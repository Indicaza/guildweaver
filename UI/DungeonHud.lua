local _, GW = ...

-- The dungeon tracker. Shows inside party and raid instances while a run is
-- open, hides everywhere else. Three modes:
--   minimized: one line, time, bosses and XP/hour
--   compact (default): dungeon, time, XP, XP/hour, bosses, deaths, PB pace
--     and the current objective
--   expanded: XP detail, every checkpoint with its split and PB pace,
--     objectives, the wallet change (labelled, not profit) and a Split button
-- Drag to move, drag the corner to resize, right-click or the +/- buttons to
-- change mode. Position, size and mode are saved per account.
--
-- A plain frame with simple textures: no secure template, no protected
-- calls, so nothing here is blocked in combat. No sounds, no animations.
-- It redraws only when a run changes, plus once a second for the clock
-- while it is on screen, and only touches the text when it changed.
GW.DungeonHud = GW.DungeonHud or {}

local Globals = _G or {}
local Hud = GW.DungeonHud
local MODES = { "minimized", "compact", "expanded" }
local MODE_INDEX = { minimized = 1, compact = 2, expanded = 3 }
local DEFAULT_SIZES = {
    minimized = { width = 200, height = 26 },
    compact = { width = 230, height = 96 },
    expanded = { width = 260, height = 230 },
}
local DEFAULTS = { enabled = true, mode = "compact", point = "TOPRIGHT", relativePoint = "TOPRIGHT", x = -220, y = -220 }
local MAX_SPLITS = 8
local MAX_OBJECTIVES = 3
Hud.MODES = MODES
Hud.DEFAULT_SIZES = DEFAULT_SIZES

local function prefs()
    local db = GW.Store and GW.Store.GetDatabase and GW.Store.GetDatabase()
    if type(db) ~= "table" then
        return nil
    end
    db.ui = type(db.ui) == "table" and db.ui or {}
    local value = type(db.ui.dungeonHud) == "table" and db.ui.dungeonHud or {}
    -- 0.5 saved a bool "expanded" and one width/height: carry them over.
    if value.mode == nil then
        value.mode = value.expanded and "expanded" or "compact"
    end
    if not MODE_INDEX[value.mode] then value.mode = "compact" end
    value.sizes = type(value.sizes) == "table" and value.sizes or {}
    if value.width and value.height and not value.sizes.compact then
        value.sizes.compact = { width = value.width, height = value.height }
    end
    for key, default in pairs(DEFAULTS) do
        if value[key] == nil then value[key] = default end
    end
    db.ui.dungeonHud = value
    return value
end

local function sizeFor(value, mode)
    local saved = value and value.sizes and value.sizes[mode]
    local default = DEFAULT_SIZES[mode]
    if type(saved) ~= "table" or not tonumber(saved.width) or not tonumber(saved.height) then
        return default.width, default.height
    end
    return saved.width, saved.height
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

-- "18s ahead" in green, "1:05 behind" in red. Plain text when colour = false.
function Hud.FormatPace(delta, colour)
    if delta == nil then
        return nil
    end
    delta = math.floor(delta + 0.5)
    if delta == 0 then
        return "even"
    end
    local amount = math.abs(delta) < 60 and (math.abs(delta) .. "s") or Hud.FormatDuration(math.abs(delta))
    local word = delta < 0 and "ahead" or "behind"
    if colour == false then
        return amount .. " " .. word
    end
    return (delta < 0 and "|cff5ad19a" or "|cfff2836b") .. amount .. " " .. word .. "|r"
end

local function bossText(run)
    return tostring(run.bossesDefeated or 0) .. (run.bossesTotal and ("/" .. run.bossesTotal) or "")
end

local function xpText(run)
    if run.atLevelCap then
        return "max level"
    end
    return run.xpGained and ("+" .. commas(run.xpGained)) or "-"
end

local function rateText(run)
    if run.atLevelCap then
        return nil
    end
    return run.xpPerHour and (commas(run.xpPerHour) .. "/h") or "-/h"
end

local function paceLine(run)
    if not run.pb then
        return "PB: none yet"
    end
    local pace = Hud.FormatPace(run.pace)
    return "PB " .. Hud.FormatDuration(run.pb.durationSeconds) .. (pace and ("  " .. pace) or "")
end

-- The text lines for a run in a mode, kept apart from the frame so tests
-- can read them. `expanded` = true is the 0.5 signature (expanded mode).
function Hud.Lines(run, mode)
    if not run then
        return nil
    end
    if mode == true then mode = "expanded" elseif mode == false or mode == nil then mode = "compact" end
    local title = run.name or "Instance"
    if run.difficultyName then
        title = title .. " (" .. run.difficultyName .. ")"
    end
    if mode == "minimized" then
        local rate = rateText(run)
        return { string.format("%s  Bosses %s%s", Hud.FormatDuration(run.durationSeconds), bossText(run), rate and ("  " .. rate) or "") }
    end
    local lines = {
        "|cffe9c46a" .. title .. "|r",
        string.format("%s   Bosses %s   Deaths %d", Hud.FormatDuration(run.durationSeconds), bossText(run), run.deaths or 0),
        string.format("XP %s%s", xpText(run), rateText(run) and ("   " .. rateText(run)) or ""),
        paceLine(run),
    }
    if mode == "compact" then
        if run.objective then
            table.insert(lines, "Next: " .. tostring(run.objective.text))
        end
        return lines
    end
    -- Expanded.
    lines[3] = string.format("XP %s   %s%s", xpText(run), rateText(run) or "",
        (run.levelUps or 0) > 0 and ("   " .. run.levelUps .. " level-up" .. (run.levelUps == 1 and "" or "s")) or "")
    table.insert(lines, 3, string.format("Inside %s of %s", Hud.FormatDuration(run.insideSeconds or run.durationSeconds), Hud.FormatDuration(run.durationSeconds)))
    table.insert(lines, "Wallet change " .. Hud.FormatMoney(run.netCopper) .. " (not profit)")
    if not run.encounterEvents then
        table.insert(lines, "|cff6c7480No boss events yet: use Split at each boss.|r")
    end
    local splits = run.splits or {}
    local first = math.max(1, #splits - MAX_SPLITS + 1)
    for index = first, #splits do
        local split = splits[index]
        local pace = Hud.FormatPace(split.delta)
        table.insert(lines, string.format("%s  %s  +%s%s", Hud.FormatDuration(split.at), tostring(split.name),
            Hud.FormatDuration(split.split or 0), pace and ("  " .. pace) or ""))
    end
    local objectives = GW.DungeonObjectives and GW.DungeonObjectives.List and GW.DungeonObjectives.List() or {}
    local shown = 0
    for _, objective in ipairs(objectives) do
        if shown >= MAX_OBJECTIVES then break end
        shown = shown + 1
        table.insert(lines, (objective.done and "|cff5ad19a[x]|r " or "[ ] ") .. tostring(objective.text))
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
        value.sizes[value.mode] = { width = math.floor(width), height = math.floor(height) }
    end
end
Hud.SavePosition = savePosition

local function applyLayout(frame)
    local value = prefs()
    if not value then return end
    frame:ClearAllPoints()
    frame:SetPoint(value.point, Globals.UIParent, value.relativePoint, value.x, value.y)
    local width, height = sizeFor(value, value.mode)
    frame:SetSize(width, height)
    if Hud.splitButton then
        if value.mode == "expanded" then Hud.splitButton:Show() else Hud.splitButton:Hide() end
    end
    if Hud.lessButton then
        if value.mode == "minimized" then Hud.lessButton:Hide() else Hud.lessButton:Show() end
    end
    if Hud.moreButton then
        if value.mode == "expanded" then Hud.moreButton:Hide() else Hud.moreButton:Show() end
    end
end

local function smallButton(frame, label, onClick)
    local button = Globals.CreateFrame("Button", nil, frame)
    button:SetSize(14, 14)
    local text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("CENTER", button, "CENTER", 0, 0)
    text:SetText(label)
    button:SetScript("OnClick", onClick)
    return button
end

function Hud:Create()
    if self.frame or type(Globals.CreateFrame) ~= "function" then
        return self.frame
    end
    local ok, frame = pcall(Globals.CreateFrame, "Frame", "GuildweaverDungeonHud", Globals.UIParent, "BackdropTemplate")
    if not ok or not frame then
        frame = Globals.CreateFrame("Frame", "GuildweaverDungeonHud", Globals.UIParent)
    end
    -- Below dialogs and the default action bars' tooltips; clamped so it
    -- can never be lost off screen.
    frame:SetFrameStrata("LOW")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:SetResizable(true)
    if frame.SetResizeBounds then
        pcall(frame.SetResizeBounds, frame, 150, 22, 480, 420)
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
        pcall(frame.SetBackdropColor, frame, 0.03, 0.035, 0.05, 0.78)
        pcall(frame.SetBackdropBorderColor, frame, 0.55, 0.47, 0.28, 0.6)
    end
    frame:SetScript("OnDragStart", function(current) current:StartMoving() end)
    frame:SetScript("OnDragStop", function(current)
        current:StopMovingOrSizing()
        savePosition(current)
    end)
    frame:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then Hud:CycleMode() end
    end)

    local text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -7)
    text:SetPoint("RIGHT", frame, "RIGHT", -22, 0)
    text:SetJustifyH("LEFT")
    text:SetJustifyV("TOP")
    text:SetSpacing(3)
    self.text = text

    self.lessButton = smallButton(frame, "-", function() Hud:SetMode(MODES[math.max(1, MODE_INDEX[prefs().mode] - 1)]) end)
    self.lessButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -5)
    self.moreButton = smallButton(frame, "+", function() Hud:SetMode(MODES[math.min(3, MODE_INDEX[prefs().mode] + 1)]) end)
    self.moreButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -20)

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
    self.lines = Hud.Lines(run, value.mode)
    local text = table.concat(self.lines, "\n")
    if text ~= self.shownText then
        self.text:SetText(text)
        self.shownText = text
        self.redraws = (self.redraws or 0) + 1
    end
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

function Hud.Mode()
    local value = prefs()
    return value and value.mode or "compact"
end

function Hud:SetMode(mode)
    local value = prefs()
    if not value or not MODE_INDEX[mode] then return nil end
    value.mode = mode
    value.expanded = mode == "expanded"
    if self.frame then applyLayout(self.frame) end
    self.shownText = nil
    self:Refresh()
    return mode
end

-- minimized → compact → expanded → minimized.
function Hud:CycleMode()
    local current = MODE_INDEX[Hud.Mode()] or 2
    return self:SetMode(MODES[current % #MODES + 1])
end

-- 0.5's toggle: compact ↔ expanded.
function Hud:ToggleExpanded()
    return self:SetMode(Hud.Mode() == "expanded" and "compact" or "expanded")
end

function Hud:ResetPosition()
    local value = prefs()
    if not value then return end
    for key, default in pairs(DEFAULTS) do
        if key ~= "enabled" and key ~= "mode" then value[key] = default end
    end
    value.sizes = {}
    value.width, value.height = nil, nil
    if self.frame then applyLayout(self.frame) end
end
