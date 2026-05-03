AddCSLuaFile('shared.lua')
AddCSLuaFile('cl_init.lua')
AddCSLuaFile('sh_controls.lua')
AddCSLuaFile('cl_radar.lua')
AddCSLuaFile('cl_map.lua')

-- Drop a .lua into entities/holo_table_3d/radar/ and the client picks
-- it up via cl_radar.lua's loader; this loop just makes sure each one
-- ships to clients.
for _, f in ipairs((file.Find('entities/holo_table_3d/radar/*.lua', 'LUA'))) do
    AddCSLuaFile('radar/' .. f)
end

include('shared.lua')
include('sh_controls.lua')

function ENT:Initialize()
    self:SetModel('models/kingpommes/starwars/venator/galaxy_holo_1.mdl')
    self:PhysicsInit(SOLID_VPHYSICS)

    self:InitializeControls()

    self:SetMap(true)
    self:SetEntities(true)
    self:SetHeight(381.8)
    self:SetScale(36)
end

function ENT:OnRemove()
    self:CleanupControls()
end
