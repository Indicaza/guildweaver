local _, GW = ...

-- The Guildweaver dashboard: a sidebar of modules and one view at a time.
--   Overview     what each module is doing, one card each
--   Dungeons     the dungeon journal (UI/DungeonGuide.lua): every dungeon,
--                its map, bosses, loot, quests and your runs, and the open
--                run's status
--   Farming      the timed farming run, this session's fishing
--   Sync & Data  what is waiting for the bridge, Sync now, and an Advanced
--                section for diagnostics
--   Settings     the minimap button, the dungeon HUD, the window
-- Guild Quests (QuestLog.lua) is built but not shown while QUESTS_ENABLED
-- is false; the quest system itself keeps running.
-- Built on first open, not at login. While open it updates live numbers
-- once a second; closed, it does nothing at all.
--
-- The window is resizable (the grip in its bottom-right corner): 1050 x 700
-- by default, never smaller than 740 x 500 or larger than the screen, the
-- size saved with the dashboard's preferences. Views lay themselves out for
-- the content area's size: a view may give a layout(view, width, height)
-- that runs once when it is built and again after each resize (out of
-- combat), never while the grip is being dragged.
GW.MainFrame = GW.MainFrame or {}

local Globals = _G or {}
local Main = GW.MainFrame
local UI, Theme, Prefs = GW.UI, GW.Theme, GW.UiPrefs

local WIDTH, HEIGHT = 1050, 700
local MIN_WIDTH, MIN_HEIGHT = 740, 500
local HEADER = 44
local SIDEBAR = 168
local PAD = 20
-- The narrowest content area: what the fixed parts of the views are built for.
local CONTENT_WIDTH = MIN_WIDTH - SIDEBAR - PAD * 2
Main.DEFAULT_SIZE = { WIDTH, HEIGHT }
Main.MIN_SIZE = { MIN_WIDTH, MIN_HEIGHT }
-- Every dashboard button is this tall; widths come in two sizes.
local BUTTON_HEIGHT = 22
local BUTTON_WIDE, BUTTON_NARROW = 124, 88
local DOT = "\194\183"

-- The first guild-facing release leaves Guild Quests out of the window.
Main.QUESTS_ENABLED = false

local NAV = {
    { key = "overview", label = "Overview" },
    { key = "dungeon", label = "Dungeons" },
    { key = "farming", label = "Farming" },
    { key = "quests", label = "Guild Quests", enabled = function() return Main.QUESTS_ENABLED end },
    { key = "sync", label = "Sync & Data" },
}

local function visibleNav()
    local list = {}
    for _, entry in ipairs(NAV) do
        if not entry.enabled or entry.enabled() then table.insert(list, entry) end
    end
    return list
end
Main.NAV = visibleNav()

local Views = {}
Main.Views = Views
-- Old view keys that now open another view.
local ALIASES = { guide = "dungeon" }

local function hud() return GW.DungeonHud end
local function sessions() return GW.DungeonSessions end
local function duration(seconds) return GW.DungeonHud.FormatDuration(seconds) end

local function inCombat()
    if type(Globals.InCombatLockdown) ~= "function" then return false end
    local ok, value = pcall(Globals.InCombatLockdown)
    return ok and value == true
end

local function clockTime(timestamp)
    timestamp = tonumber(timestamp)
    if not timestamp or type(Globals.date) ~= "function" then return nil end
    local ok, text = pcall(Globals.date, "%H:%M", timestamp)
    return ok and text or nil
end

local function shortDate(timestamp)
    timestamp = tonumber(timestamp)
    if not timestamp or timestamp <= 0 or type(Globals.date) ~= "function" then return nil end
    local ok, text = pcall(Globals.date, "%b %d", timestamp)
    return ok and text or nil
end

Main.ShortDate = shortDate

local function stateColor(state)
    return state == "paused" and "warn" or (state == "ready" and "textMuted" or (state == "cleared" and "gold" or "text"))
end
Main.StateColor = stateColor

-- A page title, and an optional one-line note under it. Returns the y
-- offset where the view's content starts.
local function pageHeader(view, title, subtitle)
    view.title = UI.Text(view, "pageTitle", "goldBright")
    view.title:SetPoint("TOPLEFT", view, "TOPLEFT", 0, 0)
    view.title:SetText(title)
    if not subtitle then
        return -34
    end
    view.subtitle = UI.Text(view, "label", "textMuted")
    view.subtitle:SetPoint("TOPLEFT", view.title, "BOTTOMLEFT", 0, -6)
    view.subtitle:SetPoint("RIGHT", view, "RIGHT", 0, 0)
    pcall(view.subtitle.SetWordWrap, view.subtitle, false)
    view.subtitle:SetText(subtitle)
    return -52
end

local function paragraph(parent, role, color, width)
    local text = UI.Text(parent, role or "label", color or "textMuted")
    text:SetWidth(width or CONTENT_WIDTH)
    pcall(text.SetWordWrap, text, true)
    pcall(text.SetJustifyV, text, "TOP")
    return text
end

-- Farming ---------------------------------------------------------------------------

function Main:ToggleFarming()
    local farming = GW.FarmingSessions
    local context = farming.Context()
    if context and context.mode == "manual" then
        farming.Stop()
        GW.Print("Farming run saved. It reaches the website after /reload or logout.")
    elseif farming.Start() then
        GW.Print("Farming timer started. Travel and waiting count.")
    else
        GW.Print("Character data is not ready yet.")
    end
    self:RefreshView()
end

local function farmingLabel()
    local context = GW.FarmingSessions.Context()
    return context and context.mode == "manual" and "Stop & save" or "Start timed run"
end

local function gathers(count)
    return count .. (count == 1 and " gather" or " gathers")
end

-- Recent runs ------------------------------------------------------------------------

-- How a finished run ended, in a word or two, and its colour. Only boss
-- evidence earns "Cleared"; the player's own word is labelled as such.
local function outcome(entry)
    local status, basis = entry.status, entry.completionBasis
    if entry.classification then
        local label = GW.DungeonHud.ClassLabel({ kind = entry.classification, verification = entry.verification })
        local good = entry.classification ~= "partial" and entry.verification ~= "manual" and entry.verification ~= "unconfirmed"
        return label, good and "good" or (entry.verification == "unconfirmed" and "gold" or "text")
    end
    -- Runs recorded before classification: from their stored evidence.
    if status == "completed" then
        if basis == "lockout" or basis == "encounters" then return "100% clear", "good" end
        if basis == "final_boss" then return "Dungeon clear", "good" end
        if basis == "final_boss_unconfirmed" then return "Dungeon clear (unverified)", "gold" end
        if basis == "manual" then return "Finished by you", "text" end
        return "Completed", "text"
    elseif status == "abandoned" or status == "interrupted" then
        return "Partial", "text"
    end
    return tostring(status or ""), "textFaint"
end
Main.Outcome = outcome

-- Runs worth a line in the quick list: not the zero-length interrupted or
-- abandoned stubs a disconnect leaves. History itself keeps them.
local function listedRuns(history, max)
    local list = {}
    for _, entry in ipairs(history) do
        local empty = (entry.status == "interrupted" or entry.status == "abandoned")
            and (tonumber(entry.timerSeconds) or 0) == 0 and (tonumber(entry.bossesDefeated) or 0) == 0
        if not empty then
            table.insert(list, entry)
            if #list >= max then break end
        end
    end
    return list
end
Main.ListedRuns = listedRuns

-- Overview ---------------------------------------------------------------------------

local function dungeonSummary()
    local run = sessions().Current()
    if run then
        local state = hud().DisplayState(run)
        local detail = hud().StateText(run)
        if run.bossesTotal or (run.bossesDefeated or 0) > 0 then
            detail = "Bosses " .. run.bossesDefeated .. (run.bossesTotal and ("/" .. run.bossesTotal) or "") .. "  " .. Theme.Colorize(DOT, "textFaint") .. "  " .. detail
        end
        return run.name, hud().ClockText(run), state, detail
    end
    local last = listedRuns(sessions().History(), 1)[1]
    if last then
        local word = outcome(last)
        return "No run open", nil, nil, "Last: " .. tostring(last.name or "Instance") .. "  " .. Theme.Colorize(DOT, "textFaint") .. "  "
            .. duration(last.timerSeconds or last.durationSeconds) .. "  " .. Theme.Colorize(DOT, "textFaint") .. "  " .. word
    end
    return "No run open", nil, nil, "Tracking starts when you enter a dungeon or raid."
end

Views.overview = {
    build = function(view)
        local ok, name = pcall(Globals.UnitName, "player")
        name = ok and type(name) == "string" and name or nil
        local top = pageHeader(view, name and ("Welcome back, " .. name) or "Welcome back")
        local cardWidth, cardHeight = (CONTENT_WIDTH - 12) / 2, 128
        view.cards = {}
        local function card(key, heading, width, height)
            local frame = UI.Card(view, function() Main:Select(key) end)
            frame:SetSize(width, height)
            frame.heading = UI.Text(frame, "heading", "gold")
            frame.heading:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -14)
            frame.heading:SetText(string.upper(heading))
            frame.more = UI.Text(frame, "small", "textFaint", "RIGHT")
            frame.more:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -16, -14)
            frame.more:SetText("Open \226\128\186")
            frame.main = UI.Text(frame, "title", "text")
            frame.main:SetPoint("TOPLEFT", frame.heading, "BOTTOMLEFT", 0, -14)
            frame.main:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
            pcall(frame.main.SetWordWrap, frame.main, false)
            frame.value = UI.Text(frame, "clockMid", "text", "RIGHT")
            frame.value:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -16, -38)
            frame.detail = UI.Text(frame, "small", "textMuted")
            frame.detail:SetPoint("TOPLEFT", frame.main, "BOTTOMLEFT", 0, -8)
            frame.detail:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
            pcall(frame.detail.SetWordWrap, frame.detail, false)
            view.cards[key] = frame
            return frame
        end
        local dungeon = card("dungeon", "Dungeons", cardWidth, cardHeight)
        dungeon:SetPoint("TOPLEFT", view, "TOPLEFT", 0, top)
        local farming = card("farming", "Farming", cardWidth, cardHeight)
        farming:SetPoint("TOPLEFT", dungeon, "TOPRIGHT", 12, 0)
        farming.button = UI.Button(farming, farmingLabel(), { width = BUTTON_WIDE, height = BUTTON_HEIGHT, variant = "primary",
            onClick = function() Main:ToggleFarming() end })
        farming.button:SetPoint("BOTTOMLEFT", farming, "BOTTOMLEFT", 16, 14)
        -- Sync & Data: one line across the bottom of the overview.
        local sync = card("sync", "Sync & Data", CONTENT_WIDTH, 74)
        sync:SetPoint("TOPLEFT", dungeon, "BOTTOMLEFT", 0, -12)
        sync.main:ClearAllPoints()
        sync.main:SetPoint("TOPLEFT", sync.heading, "BOTTOMLEFT", 15, -12)
        sync.dot = UI.Dot(sync, 8)
        sync.dot:SetPoint("RIGHT", sync.main, "LEFT", -7, 0)
        sync.dot:SetStatus("good")
        sync.detail:ClearAllPoints()
        sync.detail:SetPoint("LEFT", sync.main, "RIGHT", 14, -1)
        sync.detail:SetPoint("RIGHT", sync, "RIGHT", -16, 0)
        if Main.QUESTS_ENABLED then
            local quests = card("quests", "Guild Quests", CONTENT_WIDTH, 74)
            quests:SetPoint("TOPLEFT", sync, "BOTTOMLEFT", 0, -12)
        end
    end,
    layout = function(view, width)
        local half = (width - 12) / 2
        view.cards.dungeon:SetWidth(half)
        view.cards.farming:SetWidth(half)
        view.cards.sync:SetWidth(width)
        if view.cards.quests then view.cards.quests:SetWidth(width) end
    end,
    refresh = function(view)
        local cards = view.cards
        local title, clock, state, detail = dungeonSummary()
        UI.SetText(cards.dungeon.main, title)
        UI.SetText(cards.dungeon.value, clock or "")
        Theme.Tint(cards.dungeon.value, stateColor(state))
        UI.SetText(cards.dungeon.detail, detail)

        local status = GW.FarmingSessions.Status()
        local measuring = status and status.mode == "manual"
        UI.SetText(cards.farming.main, measuring and "Timing a run" or "Not timing")
        UI.SetText(cards.farming.value, measuring and duration(status.durationSeconds) or "")
        UI.SetText(cards.farming.detail, (status and status.gatheringCount > 0) and (gathers(status.gatheringCount) .. (measuring and " so far" or " in the current estimate"))
            or (measuring and "Gather something to count it." or "Time a run for exact hours."))
        cards.farming.button:SetLabel(farmingLabel())
        cards.farming.button:SetVariant(measuring and "secondary" or "primary")

        UI.SetText(cards.sync.main, "Collecting")
        local waiting = GW.Store.GetTelemetryStatus().count
        UI.SetText(cards.sync.detail, waiting == 0 and "Everything has reached the bridge."
            or (waiting .. (waiting == 1 and " update goes" or " updates go") .. " out on your next /reload or logout."))
    end,
    tick = function(view)
        local run = sessions().Current()
        if run then UI.SetText(view.cards.dungeon.value, hud().ClockText(run)) end
        local status = GW.FarmingSessions.Status()
        if status and status.mode == "manual" then UI.SetText(view.cards.farming.value, duration(status.durationSeconds)) end
    end,
}

-- Farming ----------------------------------------------------------------------------

Views.farming = {
    build = function(view)
        local top = pageHeader(view, "Farming", "Gathering is grouped into runs automatically. Time a run for exact hours.")
        local card = UI.Card(view)
        card:SetPoint("TOPLEFT", view, "TOPLEFT", 0, top)
        card:SetSize(CONTENT_WIDTH, 116)
        view.card = card
        card.state = UI.Text(card, "title", "gold")
        card.state:SetPoint("TOPLEFT", card, "TOPLEFT", 16, -14)
        card.clock = UI.Text(card, "clock", "text")
        card.clock:SetPoint("TOPLEFT", card.state, "BOTTOMLEFT", 0, -10)
        card.detail = UI.Text(card, "label", "textMuted")
        card.detail:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 16, 14)
        card.detail:SetPoint("RIGHT", card, "RIGHT", -16, 0)
        pcall(card.detail.SetWordWrap, card.detail, false)
        card.button = UI.Button(card, farmingLabel(), { width = BUTTON_WIDE, height = BUTTON_HEIGHT, variant = "primary",
            tooltip = "Timed run", tooltipLines = { "Travel, combat and waiting count; AFK time is noted apart. A /reload or logout ends the run." },
            onClick = function() Main:ToggleFarming() end })
        card.button:SetPoint("TOPRIGHT", card, "TOPRIGHT", -16, -14)

        local fishing = UI.SectionHeader(view, "Fishing this session")
        fishing:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -20)
        fishing:SetWidth(CONTENT_WIDTH)
        view.fishingStats = {}
        local labels = { "Casts", "Catches", "From pools" }
        for index, label in ipairs(labels) do
            local stat = UI.Stat(view, label, 120)
            stat:SetPoint("TOPLEFT", fishing, "BOTTOMLEFT", (index - 1) * 132, -12)
            view.fishingStats[index] = stat
        end
        view.lastCatch = UI.Text(view, "label", "textMuted")
        view.lastCatch:SetPoint("TOPLEFT", fishing, "BOTTOMLEFT", 0, -58)
        view.lastCatch:SetPoint("RIGHT", view, "RIGHT", 0, 0)
        pcall(view.lastCatch.SetWordWrap, view.lastCatch, false)
        view.fishingEmpty = UI.Text(view, "label", "textFaint")
        view.fishingEmpty:SetPoint("TOPLEFT", fishing, "BOTTOMLEFT", 0, -10)
        view.fishingEmpty:SetText("No fishing yet this session.")
    end,
    layout = function(view, width)
        view.card:SetWidth(width)
    end,
    refresh = function(view)
        local card = view.card
        local status = GW.FarmingSessions.Status()
        local measuring = status and status.mode == "manual"
        UI.SetText(card.state, measuring and "Timing a run" or (status and "Estimating from your gathering" or "Not timing"))
        -- No "0:00" when nothing is being timed.
        UI.SetText(card.clock, status and duration(status.durationSeconds) or "")
        Theme.Tint(card.clock, measuring and "text" or "textMuted")
        local detail
        if status then
            local parts = { gathers(status.gatheringCount) }
            if status.afkSeconds and status.afkSeconds > 0 then table.insert(parts, "AFK " .. duration(status.afkSeconds)) end
            if not measuring then table.insert(parts, "estimated: first to last harvest") end
            detail = table.concat(parts, "  " .. Theme.Colorize(DOT, "textFaint") .. "  ")
        else
            detail = "Herbs, ore, skins and fish are grouped into runs on their own."
        end
        UI.SetText(card.detail, detail)
        card.button:SetLabel(farmingLabel())
        card.button:SetVariant(measuring and "secondary" or "primary")

        local stats = GW.FishingCapture and GW.FishingCapture.Stats and GW.FishingCapture.Stats() or {}
        local fished = (stats.casts or 0) > 0 or (stats.catches or 0) > 0
        view.fishingStats[1]:SetValue(tostring(stats.casts or 0))
        view.fishingStats[2]:SetValue(tostring(stats.catches or 0))
        view.fishingStats[3]:SetValue(tostring(stats.poolCatches or 0))
        for _, stat in ipairs(view.fishingStats) do UI.SetShown(stat, fished) end
        UI.SetShown(view.fishingEmpty, not fished)
        local last = stats.last
        if last then
            local place = tostring(last.zone or "unknown zone") .. (last.subzone and (" - " .. tostring(last.subzone)) or "")
            UI.SetText(view.lastCatch, "Last catch: " .. tostring(last.sourceName or "open water") .. ", " .. place)
        else
            UI.SetText(view.lastCatch, "")
        end
    end,
    tick = function(view)
        local status = GW.FarmingSessions.Status()
        if status then UI.SetText(view.card.clock, duration(status.durationSeconds)) end
    end,
}

-- Guild Quests (hidden while QUESTS_ENABLED is false) ------------------------------

Views.quests = {
    build = function(view)
        local top = pageHeader(view, "Guild Quests", "Quests your guild posts on its website. Join an objective to take it on.")
        local holder = UI.CreateFrame("Frame", view)
        holder:SetPoint("TOPLEFT", view, "TOPLEFT", 0, top + 2)
        holder:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", 0, 0)
        GW.QuestLog:Initialize(holder)
    end,
    refresh = function()
        GW.QuestLog:Refresh()
    end,
    enabled = function() return Main.QUESTS_ENABLED end,
}

-- Sync & Data ------------------------------------------------------------------------

local ADVANCED = {
    { "Telemetry streams", "telemetry", "Every stream waiting for the bridge, with its revision." },
    { "Performance", "perf", "Capture timings and work-queue state for this session." },
    { "Reset counters", "perf reset", "Clears the performance counters." },
    { "Character", "snapshot", "Captures and prints a character snapshot." },
    { "Inventory", "inventory", "Rescans your bags and prints the inventory revision." },
    { "Fishing", "fishing", "Casts and catches recorded this session." },
}

Views.sync = {
    build = function(view)
        view.showAdvanced = false
        local top = pageHeader(view, "Sync & Data")
        local card = UI.Card(view)
        card:SetPoint("TOPLEFT", view, "TOPLEFT", 0, top)
        card:SetSize(CONTENT_WIDTH, 112)
        view.card = card
        card.dot = UI.Dot(card, 9)
        card.dot:SetPoint("TOPLEFT", card, "TOPLEFT", 16, -19)
        card.dot:SetStatus("good")
        card.state = UI.Text(card, "title", "text")
        card.state:SetPoint("LEFT", card.dot, "RIGHT", 8, 0)
        card.state:SetText("Collecting automatically")
        card.lines = {}
        for index = 1, 2 do
            local line = UI.Text(card, "label", "textMuted")
            line:SetPoint("TOPLEFT", card, "TOPLEFT", 16, -42 - (index - 1) * 19)
            line:SetPoint("RIGHT", card, "RIGHT", -(BUTTON_WIDE + 32), 0)
            pcall(line.SetWordWrap, line, false)
            card.lines[index] = line
        end
        card.sync = UI.ConfirmButton(card, "Sync now", "Reload to sync", { width = BUTTON_WIDE, height = BUTTON_HEIGHT, variant = "primary",
            tooltip = "Sync now", tooltipLines = { "Saves a checkpoint and reloads your interface so WoW writes it to disk for the bridge.",
                "A timed farming run ends; an open dungeon run continues." },
            onClick = function()
                if inCombat() then
                    GW.Print("Sync after combat: reloading is not allowed while you fight.")
                    return
                end
                if not GW.SessionCapture.CaptureAndReload("MANUAL_CHECKPOINT") then
                    GW.Print("Telemetry checkpoint unavailable.")
                end
            end })
        card.sync:SetPoint("TOPRIGHT", card, "TOPRIGHT", -16, -14)
        card.note = UI.Text(card, "small", "textFaint")
        card.note:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 16, 12)
        card.note:SetText("WoW saves addon data on /reload or logout; the bridge sends it from there.")

        local advanced = UI.SectionHeader(view, "Advanced")
        advanced:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -20)
        advanced:SetWidth(CONTENT_WIDTH)
        view.advancedToggle = UI.Button(view, "Show", { width = BUTTON_NARROW / 2 + 16, height = BUTTON_HEIGHT, variant = "ghost", onClick = function()
            view.showAdvanced = not view.showAdvanced
            Main:RefreshView()
        end })
        view.advancedToggle:SetPoint("TOPRIGHT", card, "BOTTOMRIGHT", 0, -16)
        view.advancedNote = UI.Text(view, "small", "textFaint")
        view.advancedNote:SetPoint("TOPLEFT", advanced, "BOTTOMLEFT", 0, -10)
        view.advancedNote:SetText("Diagnostics print to chat. Nothing here changes what is collected.")
        view.advancedButtons = {}
        local buttonWidth = (CONTENT_WIDTH - 20) / 3
        for index, entry in ipairs(ADVANCED) do
            local button = UI.Button(view, entry[1], { width = buttonWidth, height = BUTTON_HEIGHT, tooltip = entry[1], tooltipLines = { entry[3] },
                onClick = function() Globals.SlashCmdList.GUILDWEAVER(entry[2]) end })
            button:SetPoint("TOPLEFT", advanced, "BOTTOMLEFT", ((index - 1) % 3) * (buttonWidth + 10), -32 - math.floor((index - 1) / 3) * (BUTTON_HEIGHT + 8))
            view.advancedButtons[index] = button
        end
    end,
    layout = function(view, width)
        view.card:SetWidth(width)
    end,
    refresh = function(view)
        local card = view.card
        local status = GW.Store.GetTelemetryStatus()
        UI.SetText(card.lines[1], status.count == 0 and "Everything has reached the bridge."
            or (status.count .. (status.count == 1 and " update waits" or " updates wait") .. " for the next save."))
        local _, startedAt = GW.Store.GetCaptureSession()
        local started = clockTime(startedAt)
        UI.SetText(card.lines[2], started and ("Recording since " .. started .. ".") or "Recording this session.")
        card.sync:SetEnabled(not inCombat())
        view.advancedToggle:SetLabel(view.showAdvanced and "Hide" or "Show")
        UI.SetShown(view.advancedNote, view.showAdvanced)
        for _, button in ipairs(view.advancedButtons) do
            UI.SetShown(button, view.showAdvanced)
        end
    end,
}

-- Settings ---------------------------------------------------------------------------

local MODE_CHOICES = { { "minimized", "Minimal" }, { "compact", "Compact" }, { "expanded", "Detailed" } }
local SCALE_CHOICES = { { 0.85, "S" }, { 1, "M" }, { 1.15, "L" }, { 1.3, "XL" } }
-- Estimated auction value (copper) a Bind-on-Equip item needs for a gold alert.
local BOE_CHOICES = { { 50000, "5g" }, { 100000, "10g" }, { 250000, "25g" }, { 500000, "50g" }, { 1000000, "100g" } }

Views.settings = {
    build = function(view)
        local top = pageHeader(view, "Settings", "None of these settings stop data collection.")
        local columnWidth = (CONTENT_WIDTH - 28) / 2
        local tracker = hud()
        view.controls = {}
        local function add(control)
            table.insert(view.controls, control)
            return control
        end

        -- Left column: general, then data collection.
        local general = UI.SectionHeader(view, "General")
        general:SetPoint("TOPLEFT", view, "TOPLEFT", 0, top - 4)
        general:SetWidth(columnWidth)
        local minimap = add(UI.Toggle(view, "Minimap button", "Click to open, right-click for actions",
            function() return not Prefs.MinimapHidden() end,
            function(value) Prefs.SetMinimapHidden(not value) end, columnWidth))
        minimap:SetPoint("TOPLEFT", general, "BOTTOMLEFT", 0, -12)
        view.minimapToggle = minimap
        local reset = UI.Button(view, "Reset window", { width = BUTTON_WIDE + 36, height = BUTTON_HEIGHT,
            tooltip = "Reset window", tooltipLines = { "Centres the window and gives it its default size." },
            onClick = function() Main:ResetPosition() end })
        reset:SetPoint("TOPLEFT", minimap, "BOTTOMLEFT", 0, -10)

        local data = UI.SectionHeader(view, "Data collection")
        data:SetPoint("TOPLEFT", reset, "BOTTOMLEFT", 0, -24)
        data:SetWidth(columnWidth)
        local dot = UI.Dot(view, 8)
        dot:SetPoint("TOPLEFT", data, "BOTTOMLEFT", 0, -16)
        dot:SetStatus("good")
        local always = UI.Text(view, "label", "text")
        always:SetPoint("LEFT", dot, "RIGHT", 8, 0)
        always:SetText("Always on")
        local explain = paragraph(view, "small", "textMuted", columnWidth)
        explain:SetPoint("TOPLEFT", dot, "BOTTOMLEFT", 0, -10)
        explain:SetText("Hiding the HUD or this window never pauses recording, so your guild's records stay complete.")

        -- Right column: the dungeon HUD.
        local hudHeader = UI.SectionHeader(view, "Dungeon HUD")
        hudHeader:SetPoint("TOPLEFT", view, "TOPLEFT", columnWidth + 28, top - 4)
        hudHeader:SetWidth(columnWidth)
        local enabled = add(UI.Toggle(view, "Show in dungeons", "Runs are recorded even when hidden",
            function() return tracker.IsEnabled() end,
            function(value) if value then tracker:ShowNow() else tracker:SetEnabled(false) end end, columnWidth))
        enabled:SetPoint("TOPLEFT", hudHeader, "BOTTOMLEFT", 0, -12)
        view.hudToggle = enabled
        local collapse = add(UI.Toggle(view, "Collapse in combat", "Shrinks to the timer while you fight",
            function() return tracker.CollapsesInCombat() end,
            function(value) tracker:SetCollapseInCombat(value) end, columnWidth))
        collapse:SetPoint("TOPLEFT", enabled, "BOTTOMLEFT", 0, -8)
        view.collapseToggle = collapse
        local lock = add(UI.Toggle(view, "Lock position", nil,
            function() return tracker.IsLocked() end,
            function(value) tracker:SetLocked(value) end, columnWidth))
        lock:SetPoint("TOPLEFT", collapse, "BOTTOMLEFT", 0, -8)
        view.lockToggle = lock
        local mode = add(UI.SettingRow(view, "View", nil, UI.Segmented(view, MODE_CHOICES,
            function() return tracker.Mode() end,
            function(value) tracker:SetMode(value) end, { segmentWidth = 58, height = BUTTON_HEIGHT }), columnWidth))
        mode:SetPoint("TOPLEFT", lock, "BOTTOMLEFT", 0, -10)
        view.modeChoice = mode.control
        local scale = add(UI.SettingRow(view, "Size", nil, UI.Segmented(view, SCALE_CHOICES,
            function() return tracker.Scale() end,
            function(value) tracker:SetScale(value) end, { segmentWidth = 36, height = BUTTON_HEIGHT }), columnWidth))
        scale:SetPoint("TOPLEFT", mode, "BOTTOMLEFT", 0, -10)
        view.scaleChoice = scale.control
        local resetHud = UI.Button(view, "Reset HUD position", { width = BUTTON_WIDE + 16, height = BUTTON_HEIGHT, onClick = function()
            tracker:ResetPosition()
            Main:RefreshView()
        end })
        resetHud:SetPoint("TOPLEFT", scale, "BOTTOMLEFT", 0, -14)

        -- Loot alerts, across the bottom: what glows in Need/Greed rolls.
        -- Laid out upwards from the bottom edge so it always fits.
        local alerts = GW.LootAlerts
        local function lootPref(key)
            return function() return alerts.Prefs()[key] ~= false end, function(value) alerts.Prefs()[key] = value == true end
        end
        local right = columnWidth + 28
        local sound = add(UI.Toggle(view, "Chime", nil, lootPref("sound")))
        sound:SetWidth(columnWidth)
        sound:SetPoint("BOTTOMLEFT", view, "BOTTOMLEFT", 0, 0)
        local threshold = add(UI.SettingRow(view, "BoE from", nil, UI.Segmented(view, BOE_CHOICES,
            function() return alerts.Threshold() end,
            function(value) alerts.Prefs().boeThreshold = value end, { segmentWidth = 36, height = BUTTON_HEIGHT }), columnWidth))
        threshold:SetPoint("BOTTOMLEFT", view, "BOTTOMLEFT", right, 0)
        local wishlist = add(UI.Toggle(view, "Wishlist items (purple)", nil, lootPref("wishlist")))
        wishlist:SetWidth(columnWidth)
        wishlist:SetPoint("BOTTOMLEFT", sound, "TOPLEFT", 0, 6)
        local boe = add(UI.Toggle(view, "Valuable BoE items (gold)", nil, lootPref("boe")))
        boe:SetWidth(columnWidth)
        boe:SetPoint("BOTTOMLEFT", threshold, "TOPLEFT", 0, 6)
        local loot = UI.SectionHeader(view, "Loot alerts")
        loot:SetPoint("BOTTOMLEFT", wishlist, "TOPLEFT", 0, 10)
        loot:SetWidth(CONTENT_WIDTH)
        view.lootSoundToggle, view.lootWishlistToggle, view.lootBoeToggle, view.lootThreshold = sound, wishlist, boe, threshold.control
    end,
    refresh = function(view)
        for _, control in ipairs(view.controls) do
            if control.Refresh then control:Refresh() end
        end
    end,
}

-- Window -----------------------------------------------------------------------------

local function navButton(parent, entry, index)
    local button = UI.CreateFrame("Button", parent)
    button:SetHeight(30)
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -14 - (index - 1) * 32)
    button:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
    button.bg = button:CreateTexture(nil, "BACKGROUND")
    button.bg:SetAllPoints(button)
    Theme.Fill(button.bg, "bgActive")
    button.bg:Hide()
    button.bar = button:CreateTexture(nil, "ARTWORK")
    button.bar:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    button.bar:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
    button.bar:SetWidth(2)
    Theme.Fill(button.bar, "gold")
    button.bar:Hide()
    button.label = UI.Text(button, "label", "textMuted")
    button.label:SetPoint("LEFT", button, "LEFT", 18, 0)
    button.label:SetText(entry.label)
    button.key = entry.key
    pcall(button.RegisterForClicks, button, "LeftButtonUp")
    button:SetScript("OnClick", function() Main:Select(entry.key, "nav") end)
    button:SetScript("OnEnter", function(self)
        if Main.current ~= self.key then
            self.bg:Show()
            Theme.Fill(self.bg, "bgHover")
            Theme.Tint(self.label, "text")
        end
    end)
    button:SetScript("OnLeave", function(self)
        if Main.current ~= self.key then
            self.bg:Hide()
            Theme.Tint(self.label, "textMuted")
        end
    end)
    function button:SetSelected(selected)
        Theme.Fill(self.bg, "bgActive")
        UI.SetShown(self.bg, selected)
        UI.SetShown(self.bar, selected)
        Theme.Tint(self.label, selected and "goldBright" or "textMuted")
    end
    return button
end

-- Nothing is built at login: the window is made on first open.
function Main:Initialize()
    return self.frame
end

function Main:Build()
    if self.frame or type(Globals.CreateFrame) ~= "function" then
        return self.frame
    end
    local frame = UI.Window({
        name = "GuildweaverMainFrame", width = WIDTH, height = HEIGHT, headerHeight = HEADER, title = "Guildweaver",
        resizable = true, minWidth = MIN_WIDTH, minHeight = MIN_HEIGHT,
        getPosition = function() return GW.Store.GetMainFramePosition() end,
        savePosition = function(point, relativePoint, x, y) GW.Store.SetMainFramePosition(point, relativePoint, x, y) end,
        getSize = function() return Prefs.WindowSize() end,
        saveSize = function(width, height) Prefs.SetWindowSize(width, height) end,
        onResized = function() Main:Relayout() end,
        onSizeChanged = function() Main:ScheduleRelayout() end,
    })
    self.frame = frame
    local version = UI.Text(frame.header, "small", "textFaint")
    version:SetPoint("LEFT", frame.title, "RIGHT", 8, -1)
    version:SetText("v" .. tostring(GW.version or ""))

    local sidebar = UI.CreateFrame("Frame", frame)
    sidebar:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -(HEADER + 1))
    sidebar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 1, 1)
    sidebar:SetWidth(SIDEBAR)
    local sidebarBg = sidebar:CreateTexture(nil, "BACKGROUND", nil, -7)
    sidebarBg:SetAllPoints(sidebar)
    Theme.Fill(sidebarBg, "bgInset")
    self.sidebarGrain = Theme.Grain(sidebar, SIDEBAR, select(2, frame:Size()) - HEADER, 0.05, 0)
    local divider = sidebar:CreateTexture(nil, "BORDER")
    divider:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", 0, 0)
    divider:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT", 0, 0)
    divider:SetWidth(1)
    Theme.Fill(divider, "border")
    self.nav = {}
    for index, entry in ipairs(visibleNav()) do
        self.nav[entry.key] = navButton(sidebar, entry, index)
    end
    self.nav.settings = navButton(sidebar, { key = "settings", label = "Settings" }, 1)
    self.nav.settings:ClearAllPoints()
    self.nav.settings:SetPoint("BOTTOMLEFT", sidebar, "BOTTOMLEFT", 0, 40)
    self.nav.settings:SetPoint("RIGHT", sidebar, "RIGHT", 0, 0)
    local statusDot = UI.Dot(sidebar, 7)
    statusDot:SetPoint("BOTTOMLEFT", sidebar, "BOTTOMLEFT", 18, 18)
    statusDot:SetStatus("good")
    local status = UI.Text(sidebar, "small", "textMuted")
    status:SetPoint("LEFT", statusDot, "RIGHT", 7, 0)
    status:SetText("Collecting data")
    self.sidebar = sidebar

    local content = UI.CreateFrame("Frame", frame)
    content:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", PAD, -18)
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, PAD)
    self.content = content
    self.views = {}

    frame:SetScript("OnShow", function()
        Main:RefreshView()
        Main:StartTicker()
    end)
    frame:SetScript("OnHide", function()
        Main:StopTicker()
        UI.HideMenu()
    end)
    -- A resize that ends in combat lays the views out when combat ends.
    local events = UI.CreateFrame("Frame", frame)
    events:RegisterEvent("PLAYER_REGEN_ENABLED")
    events:SetScript("OnEvent", function()
        if Main.relayoutPending then Main:Relayout() end
    end)
    self.events = events
    return frame
end

-- The content area's size: the window's, less the header, sidebar and padding.
function Main:ContentSize()
    local width, height = WIDTH, HEIGHT
    if self.frame and self.frame.Size then width, height = self.frame:Size() end
    return width - SIDEBAR - 1 - PAD * 2, height - HEADER - 1 - 18 - PAD
end

local function layoutView(key, view)
    local spec = Views[key]
    if spec and spec.layout and view then
        local width, height = Main:ContentSize()
        spec.layout(view, width, height)
        view.gwLaidOut = width .. "x" .. height
    end
end

-- After a size change: every built view lays itself out again (the shown
-- one now, the others when next shown). Never in combat: then once combat
-- ends. light (while the grip is dragged): only sizes and positions (a
-- view's reflow), no repaint; the end of the drag repaints.
function Main:Relayout(light)
    if not self.frame then return end
    if inCombat() then
        self.relayoutPending = true
        return
    end
    self.relayoutPending = nil
    local _, height = self.frame:Size()
    pcall(self.sidebarGrain.SetTexCoord, self.sidebarGrain, 0, SIDEBAR / Theme.GRAIN_SIZE, 0, (height - HEADER) / Theme.GRAIN_SIZE)
    local width, contentHeight = self:ContentSize()
    local size = width .. "x" .. contentHeight
    for key, view in pairs(self.views or {}) do
        if view:IsShown() or key == self.current then
            if not light or view.gwLaidOut ~= size then
                layoutView(key, view)
                local spec = Views[key]
                if light and spec and spec.reflow then spec.reflow(view) end
            end
        end
        if view.gwLaidOut ~= size then view.gwLayoutStale = true end
    end
    if not light then self:RefreshView() end
end

-- The window's size changed (a drag in progress, a clamp, the client): one
-- light layout soon, however many changes come in meanwhile.
function Main:ScheduleRelayout()
    if not self.frame or not self.views then return end
    local timer = Globals.C_Timer
    if not (timer and type(timer.After) == "function") then
        self:Relayout(true)
        return
    end
    if self.relayoutScheduled then return end
    self.relayoutScheduled = true
    timer.After(0.05, function()
        Main.relayoutScheduled = nil
        Main:Relayout(true)
    end)
end

-- Sets the window's size (as a drag of the grip would).
function Main:Resize(width, height)
    local frame = self:Build()
    if frame and frame.Resize then return frame:Resize(width, height) end
end

-- A view the window may show: hidden modules fall back to the overview.
local function available(key)
    local spec = Views[key]
    return spec ~= nil and (not spec.enabled or spec.enabled())
end

function Main:View(key)
    local spec = Views[key]
    if not spec then return nil end
    local view = self.views[key]
    if not view then
        view = UI.CreateFrame("Frame", self.content)
        view:SetAllPoints(self.content)
        view:Hide()
        spec.build(view)
        self.views[key] = view
        layoutView(key, view)
    elseif view.gwLayoutStale and not inCombat() then
        view.gwLayoutStale = nil
        layoutView(key, view)
    end
    return view
end

-- Shows a view; the last one (except Settings) is remembered. source is
-- "nav" for a click in the sidebar (a view may treat it as "go home").
function Main:Select(key, source)
    key = ALIASES[key] or key
    if not available(key) then key = "overview" end
    self:Build()
    local view = self:View(key)
    if not view then return nil end
    for other, existing in pairs(self.views) do
        if other ~= key then existing:Hide() end
    end
    for navKey, button in pairs(self.nav) do
        button:SetSelected(navKey == key)
    end
    self.current = key
    if key ~= "settings" then
        Prefs.SetLastView(key)
    end
    view:Show()
    local spec = Views[key]
    if source == "nav" and spec.onNav then spec.onNav(view) end
    self:RefreshView()
    return key
end

-- Refreshes the open view, when the window is shown.
function Main:RefreshView()
    if not self.frame or not self.frame:IsShown() or not self.current then
        return
    end
    local spec, view = Views[self.current], self.views[self.current]
    if spec and view and spec.refresh then
        spec.refresh(view)
    end
end

-- Opens the window, on a view or the last one used.
function Main:Open(key)
    local frame = self:Build()
    if not frame then return nil end
    local target = key or self.current or Prefs.LastView()
    if not frame:IsShown() then
        frame:Show()
    end
    self:StartTicker()
    return self:Select(target)
end

function Main:Close()
    if self.frame then self.frame:Hide() end
    self:StopTicker()
end

function Main:IsOpen()
    return self.frame ~= nil and self.frame:IsShown() == true
end

function Main:Toggle()
    if self:IsOpen() then
        self:Close()
        return false
    end
    self:Open()
    return true
end

function Main:StartTicker()
    if self.ticker or not (Globals.C_Timer and type(Globals.C_Timer.NewTicker) == "function") then return end
    self.ticker = Globals.C_Timer.NewTicker(1, function()
        if not Main:IsOpen() then
            Main:StopTicker()
            return
        end
        local spec, view = Views[Main.current], Main.views and Main.views[Main.current]
        if spec and spec.tick and view then
            spec.tick(view)
        end
    end)
end

function Main:StopTicker()
    if self.ticker then
        self.ticker:Cancel()
        self.ticker = nil
    end
end

-- Called by DungeonSessions and FarmingSessions when their state changes.
function Main:RefreshDungeon()
    if self.current == "dungeon" or self.current == "overview" then self:RefreshView() end
end

function Main:RefreshFarmingTimer()
    if self.current == "farming" or self.current == "overview" then self:RefreshView() end
end

-- Centres the window and gives it its default size.
function Main:ResetPosition()
    GW.Store.ResetMainFramePosition()
    Prefs.SetWindowSize(nil, nil)
    if self.frame then
        self.frame:ApplySize(WIDTH, HEIGHT)
        self.frame:RestorePosition()
        self:Relayout()
    end
end
