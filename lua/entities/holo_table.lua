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
    end
end

function ENT:SetupDataTables()
    self:NetworkVar('Bool', 0, 'Entities', { KeyName = 'entities', Edit = { type = 'Boolean' }})
    self:NetworkVar('Bool', 1, 'Map', { KeyName = 'map', Edit = { type = 'Boolean' }})

    self:NetworkVar('Float', 0, 'Height', { KeyName = 'height', Edit = { type = 'Float', min = -500, max = 500 }})
    self:NetworkVar('Float', 1, 'Scale', { KeyName = 'scale', Edit = { type = 'Float', min = 1, max = 500 } })
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

    local pos = self:GetPos() + Vector(0, 0, 27)
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

    local m2 = Matrix()
    m2:Translate(self:GetPos() + Vector(0, 0, self:GetHeight()))
    m2:SetAngles(self:GetAngles())
    m2:SetScale(Vector(1 / scale, 1 / scale, 1 / scale))

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

        for k, v in ipairs(player.GetAll()) do
            render.SetColorMaterial()
            render.DrawSphere(v:GetPos(), scale, 10, 10, Color(255, 0, 0))
        end

        for k, v in ipairs(ents.GetAll()) do
            if v:IsNPC() then
                render.SetColorMaterial()
                render.DrawSphere(v:GetPos(), scale, 10, 10, Color(0, 0, 255))
            elseif v.LFS or v.IsSWVehicle or v.IsSWVRVehicle then
                render.SetColorMaterial()
                render.DrawSphere(v:GetPos(), scale, 10, 10, Color(0, 255, 255))
            end
        end

        if self:GetEntities() then
            for k, v in ipairs(map.entities) do
                v:DrawModel()
            end
        end
    cam.PopModelMatrix()

    render.SetLightingMode(0)
    render.PopFilterMin()
    render.PopFilterMag()

    render.SetStencilEnable(false)

    self:DrawModel()
end
