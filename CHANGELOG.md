# Changelog

All notable changes to Peak AI NPC are documented here.

## 1.0.0 — Open Source Release

Initial public open-source release.

### Features

- **Conversations** — Server-authoritative AI dialogue with any configured NPC or eligible ambient ped.
- **Voice I/O** — Hold-to-talk microphone (PTT) with spatial WebAudio playback, barge-in, lip sync, and 3D subtitles. Text/keyboard fallback always available.
- **27 voice profiles** — Named character voices mapped to ElevenLabs premade voices with accent, age, and delivery metadata.
- **Provider-neutral** — OpenAI-compatible, native Anthropic, Gemini, Ollama for text; ElevenLabs, Cartesia, OpenAI for TTS; Whisper-compatible for STT.
- **NPC tools** — Configured NPCs can give items, trigger missions, open shop menus, and run server-side commands. Each tool is NPC-allowlisted and server-validated.
- **Memory** — Persistent memory per character and per player using file stores or PostgreSQL.
- **Residents** — Ambient NPCs with simulated identity, personality, and schedule. Resident voices are deterministically assigned from the voice pool.
- **Vision** — Optional screenshot context for NPCs. Disabled by default; must be explicitly opted in per server.
- **Commerce** — Shop NPCs can quote and settle purchases through server-authoritative framework validation (QBCore, ESX, Ox).
- **Framework support** — QBCore, ESX, Ox/Qbox, and custom frameworks. All framework integrations are bounded and fail visibly when missing.
- **Spatial audio** — Client-side distance attenuation, stereo panning, and line-of-sight occlusion without double-attenuation artifacts.
- **Scene context** — Every NPC turn is grounded in bounded FiveM-native scene observations (nearby entities, player state, danger).
- **End-to-end deadlines** — Turn timeouts return to a usable text/subtitle state on provider stall, microphone failure, or network error.
- **Dashboard** — In-gateway admin view showing active sessions, turn history, and NPC status.

### Gateway

- Node.js/TypeScript HTTP gateway with shared-secret authentication.
- PostgreSQL and file-backed memory stores with async extraction queue.
- Streaming MP3 audio delivery with expiring tokens, CORS, and in-flight coalescing.
- Provider-level rate limiting, fallback providers, and retry configuration.
- Docker Compose deployment with read-only container filesystem and named volumes.
