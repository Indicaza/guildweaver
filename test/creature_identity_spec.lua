-- Creature identity for mob_loot: names survive target changes and death,
-- and never move from one creature to another.
local function equal(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local now = 1000
local frame
local function guidOf(npcId, spawn) return "Creature-0-1-2-3-" .. npcId .. "-" .. spawn end
local smite = guidOf(646, "00000A")
local cookie = guidOf(645, "00000B")
local defiasA = guidOf(1729, "00000C")
local defiasB = guidOf(1729, "00000D")
local unknown = guidOf(657, "00000E")
local NAMES = { [smite] = "Mr. Smite", [cookie] = "Cookie", [defiasA] = "Defias Evoker", [defiasB] = "Defias Evoker" }
local units = {}
local creatureIds = {}
local sourcePairs = {}
GuildweaverDB = nil
_G.GetServerTime = function() return now end
_G.GetTime = function() return now end
_G.GetLocale = function() return "enUS" end
_G.UnitGUID = function(unit) return units[unit] end
_G.UnitName = function(unit) return units[unit] and NAMES[units[unit]] end
_G.UnitCreatureID = function(unit) return creatureIds[unit] end
_G.UnitClassification = function(unit) return units[unit] == smite and "elite" or "normal" end
_G.GetRealZoneText = function() return "The Deadmines" end
_G.GetNumLootItems = function() return 1 end
_G.GetLootSlotInfo = function() return 132889, "Linen Cloth", 1, 0, 1, false, true end
_G.GetLootSlotLink = function() return "item:2589" end
_G.GetLootSourceInfo = function() return unpack(sourcePairs) end
_G.GetInstanceInfo = function() return "Deadmines", "party", 1, "Normal", 5, 0, false, 36 end
_G.C_Map = { GetBestMapForUnit = function() return 1581 end, GetPlayerMapPosition = function() return { x = 0.5, y = 0.5 } end }
local registered = {}
_G.CreateFrame = function()
    frame = { RegisterEvent = function(_, event) registered[event] = true end, SetScript = function(self, _, fn) self.onEvent = fn end }
    return frame
end
local GW = { version = "test" }
assert(loadfile("Data/Store.lua"))("Guildweaver", GW)
GW.Store.Initialize()
assert(loadfile("Data/TelemetryEnvelope.lua"))("Guildweaver", GW)
GW.Character = { GetCurrentSnapshot = function() return { characterId = "character-1", realm = "Realm", region = "US", gameBuild = { build = "71037" } } end }
assert(loadfile("Data/GatheringTelemetry.lua"))("Guildweaver", GW)
assert(loadfile("Systems/MobLootCapture.lua"))("Guildweaver", GW)
local Capture = GW.MobLootCapture

local function event(name, unit) frame.onEvent(frame, name, unit) end
local function loot(...)
    sourcePairs = { ... }
    GW.GatheringTelemetry.InvalidateLoot()
    units.target, units.mouseover = nil, nil
    return Capture.Capture()
end
local function source(guid)
    local record = GuildweaverDB.sync.outbound.telemetry["mob_loot:character-1:" .. guid]
    return record and record.envelope.payload.source
end

equal(registered.NAME_PLATE_UNIT_ADDED, true, "nameplates are listened to")
equal(registered.INSTANCE_ENCOUNTER_ENGAGE_UNIT, true, "boss frames are listened to")

-- Mr. Smite is targeted, then the player targets Cookie: Smite keeps his name.
units.target = smite; creatureIds.target = 646; event("PLAYER_TARGET_CHANGED")
units.target = cookie; creatureIds.target = 645; event("PLAYER_TARGET_CHANGED")
units.target = nil; event("PLAYER_TARGET_CHANGED")

-- Both die; Smite's corpse is looted with no unit pointing at him any more.
now = now + 600
equal(loot(smite, 1), 1, "Smite's corpse reported")
equal(source(smite).name, "Mr. Smite", "name survives the target change and death")
equal(source(smite).nameSource, "unit", "named from this very creature")
equal(source(smite).classification, "elite", "classification kept")
equal(source(smite).npcId, 646, "attribution unchanged")

-- Two Defias Evokers fight together; only one was ever on a nameplate. The
-- other's corpse is named from the NPC, and says so.
units.nameplate3 = defiasA; creatureIds.nameplate3 = 1729; event("NAME_PLATE_UNIT_ADDED", "nameplate3")
units.nameplate3 = nil
equal(loot(defiasA, 1), 1, "first Evoker reported")
equal(source(defiasA).nameSource, "unit", "nameplate sighting names its own corpse")
equal(loot(defiasB, 1), 1, "second Evoker reported")
equal(source(defiasB).name, "Defias Evoker", "same NPC, same name")
equal(source(defiasB).nameSource, "npc", "but not claimed as a sighting of that corpse")
equal(source(defiasB).classification, nil, "no classification borrowed from another creature")

-- A corpse whose creature was never seen gets no name.
equal(loot(unknown, 1), 1, "unseen creature reported")
equal(source(unknown).name, nil, "no name guessed")

-- A unit whose client creature ID disagrees with its GUID is not named.
local liar = guidOf(1732, "00000F")
NAMES[liar] = "Not This"
units.focus = liar; creatureIds.focus = 9999; event("PLAYER_FOCUS_CHANGED")
equal(Capture.CreatureIdentity(liar, 1732).name, nil, "mismatched creature ID ignored")

-- Boss frames name the encounter's creatures.
local vancleef = guidOf(639, "000010")
NAMES[vancleef] = "Edwin VanCleef"
units.boss1 = vancleef; creatureIds.boss1 = 639; event("INSTANCE_ENCOUNTER_ENGAGE_UNIT")
equal(Capture.CreatureIdentity(vancleef, 639).name, "Edwin VanCleef", "boss frame sighting")

-- The cache stays bounded and keeps the most recent sightings.
Capture.ResetCreatureCache()
for spawn = 1, 1000 do
    local guid = guidOf(5000 + spawn, string.format("%06X", spawn))
    NAMES[guid] = "Creature " .. spawn
    now = now + 1
    units.nameplate1 = guid; creatureIds.nameplate1 = nil; event("NAME_PLATE_UNIT_ADDED", "nameplate1")
end
local kept = 0
for spawn = 1, 1000 do
    if Capture.CreatureIdentity(guidOf(5000 + spawn, string.format("%06X", spawn))).nameSource == "unit" then kept = kept + 1 end
end
assert(kept <= 400 and kept >= 300, "bounded cache, got " .. kept)
equal(Capture.CreatureIdentity(guidOf(6000, string.format("%06X", 1000)), 6000).name, "Creature 1000", "newest kept")
equal(Capture.CreatureIdentity(guidOf(5001, "000001"), 5001).nameSource, nil, "oldest dropped")

print("creature identity: ok")
