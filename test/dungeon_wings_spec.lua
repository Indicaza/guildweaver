-- Dungeon wings in the fake client: the 11 wings of Holdfast's wing
-- manifest (test/fixtures/wing-manifest.json, a verbatim copy of Holdfast's
-- generated backend/src/Atlas/data/wing-manifest.json) in the packaged
-- atlas; each wing's bosses, floors, loot and quests in the journal; and the
-- run tracker naming a wing only from real evidence (a boss kill by
-- encounter ID, or a map floor of one wing), with per-wing progress,
-- completion and personal bests.
--
-- Mocked client APIs prove the addon's logic, not what the Forever client
-- sends: whether Forever's map floors carry these names is unverified.

local Env = dofile("test/support/wow_env.lua")
local Export = dofile("scripts/exportDungeonAtlas.lua")

local function equal(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function truthy(value, label)
    if not value then error((label or "value") .. ": expected truthy value", 2) end
end

local function falsy(value, label)
    if value then error((label or "value") .. ": expected falsy value, got " .. tostring(value), 2) end
end

local function read(path)
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    return text
end

local function names(list)
    local out = {}
    for _, entry in ipairs(list) do table.insert(out, entry.name) end
    return table.concat(out, ", ")
end

local WINGS = {
    "scarlet-monastery:graveyard", "scarlet-monastery:library", "scarlet-monastery:armory", "scarlet-monastery:cathedral",
    "blackrock-spire:lower", "blackrock-spire:upper", "stratholme:live", "stratholme:undead",
    "dire-maul:east", "dire-maul:west", "dire-maul:north",
}

local world

local function installWorld()
    local G = _G
    G.IsInInstance = function() return world.instance ~= nil, world.instance and world.instance.type or "none" end
    G.GetInstanceInfo = function()
        local instance = world.instance
        if not instance then return "Elwynn Forest", "none", 0, "", 0, 0, false, 0 end
        return instance.name, instance.type, instance.difficultyId, instance.difficultyName, instance.maxPlayers, 0, false, instance.id
    end
    G.UnitXP, G.UnitXPMax, G.GetMaxPlayerLevel = function() return 1000 end, function() return 5000 end, function() return 60 end
    G.GetNumGroupMembers = function() return 5 end
    G.GetInstanceLockTimeRemaining = function() return 3600, false, world.lock.total, world.lock.complete end
    G.GetInstanceLockTimeRemainingEncounter = nil
    G.EJ_GetInstanceForMap, G.EJ_SelectInstance, G.EJ_GetEncounterInfoByIndex, G.EJ_GetCreatureInfo = nil, nil, nil, nil
    G.InCombatLockdown = function() return world.combat == true end
    -- The map floor the player is on: a uiMap in a group whose members name their floors.
    G.C_Map = {
        GetBestMapForUnit = function() return world.floor and 7000 or nil end,
        GetMapGroupID = function() return world.floor and 70 or nil end,
        GetMapGroupMembersInfo = function() return world.floor and { { mapID = 6999, name = "Elsewhere" }, { mapID = 7000, name = world.floor } } or nil end,
    }
    G.UnitFactionGroup = function() return "Alliance" end
    G.SetPortraitTextureFromCreatureDisplayID = nil
end

local SM = { name = "Scarlet Monastery", type = "party", difficultyId = 1, difficultyName = "Normal", maxPlayers = 5, id = 189 }
local DM = { name = "Dire Maul", type = "party", difficultyId = 1, difficultyName = "Normal", maxPlayers = 5, id = 429 }
local STRAT = { name = "Stratholme", type = "party", difficultyId = 1, difficultyName = "Normal", maxPlayers = 5, id = 329 }
local DEADMINES = { name = "The Deadmines", type = "party", difficultyId = 1, difficultyName = "Normal", maxPlayers = 5, id = 36 }

local function boot(options)
    options = options or {}
    if not options.keepWorld then world = { instance = nil, lock = { total = options.total or 7, complete = 0 } } end
    local env = Env.new()
    local addon = env:load()
    installWorld()
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

local function kill(env, id, name, onLockout)
    env:dispatch("ENCOUNTER_START", id, name, 1, 5)
    wait(env, 30)
    env:dispatch("ENCOUNTER_END", id, name, 1, 5, 1)
    env:dispatch("BOSS_KILL", id, name)
    if onLockout then world.lock.complete = world.lock.complete + 1 end
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

-- 1. The packaged wings are Holdfast's manifest, exactly ------------------------------
do
    local atlas = dofile("Data/DungeonAtlas.generated.lua")
    local manifest = Export.decode(read("test/fixtures/wing-manifest.json"))
    local seen = {}
    for _, dungeon in ipairs(manifest.dungeons) do
        equal(atlas.keys[dungeon.instanceId], dungeon.dungeonKey, "dungeon key of " .. dungeon.instanceId)
        for index, wing in ipairs(dungeon.wings) do
            local packaged = atlas.wings[wing.dungeonKey]
            truthy(packaged, wing.dungeonKey .. " is packaged")
            seen[wing.dungeonKey] = true
            equal(atlas.wingOrder[dungeon.instanceId][index], wing.dungeonKey, "wing order")
            equal(packaged.i, dungeon.instanceId, "the game's instance ID")
            equal(packaged.parent, wing.parentKey)
            equal(packaged.name, wing.name)
            equal(packaged.lmin, wing.levelMin ~= Export.NULL and wing.levelMin or nil)
            equal(packaged.lsrc, wing.levelSource)
            equal(#packaged.npcs, #wing.bosses, wing.dungeonKey .. " bosses")
            for position, boss in ipairs(wing.bosses) do equal(packaged.npcs[position], boss.npcId) end
            equal(#packaged.rares, #wing.rares, wing.dungeonKey .. " rares")
            equal(table.concat(packaged.floors, "|"), table.concat(wing.floors, "|"), wing.dungeonKey .. " floors")
            equal(packaged.shared, wing.entrancesShared)
        end
    end
    local count = 0
    for key in pairs(atlas.wings) do
        count = count + 1
        truthy(seen[key], key .. " comes from the manifest")
    end
    equal(count, 11, "11 wings")
    for index, key in ipairs(WINGS) do truthy(atlas.wings[key], "wing " .. index .. " " .. key) end
    -- The exporter checks the manifest against the atlas: a boss it does not
    -- know, or one given to two wings, is a problem (the file is not written).
    local dungeons = { { id = 189, bosses = { { npcId = 3974, encounterId = 446 }, { npcId = 6487, encounterId = 447 } }, rares = {} } }
    local manifestOf = function(bosses)
        return { schemaVersion = 1, sources = {}, dungeons = { { instanceId = 189, dungeonKey = "scarlet-monastery", wings = {
            { dungeonKey = "scarlet-monastery:library", slug = "library", wing = "Library", name = "Library", bosses = bosses, rares = {}, floors = {}, entrances = {} },
        } } } }
    end
    local state = { problems = {} }
    local wings = Export.wingsOf(state, manifestOf({ { npcId = 3974 }, { npcId = 6487 } }), dungeons)
    equal(#state.problems, 0)
    equal(wings.wings["scarlet-monastery:library"].encounters[2], 447)
    Export.wingsOf(state, manifestOf({ { npcId = 3974 }, { npcId = 999999, name = "Nobody" } }), dungeons)
    equal(#state.problems, 1, "an unknown boss is reported")
    state = { problems = {} }
    Export.wingsOf(state, manifestOf({ { npcId = 3974 }, { npcId = 3974 } }), dungeons)
    equal(#state.problems, 1, "a boss twice is reported")
end

-- 2. Ids, grouping, floors, loot and quests in the journal's data ---------------------------
do
    local _, addon = boot()
    local guide = addon.DungeonGuide
    -- One instance ID, four keys; the dungeon itself stays reachable.
    for _, key in ipairs({ "scarlet-monastery:graveyard", "scarlet-monastery:library", "scarlet-monastery:armory", "scarlet-monastery:cathedral" }) do
        equal(guide.InstanceIdOf(key), 189, key)
        equal(guide.NormalizeId(key), key)
    end
    equal(guide.NormalizeId("189"), 189)
    equal(guide.NormalizeId("scarlet-monastery:crypt"), nil, "an unknown wing")
    equal(guide.DungeonKeyOf(36), "deadmines")
    equal(guide.DungeonKeyOf(189), "scarlet-monastery")
    falsy(guide.WingsOf(36), "a single dungeon has no wings")
    -- The list: wings instead of their dungeon; every other dungeon as before.
    local listed = {}
    for _, entry in ipairs(guide.List()) do listed[entry.id] = entry end
    for _, key in ipairs(WINGS) do truthy(listed[key], key .. " has a card") end
    for _, id in ipairs({ 189, 229, 329, 429 }) do falsy(listed[id], id .. " is listed as its wings") end
    truthy(listed[36] and listed[230] and listed[349], "single dungeons stay")
    equal(listed["scarlet-monastery:library"].name, "Scarlet Monastery \226\128\148 Library")
    equal(listed["scarlet-monastery:library"].lmin, 32)

    -- Bosses: the wing's own, never a sibling's.
    equal(names(guide.Dungeon("scarlet-monastery:library").bosses), "Houndmaster Loksey, Arcanist Doan")
    equal(names(guide.Dungeon("scarlet-monastery:armory").bosses), "Herod")
    equal(names(guide.Dungeon("scarlet-monastery:graveyard").rares), "Azshir the Sleepless, Fallen Champion, Ironspine")
    equal(#guide.Dungeon("scarlet-monastery:library").rares, 0)
    truthy(names(guide.Dungeon("dire-maul:north").bosses):find("King Gordok", 1, true))
    falsy(names(guide.Dungeon("dire-maul:north").bosses):find("Immol'thar", 1, true))
    equal(#guide.Dungeon(189).bosses, 7, "the dungeon page keeps every boss")
    -- What no wing owns stays on the dungeon and is named on each wing.
    equal(table.concat(guide.Dungeon("stratholme:live").unassigned, ", "), "Skul, Stonespine, Crimson Hammersmith, Black Guard Swordsmith, Ezra Grimm")
    equal(table.concat(guide.Dungeon("dire-maul:east").unassigned, ", "), "Lord Hel'nurath")
    for _, key in ipairs({ "stratholme:live", "stratholme:undead" }) do
        falsy(names(guide.Dungeon(key).bosses):find("Skul", 1, true), "unassigned bosses are in no wing")
    end

    -- Floors: the wing's named floors; pins only of its bosses, only on them.
    equal(#guide.Floors(189), 4)
    local library = guide.Floors("scarlet-monastery:library")
    equal(#library, 1)
    equal(library[1].n, "Library")
    equal(#guide.Floors("dire-maul:west"), 3)
    local undead = guide.Floors("stratholme:undead")
    equal(#undead, 1)
    equal(undead[1].n, "The Gauntlet")
    for _, pin in ipairs(guide.Pins("stratholme:undead")) do
        equal(pin.floor, 1, "on the wing's own floor")
        truthy(pin.creature.name ~= "Postmaster Malown", "Malown's journal pin is on another wing's floor: not placed")
    end
    truthy(#guide.Pins("stratholme:undead") >= 5, "the Gauntlet's bosses are pinned")
    for _, pin in ipairs(guide.Pins("dire-maul:west")) do
        truthy(names(guide.Dungeon("dire-maul:west").bosses):find(pin.creature.name, 1, true), "a West boss")
        truthy(pin.floor >= 1 and pin.floor <= 3, "a West floor")
    end
    -- Blackrock Spire: no floor names; the floors Blizzard's journal pins a wing's boss on.
    local upper = guide.Floors("blackrock-spire:upper")
    equal(#upper, 1)
    equal(upper[1].n, "Chamber of Battle")
    equal(names((function() local out = {} for _, pin in ipairs(guide.Pins("blackrock-spire:upper")) do table.insert(out, pin.creature) end return out end)()),
        "Pyroguard Emberseer", "only Upper's boss on the shared floor")
    truthy(#guide.Floors("blackrock-spire:lower") >= 5)

    -- Loot: the wing's bosses and rares; shared other loot; no sibling's drops.
    local rows = {}
    for _, row in ipairs(guide.LootRows("scarlet-monastery:library")) do rows[row.itemId] = row end
    truthy(rows[7714], "Arcanist Doan's loot")
    falsy(rows[7717], "Herod's loot is the Armory's")
    falsy(rows[7682], "Vishas' loot is the Graveyard's")
    truthy(rows[7723], "Mograine's drop (no boss of any wing in the atlas): shared")
    local doan = guide.FindBoss("scarlet-monastery:library", 447)
    truthy(doan, "the wing finds its boss")
    equal(guide.FindBoss("scarlet-monastery:library", 448), nil, "never a sibling's boss")
    -- Quests: the dungeon's, shared.
    equal(#guide.Quests("scarlet-monastery:library"), #guide.Quests(189))
    truthy(guide.Dungeon("scarlet-monastery:library").shared)
    -- Levels: the wing's band, or the dungeon's where no source gives one.
    equal(guide.Dungeon("stratholme:live").lmin, 56)
    equal(guide.Dungeon("stratholme:live").levelSource, "parent")
    equal(guide.Dungeon("scarlet-monastery:cathedral").entrance.map, 1422, "the wing's own entrance")
    -- Selection keeps the key apart from the ID.
    truthy(guide.Select("scarlet-monastery:library"))
    local prefs = addon.UiPrefs.Get("dungeonGuide")
    equal(prefs.instanceId, 189)
    equal(prefs.wingKey, "scarlet-monastery:library")
    equal(guide.SelectedInstanceId(), "scarlet-monastery:library")
    truthy(guide.Select(36))
    equal(prefs.wingKey, nil)
end

-- 3. The journal: wing cards, wing pages and deep links ---------------------------------
do
    local env, addon = boot()
    local main, guideUI, guide = addon.MainFrame, addon.DungeonGuideUI, addon.DungeonGuide
    main:Open()
    main:Select("dungeon", "nav")
    local view = main.views.dungeon
    equal(view.gwShownCards, #guide.List(), "every dungeon and wing has a card")
    local cards = view.browser.cards.items
    local function cardFor(id)
        for _, card in ipairs(cards) do if card.shown ~= false and card.gwData and card.gwData.id == id then return card end end
    end
    local library = cardFor("scarlet-monastery:library")
    truthy(library, "a Library card")
    equal(library.name.gwText, "Scarlet Monastery \226\128\148 Library")
    truthy(library.meta.gwText:find("Levels 32", 1, true))
    truthy(library.kind.gwText:find("2 BOSSES", 1, true))
    falsy(cardFor(189), "no combined card")
    truthy(cardFor(36), "Deadmines unchanged")
    -- Opening a wing card shows only its bosses.
    guideUI.Navigate(guideUI.Pages.dungeon("scarlet-monastery:library"))
    env:advance(1)
    equal(guideUI.CurrentPage().id, "scarlet-monastery:library")
    equal(view.dungeon.title.gwText, "Scarlet Monastery \226\128\148 Library")
    -- The HUD's link to a boss opens its wing's page on that boss.
    truthy(guideUI.OpenForEntry(189, { encounterId = 448, name = "Herod" }))
    env:advance(1)
    local page = guideUI.CurrentPage()
    equal(page.id, "scarlet-monastery:armory", "Herod opens on the Armory")
    equal(page.kind, "boss")
    equal(page.index, 1)
    -- The old numeric page still opens the whole dungeon.
    truthy(guideUI.Show(189))
    env:advance(1)
    equal(guideUI.CurrentPage().id, 189)
    equal(view.dungeon.title.gwText, "Scarlet Monastery")
    -- Back and forward walk the wing pages.
    guideUI.Back()
    env:advance(1)
    equal(guideUI.CurrentPage().id, "scarlet-monastery:armory")
end

-- 4. A run: the dungeon until a boss names the wing; per-wing progress and completion --------
do
    local env, addon = boot({ total = 7 })
    local sessions, hud, guide = addon.DungeonSessions, addon.DungeonHud, addon.DungeonGuide
    zone(env, SM)
    pull(env)
    wait(env, 120)
    local run = sessions.Current()
    equal(run.wing, nil, "entering names no wing")
    equal(run.name, "Scarlet Monastery", "the dungeon until evidence")
    equal(guide.CurrentGuideId(), 189, "the guide shows the dungeon, not a guessed wing")
    kill(env, 446, "Houndmaster Loksey")
    run = sessions.Current()
    equal(run.wing.key, "scarlet-monastery:library", "a Library boss names the wing")
    equal(run.wing.evidence, "boss_kill")
    equal(run.name, "Scarlet Monastery \226\128\148 Library")
    equal(guide.CurrentGuideId(), "scarlet-monastery:library")
    equal(run.classification.coverage, "reference")
    equal(hud.BossCountText(run), "1/2", "the wing's bosses, not the instance's 7")
    equal(run.classification.verification, "unknown", "short of the reference roster: unknown, not partial")
    falsy(run.complete)
    kill(env, 447, "Arcanist Doan")
    run = sessions.Current()
    equal(hud.BossCountText(run), "2/2")
    truthy(run.complete, "every boss of the wing")
    equal(run.classification.kind, "full_clear")
    equal(run.classification.verification, "unconfirmed", "a Classic reference roster never verifies")
    equal(run.timer.state, "stopped")
    truthy(hud.StateText(run):find("unverified", 1, true), hud.StateText(run))
    zone(env, nil)
    local payload = lastPayload(env)
    equal(payload.status, "completed")
    equal(payload.completion.basis, "none", "Holdfast accepts the wing basis only from #300 on")
    equal(payload.completion.claimed, "required_bosses_unconfirmed")
    equal(payload.wing.dungeonKey, "scarlet-monastery:library")
    equal(payload.wing.evidence, "boss_kill")
    equal(payload.wing.encounterId, 446)
    equal(payload.classification.wingKey, "scarlet-monastery:library")
    equal(payload.instance.instanceId, 189, "the game's instance ID")
    equal(sessions.PersonalBest(characterId(addon), { instanceId = 189, difficultyId = 1 }, "first_pull", "full_clear", "scarlet-monastery:library"), nil,
        "no personal best from Classic references")
    local entry = sessions.History()[1]
    equal(entry.wingKey, "scarlet-monastery:library")
    equal(entry.wingName, "Scarlet Monastery \226\128\148 Library")
    equal(guide.RunGuideId(entry), "scarlet-monastery:library")
    equal(#guide.Runs("scarlet-monastery:library"), 1)
    equal(#guide.Runs("scarlet-monastery:armory"), 0)
    equal(#guide.Runs(189), 1, "the dungeon lists every run of its instance")
end

-- 5. Ambiguous and unassigned evidence keep the dungeon ----------------------------------------
do
    local env, addon = boot({ total = 17 })
    local sessions = addon.DungeonSessions
    zone(env, DM)
    pull(env)
    kill(env, 349, "Immol'thar")
    equal(sessions.Current().wing.key, "dire-maul:west")
    kill(env, 368, "King Gordok")
    local run = sessions.Current()
    equal(run.wing, nil, "kills in West and North: no wing")
    truthy(run.wingAmbiguous)
    equal(run.name, "Dire Maul")
    equal(run.classification.coverage, "unknown")
    zone(env, nil)
    wait(env, sessions.REENTRY_SECONDS + 40)
    equal(lastPayload(env).wing, nil, "no wing sent")
    equal(sessions.History()[1].wingKey, nil)

    zone(env, STRAT)
    pull(env)
    kill(env, 2799, "Skul")
    equal(sessions.Current().wing, nil, "an unassigned boss names no wing")
    kill(env, 484, "Baron Rivendare")
    equal(sessions.Current().wing.key, "stratholme:undead")
end

-- 6. The map floor names a wing; a boss kill wins over it ------------------------------------
do
    local env, addon = boot({ total = 7 })
    local sessions = addon.DungeonSessions
    world.floor = "Library"
    zone(env, SM)
    local run = sessions.Current()
    equal(run.wing.key, "scarlet-monastery:library", "the client's floor name")
    equal(run.wing.evidence, "floor")
    -- In combat the floor is not read.
    world.floor, world.combat = "Armory", true
    env:dispatch("ZONE_CHANGED_INDOORS")
    equal(sessions.Current().wing.key, "scarlet-monastery:library")
    world.combat = false
    env:dispatch("ZONE_CHANGED_INDOORS")
    equal(sessions.Current().wing.key, "scarlet-monastery:armory", "a floor change out of combat")
    kill(env, 446, "Houndmaster Loksey")
    run = sessions.Current()
    equal(run.wing.key, "scarlet-monastery:library", "a boss kill overrides a floor")
    equal(run.wing.evidence, "boss_kill")
    -- A floor that is no wing's (or several wings') is no evidence.
    world.floor = "Hordemar City"
    zone(env, nil)
end

-- 7. A rare in the reference roster that never spawned: unknown, never partial or verified ------
do
    local env, addon = boot({ total = 6 })
    local sessions, hud = addon.DungeonSessions, addon.DungeonHud
    zone(env, DM)
    pull(env)
    for _, boss in ipairs({ { 350, "Tendris Warpwood" }, { 347, "Illyanna Ravenoak" }, { 348, "Magister Kalendris" }, { 349, "Immol'thar" },
        { 361, "Prince Tortheldrin" } }) do kill(env, boss[1], boss[2]) end
    local run = sessions.Current()
    equal(run.wing.key, "dire-maul:west")
    equal(hud.BossCountText(run), "5/6", "Tsu'zee (a rare spawn the reference lists) not seen")
    equal(run.classification.kind, "partial")
    equal(run.classification.verification, "unknown", "completion unknown, not a failure")
    equal(hud.ClassLabel(run.classification), "Completion unknown")
    falsy(run.complete)
end

-- 8. Lockout-proved clears keep their personal bests per wing ----------------------------------
do
    local env, addon = boot({ total = 2 })
    local sessions = addon.DungeonSessions
    local id = function() return characterId(addon) end
    zone(env, SM)
    pull(env)
    wait(env, 150)
    kill(env, 446, "Houndmaster Loksey", true)
    kill(env, 447, "Arcanist Doan", true)
    wait(env, 3)
    equal(sessions.Current().classification.kind, "hundred_clear", "the lockout proves it")
    zone(env, nil)
    local libraryPb = sessions.PersonalBest(id(), { instanceId = 189, difficultyId = 1 }, "first_pull", nil, "scarlet-monastery:library")
    truthy(libraryPb, "the Library's best")
    equal(sessions.PersonalBest(id(), { instanceId = 189, difficultyId = 1 }, "first_pull"), nil, "never filed as the whole dungeon's")
    world.lock = { total = 1, complete = 0 }
    wait(env, sessions.REENTRY_SECONDS + 40)
    zone(env, SM)
    pull(env)
    wait(env, 200)
    kill(env, 448, "Herod", true)
    wait(env, 3)
    zone(env, nil)
    local armoryPb = sessions.PersonalBest(id(), { instanceId = 189, difficultyId = 1 }, "first_pull", nil, "scarlet-monastery:armory")
    truthy(armoryPb, "the Armory's own best")
    truthy(armoryPb.runId ~= libraryPb.runId, "two wings, two bests")
    -- Deadmines keeps its key.
    world.lock = { total = 1, complete = 0 }
    zone(env, DEADMINES)
    pull(env)
    wait(env, 150)
    kill(env, 2747, "Edwin VanCleef", true)
    wait(env, 3)
    zone(env, nil)
    truthy(sessions.PersonalBest(id(), { instanceId = 36, difficultyId = 1 }, "first_pull"), "a single dungeon as before")
    equal(lastPayload(env).wing, nil)
end

-- 9. Reload during a run keeps its wing evidence; old history stays on the dungeon ------------
do
    local env, addon = boot({ total = 7 })
    zone(env, SM)
    pull(env)
    kill(env, 444, "Interrogator Vishas")
    local before = addon.DungeonSessions.Current()
    equal(before.wing.key, "scarlet-monastery:graveyard")
    env:dispatch("PLAYER_LOGOUT")
    local env2, addon2 = boot({ keepWorld = true, saved = { db = GuildweaverDB, serverTime = env.serverTime + 5 } })
    zone(env2, SM)
    local run = addon2.DungeonSessions.Current()
    equal(run.runId, before.runId, "the same run")
    equal(run.wing.key, "scarlet-monastery:graveyard", "its wing after /reload")
    -- A run recorded before wings existed: on the dungeon, never a wing.
    local guide = addon2.DungeonGuide
    local old = { runId = "old", name = "Scarlet Monastery", instanceKey = "i189:1", status = "completed", timerSeconds = 900, bossesDefeated = 2 }
    equal(guide.RunGuideId(old), 189)
    local history = addon2.DungeonSessions.History()
    table.insert(history, old)
    local inWing = false
    for _, entry in ipairs(guide.Runs("scarlet-monastery:library")) do if entry == old then inWing = true end end
    falsy(inWing, "not in any wing")
    local inDungeon = false
    for _, entry in ipairs(guide.Runs(189)) do if entry == old then inDungeon = true end end
    truthy(inDungeon, "on its dungeon")
    equal(old.wingKey, nil, "never rewritten")
end

-- 10. Kills in combat resolve the wing without building journal data ---------------------------
do
    local env, addon = boot({ total = 7 })
    local guide = addon.DungeonGuide
    -- Entering out of combat prebuilds the dungeon on purpose; here the
    -- player arrives fighting.
    world.combat = true
    zone(env, SM)
    pull(env)
    kill(env, 448, "Herod")
    equal(addon.DungeonSessions.Current().wing.key, "scarlet-monastery:armory")
    falsy(guide.IsBuilt(189), "no dungeon built for it")
    falsy(guide.IsBuilt("scarlet-monastery:armory"))
    world.combat = false
end

print("dungeon wing tests passed")
