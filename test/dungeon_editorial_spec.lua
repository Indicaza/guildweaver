-- Published editorial content from Holdfast's Dungeon Content Studio in the
-- generated atlas (scripts/exportDungeonAtlas.lua --editorial), and the
-- journal's reading of it (GW.DungeonGuide.ApplyEditorial).
--
-- Fixtures: test/fixtures/atlas_studio.json holds two real atlas dungeons
-- (Deadmines 36, The Hall of Thanes 3065), trimmed. editorial_bundle.json is
-- SYNTHETIC editorial content built by Holdfast's rules, and
-- editorial_expected.lua the lines Holdfast expects for it (both written by
-- Holdfast's backend/scripts/addonEditorialParity.mjs). This proves the
-- exporter and the data path, not what the game client draws.

local Export = dofile("scripts/exportDungeonAtlas.lua")

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

local COMMIT = "7e9ab4642e2096c4db7e99921c882ad4f1a5c93e"
local atlasJson = read("test/fixtures/atlas_studio.json")
local bundleJson = read("test/fixtures/editorial_bundle.json")
local expected = read("test/fixtures/editorial_expected.lua")
local always = function() return true end

-- 1. Parity: the exporter writes Holdfast's lines byte for byte ---------------------
local plain, plainProblems = Export.run(atlasJson, nil, COMMIT)
equal(#plainProblems, 0, table.concat(plainProblems, "; "))
local text, problems = Export.run(atlasJson, nil, COMMIT, nil, nil, nil, bundleJson, always)
equal(#problems, 0, table.concat(problems, "; "))
local block = string.match(text, "function A%.editorial%(%)\n  return {\n(.-)  }\nend\n")
truthy(block, "the editorial block")
equal(block, expected, "the editorial lines match Holdfast's")
equal(select(1, Export.run(atlasJson, nil, COMMIT, nil, nil, nil, bundleJson, always)), text, "deterministic")
-- Without a bundle nothing changes: the packaged file stays as it was.
equal(string.find(plain, "editorial", 1, true), nil, "no editorial block without --editorial")
local without = string.gsub(text, "A%.editorialSource = .-\nfunction A%.editorial%(%).-\nend\nA%.editorialArt = {\n.-\n}\n", "")
equal(without, plain, "the rest of the file is unchanged")

-- 2. The data loads in Lua 5.1 and the journal lays it over the atlas ----------------
local data = assert((loadstring or load)(text, "=generated"))("Guildweaver", {})
local entries = data.editorial()
equal(entries[3065].sub, "Synthetic subtitle")
equal(entries[3065].tips[1], "Tip with \"quotes\" and a back\\slash.")
equal(entries[3065].route, "Line one.\nLine two.")
equal(data.editorialArt[3065].card, "Interface\\AddOns\\Guildweaver\\Media\\Atlas\\3065_card")
equal(data.editorialSource.revision, "parity-fixture")

local GW = { DungeonAtlasData = data }
local chunk = assert(loadfile("Systems/DungeonGuide.lua"))
local ok, err = pcall(chunk, "Guildweaver", GW)
truthy(ok, "Systems/DungeonGuide.lua loads: " .. tostring(err))
local Guide = GW.DungeonGuide
local hall = Guide.Dungeon(3065)
truthy(hall and hall.ed, "the Hall of Thanes has its editorial entry")
local faldrim
for _, boss in ipairs(hall.bosses) do if boss.npc == 261306 then faldrim = boss end end
local lines = Guide.EditorialLines(faldrim)
equal(lines[1].label, "KICK")
equal(lines[1].ability, "Shadow Bolt")
equal(lines[1].roles, "Tank, Damage")
equal(lines[1].text, "Interrupt whenever possible.")
equal(lines[1].verified, true)
equal(lines[2].label, "MOVE")
equal(lines[3].heading, "Strategy")
local infurnus
for _, boss in ipairs(hall.bosses) do if boss.name == "Infurnus" then infurnus = boss end end
equal(Guide.EditorialLines(infurnus)[1].text, "Synthetic tank note.", "a boss without ids is matched by name")
local notes = table.concat(Guide.EditorialNotes(hall), "|")
contains(notes, "Synthetic subtitle")
contains(notes, "Tip: Tip two")
local deadmines = Guide.Dungeon(36)
equal(deadmines.name, "The Deadmines", "the published name")
equal(deadmines.atlasName, "Deadmines")
equal(deadmines.lmin, 17)
equal(deadmines.entrance.map, 1436)
equal(deadmines.entrance.x, 380)
equal(deadmines.bosses[1].name, "Rhahk'Zor", "boss order and names the editor left alone stay")
equal(Guide.EditorialLines(deadmines.bosses[1])[1].text, "Synthetic dispel note.")
equal(Guide.EditorialArt(3065).card, "Interface\\AddOns\\Guildweaver\\Media\\Atlas\\3065_card")

-- 3. Checked, never cut ---------------------------------------------------------------
local function problemsFor(mutate, exists)
    local bundle = Export.decode(bundleJson)
    mutate(bundle)
    -- Re-encode through the literal: the decoder reads Lua-literal-free JSON, so
    -- rebuild the JSON by hand for the fields the cases touch.
    local normalized = Export.normalize(Export.decode(atlasJson))
    local found = {}
    Export.editorial(bundle, normalized, found, exists or always)
    return table.concat(found, "; ")
end
contains(problemsFor(function(b) b.dungeons[2].sub = string.rep("x", 81) end), "is 81 characters (limit 80)")
contains(problemsFor(function(b) b.dungeons[2].bosses[1].k = "999" end), "is not a boss of this dungeon")
contains(problemsFor(function(b) b.dungeons[2].bosses[1].mech[1].t = "dance" end), "has no known type")
contains(problemsFor(function(b) b.dungeons[1].id = 4242 end), "is not in the atlas")
contains(problemsFor(function(b) b.dungeons[2].observedRate = 1 end), "unknown field observedRate")
contains(problemsFor(function(b) b.dungeons[2].strat = string.rep("y", 7000) end), "unknown field strat")
equal(problemsFor(function(b) b.dungeons[2].desc = string.rep("z", 600); b.dungeons[2].comp = string.rep("z", 400) end), "", "at the limits")
contains(problemsFor(function(b) b.art["3065"].card = "Interface\\Icons\\Evil" end), "is not under Media")
contains(problemsFor(function() end, function() return false end), "has no .tga in Media/Atlas")
contains(problemsFor(function(b) b.schemaVersion = 2 end), "not a schemaVersion 1 editorial bundle")
local big = problemsFor(function(b)
    local boss = b.dungeons[2].bosses[1]
    for _, key in ipairs({ "desc", "strat", "tank", "heal", "dps", "pos", "kick", "disp" }) do boss[key] = string.rep("w", 400) end
end)
equal(big, "", "a full but legal entry is accepted")
local over = problemsFor(function(b)
    local boss = b.dungeons[2].bosses[1]
    for _, key in ipairs({ "desc", "strat", "tank", "heal", "dps", "pos", "kick", "disp" }) do boss[key] = string.rep("w", 400) end
    local second = b.dungeons[2].bosses[2]
    for _, key in ipairs({ "desc", "strat", "tank", "heal", "dps", "pos", "kick", "disp" }) do second[key] = string.rep("u", 400) end
end)
contains(over, "bytes (limit 6144)", "the per-dungeon Lua budget")

print("dungeon editorial spec passed")
