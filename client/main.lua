local resourceName = GetCurrentResourceName()
local isOpen = false
local spawnedNpc

local function notify(message, msgType)
    lib.notify({ title = 'DOJ Finance Suite', description = message, type = msgType or 'inform' })
end

local function openTablet()
    if isOpen then return end
    isOpen = true
    SetNuiFocus(true, true)
    SetNuiFocusKeepInput(false)
    SendNUIMessage({ action = 'open' })
end

local function closeTablet()
    if not isOpen then return end
    isOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
end

RegisterNetEvent('doj_finance_suite:client:open', function()
    openTablet()
end)

RegisterNUICallback('close', function(_, cb)
    closeTablet()
    cb({ ok = true })
end)

RegisterNUICallback('getDashboard', function(_, cb)
    local data = lib.callback.await('doj_finance_suite:server:getDashboard', false)
    cb(data or {})
end)

RegisterNUICallback('getPrivateCases', function(payload, cb)
    local response = lib.callback.await('doj_finance_suite:server:getPrivateTaxes', false, payload and payload.filters or {}, payload and payload.page or 1, payload and payload.pageSize or 25)
    cb(response or { rows = {}, count = 0 })
end)

RegisterNUICallback('getBusinessCases', function(payload, cb)
    local response = lib.callback.await('doj_finance_suite:server:getBusinessTaxes', false, payload and payload.filters or {}, payload and payload.page or 1, payload and payload.pageSize or 25)
    cb(response or { rows = {}, count = 0 })
end)

RegisterNUICallback('getTransactions', function(payload, cb)
    local response = lib.callback.await('doj_finance_suite:server:getTransactions', false, payload and payload.filters or {}, payload and payload.page or 1, payload and payload.pageSize or 50)
    cb(response or { rows = {}, count = 0, analysis = { score = 0, band = 'unauffaellig', reasons = {} }, windows = {} })
end)

RegisterNUICallback('getCaseDetail', function(payload, cb)
    local detail = lib.callback.await('doj_finance_suite:server:getCaseDetail', false, payload.source_type, payload.source_id, payload.source_key)
    cb(detail or {})
end)

RegisterNUICallback('setStatus', function(payload, cb)
    local ok = lib.callback.await('doj_finance_suite:server:setReviewStatus', false, payload)
    cb({ ok = ok and true or false })
end)

RegisterNUICallback('addNote', function(payload, cb)
    local noteId = lib.callback.await('doj_finance_suite:server:addReviewNote', false, payload)
    cb({ ok = noteId and true or false, id = noteId })
end)

RegisterNUICallback('setDeadline', function(payload, cb)
    local ok = lib.callback.await('doj_finance_suite:server:setDeadline', false, payload)
    cb({ ok = ok and true or false })
end)

RegisterNUICallback('removeDeadline', function(payload, cb)
    local ok = lib.callback.await('doj_finance_suite:server:removeDeadline', false, payload)
    cb({ ok = ok and true or false })
end)

RegisterNUICallback('addLink', function(payload, cb)
    local id = lib.callback.await('doj_finance_suite:server:addLink', false, payload)
    cb({ ok = id and true or false, id = id })
end)

RegisterNUICallback('removeLink', function(payload, cb)
    local ok = lib.callback.await('doj_finance_suite:server:removeLink', false, payload)
    cb({ ok = ok and true or false })
end)

RegisterNUICallback('listReports', function(payload, cb)
    local rows, count = lib.callback.await('doj_finance_suite:server:listReports', false, payload and payload.filters or { page = 1, pageSize = 50 })
    cb({ rows = rows or {}, count = count or 0 })
end)

RegisterNUICallback('getReport', function(payload, cb)
    local report = lib.callback.await('doj_finance_suite:server:getReport', false, payload.report_id)
    cb(report or {})
end)

RegisterNUICallback('createReport', function(payload, cb)
    local id = lib.callback.await('doj_finance_suite:server:createReport', false, payload.report_type, payload.payload or {})
    if id then
        notify(('Report erstellt: %s'):format(id), 'success')
    end
    cb({ id = id })
end)

RegisterNUICallback('upsertBusinessMap', function(payload, cb)
    local ok = lib.callback.await('doj_finance_suite:server:upsertBusinessMap', false, payload)
    cb({ ok = ok and true or false })
end)

RegisterNUICallback('getBusinessMaps', function(_, cb)
    local rows = lib.callback.await('doj_finance_suite:server:getBusinessMaps', false)
    cb({ rows = rows or {} })
end)

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
            if Config.Interaction.point.enabled and not isOpen then
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
            else
                lib.hideTextUI()
            end
            Wait(sleep)
        end
    end)
end

CreateThread(function()
    while true do
        if IsControlJustReleased(0, 322) and isOpen then -- ESC
            closeTablet()
        end
        Wait(0)
    end
end)

AddEventHandler('onResourceStart', function(name)
    if name ~= resourceName then return end
    setupInteraction()
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= resourceName then return end
    closeTablet()
    lib.hideTextUI()
    if spawnedNpc and DoesEntityExist(spawnedNpc) then
        DeleteEntity(spawnedNpc)
    end
end)
