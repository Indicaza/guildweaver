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

equal(GuildweaverDB.characters.BetaRook, nil, "beta character excluded from active save")
truthy(GuildweaverDB.releaseQuarantine.characters.BetaRook, "legacy beta data retained offline")
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

-- Live Forever realms can use test-flagged builds. Explicit Beta/PTR realm
-- names and unrelated clients must still fail closed.
do
    local existing = GuildweaverDB
    GetRealmName = function() return "CAMWOW US2 Realm 9 RP PvP" end
    IsTestBuild = function() return true end
    equal(Store.ConfirmLiveClient(), true, "numbered live realm with test flag")
    equal(GuildweaverDB.gameRelease, "forever-live", "live marker set")
    GetRealmName = function() return nil end
    equal(Store.ConfirmLiveClient(), false, "temporarily unavailable realm rejected")
    equal(GuildweaverDB.meta.releaseValidation.reason, "realm_unavailable", "specific rejection")
    Store.Initialize()
    equal(GuildweaverDB, existing, "temporarily unavailable realm preserves the save")
    equal(GuildweaverDB.gameRelease, nil, "unconfirmed save not uploadable")
    GetRealmName = function() return "CAMWOW US2 Realm 9 RP PvP" end
    Store.Initialize()
    equal(GuildweaverDB, existing, "reloading does not erase previously confirmed data")
    equal(GuildweaverDB.gameRelease, "forever-live", "confirmation recovers")
    GetRealmName = function() return "CAMWOW US2 Realm 9 RP PvP Beta" end
    equal(Store.ConfirmLiveClient(), false, "explicit beta realm never promoted")
    equal(GuildweaverDB.meta.releaseValidation.reason, "test_realm", "specific rejection")
    GetRealmName = function() return "CAMWOW US2 Realm 9 RP PvP" end
    GetBuildInfo = function() return "12.1.5", "1", "Nov 2026", 120105 end
    equal(Store.ConfirmLiveClient(), false, "unrelated interface rejected even with numbered realm")
    GetBuildInfo = function() return "1.60.1", "70338", "Nov 2026", 16001 end
    GetRealmName = function() return "Live Realm" end
    IsTestBuild = function() return 0 end
    equal(Store.ConfirmLiveClient(), true, "numeric false flag not truthy")
    IsTestBuild = nil
end

-- An affected live save has no release marker but still contains realm
-- evidence. Keep the original IDs, queued telemetry and user settings.
do
    GetRealmName = function() return "CAMWOW US2 Realm 9 RP PvP" end
    IsTestBuild = function() return true end
    local oldSave = {
        schemaVersion = 4,
        meta = { installationId = "existing-install", characterIds = { rook = "existing-rook" } },
        characters = { rook = { realm = GetRealmName(), level = 18 } },
        sync = { outbound = { telemetry = {
            ["character:existing-rook"] = { revision = 8, envelope = { realm = GetRealmName() } },
        } } },
    }
    GuildweaverDB = oldSave
    Store.Initialize()
    equal(GuildweaverDB, oldSave, "unmarked proven live save recovered in place")
    equal(GuildweaverDB.meta.installationId, "existing-install", "installation identity preserved")
    equal(GuildweaverDB.meta.characterIds.rook, "existing-rook", "character identity preserved")
    equal(GuildweaverDB.sync.outbound.telemetry["character:existing-rook"].revision, 8, "outbox preserved")
    equal(GuildweaverDB.gameRelease, "forever-live", "recovered save eligible")
    GuildweaverDB = {
        schemaVersion = 4,
        characters = { rook = { realm = GetRealmName() }, beta = { realm = "Classic Beta PvE 2" } },
    }
    Store.Initialize()
    equal(GuildweaverDB.characters.beta, nil, "mixed legacy save not promoted")
    truthy(GuildweaverDB.releaseQuarantine.characters.beta, "mixed legacy save retained")
    local quarantine = GuildweaverDB.releaseQuarantine
    GetRealmName = function() return nil end
    Store.Initialize()
    Store.Initialize()
    equal(GuildweaverDB.releaseQuarantine, quarantine, "no repeated quarantine nesting")
    IsTestBuild = nil
end

print("live release validation specs passed")

-- Initialized does not mean live. A beta store must remain offline when
-- loaded by the live client, including after it received the new metadata.
do
    GuildweaverDB = nil
    GetRealmName = function() return "Classic Beta PvE 2" end
    Store.Initialize()
    local beta = GuildweaverDB
    beta.characters.beta = { realm = GetRealmName() }
    equal(beta.meta.releaseValidationVersion, 1, "beta store initialized")
    GetRealmName = function() return "Live Realm" end
    Store.Initialize()
    equal(GuildweaverDB.characters.beta, nil, "initialized beta store excluded")
    equal(GuildweaverDB.releaseQuarantine, beta, "initialized beta store retained offline")
end
