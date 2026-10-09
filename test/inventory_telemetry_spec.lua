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
local now = 1791322510
GetServerTime = function() return now end

-- Two bags: the backpack (copper ore x2 stacks, a bound sword) and an
-- equipped linen bag holding one more ore stack; plus a keyring with no slots.
local ORE = "|cffffffff|Hitem:2770::::::::20:::::::|h[Copper Ore]|h|r"
local SWORD = "|cff1eff00|Hitem:15210::::::1027:0:20:::::::|h[Raider Shortsword of the Tiger]|h|r"
local bags = {
    [0] = {
        size = 16,
        slots = {
            [1] = { iconFileID = 134566, stackCount = 10, quality = 1, hyperlink = ORE, itemID = 2770, isLocked = false },
            [2] = { iconFileID = 134566, stackCount = 4, quality = 1, hyperlink = ORE, itemID = 2770 },
            [5] = { iconFileID = 135274, stackCount = 1, quality = 2, hyperlink = SWORD, itemID = 15210, isBound = true },
        },
    },
    [1] = {
        size = 6,
        name = "Linen Bag",
        slots = {
            [3] = { iconFileID = 134566, stackCount = 6, quality = 1, hyperlink = ORE, itemID = 2770 },
        },
    },
}
local money = 1234567
local itemInfoReady = true

rawset(_G, "C_Container", {
    GetContainerNumSlots = function(bagId)
        return bags[bagId] and bags[bagId].size or 0
    end,
    GetContainerNumFreeSlots = function(bagId)
        local bag = bags[bagId]
        local used = 0
        for _ in pairs(bag and bag.slots or {}) do
            used = used + 1
        end
        return (bag and bag.size or 0) - used, 0
    end,
    GetContainerItemInfo = function(bagId, slot)
        local bag = bags[bagId]
        return bag and bag.slots[slot] or nil
    end,
    GetBagName = function(bagId)
        return bagId == 0 and "Backpack" or (bags[bagId] and bags[bagId].name)
    end,
    ContainerIDToInventoryID = function(bagId)
        return 19 + bagId
    end,
})
rawset(_G, "GetInventoryItemLink", function(_, inventoryId)
    return inventoryId == 20 and "|cffffffff|Hitem:4238::::::::20:::::::|h[Linen Bag]|h|r" or nil
end)
rawset(_G, "GetInventoryItemTexture", function() return 133627 end)
rawset(_G, "GetInventoryItemQuality", function() return 1 end)
rawset(_G, "GetMoney", function() return money end)
rawset(_G, "GetItemStats", function(link)
    return link:find("15210", 1, true) and { ITEM_MOD_AGILITY_SHORT = 3 } or nil
end)

GetItemInfo = function(link)
    if not itemInfoReady then
        return nil
    end
    if tostring(link):find("15210", 1, true) then
        return "Raider Shortsword of the Tiger", link, 2, 18, 13, "Weapon", "One-Handed Swords", 1,
            "INVTYPE_WEAPON", 135274, 461, 2, 7, 2, 0, nil, false
    end
    return "Copper Ore", link, 1, 10, 0, "Trade Goods", "Metal & Stone", 20,
        "", 134566, 5, 7, 7, 0, 0, nil, true
end

rawset(_G, "C_TooltipInfo", {
    GetHyperlink = function(link)
        local name = tostring(link):match("%[(.-)%]") or "Item"
        return { lines = { { leftText = name }, { leftText = "Crafted by Player-4620-014B5E8E" } } }
    end,
})

local addon = { version = "test" }
local function loadAddonFile(path)
    local chunk = assert(loadfile(path))
    return chunk("Guildweaver", addon)
end

loadAddonFile("Data/Store.lua")
addon.Store.Initialize()
loadAddonFile("Data/TelemetryEnvelope.lua")
loadAddonFile("Data/ItemTelemetry.lua")
loadAddonFile("Data/InventoryTelemetry.lua")
loadAddonFile("Telemetry/Domain.lua")
loadAddonFile("Telemetry/Domains/Inventory.lua")

local characterSnapshot = {
    capturedAt = now - 600,
    characterKey = "darkwing:rook",
    characterId = "character-rook",
    realm = "Darkwing",
    region = "US",
}
addon.Character = {
    GetCurrentSnapshot = function() return characterSnapshot end,
}
rawset(_G, "CreateFrame", nil)
loadAddonFile("Systems/InventoryCapture.lua")

-- Payload shape ---------------------------------------------------------------

local payload = addon.InventoryTelemetry.Collect()
truthy(payload, "inventory collected")
equal(payload.scope, "carried", "scope")
equal(payload.source, "C_Container", "source")
equal(payload.money.copper, 1234567, "money")
equal(payload.slotCount, 22, "total slots")
equal(payload.freeSlots, 18, "free slots")
equal(#payload.containers, 2, "only containers with slots")

local backpack = payload.containers[1]
equal(backpack.bagId, 0, "backpack id")
equal(backpack.kind, "backpack", "backpack kind")
equal(backpack.name, "Backpack", "backpack name")
equal(backpack.iconFileDataId, 133633, "backpack icon")
equal(#backpack.slots, 3, "backpack occupied slots only")
equal(backpack.slots[1].slot, 1, "slot index")
equal(backpack.slots[1].count, 10, "stack count")
equal(backpack.slots[3].slot, 5, "sparse slot index kept")
equal(backpack.slots[3].isBound, true, "bound flag")
equal(backpack.slots[1].isBound, nil, "unbound omitted")

local bag = payload.containers[2]
equal(bag.kind, "bag", "bag kind")
equal(bag.item.itemId, 4238, "bag item id")
equal(bag.item.name, "Linen Bag", "bag item name")
equal(bag.iconFileDataId, 133627, "bag icon from inventory slot")
equal(bag.freeSlots, 5, "bag free slots")

equal(#payload.items, 2, "distinct items described once")
local ore, sword
for _, item in ipairs(payload.items) do
    if item.itemId == 2770 then ore = item end
    if item.itemId == 15210 then sword = item end
end
truthy(ore and sword, "both items described")
equal(ore.key, "item:2770::::::::20:::::::", "item key is the item string")
equal(ore.name, "Copper Ore", "item name")
equal(ore.maxStackSize, 20, "max stack size (not the slot count)")
equal(ore.sellPrice, 5, "sell price")
equal(ore.itemClass.name, "Trade Goods", "item class")
equal(ore.itemSubclass.id, 7, "item subclass")
equal(ore.isCraftingReagent, true, "crafting reagent")
equal(ore.tooltip.lines[2].left, "Crafted by Player-REDACTED", "tooltip redacts player GUIDs")
equal(sword.suffixId, 1027, "random suffix parsed from the item string")
equal(sword.stats.ITEM_MOD_AGILITY_SHORT, 3, "shared stats enrichment")
equal(sword.requiredLevel, 13, "required level")
equal(sword.bindType, 2, "bind type")

equal(#payload.totals, 2, "totals per item id")
equal(payload.totals[1].itemId, 2770, "totals sorted by item id")
equal(payload.totals[1].count, 20, "ore summed across bags")
equal(payload.totals[1].stacks, 3, "ore stacks")
equal(payload.totals[2].count, 1, "sword count")

-- Publishing, revisions, dedupe -----------------------------------------------

local first = addon.InventoryCapture.Publish("BAG_UPDATE_DELAYED")
truthy(first.changed, "first publish")
equal(first.streamKey, "inventory_snapshot:character-rook", "stream key")
equal(first.revision, 1, "first revision")
local envelope = first.envelope
equal(envelope.eventType, "inventory_snapshot", "event type")
equal(envelope.payloadSchemaVersion, 1, "payload schema")
equal(envelope.characterId, "character-rook", "character id")
equal(envelope.capturedAt, now, "observation time, not the cached snapshot time")

now = now + 30
local unchanged = addon.InventoryCapture.Publish("BAG_UPDATE_DELAYED")
equal(unchanged.changed, false, "unchanged inventory is deduped")
equal(unchanged.revision, 1, "no new revision")

-- Looting more ore changes the totals and creates revision 2.
bags[0].slots[2].stackCount = 7
now = now + 30
local looted = addon.InventoryCapture.Publish("BAG_UPDATE_DELAYED")
truthy(looted.changed, "loot publishes")
equal(looted.revision, 2, "revision advances")
equal(looted.envelope.payload.totals[1].count, 23, "ore total after loot")

-- Money alone is a material change.
money = money + 250
local paid = addon.InventoryCapture.Publish("PLAYER_MONEY")
equal(paid.revision, 3, "money change advances revision")
equal(paid.envelope.payload.money.copper, 1234817, "new money")

-- Domain publish (from a character capture) reuses the cached scan.
local viaDomain = addon.TelemetryDomains.Inventory.Publish(characterSnapshot)
equal(viaDomain.changed, false, "character capture does not duplicate inventory")

-- Bags not loaded: no payload, the stored stream is left alone.
local saved = bags[0].size
bags[0].size = 0
equal(addon.InventoryTelemetry.Collect(), nil, "unloaded backpack yields no payload")
bags[0].size = saved

-- Uncached item info is reported as pending and retried, never cached.
addon.InventoryTelemetry.ResetCache()
itemInfoReady = false
local partial, pending = addon.InventoryTelemetry.Collect()
truthy(pending, "pending while item info loads")
equal(partial.items[2].itemId, 2770, "items sorted by key")
equal(partial.items[2].name, "Copper Ore", "name falls back to the link")
itemInfoReady = true
local _, stillPending = addon.InventoryTelemetry.Collect()
equal(stillPending, false, "described once info arrives")

print("inventory_telemetry_spec passed")
