-- The dungeon journal: the client-art table (exporter and packaged file),
-- the map renderer, the shared portrait engine, the dungeon cards, Back /
-- Forward and the breadcrumb, boss pages with their mechanics and loot grid,
-- tooltips, quests, runs and the current-run strip, the HUD's faces and
-- deep links, resizing, combat rules and what is never packaged
-- (references/).
--
-- Fixtures: test/fixtures/journal_refs/ is an excerpt of the two MIT
-- reference add-ons (OpenMap's Deadmines and Ragefire Chasm maps and the
-- Deadmines' journal pins; DungeonPlanner's Deadmines and Ragefire Chasm
-- boss files), copied unchanged with their licences.

local Env = dofile("test/support/wow_env.lua")
local Export = dofile("scripts/exportJournalArt.lua")

local function equal(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function truthy(value, label)
    if not value then error((label or "value") .. ": expected truthy value", 2) end
end

local function falsy(value, label)
    if value then error((label or "value") .. ": expected nil or false, got " .. tostring(value), 2) end
end

local function contains(text, needle, label)
    if type(text) ~= "string" or not string.find(text, needle, 1, true) then
        error((label or "text") .. ": " .. tostring(text) .. " does not contain " .. needle, 2)
    end
end

local function read(path)
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    return (string.gsub(text, "\r\n", "\n"))
end

-- Exporter ------------------------------------------------------------------------------

do
    local art = Export.Collect("test/fixtures/journal_refs/openmap", "test/fixtures/journal_refs/planner")
    equal(#art.problems, 0, "the excerpt exports cleanly: " .. table.concat(art.problems, "; "))
    equal(#art.maps[36], 2, "the Deadmines has two floors")
    equal(art.maps[36][1].n, "The Deadmines")
    equal(art.maps[36][1].t[1], 449591, "the first tile ForeverPlusPlus checked in game")
    equal(#art.maps[389], 1, "Ragefire Chasm has one floor")
    equal(art.pins[389], nil, "and no journal pins: nothing is placed")
    equal(#art.pins[36], 7, "seven Deadmines bosses placed by the journal")
    equal(art.creatures[639].d, 2029, "VanCleef's display ID, keyed by his NPC ID")
    equal(art.creatures[639].l, "21")
    equal(art.creatures[642].d, 1269, "Sneed's Shredder has its own display")
    equal(art.creatures[643], nil, "Sneed, a member of that entry, gets no face that is not his")
    equal(art.creatures[11520].d, 7970, "Taragaman (Ragefire Chasm)")
    local first = Export.Render(art, { openmap = "abc", planner = "def" })
    equal(first, Export.Render(art, { openmap = "abc", planner = "def" }), "deterministic")
    local chunk = assert((loadstring or load)(first, "=art"))
    local holder = {}
    chunk("Guildweaver", holder)
    local loaded = holder.DungeonJournalArt.load()
    equal(loaded.maps[36][2].n, "Ironclad Cove", "the output is valid Lua that registers GW.DungeonJournalArt")
    equal(loaded.pins[36][1].n, "Captain Greenskin", "pins sorted by name")

    -- Problems the exporter refuses.
    local bad = Export.Build({ [1] = { { tiles = { 1, 2, 3 } } } },
        { [1] = { ["Off the map"] = { 1, 1.4, 0.5 }, ["Wrong floor"] = { 3, 0.5, 0.5 } } },
        { { bosses = { { npc = 5, disp = 10 } } }, { bosses = { { npc = 5, disp = 11 } } } })
    equal(#bad.problems, 4, "short floor, off-picture pin, missing floor, two displays for one NPC: " .. table.concat(bad.problems, "; "))
end

-- The packaged art table ----------------------------------------------------------------------

local ART_PATH = "Data/DungeonJournalArt.generated.lua"
do
    local text = read(ART_PATH)
    truthy(#text < 40 * 1024, "the art table stays small (" .. #text .. " bytes)")
    local holder = {}
    assert(loadfile(ART_PATH))("Guildweaver", holder)
    equal(type(holder.DungeonJournalArt.load), "function", "the tables are built on first use, not at login")
    local art = holder.DungeonJournalArt.load()
    local maps, floors = 0, 0
    for instanceId, list in pairs(art.maps) do
        maps = maps + 1
        for _, floor in ipairs(list) do
            floors = floors + 1
            equal(#floor.t, 12, instanceId .. ": 12 tiles per floor")
            for _, id in ipairs(floor.t) do truthy(type(id) == "number" and id > 0, "tile file IDs are numbers") end
        end
    end
    equal(maps, 25, "25 instances have the client's map")
    truthy(art.maps[36] and art.maps[389], "the Deadmines and Ragefire Chasm among them")
    for instanceId, pins in pairs(art.pins) do
        for _, pin in ipairs(pins) do
            truthy(art.maps[instanceId][pin.f], "pin on an existing floor")
            truthy(pin.x >= 0 and pin.x <= 1 and pin.y >= 0 and pin.y <= 1, "pin on the picture")
        end
    end
    local creatures = 0
    for npc, entry in pairs(art.creatures) do
        creatures = creatures + 1
        truthy(type(npc) == "number" and type(entry.d) == "number" and entry.d > 0, "display IDs are numbers")
    end
    truthy(creatures >= 250, "boss display IDs: " .. creatures)
    print(string.format("journal art: %d bytes, %d maps (%d floors), %d creatures", #text, maps, floors, creatures))
end

-- The add-on in the fake client ---------------------------------------------------------------

local world
local DEADMINES = { name = "The Deadmines", type = "party", difficultyId = 1, difficultyName = "Normal", maxPlayers = 5, id = 36 }

local function boot(options)
    options = options or {}
    world = { instance = nil }
    local env = Env.new()
    local addon = env:load()
    local G = _G
    G.IsInInstance = function() return world.instance ~= nil, world.instance and world.instance.type or "none" end
    G.GetInstanceInfo = function()
        local instance = world.instance
        if not instance then return "Elwynn Forest", "none", 0, "", 0, 0, false, 0 end
        return instance.name, instance.type, instance.difficultyId, instance.difficultyName, instance.maxPlayers, 0, false, instance.id
    end
    G.UnitXP, G.UnitXPMax, G.GetMaxPlayerLevel = function() return 1000 end, function() return 5000 end, function() return 60 end
    G.GetNumGroupMembers = function() return 5 end
    G.GetInstanceLockTimeRemaining = function() return 3600, false, 7, 0 end
    G.EJ_GetInstanceForMap, G.EJ_SelectInstance, G.EJ_GetEncounterInfoByIndex, G.EJ_GetCreatureInfo = nil, nil, nil, nil
    G.C_Map = nil
    G.UnitFactionGroup = function() return "Alliance" end
    G.UnitGroupRolesAssigned = nil
    -- The client's art calls.
    env.portraitDraws = {}
    G.SetPortraitTextureFromCreatureDisplayID = function(texture, displayId)
        table.insert(env.portraitDraws, displayId)
        texture.gwDrawnDisplay = displayId
    end
    G.GetItemIcon = function(itemId) env.itemIcons = (env.itemIcons or 0) + 1; return 133000 + itemId end
    G.GetSpellTexture = function(spellId) return 136000 + (spellId % 100) end
    G.GetCursorPosition = function() return 600, 400 end
    G.UIParent.GetEffectiveScale = function() return 1 end
    env.protectedCalls = 0
    for _, name in ipairs({ "RollOnLoot", "ConfirmLootRoll", "CastSpellByName", "UseAction", "TargetUnit", "RunMacroText" }) do
        G[name] = function() env.protectedCalls = env.protectedCalls + 1 end
    end
    local holder = {}
    assert(loadfile("test/fixtures/BridgeLoot.generated.lua"))("Guildweaver", holder)
    addon.BridgeLoot = options.inbox ~= false and holder.BridgeLoot or nil
    addon.Portraits.Reset()
    env:login()
    env:advance(3)
    return env, addon
end

local function zone(env, instance)
    world.instance = instance
    env:dispatch("PLAYER_ENTERING_WORLD", false, false)
    env:advance(2)
end

-- Model: floors, verified pins, display IDs, levels, observed state, default dungeon.
do
    local env, addon = boot()
    local guide = addon.DungeonGuide
    equal(#guide.Floors(389), 1, "Ragefire Chasm: one floor")
    equal(#guide.Pins(389), 0, "no verified boss positions: no pins")
    equal(#guide.Floors(36), 2)
    local pins = guide.Pins(36)
    equal(#pins, 7, "every Deadmines boss has a journal pin")
    for _, pin in ipairs(pins) do truthy(pin.creature and pin.index and pin.floor, "pins carry their boss") end
    equal(#guide.Floors(533), 0, "Naxxramas: no client map")
    local vancleef = guide.FindBoss(36, 2747)
    equal(guide.DisplayId(36, vancleef), 2029, "VanCleef's face")
    equal(guide.CreatureLevel(vancleef), "21", "his level from the art table")
    equal(guide.CreatureClass(vancleef), "Rare elite")
    local sneed = guide.FindBoss(36, 2742)
    equal(guide.DisplayId(36, sneed), nil, "Sneed has no known face of his own")
    -- No display ID is ever an NPC ID.
    for _, entry in ipairs(guide.List()) do
        local dungeon = guide.Dungeon(entry.id)
        for _, boss in ipairs(dungeon.bosses) do
            local displayId = guide.DisplayId(entry.id, boss)
            if displayId and boss.npc then truthy(displayId ~= boss.npc or displayId == guide.Art().creatures[boss.npc].d, "display, not NPC, IDs") end
        end
    end
    -- Ragefire Chasm: every boss has a face.
    for _, boss in ipairs(guide.Dungeon(389).bosses) do truthy(guide.DisplayId(389, boss), boss.name .. " has a face") end
    -- Observed state comes only from the run open in that dungeon.
    local run = { instanceId = 36, engaged = { encounterId = 2746, name = "Cookie" },
        splits = { { kind = "boss_kill", id = "boss:2741", name = "Rhahk'Zor" }, { kind = "split", id = "split:1", name = "Gate" } } }
    equal(guide.EncounterState(36, guide.FindBoss(36, 2746), run), "engaged")
    equal(guide.EncounterState(36, guide.FindBoss(36, 2741), run), "defeated")
    equal(guide.EncounterState(36, vancleef, run), nil, "not seen: no state")
    equal(guide.EncounterState(43, guide.FindBoss(43, nil, "Kresh"), run), nil, "another dungeon's run says nothing here")
    equal(guide.EncounterState(36, vancleef, false), nil)
    -- Outside, nothing picked: a dungeon for the player's level, not the first in the list.
    local suggested = guide.SuggestedInstanceId(30)
    local entry = guide.Index()[suggested]
    truthy(entry.lmin <= 30 and (entry.lmax or entry.lmin) >= 30, "a level-30 dungeon (" .. entry.name .. ")")
    truthy(guide.SuggestedInstanceId(15) ~= nil)
    equal(guide.SelectedInstanceId(), guide.SuggestedInstanceId(), "the default outside is the suggested dungeon")
    local _ = env
end

-- Portraits: loaded once, the shared timer, combat, missing IDs.
do
    local env, addon = boot()
    local Portraits = addon.Portraits
    local texture = {}
    equal(Portraits.Draw(texture, nil), false, "no display ID: nothing drawn")
    equal(Portraits.Draw(texture, 0), false)
    local readyCalls = 0
    equal(Portraits.Draw(texture, 2029, function() readyCalls = readyCalls + 1 end), "loading", "a creature not loaded yet")
    falsy(texture.gwReady)
    local count, pending = Portraits.Pending()
    equal(count, 1)
    truthy(pending, "one shared timer")
    local other = {}
    equal(Portraits.Draw(other, 1305), "loading")
    local _, stillOne = Portraits.Pending()
    truthy(stillOne)
    env:advance(Portraits.LOAD_SECONDS + 0.2)
    truthy(texture.gwReady and other.gwReady, "both ready after the load")
    equal(readyCalls, 1)
    equal(texture.gwDrawnDisplay, 2029, "drawn again with the loaded creature")
    local again = {}
    equal(Portraits.Draw(again, 2029), "ready", "a loaded creature is ready at once")
    -- Combat: a creature not loaded is not drawn until combat ends.
    env.inCombat = true
    local fight = {}
    local draws = #env.portraitDraws
    equal(Portraits.Draw(fight, 7124), "deferred")
    equal(#env.portraitDraws, draws, "no model work in combat")
    equal(Portraits.Draw({}, 2029), "ready", "a loaded face still shows in combat")
    env.inCombat = false
    env:dispatch("PLAYER_REGEN_ENABLED")
    equal(fight.gwDisplay, 7124, "drawn after combat")
    -- Without the client function nothing breaks.
    _G.SetPortraitTextureFromCreatureDisplayID = nil
    equal(Portraits.Draw({}, 2029), false)
    -- The widget: states and the fallback.
    _G.SetPortraitTextureFromCreatureDisplayID = function(target, displayId) target.gwDrawnDisplay = displayId end
    local widget = addon.UI.Portrait(nil, 40)
    equal(widget:SetCreature(nil), false, "unknown: the skull")
    truthy(widget.fallback.shown ~= false and not widget.gwFaceReady)
    equal(widget:SetCreature(2029), "ready")
    truthy(widget.gwFaceReady, "a loaded creature's face shows at once")
    widget:SetState("defeated")
    equal(widget.gwState, "defeated")
    truthy(widget.check.shown ~= false, "defeated shows a check")
    widget:SetState("nonsense")
    equal(widget.gwState, "available", "unknown states fall back")
end

-- Map renderer: geometry, floors, pins, missing art, no map.
do
    local env, addon = boot()
    local DungeonMap = addon.DungeonMap
    local tiles = DungeonMap.TileLayout(350)
    equal(#tiles, 12)
    local width = 0
    for index = 1, 4 do width = width + tiles[index].w end
    truthy(math.abs(width - 350) < 0.01, "a row of tiles spans the map's width")
    local height = tiles[1].h + tiles[5].h + tiles[9].h
    truthy(math.abs(height - 350 / DungeonMap.ASPECT) < 0.01, "three rows span its height (1002 x 668)")
    equal(tiles[4].u, 234 / 256, "the last column shows 234 of 256 px")
    equal(tiles[12].v, 156 / 256, "the last row 156")

    local clicked
    local map = DungeonMap.New(nil, 350, { onPin = function(pin) clicked = pin end, onFloor = function(floor) clicked = floor end })
    equal(map:ShowDungeon(389, 1), "drawn", "Ragefire Chasm's map")
    equal(map.tiles[1].gwFile, 449736, "its first tile, by file ID")
    equal(map.gwPinCount, 0, "no unverified markers")
    falsy(map.bar.shown, "one unnamed floor: no floor bar")
    equal(map:ShowDungeon(36, 2), "drawn")
    equal(map.gwPinCount, 5, "five bosses in Ironclad Cove")
    truthy(map.bar.shown)
    contains(map.bar.label.gwText, "2/2  Ironclad Cove")
    map.pins[1]:GetScript("OnClick")()
    truthy(clicked and clicked.creature, "a pin click hands its boss over")
    map.bar.prev:GetScript("OnClick")()
    equal(clicked, 1, "the floor arrow asks for floor 1")
    -- Missing art: the client answers false for every tile.
    for _, texture in ipairs(map.tiles) do texture.SetTexture = function() return false end end
    map.gwDrawn = nil
    map:ShowDungeon(36, 1)
    equal(map.gwMissing, 12)
    truthy(map.empty.shown, "a client without the pictures says so")
    contains(map.empty.gwText, "none of the map's pictures")
    -- No map at all.
    equal(map:ShowDungeon(533, 1), "nomap")
    contains(map.empty.gwText, "no map of this instance")
    falsy(map.bar.shown)
    local _ = env
end

-- The journal: the dungeon cards, Back/Forward and the breadcrumb, a boss's
-- page with its mechanics and loot grid, tooltips, quests and runs.
do
    local env, addon = boot()
    local main, guideUI, guide = addon.MainFrame, addon.DungeonGuideUI, addon.DungeonGuide
    -- This client answers spell icons through C_Spell; the old global is gone.
    _G.GetSpellTexture = nil
    _G.C_Spell.GetSpellTexture = function(spellId) if spellId == 5174 then return nil end return 136000 + (spellId % 100) end
    env:resetCalls()
    -- One Dungeons entry in the sidebar, no Dungeon Guide.
    local entries = {}
    for _, entry in ipairs(main.NAV) do entries[entry.key] = entry.label end
    equal(entries.dungeon, "Dungeons")
    equal(entries.guide, nil, "no separate Dungeon Guide entry")
    -- Dungeons: the cards, no dungeon opened by itself.
    main:Open()
    main:Select("dungeon", "nav")
    local view = main.views.dungeon
    truthy(view.browser.shown, "the dungeon cards are the landing page")
    falsy(view.dungeon.shown, "no dungeon is opened on landing")
    equal(guideUI.CurrentPage().level, "browser")
    equal(view.gwShownCards, #guide.List(), "every dungeon has a card")
    local cards = view.browser.cards.items
    local function cardFor(id)
        for _, card in ipairs(cards) do if card.shown ~= false and card.gwData and card.gwData.id == id then return card end end
    end
    local deadmines = cardFor(36)
    truthy(deadmines, "a Deadmines card")
    equal(deadmines.name.gwText, "Deadmines")
    contains(deadmines.meta.gwText, "Levels 15")
    contains(deadmines.meta.gwText, "Westfall")
    contains(deadmines.kind.gwText, "DUNGEON")
    contains(deadmines.kind.gwText, "7 BOSSES")
    equal(deadmines.gwArt, guideUI.CardArt(36), "its art is a strip of the client's own map")
    truthy(guideUI.CardArt(36), "a file ID, not a bundled picture")
    contains(cardFor(409).kind.gwText, "RAID")
    falsy(rawget(cardFor(533), "gwArt"), "Naxxramas: no map, no art")
    -- Level 30 (the fake player): a dungeon for that level comes first.
    truthy(cards[1].gwData.gwSuggested, "suggested dungeons first")
    contains(cards[1].flags.gwText, "Your level")
    -- Filters: search, level band, raids.
    view.browser.search.GetText = function() return "deadm" end
    view.browser.search:GetScript("OnTextChanged")(view.browser.search)
    equal(view.gwShownCards, 1, "search by name")
    equal(cards[1].gwData.id, 36)
    view.browser.search.GetText = function() return "" end
    view.browser.search:GetScript("OnTextChanged")(view.browser.search)
    view.browser.kind.buttons[3]:Click()
    for index = 1, view.gwShownCards do equal(cards[index].gwData.kind, "raid", "raids only") end
    view.browser.kind.buttons[1]:Click()
    view.browser.band.buttons[4]:Click()
    for index = 1, view.gwShownCards do truthy(cards[index].gwData.lmin >= 50, "level 50+ only") end
    view.browser.band.buttons[1]:Click()
    equal(view.gwShownCards, #guide.List(), "everything again")
    -- The grid scrolls; nothing is laid out while it does.
    local grid = view.browser.grid
    truthy(grid.gwContent > grid.gwViewHeight, "more cards than fit: the grid scrolls")
    grid:GetScript("OnMouseWheel")(grid, -1)
    equal(grid:Offset(), 48, "a wheel notch moves it")

    -- Click Deadmines: the overview with the map and its pins.
    cardFor(36):GetScript("OnClick")(cardFor(36))
    local page = view.dungeon
    truthy(page.shown and not view.browser.shown)
    equal(page.title.gwText, "Deadmines")
    contains(page.sub.gwText, "Levels 15")
    truthy(page.map.shown, "the map is the overview's centre")
    equal(page.map.gwDrawn, "36:1")
    equal(page.map.gwPinCount, 2, "Rhahk'Zor and Sneed on the first floor")
    local crumbs = view.topBar.crumbs
    equal(crumbs[1].label.gwText, "Dungeons")
    equal(crumbs[2].label.gwText, "Deadmines")
    falsy(crumbs[3].shown)
    -- The list: bosses, the rare, dangerous trash, other loot.
    local bosses = page.bossRows.items
    equal(bosses[7].name.gwText, "Edwin VanCleef")
    contains(bosses[7].sub.gwText, "Level 21")
    equal(bosses[7].portrait.gwDisplay, 2029, "his portrait")
    truthy(bosses[7].wish.shown, "a wishlist item drops from him")
    truthy(bosses[7].gwMarks >= 1, "mechanic spell icons")
    equal(bosses[2].portrait.gwState, "unknown", "Sneed has no portrait: the unknown state")
    local small = page.smallRows.items
    equal(small[1].name.gwText, "Miner Johnson")
    equal(small[1].portrait.gwIcon, guideUI.ICONS.rare)
    local otherRow
    for _, row in ipairs(small) do if row.shown ~= false and row.gwData and row.gwData.kind == "other" then otherRow = row end end
    truthy(otherRow, "loot with no verified source has its own entry")

    -- Turn the floor, open Captain Greenskin from his pin.
    page.map.bar.next:GetScript("OnClick")()
    equal(page.map.gwDrawn, "36:2", "Ironclad Cove")
    equal(guideUI.state.floors[36], 2, "the floor is remembered")
    local greenskinPin
    for _, pin in ipairs(page.map.pins) do if pin.shown ~= false and pin.gwPin and pin.gwPin.creature.name == "Captain Greenskin" then greenskinPin = pin end end
    truthy(greenskinPin, "Greenskin's pin")
    greenskinPin:GetScript("OnClick")(greenskinPin)
    equal(guideUI.CurrentPage().level, "creature")
    equal(page.name.gwText, "Captain Greenskin")
    falsy(page.map.shown, "his page replaces the map")
    equal(crumbs[3].label.gwText, "Captain Greenskin", "Dungeons > Deadmines > Captain Greenskin")
    truthy(crumbs[2].gwPage, "Deadmines is a way up")
    truthy(page.keyHeader.shown, "key mechanics")
    truthy(page.abilityRows.items[1].shown and page.abilityRows.items[1].icon.gwFile, "with spell icons")
    equal(page.gwLootCount, 3, "his three drops")
    local cell = page.cells.items[1]
    truthy(cell.shown ~= false and cell.icon.gwFile, "an item cell with the client's icon")
    equal(page.gwGridColumns > 3, true, "several items per row")
    equal(cell:GetScript("OnClick"), nil, "no click action on items: hover only")
    -- The same page from the list.
    guideUI.Back()
    equal(guideUI.CurrentPage().level, "dungeon", "Back: the Deadmines")
    equal(page.map.gwDrawn, "36:2", "on the floor it was left on")
    bosses[4]:GetScript("OnClick")(bosses[4])
    equal(page.name.gwText, "Captain Greenskin", "the list opens the same page")
    -- Back twice: the cards; Forward: the Deadmines again.
    guideUI.Back()
    guideUI.Back()
    truthy(view.browser.shown, "Back again: the dungeon cards")
    equal(grid:Offset(), 48, "where the grid was scrolled")
    guideUI.Forward()
    equal(guideUI.CurrentPage().level, "dungeon", "Forward: the Deadmines")
    guideUI.Forward()
    equal(page.name.gwText, "Captain Greenskin", "Forward again: Greenskin")
    falsy(view.topBar.forward.gwEnabled, "nothing further ahead")
    crumbs[2]:GetScript("OnClick")(crumbs[2])
    equal(guideUI.CurrentPage().level, "dungeon", "the Deadmines crumb goes up one level")
    crumbs[1]:GetScript("OnClick")(crumbs[1])
    truthy(view.browser.shown, "Dungeons goes to the cards")

    -- VanCleef: the wanted item in the grid, the native tooltip at the cursor.
    guideUI.Show(36, 7)
    equal(page.name.gwText, "Edwin VanCleef")
    contains(page.facts.gwText, "Rare elite")
    truthy(page.detailBadge.gwLines, "the reference indicator")
    local barb
    for _, itemCell in ipairs(page.cells.items) do
        if itemCell.shown ~= false and itemCell.gwData and itemCell.gwData.itemId == 5191 then barb = itemCell end
    end
    truthy(barb, "Cruel Barb in VanCleef's loot")
    equal(barb.icon.gwFile, 133000 + 5191, "the client's item icon")
    equal(barb.gwWanted, true, "the wishlist diamond on the item")
    equal(barb.gwAcquired, false, "not acquired")
    local tooltip = _G.GameTooltip
    local calls = {}
    tooltip.SetOwner = function(_, _, anchor) calls.anchor = anchor end
    tooltip.ClearAllPoints = function() end
    tooltip.SetPoint = function(_, point, relative, relativePoint, x, y) calls.point = { point, relative, relativePoint, x, y } end
    tooltip.SetHyperlink = function(_, link) calls.link = link end
    tooltip.AddLine = function(_, text) calls.lines = (calls.lines or "") .. tostring(text) .. "\n" end
    tooltip.ClearLines = function() end
    tooltip.Show = function() calls.shown = true end
    tooltip.Hide = function() calls.shown = false end
    _G.IsModifiedClick = function(name) return name == "COMPAREITEMS" and env.shift == true end
    _G.GameTooltip_ShowCompareItem = function() calls.compared = (calls.compared or 0) + 1 end
    barb:GetScript("OnEnter")(barb)
    equal(calls.anchor, "ANCHOR_NONE")
    equal(calls.point[1], "BOTTOMLEFT")
    equal(calls.point[2], _G.UIParent, "anchored to the screen at the cursor")
    equal(calls.point[4], 618, "just right of the pointer (x 600)")
    equal(calls.point[5], 406)
    equal(calls.link, "item:5191", "the client's own item tooltip")
    contains(calls.lines, "Drops from Edwin VanCleef")
    contains(calls.lines, "On your wishlist")
    falsy(calls.compared, "no comparison without shift")
    env.shift = true
    env:dispatch("MODIFIER_STATE_CHANGED", "LSHIFT", 1)
    equal(calls.compared, 1, "shift shows Blizzard's comparison")
    barb:GetScript("OnLeave")(barb)
    falsy(calls.shown, "gone on leave")
    falsy(guideUI.hoveredItem)
    env:dispatch("MODIFIER_STATE_CHANGED", "LSHIFT", 0)
    equal(calls.compared, 1, "nothing shows after the mouse left")
    -- Spell rows: the client's spell tooltip with the label, at the cursor.
    tooltip.SetSpellByID = function(_, id) calls.spell = id end
    calls.lines, calls.point = "", nil
    local ability = page.abilityRows.items[1]
    ability:GetScript("OnEnter")(ability)
    truthy(calls.spell, "spell tooltip by ID")
    equal(calls.point[4], 618, "the same tooltip convention")
    contains(calls.lines, "unverified on Forever")

    -- Spell icons: C_Spell's answer; a spell without one gets the empty slot.
    local icon, found = guideUI.SpellIcon(6306)
    equal(icon, 136006, "the icon from C_Spell.GetSpellTexture")
    truthy(found)
    guideUI.Show(36, 6)
    local slotted
    for _, row in ipairs(page.abilityRows.items) do
        if row.shown ~= false and row.gwData and row.gwData.id == 5174 then slotted = row end
    end
    truthy(slotted, "Cookie's ability without a client icon is still listed")
    equal(slotted.icon.gwFile, guideUI.ICONS.noSpell, "an empty slot, not a red question mark")
    contains(slotted.text.gwText, slotted.gwData.spell.n, "with its name")
    local kick = false
    for _, row in ipairs(page.abilityRows.items) do
        if row.shown ~= false and row.gwData and row.tag.gwText == "KICK" then kick = true end
    end
    truthy(kick, "Cookie's kick")
    equal(page.abilityRows.items[1].tag.gwText, "KICK", "dangerous interrupts first")

    -- Trash: a compact page, with the loot attributed to it by name.
    guideUI.Navigate(guideUI.Pages.creature(36, "trash", 7))
    equal(page.name.gwText, "Sneed's Shredder")
    contains(page.facts.gwText, "Dangerous trash")
    equal(page.gwLootCount, 1, "the drop the atlas names it as the source of")
    -- Other dungeon loot: never attributed to a boss.
    guideUI.Navigate(guideUI.Pages.creature(36, "other", 1))
    equal(page.name.gwText, "Other dungeon loot")
    falsy(page.keyHeader.shown, "no mechanics")
    truthy(page.gwLootCount >= 4, "unsourced and unknown-source drops")

    -- Quests: names, levels, givers, objectives and rewards.
    guideUI.Navigate(guideUI.Pages.dungeon(36, "quests"))
    truthy(page.quests.shown)
    falsy(page.list.shown, "quests take the full width")
    equal(crumbs[3].label.gwText, "Quests")
    local quest = page.questRows.items[1]
    equal(quest.name.gwText, "The Defias Brotherhood")
    contains(quest.facts.gwText, "Level 22")
    contains(quest.facts.gwText, "Alliance")
    contains(quest.giver.gwText, "Gryan Stoutmantle")
    contains(quest.objective.gwText, "Edwin VanCleef")
    equal(quest.rewardLabel.gwText, "CHOOSE ONE")
    truthy(quest.rewards.items[1].icon.gwFile, "reward item icons")
    falsy(string.find(quest.facts.gwText, "Completed", 1, true), "not claimed completed")
    _G.C_QuestLog = { IsQuestFlaggedCompleted = function(id) return id == 166 end }
    main:RefreshView()
    contains(quest.facts.gwText, "Completed", "only when the client confirms it")
    _G.C_QuestLog = nil

    local itemQueries = env:callCount("GetItemInfo")
    equal(itemQueries, 0, "item icons come without item queries")
    equal(env.protectedCalls, 0)
end

-- Runs in the journal, the current-run strip, the HUD's faces and observed states.
do
    local env, addon = boot()
    local hud, sessions, guideUI, main = addon.DungeonHud, addon.DungeonSessions, addon.DungeonGuideUI, addon.MainFrame
    zone(env, DEADMINES)
    truthy(addon.DungeonGuide.IsBuilt(36), "entering a known dungeon builds it (out of combat)")
    env:dispatch("PLAYER_REGEN_DISABLED")
    env:dispatch("PLAYER_REGEN_ENABLED")
    env:dispatch("ENCOUNTER_START", 2741, "Rhahk'Zor", 1, 5)
    env.serverTime = env.serverTime + 30
    env:advance(30)
    env:dispatch("ENCOUNTER_END", 2741, "Rhahk'Zor", 1, 5, 1)
    env:dispatch("ENCOUNTER_START", 2746, "Cookie", 1, 5)
    local entries = hud.Portraits(sessions.Current())
    equal(entries[1].displayId, 14403, "Rhahk'Zor's face from the journal's art table")
    equal(entries[2].kind, "engaged")
    equal(entries[2].displayId, 1305, "Cookie's")
    hud:SetMode("expanded")
    hud:Refresh()
    -- The HUD's ? opens the dungeon the run is in.
    hud.guideButton:Click()
    local view = main.views.dungeon
    equal(guideUI.CurrentPage().level, "dungeon")
    equal(guideUI.CurrentPage().id, 36)
    -- The strip: the open run, compact.
    truthy(view.strip.shown, "the current run's strip")
    equal(view.strip.name.label.gwText, "The Deadmines", "the run, as the client names it")
    contains(view.strip.state.gwText, "Bosses 1")
    truthy(view.gwTop > 28, "the pages start under it")
    falsy(view.topBar.here.shown, "already on the current dungeon")
    local list = view.dungeon.bossRows.items
    equal(list[6].portrait.gwState, "engaged", "Cookie: fighting now, as the run observed")
    contains(list[6].sub.gwText, "In combat")
    equal(list[1].portrait.gwState, "defeated", "Rhahk'Zor: killed in this run")
    contains(list[1].sub.gwText, "Defeated")
    equal(list[7].portrait.gwState, "available", "VanCleef: nothing observed")
    -- A boss face in the HUD deep-links to that encounter.
    hud.circles["boss:2741"].frame:GetScript("OnClick")()
    equal(guideUI.CurrentPage().level, "creature")
    equal(view.dungeon.name.gwText, "Rhahk'Zor")
    contains(view.dungeon.facts.gwText, "Defeated")
    -- Another dungeon: the way back to the current one.
    guideUI.Show(389)
    truthy(view.topBar.here.shown, "Current dungeon")
    view.topBar.here:Click()
    equal(guideUI.CurrentPage().id, 36)
    -- End the run from the strip (twice), then it is under My Runs.
    env:dispatch("ENCOUNTER_END", 2746, "Cookie", 1, 5, 1)
    view.strip.finish:Click()
    view.strip.finish:Click()
    equal(sessions.Current(), nil, "two clicks end the run")
    falsy(view.strip.shown, "no strip without a run")
    equal(view.gwTop, 28)
    guideUI.Navigate(guideUI.Pages.dungeon(36, "runs"))
    local row = view.dungeon.runRows.items[1]
    truthy(row and row.shown ~= false, "the run, under the Deadmines' runs")
    contains(row.when.gwText, "Bosses 2")
    truthy(row.time.gwText ~= "", "its duration")
    truthy(row.outcome.gwText ~= "", "its outcome")
    guideUI.Navigate(guideUI.Pages.browser("runs"))
    equal(view.browser.runRows.items[1].title.gwText, "The Deadmines", "and under all runs")
    view.browser.runRows.items[1]:GetScript("OnClick")(view.browser.runRows.items[1])
    equal(guideUI.CurrentPage().tab, "runs", "a run opens its dungeon's runs")
    equal(addon.DungeonGuide.RunInstanceId(sessions.History()[1]), 36)
    equal(env.protectedCalls, 0)
end

-- Resizing: test/dungeon_journal_layout_spec.lua.

-- Never packaged: the reference add-ons, and glyphs the game font lacks.
do
    local toc = read("Guildweaver.toc")
    falsy(string.find(toc, "references", 1, true), "the TOC lists nothing from references/")
    for line in string.gmatch(toc, "[^\n]+") do
        if not line:find("^#") and line ~= "" then falsy(line:find("^%.%."), "TOC paths stay inside the add-on") end
    end
    contains(read(".gitignore"), "references/", "git ignores a nested references/ checkout")
    contains(read(".luacheckrc"), "references/", "luacheck skips it")
    contains(read(".github/workflows/ci.yml"), "./references", "the syntax check skips it")
    -- Glyphs that render as squares in the game's fonts.
    local glyphs = { "\226\150\190", "\226\151\134", "\226\156\147", "\226\152\133", "\226\128\185", "\226\128\186" }
    for _, path in ipairs({ "UI/DungeonGuide.lua", "UI/DungeonMap.lua", "UI/Portraits.lua" }) do
        local text = read(path)
        for _, glyph in ipairs(glyphs) do falsy(string.find(text, glyph, 1, true), path .. " uses no glyph the font lacks") end
    end
end

print("dungeon journal tests passed")
