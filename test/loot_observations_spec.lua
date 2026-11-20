-- Loot observations for drop rates (loot intelligence PR 3): each corpse's
-- loot window says whether it was a complete inspection, and an atlas boss's
-- or rare's coin-only window is reported as an opportunity with no item drop,
-- so Holdfast has an honest denominator. Made-up client; proves the logic,
-- not the Forever client's loot API (docs/dungeon-guide.md checklist).

local function equal(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local now = 1000
local frame
-- VanCleef (639) and Miner Johnson (3586, a rare) are atlas creatures; 657 is Defias trash.
local VANCLEEF = "Creature-0-1-36-3-639-000010"
local MINER = "Creature-0-1-36-3-3586-000011"
local TRASH = "Creature-0-1-36-3-657-000012"
-- The window: slots of { itemId or "coin", sources = { guid, quantity, ... } }.
local window = {}
local group, lootMethod = 0, "group"
GuildweaverDB = nil
_G.GetServerTime = function() return now end
_G.GetTime = function() return now end
_G.GetLocale = function() return "enUS" end
_G.UnitGUID = function() return nil end
_G.UnitName = function() return nil end
_G.GetRealZoneText = function() return "The Deadmines" end
_G.GetNumLootItems = function() return #window end
_G.GetLootSlotInfo = function(slot)
    local entry = window[slot]
    if entry.coin then return 133784, "25 Silver", 0, 0, 0, false, false, nil, false, true end
    return 135325, "Item " .. entry.itemId, 1, 0, 3, false, false, nil, false, false
end
_G.GetLootSlotLink = function(slot)
    local entry = window[slot]
    return entry.coin and nil or ("item:" .. entry.itemId)
end
_G.GetLootSourceInfo = function(slot) return unpack(window[slot].sources) end
_G.GetInstanceInfo = function() return "The Deadmines", "party", 1, "Normal", 5, 0, false, 36 end
_G.GetNumGroupMembers = function() return group end
_G.GetLootMethod = function() return lootMethod end
_G.C_Map = { GetBestMapForUnit = function() return 1429 end, GetPlayerMapPosition = function() return { x = 0.5, y = 0.5 } end }
_G.CreateFrame = function()
    frame = { RegisterEvent = function() end, SetScript = function(self, _, fn) self.onEvent = fn end }
    return frame
end
local GW = { version = "test" }
assert(loadfile("Data/Store.lua"))("Guildweaver", GW)
GW.Store.Initialize()
assert(loadfile("Data/TelemetryEnvelope.lua"))("Guildweaver", GW)
GW.Character = { GetCurrentSnapshot = function() return { characterId = "character-1", realm = "Realm", region = "US", gameBuild = { build = "70959" } } end }
GW.DungeonGuide = { InstanceFor = function(_, npcId) return (npcId == 639 or npcId == 3586) and 36 or nil end }
assert(loadfile("Data/GatheringTelemetry.lua"))("Guildweaver", GW)
assert(loadfile("Systems/MobLootCapture.lua"))("Guildweaver", GW)

local function capture()
    GW.GatheringTelemetry.InvalidateLoot()
    return GW.MobLootCapture.Capture()
end
local function report(guid)
    return GuildweaverDB.sync.outbound.telemetry["mob_loot:character-1:" .. guid]
end

-- 1. VanCleef drops an item and coins: a complete inspection.
window = { { itemId = 5191, sources = { VANCLEEF, 1 } }, { coin = true, sources = { VANCLEEF, 2500 } } }
equal(capture(), 1, "one corpse")
local capturePayload = report(VANCLEEF).envelope.payload.capture
equal(capturePayload.inspection, "complete", "every slot mapped")
equal(capturePayload.partialReason, nil)
equal(capturePayload.slotCount, 2)
equal(#report(VANCLEEF).envelope.payload.outputs, 1, "coins are not items")

-- 2. The rare's window held only coins: an opportunity without an item drop.
window = { { coin = true, sources = { MINER, 1200 } } }
equal(capture(), 1, "the rare is reported with no items")
equal(#report(MINER).envelope.payload.outputs, 0, "no outputs")
equal(report(MINER).envelope.payload.capture.inspection, "complete")

-- 3. Trash with only coins: nothing (not an atlas creature; keeps the volume small).
window = { { coin = true, sources = { TRASH, 300 } } }
equal(capture(), 0, "trash coin-only: no report")
equal(report(TRASH), nil)

-- 4. Reopening the same corpse: no second report (one physical drop, one count).
window = { { itemId = 5191, sources = { VANCLEEF, 1 } }, { coin = true, sources = { VANCLEEF, 2500 } } }
equal(capture(), 0, "reopened: nothing new")
equal(report(VANCLEEF).revision, 1)
-- After /reload too (the seen cache is saved).
assert(loadfile("Systems/MobLootCapture.lua"))("Guildweaver", GW)
equal(capture(), 0, "after reload: nothing new")

-- 5. A slot that cannot be tied to its corpse: partial, never a denominator.
local BOSS2 = "Creature-0-1-36-3-639-000020"
window = { { itemId = 5193, sources = { BOSS2, 1 } }, { itemId = 5202, sources = {} } }
equal(capture(), 1)
equal(report(BOSS2).envelope.payload.capture.inspection, "partial", "an unmapped slot")
equal(report(BOSS2).envelope.payload.capture.partialReason, "unmapped-slot")

-- 6. Free-for-all in a group: someone may have taken items first.
local BOSS3 = "Creature-0-1-36-3-639-000030"
group, lootMethod = 5, "freeforall"
window = { { itemId = 5193, sources = { BOSS3, 1 } } }
equal(capture(), 1)
equal(report(BOSS3).envelope.payload.capture.inspection, "partial")
equal(report(BOSS3).envelope.payload.capture.partialReason, "free-for-all")
-- A partial window's coin-only boss is not reported as an empty opportunity.
local BOSS4 = "Creature-0-1-36-3-639-000040"
window = { { coin = true, sources = { BOSS4, 900 } } }
equal(capture(), 0, "coin-only, but not a complete inspection: nothing claimed")
-- Group loot (not free-for-all) in a group is complete.
group, lootMethod = 5, "group"
local BOSS5 = "Creature-0-1-36-3-639-000050"
window = { { itemId = 5191, sources = { BOSS5, 1 } } }
equal(capture(), 1)
equal(report(BOSS5).envelope.payload.capture.inspection, "complete")

-- 7. No names or player data in the payload's capture block.
for key in pairs(report(BOSS5).envelope.payload.capture) do
    assert(({ attribution = true, visibility = true, yieldBasis = true, inspection = true, partialReason = true, slotCount = true })[key], "capture field " .. key)
end

print("loot observations spec passed")
