local _, GW = ...

GW.MainFrame = GW.MainFrame or {}

function GW.MainFrame:Initialize()
    if self.frame then
        return
    end

    local frame = CreateFrame("Frame", "GuildweaverMainFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(720, 520)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")

    frame.TitleText:SetText("Guildweaver")

    local heading = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    heading:SetPoint("TOP", 0, -74)
    heading:SetText("Guild Quest Log")

    local description = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    description:SetPoint("TOP", heading, "BOTTOM", 0, -16)
    description:SetWidth(560)
    description:SetJustifyH("CENTER")
    description:SetText("The loom is ready. Quest browsing, assignments, rewards, and guild synchronization come next.")

    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    hint:SetPoint("BOTTOM", 0, 42)
    hint:SetText("/gw  •  /gw version  •  /gw reset")

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
end

function GW.MainFrame:Toggle()
    if self.frame:IsShown() then
        self.frame:Hide()
    else
        self.frame:Show()
    end
end

function GW.MainFrame:ResetPosition()
    GW.Store.ResetMainFramePosition()

    local position = GW.Store.GetMainFramePosition()
    self.frame:ClearAllPoints()
    self.frame:SetPoint(position.point, UIParent, position.relativePoint, position.x, position.y)
end
