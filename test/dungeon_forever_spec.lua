-- WoW Forever's own dungeons in the addon: the exporter's Forever fields
-- (origin, coverage, floors, quests without known chains, drops kept by item
-- ID without facts), the packed item table, the packaged nine through the
-- guide, run tracking in them (unknown encounters never guess a clear),
-- saved runs that stay valid, and the catalog of instances the atlas does
-- not know (/gw dungeon catalog).
--
-- Instance 9002 is made up for these tests. Mocked client APIs prove the
-- addon's logic, not what the Forever client actually provides.

local Env = dofile("test/support/wow_env.lua")
local Export = dofile("scripts/exportDungeonAtlas.lua")

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

local function read(path)
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    return text
end

local function find(list, field, value)
    for _, entry in ipairs(list or {}) do if entry[field] == value then return entry end end
end

local FOREVER_IDS = { 2959, 2970, 2974, 2994, 2998, 2999, 3001, 3039, 3065 }

-- 1. The exporter: a Forever dungeon beside an original one ---------------------------
do
    local atlas = Export.decode(read("test/fixtures/atlas_mini.json"))
    local loot = Export.decode(read("test/fixtures/reference_loot_mini.json"))
    table.insert(atlas.dungeons, {
        instanceId = 3065, name = "The Hall of Thanes", kind = "dungeon", levelMin = 13, levelMax = 20, zoneName = "Ironforge", origin = "forever",
        entrance = { mapId = 1455, x = 0.277, y = 0.479 }, maps = {}, creatures = {}, rares = {}, quests = {},
        coverage = { identity = "client", bosses = "client-names", encounterIds = "none", npcIds = "partial", maps = "none", abilities = "none" },
        floorNames = { "The Hall of Thanes" },
        bosses = { { name = "Faldrim Anvilmar", npcId = 261306, abilities = {} }, { name = "Infurnus", abilities = {} } },
        provenance = { { source = "openmap-forever", tier = "forever-reference", confidence = "high" } },
    })
    table.insert(atlas.dungeons, {
        instanceId = 2974, name = "Blackmaw Hold", kind = "dungeon", levelMin = 20, levelMax = 28, origin = "forever", maps = {}, creatures = {},
        rares = {}, quests = {}, coverage = { encounterIds = "none" }, bosses = { { name = "Gorefang", abilities = {} } },
    })
    loot.gaps = {
        { instanceId = 3065, npcId = 261306, itemId = 270227 }, { instanceId = 3065, npcId = 261306, itemId = 270227 },
        { instanceId = 3065, npcId = 999999, itemId = 270230 }, { instanceId = 36, npcId = 644, itemId = 273289 },
    }
    local catalog = { schemaVersion = 1, dungeons = {
        { instanceId = 3065, curated = true, quests = {
            { questId = 96394, name = "The Restless Dead", relevance = "dungeon", level = 15, minLevel = 10, faction = "alliance", prerequisitesKnown = false },
            { questId = 96393, name = "Old Ironforge Incursion", relevance = "dungeon", level = 16, minLevel = 9, faction = "alliance", prerequisitesKnown = false },
            { questId = 1, name = "Somewhere Else", relevance = "zone", level = 15 } } },
        { instanceId = 2974, curated = false, quests = {} },
    } }
    local normalized, problems = Export.normalize(atlas, loot, nil, catalog)
    equal(#problems, 0, table.concat(problems, "; "))
    local text = Export.render(normalized, "7e9ab4642e2096c4db7e99921c882ad4f1a5c93e")
    contains(text, "quest-catalog.json", "the header names the quest catalog")
    local data = assert((loadstring or load)(text, "=generated"))("Guildweaver", {})
    equal(data.index[3065].origin, "forever")
    equal(data.index[36].origin, nil, "an original dungeon has no origin field")
    local hall = data.dungeons[3065]()
    equal(hall.origin, "forever")
    equal(hall.cov.enc, "none")
    equal(hall.cov.npc, "partial")
    equal(hall.floors[1], "The Hall of Thanes")
    equal(hall.qlist, nil, "a curated list: no qlist flag")
    equal(#hall.quests, 2, "zone quests are left out")
    equal(hall.quests[1].id, 96393, "lowest level first")
    equal(hall.quests[1].prek, false, "prerequisites not known")
    equal(hall.quests[1].fac, "A")
    local faldrim = find(hall.bosses, "name", "Faldrim Anvilmar")
    equal(table.concat(faldrim.unres, ","), "270227", "its drop by item ID, once")
    equal(faldrim.loot, nil, "no Classic item facts claimed")
    equal(find(hall.bosses, "name", "Infurnus").e, nil, "no encounter ID guessed")
    equal(table.concat(hall.unres, ","), "270230", "a drop whose creature is not a boss here stays on the dungeon")
    equal(data.items()[270227], nil, "an item without facts is never in the item table")
    local blackmaw = data.dungeons[2974]()
    equal(blackmaw.qlist, false, "no quest list: said, not shown as zero quests")
    equal(#blackmaw.quests, 0)
    local deadmines = data.dungeons[36]()
    equal(table.concat(find(deadmines.bosses, "npc", 644).unres, ","), "273289", "Forever's new drop in an original dungeon, by ID")
    equal(deadmines.origin, nil)

    -- The packed item table unpacks to what the facts say.
    local items = data.items()
    for id, fact in pairs(normalized.items) do
        local item = items[id]
        truthy(item, "item " .. id)
        equal(item.n, fact.name)
        equal(item.q, fact.quality)
        equal(item.s, fact.slot)
        equal(item.l, fact.itemLevel)
        equal(item.r, fact.requiredLevel)
        equal(item.sc, fact.subclass)
        equal(item.b, fact.bind)
        equal(item.set, fact.setName)
        equal(item.dps, fact.dps)
    end
    -- Deterministic.
    equal(Export.render(Export.normalize(Export.decode(read("test/fixtures/atlas_mini.json")), loot, nil, catalog), "7e9ab46"),
        Export.render(Export.normalize(Export.decode(read("test/fixtures/atlas_mini.json")), loot, nil, catalog), "7e9ab46"))
    local ok, message = pcall(Export.normalize, atlas, loot, nil, { schemaVersion = 2 })
    falsy(ok)
    contains(message, "quest catalog")
end

-- 2. The packaged nine -----------------------------------------------------------------
do
    local text = read("Data/DungeonAtlas.generated.lua")
    local data = assert((loadstring or load)(text, "=generated"))("Guildweaver", {})
    local items = data.items()
    local forever = 0
    for id, entry in pairs(data.index) do
        if entry.origin == "forever" then forever = forever + 1 end
        truthy(data.dungeons[id], id .. " builds")
    end
    equal(forever, 9, "nine WoW Forever dungeons")
    for _, id in ipairs(FOREVER_IDS) do
        local entry = data.index[id]
        truthy(entry and entry.origin == "forever", id .. " is a WoW Forever dungeon")
        local dungeon = data.dungeons[id]()
        truthy(dungeon.lmin and dungeon.lmax and #dungeon.bosses > 0, id .. ": level band and bosses")
        truthy(dungeon.cov, id .. ": what is known")
        truthy(data.keys[id], id .. ": a dungeon key")
        for _, boss in ipairs(dungeon.bosses) do
            equal(boss.loot, nil, id .. " " .. boss.name .. ": no Classic loot")
            equal(#(boss.ab or {}), 0, id .. " " .. boss.name .. ": no abilities claimed")
            for _, itemId in ipairs(boss.unres or {}) do equal(items[itemId], nil, "unresolved " .. itemId .. " has no facts") end
            if boss.e then truthy(boss.e == 3480 or boss.e == 3481, "only observed encounter IDs (" .. boss.e .. ")") end
        end
        if id == 2974 or id == 3001 then
            equal(dungeon.qlist, false, id .. ": no quest list")
        else
            truthy(#dungeon.quests > 0, id .. ": quests from the catalog")
            for _, quest in ipairs(dungeon.quests) do equal(quest.prek, false, id .. " quest " .. quest.id .. ": chain not known") end
        end
    end
    equal(data.encounters[3480], 2998)
    equal(data.encounters[3481], 2998)
    equal(data.keys[3065], "the-hall-of-thanes")
    equal(data.keys[36], "deadmines", "original keys unchanged")
    local wings = 0
    for _ in pairs(data.wings) do wings = wings + 1 end
    equal(wings, 11, "the 11 wings")
end

-- 3. In the fake client: guide, runs, saved runs, catalog --------------------------------
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
    G.GetInstanceLockTimeRemainingEncounter = nil
    G.C_LFGList = world.lfg
end

local HALL = { name = "The Hall of Thanes", type = "party", difficultyId = 1, difficultyName = "Normal", maxPlayers = 5, id = 3065 }
local NAMELESS = { name = "Nameless Crypt", type = "party", difficultyId = 1, difficultyName = "Normal", maxPlayers = 5, id = 9002 }

local function boot(db)
    world = world or {}
    world.instance, world.lock = nil, { total = 4, complete = 0 }
    local env = Env.new()
    local addon = env:load()
    installWorld()
    if db then GuildweaverDB = db end
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

local function kill(env, id, name)
    env:dispatch("ENCOUNTER_START", id, name, 1, 5)
    wait(env, 30)
    env:dispatch("ENCOUNTER_END", id, name, 1, 5, 1)
end

do
    world = { lfg = nil }
    local env, addon = boot()
    local guide, sessions, catalog = addon.DungeonGuide, addon.DungeonSessions, addon.DungeonCatalog
    truthy(guide.IsForever(3065))
    equal(guide.SourceNote(3065), guide.FOREVER_NOTE)
    equal(guide.SourceNote(36), guide.REFERENCE_NOTE)
    local hall = guide.Dungeon(3065)
    truthy(#guide.UnresolvedLoot(hall.bosses[1]) > 0, "the first boss's drops by item ID")
    equal(#guide.UnresolvedLoot({}), 0)
    equal(guide.NormalizeId("3065"), 3065, "a numeric route still works")
    equal(guide.DungeonKeyOf(3065), "the-hall-of-thanes")

    -- A run in a Forever dungeon: unknown encounters are kills, never a clear.
    zone(env, HALL)
    equal(guide.CurrentInstanceId(), 3065, "the atlas knows it now")
    truthy(sessions.Current(), "a run starts")
    -- The one open run (the saved table, not Current()'s summary).
    local run = select(2, next(GuildweaverDB.dungeon.active))
    kill(env, 777001, "Faldrim Anvilmar")
    local ledger = sessions.BossLedger(run)
    equal(ledger.unknown, 1, "an encounter the registry does not know: role unknown")
    equal(ledger.mandatoryTotal, nil, "no roster is guessed")
    falsy(sessions.IsComplete(run), "one unknown kill is not a clear")
    kill(env, 777002, "Infurnus")
    kill(env, 777003, "Plunder")
    kill(env, 777004, "Durgen Dirgehammer")
    falsy(sessions.IsComplete(run), "every listed name down is still not a clear without the client's word")
    -- The lockout says every encounter is down: that is the client's word.
    world.lock.complete = 4
    zone(env, nil)
    local entry = sessions.History()[1]
    equal(entry.status, "completed")
    equal(entry.completionBasis, "lockout")
    equal(guide.RunInstanceId(entry), 3065)

    -- The catalog: the Forever dungeon's client facts, an unknown instance.
    local saved = GuildweaverDB.dungeon.catalog
    equal(saved.forever[3065].name, "The Hall of Thanes")
    equal(saved.forever[3065].lockTotal, 4)
    zone(env, NAMELESS)
    equal(saved.candidates[9002].name, "Nameless Crypt", "an instance the atlas does not know is kept")
    equal(saved.candidates[9002].visits, 1)
    -- Combat never writes the catalog.
    env:dispatch("PLAYER_REGEN_DISABLED")
    env:dispatch("PLAYER_REGEN_ENABLED")
    equal(saved.candidates[9002].visits, 1, "not on the combat path")
    zone(env, nil)
    zone(env, NAMELESS)
    equal(saved.candidates[9002].visits, 2)
    zone(env, nil)
    -- Nothing is published: no telemetry carries a candidate.
    for key in pairs(env:telemetry()) do falsy(string.find(key, "catalog", 1, true), "no catalog telemetry: " .. key) end

    -- Bounded.
    for id = 1, catalog.MAX_CANDIDATES + 5 do
        catalog.Note({ instanceId = 50000 + id, name = "Fake " .. id, type = "party" })
        wait(env, 1)
    end
    local count = 0
    for _ in pairs(saved.candidates) do count = count + 1 end
    equal(count, catalog.MAX_CANDIDATES, "at most MAX_CANDIDATES")
    equal(saved.candidates[9002], nil, "the least recently seen go first")
    equal(catalog.Note({ instanceId = 36, name = "The Deadmines" }), "known", "an original dungeon is neither")

    -- The report, with and without an LFG activity list.
    local lines = table.concat(catalog.Report(), "\n")
    contains(lines, "35 instances (26 original, 9 WoW Forever)")
    contains(lines, "3065 The Hall of Thanes: 4 bosses in the atlas; client: \"The Hall of Thanes\", lockout 4 encounters")
    contains(lines, "2974 Blackmaw Hold")
    contains(lines, "not entered yet")
    contains(lines, "LFG activities: the client offers no activity list.")
    _G.C_LFGList = {
        GetAvailableActivities = function() return { 1, 2, 3 } end,
        GetActivityInfoTable = function(id)
            if id == 1 then return { mapID = 36, fullName = "The Deadmines" } end
            if id == 2 then return { mapID = 3100, fullName = "Barrow Deeps" } end
            error("no such activity")
        end,
    }
    lines = table.concat(catalog.Report(), "\n")
    contains(lines, "map 3100: Barrow Deeps (activity 2)", "an activity for a map the atlas lacks")
    falsy(string.find(lines, "map 36:", 1, true), "known maps are not listed")
    env.inCombat = true
    contains(table.concat(catalog.Report(), "\n"), "not scanned in combat")
    env.inCombat = false
    SlashCmdList.GUILDWEAVER("dungeon catalog")
    contains(table.concat(env.printed, "\n"), "WoW Forever", "/gw dungeon catalog prints the report")
    _G.C_LFGList = nil

    -- Saved runs stay valid across /reload with the new atlas.
    local db = GuildweaverDB
    local _, again = boot(db)
    local runs = again.DungeonGuide.Runs(3065)
    equal(#runs, 1, "the Hall of Thanes run is on its page")
    equal(runs[1].completionBasis, "lockout")
    equal(again.DungeonCatalog and GuildweaverDB.dungeon.catalog.forever[3065].visits, 1)
end

print("dungeon forever tests passed")
