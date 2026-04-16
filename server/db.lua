FinanceDB = {
    cache = {}
}

local function nowSeconds()
    return os.time()
end

function FinanceDB.invalidateCache(prefix)
    if not prefix then
        FinanceDB.cache = {}
        return
    end

    for key, _ in pairs(FinanceDB.cache) do
        if key:find(prefix, 1, true) == 1 then
            FinanceDB.cache[key] = nil
        end
    end
end

function FinanceDB.cachedFetch(cacheKey, ttl, query, params)
    local entry = FinanceDB.cache[cacheKey]
    local now = nowSeconds()

    if entry and now < entry.expiresAt then
        return entry.value
    end

    local rows = MySQL.query.await(query, params or {}) or {}
    FinanceDB.cache[cacheKey] = {
        value = rows,
        expiresAt = now + (ttl or Config.CacheTtlSeconds)
    }

    return rows
end

function FinanceDB.cachedScalar(cacheKey, ttl, query, params)
    local entry = FinanceDB.cache[cacheKey]
    local now = nowSeconds()

    if entry and now < entry.expiresAt then
        return entry.value
    end

    local value = MySQL.scalar.await(query, params or {})
    FinanceDB.cache[cacheKey] = {
        value = value,
        expiresAt = now + (ttl or Config.CacheTtlSeconds)
    }

    return value
end

function FinanceDB.fetchPrivateTaxes(filters, page, pageSize)
    local clauses, params = { '1=1' }, {}

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

    local _, limit, offset = FinanceUtils.clampPage(page, pageSize)
    local where = table.concat(clauses, ' AND ')
    local countQuery = ('SELECT COUNT(*) FROM taxes WHERE %s'):format(where)
    local dataQuery = ([[
        SELECT id, receiver, receiver_name, received_date, title, amount, is_paid, paid_date, canceled
        FROM taxes
        WHERE %s
        ORDER BY id DESC
        LIMIT ? OFFSET ?
    ]]):format(where)

    local count = MySQL.scalar.await(countQuery, params) or 0
    params[#params + 1] = limit
    params[#params + 1] = offset
    local rows = MySQL.query.await(dataQuery, params) or {}

    return rows, count
end

function FinanceDB.fetchBusinessTaxes(filters, page, pageSize)
    local clauses, params = { '1=1' }, {}

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
    local countQuery = ('SELECT COUNT(*) FROM taxes_business WHERE %s'):format(where)
    local dataQuery = ([[
        SELECT job, job_label, period, amount, paid_amount, delayed_amount, late_fee_applied, is_paid, paid_date
        FROM taxes_business
        WHERE %s
        ORDER BY period DESC, job ASC
        LIMIT ? OFFSET ?
    ]]):format(where)

    local count = MySQL.scalar.await(countQuery, params) or 0
    params[#params + 1] = limit
    params[#params + 1] = offset
    local rows = MySQL.query.await(dataQuery, params) or {}
    return rows, count
end

function FinanceDB.fetchBusinessProfiles(page, pageSize)
    local _, limit, offset = FinanceUtils.clampPage(page, pageSize)
    local rows = MySQL.query.await([[SELECT id, type, owner, employees, data FROM vms_business ORDER BY id DESC LIMIT ? OFFSET ?]], {
        limit,
        offset
    }) or {}
    local total = MySQL.scalar.await('SELECT COUNT(*) FROM vms_business') or 0
    return rows, total
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
    local rows = MySQL.query.await(([[
        SELECT id, receiver_identifier, receiver_name, sender_identifier, sender_name, date, value, type
        FROM okokbanking_transactions
        WHERE %s
        ORDER BY date DESC, id DESC
        LIMIT ? OFFSET ?
    ]]):format(where), params) or {}

    return rows, count
end

function FinanceDB.fetchSinglePrivateTax(id)
    return MySQL.single.await([[SELECT id, receiver, receiver_name, received_date, title, amount, is_paid, paid_date, canceled FROM taxes WHERE id = ?]], { id })
end

function FinanceDB.fetchSingleBusinessTax(job, period)
    return MySQL.single.await([[SELECT job, job_label, period, amount, paid_amount, delayed_amount, late_fee_applied, is_paid, paid_date FROM taxes_business WHERE job = ? AND period = ?]], {
        job,
        period
    })
end
