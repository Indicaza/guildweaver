-- Dungeon runs against the real TOC in the fake client: entering and
-- leaving instances, reloads, XP, money, deaths, bosses, the payload and the
-- HUD.

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

-- World state the dungeon module reads, shared by every fake client below.
local world

local function installWorld(env)
    local G = _G
    G.IsInInstance = function()
        if world.secretInstance then return G.SECRET, G.SECRET end
        return world.instance ~= nil, world.instance and world.instance.type or "none"
    end
    G.GetInstanceInfo = function()
        local instance = world.instance
        if not instance then return "Elwynn Forest", "none", 0, "", 0, 0, false, 0 end
        if world.secretInstance then return G.SECRET, G.SECRET, G.SECRET, G.SECRET, G.SECRET, 0, false, G.SECRET end
        return instance.name, instance.type, instance.difficultyId, instance.difficultyName, instance.maxPlayers, 0, false, instance.id
    end
    G.UnitXP = function() return world.xp end
    G.UnitXPMax = function() return world.xpMax end
    G.UnitLevel = function() return env.player.level end
    G.GetMaxPlayerLevel = function() return world.maxLevel end
    G.GetNumGroupMembers = function() return world.group end
    G.GetInstanceLockTimeRemaining = world.lock and function()
        return 3600, false, world.lock.total, world.lock.complete
    end or nil
    G.issecretvalue = function(value) return value == G.SECRET end
    G.SECRET = G.SECRET or setmetatable({}, { __tostring = function() return "secret" end })
end

local DEADMINES = { name = "The Deadmines", type = "party", difficultyId = 1, difficultyName = "Normal", maxPlayers = 5, id = 36 }
local STOCKADE = { name = "The Stockade", type = "party", difficultyId = 1, difficultyName = "Normal", maxPlayers = 5, id = 34 }

local function resetWorld()
    world = { instance = nil, xp = 1000, xpMax = 5000, maxLevel = 60, group = 5 }
end

local function boot(saved)
    local env = Env.new()
    local addon = env:load()
    installWorld(env)
    if saved then
        GuildweaverDB = saved.db
        env.serverTime = saved.serverTime
        env.money = saved.money
        env.player.level = saved.level
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

-- /reload or logout and back: PLAYER_LOGOUT, a new client with the same
-- SavedVariables, `gap` seconds later.
local function relog(env, gap)
    env:dispatch("PLAYER_LOGOUT")
    local saved = { db = GuildweaverDB, serverTime = env.serverTime + (gap or 5), money = env.money, level = env.player.level }
    return boot(saved)
end

local function runs(env)
    local found = {}
    for key, record in pairs(env:telemetry()) do
        if key:find("dungeon_run:", 1, true) == 1 then
            table.insert(found, record)
        end
    end
    table.sort(found, function(a, b) return a.envelope.payload.startedAt < b.envelope.payload.startedAt end)
    return found
end

local function lastRun(env)
    local found = runs(env)
    local record = found[#found]
    return record and record.envelope.payload, record
end

local function active(addon)
    return addon.DungeonSessions.Current()
end

-- Entering and exiting; a normal full clear ----------------------------------
do
    resetWorld()
    world.lock = { total = 2, complete = 0 }
    local env, addon = boot()
    equal(active(addon), nil, "no run in the open world")
    zone(env, DEADMINES)
    local run = active(addon)
    truthy(run, "run starts on entering a dungeon")
    equal(run.name, "The Deadmines")
    truthy(addon.DungeonHud.visible, "HUD shows inside")
    equal(#runs(env), 0, "nothing is queued mid-run")

    wait(env, 120)
    world.xp = 2500
    env:dispatch("PLAYER_XP_UPDATE", "player")
    env.money = env.money + 15000
    env:dispatch("PLAYER_MONEY")
    env:dispatch("ENCOUNTER_START", 1, "Rhahk'Zor", 1, 5)
    wait(env, 30)
    env:dispatch("ENCOUNTER_END", 1, "Rhahk'Zor", 1, 5, 1)
    env:dispatch("BOSS_KILL", 1, "Rhahk'Zor")
    world.lock.complete = 1
    equal(active(addon).bossesDefeated, 1, "ENCOUNTER_END and BOSS_KILL count one kill")
    env:dispatch("PLAYER_DEAD")
    wait(env, 60)
    env:dispatch("ENCOUNTER_END", 2, "Van Cleef", 1, 5, 0)
    equal(active(addon).bossesDefeated, 1, "a failed encounter is not a kill")
    wait(env, 30)
    env:dispatch("ENCOUNTER_END", 2, "Van Cleef", 1, 5, 1)
    world.lock.complete = 2

    zone(env, nil)
    equal(active(addon), nil, "full clear ends on leaving")
    truthy(not addon.DungeonHud.visible, "HUD hides outside")
    local payload, record = lastRun(env)
    equal(record.kind, "event", "runs use the event stream")
    equal(record.envelope.eventType, "dungeon_run")
    equal(payload.schemaVersion, 2)
    equal(payload.status, "completed")
    equal(payload.endReason, "all_bosses_defeated")
    equal(payload.instance.name, "The Deadmines")
    equal(payload.instance.instanceId, 36)
    equal(payload.instance.difficultyId, 1)
    equal(payload.instance.type, "party")
    equal(payload.group.sizeAtEntry, 5)
    equal(payload.xp.gained, 1500, "XP gained")
    equal(payload.xp.atLevelCap, false)
    equal(payload.wallet.basis, "wallet_delta", "wallet change is labelled, not profit")
    equal(payload.wallet.netCopper, 15000)
    equal(payload.deaths, 1)
    equal(payload.bosses.defeated, 2)
    equal(payload.bosses.total, 2)
    equal(payload.bosses.encounterEvents, true)
    equal(#payload.bosses.list, 2)
    equal(payload.bosses.list[1].name, "Rhahk'Zor")
    equal(payload.durationSeconds, 242, "online time from entry to leaving")
    truthy(payload.endedAt >= payload.startedAt, "ended after start")
    equal(record.envelope.characterId, env.addon.Character.GetCurrentSnapshot().characterId, "run belongs to the character")
    equal(record.envelope.realm, "Live Realm")
    local kinds = {}
    for _, entry in ipairs(payload.timeline) do kinds[#kinds + 1] = entry.kind end
    equal(table.concat(kinds, ","), "enter,timer_start,encounter_start,boss_kill,death,encounter_failed,boss_kill,complete,timer_stop,leave",
        "timeline: the first encounter starts the timer, the last boss stops it")
    -- Schema 2: checkpoints with stable ids, what proved the clear.
    equal(#payload.checkpoints, 2, "two boss checkpoints")
    equal(payload.checkpoints[1].id, "boss:1")
    equal(payload.checkpoints[2].id, "boss:2")
    equal(payload.checkpoints[1].source, "encounter_end")
    equal(payload.completion.basis, "encounters", "both kills reported by the client")
    equal(payload.bosses.duplicatesIgnored, 1, "BOSS_KILL after ENCOUNTER_END ignored")
    equal(#addon.DungeonSessions.History(), 1, "kept for the window")
end

-- Two runs of the same dungeon in a row are two runs -------------------------
do
    resetWorld()
    world.lock = { total = 1, complete = 0 }
    local env, addon = boot()
    zone(env, DEADMINES)
    wait(env, 90)
    env:dispatch("ENCOUNTER_END", 9, "Boss", 1, 5, 1)
    world.lock.complete = 1
    zone(env, nil)
    world.lock.complete = 0
    zone(env, DEADMINES)
    wait(env, 90)
    env:dispatch("ENCOUNTER_END", 9, "Boss", 1, 5, 1)
    world.lock.complete = 1
    zone(env, nil)
    local found = runs(env)
    equal(#found, 2, "consecutive runs")
    truthy(found[1].envelope.payload.runId ~= found[2].envelope.payload.runId, "unique run ids")
    equal(found[2].envelope.payload.bosses.defeated, 1, "second run counts its own boss")
    equal(active(addon), nil)
end

-- Leaving briefly and coming back continues the run; staying out ends it -----
do
    resetWorld()
    local env, addon = boot()
    zone(env, DEADMINES)
    local id = active(addon).runId
    wait(env, 100)
    env:dispatch("PLAYER_DEAD")
    zone(env, nil) -- released to the graveyard
    truthy(active(addon), "run stays open outside")
    equal(active(addon).inside, false)
    wait(env, 120)
    zone(env, DEADMINES)
    equal(active(addon).runId, id, "re-entry continues the same run")
    wait(env, 60)
    zone(env, nil)
    wait(env, addon.DungeonSessions.REENTRY_SECONDS + 40)
    equal(active(addon), nil, "the run ends after the re-entry window")
    local payload = lastRun(env)
    equal(payload.runId, id)
    equal(payload.status, "abandoned", "left without clearing")
    equal(payload.endReason, "left_instance")
    equal(payload.durationSeconds, 286, "time after leaving for good is not counted")
    equal(payload.insideSeconds, 164)

    -- Leaving, then a /reload outside: the window still closes the run.
    zone(env, DEADMINES)
    local outsideId = active(addon).runId
    wait(env, 90)
    zone(env, nil)
    env, addon = relog(env, 3)
    equal(active(addon).runId, outsideId, "still open after reload outside")
    wait(env, addon.DungeonSessions.REENTRY_SECONDS + 40)
    equal(active(addon), nil, "ends after the window even across a reload")
    equal(lastRun(env).runId, outsideId)
    equal(lastRun(env).status, "abandoned")

    -- Entering another dungeon ends an open run right away.
    zone(env, DEADMINES)
    wait(env, 100)
    zone(env, STOCKADE)
    equal(active(addon).name, "The Stockade")
    equal(lastRun(env).endReason, "entered_other_instance")
    equal(lastRun(env).status, "abandoned")
end

-- Reload and logout during a run ---------------------------------------------
do
    resetWorld()
    local env, addon = boot()
    zone(env, DEADMINES)
    local id = active(addon).runId
    wait(env, 200)
    env:dispatch("ENCOUNTER_END", 1, "Boss", 1, 5, 1)
    world.instance = DEADMINES
    env, addon = relog(env, 4) -- /reload
    local run = active(addon)
    truthy(run, "run continues after reload")
    equal(run.runId, id, "no duplicate run after reload")
    equal(run.bossesDefeated, 1, "progress kept")
    local open = lastRun(env)
    equal(open.status, "open", "reload queues the open run for the website")
    equal(open.sequence, 1)
    wait(env, 100)

    env, addon = relog(env, 120) -- disconnect, back two minutes later
    equal(active(addon).runId, id, "reconnect continues the run")
    -- 300 s played plus the fake client's login frames; the 124 s offline are not counted.
    equal(math.floor(active(addon).durationSeconds), 314, "offline time is not counted")
    equal(#runs(env), 1, "one stream per run")

    -- Logged out in the dungeon and not back for an hour.
    env, addon = relog(env, 3600)
    truthy(active(addon).runId ~= id, "stale run ends at next login; being inside starts a new one")
    local payload, record = lastRun(env)
    equal(payload.runId, id)
    equal(payload.status, "interrupted")
    equal(payload.endReason, "logout_not_resumed")
    truthy(payload.sequence > open.sequence, "final state supersedes interim ones")
    equal(record.revision, 4, "same stream, newer revision (three logouts, then the end)")
end

-- XP across a level up, and at the level cap ---------------------------------
do
    resetWorld()
    local env, addon = boot()
    zone(env, DEADMINES)
    world.xp = 4500
    env:dispatch("PLAYER_XP_UPDATE", "player")
    -- Ding: the event arrives before UnitLevel and UnitXP move on.
    env:dispatch("PLAYER_LEVEL_UP", 31)
    env.player.level = 31
    world.xp, world.xpMax = 700, 6000
    env:dispatch("PLAYER_XP_UPDATE", "player")
    wait(env, 600)
    local run = active(addon)
    equal(run.xpGained, 3500 + 500 + 700, "rest of the old level plus the new")
    truthy(run.xpPerHour, "XP/hour after a few minutes")
    zone(env, nil)
    addon.DungeonSessions.Evaluate("test")
    wait(env, 700)
    local payload = lastRun(env)
    equal(payload.xp.levelUps, 1)
    equal(payload.character.levelAtEntry, 30)
    equal(payload.character.levelAtExit, 31)

    -- At max level nothing is reported as XP.
    env.player.level = 60
    world.xp, world.xpMax = 0, 0
    zone(env, DEADMINES)
    wait(env, 600)
    env:dispatch("PLAYER_XP_UPDATE", "player")
    run = active(addon)
    equal(run.xpGained, nil, "no XP at the cap")
    equal(run.xpPerHour, nil, "no XP/hour at the cap")
    truthy(addon.DungeonHud.Lines(run)[3]:find("max level", 1, true), "HUD says max level")
    addon.DungeonSessions.Finish()
    payload = lastRun(env)
    equal(payload.xp.atLevelCap, true)
    equal(payload.xp.gained, nil)
    equal(payload.status, "completed")
    equal(payload.endReason, "manual_finish")
end

-- No encounter events: manual splits; secret and missing values --------------
do
    resetWorld()
    local env, addon = boot()
    world.secretInstance = true
    zone(env, DEADMINES)
    equal(active(addon), nil, "secret instance info starts nothing")
    world.secretInstance = false
    _G.GetInstanceLockTimeRemaining = nil
    _G.GetMoney = function() return _G.SECRET end
    _G.UnitXP = function() return nil end
    _G.GetNumGroupMembers = nil
    zone(env, DEADMINES)
    local run = active(addon)
    truthy(run, "run starts without money, XP or group data")
    wait(env, 45)
    local split = addon.DungeonSessions.Split("Mr. Smite")
    equal(split.name, "Mr. Smite")
    equal(split.at, 46, "split time (45 s plus the second after entry)")
    run = active(addon)
    equal(run.bossesDefeated, 0, "a split is not a kill")
    equal(run.encounterEvents, false, "no encounter events seen")
    equal(#run.splits, 1)
    addon.DungeonSessions.Finish()
    local payload = lastRun(env)
    equal(payload.wallet.available, false)
    equal(payload.wallet.netCopper, nil, "unknown money is not zero")
    equal(payload.xp.available, false)
    equal(payload.xp.gained, nil)
    equal(payload.group.sizeAtEntry, nil)
    equal(payload.bosses.manualSplits, 1)
    equal(payload.bosses.encounterEvents, false)
    equal(payload.timeline[2].kind, "manual_split")
end

-- Bounded timeline, history and nothing for empty visits ----------------------
do
    resetWorld()
    local env, addon = boot()
    for _ = 1, addon.DungeonSessions.MAX_HISTORY + 3 do
        zone(env, DEADMINES)
        wait(env, 30)
        env:dispatch("PLAYER_DEAD")
        zone(env, STOCKADE)
    end
    equal(#addon.DungeonSessions.History(), addon.DungeonSessions.MAX_HISTORY, "history is bounded")
    for _ = 1, addon.DungeonSessions.MAX_TIMELINE + 20 do
        env:dispatch("PLAYER_DEAD")
    end
    addon.DungeonSessions.Finish()
    local payload = lastRun(env)
    equal(#payload.timeline, addon.DungeonSessions.MAX_TIMELINE, "timeline is bounded")
    equal(payload.timelineTruncated, true)
    equal(payload.deaths, addon.DungeonSessions.MAX_TIMELINE + 20, "counts stay exact")

    local before = #runs(env)
    zone(env, DEADMINES)
    wait(env, 10)
    zone(env, nil)
    wait(env, addon.DungeonSessions.REENTRY_SECONDS + 40)
    equal(#runs(env), before, "zoning in and out records nothing")
end

-- Duplicate delivery: a re-sent final run is the same record ------------------
do
    resetWorld()
    local env, addon = boot()
    zone(env, DEADMINES)
    wait(env, 100)
    addon.DungeonSessions.Finish()
    local _, record = lastRun(env)
    local key
    for streamKey, value in pairs(env:telemetry()) do if value == record then key = streamKey end end
    equal(addon.Store.SetTelemetryEvent(key, record.envelope), false, "same final state is not queued twice")
    env:dispatch("PLAYER_LOGOUT")
    local _, after = lastRun(env)
    equal(after.revision, record.revision, "logout after the run does not re-send it")
end

-- Loot inside a run carries the run id; outside it does not -------------------
do
    resetWorld()
    local env, addon = boot()
    local snapshot = addon.Character.GetCurrentSnapshot()
    env.loot = { { link = "|cffffffff|Hitem:2589::::::::30:::::::|h[Linen Cloth]|h|r", quantity = 2,
        source = "Creature-0-1-36-1-644-0000ABCD" } }
    zone(env, DEADMINES)
    addon.GatheringTelemetry.InvalidateLoot()
    addon.MobLootCapture.Capture()
    local record = env:stream("mob_loot:" .. snapshot.characterId)
    truthy(record, "loot recorded in the dungeon")
    equal(record.envelope.payload.context.dungeonRun.runId, active(addon).runId, "loot linked to the run")
    equal(record.envelope.payload.observationId, "Creature-0-1-36-1-644-0000ABCD", "observation id unchanged")
    zone(env, nil)
    addon.DungeonSessions.Finish()
    equal(lastRun(env).loot.observations, 1, "run counts its loot without copying it")
    env.loot = { { link = "|cffffffff|Hitem:2589::::::::30:::::::|h[Linen Cloth]|h|r", quantity = 1,
        source = "Creature-0-1-1-1-299-0000BEEF" } }
    addon.GatheringTelemetry.InvalidateLoot()
    addon.MobLootCapture.Capture()
    local _, outsideKey = env:stream("mob_loot:" .. snapshot.characterId .. ":Creature-0-1-1-1-299")
    equal(env:telemetry()[outsideKey].envelope.payload.context.dungeonRun, nil, "open-world loot has no run")
end

-- HUD preferences --------------------------------------------------------------
do
    resetWorld()
    local env, addon = boot()
    addon.DungeonHud:SetEnabled(false)
    zone(env, DEADMINES)
    truthy(active(addon), "runs record with the HUD off")
    truthy(not addon.DungeonHud.visible, "disabled HUD stays hidden")
    addon.DungeonHud:SetEnabled(true)
    truthy(addon.DungeonHud.visible, "enabled HUD shows")
    addon.DungeonHud:ToggleExpanded()
    equal(GuildweaverDB.ui.dungeonHud.expanded, true, "expanded is saved")
    equal(GuildweaverDB.ui.dungeonHud.enabled, true, "enabled is saved")
    local lines = addon.DungeonHud.lines
    truthy(table.concat(lines, "\n"):find("/h", 1, true), "details show XP/hour")
    SlashCmdList.GUILDWEAVER("dungeon split Big Boss")
    equal(active(addon).splits[1].name, "Big Boss", "slash split keeps the name's case")
    SlashCmdList.GUILDWEAVER("dungeon hud off")
    equal(GuildweaverDB.ui.dungeonHud.enabled, false)
    SlashCmdList.GUILDWEAVER("dungeon")
end

print("dungeon session tests passed")
