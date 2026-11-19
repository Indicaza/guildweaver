-- The Dungeon Guide: the build-time exporter (Holdfast's atlas JSON -> Lua),
-- the packaged data's integrity and size, lookups by encounter/NPC/name,
-- ability ordering per role, wishlist and acquired state from LootSync,
-- current-instance detection, selection across /reload, the dashboard view,
-- the HUD's links into it, and what is (not) done in combat.
--
-- Fixtures: test/fixtures/atlas_mini.json and reference_loot_mini.json are a
-- real excerpt of Holdfast's atlas (Deadmines and Wailing Caverns), cut by
-- hand-free script; nothing in them is made up for the test.

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
    if value then error((label or "value") .. ": expected nil or false, got " .. tostring(value), 2) end
end

local function contains(text, needle, label)
    if type(text) ~= "string" or not string.find(text, needle, 1, true) then
        error((label or "text") .. ": " .. tostring(text) .. " does not contain " .. needle, 2)
    end
end

local function read(path)
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    return (string.gsub(text, "\r\n", "\n"))
end

local function loadGenerated(text)
    local chunk = assert((loadstring or load)(text, "=generated"))
    local holder = {}
    local data = chunk("Guildweaver", holder)
    return data, holder
end

local ATLAS = read("test/fixtures/atlas_mini.json")
local LOOT = read("test/fixtures/reference_loot_mini.json")
local COMMIT = "943fcdf01844efb4151a22f4ff5decfe8e78a75a"

-- Exporter: deterministic, valid Lua 5.1, nothing invented -----------------------------

do
    local first, problems = Export.run(ATLAS, LOOT, COMMIT)
    equal(#problems, 0, "the excerpt exports cleanly: " .. table.concat(problems, "; "))
    local second = Export.run(ATLAS, LOOT, COMMIT)
    equal(first, second, "the same inputs give byte-identical Lua")
    contains(first, COMMIT, "the source commit is in the file")
    local data, holder = loadGenerated(first)
    equal(holder.DungeonAtlasData, data, "the file registers GW.DungeonAtlasData")
    equal(data.schema, 1)
    equal(data.source.commit, COMMIT)
    truthy(data.source.lootRevision, "the loot file's revision is kept")
    truthy(#data.sources >= 2, "sources with licences")

    -- Index and lookups.
    equal(data.index[36].name, "Deadmines")
    equal(data.index[36].bosses, 3)
    equal(data.encounters[2747], 36, "VanCleef's encounter is the Deadmines'")
    equal(data.npcs[3586], 36, "a rare's NPC id maps to its dungeon")
    equal(type(data.dungeons[36]), "function", "detail is built on demand")

    local dm = data.dungeons[36]()
    local vancleef = dm.bosses[3]
    equal(vancleef.name, "Edwin VanCleef")
    equal(vancleef.e, 2747)
    equal(vancleef.npc, 639)
    equal(#vancleef.loot, 5, "VanCleef's reference loot")
    local items = data.items()
    equal(items[5191].n, "Cruel Barb")
    equal(items[5191].q, 3)
    falsy(items[5191].chance, "no drop chances anywhere")
    for id, item in pairs(items) do
        truthy(item.n, "item " .. id .. " has a name")
    end
    local spells = data.spells()
    local cookie = dm.bosses[2]
    local kicks = 0
    for _, spellId in ipairs(cookie.ab) do
        local spell = spells[spellId]
        truthy(spell, "every ability id has spell facts")
        falsy(spell.v, "nothing claims Forever verification")
        if spell.c == "interrupt" then
            equal(spell.k, true, "an interrupt spell is one the client marks interruptible")
            kicks = kicks + 1
        end
    end
    equal(kicks, 1, "Cookie has one interruptible cast")
    for _, quest in ipairs(dm.quests) do
        for _, itemId in ipairs(quest.rew or {}) do truthy(items[itemId], "quest reward " .. itemId .. " has facts") end
    end
    truthy(dm.layout and #dm.layout.pts % 4 == 0, "the layout is packed as 4 hex digits per cell")

    -- Without the loot file: same dungeons, no loot.
    local noLoot, noLootProblems = Export.run(ATLAS, nil, COMMIT)
    equal(#noLootProblems, 0)
    local bare = loadGenerated(noLoot)
    equal(bare.dungeons[36]().bosses[3].loot, nil, "no reference loot, no rows")
end

do
    -- Problems are reported, not papered over.
    local atlas = Export.decode(ATLAS)
    atlas.dungeons[1].bosses[2].abilities[1].verifiedForForever = true
    atlas.dungeons[2].bosses[1].encounterId = 2747
    local loot = Export.decode(LOOT)
    loot.items["5191"] = nil
    local _, problems = Export.normalize(atlas, loot)
    local text = table.concat(problems, "\n")
    contains(text, "claims Forever verification", "a Classic ability cannot claim Forever verification")
    contains(text, "encounter 2747 is in two dungeons")
    contains(text, "item 5191 has no facts", "an item id without facts is refused")
    local ok, message = pcall(Export.normalize, { schemaVersion = 2, dungeons = {} })
    falsy(ok)
    contains(message, "schemaVersion 1")
    -- JSON edge cases the atlas uses.
    local decoded = Export.decode('{"a":"Rhahk\\u0027Zor \\u00b7 x","b":[1,-2.5,1e2,null,true]}')
    equal(decoded.a, "Rhahk'Zor \194\183 x")
    equal(decoded.b[3], 100)
    equal(decoded.b[4], Export.NULL)
end

-- The packaged file: loads, bounded, consistent -----------------------------------------

do
    local text = read("Data/DungeonAtlas.generated.lua")
    truthy(#text < Export.MAX_BYTES, "the packaged atlas stays under " .. Export.MAX_BYTES .. " bytes (" .. #text .. ")")
    collectgarbage("collect")
    local before = collectgarbage("count")
    local data = loadGenerated(text)
    collectgarbage("collect")
    local atLogin = collectgarbage("count") - before
    truthy(atLogin < 1024, "at login the atlas costs under 1 MB of Lua memory (" .. math.floor(atLogin) .. " KB)")
    print(string.format("packaged atlas: %d bytes, %d KB of Lua memory at login", #text, math.floor(atLogin)))
    truthy(data.source.commit and #data.source.commit == 40, "a full Holdfast commit")
    local spells, items = data.spells(), data.items()
    local dungeons = 0
    for id, entry in pairs(data.index) do
        dungeons = dungeons + 1
        local dungeon = data.dungeons[id]()
        equal(dungeon.id, id)
        equal(#dungeon.bosses, entry.bosses, id .. ": index boss count")
        for _, list in ipairs({ dungeon.bosses, dungeon.trash, dungeon.rares }) do
            for _, creature in ipairs(list) do
                truthy(#(creature.ab or {}) <= Export.MAX_ABILITIES, "abilities bounded")
                for _, spellId in ipairs(creature.ab or {}) do
                    local spell = spells[spellId]
                    truthy(spell, id .. ": spell " .. spellId .. " has facts")
                    truthy(Export.CATEGORIES[spell.c], "known category")
                    falsy(spell.v, "nothing is verified on Forever yet")
                    if spell.c == "interrupt" then equal(spell.k, true, spell.n .. ": interrupt means the client marks it interruptible") end
                end
                for _, itemId in ipairs(creature.loot or {}) do truthy(items[itemId], "loot item " .. itemId .. " has facts") end
                if creature.x then truthy(creature.x >= 0 and creature.x <= 1000 and creature.y >= 0 and creature.y <= 1000, "positions in range") end
            end
        end
        for _, boss in ipairs(dungeon.bosses) do
            truthy(boss.name, id .. ": every boss keeps its name (encounter " .. tostring(boss.e) .. ")")
            if boss.e then equal(data.encounters[boss.e], id, "encounter lookup") end
        end
        for _, list in ipairs({ dungeon.trash, dungeon.rares, dungeon.quests }) do
            for _, named in ipairs(list) do truthy(named.name, id .. ": every entry keeps its name") end
        end
        truthy(#dungeon.quests <= Export.MAX_QUESTS, "quests bounded")
    end
    equal(dungeons, 26, "26 dungeons and raids")
end

-- The add-on in the fake client --------------------------------------------------------

local world
local DEADMINES = { name = "The Deadmines", type = "party", difficultyId = 1, difficultyName = "Normal", maxPlayers = 5, id = 36 }
local WAILING = { name = "Wailing Caverns", type = "party", difficultyId = 1, difficultyName = "Normal", maxPlayers = 5, id = 43 }
local UNKNOWN = { name = "Excavation Site: Wetlands", type = "party", difficultyId = 1, difficultyName = "Normal", maxPlayers = 5, id = 2998 }

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
    G.GetInstanceLockTimeRemaining = function() return 3600, false, 7, 0 end
    G.GetInstanceLockTimeRemainingEncounter = nil
    G.EJ_GetInstanceForMap, G.EJ_SelectInstance, G.EJ_GetEncounterInfoByIndex, G.EJ_GetCreatureInfo = nil, nil, nil, nil
    G.C_Map = nil
    G.UnitFactionGroup = function() return "Alliance" end
    G.UnitGroupRolesAssigned = nil
    for _, name in ipairs({ "RollOnLoot", "ConfirmLootRoll", "CastSpellByName", "UseAction", "TargetUnit", "RunMacroText" }) do
        G[name] = function() env.protectedCalls = (env.protectedCalls or 0) + 1 end
    end
end

local function fixtureInbox()
    local holder = {}
    assert(loadfile("test/fixtures/BridgeLoot.generated.lua"))("Guildweaver", holder)
    return holder.BridgeLoot
end

local function boot(options)
    options = options or {}
    world = { instance = nil }
    local env = Env.new()
    local addon = env:load()
    installWorld(env)
    env.protectedCalls = 0
    if options.db then GuildweaverDB = options.db end
    if options.inbox ~= false then addon.BridgeLoot = fixtureInbox() end
    env:login()
    env:advance(3)
    return env, addon
end

local function zone(env, instance)
    world.instance = instance
    env:dispatch("PLAYER_ENTERING_WORLD", false, false)
    env:advance(2)
end

-- Lookups and abilities.
do
    local env, addon = boot()
    local guide = addon.DungeonGuide
    truthy(guide.Available(), "the packaged atlas is loaded")
    falsy(guide.IsBuilt(36), "nothing is built at login")
    equal(guide.InstanceFor(2746), 36, "Cookie's encounter -> Deadmines")
    equal(guide.InstanceFor(nil, 3586), 36, "a rare's NPC -> Deadmines")
    equal(guide.InstanceFor(999999), nil)

    local boss, index, how = guide.FindBoss(36, 2747, "Somebody Else")
    equal(boss.name, "Edwin VanCleef")
    equal(how, "encounter", "the encounter ID wins over the name")
    truthy(index and index > 0)
    local _, _, byNpc = guide.FindBoss(36, nil, nil, 645)
    equal(byNpc, "npc")
    local byName, _, nameHow = guide.FindBoss(36, nil, "mr smite")
    equal(byName and byName.name, "Mr. Smite", "names match without case or punctuation")
    equal(nameHow, "name")
    equal(guide.FindBoss(36, 999, "Cookie"), nil, "a different known encounter ID is not overridden by a name")
    equal(guide.FindBoss(2998, 3480, "Saltspine"), nil, "a dungeon the atlas does not know has no guide")
    equal(guide.Dungeon(2998), nil)
    truthy(guide.IsBuilt(36), "built on first use")
    equal(guide.Dungeon(36), guide.Dungeon(36), "and cached")

    -- Labels: KICK only for an interruptible cast.
    equal(guide.Label({ c = "interrupt", k = true }), "KICK")
    equal(guide.Label({ c = "interrupt", k = false }), "CAST", "never claim a kick the data does not support")
    equal(guide.Label({ c = "interrupt" }), "CAST")
    equal(guide.Label({ c = "tank-danger" }), "TANK")
    equal(guide.Label({ c = "healer-danger" }), "HEAL")
    equal(guide.Label({ c = "dispel" }), "DISPEL")
    equal(guide.Label({ c = "positioning" }), "MOVE")
    equal(guide.Label({ c = "crowd-control" }), "CC")

    -- One order for everyone (no role switch), over the real spell table:
    -- dangerous interrupts, then major mechanics, then dispels and control.
    local spells = guide.Spells()
    local function first(category, kick)
        for id, spell in pairs(spells) do
            if spell.c == category and spell.p == "high" and (kick == nil or spell.k == kick) then return id end
        end
    end
    local creature = { ab = { first("crowd-control"), first("interrupt", true), first("healer-danger"), first("tank-danger") } }
    for _, id in ipairs(creature.ab) do truthy(id, "the atlas has high-priority spells of each kind") end
    local top, count = guide.TopMechanics(creature, nil, 4)
    equal(top[1].label, "KICK", "the dangerous interrupt first")
    equal(top[2].label, "HEAL", "then the major mechanics, in the atlas's order")
    equal(top[3].label, "TANK")
    equal(top[4].label, "CC", "then crowd control")
    equal(count, 4)
    equal(guide.TopMechanics(creature, "tank", 4)[1].label, "KICK", "a role no longer changes the order")
    equal(guide.Role(), nil, "there is no manual role")
    equal(#guide.OrderedAbilities(creature), 4, "every ability, ordered")
    local quiet = { ab = {} }
    equal(#guide.TopMechanics(quiet, nil, 4), 0, "no abilities, no mechanics")

    -- Current instance detection.
    equal(guide.CurrentInstanceId(), nil, "outside: none")
    zone(env, DEADMINES)
    equal(guide.CurrentInstanceId(), 36)
    zone(env, UNKNOWN)
    equal(guide.CurrentInstanceId(), nil, "an instance the atlas does not know")
    equal(env.protectedCalls, 0)
end

-- Wishlist and acquired state, read from LootSync.
do
    local _, addon = boot()
    local guide, sync = addon.DungeonGuide, addon.LootSync
    local rows = guide.LootRows(36)
    local barb
    for _, row in ipairs(rows) do if row.itemId == 5191 then barb = row end end
    truthy(barb, "Cruel Barb is reference loot in the Deadmines")
    equal(barb.from, "Edwin VanCleef")
    equal(barb.kind, "boss")
    truthy(barb.wanted, "and on Rook's website wishlist")
    equal(barb.wanted.priority, "high")
    falsy(barb.acquired)
    equal(guide.WantedCount(36), 1)
    local vancleef = guide.FindBoss(36, 2747)
    truthy(guide.HasWantedLoot(vancleef), "VanCleef carries a wanted drop")
    falsy(guide.HasWantedLoot(guide.FindBoss(36, 2746)), "Cookie does not")
    -- The wishlist's own source names a dungeon ("Wailing Caverns").
    local belt
    for _, row in ipairs(guide.LootRows(43)) do if row.itemId == 6468 then belt = row end end
    truthy(belt and belt.wanted, "a wanted item that names the dungeon shows there")
    -- Acquired: the game said so this session.
    sync.MarkAcquired("i:5191")
    for _, row in ipairs(guide.LootRows(36)) do if row.itemId == 5191 then barb = row end end
    truthy(barb.acquired, "acquired once the game reported it")
    equal(guide.WantedCount(36), 0, "acquired items stop counting")
end

-- Loot belongs to its source: each item once, never guessed onto a boss.
do
    local _, addon = boot()
    local guide = addon.DungeonGuide
    local dungeon = guide.Dungeon(36)
    local seen, total = {}, 0
    local function count(rows, label)
        for _, row in ipairs(rows) do
            falsy(seen[row.itemId], label .. ": item " .. row.itemId .. " listed once")
            seen[row.itemId] = label
            total = total + 1
        end
    end
    for _, list in ipairs({ dungeon.bosses, dungeon.rares, dungeon.trash }) do
        for _, creature in ipairs(list) do count(guide.SourceLoot(36, creature), creature.name) end
    end
    count(guide.OtherLoot(36), "other")
    equal(seen[1937], "Sneed's Shredder", "a drop the atlas names a listed creature for goes to it")
    equal(seen[1930], "other", "a source the atlas lists no creature for stays under other")
    equal(seen[1951], "other", "no source: other")
    equal(seen[5191], "Edwin VanCleef")
    local reference = 0
    for _, row in ipairs(guide.LootRows(36)) do if row.kind ~= "wishlist" then reference = reference + 1 end end
    equal(total, reference, "no reference item is dropped or invented")
end

-- No website wishlist: nothing is wanted, nothing breaks.
do
    local _, addon = boot({ inbox = false })
    local guide = addon.DungeonGuide
    equal(guide.WantedCount(36), 0)
    truthy(#guide.LootRows(36) > 0, "reference loot still lists")
end

-- Selection survives /reload; the guide follows the instance unless the player picked.
do
    local env, addon = boot()
    local guide = addon.DungeonGuide
    truthy(guide.Select(43))
    equal(guide.SelectedInstanceId(), 43)
    falsy(guide.Select(2998), "a dungeon the atlas does not know cannot be picked")
    local saved = GuildweaverDB
    local env2, again = boot({ db = saved })
    equal(again.DungeonGuide.SelectedInstanceId(), 43, "the pick is kept across /reload")
    zone(env2, DEADMINES)
    equal(again.DungeonGuide.SelectedInstanceId(), 36, "inside a known dungeon the guide follows it")
    again.DungeonGuide.Select(43)
    equal(again.DungeonGuide.SelectedInstanceId(), 43, "picking another dungeon inside stops following")
    again.DungeonGuide.FollowCurrent()
    equal(again.DungeonGuide.SelectedInstanceId(), 36)
    local _ = env
end

-- The dashboard view: built on first open, every page, empty states.
do
    local env, addon = boot()
    local main, guideUI = addon.MainFrame, addon.DungeonGuideUI
    local hasGuide = false
    for _, entry in ipairs(main.NAV) do if entry.key == "guide" then hasGuide = true end end
    falsy(hasGuide, "one Dungeons entry: no separate Dungeon Guide")
    falsy(main.views, "nothing built before the window opens")
    truthy(guideUI.Show(36, 3))
    local view = main.views.dungeon
    truthy(view, "the journal is built on open")
    equal(main:Select("guide"), "dungeon", "the old key opens the journal")
    local page = view.dungeon
    equal(page.title.gwText, "Deadmines")
    equal(page.name.gwText, "Gilnid", "the boss's page")
    for _, tab in ipairs({ "quests", "runs", "overview" }) do
        page.tabs.buttons[({ overview = 1, quests = 2, runs = 3 })[tab]]:Click()
        equal(guideUI.CurrentPage().tab, tab)
    end
    -- Overview: the client's map of the floor, drawn once, reused.
    local map = page.map
    equal(map.gwDrawn, "36:2", "the floor of the boss last shown (Gilnid, Ironclad Cove)")
    equal(#map.tiles, 12, "from 12 tiles")
    map.bar.prev:GetScript("OnClick")()
    equal(map.gwDrawn, "36:1", "the floor arrow turns to the first floor")
    contains(map.bar.label.gwText, "1/2", "the floor bar names the floor")
    main:RefreshView()
    equal(#map.tiles, 12, "redrawing creates nothing new")
    -- A dungeon without quests or runs: the empty states.
    guideUI.Navigate(guideUI.Pages.dungeon(47, "quests"))
    contains(page.empty.gwText, "No quests")
    guideUI.Navigate(guideUI.Pages.dungeon(47, "runs"))
    contains(page.empty.gwText, "No finished runs")
    -- Rares and dangerous trash in the list, each with its own page.
    guideUI.Show(36)
    equal(page.smallRows.items[1].name.gwText, "Miner Johnson")
    page.smallRows.items[1]:GetScript("OnClick")(page.smallRows.items[1])
    contains(page.facts.gwText, "Rare elite")
    truthy(page.detailBadge.gwLines, "the reference indicator on every page")
    -- No role switch, no loot tab, no paging.
    equal(rawget(view, "role"), nil, "no Any / Tank / Heal / DPS")
    equal(rawget(view, "tabBar"), nil, "no Loot tab")
    for _, button in ipairs(page.tabs.buttons) do falsy(button.label.gwText == "Loot", "no Loot tab") end
    equal(env.protectedCalls, 0)
end

-- Combat: nothing large is created mid-fight; the map waits for the end.
do
    local env, addon = boot()
    local main, guideUI = addon.MainFrame, addon.DungeonGuideUI
    env.inCombat = true
    falsy(guideUI.Show(36), "the journal is not built in combat")
    falsy(main.views and main.views.dungeon, "no view created")
    env.inCombat = false
    guideUI.Show(43)
    env.inCombat = true
    truthy(guideUI.Show(36), "an already built journal may be shown")
    local map = main.views.dungeon.dungeon.map
    falsy(map.gwDrawn == "36:1", "the map's art is not set in combat")
    truthy(guideUI.pending)
    contains(map.empty.gwText, "after combat")
    env.inCombat = false
    env:dispatch("PLAYER_REGEN_ENABLED")
    equal(map.gwDrawn, "36:1", "drawn when combat ends")
    equal(env.protectedCalls, 0)
end

-- Performance: every dungeon, every page, no item or tooltip scans, no
-- OnUpdate handlers, bounded frames, one build per dungeon.
do
    local env, addon = boot()
    local main, guideUI, guide = addon.MainFrame, addon.DungeonGuideUI, addon.DungeonGuide
    local function onUpdates()
        local count = 0
        for _, frame in ipairs(env.frames) do
            if frame.scripts.OnUpdate then count = count + 1 end
        end
        return count
    end
    local updatesBefore = onUpdates()
    env:resetCalls()
    guideUI.Show(36)
    local framesAfterFirst = #env.frames
    local builds = 0
    local build = guide.Dungeon
    guide.Dungeon = function(id)
        if not guide.IsBuilt(id) then builds = builds + 1 end
        return build(id)
    end
    local pages = 0
    for _, entry in ipairs(guide.List()) do
        guideUI.Navigate(guideUI.Pages.dungeon(entry.id))
        guideUI.Navigate(guideUI.Pages.dungeon(entry.id, "quests"))
        guideUI.Navigate(guideUI.Pages.dungeon(entry.id, "runs"))
        local dungeon = build(entry.id)
        for index = 1, #dungeon.bosses do guideUI.Navigate(guideUI.Pages.creature(entry.id, "boss", index)) end
        for index = 1, #dungeon.trash do guideUI.Navigate(guideUI.Pages.creature(entry.id, "trash", index)) end
        pages = pages + 3 + #dungeon.bosses + #dungeon.trash
    end
    guideUI.Navigate(guideUI.Pages.browser())
    guide.Dungeon = build
    truthy(builds <= #guide.List(), "each dungeon is built at most once")
    equal(onUpdates(), updatesBefore, "the journal adds no OnUpdate handlers")
    equal(env:itemTooltipScans(), 0, "no item tooltip scans")
    equal(env:callCount("GetItemInfo"), 0, "no item info queries")
    -- Frames: pools grow to the largest list shown, then are reused.
    local grown = #env.frames - framesAfterFirst
    for _, entry in ipairs(guide.List()) do guideUI.Navigate(guideUI.Pages.dungeon(entry.id)) end
    equal(#env.frames - framesAfterFirst, grown, "a second pass creates nothing")
    truthy(grown <= 400, "bounded pools (" .. grown .. ")")
    equal(#main.views.dungeon.dungeon.map.tiles, 12, "the map's 12 tiles are reused for every dungeon")
    -- Scrolling only moves the offset.
    local list = main.views.dungeon.dungeon.list
    local before = #env.frames
    for _ = 1, 20 do list:GetScript("OnMouseWheel")(list, -1) end
    equal(#env.frames, before, "no frames while scrolling")
    collectgarbage("collect")
    print(string.format("journal: %d dungeons, %d pages, %d frames after the first open, %d map pins pooled, %d KB Lua memory in the fake client",
        #guide.List(), pages, grown, #main.views.dungeon.dungeon.map.pins, math.floor(collectgarbage("count"))))
end

-- The HUD: Guide button, boss faces with mechanics and a click into the guide.
do
    local env, addon = boot()
    local hud, sessions, main = addon.DungeonHud, addon.DungeonSessions, addon.MainFrame
    zone(env, DEADMINES)
    env:dispatch("PLAYER_REGEN_DISABLED")
    env:dispatch("PLAYER_REGEN_ENABLED")
    env:dispatch("ENCOUNTER_START", 2746, "Cookie", 1, 5)
    env.serverTime = env.serverTime + 30
    env:advance(30)
    env:dispatch("ENCOUNTER_END", 2746, "Cookie", 1, 5, 1)
    hud:SetMode("expanded")
    hud:Refresh()
    truthy(hud.guideButton, "the HUD has a Guide button")
    local entries = hud.Portraits(sessions.Current())
    equal(entries[1].encounterId, 2746, "a kill's face knows its encounter")
    local lines = {}
    local tooltip = _G.GameTooltip
    tooltip.SetOwner = function() end
    tooltip.ClearLines = function() lines = {} end
    tooltip.AddLine = function(_, text) table.insert(lines, text) end
    tooltip.Show = function() end
    -- Out of combat the tooltip reads (and builds) the guide's boss.
    hud.circles["boss:2746"].frame:GetScript("OnEnter")()
    equal(lines[1], "Cookie")
    contains(table.concat(lines, "\n"), "KICK", "the face's tooltip shows Cookie's kick")
    contains(table.concat(lines, "\n"), "unverified on Forever")
    -- A click opens the guide on that boss.
    hud.circles["boss:2746"].frame:GetScript("OnClick")()
    equal(main.current, "dungeon")
    equal(main.views.dungeon.dungeon.name.gwText, "Cookie", "the face opens that boss's page")
    -- The expanded HUD's guide line (the next boss) and the timer still there.
    local section = addon.DungeonGuideUI.hudSection
    truthy(section.frame, "the guide line exists in the HUD")
    truthy(hud.clock and hud.timerButton, "the timer is untouched")
    equal(env.protectedCalls, 0)
    -- In combat, the HUD never builds a dungeon it has not built.
    addon.DungeonGuide.Reset()
    env.inCombat = true
    lines = {}
    hud.circles["boss:2746"].frame:GetScript("OnEnter")()
    falsy(addon.DungeonGuide.IsBuilt(36), "no build in combat")
    equal(lines[1], "Cookie", "the plain tooltip still shows")
    env.inCombat = false
end

-- Wailing Caverns, no wanted loot: unknown fields stay empty, nothing crashes.
do
    local env, addon = boot()
    local guideUI = addon.DungeonGuideUI
    zone(env, WAILING)
    truthy(guideUI.Show())
    equal(addon.MainFrame.views.dungeon.dungeon.title.gwText, "Wailing Caverns", "the journal opens on the dungeon the player is in")
end

print("dungeon guide tests passed")
