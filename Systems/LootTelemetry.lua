local _, GW = ...

GW.LootTelemetry = GW.LootTelemetry or {}

local DEDUPE_WINDOW_SECONDS = 2

local function itemIdFromLink(itemLink)
    if type(itemLink) ~= "string" then
        return nil
    end

    return tonumber(itemLink:match("item:(%d+)"))
end

local function splitGuid(guid)
    if type(guid) ~= "string" or guid == "" then
        return nil
    end

    local parts = {}
    for part in string.gmatch(guid, "[^%-]+") do
        table.insert(parts, part)
    end

    return {
        guid = guid,
        kind = parts[1],
        objectId = tonumber(parts[6]),
    }
end

local function lootSources(slot)
    if type(_G.GetLootSourceInfo) ~= "function" then
        return {}
    end

    local values = { pcall(_G.GetLootSourceInfo, slot) }
    if not values[1] then
        return {}
    end

    local sources = {}
    local index = 2
    while index <= #values do
        local guid = values[index]
        local quantity = tonumber(values[index + 1]) or 0
        if guid then
            local parsed = splitGuid(guid) or { guid = guid }
            parsed.quantity = quantity
            table.insert(sources, parsed)
        end
        index = index + 2
    end

    return sources
end

local function playerLocation()
    local result = {
        zone = type(_G.GetZoneText) == "function" and _G.GetZoneText() or nil,
        subzone = type(_G.GetSubZoneText) == "function" and _G.GetSubZoneText() or nil,
    }

    local mapApi = _G.C_Map
    if not mapApi or type(mapApi.GetBestMapForUnit) ~= "function" then
        return result
    end

    local ok, mapId = pcall(mapApi.GetBestMapForUnit, "player")
    if not ok or not mapId then
        return result
    end

    result.mapId = mapId

    if type(mapApi.GetPlayerMapPosition) ~= "function" then
        return result
    end

    local positionOk, position = pcall(mapApi.GetPlayerMapPosition, mapId, "player")
    if not positionOk or not position then
        return result
    end

    local x = position.x
    local y = position.y

    if type(position.GetXY) == "function" then
        local xyOk, valueX, valueY = pcall(position.GetXY, position)
        if xyOk then
            x = valueX
            y = valueY
        end
    end

    if type(x) == "number" and type(y) == "number" then
        result.x = x
        result.y = y
    end

    return result
end

local function instanceContext()
    if type(_G.GetInstanceInfo) ~= "function" then
        return nil
    end

    local ok, name, instanceType, difficultyId, difficultyName, maxPlayers, dynamicDifficulty, isDynamic, instanceId = pcall(_G.GetInstanceInfo)
    if not ok then
        return nil
    end

    return {
        name = name,
        type = instanceType,
        difficultyId = difficultyId,
        difficultyName = difficultyName,
        maxPlayers = maxPlayers,
        dynamicDifficulty = dynamicDifficulty,
        isDynamic = isDynamic,
        instanceId = instanceId,
    }
end

local function collectSlot(slot)
    local itemLink = type(_G.GetLootSlotLink) == "function" and _G.GetLootSlotLink(slot) or nil
    local icon, name, quantity, currencyId, quality, locked, isQuestItem, questId, isActive = nil, nil, nil, nil, nil, nil, nil, nil, nil

    if type(_G.GetLootSlotInfo) == "function" then
        local ok
        ok, icon, name, quantity, currencyId, quality, locked, isQuestItem, questId, isActive = pcall(_G.GetLootSlotInfo, slot)
        if not ok then
            icon, name, quantity, currencyId, quality, locked, isQuestItem, questId, isActive = nil, nil, nil, nil, nil, nil, nil, nil, nil
        end
    end

    local itemId = itemIdFromLink(itemLink)
    if not itemId and not currencyId and not name then
        return nil
    end

    return {
        slot = slot,
        itemId = itemId,
        itemLink = itemLink,
        icon = icon,
        name = name,
        quantity = tonumber(quantity) or 1,
        currencyId = currencyId,
        quality = quality,
        locked = locked,
        isQuestItem = isQuestItem,
        questId = questId,
        isActive = isActive,
        sources = lootSources(slot),
    }
end

local function collectItems()
    if type(_G.GetNumLootItems) ~= "function" then
        return {}
    end

    local ok, count = pcall(_G.GetNumLootItems)
    if not ok or not count or count < 1 then
        return {}
    end

    local items = {}
    for slot = 1, count do
        local item = collectSlot(slot)
        if item then
            table.insert(items, item)
        end
    end

    return items
end

local function observationFingerprint(items)
    local parts = {}

    for _, item in ipairs(items) do
        table.insert(parts, tostring(item.itemId or item.currencyId or item.name or "?"))
        table.insert(parts, "x")
        table.insert(parts, tostring(item.quantity or 0))

        for _, source in ipairs(item.sources or {}) do
            table.insert(parts, "@")
            table.insert(parts, tostring(source.guid or "?"))
            table.insert(parts, "x")
            table.insert(parts, tostring(source.quantity or 0))
        end
        table.insert(parts, ";")
    end

    return table.concat(parts)
end

function GW.LootTelemetry.Capture(reason)
    local items = collectItems()
    if #items == 0 then
        return nil, "empty_loot"
    end

    local capturedAt = GetServerTime()
    local fingerprint = observationFingerprint(items)

    if self.lastFingerprint == fingerprint and capturedAt - (self.lastCapturedAt or 0) <= DEDUPE_WINDOW_SECONDS then
        return nil, "duplicate_loot_window"
    end

    self.lastFingerprint = fingerprint
    self.lastCapturedAt = capturedAt

    local targetGuid = type(_G.UnitGUID) == "function" and _G.UnitGUID("target") or nil
    local payload = {
        schemaVersion = 1,
        reason = reason or "manual",
        observedAt = capturedAt,
        location = playerLocation(),
        instance = instanceContext(),
        target = splitGuid(targetGuid),
        items = items,
    }

    local record, queueError = GW.TelemetryEvents.Queue("loot_observation", payload, {
        capturedAt = capturedAt,
    })

    if not record then
        return nil, queueError
    end

    return payload
end

local function safeRegister(frame, event)
    pcall(frame.RegisterEvent, frame, event)
end

function GW.LootTelemetry:Initialize()
    if self.eventFrame then
        return
    end

    local frame = CreateFrame("Frame")
    safeRegister(frame, "LOOT_READY")
    safeRegister(frame, "LOOT_OPENED")

    frame:SetScript("OnEvent", function(_, event)
        C_Timer.After(0, function()
            GW.LootTelemetry.Capture(event)
        end)
    end)

    self.eventFrame = frame
end
