-- Live player-model radar. Remote players use the same trick as wOS'
-- hologram table: draw the real player entity at a temporary projected
-- pose, then immediately restore it. The local player gets a small
-- ClientsideModel mirror because first-person local-player drawing is
-- special-cased by the engine and may be suppressed.

local mirrorState = _G.HOLO_TABLE_3D_PLAYER_RADAR_MIRRORS
if mirrorState then
    for cs in pairs(mirrorState) do
        if IsValid(cs) then SafeRemoveEntity(cs) end
    end
end
mirrorState = {}
_G.HOLO_TABLE_3D_PLAYER_RADAR_MIRRORS = mirrorState

local localBonePoseCvar = CreateClientConVar('holo_table_player_anim_events', '1', true, false,
    'Experimental: copy the local player solved bone pose to the holo-table mirror.')
local playerLightCvar = CreateClientConVar('holo_table_player_light', '1', true, false,
    'Brightness for holo-table player/weapon radar models when engine lighting is suppressed.')

local function beginPlayerLighting()
    local light = math.Clamp(playerLightCvar:GetFloat(), 0, 3)
    render.SuppressEngineLighting(true)
    render.ResetModelLighting(light, light, light)
end

local function endPlayerLighting()
    render.ResetModelLighting(1, 1, 1)
    render.SuppressEngineLighting(false)
end

local function drawPlayerAndWeapon(ply)
    ply:SetupBones()
    ply:DrawModel()

    local wep = ply:GetActiveWeapon()
    if IsValid(wep) then
        wep:DrawModel()
    end
end

local function removeMirror(mirror)
    if not mirror then return end
    local cs = mirror.csent
    if IsValid(cs) then
        mirrorState[cs] = nil
        cs:SetParent(NULL)
        SafeRemoveEntity(cs)
    end
end

local function setupMirrorEntity(cs)
    cs:SetNoDraw(true)
    cs:SetSolid(SOLID_NONE)
    cs:SetMoveType(MOVETYPE_NONE)
    cs:PhysicsDestroy()

    mirrorState[cs] = true
end

local function makePlayerMirror(ply, model)
    local cs = ClientsideModel(model, RENDERGROUP_OTHER)
    if not IsValid(cs) then return nil end

    setupMirrorEntity(cs)

    -- Player-color proxies on many playermodel materials ask the entity
    -- being drawn for GetPlayerColor, so let the mirror answer with the
    -- source player's live color.
    cs.GetPlayerColor = function()
        if IsValid(ply) then return ply:GetPlayerColor() end
        return vector_origin
    end

    return { csent = cs, model = model }
end

local function makeWeaponMirror(model)
    local cs = ClientsideModel(model, RENDERGROUP_OTHER)
    if not IsValid(cs) then return nil end

    setupMirrorEntity(cs)

    return { csent = cs, model = model }
end

local function getLocalMirror(radar, ply)
    local model = ply:GetModel()
    if not model or model == '' then return nil end

    local mirror = radar.LocalPlayerMirror
    if mirror and IsValid(mirror.csent) and mirror.model == model then
        return mirror
    end

    removeMirror(mirror)
    mirror = makePlayerMirror(ply, model)
    radar.LocalPlayerMirror = mirror
    return mirror
end

local STOCK_WEAPON_MODELS = {
    gmod_camera = 'models/maxofs2d/camera.mdl',
    gmod_tool = 'models/weapons/w_toolgun.mdl',
    weapon_357 = 'models/weapons/w_357.mdl',
    weapon_ar2 = 'models/weapons/w_irifle.mdl',
    weapon_crossbow = 'models/weapons/w_crossbow.mdl',
    weapon_crowbar = 'models/weapons/w_crowbar.mdl',
    weapon_frag = 'models/weapons/w_grenade.mdl',
    weapon_physcannon = 'models/weapons/w_physics.mdl',
    weapon_physgun = 'models/weapons/w_physics.mdl',
    weapon_pistol = 'models/weapons/w_pistol.mdl',
    weapon_rpg = 'models/weapons/w_rocket_launcher.mdl',
    weapon_shotgun = 'models/weapons/w_shotgun.mdl',
    weapon_slam = 'models/weapons/w_slam.mdl',
    weapon_smg1 = 'models/weapons/w_smg1.mdl',
    weapon_stunstick = 'models/weapons/w_stunbaton.mdl',
}

local function validModelName(model)
    return isstring(model) and model ~= ''
end

local function getWeaponModel(wep)
    local model = wep:GetModel()
    if validModelName(model) then return model end

    model = wep.WorldModel
    if validModelName(model) then return model end

    local class = wep:GetClass()
    local weaponData = weapons.Get(class)
    model = weaponData and weaponData.WorldModel
    if validModelName(model) then return model end
    local scriptedWeaponData = weaponData

    local weaponList = list.Get('Weapon')
    weaponData = weaponList and weaponList[class]
    model = weaponData and weaponData.WorldModel
    if validModelName(model) then return model end

    model = STOCK_WEAPON_MODELS[class]
    if validModelName(model) then return model end

    local owner = wep:GetOwner()
    local viewModel = IsValid(owner) and owner.GetViewModel and owner:GetViewModel()
    model = IsValid(viewModel) and viewModel:GetModel() or nil
    if validModelName(model) then return model end

    model = wep.ViewModel or scriptedWeaponData and scriptedWeaponData.ViewModel or weaponData and weaponData.ViewModel
    if validModelName(model) then return model end

    return nil
end

local function getLocalWeaponMirror(radar, wep)
    if not IsValid(wep) then
        removeMirror(radar.LocalWeaponMirror)
        radar.LocalWeaponMirror = nil
        return nil
    end

    local model = getWeaponModel(wep)
    if not model then
        removeMirror(radar.LocalWeaponMirror)
        radar.LocalWeaponMirror = nil
        return nil
    end

    local mirror = radar.LocalWeaponMirror
    if not (mirror and IsValid(mirror.csent) and mirror.model == model) then
        removeMirror(mirror)
        mirror = makeWeaponMirror(model)
        radar.LocalWeaponMirror = mirror
    end

    if not (mirror and IsValid(mirror.csent)) then return nil end

    return mirror
end

local function syncMirrorBodygroups(ply, cs)
    cs:SetSkin(ply:GetSkin() or 0)

    for _, bg in ipairs(ply:GetBodyGroups()) do
        local id = bg.id
        cs:SetBodygroup(id, ply:GetBodygroup(id))
    end
end

local function syncMirrorPoseParams(ply, cs)
    for i = 0, ply:GetNumPoseParameters() - 1 do
        local name = ply:GetPoseParameterName(i)
        if not name then continue end

        local minValue, maxValue = ply:GetPoseParameterRange(i)
        cs:SetPoseParameter(name, math.Remap(ply:GetPoseParameter(name), 0, 1, minValue, maxValue))
    end

    cs:InvalidateBoneCache()
end

local function syncMirrorMainAnimation(ply, mirror)
    local cs = mirror.csent
    local seq = ply:GetSequence()
    if cs:GetSequence() ~= seq then
        cs:SetSequence(seq)
    end
    cs:SetCycle(ply:GetCycle())
    cs:SetPlaybackRate(ply:GetPlaybackRate())
end

local function copyLocalBonePose(ply, mirror, rootPos, rootAng, invScale)
    if not localBonePoseCvar:GetBool() then return end

    local cs = mirror.csent
    local plyBoneCount = ply:GetBoneCount() or 0
    local mirrorBoneCount = cs:GetBoneCount() or 0
    local boneCount = math.min(plyBoneCount, mirrorBoneCount)
    if boneCount <= 0 then return end

    local sourcePos = ply:GetPos()
    local sourceAng = ply:GetAngles()

    ply:SetupBones()
    cs:SetupBones()

    for boneId = 0, boneCount - 1 do
        if cs:GetBoneName(boneId) == '__INVALIDBONE__' then continue end

        local sourceMatrix = ply:GetBoneMatrix(boneId)
        if not sourceMatrix then continue end

        local localPos, localAng = WorldToLocal(
            sourceMatrix:GetTranslation(),
            sourceMatrix:GetAngles(),
            sourcePos,
            sourceAng
        )
        local targetPos, targetAng = LocalToWorld(localPos * invScale, localAng, rootPos, rootAng)

        local targetMatrix = Matrix()
        targetMatrix:SetTranslation(targetPos)
        targetMatrix:SetAngles(targetAng)
        targetMatrix:SetScale(sourceMatrix:GetScale() * invScale)

        cs:SetBoneMatrix(boneId, targetMatrix)
    end
end

local function syncLocalMirror(ply, mirror)
    local cs = mirror.csent
    cs:SetColor(ply:GetColor())
    cs:SetMaterial(ply:GetMaterial() or '')
    syncMirrorBodygroups(ply, cs)

    syncMirrorMainAnimation(ply, mirror)
    syncMirrorPoseParams(ply, cs)
end

local function syncLocalWeaponMirror(wep, weaponCs, invScale)
    weaponCs:SetColor(wep:GetColor())
    weaponCs:SetMaterial(wep:GetMaterial() or '')
    weaponCs:SetSkin(wep:GetSkin() or 0)
    weaponCs:SetModelScale(wep:GetModelScale() * invScale, 0)

    for _, bg in ipairs(wep:GetBodyGroups()) do
        local id = bg.id
        weaponCs:SetBodygroup(id, wep:GetBodygroup(id))
    end
end

local function clearWeaponParent(weaponCs)
    if weaponCs:GetParent() ~= NULL then
        weaponCs:SetParent(NULL)
    end

    if EF_BONEMERGE then weaponCs:RemoveEffects(EF_BONEMERGE) end
    if EF_BONEMERGE_FASTCULL then weaponCs:RemoveEffects(EF_BONEMERGE_FASTCULL) end
    if EF_PARENT_ANIMATES then weaponCs:RemoveEffects(EF_PARENT_ANIMATES) end
    if EF_FOLLOWBONE then weaponCs:RemoveEffects(EF_FOLLOWBONE) end
end

local WEAPON_BONEMERGE_BONES = {
    'ValveBiped.Bip01_R_Hand',
    'ValveBiped.Anim_Attachment_RH',
}

local function canBoneMergeWeapon(weaponCs)
    for _, name in ipairs(WEAPON_BONEMERGE_BONES) do
        if weaponCs:LookupBone(name) then return true end
    end

    return false
end

local function attachWeaponMirror(playerMirror, weaponCs)
    clearWeaponParent(weaponCs)
    weaponCs:SetPos(playerMirror:GetPos())
    weaponCs:SetAngles(playerMirror:GetAngles())

    if canBoneMergeWeapon(weaponCs) and EF_BONEMERGE then
        weaponCs:SetParent(playerMirror)
        weaponCs:AddEffects(EF_BONEMERGE)
        if EF_BONEMERGE_FASTCULL then weaponCs:AddEffects(EF_BONEMERGE_FASTCULL) end
        if EF_PARENT_ANIMATES then weaponCs:AddEffects(EF_PARENT_ANIMATES) end
        return
    end

    local attachId = playerMirror:LookupAttachment('anim_attachment_RH')
    if attachId > 0 then
        weaponCs:SetParent(playerMirror, attachId)
        if EF_PARENT_ANIMATES then weaponCs:AddEffects(EF_PARENT_ANIMATES) end
    end
end

local function drawProjectedLocalPlayer(radar, ply, invScale)
    local mirror = getLocalMirror(radar, ply)
    if not mirror then return end

    local cs = mirror.csent
    if not IsValid(cs) then return end

    local ok, err = pcall(function()
        syncLocalMirror(ply, mirror)

        local wpos, wang = radar:Project(ply:GetPos(), ply:GetAngles())
        cs:SetPos(wpos)
        cs:SetAngles(wang)
        cs:SetModelScale(ply:GetModelScale() * invScale, 0)
        cs:SetupBones()
        copyLocalBonePose(ply, mirror, wpos, wang, invScale)

        cs:DrawModel()

        local activeWeapon = ply:GetActiveWeapon()
        local weaponMirror = getLocalWeaponMirror(radar, activeWeapon)
        local weaponCs = weaponMirror and weaponMirror.csent
        if IsValid(weaponCs) then
            syncLocalWeaponMirror(activeWeapon, weaponCs, invScale)
            attachWeaponMirror(cs, weaponCs)
            weaponCs:SetupBones()
            weaponCs:DrawModel()
        end
    end)

    if not ok then
        ErrorNoHaltWithStack('[holo_table] local player radar draw aborted: ' .. tostring(err))
    end
end

local function drawProjectedPlayer(radar, ply, invScale)
    local oldPos = ply:GetPos()
    local oldAng = ply:GetAngles()
    local oldScale = ply:GetModelScale()

    local wep = ply:GetActiveWeapon()
    local oldWepScale
    if IsValid(wep) then
        oldWepScale = wep:GetModelScale()
    end

    local wpos, wang = radar:Project(oldPos, oldAng)
    ply:SetPos(wpos)
    ply:SetAngles(wang)
    ply:SetModelScale(oldScale * invScale, 0)
    if IsValid(wep) then
        wep:SetModelScale(oldWepScale * invScale, 0)
    end

    local ok, err = pcall(function()
        drawPlayerAndWeapon(ply)
    end)

    if IsValid(wep) and oldWepScale then
        wep:SetModelScale(oldWepScale, 0)
    end
    ply:SetModelScale(oldScale, 0)
    ply:SetAngles(oldAng)
    ply:SetPos(oldPos)
    ply:SetupBones()

    if not ok then
        ErrorNoHaltWithStack('[holo_table] player radar draw aborted: ' .. tostring(err))
    end
end

function RADAR:Draw()
    local invScale = self:GetScale()
    beginPlayerLighting()

    local ok, err = pcall(function()
        for _, ply in player.Iterator() do
            if not IsValid(ply) then continue end
            if not ply:Alive() then continue end

            if ply == LocalPlayer() then
                drawProjectedLocalPlayer(self, ply, invScale)
            else
                drawProjectedPlayer(self, ply, invScale)
            end
        end
    end)

    endPlayerLighting()

    if not ok then
        ErrorNoHaltWithStack('[holo_table] player radar lighting draw aborted: ' .. tostring(err))
    end
end

function RADAR:OnRemove()
    removeMirror(self.LocalPlayerMirror)
    self.LocalPlayerMirror = nil
    removeMirror(self.LocalWeaponMirror)
    self.LocalWeaponMirror = nil
end
