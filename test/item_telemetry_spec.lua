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

rawset(_G, "C_TooltipInfo", {
    GetHyperlink = function()
        return {
            lines = {
                { leftText = "Golem Skull Helm", leftColor = { r = 0, g = 0.44, b = 0.87, a = 1 } },
                { leftText = "Binds when picked up" },
                { leftText = "+8 Stamina" },
                { leftText = "Owned by Player-4620-014B5E8E" },
            },
        }
    end,
})

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
equal(item.tooltip.source, "C_TooltipInfo", "modern tooltip source")
equal(#item.tooltip.lines, 4, "tooltip line count")
equal(item.tooltip.lines[2].left, "Binds when picked up", "tooltip binding line")
truthy(item.tooltip.lines[1].leftColor, "tooltip color retained")
truthy(item.tooltip.lines[4].left:find("Player%-REDACTED"), "tooltip guid scrubbed")
equal(item.tooltip.lines[4].left:find("014B5E8E"), nil, "raw player guid removed")

print("item telemetry spec passed")
