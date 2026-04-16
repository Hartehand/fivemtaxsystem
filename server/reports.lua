FinanceReports = {}

local function createReport(typeName, title, createdBy, rangeFrom, rangeTo, summary, entries)
    local reportId = MySQL.insert.await([[INSERT INTO doj_finance_reports (report_type, title, created_by, range_from, range_to, summary) VALUES (?, ?, ?, ?, ?, ?)]], {
        typeName,
        title,
        createdBy,
        rangeFrom,
        rangeTo,
        json.encode(summary or {})
    })

    for idx, entry in ipairs(entries or {}) do
        MySQL.insert.await([[INSERT INTO doj_finance_report_entries (report_id, line_no, source_type, source_id, source_key, label, amount, payload) VALUES (?, ?, ?, ?, ?, ?, ?, ?)]], {
            reportId,
            idx,
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

function FinanceReports.generateDebtorReport(xPlayer)
    local rows = MySQL.query.await([[SELECT id, receiver, receiver_name, received_date, title, amount FROM taxes WHERE is_paid = 0 AND canceled = 0 ORDER BY amount DESC]]) or {}
    local entries = {}
    local total = 0

    for _, row in ipairs(rows) do
        total = total + FinanceUtils.safeNumber(row.amount)
        entries[#entries + 1] = {
            source_type = Config.RecordTypes.taxes,
            source_id = row.id,
            label = ('%s (%s)'):format(row.receiver_name or row.receiver, row.title or 'Ohne Titel'),
            amount = row.amount,
            payload = {
                received_date = row.received_date,
                receiver = row.receiver
            }
        }
    end

    local summary = {
        anzahl = #entries,
        gesamt_offen = total
    }

    local title = ('Schuldnerreport %s'):format(os.date('%d.%m.%Y %H:%M'))
    return createReport('schuldnerreport', title, xPlayer.getIdentifier(), nil, nil, summary, entries)
end

function FinanceReports.generateBusinessPeriodReport(xPlayer, period)
    local rows = MySQL.query.await([[SELECT job, job_label, period, amount, paid_amount, delayed_amount, is_paid FROM taxes_business WHERE period = ? ORDER BY job ASC]], {
        period
    }) or {}

    local entries = {}
    local openTotal = 0
    for _, row in ipairs(rows) do
        local computed = FinanceAnalytics.computeBusinessTaxRow(row)
        if computed.status ~= 'bezahlt' then
            openTotal = openTotal + computed.restschuld
        end

        entries[#entries + 1] = {
            source_type = Config.RecordTypes.taxes_business,
            source_key = FinanceUtils.businessKey(row.job, row.period),
            label = ('%s (%s)'):format(row.job_label or row.job, row.period),
            amount = computed.restschuld,
            payload = computed
        }
    end

    local summary = {
        periode = period,
        anzahl = #entries,
        offene_restschuld = openTotal
    }

    local title = ('Periodenreport %s'):format(period)
    return createReport('periodenreport', title, xPlayer.getIdentifier(), period .. '-01', period .. '-31', summary, entries)
end

function FinanceReports.getReport(reportId)
    local report = MySQL.single.await([[SELECT id, report_type, title, created_by, range_from, range_to, summary, created_at FROM doj_finance_reports WHERE id = ?]], {
        reportId
    })

    if not report then
        return nil
    end

    local entries = MySQL.query.await([[SELECT id, line_no, source_type, source_id, source_key, label, amount, payload FROM doj_finance_report_entries WHERE report_id = ? ORDER BY line_no ASC]], {
        reportId
    }) or {}

    report.summary = FinanceUtils.safeDecode(report.summary)
    for _, entry in ipairs(entries) do
        entry.payload = FinanceUtils.safeDecode(entry.payload)
    end

    return {
        report = report,
        entries = entries
    }
end

function FinanceReports.listReports(limit)
    return MySQL.query.await([[SELECT id, report_type, title, created_by, created_at FROM doj_finance_reports ORDER BY id DESC LIMIT ?]], {
        math.max(1, tonumber(limit) or 20)
    }) or {}
end
