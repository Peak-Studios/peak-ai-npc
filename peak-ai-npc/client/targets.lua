AINPCTargets = { registered = {} }
local ambientRegistered = false
local vehicleRegistered = false
local targetResource
local globalResource
local ambientLabel, driverLabel = 'Talk to local resident (AI)', 'Talk to driver (AI)'
local function clearGlobals(resource)
    if resource == 'ox_target' then
        pcall(function() exports.ox_target:removeGlobalPed('peak_ai_npc_ambient') end)
        pcall(function() exports.ox_target:removeGlobalVehicle('peak_ai_npc_driver') end)
    elseif resource == 'qb-target' then
        pcall(function() exports['qb-target']:RemoveGlobalPed(ambientLabel) end)
        pcall(function() exports['qb-target']:RemoveGlobalVehicle(driverLabel) end)
    end
    ambientRegistered, vehicleRegistered = false, false
end
local function driver(vehicle)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return nil end
    local ped = GetPedInVehicleSeat(vehicle, -1)
    if ped ~= 0 and DoesEntityExist(ped) and IsPedHuman(ped) and not IsPedAPlayer(ped) and not IsEntityDead(ped) then return ped end
end

local function registerVehicleTarget(resource)
    if vehicleRegistered or not Config.Police.enabled then return end
    local function talk(vehicle)
        local ped = driver(vehicle)
        if ped and AINPCStartAmbientConversation then AINPCStartAmbientConversation(ped) end
    end
    if resource == 'ox_target' then
        vehicleRegistered = pcall(function() exports.ox_target:addGlobalVehicle({ { name='peak_ai_npc_driver', label='Talk to driver', icon='fa-solid fa-comments',
            distance=Config.Police.interactionDistance, canInteract=function(entity) return driver(entity) ~= nil end,
            onSelect=function(data) talk(data.entity) end } }) end)
    elseif resource == 'qb-target' then
        vehicleRegistered = pcall(function() exports['qb-target']:AddGlobalVehicle({options={{label=driverLabel,icon='fas fa-comments',
            canInteract=function(entity) return driver(entity) ~= nil end,action=talk}},distance=Config.Police.interactionDistance}) end)
    end
end

local function configuredPed(ped)
    for _, configured in pairs(AINPCClientEntities or {}) do if configured == ped then return true end end
    return false
end

local function nearConfiguredNpc(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return false end
    if configuredPed(ped) then return true end
    local coords = GetEntityCoords(ped)
    for _, configured in pairs(AINPCClientEntities or {}) do
        if DoesEntityExist(configured) and #(coords - GetEntityCoords(configured)) < 4.0 then
            return true
        end
    end
    for _, def in pairs(AINPCDefinitions or {}) do
        if def.coords then
            local defPos = vec3(def.coords.x, def.coords.y, def.coords.z)
            if #(coords - defPos) < 4.0 then return true end
        end
    end
    return false
end

local function registerAmbientTarget()
    if ambientRegistered or not Config.Ambient.enabled then return end
    local resource = targetResource()
    local option = {
        name = 'peak_ai_npc_ambient', icon = 'fa-solid fa-comments', label = 'Talk', distance = Config.Ambient.interactionDistance or 3.0,
        canInteract = function(entity) return entity and entity ~= 0 and DoesEntityExist(entity) and IsEntityAPed(entity) and IsPedHuman(entity) and not IsPedAPlayer(entity) and not IsEntityDead(entity) and not nearConfiguredNpc(entity) end,
        onSelect = function(data) if AINPCStartAmbientConversation then AINPCStartAmbientConversation(data and data.entity) end end
    }
    if resource == 'ox_target' then
        ambientRegistered = pcall(function() exports.ox_target:addGlobalPed({ option }) end)
    elseif resource == 'qb-target' then
        ambientRegistered = pcall(function() exports['qb-target']:AddGlobalPed({ options = { { icon = 'fas fa-comments', label = ambientLabel, action = function(entity) if AINPCStartAmbientConversation then AINPCStartAmbientConversation(entity) end end, canInteract = option.canInteract } }, distance = option.distance }) end)
    end
end

targetResource = function()
    if Config.Target == 'native' then return 'native' end
    if Config.Target ~= 'auto' and Config.Target ~= 'native' then
        if GetResourceState(Config.Target) == 'started' then return Config.Target end
        print(('[peak-ai-npc] configured target resource is not started: %s; using native fallback'):format(Config.Target))
        return 'native'
    end
    if GetResourceState('ox_target') == 'started' then return 'ox_target' end
    if GetResourceState('qb-target') == 'started' then return 'qb-target' end
    return 'native'
end

function AINPCTargets.resource()
    return targetResource()
end

function AINPCTargets.unregister(id)
    local entry = AINPCTargets.registered[id]
    if not entry then return end
    if entry.resource == 'fw-ui' then
        pcall(function() exports['fw-ui']:RemoveEyeEntry('peak_ai_npc_' .. id) end)
    elseif entry.resource == 'ox_target' then
        pcall(function() exports.ox_target:removeLocalEntity(entry.ped, { 'peak_ai_npc_' .. id }) end)
    elseif entry.resource == 'qb-target' then
        pcall(function() exports['qb-target']:RemoveTargetEntity(entry.ped, entry.label) end)
    end
    AINPCTargets.registered[id] = nil
end

function AINPCTargets.register(id, ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return end
    if not AINPCDefinitions[id] or AINPCDefinitions[id].enabled == false then
        AINPCTargets.unregister(id)
        return
    end
    local existing = AINPCTargets.registered[id]
    if existing and existing.ped == ped and existing.resource == targetResource() then return end
    if existing then AINPCTargets.unregister(id) end
    local resource = targetResource()
    local label = (AINPCDefinitions[id].identity and AINPCDefinitions[id].identity.name or id)
    if resource == 'fw-ui' then
        local options = {
            {
                Name = 'talk_' .. id,
                Icon = 'fas fa-comments',
                Label = 'Talk to ' .. label,
                EventType = 'Client',
                EventName = 'peak_ai_npc:client:targetTalk',
                EventParams = { npcId = id, entity = ped },
                Enabled = function() return true end
            }
        }
        if AINPCDefinitions[id] and AINPCDefinitions[id].shop then
            table.insert(options, {
                Name = 'shop_' .. id,
                Icon = 'fas fa-shopping-basket',
                Label = 'Browse Wares',
                EventType = 'Client',
                EventName = 'peak_ai_npc:client:openShopWares',
                EventParams = { npcId = id, entity = ped },
                Enabled = function() return true end
            })
        end
        local ok = pcall(function()
            exports['fw-ui']:AddEyeEntry('peak_ai_npc_' .. id, {
                Type = 'Entity',
                Entity = ped,
                Distance = AINPCDefinitions[id].interactionDistance or 3.0,
                Options = options
            })
        end)
        if ok then
            AINPCTargets.registered[id] = { resource = resource, ped = ped, label = 'Talk to ' .. label }
        else
            print(('[peak-ai-npc] fw-ui registration failed for %s; native keybind remains available'):format(id))
        end
    elseif resource == 'ox_target' then
        local ok = pcall(function() exports.ox_target:addLocalEntity(ped, { { name = 'peak_ai_npc_' .. id, icon = 'fa-solid fa-comments', label = 'Talk to ' .. label, distance = AINPCDefinitions[id].interactionDistance or 3.0, onSelect = function(data) AINPCStartConversation(id, data and data.entity or ped) end } }) end)
        if ok then AINPCTargets.registered[id] = { resource = resource, ped = ped, label = 'Talk to ' .. label } else print(('[peak-ai-npc] ox_target registration failed for %s; native keybind remains available'):format(id)) end
    elseif resource == 'qb-target' then
        local ok = pcall(function() exports['qb-target']:AddTargetEntity(ped, { options = { { icon = 'fas fa-comments', label = 'Talk to ' .. label, action = function(entity) AINPCStartConversation(id, entity or ped) end } }, distance = AINPCDefinitions[id].interactionDistance or 3.0 }) end)
        if ok then AINPCTargets.registered[id] = { resource = resource, ped = ped, label = 'Talk to ' .. label } else print(('[peak-ai-npc] qb-target registration failed for %s; native keybind remains available'):format(id)) end
    else
        AINPCTargets.registered[id] = { resource = 'native', ped = ped }
    end
end

local function safeRegisterNetEvent(name, fn)
    if RegisterNetEvent then
        RegisterNetEvent(name, fn)
    elseif AddEventHandler then
        AddEventHandler(name, fn)
    end
end

local function safeTriggerEvent(name, ...)
    if TriggerEvent then
        TriggerEvent(name, ...)
    end
end

safeRegisterNetEvent('peak_ai_npc:client:targetTalk', function(data)
    if data and data.npcId then
        AINPCStartConversation(data.npcId, data.entity)
    end
end)

local function resolveStoreNpcId(storeName)
    if storeName == '247' then return 'shopkeeper' end
    if storeName == 'Liqour' then return 'shopkeeper_liquor' end
    if storeName == 'Toolshop' then return 'shopkeeper_toolshop' end
    return 'shopkeeper'
end

safeRegisterNetEvent('peak_ai_npc:client:openStoreShopkeeper', function(data)
    local storeName = data and data.Store or '247'
    local npcId = resolveStoreNpcId(storeName)
    AINPCStartConversation(npcId)
end)

safeRegisterNetEvent('peak_ai_npc:client:openStoreWares', function(data)
    local storeName = data and data.Store or '247'
    local npcId = resolveStoreNpcId(storeName)
    safeTriggerEvent('peak_ai_npc:client:openShopCatalog', npcId)
end)

safeRegisterNetEvent('peak_ai_npc:client:openShopWares', function(data)
    if data and data.npcId then
        safeTriggerEvent('peak_ai_npc:client:openShopCatalog', data.npcId)
    end
end)

CreateThread(function()
    Wait(1000)
    globalResource = targetResource()
    registerAmbientTarget()
    registerVehicleTarget(targetResource())
    while true do
        Wait(1000)
        local resource = targetResource()
        if globalResource ~= resource then clearGlobals(globalResource); globalResource = resource end
        registerAmbientTarget()
        registerVehicleTarget(targetResource())
        for id, ped in pairs(AINPCClientEntities or {}) do AINPCTargets.register(id, ped) end
    end
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource == 'fw-ui' or resource == 'ox_target' or resource == 'qb-target' then
        if globalResource == resource then ambientRegistered, vehicleRegistered = false, false end
        for id, entry in pairs(AINPCTargets.registered) do
            if entry.resource == resource then AINPCTargets.registered[id] = nil end
        end
    end
end)
