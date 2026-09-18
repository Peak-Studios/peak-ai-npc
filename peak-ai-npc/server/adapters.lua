AINPCAdapters = {}
local serviceHandler
local serviceHandlerOwner
local inventoryAdapter
local inventoryAdapterOwner

function AINPCAdapters.registerServiceHandler(handler)
    if type(handler) ~= 'function' then return false end
    local owner = GetInvokingResource() or GetCurrentResourceName()
    if not Config.Dispatch or type(Config.Dispatch.integrations) ~= 'table' or Config.Dispatch.integrations[owner] ~= true then return false, 'dispatch_resource_not_allowed' end
    if serviceHandler and serviceHandlerOwner ~= owner then return false, 'service_handler_already_registered' end
    serviceHandler = handler
    serviceHandlerOwner = owner
    return true
end

function AINPCAdapters.registerInventoryAdapter(adapter)
    if type(adapter) ~= 'table' or type(adapter.canCarry) ~= 'function' or type(adapter.addItem) ~= 'function' or type(adapter.getItemCount) ~= 'function' then return false, 'invalid_inventory_adapter' end
    local owner = GetInvokingResource() or GetCurrentResourceName()
    if inventoryAdapter and inventoryAdapterOwner ~= owner then return false, 'inventory_adapter_already_registered' end
    inventoryAdapter = adapter
    inventoryAdapterOwner = owner
    return true
end

-- Dispatch adapters receive only a bounded report, never the mutable session or
-- private framework record. They must explicitly acknowledge acceptance.
function AINPCAdapters.callService(source, session, service, reason)
    local policy = Config.Dispatch
    if type(policy) ~= 'table' or policy.enabled ~= true then return false, 'dispatch_disabled' end
    local aliases = { police = 'police', sheriff = 'police', ['911'] = 'police', ems = 'ems', ambulance = 'ems', medical = 'ems' }
    service = aliases[service]
    if not service then return false, 'invalid_service' end
    if reason ~= nil and (type(reason) ~= 'string' or #reason < 1 or #reason > 256 or reason:find('%c')) then return false, 'invalid_report' end
    local valid, failure = AINPCSessions.valid(source, session)
    if not valid then return false, failure end
    if session.npc.enabled == false or not session.entity or session.entity == 0 or session.npc.localEntity then return false, 'network_entity_required' end
    local allowed = false
    for _, name in ipairs(session.npc.allowedTools or {}) do
        if name == 'npc_call_service' or name == (service == 'police' and 'npc_call_police' or 'npc_call_ems') then allowed = true end
    end
    if not allowed then return false, 'service_unavailable' end
    if not serviceHandler or not serviceHandlerOwner or GetResourceState(serviceHandlerOwner) ~= 'started'
        or type(policy.integrations) ~= 'table' or policy.integrations[serviceHandlerOwner] ~= true then
        return false, 'dispatch_adapter_not_configured'
    end
    local ok, identity = pcall(function()
        local adapter = AINPCAdapters.framework()
        local player = adapter.getPlayer(source)
        local id = player and adapter.getCharacterId(player)
        if type(id) ~= 'string' or #id < 1 or #id > 128 then return nil end
        return adapter.name .. ':' .. id
    end)
    if not ok or not identity then return false, 'player_unavailable' end
    local location = GetEntityCoords(GetPlayerPed(source))
    local bucket = GetPlayerRoutingBucket(source)
    for _, axis in ipairs({ 'x', 'y', 'z' }) do
        local value = location[axis]
        if type(value) ~= 'number' or value ~= value or math.abs(value) > 100000 then return false, 'location_unavailable' end
    end
    local cooldown, globalCooldown = policy.cooldownSeconds, policy.globalCooldownSeconds
    if type(cooldown) ~= 'number' or cooldown % 1 ~= 0 or cooldown < 1 or cooldown > 86400
        or type(globalCooldown) ~= 'number' or globalCooldown % 1 ~= 0 or globalCooldown < 1 or globalCooldown > 3600 then
        return false, 'invalid_dispatch_policy'
    end
    local keys = { { 'ainpc:dispatch:v1:character:' .. identity, cooldown }, { 'ainpc:dispatch:v1:global', globalCooldown } }
    local now = os.time()
    for _, entry in ipairs(keys) do
        local read, stored = pcall(GetResourceKvpString, entry[1])
        local value = stored and tonumber(stored)
        if not read or (stored and (not value or value ~= value or value % 1 ~= 0)) then return false, 'dispatch_storage_unavailable' end
        if value and value > now then return false, 'dispatch_rate_limited' end
    end
    -- Reserve before invoking an adapter. Unknown/failed outcomes retain the
    -- reservation: retrying must not create a second emergency alert.
    for _, entry in ipairs(keys) do
        local value = tostring(now + entry[2])
        local wrote = pcall(SetResourceKvp, entry[1], value)
        local read, stored = pcall(GetResourceKvpString, entry[1])
        if not wrote or not read or stored ~= value then return false, 'dispatch_storage_unavailable' end
    end
    local handler, owner = serviceHandler, serviceHandlerOwner
    local report = { service = service, location = { x = location.x, y = location.y, z = location.z },
        routingBucket = bucket, scope = 'incident_report', unverifiedNarrative = reason,
        npcId = session.npcId, sessionId = session.id, sessionRevision = session.revision }
    local accepted, result = pcall(handler, source, report)
    if not accepted or handler ~= serviceHandler or owner ~= serviceHandlerOwner or GetResourceState(owner) ~= 'started' then
        return false, 'dispatch_outcome_unknown'
    end
    if type(result) ~= 'table' or result.ok ~= true or result.accepted ~= true then return false, 'dispatch_not_acknowledged' end
    return true, { ok = true, accepted = true, service = service }
end

local function detectFramework()
    if Config.Framework ~= 'auto' then return Config.Framework end
    if GetResourceState('fw-core') == 'started' then return 'fw-core' end
    if GetResourceState('qbx_core') == 'started' then return 'qbox' end
    if GetResourceState('qb-core') == 'started' then return 'qbcore' end
    if GetResourceState('es_extended') == 'started' then return 'esx' end
    return 'standalone'
end

local function readSafely(fn)
    local ok, result = pcall(fn)
    if ok then return result end
end

local function publicJob(job)
    if type(job) ~= 'table' then return nil end
    return { name = type(job.name) == 'string' and job.name:sub(1, 64) or nil,
        label = type(job.label) == 'string' and job.label:sub(1, 96) or nil,
        onduty = job.onduty == true }
end

function AINPCAdapters.framework()
    local name = detectFramework()
    local resources = { ['fw-core'] = 'fw-core', qbcore = 'qb-core', qbox = 'qbx_core', esx = 'es_extended' }
    local resource = resources[name]
    local function getPlayer(source)
        if not resource or GetResourceState(resource) ~= 'started' then return nil end
        return readSafely(function()
            if name == 'qbox' then return exports[resource]:GetPlayer(source) end
            if name == 'esx' then
                local core = exports[resource]:getSharedObject()
                return core and core.GetPlayerFromId(source)
            end
            local core = exports[resource]:GetCoreObject()
            return core and core.Functions and core.Functions.GetPlayer(source)
        end)
    end
    return {
        name = name,
        getPlayer = getPlayer,
        getCharacterId = function(player)
            if not resource or GetResourceState(resource) ~= 'started' then return nil end
            return readSafely(function()
                if name == 'esx' then return player and (player.identifier or player.getIdentifier()) end
                return player and player.PlayerData and player.PlayerData.citizenid
            end)
        end,
        getAuthorizationContext = function(player)
            if not resource or GetResourceState(resource) ~= 'started' then return nil end
            return readSafely(function()
                if name == 'esx' then return { job = player and player.getJob() } end
                local data = player and player.PlayerData
                return data and { job = data.job, gang = data.gang }
            end)
        end,
        getPublicContext = function(player)
            if not resource or GetResourceState(resource) ~= 'started' then return {} end
            return readSafely(function()
                if name == 'esx' then return { name = player and player.getName(), job = publicJob(player and player.getJob()) } end
                local data = player and player.PlayerData or {}
                local info = type(data.charinfo) == 'table' and data.charinfo or {}
                local first = type(info.firstname) == 'string' and info.firstname:sub(1, 64) or ''
                local last = type(info.lastname) == 'string' and info.lastname:sub(1, 64) or ''
                -- Phone, finance, health, licenses, gang, biometrics and full job
                -- metadata require a separate scoped adapter; never public context.
                return { name = (first .. ' ' .. last):match('^%s*(.-)%s*$'), job = publicJob(data.job) }
            end) or {}
        end,
        notify = function(source, message, kind)
            TriggerClientEvent('peak_ai_npc:client:notify', source, message, kind or 'inform')
        end
    }
end

function AINPCAdapters.inventory()
    if Config.Inventory ~= 'auto' then return Config.Inventory end
    if GetResourceState('fw-inventory') == 'started' then return 'fw-inventory' end
    if GetResourceState('ox_inventory') == 'started' then return 'ox_inventory' end
    if GetResourceState('qb-inventory') == 'started' then return 'qb-inventory' end
    if detectFramework() == 'esx' then return 'esx-native' end
    return 'standalone'
end

function AINPCAdapters.playerHasItem(source, item, quantity)
    if type(item) ~= 'string' or #item < 1 or #item > 64 or not item:match('^[%w_%-]+$')
        or type(quantity) ~= 'number' or quantity % 1 ~= 0 or quantity < 1 or quantity > 10000 then return false, 'invalid_item_query' end
    local inventory = AINPCAdapters.inventory()
    local adapter = AINPCAdapters.framework()
    local player = adapter.getPlayer(source)
    if not player then return false, 'player_unavailable' end
    if inventory ~= 'custom' and inventory ~= 'esx-native' and GetResourceState(inventory) ~= 'started' then
        return false, 'inventory_adapter_unavailable'
    end
    local count
    if inventory == 'fw-inventory' and adapter.name == 'fw-core' then
        local ok, itemData = pcall(function() return exports['fw-inventory']:GetItemData(item) end)
        if not ok or type(itemData) ~= 'table' then return false, 'unknown_item' end
        local slots = player.PlayerData and player.PlayerData.inventory
        if type(slots) ~= 'table' then return false, 'inventory_query_failed' end
        count = 0
        for _, row in pairs(slots) do
            if type(row) == 'table' and row.Item == item then
                if type(row.Amount) ~= 'number' or row.Amount % 1 ~= 0 or row.Amount < 0 then return false, 'inventory_query_failed' end
                count = count + row.Amount
            end
        end
    elseif inventory == 'ox_inventory' then
        count = readSafely(function() return exports.ox_inventory:GetItemCount(source, item, nil, true) end)
    elseif inventory == 'qb-inventory' and adapter.name == 'qbcore' then
        count = readSafely(function() return exports['qb-inventory']:GetItemCount(source, item) end)
    elseif inventory == 'custom' then
        if not inventoryAdapter or not inventoryAdapterOwner or GetResourceState(inventoryAdapterOwner) ~= 'started' then
            return false, 'custom_inventory_adapter_not_configured'
        end
        count = readSafely(function() return inventoryAdapter.getItemCount(source, item) end)
    elseif inventory == 'esx-native' and adapter.name == 'esx' then
        local row = readSafely(function() return player.getInventoryItem(item) end)
        count = type(row) == 'table' and row.count
    else
        return false, 'inventory_adapter_not_configured'
    end
    if type(count) ~= 'number' or count % 1 ~= 0 or count < 0 or count > 1000000000 then return false, 'inventory_query_failed' end
    return true, { item = item, quantity = quantity, count = count, hasItem = count >= quantity }
end


AddEventHandler('onResourceStop', function(resourceName)
    if serviceHandlerOwner == resourceName then serviceHandler = nil; serviceHandlerOwner = nil end
    if inventoryAdapterOwner == resourceName then inventoryAdapter = nil; inventoryAdapterOwner = nil end
end)
