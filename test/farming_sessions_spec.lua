local function equal(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local server = 10000
local elapsed = 100
local isAfk = false
local frame
GuildweaverDB = nil
GetServerTime = function() return server end
_G.GetTime = function() return elapsed end
_G.UnitIsAFK = function() return isAfk end
CreateFrame = function()
    frame = { RegisterEvent = function() end }
    function frame:SetScript(_, callback) self.onEvent = callback end
    return frame
end
C_Timer = { NewTicker = function(_, callback) return callback end }
local GW = { version = "test" }
assert(loadfile("Data/Store.lua"))("Guildweaver", GW)
GW.Store.Initialize()
assert(loadfile("Data/TelemetryEnvelope.lua"))("Guildweaver", GW)
GW.Character = { GetCurrentSnapshot = function()
    return { characterId = "char-1", realm = "Realm", region = "US", level = 30, class = { token = "DRUID" }, gameBuild = { build = "1" } }
end }
GW.GatheringTelemetry = { CurrentLocation = function() return { mapId = 1431, x = 0.4, y = 0.5 } end }
assert(loadfile("Systems/FarmingSessions.lua"))("Guildweaver", GW)
local function advance(seconds)
    server = server + seconds
    elapsed = elapsed + seconds
end
local function currentPayload()
    local id = GW.FarmingSessions.Context().sessionId
    return GuildweaverDB.sync.outbound.telemetry["farming_session:char-1:" .. id].envelope.payload
end

GW.FarmingSessions.RecordGather("herbalism")
local firstId = GW.FarmingSessions.Context().sessionId
advance(300)
GW.FarmingSessions.RecordGather("mining")
advance(180)
GW.FarmingSessions.Tick()
equal(currentPayload().durationSeconds, 300, "automatic observed window")
advance(421)
GW.FarmingSessions.Tick()
equal(GW.FarmingSessions.Context(), nil, "quiet gap ends candidate")
local first = GuildweaverDB.sync.outbound.telemetry["farming_session:char-1:" .. firstId].envelope.payload
equal(first.durationSeconds, 300, "quiet tail excluded and labelled estimated")
equal(first.mode, "automatic")
equal(first.endedAt, 10300)
equal(first.endReason, "gap")
equal(first.gatheringCount, 2)
equal(first.disciplines.mining, 1)

GW.FarmingSessions.RecordGather("fishing")
local nextId = GW.FarmingSessions.Context().sessionId
assert(nextId ~= firstId)
equal(GW.FarmingSessions.Start(), true)
equal(GW.FarmingSessions.Start(), false, "duplicate start")
advance(300)
GW.FarmingSessions.Tick()
isAfk = true
frame.onEvent(frame, "PLAYER_FLAGS_CHANGED", "player")
advance(600)
GW.FarmingSessions.Tick()
isAfk = false
frame.onEvent(frame, "PLAYER_FLAGS_CHANGED", "player")
advance(600)
GW.FarmingSessions.RecordGather("fishing")
local result = GW.FarmingSessions.Stop()
equal(result.mode, "manual")
equal(result.durationSeconds, 1500, "manual includes quiet travel and waiting")
equal(result.afkSeconds, 600, "only reported AFK separated")
equal(result.afkAvailable, true)
equal(result.gatheringCount, 1)
equal(GW.FarmingSessions.Stop(), nil)

_G.UnitIsAFK = nil
assert(GW.FarmingSessions.Start())
advance(40)
GW.FarmingSessions.RecordGather("skinning")
frame.onEvent(frame, "PLAYER_LOGOUT")
equal(GW.FarmingSessions.Context(), nil, "logout ends run before offline time")
local last
for _, record in pairs(GuildweaverDB.sync.outbound.telemetry) do
    if record.envelope.payload.endReason == "logout_or_reload" then last = record.envelope.payload end
end
equal(last.durationSeconds, 40)
equal(last.afkSeconds, nil, "unknown AFK is not zero")
equal(last.afkAvailable, false)

_G.UnitIsAFK = function() return false end
GW.FarmingSessions.RecordGather("herbalism")
advance(60)
GW.FarmingSessions.Tick()
local checkpoint = currentPayload().sequence
local key = "farming_session:char-1:" .. GW.FarmingSessions.Context().sessionId
local revision = GuildweaverDB.sync.outbound.telemetry[key].revision
for _ = 1, 4 do advance(60); GW.FarmingSessions.Tick() end
equal(currentPayload().sequence, checkpoint, "idle automatic checkpoints do not increment sequence")
equal(GuildweaverDB.sync.outbound.telemetry[key].revision, revision, "idle automatic revisions stay unchanged")
GW.FarmingSessions.RecordGather("mining")
GW.FarmingSessions.Tick()
equal(currentPayload().sequence, checkpoint + 1, "new gather publishes an automatic checkpoint")
GW.FarmingSessions.Stop()
assert(GW.FarmingSessions.Start())
advance(60)
GW.FarmingSessions.Tick()
local manualSequence = currentPayload().sequence
advance(60)
GW.FarmingSessions.Tick()
equal(currentPayload().sequence, manualSequence + 1, "manual duration still checkpoints")
local originalSetEvent = GW.Store.SetTelemetryEvent
GW.Store.SetTelemetryEvent = function() return false end
advance(60)
GW.FarmingSessions.Tick()
local failedSequence = currentPayload().sequence
GW.Store.SetTelemetryEvent = originalSetEvent
GW.FarmingSessions.Tick()
equal(currentPayload().sequence, failedSequence + 1, "failed publish does not advance sequence")
GW.FarmingSessions.Stop()

print("farming session timing tests passed")
