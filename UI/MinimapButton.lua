local _, GW = ...

-- The minimap launcher: the Guildweaver emblem in the client's own round
-- minimap-button frame, so it sits naturally next to every other addon's.
--   click          open or close the dashboard
--   double-click   open the dashboard on Settings
--   right-click    a short menu of quick actions
--   drag           move it around the minimap edge (saved)
-- A single click waits out the double-click window before it acts, so a
-- double-click never opens and closes the dashboard on its way to Settings.
-- No library: one button, a dozen lines of geometry. /gw minimap shows it
-- again after it was hidden.
GW.MinimapButton = GW.MinimapButton or {}

local Globals = _G or {}
local Button = GW.MinimapButton
local UI, Theme, Prefs = GW.UI, GW.Theme, GW.UiPrefs

Button.DOUBLE_CLICK_SECONDS = 0.3
-- A click this soon after a drag ends is the drag's release, not a click.
local DRAG_GRACE_SECONDS = 0.2

local function now()
    local ok, value = pcall(Globals.GetTime)
    return ok and tonumber(value) or 0
end

local function number(fn, frame)
    if not frame or type(frame[fn]) ~= "function" then return nil end
    local ok, value = pcall(frame[fn], frame)
    return ok and tonumber(value) or nil
end

local function radius(minimap)
    local width = number("GetWidth", minimap)
    return width and (width / 2 + 10) or 80
end

-- Places the button on the minimap's edge at an angle (degrees, 0 = east).
function Button:Place(angle)
    local button, minimap = self.button, Globals.Minimap
    if not button or not minimap then return end
    local radians = math.rad(angle or Prefs.MinimapAngle())
    local r = radius(minimap)
    button:ClearAllPoints()
    button:SetPoint("CENTER", minimap, "CENTER", math.cos(radians) * r, math.sin(radians) * r)
end

-- The angle from the minimap's centre to the cursor.
function Button.CursorAngle()
    local minimap = Globals.Minimap
    if not minimap or type(Globals.GetCursorPosition) ~= "function" then return nil end
    local okCenter, cx, cy = pcall(minimap.GetCenter, minimap)
    local okCursor, px, py = pcall(Globals.GetCursorPosition)
    local scale = number("GetEffectiveScale", minimap) or 1
    if not okCenter or not okCursor or not tonumber(cx) or not tonumber(px) or scale == 0 then return nil end
    return math.deg(math.atan2(py / scale - cy, px / scale - cx)) % 360
end

-- Clicks ---------------------------------------------------------------------------

local function dashboard()
    return GW.MainFrame
end

function Button.SingleClick()
    local main = dashboard()
    if main and main.Toggle then main:Toggle() end
end

function Button.DoubleClick()
    local main = dashboard()
    if main and main.Open then main:Open("settings") end
end

function Button:HandleClick(mouse)
    if mouse == "RightButton" then
        self.pendingClickAt = nil
        self:ShowMenu()
        return "menu"
    end
    local at = now()
    if self.draggedAt and at - self.draggedAt < DRAG_GRACE_SECONDS then
        return "drag"
    end
    if self.pendingClickAt and at - self.pendingClickAt <= Button.DOUBLE_CLICK_SECONDS then
        -- The second click: the first one's action is cancelled.
        self.pendingClickAt = nil
        self.clickToken = (self.clickToken or 0) + 1
        Button.DoubleClick()
        return "double"
    end
    self.pendingClickAt = at
    self.clickToken = (self.clickToken or 0) + 1
    local token = self.clickToken
    local timer = Globals.C_Timer
    if timer and type(timer.After) == "function" then
        timer.After(Button.DOUBLE_CLICK_SECONDS, function()
            if self.clickToken == token and self.pendingClickAt then
                self.pendingClickAt = nil
                Button.SingleClick()
            end
        end)
        return "pending"
    end
    self.pendingClickAt = nil
    Button.SingleClick()
    return "single"
end

function Button.MenuItems()
    local hud = GW.DungeonHud
    local farming = GW.FarmingSessions
    local context = farming and farming.Context and farming.Context()
    local measuring = context and context.mode == "manual"
    local main = dashboard()
    return {
        { text = "Guildweaver", title = true, disabled = true },
        { text = "Open dashboard", onClick = function() main:Open() end },
        { text = "Dungeon HUD", checked = hud and hud.IsEnabled() and not hud.IsHiddenForRun(), onClick = function()
            if hud.IsEnabled() and not hud.IsHiddenForRun() then hud:SetEnabled(false) else hud:ShowNow() end
            if main.RefreshView then main:RefreshView() end
        end },
        { text = measuring and "Stop farming run" or "Start farming run", onClick = function()
            if main.ToggleFarming then main:ToggleFarming() end
        end },
        { text = "Sync & data", onClick = function() main:Open("sync") end },
        { text = "Settings", onClick = function() main:Open("settings") end },
        { separator = true },
        { text = "Hide minimap button", onClick = function()
            Prefs.SetMinimapHidden(true)
            GW.Print("Minimap button hidden. /gw minimap brings it back, or turn it on in Settings.")
        end },
    }
end

function Button:ShowMenu()
    UI.HideTooltip()
    return UI.ShowMenu(self.button, Button.MenuItems())
end

-- Frame ------------------------------------------------------------------------------

local function showTooltip(button)
    if Button.dragging then return end
    UI.ShowTooltip(button, "Guildweaver", {
        Theme.Colorize("Click", "text") .. "  open the dashboard",
        Theme.Colorize("Double-click", "text") .. "  settings",
        Theme.Colorize("Right-click", "text") .. "  quick actions",
        Theme.Colorize("Drag", "text") .. "  move this button",
    }, "ANCHOR_LEFT")
end

function Button:Initialize()
    if self.button then return self.button end
    local minimap = Globals.Minimap
    if not minimap or type(Globals.CreateFrame) ~= "function" then
        return nil
    end
    local button = Globals.CreateFrame("Button", "GuildweaverMinimapButton", minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    pcall(button.SetFrameLevel, button, 8)
    pcall(button.RegisterForClicks, button, "LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    pcall(button.SetHighlightTexture, button, "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetPoint("TOPLEFT", button, "TOPLEFT", 7, -5)
    pcall(background.SetTexture, background, "Interface\\Minimap\\UI-Minimap-Background")
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("TOPLEFT", button, "TOPLEFT", 6, -5)
    pcall(icon.SetTexture, icon, Theme.EMBLEM)
    button.icon = icon
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    pcall(border.SetTexture, border, "Interface\\Minimap\\MiniMap-TrackingBorder")

    button:SetScript("OnClick", function(_, mouse) Button:HandleClick(mouse) end)
    button:SetScript("OnMouseDown", function() pcall(icon.SetPoint, icon, "TOPLEFT", button, "TOPLEFT", 7, -6) end)
    button:SetScript("OnMouseUp", function() pcall(icon.SetPoint, icon, "TOPLEFT", button, "TOPLEFT", 6, -5) end)
    button:SetScript("OnEnter", showTooltip)
    button:SetScript("OnLeave", UI.HideTooltip)
    button:SetScript("OnDragStart", function(current)
        Button.dragging = true
        UI.HideTooltip()
        -- OnUpdate only while the button is being dragged.
        current:SetScript("OnUpdate", function()
            local angle = Button.CursorAngle()
            if angle then
                Button.dragAngle = angle
                Button:Place(angle)
            end
        end)
    end)
    button:SetScript("OnDragStop", function(current)
        current:SetScript("OnUpdate", nil)
        Button.dragging = false
        Button.draggedAt = now()
        local angle = Button.CursorAngle() or Button.dragAngle
        if angle then
            Prefs.SetMinimapAngle(angle)
        end
        Button:Place()
    end)
    self.button = button
    self:Refresh()
    return button
end

function Button:Refresh()
    if not self.button then return end
    self:Place()
    if Prefs.MinimapHidden() then self.button:Hide() else self.button:Show() end
end

function Button.IsShown()
    return Button.button ~= nil and not Prefs.MinimapHidden()
end
