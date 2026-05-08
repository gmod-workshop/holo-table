local MapCache = ENT.MapCache
local SysTime = SysTime

function ENT:InitializeMap()
    -- Cold first-build cost on big maps is dominated by per-face
    -- triangulation: ~300 ms of Lua-side work building face._holoTris
    -- entries the first time the cylinder culler walks worldspawn.
    -- That data is independent of scale/height/pan, so kick a global
    -- background coroutine the moment any holo_table_3d is initialised
    -- to populate it ahead of time. Subsequent first-builds (this
    -- entity or any sibling) skip the 300 ms and run at warm cost.
    MapCache.startTriCachePrewarm()
    -- The first time a static prop is rendered the engine syncs in its
    -- model and material data, producing 80-90 ms hitches inside
    -- DrawStaticProps (visible as occasional FPS spikes when the table
    -- starts displaying a previously-unseen part of the map). Touching
    -- every unique model once at init time forces the load up front.
    MapCache.startPropPrewarm()
    -- A shared static-prop bake replaces thousands of per-frame
    -- ClientsideModel DrawModel calls with material-batched IMesh draws.
    -- Mode 3 keeps that path active for zoomed views too and lets the
    -- existing GPU clip prism trim the oversized bake.
    local staticMode = MapCache.staticPropBakeModeCvar:GetInt()
    if staticMode == 2 then
        MapCache.startStaticPropPerPropBake(self:GetScale())
    elseif staticMode == 3 or self:CylinderHorizContainsMap(self:GetScale(), self:GetPanX(), self:GetPanY()) then
        MapCache.startStaticPropBake(self:GetScale())
    end
    MapCache.startDynamicPropBakeWatch()
end

function ENT:CleanupMap()
    self:GetTable().ClipCoroutine = nil
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

    local selfTbl = self:GetTable()
    local scale = self:GetScale()
    local height = self:GetHeight()
    local panX = self:GetPanX()
    local panY = self:GetPanY()

    local stale = selfTbl.ClippedScale ~= scale or selfTbl.ClippedHeight ~= height
        or selfTbl.ClippedPanX ~= panX or selfTbl.ClippedPanY ~= panY

    if selfTbl.RebuildTargetScale ~= scale or selfTbl.RebuildTargetHeight ~= height
        or selfTbl.RebuildTargetPanX ~= panX or selfTbl.RebuildTargetPanY ~= panY then
        selfTbl.RebuildTargetScale = scale
        selfTbl.RebuildTargetHeight = height
        selfTbl.RebuildTargetPanX = panX
        selfTbl.RebuildTargetPanY = panY
        selfTbl.RebuildTargetTime = SysTime()
    end

    local stable = SysTime() - (selfTbl.RebuildTargetTime or 0) > 0.15
    local firstBuild = not selfTbl.ClippedMeshes
    if stale and not selfTbl.ClipCoroutine and (stable or firstBuild) then
        self:StartClippedBuild()
    end
    if selfTbl.ClipCoroutine then
        self:TickClippedBuild()
    end
end



_G.HOLO_TABLE_3D_CL_MAP_CLEANUP = function()
    MapCache.cleanupPrewarm()
    MapCache.destroyStaticPropBake()
    MapCache.destroyStaticPropPerPropBake()
    MapCache.destroyDynamicPropBake()
    MapCache.clearBrushMeshCache()
    MapCache.cleanupPropEntCache()
end
