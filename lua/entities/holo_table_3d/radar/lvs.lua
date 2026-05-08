-- LVS radar: mirror props for any ent with a .LVS marker, color-tinted
-- by AITEAM relative to the table's owning team, plus projected LVS
-- bullet tracers captured from the clientside effect path.

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

local TRACER_MAT_BEAM  = Material('effects/spark')
local TRACER_MAT_GLOW  = Material('sprites/light_glow02_add')
local TRACER_MAX_AGE   = 2
local TRACER_MIN_WIDTH = 0.7
local TRACER_MAX_WIDTH = 3.5
local TRACER_COLORS = {
    red     = Color(255, 80, 70, 230),
    green   = Color(80, 255, 120, 230),
    blue    = Color(100, 170, 255, 230),
    yellow  = Color(255, 230, 90, 230),
    orange  = Color(255, 150, 70, 230),
    white   = Color(240, 250, 255, 230),
    proton  = Color(180, 120, 255, 230),
    default = Color(100, 220, 255, 230),
}
local TRACER_CORE_COLOR = Color(255, 255, 255, 235)
local TRACER_START = Vector()
local TRACER_END = Vector()

local tracerState = _G.HOLO_TABLE_3D_LVS_TRACERS
if tracerState and isfunction(tracerState.restore) then
    tracerState.restore()
end

tracerState = {
    items = {},
    nextPurge = 0,
    oldEffect = util.Effect,
}
_G.HOLO_TABLE_3D_LVS_TRACERS = tracerState

local function tracerColor(name)
    name = string.lower(tostring(name or ''))
    if name:find('red', 1, true) then return TRACER_COLORS.red end
    if name:find('green', 1, true) then return TRACER_COLORS.green end
    if name:find('blue', 1, true) then return TRACER_COLORS.blue end
    if name:find('yellow', 1, true) then return TRACER_COLORS.yellow end
    if name:find('orange', 1, true) then return TRACER_COLORS.orange end
    if name:find('white', 1, true) then return TRACER_COLORS.white end
    if name:find('proton', 1, true) then return TRACER_COLORS.proton end
    return TRACER_COLORS.default
end

local function captureTracerEffect(effectName, data)
    if not (data and LVS and LVS.GetBullet) then return end

    local now = CurTime()
    if now >= tracerState.nextPurge then
        tracerState.nextPurge = now + 1
        for id, tr in pairs(tracerState.items) do
            if now - tr.born > TRACER_MAX_AGE or not LVS:GetBullet(id) then
                tracerState.items[id] = nil
            end
        end
    end

    local ok, id = pcall(data.GetMaterialIndex, data)
    if not ok or not id then return end

    local bullet = LVS:GetBullet(id)
    if not bullet then return end

    local shooter = bullet.Entity
    if not (IsValid(shooter) and shooter.LVS) then return end

    -- Generic LVS bullet effects carry their own tracer effect name on
    -- the bullet. This filters smoke/exhaust effects whose material
    -- index may coincidentally reference a live bullet.
    if bullet.TracerName ~= effectName then return end

    tracerState.items[id] = {
        born = now,
        color = tracerColor(effectName),
    }
end

local function effectWrapper(effectName, data, allowOverride, filter)
    captureTracerEffect(effectName, data)
    return tracerState.oldEffect(effectName, data, allowOverride, filter)
end
tracerState.wrapper = effectWrapper
util.Effect = effectWrapper

tracerState.restore = function()
    if util.Effect == tracerState.wrapper then
        util.Effect = tracerState.oldEffect
    end
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

local function drawTracers(radar)
    if not (LVS and LVS.GetBullet) then return end

    local now = CurTime()
    render.SetMaterial(TRACER_MAT_GLOW)
    for id, tr in pairs(tracerState.items) do
        local bullet = LVS:GetBullet(id)
        if not bullet or now - tr.born > TRACER_MAX_AGE then
            tracerState.items[id] = nil
            continue
        end
        if not (bullet.GetPos and bullet.GetDir and bullet.GetLength) then
            tracerState.items[id] = nil
            continue
        end

        local pos = bullet:GetPos()
        local dir = bullet:GetDir()
        local len = 1000 * (bullet:GetLength() or 1)
        local startPos = pos - dir * len
        local endPos = pos + dir * len * 0.1
        local wStart = radar:Project(startPos)
        TRACER_START:SetUnpacked(wStart.x, wStart.y, wStart.z)
        local wEnd = radar:Project(endPos)
        TRACER_END:SetUnpacked(wEnd.x, wEnd.y, wEnd.z)

        local width = math.Clamp(len * radar:GetScale() * 0.025, TRACER_MIN_WIDTH, TRACER_MAX_WIDTH)
        render.DrawBeam(TRACER_START, TRACER_END, width * 1.8, 1, 0, tr.color)

        render.SetMaterial(TRACER_MAT_BEAM)
        render.DrawBeam(TRACER_START, TRACER_END, width, 1, 0, tr.color)
        render.DrawBeam(TRACER_START, TRACER_END, math.max(width * 0.35, 0.25), 1, 0, TRACER_CORE_COLOR)
        render.SetMaterial(TRACER_MAT_GLOW)
    end
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

    drawTracers(self)
end

function RADAR:OnRemove()
    for _, v in pairs(self.Tracked) do
        if v.csent then SafeRemoveEntity(v.csent) end
    end
    self.Tracked = nil
end
