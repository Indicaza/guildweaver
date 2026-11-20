local _, GW = ...

-- Guildweaver's look: blue-black panels, hairline borders, antique gold for
-- what matters, quiet greys for everything else. Colours and fonts live here
-- so every window, the HUD and the minimap button agree.
--
-- Fonts come from the client's own font objects, so other locales keep the
-- glyphs their client ships; the enUS fallbacks are Friz Quadrata for
-- headings and Arial Narrow for text and numbers.
GW.Theme = GW.Theme or {}

local Globals = _G or {}
local Theme = GW.Theme

Theme.MEDIA = "Interface\\AddOns\\Guildweaver\\Media\\"
Theme.EMBLEM = Theme.MEDIA .. "Emblem"
Theme.WHITE = "Interface\\Buttons\\WHITE8X8"
-- A 32x32 feathered corner (alpha only): the soft edge of the paper shadow.
Theme.SHADOW = Theme.MEDIA .. "Shadow"
-- A 256x256 tileable stone grain, laid at very low alpha over panels.
Theme.GRAIN = Theme.MEDIA .. "Grain"
Theme.GRAIN_SIZE = 256

-- Theme.Panel's styles (below); SetBackground reads their shade.
local PANEL
local PANEL_SHADE = { stone = 0.55, inset = 0.72, gold = 0.62 }

Theme.colors = {
    -- Surfaces, darkest to lightest.
    shadow = { 0, 0, 0, 0.45 },
    bg = { 0.047, 0.055, 0.074, 0.96 },
    bgInset = { 0.031, 0.036, 0.050, 0.92 },
    bgRaised = { 0.078, 0.087, 0.112, 0.98 },
    bgHover = { 0.110, 0.121, 0.153, 1 },
    bgActive = { 0.137, 0.125, 0.098, 1 },
    border = { 0.165, 0.176, 0.212, 1 },
    borderStrong = { 0.247, 0.255, 0.290, 1 },
    borderGold = { 0.478, 0.392, 0.231, 0.9 },
    -- Accent.
    gold = { 0.851, 0.714, 0.431, 1 },
    goldBright = { 0.984, 0.855, 0.565, 1 },
    goldDim = { 0.553, 0.459, 0.282, 1 },
    -- Text.
    text = { 0.906, 0.894, 0.863, 1 },
    textMuted = { 0.584, 0.600, 0.643, 1 },
    textFaint = { 0.396, 0.412, 0.459, 1 },
    -- Status.
    good = { 0.427, 0.792, 0.553, 1 },
    warn = { 0.937, 0.706, 0.337, 1 },
    bad = { 0.902, 0.416, 0.365, 1 },
    info = { 0.502, 0.651, 0.890, 1 },
}

-- role = { font kind, size, flags }
Theme.fontRoles = {
    brand = { "heading", 15 },
    pageTitle = { "heading", 16 },
    title = { "heading", 13 },
    heading = { "heading", 11 },
    caps = { "body", 10 },
    body = { "body", 13 },
    label = { "body", 12 },
    small = { "body", 11 },
    button = { "body", 12 },
    glyph = { "body", 17 },
    clock = { "number", 24 },
    clockMid = { "number", 19 },
    clockSmall = { "number", 15 },
    stat = { "number", 15 },
}

local fontFiles = nil

local function fontFile(object, fallback)
    local candidate = Globals[object]
    if type(candidate) == "table" and type(candidate.GetFont) == "function" then
        local ok, file = pcall(candidate.GetFont, candidate)
        if ok and type(file) == "string" and file ~= "" then
            return file
        end
    end
    return fallback
end

function Theme.FontFiles()
    if not fontFiles then
        local standard = type(Globals.STANDARD_TEXT_FONT) == "string" and Globals.STANDARD_TEXT_FONT or nil
        fontFiles = {
            heading = standard or fontFile("GameFontNormal", "Fonts\\FRIZQT__.TTF"),
            body = fontFile("ChatFontNormal", "Fonts\\ARIALN.TTF"),
            number = fontFile("NumberFontNormal", "Fonts\\ARIALN.TTF"),
        }
    end
    return fontFiles
end

function Theme.Color(name)
    return Theme.colors[name] or Theme.colors.text
end

-- Colours a font string, texture or anything with SetTextColor/SetVertexColor.
function Theme.Tint(widget, name, alpha)
    if not widget then return end
    local rgb = type(name) == "table" and name or Theme.Color(name)
    local a = alpha or rgb[4] or 1
    if type(widget.SetTextColor) == "function" then
        pcall(widget.SetTextColor, widget, rgb[1], rgb[2], rgb[3], a)
    elseif type(widget.SetVertexColor) == "function" then
        pcall(widget.SetVertexColor, widget, rgb[1], rgb[2], rgb[3], a)
    end
end

-- Fills a texture with a theme colour.
function Theme.Fill(texture, name, alpha)
    local rgb = type(name) == "table" and name or Theme.Color(name)
    pcall(texture.SetColorTexture, texture, rgb[1], rgb[2], rgb[3], alpha or rgb[4] or 1)
end

-- Sets a font string's face for a role, and optionally its colour.
function Theme.Font(fontString, role, color)
    local spec = Theme.fontRoles[role] or Theme.fontRoles.body
    local file = Theme.FontFiles()[spec[1]]
    pcall(fontString.SetFont, fontString, file, spec[2], spec[3] or "")
    pcall(fontString.SetShadowOffset, fontString, 1, -1)
    pcall(fontString.SetShadowColor, fontString, 0, 0, 0, 0.75)
    if color then
        Theme.Tint(fontString, color)
    end
    return fontString
end

-- A colour as a |c escape for inline text.
function Theme.Hex(name)
    local rgb = type(name) == "table" and name or Theme.Color(name)
    return string.format("|cff%02x%02x%02x", math.floor(rgb[1] * 255 + 0.5), math.floor(rgb[2] * 255 + 0.5), math.floor(rgb[3] * 255 + 0.5))
end

function Theme.Colorize(text, name)
    return Theme.Hex(name) .. tostring(text) .. "|r"
end

-- A flat surface with a one-pixel border, drawn with plain textures (no
-- backdrop template, so it looks the same on every client). Returns the
-- textures so callers can recolour them for hover and active states.
function Theme.Skin(frame, background, border, borderAlpha)
    local skin = rawget(frame, "gwSkin")
    if not skin then
        skin = {}
        -- Sublevel -7: the paper shadow (-8) lies under it, the grain (-6) over it.
        skin.bg = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
        skin.bg:SetAllPoints(frame)
        skin.edges = {}
        local function edge(a1, a2, horizontal)
            local texture = frame:CreateTexture(nil, "BORDER", nil, 7)
            texture:SetPoint(a1, frame, a1, 0, 0)
            texture:SetPoint(a2, frame, a2, 0, 0)
            if horizontal then texture:SetHeight(1) else texture:SetWidth(1) end
            table.insert(skin.edges, texture)
        end
        edge("TOPLEFT", "TOPRIGHT", true)
        edge("BOTTOMLEFT", "BOTTOMRIGHT", true)
        edge("TOPLEFT", "BOTTOMLEFT", false)
        edge("TOPRIGHT", "BOTTOMRIGHT", false)
        frame.gwSkin = skin
    end
    Theme.Fill(skin.bg, background or "bg")
    for _, texture in ipairs(skin.edges) do
        Theme.Fill(texture, border or "border", borderAlpha)
    end
    return skin
end

function Theme.SetBorder(frame, border, alpha)
    local skin = rawget(frame, "gwSkin")
    if not skin then return end
    -- A Blizzard border (Theme.Panel): its edge colour.
    if skin.backdrop then
        local rgb = type(border) == "table" and border or Theme.Color(border)
        pcall(skin.backdrop.SetBackdropBorderColor, skin.backdrop, rgb[1], rgb[2], rgb[3], alpha or rgb[4] or 1)
        return
    end
    for _, texture in ipairs(skin.edges) do
        Theme.Fill(texture, border, alpha)
    end
end

function Theme.SetBackground(frame, background, alpha)
    local skin = rawget(frame, "gwSkin")
    if not skin then return end
    -- Over Blizzard's rock (Theme.Panel) only the shade changes.
    if skin.rock then
        local rgb = type(background) == "table" and background or Theme.Color(background)
        pcall(skin.shade.SetColorTexture, skin.shade, rgb[1] * 0.5, rgb[2] * 0.5, rgb[3] * 0.5, alpha or (PANEL_SHADE[skin.style] or 0.55))
        return
    end
    Theme.Fill(skin.bg, background, alpha)
end

-- The shadow of a sheet of paper lifted slightly off the table: a
-- Gaussian falloff (Media/Shadow.tga, one feathered corner) drawn as a
-- nine-slice around the frame, nudged down a few pixels, reaching further
-- and darker under the lower edge than above it. The corner is mirrored
-- with texture coordinates; the edges stretch its innermost row or column.
-- scale shrinks it for small popups. Returns the textures.
local SHADOW = { offset = 3, top = 12, side = 16, bottom = 26, topAlpha = 0.32, bottomAlpha = 0.55 }
Theme.SHADOW_SPEC = SHADOW

local function shadeVertical(texture, top, bottom)
    if type(texture.SetGradient) == "function" and type(Globals.CreateColor) == "function" then
        -- VERTICAL: the first colour is the bottom.
        if pcall(texture.SetGradient, texture, "VERTICAL", Globals.CreateColor(0, 0, 0, bottom), Globals.CreateColor(0, 0, 0, top)) then
            return
        end
    end
    pcall(texture.SetVertexColor, texture, 0, 0, 0, (top + bottom) / 2)
end

function Theme.PaperShadow(frame, scale)
    scale = scale or 1
    local off, top, side, bottom = SHADOW.offset * scale, SHADOW.top * scale, SHADOW.side * scale, SHADOW.bottom * scale
    local at, ab = SHADOW.topAlpha, SHADOW.bottomAlpha
    local inner = 31 / 32
    local pieces = {}
    local function add(coords, alpha, place)
        local texture = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
        pcall(texture.SetTexture, texture, Theme.SHADOW)
        pcall(texture.SetTexCoord, texture, coords[1], coords[2], coords[3], coords[4])
        place(texture)
        if alpha then pcall(texture.SetVertexColor, texture, 0, 0, 0, alpha) end
        table.insert(pieces, texture)
    end
    -- Corners: the texture's (1,1) is the frame's corner.
    add({ 0, 1, 0, 1 }, at, function(t) t:SetSize(side, top); t:SetPoint("BOTTOMRIGHT", frame, "TOPLEFT", 0, -off) end)
    add({ 1, 0, 0, 1 }, at, function(t) t:SetSize(side, top); t:SetPoint("BOTTOMLEFT", frame, "TOPRIGHT", 0, -off) end)
    add({ 0, 1, 1, 0 }, ab, function(t) t:SetSize(side, bottom); t:SetPoint("TOPRIGHT", frame, "BOTTOMLEFT", 0, -off) end)
    add({ 1, 0, 1, 0 }, ab, function(t) t:SetSize(side, bottom); t:SetPoint("TOPLEFT", frame, "BOTTOMRIGHT", 0, -off) end)
    -- Top and bottom edges.
    add({ inner, 1, 0, 1 }, at, function(t)
        t:SetHeight(top)
        t:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, -off)
        t:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, -off)
    end)
    add({ inner, 1, 1, 0 }, ab, function(t)
        t:SetHeight(bottom)
        t:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -off)
        t:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", 0, -off)
    end)
    -- Side edges, darkening towards the bottom.
    add({ 0, 1, inner, 1 }, nil, function(t)
        t:SetWidth(side)
        t:SetPoint("TOPRIGHT", frame, "TOPLEFT", 0, -off)
        t:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", 0, -off)
        shadeVertical(t, at, ab)
    end)
    add({ 1, 0, inner, 1 }, nil, function(t)
        t:SetWidth(side)
        t:SetPoint("TOPLEFT", frame, "TOPRIGHT", 0, -off)
        t:SetPoint("BOTTOMLEFT", frame, "BOTTOMRIGHT", 0, -off)
        shadeVertical(t, at, ab)
    end)
    -- Under the frame: only the strip the offset uncovers is ever seen.
    local under = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
    under:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -off)
    under:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, -off)
    pcall(under.SetColorTexture, under, 0, 0, 0, ab)
    table.insert(pieces, under)
    return pieces
end

-- A faint stone grain over a surface of a known size, tiled. Its alpha is
-- very low: it should be felt more than seen.
function Theme.Grain(frame, width, height, alpha, inset)
    inset = inset or 1
    local texture = frame:CreateTexture(nil, "BACKGROUND", nil, -6)
    texture:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -inset)
    texture:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset)
    if not pcall(texture.SetTexture, texture, Theme.GRAIN, "REPEAT", "REPEAT") then
        pcall(texture.SetTexture, texture, Theme.GRAIN)
    end
    pcall(texture.SetTexCoord, texture, 0, (width or Theme.GRAIN_SIZE) / Theme.GRAIN_SIZE, 0, (height or Theme.GRAIN_SIZE) / Theme.GRAIN_SIZE)
    pcall(texture.SetAlpha, texture, alpha or 0.07)
    return texture
end

-- A one-pixel rule.
function Theme.Rule(parent, color, alpha)
    local texture = parent:CreateTexture(nil, "ARTWORK")
    texture:SetHeight(1)
    Theme.Fill(texture, color or "border", alpha)
    return texture
end


-- Blizzard's own UI art ------------------------------------------------------------------
--
-- Textures the client ships, by path. Each one is used by OpenMap, an
-- add-on built for WoW Forever's client (Interface 16001), so it is known to
-- exist there; nothing here is guessed. Every use goes through
-- Theme.Texture, and a client that lacks a file (SetTexture answers false)
-- gets the flat look instead.
Theme.ART = {
    rock = "Interface\\FrameGeneral\\UI-Background-Rock",
    tooltipBorder = "Interface\\Tooltips\\UI-Tooltip-Border",
    goldBorder = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
    slot = "Interface\\Buttons\\UI-Quickslot2",
    rowHighlight = "Interface\\QuestFrame\\UI-QuestTitleHighlight",
    mouseHighlight = "Interface\\Buttons\\UI-Common-MouseHilight",
    questAvailable = "Interface\\GossipFrame\\AvailableQuestIcon",
    questIncomplete = "Interface\\GossipFrame\\IncompleteQuestIcon",
    questActive = "Interface\\GossipFrame\\ActiveQuestIcon",
    skull = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull",
    book = "Interface\\QuestFrame\\UI-QuestLog-BookIcon",
}

-- Sets a texture to a file. False when the client has no such file (or the
-- call fails); the caller then draws its fallback.
function Theme.Texture(texture, file, horizontal, vertical)
    if not texture or type(file) == "nil" then return false end
    local ok, result
    if horizontal then
        ok, result = pcall(texture.SetTexture, texture, file, horizontal, vertical or horizontal)
    else
        ok, result = pcall(texture.SetTexture, texture, file)
    end
    if not ok or result == false then return false end
    rawset(texture, "gwArt", file)
    return true
end

-- The edge colour of a Blizzard border, by theme colour name.
local function backdropBorder(backdrop, name, alpha)
    local rgb = type(name) == "table" and name or Theme.Color(name)
    pcall(backdrop.SetBackdropBorderColor, backdrop, rgb[1], rgb[2], rgb[3], alpha or rgb[4] or 1)
end

-- A panel in the game's own look: Blizzard's dark rock, shaded so text
-- reads, inside the tooltip border (or, for "gold", the dialog's gold
-- edge). style: "stone" (cards, panels), "inset" (wells: the map, the
-- quest summary), "gold" (a framed centrepiece). Without the art (or a
-- backdrop) it is Theme.Skin's flat surface and hairline, as before.
-- Theme.SetBorder and Theme.SetBackground keep working on it.
PANEL = {
    stone = { shade = 0.55, edge = "borderGold", edgeAlpha = 0.85, flat = "bgRaised", flatEdge = "border" },
    inset = { shade = 0.72, edge = "borderStrong", edgeAlpha = 0.9, flat = "bgInset", flatEdge = "border" },
    gold = { shade = 0.62, edge = "gold", edgeAlpha = 0.9, gold = true, flat = "bgInset", flatEdge = "borderGold" },
}
Theme.PANEL = PANEL

function Theme.Panel(frame, style, outset)
    local spec = PANEL[style] or PANEL.stone
    local skin = Theme.Skin(frame, spec.flat, spec.flatEdge)
    skin.style = style
    if not skin.shade then
        skin.shade = frame:CreateTexture(nil, "BACKGROUND", nil, -6)
        skin.shade:SetAllPoints(frame)
    end
    -- The rock, tiled, under a dark shade.
    if Theme.Texture(skin.bg, Theme.ART.rock, "REPEAT", "REPEAT") then
        pcall(skin.bg.SetHorizTile, skin.bg, true)
        pcall(skin.bg.SetVertTile, skin.bg, true)
        pcall(skin.bg.SetVertexColor, skin.bg, 1, 1, 1, 1)
        pcall(skin.shade.SetColorTexture, skin.shade, 0, 0, 0, spec.shade)
        skin.shade:Show()
        skin.rock = true
    else
        skin.shade:Hide()
        skin.rock = false
    end
    -- The border: a backdrop child, when the client has the template.
    local backdrop = skin.backdrop
    if backdrop == nil then
        local ok, made = pcall(Globals.CreateFrame, "Frame", nil, frame, "BackdropTemplate")
        backdrop = ok and made and type(made.SetBackdrop) == "function" and made or false
        skin.backdrop = backdrop
    end
    if backdrop then
        outset = outset or 2
        backdrop:ClearAllPoints()
        backdrop:SetPoint("TOPLEFT", frame, "TOPLEFT", -outset, outset)
        backdrop:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", outset, -outset)
        local okLevel, level = pcall(frame.GetFrameLevel, frame)
        pcall(backdrop.SetFrameLevel, backdrop, (okLevel and tonumber(level) or 1) + 1)
        local ok = pcall(backdrop.SetBackdrop, backdrop, {
            edgeFile = spec.gold and Theme.ART.goldBorder or Theme.ART.tooltipBorder,
            edgeSize = spec.gold and 16 or 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        if ok then
            backdropBorder(backdrop, spec.edge, spec.edgeAlpha)
            for _, edge in ipairs(skin.edges) do edge:Hide() end
            skin.edgeColor = spec.edge
        else
            skin.backdrop = false
        end
    end
    return skin
end

-- A hover glow: the quest log's row highlight, added over the row.
function Theme.Highlight(button, file, alpha)
    if type(button.SetHighlightTexture) ~= "function" then return end
    pcall(button.SetHighlightTexture, button, file or Theme.ART.rowHighlight, "ADD")
    if alpha and type(button.GetHighlightTexture) == "function" then
        local ok, texture = pcall(button.GetHighlightTexture, button)
        if ok and texture and type(texture.SetAlpha) == "function" then pcall(texture.SetAlpha, texture, alpha) end
    end
end

-- A soft hairline that fades in from the left and out to the right: a
-- quiet divider instead of a hard rule or a bright underline.
function Theme.Divider(parent, color, alpha)
    local texture = parent:CreateTexture(nil, "ARTWORK")
    texture:SetHeight(1)
    pcall(texture.SetTexture, texture, Theme.WHITE)
    local rgb = Theme.Color(color or "goldDim")
    local a = alpha or 0.55
    if type(texture.SetGradient) == "function" and type(Globals.CreateColor) == "function"
        and pcall(texture.SetGradient, texture, "HORIZONTAL", Globals.CreateColor(rgb[1], rgb[2], rgb[3], a), Globals.CreateColor(rgb[1], rgb[2], rgb[3], 0)) then
        return texture
    end
    Theme.Fill(texture, color or "goldDim", a * 0.6)
    return texture
end

-- A short accent line, fading to the right: now a quiet one-pixel bronze
-- line (it was a bright gold underline).
function Theme.Accent(parent, width)
    local texture = parent:CreateTexture(nil, "ARTWORK")
    texture:SetSize(width or 24, 1)
    pcall(texture.SetTexture, texture, Theme.WHITE)
    local gold = Theme.colors.goldDim
    if type(texture.SetGradient) == "function" and type(Globals.CreateColor) == "function" then
        local ok = pcall(texture.SetGradient, texture, "HORIZONTAL", Globals.CreateColor(gold[1], gold[2], gold[3], 1), Globals.CreateColor(gold[1], gold[2], gold[3], 0))
        if ok then return texture end
    end
    Theme.Fill(texture, "goldDim", 0.6)
    return texture
end

-- Loot alerts --------------------------------------------------------------------------
--
-- One colour per alert category, here and nowhere else: the roll-frame
-- glow, the HUD glow and the toast all ask Theme.AlertColor(category).
-- A new category is a new entry in this table.
Theme.colors.alertWishlist = { 0.698, 0.455, 1.000, 1 }
Theme.colors.alertBoe = { 1.000, 0.824, 0.376, 1 }
Theme.colors.alertUpgrade = { 0.400, 0.682, 1.000, 1 }

Theme.alerts = {
    wishlist = { color = "alertWishlist", label = "Wishlist" },
    valuable_boe = { color = "alertBoe", label = "Valuable BoE" },
    -- Reserved: nothing raises it yet (see Systems/LootAlerts.lua).
    upgrade = { color = "alertUpgrade", label = "Potential upgrade" },
}

function Theme.AlertColor(category)
    local alert = Theme.alerts[category]
    return Theme.Color(alert and alert.color or "gold")
end

function Theme.AlertLabel(category)
    local alert = Theme.alerts[category]
    return alert and alert.label or tostring(category)
end

-- A soft halo around a frame: the feathered corner of the paper shadow,
-- drawn additively in a colour, breathing slowly. It lives on its own
-- frame (never a child of the frame it surrounds, which may belong to the
-- game), sits behind it, takes no mouse input and covers nothing: every
-- piece lies outside the target's edges.
--
-- Returns { frame, SetColor(rgb), Attach(target), Pulse(), Stop() }, or nil
-- where frames cannot be created.
local HALO = { spread = 14, low = 0.35, high = 0.95, period = 1.1 }
Theme.HALO_SPEC = HALO

function Theme.Halo(spread)
    if type(Globals.CreateFrame) ~= "function" then return nil end
    spread = spread or HALO.spread
    local frame = Globals.CreateFrame("Frame", nil, Globals.UIParent)
    pcall(frame.EnableMouse, frame, false)
    frame:Hide()
    local inner = 31 / 32
    local pieces = {}
    local function add(coords, place)
        local texture = frame:CreateTexture(nil, "BACKGROUND")
        pcall(texture.SetTexture, texture, Theme.SHADOW)
        pcall(texture.SetTexCoord, texture, coords[1], coords[2], coords[3], coords[4])
        pcall(texture.SetBlendMode, texture, "ADD")
        place(texture)
        table.insert(pieces, texture)
    end
    add({ 0, 1, 0, 1 }, function(t) t:SetSize(spread, spread); t:SetPoint("BOTTOMRIGHT", frame, "TOPLEFT", spread, -spread) end)
    add({ 1, 0, 0, 1 }, function(t) t:SetSize(spread, spread); t:SetPoint("BOTTOMLEFT", frame, "TOPRIGHT", -spread, -spread) end)
    add({ 0, 1, 1, 0 }, function(t) t:SetSize(spread, spread); t:SetPoint("TOPRIGHT", frame, "BOTTOMLEFT", spread, spread) end)
    add({ 1, 0, 1, 0 }, function(t) t:SetSize(spread, spread); t:SetPoint("TOPLEFT", frame, "BOTTOMRIGHT", -spread, spread) end)
    add({ inner, 1, 0, 1 }, function(t)
        t:SetHeight(spread)
        t:SetPoint("TOPLEFT", frame, "TOPLEFT", spread, 0)
        t:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -spread, 0)
    end)
    add({ inner, 1, 1, 0 }, function(t)
        t:SetHeight(spread)
        t:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", spread, 0)
        t:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -spread, 0)
    end)
    add({ 0, 1, inner, 1 }, function(t)
        t:SetWidth(spread)
        t:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -spread)
        t:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, spread)
    end)
    add({ 1, 0, inner, 1 }, function(t)
        t:SetWidth(spread)
        t:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -spread)
        t:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, spread)
    end)

    local halo = { frame = frame, pieces = pieces, spread = spread }

    function halo:SetColor(rgb)
        rgb = type(rgb) == "table" and rgb or Theme.Color(rgb)
        self.color = rgb
        for _, texture in ipairs(self.pieces) do
            pcall(texture.SetVertexColor, texture, rgb[1], rgb[2], rgb[3], 1)
        end
    end

    -- Surrounds `target`: the halo's own frame is larger by the spread on
    -- every side, in the same strata, one level below.
    function halo:Attach(target)
        local f = self.frame
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", target, "TOPLEFT", -self.spread, self.spread)
        f:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", self.spread, -self.spread)
        local okStrata, strata = pcall(target.GetFrameStrata, target)
        if okStrata and type(strata) == "string" then pcall(f.SetFrameStrata, f, strata) end
        local okLevel, level = pcall(target.GetFrameLevel, target)
        if okLevel and tonumber(level) then pcall(f.SetFrameLevel, f, math.max(0, tonumber(level) - 1)) end
        self.target = target
    end

    -- Breathes between two alphas. An animation group where the client has
    -- one; otherwise the halo simply stays lit.
    function halo:Pulse()
        local f = self.frame
        pcall(f.SetAlpha, f, HALO.high)
        f:Show()
        if not self.animation and type(f.CreateAnimationGroup) == "function" then
            local ok, group = pcall(f.CreateAnimationGroup, f)
            if ok and type(group) == "table" and type(group.CreateAnimation) == "function" then
                local okFade, fade = pcall(group.CreateAnimation, group, "Alpha")
                if okFade and type(fade) == "table" then
                    pcall(fade.SetFromAlpha, fade, HALO.high)
                    pcall(fade.SetToAlpha, fade, HALO.low)
                    pcall(fade.SetDuration, fade, HALO.period)
                    pcall(fade.SetSmoothing, fade, "IN_OUT")
                    pcall(group.SetLooping, group, "BOUNCE")
                    self.animation = group
                end
            end
        end
        if self.animation then pcall(self.animation.Play, self.animation) end
        self.lit = true
    end

    function halo:Stop()
        if self.animation then pcall(self.animation.Stop, self.animation) end
        self.frame:Hide()
        self.frame:ClearAllPoints()
        self.target = nil
        self.lit = false
    end

    return halo
end
