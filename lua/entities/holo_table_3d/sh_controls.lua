-- Interactive control mode. Server owns ownership + authoritative NetworkVar
-- values; client mirrors the grant, polls input, and ships params back.

if SERVER then
    util.AddNetworkString('holo_table_autocenter')
    util.AddNetworkString('holo_table_focus_table')
    util.AddNetworkString('holo_table_control')
    util.AddNetworkString('holo_table_setparams')
    util.AddNetworkString('holo_table_setlayers')
    util.AddNetworkString('holo_table_release')

    --- SIMPLE_USE fires once per E press; base_anim's default is
    --- continuous-while-held and would flicker the toggle.
    function ENT:InitializeControls()
        self:SetUseType(SIMPLE_USE)
    end

    function ENT:CleanupControls()
        self:ReleaseController()
    end

    --- Toggles control of this table for the activator. A player can only
    --- control one table at a time; grabbing a new one releases any previous.
    --- @param activator Entity
    --- @param caller Entity
    function ENT:Use(activator, caller)
        if not (IsValid(activator) and activator:IsPlayer()) then return end

        if self.Controller == activator then
            self:ReleaseController()
            return
        end
        if IsValid(self.Controller) then return end

        for _, e in ipairs(ents.FindByClass('holo_table_3d')) do
            if e ~= self and e.Controller == activator then e:ReleaseController() end
        end

        self.Controller = activator
        net.Start('holo_table_control')
        net.WriteEntity(self)
        net.WriteBool(true)
        net.Send(activator)
    end

    --- Clears the controller and notifies the previous owner's client.
    function ENT:ReleaseController()
        local ply = self.Controller
        self.Controller = nil
        if IsValid(ply) then
            net.Start('holo_table_control')
            net.WriteEntity(self)
            net.WriteBool(false)
            net.Send(ply)
        end
    end

    --- Shared handler for autocenter / focus_table: client computes the
    --- target params, server clamps and rejects if owned by someone else.
    local function receiveSnapParams(_, ply)
        local ent = net.ReadEntity()
        local scale = math.Clamp(net.ReadFloat(), 1, 300)
        local panX = math.Clamp(net.ReadFloat(), -16384, 16384)
        local panY = math.Clamp(net.ReadFloat(), -16384, 16384)
        local height = math.Clamp(net.ReadFloat(), -500, 500)
        if not IsValid(ent) or ent:GetClass() ~= 'holo_table_3d' then return end
        if IsValid(ent.Controller) and ent.Controller ~= ply then return end
        ent:SetScale(scale)
        ent:SetPanX(panX)
        ent:SetPanY(panY)
        ent:SetHeight(height)
    end

    net.Receive('holo_table_autocenter', receiveSnapParams)
    net.Receive('holo_table_focus_table', receiveSnapParams)

    -- Live parameter feed from the active controller. Clamped to NetworkVar
    -- limits in shared.lua; ownership-gated.
    net.Receive('holo_table_setparams', function(_, ply)
        local ent    = net.ReadEntity()
        local scale  = math.Clamp(net.ReadFloat(), 1, 300)
        local height = math.Clamp(net.ReadFloat(), -500, 500)
        local panX   = math.Clamp(net.ReadFloat(), -16384, 16384)
        local panY   = math.Clamp(net.ReadFloat(), -16384, 16384)
        if not IsValid(ent) or ent:GetClass() ~= 'holo_table_3d' then return end
        if ent.Controller ~= ply then return end
        ent:SetScale(scale)
        ent:SetHeight(height)
        ent:SetPanX(panX)
        ent:SetPanY(panY)
    end)

    net.Receive('holo_table_setlayers', function(_, ply)
        local ent = net.ReadEntity()
        local map = net.ReadBool()
        local entities = net.ReadBool()
        if not IsValid(ent) or ent:GetClass() ~= 'holo_table_3d' then return end
        if ent.Controller ~= ply then return end
        ent:SetMap(map)
        ent:SetEntities(entities)
    end)

    net.Receive('holo_table_release', function(_, ply)
        local ent = net.ReadEntity()
        if not IsValid(ent) or ent:GetClass() ~= 'holo_table_3d' then return end
        if ent.Controller ~= ply then return end
        ent:ReleaseController()
    end)

    hook.Add('PlayerDisconnected', 'holo_table_3d.Controls', function(ply)
        for _, e in ipairs(ents.FindByClass('holo_table_3d')) do
            if e.Controller == ply then e:ReleaseController() end
        end
    end)

    return
end

local PAN_VISUAL_SPEED = 60   -- table-space units / sec at scale=1
local HEIGHT_STEP      = 10
local SCALE_FACTOR     = 1.10
local PRECISION_MUL    = 0.25 -- pan/height/zoom step multiplier while +duck held
local SEND_INTERVAL    = 0.033
local TABLE_FOCUS_SCALE  = 8
local TABLE_FOCUS_HEIGHT = 28

-- Mirrors shared.lua NetworkVar limits.
local SCALE_MIN, SCALE_MAX   = 1, 300
local HEIGHT_MIN, HEIGHT_MAX = -500, 500
local PAN_MIN, PAN_MAX       = -16384, 16384

--- @type Entity?
local controlled    = nil
local nextSendTime  = 0
local dirty         = false
local wasReloadDown = false
local wasMapDown    = false
local wasEntDown    = false


local function clearLocalState()
    controlled    = nil
    nextSendTime  = 0
    dirty         = false
    wasReloadDown = false
    wasMapDown    = false
    wasEntDown    = false
end

net.Receive('holo_table_control', function()
    local ent    = net.ReadEntity()
    local active = net.ReadBool()
    if active and IsValid(ent) then
        controlled = ent
    elseif controlled == ent or not IsValid(ent) then
        clearLocalState()
    end
end)

--- Throttled live parameter feed (scale/height/pan) for the active table.
--- @param ent Entity
local function sendParams(ent)
    net.Start('holo_table_setparams')
    net.WriteEntity(ent)
    net.WriteFloat(ent:GetScale())
    net.WriteFloat(ent:GetHeight())
    net.WriteFloat(ent:GetPanX())
    net.WriteFloat(ent:GetPanY())
    net.SendToServer()
end

--- Edge-triggered layer toggle send; bypasses the throttled setparams send.
--- @param ent Entity
local function sendLayers(ent)
    net.Start('holo_table_setlayers')
    net.WriteEntity(ent)
    net.WriteBool(ent:GetMap())
    net.WriteBool(ent:GetEntities())
    net.SendToServer()
end

--- Table-local pan basis projected onto BSP XY so movement keys drive
--- PanX/PanY consistently regardless of how the table is rotated.
--- @param ent Entity
--- @return Vector fwd
--- @return Vector right
local function panAxes(ent)
    local ang = ent:GetAngles()
    local fwd, right = ang:Forward(), ang:Right()
    fwd.z, right.z = 0, 0
    if fwd:LengthSqr() > 0 then fwd:Normalize() else fwd = Vector(1, 0, 0) end
    if right:LengthSqr() > 0 then right:Normalize() else right = Vector(0, -1, 0) end
    return fwd, right
end

--- Resolves the holo table for a control concommand: actively-controlled,
--- then under the crosshair, then nearest.
--- @return Entity?
local function findControlTarget()
    if IsValid(controlled) then return controlled end

    local lp = LocalPlayer()
    if not IsValid(lp) then return end

    local trEnt = lp:GetEyeTrace().Entity
    if IsValid(trEnt) and trEnt:GetClass() == 'holo_table_3d' then
        return trEnt
    end

    local best, bestDist = nil, math.huge
    for _, e in ipairs(ents.FindByClass('holo_table_3d')) do
        local d = e:GetPos():DistToSqr(lp:GetPos())
        if d < bestDist then best, bestDist = e, d end
    end
    return best
end

--- Applies a precomputed snap locally and ships it to the server. Server
--- replays the clamped authoritative values within ~RTT.
--- @param ent Entity
--- @param netName string
--- @param scale number
--- @param panX number
--- @param panY number
--- @param height number
--- @return boolean sent
local function sendSnapParams(ent, netName, scale, panX, panY, height)
    ent:SetScale(scale)
    ent:SetPanX(panX)
    ent:SetPanY(panY)
    ent:SetHeight(height)

    net.Start(netName)
    net.WriteEntity(ent)
    net.WriteFloat(scale)
    net.WriteFloat(panX)
    net.WriteFloat(panY)
    net.WriteFloat(height)
    net.SendToServer()
    return true
end

--- Computes auto-center params for ent and ships them to the server.
--- @param ent Entity
--- @return boolean sent
--- @see ENT:ComputeAutoCenter
local function sendAutoCenter(ent)
    if not (IsValid(ent) and ent.ComputeAutoCenter) then return false end
    local scale, panX, panY, height = ent:ComputeAutoCenter()
    if not scale then return false end

    return sendSnapParams(ent, 'holo_table_autocenter', scale, panX, panY, height)
end

--- Focuses the hologram on the physical holo table's own map position.
--- The model itself is hidden from the holo, but nearby radar entities
--- become readable without manual zooming.
--- @param ent Entity
--- @return boolean sent
local function sendTableFocus(ent)
    if not IsValid(ent) then return false end
    local pos = ent:GetPos()
    return sendSnapParams(ent, 'holo_table_focus_table',
        TABLE_FOCUS_SCALE, pos.x, pos.y, TABLE_FOCUS_HEIGHT)
end

hook.Add('CreateMove', 'holo_table_3d.Controls', function(cmd)
    local ent = controlled
    if not IsValid(ent) then
        if controlled then clearLocalState() end
        return
    end

    -- Capture +duck BEFORE RemoveKey scrubs it.
    local precise = cmd:KeyDown(IN_DUCK)
    local mul = precise and PRECISION_MUL or 1

    -- Suppress player movement so dragging the table doesn't also walk.
    cmd:ClearMovement()
    cmd:RemoveKey(IN_JUMP)
    cmd:RemoveKey(IN_DUCK)

    local dt = FrameTime()
    if dt <= 0 then return end

    -- Read off cmd button bits so user keybinds (ESDF, arrows, etc.) work.
    local f = cmd:KeyDown(IN_FORWARD)
    local b = cmd:KeyDown(IN_BACK)
    local l = cmd:KeyDown(IN_MOVELEFT)
    local r = cmd:KeyDown(IN_MOVERIGHT)
    if f or b or l or r then
        local fwd, right = panAxes(ent)
        local fInput = (f and 1 or 0) - (b and 1 or 0)
        local rInput = (r and 1 or 0) - (l and 1 or 0)
        local speed  = PAN_VISUAL_SPEED * ent:GetScale() * dt * mul
        local dx = (fwd.x * fInput + right.x * rInput) * speed
        local dy = (fwd.y * fInput + right.y * rInput) * speed
        if dx ~= 0 or dy ~= 0 then
            ent:SetPanX(math.Clamp(ent:GetPanX() + dx, PAN_MIN, PAN_MAX))
            ent:SetPanY(math.Clamp(ent:GetPanY() + dy, PAN_MIN, PAN_MAX))
            dirty = true
        end
    end

    local wheel = cmd:GetMouseWheel()
    if wheel ~= 0 then
        cmd:SetMouseWheel(0)
        if cmd:KeyDown(IN_SPEED) then
            -- Precision shrinks the multiplicative step (1.10 -> 1.025 by default).
            local factor = math.pow(1 + (SCALE_FACTOR - 1) * mul, wheel)
            ent:SetScale(math.Clamp(ent:GetScale() * factor, SCALE_MIN, SCALE_MAX))
        else
            ent:SetHeight(math.Clamp(ent:GetHeight() + wheel * HEIGHT_STEP * mul,
                HEIGHT_MIN, HEIGHT_MAX))
        end
        dirty = true
    end

    -- +reload edge: poll raw key, since PlayerBindPress below swallows the
    -- bind (so IN_RELOAD never fires). Clears `dirty` so a stale param
    -- update doesn't overwrite the snap on the next tick.
    local reloadKey = input.LookupBinding('+reload')
    local reload = reloadKey and input.IsKeyDown(input.GetKeyCode(reloadKey)) or false
    if reload and not wasReloadDown then
        local sent = cmd:KeyDown(IN_SPEED) and sendTableFocus(ent) or sendAutoCenter(ent)
        if sent then
            dirty = false
            nextSendTime = SysTime() + SEND_INTERVAL
        end
    end
    wasReloadDown = reload

    -- T / G layer toggles, raw-keyed because they have no +command bind.
    local entDown = input.IsKeyDown(KEY_T)
    if entDown and not wasEntDown then
        ent:SetEntities(not ent:GetEntities())
        sendLayers(ent)
    end
    wasEntDown = entDown

    local mapDown = input.IsKeyDown(KEY_G)
    if mapDown and not wasMapDown then
        ent:SetMap(not ent:GetMap())
        sendLayers(ent)
    end
    wasMapDown = mapDown

    if dirty and SysTime() >= nextSendTime then
        sendParams(ent)
        nextSendTime = SysTime() + SEND_INTERVAL
        dirty = false
    end
end)

-- Swallow conflicting binds: weapon-select scrolls, +reload (weapon
-- animation+sound), and the default T/G binds (messagemode / +menu_context).
hook.Add('PlayerBindPress', 'holo_table_3d.Controls', function(ply, bind, pressed)
    if not IsValid(controlled) then return end
    if bind == 'invnext' or bind == 'invprev' or bind == 'lastinv' then
        return true
    end
    if bind == '+reload' or bind == 'reload' then
        return true
    end
    if bind == 'messagemode' or bind == 'messagemode2'
        or bind == '+menu_context' or bind == '+menu' then
        return true
    end
end)

--- Looks up the player's bound key for cmd, returning fallback when unbound.
--- @param cmd string
--- @param fallback string
--- @return string
local function bindKey(cmd, fallback)
    local k = input.LookupBinding(cmd)
    return k and string.upper(k) or fallback
end

--- @return string keys Concatenated bound keys for the four pan commands.
local function panKeysHint()
    local f = bindKey('+forward', '?')
    local l = bindKey('+moveleft', '?')
    local b = bindKey('+back', '?')
    local r = bindKey('+moveright', '?')
    return f .. l .. b .. r
end

local function onOff(b) return b and 'ON' or 'OFF' end

hook.Add('HUDPaint', 'holo_table_3d.Controls', function()
    local ent = controlled
    if not IsValid(ent) then return end

    local x, y = ScrW() * 0.5, ScrH() - 78
    local hint1 = string.format(
        '[HOLO TABLE]  %s pan  -  Wheel height  -  %s+Wheel zoom  -  %s fit map  -  %s+%s table',
        panKeysHint(),
        bindKey('+speed', 'SHIFT'),
        bindKey('+reload', 'R'),
        bindKey('+speed', 'SHIFT'),
        bindKey('+reload', 'R'))
    local hint2 = string.format(
        'T entities (%s)  -  G map (%s)  -  hold %s for precision  -  %s exit',
        onOff(ent:GetEntities()),
        onOff(ent:GetMap()),
        bindKey('+duck', 'CTRL'),
        bindKey('+use', 'E'))
    local stats = string.format('scale %.1f   height %.1f   pan (%.0f, %.0f)',
        ent:GetScale(), ent:GetHeight(), ent:GetPanX(), ent:GetPanY())

    draw.SimpleText(hint1, 'DermaDefaultBold', x, y,
        color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    draw.SimpleText(hint2, 'DermaDefault', x, y + 18,
        color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    draw.SimpleText(stats, 'DermaDefault', x, y + 36,
        color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end)

-- Manual release for when the player walked away from the table.
concommand.Add('holo_table_release', function()
    if not IsValid(controlled) then return end
    net.Start('holo_table_release')
    net.WriteEntity(controlled)
    net.SendToServer()
end)

concommand.Add('holo_table_autocenter', function()
    local ent = findControlTarget()
    if not IsValid(ent) then
        MsgC(Color(255, 120, 120), '[holo_table] No holo_table_3d found.\n')
        return
    end
    if not sendAutoCenter(ent) then
        MsgC(Color(255, 120, 120), '[holo_table] No BSP available (bsp2 not loaded).\n')
        return
    end

    MsgC(Color(120, 200, 255),
        string.format('[holo_table] Auto-center: scale=%d pan=(%.0f, %.0f) height=%.1f\n',
            ent:GetScale(), ent:GetPanX(), ent:GetPanY(), ent:GetHeight()))
end)

concommand.Add('holo_table_focus_table', function()
    local ent = findControlTarget()
    if not IsValid(ent) then
        MsgC(Color(255, 120, 120), '[holo_table] No holo_table_3d found.\n')
        return
    end
    if not sendTableFocus(ent) then
        MsgC(Color(255, 120, 120), '[holo_table] Could not focus table.\n')
        return
    end

    MsgC(Color(120, 200, 255),
        string.format('[holo_table] Table focus: scale=%d pan=(%.0f, %.0f) height=%.1f\n',
            ent:GetScale(), ent:GetPanX(), ent:GetPanY(), ent:GetHeight()))
end)
