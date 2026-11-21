-- The dungeon quest preparation planner in game (Systems/DungeonQuestPlan.lua)
-- and its checklist on the journal's quest tab.
--
-- Parity: test/fixtures/quest-plan-parity.json holds plans Holdfast's own
-- engine (backend/src/Atlas/atlasQuestPlan.js) computed over the same
-- catalog (scripts/questPlanParity.mjs): dungeons, wings, a Forever
-- dungeon, a dungeon without a list, and character states from nothing
-- reported to a chain half done. Every step's id, kind, quest, status and
-- waypoint, their order, every waypoint, next and readiness must come out
-- the same here. Text is not compared: each client words it its own way.

local Env = dofile("test/support/wow_env.lua")
local Export = dofile("scripts/exportDungeonAtlas.lua")
local Quests = dofile("scripts/exportDungeonQuests.lua")

local function equal(actual, expected, label)
    if actual ~= expected then error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2) end
end
local function truthy(value, label)
    if not value then error((label or "value") .. ": expected truthy value", 2) end
end
local function contains(text, part, label)
    if type(text) ~= "string" or not string.find(text, part, 1, true) then error((label or "text") .. ": " .. tostring(text) .. " lacks " .. part, 2) end
end
local function read(path)
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    return text
end
local null = Export.decode("null")
local function present(value) if value ~= null then return value end end

-- 1. Size and startup -----------------------------------------------------------------------
local text = read("Data/DungeonQuests.generated.lua")
truthy(#text < Quests.MAX_BYTES, "the quest data stays under its budget with map ids and shareable")
local env = Env.new()
local addon = env:load()
local R, P = addon.DungeonReadiness, addon.DungeonQuestPlan
truthy(P and type(P.Build) == "function", "the planner is loaded")
truthy(not R.IsBuilt(), "loading the add-on builds no quest tables (lazy)")
local defias = R.Quest(166)
equal(defias.mapId, 1436, "the giver's UiMap id")
equal(defias.shareable, "yes")
equal(R.Quest(2278).shareable, "no")
equal(R.Quest(98423).shareable, "unknown", "Forever: not known stays not known")
equal(R.Quest(98423).mapId, nil)

-- 2. Parity with Holdfast -------------------------------------------------------------------
local fixture = Export.decode(read("test/fixtures/quest-plan-parity.json"))
local function set(list)
    local out = {}
    for _, id in ipairs(present(list) or {}) do out[id] = true end
    return out
end
local function stateOf(raw)
    local log = present(raw.questLog) or { coverage = "none" }
    local ids, complete = {}, {}
    for _, entry in ipairs(present(log.entries) or {}) do
        ids[entry.questId] = true
        local value = present(entry.isComplete)
        if value == true or value == false then complete[entry.questId] = value end
    end
    return {
        faction = present(raw.faction), race = present(raw.race), classToken = present(raw.classToken), level = present(raw.level),
        completed = { coverage = raw.completed.coverage, ids = set(raw.completed.questIds), checked = set(raw.completed.checkedQuestIds) },
        questLog = { coverage = log.coverage, ids = ids, complete = complete },
    }
end
local function flatten(steps, depth, rows)
    for _, entry in ipairs(steps) do
        table.insert(rows, entry)
        entry.gwDepth = depth
        flatten(entry.children, depth + 1, rows)
    end
    return rows
end
local checked, steps, seenNext, editorialCases = 0, 0, {}, 0
for _, case in ipairs(fixture.cases) do
    local label = tostring(case.guide) .. "/" .. case.state
    local catalog = R.Catalog(case.guide)
    if case.missing then
        equal(catalog, nil, label .. " has no catalog entry")
    else
        truthy(catalog, label)
        local entrance = present(case.entrance)
        -- Editorial cases: the same SYNTHETIC documents, through the exporter's own packaging.
        local editorial, catalogIds
        if present(case.editorial) then
            local packaging = {}
            editorial = Quests.editorialFromBundle({ questPlans = { fixture.editorials[case.editorial] } }, packaging)[case.guide]
            equal(#packaging, 0, label .. " packages without problems")
            truthy(editorial, label .. " editorial record")
            catalogIds = {}
            for _, entry in ipairs(R.Catalog(case.guide).entries) do catalogIds[entry.quest.questId] = true end
            editorialCases = editorialCases + 1
        end
        local plan = P.Build({ entries = catalog.entries, state = stateOf(fixture.states[case.state]), wingKey = catalog.wingKey,
            entrance = entrance and { mapId = entrance.mapId, x = entrance.x, y = entrance.y, zoneName = present(entrance.zoneName) },
            editorial = editorial, catalogIds = catalogIds })
        if editorial then
            equal(plan.editorial.used, case.used, label .. " editorial used")
            for _, section in ipairs(plan.sections) do equal(#section.notes, case.notes[section.key], label .. " " .. section.key .. " notes") end
        end
        equal(plan.readiness, case.readiness, label .. " readiness")
        equal(plan.next, present(case.next), label .. " next")
        if plan.next then seenNext[string.match(plan.next, "^[^:]+")] = true end
        for _, key in ipairs(P.SECTIONS) do
            local expected = case.sections[key]
            local actual = flatten(plan.bySection[key], 0, {})
            equal(#actual, #expected, label .. " " .. key .. " size")
            for index, row in ipairs(expected) do
                local got = actual[index]
                local where = label .. " " .. key .. " #" .. index .. " " .. row[1]
                equal(got.id, row[1], where .. " id")
                equal(got.kind, row[2], where .. " kind")
                equal(got.questId, present(row[3]), where .. " quest")
                equal(got.status, row[4], where .. " status")
                equal(got.waypoint, present(row[5]), where .. " waypoint")
                equal(got.gwDepth, row[6], where .. " depth")
                steps = steps + 1
            end
        end
        equal(#plan.waypoints, #case.waypoints, label .. " waypoints")
        for index, row in ipairs(case.waypoints) do
            local got = plan.waypoints[index]
            equal(got.id, row[1], label .. " waypoint id")
            equal(got.mapId, row[2], label .. " " .. row[1] .. " map")
            equal(got.x, row[3], label .. " " .. row[1] .. " x")
            equal(got.y, row[4], label .. " " .. row[1] .. " y")
            equal(got.targetType, row[5], label .. " " .. row[1] .. " target type")
            if row[6] ~= nil then
                equal(got.source, row[6], label .. " " .. row[1] .. " source")
                equal(got.verified, row[7], label .. " " .. row[1] .. " verified")
            end
        end
        local codes = {}
        for _, problem in ipairs(plan.problems) do table.insert(codes, problem.code) end
        equal(table.concat(codes, ","), table.concat(case.problems, ","), label .. " problems")
    end
    checked = checked + 1
end
truthy(checked >= 100, "parity cases")
truthy(editorialCases >= 18, "parity cases with published quest edits")
truthy(steps > 1000, "parity steps")
for _, kind in ipairs({ "collect", "enter" }) do truthy(seenNext[kind], "the fixture has a next step in " .. kind) end

-- 3. The planner's promises -----------------------------------------------------------------
local fresh = stateOf(fixture.states.freshAlliance)
local deadmines = P.ForGuide(36, fresh)
local order = {}
for index, entry in ipairs(deadmines.bySection.collect) do order[entry.questId] = index end
for _, pair in ipairs({ { 65, 132 }, { 132, 135 }, { 135, 141 }, { 141, 142 }, { 142, 155 }, { 155, 166 }, { 155, 214 } }) do
    truthy(order[pair[1]] < order[pair[2]], pair[1] .. " before " .. pair[2])
end
equal(deadmines.next, "collect:q168:travel")
equal(deadmines.waypointById["wp:entrance"].mapId, 1436, "the entrance from the packaged atlas")
equal(P.ForGuide(36, fresh), deadmines, "cached for the same state")
local nothing = P.Build({ entries = R.Catalog(36).entries })
equal(nothing.next, nil, "nothing reported: nothing claimed doable")
equal(nothing.readiness, "unknown")
-- A cycle and a duplicate (SYNTHETIC entries): problems, not a crash.
local function synthetic(questId, prerequisites)
    local pre = {}
    for _, id in ipairs(prerequisites or {}) do table.insert(pre, { questId = id }) end
    return { quest = { questId = questId, name = "Synthetic " .. questId, faction = "alliance", factionKnown = true, prerequisitesKnown = true,
        prerequisites = pre, shareable = "unknown", giver = "Giver", zone = "Westfall", mapId = 1436, x = 500, y = 500 }, relevance = "dungeon" }
end
local cyclic = P.Build({ entries = { synthetic(1, { 2 }), synthetic(2, { 1 }), synthetic(3), synthetic(3) }, state = fresh })
equal(cyclic.problems[1].code, "duplicate-quest")
equal(cyclic.problems[2].code, "prerequisite-cycle")
equal(#cyclic.bySection.unknown, 2)
equal(cyclic.bySection.collect[1].id, "collect:q3")

-- 4. Waypoints: TomTom, the client's pin, or text --------------------------------------------
local record = deadmines.waypointById["wp:giver:168"]
_G.C_Map, _G.TomTom, _G.UiMapPoint, _G.C_SuperTrack = nil, nil, nil, nil
local how, line = P.SetWaypoint(record)
equal(how, "text", "no map API: coordinates as text")
contains(line, "65.4, 21.2")
_G.C_Map = { GetMapInfo = function(mapId) return mapId == 1453 and { name = "Elwynn Forest" } or nil end }
equal((P.SetWaypoint(record)), "text", "the client's map has another name: not set")
local pins, tracked = {}, false
_G.C_Map = {
    GetMapInfo = function(mapId) return mapId == 1453 and { name = "Stormwind City" } or nil end,
    CanSetUserWaypointOnMap = function() return true end,
    SetUserWaypoint = function(point) table.insert(pins, point) end,
}
_G.UiMapPoint = { CreateFromCoordinates = function(mapId, x, y) return { mapId = mapId, x = x, y = y } end }
_G.C_SuperTrack = { SetSuperTrackedUserWaypoint = function(value) tracked = value end }
equal((P.SetWaypoint(record)), "blizzard", "without TomTom: the client's own pin")
equal(pins[1].mapId, 1453)
equal(pins[1].x, 0.654)
truthy(tracked, "and tracked")
_G.C_Map.CanSetUserWaypointOnMap = function() return false end
equal((P.SetWaypoint(record)), "text", "a map that takes no pin")
local added, removed = {}, {}
_G.TomTom = {
    AddWaypoint = function(_, mapId, x, y, opts) table.insert(added, { mapId = mapId, x = x, y = y, opts = opts }) return "handle" .. #added end,
    RemoveWaypoint = function(_, handle) table.insert(removed, handle) end,
}
equal((P.SetWaypoint(record)), "tomtom")
equal(added[1].mapId, 1453)
equal(added[1].opts.from, "Guildweaver")
equal(added[1].opts.title, "Wilder Thistlenettle")
P.SetWaypoint(record)
equal(removed[1], "handle1", "the previous TomTom waypoint is replaced")
_G.TomTom = { AddWaypoint = function() error("broken TomTom") end }
_G.C_Map.CanSetUserWaypointOnMap = nil
equal((P.SetWaypoint(record)), "blizzard", "a failing TomTom falls back")
_G.C_Map, _G.TomTom, _G.UiMapPoint, _G.C_SuperTrack = nil, nil, nil, nil

-- 5. The journal's checklist ----------------------------------------------------------------
do
    local env2 = Env.new()
    local addon2 = env2:load()
    env2:login()
    local completedIds = { 65 }
    _G.C_QuestLog = {
        GetAllCompletedQuestIDs = function() return completedIds end,
        GetNumQuestLogEntries = function() return 1 end,
        GetInfo = function(index) return index == 1 and { questID = 168, title = "Collecting Memories", isHeader = false } or nil end,
        IsComplete = function(id) return id == 168 end,
    }
    env2:dispatch("QUEST_LOG_UPDATE")
    addon2.CharacterQuests.Capture("test", true)
    local guideUI, main = addon2.DungeonGuideUI, addon2.MainFrame
    truthy(guideUI.Show(36))
    guideUI.Navigate(guideUI.Pages.dungeon(36, "quests"))
    local page = main.views.dungeon.dungeon
    local rows = {}
    for _, row in ipairs(page.planRows.items) do if row.shown ~= false then table.insert(rows, row) end end
    truthy(#rows > 10, "the checklist is on the quest tab")
    equal(rows[1].number.gwText, "1.", "numbered steps")
    equal(rows[2].number.gwText, "a.", "lettered parts")
    local nextRow
    for _, row in ipairs(rows) do if row.gwData.isNext then nextRow = row end end
    truthy(nextRow, "the next step is highlighted")
    contains(nextRow.status.gwText, "Next")
    contains(page.questSummary.gwText, "Next: ")
    local heads = {}
    for _, header in ipairs(page.planHeads.items) do if header.shown ~= false then table.insert(heads, header.text.gwText) end end
    contains(table.concat(heads, "|"), "COLLECT BEFORE YOU GO")
    contains(table.concat(heads, "|"), "AFTER THE RUN", "the turn-in list")
    local turnIn
    for _, row in ipairs(rows) do if row.gwData.id == "turnin:q168" then turnIn = row end end
    truthy(turnIn, "168's objectives are done: turn it in")
    contains(turnIn.text.gwText, "not in our data", "no turn-in location without editorial data")
    -- The quest groups are still there, after it.
    equal(page.questRows.items[1].shown ~= false, true)
    -- A waypoint button without TomTom or a map API: the coordinates as text.
    local travel
    for _, row in ipairs(rows) do if row.gwData.record then travel = row break end end
    truthy(travel, "a step with a place has a waypoint button")
    travel.go:Click()
    equal(travel.gwWaypointSet, "text")
    -- In combat the checklist is not rebuilt; quest events refresh it after.
    local built = page.gwPlan
    env2.inCombat = true
    main:RefreshView()
    equal(page.gwPlan, built, "kept in combat")
    env2.inCombat = false
    completedIds = { 65, 132, 135, 141, 142, 155 }
    env2:dispatch("QUEST_TURNED_IN", 155)
    env2:advance(addon2.CharacterQuests.DEBOUNCE + 1)
    local fresh2 = page.gwPlan
    truthy(fresh2 ~= built, "rebuilt after the quest event")
    local listed = false
    for _, entry in ipairs(fresh2.bySection.collect) do if entry.questId == 155 then listed = true end end
    truthy(not listed, "the finished chain is gone")
    _G.C_QuestLog = nil
end

-- 6. Published quest edits in the package (scripts/exportDungeonQuests.lua --editorial) -----
-- test/fixtures/editorial_quest_bundle.json: SYNTHETIC edits in the shape of
-- Holdfast's studio export bundle (questPlans), the parity fixture's own.
do
    local bundleJson = read("test/fixtures/editorial_quest_bundle.json")
    local packagedText = read("Data/DungeonQuests.generated.lua")
    local problems = {}
    local records = Quests.editorialFromBundle(Export.decode(bundleJson), problems)
    equal(#problems, 0, "the synthetic bundle packages cleanly")
    truthy(records[36] and records[3065], "one record per dungeon")
    equal(records[36].revision, "parity-1")
    equal(records[36].entrance.x, 421, "coordinates in permille")
    equal(records[36].quests[2].steps[2], "Synthetic step two.")
    equal(Quests.literal(records[36]), Quests.literal(Quests.editorialFromBundle(Export.decode(bundleJson), {})[36]), "deterministic")

    -- Refused, never cut: a bundle Holdfast flagged, an over-long step, a bad location, a duplicate dungeon.
    local function refused(bundle, label)
        local found = {}
        Quests.editorialFromBundle(Export.decode(bundle), found)
        truthy(#found > 0, label .. " is refused")
    end
    refused('{"questPlans":[],"questPlanProblems":[{"instanceId":36,"code":"editorial-location-dropped"}]}', "a bundle Holdfast flagged")
    refused('{"questPlans":[{"schemaVersion":1,"instanceId":36,"quests":[{"questId":166,"steps":[{"text":"' .. string.rep("x", 201) .. '"}]}]}]}', "a step over 200 bytes")
    refused('{"questPlans":[{"schemaVersion":1,"instanceId":36,"quests":[{"questId":166,"turnIn":{"location":{"mapId":1436,"x":1.5,"y":0.2}}}]}]}', "coordinates outside 0-1")
    refused('{"questPlans":[{"schemaVersion":2,"instanceId":36}]}', "another schema")
    refused('{"questPlans":[{"schemaVersion":1,"instanceId":36},{"schemaVersion":1,"instanceId":36}]}', "a dungeon twice")
    refused('{"questPlans":[{"schemaVersion":1,"instanceId":36,"quests":[{"questId":166},{"questId":166}]}]}', "a quest twice")

    -- The generated file with edits: the in-game planner reads them (offline, from the package).
    local function withEditorial(fileText)
        local start = string.find(fileText, "local E = {}\n", 1, true)
        truthy(start, "the generated file has its E table")
        local lines = {}
        for id, packed in pairs(records) do table.insert(lines, string.format("E[%d]=%s\n", id, Quests.literal(packed))) end
        table.sort(lines)
        return string.sub(fileText, 1, start + #"local E = {}\n" - 1) .. table.concat(lines) .. string.sub(fileText, start + #"local E = {}\n")
    end
    local packaged = string.gsub(packagedText, "\r\n", "\n")
    equal(string.find(packaged, "\nE%["), nil, "the packaged file carries no edits until one is published and exported")
    local edited = withEditorial(packaged)
    truthy(#edited < Quests.MAX_BYTES, "still under budget")
    local editedEnv = Env.new()
    local editedAddon = editedEnv:load()
    local chunk = assert(loadstring(edited))
    local holder = {}
    chunk("Guildweaver", holder)
    editedAddon.DungeonQuestData = holder.DungeonQuestData
    local ER, EP = editedAddon.DungeonReadiness, editedAddon.DungeonQuestPlan
    equal(ER.Editorial(36).revision, "parity-1")
    equal(ER.Editorial(48), nil, "a dungeon without edits")
    local plan = EP.ForGuide(36, stateOf(fixture.states.defiasDone))
    truthy(plan.editorial.used, "the journal's plan uses the published edits")
    local entranceWp = plan.waypointById["wp:entrance"]
    equal(entranceWp.source, "editorial")
    equal(entranceWp.verified, true)
    local notes = 0
    for _, section in ipairs(plan.sections) do notes = notes + #section.notes end
    equal(notes, 2, "both instructions reach their sections")
    -- The journal's checklist draws them as notes, not as steps to do.
    local noteLines, stepNotes = 0, 0
    for _, group in ipairs(editedAddon.DungeonGuideUI.PlanLines(plan)) do
        for _, row in ipairs(group.lines) do
            if row.note and row.depth == 0 then noteLines = noteLines + 1 end
            if row.note and row.depth == 1 then stepNotes = stepNotes + 1 end
            if row.note then truthy(not row.isNext, "a note is never the next step") end
        end
    end
    equal(noteLines, 2, "instruction lines in the checklist")
    for _, group in ipairs(editedAddon.DungeonGuideUI.PlanLines(EP.ForGuide(36, stateOf(fixture.states.freshAlliance)))) do
        for _, row in ipairs(group.lines) do
            if row.note and row.depth == 1 then stepNotes = stepNotes + 1 end
        end
    end
    equal(stepNotes, 2, "a quest's published steps are lettered notes under it")
    local hall = EP.ForGuide(3065, stateOf(fixture.states.freshAlliance))
    local collected = {}
    for _, entry in ipairs(hall.bySection.collect) do collected[entry.questId] = true end
    truthy(not collected[96394], "the edited chain: 96394 waits on the dungeon quest 96393")
    truthy(hall.waypointById["wp:giver:96393"], "the edited giver location gives a waypoint")
    equal(hall.waypointById["wp:giver:96393"].source, "editorial")
end

print("dungeon quest plan spec passed (" .. checked .. " parity cases, " .. steps .. " steps from Holdfast " .. string.sub(fixture.commit, 1, 7) .. ")")
