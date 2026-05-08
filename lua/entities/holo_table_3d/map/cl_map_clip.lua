local MapCache = ENT.MapCache
local SysTime = SysTime
local Vector = Vector
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

--- Builds the clipped worldspawn mesh list. Iterates worldspawn faces only;
--- each surviving face becomes triangles in a per-material group. Both fast
--- (fully interior) and slow (boundary) paths feed the same group list,
--- which is then chunked into IMeshes. See DESIGN.md "Build pipeline" / "Culling".
--- @param scale number
--- @param height number
--- @param panX number
--- @param panY number
--- @param useYield boolean If true, yields when the per-frame budget is exceeded.
--- @param stats table? Optional table populated with stage timings + counts.
--- @return table[] meshes List of { mat: IMaterial, mesh: IMesh } records.
function ENT:BuildClippedMap(scale, height, panX, panY, useYield, stats)
    local bsp = bsp2 and bsp2.GetCurrent()
    if not bsp or not bsp.faces then return {} end

    if stats then stats.tStart = SysTime() end

    -- Frame budget: throttles the per-face loop AND makes getMatByTexinfo's
    -- ~250 ms first-call lookup yieldable instead of one big hitch.
    local matByTexinfoLocal
    local function buildDeadlineFn() return matByTexinfoLocal end
    local function bumpBuildDeadline()
        matByTexinfoLocal = SysTime() + CLIP_FRAME_BUDGET
    end
    local matByTexinfoDeadlineFn = useYield and buildDeadlineFn or nil
    local matByTexinfoBumpFn     = useYield and bumpBuildDeadline or nil
    if useYield then bumpBuildDeadline() end

    local matByTexinfo = getMatByTexinfo(matByTexinfoDeadlineFn, matByTexinfoBumpFn) or {}

    local axis = self:GetUp()
    local right = self:GetAngles():Right()
    local fwd = self:GetAngles():Forward()

    local pivotZ = self:GetPos():Dot(axis)
    local radius = scale * 90
    local floorOffset = scale * (25 - height) + pivotZ
    local floorPlane = { n = -axis, d = -floorOffset }

    -- Pan shifts the cylinder horizontally in BSP space. Wall planes get
    -- d = radius + panOffset.n; horizontal cull subtracts panHoriz too.
    local panOffset = Vector(panX or 0, panY or 0, 0)
    local panHoriz = panOffset - axis * panOffset:Dot(axis)

    -- Scalar basis: per-face hot loop runs without Vector temporaries.
    local axisX, axisY, axisZ = axis.x, axis.y, axis.z
    local rightX, rightY, rightZ = right.x, right.y, right.z
    local fwdX, fwdY, fwdZ = fwd.x, fwd.y, fwd.z
    local panHX, panHY, panHZ = panHoriz.x, panHoriz.y, panHoriz.z

    -- cos/sin per wall plane so the per-face sphere test can project the
    -- center onto every wall normal in (right, fwd) without redoing trig.
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

    local function resolveMatLocal(tinfo) return resolveMat(tinfo, matByTexinfo) end

    local groups = {}
    local yieldDeadline = useYield and (SysTime() + CLIP_FRAME_BUDGET) or nil

    local sFacesTotal, sFacesRejected, sFacesFast, sFacesClipped = 0, 0, 0, 0
    local sPlaneChecked, sPlaneSkipped, sPlaneCut = 0, 0, 0
    local sOutputTris = 0

    -- Worldspawn-only iteration. Brush-entity faces are stored entity-local
    -- and would render at the BSP origin; DrawBrushEntities handles them.
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


        -- Per-face bounding sphere, scalar, cached on the face table.
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
        local cfx = cx - axisX * along - panHX
        local cfy = cy - axisY * along - panHY
        local cfz = cz - axisZ * along - panHZ
        local horizDist2 = cfx * cfx + cfy * cfy + cfz * cfz

        local outerR = radius + fr
        if horizDist2 > outerR * outerR then sFacesRejected = sFacesRejected + 1; continue end
        if along + fr < floorOffset then sFacesRejected = sFacesRejected + 1; continue end

        -- needsWallClip iff horizDist + fr > radius. Squared form is exact
        -- when radius >= fr; force-clip when the cylinder is smaller.
        local insideR = radius - fr
        local needsWallClip = insideR < 0 or horizDist2 > insideR * insideR
        local needsFloorClip = along - fr < floorOffset

        -- Fast path: face is fully inside. Triangulation is invariant of
        -- scale/pan/height -- cached on face._holoTris and reused verbatim.
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

            -- One-shot lastGroups/lastGroup ref skips the per-face hash lookup.
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

        -- Slow path: project the bounding sphere onto each wall normal
        -- and skip planes whose half-space already contains the sphere.
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
            -- Group by basetexture so per-texinfo adapter materials collapse
            -- into one batch per texture.
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

    -- Chunked IMesh emit. Static mesh.Begin is ~0.45 us/vert, so a 30k-vert
    -- group blocks for ~13 ms in one unyieldable call. Split big groups
    -- under MAX_VERTS_PER_MESH; yield BEFORE a chunk if its predicted cost
    -- pushes past the deadline. Partial allocations are tracked on
    -- selfTbl.ClipPending so abandoned coroutines can free them.
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

--- Frees the cached "all-in" build. Items in this list carry borrowed=true
--- while cached so DestroyClippedMap leaves them alone; this is the sole owner.
function ENT:DestroyAllInCache()
    local selfTbl = self:GetTable()
    if not selfTbl.AllInMeshes then return end
    for _, item in ipairs(selfTbl.AllInMeshes) do
        self:_SafeDestroyMesh(item)
        item.borrowed = nil
    end
    selfTbl.AllInMeshes = nil
end

--- True iff the cylinder fully contains the worldspawn AABB. When this
--- holds, the clipper output is identical to any other all-in config so
--- rebuilding can be skipped.
--- @param scale number
--- @param height number
--- @param panX number
--- @param panY number
--- @return boolean
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

--- Horizontal-only all-in check used by baked prop renderers. Vertical
--- changes don't invalidate baked meshes -- the GPU floor clip plane crops them.
--- @param scale number
--- @param panX number
--- @param panY number
--- @return boolean
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

--- Draws the cached clipped worldspawn mesh under its own scene matrix.
--- Bounded in 3D by the build pipeline, so it draws OUTSIDE the screen-space
--- stencil and the GPU clip prism (which would chop tall content).
function ENT:DrawClippedMap()
    local selfTbl = self:GetTable()
    local clippedMeshes = selfTbl.ClippedMeshes
    if not clippedMeshes then return end
    if not self:GetMap() then return end

    local m = Matrix()
    m:SetTranslation(selfTbl._holoOrigin)
    m:SetAngles(selfTbl._holoAngles)
    m:Scale(Vector(selfTbl._holoInvScale, selfTbl._holoInvScale, selfTbl._holoInvScale))

    render.PushFilterMag(TEXFILTER.ANISOTROPIC)
    render.PushFilterMin(TEXFILTER.ANISOTROPIC)
    render.SetLightingMode(2)

    -- pcall guards against a NULL IMesh aborting before the Pop calls run;
    -- a leaked Push per frame overflows the texture-filter stack.
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


--- Commits a finished build, swaps in the new mesh list, and stamps the
--- "all-in" cache when applicable.
--- @param list table[]
--- @param scale number
--- @param height number
--- @param panX number
--- @param panY number
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

--- Frees IMeshes from a build that was abandoned mid-pass.
function ENT:DestroyPendingBuild()
    local selfTbl = self:GetTable()
    if not selfTbl.ClipPending then return end
    for _, item in ipairs(selfTbl.ClipPending) do
        if not item.borrowed then self:_SafeDestroyMesh(item) end
    end
    selfTbl.ClipPending = nil
end

--- Kicks off (or short-circuits to) a clipped-map rebuild for current params.
--- All-in current display reuses, all-in with cached AllInMeshes swaps it
--- back in, otherwise spawns a coroutine.
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

--- Resumes the in-flight build for one frame's slice; commits when finished.
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


--- Layer-toggle dispatch. Adapter fallback for unclipped first-frame
--- worldspawn (vestigial since NikNaks exposes no prebuilt meshes), plus
--- the entity (BSP-prefab) layer when GetEntities() is on.
function ENT:DrawMap()
    local map = bsp2.GetModelInfo()
    if not map then return end
    local selfTbl = self:GetTable()

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
