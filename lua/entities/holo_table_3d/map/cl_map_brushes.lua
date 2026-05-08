local MapCache = ENT.MapCache
local SysTime = SysTime
local Vector = Vector
local bit_band = bit.band
local math_sqrt = math.sqrt
local hook_Add = hook.Add
local render_SetMaterial = render.SetMaterial
local filter = MapCache.filter
local SURF_SKIP_MASK = MapCache.SURF_SKIP_MASK
local getMatByTexinfo = MapCache.getMatByTexinfo
local loadTexdataMaterial = MapCache.loadTexdataMaterial
local unlitWrap = MapCache.unlitWrap
local buildMeshFromTriangles = MapCache.buildMeshFromTriangles
local brushMeshCache = {}

function MapCache.clearBrushMeshCache()
    for _, list in pairs(brushMeshCache) do
        if type(list) == 'table' then
            for _, item in ipairs(list) do
                if item.mesh then item.mesh:Destroy() end
            end
        end
    end
    brushMeshCache = {}
    MapCache.destroyStaticPropBake()
    MapCache.destroyStaticPropPerPropBake()
    MapCache.destroyDynamicPropBake()
end

hook_Add('CurrentBSPReady', 'holo_table_3d.brushMeshCache', MapCache.clearBrushMeshCache)

--- Builds (or returns cached) per-material IMesh batches for one bmodel.
--- Vertices are kept entity-local so a single mesh serves every live brush
--- entity that references this bmodel index.
--- @param modelIndex number 1-based bmodel index.
--- @return table[]? meshes nil if the model has no renderable faces.
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
            -- Same logic as resolveMat: prefer the adapter fallback, wrap
            -- the corrected texture ourselves when the fallback is broken.
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
            local msh = buildMeshFromTriangles(g.verts)
            list[#list + 1] = { mat = g.mat, mesh = msh }
        end
    end
    brushMeshCache[modelIndex] = #list > 0 and list or false
    return #list > 0 and list or nil
end

-- 1 Hz cached "*N" brush-entity list. ents.Iterator walks the engine's
-- existing entity table directly (no realloc per call).
local brushEntCache     = {}
local brushEntCacheTime = 0
local BRUSH_CACHE_TTL   = 1.0

--- @return { ent: Entity, idx1: number, extent: number }[]
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

-- Module-level scratch matrix reused for every brush-ent push.
local BRUSH_DRAW_SCRATCH_MTX = Matrix()

--- Draws every live brush entity ("*N" model) at its current world pose,
--- composed on top of the caller's pushed scene matrix. Cylinder cull is
--- BSP-space scalar against the entity origin + bmodel local extent.
function ENT:DrawBrushEntities()
    local bsp = bsp2 and bsp2.GetCurrent()
    if not bsp or not bsp.models then return end

    local selfTbl = self:GetTable()
    local axisX, axisY, axisZ = selfTbl._holoAxis:Unpack()
    local panX,  panY,  panZ  = selfTbl._holoPanHoriz:Unpack()
    local cylRadius           = selfTbl._holoCylRadius
    local floorOffset         = selfTbl._holoFloorOffset
    local mtx                 = BRUSH_DRAW_SCRATCH_MTX
    local list                = getBrushEntList(bsp)

    for i = 1, #list do
        local rec = list[i]
        local ent = rec.ent
        if not IsValid(ent) or ent == self then continue end

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
