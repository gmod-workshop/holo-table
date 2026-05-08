local MapCache = ENT.MapCache
local SysTime = SysTime
local Vector = Vector
local Material = Material
local Mesh = Mesh
local math_atan2 = math.atan2
local math_sqrt = math.sqrt
local math_pi = math.pi
local coroutine_create = coroutine.create
local coroutine_yield = coroutine.yield
local coroutine_resume = coroutine.resume
local coroutine_status = coroutine.status
local hook_Add = hook.Add
local hook_Remove = hook.Remove
local render_SetMaterial = render.SetMaterial
local filter = MapCache.filter
local staticPropBakeCvar = MapCache.staticPropBakeCvar
local staticPropBakeModeCvar = MapCache.staticPropBakeModeCvar
local PROP_SUBPIXEL_THRESHOLD = MapCache.PROP_SUBPIXEL_THRESHOLD
local CACHE_GENERATION = MapCache.CACHE_GENERATION
local getPropBounds = MapCache.getPropBounds
local getPropDrawEnt = MapCache.getPropDrawEnt
local buildMeshFromTriangles = MapCache.buildMeshFromTriangles
local PROP_DRAW_SCRATCH_POS = MapCache.PROP_DRAW_SCRATCH_POS
local PROP_DRAW_SCRATCH_ANG = MapCache.PROP_DRAW_SCRATCH_ANG
local atan2 = math_atan2
local sqrt = math_sqrt
local RAD2DEG = 180 / math_pi
local STATIC_PROP_BAKE_HOOK = 'holo_table_3d.static_prop_bake'
local STATIC_PROP_PER_PROP_BAKE_HOOK = 'holo_table_3d.static_prop_per_prop_bake'
local STATIC_PROP_BAKE_FRAME_BUDGET = 0.006
local STATIC_PROP_BAKE_MAX_VERTS = 12000
local STATIC_PROP_BAKE_PER_VERT_SEC = 0.5e-6
MapCache.staticPropBake = nil
MapCache.staticPropPerPropBake = nil

function MapCache.destroyStaticPropBake()
    hook_Remove('Think', STATIC_PROP_BAKE_HOOK)
    if MapCache.staticPropBake and MapCache.staticPropBake.meshes then
        MapCache.destroyMeshList(MapCache.staticPropBake.meshes)
    end
    MapCache.staticPropBake = nil
end

function MapCache.destroyStaticPropPerPropBake()
    hook_Remove('Think', STATIC_PROP_PER_PROP_BAKE_HOOK)
    if MapCache.staticPropPerPropBake and MapCache.staticPropPerPropBake.props then
        for _, rec in ipairs(MapCache.staticPropPerPropBake.props) do
            MapCache.destroyMeshList(rec.meshes)
        end
    end
    if MapCache.staticPropPerPropBake and MapCache.staticPropPerPropBake.pendingProps then
        for _, rec in ipairs(MapCache.staticPropPerPropBake.pendingProps) do
            MapCache.destroyMeshList(rec.meshes)
        end
    end
    if MapCache.staticPropPerPropBake then
        MapCache.destroyMeshList(MapCache.staticPropPerPropBake.pendingMeshes)
    end
    MapCache.staticPropPerPropBake = nil
end

local function staticPropBakeMaterial(path)
    if not path or path == '' then return nil, nil end
    local mat = Material(path)
    if not mat or mat:IsError() then return nil, nil end
    local btn = mat:GetTexture('$basetexture')
    if btn and filter[btn:GetName()] then return nil, nil end
    return mat, btn and btn:GetName() or mat:GetName()
end

local function addStaticPropBakeVert(out, vert, origin, fx, fy, fz, rx, ry, rz, ux, uy, uz)
    local pos = vert.pos
    local px, py, pz = pos.x, pos.y, pos.z
    local normal = vert.normal or vector_up
    local nx, ny, nz = normal.x, normal.y, normal.z
    local outNormal = Vector(
        fx * nx - rx * ny + ux * nz,
        fy * nx - ry * ny + uy * nz,
        fz * nx - rz * ny + uz * nz)
    outNormal:Normalize()

    out[#out + 1] = {
        pos = Vector(
            origin.x + fx * px - rx * py + ux * pz,
            origin.y + fy * px - ry * py + uy * pz,
            origin.z + fz * px - rz * py + uz * pz),
        normal = outNormal,
        u = vert.u,
        v = vert.v,
    }
end
MapCache.addStaticPropBakeVert = addStaticPropBakeVert

function MapCache.startStaticPropBake(scale)
    if not staticPropBakeCvar:GetBool() then return end
    local bsp = bsp2 and bsp2.GetCurrent()
    if not bsp or not bsp.props or #bsp.props == 0 then return end
    scale = tonumber(scale) or 0
    if scale <= 0 then return end
    if MapCache.staticPropBake and MapCache.staticPropBake.gen == CACHE_GENERATION
        and math.abs((MapCache.staticPropBake.scale or 0) - scale) < 0.01
        and (MapCache.staticPropBake.state == 'building' or MapCache.staticPropBake.state == 'ready') then
        return
    end

    MapCache.destroyStaticPropBake()
    local minRadius = PROP_SUBPIXEL_THRESHOLD / (2 / scale)
    MapCache.staticPropBake = {
        gen = CACHE_GENERATION,
        state = 'building',
        scale = scale,
        minRadius = minRadius,
        meshes = {},
        props = #bsp.props,
        bakedProps = 0,
        outputVerts = 0,
    }

    MapCache.staticPropBake.co = coroutine_create(function()
        local props = bsp.props
        local modelCache = {}
        local groups = {}
        local deadline = SysTime() + STATIC_PROP_BAKE_FRAME_BUDGET

        local function bumpDeadline()
            deadline = SysTime() + STATIC_PROP_BAKE_FRAME_BUDGET
        end

        local function budgetYield()
            if SysTime() <= deadline then return end
            coroutine_yield()
            bumpDeadline()
        end

        local function flushGroup(group)
            local verts = group.verts
            local n = #verts
            if n == 0 then return end
            if SysTime() + n * STATIC_PROP_BAKE_PER_VERT_SEC > deadline then
                coroutine_yield()
                bumpDeadline()
            end
            local msh = buildMeshFromTriangles(verts)
            MapCache.staticPropBake.meshes[#MapCache.staticPropBake.meshes + 1] = { mat = group.mat, mesh = msh }
            MapCache.staticPropBake.outputVerts = MapCache.staticPropBake.outputVerts + n
            group.verts = {}
            budgetYield()
        end

        local function groupFor(mat, matKey)
            local group = groups[matKey]
            if not group then
                group = { mat = mat, verts = {} }
                groups[matKey] = group
            end
            return group
        end

        for i = 1, #props do
            budgetYield()
            local prop = props[i]
            local model = prop and prop.model
            if not model then continue end

            local bounds = getPropBounds(model)
            if bounds.radius == 0 or bounds.radius < minRadius then continue end

            local skin = prop.skin or 0
            local modelKey = model .. '|skin=' .. tostring(skin)
            local modelMeshes = modelCache[modelKey]
            if modelMeshes == nil then
                modelMeshes = util.GetModelMeshes(model, 0, 0, skin) or false
                modelCache[modelKey] = modelMeshes
            end
            if not modelMeshes then continue end

            local origin = prop.origin
            if not origin then continue end
            MapCache.staticPropBake.bakedProps = MapCache.staticPropBake.bakedProps + 1

            local fx, fy, fz, rx, ry, rz, ux, uy, uz
            if prop.angles then
                local f = prop.angles:Forward()
                local r = prop.angles:Right()
                local u = prop.angles:Up()
                fx, fy, fz = f.x, f.y, f.z
                rx, ry, rz = r.x, r.y, r.z
                ux, uy, uz = u.x, u.y, u.z
            else
                fx, fy, fz = 1, 0, 0
                rx, ry, rz = 0, -1, 0
                ux, uy, uz = 0, 0, 1
            end

            for _, meshData in ipairs(modelMeshes) do
                local mat, matKey = staticPropBakeMaterial(meshData.material)
                local tris = meshData.triangles
                if not (mat and tris) then continue end

                local group = groupFor(mat, matKey)
                local out = group.verts
                for vi = 1, #tris do
                    addStaticPropBakeVert(out, tris[vi], origin, fx, fy, fz, rx, ry, rz, ux, uy, uz)
                    if #out >= STATIC_PROP_BAKE_MAX_VERTS then
                        flushGroup(group)
                        out = group.verts
                    elseif vi % 768 == 0 then
                        budgetYield()
                    end
                end
            end
        end

        for _, group in pairs(groups) do
            flushGroup(group)
        end

        MapCache.staticPropBake.state = 'ready'
    end)

    hook_Add('Think', STATIC_PROP_BAKE_HOOK, function()
        if not MapCache.staticPropBake or MapCache.staticPropBake.gen ~= CACHE_GENERATION then
            MapCache.destroyStaticPropBake()
            return
        end
        if MapCache.staticPropBake.state ~= 'building' then
            hook_Remove('Think', STATIC_PROP_BAKE_HOOK)
            return
        end
        if MapCache.anyClipCoroutineActive() then return end

        local ok, err = coroutine_resume(MapCache.staticPropBake.co)
        if not ok then
            ErrorNoHaltWithStack(err)
            MapCache.destroyStaticPropBake()
            return
        end
        if coroutine_status(MapCache.staticPropBake.co) == 'dead' then
            MapCache.staticPropBake.co = nil
            if MapCache.staticPropBake.state == 'building' then MapCache.staticPropBake.state = 'ready' end
            hook_Remove('Think', STATIC_PROP_BAKE_HOOK)
            MsgC(Color(120, 200, 255), string.format(
                '[holo_table] Static prop bake ready: props=%d/%d scale=%.1f meshes=%d verts=%d\n',
                MapCache.staticPropBake.bakedProps or 0,
                MapCache.staticPropBake.props or 0,
                MapCache.staticPropBake.scale or 0,
                MapCache.staticPropBake.meshes and #MapCache.staticPropBake.meshes or 0,
                MapCache.staticPropBake.outputVerts or 0))
        end
    end)
end

function MapCache.startStaticPropPerPropBake(scale)
    if not staticPropBakeCvar:GetBool() then return end
    local bsp = bsp2 and bsp2.GetCurrent()
    if not bsp or not bsp.props or #bsp.props == 0 then return end
    scale = tonumber(scale) or 0
    if scale <= 0 then return end
    if MapCache.staticPropPerPropBake and MapCache.staticPropPerPropBake.gen == CACHE_GENERATION
        and math.abs((MapCache.staticPropPerPropBake.scale or 0) - scale) < 0.01
        and (MapCache.staticPropPerPropBake.state == 'building' or MapCache.staticPropPerPropBake.state == 'ready') then
        return
    end

    MapCache.destroyStaticPropPerPropBake()
    local minRadius = PROP_SUBPIXEL_THRESHOLD / (2 / scale)
    MapCache.staticPropPerPropBake = {
        gen = CACHE_GENERATION,
        state = 'building',
        scale = scale,
        minRadius = minRadius,
        propsTotal = #bsp.props,
        props = {},
        pendingProps = {},
        pendingMeshes = {},
        bakedProps = 0,
        outputVerts = 0,
    }

    MapCache.staticPropPerPropBake.co = coroutine_create(function()
        local props = bsp.props
        local modelCache = {}
        local deadline = SysTime() + STATIC_PROP_BAKE_FRAME_BUDGET

        local function bumpDeadline()
            deadline = SysTime() + STATIC_PROP_BAKE_FRAME_BUDGET
        end

        local function budgetYield()
            if SysTime() <= deadline then return end
            coroutine_yield()
            bumpDeadline()
        end

        local function flushGroup(group, meshes)
            local verts = group.verts
            local n = #verts
            if n == 0 then return end
            if SysTime() + n * STATIC_PROP_BAKE_PER_VERT_SEC > deadline then
                coroutine_yield()
                bumpDeadline()
            end
            local msh = buildMeshFromTriangles(verts)
            local item = { mat = group.mat, mesh = msh }
            meshes[#meshes + 1] = item
            MapCache.staticPropPerPropBake.pendingMeshes[#MapCache.staticPropPerPropBake.pendingMeshes + 1] = item
            MapCache.staticPropPerPropBake.outputVerts = MapCache.staticPropPerPropBake.outputVerts + n
            group.verts = {}
            budgetYield()
        end

        local function groupFor(groups, mat, matKey)
            local group = groups[matKey]
            if not group then
                group = { mat = mat, verts = {} }
                groups[matKey] = group
            end
            return group
        end

        for i = 1, #props do
            budgetYield()
            local prop = props[i]
            local model = prop and prop.model
            if not model then continue end

            local bounds = getPropBounds(model)
            local radius = bounds.radius
            if radius == 0 or radius < minRadius then continue end

            local skin = prop.skin or 0
            local modelKey = model .. '|skin=' .. tostring(skin)
            local modelMeshes = modelCache[modelKey]
            if modelMeshes == nil then
                modelMeshes = util.GetModelMeshes(model, 0, 0, skin) or false
                modelCache[modelKey] = modelMeshes
            end
            if not modelMeshes then continue end

            local origin = prop.origin
            if not origin then continue end

            local fx, fy, fz, rx, ry, rz, ux, uy, uz
            if prop.angles then
                local f = prop.angles:Forward()
                local r = prop.angles:Right()
                local u = prop.angles:Up()
                fx, fy, fz = f.x, f.y, f.z
                rx, ry, rz = r.x, r.y, r.z
                ux, uy, uz = u.x, u.y, u.z
            else
                fx, fy, fz = 1, 0, 0
                rx, ry, rz = 0, -1, 0
                ux, uy, uz = 0, 0, 1
            end

            local bc = bounds.center
            local bcx, bcy, bcz = bc.x, bc.y, bc.z
            local cx = origin.x + fx * bcx - rx * bcy + ux * bcz
            local cy = origin.y + fy * bcx - ry * bcy + uy * bcz
            local cz = origin.z + fz * bcx - rz * bcy + uz * bcz
            local groups = {}
            local meshes = {}

            for _, meshData in ipairs(modelMeshes) do
                local mat, matKey = staticPropBakeMaterial(meshData.material)
                local tris = meshData.triangles
                if not (mat and tris) then continue end

                local group = groupFor(groups, mat, matKey)
                local out = group.verts
                for vi = 1, #tris do
                    addStaticPropBakeVert(out, tris[vi], origin, fx, fy, fz, rx, ry, rz, ux, uy, uz)
                    if #out >= STATIC_PROP_BAKE_MAX_VERTS then
                        flushGroup(group, meshes)
                        out = group.verts
                    elseif vi % 768 == 0 then
                        budgetYield()
                    end
                end
            end

            for _, group in pairs(groups) do
                flushGroup(group, meshes)
            end

            if #meshes > 0 then
                local rec = {
                    cx = cx, cy = cy, cz = cz,
                    radius = radius,
                    meshes = meshes,
                }
                MapCache.staticPropPerPropBake.pendingProps[#MapCache.staticPropPerPropBake.pendingProps + 1] = rec
                MapCache.staticPropPerPropBake.bakedProps = MapCache.staticPropPerPropBake.bakedProps + 1
            end
        end

        MapCache.staticPropPerPropBake.state = 'ready'
    end)

    hook_Add('Think', STATIC_PROP_PER_PROP_BAKE_HOOK, function()
        if not MapCache.staticPropPerPropBake or MapCache.staticPropPerPropBake.gen ~= CACHE_GENERATION then
            MapCache.destroyStaticPropPerPropBake()
            return
        end
        if MapCache.staticPropPerPropBake.state ~= 'building' then
            hook_Remove('Think', STATIC_PROP_PER_PROP_BAKE_HOOK)
            return
        end
        if MapCache.anyClipCoroutineActive() then return end

        local ok, err = coroutine_resume(MapCache.staticPropPerPropBake.co)
        if not ok then
            ErrorNoHaltWithStack(err)
            MapCache.destroyStaticPropPerPropBake()
            return
        end
        if coroutine_status(MapCache.staticPropPerPropBake.co) == 'dead' then
            MapCache.staticPropPerPropBake.co = nil
            MapCache.staticPropPerPropBake.props = MapCache.staticPropPerPropBake.pendingProps or {}
            MapCache.staticPropPerPropBake.pendingProps = nil
            MapCache.staticPropPerPropBake.pendingMeshes = nil
            if MapCache.staticPropPerPropBake.state == 'building' then MapCache.staticPropPerPropBake.state = 'ready' end
            hook_Remove('Think', STATIC_PROP_PER_PROP_BAKE_HOOK)
            MsgC(Color(120, 200, 255), string.format(
                '[holo_table] Static prop per-prop bake ready: props=%d/%d scale=%.1f verts=%d\n',
                MapCache.staticPropPerPropBake.bakedProps or 0,
                MapCache.staticPropPerPropBake.propsTotal or 0,
                MapCache.staticPropPerPropBake.scale or 0,
                MapCache.staticPropPerPropBake.outputVerts or 0))
        end
    end)
end

-- prop_dynamic map dressing is map-owned rather than radar-owned. Most of
-- it is static enough to bake into BSP-space IMeshes and draw inside the
-- holo matrix; the per-table csent fallback below covers partial views,
-- disabled bake, and the short window while a changed prop set rebuilds.


function ENT:DrawBakedStaticProps()
    if not staticPropBakeCvar:GetBool() then return false end
    if not self:GetMap() then return false end
    local selfTbl = self:GetTable()
    local mode = staticPropBakeModeCvar:GetInt()
    if mode == 0 then return false end
    local scale = self:GetScale()
    if mode == 2 then
        if not MapCache.staticPropPerPropBake or MapCache.staticPropPerPropBake.gen ~= CACHE_GENERATION then
            MapCache.startStaticPropPerPropBake(scale)
            return false
        end
        if math.abs((MapCache.staticPropPerPropBake.scale or 0) - scale) >= 0.01 then
            MapCache.startStaticPropPerPropBake(scale)
            return false
        end
        if MapCache.staticPropPerPropBake.state ~= 'ready' or not MapCache.staticPropPerPropBake.props then return false end

        local axisX, axisY, axisZ = selfTbl._holoAxis:Unpack()
        local panX,  panY,  panZ  = selfTbl._holoPanHoriz:Unpack()
        local cylRadius           = selfTbl._holoCylRadius
        local floorOffset         = selfTbl._holoFloorOffset

        render.SuppressEngineLighting(true)
        local ok, err = pcall(function()
            for _, rec in ipairs(MapCache.staticPropPerPropBake.props) do
                local cx, cy, cz = rec.cx, rec.cy, rec.cz
                local radius = rec.radius
                local along = cx * axisX + cy * axisY + cz * axisZ
                local hx = cx - axisX * along - panX
                local hy = cy - axisY * along - panY
                local hz = cz - axisZ * along - panZ
                local bound = cylRadius + radius
                if hx * hx + hy * hy + hz * hz > bound * bound then continue end
                if along + radius < floorOffset then continue end

                for _, item in ipairs(rec.meshes) do
                    if item.mesh then
                        render_SetMaterial(item.mat)
                        item.mesh:Draw()
                    end
                end
            end
        end)
        render.SuppressEngineLighting(false)

        if not ok then
            ErrorNoHaltWithStack('[holo_table] DrawBakedStaticProps per-prop aborted: ' .. tostring(err))
            MapCache.destroyStaticPropPerPropBake()
            return false
        end
        return true
    end

    if mode ~= 3 and not self:CylinderHorizContainsMap(scale, self:GetPanX(), self:GetPanY()) then
        return false
    end
    if not MapCache.staticPropBake or MapCache.staticPropBake.gen ~= CACHE_GENERATION then
        MapCache.startStaticPropBake(scale)
        return false
    end
    if math.abs((MapCache.staticPropBake.scale or 0) - scale) >= 0.01 then
        MapCache.startStaticPropBake(scale)
        return false
    end
    if MapCache.staticPropBake.state ~= 'ready' or not MapCache.staticPropBake.meshes then return false end

    render.SuppressEngineLighting(true)
    local ok, err = pcall(function()
        for _, item in ipairs(MapCache.staticPropBake.meshes) do
            if item.mesh then
                render_SetMaterial(item.mat)
                item.mesh:Draw()
            end
        end
    end)
    render.SuppressEngineLighting(false)

    if not ok then
        ErrorNoHaltWithStack('[holo_table] DrawBakedStaticProps aborted: ' .. tostring(err))
        MapCache.destroyStaticPropBake()
        return false
    end

    return true
end

function ENT:DrawStaticProps()
    local bsp = bsp2 and bsp2.GetCurrent()
    if not bsp or not bsp.props then return end
    local selfTbl = self:GetTable()

    -- Static props are drawn as clientside mirrors culled against the table
    -- cylinder. Shared scratch position/angle objects keep this path
    -- allocation-free per surviving prop.

    -- Hot loop: 2256 props/frame on rp_venator, called every frame the
    -- table is on screen. The earlier version allocated ~360 KB/frame of
    -- short-lived Vectors (cull-pass arithmetic + per-prop LocalToWorld
    -- results), which alone produced periodic 80 ms full-GC hitches.
    -- This version unpacks every world vector into scalars up front so
    -- the cull pass touches no garbage, and caches each prop's BSP-space
    -- cull center as scalars on the prop itself the first time it is
    -- considered.
    local axisX, axisY, axisZ = selfTbl._holoAxis:Unpack()
    local panX,  panY,  panZ  = selfTbl._holoPanHoriz:Unpack()
    local cylRadius   = selfTbl._holoCylRadius
    local floorOffset = selfTbl._holoFloorOffset

    -- World-space transform mirroring the m2 matrix used for meshes:
    --   p_world = tableOrigin + R(tableAng) * ((p_bsp - panOffset) / scale)
    -- with the pan term already folded into tableOrigin (see
    -- ENT:UpdateHologramTransform). Per-prop draw only needs the
    -- standard scale + rotate, not the pan.
    local tableAng    = selfTbl._holoAngles
    local tableOrigin = selfTbl._holoOrigin
    local invScale    = selfTbl._holoInvScale

    -- Pre-multiply: prop survives sub-pixel cull when its visible
    -- diagonal in holo units (2 * b.radius * invScale, since b.radius
    -- is half-diagonal in BSP units) is >= PROP_SUBPIXEL_THRESHOLD.
    -- Solve for b.radius: b.radius >= threshold / (2 * invScale).
    local subpxRadiusBSP = PROP_SUBPIXEL_THRESHOLD / (2 * invScale)

    -- Pre-square the cylinder bound so the per-prop horiz check stays
    -- in scalars (avoids the sqrt in :Length()).
    local cylRadiusPlus = cylRadius -- per-prop adds b.radius below
    local props = bsp.props
    local scratchPos = PROP_DRAW_SCRATCH_POS
    local scratchAng = PROP_DRAW_SCRATCH_ANG

    -- Cache the table's basis vectors and origin as scalars once per
    -- frame. Per-prop world position is then `tableOrigin + tF*lx -
    -- tR*ly + tU*lz` (the verified Source/GMod LocalToWorld convention),
    -- written into scratchPos via :SetUnpacked. The three :Forward()/
    -- :Right()/:Up() calls each allocate a Vector but only run once per
    -- frame, so the per-frame overhead is constant (~720 bytes/frame
    -- regardless of prop count).
    local tF = tableAng:Forward()
    local tR = tableAng:Right()
    local tU = tableAng:Up()
    local tFx, tFy, tFz = tF.x, tF.y, tF.z
    local tRx, tRy, tRz = tR.x, tR.y, tR.z
    local tUx, tUy, tUz = tU.x, tU.y, tU.z
    local toX, toY, toZ = tableOrigin.x, tableOrigin.y, tableOrigin.z

    render.SuppressEngineLighting(true)
    for i = 1, #props do
        local prop = props[i]
        local model = prop.model
        if not model then continue end

        local b = getPropBounds(model)
        local radius = b.radius
        if radius == 0 then continue end
        if radius < subpxRadiusBSP then continue end

        -- BSP-space cull center and prop-local basis, lazily cached as
        -- scalars on the prop. prop.origin and prop.angles never change
        -- at runtime, so both the composed center and the prop's basis
        -- are invariant. The two caches are independently gated so a
        -- prop populated by an earlier build (before the basis fields
        -- existed) still gets its basis filled the first time the
        -- angled-prop draw path runs.
        local cx, cy, cz = prop._holoCullCx, prop._holoCullCy, prop._holoCullCz
        if not cx then
            local origin = prop.origin
            local bc = b.center
            local bcx, bcy, bcz = bc.x, bc.y, bc.z
            if prop.angles then
                -- center = origin + R(prop.angles) * b.center
                -- using the verified F*x - R*y + U*z convention.
                local pf = prop.angles:Forward()
                local pr = prop.angles:Right()
                local pu = prop.angles:Up()
                prop._holoFx, prop._holoFy, prop._holoFz = pf.x, pf.y, pf.z
                prop._holoRx, prop._holoRy, prop._holoRz = pr.x, pr.y, pr.z
                prop._holoUx, prop._holoUy, prop._holoUz = pu.x, pu.y, pu.z
                cx = origin.x + pf.x * bcx - pr.x * bcy + pu.x * bcz
                cy = origin.y + pf.y * bcx - pr.y * bcy + pu.y * bcz
                cz = origin.z + pf.z * bcx - pr.z * bcy + pu.z * bcz
            else
                cx = origin.x + bcx
                cy = origin.y + bcy
                cz = origin.z + bcz
            end
            prop._holoCullCx, prop._holoCullCy, prop._holoCullCz = cx, cy, cz
        elseif prop.angles and not prop._holoFx then
            local pf = prop.angles:Forward()
            local pr = prop.angles:Right()
            local pu = prop.angles:Up()
            prop._holoFx, prop._holoFy, prop._holoFz = pf.x, pf.y, pf.z
            prop._holoRx, prop._holoRy, prop._holoRz = pr.x, pr.y, pr.z
            prop._holoUx, prop._holoUy, prop._holoUz = pu.x, pu.y, pu.z
        end

        local along = cx * axisX + cy * axisY + cz * axisZ
        local hx = cx - axisX * along - panX
        local hy = cy - axisY * along - panY
        local hz = cz - axisZ * along - panZ
        local bound = cylRadiusPlus + radius
        if hx * hx + hy * hy + hz * hz > bound * bound then continue end
        if along + radius < floorOffset then continue end

        local cs = getPropDrawEnt(model)
        if not IsValid(cs) then continue end

        -- Draw transform, written entirely into scratch storage.
        -- Position: world = tableOrigin + R(tableAng) * (origin/scale).
        -- Angles: tableAng directly when the prop has none of its own;
        -- otherwise compose the world-space prop basis manually and
        -- derive Euler angles into a scratch Angle. Verified to match
        -- Matrix(SetAngles(tableAng):Rotate(prop.angles)):GetAngles()
        -- to within 1e-6 across 80 cases (see PROP_DRAW_SCRATCH_ANG
        -- doc-comment above). Zero allocations per drawn prop.
        local origin = prop.origin
        local lx = origin.x * invScale
        local ly = origin.y * invScale
        local lz = origin.z * invScale
        scratchPos:SetUnpacked(
            toX + tFx * lx - tRx * ly + tUx * lz,
            toY + tFy * lx - tRy * ly + tUy * lz,
            toZ + tFz * lx - tRz * ly + tUz * lz)
        cs:SetPos(scratchPos)
        if prop.angles then
            -- Compose the world-space basis vectors. Each composed
            -- basis vector is R(tableAng) applied to the prop-local
            -- basis using the same F*x - R*y + U*z convention used
            -- for position. Only the components needed for Euler
            -- extraction (full F, R.z, U.z) are computed.
            local pfx, pfy, pfz = prop._holoFx, prop._holoFy, prop._holoFz
            local prx, pry, prz = prop._holoRx, prop._holoRy, prop._holoRz
            local pux, puy, puz = prop._holoUx, prop._holoUy, prop._holoUz
            local wFx = tFx * pfx - tRx * pfy + tUx * pfz
            local wFy = tFy * pfx - tRy * pfy + tUy * pfz
            local wFz = tFz * pfx - tRz * pfy + tUz * pfz
            local wRz = tFz * prx - tRz * pry + tUz * prz
            local wUz = tFz * pux - tRz * puy + tUz * puz
            local pitch = atan2(-wFz, sqrt(wFx * wFx + wFy * wFy)) * RAD2DEG
            local yaw   = atan2(wFy, wFx) * RAD2DEG
            local roll  = atan2(-wRz, wUz) * RAD2DEG
            scratchAng:SetUnpacked(pitch, yaw, roll)
            cs:SetAngles(scratchAng)
        else
            cs:SetAngles(tableAng)
        end
        cs:SetModelScale(invScale, 0)
        cs:SetupBones()
        cs:DrawModel()
    end
    render.SuppressEngineLighting(false)
end

-- Replaces the live clipped mesh list, destroying the previous one. Records
-- whether the build was for an "all-in" cylinder; when it was, the list is
-- also cached on `self.AllInMeshes` so partial → all-in transitions can swap
-- it back in without rebuilding. Items are flagged `borrowed` while cached
-- so the standard DestroyClippedMap path won't free them.


MapCache.staticPropBakeMaterial = staticPropBakeMaterial
