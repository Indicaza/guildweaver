-- The character's World of Warcraft quest state (Systems/CharacterQuests.lua)
-- and its quest_state telemetry (Telemetry/Domains/QuestState.lua), with the
-- Dungeon Journal's readiness shown from it.
--
-- The client below is made up: these tests prove the addon's logic (feature
-- detection, coverage, debouncing, combat, publishing, isolation), not
-- which APIs the WoW Forever client actually has. /gw dungeon quests reports
-- that in game (docs/dungeon-guide.md, in-game checklist).

local Env = dofile("test/support/wow_env.lua")

local function equal(actual, expected, label)
    if actual ~= expected then error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2) end
end

local function truthy(value, label)
    if not value then error((label or "value") .. ": expected truthy value", 2) end
end

local function falsy(value, label)
    if value then error((label or "value") .. ": expected falsy value, got " .. tostring(value), 2) end
end

local function contains(text, part, label)
    if not string.find(tostring(text), part, 1, true) then error((label or "text") .. ": " .. tostring(text) .. " lacks " .. part, 2) end
end

-- The made-up client ---------------------------------------------------------------------
-- world.whole: "modern" (C_QuestLog.GetAllCompletedQuestIDs), "classic"
-- (GetQuestsCompleted) or nil; world.check: per-quest checks; world.logApi:
-- "modern", "classic" or nil; world.log: entries ({ header, collapsed } or
-- { id, complete }); world.completed: ids.
local world
local calls = {}
local function count(name) calls[name] = (calls[name] or 0) + 1 end

local function installClient()
    local modern = {}
    if world.whole == "modern" then
        modern.GetAllCompletedQuestIDs = function()
            count("GetAllCompletedQuestIDs")
            local copy = {}
            for index, id in ipairs(world.completed) do copy[index] = id end
            return copy
        end
    end
    if world.check then
        modern.IsQuestFlaggedCompleted = function(id)
            count("IsQuestFlaggedCompleted")
            for _, done in ipairs(world.completed) do if done == id then return true end end
            return false
        end
    end
    if world.logApi == "modern" then
        modern.GetNumQuestLogEntries = function() count("GetNumQuestLogEntries"); return #world.log, #world.log end
        modern.GetInfo = function(index)
            local entry = world.log[index]
            if not entry then return nil end
            if entry.header then return { title = "Westfall", isHeader = true, isCollapsed = entry.collapsed == true } end
            return { title = "A title that must never be sent", questID = entry.id, isHeader = false }
        end
        modern.IsComplete = function(id)
            for _, entry in ipairs(world.log) do if entry.id == id then return entry.complete == true end end
            return false
        end
    end
    _G.C_QuestLog = next(modern) and modern or nil
    _G.GetQuestsCompleted = world.whole == "classic" and function()
        count("GetQuestsCompleted")
        local set = {}
        for _, id in ipairs(world.completed) do set[id] = true end
        return set
    end or nil
    if world.logApi == "classic" then
        _G.GetNumQuestLogEntries = function() return #world.log, #world.log end
        _G.GetQuestLogTitle = function(index)
            local entry = world.log[index]
            if entry.header then return "Westfall", nil, nil, true, entry.collapsed == true end
            return "A title", 20, nil, false, false, entry.complete and 1 or nil, nil, entry.id
        end
    else
        _G.GetNumQuestLogEntries, _G.GetQuestLogTitle = nil, nil
    end
    _G.UnitFactionGroup = function() return world.faction or "Alliance", world.faction or "Alliance" end
end

local function boot(options, db)
    world = { whole = "modern", check = true, logApi = "modern", completed = { 65, 132, 135, 141, 142, 155, 167 },
        log = { { header = true }, { id = 168 }, { id = 2040, complete = true } } }
    for key, value in pairs(options or {}) do world[key] = value end
    calls = {}
    local env = Env.new()
    local addon = env:load()
    installClient()
    if db then GuildweaverDB = db end
    env:login()
    env:advance(3)
    return env, addon
end

local function stream(env)
    local record, key = env:stream("quest_state:")
    return record, key
end

local function logLoaded(env)
    env:dispatch("QUEST_LOG_UPDATE")
    env:advance(3)
end

local function ids(list)
    local out = {}
    for _, value in ipairs(list or {}) do table.insert(out, type(value) == "table" and value.questId or value) end
    return table.concat(out, ",")
end

-- 1. Login: whole completed list; nothing is published until the log has loaded ---------------
do
    local env, addon = boot()
    equal(stream(env), nil, "the log has not loaded: nothing published yet")
    equal(addon.CharacterQuests.State().questLog.coverage, "none", "the journal does not claim the log either")
    logLoaded(env)
    local record, key = stream(env)
    truthy(record, "a quest_state record after login")
    local snapshot = addon.Character.GetCurrentSnapshot()
    equal(key, "quest_state:" .. snapshot.characterId, "one stream per character, exactly as Holdfast checks it")
    local envelope = record.envelope
    equal(envelope.eventType, "quest_state")
    equal(envelope.schemaVersion, 1)
    equal(envelope.payloadSchemaVersion, 1)
    equal(envelope.characterId, snapshot.characterId)
    equal(envelope.realm, "Live Realm")
    equal(envelope.region, "US")
    truthy(envelope.gameBuild, "the client build")
    equal(record.kind, "state")
    local payload = envelope.payload
    equal(payload.schemaVersion, 1)
    equal(payload.faction, "alliance")
    equal(payload.race, "NightElf", "the client's race token")
    equal(payload.classToken, "WARRIOR")
    equal(payload.level, 30)
    truthy(type(payload.capturedAt) == "number", "capturedAt")
    equal(payload.completed.coverage, "full", "the whole list was read")
    equal(ids(payload.completed.questIds), "65,132,135,141,142,155,167", "sorted ids")
    equal(payload.completed.checkedQuestIds, nil, "full is not checked")
    equal(payload.questLog.coverage, "full")
    equal(ids(payload.questLog.entries), "168,2040")
    equal(payload.questLog.entries[2].isComplete, true)
    equal(payload.questLog.entries[1].isComplete, false)
    equal(record.revision, 1, "one record for the login")
    local revision

    -- No names or other text anywhere in the payload.
    local function noText(value, path)
        for field, entry in pairs(value) do
            if type(entry) == "table" then noText(entry, path .. "." .. tostring(field))
            elseif type(entry) == "string" then
                truthy(({ coverage = true, faction = true, race = true, classToken = true })[field], "only tokens are strings: " .. path .. "." .. field)
            end
        end
    end
    noText(payload, "payload")

    -- Readiness from it: Deadmines for this level 30 alliance warrior.
    local result = addon.DungeonReadiness.ForGuide(36)
    local byId = {}
    for _, row in ipairs(result.quests) do byId[row.quest.questId] = row.state end
    equal(byId[167], "completed")
    equal(byId[168], "accepted")
    equal(byId[2040], "accepted")
    equal(byId[166], "available", "the chain is done (155)")
    equal(result.readiness, "missing")

    -- 2. Duplicate and noisy events: one capture, nothing new stored ------------------------
    local captures = addon.CharacterQuests.Debug().captures
    revision = stream(env).revision
    for _ = 1, 50 do env:dispatch("QUEST_LOG_UPDATE") end
    env:advance(1)
    for _ = 1, 50 do env:dispatch("QUEST_LOG_UPDATE") end
    env:advance(3)
    equal(addon.CharacterQuests.Debug().captures, captures + 1, "a burst of updates is one capture")
    equal(stream(env).revision, revision, "unchanged content is not stored again")
    equal(calls.GetAllCompletedQuestIDs, 1, "log updates do not reread the completed list")

    -- 3. Accepting a quest -------------------------------------------------------------------
    table.insert(world.log, { id = 166 })
    env:dispatch("QUEST_ACCEPTED", 4, 166)
    env:advance(3)
    equal(ids(stream(env).envelope.payload.questLog.entries), "166,168,2040")
    equal(stream(env).revision, revision + 1)

    -- 4. Turning one in: completed even before the client's list catches up -----------------
    table.remove(world.log, 3) -- 2040 leaves the log
    env:dispatch("QUEST_TURNED_IN", 2040, 450, 0)
    env:dispatch("QUEST_REMOVED", 2040)
    env:advance(3)
    payload = stream(env).envelope.payload
    contains("," .. ids(payload.completed.questIds) .. ",", ",2040,", "turned in")
    equal(ids(payload.questLog.entries), "166,168")

    -- 5. Abandoning one: out of the log, not completed ----------------------------------------
    table.remove(world.log, 2) -- 168
    env:dispatch("QUEST_REMOVED", 168)
    env:advance(3)
    payload = stream(env).envelope.payload
    equal(ids(payload.questLog.entries), "166")
    falsy(string.find("," .. ids(payload.completed.questIds) .. ",", ",168,", 1, true), "abandoned is not completed")
    equal(addon.DungeonReadiness.ForGuide(36).quests[2].state, "available", "168 can be picked up again")

    -- 6. Combat: nothing is read until it ends ------------------------------------------------
    local before = addon.CharacterQuests.Debug().captures
    env.inCombat = true
    table.insert(world.log, { id = 214 })
    env:dispatch("QUEST_LOG_UPDATE")
    env:advance(5)
    equal(addon.CharacterQuests.Debug().captures, before, "no capture in combat")
    env.inCombat = false
    env:dispatch("PLAYER_REGEN_ENABLED")
    env:advance(3)
    equal(addon.CharacterQuests.Debug().captures, before + 1, "after combat")
    equal(ids(stream(env).envelope.payload.questLog.entries), "166,214")

    -- 7. A collapsed header hides quests: the log is not claimed --------------------------------
    world.log[1].collapsed = true
    env:dispatch("QUEST_LOG_UPDATE")
    env:advance(3)
    payload = stream(env).envelope.payload
    equal(payload.questLog.coverage, "none")
    equal(#payload.questLog.entries, 0)
    contains(table.concat(addon.CharacterQuests.Report(), "\n"), "expand every quest log header")
    world.log[1].collapsed = false

    -- 8. Level-up: the level changes, nothing is reread ------------------------------------------
    local reads = calls.GetAllCompletedQuestIDs
    env.player.level = 31
    env:dispatch("PLAYER_LEVEL_UP", 31)
    env:advance(3)
    equal(stream(env).envelope.payload.level, 31)
    equal(calls.GetAllCompletedQuestIDs, reads)

    -- 9. Performance under frequent quest events: a minute of questing ---------------------------
    local start = addon.CharacterQuests.Debug().captures
    for second = 1, 60 do
        for _ = 1, 10 do env:dispatch("QUEST_LOG_UPDATE") end
        env:advance(1)
        if second % 20 == 0 then env:dispatch("QUEST_TURNED_IN", 9000 + second) end
    end
    env:advance(3)
    local made = addon.CharacterQuests.Debug().captures - start
    truthy(made <= 31, "at most one capture per debounce window, got " .. made)
    truthy(calls.GetAllCompletedQuestIDs - reads <= 4, "the completed list is reread only for turn-ins")

    -- 10. The journal shows it ------------------------------------------------------------------
    addon.CharacterQuests.Capture("test", true)
    local guideUI, main = addon.DungeonGuideUI, addon.MainFrame
    truthy(guideUI.Show(36))
    local page = main.views.dungeon.dungeon
    contains(page.sub.gwText, "Quests to pick up", "the overview says it")
    guideUI.Navigate(guideUI.Pages.dungeon(36, "quests"))
    contains(page.questSummary.gwText, "Quests to pick up")
    contains(page.questSummary.gwText, "required done")
    local heads = {}
    for _, header in ipairs(page.questHeads.items) do if header.shown ~= false then table.insert(heads, header.text.gwText) end end
    contains(table.concat(heads, "|"), "PICK UP BEFORE YOU GO", "what to pick up comes first")
    equal(string.find(heads[1], "PICK UP BEFORE YOU GO", 1, true), 1, "first")
    contains(heads[#heads], "COMPLETED", "completed last")
    local pick = page.questRows.items[1]
    contains(pick.facts.gwText, "Pick up")
    local chained
    for _, row in ipairs(page.questRows.items) do
        if row.shown ~= false and row.giver.gwText and string.find(row.giver.gwText, "Needs ", 1, true) then chained = row end
    end
    truthy(chained, "a prerequisite chain is shown")
    contains(chained.giver.gwText, "(", "with where each step stands")
    -- The game's own text never reaches the row from the quest log.
    for _, row in ipairs(page.questRows.items) do falsy(row.name.gwText == "A title that must never be sent", "no log titles") end
end

-- 11. Only per-quest checks: "checked" with exactly the ids asked ---------------------------------
do
    local env, addon = boot({ whole = false })
    logLoaded(env)
    local payload = stream(env).envelope.payload
    equal(payload.completed.coverage, "checked")
    local asked = addon.DungeonReadiness.AllQuestIds()
    equal(#payload.completed.checkedQuestIds, #asked, "every catalog quest asked")
    equal(ids(payload.completed.questIds), "65,132,135,141,142,155,167", "the yes answers")
    equal(calls.IsQuestFlaggedCompleted, #asked)
end

-- 12. A whole list that comes back empty is not "full" ------------------------------------------
do
    local env = boot({ completed = {} })
    logLoaded(env)
    equal(stream(env).envelope.payload.completed.coverage, "checked", "falls back to checks")
    local env2 = boot({ completed = {}, check = false })
    logLoaded(env2)
    equal(stream(env2).envelope.payload.completed.coverage, "none", "nothing to fall back to")
    equal(#stream(env2).envelope.payload.completed.questIds, 0)
end

-- 13. The classic APIs ---------------------------------------------------------------------------
do
    local env = boot({ whole = "classic", logApi = "classic" })
    logLoaded(env)
    local payload = stream(env).envelope.payload
    equal(payload.completed.coverage, "full")
    equal(ids(payload.completed.questIds), "65,132,135,141,142,155,167")
    equal(payload.questLog.coverage, "full")
    equal(ids(payload.questLog.entries), "168,2040")
    equal(payload.questLog.entries[2].isComplete, true)
end

-- 14. No quest APIs at all: nothing is claimed, and readiness is never ready --------------------
do
    local env, addon = boot({ whole = false, check = false, logApi = false })
    logLoaded(env)
    local payload = stream(env).envelope.payload
    equal(payload.completed.coverage, "none")
    equal(payload.questLog.coverage, "none")
    equal(addon.DungeonReadiness.ForGuide(36).readiness, "unknown")
    contains(table.concat(addon.CharacterQuests.Report(), "\n"), "no-api")
end

-- 14b. A client that never says its log loaded: published without it after LOG_WAIT ---------
do
    local env, addon = boot()
    equal(stream(env), nil)
    env:advance(addon.CharacterQuests.LOG_WAIT + 3)
    local payload = stream(env).envelope.payload
    equal(payload.questLog.coverage, "none", "never an empty full list")
    equal(payload.completed.coverage, "full")
end

-- 15. Reload: the saved record is kept, the same content is not stored again;
--     SavedVariables round trip; character isolation; character switching ---------------------
do
    local env = boot()
    logLoaded(env)
    local record, key = stream(env)
    local revision = record.revision

    -- SavedVariables as the game writes them, read back.
    local function serialize(value, indent)
        indent = indent or ""
        if type(value) == "table" then
            local keys = {}
            for k in pairs(value) do table.insert(keys, k) end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            local parts = {}
            for _, k in ipairs(keys) do
                local keyText = type(k) == "number" and ("[" .. k .. "]") or ("[" .. string.format("%q", k) .. "]")
                table.insert(parts, indent .. "  " .. keyText .. " = " .. serialize(value[k], indent .. "  "))
            end
            return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
        elseif type(value) == "string" then
            return string.format("%q", value)
        end
        return tostring(value)
    end
    local text = "GuildweaverDB = " .. serialize(GuildweaverDB) .. "\n"
    local dump = os.getenv and os.getenv("GW_SAVEDVARIABLES_DUMP")
    if dump and dump ~= "" then
        local file = assert(io.open(dump, "wb"))
        file:write(text)
        file:close()
    end
    local loaded = {}
    assert((loadstring or load)(text, "=SavedVariables"))
    setfenv(assert(loadstring(text)), loaded)()
    local saved = loaded.GuildweaverDB
    equal(saved.sync.outbound.telemetry[key].revision, revision, "round trip")
    equal(ids(saved.sync.outbound.telemetry[key].envelope.payload.questLog.entries), "168,2040")

    -- After /reload, the same quests: the record stays, nothing new is stored.
    local env2 = boot(nil, saved)
    logLoaded(env2)
    local again = stream(env2)
    equal(again.revision, revision, "the same content after a reload is not stored again")

    -- Another character on the account: its own stream; the first is untouched.
    world.completed = { 1 }
    env2.player.name, env2.player.surname = "Fern", "Ashgrove"
    env2:dispatch("PLAYER_ENTERING_WORLD", false, false)
    env2:advance(5)
    local other, otherKey
    for streamKey, entry in pairs(Env.telemetry()) do
        if string.find(streamKey, "quest_state:", 1, true) == 1 and streamKey ~= key then other, otherKey = entry, streamKey end
    end
    truthy(other, "the other character has its own stream")
    equal(ids(other.envelope.payload.completed.questIds), "1", "with its own quests")
    equal(otherKey, "quest_state:" .. other.envelope.characterId, "keyed by its own id")
    truthy(other.envelope.characterId ~= record.envelope.characterId, "a different character id")
    equal(Env.telemetry()[key].revision, revision, "the first character's state is untouched")
end

print("character quests spec passed")
