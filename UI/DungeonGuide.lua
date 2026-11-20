local _, GW = ...

-- The Dungeons view: a dungeon journal in the dashboard, and the dungeon
-- HUD's links into it (the ? button, clickable boss faces, a "next boss"
-- line in the expanded HUD and mechanics in boss tooltips).
--
-- Three levels, one navigation:
--   Dungeons              a grid of dungeon cards (search, level and type
--                         filters, the current dungeon first) | My Runs
--   Deadmines             Overview (the client's map with boss pins, and
--                         the bosses, rares and dangerous trash on the
--                         left) | Quests | My Runs
--   Captain Greenskin     portrait, key mechanics, abilities, and the loot
--                         as a grid of item icons
-- Back and Forward walk the journal's own history; the breadcrumb goes up.
-- A boss from the map, from the list or from the HUD opens the same page.
-- When a run is open, a slim status strip shows its clock and bosses; the
-- floating HUD stays the tracker in combat.
--
-- Built on first open, like every dashboard view. Nothing runs on a timer
-- or OnUpdate: the view repaints when it is shown, on a click, or when the
-- instance, the run or combat changes. Rows, cards and item cells are pools
-- that only grow to the largest list shown; scrolling only moves an offset.
-- The layout follows the window's size (layout), never in combat. The
-- client draws all art (maps, faces, spell and item icons) from IDs;
-- Guildweaver ships none of it. Wishlists are read-only here.
GW.DungeonGuideUI = GW.DungeonGuideUI or {}

local GuideUI = GW.DungeonGuideUI
local Globals = _G or {}
local UI, Theme = GW.UI, GW.Theme
local Guide = GW.DungeonGuide
local Portraits = GW.Portraits
local DungeonMap = GW.DungeonMap

local DOT = "\194\183"
local DASH = "\226\128\148"
local TIMES = "\195\151"
local SEP = "  " .. DOT .. "  "

local ICONS = {
    -- The client's own "unknown item" icon (bags show it for uncached items).
    unknown = "Interface\\Icons\\INV_Misc_QuestionMark",
    -- A spell the client has no icon for: an empty slot, not a red "?".
    noSpell = "Interface\\Buttons\\UI-EmptySlot-Disabled",
    wish = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_3",
    acquired = "Interface\\RaidFrame\\ReadyCheck-Ready",
    rare = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1",
    trash = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8",
    other = "Interface\\Icons\\INV_Misc_Bag_10",
    info = "Interface\\FriendsFrame\\InformationIcon",
    quest = "Interface\\GossipFrame\\AvailableQuestIcon",
    questActive = "Interface\\GossipFrame\\ActiveQuestIcon",
    questIncomplete = "Interface\\GossipFrame\\IncompleteQuestIcon",
    blocked = "Interface\\RaidFrame\\ReadyCheck-NotReady",
    waiting = "Interface\\RaidFrame\\ReadyCheck-Waiting",
    crumb = "Interface\\ChatFrame\\ChatFrameExpandArrow",
    search = "Interface\\Common\\UI-Searchbox-Icon",
    highlight = "Interface\\Buttons\\ButtonHilight-Square",
}
GuideUI.ICONS = ICONS

local QUALITY = { [0] = "9d9d9d", [1] = "ffffff", [2] = "1eff00", [3] = "0070dd", [4] = "a335ee", [5] = "ff8000" }
local QUALITY_RGB = { [0] = { 0.62, 0.62, 0.62 }, [1] = { 1, 1, 1 }, [2] = { 0.12, 1, 0 }, [3] = { 0, 0.44, 0.87 }, [4] = { 0.64, 0.21, 0.93 }, [5] = { 1, 0.5, 0 } }
local FACTIONS = { A = "Alliance", H = "Horde", B = "Both factions" }
local Readiness = GW.DungeonReadiness
-- A quest's state for the current character (GW.DungeonReadiness): its icon
-- and the colour of its short label.
local QUEST_STATE = {
    completed = { icon = "acquired", color = "good" },
    accepted = { icon = "questIncomplete", color = "info" },
    available = { icon = "quest", color = "warn" },
    prerequisites = { icon = "blocked", color = "bad" },
    ineligible = { icon = "blocked", color = "textFaint" },
    unknown = { icon = "waiting", color = "textFaint" },
}
local READINESS_COLOR = { ready = "good", missing = "warn", blocked = "bad", unknown = "textFaint", none = "textFaint" }
local PREREQUISITE_WORDS = { done = "done", accepted = "in your log", missing = "not done", unknown = "not known" }

-- Sizes. The item grid uses bag-sized cells.
local CELL, CELL_GAP = 40, 4
local REWARD_CELL = 28
local BOSS_ROW, SMALL_ROW, ABILITY_ROW, RUN_ROW = 42, 30, 26, 42
-- The boss page's framed header.
local HERO_HEIGHT = 98
local CARD_HEIGHT, CARD_GAP, CARD_MIN = 100, 10, 240
-- The browser's controls: search (140 to 240 wide), the level band and the
-- type switch, and the gap between them.
local SEARCH_MIN, SEARCH_MAX, BAND_WIDTH, KIND_WIDTH, CONTROL_GAP, CONTROL_ROW = 140, 240, 4 * 48, 3 * 60, 8, 30
-- Below this content width the overview stacks the list over the map.
local COMPACT_WIDTH = 520
local TOP_BAR, STRIP = 28, 38
local MECHANIC_ICONS = 3

local function inCombat()
    if type(Globals.InCombatLockdown) ~= "function" then return false end
    local ok, value = pcall(Globals.InCombatLockdown)
    return ok and value == true
end
GuideUI.InCombat = inCombat

function GuideUI.FrameLevel(frame)
    return DungeonMap.FrameLevel(frame)
end

local function prefs()
    return GW.UiPrefs and GW.UiPrefs.Get and GW.UiPrefs.Get("dungeonGuide") or {}
end

local function colorize(text, hex)
    return "|cff" .. hex .. tostring(text) .. "|r"
end

local function noWrap(fontString)
    pcall(fontString.SetWordWrap, fontString, false)
    return fontString
end

local function icon(parent, size, layer)
    local texture = parent:CreateTexture(nil, layer or "ARTWORK")
    texture:SetSize(size, size)
    pcall(texture.SetTexCoord, texture, 0.07, 0.93, 0.07, 0.93)
    return texture
end

local function setIcon(texture, file, crop)
    if texture.gwFile == file then return end
    texture.gwFile = file
    pcall(texture.SetTexture, texture, file)
    if crop == false then pcall(texture.SetTexCoord, texture, 0, 1, 0, 1) end
end

local function wrapText(parent, role, color, width)
    local text = UI.Text(parent, role or "small", color or "textMuted")
    if width then text:SetWidth(width) end
    pcall(text.SetWordWrap, text, true)
    pcall(text.SetJustifyV, text, "TOP")
    return text
end

local function duration(seconds)
    return GW.DungeonHud and GW.DungeonHud.FormatDuration(seconds or 0) or tostring(seconds or 0)
end

-- Art from the client ----------------------------------------------------------------------

-- An item's icon (the client's own item table: no server query, no tooltip).
local itemIcons = {}
function GuideUI.ItemIcon(itemId)
    itemId = tonumber(itemId)
    if not itemId then return ICONS.unknown end
    local cached = itemIcons[itemId]
    if cached ~= nil then return cached or ICONS.unknown end
    local file
    local C_Item = Globals.C_Item
    if C_Item and type(C_Item.GetItemIconByID) == "function" then
        local ok, value = pcall(C_Item.GetItemIconByID, itemId)
        if ok then file = value end
    end
    if not file and type(Globals.GetItemIcon) == "function" then
        local ok, value = pcall(Globals.GetItemIcon, itemId)
        if ok then file = value end
    end
    itemIcons[itemId] = file or false
    return file or ICONS.unknown
end

-- A spell's icon. This client answers through C_Spell (as Guildweaver's own
-- spell telemetry does); the old globals are only a fallback. A spell the
-- client has no icon for gets the empty slot, and keeps its name and label.
local spellIcons = {}
function GuideUI.SpellIcon(spellId)
    spellId = tonumber(spellId)
    if not spellId then return ICONS.noSpell, false end
    local cached = spellIcons[spellId]
    if cached ~= nil then return cached or ICONS.noSpell, cached ~= false end
    local file
    local C_Spell = Globals.C_Spell
    if C_Spell and type(C_Spell.GetSpellTexture) == "function" then
        local ok, value = pcall(C_Spell.GetSpellTexture, spellId)
        if ok and value then file = value end
    end
    if not file and C_Spell and type(C_Spell.GetSpellInfo) == "function" then
        local ok, info = pcall(C_Spell.GetSpellInfo, spellId)
        if ok and type(info) == "table" then file = info.iconID or info.originalIconID end
    end
    if not file and type(Globals.GetSpellTexture) == "function" then
        local ok, value = pcall(Globals.GetSpellTexture, spellId)
        if ok and value then file = value end
    end
    if not file and type(Globals.GetSpellInfo) == "function" then
        local ok, _, _, value = pcall(Globals.GetSpellInfo, spellId)
        if ok and value then file = value end
    end
    spellIcons[spellId] = file or false
    return file or ICONS.noSpell, file ~= nil
end

-- Sets a spell icon, dimmed when the client has none.
local function setSpellIcon(texture, spellId)
    local file, found = GuideUI.SpellIcon(spellId)
    setIcon(texture, file)
    pcall(texture.SetAlpha, texture, found and 1 or 0.55)
end

-- A dungeon card's art: a strip of the dungeon's own map from the client
-- (its first floor's centre tile), or nothing.
function GuideUI.CardArt(instanceId)
    local floors = Guide.Floors(instanceId)
    local floor = floors[1]
    return floor and floor.t and (floor.t[6] or floor.t[1]) or nil
end

-- Text helpers ------------------------------------------------------------------------------

function GuideUI.ItemName(row)
    local item = row.item or {}
    local name = item.n or ("Item " .. row.itemId)
    return colorize(name, QUALITY[item.q or 1] or QUALITY[1])
end

-- "Two-Hand Mace · ilvl 24 · Req. 19"
function GuideUI.ItemFacts(item)
    if type(item) ~= "table" then return nil end
    local parts = {}
    local slot = item.s
    if item.sc and item.sc ~= item.s then slot = slot and (slot .. " " .. item.sc) or item.sc end
    if slot then table.insert(parts, slot) end
    if item.l then table.insert(parts, "ilvl " .. item.l) end
    if item.r then table.insert(parts, "Req. " .. item.r) end
    if item.dps then table.insert(parts, item.dps .. " dps") end
    if item.b == "BoE" then table.insert(parts, "BoE") end
    return #parts > 0 and table.concat(parts, SEP) or nil
end

-- Ability lines for tooltips and the HUD: "KICK  Spell name  summary".
function GuideUI.AbilityText(row)
    local color = Guide.LABEL_COLORS[row.label] or "textMuted"
    return Theme.Colorize(row.label, color) .. "  " .. tostring(row.spell.n) .. (row.spell.s and Theme.Colorize("  " .. row.spell.s, "textFaint") or "")
end

-- Tooltips -------------------------------------------------------------------------------------
--
-- One convention everywhere: next to the cursor (the tooltip's bottom-left
-- just right of and above the pointer), clamped to the screen.

function GuideUI.AnchorTooltip(tooltip, owner)
    local G = Globals
    if type(G.GetCursorPosition) ~= "function" or not G.UIParent then
        pcall(tooltip.SetOwner, tooltip, owner, "ANCHOR_CURSOR")
        return "cursor"
    end
    pcall(tooltip.SetOwner, tooltip, owner, "ANCHOR_NONE")
    pcall(tooltip.ClearAllPoints, tooltip)
    local okCursor, x, y = pcall(G.GetCursorPosition)
    local okScale, scale = pcall(G.UIParent.GetEffectiveScale, G.UIParent)
    scale = okScale and tonumber(scale) or 1
    if not okCursor or not tonumber(x) or scale <= 0 then
        pcall(tooltip.SetPoint, tooltip, "BOTTOMLEFT", owner, "TOPLEFT", 0, 4)
        return "owner"
    end
    pcall(tooltip.SetClampedToScreen, tooltip, true)
    pcall(tooltip.SetPoint, tooltip, "BOTTOMLEFT", G.UIParent, "BOTTOMLEFT", x / scale + 18, y / scale + 6)
    return "cursor"
end

local function addLine(tooltip, text, color, wrap)
    local rgb = type(color) == "table" and color or Theme.Color(color or "textMuted")
    pcall(tooltip.AddLine, tooltip, text, rgb[1], rgb[2], rgb[3], wrap == true)
end

-- A plain titled tooltip at the cursor.
local function textTooltip(owner, title, lines)
    local tooltip = Globals.GameTooltip
    if not tooltip or type(tooltip.SetOwner) ~= "function" then return end
    GuideUI.AnchorTooltip(tooltip, owner)
    pcall(tooltip.ClearLines, tooltip)
    addLine(tooltip, title, "goldBright")
    for _, line in ipairs(lines or {}) do addLine(tooltip, line, "textMuted", true) end
    pcall(tooltip.Show, tooltip)
end
GuideUI.TextTooltip = textTooltip

local function wantsCompare()
    local G = Globals
    if type(G.IsModifiedClick) == "function" then
        local ok, value = pcall(G.IsModifiedClick, "COMPAREITEMS")
        if ok and value then return true end
    end
    if type(G.GetCVarBool) == "function" then
        local ok, value = pcall(G.GetCVarBool, "alwaysCompareItems")
        if ok and value then return true end
    end
    return false
end

-- The client's own item tooltip (with Blizzard's comparison when shift is
-- held or always-compare is on), with what the journal knows underneath.
function GuideUI.ShowItemTooltip(owner, row)
    local tooltip = Globals.GameTooltip
    if not tooltip or type(tooltip.SetOwner) ~= "function" or not row or not row.itemId then return end
    GuideUI.AnchorTooltip(tooltip, owner)
    local shown = type(tooltip.SetHyperlink) == "function" and pcall(tooltip.SetHyperlink, tooltip, "item:" .. row.itemId)
    if not shown then
        pcall(tooltip.ClearLines, tooltip)
        local quality = QUALITY_RGB[(row.item and row.item.q) or 1] or QUALITY_RGB[1]
        addLine(tooltip, (row.item and row.item.n) or ("Item " .. row.itemId), quality)
        local facts = GuideUI.ItemFacts(row.item)
        if facts then addLine(tooltip, facts, "text", true) end
    end
    if row.from then addLine(tooltip, "Drops from " .. row.from, "textMuted") end
    local item = row.item or {}
    if item.qi then addLine(tooltip, "Quest item", "textMuted") end
    if not item.q and item.n then addLine(tooltip, "Quality not known yet", "textFaint") end
    local rate = Guide.RateText(row.rate)
    if rate then addLine(tooltip, "Drop rate: " .. rate, "text") end
    if row.listedBy == "ForeverDB" then
        addLine(tooltip, "Listed by ForeverDB (seen in WoW Forever)", "textFaint")
    elseif row.listedBy then
        addLine(tooltip, "Listed by " .. row.listedBy .. " (Classic reference)", "textFaint")
    end
    if row.item and row.item.set then addLine(tooltip, "Set: " .. row.item.set, "textMuted") end
    if row.acquired then
        addLine(tooltip, "On your wishlist " .. DASH .. " acquired", "good")
    elseif row.wanted then
        addLine(tooltip, "On your wishlist (" .. tostring(row.wanted.priority) .. ")" .. (row.wanted.note and row.wanted.note ~= "" and (": " .. row.wanted.note) or ""),
            "alertWishlist", true)
    end
    if row.kind ~= "wishlist" and not row.quest then
        if item.fv then
            addLine(tooltip, "A WoW Forever item: facts from the Forever client and ForeverDB.", "textFaint", true)
        elseif not rate then
            addLine(tooltip, Guide.REFERENCE_NOTE .. ". Drop chances not shown.", "textFaint", true)
        end
    end
    if rate or row.listedBy == "ForeverDB" or item.fv then addLine(tooltip, Guide.FOREVERDB_CREDIT, "textFaint") end
    pcall(tooltip.Show, tooltip)
    GuideUI.hoveredItem = { owner = owner, row = row }
    if shown and wantsCompare() and type(Globals.GameTooltip_ShowCompareItem) == "function" then
        pcall(Globals.GameTooltip_ShowCompareItem, tooltip)
    end
end

function GuideUI.HideTooltip()
    GuideUI.hoveredItem = nil
    UI.HideTooltip()
    for _, name in ipairs({ "ShoppingTooltip1", "ShoppingTooltip2" }) do
        local compare = Globals[name]
        if compare and type(compare.Hide) == "function" then pcall(compare.Hide, compare) end
    end
end

-- Shift pressed or released over an item: show again (with or without the
-- comparison).
function GuideUI.OnModifierChanged()
    local hovered = GuideUI.hoveredItem
    if hovered and hovered.owner and (type(hovered.owner.IsMouseOver) ~= "function" or hovered.owner:IsMouseOver()) then
        GuideUI.ShowItemTooltip(hovered.owner, hovered.row)
    end
end

-- The client's spell tooltip where it has the spell, then the atlas's label
-- and summary and the reference note.
function GuideUI.ShowSpellTooltip(owner, row)
    local tooltip = Globals.GameTooltip
    if not tooltip or type(tooltip.SetOwner) ~= "function" or not row then return end
    GuideUI.AnchorTooltip(tooltip, owner)
    local shown = type(tooltip.SetSpellByID) == "function" and pcall(tooltip.SetSpellByID, tooltip, row.id)
    if not shown then
        pcall(tooltip.ClearLines, tooltip)
        addLine(tooltip, tostring(row.spell.n), "goldBright")
    end
    addLine(tooltip, row.label .. (row.spell.s and ("  " .. row.spell.s) or ""), Guide.LABEL_COLORS[row.label] or "textMuted", true)
    if not Guide.IsVerified(row.spell) then addLine(tooltip, Guide.REFERENCE_NOTE, "textFaint") end
    pcall(tooltip.Show, tooltip)
end

-- Building blocks ---------------------------------------------------------------------------

-- A clickable row with hover and selected states.
local function rowBase(parent, width, height, onClick)
    local row = UI.CreateFrame("Button", parent)
    row:SetSize(width, height)
    Theme.Skin(row, { 0, 0, 0, 0 }, { 0, 0, 0, 0 })
    if onClick then Theme.Highlight(row, nil, 0.45) end
    pcall(row.RegisterForClicks, row, "LeftButtonUp")
    row:SetScript("OnClick", function(self) if onClick and self.gwData then onClick(self.gwData, self) end end)
    row:SetScript("OnEnter", function(self)
        if self.gwData then
            if not self.gwSelected and onClick then Theme.SetBackground(self, "bgHover") end
            if self.gwEnter then self.gwEnter(self, self.gwData) end
        end
    end)
    row:SetScript("OnLeave", function(self)
        if not self.gwSelected then Theme.SetBackground(self, { 0, 0, 0, 0 }) end
        GuideUI.HideTooltip()
    end)
    function row:SetSelected(selected)
        self.gwSelected = selected == true
        Theme.SetBackground(self, self.gwSelected and "bgActive" or { 0, 0, 0, 0 })
        Theme.SetBorder(self, self.gwSelected and "borderGold" or { 0, 0, 0, 0 })
    end
    function row:Clear()
        self.gwData, self.gwEnter = nil, nil
        self:SetSelected(false)
        self:Hide()
    end
    return row
end

-- The small "Reference" indicator: an info icon with the source in its
-- tooltip. The same one on every page that shows reference data.
local function sourceBadge(parent)
    local badge = UI.CreateFrame("Button", parent)
    badge:SetSize(78, 16)
    badge.icon = badge:CreateTexture(nil, "ARTWORK")
    badge.icon:SetSize(14, 14)
    badge.icon:SetPoint("LEFT", badge, "LEFT", 0, 0)
    pcall(badge.icon.SetTexture, badge.icon, ICONS.info)
    badge.text = UI.Text(badge, "caps", "textFaint")
    badge.text:SetPoint("LEFT", badge.icon, "RIGHT", 3, 0)
    badge.text:SetText("REFERENCE")
    badge:SetScript("OnEnter", function(self) textTooltip(self, self.gwTitle or "Classic reference", self.gwLines) end)
    badge:SetScript("OnLeave", GuideUI.HideTooltip)
    function badge:Set(title, lines)
        self.gwTitle, self.gwLines = title, lines
    end
    return badge
end

-- An encounter row: portrait, name, level and observed state, the top
-- mechanics' spell icons, and how many wishlist items drop.
local function encounterRow(parent, height, onClick)
    local row = rowBase(parent, 200, height, onClick)
    local size = height - 6
    row.portrait = UI.Portrait(row, size)
    pcall(row.portrait.EnableMouse, row.portrait, false)
    row.portrait:SetPoint("LEFT", row, "LEFT", 3, 0)
    local tall = height >= 34
    row.name = noWrap(UI.Text(row, tall and "label" or "small", "text"))
    row.sub = noWrap(UI.Text(row, "small", "textFaint"))
    row.marks = {}
    for index = 1, MECHANIC_ICONS do
        local mark = icon(row, 13, "OVERLAY")
        mark:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4 - (index - 1) * 15, 4)
        row.marks[index] = mark
    end
    row.wish = icon(row, 13, "OVERLAY")
    setIcon(row.wish, ICONS.wish, false)
    row.wishCount = UI.Text(row, "small", "alertWishlist", "RIGHT")
    if tall then
        row.name:SetPoint("TOPLEFT", row.portrait, "TOPRIGHT", 7, -3)
        row.name:SetPoint("RIGHT", row, "RIGHT", -24, 0)
        row.wish:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -5)
    else
        pcall(row.sub.SetJustifyH, row.sub, "RIGHT")
        row.sub:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.name:SetPoint("LEFT", row.portrait, "RIGHT", 7, 0)
        row.name:SetPoint("RIGHT", row.sub, "LEFT", -4, 0)
        row.wish:SetPoint("RIGHT", row.sub, "LEFT", -2, 0)
    end
    row.wishCount:SetPoint("RIGHT", row.wish, "LEFT", -1, 0)
    -- entry: { creature, kind, index, displayId, icon, state, mechanics, wanted, selected, sub }
    function row:Fill(entry)
        self.gwData = entry
        UI.SetText(self.name, entry.name or entry.creature.name)
        Theme.Tint(self.name, entry.state == "defeated" and "textMuted" or (entry.selected and "goldBright" or "text"))
        UI.SetText(self.sub, entry.sub or "")
        self.portrait:SetCreature(entry.displayId, entry.icon)
        self.portrait:SetState(entry.state or (entry.displayId and "available" or "unknown"))
        local shownMarks = 0
        for index, mark in ipairs(self.marks) do
            local mechanic = tall and entry.mechanics and entry.mechanics[index] or nil
            if mechanic then
                setSpellIcon(mark, mechanic.id)
                mark:Show()
                shownMarks = index
            else
                mark:Hide()
            end
        end
        self.gwMarks = shownMarks
        local wanted = entry.wanted or 0
        UI.SetShown(self.wish, wanted > 0)
        UI.SetText(self.wishCount, wanted > 1 and tostring(wanted) or "")
        UI.SetShown(self.wishCount, wanted > 1)
        if tall then
            -- The level and state line stops before the mechanic icons.
            self.sub:ClearAllPoints()
            self.sub:SetPoint("BOTTOMLEFT", self.portrait, "BOTTOMRIGHT", 7, 3)
            self.sub:SetPoint("RIGHT", self, "RIGHT", -(6 + shownMarks * 15), 0)
        end
        self:SetSelected(entry.selected)
        self:Show()
    end
    return row
end

-- An ability: spell icon, label, name and the atlas's short summary.
local function abilityRow(parent)
    local row = rowBase(parent, 300, ABILITY_ROW, nil)
    row.wash = row:CreateTexture(nil, "BACKGROUND", nil, -6)
    row.wash:SetAllPoints(row)
    row.stripe = row:CreateTexture(nil, "BORDER")
    row.stripe:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.stripe:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    row.stripe:SetWidth(3)
    row.icon = icon(row, 22)
    row.icon:SetPoint("LEFT", row, "LEFT", 8, 0)
    row.tag = UI.Text(row, "caps", "info", "LEFT")
    row.tag:SetPoint("LEFT", row.icon, "RIGHT", 7, 0)
    row.tag:SetWidth(46)
    row.text = noWrap(UI.Text(row, "label", "text"))
    row.text:SetPoint("LEFT", row.tag, "RIGHT", 2, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    -- callout: a key mechanic, drawn with its category's colour on the left
    -- edge and a faint wash of it, so kicks and dangers stand out.
    function row:Fill(ability, callout)
        self.gwData, self.gwEnter = ability, GuideUI.ShowSpellTooltip
        setSpellIcon(self.icon, ability.id)
        UI.SetText(self.tag, ability.label)
        local color = Guide.LABEL_COLORS[ability.label] or "textMuted"
        Theme.Tint(self.tag, color)
        self.gwCallout = callout == true
        Theme.Fill(self.stripe, color, callout and 0.9 or 0)
        Theme.Fill(self.wash, color, callout and 0.08 or 0)
        Theme.Font(self.text, callout and "body" or "label")
        UI.SetText(self.text, tostring(ability.spell.n) .. (ability.spell.s and Theme.Colorize("  " .. ability.spell.s, "textFaint") or ""))
        self:SetSelected(false)
        self:Show()
    end
    return row
end

-- An inventory cell: the item's icon in a quality-coloured frame, a purple
-- raid diamond when it is on the wishlist, a check when acquired. Hover for
-- the client's tooltip; there is no click action.
local function itemCell(parent, size)
    local cell = UI.CreateFrame("Button", parent)
    cell:SetSize(size, size)
    Theme.Skin(cell, "bgInset", "border")
    cell.icon = icon(cell, size - 2)
    cell.icon:SetPoint("CENTER", cell, "CENTER", 0, 0)
    -- The bag slot's frame (64 px round a 37 px button, as the client's
    -- item buttons draw it); without it, the hairline in the item's quality.
    cell.slot = cell:CreateTexture(nil, "OVERLAY", nil, -1)
    local out = size * 14 / 36
    cell.slot:SetPoint("TOPLEFT", cell, "TOPLEFT", -out, out)
    cell.slot:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", out, -out)
    cell.gwSlotArt = Theme.Texture(cell.slot, Theme.ART.slot)
    UI.SetShown(cell.slot, cell.gwSlotArt)
    cell.wish = cell:CreateTexture(nil, "OVERLAY")
    cell.wish:SetSize(math.floor(size * 0.38), math.floor(size * 0.38))
    cell.wish:SetPoint("TOPRIGHT", cell, "TOPRIGHT", 3, 3)
    setIcon(cell.wish, ICONS.wish, false)
    cell.check = cell:CreateTexture(nil, "OVERLAY")
    cell.check:SetSize(math.floor(size * 0.4), math.floor(size * 0.4))
    cell.check:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", 2, -2)
    setIcon(cell.check, ICONS.acquired, false)
    pcall(cell.SetHighlightTexture, cell, ICONS.highlight, "ADD")
    cell:SetScript("OnEnter", function(self) if self.gwData then GuideUI.ShowItemTooltip(self, self.gwData) end end)
    cell:SetScript("OnLeave", GuideUI.HideTooltip)
    function cell:Fill(row)
        self.gwData = row
        setIcon(self.icon, GuideUI.ItemIcon(row.itemId))
        local quality = (row.item and row.item.q) or 1
        local rgb = QUALITY_RGB[quality] or QUALITY_RGB[1]
        Theme.SetBorder(self, { rgb[1], rgb[2], rgb[3], quality >= 2 and 1 or 0.55 })
        if self.gwSlotArt then
            -- Common and poor items keep the plain metal; better ones take their colour.
            if quality >= 2 then pcall(self.slot.SetVertexColor, self.slot, rgb[1], rgb[2], rgb[3], 1)
            else pcall(self.slot.SetVertexColor, self.slot, 1, 1, 1, 1) end
        end
        self.gwWanted, self.gwAcquired = (row.wanted and not row.acquired) and true or false, row.acquired == true
        UI.SetShown(self.wish, self.gwWanted)
        UI.SetShown(self.check, self.gwAcquired)
        self:Show()
    end
    function cell:Clear()
        self.gwData = nil
        self:Hide()
    end
    return cell
end

-- A pool of frames that grows to the largest list shown and is reused.
local function pool(make)
    local list = { items = {}, used = 0 }
    function list:Get(index)
        local item = self.items[index]
        if not item then
            item = make(index)
            self.items[index] = item
        end
        if index > self.used then self.used = index end
        return item
    end
    -- Hides everything past `count`.
    function list:Trim(count)
        for index = count + 1, #self.items do
            local item = self.items[index]
            if item.Clear then item:Clear() else item:Hide() end
        end
    end
    return list
end

-- Lays item rows out as a grid in `parent` from (x, y), `width` wide: as
-- many columns of `size` as fit. Returns the grid's height and its number
-- of columns. placeOnly: the cells already show these rows; only move them.
local function layoutGrid(cells, rows, parent, x, y, width, size, gap, placeOnly)
    local columns = math.max(1, math.floor((width + gap) / (size + gap)))
    for index, row in ipairs(rows) do
        local cell = cells:Get(index)
        local column, line = (index - 1) % columns, math.floor((index - 1) / columns)
        cell:ClearAllPoints()
        cell:SetPoint("TOPLEFT", parent, "TOPLEFT", x + column * (size + gap), y - line * (size + gap))
        if not placeOnly then cell:Fill(row) end
    end
    if not placeOnly then cells:Trim(#rows) end
    if #rows == 0 then return 0, columns end
    return math.ceil(#rows / columns) * (size + gap) - gap, columns
end
GuideUI.LayoutGrid = layoutGrid

-- Navigation ------------------------------------------------------------------------------
--
-- A page: { level = "browser", mode = "dungeons"|"runs" }
--         { level = "dungeon", id, tab = "overview"|"quests"|"runs" }
--         { level = "creature", id, kind = "boss"|"rare"|"trash"|"other", index }
-- The history is a list with a cursor: Navigate cuts what lay ahead,
-- Back and Forward move the cursor. Each page keeps its own scroll offsets.

local MAX_HISTORY = 50
local nav = { history = {}, index = 0 }
GuideUI.nav = nav

local state = { floors = {}, browser = { query = "", band = "all", kind = "all" } }
GuideUI.state = state

local function samePage(a, b)
    if not a or not b then return false end
    return a.level == b.level and a.id == b.id and (a.tab or "overview") == (b.tab or "overview") and a.kind == b.kind
        and a.index == b.index and (a.mode or "dungeons") == (b.mode or "dungeons")
end
GuideUI.SamePage = samePage

function GuideUI.CurrentPage()
    return nav.history[nav.index]
end

local function rememberScroll()
    local page, view = GuideUI.CurrentPage(), GuideUI.view
    if not page or not view then return end
    page.scroll = page.scroll or {}
    for key, area in pairs(view.scrollAreas or {}) do
        if area:IsShown() then page.scroll[key] = area:Offset() end
    end
end

-- Goes to a page (a no-op when it is the page shown). The first page is
-- always the dungeon cards, so Back from a first dungeon leads there.
-- quiet: no repaint (the caller repaints).
function GuideUI.Navigate(page, quiet)
    if samePage(page, GuideUI.CurrentPage()) then
        if not quiet then GuideUI.Refresh() end
        return false
    end
    rememberScroll()
    if nav.index == 0 and page.level ~= "browser" then
        table.insert(nav.history, { level = "browser", mode = "dungeons" })
        nav.index = 1
    end
    for index = #nav.history, nav.index + 1, -1 do table.remove(nav.history, index) end
    table.insert(nav.history, page)
    while #nav.history > MAX_HISTORY do table.remove(nav.history, 1) end
    nav.index = #nav.history
    if page.id and page.level ~= "browser" then Guide.Select(page.id) end
    if not quiet then GuideUI.Refresh() end
    return true
end

function GuideUI.Back()
    if nav.index <= 1 then return false end
    rememberScroll()
    nav.index = nav.index - 1
    GuideUI.Refresh()
    return true
end

function GuideUI.Forward()
    if nav.index >= #nav.history then return false end
    rememberScroll()
    nav.index = nav.index + 1
    GuideUI.Refresh()
    return true
end

local function browserPage(mode) return { level = "browser", mode = mode or "dungeons" } end
local function dungeonPage(id, tab) return { level = "dungeon", id = id, tab = tab or "overview" } end
local function creaturePage(id, kind, index) return { level = "creature", id = id, kind = kind, index = index } end
GuideUI.Pages = { browser = browserPage, dungeon = dungeonPage, creature = creaturePage }

-- Data for pages ----------------------------------------------------------------------------

-- What the run open here observed, per boss.
local function encounterStates(instanceId, dungeon)
    local run = Guide.CurrentRun()
    local states = {}
    if not run or tonumber(run.instanceId) ~= Guide.InstanceIdOf(instanceId) then return states end
    for _, boss in ipairs(dungeon.bosses) do states[boss] = Guide.EncounterState(instanceId, boss, run) end
    return states
end

local STATE_TEXT = { engaged = Theme.Colorize("In combat", "bad"), defeated = Theme.Colorize("Defeated", "gold") }

-- The creature a page shows, and its list.
local function pageCreature(dungeon, page)
    if not dungeon or page.level ~= "creature" then return nil end
    local list = page.kind == "boss" and dungeon.bosses or (page.kind == "rare" and dungeon.rares or (page.kind == "trash" and dungeon.trash or nil))
    return list and list[page.index] or nil
end

local function wantedIn(rows)
    local count = 0
    for _, row in ipairs(rows) do
        if row.wanted and not row.acquired then count = count + 1 end
    end
    return count
end

-- Dungeon cards: the filters, then the current dungeon, then the ones for
-- the player's level, then the rest in the atlas's order.
local BANDS = {
    all = function() return true end,
    low = function(d) return (d.lmin or 0) < 30 end,
    mid = function(d) return (d.lmin or 0) >= 30 and (d.lmin or 0) < 50 end,
    high = function(d) return (d.lmin or 0) >= 50 end,
}

local function playerLevel()
    if type(Globals.UnitLevel) ~= "function" then return nil end
    local ok, value = pcall(Globals.UnitLevel, "player")
    return ok and tonumber(value) or nil
end

local function suits(dungeon, level)
    return level and dungeon.lmin and dungeon.kind ~= "raid" and level >= dungeon.lmin and level <= (dungeon.lmax or dungeon.lmin) or false
end

function GuideUI.BrowserList(filters)
    filters = filters or state.browser
    local query = Guide.NormalizeName(filters.query or "")
    local band = BANDS[filters.band or "all"] or BANDS.all
    -- Inside a dungeon whose wing is not known yet, each of its wings is
    -- "here": none is picked for the player.
    local current, instance, level = Guide.CurrentGuideId(), Guide.CurrentInstanceId(), playerLevel()
    local list = {}
    for order, dungeon in ipairs(Guide.List()) do
        local kindOk = filters.kind == nil or filters.kind == "all" or (filters.kind == "raid") == (dungeon.kind == "raid")
        local nameOk = not query or string.find(Guide.NormalizeName(dungeon.name) or "", query, 1, true) ~= nil
        if kindOk and nameOk and band(dungeon) then
            local here = dungeon.id == current or (current == instance and instance ~= nil and dungeon.instanceId == instance)
            local rank = here and 0 or (suits(dungeon, level) and 1 or 2)
            table.insert(list, { dungeon = dungeon, rank = rank, order = order, suggested = rank == 1 })
        end
    end
    table.sort(list, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.order < b.order
    end)
    local result = {}
    for _, entry in ipairs(list) do
        entry.dungeon.gwSuggested = entry.suggested
        table.insert(result, entry.dungeon)
    end
    return result
end

-- The view ------------------------------------------------------------------------------------

local main = GW.MainFrame

local function scrollArea(view, key, parent)
    local area = UI.ScrollArea(parent, { step = 48 })
    view.scrollAreas[key] = area
    return area
end

-- Top bar: Back, Forward, the breadcrumb, and the way to the current dungeon.
local function buildTopBar(view)
    local bar = UI.CreateFrame("Frame", view)
    bar:SetHeight(TOP_BAR - 4)
    bar:SetPoint("TOPLEFT", view, "TOPLEFT", 0, 0)
    bar:SetPoint("TOPRIGHT", view, "TOPRIGHT", 0, 0)
    bar.back = DungeonMap.Arrow(bar, DungeonMap.PREV, function() GuideUI.Back() end)
    bar.back:SetPoint("LEFT", bar, "LEFT", -4, 0)
    bar.back:SetScript("OnEnter", function(self) textTooltip(self, "Back", nil) end)
    bar.back:SetScript("OnLeave", GuideUI.HideTooltip)
    bar.forward = DungeonMap.Arrow(bar, DungeonMap.NEXT, function() GuideUI.Forward() end)
    bar.forward:SetPoint("LEFT", bar.back, "RIGHT", 0, 0)
    bar.forward:SetScript("OnEnter", function(self) textTooltip(self, "Forward", nil) end)
    bar.forward:SetScript("OnLeave", GuideUI.HideTooltip)
    bar.crumbs = {}
    for index = 1, 3 do
        local crumb = UI.CreateFrame("Button", bar)
        crumb:SetHeight(20)
        crumb.label = noWrap(UI.Text(crumb, "label", "gold"))
        crumb.label:SetPoint("LEFT", crumb, "LEFT", 0, 0)
        -- Bounded by the crumb: a crumb shortened to fit truncates its name.
        crumb.label:SetPoint("RIGHT", crumb, "RIGHT", 0, 0)
        crumb.arrow = crumb:CreateTexture(nil, "ARTWORK")
        crumb.arrow:SetSize(12, 12)
        pcall(crumb.arrow.SetTexture, crumb.arrow, ICONS.crumb)
        crumb.arrow:SetPoint("RIGHT", crumb, "LEFT", -5, 0)
        pcall(crumb.RegisterForClicks, crumb, "LeftButtonUp")
        crumb:SetScript("OnClick", function(self) if self.gwPage then GuideUI.Navigate(self.gwPage) end end)
        crumb:SetScript("OnEnter", function(self) if self.gwPage then Theme.Tint(self.label, "goldBright") end end)
        crumb:SetScript("OnLeave", function(self) if self.gwPage then Theme.Tint(self.label, "gold") end end)
        if index == 1 then
            crumb:SetPoint("LEFT", bar.forward, "RIGHT", 6, 0)
        else
            crumb:SetPoint("LEFT", bar.crumbs[index - 1], "RIGHT", 22, 0)
        end
        UI.SetShown(crumb.arrow, index > 1)
        bar.crumbs[index] = crumb
    end
    bar.here = UI.Button(bar, "Current dungeon", { width = 124, height = 20, variant = "primary", role = "small",
        tooltip = "Current dungeon", tooltipLines = { "Opens the dungeon you are in." },
        onClick = function()
            local current = Guide.CurrentGuideId()
            if current then
                Guide.FollowCurrent()
                GuideUI.Navigate(dungeonPage(current))
            end
        end })
    bar.here:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
    view.topBar = bar
end

-- The open run: clock, state and bosses, with the timer, End run and the
-- HUD's visibility. The HUD keeps everything else.
local function buildStrip(view)
    local strip = UI.Card(view)
    strip:SetHeight(STRIP - 6)
    strip:SetPoint("TOPLEFT", view, "TOPLEFT", 0, -TOP_BAR)
    strip:SetPoint("TOPRIGHT", view, "TOPRIGHT", 0, -TOP_BAR)
    strip.dot = UI.Dot(strip, 8)
    strip.dot:SetPoint("LEFT", strip, "LEFT", 12, 0)
    strip.name = UI.CreateFrame("Button", strip)
    strip.name:SetSize(160, 20)
    strip.name:SetPoint("LEFT", strip.dot, "RIGHT", 8, 0)
    strip.name.label = noWrap(UI.Text(strip.name, "label", "gold"))
    strip.name.label:SetAllPoints(strip.name)
    pcall(strip.name.RegisterForClicks, strip.name, "LeftButtonUp")
    strip.name:SetScript("OnClick", function()
        local run = Guide.CurrentRun()
        -- The run's wing when its evidence named one, else the dungeon.
        local id = run and (Guide.NormalizeId(run.wing and run.wing.key) or Guide.NormalizeId(run.instanceId))
        if id then GuideUI.Navigate(dungeonPage(id)) end
    end)
    strip.clock = UI.Text(strip, "clockSmall", "text")
    strip.clock:SetPoint("LEFT", strip.name, "RIGHT", 8, 0)
    strip.state = noWrap(UI.Text(strip, "small", "textMuted"))
    strip.state:SetPoint("LEFT", strip.clock, "RIGHT", 10, 0)
    strip.hud = UI.Button(strip, "Show HUD", { width = 78, height = 20, variant = "ghost", role = "small", onClick = function()
        local tracker = GW.DungeonHud
        if tracker.IsEnabled() and not tracker.IsHiddenForRun() then tracker:SetEnabled(false) else tracker:ShowNow() end
        GuideUI.Refresh()
    end })
    strip.hud:SetPoint("RIGHT", strip, "RIGHT", -8, 0)
    strip.finish = UI.ConfirmButton(strip, "End run", "Click to end", { width = 84, height = 20,
        tooltip = "End run", tooltipLines = { "Saves the run as completed and closes it. Pause only stops the clock." },
        onClick = function()
            if GW.DungeonSessions.Finish() then
                GW.Print("Dungeon run saved as completed. It reaches the website after /reload or logout.")
            end
            GuideUI.Refresh()
        end })
    strip.finish:SetPoint("RIGHT", strip.hud, "LEFT", -6, 0)
    strip.timer = UI.Button(strip, "Start", { width = 70, height = 20, variant = "primary", onClick = function()
        GW.DungeonSessions.ToggleTimer()
        GuideUI.Refresh()
    end })
    strip.timer:SetPoint("RIGHT", strip.finish, "LEFT", -6, 0)
    strip.state:SetPoint("RIGHT", strip.timer, "LEFT", -10, 0)
    strip:Hide()
    view.strip = strip
end

local function refreshStrip(view)
    local strip = view.strip
    local run = GW.DungeonSessions and GW.DungeonSessions.Current() or nil
    if not run then
        strip:Hide()
        return false
    end
    local hud = GW.DungeonHud
    local displayState = hud.DisplayState(run)
    UI.SetText(strip.name.label, tostring(run.name or "Instance"))
    UI.SetText(strip.clock, hud.ClockText(run))
    Theme.Tint(strip.clock, main.StateColor and main.StateColor(displayState) or "text")
    strip.dot:SetStatus(displayState == "running" and "good" or (displayState == "paused" and "warn" or "textFaint"))
    local parts = { hud.StateText(run) }
    if run.bossesTotal or (run.bossesDefeated or 0) > 0 then
        table.insert(parts, "Bosses " .. hud.BossCountText(run))
    end
    if (run.deaths or 0) > 0 then table.insert(parts, run.deaths .. (run.deaths == 1 and " death" or " deaths")) end
    if not run.inside then table.insert(parts, "outside") end
    UI.SetText(strip.state, table.concat(parts, SEP))
    strip.timer:SetLabel(hud.TimerButtonText(run))
    strip.timer:SetVariant(displayState == "running" and "secondary" or "primary")
    strip.hud:SetLabel((hud.IsEnabled() and not hud.IsHiddenForRun()) and "Hide HUD" or "Show HUD")
    strip:Show()
    return true
end

-- Browser -----------------------------------------------------------------------------------

local function dungeonCard(parent)
    local card = UI.Card(parent, function(self)
        if self.gwData then GuideUI.Navigate(dungeonPage(self.gwData.id)) end
    end)
    card:SetHeight(CARD_HEIGHT)
    Theme.Panel(card, "stone")
    Theme.SetBorder(card, "borderStrong")
    Theme.Highlight(card, nil, 0.25)
    card:SetScript("OnEnter", function(self) Theme.SetBorder(self, "gold") end)
    card.art = card:CreateTexture(nil, "BACKGROUND", nil, -5)
    card.art:SetPoint("TOPLEFT", card, "TOPLEFT", 3, -3)
    card.art:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -3, 3)
    pcall(card.art.SetTexCoord, card.art, 0, 1, 0.3, 0.7)
    pcall(card.art.SetAlpha, card.art, 0.5)
    card.art:Hide()
    -- No map art: the Guildweaver emblem, large and faint, on the right.
    card.emblem = card:CreateTexture(nil, "BACKGROUND", nil, -5)
    card.emblem:SetSize(CARD_HEIGHT - 12, CARD_HEIGHT - 12)
    card.emblem:SetPoint("RIGHT", card, "RIGHT", -6, 0)
    pcall(card.emblem.SetTexture, card.emblem, Theme.EMBLEM)
    pcall(card.emblem.SetAlpha, card.emblem, 0.14)
    card.emblem:Hide()
    -- A dark wash on the left keeps the text readable over the map.
    card.wash = card:CreateTexture(nil, "BACKGROUND", nil, -4)
    card.wash:SetPoint("TOPLEFT", card, "TOPLEFT", 1, -1)
    card.wash:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -1, 1)
    pcall(card.wash.SetTexture, card.wash, Theme.WHITE)
    local shade = Theme.colors.bgRaised
    if type(card.wash.SetGradient) ~= "function" or type(Globals.CreateColor) ~= "function"
        or not pcall(card.wash.SetGradient, card.wash, "HORIZONTAL", Globals.CreateColor(shade[1], shade[2], shade[3], 0.95), Globals.CreateColor(shade[1], shade[2], shade[3], 0.15)) then
        Theme.Fill(card.wash, "bgRaised", 0.55)
    end
    card.name = noWrap(UI.Text(card, "title", "goldBright"))
    card.name:SetPoint("TOPLEFT", card, "TOPLEFT", 14, -12)
    card.name:SetPoint("RIGHT", card, "RIGHT", -12, 0)
    card.meta = noWrap(UI.Text(card, "small", "text"))
    card.meta:SetPoint("TOPLEFT", card.name, "BOTTOMLEFT", 0, -6)
    card.meta:SetPoint("RIGHT", card, "RIGHT", -12, 0)
    card.ready = noWrap(UI.Text(card, "small", "textMuted"))
    card.ready:SetPoint("TOPLEFT", card.meta, "BOTTOMLEFT", 0, -4)
    card.ready:SetPoint("RIGHT", card, "RIGHT", -12, 0)
    card.kind = noWrap(UI.Text(card, "caps", "textFaint"))
    card.kind:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 14, 11)
    card.flags = noWrap(UI.Text(card, "small", "text", "RIGHT"))
    card.flags:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -12, 10)
    card.wish = icon(card, 13, "OVERLAY")
    setIcon(card.wish, ICONS.wish, false)
    card.wish:SetPoint("RIGHT", card.flags, "LEFT", -3, 0)
    card:SetScript("OnLeave", function(self) Theme.SetBorder(self, self.gwSelected and "gold" or "borderStrong") end)
    function card:Fill(dungeon, info)
        self.gwData = dungeon
        UI.SetText(self.name, dungeon.name)
        local meta = {}
        local levels = Guide.LevelText(dungeon.lmin, dungeon.lmax)
        if levels then table.insert(meta, "Levels " .. levels) end
        if dungeon.zone then table.insert(meta, dungeon.zone) end
        UI.SetText(self.meta, table.concat(meta, SEP))
        local entry = Guide.Entry(dungeon.id) or {}
        local kind = { dungeon.kind == "raid" and "RAID" or "DUNGEON" }
        if entry.bosses and entry.bosses > 0 then table.insert(kind, entry.bosses .. (entry.bosses == 1 and " BOSS" or " BOSSES")) end
        UI.SetText(self.kind, table.concat(kind, SEP))
        local flags = {}
        if info.wanted > 0 then table.insert(flags, Theme.Colorize(tostring(info.wanted), "alertWishlist")) end
        if info.runs > 0 then table.insert(flags, Theme.Colorize(info.runs .. (info.runs == 1 and " run" or " runs"), "textMuted")) end
        if info.here then
            table.insert(flags, Theme.Colorize("You are here", "good"))
        elseif dungeon.gwSuggested then
            table.insert(flags, Theme.Colorize("Your level", "gold"))
        end
        UI.SetText(self.flags, table.concat(flags, "   "))
        -- The character's quest readiness, when the dungeon has quests to hold.
        local readiness = GuideUI.QuestReadiness and GuideUI.QuestReadiness(dungeon.id) or nil
        if readiness and readiness.required > 0 then
            local line = Readiness.OVERVIEW_LABELS[readiness.readiness]
            if readiness.readiness == "missing" then line = readiness.counts.available .. (readiness.counts.available == 1 and " quest" or " quests") .. " to pick up" end
            UI.SetText(self.ready, Theme.Colorize(line, READINESS_COLOR[readiness.readiness]))
        else
            UI.SetText(self.ready, "")
        end
        -- The diamond sits before the flags, of which the count is the first.
        UI.SetShown(self.wish, info.wanted > 0)
        -- The map strip, set once per card and never in combat.
        local art = GuideUI.CardArt(dungeon.id)
        if art and self.gwArt ~= art then
            if inCombat() then
                GuideUI.pending = true
            else
                self.gwArt = art
                pcall(self.art.SetTexture, self.art, art)
            end
        end
        UI.SetShown(self.art, art ~= nil and self.gwArt == art)
        UI.SetShown(self.emblem, not (art ~= nil and self.gwArt == art))
        self.gwSelected = info.selected
        Theme.SetBorder(self, info.selected and "gold" or "borderStrong")
        self:Show()
    end
    function card:Clear()
        self.gwData = nil
        self:Hide()
    end
    return card
end

local function runRow(parent, onClick)
    local row = rowBase(parent, 300, RUN_ROW, onClick)
    row.title = noWrap(UI.Text(row, "label", "text"))
    row.title:SetPoint("TOPLEFT", row, "TOPLEFT", 10, -6)
    row.when = noWrap(UI.Text(row, "small", "textFaint"))
    row.when:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 10, 6)
    row.time = UI.Text(row, "clockSmall", "text", "RIGHT")
    row.time:SetPoint("TOPRIGHT", row, "TOPRIGHT", -10, -5)
    row.outcome = noWrap(UI.Text(row, "small", "textMuted", "RIGHT"))
    row.outcome:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -10, 6)
    row.title:SetPoint("RIGHT", row.time, "LEFT", -10, 0)
    row.when:SetPoint("RIGHT", row.outcome, "LEFT", -10, 0)
    row.rule = Theme.Rule(row, "border", 0.6)
    row.rule:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    row.rule:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    -- entry: a finished run from DungeonSessions' history.
    function row:Fill(entry, showName)
        self.gwData = entry
        local date = main.ShortDate and main.ShortDate(entry.startedAt) or nil
        -- The wing the run's evidence resolved, else its dungeon.
        UI.SetText(self.title, showName and tostring(entry.wingName or entry.name or "Instance") or (date or "Run"))
        local meta = {}
        if showName and date then table.insert(meta, date) end
        if entry.bossesTotal or (entry.bossesDefeated or 0) > 0 then
            table.insert(meta, "Bosses " .. GW.DungeonHud.BossCountText(entry))
        end
        if (entry.deaths or 0) > 0 then table.insert(meta, entry.deaths .. (entry.deaths == 1 and " death" or " deaths")) end
        UI.SetText(self.when, table.concat(meta, SEP))
        UI.SetText(self.time, duration(entry.timerSeconds or entry.durationSeconds))
        local word, color = "", "textFaint"
        if main.Outcome then word, color = main.Outcome(entry) end
        UI.SetText(self.outcome, word)
        Theme.Tint(self.outcome, color)
        self:SetSelected(false)
        self:Show()
    end
    return row
end

local function buildBrowser(view)
    local page = UI.CreateFrame("Frame", view)
    page.title = UI.Text(page, "pageTitle", "goldBright")
    page.title:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
    page.title:SetText("Dungeons")
    page.mode = UI.Segmented(page, { { "dungeons", "Journal" }, { "runs", "My Runs" } }, function()
        local current = GuideUI.CurrentPage()
        return current and current.mode or "dungeons"
    end, function(value) GuideUI.Navigate(browserPage(value)) end, { segmentWidth = 84, height = 22 })
    page.mode:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, 0)

    page.search = UI.Input(page, 160, function(box) box:ClearFocus() end)
    page.search:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -32)
    page.searchIcon = page.search:CreateTexture(nil, "OVERLAY")
    page.searchIcon:SetSize(12, 12)
    page.searchIcon:SetPoint("RIGHT", page.search, "RIGHT", -6, 0)
    pcall(page.searchIcon.SetTexture, page.searchIcon, ICONS.search)
    page.hint = UI.Text(page.search, "label", "textFaint")
    page.hint:SetPoint("LEFT", page.search, "LEFT", 7, 0)
    page.hint:SetText("Search dungeons")
    page.search:SetScript("OnTextChanged", function(box)
        local ok, text = pcall(box.GetText, box)
        state.browser.query = ok and type(text) == "string" and text or ""
        UI.SetShown(page.hint, state.browser.query == "")
        GuideUI.Refresh()
    end)
    page.band = UI.Segmented(page, { { "all", "All" }, { "low", "10\226\128\14729" }, { "mid", "30\226\128\14749" }, { "high", "50+" } },
        function() return state.browser.band end, function(value)
            state.browser.band = value
            GuideUI.Refresh()
        end, { segmentWidth = 48, height = 22 })
    page.band:SetPoint("LEFT", page.search, "RIGHT", 8, 0)
    page.kind = UI.Segmented(page, { { "all", "All" }, { "dungeon", "Dungeons" }, { "raid", "Raids" } },
        function() return state.browser.kind end, function(value)
            state.browser.kind = value
            GuideUI.Refresh()
        end, { segmentWidth = 60, height = 22 })
    page.kind:SetPoint("LEFT", page.band, "RIGHT", 8, 0)

    page.grid = scrollArea(view, "grid", page)
    page.grid:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -64)
    page.cards = pool(function() return dungeonCard(page.grid.child) end)
    page.empty = wrapText(page, "label", "textFaint", 400)
    page.empty:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -70)

    page.runs = scrollArea(view, "allRuns", page)
    page.runs:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -34)
    page.runRows = pool(function()
        return runRow(page.runs.child, function(entry)
            local id = Guide.RunGuideId(entry)
            if id then GuideUI.Navigate(dungeonPage(id, "runs")) end
        end)
    end)
    view.browser = page
end

-- Card columns for a grid `width` wide: as many cards of at least
-- CARD_MIN as fit, one to three.
function GuideUI.Columns(width)
    return math.max(1, math.min(3, math.floor(((tonumber(width) or 0) + CARD_GAP) / (CARD_MIN + CARD_GAP))))
end

-- The browser's controls in rows that fit `width`: one row when they all
-- fit, else the search alone and the two switches together, else each on
-- its own row. Returns the rows' widths (for the tests) and where the grid
-- starts.
local function layoutControls(page, width)
    local rows
    local search
    if width >= SEARCH_MIN + BAND_WIDTH + KIND_WIDTH + CONTROL_GAP * 2 then
        search = math.min(SEARCH_MAX, width - BAND_WIDTH - KIND_WIDTH - CONTROL_GAP * 2)
        page.band:ClearAllPoints()
        page.band:SetPoint("LEFT", page.search, "RIGHT", CONTROL_GAP, 0)
        page.kind:ClearAllPoints()
        page.kind:SetPoint("LEFT", page.band, "RIGHT", CONTROL_GAP, 0)
        rows = { search + CONTROL_GAP + BAND_WIDTH + CONTROL_GAP + KIND_WIDTH }
    elseif width >= BAND_WIDTH + KIND_WIDTH + CONTROL_GAP then
        search = math.min(SEARCH_MAX, width)
        page.band:ClearAllPoints()
        page.band:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -32 - CONTROL_ROW)
        page.kind:ClearAllPoints()
        page.kind:SetPoint("LEFT", page.band, "RIGHT", CONTROL_GAP, 0)
        rows = { search, BAND_WIDTH + CONTROL_GAP + KIND_WIDTH }
    else
        search = math.min(SEARCH_MAX, width)
        page.band:ClearAllPoints()
        page.band:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -32 - CONTROL_ROW)
        page.kind:ClearAllPoints()
        page.kind:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -32 - CONTROL_ROW * 2)
        rows = { search, BAND_WIDTH, KIND_WIDTH }
    end
    page.search:SetWidth(search)
    page.gwControlRows = rows
    return 32 + #rows * CONTROL_ROW + 2
end

local function layoutBrowser(view, width, height)
    local page = view.browser
    page.gwWidth, page.gwHeight = width, height
    local gridTop = layoutControls(page, width)
    page.gwGridTop = gridTop
    page.grid:ClearAllPoints()
    page.grid:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -gridTop)
    page.grid:SetViewSize(width, height - gridTop)
    page.runs:SetViewSize(width, height - 34)
    page.empty:SetWidth(math.min(400, width))
    page.columns = GuideUI.Columns(page.grid:ContentWidth())
end

-- Places the cards shown in the grid's columns (no data is read).
local function placeCards(page, count)
    local columns = page.columns or 1
    local width = page.grid:ContentWidth()
    local cardWidth = math.floor((width - CARD_GAP * (columns - 1)) / columns)
    page.gwCardWidth = cardWidth
    for index = 1, count do
        local card = page.cards:Get(index)
        card:SetWidth(cardWidth)
        card:ClearAllPoints()
        local column, line = (index - 1) % columns, math.floor((index - 1) / columns)
        card:SetPoint("TOPLEFT", page.grid.child, "TOPLEFT", column * (cardWidth + CARD_GAP), -line * (CARD_HEIGHT + CARD_GAP))
    end
    page.grid:SetContentHeight(count > 0 and (math.ceil(count / columns) * (CARD_HEIGHT + CARD_GAP) - CARD_GAP) or 0)
end

local function placeRunRows(area, rows, count)
    local width = area:ContentWidth()
    for index = 1, count do
        local row = rows:Get(index)
        row:SetWidth(width)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", area.child, "TOPLEFT", 0, -(index - 1) * RUN_ROW)
    end
    area:SetContentHeight(count * RUN_ROW)
end

local function refreshBrowser(view, current)
    local page = view.browser
    local mode = current.mode or "dungeons"
    page.mode:Refresh()
    local journal = mode == "dungeons"
    for _, widget in ipairs({ page.search, page.band, page.kind, page.grid }) do UI.SetShown(widget, journal) end
    UI.SetShown(page.runs, not journal)
    if not journal then
        page.cards:Trim(0)
        view.gwShownCards = 0
        local runs = Guide.Runs(nil)
        for index, entry in ipairs(runs) do page.runRows:Get(index):Fill(entry, true) end
        page.runRows:Trim(#runs)
        page.gwRunCount = #runs
        placeRunRows(page.runs, page.runRows, #runs)
        UI.SetText(page.empty, #runs == 0 and "No finished runs yet. Runs are recorded on their own when you enter a dungeon or raid." or "")
        page.empty:ClearAllPoints()
        page.empty:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -40)
        UI.SetShown(page.empty, #runs == 0)
        return
    end
    page.band:Refresh()
    page.kind:Refresh()
    local list = GuideUI.BrowserList()
    local here, instance = Guide.CurrentGuideId(), Guide.CurrentInstanceId()
    local selected = Guide.NormalizeId(prefs().wingKey) or tonumber(prefs().instanceId)
    local wishes, runs = Guide.WishlistByDungeon(), {}
    -- A wing counts the runs resolved to it; ambiguous runs stay on the dungeon.
    for _, entry in ipairs(Guide.Runs(nil)) do
        local id = Guide.RunGuideId(entry)
        if id then runs[id] = (runs[id] or 0) + 1 end
    end
    for index, dungeon in ipairs(list) do
        local isHere = dungeon.id == here or (here ~= nil and here == instance and dungeon.instanceId == instance)
        page.cards:Get(index):Fill(dungeon, { here = isHere, selected = dungeon.id == selected and not isHere,
            wanted = Guide.DungeonWishlistCount(dungeon.id, wishes), runs = runs[dungeon.id] or 0 })
    end
    page.cards:Trim(#list)
    page.runRows:Trim(0)
    page.gwRunCount = 0
    placeCards(page, #list)
    UI.SetText(page.empty, #list == 0 and "No dungeon matches. Clear the search or choose All." or "")
    page.empty:ClearAllPoints()
    page.empty:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -(page.gwGridTop or 64) - 6)
    UI.SetShown(page.empty, #list == 0)
    view.gwShownCards = #list
end

-- Dungeon and creature pages ------------------------------------------------------------------

local TABS = { { "overview", "Overview" }, { "quests", "Quests" }, { "runs", "My Runs" } }

local function pinTooltip(pin, owner)
    local lines = {}
    local level = Guide.CreatureLevel(pin.creature)
    if level then table.insert(lines, "Level " .. level) end
    for _, row in ipairs(Guide.TopMechanics(pin.creature, nil, 2)) do table.insert(lines, GuideUI.AbilityText(row)) end
    table.insert(lines, Theme.Colorize("Position from Blizzard's dungeon journal. Click for the encounter.", "textFaint"))
    textTooltip(owner, pin.index .. ". " .. pin.creature.name, lines)
end

local function questRow(parent)
    local row = UI.CreateFrame("Frame", parent)
    row:SetSize(300, 60)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -1)
    row.name = noWrap(UI.Text(row, "label", "goldBright"))
    row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 22, 0)
    row.facts = noWrap(UI.Text(row, "small", "textMuted", "RIGHT"))
    row.facts:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, -1)
    row.name:SetPoint("RIGHT", row.facts, "LEFT", -10, 0)
    row.giver = noWrap(UI.Text(row, "small", "textMuted"))
    row.giver:SetPoint("TOPLEFT", row, "TOPLEFT", 22, -18)
    row.giver:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.objective = wrapText(row, "small", "text")
    row.objective:SetPoint("TOPLEFT", row, "TOPLEFT", 22, -34)
    row.objective:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.rewardLabel = UI.Text(row, "caps", "textFaint")
    row.rewards = pool(function() return itemCell(row, REWARD_CELL) end)
    row.rule = Theme.Rule(row, "border", 0.6)
    row.rule:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    row.rule:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    -- Lays the quest out; returns its height.
    function row:Fill(quest)
        self.gwData = quest
        local style = quest.state and QUEST_STATE[quest.state] or nil
        local done = not style and Guide.QuestCompleted(quest.id)
        -- In the log: the grey "?" until its objectives are done, then the gold one.
        local iconName = style and (quest.state == "accepted" and quest.turnIn and "questActive" or style.icon) or nil
        setIcon(self.icon, iconName and ICONS[iconName] or (done and ICONS.acquired or ICONS.quest), false)
        UI.SetText(self.name, tostring(quest.name))
        local facts = {}
        if style then
            local label = quest.state == "accepted" and quest.turnIn and "Ready to turn in" or Readiness.STATE_LABELS[quest.state]
            table.insert(facts, Theme.Colorize(label, style.color))
        end
        if quest.lvl then table.insert(facts, "Level " .. quest.lvl) end
        if quest.min then table.insert(facts, "Requires " .. quest.min) end
        if quest.fac and FACTIONS[quest.fac] then table.insert(facts, FACTIONS[quest.fac]) end
        -- No source records its chain: prerequisites unknown, not none.
        if quest.prek == false then table.insert(facts, Theme.Colorize("Prerequisites not known", "textFaint")) end
        if done then table.insert(facts, Theme.Colorize("Completed", "good")) end
        UI.SetText(self.facts, table.concat(facts, SEP))
        local giver = {}
        if quest.giver then
            local where = quest.where and (quest.where .. (quest.x and quest.y and (" " .. Guide.Coordinates(quest.x, quest.y)) or "")) or nil
            table.insert(giver, "From " .. quest.giver .. (where and (", " .. where) or ""))
        end
        if quest.chain and quest.chain[1] then
            local steps = {}
            for _, step in ipairs(quest.chain) do
                table.insert(steps, step.name .. " (" .. Theme.Colorize(PREREQUISITE_WORDS[step.status] or "not known", step.status == "missing" and "bad"
                    or (step.status == "done" and "good" or "textFaint")) .. ")")
            end
            table.insert(giver, "Needs " .. table.concat(steps, ", "))
        elseif quest.pre and quest.pre[1] then
            table.insert(giver, "After " .. table.concat(quest.pre, ", "))
        end
        if quest.why then table.insert(giver, Theme.Colorize("Not known: " .. quest.why, "textFaint")) end
        UI.SetText(self.giver, #giver > 0 and table.concat(giver, SEP) or Theme.Colorize("No giver or objective in the atlas.", "textFaint"))
        UI.SetText(self.objective, quest.obj or "")
        local rewards = {}
        for _, itemId in ipairs(quest.rew or {}) do
            table.insert(rewards, { itemId = itemId, item = Guide.Item(itemId), quest = true, wanted = Guide.Wanted(itemId) })
        end
        for index, reward in ipairs(rewards) do self.rewards:Get(index):Fill(reward) end
        self.rewards:Trim(#rewards)
        self.gwRewards = rewards
        UI.SetText(self.rewardLabel, quest.choice and "CHOOSE ONE" or "REWARDS")
        self:Show()
        return self:Layout(self.gwWidth or 300)
    end
    -- Places the quest's parts for a row `width` wide (the objective wraps,
    -- rewards wrap onto more lines). Returns its height.
    function row:Layout(width)
        self.gwWidth = width
        self:SetWidth(width)
        local quest = self.gwData
        local y = -34
        if quest.obj then
            self.objective:SetWidth(math.max(60, width - 22))
            local ok, measured = pcall(self.objective.GetStringHeight, self.objective)
            measured = ok and tonumber(measured) or nil
            self.objective:Show()
            y = y - math.max(14, measured or 28) - 6
        else
            self.objective:Hide()
        end
        local rewards = self.gwRewards or {}
        if #rewards > 0 then
            self.rewardLabel:ClearAllPoints()
            self.rewardLabel:SetPoint("TOPLEFT", self, "TOPLEFT", 22, y - 9)
            self.rewardLabel:Show()
            local height = layoutGrid(self.rewards, rewards, self, 108, y, math.max(REWARD_CELL, width - 108), REWARD_CELL, 4, true)
            y = y - height - 4
        else
            self.rewardLabel:Hide()
        end
        local height = -y + 10
        self:SetHeight(height)
        return height
    end
    function row:Clear() self:Hide() end
    return row
end

local function buildDungeonPage(view)
    local page = UI.CreateFrame("Frame", view)
    page.title = noWrap(UI.Text(page, "pageTitle", "goldBright"))
    page.title:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
    page.badge = sourceBadge(page)
    page.badge:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, -25)
    page.sub = noWrap(UI.Text(page, "label", "textMuted"))
    page.sub:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -24)
    page.sub:SetPoint("RIGHT", page.badge, "LEFT", -10, 0)
    page.tabs = UI.Segmented(page, TABS, function()
        local current = GuideUI.CurrentPage()
        return current and current.level == "dungeon" and current.tab or "overview"
    end, function(value)
        local current = GuideUI.CurrentPage()
        if current and current.id then GuideUI.Navigate(dungeonPage(current.id, value)) end
    end, { segmentWidth = 84, height = 22 })
    page.tabs:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, 0)
    page.title:SetPoint("RIGHT", page.tabs, "LEFT", -12, 0)

    -- Left: bosses, rares, dangerous trash and other loot.
    page.list = scrollArea(view, "list", page)
    page.list:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -52)
    local function openCreature(entry)
        local current = GuideUI.CurrentPage()
        if current and current.id then GuideUI.Navigate(creaturePage(current.id, entry.kind, entry.index)) end
    end
    page.headers = {}
    for index = 1, 4 do
        local header = UI.SectionHeader(page.list.child, "")
        page.headers[index] = header
    end
    page.bossRows = pool(function() return encounterRow(page.list.child, BOSS_ROW, openCreature) end)
    page.smallRows = pool(function() return encounterRow(page.list.child, SMALL_ROW, openCreature) end)
    page.listEmpty = wrapText(page.list.child, "label", "textFaint", 200)

    -- Right: the map, or a creature.
    page.right = UI.CreateFrame("Frame", page)
    page.map = DungeonMap.New(page.right, 400, {
        onPin = function(pin)
            local current = GuideUI.CurrentPage()
            if current and current.id then GuideUI.Navigate(creaturePage(current.id, "boss", pin.index)) end
        end,
        onPinEnter = pinTooltip,
        onFloor = function(floor)
            local current = GuideUI.CurrentPage()
            if current and current.id then state.floors[current.id] = floor end
            GuideUI.Refresh()
        end,
    })
    page.map:SetPoint("TOPLEFT", page.right, "TOPLEFT", 0, 0)
    page.foot = noWrap(UI.Text(page.right, "small", "textFaint"))
    page.footWish = icon(page.right, 13, "OVERLAY")
    setIcon(page.footWish, ICONS.wish, false)

    page.detail = scrollArea(view, "detail", page.right)
    page.detail:SetPoint("TOPLEFT", page.right, "TOPLEFT", 0, 0)
    local d = page.detail.child
    -- The encounter's header: the portrait and name on Blizzard's rock.
    page.hero = UI.CreateFrame("Frame", d)
    page.hero:SetPoint("TOPLEFT", d, "TOPLEFT", 0, 0)
    page.hero:SetHeight(HERO_HEIGHT)
    Theme.Panel(page.hero, "stone")
    page.portrait = UI.Portrait(page.hero, 80)
    pcall(page.portrait.EnableMouse, page.portrait, false)
    page.portrait:SetPoint("TOPLEFT", d, "TOPLEFT", 10, -9)
    page.name = noWrap(UI.Text(page.hero, "pageTitle", "goldBright"))
    page.name:SetPoint("TOPLEFT", page.portrait, "TOPRIGHT", 14, -12)
    page.name:SetPoint("RIGHT", d, "RIGHT", -10, 0)
    page.facts = noWrap(UI.Text(page.hero, "label", "textMuted"))
    page.facts:SetPoint("TOPLEFT", page.name, "BOTTOMLEFT", 0, -6)
    page.facts:SetPoint("RIGHT", d, "RIGHT", -10, 0)
    page.detailBadge = sourceBadge(page.hero)
    page.detailBadge:SetPoint("TOPLEFT", page.facts, "BOTTOMLEFT", 0, -6)
    page.keyHeader = UI.SectionHeader(d, "Key mechanics")
    page.moreHeader = UI.SectionHeader(d, "Other abilities")
    page.lootHeader = UI.SectionHeader(d, "Loot")
    page.abilityRows = pool(function() return abilityRow(d) end)
    page.cells = pool(function() return itemCell(d, CELL) end)
    page.abilityEmpty = wrapText(d, "label", "textFaint", 300)
    page.lootEmpty = wrapText(d, "label", "textFaint", 300)

    -- Full width: quests and runs.
    page.quests = scrollArea(view, "quests", page)
    page.quests:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -52)
    page.questRows = pool(function() return questRow(page.quests.child) end)
    page.questHeads = pool(function() return UI.SectionHeader(page.quests.child, "") end)
    page.questBox = UI.CreateFrame("Frame", page.quests.child)
    Theme.Panel(page.questBox, "inset")
    page.questBox.stripe = page.questBox:CreateTexture(nil, "BORDER")
    page.questBox.stripe:SetPoint("TOPLEFT", page.questBox, "TOPLEFT", 3, -3)
    page.questBox.stripe:SetPoint("BOTTOMLEFT", page.questBox, "BOTTOMLEFT", 3, 3)
    page.questBox.stripe:SetWidth(3)
    page.questSummary = wrapText(page.quests.child, "label", "text", 400)
    page.runs = scrollArea(view, "runs", page)
    page.runs:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -52)
    page.runRows = pool(function() return runRow(page.runs.child, nil) end)
    page.empty = wrapText(page, "label", "textFaint", 400)
    page.empty:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -58)
    view.dungeon = page
end

-- Two columns (the list left, the map or a creature right) when both fit;
-- below COMPACT_WIDTH the list sits over the map or creature instead.
local function layoutDungeonPage(view, width, height)
    local page = view.dungeon
    local body = height - 52
    local compact = width < COMPACT_WIDTH
    page.gwCompact = compact
    local rightX, rightY, rightWidth, rightHeight
    if compact then
        local listHeight = math.max(120, math.floor(body * 0.38))
        page.leftWidth = width
        page.list:SetViewSize(width, listHeight)
        rightX, rightY, rightWidth, rightHeight = 0, 52 + listHeight + 10, width, body - listHeight - 10
    else
        local left = math.max(200, math.min(280, math.floor(width * 0.3)))
        page.leftWidth = left
        page.list:SetViewSize(left, body)
        rightX, rightY, rightWidth, rightHeight = left + 16, 52, width - left - 16, body
    end
    page.right:ClearAllPoints()
    page.right:SetPoint("TOPLEFT", page, "TOPLEFT", rightX, -rightY)
    page.right:SetSize(rightWidth, rightHeight)
    -- The map as large as fits (its aspect kept), under it the floor bar
    -- and one line.
    local mapWidth = math.floor(math.min(rightWidth - 2, (rightHeight - 2 - 26 - 24) * DungeonMap.ASPECT))
    page.map:SetMapWidth(mapWidth)
    page.foot:ClearAllPoints()
    page.foot:SetPoint("TOPLEFT", page.map, "BOTTOMLEFT", 0, -32)
    page.foot:SetWidth(rightWidth)
    page.detail:SetViewSize(rightWidth, rightHeight)
    page.quests:SetViewSize(width, body)
    page.runs:SetViewSize(width, body)
    page.empty:SetWidth(math.min(400, width))
    page.rightWidth, page.rightHeight = rightWidth, rightHeight
    local listWidth = page.list:ContentWidth()
    for _, row in ipairs(page.bossRows.items) do row:SetWidth(listWidth) end
    for _, row in ipairs(page.smallRows.items) do row:SetWidth(listWidth) end
    for _, header in ipairs(page.headers) do header:SetWidth(listWidth) end
    page.listEmpty:SetWidth(listWidth)
end

-- The left list: section headers and rows, top to bottom.
local function refreshList(page, instanceId, dungeon, current, states)
    local width = page.list:ContentWidth()
    local y, headerIndex, bossCount, smallCount = 0, 0, 0, 0
    local function header(title)
        headerIndex = headerIndex + 1
        local h = page.headers[headerIndex]
        h:SetTitle(title)
        h:SetWidth(width)
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", page.list.child, "TOPLEFT", 0, -y)
        h:Show()
        y = y + 24
    end
    local function place(row, height, entry)
        row:SetWidth(width)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", page.list.child, "TOPLEFT", 0, -y)
        row:Fill(entry)
        y = y + height + 1
    end
    local selectedKind = current.level == "creature" and current.kind or nil
    if #dungeon.bosses > 0 then
        header("Bosses (" .. #dungeon.bosses .. ")")
        for index, boss in ipairs(dungeon.bosses) do
            bossCount = bossCount + 1
            local level = Guide.CreatureLevel(boss)
            local parts = {}
            if level then table.insert(parts, "Level " .. level) end
            local observed = states[boss]
            if observed then table.insert(parts, STATE_TEXT[observed]) end
            local selected = selectedKind == "boss" and current.index == index
            local displayId = Guide.DisplayId(instanceId, boss)
            place(page.bossRows:Get(bossCount), BOSS_ROW, { creature = boss, kind = "boss", index = index, displayId = displayId,
                state = (selected and "selected") or observed or (displayId and "available" or "unknown"),
                mechanics = Guide.TopMechanics(boss, nil, MECHANIC_ICONS), wanted = wantedIn(Guide.SourceLoot(instanceId, boss)),
                selected = selected, sub = table.concat(parts, SEP) })
        end
        y = y + 8
    end
    local function small(list, kind, title, iconFile)
        if #list == 0 then return end
        header(title)
        for index, creature in ipairs(list) do
            smallCount = smallCount + 1
            local right = {}
            if creature.n and creature.n > 1 then table.insert(right, TIMES .. creature.n) end
            for _, ability in ipairs(Guide.Abilities(creature)) do
                if ability.label == "KICK" then
                    table.insert(right, Theme.Colorize("KICK", "info"))
                    break
                end
            end
            if #right == 0 then table.insert(right, Guide.CreatureLevel(creature) or "") end
            local selected = selectedKind == kind and current.index == index
            local displayId = Guide.DisplayId(instanceId, creature)
            place(page.smallRows:Get(smallCount), SMALL_ROW, { creature = creature, kind = kind, index = index, displayId = displayId,
                icon = iconFile, state = selected and "selected" or (displayId and "available" or "unknown"), selected = selected,
                wanted = wantedIn(Guide.SourceLoot(instanceId, creature)), sub = table.concat(right, " ") })
        end
        y = y + 8
    end
    small(dungeon.rares, "rare", "Rares", ICONS.rare)
    small(dungeon.trash, "trash", "Dangerous trash", ICONS.trash)
    local other = Guide.OtherLoot(instanceId)
    if #other > 0 then
        header("Other dungeon loot")
        smallCount = smallCount + 1
        local selected = selectedKind == "other"
        place(page.smallRows:Get(smallCount), SMALL_ROW, { creature = { name = "Other dungeon loot" }, kind = "other", index = 1,
            icon = ICONS.other, state = selected and "selected" or "unknown", selected = selected, wanted = wantedIn(other),
            sub = #other .. (#other == 1 and " item" or " items") })
    end
    for index = headerIndex + 1, #page.headers do page.headers[index]:Hide() end
    page.bossRows:Trim(bossCount)
    page.smallRows:Trim(smallCount)
    UI.SetText(page.listEmpty, (bossCount + smallCount) == 0 and "No bosses or creatures in the atlas for this dungeon." or "")
    page.listEmpty:ClearAllPoints()
    page.listEmpty:SetPoint("TOPLEFT", page.list.child, "TOPLEFT", 0, 0)
    UI.SetShown(page.listEmpty, (bossCount + smallCount) == 0)
    page.list:SetContentHeight(y)
end

local function refreshMap(page, instanceId, dungeon, states)
    local floor = state.floors[instanceId] or 1
    local result = page.map:ShowDungeon(instanceId, floor, nil, states)
    if result == "deferred" then GuideUI.pending = true end
    local pins = Guide.Pins(instanceId)
    local floors = Guide.Floors(instanceId)
    local parts = {}
    local wanted = Guide.WantedCount(instanceId)
    if wanted > 0 then table.insert(parts, "     " .. Theme.Colorize(wanted .. (wanted == 1 and " wishlist item drops here" or " wishlist items drop here"), "alertWishlist")) end
    if #floors > 0 and #dungeon.bosses > 0 then
        table.insert(parts, #pins < #dungeon.bosses and (#pins .. " of " .. #dungeon.bosses .. " bosses placed from Blizzard's dungeon journal")
            or "Boss positions from Blizzard's dungeon journal")
    end
    UI.SetText(page.foot, table.concat(parts, SEP))
    page.footWish:ClearAllPoints()
    page.footWish:SetPoint("LEFT", page.foot, "LEFT", 0, 0)
    UI.SetShown(page.footWish, wanted > 0)
end

-- A creature's page: portrait and facts, key mechanics, the other
-- abilities, and its loot as a grid. Also the "Other dungeon loot" page.
local function refreshCreature(page, instanceId, dungeon, current, states)
    local d = page.detail.child
    local width = page.detail:ContentWidth()
    local creature = pageCreature(dungeon, current)
    local kind = current.kind
    local loot, abilities, observed
    if kind == "other" then
        page.portrait:SetCreature(nil, ICONS.other)
        page.portrait:SetState("unknown")
        UI.SetText(page.name, "Other dungeon loot")
        UI.SetText(page.facts, "Drops the atlas names no boss or creature in this dungeon for")
        loot, abilities = Guide.OtherLoot(instanceId), {}
    elseif creature then
        local displayId = Guide.DisplayId(instanceId, creature)
        observed = kind == "boss" and states[creature] or nil
        page.portrait:SetCreature(displayId, kind == "rare" and ICONS.rare or (kind == "trash" and ICONS.trash or nil))
        page.portrait:SetState(observed or (displayId and "available" or "unknown"))
        UI.SetText(page.name, creature.name)
        local facts = {}
        local level = Guide.CreatureLevel(creature)
        if level then table.insert(facts, "Level " .. level) end
        local class = Guide.CreatureClass(creature)
        if kind == "rare" then table.insert(facts, creature.elite and "Rare elite" or "Rare")
        elseif kind == "trash" then table.insert(facts, "Dangerous trash" .. (creature.n and creature.n > 1 and ("  " .. TIMES .. creature.n) or ""))
        elseif class then table.insert(facts, class) end
        -- Its loot is a chest the encounter leaves (Majordomo's Cache of the Firelord).
        if creature.chest then table.insert(facts, "Loot: " .. creature.chest) end
        if observed then table.insert(facts, STATE_TEXT[observed] .. (observed == "defeated" and Theme.Colorize(" this run", "textMuted") or "")) end
        UI.SetText(page.facts, table.concat(facts, SEP))
        loot, abilities = Guide.SourceLoot(instanceId, creature), Guide.OrderedAbilities(creature)
    else
        loot, abilities = {}, {}
        UI.SetText(page.name, "")
        UI.SetText(page.facts, "")
    end
    local verified = false
    for _, row in ipairs(abilities) do if Guide.IsVerified(row.spell) then verified = true end end
    if Guide.IsForever(instanceId) then
        page.detailBadge:Set("WoW Forever", { "Name from the WoW Forever client.", "Abilities and item details are not known yet." })
    else
        page.detailBadge:Set("Classic reference", { verified and "Some entries are verified on Forever." or (Guide.REFERENCE_NOTE .. "."),
            "Mechanics, levels and loot come from Classic reference data and may differ on WoW Forever.", "Drop chances are not shown." })
    end

    -- Fill: key mechanics first, then the rest, then the loot.
    local count, topCount = 0, 0
    if kind ~= "other" then
        local shown = {}
        for _, ability in ipairs(Guide.TopMechanics(creature, nil, 4)) do
            shown[ability] = true
            count = count + 1
            page.abilityRows:Get(count):Fill(ability, true)
        end
        topCount = count
        for _, ability in ipairs(abilities) do
            if not shown[ability] then
                count = count + 1
                page.abilityRows:Get(count):Fill(ability)
            end
        end
    end
    page.abilityRows:Trim(count)
    page.keyHeader:SetTitle("Key mechanics")
    page.moreHeader:SetTitle("Other abilities")
    page.lootHeader:SetTitle("Loot" .. (#loot > 0 and (" (" .. #loot .. ")") or ""))
    UI.SetText(page.abilityEmpty, #abilities == 0 and "No abilities in the atlas for this creature. That does not mean it has none." or "")
    -- An empty list only says no reference source links an item to it.
    -- Drops listed by item ID without item facts (WoW Forever's own items).
    local unresolved = Guide.UnresolvedLoot(kind == "other" and dungeon or creature)
    local lootEmpty = ""
    if #unresolved > 0 then
        lootEmpty = string.format("%d drop%s listed without item details yet (item %s).", #unresolved, #unresolved == 1 and " is" or "s are",
            table.concat(unresolved, ", "))
    elseif #loot == 0 then
        lootEmpty = "No loot data for " .. tostring(creature and creature.name or "this") .. " yet. That does not mean it drops nothing."
    end
    UI.SetText(page.lootEmpty, lootEmpty)
    layoutGrid(page.cells, loot, d, 0, 0, width, CELL, CELL_GAP)
    page.gwCreature = { kind = kind, top = topCount, count = count, loot = loot, noAbilities = #abilities == 0 }
    page.gwUnresolved = #unresolved > 0 or nil
    page.gwLootCount, page.gwAbilityCount = #loot, count
    GuideUI.LayoutCreature(page)
end

-- Places a creature page's parts for the panel's width: headers, ability
-- rows, the loot grid (as many columns as fit) and the empty notes. Reads
-- no data; a resize repeats it.
function GuideUI.LayoutCreature(page)
    local shown = rawget(page, "gwCreature")
    if not shown then return end
    local d = page.detail.child
    local width = page.detail:ContentWidth()
    page.hero:SetWidth(width)
    local y = HERO_HEIGHT + 12
    local function place(widget, height)
        widget:SetWidth(width)
        widget:ClearAllPoints()
        widget:SetPoint("TOPLEFT", d, "TOPLEFT", 0, -y)
        widget:Show()
        y = y + height
    end
    if shown.kind ~= "other" then
        place(page.keyHeader, 26)
        for index = 1, shown.top do place(page.abilityRows:Get(index), ABILITY_ROW + 2) end
        if shown.noAbilities then
            place(page.abilityEmpty, 22)
        else
            page.abilityEmpty:Hide()
        end
        y = y + 8
        if shown.count > shown.top then
            place(page.moreHeader, 26)
            for index = shown.top + 1, shown.count do place(page.abilityRows:Get(index), ABILITY_ROW + 2) end
            y = y + 8
        else
            page.moreHeader:Hide()
        end
    else
        page.keyHeader:Hide()
        page.moreHeader:Hide()
        page.abilityEmpty:Hide()
    end
    place(page.lootHeader, 26)
    local gridHeight, columns = layoutGrid(page.cells, shown.loot, d, 0, -y, width, CELL, CELL_GAP, true)
    page.gwGridColumns, page.gwGridWidth = columns, columns * (CELL + CELL_GAP) - CELL_GAP
    y = y + gridHeight
    if #shown.loot == 0 or rawget(page, "gwUnresolved") then
        place(page.lootEmpty, 22)
    else
        page.lootEmpty:Hide()
    end
    page.detail:SetContentHeight(y + 8)
end

-- Stacks the quest tab for the area's width: the readiness summary, then
-- headers and quest rows in order (or, without readiness, the rows alone).
local function layoutQuests(page)
    local width = page.quests:ContentWidth()
    local child = page.quests.child
    local y = 0
    local summary = page.questSummary
    local box = page.questBox
    if rawget(page, "gwQuestSummary") then
        summary:ClearAllPoints()
        summary:SetPoint("TOPLEFT", child, "TOPLEFT", 16, -10)
        summary:SetWidth(math.max(60, width - 28))
        summary:Show()
        local ok, measured = pcall(summary.GetStringHeight, summary)
        local height = math.max(14, ok and tonumber(measured) or 28) + 20
        box:ClearAllPoints()
        box:SetPoint("TOPLEFT", child, "TOPLEFT", 0, 0)
        box:SetSize(width, height)
        box:Show()
        y = y + height + 14
    else
        summary:Hide()
        box:Hide()
    end
    local layout = rawget(page, "gwQuestLayout")
    if not layout then
        layout = {}
        for index = 1, rawget(page, "gwQuestCount") or 0 do layout[index] = { row = index } end
    end
    for _, item in ipairs(layout) do
        if item.head then
            local header = page.questHeads:Get(item.head)
            header:ClearAllPoints()
            header:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
            header:SetWidth(width)
            y = y + 30
        else
            local row = page.questRows:Get(item.row)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
            y = y + row:Layout(width) + 10
        end
    end
    page.quests:SetContentHeight(y)
end

-- The current character's readiness for a guide page, or nil when there is
-- no quest catalog for it (the atlas list is shown as before).
local function questReadiness(instanceId)
    if not Readiness or type(Readiness.ForGuide) ~= "function" then return nil end
    -- The quest tables are built out of combat only (about 470 KB, once).
    if inCombat() and type(Readiness.IsBuilt) == "function" and not Readiness.IsBuilt() then return nil end
    local ok, result = pcall(Readiness.ForGuide, instanceId)
    return ok and result or nil
end
GuideUI.QuestReadiness = questReadiness

-- One quest row's data: the catalog's quest with the atlas's objective,
-- rewards and giver when the atlas lists it, and the character's state.
local function questView(entry, atlasById, characterState)
    local quest = entry.quest
    local atlas = atlasById[quest.questId]
    local chain = {}
    for _, prerequisite in ipairs(quest.prerequisites or {}) do
        local known = Readiness.Quest(prerequisite.questId)
        table.insert(chain, { name = known and known.name or ("Quest " .. prerequisite.questId),
            status = Readiness.PrerequisiteStatus(prerequisite, characterState or Readiness.EmptyState()) })
    end
    return {
        id = quest.questId, name = quest.name, lvl = quest.level, min = quest.minLevel,
        fac = quest.faction == "alliance" and "A" or (quest.faction == "horde" and "H" or nil),
        giver = atlas and atlas.giver or quest.giver, where = atlas and atlas.where or quest.zone,
        x = atlas and atlas.where and atlas.x or quest.x, y = atlas and atlas.where and atlas.y or quest.y,
        obj = atlas and atlas.obj, rew = atlas and atlas.rew, choice = atlas and atlas.choice,
        prek = quest.prerequisitesKnown == false and false or nil,
        state = entry.state, chain = #chain > 0 and chain or nil,
        why = entry.state == "unknown" and Readiness.UnknownReason(entry.reasons) or nil,
        turnIn = entry.turnIn,
    }
end

-- The quest groups, most urgent first; quiet ones (chains, optional,
-- completed) last. Ineligible quests are only counted.
local function questGroups(result)
    local function pick(list, wanted, skip)
        local out = {}
        for _, entry in ipairs(list) do
            if (not wanted or wanted[entry.state]) and not (skip and skip[entry.state]) then table.insert(out, entry) end
        end
        return out
    end
    local others = {}
    for _, entry in ipairs(result.optional) do table.insert(others, entry) end
    for _, entry in ipairs(result.repeatable) do table.insert(others, entry) end
    local completed = pick(result.quests, { completed = true })
    for _, entry in ipairs(pick(others, { completed = true })) do table.insert(completed, entry) end
    local settled = { completed = true, ineligible = true }
    return {
        { "Pick up before you go", pick(result.quests, { available = true }) },
        { "Needs an earlier quest first", pick(result.quests, { prerequisites = true }) },
        { "Not known yet", pick(result.quests, { unknown = true }) },
        { "In your quest log", pick(result.quests, { accepted = true }) },
        { "Prerequisite chains", pick(result.prerequisites, nil, settled) },
        { "Optional quests", pick(others, nil, settled) },
        { "Completed", completed },
    }
end

local function refreshQuests(page, instanceId)
    local width = page.quests:ContentWidth()
    local result = questReadiness(instanceId)
    if not result then
        local quests = Guide.Quests(instanceId)
        for index, quest in ipairs(quests) do
            local row = page.questRows:Get(index)
            row.gwWidth = width
            row:Fill(quest)
        end
        page.questRows:Trim(#quests)
        page.questHeads:Trim(0)
        page.gwQuestCount = #quests
        page.gwQuestLayout = nil
        page.gwQuestSummary = nil
        layoutQuests(page)
        return #quests
    end
    local dungeon = Guide.Dungeon(instanceId)
    local atlasById = {}
    for _, quest in ipairs(dungeon and dungeon.quests or {}) do atlasById[quest.id] = quest end
    -- Accepted quests whose objectives the log says are done.
    local log = GW.CharacterQuests and GW.CharacterQuests.Debug and GW.CharacterQuests.Debug().log
    local turnIn = {}
    for _, entry in ipairs(log and log.entries or {}) do if entry.isComplete then turnIn[entry.questId] = true end end
    local layout, rowCount, headCount, shown = {}, 0, 0, 0
    for _, group in ipairs(questGroups(result)) do
        local title, entries = group[1], group[2]
        if #entries > 0 then
            headCount = headCount + 1
            page.questHeads:Get(headCount):SetTitle(title .. " (" .. #entries .. ")")
            page.questHeads:Get(headCount):Show()
            table.insert(layout, { head = headCount })
            for _, entry in ipairs(entries) do
                rowCount = rowCount + 1
                local row = page.questRows:Get(rowCount)
                row.gwWidth = width
                entry.turnIn = turnIn[entry.quest.questId]
                row:Fill(questView(entry, atlasById, result.state))
                table.insert(layout, { row = rowCount })
                shown = shown + 1
            end
        end
    end
    page.questRows:Trim(rowCount)
    page.questHeads:Trim(headCount)
    page.gwQuestCount = rowCount
    page.gwQuestLayout = layout
    local characterState = result.state
    local lines = { Theme.Colorize(Readiness.READINESS_LABELS[result.readiness], READINESS_COLOR[result.readiness]) .. SEP .. Readiness.Summary(result) }
    if not characterState then
        table.insert(lines, Theme.Colorize("Your quests have not been read yet (they are, out of combat).", "textFaint"))
    elseif characterState.completed.coverage ~= "full" or characterState.questLog.coverage ~= "full" then
        local missing = {}
        if characterState.completed.coverage == "none" then table.insert(missing, "which quests you completed") end
        if characterState.questLog.coverage == "none" then table.insert(missing, "your quest log (expand every header)") end
        if #missing > 0 then table.insert(lines, Theme.Colorize("The game did not give " .. table.concat(missing, " or ") .. ".", "textFaint")) end
    end
    if result.counts.ineligible > 0 then
        table.insert(lines, Theme.Colorize(result.counts.ineligible .. " dungeon quest" .. (result.counts.ineligible == 1 and " is" or "s are")
            .. " not for you (faction, race, class or level).", "textFaint"))
    end
    table.insert(lines, Theme.Colorize("Quest facts are Classic reference data, not confirmed on Forever.", "textFaint"))
    UI.SetText(page.questSummary, table.concat(lines, "\n"))
    Theme.Fill(page.questBox.stripe, READINESS_COLOR[result.readiness], 0.9)
    page.gwQuestSummary = true
    layoutQuests(page)
    return shown, result
end

local function refreshRuns(page, instanceId)
    local runs = Guide.Runs(instanceId)
    for index, entry in ipairs(runs) do page.runRows:Get(index):Fill(entry, false) end
    page.runRows:Trim(#runs)
    page.gwRunCount = #runs
    placeRunRows(page.runs, page.runRows, #runs)
    return #runs
end

local function refreshDungeonPage(view, current)
    local page = view.dungeon
    local instanceId = current.id
    local dungeon = Guide.Dungeon(instanceId)
    if state.shownId ~= instanceId then
        state.shownId = instanceId
        if dungeon and not inCombat() and Portraits then
            local ids = {}
            for _, boss in ipairs(dungeon.bosses) do table.insert(ids, Guide.DisplayId(instanceId, boss)) end
            Portraits.Prefetch(ids)
        end
    end
    page.tabs:Refresh()
    if not dungeon then
        UI.SetText(page.title, "Dungeons")
        UI.SetText(page.sub, "")
        for _, widget in ipairs({ page.list, page.right, page.quests, page.runs, page.badge }) do widget:Hide() end
        UI.SetText(page.empty, "This dungeon is not in the packaged atlas.")
        page.empty:Show()
        return
    end
    UI.SetText(page.title, dungeon.name)
    local parts = { dungeon.kind == "raid" and "Raid" or "Dungeon" }
    local levels = Guide.LevelText(dungeon.lmin, dungeon.lmax)
    if levels then table.insert(parts, "Levels " .. levels) end
    if dungeon.zone then table.insert(parts, dungeon.zone) end
    -- Here: this page, or (inside a dungeon whose wing is not known yet) the
    -- dungeon of this wing.
    local currentGuide, currentInstance = Guide.CurrentGuideId(), Guide.CurrentInstanceId()
    if instanceId == currentGuide or (currentGuide == currentInstance and currentInstance ~= nil and Guide.InstanceIdOf(instanceId) == currentInstance) then
        table.insert(parts, Theme.Colorize("You are here", "good"))
    end
    local readiness = questReadiness(instanceId)
    if readiness and (readiness.required > 0 or readiness.questList == "unknown") then
        table.insert(parts, Theme.Colorize(Readiness.OVERVIEW_LABELS[readiness.required > 0 and readiness.readiness or "none"], READINESS_COLOR[readiness.readiness]))
    end
    UI.SetText(page.sub, table.concat(parts, SEP))
    local entry = Guide.Entry(instanceId) or {}
    local where = dungeon.entrance and ("Entrance: " .. tostring(entry.zone or dungeon.zone or "?") .. " " .. Guide.Coordinates(dungeon.entrance.x, dungeon.entrance.y))
        or ("Entrance not known" .. (dungeon.zone and (" (" .. dungeon.zone .. ")") or ""))
    local forever = Guide.IsForever(instanceId)
    local lines = { where }
    if forever then
        table.insert(lines, "A WoW Forever dungeon: its bosses, level band and entrance come from the game client.")
        table.insert(lines, "Abilities, maps and most item details are not known yet. Nothing stands in for them.")
        if dungeon.floors and #dungeon.floors > 0 then table.insert(lines, "Floors: " .. table.concat(dungeon.floors, ", ") .. ".") end
        if dungeon.qlist == false then table.insert(lines, "No quest list is known for this dungeon yet.") end
        local unresolved = #Guide.UnresolvedLoot(dungeon)
        for _, boss in ipairs(dungeon.bosses or {}) do unresolved = unresolved + #Guide.UnresolvedLoot(boss) end
        if unresolved > 0 then table.insert(lines, unresolved .. " listed drops have no item details yet; they show by item ID.") end
    else
        table.insert(lines, Guide.REFERENCE_NOTE .. ": bosses, mechanics, loot and quests come from Classic reference data.")
        table.insert(lines, "Maps, boss positions and faces are the client's own.")
    end
    if dungeon.wingKey then
        -- What the wing owns, and what it only shares with its dungeon.
        table.insert(lines, "Wing bosses: Classic reference (DungeonPlanner, InstanceJournal), not confirmed on Forever.")
        table.insert(lines, "Quests, trash and other loot are the whole of " .. tostring(dungeon.parentName) .. "'s: no source ties them to one wing.")
        if dungeon.unassigned and #dungeon.unassigned > 0 then table.insert(lines, "Not placed in a wing: " .. table.concat(dungeon.unassigned, ", ") .. ".") end
        if dungeon.levelSource == "parent" then table.insert(lines, "Level band: the whole dungeon's.") end
        if #Guide.Floors(instanceId) == 0 then table.insert(lines, "No map floor is known for this wing.") end
    elseif Guide.WingsOf(instanceId) then
        local names = {}
        for _, key in ipairs(Guide.WingsOf(instanceId)) do table.insert(names, Guide.Entry(key).name) end
        table.insert(lines, "Played as wings: " .. table.concat(names, ", ") .. ". This page covers the whole dungeon.")
    end
    page.badge:Set(forever and "WoW Forever" or "Classic reference", lines)
    page.badge:Show()
    page.empty:Hide()

    local tab = current.level == "creature" and "overview" or (current.tab or "overview")
    local states = encounterStates(instanceId, dungeon)
    local overview = tab == "overview"
    UI.SetShown(page.list, overview)
    UI.SetShown(page.right, overview)
    UI.SetShown(page.quests, tab == "quests")
    UI.SetShown(page.runs, tab == "runs")
    if overview then
        refreshList(page, instanceId, dungeon, current, states)
        local creature = current.level == "creature"
        UI.SetShown(page.map, not creature)
        UI.SetShown(page.map.bar, not creature)
        UI.SetShown(page.foot, not creature)
        UI.SetShown(page.footWish, not creature)
        UI.SetShown(page.detail, creature)
        if creature then
            refreshCreature(page, instanceId, dungeon, current, states)
        else
            page.gwCreature = nil
            refreshMap(page, instanceId, dungeon, states)
        end
    elseif tab == "quests" then
        local count, result = refreshQuests(page, instanceId)
        local noList = count == 0 and ((dungeon and dungeon.qlist == false) or (result and result.questList == "unknown"))
        UI.SetText(page.empty, noList and "No quest list is known for this dungeon yet. That does not mean it has none."
            or (count == 0 and "No quests for this dungeon in the atlas for your faction." or ""))
        UI.SetShown(page.empty, count == 0)
    else
        local count = refreshRuns(page, instanceId)
        UI.SetText(page.empty, count == 0 and ("No finished runs of " .. dungeon.name .. " yet. Runs are recorded on their own when you enter.") or "")
        UI.SetShown(page.empty, count == 0)
    end
end

-- Top bar and breadcrumb ----------------------------------------------------------------------

local function crumbName(page)
    if page.level == "browser" then return page.mode == "runs" and "My Runs" or nil end
    local dungeon = Guide.Dungeon(page.id)
    if page.level == "dungeon" then
        if page.tab == "quests" then return "Quests" end
        if page.tab == "runs" then return "My Runs" end
        return nil
    end
    if page.kind == "other" then return "Other dungeon loot" end
    local creature = pageCreature(dungeon, page)
    return creature and creature.name or nil
end

local function refreshTopBar(view, current)
    local bar = view.topBar
    bar.back:SetActive(nav.index > 1)
    bar.forward:SetActive(nav.index < #nav.history)
    local crumbs = { { "Dungeons", current.level ~= "browser" and browserPage() or nil } }
    if current.level ~= "browser" then
        local entry = Guide.Entry(current.id)
        local deeper = crumbName(current)
        table.insert(crumbs, { entry and entry.name or "Dungeon", deeper and dungeonPage(current.id) or nil })
        if deeper then table.insert(crumbs, { deeper, nil }) end
    else
        local deeper = crumbName(current)
        if deeper then
            crumbs[1][2] = browserPage()
            table.insert(crumbs, { deeper, nil })
        end
    end
    for index, crumb in ipairs(bar.crumbs) do
        local data = crumbs[index]
        if data then
            UI.SetText(crumb.label, data[1])
            crumb.gwPage = data[2]
            Theme.Tint(crumb.label, data[2] and "gold" or "goldBright")
            local width = tonumber(select(2, pcall(crumb.label.GetStringWidth, crumb.label))) or (#data[1] * 7)
            crumb.gwNatural = math.max(20, width + 2)
            crumb:Show()
        else
            crumb.gwPage, crumb.gwNatural = nil, nil
            crumb:Hide()
        end
    end
    local here = Guide.CurrentGuideId()
    bar.gwHere = here ~= nil and current.id ~= here
    UI.SetShown(bar.here, bar.gwHere)
    GuideUI.FitCrumbs(view)
end

-- The breadcrumb in the room the top bar leaves (after the arrows, before
-- "Current dungeon"): the deepest crumbs give way first, down to 40 px, and
-- truncate their names.
local ARROWS_WIDTH, CRUMB_GAP, HERE_WIDTH = 50, 22, 130
function GuideUI.FitCrumbs(view)
    local bar = view.topBar
    local room = (view.gwWidth or 532) - ARROWS_WIDTH - (bar.gwHere and HERE_WIDTH or 0)
    local widths, total = {}, 0
    for index, crumb in ipairs(bar.crumbs) do
        local natural = rawget(crumb, "gwNatural")
        if natural then
            widths[index] = natural
            total = total + natural + (index > 1 and CRUMB_GAP or 0)
        end
    end
    for index = #widths, 1, -1 do
        if total <= room then break end
        local cut = math.min(total - room, widths[index] - 40)
        if cut > 0 then
            widths[index] = widths[index] - cut
            total = total - cut
        end
    end
    for index, width in ipairs(widths) do bar.crumbs[index]:SetWidth(width) end
    bar.gwCrumbsWidth, bar.gwCrumbRoom = total, room
end

-- Build, layout, refresh ------------------------------------------------------------------------

local function buildView(view)
    GuideUI.view = view
    view.scrollAreas = {}
    buildTopBar(view)
    buildStrip(view)
    buildBrowser(view)
    buildDungeonPage(view)
    if nav.index == 0 then
        table.insert(nav.history, browserPage())
        nav.index = 1
    end
end
GuideUI.ResetHistory = function()
    nav.history, nav.index = { browserPage() }, 1
end

-- Lays the view out for the content area. The pages start under the top
-- bar, and under the run strip while a run is open.
local function layoutView(view, width, height)
    view.gwWidth, view.gwHeight = width, height
    local top = TOP_BAR + (view.gwStrip and STRIP or 0)
    view.gwTop = top
    for _, page in ipairs({ view.browser, view.dungeon }) do
        page:ClearAllPoints()
        page:SetPoint("TOPLEFT", view, "TOPLEFT", 0, -top)
        page:SetSize(width, height - top)
    end
    -- The strip's run name gives way to its buttons.
    view.strip.name:SetWidth(math.max(60, math.min(160, width - 430)))
    layoutBrowser(view, width, height - top)
    layoutDungeonPage(view, width, height - top)
end
GuideUI.Layout = layoutView

-- After a layout, puts what the page already shows in its new places:
-- cards, rows, the loot grid, quests, the breadcrumb. No data is read, no
-- frame is filled again; the drag of the grip runs this.
local function reflowView(view)
    GuideUI.FitCrumbs(view)
    local browser, page = view.browser, view.dungeon
    placeCards(browser, rawget(view, "gwShownCards") or 0)
    placeRunRows(browser.runs, browser.runRows, rawget(browser, "gwRunCount") or 0)
    if rawget(page, "gwCreature") then GuideUI.LayoutCreature(page) end
    layoutQuests(page)
    placeRunRows(page.runs, page.runRows, rawget(page, "gwRunCount") or 0)
end
GuideUI.Reflow = reflowView

local function refreshView(view)
    local started = GW.Perf and GW.Perf.Begin and GW.Perf.Begin()
    local strip = refreshStrip(view)
    if strip ~= (view.gwStrip == true) and not inCombat() then
        view.gwStrip = strip
        layoutView(view, view.gwWidth or 532, view.gwHeight or 418)
    end
    local current = GuideUI.CurrentPage() or browserPage()
    refreshTopBar(view, current)
    local browsing = current.level == "browser"
    UI.SetShown(view.browser, browsing)
    UI.SetShown(view.dungeon, not browsing)
    if browsing then refreshBrowser(view, current) else refreshDungeonPage(view, current) end
    -- Another page: its scroll offsets as it left them (a repaint of the
    -- same page keeps where the player scrolled).
    if view.gwShownPage ~= current then
        view.gwShownPage = current
        for key, area in pairs(view.scrollAreas) do
            if area:IsShown() then area:ScrollTo(current.scroll and current.scroll[key] or 0) end
        end
    end
    if started then GW.Perf.End("guide:refresh", started) end
end

-- The sidebar's Dungeons: the dungeon cards (the dashboard repaints).
local function onNav()
    local current = GuideUI.CurrentPage()
    if not (current and current.level == "browser" and (current.mode or "dungeons") == "dungeons") then
        GuideUI.Navigate(browserPage(), true)
    end
end

local function tick(view)
    local strip = view.strip
    if not strip:IsShown() then return end
    local run = GW.DungeonSessions and GW.DungeonSessions.Current() or nil
    if run then UI.SetText(strip.clock, GW.DungeonHud.ClockText(run)) end
end

-- Registers the journal as the dashboard's Dungeons view.
if main and main.Views then
    main.Views.dungeon = { build = buildView, refresh = refreshView, layout = layoutView, reflow = reflowView, onNav = onNav, tick = tick }
end

-- Public -----------------------------------------------------------------------------------

function GuideUI.Refresh()
    if main and main.current == "dungeon" and main.RefreshView then main:RefreshView() end
end

-- Opens the journal: on a boss (index in the atlas) of a dungeon, on a
-- dungeon, or (no dungeon) on the dungeon the player is in, else where it
-- was (the dungeon cards at first). In combat the dashboard is only shown
-- when it was already built: nothing large is created mid-fight.
function GuideUI.Show(instanceId, bossIndex)
    if not main or not main.Open then return false end
    if inCombat() and not (main.views and main.views.dungeon) then
        GW.Print("The dungeon journal opens out of combat.")
        return false
    end
    -- A dungeon's instance ID or a wing's key; else where the player is
    -- (the wing their run resolved, or the dungeon).
    instanceId = Guide.NormalizeId(instanceId) or Guide.CurrentGuideId()
    if instanceId then
        if instanceId == Guide.CurrentGuideId() then Guide.FollowCurrent() end
        local dungeon = Guide.Dungeon(instanceId)
        local boss = bossIndex and dungeon and dungeon.bosses[bossIndex]
        if boss then
            local pin = Guide.PinFor(instanceId, boss)
            if pin then state.floors[instanceId] = pin.floor end
            GuideUI.Navigate(creaturePage(instanceId, "boss", bossIndex), true)
        else
            GuideUI.Navigate(dungeonPage(instanceId), true)
        end
    end
    -- Open repaints (and builds the view the first time).
    if main.current == "dungeon" and main:IsOpen() then
        GuideUI.Refresh()
    else
        main:Open("dungeon")
    end
    return true
end

-- Entering a known dungeon out of combat builds it and starts loading its
-- bosses' faces, so the HUD's tooltips and faces are ready in the fight.
function GuideUI.OnInstanceChanged()
    local current = Guide.CurrentInstanceId()
    if current and not inCombat() then
        local dungeon = Guide.Dungeon(current)
        if dungeon and Portraits then
            local ids = {}
            for _, boss in ipairs(dungeon.bosses) do table.insert(ids, Guide.DisplayId(current, boss)) end
            Portraits.Prefetch(ids)
        end
    end
    GuideUI.Refresh()
end

function GuideUI.OnCombatEnded()
    if Portraits then Portraits.OnCombatEnded() end
    if GuideUI.pending then
        GuideUI.pending = nil
        GuideUI.Refresh()
    end
end

-- HUD -------------------------------------------------------------------------------------

-- The atlas boss behind a HUD face: by encounter ID, then name.
function GuideUI.BossForEntry(instanceId, entry)
    if not entry or not instanceId then return nil end
    -- In combat only an already built dungeon is read.
    if inCombat() and not Guide.IsBuilt(instanceId) then return nil end
    local encounterId = entry.encounterId or (entry.id and tonumber(tostring(entry.id):match("^boss:(%d+)$")))
    return Guide.FindBoss(instanceId, encounterId, entry.name)
end

-- The display ID for a HUD face the client gave no art for.
function GuideUI.DisplayIdForEntry(instanceId, entry)
    local boss = GuideUI.BossForEntry(instanceId, entry)
    return boss and Guide.DisplayId(instanceId, boss) or nil
end

-- Lines for a HUD face's tooltip: the boss's top mechanics and wanted loot.
function GuideUI.TooltipLines(instanceId, entry)
    local boss = GuideUI.BossForEntry(instanceId, entry)
    if not boss then return nil end
    local lines = {}
    for _, row in ipairs(Guide.TopMechanics(boss, nil, 3)) do table.insert(lines, GuideUI.AbilityText(row)) end
    for _, row in ipairs(Guide.CreatureLoot(boss)) do
        if row.wanted and not row.acquired then
            table.insert(lines, Theme.Colorize("Wishlist: " .. ((row.item and row.item.n) or ("Item " .. row.itemId)), "alertWishlist"))
        end
    end
    if #lines == 0 then return nil end
    table.insert(lines, Theme.Colorize(Guide.SourceNote(instanceId) .. ". Click for the journal.", "textFaint"))
    return lines
end

-- A boss that belongs to one wing opens on that wing's page, where it is;
-- any other on its dungeon's.
function GuideUI.OpenForEntry(instanceId, entry)
    local boss, index = GuideUI.BossForEntry(instanceId, entry)
    local key = boss and Guide.WingForBoss(instanceId, boss.e, boss.npc)
    local wing = key and Guide.Dungeon(key)
    if wing then
        for position, candidate in ipairs(wing.bosses) do
            if candidate == boss then return GuideUI.Show(key, position) end
        end
    end
    return GuideUI.Show(instanceId, index)
end

-- The expanded HUD's line: the next boss's (or the fight's) top two
-- mechanics. Cached per boss; nothing is built here in combat.
local hudSection = { key = "guide", height = 34 }
GuideUI.hudSection = hudSection

function hudSection.create(parent)
    local frame = UI.CreateFrame("Frame", parent)
    frame.gwHeight = 34
    frame.title = noWrap(UI.Text(frame, "small", "gold"))
    frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    frame.title:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
    frame.line = noWrap(UI.Text(frame, "small", "text"))
    frame.line:SetPoint("TOPLEFT", frame.title, "BOTTOMLEFT", 0, -3)
    frame.line:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
    return frame
end

function hudSection.refresh(frame, run)
    if not run or not run.instanceId then return false end
    local hud = GW.DungeonHud
    local entries = hud and hud.Portraits and hud.Portraits(run) or {}
    local target
    for _, entry in ipairs(entries) do
        if entry.kind == "engaged" then target = entry break end
    end
    if not target then
        for _, entry in ipairs(entries) do
            if entry.kind == "pending" and entry.name then target = entry break end
        end
    end
    local boss = target and GuideUI.BossForEntry(run.instanceId, target)
    if not boss then return false end
    if frame.gwBoss ~= boss then
        frame.gwBoss = boss
        local parts = {}
        for _, row in ipairs(Guide.TopMechanics(boss, nil, 2)) do
            table.insert(parts, Theme.Colorize(row.label, Guide.LABEL_COLORS[row.label] or "textMuted") .. " " .. tostring(row.spell.n))
        end
        frame.gwHasText = #parts > 0
        if #parts == 0 then return false end
        UI.SetText(frame.title, (target.kind == "engaged" and "NOW: " or "NEXT: ") .. boss.name)
        UI.SetText(frame.line, table.concat(parts, "   "))
        frame.gwHasText = true
    end
    return frame.gwHasText == true
end

local hud = GW.DungeonHud
if hud then
    hud.extraSections = hud.extraSections or {}
    table.insert(hud.extraSections, hudSection)
end

-- Events: instance changes, the end of combat, and shift over an item.
-- Registered once at load; the handlers only touch an open window.
local events = type(Globals.CreateFrame) == "function" and Globals.CreateFrame("Frame") or nil
if events then
    events:RegisterEvent("PLAYER_ENTERING_WORLD")
    events:RegisterEvent("PLAYER_REGEN_ENABLED")
    events:RegisterEvent("MODIFIER_STATE_CHANGED")
    events:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_ENABLED" then
            GuideUI.OnCombatEnded()
        elseif event == "MODIFIER_STATE_CHANGED" then
            if GuideUI.hoveredItem then GuideUI.OnModifierChanged() end
        else
            GuideUI.OnInstanceChanged()
        end
    end)
    GuideUI.events = events
end
