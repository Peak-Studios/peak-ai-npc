# Compatibility matrix

“Code” means an adapter and fail-closed path exist. “Verified” means the named runtime has actually been exercised on the current release artifact.

| Area | Code | Current evidence |
|---|---:|---|
| FiveM Lua 5.4 resource | Yes | Current 38-file Lua syntax and full release gate pass; licensed local startup passes; connected resource acceptance remains |
| OneSync server NPC + local fallback | Yes | Current executable lifecycle tests pass; historical startup is not current rendering, migration, or restart acceptance |
| Gateway catalog NPC synchronization | Yes | Validated server-to-client definition sync and hot-registration reconciliation; live target/render acceptance remains |
| QBCore | Yes | Maintained source APIs inspected; current character/money/permission regressions pass; live identity/economy scenarios remain |
| `qb-inventory` | Yes | Exact-cash/slot/rollback and failure regressions pass; live capacity/add/query/rollback evidence remains |
| `qb-target` | Yes | Actual API inspected and lifecycle regression passes; live target selection/removal evidence remains |
| Qbox / ESX | Yes | Documented money and inventory API contracts exercised in production Lua; separate live fixture required; old nil-returning ESX forks unqualified |
| `ox_inventory` / `ox_target` | Yes | Exact slot/metadata settlement and target lifecycle regressions pass; separate live fixture required |
| Peak FW / `fw-inventory` | Opt-in | Local strict-capacity API and resource driver tests pass; requires `fw_inventory_ai_commerce=1` and matching Peak patch; not deployed or live-qualified |
| Custom commerce driver | Opt-in | Explicit resource allowlist, character identity, lifecycle, strict acknowledgements and independent exact-delta checks; operator must qualify its implementation |
| Native keybind | Yes | Remappable `+ainpcvoice`/`-ainpcvoice` default `G`; live client acceptance required |
| Mock provider | Yes | Build, contract, and HTTP/load smoke pass |
| OpenAI-compatible text / Ollama | Yes | Groq live preflight plus mocked contracts; each advertised model needs its own tool/latency check |
| Native Anthropic | Yes | Current request contract covered; live credential/model check required |
| Native Gemini | Yes | Current request contract covered; live credential/model check required |
| OpenAI-compatible/Groq TTS | Yes | Contract/audio delivery covered; Orpheus terms and live NUI playback remain |
| Native Cartesia TTS | Yes | Auth/request contract covered; configured voice listening test required |
| Native ElevenLabs TTS | Yes | Catalog/readiness and request/storage/delivery regressions pass; 27 existing profiles map to 21 premade voices; owner listening approval and customer-controls rc5 startup synthesis plus bounded host-side duration/cost samples pass; in-game language/model/latency matrix remains |
| OpenAI-compatible/Groq STT | Yes | Groq Whisper live transcription observed; FiveM mic and language matrix remain |
| Voice-first NUI and 3D subtitles | Yes | Executable permission/lifecycle/spatial mixer tests and static checks pass; live ped tracking, microphone, barge-in timing, and two-client audio remain |
| Vision direct upload | Yes | Session-bound one-time HTTP flow passes; live `screenshot-basic`/HTTPS/provider test remains |
| File memory | Yes | Concurrency, relationship, expiry, and deletion tests pass |
| PostgreSQL memory | Yes | Disposable persistence/isolation/concurrency/migration smoke passed; production is healthy and initial matched backup/off-host restore passed; deployed retention qualification remains |

## Verification

Test your framework, inventory, target, and provider combination in a staging environment before public launch to ensure optimal latency and interaction quality.
