local _, GW = ...

-- The dungeon quest preparation planner in game: for the current character
-- and one dungeon (or wing), an ordered checklist of the quests to collect
-- (chains first, a shared prerequisite once, staying in one zone where the
-- order allows), what a group member could share, when to go in, and what
-- to turn in after.
--
-- These are Holdfast's rules (backend/src/Atlas/atlasQuestPlan.js,
-- docs/dungeon-quest-planner.md), built on GW.DungeonReadiness for every
-- quest state: the same sections, step ids, kinds, statuses, order and
-- waypoints. test/dungeon_quest_plan_spec.lua runs this file against plans
-- Holdfast computed (test/fixtures/quest-plan-parity.json, written by
-- scripts/questPlanParity.mjs). Editorial data (the website's CMS) is not
-- packaged, so turn-in locations are always "not in our data" here.
--
-- Costs: nothing per frame. A plan is built when the journal's quest tab
-- asks (out of combat; it caches by page and character state), and the
-- character state is re-read on quest events by GW.CharacterQuests.

GW.DungeonQuestPlan = GW.DungeonQuestPlan or {}

local P = GW.DungeonQuestPlan
local R = GW.DungeonReadiness
local Globals = _G or {}

P.SCHEMA = 1
P.SECTIONS = { "collect", "share", "enter", "optional", "repeatable", "unknown", "turnIn" }
P.STATUSES = { "done", "todo", "blocked", "unknown", "ineligible" }
local NOT_IN_DATA = "not-in-our-data"
local STATUS_OF = { completed = "done", available = "todo", prerequisites = "blocked", unknown = "unknown", ineligible = "ineligible" }

local function coordinates(x, y)
    return string.format("%.1f, %.1f", x / 10, y / 10)
end

-- A usable location: a UiMap id and per-mille coordinates inside the map.
local function located(mapId, x, y)
    return type(mapId) == "number" and mapId > 0 and type(x) == "number" and type(y) == "number"
        and x >= 0 and x <= 1000 and y >= 0 and y <= 1000
end

local function giverKey(quest)
    if not quest.giver then return nil end
    if located(quest.mapId, quest.x, quest.y) then
        return quest.giver .. "|" .. quest.mapId .. "|" .. quest.x .. "|" .. quest.y
    end
    return quest.giver .. "|"
end

-- (zone, minimum level, id); no zone last.
local function before(a, b)
    local za, zb = a.zone, b.zone
    if za ~= zb then
        if za == nil then return false end
        if zb == nil then return true end
        return za < zb
    end
    local la, lb = a.minLevel or 0, b.minLevel or 0
    if la ~= lb then return la < lb end
    return a.questId < b.questId
end

local function step(fields)
    fields.children = fields.children or {}
    return fields
end

--   input.entries:  the dungeon's catalog entries ({ quest, relevance, wing }, R.Catalog)
--   input.state:    the character state (GW.CharacterQuests.State()), nil = nothing reported
--   input.wingKey:  a wing's key, to leave out quests of sibling wings
--   input.entrance: { mapId, x, y (per mille), zoneName } or nil
--   input.name:     the dungeon's name (the entrance waypoint's target)
function P.Build(input)
    local state = input.state or R.EmptyState()
    local wingKey = input.wingKey
    local problems = {}
    local known, sortedIds = {}, {}
    for _, entry in ipairs(input.entries or {}) do
        local quest = entry.quest
        if not wingKey or not entry.wing or entry.wing == wingKey then
            if known[quest.questId] then
                table.insert(problems, { code = "duplicate-quest", questId = quest.questId })
            elseif entry.relevance ~= "zone" then
                known[quest.questId] = { quest = quest, relevance = entry.relevance }
                table.insert(sortedIds, quest.questId)
            end
        end
    end
    table.sort(sortedIds)

    local states, reasonsOf = {}, {}
    for _, questId in ipairs(sortedIds) do
        states[questId], reasonsOf[questId] = R.QuestState(known[questId].quest, state)
    end
    local complete = state.questLog and state.questLog.complete or nil
    local function objectivesComplete(questId)
        if states[questId] ~= "accepted" or not complete then return nil end
        local value = complete[questId]
        if value == true or value == false then return value end
        return nil
    end
    local function quest(questId) return known[questId].quest end
    local function relevance(questId) return known[questId].relevance end
    local function done(questId) return states[questId] == "completed" end

    for _, questId in ipairs(sortedIds) do
        for _, prerequisite in ipairs(quest(questId).prerequisites or {}) do
            if not known[prerequisite.questId] then
                table.insert(problems, { code = "prerequisite-not-in-catalog", questId = questId, prerequisiteId = prerequisite.questId })
            end
        end
    end

    -- Cycles, depth-first as Holdfast does.
    local color, inCycle = {}, {}
    local function visit(questId, path)
        color[questId] = 1
        table.insert(path, questId)
        for _, prerequisite in ipairs(quest(questId).prerequisites or {}) do
            local nextId = prerequisite.questId
            if known[nextId] then
                if color[nextId] == 1 then
                    local cycle, started = {}, false
                    for _, id in ipairs(path) do
                        if id == nextId then started = true end
                        if started then
                            table.insert(cycle, id)
                            inCycle[id] = true
                        end
                    end
                    table.sort(cycle)
                    table.insert(problems, { code = "prerequisite-cycle", questIds = cycle })
                elseif not color[nextId] then
                    visit(nextId, path)
                end
            end
        end
        table.remove(path)
        color[questId] = 2
    end
    for _, questId in ipairs(sortedIds) do if not color[questId] then visit(questId, {}) end end

    -- Waypoints.
    local waypoints, waypointList = {}, {}
    local function waypoint(id, mapId, x, y, zoneName, target, targetType, source)
        if not located(mapId, x, y) then return nil end
        if not waypoints[id] then
            local record = { id = id, mapSystem = "uiMap", mapId = mapId, x = x, y = y, zoneName = zoneName, target = target,
                targetType = targetType, source = source, verified = false }
            waypoints[id] = record
            table.insert(waypointList, record)
        end
        return id
    end
    local function giverWaypoint(q, targetType)
        return waypoint("wp:giver:" .. q.questId, q.mapId, q.x, q.y, q.zone, q.giver, targetType, "catalog")
    end
    local function travel(q, id, status, targetType, optional)
        local wp = giverWaypoint(q, targetType)
        local text
        if q.giver and wp then text = "Go to " .. q.giver .. (q.zone and (" in " .. q.zone) or "") .. " (" .. coordinates(q.x, q.y) .. ")"
        elseif q.giver then text = "Find " .. q.giver .. ": location not in our data"
        elseif q.startsFromItem then text = "Starts from an item (" .. q.startsFromItem .. "): location not in our data"
        else text = "Quest giver not in our data" end
        return step({ id = id, kind = "travel", questId = q.questId, status = status, text = text, waypoint = wp,
            location = not wp and NOT_IN_DATA or nil, optional = optional or nil, source = "catalog" })
    end

    -- collect ---------------------------------------------------------------------------
    local afterMemo = {}
    local function afterDungeon(questId, seen)
        if afterMemo[questId] ~= nil then return afterMemo[questId] end
        if seen[questId] or inCycle[questId] then return false end
        seen[questId] = true
        local result = false
        for _, prerequisite in ipairs(quest(questId).prerequisites or {}) do
            local id = prerequisite.questId
            if known[id] and not inCycle[id] and not done(id) then
                if relevance(id) == "dungeon" or afterDungeon(id, seen) then
                    result = true
                    break
                end
            end
        end
        afterMemo[questId] = result
        return result
    end
    local nodes, nodeCount, keepInLog = {}, 0, {}
    local function pull(questId, role)
        if nodes[questId] then
            if role == "quest" then nodes[questId].role = "quest" end
            return
        end
        nodes[questId] = { role = role }
        nodeCount = nodeCount + 1
        local current = states[questId]
        if current == "completed" or current == "accepted" or current == "ineligible" then return end
        for _, prerequisite in ipairs(quest(questId).prerequisites or {}) do
            local id = prerequisite.questId
            if known[id] and not inCycle[id] and not done(id) then
                if prerequisite.mustBeActive then keepInLog[id] = true end
                if not (prerequisite.mustBeActive and states[id] == "accepted") then pull(id, "prerequisite") end
            end
        end
    end
    for _, questId in ipairs(sortedIds) do
        local current = states[questId]
        if relevance(questId) == "dungeon" and not inCycle[questId] and current ~= "ineligible"
            and (current == "completed" or current == "accepted" or not afterDungeon(questId, {})) then
            pull(questId, "quest")
        end
    end
    local edges = {}
    for questId in pairs(nodes) do
        local list = {}
        for _, prerequisite in ipairs(quest(questId).prerequisites or {}) do
            if prerequisite.questId ~= questId and nodes[prerequisite.questId] then table.insert(list, prerequisite.questId) end
        end
        edges[questId] = list
    end
    local placed, order = {}, {}
    local previousZone
    while #order < nodeCount do
        local ready = {}
        for questId in pairs(nodes) do
            if not placed[questId] then
                local ok = true
                for _, id in ipairs(edges[questId]) do if not placed[id] then ok = false break end end
                if ok then table.insert(ready, quest(questId)) end
            end
        end
        if #ready == 0 then break end
        table.sort(ready, before)
        local chosen = ready[1]
        if #order > 0 then
            for _, candidate in ipairs(ready) do
                if candidate.zone == previousZone then chosen = candidate break end
            end
        end
        placed[chosen.questId] = true
        table.insert(order, chosen.questId)
        previousZone = chosen.zone
    end

    local collect, lastGiver = {}, nil
    for _, questId in ipairs(order) do
        local q = quest(questId)
        local isQuest = nodes[questId].role == "quest"
        local current = states[questId]
        local held = current == "accepted" and (isQuest or keepInLog[questId])
        local status = held and "done" or (current == "accepted" and "todo" or STATUS_OF[current])
        local id = "collect:q" .. questId
        local children = {}
        local targetType = isQuest and "quest-giver" or "prerequisite-giver"
        if status ~= "done" and status ~= "ineligible" then
            for _, prerequisite in ipairs(q.prerequisites or {}) do
                if not known[prerequisite.questId] then
                    local where = R.PrerequisiteStatus(prerequisite, state)
                    table.insert(children, step({ id = id .. ":pre" .. prerequisite.questId, kind = "complete-prerequisite", questId = prerequisite.questId,
                        status = where == "done" and "done" or (where == "unknown" and "unknown" or "todo"),
                        text = "Complete quest " .. prerequisite.questId .. " first (not in our data)", location = NOT_IN_DATA }))
                end
            end
            if current == "accepted" then
                local finished = objectivesComplete(questId)
                table.insert(children, step({ id = id .. ":complete", kind = "complete-prerequisite", questId = questId, status = "todo",
                    objectivesComplete = finished,
                    text = finished == true and ("Turn in " .. q.name) or (finished == false and ("Finish " .. q.name .. ", then turn it in")
                        or ("Complete and turn in " .. q.name)) }))
            else
                local key = giverKey(q)
                if not (key and key == lastGiver) then table.insert(children, travel(q, id .. ":travel", status, targetType)) end
                table.insert(children, step({ id = id .. ":accept", kind = "accept", questId = questId, status = status,
                    text = "Accept " .. q.name .. (q.giver and (" from " .. q.giver) or "") }))
                if not isQuest and not keepInLog[questId] then
                    table.insert(children, step({ id = id .. ":complete", kind = "complete-prerequisite", questId = questId, status = status,
                        text = "Complete and turn in " .. q.name }))
                end
                lastGiver = key
            end
        end
        local text
        if isQuest then
            text = held and (q.name .. ": in your quest log") or (current == "completed" and (q.name .. ": completed") or ("Get " .. q.name))
        else
            text = "Prerequisite: " .. q.name
        end
        table.insert(collect, step({ id = id, kind = isQuest and "quest" or "prerequisite", questId = questId, status = status, text = text,
            children = children, collapsed = status == "done" or nil,
            waypoint = (status ~= "done" and status ~= "ineligible") and giverWaypoint(q, targetType) or nil,
            reasons = (status == "unknown" or status == "blocked" or status == "ineligible") and reasonsOf[questId] or nil }))
    end

    -- share -----------------------------------------------------------------------------
    local share = {}
    for _, questId in ipairs(order) do
        local q = quest(questId)
        if q.shareable == "yes" and states[questId] == "available" then
            local id = "share:q" .. questId
            table.insert(share, step({ id = id, kind = "share", questId = questId, status = "todo", text = q.name .. ": shareable", children = {
                step({ id = id .. ":ask", kind = "ask-share", questId = questId, status = "todo",
                    text = "Ask your group whether anyone has " .. q.name .. " to share" }),
                travel(q, id .. ":travel", "todo", nodes[questId].role == "quest" and "quest-giver" or "prerequisite-giver", true),
            } }))
        end
    end

    -- enter -----------------------------------------------------------------------------
    local total, doneCount, has = 0, 0, {}
    for _, entry in ipairs(collect) do
        if entry.kind == "quest" then
            total = total + 1
            has[entry.status] = true
            if entry.status == "done" then doneCount = doneCount + 1 end
        end
    end
    local verify = (total == 0 or doneCount == total) and "done" or (has.todo and "todo" or (has.blocked and "blocked" or "unknown"))
    local goStatus = verify == "done" and "todo" or (verify == "unknown" and "unknown" or "blocked")
    local entrance = input.entrance
    local entranceWp = entrance and waypoint("wp:entrance", entrance.mapId, entrance.x, entrance.y, entrance.zoneName, input.name, "entrance", "atlas") or nil
    local enter = {
        step({ id = "enter:verify", kind = "verify", status = verify,
            text = total > 0 and string.format("Have every dungeon quest (%d of %d)", doneCount, total) or "No dungeon quests to collect" }),
        step({ id = "enter:travel", kind = "travel", status = goStatus, waypoint = entranceWp, location = not entranceWp and NOT_IN_DATA or nil,
            source = "atlas", text = entranceWp and ("Go to the entrance" .. (entrance.zoneName and (" in " .. entrance.zoneName) or "")
                .. " (" .. coordinates(entrance.x, entrance.y) .. ")") or "Entrance location not in our data" }),
        step({ id = "enter:enter", kind = "enter", status = goStatus,
            text = verify == "done" and "Enter the dungeon: you are ready" or "Enter when every quest is collected" }),
    }

    -- optional, repeatable, unknown -----------------------------------------------------
    local function plain(wanted)
        local list = {}
        for _, questId in ipairs(sortedIds) do
            if relevance(questId) == wanted and not inCycle[questId] and states[questId] ~= "ineligible" then
                local current = states[questId]
                local status = current == "accepted" and "done" or STATUS_OF[current]
                table.insert(list, step({ id = wanted .. ":q" .. questId, kind = wanted, questId = questId, status = status, text = quest(questId).name,
                    waypoint = status ~= "done" and giverWaypoint(quest(questId), "quest-giver") or nil,
                    reasons = (status == "unknown" or status == "blocked") and reasonsOf[questId] or nil }))
            end
        end
        return list
    end
    local optional = plain("optional")
    local repeatable = plain("repeatable")
    local unknown = {}
    for _, questId in ipairs(sortedIds) do
        if inCycle[questId] or (relevance(questId) == "unknown" and states[questId] ~= "ineligible") then
            local reasons = { "prerequisite-cycle" }
            if not inCycle[questId] then
                reasons = { "relevance-not-known" }
                for _, reason in ipairs(reasonsOf[questId]) do table.insert(reasons, reason) end
            end
            table.insert(unknown, step({ id = "unknown:q" .. questId, kind = "unknown", questId = questId, status = "unknown",
                text = quest(questId).name, reasons = reasons }))
        end
    end

    -- turnIn ----------------------------------------------------------------------------
    local turnIn = {}
    for _, questId in ipairs(sortedIds) do
        if states[questId] == "accepted" and relevance(questId) ~= "prerequisite" and not inCycle[questId] then
            local finished = objectivesComplete(questId)
            local q = quest(questId)
            table.insert(turnIn, step({ id = "turnin:q" .. questId, kind = finished == false and "finish-objectives" or "turn-in", questId = questId,
                status = finished == nil and "unknown" or "todo", objectivesComplete = finished,
                location = finished ~= false and NOT_IN_DATA or nil,
                text = finished == false and ("Finish " .. q.name .. "'s objectives") or ("Turn in " .. q.name .. ": turn-in location not in our data") }))
        end
    end
    for _, questId in ipairs(sortedIds) do
        local current = states[questId]
        if not nodes[questId] and not inCycle[questId] and current ~= "completed" and current ~= "accepted" and current ~= "ineligible" then
            local q = quest(questId)
            local unlockedBy
            for _, prerequisite in ipairs(q.prerequisites or {}) do
                local id = prerequisite.questId
                if known[id] and relevance(id) == "dungeon" and not done(id) then unlockedBy = id break end
            end
            if unlockedBy or (relevance(questId) == "dungeon" and afterDungeon(questId, {})) then
                table.insert(turnIn, step({ id = "followup:q" .. questId, kind = "follow-up", questId = questId, status = STATUS_OF[current],
                    text = "Follow-up: " .. q.name .. (unlockedBy and (", after " .. quest(unlockedBy).name) or ", after the dungeon"),
                    waypoint = giverWaypoint(q, "quest-giver"), reasons = current == "unknown" and reasonsOf[questId] or nil }))
            end
        end
    end

    local bySection = { collect = collect, share = share, enter = enter, optional = optional, repeatable = repeatable, unknown = unknown, turnIn = turnIn }
    local sections, counts = {}, {}
    for _, key in ipairs(P.SECTIONS) do
        table.insert(sections, { key = key, steps = bySection[key] })
        local tally = { total = 0, done = 0, todo = 0, blocked = 0, unknown = 0, ineligible = 0 }
        for _, entry in ipairs(bySection[key]) do
            tally.total = tally.total + 1
            tally[entry.status] = tally[entry.status] + 1
        end
        counts[key] = tally
    end
    local function firstTodo(list)
        for _, entry in ipairs(list) do
            if #entry.children > 0 then
                local found = firstTodo(entry.children)
                if found then return found end
            elseif entry.status == "todo" and entry.kind ~= "note" and not entry.optional then
                return entry.id
            end
        end
        return nil
    end
    local handIns = {}
    for _, entry in ipairs(turnIn) do if entry.kind == "turn-in" then table.insert(handIns, entry) end end
    local nextId = firstTodo(collect) or firstTodo(handIns) or firstTodo(enter)
    table.sort(waypointList, function(a, b) return a.id < b.id end)
    local hidden = 0
    for _, questId in ipairs(sortedIds) do if states[questId] == "ineligible" and not nodes[questId] then hidden = hidden + 1 end end
    local readiness = R.Evaluate(input.entries, input.state, wingKey)
    return {
        schemaVersion = P.SCHEMA, sections = sections, bySection = bySection, waypoints = waypointList, waypointById = waypoints,
        next = nextId, readiness = readiness.readiness, counts = counts, hidden = { ineligible = hidden }, problems = problems,
    }
end

-- The plan for a guide page (a dungeon or a wing) and the current
-- character. Nil when the catalog has no entry for it. Cached until the
-- character state or the page changes.
local cache = {}
function P.ForGuide(guideId, state)
    local catalog = R.Catalog(guideId)
    if not catalog then return nil end
    if not state then
        local quests = GW.CharacterQuests
        state = quests and type(quests.State) == "function" and quests.State() or nil
    end
    local key = tostring(guideId)
    if cache.key == key and cache.state == state and (not state or cache.capturedAt == state.capturedAt) then return cache.plan end
    local guide = GW.DungeonGuide
    local dungeon = guide and type(guide.Dungeon) == "function" and guide.Dungeon(guideId) or nil
    local entrance
    if dungeon and dungeon.entrance and dungeon.entrance.map then
        local entry = guide.Entry and guide.Entry(guideId) or nil
        entrance = { mapId = dungeon.entrance.map, x = dungeon.entrance.x, y = dungeon.entrance.y, zoneName = (entry and entry.zone) or dungeon.zone }
    end
    local plan = P.Build({ entries = catalog.entries, state = state, wingKey = catalog.wingKey, entrance = entrance, name = dungeon and dungeon.name })
    plan.questList = catalog.curated and "curated" or "unknown"
    plan.state = state
    cache.key, cache.state, cache.capturedAt, cache.plan = key, state, state and state.capturedAt, plan
    return plan
end

function P.ClearCache()
    cache = {}
end

-- Waypoints ------------------------------------------------------------------------------
-- TomTom when it is installed, else the client's own user waypoint, else
-- the coordinates as text. A waypoint is only set on a map the client
-- confirms: C_Map.GetMapInfo(mapId) must exist and carry the record's zone
-- name (the catalog's UiMap ids are projected from AzerothCore spawns and
-- not verified on Forever). API shapes as OpenMap (Forever) uses them.

local tomtomHandle

local function call(fn, ...)
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end

-- Does the client know this map under this zone name?
function P.MapConfirmed(record)
    local maps = Globals.C_Map
    if not record or not record.zoneName or type(maps) ~= "table" then return false end
    local ok, info = call(maps.GetMapInfo, record.mapId)
    return ok and type(info) == "table" and info.name == record.zoneName or false
end

function P.WaypointText(record)
    return (record.target and (record.target .. ", ") or "") .. (record.zoneName or "?") .. " " .. coordinates(record.x, record.y)
end

-- Sets a waypoint for a record. Returns how ("tomtom", "blizzard" or
-- "text") and the coordinates as text (always shown).
function P.SetWaypoint(record)
    if not record then return nil end
    local text = P.WaypointText(record)
    if not P.MapConfirmed(record) then return "text", text end
    local x, y = record.x / 1000, record.y / 1000
    local tomtom = Globals.TomTom
    if type(tomtom) == "table" and type(tomtom.AddWaypoint) == "function" then
        if tomtomHandle and type(tomtom.RemoveWaypoint) == "function" then pcall(tomtom.RemoveWaypoint, tomtom, tomtomHandle) end
        local ok, handle = pcall(tomtom.AddWaypoint, tomtom, record.mapId, x, y, { title = record.target or record.zoneName, from = "Guildweaver" })
        if ok then
            tomtomHandle = handle
            return "tomtom", text
        end
    end
    local maps, point = Globals.C_Map, Globals.UiMapPoint
    if type(maps) == "table" and type(maps.SetUserWaypoint) == "function" and type(point) == "table" and type(point.CreateFromCoordinates) == "function" then
        local allowed = true
        if type(maps.CanSetUserWaypointOnMap) == "function" then
            local ok, value = pcall(maps.CanSetUserWaypointOnMap, record.mapId)
            allowed = ok and value and true or false
        end
        if allowed then
            local okPoint, mapPoint = pcall(point.CreateFromCoordinates, record.mapId, x, y)
            if okPoint and mapPoint and pcall(maps.SetUserWaypoint, mapPoint) then
                local super = Globals.C_SuperTrack
                if type(super) == "table" and type(super.SetSuperTrackedUserWaypoint) == "function" then pcall(super.SetSuperTrackedUserWaypoint, true) end
                return "blizzard", text
            end
        end
    end
    return "text", text
end

-- Short words for the checklist.
P.STATUS_LABELS = { done = "Done", todo = "To do", blocked = "Needs an earlier step", unknown = "Not known", ineligible = "Not for you" }
P.SECTION_TITLES = {
    collect = "Collect before you go", share = "Or ask your group to share", enter = "Enter",
    optional = "Optional quests", repeatable = "Repeatable quests", unknown = "Not known", turnIn = "After the run",
}
