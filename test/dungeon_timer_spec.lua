-- The dungeon run timer and the tracker's boss row in the fake client: the
-- timer is ready at entry, starts on the first pull or by hand, stops by
-- hand or on the last boss, survives a reload without counting offline
-- time, stamps checkpoints and the payload; the boss row keeps one round
-- portrait per boss and split, adopts the fight's face on the kill, names
-- splits after the target, and starts over with a new run.

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

local function contains(lines, needle, label)
    for _, line in ipairs(lines or {}) do
        if string.find(line, needle, 1, true) then return line end
    end
    error((label or "lines") .. ": no line contains " .. needle .. " in\n" .. table.concat(lines or {}, "\n"), 2)
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
    G.UnitXP = function() return world.xp end
    G.UnitXPMax = function() return world.xpMax end
    G.UnitLevel = function() return env.player.level end
    G.GetMaxPlayerLevel = function() return 60 end
    G.GetNumGroupMembers = function() return 5 end
    G.GetInstanceLockTimeRemaining = function() return 3600, false, world.lock.total, world.lock.complete end
    -- Units the tracker may look at: boss frames and the target.
    G.UnitExists = function(unit) return world.units[unit] ~= nil end
    G.UnitIsPlayer = function(unit) return world.units[unit] ~= nil and world.units[unit].player == true end
    local unitName = G.UnitName
    G.UnitName = function(unit)
        if world.units[unit] then return world.units[unit].name end
        return unitName(unit)
    end
    -- The client draws a unit's face into a texture; here it leaves a mark.
    G.SetPortraitTexture = function(texture, unit)
        texture.face = unit
        world.portraits = world.portraits + 1
    end
end

local SM = { name = "Scarlet Monastery", type = "party", difficultyId = 1, difficultyName = "Normal", maxPlayers = 5, id = 189 }

local function resetWorld()
    world = { instance = nil, xp = 1000, xpMax = 5000, lock = { total = 3, complete = 0 }, units = {}, portraits = 0 }
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

local function relog(env, gap)
    env:dispatch("PLAYER_LOGOUT")
    return boot({ db = GuildweaverDB, serverTime = env.serverTime + (gap or 5), money = env.money, level = env.player.level })
end

local function pull(env)
    env:dispatch("PLAYER_REGEN_DISABLED")
end

local function kill(env, id, name)
    env:dispatch("ENCOUNTER_START", id, name, 1, 5)
    wait(env, 20)
    env:dispatch("ENCOUNTER_END", id, name, 1, 5, 1)
    env:dispatch("BOSS_KILL", id, name)
    world.lock.complete = world.lock.complete + 1
end

local function lastPayload(env)
    local newest
    for key, record in pairs(env:telemetry()) do
        if key:find("dungeon_run:", 1, true) == 1 then
            if not newest or record.envelope.payload.sequence > newest.envelope.payload.sequence then newest = record end
        end
    end
    return newest and newest.envelope.payload
end

local function timer(addon)
    return addon.DungeonSessions.Current().timer
end

-- The timer by hand and by combat ---------------------------------------------
do
    resetWorld()
    world.lock = { total = 2, complete = 0 }
    local env, addon = boot()
    local hud, sessions = addon.DungeonHud, addon.DungeonSessions
    zone(env, SM)
    local run = sessions.Current()
    equal(run.timer.state, "ready", "ready at entry")
    equal(run.timerSeconds, 0)
    equal(hud.StateText(run), "Starts on your first pull")
    contains(hud.lines, "0:00 ready", "the clock shows the state")
    equal(hud.timerButton:GetLabel(), "Start", "the button offers Start")
    wait(env, 60)
    run = sessions.Current()
    equal(run.timerSeconds, 0, "waiting before the first pull is not timed")
    truthy(run.durationSeconds >= 60, "but the run's elapsed time counts")

    pull(env)
    equal(timer(addon).state, "running", "the first pull starts the timer")
    equal(timer(addon).startedBy, "combat")
    equal(hud.timerButton:GetLabel(), "Pause", "a running timer offers Pause")
    wait(env, 100)
    equal(sessions.Current().timerSeconds, 100, "timed from the pull")
    -- Between run events only the clock text ticks, from the last timer.
    truthy(hud.shown.clock == "1:40" or hud.shown.clock == "1:39", "the clock ticks: " .. tostring(hud.shown.clock))
    hud:Refresh()
    contains(hud.lines, "1:40 ")

    -- Stop by the button; combat does not restart a timer stopped by hand.
    hud.timerButton:GetScript("OnClick")()
    equal(timer(addon).state, "stopped")
    equal(timer(addon).stoppedBy, "manual")
    wait(env, 50)
    pull(env)
    equal(timer(addon).state, "stopped", "a pull never restarts a stopped timer")
    equal(sessions.Current().timerSeconds, 100, "a stopped timer holds")
    contains(hud.lines, "1:40 paused")
    truthy(hud.StateText(sessions.Current()):find("^Paused"), "paused, not ended")
    equal(hud.timerButton:GetLabel(), "Resume", "a paused timer offers Resume")

    -- Start and stop by slash command.
    SlashCmdList.GUILDWEAVER("dungeon start")
    equal(timer(addon).state, "running")
    wait(env, 10)
    SlashCmdList.GUILDWEAVER("dungeon stop")
    equal(sessions.Current().timerSeconds, 110)
    equal(timer(addon).starts, 2)
    SlashCmdList.GUILDWEAVER("dungeon timer")
    equal(timer(addon).state, "running", "timer toggles")
    SlashCmdList.GUILDWEAVER("dungeon timer")
    equal(timer(addon).state, "stopped")

    -- A reload keeps the state and never counts offline time.
    local env2, addon2 = relog(env, 30)
    hud, sessions = addon2.DungeonHud, addon2.DungeonSessions
    equal(timer(addon2).state, "stopped", "state after reload")
    equal(sessions.Current().timerSeconds, 110, "seconds after reload")
    truthy(sessions.StartTimer(), "Start resumes")
    equal(sessions.StartTimer(), false, "already running")
    wait(env2, 5)
    equal(sessions.Current().timerSeconds, 115)

    -- Checkpoints carry the timer's time; the last boss stops the clock.
    sessions.Split("Courtyard")
    run = sessions.Current()
    equal(run.splits[1].at, 115, "split at the timer's time")
    truthy(run.splits[1].elapsedAt > 200, "and keeps the elapsed time apart")
    kill(env2, 1, "Houndmaster Loksey")
    kill(env2, 2, "Arcanist Doan")
    run = sessions.Current()
    equal(run.timer.state, "stopped", "the clear stops the timer")
    equal(run.timer.stoppedBy, "complete")
    equal(run.timerSeconds, 155)
    truthy(hud.StateText(run):find("^Cleared"), "the clear is shown")
    wait(env2, 30)
    equal(sessions.Current().timerSeconds, 155, "nothing after the clear is timed")
    equal(sessions.StopTimer(), false, "already stopped")

    zone(env2, nil)
    local payload = lastPayload(env2)
    equal(payload.status, "completed")
    equal(payload.timer.state, "stopped")
    equal(payload.timer.seconds, 155)
    equal(payload.timer.startedBy, "combat")
    equal(payload.timer.stoppedBy, "complete")
    equal(payload.timer.starts, 4, "pull, Start, the toggle, Start after reload")
    equal(payload.checkpoints[1].timerAt, 115)
    equal(payload.checkpoints[2].timerAt, 135)
    truthy(payload.durationSeconds > payload.timer.seconds, "elapsed time stays the online time since entry")
    equal(sessions.History()[1].timerSeconds, 155, "history keeps the timed run")
    equal(sessions.TimerState(), nil, "no run, no timer")
    equal(sessions.ToggleTimer(), nil)
end

-- The first encounter starts the timer; pace compares timed runs ----------------
do
    resetWorld()
    local env, addon = boot()
    local sessions = addon.DungeonSessions
    zone(env, SM)
    wait(env, 120)
    kill(env, 1, "Houndmaster Loksey")
    local run = sessions.Current()
    equal(run.timer.startedBy, "encounter", "a boss pull starts the timer too")
    equal(run.splits[1].at, 20, "the kill is 20 s into the timed run")
    truthy(run.splits[1].elapsedAt >= 140, "and about 140 s since entry")
end

-- A run saved before the timer existed has been running since entry ------------
do
    resetWorld()
    local env, addon = boot()
    zone(env, SM)
    wait(env, 100)
    local snapshot = addon.Character.GetCurrentSnapshot()
    GuildweaverDB.dungeon.active[snapshot.characterId].timer = nil
    local env2, addon2 = relog(env, 4)
    local run = addon2.DungeonSessions.Current()
    equal(run.timer.state, "running", "an older run's timer runs")
    equal(run.timer.startedBy, "entry")
    truthy(run.timerSeconds >= 100 and math.abs(run.timerSeconds - run.durationSeconds) < 1, "with the time already spent")
    wait(env2, 10)
    truthy(addon2.DungeonSessions.Current().timerSeconds >= 110, "and keeps counting")
end

-- The boss row: faces, the fight, splits named after the target ----------------
do
    resetWorld()
    local env, addon = boot()
    local hud, sessions = addon.DungeonHud, addon.DungeonSessions
    zone(env, SM)
    hud:SetMode("expanded")
    local entries = hud.Portraits(sessions.Current())
    equal(#entries, 3, "one entry per boss the lockout lists")
    equal(entries[1].kind, "pending")
    equal(#hud.rowEntries, 0, "no placeholder faces for bosses still up")
    truthy(hud.circles["pending:1"] == nil, "no question-mark circles")
    local progress = hud.BossProgress(sessions.Current())
    equal(progress.total, 3, "progress pips: three bosses")
    equal(progress.defeated, 0)
    truthy(hud.progressRow.shown, "the pips show")

    -- A boss fight: its circle takes the boss frame's face and health.
    env:dispatch("ENCOUNTER_START", 1, "Houndmaster Loksey", 1, 5)
    entries = hud.Portraits(sessions.Current())
    equal(entries[1].kind, "engaged", "the fight is in the row")
    equal(#entries, 3, "fight plus two still to kill")
    equal(hud.StateText(sessions.Current()), "Fighting Houndmaster Loksey")
    truthy(hud.engaged, "a circle for the fight")
    equal(hud.engaged.icon, hud.TEXTURES.boss, "an icon until the boss is on screen")
    world.units.boss1 = { name = "Houndmaster Loksey" }
    env:dispatch("INSTANCE_ENCOUNTER_ENGAGE_UNIT")
    equal(hud.engaged.unit, "boss1", "the boss frame is found by name")
    equal(hud.engaged.portrait.face, "boss1", "and its face drawn")
    equal(hud.engagedUnit, "boss1")
    truthy(hud.healthBar.shown, "its health shows")
    local drawn = world.portraits
    env:dispatch("UNIT_PORTRAIT_UPDATE", "boss1")
    equal(world.portraits, drawn + 1, "redrawn when the client says the portrait changed")
    env:dispatch("UNIT_HEALTH", "boss1")
    hud:Refresh()
    equal(world.portraits, drawn + 1, "the clock tick does not redraw a face")

    -- The kill: the fight's circle becomes the kill's, face and all.
    local fight = hud.engaged
    wait(env, 20)
    env:dispatch("ENCOUNTER_END", 1, "Houndmaster Loksey", 1, 5, 1)
    world.units.boss1 = nil
    world.lock.complete = 1
    truthy(hud.engaged == nil, "no fight after the kill")
    truthy(hud.circles["boss:1"] == fight, "the kill keeps the fight's circle")
    equal(hud.circles["boss:1"].portrait.face, "boss1")
    equal(hud.circles["boss:1"].entry.kind, "boss")
    truthy(not hud.healthBar.shown, "health hidden")
    entries = hud.Portraits(sessions.Current())
    equal(entries[1].kind, "boss")
    equal(entries[1].name, "Houndmaster Loksey")
    equal(#entries, 3, "one down, two to go")

    -- Split with an NPC targeted: named after it, with its face.
    world.units.target = { name = "Scarlet Guard" }
    hud.splitButton:GetScript("OnClick")()
    local run = sessions.Current()
    equal(run.splits[2].name, "Scarlet Guard", "the split takes the target's name")
    equal(run.splits[2].kind, "manual_split", "but is not a kill")
    equal(run.bossesDefeated, 1)
    local split = hud.circles["split:scarlet-guard"]
    truthy(split, "a circle for the split")
    equal(split.portrait.face, "target")
    equal(split.entry.kind, "split")
    equal(#hud.Portraits(run), 4, "boss, split, two to go")

    -- Split with a player targeted: a plain split, an icon, no face.
    world.units.target = { name = "Rook", player = true }
    sessions.Split()
    run = sessions.Current()
    equal(run.splits[3].name, "Split 2", "players never name a split")
    equal(hud.circles["split:split-2"].icon, hud.TEXTURES.split)
    truthy(not hud.circles["split:split-2"].hasFace)

    -- A named split keeps its label.
    world.units.target = nil
    SlashCmdList.GUILDWEAVER("dungeon split Stairs")
    equal(sessions.Current().splits[4].name, "Stairs")

    -- The row never grows past what fits: the oldest go first.
    hud:RefreshRow(sessions.Current(), "expanded", 80)
    truthy(#hud.rowEntries <= 2, "a narrow row shows fewer faces")
    equal(hud.rowEntries[#hud.rowEntries].id, "split:stairs", "the newest stays")
    hud:Refresh()
    -- Compact draws no faces at all, only the pips.
    hud:SetMode("compact")
    truthy(not hud.faces.shown, "no faces in compact")
    hud:SetMode("expanded")

    -- Tooltip on a circle.
    local tooltip = _G.GameTooltip
    local lines = {}
    tooltip.SetOwner = function() end
    tooltip.ClearLines = function() lines = {} end
    tooltip.AddLine = function(_, text) table.insert(lines, text) end
    hud.circles["boss:1"].frame:GetScript("OnEnter")()
    equal(lines[1], "Houndmaster Loksey")
    truthy(lines[2]:find("Defeated at", 1, true), "when it fell")

    -- A new run starts with an empty row.
    zone(env, nil)
    wait(env, sessions.REENTRY_SECONDS + 40)
    world.lock.complete = 0
    zone(env, SM)
    truthy(hud.circles["boss:1"] == nil, "circles of the old run are gone")
    truthy(hud.circles["split:scarlet-guard"] == nil)
    equal(#hud.Portraits(sessions.Current()), 3, "three to kill again")

    -- Minimized: no row, the clock and Start/Stop stay.
    hud:SetMode("minimized")
    equal(#hud.lines, 1)
    contains(hud.lines, "Bosses 0/3")
    truthy(not hud.row.shown, "no row when minimized")
    hud:SetMode("compact")
end

-- Combat: Start, Stop and Split call nothing protected -------------------------
do
    resetWorld()
    local env, addon = boot()
    for _, name in ipairs({ "CastSpellByName", "UseAction", "TargetUnit", "RunMacroText", "PickupContainerItem", "UseContainerItem" }) do
        _G[name] = function() env.protectedCalls = (env.protectedCalls or 0) + 1 end
    end
    env.inCombat = true
    env.protectedCalls = 0
    zone(env, SM)
    pull(env)
    addon.DungeonHud.timerButton:GetScript("OnClick")()
    addon.DungeonHud.timerButton:GetScript("OnClick")()
    addon.DungeonHud.splitButton:GetScript("OnClick")()
    env:dispatch("ENCOUNTER_START", 1, "Houndmaster Loksey", 1, 5)
    env:dispatch("PLAYER_TARGET_CHANGED")
    equal(addon.DungeonSessions.Current().timer.state, "running")
    equal(env.protectedCalls, 0, "no protected API calls")
    env.inCombat = false
end

print("dungeon timer and boss row tests passed")

do
    resetWorld()
    local env, addon = boot()
    local sessions = addon.DungeonSessions
    world.instance = SM
    env:dispatch("PLAYER_ENTERING_WORLD")
    pull(env)
    equal(sessions.TimerState(), "running", "immediate first pull")
    world.units.target = { name = "Scarlet Trainee" }
    equal(addon.DungeonHud.UnitFor(nil), nil)
    env:dispatch("ENCOUNTER_END", nil, nil, 1, 5, 1)
    env:dispatch("BOSS_KILL", 4, "Loksey")
    local run = sessions.Current()
    equal(run.bossesDefeated, 1)
    equal(run.splits[1].id, "boss:4")
    equal(run.splits[1].name, "Loksey")
    wait(env, 150)
    zone(env, nil)
    zone(env, SM)
    equal(sessions.Current().runId, run.runId)
    SlashCmdList.GUILDWEAVER("dungeon new")
    truthy(sessions.Current().runId ~= run.runId)
    equal(sessions.Current().bossesDefeated, 0)
    pull(env)
    wait(env, 150)
    zone(env, nil)
    wait(env, sessions.REENTRY_SECONDS + 60)
    local last = sessions.History()[1]
    truthy(last.timerSeconds <= last.durationSeconds)
end

do
    resetWorld()
    local env, addon = boot()
    local function clear(setup, seconds)
        world.lock.total, world.lock.complete = 1, 0
        zone(env, SM)
        wait(env, setup)
        pull(env)
        wait(env, seconds)
        env:dispatch("BOSS_KILL", 1, "Loksey")
        zone(env, nil)
    end
    clear(300, 150)
    clear(0, 180)
    local id = addon.Character.GetCurrentSnapshot().characterId
    equal(addon.DungeonSessions.PersonalBest(id, {instanceId = 189, difficultyId = 1}).timerSeconds, 150)
end
