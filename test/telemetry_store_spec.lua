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

GuildweaverDB = nil
local now = 1791322510
GetServerTime = function() return now end

local addon = { version = "test" }
local chunk = assert(loadfile("Data/Store.lua"))
chunk("Guildweaver", addon)
addon.Store.Initialize()

local Store = addon.Store
local outbound = GuildweaverDB.sync.outbound.telemetry

local function state(streamKey, value)
    return Store.SetTelemetrySnapshot(streamKey, { capturedAt = now, payload = { value = value } })
end

-- A character's state streams, written long ago.
state("talents:character-rook", 1)
state("talents:character-rook", 2)
equal(outbound["talents:character-rook"].revision, 2, "state revision")
state("equipment:character-rook", 1)

-- Many logins later: one checkpoint event per session, all newer.
for session = 1, 200 do
    now = now + 60
    Store.SetTelemetryEvent("character_session:character-rook:" .. session .. ":start", { capturedAt = now, payload = { session = session } })
end

truthy(outbound["talents:character-rook"], "state streams outlive session events")
truthy(outbound["equipment:character-rook"], "every state stream is kept")
truthy(not outbound["character_session:character-rook:1:start"], "the oldest events were pruned")
local count = 0
for _ in pairs(outbound) do count = count + 1 end
equal(count, 128, "bounded")

-- Even when a state stream is pruned, its revisions continue.
outbound["talents:character-rook"] = nil
state("talents:character-rook", 3)
equal(outbound["talents:character-rook"].revision, 3, "a recreated stream continues its revisions")
equal(state("talents:character-rook", 3), false, "unchanged content is still deduped")

-- Upgrading from a version that also sent whole character snapshots.
GuildweaverDB.sync.outbound.characters = { ["darkwing:rook"] = { revision = 9, payload = {} } }
outbound["character_snapshot:character-rook"] = { revision = 9, envelope = { eventType = "character_snapshot" } }
Store.Initialize()
equal(GuildweaverDB.sync.outbound.characters, nil, "legacy character mailbox removed")
equal(GuildweaverDB.sync.outbound.telemetry["character_snapshot:character-rook"], nil, "legacy character_snapshot stream removed")
truthy(GuildweaverDB.sync.outbound.telemetry["talents:character-rook"], "other streams kept")

print("telemetry_store_spec passed")
