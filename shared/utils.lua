FinanceUtils = {}
FinanceCore = {}

local function fetchEsx()
    if FinanceCore.esx then
        return FinanceCore.esx
    end

    local ok, obj = pcall(function()
        return exports['es_extended']:getSharedObject()
    end)

    if ok and obj then
        FinanceCore.esx = obj
        return obj
    end

    return nil
end

function FinanceCore.getESX()
    return fetchEsx()
end

function FinanceUtils.safeNumber(value, default)
    local n = tonumber(value)
    if not n then
        return default or 0
    end

    return n
end

function FinanceUtils.round(value)
    return math.floor(FinanceUtils.safeNumber(value) + 0.5)
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

function FinanceUtils.formatMoney(value)
    return string.format('%.2f', FinanceUtils.safeNumber(value))
end

function FinanceUtils.normalizeDateString(value)
    if not value or value == '' then
        return nil
    end

    local y, m, d = tostring(value):match('^(%d%d%d%d)%-(%d%d)%-(%d%d)')
    if y and m and d then
        return string.format('%04d-%02d-%02d', tonumber(y), tonumber(m), tonumber(d))
    end

    return nil
end

function FinanceUtils.parseDate(value)
    if value == nil then
        return nil
    end

    if type(value) == 'number' then
        if value > 1000000000 then
            return value
        end
        return nil
    end

    local raw = tostring(value)

    local y, m, d, hh, mm, ss = raw:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)[ T](%d%d):(%d%d):?(%d?%d?)')
    if y and m and d then
        return os.time({
            year = tonumber(y),
            month = tonumber(m),
            day = tonumber(d),
            hour = tonumber(hh) or 0,
            min = tonumber(mm) or 0,
            sec = tonumber(ss) or 0
        })
    end

    local y2, m2, d2 = raw:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)')
    if y2 and m2 and d2 then
        return os.time({ year = tonumber(y2), month = tonumber(m2), day = tonumber(d2), hour = 0, min = 0, sec = 0 })
    end

    local d3, m3, y3, hh3, mm3, ss3 = raw:match('^(%d%d)%.(%d%d)%.(%d%d%d%d)[ T]?(%d?%d?):?(%d?%d?):?(%d?%d?)')
    if d3 and m3 and y3 then
        return os.time({
            year = tonumber(y3),
            month = tonumber(m3),
            day = tonumber(d3),
            hour = tonumber(hh3) or 0,
            min = tonumber(mm3) or 0,
            sec = tonumber(ss3) or 0
        })
    end

    local d4, m4, y4 = raw:match('^(%d%d)/(%d%d)/(%d%d%d%d)')
    if d4 and m4 and y4 then
        return os.time({ year = tonumber(y4), month = tonumber(m4), day = tonumber(d4), hour = 0, min = 0, sec = 0 })
    end

    return nil
end

function FinanceUtils.dateAddDays(dateValue, dueDays)
    local baseTs = FinanceUtils.parseDate(dateValue)
    if not baseTs then
        return nil, nil
    end

    local finalTs = baseTs + ((dueDays or Config.DueDays) * 86400)
    return os.date('%Y-%m-%d', finalTs), finalTs
end

function FinanceUtils.daysBetween(nowTs, baseTs)
    if not nowTs or not baseTs then
        return nil
    end

    return math.floor((nowTs - baseTs) / 86400)
end

function FinanceUtils.clampPage(page, pageSize)
    local p = math.max(1, tonumber(page) or 1)
    local s = math.min(Config.MaxPageSize, math.max(1, tonumber(pageSize) or Config.DefaultPageSize))
    local offset = (p - 1) * s
    return p, s, offset
end

function FinanceUtils.businessKey(job, period)
    return string.format('%s|%s', tostring(job or ''), tostring(period or ''))
end

function FinanceUtils.normalizeToken(value)
    local token = tostring(value or ''):lower()
    token = token:gsub('%s+', ''):gsub('[^%w_%-]', '')
    return token
end

function FinanceUtils.riskBand(score)
    local s = FinanceUtils.safeNumber(score)
    if s >= Config.RiskEngine.thresholds.high then
        return 'hochrisiko'
    elseif s >= Config.RiskEngine.thresholds.flagged then
        return 'auffaellig'
    elseif s >= Config.RiskEngine.thresholds.watch then
        return 'beobachten'
    end

    return 'unauffaellig'
end

function FinanceUtils.periodToRange(period)
    local y, m = tostring(period or ''):match('^(%d%d%d%d)%-(%d%d)$')
    if not y then
        return nil, nil
    end

    local from = string.format('%s-%s-01', y, m)
    local month = tonumber(m)
    local year = tonumber(y)
    local nextMonth = month + 1
    local nextYear = year
    if nextMonth > 12 then
        nextMonth = 1
        nextYear = nextYear + 1
    end

    local toTs = os.time({ year = nextYear, month = nextMonth, day = 1, hour = 0, min = 0, sec = 0 }) - 86400
    return from, os.date('%Y-%m-%d', toTs)
end

function FinanceUtils.txDirection(txType, value)
    local t = tostring(txType or ''):lower()
    local v = FinanceUtils.safeNumber(value)
    local absV = math.abs(v)

    if t == 'deposit' then
        return 'incoming', absV
    elseif t == 'withdraw' then
        return 'outgoing', absV
    elseif t == 'transfer' then
        if v >= 0 then
            return 'incoming', absV
        end
        return 'outgoing', absV
    end

    if v >= 0 then
        return 'incoming', absV
    end
    return 'outgoing', absV
end
