local _, GW = ...

-- Dungeon quest readiness in game: for the current character and one
-- dungeon (or wing), where each of its quests stands and whether the
-- character holds every dungeon quest it can before going in.
--
-- These are Holdfast's rules (backend/src/Atlas/atlasReadiness.js,
-- docs/dungeon-quest-readiness.md), not a second engine: the same states,
-- the same order of checks, the same readiness. test/dungeon_readiness_spec.lua
-- runs this file against cases Holdfast's own engine computed
-- (test/fixtures/readiness-parity.json), so the two cannot drift apart
-- silently. The quests come from Data/DungeonQuests.generated.lua (Holdfast's
-- quest catalog); the character state from GW.CharacterQuests, in the
-- contract's shape:
--   { faction = "alliance" | "horde" | nil, race = token | nil, classToken = token | nil,
--     level = number | nil,
--     completed = { coverage = "full" | "checked" | "none", ids = { [id] = true }, checked = { [id] = true } },
--     questLog  = { coverage = "full" | "none", ids = { [id] = true } } }
-- A quest missing from a list proves nothing unless the list's coverage says
-- it is complete; a fact not reported makes what depends on it "unknown".

GW.DungeonReadiness = GW.DungeonReadiness or {}

local R = GW.DungeonReadiness

R.QUEST_STATES = { "completed", "accepted", "available", "prerequisites", "ineligible", "unknown" }
local RELEVANCE = { d = "dungeon", o = "optional", p = "prerequisite", r = "repeatable", u = "unknown" }
local FACTIONS = { A = "alliance", H = "horde", B = "both" }

local cache = { data = nil, quests = {} }

local function data()
    if cache.data == nil then
        local raw = GW.DungeonQuestData
        local ok, tables = false, nil
        if type(raw) == "table" and type(raw.load) == "function" then ok, tables = pcall(raw.load) end
        cache.data = ok and type(tables) == "table" and tables or false
    end
    return cache.data or nil
end

function R.Available()
    return data() ~= nil
end

function R.Source()
    local raw = GW.DungeonQuestData
    return type(raw) == "table" and raw.source or nil
end

local function split(text)
    if type(text) ~= "string" then return nil end
    local list = {}
    for token in string.gmatch(text, "[^,]+") do table.insert(list, token) end
    return list
end

-- One quest, decoded from its row once.
function R.Quest(questId)
    questId = tonumber(questId)
    if not questId then return nil end
    local cached = cache.quests[questId]
    if cached ~= nil then return cached or nil end
    local tables = data()
    local row = tables and tables.quests[questId]
    if not row then
        cache.quests[questId] = false
        return nil
    end
    local flags = row[6] or ""
    local prerequisites = {}
    for _, value in ipairs(row[14] or {}) do
        table.insert(prerequisites, { questId = math.abs(value), mustBeActive = value < 0 })
    end
    local quest = {
        questId = questId, name = row[1], level = row[2], minLevel = row[3], maxLevel = row[4],
        -- false in the row: the catalog does not know who may take it.
        faction = row[5] ~= false and FACTIONS[row[5]] or nil, factionKnown = row[5] ~= false,
        repeatable = string.find(flags, "r", 1, true) ~= nil,
        prerequisitesKnown = string.find(flags, "p", 1, true) == nil,
        requiresReputation = string.find(flags, "u", 1, true) ~= nil,
        giver = row[7], zone = row[8] and tables.zones[row[8]] or nil,
        -- Permille, as Guide.Coordinates takes them.
        x = row[9], y = row[10],
        startsFromItem = row[11], races = split(row[12]), classes = split(row[13]),
        prerequisites = prerequisites,
    }
    cache.quests[questId] = quest
    return quest
end

-- A dungeon's (or wing's) catalog: { curated, entries = { { quest, relevance, wing } } }.
-- A wing's key leaves out quests attributed to a sibling wing. Nil when the
-- catalog has no entry for the dungeon.
function R.Catalog(guideId)
    local tables = data()
    if not tables then return nil end
    local guide = GW.DungeonGuide
    local instanceId = guide and type(guide.InstanceIdOf) == "function" and guide.InstanceIdOf(guideId) or tonumber(guideId)
    local wingKey = type(guideId) == "string" and string.find(guideId, ":", 1, true) and guideId or nil
    local row = instanceId and tables.dungeons[instanceId]
    if not row then return nil end
    local entries = {}
    local relevance = row[3] or ""
    for position, questId in ipairs(row[2] or {}) do
        local wing = row[4] and row[4][position] or nil
        local quest = R.Quest(questId)
        if quest and (not wingKey or not wing or wing == wingKey) then
            table.insert(entries, { quest = quest, relevance = RELEVANCE[string.sub(relevance, position, position)] or "unknown", wing = wing })
        end
    end
    return { curated = row[1] == true, entries = entries, instanceId = instanceId, wingKey = wingKey }
end

-- Every quest id the catalog knows (dungeon, optional, prerequisite,
-- repeatable): what a per-quest completion check must ask. Sorted.
function R.AllQuestIds()
    if cache.allIds then return cache.allIds end
    local tables = data()
    local ids = {}
    for questId in pairs(tables and tables.quests or {}) do table.insert(ids, questId) end
    table.sort(ids)
    cache.allIds = ids
    return ids
end

-- The rules ---------------------------------------------------------------------------

-- Is the quest known done (true), known not done (false), or unknown (nil)?
local function doneState(state, questId)
    local completed = state.completed
    if completed.ids[questId] then return true end
    if completed.coverage == "full" then return false end
    if completed.coverage == "checked" and completed.checked[questId] then return false end
    return nil
end

local function inLog(state, questId)
    if state.questLog.ids[questId] then return true end
    if state.questLog.coverage == "full" then return false end
    return nil
end

local function includes(list, value)
    for _, entry in ipairs(list) do if entry == value then return true end end
    return false
end

-- One quest's state for the character, and the reasons behind it.
function R.QuestState(quest, state)
    local reasons = {}
    local done = doneState(state, quest.questId)
    if done == true and not quest.repeatable then return "completed", { "completed" } end
    local logged = inLog(state, quest.questId)
    if logged == true then return "accepted", { "in-quest-log" } end
    -- Eligibility: only rules the catalog states; an unreported fact leaves
    -- the rule open.
    local eligibilityUnknown = false
    if quest.faction == "alliance" or quest.faction == "horde" then
        if state.faction == nil then eligibilityUnknown = true
        elseif state.faction ~= quest.faction then return "ineligible", { "faction" } end
    elseif not quest.factionKnown then
        eligibilityUnknown = true
    end
    if quest.races then
        if state.race == nil then eligibilityUnknown = true
        elseif not includes(quest.races, state.race) then return "ineligible", { "race" } end
    end
    if quest.classes then
        if state.classToken == nil then eligibilityUnknown = true
        elseif not includes(quest.classes, state.classToken) then return "ineligible", { "class" } end
    end
    if quest.minLevel and quest.minLevel ~= 0 then
        if state.level == nil then eligibilityUnknown = true
        elseif state.level < quest.minLevel then return "ineligible", { "level-below-minimum" } end
    end
    if quest.maxLevel and quest.maxLevel ~= 0 and state.level ~= nil and state.level > quest.maxLevel then return "ineligible", { "level-above-maximum" } end
    if quest.requiresReputation then
        eligibilityUnknown = true
        table.insert(reasons, "reputation-not-reported")
    end
    local prerequisitesUnknown = false
    for _, prerequisite in ipairs(quest.prerequisites or {}) do
        local met
        if prerequisite.mustBeActive then met = inLog(state, prerequisite.questId) else met = doneState(state, prerequisite.questId) end
        if met == false then return "prerequisites", { "prerequisite:" .. prerequisite.questId } end
        if met == nil then prerequisitesUnknown = true end
    end
    if quest.prerequisitesKnown == false then prerequisitesUnknown = true end
    if eligibilityUnknown then table.insert(reasons, "eligibility-not-reported") end
    if prerequisitesUnknown then
        table.insert(reasons, quest.prerequisitesKnown == false and "prerequisites-not-known" or "prerequisite-state-not-reported")
    end
    if done == nil and not quest.repeatable then table.insert(reasons, "completion-not-reported") end
    if logged == nil then table.insert(reasons, "quest-log-not-reported") end
    if #reasons > 0 then return "unknown", reasons end
    return "available", reasons
end

-- Where one prerequisite stands: "done", "accepted", "missing" or "unknown".
function R.PrerequisiteStatus(prerequisite, state)
    local logged = inLog(state, prerequisite.questId)
    if prerequisite.mustBeActive then
        return logged == true and "accepted" or (logged == false and "missing" or "unknown")
    end
    local done = doneState(state, prerequisite.questId)
    if done == true then return "done" end
    if logged == true then return "accepted" end
    return done == false and "missing" or "unknown"
end

-- A state that reports nothing: every quest that depends on the character
-- is unknown, so readiness is never "ready" from it.
function R.EmptyState()
    return { completed = { coverage = "none", ids = {}, checked = {} }, questLog = { coverage = "none", ids = {} } }
end

-- Readiness for catalog entries ({ quest, relevance, wing }), as Holdfast's
-- evaluateReadiness: { readiness, counts, required, quests, optional,
-- prerequisites, repeatable, unknownRelevance }, each entry
-- { quest, relevance, wing, state, reasons }.
function R.Evaluate(entries, state, wingKey)
    state = state or R.EmptyState()
    local rows, required = {}, {}
    local groups = { dungeon = {}, optional = {}, prerequisite = {}, repeatable = {}, unknown = {} }
    for _, entry in ipairs(entries or {}) do
        if entry.relevance ~= "zone" and (not wingKey or not entry.wing or entry.wing == wingKey) then
            local questState, reasons = R.QuestState(entry.quest, state)
            local row = { quest = entry.quest, relevance = entry.relevance, wing = entry.wing, state = questState, reasons = reasons }
            table.insert(rows, row)
            if groups[entry.relevance] then table.insert(groups[entry.relevance], row) end
            if entry.relevance == "dungeon" and questState ~= "ineligible" then table.insert(required, row) end
        end
    end
    local counts = {}
    for _, name in ipairs(R.QUEST_STATES) do counts[name] = 0 end
    for _, row in ipairs(required) do counts[row.state] = counts[row.state] + 1 end
    local readiness
    if #required == 0 then readiness = "none"
    elseif counts.available > 0 then readiness = "missing"
    elseif counts.prerequisites > 0 then readiness = "blocked"
    elseif counts.unknown > 0 then readiness = "unknown"
    else readiness = "ready" end
    return {
        readiness = readiness, counts = counts, required = #required,
        quests = groups.dungeon, optional = groups.optional, prerequisites = groups.prerequisite,
        repeatable = groups.repeatable, unknownRelevance = groups.unknown,
    }
end

-- Readiness of the current character for a guide page (a dungeon or a
-- wing): the evaluation, plus questList ("curated" | "unknown") and the
-- state it was read from. Nil when the catalog has no entry for it.
function R.ForGuide(guideId, state)
    local catalog = R.Catalog(guideId)
    if not catalog then return nil end
    if not state then
        local quests = GW.CharacterQuests
        state = quests and type(quests.State) == "function" and quests.State() or nil
    end
    local result = R.Evaluate(catalog.entries, state, catalog.wingKey)
    result.questList = catalog.curated and "curated" or "unknown"
    result.state = state
    return result
end

-- Short words for the journal.
R.READINESS_LABELS = {
    ready = "Ready", missing = "Quests to pick up", blocked = "Blocked", unknown = "Not known", none = "No dungeon quests",
}
-- The overview line's words.
R.OVERVIEW_LABELS = {
    ready = "Quests ready", missing = "Quests to pick up", blocked = "Quests blocked", unknown = "Quests not known", none = "No quest list known",
}
R.STATE_LABELS = {
    completed = "Completed", accepted = "In quest log", available = "Pick up", prerequisites = "Needs an earlier quest",
    ineligible = "Not for you", unknown = "Not known",
}

-- One line: "2 of 5 required done, 1 in the quest log, 2 to pick up".
function R.Summary(result)
    if not result then return nil end
    local counts = result.counts
    if result.required == 0 then
        return result.questList == "unknown" and "No quest list is known for this dungeon yet. That does not mean it has none."
            or "No dungeon quests apply to you."
    end
    local parts = { string.format("%d of %d required done", counts.completed, result.required) }
    if counts.accepted > 0 then table.insert(parts, counts.accepted .. " in the quest log") end
    if counts.available > 0 then table.insert(parts, counts.available .. " to pick up") end
    if counts.prerequisites > 0 then table.insert(parts, counts.prerequisites .. " waiting on an earlier quest") end
    if counts.unknown > 0 then table.insert(parts, counts.unknown .. " not known") end
    return table.concat(parts, ", ")
end

-- Why a quest is "unknown", in a few words.
function R.UnknownReason(reasons)
    local set = {}
    for _, reason in ipairs(reasons or {}) do set[reason] = true end
    if set["prerequisites-not-known"] then return "its quest chain is not known" end
    if set["completion-not-reported"] or set["quest-log-not-reported"] then return "your quest data could not be read" end
    if set["reputation-not-reported"] then return "needs a reputation" end
    if set["prerequisite-state-not-reported"] then return "earlier quests could not be checked" end
    if set["eligibility-not-reported"] then return "who can take it is not known" end
    return nil
end
