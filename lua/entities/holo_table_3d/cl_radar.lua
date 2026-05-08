-- Radar subsystem: module loader + ENT lifecycle hooks. Drop a file in
-- entities/holo_table_3d/radar/ defining RADAR:Initialize/Think/Draw/OnRemove.

--- @class RadarBase
--- @field entity Entity Owning holo_table_3d.
--- @field entityTable table Cached self:GetTable() of the owning entity.
--- Base inherited by every radar module. Per-entity instances see
--- self = inst -> mod -> RadarBase, so module bodies have these accessors.
local RadarBase = {}
RadarBase.__index = RadarBase

--- @return Entity table The owning holo_table_3d entity.
function RadarBase:GetEntity() return self.entity end

--- @return number invScale Inverse of the table's Scale; multiply BSP-space lengths by this.
function RadarBase:GetScale()  return self.entityTable._holoInvScale end

--- @return Vector world Hologram origin in world space (current frame).
function RadarBase:GetOrigin() return self.entityTable._holoOrigin end

--- @return Angle world Hologram angles in world space (current frame).
function RadarBase:GetAngles() return self.entityTable._holoAngles end

local atan2, sqrt = math.atan2, math.sqrt
local cos, sin    = math.cos, math.sin
local DEG2RAD     = math.pi / 180
local RAD2DEG     = 180 / math.pi

-- Module-level scratch reused across every Project call. Lifetime contract:
-- the returned Vector/Angle are valid only until the next Project on any
-- radar instance; every consumer reads them immediately.
local PROJ_POS    = Vector()
local PROJ_ANG    = Angle()

--- Maps a BSP-space (pos, ang) into the hologram's world-space slot.
--- Only valid inside a module's Draw (the _holo* fields are staged for the
--- current frame by then). Returns shared scratch -- read immediately.
--- @param pos Vector BSP-space position.
--- @param ang Angle? BSP-space angles (optional).
--- @return Vector worldPos
--- @return Angle? worldAng
function RadarBase:Project(pos, ang)
    local e   = self.entityTable
    local s   = e._holoInvScale
    local lx, ly, lz = pos.x * s, pos.y * s, pos.z * s
    local tFx, tFy, tFz = e._holoFx, e._holoFy, e._holoFz
    local tRx, tRy, tRz = e._holoRx, e._holoRy, e._holoRz
    local tUx, tUy, tUz = e._holoUx, e._holoUy, e._holoUz
    PROJ_POS:SetUnpacked(
        e._holoOx + tFx * lx - tRx * ly + tUx * lz,
        e._holoOy + tFy * lx - tRy * ly + tUy * lz,
        e._holoOz + tFz * lx - tRz * ly + tUz * lz)
    if not ang then return PROJ_POS end

    -- Build the input angle's basis directly from cos/sin (Source mathlib).
    local sp, cp = sin(ang.p * DEG2RAD), cos(ang.p * DEG2RAD)
    local sy, cy = sin(ang.y * DEG2RAD), cos(ang.y * DEG2RAD)
    local sr, cr = sin(ang.r * DEG2RAD), cos(ang.r * DEG2RAD)
    local pFx, pFy, pFz =  cp * cy,             cp * sy,             -sp
    local pRx, pRy, pRz = -sr * sp * cy + cr * sy, -sr * sp * sy - cr * cy, -sr * cp
    local pUx, pUy, pUz =  cr * sp * cy + sr * sy,  cr * sp * sy - sr * cy,  cr * cp

    -- Compose with the table basis; only the components needed for Euler.
    local wFx = tFx * pFx - tRx * pFy + tUx * pFz
    local wFy = tFy * pFx - tRy * pFy + tUy * pFz
    local wFz = tFz * pFx - tRz * pFy + tUz * pFz
    local wRz = tFz * pRx - tRz * pRy + tUz * pRz
    local wUz = tFz * pUx - tRz * pUy + tUz * pUz
    PROJ_ANG:SetUnpacked(
        atan2(-wFz, sqrt(wFx * wFx + wFy * wFy)) * RAD2DEG,
        atan2(wFy, wFx) * RAD2DEG,
        atan2(-wRz, wUz) * RAD2DEG)
    return PROJ_POS, PROJ_ANG
end

local registry = {}

--- Walks radar/*.lua, sets _G.RADAR to a fresh per-module table chained to
--- RadarBase, includes the file, and pushes the populated module onto the registry.
local function loadModules()
    registry = {}
    for _, fname in ipairs(file.Find('entities/holo_table_3d/radar/*.lua', 'LUA')) do
        local mod = setmetatable({}, RadarBase)
        mod.__index = mod
        _G.RADAR = mod
        local ok, err = pcall(include, 'entities/holo_table_3d/radar/' .. fname)
        _G.RADAR = nil
        if not ok then
            MsgC(Color(255, 120, 120),
                '[holo_table] radar module ' .. fname .. ' failed to load: ' .. tostring(err) .. '\n')
            continue
        end
        mod.Name = mod.Name or string.StripExtension(fname)
        table.insert(registry, mod)
    end
end

loadModules()

--- Builds one instance per registered module on self.Radars.
--- Lookup chain is inst -> mod -> RadarBase.
function ENT:InitializeRadar()
    local selfTbl = self:GetTable()
    selfTbl.Radars = {}
    for _, mod in ipairs(registry) do
        local inst = setmetatable({ entity = self, entityTable = selfTbl }, mod)
        if isfunction(inst.Initialize) then inst:Initialize() end
        selfTbl.Radars[mod.Name] = inst
    end
end

--- Iterates every module's Think. Lazy-inits if Radars is missing so live
--- reload against an already-spawned entity doesn't crash.
function ENT:ThinkRadar()
    local selfTbl = self:GetTable()
    if not selfTbl.Radars then self:InitializeRadar() end
    for _, inst in pairs(selfTbl.Radars) do
        if isfunction(inst.Think) then inst:Think() end
    end
end

--- Iterates every module's Draw. Runs outside the m2 matrix block in
--- DrawHologram because Entity:DrawModel ignores cam matrices.
--- @see ENT:DrawHologram
--- @see RadarBase.Project
function ENT:DrawRadar()
    local radars = self:GetTable().Radars
    if not radars then return end
    for _, inst in pairs(radars) do
        if isfunction(inst.Draw) then inst:Draw() end
    end
end

function ENT:CleanupRadar()
    local selfTbl = self:GetTable()
    if not selfTbl.Radars then return end
    for _, inst in pairs(selfTbl.Radars) do
        if isfunction(inst.OnRemove) then inst:OnRemove() end
    end
    selfTbl.Radars = nil
end

concommand.Add('holo_table_radar_reload', function()
    loadModules()

    local count = 0
    for _, ent in ents.Iterator() do
        if ent:GetClass() ~= 'holo_table_3d' then continue end
        if not (ent.CleanupRadar and ent.InitializeRadar) then continue end

        ent:CleanupRadar()
        ent:InitializeRadar()
        count = count + 1
    end

    print('[holo_table] reloaded radar modules for ' .. count .. ' table(s)')
end)
