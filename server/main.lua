local ESX = exports['es_extended']:getSharedObject()

local function hasAccess(source)
    local xPlayer = ESX.GetPlayerFromId(source)
    if not xPlayer then
        return false
    end

    local group = xPlayer.getGroup and xPlayer.getGroup() or 'user'
    if Config.AllowedGroups[group] then
        return true
    end

    local job = xPlayer.getJob and xPlayer.getJob()
    return job and Config.AllowedJobs[job.name] == true
end

local function assertAccess(source)
    if not hasAccess(source) then
        error('Kein Zugriff auf DOJ Finance Suite')
    end
end

local function buildBusinessLookup()
    local rows = MySQL.query.await('SELECT DISTINCT job FROM taxes_business') or {}
    local map = {}
    for _, row in ipairs(rows) do
        map[row.job] = true
    end
    return map
end

lib.callback.register('doj_finance_suite:server:getDashboard', function(source)
    assertAccess(source)
    return FinanceAnalytics.getDashboard()
end)

lib.callback.register('doj_finance_suite:server:getPrivateTaxes', function(source, filters, page, pageSize)
    assertAccess(source)
    local rows, count = FinanceDB.fetchPrivateTaxes(filters or {}, page, pageSize)
    local list = {}
    for _, row in ipairs(rows) do
        list[#list + 1] = FinanceAnalytics.computePrivateTaxRow(row)
    end

    return { rows = list, count = count }
end)

lib.callback.register('doj_finance_suite:server:getBusinessTaxes', function(source, filters, page, pageSize)
    assertAccess(source)
    local rows, count = FinanceDB.fetchBusinessTaxes(filters or {}, page, pageSize)
    local list = {}
    for _, row in ipairs(rows) do
        list[#list + 1] = FinanceAnalytics.computeBusinessTaxRow(row)
    end
    return { rows = list, count = count }
end)

lib.callback.register('doj_finance_suite:server:getBusinesses', function(source, page, pageSize)
    assertAccess(source)
    local rows, count = FinanceDB.fetchBusinessProfiles(page, pageSize)
    local output = {}
    for _, row in ipairs(rows) do
        output[#output + 1] = FinanceAnalytics.computeBusinessProfile(row)
    end

    return { rows = output, count = count }
end)

lib.callback.register('doj_finance_suite:server:getSocieties', function(source)
    assertAccess(source)
    return FinanceDB.fetchSocieties()
end)

lib.callback.register('doj_finance_suite:server:getTransactions', function(source, filters, page, pageSize)
    assertAccess(source)
    local rows, count = FinanceDB.fetchTransactions(filters or {}, page, pageSize)
    local lookup = buildBusinessLookup()

    for _, tx in ipairs(rows) do
        local quality, matched = FinanceAnalytics.detectTransactionMatch(tx, lookup)
        tx.match_quality = quality
        tx.match_job = matched
    end

    return { rows = rows, count = count }
end)

lib.callback.register('doj_finance_suite:server:getReview', function(source, sourceType, sourceId, sourceKey)
    assertAccess(source)
    return FinanceReviews.getReviewBundle(sourceType, sourceId, sourceKey)
end)

lib.callback.register('doj_finance_suite:server:setReviewStatus', function(source, payload)
    assertAccess(source)
    local xPlayer = ESX.GetPlayerFromId(source)
    return FinanceReviews.setStatus(xPlayer, payload)
end)

lib.callback.register('doj_finance_suite:server:addReviewNote', function(source, payload)
    assertAccess(source)
    local xPlayer = ESX.GetPlayerFromId(source)
    return FinanceReviews.addNote(xPlayer, payload)
end)

lib.callback.register('doj_finance_suite:server:listReports', function(source)
    assertAccess(source)
    return FinanceReports.listReports(50)
end)

lib.callback.register('doj_finance_suite:server:getReport', function(source, reportId)
    assertAccess(source)
    return FinanceReports.getReport(reportId)
end)

lib.callback.register('doj_finance_suite:server:createReport', function(source, reportType, payload)
    assertAccess(source)
    local xPlayer = ESX.GetPlayerFromId(source)

    if reportType == 'schuldnerreport' then
        return FinanceReports.generateDebtorReport(xPlayer)
    elseif reportType == 'periodenreport' then
        return FinanceReports.generateBusinessPeriodReport(xPlayer, payload and payload.period or os.date('%Y-%m'))
    end

    return nil
end)

local function openFinance(source)
    if not hasAccess(source) then
        TriggerClientEvent('ox_lib:notify', source, {
            title = 'DOJ Finance Suite',
            description = 'Du bist nicht berechtigt.',
            type = 'error'
        })
        return
    end

    TriggerClientEvent('doj_finance_suite:client:open', source)
end

RegisterCommand(Config.Commands.finance, function(source)
    if source == 0 then
        print('Dieser Command ist nur Ingame verfügbar.')
        return
    end

    openFinance(source)
end, false)

RegisterCommand(Config.Commands.taxoffice, function(source)
    if source == 0 then
        print('Dieser Command ist nur Ingame verfügbar.')
        return
    end

    openFinance(source)
end, false)

RegisterCommand(Config.Commands.report, function(source, args)
    if source == 0 then
        print('Dieser Command ist nur Ingame verfügbar.')
        return
    end

    if not hasAccess(source) then
        return
    end

    local reportType = args[1] or 'schuldnerreport'
    local payload = {}
    if reportType == 'periodenreport' then
        payload.period = args[2] or os.date('%Y-%m')
    end

    local xPlayer = ESX.GetPlayerFromId(source)
    local id = nil
    if reportType == 'periodenreport' then
        id = FinanceReports.generateBusinessPeriodReport(xPlayer, payload.period)
    else
        id = FinanceReports.generateDebtorReport(xPlayer)
    end

    TriggerClientEvent('ox_lib:notify', source, {
        title = 'DOJ Finance Suite',
        description = ('Report erstellt (ID: %s)'):format(id),
        type = 'success'
    })
end, false)

RegisterCommand(Config.Commands.debugRefresh, function(source)
    if source ~= 0 and not hasAccess(source) then
        return
    end

    FinanceDB.invalidateCache()

    if source ~= 0 then
        TriggerClientEvent('ox_lib:notify', source, {
            title = 'DOJ Finance Suite',
            description = 'Cache wurde geleert.',
            type = 'inform'
        })
    else
        print('[doj_finance_suite] Cache refreshed.')
    end
end, true)
