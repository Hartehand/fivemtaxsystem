local ESX = FinanceCore.getESX()
local DEBUG = GetConvarInt('doj_finance_debug', 1) == 1

local function dprint(msg)
    if DEBUG then
        print(('[doj_finance_suite][server] %s'):format(msg))
    end
end

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
    if not job or not job.name then
        return false
    end

    local allowed = Config.AllowedJobs[job.name] == true
    if not allowed then
        return false
    end

    -- Optional strictness: if duty states exist, block access when clearly off-duty.
    if job.onDuty ~= nil and job.onDuty == false then
        return false
    end

    return true
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
    local taxRows = MySQL.query.await('SELECT job, period, amount, paid_amount, delayed_amount, is_paid FROM taxes_business ORDER BY period DESC LIMIT 2500') or {}
    local _, lookup = FinanceDB.fetchBusinessMaps()

    local taxByBusiness = {}
    for _, tax in ipairs(taxRows) do
        local businessId = FinanceAnalytics.resolveBusinessIdForJob(tax.job, lookup)
        local token = FinanceUtils.normalizeToken(businessId)
        taxByBusiness[token] = taxByBusiness[token] or {}
        taxByBusiness[token][#taxByBusiness[token] + 1] = tax
    end

    local out = {}
    for _, row in ipairs(rows) do
        local token = FinanceUtils.normalizeToken(row.id)
        local debt = 0
        local openCount = 0
        for _, tax in ipairs(taxByBusiness[token] or {}) do
            local amount = FinanceUtils.safeNumber(tax.amount)
            local paid = FinanceUtils.safeNumber(tax.paid_amount)
            local delayed = FinanceUtils.safeNumber(tax.delayed_amount)
            local rest = math.max(0, amount - paid + delayed)
            if rest > 0 then
                debt = debt + rest
                openCount = openCount + 1
            end
        end
        local score = math.min(100, openCount * 15 + math.min(60, math.floor(debt / 2500)))

        out[#out + 1] = {
            id = row.id,
            type = row.type,
            owner = row.owner,
            employees = row.employees,
            data = FinanceUtils.safeDecode(row.data),
            kpi = {
                open_tax_cases = openCount,
                rest_debt = debt,
                score = score,
                band = FinanceUtils.riskBand(score)
            }
        }
    end

    return { rows = out, count = count }
end)

lib.callback.register('doj_finance_suite:server:getBusinessProfile', function(source, businessId)
    assertAccess(source)
    local business = FinanceDB.fetchBusinessById(businessId)
    if not business then return nil end

    local parsedData = FinanceUtils.safeDecode(business.data)
    local _, mapLookup = FinanceDB.fetchBusinessMaps()
    local taxRows = MySQL.query.await('SELECT job, job_label, period, amount, paid_amount, delayed_amount, late_fee_applied, is_paid, paid_date FROM taxes_business ORDER BY period DESC LIMIT 1200') or {}
    local filteredTaxRows = {}
    for _, t in ipairs(taxRows) do
        local resolvedBusinessId = FinanceAnalytics.resolveBusinessIdForJob(t.job, mapLookup)
        if FinanceUtils.normalizeToken(resolvedBusinessId) == FinanceUtils.normalizeToken(businessId) then
            filteredTaxRows[#filteredTaxRows + 1] = t
        end
    end

    local computedTaxes = {}
    for _, t in ipairs(filteredTaxRows) do
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

lib.callback.register('doj_finance_suite:server:getBusinessLinkProfile', function(source, businessId)
    assertAccess(source)
    return FinanceDB.fetchBusinessLinkProfile(businessId)
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

lib.callback.register('doj_finance_suite:server:getCaseTimeline', function(source, sourceType, sourceId, sourceKey)
    assertAccess(source)
    return FinanceDB.fetchCaseTimeline(sourceType, sourceId, sourceKey)
end)

lib.callback.register('doj_finance_suite:server:setReviewStatus', function(source, payload)
    assertAccess(source)
    return FinanceReviews.setStatus(source, payload)
end)

lib.callback.register('doj_finance_suite:server:addReviewNote', function(source, payload)
    assertAccess(source)
    return FinanceReviews.addNote(source, payload)
end)

lib.callback.register('doj_finance_suite:server:setCaseMeta', function(source, payload)
    assertAccess(source)
    return FinanceReviews.setCaseMeta(source, payload)
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
    local mapRows, mapLookup = FinanceDB.fetchBusinessMaps()
    local businessRows = FinanceDB.fetchAllBusinessRefs()
    local refs = {}
    for _, tx in ipairs(rows) do
        refs[#refs + 1] = { transaction_table = tx.source_table or Config.RecordTypes.transaction, transaction_id = tx.id }
    end
    local manualMap = FinanceDB.fetchTransactionAssignments(refs)

    for _, tx in ipairs(rows) do
        local key = (tx.source_table or Config.RecordTypes.transaction) .. ':' .. tostring(tx.id)
        local manual = manualMap[key]
        local inferred = FinanceAnalytics.inferBusinessForTransaction(tx, businessRows, mapLookup)
        tx.business_inference = inferred
        tx.assigned_business_id = manual and manual.business_id or inferred.business_id
        tx.assignment_mode = manual and 'manual' or inferred.mode
        tx.assignment_comment = manual and manual.comment or nil
    end

    local openDebt = 0
    local debtRows = MySQL.query.await('SELECT amount, paid_amount, delayed_amount, is_paid FROM taxes_business WHERE is_paid = 0') or {}
    for _, d in ipairs(debtRows) do
        openDebt = openDebt + math.max(0, FinanceUtils.safeNumber(d.amount) - FinanceUtils.safeNumber(d.paid_amount) + FinanceUtils.safeNumber(d.delayed_amount))
    end

    local analysis, windows = FinanceAnalytics.buildTransactionAnalysis(rows, openDebt)
    return { rows = rows, count = count, analysis = analysis, windows = windows, openDebt = openDebt, mappings = mapRows }
end)

lib.callback.register('doj_finance_suite:server:assignTransactionBusiness', function(source, payload)
    assertAccess(source)
    local actor = getPlayer(source)
    local identifier = actor and actor.getIdentifier and actor.getIdentifier() or 'system'
    local ok = FinanceDB.upsertTransactionAssignment({
        transaction_table = payload.transaction_table or Config.RecordTypes.transaction,
        transaction_id = payload.transaction_id,
        business_id = payload.business_id,
        assignment_mode = 'manual',
        comment = payload.comment,
        assigned_by = identifier
    })

    FinanceReviews.addAudit(payload.transaction_table or Config.RecordTypes.transaction, payload.transaction_id, nil, 'transaction_business_assigned', identifier, {
        business_id = payload.business_id,
        comment = payload.comment
    })
    return ok and true or false
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

lib.callback.register('doj_finance_suite:server:listEnforcement', function(source, filters)
    assertAccess(source)
    return FinanceDB.listEnforcement(filters)
end)

lib.callback.register('doj_finance_suite:server:upsertEnforcement', function(source, payload)
    assertAccess(source)
    local actor = getPlayer(source)
    local identifier = actor and actor.getIdentifier and actor.getIdentifier() or 'system'
    local previous = payload.id and MySQL.single.await('SELECT status FROM doj_finance_enforcement WHERE id = ?', { payload.id }) or nil
    payload.set_by = identifier
    local id = FinanceDB.upsertEnforcement(payload)
    if id then
        FinanceDB.addEnforcementEvent(id, previous and previous.status or nil, payload.status, payload.reason, identifier)
        FinanceReviews.addAudit(payload.source_type, payload.source_id, payload.source_key, 'enforcement_updated', identifier, {
            enforcement_id = id,
            status = payload.status
        })
    end
    return id
end)

lib.callback.register('doj_finance_suite:server:listInstallmentPlans', function(source, filters)
    assertAccess(source)
    return FinanceDB.listInstallmentPlans(filters)
end)

lib.callback.register('doj_finance_suite:server:createInstallmentPlan', function(source, payload)
    assertAccess(source)
    local actor = getPlayer(source)
    payload.created_by = actor and actor.getIdentifier and actor.getIdentifier() or 'system'
    local id = FinanceDB.createInstallmentPlan(payload)
    FinanceReviews.addAudit(payload.source_type, payload.source_id, payload.source_key, 'installment_created', payload.created_by, { plan_id = id })
    return id
end)

lib.callback.register('doj_finance_suite:server:markInstallmentEntryPaid', function(source, entryId, sourceType, sourceId, sourceKey)
    assertAccess(source)
    local ok = FinanceDB.markInstallmentEntryPaid(entryId)
    if ok then
        local actor = getPlayer(source)
        FinanceReviews.addAudit(sourceType, sourceId, sourceKey, 'installment_entry_paid', actor and actor.getIdentifier and actor.getIdentifier() or 'system', { entry_id = entryId })
    end
    return ok
end)

lib.callback.register('doj_finance_suite:server:listCaseHandoffs', function(source, filters)
    assertAccess(source)
    return FinanceDB.listCaseHandoffs(filters)
end)

lib.callback.register('doj_finance_suite:server:createCaseHandoff', function(source, payload)
    assertAccess(source)
    local actor = getPlayer(source)
    local identifier = actor and actor.getIdentifier and actor.getIdentifier() or 'system'
    local detail = FinanceDB.fetchCaseTimeline(payload.source_type, payload.source_id, payload.source_key)
    payload.created_by = identifier
    payload.snapshot_json = { timeline = detail, created_at = os.date('%Y-%m-%d %H:%M:%S') }
    local id = FinanceDB.createCaseHandoff(payload)
    FinanceReviews.addAudit(payload.source_type, payload.source_id, payload.source_key, 'case_handoff_created', identifier, { handoff_id = id, target_case_id = payload.target_case_id })
    return id
end)

lib.callback.register('doj_finance_suite:server:listDocuments', function(source, filters)
    assertAccess(source)
    return FinanceDB.listDocuments(filters)
end)

lib.callback.register('doj_finance_suite:server:createDocument', function(source, payload)
    assertAccess(source)
    local actor = getPlayer(source)
    payload.created_by = actor and actor.getIdentifier and actor.getIdentifier() or 'system'
    local id = FinanceDB.createDocument(payload)
    FinanceReviews.addAudit(payload.source_type, payload.source_id, payload.source_key, 'document_created', payload.created_by, { document_id = id, doc_type = payload.doc_type })
    return id
end)

lib.callback.register('doj_finance_suite:server:getNetworkProfile', function(source, businessId)
    assertAccess(source)
    return FinanceDB.fetchBusinessLinkProfile(businessId)
end)

local function openFinance(source)
    dprint(('openFinance requested by source %s'):format(source))
    if not hasAccess(source) then
        dprint(('source %s denied (no finance permissions)'):format(source))
        notify(source, 'Kein Zugriff auf die DOJ Finance Suite.', 'error')
        return
    end

    TriggerClientEvent('doj_finance_suite:client:open', source)
    dprint(('open event sent to source %s'):format(source))
end

RegisterCommand(Config.Commands.finance, function(source)
    dprint(('command /%s by source %s'):format(Config.Commands.finance, source))
    if source > 0 then openFinance(source) end
end, false)

RegisterCommand(Config.Commands.taxoffice, function(source)
    dprint(('command /%s by source %s'):format(Config.Commands.taxoffice, source))
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
