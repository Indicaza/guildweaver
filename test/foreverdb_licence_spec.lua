-- ForeverDB.net's data is GPL-3.0 with its attribution term (Licenses/):
-- it lives in Data/ForeverDB.generated.lua only, keeps ForeverDB's notice
-- line, is credited (tooltip, /gw credits, Licenses/README.md, README), is
-- packaged with its licence, and the add-on works without it.

local Env = dofile("test/support/wow_env.lua")

local function equal(actual, expected, label)
    if actual ~= expected then error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2) end
end
local function truthy(value, label)
    if not value then error((label or "value") .. ": expected truthy value", 2) end
end
local function contains(text, part, label)
    if not string.find(tostring(text), part, 1, true) then error((label or "text") .. ": lacks " .. part, 2) end
end
local function read(path)
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    return (string.gsub(text, "\r\n", "\n"))
end

-- 1. The files ---------------------------------------------------------------------------------
local overlay = read("Data/ForeverDB.generated.lua")
truthy(string.find(overlay, "^%-%- Data: ForeverDB%.net %(https://foreverdb%.net%)"), "ForeverDB's notice line comes first, unchanged")
contains(overlay, "GPL-3.0 with ForeverDB.net's attribution term")
local atlas = read("Data/DungeonAtlas.generated.lua")
equal(string.find(atlas, "ForeverDB", 1, true), nil, "the atlas holds nothing from ForeverDB")
equal(string.find(atlas, "rt=", 1, true), nil, "no reference rates in the atlas")
equal(string.find(atlas, "foreverdb", 1, true), nil)
for _, name in ipairs({ "Licenses/ForeverDB-COPYING.txt", "Licenses/ForeverDB-LICENSE.txt", "Licenses/ForeverDB-NOTICE.txt", "Licenses/README.md" }) do
    truthy(#read(name) > 100, name)
end
contains(read("Licenses/ForeverDB-COPYING.txt"), "GNU GENERAL PUBLIC LICENSE")
contains(read("Licenses/ForeverDB-LICENSE.txt"), "Data from ForeverDB.net (https://foreverdb.net)")
contains(read("Licenses/README.md"), "Data/ForeverDB.generated.lua")
contains(read("README.md"), "Data from ForeverDB.net (https://foreverdb.net)")
contains(read("Guildweaver.toc"), "Data/ForeverDB.generated.lua")
contains(read(".github/workflows/release.yml"), "cp -R Licenses dist/Guildweaver/Licenses", "the licences ship in the release")

-- 2. With the file: ForeverDB's facts and rates, and the credit ---------------------------------
local function boot(withForeverDb)
    local env = Env.new()
    local addon = env:load()
    if not withForeverDb then addon.ForeverDbData = nil end
    _G.IsInInstance = function() return false, "none" end
    _G.GetInstanceInfo = function() return "Elwynn Forest", "none", 0, "", 0, 0, false, 0 end
    env:login()
    env:advance(3)
    return env, addon
end
local function witherfang(guide)
    for _, boss in ipairs(guide.Dungeon(2999).bosses) do if boss.name == "Witherfang" then return boss end end
end
local printed = {}
do
    local _, addon = boot(true)
    local guide = addon.DungeonGuide
    local boss = witherfang(guide)
    local found
    for _, row in ipairs(guide.SourceLoot(2999, boss)) do if row.itemId == 271201 then found = row end end
    truthy(found and found.item.n == "Atrophic Girdle" and found.rate, "with ForeverDB: named and rated")
    equal(#guide.UnresolvedLoot(boss), 0)
    equal(found.item.fd, true, "its facts are marked as ForeverDB's (for the credit)")
    equal(guide.ForeverDbCredit(), "Data from ForeverDB.net (https://foreverdb.net)")
    local original = addon.Print
    addon.Print = function(text) table.insert(printed, text) end
    addon.PrintCredits()
    addon.Print = original
    contains(table.concat(printed, "\n"), "Data from ForeverDB.net (https://foreverdb.net)")
    contains(table.concat(printed, "\n"), "GPL-3.0")
end

-- 3. Without it: the base data, by id, and no credit claimed -------------------------------------
do
    local _, addon = boot(false)
    local guide = addon.DungeonGuide
    local boss = witherfang(guide)
    local named = false
    for _, row in ipairs(guide.SourceLoot(2999, boss)) do if row.itemId == 271201 and row.item and row.item.n then named = true end end
    equal(named, false, "without ForeverDB the girdle is not named")
    equal(#guide.UnresolvedLoot(boss), 3, "the girdle, bracers and staff by item id")
    equal(guide.ForeverDbCredit(), nil)
    printed = {}
    local original = addon.Print
    addon.Print = function(text) table.insert(printed, text) end
    addon.PrintCredits()
    addon.Print = original
    equal(string.find(table.concat(printed, "\n"), "ForeverDB", 1, true), nil, "no ForeverDB credit without its data")
end

print("foreverdb licence spec passed")
