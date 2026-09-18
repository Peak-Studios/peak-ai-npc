-- One purchase/quote boundary for dialogue and the shop drawer. Network callers
-- never supply prices, stock, a player identity, or a settlement identity.
AINPCCommerce = {}
local rates = {}
local locks = {}
local stores = {}
local serial = 0

local function integer(value, minimum, maximum)
    return type(value) == 'number' and value == value and value % 1 == 0
        and value >= minimum and value <= maximum
end

local function limit()
    local value = Config.Security and Config.Security.maximumTransactionValue
    return integer(value, 1, 100000000) and value or 10000
end

local function throttle(source)
    local now = os.time()
    local rate = rates[source]
    if not rate or now - rate.since >= 60 then rate = { since = now, count = 0 }; rates[source] = rate end
    rate.count = rate.count + 1
    return rate.count <= 30
end

local function shopBinding(session)
    local npc = session.npc
    local entities = AINPCServerEntities
    if type(entities) ~= 'table' or type(entities.records) ~= 'table' then
        return nil, nil, 'shop_entity_unavailable'
    end
    local record = entities.records[npc.id]
    if session.entity and session.entity ~= 0 then
        if npc.localEntity or not DoesEntityExist(session.entity) then
            return nil, nil, 'network_entity_required'
        end
        if not record or record.ped ~= session.entity then
            return nil, nil, 'shop_entity_unavailable'
        end
        return record, 'network'
    end
    -- Authored NPCs may deliberately use a client-rendered ped when FXServer
    -- cannot obtain a usable OneSync network ID. Only the server-owned fallback
    -- marker plus the exact configured definition can authorize commerce; a
    -- client-local ambient/resident ped never can.
    local fallback = type(entities.fallbacks) == 'table' and entities.fallbacks[npc.id] or nil
    if npc.localEntity or record or type(AINPCDefinitions) ~= 'table'
        or AINPCDefinitions[npc.id] ~= npc or type(fallback) ~= 'string' or fallback == '' then
        return nil, nil, 'network_entity_required'
    end
    return fallback, 'authored_fallback'
end

function AINPCCommerce.validate(source, session)
    local valid, reason = AINPCSessions.valid(source, session)
    if not valid then return false, reason end
    local npc = session.npc
    if type(npc.shop) ~= 'table' or npc.enabled == false then return false, 'shop_unavailable' end
    if npc.medical and (not Config.Medical or Config.Medical.enabled ~= true) then return false, 'medical_disabled' end
    local binding, bindingKind, bindingReason = shopBinding(session)
    if not binding then return false, bindingReason end
    if bindingKind == 'network' and GetPlayerRoutingBucket(source) ~= GetEntityRoutingBucket(session.entity) then
        return false, 'npc_not_in_bucket'
    end
    local distance = tonumber(npc.interactionDistance) or Config.Conversations.interactionDistance or 3
    local npcCoords = bindingKind == 'network' and GetEntityCoords(session.entity)
        or vec3(npc.coords.x, npc.coords.y, npc.coords.z)
    if #(GetEntityCoords(GetPlayerPed(source)) - npcCoords) > math.min(distance, 5) then
        return false, 'too_far'
    end
    return true, nil, binding, bindingKind
end

function AINPCCommerce.catalog(source, session)
    local valid, reason = AINPCCommerce.validate(source, session)
    if not valid then return nil, reason end
    if not AINPCAdapters.commerceIdentity(source) then return nil, 'commerce_adapter_unavailable' end
    local shop, catalog = session.npc.shop, {}
    if type(shop.id) ~= 'string' or #shop.id < 1 or #shop.id > 96 then return nil, 'invalid_catalog' end
    local configured = shop.catalog or shop.items
    if type(configured) ~= 'table' then return nil, 'catalog_unavailable' end
    local count = 0
    for key, value in pairs(configured) do
        if type(value) ~= 'table' then return nil, 'invalid_catalog' end
        local item = value.item or value.name or key
        if type(item) ~= 'string' or #item > 64 or not item:match('^[%w_%-]+$')
            or catalog[item] or not integer(value.price, 1, limit())
            or (value.buyPrice ~= nil and not integer(value.buyPrice, 1, limit()))
            or (value.maximumQuantity ~= nil and not integer(value.maximumQuantity, 1, 20))
            or (value.cooldownSeconds ~= nil and not integer(value.cooldownSeconds, 0, 86400))
            or (value.cooldownKey ~= nil and (type(value.cooldownKey) ~= 'string' or #value.cooldownKey > 128 or not value.cooldownKey:match('^[%w_:%-]+$'))) then
            return nil, 'invalid_catalog'
        end
        -- An owner configuration is not proof that an inventory item exists.
        if AINPCAdapters.knownItem(source, item) then
            catalog[item] = { label = type(value.label) == 'string' and value.label:sub(1, 96) or item,
                price = value.price, buyPrice = value.buyPrice, maximumQuantity = value.maximumQuantity or 20,
                cooldownSeconds = value.cooldownSeconds or 0, cooldownKey = value.cooldownKey or (shop.id .. ':' .. item),
                category = type(value.category) == 'string' and value.category:sub(1, 48) or 'general',
                description = type(value.description) == 'string' and value.description:sub(1, 256) or '' }
        end
        count = count + 1
        if count > 256 then return nil, 'catalog_limit' end
    end
    return catalog
end

local function cooldowns(identity)
    local key = 'ainpc:purchase-cooldown:v1:' .. identity
    local ok, raw = pcall(GetResourceKvpString, key)
    if not ok then return nil end
    if not raw then return {} end
    local decoded, values = pcall(json.decode, raw)
    if not decoded or type(values) ~= 'table' then return nil end
    local result, count = {}, 0
    for name, expires in pairs(values) do
        if type(name) ~= 'string' or not integer(expires, 0, 9007199254740991) then return nil end
        if expires > os.time() then result[name] = expires; count = count + 1 end
    end
    if count > 1024 then return nil end
    return result
end

local function saveCooldowns(identity, values)
    local ok, encoded = pcall(json.encode, values)
    if not ok then return false end
    local key = 'ainpc:purchase-cooldown:v1:' .. identity
    local written = pcall(SetResourceKvp, key, encoded)
    local read, actual = pcall(GetResourceKvpString, key)
    return written and read and actual == encoded
end

local function persistStock(session, state)
    local key = 'ainpc:stock:v1:' .. session.npc.id .. ':' .. session.npc.shop.id
    local ok, encoded = pcall(json.encode, state)
    if not ok then return false end
    local writeOk = pcall(SetResourceKvp, key, encoded)
    local readOk, value = pcall(GetResourceKvpString, key)
    return writeOk and readOk and value == encoded
end

local function stockFor(session, catalog)
    local shop = session.npc.shop
    if type(shop.id) ~= 'string' or #shop.id < 1 or #shop.id > 96 then return nil end
    if not stores[shop] then
        local ok, stored = pcall(GetResourceKvpString, 'ainpc:stock:v1:' .. session.npc.id .. ':' .. shop.id)
        if not ok then return nil end
        if stored then
            local decoded, value = pcall(json.decode, stored)
            if not decoded or type(value) ~= 'table' or type(value.stock) ~= 'table' then return nil end
            stores[shop] = value
            shop.stock = value.stock
            if value.pending then locks[shop] = true end
        else
            stores[shop] = { stock = shop.stock or {} }
            shop.stock = stores[shop].stock
        end
    end
    if shop.stock == nil then shop.stock = {} end
    if type(shop.stock) ~= 'table' then return nil end
    for item in pairs(catalog) do
        if shop.stock[item] == nil then shop.stock[item] = shop.defaultStock or 50 end
        if not integer(shop.stock[item], 0, 1000000) then return nil end
    end
    return shop.stock
end

function AINPCCommerce.stock(source, session)
    local catalog, reason = AINPCCommerce.catalog(source, session)
    if not catalog then return nil, reason end
    local stock = stockFor(session, catalog)
    if not stock then return nil, 'invalid_stock' end
    local visible = {}
    for item in pairs(catalog) do visible[item] = stock[item] end
    return visible
end

function AINPCCommerce.quote(source, session, args, kind)
    if not throttle(source) then return false, 'shop_rate_limit' end
    if kind ~= nil and kind ~= 'buy' and kind ~= 'sell' then return false, 'invalid_transaction_kind' end
    local catalog, reason = AINPCCommerce.catalog(source, session)
    if not catalog then return false, reason end
    if session.commerceBusy then return false, 'transaction_busy' end
    if type(args) ~= 'table' then return false, 'invalid_purchase_items' end
    local requested = args.items or { { item = args.item, quantity = args.quantity } }
    if type(requested) ~= 'table' or #requested < 1 or #requested > 20 then return false, 'invalid_purchase_items' end
    local quantities, count = {}, 0
    for index, entry in pairs(requested) do
        if not integer(index, 1, #requested) or type(entry) ~= 'table' or type(entry.item) ~= 'string'
            or not catalog[entry.item] or not integer(entry.quantity, 1, 20) then return false, 'invalid_purchase_items' end
        quantities[entry.item] = (quantities[entry.item] or 0) + entry.quantity
        if quantities[entry.item] > 20 then return false, 'invalid_purchase_quantity' end
        count = count + 1
    end
    if count ~= #requested then return false, 'invalid_purchase_items' end
    local stock = stockFor(session, catalog)
    if not stock then return false, 'invalid_stock' end
    local identity = AINPCAdapters.commerceIdentity(source)
    if not identity then return false, 'commerce_adapter_unavailable' end
    local activeCooldowns = cooldowns(identity)
    if not activeCooldowns then return false, 'transaction_storage_unavailable' end
    local items, total = {}, 0
    for item, quantity in pairs(quantities) do
        if quantity > catalog[item].maximumQuantity then return false, 'invalid_purchase_quantity' end
        if (activeCooldowns[catalog[item].cooldownKey] or 0) > os.time() then return false, 'item_cooldown_active' end
        local price = catalog[item].price
        if kind == 'sell' then price = catalog[item].buyPrice end
        if not integer(price, 1, limit()) then return false, 'item_not_purchased_by_shop' end
        if kind ~= 'sell' and stock[item] < quantity then return false, 'out_of_stock' end
        total = total + price * quantity
        items[#items + 1] = { item = item, quantity = quantity, price = price, label = catalog[item].label,
            cooldownKey = catalog[item].cooldownKey, cooldownSeconds = catalog[item].cooldownSeconds }
    end
    if not integer(total, 1, limit()) then return false, 'transaction_limit' end
    table.sort(items, function(a, b) return a.item < b.item end)
    local valid, bindingReason, binding, bindingKind = AINPCCommerce.validate(source, session)
    if not valid then return false, bindingReason end
    serial = serial + 1
    local quote = { id = ('%s:q:%d'):format(session.id, serial), kind = kind == 'sell' and 'sell' or 'buy',
        items = items, item = items[1].item, quantity = items[1].quantity, total = total,
        ok = true, revision = session.revision, expiresAt = os.time() + 30, entity = session.entity,
        shopId = session.npc.shop.id, identity = identity, entityBinding = binding,
        entityBindingKind = bindingKind, requiresConfirmation = true }
    session.pendingQuote, session.purchaseConfirmed = quote, false
    return true, { ok = true, id = quote.id, kind = quote.kind, items = quote.items, item = quote.item,
        quantity = quote.quantity, total = quote.total, expiresAt = quote.expiresAt, requiresConfirmation = true }
end

function AINPCCommerce.confirm(source, session, quoteId)
    if not throttle(source) then return false, 'shop_rate_limit' end
    local valid, reason, binding, bindingKind = AINPCCommerce.validate(source, session)
    if not valid then return false, reason end
    if type(quoteId) ~= 'string' or #quoteId > 240 then return false, 'invalid_quote' end
    local cached = session.commerceReceipts and session.commerceReceipts[quoteId]
    if cached then
        if cached.identity ~= AINPCAdapters.commerceIdentity(source) then return false, 'character_changed' end
        return cached.ok, cached.result
    end
    local quote = session.pendingQuote
    if not quote or quote.id ~= quoteId or quote.revision ~= session.revision or quote.entity ~= session.entity
        or quote.shopId ~= session.npc.shop.id or quote.expiresAt < os.time() then return false, 'stale_quote' end
    if quote.entityBinding ~= binding or quote.entityBindingKind ~= bindingKind then return false, 'shop_entity_changed' end
    if AINPCAdapters.commerceIdentity(source) ~= quote.identity then return false, 'character_changed' end
    if session.purchaseConfirmed ~= quote.id then return false, 'purchase_confirmation_required' end
    local shop = session.npc.shop
    if locks[shop] or session.commerceBusy then return false, 'transaction_busy' end
    local catalog, catalogReason = AINPCCommerce.catalog(source, session)
    if not catalog then return false, catalogReason end
    local stock = stockFor(session, catalog)
    if not stock then return false, 'invalid_stock' end
    if locks[shop] then return false, 'transaction_outcome_unknown' end
    local total = 0
    local activeCooldowns = cooldowns(quote.identity)
    if not activeCooldowns then return false, 'transaction_storage_unavailable' end
    local priorCooldowns = {}
    for key, value in pairs(activeCooldowns) do priorCooldowns[key] = value end
    for _, entry in ipairs(quote.items) do
        local row = catalog[entry.item]
        local price = row and row.price
        if row and quote.kind == 'sell' then price = row.buyPrice end
        if not row or price ~= entry.price or not integer(entry.quantity, 1, row.maximumQuantity)
            or row.cooldownKey ~= entry.cooldownKey or row.cooldownSeconds ~= entry.cooldownSeconds then return false, 'catalog_changed' end
        if (activeCooldowns[row.cooldownKey] or 0) > os.time() then return false, 'item_cooldown_active' end
        if row.cooldownSeconds > 0 then activeCooldowns[row.cooldownKey] = os.time() + row.cooldownSeconds end
        if quote.kind == 'buy' and stock[entry.item] < entry.quantity then return false, 'out_of_stock' end
        if quote.kind == 'sell' and stock[entry.item] + entry.quantity > 1000000 then return false, 'stock_limit' end
        total = total + price * entry.quantity
    end
    if total ~= quote.total or not integer(total, 1, limit()) then return false, 'invalid_transaction_value' end
    locks[shop], session.commerceBusy = true, true
    -- Consume authorization before any adapter can yield, error, or re-enter.
    session.pendingQuote, session.purchaseConfirmed = nil, false
    if not saveCooldowns(quote.identity, activeCooldowns) then
        session.commerceBusy = false
        return false, 'transaction_outcome_unknown'
    end
    local store = stores[shop]
    store.pending = quote.id
    if quote.kind == 'buy' then
        for _, entry in ipairs(quote.items) do stock[entry.item] = stock[entry.item] - entry.quantity end
    end
    if not persistStock(session, store) then
        session.commerceBusy = false
        return false, 'transaction_outcome_unknown'
    end
    local invoked, ok, result = pcall(AINPCAdapters.settleCommerce, source, quote, function()
        local current, _, currentBinding, currentKind = AINPCCommerce.validate(source, session)
        return current and AINPCAdapters.commerceIdentity(source) == quote.identity
            and quote.entityBinding == currentBinding and quote.entityBindingKind == currentKind
    end)
    if not invoked then ok, result = false, 'transaction_outcome_unknown' end
    if ok then
        for _, entry in ipairs(quote.items) do
            if quote.kind == 'sell' then stock[entry.item] = stock[entry.item] + entry.quantity end
        end
        result = { ok = true, quoteId = quote.id, items = quote.items, item = quote.item,
            quantity = quote.quantity, total = quote.total, kind = quote.kind }
    elseif result ~= 'transaction_outcome_unknown' and quote.kind == 'buy' then
        for _, entry in ipairs(quote.items) do stock[entry.item] = stock[entry.item] + entry.quantity end
    end
    if result ~= 'transaction_outcome_unknown' then
        if not ok and not saveCooldowns(quote.identity, priorCooldowns) then result = 'transaction_outcome_unknown' end
        if result ~= 'transaction_outcome_unknown' then
            store.pending = nil
            if not persistStock(session, store) then ok, result = false, 'transaction_outcome_unknown' end
        end
    end
    session.commerceReceipts = session.commerceReceipts or {}
    session.commerceReceipts[quote.id] = { ok = ok == true, result = result, identity = quote.identity }
    -- An uncertain adapter outcome keeps the shop fenced for operator review.
    if result ~= 'transaction_outcome_unknown' then locks[shop] = nil end
    session.commerceBusy = false
    print(('[peak-ai-npc][commerce] receipt=%s kind=%s ok=%s result=%s'):format(tostring(joaat(quote.id)), quote.kind, tostring(ok == true), ok and 'settled' or tostring(result)))
    return ok == true, result
end

function AINPCCommerce.request(source, data)
    if type(data) ~= 'table' or type(data.sessionId) ~= 'string' or not integer(data.sessionRevision, 1, 2147483647) then
        return nil, 'invalid_session'
    end
    local session = AINPCSessions.get(source)
    if not session or session.id ~= data.sessionId or session.revision ~= data.sessionRevision or session.busy then
        return nil, 'stale_session'
    end
    local valid, reason = AINPCCommerce.validate(source, session)
    if not valid then return nil, reason end
    return session
end

AddEventHandler('playerDropped', function() rates[source] = nil end)
