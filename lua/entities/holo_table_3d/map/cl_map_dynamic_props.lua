local MapCache = ENT.MapCache
local SysTime = SysTime
local math_atan2 = math.atan2
local math_sin = math.sin
local math_cos = math.cos
local math_sqrt = math.sqrt
local math_pi = math.pi
local coroutine_create = coroutine.create
local coroutine_yield = coroutine.yield
local coroutine_resume = coroutine.resume
local coroutine_status = coroutine.status
local hook_Add = hook.Add
local hook_Remove = hook.Remove
local render_SetMaterial = render.SetMaterial
local dynamicPropBakeCvar = MapCache.dynamicPropBakeCvar
local CACHE_GENERATION = MapCache.CACHE_GENERATION
local staticPropBakeMaterial = MapCache.staticPropBakeMaterial
local addStaticPropBakeVert = MapCache.addStaticPropBakeVert
local buildMeshFromTriangles = MapCache.buildMeshFromTriangles
local DYNAMIC_PROP_BAKE_HOOK = 'holo_table_3d.dynamic_prop_bake'
local DYNAMIC_PROP_SCAN_INTERVAL = 1.0
local DYNAMIC_PROP_BAKE_FRAME_BUDGET = 0.006
local DYNAMIC_PROP_BAKE_MAX_VERTS = 12000
local DYNAMIC_PROP_BAKE_PER_VERT_SEC = 0.5e-6
MapCache.dynamicPropBake = nil

function MapCache.destroyDynamicPropBake()
    hook_Remove('Think', DYNAMIC_PROP_BAKE_HOOK)
    if MapCache.dynamicPropBake then
        MapCache.destroyMeshList(MapCache.dynamicPropBake.meshes)
        MapCache.destroyMeshList(MapCache.dynamicPropBake.pendingMeshes)
    end
    MapCache.dynamicPropBake = nil
end

local DYNAMIC_PROP_MOVE_EPS_SQR = 1
local DYNAMIC_PROP_ANGLE_EPS = 1

local function dynamicPropChanged(a, b)
    if not a then return false end
    if a.model ~= b.model or a.skin ~= b.skin then return false end
    local dx, dy, dz = a.px - b.px, a.py - b.py, a.pz - b.pz
    local da = math.abs(a.ap - b.ap) + math.abs(a.ay - b.ay) + math.abs(a.ar - b.ar)
    return dx * dx + dy * dy + dz * dz > DYNAMIC_PROP_MOVE_EPS_SQR
        or da > DYNAMIC_PROP_ANGLE_EPS
end

local function dynamicPropSnapshot()
    local bake = MapCache.dynamicPropBake
    local prev = bake and bake.lastSeen or {}
    local seen = {}
    local unbaked = {}
    local list = {}
    local sig = {}
    for _, ent in ents.Iterator() do
        if ent:GetClass() ~= 'prop_dynamic' then continue end
        local model = ent:GetModel()
        if not model or model == '' then continue end
        local pos = ent:GetPos()
        local ang = ent:GetAngles()
        local skin = ent:GetSkin() or 0
        local idx = ent:EntIndex()
        local state = {
            model = model,
            skin = skin,
            px = pos.x, py = pos.y, pz = pos.z,
            ap = ang.p, ay = ang.y, ar = ang.r,
        }
        seen[idx] = state
        if dynamicPropChanged(prev[idx], state) then
            unbaked[idx] = true
        elseif bake and bake.unbaked and bake.unbaked[idx] then
            unbaked[idx] = true
        end
        if unbaked[idx] then continue end

        list[#list + 1] = {
            entIndex = idx,
            model = model,
            skin = skin,
            pos = pos,
            ang = ang,
        }
        sig[#sig + 1] = string.format('%d:%s:%d:%.2f,%.2f,%.2f:%.2f,%.2f,%.2f',
            idx, model, skin,
            pos.x, pos.y, pos.z,
            ang.p, ang.y, ang.r)
    end
    table.sort(sig)
    if bake then
        bake.lastSeen = seen
        bake.unbaked = unbaked
    end
    return list, table.concat(sig, '|')
end

local function startDynamicPropBake(snapshot, signature)
    if not MapCache.dynamicPropBake then return end
    MapCache.dynamicPropBake.state = 'building'
    MapCache.dynamicPropBake.pendingSignature = signature
    MapCache.dynamicPropBake.pendingMeshes = {}
    MapCache.dynamicPropBake.pendingProps = #snapshot
    MapCache.dynamicPropBake.pendingVerts = 0

    MapCache.dynamicPropBake.co = coroutine_create(function()
        local modelCache = {}
        local groups = {}
        local deadline = SysTime() + DYNAMIC_PROP_BAKE_FRAME_BUDGET

        local function bumpDeadline()
            deadline = SysTime() + DYNAMIC_PROP_BAKE_FRAME_BUDGET
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
            if SysTime() + n * DYNAMIC_PROP_BAKE_PER_VERT_SEC > deadline then
                coroutine_yield()
                bumpDeadline()
            end
            local msh = buildMeshFromTriangles(verts)
            MapCache.dynamicPropBake.pendingMeshes[#MapCache.dynamicPropBake.pendingMeshes + 1] = {
                mat = group.mat,
                mesh = msh,
            }
            MapCache.dynamicPropBake.pendingVerts = MapCache.dynamicPropBake.pendingVerts + n
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

        for i = 1, #snapshot do
            budgetYield()
            local rec = snapshot[i]
            local modelKey = rec.model .. '|skin=' .. tostring(rec.skin)
            local modelMeshes = modelCache[modelKey]
            if modelMeshes == nil then
                modelMeshes = util.GetModelMeshes(rec.model, 0, 0, rec.skin) or false
                modelCache[modelKey] = modelMeshes
            end
            if not modelMeshes then continue end

            local f = rec.ang:Forward()
            local r = rec.ang:Right()
            local u = rec.ang:Up()
            local fx, fy, fz = f.x, f.y, f.z
            local rx, ry, rz = r.x, r.y, r.z
            local ux, uy, uz = u.x, u.y, u.z

            for _, meshData in ipairs(modelMeshes) do
                local mat, matKey = staticPropBakeMaterial(meshData.material)
                local tris = meshData.triangles
                if not (mat and tris) then continue end

                local group = groupFor(mat, matKey)
                local out = group.verts
                for vi = 1, #tris do
                    addStaticPropBakeVert(out, tris[vi], rec.pos, fx, fy, fz, rx, ry, rz, ux, uy, uz)
                    if #out >= DYNAMIC_PROP_BAKE_MAX_VERTS then
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
    end)
end

function MapCache.startDynamicPropBakeWatch()
    if not dynamicPropBakeCvar:GetBool() then return end
    if MapCache.dynamicPropBake and MapCache.dynamicPropBake.gen == CACHE_GENERATION then return end

    MapCache.destroyDynamicPropBake()
    MapCache.dynamicPropBake = {
        gen = CACHE_GENERATION,
        state = 'idle',
        meshes = {},
        signature = nil,
        lastSeen = {},
        unbaked = {},
        nextScan = 0,
    }

    hook_Add('Think', DYNAMIC_PROP_BAKE_HOOK, function()
        if not MapCache.dynamicPropBake or MapCache.dynamicPropBake.gen ~= CACHE_GENERATION then
            MapCache.destroyDynamicPropBake()
            return
        end
        if not dynamicPropBakeCvar:GetBool() then return end
        if MapCache.anyClipCoroutineActive() then return end

        if MapCache.dynamicPropBake.state == 'building' then
            local ok, err = coroutine_resume(MapCache.dynamicPropBake.co)
            if not ok then
                ErrorNoHaltWithStack(err)
                MapCache.destroyMeshList(MapCache.dynamicPropBake.pendingMeshes)
                MapCache.dynamicPropBake.pendingMeshes = nil
                MapCache.dynamicPropBake.co = nil
                MapCache.dynamicPropBake.state = 'ready'
                MapCache.dynamicPropBake.nextScan = SysTime() + DYNAMIC_PROP_SCAN_INTERVAL
                return
            end
            if coroutine_status(MapCache.dynamicPropBake.co) == 'dead' then
                MapCache.destroyMeshList(MapCache.dynamicPropBake.meshes)
                MapCache.dynamicPropBake.meshes = MapCache.dynamicPropBake.pendingMeshes or {}
                MapCache.dynamicPropBake.signature = MapCache.dynamicPropBake.pendingSignature
                MapCache.dynamicPropBake.props = MapCache.dynamicPropBake.pendingProps or 0
                MapCache.dynamicPropBake.outputVerts = MapCache.dynamicPropBake.pendingVerts or 0
                MapCache.dynamicPropBake.pendingMeshes = nil
                MapCache.dynamicPropBake.pendingSignature = nil
                MapCache.dynamicPropBake.co = nil
                MapCache.dynamicPropBake.state = 'ready'
                MapCache.dynamicPropBake.nextScan = SysTime() + DYNAMIC_PROP_SCAN_INTERVAL
                MsgC(Color(120, 200, 255), string.format(
                    '[holo_table] prop_dynamic bake ready: props=%d meshes=%d verts=%d\n',
                    MapCache.dynamicPropBake.props or 0,
                    MapCache.dynamicPropBake.meshes and #MapCache.dynamicPropBake.meshes or 0,
                    MapCache.dynamicPropBake.outputVerts or 0))
            end
            return
        end

        if SysTime() < (MapCache.dynamicPropBake.nextScan or 0) then return end
        MapCache.dynamicPropBake.nextScan = SysTime() + DYNAMIC_PROP_SCAN_INTERVAL
        local snapshot, signature = dynamicPropSnapshot()
        if signature ~= MapCache.dynamicPropBake.signature then
            startDynamicPropBake(snapshot, signature)
        end
    end)
end


-- Builds per-material IMesh batches of the BSP geometry that survives
-- clipping against the holographic cylinder volume. The cylinder lives at
local PROP_DRAW_SCRATCH_POS = MapCache.PROP_DRAW_SCRATCH_POS
local PROP_DRAW_SCRATCH_ANG = MapCache.PROP_DRAW_SCRATCH_ANG

-- Hot-loop math locals: avoids per-call global table lookups in the
-- per-prop Euler-decomposition path.
local atan2   = math_atan2
local sin     = math_sin
local cos     = math_cos
local sqrt    = math_sqrt
local DEG2RAD = math_pi / 180
local RAD2DEG = 180 / math_pi

local DYN_PROP_CACHE_TTL = 1.0

local function makeDynamicPropMirror(model)
    local cs = ents.CreateClientProp(model)
    if not IsValid(cs) then return nil end
    cs:SetNoDraw(true)
    cs:SetSolid(SOLID_NONE)
    cs:SetMoveType(MOVETYPE_NONE)
    cs:PhysicsDestroy()
    return cs
end

local function deferredRemoveEntity(ent)
    if not IsValid(ent) then return end
    timer.Simple(0, function()
        if IsValid(ent) then SafeRemoveEntity(ent) end
    end)
end

function ENT:CleanupDynamicProps()
    local selfTbl = self:GetTable()
    if not selfTbl.DynamicPropMirrors then return end
    for _, rec in pairs(selfTbl.DynamicPropMirrors) do
        if rec.csent then SafeRemoveEntity(rec.csent) end
    end
    selfTbl.DynamicPropMirrors = nil
    selfTbl.DynamicPropMirrorTime = nil
end

local function refreshDynamicPropMirrors(self, onlyUnbaked)
    local selfTbl = self:GetTable()
    if selfTbl.DynamicPropMirrors and SysTime() - (selfTbl.DynamicPropMirrorTime or 0) < DYN_PROP_CACHE_TTL then
        return selfTbl.DynamicPropMirrors
    end

    local fresh = {}
    local old = selfTbl.DynamicPropMirrors or {}
    local unbaked = MapCache.dynamicPropBake and MapCache.dynamicPropBake.unbaked
    for _, rec in pairs(old) do
        local keep = IsValid(rec.ent)
            and (not onlyUnbaked or (unbaked and unbaked[rec.ent:EntIndex()]))
        if keep then
            fresh[rec.ent:EntIndex()] = rec
        elseif rec.csent then
            deferredRemoveEntity(rec.csent)
        end
    end

    for _, ent in ents.Iterator() do
        if ent:GetClass() ~= 'prop_dynamic' then continue end
        if onlyUnbaked and not (unbaked and unbaked[ent:EntIndex()]) then continue end
        local idx = ent:EntIndex()
        local rec = fresh[idx]
        local model = ent:GetModel()
        if not model or model == '' then
            if rec and rec.csent then deferredRemoveEntity(rec.csent) end
            fresh[idx] = nil
            continue
        end
        if not rec or rec.model ~= model then
            if rec and rec.csent then deferredRemoveEntity(rec.csent) end
            local cs = makeDynamicPropMirror(model)
            if cs then
                fresh[idx] = { ent = ent, csent = cs, model = model }
            else
                fresh[idx] = nil
            end
        end
    end

    selfTbl.DynamicPropMirrors = fresh
    selfTbl.DynamicPropMirrorTime = SysTime()
    return fresh
end

-- Draws baked prop_dynamic map dressing inside the holo scene matrix.
-- The global GPU clip prism crops zoomed/partial views, so the baked path
-- can replace the per-prop ClientsideModel fallback outside all-in views too.
-- Returns true when the baked path handled the prop_dynamic layer this
-- frame, even if there are zero props; callers use this to skip the csent
-- fallback outside the matrix.
function ENT:DrawBakedDynamicProps()
    if not dynamicPropBakeCvar:GetBool() then return false end
    if not self:GetMap() then return false end
    if not MapCache.dynamicPropBake or MapCache.dynamicPropBake.gen ~= CACHE_GENERATION then
        MapCache.startDynamicPropBakeWatch()
        return true
    end
    if MapCache.dynamicPropBake.state ~= 'ready' or not MapCache.dynamicPropBake.meshes then return true end

    render.SuppressEngineLighting(true)
    local ok, err = pcall(function()
        for _, item in ipairs(MapCache.dynamicPropBake.meshes) do
            if item.mesh then
                render_SetMaterial(item.mat)
                item.mesh:Draw()
            end
        end
    end)
    render.SuppressEngineLighting(false)

    if not ok then
        ErrorNoHaltWithStack('[holo_table] DrawBakedDynamicProps aborted: ' .. tostring(err))
        MapCache.destroyDynamicPropBake()
        return false
    end

    return true
end

-- Legacy prop_dynamic fallback. This mirrors the old radar module's
-- ClientsideModel path and is used for disabled bake or individual
-- moving/unbaked props. While the async map-owned bake is rebuilding, the
-- baked path suppresses this fallback for stable props.
function ENT:DrawDynamicProps(onlyUnbaked)
    local mirrors = refreshDynamicPropMirrors(self, onlyUnbaked)
    if not mirrors then return end

    local selfTbl = self:GetTable()
    local invScale = selfTbl._holoInvScale
    local toX, toY, toZ = selfTbl._holoOx, selfTbl._holoOy, selfTbl._holoOz
    local tFx, tFy, tFz = selfTbl._holoFx, selfTbl._holoFy, selfTbl._holoFz
    local tRx, tRy, tRz = selfTbl._holoRx, selfTbl._holoRy, selfTbl._holoRz
    local tUx, tUy, tUz = selfTbl._holoUx, selfTbl._holoUy, selfTbl._holoUz
    local scratchPos = PROP_DRAW_SCRATCH_POS
    local scratchAng = PROP_DRAW_SCRATCH_ANG

    render.SuppressEngineLighting(true)
    for _, rec in pairs(mirrors) do
        local ent, csent = rec.ent, rec.csent
        if not (IsValid(ent) and IsValid(csent)) then continue end

        if csent:GetSkin() ~= ent:GetSkin() then csent:SetSkin(ent:GetSkin()) end

        local pos = ent:GetPos()
        local lx, ly, lz = pos.x * invScale, pos.y * invScale, pos.z * invScale
        scratchPos:SetUnpacked(
            toX + tFx * lx - tRx * ly + tUx * lz,
            toY + tFy * lx - tRy * ly + tUy * lz,
            toZ + tFz * lx - tRz * ly + tUz * lz)

        local ang = ent:GetAngles()
        local sp, cp = sin(ang.p * DEG2RAD), cos(ang.p * DEG2RAD)
        local sy, cy = sin(ang.y * DEG2RAD), cos(ang.y * DEG2RAD)
        local sr, cr = sin(ang.r * DEG2RAD), cos(ang.r * DEG2RAD)
        local pFx, pFy, pFz =  cp * cy,                 cp * sy,                 -sp
        local pRx, pRy, pRz = -sr * sp * cy + cr * sy, -sr * sp * sy - cr * cy, -sr * cp
        local pUx, pUy, pUz =  cr * sp * cy + sr * sy,  cr * sp * sy - sr * cy,  cr * cp

        local wFx = tFx * pFx - tRx * pFy + tUx * pFz
        local wFy = tFy * pFx - tRy * pFy + tUy * pFz
        local wFz = tFz * pFx - tRz * pFy + tUz * pFz
        local wRz = tFz * pRx - tRz * pRy + tUz * pRz
        local wUz = tFz * pUx - tRz * pUy + tUz * pUz
        scratchAng:SetUnpacked(
            atan2(-wFz, sqrt(wFx * wFx + wFy * wFy)) * RAD2DEG,
            atan2(wFy, wFx) * RAD2DEG,
            atan2(-wRz, wUz) * RAD2DEG)

        csent:SetPos(scratchPos)
        csent:SetAngles(scratchAng)
        csent:SetModelScale(invScale, 0)
        csent:SetupBones()
        csent:DrawModel()
    end
    render.SuppressEngineLighting(false)
end

-- Draws the shared baked static-prop mesh list. Returns true only when
-- it actually handled props this frame so cl_init can skip the legacy
-- per-prop ClientsideModel path. The caller has already pushed the holo
-- scene matrix and enabled the GPU clip prism.
