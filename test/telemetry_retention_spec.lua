local function equal(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
GuildweaverDB = nil
GetServerTime = function() return 10000 end
local GW = { version = "test" }
assert(loadfile("Data/Store.lua"))("Guildweaver", GW)
GW.Store.Initialize()
local function record(kind, eventType, timestamp, revision)
    return { kind = kind, revision = revision or 1, updatedAt = timestamp,
        envelope = { eventType = eventType, payload = { schemaVersion = 1, value = 1 } } }
end
local function envelope(eventType, value, timestamp)
    return { eventType = eventType, capturedAt = timestamp or 10000, payload = { schemaVersion = 1, value = value or 1 } }
end
local function reset()
    GuildweaverDB.sync.outbound.telemetry = {}
    return GuildweaverDB.sync.outbound.telemetry
end
local outbox = reset()
for index = 1, 4096 do outbox["definition:" .. index] = record("state", "item_definition", index, 7) end
assert(GW.Store.SetTelemetryEvent("new-event", envelope("gathering_loot")))
equal(outbox["new-event"].kind, "event", "new event survives a legacy definition-filled outbox")
equal(outbox["definition:1"], nil, "oldest definition evicted")
equal(GW.Store.GetTelemetryStatus().count, 1501, "combined definition sub-cap")
assert(GW.Store.SetTelemetrySnapshot("definition:1", envelope("item_definition")))
equal(outbox["definition:1"].revision, 8, "pruned legacy definition resumes revisions")
equal(outbox["definition:1"].tier, "catalog", "explicit catalog tier")

outbox = reset()
outbox.definition = record("state", "game_item_definition", 100000)
outbox.event = record("event", "mob_loot", 100000)
for index = 1, 4095 do outbox["character:" .. index] = record("state", "character", index) end
assert(GW.Store.SetTelemetrySnapshot("new-character", envelope("character", 2, 0)))
equal(outbox.definition, nil, "catalog before events")
equal(outbox.event, nil, "events before character state")
equal(outbox["character:1"] ~= nil, true, "character state protected while lower tiers remain")
equal(outbox["new-character"] ~= nil, true, "fresh record survives even with an old timestamp")
assert(GW.Store.SetTelemetryEvent("new-event", envelope("mob_loot", 2, 0)))
equal(outbox["new-character"], nil, "oldest character state is last resort after insertion protection ends")
equal(outbox["new-event"] ~= nil, true, "new event protected even if only character states can be evicted")
equal(GW.Store.GetTelemetryStatus().count, 4096, "global cap remains enforced")

outbox = reset()
for index = 1, 1600 do
    local eventType = index % 2 == 0 and "game_item_definition" or "item_definition"
    assert(GW.Store.SetTelemetrySnapshot("catalog:" .. index, envelope(eventType, index, index)))
end
equal(GW.Store.GetTelemetryStatus().count, 1500, "definition sub-cap across both types")
equal(outbox["catalog:100"], nil, "old catalog records evicted first")
equal(outbox["catalog:101"] ~= nil, true, "newer catalog retained")
assert(GW.Store.SetTelemetrySnapshot("catalog:1", envelope("item_definition", 1, 0)))
equal(outbox["catalog:1"].revision, 2, "recreated definitions preserve saved revisions")
equal(outbox["catalog:1"] ~= nil, true, "fresh catalog record protected")
print("telemetry retention priority tests passed")
