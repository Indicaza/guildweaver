-- The in-game UI in the fake client: the minimap launcher (click, double-
-- click, right-click menu, drag), the dashboard (open, close, navigation,
-- remembered view and position), settings persistence, HUD visibility kept
-- apart from data collection, combat collapse and manual hiding, empty
-- data, reloads, and no protected calls. These prove behaviour, not looks:
-- the fake client renders nothing.

local Env = dofile("test/support/wow_env.lua")

local function equal(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function truthy(value, label)
    if not value then
        error((label or "value") .. ": expected truthy value", 2)
    end
end

local world

local function installWorld(env)
    local G = _G
    G.IsInInstance = function() return world.instance ~= nil, world.instance and world.instance.type or "none" end
    G.GetInstanceInfo = function()
        local instance = world.instance
        if not instance then return "Elwynn Forest", "none", 0, "", 0, 0, false, 0 end
        return instance.name, instance.type, instance.difficultyId, instance.difficultyName, instance.maxPlayers, 0, false, instance.id
    end
    G.UnitXP = function() return world.xp end
    G.UnitXPMax = function() return 5000 end
    G.GetMaxPlayerLevel = function() return 60 end
    G.GetNumGroupMembers = function() return 5 end
    G.GetInstanceLockTimeRemaining = function() return 3600, false, 3, world.complete end
    G.GetCursorPosition = function() return world.cursor[1], world.cursor[2] end
    for _, name in ipairs({ "CastSpellByName", "UseAction", "TargetUnit", "RunMacroText", "PickupContainerItem", "UseContainerItem" }) do
        G[name] = function() env.protectedCalls = (env.protectedCalls or 0) + 1 end
    end
end

-- The minimap: 140 wide, centred at (1000, 600), unscaled.
local function newMinimap(env)
    local minimap = env:newFrame("Frame", "Minimap")
    minimap.GetWidth = function() return 140 end
    minimap.GetCenter = function() return 1000, 600 end
    minimap.GetEffectiveScale = function() return 1 end
    return minimap
end

local SM = { name = "Scarlet Monastery", type = "party", difficultyId = 1, difficultyName = "Normal", maxPlayers = 5, id = 189 }

local function boot(saved)
    -- A reload keeps the world (the player is still where they were).
    if not saved then
        world = { instance = nil, xp = 1000, complete = 0, cursor = { 0, 0 } }
    end
    local env = Env.new()
    local addon = env:load()
    installWorld(env)
    newMinimap(env)
    env.protectedCalls = 0
    if saved then
        GuildweaverDB = saved.db
        env.serverTime = saved.serverTime
        env.inCombat = saved.inCombat == true
    end
    env:login()
    env:advance(3)
    return env, addon
end

local function zone(env, instance)
    world.instance = instance
    env:dispatch("PLAYER_ENTERING_WORLD", false, false)
    env:advance(2)
end

local function relog(env)
    env:dispatch("PLAYER_LOGOUT")
    return boot({ db = GuildweaverDB, serverTime = env.serverTime + 5, inCombat = env.inCombat })
end

local function click(widget, ...)
    local handler = widget:GetScript("OnClick")
    truthy(handler, "widget has an OnClick")
    handler(widget, ...)
end

-- Minimap launcher -------------------------------------------------------------------
do
    local env, addon = boot()
    local launcher, main = addon.MinimapButton, addon.MainFrame
    truthy(launcher.button, "the minimap button exists after login")
    truthy(launcher.button.shown, "and is shown by default")
    equal(GuildweaverDB.ui.minimap.angle, 215, "default angle")

    -- Single click: opens after the double-click window, never at once.
    equal(launcher:HandleClick("LeftButton"), "pending")
    truthy(not main:IsOpen(), "a single click waits for a possible second click")
    env:advance(0.4)
    truthy(main:IsOpen(), "single click opens the dashboard")
    equal(main.current, "overview", "on the overview the first time")
    launcher:HandleClick("LeftButton")
    env:advance(0.4)
    truthy(not main:IsOpen(), "single click again closes it")

    -- Double click: settings, and the first click's toggle never runs.
    equal(launcher:HandleClick("LeftButton"), "pending")
    env:advance(0.1)
    equal(launcher:HandleClick("LeftButton"), "double")
    truthy(main:IsOpen(), "double click opens")
    equal(main.current, "settings", "on Settings")
    env:advance(1)
    truthy(main:IsOpen(), "and stays open: no open-then-close")
    equal(main.current, "settings")

    -- Double click while open on another view switches to Settings, open.
    main:Select("farming")
    launcher:HandleClick("LeftButton")
    env:advance(0.1)
    launcher:HandleClick("LeftButton")
    env:advance(1)
    truthy(main:IsOpen(), "still open")
    equal(main.current, "settings")

    -- Two slow clicks are two single clicks.
    main:Close()
    launcher:HandleClick("LeftButton")
    env:advance(0.5)
    launcher:HandleClick("LeftButton")
    env:advance(0.5)
    truthy(not main:IsOpen(), "slow clicks: open, then close")

    -- The real OnClick script routes to the same handler.
    click(launcher.button, "LeftButton")
    env:advance(0.4)
    truthy(main:IsOpen(), "OnClick opens")
    main:Close()

    -- Right click: the quick menu.
    equal(launcher:HandleClick("RightButton"), "menu")
    local menu = addon.UI.menu
    truthy(menu and menu.shown, "the menu shows")
    local labels = {}
    for index, item in ipairs(menu.items) do labels[item.text or "-"] = index end
    truthy(labels["Open dashboard"] and labels["Dungeon HUD"] and labels["Settings"] and labels["Sync & data"], "menu items")
    truthy(labels["Start farming run"], "farming action offered")
    click(menu.rows[labels["Start farming run"]], "LeftButton")
    truthy(not menu.shown, "a pick closes the menu")
    equal(addon.FarmingSessions.Context().mode, "manual", "menu started a timed farming run")
    launcher:HandleClick("RightButton")
    truthy(menu.items[labels["Start farming run"]].text == "Stop farming run", "and now offers Stop")
    click(menu.catcher)
    truthy(not menu.shown, "an outside click closes the menu")
    addon.FarmingSessions.Stop()

    -- Drag: follows the cursor around the edge; the release is not a click.
    world.cursor = { 1000, 700 }
    launcher.button:GetScript("OnDragStart")(launcher.button)
    truthy(launcher.button:GetScript("OnUpdate"), "OnUpdate only while dragging")
    launcher.button:GetScript("OnUpdate")(launcher.button)
    launcher.button:GetScript("OnDragStop")(launcher.button)
    equal(launcher.button:GetScript("OnUpdate"), nil, "OnUpdate removed after the drag")
    equal(GuildweaverDB.ui.minimap.angle, 90, "angle saved: straight up")
    equal(launcher:HandleClick("LeftButton"), "drag", "the release right after a drag is ignored")
    env:advance(1)
    truthy(not main:IsOpen(), "so the drag does not open the dashboard")

    -- Hide from the menu; it persists; /gw minimap brings it back.
    launcher:HandleClick("RightButton")
    for index, item in ipairs(menu.items) do labels[item.text or "-"] = index end
    click(menu.rows[labels["Hide minimap button"]], "LeftButton")
    truthy(not launcher.button.shown, "hidden")
    local env2, addon2 = relog(env)
    truthy(not addon2.MinimapButton.button.shown, "still hidden after reload")
    equal(GuildweaverDB.ui.minimap.angle, 90, "angle after reload")
    SlashCmdList.GUILDWEAVER("minimap")
    truthy(addon2.MinimapButton.button.shown, "/gw minimap shows it")
    equal(env2.protectedCalls, 0, "no protected calls")
end

-- Dashboard navigation, memory and position ---------------------------------------------
do
    local env, addon = boot()
    local main = addon.MainFrame
    truthy(main.frame == nil, "nothing is built at login")
    SlashCmdList.GUILDWEAVER("")
    truthy(main:IsOpen(), "/gw opens it")
    for _, entry in ipairs(main.NAV) do
        click(main.nav[entry.key])
        equal(main.current, entry.key, "nav selects " .. entry.key)
        truthy(main.views[entry.key].shown, entry.key .. " view shown")
        for key, view in pairs(main.views) do
            if key ~= entry.key then truthy(not view.shown, key .. " hidden while " .. entry.key .. " is open") end
        end
    end
    click(main.settingsButton)
    equal(main.current, "settings", "header Settings button")
    equal(GuildweaverDB.ui.dashboard.view, "sync", "Settings is not remembered as the last view")
    main:Select("farming")
    SlashCmdList.GUILDWEAVER("")
    truthy(not main:IsOpen(), "/gw closes it")
    SlashCmdList.GUILDWEAVER("")
    equal(main.current, "farming", "reopens where it was")
    click(main.frame.closeButton)
    truthy(not main:IsOpen(), "the close button closes it")
    env:advance(1.1)
    truthy(main.ticker == nil, "no ticker while closed")
    SlashCmdList.GUILDWEAVER("settings")
    equal(main.current, "settings", "/gw settings")

    -- Dragging the header saves the position.
    main.frame.GetPoint = function() return "TOPLEFT", nil, "TOPLEFT", 120, -80 end
    main.frame.header:GetScript("OnDragStop")(main.frame.header)
    equal(GuildweaverDB.ui.mainFrame.point, "TOPLEFT")
    equal(GuildweaverDB.ui.mainFrame.x, 120)
    main:Select("dungeon")

    -- Reload: the last view and position are kept.
    local _, addon2 = relog(env)
    equal(GuildweaverDB.ui.mainFrame.x, 120, "position after reload")
    addon2.MainFrame:Open()
    equal(addon2.MainFrame.current, "dungeon", "last view after reload")
    addon2.MainFrame:ResetPosition()
    equal(GuildweaverDB.ui.mainFrame.point, "CENTER", "reset position")
    SlashCmdList.GUILDWEAVER("reset")
end

-- Empty data: every view renders with nothing recorded ----------------------------------
do
    local _, addon = boot()
    local main = addon.MainFrame
    main:Open()
    for _, key in ipairs({ "overview", "dungeon", "farming", "quests", "sync", "settings" }) do
        main:Select(key)
    end
    local dungeon = main.views.dungeon
    equal(dungeon.runCard.name.gwText, "No run open", "dungeon view without a run")
    truthy(not dungeon.runCard.timer.shown, "no timer controls without a run")
    truthy(dungeon.recentEmpty.shown, "empty recent runs say so")
    local farming = main.views.farming
    equal(farming.card.state.gwText, "Not timing")
    truthy(farming.fishingEmpty.shown, "fishing says it has nothing yet")
    truthy(not farming.fishingStats[1].shown, "instead of three zeros")
    equal(farming.card.clock.gwText, "", "no 0:00 when nothing is timed")
    local overview = main.views.overview
    main:Select("overview")
    equal(overview.cards.dungeon.main.gwText, "No run open")
    -- Guild Quests is hidden for this release: not in the sidebar, not built,
    -- and asking for it opens the overview. The quest system still runs.
    truthy(main.nav.quests == nil, "no Guild Quests in the sidebar")
    truthy(addon.QuestLog.frame == nil, "the quest log is not built")
    equal(main:Select("quests"), "overview", "the quests view falls back to the overview")
    truthy(main.views.overview.cards.quests == nil, "no quests card")
    truthy(addon.Quests.GetQuests("available"), "the quest data is still there")
    for _, entry in ipairs(main.NAV) do truthy(entry.key ~= "quests", "nav has no quests") end
    -- Advanced diagnostics are tucked away until asked for.
    main:Select("sync")
    local sync = main.views.sync
    truthy(not sync.advancedButtons[1].shown, "advanced hidden by default")
    click(sync.advancedToggle)
    truthy(sync.advancedButtons[1].shown, "advanced shown on request")
end

-- Farming from the dashboard -----------------------------------------------------------
do
    local env, addon = boot()
    local main = addon.MainFrame
    main:Open("farming")
    local card = main.views.farming.card
    equal(card.button:GetLabel(), "Start timed run")
    click(card.button)
    equal(addon.FarmingSessions.Context().mode, "manual", "Start begins a timed run")
    equal(card.button:GetLabel(), "Stop & save")
    equal(card.state.gwText, "Timing a run")
    env:advance(65)
    truthy(card.clock.gwText == "1:05" or card.clock.gwText == "1:04", "the elapsed time ticks while open: " .. tostring(card.clock.gwText))
    click(card.button)
    equal(addon.FarmingSessions.Context(), nil, "Stop saves it")
    local saved = false
    for key, record in pairs(env:telemetry()) do
        if key:find("farming_session:", 1, true) == 1 and record.envelope.payload.status == "complete" then saved = true end
    end
    truthy(saved, "a completed farming_session event is written")
end

-- Settings persist; hiding the HUD never stops recording --------------------------------
do
    local env, addon = boot()
    local main, hud = addon.MainFrame, addon.DungeonHud
    main:Open("settings")
    local settings = main.views.settings
    click(settings.hudToggle)
    equal(GuildweaverDB.ui.dungeonHud.enabled, false, "HUD off")
    click(settings.collapseToggle)
    equal(GuildweaverDB.ui.dungeonHud.collapseInCombat, false, "collapse off")
    click(settings.lockToggle)
    equal(GuildweaverDB.ui.dungeonHud.locked, true, "locked")
    click(settings.modeChoice.buttons[3])
    equal(GuildweaverDB.ui.dungeonHud.mode, "expanded", "default view: detailed")
    click(settings.scaleChoice.buttons[3])
    equal(GuildweaverDB.ui.dungeonHud.scale, 1.15, "size L")
    click(settings.minimapToggle)
    equal(GuildweaverDB.ui.minimap.hide, true, "minimap off from settings")

    zone(env, SM)
    env:dispatch("PLAYER_REGEN_DISABLED")
    env:dispatch("PLAYER_REGEN_ENABLED")
    truthy(not hud.visible, "a disabled HUD stays hidden in the dungeon")
    local run = addon.DungeonSessions.Current()
    truthy(run and run.inside, "the run is recorded anyway")
    equal(run.timer.state, "running", "and its timer started on the pull")

    local _, addon2 = relog(env)
    equal(GuildweaverDB.ui.dungeonHud.enabled, false, "HUD off after reload")
    equal(GuildweaverDB.ui.dungeonHud.locked, true)
    equal(GuildweaverDB.ui.dungeonHud.scale, 1.15)
    truthy(not addon2.MinimapButton.button.shown, "minimap off after reload")
    addon2.MainFrame:Open("settings")
    truthy(addon2.MainFrame.views.settings.hudToggle.gwValue == false, "the toggle shows the saved state")
    truthy(addon2.DungeonSessions.Current().inside, "the run continues after the reload")
    click(addon2.MainFrame.views.settings.hudToggle)
    truthy(addon2.DungeonHud.visible, "turning it on shows it at once")
end

-- Combat collapse, a pick during combat, recovery ----------------------------------------
do
    local env, addon = boot()
    local hud = addon.DungeonHud
    zone(env, SM)
    equal(hud:DisplayMode(), "compact")
    env:dispatch("PLAYER_REGEN_DISABLED")
    equal(hud:DisplayMode(), "minimized", "collapses in combat")
    equal(hud.Mode(), "compact", "the saved mode is untouched")
    truthy(not hud.header.shown, "only the clock in combat")
    equal(addon.DungeonSessions.Current().timer.state, "running", "the first pull still starts the timer")
    hud.moreButton:GetScript("OnClick")()
    equal(hud:DisplayMode(), "compact", "the player can expand during combat")
    equal(hud.Mode(), "compact", "without changing the saved mode")
    env:dispatch("PLAYER_REGEN_ENABLED")
    equal(hud:DisplayMode(), "compact", "back to the preferred view after combat")
    hud:SetMode("expanded")
    env:dispatch("PLAYER_REGEN_DISABLED")
    equal(hud:DisplayMode(), "minimized")
    env:dispatch("PLAYER_REGEN_ENABLED")
    equal(hud:DisplayMode(), "expanded", "restores expanded")

    hud:SetCollapseInCombat(false)
    env:dispatch("PLAYER_REGEN_DISABLED")
    equal(hud:DisplayMode(), "expanded", "no collapse when turned off")
    hud:SetMode("compact")
    equal(hud.Mode(), "compact", "out of a collapse a pick is saved, even in combat")
    env:dispatch("PLAYER_REGEN_ENABLED")
    hud:SetCollapseInCombat(true)

    -- Manual hide during combat: stays hidden after combat, for this run.
    env:dispatch("PLAYER_REGEN_DISABLED")
    local runId = addon.DungeonSessions.Current().runId
    hud.closeButton:GetScript("OnClick")()
    truthy(not hud.visible, "hidden by the player in combat")
    env:dispatch("PLAYER_REGEN_ENABLED")
    truthy(not hud.visible, "still hidden after combat")
    truthy(hud.IsHiddenForRun(), "hidden for this run")
    equal(GuildweaverDB.ui.dungeonHud.enabled, true, "hiding is not disabling")
    env:advance(5)
    truthy(not hud.visible, "the clock tick does not bring it back")
    equal(addon.DungeonSessions.Current().runId, runId, "the run goes on")
    -- The timer keeps counting while hidden.
    local before = addon.DungeonSessions.Current().timerSeconds
    env.serverTime = env.serverTime + 30
    env:advance(30)
    truthy(addon.DungeonSessions.Current().timerSeconds >= before + 30, "timer runs while hidden")
    -- The dashboard brings it back.
    addon.MainFrame:Open("dungeon")
    local card = addon.MainFrame.views.dungeon.runCard
    equal(card.hud:GetLabel(), "Show HUD")
    click(card.hud)
    truthy(hud.visible, "Show HUD brings it back")

    -- Hidden again; a new run shows it again.
    hud:HideForRun()
    SlashCmdList.GUILDWEAVER("dungeon new")
    truthy(addon.DungeonSessions.Current().runId ~= runId, "a new run")
    truthy(hud.visible, "a new run shows the HUD again")

    -- Reload in combat: collapsed from the start.
    env:dispatch("PLAYER_REGEN_DISABLED")
    env.inCombat = true
    local env2, addon2 = relog(env)
    equal(addon2.DungeonHud:DisplayMode(), "minimized", "after a reload in combat it starts collapsed")
    env2:dispatch("PLAYER_REGEN_ENABLED")
    env2.inCombat = false
    equal(addon2.DungeonHud:DisplayMode(), "compact")
    equal(env.protectedCalls + env2.protectedCalls, 0, "no protected calls")
end

-- Timer controls and End run from the dashboard -------------------------------------------
do
    local env, addon = boot()
    local main, sessions = addon.MainFrame, addon.DungeonSessions
    zone(env, SM)
    main:Open("dungeon")
    local card = main.views.dungeon.runCard
    equal(card.timer:GetLabel(), "Start")
    click(card.timer)
    equal(sessions.TimerState(), "running")
    equal(card.timer:GetLabel(), "Pause")
    click(card.timer)
    equal(sessions.TimerState(), "stopped", "Pause stops the clock")
    truthy(sessions.Current(), "but the run stays open")
    equal(card.timer:GetLabel(), "Resume")
    click(card.split)
    equal(#sessions.Current().splits, 1, "Split from the dashboard")
    -- End run needs a second click.
    click(card.finish)
    truthy(sessions.Current(), "one click only arms End run")
    equal(card.finish:GetLabel(), "Click to end")
    env:advance(5)
    equal(card.finish:GetLabel(), "End run", "it disarms by itself")
    click(card.finish)
    click(card.finish)
    equal(sessions.Current(), nil, "two clicks end the run")
    equal(sessions.History()[1].status, "completed")
    equal(main.views.dungeon.recentRows[1].name.gwText, "Scarlet Monastery", "it is listed under recent runs")

    -- Objectives from the dashboard.
    local view = main.views.dungeon
    -- The fake client's edit box holds no text: give it some.
    view.objectiveInput.GetText = function() return "Kill Herod" end
    view.objectiveInput:GetScript("OnEnterPressed")(view.objectiveInput)
    equal(addon.DungeonObjectives.List()[1].text, "Kill Herod", "objective added")
    click(view.objectiveRows[1])
    equal(addon.DungeonObjectives.List()[1].done, true, "click marks it done")
    click(view.objectiveRows[1].remove)
    equal(#addon.DungeonObjectives.List(), 0, "removed")
end

-- Sync now: blocked in combat, otherwise asks twice, then reloads ------------------------
do
    local env, addon = boot()
    local main = addon.MainFrame
    main:Open("sync")
    local button = main.views.sync.card.sync
    env.inCombat = true
    main:RefreshView()
    truthy(not button:IsEnabled(), "disabled in combat")
    click(button)
    click(button)
    equal(env.reloads, 0, "no reload in combat")
    env.inCombat = false
    main:RefreshView()
    click(button)
    equal(env.reloads, 0, "the first click only asks")
    click(button)
    env:advance(2)
    equal(env.reloads, 1, "the second click syncs (a checkpoint, then the reload)")
end

-- Compact HUD rates: XP/hr left, Wallet/hr right, labelled, only when real -------
do
    local env, addon = boot()
    local hud, sessions = addon.DungeonHud, addon.DungeonSessions
    zone(env, SM)
    local xp, wallet = hud.Rates(sessions.Current())
    equal(xp, nil, "no XP/hr at entry")
    equal(wallet, nil, "no Wallet/hr at entry")
    truthy(not hud.ratesRow.shown, "no rates row yet")
    env.serverTime = env.serverTime + 600
    env:advance(600)
    world.xp = 4000
    env:dispatch("PLAYER_XP_UPDATE", "player")
    env.money = env.money + 50000
    env:dispatch("PLAYER_MONEY")
    local run = sessions.Current()
    xp, wallet = hud.Rates(run)
    truthy(xp and xp:find("%d"), "XP/hr after ten minutes: " .. tostring(xp))
    truthy(wallet and wallet:sub(1, 1) == "+", "Wallet/hr after ten minutes: " .. tostring(wallet))
    equal(hud.WalletPerHour(run), math.floor(50000 * 3600 / run.durationSeconds + 0.5), "wallet change per hour of the run")
    truthy(hud.ratesRow.shown, "the rates row shows in compact")
    truthy(hud.shown.xpRate:find("XP/hr", 1, true), "XP/hr labelled")
    truthy(hud.shown.walletRate:find("Wallet/hr", 1, true), "labelled wallet, never 'gold earned'")
    truthy(not hud.shown.walletRate:lower():find("earned", 1, true) and not hud.shown.walletRate:lower():find("profit", 1, true))
    -- Rate formatting.
    equal(hud.FormatRate(1234567), "+123g")
    equal(hud.FormatRate(43000), "+4g 30s")
    equal(hud.FormatRate(50000), "+5g")
    equal(hud.FormatRate(3500), "+35s")
    equal(hud.FormatRate(-80), "-80c")
    -- A wallet that has not moved gives no rate rather than "+0c".
    env.money = env.money - 50000
    env:dispatch("PLAYER_MONEY")
    equal(select(2, hud.Rates(sessions.Current())), nil, "no Wallet/hr while the wallet is back where it started")
    -- Minimal stays tiny: no boss frames, no rates.
    hud:SetMode("minimized")
    truthy(not hud.ratesRow.shown and not hud.bossRow.shown, "minimal shows only the clock")
    hud:SetMode("compact")
    -- Boss frames: a socket per boss ahead, no names invented.
    local tooltip = _G.GameTooltip
    local lines = {}
    tooltip.SetOwner = function() end
    tooltip.ClearLines = function() lines = {} end
    tooltip.AddLine = function(_, text) table.insert(lines, text) end
    hud.circles["pending:1"].frame:GetScript("OnEnter")()
    equal(lines[1], "Boss ahead", "an unknown boss is not named")
end

print("ui overhaul tests passed")
