fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'doj_finance_suite'
author 'Codex'
description 'DOJ Finanzamt-/Controlling-Backoffice für ESX auf Basis bestehender Steuer- und Banking-Tabellen'
version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
    'shared/utils.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/db.lua',
    'server/analytics.lua',
    'server/reviews.lua',
    'server/reports.lua',
    'server/main.lua'
}

client_scripts {
    'client/main.lua'
}

dependencies {
    'es_extended',
    'ox_lib',
    'oxmysql'
}
