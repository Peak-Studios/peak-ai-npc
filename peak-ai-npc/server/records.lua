AINPCRecords = {}

local function context(source, session)
    local policy = Config.Police and Config.Police.records
    if not Config.Police or Config.Police.enabled ~= true or type(policy) ~= 'table' or policy.enabled ~= true
        or type(session) ~= 'table' or type(session.npc) ~= 'table' or session.npc.policeRecords ~= true then return nil, 'police_records_disabled' end
    local valid, reason = AINPCSessions.valid(source, session)
    if not valid then return nil, reason end
    if not session.entity or session.entity == 0 or session.npc.localEntity then return nil, 'network_entity_required' end
    local record = AINPCServerEntities and AINPCServerEntities.records[session.npcId]
    if not record or record.ped ~= session.entity then return nil, 'police_entity_unavailable' end
    if #(GetEntityCoords(GetPlayerPed(source)) - GetEntityCoords(session.entity)) > 3 then return nil, 'too_far' end
    local adapter = AINPCAdapters.framework()
    local player = adapter.getPlayer(source)
    local character = player and adapter.getCharacterId(player)
    if type(character) ~= 'string' or #character < 1 then return nil, 'player_unavailable' end
    -- Once private records enter history, the whole remaining session stays
    -- private. The model cannot turn observer delivery back on.
    session.privateReply = true
    if session.recordsCharacter and session.recordsCharacter ~= character then return nil, 'character_changed' end
    session.recordsCharacter = character
    session.recordsFramework = adapter.name
    return { adapter = adapter, player = player, identity = character, policy = policy, revision = session.revision }
end

function AINPCRecords.authorized(source, session, operation)
    local current, reason = context(source, session)
    if not current then return false, reason end
    if operation == 'police_check_warrants' and (current.policy.provider ~= 'fw-mdw' or current.adapter.name ~= 'fw-core'
        or GetResourceState('fw-mdw') ~= 'started') then return false, 'records_adapter_unavailable' end
    return true
end

function AINPCRecords.identification(source, session)
    local current, reason = context(source, session)
    if not current then return { ok = false, reason = reason } end
    local public = current.adapter.getPublicContext(current.player)
    if type(public.name) ~= 'string' or public.name == '' then return { ok = false, reason = 'identification_unavailable' } end
    return { ok = true, scope = 'self', name = public.name, verifiedCredential = false }
end

function AINPCRecords.warrants(source, session)
    local current, reason = context(source, session)
    if not current then return { ok = false, reason = reason } end
    if current.policy.provider ~= 'fw-mdw' or current.adapter.name ~= 'fw-core' or GetResourceState('fw-mdw') ~= 'started' then
        return { ok = false, reason = 'records_adapter_unavailable' }
    end
    local read, result = pcall(function() return exports['fw-mdw']:GetAINPCSelfWarrantStatus(source) end)
    local fresh, invalid = context(source, session)
    if not fresh or fresh.revision ~= current.revision or fresh.identity ~= current.identity then return { ok = false, reason = invalid or 'stale_records_request' } end
    if not read or GetResourceState('fw-mdw') ~= 'started' or type(result) ~= 'table' or result.ok ~= true
        or result.scope ~= 'self' or type(result.hasWarrant) ~= 'boolean'
        or type(result.warrantCount) ~= 'number' or result.warrantCount % 1 ~= 0 or result.warrantCount < 0
        or result.warrantCount > 100000 or result.hasWarrant ~= (result.warrantCount > 0) then
        return { ok = false, reason = 'records_unavailable' }
    end
    return { ok = true, scope = 'self', hasWarrant = result.hasWarrant, warrantCount = result.warrantCount }
end
