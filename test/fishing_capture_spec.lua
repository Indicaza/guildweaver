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
local currentCursorData = nil
local currentTooltipText = nil
local secretPoolName = {}

GuildweaverDB = nil
GetServerTime = function() return now end
_G.GetTime = function() return elapsed end
_G.issecretvalue = function(value) return value == secretPoolName end
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
_G.Enum = { TooltipDataType = { Object = 4 } }
_G.C_TooltipInfo = {
    GetWorldCursor = function()
        return currentCursorData
    end,
}
_G.GameTooltip = { scripts = {} }
function _G.GameTooltip:HookScript(kind, fn)
    self.scripts[kind] = fn
end
function _G.GameTooltip:GetLeftLine()
    return { GetText = function() return currentTooltipText end }
end
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
assert(loadfile("Systems/FishingPoolProbe.lua"))("Guildweaver", GW)
assert(loadfile("Systems/FishingCapture.lua"))("Guildweaver", GW)
truthy(eventFrame, "event frame")
truthy(eventFrame.events.UNIT_SPELLCAST_SUCCEEDED, "successful casts registered")
truthy(_G.GameTooltip.scripts.OnShow, "world tooltip probe hooked")

local function recordsByType()
    local records = {}
    for _, record in pairs(GuildweaverDB.sync.outbound.telemetry) do
        local eventType = record.envelope and record.envelope.eventType
        records[eventType] = records[eventType] or {}
        table.insert(records[eventType], record)
    end
    return records
end

local function recordForCast(records, eventType, castGuid)
    for _, record in ipairs(records[eventType] or {}) do
        local payload = record.envelope and record.envelope.payload
        if payload and payload.context and payload.context.trigger
            and payload.context.trigger.castGuid == castGuid then
            return payload
        end
    end
    return nil
end

-- Ordinary open-water fishing remains the safe fallback.
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SENT", "player", nil, "Cast-Fish-1", 7620)
truthy(GW.FishingCapture.pending, "pending fishing cast")
equal(next(GuildweaverDB.sync.outbound.telemetry), nil, "sent cast is not yet an accepted attempt")

now = 6101
elapsed = 121
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-Fish-1", 7620)
local records = recordsByType()
equal(#(records.gathering_attempt or {}), 1, "one accepted fishing cast")
equal(#(records.gathering_loot or {}), 0, "no catch before fishing loot")

local attempt = recordForCast(records, "gathering_attempt", "Cast-Fish-1")
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
equal(attempt.capture.sourceDetection, "open_water_fallback", "open water detector fallback")
truthy(attempt.observationId, "attempt observation id")

now = 6110
elapsed = 130
eventFrame.onEvent(eventFrame, "LOOT_OPENED")
records = recordsByType()
equal(#(records.gathering_attempt or {}), 1, "attempt remains unique")
equal(#(records.gathering_loot or {}), 1, "one fishing catch")
equal(GW.FishingCapture.pending, nil, "pending cleared after catch")

local catch = recordForCast(records, "gathering_loot", "Cast-Fish-1")
equal(catch.discipline, "fishing", "catch discipline")
equal(catch.activity, "catch", "catch activity")
equal(catch.source.kind, "fishing_water", "catch source kind")
equal(catch.source.name, "Open Water", "catch source name")
equal(catch.source.objectId, nil, "bobber object id is not semantic source identity")
equal(catch.source.guid, nil, "bobber guid is not semantic source identity")
equal(catch.capture.rawSourceObjectId, 35591, "raw bobber object id preserved for debugging")
equal(catch.outputs[1].itemId, 6291, "fish item")
equal(catch.outputs[2].itemId, 6529, "secondary fishing output")
equal(catch.context.location.mapId, 1429, "catch map id")
truthy(catch.observationId, "catch observation id")

eventFrame.onEvent(eventFrame, "LOOT_READY")
records = recordsByType()
equal(#(records.gathering_loot or {}), 1, "duplicate fishing loot event suppressed")

-- A named school under the world cursor becomes the semantic source for both
-- the cast and the catch. The bobber remains debug-only raw source data.
currentCursorData = { type = 4, guid = "GameObject-0-1-2-3-180682-000001" }
currentTooltipText = "Oily Blackmouth School"
now = 6120
elapsed = 140
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SENT", "player", nil, "Cast-Pool-1", 7620)
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-Pool-1", 7620)
records = recordsByType()
local poolAttempt = recordForCast(records, "gathering_attempt", "Cast-Pool-1")
equal(poolAttempt.source.kind, "fishing_pool", "school attempt source kind")
equal(poolAttempt.source.name, "Oily Blackmouth School", "school attempt source name")
equal(poolAttempt.source.objectId, 180682, "school object id")
equal(poolAttempt.capture.sourceDetection, "world_cursor_tooltip", "school detector")
equal(poolAttempt.capture.sourceConfidence, "strong", "school detector confidence")

now = 6122
elapsed = 142
eventFrame.onEvent(eventFrame, "LOOT_OPENED")
records = recordsByType()
local poolCatch = recordForCast(records, "gathering_loot", "Cast-Pool-1")
equal(poolCatch.source.kind, "fishing_pool", "school catch source kind")
equal(poolCatch.source.name, "Oily Blackmouth School", "school catch source name")
equal(poolCatch.source.objectId, 180682, "school catch object id")
equal(poolCatch.capture.rawSourceObjectId, 35591, "school still keeps raw bobber id")

-- A harmless world object is diagnostic evidence, never a fishing pool.
currentCursorData = { type = 4, guid = "GameObject-0-1-2-3-12345-000001" }
currentTooltipText = "Mailbox"
now = 6130
elapsed = 150
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SENT", "player", nil, "Cast-Object-1", 7620)
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-Object-1", 7620)
records = recordsByType()
local objectAttempt = recordForCast(records, "gathering_attempt", "Cast-Object-1")
equal(objectAttempt.source.kind, "fishing_water", "ordinary object does not become a pool")
equal(objectAttempt.source.name, "Open Water", "ordinary object keeps fallback")
equal(objectAttempt.capture.worldCursor.name, "Mailbox", "ordinary object probe retained")
equal(objectAttempt.capture.worldCursor.looksLikePool, false, "ordinary object classified safely")

-- If a pool only becomes visible after the cast was accepted, preserve the
-- cast denominator as Open Water but promote the catch before loot is read.
currentCursorData = nil
currentTooltipText = nil
now = 6140
elapsed = 160
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SENT", "player", nil, "Cast-Late-1", 7620)
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-Late-1", 7620)
records = recordsByType()
local lateAttempt = recordForCast(records, "gathering_attempt", "Cast-Late-1")
equal(lateAttempt.source.kind, "fishing_water", "late pool attempt starts as open water")

currentCursorData = { type = 4, guid = "GameObject-0-1-2-3-180683-000001" }
currentTooltipText = "Firefin Snapper School"
elapsed = 163
_G.GameTooltip.scripts.OnShow(_G.GameTooltip)
now = 6144
eventFrame.onEvent(eventFrame, "LOOT_OPENED")
records = recordsByType()
local lateCatch = recordForCast(records, "gathering_loot", "Cast-Late-1")
equal(lateCatch.source.kind, "fishing_pool", "late-detected school promotes catch")
equal(lateCatch.source.name, "Firefin Snapper School", "late-detected school name")
equal(lateCatch.source.objectId, 180683, "late-detected school object id")

-- Forever can mark tooltip text secret. A real GameObject identity still gives
-- us a short-lived weak pool candidate without serializing the secret value.
currentCursorData = { type = 4, guid = "GameObject-0-1-2-3-180684-000001" }
currentTooltipText = secretPoolName
now = 6150
elapsed = 170
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SENT", "player", nil, "Cast-Secret-1", 7620)
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-Secret-1", 7620)
records = recordsByType()
local secretAttempt = recordForCast(records, "gathering_attempt", "Cast-Secret-1")
equal(secretAttempt.source.kind, "fishing_pool", "restricted tooltip can use game object identity")
equal(secretAttempt.source.name, "Fishing Pool", "restricted tooltip gets safe display name")
equal(secretAttempt.source.objectId, 180684, "restricted tooltip object id")
equal(secretAttempt.capture.sourceConfidence, "weak", "restricted tooltip confidence")
equal(secretAttempt.capture.worldCursor.nameRestricted, true, "restricted name diagnostic")

currentCursorData = nil
currentTooltipText = nil
fishingLoot = true
now = 6160
elapsed = 180
eventFrame.onEvent(eventFrame, "LOOT_OPENED")
records = recordsByType()
local secretCatch = recordForCast(records, "gathering_loot", "Cast-Secret-1")
equal(secretCatch.source.kind, "fishing_pool", "restricted pool identity survives to catch")
equal(secretCatch.source.objectId, 180684, "restricted pool object id survives")

-- No-catch casts remain attempts only.
now = 6170
elapsed = 190
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SENT", "player", nil, "Cast-Fish-2", 7620)
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-Fish-2", 7620)
records = recordsByType()
truthy(recordForCast(records, "gathering_attempt", "Cast-Fish-2"), "cast with no catch contributes to denominator")
equal(recordForCast(records, "gathering_loot", "Cast-Fish-2"), nil, "no invented catch for unlooted cast")

now = 6172
elapsed = 192
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SENT", "player", nil, "Cast-Fish-3", 7620)
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_FAILED", "player", "Cast-Fish-3", 7620)
records = recordsByType()
equal(recordForCast(records, "gathering_attempt", "Cast-Fish-3"), nil, "failed cast before acceptance is not an attempt")
equal(GW.FishingCapture.pending, nil, "failed cast cleared")

fishingLoot = false
now = 6174
elapsed = 194
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SENT", "player", nil, "Cast-Fish-4", 7620)
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-Fish-4", 7620)
eventFrame.onEvent(eventFrame, "LOOT_OPENED")
records = recordsByType()
truthy(recordForCast(records, "gathering_attempt", "Cast-Fish-4"), "accepted cast counted before unrelated loot")
equal(recordForCast(records, "gathering_loot", "Cast-Fish-4"), nil, "non-fishing loot is not misclassified")

print("fishing pool telemetry stress tests passed")
