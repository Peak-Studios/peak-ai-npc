local activeSubtitles = {}
local playerSubtitle = nil
local preferenceKey = 'peak_ai_npc:subtitles'
local accessibilityKey = 'peak_ai_npc:accessibility'

local function textLength(value)
    local text = tostring(value or '')
    return utf8 and utf8.len and (utf8.len(text) or #text) or #text
end

local function storedBoolean(key, fallback)
    local value = GetResourceKvpString(key)
    if value == '1' then return true end
    if value == '0' then return false end
    return fallback
end

local function setStoredBoolean(key, value)
    SetResourceKvp(key, value and '1' or '0')
end

function AINPCShouldShowSubtitle(isInteracting, hasAudio)
    if not Config.Subtitles.enabled then return false end
    if Config.Subtitles.audience == 'interacting' and not isInteracting then return false end
    local mode = Config.Subtitles.mode or 'always'
    if mode == 'never' then return false end
    if mode == 'audio_failed' then return not hasAudio end
    if mode == 'player_preference' then
        return storedBoolean(preferenceKey, Config.Subtitles.playerPreferenceDefault ~= false)
    end
    if mode == 'accessibility' then
        return storedBoolean(accessibilityKey, Config.Subtitles.accessibilityDefault == true)
    end
    return mode == 'always'
end

local function durationFor(text)
    local length = textLength(text)
    return math.min(Config.Subtitles.maximumDurationMs, math.max(Config.Subtitles.minimumDurationMs, length * Config.Subtitles.millisecondsPerCharacter))
end

local function wrappedLines(text)
    local lines, current = {}, ''
    local safeText = tostring(text or ''):gsub('~', '')
    for word in safeText:gmatch('%S+') do
        local candidate = current == '' and word or (current .. ' ' .. word)
        if textLength(candidate) > Config.Subtitles.charactersPerLine and current ~= '' then
            lines[#lines + 1] = current
            current = word
            if #lines >= Config.Subtitles.maximumLines then break end
        else
            current = candidate
        end
    end
    if current ~= '' and #lines < Config.Subtitles.maximumLines then lines[#lines + 1] = current end
    if #lines == Config.Subtitles.maximumLines then
        local consumed = table.concat(lines, ' ')
        if textLength(consumed) < textLength(safeText) then lines[#lines] = lines[#lines] .. '…' end
    end
    return lines
end

local function drawText(text, x, y, scale, color, alpha, font)
    SetTextFont(font or 4)
    SetTextScale(0.0, scale)
    SetTextColour(color[1], color[2], color[3], alpha)
    SetTextCentre(true)
    SetTextOutline()
    SetTextDropShadow()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(tostring(text or ''):gsub('~', ''))
    EndTextCommandDisplayText(x, y)
end

local function drawSubtitle(ped, entry)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return false end
    local playerPed = PlayerPedId()
    local distance = #(GetEntityCoords(playerPed) - GetEntityCoords(ped))
    if distance > Config.Subtitles.maximumDistance then return true end
    if ped ~= playerPed and Config.Subtitles.requireLineOfSight and not HasEntityClearLosToEntity(playerPed, ped, 17) then return true end

    local head = GetPedBoneCoords(ped, 31086, 0.0, 0.0, Config.Subtitles.headOffset)
    local visible, x, y = World3dToScreen2d(head.x, head.y, head.z)
    if not visible then return true end

    local remaining = entry.expiresAt - GetGameTimer()
    local alpha = 235
    if remaining < Config.Subtitles.fadeDurationMs then
        alpha = math.floor(235 * math.max(0.0, remaining / Config.Subtitles.fadeDurationMs))
    end

    local distanceScale = math.max(0.72, 1.0 - (distance / Config.Subtitles.maximumDistance) * 0.28)
    local lines = entry.lines
    local lineHeight = 0.024 * distanceScale
    local height = (#lines * lineHeight) + (entry.name and 0.029 or 0.014)
    local longest = 0
    for _, line in ipairs(lines) do longest = math.max(longest, textLength(line)) end
    local width = math.min(0.25, math.max(0.105, longest * 0.0042 * distanceScale))

    DrawRect(x, y + height * 0.46, width, height, 11, 14, 12, math.floor(alpha * 0.82))
    if entry.name then
        drawText(entry.name, x, y + 0.002, 0.255 * distanceScale, Config.Subtitles.accentColor, alpha, 4)
    end
    local startY = y + (entry.name and 0.023 or 0.009)
    for index, line in ipairs(lines) do
        drawText(line, x, startY + ((index - 1) * lineHeight), 0.31 * distanceScale, { 247, 247, 245 }, alpha, 4)
    end
    return true
end

function AINPCShowSubtitle(npcId, text, name, utteranceId)
    if not Config.Subtitles.enabled or type(npcId) ~= 'string' or type(text) ~= 'string' or text == '' then return false end
    local ped = AINPCClientEntities and AINPCClientEntities[npcId]
    if not ped or not DoesEntityExist(ped) then return false end
    activeSubtitles[npcId] = {
        text = text,
        name = type(name) == 'string' and name or (AINPCDefinitions[npcId] and AINPCDefinitions[npcId].identity.name),
        utteranceId = utteranceId,
        lines = wrappedLines(text),
        expiresAt = GetGameTimer() + durationFor(text)
    }
    return true
end

function AINPCHideSubtitle(npcId, utteranceId)
    local entry = activeSubtitles[npcId]
    if not entry or (utteranceId and entry.utteranceId and entry.utteranceId ~= utteranceId) then return end
    activeSubtitles[npcId] = nil
end

function AINPCShowPlayerSubtitle(text)
    if not AINPCShouldShowSubtitle(true, false) or not Config.Subtitles.showLocalPlayerTranscript or type(text) ~= 'string' or text == '' then return end
    playerSubtitle = {
        text = text,
        lines = wrappedLines(text),
        expiresAt = GetGameTimer() + durationFor(text)
    }
end

RegisterCommand('ainpc_subtitles', function()
    local current = storedBoolean(preferenceKey, Config.Subtitles.playerPreferenceDefault ~= false)
    setStoredBoolean(preferenceKey, not current)
    TriggerEvent('peak_ai_npc:client:notify', ('NPC subtitles %s.'):format(current and 'disabled' or 'enabled'))
end, false)

RegisterCommand('ainpc_accessibility', function()
    local current = storedBoolean(accessibilityKey, Config.Subtitles.accessibilityDefault == true)
    setStoredBoolean(accessibilityKey, not current)
    TriggerEvent('peak_ai_npc:client:notify', ('NPC accessibility subtitles %s.'):format(current and 'disabled' or 'enabled'))
end, false)

CreateThread(function()
    while true do
        local now = GetGameTimer()
        local hasActive = false
        for npcId, entry in pairs(activeSubtitles) do
            if entry.expiresAt <= now then
                activeSubtitles[npcId] = nil
            else
                hasActive = true
                drawSubtitle(AINPCClientEntities and AINPCClientEntities[npcId], entry)
            end
        end
        if playerSubtitle then
            if playerSubtitle.expiresAt <= now then
                playerSubtitle = nil
            else
                hasActive = true
                drawSubtitle(PlayerPedId(), playerSubtitle)
            end
        end
        Wait(hasActive and 0 or 250)
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    activeSubtitles = {}
    playerSubtitle = nil
end)
