AINPCServerEntities = { records = {}, fallbacks = {}, spawning = {}, disabled = {}, nextSpawnAt = {} }

local function oneSyncAvailable()
    local mode = GetConvar('onesync', 'off')
    return mode ~= 'off' and mode ~= ''
end

local function announce(source, id, ped, available)
    local netId = 0
    if available and ped and DoesEntityExist(ped) then netId = NetworkGetNetworkIdFromEntity(ped) end
    TriggerClientEvent(AINPC.Event.EntityState, source or -1, id, netId, available == true)
end

local function definitionSignature(npc)
    local coords = npc.coords or {}
    return table.concat({ tostring(npc.model), tostring(coords.x), tostring(coords.y), tostring(coords.z), tostring(coords.w) }, '|')
end

local function clientDefinition(id, npc)
    return {
        id = id,
        model = npc.model,
        coords = { x = npc.coords.x, y = npc.coords.y, z = npc.coords.z, w = npc.coords.w },
        identity = {
            name = npc.identity and npc.identity.name or id,
            occupation = npc.identity and npc.identity.occupation or 'NPC'
        },
        enabled = npc.enabled ~= false,
        interactionDistance = npc.interactionDistance,
        -- Only presentation-safe shop flags are sent to clients. Economy and
        -- robbery policy remain server-owned.
        shop = npc.shop and { robbery = npc.shop.robbery and { enabled = npc.shop.robbery.enabled ~= false } or nil } or nil
    }
end

function AINPCServerEntities.syncDefinitions(source)
    local definitions = {}
    for id, npc in pairs(AINPCDefinitions) do definitions[id] = clientDefinition(id, npc) end
    TriggerClientEvent(AINPC.Event.DefinitionSync, source or -1, definitions)
end

function AINPCServerEntities.remove(id)
    local record = AINPCServerEntities.records[id]
    if record and record.ped and DoesEntityExist(record.ped) then DeleteEntity(record.ped) end
    AINPCServerEntities.records[id] = nil
    AINPCServerEntities.fallbacks[id] = nil
    AINPCServerEntities.spawning[id] = nil
    AINPCServerEntities.nextSpawnAt[id] = nil
    announce(-1, id, nil, false)
end

local function spawnNpc(id, npc)
    if npc.enabled == false then return false, 'interaction_disabled' end
    if not oneSyncAvailable() then return false, 'onesync_disabled' end
    local hash = joaat(npc.model)
    local ped = CreatePed(4, hash, npc.coords.x, npc.coords.y, npc.coords.z, npc.coords.w, true, true)
    if not ped or ped == 0 then return false, 'create_ped_failed' end
    local deadline = GetGameTimer() + 10000
    while not DoesEntityExist(ped) and GetGameTimer() < deadline do Wait(50) end
    if not DoesEntityExist(ped) then return false, 'ped_not_ready' end
    local netId
    local networkDeadline = GetGameTimer() + 5000
    repeat
        netId = NetworkGetNetworkIdFromEntity(ped)
        if netId and netId > 0 and netId < 65528 then break end
        Wait(50)
    until GetGameTimer() >= networkDeadline
    -- FXServer may briefly expose unresolved sentinel IDs (for example 65533)
    -- while registering a new server-created ped. If no usable ID appears
    -- within the bounded wait, remove it and use the safe client fallback.
    if not netId or netId == 0 or netId >= 65528 then
        DeleteEntity(ped)
        return false, 'network_id_unavailable'
    end
    SetEntityOrphanMode(ped, 2)
    Entity(ped).state:set('ainpc:id', id, true)
    Entity(ped).state:set('ainpc:state', AINPC.State.Idle, true)
    Entity(ped).state:set('ainpc:interactionEnabled', true, true)
    AINPCServerEntities.records[id] = { ped = ped, model = npc.model, signature = definitionSignature(npc), spawnedAt = os.time() }
    if AINPCBehavior then AINPCBehavior.reconcile(id, npc, ped, nil, true) end
    return true
end

function AINPCServerEntities.spawnAll()
    for id, npc in pairs(AINPCDefinitions) do
        if npc.enabled == false then
            if not AINPCServerEntities.disabled[id] then
                AINPCServerEntities.remove(id)
                AINPCServerEntities.disabled[id] = true
            end
            goto continue
        end
        AINPCServerEntities.disabled[id] = nil
        if (AINPCServerEntities.nextSpawnAt[id] or 0) > GetGameTimer() then goto continue end
        local signature = definitionSignature(npc)
        local record = AINPCServerEntities.records[id]
        if record and not DoesEntityExist(record.ped) then AINPCServerEntities.records[id] = nil; record = nil end
        if record and record.signature ~= signature then
            if DoesEntityExist(record.ped) then DeleteEntity(record.ped) end
            AINPCServerEntities.records[id] = nil
            record = nil
        end
        if AINPCServerEntities.fallbacks[id] and AINPCServerEntities.fallbacks[id] ~= signature then AINPCServerEntities.fallbacks[id] = nil end
        if AINPCServerEntities.fallbacks[id] == signature then goto continue end
        if not AINPCServerEntities.records[id] and not AINPCServerEntities.spawning[id] then
            AINPCServerEntities.spawning[id] = true
            local ok, reason = spawnNpc(id, npc)
            AINPCServerEntities.spawning[id] = nil
            if ok then
                AINPCServerEntities.nextSpawnAt[id] = nil
                announce(-1, id, AINPCServerEntities.records[id].ped, true)
            else
                AINPCServerEntities.fallbacks[id] = signature
                print(('[peak-ai-npc] server NPC %s using client fallback: %s'):format(id, reason))
            end
        end
        ::continue::
    end
end

function AINPCServerEntities.setEnabled(id, enabled)
    local npc = AINPCDefinitions[id]
    if not npc or type(enabled) ~= 'boolean' then return false, 'invalid_npc_state' end
    npc.enabled = enabled
    if not enabled then
        AINPCServerEntities.remove(id)
        AINPCServerEntities.disabled[id] = true
    else
        AINPCServerEntities.disabled[id] = nil
        AINPCServerEntities.fallbacks[id] = nil
        AINPCServerEntities.nextSpawnAt[id] = nil
        AINPCServerEntities.spawnAll()
    end
    AINPCServerEntities.syncDefinitions(-1)
    return true
end

-- Some FXServer builds do not assign usable network IDs until at least one
-- client is present. Retry prior safe fallbacks once after each player joins;
-- the per-NPC spawning lock prevents catalog/timer/join races from duplicating.
AddEventHandler('playerJoining', function()
    AINPCServerEntities.fallbacks = {}
    SetTimeout(3000, function() AINPCServerEntities.spawnAll() end)
end)

CreateThread(function()
    while true do
        Wait(Config.Entities.lifecycleCheckMs or 1000)
        for id, record in pairs(AINPCServerEntities.records) do
            local dead = not record.ped or not DoesEntityExist(record.ped)
            if not dead then
                local isDeadOk, health = pcall(GetEntityHealth, record.ped)
                local isDead = isDeadOk and type(health) == 'number' and health <= 0
                if isDead then
                    dead = true
                end
            end
            if dead then
                if record.ped and DoesEntityExist(record.ped) then DeleteEntity(record.ped) end
                AINPCServerEntities.records[id] = nil
                AINPCServerEntities.fallbacks[id] = nil
                AINPCServerEntities.nextSpawnAt[id] = GetGameTimer() + (Config.Entities.respawnDelayMs or 5000)
                announce(-1, id, nil, false)
            end
        end
        AINPCServerEntities.spawnAll()
    end
end)

RegisterNetEvent(AINPC.Event.SyncEntities, function()
    local source = source
    AINPCServerEntities.syncDefinitions(source)
    for id, record in pairs(AINPCServerEntities.records) do
        announce(source, id, record.ped, DoesEntityExist(record.ped))
    end
    -- Client fallback peds are presentation-only, but they still render a
    -- server-selected directive rather than independently choosing a routine.
    if AINPCBehavior then
        for id, npc in pairs(AINPCDefinitions) do
            local record = AINPCServerEntities.records[id]
            if not record or not record.ped or not DoesEntityExist(record.ped) then
                AINPCBehavior.reconcile(id, npc, nil, source, true)
            end
        end
    end
    TriggerClientEvent(AINPC.Event.EntitySyncComplete, source)
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    for id, record in pairs(AINPCServerEntities.records) do
        if record.ped and DoesEntityExist(record.ped) then DeleteEntity(record.ped) end
        AINPCServerEntities.records[id] = nil
    end
    AINPCServerEntities.fallbacks = {}
    AINPCServerEntities.spawning = {}
    AINPCServerEntities.disabled = {}
    AINPCServerEntities.nextSpawnAt = {}
end)
