AINPCClientEntities = {}
AINPCClientEntityOwnership = {}
local pendingNetworkEntities = {}
local entitySyncComplete = false
local ensureFallbackEntities

local function configurePed(ped)
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanRagdoll(ped, false)
end

local function releaseEntity(id)
    local ped = AINPCClientEntities[id]
    if AINPCCancelActions then AINPCCancelActions(id, 'entity_released') end
    if AINPCTargets and AINPCTargets.unregister then AINPCTargets.unregister(id) end
    if AINPCClientEntityOwnership[id] and ped and DoesEntityExist(ped) then DeleteEntity(ped) end
    AINPCClientEntities[id] = nil
    AINPCClientEntityOwnership[id] = nil
end

RegisterNetEvent(AINPC.Event.EntitySyncComplete, function()
    entitySyncComplete = true
end)

local function validDefinition(id, npc)
    if type(id) ~= 'string' or not id:match('^[%w_%-]+$') or #id > 64 or type(npc) ~= 'table' or type(npc.model) ~= 'string' or #npc.model < 1 or #npc.model > 80 then return false end
    local coords, identity = npc.coords, npc.identity
    if type(coords) ~= 'table' or type(coords.x) ~= 'number' or type(coords.y) ~= 'number' or type(coords.z) ~= 'number' or type(coords.w) ~= 'number' then return false end
    if coords.x ~= coords.x or coords.y ~= coords.y or coords.z ~= coords.z or coords.w ~= coords.w then return false end
    if math.abs(coords.x) > 100000 or math.abs(coords.y) > 100000 or coords.z < -1000 or coords.z > 10000 or math.abs(coords.w) > 360 then return false end
    if type(identity) ~= 'table' or type(identity.name) ~= 'string' or #identity.name < 1 or #identity.name > 80 or type(identity.occupation) ~= 'string' or #identity.occupation < 1 or #identity.occupation > 80 then return false end
    local distance = npc.interactionDistance
    if distance ~= nil and (type(distance) ~= 'number' or distance < 1.0 or distance > 20.0) then return false end
    if npc.enabled ~= nil and type(npc.enabled) ~= 'boolean' then return false end
    if npc.shop ~= nil and (type(npc.shop) ~= 'table' or (npc.shop.robbery ~= nil and (type(npc.shop.robbery) ~= 'table' or type(npc.shop.robbery.enabled) ~= 'boolean'))) then return false end
    return true
end

RegisterNetEvent(AINPC.Event.DefinitionSync, function(definitions)
    if type(definitions) ~= 'table' then return end
    local synchronized, count = {}, 0
    for id, npc in pairs(definitions) do
        count = count + 1
        if count > 256 then return end
        if validDefinition(id, npc) then
            synchronized[id] = {
                id = id,
                model = npc.model,
                coords = vec4(npc.coords.x, npc.coords.y, npc.coords.z, npc.coords.w),
                identity = { name = npc.identity.name, occupation = npc.identity.occupation },
                enabled = npc.enabled ~= false,
                interactionDistance = npc.interactionDistance,
                shop = npc.shop and { robbery = npc.shop.robbery and { enabled = npc.shop.robbery.enabled } or nil } or nil
            }
        end
    end
    for id in pairs(AINPCDefinitions) do
        if not synchronized[id] then
            pendingNetworkEntities[id] = nil
            releaseEntity(id)
        end
    end
    AINPCDefinitions = synchronized
    if ensureFallbackEntities then CreateThread(ensureFallbackEntities) end
end)

RegisterNetEvent(AINPC.Event.EntityState, function(id, netId, available)
    -- Some FXServer builds expose unresolved sentinel IDs near the upper end of
    -- the uint16 range for server-created peds. Do not call NetToPed for them:
    -- it emits client warnings and the regular local fallback is safer.
    if available and netId and netId ~= 0 and netId < 65528 then
        pendingNetworkEntities[id] = netId
        CreateThread(function()
            local deadline = GetGameTimer() + 5000
            repeat
                if pendingNetworkEntities[id] ~= netId or not AINPCDefinitions[id] then return end
                local ped = NetToPed(netId)
                if ped ~= 0 and DoesEntityExist(ped) then
                    if AINPCClientEntities[id] and AINPCClientEntities[id] ~= ped then
                        releaseEntity(id)
                    end
                    configurePed(ped)
                    AINPCClientEntities[id] = ped
                    AINPCClientEntityOwnership[id] = false
                    if pendingNetworkEntities[id] == netId then pendingNetworkEntities[id] = nil end
                    if AINPCTargets and AINPCTargets.register then AINPCTargets.register(id, ped) end
                    return
                end
                Wait(100)
            until GetGameTimer() >= deadline
            if pendingNetworkEntities[id] == netId then pendingNetworkEntities[id] = nil end
        end)
        return
    end
    pendingNetworkEntities[id] = nil
    if not available and AINPCClientEntities[id] then
        releaseEntity(id)
    end
    if not available and AINPCDefinitions[id] and AINPCDefinitions[id].enabled ~= false then
        local missingId = id
        SetTimeout(Config.Entities.respawnDelayMs or 5000, function()
            if AINPCDefinitions[missingId] and AINPCDefinitions[missingId].enabled ~= false and not AINPCClientEntities[missingId] then
                ensureFallbackEntities()
            end
        end)
    end
end)

local function loadModel(modelName)
    local hash = joaat(modelName)
    if not IsModelInCdimage(hash) or not IsModelValid(hash) then return nil end
    RequestModel(hash)
    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do Wait(0) end
    return HasModelLoaded(hash) and hash or nil
end

local function suppressAmbientDuplicates(coords, keepPed)
    local targetPos = vec3(coords.x, coords.y, coords.z)
    local peds = GetGamePool('CPed')
    for _, entity in ipairs(peds) do
        if entity ~= keepPed and DoesEntityExist(entity) and not IsPedAPlayer(entity) then
            local isConfigured = false
            for _, cfgPed in pairs(AINPCClientEntities) do
                if cfgPed == entity then isConfigured = true; break end
            end
            if not isConfigured and #(GetEntityCoords(entity) - targetPos) < 2.5 then
                SetEntityAsMissionEntity(entity, true, true)
                DeletePed(entity)
                DeleteEntity(entity)
            end
        end
    end
end

ensureFallbackEntities = function()
    for id, npc in pairs(AINPCDefinitions) do
        if npc.enabled == false then
            if AINPCClientEntities[id] then releaseEntity(id) end
            goto continue
        end
        if AINPCClientEntities[id] or pendingNetworkEntities[id] then
            if AINPCClientEntities[id] then suppressAmbientDuplicates(npc.coords, AINPCClientEntities[id]) end
            goto continue
        end
        suppressAmbientDuplicates(npc.coords, nil)
        local model = loadModel(npc.model)
        if model then
            local ped = CreatePed(4, model, npc.coords.x, npc.coords.y, npc.coords.z, npc.coords.w, false, false)
            SetEntityAsMissionEntity(ped, true, true)
            configurePed(ped)
            AINPCClientEntities[id] = ped
            AINPCClientEntityOwnership[id] = true
            suppressAmbientDuplicates(npc.coords, ped)
            if AINPCTargets and AINPCTargets.register then AINPCTargets.register(id, ped) end
            SetModelAsNoLongerNeeded(model)
        else
            print(('[peak-ai-npc] invalid NPC model for %s: %s'):format(id, npc.model))
        end
        ::continue::
    end
end

CreateThread(function()
    Wait(1000)
    TriggerServerEvent(AINPC.Event.SyncEntities)
    local deadline = GetGameTimer() + 7000
    while not entitySyncComplete and GetGameTimer() < deadline do Wait(100) end
    ensureFallbackEntities()
end)

CreateThread(function()
    while true do
        Wait(Config.Entities.lifecycleCheckMs or 1000)
        local missingConfiguredEntity = false
        for id, ped in pairs(AINPCClientEntities) do
            if not DoesEntityExist(ped) then
                releaseEntity(id)
                missingConfiguredEntity = AINPCDefinitions[id] and AINPCDefinitions[id].enabled ~= false or missingConfiguredEntity
            end
            if DoesEntityExist(ped) and IsEntityDead(ped) then
                releaseEntity(id)
                local deadId = id
                SetTimeout(Config.Entities.respawnDelayMs or 5000, function()
                    if AINPCDefinitions[deadId] and AINPCDefinitions[deadId].enabled ~= false and not AINPCClientEntities[deadId] then
                        ensureFallbackEntities()
                    end
                end)
            end
        end
        for id, npc in pairs(AINPCDefinitions) do
            if npc.enabled ~= false and npc.coords then
                suppressAmbientDuplicates(npc.coords, AINPCClientEntities[id])
            end
        end
        if missingConfiguredEntity then
            SetTimeout(Config.Entities.respawnDelayMs or 5000, function()
                ensureFallbackEntities()
            end)
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    for id, ped in pairs(AINPCClientEntities) do
        releaseEntity(id)
    end
end)
