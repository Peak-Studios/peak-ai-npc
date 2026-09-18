local framework
local spawned = {}
local requestBuckets = {}
local pendingStarts = {}
local lastGatewayError = 'none'
local registeredNpcOwners = {}
local gatewayCapabilities = { transcription = 'none' }
local proactivePlayerCooldowns = {}
local proactiveNpcCooldowns = {}

local function validSession(source, session)
    if session and session.npc and session.npc.entityNetId and not AINPCAmbient.validBinding(source, session.npc, session.entity) then
        return false, 'ambient_binding_stale'
    end
    return AINPCSessions.valid(source, session)
end

local function log(message)
    if Config.Debug then print(('[peak-ai-npc] %s'):format(message)) end
end

local function gatewayConfig()
    local url = GetConvar('peak_ai_npc_gateway_url', Config.Gateway.url or 'http://127.0.0.1:8787')
    local secret = GetConvar('peak_ai_npc_gateway_secret', Config.Gateway.licenseKey or GetConvar(Config.Gateway.secretConvar or 'peak_ai_npc_gateway_secret', ''))
    local serverId = GetConvar('peak_ai_npc_server_id', Config.Gateway.serverId or 'local')
    return url, secret, serverId
end

local function urlEncode(value)
    return tostring(value):gsub('[^%w%-%._~]', function(character) return ('%%%02X'):format(string.byte(character)) end)
end

local function detectedTarget()
    if Config.Target ~= 'auto' and Config.Target ~= 'native' then return GetResourceState(Config.Target) == 'started' and Config.Target or 'native' end
    if GetResourceState('ox_target') == 'started' then return 'ox_target' end
    if GetResourceState('qb-target') == 'started' then return 'qb-target' end
    return 'native'
end

local function gatewayRequest(path, payload, callback, method)
    local url, secret, serverId = gatewayConfig()
    if secret == '' then lastGatewayError = 'gateway_secret_missing'; callback(false, nil, 'gateway_secret_missing'); return end
    PerformHttpRequest(url .. path, function(status, body)
        if status < 200 or status >= 300 or not body then
            local error = 'gateway_http_' .. tostring(status)
            if body then
                local decoded, response = pcall(json.decode, body)
                if decoded and type(response) == 'table' and type(response.error) == 'string' and response.error:match('^[%w_%-]+$') then
                    error = response.error
                end
            end
            lastGatewayError = error
            print(('[peak-ai-npc] gateway request failed path=%s status=%s error=%s'):format(path, tostring(status), error))
            callback(false, nil, error)
            return
        end
        local ok, response = pcall(json.decode, body)
        if not ok or type(response) ~= 'table' then lastGatewayError = 'gateway_invalid_json'; callback(false, nil, lastGatewayError); return end
        lastGatewayError = 'none'
        callback(true, response)
    end, method or 'POST', payload and json.encode(payload) or '', { ['Content-Type'] = 'application/json', ['X-Peak-License-Key'] = secret, ['X-Peak-Server-Id'] = serverId, ['X-AI-NPC-Secret'] = secret })
end

AINPCGatewayRequest = gatewayRequest

local function rateLimited(source)
    local bucket = requestBuckets[source] or { started = os.time(), count = 0 }
    if os.time() - bucket.started >= 60 then bucket = { started = os.time(), count = 0 } end
    bucket.count = bucket.count + 1
    requestBuckets[source] = bucket
    return bucket.count > Config.Conversations.maxRequestsPerMinute
end

local function appendConversationHistory(session, role, content)
    session.history[#session.history + 1] = { role = role, content = content }
    -- Keep recent dialogue coherent without exceeding the gateway's request
    -- contract. Durable facts remain in the memory store independently.
    while #session.history > 40 do table.remove(session.history, 1) end
end

local function sendState(source, state, payload)
    payload = payload or {}
    local session = AINPCSessions and AINPCSessions.get(source)
    if session then
        payload.startId = payload.startId or session.startId
        payload.sessionRevision = payload.sessionRevision or session.revision
        payload.turnId = payload.turnId or session.turnId
        payload.gatewayNonce = payload.gatewayNonce or session.gatewayNonce
        payload.phase = payload.phase or session.phase
        if payload.pendingConfirmation == nil then payload.pendingConfirmation = session.pendingQuote ~= nil end
        payload.quoteId = session.pendingQuote and session.pendingQuote.id or false
        local quote = session.pendingQuote
        payload.transactionQuote = quote and { id = quote.id, kind = quote.kind, total = quote.total, items = quote.items } or false
        payload.shopAvailable = session.npc.shop ~= nil
    end
    TriggerClientEvent(AINPC.Event.ClientState, source, { state = state, payload = payload })
end

local function rejectRateLimited(source)
    if not rateLimited(source) then return false end
    local session = AINPCSessions and AINPCSessions.get(source)
    if session and session.phase == 'capturing' then
        AINPCSessions.transition(session, 'ready', { sessionRevision = session.revision })
    end
    sendState(source, AINPC.State.Error, { message = 'You are interacting too quickly. Wait a moment and try again.' })
    return true
end

local deliveryPresets = { neutral = true, warm = true, stern = true, nervous = true, urgent = true, quiet = true, menacing = true }
local performanceGestures = { none = true, greet = true, explain = true, warn = true, dismiss = true }
local performanceGazes = { player = true, away = true, scan = true }

local function validatedPerformance(session, value)
    value = type(value) == 'table' and value or {}
    local fallback = type(session.npc.voice) == 'table' and session.npc.voice.deliveryPreset or 'neutral'
    if session.sceneUrgency == 'active_combat' or session.sceneUrgency == 'recent_assault' then
        fallback = session.npc.archetype == 'gang' and 'menacing' or 'urgent'
    elseif session.sceneUrgency == 'weapon_threat' then fallback = session.npc.archetype == 'gang' and 'menacing' or 'nervous'
    elseif session.recentTreatment == 'threatening' then fallback = session.npc.archetype == 'gang' and 'menacing' or 'nervous'
    elseif session.recentTreatment == 'insulting' then fallback = 'stern'
    elseif session.recentTreatment == 'apologetic' or session.recentTreatment == 'respectful' then fallback = 'warm' end
    local preset = deliveryPresets[value.deliveryPreset] and value.deliveryPreset or (deliveryPresets[fallback] and fallback or 'neutral')
    local intensity = tonumber(value.intensity) or 0.5
    return {
        emotion = deliveryPresets[value.emotion] and value.emotion or preset,
        intensity = math.max(0.0, math.min(1.0, intensity)),
        cadence = type(value.cadence) == 'string' and value.cadence:sub(1, 32) or 'natural',
        deliveryPreset = preset,
        gesture = performanceGestures[value.gesture] and value.gesture or 'none',
        gaze = performanceGazes[value.gaze] and value.gaze or 'player'
    }
end

local function sessionDisplayName(session)
    local identity = session and session.npc and session.npc.identity
    if type(identity) ~= 'table' then return session and session.npcId or 'NPC' end
    if (session.npc.kind == 'ambient' or session.npc.kind == 'resident') and not session.identityRevealed then
        return type(identity.displayName) == 'string' and identity.displayName or 'Local resident'
    end
    return identity.name
end

local function identityTopic(text)
    if type(text) ~= 'string' then return false end
    local value = text:lower()
    for _, phrase in ipairs({ 'name', 'who are you', 'what should i call you', 'what do i call you', 'introduce yourself' }) do
        if value:find(phrase, 1, true) then return true end
    end
    return false
end

local function revealIdentityFromDialogue(session, playerText, npcText)
    if not session or not session.npc or (session.npc.kind ~= 'ambient' and session.npc.kind ~= 'resident') or session.identityRevealed then return end
    local name = session.npc.identity and session.npc.identity.name
    if identityTopic(playerText) or (type(name) == 'string' and type(npcText) == 'string' and npcText:lower():find(name:lower(), 1, true)) then
        session.identityRevealed = true
        if session.npc.kind == 'resident' then AINPCResidents.revealName(session) end
    end
end

local function playerIntroducedThemself(text)
    if type(text) ~= 'string' then return false end
    local value = text:lower()
    return value:find('my name is ', 1, true) ~= nil
        or value:find("i'm called ", 1, true) ~= nil
        or value:find('i am called ', 1, true) ~= nil
        or value:find('call me ', 1, true) ~= nil
end

local function applyTreatmentReaction(source, session, text)
    if AINPCBehavior then AINPCBehavior.noteTreatment(source, session, text) end
end

local function safeAudioUrl(value)
    if type(value) ~= 'string' or #value < 8 or #value > 2048 or not value:match('^https?://') then return nil end
    return value
end

local sendNearbySpeech

local function fixedSpeech(source, session, text, extra)
    session.busy = true
    AINPCSessions.transition(session, 'synthesizing', { sessionRevision = session.revision })
    sendState(source, AINPC.State.Synthesizing, { message = 'Preparing the NPC response…' })
    local voice = type(session.npc.voice) == 'table' and session.npc.voice or {}
    local completed = false
    local revision = session.revision
    local function deliver(audio)
        if completed or AINPCSessions.get(source) ~= session or session.revision ~= revision then return end
        local valid = validSession(source, session)
        if not valid then AINPCSessions.close(source, 'speech_scope_invalid'); return end
        completed = true
        session.busy = false
        session.utteranceSequence = (session.utteranceSequence or 0) + 1
        local utteranceId = type(audio) == 'table' and audio.utteranceId or ('%s:u:%s:%s'):format(session.id, revision, session.utteranceSequence)
        session.utteranceId, session.lastUtteranceId = utteranceId, utteranceId
        AINPCSessions.transition(session, 'speaking', { sessionRevision = revision, utteranceId = utteranceId })
        local payload = type(extra) == 'table' and extra or {}
        payload.text = text
        payload.audio = type(audio) == 'table' and audio or nil
        payload.audioUrl = payload.audio and safeAudioUrl(payload.audio.url) or safeAudioUrl(audio)
        if payload.audio then payload.audio.url = payload.audioUrl end
        payload.npcId = session.npcId
        payload.name = sessionDisplayName(session)
        payload.sourceNetworkId = session.entity and session.entity ~= 0 and DoesEntityExist(session.entity) and NetworkGetNetworkIdFromEntity(session.entity) or nil
        payload.targetServerId = source
        payload.audioVolume = 1.0
        payload.maximumAudibleDistance = 20.0
        payload.performance = validatedPerformance(session, payload.performance)
        session.performance = payload.performance
        sendState(source, AINPC.State.Speaking, payload)
        sendNearbySpeech(source, session, { text = text, audio = payload.audio, audioUrl = payload.audioUrl, utteranceId = utteranceId, performance = payload.performance })
    end
    SetTimeout((Config.Gateway.timeoutMs or 15000) + 1000, function() deliver(nil) end)
    gatewayRequest('/v1/speech', {
        serverId = GetConvar('peak_ai_npc_server_id', Config.Gateway.serverId or 'local'),
        sessionId = session.id,
        text = text,
        voiceProfileId = voice.voiceProfileId,
        voiceSeed = voice.voiceSeed,
        genderPresentation = voice.genderPresentation,
        ageBand = voice.ageBand,
        accent = voice.accent,
        language = voice.language,
        qualityMode = voice.qualityMode,
        deliveryPreset = voice.deliveryPreset,
        sessionRevision = revision,
        turnId = session.turnId,
        gatewayNonce = session.gatewayNonce
    }, function(ok, response)
        deliver(ok and (response.audio or response.audioUrl) or nil)
    end)
end

sendNearbySpeech = function(source, session, payload)
    if session.privateReply == true or session.npc.privateReply == true then return end
    -- Client-local population peds cannot be a multiplayer audio source. A
    -- resident handoff must promote them to a visible network entity first.
    if session.npc.localEntity or not session.entity or session.entity == 0 or not DoesEntityExist(session.entity) then return end
    local npcCoords
    if session.entity and session.entity ~= 0 and DoesEntityExist(session.entity) then
        npcCoords = GetEntityCoords(session.entity)
    elseif session.npc.coords then
        npcCoords = vec3(session.npc.coords.x, session.npc.coords.y, session.npc.coords.z)
    end
    if not npcCoords then return end
    -- Coordinates can overlap across routing buckets. Never expose dialogue or
    -- generated audio to a player outside the speaker's current instance.
    local sourceBucket = GetPlayerRoutingBucket(source)
    local publicPayload = {
        text = tostring(payload.text or ''),
        audioUrl = payload.audioUrl,
        npcId = session.npcId,
        name = sessionDisplayName(session),
        audio = payload.audio,
        utteranceId = payload.utteranceId,
        performance = payload.performance,
        sessionRevision = session.revision,
        turnId = session.turnId,
        sourceNetworkId = NetworkGetNetworkIdFromEntity(session.entity),
        targetServerId = source,
        nearby = true
    }
    for _, playerId in ipairs(GetPlayers()) do
        local target = tonumber(playerId)
        if target and target ~= source and GetPlayerRoutingBucket(target) == sourceBucket then
            local ped = GetPlayerPed(target)
            if ped ~= 0 and DoesEntityExist(ped) then
                local distance = #(GetEntityCoords(ped) - npcCoords)
                if distance <= 20.0 then
                    -- Every client computes live attenuation from the moving ped
                    -- and its own camera. Keep only the server-side range/bucket
                    -- gate here so distance is not applied twice.
                    local listenerPayload = { text = publicPayload.text, audio = publicPayload.audio, audioUrl = publicPayload.audioUrl, utteranceId = publicPayload.utteranceId, performance = publicPayload.performance, sessionRevision = publicPayload.sessionRevision, turnId = publicPayload.turnId, sourceNetworkId = publicPayload.sourceNetworkId, targetServerId = source, npcId = publicPayload.npcId, name = publicPayload.name, nearby = true, maximumAudibleDistance = 20.0, audioVolume = 1.0 }
                    TriggerClientEvent(AINPC.Event.ClientState, target, { state = AINPC.State.Speaking, payload = listenerPayload })
                end
            end
        end
    end
end

local relationshipFields = { 'score', 'familiarity', 'trust', 'warmth', 'respect', 'fear', 'irritation', 'obligation', 'sessionScore' }

local function safeRelationshipSnapshot(value)
    if type(value) ~= 'table' then return nil end
    local snapshot = {}
    for _, key in ipairs(relationshipFields) do
        local number = value[key]
        if type(number) == 'number' and number == number and number > -math.huge and number < math.huge then
            snapshot[key] = math.max(-100, math.min(100, number))
        end
    end
    if type(value.recentTreatment) == 'string' and #value.recentTreatment <= 32 and value.recentTreatment:match('^[%a][%w_%-]*$') then
        snapshot.recentTreatment = value.recentTreatment
    end
    if type(value.updatedAt) == 'string' and #value.updatedAt <= 40 then snapshot.updatedAt = value.updatedAt end
    snapshot.tags = {}
    if type(value.tags) == 'table' then
        for _, tag in ipairs(value.tags) do
            if #snapshot.tags >= 12 then break end
            if type(tag) == 'string' and #tag >= 1 and #tag <= 64 and tag:match('^[%w_:%-]+$') then
                snapshot.tags[#snapshot.tags + 1] = tag
            end
        end
    end
    return snapshot
end

local function rejectProactiveStart(source, startId)
    sendState(source, AINPC.State.Idle, { startId = startId })
end

local function proactiveStartAllowed(source, npcId, proactive)
    if proactive ~= true then return true end
    local policy = Config.Proactive or {}
    if policy.enabled ~= true or type(npcId) ~= 'string' or npcId == '' then return false end
    local now = GetGameTimer()
    local playerCooldown = math.max(10000, (tonumber(policy.playerCooldownSeconds) or 90) * 1000)
    local npcCooldown = math.max(10000, (tonumber(policy.npcCooldownSeconds) or 180) * 1000)
    local playerLast = proactivePlayerCooldowns[source] or -1000000
    local npcLast = proactiveNpcCooldowns[npcId] or -1000000
    return now - playerLast >= playerCooldown and now - npcLast >= npcCooldown
end

local function recordProactiveStart(source, npcId)
    local now = GetGameTimer()
    proactivePlayerCooldowns[source] = now
    proactiveNpcCooldowns[npcId] = now
end

local function clearProactiveTurn(session, revision)
    if not session or (revision and session.proactiveTurnRevision ~= revision) then return end
    session.proactiveTrigger = nil
    session.proactiveTurnRevision = nil
end

local function serverNative(fn, ...)
    if type(fn) ~= 'function' then return nil end
    local ok, value = pcall(fn, ...)
    return ok and value or nil
end

local function authoritativeScene(source, session)
    local player = GetPlayerPed(source)
    local npc = session.entity
    if player == 0 or not DoesEntityExist(player) or not npc or npc == 0 or not DoesEntityExist(npc) then
        return { available = false }
    end
    local playerCoords, npcCoords = GetEntityCoords(player), GetEntityCoords(npc)
    return {
        available = true,
        distance = #(playerCoords - npcCoords),
        playerHealth = serverNative(GetEntityHealth, player),
        npcHealth = serverNative(GetEntityHealth, npc),
        npcInCombatWithPlayer = serverNative(IsPedInCombat, npc, player) == true,
        playerInCombatWithNpc = serverNative(IsPedInCombat, player, npc) == true,
        npcDamagedByPlayer = serverNative(HasEntityBeenDamagedByEntity, npc, player, true) == true,
        playerDamagedByNpc = serverNative(HasEntityBeenDamagedByEntity, player, npc, true) == true,
        npcNetworkId = serverNative(NetworkGetNetworkIdFromEntity, npc)
    }
end

local function authoritativeContext(source, session)
    local player = framework.getPlayer(source)
    local playerContext = framework.getPublicContext(player)
    playerContext.characterId = framework.getCharacterId(player)
    if session.npc.kind == 'resident' and not session.playerNameKnown then playerContext.name = nil end
    local locationCoords = session.npc.localEntity and session.observedNpcCoords or session.npc.coords
    if session.entity and session.entity ~= 0 and DoesEntityExist(session.entity) then
        local live = GetEntityCoords(session.entity)
        locationCoords = { x = live.x, y = live.y, z = live.z, w = GetEntityHeading(session.entity) }
    end
    local zone
    if locationCoords then
        local ok, value = pcall(GetNameOfZone, locationCoords.x, locationCoords.y, locationCoords.z)
        if ok and type(value) == 'string' then zone = value end
    end
    local relationship = safeRelationshipSnapshot(session.relationship) or {}
    relationship.sessionScore = session.treatmentScore or 0
    relationship.recentTreatment = session.recentTreatment or 'neutral'
    local archetype = session.npc.archetype
    if AINPCBehavior and type(AINPCBehavior.profile) == 'function' then
        local ok, resolved = pcall(AINPCBehavior.profile, session.npc, session.entity)
        if ok and type(resolved) == 'string' then archetype = resolved end
    end
    local environment
    if AINPCEnvironment and type(AINPCEnvironment.snapshot) == 'function' then
        local ok, value = pcall(AINPCEnvironment.snapshot, session.npc, session.entity, source, archetype)
        if ok and type(value) == 'table' then environment = value end
    end
    local scene = {
        authoritative = authoritativeScene(source, session),
        clientObserved = session.sceneObservation,
        observationAgeMs = session.lastSceneObservationAt and math.max(0, GetGameTimer() - session.lastSceneObservationAt) or nil,
        urgency = session.sceneUrgency or 'normal'
    }
    local proactive = session.proactiveTrigger == true and session.proactiveTurnRevision == session.revision
        and { playerHasNotSpoken = true, initiatedBy = 'npc' } or nil
    return {
        player = playerContext,
        police = AINPCPolice and AINPCPolice.context(source, session) or nil,
        npc = { id = session.npc.id, kind = session.npc.kind or 'configured', identity = session.npc.identity, occupation = session.npc.identity and session.npc.identity.occupation, model = session.npc.model, archetype = archetype, residentState = session.npc.residentState, knowledge = session.npc.knowledge },
        location = { coords = locationCoords, zone = zone, routingBucket = GetPlayerRoutingBucket(source) },
        scene = scene,
        mission = { active = AINPCMissions.context(source), offered = session.offeredMission },
        vision = session.lastVision,
        relationship = relationship,
        environment = environment,
        proactive = proactive,
        memory = { enabled = Config.Memory.enabled and session.npc.memoryEnabled ~= false, retentionDays = Config.Memory.retentionDays, minimumImportance = Config.Memory.minimumImportance },
        server = { time = os.date('!%Y-%m-%dT%H:%M:%SZ'), lore = Config.ServerLore },
        extensions = AINPCContext.collect(source, session)
    }
end

local function validSceneObservation(value)
    if type(value) ~= 'table' or value.untrusted ~= true then return false end
    local encoded = json.encode(value)
    if not encoded or #encoded > 12000 then return false end
    local camera = value.camera
    if type(camera) ~= 'table' or type(camera.x) ~= 'number' or type(camera.y) ~= 'number' or type(camera.z) ~= 'number' then return false end
    for _, listName in ipairs({ 'nearbyPeds', 'nearbyVehicles' }) do
        local list = value[listName]
        if type(list) ~= 'table' or #list > 12 then return false end
        for _, entity in ipairs(list) do
            if type(entity) ~= 'table' or type(entity.model) ~= 'number' then return false end
            if entity.networkId ~= nil and type(entity.networkId) ~= 'number' then return false end
        end
    end
    return true
end

local function finiteNumber(value)
    return type(value) == 'number' and value == value and value > -math.huge and value < math.huge
end

local function updateLocalObservedNpc(source, session, observation)
    if not session.npc.localEntity or session.entity then return end
    local observed = observation.npc
    local coords = type(observed) == 'table' and observed.coords or nil
    if type(coords) ~= 'table' or not finiteNumber(coords.x) or not finiteNumber(coords.y) or not finiteNumber(coords.z) then return end
    local player = GetPlayerPed(source)
    if player == 0 or not DoesEntityExist(player) then return end
    local candidate = vec3(coords.x, coords.y, coords.z)
    local playerCoords = GetEntityCoords(player)
    if #(candidate - playerCoords) > ((Config.Conversations.maximumDistance or 8.0) + 2.0) then return end
    local origin = vec3(session.npc.coords.x, session.npc.coords.y, session.npc.coords.z)
    if #(candidate - origin) > (Config.Ambient.maximumRoamDistance or 100.0) then return end
    local previous = session.observedNpcCoords or origin
    if #(candidate - previous) > (Config.Ambient.maximumObservedStep or 12.0) then return end
    session.observedNpcCoords = candidate
end

local function validCatalogDefinition(definition)
    if type(definition) ~= 'table' or type(definition.model) ~= 'string' or #definition.model < 1 or #definition.model > 80 then return false end
    local coords = definition.coords
    local identity = definition.identity
    if (type(coords) ~= 'table' and type(coords) ~= 'vector4') or type(coords.x) ~= 'number' or type(coords.y) ~= 'number' or type(coords.z) ~= 'number' or type(coords.w) ~= 'number' then return false end
    if coords.x < -100000 or coords.x > 100000 or coords.y < -100000 or coords.y > 100000 or coords.z < -1000 or coords.z > 10000 then return false end
    if type(identity) ~= 'table' or type(identity.name) ~= 'string' or #identity.name < 1 or #identity.name > 80 or type(identity.occupation) ~= 'string' or #identity.occupation < 1 or #identity.occupation > 80 then return false end
    if definition.enabled ~= nil and type(definition.enabled) ~= 'boolean' then return false end
    if type(definition.allowedTools) ~= 'table' or #definition.allowedTools > 32 then return false end
    for _, tool in ipairs(definition.allowedTools) do if type(tool) ~= 'string' or #tool < 1 or #tool > 64 or not tool:match('^[%w_%-]+$') then return false end end
    definition.coords = vec4(coords.x, coords.y, coords.z, coords.w)
    return true
end

local function loadCatalog(callback)
    local serverId = GetConvar('peak_ai_npc_server_id', Config.Gateway.serverId or 'local')
    gatewayRequest('/v1/npcs?serverId=' .. urlEncode(serverId), nil, function(ok, response, error)
        if not ok or type(response) ~= 'table' or type(response.npcs) ~= 'table' then
            if error and error ~= 'gateway_secret_missing' then log('catalog load failed: ' .. tostring(error)) end
            callback()
            return
        end
        local loaded = 0
        for _, entry in ipairs(response.npcs) do
            if type(entry) == 'table' and type(entry.id) == 'string' and entry.id:match('^[%w_%-]+$') and validCatalogDefinition(entry.definition) then
                entry.definition.id = entry.id
                AINPCDefinitions[entry.id] = entry.definition
                loaded = loaded + 1
            end
        end
        log(('loaded %s persisted NPC definitions from gateway'):format(loaded))
        callback()
    end, 'GET')
end

local function registerGateway()
    gatewayRequest('/v1/register', {
        serverId = GetConvar('peak_ai_npc_server_id', Config.Gateway.serverId or 'local'),
        name = GetConvar('sv_hostname', 'FiveM server'),
        version = AINPC.Version
    }, function(ok, _, error)
        if not ok then log('gateway registration failed: ' .. tostring(error)) end
    end)
end

local function refreshGatewayCapabilities()
    gatewayRequest('/health', nil, function(ok, response)
        if not ok then
            gatewayCapabilities = { transcription = 'none' }
            return
        end
        gatewayCapabilities = {
            provider = type(response.provider) == 'string' and response.provider or 'unknown',
            speech = type(response.speech) == 'string' and response.speech or 'none',
            transcription = type(response.transcription) == 'string' and response.transcription or 'none',
            vision = type(response.vision) == 'string' and response.vision or 'none'
        }
    end, 'GET')
end

local function gatewayTurn(source, session, text, toolResult, toolDepth, requestId)
    toolDepth = toolDepth or 0
    requestId = requestId or ('%s.turn.%s'):format(session.id, tostring(session.turns))
    local url, secret, serverId = gatewayConfig()
    local requestRevision = session.revision
    local function finish() session.busy = false end
    if secret == '' then finish(); clearProactiveTurn(session, requestRevision); sendState(source, AINPC.State.Error, { message = 'Gateway install token is not configured.' }); return end
    session.gatewayNonce = (session.gatewayNonce or 0) + 1
    local requestNonce = session.gatewayNonce
    local completed = false
    local proactiveTurn = session.proactiveTrigger == true and session.proactiveTurnRevision == requestRevision
    local function recover(message)
        finish()
        session.pendingTool = nil
        clearProactiveTurn(session, requestRevision)
        AINPCSessions.transition(session, 'ready', { sessionRevision = requestRevision })
        sendState(source, AINPC.State.Idle, {
            sessionId = session.id,
            sessionRevision = requestRevision,
            phase = 'ready',
            message = message,
            recoverable = true,
            voiceInputEnabled = Config.VoiceInput.enabled and gatewayCapabilities.transcription ~= 'none'
        })
    end
    local deadline = GetGameTimer() + (Config.Gateway.timeoutMs or 15000)
    local function timeout()
        if completed or AINPCSessions.get(source) ~= session or session.gatewayNonce ~= requestNonce or session.revision ~= requestRevision then return end
        completed = true
        recover('The AI reply took too long. Hold Push-to-Talk to retry or use text.')
    end
    SetTimeout(Config.Gateway.timeoutMs, timeout)
    if AINPCPolice then AINPCPolice.prepareSession(source, session) end
    local toolSchemas = AINPCTools.schemas(session.npc)
    if not next(toolSchemas) then toolSchemas = json.empty_object end
    local payload = json.encode({ serverId = serverId, sessionId = session.id, sessionRevision = requestRevision, turnId = session.turnId, gatewayNonce = requestNonce, requestId = requestId, npc = session.npc, voice = session.npc.voice, context = authoritativeContext(source, session), history = session.history, input = text, allowedTools = session.npc.allowedTools or {}, toolSchemas = toolSchemas, toolResult = toolResult })
    local headers = { ['Content-Type'] = 'application/json', ['X-Peak-License-Key'] = secret, ['X-Peak-Server-Id'] = serverId, ['X-AI-NPC-Secret'] = secret, ['X-AI-NPC-Request-Id'] = requestId }
    local attempts = 0
    local function requestTurn()
    if completed or AINPCSessions.get(source) ~= session or session.gatewayNonce ~= requestNonce or session.revision ~= requestRevision then return end
    if GetGameTimer() >= deadline then timeout(); return end
    local turnRequestId = attempts == 0 and requestId or (requestId .. ':r' .. tostring(attempts))
    local turnPayload = attempts == 0 and payload or json.encode({ serverId = serverId, sessionId = session.id, sessionRevision = requestRevision, turnId = session.turnId, gatewayNonce = requestNonce, requestId = turnRequestId, npc = session.npc, voice = session.npc.voice, context = authoritativeContext(source, session), history = session.history, input = text, allowedTools = session.npc.allowedTools or {}, toolSchemas = toolSchemas, toolResult = toolResult })
    local turnHeaders = { ['Content-Type'] = 'application/json', ['X-Peak-License-Key'] = secret, ['X-Peak-Server-Id'] = serverId, ['X-AI-NPC-Secret'] = secret, ['X-AI-NPC-Request-Id'] = turnRequestId }
    PerformHttpRequest(url .. '/v1/turn', function(status, body)
        if AINPCSessions.get(source) ~= session then return end
        if completed or session.gatewayNonce ~= requestNonce or session.revision ~= requestRevision then return end
        local transient = status <= 0 or status == 408 or status == 425 or status == 429 or status >= 500
        if transient and attempts < 2 and GetGameTimer() + 1000 < deadline then
            attempts = attempts + 1
            local backoffMs = attempts * 1000
            SetTimeout(backoffMs, requestTurn)
            return
        end
        completed = true
        if status < 200 or status >= 300 or not body then
            local gatewayError = 'gateway_http_' .. tostring(status)
            if body then
                local decoded, response = pcall(json.decode, body)
                if decoded and type(response) == 'table' and type(response.error) == 'string' and response.error:match('^[%w_%-]+$') then
                    gatewayError = response.error
                end
            end
            lastGatewayError = gatewayError
            print(('[peak-ai-npc] turn failed source=%s status=%s error=%s'):format(tostring(source), tostring(status), gatewayError))
            if proactiveTurn then
                recover('The NPC did not speak. You can start the conversation normally.')
                return
            end
            if (session.turns or 0) > 0 then
                local recoveryLines = {
                    "Sorry, got distracted for a second—what did you say?",
                    "Sorry, my mind wandered for a moment. Could you repeat that?",
                    "Pardon me, I lost my train of thought. What was that?"
                }
                local recoveryLine = recoveryLines[math.random(1, #recoveryLines)]
                recover(recoveryLine)
                TriggerClientEvent(AINPC.Event.Dialogue, source, {
                    text = recoveryLine,
                    speaker = session.npc.name or 'Resident',
                    subtitleOnly = true
                })
                return
            end
            recover('AI gateway unavailable. Hold Push-to-Talk to retry or use text.'); return
        end
        local ok, response = pcall(json.decode, body)
        if not ok or type(response) ~= 'table' then recover('The AI reply was invalid. Hold Push-to-Talk to retry or use text.'); return end
        local relationship = safeRelationshipSnapshot(response.relationship)
        if relationship then session.relationship = relationship end
        if response.toolCall then
            if toolDepth >= (Config.Gateway.maxToolCallsPerTurn or 1) then finish(); clearProactiveTurn(session, requestRevision); sendState(source, AINPC.State.Error, { message = 'The AI returned an invalid follow-up action.' }); return end
            local invocationId = requestId .. ':tool:' .. tostring(toolDepth) .. ':' .. tostring(response.toolCall.name)
            local toolOk, result = AINPCTools.execute(source, session, response.toolCall.name, response.toolCall.arguments or {}, invocationId)
            if toolOk == nil and type(result) == 'table' and result.pending then
                session.pendingTool = { actionId = result.actionId, requestId = requestId, text = text, toolDepth = toolDepth, name = response.toolCall.name, revision = requestRevision }
                sendState(source, AINPC.State.ActionPending, { message = 'Waiting for the NPC action to finish…' })
                SetTimeout(16000, function()
                    if AINPCSessions.get(source) ~= session or session.revision ~= requestRevision or not session.pendingTool or session.pendingTool.actionId ~= result.actionId then return end
                    session.pendingActions[result.actionId] = nil
                    session.pendingTool = nil
                    AINPCSessions.transition(session, 'deliberating', { sessionRevision = requestRevision })
                    sendState(source, AINPC.State.Deliberating, { message = 'Finishing the response…' })
                    gatewayTurn(source, session, text, { name = response.toolCall.name, result = { ok = false, reason = 'action_ack_timeout' } }, toolDepth + 1, requestId)
                end)
                return
            end
            -- Tool failures are authoritative facts too. Return them to the model so it can
            -- reply in character without ever claiming that a rejected action succeeded.
            if not toolOk then
                log(('tool rejected source=%s tool=%s reason=%s'):format(source, response.toolCall.name, result))
                result = { ok = false, reason = result }
            end
            gatewayTurn(source, session, text, { name = response.toolCall.name, result = result }, toolDepth + 1, requestId)
            return
        end
        local reply = tostring(response.text or 'I cannot answer that right now.'):sub(1, 1200)
        local audio = type(response.audio) == 'table' and response.audio or nil
        local audioUrl = safeAudioUrl(audio and audio.url or response.audioUrl)
        if audio then audio.url = audioUrl end
        local performance = validatedPerformance(session, response.performance)
        local stillValid, invalidReason = validSession(source, session)
        if not stillValid then finish(); clearProactiveTurn(session, requestRevision); AINPCSessions.close(source, invalidReason); return end
        AINPCSessions.transition(session, 'synthesizing', { sessionRevision = requestRevision })
        session.utteranceSequence = (session.utteranceSequence or 0) + 1
        local utteranceId = audio and type(audio.utteranceId) == 'string' and audio.utteranceId or ('%s:u:%s:%s'):format(session.id, requestRevision, session.utteranceSequence)
        if audio then
            audio.utteranceId = utteranceId
            audio.sourceNetworkId = session.entity and session.entity ~= 0 and DoesEntityExist(session.entity) and NetworkGetNetworkIdFromEntity(session.entity) or nil
            audio.maximumDistance = math.min(50.0, tonumber(audio.maximumDistance) or 20.0)
        end
        revealIdentityFromDialogue(session, proactiveTurn and '' or text, reply)
        finish()
        session.utteranceId, session.lastUtteranceId = utteranceId, utteranceId
        AINPCSessions.transition(session, 'speaking', { sessionRevision = requestRevision, utteranceId = utteranceId })
        session.performance = performance
        if not proactiveTurn then appendConversationHistory(session, 'user', text) end
        appendConversationHistory(session, 'assistant', reply)
        clearProactiveTurn(session, requestRevision)
        sendState(source, AINPC.State.Speaking, {
            text = reply,
            audio = audio,
            audioUrl = audioUrl,
            utteranceId = utteranceId,
            performance = performance,
            sourceNetworkId = audio and audio.sourceNetworkId or nil,
            targetServerId = source,
            npcId = session.npcId,
            name = sessionDisplayName(session),
            message = not audioUrl and gatewayCapabilities.speech ~= 'none' and 'NPC voice failed; subtitles are still available.' or nil,
            pendingConfirmation = session.pendingQuote ~= nil,
            audioVolume = 1.0,
            maximumAudibleDistance = 20.0
        })
        sendNearbySpeech(source, session, { text = reply, audio = audio, audioUrl = audioUrl, utteranceId = utteranceId, performance = performance })
    end, 'POST', turnPayload, turnHeaders)
    end
    requestTurn()
end

local function beginAwareTurn(source, session, text, requestId)
    local vision = Config.Vision or {}
    local refreshMs = math.max(5000, (tonumber(vision.refreshSeconds) or 15) * 1000)
    local urgent = session.sceneUrgency and session.sceneUrgency ~= 'normal'
    local needsVision = vision.enabled == true and vision.automaticTurnContext ~= false
        and gatewayCapabilities.vision ~= 'none' and not session.pendingVision
        and (not session.lastVisionAtMs or urgent or GetGameTimer() - session.lastVisionAtMs >= refreshMs)
    if not needsVision then gatewayTurn(source, session, text, nil, nil, requestId); return end

    local revision = session.revision
    local pending = { purpose = 'turn', revision = revision, requestId = requestId, text = text, expiresAt = os.time() + 30 }
    local continued = false
    local function continueTurn()
        if continued then return end
        continued = true
        pending.continued = true
        if session.pendingVision == pending then
            if pending.token then session.ignoredVisionToken = pending.token end
            session.pendingVision = nil
        end
        session.visionRequesting = false
        if AINPCSessions.get(source) ~= session or session.revision ~= revision then return end
        gatewayTurn(source, session, text, nil, nil, requestId)
    end
    pending.continueTurn = continueTurn
    session.pendingVision = pending
    session.visionRequesting = true
    SetTimeout(math.max(3000, tonumber(vision.captureTimeoutMs) or 12000), continueTurn)
    local serverId = GetConvar('peak_ai_npc_server_id', Config.Gateway.serverId or 'local')
    gatewayRequest('/v1/vision/upload-url', { serverId = serverId, sessionId = session.id }, function(ok, response)
        if continued or AINPCSessions.get(source) ~= session or session.revision ~= revision or session.pendingVision ~= pending then return end
        session.visionRequesting = false
        if not ok then continueTurn(); return end
        local token = type(response.token) == 'string' and response.token or ''
        local uploadUrl = type(response.uploadUrl) == 'string' and response.uploadUrl or ''
        if #token < 40 or #token > 64 or not token:match('^[%w_-]+$')
            or #uploadUrl < 8 or #uploadUrl > 2048 or not uploadUrl:match('^https?://') then continueTurn(); return end
        pending.token = token
        pending.expiresAt = os.time() + 25
        pending.prompt = 'Ignore all overlay panels, subtitles, prompts, and written UI text. In one compact sentence of at most 45 words, describe only visible world facts relevant to the NPC and interacting player: immediate actions, threats, injuries, vehicles, nearby people, and location cues. Do not infer identity, intent, permissions, or hidden state.'
        TriggerClientEvent(AINPC.Event.CaptureVision, source, session.id, token, uploadUrl)
    end)
end

local function activateSession(source, session, payload, proactive)
    if proactive ~= true then
        sendState(source, AINPC.State.Idle, payload)
        return
    end
    local valid, reason = validSession(source, session)
    if not valid then
        AINPCSessions.close(source, reason)
        rejectProactiveStart(source, session.startId)
        return
    end
    recordProactiveStart(source, session.npcId)
    AINPCSessions.touch(session)
    local requestId = ('%s:proactive:%s'):format(session.id, GetGameTimer())
    AINPCSessions.beginTurn(session, requestId)
    session.proactiveTrigger = true
    session.proactiveTurnRevision = session.revision
    payload.sessionRevision = session.revision
    payload.turnId = session.turnId
    payload.message = 'The NPC noticed you nearby…'
    payload.phase = 'deliberating'
    sendState(source, AINPC.State.Thinking, payload)
    local revision = session.revision
    SetTimeout(450, function()
        if AINPCSessions.get(source) ~= session or session.revision ~= revision
            or session.proactiveTurnRevision ~= revision then return end
        beginAwareTurn(source, session, '[Nearby presence event; the player has not spoken.]', requestId)
    end)
end

RegisterNetEvent(AINPC.Event.Begin, function(npcId, entity, startId, proactive)
    local source = source
    if type(npcId) ~= 'string' or type(entity) ~= 'number' or (proactive ~= nil and type(proactive) ~= 'boolean') then return end
    if rejectRateLimited(source) then return end
    if not proactiveStartAllowed(source, npcId, proactive) then rejectProactiveStart(source, startId); return end
    local record = AINPCServerEntities and AINPCServerEntities.records[npcId]
    if record and record.ped and DoesEntityExist(record.ped) then
        local playerBucketOk, playerBucket = pcall(GetPlayerRoutingBucket, source)
        local entityBucketOk, entityBucket = pcall(GetEntityRoutingBucket, record.ped)
        -- A server-owned entity is authoritative only inside the same instance.
        -- Other buckets use the definition's server-authored coordinates and a
        -- local visual fallback. The client-supplied handle is never trusted.
        entity = playerBucketOk and entityBucketOk and playerBucket == entityBucket and record.ped or nil
    else
        entity = nil
    end
    if AINPCDiagnostics then AINPCDiagnostics.record('binding_start', { residentId = npcId, generation = startId }, entity) end
    local session, reason = AINPCSessions.create(source, npcId, entity)
    if not session then if AINPCDiagnostics then AINPCDiagnostics.record('binding_failed', { generation = startId }, entity) end; sendState(source, AINPC.State.Error, { message = reason }); return end
    session.startId = startId
    local valid, distanceReason = validSession(source, session)
    if not valid then AINPCSessions.close(source); if AINPCDiagnostics then AINPCDiagnostics.record('binding_failed', { generation = startId }, entity) end; sendState(source, AINPC.State.Error, { message = distanceReason }); return end
    if AINPCBehavior then AINPCBehavior.sessionStarted(source, session) end
    if AINPCDiagnostics then AINPCDiagnostics.record('binding_ready', { sessionId = session.id, residentId = session.npc.id, generation = startId }, session.entity) end
    activateSession(source, session, {
        sessionId = session.id,
        startId = startId,
        sessionRevision = session.revision,
        npcId = npcId,
        name = session.npc.identity and session.npc.identity.name or npcId,
        occupation = session.npc.identity and session.npc.identity.occupation or 'Conversation',
        voiceInputEnabled = Config.VoiceInput.enabled and gatewayCapabilities.transcription ~= 'none'
    }, proactive)
end)

RegisterNetEvent(AINPC.Event.BeginAmbient, function(netId, startId, proactive)
    local source = source
    if proactive ~= nil and type(proactive) ~= 'boolean' then return end
    if rejectRateLimited(source) then return end
    if AINPCSessions.get(source) or pendingStarts[source] then return end
    local npc, pedOrReason = AINPCAmbient.resolve(source, netId)
    if AINPCDiagnostics then AINPCDiagnostics.record('binding_start', { generation = startId }, type(pedOrReason) == 'number' and pedOrReason or nil) end
    if not npc then if AINPCDiagnostics then AINPCDiagnostics.record('binding_failed', { generation = startId }, type(pedOrReason) == 'number' and pedOrReason or nil) end; sendState(source, AINPC.State.Error, { message = pedOrReason or 'ambient_npc_unavailable' }); return end
    if not proactiveStartAllowed(source, npc.id, proactive) then rejectProactiveStart(source, startId); return end
    local player = framework.getPlayer(source)
    local characterId = framework.getCharacterId(player)
    if Config.Residents.enabled and npc.residentCandidate and type(characterId) == 'string' and characterId ~= '' then
        local start = { id = startId }
        pendingStarts[source] = start
        AINPCResidents.resolve(source, npc, characterId, function(ok, resolved, error)
            if pendingStarts[source] ~= start then return end
            pendingStarts[source] = nil
            if not ok or not resolved then if AINPCDiagnostics then AINPCDiagnostics.record('binding_failed', { generation = startId }, type(pedOrReason) == 'number' and pedOrReason or nil) end; sendState(source, AINPC.State.Error, { message = error or 'resident_resolution_failed' }); return end
            local current, entity = AINPCAmbient.resolve(source, netId)
            if not current or current.id ~= npc.id or (not npc.localEntity and entity ~= pedOrReason) then
                if AINPCDiagnostics then AINPCDiagnostics.record('binding_failed', { generation = startId }, type(pedOrReason) == 'number' and pedOrReason or nil) end; sendState(source, AINPC.State.Error, { message = 'resident_resolution_stale' }); return
            end
            -- Keep the original population ped in place. A client-local ambient
            -- entity cannot be safely promoted in-place by this resource; the
            -- bounded fallback still supports dialogue and persistent identity,
            -- while gameplay tools remain disabled for local entities.
            resolved.npc.localEntity = true
            resolved.npc.originalEntity = true
            resolved.npc.entityNetId = nil
            if not npc.localEntity then
                resolved.npc.localEntity = nil
                resolved.npc.entityNetId = npc.entityNetId
                resolved.npc.bindingIdentity = npc.id
            end
            resolved.npc.coords = current.coords
            local session, reason = AINPCSessions.createResolved(source, resolved.npc, npc.localEntity and nil or pedOrReason)
            if not session then if AINPCDiagnostics then AINPCDiagnostics.record('binding_failed', { generation = startId }, type(pedOrReason) == 'number' and pedOrReason or nil) end; sendState(source, AINPC.State.Error, { message = reason }); return end
            session.startId = startId
            session.characterId = characterId
            session.identityRevealed = resolved.knowledge.knownNameAt ~= nil
            session.playerNameKnown = resolved.knowledge.playerNameKnownAt ~= nil
            -- Binding an original population entity grants no ownership of its tasks.
            if AINPCDiagnostics then AINPCDiagnostics.record('binding_ready', { sessionId = session.id, residentId = session.npc.id, generation = startId }, session.entity) end
            activateSession(source, session, {
                startId = startId, sessionId = session.id, npcId = resolved.npc.id, residentId = resolved.npc.id,
                sessionRevision = session.revision,
                name = sessionDisplayName(session), occupation = resolved.npc.identity.occupation,
                entityNetId = resolved.npc.entityNetId,
                voiceInputEnabled = Config.VoiceInput.enabled and gatewayCapabilities.transcription ~= 'none'
            }, proactive)
        end)
        return
    end
    local session, reason = AINPCSessions.createResolved(source, npc, pedOrReason)
    if not session then if AINPCDiagnostics then AINPCDiagnostics.record('binding_failed', { generation = startId }, type(pedOrReason) == 'number' and pedOrReason or nil) end; sendState(source, AINPC.State.Error, { message = reason }); return end
    session.startId = startId
    -- Preserve ambient scenarios, heading and occupied seats on contact.
    if AINPCDiagnostics then AINPCDiagnostics.record('binding_ready', { sessionId = session.id, residentId = session.npc.id, generation = startId }, session.entity) end
    activateSession(source, session, {
        startId = startId, sessionId = session.id, npcId = npc.id, name = sessionDisplayName(session), occupation = npc.identity.occupation,
        sessionRevision = session.revision,
        entityNetId = npc.entityNetId, voiceInputEnabled = Config.VoiceInput.enabled and gatewayCapabilities.transcription ~= 'none'
    }, proactive)
end)

RegisterNetEvent(AINPC.Event.Message, function(sessionId, text, requestId)
    local source = source
    local session = AINPCSessions.get(source)
    if type(text) ~= 'string' or #text < 1 or #text > 500 or type(requestId) ~= 'string' or #requestId < 8 or #requestId > 160 or not requestId:match('^[%w%._:%-]+$') then return end
    if not session or session.id ~= sessionId then return end
    if rejectRateLimited(source) then return end
    if session.busy and session.phase ~= 'capturing' then sendState(source, AINPC.State.Error, { message = 'Please wait for the current reply.' }); return end
    if session.requestIds[requestId] then sendState(source, AINPC.State.Error, { message = 'That request was already received.' }); return end
    session.requestIds[requestId] = true
    session.requestOrder[#session.requestOrder + 1] = requestId
    if #session.requestOrder > 64 then session.requestIds[table.remove(session.requestOrder, 1)] = nil end
    local valid, reason = validSession(source, session)
    if not valid then sendState(source, AINPC.State.Error, { message = reason }); AINPCSessions.close(source); return end
    AINPCSessions.touch(session)
    applyTreatmentReaction(source, session, text)
    if session.npc.kind == 'resident' and not session.playerNameKnown and playerIntroducedThemself(text) then
        session.playerNameKnown = true
        AINPCResidents.noteMeeting(session, true)
    end
    AINPCSessions.beginTurn(session, requestId)
    sendState(source, AINPC.State.Thinking, { phase = 'deliberating' })
    beginAwareTurn(source, session, text, requestId)
end)

RegisterNetEvent(AINPC.Event.Transcribe, function(sessionId, audioDataUrl, language, expectedRevision, captureGeneration)
    local source = source
    if not Config.VoiceInput.enabled or type(sessionId) ~= 'string' or type(audioDataUrl) ~= 'string' or #audioDataUrl > Config.VoiceInput.maximumDataUrlBytes or not audioDataUrl:match('^data:audio/[%w%+%.%-]+;base64,') or (language ~= nil and type(language) ~= 'string') then return end
    local session = AINPCSessions.get(source)
    if not session or session.id ~= sessionId then return end
    if type(expectedRevision) ~= 'number' or expectedRevision ~= math.floor(expectedRevision)
        or expectedRevision < 1 or expectedRevision > 2147483647 or expectedRevision ~= session.revision
        or type(captureGeneration) ~= 'number' or captureGeneration ~= math.floor(captureGeneration)
        or captureGeneration < 1 or captureGeneration > 2147483647
        or captureGeneration <= (session.lastCaptureGeneration or 0) then return end
    if rejectRateLimited(source) then return end
    if session.busy and session.phase ~= 'capturing' then sendState(source, AINPC.State.Error, { message = 'Please wait for the current reply.' }); return end
    local valid, reason = validSession(source, session)
    if not valid then sendState(source, AINPC.State.Error, { message = reason }); AINPCSessions.close(source); return end
    session.lastCaptureGeneration = captureGeneration
    AINPCSessions.touch(session)
    session.revision = (session.revision or 0) + 1
    session.turnId = ('%s:voice:%s'):format(session.id, session.revision)
    session.gatewayNonce = (session.gatewayNonce or 0) + 1
    session.phase, session.busy = 'transcribing', true
    local transcriptionRevision = session.revision
    sendState(source, AINPC.State.Thinking, { message = 'Transcribing voice…', phase = 'transcribing' })
    gatewayRequest('/v1/transcribe', {
        serverId = GetConvar('peak_ai_npc_server_id', 'local'),
        sessionId = session.id,
        audioDataUrl = audioDataUrl,
        language = language
    }, function(ok, response, error)
        if AINPCSessions.get(source) ~= session or session.revision ~= transcriptionRevision then return end
        local stillValid, invalidReason = validSession(source, session)
        if not stillValid then
            sendState(source, AINPC.State.Error, { message = invalidReason })
            AINPCSessions.close(source, invalidReason)
            return
        end
        if not ok or type(response.text) ~= 'string' or #response.text < 1 or #response.text > 500 then
            session.busy = false
            local errMessage = 'Voice transcription failed. You can still type your message.'
            if error == 'audio_too_short' or error == 'empty_transcript' then
                errMessage = 'No clear speech was detected. Check your FiveM microphone, then try again or use text.'
            elseif error == 'invalid_audio' or error == 'invalid_audio_size' or error == 'stt_http_400' or error == 'stt_http_413' then
                errMessage = 'The voice recording could not be read. Try speaking again or use text.'
            elseif error == 'transcription_not_configured' or error == 'stt_http_503' then
                errMessage = 'Voice transcription is unavailable on the server. Please use text.'
            end
            sendState(source, AINPC.State.Idle, {
                sessionId = session.id,
                npcId = session.npcId,
                name = sessionDisplayName(session),
                occupation = session.npc.identity and session.npc.identity.occupation or 'Conversation',
                voiceInputEnabled = Config.VoiceInput.enabled and gatewayCapabilities.transcription ~= 'none',
                message = errMessage
            })
            return
        end
        local transcript = response.text
        applyTreatmentReaction(source, session, transcript)
        local requestId = session.turnId
        session.phase, session.busy = 'deliberating', true
        sendState(source, AINPC.State.Thinking, { transcript = transcript })
        beginAwareTurn(source, session, transcript, requestId)
    end)
end)

RegisterNetEvent(AINPC.Event.SceneObservation, function(sessionId, observation)
    local source = source
    local session = AINPCSessions.get(source)
    if not session or session.id ~= sessionId or not validSceneObservation(observation) then return end
    local now = GetGameTimer()
    if session.lastSceneObservationAt and now - session.lastSceneObservationAt < 1000 then return end
    updateLocalObservedNpc(source, session, observation)
    local valid = validSession(source, session)
    if not valid then return end
    -- This is deliberately labeled and stored separately from server facts. It can
    -- guide dialogue but can never authorize tools, money, inventory, or permissions.
    session.lastSceneObservationAt = now
    session.sceneObservation = observation
    local player, npc = observation.player, observation.npc
    if type(npc) == 'table' and (npc.inCombatWithPlayer == true or npc.combatTargetIsPlayer == true
        or npc.isShooting == true or npc.inMelee == true) then
        session.sceneUrgency = 'active_combat'
    elseif type(npc) == 'table' and npc.recentlyDamagedByPlayer == true then
        session.sceneUrgency = 'recent_assault'
    elseif type(player) == 'table' and (player.aimingAtNpc == true or player.isShooting == true) then
        session.sceneUrgency = 'weapon_threat'
    elseif type(player) == 'table' and (player.injured == true or player.onFire == true or player.stunned == true) then
        session.sceneUrgency = 'player_distress'
    else
        session.sceneUrgency = 'normal'
    end
    -- Untrusted scene data can request only a bounded reversible presentation
    -- response. The behavior module cannot turn it into combat or durable state.
    if AINPCBehavior then AINPCBehavior.observePresentation(source, session, observation) end
end)

local peakShopRobberySessions = {}

local function notifyShopRobbery(source, reason)
    local messages = {
        firearm_required = 'Aim an owned firearm at the clerk.',
        equipped_firearm_not_owned = 'The equipped firearm could not be verified.',
        not_enough_police = 'There are not enough officers on duty for a store robbery.',
        shop_robbery_active = 'Someone is already robbing this store.',
        shop_on_cooldown = 'This store was recently robbed.',
        register_unavailable = 'The register is already empty.',
        request_rate_limited = 'Wait before threatening the clerk again.',
        too_far = 'Move closer to the clerk.'
    }
    TriggerClientEvent('peak_ai_npc:client:notify', source, messages[reason] or 'The store robbery could not start.')
end

local function nearbyShopClients(source, coords)
    local result, bucket = {}, GetPlayerRoutingBucket(source)
    local origin = vec3(coords.x, coords.y, coords.z)
    for _, value in ipairs(GetPlayers()) do
        local target = tonumber(value)
        local ped = target and GetPlayerPed(target) or 0
        if target and ped ~= 0 and GetPlayerRoutingBucket(target) == bucket
            and #(GetEntityCoords(ped) - origin) <= (Config.ShopRobbery.broadcastDistance or 80.0) then
            result[#result + 1] = target
        end
    end
    return result
end

local function sendShopReaction(source, reaction, reset)
    local payload = {
        kind = reaction.kind, npcId = reaction.npcId, shopId = reaction.shopId,
        reactionId = reaction.reactionId, response = reaction.response,
        weapon = reaction.weapon, line = reaction.line, durationMs = reaction.durationMs,
        robberSource = source, reset = reset == true
    }
    if reaction.kind == 'managed' then
        local target = source
        local record = reaction.npcId and AINPCServerEntities and AINPCServerEntities.records[reaction.npcId]
        if record and record.ped and DoesEntityExist(record.ped) then
            local ownerOk, owner = pcall(NetworkGetEntityOwner, record.ped)
            if ownerOk and type(owner) == 'number' and owner > 0 then target = owner end
        end
        TriggerClientEvent(AINPC.Event.ShopRobberyReaction, target, payload)
    else
        for _, target in ipairs(nearbyShopClients(source, reaction.coords)) do
            TriggerClientEvent(AINPC.Event.ShopRobberyReaction, target, payload)
        end
    end
end

RegisterNetEvent(AINPC.Event.ShopThreat, function(request)
    local source = source
    if not Config.ShopRobbery.enabled or type(request) ~= 'table'
        or (request.kind ~= 'managed' and request.kind ~= 'qb_shop')
        or GetResourceState('qb-storerobbery') ~= 'started' then return end

    local shopId, npcId
    if request.kind == 'managed' then
        npcId = request.npcId
        if type(npcId) ~= 'string' or not npcId:match('^[%w_%-]+$') then return end
        local npc = AINPCDefinitions[npcId]
        local robbery = npc and npc.shop and npc.shop.robbery
        local record = AINPCServerEntities and AINPCServerEntities.records[npcId]
        if not npc or not robbery or robbery.enabled == false or not record or not record.ped
            or not DoesEntityExist(record.ped)
            or GetPlayerRoutingBucket(source) ~= GetEntityRoutingBucket(record.ped) then return end
        local player = GetPlayerPed(source)
        if player == 0 or #(GetEntityCoords(player) - GetEntityCoords(record.ped))
            > (Config.ShopRobbery.maximumDistance or 4.0) then return end
        shopId = npc.shop.id
    else
        shopId = request.shopId
        if type(shopId) ~= 'string' or not shopId:match('^[%w_%-]+$')
            or GetResourceState('qb-shops') ~= 'started' then return end
        local invoked, eligible, reason = pcall(function()
            return exports['qb-shops']:ValidateShopkeeperThreat(source, shopId)
        end)
        if not invoked or not eligible then notifyShopRobbery(source, reason); return end
    end
    if type(shopId) ~= 'string' or not shopId:match('^[%w_%-]+$') then return end

    local invoked, started, result = pcall(function()
        return exports['qb-storerobbery']:StartClerkRobbery(source, shopId)
    end)
    if not invoked or not started or type(result) ~= 'table' then
        notifyShopRobbery(source, invoked and result or 'bridge_unavailable')
        return
    end
    local shop = result.shop
    if type(shop) ~= 'table' or type(shop.coords) ~= 'table' then return end
    local reaction = {
        kind = request.kind, npcId = npcId, shopId = shopId,
        reactionId = result.reactionId, response = result.response,
        weapon = result.weapon, line = result.line, durationMs = result.durationMs,
        coords = shop.coords
    }
    if npcId and AINPCBehavior then AINPCBehavior.hold(npcId, result.durationMs, source) end
    sendShopReaction(source, reaction, false)
    if type(result.token) == 'string' then
        peakShopRobberySessions[result.token] = {
            source = source, reaction = reaction,
            expiresAt = GetGameTimer() + result.durationMs + 15000
        }
        TriggerClientEvent(AINPC.Event.ShopRobberyProgress, source, {
            token = result.token, durationMs = result.durationMs, label = shop.label
        })
    end
    TriggerEvent(Config.ShopRobbery.event or 'peak_ai_npc:server:shopRobberyResolved', {
        source = source, npcId = npcId, shopId = shopId,
        response = result.response, coords = shop.coords
    })
    if Config.Security.auditWriteTools then
        print(('[peak-ai-npc][audit] shop_threat source=%s kind=%s shop=%s response=%s'):format(
            source, request.kind, shopId, result.response
        ))
    end
end)

RegisterNetEvent(AINPC.Event.ShopRobberyComplete, function(token, completed)
    local source = source
    if type(token) ~= 'string' or #token < 8 or #token > 160 or type(completed) ~= 'boolean' then return end
    local tracked = peakShopRobberySessions[token]
    if not tracked or tracked.source ~= source then return end
    peakShopRobberySessions[token] = nil
    local invoked, ok, result
    if completed then
        invoked, ok, result = pcall(function()
            return exports['qb-storerobbery']:CompleteClerkRobbery(source, token)
        end)
        if not invoked or not ok then
            pcall(function() exports['qb-storerobbery']:CancelClerkRobbery(source, token, result or 'completion_failed') end)
        end
    else
        invoked, ok, result = pcall(function()
            return exports['qb-storerobbery']:CancelClerkRobbery(source, token, 'player_cancelled')
        end)
        result = ok and 'cancelled' or result
    end
    sendShopReaction(source, tracked.reaction, true)
    TriggerClientEvent(AINPC.Event.ShopRobberyResult, source, invoked and ok, result, invoked and ok and result or nil)
end)

RegisterNetEvent(AINPC.Event.Confirm, function(sessionId, quoteId)
    local source = source
    local session = AINPCSessions.get(source)
    if not session or session.id ~= sessionId then return end
    if session.busy then return end
    local valid, reason = validSession(source, session)
    if not valid then sendState(source, AINPC.State.Error, { message = reason }); return end
    if not session.pendingQuote or session.pendingQuote.id ~= quoteId then sendState(source, AINPC.State.Error, { message = 'There is no matching purchase waiting for confirmation.' }); return end
    session.purchaseConfirmed = quoteId
    local ok, result = AINPCTools.execute(source, session, 'confirm_purchase', {})
    if not ok then
        session.purchaseConfirmed = false
        local explanations = {
            insufficient_cash = 'You do not have enough cash for this purchase.',
            inventory_full = 'Your inventory does not have enough space.',
            item_grant_failed = 'That item is not available in the server inventory.',
            out_of_stock = 'That item is out of stock.'
        }
        sendState(source, AINPC.State.Error, { message = explanations[result] or 'The purchase could not be completed.', reason = result })
        return
    end
    local message
    if result and result.ok then
        local rawItem = tostring(result.item or '')
        local cleanItem = rawItem:gsub('_', ' ')
        local qty = tonumber(result.quantity) or 1
        local total = tostring(result.total or '0')
        local qtyPrefix = qty > 1 and (tostring(qty) .. ' ') or ''
        local replies = {
            ("Here you go! %s%s for $%s. Thanks for stopping by!"):format(qtyPrefix, cleanItem, total),
            ("All set, got your %s%s right here for $%s. Have a good one!"):format(qtyPrefix, cleanItem, total),
            ("There you are—%s%s. That'll be $%s. Appreciate your business!"):format(qtyPrefix, cleanItem, total),
        }
        message = result.kind == 'sell' and ('I bought your %s%s for $%s.'):format(qtyPrefix, cleanItem, total) or replies[math.random(#replies)]
    else
        message = 'Sorry about that, looks like I can’t complete that purchase right now.'
    end
    fixedSpeech(source, session, message, { transaction = result })
end)

RegisterNetEvent(AINPC.Event.RequestVision, function(sessionId, prompt)
    local source = source
    if not Config.Vision.enabled or type(prompt) ~= 'string' or #prompt < 1 or #prompt > Config.Vision.maximumPromptLength then return end
    local session = AINPCSessions.get(source)
    if not session or session.id ~= sessionId then return end
    if rejectRateLimited(source) then return end
    if session.busy or session.visionRequesting then sendState(source, AINPC.State.Error, { message = 'Please wait for the current request.' }); return end
    local valid, reason = validSession(source, session)
    if not valid then sendState(source, AINPC.State.Error, { message = reason }); return end
    if session.pendingVision and session.pendingVision.expiresAt >= os.time() then
        sendState(source, AINPC.State.Error, { message = 'Scene analysis is already pending.' })
        return
    end
    session.visionRequesting = true
    local serverId = GetConvar('peak_ai_npc_server_id', Config.Gateway.serverId or 'local')
    gatewayRequest('/v1/vision/upload-url', { serverId = serverId, sessionId = session.id }, function(ok, response, error)
        if AINPCSessions.get(source) ~= session then return end
        session.visionRequesting = false
        if not ok then sendState(source, AINPC.State.Error, { message = error or 'Vision upload unavailable.' }); return end
        local token = type(response.token) == 'string' and response.token or ''
        local uploadUrl = type(response.uploadUrl) == 'string' and response.uploadUrl or ''
        if #token < 40 or #token > 64 or not token:match('^[%w_-]+$') or #uploadUrl < 8 or #uploadUrl > 2048 or not uploadUrl:match('^https?://') then
            sendState(source, AINPC.State.Error, { message = 'Vision upload response was invalid.' })
            return
        end
        local stillValid, currentReason = validSession(source, session)
        if not stillValid or session.busy then sendState(source, AINPC.State.Error, { message = currentReason or 'Please wait for the current reply.' }); return end
        session.pendingVision = { token = token, prompt = prompt, expiresAt = os.time() + 25 }
        TriggerClientEvent(AINPC.Event.CaptureVision, source, session.id, token, uploadUrl)
    end)
end)

RegisterNetEvent(AINPC.Event.VisionUploaded, function(sessionId, token, uploaded)
    local source = source
    if not Config.Vision.enabled or type(token) ~= 'string' or #token < 40 or #token > 64 or not token:match('^[%w_-]+$') or type(uploaded) ~= 'boolean' then return end
    local session = AINPCSessions.get(source)
    if not session or session.id ~= sessionId then return end
    local pending = session.pendingVision
    if (not pending or pending.token ~= token) and session.ignoredVisionToken == token then
        session.ignoredVisionToken = nil
        return
    end
    if not pending or pending.token ~= token or pending.expiresAt < os.time() then
        if pending and pending.purpose == 'turn' and pending.continueTurn then pending.continueTurn()
        else sendState(source, AINPC.State.Error, { message = 'Scene analysis expired. Try again.' }) end
        return
    end
    session.pendingVision = nil
    if not uploaded then
        if pending.purpose == 'turn' and pending.continueTurn then pending.continueTurn()
        else sendState(source, AINPC.State.Error, { message = 'Scene analysis failed. Text conversation is still available.' }) end
        return
    end
    if session.busy and pending.purpose ~= 'turn' then sendState(source, AINPC.State.Error, { message = 'Please wait for the current reply.' }); return end
    local valid, reason = validSession(source, session)
    if not valid then sendState(source, AINPC.State.Error, { message = reason }); return end
    session.busy = true
    gatewayRequest('/v1/vision/from-upload', {
        serverId = GetConvar('peak_ai_npc_server_id', Config.Gateway.serverId or 'local'),
        sessionId = session.id,
        token = token,
        prompt = pending.prompt
    }, function(ok, response, error)
        if AINPCSessions.get(source) ~= session then return end
        if pending.purpose == 'turn' then
            if pending.continued or session.revision ~= pending.revision then return end
            if ok and response and response.text then
                session.lastVision = { description = tostring(response.text):sub(1, 2000), capturedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'), urgency = session.sceneUrgency or 'normal' }
                session.lastVisionAtMs = GetGameTimer()
            end
            if pending.continueTurn then pending.continueTurn() end
            return
        end
        session.busy = false
        if not ok or not response or not response.text then sendState(source, AINPC.State.Error, { message = error or 'Vision analysis failed.' }); return end
        session.lastVision = { description = tostring(response.text):sub(1, 2000), capturedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'), urgency = session.sceneUrgency or 'normal' }
        session.lastVisionAtMs = GetGameTimer()
        sendState(source, AINPC.State.Idle, { sessionId = session.id, npcId = session.npcId, vision = session.lastVision })
    end)
end)

RegisterNetEvent(AINPC.Event.ActionLifecycle, function(sessionRevision, actionId, phase, code)
    local source = source
    if type(sessionRevision) ~= 'number' or type(actionId) ~= 'string' or #actionId > 200 or type(phase) ~= 'string' then return end
    local session = AINPCSessions.get(source)
    if not session then
        -- During barge-in / revision increments, actions can arrive shortly after
        -- the revision rolls over. Fall back to scanning the session by revision.
        for _, candidate in pairs(AINPCSessions.bySource) do
            if candidate.revision == sessionRevision and candidate.pendingActions and candidate.pendingActions[actionId] then session = candidate break end
        end
    end
    if not session then return end
    local valid, reason = validSession(session.source, session)
    if not valid then AINPCSessions.close(session.source, reason); return end
    local ok, pending = AINPCTools.ack(source, session, sessionRevision, actionId, phase, code)
    if not ok or phase == 'started' or phase == 'start' then return end
    local context = session.pendingTool
    if not context or context.actionId ~= actionId or context.revision ~= sessionRevision then return end
    session.pendingTool = nil
    AINPCSessions.transition(session, 'deliberating', { sessionRevision = sessionRevision })
    sendState(session.source, AINPC.State.Deliberating, { message = 'Finishing the response…' })
    local result = pending.ok and { ok = true, action = pending.action, actionId = actionId }
        or { ok = false, reason = pending.code or 'action_failed', action = pending.action, actionId = actionId }
    gatewayTurn(session.source, session, context.text, { name = context.name, result = result }, context.toolDepth + 1, context.requestId)
end)

RegisterNetEvent(AINPC.Event.AudioLifecycle, function(sessionRevision, utteranceId, phase, code)
    local source = source
    if type(sessionRevision) ~= 'number' or type(utteranceId) ~= 'string' or #utteranceId > 200 or type(phase) ~= 'string' then return end
    local session = AINPCSessions.get(source)
    if not session or session.revision ~= sessionRevision or session.utteranceId ~= utteranceId then return end
    local valid, reason = validSession(source, session)
    if not valid then AINPCSessions.close(source, reason); return end
    if phase == 'started' or phase == 'start' then
        AINPCSessions.transition(session, 'speaking', { sessionRevision = sessionRevision, utteranceId = utteranceId })
        local performance = session.performance or { emotion = 'neutral', deliveryPreset = 'neutral' }
        if AINPCBehavior and not session.npc.originalEntity and not session.npc.localEntity and session.npc.kind ~= 'ambient' then AINPCBehavior.push(source, session, { mode = 'face', facial = performance.emotion == 'warm' and 'happy' or performance.emotion == 'stern' and 'angry' or performance.emotion == 'nervous' and 'stressed' or 'neutral', priority = 60, targetServerId = source, durationMs = 15000, reason = 'speaking:' .. performance.deliveryPreset }) end
    elseif phase == 'ended' or phase == 'end' or phase == 'error' then
        session.utteranceId = nil
        session.performance = nil
        AINPCSessions.transition(session, 'ready', { sessionRevision = sessionRevision })
        if AINPCBehavior then AINPCBehavior.clearSession(source, session) end
        if phase == 'error' and type(code) == 'string' then log(('audio error source=%s code=%s'):format(source, code:sub(1, 64))) end
        sendState(source, AINPC.State.Idle, { sessionId = session.id, sessionRevision = session.revision, phase = 'ready' })
    end
end)

RegisterNetEvent(AINPC.Event.BargeIn, function(sessionId, sessionRevision, utteranceId, captureGeneration)
    local source = source
    if type(captureGeneration) ~= 'number' or captureGeneration < 1 or captureGeneration > 2147483647 or captureGeneration % 1 ~= 0 then return end
    local session, reason = AINPCSessions.current(source, sessionId, sessionRevision)
    if not session then return end
    local valid, invalidReason = validSession(source, session)
    if not valid then AINPCSessions.close(source, invalidReason); return end
    if session.phase ~= 'speaking' or session.utteranceId ~= utteranceId then
        -- Speech already concluded; seamlessly accept capture
        session.phase, session.busy = 'capturing', true
        sendState(source, AINPC.State.Capturing, { sessionId = session.id, interruptedRevision = session.revision, interruptedUtteranceId = utteranceId, bargeCaptureGeneration = captureGeneration })
        return
    end
    local oldRevision = session.revision
    local stopPayload = { npcId = session.npcId, sessionRevision = oldRevision, utteranceId = utteranceId, reason = 'barge_in', fadeMs = 150 }
    local origin = session.entity and session.entity ~= 0 and DoesEntityExist(session.entity) and GetEntityCoords(session.entity) or GetEntityCoords(GetPlayerPed(source))
    local bucket = GetPlayerRoutingBucket(source)
    for _, value in ipairs(GetPlayers()) do
        local target = tonumber(value)
        local ped = target and GetPlayerPed(target) or 0
        if target and ped ~= 0 and DoesEntityExist(ped) and GetPlayerRoutingBucket(target) == bucket
            and #(GetEntityCoords(ped) - origin) <= 20.0 then TriggerClientEvent(AINPC.Event.StopUtterance, target, stopPayload) end
    end
    AINPCSessions.invalidate(session, 'barge_in')
    session.phase, session.busy = 'capturing', true
    sendState(source, AINPC.State.Capturing, { sessionId = session.id, interruptedRevision = oldRevision, interruptedUtteranceId = utteranceId, bargeCaptureGeneration = captureGeneration })
end)

RegisterNetEvent(AINPC.Event.End, function(sessionId, startId)
    local source = source
    if sessionId == nil and pendingStarts[source] and pendingStarts[source].id == startId then
        pendingStarts[source] = nil
        if AINPCResidents then AINPCResidents.pending[source] = nil end
    end
    local session = AINPCSessions.get(source)
    if session and (session.id == sessionId or (sessionId == nil and startId ~= nil and session.startId == startId)) then
        if AINPCDiagnostics then AINPCDiagnostics.record('session_end', { sessionId = session.id, residentId = session.npcId, generation = session.startId }, session.entity) end
        AINPCSessions.close(source, 'ended'); sendState(source, AINPC.State.Idle, { startId = session.startId })
    end
end)

AddEventHandler('playerDropped', function()
    local session = AINPCSessions.get(source)
    if session and AINPCDiagnostics then AINPCDiagnostics.record('session_end', { sessionId = session.id, residentId = session.npcId, generation = session.startId }, session.entity) end
    pendingStarts[source] = nil
    if AINPCResidents then AINPCResidents.cancelSource(source) end
    AINPCSessions.close(source, 'disconnect'); AINPCMissions.cancelSource(source); requestBuckets[source] = nil
    proactivePlayerCooldowns[source] = nil
    for token, tracked in pairs(peakShopRobberySessions) do
        if tracked.source == source then peakShopRobberySessions[token] = nil end
    end
end)

CreateThread(function()
    while true do
        Wait(5000)
        local now = GetGameTimer()
        for token, tracked in pairs(peakShopRobberySessions) do
            if tracked.expiresAt <= now then peakShopRobberySessions[token] = nil end
        end
        local proactiveRetention = math.max(60000, ((Config.Proactive and tonumber(Config.Proactive.npcCooldownSeconds)) or 180) * 2000)
        for npcId, lastAt in pairs(proactiveNpcCooldowns) do
            if now - lastAt > proactiveRetention then proactiveNpcCooldowns[npcId] = nil end
        end
    end
end)

RegisterCommand('ainpc_status', function(source)
    if source ~= 0 and not IsPlayerAceAllowed(source, 'ainpc.admin') then return end
    local report = {
        version = AINPC.Version,
        framework = framework and framework.name or 'initializing',
        inventory = AINPCAdapters.inventory(),
        target = detectedTarget(),
        oneSync = GetConvar('onesync', 'off'),
        screenshotBasic = GetResourceState(Config.Vision.screenshotBasicResource),
        configuredNpcs = 0,
        activeSessions = 0,
        residents = AINPCResidents.status(),
        gateway = 'checking',
        lastGatewayError = lastGatewayError
    }
    for _ in pairs(AINPCDefinitions) do report.configuredNpcs = report.configuredNpcs + 1 end
    for _ in pairs(AINPCSessions.bySource) do report.activeSessions = report.activeSessions + 1 end
    gatewayRequest('/health', nil, function(ok, response, error)
        if ok then
            gatewayCapabilities.transcription = type(response.transcription) == 'string' and response.transcription or 'none'
        end
        report.gateway = ok and ('ok:' .. tostring(response.provider or 'unknown')) or ('error:' .. tostring(error))
        local line = json.encode(report)
        if source == 0 then print('[peak-ai-npc] ' .. line) else TriggerClientEvent('chat:addMessage', source, { args = { 'Peak AI NPC', line } }) end
    end, 'GET')
end, false)

CreateThread(function()
    framework = AINPCAdapters.framework()
    registerGateway()
    refreshGatewayCapabilities()
    AINPCResidents.start()
    CreateThread(function()
        while true do
            Wait(60000)
            registerGateway()
            refreshGatewayCapabilities()
        end
    end)
    local catalogReady = false
    CreateThread(function()
        Wait(3000)
        if not catalogReady then
            log('catalog hydration is still pending; spawning built-in NPC definitions')
            AINPCServerEntities.spawnAll()
        end
    end)
    loadCatalog(function()
        catalogReady = true
        AINPCServerEntities.syncDefinitions(-1)
        AINPCServerEntities.spawnAll()
        for id in pairs(AINPCDefinitions) do log(('loaded NPC %s using %s/%s'):format(id, framework.name, AINPCAdapters.inventory())) end
    end)
end)

exports('registerTool', function(name, definition) return AINPCTools.register(name, definition) end)
exports('registerContextProvider', function(name, handler) return AINPCContext.register(name, handler) end)
exports('registerServiceHandler', function(handler) return AINPCAdapters.registerServiceHandler(handler) end)
exports('registerInventoryAdapter', function(adapter) return AINPCAdapters.registerInventoryAdapter(adapter) end)
exports('registerCommerceDriver', function(name, factory) return AINPCAdapters.registerCommerceDriver(name, factory) end)
exports('registerNpc', function(id, definition)
    if type(id) ~= 'string' or not id:match('^[%w_%-]+$') or #id < 1 or #id > 64 or not validCatalogDefinition(definition) then return false end
    local owner = GetInvokingResource() or GetCurrentResourceName()
    if AINPCDefinitions[id] and registeredNpcOwners[id] ~= owner then return false, 'npc_already_registered' end
    definition.id = id
    AINPCDefinitions[id] = definition
    registeredNpcOwners[id] = owner
    AINPCServerEntities.syncDefinitions(-1)
    AINPCServerEntities.spawnAll()
    return true
end)

exports('setNpcEnabled', function(id, enabled)
    if type(id) ~= 'string' or type(enabled) ~= 'boolean' then return false, 'invalid_npc_state' end
    return AINPCServerEntities.setEnabled(id, enabled)
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        for source in pairs(AINPCSessions.bySource) do AINPCSessions.close(source, 'resource_stop') end
        return
    end
    local changed = false
    for id, owner in pairs(registeredNpcOwners) do
        if owner == resourceName then
            for source, session in pairs(AINPCSessions.bySource) do
                if session.npcId == id then
                    sendState(source, AINPC.State.Error, { message = 'This NPC is no longer available.' })
                    AINPCSessions.close(source, 'definition_removed')
                end
            end
            registeredNpcOwners[id] = nil
            AINPCDefinitions[id] = nil
            AINPCServerEntities.remove(id)
            changed = true
        end
    end
    if changed then AINPCServerEntities.syncDefinitions(-1) end
end)

exports('completeMission', function(source, missionId)
    if type(source) ~= 'number' or type(missionId) ~= 'string' then return false, 'invalid_mission_request' end
    local ok, result = AINPCMissions.complete(source, missionId)
    if Config.Security.auditWriteTools then print(('[peak-ai-npc][audit] mission_complete source=%s mission=%s ok=%s result=%s'):format(tostring(source), missionId, tostring(ok), tostring(result and result.status or result))) end
    return ok, result
end)
