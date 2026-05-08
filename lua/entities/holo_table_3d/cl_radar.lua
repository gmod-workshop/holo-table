-- Radar subsystem: a tiny module loader plus ENT lifecycle hooks that
-- iterate the registered modules. Drop a file in
-- entities/holo_table_3d/radar/ that defines RADAR:Initialize/Think/
-- Draw/OnRemove (any subset) and it gets picked up here.
--
-- Public surface on ENT: InitializeRadar, ThinkRadar, DrawRadar,
-- CleanupRadar -- wired from cl_init.lua's Initialize/Think/OnRemove
-- and DrawHologram.

-- Methods inherited by every module's RADAR table, and through it by
-- every per-entity instance. GetScale returns the *inverse* scale (the
-- factor the modules actually want when drawing into the table) since
-- no module has wanted the forward direction yet. All accessors read
-- the shared hologram transform staged on the entity by
-- ENT:UpdateHologramTransform (cl_init.lua) once per frame.
local RadarBase = {}
RadarBase.__index = RadarBase

--- @return Entity
function RadarBase:GetEntity() return self.entity end
--- @return number
function RadarBase:GetScale()  return self.entityTable._holoInvScale end
--- @return Vector
function RadarBase:GetOrigin() return self.entityTable._holoOrigin end
--- @return Angle
function RadarBase:GetAngles() return self.entityTable._holoAngles end

-- Hot-loop math locals; module-level scratch Vector/Angle are reused
-- across every Project call so the per-entry allocation drops from
-- (1 Vec + 1 Vec + 1 Ang for pos*invScale and the LocalToWorld returns)
-- to zero. Lifetime contract: the returned Vector/Angle are valid only
-- until the next Project call on any radar instance. Every consumer in
-- this addon reads them immediately (csent:SetPos(wpos); csent:Set-
-- Angles(wang); render.DrawSphere(self:Project(...))) so the contract
-- holds.
local atan2, sqrt = math.atan2, math.sqrt
local cos, sin    = math.cos, math.sin
local DEG2RAD     = math.pi / 180
local RAD2DEG     = 180 / math.pi
local PROJ_POS    = Vector()
local PROJ_ANG    = Angle()

-- Maps a BSP-space (pos, ang) into the hologram's world-space slot.
-- Only valid inside a module's Draw (the _holo* fields are staged for
-- the current frame by then). Math: world = O + R(tableAng) * (pos *
-- invScale), composed angle = R(tableAng) * R(ang) decomposed back to
-- Euler. Verified to match LocalToWorld(pos*inv, ang, _holoOrigin,
-- _holoAngles) within ~1e-5 across diverse cases.
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

    -- Build the input angle's basis directly from cos/sin (no Vector
    -- allocs from Angle:Forward/Right/Up). Source mathlib convention.
    local sp, cp = sin(ang.p * DEG2RAD), cos(ang.p * DEG2RAD)
    local sy, cy = sin(ang.y * DEG2RAD), cos(ang.y * DEG2RAD)
    local sr, cr = sin(ang.r * DEG2RAD), cos(ang.r * DEG2RAD)
    local pFx, pFy, pFz =  cp * cy,             cp * sy,             -sp
    local pRx, pRy, pRz = -sr * sp * cy + cr * sy, -sr * sp * sy - cr * cy, -sr * cp
    local pUx, pUy, pUz =  cr * sp * cy + sr * sy,  cr * sp * sy - sr * cy,  cr * cp

    -- Compose with the table basis (only the components needed for
    -- Euler extraction: full F, plus R.z and U.z).
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

-- Module registry. Each entry is the RADAR table populated by a file
-- in radar/, with __index chaining to RadarBase.
local registry = {}

local function loadModules()
    registry = {}
    for _, fname in ipairs(file.Find('entities/holo_table_3d/radar/*.lua', 'LUA')) do
        -- mod inherits from RadarBase (via RadarBase.__index = RadarBase)
        -- and is itself the metatable for per-entity instances, so the
        -- lookup chain is inst -> mod -> RadarBase.
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

-- Builds one instance per registered module; instance lookup is
-- inst -> RADAR -> RadarBase, so modules see a `self` that has both
-- their own methods and the base accessors.
function ENT:InitializeRadar()
    local selfTbl = self:GetTable()
    selfTbl.Radars = {}
    for _, mod in ipairs(registry) do
        local inst = setmetatable({ entity = self, entityTable = selfTbl }, mod)
        if isfunction(inst.Initialize) then inst:Initialize() end
        selfTbl.Radars[mod.Name] = inst
    end
end

function ENT:ThinkRadar()
    local selfTbl = self:GetTable()
    if not selfTbl.Radars then self:InitializeRadar() end
    for _, inst in pairs(selfTbl.Radars) do
        if isfunction(inst.Think) then inst:Think() end
    end
end

-- Iterates every module's Draw. Runs outside the m2 matrix block in
-- DrawHologram because Entity:DrawModel ignores cam matrices; modules
-- read the shared hologram transform via RadarBase accessors, which
-- pull from self._holo* (staged once per frame by
-- ENT:UpdateHologramTransform in cl_init.lua).
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
