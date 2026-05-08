include('shared.lua')
include('sh_controls.lua')
include('cl_map.lua')
include('cl_radar.lua')

local HOLOGRAM_HOOK = 'holo_table_3d.DrawHologram'
local hologramHookInstalled = false
local ensureHologramHook
local pruneHologramHook

--- Sets up the stencil mask mesh and hands off to the map / radar
--- subsystems, then installs the global render hook if needed.
function ENT:Initialize()
    local meshes = util.GetModelMeshes('models/props_phx/construct/metal_plate_curve360x2.mdl')

    local selfTbl = self:GetTable()
    selfTbl.Mask = Mesh()
    selfTbl.Mask:BuildFromTriangles(meshes[1].triangles)

    self:InitializeMap()
    self:InitializeRadar()
    if ensureHologramHook then ensureHologramHook() end
end

-- Radar polling rate. Sub-frame updates aren't visible on tracked entities,
-- so throttle below the default per-frame Think.
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
    if pruneHologramHook then pruneHologramHook() end
end


--- Stages the shared hologram coordinate frame on self for every subsystem
--- that draws this frame. Consumers read self._holo* instead of recomputing.
--- @param scale number
--- @param height number
--- @param panX number
--- @param panY number
--- @see ENT:DrawHologram
function ENT:UpdateHologramTransform(scale, height, panX, panY)
    local selfTbl = self:GetTable()
    local pos = self:GetPos()
    local axis = self:GetUp()
    local pivotZ = pos:Dot(axis)
    local invScale = 1 / scale

    local panOffset = Vector(panX or 0, panY or 0, 0)
    local panHoriz = panOffset - axis * panOffset:Dot(axis)
    local tableAng = self:GetAngles()
    local rotPan = LocalToWorld(panOffset, angle_zero, vector_origin, tableAng)

    selfTbl._holoAxis        = axis
    selfTbl._holoAngles      = tableAng
    selfTbl._holoInvScale    = invScale
    selfTbl._holoCylRadius   = scale * 90
    selfTbl._holoFloorOffset = scale * (25 - height) + pivotZ
    selfTbl._holoPanHoriz    = panHoriz
    selfTbl._holoOrigin      = pos + axis * (height - pivotZ / scale) - rotPan * invScale

    -- Scalar table-space basis used by RadarBase:Project for allocation-free
    -- LocalToWorld in the per-radar-entry hot loop.
    local F = tableAng:Forward()
    local R = tableAng:Right()
    local U = tableAng:Up()
    selfTbl._holoFx, selfTbl._holoFy, selfTbl._holoFz = F.x, F.y, F.z
    selfTbl._holoRx, selfTbl._holoRy, selfTbl._holoRz = R.x, R.y, R.z
    selfTbl._holoUx, selfTbl._holoUy, selfTbl._holoUz = U.x, U.y, U.z
    local o = selfTbl._holoOrigin
    selfTbl._holoOx, selfTbl._holoOy, selfTbl._holoOz = o.x, o.y, o.z
end


--- Opaque pass + halo silhouette. Stencil work happens in DrawHologram so
--- it doesn't corrupt this entity's halo silhouette.
--- @see ENT:DrawHologram
function ENT:Draw()
    self:DrawModel()
end


-- Module-level scratch reused across every DrawHologram call to keep the
-- stencil/prism setup allocation-free.
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

--- Renders the holographic content (clipped map, stencil-masked cylinder,
--- brush entities, baked / fallback props, radars) from the global
--- PostDrawTranslucentRenderables hook.
--- @see ENT:UpdateHologramTransform
--- @see ENT:DrawClippedMap
--- @see ENT:DrawMap
--- @see ENT:DrawBrushEntities
--- @see ENT:DrawRadar
function ENT:DrawHologram()
    local selfTbl = self:GetTable()
    if not selfTbl.Mask then return end

    self:UpdateHologramTransform(self:GetScale(), self:GetHeight(),
        self:GetPanX(), self:GetPanY())

    self:TickMapBuild()
    self:DrawClippedMap()

    render.ClearStencil()
    render.SetStencilEnable(true)
    render.SetStencilWriteMask(255)
    render.SetStencilTestMask(255)
    render.SetStencilPassOperation(STENCIL_REPLACE)
    render.SetStencilCompareFunction(STENCIL_ALWAYS)
    render.SetStencilReferenceValue(1)

    -- Cache the table pose once; Entity:Get{Pos,Angles,Up} each allocate.
    local tablePos    = self:GetPos()
    local tableAng    = self:GetAngles()
    local tableUp     = self:GetUp()
    local tableRight  = tableAng:Right()
    local tableFwd    = tableAng:Forward()
    local tpx, tpy, tpz = tablePos.x, tablePos.y, tablePos.z
    local tux, tuy, tuz = tableUp.x,  tableUp.y,  tableUp.z

    -- Polygon-mask centre + basis (table top + 26 units up the table normal).
    local centerX = tpx + tux * STENCIL_HEIGHT_OFFSET
    local centerY = tpy + tuy * STENCIL_HEIGHT_OFFSET
    local centerZ = tpz + tuz * STENCIL_HEIGHT_OFFSET
    local basisAx, basisAy, basisAz = tableRight.x, tableRight.y, tableRight.z
    local basisBx, basisBy, basisBz = tableFwd.x,   tableFwd.y,   tableFwd.z

    -- Stencil mask geometry: no color, no depth.
    render.OverrideColorWriteEnable(true, false)
    render.OverrideDepthEnable(true, false)

    render.SetColorMaterial()
    mesh.Begin( MATERIAL_POLYGON, STENCIL_SEGMENTS )

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

    -- Cylinder mask. Translation is in WORLD +Z (matches Vector(0,0,27))
    -- rather than tableUp * 27, so behaviour is unchanged for tilted tables.
    local maskMtx = STENCIL_MASK_MTX
    maskMtx:Identity()
    STENCIL_VERT_VEC:SetUnpacked(tpx, tpy, tpz + STENCIL_MASK_HEIGHT)
    maskMtx:Translate(STENCIL_VERT_VEC)
    maskMtx:SetAngles(tableAng)
    SCENE_SCALE_VEC:SetUnpacked(2, 2, 2)
    maskMtx:Scale(SCENE_SCALE_VEC)

    cam.PushModelMatrix(maskMtx)
        selfTbl.Mask:Draw()
    cam.PopModelMatrix()

    render.OverrideDepthEnable(false, false)
    render.OverrideColorWriteEnable(false, false)

    render.SetStencilCompareFunction( STENCIL_EQUAL )

    -- Floor clip plane keeps anything below the table top from bleeding
    -- through; offset is tableUp:Dot(tablePos + worldZ * STENCIL_FLOOR_OFFSET).
    local clip = render.EnableClipping(true)
    local floorOffset = tux * tpx + tuy * tpy + tuz * tpz + tuz * STENCIL_FLOOR_OFFSET
    render.PushCustomClipPlane(tableUp, floorOffset)

    -- Pentagonal prism circumscribing the cylinder. Combined with the floor
    -- plane this uses the engine's full 6-plane clip budget.
    local wall_count = STENCIL_PRISM_WALL_COUNT
    local wall_apothem = STENCIL_RADIUS
    for i = 0, wall_count - 1 do
        local angle = twoPi * i / wall_count
        local s, c = math.sin(angle), math.cos(angle)
        local nx = -(basisAx * s + basisBx * c)
        local ny = -(basisAy * s + basisBy * c)
        local nz = -(basisAz * s + basisBz * c)
        STENCIL_NORMAL_VEC:SetUnpacked(nx, ny, nz)
        local d = nx * centerX + ny * centerY + nz * centerZ - wall_apothem
        render.PushCustomClipPlane(STENCIL_NORMAL_VEC, d)
    end

    -- Pinned-pivot scene matrix shared with map / static-prop / radar draws
    -- via _holo* fields staged at the top of DrawHologram.
    local m2 = SCENE_MTX
    m2:Identity()
    m2:SetTranslation(selfTbl._holoOrigin)
    m2:SetAngles(selfTbl._holoAngles)
    SCENE_SCALE_VEC:SetUnpacked(selfTbl._holoInvScale, selfTbl._holoInvScale, selfTbl._holoInvScale)
    m2:Scale(SCENE_SCALE_VEC)

    render.PushFilterMag(TEXFILTER.ANISOTROPIC)
    render.PushFilterMin(TEXFILTER.ANISOTROPIC)
    render.SetLightingMode(2)

    local drewBakedStaticProps = false
    local drewBakedDynamicProps = false
    cam.PushModelMatrix(m2)
        self:DrawMap()

        -- Brush entities ride inside the m2 block so the world-space GPU clip
        -- prism crops oversized geometry the per-bmodel sphere cull misses.
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

    -- Legacy csent prop fallbacks and radars are world-space because
    -- Entity:DrawModel ignores cam.PushModelMatrix.
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


-- World-space bounding sphere covering the holographic volume. Stencil
-- cylinder is offset +26 along table-up with height 27, radius 90; ~104
-- contains it, round up to 120 for tilted tables.
local CULL_SPHERE_RADIUS = 120
local CULL_FOV_PADDING_DEG = 8

--- PostDrawTranslucentRenderables driver. Cone-vs-sphere culls each table so
--- offscreen / behind-camera tables don't pay DrawHologram's ~2 ms cost.
--- @param bDepth boolean
--- @param bSkybox boolean
--- @param b3DSkybox boolean
local function drawHolograms(bDepth, bSkybox, b3DSkybox)
    if bDepth or bSkybox or b3DSkybox then return end

    local tables = ents.FindByClass('holo_table_3d')
    if not tables[1] then
        hook.Remove('PostDrawTranslucentRenderables', HOLOGRAM_HOOK)
        hologramHookInstalled = false
        return
    end

    -- Skip render-target passes (point_camera / scope RTs / etc.); reproducing
    -- the hologram in a 256-512 px RT pays full cost for an unreadable speck.
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

    for _, ent in ipairs(tables) do
        if not ent.DrawHologram then continue end

        local p = ent:GetPos()
        local dx, dy, dz = p.x - exV, p.y - eyV, p.z - ezV
        local fwd = dx * fxV + dy * fyV + dz * fzV
        if fwd >= negSphereR then
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

ensureHologramHook = function()
    if hologramHookInstalled then return end
    if not ents.FindByClass('holo_table_3d')[1] then return end

    hook.Add('PostDrawTranslucentRenderables', HOLOGRAM_HOOK, drawHolograms)
    hologramHookInstalled = true
end

pruneHologramHook = function()
    timer.Simple(0, function()
        if ents.FindByClass('holo_table_3d')[1] then return end

        hook.Remove('PostDrawTranslucentRenderables', HOLOGRAM_HOOK)
        hologramHookInstalled = false
    end)
end

if ents.FindByClass('holo_table_3d')[1] then
    ensureHologramHook()
else
    hook.Remove('PostDrawTranslucentRenderables', HOLOGRAM_HOOK)
    hologramHookInstalled = false
end
