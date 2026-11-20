-- The journal's look (sprint step 5A): Blizzard's own UI art through the
-- theme (Theme.Panel, Theme.Texture, Theme.Divider, Theme.Highlight), with
-- the flat look as the fallback wherever the client lacks a file or the
-- backdrop template; the dungeon cards (art or an emblem, quest readiness),
-- the framed map, the boss page's header and mechanic callouts, item slots,
-- the quest summary; and every page of every dungeon, wing, WoW Forever
-- dungeon and raid laid out at small, medium and large sizes.
--
-- The fake client draws nothing: these tests prove which art is asked for,
-- the fallbacks and the layout's bounds, not how it looks (the in-game
-- checklist in docs/dungeon-guide.md does).

local Env = dofile("test/support/wow_env.lua")

local function equal(actual, expected, label)
    if actual ~= expected then error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2) end
end

local function truthy(value, label)
    if not value then error((label or "value") .. ": expected truthy value", 2) end
end

local function falsy(value, label)
    if value then error((label or "value") .. ": expected falsy value, got " .. tostring(value), 2) end
end

local function contains(text, part, label)
    if not string.find(tostring(text), part, 1, true) then error((label or "text") .. ": " .. tostring(text) .. " lacks " .. part, 2) end
end

local function within(value, limit, label)
    if value > limit + 0.5 then error((label or "value") .. ": " .. tostring(value) .. " exceeds " .. tostring(limit), 2) end
end

-- The client: textures that remember what they were given, and (when the
-- client has it) the backdrop template. missing: files SetTexture refuses.
local function boot(options)
    options = options or {}
    local env = Env.new()
    local addon = env:load()
    local G = _G
    G.IsInInstance = function() return false, "none" end
    G.GetInstanceInfo = function() return "Elwynn Forest", "none", 0, "", 0, 0, false, 0 end
    G.GetInstanceLockTimeRemaining = function() return 0, false, 0, 0 end
    G.UnitXP, G.UnitXPMax, G.GetMaxPlayerLevel = function() return 1000 end, function() return 5000 end, function() return 60 end
    G.UnitFactionGroup = function() return "Alliance" end
    G.EJ_GetInstanceForMap, G.C_Map = nil, nil
    G.SetPortraitTextureFromCreatureDisplayID = function(texture, displayId) texture.gwDrawnDisplay = displayId end
    G.GetItemIcon = function(itemId) return 133000 + itemId end
    G.GetSpellTexture = function(spellId) return 136000 + (spellId % 100) end
    G.GetCursorPosition = function() return 600, 400 end
    G.UIParent.GetEffectiveScale = function() return 1 end
    local missing = options.missing or {}
    local stub = getmetatable(G.CreateFrame("Frame"))
    local function texture()
        local t = setmetatable({ shown = true }, stub)
        rawset(t, "SetTexture", function(self, file)
            if missing[file] then return false end
            self.file = file
            return true
        end)
        rawset(t, "SetColorTexture", function(self, r, g, b, a) self.color = { r, g, b, a } end)
        rawset(t, "SetVertexColor", function(self, r, g, b, a) self.vertex = { r, g, b, a } end)
        rawset(t, "Show", function(self) self.shown = true end)
        rawset(t, "Hide", function(self) self.shown = false end)
        return t
    end
    local base = G.CreateFrame
    env.backdrops = {}
    G.CreateFrame = function(frameType, name, parent, template, ...)
        local frame = base(frameType, name, parent, template, ...)
        rawset(frame, "CreateTexture", function() return texture() end)
        if template == "BackdropTemplate" and options.backdrop ~= false then
            rawset(frame, "SetBackdrop", function(self, spec) self.backdrop = spec end)
            rawset(frame, "SetBackdropBorderColor", function(self, r, g, b, a) self.edge = { r, g, b, a } end)
            table.insert(env.backdrops, frame)
        end
        return frame
    end
    addon.Portraits.Reset()
    env:login()
    env:advance(3)
    return env, addon
end

local function sameColor(rgba, name, Theme, label)
    local want = Theme.Color(name)
    truthy(rgba, label .. ": a colour")
    for index = 1, 3 do truthy(math.abs(rgba[index] - want[index]) < 0.001, label .. ": " .. name) end
end

-- 1. With the art: Blizzard's rock, borders, slots and highlights -------------------------------
do
    local _, addon = boot()
    local Theme, guideUI, main = addon.Theme, addon.DungeonGuideUI, addon.MainFrame
    truthy(guideUI.Show(), "the journal opens")
    local view = main.views.dungeon
    local browser = view.browser
    local function cardFor(id)
        for _, candidate in ipairs(browser.cards.items) do
            if candidate.gwData and candidate.gwData.id == id then return candidate end
        end
    end
    local card = cardFor(36)
    truthy(card, "the Deadmines' card")
    local skin = card.gwSkin
    truthy(skin.rock, "the card is on Blizzard's rock")
    equal(skin.bg.file, Theme.ART.rock)
    truthy(skin.shade.shown, "under a shade, so the text reads")
    truthy(skin.backdrop and skin.backdrop.backdrop, "inside a Blizzard border")
    equal(skin.backdrop.backdrop.edgeFile, Theme.ART.tooltipBorder)
    for _, edge in ipairs(skin.edges) do falsy(edge.shown, "no hairline under the border") end
    sameColor(skin.backdrop.edge, "borderStrong", Theme, "resting edge")
    card:GetScript("OnEnter")(card)
    sameColor(skin.backdrop.edge, "gold", Theme, "hover edge")
    card:GetScript("OnLeave")(card)
    sameColor(skin.backdrop.edge, "borderStrong", Theme, "edge after hover")
    equal(rawget(card, "accent"), nil, "no gold underline under the name")
    contains(card.ready.gwText, "Quests not known", "the character's readiness (no quest API in this client)")
    -- A WoW Forever dungeon has no map art: the emblem stands in.
    local forever = cardFor(3065)
    truthy(forever, "the Hall of Thanes' card")
    truthy(forever.emblem.shown, "no art: the emblem")
    falsy(forever.art.shown, "and no empty art")

    -- The map: framed in the gold edge.
    guideUI.Navigate(guideUI.Pages.dungeon(36))
    local page = view.dungeon
    local mapSkin = page.map.gwSkin
    truthy(mapSkin.backdrop and mapSkin.backdrop.backdrop, "the map's frame")
    equal(mapSkin.backdrop.backdrop.edgeFile, Theme.ART.goldBorder)
    -- Section headers: a line from the title to the edge, not an underline.
    local header = page.headers[1]
    truthy(header.accent, "the header's line")

    -- The boss page: a framed header, key mechanics as callouts.
    guideUI.Show(36, 7)
    truthy(page.hero.gwSkin.rock, "the boss's header on the rock")
    local top = page.gwCreature.top
    truthy(top >= 1, "VanCleef has key mechanics")
    for index = 1, page.gwCreature.count do
        equal(page.abilityRows.items[index].gwCallout, index <= top, "ability " .. index .. (index <= top and " is a callout" or " is a plain row"))
    end
    local callout = page.abilityRows.items[1]
    truthy(callout.stripe.color and callout.stripe.color[4] > 0.5, "a coloured edge")
    truthy(callout.wash.color and callout.wash.color[4] > 0 and callout.wash.color[4] < 0.2, "a faint wash")
    if page.gwCreature.count > top then
        equal(page.abilityRows.items[top + 1].stripe.color[4], 0, "other abilities: no edge")
    end
    -- Loot: the bag slot's frame, in the item's quality colour.
    local cell = page.cells.items[1]
    truthy(cell.gwSlotArt, "the slot art")
    equal(cell.slot.file, Theme.ART.slot)
    local quality = cell.gwData.item and cell.gwData.item.q or 1
    if quality >= 2 then truthy(cell.slot.vertex[1] ~= 1 or cell.slot.vertex[2] ~= 1, "tinted by quality") end

    -- Quests: the summary in a framed well, edged in the readiness colour.
    guideUI.Navigate(guideUI.Pages.dungeon(36, "quests"))
    truthy(page.questBox.shown, "the summary's well")
    truthy(page.questBox.gwSkin.backdrop, "inside a border")
    sameColor(page.questBox.stripe.color, "textFaint", Theme, "unknown readiness")
    truthy(page.questHeads.items[1].accent, "group headers")
    contains(page.questSummary.gwText, "Not known")
end

-- 2. Without the art (or the backdrop template): the flat look, never a broken frame ----------
do
    local missing = {}
    local _, probe = boot()
    for _, file in pairs(probe.Theme.ART) do missing[file] = true end
    local _, addon = boot({ missing = missing, backdrop = false })
    local guideUI, main = addon.DungeonGuideUI, addon.MainFrame
    truthy(guideUI.Show(36, 7))
    local page = main.views.dungeon.dungeon
    local skin = page.hero.gwSkin
    falsy(skin.rock, "no rock")
    falsy(skin.shade.shown, "no shade over a flat surface")
    falsy(skin.backdrop, "no backdrop")
    for _, edge in ipairs(skin.edges) do truthy(edge.shown ~= false, "the hairline stays") end
    local cell = page.cells.items[1]
    falsy(cell.gwSlotArt, "no slot art")
    falsy(cell.slot.shown, "and nothing empty drawn for it")
    -- Hover and borders still work on the fallback.
    addon.Theme.SetBorder(page.hero, "gold")
    truthy(skin.edges[1].color, "the hairline takes the colour")
end

-- 3. Every page, at small, medium and large sizes --------------------------------------------------
do
    local _, addon = boot()
    local Guide, guideUI, main = addon.DungeonGuide, addon.DungeonGuideUI, addon.MainFrame
    main:Open("dungeon")
    local view = main.views.dungeon
    local page = view.dungeon
    local ids, seen, raidIds = {}, {}, {}
    for _, entry in ipairs(Guide.List()) do
        if entry.kind == "raid" then raidIds[entry.id] = true end
        if not seen[entry.id] then table.insert(ids, entry.id); seen[entry.id] = true end
        if entry.instanceId and not seen[entry.instanceId] then table.insert(ids, entry.instanceId); seen[entry.instanceId] = true end
    end
    local wings, forever, raids = 0, 0, 0
    for _, id in ipairs(ids) do
        if type(id) == "string" then wings = wings + 1 end
        if Guide.IsForever(id) then forever = forever + 1 end
        if raidIds[id] then raids = raids + 1 end
    end
    equal(wings, 11, "all eleven wings")
    equal(forever, 9, "all nine WoW Forever dungeons")
    equal(raids, 7, "the seven raids")
    local sizes = { { 420, 380 }, { 531, 420 }, { 860, 560 }, { 1700, 980 } }
    local pages = 0
    for _, id in ipairs(ids) do
        local dungeon = Guide.Dungeon(id)
        for _, size in ipairs(sizes) do
            guideUI.Layout(view, size[1], size[2])
            guideUI.Navigate(guideUI.Pages.dungeon(id))
            within(page.map.gwWidth + 2, page.rightWidth, tostring(id) .. " map at " .. size[1])
            guideUI.Navigate(guideUI.Pages.dungeon(id, "quests"))
            local width = page.quests:ContentWidth()
            for index = 1, rawget(page, "gwQuestCount") or 0 do
                equal(page.questRows.items[index].gwWidth, width, tostring(id) .. " quest " .. index .. " at " .. size[1])
            end
            if dungeon and dungeon.bosses and #dungeon.bosses > 0 then
                guideUI.Navigate(guideUI.Pages.creature(id, "boss", #dungeon.bosses))
                guideUI.Reflow(view)
                within(page.gwGridWidth or 0, page.detail:ContentWidth(), tostring(id) .. " loot grid at " .. size[1])
                truthy(page.gwGridColumns >= 1, tostring(id) .. " at least one loot column")
            end
            pages = pages + 1
        end
    end
    truthy(pages >= #ids * #sizes, "every page laid out")
    print(string.format("journal polish: %d guide pages x %d sizes (%d wings, %d WoW Forever, %d raids)", #ids, #sizes, wings, forever, raids))
end

-- 4. In combat the journal never builds the quest tables for the cards -------------------------
do
    -- A session that has not built them yet, then a fight.
    local env2, addon2 = boot()
    env2.inCombat = true
    falsy(addon2.DungeonReadiness.IsBuilt(), "not built at login (this client has no quest API)")
    equal(addon2.DungeonGuideUI.QuestReadiness(36), nil, "no readiness from unbuilt tables in combat")
    falsy(addon2.DungeonReadiness.IsBuilt(), "still not built")
    env2.inCombat = false
    truthy(addon2.DungeonGuideUI.QuestReadiness(36), "out of combat it is")
end

print("journal polish spec passed")
