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
    GW.QuestLog:Initialize(frame)
end

function GW.MainFrame:RefreshFarmingTimer()
    if not self.farmButton then
        return
    end
    local context = GW.FarmingSessions.Context()
    self.farmButton:SetText(context and context.mode == "manual" and "Stop farming" or "Start farming")
end

function GW.MainFrame:Toggle()
    if self.frame:IsShown() then
        self.frame:Hide()
    else
        GW.QuestLog:Refresh()
        self.frame:Show()
    end
end

function GW.MainFrame:ResetPosition()
    GW.Store.ResetMainFramePosition()

    local position = GW.Store.GetMainFramePosition()
    self.frame:ClearAllPoints()
    self.frame:SetPoint(position.point, UIParent, position.relativePoint, position.x, position.y)
end
