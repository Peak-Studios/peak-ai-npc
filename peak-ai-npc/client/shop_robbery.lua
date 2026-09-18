-- Armed aim is a client-observed trigger only. The server independently owns
-- firearm ownership, player/shop distance, police count, routing bucket,
-- response selection, cooldown, completion timing, and every reward.
local heldSince = {}
local reported = {}
local activeProgressToken

local function managedShopkeeper(entity)
    for id, ped in pairs(AINPCClientEntities or {}) do
        local definition = AINPCDefinitions and AINPCDefinitions[id]
        if ped == entity and definition and definition.shop and definition.shop.robbery
            and definition.shop.robbery.enabled ~= false then
            return { key = 'managed:' .. id, kind = 'managed', npcId = id }
        end
    end
    return nil
end

local function qbShopkeeper(entity)
    if GetResourceState('qb-shops') ~= 'started' then return nil end
    local ok, shopId = pcall(function() return exports['qb-shops']:ResolveRobbableShopPed(entity) end)
    if not ok or type(shopId) ~= 'string' or not shopId:match('^[%w_%-]+$') then return nil end
    return { key = 'qb_shop:' .. shopId, kind = 'qb_shop', shopId = shopId }
end

local function aimedShopkeeper()
    if not Config.ShopRobbery.enabled or not IsPlayerFreeAiming(PlayerId()) then return nil end
    local aiming, entity = GetEntityPlayerIsFreeAimingAt(PlayerId())
    if not aiming or not entity or entity == 0 or not IsPed(entity) then return nil end
    if not IsPedArmed(PlayerPedId(), 4) then return nil end
    return managedShopkeeper(entity) or qbShopkeeper(entity)
end

local function applyReaction(payload)
    if type(payload) ~= 'table' or type(payload.kind) ~= 'string'
        or type(payload.reactionId) ~= 'string' or #payload.reactionId > 80 then return end
    if payload.kind == 'qb_shop' then
        if type(payload.shopId) ~= 'string' or GetResourceState('qb-shops') ~= 'started' then return end
        if payload.reset == true then
            pcall(function() exports['qb-shops']:ResetRobberyReaction(payload.shopId, payload.reactionId) end)
            return
        end
        pcall(function()
            exports['qb-shops']:ApplyRobberyReaction(
                payload.shopId,
                payload.reactionId,
                payload.response,
                payload.weapon,
                payload.robberSource,
                payload.durationMs
            )
        end)
    elseif payload.kind == 'managed' and type(payload.npcId) == 'string' then
        if payload.reset == true then
            if AINPCCancelActions then AINPCCancelActions(payload.npcId) end
            return
        end
        TriggerEvent(AINPC.Event.Action, payload.npcId, 'shop_robbery', {
            response = payload.response,
            weapon = payload.weapon,
            line = payload.line,
            durationMs = payload.durationMs,
            reactionId = payload.reactionId,
            robberSource = payload.robberSource
        })
    end
    if payload.reset ~= true and type(payload.line) == 'string' then
        TriggerEvent('peak_ai_npc:client:notify', payload.line)
    end
end

RegisterNetEvent(AINPC.Event.ShopRobberyReaction, applyReaction)

RegisterNetEvent(AINPC.Event.ShopRobberyProgress, function(payload)
    if type(payload) ~= 'table' or type(payload.token) ~= 'string' or #payload.token < 8 or #payload.token > 160
        or type(payload.durationMs) ~= 'number' or payload.durationMs < 1000 or payload.durationMs > 60000 then return end
    if activeProgressToken then return end
    activeProgressToken = payload.token
    if GetResourceState('qb-core') ~= 'started' then
        activeProgressToken = nil
        TriggerServerEvent(AINPC.Event.ShopRobberyComplete, payload.token, false)
        return
    end
    local QBCore = exports['qb-core']:GetCoreObject({ 'Functions' })
    QBCore.Functions.Progressbar(
        'peak_ai_npc_clerk_robbery',
        ('Emptying %s register'):format(tostring(payload.label or 'the')),
        math.floor(payload.durationMs),
        false,
        true,
        {
            disableMovement = true,
            disableCarMovement = true,
            disableMouse = false,
            disableCombat = true
        },
        {
            animDict = 'veh@break_in@0h@p_m_one@',
            anim = 'low_force_entry_ds',
            flags = 16
        },
        {},
        {},
        function()
            if activeProgressToken ~= payload.token then return end
            activeProgressToken = nil
            ClearPedTasks(PlayerPedId())
            TriggerServerEvent(AINPC.Event.ShopRobberyComplete, payload.token, true)
        end,
        function()
            if activeProgressToken ~= payload.token then return end
            activeProgressToken = nil
            ClearPedTasks(PlayerPedId())
            TriggerServerEvent(AINPC.Event.ShopRobberyComplete, payload.token, false)
        end
    )
end)

RegisterNetEvent(AINPC.Event.ShopRobberyResult, function(ok, reason, result)
    if ok and type(result) == 'table' then
        TriggerEvent('peak_ai_npc:client:notify', ('You took %s marked bill bag(s) from the register.'):format(tostring(result.bags or 0)))
        return
    end
    local messages = {
        inventory_full = 'Your inventory cannot hold the register money.',
        completion_too_early = 'The register is not open yet.',
        completion_expired = 'The robbery opportunity expired.',
        routing_bucket_changed = 'The robbery was cancelled when you left the instance.',
        too_far = 'You moved too far away from the clerk.',
        cancelled = 'You stopped emptying the register.'
    }
    TriggerEvent('peak_ai_npc:client:notify', messages[reason] or 'The register robbery was cancelled.')
end)

CreateThread(function()
    while true do
        Wait(Config.ShopRobbery.checkIntervalMs or 250)
        local target = aimedShopkeeper()
        local key = target and target.key
        local now = GetGameTimer()
        if target then
            heldSince[key] = heldSince[key] or now
            if not reported[key] and now - heldSince[key] >= (Config.ShopRobbery.triggerHoldMs or 900) then
                reported[key] = true
                TriggerServerEvent(AINPC.Event.ShopThreat, {
                    kind = target.kind,
                    npcId = target.npcId,
                    shopId = target.shopId
                })
            end
        end
        for knownKey in pairs(heldSince) do
            if knownKey ~= key then
                heldSince[knownKey] = nil
                reported[knownKey] = nil
            end
        end
    end
end)
