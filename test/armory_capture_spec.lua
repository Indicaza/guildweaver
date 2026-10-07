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
GetServerTime = function() return 2000 end
GetRealmName = function() return "Classic Beta PvE 2" end
GetItemInfoInstant = nil

C_Item = {
    GetItemInfoInstant = function()
        return 273088, "Armor", "Miscellaneous", "INVTYPE_NECK", 134123, 4, 0
    end,
}

C_TooltipInfo = {
    GetInventoryItem = function(_, slotId)
        equal(slotId, 2, "tooltip slot")
        return {
            lines = {
                { leftText = "Snake Eye Kaleidoscope" },
                { leftText = "Item Level 22" },
                { leftText = "+4 Agility", rightText = "+3 Stamina" },
            },
        }
    end,
}

local GW = { version = "test" }
assert(loadfile("Data/Store.lua"))("Guildweaver", GW)
GW.Store.Initialize()
assert(loadfile("Data/CharacterIdentity.lua"))("Guildweaver", GW)
assert(loadfile("Data/ArmoryCapture.lua"))("Guildweaver", GW)

local snapshot = {
    schemaVersion = 2,
    capturedAt = 2000,
    name = "Rook",
    realm = "Darkwing",
    equipment = {
        {
            slot = "NeckSlot",
            slotId = 2,
            itemId = 273088,
            itemLink = "|cff0070dd|Hitem:273088::::::::22:::::::|h[Snake Eye Kaleidoscope]|h|r",
            icon = "Interface\\Icons\\INV_Misc_Gem_Pearl_05",
        },
    },
}

GW.Store.SetCharacterSnapshot("darkwing:rook", snapshot)

local item = snapshot.equipment[1]
equal(snapshot.schemaVersion, 3, "identity schema")
equal(snapshot.displayName, "Rook Darkwing", "display name")
equal(item.iconTexture, "Interface\\Icons\\INV_Misc_Gem_Pearl_05", "client texture path")
equal(item.iconFileDataId, 134123, "instant icon file id")
equal(item.class, "Armor", "instant class")
equal(item.subclass, "Miscellaneous", "instant subclass")
equal(item.equipLocation, "INVTYPE_NECK", "instant equip location")
truthy(item.tooltipLines, "tooltip lines")
equal(item.tooltipLines[2].left, "Item Level 22", "tooltip text")
equal(item.tooltipLines[3].right, "+3 Stamina", "tooltip right text")

print("armory capture spec passed")
