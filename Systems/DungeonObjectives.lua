local _, GW = ...

-- A small per-character checklist for dungeon runs ("Kill Herod", "Get the
-- Cruel Barb"). The first open objective is the current one and shows in
-- the dungeon tracker. Kept in SavedVariables (GuildweaverDB.dungeon
-- .objectives), per character, at most 20.
--
-- An objective with a boss completes on its own only when the client
-- reports that boss's kill (ENCOUNTER_END or BOSS_KILL), never from a
-- manual split and never from loot: an item in a group loot window is not
-- proof it was won. The website keeps its own list; nothing is synced
-- between them yet.
GW.DungeonObjectives = GW.DungeonObjectives or {}

local Objectives = GW.DungeonObjectives
local MAX = 20
Objectives.MAX = MAX

local function store()
    local db = GW.Store and GW.Store.GetDatabase and GW.Store.GetDatabase()
    if type(db) ~= "table" then
        return nil
    end
    db.dungeon = type(db.dungeon) == "table" and db.dungeon or {}
    db.dungeon.objectives = type(db.dungeon.objectives) == "table" and db.dungeon.objectives or {}
    return db.dungeon.objectives
end

local function currentCharacterId()
    local character = GW.Character
    local ok, snapshot = pcall(function() return character and character.GetCurrentSnapshot and character.GetCurrentSnapshot() end)
    return ok and type(snapshot) == "table" and snapshot.characterId or nil
end

local function list(characterId)
    local all = store()
    characterId = characterId or currentCharacterId()
    if not all or not characterId then
        return nil
    end
    all[characterId] = type(all[characterId]) == "table" and all[characterId] or {}
    return all[characterId]
end

local function clean(value, max)
    if type(value) ~= "string" then
        return nil
    end
    value = value:gsub("^%s+", ""):gsub("%s+$", ""):gsub("|", "")
    if value == "" then
        return nil
    end
    return string.sub(value, 1, max or 120)
end

local function normalized(value)
    return string.lower(tostring(value or "")):gsub("[^%w]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function changed()
    local hud = GW.DungeonHud
    if hud and hud.Refresh then
        pcall(hud.Refresh, hud)
    end
end

function Objectives.List(characterId)
    return list(characterId) or {}
end

-- The first objective not done, or nil.
function Objectives.Current(characterId)
    for _, objective in ipairs(Objectives.List(characterId)) do
        if not objective.done then
            return objective
        end
    end
    return nil
end

-- Adds an objective. `boss` (optional) completes it when that boss's kill
-- is reported. Returns the objective, or nil and a reason.
function Objectives.Add(text, boss)
    local entries = list()
    if not entries then return nil, "no_character" end
    text = clean(text)
    if not text then return nil, "empty" end
    if #entries >= MAX then return nil, "full" end
    local objective = { text = text, boss = clean(boss, 80), done = false }
    table.insert(entries, objective)
    changed()
    return objective
end

local function at(index)
    local entries = list()
    index = tonumber(index)
    if not entries or not index or not entries[index] then
        return nil
    end
    return entries, index
end

function Objectives.Edit(index, text)
    local entries, position = at(index)
    text = clean(text)
    if not entries or not text then return nil end
    entries[position].text = text
    changed()
    return entries[position]
end

function Objectives.SetDone(index, done)
    local entries, position = at(index)
    if not entries then return nil end
    entries[position].done = done == true
    entries[position].doneBy = done and "manual" or nil
    changed()
    return entries[position]
end

-- Moves an objective up (-1) or down (+1).
function Objectives.Move(index, step)
    local entries, position = at(index)
    if not entries then return nil end
    local target = position + (step < 0 and -1 or 1)
    if target < 1 or target > #entries then return nil end
    entries[position], entries[target] = entries[target], entries[position]
    changed()
    return target
end

function Objectives.Remove(index)
    local entries, position = at(index)
    if not entries then return nil end
    local removed = table.remove(entries, position)
    changed()
    return removed
end

-- Called by DungeonSessions for every reported (never manual) boss kill.
function Objectives.NoteBossKill(characterId, bossName)
    local entries = list(characterId)
    local name = normalized(bossName)
    if not entries or name == "" then
        return 0
    end
    local completed = 0
    for _, objective in ipairs(entries) do
        if not objective.done and objective.boss and normalized(objective.boss) == name then
            objective.done = true
            objective.doneBy = "boss_kill"
            completed = completed + 1
        end
    end
    if completed > 0 then changed() end
    return completed
end
