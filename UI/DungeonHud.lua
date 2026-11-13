local _, GW = ...

-- The dungeon tracker. Shows inside party and raid instances while a run is
-- open, hides everywhere else. Three modes:
--   minimized: the clock, Start/Stop, bosses and XP/hour on one line
--   compact (default): the dungeon, the clock with Start/Stop and Split,
--     the boss row, bosses, deaths, XP, XP/hour, PB pace and the current
--     objective
--   expanded: everything above plus time inside, XP detail, every
--     checkpoint with its split and pace, objectives and the wallet change
--     (labelled, not profit)
--
-- The clock is the run timer (DungeonSessions): ready until the first pull
-- or Start, then running until Stop or the last boss. The boss row is one
-- round portrait per boss kill and split, with the face of the unit that
-- was on screen at the time (a boss frame, or the target a split was named
-- after), the boss being fought with its health, and a dim circle for every
-- boss the lockout still lists. Faces are drawn by the client into the
-- circle while the unit is on screen; a reload shows an icon instead.
--
-- Drag to move, drag the corner to change the width; the height follows
-- the content. Right-click, or the -/+ buttons, change mode. Position,
-- width and mode are saved per account.
--
-- A plain frame with simple textures: no secure template, no protected
-- calls, so nothing here is blocked in combat. No sounds, no animations.
-- It redraws only when a run changes, plus once a second for the clock
-- while it is on screen, and only touches a text when it changed.
GW.DungeonHud = GW.DungeonHud or {}

local Globals = _G or {}
local Hud = GW.DungeonHud
local MODES = { "minimized", "compact", "expanded" }
local MODE_INDEX = { minimized = 1, compact = 2, expanded = 3 }
local DEFAULT_SIZES = {
    minimized = { width = 250, height = 30 },
    compact = { width = 260, height = 170 },
    expanded = { width = 290, height = 330 },
}
local DEFAULTS = { enabled = true, mode = "compact", point = "TOPRIGHT", relativePoint = "TOPRIGHT", x = -220, y = -220 }
local MAX_SPLITS = 8
local MAX_OBJECTIVES = 3
local PADDING = 8
local LINE_HEIGHT = 14
local PORTRAIT = 30
local PORTRAIT_GAP = 6
-- Dim circles for bosses still to kill, at most this many.
local MAX_PENDING = 12
local COLORS = {
    title = { 0.91, 0.77, 0.42 },
    ready = { 0.62, 0.66, 0.74 },
    running = { 1, 1, 1 },
    stopped = { 0.98, 0.72, 0.33 },
    muted = { 0.45, 0.48, 0.54 },
    -- Rings of the boss row.
    boss = { 0.93, 0.78, 0.40 },
    split = { 0.56, 0.62, 0.72 },
    engaged = { 0.96, 0.42, 0.34 },
    pending = { 0.27, 0.29, 0.34 },
}
local TEXTURES = {
    mask = "Interface\\CharacterFrame\\TempPortraitAlphaMask",
    boss = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull",
    split = "Interface\\Icons\\Ability_Rogue_Sprint",
    pending = "Interface\\Icons\\INV_Misc_QuestionMark",
    check = "Interface\\RaidFrame\\ReadyCheck-Ready",
    bar = "Interface\\TargetingFrame\\UI-StatusBar",
    background = "Interface\\Tooltips\\UI-Tooltip-Background",
    border = "Interface\\Tooltips\\UI-Tooltip-Border",
}
Hud.MODES = MODES
Hud.DEFAULT_SIZES = DEFAULT_SIZES
Hud.TEXTURES = TEXTURES
Hud.COLORS = COLORS

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

local function normalizeMode(mode)
    if mode == true then return "expanded" end
    if mode == false or mode == nil or not MODE_INDEX[mode] then return "compact" end
    return mode
end

-- Text ----------------------------------------------------------------------------

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

-- The run timer's state: ready (not started), running or stopped.
function Hud.TimerState(run)
    return run and run.timer and run.timer.state or "running"
end

-- The clock: the timed run, not the time since entry.
function Hud.ClockText(run)
    return Hud.FormatDuration(run and (run.timerSeconds or run.durationSeconds) or 0)
end

local function clockWithState(run)
    local state = Hud.TimerState(run)
    return Hud.ClockText(run) .. (state == "running" and "" or (" " .. state))
end

-- One line under the clock about the timer.
function Hud.StateText(run)
    local state = Hud.TimerState(run)
    if state == "ready" then
        return "Starts on your first pull"
    end
    if state == "stopped" then
        if run.timer and run.timer.stoppedBy == "complete" then
            return "Clear. Timer stopped"
        end
        return "Stopped. Start resumes"
    end
    if run.engaged then
        return "Fighting " .. tostring(run.engaged.name or "a boss")
    end
    return "Running"
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
    return "PB " .. Hud.FormatDuration(run.pb.seconds or run.pb.durationSeconds) .. (pace and ("  " .. pace) or "")
end

local function titleText(run)
    local title = run.name or "Instance"
    if run.difficultyName then
        title = title .. " (" .. run.difficultyName .. ")"
    end
    return title
end

-- The text lines for a run in a mode, kept apart from the frame so tests
-- and /gw dungeon can read them. `expanded` = true is the 0.5 signature.
function Hud.Lines(run, mode)
    if not run then
        return nil
    end
    mode = normalizeMode(mode)
    if mode == "minimized" then
        local rate = rateText(run)
        return { string.format("%s  Bosses %s%s", clockWithState(run), bossText(run), rate and ("  " .. rate) or "") }
    end
    local lines = {
        "|cffe9c46a" .. titleText(run) .. "|r",
        string.format("%s   Bosses %s   Deaths %d", clockWithState(run), bossText(run), run.deaths or 0),
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
    table.insert(lines, 3, string.format("Inside %s of %s since entry", Hud.FormatDuration(run.insideSeconds or run.durationSeconds), Hud.FormatDuration(run.durationSeconds)))
    table.insert(lines, "Wallet change " .. Hud.FormatMoney(run.netCopper) .. " (not profit)")
    if not run.encounterEvents then
        table.insert(lines, "|cff6c7480No boss events yet: Split at each boss names it after your target.|r")
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

-- What the frame prints under its widgets: Lines without the title and the
-- clock line, which the frame draws itself.
function Hud.BodyLines(run, mode)
    if not run then
        return nil
    end
    mode = normalizeMode(mode)
    if mode == "minimized" then
        local rate = rateText(run)
        return { string.format("Bosses %s%s", bossText(run), rate and ("  " .. rate) or "") }
    end
    local lines = Hud.Lines(run, mode)
    local body = { string.format("Bosses %s   Deaths %d", bossText(run), run.deaths or 0) }
    for index = 3, #lines do
        body[#body + 1] = lines[index]
    end
    return body
end

-- The boss row: one entry per checkpoint (a boss kill or a split), the boss
-- being fought, then a dim circle for each boss the lockout still lists.
function Hud.Portraits(run)
    local entries = {}
    for _, split in ipairs(run and run.splits or {}) do
        table.insert(entries, { id = split.id, name = split.name, kind = split.kind == "boss_kill" and "boss" or "split", at = split.at })
    end
    if run and run.engaged then
        table.insert(entries, { id = "engaged", name = run.engaged.name, kind = "engaged", at = run.engaged.since })
    end
    if run and run.bossesTotal then
        local remaining = run.bossesTotal - (run.bossesDefeated or 0) - (run.engaged and 1 or 0)
        for index = 1, math.min(MAX_PENDING, remaining) do
            table.insert(entries, { id = "pending:" .. index, kind = "pending" })
        end
    end
    return entries
end

-- Units ---------------------------------------------------------------------------

local function unitIs(fn, unit)
    if type(fn) ~= "function" then
        return false
    end
    local ok, value = pcall(fn, unit)
    if ok and Globals.issecretvalue and Globals.issecretvalue(value) then return false end
    return ok and (value == true or value == 1)
end

local function unitName(unit)
    if type(Globals.UnitName) ~= "function" then
        return nil
    end
    local ok, name = pcall(Globals.UnitName, unit)
    if ok and Globals.issecretvalue and Globals.issecretvalue(name) then return nil end
    return ok and type(name) == "string" and name or nil
end

-- The unit showing a boss: a boss frame with that name (any boss frame when
-- the name is unknown), else the target when it is that NPC.
local function unitFor(name)
    local wanted = name and string.lower(name) or nil
    local function matches(unit)
        if not unitIs(Globals.UnitExists, unit) or unitIs(Globals.UnitIsPlayer, unit) then
            return false
        end
        if wanted == nil then
            return true
        end
        local seen = unitName(unit)
        return seen ~= nil and string.lower(seen) == wanted
    end
    for index = 1, 5 do
        if matches("boss" .. index) then
            return "boss" .. index
        end
    end
    if wanted and matches("target") then
        return "target"
    end
    return nil
end
Hud.UnitFor = unitFor

-- Widgets -------------------------------------------------------------------------

local function label(parent, template, justify)
    local text = parent:CreateFontString(nil, "OVERLAY", template)
    text:SetJustifyH(justify or "LEFT")
    return text
end

local function tint(widget, rgb, alpha)
    pcall(widget.SetTextColor, widget, rgb[1], rgb[2], rgb[3], alpha or 1)
end

-- Sets a widget's text only when it changed, counting redraws.
local function setText(widget, key, text)
    Hud.shown = Hud.shown or {}
    if Hud.shown[key] == text then
        return false
    end
    Hud.shown[key] = text
    widget:SetText(text)
    Hud.redraws = (Hud.redraws or 0) + 1
    return true
end

local function panelButton(parent, text, width, onClick)
    local button = Globals.CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, 20)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    return button
end

local function smallButton(parent, text, onClick)
    local button = Globals.CreateFrame("Button", nil, parent)
    button:SetSize(14, 14)
    local caption = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    caption:SetPoint("CENTER", button, "CENTER", 0, 0)
    caption:SetText(text)
    button:SetScript("OnClick", onClick)
    return button
end

local function hideTooltip()
    local tooltip = Globals.GameTooltip
    if tooltip then
        pcall(tooltip.Hide, tooltip)
    end
end

function Hud.ShowTooltip(circle)
    local tooltip, entry = Globals.GameTooltip, circle.entry
    if not tooltip or not entry or type(tooltip.SetOwner) ~= "function" then
        return
    end
    pcall(tooltip.SetOwner, tooltip, circle.frame, "ANCHOR_TOP")
    pcall(tooltip.ClearLines, tooltip)
    if entry.kind == "pending" then
        pcall(tooltip.AddLine, tooltip, "Boss still up", 1, 1, 1)
    else
        pcall(tooltip.AddLine, tooltip, entry.name or "Boss", 1, 1, 1)
        local what = entry.kind == "boss" and "Defeated" or (entry.kind == "split" and "Split" or "In combat since")
        pcall(tooltip.AddLine, tooltip, what .. (entry.at and (" at " .. Hud.FormatDuration(entry.at)) or ""), 0.7, 0.7, 0.7)
    end
    pcall(tooltip.Show, tooltip)
end

-- A round portrait: a coloured ring, the face inside, a check for a kill.
-- Its state lives in this table, not on the frame.
local function newCircle(parent)
    local frame = Globals.CreateFrame("Button", nil, parent)
    frame:SetSize(PORTRAIT, PORTRAIT)
    local ring = frame:CreateTexture(nil, "BACKGROUND")
    ring:SetAllPoints(frame)
    ring:SetColorTexture(1, 1, 1, 1)
    local portrait = frame:CreateTexture(nil, "ARTWORK")
    portrait:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)
    portrait:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
    if type(frame.CreateMaskTexture) == "function" and type(portrait.AddMaskTexture) == "function" then
        for _, texture in ipairs({ ring, portrait }) do
            local mask = frame:CreateMaskTexture()
            mask:SetTexture(TEXTURES.mask, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            mask:SetAllPoints(texture)
            texture:AddMaskTexture(mask)
        end
    end
    local check = frame:CreateTexture(nil, "OVERLAY")
    check:SetSize(12, 12)
    check:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 2, -2)
    check:SetTexture(TEXTURES.check)
    check:Hide()
    local circle = { frame = frame, ring = ring, portrait = portrait, check = check, hasFace = false }
    frame:SetScript("OnEnter", function() Hud.ShowTooltip(circle) end)
    frame:SetScript("OnLeave", hideTooltip)
    return circle
end

-- Draws the unit's face into the circle. The last face stays when the unit
-- is gone; the fallback icon shows when none was ever seen.
local function setPortrait(circle, unit, fallback)
    if unit and type(Globals.SetPortraitTexture) == "function" then
        if pcall(Globals.SetPortraitTexture, circle.portrait, unit) then
            circle.hasFace = true
            circle.unit = unit
            circle.icon = nil
            pcall(circle.portrait.SetTexCoord, circle.portrait, 0, 1, 0, 1)
            return true
        end
    end
    if not circle.hasFace and circle.icon ~= fallback then
        circle.icon = fallback
        pcall(circle.portrait.SetTexture, circle.portrait, fallback)
        pcall(circle.portrait.SetTexCoord, circle.portrait, 0.07, 0.93, 0.07, 0.93)
    end
    return false
end

local function paintCircle(circle, entry)
    local rgb = COLORS[entry.kind] or COLORS.pending
    pcall(circle.ring.SetVertexColor, circle.ring, rgb[1], rgb[2], rgb[3], 1)
    if entry.kind == "boss" then circle.check:Show() else circle.check:Hide() end
    pcall(circle.portrait.SetDesaturated, circle.portrait, entry.kind == "pending")
    pcall(circle.portrait.SetAlpha, circle.portrait, entry.kind == "pending" and 0.4 or 1)
    circle.entry = entry
end

local function resetCircle(circle)
    circle.hasFace, circle.unit, circle.icon, circle.entry, circle.name = false, nil, nil, nil, nil
    circle.frame:Hide()
end

-- Takes a circle from the pool, or makes one.
function Hud:circleFor(id)
    local frame = self:Create()
    if not frame then
        return nil
    end
    self.circles = self.circles or {}
    self.pool = self.pool or {}
    local circle = self.circles[id] or table.remove(self.pool) or newCircle(self.row)
    self.circles[id] = circle
    return circle
end

-- Every circle back to the pool: a new run.
function Hud:ResetCircles()
    self.pool = self.pool or {}
    for id, circle in pairs(self.circles or {}) do
        resetCircle(circle)
        table.insert(self.pool, circle)
        self.circles[id] = nil
    end
    if self.engaged then
        resetCircle(self.engaged)
        table.insert(self.pool, self.engaged)
        self.engaged = nil
    end
    self.engagedUnit = nil
end

-- A new checkpoint (from DungeonSessions): give it a circle with the face of
-- the boss frame being fought, or of the unit the split was named after.
function Hud:NoteCheckpoint(entry, unit)
    if not entry or not entry.id then
        return nil
    end
    self.circles = self.circles or {}
    local circle = self.circles[entry.id]
    local engaged = self.engaged
    if not circle and entry.kind == "boss" and engaged and engaged.hasFace then
        local same = entry.name and engaged.name and string.lower(entry.name) == string.lower(engaged.name)
        if same then
            -- The boss frame's circle becomes the kill's: its face stays.
            circle = engaged
            self.engaged = nil
            self.engagedUnit = nil
            self.circles[entry.id] = circle
        end
    end
    circle = circle or self:circleFor(entry.id)
    if not circle then
        return nil
    end
    circle.name = entry.name
    setPortrait(circle, unit or unitFor(entry.name), entry.kind == "boss" and TEXTURES.boss or TEXTURES.split)
    return circle
end

local function updateHealth(unit)
    local bar = Hud.healthBar
    if not bar then
        return
    end
    if not unit or type(Globals.UnitHealth) ~= "function" or type(Globals.UnitHealthMax) ~= "function" then
        bar:Hide()
        return
    end
    local okMax, maximum = pcall(Globals.UnitHealthMax, unit)
    local ok, health = pcall(Globals.UnitHealth, unit)
    if not okMax or not ok then
        bar:Hide()
        return
    end
    -- Forever may hand add-ons secret combat numbers: a status bar can still
    -- show them, only arithmetic on them is barred, so nothing is computed.
    if pcall(bar.SetMinMaxValues, bar, 0, maximum) and pcall(bar.SetValue, bar, health) then
        bar:Show()
    else
        bar:Hide()
    end
end

-- The boss being fought: its face and health, re-read on unit events.
function Hud:RefreshEngaged(force)
    local run = self.run
    local engaged = run and run.engaged
    if not engaged or not self.engaged or self.Mode() == "minimized" then
        self.engagedUnit = nil
        updateHealth(nil)
        if self.engagedName then self.engagedName:Hide() end
        return
    end
    local unit = unitFor(engaged.name)
    if unit and (force or unit ~= self.engaged.unit or not self.engaged.hasFace) then
        setPortrait(self.engaged, unit, TEXTURES.boss)
    elseif not unit then
        setPortrait(self.engaged, nil, TEXTURES.boss)
    end
    self.engaged.name = engaged.name
    self.engagedUnit = unit
    setText(self.engagedName, "engagedName", engaged.name or "Boss")
    self.engagedName:Show()
    updateHealth(unit)
end

-- Lays the circles out left to right; oldest kills scroll off first, then
-- the dim ones, so the fight and the latest kills always fit.
function Hud:RefreshRow(run, mode, width)
    local row = self.row
    if not row then
        return 0
    end
    if mode == "minimized" then
        row:Hide()
        return 0
    end
    local entries = Hud.Portraits(run)
    local available = math.max(PORTRAIT, (width or 0) - PADDING * 2)
    local fit = math.max(1, math.floor((available + PORTRAIT_GAP) / (PORTRAIT + PORTRAIT_GAP)))
    while #entries > fit and entries[#entries].kind == "pending" do
        table.remove(entries)
    end
    while #entries > fit do
        table.remove(entries, 1)
    end
    self.rowEntries = entries
    local used = {}
    local x = 0
    for _, entry in ipairs(entries) do
        local circle
        if entry.kind == "engaged" then
            if not self.engaged then
                self.engaged = table.remove(self.pool or {}) or newCircle(row)
                resetCircle(self.engaged)
            end
            circle = self.engaged
        else
            circle = self:circleFor(entry.id)
            if entry.kind == "pending" then
                setPortrait(circle, nil, TEXTURES.pending)
            elseif not circle.hasFace and not circle.icon then
                setPortrait(circle, unitFor(entry.name), entry.kind == "boss" and TEXTURES.boss or TEXTURES.split)
            end
        end
        paintCircle(circle, entry)
        circle.frame:ClearAllPoints()
        circle.frame:SetPoint("LEFT", row, "LEFT", x, 0)
        circle.frame:Show()
        used[circle] = true
        x = x + PORTRAIT + PORTRAIT_GAP
    end
    for id, circle in pairs(self.circles or {}) do
        if not used[circle] then
            if id:find("^pending:") then
                resetCircle(circle)
                table.insert(self.pool, circle)
                self.circles[id] = nil
            else
                circle.frame:Hide()
            end
        end
    end
    if self.engaged and not used[self.engaged] then
        resetCircle(self.engaged)
        table.insert(self.pool, self.engaged)
        self.engaged = nil
    end
    if #entries == 0 then
        row:Hide()
        return 0
    end
    row:SetSize(math.max(PORTRAIT, x - PORTRAIT_GAP), PORTRAIT)
    row:Show()
    return PORTRAIT
end

-- Layout ----------------------------------------------------------------------------

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

local function show(widget, visible)
    if not widget then return end
    if visible then widget:Show() else widget:Hide() end
end

local function textHeight(widget, lines)
    local ok, height = pcall(widget.GetStringHeight, widget)
    if ok and tonumber(height) and height > 0 then
        return height
    end
    return lines * LINE_HEIGHT
end

-- Places every widget for the mode and fits the frame's height to them.
function Hud:Layout(mode, body)
    local frame = self.frame
    local value = prefs()
    if not frame or not value then
        return
    end
    local width = sizeFor(value, mode)
    local minimized = mode == "minimized"
    show(self.strip, not minimized)
    show(self.title, not minimized)
    show(self.state, not minimized)
    show(self.splitButton, not minimized)
    show(self.lessButton, not minimized)
    show(self.moreButton, mode ~= "expanded")
    self.lessButton:ClearAllPoints()
    self.moreButton:ClearAllPoints()
    self.lessButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -5)
    self.moreButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, minimized and -8 or -20)
    self.clock:ClearAllPoints()
    self.timerButton:ClearAllPoints()
    self.bodyText:ClearAllPoints()
    local height
    if minimized then
        self.clock:SetPoint("LEFT", frame, "LEFT", PADDING, 0)
        self.timerButton:SetSize(46, 18)
        self.timerButton:SetPoint("RIGHT", frame, "RIGHT", -22, 0)
        self.bodyText:SetPoint("LEFT", self.clock, "RIGHT", 8, 0)
        self.bodyText:SetPoint("RIGHT", self.timerButton, "LEFT", -6, 0)
        self.bodyText:SetJustifyV("MIDDLE")
        self.row:Hide()
        height = 30
    else
        local y = -6
        self.title:ClearAllPoints()
        self.title:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, y - 1)
        self.title:SetPoint("RIGHT", frame, "RIGHT", -24, 0)
        y = y - 20
        self.clock:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, y - 1)
        self.timerButton:SetSize(56, 20)
        self.timerButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING, y)
        self.splitButton:ClearAllPoints()
        self.splitButton:SetPoint("RIGHT", self.timerButton, "LEFT", -4, 0)
        y = y - 24
        self.state:ClearAllPoints()
        self.state:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, y)
        self.state:SetPoint("RIGHT", frame, "RIGHT", -PADDING, 0)
        y = y - LINE_HEIGHT - 2
        local rowHeight = self:RefreshRow(self.run, mode, width)
        if rowHeight > 0 then
            self.row:ClearAllPoints()
            self.row:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, y)
            y = y - rowHeight - 4
            if self.engagedUnit or (self.run and self.run.engaged) then
                self.engagedName:ClearAllPoints()
                self.engagedName:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, y)
                self.engagedName:SetPoint("RIGHT", frame, "RIGHT", -PADDING, 0)
                y = y - LINE_HEIGHT
                self.healthBar:ClearAllPoints()
                self.healthBar:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, y)
                self.healthBar:SetPoint("RIGHT", frame, "RIGHT", -PADDING, 0)
                y = y - 6 - 4
            end
        end
        self.bodyText:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, y)
        self.bodyText:SetPoint("RIGHT", frame, "RIGHT", -PADDING, 0)
        self.bodyText:SetJustifyV("TOP")
        y = y - textHeight(self.bodyText, #body) - 2
        height = -y + PADDING
    end
    frame:SetSize(width, height)
end

local function applyLayout(frame)
    local value = prefs()
    if not value then return end
    frame:ClearAllPoints()
    frame:SetPoint(value.point, Globals.UIParent, value.relativePoint, value.x, value.y)
    frame:SetSize(sizeFor(value, value.mode))
end

-- Unit events for the boss being fought: its face and health.
local function watchUnits(self)
    if self.events or type(Globals.CreateFrame) ~= "function" then
        return
    end
    local frame = Globals.CreateFrame("Frame")
    for _, event in ipairs({ "PLAYER_TARGET_CHANGED", "INSTANCE_ENCOUNTER_ENGAGE_UNIT" }) do
        pcall(frame.RegisterEvent, frame, event)
    end
    for _, event in ipairs({ "UNIT_PORTRAIT_UPDATE", "UNIT_HEALTH" }) do
        local ok, done = false, false
        if type(frame.RegisterUnitEvent) == "function" then
            ok, done = pcall(frame.RegisterUnitEvent, frame, event, "target", "boss1")
        end
        if not ok or done == false then
            pcall(frame.RegisterEvent, frame, event)
        end
    end
    frame:SetScript("OnEvent", function(_, event, unit)
        if not Hud.visible or not Hud.run or not Hud.run.engaged then
            return
        end
        if event == "UNIT_HEALTH" then
            if Hud.engagedUnit and (unit == nil or unit == Hud.engagedUnit) then
                updateHealth(Hud.engagedUnit)
            end
            return
        end
        Hud:RefreshEngaged(event == "UNIT_PORTRAIT_UPDATE")
    end)
    self.events = frame
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
        pcall(frame.SetResizeBounds, frame, 190, 22, 560, 700)
    end
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    if frame.SetBackdrop then
        pcall(frame.SetBackdrop, frame, {
            bgFile = TEXTURES.background,
            edgeFile = TEXTURES.border,
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        pcall(frame.SetBackdropColor, frame, 0.03, 0.035, 0.05, 0.82)
        pcall(frame.SetBackdropBorderColor, frame, 0.55, 0.47, 0.28, 0.65)
    end
    frame:SetScript("OnDragStart", function(current) current:StartMoving() end)
    frame:SetScript("OnDragStop", function(current)
        current:StopMovingOrSizing()
        savePosition(current)
    end)
    frame:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then Hud:CycleMode() end
    end)

    -- A faint strip behind the title.
    local strip = frame:CreateTexture(nil, "BORDER")
    strip:SetPoint("TOPLEFT", frame, "TOPLEFT", 3, -3)
    strip:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -3, -3)
    strip:SetHeight(22)
    strip:SetColorTexture(1, 0.88, 0.6, 0.07)
    self.strip = strip

    self.title = label(frame, "GameFontNormal")
    tint(self.title, COLORS.title)
    self.clock = label(frame, "GameFontNormalLarge")
    tint(self.clock, COLORS.ready)
    self.state = label(frame, "GameFontHighlightSmall")
    tint(self.state, COLORS.muted)
    self.bodyText = label(frame, "GameFontHighlightSmall")
    self.bodyText:SetJustifyV("TOP")
    self.bodyText:SetSpacing(3)

    self.timerButton = panelButton(frame, "Start", 56, function()
        GW.DungeonSessions.ToggleTimer()
        Hud:Refresh()
    end)
    self.splitButton = panelButton(frame, "Split", 50, function()
        GW.DungeonSessions.Split()
        Hud:Refresh()
    end)
    self.lessButton = smallButton(frame, "-", function() Hud:SetMode(MODES[math.max(1, MODE_INDEX[prefs().mode] - 1)]) end)
    self.moreButton = smallButton(frame, "+", function() Hud:SetMode(MODES[math.min(3, MODE_INDEX[prefs().mode] + 1)]) end)

    -- The boss row, the name of the boss being fought and its health.
    local row = Globals.CreateFrame("Frame", nil, frame)
    row:SetSize(PORTRAIT, PORTRAIT)
    self.row = row
    self.engagedName = label(frame, "GameFontHighlightSmall")
    tint(self.engagedName, COLORS.engaged)
    local bar = Globals.CreateFrame("StatusBar", nil, frame)
    bar:SetHeight(6)
    bar:SetStatusBarTexture(TEXTURES.bar)
    bar:SetStatusBarColor(0.85, 0.25, 0.2)
    local back = bar:CreateTexture(nil, "BACKGROUND")
    back:SetAllPoints(bar)
    back:SetColorTexture(0, 0, 0, 0.5)
    bar:Hide()
    self.healthBar = bar

    -- The corner grip changes the width; the height follows the content.
    local grip = Globals.CreateFrame("Button", nil, frame)
    grip:SetSize(14, 14)
    grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetScript("OnMouseDown", function() frame:StartSizing("RIGHT") end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        savePosition(frame)
        Hud.shownText = nil
        Hud:Refresh()
    end)

    watchUnits(self)
    self.frame = frame
    self.shown = {}
    self.circles, self.pool = {}, {}
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
        self.run = nil
        return false
    end
    local frame = self:Create()
    if not frame then
        return false
    end
    if self.runId ~= run.runId then
        self:ResetCircles()
        self.runId = run.runId
    end
    self.run = run
    local mode = value.mode
    local state = Hud.TimerState(run)
    self.lines = Hud.Lines(run, mode)
    local body = Hud.BodyLines(run, mode)
    setText(self.title, "title", titleText(run))
    if setText(self.clock, "clock", Hud.ClockText(run)) or self.shownState ~= state then
        tint(self.clock, COLORS[state] or COLORS.running)
        self.shownState = state
    end
    setText(self.state, "state", Hud.StateText(run))
    setText(self.timerButton, "timerButton", state == "running" and "Stop" or "Start")
    setText(self.bodyText, "body", table.concat(body, "\n"))
    self.shownText = table.concat(self.lines, "\n")
    -- Layout lays the boss row out (making the fight's circle), then the
    -- fight's face and health are read.
    self:Layout(mode, body)
    self:RefreshEngaged()
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
    self.shown = {}
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
    self.shown = {}
    self:Refresh()
end
