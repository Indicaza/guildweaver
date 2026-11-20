-- Loot intelligence in the journal (PR 4): the exporter carries Holdfast's
-- loot relationships (reference drop rates per boss drop, ForeverDB's own boss
-- drops) and the item definitions' quest-item and WoW Forever flags; the
-- guide reads them; the item tooltip shows the rate with ForeverDB's credit.
-- Guildweaver's observed rates are on the website (they come from the
-- server), not in the packaged file.

local Env = dofile("test/support/wow_env.lua")
local Export = dofile("scripts/exportDungeonAtlas.lua")

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
local function contains(text, part, label)
    if not string.find(tostring(text), part, 1, true) then error((label or "text") .. ": " .. tostring(text) .. " lacks " .. part, 2) end
end

-- 1. The exporter on fixtures: rates in loot order, ForeverDB's drops, flags --------------
do
    local atlas = Export.decode(read("test/fixtures/atlas_mini.json"))
    local loot = Export.decode(read("test/fixtures/reference_loot_mini.json"))
    local deadmines
    for _, dungeon in ipairs(atlas.dungeons) do if dungeon.instanceId == 36 then deadmines = dungeon end end
    local boss = deadmines.bosses[#deadmines.bosses]
    local refBoss
    for _, dungeon in ipairs(loot.dungeons) do
        if dungeon.instanceId == 36 then
            for _, entry in ipairs(dungeon.bosses) do
                if (boss.encounterId and entry.encounterId == boss.encounterId) or (boss.npcId and entry.npcId == boss.npcId) then refBoss = entry end
            end
        end
    end
    truthy(refBoss and #refBoss.itemIds > 0, "the fixture boss has loot")
    local first = refBoss.itemIds[1]
    -- A quest item in the reference loot.
    loot.items[tostring(first)].kind = "quest-item"
    local relationships = { dataset = "loot-relationships", sources = { { source = "foreverdb", revision = "test", attribution = "Data from ForeverDB.net" } },
        dungeons = { { instanceId = 36, bosses = { { encounterId = boss.encounterId, npcId = boss.npcId, name = boss.name, items = {
            { itemId = first, scope = "boss", listedBy = { "azerothcore" }, rates = { { source = "foreverdb", method = "observed", percent = 22.222, kills = 27 } } },
            { itemId = 271201, scope = "boss", listedBy = {}, rates = { { source = "foreverdb", method = "observed", percent = 23.53, kills = 17 } } },
            { itemId = 2970, scope = "corpse", listedBy = {}, rates = { { source = "foreverdb", method = "observed", percent = 5.88, kills = 17 } } },
        } } } } },
        items = {
            ["271201"] = { itemId = 271201, name = "Atrophic Girdle", qualityId = Export.decode("null"), slot = "Waist", itemSubclass = "Mail", kind = "gear",
                factSources = { "wago-forever", "foreverdb" } },
            ["2970"] = { itemId = 2970, name = "Swift Boots", qualityId = 2, kind = "gear", factSources = { "wago-classic-era" } },
        } }
    local normalized, problems = Export.normalize(atlas, loot, nil, nil, relationships)
    equal(#problems, 0, table.concat(problems, "; "))
    local exported
    for _, dungeon in ipairs(normalized.dungeons) do
        if dungeon.id == 36 then exported = dungeon.bosses[#dungeon.bosses] end
    end
    local last = exported.loot[#exported.loot]
    equal(last, 271201, "ForeverDB's own drop appended")
    equal(string.sub(exported.lootSources, #exported.loot, #exported.loot), "4", "listed by ForeverDB")
    for _, itemId in ipairs(exported.loot) do truthy(itemId ~= 2970, "a corpse-only drop is not the boss's loot") end
    contains(exported.rates, "22.22:27:o", "the first drop's rate")
    contains(exported.rates, "23.53:17:o", "the girdle's rate")
    equal(normalized.items[271201].forever, true, "a WoW Forever item")
    equal(normalized.items[271201].quality, nil, "quality unknown stays unknown")
    equal(normalized.items[first].questItem, true, "a quest item")
    local text = Export.render(normalized, "abcdef0")
    contains(text, "credit=\"Data from ForeverDB.net\"", "the credit travels with the data")
    local data = assert((loadstring or load)(text, "=generated"))("Guildweaver", {})
    local items = data.items()
    equal(items[271201].fv, true)
    equal(items[first].qi, true)
    equal(items[271201].q, nil)
    local ok = pcall(Export.normalize, atlas, loot, nil, nil, { dataset = "something-else" })
    equal(ok, false, "an unknown relationships file is refused")
end

-- 2. The packaged data through the guide and the tooltip -----------------------------------
do
    local env = Env.new()
    local addon = env:load()
    _G.IsInInstance = function() return false, "none" end
    _G.GetInstanceInfo = function() return "Elwynn Forest", "none", 0, "", 0, 0, false, 0 end
    env:login()
    env:advance(3)
    local guide, guideUI = addon.DungeonGuide, addon.DungeonGuideUI
    local ruins = guide.Dungeon(2999)
    local witherfang
    for _, boss in ipairs(ruins.bosses) do if boss.name == "Witherfang" then witherfang = boss end end
    local rows = guide.SourceLoot(2999, witherfang)
    local girdle
    for _, row in ipairs(rows) do if row.itemId == 271201 then girdle = row end end
    truthy(girdle, "Witherfang drops the Atrophic Girdle")
    equal(girdle.item.n, "Atrophic Girdle")
    equal(girdle.item.fv, true)
    equal(girdle.rate.method, "observed")
    truthy(girdle.rate.kills > 0 and girdle.rate.percent > 0)
    contains(guide.RateText(girdle.rate), "% (ForeverDB, ")
    local strain
    for _, row in ipairs(rows) do if row.itemId == 275443 then strain = row end end
    truthy(strain and strain.item.qi, "the quest item is marked")
    -- VanCleef: Classic loot with Forever rates.
    local vancleef
    for _, boss in ipairs(guide.Dungeon(36).bosses) do if boss.name == "Edwin VanCleef" then vancleef = boss end end
    local rated = 0
    for _, row in ipairs(guide.SourceLoot(36, vancleef)) do if row.rate then rated = rated + 1 end end
    truthy(rated > 0, "VanCleef's drops have rates")

    -- The tooltip: rate, unknown quality, the Forever note and the credit.
    local lines = {}
    rawset(_G.GameTooltip, "AddLine", function(_, text) table.insert(lines, text) end)
    rawset(_G.GameTooltip, "SetHyperlink", function() error("not cached") end)
    rawset(_G.GameTooltip, "SetOwner", function() end)
    guideUI.ShowItemTooltip({}, girdle)
    local all = table.concat(lines, "\n")
    contains(all, "Drop rate: ")
    contains(all, "Quality not known yet")
    contains(all, "A WoW Forever item")
    contains(all, "Data from ForeverDB.net")
    equal(string.find(all, "Drop chances not shown", 1, true), nil, "not the old note when a rate is shown")
    -- A Classic item without a rate keeps the old note and no credit.
    lines = {}
    guideUI.ShowItemTooltip({}, { itemId = 5191, item = guide.Item(5191), from = "Edwin VanCleef", kind = "creature", listedBy = "AzerothCore" })
    all = table.concat(lines, "\n")
    contains(all, "Drop chances not shown")
    equal(string.find(all, "ForeverDB", 1, true), nil)
    print(string.format("packaged rates: %d of VanCleef's drops rated", rated))
end

print("loot rates spec passed")
