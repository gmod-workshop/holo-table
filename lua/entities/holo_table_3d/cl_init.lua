include('shared.lua')
include('sh_controls.lua')
include('cl_map.lua')
include('cl_radar.lua')

function ENT:Initialize()
    local meshes = util.GetModelMeshes('models/props_phx/construct/metal_plate_curve360x2.mdl')

    self.Mask = Mesh()
    self.Mask:BuildFromTriangles(meshes[1].triangles)

    self:InitializeMap()
    self:InitializeRadar()
end

-- Radar polling rate. Default Think runs at framerate (~240 Hz on
-- high-refresh displays), which is far more than the radar mirror
-- props need: tracked entities don't move fast enough for sub-frame
-- updates to be visible, so we throttle to a fixed Hz with
-- SetNextClientThink. 15 Hz = ~67 ms between scans, well below the
-- threshold where snap-updates would be perceptible on the radar.
local RADAR_THINK_HZ       = 15
local RADAR_THINK_INTERVAL = 1 / RADAR_THINK_HZ

function ENT:Think()
    self:ThinkRadar()
    self:SetNextClientThink(CurTime() + RADAR_THINK_INTERVAL)
    return true
end

function ENT:OnRemove()
    self:CleanupMap()
    self:CleanupRadar()
end


-- Stages the shared hologram coordinate frame on `self` for every
-- subsystem that draws this frame: world-space origin/angles/inverse
-- scale for the matrix pushes (DrawClippedMap, the m2 block below,
-- DrawStaticProps, RadarBase:Project), plus the BSP-space cull
-- primitives DrawBrushEntities / DrawStaticProps share. Computed once
-- at the top of DrawHologram; consumers read self._holo* instead of
-- recomputing the same pivot / pan math.
function ENT:UpdateHologramTransform(scale, height, panX, panY)
    local pos = self:GetPos()
    local axis = self:GetUp()
    local pivotZ = pos:Dot(axis)
    local invScale = 1 / scale

    local panOffset = Vector(panX or 0, panY or 0, 0)
    local panHoriz = panOffset - axis * panOffset:Dot(axis)
    local tableAng = self:GetAngles()
    local rotPan = LocalToWorld(panOffset, angle_zero, vector_origin, tableAng)

    self._holoAxis        = axis
    self._holoAngles      = tableAng
    self._holoInvScale    = invScale
    self._holoCylRadius   = scale * 90
    self._holoFloorOffset = scale * (25 - height) + pivotZ
    self._holoPanHoriz    = panHoriz
    self._holoOrigin      = pos + axis * (height - pivotZ / scale) - rotPan * invScale

    -- Scalar caches of the table-space basis and origin, used by
    -- RadarBase:Project for allocation-free LocalToWorld in the per-
    -- radar-entry hot loop. Three Forward/Right/Up calls allocate one
    -- Vector each (constant ~72 B/frame) which is recouped many times
    -- over once Project stops calling LocalToWorld per entry.
    local F = tableAng:Forward()
    local R = tableAng:Right()
    local U = tableAng:Up()
    self._holoFx, self._holoFy, self._holoFz = F.x, F.y, F.z
    self._holoRx, self._holoRy, self._holoRz = R.x, R.y, R.z
    self._holoUx, self._holoUy, self._holoUz = U.x, U.y, U.z
    local o = self._holoOrigin
    self._holoOx, self._holoOy, self._holoOz = o.x, o.y, o.z
end


-- ENT:Draw runs during the OPAQUE entity pass and is also invoked by
-- halo.Render for the physgun silhouette. Touching stencil state from
-- here corrupts the halo silhouette for this entity (every other prop
-- still halos correctly), so the holographic content is rendered from a
-- PostDrawTranslucentRenderables hook below instead. Keep this minimal.
function ENT:Draw()
    self:DrawModel()
end


-- Module-level scratch reused across every DrawHologram call. The
-- prior version allocated two fresh Matrix(), three temp Vectors for
-- the cylinder mask transform, and ~190 short-lived Vectors per frame
-- in the polygon/prism inner loops; together about 30 KB/frame of
-- garbage. Reusing scratch + scalar inner loops drops it to ~0.
local STENCIL_MASK_MTX  = Matrix()
local SCENE_MTX         = Matrix()
local SCENE_SCALE_VEC   = Vector()
local STENCIL_VERT_VEC  = Vector()
local STENCIL_NORMAL_VEC = Vector()
local STENCIL_SEGMENTS  = 32
local STENCIL_RADIUS    = 90
local STENCIL_HEIGHT_OFFSET    = 26
local STENCIL_FLOOR_OFFSET     = 25
local STENCIL_MASK_HEIGHT      = 27
local STENCIL_PRISM_WALL_COUNT = 5

-- Renders the holographic content (clipped map, stencil-masked
-- cylinder, brush entities, radars, static props) from a
-- global render hook so the OPAQUE pass that drives halo.Render sees
-- only the table model.
function ENT:DrawHologram()
    if not self.Mask then return end

    self:UpdateHologramTransform(self:GetScale(), self:GetHeight(),
        self:GetPanX(), self:GetPanY())

    self:TickMapBuild()
    self:DrawClippedMap()

    -- Reset everything to known good
    render.ClearStencil()

    render.SetStencilEnable(true)

    render.SetStencilWriteMask(255)
    render.SetStencilTestMask(255)

    render.SetStencilPassOperation(STENCIL_REPLACE)

    render.SetStencilCompareFunction(STENCIL_ALWAYS)
    render.SetStencilReferenceValue( 1 ) --Reference value 1

    -- Cache the table pose once; Entity:Get{Pos,Angles,Up} each
    -- allocate a fresh Vector/Angle every call, so the seven uses
    -- below collapse to one of each (plus two basis vectors derived
    -- from the angle). All inner loops below read scalar components
    -- from these cached objects.
    local tablePos    = self:GetPos()
    local tableAng    = self:GetAngles()
    local tableUp     = self:GetUp()
    local tableRight  = tableAng:Right()
    local tableFwd    = tableAng:Forward()
    local tpx, tpy, tpz = tablePos.x, tablePos.y, tablePos.z
    local tux, tuy, tuz = tableUp.x,  tableUp.y,  tableUp.z

    -- Polygon-mask centre + basis (table top + 26 units up the table
    -- normal). Used by both the polygon vertex loop and the prism
    -- walls below; computed once as scalars to avoid the 4-Vector
    -- allocation the prior implementation did per use.
    local centerX = tpx + tux * STENCIL_HEIGHT_OFFSET
    local centerY = tpy + tuy * STENCIL_HEIGHT_OFFSET
    local centerZ = tpz + tuz * STENCIL_HEIGHT_OFFSET
    local basisAx, basisAy, basisAz = tableRight.x, tableRight.y, tableRight.z
    local basisBx, basisBy, basisBz = tableFwd.x,   tableFwd.y,   tableFwd.z

    -- Draw the stencil mask geometry without touching color or depth so the
    -- underlying scene shows through anywhere the holographic content does
    -- not draw on top.
    render.OverrideColorWriteEnable(true, false)
    render.OverrideDepthEnable(true, false)

    render.SetColorMaterial()
    mesh.Begin( MATERIAL_POLYGON, STENCIL_SEGMENTS )

    -- Polygon vertex loop in scalars; mesh.Position is fed via a
    -- single reused scratch Vector per vertex (zero allocations vs
    -- the prior 4 Vectors per segment = 128/frame).
    local twoPi = math.pi * 2
    for i = 0, STENCIL_SEGMENTS - 1 do
        local rot = twoPi * ( i / STENCIL_SEGMENTS )
        local s = math.sin( rot ) * STENCIL_RADIUS
        local c = math.cos( rot ) * STENCIL_RADIUS
        STENCIL_VERT_VEC:SetUnpacked(
            centerX + basisAx * s + basisBx * c,
            centerY + basisAy * s + basisBy * c,
            centerZ + basisAz * s + basisBz * c)
        mesh.Position(STENCIL_VERT_VEC)
        mesh.AdvanceVertex()
    end

    mesh.End()

    -- Cylinder model masked into the stencil. Translation is in WORLD
    -- +Z (matches the original Vector(0, 0, 27) offset) rather than
    -- tableUp * 27, so behaviour is unchanged for tilted tables.
    local maskMtx = STENCIL_MASK_MTX
    maskMtx:Identity()
    STENCIL_VERT_VEC:SetUnpacked(tpx, tpy, tpz + STENCIL_MASK_HEIGHT)
    maskMtx:Translate(STENCIL_VERT_VEC)
    maskMtx:SetAngles(tableAng)
    SCENE_SCALE_VEC:SetUnpacked(2, 2, 2)
    maskMtx:Scale(SCENE_SCALE_VEC)

    cam.PushModelMatrix(maskMtx)
        self.Mask:Draw()
    cam.PopModelMatrix()

    render.OverrideDepthEnable(false, false)
    render.OverrideColorWriteEnable(false, false)

    -- Begin actual drawing of meshes using set stencil

    render.SetStencilCompareFunction( STENCIL_EQUAL ) --Only draw if pixel value == reference value

    -- Floor clip plane: keeps anything below the table top from
    -- bleeding through. The original code used a WORLD +Z offset
    -- (Vector(0, 0, 25)), so the plane offset is
    --   tableUp:Dot(tablePos + worldZ * STENCIL_FLOOR_OFFSET)
    -- = tableUp:Dot(tablePos) + tableUp.z * STENCIL_FLOOR_OFFSET.
    local clip = render.EnableClipping(true)
    local floorOffset = tux * tpx + tuy * tpy + tuz * tpz + tuz * STENCIL_FLOOR_OFFSET
    render.PushCustomClipPlane(tableUp, floorOffset)

    -- Pentagonal prism in 3D world space, circumscribing the cylinder so any
    -- content inside the cylinder is preserved. Combined with the floor plane
    -- above, this uses the engine's full 6-plane clip budget.
    local wall_count = STENCIL_PRISM_WALL_COUNT
    local wall_apothem = STENCIL_RADIUS
    for i = 0, wall_count - 1 do
        local angle = twoPi * i / wall_count
        local s, c = math.sin(angle), math.cos(angle)
        -- outward = basisA * s + basisB * c (unit length, since the
        -- two basis vectors are orthonormal). The clip plane uses the
        -- inward normal, so flip signs when writing the scratch.
        local nx = -(basisAx * s + basisBx * c)
        local ny = -(basisAy * s + basisBy * c)
        local nz = -(basisAz * s + basisBz * c)
        STENCIL_NORMAL_VEC:SetUnpacked(nx, ny, nz)
        -- plane offset = inward:Dot(plane_point) where
        -- plane_point = center + outward * apothem
        --             = center - inward * apothem.
        -- => inward:Dot(plane_point) = inward:Dot(center) - apothem.
        local d = nx * centerX + ny * centerY + nz * centerZ - wall_apothem
        render.PushCustomClipPlane(STENCIL_NORMAL_VEC, d)
    end

    -- Pinned-pivot scene matrix shared with DrawClippedMap /
    -- DrawStaticProps / radar Project via the _holo* fields staged at
    -- the top of DrawHologram. Pins the BSP altitude so changing scale
    -- does not slide content vertically (a BSP point at altitude
    -- pivotZ always appears at table.z + height) and shifts the view
    -- so BSP (panX, panY) lands at the table center.
    local m2 = SCENE_MTX
    m2:Identity()
    m2:SetTranslation(self._holoOrigin)
    m2:SetAngles(self._holoAngles)
    SCENE_SCALE_VEC:SetUnpacked(self._holoInvScale, self._holoInvScale, self._holoInvScale)
    m2:Scale(SCENE_SCALE_VEC)

    render.PushFilterMag(TEXFILTER.ANISOTROPIC)
    render.PushFilterMin(TEXFILTER.ANISOTROPIC)
    render.SetLightingMode(2)

    local drewBakedStaticProps = false
    local drewBakedDynamicProps = false
    cam.PushModelMatrix(m2)
        self:DrawMap()

        -- Brush entities ride inside the m2 block so the world-space GPU
        -- clip prism above crops oversized geometry (e.g. hangar doors)
        -- that the per-bmodel sphere cull passes through.
        if self:GetMap() then
            self:DrawBrushEntities()
            if self.DrawBakedStaticProps then
                drewBakedStaticProps = self:DrawBakedStaticProps()
            end
            if self.DrawBakedDynamicProps then
                drewBakedDynamicProps = self:DrawBakedDynamicProps()
            end
        end

    cam.PopModelMatrix()

    -- Legacy static / dynamic props and radars are drawn in world space
    -- (not via the m2 matrix) because Entity:DrawModel does not respect
    -- cam.PushModelMatrix; the per-entity transform is folded in below.
    -- Baked props are ordinary IMeshes, so all-in views draw them inside
    -- the m2 block above and skip these fallbacks.
    if self:GetMap() and not drewBakedStaticProps then
        self:DrawStaticProps()
    end
    if self:GetMap() and self.DrawDynamicProps then
        self:DrawDynamicProps(drewBakedDynamicProps)
    end
    self:DrawRadar()

    render.SetLightingMode(0)
    render.PopFilterMin()
    render.PopFilterMag()

    -- Restore stencil state. halo.Render runs later (PostDrawEffects)
    -- and clears stencil itself, so this is mostly defensive against
    -- other consumers that read stencil between now and then.
    render.SetStencilEnable(false)
    render.SetStencilWriteMask(255)
    render.SetStencilTestMask(255)
    render.ClearStencil()

    for i = 1, wall_count do
        render.PopCustomClipPlane()
    end
    render.PopCustomClipPlane()
    render.EnableClipping(clip)
end


-- Bounding sphere for the holographic volume in WORLD space, centred
-- on the table's GetPos(). The stencil cylinder has radius 90 and is
-- offset +26 along table-up with height 27, so a sphere of radius
-- ~104 contains it; round up to 120 for safety against tilted tables
-- and any near-cylinder fringe geometry.
local CULL_SPHERE_RADIUS = 120
-- Half-FOV padding (degrees) added to the cone test to cover
-- horizontal-vs-vertical FOV mismatch on wide aspect ratios and any
-- engine-side jitter; cheap insurance against false culls at edges.
local CULL_FOV_PADDING_DEG = 8

-- Drives ENT:DrawHologram for every holo_table_3d in PVS from the
-- translucent render hook. The OPAQUE entity pass has to stay free of
-- stencil/clip work for halo.Render's silhouette pass to come out
-- correct, so the holographic content rides this hook instead.
--
-- Cull tables outside the view frustum here: DrawHologram costs ~2.1ms
-- per call regardless of whether anything is visible, and PVS is
-- generous enough that the table is often in PVS but behind the camera
-- or off to the side. Cone-vs-bounding-sphere is the cheapest test
-- that handles both the behind-camera and off-screen cases at once.
hook.Add('PostDrawTranslucentRenderables', 'holo_table_3d.DrawHologram', function(bDepth, bSkybox, b3DSkybox)
    if bDepth or bSkybox or b3DSkybox then return end

    -- Skip when rendering into a render target (point_camera /
    -- func_camera_screen / cockpit viewscreens / scope RTs). The
    -- hologram is meant for the main world view; reproducing it in a
    -- 256-512 px RT pays full cost (~2 ms) for an unreadable speck.
    -- Common case in LVS-heavy scenes where vehicles run camera
    -- entities every frame.
    if render.GetRenderTarget() then return end

    local eyePos = EyePos()
    local eyeVec = EyeVector()
    local exV, eyV, ezV = eyePos.x, eyePos.y, eyePos.z
    local fxV, fyV, fzV = eyeVec.x, eyeVec.y, eyeVec.z
    local lp = LocalPlayer()
    local fov = (IsValid(lp) and lp:GetFOV() or 90) + CULL_FOV_PADDING_DEG
    local tanHalfFov = math.tan(math.rad(fov) * 0.5)
    local sphereR = CULL_SPHERE_RADIUS
    local negSphereR = -sphereR

    -- ents.Iterator returns a cached entity table (no per-frame alloc),
    -- vs ents.FindByClass which builds a fresh filtered table each call.
    -- Class filter via GetClass is cheap enough that the saved alloc wins.
    for _, ent in ents.Iterator() do
        if ent:GetClass() == 'holo_table_3d' and ent.DrawHologram then
            local p = ent:GetPos()
            local dx, dy, dz = p.x - exV, p.y - eyV, p.z - ezV
            local fwd = dx * fxV + dy * fyV + dz * fzV
            -- Behind-camera reject: entire bounding sphere lies behind
            -- the eye plane.
            if fwd >= negSphereR then
                -- Cone reject: lateral distance from the view axis
                -- exceeds the cone half-width at this depth, padded by
                -- the bounding sphere radius. Uses max(fwd, 0) so very
                -- close tables (slightly behind plane but sphere still
                -- straddling the eye) get the full sphere padding.
                local sqrLen = dx * dx + dy * dy + dz * dz
                local lateralSq = sqrLen - fwd * fwd
                local coneFwd = fwd > 0 and fwd or 0
                local maxLat = coneFwd * tanHalfFov + sphereR
                if lateralSq <= maxLat * maxLat then
                    ent:DrawHologram()
                end
            end
        end
    end
end)
