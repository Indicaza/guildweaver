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

local LINE_TYPE_BLANK = 1
local LINE_TYPE_SELL_PRICE = 11
local LINE_TYPE_SEPARATOR = 23

local function normalizeTooltipLine(line)
    if type(line) ~= "table" then
        return nil
    end

    local lineType = tonumber(line.type)
    if lineType == LINE_TYPE_SELL_PRICE then
        return { sellPrice = true }
    end

    local left = cleanText(line.leftText or line.text or line.left)
    local right = cleanText(line.rightText or line.right)
    if not left and not right then
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

-- Structured tooltip APIs are useful as a compatibility fallback, but Forever
-- can return a syntactically valid subset of the tooltip. Never call this
-- authoritative: the rendered GameTooltip scanner below is the source of truth.
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

    return #lines > 0 and {
        source = "C_TooltipInfo",
        rendered = false,
        complete = false,
        lines = lines,
    } or nil
end

local function scannerFrame()
    if tooltipScannerInitialized then
        return tooltipScanner
    end
    tooltipScannerInitialized = true

    local createFrame = Globals.CreateFrame or CreateFrame
    local parent = Globals.UIParent or UIParent
    if type(createFrame) ~= "function" or not parent then
        return nil
    end

    local ok, frame = pcall(createFrame, "GameTooltip", "GuildweaverItemScanTooltip", parent, "GameTooltipTemplate")
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

-- Scan the exact GameTooltip the client renders. This preserves Forever-only
-- armor/stat/effect/binding/set text instead of trying to reconstruct it from
-- item metadata. Empty rendered rows are retained because Blizzard uses them
-- to separate tooltip sections.
local function collectLegacyTooltip(method, ...)
    local frame = scannerFrame()
    if not frame or type(frame[method]) ~= "function" or type(frame.NumLines) ~= "function" then
        return nil
    end

    local parent = Globals.UIParent or UIParent
    if type(frame.SetOwner) == "function" then
        pcall(frame.SetOwner, frame, parent, "ANCHOR_NONE")
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
    local textLines = 0
    local count = math.min(tonumber(lineCount) or 0, MAX_TOOLTIP_LINES)
    for index = 1, count do
        local leftField = Globals["GuildweaverItemScanTooltipTextLeft" .. index]
        local rightField = Globals["GuildweaverItemScanTooltipTextRight" .. index]
        local left = fontStringText(leftField)
        local right = fontStringText(rightField)
        if left or right then
            textLines = textLines + 1
            table.insert(lines, {
                left = left,
                right = right,
                leftColor = fontStringColor(leftField),
                rightColor = fontStringColor(rightField),
            })
        else
            table.insert(lines, { blank = true })
        end
    end

    if type(frame.Hide) == "function" then
        pcall(frame.Hide, frame)
    end

    if textLines == 0 then
        return nil
    end

    return {
        source = "GameTooltip",
        method = method,
        rendered = true,
        complete = true,
        lines = lines,
    }
end

local function collectTooltip(itemLink)
    if type(itemLink) ~= "string" or itemLink == "" then
        return nil
    end
    return collectLegacyTooltip("SetHyperlink", itemLink)
        or collectModernTooltip("GetHyperlink", itemLink)
end

local function collectEquipmentTooltip(slotId, itemLink)
    if tonumber(slotId) then
        local tooltip = collectLegacyTooltip("SetInventoryItem", "player", tonumber(slotId))
        if tooltip then
            return tooltip
        end
    end
    return collectTooltip(itemLink)
end

local function collectBagTooltip(bagId, slot, itemLink)
    local tooltip = collectLegacyTooltip("SetBagItem", bagId, slot)
    if tooltip then
        return tooltip
    end
    tooltip = collectModernTooltip("GetBagItem", bagId, slot)
    if tooltip and tooltip.complete then
        return tooltip
    end
    if type(itemLink) == "string" and itemLink ~= "" then
        return collectLegacyTooltip("SetHyperlink", itemLink) or tooltip or collectModernTooltip("GetHyperlink", itemLink)
    end
    return tooltip
end

-- Loot windows are the richest and most reliable place to describe freshly
-- gathered materials. Capture the actual slot before auto-loot closes it;
-- hyperlink scanning afterwards may be incomplete forever on Forever.
local function collectLootTooltip(slot, itemLink)
    if tonumber(slot) then
        local tooltip = collectLegacyTooltip("SetLootItem", tonumber(slot))
        if tooltip then
            return tooltip
        end
    end
    return collectTooltip(itemLink)
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
    item.tooltip = collectEquipmentTooltip(item.slotId, itemLink) or item.tooltip
end

-- Shared item description for recipes, reagents, loot, inventory, etc. A
-- generic hyperlink scan still comes from the rendered GameTooltip first.
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
GW.ItemTelemetry.IsFullTooltip = function(tooltip)
    return type(tooltip) == "table"
        and tooltip.complete == true
        and tooltip.rendered == true
        and tooltip.source == "GameTooltip"
        and type(tooltip.lines) == "table"
        and #tooltip.lines > 0
end

function GW.ItemTelemetry.BagItemTooltip(bagId, slot, itemLink)
    if bagId == nil or not slot then
        return nil
    end
    return collectBagTooltip(bagId, slot, itemLink)
end

function GW.ItemTelemetry.LootItemTooltip(slot, itemLink)
    if not slot then
        return nil
    end
    return collectLootTooltip(slot, itemLink)
end

function GW.ItemTelemetry.BaseDefinition(itemId)
    itemId = tonumber(itemId)
    if not itemId or itemId <= 0 then return nil end
    local link = "item:" .. tostring(itemId)
    local item = { itemId = itemId }
    enrichMetadata(item, link)
    item.itemLink = nil
    item.tooltip = collectTooltip(link)
    item.stats = collectStats(link)
    item.spell = collectSpell(link)
    return item
end
