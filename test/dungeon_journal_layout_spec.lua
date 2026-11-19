-- The dashboard and the dungeon journal follow the window's size: the
-- regression for content that overflowed the window after a resize.
--
-- The fake client draws nothing and does no layout of its own, so the
-- window here is given a size model (SetSize stores the size, GetWidth and
-- GetHeight report it, and OnSizeChanged fires, as the client does). The
-- checks are on the sizes and columns the journal computes for itself:
-- they prove the arithmetic keeps everything inside the content area, not
-- how it looks in the game.

local Env = dofile("test/support/wow_env.lua")

local function equal(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function truthy(value, label)
    if not value then error((label or "value") .. ": expected truthy value", 2) end
end

local function within(value, limit, label)
    if not (tonumber(value) and value <= limit + 0.01) then
        error((label or "value") .. ": " .. tostring(value) .. " exceeds " .. tostring(limit), 2)
    end
end

local SIDEBAR_AND_PAD = 168 + 1 + 40

local screen = { w = 1920, h = 1080 }

-- The window as the client sizes it.
local function model(frame)
    local size, points = { w = 0, h = 0 }, {}
    rawset(frame, "SetSize", function(self, w, h)
        local changed = size.w ~= w or size.h ~= h
        size.w, size.h = w, h
        local handler = changed and self:GetScript("OnSizeChanged")
        if handler then handler(self, w, h) end
    end)
    rawset(frame, "GetWidth", function() return size.w end)
    rawset(frame, "GetHeight", function() return size.h end)
    rawset(frame, "ClearAllPoints", function() points = {} end)
    rawset(frame, "SetPoint", function(_, point, relative, relativePoint, x, y) points = { point, relative, relativePoint, x, y } end)
    rawset(frame, "GetPoint", function() return points[1], points[2], points[3], points[4], points[5] end)
    return size
end

local function boot(saved)
    local env = Env.new()
    local addon = env:load()
    local G = _G
    G.UIParent.GetWidth = function() return screen.w end
    G.UIParent.GetHeight = function() return screen.h end
    G.UIParent.GetEffectiveScale = function() return 1 end
    G.GetCursorPosition = function() return 600, 400 end
    local base = G.CreateFrame
    G.CreateFrame = function(frameType, name, ...)
        local frame = base(frameType, name, ...)
        if name == "GuildweaverMainFrame" then env.windowSize = model(frame) end
        return frame
    end
    if saved then GuildweaverDB = saved end
    env:login()
    env:advance(3)
    return env, addon
end

-- A drag of the grip: the client resizes the window step by step (each step
-- fires OnSizeChanged), then the mouse is released.
local function drag(env, main, steps)
    local grip = main.frame.sizeGrip
    grip:GetScript("OnMouseDown")()
    for _, step in ipairs(steps) do
        main.frame:SetSize(step[1], step[2])
        env:advance(0.1)
    end
    grip:GetScript("OnMouseUp")()
end

-- Everything the journal laid out stays inside the content area.
local function checkJournal(main, label)
    local width, height = main:ContentSize()
    local window = select(1, main.frame:Size())
    equal(width, window - SIDEBAR_AND_PAD, label .. ": the content area follows the window")
    local view = main.views.dungeon
    equal(view.gwWidth, width, label .. ": the journal is laid out for it")
    local browser = view.browser
    within(browser.grid.gwViewWidth, width, label .. ": the card grid")
    local columns = browser.columns
    within(columns * browser.gwCardWidth + (columns - 1) * 10, browser.grid:ContentWidth(), label .. ": the cards")
    for index, row in ipairs(browser.gwControlRows) do within(row, width, label .. ": control row " .. index) end
    within(168, width, label .. ": Journal / My Runs")
    local page = view.dungeon
    if page.gwCompact then
        within(page.leftWidth, width, label .. ": the list")
    else
        within(page.leftWidth + 16 + page.rightWidth, width, label .. ": list and map side by side")
    end
    within(page.map.gwWidth + 2, page.rightWidth, label .. ": the map's width")
    within(page.map.gwHeight + 2 + 26 + 24, page.rightHeight, label .. ": the map's height")
    truthy(math.abs(page.map.gwWidth / page.map.gwHeight - 1002 / 668) < 0.01, label .. ": the map keeps its aspect")
    within(page.detail.gwViewWidth, page.rightWidth, label .. ": the creature panel")
    if rawget(page, "gwCreature") then
        within(page.gwGridWidth, page.detail:ContentWidth(), label .. ": the loot grid")
    end
    local bar = view.topBar
    within(bar.gwCrumbsWidth, math.max(bar.gwCrumbRoom, 40 * 3 + 44), label .. ": the breadcrumb")
    return width, height
end

-- Minimum, medium and large windows; three, two and one columns; dragging
-- smaller and larger, repeatedly.
do
    local env, addon = boot()
    local main, guideUI = addon.MainFrame, addon.DungeonGuideUI
    main:Open("dungeon")
    local view = main.views.dungeon
    checkJournal(main, "default 1050 x 700")
    equal(view.browser.columns, 3, "1050 wide: three columns")

    -- The overflow: the window shrinks while the grip is dragged; before
    -- the fix nothing was laid out until the release (or ever, if the
    -- release was missed), and the cards kept their old widths.
    local grip = main.frame.sizeGrip
    grip:GetScript("OnMouseDown")()
    main.frame:SetSize(760, 520)
    env:advance(0.1)
    checkJournal(main, "during the drag")
    equal(view.browser.columns, 2, "760 wide: two columns")
    grip:GetScript("OnMouseUp")()
    equal(GuildweaverDB.ui.dashboard.width, 760, "the size is saved when the drag ends")

    -- Below the minimum: the client is told the bounds; the end clamps.
    drag(env, main, { { 600, 380 } })
    equal(GuildweaverDB.ui.dashboard.width, 740, "never narrower than 740")
    equal(GuildweaverDB.ui.dashboard.height, 500, "never lower than 500")
    local width = checkJournal(main, "minimum 740 x 500")
    equal(width, 531, "the narrowest content area")
    equal(view.browser.columns, 2, "two columns at the minimum")
    equal(#view.browser.gwControlRows, 1, "the search and both switches in one row")

    -- Larger than the screen: clamped to it.
    drag(env, main, { { 3000, 2000 } })
    equal(GuildweaverDB.ui.dashboard.width, 1900, "within the screen")
    equal(GuildweaverDB.ui.dashboard.height, 1060)
    checkJournal(main, "maximum")
    equal(view.browser.columns, 3, "three columns at most")

    -- A dungeon, a boss and quests at each size.
    guideUI.Show(36, 7)
    local page = view.dungeon
    drag(env, main, { { 1260, 800 } })
    checkJournal(main, "VanCleef, large")
    local wide = page.gwGridColumns
    drag(env, main, { { 740, 500 } })
    checkJournal(main, "VanCleef, minimum")
    truthy(page.gwGridColumns < wide, "the loot grid has fewer columns in a narrower panel")
    truthy(page.gwGridColumns >= 1)
    guideUI.Navigate(guideUI.Pages.dungeon(36))
    checkJournal(main, "the Deadmines' map, minimum")
    local narrowMap = page.map.gwWidth
    guideUI.Navigate(guideUI.Pages.dungeon(36, "quests"))
    for index = 1, 5 do equal(page.questRows.items[index].gwWidth, page.quests:ContentWidth(), "quest " .. index .. " spans the area") end

    -- Shrinking and growing again and again: frames are reused.
    guideUI.Navigate(guideUI.Pages.dungeon(36))
    local frames
    for cycle = 1, 3 do
        for _, size in ipairs({ { 1260, 800 }, { 740, 500 }, { 1050, 700 }, { 800, 560 }, { 1500, 900 } }) do
            drag(env, main, { { size[1] - 50, size[2] - 30 }, size })
            checkJournal(main, "cycle " .. cycle .. " at " .. size[1])
        end
        if cycle == 1 then frames = #env.frames else equal(#env.frames, frames, "no new frames on cycle " .. cycle) end
    end
    truthy(page.map.gwWidth > narrowMap, "the map grows with the window")
    guideUI.Navigate(guideUI.Pages.browser())
    checkJournal(main, "the cards after it all")

    -- One column, and the compact overview: below the window's minimum
    -- content width, laid out directly.
    equal(guideUI.Columns(400), 1, "one column under 490")
    equal(guideUI.Columns(531), 2)
    equal(guideUI.Columns(841), 3)
    equal(guideUI.Columns(2000), 3)
    guideUI.Layout(view, 420, 400)
    guideUI.Reflow(view)
    equal(view.browser.columns, 1, "a 420-wide grid: one column")
    equal(#view.browser.gwControlRows, 2, "the switches wrap under the search")
    for _, row in ipairs(view.browser.gwControlRows) do within(row, 420, "a wrapped control row") end
    truthy(view.dungeon.gwCompact, "the overview stacks the list over the map")
    within(view.dungeon.map.gwWidth + 2, 420, "the map fits the narrow width")
    guideUI.Layout(view, 300, 400)
    equal(#view.browser.gwControlRows, 3, "each control on its own row when even that does not fit")
    main:Relayout()
    checkJournal(main, "back to the window")
    equal(env.protectedCalls or 0, 0)
end

-- Every other view at the minimum and the maximum.
do
    local env, addon = boot()
    local main = addon.MainFrame
    main:Open("overview")
    for _, size in ipairs({ { 740, 500 }, { 1900, 1060 }, { 740, 500 } }) do
        drag(env, main, { size })
        local width = select(1, main:ContentSize())
        for _, key in ipairs({ "overview", "farming", "sync", "settings", "dungeon" }) do
            equal(main:Select(key), key, key .. " opens at " .. size[1])
            truthy(main.views[key].shown, key .. " is shown")
        end
        local overview = main.views.overview
        main:Select("overview")
        truthy(overview.gwLaidOut == width .. "x" .. select(2, main:ContentSize()), "the overview is laid out for the size")
        within(width, 1900 - SIDEBAR_AND_PAD, "the content area at " .. size[1])
    end
end

-- The size and position after /reload; a UI scale change clamps and restores.
do
    local env, addon = boot()
    local main = addon.MainFrame
    main:Open("dungeon")
    drag(env, main, { { 900, 620 } })
    equal(GuildweaverDB.ui.dashboard.width, 900)
    truthy(GuildweaverDB.ui.mainFrame.point, "the position is saved with the size")
    env:dispatch("PLAYER_LOGOUT")
    local _, again = boot(GuildweaverDB)
    again.MainFrame:Open()
    local width, height = again.MainFrame.frame:Size()
    equal(width, 900, "the width after /reload")
    equal(height, 620, "the height after /reload")
    checkJournal(again.MainFrame, "after /reload")

    -- A larger UI scale: the screen is 800 x 560 in UI units now.
    screen.w, screen.h = 800, 560
    again.MainFrame.frame.screenEvents:GetScript("OnEvent")(again.MainFrame.frame.screenEvents, "UI_SCALE_CHANGED")
    width, height = again.MainFrame.frame:Size()
    equal(width, 780, "clamped to the smaller screen")
    equal(height, 540)
    checkJournal(again.MainFrame, "after the UI scale grew")
    equal(GuildweaverDB.ui.dashboard.width, 900, "the chosen size is kept")
    screen.w, screen.h = 1920, 1080
    again.MainFrame.frame.screenEvents:GetScript("OnEvent")(again.MainFrame.frame.screenEvents, "UI_SCALE_CHANGED")
    equal(select(1, again.MainFrame.frame:Size()), 900, "and comes back when there is room")
    checkJournal(again.MainFrame, "after the UI scale shrank")
    -- A screen smaller than the minimum: the minimum still holds.
    screen.w, screen.h = 640, 480
    again.MainFrame.frame.screenEvents:GetScript("OnEvent")(again.MainFrame.frame.screenEvents, "DISPLAY_SIZE_CHANGED")
    equal(select(1, again.MainFrame.frame:Size()), 740, "never below the minimum")
    screen.w, screen.h = 1920, 1080
end

-- In combat a resize lays out after the fight; the drag stays cheap.
do
    local env, addon = boot()
    local main, guide = addon.MainFrame, addon.DungeonGuide
    main:Open("dungeon")
    local view = main.views.dungeon
    env.inCombat = true
    main.frame:SetSize(800, 560)
    env:advance(0.1)
    truthy(main.relayoutPending, "no layout in combat")
    equal(view.gwWidth, 841, "the old layout until the fight ends")
    env.inCombat = false
    env:dispatch("PLAYER_REGEN_ENABLED")
    equal(view.gwWidth, 800 - SIDEBAR_AND_PAD, "laid out when combat ends")
    -- Many size changes during a drag: one layout per 50 ms, no data reads.
    env:resetCalls()
    local builds = 0
    local build = guide.Dungeon
    guide.Dungeon = function(id)
        builds = builds + 1
        return build(id)
    end
    local layouts = 0
    local spec = main.Views.dungeon
    local layout = spec.layout
    spec.layout = function(...)
        layouts = layouts + 1
        return layout(...)
    end
    main.frame.sizeGrip:GetScript("OnMouseDown")()
    for step = 1, 30 do main.frame:SetSize(800 + step * 10, 560 + step * 4) end
    env:advance(0.1)
    equal(layouts, 1, "thirty size changes in one frame: one layout")
    equal(builds, 0, "a drag reads no dungeon data")
    main.frame.sizeGrip:GetScript("OnMouseUp")()
    spec.layout = layout
    guide.Dungeon = build
    equal(env:callCount("GetItemInfo"), 0)
end

print("dungeon journal layout tests passed")
