local _, GW = ...

GW.MainFrame = GW.MainFrame or {}

function GW.MainFrame:Initialize()
    if self.frame then
        return
    end

    local frame = CreateFrame("Frame", "GuildweaverMainFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(820, 600)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")

    frame.TitleText:SetText("Guildweaver")

    frame:SetScript("OnDragStart", function(currentFrame)
        currentFrame:StartMoving()
    end)

    frame:SetScript("OnDragStop", function(currentFrame)
        currentFrame:StopMovingOrSizing()
        local point, _, relativePoint, x, y = currentFrame:GetPoint(1)
        GW.Store.SetMainFramePosition(point, relativePoint, x, y)
    end)

    local position = GW.Store.GetMainFramePosition()
    frame:ClearAllPoints()
    frame:SetPoint(position.point, UIParent, position.relativePoint, position.x, position.y)
    frame:Hide()

    table.insert(UISpecialFrames, frame:GetName())

    self.frame = frame
    local farmButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    farmButton:SetSize(130, 24)
    farmButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -34)
    farmButton:SetScript("OnClick", function()
        local context = GW.FarmingSessions.Context()
        if context and context.mode == "manual" then
            GW.FarmingSessions.Stop()
            GW.Print("Farming run saved. /gw sync sends it now.")
        elseif GW.FarmingSessions.Start() then
            GW.Print("Farming timer started. Travel and waiting count.")
        else
            GW.Print("Character data is not ready yet.")
        end
        self:RefreshFarmingTimer()
    end)
    self.farmButton = farmButton
    self:RefreshFarmingTimer()

    -- Dungeon section: the HUD switch and the open or last run.
    local dungeonButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    dungeonButton:SetSize(150, 24)
    dungeonButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 150, -34)
    dungeonButton:SetScript("OnClick", function()
        GW.DungeonHud:SetEnabled(not GW.DungeonHud:IsEnabled())
        self:RefreshDungeon()
    end)
    self.dungeonButton = dungeonButton
    local dungeonText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dungeonText:SetPoint("LEFT", dungeonButton, "RIGHT", 10, 0)
    dungeonText:SetPoint("RIGHT", frame, "RIGHT", -14, 0)
    dungeonText:SetJustifyH("LEFT")
    self.dungeonText = dungeonText
    self:RefreshDungeon()
    GW.QuestLog:Initialize(frame)
end

function GW.MainFrame:RefreshFarmingTimer()
    if not self.farmButton then
        return
    end
    local context = GW.FarmingSessions.Context()
    self.farmButton:SetText(context and context.mode == "manual" and "Stop farming" or "Start farming")
end

function GW.MainFrame:RefreshDungeon()
    if not self.dungeonButton then
        return
    end
    self.dungeonButton:SetText(GW.DungeonHud:IsEnabled() and "Dungeon HUD: on" or "Dungeon HUD: off")
    local run = GW.DungeonSessions.Current()
    local hud = GW.DungeonHud
    if run then
        local state = hud.TimerState(run)
        self.dungeonText:SetText(string.format("Dungeon run: %s, timer %s%s, %d boss(es), %d death(s)%s",
            run.name, hud.ClockText(run), state == "running" and "" or (" (" .. state .. ")"),
            run.bossesDefeated or 0, run.deaths or 0,
            run.inside and "" or " (outside, continues if you go back in)"))
        return
    end
    local last = GW.DungeonSessions.History()[1]
    if last then
        self.dungeonText:SetText(string.format("Last run: %s, %s, %s. Reaches the website after /reload or logout.",
            tostring(last.name or "Instance"), hud.FormatDuration(last.timerSeconds or last.durationSeconds), tostring(last.status)))
    else
        self.dungeonText:SetText("Dungeon runs are tracked automatically inside dungeons and raids.")
    end
end

function GW.MainFrame:Toggle()
    if self.frame:IsShown() then
        self.frame:Hide()
    else
        GW.QuestLog:Refresh()
        self:RefreshDungeon()
        self.frame:Show()
    end
end

function GW.MainFrame:ResetPosition()
    GW.Store.ResetMainFramePosition()

    local position = GW.Store.GetMainFramePosition()
    self.frame:ClearAllPoints()
    self.frame:SetPoint(position.point, UIParent, position.relativePoint, position.x, position.y)
end
