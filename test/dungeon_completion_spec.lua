-- Dungeon completion accuracy in the fake client: required, final, optional
-- and unknown encounters. Optional bosses and rares never block a clear and
-- never prove one; unknown encounters are never assumed either way; a kill
-- count alone never proves a clear.
--
-- The dungeons below (instances 9101-9103) are made up for these tests and
-- added to the boss registry only here. Mocked client APIs prove the addon's
-- logic, not what the Forever client actually sends.

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

local function installWorld()
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
    -- The lockout's encounter list only when a test gives one.
    G.GetInstanceLockTimeRemainingEncounter = world.lockNames and function(index)
        local name = world.lockNames[index]
        if not name then return nil end
        return name, nil, world.lockDown[name] == true
    end or nil
    G.EJ_GetInstanceForMap, G.EJ_SelectInstance, G.EJ_GetEncounterInfoByIndex, G.EJ_GetCreatureInfo = nil, nil, nil, nil
    G.C_Map = nil
    G.SetPortraitTextureFromCreatureDisplayID = nil
end

-- A complete roster: two required bosses, an optional rare, a final boss.
local BARROW = { name = "Test Barrow", type = "party", difficultyId = 1, difficultyName = "Normal", maxPlayers = 5, id = 9101 }
local BARROW_BOSSES = {
    name = "Test Barrow",
    complete = true,
    encounters = {
        { encounterId = 911, name = "Warden Thale", role = "required", confidence = "observed", source = "test" },
        { encounterId = 912, name = "Gnasher", role = "required", confidence = "observed", source = "test" },
        { encounterId = 913, name = "Glimmerfang", role = "optional", confidence = "observed", source = "test" },
        { encounterId = 914, name = "Barrow King", role = "final", confidence = "observed", source = "test" },
    },
}
-- No complete roster, but every name the lockout lists has a role.
local SUMP = { name = "Test Sump", type = "party", difficultyId = 1, difficultyName = "Normal", maxPlayers = 5, id = 9102 }
local SUMP_BOSSES = {
    name = "Test Sump",
    encounters = {
        { encounterId = 921, name = "Mire Lord", role = "required", confidence = "observed", source = "test" },
        { encounterId = 922, name = "Silt Lurker", role = "optional", confidence = "observed", source = "test" },
        { encounterId = 923, name = "Sump Queen", role = "required", confidence = "observed", source = "test" },
    },
}
-- Nothing known: no registry entry.
local CRYPT = { name = "Nameless Crypt", type = "party", difficultyId = 1, difficultyName = "Normal", maxPlayers = 5, id = 9103 }
local DEADMINES = { name = "The Deadmines", type = "party", difficultyId = 1, difficultyName = "Normal", maxPlayers = 5, id = 36 }
local BFD = { name = "Blackfathom Deeps", type = "party", difficultyId = 1, difficultyName = "Normal", maxPlayers = 5, id = 48 }

local function boot(options)
    options = options or {}
    if not options.keepWorld then
        world = { instance = nil, lock = { total = options.total or 4, complete = 0 }, lockNames = options.lockNames, lockDown = {} }
    end
    local env = Env.new()
    local addon = env:load()
    installWorld()
    addon.DungeonBosses.instances[9101] = BARROW_BOSSES
    addon.DungeonBosses.instances[9102] = SUMP_BOSSES
    if options.saved then
        GuildweaverDB = options.saved.db
        env.serverTime = options.saved.serverTime
    end
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

-- A kill as the client reports it: ENCOUNTER_END and BOSS_KILL. onLockout:
-- the lockout counts it (rares off the lockout do not).
local function kill(env, id, name, onLockout)
    env:dispatch("ENCOUNTER_START", id, name, 1, 5)
    wait(env, 30)
    env:dispatch("ENCOUNTER_END", id, name, 1, 5, 1)
    env:dispatch("BOSS_KILL", id, name)
    if onLockout ~= false then
        world.lock.complete = world.lock.complete + 1
        world.lockDown[name] = true
    end
end

local function lastPayload(env)
    local newest
    for key, record in pairs(env:telemetry()) do
        if key:find("dungeon_run:", 1, true) == 1 then
            local payload = record.envelope.payload
            if not newest or payload.startedAt > newest.startedAt or (payload.startedAt == newest.startedAt and payload.sequence > newest.sequence) then
                newest = payload
            end
        end
    end
    return newest
end

local function characterId(addon)
    return addon.Character.GetCurrentSnapshot().characterId
end

local function pbFor(addon, instance, kind)
    return addon.DungeonSessions.PersonalBest(characterId(addon), { instanceId = instance.id, difficultyId = 1 }, "first_pull", kind)
end

-- 1. Every required boss and the final boss down, optional rare skipped ---------
do
    local env, addon = boot({ total = 4 })
    local sessions, hud = addon.DungeonSessions, addon.DungeonHud
    zone(env, BARROW)
    pull(env)
    wait(env, 60)
    kill(env, 911, "Warden Thale")
    wait(env, 60)
    kill(env, 912, "Gnasher")
    local run = sessions.Current()
    equal(hud.BossCountText(run), "2/3", "mandatory progress, the rare not in it")
    truthy(not run.complete)
    wait(env, 60)
    kill(env, 914, "Barrow King")
    run = sessions.Current()
    truthy(run.complete, "a clear without the rare")
    equal(run.classification.kind, "full_clear", "every mandatory boss down")
    equal(run.classification.verification, "verified")
    equal(run.classification.mandatoryDefeated, 3)
    equal(run.classification.mandatoryTotal, 3)
    equal(run.classification.optionalDefeated, 0)
    equal(run.classification.coverage, "roster")
    equal(run.timer.state, "stopped", "the clock stops on the last mandatory boss")
    local stopped = run.timerSeconds
    equal(hud.BossCountText(run), "3/3")
    wait(env, 60)
    zone(env, nil)
    local payload = lastPayload(env)
    equal(payload.status, "completed")
    equal(payload.endReason, "required_bosses_defeated")
    -- Sent as "none" until Holdfast accepts the basis (#300); the claim rides along.
    equal(payload.completion.basis, "none")
    equal(payload.completion.claimed, "required_bosses")
    equal(payload.classification.kind, "full_clear")
    equal(payload.bosses.total, 4, "the lockout's total is kept as reported")
    equal(payload.bosses.mandatoryTotal, 3)
    equal(payload.bosses.optionalDefeated, 0)
    equal(payload.bosses.list[3].role, "final")
    equal(payload.timer.seconds, stopped, "nothing after the clear is timed")
    local pb = pbFor(addon, BARROW, "full_clear")
    truthy(pb, "a verified full clear sets a full-clear personal best")
    equal(pb.basis, "required_bosses")
    equal(pbFor(addon, BARROW), nil, "never filed as a 100% clear")
    local entry = sessions.History()[1]
    equal(entry.mandatoryTotal, 3)
    equal(addon.MainFrame.Outcome(entry), "Full clear")
end

-- 2. The rare killed too: a bonus, not a mandatory boss --------------------------
do
    local env, addon = boot({ total = 4 })
    local sessions, hud = addon.DungeonSessions, addon.DungeonHud
    zone(env, BARROW)
    pull(env)
    kill(env, 911, "Warden Thale")
    kill(env, 913, "Glimmerfang")
    local run = sessions.Current()
    equal(run.classification.mandatoryDefeated, 1, "the rare does not count toward the mandatory bosses")
    equal(run.classification.optionalDefeated, 1)
    equal(hud.BossCountText(run), "1/3 +1 optional")
    kill(env, 912, "Gnasher")
    kill(env, 914, "Barrow King")
    equal(sessions.Current().classification.kind, "full_clear", "at the kill: every mandatory boss")
    wait(env, 3) -- the lockout counts the last kill a moment later
    run = sessions.Current()
    equal(run.classification.kind, "hundred_clear", "every lockout encounter, the rare included")
    equal(hud.BossCountText(run), "3/3 +1 optional")
    zone(env, nil)
    local payload = lastPayload(env)
    equal(payload.bosses.optionalDefeated, 1, "the bonus kill stays in the record")
    equal(payload.bosses.list[2].role, "optional")
    equal(payload.bosses.list[2].name, "Glimmerfang")
end

-- 3. Rare killed, a required boss skipped: no clear ------------------------------
do
    local env, addon = boot({ total = 4 })
    local sessions, hud = addon.DungeonSessions, addon.DungeonHud
    zone(env, BARROW)
    pull(env)
    kill(env, 911, "Warden Thale")
    kill(env, 913, "Glimmerfang")
    kill(env, 912, "Gnasher")
    local run = sessions.Current()
    truthy(not run.complete, "three kills, but the final boss is still up")
    equal(run.classification.kind, "partial")
    equal(run.timer.state, "running")
    equal(hud.BossCountText(run), "2/3 +1 optional")
    wait(env, 60)
    zone(env, nil)
    wait(env, sessions.REENTRY_SECONDS + 40)
    local payload = lastPayload(env)
    equal(payload.status, "abandoned")
    equal(payload.classification.kind, "partial")
    equal(payload.completion.basis, "none")
    equal(pbFor(addon, BARROW, "full_clear"), nil, "no personal best")
end

-- 3b. Unknown roster: a rare off the lockout would make the kill count match --
do
    local env, addon = boot({ total = 3 })
    local sessions, hud = addon.DungeonSessions, addon.DungeonHud
    zone(env, CRYPT)
    pull(env)
    kill(env, 931, "Crypt Warden")
    kill(env, 939, "Wandering Rare", false)
    kill(env, 932, "Bone Weaver")
    wait(env, 5)
    local run = sessions.Current()
    equal(run.bossesDefeated, 3, "three kills")
    equal(run.bossesTotal, 3, "the lockout lists three")
    truthy(not run.complete, "the kill count alone proves nothing: the lockout has two down")
    equal(run.timer.state, "running")
    equal(run.classification.kind, "partial")
    equal(run.classification.verification, "unknown", "completion unknown, not assumed")
    equal(run.classification.coverage, "unknown")
    equal(hud.ClassLabel(run.classification), "Completion unknown")
    equal(hud.BossCountText(run), "3 of 3 listed", "a count, not a fraction to finish")
    zone(env, nil)
    wait(env, sessions.REENTRY_SECONDS + 40)
    local payload = lastPayload(env)
    equal(payload.status, "abandoned", "not a clear")
    equal(payload.classification.verification, "unknown")
    equal(payload.bosses.unknownDefeated, 3)
    equal(payload.bosses.mandatoryTotal, nil, "no mandatory total invented")
    equal(pbFor(addon, CRYPT), nil)
    equal(addon.MainFrame.Outcome(sessions.History()[1]), "Completion unknown")
end

-- 4. The rare never spawned: the lockout list names it, the registry knows it is optional
do
    local names = { "Mire Lord", "Silt Lurker", "Sump Queen" }
    local env, addon = boot({ total = 3, lockNames = names })
    local sessions, hud = addon.DungeonSessions, addon.DungeonHud
    zone(env, SUMP)
    pull(env)
    kill(env, 921, "Mire Lord")
    local run = sessions.Current()
    equal(run.classification.coverage, "lockout", "the lockout's list, every role known")
    equal(hud.BossCountText(run), "1/2")
    wait(env, 60)
    kill(env, 923, "Sump Queen")
    run = sessions.Current()
    truthy(run.complete, "the rare that never spawned does not block the clear")
    equal(run.classification.kind, "full_clear")
    equal(run.classification.verification, "verified")
    equal(hud.BossCountText(run), "2/2")
    zone(env, nil)
    local payload = lastPayload(env)
    equal(payload.status, "completed")
    equal(payload.completion.basis, "none", "sent as none until Holdfast accepts it")
    equal(payload.completion.claimed, "required_bosses")
    truthy(pbFor(addon, SUMP, "full_clear"), "a verified full clear")
end

-- 4b. A lockout name without a role keeps the coverage unknown -------------------
do
    local names = { "Mire Lord", "Silt Lurker", "Sump Queen", "Drowned Thing" }
    local env, addon = boot({ total = 4, lockNames = names })
    local sessions, hud = addon.DungeonSessions, addon.DungeonHud
    zone(env, SUMP)
    pull(env)
    kill(env, 921, "Mire Lord")
    kill(env, 923, "Sump Queen")
    local run = sessions.Current()
    equal(run.classification.coverage, "unknown", "Drowned Thing is neither assumed required nor optional")
    truthy(not run.complete, "no clear while an unknown encounter is up")
    equal(hud.BossCountText(run), "2 of 4 listed")
end

-- 5. Unknown roster: the lockout itself proves a 100% clear ----------------------
do
    local env, addon = boot({ total = 2 })
    local sessions, hud = addon.DungeonSessions, addon.DungeonHud
    zone(env, CRYPT)
    pull(env)
    wait(env, 120)
    kill(env, 931, "Crypt Warden")
    equal(hud.BossCountText(sessions.Current()), "1 of 2 listed")
    kill(env, 932, "Bone Weaver")
    wait(env, 3)
    local run = sessions.Current()
    truthy(run.complete, "the lockout counts both")
    equal(run.classification.kind, "hundred_clear")
    zone(env, nil)
    equal(lastPayload(env).completion.basis, "lockout")
    truthy(pbFor(addon, CRYPT), "a lockout-proved clear keeps its personal best")
end

-- 5b. A final boss the classic reference knows is not a verified clear -----------
do
    local env, addon = boot({ total = 5 })
    local sessions = addon.DungeonSessions
    zone(env, DEADMINES)
    pull(env)
    kill(env, 2001, "Edwin VanCleef")
    local run = sessions.Current()
    truthy(not run.complete, "the boss registry has no final boss here; the journal's reference data proves nothing")
    equal(run.classification.kind, "partial")
    zone(env, nil)
    -- A documented (unobserved) final boss completes the run, unverified.
    zone(env, BFD)
    pull(env)
    kill(env, 2002, "Aku'mai")
    run = sessions.Current()
    truthy(run.complete)
    equal(run.classification.kind, "dungeon_clear")
    equal(run.classification.verification, "unconfirmed")
    zone(env, nil)
    equal(lastPayload(env).completion.basis, "final_boss_unconfirmed")
    equal(pbFor(addon, BFD, "dungeon_clear"), nil, "no personal best from a documented boss")
end

-- 6. Duplicate kill events count once -------------------------------------------
do
    local env, addon = boot({ total = 4 })
    local sessions, hud = addon.DungeonSessions, addon.DungeonHud
    zone(env, BARROW)
    pull(env)
    kill(env, 911, "Warden Thale")
    env:dispatch("ENCOUNTER_END", 911, "Warden Thale", 1, 5, 1)
    env:dispatch("BOSS_KILL", 911, "Warden Thale")
    kill(env, 913, "Glimmerfang")
    env:dispatch("BOSS_KILL", 913, "Glimmerfang")
    env:dispatch("ENCOUNTER_END", 913, "Glimmerfang", 1, 5, 1)
    local run = sessions.Current()
    equal(run.bossesDefeated, 2, "two bosses, however many reports")
    equal(run.classification.mandatoryDefeated, 1)
    equal(run.classification.optionalDefeated, 1)
    equal(hud.BossCountText(run), "1/3 +1 optional")
    -- A rare reported twice never adds up to a mandatory boss.
    for _ = 1, 3 do env:dispatch("BOSS_KILL", 913, "Glimmerfang") end
    equal(sessions.Current().classification.mandatoryDefeated, 1)
end

-- 7. Old records: history and an open run from before roles -----------------------
do
    local env, addon = boot({ total = 4 })
    local sessions, hud = addon.DungeonSessions, addon.DungeonHud
    local db = GuildweaverDB
    db.dungeon = db.dungeon or {}
    db.dungeon.history = db.dungeon.history or {}
    local old = { runId = "dungeon-old-1", characterId = characterId(addon), name = "Blackfathom Deeps", status = "abandoned",
        startedAt = 100, durationSeconds = 900, timerSeconds = 880, bossesDefeated = 6, bossesTotal = 7,
        completionBasis = "none", classification = "partial", verification = "none", killKeys = { "name:aku'mai" } }
    local older = { runId = "dungeon-old-2", characterId = characterId(addon), name = "The Deadmines", status = "completed",
        startedAt = 50, durationSeconds = 1200, bossesDefeated = 5, bossesTotal = 5, completionBasis = "encounters" }
    table.insert(db.dungeon.history, old)
    table.insert(db.dungeon.history, older)
    equal(hud.BossCountText(old), "6 of 7 listed", "an old entry reads as the lockout's count")
    equal(addon.MainFrame.Outcome(old), "Partial", "its stored classification is kept")
    equal(addon.MainFrame.Outcome(older), "100% clear", "a pre-classification record keeps its basis")
    -- A new run leaves old entries as they were.
    zone(env, BARROW)
    pull(env)
    kill(env, 911, "Warden Thale")
    zone(env, nil)
    wait(env, sessions.REENTRY_SECONDS + 40)
    equal(old.classification, "partial", "never rewritten")
    equal(old.mandatoryTotal, nil, "no fields invented for an old run")
    equal(old.runId, "dungeon-old-1")
    equal(older.completionBasis, "encounters")

    -- An open run saved before roles existed (no killedNames, no lockout
    -- list) resumes and classifies from its checkpoints.
    local id = characterId(addon)
    db.dungeon.active[id] = {
        runId = "dungeon-legacy-open", characterId = id, identity = { realm = "Live Realm" },
        instance = { name = BARROW.name, instanceId = BARROW.id, difficultyId = 1, difficultyName = "Normal", type = "party" },
        startedAt = env.serverTime - 300, lastActiveAt = env.serverTime, durationSeconds = 300, insideSeconds = 300, inside = true,
        xp = { available = true, gained = 0 }, wallet = { available = false }, deaths = 0, group = { sizeAtEntry = 5, maxSize = 5 },
        bosses = { defeated = 2, killed = { ["911"] = true, ["912"] = true }, manualSplits = 0, duplicatesIgnored = 0 },
        checkpoints = {
            { id = "boss:911", kind = "boss", at = 100, timerAt = 90, name = "Warden Thale", encounterId = 911, source = "encounter_end" },
            { id = "boss:912", kind = "boss", at = 200, timerAt = 190, name = "Gnasher", encounterId = 912, source = "encounter_end" },
        },
        timer = { state = "running", seconds = 290, starts = 1, startedBy = "combat" },
        timeline = {}, lootObservations = 0,
    }
    world.lock.complete = 2
    zone(env, BARROW)
    local run = sessions.Current()
    equal(run.runId, "dungeon-legacy-open", "the old run resumes")
    equal(run.classification.mandatoryDefeated, 2, "roles from its saved checkpoints")
    kill(env, 914, "Barrow King")
    run = sessions.Current()
    equal(run.classification.kind, "full_clear")
    equal(run.runId, "dungeon-legacy-open", "same run ID")
end

-- 8. Manual completion: the player's word, never a verified clear -----------------
do
    local env, addon = boot({ total = 4 })
    local sessions = addon.DungeonSessions
    zone(env, BARROW)
    pull(env)
    wait(env, 200)
    kill(env, 911, "Warden Thale")
    kill(env, 913, "Glimmerfang")
    sessions.Finish()
    local payload = lastPayload(env)
    equal(payload.status, "completed")
    equal(payload.endReason, "manual_finish")
    equal(payload.completion.basis, "manual")
    equal(payload.classification.kind, "dungeon_clear")
    equal(payload.classification.verification, "manual")
    equal(payload.bosses.optionalDefeated, 1, "the rare stays in the record")
    equal(pbFor(addon, BARROW, "dungeon_clear"), nil, "no personal best")
    equal(pbFor(addon, BARROW, "full_clear"), nil)
end

-- 9. Personal best eligibility: an unverified full clear sets none ---------------
do
    -- The roster's second boss known by name only: a full clear, unconfirmed.
    local saved = BARROW_BOSSES.encounters[2]
    BARROW_BOSSES.encounters[2] = { name = "Gnasher", role = "required", confidence = "documented", source = "test" }
    local env, addon = boot({ total = 4 })
    local sessions = addon.DungeonSessions
    zone(env, BARROW)
    pull(env)
    wait(env, 120)
    kill(env, 911, "Warden Thale")
    kill(env, 912, "Gnasher", false)
    kill(env, 914, "Barrow King")
    local run = sessions.Current()
    equal(run.classification.kind, "full_clear")
    equal(run.classification.verification, "unconfirmed", "a boss matched by name only")
    equal(addon.DungeonHud.ClassLabel(run.classification), "Full clear (unverified)")
    zone(env, nil)
    local payload = lastPayload(env)
    equal(payload.completion.basis, "none", "sent as none until Holdfast accepts it")
    equal(payload.completion.claimed, "required_bosses_unconfirmed")
    equal(pbFor(addon, BARROW, "full_clear"), nil, "no personal best from an unverified clear")
    -- The final boss (observed, by ID) still proves a dungeon clear: kept
    -- apart, it is not the stronger full clear.
    equal(pbFor(addon, BARROW, "dungeon_clear"), nil, "the run is filed under its own classification only")
    BARROW_BOSSES.encounters[2] = saved
end

-- 10. Reload during a run ----------------------------------------------------------
do
    local env, addon = boot({ total = 4 })
    zone(env, BARROW)
    pull(env)
    wait(env, 60)
    kill(env, 911, "Warden Thale")
    kill(env, 913, "Glimmerfang")
    local before = addon.DungeonSessions.Current()
    env:dispatch("PLAYER_LOGOUT")
    local env2, addon2 = boot({ keepWorld = true, saved = { db = GuildweaverDB, serverTime = env.serverTime + 5 } })
    zone(env2, BARROW)
    local sessions = addon2.DungeonSessions
    local run = sessions.Current()
    equal(run.runId, before.runId, "the same run after /reload")
    equal(run.classification.mandatoryDefeated, 1)
    equal(run.classification.optionalDefeated, 1)
    kill(env2, 912, "Gnasher")
    kill(env2, 914, "Barrow King")
    wait(env2, 3)
    run = sessions.Current()
    equal(run.classification.kind, "hundred_clear", "every lockout encounter down")
    equal(run.timer.state, "stopped")
    equal(addon2.DungeonHud.BossCountText(run), "3/3 +1 optional")
    zone(env2, nil)
    equal(lastPayload(env2).runId, before.runId)
    equal(lastPayload(env2).status, "completed")
end

print("dungeon completion tests passed")
