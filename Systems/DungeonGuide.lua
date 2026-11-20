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
-- WoW Forever's own dungeons (origin "forever" in the atlas): bosses, level
-- band and entrance from the Forever client; abilities, maps and most item
-- facts are not known yet, and nothing stands in for them.
Guide.FOREVER_NOTE = "WoW Forever dungeon \194\183 from the game client"

-- Short labels for ability categories. KICK only for a cast the client marks
-- interruptible; an interrupt-category spell without that mark says CAST.
Guide.LABELS = {
    ["interrupt"] = "KICK", ["tank-danger"] = "TANK", ["healer-danger"] = "HEAL", ["dispel"] = "DISPEL",
    ["positioning"] = "MOVE", ["crowd-control"] = "CC", ["special-mechanic"] = "NOTE",
}
Guide.LABEL_COLORS = { KICK = "info", TANK = "bad", HEAL = "good", DISPEL = "alertWishlist", MOVE = "warn", CC = "alertBoe", NOTE = "textMuted", CAST = "textMuted" }

local PRIORITY_SCORE = { high = 30, medium = 20, low = 10 }

local cache = { dungeons = {}, layouts = {}, spells = nil, items = nil, abilities = {}, ordered = {}, pins = {}, display = {}, sourced = {},
    entries = {}, floors = {} }
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

-- Ids and wings ------------------------------------------------------------------------
--
-- A guide id is a dungeon's game instance ID (a number) or, for a dungeon
-- whose wings are played as separate dungeons (Scarlet Monastery, Dire Maul,
-- Stratholme, Blackrock Spire), a wing's key ("scarlet-monastery:library").
-- Wings come from Holdfast's wing manifest (keys and wings in the generated
-- atlas): a wing owns the bosses and rares listed for it; quests, trash and
-- other loot are the dungeon's, shared by its wings. Every wing of a dungeon
-- is the same game instance.

local function wingData(id)
    local atlas = data()
    return type(id) == "string" and atlas and atlas.wings and atlas.wings[id] or nil
end
Guide.Wing = wingData

-- The wing keys of a dungeon, in order, or nil.
function Guide.WingsOf(instanceId)
    local atlas = data()
    local order = atlas and atlas.wingOrder and atlas.wingOrder[tonumber(instanceId) or 0]
    return order and #order > 0 and order or nil
end

-- The game instance a guide id stands for.
function Guide.InstanceIdOf(id)
    local wing = wingData(id)
    if wing then return wing.i end
    return tonumber(id)
end

-- The website's dungeon key of a guide id ("deadmines", or the wing key).
function Guide.DungeonKeyOf(id)
    if wingData(id) then return id end
    local atlas = data()
    return atlas and atlas.keys and atlas.keys[tonumber(id) or 0] or nil
end

-- A guide id from saved or linked data (a number, a numeric string or a
-- wing key), or nil when the atlas does not know it.
function Guide.NormalizeId(value)
    if wingData(value) then return value end
    local id = tonumber(value)
    return id and Guide.Index()[id] and id or nil
end

-- The index entry of a guide id: a dungeon's own, or for a wing the
-- dungeon's with the wing's name, level band and boss and rare counts.
function Guide.Entry(id)
    local wing = wingData(id)
    if not wing then return Guide.Index()[tonumber(id) or 0] end
    local cached = cache.entries[id]
    if cached then return cached end
    local parent = Guide.Index()[wing.i] or {}
    local entry = {}
    for key, value in pairs(parent) do entry[key] = value end
    entry.name, entry.wing, entry.parentName, entry.instanceId = wing.name, wing.wing, parent.name, wing.i
    entry.lmin, entry.lmax = wing.lmin or parent.lmin, wing.lmax or parent.lmax
    entry.bosses, entry.rares = #(wing.npcs or {}), #(wing.rares or {})
    cache.entries[id] = entry
    return entry
end

-- A WoW Forever dungeon (or a wing of one)?
function Guide.IsForever(id)
    local entry = Guide.Entry(id)
    return type(entry) == "table" and entry.origin == "forever"
end

-- Where a page's facts come from, in one short line.
function Guide.SourceNote(id)
    return Guide.IsForever(id) and Guide.FOREVER_NOTE or Guide.REFERENCE_NOTE
end

-- Drops a guide lists for a creature (or, given a dungeon, for no creature)
-- by item ID that have no item facts yet: IDs only, never a guessed name.
function Guide.UnresolvedLoot(holder)
    return type(holder) == "table" and type(holder.unres) == "table" and holder.unres or {}
end

-- The wing a boss (by encounter or NPC ID) belongs to, or nil: unassigned,
-- or a dungeon without wings.
function Guide.WingForBoss(instanceId, encounterId, npcId)
    encounterId, npcId = tonumber(encounterId), tonumber(npcId)
    for _, key in ipairs(Guide.WingsOf(instanceId) or {}) do
        local wing = wingData(key)
        for _, e in ipairs(wing.enc or {}) do if encounterId and e == encounterId then return key end end
        for _, n in ipairs(wing.npcs or {}) do if npcId and n == npcId then return key end end
        for _, n in ipairs(wing.rares or {}) do if npcId and n == npcId then return key end end
    end
    return nil
end

-- Dungeons in the index, sorted by level band then name. A dungeon played
-- as wings is listed once per wing instead (its own page stays reachable by
-- its instance ID).
function Guide.List()
    if cache.list then return cache.list end
    local list = {}
    for id, entry in pairs(Guide.Index()) do
        local wings = Guide.WingsOf(id)
        if wings then
            for _, key in ipairs(wings) do
                local wing = Guide.Entry(key)
                table.insert(list, { id = key, name = wing.name, kind = wing.kind, lmin = wing.lmin, lmax = wing.lmax, zone = wing.zone,
                    instanceId = id, wing = wing.wing })
            end
        else
            table.insert(list, { id = id, name = entry.name, kind = entry.kind, lmin = entry.lmin, lmax = entry.lmax, zone = entry.zone, instanceId = id })
        end
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

-- A wing's detail: its dungeon's, narrowed to the wing. Its own bosses and
-- rares; the dungeon's trash, quests and other loot, shared (minus drops a
-- sibling wing's boss or rare is named for); and the bosses no wing owns.
local function buildWing(key, wing)
    local parent = Guide.Dungeon(wing.i)
    if not parent then return nil end
    local npcs, rares, siblings = {}, {}, {}
    for _, npc in ipairs(wing.npcs or {}) do npcs[npc] = true end
    for _, npc in ipairs(wing.rares or {}) do rares[npc] = true end
    for _, other in ipairs(Guide.WingsOf(wing.i) or {}) do
        local sibling = other ~= key and wingData(other)
        for _, npc in ipairs(sibling and sibling.npcs or {}) do siblings[npc] = true end
        for _, npc in ipairs(sibling and sibling.rares or {}) do siblings[npc] = true end
    end
    local dungeon = {}
    for field, value in pairs(parent) do dungeon[field] = value end
    dungeon.id, dungeon.instanceId, dungeon.wingKey, dungeon.wing = key, wing.i, key, wing.wing
    dungeon.name, dungeon.parentName = wing.name, parent.name
    dungeon.lmin, dungeon.lmax, dungeon.levelSource = wing.lmin or parent.lmin, wing.lmax or parent.lmax, wing.lsrc
    if wing.emap and wing.ex and wing.ey then dungeon.entrance = { map = wing.emap, x = wing.ex, y = wing.ey } end
    dungeon.bosses, dungeon.rares = {}, {}
    local siblingNames = {}
    for _, boss in ipairs(parent.bosses or {}) do
        if boss.npc and npcs[boss.npc] then table.insert(dungeon.bosses, boss)
        elseif boss.npc and siblings[boss.npc] then siblingNames[Guide.NormalizeName(boss.name) or ""] = true end
    end
    for _, rare in ipairs(parent.rares or {}) do
        if rare.npc and rares[rare.npc] then table.insert(dungeon.rares, rare)
        elseif rare.npc and siblings[rare.npc] then siblingNames[Guide.NormalizeName(rare.name) or ""] = true end
    end
    dungeon.other = {}
    for _, entry in ipairs(parent.other or {}) do
        if not (entry.from and siblingNames[Guide.NormalizeName(entry.from) or ""]) then table.insert(dungeon.other, entry) end
    end
    dungeon.shared = true
    local atlas = data()
    local loose = atlas and atlas.unassigned and atlas.unassigned[wing.i] or {}
    local unassigned = {}
    for _, npc in ipairs(loose.npcs or {}) do
        for _, list in ipairs({ parent.bosses or {}, parent.rares or {} }) do
            for _, creature in ipairs(list) do if creature.npc == npc then table.insert(unassigned, creature.name) end end
        end
    end
    for _, name in ipairs(loose.names or {}) do table.insert(unassigned, name) end
    dungeon.unassigned = unassigned
    return dungeon
end

-- One dungeon's (or wing's) detail, built on first use and cached. nil when
-- unknown.
function Guide.Dungeon(instanceId)
    local wing = wingData(instanceId)
    if wing then
        local cached = cache.dungeons[instanceId]
        if cached ~= nil then return cached or nil end
        local ok, dungeon = pcall(buildWing, instanceId, wing)
        cache.dungeons[instanceId] = ok and type(dungeon) == "table" and dungeon or false
        return cache.dungeons[instanceId] or nil
    end
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
    if ok and type(dungeon) == "table" then pcall(Guide.ApplyForeverDb, instanceId, dungeon) end
    cache.dungeons[instanceId] = ok and type(dungeon) == "table" and dungeon or false
    return cache.dungeons[instanceId] or nil
end

-- ForeverDB.net's data (Data/ForeverDB.generated.lua, GPL-3.0 with its
-- attribution term, kept apart from the rest: docs/dungeon-guide.md,
-- "Licences"): when that file is loaded, its loot lists, listed-by codes,
-- reference rates and resolved drops replace the base ones of the bosses
-- and rares it names, and its item facts the base ones. Without the file
-- the journal shows the base data.
function Guide.ForeverDb()
    local overlay = GW.ForeverDbData
    return type(overlay) == "table" and overlay or nil
end

function Guide.ApplyForeverDb(instanceId, dungeon)
    local overlay = Guide.ForeverDb()
    local build = overlay and overlay.dungeons and overlay.dungeons[instanceId]
    if type(build) ~= "function" then return false end
    local patch = build()
    local function apply(list, patches)
        for index, p in pairs(patches or {}) do
            local creature = list and list[index]
            if creature then
                creature.loot, creature.ls, creature.rt = p.loot, p.ls, p.rt
                if p.unres ~= nil then creature.unres = p.unres or nil end
            end
        end
    end
    apply(dungeon.bosses, patch.bosses)
    apply(dungeon.rares, patch.rares)
    if patch.unres ~= nil then dungeon.unres = patch.unres or nil end
    if patch.other then dungeon.other = patch.other end
    dungeon.foreverDb = true
    return true
end

-- "Data from ForeverDB.net (https://foreverdb.net)" when its data is loaded.
function Guide.ForeverDbCredit()
    local overlay = Guide.ForeverDb()
    return overlay and overlay.source and overlay.source.credit or nil
end

function Guide.IsBuilt(instanceId)
    if wingData(instanceId) then return cache.dungeons[instanceId] ~= nil end
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
        -- ForeverDB's item facts over the base ones (fd: they came from it).
        local foreverDb = Guide.ForeverDb()
        local okOverlay, overlay = false, nil
        if foreverDb and type(foreverDb.items) == "function" then okOverlay, overlay = pcall(foreverDb.items) end
        if okOverlay and type(overlay) == "table" then
            for id, item in pairs(overlay) do
                item.fd = true
                cache.items[id] = item
            end
        end
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

-- What the guide should show for the instance the player is in: the wing
-- the open run resolved (DungeonSessions, from real evidence), else the
-- dungeon itself; never a wing picked for the player.
function Guide.CurrentGuideId()
    local instanceId = Guide.CurrentInstanceId()
    if not instanceId or not Guide.WingsOf(instanceId) then return instanceId end
    local run = Guide.CurrentRun()
    local key = run and run.wing and run.wing.key
    if key and wingData(key) and wingData(key).i == instanceId then return key end
    return instanceId
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
    -- The website names the game instance (a wing shares its dungeon's).
    local wantedName = Guide.DungeonKey(dungeon.parentName or dungeon.name)
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

-- Which reference sources list a creature's item: its digit in the
-- creature's `ls` (1 AzerothCore, 2 DungeonPlanner, 3 both), as words.
local LISTED_BY = { ["1"] = "AzerothCore", ["2"] = "DungeonPlanner", ["3"] = "AzerothCore and DungeonPlanner", ["4"] = "ForeverDB" }
function Guide.ListedBy(creature, index)
    local codes = type(creature) == "table" and creature.ls
    return type(codes) == "string" and LISTED_BY[string.sub(codes, index, index)] or nil
end

-- A boss drop's reference rate (Holdfast's loot relationships, `rt`): {
-- percent, kills, method = "observed" (in WoW Forever, over that many looted
-- kills) | "classic" (Classic data) } or nil. Only the source's own number:
-- Guildweaver's observed rates are on the website.
local RATE_METHOD = { o = "observed", c = "classic" }
function Guide.ReferenceRate(creature, index)
    local codes = type(creature) == "table" and creature.rt
    if type(codes) ~= "string" then return nil end
    local position = 0
    for entry in string.gmatch(codes .. ",", "([^,]*),") do
        position = position + 1
        if position == index then
            local percent, kills, method = string.match(entry, "^([%d%.]+):(%d*):(%a)$")
            if not percent then return nil end
            return { percent = tonumber(percent), kills = tonumber(kills), method = RATE_METHOD[method] or "unknown" }
        end
    end
    return nil
end

-- "23.5% (ForeverDB, 17 kills)" / "20% (ForeverDB, Classic data)".
function Guide.RateText(rate)
    if type(rate) ~= "table" or not rate.percent then return nil end
    local value = math.floor(rate.percent * 10 + 0.5) / 10
    if rate.method == "classic" then return value .. "% (ForeverDB, Classic data)" end
    return value .. "% (ForeverDB" .. (rate.kills and (", " .. rate.kills .. " kills") or "") .. ")"
end
Guide.FOREVERDB_CREDIT = "Data from ForeverDB.net"

-- Item ids a creature drops, with wishlist state.
function Guide.CreatureLoot(creature)
    local rows = {}
    for index, itemId in ipairs(type(creature) == "table" and creature.loot or {}) do
        local wanted = Guide.Wanted(itemId)
        table.insert(rows, { itemId = itemId, item = Guide.Item(itemId), wanted = wanted,
            acquired = wanted and Guide.Acquired(wanted.itemKey) or false, listedBy = Guide.ListedBy(creature, index),
            rate = Guide.ReferenceRate(creature, index) })
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
local function lootRow(itemId, from, kind, listedBy, rate)
    local wanted = Guide.Wanted(itemId)
    return { itemId = itemId, item = Guide.Item(itemId), from = from, kind = kind, wanted = wanted,
        acquired = wanted and Guide.Acquired(wanted.itemKey) or Guide.Acquired("i:" .. itemId), listedBy = listedBy, rate = rate }
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
            for index, itemId in ipairs(creature.loot or {}) do
                table.insert(items, { itemId, creature.name, Guide.ListedBy(creature, index), Guide.ReferenceRate(creature, index) })
            end
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
        table.insert(rows, lootRow(pair[1], pair[2], "creature", pair[3], pair[4]))
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
    -- A wing before it is built: the website names only the instance, which
    -- would count every wing's items; built from its dungeon if that is.
    local wing = wingData(instanceId)
    if wing then
        if Guide.IsBuilt(wing.i) and Guide.Dungeon(instanceId) then return Guide.WantedCount(instanceId) end
        return 0
    end
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

-- The guide id a finished run belongs to: the wing its own evidence
-- resolved (recorded when the run was), else its dungeon.
function Guide.RunGuideId(entry)
    local id = Guide.RunInstanceId(entry)
    local key = type(entry) == "table" and entry.wingKey
    if id and key and wingData(key) and wingData(key).i == id then return key end
    return id
end

-- Finished runs worth listing (not the empty stubs a disconnect leaves),
-- all or one dungeon's, newest first. A wing lists the runs resolved to it;
-- a dungeon lists every run of its instance (ambiguous ones included).
-- Only reads DungeonSessions' history.
function Guide.Runs(instanceId)
    local sessions = GW.DungeonSessions
    local history = sessions and type(sessions.History) == "function" and sessions.History() or {}
    local list = {}
    for _, entry in ipairs(history) do
        local empty = (entry.status == "interrupted" or entry.status == "abandoned")
            and (tonumber(entry.timerSeconds) or 0) == 0 and (tonumber(entry.bossesDefeated) or 0) == 0
        local mine = not instanceId
            or (wingData(instanceId) and Guide.RunGuideId(entry) == instanceId)
            or (not wingData(instanceId) and Guide.RunInstanceId(entry) == tonumber(instanceId))
        if not empty and mine then table.insert(list, entry) end
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
    instanceId = wingData(instanceId) and instanceId or tonumber(instanceId)
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

-- A wing's floors: the floors its sources name, else the floors Blizzard's
-- journal places one of its bosses on, else none (the guide then shows no
-- map rather than a floor that may be another wing's). Returns the floors
-- and, per wing floor, the dungeon floor's index.
local function wingFloors(key, wing)
    local cached = cache.floors[key]
    if cached then return cached.list, cached.index end
    local maps = art() and art().maps
    local all = maps and maps[wing.i] or {}
    local keep = {}
    if #(wing.floors or {}) > 0 then
        local named = {}
        for _, name in ipairs(wing.floors) do named[Guide.NormalizeName(name) or ""] = true end
        for index, floor in ipairs(all) do
            if floor.n and named[Guide.NormalizeName(floor.n) or ""] then keep[index] = true end
        end
    else
        local bosses = {}
        local parent = Guide.Dungeon(wing.i)
        for _, boss in ipairs(parent and parent.bosses or {}) do
            for _, npc in ipairs(wing.npcs or {}) do
                if boss.npc == npc then bosses[Guide.NormalizeName(boss.name) or ""] = true end
            end
        end
        for _, pin in ipairs(art() and art().pins and art().pins[wing.i] or {}) do
            if bosses[Guide.NormalizeName(pin.n) or ""] and all[pin.f] then keep[pin.f] = true end
        end
    end
    local list, index = {}, {}
    for position, floor in ipairs(all) do
        if keep[position] then
            table.insert(list, floor)
            index[#list] = position
        end
    end
    cache.floors[key] = { list = list, index = index }
    return list, index
end

-- The instance's (or wing's) floors: { { n = name or nil, t = 12 file IDs } }, or {}.
function Guide.Floors(instanceId)
    local wing = wingData(instanceId)
    if wing then return (wingFloors(instanceId, wing)) end
    local maps = art() and art().maps
    return maps and maps[tonumber(instanceId) or 0] or {}
end

-- Bosses the journal placed on the floors, matched to the atlas's bosses by
-- name: { creature, index, floor, x, y } (x, y 0..1 of the picture). A boss
-- the journal did not place has no pin: its spot is never guessed, and the
-- atlas's own spawn layout (another projection) is never laid over the map.
function Guide.Pins(instanceId)
    local wing = wingData(instanceId)
    instanceId = wing and instanceId or (tonumber(instanceId) or 0)
    local cached = cache.pins[instanceId]
    if cached then return cached end
    local dungeon = Guide.Dungeon(instanceId)
    local placed = art() and art().pins and art().pins[wing and wing.i or instanceId]
    local floors = Guide.Floors(instanceId)
    -- A wing's floor numbers are its own: the dungeon floor a pin is on maps
    -- to one of them, or the pin is not shown (another wing's floor).
    local floorOf = {}
    if wing then
        local _, index = wingFloors(instanceId, wing)
        for own, position in pairs(index) do floorOf[position] = own end
    else
        for position in ipairs(floors) do floorOf[position] = position end
    end
    local pins = {}
    if dungeon and placed then
        local byName = {}
        for _, pin in ipairs(placed) do
            local key = Guide.NormalizeName(pin.n)
            if key and floorOf[pin.f] then byName[key] = pin end
        end
        for index, boss in ipairs(dungeon.bosses) do
            local pin = byName[Guide.NormalizeName(boss.name) or ""]
            if pin then table.insert(pins, { creature = boss, index = index, floor = floorOf[pin.f], x = pin.x, y = pin.y }) end
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
    instanceId = Guide.InstanceIdOf(instanceId)
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
    if not run or tonumber(run.instanceId) ~= Guide.InstanceIdOf(instanceId) then return nil end
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
-- (A guide id: a wing picked or resolved is its wing key.)
function Guide.SelectedInstanceId()
    local value = prefs()
    local current = Guide.CurrentGuideId()
    if current and (not value or value.follow ~= false) then return current end
    local picked = value and (Guide.NormalizeId(value.wingKey) or Guide.NormalizeId(value.instanceId))
    if picked then return picked end
    return current or Guide.SuggestedInstanceId()
end

-- Saves the dungeon (instanceId) and, for a wing, its key apart: older
-- saved settings keep working and a wing key never stands in for an ID.
function Guide.Select(instanceId)
    local value = prefs()
    local id = Guide.NormalizeId(instanceId)
    if value and id then
        value.instanceId = Guide.InstanceIdOf(id)
        value.wingKey = wingData(id) and id or nil
        -- Picking another dungeon while inside one stops following it.
        local current = Guide.CurrentInstanceId()
        value.follow = current == nil or current == value.instanceId
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
    cache.entries, cache.floors = {}, {}
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
