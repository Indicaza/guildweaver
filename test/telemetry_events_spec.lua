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

local now = 3000

GuildweaverDB = nil
GetServerTime = function() return now end
GetCurrentRegion = function() return 1 end
GetBuildInfo = function() return "1.60.1", "60001", "Oct 6 2026", 16001 end
UnitFullName = function() return "Quill", "Realm" end
UnitName = function() return "Quill" end
GetRealmName = function() return "Realm" end
GetGuildInfo = function() return "Holdfast", "Private", 8, "Realm" end

local GW = { version = "test" }
assert(loadfile("Data/Store.lua"))("Guildweaver", GW)
assert(loadfile("Systems/TelemetryEvents.lua"))("Guildweaver", GW)
GW.Store.Initialize()

local first = GW.TelemetryEvents.Queue("item_looted", {
    itemId = 123,
    quantity = 2,
})
truthy(first, "queued event")
equal(first.schemaVersion, 1, "record schema")
equal(first.sequence, 1, "first sequence")
equal(first.envelope.eventType, "item_looted", "event type")
equal(first.envelope.payload.itemId, 123, "payload item")
truthy(first.eventId:match(":1$"), "event id sequence suffix")

now = now + 1
local second = GW.TelemetryEvents.Queue("craft_completed", {
    recipeId = 456,
})
equal(second.sequence, 2, "second sequence")

local stats = GW.TelemetryEvents.GetStats()
equal(stats.queued, 2, "initial queue count")
equal(stats.dropped, 0, "initial dropped count")
equal(stats.capacity, 512, "queue capacity")

for index = 1, 511 do
    now = now + 1
    GW.TelemetryEvents.Queue("fixture_event", { index = index })
end

stats = GW.TelemetryEvents.GetStats()
equal(stats.queued, 512, "bounded queue count")
equal(stats.dropped, 1, "oldest event dropped on overflow")
equal(stats.nextSequence, 513, "sequence remains monotonic")
equal(GW.TelemetryEvents.GetQueue().items[first.eventId], nil, "oldest record pruned")
truthy(GW.TelemetryEvents.GetQueue().items[second.eventId], "next oldest record retained")

local invalid, invalidReason = GW.TelemetryEvents.Queue("", {})
equal(invalid, nil, "invalid event rejected")
equal(invalidReason, "invalid_event_type", "invalid event reason")

print("telemetry event queue tests passed")
