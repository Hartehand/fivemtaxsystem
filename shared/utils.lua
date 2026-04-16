FinanceUtils = {}

function FinanceUtils.safeNumber(value, default)
    local n = tonumber(value)
    if not n then
        return default or 0
    end

    return n
end

function FinanceUtils.toBoolean(value)
    if type(value) == 'boolean' then
        return value
    end

    if type(value) == 'number' then
        return value ~= 0
    end

    if type(value) == 'string' then
        value = value:lower()
        return value == '1' or value == 'true' or value == 'yes'
    end

    return false
end

function FinanceUtils.normalizeDateString(value)
    if not value or value == '' then
        return nil
    end

    local y, m, d = string.match(value, '^(%d%d%d%d)%-(%d%d)%-(%d%d)')
    if y and m and d then
        return string.format('%04d-%02d-%02d', y, m, d)
    end

    return nil
end

function FinanceUtils.parseDate(value)
    if not value then
        return nil
    end

    local normalized = FinanceUtils.normalizeDateString(value)
    if not normalized then
        return nil
    end

    local y, m, d = normalized:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
    return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0, min = 0, sec = 0 })
end

function FinanceUtils.formatMoney(value)
    return string.format('%.2f', FinanceUtils.safeNumber(value))
end

function FinanceUtils.daysBetween(nowTs, baseTs)
    if not nowTs or not baseTs then
        return nil
    end

    return math.floor((nowTs - baseTs) / 86400)
end

function FinanceUtils.safeDecode(jsonValue)
    if type(jsonValue) == 'table' then
        return jsonValue
    end

    if type(jsonValue) ~= 'string' or jsonValue == '' then
        return {}
    end

    local ok, decoded = pcall(json.decode, jsonValue)
    if not ok or type(decoded) ~= 'table' then
        return {}
    end

    return decoded
end

function FinanceUtils.clampPage(page, pageSize)
    local p = math.max(1, tonumber(page) or 1)
    local s = math.min(Config.MaxPageSize, math.max(1, tonumber(pageSize) or Config.DefaultPageSize))
    local offset = (p - 1) * s
    return p, s, offset
end

function FinanceUtils.tableKeys(tbl)
    local result = {}
    for key, _ in pairs(tbl or {}) do
        result[#result + 1] = key
    end
    table.sort(result)
    return result
end

function FinanceUtils.dateAddDays(dateValue, dueDays)
    local baseTs = FinanceUtils.parseDate(dateValue)
    if not baseTs then
        return nil
    end

    local finalTs = baseTs + ((dueDays or Config.DueDays) * 86400)
    return os.date('%Y-%m-%d', finalTs), finalTs
end

function FinanceUtils.businessKey(job, period)
    return string.format('%s|%s', tostring(job or ''), tostring(period or ''))
end
