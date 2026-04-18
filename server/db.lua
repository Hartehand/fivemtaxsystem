FinanceDB = { cache = {} }
FinanceDB.schema = { tableExists = {}, tableColumns = {} }

local function nowSeconds()
    return os.time()
end

function FinanceDB.invalidateCache(prefix)
    if not prefix then
        FinanceDB.cache = {}
        return
    end

    for key in pairs(FinanceDB.cache) do
        if key:find(prefix, 1, true) == 1 then
            FinanceDB.cache[key] = nil
        end
    end
end

local function readCache(cacheKey)
    local entry = FinanceDB.cache[cacheKey]
    if entry and nowSeconds() < entry.expiresAt then
        return entry.value
    end

    return nil
end

local function writeCache(cacheKey, value, ttl)
    FinanceDB.cache[cacheKey] = {
        value = value,
        expiresAt = nowSeconds() + (ttl or Config.CacheTtlSeconds)
    }
end

function FinanceDB.cachedFetch(cacheKey, ttl, query, params)
    local cached = readCache(cacheKey)
    if cached then
        return cached
    end

    local rows = MySQL.query.await(query, params or {}) or {}
    writeCache(cacheKey, rows, ttl)
    return rows
end

function FinanceDB.fetchPrivateTaxes(filters, page, pageSize)
    local clauses, params = { '1=1' }, {}
    filters = filters or {}

    if filters.status == 'offen' then
        clauses[#clauses + 1] = 'is_paid = 0 AND canceled = 0'
    elseif filters.status == 'bezahlt' then
        clauses[#clauses + 1] = 'is_paid = 1'
    elseif filters.status == 'storniert' then
        clauses[#clauses + 1] = 'canceled = 1'
    end

    if filters.receiver and filters.receiver ~= '' then
        clauses[#clauses + 1] = 'receiver = ?'
        params[#params + 1] = filters.receiver
    end

    if filters.search and filters.search ~= '' then
        clauses[#clauses + 1] = '(receiver LIKE ? OR receiver_name LIKE ? OR title LIKE ?)'
        local wildcard = ('%%%s%%'):format(filters.search)
        params[#params + 1] = wildcard
        params[#params + 1] = wildcard
        params[#params + 1] = wildcard
    end

    local where = table.concat(clauses, ' AND ')
    local _, limit, offset = FinanceUtils.clampPage(page, pageSize)
    local count = MySQL.scalar.await(('SELECT COUNT(*) FROM taxes WHERE %s'):format(where), params) or 0

    params[#params + 1] = limit
    params[#params + 1] = offset
    local rows = MySQL.query.await(([[
        SELECT id, receiver, receiver_name, received_date, title, amount, is_paid, paid_date, canceled
        FROM taxes
        WHERE %s
        ORDER BY received_date DESC, id DESC
        LIMIT ? OFFSET ?
    ]]):format(where), params) or {}

    return rows, count
end

function FinanceDB.fetchBusinessTaxes(filters, page, pageSize)
    local clauses, params = { '1=1' }, {}
    filters = filters or {}

    if filters.job and filters.job ~= '' then
        clauses[#clauses + 1] = 'job = ?'
        params[#params + 1] = filters.job
    end

    if filters.status == 'offen' then
        clauses[#clauses + 1] = 'is_paid = 0'
    elseif filters.status == 'bezahlt' then
        clauses[#clauses + 1] = 'is_paid = 1'
    elseif filters.status == 'teilweise' then
        clauses[#clauses + 1] = 'is_paid = 0 AND paid_amount > 0'
    end

    local where = table.concat(clauses, ' AND ')
    local _, limit, offset = FinanceUtils.clampPage(page, pageSize)
    local count = MySQL.scalar.await(('SELECT COUNT(*) FROM taxes_business WHERE %s'):format(where), params) or 0

    params[#params + 1] = limit
    params[#params + 1] = offset
    local rows = MySQL.query.await(([[
        SELECT job, job_label, period, amount, paid_amount, delayed_amount, late_fee_applied, is_paid, paid_date
        FROM taxes_business
        WHERE %s
        ORDER BY period DESC, job ASC
        LIMIT ? OFFSET ?
    ]]):format(where), params) or {}

    return rows, count
end

function FinanceDB.fetchBusinessProfiles(page, pageSize)
    local _, limit, offset = FinanceUtils.clampPage(page, pageSize)
    local rows = MySQL.query.await('SELECT id, type, owner, employees, data FROM vms_business ORDER BY id ASC LIMIT ? OFFSET ?', { limit, offset }) or {}
    local total = MySQL.scalar.await('SELECT COUNT(*) FROM vms_business') or 0
    return rows, total
end

function FinanceDB.fetchBusinessById(businessId)
    return MySQL.single.await('SELECT id, type, owner, employees, stock, data, announcements, orders, history FROM vms_business WHERE id = ?', { businessId })
end

function FinanceDB.fetchAllBusinessRefs()
    return MySQL.query.await('SELECT id, type, owner FROM vms_business ORDER BY id ASC') or {}
end

function FinanceDB.fetchSocieties()
    return FinanceDB.cachedFetch('societies:all', Config.CacheTtlSeconds, [[
        SELECT society, society_name, value, iban, is_withdrawing
        FROM okokbanking_societies
        ORDER BY society_name ASC
    ]])
end

function FinanceDB.tableExists(tableName)
    if FinanceDB.schema.tableExists[tableName] ~= nil then
        return FinanceDB.schema.tableExists[tableName]
    end

    local exists = MySQL.scalar.await([[
        SELECT COUNT(*)
        FROM information_schema.tables
        WHERE table_schema = DATABASE() AND table_name = ?
    ]], { tableName }) or 0

    local value = exists > 0
    FinanceDB.schema.tableExists[tableName] = value
    return value
end

function FinanceDB.fetchTableColumns(tableName)
    if FinanceDB.schema.tableColumns[tableName] then
        return FinanceDB.schema.tableColumns[tableName]
    end

    if not FinanceDB.tableExists(tableName) then
        FinanceDB.schema.tableColumns[tableName] = {}
        return {}
    end

    local rows = MySQL.query.await('SHOW COLUMNS FROM `' .. tableName .. '`') or {}
    local columns = {}
    for _, row in ipairs(rows) do
        columns[tostring(row.Field)] = true
    end
    FinanceDB.schema.tableColumns[tableName] = columns
    return columns
end

local function pickColumn(columns, names)
    for _, key in ipairs(names) do
        if columns[key] then
            return '`' .. key .. '`'
        end
    end
    return 'NULL'
end

function FinanceDB.fetchBossmenuTransactions(filters)
    filters = filters or {}
    local tableName = 'bossmenu_transactions'
    if not FinanceDB.tableExists(tableName) then
        return {}
    end

    local cols = FinanceDB.fetchTableColumns(tableName)
    if not cols.id then
        return {}
    end

    local clauses, params = { '1=1' }, {}
    local searchExpr = {
        pickColumn(cols, { 'society', 'job' }),
        pickColumn(cols, { 'name', 'player_name', 'author_name' }),
        pickColumn(cols, { 'identifier', 'player_identifier', 'author_identifier' })
    }

    if filters.search and filters.search ~= '' then
        local w = ('%%%s%%'):format(filters.search)
        local likes = {}
        for _, expr in ipairs(searchExpr) do
            if expr ~= 'NULL' then
                likes[#likes + 1] = expr .. ' LIKE ?'
                params[#params + 1] = w
            end
        end
        if #likes > 0 then
            clauses[#clauses + 1] = '(' .. table.concat(likes, ' OR ') .. ')'
        end
    end

    local typeExpr = pickColumn(cols, { 'type', 'action', 'transaction_type' })
    if filters.type and filters.type ~= '' and typeExpr ~= 'NULL' then
        clauses[#clauses + 1] = ('LOWER(%s) = ?'):format(typeExpr)
        params[#params + 1] = tostring(filters.type):lower()
    end

    local where = table.concat(clauses, ' AND ')
    local rows = MySQL.query.await(([[
        SELECT
            `id` AS id,
            %s AS business_job,
            %s AS actor_name,
            %s AS actor_identifier,
            %s AS tx_type,
            %s AS amount,
            %s AS tx_reason,
            %s AS tx_date
        FROM `%s`
        WHERE %s
        ORDER BY `id` DESC
        LIMIT 2000
    ]]):format(
        pickColumn(cols, { 'society', 'job' }),
        pickColumn(cols, { 'name', 'player_name', 'author_name' }),
        pickColumn(cols, { 'identifier', 'player_identifier', 'author_identifier' }),
        typeExpr,
        pickColumn(cols, { 'amount', 'value' }),
        pickColumn(cols, { 'reason', 'description', 'label' }),
        pickColumn(cols, { 'date', 'created_at', 'time', 'timestamp' }),
        tableName,
        where
    ), params) or {}

    local out = {}
    for _, row in ipairs(rows) do
        local dateValue = row.tx_date
        if type(dateValue) == 'number' then
            dateValue = os.date('%Y-%m-%d %H:%M:%S', dateValue)
        end

        out[#out + 1] = {
            id = row.id,
            source_table = tableName,
            source_label = 'Bossmenu',
            business_job = row.business_job,
            receiver_identifier = row.business_job,
            receiver_name = row.business_job,
            sender_identifier = row.actor_identifier,
            sender_name = row.actor_name,
            actor_identifier = row.actor_identifier,
            actor_name = row.actor_name,
            type = row.tx_type,
            value = FinanceUtils.safeNumber(row.amount),
            reason = row.tx_reason,
            date = dateValue
        }
    end

    return out
end

function FinanceDB.fetchTransactions(filters, page, pageSize)
    local clauses, params = { '1=1' }, {}
    filters = filters or {}

    if filters.search and filters.search ~= '' then
        clauses[#clauses + 1] = '(receiver_identifier LIKE ? OR receiver_name LIKE ? OR sender_identifier LIKE ? OR sender_name LIKE ?)'
        local w = ('%%%s%%'):format(filters.search)
        params[#params + 1] = w
        params[#params + 1] = w
        params[#params + 1] = w
        params[#params + 1] = w
    end

    local where = table.concat(clauses, ' AND ')
    local seedRows = MySQL.query.await(([[
        SELECT id, receiver_identifier, receiver_name, sender_identifier, sender_name, date, value, type
        FROM okokbanking_transactions
        WHERE %s
        ORDER BY date DESC, id DESC
        LIMIT 2000
    ]]):format(where), params) or {}
    for _, row in ipairs(seedRows) do
        row.source_table = 'okokbanking_transactions'
        row.source_label = 'Okokbanking'
    end

    if (filters.source or '') ~= 'okokbanking_transactions' then
        local bossRows = FinanceDB.fetchBossmenuTransactions(filters)
        for _, row in ipairs(bossRows) do
            seedRows[#seedRows + 1] = row
        end
    end

    local fromTs = FinanceUtils.parseDate(filters.from)
    local toTs = FinanceUtils.parseDate(filters.to)
    local filtered = {}
    for _, row in ipairs(seedRows) do
        local txTs = FinanceUtils.parseDate(row.date)
        local txValue = math.abs(FinanceUtils.safeNumber(row.value))
        local joined = FinanceUtils.normalizeToken((row.sender_name or '') .. ' ' .. (row.receiver_name or '') .. ' ' .. (row.sender_identifier or '') .. ' ' .. (row.receiver_identifier or '') .. ' ' .. (row.business_job or ''))
        local valid = true
        if filters.source and filters.source ~= '' and row.source_table ~= filters.source then
            valid = false
        end
        if fromTs and txTs and txTs < fromTs then valid = false end
        if toTs and txTs and txTs > toTs then valid = false end
        if (fromTs or toTs) and not txTs then valid = false end
        if filters.min_amount and filters.min_amount ~= '' and txValue < FinanceUtils.safeNumber(filters.min_amount) then valid = false end
        if filters.max_amount and filters.max_amount ~= '' and txValue > FinanceUtils.safeNumber(filters.max_amount) then valid = false end
        if filters.entity and filters.entity ~= '' and joined:find(FinanceUtils.normalizeToken(filters.entity), 1, true) == nil then valid = false end
        if valid then filtered[#filtered + 1] = row end
    end

    table.sort(filtered, function(a, b)
        local aTs = FinanceUtils.parseDate(a.date) or 0
        local bTs = FinanceUtils.parseDate(b.date) or 0
        if aTs == bTs then
            return FinanceUtils.safeNumber(a.id) > FinanceUtils.safeNumber(b.id)
        end
        return aTs > bTs
    end)

    local _, limit, offset = FinanceUtils.clampPage(page, pageSize)
    local count = #filtered
    local rows = {}
    for i = offset + 1, math.min(offset + limit, #filtered) do
        rows[#rows + 1] = filtered[i]
    end

    return rows, count
end

function FinanceDB.fetchOpenBillingTotals()
    if not FinanceDB.tableExists('billing') then
        return { total = 0, count = 0, top = {} }
    end

    local rows = MySQL.query.await([[
        SELECT identifier, sender, target_type, target, label, amount
        FROM billing
        ORDER BY amount DESC
        LIMIT 300
    ]]) or {}

    local total = 0
    local top = {}
    for i, row in ipairs(rows) do
        local amount = FinanceUtils.safeNumber(row.amount)
        total = total + amount
        if i <= 10 then
            top[#top + 1] = row
        end
    end

    return { total = total, count = #rows, top = top }
end

function FinanceDB.fetchUsersEconomicSnapshot()
    if not FinanceDB.tableExists('users') then
        return {}
    end

    return MySQL.query.await([[
        SELECT identifier, iban, job, firstname, lastname, accounts, cityhall_data, metadata, created_at, last_seen
        FROM users
        ORDER BY last_seen DESC
        LIMIT 1200
    ]]) or {}
end

function FinanceDB.fetchAssetSignals()
    local out = { vehicles = {}, sold = {}, societyAccounts = {}, charges = {}, dojCases = {}, banking = {}, documents = {} }

    if FinanceDB.tableExists('owned_vehicles') then
        out.vehicles = MySQL.query.await('SELECT owner, owner_name, company, vehicle, plate, parking_date FROM owned_vehicles ORDER BY parking_date DESC LIMIT 1500') or {}
    end
    if FinanceDB.tableExists('vehicle_sold') then
        out.sold = MySQL.query.await('SELECT client, model, plate, soldby, date FROM vehicle_sold ORDER BY id DESC LIMIT 1200') or {}
    end
    if FinanceDB.tableExists('addon_account_data') then
        out.societyAccounts = MySQL.query.await('SELECT account_name, money, owner FROM addon_account_data ORDER BY money DESC LIMIT 600') or {}
    end
    if FinanceDB.tableExists('vms_cityhall_wasabi_bridge_sync') then
        out.charges = MySQL.query.await('SELECT target_identifier, target_name, officer_identifier, officer_name, status, created_at FROM vms_cityhall_wasabi_bridge_sync ORDER BY id DESC LIMIT 1000') or {}
    end
    if FinanceDB.tableExists('doj_cases') then
        out.dojCases = MySQL.query.await('SELECT id, case_number, status, priority, lead_identifier, lead_name, created_at, updated_at FROM doj_cases ORDER BY id DESC LIMIT 1000') or {}
    end
    if FinanceDB.tableExists('banking') then
        out.banking = MySQL.query.await('SELECT identifier, type, amount, time, balance, label FROM banking ORDER BY ID DESC LIMIT 3000') or {}
    end
    if FinanceDB.tableExists('player_documents') then
        out.documents = MySQL.query.await('SELECT serial_number, owner, type, valid, for_pickup FROM player_documents ORDER BY serial_number DESC LIMIT 2000') or {}
    end

    return out
end

function FinanceDB.fetchTransactionAssignments(transactionRefs)
    if not FinanceDB.tableExists('doj_finance_transaction_map') then
        return {}
    end

    transactionRefs = transactionRefs or {}
    if #transactionRefs == 0 then
        return {}
    end

    local keys, params = {}, {}
    for _, ref in ipairs(transactionRefs) do
        keys[#keys + 1] = '(transaction_table = ? AND transaction_id = ?)'
        params[#params + 1] = ref.transaction_table
        params[#params + 1] = ref.transaction_id
    end

    local rows = MySQL.query.await(([[
        SELECT transaction_table, transaction_id, business_id, assignment_mode, comment, assigned_by, updated_at
        FROM doj_finance_transaction_map
        WHERE %s
    ]]):format(table.concat(keys, ' OR ')), params) or {}

    local out = {}
    for _, row in ipairs(rows) do
        out[(row.transaction_table or '') .. ':' .. tostring(row.transaction_id)] = row
    end
    return out
end

function FinanceDB.upsertTransactionAssignment(payload)
    if not FinanceDB.tableExists('doj_finance_transaction_map') then
        return nil
    end

    return MySQL.insert.await([[
        INSERT INTO doj_finance_transaction_map (transaction_table, transaction_id, business_id, assignment_mode, comment, assigned_by)
        VALUES (?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            business_id = VALUES(business_id),
            assignment_mode = VALUES(assignment_mode),
            comment = VALUES(comment),
            assigned_by = VALUES(assigned_by),
            updated_at = CURRENT_TIMESTAMP
    ]], {
        payload.transaction_table,
        payload.transaction_id,
        payload.business_id,
        payload.assignment_mode,
        payload.comment,
        payload.assigned_by
    })
end

function FinanceDB.fetchTransactionsByDateRange(fromDate, toDate)
    local rows = MySQL.query.await([[
        SELECT id, receiver_identifier, receiver_name, sender_identifier, sender_name, date, value, type
        FROM okokbanking_transactions
        ORDER BY date DESC, id DESC
        LIMIT 5000
    ]]) or {}

    local fromTs = FinanceUtils.parseDate(fromDate)
    local toTs = FinanceUtils.parseDate(toDate)
    local filtered = {}
    for _, row in ipairs(rows) do
        local ts = FinanceUtils.parseDate(row.date)
        if ts then
            local valid = true
            if fromTs and ts < fromTs then valid = false end
            if toTs and ts > toTs then valid = false end
            if valid then filtered[#filtered + 1] = row end
        end
    end

    return filtered
end

function FinanceDB.fetchSinglePrivateTax(id)
    return MySQL.single.await('SELECT id, receiver, receiver_name, received_date, title, amount, is_paid, paid_date, canceled FROM taxes WHERE id = ?', { id })
end

function FinanceDB.fetchSingleBusinessTax(job, period)
    return MySQL.single.await('SELECT job, job_label, period, amount, paid_amount, delayed_amount, late_fee_applied, is_paid, paid_date FROM taxes_business WHERE job = ? AND period = ?', {
        job,
        period
    })
end

function FinanceDB.fetchBusinessTaxHistory(job)
    return MySQL.query.await('SELECT job, job_label, period, amount, paid_amount, delayed_amount, late_fee_applied, is_paid, paid_date FROM taxes_business WHERE job = ? ORDER BY period DESC', {
        job
    }) or {}
end

function FinanceDB.fetchReviewBySource(sourceType, sourceId, sourceKey)
    return MySQL.single.await('SELECT id, status, priority, assigned_to, evidence, doj_case_id, follow_up_at, created_at, updated_at FROM doj_finance_reviews WHERE source_type = ? AND source_id <=> ? AND source_key <=> ?', {
        sourceType,
        sourceId,
        sourceKey
    })
end

function FinanceDB.fetchReviewBundle(sourceType, sourceId, sourceKey)
    local review = FinanceDB.fetchReviewBySource(sourceType, sourceId, sourceKey)
    if not review then
        return { review = nil, notes = {}, audit = {} }
    end

    local notes = MySQL.query.await('SELECT id, author_identifier, note, is_internal, created_at FROM doj_finance_notes WHERE review_id = ? ORDER BY id DESC', {
        review.id
    }) or {}

    local audit = MySQL.query.await('SELECT id, action, actor_identifier, payload, created_at FROM doj_finance_auditlog WHERE source_type = ? AND source_id <=> ? AND source_key <=> ? ORDER BY id DESC LIMIT ?', {
        sourceType,
        sourceId,
        sourceKey,
        Config.MaxAuditRows
    }) or {}

    local caseLinks = {}
    if FinanceDB.tableExists('doj_finance_case_links') then
        caseLinks = MySQL.query.await('SELECT id, review_id, doj_case_id, doj_case_number, link_type, created_by, created_at FROM doj_finance_case_links WHERE review_id = ? ORDER BY id DESC', {
            review.id
        }) or {}
    end

    if review and review.evidence then
        review.evidence = FinanceUtils.safeDecode(review.evidence)
    end

    return { review = review, notes = notes, audit = audit, case_links = caseLinks }
end

function FinanceDB.updateReviewMeta(reviewId, payload)
    MySQL.update.await([[
        UPDATE doj_finance_reviews
        SET priority = ?, evidence = ?, doj_case_id = ?, follow_up_at = ?, assigned_to = COALESCE(?, assigned_to), updated_at = CURRENT_TIMESTAMP
        WHERE id = ?
    ]], {
        payload.priority,
        json.encode(payload.evidence or {}),
        payload.doj_case_id,
        payload.follow_up_at,
        payload.assigned_to,
        reviewId
    })
end

function FinanceDB.upsertCaseLink(reviewId, dojCaseId, dojCaseNumber, linkType, createdBy)
    if not FinanceDB.tableExists('doj_finance_case_links') then return nil end
    return MySQL.insert.await([[
        INSERT INTO doj_finance_case_links (review_id, doj_case_id, doj_case_number, link_type, created_by)
        VALUES (?, ?, ?, ?, ?)
    ]], { reviewId, dojCaseId, dojCaseNumber, linkType or 'related', createdBy })
end

function FinanceDB.fetchCaseTimeline(sourceType, sourceId, sourceKey)
    local bundle = FinanceDB.fetchReviewBundle(sourceType, sourceId, sourceKey)
    local timeline = {}
    for _, a in ipairs(bundle.audit or {}) do
        timeline[#timeline + 1] = { kind = 'audit', created_at = a.created_at, title = a.action, payload = FinanceUtils.safeDecode(a.payload) }
    end
    for _, n in ipairs(bundle.notes or {}) do
        timeline[#timeline + 1] = { kind = 'note', created_at = n.created_at, title = n.author_identifier, payload = { note = n.note, is_internal = n.is_internal } }
    end
    for _, l in ipairs(bundle.case_links or {}) do
        timeline[#timeline + 1] = { kind = 'doj_link', created_at = l.created_at, title = l.doj_case_number or tostring(l.doj_case_id or '-'), payload = l }
    end
    local deadline = FinanceDB.fetchDeadline(sourceType, sourceId, sourceKey)
    if deadline then
        timeline[#timeline + 1] = { kind = 'deadline', created_at = deadline.updated_at or deadline.created_at, title = deadline.due_date, payload = deadline }
    end

    table.sort(timeline, function(a, b)
        return tostring(a.created_at or '') > tostring(b.created_at or '')
    end)
    return timeline
end

function FinanceDB.fetchBusinessLinkProfile(businessId)
    local business = FinanceDB.fetchBusinessById(businessId)
    if not business then
        return nil
    end

    local ownerData = FinanceUtils.safeDecode(business.owner)
    local employeesData = FinanceUtils.safeDecode(business.employees)
    local owners, employees = {}, {}

    local function collectIdentifiers(src, out)
        if type(src) == 'table' then
            for _, v in pairs(src) do
                if type(v) == 'table' then
                    local ident = v.identifier or v.owner or v.id
                    if ident then out[#out + 1] = tostring(ident) end
                elseif type(v) == 'string' then
                    out[#out + 1] = v
                end
            end
        elseif type(src) == 'string' and src ~= '' then
            out[#out + 1] = src
        end
    end

    collectIdentifiers(ownerData, owners)
    collectIdentifiers(employeesData, employees)

    local ownerSet = {}
    for _, id in ipairs(owners) do ownerSet[id] = true end

    local usersRows, vehiclesRows, casesRows, societiesRows = {}, {}, {}, {}
    if FinanceDB.tableExists('users') then
        local base = MySQL.query.await('SELECT identifier, firstname, lastname, job, iban, phone_number FROM users WHERE lower(job) = lower(?) LIMIT 400', { businessId }) or {}
        for _, u in ipairs(base) do
            if ownerSet[u.identifier] or tostring(u.job or ''):lower() == tostring(businessId):lower() then
                usersRows[#usersRows + 1] = u
            end
        end
    end
    if FinanceDB.tableExists('owned_vehicles') then
        local base = MySQL.query.await('SELECT owner, owner_name, company, plate, vehicle, parking_date FROM owned_vehicles WHERE lower(company) = lower(?) LIMIT 600', { businessId }) or {}
        for _, v in ipairs(base) do
            if ownerSet[v.owner] or tostring(v.company or ''):lower() == tostring(businessId):lower() then
                vehiclesRows[#vehiclesRows + 1] = v
            end
        end
    end
    if FinanceDB.tableExists('doj_cases') then
        local base = MySQL.query.await('SELECT id, case_number, status, priority, lead_identifier, lead_name, updated_at FROM doj_cases ORDER BY id DESC LIMIT 600') or {}
        for _, c in ipairs(base) do
            if ownerSet[c.lead_identifier] then
                casesRows[#casesRows + 1] = c
            end
        end
    end
    if FinanceDB.tableExists('okokbanking_societies') then
        societiesRows = MySQL.query.await('SELECT society, society_name, value, iban FROM okokbanking_societies WHERE lower(society) = lower(?) OR lower(society_name) = lower(?) LIMIT 50', {
            businessId,
            businessId
        }) or {}
    end

    return {
        business = business,
        owners = owners,
        employees = employees,
        users = usersRows,
        vehicles = vehiclesRows,
        doj_cases = casesRows,
        societies = societiesRows
    }
end

function FinanceDB.fetchDeadline(sourceType, sourceId, sourceKey)
    return MySQL.single.await('SELECT id, due_date, is_overridden, reason, updated_by, created_at, updated_at FROM doj_finance_deadlines WHERE source_type = ? AND source_id <=> ? AND source_key <=> ?', {
        sourceType,
        sourceId,
        sourceKey
    })
end

function FinanceDB.upsertDeadline(sourceType, sourceId, sourceKey, dueDate, reason, updatedBy)
    MySQL.insert.await([[
        INSERT INTO doj_finance_deadlines (source_type, source_id, source_key, due_date, is_overridden, reason, updated_by)
        VALUES (?, ?, ?, ?, 1, ?, ?)
        ON DUPLICATE KEY UPDATE
            due_date = VALUES(due_date),
            is_overridden = 1,
            reason = VALUES(reason),
            updated_by = VALUES(updated_by),
            updated_at = CURRENT_TIMESTAMP
    ]], { sourceType, sourceId, sourceKey, dueDate, reason, updatedBy })

    FinanceDB.invalidateCache('dashboard:')
end

function FinanceDB.deleteDeadline(sourceType, sourceId, sourceKey)
    MySQL.update.await('DELETE FROM doj_finance_deadlines WHERE source_type = ? AND source_id <=> ? AND source_key <=> ?', {
        sourceType,
        sourceId,
        sourceKey
    })

    FinanceDB.invalidateCache('dashboard:')
end

function FinanceDB.fetchLinks(sourceType, sourceId, sourceKey)
    return MySQL.query.await([[
        SELECT l.id, l.business_job, l.period, l.transaction_id, l.tax_source_type, l.tax_source_id, l.tax_source_key,
               l.match_quality, l.comment, l.created_by, l.created_at,
               t.value, t.date, t.type, t.sender_name, t.receiver_name
        FROM doj_finance_links l
        LEFT JOIN okokbanking_transactions t ON t.id = l.transaction_id
        WHERE l.tax_source_type = ? AND l.tax_source_id <=> ? AND l.tax_source_key <=> ?
        ORDER BY l.id DESC
    ]], { sourceType, sourceId, sourceKey }) or {}
end

function FinanceDB.createLink(payload)
    local id = MySQL.insert.await([[
        INSERT INTO doj_finance_links (business_job, period, transaction_id, tax_source_type, tax_source_id, tax_source_key, match_quality, comment, created_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], {
        payload.business_job,
        payload.period,
        payload.transaction_id,
        payload.tax_source_type,
        payload.tax_source_id,
        payload.tax_source_key,
        payload.match_quality,
        payload.comment,
        payload.created_by
    })

    return id
end

function FinanceDB.deleteLink(linkId)
    return MySQL.update.await('DELETE FROM doj_finance_links WHERE id = ?', { linkId })
end

function FinanceDB.fetchBusinessMaps()
    local rows = MySQL.query.await('SELECT tax_job, business_id, alias FROM doj_finance_business_map ORDER BY tax_job ASC') or {}
    local map = {}
    for _, row in ipairs(rows) do
        map[FinanceUtils.normalizeToken(row.tax_job)] = row.business_id
        if row.alias and row.alias ~= '' then
            map[FinanceUtils.normalizeToken(row.alias)] = row.business_id
        end
    end
    return rows, map
end

function FinanceDB.upsertBusinessMap(taxJob, businessId, alias, createdBy)
    MySQL.insert.await([[
        INSERT INTO doj_finance_business_map (tax_job, business_id, alias, created_by)
        VALUES (?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            business_id = VALUES(business_id),
            alias = VALUES(alias),
            created_by = VALUES(created_by),
            updated_at = CURRENT_TIMESTAMP
    ]], { taxJob, businessId, alias, createdBy })

    FinanceDB.invalidateCache('businessmap:')
end

function FinanceDB.fetchPotentialTransactions(job, period)
    local fromDate, toDate = FinanceUtils.periodToRange(period)
    local base = MySQL.query.await([[
        SELECT id, receiver_identifier, receiver_name, sender_identifier, sender_name, date, value, type
        FROM okokbanking_transactions
        WHERE date >= ? AND date <= ?
        ORDER BY date DESC
        LIMIT 100
    ]], { fromDate or '1970-01-01', toDate or os.date('%Y-%m-%d') }) or {}

    if #base > 0 then
        return base
    end

    return MySQL.query.await([[
        SELECT id, receiver_identifier, receiver_name, sender_identifier, sender_name, date, value, type
        FROM okokbanking_transactions
        ORDER BY date DESC
        LIMIT 50
    ]]) or {}
end

function FinanceDB.fetchReports(filters)
    filters = filters or {}
    local clauses, params = { '1=1' }, {}

    if filters.type and filters.type ~= '' then
        clauses[#clauses + 1] = 'report_type = ?'
        params[#params + 1] = filters.type
    end

    if filters.author and filters.author ~= '' then
        clauses[#clauses + 1] = 'created_by = ?'
        params[#params + 1] = filters.author
    end

    if filters.from and filters.from ~= '' then
        clauses[#clauses + 1] = 'DATE(created_at) >= ?'
        params[#params + 1] = filters.from
    end

    if filters.to and filters.to ~= '' then
        clauses[#clauses + 1] = 'DATE(created_at) <= ?'
        params[#params + 1] = filters.to
    end

    local _, limit, offset = FinanceUtils.clampPage(filters.page, filters.pageSize)
    local where = table.concat(clauses, ' AND ')
    local count = MySQL.scalar.await(('SELECT COUNT(*) FROM doj_finance_reports WHERE %s'):format(where), params) or 0

    params[#params + 1] = limit
    params[#params + 1] = offset
    local rows = MySQL.query.await(('SELECT id, report_type, title, created_by, range_from, range_to, created_at FROM doj_finance_reports WHERE %s ORDER BY id DESC LIMIT ? OFFSET ?'):format(where), params) or {}

    return rows, count
end
