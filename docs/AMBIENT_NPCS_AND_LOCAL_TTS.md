# Ambient NPCs and local TTS

## Two NPC classes

- **Configured NPCs** are explicit definitions in the manifest-loaded `npcs/examples.lua`, a trusted server registration export, or the gateway catalog. Use them for stores, missions, rewards, policies, and other tools.
- **Ambient NPCs** are eligible non-player peds already in the world, including client-local population peds. Aim at one and use `/ainpc`, or select **Talk** through `ox_target` or `qb-target`.

Networked ambient NPCs are resolved on the server. Client-local population peds use a bounded descriptor that is distance-checked when the session starts. Live scene observations remain explicitly untrusted and can guide dialogue, reactions, and bounded local roaming, but cannot authorize money, inventory, missions, permissions, or other durable game state.

The default ambient allowlist contains `npc_react`, `npc_follow_player`, `npc_stop`, `npc_crouch`, `npc_perform_move`, `npc_look_at`, and `npc_walk_to_position`. Every action remains subject to its server validation, distance and lifecycle rules. Ambient people cannot sell items, start missions, dispatch services, or grant rewards.

`Config.Ambient` controls ambient interactions. Add unwanted models to `ignoredModels`, or set `enabled = false` to return to configured-role-only conversations.

The conversation HUD is a passive bottom-center status strip. Press **Left Shift** to show or hide its cursor controls; otherwise it does not capture focus, so the player can keep moving while talking. Press **Esc** to leave.

Random pedestrians enter the HUD as **Local resident**. Accepting a conversation binds persistent identity, voice assignment, appearance and history to the original pedestrian. Interaction must not replace, clone or teleport that entity. Streaming/restart suppression preserves original-world ownership separately from the resident record. When the player asks their name or the NPC naturally introduces themselves, the HUD updates to that name. Connected tests must still verify this behavior across streaming and ownership changes.

## Memory and consistency

The resident's name and biography are shared within that server/tenant, while learned-name status, memories, and seven relationship dimensions are private to each framework character. Stored resident IDs survive reconnect/restart; reidentifying an actual world pedestrian remains subject to the original-entity binding rules. A different character still sees **Local resident** until they independently learn the name.

The gateway performs strict structured memory extraction after every completed turn on a non-blocking queue. Deterministic capture still protects introductions, explicit remember requests, threats, gratitude, and summaries if the provider times out or fails. Background routines are deterministic and never change QBCore cash or inventory.

## Local TTS quick check

For one-computer testing, keep both settings local:

```dotenv
AI_NPC_PUBLIC_BASE_URL=http://127.0.0.1:8787
```

```cfg
set peak_ai_npc_gateway_url "http://127.0.0.1:8787"
```

Start the gateway from `gateway/`:

```powershell
npm run build
node --env-file=../.env dist/server.js
```

`GET /health` must report a configured speech provider; ElevenLabs additionally reports registry/catalog/preflight readiness. Ambient NPCs use provider-neutral profiles from `Config.VoiceProfiles.ambientPools`, with stable resident assignments. Provider voice IDs belong only in the private gateway registry. `Config.Ambient.voices` is not a current configuration option. Test one authenticated `/v1/speech` request with an existing approved profile before diagnosing NUI playback; provider calls may consume credit. Text and subtitles remain the fallback if synthesis or playback fails.

For remote players, replace the loopback public URL with a client-reachable HTTPS URL; `127.0.0.1` points to each player's own computer.
