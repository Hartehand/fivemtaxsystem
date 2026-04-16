FinanceAnalytics = {}

local function sumField(rows, field)
    local total = 0
    for _, row in ipairs(rows) do
        total = total + FinanceUtils.safeNumber(row[field])
    end
    return total
end

function FinanceAnalytics.resolveDisplayName(identifier, fallback)
    local name = fallback

    if Config.Resolver.preferOnlinePlayerName and identifier then
        local xPlayer = ESX.GetPlayerFromIdentifier(identifier)
        if xPlayer and xPlayer.getName then
            name = xPlayer.getName()
        end
    end

    if Config.Resolver.userAdapter and type(Config.Resolver.userAdapter) == 'function' then
        local fromAdapter = Config.Resolver.userAdapter(identifier)
        if fromAdapter and fromAdapter.name then
            name = fromAdapter.name
        end
    end

    return name or identifier or 'Unbekannt'
end

local function parseBusinessData(row)
    local payload = FinanceUtils.safeDecode(row.data)
    return {
        id = row.id,
        type = row.type,
        owner = row.owner,
        employees = row.employees,
        balance = FinanceUtils.safeNumber(payload.balance),
        totalEarned = FinanceUtils.safeNumber(payload.totalEarned),
        totalOrders = FinanceUtils.safeNumber(payload.totalOrders),
        totalVehicles = FinanceUtils.safeNumber(payload.totalVehicles),
        totalSales = FinanceUtils.safeNumber(payload.totalSales),
        payload = payload
    }
end

function FinanceAnalytics.getDashboard()
    local cacheKey = 'dashboard:v1'
    local cached = FinanceDB.cache[cacheKey]
    local now = os.time()

    if cached and now < cached.expiresAt then
        return cached.value
    end

    local privateRows = MySQL.query.await([[SELECT amount, is_paid, canceled, received_date FROM taxes]]) or {}
    local businessRows = MySQL.query.await([[SELECT job, amount, paid_amount, delayed_amount, late_fee_applied, is_paid FROM taxes_business]]) or {}
    local businesses = MySQL.query.await([[SELECT id, data FROM vms_business]]) or {}
    local societies = FinanceDB.fetchSocieties()
    local transactions = MySQL.query.await([[SELECT id, receiver_name, sender_name, value, date, type FROM okokbanking_transactions ORDER BY date DESC LIMIT ?]], {
        Config.DefaultRecentTransactionsLimit
    }) or {}

    local private = {
        openCount = 0,
        paidCount = 0,
        canceledCount = 0,
        openAmount = 0,
        paidAmount = 0
    }

    local nowTs = os.time()
    for _, row in ipairs(privateRows) do
        local amount = FinanceUtils.safeNumber(row.amount)
        if FinanceUtils.toBoolean(row.canceled) then
            private.canceledCount = private.canceledCount + 1
        elseif FinanceUtils.toBoolean(row.is_paid) then
            private.paidCount = private.paidCount + 1
            private.paidAmount = private.paidAmount + amount
        else
            private.openCount = private.openCount + 1
            private.openAmount = private.openAmount + amount
        end

        local _, dueTs = FinanceUtils.dateAddDays(row.received_date, Config.DueDays)
        row.isOverdue = dueTs and nowTs > dueTs and (not FinanceUtils.toBoolean(row.is_paid)) and (not FinanceUtils.toBoolean(row.canceled))
    end

    local business = {
        openPeriods = 0,
        openAmount = 0,
        delayedAmount = 0,
        lateFeeAmount = 0,
        recurringDelays = {}
    }

    local companyOpenMap = {}
    for _, row in ipairs(businessRows) do
        local amount = FinanceUtils.safeNumber(row.amount)
        local paidAmount = FinanceUtils.safeNumber(row.paid_amount)
        local delayed = FinanceUtils.safeNumber(row.delayed_amount)
        local lateFee = FinanceUtils.safeNumber(row.late_fee_applied)
        local rest = amount - paidAmount + delayed
        local isOpen = (not FinanceUtils.toBoolean(row.is_paid)) and rest > 0

        if isOpen then
            business.openPeriods = business.openPeriods + 1
            business.openAmount = business.openAmount + rest
            companyOpenMap[row.job] = (companyOpenMap[row.job] or 0) + 1
        end

        business.delayedAmount = business.delayedAmount + delayed
        business.lateFeeAmount = business.lateFeeAmount + lateFee
    end

    local businessProfiles = {}
    for _, row in ipairs(businesses) do
        businessProfiles[#businessProfiles + 1] = parseBusinessData(row)
    end

    local flagged = {}
    for _, profile in ipairs(businessProfiles) do
        local relatedOpen = companyOpenMap[profile.type] or 0
        local reason = nil

        if relatedOpen >= Config.RiskRules.repeatedOpenPeriods then
            reason = 'Mehrfach offene Perioden'
        elseif profile.totalEarned > 0 and relatedOpen > 0 and business.openAmount > (profile.totalEarned * Config.RiskRules.highEarnedOpenTaxRatio) then
            reason = 'Hohe Steuerlast bei hohem Umsatz'
        elseif profile.balance < Config.RiskRules.lowBalanceOpenTaxThreshold and relatedOpen > 0 then
            reason = 'Niedriger Kontostand bei offener Steuerlast'
        end

        if reason then
            flagged[#flagged + 1] = {
                business_id = profile.id,
                business_type = profile.type,
                owner = profile.owner,
                reason = reason,
                balance = profile.balance,
                totalEarned = profile.totalEarned,
                openPeriods = relatedOpen
            }
        end
    end

    local result = {
        private = private,
        business = business,
        companies = {
            total = #businessProfiles,
            withOpenPeriods = 0,
            societiesTotalBalance = sumField(societies, 'value')
        },
        flagged = flagged,
        recentTransactions = transactions
    }

    for _, count in pairs(companyOpenMap) do
        if count > 0 then
            result.companies.withOpenPeriods = result.companies.withOpenPeriods + 1
        end
    end

    FinanceDB.cache[cacheKey] = {
        value = result,
        expiresAt = now + Config.CacheTtlSeconds
    }

    return result
end

function FinanceAnalytics.computePrivateTaxRow(row)
    local dueDate, dueTs = FinanceUtils.dateAddDays(row.received_date, Config.DueDays)
    local isPaid = FinanceUtils.toBoolean(row.is_paid)
    local isCanceled = FinanceUtils.toBoolean(row.canceled)
    local nowTs = os.time()

    local status = 'offen'
    if isCanceled then
        status = 'storniert'
    elseif isPaid then
        status = 'bezahlt'
    elseif dueTs and nowTs > dueTs then
        status = 'ueberfaellig'
    elseif dueTs then
        status = 'faellig'
    end

    return {
        id = row.id,
        receiver = row.receiver,
        receiver_name = FinanceAnalytics.resolveDisplayName(row.receiver, row.receiver_name),
        received_date = row.received_date,
        due_date = dueDate,
        title = row.title,
        amount = FinanceUtils.safeNumber(row.amount),
        is_paid = isPaid,
        paid_date = row.paid_date,
        canceled = isCanceled,
        status = status,
        age_days = FinanceUtils.daysBetween(nowTs, FinanceUtils.parseDate(row.received_date)),
        overdue_days = dueTs and math.max(0, FinanceUtils.daysBetween(nowTs, dueTs)) or 0
    }
end

function FinanceAnalytics.computeBusinessTaxRow(row)
    local amount = FinanceUtils.safeNumber(row.amount)
    local paid = FinanceUtils.safeNumber(row.paid_amount)
    local delayed = FinanceUtils.safeNumber(row.delayed_amount)
    local rest = amount - paid + delayed

    local status = 'offen'
    if FinanceUtils.toBoolean(row.is_paid) or rest <= 0 then
        status = 'bezahlt'
    elseif paid > 0 then
        status = 'teilweise'
    end

    return {
        job = row.job,
        job_label = row.job_label,
        period = row.period,
        amount = amount,
        paid_amount = paid,
        delayed_amount = delayed,
        late_fee_applied = FinanceUtils.safeNumber(row.late_fee_applied),
        is_paid = FinanceUtils.toBoolean(row.is_paid),
        paid_date = row.paid_date,
        restschuld = rest,
        status = status
    }
end

function FinanceAnalytics.computeBusinessProfile(row)
    return parseBusinessData(row)
end

function FinanceAnalytics.detectTransactionMatch(transaction, businessLookup)
    local sender = (transaction.sender_identifier or ''):lower()
    local receiver = (transaction.receiver_identifier or ''):lower()

    for job, _ in pairs(businessLookup) do
        local jobLower = tostring(job):lower()
        if sender:find(jobLower, 1, true) or receiver:find(jobLower, 1, true) then
            return 'eindeutig', job
        end
    end

    if sender ~= '' or receiver ~= '' then
        return 'wahrscheinlich', sender ~= '' and sender or receiver
    end

    return 'manuell_pruefen', nil
end
