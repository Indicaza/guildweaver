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

local now = 4000

GuildweaverDB = nil
GetServerTime = function() return now end
GetCurrentRegion = function() return 1 end
GetBuildInfo = function() return "1.60.1", "60001", "Oct 6 2026", 16001 end
UnitFullName = function() return "Kumo", "Realm" end
UnitName = function() return "Kumo" end
GetRealmName = function() return "Realm" end
GetGuildInfo = function() return "Holdfast", "Private", 8, "Realm" end
UnitGUID = function(unit)
    if unit == "target" then
        return "Creature-0-1-2-3-777-00000001"
    end
end
GetZoneText = function() return "Wetlands" end
GetSubZoneText = function() return "The Green Belt" end
GetInstanceInfo = function() return "Eastern Kingdoms", "none", 0, "", 0, 0, false, 0 end
GetNumLootItems = function() return 2 end
GetLootSlotLink = function(slot)
    if slot == 1 then
        return "|cff1eff00|Hitem:765::::::::30:::::::|h[Silverleaf]|h|r"
    end
    return nil
end
GetLootSlotInfo = function(slot)
    if slot == 1 then
        return 134190, "Silverleaf", 3, nil, 1, false, false, nil, true
    end
    return 133784, "Copper", 12, 61, 1, false, false, nil, true
end
GetLootSourceInfo = function(slot)
    if slot == 1 then
        return "GameObject-0-1-2-3-1617-00000009", 3
    end
    return "Creature-0-1-2-3-777-00000001", 12
end
C_Map = {
    GetBestMapForUnit = function() return 56 end,
    GetPlayerMapPosition = function()
        return {
            GetXY = function() return 0.42, 0.73 end,
        }
    end,
}

local GW = { version = "test" }
assert(loadfile("Data/Store.lua"))("Guildweaver", GW)
assert(loadfile("Systems/TelemetryEvents.lua"))("Guildweaver", GW)
assert(loadfile("Systems/LootTelemetry.lua"))("Guildweaver", GW)
GW.Store.Initialize()

local payload = GW.LootTelemetry.Capture("TEST")
truthy(payload, "loot payload")
equal(payload.reason, "TEST", "capture reason")
equal(payload.location.zone, "Wetlands", "zone")
equal(payload.location.mapId, 56, "map id")
equal(payload.location.x, 0.42, "map x")
equal(payload.location.y, 0.73, "map y")
equal(#payload.items, 2, "loot item count")
equal(payload.items[1].itemId, 765, "item id")
equal(payload.items[1].quantity, 3, "item quantity")
equal(payload.items[1].sources[1].kind, "GameObject", "source kind")
equal(payload.items[1].sources[1].objectId, 1617, "source object id")
equal(payload.items[2].currencyId, 61, "currency id")
equal(payload.target.objectId, 777, "target object id")

local queue = GW.TelemetryEvents.GetQueue()
local stats = GW.TelemetryEvents.GetStats()
equal(stats.queued, 1, "one observation queued")
local record = nil
for _, value in pairs(queue.items) do
    record = value
end
truthy(record, "queued observation")
equal(record.envelope.eventType, "loot_observation", "event type")
equal(record.envelope.payload.items[1].itemId, 765, "queued item id")

local duplicate, duplicateReason = GW.LootTelemetry.Capture("LOOT_OPENED")
equal(duplicate, nil, "duplicate suppressed")
equal(duplicateReason, "duplicate_loot_window", "duplicate reason")
equal(GW.TelemetryEvents.GetStats().queued, 1, "duplicate does not enqueue")

now = now + 3
local later = GW.LootTelemetry.Capture("NEXT_LOOT")
truthy(later, "same loot after dedupe window")
equal(GW.TelemetryEvents.GetStats().queued, 2, "later observation queued")

print("loot telemetry tests passed")
