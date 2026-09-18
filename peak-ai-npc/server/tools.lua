AINPCTools = {}
local registry = {}
local registryOwners = {}
local function catalogFor(session)
    return AINPCCommerce.catalog(session.source, session)
end

local function stockFor(session)
    return AINPCCommerce.stock(session.source, session)
end

local function numberInRange(value, min, max)
    return type(value) == 'number' and value % 1 == 0 and value >= min and value <= max
end

local function finiteNumber(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function npcPosition(session)
    if session.entity and session.entity ~= 0 and DoesEntityExist(session.entity) then return GetEntityCoords(session.entity) end
    local coords = session.npc.coords
    return coords and vec3(coords.x, coords.y, coords.z) or nil
end

local function triggerNpcAction(source, session, action, payload)
    local valid, reason = AINPCSessions.valid(source, session)
    if not valid then return { ok = false, reason = reason } end
    if session.phase ~= 'deliberating' then return { ok = false, reason = 'action_phase_invalid' } end
    local ped = session.entity
    if not ped or ped == 0 or not DoesEntityExist(ped) or session.npc.localEntity then
        return { ok = false, reason = 'network_entity_required' }
    end
    local ownerOk, owner = pcall(NetworkGetEntityOwner, ped)
    if not ownerOk or type(owner) ~= 'number' or owner <= 0 then return { ok = false, reason = 'entity_owner_unavailable' } end
    if GetPlayerRoutingBucket(source) ~= GetEntityRoutingBucket(ped) or GetPlayerRoutingBucket(owner) ~= GetEntityRoutingBucket(ped) then
        return { ok = false, reason = 'entity_owner_out_of_scope' }
    end
    session.actionSequence = (session.actionSequence or 0) + 1
    local actionId = ('%s:a:%s:%s'):format(session.id, session.revision, session.actionSequence)
    local actionPayload = type(payload) == 'table' and payload or {}
    actionPayload.actionId = actionId
    actionPayload.sessionRevision = session.revision
    actionPayload.turnId = session.turnId
    actionPayload.entityNetId = NetworkGetNetworkIdFromEntity(ped)
    actionPayload.ownerServerId = owner
    actionPayload.targetServerId = source
    session.pendingActions[actionId] = {
        id = actionId, action = action, owner = owner, revision = session.revision,
        entity = ped, createdAt = GetGameTimer(), started = false, payload = actionPayload
    }
    if AINPCBehavior then
        AINPCBehavior.push(source, session, { mode = action == 'flee' and 'flee' or action == 'surrender' and 'surrender' or action == 'follow' and 'face' or 'idle', facial = action == 'flee' and 'stressed' or 'neutral', priority = (action == 'flee' or action == 'surrender' or action == 'shop_robbery') and 100 or 80, targetServerId = source, durationMs = 15000, reason = 'action:' .. action })
    end
    AINPCSessions.transition(session, 'action_pending', { sessionRevision = session.revision })
    TriggerClientEvent(AINPC.Event.Action, owner, session.npc.id, action, actionPayload)
    local function trackOwner()
        local pending = session.pendingActions and session.pendingActions[actionId]
        if not pending or pending.started or GetGameTimer() - pending.createdAt >= 15000 or not DoesEntityExist(ped) then return end
        local currentOk, currentOwner = pcall(NetworkGetEntityOwner, ped)
        if currentOk and type(currentOwner) == 'number' and currentOwner > 0 and currentOwner ~= pending.owner
            and GetPlayerRoutingBucket(currentOwner) == GetEntityRoutingBucket(ped) then
            pending.owner = currentOwner
            pending.payload.ownerServerId = currentOwner
            TriggerClientEvent(AINPC.Event.Action, currentOwner, session.npc.id, action, pending.payload)
        end
        SetTimeout(500, trackOwner)
    end
    SetTimeout(500, trackOwner)
    return { pending = true, action = action, actionId = actionId, ownerServerId = owner }
end

function AINPCTools.register(name, definition)
    if type(name) ~= 'string' or #name < 1 or #name > 64 or not name:match('^[%w_%-]+$') or type(definition) ~= 'table' or type(definition.execute) ~= 'function' then
        return false, 'invalid_tool_definition'
    end
    local owner = GetInvokingResource() or GetCurrentResourceName()
    if registry[name] and registryOwners[name] ~= owner then return false, 'tool_already_registered' end
    registry[name] = definition
    registryOwners[name] = owner
    return true
end

function AINPCTools.allowed(npc, name)
    for _, allowed in ipairs(npc.allowedTools or {}) do if allowed == name then return registry[name] end end
    return nil
end

function AINPCTools.schemas(npc)
    local schemas = {}
    for _, name in ipairs(npc.allowedTools or {}) do
        local tool = registry[name]
        if tool and type(tool.description) == 'string' and type(tool.parameters) == 'table' then
            schemas[name] = { description = tool.description, parameters = tool.parameters }
        end
    end
    return schemas
end

function AINPCTools.execute(source, session, name, args, invocationId)
    local valid, invalidReason = AINPCSessions.valid(source, session)
    if not valid then return false, invalidReason end
    session.toolResults = session.toolResults or {}
    local tool = AINPCTools.allowed(session.npc, name)
    local function audit(ok, reason)
        if Config.Security.auditWriteTools and tool and tool.risk == 'write' then
            print(('[peak-ai-npc][audit] source=%s session=%s npc=%s tool=%s ok=%s reason=%s'):format(tostring(source), tostring(session.id), tostring(session.npc.id), name, tostring(ok), tostring(reason or 'none')))
        end
    end
    local function complete(ok, result)
        if type(invocationId) == 'string' then session.toolResults[invocationId] = { ok = ok, result = result, name = name, revision = session.revision } end
        return ok, result
    end
    if not tool then return complete(false, 'tool_not_allowed') end
    if type(args) ~= 'table' then audit(false, 'invalid_arguments'); return complete(false, 'invalid_arguments') end
    if (name == 'police_check_warrants' or name == 'police_demand_id') then
        local permitted, reason = AINPCRecords.authorized(source, session, name)
        if not permitted then return false, reason end
    end
    if type(invocationId) == 'string' and session.toolResults[invocationId] then
        local cached = session.toolResults[invocationId]
        if cached.name ~= name or cached.revision ~= session.revision then return false, 'tool_replay_scope_mismatch' end
        return cached.ok, cached.result
    end
    local cooldown = tonumber(tool.cooldownSeconds or 0) or 0
    local lastRun = session.toolLastExecuted and session.toolLastExecuted[name]
    if cooldown > 0 and lastRun and os.time() - lastRun < cooldown then audit(false, 'tool_cooldown_active'); return complete(false, 'tool_cooldown_active') end
    if tool.validate then
        local ok, reason = tool.validate(source, session, args)
        if not ok then audit(false, reason or 'validation_failed'); return complete(false, reason or 'validation_failed') end
    end
    local ok, result = pcall(tool.execute, source, session, args)
    if not ok then audit(false, 'tool_execution_failed'); return complete(false, 'tool_execution_failed') end
    if type(result) == 'table' and result.ok == false then audit(false, result.reason or 'tool_rejected'); return complete(false, result.reason or 'tool_rejected') end
    if type(result) == 'table' and result.pending == true then
        session.toolLastExecuted = session.toolLastExecuted or {}
        session.toolLastExecuted[name] = os.time()
        return nil, result
    end
    session.toolLastExecuted = session.toolLastExecuted or {}
    session.toolLastExecuted[name] = os.time()
    audit(true)
    return complete(true, result)
end

function AINPCTools.ack(source, session, revision, actionId, phase, code)
    if not session or revision ~= session.revision or type(actionId) ~= 'string' then return false, 'stale_revision' end
    local pending = session.pendingActions and session.pendingActions[actionId]
    if not pending or pending.revision ~= revision then return false, 'unknown_action' end
    if pending.owner ~= source then return false, 'wrong_entity_owner' end
    if not pending.entity or not DoesEntityExist(pending.entity) then return false, 'npc_unavailable' end
    local ownerOk, currentOwner = pcall(NetworkGetEntityOwner, pending.entity)
    if not ownerOk or currentOwner ~= source then return false, 'entity_ownership_changed' end
    if phase == 'started' or phase == 'start' then
        pending.started = true
        return true, pending
    end
    if phase ~= 'completed' and phase ~= 'failed' then return false, 'invalid_action_phase' end
    session.pendingActions[actionId] = nil
    pending.ok = phase == 'completed'
    pending.code = type(code) == 'string' and code:sub(1, 64) or nil
    return true, pending
end

AINPCTools.register('get_shop_catalog', {
    risk = 'read',
    execute = function(_, session)
        local catalog, reason = catalogFor(session)
        if not catalog then return { ok = false, reason = reason } end
        return { shopId = session.npc.shop.id, items = catalog }
    end
})

AINPCTools.register('get_shop_stock', {
    risk = 'read',
    execute = function(_, session)
        local stock, reason = stockFor(session)
        if not stock then return { ok = false, reason = reason } end
        return { shopId = session.npc.shop.id, stock = stock }
    end
})

AINPCTools.register('player_has_item', {
    risk = 'read',
    validate = function(_, _, args)
        return type(args.item) == 'string' and #args.item >= 1 and #args.item <= 64 and numberInRange(args.quantity or 0, 1, 10000), 'invalid_item_query'
    end,
    execute = function(source, _, args)
        local ok, result = AINPCAdapters.playerHasItem(source, args.item, args.quantity)
        return ok and { ok = true, item = result.item, quantity = result.quantity, count = result.count, hasItem = result.hasItem } or { ok = false, reason = result }
    end
})

AINPCTools.register('create_purchase_quote', {
    risk = 'write',
    execute = function(source, session, args)
        local ok, result = AINPCCommerce.quote(source, session, args, 'buy')
        return ok and result or { ok = false, reason = result }
    end
})

AINPCTools.register('confirm_purchase', {
    risk = 'write',
    execute = function(source, session)
        local quote = session.pendingQuote
        if not quote then return { ok = false, reason = 'no_pending_quote' } end
        local ok, result = AINPCCommerce.confirm(source, session, quote.id)
        return ok and result or { ok = false, reason = result }
    end
})
AINPCTools.register('offer_mission', {
    risk = 'write',
    validate = function(_, session, args)
        return type(args.missionId) == 'string' and AINPCMissions and AINPCMissions.definitions[args.missionId] ~= nil and session.npc.missions ~= nil, 'mission_unavailable'
    end,
    execute = function(source, session, args)
        local ok, result = AINPCMissions.offer(source, session, args.missionId)
        return ok and { ok = true, mission = result } or { ok = false, reason = result }
    end
})

AINPCTools.register('accept_mission', {
    risk = 'write',
    validate = function(_, session, args) return session.offeredMission == args.missionId, 'mission_not_offered' end,
    execute = function(source, session, args)
        local ok, result = AINPCMissions.accept(source, session, args.missionId)
        return ok and { ok = true, mission = result } or { ok = false, reason = result }
    end
})

AINPCTools.register('npc_face_player', { risk = 'action', cooldownSeconds = 1, execute = function(source, session) return triggerNpcAction(source, session, 'face') end })
AINPCTools.register('npc_follow_player', { risk = 'action', cooldownSeconds = 2, execute = function(source, session) return triggerNpcAction(source, session, 'follow') end })
AINPCTools.register('npc_flee', { risk = 'action', cooldownSeconds = 2, execute = function(source, session) return triggerNpcAction(source, session, 'flee') end })
AINPCTools.register('npc_surrender', { risk = 'action', cooldownSeconds = 2, execute = function(source, session) return triggerNpcAction(source, session, 'surrender') end })
AINPCTools.register('npc_defend_store', {
    risk = 'action', cooldownSeconds = 10,
    validate = function(_, session)
        return session.npc.shop and session.npc.shop.robbery and session.npc.shop.robbery.enabled == true, 'shop_defense_unavailable'
    end,
    execute = function(source, session)
        local robbery = session.npc.shop.robbery
        return triggerNpcAction(source, session, 'shop_robbery', { response = 'defend', weapon = robbery.weapon or 'WEAPON_PISTOL' })
    end
})
AINPCTools.register('npc_stop', { risk = 'action', cooldownSeconds = 1, execute = function(source, session) return triggerNpcAction(source, session, 'stop') end })
AINPCTools.register('npc_react', {
    risk = 'action',
    cooldownSeconds = 1,
    validate = function(_, _, args)
        if type(args.reaction) ~= 'string' then return false, 'invalid_reaction' end
        for _, reaction in ipairs({ 'approach', 'offended', 'angry', 'dismissive', 'friendly', 'cautious' }) do
            if args.reaction == reaction then return true end
        end
        return false, 'invalid_reaction'
    end,
    execute = function(source, session, args)
        return triggerNpcAction(source, session, 'react', { reaction = args.reaction })
    end
})
AINPCTools.register('npc_walk_to_position', {
    risk = 'action',
    cooldownSeconds = 2,
    validate = function(_, session, args)
        if not finiteNumber(args.x) or not finiteNumber(args.y) or not finiteNumber(args.z) then return false, 'invalid_walk_position' end
        local origin = npcPosition(session)
        if not origin or #(origin - vec3(args.x, args.y, args.z)) > 30.0 then return false, 'walk_position_out_of_range' end
        return true
    end,
    execute = function(source, session, args) return triggerNpcAction(source, session, 'walk', { x = args.x, y = args.y, z = args.z }) end
})
AINPCTools.register('npc_sit', { risk = 'action', cooldownSeconds = 2, execute = function(source, session) return triggerNpcAction(source, session, 'sit') end })
AINPCTools.register('npc_point', { risk = 'action', cooldownSeconds = 2, execute = function(source, session) return triggerNpcAction(source, session, 'point') end })
AINPCTools.register('npc_enter_vehicle', { risk = 'action', cooldownSeconds = 3, execute = function(source, session) return triggerNpcAction(source, session, 'enter_vehicle') end })
AINPCTools.register('npc_leave_vehicle', { risk = 'action', cooldownSeconds = 3, execute = function(source, session) return triggerNpcAction(source, session, 'leave_vehicle') end })
AINPCTools.register('npc_crouch', {
    risk = 'action',
    cooldownSeconds = 1,
    validate = function(_, _, args) return args.enable == nil or type(args.enable) == 'boolean', 'invalid_crouch_state' end,
    description = 'Crouch down or stand back up to match the player or sneak.',
    parameters = {
        type = 'object',
        properties = {
            enable = { type = 'boolean', description = 'True to crouch down, false to stand back up.' }
        },
        additionalProperties = false
    },
    execute = function(source, session, args)
        local enable = type(args) == 'table' and args.enable ~= false
        return triggerNpcAction(source, session, enable and 'crouch' or 'stand', { enable = enable })
    end
})
AINPCTools.register('npc_perform_move', {
    risk = 'action',
    cooldownSeconds = 1,
    description = 'Perform a physical gesture, move, or roleplay action (nod, shake_head, wave, shrug, cross_arms, cheer, salute, smoke, drink, sit, point, crouch, stand).',
    parameters = {
        type = 'object',
        properties = {
            move = {
                type = 'string',
                enum = { 'nod', 'shake_head', 'wave', 'shrug', 'cross_arms', 'cheer', 'salute', 'smoke', 'drink', 'sit', 'point', 'crouch', 'stand' },
                description = 'The physical move or gesture to perform.'
            }
        },
        required = { 'move' },
        additionalProperties = false
    },
    validate = function(_, _, args)
        local allowed = { nod = true, shake_head = true, wave = true, shrug = true, cross_arms = true,
            cheer = true, salute = true, smoke = true, drink = true, sit = true, point = true, crouch = true, stand = true }
        return type(args.move) == 'string' and allowed[args.move] == true, 'invalid_move'
    end,
    execute = function(source, session, args)
        return triggerNpcAction(source, session, 'move', { move = args.move })
    end
})
AINPCTools.register('npc_look_at', {
    risk = 'action',
    cooldownSeconds = 1,
    description = 'Look directly at the player.',
    validate = function(_, _, args) return args.durationMs == nil or numberInRange(args.durationMs, 500, 10000), 'invalid_look_duration' end,
    execute = function(source, session, args)
        return triggerNpcAction(source, session, 'look_at', { durationMs = type(args) == 'table' and args.durationMs or 5000 })
    end
})
AINPCTools.register('npc_call_service', {
    risk = 'write',
    validate = function(_, session, args)
        if type(args.service) ~= 'string' or #args.service < 1 or #args.service > 32 then return false, 'invalid_service' end
        for _, allowedService in ipairs(session.npc.services or {}) do if allowedService == args.service then return true end end
        return false, 'service_unavailable'
    end,
    execute = function(source, session, args)
        local ok, result = AINPCAdapters.callService(source, session, args.service)
        if not ok then return { ok = false, reason = result } end
        return { ok = true, service = args.service, dispatch = result }
    end
})

AINPCTools.register('sell_item_to_shop', {
    risk = 'write',
    execute = function(source, session, args)
        local ok, result = AINPCCommerce.quote(source, session, args, 'sell')
        return ok and result or { ok = false, reason = result }
    end
})
AINPCTools.register('npc_call_police', {
    risk = 'write',
    cooldownSeconds = 5,
    validate = function(_, _, args)
        return type(args.reason) == 'string' and #args.reason >= 1 and #args.reason <= 256, 'invalid_reason'
    end,
    execute = function(source, session, args)
        local ok, result = AINPCAdapters.callService(source, session, 'police', args.reason)
        if not ok then return { ok = false, reason = result } end
        return { ok = true, service = 'police', reason = args.reason, dispatch = result }
    end
})

AINPCTools.register('npc_call_ems', {
    risk = 'write',
    cooldownSeconds = 5,
    validate = function(_, _, args)
        return type(args.condition) == 'string' and #args.condition >= 1 and #args.condition <= 256, 'invalid_condition'
    end,
    execute = function(source, session, args)
        local ok, result = AINPCAdapters.callService(source, session, 'ems', args.condition)
        if not ok then return { ok = false, reason = result } end
        return { ok = true, service = 'ems', condition = args.condition, dispatch = result }
    end
})

AINPCTools.register('medical_triage_player', {
    risk = 'read',
    cooldownSeconds = 2,
    execute = function(source, session) return AINPCMedical.triage(source, session) end
})

AINPCTools.register('medical_heal_player', {
    risk = 'action',
    execute = function(source, session, args) return AINPCMedical.handoff(source, session, args) end
})

AINPCTools.register('medical_provide_supplies', {
    risk = 'write',
    execute = function(source, session, args) return AINPCMedical.supplies(source, session, args) end
})
AINPCTools.register('police_check_warrants', {
    risk = 'read',
    cooldownSeconds = 5,
    execute = function(source, session) return AINPCRecords.warrants(source, session) end
})

AINPCTools.register('police_demand_id', {
    risk = 'read',
    cooldownSeconds = 2,
    execute = function(source, session) return AINPCRecords.identification(source, session) end
})

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then return end
    for name, owner in pairs(registryOwners) do
        if owner == resourceName then
            registry[name] = nil
            registryOwners[name] = nil
        end
    end
end)
