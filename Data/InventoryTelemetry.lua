local _, GW = ...

-- Inventory telemetry: the player's carried bags (backpack, equipped bags,
-- reagent bag and keyring when the client has them) and money.
--
-- The payload is shaped for later snapshot-to-snapshot comparison:
--   containers[].slots[]  where each item sits (bag, slot, count, itemKey)
--   items[]               each distinct item described once (shared item
--                         enrichment: metadata, tooltip, stats, spell)
--   totals[]              carried count per itemId, the stable series a
--                         material-acquisition delta reads
-- Nothing volatile (lock state, timestamps) is included, so an unchanged
-- inventory fingerprints identically and does not emit a new revision.

local Globals = _G or {}

GW.InventoryTelemetry = GW.InventoryTelemetry or {}

local BACKPACK_ID = 0
-- Classic clients' keyring; clients with a bag index enum name their own
-- (WoW Forever's is -1, where -2 is a character bank tab).
local CLASSIC_KEYRING_ID = -2
local DEFAULT_BAG_SLOTS = 4
-- INV_Misc_Bag_08: the backpack has no inventory item to read an icon from.
local BACKPACK_ICON = 133633
local MAX_SLOTS_PER_CONTAINER = 64

local describedItems = {}
local latestByCharacter = {}

local function safe(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local results = { pcall(fn, ...) }
    if not results[1] then
        return nil
    end
    return unpack(results, 2, table.maxn(results))
end

local function cleanText(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    return (value:gsub("Player%-%d+%-%x+", "Player-REDACTED"))
end

local function positiveNumber(value)
    local number = tonumber(value)
    return number and number > 0 and number or nil
end

local function containerApi()
    local api = Globals.C_Container
    return type(api) == "table" and api or nil
end

local function call(name, ...)
    local api = containerApi()
    if api and type(api[name]) == "function" then
        return safe(api[name], ...)
    end
    return safe(Globals[name], ...)
end

local function bagIndexEnum()
    local enum = type(Globals.Enum) == "table" and Globals.Enum.BagIndex or nil
    return type(enum) == "table" and enum or nil
end

local function keyringId()
    local enum = bagIndexEnum()
    if enum then
        return tonumber(enum.Keyring)
    end
    return CLASSIC_KEYRING_ID
end

-- The reagent bag only exists on clients whose bag index enum names one; on
-- classic clients the id after the last bag is the first bank bag, which must
-- never be read as carried inventory.
local function reagentBagId()
    local bagIndex = bagIndexEnum()
    local reagent = bagIndex and tonumber(bagIndex.ReagentBag) or nil
    if not reagent then
        return nil
    end
    for key, value in pairs(bagIndex) do
        if type(key) == "string" and key:lower():find("bank", 1, true) and tonumber(value) == reagent then
            return nil
        end
    end
    return reagent
end

local function containerIds()
    local ids = {}
    local bagSlots = tonumber(Globals.NUM_BAG_SLOTS) or DEFAULT_BAG_SLOTS
    for bagId = BACKPACK_ID, bagSlots do
        table.insert(ids, bagId)
    end
    local reagent = reagentBagId()
    if reagent and reagent > bagSlots then
        table.insert(ids, reagent)
    end
    local keyring = keyringId()
    if keyring then
        table.insert(ids, keyring)
    end
    return ids
end

local function containerKind(bagId)
    if bagId == BACKPACK_ID then
        return "backpack"
    end
    if bagId == keyringId() then
        return "keyring"
    end
    if bagId == reagentBagId() then
        return "reagent"
    end
    return "bag"
end

-- The bag item itself (for equipped bags), read from its inventory slot.
local function containerItem(bagId)
    if bagId <= BACKPACK_ID then
        return nil
    end
    local inventoryId = call("ContainerIDToInventoryID", bagId)
    if not inventoryId then
        return nil
    end
    local link = safe(Globals.GetInventoryItemLink, "player", inventoryId)
    if type(link) ~= "string" then
        return nil
    end
    local itemId = tonumber(link:match("item:(%d+)"))
    local name = link:match("%[(.-)%]")
    return {
        itemId = itemId,
        name = cleanText(name),
        itemLink = cleanText(link),
        iconFileDataId = positiveNumber(safe(Globals.GetInventoryItemTexture, "player", inventoryId)),
        qualityId = tonumber(safe(Globals.GetInventoryItemQuality, "player", inventoryId)),
    }
end

-- C_Container returns a table; the legacy global returns a tuple.
local function slotInfo(bagId, slot)
    local api = containerApi()
    if api and type(api.GetContainerItemInfo) == "function" then
        local info = safe(api.GetContainerItemInfo, bagId, slot)
        if type(info) ~= "table" then
            return nil
        end
        return {
            iconFileDataId = info.iconFileID,
            count = info.stackCount,
            qualityId = info.quality,
            link = info.hyperlink,
            itemId = info.itemID,
            isBound = info.isBound,
            isReadable = info.isReadable,
            hasLoot = info.hasLoot,
            hasNoValue = info.hasNoValue,
        }
    end

    local texture, count, _, quality, readable, lootable, link, _, noValue, itemId, isBound = safe(Globals.GetContainerItemInfo, bagId, slot)
    if not texture and not link then
        return nil
    end
    return {
        iconFileDataId = texture,
        count = count,
        qualityId = quality,
        link = link or safe(Globals.GetContainerItemLink, bagId, slot),
        itemId = itemId,
        isBound = isBound,
        isReadable = readable,
        hasLoot = lootable,
        hasNoValue = noValue,
    }
end

local function itemStringFromLink(link)
    if type(link) ~= "string" then
        return nil
    end
    return link:match("|H(item:[^|]+)|h") or link:match("(item:[%-%d:]+)")
end

-- Same item string fields the equipment snapshot parses.
local function linkModifiers(itemString)
    local fields = {}
    local payload = type(itemString) == "string" and itemString:match("^item:(.*)$") or nil
    if not payload then
        return {}
    end
    for field in string.gmatch(payload .. ":", "(.-):") do
        table.insert(fields, tonumber(field) or field)
    end

    local gemItemIds = {}
    for index = 3, 6 do
        local gemId = positiveNumber(fields[index])
        if gemId then
            table.insert(gemItemIds, gemId)
        end
    end
    local bonusIds = {}
    for index = 1, tonumber(fields[13]) or 0 do
        local bonusId = tonumber(fields[13 + index])
        if bonusId then
            table.insert(bonusIds, bonusId)
        end
    end

    return {
        enchantId = positiveNumber(fields[2]),
        gemItemIds = #gemItemIds > 0 and gemItemIds or nil,
        suffixId = positiveNumber(fields[7]),
        bonusIds = #bonusIds > 0 and bonusIds or nil,
    }
end

-- Tooltip lines that count down (cooldowns, durations, refund windows) would
-- change on every scan and churn revisions without the bags changing. Built
-- from the client's own format strings, with English fallbacks.
local volatilePatterns = nil

local function formatPattern(format)
    local escaped = format:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    local pattern = escaped:gsub("%%[%d%.]*[sdf]", ".-")
    return "^" .. pattern
end

local function volatileLinePatterns()
    if volatilePatterns then
        return volatilePatterns
    end
    volatilePatterns = { "^Cooldown remaining", "^Duration:", "full refund" }
    for _, name in ipairs({ "ITEM_COOLDOWN_TIME", "ITEM_COOLDOWN_TIME_MIN", "ITEM_COOLDOWN_TIME_SEC", "ITEM_COOLDOWN_TIME_HOURS", "ITEM_COOLDOWN_TIME_DAYS", "REFUND_TIME_REMAINING", "ITEM_DURATION_SEC", "ITEM_DURATION_MIN", "ITEM_DURATION_HOURS", "ITEM_DURATION_DAYS" }) do
        local format = Globals[name]
        if type(format) == "string" and format ~= "" then
            table.insert(volatilePatterns, formatPattern(format))
        end
    end
    return volatilePatterns
end

local function isVolatile(text)
    if type(text) ~= "string" then
        return false
    end
    for _, pattern in ipairs(volatileLinePatterns()) do
        if text:find(pattern) then
            return true
        end
    end
    return false
end

local function stableTooltip(tooltip)
    if type(tooltip) ~= "table" or type(tooltip.lines) ~= "table" then
        return nil
    end
    local lines = {}
    for _, line in ipairs(tooltip.lines) do
        if not isVolatile(line.left) and not isVolatile(line.right) then
            table.insert(lines, line)
        end
    end
    return #lines > 0 and { source = tooltip.source, lines = lines } or nil
end

-- Incremental scanning ---------------------------------------------------------
--
-- Bag tooltips are the expensive part of a scan (each renders a hidden
-- GameTooltip), so they are cached per item string together with the
-- instance state that can change the rendered text: the link (enchants, gems,
-- suffixes), stack count, binding and durability. A cached tooltip is reused
-- while that signature is unchanged; a changed signature rescans only that
-- item. Descriptions the client could not complete yet (no name or no
-- tooltip) are retried a bounded number of times; GET_ITEM_INFO_RECEIVED for
-- the item grants one more attempt.
--
-- Event-driven refreshes read only bags marked dirty by BAG_UPDATE and reuse
-- the previous container records for the rest. A full read (Collect() with
-- no options, PLAYER_ENTERING_WORLD, bag swaps, or the periodic
-- reconciliation in Systems/InventoryCapture.lua) repairs anything an event
-- missed, still reusing tooltips whose signature matches.

local MAX_TOOLTIP_ATTEMPTS = 3
local MAX_ITEM_INFO_RESETS = 3

local tooltipByKey = {}
local compositeByKey = {}
local containerRecords = {}
local dirtyBags = {}
local allDirty = true
local payloadRevision = 0
local lastFullRead = nil
local incompleteKeys = 0

local function perfCount(name)
    local perf = GW.Perf
    if perf and perf.Count then
        perf.Count(name)
    end
end

local function itemIdFromKey(itemKey, fallback)
    return tonumber(type(itemKey) == "string" and itemKey:match("^item:(%d+)") or nil) or fallback
end

local function slotSignature(source)
    local info = source.info
    local durability, maxDurability = call("GetContainerItemDurability", source.bagId, source.slot)
    return table.concat({
        tostring(source.link),
        tostring(info.count or 1),
        info.isBound and "1" or "0",
        tostring(durability or ""),
        tostring(maxDurability or ""),
    }, "\031")
end

local function describeMetadata(itemKey, link, info)
    local cached = describedItems[itemKey]
    if cached then
        return cached, true
    end
    local describeItem = GW.ItemTelemetry and GW.ItemTelemetry.Describe
    local item = nil
    if type(describeItem) == "function" then
        local ok, value = pcall(describeItem, link, { details = true, tooltip = false })
        item = ok and type(value) == "table" and value or nil
    end
    item = item or { itemId = info.itemId }

    local modifiers = linkModifiers(itemKey)
    cached = {
        key = itemKey,
        itemId = item.itemId or info.itemId,
        itemLink = item.itemLink or cleanText(link),
        name = item.name or cleanText(type(link) == "string" and link:match("%[(.-)%]") or nil),
        iconFileDataId = item.iconFileDataId or positiveNumber(info.iconFileDataId),
        qualityId = item.qualityId or info.qualityId,
        itemLevel = item.itemLevel,
        requiredLevel = item.requiredLevel,
        maxStackSize = item.stackCount,
        sellPrice = item.sellPrice,
        bindType = item.bindType,
        equipLocation = cleanText(item.equipLocation),
        expansionId = item.expansionId,
        setId = item.setId,
        isCraftingReagent = item.isCraftingReagent,
        itemClass = item.itemClass,
        itemSubclass = item.itemSubclass,
        enchantId = modifiers.enchantId,
        gemItemIds = modifiers.gemItemIds,
        suffixId = modifiers.suffixId,
        bonusIds = modifiers.bonusIds,
        stats = item.stats,
        spell = item.spell,
    }
    local complete = item.name ~= nil
    if complete then
        describedItems[itemKey] = cached
    end
    return cached, complete
end

local function scanTooltip(source)
    perfCount("tooltip_bag_scans")
    local bagTooltip = GW.ItemTelemetry and GW.ItemTelemetry.BagItemTooltip
    local tooltip = type(bagTooltip) == "function" and stableTooltip(bagTooltip(source.bagId, source.slot)) or nil
    if not tooltip and GW.ItemTelemetry and type(GW.ItemTelemetry.Describe) == "function" then
        local ok, value = pcall(GW.ItemTelemetry.Describe, source.link)
        tooltip = ok and type(value) == "table" and stableTooltip(value.tooltip) or nil
    end
    return tooltip
end

-- What the item is (metadata cached once per item string) plus the tooltip
-- as the player would see it hovering the first slot holding it. Returns the
-- description and whether a later scan should retry it.
local function describe(itemKey, source)
    local metadata, metadataComplete = describeMetadata(itemKey, source.link, source.info)
    local signature = slotSignature(source)
    local entry = tooltipByKey[itemKey]
    local tooltip
    if entry and entry.signature == signature and (entry.complete or entry.attempts >= MAX_TOOLTIP_ATTEMPTS) then
        tooltip = entry.tooltip
    else
        tooltip = scanTooltip(source)
        local attempts = (entry and entry.signature == signature and entry.attempts or 0) + 1
        entry = {
            signature = signature,
            tooltip = tooltip,
            complete = tooltip ~= nil and metadataComplete,
            attempts = attempts,
            resets = entry and entry.resets or 0,
            itemId = itemIdFromKey(itemKey, source.info.itemId),
        }
        tooltipByKey[itemKey] = entry
    end
    if metadataComplete and tooltip ~= nil and not entry.complete then
        entry.complete = true
    end

    local composite = compositeByKey[itemKey]
    local description
    if composite and composite.metadata == metadata and composite.tooltip == tooltip then
        description = composite.value
    else
        description = {}
        for key, value in pairs(metadata) do
            description[key] = value
        end
        description.tooltip = tooltip
        compositeByKey[itemKey] = { metadata = metadata, tooltip = tooltip, value = description }
    end

    local retry = not entry.complete and entry.attempts < MAX_TOOLTIP_ATTEMPTS
    return description, retry
end

local function readContainer(bagId, slotCount)
    local freeSlots, bagFamily = call("GetContainerNumFreeSlots", bagId)
    local container = {
        bagId = bagId,
        kind = containerKind(bagId),
        name = cleanText(call("GetBagName", bagId)),
        slotCount = slotCount,
        freeSlots = 0,
        bagFamily = tonumber(bagFamily),
        item = containerItem(bagId),
        slots = {},
    }
    if bagId == BACKPACK_ID then
        container.iconFileDataId = BACKPACK_ICON
    elseif container.item then
        container.iconFileDataId = container.item.iconFileDataId
    end

    local sources = {}
    for slot = 1, slotCount do
        local info = slotInfo(bagId, slot)
        local link = info and info.link
        local itemKey = cleanText(itemStringFromLink(link))
        if info and itemKey then
            local count = math.max(1, tonumber(info.count) or 1)
            table.insert(container.slots, {
                slot = slot,
                itemKey = itemKey,
                itemId = itemIdFromKey(itemKey, info.itemId),
                count = count,
                isBound = info.isBound == true or nil,
                isReadable = info.isReadable == true or nil,
                hasLoot = info.hasLoot == true or nil,
                hasNoValue = info.hasNoValue == true or nil,
            })
            table.insert(sources, { bagId = bagId, slot = slot, link = link, info = info })
        end
    end
    container.freeSlots = tonumber(freeSlots) or (slotCount - #container.slots)
    return { container = container, sources = sources, slotCount = slotCount }
end

local function itemSort(left, right)
    return tostring(left.key) < tostring(right.key)
end

local function totalSort(left, right)
    return left.itemId < right.itemId
end

local function currentTime()
    return tonumber(safe(Globals.GetTime)) or nil
end

-- Reads the carried inventory. Returns nil when bag data is not loaded yet
-- (the backpack always has slots once it is), so a half-loaded client never
-- replaces a real inventory with an empty one.
--
-- options.incremental reads only bags marked dirty since the last read and
-- reuses the rest; without it every bag is read (tooltips still come from the
-- signature cache).
function GW.InventoryTelemetry.Collect(options)
    local incremental = type(options) == "table" and options.incremental == true
    local backpackSlots = tonumber(call("GetContainerNumSlots", BACKPACK_ID)) or 0
    if backpackSlots <= 0 then
        return nil
    end

    local fullRead = not incremental or allDirty
    local containers = {}
    local records = {}
    for _, bagId in ipairs(containerIds()) do
        local slotCount = math.min(tonumber(call("GetContainerNumSlots", bagId)) or 0, MAX_SLOTS_PER_CONTAINER)
        if slotCount > 0 then
            local record = containerRecords[bagId]
            if fullRead or dirtyBags[bagId] or not record or record.slotCount ~= slotCount then
                record = readContainer(bagId, slotCount)
                perfCount("inventory_bag_reads")
            end
            records[bagId] = record
            table.insert(containers, record)
        end
    end
    containerRecords = records
    dirtyBags = {}
    allDirty = false
    if fullRead then
        lastFullRead = currentTime()
    end

    local itemsByKey = {}
    local totalsById = {}
    local totalSlots = 0
    local totalFree = 0
    local pending = false
    local payloadContainers = {}

    for _, record in ipairs(containers) do
        local container = record.container
        for index, slotRecord in ipairs(container.slots) do
            local itemKey = slotRecord.itemKey
            -- Each distinct item is described from the first slot holding it.
            local item = itemsByKey[itemKey]
            if not item then
                local retry
                item, retry = describe(itemKey, record.sources[index])
                pending = pending or retry
                itemsByKey[itemKey] = item
            end
            local itemId = item.itemId or slotRecord.itemId
            if itemId then
                local total = totalsById[itemId] or { itemId = itemId, count = 0, stacks = 0 }
                total.count = total.count + slotRecord.count
                total.stacks = total.stacks + 1
                totalsById[itemId] = total
            end
        end
        -- As in game, the keyring does not count toward bag space.
        if container.kind ~= "keyring" then
            totalSlots = totalSlots + container.slotCount
            totalFree = totalFree + container.freeSlots
        end
        table.insert(payloadContainers, container)
    end

    local items = {}
    local incomplete = 0
    for itemKey, item in pairs(itemsByKey) do
        table.insert(items, item)
        local entry = tooltipByKey[itemKey]
        if entry and not entry.complete then
            incomplete = incomplete + 1
        end
    end
    table.sort(items, itemSort)
    incompleteKeys = incomplete

    local totals = {}
    for _, total in pairs(totalsById) do
        table.insert(totals, total)
    end
    table.sort(totals, totalSort)

    return {
        scope = "carried",
        source = containerApi() and "C_Container" or "legacy",
        money = { copper = math.max(0, math.floor(tonumber(safe(Globals.GetMoney)) or 0)) },
        slotCount = totalSlots,
        freeSlots = totalFree,
        containers = payloadContainers,
        items = items,
        totals = totals,
    }, pending
end

-- Scans and caches the inventory for a character. Returns the payload (nil
-- when bags are not readable) and whether some item info was still loading.
function GW.InventoryTelemetry.Refresh(characterKey, options)
    local payload, pending = GW.InventoryTelemetry.Collect(options)
    if payload and characterKey then
        latestByCharacter[characterKey] = payload
        payloadRevision = payloadRevision + 1
    end
    return payload, pending
end

-- Money changes do not touch the bags: the last payload is reused with the
-- new amount (no slot reads, no tooltip scans). Returns nil when there is no
-- earlier scan to update.
function GW.InventoryTelemetry.RefreshMoney(characterKey)
    local latest = characterKey and latestByCharacter[characterKey] or nil
    if not latest then
        return nil
    end
    local payload = {}
    for key, value in pairs(latest) do
        payload[key] = value
    end
    payload.money = { copper = math.max(0, math.floor(tonumber(safe(Globals.GetMoney)) or 0)) }
    latestByCharacter[characterKey] = payload
    payloadRevision = payloadRevision + 1
    return payload, false
end

-- Changes whenever a new payload is cached (see the inventory domain).
function GW.InventoryTelemetry.PayloadRevision(characterKey)
    if not characterKey or not latestByCharacter[characterKey] then
        return nil
    end
    return payloadRevision
end

function GW.InventoryTelemetry.MarkBagDirty(bagId)
    bagId = tonumber(bagId)
    if bagId then
        dirtyBags[bagId] = true
    else
        allDirty = true
    end
end

function GW.InventoryTelemetry.MarkAllDirty()
    allDirty = true
end

function GW.InventoryTelemetry.HasDirtyBags()
    return allDirty or next(dirtyBags) ~= nil
end

-- Seconds since the last read of every bag, or nil if there was none.
function GW.InventoryTelemetry.SecondsSinceFullRead()
    local current = currentTime()
    if not lastFullRead or not current then
        return nil
    end
    return current - lastFullRead
end

-- Item data arrived for itemId: allow one more attempt for incomplete
-- descriptions of that item. Returns whether anything became retryable.
function GW.InventoryTelemetry.NoteItemInfo(itemId)
    itemId = tonumber(itemId)
    if not itemId or incompleteKeys == 0 then
        return false
    end
    local retryable = false
    for _, entry in pairs(tooltipByKey) do
        if entry.itemId == itemId and not entry.complete and entry.resets < MAX_ITEM_INFO_RESETS then
            entry.resets = entry.resets + 1
            entry.attempts = math.min(entry.attempts, MAX_TOOLTIP_ATTEMPTS - 1)
            retryable = true
        end
    end
    return retryable
end

-- Whether any cached description is incomplete and may still be retried.
function GW.InventoryTelemetry.HasPendingItems()
    for _, entry in pairs(tooltipByKey) do
        if not entry.complete and entry.attempts < MAX_TOOLTIP_ATTEMPTS then
            return true
        end
    end
    return false
end

-- The last scanned inventory, or nil.
function GW.InventoryTelemetry.Latest(characterKey)
    return characterKey and latestByCharacter[characterKey] or nil
end

-- The last scanned inventory, scanning now if there is none yet.
function GW.InventoryTelemetry.Current(characterKey)
    if not characterKey then
        return nil
    end
    return latestByCharacter[characterKey] or (GW.InventoryTelemetry.Refresh(characterKey))
end

function GW.InventoryTelemetry.ResetCache()
    describedItems = {}
    latestByCharacter = {}
    tooltipByKey = {}
    compositeByKey = {}
    containerRecords = {}
    dirtyBags = {}
    allDirty = true
    lastFullRead = nil
    incompleteKeys = 0
end
