-- Marker-sphere radar for non-LVS vehicles (LFS, simfphys, scars, etc).
-- No mirror prop; we just project the source position and draw a sphere.

local function isOtherVehicle(v)
    return v.LFS or v.IsSWVehicle or v.IsSWVRVehicle
end

function RADAR:Initialize()
    self.Tracked = {}
end

function RADAR:Think()
    local fresh = {}
    for _, ent in pairs(self.Tracked) do
        if IsValid(ent) then fresh[ent:EntIndex()] = ent end
    end
    for _, v in ents.Iterator() do
        if not isOtherVehicle(v) then continue end
        fresh[v:EntIndex()] = v
    end
    self.Tracked = fresh
end

function RADAR:Draw()
    render.SetColorMaterial()
    for _, ent in pairs(self.Tracked) do
        if not IsValid(ent) then continue end
        render.DrawSphere(self:Project(ent:GetPos()), 1, 10, 10, Color(255, 0, 0))
    end
end

function RADAR:OnRemove()
    self.Tracked = nil
end
