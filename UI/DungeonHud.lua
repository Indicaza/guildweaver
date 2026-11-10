local _, GW = ...

-- A small dungeon tracker. Shows inside party and raid instances while a
-- run is open, hides everywhere else. Movable (drag), resizable (bottom
-- right corner), right-click or /gw dungeon details for more. No sounds,
-- no popups, and it is a plain frame, so it never touches protected UI.
GW.DungeonHud = GW.DungeonHud or {}

local Globals = _G or {}
local Hud = GW.DungeonHud
local DEFAULTS = { enabled = true, expanded = false, point = "TOPRIGHT", relativePoint = "TOPRIGHT",
    x = -220, y = -220, width = 220, height = 78 }
local EXPANDED_EXTRA = 86
local MAX_SPLITS = 4

local function prefs()
    local db = GW.Store and GW.Store.GetDatabase and GW.Store.GetDatabase()
    if type(db) ~= "table" then
        return nil
    end
    db.ui = type(db.ui) == "table" and db.ui or {}
    local value = type(db.ui.dungeonHud) == "table" and db.ui.dungeonHud or {}
    for key, default in pairs(DEFAULTS) do
        if value[key] == nil then value[key] = default end
    end
    db.ui.dungeonHud = value
    return value
end

function Hud.FormatDuration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor(seconds / 60) % 60
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, seconds % 60)
    end
    return string.format("%d:%02d", minutes, seconds % 60)
end

function Hud.FormatMoney(copper)
    if copper == nil then
        return "-"
    end
    local sign = copper < 0 and "-" or "+"
    copper = math.abs(math.floor(copper))
    local gold, silver = math.floor(copper / 10000), math.floor(copper / 100) % 100
    if gold > 0 then
        return string.format("%s%dg %ds", sign, gold, silver)
    end
    return string.format("%s%ds %dc", sign, silver, copper % 100)
end

local function commas(value)
    local formatted = tostring(math.floor(value))
    local count
    repeat
        formatted, count = formatted:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
    until count == 0
    return formatted
end

-- The text lines for a run, kept apart from the frame so tests can read it.
function Hud.Lines(run, expanded)
    if not run then
        return nil
    end
    local title = run.name or "Instance"
    if run.difficultyName then
        title = title .. " (" .. run.difficultyName .. ")"
    end
    local bosses = tostring(run.bossesDefeated or 0) .. (run.bossesTotal and ("/" .. run.bossesTotal) or "")
    local xp = run.atLevelCap and "max level" or (run.xpGained and ("+" .. commas(run.xpGained)) or "-")
    local lines = {
        title,
        string.format("%s   Bosses %s   Deaths %d", Hud.FormatDuration(run.durationSeconds), bosses, run.deaths or 0),
        string.format("XP %s   Gold %s", xp, Hud.FormatMoney(run.netCopper)),
    }
    if expanded then
        table.insert(lines, "XP/hour " .. (run.xpPerHour and commas(run.xpPerHour) or "-")
            .. (run.encounterEvents and "" or "   (bosses: use Split)"))
        local splits = run.splits or {}
        local first = math.max(1, #splits - MAX_SPLITS + 1)
        for index = first, #splits do
            local split = splits[index]
            table.insert(lines, Hud.FormatDuration(split.at) .. "  " .. tostring(split.name))
        end
    end
    return lines
end

local function savePosition(frame)
    local value = prefs()
    if not value then return end
    local ok, point, _, relativePoint, x, y = pcall(frame.GetPoint, frame, 1)
    if ok and type(point) == "string" then
        value.point, value.relativePoint, value.x, value.y = point, relativePoint, x, y
    end
    local okSize, width, height = pcall(frame.GetSize, frame)
    if okSize and tonumber(width) and tonumber(height) then
        value.width = math.floor(width)
        value.height = math.floor(height - (value.expanded and EXPANDED_EXTRA or 0))
    end
end

local function applyLayout(frame)
    local value = prefs()
    if not value then return end
    frame:ClearAllPoints()
    frame:SetPoint(value.point, Globals.UIParent, value.relativePoint, value.x, value.y)
    frame:SetSize(value.width, value.height + (value.expanded and EXPANDED_EXTRA or 0))
    if Hud.splitButton then
        if value.expanded then Hud.splitButton:Show() else Hud.splitButton:Hide() end
    end
end

function Hud:Create()
    if self.frame or type(Globals.CreateFrame) ~= "function" then
        return self.frame
    end
    local ok, frame = pcall(Globals.CreateFrame, "Frame", "GuildweaverDungeonHud", Globals.UIParent, "BackdropTemplate")
    if not ok or not frame then
        frame = Globals.CreateFrame("Frame", "GuildweaverDungeonHud", Globals.UIParent)
    end
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:SetResizable(true)
    if frame.SetResizeBounds then
        pcall(frame.SetResizeBounds, frame, 170, 60, 480, 400)
    end
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    if frame.SetBackdrop then
        pcall(frame.SetBackdrop, frame, {
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        pcall(frame.SetBackdropColor, frame, 0, 0, 0, 0.7)
    end
    frame:SetScript("OnDragStart", function(current) current:StartMoving() end)
    frame:SetScript("OnDragStop", function(current)
        current:StopMovingOrSizing()
        savePosition(current)
    end)
    frame:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then Hud:ToggleExpanded() end
    end)

    local text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -8)
    text:SetPoint("RIGHT", frame, "RIGHT", -8, 0)
    text:SetJustifyH("LEFT")
    text:SetJustifyV("TOP")
    text:SetSpacing(3)
    self.text = text

    local grip = Globals.CreateFrame("Button", nil, frame)
    grip:SetSize(14, 14)
    grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        savePosition(frame)
    end)

    local split = Globals.CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    split:SetSize(64, 20)
    split:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 8, 6)
    split:SetText("Split")
    split:SetScript("OnClick", function()
        GW.DungeonSessions.Split()
        Hud:Refresh()
    end)
    self.splitButton = split

    self.frame = frame
    applyLayout(frame)
    frame:Hide()
    return frame
end

local function stopTicker()
    if Hud.ticker then
        Hud.ticker:Cancel()
        Hud.ticker = nil
    end
end

-- Shows the HUD inside an instance with an open run, hides it otherwise.
-- The once-a-second timer runs only while it is on screen.
function Hud:Refresh()
    local value = prefs()
    local run = GW.DungeonSessions and GW.DungeonSessions.Current and GW.DungeonSessions.Current() or nil
    local visible = value and value.enabled and run and run.inside
    if not visible then
        stopTicker()
        if self.frame then self.frame:Hide() end
        self.visible = false
        return false
    end
    local frame = self:Create()
    if not frame then
        return false
    end
    self.lines = Hud.Lines(run, value.expanded)
    self.text:SetText(table.concat(self.lines, "\n"))
    if not self.visible then
        frame:Show()
        self.visible = true
    end
    if not self.ticker and Globals.C_Timer and type(Globals.C_Timer.NewTicker) == "function" then
        self.ticker = Globals.C_Timer.NewTicker(1, function() Hud:Refresh() end)
    end
    return true
end

function Hud:SetEnabled(enabled)
    local value = prefs()
    if not value then return false end
    value.enabled = enabled == true
    self:Refresh()
    return value.enabled
end

function Hud.IsEnabled()
    local value = prefs()
    return value ~= nil and value.enabled == true
end

function Hud:ToggleExpanded()
    local value = prefs()
    if not value then return end
    value.expanded = not value.expanded
    if self.frame then applyLayout(self.frame) end
    self:Refresh()
end

function Hud:ResetPosition()
    local value = prefs()
    if not value then return end
    for key, default in pairs(DEFAULTS) do
        if key ~= "enabled" and key ~= "expanded" then value[key] = default end
    end
    if self.frame then applyLayout(self.frame) end
end
