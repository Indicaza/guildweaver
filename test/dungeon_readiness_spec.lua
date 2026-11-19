-- Dungeon quest readiness in game: the packaged quest catalog
-- (Data/DungeonQuests.generated.lua, scripts/exportDungeonQuests.lua) and the
-- readiness rules (Systems/DungeonReadiness.lua).
--
-- Parity: test/fixtures/readiness-parity.json holds cases Holdfast's own
-- engine (backend/src/Atlas/atlasReadiness.js) computed over the same
-- catalog: dungeons, wings, Forever dungeons, a dungeon without a list,
-- and character states (nothing reported, full lists, checked-only, an
-- unread log, other faction, class rules, unknown facts). Every case must
-- come out the same here, quest by quest: one set of rules, not two.
-- Regenerate the fixture with Holdfast when its catalog or rules change
-- (docs/dungeon-guide.md, "Quest readiness").

local Env = dofile("test/support/wow_env.lua")
local Export = dofile("scripts/exportDungeonAtlas.lua")
local Quests = dofile("scripts/exportDungeonQuests.lua")

local function equal(actual, expected, label)
    if actual ~= expected then error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2) end
end

local function truthy(value, label)
    if not value then error((label or "value") .. ": expected truthy value", 2) end
end

local function read(path)
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    return text
end

local null = Export.decode("null")
local function present(value) if value ~= null then return value end end

-- 1. The packaged catalog ------------------------------------------------------------------
local env = Env.new()
local addon = env:load()
local R = addon.DungeonReadiness
local source = R.Source()
truthy(R.Available(), "the quest catalog is packaged")
equal(source.quests, 753, "every quest a dungeon shows by default")
equal(source.dungeons, 35, "every atlas dungeon")
equal(source.zoneQuestsLeftOut, 159, "zone-only quests are left out, as the website hides them")
local text = read("Data/DungeonQuests.generated.lua")
truthy(#text < Quests.MAX_BYTES, "under its budget")
equal(string.find(text, "objective", 1, true), nil, "no objectives (the atlas file has them)")

-- Facts kept as the catalog says them.
local warriorMage = R.Quest(8966)
equal(table.concat(warriorMage.classes, ","), "WARRIOR,MAGE", "class rules")
equal(warriorMage.prerequisites[1].questId, 8962)
local thanes = R.Quest(98423)
equal(thanes.prerequisitesKnown, false, "a Forever quest's chain stays unknown")
equal(thanes.faction, "alliance")
local riots = R.Quest(391)
equal(riots.giver, "Warden Thelwater")
equal(riots.zone, "Stormwind City")
equal(riots.x, 411, "permille")
local unknownFaction = 0
for _, questId in ipairs(R.AllQuestIds()) do
    if not R.Quest(questId).factionKnown then unknownFaction = unknownFaction + 1 end
end
truthy(unknownFaction > 0, "an unknown faction stays unknown (not 'both')")
equal(#R.AllQuestIds(), 753)
-- Wings: Lower Spire leaves out the Upper Spire's quest, both keep shared ones.
local function ids(catalog)
    local set = {}
    for _, entry in ipairs(catalog.entries) do set[entry.quest.questId] = entry.relevance end
    return set
end
local lower, upper = ids(R.Catalog("blackrock-spire:lower")), ids(R.Catalog("blackrock-spire:upper"))
truthy(lower[5081] and not lower[5102], "Lower Spire")
truthy(upper[5102] and not upper[5081], "Upper Spire")
equal(lower[4729], "dungeon", "shared by both wings")
equal(R.Catalog(2974).curated, false, "Blackmaw Hold: no list")
equal(R.Catalog(1), nil, "no catalog entry")
-- No silent cut: Uldaman's 86 shown quests are all here (the old atlas list stopped at 40).
equal(#R.Catalog(70).entries, 86, "Uldaman, every quest shown by default")

-- The exporter: deterministic, refuses what it cannot keep.
local mini = { schemaVersion = 1, dungeons = {
    { instanceId = 36, curated = true, quests = {
        { questId = 166, name = "The Defias Brotherhood", relevance = "dungeon", level = 22, minLevel = 14, faction = "alliance",
          prerequisites = { { questId = 155, name = "Part 6" }, { questId = 9, mustBeActive = true } }, prerequisitesKnown = true,
          giver = { name = "Gryan Stoutmantle", location = { zoneName = "Westfall", x = 0.56, y = 0.47 } } },
        { questId = 155, name = "Part 6", relevance = "prerequisite", level = 22 }, -- faction null in JSON: absent
        { questId = 7, name = "A Turn-in", relevance = "zone" } } },
} }
local normalized, problems = Quests.normalize(mini)
equal(#problems, 0, table.concat(problems, "; "))
local rendered = Quests.render(normalized, "abc")
equal(rendered, Quests.render(Quests.normalize(mini), "abc"), "byte-identical output")
local G = {}
assert((loadstring or load)(rendered, "=quests"))("Guildweaver", G)
truthy(G.DungeonQuestData, "the file defines GW.DungeonQuestData")
local tables = G.DungeonQuestData.load()
equal(tables.quests[166][1], "The Defias Brotherhood")
equal(tables.quests[166][14][2], -9, "mustBeActive is kept")
equal(tables.quests[155][5], false, "faction unknown, not both")
equal(tables.quests[7], nil, "zone quests left out")
equal(G.DungeonQuestData.source.zoneQuestsLeftOut, 1)
local _, bad = Quests.normalize({ schemaVersion = 1, dungeons = { { instanceId = 1, quests = { { questId = 1, name = "x", relevance = "weird" } } } } })
equal(#bad, 1, "an unknown relevance stops the export")
local _, badSchema = Quests.normalize({ schemaVersion = 2, dungeons = {} })
equal(#badSchema, 1, "an unknown catalog schema stops the export")

-- 2. Parity with Holdfast ------------------------------------------------------------------
local fixture = Export.decode(read("test/fixtures/readiness-parity.json"))
local function set(list)
    local out = {}
    for _, id in ipairs(present(list) or {}) do out[id] = true end
    return out
end
local function stateOf(raw)
    return {
        faction = present(raw.faction), race = present(raw.race), classToken = present(raw.classToken), level = present(raw.level),
        completed = { coverage = raw.completed.coverage, ids = set(raw.completed.questIds), checked = set(raw.completed.checkedQuestIds) },
        questLog = { coverage = raw.questLog.coverage, ids = set(raw.questLog.questIds) },
    }
end
local function compareGroup(expected, actual, label)
    equal(#actual, #expected, label .. " size")
    for index, row in ipairs(expected) do
        local got = actual[index]
        equal(got.quest.questId, row[1], label .. " #" .. index .. " id")
        equal(got.state, row[2], label .. " quest " .. row[1] .. " state")
        equal(table.concat(got.reasons, "|"), table.concat(row[3], "|"), label .. " quest " .. row[1] .. " reasons")
    end
end
local checked, seen = 0, {}
for _, case in ipairs(fixture.cases) do
    local guide = case.guide
    local label = tostring(guide) .. "/" .. case.state
    local result = R.ForGuide(guide, stateOf(fixture.states[case.state]))
    if case.missing then
        equal(result, nil, label .. " has no catalog entry")
    else
        truthy(result, label)
        equal(result.readiness, case.readiness, label .. " readiness")
        equal(result.required, case.required, label .. " required")
        for name, count in pairs(case.counts) do equal(result.counts[name], count, label .. " count " .. name) end
        compareGroup(case.quests, result.quests, label .. " dungeon quests")
        compareGroup(case.optional, result.optional, label .. " optional")
        compareGroup(case.prerequisites, result.prerequisites, label .. " prerequisites")
        compareGroup(case.repeatable, result.repeatable, label .. " repeatable")
        compareGroup(case.unknownRelevance, result.unknownRelevance, label .. " unknown relevance")
        seen[case.readiness] = true
    end
    checked = checked + 1
end
truthy(checked >= 100, "parity cases")
for _, readiness in ipairs({ "ready", "missing", "blocked", "unknown", "none" }) do truthy(seen[readiness], "the fixture covers " .. readiness) end

-- 3. The rules' promises -------------------------------------------------------------------
-- Nothing reported is never ready; a quest list that is not known says so.
local nothing = R.ForGuide(36, nil)
equal(nothing.readiness, "unknown")
local blackmaw = R.ForGuide(2974, stateOf(fixture.states.freshAlliance))
equal(blackmaw.readiness, "none")
equal(blackmaw.questList, "unknown")
equal(R.Summary(blackmaw), "No quest list is known for this dungeon yet. That does not mean it has none.")
-- Optional quests never block: Deadmines with every required quest done or held.
local done = R.ForGuide(36, stateOf(fixture.states.defiasDone))
equal(done.readiness, "ready")
equal(R.Summary(done), "3 of 5 required done, 2 in the quest log")
-- Prerequisite status for the chain view.
local fresh = stateOf(fixture.states.freshAlliance)
equal(R.PrerequisiteStatus({ questId = 155 }, fresh), "missing")
equal(R.PrerequisiteStatus({ questId = 155 }, stateOf(fixture.states.defiasDone)), "done")
equal(R.PrerequisiteStatus({ questId = 168, mustBeActive = true }, stateOf(fixture.states.defiasDone)), "accepted")
equal(R.PrerequisiteStatus({ questId = 155 }, R.EmptyState()), "unknown")

print("dungeon readiness spec passed (" .. checked .. " parity cases from Holdfast " .. string.sub(fixture.commit, 1, 7) .. ")")
