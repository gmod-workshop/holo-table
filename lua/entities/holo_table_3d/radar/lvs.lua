-- LVS radar: mirror props for any ent with a .LVS marker, color-tinted
-- by AITEAM relative to the table's owning team.

-- Subtle tints so the source model is still readable. Friendly = same
-- AITEAM as the table, Hostile = different non-zero AITEAM, Neutral =
-- either side is team 0.
local TINT_FRIENDLY = { 0.45, 0.65, 1.00 }
local TINT_HOSTILE  = { 1.00, 0.45, 0.45 }
local TINT_NEUTRAL  = { 1.00, 1.00, 1.00 }

local function tintFor(tableTeam, entTeam)
    if tableTeam == 0 or entTeam == 0 then return TINT_NEUTRAL end
    if entTeam == tableTeam then return TINT_FRIENDLY end
    return TINT_HOSTILE
end

-- Sets up a client-side mirror prop for hologram-pose drawing. SetNoDraw
-- so the engine's auto-draw doesn't show a second full-size copy in PVS;
-- physics/collision dropped because we shove SetPos every frame.
local function makeMirror(model)
    local cs = ents.CreateClientProp(model)
    if not IsValid(cs) then return nil end
    cs:SetNoDraw(true)
    cs:SetSolid(SOLID_NONE)
    cs:SetMoveType(MOVETYPE_NONE)
    cs:PhysicsDestroy()
    return cs
end

function RADAR:Initialize()
    self.Tracked = {}
end

-- Single sweep: drop stale entries (and their mirrors), then add a
-- mirror for any new LVS ent we don't already track.
function RADAR:Think()
    local fresh = {}
    for _, v in pairs(self.Tracked) do
        if IsValid(v.ent) then
            fresh[v.ent:EntIndex()] = v
        elseif v.csent then
            SafeRemoveEntity(v.csent)
        end
    end

    for _, v in ents.Iterator() do
        if not v.LVS then continue end
        if fresh[v:EntIndex()] then continue end
        local model = v:GetModel()
        if not model or model == '' then continue end
        local cs = makeMirror(model)
        if not cs then continue end
        fresh[v:EntIndex()] = { ent = v, csent = cs }
    end

    self.Tracked = fresh
end

function RADAR:Draw()
    local team = self:GetEntity():GetTeam()
    local invScale = self:GetScale()
    render.SuppressEngineLighting(true)
    for _, v in pairs(self.Tracked) do
        local ent, csent = v.ent, v.csent
        if not (IsValid(ent) and IsValid(csent)) then continue end

        local entTeam = ent.GetAITEAM and ent:GetAITEAM() or ent.AITEAM or 0
        local tint = tintFor(team, entTeam)
        local wpos, wang = self:Project(ent:GetPos(), ent:GetAngles())
        csent:SetPos(wpos)
        csent:SetAngles(wang)
        csent:SetModelScale(invScale, 0)
        csent:SetupBones()

        render.SetColorModulation(tint[1], tint[2], tint[3])
        csent:DrawModel()
    end
    render.SetColorModulation(1, 1, 1)
    render.SuppressEngineLighting(false)
end

function RADAR:OnRemove()
    for _, v in pairs(self.Tracked) do
        if v.csent then SafeRemoveEntity(v.csent) end
    end
    self.Tracked = nil
end
