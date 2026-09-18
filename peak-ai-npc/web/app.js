const ui = {
    app: document.getElementById('app'),
    dock: document.querySelector('.voice-dock'),
    npcName: document.getElementById('npcName'),
    occupation: document.getElementById('occupation'),
    stateLabel: document.getElementById('stateLabel'),
    status: document.getElementById('status'),
    transcript: document.getElementById('transcript'),
    micIndicator: document.getElementById('micIndicator'),
    purchase: document.getElementById('purchase'),
    fallbackSubtitle: document.getElementById('subtitleFallback'),
    form: document.getElementById('form'),
    input: document.getElementById('input'),
    textToggle: document.getElementById('textToggle'),
};

const resource = window.GetParentResourceName ? window.GetParentResourceName() : 'peak-ai-npc';
const previewState = new URLSearchParams(window.location.search).get('preview');
const previewMode = previewState !== null;
const stateCopy = {
    ready: ['Ready', 'Hold NPC Push-to-Talk and speak naturally'],
    idle: ['Ready', 'Hold NPC Push-to-Talk and speak naturally'],
    capturing: ['Recording…', 'Speak now — release NPC Push-to-Talk when done'],
    transcribing: ['Transcribing…', 'Converting your speech to text'],
    deliberating: ['Thinking…', 'Considering what you said'],
    thinking: ['Thinking…', 'Considering what you said'],
    action_pending: ['Acting…', 'Waiting for the NPC action to complete'],
    synthesizing: ['Preparing voice…', 'Generating the NPC response'],
    speaking: ['Speaking', 'Listen or follow the subtitle above the NPC'],
    error: ['Couldn’t continue', 'Try again or use the text fallback'],
};

const friendlyErrors = {
    resident_handoff_timeout: 'This resident could not join the conversation. Try again or choose another NPC.',
    resident_resolution_failed: 'This resident is not ready to talk. Try again in a moment.',
    unknown_npc: 'This NPC is no longer available.',
    npc_unavailable: 'This NPC is no longer available.',
    npc_busy: 'This NPC is already talking to someone else.',
    player_already_in_conversation: 'Finish your current conversation before starting another.',
    permission_denied: 'You do not have permission to talk to this NPC.',
    job_not_allowed: 'Your current job cannot use this conversation.',
    gang_not_allowed: 'Your current group cannot use this conversation.',
    session_expired: 'The conversation timed out. Start it again to continue.',
    turn_limit: 'This conversation has reached its turn limit. Start a new one to continue.',
    player_unavailable: 'Your character is not ready to talk right now.',
    player_dead: 'You cannot continue this conversation while incapacitated.',
    npc_not_in_bucket: 'This NPC is in another instance.',
    npc_dead: 'This NPC can no longer continue the conversation.',
    too_far: 'You moved too far away. Walk closer and start the conversation again.',
};

let sessionId = null;
let sessionRevision = 0;
let voiceEnabled = false;
let captureGeneration = 0;
let captureWanted = false;
let capture = null;
let captureUpload = null;
let pendingCaptureBinding = null;
let microphoneSetupOpen = false;
const CAPTURE_BIND_TIMEOUT_MS = 15000;
const MAX_CAPTURE_BYTES = 5999900;
let captureCommandGeneration = null;
let microphoneDeviceId = '';
let preparedMicrophone = null;
let microphoneSetupGeneration = 0;
let microphoneListGeneration = 0;
let microphoneIdleTimer = null;
let fallbackSubtitleTimer = null;
let stateTimer = null;
let animationFrame = null;
let playbackContext = null;
const speakers = new Map();
const MAX_SPEAKERS = 3;
const MAX_CAPTURE_DATA_URL_BYTES = 8000000;
const waveformBars = document.querySelectorAll('.waveform:not(.waveform-inline) i');

function post(name, data = {}, options = {}) {
    if (previewMode) return Promise.resolve({ ok: true, json: async () => ({ ok: true }) });
    return fetch(`https://${resource}/${name}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data),
        ...options,
    });
}

async function postResult(name, data = {}, options = {}) {
    const response = await post(name, data, options);
    const result = await response.json();
    if (response.ok === false || result?.ok !== true) throw new Error(result?.error || `${name}_rejected`);
    return result;
}

function requestId() {
    if (window.crypto?.randomUUID) return window.crypto.randomUUID();
    return `req-${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

function setState(name, message) {
    clearTimeout(stateTimer);
    stateTimer = null;
    const copy = stateCopy[name] || stateCopy.ready;
    ui.dock.dataset.state = name;
    ui.stateLabel.textContent = copy[0];
    const friendlyMessage = typeof message === 'string' && friendlyErrors[message] ? friendlyErrors[message] : message;
    ui.status.textContent = friendlyMessage || copy[1];
    ui.micIndicator?.setAttribute('aria-label', copy[0]);
    if (name === 'capturing' || name === 'speaking') startWaveformAnimation();
    else stopWaveformAnimation();
}

function showTranscript(text) {
    ui.transcript.textContent = text ? `“${text}”` : '';
    ui.transcript.hidden = !text;
}

function showFallbackSubtitle(text) {
    ui.fallbackSubtitle.textContent = text || '';
    ui.fallbackSubtitle.hidden = !text;
    clearTimeout(fallbackSubtitleTimer);
    if (text) {
        fallbackSubtitleTimer = setTimeout(() => {
            ui.fallbackSubtitle.hidden = true;
        }, Math.min(9000, Math.max(2800, text.length * 48)));
    }
}

function setTextFallback(open) {
    ui.form.hidden = !open;
    ui.textToggle.textContent = open ? 'Hide text' : 'Use text';
    ui.textToggle.setAttribute('aria-expanded', String(open));
    if (open) ui.input.focus();
    else if (document.activeElement === ui.input) ui.textToggle.focus();
}

function startWaveformAnimation() {
    if (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) return;
    if (animationFrame) return;
    let tick = 0;
    const frame = () => {
        tick += 0.08;
        let energyScale = 1;
        if (capture?.analyser) {
            const samples = capture.waveformSamples ||= new Uint8Array(capture.analyser.fftSize);
            capture.analyser.getByteTimeDomainData(samples);
            let energy = 0;
            for (const sample of samples) {
                const normalized = (sample - 128) / 128;
                energy += normalized * normalized;
            }
            energyScale = Math.min(3.5, Math.sqrt(energy / samples.length) * 18);
        }
        waveformBars.forEach((bar, index) => {
            const height = (0.3 + 0.7 * Math.abs(Math.sin(tick + index * 0.55))) * energyScale;
            bar.style.height = `${Math.min(100, Math.round(height * 22))}%`;
        });
        animationFrame = requestAnimationFrame(frame);
    };
    animationFrame = requestAnimationFrame(frame);
}

function stopWaveformAnimation() {
    if (animationFrame) cancelAnimationFrame(animationFrame);
    animationFrame = null;
    waveformBars.forEach(bar => { bar.style.height = ''; });
}

function stopTracks(mediaStream) {
    if (!mediaStream) return;
    for (const track of mediaStream.getTracks()) track.stop();
}

function releasePreparedMicrophone() {
    microphoneSetupGeneration += 1;
    microphoneListGeneration += 1;
    clearTimeout(microphoneIdleTimer);
    stopTracks(preparedMicrophone);
    preparedMicrophone = null;
}

function microphoneConstraints() {
    return { audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true,
        ...(microphoneDeviceId ? { deviceId: { exact: microphoneDeviceId } } : {}) }, video: false };
}

async function refreshMicrophones() {
    const select = document.getElementById('microphoneDevice');
    if (!select || !navigator.mediaDevices?.enumerateDevices) return;
    const generation = ++microphoneListGeneration;
    const expectedDevice = microphoneDeviceId;
    const devices = await navigator.mediaDevices.enumerateDevices();
    if (generation !== microphoneListGeneration || expectedDevice !== microphoneDeviceId) return;
    const inputs = devices.filter(device => device.kind === 'audioinput');
    select.replaceChildren();
    for (const device of [{ deviceId: '', label: 'System default microphone' }, ...inputs]) {
        const option = document.createElement('option');
        option.value = device.deviceId;
        option.textContent = device.label || `Microphone ${select.options.length}`;
        select.appendChild(option);
    }
    if (microphoneDeviceId && !inputs.some(device => device.deviceId === microphoneDeviceId)) {
        microphoneDeviceId = '';
        cancelCapture();
        releasePreparedMicrophone();
        setState('error', 'Selected microphone disconnected. Choose a microphone and prepare it again, or use text.');
        setTextFallback(true);
    }
    select.value = microphoneDeviceId;
}

async function prepareMicrophone() {
    cancelCapture();
    releasePreparedMicrophone();
    const setup = microphoneSetupGeneration;
    setState('ready', 'Allow microphone access, then hold NPC Push-to-Talk.');
    try {
        const stream = await navigator.mediaDevices.getUserMedia(microphoneConstraints());
        if (setup !== microphoneSetupGeneration) { stopTracks(stream); return; }
        preparedMicrophone = stream;
        // Bound the idle device lease; never leave the microphone open indefinitely.
        microphoneIdleTimer = setTimeout(releasePreparedMicrophone, 30000);
        setState('ready', 'Microphone ready. Hold NPC Push-to-Talk and speak.');
        refreshMicrophones().catch(() => {});
    } catch {
        if (setup !== microphoneSetupGeneration) return;
        setState('error', 'Microphone unavailable. Check permission and device, then select Prepare microphone to retry.');
        setTextFallback(true);
    }
}

async function warmMicrophone() {
    if (!sessionId || !voiceEnabled || preparedMicrophone || capture || captureUpload) return;
    const setup = microphoneSetupGeneration;
    try {
        const stream = await navigator.mediaDevices.getUserMedia(microphoneConstraints());
        if (setup !== microphoneSetupGeneration || !sessionId || !voiceEnabled || preparedMicrophone || capture) {
            stopTracks(stream);
            return;
        }
        preparedMicrophone = stream;
        clearTimeout(microphoneIdleTimer);
        microphoneIdleTimer = setTimeout(releasePreparedMicrophone, 30000);
    } catch {}
}

function cleanupCaptureState(item) {
    if (!item) return;
    clearTimeout(item.maximumTimer);
    stopTracks(item.stream);
    item.context?.close().catch(() => {});
    if (capture === item) capture = null;
}

function cancelCapture({ discard = true, invalidate = true } = {}) {
    captureWanted = false;
    if (invalidate) captureGeneration += 1;
    if (pendingCaptureBinding) {
        clearTimeout(pendingCaptureBinding.timer);
        if (pendingCaptureBinding.finished) pendingCaptureBinding.finished.discard = true;
        pendingCaptureBinding = null;
    }
    if (captureUpload) {
        captureUpload.discard = true;
        captureUpload.reader?.abort?.();
        captureUpload.controller?.abort();
        captureUpload = null;
    }
    const item = capture;
    if (!item) return;
    item.discard = discard;
    if (item.recorder?.state === 'recording') item.recorder.stop();
    cleanupCaptureState(item);
}

function chooseRecorderType() {
    if (typeof MediaRecorder === 'undefined') return null;
    const candidates = ['audio/webm;codecs=opus', 'audio/ogg;codecs=opus', 'audio/webm'];
    if (typeof MediaRecorder.isTypeSupported !== 'function') return 'audio/webm';
    return candidates.find(type => MediaRecorder.isTypeSupported(type)) || null;
}

async function beginRecording(commandGeneration, pending = false, barge = null) {
    if (barge && (!sessionId || !voiceEnabled || barge.sessionId !== sessionId || barge.sessionRevision !== sessionRevision
        || typeof barge.utteranceId !== 'string' || !barge.utteranceId)) return;
    if (pending ? ((!barge && sessionId) || !Number.isSafeInteger(commandGeneration) || commandGeneration < 1) : (!sessionId || !voiceEnabled)) return;
    if (Number.isFinite(commandGeneration) && Number.isFinite(captureCommandGeneration)
        && commandGeneration <= captureCommandGeneration) return;
    cancelCapture({ discard: true, invalidate: false });
    captureCommandGeneration = commandGeneration;
    const generation = ++captureGeneration;
    captureWanted = true;
    const expectedSession = sessionId;
    const expectedRevision = sessionRevision;
    const binding = pending ? { commandGeneration, generation, bound: false, sessionId: null,
        sessionRevision: 0, barge, deadline: Date.now() + CAPTURE_BIND_TIMEOUT_MS, finished: null, item: null } : null;
    if (binding) {
        pendingCaptureBinding = binding;
        binding.timer = setTimeout(() => {
            if (pendingCaptureBinding !== binding || binding.bound) return;
            cancelCapture();
            setState('error', 'The NPC did not connect in time. Your recording was discarded. Hold NPC Push-to-Talk to retry.');
        }, CAPTURE_BIND_TIMEOUT_MS);
        ui.app.hidden = false;
        setState('ready', 'Preparing microphone. Speak when Recording appears.');
    }
    const recorderType = chooseRecorderType();
    if (!navigator.mediaDevices?.getUserMedia || !recorderType) {
        captureWanted = false;
        setState('error', 'This FiveM browser cannot record a supported Opus audio format. Use text.');
        setTextFallback(true);
        return;
    }

    let mediaStream;
    try {
        mediaStream = preparedMicrophone;
        preparedMicrophone = null;
        clearTimeout(microphoneIdleTimer);
        microphoneSetupGeneration += 1;
        if (mediaStream?.getTracks().some(track => track.readyState === 'ended')) {
            stopTracks(mediaStream);
            mediaStream = null;
        }
        mediaStream ||= await navigator.mediaDevices.getUserMedia(microphoneConstraints());
    } catch {
        if (generation !== captureGeneration) return;
        captureWanted = false;
        setState('error', 'Microphone unavailable. Check microphone permission and device, then hold NPC Push-to-Talk to retry, or use text.');
        setTextFallback(true);
        return;
    }

    // PTT may have been released, the session may have ended, or a newer press
    // may have started while the browser permission prompt was still visible.
    const targetCurrent = binding
        ? pendingCaptureBinding === binding && (!binding.bound || (binding.sessionId === sessionId && binding.sessionRevision === sessionRevision))
        : sessionId === expectedSession && sessionRevision === expectedRevision;
    if (!captureWanted || generation !== captureGeneration || !targetCurrent) {
        stopTracks(mediaStream);
        return;
    }

    const item = {
        generation,
        commandGeneration,
        sessionId: binding?.sessionId ?? expectedSession,
        sessionRevision: binding?.sessionRevision ?? expectedRevision,
        binding,
        stream: mediaStream,
        recorder: null,
        context: null,
        analyser: null,
        maximumTimer: null,
        discard: false,
        startedAt: Date.now(),
        chunks: [],
        bytes: 0,
    };
    if (binding) binding.item = item;
    capture = item;
    for (const track of mediaStream.getTracks()) track.onended = () => {
        if (!isCurrentCapture(item)) return;
        cancelCapture();
        setState('error', 'Microphone disconnected. Reconnect it and hold NPC Push-to-Talk to retry, or use text.');
        setTextFallback(true);
    };

    try {
        const AudioContextClass = window.AudioContext || window.webkitAudioContext;
        try {
          if (AudioContextClass) {
            item.context = new AudioContextClass();
            item.analyser = item.context.createAnalyser();
            item.analyser.fftSize = 512;
            item.analyser.smoothingTimeConstant = 0.5;
            item.context.createMediaStreamSource(mediaStream).connect(item.analyser);
            // FiveM's Chromium runtime can create capture AudioContexts in a
            // suspended state after the async getUserMedia permission step.
            // Resume it when possible, but never make recording depend on the
            // analyser: MediaRecorder remains the authoritative capture path.
            try {
                const resumeResult = item.context.resume?.();
                resumeResult?.catch?.(() => {});
            } catch {
                // Some embedded runtimes expose resume but reject it outside a
                // user activation. The recorder can still produce valid audio.
            }
          }
        } catch {
            // Meter failure must not prevent the independent MediaRecorder path.
            item.analyser = null;
        }

        item.recorder = new MediaRecorder(mediaStream, { mimeType: recorderType });
        item.recorder.ondataavailable = event => {
            if (item.discard || !event.data?.size) return;
            item.bytes += event.data.size;
            if (item.bytes > MAX_CAPTURE_BYTES) {
                if (!isCurrentCapture(item)) return;
                cancelCapture();
                setState('error', 'The voice message was too large. Hold NPC Push-to-Talk to retry with a shorter message.');
                return;
            }
            item.chunks.push(event.data);
        };
        item.recorder.onerror = () => {
            const wasCurrent = isCurrentCapture(item);
            item.discard = true;
            cleanupCaptureState(item);
            if (!wasCurrent) return;
            setState('error', 'Recording failed. Use the text fallback.');
            setTextFallback(true);
        };
        item.recorder.onstop = () => finishRecording(item);
        item.recorder.start(250);
        item.startedAt = Date.now();
        setState('capturing');
        item.maximumTimer = setTimeout(() => {
            captureWanted = false;
            item.stoppedAt = Date.now();
            if (item.recorder?.state === 'recording') item.recorder.stop();
        }, 12000);
    } catch {
        item.discard = true;
        cleanupCaptureState(item);
        setState('error', 'The microphone codec could not start. Use the text fallback.');
        setTextFallback(true);
    }
}

function stopRecording(commandGeneration) {
    if (Number.isFinite(commandGeneration) && commandGeneration !== captureCommandGeneration) return;
    captureWanted = false;
    // This invalidates a pending getUserMedia call before it can create a late recorder.
    if (!capture) {
        if (pendingCaptureBinding?.finished) return;
        // A maximum-duration stop or duplicate release may already be encoding
        // this recording. Do not invalidate that legitimate pending upload.
        if (captureUpload && isCurrentCapture(captureUpload)) return;
        captureGeneration += 1;
        if (pendingCaptureBinding) {
            cancelCapture();
            setState('error', 'Microphone was not ready before release. Prepare the microphone, then hold NPC Push-to-Talk again.');
        }
        return;
    }
    capture.discard = false;
    capture.stoppedAt ??= Date.now();
    if (capture.recorder?.state === 'recording') capture.recorder.stop();
}

function isCurrentCapture(item) {
    return !item.discard && item.generation === captureGeneration
        && (item.binding && !item.binding.bound
            ? pendingCaptureBinding === item.binding && Date.now() < item.binding.deadline
            : item.sessionId === sessionId && item.sessionRevision === sessionRevision);
}

function bindRecording(data) {
    const binding = pendingCaptureBinding;
    if (!binding || binding.bound || data?.generation !== binding.commandGeneration
        || binding.generation !== captureGeneration) return;
    if (Date.now() >= binding.deadline) { cancelCapture(); return; }
    // Authoritative state must arrive before the explicit bind message. A state
    // update alone never grants an unbound recording to a new conversation.
    if (!data.sessionId || data.sessionId !== sessionId || data.sessionRevision !== sessionRevision || !voiceEnabled) return;
    if (binding.barge && (data.bargeCaptureGeneration !== binding.commandGeneration
        || data.sessionId !== binding.barge.sessionId
        || data.sessionRevision !== binding.barge.sessionRevision + 1
        || data.interruptedRevision !== binding.barge.sessionRevision
        || data.interruptedUtteranceId !== binding.barge.utteranceId)) return;
    binding.bound = true;
    binding.sessionId = data.sessionId;
    binding.sessionRevision = data.sessionRevision;
    clearTimeout(binding.timer);
    if (binding.item) {
        binding.item.sessionId = data.sessionId;
        binding.item.sessionRevision = data.sessionRevision;
        if (binding.item.recorder?.state === 'recording') setState('capturing');
    }
    if (binding.finished) {
        const item = binding.finished;
        binding.finished = null;
        finishRecording(item);
    }
}

function finishRecording(item) {
    if (item.binding && !item.binding.bound && isCurrentCapture(item)) {
        item.stoppedAt ??= Date.now();
        cleanupCaptureState(item);
        item.binding.finished = item;
        setState('ready', 'Recording saved. Waiting for the NPC to connect…');
        return;
    }
    const mime = (item.recorder?.mimeType || item.chunks[0]?.type || 'audio/webm').split(';')[0];
    const blob = new Blob(item.chunks, { type: mime });
    const duration = (item.stoppedAt ?? Date.now()) - item.startedAt;
    const discarded = !isCurrentCapture(item);
    // A sparse UI meter cannot prove silence, especially for quiet/short words.
    // Submit nonempty recorder bytes; STT owns evidence-based silence handling.
    cleanupCaptureState(item);
    if (discarded) return;
    if (!blob.size) {
        setState('ready', 'No microphone signal detected. Hold NPC Push-to-Talk and try again.');
        return;
    }

    setState('transcribing');
    const reader = new FileReader();
    item.reader = reader;
    captureUpload = item;
    reader.onerror = () => { if (isCurrentCapture(item)) setState('ready', 'Could not read the recording. Try again.'); };
    reader.onload = async () => {
        if (!isCurrentCapture(item)) return;
        if (typeof reader.result !== 'string' || reader.result.length > MAX_CAPTURE_DATA_URL_BYTES) {
            setState('ready', 'The voice message was too large. Keep it under 12 seconds.');
            return;
        }
        const controller = new AbortController();
        item.controller = controller;
        let timer;
        try {
            await Promise.race([
                postResult('transcribe', { sessionId: item.sessionId, sessionRevision: item.sessionRevision,
                    generation: item.commandGeneration, durationMs: duration, audioDataUrl: reader.result }, { signal: controller.signal }),
                new Promise((_, reject) => { timer = setTimeout(() => {
                    controller.abort();
                    reject(new Error('capture_ack_timeout'));
                }, 10000); }),
            ]);
        } catch {
            if (isCurrentCapture(item)) {
                setState('ready', 'Voice upload failed. Hold NPC Push-to-Talk to retry or use text.');
                setTextFallback(true);
            }
        } finally {
            clearTimeout(timer);
            if (captureUpload === item) captureUpload = null;
        }
    };
    reader.readAsDataURL(blob);
}

function ensurePlaybackContext() {
    if (playbackContext && playbackContext.state !== 'closed') return playbackContext;
    // Previous context was closed (CEF idle cleanup) — discard and recreate.
    playbackContext = null;
    const AudioContextClass = window.AudioContext || window.webkitAudioContext;
    if (!AudioContextClass) return null;
    playbackContext = new AudioContextClass();
    return playbackContext;
}

function lifecycle(entry, phase, code) {
    if (phase === 'started') {
        if (entry.startedAck) return;
        entry.startedAck = true;
    } else {
        if (entry.terminalAck) return;
        entry.terminalAck = true;
    }
    post('audioLifecycle', {
        sessionId: entry.sessionId,
        sessionRevision: entry.sessionRevision,
        utteranceId: entry.utteranceId,
        phase,
        code: code || null,
    }).catch(() => {});
}

function removeSpeaker(entry, phase = 'ended', code, fadeMs = 0) {
    if (!entry || entry.stopping) return;
    entry.stopping = true;
    // Remove it from scheduling immediately. The media node may keep fading,
    // but it no longer consumes a mixer slot or receives spatial updates.
    speakers.delete(entry.utteranceId);
    const finish = () => {
        entry.audio.onplaying = null;
        entry.audio.onended = null;
        entry.audio.onerror = null;
        entry.audio.pause();
        // Release the media resource so CEF does not hold stale connections
        // or leak MediaElementSource bindings between utterances.
        if (typeof entry.audio.removeAttribute === 'function') entry.audio.removeAttribute('src');
        entry.audio.src = '';
        if (typeof entry.audio.load === 'function') entry.audio.load();
        entry.source?.disconnect();
        entry.gain?.disconnect();
        entry.pan?.disconnect();
        lifecycle(entry, phase, code);
        if (entry.interacting && sessionId === entry.sessionId && sessionRevision === entry.sessionRevision && speakers.size === 0) setState('ready');
    };
    if (fadeMs > 0 && entry.gain && playbackContext) {
        entry.gain.gain.cancelScheduledValues(playbackContext.currentTime);
        entry.gain.gain.setTargetAtTime(0, playbackContext.currentTime, Math.max(0.01, fadeMs / 3000));
        setTimeout(finish, fadeMs);
    } else finish();
}

function stopUtterance(utteranceId, reason = 'interrupted', fadeMs = 100) {
    if (utteranceId) {
        removeSpeaker(speakers.get(utteranceId), 'interrupted', reason, fadeMs);
        return;
    }
    for (const entry of [...speakers.values()]) removeSpeaker(entry, 'interrupted', reason, fadeMs);
}

async function playSpatialAudio(data) {
    if (!data?.url || !data?.utteranceId) return;
    const incomingRevision = Number(data.sessionRevision || 0);
    if (data.sessionId === sessionId && incomingRevision && incomingRevision < sessionRevision) return;
    stopUtterance(data.utteranceId, 'superseded', 0);
    while (speakers.size >= MAX_SPEAKERS) {
        const oldest = [...speakers.values()].sort((a, b) => a.createdAt - b.createdAt)[0];
        removeSpeaker(oldest, 'interrupted', 'mixer_capacity', 60);
    }

    const audio = new Audio();
    audio.crossOrigin = 'anonymous';
    audio.preload = 'auto';
    audio.src = data.url;
    const entry = {
        audio,
        utteranceId: data.utteranceId,
        sessionId: data.sessionId || sessionId,
        sessionRevision: Number(data.sessionRevision || sessionRevision || 0),
        speakerId: data.speakerId || data.npcId || 'npc',
        interacting: data.nearby !== true,
        baseVolume: Math.max(0, Math.min(1, Number(data.volume ?? 1))),
        spatialGain: Math.max(0, Math.min(1, Number(data.initialGain ?? 0))),
        spatialPan: Math.max(-1, Math.min(1, Number(data.initialPan ?? 0))),
        createdAt: Date.now(),
        startedAck: false,
        terminalAck: false,
        stopping: false,
        source: null,
        gain: null,
        pan: null,
    };
    speakers.set(entry.utteranceId, entry);

    const context = ensurePlaybackContext();
    if (context) {
        try {
            if (context.state === 'suspended') await context.resume();
            if (entry.stopping || speakers.get(entry.utteranceId) !== entry) return;
            entry.source = context.createMediaElementSource(audio);
            entry.gain = context.createGain();
            entry.gain.gain.value = entry.baseVolume * entry.spatialGain;
            if (typeof context.createStereoPanner === 'function') {
                entry.pan = context.createStereoPanner();
                entry.pan.pan.value = entry.spatialPan;
                entry.source.connect(entry.gain).connect(entry.pan).connect(context.destination);
            } else entry.source.connect(entry.gain).connect(context.destination);
        } catch {
            entry.source = null;
            entry.gain = null;
            entry.pan = null;
            audio.volume = entry.baseVolume * entry.spatialGain;
        }
    }

    if (entry.interacting) {
        for (const [id, prev] of speakers.entries()) {
            if (prev.interacting && id !== entry.utteranceId) {
                removeSpeaker(prev, 'interrupted', 'superseded', 60);
            }
        }
    }

    if (entry.stopping || speakers.get(entry.utteranceId) !== entry) return;
    audio.onplaying = () => {
        if (entry.stopping) { audio.pause(); return; }
        lifecycle(entry, 'started');
        if (entry.interacting) setState('speaking');
    };
    audio.onended = () => removeSpeaker(entry, 'ended');
    audio.onerror = () => {
        if (!entry.stopping && audio.crossOrigin) {
            if (typeof audio.removeAttribute === 'function') audio.removeAttribute('crossorigin');
            audio.crossOrigin = null;
            if (typeof audio.load === 'function') audio.load();
            audio.play().catch(() => removeSpeaker(entry, 'error', 'media_error'));
            return;
        }
        removeSpeaker(entry, 'error', 'media_error');
    };
    try {
        await audio.play();
        if (entry.stopping) audio.pause();
    } catch (playError) {
        // CEF/NUI often suspends the AudioContext after an utterance ends.
        // Resume it and retry once before reporting failure.
        if (!entry.stopping && playbackContext && playbackContext.state === 'suspended') {
            try {
                await playbackContext.resume();
                await audio.play();
                if (entry.stopping) audio.pause();
                return;
            } catch { /* fall through to failure */ }
        }
        const wasCancelled = entry.stopping;
        removeSpeaker(entry, 'error', 'play_rejected');
        if (!wasCancelled && entry.interacting && sessionId === entry.sessionId) setState('ready', 'Audio unavailable — the subtitle is still available.');
    }
}

function applySpatialSnapshot(entries) {
    for (const spatial of entries || []) {
        const entry = speakers.get(spatial.utteranceId);
        if (!entry) continue;
        const gain = entry.baseVolume * Math.max(0, Math.min(1, Number(spatial.gain ?? 0)));
        const pan = Math.max(-1, Math.min(1, Number(spatial.pan ?? 0)));
        entry.spatialGain = Math.max(0, Math.min(1, Number(spatial.gain ?? 0)));
        entry.spatialPan = pan;
        if (entry.gain && playbackContext) {
            entry.gain.gain.setTargetAtTime(gain, playbackContext.currentTime, 0.04);
            if (entry.pan) entry.pan.pan.setTargetAtTime(pan, playbackContext.currentTime, 0.04);
        } else entry.audio.volume = gain;
    }
}

function closeConversation() {
    cancelCapture({ discard: true });
    releasePreparedMicrophone();
    captureCommandGeneration = null;
    microphoneSetupOpen = false;
    stopUtterance(null, 'conversation_closed', 60);
    ui.app.hidden = true;
    ui.purchase.hidden = true;
    setTextFallback(false);
    showTranscript('');
    showFallbackSubtitle('');
    stopWaveformAnimation();
    clearTimeout(stateTimer);
    stateTimer = null;
    voiceEnabled = false;
    sessionId = null;
    sessionRevision = 0;
}

ui.form.addEventListener('submit', event => {
    event.preventDefault();
    const text = ui.input.value.trim();
    if (!text || !sessionId) return;
    cancelCapture();
    showTranscript(text);
    ui.input.value = '';
    setState('deliberating');
    const expectedSession = sessionId;
    postResult('sendMessage', { sessionId: expectedSession, text, requestId: requestId() })
        .catch(() => {
            if (sessionId !== expectedSession) return;
            if (!ui.input.value) ui.input.value = text;
            setState('error', 'Message could not be sent. Try again below.');
            setTextFallback(true);
        });
});

document.getElementById('close').addEventListener('click', () => {
    if (sessionId) post('endConversation', { sessionId });
    else if (microphoneSetupOpen) {
        microphoneSetupOpen = false;
        ui.app.hidden = true;
        post('microphoneSetupDone').catch(() => {});
    } else if (pendingCaptureBinding) {
        const generation = pendingCaptureBinding.commandGeneration;
        cancelCapture();
        ui.app.hidden = true;
        post('cancelPendingCapture', { generation }).catch(() => {});
    }
});
document.getElementById('confirm').addEventListener('click', () => {
    if (!sessionId) return;
    ui.purchase.hidden = true;
    setState('action_pending', 'Completing purchase…');
    postResult('confirmPurchase', { sessionId }).catch(() => {
        ui.purchase.hidden = false;
        setState('error', 'Purchase confirmation could not be sent. Try again.');
    });
});
ui.textToggle.addEventListener('click', () => setTextFallback(ui.form.hidden));
document.getElementById('prepareMicrophone')?.addEventListener('click', prepareMicrophone);
document.getElementById('microphoneDevice')?.addEventListener('change', event => {
    microphoneDeviceId = event.target.value;
    prepareMicrophone();
});
navigator.mediaDevices?.addEventListener?.('devicechange', () => refreshMicrophones().catch(() => {}));
window.addEventListener('pagehide', closeConversation);

window.addEventListener('keydown', event => {
    if (previewState === 'demo' && (event.key === 'ArrowLeft' || event.key === 'ArrowRight')) {
        event.preventDefault?.();
        stepPreview(event.key === 'ArrowRight' ? 1 : -1);
        return;
    }
    if (event.key === 'Escape' && sessionId && !window.PeakShop?.isOpen()) post('endConversation', { sessionId });
});

window.addEventListener('message', event => {
    const message = event.data || {};
    if (message.action === 'microphoneSetup') {
        microphoneSetupOpen = true;
        ui.app.hidden = false;
        ui.npcName.textContent = 'Microphone setup';
        ui.occupation.textContent = 'Prepare before speaking to an NPC';
        setState('ready', 'Select Prepare microphone, allow access, then close this panel.');
        refreshMicrophones().catch(() => {});
        return;
    }
    if (message.action === 'beginPendingRecording') { beginRecording(message.data?.generation, true); return; }
    if (message.action === 'beginBargeRecording') { beginRecording(message.data?.generation, true, message.data); return; }
    if (message.action === 'bindRecording') { bindRecording(message.data); return; }
    if (message.action === 'prepareMicrophone') { prepareMicrophone(); return; }
    if (message.action === 'startRecording') {
        beginRecording(message.data?.generation);
        return;
    }
    if (message.action === 'stopRecording') {
        stopRecording(message.data?.generation);
        return;
    }
    if (message.action === 'cancelRecording') {
        if (Number.isFinite(message.data?.generation) && message.data.generation !== captureCommandGeneration) return;
        const pending = pendingCaptureBinding && !pendingCaptureBinding.bound;
        cancelCapture({ discard: true });
        if (pending) setState('error', 'The NPC connection was cancelled. Your recording was discarded. Hold NPC Push-to-Talk to retry.');
        return;
    }
    if (message.action === 'stopUtterance') {
        stopUtterance(message.data?.utteranceId, message.data?.reason, Number(message.data?.fadeMs ?? 100));
        return;
    }
    if (message.action === 'spatial') {
        applySpatialSnapshot(message.data?.entries);
        return;
    }
    if (message.action === 'close') {
        closeConversation();
        return;
    }
    if (message.action === 'subtitleFallback' && message.data?.text) {
        showFallbackSubtitle(message.data.text);
        return;
    }
    if (message.action === 'cursor') {
        const active = message.data?.active === true;
        ui.dock.dataset.interactive = String(active);
        if (!active) {
            setTextFallback(false);
            ui.input.blur();
        }
        return;
    }
    if (message.action === 'audio') {
        playSpatialAudio(message.data);
        return;
    }
    if (message.action === 'state') {
        const payload = message.data?.payload || {};
        const state = message.data?.state || 'ready';
        if (payload.nearby) return;
        const incomingRevision = Number(payload.sessionRevision || 0);
        if (payload.sessionId === sessionId && incomingRevision && incomingRevision < sessionRevision) return;
        const pending = pendingCaptureBinding && !pendingCaptureBinding.bound ? pendingCaptureBinding : null;
        const bargeAck = pending?.barge && state === 'capturing'
            && payload.sessionId === pending.barge.sessionId
            && payload.bargeCaptureGeneration === pending.commandGeneration
            && payload.interruptedRevision === pending.barge.sessionRevision
            && payload.interruptedUtteranceId === pending.barge.utteranceId
            && incomingRevision === pending.barge.sessionRevision + 1
            && Date.now() < pending.deadline;
        if (payload.sessionId === sessionId && incomingRevision > sessionRevision
            && !(pending && (!pending.barge || bargeAck))) cancelCapture();
        if (typeof payload.name === 'string' && payload.name.trim()) ui.npcName.textContent = payload.name.trim();
        if (payload.sessionId) {
            if (sessionId && payload.sessionId !== sessionId) closeConversation();
            sessionId = payload.sessionId;
            sessionRevision = Number(payload.sessionRevision || sessionRevision || 0);
            if (Object.prototype.hasOwnProperty.call(payload, 'voiceInputEnabled')) {
                voiceEnabled = payload.voiceInputEnabled === true;
                if (!voiceEnabled) { cancelCapture(); releasePreparedMicrophone(); }
            }
            if (typeof payload.occupation === 'string' && payload.occupation.trim()) {
                ui.occupation.textContent = payload.occupation.trim();
            }
            ui.app.hidden = false;
        }
        if (payload.transcript) showTranscript(payload.transcript);
        if (Object.prototype.hasOwnProperty.call(payload, 'pendingConfirmation')) {
            ui.purchase.hidden = payload.pendingConfirmation !== true;
        } else if (payload.transactionQuote) ui.purchase.hidden = false;
        if (payload.transactionQuote && Array.isArray(payload.transactionQuote.items)) {
            const quote = payload.transactionQuote;
            const items = quote.items.map(item => `${item.quantity} × ${item.label || item.item}`).join(', ');
            document.getElementById('purchaseSummary').textContent = `${quote.kind === 'sell' ? 'Sell' : 'Buy'} ${items} for $${quote.total}?`;
        }
        const effectiveState = state === 'thinking' && stateCopy[payload.phase] ? payload.phase : state;
        setState(effectiveState, payload.message);
        if (pendingCaptureBinding && !pendingCaptureBinding.bound && capture?.recorder?.state === 'recording') setState('capturing');
        if (!voiceEnabled && payload.sessionId) {
            setTextFallback(true);
            ui.status.textContent = 'Voice is unavailable — type your message below';
        }
        if (effectiveState === 'speaking' && !payload.audioUrl && !payload.audio?.url) {
            const duration = Math.min(9000, Math.max(2800, String(payload.text || '').length * 48));
            stateTimer = setTimeout(() => sessionId && setState('ready'), duration);
        }
        return;
    }
    if (message.action === 'notice' && message.data?.message) ui.status.textContent = message.data.message;
});

window.addEventListener('beforeunload', closeConversation);

const previewStates = ['ready', 'capturing', 'transcribing', 'deliberating', 'speaking', 'action_pending', 'error'];
let previewIndex = Math.max(0, previewStates.indexOf(previewState));
let previewRevision = 0;

function renderPreview(state) {
    previewIndex = Math.max(0, previewStates.indexOf(state));
    previewRevision += 1;
    showTranscript('');
    showFallbackSubtitle('');
    window.dispatchEvent(new MessageEvent('message', {
        data: { action: 'state', data: { state, payload: {
            sessionId: 'preview-session', sessionRevision: previewRevision, npcId: 'shopkeeper',
            name: 'Martin Hale', occupation: 'Shopkeeper', voiceInputEnabled: true,
            phase: state,
            transcript: state === 'deliberating' ? 'What have you heard about the crew near the docks?' : undefined,
            text: state === 'speaking' ? 'Depends who is asking. People around here remember how you treat them.' : undefined,
            message: state === 'error' ? 'resident_handoff_timeout' : undefined,
            pendingConfirmation: state === 'action_pending',
        } } },
    }));
    if (state === 'speaking') showFallbackSubtitle('Depends who is asking. People around here remember how you treat them.');
    const label = document.getElementById('previewStateLabel');
    if (label) label.textContent = stateCopy[state]?.[0] || state;
}

function stepPreview(direction) {
    previewIndex = (previewIndex + direction + previewStates.length) % previewStates.length;
    renderPreview(previewStates[previewIndex]);
}

if (previewMode) {
    const state = stateCopy[previewState] ? previewState : 'ready';
    if (previewState === 'demo') {
        const controls = document.getElementById('previewControls');
        controls.hidden = false;
        document.getElementById('previewPrevious').addEventListener('click', () => stepPreview(-1));
        document.getElementById('previewNext').addEventListener('click', () => stepPreview(1));
    }
    renderPreview(state);
}
