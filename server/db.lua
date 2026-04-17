FinanceDB = { cache = {} }

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
    local rows = MySQL.query.await([[
        SELECT id, receiver, receiver_name, received_date, title, amount, is_paid, paid_date, canceled
        FROM taxes
        WHERE %s
        ORDER BY received_date DESC, id DESC
        LIMIT ? OFFSET ?
    ]]:format(where), params) or {}

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
    local rows = MySQL.query.await([[
        SELECT job, job_label, period, amount, paid_amount, delayed_amount, late_fee_applied, is_paid, paid_date
        FROM taxes_business
        WHERE %s
        ORDER BY period DESC, job ASC
        LIMIT ? OFFSET ?
    ]]:format(where), params) or {}

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

function FinanceDB.fetchSocieties()
    return FinanceDB.cachedFetch('societies:all', Config.CacheTtlSeconds, [[
        SELECT society, society_name, value, iban, is_withdrawing
        FROM okokbanking_societies
        ORDER BY society_name ASC
    ]])
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

    if filters.from and filters.from ~= '' then
        clauses[#clauses + 1] = 'date >= ?'
        params[#params + 1] = filters.from
    end

    if filters.to and filters.to ~= '' then
        clauses[#clauses + 1] = 'date <= ?'
        params[#params + 1] = filters.to
    end

    local where = table.concat(clauses, ' AND ')
    local _, limit, offset = FinanceUtils.clampPage(page, pageSize)
    local count = MySQL.scalar.await(('SELECT COUNT(*) FROM okokbanking_transactions WHERE %s'):format(where), params) or 0

    params[#params + 1] = limit
    params[#params + 1] = offset
    local rows = MySQL.query.await([[
        SELECT id, receiver_identifier, receiver_name, sender_identifier, sender_name, date, value, type
        FROM okokbanking_transactions
        WHERE %s
        ORDER BY date DESC, id DESC
        LIMIT ? OFFSET ?
    ]]:format(where), params) or {}

    return rows, count
end

function FinanceDB.fetchTransactionsByDateRange(fromDate, toDate)
    local clauses = { '1=1' }
    local params = {}

    if fromDate then
        clauses[#clauses + 1] = 'date >= ?'
        params[#params + 1] = fromDate
    end

    if toDate then
        clauses[#clauses + 1] = 'date <= ?'
        params[#params + 1] = toDate
    end

    return MySQL.query.await([[
        SELECT id, receiver_identifier, receiver_name, sender_identifier, sender_name, date, value, type
        FROM okokbanking_transactions
        WHERE %s
        ORDER BY date DESC, id DESC
    ]]:format(table.concat(clauses, ' AND ')), params) or {}
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
    return MySQL.single.await('SELECT id, status, assigned_to, created_at, updated_at FROM doj_finance_reviews WHERE source_type = ? AND source_id <=> ? AND source_key <=> ?', {
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

    return { review = review, notes = notes, audit = audit }
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
