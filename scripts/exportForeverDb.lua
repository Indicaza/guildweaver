-- Build-time exporter for ForeverDB.net's data, kept apart from the rest of
-- the add-on's data under ForeverDB's own licence (GPL-3.0 with its
-- attribution term: Licenses/ForeverDB-LICENSE.txt; docs/dungeon-guide.md,
-- "Licences"):
--
--   lua5.1 scripts/exportForeverDb.lua [--check] --atlas <atlas.json>
--       --base-loot <reference-loot.json> --foreverdb-loot <foreverdb/reference-loot.json>
--       --relationships <foreverdb/loot-relationships.json> [--wings <wing-manifest.json>]
--       [--quests <quest-catalog.json>] --commit <holdfast sha> [--out Data/ForeverDB.generated.lua]
--
-- The atlas file (Data/DungeonAtlas.generated.lua) is exported from
-- Holdfast's MIT base reference loot, with no ForeverDB data in it. This
-- writes what ForeverDB's data changes, and nothing else: item facts that
-- differ (or exist only with it), and per boss and rare the loot list,
-- listed-by codes, reference rates and drops still known by ID only. The
-- guide applies it when the file is loaded (Systems/DungeonGuide.lua);
-- without it the journal shows the base data.

local Export = dofile("scripts/exportDungeonAtlas.lua")

local Overlay = {}
Overlay.MAX_BYTES = 163840 -- 160 KB

local null = Export.decode("null")
local function present(value) if value ~= null then return value end end

local function quote(value) return string.format("%q", value) end
local function scalar(value)
    if value == nil then return "nil" end
    if value == true then return "true" end
    if value == false then return "false" end
    if type(value) == "number" then return tostring(value) end
    return quote(value)
end
local function array(values)
    local parts = {}
    for _, value in ipairs(values) do table.insert(parts, scalar(value)) end
    return "{" .. table.concat(parts, ",") .. "}"
end
local function sortedKeys(map)
    local keys = {}
    for key in pairs(map) do table.insert(keys, key) end
    table.sort(keys)
    return keys
end

-- An item's facts as the guide reads them (the atlas file's unpacked items).
local function itemFields(i)
    return { n = i.name, q = i.quality, s = i.slot, l = i.itemLevel, r = i.requiredLevel, sc = i.subclass, b = i.bind, set = i.setName, dps = i.dps,
        qi = i.questItem or nil, fv = i.forever or nil }
end
local ITEM_KEYS = { "n", "q", "s", "l", "r", "sc", "b", "set", "dps", "qi", "fv" }
local function itemText(fields)
    local parts = {}
    for _, key in ipairs(ITEM_KEYS) do
        if fields[key] ~= nil then table.insert(parts, key .. "=" .. scalar(fields[key])) end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for key, value in pairs(a) do if not same(value, b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end

-- What ForeverDB's data changes, from the two normalized atlases.
function Overlay.diff(base, full)
    local items = {}
    for id, fact in pairs(full.items) do
        local mine = base.items[id]
        if not mine or not same(itemFields(mine), itemFields(fact)) then items[id] = itemFields(fact) end
    end
    local baseById = {}
    for _, d in ipairs(base.dungeons) do baseById[d.id] = d end
    local dungeons = {}
    local creatureFields = { "loot", "lootSources", "rates", "unresolved" }
    local function creaturePatch(b, f)
        local changed = false
        for _, field in ipairs(creatureFields) do if not same(b and b[field], f[field]) then changed = true end end
        if not changed then return nil end
        -- unresolved: false when ForeverDB's facts resolved every listed drop.
        -- Not `x and false or nil` (that is always nil in Lua).
        local unres = f.unresolved
        if not unres and b and b.unresolved then unres = false end
        return { loot = f.loot, ls = f.lootSources, rt = f.rates, unres = unres }
    end
    for _, f in ipairs(full.dungeons) do
        local b = baseById[f.id]
        local patch = { bosses = {}, rares = {} }
        local any = false
        for index, boss in ipairs(f.bosses) do
            local p = creaturePatch(b and b.bosses[index], boss)
            if p then patch.bosses[index] = p; any = true end
        end
        for index, rare in ipairs(f.rares) do
            local p = creaturePatch(b and b.rares[index], rare)
            if p then patch.rares[index] = p; any = true end
        end
        if not same(b and b.unresolved, f.unresolved) then patch.unres = f.unresolved or false; any = true end
        if not same(b and b.otherLoot, f.otherLoot) then patch.other = f.otherLoot; any = true end
        if any then dungeons[f.id] = patch end
    end
    return { items = items, dungeons = dungeons }
end

local function creatureText(p)
    local parts = {}
    if p.loot then table.insert(parts, "loot=" .. array(p.loot)) end
    if p.ls then table.insert(parts, "ls=" .. quote(p.ls)) end
    if p.rt then table.insert(parts, "rt=" .. quote(p.rt)) end
    if p.unres == false then table.insert(parts, "unres=false") elseif p.unres then table.insert(parts, "unres=" .. array(p.unres)) end
    if not p.loot then table.insert(parts, "noloot=true") end
    return "{" .. table.concat(parts, ",") .. "}"
end

function Overlay.render(diff, commit, notice, credit)
    assert(type(commit) == "string" and string.match(commit, "^%x+$") and #commit >= 7, "a Holdfast commit sha is required")
    assert(type(notice) == "string" and string.find(notice, "^%-%- Data: ForeverDB%.net %(https://foreverdb%.net%)"), "ForeverDB's notice line is required")
    local lines = {}
    local function add(line) table.insert(lines, line) end
    -- ForeverDB's attribution term: its notice line first, unchanged.
    add(notice)
    add("-- GENERATED by scripts/exportForeverDb.lua from Indicaza/holdfast at commit " .. commit)
    add("-- (backend/src/Atlas/data/foreverdb/). Do not edit; regenerate.")
    add("-- Licence: GPL-3.0 with ForeverDB.net's attribution term (Licenses/ForeverDB-LICENSE.txt,")
    add("-- Licenses/ForeverDB-COPYING.txt). Not part of Guildweaver's own code or data:")
    add("-- the guide applies it over Data/DungeonAtlas.generated.lua when it is loaded.")
    add("-- " .. credit)
    add("local _, GW = ...")
    add("local F = { source = { commit = " .. quote(commit) .. ", credit = " .. quote(credit) .. " }, dungeons = {} }")
    add("function F.items()")
    add("  return {")
    for _, id in ipairs(sortedKeys(diff.items)) do add("    [" .. id .. "]=" .. itemText(diff.items[id]) .. ",") end
    add("  }")
    add("end")
    for _, id in ipairs(sortedKeys(diff.dungeons)) do
        local d = diff.dungeons[id]
        add("F.dungeons[" .. id .. "] = function()")
        add("  return {")
        add("    bosses={")
        for _, index in ipairs(sortedKeys(d.bosses)) do add("      [" .. index .. "]=" .. creatureText(d.bosses[index]) .. ",") end
        add("    },")
        add("    rares={")
        for _, index in ipairs(sortedKeys(d.rares)) do add("      [" .. index .. "]=" .. creatureText(d.rares[index]) .. ",") end
        add("    },")
        if d.unres == false then add("    unres=false,") elseif d.unres then add("    unres=" .. array(d.unres) .. ",") end
        if d.other then
            add("    other={")
            for _, o in ipairs(d.other) do add("      {item=" .. o.itemId .. (o.source and (",from=" .. quote(o.source)) or "") .. "},") end
            add("    },")
        end
        add("  }")
        add("end")
    end
    add("if GW then GW.ForeverDbData = F end")
    add("return F")
    return table.concat(lines, "\n") .. "\n"
end

local function readFile(path)
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    return text
end

function Overlay.run(options)
    local atlas = Export.decode(readFile(options.atlas))
    local wings = options.wings and Export.decode(readFile(options.wings)) or nil
    local quests = options.quests and Export.decode(readFile(options.quests)) or nil
    local fullLoot = Export.decode(readFile(options["foreverdb-loot"]))
    local relationships = Export.decode(readFile(options.relationships))
    local base, baseProblems = Export.normalize(atlas, Export.decode(readFile(options["base-loot"])), wings, quests, nil)
    local full, fullProblems = Export.normalize(atlas, fullLoot, wings, quests, relationships)
    local problems = {}
    for _, list in ipairs({ baseProblems, fullProblems }) do for _, problem in ipairs(list) do table.insert(problems, problem) end end
    local notice = present(relationships.notice) or present(fullLoot.notice)
    local text = Overlay.render(Overlay.diff(base, full), options.commit, notice, "Data from ForeverDB.net (https://foreverdb.net)")
    if #text > Overlay.MAX_BYTES then table.insert(problems, string.format("ForeverDB file is %d bytes (limit %d)", #text, Overlay.MAX_BYTES)) end
    return text, problems
end

local function main(args)
    local options, index = { out = "Data/ForeverDB.generated.lua" }, 1
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
    for _, required in ipairs({ "atlas", "base-loot", "foreverdb-loot", "relationships", "commit" }) do
        if not options[required] then
            io.stderr:write("usage: lua5.1 scripts/exportForeverDb.lua [--check] --atlas <atlas.json> --base-loot <reference-loot.json> --foreverdb-loot <foreverdb/reference-loot.json> --relationships <foreverdb/loot-relationships.json> [--wings <wing-manifest.json>] [--quests <quest-catalog.json>] --commit <sha> [--out <file.lua>]\n")
            os.exit(2)
        end
    end
    local text, problems = Overlay.run(options)
    if #problems > 0 then
        io.stderr:write("ForeverDB export problems:\n  " .. table.concat(problems, "\n  ") .. "\n")
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
    print(string.format("wrote %s: %d bytes", options.out, #text))
end

local cli = { ... }
if type(cli[1]) == "string" and string.find(cli[1], "^%-%-") then
    main(cli)
end

return Overlay
