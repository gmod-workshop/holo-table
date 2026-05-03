-- Marker-sphere radar for players. Engine already keeps the live
-- player list, so no Initialize/Think/OnRemove state is needed; we
-- just iterate per-frame in Draw.

function RADAR:Draw()
    render.SetColorMaterial()
    for _, ply in player.Iterator() do
        if not IsValid(ply) then continue end
        render.DrawSphere(self:Project(ply:GetPos()), 1, 10, 10, Color(255, 0, 0))
    end
end
