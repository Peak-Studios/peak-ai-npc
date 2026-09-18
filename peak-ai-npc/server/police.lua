AINPCPolice = {}
local incidents, residentLocks, windows = {}, {}, {}
local sequence = 0
local replaySessions = {}
local actions = { stop=true, question=true, documents=true, request_exit=true, release=true }

local function integer(value)
    return type(value)=='number' and value>=1 and value<=2147483647 and value%1==0
end

local function officer(source)
    if not Config.Police or Config.Police.enabled ~= true then return false, 'police_disabled' end
    local ok, adapter = pcall(AINPCAdapters.framework)
    if not ok or not adapter then return false, 'framework_unavailable' end
    local fwName = adapter.name
    if fwName ~= 'fw-core' and fwName ~= 'qbcore' and fwName ~= 'qbox' then return false, 'supported_framework_required' end
    local found, player = pcall(adapter.getPlayer, source)
    if not found or not player then return false, 'player_unavailable' end
    local read, context = pcall(adapter.getPublicContext, player)
    local job = read and type(context) == 'table' and context.job
    local allowedJobs = Config.Police.jobs or { police = true, sheriff = true, state = true, trooper = true }
    if type(job) ~= 'table' or allowedJobs[job.name] ~= true or job.onduty ~= true then return false, 'on_duty_police_required' end
    return true
end

local function validate(source,sessionId,revision)
    local allowed,reason=officer(source)
    if not allowed then return nil,reason end
    local session=AINPCSessions.get(source)
    if type(sessionId)~='string' or not integer(revision) or not session or session.id~=sessionId or session.revision~=revision then return nil,'stale_session' end
    local valid,why=AINPCSessions.valid(source,session)
    if not valid then return nil,why end
    local ped=session.entity
    if session.npc.localEntity or not ped or ped==0 or not DoesEntityExist(ped) then return nil,'network_driver_required' end
    if type(session.npcId)~='string' or not session.npcId:match('^resident:[%w%-]+$') then return nil,'durable_resident_required' end
    if GetPlayerRoutingBucket(source)~=GetEntityRoutingBucket(ped) then return nil,'npc_not_in_bucket' end
    if #(GetEntityCoords(GetPlayerPed(source))-GetEntityCoords(ped))>Config.Police.interactionDistance then return nil,'too_far' end
    return session
end

local function driverVehicle(session)
    local vehicle=GetVehiclePedIsIn(session.entity,false)
    if vehicle==0 or not DoesEntityExist(vehicle) or GetPedInVehicleSeat(vehicle,-1)~=session.entity then return nil,'driver_required' end
    if GetEntityRoutingBucket(vehicle)~=GetEntityRoutingBucket(session.entity) then return nil,'vehicle_not_in_bucket' end
    if GetEntitySpeed(vehicle)>Config.Police.maximumVehicleSpeed then return nil,'vehicle_must_be_stationary' end
    return vehicle
end

local function documents(session)
    local key=('ainpc:police-documents:%s:%s'):format(GetConvar('peak_ai_npc_server_id','local'),session.npcId)
    local read,raw=pcall(GetResourceKvpString,key)
    if not read then return nil,'document_storage_unavailable' end
    if raw~=nil then
        local ok,value=pcall(json.decode,raw)
        if not ok or type(value)~='table' or value.version~=1 or value.residentId~=session.npcId or value.fictional~=true
            or type(value.documentId)~='string' or type(value.name)~='string' then return nil,'document_storage_invalid' end
        return value
    end
    local seed=math.abs(joaat(session.npcId))
    local value={version=1,fictional=true,residentId=session.npcId,documentId='NPC-'..tostring(seed),
        name=tostring(session.npc.identity and session.npc.identity.name or 'Fictional resident'):sub(1,80),
        birthYear=1970+(seed%30),licenceStatus='valid',issuedAt=os.time()}
    local encoded=json.encode(value)
    local wrote=pcall(SetResourceKvp,key,encoded)
    local verified,saved=pcall(GetResourceKvpString,key)
    if not wrote or not verified or saved~=encoded then return nil,'document_storage_write_failed' end
    return value
end

local function historyKey(residentId)
    return ('ainpc:police-history:%s:%s'):format(GetConvar('peak_ai_npc_server_id','local'),residentId)
end

local function readHistory(residentId)
    local key=historyKey(residentId)
    local read,raw=pcall(GetResourceKvpString,key)
    if not read or not raw then return {} end
    local ok,entries=pcall(json.decode,raw)
    if ok and type(entries)=='table' then return entries end
    return {}
end

local function recordHistory(residentId,entry)
    local entries=readHistory(residentId)
    table.insert(entries,1,entry)
    while #entries>20 do table.remove(entries) end
    local key=historyKey(residentId)
    pcall(SetResourceKvp,key,json.encode(entries))
end

local function public(incident)
    return {sessionId=incident.session.id,sessionRevision=incident.session.revision,residentId=incident.residentId,
        incidentId=incident.id,version=incident.version,phase=incident.phase,documents=incident.documents}
end

local function publish(source,incident)
    TriggerClientEvent(AINPC.Event.PoliceState,source,{ok=true,result=public(incident)})
end

local function clearExit(incident)
    local ped = incident.session.entity
    if incident.exit and DoesEntityExist(ped) and GetEntityModel(ped) == incident.pedModel
        and Entity(ped).state.peak_ai_npc_identity == incident.generation
        and Entity(ped).state['ainpc:policeExit'] == incident.exit.id then
        Entity(ped).state:set('ainpc:policeExit',nil,true)
    end
end

local function close(source,reason)
    local incident=incidents[source]
    if not incident then return end
    clearExit(incident)
    incident.phase='released';incident.version=incident.version+1;incident.exit=nil
    if residentLocks[incident.residentId]==incident then residentLocks[incident.residentId]=nil end
    incidents[source]=nil
    recordHistory(incident.residentId,{
        incidentId=incident.id,
        at=os.time(),
        action='close',
        phase='released',
        reason=reason
    })
    TriggerClientEvent(AINPC.Event.PoliceState,source,{ok=true,result=public(incident),reason=reason})
end

local function current(source,session)
    local incident=incidents[source]
    if incident and incident.session~=session then close(source,'session_changed');return nil end
    return incident
end

function AINPCPolice.request(source,sessionId,revision,action,requestId)
    local session,reason=validate(source,sessionId,revision)
    if not session then close(source,reason);return false,reason end
    if type(action)~='string' or not actions[action] or type(requestId)~='string' or #requestId<1 or #requestId>80 or not requestId:match('^[%w:%-]+$') then return false,'invalid_police_request' end
    local incident=current(source,session)
    local replay = replaySessions[source]
    if not replay or replay.session ~= session then replay={session=session,ids={},count=0};replaySessions[source]=replay end
    if replay.ids[requestId] then return false,'police_request_replayed' end
    if replay.count >= 100 then return false,'police_session_request_limit' end
    replay.ids[requestId]=true;replay.count=replay.count+1
    if incident and incident.replays[requestId] then
        if incident.replays[requestId]~=action then return false,'request_id_conflict' end
        return false,'police_request_replayed'
    end
    local window=windows[source]
    if not window or os.time()-window.at>=60 then window={at=os.time(),count=0};windows[source]=window end
    window.count=window.count+1
    if window.count>Config.Police.maximumRequestsPerMinute then return false,'police_rate_limited' end
    if action=='release' then
        if not incident then return false,'no_police_stop' end
        close(source,'officer_release');return true,{phase='released'}
    end
    if action=='stop' then
        if incident or residentLocks[session.npcId] then return false,'police_stop_exists' end
        local vehicle,why=driverVehicle(session)
        if not vehicle then return false,why end
        sequence=sequence+1
        incident={id=session.id..':police:'..sequence,session=session,residentId=session.npcId,vehicle=vehicle,
            pedModel=GetEntityModel(session.entity),generation=session.npc.bindingIdentity or session.npc.id,
            vehicleModel=GetEntityModel(vehicle),phase='stopped',version=1,replays={},requestCount=0}
        incidents[source]=incident;residentLocks[session.npcId]=incident
        local plate = vehicle and DoesEntityExist(vehicle) and type(GetVehicleNumberPlateText) == 'function' and GetVehicleNumberPlateText(vehicle) or nil
        recordHistory(session.npcId,{
            incidentId=incident.id,
            at=os.time(),
            vehicleModel=GetEntityModel(vehicle),
            plate=plate and tostring(plate):gsub('%s+$','') or nil,
            action='stop',
            phase='stopped'
        })
    else
        if not incident then return false,'no_police_stop' end
        if incident.exit then return false,'exit_pending' end
        if incident.phase~='exited' then
            local vehicle,why=driverVehicle(session)
            if not vehicle or vehicle~=incident.vehicle or GetEntityModel(vehicle)~=incident.vehicleModel then close(source,'driver_changed');return false,why or 'driver_changed' end
        end
        if action=='question' then incident.phase='questioning'
        elseif action=='documents' then
            local value,why=documents(session)
            if not value then return false,why end
            incident.documents=value;incident.phase='documents_requested'
        elseif action=='request_exit' then
            if incident.phase=='exited' then return false,'driver_already_exited' end
            incident.phase='exit_requested'
        end
        incident.version=incident.version+1
    end
    incident.requestCount=incident.requestCount+1
    if incident.requestCount>100 then close(source,'request_limit');return false,'police_request_limit' end
    incident.replays[requestId]=action
    publish(source,incident)
    return true,public(incident)
end

function AINPCPolice.respondToExit(source,sessionId,revision,accepted)
    local session,reason=validate(source,sessionId,revision)
    if not session then close(source,reason);return false,reason end
    local incident=current(source,session)
    if type(accepted)~='boolean' or not incident or incident.phase~='exit_requested' or incident.exit then return false,'no_exit_request' end
    if not accepted then incident.phase='exit_declined';incident.version=incident.version+1;publish(source,incident);return true,{phase=incident.phase} end
    local vehicle,why=driverVehicle(session)
    if not vehicle or vehicle~=incident.vehicle or GetEntityModel(vehicle)~=incident.vehicleModel then return false,why or 'driver_changed' end
    local owner=NetworkGetEntityOwner(session.entity)
    if type(owner)~='number' or owner<=0 or GetPlayerRoutingBucket(owner)~=GetPlayerRoutingBucket(source) then return false,'entity_owner_unavailable' end
    incident.version=incident.version+1
    local token=incident.id..':exit:'..incident.version
    incident.exit={id=token,owner=owner,revision=revision,expires=GetGameTimer()+Config.Police.exitTimeoutMs}
    incident.phase='exit_accepted'
    recordHistory(session.npcId,{
        incidentId=incident.id,
        at=os.time(),
        action='exit_accepted',
        phase='exit_accepted'
    })
    Entity(session.entity).state:set('ainpc:policeExit',token,true)
    TriggerClientEvent(AINPC.Event.PoliceExit,owner,{actionId=token,entityNetId=NetworkGetNetworkIdFromEntity(session.entity),
        model=GetEntityModel(session.entity),vehicleNetId=NetworkGetNetworkIdFromEntity(vehicle),
        generation=session.npc.bindingIdentity or session.npc.id})
    publish(source,incident)
    return true,{phase='exit_accepted'}
end

-- Parent calls this while building authoritative context; no spoken role claims.
function AINPCPolice.context(source,session)
    local valid=validate(source,session.id,session.revision)
    if not valid then return nil end
    local incident=current(source,session)
    local result = incident and public(incident) or {phase='none',onDutyPolice=true}
    local history = readHistory(session.npcId)
    if #history > 0 then
        result.history = history
    end
    return result
end

function AINPCPolice.history(residentId)
    if type(residentId)~='string' or not residentId:match('^resident:[%w%-]+$') then return {} end
    return readHistory(residentId)
end

function AINPCPolice.prepareSession(source,session)
    local list={}
    for _,name in ipairs(session.npc.allowedTools or {}) do if name~='police_respond_exit' then list[#list+1]=name end end
    session.npc.allowedTools=list
    if not validate(source,session.id,session.revision) then return false end
    list[#list+1]='police_respond_exit';session.npc.allowedTools=list
    return true
end

AINPCTools.register('police_respond_exit',{
    description='Respond to an existing verified officer request to exit this stationary vehicle. Acceptance permits only leaving the current driver seat.',
    parameters={type='object',properties={accepted={type='boolean'}},required={'accepted'},additionalProperties=false},risk='write',
    validate=function(source,session,args)
        if type(args.accepted)~='boolean' then return false,'invalid_acceptance' end
        return validate(source,session.id,session.revision)~=nil
    end,
    execute=function(source,session,args)
        local ok,result=AINPCPolice.respondToExit(source,session.id,session.revision,args.accepted)
        return ok and result or {ok=false,reason=result}
    end
})

RegisterNetEvent(AINPC.Event.PoliceRequest,function(sessionId,revision,action,requestId)
    local source=source
    local ok,result=AINPCPolice.request(source,sessionId,revision,action,requestId)
    if not ok then TriggerClientEvent(AINPC.Event.PoliceState,source,{ok=false,reason=result,sessionId=type(sessionId)=='string' and sessionId:sub(1,200) or nil,sessionRevision=type(revision)=='number' and revision or nil}) end
end)

-- ACK alone never establishes completion: the server observes the original seat.
RegisterNetEvent(AINPC.Event.PoliceExitAck,function(actionId)
    local sender=source
    for _,incident in pairs(incidents) do
        if incident.exit and incident.exit.id==actionId and incident.exit.owner==sender then incident.exit.ack=true;return end
    end
end)

CreateThread(function()
    while true do
        Wait(250)
        for source,incident in pairs(incidents) do
            local session=validate(source,incident.session.id,incident.session.revision)
            if not session then close(source,'scope_or_duty_lost')
            elseif incident.exit then
                if session.revision~=incident.exit.revision or not DoesEntityExist(incident.vehicle) then close(source,'exit_scope_changed')
                elseif GetVehiclePedIsIn(session.entity,false)==0 then
                    clearExit(incident)
                    incident.exit=nil;incident.phase='exited';incident.version=incident.version+1;publish(source,incident)
                elseif GetGameTimer()>=incident.exit.expires then
                    clearExit(incident)
                    incident.exit=nil;incident.phase='exit_declined';incident.version=incident.version+1;publish(source,incident)
                end
            end
        end
    end
end)

exports('respondToPoliceExit',function(source,sessionId,revision,accepted)
    local invoking=GetInvokingResource()
    if not invoking or Config.Police.integrations[invoking]~=true or GetResourceState(invoking)~='started' then return false,'integration_not_enabled' end
    return AINPCPolice.respondToExit(source,sessionId,revision,accepted)
end)
exports('policeHistory',function(residentId)
    return AINPCPolice.history(residentId)
end)
exports('getPoliceHistory',function(residentId)
    return AINPCPolice.history(residentId)
end)
AddEventHandler('playerDropped',function() close(source,'disconnect');windows[source]=nil;replaySessions[source]=nil end)
AddEventHandler('onResourceStop',function(resource)
    if resource==GetCurrentResourceName() or resource=='qb-core' then for source in pairs(incidents) do close(source,'resource_stopped') end end
end)
