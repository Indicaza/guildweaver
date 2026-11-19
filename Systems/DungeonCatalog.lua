local _, GW = ...

-- What the client says about instances, for the people who keep the
-- Dungeon Atlas: an instance the packaged atlas does not know (a new WoW
-- Forever dungeon, a raid) is kept as a candidate, and what the client
-- reports for WoW Forever's own dungeons (its name for the instance, its
-- lockout's encounter count) is kept beside the atlas's. Nothing here is
-- published: candidates stay in SavedVariables, and /gw dungeon catalog
-- prints them for a maintainer to check and add to Holdfast by hand.
--
-- Costs: one table write when DungeonSessions reads the instance (entering
-- the world or changing zone, never per frame and never in combat). The
-- LFG activity scan runs only for /gw dungeon catalog, out of combat.
GW.DungeonCatalog = GW.DungeonCatalog or {}

local Catalog = GW.DungeonCatalog
local Globals = _G or {}

Catalog.MAX_CANDIDATES = 20
Catalog.MAX_ACTIVITIES = 600

local function store()
    local db = GW.Store and GW.Store.GetDatabase and GW.Store.GetDatabase()
    if type(db) ~= "table" then return nil end
    db.dungeon = type(db.dungeon) == "table" and db.dungeon or {}
    local catalog = type(db.dungeon.catalog) == "table" and db.dungeon.catalog or {}
    db.dungeon.catalog = catalog
    catalog.candidates = type(catalog.candidates) == "table" and catalog.candidates or {}
    catalog.forever = type(catalog.forever) == "table" and catalog.forever or {}
    return catalog
end

local function now()
    local ok, value = pcall(Globals.GetServerTime or Globals.time or function() return 0 end)
    return ok and tonumber(value) or 0
end

local function index()
    local atlas = GW.DungeonAtlasData
    return type(atlas) == "table" and type(atlas.index) == "table" and atlas.index or nil
end

-- Bounded: the least recently seen candidate goes first.
local function trim(candidates)
    local ids = {}
    for id in pairs(candidates) do table.insert(ids, id) end
    if #ids <= Catalog.MAX_CANDIDATES then return end
    table.sort(ids, function(a, b)
        local la, lb = tonumber(candidates[a].lastSeen) or 0, tonumber(candidates[b].lastSeen) or 0
        if la ~= lb then return la < lb end
        return a < b
    end)
    for position = 1, #ids - Catalog.MAX_CANDIDATES do candidates[ids[position]] = nil end
end

-- The instance DungeonSessions read ({ instanceId, name, type,
-- difficultyId, maxPlayers }), and the lockout's encounter total when known.
function Catalog.Note(instance, lockTotal)
    local id = type(instance) == "table" and tonumber(instance.instanceId) or nil
    local known = index()
    if not id or id <= 0 or not known then return nil end
    local catalog = store()
    if not catalog then return nil end
    local entry = known[id]
    local at = now()
    if not entry then
        local candidate = catalog.candidates[id] or { firstSeen = at, visits = 0 }
        candidate.name = type(instance.name) == "string" and string.sub(instance.name, 1, 80) or candidate.name
        candidate.type, candidate.difficultyId, candidate.maxPlayers = instance.type, tonumber(instance.difficultyId), tonumber(instance.maxPlayers)
        candidate.lockTotal = tonumber(lockTotal) or candidate.lockTotal
        candidate.lastSeen, candidate.visits = at, (tonumber(candidate.visits) or 0) + 1
        catalog.candidates[id] = candidate
        trim(catalog.candidates)
        return "candidate"
    end
    if entry.origin == "forever" then
        local seen = catalog.forever[id] or { firstSeen = at, visits = 0 }
        seen.name = type(instance.name) == "string" and string.sub(instance.name, 1, 80) or seen.name
        seen.lockTotal = tonumber(lockTotal) or seen.lockTotal
        seen.lastSeen, seen.visits = at, (tonumber(seen.visits) or 0) + 1
        catalog.forever[id] = seen
        return "forever"
    end
    return "known"
end

-- LFG activities whose instance map the atlas does not know, by map ID.
-- Defensive: any missing function or odd value gives nothing.
function Catalog.UnknownActivities()
    local lfg = Globals.C_LFGList
    local known = index() or {}
    if type(lfg) ~= "table" or type(lfg.GetAvailableActivities) ~= "function" or type(lfg.GetActivityInfoTable) ~= "function" then
        return nil
    end
    local ok, activities = pcall(lfg.GetAvailableActivities)
    if not ok or type(activities) ~= "table" then return nil end
    local found, seen = {}, {}
    for position, activityId in ipairs(activities) do
        if position > Catalog.MAX_ACTIVITIES then break end
        local okInfo, info = pcall(lfg.GetActivityInfoTable, activityId)
        local mapId = okInfo and type(info) == "table" and tonumber(info.mapID) or nil
        if mapId and mapId > 0 and not known[mapId] and not seen[mapId] then
            seen[mapId] = true
            table.insert(found, { mapId = mapId, activityId = activityId, name = type(info.fullName) == "string" and info.fullName or nil })
        end
    end
    table.sort(found, function(a, b) return a.mapId < b.mapId end)
    return found
end

local function inCombat()
    local fn = Globals.InCombatLockdown
    local ok, value = pcall(fn or function() return false end)
    return ok and value == true
end

-- The maintainer report: the atlas's coverage, what the client said about
-- WoW Forever's dungeons, candidates, and (out of combat) LFG activities.
function Catalog.Report()
    local known = index()
    if not known then return { "No Dungeon Atlas is packaged with this add-on." } end
    local lines, classic, forever = {}, 0, {}
    for id, entry in pairs(known) do
        if entry.origin == "forever" then table.insert(forever, id) else classic = classic + 1 end
    end
    table.sort(forever)
    local source = GW.DungeonAtlasData.source or {}
    table.insert(lines, string.format("Dungeon Atlas: %d instances (%d original, %d WoW Forever), Holdfast %s.", classic + #forever, classic, #forever,
        string.sub(tostring(source.commit or "?"), 1, 7)))
    local catalog = store() or { candidates = {}, forever = {} }
    for _, id in ipairs(forever) do
        local entry, seen = known[id], catalog.forever[id]
        local text = string.format("  %d %s: %d bosses in the atlas", id, tostring(entry.name), tonumber(entry.bosses) or 0)
        if seen then
            text = text .. string.format("; client: %q, lockout %s encounters, %d visits", tostring(seen.name), seen.lockTotal and tostring(seen.lockTotal) or "?",
                tonumber(seen.visits) or 0)
            if seen.lockTotal and tonumber(entry.bosses) and seen.lockTotal ~= entry.bosses then text = text .. " (counts differ)" end
        else
            text = text .. "; not entered yet"
        end
        table.insert(lines, text)
    end
    local ids = {}
    for id in pairs(catalog.candidates) do table.insert(ids, id) end
    table.sort(ids)
    if #ids == 0 then
        table.insert(lines, "No unknown instances entered.")
    else
        table.insert(lines, "Entered, not in the atlas (check, then add to Holdfast):")
        for _, id in ipairs(ids) do
            local c = catalog.candidates[id]
            table.insert(lines, string.format("  %d %q %s, difficulty %s, %s players, lockout %s encounters, %d visits", id, tostring(c.name), tostring(c.type),
                tostring(c.difficultyId or "?"), tostring(c.maxPlayers or "?"), c.lockTotal and tostring(c.lockTotal) or "?", tonumber(c.visits) or 0))
        end
    end
    if inCombat() then
        table.insert(lines, "LFG activities: not scanned in combat.")
    else
        local activities = Catalog.UnknownActivities()
        if activities == nil then
            table.insert(lines, "LFG activities: the client offers no activity list.")
        elseif #activities == 0 then
            table.insert(lines, "LFG activities: every instance map is in the atlas.")
        else
            table.insert(lines, "LFG activities for instance maps not in the atlas:")
            for _, a in ipairs(activities) do
                table.insert(lines, string.format("  map %d: %s (activity %s)", a.mapId, tostring(a.name or "?"), tostring(a.activityId)))
            end
        end
    end
    return lines
end
