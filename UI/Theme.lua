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
        skin.bg = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
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
    for _, texture in ipairs(skin.edges) do
        Theme.Fill(texture, border, alpha)
    end
end

function Theme.SetBackground(frame, background, alpha)
    local skin = rawget(frame, "gwSkin")
    if skin then Theme.Fill(skin.bg, background, alpha) end
end

-- A soft drop shadow a few pixels outside a window.
function Theme.Shadow(frame, size)
    size = size or 6
    local shadow = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
    shadow:SetPoint("TOPLEFT", frame, "TOPLEFT", -size, size)
    shadow:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", size, -size)
    Theme.Fill(shadow, "shadow")
    return shadow
end

-- A one-pixel rule.
function Theme.Rule(parent, color, alpha)
    local texture = parent:CreateTexture(nil, "ARTWORK")
    texture:SetHeight(1)
    Theme.Fill(texture, color or "border", alpha)
    return texture
end

-- A short gold accent line under a heading, fading to the right.
function Theme.Accent(parent, width)
    local texture = parent:CreateTexture(nil, "ARTWORK")
    texture:SetSize(width or 24, 2)
    pcall(texture.SetTexture, texture, Theme.WHITE)
    local gold = Theme.colors.gold
    if type(texture.SetGradient) == "function" and type(Globals.CreateColor) == "function" then
        local ok = pcall(texture.SetGradient, texture, "HORIZONTAL", Globals.CreateColor(gold[1], gold[2], gold[3], 1), Globals.CreateColor(gold[1], gold[2], gold[3], 0))
        if ok then return texture end
    end
    Theme.Fill(texture, "gold", 0.8)
    return texture
end
