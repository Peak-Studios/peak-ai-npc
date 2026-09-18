# Peak AI NPC Integration Guide

The resource exposes server exports for integrations and a client export for custom interaction systems.

## Stock-ped reference and build discovery

`shared/ped_catalog.lua` contains a pinned 860-model [official Cfx reference](https://docs.fivem.net/docs/game-references/ped-models/), source revision and SHA-256, target build 3095, and an explicit incomplete-coverage flag. Its 34 animal-category entries are nonhuman; the remaining 826 require review. This dated reference does not enumerate every later DLC model. Regenerate it with `node scripts/build-ped-catalog.mjs` from the gateway directory; changing the pinned source requires reviewing the resulting catalog diff.

On an authorized connected client, run `ainpc_ped_catalog 1` through `ainpc_ped_catalog 18` in F8. Each command prints one bounded JSON report with actual game build, availability, classification, and official image links for at most 50 models. The probe checks `IsModelInCdimage`, `IsModelValid`, and `IsModelAPed`; it never creates, streams, modifies, or uploads a ped. Save the local log as tester evidence against the exact resource hash. A passing native check establishes availability only. Visual variations, human classification, authored foundation, voice approval and newer-build completeness still require review. Native failure emits no successful report and releases the command lock.

Model names no longer automatically assign technology or shop occupations. Explicit customer role mappings remain available; filename age/presentation hints are marked unreviewed by the casting parser. Catalog import is diagnostic and does not rewrite resident identity or voice assignments.

## Client interaction export

```lua
exports['peak-ai-npc']:startConversation('shopkeeper', entity)
```

`entity` is optional and is used only by the client presentation layer. The server never trusts the supplied entity handle: it selects its own OneSync entity when it is in the player's routing bucket, otherwise it validates distance against the server-authored NPC coordinates. The export returns `false` when the player already has an active conversation or the NPC ID is unknown.

```lua
exports['peak-ai-npc']:registerNpc('custom_contact', {
    id = 'custom_contact',
    model = 'a_m_m_business_01',
    coords = vec4(215.0, -810.0, 30.7, 90.0),
    identity = { name = 'Avery', occupation = 'dispatcher' },
    personality = 'Calm and precise.',
    knowledge = 'Only use configured context and tool results.',
    allowedTools = { 'custom_dispatch' }
})
```

Registered NPC definitions are validated, synchronized to connected clients, spawned or reconciled immediately, and removed when the owning integration resource stops. Built-in or catalog NPC IDs cannot be replaced by another resource.

Mission resources must verify their own objective server-side, be listed in `Config.Missions.integrations`, and then complete the mission through the trusted export:

```lua
local ok, result = exports['peak-ai-npc']:completeMission(source, 'delivery_intro')
if not ok then
    -- Do not grant a separate reward when the AI NPC engine rejects completion.
end
```

The AI model has no `complete_mission` tool. It can offer and accept a mission, but only the host gameplay resource can verify completion and trigger the framework reward adapter.

Register tools with a fixed validator and executor. Do not expose raw framework events, exports, SQL, or model-generated code:

```lua
exports['peak-ai-npc']:registerTool('custom_dispatch', {
    risk = 'write',
    description = 'Dispatch one of the server-approved service names.',
    parameters = {
        type = 'object',
        properties = {
            service = { type = 'string', minLength = 1, maxLength = 32 }
        },
        required = { 'service' },
        additionalProperties = false
    },
    validate = function(source, session, args)
        if type(args.service) ~= 'string' then return false, 'invalid_service' end
        if #args.service > 32 then return false, 'service_too_long' end
        return true
    end,
    execute = function(source, session, args)
        -- Re-check permissions and state here, then call your own fixed handler.
        TriggerEvent('my_resource:server:dispatch', source, args.service)
        return { ok = true, service = args.service }
    end
})
```

`description` and `parameters` are required for a custom tool to be visible to a model. The gateway accepts a strict, flat JSON Schema subset: object parameters with at most 24 string, number, integer, or boolean properties; optional bounds/enums; an explicit required list; and `additionalProperties = false`. The server validator and executor remain mandatory and authoritative even after gateway schema validation.

Tool, context, service, and custom-inventory registrations are owned by the invoking server resource. A different resource cannot replace an existing registration, and registrations are removed when their owner stops.

Register server-authoritative context providers for facts owned by another resource:

```lua
exports['peak-ai-npc']:registerContextProvider('my_resource', function(source, session)
    return {
        activeCaseId = exports['my_resource']:getCaseForPlayer(source),
        npcZone = session.npc.id == 'police_contact' and 'station' or 'public'
    }
end)
```

For `npc_call_service`, `npc_call_police`, and `npc_call_ems`, explicitly allow the integration resource in `Config.Dispatch.integrations` before it registers a server handler. The callback contract is `(source, report)`; legacy session/service callbacks must migrate. `report` contains the server-observed location and routing bucket, service, session correlation and an explicitly unverified narrative. It contains no private player record. Return `{ ok = true, accepted = true }` only after the installed dispatch system acknowledges acceptance; nil, exceptions and stopped adapters fail closed. Acceptance means accepted by dispatch, not emergency personnel arrival.

The adapter must use its installed system's verified API, restrict recipients to authorized on-duty personnel in the report's bucket/tenant, treat narrative as untrusted text, and never use it to mutate justice records, evidence or permissions. There is no implicit chat/client-event fallback. `services = { 'police', 'ems' }` bounds the generic tool on each NPC; dedicated tools also require the NPC tool allowlist. Unsupported integrations remain unavailable until configured and verified.

`Config.Dispatch.cooldownSeconds` (120 by default) applies to a character across sessions and NPCs; `globalCooldownSeconds` (5) limits server-wide bursts. Both reservations persist in resource KVP before delivery and survive failed/unknown outcomes. Do not erase these reservations to retry an ambiguous report. Provider integration acceptance and connected recipient duty/privacy tests remain required.

## Custom inventory adapter

Set `Config.Inventory = 'custom'`, then register the three server-authoritative functions below from the inventory integration resource. The core still validates money, quote state, stock, distance, and idempotency; the adapter is responsible only for its own inventory state.

```lua
exports['peak-ai-npc']:registerInventoryAdapter({
    canCarry = function(source, item, quantity)
        return exports.my_inventory:CanCarryItem(source, item, quantity) == true
    end,
    addItem = function(source, item, quantity, reason)
        return exports.my_inventory:AddItem(source, item, quantity, reason) == true
    end,
    getItemCount = function(source, item)
        return tonumber(exports.my_inventory:GetItemCount(source, item)) or 0
    end
})
```

The registration rejects incomplete adapters and fails closed when `Config.Inventory = 'custom'` without a registered adapter.

Provider names are validated and each result is size-limited before it enters the gateway prompt. Never return secrets, raw credentials, or unrestricted database rows.

NPC access can be restricted before a conversation session is created:

```lua
interactionPolicy = {
    ace = 'ainpc.police',
    jobs = { police = 0, sheriff = 1 },
    gangs = { ballas = 2 }
}
```

ACE, job, and gang checks are server-side. A missing or insufficient job/gang grade rejects the session and does not reserve the NPC.

## Adapter rules

- Treat every client payload as untrusted.
- Keep persistent state on the server.
- Re-check distance, routing bucket, permissions, inventory, funds, and mission state inside the tool handler.
- Make economy writes idempotent where the underlying framework allows it.
- Return a structured result; the model may speak only after receiving that result.
- Keep custom integration files outside protected core code.

## Gateway contract

The resource sends authenticated `POST /v1/turn` requests to the gateway. The gateway returns either `{ text }` or one allowlisted `{ toolCall }`. After the server executes a tool, it sends `{ toolResult }` back through the same endpoint for a final response.

`ainpc_status` reports the detected framework, inventory, target, OneSync mode, screenshot dependency state, configured/active NPC counts, gateway health, and the last redacted gateway error.

The stable boundary is intentionally small so provider, memory, speech, and dashboard implementations can evolve without changing gameplay adapters.

### Framework read boundary verification (September 10)

FW uses the locally inspected `fw-core:GetCoreObject().Functions.GetPlayer(source)` API; QBCore uses the same documented object shape. Qbox uses its [GetPlayer server export](https://docs.qbox.re/resources/qbx_core/exports/server). ESX obtains `getSharedObject()` and calls [ESX.GetPlayerFromId](https://docs.esx-framework.org/en/esx_core/es_extended/server/functions). Every lookup checks resource state and catches missing/throwing exports. Public context contains display name and a minimal job name/label/duty projection; phone, bank, health, licenses, gang, biometrics and arbitrary job metadata are excluded. Character identity has no source/license fallback. These are deterministic read-boundary checks, not live integration qualification.

Auto target selection uses global-capable ox_target/qb-target or native controls. Explicit fw-ui remains available for authored entities; ambient/vehicle targeting uses native controls when selected. The inspected FW AddEyeEntry accepts Type=Entity and an existing Entity handle; omitting EntityType=ped avoids giving FW UI lifecycle ownership of that NPC.

### Private self-service records

The authored police desk has a separate, default-off `Config.Police.records` policy. Both police and records switches must be enabled, the NPC must explicitly declare `policeRecords=true`, and the original server-managed entity must be within three metres. The lookup receives no target citizen ID or SQL from the model. Identification returns only the subject's display name and explicitly does not verify a document. Warrant status returns only a self-scoped boolean/count, with unknown/unavailable results reported as unavailable.

FW integration uses the new bounded `fw-mdw:GetAINPCSelfWarrantStatus(source)` export in `server/modules/sv_ai_self_records.lua`, loaded by the existing modules glob. The other required local Peak boundary is the opt-in strict inventory API described in `COMMERCE_VERIFICATION.md`. Its independent `fw_mdw_ai_self_records` convar defaults to 0, and only the `peak-ai-npc` invoking resource is allowed. It rejects nonzero routing buckets and any `PlayerData.peak_world_id`, since the inspected MDW schema has no world column. Multi-world FW, QBCore, Qbox and ESX records therefore remain unavailable until a correspondingly scoped backend is implemented and qualified. Do not enable this adapter as a workaround for those restrictions.

A records session remains private for its lifetime: text/audio are sent only to the interacting client, never observers. Character/framework changes invalidate it; late results and cached tool responses recheck authority. Case notes, charges, phone numbers, fingerprints, licenses and other citizens' records never enter the response. Police resources retain all justice/evidence/action authority.

Local verification: `npm run test:commerce` executes the resource boundary. To test the actual Peak module, run `node scripts/test-peak-records.mjs <absolute-path-to-fw-mdw/server/modules/sv_ai_self_records.lua>` from `gateway`. This executes production Lua with injected database outcomes, not a live database.

Tester gate (after authorized staging): keep an observer next to the desk; verify typed and voiced self-status reaches only the subject. Test disabled switches, missing/stopped MDT, no database result, a real zero count, a positive count, repeated requests, source disconnect/character change while a query is pending, bucket changes and a world-bound character. Expect unavailable for unsupported scopes, never a fabricated clean record. Confirm existing officer MDT permissions and records remain unchanged. Voice approval is still required before enabling the authored desk.

### Mission payout recovery

Accepted missions persist by framework character and mission ID, including reconnect/resource restart. The introductory mission is once per character. Only a trusted, explicitly allowed server gameplay resource may call completeMission after verifying its objective; model output cannot complete it. Rewards use the qualified commerce driver's strict credit acknowledgement and a durable operation receipt. An explicit rejected credit may be retried, a successful receipt returns success without another credit, and a throw/nil/adapter loss or uncertain journal write remains fenced for reconciliation. Never delete pending reward KVPs to retry a payout. Mission state is marked complete only after the payout receipt is durable; if saving mission completion fails, retry consumes the existing paid receipt.

The 334-assertion production-Lua gate covers purchases, medical supply policy, dispatch, private records, authorization revocation, inventory query failures, missions, bounded new action envelopes, and Qbox/Ox/ESX/FW/custom settlement driver contracts. The actual local Peak inventory API also passes its separate 32-assertion gate. This verifies deterministic boundaries; the objective-verifying mission resource and real connected framework writes still require acceptance.
