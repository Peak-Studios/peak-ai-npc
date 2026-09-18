-- Inventory-specific API translation. Settlement, authorization, journaling and
-- rollback remain in economy.lua; no driver may confirm a model proposal.
AINPCCommerceDrivers = {}

local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for key, value in pairs(a) do if not same(value, b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end

local function integer(value, minimum, maximum)
    return type(value) == 'number' and value == value and value % 1 == 0 and value >= minimum and value <= maximum
end

local function moneyDriver(source, framework)
    local adapter = AINPCAdapters.framework()
    local player = adapter.getPlayer(source)
    local character = player and adapter.getCharacterId(player)
    if type(character) ~= 'string' or #character < 1 or #character > 128 then return nil end
    local driver = { identity = framework .. ':' .. character }
    local function current()
        local value = adapter.getPlayer(source)
        if value and adapter.getCharacterId(value) == character then return value end
    end
    driver.valid = function() return current() ~= nil end
    if framework == 'qbox' then
        driver.cash = function() return exports.qbx_core:GetMoney(source, 'cash') end
        driver.debit = function(amount, id) return exports.qbx_core:RemoveMoney(source, 'cash', amount, id) end
        driver.credit = function(amount, id) return exports.qbx_core:AddMoney(source, 'cash', amount, id) end
    elseif framework == 'esx' then
        driver.cash = function() return current().getMoney() end
        driver.debit = function(amount, id)
            local value = current()
            local balance = value and value.getMoney()
            if not integer(balance, 0, 1000000000) or balance < amount then return false end
            return value.removeMoney(amount, id)
        end
        driver.credit = function(amount, id) return current().addMoney(amount, id) end
    elseif framework == 'qbcore' or framework == 'fw-core' then
        driver.cash = function() return current().Functions.GetMoney('cash') end
        driver.debit = function(amount, id) return current().Functions.RemoveMoney('cash', amount, id) end
        driver.credit = function(amount, id) return current().Functions.AddMoney('cash', amount, id) end
    else
        return nil
    end
    return driver, current
end

local function oxInventory(driver, source)
    driver.item = function(item) return exports.ox_inventory:Items(item) end
    driver.canCarry = function(item, quantity) return exports.ox_inventory:CanCarryItem(source, item, quantity) end
    driver.items = function()
        local slots = exports.ox_inventory:GetInventoryItems(source)
        if type(slots) ~= 'table' then return nil end
        local result = {}
        for key, row in pairs(slots) do
            if type(row) ~= 'table' then return nil end
            result[key] = { name = row.name, amount = row.count, slot = row.slot, info = row.metadata or {} }
        end
        return result
    end
    driver.add = function(item, quantity, slot, info)
        if exports.ox_inventory:CanCarryItem(source, item, quantity, info) ~= true then return false end
        if slot then
            local slots = exports.ox_inventory:GetInventoryItems(source)
            if type(slots) ~= 'table' then return nil end
            local existing = slots[slot]
            -- Ox may pick another slot when the requested one cannot stack.
            -- A rollback must preserve the exact slot and metadata instead.
            local definition = driver.item(item)
            if existing and (existing.name ~= item or not definition or definition.stack ~= true
                or not same(existing.metadata or {}, info or {})) then return false end
        end
        return exports.ox_inventory:AddItem(source, item, quantity, info, slot)
    end
    driver.remove = function(item, quantity, slot)
        local slots = exports.ox_inventory:GetInventoryItems(source)
        local row = type(slots) == 'table' and slots[slot]
        if not row or row.name ~= item or not integer(row.count, quantity, 1000000) then return false end
        return exports.ox_inventory:RemoveItem(source, item, quantity, row.metadata or {}, slot, false, true)
    end
    return driver
end

local function esxInventory(driver, current)
    local core = exports.es_extended:getSharedObject()
    if not core or type(core.Items) ~= 'table' then return nil end
    -- Stock ESX has counts, not physical slots or arbitrary item metadata.
    -- Assign stable per-operation synthetic slots from the complete item list.
    local names, slots = {}, {}
    for name in pairs(core.Items) do names[#names + 1] = name end
    table.sort(names)
    for slot, name in ipairs(names) do slots[name] = slot end
    driver.item = function(item) return core.Items[item] end
    driver.canCarry = function(item, quantity) return current().canCarryItem(item, quantity) end
    driver.items = function()
        local inventory = current().getInventory()
        if type(inventory) ~= 'table' then return nil end
        local result, seen = {}, {}
        for _, row in pairs(inventory) do
            if type(row) ~= 'table' or not slots[row.name] or seen[row.name]
                or not integer(row.count, 0, 1000000) or row.metadata ~= nil or row.info ~= nil then return nil end
            seen[row.name] = true
            if row.count > 0 then result[#result + 1] = { name = row.name, amount = row.count, slot = slots[row.name], info = {} } end
        end
        return result
    end
    driver.add = function(item, quantity, slot, info)
        if (slot and slot ~= slots[item]) or (info and next(info)) then return false end
        local value = current()
        if value.canCarryItem(item, quantity) ~= true then return false end
        return value.addInventoryItem(item, quantity)
    end
    driver.remove = function(item, quantity, slot)
        if slot ~= slots[item] then return false end
        local value = current()
        local row = value.getInventoryItem(item)
        if not row or not integer(row.count, quantity, 1000000) then return false end
        return value.removeInventoryItem(item, quantity)
    end
    return driver
end

local function fwInventory(driver, source, current)
    local function ready()
        local capabilities = exports['fw-inventory']:GetAINPCCommerceCapabilities()
        return type(capabilities) == 'table' and capabilities.version == 1 and capabilities.strictCapacity == true
            and capabilities.exactSlots == true and capabilities.preservesCreationTime == true
    end
    if not ready() then return nil end
    local valid = driver.valid
    driver.valid = function() return valid() and ready() end
    driver.item = function(item) return exports['fw-inventory']:GetItemData(item) end
    driver.canCarry = function(item, quantity) return exports['fw-inventory']:CanCarryAINPCItem(source, item, quantity) end
    driver.items = function()
        local player = current()
        local inventory = player and player.PlayerData and player.PlayerData.inventory
        if type(inventory) ~= 'table' then return nil end
        local result = {}
        for key, row in pairs(inventory) do
            if key ~= 0 or row ~= false then
                if type(row) ~= 'table' or type(row.Info) ~= 'table' or type(row.CustomType) ~= 'string'
                    or not integer(row.CreateDate, 0, 10000000000000) then return nil end
                result[key] = { name = row.Item, amount = row.Amount, slot = row.Slot,
                    info = { info = row.Info, customType = row.CustomType, createdAt = row.CreateDate } }
            end
        end
        return result
    end
    driver.add = function(item, quantity, slot, info)
        return exports['fw-inventory']:AddAINPCItem(source, item, quantity, slot, info)
    end
    driver.remove = function(item, quantity, slot)
        return exports['fw-inventory']:RemoveAINPCItem(source, item, quantity, slot)
    end
    return driver
end

function AINPCCommerceDrivers.create(source, framework, inventory)
    if inventory == 'ox_inventory' and (framework == 'qbox' or framework == 'qbcore' or framework == 'esx') then
        local driver = moneyDriver(source, framework)
        return driver and oxInventory(driver, source)
    end
    if framework == 'esx' and inventory == 'esx-native' and GetResourceState('ox_inventory') ~= 'started' then
        local driver, current = moneyDriver(source, framework)
        return driver and esxInventory(driver, current)
    end
    if framework == 'fw-core' and inventory == 'fw-inventory' then
        local driver, current = moneyDriver(source, framework)
        return driver and fwInventory(driver, source, current)
    end
end
