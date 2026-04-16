Config = {}

Config.Locale = 'de'
Config.DueDays = 14
Config.CacheTtlSeconds = 60
Config.DefaultPageSize = 25
Config.MaxPageSize = 100
Config.DefaultRecentTransactionsLimit = 20

Config.AllowedJobs = {
    doj = true,
    government = true,
    taxoffice = true,
    clerk = true
}

Config.AllowedGroups = {
    admin = true,
    superadmin = true
}

Config.Commands = {
    finance = 'finance',
    taxoffice = 'taxoffice',
    report = 'finance_report',
    debugRefresh = 'finance_debug_refresh'
}

Config.Statuses = {
    'neu',
    'in_pruefung',
    'nachpruefung',
    'auffaellig',
    'mahnfall',
    'abgeschlossen'
}

Config.RecordTypes = {
    taxes = 'taxes',
    taxes_business = 'taxes_business',
    business = 'vms_business',
    transaction = 'okokbanking_transactions'
}

Config.SourceOfTruth = {
    taxes = 'taxes',
    taxesBusiness = 'taxes_business',
    business = 'vms_business',
    societies = 'okokbanking_societies',
    transactions = 'okokbanking_transactions'
}

Config.Resolver = {
    userAdapter = nil, -- Funktion(identifier) -> table|nil (optional)
    preferOnlinePlayerName = true
}

Config.RiskRules = {
    highDelayedAmount = 10000,
    repeatedOpenPeriods = 3,
    highEarnedOpenTaxRatio = 0.05,
    lowBalanceOpenTaxThreshold = 1000,
    zeroTaxPeriodsThreshold = 3
}
