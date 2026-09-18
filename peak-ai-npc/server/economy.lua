-- Server settlement and recovery journal. Inventory API translation lives in
-- commerce_drivers.lua; framework detection never grants confirmation authority.
local generations, drivers, owners, busy = {}, {}, {}, {}
local journalPrefix = 'ainpc:commerce:v1:'

local function integer(value, minimum, maximum)
    return type(value) == 'number' and value == value and value % 1 == 0 and value >= minimum and value <= maximum
end

local function callBoolean(fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok or (result ~= true and result ~= false) then return nil end
    return result
end

local function started(resource) return GetResourceState(resource) == 'started' end

local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for key, value in pairs(a) do if not same(value, b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end

local function qbDriver(source)
    if not started('qb-core') or not started('qb-inventory') then return nil end
    local core = exports['qb-core']:GetCoreObject({ 'Shared', 'Functions' })
    local player = core and core.Functions and core.Functions.GetPlayer(source)
    if not player then player = exports['qb-core']:GetPlayer(source) end
    local data, functions = player and player.PlayerData, player and player.Functions
    if not data or type(data.citizenid) ~= 'string' or not functions then return nil end
    local revision = (generations['qb-core'] or 0) .. ':' .. (generations['qb-inventory'] or 0)
    local driver = { identity = 'qbcore:' .. data.citizenid }
    driver.valid = function()
        if not started('qb-core') or not started('qb-inventory')
            or revision ~= (generations['qb-core'] or 0) .. ':' .. (generations['qb-inventory'] or 0) then return false end
        local current = exports['qb-core']:GetPlayer(source)
        return current and current.PlayerData and current.PlayerData.citizenid == data.citizenid or false
    end
    driver.item = function(item) return core.Shared and core.Shared.Items and core.Shared.Items[item] end
    driver.cash = function() return functions.GetMoney('cash') end
    driver.debit = function(amount, id) return functions.RemoveMoney('cash', amount, id) end
    driver.credit = function(amount, id) return functions.AddMoney('cash', amount, id) end
    driver.canCarry = function(item, quantity) return exports['qb-inventory']:CanAddItem(source, item, quantity) end
    driver.add = function(item, quantity, slot, info, id)
        if slot then
            local current = exports['qb-core']:GetPlayer(source)
            local existing = current and current.PlayerData and current.PlayerData.items and current.PlayerData.items[slot]
            if existing and (existing.name ~= item or not same(existing.info or {}, info or {})) then return false end
        end
        return exports['qb-inventory']:AddItem(source, item, quantity, slot, info, id)
    end
    driver.remove = function(item, quantity, slot, id)
        return exports['qb-inventory']:RemoveItem(source, item, quantity, slot, id)
    end
    driver.items = function()
        local current = exports['qb-core']:GetPlayer(source)
        return current and current.PlayerData and current.PlayerData.items
    end
    return driver
end

function AINPCAdapters.registerCommerceDriver(name, factory)
    if type(name) ~= 'string' or not name:match('^[%w_%-]+:[%w_%-]+$') or type(factory) ~= 'function' then
        return false, 'invalid_commerce_driver'
    end
    local owner = GetInvokingResource() or GetCurrentResourceName()
    if not Config.Commerce or type(Config.Commerce.integrations) ~= 'table'
        or Config.Commerce.integrations[owner] ~= true then return false, 'commerce_resource_not_allowed' end
    if owners[name] and owners[name] ~= owner then return false, 'commerce_driver_owned' end
    drivers[name], owners[name] = factory, owner
    return true
end

local function driverFor(source)
    local framework = AINPCAdapters.framework()
    local inventory = AINPCAdapters.inventory()
    local resources = { qbcore = 'qb-core', qbox = 'qbx_core', esx = 'es_extended', ['fw-core'] = 'fw-core' }
    local resource = resources[framework.name]
    if not resource or not started(resource) then return nil end
    if inventory ~= 'esx-native' and inventory ~= 'custom' and not started(inventory) then return nil end
    local key = framework.name .. ':' .. inventory
    local player = framework.getPlayer(source)
    local character = player and framework.getCharacterId(player)
    if type(character) ~= 'string' or #character < 1 or #character > 128 then return nil end
    local driver, owner, factory
    if framework.name == 'qbcore' and inventory == 'qb-inventory' then driver = qbDriver(source)
    elseif AINPCCommerceDrivers then driver = AINPCCommerceDrivers.create(source, framework.name, inventory) end
    if not driver and drivers[key] and started(owners[key]) and Config.Commerce
        and type(Config.Commerce.integrations) == 'table' and Config.Commerce.integrations[owners[key]] == true then
        owner, factory = owners[key], drivers[key]
        driver = factory(source)
    end
    if type(driver) ~= 'table' or driver.identity ~= framework.name .. ':' .. character then return nil end
    local selected = driver
    driver = {}
    for name, value in pairs(selected) do driver[name] = value end
    for _, method in ipairs({ 'valid', 'item', 'cash', 'debit', 'credit', 'canCarry', 'add', 'remove', 'items' }) do
        if type(driver[method]) ~= 'function' then return nil end
    end
    local versions = { [resource] = generations[resource] or 0 }
    if inventory ~= 'esx-native' and inventory ~= 'custom' then versions[inventory] = generations[inventory] or 0 end
    if owner then versions[owner] = generations[owner] or 0 end
    local valid = driver.valid
    driver.valid = function()
        for dependency, version in pairs(versions) do
            if not started(dependency) or version ~= (generations[dependency] or 0) then return false end
        end
        if AINPCAdapters.framework().name ~= framework.name or AINPCAdapters.inventory() ~= inventory then return false end
        if owner and (owners[key] ~= owner or drivers[key] ~= factory or not Config.Commerce
            or not Config.Commerce.integrations or Config.Commerce.integrations[owner] ~= true) then return false end
        local current = framework.getPlayer(source)
        return current ~= nil and framework.getCharacterId(current) == character and valid() == true
    end
    if not driver.valid() then return nil end
    for _, method in ipairs({ 'debit', 'credit' }) do
        local mutate = driver[method]
        local direction = method == 'debit' and -1 or 1
        driver[method] = function(amount, id)
            if not driver.valid() then return nil end
            local before = driver.cash()
            if not integer(before, 0, 1000000000) then return nil end
            local expected = before + direction * amount
            if not integer(expected, 0, 1000000000) then return false end
            local accepted = mutate(amount, id)
            if not driver.valid() then return nil end
            local after = driver.cash()
            if accepted == true and after == expected then return true end
            if accepted == false and after == before then return false end
            return nil
        end
    end
    return driver
end

function AINPCAdapters.knownItem(source, item)
    if type(item) ~= 'string' or #item > 64 or not item:match('^[%w_%-]+$') then return false end
    local ok, driver = pcall(driverFor, source)
    if not ok or not driver then return false end
    local itemOk, definition = pcall(driver.item, item)
    return itemOk and type(definition) == 'table'
end

function AINPCAdapters.commerceCash(source)
    local ok, driver = pcall(driverFor, source)
    if not ok or not driver then return nil end
    local readOk, cash = pcall(driver.cash)
    return readOk and integer(cash, 0, 1000000000) and cash or nil
end

function AINPCAdapters.commerceIdentity(source)
    local ok, driver = pcall(driverFor, source)
    return ok and driver and driver.identity or nil
end

local function persist(key, state)
    local ok, encoded = pcall(json.encode, state)
    if not ok then return false end
    local written = pcall(SetResourceKvp, key, encoded)
    local readOk, stored = pcall(GetResourceKvpString, key)
    return written and readOk and stored == encoded
end

function AINPCAdapters.reward(source, amount, operationId, validate)
    if not integer(amount, 1, Config.Security.maximumTransactionValue) or type(operationId) ~= 'string'
        or #operationId < 1 or #operationId > 128 or not operationId:match('^[%w_:%-]+$')
        or type(validate) ~= 'function' then return false, 'invalid_reward' end
    local found, driver = pcall(driverFor, source)
    if not found or not driver or type(driver.identity) ~= 'string' then return false, 'reward_adapter_unavailable' end
    local identity = driver.identity
    local key = 'ainpc:reward:v1:' .. identity .. ':' .. operationId
    local function valid() return callBoolean(driver.valid) == true and callBoolean(validate) == true end
    if not valid() then return false, 'reward_scope_changed' end
    if busy[identity] then return false, 'transaction_busy' end
    local read, raw = pcall(GetResourceKvpString, key)
    if not read then return false, 'reward_storage_unavailable' end
    if raw then
        local decoded, previous = pcall(json.decode, raw)
        if not decoded or type(previous) ~= 'table' or previous.amount ~= amount or previous.id ~= operationId then
            return false, 'reward_storage_invalid'
        end
        if previous.status ~= 'complete' then return false, 'reward_outcome_unknown' end
        if previous.ok == true then return true, previous.reason end
        if previous.ok ~= false or previous.reason ~= 'reward_rejected' then return false, 'reward_storage_invalid' end
        -- An explicit false acknowledgement means no credit; allow a later
        -- retry. Pending/unknown outcomes above can never take this path.
    end
    local state = { id = operationId, amount = amount, status = 'pending' }
    busy[identity] = true
    if not persist(key, state) then busy[identity] = nil; return false, 'reward_storage_unavailable' end
    if not valid() then busy[identity] = nil; return false, 'reward_scope_changed' end
    local credited = callBoolean(driver.credit, amount, operationId)
    -- A throw/nil, lost character/adapter or failed journal write may follow a
    -- real credit. Keep the durable pending fence; never blindly pay again.
    if credited == nil or not valid() then return false, 'reward_outcome_unknown' end
    state.status, state.ok = 'complete', credited
    state.reason = credited and 'reward_paid' or 'reward_rejected'
    if not persist(key, state) then return false, 'reward_outcome_unknown' end
    busy[identity] = nil
    return credited, state.reason
end

local function snapshot(driver)
    local items = driver.items()
    if type(items) ~= 'table' then return nil end
    local copy = {}
    for _, row in pairs(items) do
        if type(row) ~= 'table' or type(row.name) ~= 'string' or not integer(row.slot, 1, 10000)
            or not integer(row.amount, 1, 1000000) or (row.info ~= nil and type(row.info) ~= 'table') then return nil end
        if copy[row.slot] then return nil end
        copy[row.slot] = { item = row.name, quantity = row.amount, info = json.decode(json.encode(row.info or {})) }
    end
    return copy
end

function AINPCAdapters.settleCommerce(source, quote, validate)
    if type(quote) ~= 'table' or type(quote.id) ~= 'string' or #quote.id > 240
        or (quote.kind ~= 'buy' and quote.kind ~= 'sell') or type(quote.items) ~= 'table'
        or #quote.items < 1 or #quote.items > 20 or not integer(quote.total, 1, Config.Security.maximumTransactionValue)
        or type(validate) ~= 'function' then return false, 'invalid_transaction' end
    local driverOk, driver = pcall(driverFor, source)
    if not driverOk or not driver or type(driver.identity) ~= 'string' or #driver.identity > 160 then
        return false, 'commerce_adapter_unavailable'
    end
    local identity = driver.identity
    if busy[identity] then return false, 'transaction_busy' end
    local key = journalPrefix .. identity
    local readOk, previous = pcall(GetResourceKvpString, key)
    if not readOk then return false, 'transaction_storage_unavailable' end
    if previous then
        local decoded, state = pcall(json.decode, previous)
        if not decoded or type(state) ~= 'table' or state.status ~= 'complete' then return false, 'transaction_outcome_unknown' end
        if state.id == quote.id then return state.ok == true, state.reason end
    end
    local function valid()
        return callBoolean(driver.valid) == true and callBoolean(validate) == true
    end
    if not valid() then return false, 'commerce_adapter_lost' end
    local sum, seen = 0, {}
    for _, entry in ipairs(quote.items) do
        if type(entry) ~= 'table' or type(entry.item) ~= 'string' or seen[entry.item]
            or not integer(entry.quantity, 1, 20) or not integer(entry.price, 1, Config.Security.maximumTransactionValue) then
            return false, 'invalid_transaction'
        end
        local ok, item = pcall(driver.item, entry.item)
        if not ok or type(item) ~= 'table' then return false, 'unknown_item' end
        seen[entry.item], sum = true, sum + entry.quantity * entry.price
    end
    if sum ~= quote.total then return false, 'invalid_transaction_value' end
    local state = { id = quote.id, status = 'pending', kind = quote.kind, total = quote.total,
        items = quote.items, at = os.time(), steps = {} }
    busy[identity] = true
    if not persist(key, state) then busy[identity] = nil; return false, 'transaction_storage_unavailable' end
    local function uncertain()
        -- Keep both durable and in-process fences. No automatic refund/retry:
        -- an export may have mutated state before throwing or returning nil.
        print('[peak-ai-npc][commerce] reconciliation_required; transaction fenced')
        return false, 'transaction_outcome_unknown'
    end
    local function finish(ok, reason)
        state.status, state.ok, state.reason = 'complete', ok, reason
        if not persist(key, state) then return uncertain() end
        busy[identity] = nil
        return ok, reason
    end
    local function step(name, fn, ...)
        if not valid() then return nil end
        local arguments = table.pack(...)
        local inventoryMutation = fn == driver.add or fn == driver.remove
        local beforeItems = inventoryMutation and snapshot(driver)
        if inventoryMutation and not beforeItems then return nil end
        state.next = name
        if not persist(key, state) then return nil end
        local result = callBoolean(fn, ...)
        if result == nil then return nil end
        if inventoryMutation then
            local afterItems = snapshot(driver)
            if not afterItems then return nil end
            if result == false then
                if not same(beforeItems, afterItems) then return nil end
            elseif arguments[3] then
                -- Slot-specific removals and rollback grants must affect only
                -- that slot by the exact quantity, preserving all metadata.
                local item, quantity, slot = arguments[1], arguments[2], arguments[3]
                local old = beforeItems[slot]
                if fn == driver.remove then
                    if not old or old.item ~= item or old.quantity < quantity then return nil end
                    old.quantity = old.quantity - quantity
                    if old.quantity == 0 then beforeItems[slot] = nil end
                else
                    local info = arguments[4] or {}
                    if old and (old.item ~= item or not same(old.info, info)) then return nil end
                    beforeItems[slot] = { item = item, quantity = (old and old.quantity or 0) + quantity, info = info }
                end
                if not same(beforeItems, afterItems) then return nil end
            end
        end
        state.steps[#state.steps + 1] = { name = name, ok = result }
        state.next = nil
        if not persist(key, state) then return nil end
        if not valid() then return nil end
        return result
    end
    local rollback = {}
    local function undo(reason)
        for index = #rollback, 1, -1 do
            local entry = rollback[index]
            if step('rollback_' .. entry.name, entry.fn, table.unpack(entry.args, 1, entry.args.n or #entry.args)) ~= true then return uncertain() end
        end
        return finish(false, reason)
    end
    local function execute()
        if quote.kind == 'buy' then
            local cash = driver.cash()
            if not integer(cash, 0, 1000000000) or cash < quote.total then return finish(false, 'insufficient_cash') end
            for _, entry in ipairs(quote.items) do
                if callBoolean(driver.canCarry, entry.item, entry.quantity) ~= true then return finish(false, 'inventory_full') end
            end
            local debited = step('debit', driver.debit, quote.total, quote.id)
            if debited == nil then return uncertain() end
            if not debited then return finish(false, 'payment_failed') end
            rollback[#rollback + 1] = { name = 'credit', fn = driver.credit, args = { quote.total, quote.id } }
            for _, entry in ipairs(quote.items) do
                local before = snapshot(driver)
                if not before then return uncertain() end
                local added = step('add_' .. entry.item, driver.add, entry.item, entry.quantity, nil, nil, quote.id)
                if added == nil then return uncertain() end
                if not added then return undo('item_grant_failed') end
                local after, delta, changed = snapshot(driver), 0, {}
                if not after then return uncertain() end
                for slot, old in pairs(before) do
                    local row = after[slot]
                    if not row or row.item ~= old.item or row.quantity < old.quantity
                        or not same(row.info, old.info) then return uncertain() end
                    if old.item ~= entry.item and row.quantity ~= old.quantity then return uncertain() end
                end
                for slot, row in pairs(after) do
                    if row.item == entry.item then
                        local old = before[slot]
                        if old and old.item ~= row.item then return uncertain() end
                        local amount = row.quantity - (old and old.quantity or 0)
                        if amount < 0 then return uncertain() end
                        if amount > 0 then delta = delta + amount; changed[#changed + 1] = { slot = slot, quantity = amount } end
                    elseif not before[slot] then
                        return uncertain()
                    end
                end
                if delta ~= entry.quantity then return uncertain() end
                for _, change in ipairs(changed) do
                    rollback[#rollback + 1] = { name = 'remove_' .. entry.item, fn = driver.remove,
                        args = { entry.item, change.quantity, change.slot, quote.id } }
                end
            end
        else
            for _, entry in ipairs(quote.items) do
                local items, remaining = snapshot(driver), entry.quantity
                if not items then return uncertain() end
                local available = 0
                for _, row in pairs(items) do if row.item == entry.item then available = available + row.quantity end end
                if available < remaining then return undo('insufficient_items') end
                for slot, row in pairs(items) do
                    if row.item == entry.item and remaining > 0 then
                        local amount = math.min(remaining, row.quantity)
                        local removed = step('remove_' .. entry.item, driver.remove, entry.item, amount, slot, quote.id)
                        if removed == nil then return uncertain() end
                        if not removed then return undo('item_removal_failed') end
                        local after = snapshot(driver)
                        if not after then return uncertain() end
                        local current = after[slot]
                        if row.quantity == amount then
                            if current then return uncertain() end
                        elseif not current or current.item ~= row.item or current.quantity ~= row.quantity - amount
                            or not same(current.info, row.info) then return uncertain() end
                        rollback[#rollback + 1] = { name = 'add_' .. entry.item, fn = driver.add,
                            args = table.pack(entry.item, amount, slot, row.info, quote.id) }
                        remaining = remaining - amount
                    end
                end
            end
            local credited = step('credit', driver.credit, quote.total, quote.id)
            if credited == nil then return uncertain() end
            if not credited then return undo('payout_failed') end
        end
        return finish(true, 'settled')
    end
    local invoked, ok, reason = pcall(execute)
    if not invoked then return uncertain() end
    return ok, reason
end

AddEventHandler('onResourceStop', function(resource)
    generations[resource] = (generations[resource] or 0) + 1
    for name, owner in pairs(owners) do if owner == resource then drivers[name], owners[name] = nil, nil end end
end)
