# Peak AI NPC — Configuration Guide

This guide covers the main open-for-edit settings in `shared/config.lua`. The shipped file remains authoritative for detailed behavior profiles and optional presentation settings.

> [!NOTE]
> All files in `peak-ai-npc` are completely open source and free to customize.

---

## Overview

Open `shared/config.lua` in your `peak-ai-npc` resource folder to customize interaction distance, framework selection, subtitle styling, voice settings, and gateway thresholds.

```lua
Config = {
    Debug = false,
    ServerLore = '',
    Framework = 'qbcore',
    Inventory = 'qb-inventory',
    Target = 'qb-target',
    -- ...
}
```

---

## Core Settings

| Option | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `Debug` | `boolean` | `false` | Enables verbose console logging for session lifecycle and tool executions. |
| `ServerLore` | `string` | `''` | Server-specific background information included in NPC system prompts. Keep under 1000 characters for optimal response latency. |
| `Framework` | `string` | `'qbcore'` | Select `'qbcore'`, `'qbox'`, `'esx'`, `'fw-core'`, `'auto'`, or read-only `'standalone'`. Selection does not establish live qualification. |
| `Inventory` | `string` | `'qb-inventory'` | Select `'qb-inventory'`, `'ox_inventory'`, `'esx-native'`, `'fw-inventory'`, `'custom'`, or `'auto'`. Consult the compatibility matrix and commerce guide for the exact combination and API requirements. |
| `Target` | `string` | `'qb-target'` | Select `ox_target`, `qb-target`, native, or explicit authored-only `fw-ui`. Auto selects ox/qb global targeting, then native controls. |

### Commerce, medical, dispatch and police

`Config.Commerce.integrations` is an empty-by-default allowlist of server resources permitted to register custom settlement drivers. Built-in drivers need no registration. All purchases and sales require an explicit server-issued quote confirmation, including when the legacy `requireConfirmationForPurchases` option is changed.

`Config.Medical` enables the configured supply policy: bandage, $50 each, maximum two, 300-second per-character cooldown. The model proposes a quote and cannot grant supplies or heal directly. Treatment guides the player to the configured `qb-ambulancejob` reception; the installed hospital owns payment and care. The authored doctor stays disabled until its voice is approved.

`Config.Dispatch` requires an explicitly allowlisted service handler. Its defaults are a 120-second character cooldown and a five-second global cooldown, persisted across resource restarts. Reports contain the authoritative position/bucket and bounded unverified narrative; no raw framework event fallback is assumed.

`Config.Police.enabled` and `Config.Police.records.enabled` both default to false. Enable only for the intended acceptance scenario. Traffic conversations require verified duty and a stationary driver; the installed police system owns arrests, searches, fines and evidence. Self-service records require a separately scoped backend and stay private to the interacting player. `Config.Missions.integrations` similarly allowlists the trusted server resource that verifies mission objectives before completion and payout.

---

## Gateway Connection (`Config.Gateway`)

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `url` | `string|nil` | `nil` | Set the assigned client-reachable HTTPS endpoint using `peak_ai_npc_gateway_url`. Loopback is for explicit local development only. |
| `secretConvar` | `string` | `'peak_ai_npc_gateway_secret'` | Convar name for the shared gateway secret. Must match `AI_NPC_GATEWAY_SECRET` in your gateway `.env`. |
| `timeoutMs` | `number` | `32000` | FXServer turn timeout in milliseconds. Keep it above the gateway request deadline so a terminal retry state always reaches the player. |
| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `interactionDistance` | `number` | `3.0` | Maximum distance (meters) between player and ped to initiate conversation. |
| `sceneObservationRefreshMs` | `number` | `1500` | Lightweight active-session native snapshot cadence. Full nearby-ped/vehicle scans occur only when a turn begins. |
| `maximumDistance` | `number` | `8.0` | Maximum distance before an active conversation automatically terminates. |
| `autoApproachDistance` | `number` | `3.5` | Distance at which an idle ambient conversation partner starts closing the gap. |
| `maxTurns` | `number` | `100` | Maximum conversation turns per active session before requiring a rest or reset. |
| `idleTimeoutSeconds` | `number` | `600` | Inactivity timeout in seconds before closing an active NPC session. |
| `exclusiveByDefault` | `boolean` | `true` | If true, an NPC can only engage with one player at a time. |
| `maxRequestsPerMinute` | `number` | `12` | Rate limit threshold per player to prevent dialogue spam. |

---

## NPC-Initiated Conversations (`Config.Proactive`)

Proactive dialogue is enabled by default but deliberately sparse. A low-frequency client scan considers only a nearby, visible, facing, slow-moving human ped while both sides are on foot, alive, unarmed, and out of combat. The client chance controls natural variation; the server independently enforces per-player and per-NPC cooldowns before it spends a model turn. The internal presence event is labeled as NPC-initiated and is never stored as player-authored dialogue or memory.

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `enabled` | `boolean` | `true` | Allows eligible NPCs to initiate a brief grounded line. |
| `includeAmbient` | `boolean` | `true` | Includes eligible population peds as well as configured NPCs. |
| `scanMs` | `number` | `2500` | Client eligibility scan interval; no model or screenshot work runs in this loop. |
| `activationDistance` | `number` | `2.6` | Maximum proximity for an NPC-initiated start. |
| `chancePercent` | `number` | `18` | Chance on a new eligible proximity entry. |
| `playerCooldownSeconds` | `number` | `90` | Minimum time between proactive starts for one player, enforced client- and server-side. |
| `npcCooldownSeconds` | `number` | `180` | Minimum time before the same NPC can proactively start again, enforced client- and server-side. |

---

## Ambient Ped Conversations (`Config.Ambient`)

Ambient conversations are enabled by default for eligible networked and client-local non-player peds. Networked peds are resolved server-side; local population peds enter through a bounded descriptor. Scene observations remain untrusted. Ambient peds receive only reversible social actions by default and never gain economy, inventory, mission, service, permission, or reward tools.

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `enabled` | `boolean` | `true` | Enables dialogue with ambient peds through `/ainpc`, `ox_target`, and `qb-target`. |
| `interactionDistance` | `number` | `3.0` | Maximum distance to begin an ambient conversation. |
| `ignoredModels` | `table` | `{}` | Ped model names or hashes that must never be conversational. |
| `personality` | `string` | local-resident prompt | Default ambient-ped behavior. |
| `knowledge` | `string` | location/public-context prompt | Default ambient-ped knowledge boundary. |
| `archetypes` | `table` | bundled civilian/tech/unhoused/gang/shopkeeper profiles | Explicitly authored occupation, personality, speaking tone and delivery preset; never a provider voice ID. |
| `modelArchetypes` | `table` | bundled explicit model mappings | Maps a ped model hash/name to an authored archetype. Review each advertised foundation; a model name is not evidence of personality or criminality. |
| `modelAgeBands` | `table` | bundled mapped-model ages | Maps ped models to authored age bands. Without a mapping, recognized model-name age tokens supply unreviewed hints; otherwise the fallback is adult. Neither path establishes reviewed casting or support. |
| `zoneArchetypes` | `table` | `{}` | Maps a GTA zone code to a fallback archetype when no model mapping is supplied. |
| `names` | `table` | bundled name pool | Deterministic lifecycle names revealed when identity enters the conversation. |
| `memory` | `boolean` | `true` | Enables memory for the ped's server-assigned lifecycle identity. |
| `allowedTools` | `table` | react/follow/stop/crouch/move/look/walk | Bounded reversible social actions available to ambient peds. Do not add durable gameplay tools. |
| `maximumRoamDistance` | `number` | `100.0` | Maximum bounded distance a local ambient conversation can move from its starting point. |
| `maximumObservedStep` | `number` | `12.0` | Maximum accepted observed NPC movement between validated scene updates. |

With `Config.Residents.enabled`, an accepted ambient conversation promotes the pedestrian to a durable resident. The HUD initially says `Local resident`, then permanently switches to the resident's name for that character after it is revealed.

Voice selection uses provider-neutral `Config.VoiceProfiles` keys and `shared/voice_casting.lua`. The operator's private registry maps those keys to approved provider voices. A saved resident keeps its assigned profile/version across restarts and casting changes; concurrent conversations must never silently recast it. Text/subtitles remain available when speech cannot use the assigned profile. Only use profile keys approved by the operator:

```lua
Config.VoiceProfiles.ambientPools.civilian.male.any = {
    'ambient.civilian.male.01', 'ambient.civilian.male.02'
}
-- This changes selection for new assignments, not already saved residents.
```

Role and speaking style are authored gameplay choices. Do not infer nationality, accent, criminality or personality from appearance or model names. Provider-specific performance directions remain inside the gateway speech adapter and are stripped from displayed/spoken text where unsupported.

## Contextual Behavior (`Config.Behavior`)

Shared NPC movement and reactions are selected on the server from the authored archetype, persistent activity/mood, `qb-weathersync` game time and weather, nearby players/vehicles/allies, and recent player treatment. The server publishes a small revisioned `ainpc:behavior` directive; only the client that controls the entity applies its allowlisted scenario, wander, face, retreat, flee, or surrender task.

Priority is deterministic: store robbery and explicit validated actions cannot be overwritten by social or routine behavior. Generic dialogue/scene behavior never selects combat, grants weapons, changes inventory, or awards money.

| Key | Default | Description |
| :--- | :--- | :--- |
| `tickMs` | `5000` | Server behavior reconciliation interval. |
| `surroundingsRadius` | `30.0` | Radius used for nearby player, traffic, managed-NPC, and ally context. |
| `crowdedPlayerCount` | `4` | Nearby-player count that activates an archetype's crowded response. |
| `environmentCacheMs` | `1000` | Cache interval for authoritative game clock/weather. |
| `treatmentDurationMs` | `6000` | Duration of a respectful, insulting, apologetic, polite, or threatening social reaction. |
| `profiles` | bundled five archetypes | Allowlisted role/activity/weather/time/crowding/treatment directives. |

When `qb-weathersync` is unavailable, the server uses its UTC clock and `fallbackWeather`; it does not ask each client to make a different decision for a shared ped.

## Shopkeeper Robbery (`Config.ShopRobbery`)

Managed shop NPCs and the explicitly allowlisted convenience/liquor clerks from this server's `qb-shops` resource react after a player holds a firearm aim on them for `triggerHoldMs`. `qb-storerobbery` owns the weighted `surrender`, `flee`, and `defend` roll, police requirement, store cooldown, register state, source-bound completion token, and one-time reward. Peak AI NPC only detects the aimed clerk and renders the server-approved reaction.

```lua
shop = { id = '247supermarket', robbery = { enabled = true } }
```

The direct bridge requires `qb-core`, `qb-inventory`, `qb-shops`, and `qb-storerobbery` to start before `peak-ai-npc` (the included server profile already starts `[qb]` first). Configure eligible local clerks in `qb-shops/config.lua::Config.RobbableShops` and their canonical coordinates/register mapping and response weights in `qb-storerobbery/config.lua::Config.ClerkRobberies`.

Rewards never travel through the legacy register reward events. `peak-ai-npc` calls server-only `StartClerkRobbery`, `CompleteClerkRobbery`, and `CancelClerkRobbery` exports; `qb-storerobbery` rechecks the selected owned firearm, canonical distance, police count, routing bucket, elapsed search time, token owner, cooldown, and register state. The audited `Config.ShopRobbery.event` still fires after a validated start for non-economic logging extensions.

The maintained profile maps 19 clerks: Martin Hale is the single Peak-owned clerk at the first 24/7, while 18 convenience/liquor clerks remain local `qb-shops` peds. Defensive clerks temporarily become vulnerable, can draw the configured firearm, and are safely respawned into their original shop scenario. Reaction IDs prevent an older reset timer from replacing a newer reaction.

---

## Persistent Residents (`Config.Residents`)

| Key | Default | Description |
| :--- | :--- | :--- |
| `enabled` | `true` | Enables persistent ambient promotion and OneSync resident management. |
| `maximumProfiles` | `500` | Durable registry target. The gateway enforces the profile cap. |
| `maximumActive` | `80` | Maximum managed resident peds server-wide. |
| `maximumActivePerBucket` | `24` | Maximum managed resident peds in one routing bucket. |
| `spawnDistance` | `140.0` | Spawn a resident when a player in its bucket is this close. |
| `despawnDistance` | `200.0` | Begin idle despawn eligibility beyond this distance. |
| `despawnGraceSeconds` | `60` | Time without a nearby player before despawning. |
| `refreshSeconds` | `60` | Deterministic background simulation cadence. |
| `recoverySeconds` | `1800` | Intended real-time death recovery window. |

---

## Security & Audit (`Config.Security`)

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `requireConfirmationForPurchases` | `boolean` | `true` | Requires explicit NUI player confirmation before executing monetary purchase quotes. |
| `maximumTransactionValue` | `number` | `5000` | Hard maximum total cash value per transaction. Over-limit quotes are rejected; no model/admin bypass is implied. |
| `auditWriteTools` | `boolean` | `true` | Emits structured audit events to server logs when state-modifying tools complete. |

---

## Persistent Memory (`Config.Memory`)

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `enabled` | `boolean` | `true` | Toggles NPC long-term memory retrieval and extraction. |
| `minimumImportance` | `number` | `0.65` | Minimum importance score required for a captured memory to be retained. |
| `retentionDays` | `number` | `90` | Compatibility default; structured extraction uses permanent, 365-day, 90-day, and 30-day classes. |

---

## Voice Input (`Config.VoiceInput`)

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `enabled` | `boolean` | `true` | Enables push-to-talk microphone dictation and Speech-to-Text (STT) processing. |
| `language` | `string|nil` | `nil` | Optional BCP-47 language code hint (e.g., `'en'`, `'fr'`, `'es'`). |
| `maximumDataUrlBytes` | `number` | `8000000` | Upper limit on recorded audio payload size. |

The resource registers remappable `+ainpcvoice` / `-ainpcvoice` commands under the **NPC Voice** key mapping, default `G`. Hold the key to capture and release to submit. A generation token prevents delayed microphone permission from starting a recording after release. Pressing the key while an NPC is speaking performs utterance-specific barge-in for the interacting player and nearby listeners. `E` and typed input remain available.

The NUI monitors microphone energy, confirms when it can hear the player, and stops after roughly one second of post-speech silence. If it reports no microphone signal, check the FiveM/Windows input device and CEF microphone permission before changing STT provider settings. Audio uses a three-speaker WebAudio mix with distance, stereo pan, range, and line-of-sight occlusion updated while playback is active.

---

## 3D Subtitles (`Config.Subtitles`)

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `enabled` | `boolean` | `true` | Enables diegetic 3D world space text rendering above speaking peds. |
| `mode` | `string` | `'always'` | Rendering mode: `'always'`, `'never'`, `'player_preference'`, `'audio_failed'`, `'accessibility'`. |
| `audience` | `string` | `'nearby'` | Audience scope: `'nearby'` (all players in distance) or `'interacting'` (active player only). |
| `maximumDistance` | `number` | `22.0` | Maximum distance (meters) at which 3D subtitles remain visible. |
| `requireLineOfSight` | `boolean` | `true` | Hides subtitles when occluded by walls or static objects. |
| `charactersPerLine` | `number` | `42` | Line length threshold for text wrapping. |
| `maximumLines` | `number` | `4` | Maximum lines shown simultaneously in subtitle bubble. |
| `accentColor` | `table` | `{ 184, 255, 101 }` | RGB accent color (`#B8FF65` brand accent). |

---

## Vision Analysis (`Config.Vision`)

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `enabled` | `boolean` | convar off | Reads replicated convar `peak_ai_npc_vision_enabled`; set it to `1` only after a provider and player disclosure are configured. |
| `automaticTurnContext` | `boolean` | `true` | When vision is enabled and ready, captures bounded context on the first turn, after the refresh interval, and for urgent scenes. Native context remains the fallback. |
| `refreshSeconds` | `number` | `15` | Minimum reuse window for non-urgent screenshot context. |
| `captureTimeoutMs` | `number` | `12000` | Maximum time a conversation waits for capture/analysis before continuing with native context. |
| `screenshotBasicResource` | `string` | `'screenshot-basic'` | FiveM screenshot resource dependency name. |
| `quality` | `number` | `0.65` | JPEG compression quality ratio (0.1 to 1.0). |

Vision capture is deliberately silent in the player HUD: no per-capture toast,
status message, or screenshot-specific failure is shown. This is not a consent
mechanism. Operators must disclose screenshot processing before enabling the
server-level opt-in and document the applicable provider and retention policy.

---

## FXServer Convars

Add the following convars to your `server.cfg` before `ensure peak-ai-npc`:

```cfg
set peak_ai_npc_gateway_url "http://127.0.0.1:8787"
set peak_ai_npc_gateway_secret "your-AI_NPC_GATEWAY_SECRET-value"
# Optional: enable NPC vision (requires screenshot-basic and a vision provider)
setr peak_ai_npc_vision_enabled 0
ensure screenshot-basic
ensure peak-ai-npc
```

`peak_ai_npc_gateway_secret` must match `AI_NPC_GATEWAY_SECRET` in your gateway `.env`. Keep it server-side and never place it in a client script, shared script, NUI file, or public repository.

The replicated vision opt-in is privacy-sensitive: keep it `0` unless the gateway health reports a configured vision provider and players have received clear server-level disclosure. Start `screenshot-basic` before `peak-ai-npc`; a missing dependency degrades to native scene context without blocking dialogue.
