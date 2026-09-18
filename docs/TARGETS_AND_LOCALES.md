# Peak AI NPC — Targets & Locales Guide

This guide details how to customize target interactions (`client/targets.lua`) and add localizations (`locales/*.lua`).

> [!NOTE]
> `client/targets.lua` and `locales/*.lua` are fully open-source and can be customized freely.

---

## Target Integration (`client/targets.lua`)

`client/targets.lua` handles registering interactive target options on spawned peds for target frameworks like `ox_target` and `qb-target`, as well as native interaction fallbacks.

### Automatic Target Detection

The shipped default is `Config.Target = 'qb-target'`. When you explicitly select `'auto'`:
- If `ox_target` is running, options are attached using `exports.ox_target:addLocalEntity`.
- If `qb-target` is running, options are attached using `exports['qb-target']:AddTargetEntity`.
- If no target system is running, the native keybind/E-prompt mode is used automatically.

Global ped/vehicle options support eligible ambient residents and stopped drivers when the selected backend provides them. Explicit `fw-ui` handles authored entities only and leaves ambient/driver interaction to native controls; it is never selected automatically ahead of a global-capable backend. Target registration and teardown are owned by this resource without transferring ownership of the original ped.

### Customizing Interaction Options

You can edit `AINPCTargets.register(id, ped)` in `client/targets.lua` to change the icon, distance, or label format:

```lua
-- Customizing target options in client/targets.lua
function AINPCTargets.register(id, ped)
    -- ...
    local label = (AINPCDefinitions[id].identity and AINPCDefinitions[id].identity.name or id)
    if resource == 'ox_target' then
        exports.ox_target:addLocalEntity(ped, {
            {
                name = 'peak_ai_npc_' .. id,
                icon = 'fa-solid fa-comments',
                label = 'Talk to ' .. label,
                distance = AINPCDefinitions[id].interactionDistance or 3.0,
                onSelect = function(data)
                    AINPCStartConversation(id, data and data.entity or ped)
                end
            }
        })
    end
end
```

---

## Localization (`locales/*.lua`)

Language definitions live in `locales/`.

### Default English Locale (`locales/en.lua`)

```lua
AINPCLocale = {
    thinking = 'Thinking...',
    speaking = 'Speaking...',
    gatewayUnavailable = 'The AI service is unavailable right now.',
    screenshotUnavailable = 'Vision capture is unavailable on this client.'
}
```

### Adding New Languages

To add a new language (e.g., French in `locales/fr.lua`):

1. Create `locales/fr.lua`:

```lua
AINPCLocale = {
    thinking = 'En réflexion...',
    speaking = 'Parle...',
    gatewayUnavailable = 'Le service IA est indisponible pour le moment.',
    screenshotUnavailable = 'La capture visuelle n\'est pas disponible.'
}
```

2. Add the locale file to `shared_scripts` in `fxmanifest.lua`:

```lua
shared_scripts {
    'shared/config.lua',
    'shared/ped_catalog.lua',
    'shared/voice_casting.lua',
    'shared/constants.lua',
    'shared/diagnostics.lua',
    'locales/fr.lua',
    'npcs/examples.lua'
}
```
