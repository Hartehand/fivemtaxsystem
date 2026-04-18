FinanceReports = {}

local function addReport(reportType, title, createdBy, rangeFrom, rangeTo, summary, entries, notes)
    local maxEntries = (Config.Reports and Config.Reports.maxEntries) or 400
    local trimmedEntries = {}
    for i = 1, math.min(maxEntries, #(entries or {})) do
        trimmedEntries[#trimmedEntries + 1] = entries[i]
    end

    local wrappedSummary = summary or {}
    wrappedSummary.meta = wrappedSummary.meta or {}
    wrappedSummary.meta.entry_count_total = #(entries or {})
    wrappedSummary.meta.entry_count_saved = #trimmedEntries
    wrappedSummary.meta.entries_truncated = #(entries or {}) > #trimmedEntries

    local reportId = MySQL.insert.await('INSERT INTO doj_finance_reports (report_type, title, created_by, range_from, range_to, summary) VALUES (?, ?, ?, ?, ?, ?)', {
        reportType,
        title,
        createdBy,
        rangeFrom,
        rangeTo,
        json.encode({ summary = wrappedSummary, notes = notes or '' })
    })

    for i, entry in ipairs(trimmedEntries) do
        MySQL.insert.await('INSERT INTO doj_finance_report_entries (report_id, line_no, source_type, source_id, source_key, label, amount, payload) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', {
            reportId,
            i,
            entry.source_type,
            entry.source_id,
            entry.source_key,
            entry.label,
            FinanceUtils.safeNumber(entry.amount),
            json.encode(entry.payload or {})
        })
    end

    return reportId
end

local function actorFromSource(source)
    local esx = FinanceCore.getESX()
    if not esx then return 'system' end
    local xPlayer = esx.GetPlayerFromId(source)
    return xPlayer and xPlayer.getIdentifier and xPlayer.getIdentifier() or 'system'
end

function FinanceReports.generate(source, reportType, payload)
    local actor = actorFromSource(source)
    payload = payload or {}

    if reportType == 'schuldnerreport' then
        local rows = MySQL.query.await('SELECT id, receiver, receiver_name, title, amount, received_date FROM taxes WHERE is_paid = 0 AND canceled = 0 ORDER BY amount DESC') or {}
        local entries, total = {}, 0
        for _, row in ipairs(rows) do
            total = total + FinanceUtils.safeNumber(row.amount)
            entries[#entries + 1] = {
                source_type = Config.RecordTypes.taxes,
                source_id = row.id,
                label = ('%s - %s'):format(row.receiver_name or row.receiver, row.title),
                amount = row.amount,
                payload = row
            }
        end

        return addReport('schuldnerreport', 'Schuldnerreport', actor, nil, nil, {
            gesamt = total,
            anzahl = #entries
        }, entries)
    elseif reportType == 'hochrisikoreport' then
        local dashboard = FinanceAnalytics.getDashboard()
        local entries = {}
        for _, b in ipairs(dashboard.highRiskCases or {}) do
            entries[#entries + 1] = {
                source_type = Config.RecordTypes.business,
                source_key = b.job,
                label = ('%s / %s'):format(b.job_label or b.job, b.business_id),
                amount = b.meta and b.meta.restDebt or 0,
                payload = {
                    risk = b.risk,
                    reasons = b.risk and b.risk.reasons or {}
                }
            }
        end

        return addReport('hochrisikoreport', 'Hochrisikoreport', actor, nil, nil, {
            anzahl = #entries
        }, entries)
    elseif reportType == 'business_fall' then
        local row = FinanceDB.fetchSingleBusinessTax(payload.job, payload.period)
        if not row then return nil end
        local computed = FinanceAnalytics.computeBusinessTaxRow(row, FinanceDB.fetchDeadline(Config.RecordTypes.taxes_business, nil, FinanceUtils.businessKey(row.job, row.period)))
        return addReport('business_fall', ('Business-Fall %s %s'):format(row.job, row.period), actor, nil, nil, computed, {
            {
                source_type = Config.RecordTypes.taxes_business,
                source_key = FinanceUtils.businessKey(row.job, row.period),
                label = ('%s %s'):format(row.job, row.period),
                amount = computed.restschuld,
                payload = computed
            }
        })
    elseif reportType == 'privat_fall' then
        local row = FinanceDB.fetchSinglePrivateTax(payload.tax_id)
        if not row then return nil end
        local computed = FinanceAnalytics.computePrivateTaxRow(row, FinanceDB.fetchDeadline(Config.RecordTypes.taxes, row.id, nil))
        return addReport('privat_fall', ('Privatfall #%s'):format(row.id), actor, nil, nil, computed, {
            {
                source_type = Config.RecordTypes.taxes,
                source_id = row.id,
                label = ('%s - %s'):format(row.receiver_name or row.receiver, row.title),
                amount = computed.amount,
                payload = computed
            }
        })
    elseif reportType == 'zahlungsreport' then
        local fromDate = payload.from or os.date('%Y-%m-%d', os.time() - 30 * 86400)
        local toDate = payload.to or os.date('%Y-%m-%d')
        local rows = FinanceDB.fetchTransactionsByDateRange(fromDate, toDate)
        local incoming, outgoing = 0, 0
        local entries = {}
        for _, tx in ipairs(rows) do
            local v = FinanceUtils.safeNumber(tx.value)
            if v >= 0 then incoming = incoming + v else outgoing = outgoing + math.abs(v) end
            entries[#entries + 1] = {
                source_type = Config.RecordTypes.transaction,
                source_id = tx.id,
                label = ('TX#%s %s -> %s'):format(tx.id, tx.sender_name or '-', tx.receiver_name or '-'),
                amount = tx.value,
                payload = tx
            }
        end

        return addReport('zahlungsreport', ('Zahlungsreport %s bis %s'):format(fromDate, toDate), actor, fromDate, toDate, {
            incoming = incoming,
            outgoing = outgoing,
            anzahl = #entries
        }, entries)
    elseif reportType == 'unternehmens_risiko' then
        local dashboard = FinanceAnalytics.getDashboard()
        local entries = {}
        for _, b in ipairs(dashboard.frequentDebtors or {}) do
            entries[#entries + 1] = {
                source_type = Config.RecordTypes.business,
                source_key = b.job,
                label = ('%s (%s)'):format(b.job_label or b.job, b.business_id),
                amount = b.meta and b.meta.restDebt or 0,
                payload = b
            }
        end

        return addReport('unternehmens_risiko', 'Unternehmens-Risikoreport', actor, nil, nil, {
            anzahl = #entries
        }, entries)
    elseif reportType == 'transaktionsauffaelligkeit' then
        local fromDate = payload.from or os.date('%Y-%m-%d', os.time() - 90 * 86400)
        local toDate = payload.to or os.date('%Y-%m-%d')
        local rows = FinanceDB.fetchTransactionsByDateRange(fromDate, toDate)
        local analysis, windows = FinanceAnalytics.buildTransactionAnalysis(rows, FinanceUtils.safeNumber(payload.open_debt))
        local entries = {}
        for i = 1, math.min(150, #rows) do
            local tx = rows[i]
            entries[#entries + 1] = {
                source_type = Config.RecordTypes.transaction,
                source_id = tx.id,
                label = ('TX#%s %s -> %s'):format(tx.id, tx.sender_name or '-', tx.receiver_name or '-'),
                amount = tx.value,
                payload = tx
            }
        end

        return addReport('transaktionsauffaelligkeit', ('Transaktions-Auffälligkeitsreport %s bis %s'):format(fromDate, toDate), actor, fromDate, toDate, {
            score = analysis.score,
            band = analysis.band,
            reasons = analysis.reasons,
            windows = windows
        }, entries)
    elseif reportType == 'zahlungsverhalten' then
        local rows = MySQL.query.await('SELECT job, job_label, period, amount, paid_amount, delayed_amount, is_paid FROM taxes_business ORDER BY period DESC LIMIT 400') or {}
        local entries = {}
        for _, row in ipairs(rows) do
            local computed = FinanceAnalytics.computeBusinessTaxRow(row)
            entries[#entries + 1] = {
                source_type = Config.RecordTypes.taxes_business,
                source_key = FinanceUtils.businessKey(row.job, row.period),
                label = ('%s %s'):format(row.job, row.period),
                amount = computed.restschuld,
                payload = computed
            }
        end

        return addReport('zahlungsverhalten', 'Zahlungsverhaltensreport', actor, nil, nil, {
            anzahl = #entries
        }, entries)
    elseif reportType == 'debtor_master_report' then
        local dashboard = FinanceAnalytics.getDashboard()
        local entries = {}
        for _, p in ipairs((dashboard.private and dashboard.private.topDebtors) or {}) do
            entries[#entries + 1] = {
                source_type = Config.RecordTypes.taxes,
                source_id = p.id,
                label = ('Privat %s'):format(p.receiver_name or p.receiver),
                amount = p.amount,
                payload = p
            }
        end
        for _, b in ipairs((dashboard.business and dashboard.business.topDebtors) or {}) do
            entries[#entries + 1] = {
                source_type = Config.RecordTypes.business,
                source_key = b.business_id,
                label = ('Business %s'):format(b.job_label or b.job or b.business_id),
                amount = b.meta and b.meta.restDebt or 0,
                payload = b
            }
        end
        return addReport('debtor_master_report', 'Debtor Master Report', actor, nil, nil, {
            private_open = dashboard.private and dashboard.private.openAmount or 0,
            business_open = dashboard.business and dashboard.business.openAmount or 0,
            billing_open = dashboard.billing and dashboard.billing.total or 0
        }, entries)
    elseif reportType == 'person_risk_report' then
        local dashboard = FinanceAnalytics.getDashboard()
        local entries = {}
        for _, p in ipairs(dashboard.suspiciousPeople or {}) do
            entries[#entries + 1] = {
                source_type = 'users',
                source_key = p.identifier,
                label = p.name or p.identifier,
                amount = p.score,
                payload = p
            }
        end
        return addReport('person_risk_report', 'Person Risk Report', actor, nil, nil, {
            anzahl = #entries
        }, entries)
    elseif reportType == 'asset_mismatch_report' then
        local dashboard = FinanceAnalytics.getDashboard()
        local entries = {}
        for _, p in ipairs(dashboard.suspiciousPeople or {}) do
            entries[#entries + 1] = {
                source_type = 'users',
                source_key = p.identifier,
                label = ('%s (%s)'):format(p.name or p.identifier, p.job or '-'),
                amount = p.score,
                payload = p
            }
        end
        return addReport('asset_mismatch_report', 'Asset Mismatch Report', actor, nil, nil, { anzahl = #entries }, entries)
    elseif reportType == 'cityhall_charge_finance_report' then
        local rows = FinanceDB.fetchAssetSignals().charges or {}
        local entries = {}
        for _, c in ipairs(rows) do
            entries[#entries + 1] = {
                source_type = 'vms_cityhall_wasabi_bridge_sync',
                source_key = c.target_identifier,
                label = ('%s / %s'):format(c.target_name or c.target_identifier, c.status or '-'),
                amount = 0,
                payload = c
            }
        end
        return addReport('cityhall_charge_finance_report', 'Cityhall Charge Finance Report', actor, nil, nil, { anzahl = #entries }, entries)
    elseif reportType == 'business_person_link_report' then
        local businesses = FinanceDB.fetchAllBusinessRefs()
        local entries = {}
        for i = 1, math.min(120, #businesses) do
            local b = businesses[i]
            local profile = FinanceDB.fetchBusinessLinkProfile(b.id)
            entries[#entries + 1] = {
                source_type = Config.RecordTypes.business,
                source_key = b.id,
                label = ('%s (%s)'):format(b.id, b.type or '-'),
                amount = ((profile and profile.users) and #profile.users or 0) + ((profile and profile.vehicles) and #profile.vehicles or 0),
                payload = profile
            }
        end
        return addReport('business_person_link_report', 'Business Person Link Report', actor, nil, nil, { anzahl = #entries }, entries)
    end

    return nil
end

function FinanceReports.getReport(reportId)
    local report = MySQL.single.await('SELECT id, report_type, title, created_by, range_from, range_to, summary, created_at FROM doj_finance_reports WHERE id = ?', { reportId })
    if not report then return nil end

    local entries = MySQL.query.await('SELECT id, line_no, source_type, source_id, source_key, label, amount, payload FROM doj_finance_report_entries WHERE report_id = ? ORDER BY line_no ASC', {
        reportId
    }) or {}

    report.summary = FinanceUtils.safeDecode(report.summary)
    for _, entry in ipairs(entries) do
        entry.payload = FinanceUtils.safeDecode(entry.payload)
    end

    return { report = report, entries = entries }
end

function FinanceReports.listReports(filters)
    return FinanceDB.fetchReports(filters)
end
