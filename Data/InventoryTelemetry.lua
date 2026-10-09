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
local KEYRING_ID = -2
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

-- The reagent bag only exists on clients whose bag index enum names one; on
-- classic clients the id after the last bag is the first bank bag, which must
-- never be read as carried inventory.
local function reagentBagId()
    local bagIndex = type(Globals.Enum) == "table" and Globals.Enum.BagIndex or nil
    local reagent = type(bagIndex) == "table" and tonumber(bagIndex.ReagentBag) or nil
    if not reagent then
        return nil
    end
    for key, value in pairs(bagIndex) do
        if type(key) == "string" and key:find("^Bank") and tonumber(value) == reagent then
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
    table.insert(ids, KEYRING_ID)
    return ids
end

local function containerKind(bagId)
    if bagId == BACKPACK_ID then
        return "backpack"
    end
    if bagId == KEYRING_ID then
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

-- What the item is, described once per item string per session through the
-- shared item enrichment (descriptions the client could not fill yet are
-- retried on the next scan). The tooltip is read fresh from the bag slot on
-- every scan, as the player would see it when hovering the item.
local function describe(itemKey, link, info, bagId, slot)
    local cached = describedItems[itemKey]
    local complete = cached ~= nil
    if not cached then
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
        complete = item.name ~= nil
        if complete then
            describedItems[itemKey] = cached
        end
    end

    local bagTooltip = GW.ItemTelemetry and GW.ItemTelemetry.BagItemTooltip
    local tooltip = type(bagTooltip) == "function" and stableTooltip(bagTooltip(bagId, slot)) or nil
    if not tooltip and GW.ItemTelemetry and type(GW.ItemTelemetry.Describe) == "function" then
        local ok, value = pcall(GW.ItemTelemetry.Describe, link)
        tooltip = ok and type(value) == "table" and stableTooltip(value.tooltip) or nil
    end

    local description = {}
    for key, value in pairs(cached) do
        description[key] = value
    end
    description.tooltip = tooltip
    -- Names and tooltips load separately; a description missing either is
    -- reported so the scan is retried.
    return description, complete and tooltip ~= nil
end

local function itemSort(left, right)
    return tostring(left.key) < tostring(right.key)
end

-- Reads the carried inventory. Returns nil when bag data is not loaded yet
-- (the backpack always has slots once it is), so a half-loaded client never
-- replaces a real inventory with an empty one.
function GW.InventoryTelemetry.Collect()
    local backpackSlots = tonumber(call("GetContainerNumSlots", BACKPACK_ID)) or 0
    if backpackSlots <= 0 then
        return nil
    end

    local containers = {}
    local itemsByKey = {}
    local totalsById = {}
    local totalSlots = 0
    local totalFree = 0
    local pending = false

    for _, bagId in ipairs(containerIds()) do
        local slotCount = math.min(tonumber(call("GetContainerNumSlots", bagId)) or 0, MAX_SLOTS_PER_CONTAINER)
        if slotCount > 0 then
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

            for slot = 1, slotCount do
                local info = slotInfo(bagId, slot)
                local link = info and info.link
                local itemKey = cleanText(itemStringFromLink(link))
                if info and itemKey then
                    -- Each distinct item is described from the first slot holding it.
                    local item = itemsByKey[itemKey]
                    if not item then
                        local complete
                        item, complete = describe(itemKey, link, info, bagId, slot)
                        pending = pending or not complete
                        itemsByKey[itemKey] = item
                    end
                    local count = math.max(1, tonumber(info.count) or 1)
                    table.insert(container.slots, {
                        slot = slot,
                        itemKey = itemKey,
                        itemId = item.itemId,
                        count = count,
                        isBound = info.isBound == true or nil,
                        isReadable = info.isReadable == true or nil,
                        hasLoot = info.hasLoot == true or nil,
                        hasNoValue = info.hasNoValue == true or nil,
                    })
                    local itemId = item.itemId
                    if itemId then
                        local total = totalsById[itemId] or { itemId = itemId, count = 0, stacks = 0 }
                        total.count = total.count + count
                        total.stacks = total.stacks + 1
                        totalsById[itemId] = total
                    end
                end
            end

            container.freeSlots = tonumber(freeSlots) or (slotCount - #container.slots)
            -- As in game, the keyring does not count toward bag space.
            if container.kind ~= "keyring" then
                totalSlots = totalSlots + slotCount
                totalFree = totalFree + container.freeSlots
            end
            table.insert(containers, container)
        end
    end

    local items = {}
    for _, item in pairs(itemsByKey) do
        table.insert(items, item)
    end
    table.sort(items, itemSort)

    local totals = {}
    for _, total in pairs(totalsById) do
        table.insert(totals, total)
    end
    table.sort(totals, function(left, right)
        return left.itemId < right.itemId
    end)

    return {
        scope = "carried",
        source = containerApi() and "C_Container" or "legacy",
        money = { copper = math.max(0, math.floor(tonumber(safe(Globals.GetMoney)) or 0)) },
        slotCount = totalSlots,
        freeSlots = totalFree,
        containers = containers,
        items = items,
        totals = totals,
    }, pending
end

-- Scans and caches the inventory for a character. Returns the payload (nil
-- when bags are not readable) and whether some item info was still loading.
function GW.InventoryTelemetry.Refresh(characterKey)
    local payload, pending = GW.InventoryTelemetry.Collect()
    if payload and characterKey then
        latestByCharacter[characterKey] = payload
    end
    return payload, pending
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
end
