fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'Peak Studios'
description 'Server-authoritative conversational NPC engine'
version '0.4.0'

dependencies { '/onesync' }

ui_page 'web/index.html'

shared_scripts {
    'shared/config.lua',
    'shared/ped_catalog.lua',
    'shared/voice_casting.lua',
    'shared/constants.lua',
    'shared/diagnostics.lua',
    'locales/en.lua',
    'npcs/examples.lua'
}

client_scripts {
    'client/ped_catalog.lua',
    'client/nui.lua',
    'client/entity_manager.lua',
    'client/subtitles.lua',
    'client/vision.lua',
    'client/actions.lua',
    'client/behavior.lua',
    'client/shop_robbery.lua',
    'client/residents.lua',
    'client/main.lua',
    'client/police.lua',
    'client/targets.lua'
}

server_scripts {
    'server/adapters.lua',
    'server/commerce_drivers.lua',
    'server/economy.lua',
    'server/commerce.lua',
    'server/medical.lua',
    'server/records.lua',
    'server/tools.lua',
    'server/session.lua',
    'server/environment.lua',
    'server/behavior.lua',
    'server/ambient.lua',
    'server/missions.lua',
    'server/context.lua',
    'server/entities.lua',
    'server/residents.lua',
    'server/police.lua',
    'server/shop.lua',
    'server/main.lua'
}

files {
    'web/index.html',
    'web/app.js',
    'web/shop.js',
    'web/nui-transparent.css'
}

escrow_ignore {
    'shared/config.lua',
    'shared/voice_casting.lua',
    'shared/constants.lua',
    'npcs/examples.lua',
    'client/targets.lua',
    'locales/*.lua'
}
