local activeNpc = nil
local localAmbientKeys = {}
local localResidentIds = {}
local nextLocalAmbientKey = 0
local pttHeld = false
local pttGeneration = 0
local pendingRecordGeneration = nil
local interactionPromptTarget = nil
local startSequence = 0

local function nextStartId()
    startSequence = startSequence + 1
    return tostring(startSequence)
end

function AINPCClearConversation()
    if AINPCPoliceClient then AINPCPoliceClient.bind(nil, nil) end
    if activeNpc and AINPCDiagnostics then AINPCDiagnostics.record(activeNpc.sessionId and 'session_end' or 'binding_failed', { sessionId = activeNpc.sessionId, residentId = activeNpc.npcId, generation = activeNpc.startId }, activeNpc.entity) end
    if AINPCCancelVoiceCapture then AINPCCancelVoiceCapture('conversation_cleared', pendingRecordGeneration or pttGeneration) end
    if activeNpc and not activeNpc.sessionId then TriggerServerEvent(AINPC.Event.End, nil, activeNpc.startId) end
    if activeNpc and activeNpc.ambient and activeNpc.entity and DoesEntityExist(activeNpc.entity) then
        if activeNpc.npcId and AINPCClientEntities then AINPCClientEntities[activeNpc.npcId] = nil end
    end
    activeNpc = nil
    pttHeld = false
    pttGeneration = pttGeneration + 1
    pendingRecordGeneration = nil
    if AINPCResetConversationUI then AINPCResetConversationUI('conversation_cleared') end
end

local function rounded(value)
    return math.floor(value * 10 + 0.5) / 10
end

local function nativeValue(fn, ...)
    if type(fn) ~= 'function' then return nil end
    local ok, value, extra = pcall(fn, ...)
    if not ok then return nil end
    return value, extra
end

local function nativeBool(fn, ...)
    return nativeValue(fn, ...) == true
end

local function vehicleObservation(ped)
    local vehicle = nativeValue(GetVehiclePedIsIn, ped, false)
    if type(vehicle) ~= 'number' or vehicle == 0 or not DoesEntityExist(vehicle) then return nil end
    return {
        model = GetEntityModel(vehicle),
        speed = rounded(GetEntitySpeed(vehicle)),
        isDriver = nativeValue(GetPedInVehicleSeat, vehicle, -1) == ped,
        engineRunning = nativeBool(GetIsVehicleEngineRunning, vehicle),
        sirenActive = nativeBool(IsVehicleSirenOn, vehicle)
    }
end

local function nearbyEntities(poolName, limit, detailed)
    local player = PlayerPedId()
    local origin = GetEntityCoords(player)
    local entities = {}
    for _, entity in ipairs(GetGamePool(poolName)) do
        if entity ~= player and DoesEntityExist(entity) and #(GetEntityCoords(entity) - origin) <= 35.0 then
            local item = {
                model = GetEntityModel(entity),
                networkId = NetworkGetEntityIsNetworked(entity) and NetworkGetNetworkIdFromEntity(entity) or nil,
                distance = rounded(#(GetEntityCoords(entity) - origin)),
                speed = rounded(GetEntitySpeed(entity))
            }
            if detailed and poolName == 'CPed' then
                item.human = nativeBool(IsPedHuman, entity)
                item.player = IsPedAPlayer(entity)
                item.dead = IsEntityDead(entity)
                item.inCombat = nativeBool(IsPedInCombat, entity, 0)
                item.shooting = nativeBool(IsPedShooting, entity)
                item.armed = nativeBool(IsPedArmed, entity, 7)
                item.inVehicle = nativeBool(IsPedInAnyVehicle, entity, false)
            elseif detailed and poolName == 'CVehicle' then
                item.sirenActive = nativeBool(IsVehicleSirenOn, entity)
                item.engineRunning = nativeBool(GetIsVehicleEngineRunning, entity)
            end
            entities[#entities + 1] = item
        end
    end
    table.sort(entities, function(a, b) return a.distance < b.distance end)
    while #entities > limit do table.remove(entities) end
    return entities
end

local function weatherName()
    local current = GetPrevWeatherTypeHashName()
    for _, name in ipairs({ 'EXTRASUNNY', 'CLEAR', 'CLOUDS', 'SMOG', 'FOGGY', 'OVERCAST', 'RAIN', 'THUNDER', 'CLEARING', 'NEUTRAL', 'SNOW', 'BLIZZARD', 'SNOWLIGHT', 'XMAS', 'HALLOWEEN' }) do
        if current == joaat(name) then return name end
    end
    return 'UNKNOWN'
end

local function isFacingEntity(player, npc, playerCoords, npcCoords)
    local dx, dy = npcCoords.x - playerCoords.x, npcCoords.y - playerCoords.y
    local length = math.sqrt(dx * dx + dy * dy)
    local forward = GetEntityForwardVector(player)
    -- Horizontal 90-degree cone; LOS is a separate necessary visibility gate.
    return length > 0.01 and (forward.x * dx + forward.y * dy) / length >= 0.70710678
        and HasEntityClearLosToEntity(player, npc, 17)
end

local function collectSceneObservation(detailed)
    local player = PlayerPedId()
    local playerCoords = GetEntityCoords(player)
    local camera = GetGameplayCamCoord()
    local rotation = GetGameplayCamRot(2)
    local weapon = GetSelectedPedWeapon(player)
    local streetHash, crossingHash = GetStreetNameAtCoord(playerCoords.x, playerCoords.y, playerCoords.z)
    local npcObservation
    local facingNpc = false
    if activeNpc and activeNpc.entity and DoesEntityExist(activeNpc.entity) then
        local npcCoords = GetEntityCoords(activeNpc.entity)
        facingNpc = isFacingEntity(player, activeNpc.entity, playerCoords, npcCoords)
        local npcWeapon = GetSelectedPedWeapon(activeNpc.entity)
        local now = GetGameTimer()
        local health = GetEntityHealth(activeNpc.entity)
        local damagedByPlayer = nativeBool(HasEntityBeenDamagedByEntity, activeNpc.entity, player, true)
        if (activeNpc.lastNpcHealth and health < activeNpc.lastNpcHealth) or (damagedByPlayer and not activeNpc.sawNpcDamage) then
            activeNpc.recentNpcDamageAt = now
        end
        activeNpc.lastNpcHealth = health
        activeNpc.sawNpcDamage = activeNpc.sawNpcDamage or damagedByPlayer
        npcObservation = {
            coords = { x = rounded(npcCoords.x), y = rounded(npcCoords.y), z = rounded(npcCoords.z) },
            heading = rounded(GetEntityHeading(activeNpc.entity)),
            distance = rounded(#(npcCoords - playerCoords)),
            speed = rounded(GetEntitySpeed(activeNpc.entity)),
            health = health,
            maxHealth = GetEntityMaxHealth(activeNpc.entity),
            inVehicle = IsPedInAnyVehicle(activeNpc.entity, false),
            vehicle = vehicleObservation(activeNpc.entity),
            inCombat = IsPedInCombat(activeNpc.entity, 0),
            inCombatWithPlayer = IsPedInCombat(activeNpc.entity, player),
            combatTargetIsPlayer = nativeValue(GetPedTargetFromCombatPed, activeNpc.entity, false) == player,
            relationshipToPlayer = nativeValue(GetRelationshipBetweenPeds, activeNpc.entity, player),
            isShooting = IsPedShooting(activeNpc.entity),
            inMelee = IsPedInMeleeCombat(activeNpc.entity),
            isArmed = IsPedArmed(activeNpc.entity, 7),
            weapon = npcWeapon ~= joaat('WEAPON_UNARMED') and npcWeapon or nil,
            weaponGroup = npcWeapon ~= joaat('WEAPON_UNARMED') and nativeValue(GetWeapontypeGroup, npcWeapon) or nil,
            isFleeing = IsPedFleeing(activeNpc.entity),
            inCover = IsPedInCover(activeNpc.entity, false),
            ragdoll = IsPedRagdoll(activeNpc.entity),
            injured = nativeBool(IsPedInjured, activeNpc.entity),
            dead = IsEntityDead(activeNpc.entity),
            onFire = nativeBool(IsEntityOnFire, activeNpc.entity),
            stunned = nativeBool(IsPedBeingStunned, activeNpc.entity, 0),
            usingScenario = nativeBool(IsPedUsingAnyScenario, activeNpc.entity),
            recentlyDamagedByPlayer = activeNpc.recentNpcDamageAt and now - activeNpc.recentNpcDamageAt <= 15000 or false,
            recentDamageAgeMs = activeNpc.recentNpcDamageAt and math.max(0, now - activeNpc.recentNpcDamageAt) or nil
        }
    end
    return {
        untrusted = true,
        camera = { x = rounded(camera.x), y = rounded(camera.y), z = rounded(camera.z), pitch = rounded(rotation.x), yaw = rounded(rotation.z) },
        player = {
            coords = { x = rounded(playerCoords.x), y = rounded(playerCoords.y), z = rounded(playerCoords.z) },
            aiming = IsPlayerFreeAiming(PlayerId()),
            aimingAtNpc = activeNpc and activeNpc.entity and DoesEntityExist(activeNpc.entity) and IsPlayerFreeAimingAtEntity(PlayerId(), activeNpc.entity) or false,
            isShooting = IsPedShooting(player),
            isArmed = IsPedArmed(player, 7),
            visibleWeapon = weapon ~= joaat('WEAPON_UNARMED') and weapon or nil,
            weaponGroup = weapon ~= joaat('WEAPON_UNARMED') and nativeValue(GetWeapontypeGroup, weapon) or nil,
            speed = rounded(GetEntitySpeed(player)),
            crouching = (GetPedStealthMovement(player) == 1 or (type(IsPedCrouching) == 'function' and IsPedCrouching(player))),
            running = (IsPedRunning(player) or IsPedSprinting(player)),
            inCover = IsPedInCover(player, false),
            facingNpc = facingNpc,
            health = GetEntityHealth(player),
            maxHealth = GetEntityMaxHealth(player),
            inVehicle = IsPedInAnyVehicle(player, false),
            vehicle = vehicleObservation(player),
            inCombat = IsPedInCombat(player, 0),
            inMelee = IsPedInMeleeCombat(player),
            injured = nativeBool(IsPedInjured, player),
            dead = IsEntityDead(player),
            onFire = nativeBool(IsEntityOnFire, player),
            stunned = nativeBool(IsPedBeingStunned, player, 0),
            wantedLevel = GetPlayerWantedLevel(PlayerId())
        },
        npc = npcObservation,
        world = {
            hour = GetClockHours(),
            minute = GetClockMinutes(),
            weather = weatherName(),
            zone = GetNameOfZone(playerCoords.x, playerCoords.y, playerCoords.z),
            street = streetHash ~= 0 and GetStreetNameFromHashKey(streetHash) or nil,
            crossing = crossingHash ~= 0 and GetStreetNameFromHashKey(crossingHash) or nil
        },
        detail = detailed == true and 'turn' or 'lightweight',
        nearbyPeds = detailed == true and nearbyEntities('CPed', 12, true) or {},
        nearbyVehicles = detailed == true and nearbyEntities('CVehicle', 12, true) or {}
    }
end

function AINPCRefreshSceneObservation(sessionId, detailed)
    if activeNpc and activeNpc.sessionId == sessionId then
        TriggerServerEvent(AINPC.Event.SceneObservation, sessionId, collectSceneObservation(detailed == true))
    end
end

local function cameraDirection(rotation)
    local pitch = math.rad(rotation.x)
    local yaw = math.rad(rotation.z)
    local horizontal = math.abs(math.cos(pitch))
    return vec3(-math.sin(yaw) * horizontal, math.cos(yaw) * horizontal, math.sin(pitch))
end

local function lookedAtNpc()
    local camera = GetGameplayCamCoord()
    local camRot = GetGameplayCamRot(2)
    local camDir = cameraDirection(camRot)
    local destination = camera + (camDir * 8.0)
    local ray = StartExpensiveSynchronousShapeTestLosProbe(camera.x, camera.y, camera.z, destination.x, destination.y, destination.z, 12, PlayerPedId(), 7)
    local _, hit, _, _, entity = GetShapeTestResult(ray)
    if hit == 1 and entity and entity ~= 0 then
        for id, ped in pairs(AINPCClientEntities or {}) do
            local npc = AINPCDefinitions[id]
            if ped == entity and npc and npc.enabled ~= false then
                local distance = #(GetEntityCoords(PlayerPedId()) - GetEntityCoords(ped))
                if distance <= (npc.interactionDistance or Config.Conversations.interactionDistance) then return id, ped end
            end
        end
        if IsEntityAPed(entity) and not IsPedAPlayer(entity) and not IsEntityDead(entity) then
            local distance = #(GetEntityCoords(PlayerPedId()) - GetEntityCoords(entity))
            if distance <= (Config.Ambient.interactionDistance or Config.Conversations.interactionDistance) then
                -- If this ped is standing near a configured NPC, return the configured NPC instead
                for id, cfgPed in pairs(AINPCClientEntities or {}) do
                    if DoesEntityExist(cfgPed) and #(GetEntityCoords(entity) - GetEntityCoords(cfgPed)) < 3.5 then
                        return id, cfgPed
                    end
                end
                for id, def in pairs(AINPCDefinitions or {}) do
                    if def.coords and #(GetEntityCoords(entity) - vec3(def.coords.x, def.coords.y, def.coords.z)) < 3.5 then
                        return id, AINPCClientEntities and AINPCClientEntities[id] or entity
                    end
                end
                return 'ambient', entity
            end
        end
        if type(IsEntityAVehicle) == 'function' and IsEntityAVehicle(entity) then
            local driver = GetPedInVehicleSeat(entity, -1)
            if driver ~= 0 and DoesEntityExist(driver) and IsPedHuman(driver) and not IsPedAPlayer(driver) and not IsEntityDead(driver) then
                local maxDist = math.max(Config.Ambient.interactionDistance or Config.Conversations.interactionDistance or 3.0, (Config.Police and Config.Police.interactionDistance) or 4.0)
                local distance = #(GetEntityCoords(PlayerPedId()) - GetEntityCoords(driver))
                if distance <= maxDist then
                    for id, ped in pairs(AINPCClientEntities or {}) do
                        local npc = AINPCDefinitions[id]
                        if ped == driver and npc and npc.enabled ~= false then
                            return id, driver
                        end
                    end
                    return 'ambient', driver
                end
            end
        end
    end

    -- Forward cone fallback for moving pedestrians when the narrow line ray misses
    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)
    local maxDist = Config.Ambient.interactionDistance or Config.Conversations.interactionDistance or 3.2
    local closestDist, candidatePed = maxDist, nil
    for _, ped in ipairs(GetGamePool('CPed')) do
        if ped ~= playerPed and DoesEntityExist(ped) and not IsPedAPlayer(ped) and not IsEntityDead(ped) and IsPedHuman(ped) then
            local pedCoords = GetEntityCoords(ped)
            local offset = pedCoords - playerCoords
            local dist = #(offset)
            if dist <= maxDist and dist < closestDist then
                local toPedDir = offset / (dist > 0.001 and dist or 1.0)
                local dot = camDir.x * toPedDir.x + camDir.y * toPedDir.y + camDir.z * toPedDir.z
                if dot > 0.60 and HasEntityClearLosToEntity(playerPed, ped, 17) then
                    closestDist = dist
                    candidatePed = ped
                end
            end
        end
    end
    if candidatePed then
        for id, cfgPed in pairs(AINPCClientEntities or {}) do
            if cfgPed == candidatePed or (DoesEntityExist(cfgPed) and #(GetEntityCoords(candidatePed) - GetEntityCoords(cfgPed)) < 3.5) then
                return id, cfgPed
            end
        end
        for id, def in pairs(AINPCDefinitions or {}) do
            if def.coords and #(GetEntityCoords(candidatePed) - vec3(def.coords.x, def.coords.y, def.coords.z)) < 3.5 then
                return id, AINPCClientEntities and AINPCClientEntities[id] or candidatePed
            end
        end
        return 'ambient', candidatePed
    end
    return nil
end

local function nearestConfiguredNpc()
    local player = PlayerPedId()
    local coords = GetEntityCoords(player)
    local closestDistance, closestId
    for id, npc in pairs(AINPCDefinitions or {}) do
        if npc.enabled ~= false then
            local distance = #(coords - vec3(npc.coords.x, npc.coords.y, npc.coords.z))
            if distance <= (npc.interactionDistance or Config.Conversations.interactionDistance)
                and (not closestDistance or distance < closestDistance) then
                closestDistance, closestId = distance, id
            end
        end
    end
    if not closestId then return nil end
    return closestId, AINPCClientEntities and AINPCClientEntities[closestId] or 0
end

local function interactionPromptLabel(npcId)
    if npcId == 'ambient' then return 'this resident' end
    local npc = AINPCDefinitions and AINPCDefinitions[npcId]
    return npc and npc.identity and npc.identity.name or 'this NPC'
end

local function requestConversation(npcId, entity, proactive)
    if activeNpc or type(npcId) ~= 'string' or not AINPCDefinitions[npcId] or AINPCDefinitions[npcId].enabled == false then return false end
    activeNpc = { npcId = npcId, entity = entity, startedAt = GetGameTimer(), startId = nextStartId(), proactive = proactive == true }
    if AINPCDiagnostics then AINPCDiagnostics.record('binding_start', { residentId = npcId, generation = activeNpc.startId }, entity) end
    local netId = 0
    if entity and entity ~= 0 and NetworkGetEntityIsNetworked(entity) then netId = NetworkGetNetworkIdFromEntity(entity) end
    TriggerServerEvent(AINPC.Event.Begin, npcId, netId, activeNpc.startId, proactive == true)
    return true
end

function AINPCStartConversation(npcId, entity)
    local current = AINPCClientEntities and AINPCClientEntities[npcId]
    if current and DoesEntityExist(current) then entity = current end
    return requestConversation(npcId, entity)
end

function AINPCStartAmbientConversation(entity, proactive)
    if activeNpc or not Config.Ambient.enabled or not entity or entity == 0 or not DoesEntityExist(entity) or IsPedAPlayer(entity) or IsEntityDead(entity) then return false end
    if not IsPedHuman(entity) or (IsEntityAMissionEntity(entity) and Entity(entity).state['ainpc:managed'] ~= true) then return false end
    -- Network identities are validated by the server; genuinely local peds
    -- retain the limited conversation-only descriptor path.
    local state = Entity(entity).state
    local key = localAmbientKeys[entity]
    if key and state['ainpc:localBindingKey'] ~= key then
        localAmbientKeys[entity], localResidentIds[entity], key = nil, nil, nil
    end
    if not key then
        nextLocalAmbientKey = nextLocalAmbientKey + 1
        key = tostring(nextLocalAmbientKey)
        localAmbientKeys[entity] = key
        state:set('ainpc:localBindingKey', key, false)
    end
    local coords = GetEntityCoords(entity)
    local components, props = {}, {}
    for component = 0, 11 do
        components[#components + 1] = { id = component, drawable = GetPedDrawableVariation(entity, component), texture = GetPedTextureVariation(entity, component), palette = GetPedPaletteVariation(entity, component) }
    end
    for prop = 0, 7 do
        props[#props + 1] = { id = prop, drawable = GetPedPropIndex(entity, prop), texture = GetPedPropTextureIndex(entity, prop) }
    end
    local stateResidentId = Entity(entity).state['ainpc:residentId']
    local isNetworked = NetworkGetEntityIsNetworked(entity)
    local inVeh = type(IsPedInAnyVehicle) == 'function' and IsPedInAnyVehicle(entity, false) or false
    local target = { localKey = key, residentId = type(stateResidentId) == 'string' and stateResidentId or localResidentIds[entity], model = GetEntityModel(entity), gender = IsPedMale(entity) and 'male' or 'female', appearance = { components = components, props = props }, coords = { x = coords.x, y = coords.y, z = coords.z, w = GetEntityHeading(entity) }, zone = GetNameOfZone(coords.x, coords.y, coords.z), inVehicle = inVeh, localEntity = not isNetworked, networkId = isNetworked and NetworkGetNetworkIdFromEntity(entity) or nil }
    activeNpc = { npcId = 'ambient', entity = entity, ambient = true, startedAt = GetGameTimer(), startId = nextStartId(), proactive = proactive == true }
    if AINPCDiagnostics then AINPCDiagnostics.record('binding_start', { generation = activeNpc.startId }, entity) end
    local start = activeNpc
    local function dispatch()
        if activeNpc ~= start then return end
        if not DoesEntityExist(entity) or IsEntityDead(entity) or GetEntityModel(entity) ~= target.model
            or Entity(entity).state['ainpc:localBindingKey'] ~= key then AINPCClearConversation(); return end
        local networkId = NetworkGetEntityIsNetworked(entity) and NetworkGetNetworkIdFromEntity(entity) or nil
        if type(networkId) == 'number' and networkId > 0 and networkId < 65528 then
            target.networkId, target.localEntity = networkId, false
        else
            target.networkId, target.localEntity = nil, true
        end
        TriggerServerEvent(AINPC.Event.BeginAmbient, target, start.startId, proactive == true)
    end
    if not isNetworked and type(NetworkRegisterEntityAsNetworked) == 'function' then
        CreateThread(function()
            if activeNpc ~= start or not DoesEntityExist(entity) then return end
            pcall(NetworkRegisterEntityAsNetworked, entity)
            -- At most 300ms; capture and G-release continue on their own threads.
            for _ = 1, 15 do
                if activeNpc ~= start or not DoesEntityExist(entity) then return end
                if NetworkGetEntityIsNetworked(entity) then break end
                Wait(20)
            end
            dispatch()
        end)
    else
        dispatch()
    end
    return true
end

exports('startConversation', function(npcId, entity)
    return requestConversation(npcId, entity or AINPCClientEntities[npcId] or 0)
end)

RegisterCommand('ainpc', function()
    local aimedId, aimedEntity = lookedAtNpc()
    if aimedId then
        if aimedId == 'ambient' then AINPCStartAmbientConversation(aimedEntity) else requestConversation(aimedId, aimedEntity) end
        return
    end
    local closestId, closestEntity = nearestConfiguredNpc()
    if closestId then requestConversation(closestId, closestEntity) end
end, false)

RegisterKeyMapping('ainpc', 'Talk to the nearest configured AI NPC', 'keyboard', 'E')

-- Authored NPCs keep a passive named prompt even when a target integration is
-- available; ambient peds defer to target integrations to avoid prompt spam.
-- Conversation authority remains server-side in every mode.
CreateThread(function()
    while true do
        Wait(math.max(100, tonumber(Config.Conversations.interactionPromptRefreshMs) or 250))
        interactionPromptTarget = nil
        local player = PlayerPedId()
        local nativeMode = not AINPCTargets or not AINPCTargets.resource or AINPCTargets.resource() == 'native'
        if not activeNpc
            and player ~= 0 and DoesEntityExist(player) and not IsEntityDead(player) and not IsPauseMenuActive() then
            local npcId, entity = lookedAtNpc()
            if npcId == 'ambient' and (not nativeMode or Config.Conversations.showNativeAmbientInteractionPrompt == false) then
                npcId, entity = nil, nil
            elseif npcId ~= 'ambient' and Config.Conversations.showConfiguredInteractionPrompt == false then
                npcId, entity = nil, nil
            end
            if not npcId and Config.Conversations.showConfiguredInteractionPrompt ~= false then
                npcId, entity = nearestConfiguredNpc()
            end
            if npcId and entity and entity ~= 0 and DoesEntityExist(entity) then
                interactionPromptTarget = { npcId = npcId, entity = entity }
            end
        end
    end
end)

-- Low-frequency, entry-triggered social initiative. It does no model work in a
-- loop: a single eligible pedestrian may ask the server to begin a conversation,
-- then both player and NPC cooldowns suppress repeated approaches.
local proactiveInside = {}
local proactiveNpcCooldowns = {}
local lastProactiveAt = -1000000

local function configuredIdForPed(ped)
    for id, entity in pairs(AINPCClientEntities or {}) do
        if entity == ped and AINPCDefinitions[id] and AINPCDefinitions[id].enabled ~= false then return id end
    end
    return nil
end

CreateThread(function()
    while true do
        local policy = Config.Proactive or {}
        Wait(math.max(1000, tonumber(policy.scanMs) or 2500))
        if policy.enabled == true and not activeNpc and not IsPauseMenuActive() then
            local player = PlayerPedId()
            local now = GetGameTimer()
            local globalCooldown = math.max(10000, (tonumber(policy.playerCooldownSeconds) or 90) * 1000)
            if player ~= 0 and DoesEntityExist(player) and not IsEntityDead(player)
                and not IsPedInAnyVehicle(player, false) and not IsPedInCombat(player, 0)
                and not IsPedArmed(player, 7) and GetEntitySpeed(player) <= 1.5
                and now - lastProactiveAt >= globalCooldown then
                local playerCoords = GetEntityCoords(player)
                local activationDistance = math.max(1.5, math.min(4.0, tonumber(policy.activationDistance) or 2.6))
                local current, closest, closestDistance = {}, nil, activationDistance + 0.01
                for _, ped in ipairs(GetGamePool('CPed')) do
                    if ped ~= player and DoesEntityExist(ped) and not IsPedAPlayer(ped) and not IsEntityDead(ped)
                        and IsPedHuman(ped) and not IsPedInAnyVehicle(ped, false) and not IsPedInCombat(ped, 0)
                        and not IsPedFleeing(ped) and not IsPedRagdoll(ped) and GetEntitySpeed(ped) <= 1.2 then
                        local coords = GetEntityCoords(ped)
                        local distance = #(coords - playerCoords)
                        if distance <= activationDistance and HasEntityClearLosToEntity(player, ped, 17)
                            and isFacingEntity(player, ped, playerCoords, coords) then
                            local configuredId = configuredIdForPed(ped)
                            local managed = Entity(ped).state['ainpc:managed'] == true
                            if configuredId or (policy.includeAmbient == true and (not IsEntityAMissionEntity(ped) or managed)) then
                                current[ped] = true
                                if not proactiveInside[ped] and distance < closestDistance then
                                    closest, closestDistance = { ped = ped, npcId = configuredId }, distance
                                end
                            end
                        end
                    end
                end
                proactiveInside = current
                if closest then
                    local cooldown = proactiveNpcCooldowns[closest.ped] or -1000000
                    local npcCooldown = math.max(10000, (tonumber(policy.npcCooldownSeconds) or 180) * 1000)
                    local chance = math.max(0, math.min(100, tonumber(policy.chancePercent) or 18))
                    if now - cooldown >= npcCooldown and math.random(100) <= chance then
                        local started = closest.npcId and requestConversation(closest.npcId, closest.ped, true)
                            or AINPCStartAmbientConversation(closest.ped, true)
                        if started then
                            lastProactiveAt = now
                            proactiveNpcCooldowns[closest.ped] = now
                        end
                    end
                end
            else
                proactiveInside = {}
            end
        elseif activeNpc then
            proactiveInside = {}
        end
    end
end)

CreateThread(function()
    while true do
        if interactionPromptTarget and DoesEntityExist(interactionPromptTarget.entity)
            and not IsEntityDead(interactionPromptTarget.entity) and not activeNpc and not IsPauseMenuActive() then
            local template = Config.Conversations.interactionPrompt or 'Press ~INPUT_CONTEXT~ to talk to %s'
            BeginTextCommandDisplayHelp('STRING')
            AddTextComponentSubstringPlayerName(template:format(interactionPromptLabel(interactionPromptTarget.npcId)))
            EndTextCommandDisplayHelp(0, false, true, -1)
            Wait(0)
        else
            Wait(250)
        end
    end
end)

RegisterCommand('ainpcvision', function(_, args)
    if not activeNpc or not activeNpc.sessionId then return end
    local prompt = table.concat(args or {}, ' ')
    if prompt == '' then prompt = 'Ignore all overlay panels, subtitles, prompts, and written UI text. Describe only relevant visible world facts in one compact sentence of at most 45 words.' end
    TriggerServerEvent(AINPC.Event.RequestVision, activeNpc.sessionId, prompt)
end, false)

function AINPCAcceptClientState(message)
    if type(message) ~= 'table' then return false end
    local payload = message.payload
    if payload and type(payload) ~= 'table' then return false end
    if payload and payload.nearby == true then return true end
    if payload and payload.startId and (not activeNpc or payload.startId ~= activeNpc.startId) then return false end
    if payload and payload.sessionId then
        -- A cleared conversation cannot be revived by delayed server state.
        -- Before binding, only the response to this exact local start may bind.
        if not activeNpc then return false end
        if activeNpc.sessionId then
            if payload.sessionId ~= activeNpc.sessionId then return false end
        elseif not activeNpc.startId or payload.startId ~= activeNpc.startId then return false end
    end
    if payload and type(payload.sessionRevision) == 'number' and activeNpc and activeNpc.sessionRevision
        and payload.sessionRevision < activeNpc.sessionRevision then return false end
    return true
end

RegisterNetEvent(AINPC.Event.ClientState, function(message)
    if not AINPCAcceptClientState(message) then return end
    if message.payload and message.payload.nearby == true then return end
    if activeNpc and message.payload and message.payload.nearby ~= true and type(message.payload.sessionRevision) == 'number' then
        activeNpc.sessionRevision = message.payload.sessionRevision
        if activeNpc.sessionId and AINPCPoliceClient then AINPCPoliceClient.bind(activeNpc.sessionId, activeNpc.sessionRevision) end
    end
    if message.payload and message.payload.sessionId and activeNpc then
        if not activeNpc.sessionId and AINPCDiagnostics then AINPCDiagnostics.record('binding_ready', { sessionId = message.payload.sessionId, residentId = message.payload.residentId or message.payload.npcId, generation = activeNpc.startId }, activeNpc.entity) end
        activeNpc.sessionId = message.payload.sessionId
        if AINPCPoliceClient and type(message.payload.sessionRevision) == 'number' then
            AINPCPoliceClient.bind(activeNpc.sessionId, message.payload.sessionRevision)
        end
        if AINPCOnSessionReady then AINPCOnSessionReady(message.payload.sessionId, message.payload.sessionRevision) end
        activeNpc.npcId = message.payload.npcId or activeNpc.npcId
        if message.payload.residentId and activeNpc.entity then localResidentIds[activeNpc.entity] = message.payload.residentId end
        if message.payload.npcId and activeNpc.entity and DoesEntityExist(activeNpc.entity) then
            AINPCClientEntities = AINPCClientEntities or {}
            AINPCClientEntities[message.payload.npcId] = activeNpc.entity
        end
        AINPCRefreshSceneObservation(activeNpc.sessionId, true)
    end
    if message.state == AINPC.State.Error and activeNpc and not activeNpc.sessionId then
        if AINPCNotify and message.payload and message.payload.message then AINPCNotify(message.payload.message) end
        AINPCClearConversation()
    end
    if message.state == AINPC.State.Idle and message.payload and message.payload.sessionId == nil then AINPCClearConversation() end
end)

RegisterNetEvent(AINPC.Event.ResidentHandoff, function(payload)
    if type(payload) ~= 'table' or type(payload.residentId) ~= 'string' or type(payload.netId) ~= 'number' then return end
    if payload.netId <= 0 or payload.netId >= 65528 then return end
    local original = activeNpc and activeNpc.ambient and activeNpc.entity or 0
    -- This legacy event used to hide and delete the original population ped
    -- before swapping in a network clone. Reject promotion without mutating
    -- either entity; the server then keeps the session on the local fallback.
    TriggerServerEvent('peak_ai_npc:server:residentHandoffFailed', payload.residentId, payload.netId)
end)

RegisterNetEvent(AINPC.Event.ResidentState, function(payload)
    if type(payload) ~= 'table' or payload.action ~= 'activate' or type(payload.netId) ~= 'number' then return end
    if payload.netId <= 0 or payload.netId >= 65528 then return end
    local ped = NetToPed(payload.netId)
    if ped == 0 or not DoesEntityExist(ped) then return end
    -- Legacy activation must not mutate an original entity.
end)

CreateThread(function()
    while true do
        Wait(math.max(1000, tonumber(Config.Conversations.sceneObservationRefreshMs) or 1500))
        if activeNpc and activeNpc.sessionId and activeNpc.entity and DoesEntityExist(activeNpc.entity) and not IsEntityDead(activeNpc.entity) then
            AINPCRefreshSceneObservation(activeNpc.sessionId, false)
            -- Config.Conversations.autoApproachDistance no longer drives
            -- interaction-time movement; only explicit accepted actions do.
        end
    end
end)

CreateThread(function()
    while true do
        Wait(0)
        if activeNpc and IsControlJustReleased(0, 177) then
            if activeNpc.sessionId then TriggerServerEvent(AINPC.Event.End, activeNpc.sessionId) end
            AINPCClearConversation()
        end
    end
end)

function AINPCOnSessionReady(sessionId, sessionRevision)
    if pendingRecordGeneration then
        local generation = pendingRecordGeneration
        pendingRecordGeneration = nil
        if AINPCBindVoiceCapture then AINPCBindVoiceCapture(generation, sessionId, sessionRevision) end
    end
end

RegisterCommand('+ainpcvoice', function()
    if pttHeld or not Config.VoiceInput.enabled then return end
    local player = PlayerPedId()
    if player == 0 or not DoesEntityExist(player) or IsEntityDead(player) then return end
    pttHeld = true
    pttGeneration = pttGeneration + 1
    local generation = pttGeneration
    if activeNpc and activeNpc.sessionId then
        if AINPCBeginVoiceCapture then AINPCBeginVoiceCapture(generation) end
        return
    end
    if activeNpc then
        pendingRecordGeneration = generation
        if AINPCBeginPendingVoiceCapture then AINPCBeginPendingVoiceCapture(generation) end
        return
    end
    local aimedId, aimedEntity = lookedAtNpc()
    if not aimedId or not aimedEntity or not DoesEntityExist(aimedEntity) then pttHeld = false; return end
    pendingRecordGeneration = generation
    if AINPCBeginPendingVoiceCapture then AINPCBeginPendingVoiceCapture(generation) end
    local started
    if aimedId == 'ambient' then started = AINPCStartAmbientConversation(aimedEntity)
    else started = requestConversation(aimedId, aimedEntity) end
    if not started then
        if AINPCCancelVoiceCapture then AINPCCancelVoiceCapture('start_failed', generation) end
        pendingRecordGeneration = nil
        pttHeld = false
    end
end, false)

RegisterCommand('-ainpcvoice', function()
    if not pttHeld then return end
    pttHeld = false
    if AINPCEndVoiceCapture then AINPCEndVoiceCapture(pttGeneration) end
end, false)

RegisterKeyMapping('+ainpcvoice', 'Talk to an AI NPC (hold)', 'keyboard', 'G')

RegisterCommand('ainpcmicsetup', function()
    if AINPCPromptMicrophoneSetup then AINPCPromptMicrophoneSetup() end
end, false)

CreateThread(function()
    Wait(5000)
    if Config.VoiceInput.enabled and AINPCNotify then
        AINPCNotify('Before talking to an NPC, use /ainpcmicsetup to prepare your microphone. Text remains available.')
    end
end)

-- Terminal session conditions are mirrored locally so media, focus, gaze and
-- temporary presentation state cannot survive a lost server cleanup packet.
CreateThread(function()
    while true do
        Wait(activeNpc and 250 or 1000)
        if activeNpc then
            local player = PlayerPedId()
            local npc = activeNpc.entity
            local reason
            if player == 0 or not DoesEntityExist(player) or IsEntityDead(player) then reason = 'player_unavailable'
            elseif not npc or npc == 0 or not DoesEntityExist(npc) or IsEntityDead(npc) then reason = 'npc_unavailable'
            elseif not activeNpc.sessionId and GetGameTimer() - (activeNpc.startedAt or GetGameTimer()) > (Config.Conversations.interactionStartTimeoutMs or 12000) then reason = 'start_timeout'
            elseif #(GetEntityCoords(player) - GetEntityCoords(npc)) > (Config.Conversations.maximumDistance or 8.0) then reason = 'out_of_range' end
            if reason then
                local sessionId = activeNpc.sessionId
                if sessionId then TriggerServerEvent(AINPC.Event.End, sessionId, reason) end
                AINPCClearConversation()
                if reason == 'start_timeout' and AINPCNotify then
                    AINPCNotify('The conversation did not start. Wait a moment and try again.')
                end
            end
        end
    end
end)
