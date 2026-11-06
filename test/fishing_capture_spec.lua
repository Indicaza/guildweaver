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
_G.GameTooltip.GetLeftLine = function()
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

local function catchesWhere(predicate)
    local found = {}
    for _, record in ipairs(recordsByType().gathering_loot or {}) do
        local payload = record.envelope.payload
        if predicate(payload) then
            table.insert(found, payload)
        end
    end
    return found
end

local function lootCount()
    return #(recordsByType().gathering_loot or {})
end

-- The accepted cast above expires; a later fishing loot window with no cast
-- seen (the cast started before a /reload) is still recorded once.
local statsBefore = GW.FishingCapture.Stats()
local catchesBefore = statsBefore.catches
fishingLoot = true
elapsed = 300
now = 6300
eventFrame.onEvent(eventFrame, "LOOT_CLOSED")
local before = lootCount()
eventFrame.onEvent(eventFrame, "LOOT_READY")
eventFrame.onEvent(eventFrame, "LOOT_OPENED")
equal(lootCount(), before + 1, "catch without a seen cast is recorded once per loot window")
local unseen = catchesWhere(function(payload) return payload.capture.castObserved == false end)
equal(#unseen, 1, "catch without a seen cast is marked")
equal(unseen[1].source.kind, "fishing_water", "unseen-cast catch defaults to open water")
equal(unseen[1].context.location.mapId, 1429, "unseen-cast catch keeps map")
equal(unseen[1].context.location.x, 0.43, "unseen-cast catch keeps coordinates")
equal(unseen[1].context.profession.skillLineId, 356, "unseen-cast catch keeps fishing skill")
equal(unseen[1].context.trigger.spellName, "Fishing", "unseen-cast catch names the activity")
equal(GW.FishingCapture.Stats().catches, catchesBefore + 1, "catch counted")
equal(GW.FishingCapture.Stats().catchesWithoutCast, 1, "unseen-cast catch counted")

-- Without a cast, a loot window the client does not call fishing loot is ignored.
fishingLoot = false
eventFrame.onEvent(eventFrame, "LOOT_CLOSED")
before = lootCount()
eventFrame.onEvent(eventFrame, "LOOT_OPENED")
equal(lootCount(), before, "non-fishing loot without a cast is ignored")

-- Without IsFishingLoot, only an accepted cast makes loot a catch.
local isFishingLoot = _G.IsFishingLoot
_G.IsFishingLoot = nil
eventFrame.onEvent(eventFrame, "LOOT_CLOSED")
eventFrame.onEvent(eventFrame, "LOOT_OPENED")
equal(lootCount(), before, "unknown loot without a cast is ignored")
_G.IsFishingLoot = isFishingLoot
fishingLoot = true

-- The channel can end before the loot window opens.
elapsed = 320
now = 6320
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SENT", "player", nil, "Cast-Interrupted-1", 7620)
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-Interrupted-1", 7620)
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_INTERRUPTED", "player", "Cast-Interrupted-1", 7620)
before = lootCount()
eventFrame.onEvent(eventFrame, "LOOT_OPENED")
equal(lootCount(), before + 1, "catch after the channel ended is still recorded")

-- Higher Fishing ranks are recognized by id, whatever the spell name lookup says.
elapsed = 330
now = 6330
eventFrame.onEvent(eventFrame, "LOOT_CLOSED")
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SENT", "player", nil, "Cast-Artisan-1", 18248)
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-Artisan-1", 18248)
truthy(recordForCast(recordsByType(), "gathering_attempt", "Cast-Artisan-1"), "artisan fishing rank recognized")

-- Loot from a game object other than the bobber came from a pool, even when
-- no tooltip named it.
_G.GetLootSourceInfo = function()
    return "GameObject-0-1-2-3-180712-000009", 1
end
elapsed = 335
now = 6335
eventFrame.onEvent(eventFrame, "LOOT_OPENED")
local confirmed = recordForCast(recordsByType(), "gathering_loot", "Cast-Artisan-1")
equal(confirmed.source.kind, "fishing_pool", "loot source game object makes a pool")
equal(confirmed.source.objectId, 180712, "pool object id from loot source")
equal(confirmed.source.name, "Fishing Pool", "unnamed pool gets a safe name")
equal(confirmed.capture.sourceDetection, "loot_source", "pool detected from loot source")
equal(confirmed.capture.sourceConfidence, "confirmed", "loot source confidence")
equal(confirmed.capture.rawSourceObjectId, 180712, "raw loot source kept")

-- A pool name seen on any earlier tooltip names later catches from it.
currentCursorData = { type = 4, guid = "GameObject-0-1-2-3-180712-000010" }
currentTooltipText = "Stonescale Eel Swarm"
elapsed = 340
_G.GameTooltip.scripts.OnShow(_G.GameTooltip)
currentCursorData = nil
currentTooltipText = nil
elapsed = 400
now = 6400
eventFrame.onEvent(eventFrame, "LOOT_CLOSED")
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SENT", "player", nil, "Cast-Swarm-1", 7620)
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-Swarm-1", 7620)
local swarmAttempt = recordForCast(recordsByType(), "gathering_attempt", "Cast-Swarm-1")
equal(swarmAttempt.source.kind, "fishing_water", "stale tooltip does not label the cast")
eventFrame.onEvent(eventFrame, "LOOT_OPENED")
local swarm = recordForCast(recordsByType(), "gathering_loot", "Cast-Swarm-1")
equal(swarm.source.name, "Stonescale Eel Swarm", "learned pool name used for loot-source pool")
equal(swarm.source.objectId, 180712, "learned pool keeps object id")

-- A bobber loot source never demotes a pool the tooltip probe found.
_G.GetLootSourceInfo = function()
    return "GameObject-0-1-2-3-35591-000011", 1
end
currentCursorData = { type = 4, guid = "GameObject-0-1-2-3-180682-000012" }
currentTooltipText = "Oily Blackmouth School"
elapsed = 410
now = 6410
eventFrame.onEvent(eventFrame, "LOOT_CLOSED")
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SENT", "player", nil, "Cast-Probe-2", 7620)
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-Probe-2", 7620)
eventFrame.onEvent(eventFrame, "LOOT_OPENED")
local probed = recordForCast(recordsByType(), "gathering_loot", "Cast-Probe-2")
equal(probed.source.kind, "fishing_pool", "probe pool kept with bobber loot source")
equal(probed.source.name, "Oily Blackmouth School", "probe pool name kept")
equal(probed.capture.sourceDetection, "world_cursor_tooltip", "probe detection kept")
currentCursorData = nil
currentTooltipText = nil

local counters = GW.FishingCapture.Stats()
truthy(counters.casts >= 10, "casts counted")
equal(counters.poolCatches >= 3, true, "pool catches counted")
equal(counters.last.sourceName, "Oily Blackmouth School", "last catch source")
equal(counters.last.zone, "Elwynn Forest", "last catch zone")
equal(counters.last.items, 2, "last catch item count")

print("fishing pool telemetry stress tests passed")
