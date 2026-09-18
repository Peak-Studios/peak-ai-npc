function AINPCApplyResidentAppearance(ped, appearance)
    if not ped or ped == 0 or not DoesEntityExist(ped) or type(appearance) ~= 'table' then return end
    for _, item in ipairs(appearance.components or {}) do
        if type(item.id) == 'number' and item.id >= 0 and item.id <= 11 then
            SetPedComponentVariation(ped, item.id, tonumber(item.drawable) or 0, tonumber(item.texture) or 0, tonumber(item.palette) or 0)
        end
    end
    for _, item in ipairs(appearance.props or {}) do
        if type(item.id) == 'number' and item.id >= 0 and item.id <= 7 then
            local drawable = tonumber(item.drawable) or -1
            if drawable < 0 then ClearPedProp(ped, item.id) else SetPedPropIndex(ped, item.id, drawable, tonumber(item.texture) or 0, true) end
        end
    end
end

AddStateBagChangeHandler('ainpc:appearance', nil, function(bagName, _, value)
    local entity = GetEntityFromStateBagName(bagName)
    if entity == 0 or not IsEntityAPed(entity) or IsPedAPlayer(entity) then return end
    AINPCApplyResidentAppearance(entity, value)
end)
