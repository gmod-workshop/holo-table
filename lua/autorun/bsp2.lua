local ok, err = pcall(require, 'niknaks')
if not ok then
    ErrorNoHalt('[bsp2] NikNaks dependency failed to load: ' .. tostring(err) .. '\n')
    return
end

-- NikNaks-backed adapter preserving the small bsp2 surface holo_table_3d uses.
bsp2 = bsp2 or {}

local SCALE = 1

local CURRENT
local CACHE_GENERATION = SysTime()

--- @return table? map NikNaks map handle, or nil with an error string.
--- @return string? err
local function ensureNikNaksMap()
    if not NikNaks then return nil, 'NikNaks is not loaded' end
    return NikNaks.CurrentMap or NikNaks.Map()
end

--- Returns table values ordered by ascending numeric key.
--- @param t table?
--- @return any[]
local function orderedValues(t)
    local keys = {}
    for k in pairs(t or {}) do
        if isnumber(k) then keys[#keys + 1] = k end
    end
    table.sort(keys)

    local out = {}
    for i = 1, #keys do
        out[#out + 1] = t[keys[i]]
    end
    return out
end

--- Adapts a NikNaks texinfo into the legacy bsp2 shape, gen-cached on the source.
--- @param map table
--- @param src table?
--- @return table?
local function adaptTexInfo(map, src)
    if not src then return nil end
    if src._holoBsp2TexInfo and src._holoBsp2Gen == CACHE_GENERATION then
        return src._holoBsp2TexInfo
    end

    local texdata = map:GetTexData()[src.texdata]
    local tv = src.textureVects
    local s = tv and tv[0] or {}
    local t = tv and tv[1] or {}

    local out = {
        flags = src.flags or 0,
        texdata = {
            material = texdata and texdata.nameStringTableID or '__error',
            width = texdata and texdata.width or 1,
            height = texdata and texdata.height or 1,
            reflectivity = texdata and texdata.reflectivity or vector_origin,
        },
        textureVecs = {
            s = { x = s[0] or 0, y = s[1] or 0, z = s[2] or 0, w = s[3] or 0 },
            t = { x = t[0] or 0, y = t[1] or 0, z = t[2] or 0, w = t[3] or 0 },
        },
    }

    src._holoBsp2TexInfo = out
    src._holoBsp2Gen = CACHE_GENERATION
    return out
end

--- Adapts a NikNaks face into a legacy bsp2 face with explicit vertex pairs.
--- @param map table
--- @param src table?
--- @return table?
local function adaptFace(map, src)
    if not src then return nil end
    if src._holoBsp2Face and src._holoBsp2Gen == CACHE_GENERATION then
        return src._holoBsp2Face
    end

    local vertices = src:GetVertexs() or {}
    local edges = {}
    for i = 1, #vertices do
        local a = vertices[i]
        local b = vertices[i % #vertices + 1]
        edges[i] = { a, b }
    end

    local out = {
        plane = src.plane,
        side = src.side,
        edges = edges,
        texinfo = adaptTexInfo(map, src:GetTexInfo()),
    }

    src._holoBsp2Face = out
    src._holoBsp2Gen = CACHE_GENERATION
    return out
end

--- @param map table
--- @param src table?
--- @return table?
local function adaptModel(map, src)
    if not src then return nil end
    if src._holoBsp2Model and src._holoBsp2Gen == CACHE_GENERATION then
        return src._holoBsp2Model
    end

    local faces = {}
    for _, face in ipairs(src:GetFaces() or {}) do
        faces[#faces + 1] = adaptFace(map, face)
    end

    local out = {
        mins = src.mins,
        maxs = src.maxs,
        origin = src.origin,
        faces = faces,
    }

    src._holoBsp2Model = out
    src._holoBsp2Gen = CACHE_GENERATION
    return out
end

--- @param src table NikNaks static prop.
--- @return { model: string, origin: Vector, angles: Angle, skin: number }
local function adaptStaticProp(src)
    return {
        model = src:GetModel(),
        origin = src:GetPos(),
        angles = src:GetAngles(),
        skin = src:GetSkin(),
    }
end

--- Materializes the current map's adapted view: worldspawn at models[1],
--- bmodels at models[2..], plus static props.
--- @return table?
local function buildCurrent()
    local map, mapErr = ensureNikNaksMap()
    if not map then
        ErrorNoHalt('[bsp2] ' .. tostring(mapErr) .. '\n')
        return nil
    end

    local models = {}

    local bmodels = map:GetBModels() or {}
    local worldModel = bmodels[0]
    if not worldModel then return nil end
    models[1] = adaptModel(map, worldModel)

    for key, bmodel in pairs(bmodels) do
        if isnumber(key) and key > 0 then
            models[key + 1] = adaptModel(map, bmodel)
        end
    end

    local props = {}
    for _, prop in ipairs(orderedValues(map:GetStaticProps())) do
        props[#props + 1] = adaptStaticProp(prop)
    end

    CURRENT = {
        -- Legacy world-face fallback used by cl_map.lua; canonical source is models[1].
        faces = models[1].faces,
        models = models,
        props = props,
    }

    return CURRENT
end

--- @return table?
function bsp2.GetCurrent()
    return CURRENT or buildCurrent()
end

if CLIENT then
    local MATERIALS = {}
    local MATERIALS_READY = false

    local function destroyModelInfo()
        MATERIALS = {}
        MATERIALS_READY = false
    end

    --- Returns the per-texinfo UnlitGeneric fallback material, cached on the texinfo.
    --- @param tinfo table
    --- @return IMaterial
    local function materialForTexInfo(tinfo)
        if tinfo._holoBsp2Material then return tinfo._holoBsp2Material end

        local mat = Material(tinfo.texdata.material)
        local btn = mat:GetTexture('$basetexture')
        if btn then
            mat = CreateMaterial(tostring(tinfo) .. '_texinfo', 'UnlitGeneric', {
                ['$basetexture'] = btn:GetName(),
                ['$detailscale'] = 1,
                ['$reflectivity'] = util.StringToType(tostring(tinfo.texdata.reflectivity), 'Vector'),
                ['$model'] = 1,
            })
        end

        tinfo._holoBsp2Material = mat
        return mat
    end

    --- Builds the per-texinfo fallback material list and runs CurrentBSPReady.
    --- cl_map.lua owns all visible rendering; the only contract here is the
    --- material list keyed by 'tostring(tinfo) .. _texinfo'.
    local function buildModelInfo()
        destroyModelInfo()

        local map = ensureNikNaksMap()
        if not map then return end

        local texinfos = orderedValues(map:GetTexInfo())
        for i = 1, #texinfos do
            MATERIALS[#MATERIALS + 1] = materialForTexInfo(adaptTexInfo(map, texinfos[i]))
        end

        MATERIALS_READY = true

        hook.Run('CurrentBSPReady')
        local bsp = bsp2.GetCurrent()
        MsgC(Color(120, 200, 255), string.format(
            '[bsp2] NikNaks BSP ready: faces=%d models=%d props=%d materials=%d\n',
            bsp and #bsp.faces or 0,
            bsp and #bsp.models or 0,
            bsp and #bsp.props or 0,
            #MATERIALS))
    end

    --- @return { meshes: table[], materials: IMaterial[], entities: table[], scale: number }?
    function bsp2.GetModelInfo()
        if not MATERIALS_READY then buildModelInfo() end
        if not MATERIALS_READY then return nil end

        return {
            meshes = {},
            materials = MATERIALS,
            entities = {},
            scale = SCALE,
        }
    end

    hook.Add('Initialize', 'bsp2.Initialize', function()
        timer.Simple(0, buildModelInfo)
    end)

    hook.Add('ShutDown', 'bsp2.Cleanup', destroyModelInfo)

    concommand.Add('bsp2_rebuild', function()
        CURRENT = nil
        buildModelInfo()
    end)
end
