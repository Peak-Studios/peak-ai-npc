AINPCSessions = { bySource = {}, byNpc = {}, requests = {} }

local allowedTransitions = {
    ready = { capturing = true, deliberating = true, synthesizing = true },
    capturing = { transcribing = true, ready = true },
    transcribing = { deliberating = true, ready = true },
    deliberating = { action_pending = true, synthesizing = true, speaking = true, ready = true },
    action_pending = { deliberating = true, ready = true },
    synthesizing = { speaking = true, ready = true },
    speaking = { capturing = true, ready = true }
}

local function now() return os.time() end

local function entityDead(entity)
    if not entity or entity == 0 then return true end
    local ok, health = pcall(GetEntityHealth, entity)
    return ok and type(health) == 'number' and health <= 0
end

local function sessionId(source, npcId)
    return ('%x-%x-%x-%s'):format(os.time(), GetGameTimer(), math.random(0, 0x7fffffff), tostring(npcId):gsub('[^%w_-]', ''))
end

local function sameRoutingBucket(source, entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return true end
    local playerOk, playerBucket = pcall(GetPlayerRoutingBucket, source)
    local entityOk, entityBucket = pcall(GetEntityRoutingBucket, entity)
    return playerOk and entityOk and playerBucket == entityBucket
end

local function policyAllows(source, npc)
    local policy = npc.interactionPolicy
    if type(policy) ~= 'table' then return true end
    if type(policy.ace) == 'string' and policy.ace ~= '' and not IsPlayerAceAllowed(source, policy.ace) then return false, 'permission_denied' end
    local adapter = AINPCAdapters.framework()
    local player = adapter.getPlayer(source)
    if not player then return false, 'player_unavailable' end
    local context = adapter.getAuthorizationContext and adapter.getAuthorizationContext(player) or {}
    local job = context.job
    local gang = context.gang
    local function gradeOf(value)
        if type(value) == 'number' then return value end
        if type(value) == 'table' then return tonumber(value.level or value.grade or 0) or 0 end
        return 0
    end
    if type(policy.jobs) == 'table' then
        local name = type(job) == 'table' and (job.name or job.id) or nil
        local minimumGrade = name and policy.jobs[name]
        local grade = type(job) == 'table' and gradeOf(job.grade) or 0
        if minimumGrade == nil or grade < tonumber(minimumGrade or 0) then return false, 'job_not_allowed' end
    end
    if type(policy.gangs) == 'table' then
        local name = type(gang) == 'table' and (gang.name or gang.id) or nil
        local minimumGrade = name and policy.gangs[name]
        local grade = type(gang) == 'table' and gradeOf(gang.grade) or 0
        if minimumGrade == nil or grade < tonumber(minimumGrade or 0) then return false, 'gang_not_allowed' end
    end
    return true
end

function AINPCSessions.create(source, npcId, entity)
    local npc = AINPCDefinitions[npcId]
    if not npc then return nil, 'unknown_npc' end
    if npc.enabled == false then return nil, 'npc_unavailable' end
    local allowed, policyReason = policyAllows(source, npc)
    if not allowed then return nil, policyReason end
    if AINPCSessions.byNpc[npcId] and Config.Conversations.exclusiveByDefault then return nil, 'npc_busy' end
    if AINPCSessions.bySource[source] then return nil, 'player_already_in_conversation' end
    local session = { id = sessionId(source, npcId), source = source, npcId = npcId, npc = npc, entity = entity, createdAt = now(), expiresAt = now() + Config.Conversations.idleTimeoutSeconds, turns = 0, history = {}, pendingQuote = nil, busy = false, phase = 'ready', revision = 1, turnId = nil, gatewayNonce = 0, actionSequence = 0, utteranceSequence = 0, pendingActions = {}, requestIds = {}, requestOrder = {}, toolLastExecuted = {}, toolResults = {} }
    AINPCSessions.bySource[source] = session
    AINPCSessions.byNpc[npcId] = session
    return session
end

function AINPCSessions.createResolved(source, npc, entity)
    if type(npc) ~= 'table' or type(npc.id) ~= 'string' then return nil, 'invalid_npc' end
    if npc.enabled == false then return nil, 'npc_unavailable' end
    local allowed, policyReason = policyAllows(source, npc)
    if not allowed then return nil, policyReason end
    if AINPCSessions.byNpc[npc.id] and Config.Conversations.exclusiveByDefault then return nil, 'npc_busy' end
    if AINPCSessions.bySource[source] then return nil, 'player_already_in_conversation' end
    local session = { id = sessionId(source, npc.id), source = source, npcId = npc.id, npc = npc, entity = entity, createdAt = now(), expiresAt = now() + Config.Conversations.idleTimeoutSeconds, turns = 0, history = {}, pendingQuote = nil, busy = false, phase = 'ready', revision = 1, turnId = nil, gatewayNonce = 0, actionSequence = 0, utteranceSequence = 0, pendingActions = {}, requestIds = {}, requestOrder = {}, toolLastExecuted = {}, toolResults = {} }
    AINPCSessions.bySource[source], AINPCSessions.byNpc[npc.id] = session, session
    return session
end

function AINPCSessions.get(source) return AINPCSessions.bySource[source] end

function AINPCSessions.invalidate(session, reason)
    if not session then return end
    session.revision = (session.revision or 0) + 1
    session.gatewayNonce = (session.gatewayNonce or 0) + 1
    session.phase = 'ready'
    session.busy = false
    session.turnId = nil
    session.utteranceId = nil
    session.closeReason = reason
    session.pendingActions = {}
end

function AINPCSessions.close(source, reason)
    local session = AINPCSessions.bySource[source]
    if not session then return end
    local stoppedRevision, stoppedUtteranceId = session.revision, session.utteranceId or session.lastUtteranceId
    AINPCSessions.invalidate(session, reason or 'closed')
    local stopPayload = {
        npcId = session.npcId,
        sessionRevision = stoppedRevision,
        utteranceId = stoppedUtteranceId,
        reason = reason or 'closed',
        fadeMs = 150
    }
    local origin = session.entity and session.entity ~= 0 and DoesEntityExist(session.entity) and GetEntityCoords(session.entity) or nil
    local bucket = session.entity and session.entity ~= 0 and DoesEntityExist(session.entity) and GetEntityRoutingBucket(session.entity) or nil
    for _, value in ipairs(GetPlayers()) do
        local target = tonumber(value)
        local ped = target and GetPlayerPed(target) or 0
        if target and ped ~= 0 and DoesEntityExist(ped) and (not bucket or GetPlayerRoutingBucket(target) == bucket)
            and (not origin or #(GetEntityCoords(ped) - origin) <= 20.0) then
            TriggerClientEvent(AINPC.Event.StopUtterance, target, stopPayload)
        end
    end
    if AINPCBehavior and type(AINPCBehavior.clearSession) == 'function' then AINPCBehavior.clearSession(source, session) end
    AINPCSessions.bySource[source] = nil
    if AINPCSessions.byNpc[session.npcId] == session then AINPCSessions.byNpc[session.npcId] = nil end
end


function AINPCSessions.transition(session, nextPhase, correlation)
    if not session or type(nextPhase) ~= 'string' then return false, 'invalid_phase' end
    local current = session.phase or 'ready'
    if current ~= nextPhase and not (allowedTransitions[current] and allowedTransitions[current][nextPhase]) then
        return false, 'invalid_phase_transition'
    end
    correlation = type(correlation) == 'table' and correlation or {}
    if correlation.sessionRevision and correlation.sessionRevision ~= session.revision then return false, 'stale_revision' end
    session.phase = nextPhase
    if correlation.turnId ~= nil then session.turnId = correlation.turnId end
    if correlation.utteranceId ~= nil then session.utteranceId = correlation.utteranceId end
    session.busy = nextPhase ~= 'ready' and nextPhase ~= 'speaking'
    return true
end

function AINPCSessions.beginTurn(session, requestId)
    session.revision = (session.revision or 0) + 1
    session.turnId = requestId or ('%s:%s'):format(session.id, session.revision)
    session.gatewayNonce = (session.gatewayNonce or 0) + 1
    session.pendingActions = {}
    session.utteranceId = nil
    session.phase = 'deliberating'
    session.busy = true
    return session.revision, session.turnId, session.gatewayNonce
end

function AINPCSessions.current(source, sessionId, revision)
    local session = AINPCSessions.bySource[source]
    if not session or (sessionId and session.id ~= sessionId) then return nil, 'invalid_session' end
    if revision and revision ~= session.revision then return nil, 'stale_revision' end
    return session
end

function AINPCSessions.valid(source, session)
    if not session or session.source ~= source or AINPCSessions.bySource[source] ~= session then return false, 'invalid_session' end
    if session.recordsCharacter then
        local adapter = AINPCAdapters.framework()
        local player = adapter.getPlayer(source)
        if adapter.name ~= session.recordsFramework or not player or adapter.getCharacterId(player) ~= session.recordsCharacter then
            return false, 'character_changed'
        end
    end
    if session.npc.enabled == false then return false, 'npc_unavailable' end
    local allowed, policyReason = policyAllows(source, session.npc)
    if not allowed then return false, policyReason end
    if session.npc.entityNetId and (not AINPCAmbient or not AINPCAmbient.validBinding(source, session.npc, session.entity)) then
        return false, 'ambient_binding_stale'
    end
    if session.expiresAt < now() then return false, 'session_expired' end
    if session.turns >= Config.Conversations.maxTurns then return false, 'turn_limit' end
    local playerPed = GetPlayerPed(source)
    if playerPed == 0 or not DoesEntityExist(playerPed) then return false, 'player_unavailable' end
    if entityDead(playerPed) then return false, 'player_dead' end
    local playerCoords = GetEntityCoords(playerPed)
    local npcCoords
    -- Once bound to a networked entity, loss of that entity must invalidate the
    -- session. Authored coordinates are not a substitute for a deleted/reused ped.
    if session.entity and session.entity ~= 0 then
        if not DoesEntityExist(session.entity) then return false, 'npc_unavailable' end
        local expectedModel = tonumber(session.npc.model) or (type(session.npc.model) == 'string' and joaat(session.npc.model))
        if expectedModel and GetEntityModel(session.entity) ~= expectedModel then return false, 'npc_entity_changed' end
    end
    if session.entity and session.entity ~= 0 and DoesEntityExist(session.entity) then
        -- A server-owned NPC in another bucket is not a valid fallback target,
        -- even if two instances share the same coordinates.
        if not sameRoutingBucket(source, session.entity) then return false, 'npc_not_in_bucket' end
        if entityDead(session.entity) then return false, 'npc_dead' end
        npcCoords = GetEntityCoords(session.entity)
    end
    -- A client may be using the supported local-ped fallback when a server-created
    -- entity cannot replicate into its routing bucket. Keep the server-side
    -- proximity check by using the authoritative configured coordinates.
    if not npcCoords and session.npc.localEntity and session.observedNpcCoords then
        npcCoords = session.observedNpcCoords
    end
    if not npcCoords and session.npc.coords then
        npcCoords = vec3(session.npc.coords.x, session.npc.coords.y, session.npc.coords.z)
    end
    if npcCoords and #(playerCoords - npcCoords) > Config.Conversations.maximumDistance then return false, 'too_far' end
    return true
end

function AINPCSessions.touch(session)
    session.expiresAt = now() + Config.Conversations.idleTimeoutSeconds
    session.turns = session.turns + 1
end

CreateThread(function()
    while true do
        Wait(10000)
        for source, session in pairs(AINPCSessions.bySource) do if session.expiresAt < now() then AINPCSessions.close(source, 'timeout') end end
    end
end)
