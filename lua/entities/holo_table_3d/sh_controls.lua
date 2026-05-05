-- Interactive control mode for holo_table_3d. Server owns ownership
-- (one controller per table) and authoritative NetworkVar values; the
-- client mirrors the active grant, polls input in CreateMove, and ships
-- parameters back to the server (throttled) for the authoritative
-- replay. Lifecycle hooks ENT:InitializeControls / ENT:CleanupControls
-- are called from init.lua's Initialize / OnRemove.

if SERVER then
    util.AddNetworkString('holo_table_autocenter')
    util.AddNetworkString('holo_table_control')
    util.AddNetworkString('holo_table_setparams')
    util.AddNetworkString('holo_table_setlayers')
    util.AddNetworkString('holo_table_release')

    -- SIMPLE_USE fires Use once per E press (instead of base_anim's
    -- default continuous-while-held), so the controls toggle reliably
    -- and doesn't flicker when the player holds the key.
    function ENT:InitializeControls()
        self:SetUseType(SIMPLE_USE)
    end

    function ENT:CleanupControls()
        self:ReleaseController()
    end

    -- Toggles interactive control of this table for the activator. Each
    -- player can only control one table at a time; grabbing a new one
    -- implicitly releases any previous. Other players are locked out
    -- until the current controller releases or disconnects.
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

    net.Receive('holo_table_autocenter', function(_, ply)
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
    end)

    -- Live parameter feed from the active controller. Clamped to the
    -- NetworkVar limits in shared.lua so a malicious client can't push
    -- nonsense values; ownership check keeps non-controllers locked out.
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

    -- Layer visibility toggles from the active controller. Same ownership
    -- gate as setparams; bools are unconstrained so no clamp needed.
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

-- ---------------------------------------------------------------------
-- Client: input polling, HUD, control concommands. Player presses +use
-- on a table to grab control; while controlling, +forward/+back/
-- +moveleft/+moveright pan, mouse wheel adjusts height, +speed+wheel
-- adjusts scale, +reload re-centers. Movement keys are read off the
-- cmd's button bits (cmd:KeyDown) so user keybinds are respected.
-- NetworkVar writes are optimistic on the client (snappy) and
-- re-confirmed by the server's next snapshot.
-- ---------------------------------------------------------------------

local PAN_VISUAL_SPEED = 60   -- table-space units / sec at scale=1 (cylinder radius is 90)
local HEIGHT_STEP      = 10   -- world units per scroll tick (scale-invariant)
local SCALE_FACTOR     = 1.10 -- multiplicative per shift+scroll tick
local PRECISION_MUL    = 0.25 -- pan/height/zoom step multiplier while +duck held
local SEND_INTERVAL    = 0.033

-- Mirrors the NetworkVar limits in shared.lua.
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

-- Edge-triggered layer toggles bypass the throttled setparams send so
-- the visibility flip is immediate. Optimistic local write mirrors the
-- pattern used everywhere else in this file.
--- @param ent Entity
local function sendLayers(ent)
    net.Start('holo_table_setlayers')
    net.WriteEntity(ent)
    net.WriteBool(ent:GetMap())
    net.WriteBool(ent:GetEntities())
    net.SendToServer()
end

-- Table-local pan basis projected onto BSP XY so PanX/PanY (which are
-- world-XY) can be driven by movement keys regardless of how the table
-- is rotated. Falls back to world axes if the table is somehow vertical.
local function panAxes(ent)
    local ang = ent:GetAngles()
    local fwd, right = ang:Forward(), ang:Right()
    fwd.z, right.z = 0, 0
    if fwd:LengthSqr() > 0 then fwd:Normalize() else fwd = Vector(1, 0, 0) end
    if right:LengthSqr() > 0 then right:Normalize() else right = Vector(0, -1, 0) end
    return fwd, right
end

-- Picks a target holo table for a control-mode action issued without an
-- entity reference (concommand): prefers the actively-controlled table,
-- then the entity under the player's crosshair, then the nearest one.
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

-- Computes auto-center params for `ent` and ships them to the server.
-- Optimistic local write so the table snaps the same frame; server
-- replays with the (clamped) authoritative values within ~RTT. Returns
-- true if a message was sent. ENT:ComputeAutoCenter lives in cl_map.
--- @param ent Entity
local function sendAutoCenter(ent)
    if not (IsValid(ent) and ent.ComputeAutoCenter) then return false end
    local scale, panX, panY, height = ent:ComputeAutoCenter()
    if not scale then return false end

    ent:SetScale(scale)
    ent:SetPanX(panX)
    ent:SetPanY(panY)
    ent:SetHeight(height)

    net.Start('holo_table_autocenter')
    net.WriteEntity(ent)
    net.WriteFloat(scale)
    net.WriteFloat(panX)
    net.WriteFloat(panY)
    net.WriteFloat(height)
    net.SendToServer()
    return true
end

hook.Add('CreateMove', 'holo_table_3d.Controls', function(cmd)
    local ent = controlled
    if not IsValid(ent) then
        if controlled then clearLocalState() end
        return
    end

    -- Capture +duck (precision modifier) BEFORE RemoveKey scrubs it,
    -- otherwise cmd:KeyDown(IN_DUCK) below would always read false.
    local precise = cmd:KeyDown(IN_DUCK)
    local mul = precise and PRECISION_MUL or 1

    -- Suppress player movement so dragging the table doesn't also walk.
    -- +use is left alone so pressing E on the same table still toggles.
    cmd:ClearMovement()
    cmd:RemoveKey(IN_JUMP)
    cmd:RemoveKey(IN_DUCK)

    local dt = FrameTime()
    if dt <= 0 then return end

    -- Read movement off the cmd's button bits instead of literal WASD
    -- so user keybinds (ESDF, arrow keys, etc.) drive panning.
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
            -- Precision shrinks the multiplicative step (1.10 -> 1.025
            -- by default), so a tick is finer without changing direction.
            local factor = math.pow(1 + (SCALE_FACTOR - 1) * mul, wheel)
            ent:SetScale(math.Clamp(ent:GetScale() * factor, SCALE_MIN, SCALE_MAX))
        else
            ent:SetHeight(math.Clamp(ent:GetHeight() + wheel * HEIGHT_STEP * mul,
                HEIGHT_MIN, HEIGHT_MAX))
        end
        dirty = true
    end

    -- Edge-triggered auto-center on +reload. We can't read this off the
    -- cmd's IN_RELOAD bit because PlayerBindPress below swallows the
    -- +reload bind (so the engine never sets IN_RELOAD). Poll the raw
    -- key bound to +reload instead so suppression and detection don't
    -- fight each other. Bypasses the throttled setparams send for an
    -- immediate snap; clears dirty so a stale pan/height update doesn't
    -- overwrite it on the next tick.
    local reloadKey = input.LookupBinding('+reload')
    local reload = reloadKey and input.IsKeyDown(input.GetKeyCode(reloadKey)) or false
    if reload and not wasReloadDown then
        if sendAutoCenter(ent) then
            dirty = false
            nextSendTime = SysTime() + SEND_INTERVAL
        end
    end
    wasReloadDown = reload

    -- Edge-triggered layer toggles. T flips entities, G flips the map.
    -- Raw key polling (not cmd:KeyDown) so we don't depend on whatever
    -- bind those keys happen to fire; the conflicting messagemode /
    -- +menu_context binds are swallowed by PlayerBindPress below.
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

-- Mouse-wheel binds normally fire the weapon-selection HUD (and its
-- click sound) before CreateMove sees the cmd, so cmd:SetMouseWheel(0)
-- isn't enough on its own. +reload normally triggers the held weapon
-- (animation + sound); we consume it so R cleanly drives auto-center.
-- messagemode / +menu_context default to T and G, which we want for
-- the layer toggles.
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

--- @param cmd string
--- @param fallback string
--- @return string
local function bindKey(cmd, fallback)
    local k = input.LookupBinding(cmd)
    return k and string.upper(k) or fallback
end

-- Concatenates the player's bound keys for the four movement commands
-- (e.g. "WASD", "ESDF", "ARROWS"). Falls back to "WASD" when no bind
-- is found.
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
        '[HOLO TABLE]  %s pan  -  Wheel height  -  %s+Wheel zoom  -  %s recenter  -  %s exit',
        panKeysHint(),
        bindKey('+speed', 'SHIFT'),
        bindKey('+reload', 'R'),
        bindKey('+use', 'E'))
    local hint2 = string.format(
        'T entities (%s)  -  G map (%s)  -  hold %s for precision',
        onOff(ent:GetEntities()),
        onOff(ent:GetMap()),
        bindKey('+duck', 'CTRL'))
    local stats = string.format('scale %.1f   height %.1f   pan (%.0f, %.0f)',
        ent:GetScale(), ent:GetHeight(), ent:GetPanX(), ent:GetPanY())

    draw.SimpleText(hint1, 'DermaDefaultBold', x, y,
        color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    draw.SimpleText(hint2, 'DermaDefault', x, y + 18,
        color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    draw.SimpleText(stats, 'DermaDefault', x, y + 36,
        color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end)

-- Manual release for users who walked away from the table and can't
-- reach it to press E again.
concommand.Add('holo_table_release', function()
    if not IsValid(controlled) then return end
    net.Start('holo_table_release')
    net.WriteEntity(controlled)
    net.SendToServer()
end)

-- Snaps a holo table's scale/pan/height to frame the full BSP. Picks
-- the actively-controlled table, then the one under the crosshair,
-- then the nearest one. Also wired to +reload while controlling.
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
