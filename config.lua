Config = {}

Config.Locale = 'de'
Config.DueDays = 14
Config.CacheTtlSeconds = 90
Config.DefaultPageSize = 25
Config.MaxPageSize = 100
Config.MaxAuditRows = 100
Config.DefaultRecentTransactionsLimit = 25

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
    'teilweise_beglichen',
    'wartet_auf_zuordnung',
    'frist_ueberschritten',
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
    userAdapter = nil,
    preferOnlinePlayerName = true
}

Config.BusinessJobMap = {
    pdm = 'PDM',
    cityhall = 'Cityhall'
}

Config.BusinessJobAliases = {
    cardealer = 'pdm',
    vehicleshop = 'pdm'
}

Config.Interaction = {
    useTarget = true,
    npc = {
        enabled = false,
        model = `s_m_m_highsec_01`,
        coords = vec4(441.21, -981.89, 30.69, 184.0)
    },
    point = {
        enabled = true,
        coords = vec3(444.01, -976.15, 30.69),
        radius = 2.0,
        drawMarker = true,
        marker = { type = 1, scale = vec3(0.7, 0.7, 0.25), color = { r = 0, g = 130, b = 255, a = 140 } },
        textUI = '[E] Finanzsoftware öffnen'
    }
}

Config.RiskEngine = {
    windowsDays = { 7, 30, 90 },
    scoreCap = 100,
    thresholds = {
        watch = 25,
        flagged = 50,
        high = 75
    },
    weights = {
        openCases = 8,
        overdueCases = 10,
        delayedAmount = 8,
        lateFees = 6,
        repeatedOpenPeriods = 12,
        partialPayments = 6,
        warningStatuses = 5,
        enoughBalanceNoPay = 12,
        debtBalanceRatio = 10,
        debtEarnedRatio = 8,
        unusualTransactionSpike = 10,
        incomingWithoutTaxSettlement = 8,
        manualReviewQueue = 6,
        zeroTaxPeriods = 5
    },
    rules = {
        delayedAmountHigh = 15000,
        enoughBalanceFactor = 1.1,
        debtBalanceRatioHigh = 1.2,
        debtEarnedRatioHigh = 0.15,
        unusualTxSpikeFactor = 2.4,
        zeroTaxPeriodCount = 3,
        repeatedOpenPeriods = 3,
        highIncomingMin = 25000,
        highIncomingUnpaidFactor = 0.85
    }
}
