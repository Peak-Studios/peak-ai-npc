AINPCVoiceCasting = {}

local catalogNamesByHash

local function unsignedHash(value)
    local numeric = tonumber(value)
    if not numeric or numeric ~= numeric or numeric == math.huge or numeric == -math.huge then return nil end
    numeric = math.floor(numeric)
    if numeric < 0 then numeric = numeric + 4294967296 end
    return numeric >= 0 and numeric <= 4294967295 and numeric or nil
end

local function catalogModelName(model)
    if type(model) == 'string' and not tonumber(model) then
        local name = model:lower()
        return AINPCPedCatalog and AINPCPedCatalog.models and AINPCPedCatalog.models[name] and name or name
    end
    local target = unsignedHash(model)
    if not target or type(joaat) ~= 'function' or not AINPCPedCatalog or type(AINPCPedCatalog.models) ~= 'table' then return nil end
    if not catalogNamesByHash then
        catalogNamesByHash = {}
        for name in pairs(AINPCPedCatalog.models) do
            local hash = unsignedHash(joaat(name))
            if hash then catalogNamesByHash[hash] = name end
        end
    end
    return catalogNamesByHash[target]
end

local function stableSeed(value)
    local numeric = tonumber(value)
    if numeric and numeric == numeric and numeric ~= math.huge and numeric ~= -math.huge then
        return math.floor(math.abs(numeric))
    end
    local text, hash = tostring(value or ''), 0
    for index = 1, #text do hash = (hash * 31 + text:byte(index)) % 2147483647 end
    return hash
end

local function configuredProfile(archetype)
    local profiles = Config.Ambient.archetypes or {}
    if type(archetype) == 'string' and type(profiles[archetype]) == 'table' then return archetype, profiles[archetype] end
    return 'civilian', type(profiles.civilian) == 'table' and profiles.civilian or {}
end

local function selectFrom(pool, seed, excluded)
    if type(pool) ~= 'table' or #pool == 0 then return nil end
    local start = (stableSeed(seed) % #pool) + 1
    -- Nearby conversations must never recast an established character.
    -- Shared provider capacity is handled by the gateway, not by changing voices.
    return pool[start]
end

function AINPCVoiceCasting.seed(value) return stableSeed(value) end

function AINPCVoiceCasting.parseDemographics(model)
    local text = catalogModelName(model) or tostring(model or ''):lower()
    if text == '' then return nil end
    local gender
    local sexToken, ageToken = text:match('^[asgu]_([mf])_([ymo])_')
    sexToken = sexToken or text:match('^mp_([mf])_')
    if sexToken == 'm' then gender = 'male'
    elseif sexToken == 'f' then gender = 'female' end
    local ageBand
    if ageToken == 'y' then ageBand = 'young_adult'
    elseif ageToken == 'm' then ageBand = 'middle_aged'
    elseif ageToken == 'o' then ageBand = 'older_adult' end
    -- Filenames do not establish a person's job, background or social identity.
    -- Any authored role must be an explicit configuration, never a name heuristic.
    local archetype = text:sub(1, 2) == 'a_' and 'civilian' or nil
    if not gender and not ageBand and not archetype then return nil end
    return { sex = gender or 'unspecified', gender = gender or 'unspecified', ageBand = ageBand or 'adult', category = archetype or 'civilian', archetype = archetype or 'civilian', reviewRequired = true, source = 'model_name_hint' }
end

-- Prefer the pinned model catalog over a client/server native hint. The hint is
-- only a fallback for custom peds that the catalog cannot classify.
function AINPCVoiceCasting.genderForModel(model, fallback)
    local parsed = AINPCVoiceCasting.parseDemographics(model)
    if parsed and (parsed.gender == 'male' or parsed.gender == 'female') then return parsed.gender end
    return fallback == 'male' and 'male' or fallback == 'female' and 'female' or 'unspecified'
end

function AINPCVoiceCasting.resolve(model, zone)
    local configured = Config.Ambient.modelArchetypes or {}
    local archetype = configured[model] or configured[tostring(model)]
    if type(archetype) ~= 'string' and type(model) == 'string' and not tonumber(model) then archetype = configured[joaat(model)] end
    if type(archetype) ~= 'string' then archetype = (Config.Ambient.zoneArchetypes or {})[zone] end
    if type(archetype) ~= 'string' then
        local parsed = AINPCVoiceCasting.parseDemographics(model)
        archetype = parsed and parsed.archetype or nil
    end
    return configuredProfile(archetype)
end

function AINPCVoiceCasting.ageBand(model)
    local value = (Config.Ambient.modelAgeBands or {})[model] or (Config.Ambient.modelAgeBands or {})[tostring(model)]
    if type(value) ~= 'string' and type(model) == 'string' and not tonumber(model) then value = (Config.Ambient.modelAgeBands or {})[joaat(model)] end
    if type(value) == 'string' then return value:gsub(' ', '_'):gsub('%-', '_') end
    local parsed = AINPCVoiceCasting.parseDemographics(model)
    return parsed and parsed.ageBand or 'adult'
end

-- Returns a provider-neutral profile. Provider voice IDs belong exclusively to
-- the gateway registry and are never authored or inferred in FiveM Lua.
function AINPCVoiceCasting.cast(seed, archetype, gender, ageBand, excluded)
    local resolvedArchetype, role = configuredProfile(archetype)
    gender = gender == 'female' and 'female' or gender == 'male' and 'male' or 'unspecified'
    ageBand = tostring(ageBand or 'adult'):gsub(' ', '_'):gsub('%-', '_')
    local pools = Config.VoiceProfiles and Config.VoiceProfiles.ambientPools or {}
    local candidates = pools[resolvedArchetype] or pools.default or {}
    local genderPool = candidates[gender] or candidates.unspecified or candidates.any
    local agePool = type(genderPool) == 'table' and (genderPool[ageBand] or genderPool.adult or genderPool.any) or nil
    if type(agePool) ~= 'table' then agePool = type(genderPool) == 'table' and genderPool or {} end
    local castSeed = tostring(seed or '') .. ':' .. resolvedArchetype
    local profileId = selectFrom(agePool, castSeed, excluded)
    if not profileId then profileId = selectFrom(Config.VoiceProfiles and Config.VoiceProfiles.fallbackPool or {}, seed, excluded) end
    local delivery = role.deliveryPreset
    if delivery ~= 'neutral' and delivery ~= 'warm' and delivery ~= 'stern' and delivery ~= 'nervous'
        and delivery ~= 'urgent' and delivery ~= 'quiet' and delivery ~= 'menacing' then
        delivery = resolvedArchetype == 'shopkeeper' and 'warm' or resolvedArchetype == 'gang' and 'stern' or 'neutral'
    end
    return {
        voiceProfileId = profileId or 'ambient.neutral.01',
        voiceSeed = stableSeed(seed),
        genderPresentation = gender == 'male' and 'masculine' or gender == 'female' and 'feminine' or 'androgynous',
        ageBand = ageBand == 'young_adult' and 'young-adult' or ageBand == 'older_adult' and 'older-adult' or ageBand == 'middle_aged' and 'adult' or ageBand,
        accent = type(role.accent) == 'string' and role.accent or nil,
        language = type(role.language) == 'string' and role.language or 'en',
        qualityMode = role.qualityMode == 'quality' and 'quality' or 'realtime',
        deliveryPreset = delivery,
        tone = role.tone or 'grounded and conversational',
        archetype = resolvedArchetype,
        profile = role
    }
end
