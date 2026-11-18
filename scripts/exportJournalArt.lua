-- Builds Data/DungeonJournalArt.generated.lua: what the Dungeon Guide needs
-- to draw the client's own art, as file and creature IDs only (nothing of
-- Blizzard's is bundled; the client draws it).
--
--   maps      [instance map ID] = floors { n = name, t = 12 texture file IDs
--             (4 x 3 tiles of 256 px, row-major, picture 1002 x 668) }
--             from OpenMap (MIT): OpenMap/Data/Forever/DungeonMaps.lua.
--   pins      [instance map ID] = { { n = boss name, f = floor, x, y } }:
--             where Blizzard's own journal puts each boss on those floors
--             (0..1 of the picture), from OpenMap: Data/Forever/DungeonBosses.lua.
--             Only bosses the journal placed; nothing is guessed.
--   creatures [npc ID] = { d = creature display ID, l = level text, c = class }
--             from DungeonPlanner (MIT): Data/Bosses/*.lua (Wowhead Classic,
--             warcraft.wiki.gg). A boss entry's display ID belongs to its own
--             npc only; its "members" get none.
--
-- Plain Lua 5.1, run from the add-on folder with the two read-only reference
-- checkouts (../references is never part of the add-on):
--   lua5.1 scripts/exportJournalArt.lua --openmap ../references/openmap \
--     --planner ../references/DungeonPlanner [--out Data/DungeonJournalArt.generated.lua] [--check]

local Export = {}

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    return text
end

-- Runs a reference data file with the `local _, ns = ...` convention and
-- returns its ns.
local function runData(path, ns)
    local chunk, err = loadfile(path)
    if not chunk then error("cannot load " .. path .. ": " .. tostring(err)) end
    ns = ns or {}
    ns.Media = ns.Media or { tex = "" }
    chunk("reference", ns)
    return ns
end

-- DungeonPlanner's boss files, in its TOC's order.
local function plannerFiles(planner)
    local toc = readFile(planner .. "/DungeonPlanner.toc")
    if not toc then error("no DungeonPlanner.toc under " .. planner) end
    local files = {}
    for line in toc:gmatch("[^\r\n]+") do
        local path = line:match("^(Data[\\/]Bosses[\\/][%w%-_]+%.lua)%s*$")
        if path then table.insert(files, (path:gsub("\\", "/"))) end
    end
    return files
end

local function levelText(lv)
    if type(lv) ~= "table" or not tonumber(lv[1]) then return nil end
    local low, high = tonumber(lv[1]), tonumber(lv[2] or lv[1])
    if low < 0 then return nil end
    return low == high and tostring(low) or (low .. "-" .. high)
end

-- maps, bosses: OpenMap's tables; collected: DungeonPlanner's boss files'
-- tables (BossData.Add arguments). Pure: no files.
function Export.Build(maps, bosses, collected)
    local out = { maps = {}, pins = {}, creatures = {}, problems = {} }
    for instanceId, floors in pairs(maps) do
        if type(instanceId) == "number" then
            local list = {}
            for index, floor in ipairs(floors) do
                if type(floor.tiles) ~= "table" or #floor.tiles ~= 12 then
                    table.insert(out.problems, "map " .. instanceId .. " floor " .. index .. " has " .. tostring(floor.tiles and #floor.tiles) .. " tiles")
                end
                for _, id in ipairs(floor.tiles or {}) do
                    if type(id) ~= "number" then table.insert(out.problems, "map " .. instanceId .. " has a non-numeric tile") end
                end
                table.insert(list, { n = floor.name, w = floor.wing, t = floor.tiles })
            end
            out.maps[instanceId] = list
        end
    end
    for instanceId, places in pairs(bosses) do
        -- Only instances whose floors are the client's own pictures.
        if type(instanceId) == "number" and out.maps[instanceId] then
            local list = {}
            for name, place in pairs(places) do
                local floor, x, y = place[1], place[2], place[3]
                if type(floor) ~= "number" or not out.maps[instanceId][floor] then
                    table.insert(out.problems, "pin " .. name .. " in " .. instanceId .. " is on a floor the map lacks")
                elseif type(x) ~= "number" or type(y) ~= "number" or x < 0 or x > 1 or y < 0 or y > 1 then
                    table.insert(out.problems, "pin " .. name .. " in " .. instanceId .. " is off the picture")
                else
                    table.insert(list, { n = name, f = floor, x = x, y = y })
                end
            end
            table.sort(list, function(a, b) return a.n < b.n end)
            if #list > 0 then out.pins[instanceId] = list end
        end
    end

    for _, dungeon in ipairs(collected) do
        for _, boss in ipairs(dungeon.bosses or {}) do
            local npc, display = tonumber(boss.npc), tonumber(boss.disp)
            if npc and display and display > 0 then
                local entry = { d = display, l = levelText(boss.lv), c = boss.cls }
                local known = out.creatures[npc]
                if known and known.d ~= display then
                    table.insert(out.problems, "npc " .. npc .. " has display IDs " .. known.d .. " and " .. display)
                end
                out.creatures[npc] = known or entry
            end
        end
    end
    return out
end

function Export.Collect(openmap, planner)
    local maps = runData(openmap .. "/OpenMap/Data/Forever/DungeonMaps.lua").MapDungeonMaps or {}
    local bosses = runData(openmap .. "/OpenMap/Data/Forever/DungeonBosses.lua").MapDungeonBosses or {}
    local collected = {}
    local ns = { BossData = { Add = function(raw) table.insert(collected, raw) end } }
    for _, path in ipairs(plannerFiles(planner)) do runData(planner .. "/" .. path, ns) end
    return Export.Build(maps, bosses, collected)
end

-- Serialization -----------------------------------------------------------------------

local function sortedKeys(map)
    local keys = {}
    for key in pairs(map) do table.insert(keys, key) end
    table.sort(keys)
    return keys
end

local function quote(text)
    return string.format("%q", text)
end

local function number(value)
    if math.floor(value) == value then return tostring(value) end
    return (string.format("%.4f", value):gsub("0+$", ""))
end

function Export.Render(art, sources)
    local lines = {
        "-- GENERATED by scripts/exportJournalArt.lua; regenerate rather than edit.",
        "-- The client's own dungeon maps (texture file IDs) and boss portraits",
        "-- (creature display IDs) for the Dungeon Guide. IDs only: the client draws",
        "-- the art. Sources (MIT): OpenMap " .. tostring(sources.openmap) .. " (maps from the game's",
        "-- UiMap tables; boss places from Blizzard's journal) and DungeonPlanner",
        "-- " .. tostring(sources.planner) .. " (display IDs and levels: Wowhead Classic, warcraft.wiki.gg).",
        "local _, GW = ...",
        "local A = {}",
        "GW.DungeonJournalArt = A",
        "A.source = { openmap = " .. quote(tostring(sources.openmap)) .. ", planner = " .. quote(tostring(sources.planner)) .. " }",
        "-- Built on first use (GW.DungeonGuide), not at login.",
        "function A.load()",
        "local maps = {",
    }
    for _, instanceId in ipairs(sortedKeys(art.maps)) do
        local floors = {}
        for _, floor in ipairs(art.maps[instanceId]) do
            local parts = { "t={" .. table.concat(floor.t, ",") .. "}" }
            if floor.n then table.insert(parts, 1, "n=" .. quote(floor.n)) end
            if floor.w then table.insert(parts, 2, "w=" .. quote(floor.w)) end
            table.insert(floors, "{" .. table.concat(parts, ",") .. "}")
        end
        table.insert(lines, "  [" .. instanceId .. "]={" .. table.concat(floors, ",") .. "},")
    end
    table.insert(lines, "}")
    table.insert(lines, "local pins = {")
    for _, instanceId in ipairs(sortedKeys(art.pins)) do
        local pins = {}
        for _, pin in ipairs(art.pins[instanceId]) do
            table.insert(pins, "{n=" .. quote(pin.n) .. ",f=" .. pin.f .. ",x=" .. number(pin.x) .. ",y=" .. number(pin.y) .. "}")
        end
        table.insert(lines, "  [" .. instanceId .. "]={" .. table.concat(pins, ",") .. "},")
    end
    table.insert(lines, "}")
    table.insert(lines, "local creatures = {")
    for _, npc in ipairs(sortedKeys(art.creatures)) do
        local entry = art.creatures[npc]
        local parts = { "d=" .. entry.d }
        if entry.l then table.insert(parts, "l=" .. quote(entry.l)) end
        if entry.c then table.insert(parts, "c=" .. quote(entry.c)) end
        table.insert(lines, "  [" .. npc .. "]={" .. table.concat(parts, ",") .. "},")
    end
    table.insert(lines, "}")
    table.insert(lines, "return { maps = maps, pins = pins, creatures = creatures }")
    table.insert(lines, "end")
    return table.concat(lines, "\n") .. "\n"
end

local function gitHead(dir)
    local pipe = io.popen and io.popen('git -C "' .. dir .. '" rev-parse --short HEAD 2>' .. (package.config:sub(1, 1) == "\\" and "NUL" or "/dev/null"))
    if not pipe then return "unknown" end
    local head = pipe:read("*l")
    pipe:close()
    return head and head ~= "" and head or "unknown"
end

function Export.Main(args)
    local options = { out = "Data/DungeonJournalArt.generated.lua" }
    local index = 1
    while index <= #args do
        local key = args[index]
        if key == "--check" then
            options.check = true
            index = index + 1
        else
            options[key:gsub("^%-%-", "")] = args[index + 1]
            index = index + 2
        end
    end
    if not options.openmap or not options.planner then
        error("usage: exportJournalArt.lua --openmap <dir> --planner <dir> [--out file] [--check]")
    end
    local art = Export.Collect(options.openmap, options.planner)
    if #art.problems > 0 then
        error("reference data problems:\n  " .. table.concat(art.problems, "\n  "))
    end
    local text = Export.Render(art, { openmap = options.openmapCommit or gitHead(options.openmap), planner = options.plannerCommit or gitHead(options.planner) })
    if options.check then
        local current = readFile(options.out)
        if current and current:gsub("\r\n", "\n") == text then
            print("up to date: " .. options.out)
            return true
        end
        error(options.out .. " does not match the references; regenerate it")
    end
    local file = assert(io.open(options.out, "wb"))
    file:write(text)
    file:close()
    print(string.format("wrote %s: %d bytes, %d maps, %d pinned instances, %d creatures", options.out, #text,
        #sortedKeys(art.maps), #sortedKeys(art.pins), #sortedKeys(art.creatures)))
    return true
end

local cli = { ... }
if cli[1] and tostring(cli[1]):match("^%-%-") then
    Export.Main(cli)
end

return Export
