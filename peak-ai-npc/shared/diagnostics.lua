AINPCDiagnostics = {}
local stages = { binding_start=true, binding_ready=true, binding_failed=true, session_end=true,
    capture_start=true, capture_end=true, upload=true, transcript_accepted=true, provider_error=true, entity_sample=true }

local function safe(native, ...)
    if type(native) ~= 'function' then return nil end
    local ok, value = pcall(native, ...)
    if ok then return value end
end

local function correlation(value)
    if type(value) ~= 'string' and type(value) ~= 'number' then return nil end
    return tostring(joaat(tostring(value):sub(1, 160)))
end

function AINPCDiagnostics.record(stage, context, ped)
    if not Config.Diagnostics or Config.Diagnostics.enabled ~= true or not stages[stage] then return end
    context = type(context) == 'table' and context or {}
    local result = { stage=stage, version=AINPC.Version, at=GetGameTimer(),
        session=correlation(context.sessionId), turn=correlation(context.turnId), resident=correlation(context.residentId),
        generation=correlation(context.generation) }
    for _, key in ipairs({'bytes','durationMs','revision'}) do
        local value = context[key]
        if type(value)=='number' and value==value and value>=0 and value<=10000000 then result[key]=value end
    end
    if type(ped)=='number' and ped~=0 then
        result.exists = DoesEntityExist(ped)
        if result.exists then
            result.model = safe(GetEntityModel,ped)
            result.networkId = safe(NetworkGetNetworkIdFromEntity,ped)
            result.owner = safe(NetworkGetEntityOwner,ped)
            result.alpha = safe(GetEntityAlpha,ped)
            result.health = safe(GetEntityHealth,ped)
            result.vehicle = safe(GetVehiclePedIsIn,ped,false)
            local coords = safe(GetEntityCoords,ped)
            if coords then result.position={x=coords.x,y=coords.y,z=coords.z} end
            if result.vehicle and result.vehicle~=0 then
                for seat=-1,15 do
                    if safe(GetPedInVehicleSeat,result.vehicle,seat)==ped then result.seat=seat;break end
                end
            end
        end
    end
    -- Never serialize caller context wholesale: it may contain player speech,
    -- activation tokens, provider errors, or other private data.
    print('[peak-ai-npc][diagnostic] '..json.encode(result))
    return result
end
