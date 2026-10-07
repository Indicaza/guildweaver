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

local now = 2000
GuildweaverDB = nil
GetServerTime = function() return now end

local GW = { version = "test" }
assert(loadfile("Data/Store.lua"))("Guildweaver", GW)
GW.Store.Initialize()

local firstSession, resumed = GW.Store.BeginCaptureSession()
truthy(firstSession, "session id")
equal(resumed, false, "new session")

GW.Store.MarkCaptureReloadPending()
equal(GW.Store.IsCaptureReloadPending(), true, "reload pending")

now = 2001
local resumedSession, resumedAfterReload = GW.Store.BeginCaptureSession()
equal(resumedSession, firstSession, "session survives reload")
equal(resumedAfterReload, true, "reload resume")
equal(GW.Store.IsCaptureReloadPending(), false, "reload consumed")

local envelope = {
    schemaVersion = 1,
    eventType = "character_session_checkpoint",
    capturedAt = now,
    characterId = "character-1",
    payload = {
        sessionId = firstSession,
        checkpoint = "start",
        name = "Rook",
    },
}

local added = GW.Store.SetTelemetryEvent("character_session:character-1:" .. firstSession .. ":start", envelope)
equal(added, true, "event added")

local record = GuildweaverDB.sync.outbound.telemetry["character_session:character-1:" .. firstSession .. ":start"]
equal(record.kind, "event", "event kind")
equal(record.revision, 1, "event revision")

now = 2002
envelope.capturedAt = now
local duplicate = GW.Store.SetTelemetryEvent("character_session:character-1:" .. firstSession .. ":start", envelope)
equal(duplicate, false, "unchanged event deduped")
equal(record.revision, 1, "event revision unchanged")

equal(GW.Store.EndCaptureSession(), firstSession, "ended session")
local endedSession = GW.Store.GetCaptureSession()
equal(endedSession, nil, "session cleared")

print("session capture store tests passed")