AINPCContext = { providers = {}, owners = {} }

function AINPCContext.register(name, handler)
    if type(name) ~= 'string' or not name:match('^[%w_%-]+$') or #name > 64 or type(handler) ~= 'function' then return false end
    local owner = GetInvokingResource() or GetCurrentResourceName()
    if AINPCContext.providers[name] and AINPCContext.owners[name] ~= owner then return false, 'context_provider_already_registered' end
    AINPCContext.providers[name] = handler
    AINPCContext.owners[name] = owner
    return true
end

function AINPCContext.collect(source, session)
    local extensions = {}
    for name, handler in pairs(AINPCContext.providers) do
        local ok, value = pcall(handler, source, session)
        if ok and type(value) == 'table' then
            local encoded = json.encode(value)
            if encoded and #encoded <= 10000 then extensions[name] = value end
        end
    end
    return extensions
end

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then return end
    for name, owner in pairs(AINPCContext.owners) do
        if owner == resourceName then
            AINPCContext.providers[name] = nil
            AINPCContext.owners[name] = nil
        end
    end
end)
