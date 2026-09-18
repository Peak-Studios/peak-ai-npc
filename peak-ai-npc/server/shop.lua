local catalogRates = {}

local function reply(source, session, ok, result, requestId)
    TriggerClientEvent('peak_ai_npc:client:shopResult', source, {
        sessionId = session and session.id, sessionRevision = session and session.revision,
        ok = ok == true, result = result, requestId = requestId, cash = AINPCAdapters.commerceCash(source)
    })
end

RegisterNetEvent('peak_ai_npc:server:requestShopCatalog', function(data)
    local src = source
    if type(data) ~= 'table' or type(data.requestId) ~= 'string' or #data.requestId > 64 then return end
    local now = os.time()
    if catalogRates[src] and now - catalogRates[src] < 2 then return end
    catalogRates[src] = now
    local session, reason = AINPCCommerce.request(src, data)
    if not session then reply(src, nil, false, reason); return end
    local catalog, catalogReason = AINPCCommerce.catalog(src, session)
    if not catalog then reply(src, session, false, catalogReason); return end
    local stock, stockReason = AINPCCommerce.stock(src, session)
    if not stock then reply(src, session, false, stockReason); return end
    local items = {}
    for item, value in pairs(catalog) do
        items[#items + 1] = { item = item, label = value.label, price = value.price,
            buyPrice = value.buyPrice, category = value.category, description = value.description, stock = stock[item],
            maximumQuantity = value.maximumQuantity, cooldownSeconds = value.cooldownSeconds }
    end
    table.sort(items, function(a, b) return a.item < b.item end)
    TriggerClientEvent('peak_ai_npc:client:showShopCatalog', src, {
        sessionId = session.id, sessionRevision = session.revision, npcId = session.npc.id,
        requestId = data.requestId,
        shopName = session.npc.shop.label or 'Store', occupation = session.npc.identity and session.npc.identity.occupation,
        items = items, cash = AINPCAdapters.commerceCash(src)
    })
end)

RegisterNetEvent('peak_ai_npc:server:quoteShopItem', function(data)
    local src = source
    if type(data) ~= 'table' or type(data.requestId) ~= 'string' or #data.requestId > 64 then return end
    local session, reason = AINPCCommerce.request(src, data)
    if not session then reply(src, nil, false, reason, data.requestId); return end
    local ok, result = AINPCCommerce.quote(src, session, { item = data.item, quantity = data.quantity }, data.kind)
    reply(src, session, ok, result, data.requestId)
end)

RegisterNetEvent('peak_ai_npc:server:buyShopItem', function(data)
    local src = source
    if type(data) ~= 'table' or type(data.requestId) ~= 'string' or #data.requestId > 64 then return end
    local session, reason = AINPCCommerce.request(src, data)
    if not session then reply(src, nil, false, reason, data.requestId); return end
    if session.pendingQuote and session.pendingQuote.id == data.quoteId then session.purchaseConfirmed = data.quoteId end
    local ok, result = AINPCCommerce.confirm(src, session, data.quoteId)
    reply(src, session, ok, result, data.requestId)
end)

AddEventHandler('playerDropped', function() catalogRates[source] = nil end)
