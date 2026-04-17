local resourceName = GetCurrentResourceName()

local function notify(message, msgType)
    lib.notify({ title = 'DOJ Finance Suite', description = message, type = msgType or 'inform' })
end

local function multilineFromBundle(bundle)
    local lines = {}
    if bundle.review then
        lines[#lines + 1] = ('Status: %s | Bearbeiter: %s'):format(bundle.review.status or '-', bundle.review.assigned_to or '-')
    else
        lines[#lines + 1] = 'Status: kein Review vorhanden'
    end

    if bundle.deadline then
        lines[#lines + 1] = ('Frist-Override: %s (%s)'):format(bundle.deadline.due_date or '-', bundle.deadline.reason or '-')
    end

    lines[#lines + 1] = '--- Notizen ---'
    for i = 1, math.min(5, #bundle.notes) do
        local n = bundle.notes[i]
        lines[#lines + 1] = ('%s: %s'):format(n.author_identifier, n.note)
    end

    lines[#lines + 1] = '--- Audit ---'
    for i = 1, math.min(5, #bundle.audit) do
        local a = bundle.audit[i]
        lines[#lines + 1] = ('%s: %s (%s)'):format(a.created_at or '-', a.action or '-', a.actor_identifier or '-')
    end

    return table.concat(lines, '\n')
end

local function openCaseActions(sourceType, sourceId, sourceKey)
    local detail = lib.callback.await('doj_finance_suite:server:getCaseDetail', false, sourceType, sourceId, sourceKey)
    if not detail then
        return notify('Fall nicht gefunden.', 'error')
    end

    local opts = {
        {
            title = 'Aktenansicht',
            description = 'Review, Notizen, Audit, Frist und Links',
            onSelect = function()
                lib.alertDialog({
                    header = 'Fallakte',
                    content = multilineFromBundle(detail.bundle),
                    centered = true,
                    cancel = false
                })
            end
        },
        {
            title = 'Status ändern',
            onSelect = function()
                local statuses = {}
                for _, s in ipairs(Config.Statuses) do
                    statuses[#statuses + 1] = { value = s, label = s }
                end

                local input = lib.inputDialog('Status setzen', {
                    { type = 'select', label = 'Status', options = statuses, required = true },
                    { type = 'input', label = 'Bearbeiter', required = false }
                })

                if input then
                    lib.callback.await('doj_finance_suite:server:setReviewStatus', false, {
                        source_type = sourceType,
                        source_id = sourceId,
                        source_key = sourceKey,
                        status = input[1],
                        assigned_to = input[2]
                    })
                    notify('Status gesetzt.', 'success')
                end
            end
        },
        {
            title = 'Notiz hinzufügen',
            onSelect = function()
                local input = lib.inputDialog('Neue Notiz', {
                    { type = 'textarea', label = 'Notiz', required = true },
                    { type = 'checkbox', label = 'Intern', checked = true }
                })

                if input then
                    lib.callback.await('doj_finance_suite:server:addReviewNote', false, {
                        source_type = sourceType,
                        source_id = sourceId,
                        source_key = sourceKey,
                        note = input[1],
                        is_internal = input[2]
                    })
                    notify('Notiz gespeichert.', 'success')
                end
            end
        },
        {
            title = 'Frist überschreiben',
            description = 'doj_finance_deadlines verwenden',
            onSelect = function()
                local input = lib.inputDialog('Frist überschreiben', {
                    { type = 'input', label = 'Due Date (YYYY-MM-DD)', required = true },
                    { type = 'input', label = 'Grund', required = true }
                })

                if input then
                    lib.callback.await('doj_finance_suite:server:setDeadline', false, {
                        source_type = sourceType,
                        source_id = sourceId,
                        source_key = sourceKey,
                        due_date = input[1],
                        reason = input[2]
                    })
                    notify('Frist gesetzt.', 'success')
                end
            end
        },
        {
            title = 'Frist-Override löschen',
            onSelect = function()
                lib.callback.await('doj_finance_suite:server:removeDeadline', false, {
                    source_type = sourceType,
                    source_id = sourceId,
                    source_key = sourceKey
                })
                notify('Frist-Override gelöscht.', 'success')
            end
        }
    }

    if sourceType == Config.RecordTypes.taxes_business and detail.record and detail.record.suggestions then
        opts[#opts + 1] = {
            title = 'Transaktion verknüpfen',
            description = 'Auto-Vorschläge oder manuell ID setzen',
            onSelect = function()
                local txOptions = {}
                for i = 1, math.min(30, #detail.record.suggestions) do
                    local tx = detail.record.suggestions[i]
                    txOptions[#txOptions + 1] = { value = tostring(tx.id), label = ('#%s %s $%s (%s)'):format(tx.id, tx.date or '-', FinanceUtils.formatMoney(tx.value), tx.match.quality) }
                end

                local input = lib.inputDialog('Transaktion verknüpfen', {
                    { type = 'select', label = 'Vorschlag', options = txOptions, required = false },
                    { type = 'number', label = 'Oder manuelle TX-ID', required = false },
                    {
                        type = 'select',
                        label = 'Match-Qualität',
                        options = {
                            { value = 'eindeutig', label = 'eindeutig' },
                            { value = 'wahrscheinlich', label = 'wahrscheinlich' },
                            { value = 'manuell_pruefen', label = 'manuell_pruefen' }
                        },
                        required = true
                    },
                    { type = 'input', label = 'Kommentar', required = false }
                })

                if input then
                    local txId = tonumber(input[1]) or tonumber(input[2])
                    if not txId then return notify('Keine TX-ID ausgewählt.', 'error') end

                    lib.callback.await('doj_finance_suite:server:addLink', false, {
                        business_job = detail.record.job,
                        period = detail.record.period,
                        transaction_id = txId,
                        tax_source_type = sourceType,
                        tax_source_id = sourceId,
                        tax_source_key = sourceKey,
                        match_quality = input[3],
                        comment = input[4]
                    })

                    notify('Transaktion verknüpft.', 'success')
                end
            end
        }
    end

    for _, link in ipairs(detail.bundle.links or {}) do
        opts[#opts + 1] = {
            title = ('Link #%s lösen'):format(link.id),
            description = ('TX #%s | %s'):format(link.transaction_id or '-', link.match_quality or '-'),
            onSelect = function()
                lib.callback.await('doj_finance_suite:server:removeLink', false, {
                    link_id = link.id,
                    source_type = sourceType,
                    source_id = sourceId,
                    source_key = sourceKey
                })
                notify('Verknüpfung gelöst.', 'success')
            end
        }
    end

    lib.registerContext({
        id = 'doj_finance_case_actions',
        title = 'Fallaktionen',
        menu = 'doj_finance_root',
        options = opts
    })
    lib.showContext('doj_finance_case_actions')
end

local function openDashboard()
    local data = lib.callback.await('doj_finance_suite:server:getDashboard', false)
    if not data then return notify('Dashboard konnte nicht geladen werden.', 'error') end

    local options = {
        {
            title = 'Privatrisiko',
            description = ('Score %s (%s)'):format(data.private.risk.score, data.private.risk.band)
        },
        {
            title = 'Business hochriskant',
            description = ('%s Fälle'):format(data.business.highRiskCount)
        },
        {
            title = 'Häufige Schuldner',
            description = ('%s Unternehmen'):format(data.business.debtorCount)
        },
        {
            title = 'Transaktionsfenster 7/30/90',
            description = ('7T: $%s | 30T: $%s | 90T: $%s'):format(
                FinanceUtils.formatMoney((data.txWindows[7] and data.txWindows[7].incoming) or 0),
                FinanceUtils.formatMoney((data.txWindows[30] and data.txWindows[30].incoming) or 0),
                FinanceUtils.formatMoney((data.txWindows[90] and data.txWindows[90].incoming) or 0)
            )
        }
    }

    for _, case in ipairs(data.highRiskCases or {}) do
        options[#options + 1] = {
            title = ('⚠️ %s [%s]'):format(case.job_label or case.job, case.risk.band),
            description = ('Score %s | Restschuld $%s'):format(case.risk.score, FinanceUtils.formatMoney(case.meta.restDebt))
        }
    end

    lib.registerContext({ id = 'doj_finance_dashboard', title = 'Dashboard / Risikoanalyse', menu = 'doj_finance_root', options = options })
    lib.showContext('doj_finance_dashboard')
end

local function openPrivateTaxes()
    local data = lib.callback.await('doj_finance_suite:server:getPrivateTaxes', false, {}, 1, Config.DefaultPageSize)
    if not data then return notify('Fehler beim Laden.', 'error') end

    local options = {}
    for _, row in ipairs(data.rows) do
        options[#options + 1] = {
            title = ('#%s %s [%s]'):format(row.id, row.receiver_name or row.receiver, row.status),
            description = ('Betrag: $%s | Frist: %s (%s) | Überfällig: %s Tage'):format(
                FinanceUtils.formatMoney(row.amount),
                row.due_date or '-',
                row.due_source,
                row.overdue_days or 0
            ),
            onSelect = function()
                openCaseActions(Config.RecordTypes.taxes, row.id, nil)
            end
        }
    end

    lib.registerContext({ id = 'doj_finance_private', title = 'Privatsteuern', menu = 'doj_finance_root', options = options })
    lib.showContext('doj_finance_private')
end

local function openBusinessTaxes()
    local data = lib.callback.await('doj_finance_suite:server:getBusinessTaxes', false, {}, 1, Config.DefaultPageSize)
    if not data then return notify('Fehler beim Laden.', 'error') end

    local options = {}
    for _, row in ipairs(data.rows) do
        local sourceKey = FinanceUtils.businessKey(row.job, row.period)
        options[#options + 1] = {
            title = ('%s %s | %s'):format(row.job_label or row.job, row.period, row.status),
            description = ('Restschuld: $%s | Firma: %s (%s)'):format(
                FinanceUtils.formatMoney(row.restschuld),
                row.business_id or '-',
                row.business_match_mode or '-'
            ),
            onSelect = function()
                openCaseActions(Config.RecordTypes.taxes_business, nil, sourceKey)
            end
        }
    end

    lib.registerContext({ id = 'doj_finance_business_taxes', title = 'Business-Steuerfälle', menu = 'doj_finance_root', options = options })
    lib.showContext('doj_finance_business_taxes')
end

local function openBusinesses()
    local input = lib.inputDialog('Businessprofil öffnen', {
        { type = 'input', label = 'Business-ID (z.B. PDM)', required = true }
    })
    if not input then return end

    local detail = lib.callback.await('doj_finance_suite:server:getBusinessProfile', false, input[1])
    if not detail then return notify('Business nicht gefunden.', 'error') end

    local options = {
        {
            title = ('Profil %s (%s)'):format(detail.business.id, detail.business.type or '-'),
            description = ('Owner: %s | Balance: $%s | Earned: $%s'):format(
                detail.business.owner or '-',
                FinanceUtils.formatMoney(detail.parsed.balance),
                FinanceUtils.formatMoney(detail.parsed.totalEarned)
            )
        },
        {
            title = ('Risikowert: %s (%s)'):format(detail.risk.score, detail.risk.band),
            description = table.concat(detail.risk.reasons, ' | ')
        },
        {
            title = 'Business-Fallakte öffnen',
            onSelect = function()
                openCaseActions(Config.RecordTypes.business, detail.business.id, nil)
            end
        }
    }

    for i = 1, math.min(8, #detail.taxPeriods) do
        local p = detail.taxPeriods[i]
        options[#options + 1] = {
            title = ('Periode %s - %s'):format(p.period, p.status),
            description = ('Restschuld $%s | Delayed $%s'):format(FinanceUtils.formatMoney(p.restschuld), FinanceUtils.formatMoney(p.delayed_amount))
        }
    end

    for i = 1, math.min(5, #detail.transactions) do
        local tx = detail.transactions[i]
        options[#options + 1] = {
            title = ('TX#%s %s $%s'):format(tx.id, tx.date or '-', FinanceUtils.formatMoney(tx.value)),
            description = ('%s -> %s'):format(tx.sender_name or '-', tx.receiver_name or '-')
        }
    end

    lib.registerContext({ id = 'doj_finance_business_profile', title = 'Businessprofil', menu = 'doj_finance_root', options = options })
    lib.showContext('doj_finance_business_profile')
end

local function openReports()
    local filters = lib.inputDialog('Report-Filter', {
        { type = 'input', label = 'Typ (optional)', required = false },
        { type = 'input', label = 'Von YYYY-MM-DD', required = false },
        { type = 'input', label = 'Bis YYYY-MM-DD', required = false }
    })

    local rows, total = lib.callback.await('doj_finance_suite:server:listReports', false, {
        type = filters and filters[1] or '',
        from = filters and filters[2] or '',
        to = filters and filters[3] or '',
        page = 1,
        pageSize = 50
    })

    local options = {
        {
            title = 'Report erstellen',
            description = 'Schuldner, Hochrisiko, Privatfall, Business-Fall, Zahlungsreport, Unternehmens-Risiko',
            onSelect = function()
                local in2 = lib.inputDialog('Report erstellen', {
                    {
                        type = 'select', label = 'Typ', required = true,
                        options = {
                            { value = 'schuldnerreport', label = 'schuldnerreport' },
                            { value = 'hochrisikoreport', label = 'hochrisikoreport' },
                            { value = 'privat_fall', label = 'privat_fall' },
                            { value = 'business_fall', label = 'business_fall' },
                            { value = 'zahlungsreport', label = 'zahlungsreport' },
                            { value = 'unternehmens_risiko', label = 'unternehmens_risiko' },
                            { value = 'transaktionsauffaelligkeit', label = 'transaktionsauffaelligkeit' },
                            { value = 'zahlungsverhalten', label = 'zahlungsverhalten' }
                        }
                    },
                    { type = 'input', label = 'Arg1 (tax_id oder job oder from)', required = false },
                    { type = 'input', label = 'Arg2 (period oder to)', required = false }
                })

                if not in2 then return end
                local payload = {}
                if in2[1] == 'privat_fall' then payload.tax_id = tonumber(in2[2]) end
                if in2[1] == 'business_fall' then payload.job = in2[2] payload.period = in2[3] end
                if in2[1] == 'zahlungsreport' then payload.from = in2[2] payload.to = in2[3] end
                local id = lib.callback.await('doj_finance_suite:server:createReport', false, in2[1], payload)
                notify(('Report-ID: %s'):format(id or 'n/a'), id and 'success' or 'error')
            end
        }
    }

    for _, report in ipairs(rows or {}) do
        options[#options + 1] = {
            title = ('[%s] %s'):format(report.report_type, report.title),
            description = ('ID %s | %s | %s'):format(report.id, report.created_by, report.created_at),
            onSelect = function()
                local detail = lib.callback.await('doj_finance_suite:server:getReport', false, report.id)
                if not detail then return end

                local lines = {
                    ('Titel: %s'):format(detail.report.title),
                    ('Typ: %s'):format(detail.report.report_type),
                    ('Ersteller: %s'):format(detail.report.created_by),
                    ('Erstellt: %s'):format(detail.report.created_at),
                    ('Zeilen: %s'):format(#detail.entries)
                }
                for i = 1, math.min(10, #detail.entries) do
                    local e = detail.entries[i]
                    lines[#lines + 1] = ('%s) %s ($%s)'):format(i, e.label, FinanceUtils.formatMoney(e.amount))
                end

                lib.alertDialog({ header = 'Report-Detail', content = table.concat(lines, '\n'), centered = true, cancel = false })
            end
        }
    end

    lib.registerContext({ id = 'doj_finance_reports', title = ('Reportcenter (%s)'):format(total or 0), menu = 'doj_finance_root', options = options })
    lib.showContext('doj_finance_reports')
end

local function openTransactions()
    local input = lib.inputDialog('Transaktionsanalyse', {
        { type = 'input', label = 'Suche (optional)', required = false },
        { type = 'input', label = 'Von YYYY-MM-DD', required = false },
        { type = 'input', label = 'Bis YYYY-MM-DD', required = false }
    })

    local payload = lib.callback.await('doj_finance_suite:server:getTransactions', false, {
        search = input and input[1] or '',
        from = input and input[2] or '',
        to = input and input[3] or ''
    }, 1, 50)

    if not payload then
        return notify('Transaktionen konnten nicht geladen werden.', 'error')
    end

    local options = {
        {
            title = ('Analyse-Score: %s (%s)'):format(payload.analysis.score, payload.analysis.band),
            description = table.concat(payload.analysis.reasons, ' | ')
        },
        {
            title = ('Offene Steuerlast (Business): $%s'):format(FinanceUtils.formatMoney(payload.openDebt or 0)),
            description = ('7T Ein/Aus: $%s / $%s'):format(
                FinanceUtils.formatMoney((payload.windows[7] and payload.windows[7].incoming) or 0),
                FinanceUtils.formatMoney((payload.windows[7] and payload.windows[7].outgoing) or 0)
            )
        }
    }

    for _, tx in ipairs(payload.rows or {}) do
        options[#options + 1] = {
            title = ('TX#%s %s | $%s'):format(tx.id, tx.type or '-', FinanceUtils.formatMoney(tx.value)),
            description = ('%s -> %s | %s'):format(tx.sender_name or '-', tx.receiver_name or '-', tx.date or '-')
        }
    end

    lib.registerContext({
        id = 'doj_finance_transactions',
        title = ('Transaktionsanalyse (%s)'):format(payload.count or 0),
        menu = 'doj_finance_root',
        options = options
    })

    lib.showContext('doj_finance_transactions')
end

local function openBusinessMapping()
    local rows = lib.callback.await('doj_finance_suite:server:getBusinessMaps', false) or {}
    local options = {
        {
            title = 'Mapping hinzufügen/ändern',
            onSelect = function()
                local input = lib.inputDialog('Business-Mapping', {
                    { type = 'input', label = 'tax_job', required = true },
                    { type = 'input', label = 'business_id', required = true },
                    { type = 'input', label = 'alias (optional)', required = false }
                })

                if input then
                    lib.callback.await('doj_finance_suite:server:upsertBusinessMap', false, {
                        tax_job = input[1],
                        business_id = input[2],
                        alias = input[3]
                    })
                    notify('Mapping gespeichert.', 'success')
                end
            end
        }
    }

    for _, row in ipairs(rows) do
        options[#options + 1] = {
            title = ('%s -> %s'):format(row.tax_job, row.business_id),
            description = ('Alias: %s'):format(row.alias or '-')
        }
    end

    lib.registerContext({ id = 'doj_finance_business_map', title = 'Business-Mapping', menu = 'doj_finance_root', options = options })
    lib.showContext('doj_finance_business_map')
end

local function openRoot()
    lib.registerContext({
        id = 'doj_finance_root',
        title = 'DOJ Finanzsoftware',
        options = {
            { title = 'Dashboard', description = 'KPI + Risiko + Trends', onSelect = openDashboard },
            { title = 'Privatsteuer-Fälle', description = 'Listen- & Detailansicht', onSelect = openPrivateTaxes },
            { title = 'Business-Steuerfälle', description = 'job+period mit Mapping', onSelect = openBusinessTaxes },
            { title = 'Businessprofil', description = 'Finanzprofil / Risiko / Verlauf', onSelect = openBusinesses },
            { title = 'Transaktionsanalyse', description = 'okokbanking_transactions aktiv auswerten', onSelect = openTransactions },
            { title = 'Reportcenter', description = 'Reports erstellen/anzeigen/filtern', onSelect = openReports },
            { title = 'Business-Mapping', description = 'tax_job -> business_id', onSelect = openBusinessMapping }
        }
    })

    lib.showContext('doj_finance_root')
end

RegisterNetEvent('doj_finance_suite:client:open', openRoot)

local spawnedNpc
local function setupInteraction()
    if Config.Interaction.npc.enabled then
        local model = Config.Interaction.npc.model
        RequestModel(model)
        while not HasModelLoaded(model) do Wait(0) end

        local coords = Config.Interaction.npc.coords
        spawnedNpc = CreatePed(0, model, coords.x, coords.y, coords.z - 1.0, coords.w, false, true)
        SetEntityInvincible(spawnedNpc, true)
        SetBlockingOfNonTemporaryEvents(spawnedNpc, true)
        FreezeEntityPosition(spawnedNpc, true)

        if Config.Interaction.useTarget and GetResourceState('ox_target') == 'started' then
            exports.ox_target:addLocalEntity(spawnedNpc, {
                {
                    name = 'doj_finance_npc',
                    icon = 'fa-solid fa-building-columns',
                    label = 'Finanzamt öffnen',
                    onSelect = function() ExecuteCommand(Config.Commands.finance) end
                }
            })
        end
    end

    CreateThread(function()
        while true do
            local sleep = 1000
            if Config.Interaction.point.enabled then
                local ped = PlayerPedId()
                local p = GetEntityCoords(ped)
                local c = Config.Interaction.point.coords
                local dist = #(p - c)
                if dist <= 25.0 then
                    sleep = 0
                    if Config.Interaction.point.drawMarker then
                        local m = Config.Interaction.point.marker
                        DrawMarker(m.type, c.x, c.y, c.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, m.scale.x, m.scale.y, m.scale.z, m.color.r, m.color.g, m.color.b, m.color.a, false, true, 2, false, nil, nil, false)
                    end

                    if dist <= Config.Interaction.point.radius then
                        lib.showTextUI(Config.Interaction.point.textUI)
                        if IsControlJustReleased(0, 38) then
                            ExecuteCommand(Config.Commands.finance)
                        end
                    else
                        lib.hideTextUI()
                    end
                else
                    lib.hideTextUI()
                end
            end
            Wait(sleep)
        end
    end)
end

AddEventHandler('onResourceStart', function(name)
    if name ~= resourceName then return end
    setupInteraction()
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= resourceName then return end
    lib.hideTextUI()
    if spawnedNpc and DoesEntityExist(spawnedNpc) then
        DeleteEntity(spawnedNpc)
    end
end)
