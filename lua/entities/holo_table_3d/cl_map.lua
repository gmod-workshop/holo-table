-- Map subsystem: BSP geometry clipped against the holographic
-- cylinder, brush entities, static props, and the auto-center solver.
-- Lifecycle hooks driven from cl_init.lua: InitializeMap, CleanupMap.
-- Per-frame entry points on ENT: TickMapBuild (kicks/advances the
-- async clipper), DrawMap, DrawClippedMap, DrawBrushEntities,
-- DrawStaticProps, ComputeAutoCenter. The Draw* methods read the
-- per-frame hologram transform from self._holo* (staged by
-- ENT:UpdateHologramTransform in cl_init.lua), so they take no params.

local previousCleanup = _G.HOLO_TABLE_3D_CL_MAP_CLEANUP
if type(previousCleanup) == 'function' then
    local ok, err = pcall(previousCleanup)
    if not ok then ErrorNoHaltWithStack(err) end
end
_G.HOLO_TABLE_3D_CL_MAP_CLEANUP = nil

-- Forward declaration: the prewarm driver (defined further down once
-- its dependencies -- resolveMat, resolveProj, getMatByTexinfo, the
-- cull/tri builders -- are in scope) is invoked from InitializeMap.
local startTriCachePrewarm
local startPropPrewarm
local startStaticPropBake
local startStaticPropPerPropBake
local startDynamicPropBakeWatch
local staticPropBakeModeCvar

local SysTime = SysTime
local Vector = Vector
local Material = Material
local Mesh = Mesh
local bit_band = bit.band
local table_move = table.move
local math_sin = math.sin
local math_cos = math.cos
local math_atan2 = math.atan2
local math_sqrt = math.sqrt
local math_min = math.min
local math_max = math.max
local math_ceil = math.ceil
local math_pi = math.pi
local coroutine_create = coroutine.create
local coroutine_yield = coroutine.yield
local coroutine_resume = coroutine.resume
local coroutine_status = coroutine.status
local hook_Add = hook.Add
local hook_Remove = hook.Remove
local render_SetMaterial = render.SetMaterial

function ENT:InitializeMap()
    -- Cold first-build cost on big maps is dominated by per-face
    -- triangulation: ~300 ms of Lua-side work building face._holoTris
    -- entries the first time the cylinder culler walks worldspawn.
    -- That data is independent of scale/height/pan, so kick a global
    -- background coroutine the moment any holo_table_3d is initialised
    -- to populate it ahead of time. Subsequent first-builds (this
    -- entity or any sibling) skip the 300 ms and run at warm cost.
    startTriCachePrewarm()
    -- The first time a static prop is rendered the engine syncs in its
    -- model and material data, producing 80-90 ms hitches inside
    -- DrawStaticProps (visible as occasional FPS spikes when the table
    -- starts displaying a previously-unseen part of the map). Touching
    -- every unique model once at init time forces the load up front.
    startPropPrewarm()
    -- A shared static-prop bake replaces thousands of per-frame
    -- ClientsideModel DrawModel calls with material-batched IMesh draws.
    -- Mode 3 keeps that path active for zoomed views too and lets the
    -- existing GPU clip prism trim the oversized bake.
    local staticMode = staticPropBakeModeCvar:GetInt()
    if staticMode == 2 then
        startStaticPropPerPropBake(self:GetScale())
    elseif staticMode == 3 or self:CylinderHorizContainsMap(self:GetScale(), self:GetPanX(), self:GetPanY()) then
        startStaticPropBake(self:GetScale())
    end
    startDynamicPropBakeWatch()
end

function ENT:CleanupMap()
    self.ClipCoroutine = nil
    self:DestroyPendingBuild()
    self:DestroyClippedMap()
    self:DestroyAllInCache()
    self:CleanupDynamicProps()
end

-- Lazy async re-clip when parameters change. The current
-- ClippedMeshes (possibly stale-scale) keeps rendering until the new
-- build completes, so dragging the editor sliders never stutters; the
-- unclipped fallback in DrawMap covers the very first frames before
-- any build finishes.
--
-- Two policies keep slider drags responsive when auto-center has fit
-- the cylinder tight (so every change is a real rebuild, not an
-- all-in cache hit):
--   1. Debounce: don't kick off a build while parameters are still
--      changing. Wait until they have been stable for ~150 ms. The
--      first-ever build is exempt so the initial render isn't delayed.
--   2. Don't preempt: never abandon an in-flight coroutine just
--      because parameters changed since it started. Let it finish, and
--      a fresh build will be triggered next frame if the result is
--      already stale.
function ENT:TickMapBuild()
    if not (bsp2 and bsp2.GetCurrent()) then return end

    local scale = self:GetScale()
    local height = self:GetHeight()
    local panX = self:GetPanX()
    local panY = self:GetPanY()

    local stale = self.ClippedScale ~= scale or self.ClippedHeight ~= height
        or self.ClippedPanX ~= panX or self.ClippedPanY ~= panY

    if self.RebuildTargetScale ~= scale or self.RebuildTargetHeight ~= height
        or self.RebuildTargetPanX ~= panX or self.RebuildTargetPanY ~= panY then
        self.RebuildTargetScale = scale
        self.RebuildTargetHeight = height
        self.RebuildTargetPanX = panX
        self.RebuildTargetPanY = panY
        self.RebuildTargetTime = SysTime()
    end

    local stable = SysTime() - (self.RebuildTargetTime or 0) > 0.15
    local firstBuild = not self.ClippedMeshes
    if stale and not self.ClipCoroutine and (stable or firstBuild) then
        self:StartClippedBuild()
    end
    if self.ClipCoroutine then
        self:TickClippedBuild()
    end
end

local filter = {
    ['color/white'] = true,
    ['error'] = true
}

-- Per-model bounding-sphere {center, radius} in model-local space, plus
-- reusable ClientsideModel draw entities for the legacy fallback path.
-- Shared across all holo_table_3d entities; entries are populated lazily
-- on first use and live until hot-reload cleanup.
local propBoundsCache = {}
local propEntCache = {}

local staticPropBakeCvar = CreateClientConVar('holo_table_staticprop_bake', '1', true, false,
    'Use baked static-prop meshes for all-in holo table views.')
staticPropBakeModeCvar = CreateClientConVar('holo_table_staticprop_bake_mode', '3', true, false,
    'Static prop bake mode: 0 legacy, 1 global all-in bake, 2 per-prop baked cull, 3 global GPU-clipped bake.')
local dynamicPropBakeCvar = CreateClientConVar('holo_table_dynamicprop_bake', '1', true, false,
    'Use baked prop_dynamic meshes for all-in holo table views.')

-- Sub-pixel cull threshold in holo units (table-local space). At typical
-- viewing distances 1 holo unit ≈ 2 screen pixels, so 0.5 ≈ 1 px. Any
-- prop whose post-scale diagonal falls below this is too small to be
-- visually significant and can be skipped. Shared by the legacy prop
-- renderer and the scale-specific baked all-in renderer.
local PROP_SUBPIXEL_THRESHOLD = 0.5

local function getPropBounds(name)
    local b = propBoundsCache[name]
    if b then return b end
    local info = util.GetModelInfo(name)
    if info and info.HullMin and info.HullMax then
        local mins, maxs = info.HullMin, info.HullMax
        b = {
            center = (mins + maxs) * 0.5,
            radius = (maxs - mins):Length() * 0.5,
        }
    else
        local cs = ClientsideModel(name)
        if IsValid(cs) then
            local mins, maxs = cs:GetModelBounds()
            b = {
                center = (mins + maxs) * 0.5,
                radius = (maxs - mins):Length() * 0.5,
            }
            cs:SetNoDraw(true)
            propEntCache[name] = cs
        else
            b = { center = vector_origin, radius = 0 }
        end
    end
    propBoundsCache[name] = b
    return b
end

local function getPropDrawEnt(name)
    local cs = propEntCache[name]
    if IsValid(cs) then return cs end
    cs = ClientsideModel(name)
    if IsValid(cs) then
        cs:SetNoDraw(true)
        propEntCache[name] = cs
        return cs
    end
    return nil
end

local function cleanupPropEntCache()
    for model, cs in pairs(propEntCache) do
        if IsValid(cs) then SafeRemoveEntity(cs) end
        propEntCache[model] = nil
    end
    propBoundsCache = {}
end

-- Sutherland–Hodgman clip of a convex polygon against the half-space
-- `pos:Dot(n) <= d`. Returns the input poly unchanged when every vertex
-- already satisfies the half-space (Common Halfspace trivial-accept), the
-- shared `clipEmptyPoly` when every vertex is outside, otherwise a fresh
-- list. Inputs are left untouched. The distance scan is performed once
-- into `clipDistScratch` so the clip pass below can reuse it without
-- recomputing dot products.
local clipDistScratch = {}
local clipEmptyPoly = {}
local function clipPolygonPlane(poly, n, d)
    local count = #poly
    if count == 0 then return poly end

    local nx, ny, nz = n.x, n.y, n.z
    local allIn, allOut = true, true
    for i = 1, count do
        local v = poly[i]
        local dist = v.x * nx + v.y * ny + v.z * nz - d
        clipDistScratch[i] = dist
        if dist > 0 then allIn = false
        else allOut = false end
    end

    if allIn then return poly end
    if allOut then return clipEmptyPoly end

    local out = {}
    local prev = poly[count]
    local prevDist = clipDistScratch[count]
    local prevInside = prevDist <= 0

    for i = 1, count do
        local curr = poly[i]
        local currDist = clipDistScratch[i]
        local currInside = currDist <= 0

        if currInside then
            if not prevInside then
                local t = prevDist / (prevDist - currDist)
                out[#out + 1] = prev + (curr - prev) * t
            end
            out[#out + 1] = curr
        elseif prevInside then
            local t = prevDist / (prevDist - currDist)
            out[#out + 1] = prev + (curr - prev) * t
        end

        prev = curr
        prevDist = currDist
        prevInside = currInside
    end

    return out
end

-- Surface flags we never want to render (sky, nodraw, skip).
local SURF_SKIP_MASK = bit.bor(0x2, 0x4, 0x80, 0x200)

-- Some BSP texdata entries store the material with a stray leading slash
-- (e.g. "/FIRSTORDERBANNER"); Material() returns the error material on
-- those and the resulting "error" basetexture gets dropped by `filter`,
-- silently hiding those brush faces. Strip the slash and retry.
local function loadTexdataMaterial(name)
    local m = Material(name)
    if m:IsError() and name:sub(1, 1) == '/' then
        m = Material(name:sub(2))
    end
    return m
end

-- MaterialVarFlags bits we care about propagating from the source
-- LightmappedGeneric onto the holo wrapper. Source materials that set
-- these (commonly via the engine auto-detecting alpha in the .vtf, not
-- via an explicit $translucent/$alphatest VMT key) need the flag carried
-- across or transparent textures (glass, fences, foliage) come through
-- as solid black: their RGB usually only encodes a tint/reflection and
-- the actual transparency lives in the alpha channel.
local MATFLAG_ALPHATEST   = 0x100
local MATFLAG_TRANSLUCENT = 0x200000

-- Wraps `src`'s $basetexture in a runtime UnlitGeneric so the holo pass can
-- render it without a lightmap. Used when the adapter-generated fallback for
-- a given texinfo carries the error texture (typically because the BSP
-- texdata path was malformed), and to rebuild a translucent/alphatest
-- variant when the generated UnlitGeneric drops those flags.
local unlitWrapCache = {}
local function unlitWrap(src, translucent, alphaTest)
    local btn = src:GetTexture('$basetexture')
    if not btn then return src end
    local key = btn:GetName()
    local cacheKey = key
    if translucent then cacheKey = cacheKey .. '|t' end
    if alphaTest   then cacheKey = cacheKey .. '|a' end
    local m = unlitWrapCache[cacheKey]
    if m then return m end
    local kv = {
        ['$basetexture'] = key,
        ['$model'] = '0',
        ['$vertexcolor'] = '1',
    }
    if translucent then kv['$translucent'] = '1' end
    if alphaTest   then kv['$alphatest']   = '1' end
    m = CreateMaterial('holo_table_unlit_' .. util.CRC(cacheKey), 'UnlitGeneric', kv)
    unlitWrapCache[cacheKey] = m
    return m
end

-- How long a single coroutine.resume of the async build is allowed to run
-- before yielding back to the main thread.
local CLIP_FRAME_BUDGET = 0.004

-- Bumped on every file load so per-face triangulation caches
-- (`face._holoTris`) that hold resolved material refs are invalidated
-- when this file is hot-reloaded; otherwise material-resolution code
-- changes only take effect on the next map load. SysTime() is unique
-- per load and cheap.
local CACHE_GENERATION = SysTime()

-- Per-tinfo caches (resolved material, skip flag, unpacked textureVecs)
-- shared by BuildClippedMap and the background tri-cache prewarm. Keyed
-- by tinfo identity, gen-stamped against CACHE_GENERATION so a hot
-- reload purges them lazily on next access.
--- @type { gen: number, [Face]: IMaterial }
local matCacheGlobal     = { gen = CACHE_GENERATION }
local skipCacheGlobal    = { gen = CACHE_GENERATION }
local projCacheGlobal    = { gen = CACHE_GENERATION }
local function checkCacheGen()
    if matCacheGlobal.gen ~= CACHE_GENERATION then
        matCacheGlobal  = { gen = CACHE_GENERATION }
        skipCacheGlobal = { gen = CACHE_GENERATION }
        projCacheGlobal = { gen = CACHE_GENERATION }
    end
end

local function resolveMat(tinfo, matByTexinfo)
    checkCacheGen()
    local m = matCacheGlobal[tinfo]
    if m ~= nil then return m, skipCacheGlobal[tinfo] end
    local src = loadTexdataMaterial(tinfo.texdata.material)
    m = src
    if m:GetShader() == 'LightmappedGeneric' then
        local srcFlags = src:GetInt('$flags') or 0
        local trans     = bit_band(srcFlags, MATFLAG_TRANSLUCENT) ~= 0
        local alphaTest = bit_band(srcFlags, MATFLAG_ALPHATEST)   ~= 0
        local fb = matByTexinfo[tostring(tinfo) .. '_texinfo']
        local fbBtn = fb and fb:GetTexture('$basetexture')
        local fbOk = fbBtn and not filter[fbBtn:GetName()]
        if trans or alphaTest then
            m = unlitWrap(fbOk and fb or src, trans, alphaTest)
        elseif fbOk then
            m = fb
        else
            m = unlitWrap(src)
        end
    end
    local btn = m:GetTexture('$basetexture')
    local skip = btn and filter[btn:GetName()] or false
    matCacheGlobal[tinfo], skipCacheGlobal[tinfo] = m, skip
    return m, skip
end

local function resolveProj(tinfo)
    checkCacheGen()
    local p = projCacheGlobal[tinfo]
    if p then return p end
    local s, t = tinfo.textureVecs.s, tinfo.textureVecs.t
    p = {
        sv = Vector(s.x, s.y, s.z), sw = s.w,
        tv = Vector(t.x, t.y, t.z), tw = t.w,
        invW = 1 / tinfo.texdata.width,
        invH = 1 / tinfo.texdata.height,
    }
    projCacheGlobal[tinfo] = p
    return p
end

-- The NikNaks adapter emits one UnlitGeneric material per texinfo (named
-- `<tinfo>_texinfo`) and exposes them via mi.materials. We need a
-- name->material lookup to fall back from LightmappedGeneric world
-- materials. Building that lookup is
-- O(materials) and on big maps (rp_venator: 5934 entries) costs ~250 ms --
-- entirely in :GetName() calls into engine code, so we can't avoid the work,
-- only chunk it. Cache is keyed by the mi.materials table identity so
-- rebuilds only happen when the adapter swaps the list.
--
-- When called from a coroutine context (the user-visible build path or
-- the prewarm), the build is yieldable: pass `deadlineFn`/`bumpFn` and
-- the loop yields whenever the current frame budget is exhausted.
-- When called outside a coroutine (no callbacks), the work runs
-- synchronously and shows up as a single-frame hitch -- callers in the
-- hot path always wrap it.
local matByTexinfoCache = nil
local matByTexinfoSrc = nil
local function getMatByTexinfo(deadlineFn, bumpFn)
    local mi = bsp2 and bsp2.GetModelInfo()
    local mats = mi and mi.materials
    if not mats then return nil end
    if mats == matByTexinfoSrc then return matByTexinfoCache end
    local out = {}
    if deadlineFn and bumpFn then
        for i = 1, #mats do
            if SysTime() > deadlineFn() then
                coroutine_yield()
                bumpFn()
            end
            local m = mats[i]
            out[m:GetName()] = m
        end
    else
        for i = 1, #mats do
            local m = mats[i]
            out[m:GetName()] = m
        end
    end
    matByTexinfoCache = out
    matByTexinfoSrc = mats
    return out
end

-- Background coroutine that walks every worldspawn face once per
-- CACHE_GENERATION and populates `face._holoCull` and `face._holoTris`.
-- Two phases:
--   1. Cull-only: ~50 ms total on rp_venator (~2.3 us/face). Once
--      done, BuildClippedMap's cylinder cull can fast-reject any face
--      whose cached centroid+radius lies outside the cylinder, without
--      ever touching tri data. This is the cheapest unlock and we want
--      it finished quickly.
--   2. Tri data: same per-face work the build path's fast-accept does.
--      Heavier (~3 us/face plus material resolution) but only matters
--      for faces inside the cylinder.
--
-- Driven by a Think hook with an adaptive budget: when no holo_table_3d
-- has an active clip coroutine, we use a generous slice (~6 ms);
-- otherwise we yield entirely so the user-visible build always wins.
local PREWARM_BUDGET_IDLE = 0.006 -- 6 ms per frame when nothing else is building
local prewarmHookName      = 'holo_table_3d.tri_cache_prewarm'
local prewarmCo            = nil
local prewarmGen           = nil

local function anyClipCoroutineActive()
    for _, e in ipairs(ents.FindByClass('holo_table_3d')) do
        if e.ClipCoroutine then return true end
    end
    return false
end

function startTriCachePrewarm()
    if not (bsp2 and bsp2.GetCurrent()) then return end
    if prewarmCo and prewarmGen == CACHE_GENERATION then return end

    prewarmGen = CACHE_GENERATION
    prewarmCo = coroutine_create(function()
        local bsp = bsp2.GetCurrent()
        local faces = bsp.models and bsp.models[1] and bsp.models[1].faces or bsp.faces
        if not faces then return end
        local nFaces = #faces
        -- Shared deadline cell so the yieldable matByTexinfo builder
        -- and the per-face loops below all observe the same budget
        -- window and reset it consistently after each yield.
        local deadlineCell = { SysTime() + PREWARM_BUDGET_IDLE }
        local function deadlineFn() return deadlineCell[1] end
        local function bumpDeadline() deadlineCell[1] = SysTime() + PREWARM_BUDGET_IDLE end

        -- Phase 0: build the texinfo->material lookup. Unavoidable
        -- :GetName() call for every entry in the adapter material list, so
        -- on big maps this is ~250 ms of work and would show up as a
        -- single hitch if BuildClippedMap had to do it on the user's
        -- first cold build. The yieldable variant spreads it over
        -- multiple frames here.
        getMatByTexinfo(deadlineFn, bumpDeadline)
        bumpDeadline()

        -- Phase 1: cull data for every face. Cheap, finishes in ~10
        -- frames at 6 ms/frame even on rp_venator.
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
                local d2 = dx*dx + dy*dy + dz*dz
                if d2 > r2max then r2max = d2 end
            end
            face._holoCull = { cx = cx, cy = cy, cz = cz, fr = math_sqrt(r2max) }
        end

        -- Phase 2: tri data for every face. Heavier; resolveMat does
        -- material lookups (cached per tinfo) and the inner loop emits
        -- the same per-vertex pos/normal/uv table the build path uses.
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
        -- Yield entirely while a user-visible build coroutine is
        -- running so we never compete for the same ms.
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

-- Touches every unique static-prop model on the map exactly once via
-- getPropBounds, which forces the engine to load model metadata without
-- creating a throwaway clientside entity. Without this, those loads happen
-- lazily inside DrawStaticProps and produce 80-90 ms hitches the first
-- time the table renders a previously-unseen prop. Cheap enough (~110
-- unique models on a dense map at sub-millisecond per touch) that we
-- run it as a single coroutine with a small per-frame budget.
local propPrewarmHookName = 'holo_table_3d.prop_prewarm'
local propPrewarmCo       = nil
local propPrewarmGen      = nil
function startPropPrewarm()
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

-- Shared static-prop bake. Static BSP props never move, so their model
-- triangles can be transformed into BSP space once and drawn under the
-- same holo scene matrix as the world mesh. Mode 3 keeps this global bake
-- active for zoomed views and lets the GPU clip prism trim it.
local STATIC_PROP_BAKE_HOOK = 'holo_table_3d.static_prop_bake'
local STATIC_PROP_PER_PROP_BAKE_HOOK = 'holo_table_3d.static_prop_per_prop_bake'
local STATIC_PROP_BAKE_FRAME_BUDGET = 0.006
local STATIC_PROP_BAKE_MAX_VERTS = 12000
local STATIC_PROP_BAKE_PER_VERT_SEC = 0.5e-6
local staticPropBake = nil
local staticPropPerPropBake = nil
local destroyMeshList

local function destroyStaticPropBake()
    hook_Remove('Think', STATIC_PROP_BAKE_HOOK)
    if staticPropBake and staticPropBake.meshes then
        for _, item in ipairs(staticPropBake.meshes) do
            if item.mesh then
                pcall(item.mesh.Destroy, item.mesh)
                item.mesh = nil
            end
        end
    end
    staticPropBake = nil
end

local function destroyStaticPropPerPropBake()
    hook_Remove('Think', STATIC_PROP_PER_PROP_BAKE_HOOK)
    if staticPropPerPropBake and staticPropPerPropBake.props then
        for _, rec in ipairs(staticPropPerPropBake.props) do
            destroyMeshList(rec.meshes)
        end
    end
    if staticPropPerPropBake and staticPropPerPropBake.pendingProps then
        for _, rec in ipairs(staticPropPerPropBake.pendingProps) do
            destroyMeshList(rec.meshes)
        end
    end
    if staticPropPerPropBake then
        destroyMeshList(staticPropPerPropBake.pendingMeshes)
    end
    staticPropPerPropBake = nil
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

function startStaticPropBake(scale)
    if not staticPropBakeCvar:GetBool() then return end
    local bsp = bsp2 and bsp2.GetCurrent()
    if not bsp or not bsp.props or #bsp.props == 0 then return end
    scale = tonumber(scale) or 0
    if scale <= 0 then return end
    if staticPropBake and staticPropBake.gen == CACHE_GENERATION
        and math.abs((staticPropBake.scale or 0) - scale) < 0.01
        and (staticPropBake.state == 'building' or staticPropBake.state == 'ready') then
        return
    end

    destroyStaticPropBake()
    local minRadius = PROP_SUBPIXEL_THRESHOLD / (2 / scale)
    staticPropBake = {
        gen = CACHE_GENERATION,
        state = 'building',
        scale = scale,
        minRadius = minRadius,
        meshes = {},
        props = #bsp.props,
        bakedProps = 0,
        outputVerts = 0,
    }

    staticPropBake.co = coroutine_create(function()
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
            local msh = Mesh()
            msh:BuildFromTriangles(verts)
            staticPropBake.meshes[#staticPropBake.meshes + 1] = { mat = group.mat, mesh = msh }
            staticPropBake.outputVerts = staticPropBake.outputVerts + n
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
            staticPropBake.bakedProps = staticPropBake.bakedProps + 1

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

        staticPropBake.state = 'ready'
    end)

    hook_Add('Think', STATIC_PROP_BAKE_HOOK, function()
        if not staticPropBake or staticPropBake.gen ~= CACHE_GENERATION then
            destroyStaticPropBake()
            return
        end
        if staticPropBake.state ~= 'building' then
            hook_Remove('Think', STATIC_PROP_BAKE_HOOK)
            return
        end
        if anyClipCoroutineActive() then return end

        local ok, err = coroutine_resume(staticPropBake.co)
        if not ok then
            ErrorNoHaltWithStack(err)
            destroyStaticPropBake()
            return
        end
        if coroutine_status(staticPropBake.co) == 'dead' then
            staticPropBake.co = nil
            if staticPropBake.state == 'building' then staticPropBake.state = 'ready' end
            hook_Remove('Think', STATIC_PROP_BAKE_HOOK)
            MsgC(Color(120, 200, 255), string.format(
                '[holo_table] Static prop bake ready: props=%d/%d scale=%.1f meshes=%d verts=%d\n',
                staticPropBake.bakedProps or 0,
                staticPropBake.props or 0,
                staticPropBake.scale or 0,
                staticPropBake.meshes and #staticPropBake.meshes or 0,
                staticPropBake.outputVerts or 0))
        end
    end)
end

function startStaticPropPerPropBake(scale)
    if not staticPropBakeCvar:GetBool() then return end
    local bsp = bsp2 and bsp2.GetCurrent()
    if not bsp or not bsp.props or #bsp.props == 0 then return end
    scale = tonumber(scale) or 0
    if scale <= 0 then return end
    if staticPropPerPropBake and staticPropPerPropBake.gen == CACHE_GENERATION
        and math.abs((staticPropPerPropBake.scale or 0) - scale) < 0.01
        and (staticPropPerPropBake.state == 'building' or staticPropPerPropBake.state == 'ready') then
        return
    end

    destroyStaticPropPerPropBake()
    local minRadius = PROP_SUBPIXEL_THRESHOLD / (2 / scale)
    staticPropPerPropBake = {
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

    staticPropPerPropBake.co = coroutine_create(function()
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
            local msh = Mesh()
            msh:BuildFromTriangles(verts)
            local item = { mat = group.mat, mesh = msh }
            meshes[#meshes + 1] = item
            staticPropPerPropBake.pendingMeshes[#staticPropPerPropBake.pendingMeshes + 1] = item
            staticPropPerPropBake.outputVerts = staticPropPerPropBake.outputVerts + n
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
                staticPropPerPropBake.pendingProps[#staticPropPerPropBake.pendingProps + 1] = rec
                staticPropPerPropBake.bakedProps = staticPropPerPropBake.bakedProps + 1
            end
        end

        staticPropPerPropBake.state = 'ready'
    end)

    hook_Add('Think', STATIC_PROP_PER_PROP_BAKE_HOOK, function()
        if not staticPropPerPropBake or staticPropPerPropBake.gen ~= CACHE_GENERATION then
            destroyStaticPropPerPropBake()
            return
        end
        if staticPropPerPropBake.state ~= 'building' then
            hook_Remove('Think', STATIC_PROP_PER_PROP_BAKE_HOOK)
            return
        end
        if anyClipCoroutineActive() then return end

        local ok, err = coroutine_resume(staticPropPerPropBake.co)
        if not ok then
            ErrorNoHaltWithStack(err)
            destroyStaticPropPerPropBake()
            return
        end
        if coroutine_status(staticPropPerPropBake.co) == 'dead' then
            staticPropPerPropBake.co = nil
            staticPropPerPropBake.props = staticPropPerPropBake.pendingProps or {}
            staticPropPerPropBake.pendingProps = nil
            staticPropPerPropBake.pendingMeshes = nil
            if staticPropPerPropBake.state == 'building' then staticPropPerPropBake.state = 'ready' end
            hook_Remove('Think', STATIC_PROP_PER_PROP_BAKE_HOOK)
            MsgC(Color(120, 200, 255), string.format(
                '[holo_table] Static prop per-prop bake ready: props=%d/%d scale=%.1f verts=%d\n',
                staticPropPerPropBake.bakedProps or 0,
                staticPropPerPropBake.propsTotal or 0,
                staticPropPerPropBake.scale or 0,
                staticPropPerPropBake.outputVerts or 0))
        end
    end)
end

-- prop_dynamic map dressing is map-owned rather than radar-owned. Most of
-- it is static enough to bake into BSP-space IMeshes and draw inside the
-- holo matrix; the per-table csent fallback below covers partial views,
-- disabled bake, and the short window while a changed prop set rebuilds.
local DYNAMIC_PROP_BAKE_HOOK = 'holo_table_3d.dynamic_prop_bake'
local DYNAMIC_PROP_SCAN_INTERVAL = 1.0
local dynamicPropBake = nil

destroyMeshList = function(list)
    if not list then return end
    for _, item in ipairs(list) do
        if item.mesh then
            pcall(item.mesh.Destroy, item.mesh)
            item.mesh = nil
        end
    end
end

local function destroyDynamicPropBake()
    hook_Remove('Think', DYNAMIC_PROP_BAKE_HOOK)
    if dynamicPropBake then
        destroyMeshList(dynamicPropBake.meshes)
        destroyMeshList(dynamicPropBake.pendingMeshes)
    end
    dynamicPropBake = nil
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
    local bake = dynamicPropBake
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
    if not dynamicPropBake then return end
    dynamicPropBake.state = 'building'
    dynamicPropBake.pendingSignature = signature
    dynamicPropBake.pendingMeshes = {}
    dynamicPropBake.pendingProps = #snapshot
    dynamicPropBake.pendingVerts = 0

    dynamicPropBake.co = coroutine_create(function()
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
            local msh = Mesh()
            msh:BuildFromTriangles(verts)
            dynamicPropBake.pendingMeshes[#dynamicPropBake.pendingMeshes + 1] = {
                mat = group.mat,
                mesh = msh,
            }
            dynamicPropBake.pendingVerts = dynamicPropBake.pendingVerts + n
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
    end)
end

function startDynamicPropBakeWatch()
    if not dynamicPropBakeCvar:GetBool() then return end
    if dynamicPropBake and dynamicPropBake.gen == CACHE_GENERATION then return end

    destroyDynamicPropBake()
    dynamicPropBake = {
        gen = CACHE_GENERATION,
        state = 'idle',
        meshes = {},
        signature = nil,
        lastSeen = {},
        unbaked = {},
        nextScan = 0,
    }

    hook_Add('Think', DYNAMIC_PROP_BAKE_HOOK, function()
        if not dynamicPropBake or dynamicPropBake.gen ~= CACHE_GENERATION then
            destroyDynamicPropBake()
            return
        end
        if not dynamicPropBakeCvar:GetBool() then return end
        if anyClipCoroutineActive() then return end

        if dynamicPropBake.state == 'building' then
            local ok, err = coroutine_resume(dynamicPropBake.co)
            if not ok then
                ErrorNoHaltWithStack(err)
                destroyMeshList(dynamicPropBake.pendingMeshes)
                dynamicPropBake.pendingMeshes = nil
                dynamicPropBake.co = nil
                dynamicPropBake.state = 'ready'
                dynamicPropBake.nextScan = SysTime() + DYNAMIC_PROP_SCAN_INTERVAL
                return
            end
            if coroutine_status(dynamicPropBake.co) == 'dead' then
                destroyMeshList(dynamicPropBake.meshes)
                dynamicPropBake.meshes = dynamicPropBake.pendingMeshes or {}
                dynamicPropBake.signature = dynamicPropBake.pendingSignature
                dynamicPropBake.props = dynamicPropBake.pendingProps or 0
                dynamicPropBake.outputVerts = dynamicPropBake.pendingVerts or 0
                dynamicPropBake.pendingMeshes = nil
                dynamicPropBake.pendingSignature = nil
                dynamicPropBake.co = nil
                dynamicPropBake.state = 'ready'
                dynamicPropBake.nextScan = SysTime() + DYNAMIC_PROP_SCAN_INTERVAL
                MsgC(Color(120, 200, 255), string.format(
                    '[holo_table] prop_dynamic bake ready: props=%d meshes=%d verts=%d\n',
                    dynamicPropBake.props or 0,
                    dynamicPropBake.meshes and #dynamicPropBake.meshes or 0,
                    dynamicPropBake.outputVerts or 0))
            end
            return
        end

        if SysTime() < (dynamicPropBake.nextScan or 0) then return end
        dynamicPropBake.nextScan = SysTime() + DYNAMIC_PROP_SCAN_INTERVAL
        local snapshot, signature = dynamicPropSnapshot()
        if signature ~= dynamicPropBake.signature then
            startDynamicPropBake(snapshot, signature)
        end
    end)
end


-- Builds per-material IMesh batches of the BSP geometry that survives
-- clipping against the holographic cylinder volume. The cylinder lives at
-- the world origin in BSP space because the scene→world matrix maps W to
-- (table_pos + up*height) + (1/scale)*R*W, so clipping the un-transformed
-- BSP against an axis-aligned cylinder around the origin produces exactly
-- what fits inside the physical cylinder at the table.
--
-- Returns the new list; does not touch `self.ClippedMeshes`. When `useYield`
-- is true, periodically calls `coroutine.yield()` so the work can be spread
-- across frames; in that case the caller must drive it from a coroutine.
-- When `stats` is non-nil, populates it with timing/count breakdowns:
--   tStart, tClipEnd, tEnd, facesTotal, facesRejected, facesFast,
--   facesClipped, planeChecked, planeSkipped, planeCut, outputTris, meshes.
function ENT:BuildClippedMap(scale, height, panX, panY, useYield, stats)
    local bsp = bsp2 and bsp2.GetCurrent()
    if not bsp or not bsp.faces then return {} end

    if stats then stats.tStart = SysTime() end

    -- Frame budget bookkeeping. Used both to throttle the per-face clip
    -- loop below and to make getMatByTexinfo's first-call lookup build
    -- (~250 ms on rp_venator) yieldable instead of a single hitch.
    local matByTexinfoLocal
    local function buildDeadlineFn() return matByTexinfoLocal end
    local function bumpBuildDeadline()
        matByTexinfoLocal = SysTime() + CLIP_FRAME_BUDGET
    end
    local matByTexinfoDeadlineFn = useYield and buildDeadlineFn or nil
    local matByTexinfoBumpFn     = useYield and bumpBuildDeadline or nil
    if useYield then bumpBuildDeadline() end

    -- The adapter builds one UnlitGeneric material per unique texinfo.
    -- Used as a fallback for LightmappedGeneric world materials, which
    -- render black without a lightmap. Cached across builds.
    local matByTexinfo = getMatByTexinfo(matByTexinfoDeadlineFn, matByTexinfoBumpFn) or {}

    local axis = self:GetUp()
    local right = self:GetAngles():Right()
    local fwd = self:GetAngles():Forward()

    local pivotZ = self:GetPos():Dot(axis)
    local radius = scale * 90
    local floorOffset = scale * (25 - height) + pivotZ
    local floorPlane = { n = -axis, d = -floorOffset }

    -- Pan shifts the cylinder horizontally in BSP space; wall planes have
    -- distance d = radius + panOffset.n (axis-perpendicular component of
    -- panOffset onto each wall normal). Horizontal cull subtracts the
    -- horizontal component of panOffset before measuring distance.
    local panOffset = Vector(panX or 0, panY or 0, 0)
    local panHoriz = panOffset - axis * panOffset:Dot(axis)

    -- Scalar components of the table-space basis. The per-face hot loop
    -- reads each face's bounding sphere and projects/rejects against the
    -- cylinder; doing that with Vector temporaries allocates a handful of
    -- Vectors per face which dominates GC time on big maps. The same math
    -- with bare numbers avoids all of those allocations.
    local axisX, axisY, axisZ = axis.x, axis.y, axis.z
    local rightX, rightY, rightZ = right.x, right.y, right.z
    local fwdX, fwdY, fwdZ = fwd.x, fwd.y, fwd.z
    local panHX, panHY, panHZ = panHoriz.x, panHoriz.y, panHoriz.z

    -- cos/sin are kept on each plane so the per-face sphere test below can
    -- project the face center onto every wall normal in the (right, fwd)
    -- basis without redoing the angle math.
    local segments = 32
    local wallPlanes = {}
    for i = 0, segments - 1 do
        local angle = math_pi * 2 * i / segments
        local cosA = math_cos(angle)
        local sinA = math_sin(angle)
        local n = right * cosA + fwd * sinA
        wallPlanes[#wallPlanes + 1] = {
            n = n,
            d = radius + panOffset:Dot(n),
            cos = cosA,
            sin = sinA,
        }
    end

    -- resolveMat / resolveProj live at module level so the background
    -- tri-cache prewarm (startTriCachePrewarm) can share their per-tinfo
    -- caches. Bind matByTexinfo here so the per-face hot loop calls
    -- resolveMat with one arg via a local closure (cheaper than passing
    -- it on every call).
    local function resolveMatLocal(tinfo) return resolveMat(tinfo, matByTexinfo) end

    local groups = {}
    local yieldDeadline = useYield and (SysTime() + CLIP_FRAME_BUDGET) or nil

    local sFacesTotal, sFacesRejected, sFacesFast, sFacesClipped = 0, 0, 0, 0
    local sPlaneChecked, sPlaneSkipped, sPlaneCut = 0, 0, 0
    local sOutputTris = 0

    -- Iterate worldspawn (model 1) faces only. Brush-entity faces live on
    -- models 2..N and are stored in their entity's local space; rendering
    -- them here would put them at the BSP origin instead of at their live
    -- entity pose. DrawBrushEntities handles those separately.
    local worldFaces = bsp.models and bsp.models[1] and bsp.models[1].faces or bsp.faces
    for fi = 1, #worldFaces do
        if yieldDeadline and SysTime() > yieldDeadline then
            coroutine_yield()
            yieldDeadline = SysTime() + CLIP_FRAME_BUDGET
        end

        local face = worldFaces[fi]
        local tinfo = face.texinfo
        if not tinfo then continue end
        if bit_band(tinfo.flags or 0, SURF_SKIP_MASK) ~= 0 then continue end

        local edges = face.edges
        if not edges or #edges < 3 then continue end

        sFacesTotal = sFacesTotal + 1


        -- Per-face bounding sphere, cached on the adapted face table itself.
        -- Survives subsequent rebuilds; recomputed only when the adapter
        -- rebuilds the face tables.
        -- Stored as scalars (cx/cy/cz/fr) so the per-face cull math below
        -- can run without ever materialising a Vector.
        local cull = face._holoCull
        if not cull or not cull.cx then
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
            cull = { cx = cx, cy = cy, cz = cz, fr = math_sqrt(r2max) }
            face._holoCull = cull
        end

        local cx, cy, cz, fr = cull.cx, cull.cy, cull.cz, cull.fr
        local along = cx * axisX + cy * axisY + cz * axisZ
        -- centerFromPan = (center - axis*along) - panHoriz, scalarised.
        local cfx = cx - axisX * along - panHX
        local cfy = cy - axisY * along - panHY
        local cfz = cz - axisZ * along - panHZ
        local horizDist2 = cfx * cfx + cfy * cfy + cfz * cfz

        -- Reject faces fully outside the cylinder. Using squared distance
        -- avoids the per-face sqrt; the `radius + fr` term is positive so
        -- squaring preserves the comparison direction.
        local outerR = radius + fr
        if horizDist2 > outerR * outerR then sFacesRejected = sFacesRejected + 1; continue end
        if along + fr < floorOffset then sFacesRejected = sFacesRejected + 1; continue end

        -- needsWallClip iff horizDist + fr > radius. When radius < fr the
        -- inequality holds for any horizDist, so force-clip; otherwise the
        -- squared form is exact.
        local insideR = radius - fr
        local needsWallClip = insideR < 0 or horizDist2 > insideR * insideR
        local needsFloorClip = along - fr < floorOffset

        -- Fast path: face fits entirely inside the cylinder, no clipping
        -- needed. The triangulation (positions + normal + UVs) depends only
        -- on the face geometry and texinfo, never on scale/pan/height, so
        -- it's cached on `face._holoTris` and reused verbatim across every
        -- subsequent rebuild. This collapses ~99% of the per-face work to
        -- a few table-reference appends on maps where the cylinder
        -- contains nearly everything.
        if not needsWallClip and not needsFloorClip then
            local tcache = face._holoTris
            if not tcache or tcache.gen ~= CACHE_GENERATION then
                local mat, skip = resolveMatLocal(tinfo)
                if skip then
                    tcache = { skip = true, gen = CACHE_GENERATION }
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
                    tcache = {
                        matKey = matKey, mat = mat,
                        tris = tris, triCount = #tris,
                        gen = CACHE_GENERATION,
                    }
                end
                face._holoTris = tcache
            end
            if tcache.skip then continue end

            -- Cache the resolved group ref against this build's `groups`
            -- identity so subsequent fast-path faces skip the hash lookup.
            -- Invalidated automatically when a new build creates a new
            -- groups table.
            local group = tcache.lastGroups == groups and tcache.lastGroup
            if not group then
                group = groups[tcache.matKey]
                if not group then
                    group = { mat = tcache.mat, verts = {} }
                    groups[tcache.matKey] = group
                end
                tcache.lastGroups = groups
                tcache.lastGroup = group
            end
            local verts = group.verts
            local triCount = tcache.triCount
            table_move(tcache.tris, 1, triCount, #verts + 1, verts)
            sFacesFast = sFacesFast + 1
            sOutputTris = sOutputTris + triCount / 3
            continue
        end

        local mat, skip = resolveMatLocal(tinfo)
        if skip then continue end

        local poly = {}
        for ei = 1, #edges do poly[ei] = edges[ei][1] end

        -- Slow path: face crosses the cylinder boundary. Project the
        -- face's bounding sphere onto each wall normal (cR*cos+cF*sin)
        -- and skip planes whose half-space already contains the sphere.
        -- Without this step the clipper would visit all 32 walls per
        -- face even though typically only 2-4 actually cut.
        if needsWallClip then
            sFacesClipped = sFacesClipped + 1
            local cR = cfx * rightX + cfy * rightY + cfz * rightZ
            local cF = cfx * fwdX + cfy * fwdY + cfz * fwdZ
            local insideMargin = radius - fr
            for pi = 1, segments do
                sPlaneChecked = sPlaneChecked + 1
                local p = wallPlanes[pi]
                if cR * p.cos + cF * p.sin > insideMargin then
                    sPlaneCut = sPlaneCut + 1
                    poly = clipPolygonPlane(poly, p.n, p.d)
                    if #poly < 3 then break end
                else
                    sPlaneSkipped = sPlaneSkipped + 1
                end
            end
        end

        if #poly >= 3 and needsFloorClip then
            poly = clipPolygonPlane(poly, floorPlane.n, floorPlane.d)
        end


        if #poly >= 3 then
            -- Group by basetexture so the per-texinfo adapter materials
            -- collapse into one batch per texture. Falls back to material
            -- name when there is no basetexture.
            local btn = mat:GetTexture('$basetexture')
            local matKey = btn and btn:GetName() or mat:GetName()
            local group = groups[matKey]
            if not group then
                group = { mat = mat, verts = {} }
                groups[matKey] = group
            end

            local proj = resolveProj(tinfo)
            local sv, tv = proj.sv, proj.tv
            local sw, tw = proj.sw, proj.tw
            local invW, invH = proj.invW, proj.invH
            local normal = face.plane.normal
            if face.side and face.side ~= 0 then normal = -normal end

            local verts = group.verts
            local a = poly[1]
            local ua = (a:Dot(sv) + sw) * invW
            local va = (a:Dot(tv) + tw) * invH
            for vi = 2, #poly - 1 do
                local b, c = poly[vi], poly[vi + 1]
                local ub = (b:Dot(sv) + sw) * invW
                local vb = (b:Dot(tv) + tw) * invH
                local uc = (c:Dot(sv) + sw) * invW
                local vc = (c:Dot(tv) + tw) * invH

                verts[#verts + 1] = { pos = a, normal = normal, u = ua, v = va }
                verts[#verts + 1] = { pos = b, normal = normal, u = ub, v = vb }
                verts[#verts + 1] = { pos = c, normal = normal, u = uc, v = vc }
                sOutputTris = sOutputTris + 1
            end
        end
    end

    if stats then stats.tClipEnd = SysTime() end

    -- IMesh creation can also exceed one frame's budget on big maps, so
    -- yield here too. The list is published on `self.ClipPending` so that
    -- any partial IMesh allocations can be freed if the coroutine is
    -- abandoned mid-pass (entity removed, build restarted, etc.).
    --
    -- BuildFromTriangles cost is roughly linear in vertex count
    -- (~0.45 us/vert on 7th-gen hardware); a single group with ~30k
    -- verts spends ~13 ms in one unyieldable call and shows up as a
    -- frame hitch. Split big groups into MAX_VERTS_PER_MESH chunks
    -- (each one a separate IMesh under the same material) so every
    -- BuildFromTriangles call stays under the frame budget. Multiple
    -- IMeshes per material cost one extra draw call apiece, which is
    -- cheap relative to the avoided stutter.
    --
    -- Yield BEFORE the chunk if its predicted cost would push the
    -- current resume past the deadline; the post-chunk check alone
    -- lets a 4 ms chunk land on top of 3 ms of accrued work and
    -- produce a 7 ms resume.
    local MAX_VERTS_PER_MESH = 8000
    local PER_VERT_SEC = 0.5e-6
    local list = {}
    self.ClipPending = list
    local meshCount = 0
    local chunkScratch
    for _, group in pairs(groups) do
        local verts = group.verts
        local n = #verts
        if n > 0 then
            local offset = 0
            while offset < n do
                local take = math_min(MAX_VERTS_PER_MESH, n - offset)
                -- Round down to a multiple of 3 so we never split a tri.
                take = take - (take % 3)
                if take == 0 then break end
                if yieldDeadline and SysTime() + take * PER_VERT_SEC > yieldDeadline then
                    coroutine_yield()
                    yieldDeadline = SysTime() + CLIP_FRAME_BUDGET
                end
                local source
                if offset == 0 and take == n then
                    source = verts
                else
                    chunkScratch = chunkScratch or {}
                    table_move(verts, offset + 1, offset + take, 1, chunkScratch)
                    for i = take + 1, #chunkScratch do chunkScratch[i] = nil end
                    source = chunkScratch
                end
                local m = Mesh()
                m:BuildFromTriangles(source)
                list[#list + 1] = { mat = group.mat, mesh = m }
                meshCount = meshCount + 1
                offset = offset + take
            end
        end
    end
    self.ClipPending = nil

    if stats then
        stats.tEnd = SysTime()
        stats.facesTotal = sFacesTotal
        stats.facesRejected = sFacesRejected
        stats.facesFast = sFacesFast
        stats.facesClipped = sFacesClipped
        stats.planeChecked = sPlaneChecked
        stats.planeSkipped = sPlaneSkipped
        stats.planeCut = sPlaneCut
        stats.outputTris = sOutputTris
        stats.meshes = meshCount
    end

    return list
end

-- IMesh userdata stays present after :Destroy() (it returns a NULL handle,
-- not nil), so a plain `if item.mesh` check is not enough to detect a
-- double-free. Wrap each destroy in pcall and clear the ref so subsequent
-- passes skip it; this prevents the "Tried to use a NULL LuaMesh!" cascade
-- that takes the rest of the build/render path down with it.
local function safeDestroyMesh(item)
    if not item.mesh then return end
    pcall(item.mesh.Destroy, item.mesh)
    item.mesh = nil
end

function ENT:DestroyClippedMap()
    if not self.ClippedMeshes then return end
    for _, item in ipairs(self.ClippedMeshes) do
        if not item.borrowed then safeDestroyMesh(item) end
    end
    self.ClippedMeshes = nil
end

-- Frees the cached "all-in" build. Items in this list also carry
-- borrowed=true while cached so DestroyClippedMap leaves them alone; this
-- function is the sole owner that ever frees them.
function ENT:DestroyAllInCache()
    if not self.AllInMeshes then return end
    for _, item in ipairs(self.AllInMeshes) do
        safeDestroyMesh(item)
        item.borrowed = nil
    end
    self.AllInMeshes = nil
end

-- Returns true when the cylinder (radius `scale*90` around (panX, panY)
-- in BSP space, floor plane at `scale*(25-height) + pivotZ` along the
-- table up axis) wholly contains the worldspawn AABB. When this holds
-- the clipper produces output identical to any other "all-in" config
-- with the same scale/height, so rebuilding can be skipped.
function ENT:CylinderContainsMap(scale, height, panX, panY)
    local bsp = bsp2 and bsp2.GetCurrent()
    if not bsp or not bsp.models or not bsp.models[1] then return false end
    local m = bsp.models[1]

    local axis = self:GetUp()
    local pivotZ = self:GetPos():Dot(axis)
    local radius = scale * 90
    local floorOffset = scale * (25 - height) + pivotZ
    local panOffset = Vector(panX or 0, panY or 0, 0)
    local panHoriz = panOffset - axis * panOffset:Dot(axis)

    for cx = 0, 1 do for cy = 0, 1 do for cz = 0, 1 do
        local v = Vector(
            cx == 0 and m.mins.x or m.maxs.x,
            cy == 0 and m.mins.y or m.maxs.y,
            cz == 0 and m.mins.z or m.maxs.z
        )
        local along = v:Dot(axis)
        local horiz = (v - axis * along - panHoriz):Length()
        if horiz > radius then return false end
        if along < floorOffset then return false end
    end end end
    return true
end

-- Horizontal-only all-in check used by baked prop renderers. Height/floor
-- changes do not invalidate baked prop meshes: the existing GPU floor clip
-- plane crops IMeshes vertically. Only scale/pan can make a full-map bake
-- overdraw horizontally enough that the legacy per-prop cull is preferable.
function ENT:CylinderHorizContainsMap(scale, panX, panY)
    local bsp = bsp2 and bsp2.GetCurrent()
    if not bsp or not bsp.models or not bsp.models[1] then return false end
    local m = bsp.models[1]

    local axis = self:GetUp()
    local radius = scale * 90
    local panOffset = Vector(panX or 0, panY or 0, 0)
    local panHoriz = panOffset - axis * panOffset:Dot(axis)

    for cx = 0, 1 do for cy = 0, 1 do for cz = 0, 1 do
        local v = Vector(
            cx == 0 and m.mins.x or m.maxs.x,
            cy == 0 and m.mins.y or m.maxs.y,
            cz == 0 and m.mins.z or m.maxs.z
        )
        local along = v:Dot(axis)
        local horiz = (v - axis * along - panHoriz):Length()
        if horiz > radius then return false end
    end end end
    return true
end

-- Draws the cached clipped worldspawn mesh under its own scene matrix.
-- Bounded in 3D against the cylinder volume by the build pipeline, so
-- it must be drawn outside the screen-space stencil and the GPU clip
-- prism used for radars (the prism would chop off tall content).
function ENT:DrawClippedMap()
    if not self.ClippedMeshes then return end
    if not self:GetMap() then return end

    -- Same pinned-pivot + pan transform the m2 block in DrawHologram
    -- uses for everything else; keeps the clipped mesh aligned with the
    -- unclipped fallback and DrawStaticProps. Sourced from the shared
    -- _holo* fields staged by ENT:UpdateHologramTransform.
    local m = Matrix()
    m:SetTranslation(self._holoOrigin)
    m:SetAngles(self._holoAngles)
    m:Scale(Vector(self._holoInvScale, self._holoInvScale, self._holoInvScale))

    render.PushFilterMag(TEXFILTER.ANISOTROPIC)
    render.PushFilterMin(TEXFILTER.ANISOTROPIC)
    render.SetLightingMode(2)

    -- pcall guards against a NULL IMesh aborting the draw before the
    -- Pop calls below run; leaking a Push per frame overflows the
    -- texture-filter stack within a few seconds and breaks every
    -- subsequent render in the addon.
    cam.PushModelMatrix(m)
        local ok, err = pcall(function()
            for _, item in ipairs(self.ClippedMeshes) do
                render_SetMaterial(item.mat)
                item.mesh:Draw()
            end
        end)
    cam.PopModelMatrix()

    render.SetLightingMode(0)
    render.PopFilterMin()
    render.PopFilterMag()

    if not ok then
        self.ClippedMeshes = nil
        ErrorNoHaltWithStack('[holo_table] DrawClippedMap aborted: ' .. tostring(err))
    end
end


-- Per-bmodel mesh cache. Brush-entity faces in the BSP are stored relative
-- to the entity's local origin, so the cached IMesh sits in local space
-- and DrawBrushEntities transforms it by the live entity's pos/ang. Shared
-- across holo_table_3d instances; cleared on map load via the adapter hook.
local brushMeshCache = {}

local function clearBrushMeshCache()
    for _, list in pairs(brushMeshCache) do
        if type(list) == 'table' then
            for _, item in ipairs(list) do
                if item.mesh then item.mesh:Destroy() end
            end
        end
    end
    brushMeshCache = {}
    destroyStaticPropBake()
    destroyStaticPropPerPropBake()
    destroyDynamicPropBake()
end

hook_Add('CurrentBSPReady', 'holo_table_3d.brushMeshCache', clearBrushMeshCache)

-- Builds (or returns cached) per-material IMesh batches for a single brush
-- model. Vertices are kept in the model's local frame so a single mesh can
-- serve every live brush entity that references this bmodel index.
function ENT:GetBrushModelMeshes(modelIndex)
    local cached = brushMeshCache[modelIndex]
    if cached ~= nil then return cached or nil end

    local bsp = bsp2 and bsp2.GetCurrent()
    local bmodel = bsp and bsp.models and bsp.models[modelIndex]
    if not bmodel or not bmodel.faces or #bmodel.faces == 0 then
        brushMeshCache[modelIndex] = false
        return nil
    end

    local matByTexinfo = getMatByTexinfo() or {}

    local groups = {}
    for _, face in ipairs(bmodel.faces) do
        local tinfo = face.texinfo
        if not tinfo then continue end
        if bit_band(tinfo.flags or 0, SURF_SKIP_MASK) ~= 0 then continue end

        local edges = face.edges
        if not edges or #edges < 3 then continue end

        local mat = loadTexdataMaterial(tinfo.texdata.material)
        if mat:GetShader() == 'LightmappedGeneric' then
            -- See BuildClippedMap.resolveMat: prefer the adapter fallback,
            -- but wrap the corrected texture ourselves when that fallback
            -- is broken.
            local fb = matByTexinfo[tostring(tinfo) .. '_texinfo']
            if fb then
                local fbBtn = fb:GetTexture('$basetexture')
                if fbBtn and filter[fbBtn:GetName()] then
                    mat = unlitWrap(mat)
                else
                    mat = fb
                end
            else
                mat = unlitWrap(mat)
            end
        end
        local btn = mat:GetTexture('$basetexture')
        if btn and filter[btn:GetName()] then continue end

        local matKey = btn and btn:GetName() or mat:GetName()
        local g = groups[matKey]
        if not g then g = { mat = mat, verts = {} } groups[matKey] = g end

        local s, t = tinfo.textureVecs.s, tinfo.textureVecs.t
        local sv, sw = Vector(s.x, s.y, s.z), s.w
        local tv, tw = Vector(t.x, t.y, t.z), t.w
        local invW = 1 / tinfo.texdata.width
        local invH = 1 / tinfo.texdata.height
        local normal = face.plane.normal
        if face.side and face.side ~= 0 then normal = -normal end

        local verts = g.verts
        local a = edges[1][1]
        local ua = (a:Dot(sv) + sw) * invW
        local va = (a:Dot(tv) + tw) * invH
        for vi = 2, #edges - 1 do
            local b, c = edges[vi][1], edges[vi + 1][1]
            local ub = (b:Dot(sv) + sw) * invW
            local vb = (b:Dot(tv) + tw) * invH
            local uc = (c:Dot(sv) + sw) * invW
            local vc = (c:Dot(tv) + tw) * invH
            verts[#verts + 1] = { pos = a, normal = normal, u = ua, v = va }
            verts[#verts + 1] = { pos = b, normal = normal, u = ub, v = vb }
            verts[#verts + 1] = { pos = c, normal = normal, u = uc, v = vc }
        end
    end

    local list = {}
    for _, g in pairs(groups) do
        if #g.verts > 0 then
            local msh = Mesh()
            msh:BuildFromTriangles(g.verts)
            list[#list + 1] = { mat = g.mat, mesh = msh }
        end
    end
    brushMeshCache[modelIndex] = #list > 0 and list or false
    return #list > 0 and list or nil
end

-- Cached `*N` brush-entity list. The brush-ent set itself rarely
-- changes, so we filter once per second instead of once per frame.
-- The cache stores resolved bmodel index + pre-computed extent so the
-- per-frame loop can stay scalar. ents.Iterator walks the engine's
-- cached entity table directly (no fresh allocation), unlike
-- ents.GetAll which copies the C++ list back to Lua on every call.
local brushEntCache     = {}
local brushEntCacheTime = 0
local BRUSH_CACHE_TTL   = 1.0
local function getBrushEntList(bsp)
    if SysTime() - brushEntCacheTime < BRUSH_CACHE_TTL then return brushEntCache end
    local list = {}
    for _, ent in ents.Iterator() do
        local model = ent:GetModel()
        if not model or model:sub(1, 1) ~= '*' then continue end
        local idx = tonumber(model:sub(2))
        if not idx then continue end
        local bmodel = bsp.models[idx + 1]
        if not bmodel then continue end
        local mn, mx = bmodel.mins, bmodel.maxs
        local dx, dy, dz = mx.x - mn.x, mx.y - mn.y, mx.z - mn.z
        list[#list + 1] = {
            ent    = ent,
            idx1   = idx + 1,
            extent = math_sqrt(dx * dx + dy * dy + dz * dz) * 0.5,
        }
    end
    brushEntCache     = list
    brushEntCacheTime = SysTime()
    return list
end

-- Module-level scratch matrix reused for every brush-ent
-- cam.PushModelMatrix call (was a fresh Matrix per drawn ent).
local BRUSH_DRAW_SCRATCH_MTX = Matrix()

-- Draws every live brush entity ("*N" model) at its current world pose,
-- composed on top of the holo scene matrix that the caller has already
-- pushed (DrawBrushEntities pushes its own per-entity matrix with
-- multiply=true). Cylinder cull is done in BSP space using the entity's
-- live origin and bmodel local extent.
function ENT:DrawBrushEntities()
    local bsp = bsp2 and bsp2.GetCurrent()
    if not bsp or not bsp.models then return end

    local axisX, axisY, axisZ = self._holoAxis:Unpack()
    local panX,  panY,  panZ  = self._holoPanHoriz:Unpack()
    local cylRadius           = self._holoCylRadius
    local floorOffset         = self._holoFloorOffset
    local mtx                 = BRUSH_DRAW_SCRATCH_MTX
    local list                = getBrushEntList(bsp)

    for i = 1, #list do
        local rec = list[i]
        local ent = rec.ent
        if not IsValid(ent) or ent == self then continue end

        -- Cull in BSP-space scalars, no per-iteration Vector arithmetic.
        -- entPos is one Vector allocation per frame per surviving ent
        -- (Entity:GetPos returns a fresh Vector); cheaper than the four
        -- Vectors the prior implementation built per ent for the same
        -- result.
        local entPos = ent:GetPos()
        local px, py, pz = entPos.x, entPos.y, entPos.z
        local extent = rec.extent
        local along  = px * axisX + py * axisY + pz * axisZ
        local hx = px - axisX * along - panX
        local hy = py - axisY * along - panY
        local hz = pz - axisZ * along - panZ
        local bound = cylRadius + extent
        if hx * hx + hy * hy + hz * hz > bound * bound then continue end
        if along + extent < floorOffset then continue end

        local meshes = self:GetBrushModelMeshes(rec.idx1)
        if not meshes then continue end

        mtx:Identity()
        mtx:SetTranslation(entPos)
        mtx:SetAngles(ent:GetAngles())
        cam.PushModelMatrix(mtx, true)
            for j = 1, #meshes do
                local item = meshes[j]
                render_SetMaterial(item.mat)
                item.mesh:Draw()
            end
        cam.PopModelMatrix()
    end
end


-- Draws the BSP's static props culled against the cylinder by per-prop
-- bounding sphere. Each prop's BSP-space pose is transformed into world
-- space at the table so the call does not depend on cam.PushModelMatrix
-- affecting Entity:DrawModel. Must be called inside the active GPU
-- clip-plane block so the prism crops props that extend past the cylinder.
-- Module-level scratch reused across every prop in a frame.
-- PROP_DRAW_SCRATCH_POS feeds cs:SetPos; PROP_DRAW_SCRATCH_ANG feeds
-- cs:SetAngles for angled props. Both are written via :SetUnpacked so
-- the per-prop draw allocates nothing -- prop basis vectors are
-- cached on the prop itself (computed once since prop.angles never
-- changes), the table basis is computed once per frame, and the
-- composed angle is derived from the composed basis via plain math.
local PROP_DRAW_SCRATCH_POS = Vector()
local PROP_DRAW_SCRATCH_ANG = Angle()

-- Hot-loop math locals: avoids per-call global table lookups in the
-- per-prop Euler-decomposition path.
local atan2   = math_atan2
local sqrt    = math_sqrt
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
    if not self.DynamicPropMirrors then return end
    for _, rec in pairs(self.DynamicPropMirrors) do
        if rec.csent then SafeRemoveEntity(rec.csent) end
    end
    self.DynamicPropMirrors = nil
    self.DynamicPropMirrorTime = nil
end

local function refreshDynamicPropMirrors(self, onlyUnbaked)
    if self.DynamicPropMirrors and SysTime() - (self.DynamicPropMirrorTime or 0) < DYN_PROP_CACHE_TTL then
        return self.DynamicPropMirrors
    end

    local fresh = {}
    local old = self.DynamicPropMirrors or {}
    local unbaked = dynamicPropBake and dynamicPropBake.unbaked
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

    self.DynamicPropMirrors = fresh
    self.DynamicPropMirrorTime = SysTime()
    return fresh
end

-- Draws baked prop_dynamic map dressing inside the holo scene matrix.
-- Returns true when the baked path handled the prop_dynamic layer this
-- frame, even if there are zero props; callers use this to skip the csent
-- fallback outside the matrix.
function ENT:DrawBakedDynamicProps()
    if not dynamicPropBakeCvar:GetBool() then return false end
    if not self:GetMap() then return false end
    if not self:CylinderHorizContainsMap(self:GetScale(), self:GetPanX(), self:GetPanY()) then
        startDynamicPropBakeWatch()
        return false
    end
    if not dynamicPropBake or dynamicPropBake.gen ~= CACHE_GENERATION then
        startDynamicPropBakeWatch()
        return true
    end
    if dynamicPropBake.state ~= 'ready' or not dynamicPropBake.meshes then return true end

    render.SuppressEngineLighting(true)
    local ok, err = pcall(function()
        for _, item in ipairs(dynamicPropBake.meshes) do
            if item.mesh then
                render_SetMaterial(item.mat)
                item.mesh:Draw()
            end
        end
    end)
    render.SuppressEngineLighting(false)

    if not ok then
        ErrorNoHaltWithStack('[holo_table] DrawBakedDynamicProps aborted: ' .. tostring(err))
        destroyDynamicPropBake()
        return false
    end

    return true
end

-- Legacy prop_dynamic fallback. This mirrors the old radar module's
-- ClientsideModel path and is used for partial views, disabled bake, and
-- while the async map-owned bake is rebuilding.
function ENT:DrawDynamicProps(onlyUnbaked)
    local mirrors = refreshDynamicPropMirrors(self, onlyUnbaked)
    if not mirrors then return end

    local invScale = self._holoInvScale
    render.SuppressEngineLighting(true)
    for _, rec in pairs(mirrors) do
        local ent, csent = rec.ent, rec.csent
        if not (IsValid(ent) and IsValid(csent)) then continue end

        if csent:GetSkin() ~= ent:GetSkin() then csent:SetSkin(ent:GetSkin()) end
        local wpos, wang = LocalToWorld(ent:GetPos() * invScale, ent:GetAngles(),
            self._holoOrigin, self._holoAngles)
        csent:SetPos(wpos)
        csent:SetAngles(wang)
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
function ENT:DrawBakedStaticProps()
    if not staticPropBakeCvar:GetBool() then return false end
    if not self:GetMap() then return false end
    local mode = staticPropBakeModeCvar:GetInt()
    if mode == 0 then return false end
    local scale = self:GetScale()
    if mode == 2 then
        if not staticPropPerPropBake or staticPropPerPropBake.gen ~= CACHE_GENERATION then
            startStaticPropPerPropBake(scale)
            return false
        end
        if math.abs((staticPropPerPropBake.scale or 0) - scale) >= 0.01 then
            startStaticPropPerPropBake(scale)
            return false
        end
        if staticPropPerPropBake.state ~= 'ready' or not staticPropPerPropBake.props then return false end

        local axisX, axisY, axisZ = self._holoAxis:Unpack()
        local panX,  panY,  panZ  = self._holoPanHoriz:Unpack()
        local cylRadius           = self._holoCylRadius
        local floorOffset         = self._holoFloorOffset

        render.SuppressEngineLighting(true)
        local ok, err = pcall(function()
            for _, rec in ipairs(staticPropPerPropBake.props) do
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
            destroyStaticPropPerPropBake()
            return false
        end
        return true
    end

    if mode ~= 3 and not self:CylinderHorizContainsMap(scale, self:GetPanX(), self:GetPanY()) then
        return false
    end
    if not staticPropBake or staticPropBake.gen ~= CACHE_GENERATION then
        startStaticPropBake(scale)
        return false
    end
    if math.abs((staticPropBake.scale or 0) - scale) >= 0.01 then
        startStaticPropBake(scale)
        return false
    end
    if staticPropBake.state ~= 'ready' or not staticPropBake.meshes then return false end

    render.SuppressEngineLighting(true)
    local ok, err = pcall(function()
        for _, item in ipairs(staticPropBake.meshes) do
            if item.mesh then
                render_SetMaterial(item.mat)
                item.mesh:Draw()
            end
        end
    end)
    render.SuppressEngineLighting(false)

    if not ok then
        ErrorNoHaltWithStack('[holo_table] DrawBakedStaticProps aborted: ' .. tostring(err))
        destroyStaticPropBake()
        return false
    end

    return true
end

function ENT:DrawStaticProps()
    local bsp = bsp2 and bsp2.GetCurrent()
    if not bsp or not bsp.props then return end

    -- Hot loop: 2256 props/frame on rp_venator, called every frame the
    -- table is on screen. The earlier version allocated ~360 KB/frame of
    -- short-lived Vectors (cull-pass arithmetic + per-prop LocalToWorld
    -- results), which alone produced periodic 80 ms full-GC hitches.
    -- This version unpacks every world vector into scalars up front so
    -- the cull pass touches no garbage, and caches each prop's BSP-space
    -- cull center as scalars on the prop itself the first time it is
    -- considered.
    local axisX, axisY, axisZ = self._holoAxis:Unpack()
    local panX,  panY,  panZ  = self._holoPanHoriz:Unpack()
    local cylRadius   = self._holoCylRadius
    local floorOffset = self._holoFloorOffset

    -- World-space transform mirroring the m2 matrix used for meshes:
    --   p_world = tableOrigin + R(tableAng) * ((p_bsp - panOffset) / scale)
    -- with the pan term already folded into tableOrigin (see
    -- ENT:UpdateHologramTransform). Per-prop draw only needs the
    -- standard scale + rotate, not the pan.
    local tableAng    = self._holoAngles
    local tableOrigin = self._holoOrigin
    local invScale    = self._holoInvScale

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
function ENT:CommitClippedBuild(list, scale, height, panX, panY)
    self:DestroyClippedMap()
    self.ClippedMeshes = list
    self.ClippedScale = scale
    self.ClippedHeight = height
    self.ClippedPanX = panX
    self.ClippedPanY = panY
    self.ClippedAllIn = self:CylinderContainsMap(scale, height, panX, panY)
    if self.ClippedAllIn and self.AllInMeshes ~= list then
        self:DestroyAllInCache()
        for _, item in ipairs(list) do item.borrowed = true end
        self.AllInMeshes = list
    end
end

-- Destroys any IMesh objects that the in-flight build had allocated before
-- it was abandoned mid-pass.
function ENT:DestroyPendingBuild()
    if not self.ClipPending then return end
    for _, item in ipairs(self.ClipPending) do
        if not item.borrowed then safeDestroyMesh(item) end
    end
    self.ClipPending = nil
end

-- Kicks off a clipped-map rebuild for the current scale/height. The output
-- is invariant for any "all-in" cylinder, so two short-circuits apply:
--   1. The currently-displayed build is already all-in → no work to do.
--   2. We have a cached all-in build from a prior session → swap it back in.
-- Otherwise spawn a coroutine to clip face-by-face across multiple frames.
function ENT:StartClippedBuild()
    self:DestroyPendingBuild()
    local scale = self:GetScale()
    local height = self:GetHeight()
    local panX = self:GetPanX()
    local panY = self:GetPanY()

    if self:CylinderContainsMap(scale, height, panX, panY) then
        if self.ClippedMeshes and self.ClippedAllIn then
            self.ClippedScale = scale
            self.ClippedHeight = height
            self.ClippedPanX = panX
            self.ClippedPanY = panY
            return
        end
        if self.AllInMeshes then
            self:DestroyClippedMap()
            self.ClippedMeshes = self.AllInMeshes
            self.ClippedScale = scale
            self.ClippedHeight = height
            self.ClippedPanX = panX
            self.ClippedPanY = panY
            self.ClippedAllIn = true
            return
        end
    end

    self.ClipBuildScale = scale
    self.ClipBuildHeight = height
    self.ClipBuildPanX = panX
    self.ClipBuildPanY = panY
    self.ClipCoroutine = coroutine_create(function()
        return self:BuildClippedMap(scale, height, panX, panY, true)
    end)
end

-- Resumes the in-flight build for one frame's worth of work. Commits the
-- result when the coroutine finishes.
function ENT:TickClippedBuild()
    local co = self.ClipCoroutine
    if not co then return end

    local ok, result = coroutine_resume(co)
    if not ok then
        ErrorNoHaltWithStack(result)
        self.ClipCoroutine = nil
        return
    end

    if coroutine_status(co) == 'dead' then
        self:CommitClippedBuild(result or {},
            self.ClipBuildScale, self.ClipBuildHeight,
            self.ClipBuildPanX, self.ClipBuildPanY)
        self.ClipCoroutine = nil
    end
end


function ENT:DrawMap()
    local map = bsp2.GetModelInfo()
    if not map then return end

    -- Legacy adapter fallback. The NikNaks adapter currently exposes no
    -- prebuilt meshes/entities here; the real map paths are DrawClippedMap,
    -- DrawBrushEntities, and the prop bakes.
    if self:GetMap() and not self.ClippedMeshes then
        for k, v in ipairs(map.meshes) do
            local mat = map.materials[k]
            if filter[mat:GetTexture('$basetexture'):GetName()] then continue end
            render_SetMaterial(mat)
            v:Draw()
        end
    end

    if self:GetEntities() then
        for k, v in ipairs(map.entities) do
            v:DrawModel()
        end
    end
end

_G.HOLO_TABLE_3D_CL_MAP_CLEANUP = function()
    hook_Remove('Think', prewarmHookName)
    prewarmCo = nil
    prewarmGen = nil

    hook_Remove('Think', propPrewarmHookName)
    propPrewarmCo = nil
    propPrewarmGen = nil

    destroyStaticPropBake()
    destroyStaticPropPerPropBake()
    destroyDynamicPropBake()
    clearBrushMeshCache()
    cleanupPropEntCache()
end


-- Computes (scale, panX, panY, height) that frames the worldspawn AABB
-- inside the cylinder, centered on the table, with the map's BSP floor
-- sitting just above the table surface. Scale fits the AABB's horizontal
-- half-diagonal in the cylinder radius (scale * 90) with a small margin;
-- pan is the AABB's XY centroid; height is solved so the floor clip
-- (scale * (25 - height) + pivotZ) lands at the BSP altitude of mins.z
-- plus a 1-unit clearance, matching the table's GPU floor plane.
-- Returns nil when bsp2 has no current map.
--- @return number, number, number, number
function ENT:ComputeAutoCenter()
    local bsp = bsp2 and bsp2.GetCurrent()
    if not bsp or not bsp.models or not bsp.models[1] then return end
    local m = bsp.models[1]

    local centerX = (m.mins.x + m.maxs.x) * 0.5
    local centerY = (m.mins.y + m.maxs.y) * 0.5
    local halfDX = (m.maxs.x - m.mins.x) * 0.5
    local halfDY = (m.maxs.y - m.mins.y) * 0.5

    -- Worst-case horizontal distance from the centroid is the AABB's
    -- half-diagonal; pad ~5% so map geometry never sits flush against the
    -- cylinder rim.
    local needRadius = math_sqrt(halfDX * halfDX + halfDY * halfDY) * 1.05
    local scale = math_max(1, math_ceil(needRadius / 90))

    -- A BSP point at altitude P.z appears at world altitude
    --   pivotZ + height + (P.z - pivotZ) / scale
    -- Setting that equal to (pivotZ + 25 + clearance) for P.z = mins.z
    -- (the lowest map face along the up axis) lands the floor on the
    -- table top. clearance = 1 keeps it from z-fighting the floor clip.
    local axis = self:GetUp()
    local pivotZ = self:GetPos():Dot(axis)
    local minsAlong = m.mins:Dot(axis)
    local clearance = 1
    local height = 25 + clearance - (minsAlong - pivotZ) / scale

    return scale, centerX, centerY, height
end



-- Picks a target holo table for the auto-center command: prefers the
-- entity under the player's crosshair, falls back to the nearest one
-- in the world. Returns nil if no holo table exists.
local function findAutoCenterTarget()
    local lp = LocalPlayer()
    if not IsValid(lp) then return end

    local trEnt = lp:GetEyeTrace().Entity
    if IsValid(trEnt) and trEnt:GetClass() == 'holo_table_3d' then
        return trEnt
    end

    local best, bestDist = nil, math.huge
    for _, e in ipairs(ents.FindByClass('holo_table_3d')) do
        local d = e:GetPos():DistToSqr(lp:GetPos())
        if d < bestDist then best, bestDist = e, d end
    end
    return best
end

-- The `holo_table_autocenter` concommand lives in sh_controls.lua so
-- it can share the find-target helper with the +reload hotkey.

-- Synchronously runs BuildClippedMap with the entity's current params,
-- prints stage-by-stage timings + counts, and frees the temporary
-- meshes without touching the live ClippedMeshes. Useful for
-- benchmarking changes to the clipper without touching the live build
-- pipeline (no debounce, no coroutine yields).
concommand.Add('holo_table_profile', function()
    local ent = findAutoCenterTarget()
    if not IsValid(ent) then
        MsgC(Color(255, 120, 120), '[holo_table] No holo_table_3d found.\n')
        return
    end
    if not (bsp2 and bsp2.GetCurrent()) then
        MsgC(Color(255, 120, 120), '[holo_table] bsp2 not loaded.\n')
        return
    end

    local scale = ent:GetScale()
    local height = ent:GetHeight()
    local panX = ent:GetPanX()
    local panY = ent:GetPanY()

    local stats = {}
    local list = ent:BuildClippedMap(scale, height, panX, panY, false, stats)
    for _, item in ipairs(list) do
        if item.mesh then item.mesh:Destroy() end
    end

    local total = (stats.tEnd - stats.tStart) * 1000
    local clip  = (stats.tClipEnd - stats.tStart) * 1000
    local mesh  = (stats.tEnd - stats.tClipEnd) * 1000
    MsgC(Color(120, 200, 255), string.format(
        '[holo_table] sync build %.1f ms (clip %.1f, imesh %.1f)\n' ..
        '  faces: total=%d rejected=%d fast=%d clipped=%d\n' ..
        '  walls: checked=%d skipped=%d cut=%d (skip ratio %.0f%%)\n' ..
        '  output: tris=%d meshes=%d\n',
        total, clip, mesh,
        stats.facesTotal, stats.facesRejected, stats.facesFast, stats.facesClipped,
        stats.planeChecked, stats.planeSkipped, stats.planeCut,
        stats.planeChecked > 0 and 100 * stats.planeSkipped / stats.planeChecked or 0,
        stats.outputTris, stats.meshes))
end)
