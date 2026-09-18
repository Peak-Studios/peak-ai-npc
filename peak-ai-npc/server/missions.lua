AINPCMissions = {
    definitions = {
        delivery_intro = { id = 'delivery_intro', label = 'First Delivery', description = 'Deliver the sealed parcel to the marked contact.', reward = 250, requiredRole = nil }
    },
    active = {}
}

local function identity(source)
    return AINPCAdapters.commerceIdentity(source)
end

local function key(character, missionId)
    return 'ainpc:mission:v1:' .. character .. ':' .. missionId
end

local function read(character, missionId)
    local ok, raw = pcall(GetResourceKvpString, key(character, missionId))
    if not ok then return nil, 'mission_storage_unavailable' end
    if not raw then return false end
    local decoded, state = pcall(json.decode, raw)
    if not decoded or type(state) ~= 'table' or state.missionId ~= missionId or state.character ~= character
        or (state.status ~= 'active' and state.status ~= 'completed') or type(state.reward) ~= 'number'
        or state.reward % 1 ~= 0 or state.reward < 1 or state.reward > Config.Security.maximumTransactionValue then
        return nil, 'mission_storage_invalid'
    end
    return state
end

local function save(state)
    local ok, raw = pcall(json.encode, state)
    if not ok then return false end
    local stored = pcall(SetResourceKvp, key(state.character, state.missionId), raw)
    local checked, actual = pcall(GetResourceKvpString, key(state.character, state.missionId))
    return stored and checked and actual == raw
end

local function public(state)
    return { missionId = state.missionId, status = state.status, startedAt = state.startedAt, completedAt = state.completedAt }
end

function AINPCMissions.offer(source, session, missionId)
    local valid, reason = AINPCSessions.valid(source, session)
    if not valid then return false, reason end
    local allowed = false
    for _, id in ipairs(session.npc.missions or {}) do if id == missionId then allowed = true break end end
    local mission = type(missionId) == 'string' and AINPCMissions.definitions[missionId]
    if not allowed or not mission then return false, 'mission_unavailable' end
    session.offeredMission = missionId
    return true, { status = 'offered', mission = mission }
end

function AINPCMissions.accept(source, session, missionId)
    local valid, reason = AINPCSessions.valid(source, session)
    if not valid then return false, reason end
    if session.offeredMission ~= missionId then return false, 'mission_not_offered' end
    local mission = type(missionId) == 'string' and AINPCMissions.definitions[missionId]
    if not mission then return false, 'mission_unavailable' end
    local character = identity(source)
    if not character then return false, 'mission_adapter_unavailable' end
    if mission.requiredRole then
        local adapter = AINPCAdapters.framework()
        local auth = adapter.getAuthorizationContext(adapter.getPlayer(source))
        if not auth or not auth.job or auth.job.name ~= mission.requiredRole then return false, 'mission_role_required' end
    end
    local previous, invalid = read(character, missionId)
    if previous == nil then return false, invalid end
    if previous then return false, previous.status == 'completed' and 'mission_already_completed' or 'mission_already_active' end
    local state = { character = character, missionId = missionId, status = 'active', startedAt = os.time(), reward = mission.reward }
    if type(state.reward) ~= 'number' or state.reward % 1 ~= 0 or state.reward < 1 or state.reward > Config.Security.maximumTransactionValue then
        return false, 'invalid_mission_reward'
    end
    if not save(state) then return false, 'mission_storage_unavailable' end
    session.offeredMission = nil
    return true, public(state)
end

function AINPCMissions.cancelSource(source)
    -- Disconnect releases only ephemeral work. Accepted missions and paid
    -- completion receipts are character-bound and survive reconnect/restart.
    AINPCMissions.active[source] = nil
end

function AINPCMissions.context(source)
    local character = identity(source)
    if not character then return {} end
    local result = {}
    for missionId in pairs(AINPCMissions.definitions) do
        local state = read(character, missionId)
        if state then result[#result + 1] = public(state) end
        if #result >= 8 then break end
    end
    return result
end

function AINPCMissions.complete(source, missionId)
    local owner = GetInvokingResource() or GetCurrentResourceName()
    local integrations = Config.Missions and Config.Missions.integrations
    if owner ~= GetCurrentResourceName() and (type(integrations) ~= 'table' or integrations[owner] ~= true or GetResourceState(owner) ~= 'started') then
        return false, 'mission_integration_not_allowed'
    end
    if type(missionId) ~= 'string' or not AINPCMissions.definitions[missionId] then return false, 'mission_unavailable' end
    local character = identity(source)
    if not character then return false, 'mission_adapter_unavailable' end
    local state, reason = read(character, missionId)
    if not state then return false, reason or 'mission_not_active' end
    if state.status == 'completed' then return true, public(state) end
    local function stillValid()
        return identity(source) == character and (owner == GetCurrentResourceName()
            or (Config.Missions.integrations[owner] == true and GetResourceState(owner) == 'started'))
    end
    local paid, failure = AINPCAdapters.reward(source, state.reward, 'mission:' .. missionId, stillValid)
    if not paid then return false, failure end
    state.status, state.completedAt = 'completed', os.time()
    if not save(state) then return false, 'mission_storage_unavailable' end
    return true, public(state)
end
