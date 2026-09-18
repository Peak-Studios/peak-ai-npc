# Text provider configuration

The FiveM resource is provider-agnostic. It sends an authenticated, vendor-neutral turn to the gateway; the gateway selects the model. Keep provider credentials in the gateway environment. Scoped installation tokens belong in server-only configuration; neither belongs in client Lua or NUI.

## Adapter configuration examples

| Goal | Text | STT | TTS |
|---|---|---|---|
| Groq and Cartesia | Groq `openai/gpt-oss-20b` | Groq `whisper-large-v3-turbo` | Cartesia `sonic-3.5` |
| Groq-only capabilities | Groq `openai/gpt-oss-20b` | Groq `whisper-large-v3-turbo` | Groq Orpheus; qualify the selected model/language |
| ElevenLabs voice registry | A qualified text provider | A qualified compatible STT | ElevenLabs `eleven_flash_v2_5` |
| Private/self-hosted | Ollama or another compatible runtime | Compatible local Whisper service | Compatible local TTS service |

These are implemented adapter configurations, not price, quality, capacity or commercial-rights benchmarks. Confirm the selected model, account access, language and output format against the vendor documentation before enabling it. The Groq Orpheus example below uses WAV and a 200-character bound. Current local real-provider evidence is recorded in `RELEASE_READINESS.md`; every advertised combination still needs its own acceptance evidence.

English is the product default, not a restriction. Leave the STT language unset for automatic detection, or configure a short language hint. TTS language coverage and pronunciation vary by provider and voice, so every launch language still needs a real listening/transcription test. No provider can honestly guarantee zero quality change across every language.

## Local Ollama

```dotenv
AI_NPC_PROVIDER=ollama
AI_NPC_PROVIDER_ENDPOINT=http://127.0.0.1:11434/v1
AI_NPC_PROVIDER_MODEL=qwen3:8b
AI_NPC_PROVIDER_KEY=
```

Before starting the gateway, pull the selected model, for example `ollama pull qwen3:8b`. The model must support chat; tool calling is recommended for NPC commerce, missions, and actions. If it does not reliably return tool calls, it can still provide text-only NPC dialogue.

After configuring any provider, run `npm run build` followed by `node scripts/provider-preflight.mjs` from `gateway/`. It performs one small live text request and prints the selected provider, usage when available, and the response. It intentionally fails in mock mode so it cannot be mistaken for production-provider validation.

## OpenAI-compatible endpoints

Use this mode for any server that implements the Chat Completions API: OpenAI, OpenRouter, Groq, Together, Mistral, Fireworks, vLLM, llama.cpp, LocalAI, LM Studio, and LiteLLM are common examples.

```dotenv
AI_NPC_PROVIDER=openai-compatible
AI_NPC_PROVIDER_ENDPOINT=https://your-provider.example/v1
AI_NPC_PROVIDER_MODEL=your-model-name
AI_NPC_PROVIDER_KEY=provider-secret-if-required
```

An empty key is supported for local endpoints. Verify that the chosen endpoint supports `tools` / function calling before enabling tool-bearing NPC definitions.

For a chat-only model, set `AI_NPC_PROVIDER_TOOL_MODE=off`. The NPC remains conversational, but cannot request shop, mission, inventory, or game-action tools; server-side tool security remains unchanged.

The optional OpenAI-compatible TTS, vision, and STT adapters also omit the authorization header when their respective keys are empty, allowing compatible self-hosted capability services to be used without placeholder credentials.

## Native APIs

```dotenv
# Anthropic
AI_NPC_PROVIDER=anthropic
AI_NPC_PROVIDER_KEY=...
AI_NPC_PROVIDER_MODEL=your-account-enabled-anthropic-model
AI_NPC_PROVIDER_ENDPOINT=https://api.anthropic.com/v1

# Google Gemini
AI_NPC_PROVIDER=gemini
AI_NPC_PROVIDER_KEY=...
AI_NPC_PROVIDER_MODEL=gemini-2.5-flash
AI_NPC_PROVIDER_ENDPOINT=https://generativelanguage.googleapis.com
```

## Failover

Set the parallel fallback variables to a different provider. The gateway invokes this provider only when the primary request fails.

```dotenv
AI_NPC_FALLBACK_PROVIDER=ollama
AI_NPC_FALLBACK_ENDPOINT=http://127.0.0.1:11434/v1
AI_NPC_FALLBACK_MODEL=qwen3:8b
AI_NPC_FALLBACK_KEY=
```

If no fallback is configured, the original provider error is returned. The gateway does not silently switch to mock dialogue. Unknown provider names fail at startup, which prevents a typo from looking like a working production model.

## Speech, transcription, and vision

These capabilities are independent from the text model. OpenAI-compatible TTS/STT/vision services accept `openai-compatible`, `openai`, or `custom`. TTS also has native `cartesia` and `elevenlabs` modes. A compatible local service can leave its key empty; hosted credentials must remain in the gateway environment.

```dotenv
# Generic OpenAI-compatible TTS
AI_NPC_TTS_PROVIDER=openai-compatible
AI_NPC_TTS_ENDPOINT=http://127.0.0.1:8880/v1
AI_NPC_TTS_MODEL=your-tts-model
AI_NPC_TTS_VOICE=your-voice
AI_NPC_TTS_FORMAT=mp3
AI_NPC_TTS_MAX_CHARACTERS=1200
AI_NPC_TTS_KEY=

# OpenAI-compatible STT
AI_NPC_STT_PROVIDER=openai-compatible
AI_NPC_STT_ENDPOINT=http://127.0.0.1:8000/v1
AI_NPC_STT_MODEL=whisper-1
AI_NPC_STT_KEY=

AI_NPC_VISION_PROVIDER=openai-compatible
AI_NPC_VISION_ENDPOINT=http://127.0.0.1:11434/v1
AI_NPC_VISION_MODEL=your-vision-model
AI_NPC_VISION_KEY=
```

The compatible TTS service must implement `POST /audio/speech`; STT must implement `POST /audio/transcriptions`; vision must accept OpenAI-style image content at `POST /chat/completions`. Text providers do not automatically provide those capabilities. Enable `Config.VoiceInput` only after STT is working.

### Groq text, STT, and limited TTS

```dotenv
AI_NPC_PROVIDER=openai-compatible
AI_NPC_PROVIDER_ENDPOINT=https://api.groq.com/openai/v1
AI_NPC_PROVIDER_KEY=replace-with-groq-key
AI_NPC_PROVIDER_MODEL=openai/gpt-oss-20b
AI_NPC_MAX_RESPONSE_CHARACTERS=200

AI_NPC_STT_PROVIDER=openai-compatible
AI_NPC_STT_ENDPOINT=https://api.groq.com/openai/v1
AI_NPC_STT_KEY=replace-with-groq-key
AI_NPC_STT_MODEL=whisper-large-v3-turbo

AI_NPC_TTS_PROVIDER=openai-compatible
AI_NPC_TTS_ENDPOINT=https://api.groq.com/openai/v1
AI_NPC_TTS_KEY=replace-with-groq-key
AI_NPC_TTS_MODEL=canopylabs/orpheus-v1-english
AI_NPC_TTS_VOICE=austin
AI_NPC_TTS_FORMAT=wav
AI_NPC_TTS_MAX_CHARACTERS=200
```

Use `canopylabs/orpheus-arabic-saudi` for the Saudi Arabic model. Verify the current supported voice names and accept any required model terms in Groq Console yourself; the application never accepts legal terms for an account.

### Native Cartesia TTS

```dotenv
AI_NPC_TTS_PROVIDER=cartesia
AI_NPC_TTS_KEY=replace-with-cartesia-key
AI_NPC_TTS_MODEL=sonic-3.5
AI_NPC_TTS_VOICE=replace-with-cartesia-voice-id
AI_NPC_TTS_FORMAT=mp3
AI_NPC_TTS_MAX_CHARACTERS=1200
```

The gateway calls Cartesia's authenticated `POST /tts/bytes` endpoint and defaults to API version `2026-03-01`. Override `AI_NPC_CARTESIA_VERSION` only when Cartesia's migration documentation requires it.

### Native ElevenLabs TTS

```dotenv
AI_NPC_TTS_PROVIDER=elevenlabs
AI_NPC_TTS_KEY=replace-with-elevenlabs-key
AI_NPC_TTS_MODEL=eleven_flash_v2_5
AI_NPC_TTS_FORMAT=mp3_44100_128
AI_NPC_TTS_DEFAULT_PROFILE=martin-hale
AI_NPC_TTS_MAX_CHARACTERS=1200
AI_NPC_VOICE_PROFILES_PATH=./voice-profiles.json
AI_NPC_VOICE_REGISTRY_PATH=./data/voice-registry.json
AI_NPC_VOICE_PROVISION_MAX=32
```

The implemented ElevenLabs realtime path uses `eleven_flash_v2_5`; an explicitly authored `qualityMode = 'quality'` uses `eleven_multilingual_v2`. The chosen model must also be in the reviewed profile's `modelIds`. FiveM v1 output for this adapter is `mp3_44100_128`.

NPC Lua never contains an ElevenLabs ID. It supplies a provider-neutral profile identity:

```lua
voice = {
    voiceProfileId = 'martin-hale',
    voiceSeed = 'shopkeeper',
    genderPresentation = 'masculine',
    ageBand = 'adult',
    language = 'en',
    qualityMode = 'realtime',
    deliveryPreset = 'warm'
}
```

`accent` is optional and explicit-only. Never derive it from a GTA model, name, ethnicity, or neighborhood. Every voiced request needs a reviewed `voiceProfileId` mapped to the active provider and selected model. Legacy `voice.voice`/`voice.provider` fields and implicit default character voices cannot bypass review; migrate them to private registry mappings. A missing, unreviewed or mismatched profile retains dialogue/subtitles and blocks its TTS request.

Copy `gateway/voice-profiles.example.json` to an operator-owned `voice-profiles.json`, review the requested descriptions and cost, put the API key only in the ignored gateway environment, then run:

```powershell
cd gateway
npm run voices:provision -- --server your-server-id --dry-run
npm run voices:provision -- --server your-server-id
```

The shipped example manifest contains 27 profiles: two story-only profile IDs for Martin Hale and Rico plus 25 ambient pool profiles. The current approved deployment maps these to 21 premade voices; story-only means excluded from ambient pools, not a custom or globally exclusive provider asset. Provisioning validates the provider catalog, creates only new unmapped profiles up to the integer cap, and keeps three previews under the private registry directory's `voice-auditions` folder (override with `AI_NPC_VOICE_AUDITIONS_PATH`). Transcript overlap, byte/duration bounds and cadence provide an automatic ranking; they do not measure clipping or replace a human listening review. One candidate is saved as **review required**, never automatically activated. `review.json` retains its fingerprint, selected preview, scores and mapping for inspection.

A durable per-profile intent directory prevents blind paid retries after a failed/lost provisioning response. Reconcile the provider and saved artifacts before repairing an interrupted operation; do not remove the directory merely to retry. An established mapping missing from the provider catalog stops with `voice_recast_requires_review` and remains unchanged. Existing account voices are never deleted. Runtime startup never creates voices; approved ElevenLabs profiles may perform one short synthesis preflight, which consumes operator provider usage.

The `/health` speech readiness is `configured`, `ready`, or `degraded`. ElevenLabs `ready` requires a reviewed default profile, credential, model, MP3 format, accessible reviewed roster and synthesis preflight. `/health.ok` describes core text/storage/entitlement availability; degraded speech does not disable text. Heartbeats still report degraded speech. Counts and profile IDs are safe to report; credentials and provider voice IDs remain private.

Delivery presets (`neutral`, `warm`, `stern`, `nervous`, `urgent`, `quiet`, and `menacing`) map to bounded ElevenLabs stability, similarity, style, speaker boost, and speed. The preset also supplies performance hints, subject to the resource's original-entity, authored-gesture and action policies. Flash receives natural punctuation and normalized numbers/currency, never v3-only audio tags.

The ElevenLabs adapter exposes upstream streaming to the opaque audio-delivery layer. Identical work is coalesced. Only explicit 429 rate-limit rejections retry before streaming; 5xx, network errors and lost responses may represent paid work and do not automatically redispatch. Audio is capped at 5 MB, the cache is byte-bounded to 64 MB, and every issued URL token has its own 60-second expiry.

Keep `AI_NPC_MAX_RESPONSE_CHARACTERS` at or below the strictest enabled TTS input limit so subtitles and audio contain the same complete reply. If TTS fails, the gateway returns the text response and the NUI keeps subtitles available.

Current vendor references:

- [Groq models and pricing](https://console.groq.com/docs/models), [Whisper STT](https://console.groq.com/docs/speech-to-text), and [Orpheus TTS](https://console.groq.com/docs/text-to-speech/orpheus)
- [Cartesia Sonic models](https://docs.cartesia.ai/build-with-cartesia/tts-models/latest), [TTS bytes API](https://docs.cartesia.ai/api-reference/tts/bytes), and [pricing](https://www.cartesia.ai/pricing)
- [ElevenLabs models](https://elevenlabs.io/docs/overview/models), [streaming TTS](https://elevenlabs.io/docs/api-reference/text-to-speech/stream), [voice catalog](https://elevenlabs.io/docs/api-reference/voices/search), [Voice Design](https://elevenlabs.io/docs/api-reference/text-to-voice/design), [create voice](https://elevenlabs.io/docs/api-reference/text-to-voice/create), and [API pricing](https://elevenlabs.io/pricing/api)
- [Ollama OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility)

## Operator voice review, recast and rollback

New mappings and legacy registry records without approval are **review required**. Loading an older registry preserves every provider ID and does not manufacture listening evidence. For a legacy upgrade, prepare an isolated candidate with a private copy of the registry and public/provider traffic disabled. Record actual listening approvals through that candidate's private operator API before promoting the reviewed registry and new image together; otherwise conversations retain text but those profiles cannot synthesize. Never run two writers against the live registry. The existing deployed gateway and its earlier preflight evidence do not certify this new review policy.

Compile the gateway, then use its running process through host loopback or an SSH tunnel. Keep `AI_NPC_OPERATOR_SECRET` in a private environment file; `AI_NPC_OPERATOR_URL` defaults to `http://127.0.0.1:8787` and the CLI rejects non-loopback destinations and redirects.

```sh
node --env-file=/private/operator.env dist/voice-review.js --server '*'
node --env-file=/private/operator.env dist/voice-review.js --request /private/voice-review-request.json
```

The first command lists profile IDs, provider/model names, revisions, fingerprints and review state without provider voice IDs. For an initial approval, listen to the retained audition and save this request privately with the exact fingerprint returned by the service:

```json
{
  "action": "approve",
  "serverId": "*",
  "profileId": "martin-hale",
  "expectedFingerprint": "replace-with-the-exact-64-character-fingerprint",
  "reviewedBy": "owner-handle",
  "evidence": "private audition recording and listening review reference"
}
```

Only use `approve` after the named reviewer has actually approved that identity. Automatic preview ranking is insufficient. `*` is the explicit global scope; a tenant review never silently edits a global fallback. Approval is bound to the provider ID, model allowlist and revision fingerprint. The full listening matrix, pronunciation and per-profile settings qualification remain release requirements beyond this mapping gate.

For another provider, `register` accepts a new profile with a `candidate` object containing `provider` (`elevenlabs`, `cartesia` or `openai-compatible`), private `voiceId`, `name` and `modelIds`; it starts unreviewed. It does not overwrite an existing mapping. Use `stage` with the active fingerprint and the new `candidate` mapping to propose a recast. The current approved voice keeps serving while the candidate is pending. Approve or `reject` using the candidate fingerprint and listening evidence. Rejected revisions remain in the audit record and their fingerprints cannot approve a later attempt.

`rollback` requires the current active fingerprint, an earlier approved `targetRevision`, reviewer and evidence. It creates a new monotonically numbered revision using that earlier mapping; it does not erase history. A pending candidate must be resolved first. History is bounded to 100 retained revisions/rejections and fails closed at capacity instead of deleting audit evidence. All review writes commit atomically through the owning gateway process. These APIs are protected by the separate operator credential and excluded from public nginx routing.

Voice approval changes do not provision assets, rewrite resident biographies, replace profile IDs, or claim commercial rights. A missing provider asset, provider/model mismatch or unreviewed record keeps speech unavailable for that profile. Requalify the gateway speech preflight after configuration changes; the displayed readiness reflects the startup preflight rather than an inferred listening approval.

## Adding a vendor with a proprietary protocol

The provider boundary is `gateway/src/providers/types.ts`. Implement the one-method `TextProvider` interface and register the provider name in `gateway/src/providers/factory.ts`. It must return only plain text and a validated allowlisted tool call; it cannot invoke FiveM events, exports, or server actions directly. This means a new vendor integration does not require any change to the FiveM resource or its security model.
