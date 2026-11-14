local _, GW = ...

-- The dungeon HUD. Shows inside party and raid instances while a run is
-- open, hides everywhere else. Three modes:
--   minimized  the clock with a status light, and an expand button
--   compact    (default) the dungeon, the clock with Start/Pause/Resume,
--              round boss frames, XP/hr and Wallet/hr, the objective
--   expanded   everything in compact plus Split, inside time, deaths, XP,
--              XP/hr, the wallet change and Wallet/hr (labelled: coin, not
--              item value or profit), the personal best and pace, splits,
--              objectives and End run
-- Boss frames: gold ring and greyed face when defeated, red ring for the
-- fight, an empty socket for each boss still ahead. Names come only from
-- the client (a kill, a split named after the target); none are guessed.
-- Nothing is shown that has no value yet: no "-/h", no "PB: none yet".
--
-- In combat it collapses to minimized by default and returns to the
-- player's mode afterwards; a mode picked during combat lasts until combat
-- ends. The × button hides it for the current run only. Hiding or
-- disabling it never stops the run from being recorded (DungeonSessions).
--
-- Drag to move (unless locked); the top-left corner is kept when the mode
-- changes, so it never jumps. Mode, position, scale, lock and the combat
-- preference are saved per account in GuildweaverDB.ui.dungeonHud.
--
-- Plain frames and textures: no secure template, no protected calls. It is
-- laid out only when a run event arrives (DungeonSessions calls Refresh);
-- once a second only the clock text is updated, from the last known timer.
GW.DungeonHud = GW.DungeonHud or {}

local Globals = _G or {}
local Hud = GW.DungeonHud
local UI, Theme = GW.UI, GW.Theme

local MODES = { "minimized", "compact", "expanded" }
local MODE_INDEX = { minimized = 1, compact = 2, expanded = 3 }
local WIDTHS = { minimized = 112, compact = 224, expanded = 272 }
local DEFAULTS = {
    enabled = true, mode = "compact", point = "TOPRIGHT", relativePoint = "TOPRIGHT", x = -220, y = -220,
    locked = false, collapseInCombat = true, scale = 1,
}
local SCALES = { 0.85, 1, 1.15, 1.3 }
local MAX_SPLITS = 6
local MAX_OBJECTIVES = 3
local MAX_BOSSES = 12
local MAX_STATS = 8
local PAD = 10
-- Boss frame diameter per mode, and the gap between frames.
local FACE_SIZES = { compact = 18, expanded = 22 }
local FACE = 22
local FACE_GAP = 4
-- Room for the "2/4" count at the end of the boss row.
local BOSS_LABEL = 30
-- A full refresh this often while visible, for numbers that change with
-- time alone (XP/hour). Everything else follows run events.
local FULL_REFRESH_TICKS = 15
local TEXTURES = {
    mask = "Interface\\CharacterFrame\\TempPortraitAlphaMask",
    boss = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull",
    split = "Interface\\Icons\\INV_Misc_PocketWatch_01",
    bar = "Interface\\Buttons\\WHITE8X8",
}
-- Theme colour per timer state and per boss-frame ring.
local STATE_COLORS = { ready = "textMuted", running = "text", paused = "warn", cleared = "gold" }
local RING_COLORS = { boss = "gold", split = "info", engaged = "bad", pending = "borderStrong" }
local GLYPH = { close = "\195\151", less = "\226\128\147", more = "+", dot = "\194\183" }

Hud.MODES = MODES
Hud.WIDTHS = WIDTHS
Hud.SCALES = SCALES
Hud.TEXTURES = TEXTURES
Hud.DEFAULTS = DEFAULTS

local function prefs()
    local db = GW.Store and GW.Store.GetDatabase and GW.Store.GetDatabase()
    if type(db) ~= "table" then
        return nil
    end
    db.ui = type(db.ui) == "table" and db.ui or {}
    local value = type(db.ui.dungeonHud) == "table" and db.ui.dungeonHud or {}
    -- 0.5 saved a bool "expanded".
    if value.mode == nil then
        value.mode = value.expanded and "expanded" or "compact"
    end
    if not MODE_INDEX[value.mode] then value.mode = "compact" end
    for key, default in pairs(DEFAULTS) do
        if value[key] == nil then value[key] = default end
    end
    -- Sizes from the resizable 0.6 tracker no longer apply.
    value.sizes, value.width, value.height = nil, nil, nil
    db.ui.dungeonHud = value
    return value
end
Hud.Prefs = prefs

local function now()
    local ok, value = pcall(Globals.GetTime)
    return ok and tonumber(value) or 0
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

-- "+1g 20s", "-35s 10c"; nil when unknown.
function Hud.FormatMoney(copper)
    if copper == nil then
        return nil
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
Hud.Commas = commas

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
    return Theme.Colorize(amount .. " " .. word, delta < 0 and "good" or "bad")
end

-- The run timer's state: ready (not started), running or stopped.
function Hud.TimerState(run)
    return run and run.timer and run.timer.state or "running"
end

-- What the player sees: ready, running, paused or cleared.
function Hud.DisplayState(run)
    local state = Hud.TimerState(run)
    if state == "stopped" then
        return run.timer and run.timer.stoppedBy == "complete" and "cleared" or "paused"
    end
    return state
end

-- The clock: the timed run, not the time since entry.
function Hud.ClockText(run)
    return Hud.FormatDuration(run and (run.timerSeconds or run.durationSeconds) or 0)
end

function Hud.TimerButtonText(run)
    local state = Hud.DisplayState(run)
    return state == "running" and "Pause" or (state == "ready" and "Start" or "Resume")
end

-- One short line about the timer or the fight.
function Hud.StateText(run)
    if run.engaged and Hud.TimerState(run) ~= "stopped" then
        return "Fighting " .. tostring(run.engaged.name or "a boss")
    end
    local state = Hud.DisplayState(run)
    if state == "ready" then
        return "Starts on your first pull"
    elseif state == "cleared" then
        return "Cleared " .. GLYPH.dot .. " timer stopped"
    elseif state == "paused" then
        return "Paused " .. GLYPH.dot .. " the run stays open"
    end
    return "Running"
end

local function bossText(run)
    return tostring(run.bossesDefeated or 0) .. (run.bossesTotal and ("/" .. run.bossesTotal) or "")
end

local function knowsBosses(run)
    return run.bossesTotal ~= nil or (run.bossesDefeated or 0) > 0
end

-- Boss progress for the pips: total (nil when the client gives none),
-- defeated, and whether a boss is being fought.
function Hud.BossProgress(run)
    if not run then return nil end
    return { total = run.bossesTotal, defeated = run.bossesDefeated or 0, engaged = run.engaged ~= nil }
end

local function xpText(run)
    if run.atLevelCap then
        return "max level"
    end
    return run.xpGained and run.xpGained > 0 and ("+" .. commas(run.xpGained)) or nil
end

local function rateText(run)
    if run.atLevelCap or not run.xpPerHour then
        return nil
    end
    return commas(run.xpPerHour) .. "/h"
end

local function titleText(run)
    local title = run.name or "Instance"
    if run.difficultyName then
        title = title .. " (" .. run.difficultyName .. ")"
    end
    return title
end

local function pbText(run, colour)
    if not run.pb then
        return nil
    end
    local pace = Hud.FormatPace(run.pace, colour)
    return Hud.FormatDuration(run.pb.seconds or run.pb.durationSeconds) .. (pace and ("  " .. pace) or "")
end

-- Wallet change per hour of the run's elapsed time, in copper. This is the
-- money that actually moved (looted coin, vendor sales, minus repairs and
-- purchases): it is not the value of items looted and not profit. Nil until
-- five minutes have passed (as XP/hour) or while the wallet has not moved.
function Hud.WalletPerHour(run)
    local net, seconds = run and run.netCopper, run and tonumber(run.durationSeconds) or 0
    if net == nil or net == 0 or seconds < 300 then
        return nil
    end
    return math.floor(net * 3600 / seconds + 0.5)
end

-- "+12g", "+4g 20s", "+35s", "-80c": an hourly rate without the noise.
function Hud.FormatRate(copper)
    if copper == nil then return nil end
    local sign = copper < 0 and "-" or "+"
    copper = math.abs(copper)
    local gold, silver = math.floor(copper / 10000), math.floor(copper / 100) % 100
    if gold >= 100 or (gold > 0 and silver == 0) then
        return sign .. commas(gold) .. "g"
    elseif gold > 0 then
        return string.format("%s%dg %ds", sign, gold, silver)
    elseif silver > 0 then
        return sign .. silver .. "s"
    end
    return sign .. (copper % 100) .. "c"
end

-- The compact HUD's rate row: XP/hr on the left, Wallet/hr on the right.
-- Each is nil when it has no value yet.
function Hud.Rates(run)
    local xp = (not run.atLevelCap and run.xpPerHour) and commas(run.xpPerHour) or nil
    return xp, Hud.FormatRate(Hud.WalletPerHour(run))
end

-- The run as text lines, for /gw dungeon and tests. Only what has a value.
function Hud.Lines(run, mode)
    if not run then
        return nil
    end
    if mode == true then mode = "expanded" elseif not MODE_INDEX[mode] then mode = "compact" end
    local state = Hud.DisplayState(run)
    local clock = Hud.ClockText(run) .. (state == "running" and "" or (" " .. state))
    if mode == "minimized" then
        return { clock .. (knowsBosses(run) and ("  Bosses " .. bossText(run)) or "") }
    end
    local lines = {
        titleText(run),
        string.format("%s   Bosses %s   Deaths %d", clock, bossText(run), run.deaths or 0),
    }
    local xp, rate = xpText(run), rateText(run)
    if mode == "expanded" then
        table.insert(lines, string.format("Inside %s of %s since entry", Hud.FormatDuration(run.insideSeconds or run.durationSeconds), Hud.FormatDuration(run.durationSeconds)))
    end
    if xp then
        local levels = mode == "expanded" and (run.levelUps or 0) > 0 and ("   " .. run.levelUps .. " level-up" .. (run.levelUps == 1 and "" or "s")) or ""
        table.insert(lines, "XP " .. xp .. (rate and ("   " .. rate) or "") .. levels)
    end
    local pb = pbText(run, true)
    if pb then
        table.insert(lines, "PB " .. pb)
    end
    if mode == "compact" then
        if run.objective then
            table.insert(lines, "Next: " .. tostring(run.objective.text))
        end
        return lines
    end
    local wallet = Hud.FormatMoney(run.netCopper)
    if wallet then
        table.insert(lines, "Wallet change " .. wallet .. " (not profit)")
    end
    local splits = run.splits or {}
    for index = math.max(1, #splits - MAX_SPLITS + 1), #splits do
        local split = splits[index]
        local pace = Hud.FormatPace(split.delta)
        table.insert(lines, string.format("%s  %s  +%s%s", Hud.FormatDuration(split.at), tostring(split.name),
            Hud.FormatDuration(split.split or 0), pace and ("  " .. pace) or ""))
    end
    local objectives = GW.DungeonObjectives and GW.DungeonObjectives.List and GW.DungeonObjectives.List() or {}
    for index = 1, math.min(MAX_OBJECTIVES, #objectives) do
        local objective = objectives[index]
        table.insert(lines, (objective.done and "[x] " or "[ ] ") .. tostring(objective.text))
    end
    return lines
end

-- The stat grid of the expanded HUD: { label, value, colour, tooltip }.
function Hud.Stats(run)
    local stats = {
        { "Inside", Hud.FormatDuration(run.insideSeconds or run.durationSeconds) },
    }
    if (run.deaths or 0) > 0 then
        table.insert(stats, { "Deaths", tostring(run.deaths), "warn" })
    end
    local xp = xpText(run)
    if xp then
        local levels = (run.levelUps or 0) > 0 and (" " .. GLYPH.dot .. " " .. run.levelUps .. " lvl") or ""
        table.insert(stats, { "XP", xp .. levels })
    end
    local xpRate, walletRate = Hud.Rates(run)
    if xpRate then
        table.insert(stats, { "XP/hr", xpRate })
    end
    if run.netCopper and run.netCopper ~= 0 then
        table.insert(stats, { "Wallet", Hud.FormatMoney(run.netCopper), run.netCopper < 0 and "bad" or "good",
            "Wallet change during the run: coin looted, vendor sales, minus repairs and purchases. Not item value, not profit." })
    end
    if walletRate then
        table.insert(stats, { "Wallet/hr", walletRate, nil,
            "Wallet change per hour of the run. Items looted are not counted until sold." })
    end
    if run.pb then
        table.insert(stats, { "Best", Hud.FormatDuration(run.pb.seconds or run.pb.durationSeconds), nil,
            "Your fastest verified clear here at this difficulty." })
    end
    return stats
end

-- The boss frames: one per checkpoint (a boss kill or a split), the boss
-- being fought, then one empty frame per boss the lockout still lists.
-- Nothing is named that the client did not name.
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
        for index = 1, math.min(MAX_BOSSES, remaining) do
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

-- Sets a widget's text only when it changed, counting redraws.
local function setText(widget, key, text)
    Hud.shown = Hud.shown or {}
    text = text or ""
    if Hud.shown[key] == text then
        return false
    end
    Hud.shown[key] = text
    widget:SetText(text)
    Hud.redraws = (Hud.redraws or 0) + 1
    return true
end

local show = UI.SetShown

function Hud.ShowTooltip(circle)
    local entry = circle.entry
    if not entry then
        return
    end
    if entry.kind == "pending" then
        -- The client names a boss only once it is fought: nothing is guessed.
        UI.ShowTooltip(circle.frame, "Boss ahead", { "Not defeated yet." }, "ANCHOR_TOP")
        return
    end
    local what = entry.kind == "boss" and "Defeated" or (entry.kind == "split" and "Split" or "Fighting since")
    UI.ShowTooltip(circle.frame, entry.name or "Boss", { what .. (entry.at and (" at " .. Hud.FormatDuration(entry.at)) or "") }, "ANCHOR_TOP")
end

-- A small round face: a coloured ring, the face inside. Its state lives in
-- this table, not on the frame.
local function newCircle(parent)
    local frame = Globals.CreateFrame("Button", nil, parent)
    frame:SetSize(FACE, FACE)
    local ring = frame:CreateTexture(nil, "BACKGROUND")
    ring:SetAllPoints(frame)
    ring:SetColorTexture(1, 1, 1, 1)
    local portrait = frame:CreateTexture(nil, "ARTWORK")
    portrait:SetPoint("TOPLEFT", frame, "TOPLEFT", 1.5, -1.5)
    portrait:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1.5, 1.5)
    if type(frame.CreateMaskTexture) == "function" and type(portrait.AddMaskTexture) == "function" then
        for _, texture in ipairs({ ring, portrait }) do
            local mask = frame:CreateMaskTexture()
            mask:SetTexture(TEXTURES.mask, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            mask:SetAllPoints(texture)
            texture:AddMaskTexture(mask)
        end
    end
    local circle = { frame = frame, ring = ring, portrait = portrait, hasFace = false }
    frame:SetScript("OnEnter", function() Hud.ShowTooltip(circle) end)
    frame:SetScript("OnLeave", UI.HideTooltip)
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
        pcall(circle.portrait.SetTexCoord, circle.portrait, 0.08, 0.92, 0.08, 0.92)
    end
    return false
end

-- A boss not reached yet: an empty dark socket in a faint ring. No icon,
-- no question mark.
local function setEmpty(circle)
    if circle.icon ~= "empty" then
        circle.icon = "empty"
        local rgb = Theme.colors.bgInset
        pcall(circle.portrait.SetColorTexture, circle.portrait, rgb[1], rgb[2], rgb[3], 1)
    end
end

-- Defeated: gold ring, the face greyed. Fighting: red ring, full colour.
-- Ahead: a faint ring around an empty socket. Splits: a blue ring.
local function paintCircle(circle, entry, size)
    circle.frame:SetSize(size, size)
    Theme.Tint(circle.ring, RING_COLORS[entry.kind] or "borderStrong", entry.kind == "pending" and 0.8 or 1)
    pcall(circle.portrait.SetDesaturated, circle.portrait, entry.kind == "boss")
    pcall(circle.portrait.SetAlpha, circle.portrait, entry.kind == "boss" and 0.8 or 1)
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
    local circle = self.circles[id] or table.remove(self.pool) or newCircle(self.bossRow)
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
            -- The fight's circle becomes the kill's: its face stays.
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

-- The boss being fought: its health, and its face in the expanded row.
function Hud:RefreshEngaged(force)
    local run = self.run
    local engaged = run and run.engaged
    if not engaged or self:DisplayMode() == "minimized" then
        self.engagedUnit = nil
        updateHealth(nil)
        return
    end
    local unit = unitFor(engaged.name)
    if self.engaged then
        if unit and (force or unit ~= self.engaged.unit or not self.engaged.hasFace) then
            setPortrait(self.engaged, unit, TEXTURES.boss)
        elseif not unit then
            setPortrait(self.engaged, nil, TEXTURES.boss)
        end
        self.engaged.name = engaged.name
    end
    self.engagedUnit = unit
    updateHealth(unit)
end

-- Lays the boss frames out left to right (compact and expanded): kills and
-- splits, the fight, then an empty frame per boss still ahead. When they do
-- not fit, frames ahead go first, then the oldest kills, so the fight and
-- the latest kills always show. Returns the row's height, 0 when empty.
function Hud:RefreshRow(run, mode, width)
    local row = self.bossRow
    if not row then
        return 0
    end
    local size = FACE_SIZES[mode] or FACE
    local entries = mode == "minimized" and {} or Hud.Portraits(run)
    local available = math.max(size, (width or WIDTHS[mode] or WIDTHS.expanded) - PAD * 2 - BOSS_LABEL)
    local fit = math.max(1, math.floor((available + FACE_GAP) / (size + FACE_GAP)))
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
                setEmpty(circle)
            elseif not circle.hasFace and (not circle.icon or circle.icon == "empty") then
                setPortrait(circle, unitFor(entry.name), entry.kind == "boss" and TEXTURES.boss or TEXTURES.split)
            end
        end
        paintCircle(circle, entry, size)
        circle.frame:ClearAllPoints()
        circle.frame:SetPoint("LEFT", row, "LEFT", x, 0)
        circle.frame:Show()
        used[circle] = true
        x = x + size + FACE_GAP
    end
    for id, circle in pairs(self.circles or {}) do
        if not used[circle] then
            if id:find("^pending:") then
                -- Frames ahead are cheap: back to the pool.
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
    local progress = Hud.BossProgress(run)
    setText(self.bossLabel, "bossLabel", progress.total and (progress.defeated .. "/" .. progress.total)
        or (progress.defeated > 0 and tostring(progress.defeated) or ""))
    if #entries == 0 then
        row:Hide()
        return 0
    end
    row.gwHeight = size
    return size
end

-- Frame ---------------------------------------------------------------------------

local function number(fn, frame)
    if not frame or type(frame[fn]) ~= "function" then return nil end
    local ok, value = pcall(frame[fn], frame)
    return ok and tonumber(value) or nil
end

-- Saves the position as the top-left corner, so a taller or shorter mode
-- grows downwards instead of moving the frame.
local function savePosition(frame)
    local value = prefs()
    if not value then return end
    local left, top = number("GetLeft", frame), number("GetTop", frame)
    if left and top then
        value.point, value.relativePoint, value.x, value.y = "TOPLEFT", "BOTTOMLEFT", math.floor(left + 0.5), math.floor(top + 0.5)
        frame:ClearAllPoints()
        frame:SetPoint(value.point, Globals.UIParent, value.relativePoint, value.x, value.y)
        return
    end
    local ok, point, _, relativePoint, x, y = pcall(frame.GetPoint, frame, 1)
    if ok and type(point) == "string" then
        value.point, value.relativePoint, value.x, value.y = point, relativePoint, x, y
    end
end
Hud.SavePosition = savePosition

local function applyPosition(frame)
    local value = prefs()
    if not value then return end
    frame:ClearAllPoints()
    frame:SetPoint(value.point, Globals.UIParent, value.relativePoint, value.x, value.y)
    pcall(frame.SetScale, frame, tonumber(value.scale) or 1)
end

local function row(parent, height)
    local frame = Globals.CreateFrame("Frame", nil, parent)
    frame:SetHeight(height)
    frame.gwHeight = height
    return frame
end

-- Unit and combat events: the fight's face and health, and the combat
-- collapse.
local function watchEvents(self)
    if self.events or type(Globals.CreateFrame) ~= "function" then
        return
    end
    local frame = Globals.CreateFrame("Frame")
    for _, event in ipairs({ "PLAYER_TARGET_CHANGED", "INSTANCE_ENCOUNTER_ENGAGE_UNIT", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }) do
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
        if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
            Hud:SetCombat(event == "PLAYER_REGEN_DISABLED")
            return
        end
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

local function openSettings()
    local main = GW.MainFrame
    if main and main.Open then main:Open("dungeon") end
end

function Hud:Create()
    if self.frame or type(Globals.CreateFrame) ~= "function" then
        return self.frame
    end
    local frame = Globals.CreateFrame("Frame", "GuildweaverDungeonHud", Globals.UIParent)
    -- Below dialogs and action-bar tooltips; clamped so it is never lost.
    frame:SetFrameStrata("LOW")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    Theme.Skin(frame, { 0.035, 0.043, 0.059, 0.86 }, "border")
    local accent = frame:CreateTexture(nil, "BORDER")
    accent:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
    accent:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
    accent:SetHeight(1)
    Theme.Fill(accent, "borderGold", 0.8)
    frame:SetScript("OnDragStart", function(current)
        local value = prefs()
        if value and not value.locked then current:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(current)
        current:StopMovingOrSizing()
        savePosition(current)
    end)
    frame:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then Hud:CycleMode() end
    end)
    frame:SetScript("OnEnter", function(current)
        if Hud:DisplayMode() == "minimized" and Hud.run then
            UI.ShowTooltip(current, titleText(Hud.run), { Hud.StateText(Hud.run), "Right-click or + to expand." }, "ANCHOR_BOTTOM")
        end
    end)
    frame:SetScript("OnLeave", UI.HideTooltip)

    -- Header: dungeon, difficulty, the mode and hide buttons.
    local header = row(frame, 18)
    self.header = header
    self.title = UI.Text(header, "title", "gold")
    self.title:SetPoint("LEFT", header, "LEFT", 0, 0)
    pcall(self.title.SetWordWrap, self.title, false)
    self.difficulty = UI.Text(header, "small", "textFaint")
    self.difficulty:SetPoint("LEFT", self.title, "RIGHT", 6, -1)
    self.closeButton = UI.IconButton(frame, GLYPH.close, { size = 16, tooltip = "Hide for this run",
        tooltipLines = { "The run is still recorded. Bring the HUD back from the minimap menu or the dashboard." },
        onClick = function() Hud:HideForRun() end })
    self.moreButton = UI.IconButton(frame, GLYPH.more, { size = 16, tooltip = "More detail",
        onClick = function() Hud:SetMode(MODES[math.min(3, MODE_INDEX[Hud:DisplayMode()] + 1)]) end })
    self.lessButton = UI.IconButton(frame, GLYPH.less, { size = 16, tooltip = "Less detail",
        onClick = function() Hud:SetMode(MODES[math.max(1, MODE_INDEX[Hud:DisplayMode()] - 1)]) end })

    -- The clock and the timer controls.
    local clockRow = row(frame, 30)
    self.clockRow = clockRow
    self.dot = UI.Dot(frame, 7)
    self.clock = UI.Text(frame, "clock", "textMuted")
    self.timerButton = UI.Button(clockRow, "Start", { width = 62, height = 20, variant = "primary",
        onClick = function()
            GW.DungeonSessions.ToggleTimer()
            Hud:Refresh()
        end })
    self.splitButton = UI.Button(clockRow, "Split", { width = 48, height = 20,
        tooltip = "Split", tooltipLines = { "Marks a checkpoint at the current time, named after your target when it is an NPC." },
        onClick = function()
            GW.DungeonSessions.Split()
            Hud:Refresh()
        end })

    -- What the timer is doing, or the fight with the boss's health.
    local stateRow = row(frame, 19)
    self.stateRow = stateRow
    self.state = UI.Text(stateRow, "small", "textMuted")
    self.state:SetPoint("TOPLEFT", stateRow, "TOPLEFT", 0, -1)
    self.state:SetPoint("RIGHT", stateRow, "RIGHT", 0, 0)
    pcall(self.state.SetWordWrap, self.state, false)
    local bar = Globals.CreateFrame("StatusBar", nil, stateRow)
    bar:SetHeight(3)
    bar:SetPoint("BOTTOMLEFT", stateRow, "BOTTOMLEFT", 0, 1)
    bar:SetPoint("BOTTOMRIGHT", stateRow, "BOTTOMRIGHT", 0, 1)
    pcall(bar.SetStatusBarTexture, bar, TEXTURES.bar)
    local bad = Theme.colors.bad
    pcall(bar.SetStatusBarColor, bar, bad[1], bad[2], bad[3], 0.9)
    local back = bar:CreateTexture(nil, "BACKGROUND")
    back:SetAllPoints(bar)
    Theme.Fill(back, "bgHover")
    bar:Hide()
    self.healthBar = bar

    -- Boss frames, with the count at the end of the row.
    local bossRow = row(frame, FACE_SIZES.compact)
    self.bossRow = bossRow
    self.bossLabel = UI.Text(bossRow, "small", "textMuted", "RIGHT")
    self.bossLabel:SetPoint("RIGHT", bossRow, "RIGHT", 0, 0)

    -- Compact: XP/hr on the left, Wallet/hr on the right.
    local ratesRow = row(frame, 16)
    self.ratesRow = ratesRow
    self.xpRate = UI.Text(ratesRow, "label", "text")
    self.xpRate:SetPoint("LEFT", ratesRow, "LEFT", 0, 0)
    self.walletRate = UI.Text(ratesRow, "label", "text", "RIGHT")
    self.walletRate:SetPoint("RIGHT", ratesRow, "RIGHT", 0, 0)
    ratesRow:EnableMouse(true)
    ratesRow:SetScript("OnEnter", function(current)
        UI.ShowTooltip(current, "Rates per hour of the run", {
            "XP/hr: experience gained per hour since you entered.",
            "Wallet/hr: coin looted and vendor sales minus repairs and purchases, per hour. Items you loot count only once sold; this is not profit.",
        }, "ANCHOR_BOTTOM")
    end)
    ratesRow:SetScript("OnLeave", UI.HideTooltip)

    -- Expanded: the stat grid, pace, splits, objectives.
    local statsRow = row(frame, 16 * math.ceil(MAX_STATS / 2))
    self.statsRow = statsRow
    self.stats = {}
    for index = 1, MAX_STATS do
        local cell = Globals.CreateFrame("Frame", nil, statsRow)
        cell:SetSize((WIDTHS.expanded - PAD * 2 - 12) / 2, 16)
        cell:SetPoint("TOPLEFT", statsRow, "TOPLEFT", ((index - 1) % 2) * ((WIDTHS.expanded - PAD * 2) / 2 + 6), -math.floor((index - 1) / 2) * 16)
        cell.label = UI.Text(cell, "caps", "textFaint")
        cell.label:SetPoint("LEFT", cell, "LEFT", 0, 0)
        cell.value = UI.Text(cell, "label", "text", "RIGHT")
        cell.value:SetPoint("RIGHT", cell, "RIGHT", 0, 0)
        cell:SetScript("OnEnter", function(current)
            if current.tip then UI.ShowTooltip(current, current.tipTitle, { current.tip }, "ANCHOR_TOP") end
        end)
        cell:SetScript("OnLeave", UI.HideTooltip)
        self.stats[index] = cell
    end
    local paceRow = row(frame, 16)
    self.paceRow = paceRow
    self.pace = UI.Text(paceRow, "label", "text")
    self.pace:SetPoint("LEFT", paceRow, "LEFT", 0, 0)
    self.pace:SetPoint("RIGHT", paceRow, "RIGHT", 0, 0)

    local function list(title, count)
        local block = row(frame, 18 + 15 * count)
        block.heading = UI.Text(block, "caps", "goldDim")
        block.heading:SetPoint("TOPLEFT", block, "TOPLEFT", 0, -2)
        block.heading:SetText(title)
        local rule = Theme.Rule(block, "border")
        rule:SetPoint("LEFT", block.heading, "RIGHT", 6, 0)
        rule:SetPoint("RIGHT", block, "RIGHT", 0, 0)
        block.rows = {}
        for index = 1, count do
            local left = UI.Text(block, "label", "text")
            left:SetPoint("TOPLEFT", block, "TOPLEFT", 0, -18 - (index - 1) * 15)
            left:SetPoint("RIGHT", block, "RIGHT", -84, 0)
            pcall(left.SetWordWrap, left, false)
            local right = UI.Text(block, "small", "textMuted", "RIGHT")
            right:SetPoint("TOPRIGHT", block, "TOPRIGHT", 0, -19 - (index - 1) * 15)
            block.rows[index] = { left = left, right = right }
        end
        return block
    end
    self.splitList = list("SPLITS", MAX_SPLITS)
    self.objectiveList = list("OBJECTIVES", MAX_OBJECTIVES)
    local hintRow = row(frame, 15)
    self.hintRow = hintRow
    self.hint = UI.Text(hintRow, "small", "textFaint")
    self.hint:SetPoint("LEFT", hintRow, "LEFT", 0, 0)
    self.hint:SetPoint("RIGHT", hintRow, "RIGHT", 0, 0)
    pcall(self.hint.SetWordWrap, self.hint, false)
    self.hint:SetText("Boss kills not reported here: Split at each boss.")
    -- Room for later sections (a loot wishlist): each is
    -- { key, height, refresh(frame, run) -> shown }. None ship yet.
    self.extraSections = self.extraSections or {}

    local footer = row(frame, 22)
    self.footer = footer
    self.endButton = UI.ConfirmButton(footer, "End run", "Click to end", { width = 78, height = 20,
        tooltip = "End run", tooltipLines = { "Saves this run as completed and closes it. Pause only stops the clock." },
        onClick = function()
            if GW.DungeonSessions.Finish() then
                GW.Print("Dungeon run saved as completed. It reaches the website after /reload or logout.")
            end
        end })
    self.endButton:SetPoint("LEFT", footer, "LEFT", 0, 0)
    self.optionsButton = UI.Button(footer, "Options", { width = 64, height = 20, variant = "ghost", onClick = openSettings })
    self.optionsButton:SetPoint("RIGHT", footer, "RIGHT", 0, 0)

    self.rows = { header, clockRow, stateRow, bossRow, ratesRow, statsRow, paceRow,
        self.splitList, self.objectiveList, hintRow, footer }

    watchEvents(self)
    self.frame = frame
    self.shown = {}
    self.circles, self.pool = self.circles or {}, self.pool or {}
    if self.inCombat == nil and type(Globals.InCombatLockdown) == "function" then
        local ok, value = pcall(Globals.InCombatLockdown)
        self.inCombat = ok and value == true
    end
    applyPosition(frame)
    frame:Hide()
    return frame
end

-- Fills every text for the mode. Returns which optional rows have content.
function Hud:Paint(run, mode)
    local state = Hud.DisplayState(run)
    local has = {}
    setText(self.title, "title", run.name or "Instance")
    setText(self.difficulty, "difficulty", mode == "expanded" and run.difficultyName or "")
    setText(self.clock, "clock", Hud.ClockText(run))
    if self.shownState ~= state then
        Theme.Tint(self.clock, STATE_COLORS[state] or "text")
        self.dot:SetStatus(state == "running" and "good" or (STATE_COLORS[state] or "textMuted"))
        self.shownState = state
    end
    self.timerButton:SetLabel(Hud.TimerButtonText(run))
    self.timerButton:SetVariant(state == "running" and "secondary" or "primary")

    local stateText = Hud.StateText(run)
    has.state = stateText ~= "Running" or run.engaged ~= nil
    setText(self.state, "state", stateText)
    Theme.Tint(self.state, run.engaged and "bad" or (state == "paused" and "warn" or (state == "cleared" and "gold" or "textMuted")))

    has.progress = knowsBosses(run) or #(run.splits or {}) > 0 or run.engaged ~= nil

    if mode == "compact" then
        local xp, wallet = Hud.Rates(run)
        local faint = Theme.Hex("textFaint")
        setText(self.xpRate, "xpRate", xp and (faint .. "XP/hr|r  " .. xp) or "")
        setText(self.walletRate, "walletRate", wallet and (faint .. "Wallet/hr|r  "
            .. Theme.Colorize(wallet, wallet:sub(1, 1) == "-" and "bad" or "goldBright")) or "")
        has.rates = xp ~= nil or wallet ~= nil
    end

    if mode == "expanded" then
        local stats = Hud.Stats(run)
        for index, cell in ipairs(self.stats) do
            local stat = stats[index]
            if stat then
                setText(cell.label, "statLabel" .. index, string.upper(stat[1]))
                setText(cell.value, "statValue" .. index, stat[2])
                Theme.Tint(cell.value, stat[3] or "text")
                cell.tipTitle, cell.tip = stat[1], stat[4]
                cell:Show()
            else
                cell:Hide()
            end
        end
        self.statsRow.gwHeight = 16 * math.max(1, math.ceil(#stats / 2))
        local pace = run.pb and Hud.FormatPace(run.pace)
        has.pace = pace ~= nil
        setText(self.pace, "pace", pace and ("Pace vs best  " .. pace) or "")

        local splits = run.splits or {}
        local first = math.max(1, #splits - MAX_SPLITS + 1)
        local shown = 0
        for index = first, #splits do
            shown = shown + 1
            local split, line = splits[index], self.splitList.rows[shown]
            setText(line.left, "splitL" .. shown, Theme.Colorize(Hud.FormatDuration(split.at), "textFaint") .. "  " .. tostring(split.name))
            local splitPace = Hud.FormatPace(split.delta)
            setText(line.right, "splitR" .. shown, "+" .. Hud.FormatDuration(split.split or 0) .. (splitPace and ("  " .. splitPace) or ""))
        end
        for index = shown + 1, MAX_SPLITS do
            setText(self.splitList.rows[index].left, "splitL" .. index, "")
            setText(self.splitList.rows[index].right, "splitR" .. index, "")
        end
        self.splitList.gwHeight = 18 + 15 * shown
        has.splits = shown > 0

        local objectives = GW.DungeonObjectives and GW.DungeonObjectives.List and GW.DungeonObjectives.List() or {}
        local count = math.min(MAX_OBJECTIVES, #objectives)
        for index = 1, MAX_OBJECTIVES do
            local objective, line = objectives[index], self.objectiveList.rows[index]
            if index <= count then
                setText(line.left, "objective" .. index, Theme.Colorize(GLYPH.dot, objective.done and "good" or "gold") .. " "
                    .. (objective.done and Theme.Colorize(objective.text, "textFaint") or tostring(objective.text)))
            else
                setText(line.left, "objective" .. index, "")
            end
            setText(line.right, "objectiveR" .. index, "")
        end
        self.objectiveList.gwHeight = 18 + 15 * count
        has.objectives = count > 0
        has.hint = not run.encounterEvents and #splits == 0
    else
        -- Compact: the current objective on the note line.
        local objective = run.objective and (Theme.Colorize("Next ", "goldDim") .. tostring(run.objective.text)) or nil
        setText(self.pace, "pace", objective or "")
        has.pace = objective ~= nil
    end
    return has
end

-- Places the rows for the mode and fits the frame's height to them.
function Hud:Layout(mode, has)
    local frame = self.frame
    local width = WIDTHS[mode]
    local minimized = mode == "minimized"
    if self.layoutMode ~= mode then
        Theme.Font(self.clock, minimized and "clockSmall" or (mode == "expanded" and "clock" or "clockMid"))
        Theme.Tint(self.clock, STATE_COLORS[self.shownState] or "text")
        self.layoutMode = mode
    end
    for _, current in ipairs(self.rows) do current:Hide() end
    for _, section in ipairs(self.extraSections) do
        if section.frame then section.frame:Hide() end
    end
    self.lessButton:ClearAllPoints()
    self.moreButton:ClearAllPoints()
    self.closeButton:ClearAllPoints()
    self.clock:ClearAllPoints()
    self.dot:ClearAllPoints()
    show(self.lessButton, not minimized)
    show(self.moreButton, mode ~= "expanded")
    show(self.closeButton, not minimized)
    show(self.splitButton, mode == "expanded")
    if minimized then
        self.dot:SetPoint("LEFT", frame, "LEFT", 9, 0)
        self.clock:SetPoint("LEFT", self.dot, "RIGHT", 7, 0)
        self.moreButton:SetPoint("RIGHT", frame, "RIGHT", -4, 0)
        self.dot:Show()
        frame:SetSize(width, 26)
        return
    end
    self.dot:Hide()
    self.closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -6)
    self.lessButton:SetPoint("RIGHT", self.closeButton, "LEFT", -1, 0)
    if mode ~= "expanded" then
        self.moreButton:SetPoint("RIGHT", self.lessButton, "LEFT", -1, 0)
    end
    pcall(self.title.SetWidth, self.title, width - PAD * 2 - (mode == "expanded" and 110 or 56))
    local list = { self.header, self.clockRow }
    if has.state then table.insert(list, self.stateRow) end
    if has.progress and self:RefreshRow(self.run, mode, width) > 0 then
        table.insert(list, self.bossRow)
    end
    if mode == "compact" then
        if has.rates then table.insert(list, self.ratesRow) end
        if has.pace then table.insert(list, self.paceRow) end
    else
        table.insert(list, self.statsRow)
        if has.pace then table.insert(list, self.paceRow) end
        if has.splits then table.insert(list, self.splitList) end
        if has.objectives then table.insert(list, self.objectiveList) end
        for _, section in ipairs(self.extraSections) do
            if section.refresh and section.frame and section.refresh(section.frame, self.run) then
                table.insert(list, section.frame)
            end
        end
        if has.hint then table.insert(list, self.hintRow) end
        table.insert(list, self.footer)
    end
    local y = -6
    for index, current in ipairs(list) do
        local gap = (index == 1 and 0) or (current == self.clockRow and 2) or ((current == self.splitList or current == self.objectiveList
            or current == self.footer or current == self.statsRow) and 8) or 3
        y = y - gap
        current:ClearAllPoints()
        current:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
        current:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
        current:SetHeight(current.gwHeight or 16)
        current:Show()
        y = y - (current.gwHeight or 16)
    end
    -- The clock sits in its row; the controls on its right.
    self.clock:SetPoint("LEFT", self.clockRow, "LEFT", 0, 0)
    self.timerButton:ClearAllPoints()
    self.timerButton:SetPoint("RIGHT", self.clockRow, "RIGHT", 0, 0)
    self.splitButton:ClearAllPoints()
    self.splitButton:SetPoint("RIGHT", self.timerButton, "LEFT", -4, 0)
    frame:SetSize(width, -y + 8)
end

local function stopTicker()
    if Hud.ticker then
        Hud.ticker:Cancel()
        Hud.ticker = nil
    end
end

-- Once a second while visible: the clock only, from the last known timer.
function Hud:Tick()
    if not self.visible or not self.run then
        return
    end
    self.ticks = (self.ticks or 0) + 1
    if self.ticks % FULL_REFRESH_TICKS == 0 then
        self:Refresh()
        return
    end
    local seconds = (self.clockBase or 0) + (self.clockRunning and math.max(0, now() - (self.clockAt or now())) or 0)
    setText(self.clock, "clock", Hud.FormatDuration(seconds))
end

-- The mode on screen: the saved one, minimized during combat when the
-- player wants that, or what they picked during this fight.
function Hud:DisplayMode()
    local value = prefs()
    local mode = value and value.mode or "compact"
    if self.inCombat then
        if self.combatMode then return self.combatMode end
        if value and value.collapseInCombat then return "minimized" end
    end
    return mode
end

function Hud:SetCombat(inCombat)
    self.inCombat = inCombat == true
    if not self.inCombat then
        self.combatMode = nil
    end
    if self.visible then self:Refresh() end
end

function Hud.IsHiddenForRun()
    local value = prefs()
    local run = GW.DungeonSessions and GW.DungeonSessions.Current and GW.DungeonSessions.Current() or nil
    return value ~= nil and run ~= nil and value.hiddenRunId ~= nil and value.hiddenRunId == run.runId
end

-- Shows the HUD inside an instance with an open run, hides it otherwise.
function Hud:Refresh()
    local value = prefs()
    local run = GW.DungeonSessions and GW.DungeonSessions.Current and GW.DungeonSessions.Current() or nil
    local visible = value and value.enabled and run and run.inside and value.hiddenRunId ~= run.runId
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
    local mode = self:DisplayMode()
    self.lines = Hud.Lines(run, mode)
    self.shownText = table.concat(self.lines, "\n")
    local has = self:Paint(run, mode)
    self:Layout(mode, has)
    self:RefreshEngaged()
    self.clockBase = run.timerSeconds or run.durationSeconds or 0
    self.clockAt = now()
    self.clockRunning = Hud.TimerState(run) == "running"
    if not self.visible then
        frame:Show()
        self.visible = true
    end
    if not self.ticker and Globals.C_Timer and type(Globals.C_Timer.NewTicker) == "function" then
        self.ticks = 0
        self.ticker = Globals.C_Timer.NewTicker(1, function() Hud:Tick() end)
    end
    return true
end

-- Preferences ------------------------------------------------------------------------

function Hud:SetEnabled(enabled)
    local value = prefs()
    if not value then return false end
    value.enabled = enabled == true
    if value.enabled then value.hiddenRunId = nil end
    self:Refresh()
    return value.enabled
end

function Hud.IsEnabled()
    local value = prefs()
    return value ~= nil and value.enabled == true
end

-- Turns the HUD on and shows it now if a run is open.
function Hud:ShowNow()
    return self:SetEnabled(true)
end

-- The × button: hidden until this run ends. The run is still recorded.
function Hud:HideForRun()
    local value = prefs()
    local run = self.run or (GW.DungeonSessions and GW.DungeonSessions.Current())
    if not value or not run then return false end
    value.hiddenRunId = run.runId
    self:Refresh()
    GW.Print("Dungeon HUD hidden for this run; the run is still recorded. The minimap menu or /gw dungeon hud on brings it back.")
    return true
end

-- The saved (out-of-combat) mode.
function Hud.Mode()
    local value = prefs()
    return value and value.mode or "compact"
end

-- Picks a mode. During a combat collapse the pick lasts until combat ends;
-- otherwise it is saved.
function Hud:SetMode(mode)
    local value = prefs()
    if not value or not MODE_INDEX[mode] then return nil end
    if self.inCombat and value.collapseInCombat then
        self.combatMode = mode
    else
        value.mode = mode
        value.expanded = mode == "expanded"
        self.combatMode = nil
    end
    self.shown = {}
    self:Refresh()
    return mode
end

-- minimized → compact → expanded → minimized.
function Hud:CycleMode()
    local current = MODE_INDEX[self:DisplayMode()] or 2
    return self:SetMode(MODES[current % #MODES + 1])
end

-- compact ↔ expanded.
function Hud:ToggleExpanded()
    return self:SetMode(self:DisplayMode() == "expanded" and "compact" or "expanded")
end

function Hud:SetLocked(locked)
    local value = prefs()
    if value then value.locked = locked == true end
    if self.frame then pcall(self.frame.SetMovable, self.frame, locked ~= true) end
end

function Hud.IsLocked()
    local value = prefs()
    return value ~= nil and value.locked == true
end

function Hud:SetCollapseInCombat(collapse)
    local value = prefs()
    if not value then return end
    value.collapseInCombat = collapse == true
    if self.visible then self:Refresh() end
end

function Hud.CollapsesInCombat()
    local value = prefs()
    return value ~= nil and value.collapseInCombat == true
end

function Hud.Scale()
    local value = prefs()
    return value and tonumber(value.scale) or 1
end

-- Scales the HUD around its top-left corner.
function Hud:SetScale(scale)
    local value = prefs()
    scale = tonumber(scale)
    if not value or not scale or scale <= 0 then return end
    local old = tonumber(value.scale) or 1
    if value.point == "TOPLEFT" and value.relativePoint == "BOTTOMLEFT" and tonumber(value.x) and tonumber(value.y) then
        value.x = math.floor(value.x * old / scale + 0.5)
        value.y = math.floor(value.y * old / scale + 0.5)
    end
    value.scale = scale
    if self.frame then applyPosition(self.frame) end
end

function Hud:ResetPosition()
    local value = prefs()
    if not value then return end
    value.point, value.relativePoint, value.x, value.y = DEFAULTS.point, DEFAULTS.relativePoint, DEFAULTS.x, DEFAULTS.y
    value.scale = DEFAULTS.scale
    if self.frame then applyPosition(self.frame) end
    self.shown = {}
    self:Refresh()
end
