local _, GW = ...

-- The character's World of Warcraft quest state: which quests the client
-- says are completed and which are in the quest log. Not Systems/Quests.lua,
-- which is Guildweaver's own guild quest assignments.
--
-- It feeds two things:
--   * the Dungeon Journal's readiness (GW.DungeonReadiness reads State());
--   * the quest_state telemetry stream (docs: Holdfast
--     docs/dungeon-quest-readiness.md), one state per character, published
--     only when its content changes.
--
-- Client APIs are feature-detected; none is assumed to exist on the WoW
-- Forever client:
--   completed, whole list:  C_QuestLog.GetAllCompletedQuestIDs, else GetQuestsCompleted
--   completed, per quest:   C_QuestLog.IsQuestFlaggedCompleted, else IsQuestFlaggedCompleted
--   quest log:              C_QuestLog.GetNumQuestLogEntries + C_QuestLog.GetInfo
--                           (+ C_QuestLog.IsComplete), else GetNumQuestLogEntries +
--                           GetQuestLogTitle
-- Coverage is never claimed beyond what was read:
--   completed "full" only from a whole list that came back with ids (an empty
--   list may be one the client has not loaded yet); else "checked" with
--   exactly the ids asked (the quest catalog's); else "none".
--   questLog "full" only after the log has loaded (a QUEST_LOG_UPDATE was
--   seen) and every entry was read with its quest id and no header was
--   collapsed (a collapsed header hides its quests); else "none".
-- Only quest ids, coverage and the character's faction, race, class and
-- level are kept or sent: no titles, no text.
--
-- Costs: nothing per frame. Quest events mark what changed and one capture
-- runs DEBOUNCE seconds later, never in combat (it waits for the end of the
-- fight). The quest log is re-read on its own updates; the completed list
-- only on login, turn-ins and removals.

GW.CharacterQuests = GW.CharacterQuests or {}

local CQ = GW.CharacterQuests
local Globals = _G or {}

CQ.EVENT_TYPE = "quest_state"
CQ.DEBOUNCE = 2
CQ.MAX_LOG_ENTRIES = 100
CQ.MAX_COMPLETED = 20000
CQ.RETRY = 10
-- After entering the world, how long to wait for the quest log to load
-- before publishing without it (so a reload does not publish a "none" log
-- and then the full one).
CQ.LOG_WAIT = 30

local session = {
    logReady = false,
    dirtyCompleted = true,
    dirtyLog = true,
    pending = false,
    afterCombat = false,
    state = nil,
    completed = nil, -- { coverage, ids, checked, api, count, fingerprint }
    log = nil, -- { coverage, entries, ids, api, reason, fingerprint }
    turnedIn = {},
    lastCapture = nil,
    lastPublish = nil,
    captures = 0,
}

local function clock()
    local ok, value = pcall(Globals.GetTime or function() return 0 end)
    return ok and tonumber(value) or 0
end

local function now()
    local ok, value = pcall(Globals.GetServerTime or Globals.time or function() return 0 end)
    return ok and tonumber(value) or 0
end

local function call(fn, ...)
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end

local function inCombat()
    local queue = GW.WorkQueue
    if queue and type(queue.InCombat) == "function" then return queue.InCombat() == true end
    local ok, value = call(Globals.InCombatLockdown)
    return ok and value == true
end

local function questId(value)
    value = tonumber(value)
    if value and value > 0 and value == math.floor(value) then return value end
    return nil
end

local function sortedIds(set)
    local list = {}
    for id in pairs(set) do table.insert(list, id) end
    table.sort(list)
    return list
end

local function fingerprint(value)
    local store = GW.Store
    if store and type(store.Fingerprint) == "function" then return store.Fingerprint(value) end
    return nil
end

-- Completed quests ---------------------------------------------------------------------

-- The client's whole completed list, as a set. Nil when no whole-list API
-- answers, or it answers with nothing (never a "full" empty list).
local function wholeCompletedList()
    local log = Globals.C_QuestLog
    local fn, api
    if type(log) == "table" and type(log.GetAllCompletedQuestIDs) == "function" then
        fn, api = log.GetAllCompletedQuestIDs, "C_QuestLog.GetAllCompletedQuestIDs"
    elseif type(Globals.GetQuestsCompleted) == "function" then
        fn, api = Globals.GetQuestsCompleted, "GetQuestsCompleted"
    end
    if not fn then return nil end
    local ok, value = pcall(fn)
    if not ok or type(value) ~= "table" then return nil, api end
    local ids, count = {}, 0
    -- An array of ids (C_QuestLog) or a set keyed by id (GetQuestsCompleted).
    for key, entry in pairs(value) do
        local id = (entry == true and questId(key)) or (type(entry) == "number" and questId(entry)) or nil
        if id and not ids[id] then
            ids[id] = true
            count = count + 1
        end
    end
    if count == 0 or count > CQ.MAX_COMPLETED then return nil, api end
    return ids, api, count
end

local function perQuestCheck()
    local log = Globals.C_QuestLog
    if type(log) == "table" and type(log.IsQuestFlaggedCompleted) == "function" then return log.IsQuestFlaggedCompleted, "C_QuestLog.IsQuestFlaggedCompleted" end
    if type(Globals.IsQuestFlaggedCompleted) == "function" then return Globals.IsQuestFlaggedCompleted, "IsQuestFlaggedCompleted" end
    return nil
end

local function readCompleted()
    local ids, api, count = wholeCompletedList()
    if ids then return { coverage = "full", ids = ids, checked = {}, api = api, count = count } end
    local check, checkApi = perQuestCheck()
    local readiness = GW.DungeonReadiness
    local wanted = check and readiness and type(readiness.AllQuestIds) == "function" and readiness.AllQuestIds() or {}
    if check and #wanted > 0 then
        local done, asked, doneCount = {}, {}, 0
        for _, id in ipairs(wanted) do
            local ok, value = pcall(check, id)
            -- Only a yes or a no counts as asked.
            if ok and (value == true or value == false) then
                asked[id] = true
                if value then
                    done[id] = true
                    doneCount = doneCount + 1
                end
            end
        end
        if next(asked) then return { coverage = "checked", ids = done, checked = asked, api = checkApi, count = doneCount } end
    end
    return { coverage = "none", ids = {}, checked = {}, api = api or checkApi, count = 0 }
end

-- The quest log -------------------------------------------------------------------------

local function scanModernLog(log)
    local ok, total = pcall(log.GetNumQuestLogEntries)
    total = ok and tonumber(total) or nil
    if not total then return nil, "unreadable" end
    if total > CQ.MAX_LOG_ENTRIES * 2 then return nil, "too-many" end
    local entries = {}
    for index = 1, total do
        local okInfo, info = pcall(log.GetInfo, index)
        if not okInfo or type(info) ~= "table" then return nil, "unreadable" end
        if info.isHeader then
            if info.isCollapsed then return nil, "collapsed" end
        else
            local id = questId(info.questID)
            if not id then return nil, "unreadable" end
            local complete = nil
            if type(log.IsComplete) == "function" then
                local okComplete, value = pcall(log.IsComplete, id)
                if okComplete and (value == true or value == false) then complete = value end
            end
            table.insert(entries, { questId = id, isComplete = complete })
        end
    end
    return entries
end

local function scanClassicLog()
    local ok, total = pcall(Globals.GetNumQuestLogEntries)
    total = ok and tonumber(total) or nil
    if not total then return nil, "unreadable" end
    if total > CQ.MAX_LOG_ENTRIES * 2 then return nil, "too-many" end
    local entries = {}
    for index = 1, total do
        local okTitle, _, _, _, isHeader, isCollapsed, isComplete, _, id = pcall(Globals.GetQuestLogTitle, index)
        if not okTitle then return nil, "unreadable" end
        if isHeader then
            if isCollapsed then return nil, "collapsed" end
        else
            id = questId(id)
            if not id then return nil, "unreadable" end
            -- 1 complete, -1 failed, nil not yet.
            table.insert(entries, { questId = id, isComplete = isComplete == 1 or isComplete == true })
        end
    end
    return entries
end

local function readLog()
    if not session.logReady then return { coverage = "none", entries = {}, ids = {}, reason = "loading" } end
    local log = Globals.C_QuestLog
    local entries, reason, api
    if type(log) == "table" and type(log.GetNumQuestLogEntries) == "function" and type(log.GetInfo) == "function" then
        api = "C_QuestLog.GetInfo"
        entries, reason = scanModernLog(log)
    elseif type(Globals.GetNumQuestLogEntries) == "function" and type(Globals.GetQuestLogTitle) == "function" then
        api = "GetQuestLogTitle"
        entries, reason = scanClassicLog()
    else
        reason = "no-api"
    end
    if entries and #entries > CQ.MAX_LOG_ENTRIES then entries, reason = nil, "too-many" end
    if not entries then return { coverage = "none", entries = {}, ids = {}, reason = reason, api = api } end
    local ids, unique = {}, {}
    for _, entry in ipairs(entries) do
        if not ids[entry.questId] then
            ids[entry.questId] = true
            table.insert(unique, entry)
        end
    end
    table.sort(unique, function(a, b) return a.questId < b.questId end)
    return { coverage = "full", entries = unique, ids = ids, api = api }
end

-- The character -------------------------------------------------------------------------

local function character()
    local okFaction, faction = call(Globals.UnitFactionGroup, "player")
    -- UnitRace and UnitClass: the client's tokens ("NightElf", "WARRIOR").
    local okRace, _, race = call(Globals.UnitRace, "player")
    local okClass, _, classToken = call(Globals.UnitClass, "player")
    local okLevel, level = call(Globals.UnitLevel, "player")
    level = okLevel and tonumber(level) or nil
    return {
        faction = okFaction and (faction == "Alliance" and "alliance" or (faction == "Horde" and "horde")) or nil,
        race = okRace and type(race) == "string" and string.find(race, "^%a+$") and race or nil,
        classToken = okClass and type(classToken) == "string" and string.find(classToken, "^%u+$") and classToken or nil,
        level = level and level >= 1 and level <= 100 and math.floor(level) or nil,
    }
end

-- Capture -------------------------------------------------------------------------------

-- Turn-ins the client announced this session: completed, whatever the list
-- says yet (the completed list may lag the event).
local function withTurnIns(completed)
    if completed.coverage == "none" then return completed end
    for id in pairs(session.turnedIn) do
        if not completed.ids[id] then
            completed.ids[id] = true
            completed.count = (completed.count or 0) + 1
            if completed.coverage == "checked" then completed.checked[id] = true end
            completed.fingerprint = nil
        end
    end
    return completed
end

local function buildState()
    local who = character()
    local completed, log = session.completed, session.log
    session.state = {
        faction = who.faction, race = who.race, classToken = who.classToken, level = who.level,
        completed = { coverage = completed.coverage, ids = completed.ids, checked = completed.checked },
        questLog = { coverage = log.coverage, ids = log.ids },
        capturedAt = now(),
    }
    return session.state, who
end

-- The quest_state payload (docs/dungeon-quest-readiness.md, schema 1),
-- without capturedAt: its fingerprint is the content's.
local function payloadOf(who)
    local completed, log = session.completed, session.log
    local payload = {
        faction = who.faction, race = who.race, classToken = who.classToken, level = who.level,
        completed = { coverage = completed.coverage, questIds = sortedIds(completed.ids) },
        questLog = { coverage = log.coverage, entries = {} },
    }
    if completed.coverage == "checked" then payload.completed.checkedQuestIds = sortedIds(completed.checked) end
    if log.coverage == "full" then
        for _, entry in ipairs(log.entries) do table.insert(payload.questLog.entries, { questId = entry.questId, isComplete = entry.isComplete }) end
    end
    return payload
end

-- The payload and its content fingerprint. The completed list is
-- fingerprinted once per read, the rest each time.
local function content(who)
    local payload = payloadOf(who)
    if not session.completed.fingerprint then session.completed.fingerprint = fingerprint(payload.completed) end
    return payload, fingerprint({ session.completed.fingerprint, payload.questLog, who.faction, who.race, who.classToken, who.level })
end

local function publish(payload, contentFingerprint)
    local domain = GW.TelemetryDomains and GW.TelemetryDomains.QuestState
    local characterApi = GW.Character
    local snapshot = characterApi and type(characterApi.GetCurrentSnapshot) == "function" and characterApi.GetCurrentSnapshot() or nil
    if not domain or type(snapshot) ~= "table" or not snapshot.characterId or not contentFingerprint then return nil end
    payload.capturedAt = now()
    local result = domain.PublishPrepared({
        characterId = snapshot.characterId, realm = snapshot.realm, region = snapshot.region, gameBuild = snapshot.gameBuild,
        capturedAt = payload.capturedAt,
    }, payload, contentFingerprint)
    session.lastPublish = { at = payload.capturedAt, changed = result and result.changed == true, streamKey = result and result.streamKey,
        revision = result and result.revision }
    return result
end

-- Reads what changed and publishes when the content differs. Never in
-- combat. reason: what asked (for tests and /gw dungeon quests); reread:
-- read the client again even if no event said something changed.
function CQ.Capture(reason, reread)
    if reread then session.dirtyCompleted, session.dirtyLog = true, true end
    if inCombat() then
        session.afterCombat = true
        return nil
    end
    if session.dirtyCompleted or not session.completed then
        session.completed = readCompleted()
        session.dirtyCompleted = false
    end
    if session.dirtyLog or not session.log then
        session.log = readLog()
        session.dirtyLog = false
    end
    withTurnIns(session.completed)
    local _, who = buildState()
    session.captures = session.captures + 1
    session.lastCapture = { at = now(), reason = reason }
    local payload, contentFingerprint = content(who)
    if contentFingerprint ~= session.contentFingerprint then
        session.contentFingerprint = contentFingerprint
        -- An open journal shows the new state.
        local guideUI = GW.DungeonGuideUI
        if guideUI and type(guideUI.Refresh) == "function" then pcall(guideUI.Refresh) end
    end
    -- The log has not loaded yet: wait for it (QUEST_LOG_UPDATE), or publish
    -- without it once LOG_WAIT has passed.
    if session.log.reason == "loading" and session.enteredAt and clock() - session.enteredAt < CQ.LOG_WAIT then
        local timer = Globals.C_Timer
        if timer and type(timer.After) == "function" and not session.waiting then
            session.waiting = true
            timer.After(CQ.LOG_WAIT, function()
                session.waiting = false
                CQ.Request("log-wait", "log")
            end)
        end
        return nil
    end
    local result = publish(payload, contentFingerprint)
    if not result then
        -- No character snapshot yet (it is captured at login): try once more later.
        local timer = Globals.C_Timer
        if timer and type(timer.After) == "function" and not session.retrying then
            session.retrying = true
            timer.After(CQ.RETRY, function()
                session.retrying = false
                CQ.Request("retry")
            end)
        end
    end
    return result
end

local function run()
    session.pending = false
    CQ.Capture(session.reason or "event")
    session.reason = nil
end

-- Marks a capture wanted; one runs DEBOUNCE seconds after the last request
-- (out of combat).
function CQ.Request(reason, what)
    if what == "completed" or what == "all" then session.dirtyCompleted = true end
    if what == "log" or what == "all" then session.dirtyLog = true end
    session.reason = reason
    if session.pending then return end
    if inCombat() then
        session.afterCombat = true
        return
    end
    local timer = Globals.C_Timer
    if not timer or type(timer.After) ~= "function" then return end
    session.pending = true
    timer.After(CQ.DEBOUNCE, run)
end

-- The current character's state for the readiness rules (cached; read now
-- when nothing was read yet and it is safe to).
function CQ.State()
    if session.state then return session.state end
    if not inCombat() and (session.completed == nil or session.log == nil) then
        session.completed = session.completed or readCompleted()
        session.dirtyCompleted = false
        session.log = session.log or readLog()
        session.dirtyLog = false
        withTurnIns(session.completed)
        buildState()
    end
    return session.state
end

-- What /gw dungeon quests prints.
function CQ.Report()
    local lines = {}
    local completed, log = session.completed, session.log
    if not completed then
        table.insert(lines, "Quest state not read yet.")
    else
        table.insert(lines, string.format("Completed quests: %s (%s), %d known completed.", completed.coverage, tostring(completed.api or "no client API"),
            completed.count or 0))
        local logText = log.coverage == "full" and string.format("%d quests read", #log.entries)
            or ("not read: " .. tostring(log.reason or "?") .. (log.reason == "collapsed" and " (expand every quest log header)" or ""))
        table.insert(lines, string.format("Quest log: %s (%s), %s.", log.coverage, tostring(log.api or "no client API"), logText))
    end
    local last = session.lastPublish
    table.insert(lines, last and string.format("Last quest_state: %s, revision %s.", last.changed and "new" or "unchanged", tostring(last.revision or "?"))
        or "No quest_state saved this session yet.")
    table.insert(lines, "It reaches the website after the game writes SavedVariables (/reload or logout) and the bridge syncs.")
    return lines
end

-- For tests.
function CQ.Debug()
    return session
end

local EVENTS = {
    PLAYER_ENTERING_WORLD = "all",
    QUEST_ACCEPTED = "log",
    QUEST_REMOVED = "all",
    QUEST_TURNED_IN = "all",
    QUEST_LOG_UPDATE = "log",
    PLAYER_LEVEL_UP = "none",
    PLAYER_REGEN_ENABLED = nil,
    PLAYER_LOGOUT = nil,
}

function CQ.Initialize()
    if session.frame or type(Globals.CreateFrame) ~= "function" then return end
    local frame = Globals.CreateFrame("Frame")
    session.frame = frame
    for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN", "QUEST_LOG_UPDATE",
        "PLAYER_LEVEL_UP", "PLAYER_REGEN_ENABLED", "PLAYER_LOGOUT" }) do
        -- An event this client does not have is skipped.
        pcall(frame.RegisterEvent, frame, event)
    end
    frame:SetScript("OnEvent", function(_, event, first)
        if event == "QUEST_LOG_UPDATE" then session.logReady = true end
        if event == "PLAYER_ENTERING_WORLD" and not session.enteredAt then session.enteredAt = clock() end
        if event == "QUEST_TURNED_IN" then
            local id = questId(first)
            if id then session.turnedIn[id] = true end
        end
        if event == "PLAYER_REGEN_ENABLED" then
            if session.afterCombat then
                session.afterCombat = false
                CQ.Request("after-combat")
            end
            return
        end
        if event == "PLAYER_LOGOUT" then
            -- Timers never fire during teardown: a pending capture runs now.
            if session.pending then
                session.pending = false
                CQ.Capture("logout")
            end
            return
        end
        CQ.Request(event, EVENTS[event])
    end)
end
