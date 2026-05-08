local MapCache = ENT.MapCache
local SysTime = SysTime
local Vector = Vector
local Material = Material
local bit_band = bit.band
local coroutine_yield = coroutine.yield
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
local staticPropBakeModeCvar = CreateClientConVar('holo_table_staticprop_bake_mode', '3', true, false,
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

MapCache.filter = filter
MapCache.staticPropBakeCvar = staticPropBakeCvar
MapCache.staticPropBakeModeCvar = staticPropBakeModeCvar
MapCache.dynamicPropBakeCvar = dynamicPropBakeCvar
MapCache.PROP_SUBPIXEL_THRESHOLD = PROP_SUBPIXEL_THRESHOLD
MapCache.getPropBounds = getPropBounds
MapCache.getPropDrawEnt = getPropDrawEnt
MapCache.cleanupPropEntCache = cleanupPropEntCache
MapCache.clipPolygonPlane = clipPolygonPlane
MapCache.SURF_SKIP_MASK = SURF_SKIP_MASK
MapCache.CLIP_FRAME_BUDGET = CLIP_FRAME_BUDGET
MapCache.CACHE_GENERATION = CACHE_GENERATION
MapCache.loadTexdataMaterial = loadTexdataMaterial
MapCache.unlitWrap = unlitWrap
MapCache.resolveMat = resolveMat
MapCache.resolveProj = resolveProj
MapCache.getMatByTexinfo = getMatByTexinfo
