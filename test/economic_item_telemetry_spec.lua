local function equal(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local described = 0
local published = {}
GetServerTime = function() return 1791769800 end

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
            equal(item, "|cff1eff00|Hitem:249399::::::::30:::::::|h[Frilled Lichen]|h|r", "uses exact loot link")
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

local first = addon.GatheringTelemetry.ReadLoot()
equal(first.outputs[1].quantity, 1, "loot remains unchanged")
equal(described, 1, "item described once")
equal(#published, 1, "item definition published")
equal(published[1].streamKey, "item_definition:item:249399", "stable item stream")
equal(published[1].envelope.eventType, "item_definition", "event type")
equal(published[1].envelope.characterId, nil, "item definition is not character scoped")
equal(published[1].envelope.payload.itemKey, "item:249399", "item key")
equal(published[1].envelope.payload.item.sellPrice, 125, "item metadata")
equal(published[1].envelope.payload.item.tooltip.lines[2].left, "Crafting Reagent", "tooltip lines")

addon.GatheringTelemetry.ReadLoot()
equal(described, 1, "complete tooltip cached for the session")
equal(#published, 1, "complete definition is not republished on every gather")

print("economic item telemetry spec passed")
