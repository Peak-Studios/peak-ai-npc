# Gateway dashboard

The first dashboard surface is served by the gateway at `/admin`. It provides:

- Health/provider/memory status.
- Registered server list.
- Per-server request, token, failure, and latency metrics.
- Authenticated NPC catalog listing, JSON editing, save, and delete controls.

It intentionally keeps the admin secret in the browser session only and sends it only as the gateway authentication header. Production deployments should put the gateway behind TLS, add operator identity/roles, CSRF protection, and replace this local operational surface with the full hosted dashboard described in the product plan.
