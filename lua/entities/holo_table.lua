AddCSLuaFile()

ENT.Type 		= 'anim'
ENT.Base 		= 'base_anim'

ENT.PrintName		= 'Worldspawn Mesh'
ENT.Author		= 'Doctor'

ENT.Spawnable		= true
ENT.AdminSpawnable	= true
ENT.Editable        = true

function ENT:Initialize()
    if SERVER then
        self:SetModel('models/kingpommes/starwars/venator/galaxy_holo_1.mdl')
        self:PhysicsInit(SOLID_VPHYSICS)
    end
end

function ENT:SetupDataTables()
    self:NetworkVar('Bool', 0, 'Entities', { KeyName = 'entities', Edit = { type = 'Boolean' }})

    self:NetworkVar('Float', 0, 'Height', { KeyName = 'height', Edit = { type = 'Float', min = -500, max = 500 }})
end

function ENT:Draw()
    self:DrawModel()

    local map = bsp2.GetModelInfo()

    if not map then return end

    local offset = self:GetPos() + Vector(0, 0, self:GetHeight())

    local ang = Angle(0, 0, 0)
    local pos = EyePos() - offset

    pos:Rotate(ang)

    render.PushFilterMag(TEXFILTER.ANISOTROPIC)
    render.PushFilterMin(TEXFILTER.ANISOTROPIC)
    render.SetLightingMode(2)

    cam.Start3D(pos, EyeAngles())
        for k, v in ipairs(map.meshes) do
            render.SetMaterial(map.materials[k])
            v:Draw()
        end

        for k, v in ipairs(player.GetAll()) do
            render.SetColorMaterial()
            render.DrawSphere(v:GetPos() * map.scale, 0.25, 10, 10, Color(255, 0, 0))
        end

        for k, v in ipairs(ents.GetAll()) do
            if v:IsNPC() then
                render.SetColorMaterial()
                render.DrawSphere(v:GetPos() * map.scale, 0.25, 10, 10, Color(0, 0, 255))
            elseif v.LFS then
                render.DrawSphere(v:GetPos() * map.scale, 0.25, 10, 10, Color(0, 255, 255))
            end
        end

        if self:GetEntities() then
            for k, v in ipairs(map.entities) do
                v:DrawModel()
            end
        end
    cam.End3D()

    render.SetLightingMode(0)
    render.PopFilterMin()
    render.PopFilterMag()
end


