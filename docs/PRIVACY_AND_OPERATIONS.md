# Privacy and operations

## Data and access

Conversation text and supplied context are sent to the selected text provider. Optional speech transcription sends microphone audio to the configured STT provider; speech generation sends NPC text to TTS. Vision is disabled by default. After an operator explicitly enables it, the default policy captures a screenshot in the backend on the first conversation turn, after the configured refresh interval, or for an urgent scene; `/ainpcvision` can also request one manually. Capture and recoverable failure remain silent in the player HUD so dialogue is not interrupted. Disable `automaticTurnContext` to keep vision manual-only. Provider account retention and regional processing must be reviewed and disclosed before enabling these capabilities.

Enable vision per server with replicated convar `setr peak_ai_npc_vision_enabled 1`; source defaults remain off. The vision prompt instructs providers to ignore overlays and written dialogue, but that instruction is not a privacy boundary: screenshots can still contain HUD, chat, names, location clues or third-party UI. Review capture composition and provider data terms, publish clear server-level disclosure before enabling vision, and do not configure an account or fallback whose terms have not been accepted by its owner. The absence of a per-capture popup must never be treated as permission for undisclosed collection.

Memory stores character/NPC/server identifiers, extracted facts and relationship state. Resident data stores identity and simulation state. Treat character identifiers and player-authored facts as sensitive. Limit database and admin access to operators, keep provider secrets solely in gateway deployment state, and disclose the enabled features and retention policy to players.

Keep `AI_NPC_ADMIN_STORE_TRANSCRIPTS=false` by default. Audio delivery and screenshot-upload tokens expire; expiration of access is different from a provider's data deletion policy. Operational logs and backups need their own retention schedule. Do not collect raw audio, screenshots, tokens, transcripts or player identifiers in support tickets unless needed and appropriately redacted.

## Upgrade and rollback

1. Record the installed resource/gateway versions and archive checksum. Preserve customized editable Lua files separately.
2. Back up the PostgreSQL database and gateway data volume (catalog, resident/file stores if used, voice registry and billing state). Protect backups as production data.
3. Restore that backup into an isolated environment and verify it can be read. Test migrations against the restored database before touching production. The gateway initializes its schema on startup; review bundled migrations first.
4. Stop new conversations during the scheduled change, stop the old gateway, install the paired resource/gateway candidate, and merge editable configuration deliberately. Never mix a new gateway with unreviewed older resource contracts.
5. Run health and redacted diagnostics, then the connected-player smoke rows before reopening access.
6. On failure, stop the new gateway and restore the previous paired artifact. If a schema/data migration is incompatible, restore the verified pre-upgrade database and data volume together. Do not run two gateways against the same file store.

Use PostgreSQL backups such as `pg_dump --format=custom` and restore with `pg_restore` using operator-owned connection configuration. The private candidate was exercised with this format in an isolated database; production operators must retain their own restore-test result and recovery time. Do not paste credentials into shell history or tickets. Backup success alone is insufficient.

## Support and incident collection

Include artifact checksum, resource/gateway versions, framework/inventory/target versions, a minimal reproduction, correlation ID, and redacted `ainpc_status`/health output. Classify failures as startup, provider, microphone, playback, persistence, or gameplay transaction. For provider failures retain text/subtitle fallback; for uncertain paid settlement resolve the same operation rather than generating a new paid request blindly.

