local _, GW = ...

local Globals = _G or {}

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

local function fullTooltip(tooltip)
    local itemTelemetry = GW.ItemTelemetry
    if type(itemTelemetry) == "table" and type(itemTelemetry.IsFullTooltip) == "function" then
        return safe(itemTelemetry.IsFullTooltip, tooltip) == true
    end
    return type(tooltip) == "table"
        and tooltip.complete == true
        and tooltip.rendered == true
        and tooltip.source == "GameTooltip"
        and type(tooltip.lines) == "table"
        and #tooltip.lines > 0
end

local function descriptionComplete(item)
    if type(item) ~= "table" or not fullTooltip(item.tooltip) then
        return false
    end

    if type(item.name) ~= "string" or item.name == "" then
        return false
    end
    if item.qualityId == nil or not tonumber(item.iconFileDataId) then
        return false
    end
    return true
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
    local itemApi = type(_G) == "table" and _G.C_Item or nil
    local request = type(itemApi) == "table" and itemApi.RequestLoadItemDataByID or nil
    if type(request) ~= "function" or not tonumber(itemId) then
        return false
    end
    local ok = pcall(request, tonumber(itemId))
    return ok
end

local function contextualTooltip(options, itemLink)
    options = type(options) == "table" and options or {}
    local itemTelemetry = GW.ItemTelemetry
    if type(itemTelemetry) ~= "table" then
        return nil
    end

    if tonumber(options.lootSlot) and type(itemTelemetry.LootItemTooltip) == "function" then
        local tooltip = safe(itemTelemetry.LootItemTooltip, tonumber(options.lootSlot), itemLink)
        if fullTooltip(tooltip) then
            return tooltip
        end
    end

    if options.bagId ~= nil and tonumber(options.bagSlot) and type(itemTelemetry.BagItemTooltip) == "function" then
        local tooltip = safe(itemTelemetry.BagItemTooltip, options.bagId, tonumber(options.bagSlot), itemLink)
        if fullTooltip(tooltip) then
            return tooltip
        end
    end

    return nil
end

local function describeOutput(output, options)
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

    options = type(options) == "table" and options or {}
    local itemLink = type(output.itemLink) == "string" and output.itemLink ~= "" and output.itemLink or nil
    local hasContext = tonumber(options.lootSlot) ~= nil or (options.bagId ~= nil and tonumber(options.bagSlot) ~= nil)
    local item = safe(itemTelemetry.Describe, itemLink or itemId, {
        details = true,
        tooltip = not hasContext,
    })
    if type(item) ~= "table" then
        return nil
    end

    item.itemId = tonumber(item.itemId) or itemId
    item.itemLink = item.itemLink or itemLink
    item.name = item.name or output.name
    item.qualityId = tonumber(item.qualityId) or tonumber(output.qualityId)
    item.iconFileDataId = tonumber(item.iconFileDataId) or tonumber(output.iconFileDataId)

    -- Preserve an already-authoritative tooltip supplied by a richer caller,
    -- then prefer the exact live loot/bag slot if one is available. This is
    -- what prevents fresh gathering materials from getting stuck behind an
    -- incomplete hyperlink scan.
    if fullTooltip(output.tooltip) then
        item.tooltip = output.tooltip
    end
    local slotTooltip = contextualTooltip(options, item.itemLink or itemLink)
    if slotTooltip then
        item.tooltip = slotTooltip
    end

    return item
end

function GW.EconomicItemTelemetry.Publish(output, options)
    local item = describeOutput(output, options)
    if not item then
        return nil
    end

    local itemId = tonumber(item.itemId)
    if not itemId then
        return nil
    end

    -- A canonical item_definition means we have the full client-rendered
    -- Blizzard tooltip. Sparse C_TooltipInfo data must never poison the shared
    -- catalog: request the item and wait for another live slot/rendered scan.
    if not descriptionComplete(item) then
        pendingItems[itemId] = pendingOutput(output)
        requestItemData(itemId)
        return nil
    end

    local envelopeModule = GW.TelemetryEnvelope
    local store = GW.Store
    if type(envelopeModule) ~= "table" or type(envelopeModule.Build) ~= "function"
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
    completeItems[itemId] = true
    pendingItems[itemId] = nil

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

local function itemIdFromLink(link)
    if type(link) ~= "string" then
        return nil
    end
    return tonumber(link:match("item:(%d+)"))
end

local function currentLootSlots()
    local slots = {}
    if type(Globals.GetNumLootItems) ~= "function" or type(Globals.GetLootSlotLink) ~= "function" then
        return slots
    end

    local count = tonumber(safe(Globals.GetNumLootItems)) or 0
    for slot = 1, count do
        local link = safe(Globals.GetLootSlotLink, slot)
        local itemId = itemIdFromLink(link)
        if itemId and not slots[itemId] then
            slots[itemId] = slot
        end
    end
    return slots
end

local originalReadLoot = type(GW.GatheringTelemetry) == "table" and GW.GatheringTelemetry.ReadLoot or nil
if type(originalReadLoot) == "function" then
    GW.GatheringTelemetry.ReadLoot = function(...)
        local loot = originalReadLoot(...)
        if type(loot) == "table" and type(loot.outputs) == "table" then
            -- Read the tooltip from the live loot slot before auto-loot closes
            -- the window. Generic hyperlink scans are only a fallback.
            local slots = currentLootSlots()
            for _, output in ipairs(loot.outputs) do
                local slot = slots[tonumber(output.itemId)]
                pcall(GW.EconomicItemTelemetry.Publish, output, slot and { lootSlot = slot } or nil)
            end
        end
        return loot
    end
end

-- Existing items should self-heal the shared catalog without requiring the
-- player to gather them again. Inventory already knows the concrete bag/slot,
-- so publish definitions from SetBagItem during the normal inventory refresh.
local originalInventoryRefresh = type(GW.InventoryTelemetry) == "table" and GW.InventoryTelemetry.Refresh or nil
if type(originalInventoryRefresh) == "function" then
    GW.InventoryTelemetry.Refresh = function(...)
        local payload, pending = originalInventoryRefresh(...)
        if type(payload) == "table" and type(payload.items) == "table" and type(payload.containers) == "table" then
            local itemsByKey = {}
            for _, item in ipairs(payload.items) do
                if type(item) == "table" and item.key then
                    itemsByKey[item.key] = item
                end
            end

            local seen = {}
            for _, container in ipairs(payload.containers) do
                if type(container) == "table" and type(container.slots) == "table" then
                    for _, slot in ipairs(container.slots) do
                        local item = type(slot) == "table" and itemsByKey[slot.itemKey] or nil
                        local itemId = item and tonumber(item.itemId) or nil
                        if itemId and not seen[itemId] then
                            seen[itemId] = true
                            pcall(GW.EconomicItemTelemetry.Publish, item, {
                                bagId = container.bagId,
                                bagSlot = slot.slot,
                            })
                        end
                    end
                end
            end
        end
        return payload, pending
    end
end

-- Equipment has the richest per-instance tooltip because ItemTelemetry scans
-- the actual inventory slot. Feed that authoritative render into the shared
-- catalog so Farming, Bags, Professions and Armory converge on the same text.
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
