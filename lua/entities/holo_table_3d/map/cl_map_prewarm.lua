local MapCache = ENT.MapCache
local SysTime = SysTime
local bit_band = bit.band
local math_sqrt = math.sqrt
local coroutine_create = coroutine.create
local coroutine_yield = coroutine.yield
local coroutine_resume = coroutine.resume
local coroutine_status = coroutine.status
local hook_Add = hook.Add
local hook_Remove = hook.Remove
local CACHE_GENERATION = MapCache.CACHE_GENERATION
local SURF_SKIP_MASK = MapCache.SURF_SKIP_MASK
local getMatByTexinfo = MapCache.getMatByTexinfo
local resolveMat = MapCache.resolveMat
local resolveProj = MapCache.resolveProj
local getPropBounds = MapCache.getPropBounds
local PREWARM_BUDGET_IDLE = 0.006
local prewarmHookName      = 'holo_table_3d.tri_cache_prewarm'
local prewarmCo            = nil
local prewarmGen           = nil

--- True if any holo_table_3d has an active build coroutine.
--- @return boolean
local function anyClipCoroutineActive()
    for _, e in ipairs(ents.FindByClass('holo_table_3d')) do
        if e.ClipCoroutine then return true end
    end
    return false
end
MapCache.anyClipCoroutineActive = anyClipCoroutineActive

--- Background coroutine that walks every worldspawn face once per
--- CACHE_GENERATION and populates face._holoCull / face._holoTris.
--- Yields entirely while a user-visible build coroutine is running.
function MapCache.startTriCachePrewarm()
    if not (bsp2 and bsp2.GetCurrent()) then return end
    if prewarmCo and prewarmGen == CACHE_GENERATION then return end

    prewarmGen = CACHE_GENERATION
    prewarmCo = coroutine_create(function()
        local bsp = bsp2.GetCurrent()
        local faces = bsp.models and bsp.models[1] and bsp.models[1].faces or bsp.faces
        if not faces then return end
        local nFaces = #faces
        -- Shared cell so getMatByTexinfo and the per-face loops observe one budget window.
        local deadlineCell = { SysTime() + PREWARM_BUDGET_IDLE }
        local function deadlineFn() return deadlineCell[1] end
        local function bumpDeadline() deadlineCell[1] = SysTime() + PREWARM_BUDGET_IDLE end

        -- Phase 0: spread the ~250 ms texinfo->material lookup over multiple frames.
        getMatByTexinfo(deadlineFn, bumpDeadline)
        bumpDeadline()

        -- Phase 1: cull data for every face.
        for fi = 1, nFaces do
            if SysTime() > deadlineCell[1] then
                coroutine_yield()
                bumpDeadline()
            end
            local face = faces[fi]
            local tinfo = face.texinfo
            if not tinfo then continue end
            if bit_band(tinfo.flags or 0, SURF_SKIP_MASK) ~= 0 then continue end
            local edges = face.edges
            if not edges or #edges < 3 then continue end
            if face._holoCull and face._holoCull.cx then continue end

            local n = #edges
            local sx, sy, sz = 0, 0, 0
            for ei = 1, n do
                local v = edges[ei][1]
                sx = sx + v.x; sy = sy + v.y; sz = sz + v.z
            end
            local invN = 1 / n
            local cx, cy, cz = sx * invN, sy * invN, sz * invN
            local r2max = 0
            for ei = 1, n do
                local v = edges[ei][1]
                local dx, dy, dz = v.x - cx, v.y - cy, v.z - cz
                local d2 = dx * dx + dy * dy + dz * dz
                if d2 > r2max then r2max = d2 end
            end
            face._holoCull = { cx = cx, cy = cy, cz = cz, fr = math_sqrt(r2max) }
        end

        -- Phase 2: tri data; resolveMat is cached per tinfo.
        local matByTexinfo = getMatByTexinfo(deadlineFn, bumpDeadline) or {}
        for fi = 1, nFaces do
            if SysTime() > deadlineCell[1] then
                coroutine_yield()
                bumpDeadline()
            end
            local face = faces[fi]
            local tinfo = face.texinfo
            if not tinfo then continue end
            if bit_band(tinfo.flags or 0, SURF_SKIP_MASK) ~= 0 then continue end
            local edges = face.edges
            if not edges or #edges < 3 then continue end

            local tcache = face._holoTris
            if tcache and tcache.gen == CACHE_GENERATION then continue end
            local mat, skip = resolveMat(tinfo, matByTexinfo)
            if skip then
                face._holoTris = { skip = true, gen = CACHE_GENERATION }
            else
                local btn = mat:GetTexture('$basetexture')
                local matKey = btn and btn:GetName() or mat:GetName()
                local proj = resolveProj(tinfo)
                local sv, tv = proj.sv, proj.tv
                local sw, tw = proj.sw, proj.tw
                local invW, invH = proj.invW, proj.invH
                local normal = face.plane.normal
                if face.side and face.side ~= 0 then normal = -normal end
                local n = #edges
                local tris = {}
                local a = edges[1][1]
                local ua = (a:Dot(sv) + sw) * invW
                local va = (a:Dot(tv) + tw) * invH
                for vi = 2, n - 1 do
                    local b, c = edges[vi][1], edges[vi + 1][1]
                    local ub = (b:Dot(sv) + sw) * invW
                    local vb = (b:Dot(tv) + tw) * invH
                    local uc = (c:Dot(sv) + sw) * invW
                    local vc = (c:Dot(tv) + tw) * invH
                    tris[#tris + 1] = { pos = a, normal = normal, u = ua, v = va }
                    tris[#tris + 1] = { pos = b, normal = normal, u = ub, v = vb }
                    tris[#tris + 1] = { pos = c, normal = normal, u = uc, v = vc }
                end
                face._holoTris = {
                    matKey = matKey, mat = mat,
                    tris = tris, triCount = #tris,
                    gen = CACHE_GENERATION,
                }
            end
        end
    end)

    hook_Add('Think', prewarmHookName, function()
        if not prewarmCo or prewarmGen ~= CACHE_GENERATION then
            prewarmCo = nil
            hook_Remove('Think', prewarmHookName)
            return
        end
        if anyClipCoroutineActive() then return end

        local ok, err = coroutine_resume(prewarmCo)
        if not ok then
            ErrorNoHaltWithStack(err)
            prewarmCo = nil
            hook_Remove('Think', prewarmHookName)
            return
        end
        if coroutine_status(prewarmCo) == 'dead' then
            prewarmCo = nil
            hook_Remove('Think', prewarmHookName)
        end
    end)
end

local propPrewarmHookName = 'holo_table_3d.prop_prewarm'
local propPrewarmCo       = nil
local propPrewarmGen      = nil

--- Touches every unique static-prop model once via getPropBounds. Without
--- this, lazy model loads inside DrawStaticProps cause 80-90 ms hitches
--- the first time a previously-unseen prop renders.
function MapCache.startPropPrewarm()
    local bsp = bsp2 and bsp2.GetCurrent()
    if not bsp or not bsp.props then return end
    if propPrewarmCo and propPrewarmGen == CACHE_GENERATION then return end

    propPrewarmGen = CACHE_GENERATION
    propPrewarmCo = coroutine_create(function()
        local props = bsp.props
        local seen = {}
        local deadline = SysTime() + PREWARM_BUDGET_IDLE
        for i = 1, #props do
            local model = props[i] and props[i].model
            if not model or seen[model] then continue end
            seen[model] = true
            getPropBounds(model)
            if SysTime() > deadline then
                coroutine_yield()
                deadline = SysTime() + PREWARM_BUDGET_IDLE
            end
        end
    end)

    hook_Add('Think', propPrewarmHookName, function()
        if not propPrewarmCo or propPrewarmGen ~= CACHE_GENERATION then
            propPrewarmCo = nil
            hook_Remove('Think', propPrewarmHookName)
            return
        end
        if anyClipCoroutineActive() then return end
        local ok, err = coroutine_resume(propPrewarmCo)
        if not ok then
            ErrorNoHaltWithStack(err)
            propPrewarmCo = nil
            hook_Remove('Think', propPrewarmHookName)
            return
        end
        if coroutine_status(propPrewarmCo) == 'dead' then
            propPrewarmCo = nil
            hook_Remove('Think', propPrewarmHookName)
        end
    end)
end

function MapCache.cleanupPrewarm()
    hook_Remove('Think', prewarmHookName)
    prewarmCo = nil
    prewarmGen = nil

    hook_Remove('Think', propPrewarmHookName)
    propPrewarmCo = nil
    propPrewarmGen = nil
end
