local function equal(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local now = 1000
local frame
local creatureA = "Creature-0-1-2-3-12345-000001"
local creatureB = "Creature-0-1-2-3-12346-000002"
local object = "GameObject-0-1-2-3-1618-000003"
local sourcePairs = { creatureA, 2, creatureB, 1 }
local quantity = 3
local itemId = 2589
local unitGuid = creatureA
GuildweaverDB = nil
_G.GetServerTime = function() return now end
_G.GetTime = function() return now end
_G.GetLocale = function() return "enUS" end
_G.UnitGUID = function() return unitGuid end
_G.UnitName = function() return "Forest Spider" end
_G.GetRealZoneText = function() return "Elwynn Forest" end
_G.GetNumLootItems = function() return 1 end
_G.GetLootSlotInfo = function() return 132889, "Linen Cloth", quantity, 0, 1, false, true end
_G.GetLootSlotLink = function() return "item:" .. tostring(itemId) end
_G.GetLootSourceInfo = function() return unpack(sourcePairs) end
_G.GetInstanceInfo = function() return "Deadmines", "party", 1, "Normal", 5, 0, false, 36 end
_G.C_Map = { GetBestMapForUnit = function() return 1429 end,
    GetPlayerMapPosition = function() return { x = 0, y = 1 } end }
_G.CreateFrame = function()
    frame = { RegisterEvent = function() end, SetScript = function(self, _, fn) self.onEvent = fn end }
    return frame
end
local GW = { version = "test" }
assert(loadfile("Data/Store.lua"))("Guildweaver", GW)
GW.Store.Initialize()
assert(loadfile("Data/TelemetryEnvelope.lua"))("Guildweaver", GW)
GW.Character = { GetCurrentSnapshot = function() return { characterId = "character-1", realm = "Realm", region = "US", gameBuild = { build = "70338" } } end }
assert(loadfile("Data/GatheringTelemetry.lua"))("Guildweaver", GW)
assert(loadfile("Systems/MobLootCapture.lua"))("Guildweaver", GW)
frame.onEvent(frame, "PLAYER_TARGET_CHANGED")
local loot = GW.GatheringTelemetry.ReadLoot()
equal(#loot.outputs[1].sources, 2, "per-slot sources")
equal(loot.outputs[1].sourceMappingComplete, true, "exact quantity assignment")
equal(GW.MobLootCapture.Capture(), 2, "two corpse reports")
local function report(guid)
    return GuildweaverDB.sync.outbound.telemetry["mob_loot:character-1:" .. guid]
end
equal(report(creatureA).envelope.payload.outputs[1].quantity, 2, "first corpse quantity")
equal(report(creatureB).envelope.payload.outputs[1].quantity, 1, "second corpse quantity")
equal(report(creatureA).envelope.payload.source.name, "Forest Spider", "matching GUID name")
equal(report(creatureB).envelope.payload.source.name, nil, "unknown name not guessed")
equal(report(creatureA).envelope.payload.context.location.positionKind, "player_at_loot", "position semantics")
equal(report(creatureA).envelope.payload.context.location.x, 0, "coordinate edge")
equal(report(creatureA).envelope.payload.context.instance.instanceId, 36, "dungeon context")
equal(report(creatureA).envelope.locale, "enUS", "locale")
equal(GW.MobLootCapture.Capture(), 0, "ready/opened duplicate")
now = 1001
assert(loadfile("Systems/MobLootCapture.lua"))("Guildweaver", GW)
equal(GW.MobLootCapture.Capture(), 0, "relogin duplicate")
sourcePairs = { creatureA, 1 }; quantity = 1
equal(GW.MobLootCapture.Capture(), 0, "partial reopen never reduces or adds quantity")
sourcePairs = { creatureA, 4 }; quantity = 4
equal(GW.MobLootCapture.Capture(), 1, "updated stack")
equal(report(creatureA).revision, 2, "new revision")
equal(report(creatureA).envelope.capturedAt, 1000, "original corpse capture time")
sourcePairs = { creatureB, 1 }; quantity = 2; itemId = 2835
equal(GW.MobLootCapture.Capture(), 0, "ambiguous source quantity skipped")
sourcePairs = {}; quantity = 1
equal(GW.MobLootCapture.Capture(), 0, "missing mapping skipped")
sourcePairs = { "Player-1-11111", 1 }
equal(GW.MobLootCapture.Capture(), 0, "player source excluded")
sourcePairs = { object, 1 }
equal(GW.MobLootCapture.Capture(), 0, "container/object excluded")
sourcePairs = { object, 1, creatureB, 1 }; quantity = 2
equal(GW.MobLootCapture.Capture(), 1, "mixed sources preserve only assigned corpse item")
equal(report(creatureB).envelope.payload.outputs[2].quantity, 1, "mixed source allocation")
sourcePairs = { creatureB, 1 }; quantity = 1; itemId = 2318
GW.SkinningCapture = { pending = { armedAt = now } }
equal(GW.MobLootCapture.Capture(), nil, "pending skinning excluded")
GW.SkinningCapture = { lootWindowActive = true }
equal(GW.MobLootCapture.Capture(), nil, "skinning frame order")
GW.SkinningCapture = {}
equal(GW.MobLootCapture.Capture(), 0, "reopened skinned corpse excluded")
now = 10000
itemId = 2589
sourcePairs = { creatureA, 1 }
equal(GW.MobLootCapture.Capture(), 1, "bounded seen cache expires")
_G.GetNumLootItems = function() return 0 end
equal(GW.MobLootCapture.Capture(), nil, "empty loot not a zero-drop sample")
print("mob loot attribution and capture tests passed")
