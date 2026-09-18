AINPCResidents = {
    profiles = {},
    records = {},
    pending = {},
    bindings = {},
    originalResidents = {},
    ready = false,
    lastError = 'none'
}

local function serverId()
    return GetConvar('peak_ai_npc_server_id', Config.Gateway.serverId or 'local')
end

local function suppressionKey(residentId)
    return ('ainpc:original:%s:%s'):format(serverId(), residentId)
end

-- Tombstones deliberately have no expiry. Recurring reappearance is unavailable
-- until a validated original-release and safe-location policy can remove them.
local function originalSuppressed(residentId)
    if AINPCResidents.originalResidents[residentId] then return true end
    local ok, value = pcall(GetResourceKvpInt, suppressionKey(residentId))
    if not ok then AINPCResidents.lastError = 'resident_suppression_read_failed'; return true end
    if value == 1 then AINPCResidents.originalResidents[residentId] = true; return true end
    return false
end

local function suppressOriginal(residentId)
    AINPCResidents.originalResidents[residentId] = true
    local key = suppressionKey(residentId)
    local ok = pcall(SetResourceKvpInt, key, 1)
    local readOk, value = pcall(GetResourceKvpInt, key)
    if not ok or not readOk or value ~= 1 then
        AINPCResidents.lastError = 'resident_suppression_write_failed'
        return false
    end
    return true
end

local function cachePersistedProfile(profile)
    if type(profile) ~= 'table' or type(profile.residentId) ~= 'string'
        or not profile.residentId:match('^resident:[%w%-]+$') then return false end
    -- Legacy profiles are ambient-derived, and generated locations are not vetted
    -- respawn positions. There is currently no supported eligibility/provenance
    -- contract or off-screen release validator. Suppress ALL persisted arrivals,
    -- including simulation results, until that policy is explicitly implemented.
    local suppressed = originalSuppressed(profile.residentId)
    local saved = suppressed or suppressOriginal(profile.residentId)
    AINPCResidents.profiles[profile.residentId] = profile
    return saved
end

local function request(path, payload, callback, method)
    if type(AINPCGatewayRequest) ~= 'function' then
        callback(false, nil, 'gateway_not_ready')
        return
    end
    AINPCGatewayRequest(path, payload, callback, method)
end

local function number(value, fallback)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then return fallback or 0 end
    return value
end

local function profileCoords(profile)
    local value = profile and profile.location
    if type(value) ~= 'table' then return nil end
    return vec4(number(value.x), number(value.y), number(value.z), number(value.w))
end

-- Voice casting uses underscore-delimited demographic hints internally, while
-- the resident API persists human-readable canonical labels. Normalize only at
-- this server-owned boundary so ambient young/older models do not fail the
-- gateway contract before a conversation can start.
local function gatewayAgeBand(value)
    if type(value) ~= 'string' then return nil end
    local normalized = value:lower():gsub('_', ' '):gsub('%-', ' '):gsub('%s+', ' ')
    if normalized == 'young adult' then return 'young adult' end
    if normalized == 'middle aged' then return 'middle-aged' end
    if normalized == 'older adult' then return 'older adult' end
    if normalized == 'adult' then return 'adult' end
    return nil
end

local function residentNpc(profile, knowledge)
    local coords = profileCoords(profile)
    if not coords then return nil end
    local traits = type(profile.traits) == 'table' and table.concat(profile.traits, ', ') or 'observant'
    local model = tonumber(profile.model) or (type(profile.model) == 'string' and joaat(profile.model) or 0)
    local archetypeName, archetype = AINPCVoiceCasting.resolve(model, nil)
    local ageBand = profile.ageBand or AINPCVoiceCasting.ageBand(model)
    local savedVoice = type(profile.voiceAssignment) == 'table' and profile.voiceAssignment.version == 1
        and type(profile.voiceAssignment.profile) == 'table' and profile.voiceAssignment.profile or nil
    local cast = savedVoice or AINPCVoiceCasting.cast(model, archetypeName, profile.gender, ageBand)
    archetype = cast.profile or archetype or {}
    local roleTone = tostring(archetype.tone or profile.tone or 'natural')
    local personalTone = tostring(profile.tone or 'natural')
    local ageDirection = ageBand and (' Apparent age: %s; keep vocabulary and cadence age-appropriate without stereotyping.'):format(ageBand) or ''
    return {
        id = profile.residentId,
        residentId = profile.residentId,
        kind = 'resident',
        archetype = archetypeName or 'civilian',
        model = tostring(profile.model),
        coords = coords,
        identity = {
            name = tostring(profile.name or 'Resident'),
            displayName = 'Local resident',
            occupation = tostring(archetype.occupation or profile.occupation or 'local resident'),
            ageBand = ageBand
        },
        personality = ('%s Traits: %s. Current mood: %s. Speak in a %s, %s tone. Maintain boundaries, react naturally, and never invent unrecorded events.%s'):format(archetype.personality or 'A believable persistent resident.', traits, profile.mood or 'neutral', roleTone, personalTone, ageDirection),
        voice = {
            voiceProfileId = cast.voiceProfileId,
            voiceSeed = cast.voiceSeed or AINPCVoiceCasting.seed(model),
            genderPresentation = cast.genderPresentation,
            ageBand = cast.ageBand,
            accent = type(cast.accent) == 'string' and cast.accent or nil,
            language = cast.language,
            qualityMode = cast.qualityMode,
            deliveryPreset = cast.deliveryPreset,
            tone = roleTone .. ', ' .. personalTone .. (ageBand and (', age-appropriate for an apparent ' .. ageBand) or '')
        },
        knowledge = {
            public = Config.Ambient.knowledge,
            knownNameAt = knowledge and knowledge.knownNameAt or nil,
            playerNameKnownAt = knowledge and knowledge.playerNameKnownAt or nil,
            meetings = knowledge and knowledge.meetings or 0,
            lastMetAt = knowledge and knowledge.lastMetAt or nil
        },
        residentState = {
            activity = profile.activity,
            mood = profile.mood,
            health = profile.health,
            needs = profile.needs,
            home = profile.home,
            work = profile.work,
            leisure = profile.leisure,
            possessions = profile.possessions
        },
        appearance = profile.appearance,
        allowedTools = Config.Ambient.allowedTools or {},
        interactionDistance = Config.Ambient.interactionDistance,
        memoryEnabled = Config.Ambient.memory ~= false
    }
end

local function entityModel(profile)
    local numeric = tonumber(profile.model)
    if numeric and numeric ~= 0 then return math.floor(numeric) end
    if type(profile.model) == 'string' and #profile.model <= 80 then return joaat(profile.model) end
    return 0
end

local function deleteRecord(residentId)
    local record = AINPCResidents.records[residentId]
    if record and record.ped and DoesEntityExist(record.ped) then DeleteEntity(record.ped) end
    AINPCResidents.records[residentId] = nil
end


local function activeCounts(bucket)
    local total, inBucket = 0, 0
    for _, record in pairs(AINPCResidents.records) do
        if record.ped and DoesEntityExist(record.ped) then
            total = total + 1
            if record.bucket == bucket then inBucket = inBucket + 1 end
        end
    end
    return total, inBucket
end

local function spawn(profile)
    if not profile or profile.status ~= 'active' then return nil, 'resident_unavailable' end
    if next(AINPCResidents.pending) or originalSuppressed(profile.residentId) then return nil, 'resident_original_bound' end
    local existing = AINPCResidents.records[profile.residentId]
    if existing and existing.ped and DoesEntityExist(existing.ped) then return existing end
    local total, inBucket = activeCounts(number(profile.bucket))
    if total >= (Config.Residents.maximumActive or 80) or inBucket >= (Config.Residents.maximumActivePerBucket or 24) then
        return nil, 'resident_spawn_cap'
    end
    local coords, model = profileCoords(profile), entityModel(profile)
    if not coords or model == 0 then return nil, 'invalid_resident_profile' end
    local ped = CreatePed(4, model, coords.x, coords.y, coords.z, coords.w, true, true)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return nil, 'resident_spawn_failed' end
    SetEntityRoutingBucket(ped, number(profile.bucket))
    SetEntityOrphanMode(ped, 2)
    local state = Entity(ped).state
    state:set('ainpc:residentId', profile.residentId, true)
    state:set('ainpc:activity', profile.activity or 'leisure', true)
    state:set('ainpc:mood', profile.mood or 'neutral', true)
    local modelArchetype = (Config.Ambient.modelArchetypes or {})[model] or 'civilian'
    state:set('ainpc:archetype', modelArchetype, true)
    state:set('ainpc:appearance', profile.appearance or {}, true)
    state:set('ainpc:managed', true, true)
    local record = { ped = ped, bucket = number(profile.bucket), lastNearbyAt = os.time(), lastObservedAt = 0, deathReported = false }
    AINPCResidents.records[profile.residentId] = record
    if AINPCBehavior then AINPCBehavior.reconcile(profile.residentId, profile, ped, nil, true) end
    return record
end


function AINPCResidents.resolve(source, candidate, characterId, callback)
    if not Config.Residents.enabled then callback(false, nil, 'residents_disabled'); return end
    if AINPCResidents.pending[source] then callback(false, nil, 'resident_resolution_pending'); return end
    local coords = candidate and candidate.coords
    if type(candidate) ~= 'table' or type(candidate.residentCandidate) ~= 'table' or not coords then
        callback(false, nil, 'invalid_resident_candidate')
        return
    end
    local bindingKey = candidate.localEntity and ('local:%s:%s'):format(source, candidate.residentCandidate.localKey) or candidate.id
    local binding = AINPCResidents.bindings[bindingKey]
    if binding and binding.pending then callback(false, nil, 'resident_resolution_pending'); return end
    binding = binding or {}
    AINPCResidents.bindings[bindingKey] = binding
    local token = {}
    binding.latestToken = token
    binding.pending = token
    AINPCResidents.pending[source] = token
    local bucket = GetPlayerRoutingBucket(source)
    local function finishPending()
        if binding.pending == token then binding.pending = nil end
        if AINPCResidents.pending[source] == token then AINPCResidents.pending[source] = nil end
    end
    SetTimeout(Config.Gateway.timeoutMs or 15000, function()
        if binding.pending ~= token then return end
        local current = AINPCResidents.pending[source] == token
        finishPending()
        if current then callback(false, nil, 'resident_resolution_timeout') end
    end)
    request('/v1/residents/resolve', {
        serverId = serverId(),
        residentId = binding.residentId,
        characterId = characterId,
        model = tostring(candidate.model),
        voice = candidate.voice,
        gender = candidate.residentCandidate.gender,
        ageBand = gatewayAgeBand(candidate.residentCandidate.ageBand),
        location = { x = coords.x, y = coords.y, z = coords.z, w = coords.w },
        bucket = GetPlayerRoutingBucket(source),
        appearance = candidate.residentCandidate.appearance
    }, function(ok, response, error)
        local current = AINPCResidents.pending[source] == token
        finishPending()
        -- Even a cancelled successful resolution must suppress later streaming
        -- of its persisted profile: the original may still exist in the world.
        if ok and type(response) == 'table' and type(response.resident) == 'table'
            and type(response.resident.residentId) == 'string'
            and response.resident.residentId:match('^resident:[%w%-]+$') then
            if not suppressOriginal(response.resident.residentId) then
                if current then callback(false, nil, AINPCResidents.lastError) end
                return
            end
            if binding.latestToken == token then binding.residentId = response.resident.residentId end
        end
        if not current then return end
        local player = GetPlayerPed(source)
        if player == 0 or not DoesEntityExist(player) or GetPlayerRoutingBucket(source) ~= bucket
            or #(GetEntityCoords(player) - vec3(coords.x, coords.y, coords.z)) > (Config.Ambient.interactionDistance or Config.Conversations.interactionDistance) then
            callback(false, nil, 'resident_resolution_stale'); return
        end
        if not ok or type(response) ~= 'table' or type(response.resident) ~= 'table' then
            AINPCResidents.lastError = error or 'invalid_resident_response'
            callback(false, nil, AINPCResidents.lastError)
            return
        end
        local profile, knowledge = response.resident, response.knowledge or {}
        if type(profile.residentId) ~= 'string' or not profile.residentId:match('^resident:[%w%-]+$') then
            callback(false, nil, 'invalid_resident_id')
            return
        end
        AINPCResidents.profiles[profile.residentId] = profile
        local npc = residentNpc(profile, knowledge)
        if not npc then callback(false, nil, 'invalid_resident_profile'); return end
        AINPCResidents.lastError = 'none'
        callback(true, { npc = npc, profile = profile, knowledge = knowledge })
    end)
end

function AINPCResidents.cancelSource(source)
    AINPCResidents.pending[source] = nil
    local prefix = ('local:%s:'):format(source)
    for key in pairs(AINPCResidents.bindings) do
        if key:sub(1, #prefix) == prefix then AINPCResidents.bindings[key] = nil end
    end
end

function AINPCResidents.beginHandoff(source, session, profile)
    return false, 'resident_replacement_disabled'
end

function AINPCResidents.revealName(session)
    if not session or session.npc.kind ~= 'resident' or not session.characterId then return end
    request('/v1/residents/knowledge', {
        serverId = serverId(), residentId = session.npcId, characterId = session.characterId, revealName = true
    }, function(ok, response)
        if ok and type(response.knowledge) == 'table' then session.npc.knowledge = response.knowledge end
    end)
end

function AINPCResidents.noteMeeting(session, playerNameKnown)
    if not session or session.npc.kind ~= 'resident' or not session.characterId then return end
    request('/v1/residents/knowledge', {
        serverId = serverId(), residentId = session.npcId, characterId = session.characterId,
        meeting = true, playerNameKnown = playerNameKnown == true
    }, function(ok, response)
        if ok and type(response.knowledge) == 'table' then session.npc.knowledge = response.knowledge end
    end)
end

function AINPCResidents.status()
    local active = 0
    for _, record in pairs(AINPCResidents.records) do if record.ped and DoesEntityExist(record.ped) then active = active + 1 end end
    local stored = 0
    for _ in pairs(AINPCResidents.profiles) do stored = stored + 1 end
    return { active = active, cached = stored, ready = AINPCResidents.ready, lastError = AINPCResidents.lastError }
end

-- Replacement handoffs are disabled; legacy client messages grant no entity authority.
RegisterNetEvent('peak_ai_npc:server:residentHandoffReady', function() end)
RegisterNetEvent('peak_ai_npc:server:residentHandoffFailed', function() end)

local function hydrate()
    request('/v1/residents?serverId=' .. serverId(), nil, function(ok, response, error)
        if not ok or type(response.residents) ~= 'table' then AINPCResidents.lastError = error or 'resident_hydration_failed'; return end
        for _, profile in ipairs(response.residents) do
            if not cachePersistedProfile(profile) then return end
        end
        AINPCResidents.ready = true
        AINPCResidents.lastError = 'none'
    end, 'GET')
end

local function playersByBucket()
    local result = {}
    for _, id in ipairs(GetPlayers()) do
        local source = tonumber(id)
        local ped = source and GetPlayerPed(source)
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            local bucket = GetPlayerRoutingBucket(source)
            result[bucket] = result[bucket] or {}
            result[bucket][#result[bucket] + 1] = GetEntityCoords(ped)
        end
    end
    return result
end

local function nearestDistance(profile, buckets)
    local coords, list = profileCoords(profile), buckets[number(profile.bucket)]
    if not coords or not list then return math.huge end
    local point, nearest = vec3(coords.x, coords.y, coords.z), math.huge
    for _, playerCoords in ipairs(list) do nearest = math.min(nearest, #(point - playerCoords)) end
    return nearest
end

function AINPCResidents.start()
    hydrate()
    CreateThread(function()
        while true do
            Wait((Config.Residents.refreshSeconds or 60) * 1000)
            request('/v1/residents/simulate', {
                serverId = serverId(),
                -- The gateway can schedule against the same authoritative game
                -- clock/weather used by the in-world behavior policy.
                world = AINPCEnvironment and AINPCEnvironment.world() or nil
            }, function(ok, response, error)
                if ok and type(response.residents) == 'table' then
                    for _, profile in ipairs(response.residents) do
                        if not cachePersistedProfile(profile) then return end
                        local record = AINPCResidents.records[profile.residentId]
                        if record and record.ped and DoesEntityExist(record.ped) then
                            Entity(record.ped).state:set('ainpc:activity', profile.activity or 'leisure', true)
                            Entity(record.ped).state:set('ainpc:mood', profile.mood or 'neutral', true)
                            if AINPCBehavior then AINPCBehavior.reconcile(profile.residentId, profile, record.ped, nil, true) end
                        end
                    end
                    AINPCResidents.ready = true
                else
                    AINPCResidents.lastError = error or 'resident_simulation_failed'
                end
            end)
        end
    end)
    CreateThread(function()
        while true do
            Wait(Config.Residents.lifecycleCheckMs or 2000)
            local buckets, now = playersByBucket(), os.time()
            for residentId, profile in pairs(AINPCResidents.profiles) do
                local distance, record = nearestDistance(profile, buckets), AINPCResidents.records[residentId]
                local activeSession = AINPCSessions.byNpc[residentId]
                local sessionOwnsRecord = activeSession and activeSession.entity and record and record.ped == activeSession.entity
                -- A local ambient conversation is intentionally bound to the
                -- original population ped. Never stream a second managed ped
                -- for that resident while the session is active. If a timer
                -- raced the session start, remove only our own managed record.
                if activeSession and not sessionOwnsRecord then
                    if record and record.ped and DoesEntityExist(record.ped) then deleteRecord(residentId) end
                elseif profile.status == 'active' and distance <= (Config.Residents.spawnDistance or 140.0) then
                    if not record or not record.ped or not DoesEntityExist(record.ped) then record = spawn(profile) end
                    if record then record.lastNearbyAt = now end
                elseif record and record.ped and DoesEntityExist(record.ped) then
                    local protected = AINPCSessions.byNpc[residentId] ~= nil or profile.pinned == true
                    if distance <= (Config.Residents.despawnDistance or 200.0) then record.lastNearbyAt = now end
                    if not protected and distance > (Config.Residents.despawnDistance or 200.0) and now - (record.lastNearbyAt or now) >= (Config.Residents.despawnGraceSeconds or 60) then
                        deleteRecord(residentId)
                    elseif (GetEntityHealth(record.ped) <= 0) and not record.deathReported then
                        record.deathReported = true
                        if Config.Residents.permanentDeath then
                            request('/v1/residents/lifecycle', { serverId = serverId(), residentId = residentId, event = 'archive' }, function() end)
                            profile.status = 'archived'
                        else
                            request('/v1/residents/lifecycle', { serverId = serverId(), residentId = residentId, event = 'death', recoverySeconds = Config.Residents.recoverySeconds or 1800 }, function() end)
                            profile.status = 'recovering'
                        end
                        deleteRecord(residentId)
                    elseif now - (record.lastObservedAt or 0) >= 60 then
                        local live = GetEntityCoords(record.ped)
                        record.lastObservedAt = now
                        request('/v1/residents/observe', {
                            serverId = serverId(), residentId = residentId,
                            location = { x = live.x, y = live.y, z = live.z, w = GetEntityHeading(record.ped) },
                            activity = Entity(record.ped).state['ainpc:activity']
                        }, function() end)
                    end
                end
            end
        end
    end)
end

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    for residentId in pairs(AINPCResidents.records) do deleteRecord(residentId) end
end)
