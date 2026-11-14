local _, GW = ...

-- Guildweaver's controls, built on GW.Theme: windows, buttons, toggles,
-- segmented choices, sections, status dots and a small popup menu. Plain
-- frames and textures only: no secure templates and no protected calls, so
-- every control works the same in and out of combat.
GW.UI = GW.UI or {}

local Globals = _G or {}
local UI = GW.UI
local Theme = GW.Theme

local function create(frameType, parent, name, template)
    return Globals.CreateFrame(frameType, name, parent or Globals.UIParent, template)
end
UI.CreateFrame = create

local function setShown(widget, shown)
    if not widget then return end
    if shown then widget:Show() else widget:Hide() end
end
UI.SetShown = setShown

-- Text ----------------------------------------------------------------------------

function UI.Text(parent, role, color, justify)
    local text = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    Theme.Font(text, role or "body", color or "text")
    pcall(text.SetJustifyH, text, justify or "LEFT")
    pcall(text.SetJustifyV, text, "MIDDLE")
    return text
end

-- Sets a font string's text only when it changed. Returns true on change.
function UI.SetText(widget, text)
    text = text or ""
    if widget.gwText == text then
        return false
    end
    widget.gwText = text
    widget:SetText(text)
    return true
end

-- Tooltips ------------------------------------------------------------------------

function UI.ShowTooltip(owner, title, lines, anchor)
    local tooltip = Globals.GameTooltip
    if not tooltip or type(tooltip.SetOwner) ~= "function" then
        return
    end
    pcall(tooltip.SetOwner, tooltip, owner, anchor or "ANCHOR_RIGHT")
    pcall(tooltip.ClearLines, tooltip)
    local gold = Theme.colors.goldBright
    pcall(tooltip.AddLine, tooltip, title, gold[1], gold[2], gold[3])
    for _, line in ipairs(lines or {}) do
        local rgb = Theme.colors.textMuted
        pcall(tooltip.AddLine, tooltip, line, rgb[1], rgb[2], rgb[3], true)
    end
    pcall(tooltip.Show, tooltip)
end

function UI.HideTooltip()
    local tooltip = Globals.GameTooltip
    if tooltip and type(tooltip.Hide) == "function" then
        pcall(tooltip.Hide, tooltip)
    end
end

local function tooltipFor(frame, title, lines)
    if not title then return end
    frame:HookScript("OnEnter", function(self) UI.ShowTooltip(self, title, type(lines) == "function" and lines() or lines) end)
    frame:HookScript("OnLeave", UI.HideTooltip)
end

-- Buttons -------------------------------------------------------------------------

-- Variants: primary (gold), secondary (raised), ghost (text only), danger.
local VARIANTS = {
    primary = { bg = "bgActive", hover = { 0.20, 0.17, 0.11, 1 }, border = "borderGold", hoverBorder = "gold", text = "goldBright" },
    secondary = { bg = "bgRaised", hover = "bgHover", border = "border", hoverBorder = "borderStrong", text = "text" },
    ghost = { bg = { 0, 0, 0, 0 }, hover = "bgHover", border = { 0, 0, 0, 0 }, hoverBorder = { 0, 0, 0, 0 }, text = "textMuted", hoverText = "text" },
    danger = { bg = "bgRaised", hover = { 0.20, 0.09, 0.08, 1 }, border = "border", hoverBorder = "bad", text = "bad" },
}

local function paintButton(button)
    local style = VARIANTS[button.gwVariant] or VARIANTS.secondary
    local hover = button.gwHover and button.gwEnabled
    local active = button.gwActive
    Theme.SetBackground(button, active and "bgActive" or (hover and style.hover or style.bg))
    Theme.SetBorder(button, active and "borderGold" or (hover and style.hoverBorder or style.border))
    local color = not button.gwEnabled and "textFaint" or (active and "goldBright") or (hover and style.hoverText) or style.text
    Theme.Tint(button.label, color)
    if button.icon then
        pcall(button.icon.SetDesaturated, button.icon, not button.gwEnabled)
        pcall(button.icon.SetAlpha, button.icon, button.gwEnabled and 1 or 0.4)
    end
end

-- opts: width, height, variant, onClick, tooltip, tooltipLines, role
function UI.Button(parent, label, opts)
    opts = opts or {}
    local button = create("Button", parent)
    button:SetSize(opts.width or 96, opts.height or 22)
    Theme.Skin(button)
    button.label = UI.Text(button, opts.role or "button", "text", "CENTER")
    button.label:SetPoint("LEFT", button, "LEFT", 6, 0)
    button.label:SetPoint("RIGHT", button, "RIGHT", -6, 0)
    pcall(button.label.SetWordWrap, button.label, false)
    button.gwVariant = opts.variant or "secondary"
    button.gwEnabled = true
    -- State lives in explicit fields, false rather than nil.
    button.gwHover, button.gwActive, button.gwArmedAt = false, false, false
    button.gwOnClick = opts.onClick
    pcall(button.RegisterForClicks, button, "LeftButtonUp")
    button:SetScript("OnEnter", function(self) self.gwHover = true; paintButton(self) end)
    button:SetScript("OnLeave", function(self) self.gwHover = false; paintButton(self) end)
    -- The closure, not self: tests and other code may call the script bare.
    button:SetScript("OnClick", function(_, mouse)
        if button.gwEnabled and button.gwOnClick then
            button.gwOnClick(button, mouse)
        end
    end)
    function button:SetLabel(text) UI.SetText(self.label, text) end
    function button:GetLabel() return self.label.gwText end
    function button:SetVariant(variant) self.gwVariant = variant; paintButton(self) end
    function button:SetActive(active) self.gwActive = active == true; paintButton(self) end
    function button:SetEnabled(enabled)
        self.gwEnabled = enabled ~= false
        if self.EnableMouse then pcall(self.EnableMouse, self, true) end
        paintButton(self)
    end
    function button:IsEnabled() return self.gwEnabled end
    function button:SetOnClick(callback) self.gwOnClick = callback end
    function button:Click() if self.gwEnabled and self.gwOnClick then self.gwOnClick(self, "LeftButton") end end
    button:SetLabel(label or "")
    tooltipFor(button, opts.tooltip, opts.tooltipLines)
    paintButton(button)
    return button
end

-- A small square ghost button with a single glyph (× – + ‹).
function UI.IconButton(parent, glyph, opts)
    opts = opts or {}
    local button = UI.Button(parent, glyph, { width = opts.size or 18, height = opts.size or 18, variant = "ghost",
        onClick = opts.onClick, tooltip = opts.tooltip, tooltipLines = opts.tooltipLines, role = opts.role or "label" })
    button.label:ClearAllPoints()
    button.label:SetPoint("CENTER", button, "CENTER", 0, 0)
    return button
end

-- A button that asks to be clicked twice: the first click arms it for a few
-- seconds and changes its label, the second runs the action. For actions
-- that cannot be undone (end a run, reload the UI), without a dialog.
function UI.ConfirmButton(parent, label, confirmLabel, opts)
    opts = opts or {}
    local action = opts.onClick
    local button
    button = UI.Button(parent, label, {
        width = opts.width, height = opts.height, variant = opts.variant or "secondary", tooltip = opts.tooltip, tooltipLines = opts.tooltipLines,
        onClick = function()
            local now = tonumber(Globals.GetTime and Globals.GetTime()) or 0
            if button.gwArmedAt and now - button.gwArmedAt <= (opts.window or 4) then
                button.gwArmedAt = false
                button:SetLabel(label)
                button:SetVariant(opts.variant or "secondary")
                if action then action(button) end
                return
            end
            button.gwArmedAt = now
            button:SetLabel(confirmLabel)
            button:SetVariant("danger")
            if Globals.C_Timer and type(Globals.C_Timer.After) == "function" then
                local armed = now
                Globals.C_Timer.After(opts.window or 4, function()
                    if button.gwArmedAt == armed then
                        button.gwArmedAt = false
                        button:SetLabel(label)
                        button:SetVariant(opts.variant or "secondary")
                    end
                end)
            end
        end,
    })
    function button:Disarm()
        self.gwArmedAt = false
        self:SetLabel(label)
        self:SetVariant(opts.variant or "secondary")
    end
    return button
end

-- Toggles ---------------------------------------------------------------------------

local function paintToggle(toggle)
    local on = toggle.gwValue == true
    Theme.SetBackground(toggle.track, on and { 0.30, 0.25, 0.14, 1 } or "bgInset")
    Theme.SetBorder(toggle.track, on and "gold" or (toggle.gwHover and "borderStrong" or "border"))
    Theme.Fill(toggle.knob, on and "goldBright" or "textMuted")
    toggle.knob:ClearAllPoints()
    toggle.knob:SetPoint("CENTER", toggle.track, on and "RIGHT" or "LEFT", on and -7 or 7, 0)
    Theme.Tint(toggle.title, toggle.gwHover and "goldBright" or "text")
end

-- A labelled switch row. get() returns the value, set(value) stores it.
function UI.Toggle(parent, title, description, get, set, width)
    local toggle = create("Button", parent)
    toggle:SetSize(width or 360, description and 38 or 24)
    toggle.title = UI.Text(toggle, "label", "text")
    toggle.title:SetPoint("TOPLEFT", toggle, "TOPLEFT", 0, description and -3 or -5)
    toggle.title:SetPoint("RIGHT", toggle, "RIGHT", -46, 0)
    toggle.title:SetText(title)
    if description then
        toggle.description = UI.Text(toggle, "small", "textMuted")
        toggle.description:SetPoint("TOPLEFT", toggle.title, "BOTTOMLEFT", 0, -3)
        toggle.description:SetPoint("RIGHT", toggle, "RIGHT", -46, 0)
        pcall(toggle.description.SetWordWrap, toggle.description, false)
        toggle.description:SetText(description)
    end
    local track = create("Frame", toggle)
    track:SetSize(30, 14)
    track:SetPoint("TOPRIGHT", toggle, "TOPRIGHT", -2, -5)
    Theme.Skin(track, "bgInset")
    toggle.track = track
    local knob = track:CreateTexture(nil, "OVERLAY")
    knob:SetSize(10, 10)
    toggle.knob = knob
    toggle.gwGet, toggle.gwSet = get, set
    toggle.gwHover, toggle.gwValue = false, false
    pcall(toggle.RegisterForClicks, toggle, "LeftButtonUp")
    toggle:SetScript("OnEnter", function(self) self.gwHover = true; paintToggle(self) end)
    toggle:SetScript("OnLeave", function(self) self.gwHover = false; paintToggle(self) end)
    toggle:SetScript("OnClick", function()
        toggle.gwSet(toggle.gwGet() ~= true)
        toggle:Refresh()
    end)
    function toggle:Refresh()
        self.gwValue = self.gwGet() == true
        paintToggle(self)
    end
    toggle:Refresh()
    return toggle
end

-- Segmented choice -----------------------------------------------------------------

-- A row of joined buttons for a small set of values. options = { { value, label } }.
function UI.Segmented(parent, options, get, set, opts)
    opts = opts or {}
    local group = create("Frame", parent)
    local width = opts.segmentWidth or 64
    group:SetSize(width * #options, opts.height or 20)
    group.buttons = {}
    for index, option in ipairs(options) do
        local button = UI.Button(group, option[2], { width = width + (index > 1 and 1 or 0), height = opts.height or 20, role = "small",
            onClick = function()
                set(option[1])
                group:Refresh()
            end })
        button:SetPoint("LEFT", group, "LEFT", (index - 1) * width - (index > 1 and 1 or 0), 0)
        button.gwValue = option[1]
        group.buttons[index] = button
    end
    function group:Refresh()
        local current = get()
        for _, button in ipairs(self.buttons) do
            button:SetActive(button.gwValue == current)
        end
    end
    group:Refresh()
    return group
end

-- A setting row: title and description on the left, a control on the right.
function UI.SettingRow(parent, title, description, control, width)
    local row = create("Frame", parent)
    row:SetSize(width or 360, description and 38 or 24)
    row.title = UI.Text(row, "label", "text")
    row.title:SetPoint("TOPLEFT", row, "TOPLEFT", 0, description and -3 or -5)
    row.title:SetText(title)
    if description then
        row.description = UI.Text(row, "small", "textMuted")
        row.description:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -3)
        row.description:SetPoint("RIGHT", control, "LEFT", -8, 0)
        pcall(row.description.SetWordWrap, row.description, false)
        row.description:SetText(description)
    end
    control:SetParent(row)
    control:ClearAllPoints()
    control:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, -2)
    row.control = control
    function row:Refresh()
        if self.control.Refresh then self.control:Refresh() end
    end
    return row
end

-- Sections, cards, dots -------------------------------------------------------------

-- An uppercase section heading with a gold accent under it.
function UI.SectionHeader(parent, title)
    local header = create("Frame", parent)
    header:SetHeight(20)
    header.text = UI.Text(header, "heading", "gold")
    header.text:SetPoint("TOPLEFT", header, "TOPLEFT", 0, 0)
    header.text:SetText(string.upper(title))
    header.accent = Theme.Accent(header, 28)
    header.accent:SetPoint("TOPLEFT", header.text, "BOTTOMLEFT", 0, -4)
    function header:SetTitle(text) UI.SetText(self.text, string.upper(text)) end
    return header
end

-- A raised panel, optionally clickable (onClick) with a hover state.
function UI.Card(parent, onClick)
    local card = create(onClick and "Button" or "Frame", parent)
    Theme.Skin(card, "bgRaised", "border")
    if onClick then
        pcall(card.RegisterForClicks, card, "LeftButtonUp")
        card:SetScript("OnEnter", function(self) Theme.SetBorder(self, "borderGold") end)
        card:SetScript("OnLeave", function(self) Theme.SetBorder(self, "border") end)
        card:SetScript("OnClick", onClick)
    end
    return card
end

-- A small round status light.
function UI.Dot(parent, size)
    local dot = parent:CreateTexture(nil, "OVERLAY")
    dot:SetSize(size or 8, size or 8)
    Theme.Fill(dot, "textFaint")
    dot.gwStatus = false
    -- Round where the client has mask textures; a small square otherwise.
    if type(parent.CreateMaskTexture) == "function" and type(dot.AddMaskTexture) == "function" then
        local mask = parent:CreateMaskTexture()
        pcall(mask.SetTexture, mask, "Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(dot)
        pcall(dot.AddMaskTexture, dot, mask)
    end
    function dot:SetStatus(color)
        if self.gwStatus == color then return end
        self.gwStatus = color
        Theme.Fill(self, color)
    end
    return dot
end

-- A label above a value, for stat grids.
function UI.Stat(parent, label, width)
    local stat = create("Frame", parent)
    stat:SetSize(width or 110, 34)
    stat.label = UI.Text(stat, "caps", "textFaint")
    stat.label:SetPoint("TOPLEFT", stat, "TOPLEFT", 0, 0)
    stat.label:SetText(string.upper(label))
    stat.value = UI.Text(stat, "stat", "text")
    stat.value:SetPoint("TOPLEFT", stat.label, "BOTTOMLEFT", 0, -3)
    stat.value:SetPoint("RIGHT", stat, "RIGHT", 0, 0)
    pcall(stat.value.SetWordWrap, stat.value, false)
    function stat:SetValue(text, color)
        UI.SetText(self.value, text)
        if color then Theme.Tint(self.value, color) end
    end
    return stat
end

-- A single-line text input with a themed frame.
function UI.Input(parent, width, onEnter)
    local box = create("EditBox", parent)
    box:SetSize(width or 200, 22)
    Theme.Skin(box, "bgInset", "border")
    pcall(box.SetAutoFocus, box, false)
    pcall(box.SetTextInsets, box, 6, 6, 0, 0)
    pcall(box.SetMaxLetters, box, 80)
    local spec = Theme.fontRoles.label
    pcall(box.SetFont, box, Theme.FontFiles()[spec[1]], spec[2], "")
    local rgb = Theme.colors.text
    pcall(box.SetTextColor, box, rgb[1], rgb[2], rgb[3], 1)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEditFocusGained", function(self) Theme.SetBorder(self, "borderGold") end)
    box:SetScript("OnEditFocusLost", function(self) Theme.SetBorder(self, "border") end)
    box:SetScript("OnEnterPressed", function(self)
        if onEnter then onEnter(self, self:GetText()) end
    end)
    return box
end

-- Windows ---------------------------------------------------------------------------

-- A draggable window with a title bar, an emblem and a close button.
-- opts: name, width, height, title, getPosition(), savePosition(point, relativePoint, x, y), strata
function UI.Window(opts)
    local frame = create("Frame", Globals.UIParent, opts.name)
    frame:SetSize(opts.width or 640, opts.height or 440)
    frame:SetFrameStrata(opts.strata or "HIGH")
    pcall(frame.SetToplevel, frame, true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    Theme.Shadow(frame, 8)
    Theme.Skin(frame, "bg", "border")

    local header = create("Frame", frame)
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
    header:SetHeight(opts.headerHeight or 42)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    local headerBg = header:CreateTexture(nil, "BACKGROUND")
    headerBg:SetAllPoints(header)
    Theme.Fill(headerBg, "bgRaised")
    local rule = Theme.Rule(header, "borderGold", 0.55)
    rule:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 0, 0)
    rule:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0)
    frame.header = header

    local emblem = header:CreateTexture(nil, "ARTWORK")
    emblem:SetSize(24, 24)
    emblem:SetPoint("LEFT", header, "LEFT", 12, 0)
    pcall(emblem.SetTexture, emblem, Theme.EMBLEM)
    frame.emblem = emblem
    frame.title = UI.Text(header, "brand", "gold")
    frame.title:SetPoint("LEFT", emblem, "RIGHT", 8, 0)
    frame.title:SetText(opts.title or "Guildweaver")

    frame.closeButton = UI.IconButton(header, "\195\151", { size = 24, role = "glyph", tooltip = "Close",
        onClick = function() frame:Hide() end })
    frame.closeButton:SetPoint("RIGHT", header, "RIGHT", -8, 0)

    header:SetScript("OnDragStart", function()
        if not frame.gwLocked then frame:StartMoving() end
    end)
    header:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        if opts.savePosition then
            local ok, point, _, relativePoint, x, y = pcall(frame.GetPoint, frame, 1)
            if ok and type(point) == "string" then
                opts.savePosition(point, relativePoint, x, y)
            end
        end
    end)

    function frame:RestorePosition()
        local position = opts.getPosition and opts.getPosition() or nil
        self:ClearAllPoints()
        if position and position.point then
            self:SetPoint(position.point, Globals.UIParent, position.relativePoint or position.point, tonumber(position.x) or 0, tonumber(position.y) or 0)
        else
            self:SetPoint("CENTER", Globals.UIParent, "CENTER", 0, 0)
        end
    end
    frame:RestorePosition()

    if opts.name and type(Globals.UISpecialFrames) == "table" then
        table.insert(Globals.UISpecialFrames, opts.name)
    end
    frame:Hide()
    return frame
end

-- Popup menu ------------------------------------------------------------------------

-- A small list of actions under the cursor or an anchor. Closes on a pick,
-- on Escape, or on a click anywhere else. items = { { text, onClick, disabled, checked, separator } }
function UI.ShowMenu(anchor, items)
    local menu = UI.menu
    if not menu then
        menu = create("Frame", Globals.UIParent, "GuildweaverMenu")
        menu:SetFrameStrata("DIALOG")
        menu:SetClampedToScreen(true)
        menu:EnableMouse(true)
        Theme.Shadow(menu, 4)
        Theme.Skin(menu, "bg", "borderGold", 0.7)
        menu.rows = {}
        -- A full-screen catcher under the menu closes it on an outside click.
        local catcher = create("Button", Globals.UIParent)
        catcher:SetFrameStrata("DIALOG")
        catcher:SetAllPoints(Globals.UIParent)
        pcall(catcher.RegisterForClicks, catcher, "AnyUp")
        catcher:SetScript("OnClick", function() menu:Hide() end)
        catcher:Hide()
        menu.catcher = catcher
        menu:SetScript("OnHide", function() catcher:Hide() end)
        if type(Globals.UISpecialFrames) == "table" then
            table.insert(Globals.UISpecialFrames, "GuildweaverMenu")
        end
        UI.menu = menu
    end
    local width, y = 188, -6
    for index, item in ipairs(items) do
        local row = menu.rows[index]
        if not row then
            row = create("Button", menu)
            row:SetHeight(22)
            row.highlight = row:CreateTexture(nil, "BACKGROUND")
            row.highlight:SetAllPoints(row)
            Theme.Fill(row.highlight, "bgHover")
            row.highlight:Hide()
            row.text = UI.Text(row, "label", "text")
            row.text:SetPoint("LEFT", row, "LEFT", 12, 0)
            row.text:SetPoint("RIGHT", row, "RIGHT", -24, 0)
            row.check = UI.Text(row, "label", "gold", "RIGHT")
            row.check:SetPoint("RIGHT", row, "RIGHT", -10, 0)
            row.rule = Theme.Rule(row, "border")
            row.rule:SetPoint("LEFT", row, "LEFT", 8, 0)
            row.rule:SetPoint("RIGHT", row, "RIGHT", -8, 0)
            pcall(row.RegisterForClicks, row, "LeftButtonUp")
            row:SetScript("OnEnter", function(self) if not self.gwDisabled then self.highlight:Show() end end)
            row:SetScript("OnLeave", function(self) self.highlight:Hide() end)
            row:SetScript("OnClick", function(self)
                if self.gwDisabled or self.gwSeparator then return end
                menu:Hide()
                if self.gwAction then self.gwAction() end
            end)
            menu.rows[index] = row
        end
        row.gwAction, row.gwDisabled, row.gwSeparator = item.onClick, item.disabled == true, item.separator == true
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", menu, "TOPLEFT", 1, y)
        row:SetPoint("RIGHT", menu, "RIGHT", -1, 0)
        if item.separator then
            row:SetHeight(9)
            row.text:SetText("")
            row.check:SetText("")
            row.rule:Show()
            y = y - 9
        else
            row:SetHeight(22)
            row.rule:Hide()
            row.text:SetText(item.text or "")
            Theme.Tint(row.text, item.disabled and "textFaint" or (item.title and "gold" or "text"))
            row.check:SetText(item.checked and "\226\128\162" or "")
            y = y - 22
        end
        row:Show()
    end
    for index = #items + 1, #menu.rows do
        menu.rows[index]:Hide()
    end
    menu:SetSize(width, -y + 6)
    menu:ClearAllPoints()
    if anchor then
        menu:SetPoint("TOPRIGHT", anchor, "BOTTOMLEFT", 8, 4)
    else
        menu:SetPoint("CENTER", Globals.UIParent, "CENTER", 0, 0)
    end
    menu.catcher:Show()
    pcall(menu.catcher.SetFrameLevel, menu.catcher, math.max(0, (tonumber(menu:GetFrameLevel()) or 2) - 1))
    menu:Show()
    menu.items = items
    return menu
end

function UI.HideMenu()
    if UI.menu then UI.menu:Hide() end
end
