local MapCache = ENT.MapCache
local SysTime = SysTime
local Vector = Vector
local Mesh = Mesh
local bit_band = bit.band
local table_move = table.move
local math_sin = math.sin
local math_cos = math.cos
local math_sqrt = math.sqrt
local math_min = math.min
local math_pi = math.pi
local coroutine_create = coroutine.create
local coroutine_yield = coroutine.yield
local coroutine_resume = coroutine.resume
local coroutine_status = coroutine.status
local render_SetMaterial = render.SetMaterial
local CLIP_FRAME_BUDGET = MapCache.CLIP_FRAME_BUDGET
local CACHE_GENERATION = MapCache.CACHE_GENERATION
local SURF_SKIP_MASK = MapCache.SURF_SKIP_MASK
local filter = MapCache.filter
local clipPolygonPlane = MapCache.clipPolygonPlane
local getMatByTexinfo = MapCache.getMatByTexinfo
local resolveMat = MapCache.resolveMat
local resolveProj = MapCache.resolveProj
local buildMeshFromTriangles = MapCache.buildMeshFromTriangles
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
    -- Static mesh.Begin cost is roughly linear in vertex count
    -- (~0.45 us/vert on 7th-gen hardware); a single group with ~30k
    -- verts spends ~13 ms in one unyieldable call and shows up as a
    -- frame hitch. Split big groups into MAX_VERTS_PER_MESH chunks
    -- (each one a separate IMesh under the same material) so every
    -- mesh.End call stays under the frame budget. Multiple
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
    local selfTbl = self:GetTable()
    selfTbl.ClipPending = list
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
                local m = buildMeshFromTriangles(source)
                list[#list + 1] = { mat = group.mat, mesh = m }
                meshCount = meshCount + 1
                offset = offset + take
            end
        end
    end
    selfTbl.ClipPending = nil

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
function ENT:DestroyClippedMap()
    local selfTbl = self:GetTable()
    if not selfTbl.ClippedMeshes then return end
    for _, item in ipairs(selfTbl.ClippedMeshes) do
        if not item.borrowed then self:_SafeDestroyMesh(item) end
    end
    selfTbl.ClippedMeshes = nil
end

-- Frees the cached "all-in" build. Items in this list also carry
-- borrowed=true while cached so DestroyClippedMap leaves them alone; this
-- function is the sole owner that ever frees them.
function ENT:DestroyAllInCache()
    local selfTbl = self:GetTable()
    if not selfTbl.AllInMeshes then return end
    for _, item in ipairs(selfTbl.AllInMeshes) do
        self:_SafeDestroyMesh(item)
        item.borrowed = nil
    end
    selfTbl.AllInMeshes = nil
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
    local selfTbl = self:GetTable()
    local clippedMeshes = selfTbl.ClippedMeshes
    if not clippedMeshes then return end
    if not self:GetMap() then return end

    -- Same pinned-pivot + pan transform the m2 block in DrawHologram
    -- uses for everything else; keeps the clipped mesh aligned with the
    -- unclipped fallback and DrawStaticProps. Sourced from the shared
    -- _holo* fields staged by ENT:UpdateHologramTransform.
    local m = Matrix()
    m:SetTranslation(selfTbl._holoOrigin)
    m:SetAngles(selfTbl._holoAngles)
    m:Scale(Vector(selfTbl._holoInvScale, selfTbl._holoInvScale, selfTbl._holoInvScale))

    render.PushFilterMag(TEXFILTER.ANISOTROPIC)
    render.PushFilterMin(TEXFILTER.ANISOTROPIC)
    render.SetLightingMode(2)

    -- pcall guards against a NULL IMesh aborting the draw before the
    -- Pop calls below run; leaking a Push per frame overflows the
    -- texture-filter stack within a few seconds and breaks every
    -- subsequent render in the addon.
    cam.PushModelMatrix(m)
        local ok, err = pcall(function()
            for _, item in ipairs(clippedMeshes) do
                render_SetMaterial(item.mat)
                item.mesh:Draw()
            end
        end)
    cam.PopModelMatrix()

    render.SetLightingMode(0)
    render.PopFilterMin()
    render.PopFilterMag()

    if not ok then
        selfTbl.ClippedMeshes = nil
        ErrorNoHaltWithStack('[holo_table] DrawClippedMap aborted: ' .. tostring(err))
    end
end


-- Per-bmodel mesh cache. Brush-entity faces in the BSP are stored relative
-- to the entity's local origin, so the cached IMesh sits in local space
-- and DrawBrushEntities transforms it by the live entity's pos/ang. Shared
-- across holo_table_3d instances; cleared on map load via the adapter hook.


function ENT:CommitClippedBuild(list, scale, height, panX, panY)
    local selfTbl = self:GetTable()
    self:DestroyClippedMap()
    selfTbl.ClippedMeshes = list
    selfTbl.ClippedScale = scale
    selfTbl.ClippedHeight = height
    selfTbl.ClippedPanX = panX
    selfTbl.ClippedPanY = panY
    selfTbl.ClippedAllIn = self:CylinderContainsMap(scale, height, panX, panY)
    if selfTbl.ClippedAllIn and selfTbl.AllInMeshes ~= list then
        self:DestroyAllInCache()
        for _, item in ipairs(list) do item.borrowed = true end
        selfTbl.AllInMeshes = list
    end
end

-- Destroys any IMesh objects that the in-flight build had allocated before
-- it was abandoned mid-pass.
function ENT:DestroyPendingBuild()
    local selfTbl = self:GetTable()
    if not selfTbl.ClipPending then return end
    for _, item in ipairs(selfTbl.ClipPending) do
        if not item.borrowed then self:_SafeDestroyMesh(item) end
    end
    selfTbl.ClipPending = nil
end

-- Kicks off a clipped-map rebuild for the current scale/height. The output
-- is invariant for any "all-in" cylinder, so two short-circuits apply:
--   1. The currently-displayed build is already all-in → no work to do.
--   2. We have a cached all-in build from a prior session → swap it back in.
-- Otherwise spawn a coroutine to clip face-by-face across multiple frames.
function ENT:StartClippedBuild()
    self:DestroyPendingBuild()
    local selfTbl = self:GetTable()
    local scale = self:GetScale()
    local height = self:GetHeight()
    local panX = self:GetPanX()
    local panY = self:GetPanY()

    if self:CylinderContainsMap(scale, height, panX, panY) then
        if selfTbl.ClippedMeshes and selfTbl.ClippedAllIn then
            selfTbl.ClippedScale = scale
            selfTbl.ClippedHeight = height
            selfTbl.ClippedPanX = panX
            selfTbl.ClippedPanY = panY
            return
        end
        if selfTbl.AllInMeshes then
            self:DestroyClippedMap()
            selfTbl.ClippedMeshes = selfTbl.AllInMeshes
            selfTbl.ClippedScale = scale
            selfTbl.ClippedHeight = height
            selfTbl.ClippedPanX = panX
            selfTbl.ClippedPanY = panY
            selfTbl.ClippedAllIn = true
            return
        end
    end

    selfTbl.ClipBuildScale = scale
    selfTbl.ClipBuildHeight = height
    selfTbl.ClipBuildPanX = panX
    selfTbl.ClipBuildPanY = panY
    selfTbl.ClipCoroutine = coroutine_create(function()
        return self:BuildClippedMap(scale, height, panX, panY, true)
    end)
end

-- Resumes the in-flight build for one frame's worth of work. Commits the
-- result when the coroutine finishes.
function ENT:TickClippedBuild()
    local selfTbl = self:GetTable()
    local co = selfTbl.ClipCoroutine
    if not co then return end

    local ok, result = coroutine_resume(co)
    if not ok then
        ErrorNoHaltWithStack(result)
        selfTbl.ClipCoroutine = nil
        return
    end

    if coroutine_status(co) == 'dead' then
        self:CommitClippedBuild(result or {},
            selfTbl.ClipBuildScale, selfTbl.ClipBuildHeight,
            selfTbl.ClipBuildPanX, selfTbl.ClipBuildPanY)
        selfTbl.ClipCoroutine = nil
    end
end


function ENT:DrawMap()
    local map = bsp2.GetModelInfo()
    if not map then return end
    local selfTbl = self:GetTable()

    -- Legacy adapter fallback. The NikNaks adapter currently exposes no
    -- prebuilt meshes/entities here; the real map paths are DrawClippedMap,
    -- DrawBrushEntities, and the prop bakes.
    if self:GetMap() and not selfTbl.ClippedMeshes then
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
