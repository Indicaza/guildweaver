local _, GW = ...

-- Dungeon and raid runs. A run starts on entering a party or raid instance
-- and is kept in SavedVariables, so a /reload, a disconnect or a run back
-- from the graveyard continues it instead of starting another.
--
-- Everything here is event driven and O(1) per event. Nothing reads the
-- combat log (addons cannot on Forever), nothing scans or parses tooltips,
-- and the run is only written to the telemetry queue when it ends or when
-- the game is about to save (PLAYER_LOGOUT, which also fires on /reload).
-- The website cannot see a run before WoW writes SavedVariables anyway.
GW.DungeonSessions = GW.DungeonSessions or {}

local Globals = _G or {}
local SCHEMA_VERSION = 1
-- Leaving and coming back to the same instance within this window (a run
-- back after a death, a disconnect, a /reload) continues the run.
local REENTRY_SECONDS = 600
local MAX_TIMELINE = 60
local MAX_HISTORY = 10
local MAX_ACTIVE = 8
-- Runs shorter than this with nothing recorded are not kept (zoning in and
-- straight back out, a ghost passing the portal).
local MIN_KEEP_SECONDS = 60
local SWEEP_SECONDS = 30

local Sessions = GW.DungeonSessions
Sessions.SCHEMA_VERSION = SCHEMA_VERSION
Sessions.REENTRY_SECONDS = REENTRY_SECONDS
Sessions.MAX_TIMELINE = MAX_TIMELINE
Sessions.MAX_HISTORY = MAX_HISTORY

local function isSecret(value)
    if type(Globals.issecretvalue) ~= "function" then
        return false
    end
    local ok, secret = pcall(Globals.issecretvalue, value)
    return ok and secret == true
end

local function scalar(value)
    if value == nil or isSecret(value) then
        return nil
    end
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" then
        return value
    end
    return nil
end

local function call(fn, ...)
    if type(fn) ~= "function" then
        return false
    end
    return pcall(fn, ...)
end

local function safe(fn, ...)
    local ok, value = call(fn, ...)
    if not ok then
        return nil
    end
    return scalar(value)
end

local function number(value)
    value = scalar(value)
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then
        return nil
    end
    return value
end

local function text(value, max)
    value = scalar(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    return string.sub(value, 1, max or 120)
end

local function serverNow()
    return number(safe(Globals.GetServerTime)) or 0
end

local function clock()
    return number(safe(Globals.GetTime)) or serverNow()
end

local function store()
    local db = GW.Store and GW.Store.GetDatabase and GW.Store.GetDatabase()
    if type(db) ~= "table" then
        return nil
    end
    db.dungeon = type(db.dungeon) == "table" and db.dungeon or {}
    local dungeon = db.dungeon
    dungeon.active = type(dungeon.active) == "table" and dungeon.active or {}
    dungeon.history = type(dungeon.history) == "table" and dungeon.history or {}
    return dungeon
end

local function snapshot()
    local character = GW.Character
    local ok, value = call(character and character.GetCurrentSnapshot)
    if ok and type(value) == "table" and value.characterId then
        return value
    end
    return nil
end

-- Reads -----------------------------------------------------------------------

-- The current party or raid instance, or nil. Every field is optional: a
-- secret or missing value is left out, never guessed.
local function readInstance()
    local ok, inInstance, kind = call(Globals.IsInInstance)
    if ok and scalar(inInstance) == false then
        return nil
    end
    local okInfo, name, infoKind, difficultyId, difficultyName, maxPlayers, _, _, instanceId = call(Globals.GetInstanceInfo)
    if not okInfo then
        return nil
    end
    kind = text(kind, 20) or text(infoKind, 20)
    if kind ~= "party" and kind ~= "raid" then
        return nil
    end
    return {
        name = text(name),
        type = kind,
        instanceId = number(instanceId),
        difficultyId = number(difficultyId),
        difficultyName = text(difficultyName, 60),
        maxPlayers = number(maxPlayers),
    }
end

local function sameInstance(left, right)
    if not left or not right then
        return false
    end
    if left.instanceId and right.instanceId then
        return left.instanceId == right.instanceId and left.difficultyId == right.difficultyId
    end
    return left.name ~= nil and left.name == right.name and left.type == right.type
end

local function readXp()
    local level = number(safe(Globals.UnitLevel, "player"))
    local current = number(safe(Globals.UnitXP, "player"))
    local maximum = number(safe(Globals.UnitXPMax, "player"))
    local cap = number(safe(Globals.GetMaxPlayerLevel))
    local disabled = safe(Globals.IsXPUserDisabled) == true
    local atCap = disabled or (level ~= nil and cap ~= nil and level >= cap) or (maximum ~= nil and maximum <= 0)
    return {
        level = level,
        current = current,
        maximum = maximum,
        atCap = atCap,
        available = level ~= nil and current ~= nil and maximum ~= nil,
    }
end

local function readMoney()
    return number(safe(Globals.GetMoney))
end

local function readGroupSize()
    local size = number(safe(Globals.GetNumGroupMembers))
    if size == nil then
        return nil
    end
    return math.max(1, math.floor(size))
end

-- Bosses the lockout says this instance has and how many are down. Only
-- saved instances report it; elsewhere this is nil.
local function readLockProgress()
    local ok, _, _, total, complete = call(Globals.GetInstanceLockTimeRemaining)
    if not ok then
        return nil
    end
    total, complete = number(total), number(complete)
    if not total or total <= 0 or not complete then
        return nil
    end
    return total, complete
end

-- Run state -------------------------------------------------------------------

local function activeRun(characterId)
    local dungeon = store()
    return dungeon and characterId and dungeon.active[characterId] or nil
end

local function currentRun()
    local character = snapshot()
    return character and activeRun(character.characterId) or nil
end

local function offset(run)
    return math.max(0, math.floor((run.durationSeconds or 0) + 0.5))
end

local function addEvent(run, kind, fields)
    run.timeline = run.timeline or {}
    if #run.timeline >= MAX_TIMELINE then
        run.timelineTruncated = true
        return nil
    end
    local entry = { at = offset(run), kind = kind }
    for key, value in pairs(fields or {}) do
        entry[key] = value
    end
    table.insert(run.timeline, entry)
    return entry
end

-- Adds the time since the last tick to the run. Offline time never counts:
-- the clock restarts on resume.
local function accountTime(run)
    if not run or run.suspended then
        return
    end
    local now = clock()
    local last = tonumber(run.lastTick) or now
    if now >= last then
        run.durationSeconds = (run.durationSeconds or 0) + (now - last)
        if run.inside then
            run.insideSeconds = (run.insideSeconds or 0) + (now - last)
        end
    end
    run.lastTick = now
    run.lastActiveAt = serverNow()
end

local function sampleXp(run, levelUpTo)
    local xp = run.xp
    if not xp then
        return
    end
    local reading = readXp()
    if not reading.available then
        xp.unavailableSamples = (xp.unavailableSamples or 0) + 1
        return
    end
    if xp.lastLevel == nil then
        xp.lastLevel, xp.lastCurrent, xp.lastMaximum = reading.level, reading.current, reading.maximum
        return
    end
    local level = math.max(reading.level, levelUpTo or 0)
    if level > xp.lastLevel then
        -- Level up: the rest of the old level, then what is into the new one.
        -- A jump of several levels in one update cannot be measured exactly.
        xp.gained = xp.gained + math.max(0, (xp.lastMaximum or 0) - (xp.lastCurrent or 0))
        if level - xp.lastLevel > 1 then
            xp.partial = true
        end
        xp.levelUps = xp.levelUps + (level - xp.lastLevel)
        local into = reading.level >= level and reading.current or 0
        xp.gained = xp.gained + into
        xp.lastLevel, xp.lastCurrent = level, into
        xp.lastMaximum = reading.level >= level and reading.maximum or nil
        run.levelAtExit = level
        addEvent(run, "level_up", { level = level })
        return
    end
    if reading.level < xp.lastLevel then
        -- UnitLevel has not caught up with PLAYER_LEVEL_UP yet.
        return
    end
    if reading.current > (xp.lastCurrent or 0) then
        xp.gained = xp.gained + (reading.current - (xp.lastCurrent or 0))
    end
    xp.lastCurrent, xp.lastMaximum = reading.current, reading.maximum
    if reading.atCap then
        xp.atCap = true
    end
end

local function sampleMoney(run)
    local money = readMoney()
    if money == nil or run.wallet.startCopper == nil then
        return
    end
    run.wallet.netCopper = money - run.wallet.startCopper
end

local function refreshBosses(run)
    local total, complete = readLockProgress()
    if total then
        run.bosses.total = total
        run.bosses.lockComplete = complete
    end
end

local function bossesDone(run)
    local bosses = run.bosses
    if not bosses.total then
        return false
    end
    local complete = math.max(bosses.lockComplete or 0, bosses.defeated or 0)
    return complete >= bosses.total
end

local function newRun(character, instance)
    local now = serverNow()
    local xp = readXp()
    local run = {
        runId = string.format("dungeon-%x-%x-%x", now, math.random(0, 2147483647), math.random(0, 2147483647)),
        characterId = character.characterId,
        identity = {
            realm = character.realm,
            region = character.region,
            gameBuild = character.gameBuild,
            classToken = character.class and character.class.token or nil,
        },
        instance = instance,
        sequence = 0,
        startedAt = now,
        lastActiveAt = now,
        lastTick = clock(),
        durationSeconds = 0,
        insideSeconds = 0,
        inside = true,
        levelAtEntry = xp.level or number(character.level),
        levelAtExit = xp.level or number(character.level),
        group = { sizeAtEntry = readGroupSize(), maxSize = readGroupSize() },
        xp = {
            available = xp.available,
            atCapAtEntry = xp.atCap == true,
            atCap = xp.atCap == true,
            gained = 0,
            levelUps = 0,
            lastLevel = xp.available and xp.level or nil,
            lastCurrent = xp.available and xp.current or nil,
            lastMaximum = xp.available and xp.maximum or nil,
        },
        wallet = { startCopper = readMoney(), netCopper = 0 },
        deaths = 0,
        bosses = { defeated = 0, killed = {}, manualSplits = 0 },
        encounterEvents = Sessions.encounterEventsAvailable == true,
        lootObservations = 0,
        timeline = {},
    }
    run.wallet.available = run.wallet.startCopper ~= nil
    refreshBosses(run)
    addEvent(run, "enter", { name = instance.name })
    return run
end

local function meaningful(run)
    return (run.durationSeconds or 0) >= MIN_KEEP_SECONDS or (run.bosses.defeated or 0) > 0
        or (run.deaths or 0) > 0 or (run.xp.gained or 0) > 0 or (run.lootObservations or 0) > 0
        or (run.bosses.manualSplits or 0) > 0
end

-- The versioned dungeon_run payload. Wallet change is labelled as such: it
-- includes repairs, vendor sales and anything else, so it is not profit.
local function payloadFor(run, status, endReason)
    local xp = run.xp
    local timeline = {}
    for index, entry in ipairs(run.timeline or {}) do
        local copy = {}
        for key, value in pairs(entry) do copy[key] = value end
        timeline[index] = copy
    end
    local bosses = {}
    for _, entry in ipairs(run.timeline or {}) do
        if entry.kind == "boss_kill" then
            table.insert(bosses, { encounterId = entry.encounterId, name = entry.name, at = entry.at, source = entry.source })
        end
    end
    return {
        schemaVersion = SCHEMA_VERSION,
        runId = run.runId,
        sequence = run.sequence,
        status = status,
        endReason = endReason,
        startedAt = run.startedAt,
        endedAt = status ~= "open" and (run.endedAt or run.lastActiveAt) or nil,
        lastActiveAt = run.lastActiveAt,
        durationSeconds = math.floor((run.durationSeconds or 0) + 0.5),
        insideSeconds = math.floor((run.insideSeconds or 0) + 0.5),
        instance = run.instance,
        character = {
            levelAtEntry = run.levelAtEntry,
            levelAtExit = run.levelAtExit,
            classToken = run.identity.classToken,
        },
        group = { sizeAtEntry = run.group.sizeAtEntry, maxSize = run.group.maxSize },
        xp = {
            available = xp.available == true,
            atLevelCap = xp.atCapAtEntry == true,
            gained = xp.available and not xp.atCapAtEntry and xp.gained or nil,
            levelUps = xp.levelUps,
            partial = xp.partial == true or nil,
        },
        wallet = {
            basis = "wallet_delta",
            available = run.wallet.available == true,
            netCopper = run.wallet.available and run.wallet.netCopper or nil,
        },
        deaths = run.deaths,
        bosses = {
            defeated = run.bosses.defeated,
            total = run.bosses.total,
            manualSplits = run.bosses.manualSplits,
            encounterEvents = run.encounterEvents == true,
            list = bosses,
        },
        loot = { observations = run.lootObservations },
        timeline = timeline,
        timelineTruncated = run.timelineTruncated == true or nil,
    }
end

local function publish(run, status, endReason)
    if not run or not GW.TelemetryEnvelope or not GW.Store then
        return nil
    end
    run.sequence = (run.sequence or 0) + 1
    local payload = payloadFor(run, status, endReason)
    local envelope = GW.TelemetryEnvelope.Build("dungeon_run", payload, {
        capturedAt = serverNow(),
        characterId = run.characterId,
        realm = run.identity.realm,
        region = run.identity.region,
        gameBuild = run.identity.gameBuild,
    })
    if not envelope then
        return nil
    end
    GW.Store.SetTelemetryEvent("dungeon_run:" .. tostring(run.characterId) .. ":" .. run.runId, envelope)
    run.publishedSequence = run.sequence
    return payload
end

local function remember(dungeon, run, status, endReason)
    local history = dungeon.history
    table.insert(history, 1, {
        runId = run.runId,
        characterId = run.characterId,
        name = run.instance and run.instance.name,
        status = status,
        endReason = endReason,
        startedAt = run.startedAt,
        durationSeconds = math.floor((run.durationSeconds or 0) + 0.5),
        xpGained = run.xp.available and not run.xp.atCapAtEntry and run.xp.gained or nil,
        netCopper = run.wallet.available and run.wallet.netCopper or nil,
        deaths = run.deaths,
        bossesDefeated = run.bosses.defeated,
    })
    while #history > MAX_HISTORY do
        table.remove(history)
    end
end

local function refreshUi()
    local hud = GW.DungeonHud
    if hud and hud.Refresh then
        pcall(hud.Refresh, hud)
    end
    local main = GW.MainFrame
    if main and main.RefreshDungeon then
        pcall(main.RefreshDungeon, main)
    end
end

-- Ends a run. status: completed, interrupted or abandoned. Runs with nothing
-- in them are dropped rather than sent.
local function finish(characterId, status, endReason, options)
    local dungeon = store()
    local run = dungeon and dungeon.active[characterId]
    if not run then
        return nil
    end
    options = options or {}
    if not options.stale then
        accountTime(run)
    end
    if options.atLeave and run.leftDurationSeconds then
        run.durationSeconds = run.leftDurationSeconds
        run.endedAt = run.leftAt
    end
    run.endedAt = run.endedAt or run.lastActiveAt or serverNow()
    dungeon.active[characterId] = nil
    local payload = nil
    if meaningful(run) then
        payload = publish(run, status, endReason)
        remember(dungeon, run, status, endReason)
    end
    refreshUi()
    return payload
end

local function statusWhenLeft(run)
    return bossesDone(run) and "completed" or "abandoned"
end

local function boundActive(dungeon)
    local count = 0
    local oldestId, oldestAt = nil, nil
    for id, run in pairs(dungeon.active) do
        count = count + 1
        local at = tonumber(run.lastActiveAt) or 0
        if not oldestAt or at < oldestAt then
            oldestId, oldestAt = id, at
        end
    end
    if count > MAX_ACTIVE and oldestId then
        finish(oldestId, "interrupted", "too_many_open_runs", { stale = true })
    end
end

-- Ends runs (any character) left open longer than the re-entry window: a
-- run abandoned outside, or one whose character logged out and did not
-- come back. Their end time is when they were last active, not now.
local function sweepStale(exceptId)
    local dungeon = store()
    if not dungeon then
        return
    end
    local now = serverNow()
    local ids = {}
    for id in pairs(dungeon.active) do
        table.insert(ids, id)
    end
    for _, id in ipairs(ids) do
        local run = dungeon.active[id]
        if id ~= exceptId and run then
            if run.suspended and now - (tonumber(run.lastActiveAt) or 0) > REENTRY_SECONDS then
                local reason = run.inside and "logout_not_resumed" or "left_instance"
                local status = run.inside and "interrupted" or statusWhenLeft(run)
                finish(id, status, reason, { stale = true, atLeave = not run.inside })
            end
        end
    end
end

-- Event handling ----------------------------------------------------------------

local sweepScheduled = false

local function scheduleSweep()
    if sweepScheduled or not Globals.C_Timer or type(Globals.C_Timer.After) ~= "function" then
        return
    end
    sweepScheduled = true
    Globals.C_Timer.After(SWEEP_SECONDS, function()
        sweepScheduled = false
        local run = currentRun()
        if run and not run.inside then
            accountTime(run)
            if serverNow() - (tonumber(run.leftAt) or serverNow()) > REENTRY_SECONDS then
                finish(run.characterId, statusWhenLeft(run), "left_instance", { atLeave = true })
            else
                scheduleSweep()
            end
        end
    end)
end

local function leave(run)
    if not run.inside then
        -- Already outside (after a /reload or login): end it once the
        -- re-entry window is over, otherwise keep watching.
        accountTime(run)
        if serverNow() - (tonumber(run.leftAt) or serverNow()) > REENTRY_SECONDS then
            finish(run.characterId, statusWhenLeft(run), "left_instance", { atLeave = true })
        else
            scheduleSweep()
        end
        return
    end
    accountTime(run)
    run.inside = false
    run.leftAt = serverNow()
    run.leftDurationSeconds = run.durationSeconds
    addEvent(run, "leave")
    if bossesDone(run) then
        finish(run.characterId, "completed", "all_bosses_defeated", { atLeave = true })
        return
    end
    scheduleSweep()
end

-- Works out where the player is and starts, continues or ends runs.
function Sessions.Evaluate(reason)
    local character = snapshot()
    local dungeon = store()
    if not character or not dungeon then
        return false
    end
    local characterId = character.characterId
    local run = dungeon.active[characterId]
    -- A run resumed after logout must not count the offline gap.
    if run and run.suspended then
        if serverNow() - (tonumber(run.lastActiveAt) or 0) > REENTRY_SECONDS then
            local status = run.inside and "interrupted" or statusWhenLeft(run)
            finish(characterId, status, run.inside and "logout_not_resumed" or "left_instance",
                { stale = true, atLeave = not run.inside })
            run = nil
        else
            run.suspended = nil
            run.lastTick = clock()
            addEvent(run, "resume", { reason = reason })
        end
    end
    sweepStale(characterId)

    local instance = readInstance()
    if instance then
        if run and not sameInstance(run.instance, instance) then
            accountTime(run)
            local status = run.inside and "abandoned" or statusWhenLeft(run)
            finish(characterId, status, "entered_other_instance", { atLeave = not run.inside })
            run = nil
        end
        if run then
            if not run.inside then
                accountTime(run)
                run.inside = true
                run.leftAt, run.leftDurationSeconds = nil, nil
                addEvent(run, "reenter")
            end
            -- Fill in what a loading screen may have hidden at entry.
            for key, value in pairs(instance) do
                if run.instance[key] == nil then run.instance[key] = value end
            end
        else
            run = newRun(character, instance)
            dungeon.active[characterId] = run
            boundActive(dungeon)
        end
    elseif run then
        leave(run)
    end
    refreshUi()
    return true
end

local function withRun(handler)
    return function(...)
        local run = currentRun()
        if run and not run.suspended then
            accountTime(run)
            handler(run, ...)
        end
    end
end

local function encounterId(value)
    local id = number(value)
    return id and id > 0 and math.floor(id) or nil
end

local function recordKill(run, id, name, source)
    if id and run.bosses.killed[tostring(id)] then
        return false
    end
    if id then
        run.bosses.killed[tostring(id)] = true
    end
    run.bosses.defeated = run.bosses.defeated + 1
    addEvent(run, "boss_kill", { encounterId = id, name = text(name), source = source })
    refreshBosses(run)
    return true
end

local handlers = {
    PLAYER_XP_UPDATE = withRun(function(run, unit)
        if unit == nil or unit == "player" then sampleXp(run) end
    end),
    PLAYER_LEVEL_UP = withRun(function(run, level)
        sampleXp(run, number(level))
    end),
    PLAYER_MONEY = withRun(sampleMoney),
    PLAYER_DEAD = withRun(function(run)
        -- One character's death, never a party wipe.
        run.deaths = run.deaths + 1
        addEvent(run, "death")
    end),
    GROUP_ROSTER_UPDATE = withRun(function(run)
        local size = readGroupSize()
        if size and size > (run.group.maxSize or 0) then
            run.group.maxSize = size
        end
    end),
    ENCOUNTER_START = withRun(function(run, id, name)
        Sessions.encounterEventsAvailable = true
        run.encounterEvents = true
        addEvent(run, "encounter_start", { encounterId = encounterId(id), name = text(name) })
    end),
    ENCOUNTER_END = withRun(function(run, id, name, _, _, success)
        Sessions.encounterEventsAvailable = true
        run.encounterEvents = true
        success = scalar(success)
        if success == 1 or success == true then
            recordKill(run, encounterId(id), name, "encounter_end")
        elseif success == 0 or success == false then
            -- The encounter reset (the group wiped or left it).
            addEvent(run, "encounter_failed", { encounterId = encounterId(id), name = text(name) })
        end
    end),
    BOSS_KILL = withRun(function(run, id, name)
        Sessions.encounterEventsAvailable = true
        run.encounterEvents = true
        recordKill(run, encounterId(id), name, "boss_kill")
    end),
}

local function onEvent(_, event, ...)
    if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        -- After the loading screen, and once character data is in.
        local attempts = 0
        local function try()
            attempts = attempts + 1
            if not Sessions.Evaluate(event) and attempts < 5 and Globals.C_Timer and Globals.C_Timer.After then
                Globals.C_Timer.After(2, try)
            end
        end
        if Globals.C_Timer and type(Globals.C_Timer.After) == "function" then
            Globals.C_Timer.After(1, try)
        else
            try()
        end
        return
    end
    if event == "PLAYER_LOGOUT" then
        Sessions.Suspend()
        return
    end
    local handler = handlers[event]
    if handler then
        local perf = GW.Perf
        local started = perf and perf.Begin and perf.Begin() or nil
        handler(...)
        if perf and perf.End then perf.End("dungeon_event", started) end
        refreshUi()
    end
end

-- Logout and /reload: the game is about to write SavedVariables, so this is
-- when an open run is queued for the website. The run stays open and
-- continues on the next login in the same instance.
function Sessions.Suspend()
    local dungeon = store()
    if not dungeon then
        return
    end
    for id, run in pairs(dungeon.active) do
        if not run.suspended then
            accountTime(run)
            if not run.inside and serverNow() - (tonumber(run.leftAt) or 0) > REENTRY_SECONDS then
                finish(id, statusWhenLeft(run), "left_instance", { atLeave = true })
            else
                run.suspended = true
                if meaningful(run) then
                    publish(run, "open", nil)
                end
            end
        end
    end
end

-- Public API ---------------------------------------------------------------------

-- The open run's id while inside its instance, for loot observations.
function Sessions.Context()
    local run = currentRun()
    if run and run.inside and not run.suspended then
        return { runId = run.runId }
    end
    return nil
end

function Sessions.NoteLoot()
    local run = currentRun()
    if run and run.inside then
        run.lootObservations = (run.lootObservations or 0) + 1
    end
end

-- A manual split, for bosses the client does not report and for the
-- player's own checkpoints.
function Sessions.Split(label)
    local run = currentRun()
    if not run or run.suspended then
        return nil
    end
    accountTime(run)
    run.bosses.manualSplits = (run.bosses.manualSplits or 0) + 1
    local entry = addEvent(run, "manual_split", { name = text(label, 60) or ("Split " .. run.bosses.manualSplits) })
    refreshUi()
    return entry
end

-- Ends the current run as completed.
function Sessions.Finish()
    local character = snapshot()
    if not character or not activeRun(character.characterId) then
        return nil
    end
    return finish(character.characterId, "completed", "manual_finish")
end

-- What the HUD and the window show.
function Sessions.Current()
    local run = currentRun()
    if not run then
        return nil
    end
    accountTime(run)
    local xp = run.xp
    local xpGained = xp.available and not xp.atCapAtEntry and xp.gained or nil
    local hours = (run.durationSeconds or 0) / 3600
    local splits = {}
    for _, entry in ipairs(run.timeline or {}) do
        if entry.kind == "boss_kill" or entry.kind == "manual_split" then
            table.insert(splits, { at = entry.at, name = entry.name or (entry.kind == "boss_kill" and "Boss" or "Split"),
                kind = entry.kind })
        end
    end
    return {
        runId = run.runId,
        name = run.instance and run.instance.name or "Instance",
        difficultyName = run.instance and run.instance.difficultyName,
        inside = run.inside == true,
        durationSeconds = run.durationSeconds or 0,
        xpGained = xpGained,
        atLevelCap = xp.atCapAtEntry == true or xp.atCap == true,
        xpPerHour = xpGained and hours >= (5 / 60) and math.floor(xpGained / hours) or nil,
        netCopper = run.wallet.available and run.wallet.netCopper or nil,
        deaths = run.deaths,
        bossesDefeated = run.bosses.defeated,
        bossesTotal = run.bosses.total,
        encounterEvents = run.encounterEvents == true,
        splits = splits,
    }
end

function Sessions.History()
    local dungeon = store()
    return dungeon and dungeon.history or {}
end

function Sessions:Initialize()
    if self.frame or type(Globals.CreateFrame) ~= "function" then
        return
    end
    local frame = Globals.CreateFrame("Frame")
    -- No combat log events: addons cannot read them on Forever, and they
    -- fire far too often. Encounter events are registered when the client
    -- has them; without them bosses come from manual splits.
    for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "PLAYER_LOGOUT",
        "PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP", "PLAYER_MONEY", "PLAYER_DEAD", "GROUP_ROSTER_UPDATE" }) do
        pcall(frame.RegisterEvent, frame, event)
    end
    local encounters = 0
    for _, event in ipairs({ "ENCOUNTER_START", "ENCOUNTER_END", "BOSS_KILL" }) do
        local ok, registered = pcall(frame.RegisterEvent, frame, event)
        if ok and registered ~= false then
            encounters = encounters + 1
        end
    end
    self.encounterEventsRegistered = encounters > 0
    frame:SetScript("OnEvent", onEvent)
    self.frame = frame
end

GW.DungeonSessions:Initialize()
