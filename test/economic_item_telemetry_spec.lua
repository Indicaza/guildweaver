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
local itemLoaded = false
local snapshots = 0

GetServerTime = function() return 1791769800 end
C_Item = {
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

local function completeLichen()
    return {
        itemId = 249399,
        name = "Frilled Lichen",
        qualityId = 2,
        iconFileDataId = 134193,
        sellPrice = 125,
        itemClass = { id = 7, name = "Trade Goods" },
        itemSubclass = { id = 9, name = "Herb" },
        tooltip = {
            source = "C_TooltipInfo",
            lines = {
                { left = "Frilled Lichen", leftColor = { r = 0.12, g = 1, b = 0 } },
                { left = "Crafting Reagent" },
            },
        },
    }
end

local addon = {
    version = "test",
    Character = {
        GetCurrentSnapshot = function()
            return { gameBuild = { build = "70338", version = "1.60.1" } }
        end,
    },
    ItemTelemetry = {
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
                    tooltip = {
                        source = "C_TooltipInfo",
                        lines = {
                            { left = "Golem Skull Helm" },
                            { left = "Item Level 35" },
                        },
                    },
                }
            end

            equal(item, "|cff1eff00|Hitem:249399::::::::30:::::::|h[Frilled Lichen]|h|r", "uses exact loot link")
            if itemLoaded then
                return completeLichen()
            end
            return {
                itemId = 249399,
                name = "Frilled Lichen",
                qualityId = 2,
                iconFileDataId = 134193,
                tooltip = {
                    source = "C_TooltipInfo",
                    lines = {
                        { left = "Frilled Lichen" },
                    },
                },
            }
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
                        itemLink = "|cff1eff00|Hitem:249399::::::::30:::::::|h[Frilled Lichen]|h|r",
                        name = "Frilled Lichen",
                        quantity = 1,
                        qualityId = 2,
                        iconFileDataId = 134193,
                    },
                },
            }
        end,
    },
}

local chunk = assert(loadfile("Data/EconomicItemTelemetry.lua"))
chunk("Guildweaver", addon)

equal(registered.GET_ITEM_INFO_RECEIVED, true, "registers item-info event")
equal(registered.ITEM_DATA_LOAD_RESULT, true, "registers item-data event")

local first = addon.GatheringTelemetry.ReadLoot()
equal(first.outputs[1].quantity, 1, "loot remains unchanged")
equal(described, 1, "sparse item described")
equal(#published, 1, "sparse definition is still useful immediately")
equal(published[1].streamKey, "item_definition:item:249399", "stable item stream")
equal(published[1].envelope.eventType, "item_definition", "event type")
equal(published[1].envelope.characterId, nil, "item definition is not character scoped")
equal(published[1].envelope.payload.itemKey, "item:249399", "item key")
equal(#published[1].envelope.payload.item.tooltip.lines, 1, "initial tooltip is sparse")
equal(#requested, 1, "sparse definition requests Blizzard item data")
equal(requested[1], 249399, "requests the observed item")

equal(type(onEvent), "function", "load event callback installed")
itemLoaded = true
onEvent(nil, "GET_ITEM_INFO_RECEIVED", 249399, true)
equal(described, 2, "loaded item retried once")
equal(#published, 2, "loaded definition republished")
equal(published[2].envelope.payload.item.sellPrice, 125, "loaded metadata replaces sparse definition")
equal(published[2].envelope.payload.item.tooltip.lines[2].left, "Crafting Reagent", "loaded tooltip lines")

addon.GatheringTelemetry.ReadLoot()
equal(described, 2, "complete definition cached for the session")
equal(#published, 2, "complete definition is not republished on every gather")

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
equal(#published, 3, "equipment item definition published")
equal(published[3].streamKey, "item_definition:item:11746", "equipment uses canonical item stream")
equal(published[3].envelope.payload.item.itemLevel, 35, "equipment definition keeps client metadata")

print("economic item telemetry spec passed")
