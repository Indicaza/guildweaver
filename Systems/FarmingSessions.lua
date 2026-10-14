local _, GW = ...

GW.FarmingSessions = GW.FarmingSessions or {}

local Globals = _G or {}
local GAP_SECONDS = 600
local CHECKPOINT_SECONDS = 60
local run = nil

local function safe(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, value = pcall(fn, ...)
    if not ok then
        return nil
    end
    if type(Globals.issecretvalue) == "function" then
        local checked, secret = pcall(Globals.issecretvalue, value)
        if checked and secret then
            return nil
        end
    end
    return value
end

local function clock()
    return tonumber(safe(Globals.GetTime)) or tonumber(safe(Globals.GetServerTime)) or 0
end

local function now()
    return tonumber(safe(Globals.GetServerTime)) or 0
end

local function afk()
    local value = safe(Globals.UnitIsAFK, "player")
    return value == true, type(value) == "boolean"
end

local function accountTime()
    if not run then
        return
    end
    local current = clock()
    local delta = math.max(0, current - run.lastTick)
    run.durationSeconds = run.durationSeconds + delta
    if run.afk then
        run.afkSeconds = run.afkSeconds + delta
    end
    run.lastTick = current
    local isAfk, known = afk()
    run.afk = isAfk
    run.afkAvailable = run.afkAvailable and known
end

local function publish(status, reason, endAtLastGather)
    if not run then
        return nil
    end
    local sequence = run.sequence + 1
    local elapsed = endAtLastGather and run.lastGatherDuration or run.durationSeconds
    local afkSeconds = endAtLastGather and run.lastGatherAfk or run.afkSeconds
    local endedAt = endAtLastGather and run.lastGatherAt or now()
    local disciplines = {}
    for key, count in pairs(run.disciplines) do
        disciplines[key] = count
    end
    local payload = {
        schemaVersion = 1,
        sessionId = run.sessionId,
        sequence = sequence,
        mode = run.mode,
        status = status,
        endReason = status == "complete" and reason or nil,
        startedAt = run.startedAt,
        endedAt = status == "complete" and endedAt or nil,
        durationSeconds = elapsed,
        afkSeconds = run.afkAvailable and afkSeconds or nil,
        afkAvailable = run.afkAvailable,
        gatheringCount = run.gatheringCount,
        disciplines = disciplines,
        location = run.location,
        characterLevel = run.snapshot.level,
        classToken = run.snapshot.class and run.snapshot.class.token or nil,
        yieldBasis = "loot_window",
        gapThresholdSeconds = GAP_SECONDS,
    }
    local envelope = GW.TelemetryEnvelope.Build("farming_session", payload, {
        capturedAt = now(),
        characterId = run.snapshot.characterId,
        realm = run.snapshot.realm,
        region = run.snapshot.region,
        gameBuild = run.snapshot.gameBuild,
    })
    local key = "farming_session:" .. tostring(run.snapshot.characterId) .. ":" .. run.sessionId
    if not envelope or not GW.Store.SetTelemetryEvent(key, envelope) then return nil end
    run.sequence = sequence
    run.publishedGatheringCount = run.gatheringCount
    run.publishedGatherDuration = run.lastGatherDuration
    run.publishedGatherAfk = run.lastGatherAfk
    run.lastPublished = clock()
    return payload
end

local function finish(reason, endAtLastGather)
    accountTime()
    local payload = publish("complete", reason, endAtLastGather)
    run = nil
    if GW.MainFrame and GW.MainFrame.RefreshFarmingTimer then
        GW.MainFrame:RefreshFarmingTimer()
    end
    return payload
end

local function begin(mode)
    local snapshot = GW.Character and safe(GW.Character.GetCurrentSnapshot)
    if not snapshot or not snapshot.characterId then
        return false
    end
    local isAfk, known = afk()
    local timestamp = now()
    run = {
        sessionId = "farm-" .. tostring(timestamp) .. "-" .. tostring(math.random(0, 2147483647))
            .. "-" .. tostring(math.random(0, 2147483647)),
        snapshot = snapshot,
        mode = mode,
        startedAt = timestamp,
        lastTick = clock(),
        lastPublished = clock(),
        durationSeconds = 0,
        afkSeconds = 0,
        afk = isAfk,
        afkAvailable = known,
        gatheringCount = 0,
        disciplines = {},
        sequence = 0,
        location = GW.GatheringTelemetry.CurrentLocation(),
    }
    publish("open")
    if GW.MainFrame and GW.MainFrame.RefreshFarmingTimer then
        GW.MainFrame:RefreshFarmingTimer()
    end
    return true
end

function GW.FarmingSessions.Start()
    if run and run.mode == "manual" then
        return false
    end
    if run then
        finish("manual_start", true)
    end
    return begin("manual")
end

function GW.FarmingSessions.Stop()
    return run and finish("stopped", false) or nil
end

function GW.FarmingSessions.Context()
    return run and { sessionId = run.sessionId, mode = run.mode } or nil
end

function GW.FarmingSessions.RecordGather(discipline)
    if run and run.mode == "automatic" and clock() - run.lastGatherClock > GAP_SECONDS then
        finish("gap", true)
    end
    if not run and not begin("automatic") then
        return
    end
    accountTime()
    run.gatheringCount = run.gatheringCount + 1
    run.disciplines[discipline] = (run.disciplines[discipline] or 0) + 1
    run.lastGatherAt = now()
    run.lastGatherClock = clock()
    run.lastGatherDuration = run.durationSeconds
    run.lastGatherAfk = run.afkSeconds
end

function GW.FarmingSessions.Tick()
    if not run then
        return
    end
    accountTime()
    if run.mode == "automatic" and clock() - run.lastGatherClock > GAP_SECONDS then
        finish("gap", true)
    elseif clock() - run.lastPublished >= CHECKPOINT_SECONDS then
        if run.mode == "manual" or run.gatheringCount ~= run.publishedGatheringCount
            or run.lastGatherDuration ~= run.publishedGatherDuration or run.lastGatherAfk ~= run.publishedGatherAfk then
            publish("open", nil, run.mode == "automatic")
        end
    end
end

function GW.FarmingSessions:Initialize()
    if self.frame then
        return
    end
    local frame = Globals.CreateFrame("Frame")
    frame:RegisterEvent("PLAYER_LOGOUT")
    frame:RegisterEvent("PLAYER_FLAGS_CHANGED")
    frame:SetScript("OnEvent", function(_, event, unit)
        if event == "PLAYER_LOGOUT" and run then
            finish("logout_or_reload", run.mode == "automatic")
        elseif event == "PLAYER_FLAGS_CHANGED" and unit == "player" then
            accountTime()
        end
    end)
    self.frame = frame
    if Globals.C_Timer and type(Globals.C_Timer.NewTicker) == "function" then
        self.ticker = Globals.C_Timer.NewTicker(5, GW.FarmingSessions.Tick)
    end
end

GW.FarmingSessions:Initialize()
