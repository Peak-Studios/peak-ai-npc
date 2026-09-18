AINPCPoliceClient = {}
local sessionId, revision, sequence = nil, nil, 0

-- Main must supply only the currently accepted session, and clear it on close.
function AINPCPoliceClient.bind(id, version)
    sessionId, revision = id, version
end

RegisterCommand('ainpcpolice', function(_, args)
    local allowed = { stop=true, question=true, documents=true, request_exit=true, release=true }
    if not Config.Police.enabled or not sessionId or not allowed[args[1]] then return end
    sequence = sequence + 1
    TriggerServerEvent(AINPC.Event.PoliceRequest, sessionId, revision, args[1], sessionId .. ':' .. sequence)
end, false)

RegisterNetEvent(AINPC.Event.PoliceState, function(message)
    if source ~= 65535 or not sessionId or not revision or type(message) ~= 'table' then return end
    if message.ok == false then
        if message.sessionId == sessionId and message.sessionRevision == revision and type(message.reason) == 'string' then
            TriggerEvent('chat:addMessage', { args = { 'NPC police RP', 'Request rejected: ' .. message.reason:sub(1,100) .. '. Check duty, distance and current stop state.' } })
        end
        return
    end
    local result = message.result
    if type(result) ~= 'table' or result.sessionId ~= sessionId or result.sessionRevision ~= revision then return end
    -- Display data only; never use this response to authorize a physical action.
    TriggerEvent('chat:addMessage', { args = { 'NPC police RP', result.phase } })
    if result.documents then
        TriggerEvent('chat:addMessage', { args = { 'Fictional NPC document',
            tostring(result.documents.documentId) .. ' | ' .. tostring(result.documents.name) } })
    end
end)

RegisterNetEvent(AINPC.Event.PoliceExit, function(action)
    if source ~= 65535 or not Config.Police.enabled or type(action) ~= 'table'
        or type(action.actionId) ~= 'string' or type(action.entityNetId) ~= 'number'
        or type(action.vehicleNetId) ~= 'number' then return end
    local ped = NetworkGetEntityFromNetworkId(action.entityNetId)
    local vehicle = NetworkGetEntityFromNetworkId(action.vehicleNetId)
    if ped == 0 or vehicle == 0 or not DoesEntityExist(ped) or not DoesEntityExist(vehicle)
        or IsPedAPlayer(ped) or GetEntityModel(ped) ~= action.model
        or not NetworkHasControlOfEntity(ped) or GetPedInVehicleSeat(vehicle, -1) ~= ped
        or GetEntitySpeed(vehicle) > Config.Police.maximumVehicleSpeed
        or type(action.generation) ~= 'string' or Entity(ped).state.peak_ai_npc_identity ~= action.generation
        or Entity(ped).state['ainpc:policeExit'] ~= action.actionId then return end
    -- No control acquisition, teleport, task clearing, or automatic acceptance.
    Entity(ped).state:set('ainpc:policeExit', nil, false)
    TaskLeaveVehicle(ped, vehicle, 0)
    TriggerServerEvent(AINPC.Event.PoliceExitAck, action.actionId)
end)
