AINPCAmbient = {}
local bindings = {}

local function entityDead(ped)
    if not ped or ped == 0 then return true end
    local ok, health = pcall(GetEntityHealth, ped)
    return ok and type(health) == 'number' and health <= 0
end

local function validPed(ped)
    local isPed = true
    if GetEntityType then
        isPed = (GetEntityType(ped) == 1)
    elseif IsEntityAPed then
        isPed = IsEntityAPed(ped)
    end
    return ped and ped ~= 0 and DoesEntityExist(ped) and isPed and not IsPedAPlayer(ped) and not entityDead(ped)
end

local animalModels = {
    'a_c_boar', 'a_c_cat_01', 'a_c_chickenhawk', 'a_c_chimp', 'a_c_chop', 'a_c_cormorant',
    'a_c_cow', 'a_c_coyote', 'a_c_crow', 'a_c_deer', 'a_c_dolphin', 'a_c_fish', 'a_c_hen',
    'a_c_humpback', 'a_c_husky', 'a_c_killerwhale', 'a_c_mtlion', 'a_c_pigeon', 'a_c_poodle',
    'a_c_pug', 'a_c_rabbit_01', 'a_c_rat', 'a_c_retriever', 'a_c_rhesus', 'a_c_rottweiler',
    'a_c_seagull', 'a_c_sharkhammer', 'a_c_sharktiger', 'a_c_shepherd', 'a_c_stingray', 'a_c_westy'
}
local animalHashes = nil
local function isAnimalModel(model)
    if type(model) == 'string' and model:lower():find('^a_c_') then return true end
    if not animalHashes then
        animalHashes = {}
        if type(joaat) == 'function' then
            for _, name in ipairs(animalModels) do
                local h = joaat(name)
                if type(h) == 'number' and math.abs(h) > 1000 then
                    animalHashes[h] = true
                end
            end
        end
    end
    local numModel = tonumber(model)
    return numModel ~= nil and animalHashes[numModel] == true
end

local function ignoredModel(model)
    if isAnimalModel(model) then return true end
    local numModel = tonumber(model)
    for _, value in ipairs(Config.Ambient.ignoredModels or {}) do
        if value == model or (type(value) == 'string' and joaat(value) == numModel) or (type(model) == 'string' and joaat(model) == value) then return true end
    end
    return false
end

local function stableIdentity(ped, netId)
    local state = Entity(ped).state
    local binding = bindings[netId]
    local identity = binding and binding.ped == ped and binding.model == GetEntityModel(ped)
        and state.peak_ai_npc_identity == binding.identity and binding.identity or nil
    if not identity then
        identity = ('ambient:%s-%s-%s'):format(netId, GetGameTimer(), math.random(100000, 999999))
        state:set('peak_ai_npc_identity', identity, true)
        bindings[netId] = { ped = ped, model = GetEntityModel(ped), identity = identity }
    end
    return identity
end


local function ambientProfile(source, identity, model, zone, gender, ageBand, coords)
    local hash = AINPCVoiceCasting.seed(identity)
    local tones = Config.Ambient.tones or {}
    local names = Config.Ambient.names or {}
    local archetype = AINPCVoiceCasting.resolve(model, zone)
    local cast = AINPCVoiceCasting.cast(model, archetype, gender, ageBand)
    local profile = cast.profile
    local tone = cast.tone or (#tones > 0 and tones[(hash % #tones) + 1] or 'natural')
    local name = #names > 0 and names[(hash % #names) + 1] or ('Resident %03d'):format(hash % 1000)
    return {
        voiceProfileId = cast.voiceProfileId,
        voiceSeed = cast.voiceSeed,
        genderPresentation = cast.genderPresentation,
        ageBand = cast.ageBand,
        accent = cast.accent,
        language = cast.language,
        qualityMode = cast.qualityMode,
        deliveryPreset = cast.deliveryPreset,
        tone = tone
    }, tone, name, cast.archetype, profile
end

function AINPCAmbient.validBinding(source, npc, ped)
    if not npc or not npc.entityNetId then return true end
    local binding = bindings[npc.entityNetId]
    return binding ~= nil and binding.ped == ped and DoesEntityExist(ped)
        and binding.identity == (npc.bindingIdentity or npc.id)
        and NetworkGetEntityFromNetworkId(npc.entityNetId) == ped
        and GetEntityModel(ped) == binding.model
        and Entity(ped).state.peak_ai_npc_identity == binding.identity
        and GetEntityRoutingBucket(ped) == GetPlayerRoutingBucket(source)
end

AddEventHandler('entityRemoved', function(entity)
    for netId, binding in pairs(bindings) do
        if binding.ped == entity then bindings[netId] = nil end
    end
end)

function AINPCAmbient.resolve(source, netId)
    if not Config.Ambient.enabled then return nil, 'ambient_npc_unavailable' end
    if type(netId) == 'table' then
        if netId.networkId ~= nil then
            local npc, ped = AINPCAmbient.resolve(source, netId.networkId)
            if not npc then return nil, ped end
            if tonumber(npc.model) ~= netId.model then return nil, 'invalid_ambient_model' end
            local presentation = npc.voice.genderPresentation
            local fallback = netId.gender == 'male' and 'male' or netId.gender == 'female' and 'female'
                or (presentation == 'masculine' or presentation == 'male') and 'male'
                or (presentation == 'feminine' or presentation == 'female') and 'female' or 'unspecified'
            local gender = AINPCVoiceCasting.genderForModel(netId.model, fallback)
            local archetype = AINPCVoiceCasting.resolve(netId.model, nil)
            npc.voice = AINPCVoiceCasting.cast(netId.model, archetype, gender, AINPCVoiceCasting.ageBand(netId.model))
            npc.residentCandidate = { gender = gender, ageBand = AINPCVoiceCasting.ageBand(netId.model) }
            return npc, ped
        end
        local key, model, coords = netId.localKey, netId.model, netId.coords
        if type(model) ~= 'number' or model ~= math.floor(model) or model == 0 or math.abs(model) > 4294967295 then return nil, 'invalid_ambient_model' end
        if type(key) ~= 'string' or not key:match('^%d+$') or #key > 12 or type(model) ~= 'number' or type(coords) ~= 'table' or type(coords.x) ~= 'number' or type(coords.y) ~= 'number' or type(coords.z) ~= 'number' or type(coords.w) ~= 'number' then return nil, 'invalid_ambient_npc' end
        if coords.x ~= coords.x or coords.y ~= coords.y or coords.z ~= coords.z or coords.w ~= coords.w or math.abs(coords.x) > 100000 or math.abs(coords.y) > 100000 or coords.z < -1000 or coords.z > 10000 or math.abs(coords.w) > 360 or ignoredModel(model) then return nil, 'invalid_ambient_npc' end
        local player = GetPlayerPed(source)
        local position = vec3(coords.x, coords.y, coords.z)
        local maxDist = Config.Ambient.interactionDistance or Config.Conversations.interactionDistance or 3.0
        if netId.inVehicle then
            maxDist = math.max(maxDist, (Config.Police and Config.Police.interactionDistance) or 4.0)
        end
        if player == 0 or #(GetEntityCoords(player) - position) > maxDist then return nil, 'too_far' end
        -- Client-local population peds do not exist server-side. Their profile is
        -- restricted to conversation-only behavior and scoped to this player.
        local identity = ('ambient:local-%s-%s'):format(source, key)
        local zone = type(netId.zone) == 'string' and netId.zone or nil
        local clientGender = netId.gender == 'male' and 'male' or netId.gender == 'female' and 'female' or 'unspecified'
        local gender = AINPCVoiceCasting.genderForModel(model, clientGender)
        local ageBand = AINPCVoiceCasting.ageBand(model)
        local voice, tone, name, archetype, profile = ambientProfile(source, identity, model, zone, gender, ageBand, position)
        local ageDirection = ageBand and (' Apparent age: %s; keep vocabulary and cadence age-appropriate without stereotyping.'):format(ageBand) or ''
        return { id = identity, kind = 'ambient', originalEntity = true, model = tostring(model), coords = vec4(coords.x, coords.y, coords.z, coords.w), identity = { name = name, displayName = 'Local resident', occupation = profile.occupation or 'local resident', ageBand = ageBand }, archetype = archetype, personality = (profile.personality or Config.Ambient.personality) .. ' Speak in a ' .. tone .. ' tone.' .. ageDirection, voice = voice, knowledge = Config.Ambient.knowledge, allowedTools = Config.Ambient.allowedTools or {}, interactionDistance = Config.Ambient.interactionDistance, memoryEnabled = Config.Ambient.memory ~= false, localEntity = true, residentCandidate = { localKey = key, residentId = type(netId.residentId) == 'string' and netId.residentId or nil, gender = gender, ageBand = ageBand, appearance = type(netId.appearance) == 'table' and netId.appearance or nil } }, nil
    end
    if type(netId) ~= 'number' or netId ~= math.floor(netId) or netId <= 0 or netId >= 65528 then return nil, 'invalid_ambient_npc' end
    local ped = NetworkGetEntityFromNetworkId(netId)
    if not validPed(ped) or ignoredModel(GetEntityModel(ped)) then return nil, 'ambient_npc_unavailable' end
    -- Script-owned entities require an explicit integration opt-in. Population
    -- peds (types 1..5) are eligible; animals and unknown types fail closed.
    local population = GetEntityPopulationType(ped)
    local owned = false
    for _, record in pairs(AINPCResidents and AINPCResidents.records or {}) do
        if record.ped == ped then owned = true; break end
    end
    if (population < 1 or population > 5) and not owned then
        return nil, 'ambient_npc_not_eligible'
    end
    local humanOk, human = pcall(IsPedHuman, ped)
    -- Some server builds omit IsPedHuman. In those builds this is not proof of
    -- humanity: complete animal exclusion still requires a validated model catalog.
    if humanOk and not human then return nil, 'ambient_npc_not_eligible' end
    if GetPlayerRoutingBucket(source) ~= GetEntityRoutingBucket(ped) then return nil, 'npc_not_in_bucket' end
    local player = GetPlayerPed(source)
    local maxDist = Config.Ambient.interactionDistance or Config.Conversations.interactionDistance or 3.0
    local vehOk, inVehicle = pcall(GetVehiclePedIsIn, ped, false)
    if (vehOk and inVehicle ~= 0) or (type(IsPedInAnyVehicle) == 'function' and IsPedInAnyVehicle(ped, false)) then
        maxDist = math.max(maxDist, (Config.Police and Config.Police.interactionDistance) or 4.0)
    end
    if player == 0 or #(GetEntityCoords(player) - GetEntityCoords(ped)) > maxDist then return nil, 'too_far' end
    local coords = GetEntityCoords(ped)
    local identity = stableIdentity(ped, netId)
    local model = GetEntityModel(ped)
    local zone = nil
    local gender = 'unspecified'
    local genderOk, male = pcall(IsPedMale, ped)
    if genderOk then gender = male and 'male' or 'female' end
    gender = AINPCVoiceCasting.genderForModel(model, gender)
    local ageBand = AINPCVoiceCasting.ageBand(model)
    local voice, tone, name, archetype, profile = ambientProfile(source, identity, model, zone, gender, ageBand, coords)
    local ageDirection = ageBand and (' Apparent age: %s; keep vocabulary and cadence age-appropriate without stereotyping.'):format(ageBand) or ''
    return { id = identity, kind = 'ambient', originalEntity = true, model = tostring(model), coords = vec4(coords.x, coords.y, coords.z, GetEntityHeading(ped)), identity = { name = name, displayName = 'Local resident', occupation = profile.occupation or 'local resident', ageBand = ageBand }, archetype = archetype, personality = (profile.personality or Config.Ambient.personality) .. ' Speak in a ' .. tone .. ' tone.' .. ageDirection, voice = voice, knowledge = Config.Ambient.knowledge, allowedTools = Config.Ambient.allowedTools or {}, interactionDistance = Config.Ambient.interactionDistance, memoryEnabled = Config.Ambient.memory ~= false, entityNetId = netId }, ped
end
