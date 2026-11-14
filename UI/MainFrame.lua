local _, GW = ...

-- The Guildweaver dashboard: a sidebar of modules and one view at a time.
--   Overview     what each module is doing, one card each
--   Dungeons     the open run and its timer, recent runs, objectives
--   Farming      the timed farming run, this session's fishing
--   Guild Quests the quest log (QuestLog.lua)
--   Sync & Data  what is collected, when it reaches the bridge, Sync now,
--                and an Advanced section for diagnostics
--   Settings     the minimap button, the dungeon HUD, the window
-- Built on first open, not at login. While open it updates live numbers
-- once a second; closed, it does nothing at all.
GW.MainFrame = GW.MainFrame or {}

local Globals = _G or {}
local Main = GW.MainFrame
local UI, Theme, Prefs = GW.UI, GW.Theme, GW.UiPrefs

local WIDTH, HEIGHT = 740, 500
local HEADER = 44
local SIDEBAR = 168
local PAD = 20
local CONTENT_WIDTH = WIDTH - SIDEBAR - PAD * 2

local NAV = {
    { key = "overview", label = "Overview" },
    { key = "dungeon", label = "Dungeons" },
    { key = "farming", label = "Farming" },
    { key = "quests", label = "Guild Quests" },
    { key = "sync", label = "Sync & Data" },
}
Main.NAV = NAV

local Views = {}
Main.Views = Views

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

local function dayTime(timestamp)
    timestamp = tonumber(timestamp)
    if not timestamp or type(Globals.date) ~= "function" then return nil end
    local ok, text = pcall(Globals.date, "%b %d, %H:%M", timestamp)
    return ok and text or nil
end

-- A page title and a one-line explanation at the top of a view.
local function pageHeader(view, title, subtitle)
    view.title = UI.Text(view, "title", "goldBright")
    view.title:SetPoint("TOPLEFT", view, "TOPLEFT", 0, 0)
    view.title:SetText(title)
    view.subtitle = UI.Text(view, "label", "textMuted")
    view.subtitle:SetPoint("TOPLEFT", view.title, "BOTTOMLEFT", 0, -5)
    view.subtitle:SetPoint("RIGHT", view, "RIGHT", 0, 0)
    pcall(view.subtitle.SetWordWrap, view.subtitle, false)
    view.subtitle:SetText(subtitle)
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
    return context and context.mode == "manual" and "Stop & save run" or "Start timed run"
end

-- Overview ---------------------------------------------------------------------------

local function dungeonSummary()
    local run = sessions().Current()
    if run then
        local state = hud().DisplayState(run)
        local detail = hud().StateText(run)
        if run.bossesTotal or (run.bossesDefeated or 0) > 0 then
            detail = "Bosses " .. run.bossesDefeated .. (run.bossesTotal and ("/" .. run.bossesTotal) or "") .. "  " .. Theme.Hex("textFaint") .. "\194\183|r  " .. detail
        end
        return run.name, hud().ClockText(run), state, detail
    end
    local last = sessions().History()[1]
    if last then
        return "No run open", nil, nil, "Last: " .. tostring(last.name or "Instance") .. ", " .. duration(last.timerSeconds or last.durationSeconds) .. ", " .. tostring(last.status)
    end
    return "No run open", nil, nil, "Tracking starts when you enter a dungeon or raid."
end

local function questCounts()
    local quests = GW.Quests
    local available, mine = #quests.GetQuests("available"), #quests.GetQuests("my")
    local _, source = quests.GetSource()
    return available, mine, source
end

Views.overview = {
    build = function(view)
        local ok, name = pcall(Globals.UnitName, "player")
        name = ok and type(name) == "string" and name or nil
        pageHeader(view, name and ("Welcome back, " .. name) or "Welcome back",
            "Guildweaver records your play in the background and keeps your guild's records current.")
        local cardWidth, cardHeight = (CONTENT_WIDTH - 12) / 2, 132
        local function card(index, key, heading)
            local frame = UI.Card(view, function() Main:Select(key) end)
            frame:SetSize(cardWidth, cardHeight)
            frame:SetPoint("TOPLEFT", view, "TOPLEFT", ((index - 1) % 2) * (cardWidth + 12), -56 - math.floor((index - 1) / 2) * (cardHeight + 12))
            frame.heading = UI.Text(frame, "heading", "gold")
            frame.heading:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -14)
            frame.heading:SetText(string.upper(heading))
            frame.more = UI.Text(frame, "small", "textFaint", "RIGHT")
            frame.more:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -14)
            frame.more:SetText("Open \226\128\186")
            frame.main = UI.Text(frame, "title", "text")
            frame.main:SetPoint("TOPLEFT", frame.heading, "BOTTOMLEFT", 0, -14)
            frame.main:SetPoint("RIGHT", frame, "RIGHT", -14, 0)
            pcall(frame.main.SetWordWrap, frame.main, false)
            frame.value = UI.Text(frame, "clockMid", "text", "RIGHT")
            frame.value:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -38)
            frame.detail = paragraph(frame, "small", "textMuted", cardWidth - 28)
            frame.detail:SetPoint("TOPLEFT", frame.main, "BOTTOMLEFT", 0, -8)
            view.cards[key] = frame
            return frame
        end
        view.cards = {}
        card(1, "dungeon", "Dungeons")
        local farming = card(2, "farming", "Farming")
        farming.button = UI.Button(farming, farmingLabel(), { width = 128, height = 22, variant = "primary",
            onClick = function() Main:ToggleFarming() end })
        farming.button:SetPoint("BOTTOMLEFT", farming, "BOTTOMLEFT", 14, 14)
        card(3, "quests", "Guild Quests")
        local sync = card(4, "sync", "Sync & Data")
        -- A status light before "Collecting".
        sync.main:ClearAllPoints()
        sync.main:SetPoint("TOPLEFT", sync.heading, "BOTTOMLEFT", 15, -14)
        sync.dot = UI.Dot(sync, 8)
        sync.dot:SetPoint("RIGHT", sync.main, "LEFT", -7, 0)
        sync.dot:SetStatus("good")
    end,
    refresh = function(view)
        local cards = view.cards
        local title, clock, state, detail = dungeonSummary()
        UI.SetText(cards.dungeon.main, title)
        UI.SetText(cards.dungeon.value, clock or "")
        Theme.Tint(cards.dungeon.value, state == "paused" and "warn" or (state == "ready" and "textMuted" or (state == "cleared" and "gold" or "text")))
        UI.SetText(cards.dungeon.detail, detail)

        local status = GW.FarmingSessions.Status()
        local measuring = status and status.mode == "manual"
        UI.SetText(cards.farming.main, measuring and "Timing a run" or "Automatic estimates")
        UI.SetText(cards.farming.value, measuring and duration(status.durationSeconds) or "")
        UI.SetText(cards.farming.detail, measuring and (status.gatheringCount .. " gathers so far.")
            or (status and (status.gatheringCount .. " gathers in the current estimate.") or "Time a run yourself for exact hours."))
        cards.farming.button:SetLabel(farmingLabel())
        cards.farming.button:SetVariant(measuring and "secondary" or "primary")

        local available, mine, source = questCounts()
        UI.SetText(cards.quests.main, available .. " available  " .. Theme.Hex("textFaint") .. "\194\183|r  " .. mine .. " yours")
        UI.SetText(cards.quests.detail, source == "live" and "Synced with your guild." or "Preview data until your guild's quests sync.")

        UI.SetText(cards.sync.main, "Collecting")
        UI.SetText(cards.sync.detail, "Your data reaches the bridge when WoW saves: on /reload or logout.")
    end,
}
Views.overview.tick = Views.overview.refresh

-- Dungeons ---------------------------------------------------------------------------

local MAX_RECENT = 6
local MAX_OBJECTIVE_ROWS = 6

Views.dungeon = {
    build = function(view)
        pageHeader(view, "Dungeons", "Runs are tracked automatically in dungeons and raids. The timer starts on your first pull.")
        local run = UI.Card(view)
        run:SetPoint("TOPLEFT", view, "TOPLEFT", 0, -54)
        run:SetSize(CONTENT_WIDTH, 128)
        view.runCard = run
        run.name = UI.Text(run, "title", "gold")
        run.name:SetPoint("TOPLEFT", run, "TOPLEFT", 16, -14)
        run.difficulty = UI.Text(run, "small", "textFaint")
        run.difficulty:SetPoint("LEFT", run.name, "RIGHT", 8, -1)
        run.clock = UI.Text(run, "clock", "text")
        run.clock:SetPoint("TOPLEFT", run.name, "BOTTOMLEFT", 0, -10)
        run.state = UI.Text(run, "label", "textMuted")
        run.state:SetPoint("LEFT", run.clock, "RIGHT", 12, -2)
        run.detail = UI.Text(run, "label", "text")
        run.detail:SetPoint("TOPLEFT", run.clock, "BOTTOMLEFT", 0, -8)
        run.detail:SetPoint("RIGHT", run, "RIGHT", -16, 0)
        pcall(run.detail.SetWordWrap, run.detail, false)
        run.timer = UI.Button(run, "Start", { width = 84, height = 24, variant = "primary", onClick = function()
            sessions().ToggleTimer()
            Main:RefreshView()
        end })
        run.timer:SetPoint("TOPRIGHT", run, "TOPRIGHT", -16, -16)
        run.split = UI.Button(run, "Split", { width = 84, height = 24, tooltip = "Split",
            tooltipLines = { "Marks a checkpoint now, named after your target when it is an NPC." },
            onClick = function()
                sessions().Split()
                Main:RefreshView()
            end })
        run.split:SetPoint("TOPRIGHT", run.timer, "BOTTOMRIGHT", 0, -6)
        run.finish = UI.ConfirmButton(run, "End run", "Click to end", { width = 84, height = 24,
            tooltip = "End run", tooltipLines = { "Saves the run as completed and closes it. Pause only stops the clock." },
            onClick = function()
                if sessions().Finish() then
                    GW.Print("Dungeon run saved as completed. It reaches the website after /reload or logout.")
                end
                Main:RefreshView()
            end })
        run.finish:SetPoint("TOPRIGHT", run.split, "BOTTOMRIGHT", 0, -6)
        run.hud = UI.Button(run, "Show HUD", { width = 96, height = 24, variant = "ghost", onClick = function()
            local tracker = hud()
            if tracker.IsEnabled() and not tracker.IsHiddenForRun() then tracker:SetEnabled(false) else tracker:ShowNow() end
            Main:RefreshView()
        end })
        run.hud:SetPoint("RIGHT", run.timer, "LEFT", -8, 0)

        -- Recent runs and objectives, side by side.
        local columnWidth = (CONTENT_WIDTH - 20) / 2
        local recent = UI.SectionHeader(view, "Recent runs")
        recent:SetPoint("TOPLEFT", run, "BOTTOMLEFT", 0, -18)
        recent:SetWidth(columnWidth)
        view.recentRows = {}
        for index = 1, MAX_RECENT do
            local line = UI.CreateFrame("Frame", view)
            line:SetSize(columnWidth, 20)
            line:SetPoint("TOPLEFT", recent, "BOTTOMLEFT", 0, -10 - (index - 1) * 21)
            line.name = UI.Text(line, "label", "text")
            line.name:SetPoint("LEFT", line, "LEFT", 0, 0)
            line.name:SetPoint("RIGHT", line, "RIGHT", -96, 0)
            pcall(line.name.SetWordWrap, line.name, false)
            line.value = UI.Text(line, "small", "textMuted", "RIGHT")
            line.value:SetPoint("RIGHT", line, "RIGHT", 0, 0)
            view.recentRows[index] = line
        end
        view.recentEmpty = UI.Text(view, "label", "textFaint")
        view.recentEmpty:SetPoint("TOPLEFT", recent, "BOTTOMLEFT", 0, -12)
        view.recentEmpty:SetText("Finished runs will appear here.")

        local objectives = UI.SectionHeader(view, "Objectives")
        objectives:SetPoint("TOPLEFT", run, "BOTTOMLEFT", columnWidth + 20, -18)
        objectives:SetWidth(columnWidth)
        view.objectiveRows = {}
        for index = 1, MAX_OBJECTIVE_ROWS do
            local line = UI.CreateFrame("Button", view)
            line:SetSize(columnWidth, 20)
            line:SetPoint("TOPLEFT", objectives, "BOTTOMLEFT", 0, -10 - (index - 1) * 21)
            line.text = UI.Text(line, "label", "text")
            line.text:SetPoint("LEFT", line, "LEFT", 0, 0)
            line.text:SetPoint("RIGHT", line, "RIGHT", -24, 0)
            pcall(line.text.SetWordWrap, line.text, false)
            line.remove = UI.IconButton(line, "\195\151", { size = 18, tooltip = "Remove", onClick = function()
                GW.DungeonObjectives.Remove(line.index)
                Main:RefreshView()
            end })
            line.remove:SetPoint("RIGHT", line, "RIGHT", 0, 0)
            pcall(line.RegisterForClicks, line, "LeftButtonUp")
            line:SetScript("OnClick", function(self)
                local objective = GW.DungeonObjectives.List()[self.index]
                if objective then GW.DungeonObjectives.SetDone(self.index, not objective.done) end
                Main:RefreshView()
            end)
            line:SetScript("OnEnter", function(self) UI.ShowTooltip(self, "Objective", { "Click to mark done or open again." }) end)
            line:SetScript("OnLeave", UI.HideTooltip)
            view.objectiveRows[index] = line
        end
        view.objectiveInput = UI.Input(view, columnWidth - 52, function(box, text)
            local added = GW.DungeonObjectives.Add(text)
            if added then box:SetText("") end
            box:ClearFocus()
            Main:RefreshView()
        end)
        view.objectiveAdd = UI.Button(view, "Add", { width = 46, height = 22, onClick = function()
            local box = view.objectiveInput
            local added = GW.DungeonObjectives.Add(box:GetText())
            if added then box:SetText("") end
            box:ClearFocus()
            Main:RefreshView()
        end })
        view.objectivesHeader = objectives
    end,
    refresh = function(view)
        local card = view.runCard
        local run = sessions().Current()
        local tracker = hud()
        if run then
            UI.SetText(card.name, run.name or "Instance")
            UI.SetText(card.difficulty, run.difficultyName or "")
            UI.SetText(card.clock, tracker.ClockText(run))
            local state = tracker.DisplayState(run)
            Theme.Tint(card.clock, state == "paused" and "warn" or (state == "ready" and "textMuted" or (state == "cleared" and "gold" or "text")))
            UI.SetText(card.state, tracker.StateText(run))
            local parts = {}
            if run.bossesTotal or (run.bossesDefeated or 0) > 0 then
                table.insert(parts, "Bosses " .. run.bossesDefeated .. (run.bossesTotal and ("/" .. run.bossesTotal) or ""))
            end
            table.insert(parts, "Deaths " .. (run.deaths or 0))
            if run.xpPerHour and not run.atLevelCap then table.insert(parts, tracker.Commas(run.xpPerHour) .. " XP/h") end
            local wallet = tracker.FormatMoney(run.netCopper)
            if wallet then table.insert(parts, "Wallet " .. wallet) end
            if not run.inside then table.insert(parts, Theme.Colorize("outside: continues if you go back in", "textFaint")) end
            UI.SetText(card.detail, table.concat(parts, "   "))
            card.timer:SetLabel(tracker.TimerButtonText(run))
            card.timer:SetVariant(state == "running" and "secondary" or "primary")
            card.timer:Show()
            card.split:Show()
            card.finish:Show()
        else
            UI.SetText(card.name, "No run open")
            UI.SetText(card.difficulty, "")
            UI.SetText(card.clock, "")
            UI.SetText(card.state, "")
            UI.SetText(card.detail, "Enter a dungeon or raid to start one. " .. Theme.Colorize("/gw dungeon new", "text") .. " starts over after a reset.")
            card.timer:Hide()
            card.split:Hide()
            card.finish:Hide()
        end
        local shown = tracker.IsEnabled() and not tracker.IsHiddenForRun()
        card.hud:SetLabel(shown and "Hide HUD" or "Show HUD")
        card.hud:ClearAllPoints()
        if run then
            card.hud:SetPoint("RIGHT", card.timer, "LEFT", -8, 0)
        else
            card.hud:SetPoint("TOPRIGHT", card, "TOPRIGHT", -16, -16)
        end

        local history = sessions().History()
        for index, line in ipairs(view.recentRows) do
            local entry = history[index]
            if entry then
                UI.SetText(line.name, tostring(entry.name or "Instance"))
                local status = tostring(entry.status or "")
                UI.SetText(line.value, duration(entry.timerSeconds or entry.durationSeconds) .. "  "
                    .. Theme.Colorize(status, status == "completed" and "good" or "textFaint"))
                line:Show()
            else
                line:Hide()
            end
        end
        UI.SetShown(view.recentEmpty, #history == 0)

        local list = GW.DungeonObjectives.List()
        local count = math.min(MAX_OBJECTIVE_ROWS, #list)
        for index, line in ipairs(view.objectiveRows) do
            local objective = list[index]
            if index <= count then
                line.index = index
                local mark = Theme.Colorize("\194\183", objective.done and "good" or "gold")
                UI.SetText(line.text, mark .. "  " .. (objective.done and Theme.Colorize(objective.text, "textFaint") or objective.text)
                    .. (objective.boss and Theme.Colorize("  boss", "textFaint") or ""))
                line:Show()
            else
                line:Hide()
            end
        end
        view.objectiveInput:ClearAllPoints()
        view.objectiveInput:SetPoint("TOPLEFT", view.objectivesHeader, "BOTTOMLEFT", 0, -10 - count * 21)
        view.objectiveAdd:ClearAllPoints()
        view.objectiveAdd:SetPoint("LEFT", view.objectiveInput, "RIGHT", 6, 0)
        UI.SetShown(view.objectiveInput, #list < GW.DungeonObjectives.MAX and count < MAX_OBJECTIVE_ROWS)
        UI.SetShown(view.objectiveAdd, #list < GW.DungeonObjectives.MAX and count < MAX_OBJECTIVE_ROWS)
    end,
    tick = function(view)
        local run = sessions().Current()
        if run then UI.SetText(view.runCard.clock, hud().ClockText(run)) end
    end,
}

-- Farming ----------------------------------------------------------------------------

Views.farming = {
    build = function(view)
        pageHeader(view, "Farming", "Gathering is grouped into runs automatically. Time a run yourself for exact hours.")
        local card = UI.Card(view)
        card:SetPoint("TOPLEFT", view, "TOPLEFT", 0, -54)
        card:SetSize(CONTENT_WIDTH, 132)
        view.card = card
        card.state = UI.Text(card, "title", "gold")
        card.state:SetPoint("TOPLEFT", card, "TOPLEFT", 16, -14)
        card.clock = UI.Text(card, "clock", "text")
        card.clock:SetPoint("TOPLEFT", card.state, "BOTTOMLEFT", 0, -10)
        card.detail = UI.Text(card, "label", "textMuted")
        card.detail:SetPoint("TOPLEFT", card.clock, "BOTTOMLEFT", 0, -8)
        card.detail:SetPoint("RIGHT", card, "RIGHT", -16, 0)
        card.button = UI.Button(card, farmingLabel(), { width = 140, height = 26, variant = "primary",
            onClick = function() Main:ToggleFarming() end })
        card.button:SetPoint("TOPRIGHT", card, "TOPRIGHT", -16, -16)
        card.note = paragraph(card, "small", "textFaint", CONTENT_WIDTH - 32)
        card.note:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 16, 12)
        card.note:SetText("Travel, combat and waiting count; AFK time is noted separately. A /reload or logout ends the run, so offline time never counts.")

        local fishing = UI.SectionHeader(view, "Fishing this session")
        fishing:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -20)
        fishing:SetWidth(CONTENT_WIDTH)
        view.fishingStats = {}
        local labels = { "Casts", "Catches", "From pools" }
        for index, label in ipairs(labels) do
            local stat = UI.Stat(view, label, 120)
            stat:SetPoint("TOPLEFT", fishing, "BOTTOMLEFT", (index - 1) * 130, -12)
            view.fishingStats[index] = stat
        end
        view.lastCatch = UI.Text(view, "label", "textMuted")
        view.lastCatch:SetPoint("TOPLEFT", fishing, "BOTTOMLEFT", 0, -56)
        view.lastCatch:SetPoint("RIGHT", view, "RIGHT", 0, 0)
        pcall(view.lastCatch.SetWordWrap, view.lastCatch, false)
        view.syncNote = paragraph(view, "small", "textFaint")
        view.syncNote:SetPoint("BOTTOMLEFT", view, "BOTTOMLEFT", 0, 4)
        view.syncNote:SetText("Saved runs and catches reach the website after /reload or logout.")
    end,
    refresh = function(view)
        local card = view.card
        local status = GW.FarmingSessions.Status()
        local measuring = status and status.mode == "manual"
        UI.SetText(card.state, measuring and "Timing a run" or (status and "Estimating from your gathering" or "Not timing"))
        UI.SetText(card.clock, measuring and duration(status.durationSeconds) or (status and duration(status.durationSeconds) or "0:00"))
        Theme.Tint(card.clock, measuring and "text" or "textMuted")
        local detail
        if status then
            detail = status.gatheringCount .. (status.gatheringCount == 1 and " gather" or " gathers")
                .. (status.afkSeconds and status.afkSeconds > 0 and ("   AFK " .. duration(status.afkSeconds)) or "")
                .. (measuring and "" or "   (automatic: first to last harvest)")
        else
            detail = "Herbs, ore, skins and fish are grouped into runs automatically."
        end
        UI.SetText(card.detail, detail)
        card.button:SetLabel(farmingLabel())
        card.button:SetVariant(measuring and "secondary" or "primary")

        local stats = GW.FishingCapture and GW.FishingCapture.Stats and GW.FishingCapture.Stats() or {}
        view.fishingStats[1]:SetValue(tostring(stats.casts or 0))
        view.fishingStats[2]:SetValue(tostring(stats.catches or 0))
        view.fishingStats[3]:SetValue(tostring(stats.poolCatches or 0))
        local last = stats.last
        if last then
            local place = tostring(last.zone or "unknown zone") .. (last.subzone and (" - " .. tostring(last.subzone)) or "")
            UI.SetText(view.lastCatch, "Last catch: " .. tostring(last.sourceName or "open water") .. ", " .. place)
        else
            UI.SetText(view.lastCatch, (stats.casts or 0) > 0 and "" or "No fishing recorded this session.")
        end
    end,
    tick = function(view)
        local status = GW.FarmingSessions.Status()
        if status then UI.SetText(view.card.clock, duration(status.durationSeconds)) end
    end,
}

-- Guild Quests -----------------------------------------------------------------------

Views.quests = {
    build = function(view)
        pageHeader(view, "Guild Quests", "Quests your guild posts on its website. Join an objective to take it on.")
        local holder = UI.CreateFrame("Frame", view)
        holder:SetPoint("TOPLEFT", view, "TOPLEFT", 0, -50)
        holder:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", 0, 0)
        GW.QuestLog:Initialize(holder)
    end,
    refresh = function()
        GW.QuestLog:Refresh()
    end,
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
        pageHeader(view, "Sync & Data", "Character, professions, inventory, dungeons, farming and market sightings are recorded as you play.")
        local card = UI.Card(view)
        card:SetPoint("TOPLEFT", view, "TOPLEFT", 0, -54)
        card:SetSize(CONTENT_WIDTH, 150)
        view.card = card
        card.dot = UI.Dot(card, 9)
        card.dot:SetPoint("TOPLEFT", card, "TOPLEFT", 16, -19)
        card.dot:SetStatus("good")
        card.state = UI.Text(card, "title", "text")
        card.state:SetPoint("LEFT", card.dot, "RIGHT", 8, 0)
        card.state:SetText("Collecting automatically")
        card.lines = {}
        for index = 1, 3 do
            local line = UI.Text(card, "label", "textMuted")
            line:SetPoint("TOPLEFT", card, "TOPLEFT", 16, -42 - (index - 1) * 19)
            line:SetPoint("RIGHT", card, "RIGHT", -160, 0)
            pcall(line.SetWordWrap, line, false)
            card.lines[index] = line
        end
        card.sync = UI.ConfirmButton(card, "Sync now", "Reload to sync", { width = 132, height = 26, variant = "primary",
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
        card.sync:SetPoint("TOPRIGHT", card, "TOPRIGHT", -16, -16)
        card.note = paragraph(card, "small", "textFaint", CONTENT_WIDTH - 32)
        card.note:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 16, 12)
        card.note:SetText("WoW writes addon data to disk only on /reload or logout; the Guildweaver Bridge then sends it on its own. Sync now does that immediately by reloading your interface.")

        local advanced = UI.SectionHeader(view, "Advanced")
        advanced:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -20)
        advanced:SetWidth(CONTENT_WIDTH)
        view.advancedToggle = UI.Button(view, "Show", { width = 60, height = 20, variant = "ghost", onClick = function()
            view.showAdvanced = not view.showAdvanced
            Main:RefreshView()
        end })
        view.advancedToggle:SetPoint("TOPRIGHT", card, "BOTTOMRIGHT", 0, -16)
        view.advancedNote = UI.Text(view, "small", "textFaint")
        view.advancedNote:SetPoint("TOPLEFT", advanced, "BOTTOMLEFT", 0, -10)
        view.advancedNote:SetText("Diagnostics print to your chat window. Nothing here changes what is collected.")
        view.advancedButtons = {}
        local buttonWidth = (CONTENT_WIDTH - 20) / 3
        for index, entry in ipairs(ADVANCED) do
            local button = UI.Button(view, entry[1], { width = buttonWidth, height = 24, tooltip = entry[1], tooltipLines = { entry[3] },
                onClick = function() Globals.SlashCmdList.GUILDWEAVER(entry[2]) end })
            button:SetPoint("TOPLEFT", advanced, "BOTTOMLEFT", ((index - 1) % 3) * (buttonWidth + 10), -32 - math.floor((index - 1) / 3) * 30)
            view.advancedButtons[index] = button
        end
    end,
    refresh = function(view)
        local card = view.card
        local status = GW.Store.GetTelemetryStatus()
        UI.SetText(card.lines[1], status.count == 0 and "Nothing waiting: the bridge has everything."
            or (status.count .. (status.count == 1 and " update waits" or " updates wait") .. " for the next save"))
        local _, startedAt = GW.Store.GetCaptureSession()
        local started = clockTime(startedAt)
        UI.SetText(card.lines[2], started and ("Recording since " .. started .. " this session") or "Recording this session")
        local snapshot = GW.Quests.GetSnapshot and GW.Quests.GetSnapshot() or nil
        local _, source = GW.Quests.GetSource()
        local updated = snapshot and dayTime(snapshot.updatedAt)
        UI.SetText(card.lines[3], source == "live" and ("Guild quests last synced " .. (updated or "from the bridge")) or "Guild quests: not synced yet (preview data)")
        local blocked = inCombat()
        card.sync:SetEnabled(not blocked)
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

Views.settings = {
    build = function(view)
        pageHeader(view, "Settings", "Choose what Guildweaver shows. None of these settings stop data collection.")
        local columnWidth = (CONTENT_WIDTH - 28) / 2
        local tracker = hud()
        view.controls = {}
        local function add(control)
            table.insert(view.controls, control)
            return control
        end

        -- Left column: general, then data collection.
        local general = UI.SectionHeader(view, "General")
        general:SetPoint("TOPLEFT", view, "TOPLEFT", 0, -56)
        general:SetWidth(columnWidth)
        local minimap = add(UI.Toggle(view, "Minimap button", "Click to open, right-click for actions",
            function() return not Prefs.MinimapHidden() end,
            function(value) Prefs.SetMinimapHidden(not value) end, columnWidth))
        minimap:SetPoint("TOPLEFT", general, "BOTTOMLEFT", 0, -12)
        view.minimapToggle = minimap
        local reset = UI.Button(view, "Reset window position", { width = 170, height = 22, onClick = function() Main:ResetPosition() end })
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
        explain:SetText("Hiding the HUD or this window never pauses recording. Dungeon runs, farming and everything else are recorded either way, so your guild's records stay complete.")

        -- Right column: the dungeon HUD.
        local hudHeader = UI.SectionHeader(view, "Dungeon HUD")
        hudHeader:SetPoint("TOPLEFT", view, "TOPLEFT", columnWidth + 28, -56)
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
            function(value) tracker:SetMode(value) end, { segmentWidth = 58 }), columnWidth))
        mode:SetPoint("TOPLEFT", lock, "BOTTOMLEFT", 0, -10)
        view.modeChoice = mode.control
        local scale = add(UI.SettingRow(view, "Size", nil, UI.Segmented(view, SCALE_CHOICES,
            function() return tracker.Scale() end,
            function(value) tracker:SetScale(value) end, { segmentWidth = 36 }), columnWidth))
        scale:SetPoint("TOPLEFT", mode, "BOTTOMLEFT", 0, -10)
        view.scaleChoice = scale.control
        local resetHud = UI.Button(view, "Reset HUD position", { width = 150, height = 22, onClick = function()
            tracker:ResetPosition()
            Main:RefreshView()
        end })
        resetHud:SetPoint("TOPLEFT", scale, "BOTTOMLEFT", 0, -14)
        local hint = UI.Text(view, "small", "textFaint")
        hint:SetPoint("TOPLEFT", resetHud, "BOTTOMLEFT", 0, -10)
        hint:SetText("Drag the HUD to move it; right-click it to change the view.")
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
    button:SetScript("OnClick", function() Main:Select(entry.key) end)
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
        getPosition = function() return GW.Store.GetMainFramePosition() end,
        savePosition = function(point, relativePoint, x, y) GW.Store.SetMainFramePosition(point, relativePoint, x, y) end,
    })
    self.frame = frame
    local version = UI.Text(frame.header, "small", "textFaint")
    version:SetPoint("LEFT", frame.title, "RIGHT", 8, -1)
    version:SetText("v" .. tostring(GW.version or ""))
    self.settingsButton = UI.Button(frame.header, "Settings", { width = 76, height = 24, variant = "ghost",
        onClick = function() Main:Select("settings") end })
    self.settingsButton:SetPoint("RIGHT", frame.closeButton, "LEFT", -6, 0)

    local sidebar = UI.CreateFrame("Frame", frame)
    sidebar:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -(HEADER + 1))
    sidebar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 1, 1)
    sidebar:SetWidth(SIDEBAR)
    local sidebarBg = sidebar:CreateTexture(nil, "BACKGROUND")
    sidebarBg:SetAllPoints(sidebar)
    Theme.Fill(sidebarBg, "bgInset")
    local divider = sidebar:CreateTexture(nil, "BORDER")
    divider:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", 0, 0)
    divider:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT", 0, 0)
    divider:SetWidth(1)
    Theme.Fill(divider, "border")
    self.nav = {}
    for index, entry in ipairs(NAV) do
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
    return frame
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
    end
    return view
end

-- Shows a view; the last one (except Settings) is remembered.
function Main:Select(key)
    if not Views[key] then key = "overview" end
    self:Build()
    local view = self:View(key)
    if not view then return nil end
    for other, existing in pairs(self.views) do
        if other ~= key then existing:Hide() end
    end
    for navKey, button in pairs(self.nav) do
        button:SetSelected(navKey == key)
    end
    self.settingsButton:SetActive(key == "settings")
    self.current = key
    if key ~= "settings" then
        Prefs.SetLastView(key)
    end
    view:Show()
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

function Main:ResetPosition()
    GW.Store.ResetMainFramePosition()
    if self.frame then self.frame:RestorePosition() end
end
