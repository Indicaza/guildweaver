-- Boss tracking in the fake client: the final-boss completion rule from the
-- boss registry (optional encounters no longer block a clear), full clears,
-- missing and duplicate encounter events, unknown dungeons, name-only
-- (unconfirmed) final bosses, re-entry, manual versus verified completion,
-- personal-best eligibility, payload compatibility, the boss portraits'
-- data sources and fallbacks, and /gw dungeon bosses.
--
-- The test dungeon below (instance 9001) is made up for these tests and is
-- added to the registry only here. Mocked client APIs prove the addon's
-- logic, not what the Forever client actually provides.

local Env = dofile("test/support/wow_env.lua")

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

local world

local function installWorld(env)
    local G = _G
    G.IsInInstance = function() return world.instance ~= nil, world.instance and world.instance.type or "none" end
    G.GetInstanceInfo = function()
        local instance = world.instance
        if not instance then return "Elwynn Forest", "none", 0, "", 0, 0, false, 0 end
        return instance.name, instance.type, instance.difficultyId, instance.difficultyName, instance.maxPlayers, 0, false, instance.id
    end
    G.UnitXP = function() return 1000 end
    G.UnitXPMax = function() return 5000 end
    G.GetMaxPlayerLevel = function() return 60 end
    G.GetNumGroupMembers = function() return 5 end
    G.GetInstanceLockTimeRemaining = function() return 3600, false, world.lock.total, world.lock.complete end
    -- No lockout encounter list, Encounter Journal or display-ID portraits
    -- unless a test installs them.
    G.GetInstanceLockTimeRemainingEncounter = nil
    G.EJ_GetInstanceForMap, G.EJ_SelectInstance, G.EJ_GetEncounterInfoByIndex, G.EJ_GetCreatureInfo = nil, nil, nil, nil
    G.C_Map = nil
    G.SetPortraitTextureFromCreatureDisplayID = nil
    for _, name in ipairs({ "CastSpellByName", "UseAction", "TargetUnit", "RunMacroText" }) do
        G[name] = function() env.protectedCalls = (env.protectedCalls or 0) + 1 end
    end
end

-- Three required bosses and an optional one; Warden is the final boss.
local HOLLOW = { name = "Test Hollow", type = "party", difficultyId = 1, difficultyName = "Normal", maxPlayers = 5, id = 9001 }
local HOLLOW_BOSSES = {
    name = "Test Hollow",
    encounters = {
        { encounterId = 901, name = "Gatekeeper", role = "required", confidence = "observed", source = "test" },
        { encounterId = 902, name = "Brood Mother", role = "required", confidence = "observed", source = "test" },
        { encounterId = 903, name = "Hidden Hermit", role = "optional", confidence = "observed", source = "test" },
        { encounterId = 904, name = "Warden", role = "final", confidence = "observed", source = "test" },
    },
}
local UNKNOWN = { name = "Nameless Crypt", type = "party", difficultyId = 1, difficultyName = "Normal", maxPlayers = 5, id = 9002 }
local BFD = { name = "Blackfathom Deeps", type = "party", difficultyId = 1, difficultyName = "Normal", maxPlayers = 5, id = 48 }

local function boot()
    world = { instance = nil, lock = { total = 4, complete = 0 } }
    local env = Env.new()
    local addon = env:load()
    installWorld(env)
    addon.DungeonBosses.instances[9001] = HOLLOW_BOSSES
    env.protectedCalls = 0
    env:login()
    env:advance(3)
    return env, addon
end

local function wait(env, seconds)
    env.serverTime = env.serverTime + seconds
    env:advance(seconds)
end

local function zone(env, instance)
    world.instance = instance
    env:dispatch("PLAYER_ENTERING_WORLD", false, false)
    env:advance(2)
end

local function pull(env)
    env:dispatch("PLAYER_REGEN_DISABLED")
    env:dispatch("PLAYER_REGEN_ENABLED")
end

local function kill(env, id, name, both)
    env:dispatch("ENCOUNTER_START", id, name, 1, 5)
    wait(env, 30)
    env:dispatch("ENCOUNTER_END", id, name, 1, 5, 1)
    if both ~= false then env:dispatch("BOSS_KILL", id, name) end
end

local function payloads(env)
    local list = {}
    for key, record in pairs(env:telemetry()) do
        if key:find("dungeon_run:", 1, true) == 1 then table.insert(list, record.envelope.payload) end
    end
    table.sort(list, function(a, b) return a.startedAt < b.startedAt end)
    return list
end

local function lastPayload(env)
    local list = payloads(env)
    return list[#list]
end

local function snapshotId(addon)
    return addon.Character.GetCurrentSnapshot().characterId
end

-- Final boss down, optional boss skipped: a verified clear -------------------------
do
    local env, addon = boot()
    local sessions, hud = addon.DungeonSessions, addon.DungeonHud
    zone(env, HOLLOW)
    pull(env)
    wait(env, 120)
    kill(env, 901, "Gatekeeper")
    wait(env, 120)
    kill(env, 902, "Brood Mother")
    wait(env, 120)
    local run = sessions.Current()
    equal(run.timer.state, "running", "not done before the final boss")
    truthy(not run.complete)
    kill(env, 904, "Warden")
    run = sessions.Current()
    equal(run.bossesDefeated, 3, "the final boss counted once despite ENCOUNTER_END and BOSS_KILL")
    equal(run.bossesTotal, 4, "the lockout still lists four")
    truthy(run.complete, "complete without the optional boss")
    equal(run.finalBoss.proof, "final_boss", "proved by the final boss's encounter ID")
    equal(run.timer.state, "stopped", "the timer stops on the final boss")
    equal(run.timer.stoppedBy, "complete")
    truthy(hud.StateText(run):find("^Cleared"), "the HUD shows the clear")
    truthy(run.inside, "the run stays open for loot")
    local stopped = run.timerSeconds
    wait(env, 60)
    equal(sessions.Current().timerSeconds, stopped, "nothing after the clear is timed")
    env:dispatch("PLAYER_DEAD")
    truthy(sessions.Current(), "still open after a death post-clear")

    zone(env, nil)
    equal(sessions.Current(), nil, "leaving ends the finished run")
    local payload = lastPayload(env)
    equal(payload.status, "completed")
    equal(payload.endReason, "final_boss_defeated")
    equal(payload.schemaVersion, 2, "payload schema unchanged")
    equal(payload.completion.basis, "final_boss")
    equal(payload.completion.finalBoss.encounterId, 904)
    equal(payload.completion.finalBoss.confidence, "observed")
    equal(payload.completion.registryVersion, addon.DungeonBosses.VERSION)
    equal(payload.bosses.duplicatesIgnored, 3, "BOSS_KILL after ENCOUNTER_END ignored for each boss")
    local pb = sessions.PersonalBest(snapshotId(addon), { instanceId = 9001, difficultyId = 1 })
    truthy(pb, "a verified final-boss clear can set a personal best")
    equal(pb.basis, "final_boss")
    equal(addon.MainFrame.Outcome({ status = "completed", completionBasis = "final_boss" }), "Cleared")
end

-- Full clear: every encounter down ------------------------------------------------
do
    local env, addon = boot()
    zone(env, HOLLOW)
    pull(env)
    for index, boss in ipairs({ { 901, "Gatekeeper" }, { 902, "Brood Mother" }, { 903, "Hidden Hermit" } }) do
        wait(env, 90)
        kill(env, boss[1], boss[2])
        world.lock.complete = index
    end
    wait(env, 90)
    kill(env, 904, "Warden")
    world.lock.complete = 4
    zone(env, nil)
    local payload = lastPayload(env)
    equal(payload.status, "completed")
    equal(payload.endReason, "all_bosses_defeated")
    truthy(payload.completion.basis == "encounters" or payload.completion.basis == "lockout", "a full clear keeps its stronger basis")
    equal(payload.completion.finalBoss, nil, "no final-boss block on a full clear")
    equal(addon.MainFrame.Outcome({ status = "completed", completionBasis = payload.completion.basis }), "Full clear")
end

-- No encounter events at all: nothing is assumed ------------------------------------
do
    local env, addon = boot()
    local sessions = addon.DungeonSessions
    zone(env, HOLLOW)
    pull(env)
    wait(env, 600)
    truthy(not sessions.Current().complete, "no events, no completion")
    sessions.Split("Warden")
    truthy(not sessions.Current().complete, "a split named after the final boss proves nothing")
    zone(env, nil)
    wait(env, sessions.REENTRY_SECONDS + 40)
    equal(lastPayload(env).status, "abandoned", "left without proof")

    -- Manual finish: labelled the player's, never a PB.
    zone(env, HOLLOW)
    pull(env)
    wait(env, 400)
    sessions.Finish()
    local payload = lastPayload(env)
    equal(payload.completion.basis, "manual")
    equal(sessions.PersonalBest(snapshotId(addon), { instanceId = 9001, difficultyId = 1 }), nil, "manual finishes never set a PB")
    equal(addon.MainFrame.Outcome({ status = "completed", completionBasis = "manual" }), "Finished by you")
end

-- A failed attempt on the final boss is not a kill ------------------------------------
do
    local env, addon = boot()
    local sessions = addon.DungeonSessions
    zone(env, HOLLOW)
    pull(env)
    env:dispatch("ENCOUNTER_START", 904, "Warden", 1, 5)
    wait(env, 20)
    env:dispatch("ENCOUNTER_END", 904, "Warden", 1, 5, 0)
    truthy(not sessions.Current().complete, "a wipe on the final boss completes nothing")
    equal(sessions.Current().timer.state, "running")
end

-- Unknown dungeon: unchanged event-driven tracking --------------------------------------
do
    local env, addon = boot()
    local sessions = addon.DungeonSessions
    zone(env, UNKNOWN)
    pull(env)
    for index = 1, 3 do
        wait(env, 90)
        kill(env, 950 + index, "Boss " .. index)
    end
    local run = sessions.Current()
    truthy(not run.complete, "3 of 4 with no registry is not a clear")
    equal(run.finalBoss, nil)
    zone(env, nil)
    wait(env, sessions.REENTRY_SECONDS + 40)
    equal(lastPayload(env).status, "abandoned", "as before: needs a full clear or a finish")
    equal(lastPayload(env).completion.basis, "none")
end

-- Name-only final boss (Blackfathom Deeps' documented Aku'mai): unconfirmed --------
do
    local env, addon = boot()
    local sessions = addon.DungeonSessions
    world.lock.total = 7
    zone(env, BFD)
    pull(env)
    wait(env, 900)
    kill(env, 777, "Aku'mai")
    local run = sessions.Current()
    truthy(run.complete, "the documented final boss completes the run")
    equal(run.finalBoss.proof, "final_boss_unconfirmed", "matched by name only: unconfirmed")
    equal(run.timer.state, "stopped")
    zone(env, nil)
    local payload = lastPayload(env)
    equal(payload.status, "completed")
    equal(payload.completion.basis, "final_boss_unconfirmed")
    equal(payload.completion.finalBoss.confidence, "documented")
    equal(sessions.PersonalBest(snapshotId(addon), { instanceId = 48, difficultyId = 1 }), nil, "an unconfirmed clear never sets a PB")
    equal(addon.MainFrame.Outcome({ status = "completed", completionBasis = "final_boss_unconfirmed" }), "Cleared (unverified)")
end

-- Death and re-entry before the final boss continue the same run ---------------------
do
    local env, addon = boot()
    local sessions = addon.DungeonSessions
    zone(env, HOLLOW)
    pull(env)
    wait(env, 60)
    kill(env, 901, "Gatekeeper")
    local runId = sessions.Current().runId
    env:dispatch("PLAYER_DEAD")
    zone(env, nil)
    wait(env, 90)
    truthy(sessions.Current(), "open while running back")
    zone(env, HOLLOW)
    equal(sessions.Current().runId, runId, "the same run after re-entry")
    wait(env, 60)
    kill(env, 904, "Warden")
    truthy(sessions.Current().complete)
    equal(sessions.Current().deaths, 1)
    -- A /reload after the clear keeps it complete and open.
    env:dispatch("PLAYER_LOGOUT")
    local saved = GuildweaverDB
    local env2 = Env.new()
    local addon2 = env2:load()
    installWorld(env2)
    addon2.DungeonBosses.instances[9001] = HOLLOW_BOSSES
    GuildweaverDB = saved
    env2.serverTime = env.serverTime + 5
    env2:login()
    env2:advance(3)
    truthy(addon2.DungeonSessions.Current().complete, "still complete after a reload")
    equal(addon2.DungeonSessions.Current().runId, runId)
    world.instance = nil
    env2:dispatch("PLAYER_ENTERING_WORLD", false, false)
    env2:advance(2)
    local payload = lastPayload(env2)
    equal(payload.status, "completed")
    equal(payload.completion.basis, "final_boss")
end

-- Portraits: no journal, no display IDs, no lockout list -> restrained fallback -----
do
    local env, addon = boot()
    local hud, sessions = addon.DungeonHud, addon.DungeonSessions
    zone(env, HOLLOW)
    hud:SetMode("compact")
    equal(hud.JournalBosses(9001), nil, "no Encounter Journal API: nil, no error")
    equal(#hud.KnownBosses(sessions.Current()), 0, "nothing named without client data")
    local circle = hud.circles["pending:1"]
    truthy(circle, "a frame per boss ahead")
    equal(circle.icon, hud.TEXTURES.boss, "a faint skull, not a question mark")
    equal(circle.display, nil, "no display ID drawn")
    equal(env.protectedCalls, 0)
end

-- Portraits: lockout encounter list names bosses ahead --------------------------------
do
    local env, addon = boot()
    local hud, sessions = addon.DungeonHud, addon.DungeonSessions
    local lockNames = { "Gatekeeper", "Brood Mother", "Hidden Hermit", "Warden" }
    _G.GetInstanceLockTimeRemainingEncounter = function(index)
        return lockNames[index], nil, index <= world.lock.complete
    end
    zone(env, HOLLOW)
    pull(env)
    kill(env, 901, "Gatekeeper")
    world.lock.complete = 1
    env:dispatch("PLAYER_MONEY")
    local run = sessions.Current()
    equal(#run.lockEncounters, 4, "the lockout's list is kept as evidence")
    local entries = hud.Portraits(run)
    equal(entries[1].kind, "boss")
    equal(entries[2].kind, "pending")
    equal(entries[2].name, "Brood Mother", "bosses ahead take the client's names, in its order")
    equal(entries[4].name, "Warden")
    local tooltip = _G.GameTooltip
    local lines = {}
    tooltip.SetOwner = function() end
    tooltip.ClearLines = function() lines = {} end
    tooltip.AddLine = function(_, text) table.insert(lines, text) end
    hud:SetMode("compact")
    hud.circles["pending:1"].frame:GetScript("OnEnter")()
    equal(lines[1], "Brood Mother", "hover names a boss ahead when the client named it")
    equal(lines[2], "Not defeated yet.")
end

-- Portraits: Encounter Journal display IDs, drawn only where the API exists -----------
do
    local env, addon = boot()
    local hud, sessions = addon.DungeonHud, addon.DungeonSessions
    local selected = 0
    _G.C_Map = { GetBestMapForUnit = function() return 7001 end }
    _G.EJ_GetInstanceForMap = function(map) return map == 7001 and 333 or 0 end
    _G.EJ_SelectInstance = function() selected = selected + 1 end
    local journal = { { "Gatekeeper", 61, 901, 1001 }, { "Brood Mother", 62, 902, 1002 }, { "Hidden Hermit", 63, 903, nil }, { "Warden", 64, 904, 1004 } }
    _G.EJ_GetEncounterInfoByIndex = function(index)
        local entry = journal[index]
        if not entry then return nil end
        return entry[1], "", entry[2], 0, nil, 333, entry[3], 9001
    end
    _G.EJ_GetCreatureInfo = function(_, journalEncounter)
        for _, entry in ipairs(journal) do
            if entry[2] == journalEncounter then return 1, entry[1], "", entry[4], nil end
        end
    end
    -- In combat the journal is not touched.
    env.inCombat = true
    equal(hud.JournalBosses(9001), nil, "not read in combat")
    equal(selected, 0)
    env.inCombat = false
    -- Without the display-ID portrait API: names only, the skull fallback.
    zone(env, HOLLOW)
    hud:SetMode("compact")
    local known = hud.KnownBosses(sessions.Current())
    equal(#known, 4, "the journal's bosses")
    equal(known[4].displayId, 1004)
    equal(known[3].displayId, nil, "a boss without a display ID stays without one")
    equal(selected, 1, "the journal is read once per instance")
    hud.KnownBosses(sessions.Current())
    equal(selected, 1, "and cached")
    equal(hud.circles["pending:1"].display, nil, "no SetPortraitTextureFromCreatureDisplayID: no art, no error")
    -- With it: real portraits for bosses ahead.
    local drawn = {}
    _G.SetPortraitTextureFromCreatureDisplayID = function(texture, displayId) texture.display = displayId; table.insert(drawn, displayId) end
    hud:ResetCircles()
    hud:Refresh()
    equal(hud.circles["pending:1"].display, 1001, "Gatekeeper's portrait from its display ID")
    equal(hud.circles["pending:3"].icon, hud.TEXTURES.boss, "no display ID: the fallback")
    local count = #drawn
    hud:Refresh()
    equal(#drawn, count, "a refresh does not redraw portraits")
    -- A broken portrait API never errors.
    _G.SetPortraitTextureFromCreatureDisplayID = function() error("not available") end
    hud:ResetCircles()
    hud:Refresh()
    equal(hud.circles["pending:1"].icon, hud.TEXTURES.boss, "an erroring API falls back")
    equal(env.protectedCalls, 0)
end

-- /gw dungeon bosses: on request only ------------------------------------------------
do
    local env, addon = boot()
    local sessions = addon.DungeonSessions
    local printed = #env.printed
    zone(env, HOLLOW)
    pull(env)
    kill(env, 904, "Warden")
    equal(#env.printed, printed, "nothing is printed unasked")
    SlashCmdList.GUILDWEAVER("dungeon bosses")
    local text = table.concat(env.printed, "\n", printed + 1)
    truthy(text:find("instance 9001", 1, true), "instance ID")
    truthy(text:find("Lockout: 4 encounters", 1, true), "lockout total")
    truthy(text:find("boss_kill id=904 Warden via encounter_end", 1, true), "recorded kills with source")
    truthy(text:find("duplicates ignored: 1", 1, true), "duplicates")
    truthy(text:find("Final boss recognised: Warden", 1, true), "final boss")
    truthy(text:find("Status: complete", 1, true), "why it is complete")
    local lines = sessions.Diagnostics()
    truthy(#lines > 4)
end

-- Quick list hides zero-length stubs, history keeps them -------------------------------
do
    local _, addon = boot()
    local history = {
        { status = "interrupted", timerSeconds = 0, bossesDefeated = 0, name = "A" },
        { status = "completed", completionBasis = "manual", timerSeconds = 900, name = "B" },
        { status = "abandoned", timerSeconds = 0, bossesDefeated = 0, name = "C" },
        { status = "abandoned", timerSeconds = 1200, bossesDefeated = 2, name = "D" },
    }
    local listed = addon.MainFrame.ListedRuns(history, 5)
    equal(#listed, 2, "0:00 interrupted and abandoned stubs are not listed")
    equal(listed[1].name, "B")
    equal(listed[2].name, "D")
    equal(#history, 4, "history itself is untouched")
end

print("dungeon boss tracking tests passed")
