local function equal(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local described = 0
local published = {}
local requested = {}
local registered = {}
local onEvent = nil
local snapshots = 0

GetServerTime = function() return 1791769800 end
_G.C_Item = {
    RequestLoadItemDataByID = function(itemId)
        requested[#requested + 1] = itemId
    end,
}
CreateFrame = function()
    return {
        RegisterEvent = function(_, event)
            registered[event] = true
        end,
        SetScript = function(_, script, callback)
            if script == "OnEvent" then
                onEvent = callback
            end
        end,
    }
end

local function fullTooltip(lines, method)
    return {
        source = "GameTooltip",
        method = method or "SetHyperlink",
        rendered = true,
        complete = true,
        lines = lines,
    }
end

local lichenLink = "|cff1eff00|Hitem:249399::::::::30:::::::|h[Frilled Lichen]|h|r"
local peacebloomLink = "|cffffffff|Hitem:2447::::::::30:::::::|h[Peacebloom]|h|r"

rawset(_G, "GetNumLootItems", function() return 1 end)
rawset(_G, "GetLootSlotLink", function(slot)
    equal(slot, 1, "loot slot lookup")
    return lichenLink
end)

local addon = {
    version = "test",
    Character = {
        GetCurrentSnapshot = function()
            return { gameBuild = { build = "70338", version = "1.60.1" } }
        end,
    },
    ItemTelemetry = {
        IsFullTooltip = function(tooltip)
            return type(tooltip) == "table"
                and tooltip.source == "GameTooltip"
                and tooltip.rendered == true
                and tooltip.complete == true
                and type(tooltip.lines) == "table"
                and #tooltip.lines > 0
        end,
        Describe = function(item)
            described = described + 1
            local text = tostring(item)
            if text:find("11746", 1, true) then
                return {
                    itemId = 11746,
                    name = "Golem Skull Helm",
                    qualityId = 3,
                    iconFileDataId = 132767,
                    itemClass = { id = 4, name = "Armor" },
                    itemSubclass = { id = 4, name = "Plate" },
                    itemLevel = 35,
                    tooltip = fullTooltip({
                        { left = "Golem Skull Helm" },
                        { left = "Head", right = "Plate" },
                        { left = "120 Armor" },
                        { left = "+13 Strength" },
                        { left = "Durability 91 / 100" },
                    }, "SetInventoryItem"),
                }
            end
            if text:find("2447", 1, true) then
                return {
                    itemId = 2447,
                    itemLink = peacebloomLink,
                    name = "Peacebloom",
                    qualityId = 1,
                    iconFileDataId = 134182,
                    sellPrice = 10,
                    itemClass = { id = 7, name = "Trade Goods" },
                    itemSubclass = { id = 9, name = "Herb" },
                }
            end

            equal(item, lichenLink, "uses exact loot link")
            return {
                itemId = 249399,
                itemLink = lichenLink,
                name = "Frilled Lichen",
                qualityId = 2,
                iconFileDataId = 134193,
                sellPrice = 125,
                itemClass = { id = 7, name = "Trade Goods" },
                itemSubclass = { id = 9, name = "Herb" },
                tooltip = {
                    source = "C_TooltipInfo",
                    rendered = false,
                    complete = false,
                    lines = {
                        { left = "Frilled Lichen" },
                    },
                },
            }
        end,
        LootItemTooltip = function(slot, itemLink)
            equal(slot, 1, "captures live loot slot")
            equal(itemLink, lichenLink, "loot slot keeps exact link")
            return fullTooltip({
                { left = "Frilled Lichen", leftColor = { r = 0.12, g = 1, b = 0 } },
                { left = "Crafting Reagent" },
                { left = "Sell Price: 1s 25c" },
            }, "SetLootItem")
        end,
        BagItemTooltip = function(bagId, slot, itemLink)
            equal(bagId, 0, "captures backpack item")
            equal(slot, 3, "captures concrete bag slot")
            equal(itemLink, peacebloomLink, "bag slot keeps exact link")
            return fullTooltip({
                { left = "Peacebloom" },
                { left = "Herb" },
                { left = "Sell Price: 10c" },
            }, "SetBagItem")
        end,
    },
    TelemetryEnvelope = {
        Build = function(eventType, payload, snapshot)
            return {
                schemaVersion = 1,
                eventType = eventType,
                capturedAt = snapshot.capturedAt,
                characterId = snapshot.characterId,
                gameBuild = snapshot.gameBuild,
                payloadSchemaVersion = payload.schemaVersion,
                payload = payload,
            }
        end,
    },
    Store = {
        SetTelemetrySnapshot = function(streamKey, envelope)
            published[#published + 1] = { streamKey = streamKey, envelope = envelope }
            return true
        end,
        SetCharacterSnapshot = function(_, snapshot)
            snapshots = snapshots + 1
            return snapshot and "stored" or nil
        end,
    },
    GatheringTelemetry = {
        ReadLoot = function()
            return {
                outputs = {
                    {
                        itemId = 249399,
                        itemLink = lichenLink,
                        name = "Frilled Lichen",
                        quantity = 1,
                        qualityId = 2,
                        iconFileDataId = 134193,
                    },
                },
            }
        end,
    },
    InventoryTelemetry = {
        Refresh = function()
            return {
                items = {
                    {
                        key = "item:2447",
                        itemId = 2447,
                        itemLink = peacebloomLink,
                        name = "Peacebloom",
                        qualityId = 1,
                        iconFileDataId = 134182,
                    },
                },
                containers = {
                    {
                        bagId = 0,
                        slots = {
                            { slot = 3, itemKey = "item:2447", itemId = 2447, count = 4 },
                        },
                    },
                },
            }, false
        end,
    },
}

local chunk = assert(loadfile("Data/EconomicItemTelemetry.lua"))
chunk("Guildweaver", addon)

equal(registered.GET_ITEM_INFO_RECEIVED, true, "registers item-info event")
equal(registered.ITEM_DATA_LOAD_RESULT, true, "registers item-data event")
equal(type(onEvent), "function", "load event callback installed")

-- Gathering definitions are captured immediately from the live loot slot. The
-- generic description may still be provisional; SetLootItem is authoritative.
local first = addon.GatheringTelemetry.ReadLoot()
equal(first.outputs[1].quantity, 1, "loot remains unchanged")
equal(described, 1, "loot metadata described once")
equal(#requested, 0, "live loot slot needs no item-data retry")
equal(#published, 1, "live loot tooltip publishes immediately")
equal(published[1].streamKey, "item_definition:item:249399", "stable loot item stream")
equal(published[1].envelope.eventType, "item_definition", "event type")
equal(published[1].envelope.characterId, nil, "item definition is not character scoped")
equal(published[1].envelope.payload.itemKey, "item:249399", "item key")
equal(published[1].envelope.payload.item.sellPrice, 125, "metadata retained")
equal(published[1].envelope.payload.item.tooltip.method, "SetLootItem", "canonical tooltip comes from loot slot")
equal(published[1].envelope.payload.item.tooltip.lines[2].left, "Crafting Reagent", "full loot tooltip lines")

addon.GatheringTelemetry.ReadLoot()
equal(described, 1, "complete loot definition cached for the session")
equal(#published, 1, "complete loot definition is not republished on every gather")

-- Carried items self-heal old Farming rows on login/bag refresh even if they
-- were gathered before this capture path existed.
local inventory, pending = addon.InventoryTelemetry.Refresh("classic beta pve 2:armorytest")
equal(pending, false, "inventory pending flag preserved")
equal(inventory.items[1].name, "Peacebloom", "inventory payload preserved")
equal(described, 2, "bag item metadata described")
equal(#published, 2, "bag slot publishes missing canonical definition")
equal(published[2].streamKey, "item_definition:item:2447", "bag uses canonical item stream")
equal(published[2].envelope.payload.item.tooltip.method, "SetBagItem", "bag definition uses live slot tooltip")
equal(published[2].envelope.payload.item.tooltip.lines[2].left, "Herb", "bag tooltip lines retained")

local stored = addon.Store.SetCharacterSnapshot("classic beta pve 2:armorytest", {
    equipment = {
        {
            itemId = 11746,
            itemLink = "|cff0070dd|Hitem:11746::::::::30:::::::|h[Golem Skull Helm]|h|r",
            name = "Golem Skull Helm",
            qualityId = 3,
            iconFileDataId = 132767,
        },
    },
})
equal(stored, "stored", "character snapshot behavior preserved")
equal(snapshots, 1, "character snapshot stored once")
equal(described, 3, "equipment feeds the shared item catalog")
equal(#published, 3, "full equipment item definition published")
equal(published[3].streamKey, "item_definition:item:11746", "equipment uses canonical item stream")
equal(published[3].envelope.payload.item.itemLevel, 35, "equipment definition keeps client metadata")
equal(published[3].envelope.payload.item.tooltip.method, "SetInventoryItem", "equipment keeps slot-rendered tooltip")
equal(published[3].envelope.payload.item.tooltip.lines[3].left, "120 Armor", "equipment catalog retains full armor line")

print("economic item telemetry spec passed")
