local desired = {}
local appliedRevision = {}

local allowedModes = {
    idle = true, scenario = true, wander = true, face = true,
    retreat = true, flee = true, surrender = true, crouch = true
}

local allowedFacials = { neutral = true, happy = true, angry = true, stressed = true }
local allowedScenarios = {
    WORLD_HUMAN_CLIPBOARD = true,
    WORLD_HUMAN_DRINKING = true,
    WORLD_HUMAN_STAND_MOBILE = true,
    WORLD_HUMAN_STAND_IMPATIENT = true,
    WORLD_HUMAN_SMOKING = true,
    WORLD_HUMAN_GUARD_STAND = true,
    PROP_HUMAN_SEAT_CHAIR_MP_PLAYER = true
}

local function validDirective(value)
    if type(value) ~= 'table' or type(value.revision) ~= 'number' or value.revision < 1 or value.revision % 1 ~= 0 then return false end
    if not allowedModes[value.mode] or not allowedFacials[value.facial] then return false end
    if value.mode == 'scenario' and not allowedScenarios[value.scenario] then return false end
    if type(value.priority) ~= 'number' or value.priority < 0 or value.priority > 100 then return false end
    if type(value.speed) ~= 'number' or value.speed < 0.5 or value.speed > 2.0 then return false end
    if type(value.radius) ~= 'number' or value.radius < 1.0 or value.radius > (Config.Ambient.maximumRoamDistance or 100.0) then return false end
    if value.targetServerId ~= nil and (type(value.targetServerId) ~= 'number' or value.targetServerId < 1) then return false end
    return true
end

local function ensureControl(ped)
    if not NetworkGetEntityIsNetworked(ped) or NetworkHasControlOfEntity(ped) then return true end
    NetworkRequestControlOfEntity(ped)
    return NetworkHasControlOfEntity(ped)
end

local function targetPed(value)
    if type(value.targetServerId) ~= 'number' then return nil end
    local player = GetPlayerFromServerId(value.targetServerId)
    if player == -1 then return nil end
    local ped = GetPlayerPed(player)
    return ped ~= 0 and DoesEntityExist(ped) and ped or nil
end

local function applyFacial(ped, facial)
    if facial == 'happy' then SetFacialIdleAnimOverride(ped, 'mood_happy_1', 0)
    elseif facial == 'angry' then SetFacialIdleAnimOverride(ped, 'mood_angry_1', 0)
    elseif facial == 'stressed' then SetFacialIdleAnimOverride(ped, 'mood_stressed_1', 0)
    else ClearFacialIdleAnimOverride(ped) end
end

local function applyDirective(id, ped, value)
    if not DoesEntityExist(ped) or IsEntityDead(ped) then return false end
    -- Automatic routines/reactions must not remove a driver from their seat.
    -- Vehicle exit is a separate, explicitly authorized interaction.
    if IsPedInAnyVehicle(ped, false) then return false end
    if not ensureControl(ped) then return false end
    if AINPCMovementActionActive and AINPCMovementActionActive(id) and value.priority < 80 then return false end
    local target = targetPed(value)
    if value.targetServerId ~= nil and not target then return false end
    if value.mode == 'scenario' then
        FreezeEntityPosition(ped, false)
        SetBlockingOfNonTemporaryEvents(ped, true)
        ClearPedTasks(ped)
        TaskStartScenarioInPlace(ped, value.scenario, -1, true)
    elseif value.mode == 'wander' then
        FreezeEntityPosition(ped, false)
        SetBlockingOfNonTemporaryEvents(ped, false)
        ClearPedTasks(ped)
        local origin = GetEntityCoords(ped)
        SetPedMoveRateOverride(ped, value.speed)
        TaskWanderInArea(ped, origin.x, origin.y, origin.z, value.radius, 2.0, 10.0)
    elseif value.mode == 'face' then
        if not target then return false end
        FreezeEntityPosition(ped, false)
        TaskTurnPedToFaceEntity(ped, target, value.durationMs)
        TaskLookAtEntity(ped, target, value.durationMs, 2048, 2)
    elseif value.mode == 'retreat' then
        if not target then return false end
        FreezeEntityPosition(ped, false)
        SetBlockingOfNonTemporaryEvents(ped, false)
        ClearPedTasks(ped)
        TaskSmartFleePed(ped, target, value.radius, value.durationMs, false, false)
    elseif value.mode == 'flee' then
        if not target then return false end
        FreezeEntityPosition(ped, false)
        SetBlockingOfNonTemporaryEvents(ped, false)
        ClearPedTasks(ped)
        TaskSmartFleePed(ped, target, math.max(40.0, value.radius), value.durationMs, false, false)
    elseif value.mode == 'surrender' then
        if not target then return false end
        FreezeEntityPosition(ped, false)
        ClearPedTasks(ped)
        TaskHandsUp(ped, value.durationMs, target, -1, true)
    elseif value.mode == 'crouch' then
        FreezeEntityPosition(ped, false)
        ClearPedTasks(ped)
        SetPedStealthMovement(ped, true, 'DEFAULT_ACTION')
        if target then
            TaskTurnPedToFaceEntity(ped, target, value.durationMs or 5000)
        end
    else
        ClearPedTasks(ped)
    end
    applyFacial(ped, value.facial)
    appliedRevision[ped] = value.revision
    return true
end

local function remember(id, ped, value)
    if type(id) ~= 'string' or not validDirective(value) then return end
    desired[id] = { ped = ped, value = value }
    if ped and ped ~= 0 then applyDirective(id, ped, value) end
end

AddStateBagChangeHandler('ainpc:behavior', nil, function(bagName, _, value)
    local ped = GetEntityFromStateBagName(bagName)
    if ped == 0 or not IsEntityAPed(ped) or IsPedAPlayer(ped) then return end
    local id = Entity(ped).state['ainpc:residentId'] or Entity(ped).state['ainpc:id'] or value and value.npcId
    remember(id, ped, value)
end)

RegisterNetEvent(AINPC.Event.Behavior, function(id, value)
    local ped = AINPCClientEntities and AINPCClientEntities[id]
    remember(id, ped, value)
end)

CreateThread(function()
    while true do
        Wait(1000)
        for id, item in pairs(desired) do
            local ped = item.ped
            if (not ped or ped == 0 or not DoesEntityExist(ped)) and AINPCClientEntities then
                ped = AINPCClientEntities[id]
                item.ped = ped
            end
            if ped and ped ~= 0 and DoesEntityExist(ped) then
                local stateDirective = Entity(ped).state['ainpc:behavior']
                if validDirective(stateDirective) and stateDirective.revision > item.value.revision then
                    item.value = stateDirective
                end
                if appliedRevision[ped] ~= item.value.revision then applyDirective(id, ped, item.value) end
            end
        end
        for ped in pairs(appliedRevision) do
            if not DoesEntityExist(ped) then appliedRevision[ped] = nil end
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    desired, appliedRevision = {}, {}
end)
