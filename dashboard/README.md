# Gateway Control Dashboard

The gateway includes a self-hosted web control dashboard served at `/admin` (e.g. `http://127.0.0.1:8787/admin`).

It provides:
- **System status**: Real-time provider health, memory store state, and audio delivery statistics.
- **Server list**: Inspect registered FXServer connections, versions, and latency.
- **Usage & metrics**: Per-server request counts, token consumption, failures, and average response latency.
- **NPC Studio**: Interactive browser-based NPC catalog editor. Author and adjust NPC identities, prompts, voice profiles, and tool allowlists with direct JSON saving.
- **Resident Inspector**: View persistent resident AI state, simulated routines, moods, and trigger simulation ticks.
- **Privacy Controls**: Manage server-scoped data deletion and view current retention policies.

### Authentication

Access to `/admin` requires entering your `AI_NPC_GATEWAY_SECRET` (configured in `gateway/.env`). The secret is stored only in your active browser session and never sent to any third-party service.
