-- Build-time exporter: Holdfast's dungeon quest catalog ->
-- Data/DungeonQuests.generated.lua, the quests the in-game readiness rules
-- (Systems/DungeonReadiness.lua) read. Packaged with the add-on; the game
-- never downloads or parses anything.
--
--   lua5.1 scripts/exportDungeonQuests.lua [--check] --quests <quest-catalog.json>
--       --commit <holdfast sha> [--out <file.lua>]
--
-- Input: Indicaza/holdfast backend/src/Atlas/data/quest-catalog.json (sprint
-- step 4A, docs/dungeon-quest-readiness.md). Every quest a dungeon shows by
-- default is kept, with no cap: dungeon, optional, prerequisite, repeatable
-- and unknown relevance. Zone-only quests (relevance "zone": raid turn-ins
-- only the zone ties to a dungeon) are left out, as the website hides them.
-- What a rule needs is kept as the catalog says it, and nothing more:
-- faction (unknown stays unknown), races, classes, levels, repeatable,
-- reputation, prerequisite ids (and mustBeActive), whether the chain is
-- known, the wing, the giver's name and single spawn (zone, UiMap id and
-- coordinates; the UiMap id is projected from AzerothCore spawns, so the
-- add-on checks it against the client before setting a waypoint), and
-- whether the quest can be shared (AzerothCore's SHARABLE flag; unknown
-- stays unknown). No objectives or rewards: the atlas file has those for
-- the quests it lists.
--
-- Memory: the file defines one function. The client builds the tables only
-- when the guide or the quest capture first asks (GW.DungeonQuestData.load).
-- Output is deterministic (--check verifies the packaged file).

local Export = dofile("scripts/exportDungeonAtlas.lua")

local Quests = {}

Quests.SCHEMA = 1
Quests.MAX_BYTES = 262144 -- 256 KB: a problem stops the export, nothing is cut
local RELEVANCE = { dungeon = "d", optional = "o", prerequisite = "p", repeatable = "r", unknown = "u" }
local FACTIONS = { alliance = "A", horde = "H", both = "B" }
local CLASS_TOKENS = { WARRIOR = true, PALADIN = true, HUNTER = true, ROGUE = true, PRIEST = true, SHAMAN = true, MAGE = true, WARLOCK = true, DRUID = true }

local null = Export.decode("null")
local function present(value) if value ~= null then return value end end
local function int(value)
    value = present(value)
    if type(value) == "number" and value == math.floor(value) then return value end
end
local function str(value, max)
    value = present(value)
    if type(value) ~= "string" or value == "" then return nil end
    return string.sub(value, 1, max or 120)
end
local function list(value)
    value = present(value)
    return type(value) == "table" and value or {}
end
local function permille(value)
    value = present(value)
    if type(value) ~= "number" or value < 0 or value > 1 then return nil end
    return math.floor(value * 1000 + 0.5)
end

local function problem(problems, text) table.insert(problems, text) end

-- One quest's record from its catalog entry (the same quest is the same in
-- every dungeon that lists it).
local function questOf(raw, problems)
    local id, name = int(raw.questId), str(raw.name, 80)
    if not id or not name then
        problem(problems, "a quest without an id or name: " .. tostring(raw.questId))
        return nil
    end
    local races, classes = {}, {}
    for _, race in ipairs(list(raw.races)) do
        if type(race) == "string" and string.find(race, "^%a+$") then table.insert(races, race)
        else problem(problems, "quest " .. id .. ": a race that is not a token") end
    end
    for _, class in ipairs(list(raw.classes)) do
        if CLASS_TOKENS[class] then table.insert(classes, class)
        else problem(problems, "quest " .. id .. ": a class that is not a token") end
    end
    local prereqs = {}
    for _, pre in ipairs(list(raw.prerequisites)) do
        local preId = int(present(pre) and pre.questId)
        if preId then table.insert(prereqs, present(pre.mustBeActive) == true and -preId or preId) end
    end
    local giver = present(raw.giver)
    local location = type(giver) == "table" and present(giver.location) or nil
    -- false: the catalog does not know who may take it (never "both").
    local faction = present(raw.faction)
    if faction == nil then faction = false else faction = FACTIONS[faction] end
    local shareable = present(raw.shareable)
    return {
        id = id, name = name, level = int(raw.level), minLevel = int(raw.minLevel), maxLevel = int(raw.maxLevel),
        faction = faction,
        repeatable = present(raw.repeatable) == true,
        share = shareable == "yes" and "s" or (shareable == "no" and "n" or nil),
        prek = present(raw.prerequisitesKnown) ~= false,
        rep = present(raw.requiresReputation) ~= nil,
        races = #races > 0 and table.concat(races, ",") or nil,
        classes = #classes > 0 and table.concat(classes, ",") or nil,
        prereqs = prereqs,
        giver = type(giver) == "table" and str(giver.name, 60) or nil,
        zone = type(location) == "table" and str(location.zoneName, 40) or nil,
        mapId = type(location) == "table" and int(location.mapId) or nil,
        x = type(location) == "table" and permille(location.x) or nil,
        y = type(location) == "table" and permille(location.y) or nil,
        item = int(raw.startsFromItem),
    }
end

-- The catalog as the generated file's tables: quests by id, and per dungeon
-- whether a source lists its quests and its quests in catalog order, each
-- with its relevance and wing.
function Quests.normalize(catalog)
    local problems = {}
    if type(catalog) ~= "table" or present(catalog.schemaVersion) ~= 1 then
        problem(problems, "quest catalog: schemaVersion must be 1")
        return { quests = {}, dungeons = {} }, problems
    end
    local quests, dungeons, hidden = {}, {}, 0
    for _, raw in ipairs(list(catalog.dungeons)) do
        local instanceId = int(raw.instanceId)
        if not instanceId then
            problem(problems, "a dungeon without an instance id")
        else
            local entry = { id = instanceId, curated = present(raw.curated) == true, ids = {}, rel = {}, wings = {} }
            for _, rawQuest in ipairs(list(raw.quests)) do
                local relevance = present(rawQuest.relevance)
                if relevance == "zone" then
                    hidden = hidden + 1
                elseif not RELEVANCE[relevance] then
                    problem(problems, string.format("dungeon %d quest %s: unknown relevance %s", instanceId, tostring(rawQuest.questId), tostring(relevance)))
                else
                    local quest = questOf(rawQuest, problems)
                    if quest then
                        quests[quest.id] = quests[quest.id] or quest
                        table.insert(entry.ids, quest.id)
                        table.insert(entry.rel, RELEVANCE[relevance])
                        entry.wings[#entry.ids] = str(rawQuest.wing, 80)
                    end
                end
            end
            table.insert(dungeons, entry)
        end
    end
    table.sort(dungeons, function(a, b) return a.id < b.id end)
    return { quests = quests, dungeons = dungeons, hidden = hidden }, problems
end

local function quote(value) return string.format("%q", value) end
local function scalar(value)
    if value == nil then return "nil" end
    if value == true then return "true" end
    if value == false then return "false" end
    if type(value) == "number" then return tostring(value) end
    return quote(value)
end

local function sortedKeys(map)
    local keys = {}
    for key in pairs(map) do table.insert(keys, key) end
    table.sort(keys)
    return keys
end

-- Each quest is one positional row (see the field list in the file).
function Quests.render(n, commit)
    -- A zone is its name and UiMap id (a name without a map is its own entry).
    local zones, zoneMaps, zoneIndex = {}, {}, {}
    local function zoneKey(q) return q.zone and (q.zone .. "|" .. tostring(q.mapId or "")) or nil end
    for _, id in ipairs(sortedKeys(n.quests)) do
        local q = n.quests[id]
        local key = zoneKey(q)
        if key and not zoneIndex[key] then
            table.insert(zones, q.zone)
            table.insert(zoneMaps, q.mapId or false)
            zoneIndex[key] = #zones
        end
    end
    local out = {}
    local function add(text) table.insert(out, text) end
    local questCount = #sortedKeys(n.quests)
    add("-- Generated by scripts/exportDungeonQuests.lua from Indicaza/holdfast " .. commit .. "\n")
    add("-- (backend/src/Atlas/data/quest-catalog.json). Do not edit; regenerate.\n")
    add("-- Classic reference data (AzerothCore, DungeonPlanner), not confirmed on Forever.\n")
    add("-- Quest row: { name, level, minLevel, maxLevel, faction (A/H/B, false = unknown),\n")
    add("--   flags (r repeatable, p prerequisites not known, u needs a reputation,\n")
    add("--   s shareable, n not shareable; neither = not known),\n")
    add("--   giver, zone (index into Z, its UiMap id in M), x, y (permille), startsFromItem, races, classes,\n")
    add("--   prerequisites (ids; negative = must be in the quest log) }\n")
    add("-- Dungeon: { curated, ids, relevance (one letter per id: d o p r u), wings (by position) }\n")
    add("local _, GW = ...\n")
    add(string.format("GW.DungeonQuestData = { schema = %d, source = { commit = %s, quests = %d, dungeons = %d, zoneQuestsLeftOut = %d },\n",
        Quests.SCHEMA, quote(commit), questCount, #n.dungeons, n.hidden or 0))
    add("load = function()\n")
    local zoneParts = {}
    for _, zone in ipairs(zones) do table.insert(zoneParts, quote(zone)) end
    add("local Z = { " .. table.concat(zoneParts, ", ") .. " }\n")
    local mapParts = {}
    for _, mapId in ipairs(zoneMaps) do table.insert(mapParts, scalar(mapId)) end
    add("local M = { " .. table.concat(mapParts, ", ") .. " }\n")
    add("local Q = {}\n")
    for _, id in ipairs(sortedKeys(n.quests)) do
        local q = n.quests[id]
        local flags = (q.repeatable and "r" or "") .. (q.prek and "" or "p") .. (q.rep and "u" or "") .. (q.share or "")
        local pre = {}
        for _, preId in ipairs(q.prereqs) do table.insert(pre, tostring(preId)) end
        local fields = { quote(q.name), scalar(q.level), scalar(q.minLevel), scalar(q.maxLevel), scalar(q.faction),
            flags ~= "" and quote(flags) or "nil", scalar(q.giver), scalar(zoneKey(q) and zoneIndex[zoneKey(q)]), scalar(q.x), scalar(q.y),
            scalar(q.item), scalar(q.races), scalar(q.classes), #pre > 0 and ("{" .. table.concat(pre, ",") .. "}") or "nil" }
        -- Trailing nils are left off.
        while fields[#fields] == "nil" do table.remove(fields) end
        add(string.format("Q[%d]={%s}\n", id, table.concat(fields, ",")))
    end
    add("local D = {}\n")
    for _, d in ipairs(n.dungeons) do
        local ids, wings = {}, {}
        for position, id in ipairs(d.ids) do
            table.insert(ids, tostring(id))
            if d.wings[position] then table.insert(wings, string.format("[%d]=%s", position, quote(d.wings[position]))) end
        end
        add(string.format("D[%d]={%s,{%s},%s%s}\n", d.id, scalar(d.curated), table.concat(ids, ","), quote(table.concat(d.rel)),
            #wings > 0 and (",{" .. table.concat(wings, ",") .. "}") or ""))
    end
    add("return { zones = Z, zoneMaps = M, quests = Q, dungeons = D }\n")
    add("end }\n")
    return table.concat(out)
end

function Quests.run(questsJson, commit)
    local normalized, problems = Quests.normalize(Export.decode(questsJson))
    local text = Quests.render(normalized, commit)
    if #text > Quests.MAX_BYTES then
        table.insert(problems, string.format("generated file is %d bytes (limit %d)", #text, Quests.MAX_BYTES))
    end
    return text, problems, normalized
end

local function readFile(path)
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    return text
end

local function main(args)
    local options, index = { out = "Data/DungeonQuests.generated.lua" }, 1
    while index <= #args do
        local flag = args[index]
        if flag == "--check" then
            options.check = true
            index = index + 1
        else
            options[string.gsub(flag, "^%-%-", "")] = args[index + 1]
            index = index + 2
        end
    end
    if not options.quests or not options.commit then
        io.stderr:write("usage: lua5.1 scripts/exportDungeonQuests.lua [--check] --quests <quest-catalog.json> --commit <sha> [--out <file.lua>]\n")
        os.exit(2)
    end
    local text, problems, normalized = Quests.run(readFile(options.quests), options.commit)
    if #problems > 0 then
        io.stderr:write("quest catalog problems:\n  " .. table.concat(problems, "\n  ") .. "\n")
        os.exit(1)
    end
    if options.check then
        local ok, current = pcall(readFile, options.out)
        current = ok and (string.gsub(current, "\r\n", "\n")) or nil
        if current ~= text then
            io.stderr:write(options.out .. " is not current; regenerate it\n")
            os.exit(1)
        end
        print(options.out .. " is current")
        return
    end
    local file = assert(io.open(options.out, "wb"))
    file:write(text)
    file:close()
    print(string.format("wrote %s: %d bytes, %d quests, %d dungeons", options.out, #text, #sortedKeys(normalized.quests), #normalized.dungeons))
end

local cli = { ... }
if type(cli[1]) == "string" and string.find(cli[1], "^%-%-") then
    main(cli)
end

return Quests
