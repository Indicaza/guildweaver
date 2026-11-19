-- Reference loot from Holdfast #301 in the addon: who lists each item (the
-- exporter's per-creature `ls` codes), a boss's own chest, shared drops named
-- by their sources, the per-creature cap that fails loudly instead of
-- cutting, and the packaged data seen through the journal (Naxxramas,
-- Majordomo, The Seven, the wings).

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

local function read(path)
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    return text
end

local COMMIT = "943fcdf01844efb4151a22f4ff5decfe8e78a75a"

local function find(list, field, value)
    for _, entry in ipairs(list) do if entry[field] == value then return entry end end
end

-- 1. The exporter on the mini fixtures, with #301's fields ---------------------------
do
    local atlas = Export.decode(read("test/fixtures/atlas_mini.json"))
    local loot = Export.decode(read("test/fixtures/reference_loot_mini.json"))
    local deadmines = find(loot.dungeons, "instanceId", 36)
    local vancleef = find(deadmines.bosses, "encounterId", 2747)
    -- 2874, 5191: the emulator; 5191 also DungeonPlanner; 5193, 5202, 10399: DungeonPlanner only.
    vancleef.sources = { azerothcore = { 2874, 5191 }, ["dungeon-planner"] = { 5191, 5193, 5202, 10399 } }
    vancleef.chests = { { objectId = 1, name = "Defias Strongbox" } }
    deadmines.dungeonLoot[1] = { itemId = 1930, sources = {
        { npcId = 598, name = "Defias Miner" }, { npcId = 599, name = "Defias Pirate" }, { npcId = 600, name = "Defias Taskmaster" },
        { npcId = 601, name = "Defias Watchman" }, { npcId = 602, name = "Defias Overseer" } } }
    deadmines.dungeonLoot[2].sources = { { npcId = 642, name = "Sneed's Shredder" } }
    local normalized, problems = Export.normalize(atlas, loot)
    equal(#problems, 0, table.concat(problems, "; "))
    local text = Export.render(normalized, COMMIT)
    local data = assert((loadstring or load)(text, "=generated"))("Guildweaver", {})
    local dungeon = data.dungeons[36]()
    local boss = find(dungeon.bosses, "e", 2747)
    equal(table.concat(boss.loot, ","), "2874,5191,5193,5202,10399")
    equal(boss.ls, "13222", "one digit per item: 1 emulator, 2 DungeonPlanner, 3 both")
    equal(boss.chest, "Defias Strongbox", "the boss's own chest by name")
    local rhahk = find(dungeon.bosses, "e", 2741)
    equal(rhahk.ls, nil, "no sources in the file: no codes")
    equal(rhahk.chest, nil)
    equal(find(dungeon.other, "item", 1930).from, "Defias Miner, Defias Pirate, Defias Taskmaster and 2 more", "several sources, named")
    equal(find(dungeon.other, "item", 1937).from, "Sneed's Shredder", "one source, by name")

    -- More than MAX_LOOT drops: a problem that stops the export, never a cut.
    local many = Export.decode(read("test/fixtures/reference_loot_mini.json"))
    local template = many.items["5191"]
    local list = {}
    for index = 1, Export.MAX_LOOT + 1 do
        local id = 90000 + index
        local copy = {}
        for key, value in pairs(template) do copy[key] = value end
        copy.itemId, copy.itemKey = id, "i:" .. id
        many.items[tostring(id)] = copy
        list[index] = id
    end
    find(find(many.dungeons, "instanceId", 36).bosses, "encounterId", 2747).itemIds = list
    local _, tooMany = Export.normalize(Export.decode(read("test/fixtures/atlas_mini.json")), many)
    truthy(#tooMany == 1 and tooMany[1]:find("more than MAX_LOOT", 1, true), "reported: " .. table.concat(tooMany, "; "))
    list[#list] = nil
    local _, fits = Export.normalize(Export.decode(read("test/fixtures/atlas_mini.json")), many)
    equal(#fits, 0, "exactly MAX_LOOT is fine")
end

-- 2. The packaged data through the journal ----------------------------------------------
do
    local env = Env.new()
    local addon = env:load()
    _G.IsInInstance = function() return false, "none" end
    _G.GetInstanceInfo = function() return "Elwynn Forest", "none", 0, "", 0, 0, false, 0 end
    env:login()
    env:advance(3)
    local guide = addon.DungeonGuide
    local data = addon.DungeonAtlasData
    equal(data.source.commit, "74f0d9b0b5ac3475bc7f9a71b5e4b7222cb2904a", "Holdfast main after #301")

    -- Lazy: nothing built at login.
    for id in pairs(guide.Index()) do falsy(guide.IsBuilt(id), "dungeon " .. id .. " is built only when asked") end

    -- Naxxramas: every boss has loot now, all from DungeonPlanner.
    local naxx = guide.Dungeon(533)
    equal(#naxx.bosses, 15)
    for _, boss in ipairs(naxx.bosses) do
        truthy(boss.loot and #boss.loot > 0, boss.name .. " has loot")
        truthy(not string.find(boss.ls or "", "[13]"), boss.name .. ": DungeonPlanner only (the emulator's is WotLK)")
    end
    local rows = guide.SourceLoot(533, naxx.bosses[1])
    equal(rows[1].listedBy, "DungeonPlanner")

    -- Majordomo: his loot is the Cache of the Firelord, listed by both sources.
    local mc = guide.Dungeon(409)
    local majordomo = find(mc.bosses, "npc", 12018)
    equal(majordomo.chest, "Cache of the Firelord")
    local seen = false
    for index, itemId in ipairs(majordomo.loot) do
        if itemId == 18646 then seen = true; equal(guide.ListedBy(majordomo, index), "AzerothCore and DungeonPlanner") end
    end
    truthy(seen, "The Eye of Divinity on Majordomo")
    for _, entry in ipairs(mc.other) do truthy(entry.item ~= 18646, "a boss's chest is not shared loot too") end

    -- The Seven: their chest, through DungeonPlanner's representative NPC.
    local seven = find(guide.Dungeon(230).bosses, "name", "The Seven")
    truthy(seven.loot and #seven.loot > 0)
    equal(seven.chest, "Chest of The Seven")

    -- Ruins of Ahn'Qiraj: the long lists arrive whole (they were cut at 40).
    local longest = 0
    for _, boss in ipairs(guide.Dungeon(509).bosses) do longest = math.max(longest, #(boss.loot or {})) end
    equal(longest, 50)

    -- Every shared drop names where it comes from.
    for id in pairs(guide.Index()) do
        for _, entry in ipairs(guide.Dungeon(id).other or {}) do truthy(entry.from, "dungeon " .. id .. " item " .. entry.item .. " names its source") end
    end

    -- Wings: an item only a sibling wing's creatures drop never shows.
    local function owned(key)
        local set = {}
        local dungeon = guide.Dungeon(key)
        for _, list in ipairs({ dungeon.bosses, dungeon.rares }) do
            for _, creature in ipairs(list) do for _, itemId in ipairs(creature.loot or {}) do set[itemId] = true end end
        end
        return set
    end
    for _, parent in ipairs({ 189, 429, 329, 229 }) do
        local keys = guide.WingsOf(parent)
        for _, key in ipairs(keys) do
            local mine = owned(key)
            local listed = {}
            for _, row in ipairs(guide.LootRows(key)) do listed[row.itemId] = row end
            for _, other in ipairs(keys) do
                if other ~= key then
                    for itemId in pairs(owned(other)) do
                        if not mine[itemId] and listed[itemId] then
                            truthy(listed[itemId].kind == "other" or listed[itemId].kind == "wishlist",
                                key .. ": " .. itemId .. " is " .. other .. "'s and only shared here")
                        end
                    end
                end
            end
        end
    end
    -- Item facts for every item the journal lists.
    for id in pairs(guide.Index()) do
        for _, row in ipairs(guide.LootRows(id)) do
            if row.kind ~= "wishlist" then truthy(row.item and row.item.n and row.item.q, "facts for item " .. row.itemId) end
        end
    end
end

print("dungeon loot sources tests passed")
