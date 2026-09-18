# Gateway Deployment

## Local development

Run `npm install` and `npm run dev` from `gateway/`. The default mock provider and file memory store do not require external services. Speech/transcription duration validation requires FFmpeg on PATH (or `AI_NPC_FFMPEG_PATH`); the runtime Docker image includes it.

## PostgreSQL (optional)

PostgreSQL provides persistent memory and resident state across gateway restarts. Without it the gateway uses file-backed memory stores.

Set `AI_NPC_DATABASE_URL` and apply migrations from `gateway/migrations/` in numeric order. The gateway initializes its schema on startup.

## Container deployment

From the repo root:

```powershell
Copy-Item .env.example gateway/.env
# Edit gateway/.env with your provider keys and secrets
docker compose up --build
```

Compose keeps the container root filesystem read-only, stores catalog data in the `ainpc-gateway-data` volume, and stores memory/relationships in the PostgreSQL volume. Back up both named volumes before upgrades and restore them together if you need to roll back.

## Self-hosted production checklist

Before exposing the gateway publicly:

- **Gateway secret**: Set `AI_NPC_GATEWAY_SECRET` to a long random string (32+ characters). The FiveM resource sends this value; never put provider keys in the resource or in Lua files.
- **Public URL**: Set `AI_NPC_PUBLIC_BASE_URL` to an HTTPS URL reachable by player clients. It serves expiring audio tokens and one-time screenshot uploads — never provider credentials.
- **Local development flag**: Set `AI_NPC_LOCAL_DEVELOPMENT=false`. Loopback HTTP audio is permitted only when this flag is `true`; with it off, startup rejects any non-HTTPS or loopback public base URL.
- **TLS**: Put the service behind TLS and an access-controlled reverse proxy (nginx, Caddy, Cloudflare Tunnel, etc.).
- **Provider keys**: Configure all provider keys through `.env` or environment variables — never in source files or Lua.
- **PostgreSQL**: Keep PostgreSQL off the public interface.
- **Transcripts**: Keep `AI_NPC_ADMIN_STORE_TRANSCRIPTS=false` unless you have an explicit disclosure and need for bounded, process-memory conversation text. The dashboard still shows operational turn metadata when transcript capture is off.

## Voice registry

Mount the reviewed voice-profile manifest and persist `AI_NPC_VOICE_REGISTRY_PATH`. Use `npm run voices:provision` to register voices and `npm run voices:review` to approve mappings. Runtime never creates or deletes ElevenLabs account voices automatically. Approved startup may synthesize a short preflight clip.

## Vision

Vision is disabled by default. Enable per server with `setr peak_ai_npc_vision_enabled 1` and start `screenshot-basic` before `peak-ai-npc`. Vision supports OpenAI-compatible, native Gemini, and native Ollama adapters. Configure the independent `AI_NPC_VISION_FALLBACK_*` slot only with a separately authorized key/model. Vision fails over only on transient transport/timeout, 408/425/429 and 5xx failures — never on authentication or invalid-input errors. Review and disclose your provider's data retention terms before enabling vision on a live server.

## Upgrade and rollback

1. Record installed resource/gateway versions. Preserve customized editable Lua files separately.
2. Back up the PostgreSQL database and gateway data volume (voice registry, catalog, memory stores).
3. Test migrations against a restored database copy before touching production.
4. Stop conversations during the change, stop the old gateway, install the new paired resource/gateway, merge editable config deliberately.
5. Run health checks (`/health`) and diagnostics (`ainpc_status`) before reopening the server.
6. On failure, stop the new gateway and restore the previous paired artifact and database together.
