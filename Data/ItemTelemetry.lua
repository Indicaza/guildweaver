local _, GW = ...

local Globals = _G or {}
local MAX_TOOLTIP_LINES = 40
local MAX_TOOLTIP_TEXT = 600
local tooltipScanner = nil
local tooltipScannerInitialized = false

local function cleanText(value)
    if type(value) ~= "string" then
        return nil
    end

    local text = value:gsub("Player%-%d+%-%x+", "Player-REDACTED")
    if #text > MAX_TOOLTIP_TEXT then
        text = text:sub(1, MAX_TOOLTIP_TEXT)
    end
    return text ~= "" and text or nil
end

local function colorValue(value)
    if type(value) ~= "table" then
        return nil
    end

    local r = tonumber(value.r)
    local g = tonumber(value.g)
    local b = tonumber(value.b)
    local a = tonumber(value.a)
    if not r and not g and not b and not a then
        return nil
    end

    return {
        r = r,
        g = g,
        b = b,
        a = a,
    }
end

-- Enum.TooltipDataLineType values the client draws without text of their own.
local LINE_TYPE_BLANK = 1
local LINE_TYPE_SELL_PRICE = 11
local LINE_TYPE_SEPARATOR = 23

local function normalizeTooltipLine(line)
    if type(line) ~= "table" then
        return nil
    end

    local lineType = tonumber(line.type)
    -- The sell price is drawn as money from the item's own sell price.
    if lineType == LINE_TYPE_SELL_PRICE then
        return nil
    end

    local left = cleanText(line.leftText or line.text or line.left)
    local right = cleanText(line.rightText or line.right)
    if not left and not right then
        -- Blank lines and separators space the tooltip's sections apart.
        if lineType == LINE_TYPE_BLANK or lineType == LINE_TYPE_SEPARATOR then
            return { blank = true }
        end
        return nil
    end

    local offset = tonumber(line.leftOffset)
    return {
        left = left,
        right = right,
        leftColor = colorValue(line.leftColor or line.color),
        rightColor = colorValue(line.rightColor),
        offset = offset and offset > 0 and offset or nil,
    }
end

-- C_TooltipInfo.<method>(...): GetHyperlink(link) for an item in general,
-- GetBagItem(bag, slot) for the item a bag slot actually holds.
local function collectModernTooltip(method, ...)
    local tooltipInfo = Globals.C_TooltipInfo
    if type(tooltipInfo) ~= "table" or type(tooltipInfo[method]) ~= "function" then
        return nil
    end

    local ok, data = pcall(tooltipInfo[method], ...)
    if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then
        return nil
    end

    local lines = {}
    for _, line in ipairs(data.lines) do
        if #lines >= MAX_TOOLTIP_LINES then
            break
        end
        local normalized = normalizeTooltipLine(line)
        if normalized then
            table.insert(lines, normalized)
        end
    end

    return #lines > 0 and { source = "C_TooltipInfo", lines = lines } or nil
end

local function scannerFrame()
    if tooltipScannerInitialized then
        return tooltipScanner
    end
    tooltipScannerInitialized = true

    if type(CreateFrame) ~= "function" or not UIParent then
        return nil
    end

    local ok, frame = pcall(CreateFrame, "GameTooltip", "GuildweaverItemScanTooltip", UIParent, "GameTooltipTemplate")
    if not ok or not frame then
        return nil
    end

    tooltipScanner = frame
    return tooltipScanner
end

local function fontStringText(value)
    if not value or type(value.GetText) ~= "function" then
        return nil
    end
    local ok, text = pcall(value.GetText, value)
    return ok and cleanText(text) or nil
end

local function fontStringColor(value)
    if not value or type(value.GetTextColor) ~= "function" then
        return nil
    end
    local ok, r, g, b, a = pcall(value.GetTextColor, value)
    if not ok then
        return nil
    end
    return colorValue({ r = r, g = g, b = b, a = a })
end

-- GameTooltip:<method>(...) on a hidden scanner: SetHyperlink(link) or
-- SetBagItem(bag, slot).
local function collectLegacyTooltip(method, ...)
    local frame = scannerFrame()
    if not frame or type(frame[method]) ~= "function" or type(frame.NumLines) ~= "function" then
        return nil
    end

    if type(frame.SetOwner) == "function" then
        pcall(frame.SetOwner, frame, UIParent, "ANCHOR_NONE")
    end
    if type(frame.ClearLines) == "function" then
        pcall(frame.ClearLines, frame)
    end

    local ok = pcall(frame[method], frame, ...)
    if not ok then
        return nil
    end

    local linesOk, lineCount = pcall(frame.NumLines, frame)
    if not linesOk then
        return nil
    end

    local lines = {}
    local count = math.min(tonumber(lineCount) or 0, MAX_TOOLTIP_LINES)
    for index = 1, count do
        local leftField = Globals["GuildweaverItemScanTooltipTextLeft" .. index]
        local rightField = Globals["GuildweaverItemScanTooltipTextRight" .. index]
        local left = fontStringText(leftField)
        local right = fontStringText(rightField)
        if left or right then
            table.insert(lines, {
                left = left,
                right = right,
                leftColor = fontStringColor(leftField),
                rightColor = fontStringColor(rightField),
            })
        end
    end

    if type(frame.Hide) == "function" then
        pcall(frame.Hide, frame)
    end

    return #lines > 0 and { source = "GameTooltip", lines = lines } or nil
end

local function collectTooltip(itemLink)
    if type(itemLink) ~= "string" or itemLink == "" then
        return nil
    end
    return collectModernTooltip("GetHyperlink", itemLink) or collectLegacyTooltip("SetHyperlink", itemLink)
end

local function collectStats(itemLink)
    local getItemStats = Globals.GetItemStats
    if type(getItemStats) ~= "function" then
        return nil
    end

    local ok, stats = pcall(getItemStats, itemLink)
    if not ok or type(stats) ~= "table" then
        return nil
    end

    local result = {}
    local count = 0
    for key, value in pairs(stats) do
        if type(key) == "string" and type(value) == "number" then
            result[key:sub(1, 96)] = value
            count = count + 1
            if count >= 64 then
                break
            end
        end
    end

    return next(result) and result or nil
end

local function collectDurability(slotId)
    local getDurability = Globals.GetInventoryItemDurability
    if not slotId or type(getDurability) ~= "function" then
        return nil
    end

    local ok, current, maximum = pcall(getDurability, slotId)
    if not ok or not tonumber(maximum) or tonumber(maximum) <= 0 then
        return nil
    end

    return {
        current = tonumber(current) or 0,
        max = tonumber(maximum),
    }
end

local function collectSpell(itemLink)
    local getItemSpell = Globals.GetItemSpell
    if type(getItemSpell) ~= "function" then
        return nil
    end

    local ok, name, spellId = pcall(getItemSpell, itemLink)
    if not ok or (not name and not spellId) then
        return nil
    end

    return {
        name = cleanText(name),
        id = tonumber(spellId),
    }
end

local function enrichMetadata(item, itemLink)
    if type(GetItemInfo) ~= "function" then
        return
    end

    local ok, name, link, quality, itemLevel, requiredLevel, itemClass, itemSubclass, stackCount, equipLocation, icon, sellPrice, classId, subclassId, bindType, expansionId, setId, isCraftingReagent = pcall(GetItemInfo, itemLink)
    if not ok then
        return
    end

    item.name = item.name or cleanText(name)
    item.itemLink = item.itemLink or cleanText(link)
    item.qualityId = item.qualityId or quality
    item.itemLevel = item.itemLevel or itemLevel
    item.requiredLevel = item.requiredLevel or requiredLevel
    item.iconFileDataId = item.iconFileDataId or icon
    item.stackCount = item.stackCount or stackCount
    item.sellPrice = item.sellPrice or sellPrice
    item.equipLocation = item.equipLocation or equipLocation
    item.bindType = item.bindType or bindType
    item.expansionId = item.expansionId or expansionId
    item.setId = item.setId or setId
    if item.isCraftingReagent == nil then
        item.isCraftingReagent = isCraftingReagent
    end
    if not item.itemClass and (classId or itemClass) then
        item.itemClass = { id = classId, name = itemClass }
    end
    if not item.itemSubclass and (subclassId or itemSubclass) then
        item.itemSubclass = { id = subclassId, name = itemSubclass }
    end
end

local function enrichEquipmentItem(item)
    if type(item) ~= "table" then
        return
    end

    local itemLink = item.itemLink
    if type(itemLink) ~= "string" or itemLink == "" then
        return
    end

    enrichMetadata(item, itemLink)
    item.stats = collectStats(itemLink) or item.stats
    item.durability = collectDurability(item.slotId) or item.durability
    item.spell = collectSpell(itemLink) or item.spell
    item.tooltip = collectTooltip(itemLink) or item.tooltip
end

-- Shared item description for any telemetry domain (recipes, reagents,
-- inventory, ...): identity, metadata, and tooltip for an item ID or link.
-- options.tooltip = false skips the tooltip; options.details = true adds stats
-- and the use/equip spell. Equipment-only data (durability, socket state)
-- stays in enrichEquipmentItem.
local function describeItem(itemIdOrLink, options)
    local itemLink = itemIdOrLink
    local itemId = tonumber(itemIdOrLink)
    if itemId then
        itemLink = "item:" .. itemId
    elseif type(itemIdOrLink) == "string" and itemIdOrLink ~= "" then
        itemId = tonumber(itemIdOrLink:match("item:(%d+)"))
    else
        return nil
    end

    local item = { itemId = itemId }
    if type(itemIdOrLink) == "string" and itemIdOrLink:find("|H", 1, true) then
        item.itemLink = cleanText(itemIdOrLink)
    end
    enrichMetadata(item, itemLink)
    -- GetItemInfo returns nothing until the client has cached the item, but
    -- the icon is in the static item data and always available instantly.
    if not item.iconFileDataId and itemId and type(Globals.GetItemInfoInstant) == "function" then
        local ok, _, _, _, _, icon = pcall(Globals.GetItemInfoInstant, itemId)
        if ok and tonumber(icon) then
            item.iconFileDataId = tonumber(icon)
        end
    end
    if not (type(options) == "table" and options.tooltip == false) then
        item.tooltip = collectTooltip(item.itemLink or itemLink)
    end
    if type(options) == "table" and options.details == true then
        item.stats = collectStats(item.itemLink or itemLink)
        item.spell = collectSpell(item.itemLink or itemLink)
    end
    return item
end

local originalSetCharacterSnapshot = GW.Store.SetCharacterSnapshot

function GW.Store.SetCharacterSnapshot(characterKey, snapshot)
    if type(snapshot) == "table" and type(snapshot.equipment) == "table" then
        for _, item in ipairs(snapshot.equipment) do
            enrichEquipmentItem(item)
        end
    end

    return originalSetCharacterSnapshot(characterKey, snapshot)
end

GW.ItemTelemetry = GW.ItemTelemetry or {}
GW.ItemTelemetry.EnrichEquipmentItem = enrichEquipmentItem
GW.ItemTelemetry.Describe = describeItem

-- The tooltip of the item in a bag slot, as the player sees it when hovering
-- it: binding, durability, charges and other per-item lines included.
function GW.ItemTelemetry.BagItemTooltip(bagId, slot)
    if not bagId or not slot then
        return nil
    end
    return collectModernTooltip("GetBagItem", bagId, slot) or collectLegacyTooltip("SetBagItem", bagId, slot)
end
