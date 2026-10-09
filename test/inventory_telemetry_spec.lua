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
bags[-2] = {
    size = 4,
    slots = {
        [1] = { iconFileID = 134235, stackCount = 1, quality = 1, hyperlink = "|cffffffff|Hitem:5396::::::::20:::::::|h[Key to Searing Gorge]|h|r", itemID = 5396 },
    },
}
local money = 1234567
local tooltipReady = true
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
    if tostring(link):find("5396", 1, true) then
        return "Key to Searing Gorge", link, 1, 1, 0, "Key", "Key", 1, "", 134235, 0, 13, 0, 1, 0, nil, false
    end
    if tostring(link):find("15210", 1, true) then
        return "Raider Shortsword of the Tiger", link, 2, 18, 13, "Weapon", "One-Handed Swords", 1,
            "INVTYPE_WEAPON", 135274, 461, 2, 7, 2, 0, nil, false
    end
    return "Copper Ore", link, 1, 10, 0, "Trade Goods", "Metal & Stone", 20,
        "", 134566, 5, 7, 7, 0, 0, nil, true
end

local cooldownLeft = 300
rawset(_G, "ITEM_COOLDOWN_TIME", "Cooldown remaining: %s")
rawset(_G, "C_TooltipInfo", {
    GetBagItem = function(bagId, slot)
        if not tooltipReady then
            return nil
        end
        local info = bags[bagId] and bags[bagId].slots[slot]
        if not info then
            return nil
        end
        local name = tostring(info.hyperlink):match("%[(.-)%]") or "Item"
        local lines = { { leftText = name } }
        if info.isBound then
            table.insert(lines, { leftText = "Soulbound" })
        end
        if info.itemID == 15210 then
            table.insert(lines, { leftText = "Durability 41 / 55" })
            table.insert(lines, { type = 1, leftText = "" })
            table.insert(lines, { leftText = "Shadowcraft Boots", leftOffset = 8 })
            table.insert(lines, { type = 11, leftText = "Sell Price:", price = 461 })
        end
        if info.itemID == 6948 then
            table.insert(lines, { leftText = "Cooldown remaining: " .. cooldownLeft .. " sec" })
        end
        table.insert(lines, { leftText = "Crafted by Player-4620-014B5E8E" })
        return { lines = lines }
    end,
    GetHyperlink = function(link)
        if not tooltipReady then
            return nil
        end
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
equal(payload.slotCount, 22, "total slots exclude the keyring")
equal(payload.freeSlots, 18, "free slots exclude the keyring")
equal(#payload.containers, 3, "only containers with slots")
equal(payload.containers[3].kind, "keyring", "keyring last")
equal(payload.containers[3].slots[1].itemId, 5396, "keys are captured")

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

equal(#payload.items, 3, "distinct items described once")
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
equal(sword.tooltip.lines[2].left, "Soulbound", "tooltip read from the bag slot, binding included")
equal(sword.tooltip.lines[3].left, "Durability 41 / 55", "per-item durability included")
equal(sword.tooltip.lines[4].blank, true, "blank lines keep the tooltip's spacing")
equal(sword.tooltip.lines[5].offset, 8, "indented lines keep their offset")
for _, line in ipairs(sword.tooltip.lines) do
    truthy(line.left ~= "Sell Price:", "the sell price line is drawn from the sell price instead")
end
equal(sword.stats.ITEM_MOD_AGILITY_SHORT, 3, "shared stats enrichment")
equal(sword.requiredLevel, 13, "required level")
equal(sword.bindType, 2, "bind type")

equal(#payload.totals, 3, "totals per item id")
equal(payload.totals[1].itemId, 2770, "totals sorted by item id")
equal(payload.totals[1].count, 20, "ore summed across bags")
equal(payload.totals[1].stacks, 3, "ore stacks")
equal(payload.totals[3].count, 1, "sword count")

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

-- A ticking cooldown in a tooltip is not a change.
bags[0].slots[9] = { iconFileID = 134414, stackCount = 1, quality = 1, hyperlink = "|cffffffff|Hitem:6948::::::::20:::::::|h[Hearthstone]|h|r", itemID = 6948, isBound = true }
local hearth = addon.InventoryCapture.Publish("BAG_UPDATE_DELAYED")
equal(hearth.revision, 3, "new item advances revision")
for _, item in ipairs(hearth.envelope.payload.items) do
    if item.itemId == 6948 then
        for _, line in ipairs(item.tooltip.lines) do
            truthy(not line.left:find("Cooldown remaining", 1, true), "cooldown line stripped")
        end
    end
end
cooldownLeft = 120
equal(addon.InventoryCapture.Publish("BAG_UPDATE_DELAYED").changed, false, "cooldown ticking does not churn revisions")
bags[0].slots[9] = nil
equal(addon.InventoryCapture.Publish("BAG_UPDATE_DELAYED").revision, 4, "hearthstone removed")

-- Money alone is a material change.
money = money + 250
local paid = addon.InventoryCapture.Publish("PLAYER_MONEY")
equal(paid.revision, 5, "money change advances revision")
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
local partialOre
for _, item in ipairs(partial.items) do
    if item.itemId == 2770 then partialOre = item end
end
equal(partialOre.name, "Copper Ore", "name falls back to the link")
itemInfoReady = true
tooltipReady = false
local _, tooltipPending = addon.InventoryTelemetry.Collect()
truthy(tooltipPending, "an item without its tooltip yet is not cached")
tooltipReady = true
local _, stillPending = addon.InventoryTelemetry.Collect()
equal(stillPending, false, "described once info arrives")

-- A classic client: the id after the last bag is a bank bag, not a reagent bag.
rawset(_G, "Enum", { BagIndex = { Keyring = -2, ReagentBag = 5, BankBag_1 = 5 } })
bags[5] = { size = 28, slots = { [1] = { iconFileID = 1, stackCount = 1, hyperlink = ORE, itemID = 2770 } } }
for _, container in ipairs(addon.InventoryTelemetry.Collect().containers) do
    truthy(container.bagId ~= 5, "bank bag is never carried inventory")
end
-- WoW Forever: reagent bag 5, keyring -1, and -2 is a character bank tab.
rawset(_G, "Enum", { BagIndex = { Accountbanktab = -3, Characterbanktab = -2, Keyring = -1, Backpack = 0, ReagentBag = 5, CharacterBankTab_1 = 6 } })
bags[-1] = bags[-2]
bags[-2] = { size = 98, slots = { [1] = { iconFileID = 1, stackCount = 1, hyperlink = ORE, itemID = 2770 } } }
local forever = addon.InventoryTelemetry.Collect()
local kinds = {}
for _, container in ipairs(forever.containers) do
    truthy(container.bagId ~= -2, "a character bank tab is never carried inventory")
    kinds[container.bagId] = container.kind
end
equal(kinds[-1], "keyring", "Forever's keyring is -1")
equal(kinds[5], "reagent", "Forever's reagent bag is 5")


print("inventory_telemetry_spec passed")
