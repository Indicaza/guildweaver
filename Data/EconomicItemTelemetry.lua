local _, GW = ...

GW.EconomicItemTelemetry = GW.EconomicItemTelemetry or {}

local completeItems = GW.EconomicItemTelemetry.completeItems or {}
local pendingItems = GW.EconomicItemTelemetry.pendingItems or {}
GW.EconomicItemTelemetry.completeItems = completeItems
GW.EconomicItemTelemetry.pendingItems = pendingItems

local function safe(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, value = pcall(fn, ...)
    if not ok then
        return nil
    end
    return value
end

local function hasTableData(value)
    return type(value) == "table" and next(value) ~= nil
end

-- A title can appear before GetItemInfo has finished loading. Do not freeze
-- that one-line tooltip into the shared catalog: a loaded item also has the
-- core metadata GetItemInfo returns for every item class.
local function descriptionComplete(item)
    local lines = type(item) == "table"
        and type(item.tooltip) == "table"
        and item.tooltip.lines or nil
    if type(lines) ~= "table" or #lines == 0 then
        return false
    end
    if type(item.name) ~= "string" or item.name == "" then
        return false
    end
    if item.qualityId == nil or not tonumber(item.iconFileDataId) then
        return false
    end
    return hasTableData(item.itemClass) or hasTableData(item.itemSubclass)
end

local function currentGameBuild()
    local character = GW.Character
    if type(character) ~= "table" or type(character.GetCurrentSnapshot) ~= "function" then
        return nil
    end
    local snapshot = safe(character.GetCurrentSnapshot)
    return type(snapshot) == "table" and snapshot.gameBuild or nil
end

local function pendingOutput(output)
    if type(output) ~= "table" then
        return nil
    end
    return {
        itemId = tonumber(output.itemId),
        itemLink = output.itemLink,
        name = output.name,
        qualityId = tonumber(output.qualityId),
        iconFileDataId = tonumber(output.iconFileDataId),
    }
end

local function requestItemData(itemId)
    local itemApi = _G and _G.C_Item or C_Item
    local request = type(itemApi) == "table" and itemApi.RequestLoadItemDataByID or nil
    if type(request) ~= "function" or not tonumber(itemId) then
        return false
    end
    local ok = pcall(request, tonumber(itemId))
    return ok
end

local function describeOutput(output)
    if type(output) ~= "table" then
        return nil
    end

    local itemId = tonumber(output.itemId)
    if not itemId or itemId <= 0 then
        return nil
    end
    if completeItems[itemId] then
        return nil
    end

    local itemTelemetry = GW.ItemTelemetry
    if type(itemTelemetry) ~= "table" or type(itemTelemetry.Describe) ~= "function" then
        return nil
    end

    local itemLink = type(output.itemLink) == "string" and output.itemLink ~= "" and output.itemLink or nil
    local item = safe(itemTelemetry.Describe, itemLink or itemId, { details = true })
    if type(item) ~= "table" then
        return nil
    end

    item.itemId = tonumber(item.itemId) or itemId
    item.itemLink = item.itemLink or itemLink
    item.name = item.name or output.name
    item.qualityId = tonumber(item.qualityId) or tonumber(output.qualityId)
    item.iconFileDataId = tonumber(item.iconFileDataId) or tonumber(output.iconFileDataId)
    return item
end

function GW.EconomicItemTelemetry.Publish(output)
    local item = describeOutput(output)
    if not item then
        return nil
    end

    local itemId = tonumber(item.itemId)
    local envelopeModule = GW.TelemetryEnvelope
    local store = GW.Store
    if not itemId or type(envelopeModule) ~= "table" or type(envelopeModule.Build) ~= "function"
        or type(store) ~= "table" or type(store.SetTelemetrySnapshot) ~= "function" then
        return nil
    end

    local itemKey = "item:" .. tostring(itemId)
    local envelope = envelopeModule.Build("item_definition", {
        schemaVersion = 1,
        itemKey = itemKey,
        item = item,
    }, {
        capturedAt = type(GetServerTime) == "function" and safe(GetServerTime) or 0,
        gameBuild = currentGameBuild(),
    })
    if not envelope then
        return nil
    end

    local streamKey = "item_definition:" .. itemKey
    local changed = store.SetTelemetrySnapshot(streamKey, envelope)
    if descriptionComplete(item) then
        completeItems[itemId] = true
        pendingItems[itemId] = nil
    elseif requestItemData(itemId) then
        pendingItems[itemId] = pendingOutput(output)
    else
        -- Older clients may not expose the async item loader. Keep the best
        -- description we have and avoid rescanning it on every loot event;
        -- Holdfast can still fill sparse lines from the structured metadata.
        completeItems[itemId] = true
        pendingItems[itemId] = nil
    end

    if not changed then
        return nil
    end
    return {
        streamKey = streamKey,
        envelope = envelope,
    }
end

function GW.EconomicItemTelemetry.Retry(itemId)
    local id = tonumber(itemId)
    local output = id and pendingItems[id] or nil
    if not output then
        return nil
    end
    return GW.EconomicItemTelemetry.Publish(output)
end

local originalReadLoot = type(GW.GatheringTelemetry) == "table" and GW.GatheringTelemetry.ReadLoot or nil
if type(originalReadLoot) == "function" then
    GW.GatheringTelemetry.ReadLoot = function(...)
        local loot = originalReadLoot(...)
        if type(loot) == "table" and type(loot.outputs) == "table" then
            for _, output in ipairs(loot.outputs) do
                pcall(GW.EconomicItemTelemetry.Publish, output)
            end
        end
        return loot
    end
end

-- Equipment has the richest per-item client data we collect. Feed it into the
-- same canonical item catalog so every Holdfast surface can converge on one
-- exact Forever description instead of inventing its own tooltip shape.
local originalSetCharacterSnapshot = type(GW.Store) == "table" and GW.Store.SetCharacterSnapshot or nil
if type(originalSetCharacterSnapshot) == "function" then
    GW.Store.SetCharacterSnapshot = function(characterKey, snapshot)
        local result = originalSetCharacterSnapshot(characterKey, snapshot)
        if type(snapshot) == "table" and type(snapshot.equipment) == "table" then
            for _, item in ipairs(snapshot.equipment) do
                pcall(GW.EconomicItemTelemetry.Publish, item)
            end
        end
        return result
    end
end

-- GetItemInfo/C_TooltipInfo can legitimately be sparse until the client has
-- loaded an item. Ask the client to load it and republish the same state when
-- Blizzard signals completion; fingerprinting keeps unchanged retries free.
if type(CreateFrame) == "function" then
    local frame = CreateFrame("Frame")
    if frame and type(frame.RegisterEvent) == "function" and type(frame.SetScript) == "function" then
        pcall(frame.RegisterEvent, frame, "GET_ITEM_INFO_RECEIVED")
        pcall(frame.RegisterEvent, frame, "ITEM_DATA_LOAD_RESULT")
        frame:SetScript("OnEvent", function(_, _, itemId, success)
            if success == false then
                return
            end
            if pendingItems[tonumber(itemId)] then
                pcall(GW.EconomicItemTelemetry.Retry, itemId)
            end
        end)
    end
end
