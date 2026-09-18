# Peak AI NPC: Getting Started

Peak AI NPC is a FiveM resource for server-authoritative conversations with artificial intelligence. The resource owns gameplay state, while the lightweight self-hosted gateway handles AI model interaction, memory, speech synthesis, vision processing, and speech-to-text transcription. OneSync is required by the manifest.

## 1. Install the resource

Copy the `peak-ai-npc/` folder into your server's resources directory. The folder name matters because it is the FiveM resource name.

```text
resources/[peak]/peak-ai-npc/
```

Add the gateway settings and start the resource:

```cfg
set peak_ai_npc_gateway_url "http://127.0.0.1:8787"
set peak_ai_npc_gateway_secret "replace-with-a-long-random-secret"
set peak_ai_npc_server_id "my-server"
ensure peak-ai-npc
```

Keep the secret in server configuration or a secret manager. Never put provider keys in Lua, NUI, or client files.

## 2. Start the gateway

The gateway defaults to deterministic mock responses, which is useful for local integration tests. For production dialogue, copy `.env.example` to `.env`, choose a text provider, and configure it only in the gateway environment. `ollama` needs no key by default; `openai-compatible` works with compatible hosted services and self-hosted servers; native `anthropic` and `gemini` modes are also available. See [PROVIDERS.md](PROVIDERS.md).

```powershell
Copy-Item .env.example gateway/.env
# Edit gateway/.env: set a long gateway secret matching server.cfg.
cd gateway
npm ci
npm run build
npm start
```

For PostgreSQL-backed memory:

```powershell
# From the repository/operator-package root, with its own reviewed .env:
Copy-Item .env.example .env
docker compose up --build
```

## 3. Test the installation

In game, aim at an example NPC or an eligible ambient ped and use `/ainpc`. Ambient peds only receive the configured reversible social-action allowlist; configured NPCs keep their role-specific store/mission tools. From the server console, run `ainpc_status`. The status output is redacted and reports the detected framework, optional integrations, NPC counts, and gateway health.

You can verify gateway build and types from the gateway directory:

```powershell
cd gateway
npm run typecheck
npm run build
```


## 4. Configure NPCs and integrations

Edit `peak-ai-npc/shared/config.lua` for server lore, memory, target behavior, and optional dependencies. Register custom NPCs, tools, context providers, and trusted mission completion from another server resource using the exports documented in [INTEGRATION.md](INTEGRATION.md).

Model output cannot grant money, items, permissions, or arbitrary events. Durable actions must be implemented as fixed, server-side tools that validate permissions and current gameplay state.

## 5. Voice-first input

Configure a compatible transcription service in the gateway:

```dotenv
AI_NPC_STT_PROVIDER=openai-compatible
AI_NPC_STT_ENDPOINT=http://127.0.0.1:8000/v1
AI_NPC_STT_MODEL=whisper-1
AI_NPC_STT_KEY=
```

`Config.VoiceInput.enabled` is on in the voice-first default. Hold the remappable **NPC Voice** key (default **G**) to talk; releasing it ends capture. Starting a new capture while the NPC is speaking performs synchronized barge-in for nearby listeners. `E` and typed input remain fallbacks. The resource also checks gateway health and only exposes the microphone when `/health` reports a real transcription provider, so a missing STT configuration falls back cleanly to text. The compact bottom-center status strip does not capture the cursor by default: press **Left Shift** to toggle its microphone/text controls, and **Esc** to end the conversation. The recorder confirms when it hears a signal, stops after you finish speaking, and retains a ten-second safety cap.

NPC replies appear as 3D subtitles over the speaking ped and remain available when TTS fails. Tune policy (`always`, `never`, `player_preference`, `audio_failed`, or `accessibility`), audience (`nearby` or `interacting`), distance, line of sight, wrapping, duration, accent color, and optional local-player transcript display in `Config.Subtitles`. Players can persist their own choices with `/ainpc_subtitles` and `/ainpc_accessibility`.

The maintained test deployment uses Groq text/STT and ElevenLabs speech. Other adapters are available for qualification; compare account/model availability, language quality, latency and cost before changing provider. Every speech profile must match an approved mapping for the selected provider/model. See [PROVIDERS.md](PROVIDERS.md).

## Troubleshooting

- `gateway registration failed`: check the URL, secret, and server ID convars, then confirm the gateway is listening.
- `target resource is not started`: start `ox_target` or `qb-target`, or leave target mode disabled to use the native interaction fallback.
- `mock` responses in production: set `AI_NPC_PROVIDER` to `ollama`, `openai-compatible`, `anthropic`, or `gemini`, then configure the matching endpoint/model/key in the gateway environment. See [PROVIDERS.md](PROVIDERS.md).
- no NPC appears: validate the model name, coordinates, OneSync setting, and the startup order in `examples/server.cfg`.
- voice button is hidden: confirm `Config.VoiceInput.enabled` is true and `/health` reports a transcription provider other than `none`.
- voice transcription fails: if the HUD says **No microphone signal detected**, check the Windows/FiveM input device and microphone permission first. Otherwise confirm the endpoint implements `POST /audio/transcriptions`, accepts the configured model and WebM/Ogg audio, and is reachable from the gateway.
- no NPC audio: check `GET http://127.0.0.1:8787/health`, then make one authenticated `POST /v1/speech` request with an existing approved `voiceProfileId`; this may consume provider credit. Ambient profile pools are in `Config.VoiceProfiles.ambientPools`; provider IDs stay in the gateway registry. `Config.Ambient.voices` is not a current option. Local testing requires the FiveM client and gateway on the same machine when `AI_NPC_PUBLIC_BASE_URL` is `http://127.0.0.1:8787`.
