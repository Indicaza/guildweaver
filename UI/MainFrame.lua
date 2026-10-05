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
    GW.QuestLog:Initialize(frame)
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
