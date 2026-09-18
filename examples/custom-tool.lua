-- Load this after peak-ai-npc in server.cfg.
exports['peak-ai-npc']:registerTool('custom_dispatch', {
    risk = 'write',
    description = 'Dispatch one of the server-approved service names.',
    parameters = {
        type = 'object',
        properties = { service = { type = 'string', minLength = 1, maxLength = 32 } },
        required = { 'service' },
        additionalProperties = false
    },
    validate = function(source, session, args)
        return type(args.service) == 'string' and #args.service <= 32, 'invalid_service'
    end,
    execute = function(source, session, args)
        -- Replace this with a server-authoritative integration owned by your resource.
        TriggerEvent('my_resource:server:dispatch', source, args.service)
        return { ok = true, service = args.service }
    end
})
