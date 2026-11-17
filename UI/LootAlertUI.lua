local _, GW = ...

-- How a loot alert is shown. Two presenters, both fed the same alert by
-- LootRolls.Present, so a roll is announced once however it was detected:
--
--   Native glow   a soft halo around the game's own Need/Greed frame for
--                 that roll, in the alert's colour. Best effort: when the
--                 frame cannot be found (another loot add-on replaced it,
--                 or the client names it differently), nothing happens
--                 and nothing breaks.
--   Notice        Guildweaver's own: the item's icon, name and reason on a
--                 small strip under the dungeon HUD, with the HUD glowing;
--                 or, when the HUD is not on screen, a small toast of its
--                 own (or just the chime, if the player turned toasts off).
--                 This one never depends on the game's frames.
--
-- Everything is passive. The halo sits on its own frame behind the roll
-- frame and outside its edges; nothing is parented to, hooked into or
-- changed on the game's frame, no mouse input is taken, and no button is
-- ever touched. The HUD's mode is never changed and nothing is opened.
GW.LootAlertUI = GW.LootAlertUI or {}

local Notice = GW.LootAlertUI
local Globals = _G or {}
local UI, Theme = GW.UI, GW.Theme

Notice.SECONDS = 9
Notice.MAX_ROWS = 3
Notice.WIDTH = 236
Notice.ROW = 34
local FIND_RETRIES = { 0.05, 0.3, 1 }
local MAX_ROLL_FRAMES = 8
local WATCH_SECONDS = 0.25

local function after(seconds, callback)
    local timer = Globals.C_Timer
    if type(timer) == "table" and type(timer.After) == "function" then
        timer.After(seconds, callback)
        return true
    end
    return false
end

local function shown(frame)
    if type(frame) ~= "table" or type(frame.IsShown) ~= "function" then return false end
    local ok, value = pcall(frame.IsShown, frame)
    return ok and value == true
end

-- Native roll frame ------------------------------------------------------------------------

-- The game's frame showing this roll: GroupLootFrame1..N, each with the
-- rollID it is showing. Nothing else is assumed about it.
function Notice.FindRollFrame(rollId)
    local limit = tonumber(Globals.NUM_GROUP_LOOT_FRAMES) or 4
    for index = 1, math.min(MAX_ROLL_FRAMES, math.max(limit, 4)) do
        local frame = Globals["GroupLootFrame" .. index]
        if type(frame) == "table" and rawget(frame, "rollID") == rollId then
            local forbidden = false
            if type(frame.IsForbidden) == "function" then
                local ok, value = pcall(frame.IsForbidden, frame)
                forbidden = not ok or value == true
            end
            if not forbidden and shown(frame) then return frame end
        end
    end
    return nil
end

local pool = {}

local function takeHalo()
    local halo = table.remove(pool)
    if halo then return halo end
    return Theme.Halo()
end

-- Lets go of a roll's glow. The halo is reused for the next roll.
local function releaseGlow(roll)
    local halo = roll.halo
    if not halo then return end
    roll.halo = nil
    pcall(halo.frame.SetScript, halo.frame, "OnUpdate", nil)
    halo:Stop()
    table.insert(pool, halo)
end

local function glow(roll, attempt)
    if roll.halo or roll.endedAt or not roll.alert then return end
    local ok, frame = pcall(Notice.FindRollFrame, roll.rollId)
    frame = ok and frame or nil
    if not frame then
        local wait = FIND_RETRIES[attempt]
        if wait then after(wait, function() glow(roll, attempt + 1) end) end
        return
    end
    local halo = takeHalo()
    if not halo then return end
    halo:SetColor(Theme.AlertColor(roll.alert.category))
    if not pcall(halo.Attach, halo, frame) then
        table.insert(pool, halo)
        return
    end
    halo:Pulse()
    roll.halo = halo
    roll.nativeGlow = true
    -- The game reuses these frames: when this one hides or shows another
    -- roll, the glow goes. A light check a few times a second, only while
    -- a glow is lit.
    local elapsed = 0
    pcall(halo.frame.SetScript, halo.frame, "OnUpdate", function(_, delta)
        elapsed = elapsed + (tonumber(delta) or 0)
        if elapsed < WATCH_SECONDS then return end
        elapsed = 0
        if roll.halo ~= halo or not shown(frame) or rawget(frame, "rollID") ~= roll.rollId then
            releaseGlow(roll)
        end
    end)
end

-- The notice -------------------------------------------------------------------------------

local function hud()
    local tracker = GW.DungeonHud
    if tracker and tracker.visible and tracker.frame and shown(tracker.frame) then return tracker.frame end
    return nil
end

local function qualityColor(quality)
    local colors = Globals.ITEM_QUALITY_COLORS
    local color = type(colors) == "table" and colors[quality]
    if type(color) == "table" and tonumber(color.r) then return { color.r, color.g, color.b, 1 } end
    return Theme.Color("text")
end

local function newRow(parent, index)
    local row = Globals.CreateFrame("Frame", nil, parent)
    row:SetHeight(Notice.ROW)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * Notice.ROW)
    row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
    -- The category's colour as a bar down the left edge.
    row.bar = row:CreateTexture(nil, "ARTWORK")
    row.bar:SetPoint("TOPLEFT", row, "TOPLEFT", 1, -1)
    row.bar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 1, 1)
    row.bar:SetWidth(3)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(22, 22)
    row.icon:SetPoint("LEFT", row, "LEFT", 10, 0)
    pcall(row.icon.SetTexCoord, row.icon, 0.07, 0.93, 0.07, 0.93)
    row.name = UI.Text(row, "label", "text")
    row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 7, 1)
    row.name:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    pcall(row.name.SetWordWrap, row.name, false)
    row.reason = UI.Text(row, "small", "textMuted")
    row.reason:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
    row.reason:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    pcall(row.reason.SetWordWrap, row.reason, false)
    return row
end

function Notice:Create()
    if self.frame or type(Globals.CreateFrame) ~= "function" then return self.frame end
    local frame = Globals.CreateFrame("Frame", "GuildweaverLootNotice", Globals.UIParent)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    -- Seen, not clicked: it never takes the mouse from the game.
    pcall(frame.EnableMouse, frame, false)
    frame:SetWidth(Notice.WIDTH)
    Theme.Skin(frame, { 0.035, 0.043, 0.059, 0.92 }, "border")
    frame:Hide()
    self.rows = {}
    for index = 1, Notice.MAX_ROWS do
        self.rows[index] = newRow(frame, index)
    end
    self.halo = Theme.Halo(12)
    self.hudHalo = Theme.Halo(12)
    self.frame = frame
    return frame
end

-- Lays the strip out for the entries now showing: under the HUD when it
-- is on screen, else on its own near the top of the screen.
function Notice:Layout()
    local frame = self.frame
    if not frame then return end
    local entries = self.entries or {}
    if #entries == 0 then
        frame:Hide()
        if self.halo then self.halo:Stop() end
        if self.hudHalo then self.hudHalo:Stop() end
        self.anchoredTo = nil
        return
    end
    local tracker = hud()
    frame:ClearAllPoints()
    if tracker then
        frame:SetPoint("TOPLEFT", tracker, "BOTTOMLEFT", 0, -6)
        self.anchoredTo = "hud"
    else
        frame:SetPoint("TOP", Globals.UIParent, "TOP", 0, -150)
        self.anchoredTo = "screen"
    end
    frame:SetHeight(#entries * Notice.ROW)
    for index, row in ipairs(self.rows) do
        local entry = entries[index]
        if entry then
            local color = Theme.AlertColor(entry.alert.category)
            Theme.Fill(row.bar, color)
            pcall(row.icon.SetTexture, row.icon, entry.item.texture or "Interface\\Icons\\INV_Misc_QuestionMark")
            row.name:SetText(entry.item.name or ("Item " .. tostring(entry.item.itemId)))
            Theme.Tint(row.name, qualityColor(entry.item.quality))
            local title, detail = GW.LootAlerts.Describe(entry.alert)
            row.reason:SetText(Theme.Colorize(title or "", color) .. (detail and detail ~= "" and ("  " .. detail) or ""))
            row.text = (title or "") .. (detail and detail ~= "" and (" | " .. detail) or "")
            row:Show()
        else
            row:Hide()
        end
    end
    -- The newest alert colours the glows.
    local color = Theme.AlertColor(entries[1].alert.category)
    Theme.SetBorder(frame, color, 0.9)
    frame:Show()
    if self.halo then
        self.halo:SetColor(color)
        pcall(self.halo.Attach, self.halo, frame)
        self.halo:Pulse()
    end
    if self.hudHalo then
        if tracker then
            self.hudHalo:SetColor(color)
            pcall(self.hudHalo.Attach, self.hudHalo, tracker)
            self.hudHalo:Pulse()
        else
            self.hudHalo:Stop()
        end
    end
end

local function removeEntry(roll)
    local entries = Notice.entries or {}
    for index, entry in ipairs(entries) do
        if entry == roll then
            table.remove(entries, index)
            Notice:Layout()
            return true
        end
    end
    return false
end

-- Shows the roll's notice (newest first), unless the HUD is off screen and
-- the player turned toasts off: then the chime alone tells them.
local function notice(roll)
    local prefs = GW.LootAlerts.Prefs()
    if not hud() and prefs.toast == false then
        roll.noticeSkipped = true
        return false
    end
    if not Notice:Create() then return false end
    Notice.entries = Notice.entries or {}
    table.insert(Notice.entries, 1, roll)
    while #Notice.entries > Notice.MAX_ROWS do table.remove(Notice.entries) end
    Notice:Layout()
    roll.noticeShown = true
    after(Notice.SECONDS, function() removeEntry(roll) end)
    return true
end

-- Presenting -------------------------------------------------------------------------------

-- Called once per roll that has an alert.
function Notice.Present(roll)
    if type(roll) ~= "table" or not roll.alert or roll.presented then return false end
    roll.presented = true
    pcall(glow, roll, 1)
    pcall(notice, roll)
    return true
end

-- Called when the roll ends or disappears.
function Notice.Release(roll)
    if type(roll) ~= "table" then return end
    releaseGlow(roll)
    removeEntry(roll)
end

-- /gw loot test: shows what an alert of each category looks like, with a
-- made-up item. Nothing is rolled and nothing is recorded.
function Notice.Preview(category)
    local samples = {
        wishlist = { item = { itemId = 0, name = "Wishlist item (preview)", quality = 3, texture = "Interface\\Icons\\INV_Sword_27" },
            alert = { category = "wishlist", primary = { id = "wishlist", wishPriority = "high", note = "Your note shows here" },
                reasons = { { id = "wishlist" } } } },
        valuable_boe = { item = { itemId = 0, name = "Valuable BoE (preview)", quality = 2, texture = "Interface\\Icons\\INV_Misc_Coin_02" },
            alert = { category = "valuable_boe", primary = { id = "valuable_boe" }, reasons = { { id = "valuable_boe" } },
                value = 254300, valueAge = 7200, valueConfidence = "medium" } },
    }
    local sample = samples[category] or samples.wishlist
    local roll = { rollId = -1, preview = true, item = sample.item, alert = sample.alert }
    pcall(notice, roll)
    GW.LootAlerts.PlayChime(true)
    return roll
end
