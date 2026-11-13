-- Dungeon V2 in the fake client: HUD modes and their saved layout, live XP
-- across a level-up, exit and re-entry, reload recovery of a run started
-- by an older add-on, personal bests and pace, boss dedupe, manual splits,
-- objectives, and nothing protected touched in combat.

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
    -- Protected actions: an add-on calling any of these in combat is blocked
    -- by the client. The tracker must never call them at all.
    for _, name in ipairs({ "CastSpellByName", "UseAction", "TargetUnit", "RunMacroText", "PickupContainerItem", "UseContainerItem" }) do
        G[name] = function() env.protectedCalls = (env.protectedCalls or 0) + 1 end
    end
end

local SM = { name = "Scarlet Monastery", type = "party", difficultyId = 1, difficultyName = "Normal", maxPlayers = 5, id = 189 }
local SM_HEROIC = { name = "Scarlet Monastery", type = "party", difficultyId = 2, difficultyName = "Heroic", maxPlayers = 5, id = 189 }

local function resetWorld()
    world = { instance = nil, xp = 1000, xpMax = 5000, lock = { total = 3, complete = 0 } }
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

-- The first pull: the run timer starts here (see dungeon_timer_spec).
local function pull(env)
    env:dispatch("PLAYER_REGEN_DISABLED")
end

local function relog(env, gap)
    env:dispatch("PLAYER_LOGOUT")
    return boot({ db = GuildweaverDB, serverTime = env.serverTime + (gap or 5), money = env.money, level = env.player.level })
end

local function kill(env, id, name)
    env:dispatch("ENCOUNTER_START", id, name, 1, 5)
    wait(env, 20)
    env:dispatch("ENCOUNTER_END", id, name, 1, 5, 1)
    env:dispatch("BOSS_KILL", id, name)
    world.lock.complete = world.lock.complete + 1
end

-- A full clear: three bosses at `pace` seconds apart.
local function clear(env, pace)
    zone(env, SM)
    pull(env)
    wait(env, pace)
    kill(env, 1, "Houndmaster Loksey")
    wait(env, pace)
    kill(env, 2, "Arcanist Doan")
    wait(env, pace)
    kill(env, 3, "Herod")
    wait(env, 10)
    zone(env, nil)
    world.lock.complete = 0
end

local function lastPayload(env)
    local newest
    for key, record in pairs(env:telemetry()) do
        if key:find("dungeon_run:", 1, true) == 1 then
            if not newest or record.envelope.payload.startedAt > newest.envelope.payload.startedAt then newest = record end
        end
    end
    return newest and newest.envelope.payload
end

-- HUD modes, layout persistence and the 0.5 preference migration --------------
do
    resetWorld()
    local env, addon = boot()
    local hud = addon.DungeonHud
    -- A 0.5 install saved { expanded = true, width, height }.
    GuildweaverDB.ui = { dungeonHud = { enabled = true, expanded = true, width = 300, height = 90, point = "CENTER", relativePoint = "CENTER", x = 5, y = 6 } }
    equal(hud.Mode(), "expanded", "0.5 expanded becomes expanded mode")
    equal(GuildweaverDB.ui.dungeonHud.sizes.compact.width, 300, "0.5 size kept for compact")
    hud:SetMode("compact")

    zone(env, SM)
    pull(env)
    truthy(hud.visible, "HUD shows inside")
    equal(#hud.lines, 4, "compact: title, time/bosses/deaths, XP, PB")
    contains(hud.lines, "Scarlet Monastery (Normal)")
    contains(hud.lines, "Bosses 0/3")
    contains(hud.lines, "PB: none yet")

    hud:SetMode("minimized")
    equal(#hud.lines, 1, "minimized is one line")
    contains(hud.lines, "Bosses 0/3")
    hud:CycleMode()
    equal(hud.Mode(), "compact")
    hud:CycleMode()
    equal(hud.Mode(), "expanded")
    contains(hud.lines, "Wallet change", "expanded labels the wallet")
    contains(hud.lines, "(not profit)")
    contains(hud.lines, "Inside")
    hud:CycleMode()
    equal(hud.Mode(), "minimized", "cycle wraps")
    equal(GuildweaverDB.ui.dungeonHud.mode, "minimized", "mode is saved")
    SlashCmdList.GUILDWEAVER("dungeon mode full")
    equal(hud.Mode(), "expanded")

    -- Drag and resize: whatever the frame reports is saved for this mode.
    local frame = hud.frame
    frame.GetPoint = function() return "TOPLEFT", nil, "TOPLEFT", 40, -50 end
    frame.GetSize = function() return 280.6, 210.2 end
    frame:GetScript("OnDragStop")(frame)
    local saved = GuildweaverDB.ui.dungeonHud
    equal(saved.point, "TOPLEFT")
    equal(saved.x, 40)
    equal(saved.y, -50)
    equal(saved.sizes.expanded.width, 280, "resize saved for expanded")
    equal(saved.sizes.expanded.height, 210)
    equal(saved.sizes.compact.width, 300, "compact size untouched")

    -- Survives a reload.
    local env2, addon2 = relog(env, 3)
    equal(addon2.DungeonHud.Mode(), "expanded", "mode after reload")
    equal(GuildweaverDB.ui.dungeonHud.sizes.expanded.width, 280, "size after reload")
    truthy(addon2.DungeonHud.visible, "HUD back after reload inside the instance")
    addon2.DungeonHud:ResetPosition()
    equal(GuildweaverDB.ui.dungeonHud.point, "TOPRIGHT", "reset position")
    equal(GuildweaverDB.ui.dungeonHud.mode, "expanded", "reset keeps the mode")

    -- Redraws only when the text changes.
    local before = addon2.DungeonHud.redraws or 0
    addon2.DungeonHud:Refresh()
    addon2.DungeonHud:Refresh()
    equal(addon2.DungeonHud.redraws or 0, before, "same second, same text: no redraw")
    env2:advance(1)
    truthy((addon2.DungeonHud.redraws or 0) > before, "the clock redraws once a second")
end

-- Live XP across a level-up, exit and re-entry, deaths -----------------------
do
    resetWorld()
    local env, addon = boot()
    zone(env, SM)
    wait(env, 600)
    world.xp = 4000
    env:dispatch("PLAYER_XP_UPDATE", "player")
    local run = addon.DungeonSessions.Current()
    equal(run.xpGained, 3000, "live XP")
    truthy(run.xpPerHour and run.xpPerHour > 0, "XP/hour after five minutes")
    -- Level up: the rest of the old level, then what is into the new one.
    env.player.level = env.player.level + 1
    world.xp, world.xpMax = 700, 6000
    env:dispatch("PLAYER_LEVEL_UP", env.player.level)
    env:dispatch("PLAYER_XP_UPDATE", "player")
    run = addon.DungeonSessions.Current()
    equal(run.xpGained, 3000 + 1000 + 700, "XP across the level-up")
    equal(run.levelUps, 1)
    addon.DungeonHud:SetMode("expanded")
    contains(addon.DungeonHud.lines, "1 level-up")
    env:dispatch("PLAYER_DEAD")
    wait(env, 30)
    zone(env, nil)
    wait(env, 120)
    truthy(not addon.DungeonHud.visible, "hidden outside during the run back")
    zone(env, SM)
    run = addon.DungeonSessions.Current()
    equal(run.deaths, 1)
    truthy(run.insideSeconds < run.durationSeconds, "time outside is not inside time")
    truthy(addon.DungeonHud.visible, "back on re-entry")
end

-- Reload recovery of a run an older add-on started (no checkpoints saved) ----
do
    resetWorld()
    local env, addon = boot()
    zone(env, SM)
    wait(env, 100)
    kill(env, 1, "Houndmaster Loksey")
    addon.DungeonSessions.Split("Courtyard")
    -- What 0.5 saved: no checkpoints table, no name index.
    local snapshot = addon.Character.GetCurrentSnapshot()
    local saved = GuildweaverDB.dungeon.active[snapshot.characterId]
    saved.checkpoints = nil
    saved.bosses.killedNames = nil
    local env2, addon2 = relog(env, 4)
    env2:dispatch("BOSS_KILL", 1, "Houndmaster Loksey")
    wait(env2, 50)
    kill(env2, 2, "Arcanist Doan")
    local run = addon2.DungeonSessions.Current()
    equal(run.bossesDefeated, 2, "the replayed kill after reload is not counted again")
    equal(#run.splits, 3, "checkpoints rebuilt from the timeline, then continued")
    equal(run.splits[1].id, "boss:1")
    equal(run.splits[2].id, "split:courtyard")
    equal(run.splits[3].id, "boss:2")
end

-- Personal bests: only verified clears, same instance and difficulty ---------
do
    resetWorld()
    local env, addon = boot()
    clear(env, 300)
    local first = lastPayload(env)
    equal(first.status, "completed")
    local snapshot = addon.Character.GetCurrentSnapshot()
    local pb = addon.DungeonSessions.PersonalBest(snapshot.characterId, { instanceId = 189, difficultyId = 1 })
    truthy(pb, "a verified clear sets the PB")
    equal(pb.durationSeconds, first.durationSeconds)
    equal(#pb.checkpoints, 3)

    -- A second, faster run: pace against the PB at each checkpoint.
    zone(env, SM)
    pull(env)
    local run = addon.DungeonSessions.Current()
    equal(run.pb.durationSeconds, first.durationSeconds, "PB shown at entry")
    contains(addon.DungeonHud.lines, "PB ", "PB line")
    wait(env, 280)
    kill(env, 1, "Houndmaster Loksey")
    run = addon.DungeonSessions.Current()
    equal(run.splits[1].delta, -20, "20 s ahead at the first boss")
    equal(run.pace, -20)
    addon.DungeonHud:SetMode("compact")
    contains(addon.DungeonHud.lines, "20s ahead")
    addon.DungeonHud:SetMode("expanded")
    contains(addon.DungeonHud.lines, "Houndmaster Loksey")
    -- A manual split has no counterpart in the PB: no pace for it.
    addon.DungeonSessions.Split("Stairs")
    run = addon.DungeonSessions.Current()
    equal(run.splits[2].delta, nil, "no invented comparison")
    equal(run.pace, -20, "pace keeps the last real comparison")
    wait(env, 300)
    kill(env, 2, "Arcanist Doan")
    wait(env, 300)
    kill(env, 3, "Herod")
    zone(env, nil)
    world.lock.complete = 0
    pb = addon.DungeonSessions.PersonalBest(snapshot.characterId, { instanceId = 189, difficultyId = 1 })
    truthy(pb.durationSeconds < first.durationSeconds, "faster clear replaces the PB")

    -- Heroic has its own PB; a hand-finished partial run never sets one.
    zone(env, SM_HEROIC)
    equal(addon.DungeonSessions.Current().pb, nil, "no PB across difficulties")
    wait(env, 400)
    kill(env, 1, "Houndmaster Loksey")
    addon.DungeonSessions.Finish()
    equal(lastPayload(env).completion.basis, "manual")
    equal(addon.DungeonSessions.PersonalBest(snapshot.characterId, { instanceId = 189, difficultyId = 2 }), nil, "manual finish is not a PB")
end

-- Missing encounter data: no ids, no names; manual splits ---------------------
do
    resetWorld()
    world.lock = { total = 2, complete = 0 }
    local env, addon = boot()
    zone(env, SM)
    wait(env, 60)
    -- A client that reports kills without id or name, twice for one kill.
    env:dispatch("BOSS_KILL", nil, nil)
    env:dispatch("BOSS_KILL", nil, nil)
    local run = addon.DungeonSessions.Current()
    equal(run.bossesDefeated, 1, "a repeated anonymous report is one kill")
    wait(env, 120)
    env:dispatch("BOSS_KILL", nil, nil)
    equal(addon.DungeonSessions.Current().bossesDefeated, 2, "a later report is the next boss")
    addon.DungeonSessions.Split()
    addon.DungeonSessions.Split()
    run = addon.DungeonSessions.Current()
    equal(run.bossesDefeated, 2, "splits are not kills")
    equal(run.splits[3].name, "Split 1")
    equal(run.splits[4].id, "split:split-2")
    addon.DungeonSessions.Finish()
    local payload = lastPayload(env)
    equal(payload.bosses.duplicatesIgnored, 1)
    equal(#payload.checkpoints, 4)
    equal(payload.checkpoints[1].id, "boss:1-unnamed")
end

-- Objectives: manual list, current one in the HUD, proof-only auto-complete --
do
    resetWorld()
    local env, addon = boot()
    local objectives = addon.DungeonObjectives
    SlashCmdList.GUILDWEAVER("obj boss Herod")
    SlashCmdList.GUILDWEAVER("obj add Restock poisons")
    SlashCmdList.GUILDWEAVER("obj boss Courtyard")
    equal(#objectives.List(), 3)
    equal(objectives.Current().text, "Kill Herod")
    SlashCmdList.GUILDWEAVER("obj down 1")
    equal(objectives.Current().text, "Restock poisons", "reordered")
    SlashCmdList.GUILDWEAVER("obj edit 1 Restock 20 poisons")
    equal(objectives.List()[1].text, "Restock 20 poisons")
    SlashCmdList.GUILDWEAVER("obj done 1")
    equal(objectives.Current().text, "Kill Herod")
    zone(env, SM)
    addon.DungeonHud:SetMode("compact")
    contains(addon.DungeonHud.lines, "Next: Kill Herod", "current objective in the HUD")
    addon.DungeonSessions.Split("Courtyard")
    equal(objectives.List()[3].done, false, "a manual split is not proof")
    kill(env, 3, "Herod")
    equal(objectives.List()[2].done, true, "reported kill completes it")
    equal(objectives.List()[2].doneBy, "boss_kill")
    contains(addon.DungeonHud.lines, "Next: Kill Courtyard")
    SlashCmdList.GUILDWEAVER("obj remove 3")
    equal(#objectives.List(), 2)
    equal(objectives.Current(), nil)
    -- Per character: another character's list is separate.
    equal(#objectives.List("someone-else"), 0)
    -- Bounded.
    for index = 1, objectives.MAX + 2 do objectives.Add("o" .. index) end
    equal(#objectives.List(), objectives.MAX)
end

-- Combat: the tracker keeps working and calls nothing protected -------------
do
    resetWorld()
    local env, addon = boot()
    env.inCombat = true
    env.protectedCalls = 0
    zone(env, SM)
    wait(env, 30)
    kill(env, 1, "Houndmaster Loksey")
    addon.DungeonHud:CycleMode()
    addon.DungeonHud:SetMode("expanded")
    addon.DungeonHud.splitButton:GetScript("OnClick")()
    env:dispatch("PLAYER_DEAD")
    wait(env, 5)
    truthy(addon.DungeonHud.visible, "shown in combat")
    equal(addon.DungeonSessions.Current().bossesDefeated, 1)
    equal(#addon.DungeonSessions.Current().splits, 2, "Split works in combat")
    equal(env.protectedCalls, 0, "no protected API calls")
    env:dispatch("PLAYER_LOGOUT")
    equal(env.protectedCalls, 0)
    env.inCombat = false
end

print("dungeon HUD v2 tests passed")
