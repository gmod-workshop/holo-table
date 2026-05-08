-- Shared state and utility helpers for the holo table map subsystem.
-- Files in this folder are ordinary includes; anything intentionally
-- shared between them lives on ENT.MapCache.

local previousCleanup = _G.HOLO_TABLE_3D_CL_MAP_CLEANUP
if type(previousCleanup) == 'function' then
    local ok, err = pcall(previousCleanup)
    if not ok then ErrorNoHaltWithStack(err) end
end
_G.HOLO_TABLE_3D_CL_MAP_CLEANUP = nil

ENT.MapCache = {}
local MapCache = ENT.MapCache
local MapCacheEntity = ENT

-- Shared scratch objects used by prop draw paths. They intentionally live
-- for the whole hot-load generation to avoid per-prop Vector/Angle garbage.
MapCache.PROP_DRAW_SCRATCH_POS = Vector()
MapCache.PROP_DRAW_SCRATCH_ANG = Angle()

function ENT:_SafeDestroyMesh(item)
    if not item or not item.mesh then return end
    pcall(item.mesh.Destroy, item.mesh)
    item.mesh = nil
end

function MapCache.destroyMeshList(list)
    if not list then return end
    for _, item in ipairs(list) do
        MapCacheEntity._SafeDestroyMesh(MapCacheEntity, item)
    end
end

function MapCache.buildMeshFromTriangles(verts)
    local vertCount = #verts
    if vertCount < 3 then return nil end
    vertCount = vertCount - (vertCount % 3)

    local msh = Mesh()
    mesh.Begin(msh, MATERIAL_TRIANGLES, vertCount / 3)
    for i = 1, vertCount do
        local v = verts[i]
        mesh.Position(v.pos)
        if v.normal then mesh.Normal(v.normal) end
        mesh.TexCoord(0, v.u or 0, v.v or 0)
        if v.color then
            local c = v.color
            mesh.Color(c.r or 255, c.g or 255, c.b or 255, c.a or 255)
        end
        mesh.AdvanceVertex()
    end
    mesh.End()

    return msh
end
