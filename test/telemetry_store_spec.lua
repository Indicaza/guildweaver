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

GetRealmName = function() return "Live Realm" end
GetBuildInfo = function() return "1.60.1", "70338", "Nov 2026", 16001 end
GuildweaverDB = { characters = { BetaRook = {} } }
local now = 1791322510
GetServerTime = function() return now end

local addon = { version = "test" }
local chunk = assert(loadfile("Data/Store.lua"))
chunk("Guildweaver", addon)
addon.Store.Initialize()

equal(GuildweaverDB.characters.BetaRook, nil, "beta character cleared")
GuildweaverDB.characters.LiveRook = {}
addon.Store.Initialize()
truthy(GuildweaverDB.characters.LiveRook, "live character survives reload")

local Store = addon.Store
local outbound = GuildweaverDB.sync.outbound.telemetry
local telemetryLimit = Store.GetTelemetryStatus().limit

local function state(streamKey, value)
    return Store.SetTelemetrySnapshot(streamKey, { capturedAt = now, payload = { value = value } })
end

state("talents:character-rook", 1)
state("talents:character-rook", 2)
equal(outbound["talents:character-rook"].revision, 2, "state revision")
state("equipment:character-rook", 1)

for session = 1, telemetryLimit + 72 do
    now = now + 60
    Store.SetTelemetryEvent("character_session:character-rook:" .. session .. ":start", { capturedAt = now, payload = { session = session } })
end

truthy(outbound["talents:character-rook"], "state streams outlive session events")
truthy(outbound["equipment:character-rook"], "every state stream is kept")
truthy(not outbound["character_session:character-rook:1:start"], "the oldest events were pruned")
local count = 0
for _ in pairs(outbound) do count = count + 1 end
truthy(count <= telemetryLimit, "bounded")
truthy(count > telemetryLimit - 1024, "pruned in one batch, not emptied")

outbound["talents:character-rook"] = nil
state("talents:character-rook", 3)
equal(outbound["talents:character-rook"].revision, 3, "a recreated stream continues its revisions")
equal(state("talents:character-rook", 3), false, "unchanged content is still deduped")

GuildweaverDB.sync.outbound.characters = { ["darkwing:rook"] = { revision = 9, payload = {} } }
outbound["character_snapshot:character-rook"] = { revision = 9, envelope = { eventType = "character_snapshot" } }
Store.Initialize()
equal(GuildweaverDB.sync.outbound.characters, nil, "legacy character mailbox removed")
equal(GuildweaverDB.sync.outbound.telemetry["character_snapshot:character-rook"], nil, "legacy character_snapshot stream removed")
truthy(GuildweaverDB.sync.outbound.telemetry["talents:character-rook"], "other streams kept")

print("telemetry_store_spec passed")

GetRealmName = function() return "Classic Beta PvE 2" end
equal(Store.ConfirmLiveClient(), false, "beta client rejected")
equal(GuildweaverDB.gameRelease, nil, "beta saves have no live marker")
GetRealmName = function() return "Live Realm" end
IsTestBuild = function() return true end
equal(Store.ConfirmLiveClient(), false, "test build rejected")
IsTestBuild = nil
GetBuildInfo = function() return "12.1.5", "1", "Nov 2026", 120105 end
equal(Store.ConfirmLiveClient(), false, "other game rejected")
GetBuildInfo = function() return "1.60.1", "70338", "Nov 2026", 16001 end
equal(Store.ConfirmLiveClient(), true, "live client confirmed")

-- Records the bridge acknowledged are dropped at the next login; identical
-- state is not queued again, changed state is, and its revision continues.
do
    outbound = GuildweaverDB.sync.outbound.telemetry
    Store.SetTelemetrySnapshot("stats:character-ack", { capturedAt = now, payload = { value = 1 } })
    Store.SetTelemetryEvent("mob_loot:character-ack:corpse-1", { capturedAt = now, payload = { value = 1 } })
    Store.SetTelemetrySnapshot("stats:character-pending", { capturedAt = now, payload = { value = 1 } })
    local stats = outbound["stats:character-ack"]
    local loot = outbound["mob_loot:character-ack:corpse-1"]
    local pending = outbound["stats:character-pending"]
    addon.BridgeAcks = { schemaVersion = 1, telemetry = {
        ["stats:character-ack"] = stats.fingerprint,
        ["mob_loot:character-ack:corpse-1"] = loot.fingerprint,
        ["stats:character-pending"] = "stale-fingerprint",
    } }
    Store.Initialize()
    equal(outbound["stats:character-ack"], nil, "delivered state dropped")
    equal(outbound["mob_loot:character-ack:corpse-1"], nil, "delivered event dropped")
    equal(outbound["stats:character-pending"], pending, "a record with other content is kept")

    equal(Store.SetTelemetrySnapshot("stats:character-ack", { capturedAt = now, payload = { value = 1 } }), false,
        "identical delivered state is not queued again")
    equal(outbound["stats:character-ack"], nil, "still not queued")
    equal(Store.SetTelemetrySnapshot("stats:character-ack", { capturedAt = now, payload = { value = 2 } }), true,
        "changed state is queued")
    equal(outbound["stats:character-ack"].revision, stats.revision + 1, "its revision continues")
    addon.BridgeAcks = nil
    print("telemetry acknowledgement spec passed")
end
