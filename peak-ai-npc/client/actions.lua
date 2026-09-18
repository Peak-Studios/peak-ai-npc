local function getNpcPed(id)
    local ped = AINPCClientEntities and AINPCClientEntities[id]
    return ped and DoesEntityExist(ped) and ped or nil
end

local speakingToken = {}
local activeActions = {}
local activeActionTokens = {}
local latestActionRevision = {}

function AINPCCancelActions(id)
    activeActions[id] = nil
    activeActionTokens[id] = nil
    speakingToken[id] = (speakingToken[id] or 0) + 1
    local ped = getNpcPed(id)
    if not ped then return end
    if not NetworkGetEntityIsNetworked(ped) or NetworkHasControlOfEntity(ped) then
        ClearPedTasks(ped)
        ClearFacialIdleAnimOverride(ped)
        if AINPCDefinitions and AINPCDefinitions[id] and not IsPedInAnyVehicle(ped, false) then
            FreezeEntityPosition(ped, true)
            SetEntityInvincible(ped, true)
            SetPedCanRagdoll(ped, false)
            SetBlockingOfNonTemporaryEvents(ped, true)
        elseif not IsPedInAnyVehicle(ped, false) then
            FreezeEntityPosition(ped, false)
            TaskWanderStandard(ped, 10.0, 10)
        end
    end
end

function AINPCMovementActionActive(id)
    local action = activeActions[id]
    return action == 'follow' or action == 'walk' or action == 'flee' or action == 'enter_vehicle' or action == 'leave_vehicle'
        or action == 'shop_robbery' or action == 'surrender' or action == 'crouch'
        or action == 'react:approach' or action == 'react:dismissive' or action == 'react:cautious'
end

local function playerPedForServerId(serverId)
    if type(serverId) ~= 'number' then return nil end
    local player = GetPlayerFromServerId(serverId)
    if player == -1 then return nil end
    local ped = GetPlayerPed(player)
    return ped ~= 0 and DoesEntityExist(ped) and ped or nil
end

function AINPCSetSpeaking(id, active, targetServerId)
    local ped = getNpcPed(id)
    if not ped then return end
    speakingToken[id] = (speakingToken[id] or 0) + 1
    local token = speakingToken[id]
    if active then
        SetFacialIdleAnimOverride(ped, 'mood_talking_1', 0)
        local target
        if type(targetServerId) == 'number' then target = playerPedForServerId(targetServerId)
        else target = PlayerPedId() end
        if target and target ~= 0 then TaskLookAtEntity(ped, target, -1, 2048, 2) end
    else
        ClearFacialIdleAnimOverride(ped)
    end
    return token
end

function AINPCStopSpeaking(id, token)
    if speakingToken[id] ~= token then return end
    AINPCSetSpeaking(id, false)
end

local function ensureControl(ped)
    if not NetworkGetEntityIsNetworked(ped) or NetworkHasControlOfEntity(ped) then return true end
    local deadline = GetGameTimer() + 750
    repeat
        NetworkRequestControlOfEntity(ped)
        Wait(0)
    until NetworkHasControlOfEntity(ped) or GetGameTimer() >= deadline
    return NetworkHasControlOfEntity(ped)
end

local function playAnim(ped, dict, anim, flag, duration)
    RequestAnimDict(dict)
    local deadline = GetGameTimer() + 1000
    while not HasAnimDictLoaded(dict) and GetGameTimer() < deadline do Wait(0) end
    if HasAnimDictLoaded(dict) then
        TaskPlayAnim(ped, dict, anim, 8.0, -8.0, duration or 2000, flag or 48, 0.0, false, false, false)
        RemoveAnimDict(dict)
    end
end

RegisterNetEvent(AINPC.Event.Action, function(id, action, payload)
    local ped = getNpcPed(id)
    payload = type(payload) == 'table' and payload or {}
    local actionId = payload.actionId
    local sessionRevision = payload.sessionRevision
    local function acknowledge(phase, code)
        if type(actionId) == 'string' and type(sessionRevision) == 'number' then
            TriggerServerEvent('peak_ai_npc:server:actionLifecycle', sessionRevision, actionId, phase, code)
        end
    end
    if type(sessionRevision) == 'number' then
        if sessionRevision < (latestActionRevision[id] or 0) then acknowledge('failed', 'stale_revision'); return end
        latestActionRevision[id] = sessionRevision
    end
    if type(payload.ownerServerId) == 'number' and payload.ownerServerId ~= GetPlayerServerId(PlayerId()) then
        acknowledge('failed', 'wrong_owner')
        return
    end
    if not ped then acknowledge('failed', 'entity_missing'); return end
    if not ensureControl(ped) then
        acknowledge('failed', 'owner_control_failed')
        TriggerEvent('peak_ai_npc:client:notify', 'The NPC is temporarily controlled by another client. Try again.')
        return
    end
    if payload.entityNetId and (not NetworkGetEntityIsNetworked(ped) or NetworkGetNetworkIdFromEntity(ped) ~= payload.entityNetId) then
        acknowledge('failed', 'entity_mismatch')
        return
    end
    acknowledge('start')
    local player = PlayerPedId()
    local completion = 'assigned'
    local completionTarget = nil
    activeActions[id] = action
    if action == 'face' then
        TaskTurnPedToFaceEntity(ped, player, 1000)
    elseif action == 'follow' then
        FreezeEntityPosition(ped, false)
        TaskFollowToOffsetOfEntity(ped, player, 0.0, 1.5, 0.0, 1.0, -1, 2.0, true)
    elseif action == 'flee' then
        FreezeEntityPosition(ped, false)
        TaskSmartFleePed(ped, player, 100.0, -1, false, false)
    elseif action == 'surrender' then
        FreezeEntityPosition(ped, false)
        ClearPedTasks(ped)
        TaskHandsUp(ped, -1, player, -1, true)
    elseif action == 'shop_robbery' then
        local reactionId = type(payload.reactionId) == 'string' and payload.reactionId or tostring(GetGameTimer())
        local robber = player
        local robberIndex = GetPlayerFromServerId(tonumber(payload.robberSource) or -1)
        if robberIndex ~= -1 then
            local resolvedRobber = GetPlayerPed(robberIndex)
            if resolvedRobber ~= 0 and DoesEntityExist(resolvedRobber) then robber = resolvedRobber end
        end
        activeActionTokens[id] = reactionId
        FreezeEntityPosition(ped, false)
        SetEntityInvincible(ped, false)
        SetPedCanRagdoll(ped, true)
        SetBlockingOfNonTemporaryEvents(ped, false)
        ClearPedTasks(ped)
        local durationMs = math.max(1000, math.min(60000, tonumber(payload.durationMs) or 20000))
        if payload.response == 'defend' then
            local weapon = type(payload.weapon) == 'string' and joaat(payload.weapon) or joaat('WEAPON_PISTOL')
            GiveWeaponToPed(ped, weapon, 48, false, true)
            SetPedDropsWeaponsWhenDead(ped, false)
            TaskCombatPed(ped, robber, 0, 16)
        elseif payload.response == 'flee' then
            TaskSmartFleePed(ped, robber, 80.0, durationMs, false, false)
        else
            TaskHandsUp(ped, durationMs, robber, -1, true)
        end
        if type(payload.line) == 'string' then
            if AINPCShowSubtitle then AINPCShowSubtitle(id, payload.line) end
            PlayPedAmbientSpeechNative(ped, payload.response == 'defend' and 'GENERIC_ANGRY_HIGH' or 'GENERIC_SHOCKED_HIGH', 'SPEECH_PARAMS_FORCE')
        end
        SetTimeout(durationMs + 1500, function()
            if activeActions[id] == 'shop_robbery' and activeActionTokens[id] == reactionId then
                AINPCCancelActions(id)
            end
        end)
    elseif action == 'stop' then
        AINPCCancelActions(id)
    elseif action == 'react' and type(payload.reaction) == 'string' then
        local reaction = payload.reaction
        activeActions[id] = 'react:' .. reaction
        FreezeEntityPosition(ped, false)
        ClearPedTasks(ped)
        if reaction == 'approach' then
            TaskGoToEntity(ped, player, -1, 1.8, 1.0, 0.5, 0)
        elseif reaction == 'offended' then
            TaskTurnPedToFaceEntity(ped, player, 1250)
            SetFacialIdleAnimOverride(ped, 'mood_angry_1', 0)
            PlayPedAmbientSpeechNative(ped, 'GENERIC_CURSE_MED', 'SPEECH_PARAMS_FORCE')
        elseif reaction == 'angry' then
            TaskTurnPedToFaceEntity(ped, player, 1500)
            SetFacialIdleAnimOverride(ped, 'mood_angry_1', 0)
            PlayPedAmbientSpeechNative(ped, 'GENERIC_ANGRY_HIGH', 'SPEECH_PARAMS_FORCE')
        elseif reaction == 'dismissive' then
            PlayPedAmbientSpeechNative(ped, 'GENERIC_DISMISSED', 'SPEECH_PARAMS_FORCE')
            TaskWanderStandard(ped, 10.0, 10)
        elseif reaction == 'friendly' then
            TaskTurnPedToFaceEntity(ped, player, 1200)
            SetFacialIdleAnimOverride(ped, 'mood_happy_1', 0)
        elseif reaction == 'cautious' then
            TaskSmartFleePed(ped, player, 18.0, 8000, false, false)
        else
            activeActions[id] = nil
        end
    elseif action == 'walk' and type(payload.x) == 'number' and type(payload.y) == 'number' and type(payload.z) == 'number' then
        FreezeEntityPosition(ped, false)
        TaskGoStraightToCoord(ped, payload.x, payload.y, payload.z, 1.0, -1, 0.0, 0.5)
        completion = 'walk'
        completionTarget = vec3(payload.x, payload.y, payload.z)
    elseif action == 'sit' then
        FreezeEntityPosition(ped, false)
        ClearPedTasks(ped)
        TaskStartScenarioInPlace(ped, 'PROP_HUMAN_SEAT_CHAIR_MP_PLAYER', -1, true)
    elseif action == 'point' then
        FreezeEntityPosition(ped, false)
        ClearPedTasks(ped)
        TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_POINTING', -1, true)
    elseif action == 'enter_vehicle' then
        local coords = GetEntityCoords(ped)
        local vehicle = GetClosestVehicle(coords.x, coords.y, coords.z, 8.0, 0, 70)
        if vehicle ~= 0 then
            FreezeEntityPosition(ped, false)
            TaskEnterVehicle(ped, vehicle, 10000, -1, 1.0, 1, 0)
            completion = 'enter_vehicle'
        else completion = 'failed_no_vehicle' end
    elseif action == 'leave_vehicle' and IsPedInAnyVehicle(ped, false) then
        FreezeEntityPosition(ped, false)
        TaskLeaveVehicle(ped, GetVehiclePedIsIn(ped, false), 0)
        completion = 'leave_vehicle'
    elseif action == 'leave_vehicle' then
        completion = 'failed_not_in_vehicle'
    elseif action == 'crouch' then
        FreezeEntityPosition(ped, false)
        ClearPedTasks(ped)
        SetPedStealthMovement(ped, true, 'DEFAULT_ACTION')
        completion = 'assigned'
    elseif action == 'stand' then
        FreezeEntityPosition(ped, false)
        SetPedStealthMovement(ped, false, 'DEFAULT_ACTION')
        ClearPedTasks(ped)
        completion = 'assigned'
    elseif action == 'move' or action == 'gesture' then
        local move = payload.move or payload.gesture or 'nod'
        FreezeEntityPosition(ped, false)
        if move == 'crouch' then
            ClearPedTasks(ped)
            SetPedStealthMovement(ped, true, 'DEFAULT_ACTION')
        elseif move == 'stand' then
            SetPedStealthMovement(ped, false, 'DEFAULT_ACTION')
            ClearPedTasks(ped)
        elseif move == 'nod' then
            playAnim(ped, 'gestures@m@standing@casual', 'gesture_nod_yes', 48, 1500)
        elseif move == 'shake_head' then
            playAnim(ped, 'gestures@m@standing@casual', 'gesture_nod_no', 48, 1500)
        elseif move == 'wave' then
            playAnim(ped, 'friends@frj@ig_1', 'wave_a', 48, 2000)
        elseif move == 'shrug' then
            playAnim(ped, 'gestures@m@standing@casual', 'gesture_shrug_soft', 48, 1500)
        elseif move == 'cross_arms' then
            TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_STAND_IMPATIENT', -1, true)
        elseif move == 'cheer' then
            playAnim(ped, 'anim@mp_player_intcelebrationmale@thumbs_up', 'thumbs_up', 48, 2000)
        elseif move == 'salute' then
            playAnim(ped, 'anim@mp_player_intcelebrationmale@salute', 'salute', 48, 2000)
        elseif move == 'smoke' then
            TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_SMOKING', -1, true)
        elseif move == 'drink' then
            TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_DRINKING', -1, true)
        elseif move == 'sit' then
            TaskStartScenarioInPlace(ped, 'PROP_HUMAN_SEAT_CHAIR_MP_PLAYER', -1, true)
        elseif move == 'point' then
            TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_POINTING', -1, true)
        end
        completion = 'assigned'
    elseif action == 'look_at' then
        TaskLookAtEntity(ped, player, tonumber(payload.durationMs) or 5000, 2048, 2)
        completion = 'assigned'
    elseif action ~= 'face' and action ~= 'follow' and action ~= 'flee' and action ~= 'surrender'
        and action ~= 'shop_robbery' and action ~= 'stop' and action ~= 'react' and action ~= 'sit' and action ~= 'point'
        and action ~= 'crouch' and action ~= 'stand' and action ~= 'move' and action ~= 'gesture' and action ~= 'look_at' then
        activeActions[id] = nil
        completion = 'failed_invalid_action'
    end

    if completion:sub(1, 7) == 'failed_' then
        acknowledge('failed', completion:sub(8))
    elseif completion == 'assigned' then
        acknowledge('completed')
    else
        CreateThread(function()
            local deadline = GetGameTimer() + 15000
            while GetGameTimer() < deadline do
                Wait(100)
                local current = getNpcPed(id)
                if not current or IsEntityDead(current) then acknowledge('failed', 'entity_unavailable'); return end
                if not ensureControl(current) then acknowledge('failed', 'owner_migrated'); return end
                if completion == 'walk' and #(GetEntityCoords(current) - completionTarget) <= 1.6 then acknowledge('completed'); return end
                if completion == 'enter_vehicle' and IsPedInAnyVehicle(current, false) then acknowledge('completed'); return end
                if completion == 'leave_vehicle' and not IsPedInAnyVehicle(current, false) then acknowledge('completed'); return end
            end
            acknowledge('failed', 'action_timeout')
        end)
    end
end)

CreateThread(function()
    while true do
        Wait(1000)
        for id in pairs(activeActions) do
            local ped = getNpcPed(id)
            if not ped or IsEntityDead(ped) then
                activeActions[id] = nil
            elseif NetworkGetEntityIsNetworked(ped) and not NetworkHasControlOfEntity(ped) then
                -- The new owner will receive future authoritative actions. Drop
                -- stale local bookkeeping so scope/owner migration cannot keep
                -- presentation state alive on this client.
                activeActions[id] = nil
                ClearFacialIdleAnimOverride(ped)
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    for id in pairs(activeActions) do AINPCCancelActions(id) end
    latestActionRevision = {}
end)
