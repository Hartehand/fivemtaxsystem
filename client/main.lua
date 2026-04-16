local resourceName = GetCurrentResourceName()

local function notify(description, type)
    lib.notify({
        title = 'DOJ Finance Suite',
        description = description,
        type = type or 'inform'
    })
end

local function openReviewEditor(sourceType, sourceId, sourceKey)
    local statusInput = lib.inputDialog('Bearbeitungsstatus setzen', {
        {
            type = 'select',
            label = 'Status',
            options = (function()
                local opts = {}
                for _, status in ipairs(Config.Statuses) do
                    opts[#opts + 1] = { value = status, label = status }
                end
                return opts
            end)(),
            required = true
        },
        {
            type = 'input',
            label = 'Zuständig (optional)',
            required = false
        }
    })

    if statusInput then
        lib.callback.await('doj_finance_suite:server:setReviewStatus', false, {
            source_type = sourceType,
            source_id = sourceId,
            source_key = sourceKey,
            status = statusInput[1],
            assigned_to = statusInput[2]
        })
        notify('Status gespeichert.', 'success')
    end

    local noteInput = lib.inputDialog('Interne Notiz', {
        { type = 'textarea', label = 'Notiztext', required = false },
        { type = 'checkbox', label = 'Als interne Notiz markieren', checked = true }
    })

    if noteInput and noteInput[1] and noteInput[1] ~= '' then
        lib.callback.await('doj_finance_suite:server:addReviewNote', false, {
            source_type = sourceType,
            source_id = sourceId,
            source_key = sourceKey,
            note = noteInput[1],
            is_internal = noteInput[2]
        })
        notify('Notiz gespeichert.', 'success')
    end
end

local function openDashboard()
    local data = lib.callback.await('doj_finance_suite:server:getDashboard', false)
    if not data then
        return notify('Dashboard konnte nicht geladen werden.', 'error')
    end

    local options = {
        {
            title = 'Privatsteuern (offen / bezahlt / storniert)',
            description = ('%s / %s / %s'):format(data.private.openCount, data.private.paidCount, data.private.canceledCount)
        },
        {
            title = 'Summen Privatsteuern (offen / bezahlt)',
            description = ('$%s / $%s'):format(FinanceUtils.formatMoney(data.private.openAmount), FinanceUtils.formatMoney(data.private.paidAmount))
        },
        {
            title = 'Business-Steuerperioden offen',
            description = ('%s Perioden, Restschuld $%s'):format(data.business.openPeriods, FinanceUtils.formatMoney(data.business.openAmount))
        },
        {
            title = 'Verzögerungen / Zuschläge',
            description = ('Delayed: $%s | Late Fees: $%s'):format(FinanceUtils.formatMoney(data.business.delayedAmount), FinanceUtils.formatMoney(data.business.lateFeeAmount))
        },
        {
            title = 'Unternehmen',
            description = ('Gesamt: %s | Mit offenen Perioden: %s'):format(data.companies.total, data.companies.withOpenPeriods)
        },
        {
            title = 'Society Gesamtguthaben',
            description = ('$%s'):format(FinanceUtils.formatMoney(data.companies.societiesTotalBalance))
        }
    }

    for _, flagged in ipairs(data.flagged) do
        options[#options + 1] = {
            title = ('⚠️ %s (%s)'):format(flagged.business_type or 'Unbekannt', flagged.owner or 'kein Owner'),
            description = ('%s | Offene Perioden: %s | Balance: $%s'):format(flagged.reason, flagged.openPeriods, FinanceUtils.formatMoney(flagged.balance))
        }
    end

    for _, tx in ipairs(data.recentTransactions) do
        options[#options + 1] = {
            title = ('TX %s: %s -> %s'):format(tx.id, tx.sender_name or '-', tx.receiver_name or '-'),
            description = ('%s | $%s'):format(tx.date or '-', FinanceUtils.formatMoney(tx.value))
        }
    end

    lib.registerContext({
        id = 'doj_finance_dashboard',
        title = 'Finanz-Dashboard',
        menu = 'doj_finance_root',
        options = options
    })

    lib.showContext('doj_finance_dashboard')
end

local function openPrivateTaxes()
    local input = lib.inputDialog('Privatsteuern Filter', {
        {
            type = 'select',
            label = 'Status',
            options = {
                { value = '', label = 'Alle' },
                { value = 'offen', label = 'Offen' },
                { value = 'bezahlt', label = 'Bezahlt' },
                { value = 'storniert', label = 'Storniert' }
            }
        },
        { type = 'input', label = 'Empfänger Identifier', required = false },
        { type = 'input', label = 'Suche Name/Identifier/Titel', required = false }
    })

    local filters = {
        status = input and input[1] or '',
        receiver = input and input[2] or '',
        search = input and input[3] or ''
    }

    local payload = lib.callback.await('doj_finance_suite:server:getPrivateTaxes', false, filters, 1, Config.DefaultPageSize)
    if not payload then
        return notify('Privatsteuern konnten nicht geladen werden.', 'error')
    end

    local options = {}
    for _, row in ipairs(payload.rows) do
        options[#options + 1] = {
            title = ('#%s %s | $%s | %s'):format(row.id, row.receiver_name or row.receiver, FinanceUtils.formatMoney(row.amount), row.status),
            description = ('Empfangen: %s | Fällig: %s | Alter: %s Tage'):format(row.received_date or '-', row.due_date or '-', row.age_days or 0),
            onSelect = function()
                openReviewEditor(Config.RecordTypes.taxes, row.id, nil)
            end
        }
    end

    lib.registerContext({
        id = 'doj_finance_private_taxes',
        title = ('Privatsteuern (%s Treffer)'):format(payload.count),
        menu = 'doj_finance_root',
        options = options
    })

    lib.showContext('doj_finance_private_taxes')
end

local function openBusinessTaxes()
    local input = lib.inputDialog('Business-Steuern Filter', {
        {
            type = 'select',
            label = 'Status',
            options = {
                { value = '', label = 'Alle' },
                { value = 'offen', label = 'Offen' },
                { value = 'teilweise', label = 'Teilweise bezahlt' },
                { value = 'bezahlt', label = 'Bezahlt' }
            }
        },
        { type = 'input', label = 'Job', required = false }
    })

    local filters = {
        status = input and input[1] or '',
        job = input and input[2] or ''
    }

    local payload = lib.callback.await('doj_finance_suite:server:getBusinessTaxes', false, filters, 1, Config.DefaultPageSize)
    if not payload then
        return notify('Business-Steuern konnten nicht geladen werden.', 'error')
    end

    local options = {}
    for _, row in ipairs(payload.rows) do
        local key = FinanceUtils.businessKey(row.job, row.period)
        options[#options + 1] = {
            title = ('%s [%s] | Rest $%s | %s'):format(row.job_label or row.job, row.period, FinanceUtils.formatMoney(row.restschuld), row.status),
            description = ('Betrag: $%s | Bezahlt: $%s | Delayed: $%s'):format(
                FinanceUtils.formatMoney(row.amount),
                FinanceUtils.formatMoney(row.paid_amount),
                FinanceUtils.formatMoney(row.delayed_amount)
            ),
            onSelect = function()
                openReviewEditor(Config.RecordTypes.taxes_business, nil, key)
            end
        }
    end

    lib.registerContext({
        id = 'doj_finance_business_taxes',
        title = ('Unternehmenssteuern (%s Treffer)'):format(payload.count),
        menu = 'doj_finance_root',
        options = options
    })

    lib.showContext('doj_finance_business_taxes')
end

local function openBusinesses()
    local payload = lib.callback.await('doj_finance_suite:server:getBusinesses', false, 1, Config.DefaultPageSize)
    if not payload then
        return notify('Unternehmen konnten nicht geladen werden.', 'error')
    end

    local options = {}
    for _, row in ipairs(payload.rows) do
        options[#options + 1] = {
            title = ('Business #%s %s (%s)'):format(row.id, row.type or '-', row.owner or '-'),
            description = ('Balance: $%s | Earned: $%s | Sales: %s | Orders: %s'):format(
                FinanceUtils.formatMoney(row.balance),
                FinanceUtils.formatMoney(row.totalEarned),
                row.totalSales,
                row.totalOrders
            ),
            onSelect = function()
                openReviewEditor(Config.RecordTypes.business, row.id, nil)
            end
        }
    end

    lib.registerContext({
        id = 'doj_finance_businesses',
        title = ('Unternehmen (%s Einträge)'):format(payload.count),
        menu = 'doj_finance_root',
        options = options
    })

    lib.showContext('doj_finance_businesses')
end

local function openTransactions()
    local input = lib.inputDialog('Transaktionsfilter', {
        { type = 'input', label = 'Suche (Name/Identifier)', required = false },
        { type = 'input', label = 'Von (YYYY-MM-DD)', required = false },
        { type = 'input', label = 'Bis (YYYY-MM-DD)', required = false }
    })

    local payload = lib.callback.await('doj_finance_suite:server:getTransactions', false, {
        search = input and input[1] or '',
        from = input and input[2] or '',
        to = input and input[3] or ''
    }, 1, Config.DefaultPageSize)

    if not payload then
        return notify('Transaktionen konnten nicht geladen werden.', 'error')
    end

    local options = {}
    for _, row in ipairs(payload.rows) do
        options[#options + 1] = {
            title = ('TX #%s | $%s | %s'):format(row.id, FinanceUtils.formatMoney(row.value), row.type or '-'),
            description = ('%s -> %s | %s | Zuordnung: %s'):format(row.sender_name or '-', row.receiver_name or '-', row.date or '-', row.match_quality or 'manuell_pruefen'),
            onSelect = function()
                openReviewEditor(Config.RecordTypes.transaction, row.id, nil)
            end
        }
    end

    lib.registerContext({
        id = 'doj_finance_transactions',
        title = ('Zahlungseingänge/Bewegungen (%s)'):format(payload.count),
        menu = 'doj_finance_root',
        options = options
    })

    lib.showContext('doj_finance_transactions')
end

local function openReports()
    local reports = lib.callback.await('doj_finance_suite:server:listReports', false) or {}
    local options = {
        {
            title = 'Neuen Schuldnerreport erstellen',
            description = 'Basierend auf offenen Privatsteuern',
            onSelect = function()
                local id = lib.callback.await('doj_finance_suite:server:createReport', false, 'schuldnerreport', {})
                notify(('Report erstellt: %s'):format(id or 'n/a'), 'success')
            end
        },
        {
            title = 'Neuen Periodenreport erstellen',
            description = 'Business-Periode (z.B. 2026-04)',
            onSelect = function()
                local input = lib.inputDialog('Periode wählen', {
                    { type = 'input', label = 'Periode (YYYY-MM)', required = true }
                })

                if not input then
                    return
                end

                local id = lib.callback.await('doj_finance_suite:server:createReport', false, 'periodenreport', { period = input[1] })
                notify(('Report erstellt: %s'):format(id or 'n/a'), 'success')
            end
        }
    }

    for _, report in ipairs(reports) do
        options[#options + 1] = {
            title = ('[%s] %s'):format(report.report_type, report.title),
            description = ('ID %s | %s'):format(report.id, report.created_at or '-'),
            onSelect = function()
                local detail = lib.callback.await('doj_finance_suite:server:getReport', false, report.id)
                if not detail then
                    return notify('Report nicht gefunden.', 'error')
                end

                local lines = {
                    ('Typ: %s'):format(detail.report.report_type),
                    ('Erstellt von: %s'):format(detail.report.created_by),
                    ('Anzahl Einträge: %s'):format(#detail.entries)
                }

                for i = 1, math.min(#detail.entries, 10) do
                    local entry = detail.entries[i]
                    lines[#lines + 1] = ('%s) %s ($%s)'):format(i, entry.label, FinanceUtils.formatMoney(entry.amount))
                end

                lib.alertDialog({
                    header = detail.report.title,
                    content = table.concat(lines, '\n'),
                    centered = true,
                    cancel = false
                })
            end
        }
    end

    lib.registerContext({
        id = 'doj_finance_reports',
        title = 'Reports',
        menu = 'doj_finance_root',
        options = options
    })

    lib.showContext('doj_finance_reports')
end

local function openRootMenu()
    lib.registerContext({
        id = 'doj_finance_root',
        title = 'DOJ Finanzsoftware',
        options = {
            { title = 'Dashboard', description = 'Zentrale Kennzahlen und Auffälligkeiten', onSelect = openDashboard },
            { title = 'Privatsteuern', description = 'Einzelfälle aus taxes', onSelect = openPrivateTaxes },
            { title = 'Unternehmenssteuern', description = 'Perioden aus taxes_business', onSelect = openBusinessTaxes },
            { title = 'Unternehmen', description = 'Analyse aus vms_business.data', onSelect = openBusinesses },
            { title = 'Zahlungseingänge', description = 'okokBanking Bewegungen', onSelect = openTransactions },
            { title = 'Reports', description = 'Report-Center und Exportübersicht', onSelect = openReports }
        }
    })

    lib.showContext('doj_finance_root')
end

RegisterNetEvent('doj_finance_suite:client:open', openRootMenu)

AddEventHandler('onResourceStart', function(startedName)
    if startedName ~= resourceName then
        return
    end

    if GetResourceState('ox_target') == 'started' then
        exports.ox_target:addGlobalPlayer({
            {
                name = 'doj_finance_open',
                icon = 'fa-solid fa-chart-pie',
                label = 'Finanzsoftware öffnen',
                onSelect = function()
                    ExecuteCommand(Config.Commands.finance)
                end
            }
        })
    end
end)
