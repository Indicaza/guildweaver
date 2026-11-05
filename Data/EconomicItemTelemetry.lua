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

-- Catalog work that does not depend on a transient window runs on the
-- shared work queue (optional, budgeted per frame, paused in combat). Without
-- the queue (tests, very old clients) it runs immediately as before.
local function defer(key, run)
    local queue = GW.WorkQueue
    if type(queue) ~= "table" or type(queue.Enqueue) ~= "function" then
        run()
        return
    end
    queue.Enqueue({
        key = key,
        optional = true,
        category = "item_catalog",
        step = function()
            run()
            return true
        end,
    })
end

local function publishGameItem(itemId)
    local gameItems = GW.GameItemTelemetry
    itemId = tonumber(itemId)
    if not itemId or type(gameItems) ~= "table" or type(gameItems.Publish) ~= "function" then
        return
    end
    if type(gameItems.IsComplete) == "function" and gameItems.IsComplete(itemId) then
        return
    end
    -- The public base definition scans a bare item link, which stays valid
    -- after the loot window or bag slot is gone.
    defer("game_item:" .. tostring(itemId), function()
        pcall(gameItems.Publish, itemId)
    end)
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

-- The client build cannot change during a session; remember it once known
-- instead of resolving the character snapshot for every definition.
local knownGameBuild = nil
local function currentGameBuild()
    if knownGameBuild then
        return knownGameBuild
    end
    local character = GW.Character
    if type(character) ~= "table" or type(character.GetCurrentSnapshot) ~= "function" then
        return nil
    end
    local snapshot = safe(character.GetCurrentSnapshot)
    knownGameBuild = type(snapshot) == "table" and snapshot.gameBuild or nil
    return knownGameBuild
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
    -- A caller-supplied full tooltip (equipment slots) replaces the generic
    -- one below, so the hyperlink is not rendered just to be discarded.
    local item = safe(itemTelemetry.Describe, itemLink or itemId, {
        details = true,
        tooltip = not hasContext and not fullTooltip(output.tooltip),
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
    if type(output) == "table" then
        publishGameItem(output.itemId)
    end
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

-- Several collectors read the same loot window (mob loot plus a gathering
-- profession, on both LOOT_READY and LOOT_OPENED). Each incomplete item's
-- definition is attempted at most twice per window (item data can arrive
-- between the two events); the window resets on LOOT_CLOSED, or after a few
-- seconds if that event was missed.
local LOOT_WINDOW_SECONDS = 10
local MAX_LOOT_ATTEMPTS = 2
local lootAttempts = {}
local lootWindowStarted = nil

local function lootClock()
    return tonumber(safe(Globals.GetTime)) or nil
end

local function resetLootWindow()
    lootAttempts = {}
    lootWindowStarted = nil
end

local function attemptInLootWindow(itemId)
    local current = lootClock()
    if lootWindowStarted and current and current - lootWindowStarted > LOOT_WINDOW_SECONDS then
        resetLootWindow()
    end
    lootWindowStarted = lootWindowStarted or current
    local attempts = lootAttempts[itemId] or 0
    if attempts >= MAX_LOOT_ATTEMPTS then
        return false
    end
    lootAttempts[itemId] = attempts + 1
    return true
end

local originalReadLoot = type(GW.GatheringTelemetry) == "table" and GW.GatheringTelemetry.ReadLoot or nil
if type(originalReadLoot) == "function" then
    GW.GatheringTelemetry.ReadLoot = function(...)
        local loot = originalReadLoot(...)
        if type(loot) == "table" and type(loot.outputs) == "table" then
            -- Read the tooltip from the live loot slot before auto-loot closes
            -- the window: this part cannot be deferred. Generic hyperlink
            -- scans are only a fallback.
            local perf = GW.Perf
            local started = perf and perf.Begin and perf.Begin() or nil
            local slots = nil
            for _, output in ipairs(loot.outputs) do
                local itemId = tonumber(output.itemId)
                if itemId and not completeItems[itemId] and attemptInLootWindow(itemId) then
                    slots = slots or currentLootSlots()
                    local slot = slots[itemId]
                    pcall(GW.EconomicItemTelemetry.Publish, output, slot and { lootSlot = slot } or nil)
                elseif itemId then
                    publishGameItem(itemId)
                end
            end
            if perf and perf.End then
                perf.End("loot_capture", started)
            end
        end
        return loot
    end
end

-- Inventory and equipment definitions are not transient: they are queued,
-- tried a bounded number of times per session (item-data events still
-- retry pending ones), and skipped once complete.
local MAX_CATALOG_ATTEMPTS = 3
local catalogAttempts = {}

local function catalogCandidate(itemId)
    if not itemId or completeItems[itemId] then
        return false
    end
    local attempts = catalogAttempts[itemId] or 0
    if attempts >= MAX_CATALOG_ATTEMPTS then
        return false
    end
    catalogAttempts[itemId] = attempts + 1
    return true
end

local function slotHolds(bagId, slot, itemId)
    local container = Globals.C_Container
    if type(container) == "table" and type(container.GetContainerItemInfo) == "function" then
        local info = safe(container.GetContainerItemInfo, bagId, slot)
        return type(info) == "table" and tonumber(info.itemID) == itemId
    end
    local link = safe(Globals.GetContainerItemLink, bagId, slot)
    return itemIdFromLink(link) == itemId
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
                            if catalogCandidate(itemId) then
                                local bagId, bagSlot = container.bagId, slot.slot
                                defer("item_definition:bag:" .. tostring(itemId), function()
                                    -- The item may have moved since the scan.
                                    if GW.WorkQueue and not slotHolds(bagId, bagSlot, itemId) then
                                        catalogAttempts[itemId] = (catalogAttempts[itemId] or 1) - 1
                                        return
                                    end
                                    pcall(GW.EconomicItemTelemetry.Publish, item, {
                                        bagId = bagId,
                                        bagSlot = bagSlot,
                                    })
                                end)
                            end
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
                local itemId = type(item) == "table" and tonumber(item.itemId) or nil
                if catalogCandidate(itemId) then
                    -- The slot's rendered tooltip travels with the item.
                    defer("item_definition:equipment:" .. tostring(itemId), function()
                        pcall(GW.EconomicItemTelemetry.Publish, item)
                    end)
                end
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
        pcall(frame.RegisterEvent, frame, "LOOT_CLOSED")
        frame:SetScript("OnEvent", function(_, event, itemId, success)
            if event == "LOOT_CLOSED" then
                resetLootWindow()
                return
            end
            if success == false then
                return
            end
            if pendingItems[tonumber(itemId)] then
                pcall(GW.EconomicItemTelemetry.Retry, itemId)
            end
        end)
    end
end
