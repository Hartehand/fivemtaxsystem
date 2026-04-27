FinanceAnalytics = {}
local businessLookupCache = { expires = 0, rows = {} }

local function getBusinessLookupRows()
    if os.time() < (businessLookupCache.expires or 0) then
        return businessLookupCache.rows or {}
    end

    local rows = MySQL.query.await('SELECT id, type FROM vms_business ORDER BY id ASC') or {}
    businessLookupCache.rows = rows
    businessLookupCache.expires = os.time() + math.max(30, Config.CacheTtlSeconds or 90)
    return rows
end

local function tokenSimilarity(a, b)
    local left = FinanceUtils.normalizeToken(a)
    local right = FinanceUtils.normalizeToken(b)
    if left == '' or right == '' then
        return 0
    end
    if left == right then
        return 1
    end
    if left:find(right, 1, true) or right:find(left, 1, true) then
        return 0.82
    end

    local maxLen = math.max(#left, #right)
    local samePrefix = 0
    for i = 1, math.min(#left, #right) do
        if left:sub(i, i) == right:sub(i, i) then
            samePrefix = samePrefix + 1
        else
            break
        end
    end

    local leftSet, overlap = {}, 0
    for i = 1, #left do leftSet[left:sub(i, i)] = true end
    for i = 1, #right do
        local c = right:sub(i, i)
        if leftSet[c] then overlap = overlap + 1 end
    end

    local prefixScore = samePrefix / maxLen
    local overlapScore = overlap / math.max(#right, 1)
    return (prefixScore * 0.55) + (overlapScore * 0.45)
end

local function getBusinessIndex()
    local rows = MySQL.query.await('SELECT id, type, owner, employees, data FROM vms_business') or {}
    local byId = {}
    for _, row in ipairs(rows) do
        byId[FinanceUtils.normalizeToken(row.id)] = row
    end
    return rows, byId
end

function FinanceAnalytics.resolveDisplayName(identifier, fallback)
    local name = fallback
    local esx = FinanceCore.getESX()

    if Config.Resolver.preferOnlinePlayerName and identifier and esx and esx.GetPlayerFromIdentifier then
        local xPlayer = esx.GetPlayerFromIdentifier(identifier)
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

function FinanceAnalytics.resolveBusinessIdForJob(job, runtimeMap)
    local token = FinanceUtils.normalizeToken(job)
    local map = runtimeMap or {}

    if map[token] then
        return map[token], 'db_map'
    end

    if Config.BusinessJobMap[token] then
        return Config.BusinessJobMap[token], 'config_map'
    end

    if Config.BusinessJobAliases[token] and Config.BusinessJobMap[Config.BusinessJobAliases[token]] then
        return Config.BusinessJobMap[Config.BusinessJobAliases[token]], 'config_alias'
    end

    for _, row in ipairs(getBusinessLookupRows()) do
        local idToken = FinanceUtils.normalizeToken(row.id)
        local typeToken = FinanceUtils.normalizeToken(row.type)
        if token ~= '' and (token == idToken or token == typeToken or idToken:find(token, 1, true) == 1 or token:find(idToken, 1, true) == 1) then
            return row.id, 'auto_business_lookup'
        end
    end

    return job, 'fallback_job_as_id'
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

function FinanceAnalytics.computePrivateTaxRow(row, deadline)
    local isPaid = FinanceUtils.toBoolean(row.is_paid)
    local isCanceled = FinanceUtils.toBoolean(row.canceled)
    local dueDate, dueTs
    local dueSource = 'standard'

    if deadline and deadline.due_date then
        dueDate = deadline.due_date
        dueTs = FinanceUtils.parseDate(dueDate)
        dueSource = 'override'
    else
        dueDate, dueTs = FinanceUtils.dateAddDays(row.received_date, Config.DueDays)
    end

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
        due_source = dueSource,
        title = row.title,
        amount = FinanceUtils.safeNumber(row.amount),
        is_paid = isPaid,
        paid_date = row.paid_date,
        canceled = isCanceled,
        status = status,
        age_days = FinanceUtils.daysBetween(nowTs, FinanceUtils.parseDate(row.received_date)) or 0,
        overdue_days = dueTs and math.max(0, FinanceUtils.daysBetween(nowTs, dueTs) or 0) or 0
    }
end

function FinanceAnalytics.computeBusinessTaxRow(row, deadline)
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

    local dueDate, dueTs, dueSource
    dueSource = 'period_default'

    if deadline and deadline.due_date then
        dueDate = deadline.due_date
        dueTs = FinanceUtils.parseDate(deadline.due_date)
        dueSource = 'override'
    else
        local _, toDate = FinanceUtils.periodToRange(row.period)
        dueDate, dueTs = FinanceUtils.dateAddDays(toDate, Config.DueDays)
    end

    local overdueDays = 0
    if dueTs and os.time() > dueTs and status ~= 'bezahlt' then
        overdueDays = FinanceUtils.daysBetween(os.time(), dueTs) or 0
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
        status = status,
        due_date = dueDate,
        due_source = dueSource,
        overdue_days = overdueDays
    }
end

function FinanceAnalytics.scoreReasons(score, reasons)
    return {
        score = math.min(Config.RiskEngine.scoreCap, math.max(0, FinanceUtils.round(score))),
        band = FinanceUtils.riskBand(score),
        reasons = reasons
    }
end

function FinanceAnalytics.computePrivateRisk(privateRows, reviewByTax)
    local rules = Config.RiskEngine.rules
    local w = Config.RiskEngine.weights

    local openCases, overdueCases, warningStatuses = 0, 0, 0
    local score, reasons = 0, {}

    for _, row in ipairs(privateRows) do
        if row.status ~= 'bezahlt' and row.status ~= 'storniert' then
            openCases = openCases + 1
        end

        if row.status == 'ueberfaellig' then
            overdueCases = overdueCases + 1
        end

        local review = reviewByTax[row.id]
        if review and (review.status == 'mahnfall' or review.status == 'frist_ueberschritten' or review.status == 'auffaellig') then
            warningStatuses = warningStatuses + 1
        end
    end

    if openCases > 0 then
        score = score + math.min(20, openCases * w.openCases)
        reasons[#reasons + 1] = ('%s offene Privatforderungen'):format(openCases)
    end

    if overdueCases > 0 then
        score = score + math.min(30, overdueCases * w.overdueCases)
        reasons[#reasons + 1] = ('%s überfällige Forderungen'):format(overdueCases)
    end

    if warningStatuses > 0 then
        score = score + math.min(20, warningStatuses * w.warningStatuses)
        reasons[#reasons + 1] = ('%s Fälle mit Mahn-/Auffälligkeitsstatus'):format(warningStatuses)
    end

    if openCases >= rules.repeatedOpenPeriods then
        score = score + 10
        reasons[#reasons + 1] = ('%s offene Fälle in Folge'):format(openCases)
    end

    return FinanceAnalytics.scoreReasons(score, reasons)
end

local function txWindowMetrics(transactions)
    local now = os.time()
    local windows = {}
    for _, days in ipairs(Config.RiskEngine.windowsDays) do
        windows[days] = { incoming = 0, outgoing = 0, count = 0, byType = { deposit = 0, withdraw = 0, transfer = 0, other = 0 } }
    end

    for _, tx in ipairs(transactions) do
        local ts = FinanceUtils.parseDate(tx.date)
        if ts then
            local age = FinanceUtils.daysBetween(now, ts) or 9999
            for _, days in ipairs(Config.RiskEngine.windowsDays) do
                if age <= days then
                    windows[days].count = windows[days].count + 1
                    local direction, amount = FinanceUtils.txDirection(tx.type, tx.value)
                    if direction == 'incoming' then
                        windows[days].incoming = windows[days].incoming + amount
                    else
                        windows[days].outgoing = windows[days].outgoing + amount
                    end

                    local txType = tostring(tx.type or ''):lower()
                    if txType ~= 'deposit' and txType ~= 'withdraw' and txType ~= 'transfer' then
                        txType = 'other'
                    end
                    windows[days].byType[txType] = (windows[days].byType[txType] or 0) + 1
                end
            end
        end
    end

    return windows
end

function FinanceAnalytics.computeBusinessRisk(profile, businessTaxes, linkedTransactions, societyBalance, reviewRows)
    local w = Config.RiskEngine.weights
    local rules = Config.RiskEngine.rules

    local openPeriods, partialPayments, delayedSum, lateFeeSum, restDebt = 0, 0, 0, 0, 0
    local score, reasons = 0, {}

    for _, period in ipairs(businessTaxes) do
        if period.status ~= 'bezahlt' and period.restschuld > 0 then
            openPeriods = openPeriods + 1
            restDebt = restDebt + period.restschuld
        end

        if period.status == 'teilweise' then
            partialPayments = partialPayments + 1
        end

        delayedSum = delayedSum + period.delayed_amount
        lateFeeSum = lateFeeSum + period.late_fee_applied
    end

    if openPeriods > 0 then
        score = score + math.min(25, openPeriods * w.repeatedOpenPeriods)
        reasons[#reasons + 1] = ('%s offene Steuerperioden in Folge'):format(openPeriods)
    end

    if partialPayments > 0 then
        score = score + math.min(18, partialPayments * w.partialPayments)
        reasons[#reasons + 1] = ('%s Teilzahlungen statt Vollbegleichung'):format(partialPayments)
    end

    if delayedSum >= rules.delayedAmountHigh then
        score = score + w.delayedAmount
        reasons[#reasons + 1] = ('Hoher Verzugsbetrag: $%s'):format(FinanceUtils.formatMoney(delayedSum))
    end

    if lateFeeSum > 0 then
        score = score + math.min(12, w.lateFees + FinanceUtils.round(lateFeeSum / 5000))
        reasons[#reasons + 1] = ('Late-Fees aktiv: $%s'):format(FinanceUtils.formatMoney(lateFeeSum))
    end

    if societyBalance >= restDebt * rules.enoughBalanceFactor and restDebt > 0 then
        score = score + w.enoughBalanceNoPay
        reasons[#reasons + 1] = 'Kontostand ausreichend, aber Restschuld offen'
    end

    if societyBalance > 0 and restDebt / societyBalance >= rules.debtBalanceRatioHigh then
        score = score + w.debtBalanceRatio
        reasons[#reasons + 1] = ('Restschuld/Kontostand Verhältnis hoch (%.2f)'):format(restDebt / societyBalance)
    end

    if profile.totalEarned > 0 and restDebt / profile.totalEarned >= rules.debtEarnedRatioHigh then
        score = score + w.debtEarnedRatio
        reasons[#reasons + 1] = ('Restschuld/totalEarned Verhältnis hoch (%.2f)'):format(restDebt / profile.totalEarned)
    end

    local windows = txWindowMetrics(linkedTransactions)
    local last7 = windows[7]
    local last30 = windows[30]
    local last90 = windows[90]
    if last7 and last30 and last30.incoming > 0 then
        local extrapolated = last7.incoming * 4
        if extrapolated > (last30.incoming * rules.unusualTxSpikeFactor) then
            score = score + w.unusualTransactionSpike
            reasons[#reasons + 1] = 'Ungewöhnlich hoher Zahlungseingangsanstieg (7d vs 30d)'
        end
    end

    if last30 and last30.incoming >= rules.highIncomingMin and restDebt > 0 and (societyBalance + last30.incoming) > (restDebt * rules.highIncomingUnpaidFactor) then
        score = score + w.incomingWithoutTaxSettlement
        reasons[#reasons + 1] = 'Hohe Zahlungseingänge ohne erkennbare Steuerbegleichung'
    end

    if last90 and last90.byType and last90.byType.withdraw and last90.byType.deposit and last90.byType.withdraw > (last90.byType.deposit * 2) and restDebt > 0 then
        score = score + 8
        reasons[#reasons + 1] = 'Überdurchschnittlich viele Withdraws bei offener Steuerlast'
    end

    local warningStatuses = 0
    for _, r in ipairs(reviewRows or {}) do
        if r.status == 'mahnfall' or r.status == 'auffaellig' or r.status == 'wartet_auf_zuordnung' then
            warningStatuses = warningStatuses + 1
        end
    end

    if warningStatuses > 0 then
        score = score + math.min(15, warningStatuses * w.manualReviewQueue)
        reasons[#reasons + 1] = ('%s manuelle Prüf-/Mahnmarker'):format(warningStatuses)
    end

    return FinanceAnalytics.scoreReasons(score, reasons), {
        openPeriods = openPeriods,
        partialPayments = partialPayments,
        delayedSum = delayedSum,
        lateFeeSum = lateFeeSum,
        restDebt = restDebt,
        txWindows = windows
    }
end

function FinanceAnalytics.matchTransactionToBusiness(tx, job, businessId, societyRows, restDebt, fromDate, toDate)
    local score = 0
    local tokenSender = FinanceUtils.normalizeToken(tx.sender_identifier)
    local tokenReceiver = FinanceUtils.normalizeToken(tx.receiver_identifier)
    local tokenSenderName = FinanceUtils.normalizeToken(tx.sender_name)
    local tokenReceiverName = FinanceUtils.normalizeToken(tx.receiver_name)
    local tokenJob = FinanceUtils.normalizeToken(job)
    local tokenBusiness = FinanceUtils.normalizeToken(businessId)

    local function addIfMatch(token, amount)
        if token ~= '' and (token == tokenSender or token == tokenReceiver or token == tokenSenderName or token == tokenReceiverName) then
            score = score + amount
            return true
        end
        return false
    end

    addIfMatch(tokenJob, 35)
    addIfMatch(tokenBusiness, 30)

    for _, society in ipairs(societyRows or {}) do
        if addIfMatch(FinanceUtils.normalizeToken(society.society), 20) then break end
        if addIfMatch(FinanceUtils.normalizeToken(society.society_name), 15) then break end
    end

    local absValue = math.abs(FinanceUtils.safeNumber(tx.value))
    local direction, _ = FinanceUtils.txDirection(tx.type, tx.value)
    if restDebt > 0 then
        local diffRatio = math.abs(absValue - restDebt) / restDebt
        if diffRatio <= 0.15 then
            score = score + 20
        elseif diffRatio <= 0.35 then
            score = score + 10
        end
    end

    local txDate = FinanceUtils.parseDate(tx.date)
    local fromTs = FinanceUtils.parseDate(fromDate)
    local toTs = FinanceUtils.parseDate(toDate)
    if txDate and fromTs and toTs then
        if txDate >= fromTs and txDate <= toTs then
            score = score + 15
        elseif math.abs(txDate - toTs) <= 20 * 86400 then
            score = score + 8
        end
    end

    if direction == 'incoming' and (tostring(tx.type or ''):lower() == 'deposit' or tostring(tx.type or ''):lower() == 'transfer') then
        score = score + 5
    end

    local quality = 'manuell_pruefen'
    if score >= 70 then
        quality = 'eindeutig'
    elseif score >= 45 then
        quality = 'wahrscheinlich'
    end

    return {
        confidence = math.min(100, score),
        quality = quality
    }
end

function FinanceAnalytics.buildTransactionAnalysis(transactions, openDebt)
    local windows = txWindowMetrics(transactions)
    local reasons = {}
    local score = 0

    local w7, w30, w90 = windows[7] or {}, windows[30] or {}, windows[90] or {}
    local incoming7 = FinanceUtils.safeNumber(w7.incoming)
    local incoming30 = FinanceUtils.safeNumber(w30.incoming)
    local outgoing30 = FinanceUtils.safeNumber(w30.outgoing)
    local incoming90 = FinanceUtils.safeNumber(w90.incoming)

    if incoming30 > 0 and (incoming7 * 4) > (incoming30 * Config.RiskEngine.rules.unusualTxSpikeFactor) then
        score = score + 20
        reasons[#reasons + 1] = 'Ungewöhnlicher Eingangssprung in den letzten 7 Tagen'
    end

    if outgoing30 > incoming30 * 1.5 and openDebt > 0 then
        score = score + 18
        reasons[#reasons + 1] = 'Hohe Ausgänge bei gleichzeitig offener Steuerlast'
    end

    if openDebt > 0 and incoming90 >= openDebt and incoming30 > 0 then
        score = score + 12
        reasons[#reasons + 1] = 'Ausreichende Eingänge, aber offene Steuerlast bleibt bestehen'
    end

    if w30.byType and (w30.byType.transfer or 0) > ((w30.byType.deposit or 0) + (w30.byType.withdraw or 0)) then
        score = score + 8
        reasons[#reasons + 1] = 'Auffällig hoher Transfer-Anteil (30 Tage)'
    end

    local counterpartyTotals = {}
    local dayTotals = {}
    local roundTrip = {}
    local burstIndex = {}
    local totalVolume = 0

    for _, tx in ipairs(transactions or {}) do
        local ts = FinanceUtils.parseDate(tx.date)
        local amount = math.abs(FinanceUtils.safeNumber(tx.value))
        local sender = FinanceUtils.normalizeToken(tx.sender_identifier ~= '' and tx.sender_identifier or tx.sender_name)
        local receiver = FinanceUtils.normalizeToken(tx.receiver_identifier ~= '' and tx.receiver_identifier or tx.receiver_name)
        local cp = sender ~= '' and sender or receiver
        if cp ~= '' then
            counterpartyTotals[cp] = (counterpartyTotals[cp] or 0) + amount
        end
        totalVolume = totalVolume + amount

        if ts then
            local day = os.date('%Y-%m-%d', ts)
            dayTotals[day] = (dayTotals[day] or 0) + amount
            if sender ~= '' and receiver ~= '' then
                local pair = sender .. '|' .. receiver
                local reverse = receiver .. '|' .. sender
                roundTrip[pair] = (roundTrip[pair] or 0) + 1
                if (roundTrip[pair] or 0) >= 2 and (roundTrip[reverse] or 0) >= 2 then
                    score = score + 4
                    reasons[#reasons + 1] = ('Bidirektionale Zahlungszyklen erkannt (%s ↔ %s)'):format(sender, receiver)
                    roundTrip[pair], roundTrip[reverse] = -999, -999
                end
            end

            local burstKey = (cp ~= '' and cp or 'unknown') .. '|' .. tostring(FinanceUtils.round(amount)) .. '|' .. tostring(math.floor(ts / 600))
            burstIndex[burstKey] = (burstIndex[burstKey] or 0) + 1
        end
    end

    if totalVolume > 0 then
        local topShare = 0
        for _, v in pairs(counterpartyTotals) do
            topShare = math.max(topShare, v / totalVolume)
        end
        if topShare >= 0.6 then
            score = score + 10
            reasons[#reasons + 1] = ('Starke Gegenpartei-Konzentration (%.0f%% des Volumens)'):format(topShare * 100)
        elseif topShare >= 0.45 then
            score = score + 6
            reasons[#reasons + 1] = ('Erhöhte Gegenpartei-Konzentration (%.0f%%)'):format(topShare * 100)
        end
    end

    local values, sum = {}, 0
    for _, v in pairs(dayTotals) do
        values[#values + 1] = v
        sum = sum + v
    end
    if #values >= 7 then
        local mean = sum / #values
        local variance = 0
        for _, v in ipairs(values) do
            variance = variance + ((v - mean) * (v - mean))
        end
        variance = variance / #values
        local stddev = math.sqrt(variance)
        if stddev > 0 then
            local spikeDays = 0
            for _, v in ipairs(values) do
                if (v - mean) / stddev >= 2.2 then
                    spikeDays = spikeDays + 1
                end
            end
            if spikeDays >= 2 then
                score = score + math.min(12, spikeDays * 3)
                reasons[#reasons + 1] = ('Mehrere Volumen-Ausreißer erkannt (%s Spike-Tage)'):format(spikeDays)
            end
        end
    end

    local burstCount = 0
    for _, n in pairs(burstIndex) do
        if n >= 3 then
            burstCount = burstCount + 1
        end
    end
    if burstCount > 0 then
        score = score + math.min(10, burstCount * 2)
        reasons[#reasons + 1] = ('Burst-Muster: gleiche Beträge in kurzer Zeit (%s Cluster)'):format(burstCount)
    end

    return FinanceAnalytics.scoreReasons(score, reasons), windows
end

function FinanceAnalytics.inferBusinessForTransaction(tx, businessRows, mapLookup)
    local scores = {}
    local reasons = {}

    local function bump(businessId, value, reason)
        local token = FinanceUtils.normalizeToken(businessId)
        if token == '' then return end
        scores[token] = (scores[token] or 0) + value
        reasons[token] = reasons[token] or {}
        reasons[token][#reasons[token] + 1] = reason
    end

    local senderId = FinanceUtils.normalizeToken(tx.sender_identifier)
    local receiverId = FinanceUtils.normalizeToken(tx.receiver_identifier)
    local senderName = FinanceUtils.normalizeToken(tx.sender_name)
    local receiverName = FinanceUtils.normalizeToken(tx.receiver_name)
    local businessJob = FinanceUtils.normalizeToken(tx.business_job)
    local actorIdentifier = FinanceUtils.normalizeToken(tx.actor_identifier)

    if mapLookup and mapLookup[businessJob] then
        bump(mapLookup[businessJob], 70, 'Job-Mapping')
    end
    if mapLookup and mapLookup[receiverName] then
        bump(mapLookup[receiverName], 45, 'Receiver Name Mapping')
    end
    if mapLookup and mapLookup[senderName] then
        bump(mapLookup[senderName], 35, 'Sender Name Mapping')
    end

    for _, business in ipairs(businessRows or {}) do
        local token = FinanceUtils.normalizeToken(business.id)
        local typeToken = FinanceUtils.normalizeToken(business.type)
        if token ~= '' then
            if token == receiverId or token == senderId then
                bump(business.id, 55, 'Identifier Match')
            end
            if token == receiverName or token == senderName then
                bump(business.id, 35, 'Name Match')
            end
            if token == businessJob then
                bump(business.id, 40, 'Business Job Match')
            end
            if token == actorIdentifier then
                bump(business.id, 25, 'Actor Identifier Match')
            end
        end
        if typeToken ~= '' then
            local typeToReceiver = tokenSimilarity(typeToken, receiverName)
            local typeToSender = tokenSimilarity(typeToken, senderName)
            local idToReceiver = tokenSimilarity(token, receiverName)
            local idToSender = tokenSimilarity(token, senderName)

            if math.max(typeToReceiver, typeToSender) >= 0.74 then
                bump(business.id, 24, 'Type Similarity Match')
            end
            if math.max(idToReceiver, idToSender) >= 0.8 then
                bump(business.id, 20, 'ID Similarity Match')
            end
        end
    end

    local bestToken, bestScore = nil, 0
    for token, score in pairs(scores) do
        if score > bestScore then
            bestToken = token
            bestScore = score
        end
    end

    if not bestToken then
        return { business_id = nil, confidence = 0, mode = 'none', reasons = {} }
    end

    local businessId = bestToken
    for _, business in ipairs(businessRows or {}) do
        if FinanceUtils.normalizeToken(business.id) == bestToken then
            businessId = business.id
            break
        end
    end

    return {
        business_id = businessId,
        confidence = math.min(100, bestScore),
        mode = bestScore >= 70 and 'automatic' or 'suggested',
        reasons = reasons[bestToken] or {},
        evidence_count = #(reasons[bestToken] or {})
    }
end

function FinanceAnalytics.getDashboard()
    local db = rawget(_G, 'FinanceDB')
    if not db then
        return {
            private = { risk = { score = 0, band = 'unauffaellig', reasons = { 'DB-Schicht noch nicht initialisiert' } }, openCount = 0 },
            business = { total = 0, mappedBusinesses = 0, debtorCount = 0, highRiskCount = 0 },
            frequentDebtors = {},
            highRiskCases = {},
            txWindows = {}
        }
    end

    db.cache = db.cache or {}
    local cached = db.cache['dashboard:v2']
    if cached and os.time() < cached.expiresAt then
        return cached.value
    end

    local privateRows = MySQL.query.await('SELECT id, receiver, receiver_name, received_date, title, amount, is_paid, paid_date, canceled FROM taxes') or {}
    local businessRows = MySQL.query.await('SELECT job, job_label, period, amount, paid_amount, delayed_amount, late_fee_applied, is_paid, paid_date FROM taxes_business ORDER BY period DESC') or {}
    local societies = db.fetchSocieties()
    local tx90 = db.fetchTransactionsByDateRange(os.date('%Y-%m-%d', os.time() - 90 * 86400), os.date('%Y-%m-%d'))
    local billing = db.fetchOpenBillingTotals()
    local usersSnapshot = db.fetchUsersEconomicSnapshot()
    local assets = db.fetchAssetSignals()

    local reviewRows = MySQL.query.await('SELECT source_type, source_id, source_key, status FROM doj_finance_reviews') or {}
    local reviewByTax = {}
    for _, r in ipairs(reviewRows) do
        if r.source_type == Config.RecordTypes.taxes then
            reviewByTax[r.source_id] = r
        end
    end

    local privateComputed = {}
    local openPrivateCount, openPrivateAmount = 0, 0
    for _, row in ipairs(privateRows) do
        local deadline = db.fetchDeadline(Config.RecordTypes.taxes, row.id, nil)
        local computed = FinanceAnalytics.computePrivateTaxRow(row, deadline)
        privateComputed[#privateComputed + 1] = computed
        if computed.status ~= 'bezahlt' and computed.status ~= 'storniert' then
            openPrivateCount = openPrivateCount + 1
            openPrivateAmount = openPrivateAmount + FinanceUtils.safeNumber(computed.amount)
        end
    end

    local privateRisk = FinanceAnalytics.computePrivateRisk(privateComputed, reviewByTax)

    local dbMaps, dbLookup = db.fetchBusinessMaps()
    local rawBusinesses, byId = getBusinessIndex()
    local parsedBusinesses = {}
    for _, b in ipairs(rawBusinesses) do
        parsedBusinesses[b.id] = parseBusinessData(b)
    end

    local businessSummary = {}
    local frequentDebtors, highRiskCases = {}, {}
    local openBusinessCount, openBusinessAmount = 0, 0

    for _, row in ipairs(businessRows) do
        local computed = FinanceAnalytics.computeBusinessTaxRow(row, db.fetchDeadline(Config.RecordTypes.taxes_business, nil, FinanceUtils.businessKey(row.job, row.period)))
        local businessId = FinanceAnalytics.resolveBusinessIdForJob(row.job, dbLookup)
        local businessRow = byId[FinanceUtils.normalizeToken(businessId)]
        local profile = businessRow and parseBusinessData(businessRow) or {
            id = businessId,
            type = 'unbekannt',
            owner = 'unbekannt',
            balance = 0,
            totalEarned = 0,
            totalOrders = 0,
            totalSales = 0
        }

        local key = FinanceUtils.normalizeToken(row.job)
        businessSummary[key] = businessSummary[key] or {
            job = row.job,
            job_label = row.job_label,
            business_id = profile.id,
            profile = profile,
            periods = {},
            reviews = {}
        }

        businessSummary[key].periods[#businessSummary[key].periods + 1] = computed
        if computed.status ~= 'bezahlt' and computed.restschuld > 0 then
            openBusinessCount = openBusinessCount + 1
            openBusinessAmount = openBusinessAmount + FinanceUtils.safeNumber(computed.restschuld)
        end
    end

    local societiesByToken = {}
    for _, s in ipairs(societies) do
        societiesByToken[FinanceUtils.normalizeToken(s.society)] = FinanceUtils.safeNumber(s.value)
        societiesByToken[FinanceUtils.normalizeToken(s.society_name)] = FinanceUtils.safeNumber(s.value)
    end

    for _, bundle in pairs(businessSummary) do
        local societyBalance = societiesByToken[FinanceUtils.normalizeToken(bundle.job)] or societiesByToken[FinanceUtils.normalizeToken(bundle.business_id)] or 0
        local relevantTx = {}
        for _, tx in ipairs(tx90) do
            local match = FinanceAnalytics.matchTransactionToBusiness(tx, bundle.job, bundle.business_id, societies, 0, nil, nil)
            if match.confidence >= 35 then
                relevantTx[#relevantTx + 1] = tx
            end
        end

        local businessReviews = MySQL.query.await('SELECT status FROM doj_finance_reviews WHERE source_type = ? AND (source_key LIKE ? OR source_key LIKE ?)', {
            Config.RecordTypes.taxes_business,
            bundle.job .. '|%',
            FinanceUtils.normalizeToken(bundle.business_id) .. '|%'
        }) or {}

        local risk, meta = FinanceAnalytics.computeBusinessRisk(bundle.profile, bundle.periods, relevantTx, societyBalance, businessReviews)
        bundle.risk = risk
        bundle.meta = meta
        bundle.society_balance = societyBalance

        if meta.openPeriods >= 2 then
            frequentDebtors[#frequentDebtors + 1] = bundle
        end

        if risk.score >= Config.RiskEngine.thresholds.high then
            highRiskCases[#highRiskCases + 1] = bundle
        end
    end

    table.sort(frequentDebtors, function(a, b) return (a.meta.restDebt or 0) > (b.meta.restDebt or 0) end)
    table.sort(highRiskCases, function(a, b) return (a.risk.score or 0) > (b.risk.score or 0) end)

    local topPrivateDebtors = {}
    for _, row in ipairs(privateComputed) do
        if row.status ~= 'bezahlt' and row.status ~= 'storniert' then
            topPrivateDebtors[#topPrivateDebtors + 1] = row
        end
    end
    table.sort(topPrivateDebtors, function(a, b) return FinanceUtils.safeNumber(a.amount) > FinanceUtils.safeNumber(b.amount) end)

    local personSignals = {}
    for _, user in ipairs(usersSnapshot) do
        local identifier = user.identifier
        if identifier and identifier ~= '' then
            local fullName = ((user.firstname or '') .. ' ' .. (user.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
            personSignals[identifier] = personSignals[identifier] or {
                identifier = identifier,
                name = fullName ~= '' and fullName or identifier,
                job = user.job,
                score = 0,
                reasons = {}
            }
        end
    end

    for _, bill in ipairs(billing.top or {}) do
        local ident = bill.identifier
        if ident and personSignals[ident] then
            personSignals[ident].score = personSignals[ident].score + math.min(30, math.floor(FinanceUtils.safeNumber(bill.amount) / 2000))
            personSignals[ident].reasons[#personSignals[ident].reasons + 1] = ('Offene Rechnung: $%s'):format(FinanceUtils.formatMoney(bill.amount))
        end
    end

    for _, vehicle in ipairs(assets.vehicles or {}) do
        local ident = vehicle.owner
        if ident and personSignals[ident] then
            personSignals[ident].score = personSignals[ident].score + 2
            if #personSignals[ident].reasons < 5 then
                personSignals[ident].reasons[#personSignals[ident].reasons + 1] = 'Fahrzeugbesitz in Vermögensprofil'
            end
        end
    end

    for _, bankTx in ipairs(assets.banking or {}) do
        local ident = bankTx.identifier
        if ident and personSignals[ident] then
            local amount = math.abs(FinanceUtils.safeNumber(bankTx.amount))
            if amount >= 25000 then
                personSignals[ident].score = personSignals[ident].score + 4
                if #personSignals[ident].reasons < 6 then
                    personSignals[ident].reasons[#personSignals[ident].reasons + 1] = ('Hohe Banking-Bewegung: $%s'):format(FinanceUtils.formatMoney(amount))
                end
            end
        end
    end

    for _, doc in ipairs(assets.documents or {}) do
        local owner = doc.owner
        if owner and personSignals[owner] and FinanceUtils.toBoolean(doc.valid) == false then
            personSignals[owner].score = personSignals[owner].score + 2
            if #personSignals[owner].reasons < 6 then
                personSignals[owner].reasons[#personSignals[owner].reasons + 1] = 'Ungültige/auffällige Dokumente'
            end
        end
    end

    local suspiciousPeople = {}
    for _, profile in pairs(personSignals) do
        if profile.score > 0 then
            suspiciousPeople[#suspiciousPeople + 1] = profile
        end
    end
    table.sort(suspiciousPeople, function(a, b) return a.score > b.score end)

    local suspiciousCompanies = {}
    local societyLiquidity = {}
    for _, acc in ipairs(assets.societyAccounts or {}) do
        local t1 = FinanceUtils.normalizeToken(acc.account_name)
        local t2 = FinanceUtils.normalizeToken(acc.owner)
        local money = FinanceUtils.safeNumber(acc.money)
        if t1 ~= '' then societyLiquidity[t1] = math.max(societyLiquidity[t1] or 0, money) end
        if t2 ~= '' then societyLiquidity[t2] = math.max(societyLiquidity[t2] or 0, money) end
    end

    for _, bundle in ipairs(highRiskCases) do
        local addScore = 0
        local reasons = {}
        local liq = societyLiquidity[FinanceUtils.normalizeToken(bundle.business_id)] or societyLiquidity[FinanceUtils.normalizeToken(bundle.job)] or 0
        if bundle.meta and FinanceUtils.safeNumber(bundle.meta.restDebt) > 0 and FinanceUtils.safeNumber(bundle.society_balance) > (bundle.meta.restDebt * 1.2) then
            addScore = addScore + 18
            reasons[#reasons + 1] = 'Hohe Liquidität trotz Restschuld'
        end
        if bundle.meta and FinanceUtils.safeNumber(bundle.meta.restDebt) > 0 and liq > (bundle.meta.restDebt * 1.1) then
            addScore = addScore + 10
            reasons[#reasons + 1] = 'Addon-Account Liquidität über Restschuld'
        end
        if (bundle.meta and bundle.meta.txWindows and bundle.meta.txWindows[30] and bundle.meta.txWindows[30].incoming or 0) > 50000 and (bundle.meta and bundle.meta.restDebt or 0) > 0 then
            addScore = addScore + 12
            reasons[#reasons + 1] = 'Hoher 30-Tage-Cashflow bei offener Steuerlast'
        end
        suspiciousCompanies[#suspiciousCompanies + 1] = {
            business_id = bundle.business_id,
            job = bundle.job,
            job_label = bundle.job_label,
            score = (bundle.risk and bundle.risk.score or 0) + addScore,
            reasons = reasons
        }
    end
    table.sort(suspiciousCompanies, function(a, b) return a.score > b.score end)

    local upcomingDeadlines = {}
    if db.tableExists and db.tableExists('doj_finance_deadlines') then
        upcomingDeadlines = MySQL.query.await([[
            SELECT source_type, source_id, source_key, due_date, reason
            FROM doj_finance_deadlines
            WHERE due_date BETWEEN CURDATE() AND DATE_ADD(CURDATE(), INTERVAL 14 DAY)
            ORDER BY due_date ASC
            LIMIT 50
        ]]) or {}
    end

    local unresolvedPayments = {}
    if db.tableExists and db.tableExists('doj_finance_transaction_map') then
        unresolvedPayments = MySQL.query.await([[
            SELECT l.id, l.transaction_table, l.transaction_id, l.business_id, l.updated_at
            FROM doj_finance_transaction_map l
            WHERE l.business_id IS NULL OR l.business_id = ''
            ORDER BY l.updated_at DESC
            LIMIT 40
        ]]) or {}
    end

    local result = {
        private = {
            risk = privateRisk,
            openCount = openPrivateCount,
            openAmount = openPrivateAmount,
            topDebtors = { table.unpack(topPrivateDebtors, 1, math.min(10, #topPrivateDebtors)) }
        },
        business = {
            total = #businessRows,
            mappedBusinesses = #dbMaps,
            debtorCount = #frequentDebtors,
            highRiskCount = #highRiskCases,
            openCount = openBusinessCount,
            openAmount = openBusinessAmount,
            topDebtors = { table.unpack(frequentDebtors, 1, math.min(10, #frequentDebtors)) }
        },
        billing = billing,
        suspiciousPeople = { table.unpack(suspiciousPeople, 1, math.min(10, #suspiciousPeople)) },
        suspiciousCompanies = { table.unpack(suspiciousCompanies, 1, math.min(10, #suspiciousCompanies)) },
        worklists = {
            heute_pruefen = { table.unpack(highRiskCases, 1, math.min(10, #highRiskCases)) },
            bald_faellig = upcomingDeadlines,
            mahnen = (function()
                local out = {}
                for _, b in ipairs(frequentDebtors) do
                    if b.meta and (b.meta.openPeriods or 0) >= 2 then out[#out + 1] = b end
                    if #out >= 10 then break end
                end
                return out
            end)(),
            ungeklaerte_zahlung = unresolvedPayments
        },
        externalSignals = {
            vehicles = #(assets.vehicles or {}),
            cityhallCharges = #(assets.charges or {}),
            dojCases = #(assets.dojCases or {}),
            banking = #(assets.banking or {}),
            documents = #(assets.documents or {})
        },
        frequentDebtors = frequentDebtors,
        highRiskCases = highRiskCases,
        txWindows = txWindowMetrics(tx90)
    }

    db.cache['dashboard:v2'] = { value = result, expiresAt = os.time() + Config.CacheTtlSeconds }
    return result
end
