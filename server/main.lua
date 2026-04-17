local ESX = FinanceCore.getESX()

local function getPlayer(source)
    ESX = ESX or FinanceCore.getESX()
    return ESX and ESX.GetPlayerFromId and ESX.GetPlayerFromId(source) or nil
end

local function hasAccess(source)
    local xPlayer = getPlayer(source)
    if not xPlayer then return false end

    local group = xPlayer.getGroup and xPlayer.getGroup() or 'user'
    if Config.AllowedGroups[group] then return true end

    local job = xPlayer.getJob and xPlayer.getJob()
    return job and Config.AllowedJobs[job.name] == true
end

local function assertAccess(source)
    if not hasAccess(source) then
        error('Kein Zugriff auf DOJ Finance Suite')
    end
end

local function notify(source, msg, msgType)
    TriggerClientEvent('ox_lib:notify', source, {
        title = 'DOJ Finance Suite',
        description = msg,
        type = msgType or 'inform'
    })
end

lib.callback.register('doj_finance_suite:server:getDashboard', function(source)
    assertAccess(source)
    return FinanceAnalytics.getDashboard()
end)

lib.callback.register('doj_finance_suite:server:getPrivateTaxes', function(source, filters, page, pageSize)
    assertAccess(source)
    local rows, count = FinanceDB.fetchPrivateTaxes(filters, page, pageSize)
    local out = {}
    for _, row in ipairs(rows) do
        local deadline = FinanceDB.fetchDeadline(Config.RecordTypes.taxes, row.id, nil)
        out[#out + 1] = FinanceAnalytics.computePrivateTaxRow(row, deadline)
    end
    return { rows = out, count = count }
end)

lib.callback.register('doj_finance_suite:server:getBusinessTaxes', function(source, filters, page, pageSize)
    assertAccess(source)
    local rows, count = FinanceDB.fetchBusinessTaxes(filters, page, pageSize)
    local _, lookup = FinanceDB.fetchBusinessMaps()
    local out = {}
    for _, row in ipairs(rows) do
        local sourceKey = FinanceUtils.businessKey(row.job, row.period)
        local deadline = FinanceDB.fetchDeadline(Config.RecordTypes.taxes_business, nil, sourceKey)
        local computed = FinanceAnalytics.computeBusinessTaxRow(row, deadline)
        local businessId, matchedBy = FinanceAnalytics.resolveBusinessIdForJob(row.job, lookup)
        computed.business_id = businessId
        computed.business_match_mode = matchedBy
        out[#out + 1] = computed
    end

    return { rows = out, count = count }
end)

lib.callback.register('doj_finance_suite:server:getBusinesses', function(source, page, pageSize)
    assertAccess(source)
    local rows, count = FinanceDB.fetchBusinessProfiles(page, pageSize)
    local out = {}
    for _, row in ipairs(rows) do
        out[#out + 1] = {
            id = row.id,
            type = row.type,
            owner = row.owner,
            employees = row.employees,
            data = FinanceUtils.safeDecode(row.data)
        }
    end

    return { rows = out, count = count }
end)

lib.callback.register('doj_finance_suite:server:getBusinessProfile', function(source, businessId)
    assertAccess(source)
    local business = FinanceDB.fetchBusinessById(businessId)
    if not business then return nil end

    local parsedData = FinanceUtils.safeDecode(business.data)
    local taxRows = MySQL.query.await('SELECT job, job_label, period, amount, paid_amount, delayed_amount, late_fee_applied, is_paid, paid_date FROM taxes_business WHERE lower(job) = lower(?) ORDER BY period DESC', {
        businessId
    }) or {}

    if #taxRows == 0 then
        taxRows = MySQL.query.await('SELECT job, job_label, period, amount, paid_amount, delayed_amount, late_fee_applied, is_paid, paid_date FROM taxes_business ORDER BY period DESC LIMIT 250') or {}
    end

    local computedTaxes = {}
    for _, t in ipairs(taxRows) do
        local key = FinanceUtils.businessKey(t.job, t.period)
        computedTaxes[#computedTaxes + 1] = FinanceAnalytics.computeBusinessTaxRow(t, FinanceDB.fetchDeadline(Config.RecordTypes.taxes_business, nil, key))
    end

    local tx = FinanceDB.fetchTransactionsByDateRange(os.date('%Y-%m-%d', os.time() - 90 * 86400), os.date('%Y-%m-%d'))
    local societyRows = FinanceDB.fetchSocieties()
    local relevant = {}
    for _, entry in ipairs(tx) do
        local m = FinanceAnalytics.matchTransactionToBusiness(entry, businessId, businessId, societyRows, 0, nil, nil)
        if m.confidence >= 40 then
            entry.match = m
            relevant[#relevant + 1] = entry
        end
    end

    local reviewRows = MySQL.query.await('SELECT status FROM doj_finance_reviews WHERE source_type = ? AND source_key LIKE ?', {
        Config.RecordTypes.taxes_business,
        businessId .. '|%'
    }) or {}

    local risk, meta = FinanceAnalytics.computeBusinessRisk({
        id = business.id,
        type = business.type,
        owner = business.owner,
        balance = FinanceUtils.safeNumber(parsedData.balance),
        totalEarned = FinanceUtils.safeNumber(parsedData.totalEarned)
    }, computedTaxes, relevant, FinanceUtils.safeNumber(parsedData.balance), reviewRows)

    return {
        business = business,
        parsed = parsedData,
        taxPeriods = computedTaxes,
        transactions = relevant,
        risk = risk,
        risk_meta = meta,
        case_bundle = FinanceReviews.getCaseBundle(Config.RecordTypes.business, business.id, nil)
    }
end)

lib.callback.register('doj_finance_suite:server:getCaseDetail', function(source, sourceType, sourceId, sourceKey)
    assertAccess(source)
    local data = nil

    if sourceType == Config.RecordTypes.taxes then
        local row = FinanceDB.fetchSinglePrivateTax(sourceId)
        if not row then return nil end
        data = FinanceAnalytics.computePrivateTaxRow(row, FinanceDB.fetchDeadline(sourceType, sourceId, sourceKey))
    elseif sourceType == Config.RecordTypes.taxes_business then
        local job, period = sourceKey:match('^(.-)|(.+)$')
        local row = FinanceDB.fetchSingleBusinessTax(job, period)
        if not row then return nil end
        data = FinanceAnalytics.computeBusinessTaxRow(row, FinanceDB.fetchDeadline(sourceType, sourceId, sourceKey))

        local _, lookup = FinanceDB.fetchBusinessMaps()
        local businessId = FinanceAnalytics.resolveBusinessIdForJob(job, lookup)
        local suggestions = {}
        local fromDate, toDate = FinanceUtils.periodToRange(period)
        for _, tx in ipairs(FinanceDB.fetchPotentialTransactions(job, period)) do
            local match = FinanceAnalytics.matchTransactionToBusiness(tx, job, businessId, FinanceDB.fetchSocieties(), data.restschuld, fromDate, toDate)
            tx.match = match
            if match.confidence >= 35 then
                suggestions[#suggestions + 1] = tx
            end
        end
        data.suggestions = suggestions
        data.business_id = businessId
    elseif sourceType == Config.RecordTypes.business then
        data = FinanceDB.fetchBusinessById(sourceId)
    end

    return {
        source_type = sourceType,
        source_id = sourceId,
        source_key = sourceKey,
        record = data,
        bundle = FinanceReviews.getCaseBundle(sourceType, sourceId, sourceKey)
    }
end)

lib.callback.register('doj_finance_suite:server:setReviewStatus', function(source, payload)
    assertAccess(source)
    return FinanceReviews.setStatus(source, payload)
end)

lib.callback.register('doj_finance_suite:server:addReviewNote', function(source, payload)
    assertAccess(source)
    return FinanceReviews.addNote(source, payload)
end)

lib.callback.register('doj_finance_suite:server:setDeadline', function(source, payload)
    assertAccess(source)
    return FinanceReviews.setDeadline(source, payload)
end)

lib.callback.register('doj_finance_suite:server:removeDeadline', function(source, payload)
    assertAccess(source)
    return FinanceReviews.removeDeadline(source, payload)
end)

lib.callback.register('doj_finance_suite:server:addLink', function(source, payload)
    assertAccess(source)
    return FinanceReviews.addLink(source, payload)
end)

lib.callback.register('doj_finance_suite:server:removeLink', function(source, payload)
    assertAccess(source)
    return FinanceReviews.removeLink(source, payload)
end)

lib.callback.register('doj_finance_suite:server:upsertBusinessMap', function(source, payload)
    assertAccess(source)
    FinanceDB.upsertBusinessMap(payload.tax_job, payload.business_id, payload.alias, getPlayer(source).getIdentifier())
    return true
end)

lib.callback.register('doj_finance_suite:server:getBusinessMaps', function(source)
    assertAccess(source)
    local rows = FinanceDB.fetchBusinessMaps()
    return rows
end)

lib.callback.register('doj_finance_suite:server:getTransactions', function(source, filters, page, pageSize)
    assertAccess(source)
    local rows, count = FinanceDB.fetchTransactions(filters, page, pageSize)
    local openDebt = 0
    local debtRows = MySQL.query.await('SELECT amount, paid_amount, delayed_amount, is_paid FROM taxes_business WHERE is_paid = 0') or {}
    for _, d in ipairs(debtRows) do
        openDebt = openDebt + math.max(0, FinanceUtils.safeNumber(d.amount) - FinanceUtils.safeNumber(d.paid_amount) + FinanceUtils.safeNumber(d.delayed_amount))
    end

    local analysis, windows = FinanceAnalytics.buildTransactionAnalysis(rows, openDebt)
    return { rows = rows, count = count, analysis = analysis, windows = windows, openDebt = openDebt }
end)

lib.callback.register('doj_finance_suite:server:listReports', function(source, filters)
    assertAccess(source)
    return FinanceReports.listReports(filters)
end)

lib.callback.register('doj_finance_suite:server:getReport', function(source, reportId)
    assertAccess(source)
    return FinanceReports.getReport(reportId)
end)

lib.callback.register('doj_finance_suite:server:createReport', function(source, reportType, payload)
    assertAccess(source)
    return FinanceReports.generate(source, reportType, payload)
end)

local function openFinance(source)
    if not hasAccess(source) then
        return notify(source, 'Du bist nicht berechtigt.', 'error')
    end

    TriggerClientEvent('doj_finance_suite:client:open', source)
end

RegisterCommand(Config.Commands.finance, function(source)
    if source > 0 then openFinance(source) end
end, false)

RegisterCommand(Config.Commands.taxoffice, function(source)
    if source > 0 then openFinance(source) end
end, false)

RegisterCommand(Config.Commands.report, function(source, args)
    if source == 0 then return end
    if not hasAccess(source) then return end

    local reportType = args[1] or 'schuldnerreport'
    local payload = {}
    if reportType == 'business_fall' then
        payload.job = args[2]
        payload.period = args[3]
    elseif reportType == 'privat_fall' then
        payload.tax_id = tonumber(args[2])
    elseif reportType == 'zahlungsreport' then
        payload.from = args[2]
        payload.to = args[3]
    end

    local id = FinanceReports.generate(source, reportType, payload)
    if id then notify(source, ('Report erstellt: %s'):format(id), 'success') else notify(source, 'Report konnte nicht erstellt werden.', 'error') end
end, false)

RegisterCommand(Config.Commands.debugRefresh, function(source)
    if source > 0 and not hasAccess(source) then return end
    FinanceDB.invalidateCache()
    if source > 0 then notify(source, 'Cache geleert.', 'inform') else print('[doj_finance_suite] cache refresh done') end
end, true)
