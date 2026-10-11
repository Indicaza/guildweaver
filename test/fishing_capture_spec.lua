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

local now = 6100
local elapsed = 120
local eventFrame = nil
local fishingLoot = true

GuildweaverDB = nil
GetServerTime = function() return now end
_G.GetTime = function() return elapsed end
UnitLevel = function() return 22 end
_G.GetRealZoneText = function() return "Elwynn Forest" end
_G.GetSubZoneText = function() return "Crystal Lake" end
_G.IsFishingLoot = function() return fishingLoot end
_G.GetNumLootItems = function() return 2 end
_G.GetLootSlotInfo = function(slot)
    if slot == 1 then
        return 134326, "Raw Brilliant Smallfish", 1, nil, 1
    end
    return 134935, "Shiny Bauble", 1, nil, 1
end
_G.GetLootSlotLink = function(slot)
    if slot == 1 then
        return "|Hitem:6291::::::::|h[Raw Brilliant Smallfish]|h"
    end
    return "|Hitem:6529::::::::|h[Shiny Bauble]|h"
end
_G.GetLootSourceInfo = function()
    return "GameObject-0-1-2-3-35591-000001", 1
end
_G.C_Map = {
    GetBestMapForUnit = function() return 1429 end,
    GetPlayerMapPosition = function()
        return { GetXY = function() return 0.43, 0.66 end }
    end,
}
_G.C_Spell = {
    GetSpellInfo = function(spellId)
        return { name = spellId == 7620 and "Fishing" or "Other" }
    end,
}
CreateFrame = function()
    local frame = { events = {} }
    function frame:RegisterEvent(event)
        self.events[event] = true
    end
    function frame:SetScript(kind, fn)
        if kind == "OnEvent" then
            self.onEvent = fn
        end
    end
    eventFrame = frame
    return frame
end

local GW = { version = "test" }
assert(loadfile("Data/Store.lua"))("Guildweaver", GW)
GW.Store.Initialize()
assert(loadfile("Data/TelemetryEnvelope.lua"))("Guildweaver", GW)

GW.Character = {
    GetCurrentSnapshot = function()
        return {
            characterId = "character-fisher",
            realm = "Realm",
            region = "US",
            gameBuild = { build = "70338" },
            level = 22,
        }
    end,
}
GW.ProfessionTelemetry = {
    CollectProfessions = function()
        return {
            {
                skillLineId = 356,
                name = "Fishing",
                skillLevel = 74,
                maxSkillLevel = 150,
                skillModifier = 5,
            },
        }
    end,
}

assert(loadfile("Data/GatheringTelemetry.lua"))("Guildweaver", GW)
assert(loadfile("Systems/FishingCapture.lua"))("Guildweaver", GW)
truthy(eventFrame, "event frame")
truthy(eventFrame.events.UNIT_SPELLCAST_SUCCEEDED, "successful casts registered")

local function recordsByType()
    local records = {}
    for _, record in pairs(GuildweaverDB.sync.outbound.telemetry) do
        local eventType = record.envelope and record.envelope.eventType
        records[eventType] = records[eventType] or {}
        table.insert(records[eventType], record)
    end
    return records
end

eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SENT", "player", nil, "Cast-Fish-1", 7620)
truthy(GW.FishingCapture.pending, "pending fishing cast")
equal(next(GuildweaverDB.sync.outbound.telemetry), nil, "sent cast is not yet an accepted attempt")

now = 6101
elapsed = 121
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-Fish-1", 7620)
local records = recordsByType()
equal(#(records.gathering_attempt or {}), 1, "one accepted fishing cast")
equal(#(records.gathering_loot or {}), 0, "no catch before fishing loot")

local attempt = records.gathering_attempt[1].envelope.payload
equal(attempt.discipline, "fishing", "attempt discipline")
equal(attempt.activity, "cast", "attempt activity")
equal(attempt.source.kind, "fishing_water", "attempt source kind")
equal(attempt.source.name, "Open Water", "attempt source name")
equal(attempt.context.profession.skillLineId, 356, "fishing skill line")
equal(attempt.context.profession.skillLevel, 74, "fishing skill")
equal(attempt.context.profession.skillModifier, 5, "fishing modifier")
equal(attempt.context.modifiers, nil, "herbalism modifiers omitted")
equal(attempt.context.location.zone, "Elwynn Forest", "attempt zone")
equal(attempt.context.location.subzone, "Crystal Lake", "attempt subzone")
equal(attempt.capture.accepted, true, "accepted cast marker")
truthy(attempt.observationId, "attempt observation id")

now = 6110
elapsed = 130
eventFrame.onEvent(eventFrame, "LOOT_OPENED")
records = recordsByType()
equal(#(records.gathering_attempt or {}), 1, "attempt remains unique")
equal(#(records.gathering_loot or {}), 1, "one fishing catch")
equal(GW.FishingCapture.pending, nil, "pending cleared after catch")

local catch = records.gathering_loot[1].envelope.payload
equal(catch.discipline, "fishing", "catch discipline")
equal(catch.activity, "catch", "catch activity")
equal(catch.source.kind, "fishing_water", "catch source kind")
equal(catch.source.name, "Open Water", "catch source name")
equal(catch.source.objectId, nil, "bobber object id is not semantic source identity")
equal(catch.source.guid, nil, "bobber guid is not semantic source identity")
equal(catch.capture.rawSourceObjectId, 35591, "raw bobber object id preserved for debugging")
equal(catch.outputs[1].itemId, 6291, "fish item")
equal(catch.outputs[1].quantity, 1, "fish quantity")
equal(catch.outputs[2].itemId, 6529, "secondary fishing output")
equal(catch.context.profession.skillLevel, 74, "catch fishing skill")
equal(catch.context.location.mapId, 1429, "catch map id")
equal(catch.context.location.x, 0.43, "catch map x")
equal(catch.context.location.y, 0.66, "catch map y")
truthy(catch.observationId, "catch observation id")

eventFrame.onEvent(eventFrame, "LOOT_READY")
records = recordsByType()
equal(#(records.gathering_loot or {}), 1, "duplicate fishing loot event suppressed")

now = 6120
elapsed = 140
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SENT", "player", nil, "Cast-Fish-2", 7620)
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-Fish-2", 7620)
records = recordsByType()
equal(#(records.gathering_attempt or {}), 2, "a cast with no catch still contributes to cast denominator")
equal(#(records.gathering_loot or {}), 1, "no invented catch for an unlooted cast")

now = 6122
elapsed = 142
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SENT", "player", nil, "Cast-Fish-3", 7620)
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_FAILED", "player", "Cast-Fish-3", 7620)
records = recordsByType()
equal(#(records.gathering_attempt or {}), 2, "failed cast before acceptance is not an attempt")
equal(GW.FishingCapture.pending, nil, "failed cast cleared")

fishingLoot = false
now = 6124
elapsed = 144
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SENT", "player", nil, "Cast-Fish-4", 7620)
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-Fish-4", 7620)
eventFrame.onEvent(eventFrame, "LOOT_OPENED")
records = recordsByType()
equal(#(records.gathering_attempt or {}), 3, "third accepted cast counted")
equal(#(records.gathering_loot or {}), 1, "non-fishing loot is not misclassified as a catch")

print("fishing gathering telemetry tests passed")
