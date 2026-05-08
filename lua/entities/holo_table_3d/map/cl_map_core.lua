local MapCache = ENT.MapCache
local SysTime = SysTime

--- Per-entity init: kicks the global tri-cache + prop prewarms, the static-
--- prop bake (mode-dependent), and the dynamic prop watcher.
function ENT:InitializeMap()
    MapCache.startTriCachePrewarm()
    MapCache.startPropPrewarm()
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

--- Lazy async re-clip on parameter change. Stale ClippedMeshes keep
--- rendering until the new build commits. Debounces 150 ms (first build
--- is exempt) and never preempts an in-flight coroutine. See DESIGN.md
--- "Build pipeline".
--- @see ENT:StartClippedBuild
--- @see ENT:TickClippedBuild
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
