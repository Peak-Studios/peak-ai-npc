AINPCMedical = {}

local function context(source, session)
    if not Config.Medical or Config.Medical.enabled ~= true or not session or session.npc.medical ~= true then
        return nil, 'medical_unavailable'
    end
    local valid, reason = AINPCCommerce.validate(source, session)
    if not valid then return nil, reason end
    local ok, player, identity = pcall(function()
        local adapter = AINPCAdapters.framework()
        local current = adapter.getPlayer(source)
        local character = current and adapter.getCharacterId(current)
        if type(character) ~= 'string' or #character < 1 or #character > 128 then return nil end
        return current, adapter.name .. ':' .. character
    end)
    if not ok or not player then return nil, 'player_unavailable' end
    return { player = player, identity = identity }
end

function AINPCMedical.triage(source, session)
    local current, reason = context(source, session)
    if not current then return { ok = false, reason = reason } end
    local ped = GetPlayerPed(source)
    local healthOk, health = pcall(GetEntityHealth, ped)
    if not healthOk or type(health) ~= 'number' or health ~= health or health < 0 or health > 10000 then
        return { ok = false, reason = 'medical_observation_unavailable' }
    end
    -- Only this player's observable state is returned. No blood type, phone,
    -- fingerprints, records, or invented metadata defaults enter model context.
    return { ok = true, health = health, status = 'assessment_required',
        scope = 'self', treatmentAuthority = 'installed_medical_system' }
end

function AINPCMedical.supplies(source, session, args)
    local current, reason = context(source, session)
    if not current then return { ok = false, reason = reason } end
    local policy = type(Config.Medical.supplies) == 'table' and type(args) == 'table' and type(args.item) == 'string' and Config.Medical.supplies[args.item]
    if not policy then return { ok = false, reason = 'medical_item_not_allowed' } end
    local ok, result = AINPCCommerce.quote(source, session, { item = args.item, quantity = args.quantity }, 'buy')
    return ok and result or { ok = false, reason = result }
end

function AINPCMedical.handoff(source, session, args)
    local current, reason = context(source, session)
    if not current then return { ok = false, reason = reason } end
    if type(args) ~= 'table' or (args.treatmentType ~= 'first_aid' and args.treatmentType ~= 'full_heal') then
        return { ok = false, reason = 'invalid_treatment_type' }
    end
    local policy = Config.Medical.treatment
    if type(policy) ~= 'table' or type(policy.provider) ~= 'string' or GetResourceState(policy.provider) ~= 'started' then
        return { ok = false, reason = 'medical_adapter_unavailable' }
    end
    local location = policy.location
    if type(location) ~= 'table' then return { ok = false, reason = 'invalid_medical_destination' } end
    for _, axis in ipairs({ 'x', 'y', 'z' }) do
        local value = location[axis]
        if type(value) ~= 'number' or value ~= value or math.abs(value) > 100000 then return { ok = false, reason = 'invalid_medical_destination' } end
    end
    local cooldown = policy.cooldownSeconds
    if type(cooldown) ~= 'number' or cooldown % 1 ~= 0 or cooldown < 1 or cooldown > 86400 then
        return { ok = false, reason = 'invalid_medical_policy' }
    end
    local key = 'ainpc:medical-handoff:v1:' .. current.identity
    local read, previous = pcall(GetResourceKvpString, key)
    if not read or (previous and not tonumber(previous)) then return { ok = false, reason = 'medical_storage_unavailable' } end
    if previous and tonumber(previous) > os.time() then return { ok = false, reason = 'medical_cooldown_active' } end
    local value = tostring(os.time() + cooldown)
    local wrote = pcall(SetResourceKvp, key, value)
    local readBack, stored = pcall(GetResourceKvpString, key)
    if not wrote or not readBack or stored ~= value then return { ok = false, reason = 'medical_storage_unavailable' } end
    -- This is navigation to check-in, not a health mutation or a fabricated
    -- successful treatment. The installed resource owns payment and treatment.
    TriggerClientEvent('peak_ai_npc:client:medicalHandoff', source, {
        sessionId = session.id, sessionRevision = session.revision,
        label = type(policy.label) == 'string' and policy.label:sub(1, 96) or 'Hospital reception',
        location = { x = location.x, y = location.y, z = location.z }
    })
    return { ok = true, treatmentCompleted = false, requiresPlayerAction = true,
        action = 'hospital_check_in', message = 'Go to hospital reception for assessment and treatment.' }
end
