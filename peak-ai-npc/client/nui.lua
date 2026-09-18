local function nui(action, data)
    SendNUIMessage({ action = action, data = data or {} })
end

local conversationActive = false
local cursorActive = false
local activeSessionId = nil
local activeSessionRevision = 0
local activeQuoteId = nil
local activeNpcId = nil
local shopOpen = false
local pendingShopNpc = nil
local shopRequestId = nil
local catalogRequestId = nil
local catalogSequence = 0
local activeCaptureGeneration = nil
local captureSubmitted = false
local pendingCapture = nil
local microphoneSetupOpen = false
local activeUtterances = {}
local gestureState = {}

local function recordCaptureDiagnostic(stage, bytes, durationMs)
    if AINPCDiagnostics then
        -- The shared recorder hashes correlation IDs and whitelists numbers.
        -- Never pass an entire NUI/state payload or error/transcript text here.
        AINPCDiagnostics.record(stage, {
            sessionId = activeSessionId, generation = activeCaptureGeneration,
            revision = activeSessionRevision, bytes = bytes, durationMs = durationMs
        })
    end
end

local allowedLifecycle = { started = true, ended = true, error = true, interrupted = true }
local gestureAnimations = {
    greet = { dict = 'gestures@m@standing@casual', name = 'gesture_hello' },
    explain = { dict = 'gestures@m@standing@casual', name = 'gesture_hand_down' },
    warn = { dict = 'gestures@m@standing@casual', name = 'gesture_damn' },
    dismiss = { dict = 'gestures@m@standing@casual', name = 'gesture_bring_it_on' }
}

local function setCursorActive(active)
    cursorActive = (conversationActive or microphoneSetupOpen) and active == true
    SetNuiFocus(cursorActive, cursorActive)
    SetNuiFocusKeepInput(false)
    nui('cursor', { active = cursorActive })
end

local function notifyError(message)
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(message)
    EndTextCommandThefeedPostTicker(false, false)
end

function AINPCNotify(message)
    if type(message) ~= 'string' or message == '' then return end
    notifyError(message)
    nui('notice', { message = message })
end

local function speakerPed(entry)
    -- 65528+ is an unresolved OneSync sentinel on some FXServer builds. Calling
    -- NetToPed with it produces a client warning and can leave the audio/gesture
    -- lifecycle attached to a non-existent entity.
    if type(entry.sourceNetworkId) == 'number' and entry.sourceNetworkId > 0 and entry.sourceNetworkId < 65528 then
        local ped = NetToPed(entry.sourceNetworkId)
        if ped ~= 0 and DoesEntityExist(ped) then return ped end
    end
    local ped = AINPCClientEntities and AINPCClientEntities[entry.npcId]
    return ped and DoesEntityExist(ped) and ped or nil
end

local function stopGesture(entry)
    local state = gestureState[entry.utteranceId]
    if not state then return end
    gestureState[entry.utteranceId] = nil
    if DoesEntityExist(state.ped) and GetEntityModel(state.ped) == state.model
        and Entity(state.ped).state['ainpc:id'] == state.npcId
        and Entity(state.ped).state['ainpc:residentId'] == state.residentId
        and Entity(state.ped).state['ainpc:localBindingKey'] == state.bindingKey then
        StopAnimTask(state.ped, state.dict, state.name, 0.25)
    end
end

local function pickSpeechGesture(performance)
    return performance and performance.gesture and gestureAnimations[performance.gesture] or nil
end

local function canGesture(ped, entry)
    -- Authored server-owned NPCs alone opt into speech gestures. Existing world
    -- peds retain their scenario/tasks, including while dictionaries load.
    local state = Entity(ped).state
    return state['ainpc:id'] == entry.npcId and not state['ainpc:residentId']
        and not state['ainpc:localBindingKey'] and not IsPedUsingAnyScenario(ped)
end

local function startGesture(entry)
    local performance = entry.performance
    local animation = pickSpeechGesture(performance)
    local ped = animation and speakerPed(entry)
    if not ped or entry.stopping or IsEntityDead(ped) or IsPedInAnyVehicle(ped, false) or not canGesture(ped, entry) then return end
    local model = GetEntityModel(ped)
    local state = Entity(ped).state
    local residentId, bindingKey = state['ainpc:residentId'], state['ainpc:localBindingKey']
    CreateThread(function()
        RequestAnimDict(animation.dict)
        local deadline = GetGameTimer() + 1000
        while not HasAnimDictLoaded(animation.dict) and GetGameTimer() < deadline do Wait(0) end
        if not HasAnimDictLoaded(animation.dict) then
            RemoveAnimDict(animation.dict)
            return
        end
        -- Loading yields: the speaker can disappear, be replaced, die or enter
        -- a vehicle meanwhile. Never animate a cached handle without rechecking.
        if activeUtterances[entry.utteranceId] ~= entry or entry.stopping or speakerPed(entry) ~= ped
            or not DoesEntityExist(ped) or GetEntityModel(ped) ~= model
            or IsEntityDead(ped) or IsPedInAnyVehicle(ped, false) or not canGesture(ped, entry)
            or Entity(ped).state['ainpc:residentId'] ~= residentId
            or Entity(ped).state['ainpc:localBindingKey'] ~= bindingKey then
            RemoveAnimDict(animation.dict)
            return
        end
        -- Secondary/upper-body flags preserve authoritative locomotion tasks.
        TaskPlayAnim(ped, animation.dict, animation.name, 2.0, -2.0, -1, 48, 0.0, false, false, false)
        gestureState[entry.utteranceId] = { ped = ped, model = model, npcId = entry.npcId, residentId = residentId,
            bindingKey = bindingKey, dict = animation.dict, name = animation.name }
        RemoveAnimDict(animation.dict)
    end)
end

local function endPresentation(entry)
    if not entry then return end
    stopGesture(entry)
    if entry.speakingToken and AINPCStopSpeaking then AINPCStopSpeaking(entry.npcId, entry.speakingToken) end
    if AINPCHideSubtitle then AINPCHideSubtitle(entry.npcId, entry.utteranceId) end
    entry.speakingToken = nil
end

local function stopUtterance(utteranceId, reason, fadeMs)
    local entry = activeUtterances[utteranceId]
    if not entry then return end
    entry.stopping = true
    nui('stopUtterance', { utteranceId = utteranceId, reason = reason or 'interrupted', fadeMs = fadeMs or 100 })
end

local function commitCaptureBinding()
    local pending = pendingCapture
    if not pending or pending.bound or not pending.sessionId or GetGameTimer() >= pending.deadline then return false end
    if not conversationActive or activeSessionId ~= pending.sessionId or activeSessionRevision ~= pending.sessionRevision then return false end
    pending.bound = true
    activeCaptureGeneration = pending.generation
    captureSubmitted = false
    nui('bindRecording', { generation = pending.generation, sessionId = activeSessionId, sessionRevision = activeSessionRevision,
        bargeCaptureGeneration = pending.originRevision and pending.generation or nil,
        interruptedRevision = pending.originRevision, interruptedUtteranceId = pending.utteranceId })
    return true
end

function AINPCBeginPendingVoiceCapture(generation)
    if not Config.VoiceInput.enabled or conversationActive or type(generation) ~= 'number'
        or generation < 1 or generation % 1 ~= 0 then return false end
    if type(activeCaptureGeneration) == 'number' and generation <= activeCaptureGeneration then return false end
    local pending = { generation = generation, deadline = GetGameTimer() + 15000, bound = false }
    pendingCapture = pending
    activeCaptureGeneration = generation
    captureSubmitted = false
    recordCaptureDiagnostic('capture_start')
    nui('beginPendingRecording', { generation = generation })
    CreateThread(function()
        Wait(15000)
        if pendingCapture == pending and not pending.bound then AINPCCancelVoiceCapture('binding_timeout', generation) end
    end)
    return true
end

function AINPCBindVoiceCapture(generation, sessionId, sessionRevision)
    local pending = pendingCapture
    if not pending or pending.originRevision or pending.bound or pending.generation ~= generation or GetGameTimer() >= pending.deadline
        or type(sessionId) ~= 'string' or sessionId == '' or type(sessionRevision) ~= 'number'
        or sessionRevision < 0 or sessionRevision % 1 ~= 0 then return false end
    if pending.sessionId and (pending.sessionId ~= sessionId or pending.sessionRevision ~= sessionRevision) then return false end
    pending.sessionId, pending.sessionRevision = sessionId, sessionRevision
    -- main.lua may receive ClientState before this listener. Queue the exact
    -- binding and commit only after this bridge forwards matching state to NUI.
    commitCaptureBinding()
    return true
end

function AINPCBeginVoiceCapture(generation)
    if not conversationActive or type(activeSessionId) ~= 'string' then return false end
    if type(generation) ~= 'number' or generation < 1 or generation % 1 ~= 0 or generation > 2147483647 then return false end
    if type(generation) == 'number' and type(activeCaptureGeneration) == 'number'
        and generation <= activeCaptureGeneration then return false end
    local bargeUtterance
    for utteranceId, entry in pairs(activeUtterances) do
        if entry.interacting and entry.sessionRevision == activeSessionRevision then
            bargeUtterance = utteranceId
            stopUtterance(utteranceId, 'barge_in', 100)
        end
    end
    activeCaptureGeneration = generation
    pendingCapture = nil
    captureSubmitted = false
    recordCaptureDiagnostic('capture_start')
    if bargeUtterance then
        local pending = { generation = generation, deadline = GetGameTimer() + 15000, bound = false,
            originSessionId = activeSessionId, originRevision = activeSessionRevision, utteranceId = bargeUtterance }
        pendingCapture = pending
        nui('beginBargeRecording', { generation = generation, sessionId = activeSessionId,
            sessionRevision = activeSessionRevision, utteranceId = bargeUtterance })
        TriggerServerEvent('peak_ai_npc:server:bargeIn', activeSessionId, activeSessionRevision, bargeUtterance, generation)
        CreateThread(function()
            Wait(15000)
            if pendingCapture == pending and not pending.bound then AINPCCancelVoiceCapture('barge_timeout', generation) end
        end)
    else
        nui('startRecording', { generation = generation })
    end
    return true
end

function AINPCPrepareMicrophone()
    nui('prepareMicrophone')
end

function AINPCPromptMicrophoneSetup()
    if conversationActive or pendingCapture then return false end
    microphoneSetupOpen = true
    setCursorActive(true)
    nui('microphoneSetup')
    return true
end

RegisterNUICallback('microphoneSetupDone', function(_, cb)
    microphoneSetupOpen = false
    setCursorActive(false)
    cb({ ok = true })
end)

RegisterNUICallback('cancelPendingCapture', function(data, cb)
    data = type(data) == 'table' and data or {}
    if not pendingCapture or pendingCapture.generation ~= data.generation then
        cb({ ok = false, error = 'stale_capture' }); return
    end
    AINPCCancelVoiceCapture('user_cancelled', data.generation)
    cb({ ok = true })
end)

function AINPCCancelVoiceCapture(reason, generation)
    if generation ~= nil and generation ~= activeCaptureGeneration then return false end
    pendingCapture = nil
    captureSubmitted = true
    nui('cancelRecording', { reason = reason or 'cancelled', generation = generation })
    return true
end

function AINPCEndVoiceCapture(generation)
    if generation == activeCaptureGeneration then recordCaptureDiagnostic('capture_end') end
    -- Always send stop: it invalidates a getUserMedia request even when browser
    -- permission has not resolved and no MediaRecorder exists yet.
    nui('stopRecording', { generation = generation })
end

function AINPCResetConversationUI(reason)
    shopOpen, pendingShopNpc, activeQuoteId, activeNpcId = false, nil, nil, nil
    shopRequestId, catalogRequestId = nil, nil
    nui('closeShop')
    nui('cancelRecording', { reason = reason or 'reset' })
    for utteranceId, entry in pairs(activeUtterances) do
        endPresentation(entry)
        TriggerServerEvent('peak_ai_npc:server:audioLifecycle', entry.sessionRevision, utteranceId, 'interrupted', reason or 'reset')
        nui('stopUtterance', { utteranceId = utteranceId, reason = reason or 'reset', fadeMs = 60 })
    end
    activeUtterances = {}
    conversationActive = false
    activeSessionId = nil
    activeCaptureGeneration = nil
    captureSubmitted = false
    pendingCapture = nil
    microphoneSetupOpen = false
    activeSessionRevision = activeSessionRevision + 1
    setCursorActive(false)
    nui('close')
end

RegisterNUICallback('sendMessage', function(data, cb)
    data = type(data) == 'table' and data or {}
    if type(data.sessionId) ~= 'string' or type(data.text) ~= 'string' or type(data.requestId) ~= 'string' then
        cb({ ok = false, error = 'invalid_message' })
        return
    end
    if not conversationActive or data.sessionId ~= activeSessionId then
        cb({ ok = false, error = 'stale_session' })
        return
    end
    captureSubmitted = true
    nui('cancelRecording', { reason = 'text_turn' })
    if AINPCRefreshSceneObservation then AINPCRefreshSceneObservation(data.sessionId, true) end
    TriggerServerEvent(AINPC.Event.Message, data.sessionId, data.text, data.requestId)
    cb({ ok = true })
end)

RegisterNUICallback('transcribe', function(data, cb)
    data = type(data) == 'table' and data or {}
    local audio = data.audioDataUrl
    if not conversationActive or data.sessionId ~= activeSessionId
        or tonumber(data.sessionRevision) ~= activeSessionRevision
        or data.generation ~= activeCaptureGeneration or captureSubmitted or (pendingCapture and not pendingCapture.bound) then
        cb({ ok = false, error = 'stale_capture' })
        return
    end
    if not Config.VoiceInput.enabled or type(data.sessionId) ~= 'string' or type(audio) ~= 'string'
        or type(data.durationMs) ~= 'number' or data.durationMs < 0 or data.durationMs > 15000
        or data.durationMs ~= data.durationMs
        or #audio > Config.VoiceInput.maximumDataUrlBytes
        or not (audio:match('^data:audio/webm;base64,[A-Za-z0-9+/]+=*$') or audio:match('^data:audio/ogg;base64,[A-Za-z0-9+/]+=*$')) then
        cb({ ok = false, error = 'invalid_audio' })
        return
    end
    local encoded = audio:match(';base64,(.+)$')
    if not encoded or #encoded % 4 ~= 0 or not encoded:match('^[A-Za-z0-9+/]+=?=?$') then
        cb({ ok = false, error = 'invalid_audio' })
        return
    end
    captureSubmitted = true
    if AINPCRefreshSceneObservation then AINPCRefreshSceneObservation(data.sessionId, true) end
    recordCaptureDiagnostic('upload', #audio, data.durationMs)
    TriggerLatentServerEvent(AINPC.Event.Transcribe, Config.VoiceInput.latentBytesPerSecond, data.sessionId, audio, Config.VoiceInput.language, activeSessionRevision, data.generation)
    cb({ ok = true })
end)

RegisterNUICallback('confirmPurchase', function(data, cb)
    data = type(data) == 'table' and data or {}
    if type(data.sessionId) ~= 'string' then cb({ ok = false, error = 'invalid_session' }); return end
    if data.sessionId ~= activeSessionId or type(activeQuoteId) ~= 'string' then cb({ ok = false, error = 'stale_quote' }); return end
    TriggerServerEvent(AINPC.Event.Confirm, data.sessionId, activeQuoteId)
    cb({ ok = true })
end)

RegisterNUICallback('endConversation', function(data, cb)
    data = type(data) == 'table' and data or {}
    if type(data.sessionId) == 'string' then TriggerServerEvent(AINPC.Event.End, data.sessionId) end
    if AINPCClearConversation then AINPCClearConversation() else AINPCResetConversationUI('ended') end
    cb({ ok = true })
end)

RegisterNUICallback('toggleCursor', function(_, cb)
    setCursorActive(not cursorActive)
    cb({ ok = true, active = cursorActive })
end)

local function requestShopCatalog()
    catalogSequence = catalogSequence + 1
    catalogRequestId = 'catalog:' .. catalogSequence
    TriggerServerEvent('peak_ai_npc:server:requestShopCatalog', {
        sessionId = activeSessionId, sessionRevision = activeSessionRevision, requestId = catalogRequestId
    })
end

RegisterNetEvent('peak_ai_npc:client:openShopCatalog', function(npcId)
    if not conversationActive or npcId ~= activeNpcId then
        if AINPCStartConversation then AINPCStartConversation(npcId) end
        pendingShopNpc = npcId
        return
    end
    requestShopCatalog()
end)

RegisterNetEvent('peak_ai_npc:client:showShopCatalog', function(payload)
    if type(payload) ~= 'table' or not conversationActive or payload.sessionId ~= activeSessionId
        or payload.sessionRevision ~= activeSessionRevision or not catalogRequestId or payload.requestId ~= catalogRequestId then return end
    catalogRequestId = nil
    shopOpen = true
    setCursorActive(true)
    nui('shopCatalog', payload)
end)

RegisterNetEvent('peak_ai_npc:client:shopResult', function(payload)
    if type(payload) ~= 'table' or not conversationActive then return end
    if payload.sessionId and (payload.sessionId ~= activeSessionId or payload.sessionRevision ~= activeSessionRevision) then return end
    if not shopOpen or not shopRequestId or payload.requestId ~= shopRequestId then return end
    shopRequestId = nil
    activeQuoteId = payload.ok and type(payload.result) == 'table' and payload.result.requiresConfirmation and payload.result.id or nil
    nui('shopResult', payload)
end)

RegisterNetEvent('peak_ai_npc:client:medicalHandoff', function(payload)
    if type(payload) ~= 'table' or not conversationActive or payload.sessionId ~= activeSessionId
        or payload.sessionRevision ~= activeSessionRevision or type(payload.location) ~= 'table' then return end
    local x, y = payload.location.x, payload.location.y
    if type(x) ~= 'number' or type(y) ~= 'number' or x ~= x or y ~= y or math.abs(x) > 100000 or math.abs(y) > 100000 then return end
    SetNewWaypoint(x, y)
    AINPCNotify((type(payload.label) == 'string' and payload.label or 'Hospital reception') .. ': check in for assessment and treatment.')
end)

RegisterNUICallback('closeShop', function(data, cb)
    shopOpen = false
    pendingShopNpc = nil
    shopRequestId, catalogRequestId = nil, nil
    setCursorActive(type(data) == 'table' and data.keepCursor == true)
    nui('closeShop', {})
    cb({ ok = true })
end)

local function shopRequest(event, data, cb)
    data = type(data) == 'table' and data or {}
    if not conversationActive or not activeSessionId then cb({ ok = false, error = 'invalid_session' }); return end
    data.sessionId, data.sessionRevision = activeSessionId, activeSessionRevision
    shopRequestId = data.requestId
    TriggerServerEvent(event, data)
    cb({ ok = true })
end

RegisterNUICallback('openShop', function(data, cb)
    if not conversationActive or not activeSessionId then cb({ ok = false, error = 'invalid_session' }); return end
    requestShopCatalog()
    cb({ ok = true })
end)

RegisterNUICallback('quoteShopItem', function(data, cb)
    if not shopOpen then cb({ ok = false, error = 'shop_closed' }); return end
    shopRequest('peak_ai_npc:server:quoteShopItem', data, cb)
end)

RegisterNUICallback('buyShopItem', function(data, cb)
    if not shopOpen then cb({ ok = false, error = 'shop_closed' }); return end
    shopRequest('peak_ai_npc:server:buyShopItem', data, cb)
end)

RegisterNUICallback('audioLifecycle', function(data, cb)
    data = type(data) == 'table' and data or {}
    local utteranceId = data.utteranceId
    local phase = data.phase
    local entry = type(utteranceId) == 'string' and activeUtterances[utteranceId] or nil
    if not entry or not allowedLifecycle[phase] then
        cb({ ok = false, error = 'stale_audio_lifecycle' })
        return
    end
    if tonumber(data.sessionRevision) ~= entry.sessionRevision then
        cb({ ok = false, error = 'stale_session_revision' })
        return
    end
    if phase == 'started' and not entry.started then
        entry.started = true
        entry.speakingToken = AINPCSetSpeaking and AINPCSetSpeaking(entry.npcId, true, entry.targetServerId) or nil
        startGesture(entry)
        if entry.text and AINPCShouldShowSubtitle and AINPCShouldShowSubtitle(entry.interacting, true) then
            local shown = AINPCShowSubtitle and AINPCShowSubtitle(entry.npcId, entry.text, entry.name, entry.utteranceId)
            if not shown then nui('subtitleFallback', { text = entry.text }) end
        end
    elseif phase ~= 'started' then
        endPresentation(entry)
        activeUtterances[utteranceId] = nil
    end
    TriggerServerEvent('peak_ai_npc:server:audioLifecycle', entry.sessionRevision, utteranceId, phase, data.code)
    cb({ ok = true })
end)

RegisterCommand('+ainpccursor', function()
    if conversationActive then setCursorActive(not cursorActive) end
end, false)
RegisterCommand('-ainpccursor', function() end, false)
RegisterKeyMapping('+ainpccursor', 'Toggle AI conversation text input', 'keyboard', 'LSHIFT')

local function audioPayload(message)
    local payload = type(message.payload) == 'table' and message.payload or {}
    local audio = type(payload.audio) == 'table' and payload.audio or {}
    local url = audio.url or payload.audioUrl
    if type(url) ~= 'string' or url == '' then return nil end
    local utteranceId = audio.utteranceId or payload.utteranceId
    if type(utteranceId) ~= 'string' or utteranceId == '' then
        utteranceId = ('legacy:%s:%s'):format(tostring(payload.sessionId or 'nearby'), tostring(GetGameTimer()))
    end
    return {
        utteranceId = utteranceId,
        url = url,
        contentType = audio.contentType or payload.audioContentType or 'audio/mpeg',
        sourceNetworkId = tonumber(audio.sourceNetworkId or payload.sourceNetworkId or payload.entityNetId),
        maximumDistance = math.max(1.0, math.min(60.0, tonumber(audio.maximumDistance or payload.maximumAudibleDistance or payload.audioMaxDistance) or 18.0)),
        measuredDurationMs = tonumber(audio.measuredDurationMs or payload.audioDurationMs),
        volume = math.max(0.0, math.min(1.0, tonumber(payload.audioVolume) or 1.0))
    }
end

local function spatialForEntry(entry)
    local player = PlayerPedId()
    if player == 0 or not DoesEntityExist(player) then return 0.0, 0.0 end
    local ped = speakerPed(entry)
    if not ped or IsEntityDead(ped) then return 0.0, 0.0 end
    local playerCoords, source = GetEntityCoords(player), GetEntityCoords(ped)
    local dx, dy = source.x - playerCoords.x, source.y - playerCoords.y
    local distance = #(source - playerCoords)
    if distance >= entry.maximumDistance then return 0.0, 0.0 end
    local normalized = math.max(0.0, 1.0 - distance / entry.maximumDistance)
    local gain = distance < 1.5 and 1.0 or normalized * normalized
    if not HasEntityClearLosToEntity(player, ped, 17) then gain = gain * 0.38 end
    local yaw = math.rad(GetGameplayCamRot(2).z)
    local pan = distance > 0.1 and math.max(-1.0, math.min(1.0, (dx * math.cos(yaw) + dy * math.sin(yaw)) / distance)) or 0.0
    return gain, pan
end

RegisterNetEvent(AINPC.Event.ClientState, function(message)
    message = type(message) == 'table' and message or {}
    if AINPCAcceptClientState and not AINPCAcceptClientState(message) then return end
    local payload = type(message.payload) == 'table' and message.payload or {}
    local incomingRevision = tonumber(payload.sessionRevision)
    if payload.nearby ~= true and payload.sessionId == activeSessionId and incomingRevision and incomingRevision < activeSessionRevision then return end
    local pending = pendingCapture
    if pending and pending.originRevision and not pending.bound and payload.nearby ~= true then
        local matches = message.state == 'capturing' and payload.sessionId == pending.originSessionId
            and payload.bargeCaptureGeneration == pending.generation
            and payload.interruptedRevision == pending.originRevision
            and payload.interruptedUtteranceId == pending.utteranceId
            and incomingRevision == pending.originRevision + 1 and GetGameTimer() < pending.deadline
        if matches then
            pending.sessionId, pending.sessionRevision = payload.sessionId, incomingRevision
        elseif (payload.sessionId and payload.sessionId ~= pending.originSessionId)
            or (incomingRevision and incomingRevision > pending.originRevision) then
            AINPCCancelVoiceCapture('stale_barge_ack', pending.generation)
        end
    end
    if payload.entityNetId and payload.npcId and type(payload.entityNetId) == 'number' and payload.entityNetId > 0 and payload.entityNetId < 65528 then
        local ped = NetToPed(payload.entityNetId)
        if ped ~= 0 and DoesEntityExist(ped) then
            AINPCClientEntities = AINPCClientEntities or {}
            AINPCClientEntities[payload.npcId] = ped
        end
    end

    nui('state', message)
    if payload.transcript and AINPCShowPlayerSubtitle then AINPCShowPlayerSubtitle(payload.transcript) end
    if (message.state == AINPC.State.Idle or message.state == 'ready') and not payload.sessionId and payload.nearby ~= true then
        AINPCResetConversationUI('server_terminal')
    elseif payload.sessionId and payload.nearby ~= true then
        conversationActive = true
        if activeSessionId ~= payload.sessionId then
            activeSessionRevision = 0
            activeCaptureGeneration = pendingCapture and pendingCapture.generation or nil
            captureSubmitted = false
        end
        activeSessionId = payload.sessionId
        activeNpcId = payload.npcId or activeNpcId
        if payload.quoteId ~= nil then activeQuoteId = type(payload.quoteId) == 'string' and payload.quoteId or nil end
        if shopOpen and tonumber(payload.sessionRevision) and tonumber(payload.sessionRevision) ~= activeSessionRevision then
            shopOpen = false
            shopRequestId, catalogRequestId = nil, nil
            setCursorActive(false)
            nui('closeShop')
        end
        activeSessionRevision = math.max(activeSessionRevision, tonumber(payload.sessionRevision) or activeSessionRevision)
        commitCaptureBinding()
        if pendingShopNpc and pendingShopNpc == activeNpcId then
            pendingShopNpc = nil
            requestShopCatalog()
        end
    end
    if payload.nearby ~= true and payload.sessionId and payload.sessionId == activeSessionId then
        if type(payload.transcript) == 'string' and payload.transcript ~= '' then
            recordCaptureDiagnostic('transcript_accepted')
        end
        if message.state == AINPC.State.Error then recordCaptureDiagnostic('provider_error') end
    end
    if message.state == AINPC.State.Error and payload.message then notifyError(payload.message) end

    if message.state == AINPC.State.Speaking then
        local audio = audioPayload(message)
        if audio then
            -- A local population ped is not a safe shared audio source. Nearby
            -- playback starts only after the server promotes it to a resident.
            if payload.nearby == true and (not audio.sourceNetworkId or audio.sourceNetworkId <= 0) then return end
            local revision = tonumber(payload.sessionRevision) or activeSessionRevision
            local entry = {
                utteranceId = audio.utteranceId,
                npcId = payload.npcId,
                name = payload.name,
                text = payload.text,
                performance = payload.performance,
                targetServerId = tonumber(payload.sourceServerId or payload.targetServerId),
                sourceNetworkId = audio.sourceNetworkId,
                maximumDistance = audio.maximumDistance,
                sessionId = payload.sessionId,
                sessionRevision = revision,
                interacting = payload.nearby ~= true,
                started = false
            }
            activeUtterances[audio.utteranceId] = entry
            local initialGain, initialPan = spatialForEntry(entry)
            nui('audio', {
                url = audio.url,
                utteranceId = audio.utteranceId,
                sessionId = entry.sessionId,
                sessionRevision = revision,
                speakerId = payload.npcId,
                npcId = payload.npcId,
                nearby = payload.nearby == true,
                volume = audio.volume,
                initialGain = initialGain,
                initialPan = initialPan
            })
            local watchdogMs = math.max(5000, math.min(90000, (audio.measuredDurationMs or 30000) + 2500))
            CreateThread(function()
                Wait(watchdogMs)
                local current = activeUtterances[audio.utteranceId]
                if current then
                    endPresentation(current)
                    activeUtterances[audio.utteranceId] = nil
                    TriggerServerEvent('peak_ai_npc:server:audioLifecycle', current.sessionRevision, current.utteranceId, 'error', 'lifecycle_timeout')
                    nui('stopUtterance', { utteranceId = current.utteranceId, reason = 'lifecycle_timeout', fadeMs = 60 })
                end
            end)
        elseif payload.text and payload.npcId and AINPCShouldShowSubtitle and AINPCShouldShowSubtitle(payload.nearby ~= true, false) then
            local shown = AINPCShowSubtitle and AINPCShowSubtitle(payload.npcId, payload.text, payload.name)
            if not shown then nui('subtitleFallback', { text = payload.text }) end
        end
    end
end)

RegisterNetEvent('peak_ai_npc:client:stopUtterance', function(payload)
    payload = type(payload) == 'table' and payload or {}
    if type(payload.utteranceId) ~= 'string' then return end
    local entry = activeUtterances[payload.utteranceId]
    if entry and (not payload.sessionRevision or tonumber(payload.sessionRevision) == entry.sessionRevision) then
        stopUtterance(payload.utteranceId, payload.reason or 'server_interrupted', payload.fadeMs or 100)
    end
end)

RegisterNetEvent('peak_ai_npc:client:notify', AINPCNotify)

CreateThread(function()
    while true do
        Wait(next(activeUtterances) and 100 or 500)
        local player = PlayerPedId()
        if player ~= 0 and DoesEntityExist(player) then
            local entries = {}
            for utteranceId, entry in pairs(activeUtterances) do
                local gain, pan = spatialForEntry(entry)
                entries[#entries + 1] = { utteranceId = utteranceId, gain = gain, pan = pan }
            end
            if #entries > 0 then nui('spatial', { entries = entries }) end
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    AINPCResetConversationUI('resource_stop')
end)
