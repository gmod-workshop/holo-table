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

        self:SetMap(true)
        self:SetEntities(true)
        self:SetHeight(381.8)
        self:SetScale(36)
    end

    if CLIENT then
        local meshes = util.GetModelMeshes('models/props_phx/construct/metal_plate_curve360x2.mdl')

        self.Mask = Mesh()
        self.Mask:BuildFromTriangles(meshes[1].triangles)

        self.Ghosts = {}
    end
end

function ENT:SetupDataTables()
    self:NetworkVar('Bool', 0, 'Entities', { KeyName = 'entities', Edit = { type = 'Boolean' }})
    self:NetworkVar('Bool', 1, 'Map', { KeyName = 'map', Edit = { type = 'Boolean' }})

    self:NetworkVar('Float', 0, 'Height', { KeyName = 'height', Edit = { type = 'Float', min = -500, max = 500 }})
    self:NetworkVar('Float', 1, 'Scale', { KeyName = 'scale', Edit = { type = 'Float', min = 1, max = 500 } })
end

function ENT:Think()
    if SERVER then return end

    local ghosts = {}
    for k, v in pairs(self.Ghosts) do
        if IsValid(v.ent) then
            ghosts[v.ent:EntIndex()] = v
        else
            SafeRemoveEntity(v.csent)
        end
    end

    for k, v in ipairs(ents.GetAll()) do
        if not (v.LFS or v.IsSWVehicle or v.IsSWVRVehicle) then continue end

        if ghosts[v:EntIndex()] and IsValid(ghosts[v:EntIndex()].csent) then continue end

        local ent = ents.CreateClientProp(v:GetModel())

        ghosts[v:EntIndex()] = { ent = v, csent = ent }
    end

    self.Ghosts = ghosts
end

function ENT:OnRemove()
    if SERVER then return end

    for k, v in ipairs(self.Ghosts) do
        SafeRemoveEntity(v.csent)
    end
end

function ENT:Draw()
    if not self.Mask then return end

    local map = bsp2.GetModelInfo()

    if not map then self:DrawModel() return end

    local scale = self:GetScale()

    -- Reset everything to known good
    render.SetStencilWriteMask( 0xFF )
    render.SetStencilTestMask( 0xFF )

    render.ClearStencil()

    render.SetStencilEnable(true)

    render.SetStencilReferenceValue( 1 ) --Reference value 1
    render.SetStencilCompareFunction(STENCIL_ALWAYS)
    render.SetStencilPassOperation(STENCIL_REPLACE)

    -- This was for drawing a circle mesh
    -- This almost works, but tall parts of the mesh get cut off
    local size = 90
    local segments = 32

    local pos = self:GetPos() + self:GetUp() * 26
    local up = self:GetAngles():Right()
    local right = self:GetAngles():Forward()

    render.SetColorMaterial()
    mesh.Begin( MATERIAL_POLYGON, segments )

    for i = 0, segments - 1 do
        local rot = math.pi * 2 * ( i / segments )
        local sin = math.sin( rot ) * size
        local cos = math.cos( rot ) * size

        mesh.Position( pos + ( up * sin ) + ( right * cos ) )
        mesh.AdvanceVertex()
    end

    mesh.End()

    -- This uses an existing cylinder model
    -- This sorta works as well, but leaves a lot of black pixels
    -- local m = Matrix()
    -- m:Translate(self:GetPos() + Vector(0, 0, 27))
    -- m:SetAngles(self:GetAngles())
    -- m:Scale(Vector(2, 2, 2))

    -- cam.PushModelMatrix(m)
    --     self.Mask:Draw()
    -- cam.PopModelMatrix()

    -- Begin actual drawing of meshes using set stencil

    render.SetStencilCompareFunction( STENCIL_EQUAL ) --Only draw if pixel value == reference value
    render.ClearBuffersObeyStencil( 0, 0, 0, 0, true )

    -- Use a clip plane to stop anything below the plane of the table from being rendered
    local clip = render.EnableClipping(true)
    render.PushCustomClipPlane(self:GetUp(), self:GetUp():Dot(self:GetPos() + Vector(0, 0, 25)))

    local m2 = Matrix()
    m2:SetTranslation(self:GetPos() + self:GetUp() * self:GetHeight())
    m2:SetAngles(self:GetAngles())
    m2:Scale(Vector(1 / scale, 1 / scale, 1 / scale))

    render.PushFilterMag(TEXFILTER.ANISOTROPIC)
    render.PushFilterMin(TEXFILTER.ANISOTROPIC)
    render.SetLightingMode(2)

    cam.PushModelMatrix(m2)
        if self:GetMap() then
            for k, v in ipairs(map.meshes) do
                render.SetMaterial(map.materials[k])
                v:Draw()
            end
        end

        if self:GetEntities() then
            for k, v in ipairs(map.entities) do
                v:DrawModel()
            end
        end

        for k, v in pairs(self.Ghosts) do
            v.csent:SetPos(v.ent:GetPos())
            v.csent:SetAngles(v.ent:GetAngles())
            v.csent:SetModelScale(1 / scale, 0)
            v.csent:DrawModel()

            render.SetColorMaterial()
            -- render.SetColorModulation( 255, 0, 0 )
            render.DrawSphere(v.ent:GetPos(), scale, 10, 10, Color(255, 0, 0, 255))
        end

        for k, v in ipairs(player.GetAll()) do
            render.SetColorMaterial()
            render.DrawSphere(v:GetPos(), scale, 10, 10, Color(255, 0, 0))
        end
    cam.PopModelMatrix()

    render.SetLightingMode(0)
    render.PopFilterMin()
    render.PopFilterMag()

    render.SetStencilEnable(false)

    render.PopCustomClipPlane()
    render.EnableClipping(clip)

    self:DrawModel()
end
