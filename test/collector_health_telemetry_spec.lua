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

local now = 7000

GuildweaverDB = nil
GetServerTime = function() return now end
GetCurrentRegion = function() return 1 end
GetBuildInfo = function() return "1.60.1", "60001", "Oct 6 2026", 16001 end
UnitFullName = function() return "Rook", "Realm" end
UnitName = function() return "Rook" end
GetRealmName = function() return "Realm" end
GetGuildInfo = function() return "Holdfast", "Private", 8, "Realm" end

local GW = { version = "0.5.0-test" }
assert(loadfile("Data/Store.lua"))("Guildweaver", GW)
assert(loadfile("Systems/TelemetryEvents.lua"))("Guildweaver", GW)
assert(loadfile("Systems/CollectorHealthTelemetry.lua"))("Guildweaver", GW)
GW.Store.Initialize()

GW.Character = {
    GetCurrentSnapshot = function()
        return {
            level = 30,
            talents = { api = "legacy" },
            professions = {
                {
                    name = "Alchemy",
                    recipes = {
                        { id = 1, known = true },
                        { id = 2, known = false },
                    },
                },
            },
        }
    end,
}
GW.ProfessionTelemetry = {}
GW.InventoryTelemetry = {}
GW.LootTelemetry = {}
GW.AuctionTelemetry = {}

GW.Store.SetTelemetrySnapshot("profession_snapshot:fixture", {
    schemaVersion = 1,
    eventType = "profession_snapshot",
    capturedAt = now,
    installationId = GW.Store.GetInstallationId(),
    characterId = GW.Store.GetCharacterId("realm:rook"),
    payload = { professions = {} },
})

local payload = GW.CollectorHealthTelemetry.Capture("TEST")
truthy(payload, "collector health payload")
equal(payload.addonVersion, "0.5.0-test", "addon version")
equal(payload.savedVariablesSchemaVersion, 4, "saved variables schema")
equal(payload.capabilities.inventorySnapshot, true, "inventory capability")
equal(payload.capabilities.auctionObservation, true, "auction capability")
equal(payload.observed.talentApi, "legacy", "talent api")
equal(payload.observed.professionCount, 1, "profession count")
equal(payload.observed.knownRecipeCount, 1, "known recipe count")
equal(payload.observed.stateStreamCount, 1, "state stream count excludes health")
equal(payload.observed.stateStreamTypes[1], "profession_snapshot", "state stream type")
equal(payload.eventQueue.queued, 0, "queued events")
equal(payload.eventQueue.capacity, 512, "event queue capacity")

local characterId = GW.Store.GetCharacterId("realm:rook")
local streamKey = "collector_health_snapshot:" .. characterId
local stream = GuildweaverDB.sync.outbound.telemetry[streamKey]
truthy(stream, "collector health telemetry stream")
equal(stream.revision, 1, "initial health revision")
equal(stream.envelope.eventType, "collector_health_snapshot", "health event type")

now = now + 1
GW.CollectorHealthTelemetry.Capture("UNCHANGED")
equal(GuildweaverDB.sync.outbound.telemetry[streamKey].revision, 1, "unchanged health revision")

GW.TelemetryEvents.Queue("fixture_event", { ok = true })
now = now + 1
GW.CollectorHealthTelemetry.Capture("QUEUE_CHANGED")
equal(GuildweaverDB.sync.outbound.telemetry[streamKey].revision, 2, "queue change revision")
equal(GuildweaverDB.sync.outbound.telemetry[streamKey].envelope.payload.eventQueue.queued, 1, "updated queue count")

print("collector health telemetry tests passed")
