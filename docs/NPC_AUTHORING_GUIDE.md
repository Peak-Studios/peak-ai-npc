# Peak AI NPC — NPC Authoring Guide

This guide explains how to define custom AI NPCs, personalities, tool permissions, and spawn points in `npcs/`.

> [!NOTE]
> `npcs/examples.lua` is explicitly listed in `escrow_ignore`. Other files are not automatically loaded or made editable by placing them in `npcs/`.

---

## Defining an NPC

Add NPC definitions to `AINPCDefinitions` in `npcs/examples.lua`. A separate integration resource can register definitions through the documented server export. Adding another Lua file to this resource requires a corresponding manifest entry and a new escrow build.

Configured definitions are for special roles: shops, missions, service staff, and other peds that need explicit tools or policies. Ordinary ambient peds do not need definitions: aim at one and use `/ainpc`. Ambient conversations receive only the reversible social-action allowlist from `Config.Ambient.allowedTools`; durable gameplay tools remain exclusive to configured roles.

### Example NPC Definition

```lua
AINPCDefinitions = AINPCDefinitions or {}

AINPCDefinitions.mechanic_sam = {
    id = 'mechanic_sam',
    enabled = false, -- Enable after this character's voice and scenario are approved.
    model = 'mp_m_waremech_01',
    coords = vec4(1174.8, -3196.6, 6.0, 90.0),
    identity = {
        name = 'Sam',
        occupation = 'Head Mechanic'
    },
    personality = 'Gruff, knowledgeable, price-conscious, and direct. Speaks in short sentences.',
    knowledge = 'Knows only owner-authored repair guidance. Cannot inspect, price, repair, or modify a vehicle without a separately implemented server tool.',
    allowedTools = {
        'npc_react'
    },
    voice = { voiceProfileId = 'mechanic-sam', voiceSeed = 'mechanic_sam', genderPresentation = 'masculine', ageBand = 'adult', language = 'en', qualityMode = 'realtime', deliveryPreset = 'neutral' },
    interactionDistance = 3.0
}
```

---

## Schema Attributes

| Field | Type | Required | Description |
| :--- | :--- | :--- | :--- |
| `id` | `string` | **Yes** | Unique identifier for the NPC. Must match the table key. |
| `model` | `string` | **Yes** | GTA V ped model hash string (e.g., `'mp_m_shopkeep_01'`, `'g_m_y_mexgoon_02'`). |
| `coords` | `vector4` | **Yes** | Spawn position `vec4(x, y, z, heading)`. |
| `identity` | `table` | **Yes** | Contains `name` (`string`) and `occupation` (`string`). |
| `personality` | `string` | **Yes** | Behavioral prompt guidelines directing tone, vocabulary, and demeanor. |
| `knowledge` | `string` | **Yes** | Knowledge boundaries defining what facts the NPC knows or lacks. |
| `allowedTools` | `table` | Optional | Array of registered tool names this NPC is permitted to invoke. |
| `interactionDistance` | `number` | Optional | Proximity radius in meters for interaction (defaults to `Config.Conversations.interactionDistance`). |
| `voice` | `table` | Optional | Provider-neutral profile identity and baseline delivery; provider-native IDs stay in the gateway registry. |

### Voice identity

Inside the `voice` table, configured characters should author `voiceProfileId`, stable `voiceSeed`, `genderPresentation`, `ageBand`, `language`, `qualityMode`, and `deliveryPreset`. `accent` is optional and must be deliberately authored. Martin Hale and Rico use distinct story profile IDs reserved outside ambient pools. The maintained provider mappings use premade Roger and Adam; this is not a claim of custom or globally exclusive ElevenLabs voices. Ambient residents use stable profile assignments; concurrent speakers never cause recasting. Capacity failures retain text/subtitles. The example `mechanic-sam` profile is not in the shipped 27-profile manifest, so the example stays disabled until an operator has prepared and approved it.

Do not paste an ElevenLabs voice ID into this file. The operator registers and approves provider mappings through the private voice-review workflow in [PROVIDERS.md](PROVIDERS.md). Creating missing Voice Design profiles with `npm run voices:provision -- --server <server-id>` is a separate, explicitly authorized paid step; inspect `--dry-run` first. Newly provisioned voices retain audition files and remain unapproved until actually reviewed. Preserve existing mappings unless an explicit recast is staged and approved.

---

## Best Practices for Authoring Prompts

1. **Be Specific About Knowledge**: Explicitly restrict the NPC from inventing unverified facts. For example: *"Never invent stock, prices, or server rules not returned by tools."*
2. **Assign Tool Restrictions**: Only list tool names in `allowedTools` that match the NPC's in-game role (e.g., shopkeeper peds should only have shop catalog/purchase tools).
3. **Set Realistic Vector Headings**: Test headings in-game so peds face counter tables, doorways, or player approach vectors.
