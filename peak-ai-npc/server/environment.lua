AINPCEnvironment = {}

local worldCache = nil
local worldCacheAt = 0
local populationCache = { players = {}, vehicles = {} }
local populationCacheAt = 0

local validWeather = {
    EXTRASUNNY = true, CLEAR = true, CLOUDS = true, SMOG = true,
    FOGGY = true, OVERCAST = true, RAIN = true, THUNDER = true,
    CLEARING = true, NEUTRAL = true, SNOW = true, BLIZZARD = true,
    SNOWLIGHT = true, XMAS = true, HALLOWEEN = true, UNKNOWN = true
}

local function finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function normalizedWeather(value)
    value = type(value) == 'string' and value:upper() or 'UNKNOWN'
    return validWeather[value] and value or 'UNKNOWN'
end

local function weatherGroup(weather)
    if weather == 'RAIN' or weather == 'THUNDER' or weather == 'CLEARING' then return 'wet' end
    if weather == 'SNOW' or weather == 'BLIZZARD' or weather == 'SNOWLIGHT' or weather == 'XMAS' then return 'cold' end
    if weather == 'FOGGY' or weather == 'SMOG' or weather == 'OVERCAST' or weather == 'CLOUDS' then return 'low_visibility' end
    return weather == 'UNKNOWN' and 'unknown' or 'fair'
end

local function periodFor(hour)
    if hour >= 22 or hour < 5 then return 'night' end
    if hour < 8 then return 'morning' end
    if hour < 18 then return 'day' end
    return 'evening'
end

local function qbWeatherState()
    if GetResourceState('qb-weathersync') ~= 'started' then return nil end
    local timeOk, hour, minute = pcall(function()
        return exports['qb-weathersync']:getTime()
    end)
    local weatherOk, weather = pcall(function()
        return exports['qb-weathersync']:getWeatherState()
    end)
    local blackoutOk, blackout = pcall(function()
        return exports['qb-weathersync']:getBlackoutState()
    end)
    if not timeOk or not finite(hour) or not finite(minute) then return nil end
    return {
        hour = math.floor(hour) % 24,
        minute = math.floor(minute) % 60,
        weather = weatherOk and normalizedWeather(weather) or 'UNKNOWN',
        blackout = blackoutOk and blackout == true or false,
        provider = 'qb-weathersync',
        source = 'qb-weathersync',
        quality = weatherOk and 'authoritative' or 'partial',
        observedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        observedAtUnix = os.time(),
        authoritative = weatherOk
    }
end

function AINPCEnvironment.world()
    local now = GetGameTimer()
    if worldCache and now - worldCacheAt < (Config.Behavior.environmentCacheMs or 1000) then return worldCache end
    local value = qbWeatherState()
    if not value then
        local utc = os.date('!*t')
        value = {
            hour = tonumber(utc.hour) or 12,
            minute = tonumber(utc.min) or 0,
            weather = 'UNKNOWN',
            blackout = false,
            provider = 'server-clock-fallback',
            source = 'server-clock-fallback',
            quality = 'unknown',
            observedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
            observedAtUnix = os.time(),
            authoritative = false
        }
    end
    value.period = periodFor(value.hour)
    value.weatherGroup = weatherGroup(value.weather)
    value.ageSeconds = math.max(0, os.time() - (value.observedAtUnix or os.time()))
    worldCache, worldCacheAt = value, now
    return value
end

local function refreshPopulation()
    local now = GetGameTimer()
    if now - populationCacheAt < (Config.Behavior.populationCacheMs or 2000) then return populationCache end
    local players, vehicles = {}, {}
    for _, id in ipairs(GetPlayers()) do
        local source = tonumber(id)
        local ped = source and GetPlayerPed(source)
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            players[#players + 1] = {
                source = source,
                bucket = GetPlayerRoutingBucket(source),
                coords = GetEntityCoords(ped)
            }
        end
    end
    local getVehicles = type(GetAllVehicles) == 'function' and GetAllVehicles or nil
    if getVehicles then
        local ok, values = pcall(getVehicles)
        if ok and type(values) == 'table' then
            for _, vehicle in ipairs(values) do
                if #vehicles >= (Config.Behavior.maximumObservedVehicles or 256) then break end
                if vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) then
                    vehicles[#vehicles + 1] = {
                        bucket = GetEntityRoutingBucket(vehicle),
                        coords = GetEntityCoords(vehicle),
                        speed = GetEntitySpeed(vehicle)
                    }
                end
            end
        end
    end
    populationCache = { players = players, vehicles = vehicles }
    populationCacheAt = now
    return populationCache
end

local function entityPosition(npc, ped)
    if ped and ped ~= 0 and DoesEntityExist(ped) then
        return GetEntityCoords(ped), GetEntityRoutingBucket(ped), 'server-entity'
    end
    local coords = npc and (npc.coords or npc.location)
    if coords and finite(coords.x) and finite(coords.y) and finite(coords.z) then
        return vec3(coords.x, coords.y, coords.z), tonumber(npc.bucket) or 0, 'server-profile'
    end
    return nil, 0, 'unknown'
end

local function managedNearby(origin, bucket, radius, archetype)
    local count, allies = 0, 0
    local function inspect(record)
        local ped = record and record.ped
        if ped and ped ~= 0 and DoesEntityExist(ped) and GetEntityRoutingBucket(ped) == bucket and #(GetEntityCoords(ped) - origin) <= radius then
            count = count + 1
            if archetype and Entity(ped).state['ainpc:archetype'] == archetype then allies = allies + 1 end
        end
    end
    if AINPCServerEntities and AINPCServerEntities.records then
        for _, record in pairs(AINPCServerEntities.records) do inspect(record) end
    end
    if AINPCResidents and AINPCResidents.records then
        for _, record in pairs(AINPCResidents.records) do inspect(record) end
    end
    return math.max(0, count - 1), math.max(0, allies - 1)
end

function AINPCEnvironment.snapshot(npc, ped, source, archetype)
    local world = AINPCEnvironment.world()
    local coords, bucket, locationSource = entityPosition(npc, ped)
    if source and (not ped or ped == 0 or not DoesEntityExist(ped)) then
        bucket = GetPlayerRoutingBucket(source)
    end
    local zone
    if coords then
        local ok, value = pcall(GetNameOfZone, coords.x, coords.y, coords.z)
        if ok and type(value) == 'string' then zone = value end
    end
    local radius = Config.Behavior.surroundingsRadius or 30.0
    local players, vehicles, fastVehicles = 0, 0, 0
    if coords then
        local population = refreshPopulation()
        for _, player in ipairs(population.players) do
            if player.bucket == bucket and #(player.coords - coords) <= radius then players = players + 1 end
        end
        for _, vehicle in ipairs(population.vehicles) do
            if vehicle.bucket == bucket and #(vehicle.coords - coords) <= radius then
                vehicles = vehicles + 1
                if vehicle.speed >= (Config.Behavior.fastVehicleMetersPerSecond or 12.0) then fastVehicles = fastVehicles + 1 end
            end
        end
    end
    local managed, allies = 0, 0
    if coords then managed, allies = managedNearby(coords, bucket, radius, archetype) end
    local zoneTraits = zone and (Config.Behavior.zoneTraits or {})[zone] or nil
    return {
        world = world,
        location = {
            coords = coords and { x = coords.x, y = coords.y, z = coords.z } or nil,
            zone = zone,
            bucket = bucket,
            source = locationSource,
            traits = type(zoneTraits) == 'table' and zoneTraits or {}
        },
        surroundings = {
            nearbyPlayers = players,
            nearbyVehicles = vehicles,
            fastVehicles = fastVehicles,
            managedNpcs = managed,
            nearbyAllies = allies,
            crowded = players >= (Config.Behavior.crowdedPlayerCount or 4),
            trafficHeavy = vehicles >= (Config.Behavior.heavyTrafficVehicleCount or 8)
        }
    }
end
