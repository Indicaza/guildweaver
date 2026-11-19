local _, GW = ...

-- The Dungeon Guide's knowledge: Holdfast's Dungeon Atlas, packaged as
-- Data/DungeonAtlas.generated.lua (GW.DungeonAtlasData), read for the guide
-- window and the HUD. Read-only and offline: nothing here downloads, scans
-- tooltips, parses the combat log or writes telemetry.
--
-- Costs:
--   * At login only the generated index exists (names, level bands, encounter
--     and NPC id lookups). A dungeon's detail, the spell table and the item
--     table are built the first time the guide asks, then cached for the
--     session; nothing is copied again after that.
--   * Lookups are table reads. Building a dungeon is done out of combat by
--     the window; the HUD in combat only reads what is already built.
--   * Wishlist state comes from GW.LootSync (the website's wishlist the bridge
--     delivers); this module never stores a second copy.
--
-- Everything from the atlas is Classic reference data unless an entry says
-- otherwise: it is labelled "Classic reference, unverified on Forever".
GW.DungeonGuide = GW.DungeonGuide or {}

local Guide = GW.DungeonGuide
local Globals = _G or {}

Guide.REFERENCE_NOTE = "Classic reference \194\183 unverified on Forever"

-- Short labels for ability categories. KICK only for a cast the client marks
-- interruptible; an interrupt-category spell without that mark says CAST.
Guide.LABELS = {
    ["interrupt"] = "KICK", ["tank-danger"] = "TANK", ["healer-danger"] = "HEAL", ["dispel"] = "DISPEL",
    ["positioning"] = "MOVE", ["crowd-control"] = "CC", ["special-mechanic"] = "NOTE",
}
Guide.LABEL_COLORS = { KICK = "info", TANK = "bad", HEAL = "good", DISPEL = "alertWishlist", MOVE = "warn", CC = "alertBoe", NOTE = "textMuted", CAST = "textMuted" }

local PRIORITY_SCORE = { high = 30, medium = 20, low = 10 }

local cache = { dungeons = {}, layouts = {}, spells = nil, items = nil, abilities = {}, ordered = {}, pins = {}, display = {}, sourced = {} }
Guide.cache = cache

local function data()
    return GW.DungeonAtlasData
end

function Guide.Available()
    local atlas = data()
    return type(atlas) == "table" and type(atlas.index) == "table"
end

function Guide.Source()
    local atlas = data()
    return atlas and atlas.source or nil
end

function Guide.Index()
    local atlas = data()
    return atlas and atlas.index or {}
end

-- Dungeons in the index, sorted by level band then name.
function Guide.List()
    if cache.list then return cache.list end
    local list = {}
    for id, entry in pairs(Guide.Index()) do
        table.insert(list, { id = id, name = entry.name, kind = entry.kind, lmin = entry.lmin, lmax = entry.lmax, zone = entry.zone })
    end
    table.sort(list, function(a, b)
        if (a.kind == "raid") ~= (b.kind == "raid") then return b.kind == "raid" end
        local la, lb = a.lmin or 99, b.lmin or 99
        if la ~= lb then return la < lb end
        return a.name < b.name
    end)
    cache.list = list
    return list
end

local function measure(name, fn, ...)
    local perf = GW.Perf
    if perf and perf.Begin and perf.End then
        local started = perf.Begin()
        local a, b = fn(...)
        perf.End(name, started)
        return a, b
    end
    return fn(...)
end

-- One dungeon's detail, built on first use and cached. nil when unknown.
function Guide.Dungeon(instanceId)
    instanceId = tonumber(instanceId)
    if not instanceId then return nil end
    local cached = cache.dungeons[instanceId]
    if cached ~= nil then return cached or nil end
    local atlas = data()
    local build = atlas and atlas.dungeons and atlas.dungeons[instanceId]
    if type(build) ~= "function" then
        cache.dungeons[instanceId] = false
        return nil
    end
    local ok, dungeon = pcall(measure, "guide:build", build)
    cache.dungeons[instanceId] = ok and type(dungeon) == "table" and dungeon or false
    return cache.dungeons[instanceId] or nil
end

function Guide.IsBuilt(instanceId)
    return cache.dungeons[tonumber(instanceId) or 0] ~= nil
end

function Guide.Spells()
    if cache.spells == nil then
        local atlas = data()
        local ok, spells = pcall(atlas and atlas.spells or function() return {} end)
        cache.spells = ok and type(spells) == "table" and spells or {}
    end
    return cache.spells
end

function Guide.Items()
    if cache.items == nil then
        local atlas = data()
        local ok, items = pcall(atlas and atlas.items or function() return {} end)
        cache.items = ok and type(items) == "table" and items or {}
    end
    return cache.items
end

function Guide.Item(itemId)
    return Guide.Items()[tonumber(itemId) or 0]
end

-- Matching ---------------------------------------------------------------------------

-- "Mr. Smite" == "mr smite": case, spacing and punctuation do not count.
function Guide.NormalizeName(name)
    if type(name) ~= "string" then return nil end
    local text = string.gsub(string.lower(name), "[%s%p]", "")
    return text ~= "" and text or nil
end

-- A dungeon name as the website's wishlist and the atlas may spell it:
-- "The Deadmines" and "Deadmines" are the same dungeon.
function Guide.DungeonKey(name)
    local key = Guide.NormalizeName(name)
    if key and string.sub(key, 1, 3) == "the" and #key > 6 then key = string.sub(key, 4) end
    return key
end

-- The dungeon an encounter or creature belongs to, from the index alone.
function Guide.InstanceFor(encounterId, npcId)
    local atlas = data()
    if not atlas then return nil end
    return (encounterId and atlas.encounters and atlas.encounters[tonumber(encounterId)])
        or (npcId and atlas.npcs and atlas.npcs[tonumber(npcId)]) or nil
end

-- A boss of a dungeon: by encounter ID, then NPC ID, then name. Returns the
-- boss, its index and how it matched ("encounter", "npc", "name").
function Guide.FindBoss(instanceId, encounterId, name, npcId)
    local dungeon = Guide.Dungeon(instanceId)
    if not dungeon then return nil end
    encounterId, npcId = tonumber(encounterId), tonumber(npcId)
    if encounterId then
        for index, boss in ipairs(dungeon.bosses) do
            if boss.e == encounterId then return boss, index, "encounter" end
        end
    end
    if npcId then
        for index, boss in ipairs(dungeon.bosses) do
            if boss.npc == npcId then return boss, index, "npc" end
        end
    end
    local wanted = Guide.NormalizeName(name)
    if wanted then
        for index, boss in ipairs(dungeon.bosses) do
            -- A name never overrides a different known encounter ID.
            if Guide.NormalizeName(boss.name) == wanted and not (encounterId and boss.e and boss.e ~= encounterId) then
                return boss, index, "name"
            end
        end
    end
    return nil
end

-- The instance the player is in, when the atlas knows it.
function Guide.CurrentInstanceId()
    local G = Globals
    if type(G.IsInInstance) == "function" then
        local ok, inside = pcall(G.IsInInstance)
        if ok and not inside then return nil end
    end
    if type(G.GetInstanceInfo) ~= "function" then return nil end
    local ok, _, kind, _, _, _, _, _, instanceId = pcall(G.GetInstanceInfo)
    instanceId = ok and tonumber(instanceId) or nil
    if not instanceId or kind == "none" then return nil end
    return Guide.Index()[instanceId] and instanceId or nil
end

-- Abilities ----------------------------------------------------------------------------

-- The label for a spell: KICK, TANK, HEAL, DISPEL, MOVE, CC, NOTE (or CAST).
function Guide.Label(spell)
    if type(spell) ~= "table" then return "NOTE" end
    local label = Guide.LABELS[spell.c] or "NOTE"
    if label == "KICK" and spell.k ~= true then return "CAST" end
    return label
end

-- A creature's abilities as rows { id, spell, label }, in the atlas's
-- priority order. Cached per creature table.
function Guide.Abilities(creature)
    if type(creature) ~= "table" then return {} end
    local rows = cache.abilities[creature]
    if rows then return rows end
    rows = {}
    local spells = Guide.Spells()
    for _, spellId in ipairs(creature.ab or {}) do
        local spell = spells[spellId]
        if spell then table.insert(rows, { id = spellId, spell = spell, label = Guide.Label(spell) }) end
    end
    cache.abilities[creature] = rows
    return rows
end

-- The order mechanics are shown in, the same for every player (there is no
-- role switch): 1. dangerous interrupts, 2. lethal or major mechanics (high
-- priority, tank and healer dangers, positioning), 3. dispels and crowd
-- control, 4. everything else. Within a group the atlas's priority, then its
-- own order. The source data is never changed.
local GROUP_BY_LABEL = { KICK = 1, TANK = 2, HEAL = 2, MOVE = 2, DISPEL = 3, CC = 3 }

function Guide.MechanicGroup(row)
    local group = GROUP_BY_LABEL[row.label] or 4
    if group == 4 and row.spell.p == "high" then group = 2 end
    return group
end

-- Every ability of a creature in that order. Cached per creature.
function Guide.OrderedAbilities(creature)
    if type(creature) ~= "table" then return {} end
    local cached = cache.ordered[creature]
    if cached then return cached end
    local ranked = {}
    for index, row in ipairs(Guide.Abilities(creature)) do
        table.insert(ranked, { row = row, group = Guide.MechanicGroup(row), score = PRIORITY_SCORE[row.spell.p] or 10, index = index })
    end
    table.sort(ranked, function(a, b)
        if a.group ~= b.group then return a.group < b.group end
        if a.score ~= b.score then return a.score > b.score end
        return a.index < b.index
    end)
    local rows = {}
    for _, entry in ipairs(ranked) do table.insert(rows, entry.row) end
    cache.ordered[creature] = rows
    return rows
end

-- The 2-4 mechanics to show first: the head of that order, without
-- low-priority notes past the second. Returns them and how many abilities
-- the creature has in all. (The second argument, once a role, is ignored.)
function Guide.TopMechanics(creature, _, limit)
    limit = limit or 4
    local rows = Guide.OrderedAbilities(creature)
    local top = {}
    for index = 1, math.min(limit, #rows) do
        local row = rows[index]
        if index <= 2 or row.spell.p ~= "low" then table.insert(top, row) end
    end
    return top, #rows
end

-- Kept for callers: there is no manual role any more.
function Guide.Role()
    return nil
end

-- One line for an ability: "KICK Fireball - 3s cast · interruptible".
function Guide.AbilityLine(row)
    local spell = row.spell
    return row.label .. "  " .. tostring(spell.n) .. (spell.s and ("  \226\128\148  " .. spell.s) or "")
end

function Guide.IsVerified(spell)
    return type(spell) == "table" and spell.v == true
end

-- Loot and wishlist -----------------------------------------------------------------------

local function sync()
    return GW.LootSync
end

-- The wishlist entry for an item on the logged-in character, or nil. Only a
-- read of what LootSync already holds.
function Guide.Wanted(itemId)
    local loot = sync()
    if not loot or type(loot.WishlistEntry) ~= "function" then return nil end
    local ok, entry = pcall(loot.WishlistEntry, itemId, "i:" .. tostring(itemId))
    return ok and entry or nil
end

function Guide.Acquired(itemKey)
    local loot = sync()
    if not loot or type(loot.IsAcquired) ~= "function" then return false end
    local ok, value = pcall(loot.IsAcquired, itemKey)
    return ok and value == true
end

-- The dungeon's loot as rows { itemId, item, from, kind, wanted, acquired }:
-- boss drops (in boss order), rares, other drops. Wishlist items that name
-- this dungeon as their source but are not in the reference list are added
-- at the end with kind "wishlist".
function Guide.LootRows(instanceId)
    local dungeon = Guide.Dungeon(instanceId)
    if not dungeon then return {} end
    local rows, seen = {}, {}
    local function add(itemId, from, kind, bossIndex)
        if seen[itemId] then return end
        seen[itemId] = true
        local wanted = Guide.Wanted(itemId)
        table.insert(rows, { itemId = itemId, item = Guide.Item(itemId), from = from, kind = kind, bossIndex = bossIndex, wanted = wanted,
            acquired = wanted and Guide.Acquired(wanted.itemKey) or Guide.Acquired("i:" .. itemId) })
    end
    for index, boss in ipairs(dungeon.bosses) do
        for _, itemId in ipairs(boss.loot or {}) do add(itemId, boss.name, "boss", index) end
    end
    for _, rare in ipairs(dungeon.rares) do
        for _, itemId in ipairs(rare.loot or {}) do add(itemId, rare.name, "rare") end
    end
    for _, entry in ipairs(dungeon.other or {}) do add(entry.item, entry.from, "other") end
    -- The website's own wishlist, for items it says come from here.
    local loot = sync()
    local active = loot and type(loot.Active) == "function" and loot.Active() or nil
    local wantedName = Guide.DungeonKey(dungeon.name)
    if active and active.matched and active.character then
        for _, entry in ipairs(active.character.wishlist.items) do
            if not seen[entry.itemId] and wantedName and Guide.DungeonKey(entry.source) == wantedName then
                seen[entry.itemId] = true
                table.insert(rows, { itemId = entry.itemId, item = Guide.Item(entry.itemId) or { n = entry.name, q = entry.qualityId },
                    from = nil, kind = "wishlist", wanted = entry, acquired = Guide.Acquired(entry.itemKey) })
            end
        end
    end
    return rows
end

-- How many of the character's wishlist items drop in a dungeon.
function Guide.WantedCount(instanceId)
    local count = 0
    for _, row in ipairs(Guide.LootRows(instanceId)) do
        if row.wanted and not row.acquired then count = count + 1 end
    end
    return count
end

-- Item ids a creature drops, with wishlist state.
function Guide.CreatureLoot(creature)
    local rows = {}
    for _, itemId in ipairs(type(creature) == "table" and creature.loot or {}) do
        local wanted = Guide.Wanted(itemId)
        table.insert(rows, { itemId = itemId, item = Guide.Item(itemId), wanted = wanted,
            acquired = wanted and Guide.Acquired(wanted.itemKey) or false })
    end
    return rows
end

function Guide.HasWantedLoot(creature)
    for _, row in ipairs(Guide.CreatureLoot(creature)) do
        if row.wanted and not row.acquired then return true end
    end
    return false
end

-- The dungeon's loot by where it drops, never guessed: each boss's and
-- rare's own list, the "other" drops whose named source is exactly a listed
-- creature (dangerous trash included), and the rest (no source, or a source
-- the atlas lists no creature for) under "other". Wishlist items naming the
-- dungeon but missing from the reference lists go to "other" too.
-- Returns { [creature] = rows, other = rows }; rows as LootRows. The
-- grouping is cached per dungeon; wishlist state is read on each call.
local function lootRow(itemId, from, kind)
    local wanted = Guide.Wanted(itemId)
    return { itemId = itemId, item = Guide.Item(itemId), from = from, kind = kind, wanted = wanted,
        acquired = wanted and Guide.Acquired(wanted.itemKey) or Guide.Acquired("i:" .. itemId) }
end

local function lootGrouping(dungeon)
    local grouping = cache.sourced[dungeon]
    if grouping then return grouping end
    grouping = { creatures = {}, other = {} }
    local byName = {}
    for _, list in ipairs({ dungeon.bosses or {}, dungeon.rares or {}, dungeon.trash or {} }) do
        for _, creature in ipairs(list) do
            local key = Guide.NormalizeName(creature.name)
            if key and not byName[key] then byName[key] = creature end
            local items = {}
            for _, itemId in ipairs(creature.loot or {}) do table.insert(items, { itemId, creature.name }) end
            grouping.creatures[creature] = items
        end
    end
    for _, entry in ipairs(dungeon.other or {}) do
        local owner = entry.from and byName[Guide.NormalizeName(entry.from)]
        table.insert(owner and grouping.creatures[owner] or grouping.other, { entry.item, entry.from })
    end
    cache.sourced[dungeon] = grouping
    return grouping
end

-- One creature's loot rows (its own list and the drops attributed to it).
function Guide.SourceLoot(instanceId, creature)
    local dungeon = Guide.Dungeon(instanceId)
    if not dungeon or type(creature) ~= "table" then return {} end
    local rows = {}
    for _, pair in ipairs(lootGrouping(dungeon).creatures[creature] or {}) do
        table.insert(rows, lootRow(pair[1], pair[2], "creature"))
    end
    return rows
end

-- Loot with no verified source in the dungeon.
function Guide.OtherLoot(instanceId)
    local dungeon = Guide.Dungeon(instanceId)
    if not dungeon then return {} end
    local grouping = lootGrouping(dungeon)
    local seen, rows = {}, {}
    for _, items in pairs(grouping.creatures) do
        for _, pair in ipairs(items) do seen[pair[1]] = true end
    end
    for _, pair in ipairs(grouping.other) do
        if not seen[pair[1]] then
            seen[pair[1]] = true
            table.insert(rows, lootRow(pair[1], pair[2], "other"))
        end
    end
    for _, row in ipairs(Guide.LootRows(instanceId)) do
        if row.kind == "wishlist" and not seen[row.itemId] then
            seen[row.itemId] = true
            table.insert(rows, row)
        end
    end
    return rows
end

-- Wishlist items per dungeon (not yet acquired), by the dungeon the website
-- names as their source: { [DungeonKey] = count }. A cheap read for the
-- dungeon cards (no dungeon is built for it).
function Guide.WishlistByDungeon()
    local counts = {}
    local loot = sync()
    local active = loot and type(loot.Active) == "function" and loot.Active() or nil
    if not (active and active.matched and active.character and active.character.wishlist) then return counts end
    for _, entry in ipairs(active.character.wishlist.items or {}) do
        local key = Guide.DungeonKey(entry.source)
        if key and not Guide.Acquired(entry.itemKey) then counts[key] = (counts[key] or 0) + 1 end
    end
    return counts
end

-- A dungeon card's wishlist count: the reference loot once the dungeon is
-- built, the website's source names before that.
function Guide.DungeonWishlistCount(instanceId, byDungeon)
    if Guide.IsBuilt(instanceId) and Guide.Dungeon(instanceId) then return Guide.WantedCount(instanceId) end
    local entry = Guide.Index()[tonumber(instanceId) or 0]
    return entry and (byDungeon or Guide.WishlistByDungeon())[Guide.DungeonKey(entry.name)] or 0
end

-- Runs -------------------------------------------------------------------------------------

-- The instance a finished run was in: its key ("i36:1"), else its name.
function Guide.RunInstanceId(entry)
    if type(entry) ~= "table" then return nil end
    local id = type(entry.instanceKey) == "string" and tonumber(string.match(entry.instanceKey, "^i(%d+)")) or nil
    if id and Guide.Index()[id] then return id end
    local key = Guide.DungeonKey(entry.name)
    if not key then return nil end
    for indexId, indexEntry in pairs(Guide.Index()) do
        if Guide.DungeonKey(indexEntry.name) == key then return indexId end
    end
    return nil
end

-- Finished runs worth listing (not the empty stubs a disconnect leaves),
-- all or one dungeon's, newest first. Only reads DungeonSessions' history.
function Guide.Runs(instanceId)
    local sessions = GW.DungeonSessions
    local history = sessions and type(sessions.History) == "function" and sessions.History() or {}
    local list = {}
    for _, entry in ipairs(history) do
        local empty = (entry.status == "interrupted" or entry.status == "abandoned")
            and (tonumber(entry.timerSeconds) or 0) == 0 and (tonumber(entry.bossesDefeated) or 0) == 0
        if not empty and (not instanceId or Guide.RunInstanceId(entry) == tonumber(instanceId)) then table.insert(list, entry) end
    end
    return list
end

-- Quests -----------------------------------------------------------------------------------

-- True only when the client confirms the quest was completed.
function Guide.QuestCompleted(questId)
    questId = tonumber(questId)
    if not questId then return false end
    local log = Globals.C_QuestLog
    local check = (log and type(log.IsQuestFlaggedCompleted) == "function" and log.IsQuestFlaggedCompleted)
        or (type(Globals.IsQuestFlaggedCompleted) == "function" and Globals.IsQuestFlaggedCompleted) or nil
    if not check then return false end
    local ok, value = pcall(check, questId)
    return ok and value == true
end

-- Quests the player's faction can take (all when the faction is unknown).
function Guide.Quests(instanceId)
    local dungeon = Guide.Dungeon(instanceId)
    if not dungeon then return {} end
    local faction
    if type(Globals.UnitFactionGroup) == "function" then
        local ok, value = pcall(Globals.UnitFactionGroup, "player")
        faction = ok and (value == "Alliance" and "A" or (value == "Horde" and "H")) or nil
    end
    local list = {}
    for _, quest in ipairs(dungeon.quests) do
        if not faction or not quest.fac or quest.fac == "B" or quest.fac == faction then table.insert(list, quest) end
    end
    return list
end

-- Layout ---------------------------------------------------------------------------------

-- The spawn layout's cells as { x, y } in 0-1, decoded once per dungeon.
function Guide.LayoutPoints(instanceId)
    instanceId = tonumber(instanceId)
    local cached = cache.layouts[instanceId]
    if cached then return cached end
    local dungeon = Guide.Dungeon(instanceId)
    local points = {}
    local text = dungeon and dungeon.layout and dungeon.layout.pts or ""
    for index = 1, #text - 3, 4 do
        local x, y = tonumber(string.sub(text, index, index + 1), 16), tonumber(string.sub(text, index + 2, index + 3), 16)
        if x and y and x <= 100 and y <= 100 then table.insert(points, { x / 100, y / 100 }) end
    end
    cache.layouts[instanceId] = points
    return points
end

-- Client art ------------------------------------------------------------------------------
--
-- Data/DungeonJournalArt.generated.lua (GW.DungeonJournalArt): the client's
-- own dungeon maps as texture file IDs, Blizzard's journal positions of
-- bosses on them, and creature display IDs for portraits. IDs only; the
-- client draws the art, and a file it lacks simply stays empty.

local function art()
    if cache.art == nil then
        local raw = GW.DungeonJournalArt
        local ok, tables = false, nil
        if raw and type(raw.load) == "function" then ok, tables = pcall(raw.load) end
        cache.art = ok and type(tables) == "table" and tables or false
    end
    return cache.art or nil
end
Guide.Art = art

-- The instance's floors: { { n = name or nil, t = 12 file IDs } }, or {}.
function Guide.Floors(instanceId)
    local maps = art() and art().maps
    return maps and maps[tonumber(instanceId) or 0] or {}
end

-- Bosses the journal placed on the floors, matched to the atlas's bosses by
-- name: { creature, index, floor, x, y } (x, y 0..1 of the picture). A boss
-- the journal did not place has no pin: its spot is never guessed, and the
-- atlas's own spawn layout (another projection) is never laid over the map.
function Guide.Pins(instanceId)
    instanceId = tonumber(instanceId) or 0
    local cached = cache.pins[instanceId]
    if cached then return cached end
    local dungeon = Guide.Dungeon(instanceId)
    local placed = art() and art().pins and art().pins[instanceId]
    local floors = Guide.Floors(instanceId)
    local pins = {}
    if dungeon and placed then
        local byName = {}
        for _, pin in ipairs(placed) do
            local key = Guide.NormalizeName(pin.n)
            if key and floors[pin.f] then byName[key] = pin end
        end
        for index, boss in ipairs(dungeon.bosses) do
            local pin = byName[Guide.NormalizeName(boss.name) or ""]
            if pin then table.insert(pins, { creature = boss, index = index, floor = pin.f, x = pin.x, y = pin.y }) end
        end
    end
    cache.pins[instanceId] = pins
    return pins
end

function Guide.PinFor(instanceId, creature)
    for _, pin in ipairs(Guide.Pins(instanceId)) do
        if pin.creature == creature then return pin end
    end
    return nil
end

-- What the art table knows of a creature (by its own NPC ID only).
function Guide.CreatureArt(creature)
    local creatures = art() and art().creatures
    return creatures and type(creature) == "table" and creature.npc and creatures[creature.npc] or nil
end

-- A creature's display ID for its portrait, resolved once per creature:
-- the verified registry (Data/DungeonBosses.lua), what the HUD read from the
-- client's journal, then the art table by NPC ID. Never an NPC ID itself.
function Guide.DisplayId(instanceId, creature)
    if type(creature) ~= "table" then return nil end
    local cached = cache.display[creature]
    if cached ~= nil then return cached or nil end
    local displayId
    local registry = GW.DungeonBosses
    if creature.e and registry and type(registry.DisplayId) == "function" then
        displayId = registry.DisplayId(instanceId, creature.e, creature.name)
    end
    local hud = GW.DungeonHud
    local journal = hud and hud.journal and hud.journal[tonumber(instanceId) or 0]
    if not displayId and creature.e and type(journal) == "table" then
        for _, boss in ipairs(journal) do
            if boss.encounterId == creature.e and boss.displayId then displayId = boss.displayId end
        end
    end
    if not displayId then
        local known = Guide.CreatureArt(creature)
        displayId = known and known.d or nil
    end
    cache.display[creature] = displayId or false
    return displayId
end

-- "21", "24-25" (with an en dash) or nil: the atlas's level, else the art
-- table's.
function Guide.CreatureLevel(creature)
    if type(creature) ~= "table" then return nil end
    if creature.lmin then return Guide.LevelText(creature.lmin, creature.lmax) end
    local known = Guide.CreatureArt(creature)
    if not known or not known.l then return nil end
    local low, high = string.match(known.l, "^(%d+)%-(%d+)$")
    if low then return Guide.LevelText(tonumber(low), tonumber(high)) end
    return known.l
end

-- "Elite", "Rare elite", "Rare" or "Boss" (world boss), from the art table.
local CLASS_NAMES = { e = "Elite", re = "Rare elite", r = "Rare", wb = "Boss" }
function Guide.CreatureClass(creature)
    local known = Guide.CreatureArt(creature)
    return known and CLASS_NAMES[known.c] or nil
end

-- What this session observed of a boss in the dungeon run open here:
-- "engaged" (fighting it now), "defeated" (killed in this run) or nil.
-- Only the run's own events count (GW.DungeonSessions); nothing is assumed.
-- run: the run to read (false: none); default the current one.
function Guide.EncounterState(instanceId, creature, run)
    if type(creature) ~= "table" then return nil end
    if run == nil then run = Guide.CurrentRun() end
    if not run or tonumber(run.instanceId) ~= tonumber(instanceId) then return nil end
    local key = Guide.NormalizeName(creature.name)
    local function same(encounterId, name)
        if encounterId and creature.e then return tonumber(encounterId) == creature.e end
        return key ~= nil and Guide.NormalizeName(name) == key
    end
    if run.engaged and same(run.engaged.encounterId, run.engaged.name) then return "engaged" end
    for _, split in ipairs(run.splits or {}) do
        if split.kind == "boss_kill" then
            local encounterId = split.id and tonumber(tostring(split.id):match("^boss:(%d+)$"))
            if same(encounterId, split.name) then return "defeated" end
        end
    end
    return nil
end

-- The open dungeon run (GW.DungeonSessions), or false.
function Guide.CurrentRun()
    local sessions = GW.DungeonSessions
    if not sessions or type(sessions.Current) ~= "function" then return false end
    local ok, run = pcall(sessions.Current)
    return ok and run or false
end

-- The dungeon to show outside an instance with nothing picked: the
-- lowest-level dungeon (not raid) the player's level falls into, else the
-- highest one below it, else the first.
function Guide.SuggestedInstanceId(level)
    if level == nil and type(Globals.UnitLevel) == "function" then
        local ok, value = pcall(Globals.UnitLevel, "player")
        level = ok and tonumber(value) or nil
    end
    local list = Guide.List()
    local best, below
    for _, entry in ipairs(list) do
        if entry.kind ~= "raid" and entry.lmin and level then
            if not best and level >= entry.lmin and level <= (entry.lmax or entry.lmin) then best = entry end
            if entry.lmin <= level then below = entry end
        end
    end
    local pick = best or below or list[1]
    return pick and pick.id or nil
end

-- Formatting ------------------------------------------------------------------------------

function Guide.LevelText(lmin, lmax)
    if not lmin then return nil end
    if lmax and lmax ~= lmin then return lmin .. "\226\128\147" .. lmax end
    return tostring(lmin)
end

-- "Westfall 38.0, 77.5" from per-mille coordinates.
function Guide.Coordinates(x, y)
    if not x or not y then return nil end
    return string.format("%.1f, %.1f", x / 10, y / 10)
end

-- Selection --------------------------------------------------------------------------------

local function prefs()
    return GW.UiPrefs and GW.UiPrefs.Get and GW.UiPrefs.Get("dungeonGuide") or nil
end

-- The dungeon the guide shows: the one the player picked (kept across
-- /reload) unless "follow" is on and the player is in a known instance.
function Guide.SelectedInstanceId()
    local value = prefs()
    local current = Guide.CurrentInstanceId()
    if current and (not value or value.follow ~= false) then return current end
    local picked = value and tonumber(value.instanceId)
    if picked and Guide.Index()[picked] then return picked end
    return current or Guide.SuggestedInstanceId()
end

function Guide.Select(instanceId)
    local value = prefs()
    instanceId = tonumber(instanceId)
    if value and instanceId and Guide.Index()[instanceId] then
        value.instanceId = instanceId
        -- Picking another dungeon while inside one stops following it.
        local current = Guide.CurrentInstanceId()
        value.follow = current == nil or current == instanceId
        return true
    end
    return false
end

function Guide.FollowCurrent()
    local value = prefs()
    if value then value.follow = true end
end

function Guide.Reset()
    cache.dungeons, cache.layouts, cache.spells, cache.items, cache.list, cache.pins = {}, {}, nil, nil, nil, {}
    cache.art = nil
    cache.abilities = setmetatable({}, { __mode = "k" })
    cache.ordered = setmetatable({}, { __mode = "k" })
    cache.sourced = setmetatable({}, { __mode = "k" })
    cache.display = setmetatable({}, { __mode = "k" })
end
cache.abilities = setmetatable({}, { __mode = "k" })
cache.ordered = setmetatable({}, { __mode = "k" })
cache.sourced = setmetatable({}, { __mode = "k" })
cache.display = setmetatable({}, { __mode = "k" })
