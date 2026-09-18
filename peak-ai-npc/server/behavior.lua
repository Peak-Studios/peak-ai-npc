AINPCBehavior = { records = {} }

local allowedModes = {
    idle = true, scenario = true, wander = true, face = true,
    retreat = true, flee = true, surrender = true, crouch = true
}

local allowedFacials = { neutral = true, happy = true, angry = true, stressed = true }
local allowedScenarios = {
    WORLD_HUMAN_CLIPBOARD = true,
    WORLD_HUMAN_DRINKING = true,
    WORLD_HUMAN_STAND_MOBILE = true,
    WORLD_HUMAN_STAND_IMPATIENT = true,
    WORLD_HUMAN_SMOKING = true,
    WORLD_HUMAN_GUARD_STAND = true,
    PROP_HUMAN_SEAT_CHAIR_MP_PLAYER = true
}

local function finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function bounded(value, minimum, maximum, fallback)
    value = tonumber(value)
    if not value or not finite(value) then return fallback end
    return math.max(minimum, math.min(maximum, value))
end

local function modelHash(model)
    if type(model) == 'number' then return model end
    local numeric = tonumber(model)
    if numeric and numeric > 0 then return numeric end
    return type(model) == 'string' and joaat(model) or 0
end

local function coordsFor(npc, ped)
    if ped and ped ~= 0 and DoesEntityExist(ped) then return GetEntityCoords(ped) end
    local coords = npc and (npc.coords or npc.location)
    return coords and vec3(coords.x, coords.y, coords.z) or nil
end

function AINPCBehavior.resolveArchetype(npc, ped)
    npc = type(npc) == 'table' and npc or {}
    local explicit = type(npc.behavior) == 'table' and npc.behavior.archetype or npc.archetype
    if type(explicit) == 'string' and (Config.Behavior.profiles or {})[explicit] then return explicit end
    if type(npc.shop) == 'table' and (Config.Behavior.profiles or {}).shopkeeper then return 'shopkeeper' end
    local byModel = (Config.Ambient.modelArchetypes or {})[modelHash(npc.model)]
    if type(byModel) == 'string' and (Config.Behavior.profiles or {})[byModel] then return byModel end
    local coords = coordsFor(npc, ped)
    if coords then
        local ok, zone = pcall(GetNameOfZone, coords.x, coords.y, coords.z)
        local byZone = ok and (Config.Ambient.zoneArchetypes or {})[zone] or nil
        if type(byZone) == 'string' and (Config.Behavior.profiles or {})[byZone] then return byZone end
    end
    return 'civilian'
end

function AINPCBehavior.profile(npc, ped)
    local archetype = AINPCBehavior.resolveArchetype(npc, ped)
    return archetype, (Config.Behavior.profiles or {})[archetype] or (Config.Behavior.profiles or {}).civilian or {}
end

local function copyDirective(value)
    if type(value) ~= 'table' then return { mode = 'idle' } end
    return {
        mode = value.mode,
        scenario = value.scenario,
        facial = value.facial,
        speed = value.speed,
        radius = value.radius,
        durationMs = value.durationMs
    }
end

local function normalizeDirective(value)
    value = type(value) == 'table' and value or {}
    local mode = allowedModes[value.mode] and value.mode or 'idle'
    local scenario = mode == 'scenario' and allowedScenarios[value.scenario] and value.scenario or nil
    if mode == 'scenario' and not scenario then mode = 'idle' end
    return {
        mode = mode,
        scenario = scenario,
        facial = allowedFacials[value.facial] and value.facial or 'neutral',
        speed = bounded(value.speed, 0.5, 2.0, 1.0),
        radius = bounded(value.radius, 1.0, Config.Ambient.maximumRoamDistance or 100.0, 8.0),
        durationMs = math.floor(bounded(value.durationMs, 500, 60000, 5000)),
        priority = math.floor(bounded(value.priority, 0, 100, 10)),
        targetServerId = type(value.targetServerId) == 'number' and value.targetServerId or nil,
        reason = type(value.reason) == 'string' and value.reason:sub(1, 48) or 'routine'
    }
end

local function stateKey(source, id, ped)
    if ped and ped ~= 0 and DoesEntityExist(ped) then return tostring(id) end
    return ('local:%s:%s'):format(tostring(source or 0), tostring(id))
end

local function signature(value)
    return table.concat({
        tostring(value.mode), tostring(value.scenario), tostring(value.facial),
        tostring(value.speed), tostring(value.radius), tostring(value.durationMs),
        tostring(value.priority), tostring(value.targetServerId), tostring(value.reason)
    }, '|')
end

local function publish(source, id, npc, ped, value, force)
    if not Config.Behavior.enabled or type(id) ~= 'string' then return nil end
    local directive = normalizeDirective(value)
    local key = stateKey(source, id, ped)
    local record = AINPCBehavior.records[key] or { revision = 0, layers = {} }
    record.layers = record.layers or {}
    local expiresAt = directive.durationMs and (GetGameTimer() + directive.durationMs) or nil
    record.layers[directive.priority] = { directive = directive, expiresAt = expiresAt }
    local selected
    local now = GetGameTimer()
    for priority, layer in pairs(record.layers) do
        if layer.expiresAt and layer.expiresAt <= now then
            record.layers[priority] = nil
        elseif not selected or layer.directive.priority > selected.priority then
            selected = layer.directive
        end
    end
    directive = selected or directive
    local nextSignature = signature(directive)
    if not force and record.signature == nextSignature then return record.directive end
    record.revision = record.revision + 1
    directive.revision = record.revision
    directive.npcId = id
    record.signature = nextSignature
    record.directive = directive
    record.npc = npc
    record.ped = ped
    record.source = source
    AINPCBehavior.records[key] = record
    if ped and ped ~= 0 and DoesEntityExist(ped) then
        local archetype = AINPCBehavior.resolveArchetype(npc, ped)
        local state = Entity(ped).state
        state:set('ainpc:archetype', archetype, true)
        state:set('ainpc:behavior', directive, true)
    elseif source then
        TriggerClientEvent(AINPC.Event.Behavior, source, id, directive)
    end
    return directive
end

function AINPCBehavior.push(source, session, value)
    if not session or not session.npc then return nil end
    return publish(source, session.npcId, session.npc, session.entity, value, true)
end

function AINPCBehavior.clearSession(source, session)
    if not session then return end
    local key = stateKey(source, session.npcId, session.entity)
    local record = AINPCBehavior.records[key]
    if not record then return end
    record.layers[50], record.layers[60], record.layers[80], record.layers[100] = nil, nil, nil, nil
    record.holdUntil = nil
    AINPCBehavior.reconcile(session.npcId, session.npc, session.entity, source, true)
end

local function activityOf(npc, ped)
    if ped and ped ~= 0 and DoesEntityExist(ped) then
        return tostring(Entity(ped).state['ainpc:activity'] or npc.activity or 'leisure'),
            tostring(Entity(ped).state['ainpc:mood'] or npc.mood or 'neutral')
    end
    local resident = type(npc.residentState) == 'table' and npc.residentState or npc
    return tostring(resident.activity or 'leisure'), tostring(resident.mood or 'neutral')
end

local function baseline(npc, ped, source)
    local archetype, profile = AINPCBehavior.profile(npc, ped)
    local environment = AINPCEnvironment.snapshot(npc, ped, source, archetype)
    local activity, mood = activityOf(npc, ped)
    local directive
    if type(profile.activities) == 'table' and type(profile.activities[activity]) == 'table' then
        directive = copyDirective(profile.activities[activity])
        directive.reason = 'activity:' .. activity
    elseif not profile.indoors and type(profile.weather) == 'table' and type(profile.weather[environment.world.weatherGroup]) == 'table' then
        directive = copyDirective(profile.weather[environment.world.weatherGroup])
        directive.reason = 'weather:' .. environment.world.weatherGroup
    elseif not profile.indoors and environment.surroundings.trafficHeavy and type(profile.trafficHeavy) == 'table' then
        directive = copyDirective(profile.trafficHeavy)
        directive.reason = 'surroundings:traffic'
    elseif environment.surroundings.nearbyAllies > 0 and type(profile.withAllies) == 'table' then
        directive = copyDirective(profile.withAllies)
        directive.reason = 'surroundings:allies'
    elseif environment.surroundings.crowded and type(profile.crowded) == 'table' then
        directive = copyDirective(profile.crowded)
        directive.reason = 'surroundings:crowded'
    elseif environment.world.period == 'night' and type(profile.night) == 'table' then
        directive = copyDirective(profile.night)
        directive.reason = 'time:night'
    else
        directive = copyDirective(profile.day)
        directive.reason = 'role:' .. archetype
    end
    directive.priority = 10
    directive.durationMs = Config.Behavior.directiveRefreshMs or 15000
    if mood == 'afraid' or mood == 'stressed' then directive.facial = 'stressed'
    elseif mood == 'angry' then directive.facial = 'angry'
    elseif mood == 'happy' then directive.facial = 'happy' end
    return directive, environment
end

function AINPCBehavior.reconcile(id, npc, ped, source, force)
    if not Config.Behavior.enabled or type(id) ~= 'string' or type(npc) ~= 'table' then return end
    if npc.originalEntity or npc.localEntity or npc.kind == 'ambient' then return end
    local key = stateKey(source, id, ped)
    local record = AINPCBehavior.records[key]
    if record and (record.holdUntil or 0) > GetGameTimer() then return end
    local directive = baseline(npc, ped, source)
    publish(source, id, npc, ped, directive, force)
end

function AINPCBehavior.hold(id, durationMs, source)
    local now = GetGameTimer()
    local duration = math.floor(bounded(durationMs, 500, 60000, 5000))
    for key, record in pairs(AINPCBehavior.records) do
        if key == tostring(id) or (source and key == stateKey(source, id, nil)) then
            record.holdUntil = math.max(record.holdUntil or 0, now + duration)
        end
    end
end

local function classifyTreatment(text)
    local value = tostring(text or ''):lower()
    if value:find('kill you', 1, true) or value:find('hurt you', 1, true) or value:find('shoot you', 1, true)
        or value:find('gun you down', 1, true) then return 'threatening', -4 end
    if value:find('shut up', 1, true) or value:find('idiot', 1, true) or value:find('stupid', 1, true)
        or value:find('fuck you', 1, true) then return 'insulting', -2 end
    if value:find('sorry', 1, true) or value:find('apologize', 1, true) then return 'apologetic', 2 end
    if value:find('thank you', 1, true) or value:find('thanks', 1, true) or value:find('you helped', 1, true) then return 'respectful', 2 end
    if value:find('please', 1, true) then return 'polite', 1 end
    return 'neutral', 0
end

function AINPCBehavior.noteTreatment(source, session, text)
    if not session or not session.npc then return 'neutral' end
    local treatment, delta = classifyTreatment(text)
    session.treatmentScore = math.max(-10, math.min(10, (session.treatmentScore or 0) + delta))
    session.recentTreatment = treatment
    -- Conversation tone can affect relationship context without taking over
    -- the original population entity's tasks or another resource's scenario.
    if session.npc.originalEntity or session.npc.localEntity or session.npc.kind == 'ambient' then return treatment end
    if treatment == 'neutral' then return treatment end
    local _, profile = AINPCBehavior.profile(session.npc, session.entity)
    local reaction = type(profile.reactions) == 'table' and profile.reactions[treatment] or nil
    if not reaction and treatment == 'polite' then reaction = profile.reactions and profile.reactions.respectful end
    if not reaction and treatment == 'apologetic' then reaction = profile.reactions and profile.reactions.respectful end
    if type(reaction) == 'table' then
        reaction = copyDirective(reaction)
        reaction.priority = 50
        reaction.targetServerId = source
        reaction.durationMs = Config.Behavior.treatmentDurationMs or 6000
        reaction.reason = 'treatment:' .. treatment
        publish(source, session.npcId, session.npc, session.entity, reaction, true)
        local key = stateKey(source, session.npcId, session.entity)
        if AINPCBehavior.records[key] then
            AINPCBehavior.records[key].holdUntil = GetGameTimer() + reaction.durationMs
        end
    end
    return treatment
end

function AINPCBehavior.observePresentation(source, session, observation)
    if not session or not session.npc or type(observation) ~= 'table' then return end
    if session.npc.originalEntity then return end
    local player = observation.player
    if type(player) ~= 'table' then return end
    if session.lastObservedBehaviorAt and GetGameTimer() - session.lastObservedBehaviorAt < 2500 then return end

    local archetype = AINPCBehavior.resolveArchetype(session.npc, session.entity)

    -- 1. Player aiming or shooting weapon
    if player.aiming == true or player.isShooting == true then
        session.lastObservedBehaviorAt = GetGameTimer()
        local reaction = archetype == 'gang'
            and { mode = 'face', facial = 'angry', priority = 70, targetServerId = source, durationMs = 5000, reason = player.isShooting and 'observed:shooting' or 'observed:armed-aim' }
            or { mode = 'retreat', facial = 'stressed', radius = 14.0, speed = 1.25, priority = 70, targetServerId = source, durationMs = 5000, reason = player.isShooting and 'observed:shooting' or 'observed:armed-aim' }
        publish(source, session.npcId, session.npc, session.entity, reaction, true)
        local key = stateKey(source, session.npcId, session.entity)
        if AINPCBehavior.records[key] then AINPCBehavior.records[key].holdUntil = GetGameTimer() + reaction.durationMs end
        return
    end

    -- 2. Player crouching (roleplay stealth / cover / ducking)
    if player.crouching == true and not session.observedPlayerCrouching then
        session.observedPlayerCrouching = true
        session.lastObservedBehaviorAt = GetGameTimer()
        local reaction = { mode = 'crouch', facial = 'stressed', priority = 50, targetServerId = source, durationMs = 8000, reason = 'observed:crouch' }
        publish(source, session.npcId, session.npc, session.entity, reaction, true)
        local key = stateKey(source, session.npcId, session.entity)
        if AINPCBehavior.records[key] then AINPCBehavior.records[key].holdUntil = GetGameTimer() + reaction.durationMs end
        return
    elseif player.crouching == false and session.observedPlayerCrouching then
        session.observedPlayerCrouching = nil
    end

    -- 3. Player running around during conversation
    if player.running == true then
        session.lastObservedBehaviorAt = GetGameTimer()
        local reaction = { mode = 'face', facial = 'stressed', priority = 40, targetServerId = source, durationMs = 3000, reason = 'observed:running' }
        publish(source, session.npcId, session.npc, session.entity, reaction, true)
        return
    end
end

function AINPCBehavior.sessionStarted(source, session)
    if session and session.npc then AINPCBehavior.reconcile(session.npcId, session.npc, session.entity, source, true) end
end

CreateThread(function()
    while true do
        Wait(Config.Behavior.tickMs or 5000)
        if AINPCServerEntities and AINPCServerEntities.records then
            for id, record in pairs(AINPCServerEntities.records) do
                local npc = AINPCDefinitions and AINPCDefinitions[id]
                if npc and record.ped and DoesEntityExist(record.ped) then AINPCBehavior.reconcile(id, npc, record.ped) end
            end
        end
        if AINPCResidents and AINPCResidents.records then
            for id, record in pairs(AINPCResidents.records) do
                local profile = AINPCResidents.profiles and AINPCResidents.profiles[id]
                if profile and record.ped and DoesEntityExist(record.ped) then AINPCBehavior.reconcile(id, profile, record.ped) end
            end
        end
        local now = GetGameTimer()
        for key, record in pairs(AINPCBehavior.records) do
            if record.ped and (not DoesEntityExist(record.ped)) then AINPCBehavior.records[key] = nil
            elseif record.holdUntil and record.holdUntil <= now then
                record.holdUntil = nil
                if record.npc then AINPCBehavior.reconcile(record.directive.npcId, record.npc, record.ped, record.source, true) end
            elseif record.layers then
                local expired = false
                for priority, layer in pairs(record.layers) do
                    if layer.expiresAt and layer.expiresAt <= now then record.layers[priority], expired = nil, true end
                end
                if expired and record.npc then
                    AINPCBehavior.reconcile(record.directive.npcId, record.npc, record.ped, record.source, true)
                end
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then AINPCBehavior.records = {} end
end)
