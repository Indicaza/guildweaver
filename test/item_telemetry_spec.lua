local function equal(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function truthy(value, label)
    if not value then
        error((label or "value") .. ": expected truthy value", 2)
    end
end

GuildweaverDB = nil
GetServerTime = function() return 1791322510 end
GetRealmName = function() return "Classic Beta PvE 2" end
UIParent = {}

rawset(_G, "GetItemStats", function()
    return {
        ITEM_MOD_STAMINA_SHORT = 8,
        ITEM_MOD_STRENGTH_SHORT = 5,
        NOT_NUMERIC = "ignored",
    }
end)

rawset(_G, "GetInventoryItemDurability", function(slotId)
    equal(slotId, 5, "durability slot")
    return 42, 50
end)

rawset(_G, "GetItemSpell", function()
    return "Helm Effect", 9001
end)

GetItemInfo = function(itemLink)
    return "Golem Skull Helm", itemLink, 3, 35, 20, "Armor", "Plate", 1,
        "INVTYPE_HEAD", 132767, 12345, 4, 4, 1, 0, 77, false
end

-- Forever may return a valid-looking but incomplete C_TooltipInfo payload.
-- The hidden rendered GameTooltip below is deliberately richer and must win.
rawset(_G, "C_TooltipInfo", {
    GetHyperlink = function()
        return {
            lines = {
                { leftText = "Golem Skull Helm", leftColor = { r = 0, g = 0.44, b = 0.87, a = 1 } },
                { leftText = "Plate" },
                { leftText = "Requires Level 20" },
            },
        }
    end,
})

local rendered = {
    { left = "Golem Skull Helm", color = { 0, 0.44, 0.87, 1 } },
    { left = "Binds when picked up", color = { 1, 1, 1, 1 } },
    { left = "Head", right = "Plate", color = { 1, 1, 1, 1 } },
    { left = "120 Armor", color = { 1, 1, 1, 1 } },
    { left = "+5 Strength", color = { 1, 1, 1, 1 } },
    { left = "+8 Stamina", color = { 1, 1, 1, 1 } },
    false,
    { left = "Durability 42 / 50", color = { 1, 1, 1, 1 } },
    { left = "Requires Level 20", color = { 1, 1, 1, 1 } },
    { left = "Equip: Helm Effect", color = { 0, 1, 0, 1 } },
    { left = "Owned by Player-4620-014B5E8E", color = { 1, 1, 1, 1 } },
}

local scannerMethod = nil
local scanner = {
    SetOwner = function() end,
    ClearLines = function() end,
    SetInventoryItem = function(_, unit, slotId)
        equal(unit, "player", "inventory tooltip unit")
        equal(slotId, 5, "inventory tooltip slot")
        scannerMethod = "SetInventoryItem"
    end,
    SetHyperlink = function()
        scannerMethod = "SetHyperlink"
    end,
    SetLootItem = function(_, slot)
        equal(slot, 2, "loot tooltip slot")
        scannerMethod = "SetLootItem"
    end,
    NumLines = function()
        return #rendered
    end,
    Hide = function() end,
}

CreateFrame = function(frameType, name)
    equal(frameType, "GameTooltip", "scanner frame type")
    equal(name, "GuildweaverItemScanTooltip", "scanner frame name")
    return scanner
end

local function fontString(index, side)
    return {
        GetText = function()
            local line = rendered[index]
            if not line then return nil end
            return line[side]
        end,
        GetTextColor = function()
            local line = rendered[index]
            local color = line and line.color or { 1, 1, 1, 1 }
            return color[1], color[2], color[3], color[4]
        end,
    }
end

for index = 1, #rendered do
    rawset(_G, "GuildweaverItemScanTooltipTextLeft" .. index, fontString(index, "left"))
    rawset(_G, "GuildweaverItemScanTooltipTextRight" .. index, fontString(index, "right"))
end

local addon = { version = "test" }
local function loadAddonFile(path)
    local chunk = assert(loadfile(path))
    return chunk("Guildweaver", addon)
end

loadAddonFile("Data/Store.lua")
addon.Store.Initialize()
loadAddonFile("Data/CharacterIdentity.lua")
loadAddonFile("Data/ItemTelemetry.lua")
loadAddonFile("Data/TelemetrySchema.lua")

local snapshot = {
    schemaVersion = 2,
    capturedAt = 1791322510,
    characterKey = "classic beta pve 2:rook",
    characterId = "character-rook",
    name = "Rook",
    realm = "Classic Beta PvE 2",
    level = 22,
    race = { id = 4, file = "NightElf", name = "Night Elf" },
    class = { id = 1, file = "WARRIOR", name = "Warrior" },
    gameBuild = { build = "70245", version = "1.60.1", interface = 16001 },
    equipment = {
        {
            slot = "HeadSlot",
            slotId = 5,
            itemId = 11746,
            itemLink = "|cff0070dd|Hitem:11746::::::::22:::::::|h[Golem Skull Helm]|h|r",
            quality = 3,
            itemLevel = 35,
            icon = 132767,
            class = "Armor",
            subclass = "Plate",
            classId = 4,
            subclassId = 4,
            equipLocation = "INVTYPE_HEAD",
        },
    },
}

addon.Store.SetCharacterSnapshot(snapshot.characterKey, snapshot)

local item = snapshot.equipment[1]
equal(snapshot.schemaVersion, 3, "schema normalized before enrichment")
equal(item.itemId, 11746, "item id retained")
equal(item.stackCount, 1, "stack count")
equal(item.sellPrice, 12345, "sell price")
equal(item.requiredLevel, 20, "required level")
equal(item.stats.ITEM_MOD_STAMINA_SHORT, 8, "stamina stat")
equal(item.stats.ITEM_MOD_STRENGTH_SHORT, 5, "strength stat")
equal(item.stats.NOT_NUMERIC, nil, "non-numeric stat ignored")
equal(item.durability.current, 42, "durability current")
equal(item.durability.max, 50, "durability max")
equal(item.spell.name, "Helm Effect", "item spell name")
equal(item.spell.id, 9001, "item spell id")
equal(scannerMethod, "SetInventoryItem", "equipment scans actual inventory slot")
equal(item.tooltip.source, "GameTooltip", "rendered tooltip source")
equal(item.tooltip.method, "SetInventoryItem", "rendered tooltip method")
equal(item.tooltip.rendered, true, "rendered tooltip marker")
equal(item.tooltip.complete, true, "full tooltip marker")
equal(#item.tooltip.lines, #rendered, "full rendered line count")
equal(item.tooltip.lines[2].left, "Binds when picked up", "tooltip binding line")
equal(item.tooltip.lines[4].left, "120 Armor", "armor line retained")
equal(item.tooltip.lines[7].blank, true, "blank section line retained")
equal(item.tooltip.lines[8].left, "Durability 42 / 50", "durability line retained")
equal(item.tooltip.lines[10].left, "Equip: Helm Effect", "effect line retained")
truthy(item.tooltip.lines[1].leftColor, "tooltip color retained")
truthy(item.tooltip.lines[11].left:find("Player%-REDACTED"), "tooltip guid scrubbed")
equal(item.tooltip.lines[11].left:find("014B5E8E"), nil, "raw player guid removed")
equal(addon.ItemTelemetry.IsFullTooltip(item.tooltip), true, "full tooltip recognized")

-- Generic item descriptions also prefer the rendered GameTooltip over the
-- incomplete structured API.
scannerMethod = nil
local generic = addon.ItemTelemetry.Describe(item.itemLink, { details = true })
equal(scannerMethod, "SetHyperlink", "generic item scans rendered hyperlink")
equal(generic.tooltip.source, "GameTooltip", "generic rendered source")
equal(generic.tooltip.lines[4].left, "120 Armor", "generic tooltip remains full")

scannerMethod = nil
local base = addon.ItemTelemetry.BaseDefinition(item.itemId)
equal(scannerMethod, "SetHyperlink", "base item uses generic hyperlink")
equal(base.itemLink, nil, "base definition never retains observed instance link")
equal(base.itemId, item.itemId, "base item identity")
equal(addon.ItemTelemetry.BaseDefinition(0), nil, "invalid base id omitted")

-- Fresh gathering loot must be captured from the actual loot slot while the
-- window is still open, not reconstructed later from a hyperlink.
scannerMethod = nil
local lootTooltip = addon.ItemTelemetry.LootItemTooltip(2, item.itemLink)
equal(scannerMethod, "SetLootItem", "loot item scans actual loot slot")
equal(lootTooltip.source, "GameTooltip", "loot rendered source")
equal(lootTooltip.method, "SetLootItem", "loot rendered method")
equal(lootTooltip.complete, true, "loot tooltip complete")
equal(lootTooltip.lines[4].left, "120 Armor", "loot tooltip keeps full lines")

-- Items the client has not cached yet: GetItemInfo returns nothing, but the
-- icon still comes from the instant (static) item data.
GetItemInfo = function() return nil end
rawset(_G, "GetItemInfoInstant", function(itemId)
    if tonumber(itemId) == 2840 then
        return 2840, "Trade Goods", "Metal & Stone", "", 133216, 7, 7
    end
end)
local uncached = addon.ItemTelemetry.Describe(2840, { tooltip = false })
equal(uncached.itemId, 2840, "uncached item id")
equal(uncached.name, nil, "uncached item has no name yet")
equal(uncached.iconFileDataId, 133216, "uncached item icon from instant data")
rawset(_G, "GetItemInfoInstant", nil)

print("item telemetry spec passed")
