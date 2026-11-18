local _, GW = ...

-- The Dungeon Guide: a dungeon journal in the dashboard (Overview |
-- Encounters | Loot | Trash & Rares) and the dungeon HUD's links into it
-- (the ? button, clickable boss faces, a "next boss" line in the expanded
-- HUD and mechanics in boss tooltips).
--
-- Layout (532 x 418 content): a header with the dungeon picker and the role
-- switch, the tabs, then two columns: navigation on the left (encounters,
-- trash), the map or the encounter panel on the right.
--
-- Built on first open, like every dashboard view. Nothing here runs on a
-- timer or OnUpdate: the view repaints when it is shown, when the player
-- picks something, or when the instance or combat state changes. Lists are
-- fixed pools of rows with paging. The client draws all art (maps, faces,
-- spell and item icons) from IDs; Guildweaver ships none of it.
--
-- Wishlists are read-only here: the website is where they are edited.
GW.DungeonGuideUI = GW.DungeonGuideUI or {}

local GuideUI = GW.DungeonGuideUI
local Globals = _G or {}
local UI, Theme = GW.UI, GW.Theme
local Guide = GW.DungeonGuide
local Portraits = GW.Portraits
local DungeonMap = GW.DungeonMap

local CONTENT_WIDTH = 532
local BODY_TOP = -82
local BODY_HEIGHT = 336
local LEFT_WIDTH = 168
local RIGHT_LEFT = 180
local RIGHT_WIDTH = CONTENT_WIDTH - RIGHT_LEFT
local DOT = "\194\183"
local DASH = "\226\128\148"

local ICONS = {
    unknown = "Interface\\Icons\\INV_Misc_QuestionMark",
    wish = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_3",
    acquired = "Interface\\RaidFrame\\ReadyCheck-Ready",
    rare = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1",
    trash = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8",
    arrow = "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up",
    search = "Interface\\Common\\UI-Searchbox-Icon",
}
GuideUI.ICONS = ICONS

local TABS = { { "overview", "Overview" }, { "bosses", "Encounters" }, { "loot", "Loot" }, { "rares", "Trash & Rares" } }
local QUALITY = { [0] = "9d9d9d", [1] = "ffffff", [2] = "1eff00", [3] = "0070dd", [4] = "a335ee", [5] = "ff8000" }
local QUALITY_RGB = { [0] = { 0.62, 0.62, 0.62 }, [1] = { 1, 1, 1 }, [2] = { 0.12, 1, 0 }, [3] = { 0, 0.44, 0.87 }, [4] = { 0.64, 0.21, 0.93 }, [5] = { 1, 0.5, 0 } }

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

local spellIcons = {}
function GuideUI.SpellIcon(spellId)
    spellId = tonumber(spellId)
    if not spellId then return ICONS.unknown end
    local cached = spellIcons[spellId]
    if cached ~= nil then return cached or ICONS.unknown end
    local file
    if type(Globals.GetSpellTexture) == "function" then
        local ok, value = pcall(Globals.GetSpellTexture, spellId)
        if ok then file = value end
    end
    spellIcons[spellId] = file or false
    return file or ICONS.unknown
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
    return #parts > 0 and table.concat(parts, "  " .. DOT .. "  ") or nil
end

-- Ability lines for tooltips and the HUD: "KICK  Spell name  summary".
function GuideUI.AbilityText(row)
    local color = Guide.LABEL_COLORS[row.label] or "textMuted"
    return Theme.Colorize(row.label, color) .. "  " .. tostring(row.spell.n) .. (row.spell.s and Theme.Colorize("  " .. row.spell.s, "textFaint") or "")
end

-- Tooltips -------------------------------------------------------------------------------------
--
-- Next to the cursor, not at the far edge of a wide row: the tooltip's
-- bottom-left corner sits just right of and above the pointer. GameTooltip
-- is clamped to the screen by the client, so it flips inward at the edges.

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
-- held or always-compare is on), with what the guide knows underneath.
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
    if row.item and row.item.set then addLine(tooltip, "Set: " .. row.item.set, "textMuted") end
    if row.acquired then
        addLine(tooltip, "On your wishlist " .. DASH .. " acquired", "good")
    elseif row.wanted then
        addLine(tooltip, "On your wishlist (" .. tostring(row.wanted.priority) .. ")" .. (row.wanted.note and row.wanted.note ~= "" and (": " .. row.wanted.note) or ""),
            "alertWishlist", true)
    end
    if row.kind ~= "wishlist" then addLine(tooltip, "Reference loot: " .. Guide.REFERENCE_NOTE .. ". Drop chances not shown.", "textFaint", true) end
    pcall(tooltip.Show, tooltip)
    GuideUI.hoveredItem = { owner = owner, row = row }
    if shown and wantsCompare() and type(Globals.GameTooltip_ShowCompareItem) == "function" then
        pcall(Globals.GameTooltip_ShowCompareItem, tooltip)
    end
end

function GuideUI.HideTooltip()
    GuideUI.hoveredItem = nil
    UI.HideTooltip()
    local compare = Globals.ShoppingTooltip1
    if compare and type(compare.Hide) == "function" then pcall(compare.Hide, compare) end
    compare = Globals.ShoppingTooltip2
    if compare and type(compare.Hide) == "function" then pcall(compare.Hide, compare) end
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

-- Rows -------------------------------------------------------------------------------------

local function rowBase(parent, width, height, onClick)
    local row = UI.CreateFrame("Button", parent)
    row:SetSize(width, height)
    Theme.Skin(row, { 0, 0, 0, 0 }, { 0, 0, 0, 0 })
    pcall(row.RegisterForClicks, row, "LeftButtonUp")
    row:SetScript("OnClick", function(self) if onClick and self.gwData then onClick(self.gwData, self) end end)
    row:SetScript("OnEnter", function(self)
        if self.gwData then
            if not self.gwSelected then Theme.SetBackground(self, "bgHover") end
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

-- An encounter frame: portrait, name, level and observed state, the top
-- mechanics' spell icons, and how many wishlist items drop.
local MECHANIC_ICONS = 3
local function encounterRow(parent, width, height, onClick)
    local row = rowBase(parent, width, height, onClick)
    local size = height - 6
    row.portrait = UI.Portrait(row, size)
    pcall(row.portrait.EnableMouse, row.portrait, false)
    row.portrait:SetPoint("LEFT", row, "LEFT", 3, 0)
    row.name = noWrap(UI.Text(row, height >= 34 and "label" or "small", "text"))
    row.name:SetPoint("TOPLEFT", row.portrait, "TOPRIGHT", 6, height >= 34 and -2 or 0)
    row.name:SetPoint("RIGHT", row, "RIGHT", -22, 0)
    row.sub = noWrap(UI.Text(row, "small", "textFaint"))
    row.sub:SetPoint("BOTTOMLEFT", row.portrait, "BOTTOMRIGHT", 6, height >= 34 and 2 or 0)
    row.marks = {}
    for index = 1, MECHANIC_ICONS do
        local mark = icon(row, 13, "OVERLAY")
        mark:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4 - (index - 1) * 15, 4)
        row.marks[index] = mark
    end
    row.wish = icon(row, 13, "OVERLAY")
    setIcon(row.wish, ICONS.wish, false)
    row.wishCount = UI.Text(row, "small", "alertWishlist", "RIGHT")
    if height < 34 then
        row.name:SetPoint("RIGHT", row, "RIGHT", -60, 0)
        row.sub:ClearAllPoints()
        row.sub:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        pcall(row.sub.SetJustifyH, row.sub, "RIGHT")
        row.name:ClearAllPoints()
        row.name:SetPoint("LEFT", row.portrait, "RIGHT", 6, 0)
        row.name:SetPoint("RIGHT", row.sub, "LEFT", -4, 0)
    end
    -- entry: { creature, index, displayId, icon, level, state, mechanics, wanted, selected, sub }
    function row:Fill(entry)
        self.gwData = entry
        UI.SetText(self.name, entry.creature.name)
        Theme.Tint(self.name, entry.state == "defeated" and "textMuted" or (entry.selected and "goldBright" or "text"))
        UI.SetText(self.sub, entry.sub or "")
        self.portrait:SetCreature(entry.displayId, entry.icon)
        self.portrait:SetState(entry.state or (entry.displayId and "available" or "unknown"))
        local shownMarks = 0
        for index, mark in ipairs(self.marks) do
            local mechanic = height >= 34 and entry.mechanics and entry.mechanics[index] or nil
            if mechanic then
                setIcon(mark, GuideUI.SpellIcon(mechanic.id))
                mark:Show()
                shownMarks = index
            else
                mark:Hide()
            end
        end
        local wanted = entry.wanted or 0
        self.wish:ClearAllPoints()
        self.wish:SetPoint(height >= 34 and "TOPRIGHT" or "RIGHT", self, height >= 34 and "TOPRIGHT" or "RIGHT", -4, height >= 34 and -4 or 0)
        UI.SetShown(self.wish, wanted > 0 and height >= 34)
        UI.SetText(self.wishCount, wanted > 1 and tostring(wanted) or "")
        self.wishCount:ClearAllPoints()
        self.wishCount:SetPoint("RIGHT", self.wish, "LEFT", -1, 0)
        UI.SetShown(self.wishCount, wanted > 1 and height >= 34)
        self.gwMarks = shownMarks
        if height >= 34 then
            -- The level and state line stops before the mechanic icons.
            self.sub:ClearAllPoints()
            self.sub:SetPoint("BOTTOMLEFT", self.portrait, "BOTTOMRIGHT", 6, 2)
            self.sub:SetPoint("RIGHT", self, "RIGHT", -(6 + shownMarks * 15), 0)
        end
        self:SetSelected(entry.selected)
        self:Show()
    end
    return row
end

-- An ability: spell icon, label, name, the client's short summary.
local function abilityRow(parent, width)
    local row = rowBase(parent, width, 22, nil)
    row.icon = icon(row, 18)
    row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.tag = UI.Text(row, "caps", "info", "LEFT")
    row.tag:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.tag:SetWidth(42)
    row.text = noWrap(UI.Text(row, "label", "text"))
    row.text:SetPoint("LEFT", row.tag, "RIGHT", 2, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    function row:Fill(ability)
        self.gwData, self.gwEnter = ability, GuideUI.ShowSpellTooltip
        setIcon(self.icon, GuideUI.SpellIcon(ability.id))
        UI.SetText(self.tag, ability.label)
        Theme.Tint(self.tag, Guide.LABEL_COLORS[ability.label] or "textMuted")
        UI.SetText(self.text, tostring(ability.spell.n) .. (ability.spell.s and Theme.Colorize("  " .. ability.spell.s, "textFaint") or ""))
        self:SetSelected(false)
        self:Show()
    end
    return row
end

-- An item: its icon in a quality-coloured frame, the quality-coloured
-- name, its facts, where it drops and its wishlist state.
local function itemRow(parent, width, height, onClick)
    local row = rowBase(parent, width, height, onClick)
    local size = height - 6
    row.frame = UI.CreateFrame("Frame", row)
    row.frame:SetSize(size, size)
    row.frame:SetPoint("LEFT", row, "LEFT", 3, 0)
    Theme.Skin(row.frame, "bgInset", "border")
    row.icon = icon(row.frame, size - 2)
    row.icon:SetPoint("CENTER", row.frame, "CENTER", 0, 0)
    row.mark = icon(row, 14, "OVERLAY")
    row.mark:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.source = noWrap(UI.Text(row, "small", "textFaint", "RIGHT"))
    row.source:SetPoint("RIGHT", row.mark, "LEFT", -6, 0)
    row.source:SetWidth(math.floor(width * 0.28))
    row.name = noWrap(UI.Text(row, "label", "text"))
    row.name:SetPoint("TOPLEFT", row.frame, "TOPRIGHT", 7, height >= 28 and -1 or 0)
    row.name:SetPoint("RIGHT", row.source, "LEFT", -6, 0)
    row.facts = noWrap(UI.Text(row, "small", "textMuted"))
    row.facts:SetPoint("BOTTOMLEFT", row.frame, "BOTTOMRIGHT", 7, 1)
    row.facts:SetPoint("RIGHT", row.source, "LEFT", -6, 0)
    UI.SetShown(row.facts, height >= 28)
    function row:Fill(data, source)
        self.gwData, self.gwEnter = data, GuideUI.ShowItemTooltip
        setIcon(self.icon, GuideUI.ItemIcon(data.itemId))
        local rgb = QUALITY_RGB[(data.item and data.item.q) or 1] or QUALITY_RGB[1]
        Theme.SetBorder(self.frame, { rgb[1], rgb[2], rgb[3], 0.9 })
        UI.SetText(self.name, GuideUI.ItemName(data))
        UI.SetText(self.facts, GuideUI.ItemFacts(data.item) or "")
        UI.SetText(self.source, source or "")
        pcall(self.source.SetWidth, self.source, (source and source ~= "") and math.floor(width * 0.28) or 1)
        if data.acquired then
            setIcon(self.mark, ICONS.acquired, false)
            self.mark:Show()
        elseif data.wanted then
            setIcon(self.mark, ICONS.wish, false)
            self.mark:Show()
        else
            self.mark:Hide()
        end
        self:SetSelected(data.wanted and not data.acquired)
        self:Show()
    end
    return row
end

local function emptyText(parent, width)
    local text = UI.Text(parent, "label", "textFaint")
    text:SetWidth(width)
    pcall(text.SetWordWrap, text, true)
    pcall(text.SetJustifyV, text, "TOP")
    return text
end

-- Page arrows and "2/3".
local function pager(parent, onPage)
    local frame = UI.CreateFrame("Frame", parent)
    frame:SetSize(90, 22)
    frame.prev = DungeonMap.Arrow(frame, DungeonMap.PREV, function() onPage(-1) end)
    frame.prev:SetPoint("LEFT", frame, "LEFT", 0, 0)
    frame.next = DungeonMap.Arrow(frame, DungeonMap.NEXT, function() onPage(1) end)
    frame.next:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
    frame.label = UI.Text(frame, "small", "textMuted", "CENTER")
    frame.label:SetPoint("LEFT", frame.prev, "RIGHT", 0, 0)
    frame.label:SetPoint("RIGHT", frame.next, "LEFT", 0, 0)
    function frame:Set(page, pages)
        UI.SetShown(self, pages > 1)
        UI.SetText(self.label, page .. "/" .. pages)
        self.prev:SetActive(page > 1)
        self.next:SetActive(page < pages)
    end
    return frame
end

local function clampPage(page, count, perPage)
    local pages = math.max(1, math.ceil(count / perPage))
    return math.max(1, math.min(page or 1, pages)), pages
end

-- State --------------------------------------------------------------------------------------

local state = { tab = nil, boss = 1, rare = 1, lootPage = 1, lootFilter = "all", listPage = 1, trashPage = 1, floor = nil,
    detailTab = "abilities", detailPage = 1, picker = { query = "", band = "all", kind = "all", page = 1 } }
GuideUI.state = state

local function selectedId()
    return state.instanceId or Guide.SelectedInstanceId()
end

local function showTab(view, tab)
    state.tab = tab
    prefs().tab = tab
    for key, frame in pairs(view.tabs) do UI.SetShown(frame, key == tab) end
    view.tabBar:Refresh()
end

-- What the run open here observed, per boss.
local function encounterStates(instanceId, dungeon)
    local run = Guide.CurrentRun()
    local states = {}
    if not run or tonumber(run.instanceId) ~= tonumber(instanceId) then return states end
    for _, boss in ipairs(dungeon.bosses) do states[boss] = Guide.EncounterState(instanceId, boss, run) end
    return states
end

local STATE_TEXT = { engaged = Theme.Colorize("In combat", "bad"), defeated = Theme.Colorize("Defeated", "gold") }

-- An encounter list entry for a boss.
local function bossEntry(instanceId, boss, index, states, selected)
    local level = Guide.CreatureLevel(boss)
    local parts = {}
    if level then table.insert(parts, "Level " .. level) end
    local observed = states[boss]
    if observed then table.insert(parts, STATE_TEXT[observed]) end
    local wanted = 0
    for _, row in ipairs(Guide.CreatureLoot(boss)) do
        if row.wanted and not row.acquired then wanted = wanted + 1 end
    end
    local displayId = Guide.DisplayId(instanceId, boss)
    return { creature = boss, index = index, kind = "boss", displayId = displayId, level = level,
        state = (index == selected and "selected") or observed or (displayId and "available" or "unknown"),
        mechanics = Guide.TopMechanics(boss, Guide.Role(), MECHANIC_ICONS), wanted = wanted, selected = index == selected,
        sub = table.concat(parts, "  " .. DOT .. "  ") }
end

-- The encounter panel -------------------------------------------------------------------------
--
-- 1. a large portrait and the name, 2. two to four mechanics that matter,
-- 3. every ability with its spell icon, 4. the loot with item icons and the
-- wishlist marked. Used for bosses, rares and dangerous trash.

local WATCH_ROWS, DETAIL_ROWS, DETAIL_LOOT_ROWS = 4, 6, 4

local function detailPanel(_, parent, width)
    local panel = UI.CreateFrame("Frame", parent)
    panel:SetSize(width, BODY_HEIGHT)
    panel.portrait = UI.Portrait(panel, 60)
    pcall(panel.portrait.EnableMouse, panel.portrait, false)
    panel.portrait:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    panel.name = noWrap(UI.Text(panel, "pageTitle", "goldBright"))
    panel.name:SetPoint("TOPLEFT", panel.portrait, "TOPRIGHT", 10, -6)
    panel.name:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
    panel.facts = noWrap(UI.Text(panel, "label", "textMuted"))
    panel.facts:SetPoint("TOPLEFT", panel.name, "BOTTOMLEFT", 0, -5)
    panel.facts:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
    panel.note = noWrap(UI.Text(panel, "small", "textFaint"))
    panel.note:SetPoint("TOPLEFT", panel.facts, "BOTTOMLEFT", 0, -4)
    panel.note:SetPoint("RIGHT", panel, "RIGHT", 0, 0)

    panel.watchHeader = UI.SectionHeader(panel, "Watch for")
    panel.watchHeader:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -70)
    panel.watchHeader:SetWidth(width)
    panel.watch = {}
    for index = 1, WATCH_ROWS do
        local row = abilityRow(panel, width)
        row:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -92 - (index - 1) * 22)
        panel.watch[index] = row
    end
    panel.watchEmpty = emptyText(panel, width)
    panel.watchEmpty:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -94)

    panel.switch = UI.Segmented(panel, { { "abilities", "Abilities" }, { "loot", "Loot" } }, function() return state.detailTab end, function(value)
        state.detailTab, state.detailPage = value, 1
        GuideUI.Refresh()
    end, { segmentWidth = 86, height = 20 })
    panel.pager = pager(panel, function(step)
        state.detailPage = state.detailPage + step
        GuideUI.Refresh()
    end)
    panel.abilities = {}
    for index = 1, DETAIL_ROWS do panel.abilities[index] = abilityRow(panel, width) end
    panel.loot = {}
    for index = 1, DETAIL_LOOT_ROWS do panel.loot[index] = itemRow(panel, width, 28) end
    panel.listEmpty = emptyText(panel, width)
    return panel
end

local function paintDetail(_, panel, instanceId, creature, kind, observed)
    if not creature then
        panel:Hide()
        return
    end
    panel:Show()
    local displayId = Guide.DisplayId(instanceId, creature)
    panel.portrait:SetCreature(displayId, kind == "rare" and ICONS.rare or (kind == "trash" and ICONS.trash or nil))
    panel.portrait:SetState(observed or (displayId and "available" or "unknown"))
    UI.SetText(panel.name, creature.name)
    local facts = {}
    local level = Guide.CreatureLevel(creature)
    if level then table.insert(facts, "Level " .. level) end
    local class = Guide.CreatureClass(creature)
    if kind == "rare" then table.insert(facts, creature.elite and "Rare elite" or "Rare")
    elseif kind == "trash" then table.insert(facts, "Dangerous trash" .. (creature.n and creature.n > 1 and ("  \195\151" .. creature.n) or ""))
    elseif class then table.insert(facts, class) end
    if observed then table.insert(facts, STATE_TEXT[observed] .. (observed == "defeated" and Theme.Colorize(" this run", "textMuted") or "")) end
    UI.SetText(panel.facts, table.concat(facts, "  " .. DOT .. "  "))

    local abilities = Guide.Abilities(creature)
    local verified = false
    for _, row in ipairs(abilities) do if Guide.IsVerified(row.spell) then verified = true end end
    UI.SetText(panel.note, verified and "Some entries verified on Forever." or ("Mechanics and loot: " .. Guide.REFERENCE_NOTE))

    local role = Guide.Role()
    local top = Guide.TopMechanics(creature, role, WATCH_ROWS)
    panel.watchHeader:SetTitle("Watch for" .. (role and (" " .. DASH .. " " .. role) or ""))
    for index, row in ipairs(panel.watch) do
        if top[index] then row:Fill(top[index]) else row:Clear() end
    end
    UI.SetText(panel.watchEmpty, #abilities == 0 and "No abilities in the atlas for this creature. That does not mean it has none." or "")
    UI.SetShown(panel.watchEmpty, #abilities == 0)

    -- Abilities | Loot, under the mechanics.
    local switchTop = -92 - math.max(1, #top) * 22 - 10
    local loot = kind ~= "trash" and Guide.CreatureLoot(creature) or {}
    if kind == "trash" then state.detailTab = "abilities" end
    panel.switch.buttons[1]:SetLabel("Abilities (" .. #abilities .. ")")
    panel.switch.buttons[2]:SetLabel("Loot (" .. #loot .. ")")
    UI.SetShown(panel.switch.buttons[2], kind ~= "trash")
    panel.switch:ClearAllPoints()
    panel.switch:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, switchTop)
    panel.switch:Refresh()
    panel.pager:ClearAllPoints()
    panel.pager:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, switchTop + 1)
    local listTop = switchTop - 26
    local room = BODY_HEIGHT + listTop
    local empty = ""
    if state.detailTab == "loot" then
        local perPage = math.max(1, math.min(DETAIL_LOOT_ROWS, math.floor(room / 28)))
        local page, pages = clampPage(state.detailPage, #loot, perPage)
        state.detailPage = page
        panel.pager:Set(page, pages)
        for _, row in ipairs(panel.abilities) do row:Clear() end
        for index, rowFrame in ipairs(panel.loot) do
            local row = index <= perPage and loot[(page - 1) * perPage + index] or nil
            if row then
                row.from = creature.name
                rowFrame:ClearAllPoints()
                rowFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, listTop - (index - 1) * 28)
                rowFrame:Fill(row, nil)
            else
                rowFrame:Clear()
            end
        end
        if #loot == 0 then empty = "No reference loot listed for " .. creature.name .. "." end
    else
        local perPage = math.max(1, math.min(DETAIL_ROWS, math.floor(room / 22)))
        local page, pages = clampPage(state.detailPage, #abilities, perPage)
        state.detailPage = page
        panel.pager:Set(page, pages)
        for _, row in ipairs(panel.loot) do row:Clear() end
        for index, rowFrame in ipairs(panel.abilities) do
            local row = index <= perPage and abilities[(page - 1) * perPage + index] or nil
            if row then
                rowFrame:ClearAllPoints()
                rowFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, listTop - (index - 1) * 22)
                rowFrame:Fill(row)
            else
                rowFrame:Clear()
            end
        end
        if #abilities == 0 then empty = "None listed." end
    end
    panel.listEmpty:ClearAllPoints()
    panel.listEmpty:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, listTop - 2)
    UI.SetText(panel.listEmpty, empty)
    UI.SetShown(panel.listEmpty, empty ~= "")
end

-- Dungeon picker -----------------------------------------------------------------------------

local PICKER_ROWS = 11
local BANDS = {
    all = function() return true end,
    low = function(d) return (d.lmin or 0) < 30 end,
    mid = function(d) return (d.lmin or 0) >= 30 and (d.lmin or 0) < 50 end,
    high = function(d) return (d.lmin or 0) >= 50 end,
}

-- The dungeons the picker lists for its filters.
function GuideUI.PickerList(filters)
    filters = filters or state.picker
    local query = Guide.NormalizeName(filters.query or "")
    local band = BANDS[filters.band or "all"] or BANDS.all
    local list = {}
    for _, dungeon in ipairs(Guide.List()) do
        local kindOk = filters.kind == nil or filters.kind == "all" or (filters.kind == "raid") == (dungeon.kind == "raid")
        local nameOk = not query or string.find(Guide.NormalizeName(dungeon.name) or "", query, 1, true) ~= nil
        if kindOk and nameOk and band(dungeon) then table.insert(list, dungeon) end
    end
    return list
end

local function pickDungeon(id)
    state.pickerOpen = false
    if id == Guide.CurrentInstanceId() then Guide.FollowCurrent() else Guide.Select(id) end
    GuideUI.Show(id)
end

local function buildPicker(view)
    local picker = UI.CreateFrame("Frame", view)
    picker:SetPoint("TOPLEFT", view, "TOPLEFT", 0, -48)
    picker:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", 0, 0)
    Theme.Skin(picker, "bgRaised", "borderGold", 0.7)
    pcall(picker.SetFrameLevel, picker, GuideUI.FrameLevel(view) + 20)
    pcall(picker.EnableMouse, picker, true)
    picker:Hide()
    local header = UI.SectionHeader(picker, "Choose a dungeon")
    header:SetPoint("TOPLEFT", picker, "TOPLEFT", 12, -10)
    header:SetWidth(200)
    picker.close = UI.IconButton(picker, "\195\151", { size = 20, role = "glyph", tooltip = "Close", onClick = function()
        state.pickerOpen = false
        GuideUI.Refresh()
    end })
    picker.close:SetPoint("TOPRIGHT", picker, "TOPRIGHT", -6, -6)
    picker.here = UI.Button(picker, "Where I am", { width = 96, height = 22, variant = "primary", role = "small", onClick = function()
        local current = Guide.CurrentInstanceId()
        if current then pickDungeon(current) end
    end })
    picker.here:SetPoint("TOPRIGHT", picker, "TOPRIGHT", -12, -66)

    picker.search = UI.Input(picker, 200, function(box) box:ClearFocus() end)
    picker.search:SetPoint("TOPLEFT", picker, "TOPLEFT", 12, -38)
    picker.searchIcon = picker.search:CreateTexture(nil, "OVERLAY")
    picker.searchIcon:SetSize(12, 12)
    picker.searchIcon:SetPoint("RIGHT", picker.search, "RIGHT", -6, 0)
    pcall(picker.searchIcon.SetTexture, picker.searchIcon, ICONS.search)
    picker.hint = UI.Text(picker.search, "label", "textFaint")
    picker.hint:SetPoint("LEFT", picker.search, "LEFT", 7, 0)
    picker.hint:SetText("Search dungeons")
    picker.search:SetScript("OnTextChanged", function(box)
        local ok, text = pcall(box.GetText, box)
        state.picker.query = ok and text or ""
        state.picker.page = 1
        UI.SetShown(picker.hint, state.picker.query == "")
        GuideUI.RefreshPicker()
    end)
    picker.band = UI.Segmented(picker, { { "all", "All levels" }, { "low", "10\226\128\14729" }, { "mid", "30\226\128\14749" }, { "high", "50+" } },
        function() return state.picker.band end, function(value)
            state.picker.band, state.picker.page = value, 1
            GuideUI.RefreshPicker()
        end, { segmentWidth = 66, height = 22 })
    picker.band:SetPoint("TOPLEFT", picker, "TOPLEFT", 12, -66)
    picker.kind = UI.Segmented(picker, { { "all", "All" }, { "dungeon", "Dungeons" }, { "raid", "Raids" } },
        function() return state.picker.kind end, function(value)
            state.picker.kind, state.picker.page = value, 1
            GuideUI.RefreshPicker()
        end, { segmentWidth = 72, height = 22 })
    picker.kind:SetPoint("LEFT", picker.search, "RIGHT", 12, 0)

    local columnWidth = (CONTENT_WIDTH - 24 - 12) / 2
    picker.rows = {}
    for index = 1, PICKER_ROWS * 2 do
        local row = rowBase(picker, columnWidth, 22, function(data) pickDungeon(data.id) end)
        local column = index > PICKER_ROWS and 1 or 0
        row:SetPoint("TOPLEFT", picker, "TOPLEFT", 12 + column * (columnWidth + 12), -98 - ((index - 1) % PICKER_ROWS) * 22)
        row.name = noWrap(UI.Text(row, "label", "text"))
        row.name:SetPoint("LEFT", row, "LEFT", 6, 0)
        row.levels = UI.Text(row, "small", "textMuted", "RIGHT")
        row.levels:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        row.name:SetPoint("RIGHT", row.levels, "LEFT", -6, 0)
        picker.rows[index] = row
    end
    picker.pager = pager(picker, function(step)
        state.picker.page = state.picker.page + step
        GuideUI.RefreshPicker()
    end)
    picker.pager:SetPoint("BOTTOMRIGHT", picker, "BOTTOMRIGHT", -10, 8)
    picker.empty = emptyText(picker, CONTENT_WIDTH - 24)
    picker.empty:SetPoint("TOPLEFT", picker, "TOPLEFT", 12, -102)
    view.picker = picker
end

function GuideUI.RefreshPicker()
    local view = GuideUI.view
    local picker = view and view.picker
    if not picker then return end
    UI.SetShown(picker, state.pickerOpen == true)
    if not state.pickerOpen then return end
    picker.band:Refresh()
    picker.kind:Refresh()
    local current, shown = Guide.CurrentInstanceId(), selectedId()
    UI.SetShown(picker.here, current ~= nil)
    local list = GuideUI.PickerList()
    local perPage = PICKER_ROWS * 2
    local page, pages = clampPage(state.picker.page, #list, perPage)
    state.picker.page = page
    picker.pager:Set(page, pages)
    for index, row in ipairs(picker.rows) do
        local dungeon = list[(page - 1) * perPage + index]
        if dungeon then
            row.gwData = dungeon
            local name = dungeon.name .. (dungeon.kind == "raid" and Theme.Colorize("  Raid", "textFaint") or "")
            if dungeon.id == current then name = name .. Theme.Colorize("  here", "good") end
            UI.SetText(row.name, name)
            Theme.Tint(row.name, dungeon.id == shown and "goldBright" or "text")
            UI.SetText(row.levels, Guide.LevelText(dungeon.lmin, dungeon.lmax) or "")
            row:SetSelected(dungeon.id == shown)
            row:Show()
        else
            row:Clear()
        end
    end
    UI.SetText(picker.empty, #list == 0 and "No dungeon matches. Clear the search or pick All levels." or "")
    UI.SetShown(picker.empty, #list == 0)
end

local function openPicker()
    state.pickerOpen = not state.pickerOpen
    if state.pickerOpen and GuideUI.view and GuideUI.view.picker then
        pcall(GuideUI.view.picker.search.SetText, GuideUI.view.picker.search, state.picker.query or "")
    end
    GuideUI.RefreshPicker()
end

-- Tabs ----------------------------------------------------------------------------------------

local OVERVIEW_ROWS, ENCOUNTER_ROWS, TRASH_ROWS, LOOT_ROWS = 9, 8, 12, 10

local function goToBoss(view, index)
    state.boss, state.detailPage, state.encounterPage = index, 1, nil
    view.showAll = false
    showTab(view, "bosses")
    GuideUI.Refresh()
end

local function pinTooltip(pin, owner)
    local tooltip = Globals.GameTooltip
    if not tooltip or type(tooltip.SetOwner) ~= "function" then return end
    GuideUI.AnchorTooltip(tooltip, owner)
    pcall(tooltip.ClearLines, tooltip)
    addLine(tooltip, pin.index .. ". " .. pin.creature.name, "goldBright")
    local level = Guide.CreatureLevel(pin.creature)
    if level then addLine(tooltip, "Level " .. level, "textMuted") end
    for _, row in ipairs(Guide.TopMechanics(pin.creature, Guide.Role(), 2)) do addLine(tooltip, GuideUI.AbilityText(row), "text") end
    addLine(tooltip, "Position from Blizzard's dungeon journal. Click for the encounter.", "textFaint", true)
    pcall(tooltip.Show, tooltip)
end

local function buildOverview(view, body)
    body.header = UI.SectionHeader(body, "Encounters")
    body.header:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    body.header:SetWidth(LEFT_WIDTH)
    body.list = {}
    for index = 1, OVERVIEW_ROWS do
        local row = encounterRow(body, LEFT_WIDTH, 30, function(data) goToBoss(view, data.index) end)
        row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -24 - (index - 1) * 31)
        body.list[index] = row
    end
    body.pager = pager(body, function(step)
        state.listPage = state.listPage + step
        GuideUI.Refresh()
    end)
    body.pager:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 38, 0)
    body.listEmpty = emptyText(body, LEFT_WIDTH)
    body.listEmpty:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -26)

    body.map = DungeonMap.New(body, RIGHT_WIDTH - 2, {
        onPin = function(pin) goToBoss(view, pin.index) end,
        onPinEnter = pinTooltip,
        onFloor = function(floor)
            state.floor = floor
            GuideUI.Refresh()
        end,
    })
    body.map:SetPoint("TOPLEFT", body, "TOPLEFT", RIGHT_LEFT, 0)
    body.summary = {}
    for index = 1, 3 do
        local line = noWrap(UI.Text(body, "label", "text"))
        line:SetPoint("TOPLEFT", body, "TOPLEFT", RIGHT_LEFT, -(body.map.gwHeight + 34) - (index - 1) * 18)
        line:SetWidth(RIGHT_WIDTH)
        body.summary[index] = line
    end
    body.wishIcon = icon(body, 14, "OVERLAY")
    setIcon(body.wishIcon, ICONS.wish, false)
    body.quests = UI.CreateFrame("Button", body)
    body.quests:SetSize(RIGHT_WIDTH, 18)
    body.quests:SetPoint("TOPLEFT", body.summary[3], "TOPLEFT", 0, 2)
    body.quests:SetScript("OnEnter", function(self)
        local list = self.gwQuests
        if not list or #list == 0 then return end
        local tooltip = Globals.GameTooltip
        if not tooltip or type(tooltip.SetOwner) ~= "function" then return end
        GuideUI.AnchorTooltip(tooltip, self)
        pcall(tooltip.ClearLines, tooltip)
        addLine(tooltip, "Dungeon quests", "goldBright")
        for index, quest in ipairs(list) do
            if index > 12 then
                addLine(tooltip, "+" .. (#list - 12) .. " more", "textFaint")
                break
            end
            addLine(tooltip, (quest.lvl and ("[" .. quest.lvl .. "] ") or "") .. quest.name .. (quest.rew and Theme.Colorize("  reward", "textFaint") or ""), "text")
        end
        addLine(tooltip, Guide.REFERENCE_NOTE, "textFaint")
        pcall(tooltip.Show, tooltip)
    end)
    body.quests:SetScript("OnLeave", GuideUI.HideTooltip)
end

local function refreshOverview(_, body, instanceId, dungeon)
    local states = encounterStates(instanceId, dungeon)
    body.header:SetTitle("Encounters (" .. #dungeon.bosses .. ")")
    local page = clampPage(state.listPage, #dungeon.bosses, OVERVIEW_ROWS)
    state.listPage = page
    body.pager:Set(page, math.max(1, math.ceil(#dungeon.bosses / OVERVIEW_ROWS)))
    for index, row in ipairs(body.list) do
        local bossIndex = (page - 1) * OVERVIEW_ROWS + index
        local boss = dungeon.bosses[bossIndex]
        if boss then row:Fill(bossEntry(instanceId, boss, bossIndex, states, nil)) else row:Clear() end
    end
    UI.SetText(body.listEmpty, #dungeon.bosses == 0 and "No bosses in the atlas for this dungeon." or "")
    UI.SetShown(body.listEmpty, #dungeon.bosses == 0)

    local result = body.map:ShowDungeon(instanceId, state.floor or 1, nil, states)
    if result == "deferred" then GuideUI.pending = true end

    local entry = Guide.Index()[instanceId] or {}
    local pins = Guide.Pins(instanceId)
    local floors = Guide.Floors(instanceId)
    local where = dungeon.entrance and ("Entrance: " .. tostring(entry.zone or dungeon.zone or "?") .. " " .. Guide.Coordinates(dungeon.entrance.x, dungeon.entrance.y))
        or ("Entrance not known" .. (dungeon.zone and (" (" .. dungeon.zone .. ")") or ""))
    local placed
    if #floors == 0 then
        placed = Theme.Colorize("No client map for this instance.", "textFaint")
    elseif #pins < #dungeon.bosses then
        placed = Theme.Colorize(#pins .. " of " .. #dungeon.bosses .. " bosses have a journal position; the rest are only listed.", "textFaint")
    else
        placed = Theme.Colorize("Boss positions from Blizzard's dungeon journal.", "textFaint")
    end
    local wanted = Guide.WantedCount(instanceId)
    UI.SetText(body.summary[1], where)
    UI.SetText(body.summary[2], placed)
    local quests = Guide.Quests(instanceId)
    body.quests.gwQuests = quests
    local questText = #quests > 0 and (#quests .. (#quests == 1 and " quest" or " quests") .. Theme.Colorize("  (hover for the list)", "textFaint"))
        or Theme.Colorize("No dungeon quests in the atlas for your faction", "textFaint")
    if wanted > 0 then
        UI.SetText(body.summary[3], "      " .. Theme.Colorize(wanted .. (wanted == 1 and " wishlist item drops here" or " wishlist items drop here"), "alertWishlist")
            .. "   " .. DOT .. "   " .. questText)
        body.wishIcon:ClearAllPoints()
        body.wishIcon:SetPoint("LEFT", body.summary[3], "LEFT", 0, 0)
        body.wishIcon:Show()
    else
        UI.SetText(body.summary[3], questText)
        body.wishIcon:Hide()
    end
end

local function buildEncounters(view, body)
    body.list = {}
    for index = 1, ENCOUNTER_ROWS do
        local row = encounterRow(body, LEFT_WIDTH, 38, function(data)
            state.boss, state.detailPage = data.index, 1
            local pin = Guide.PinFor(selectedId(), data.creature)
            if pin then state.floor = pin.floor end
            GuideUI.Refresh()
        end)
        row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -(index - 1) * 39)
        body.list[index] = row
    end
    body.pager = pager(body, function(step)
        state.encounterPage = (state.encounterPage or 1) + step
        GuideUI.Refresh()
    end)
    body.pager:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 38, 0)
    body.listEmpty = emptyText(body, LEFT_WIDTH)
    body.listEmpty:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    body.detail = detailPanel(view, body, RIGHT_WIDTH)
    body.detail:SetPoint("TOPLEFT", body, "TOPLEFT", RIGHT_LEFT, 0)
end

local function refreshEncounters(view, body, instanceId, dungeon)
    local states = encounterStates(instanceId, dungeon)
    local selected = math.max(1, math.min(state.boss or 1, #dungeon.bosses))
    state.boss = selected
    -- The page that holds the selected boss, unless the player turned it.
    local pages = math.max(1, math.ceil(#dungeon.bosses / ENCOUNTER_ROWS))
    local page = math.max(1, math.min(state.encounterPage or (math.floor((selected - 1) / ENCOUNTER_ROWS) + 1), pages))
    state.encounterPage = page
    body.pager:Set(page, pages)
    for index, row in ipairs(body.list) do
        local bossIndex = (page - 1) * ENCOUNTER_ROWS + index
        local boss = dungeon.bosses[bossIndex]
        if boss then row:Fill(bossEntry(instanceId, boss, bossIndex, states, selected)) else row:Clear() end
    end
    UI.SetText(body.listEmpty, #dungeon.bosses == 0 and "No bosses in the atlas for this dungeon." or "")
    UI.SetShown(body.listEmpty, #dungeon.bosses == 0)
    local boss = dungeon.bosses[selected]
    paintDetail(view, body.detail, instanceId, boss, "boss", boss and states[boss])
end

-- Rares first, then dangerous trash, in one list.
local function rareEntries(dungeon)
    local list = {}
    for _, rare in ipairs(dungeon.rares) do table.insert(list, { creature = rare, kind = "rare" }) end
    for _, creature in ipairs(dungeon.trash) do table.insert(list, { creature = creature, kind = "trash" }) end
    return list
end

local function buildRares(view, body)
    body.list = {}
    for index = 1, TRASH_ROWS do
        local row = encounterRow(body, LEFT_WIDTH, 26, function(data)
            state.rare, state.detailPage = data.index, 1
            GuideUI.Refresh()
        end)
        row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -(index - 1) * 26)
        body.list[index] = row
    end
    body.pager = pager(body, function(step)
        state.trashPage = state.trashPage + step
        GuideUI.Refresh()
    end)
    body.pager:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 38, 0)
    body.listEmpty = emptyText(body, LEFT_WIDTH)
    body.listEmpty:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    body.detail = detailPanel(view, body, RIGHT_WIDTH)
    body.detail:SetPoint("TOPLEFT", body, "TOPLEFT", RIGHT_LEFT, 0)
end

local function refreshRares(view, body, instanceId, dungeon)
    local list = rareEntries(dungeon)
    local selected = math.max(1, math.min(state.rare or 1, #list))
    state.rare = selected
    local pages = math.max(1, math.ceil(#list / TRASH_ROWS))
    local page = math.max(1, math.min(state.trashPage or 1, pages))
    state.trashPage = page
    body.pager:Set(page, pages)
    local shownRare = false
    for index, row in ipairs(body.list) do
        local listIndex = (page - 1) * TRASH_ROWS + index
        local entry = list[listIndex]
        if entry then
            local creature = entry.creature
            if entry.kind == "rare" then shownRare = true end
            local kick = false
            for _, ability in ipairs(Guide.Abilities(creature)) do if ability.label == "KICK" then kick = true end end
            local right = {}
            if creature.n and creature.n > 1 then table.insert(right, "\195\151" .. creature.n) end
            if kick then table.insert(right, Theme.Colorize("KICK", "info")) end
            if #right == 0 then table.insert(right, Guide.CreatureLevel(creature) or "") end
            local displayId = Guide.DisplayId(instanceId, creature)
            row:Fill({ creature = creature, index = listIndex, kind = entry.kind, displayId = displayId,
                icon = entry.kind == "rare" and ICONS.rare or ICONS.trash, state = listIndex == selected and "selected" or (displayId and "available" or "unknown"),
                selected = listIndex == selected, sub = table.concat(right, " ") })
        else
            row:Clear()
        end
    end
    UI.SetText(body.listEmpty, #list == 0 and "No rares or dangerous trash in the atlas for this dungeon." or "")
    UI.SetShown(body.listEmpty, #list == 0)
    local entry = list[selected]
    paintDetail(view, body.detail, instanceId, entry and entry.creature, entry and entry.kind, nil)
    return shownRare
end

local function buildLoot(_, body)
    body.filter = UI.Segmented(body, { { "all", "All" }, { "wanted", "Wishlist" } }, function() return state.lootFilter end, function(value)
        state.lootFilter = value
        state.lootPage = 1
        GuideUI.Refresh()
    end, { segmentWidth = 72, height = 20 })
    body.filter:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    body.pager = pager(body, function(step)
        state.lootPage = state.lootPage + step
        GuideUI.Refresh()
    end)
    body.pager:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, 1)
    body.status = noWrap(UI.Text(body, "small", "textFaint"))
    body.status:SetPoint("LEFT", body.filter, "RIGHT", 12, 0)
    body.status:SetPoint("RIGHT", body.pager, "LEFT", -8, 0)
    body.rows = {}
    for index = 1, LOOT_ROWS do
        local row = itemRow(body, CONTENT_WIDTH, 30, function(data)
            if data.bossIndex then goToBoss(GuideUI.view, data.bossIndex) end
        end)
        row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -26 - (index - 1) * 30)
        body.rows[index] = row
    end
    body.empty = emptyText(body, CONTENT_WIDTH)
    body.empty:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -30)
end

local function refreshLoot(_, body, instanceId)
    local all = Guide.LootRows(instanceId)
    local list = {}
    for _, row in ipairs(all) do
        if state.lootFilter ~= "wanted" or row.wanted then table.insert(list, row) end
    end
    local page, pages = clampPage(state.lootPage, #list, LOOT_ROWS)
    state.lootPage = page
    body.pager:Set(page, pages)
    body.filter:Refresh()
    local loot = GW.LootSync
    local status = loot and loot.Status and loot.Status() or {}
    UI.SetText(body.status, (status.matched and ("Wishlist: " .. tostring(status.characterName)) or "No website wishlist for this character")
        .. "  " .. DOT .. "  " .. Guide.REFERENCE_NOTE)
    for index, rowFrame in ipairs(body.rows) do
        local row = list[(page - 1) * LOOT_ROWS + index]
        if row then
            rowFrame:Fill(row, row.from or (row.kind == "wishlist" and "Wishlist source" or nil))
        else
            rowFrame:Clear()
        end
    end
    local empty = ""
    if #all == 0 then
        empty = "No reference loot for this dungeon in the packaged atlas."
    elseif #list == 0 then
        empty = "None of your wishlist items drop here."
    end
    UI.SetText(body.empty, empty)
    UI.SetShown(body.empty, empty ~= "")
end

-- The view ------------------------------------------------------------------------------------

local function buildView(view)
    GuideUI.view = view
    -- The picker button: the dungeon's name with a menu arrow.
    view.pick = UI.CreateFrame("Button", view)
    view.pick:SetSize(320, 26)
    view.pick:SetPoint("TOPLEFT", view, "TOPLEFT", -4, 2)
    Theme.Skin(view.pick, { 0, 0, 0, 0 }, { 0, 0, 0, 0 })
    pcall(view.pick.RegisterForClicks, view.pick, "LeftButtonUp")
    view.title = noWrap(UI.Text(view.pick, "pageTitle", "goldBright"))
    view.title:SetPoint("LEFT", view.pick, "LEFT", 4, 0)
    view.arrow = view.pick:CreateTexture(nil, "OVERLAY")
    view.arrow:SetSize(20, 20)
    pcall(view.arrow.SetTexture, view.arrow, ICONS.arrow)
    view.arrow:SetPoint("LEFT", view.title, "RIGHT", 4, 0)
    view.pick:SetScript("OnClick", openPicker)
    view.pick:SetScript("OnEnter", function(self)
        Theme.SetBorder(self, "borderGold")
        Theme.SetBackground(self, "bgHover")
        UI.ShowTooltip(self, "Choose a dungeon", { "Search by name, filter by level or type." }, "ANCHOR_BOTTOMLEFT")
    end)
    view.pick:SetScript("OnLeave", function(self)
        Theme.SetBorder(self, { 0, 0, 0, 0 })
        Theme.SetBackground(self, { 0, 0, 0, 0 })
        UI.HideTooltip()
    end)
    view.subtitle = noWrap(UI.Text(view, "label", "textMuted"))
    view.subtitle:SetPoint("TOPLEFT", view, "TOPLEFT", 0, -28)
    view.subtitle:SetWidth(CONTENT_WIDTH - 190)
    view.here = UI.Button(view, "Where I am", { width = 92, height = 20, role = "small", tooltip = "Return to the dungeon you are in",
        onClick = function()
            local current = Guide.CurrentInstanceId()
            if current then pickDungeon(current) end
        end })
    view.here:SetPoint("TOPRIGHT", view, "TOPRIGHT", 0, 0)
    view.role = UI.Segmented(view, { { "auto", "Any" }, { "tank", "Tank" }, { "healer", "Heal" }, { "dps", "DPS" } },
        function() return prefs().role or "auto" end,
        function(value)
            prefs().role = value
            GuideUI.Refresh()
        end, { segmentWidth = 44, height = 20 })
    view.role:SetPoint("TOPRIGHT", view, "TOPRIGHT", 0, -26)
    view.tabBar = UI.Segmented(view, TABS, function() return state.tab end, function(value)
        showTab(view, value)
        GuideUI.Refresh()
    end, { segmentWidth = 104, height = 22 })
    view.tabBar:SetPoint("TOPLEFT", view, "TOPLEFT", 0, -52)
    view.tabs = {}
    for _, tab in ipairs(TABS) do
        local body = UI.CreateFrame("Frame", view)
        body:SetPoint("TOPLEFT", view, "TOPLEFT", 0, BODY_TOP)
        body:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", 0, 0)
        body:Hide()
        view.tabs[tab[1]] = body
    end
    buildOverview(view, view.tabs.overview)
    buildEncounters(view, view.tabs.bosses)
    buildRares(view, view.tabs.rares)
    buildLoot(view, view.tabs.loot)
    view.missing = emptyText(view, CONTENT_WIDTH)
    view.missing:SetPoint("TOPLEFT", view, "TOPLEFT", 0, BODY_TOP)
    buildPicker(view)
    showTab(view, state.tab or prefs().tab or "overview")
end

local function refreshView(view)
    local started = GW.Perf and GW.Perf.Begin and GW.Perf.Begin()
    local instanceId = selectedId()
    local dungeon = instanceId and Guide.Dungeon(instanceId)
    if state.shownId ~= instanceId then
        state.shownId = instanceId
        state.boss, state.rare, state.lootPage, state.listPage, state.trashPage, state.detailPage, state.floor = 1, 1, 1, 1, 1, 1, nil
        state.encounterPage = nil
        view.showAll = false
        if dungeon and not inCombat() and Portraits then
            local ids = {}
            for _, boss in ipairs(dungeon.bosses) do table.insert(ids, Guide.DisplayId(instanceId, boss)) end
            Portraits.Prefetch(ids)
        end
    end
    view.role:Refresh()
    local current = Guide.CurrentInstanceId()
    UI.SetShown(view.here, current ~= nil and current ~= instanceId)
    GuideUI.RefreshPicker()
    if not dungeon then
        UI.SetText(view.title, "Dungeon Guide")
        UI.SetText(view.subtitle, Guide.Available() and "Pick a dungeon." or "No atlas data is packaged with this version.")
        for _, body in pairs(view.tabs) do body:Hide() end
        UI.SetText(view.missing, Guide.Available() and "Click the title to pick a dungeon." or "The Dungeon Atlas data file is missing.")
        view.missing:Show()
        return
    end
    view.missing:Hide()
    local parts = { dungeon.kind == "raid" and "Raid" or "Dungeon" }
    local levels = Guide.LevelText(dungeon.lmin, dungeon.lmax)
    if levels then table.insert(parts, "Levels " .. levels) end
    if dungeon.zone then table.insert(parts, dungeon.zone) end
    if instanceId == current then table.insert(parts, Theme.Colorize("You are here", "good")) end
    UI.SetText(view.title, dungeon.name)
    pcall(view.pick.SetWidth, view.pick, math.min(CONTENT_WIDTH - 110, (view.title.GetStringWidth and tonumber(view.title:GetStringWidth()) or 200) + 34))
    UI.SetText(view.subtitle, table.concat(parts, "  " .. DOT .. "  "))
    showTab(view, state.tab or "overview")
    local body = view.tabs[state.tab]
    if state.tab == "overview" then refreshOverview(view, body, instanceId, dungeon)
    elseif state.tab == "bosses" then refreshEncounters(view, body, instanceId, dungeon)
    elseif state.tab == "rares" then refreshRares(view, body, instanceId, dungeon)
    elseif state.tab == "loot" then refreshLoot(view, body, instanceId) end
    if started then GW.Perf.End("guide:refresh", started) end
end

-- Registers the view with the dashboard.
local main = GW.MainFrame
if main and main.Views then
    main.Views.guide = { build = buildView, refresh = refreshView }
end

-- Public -----------------------------------------------------------------------------------

function GuideUI.Refresh()
    if main and main.current == "guide" and main.RefreshView then main:RefreshView() end
end

-- Opens the guide on a dungeon (default: the selected one), optionally on
-- a boss (index in the atlas). In combat the dashboard is only shown when it
-- was already built: nothing large is created mid-fight.
function GuideUI.Show(instanceId, bossIndex)
    if not main or not main.Open then return false end
    if inCombat() and not (main.views and main.views.guide) then
        GW.Print("The Dungeon Guide opens out of combat.")
        return false
    end
    instanceId = tonumber(instanceId)
    if instanceId and Guide.Index()[instanceId] then
        state.instanceId = instanceId
        if instanceId ~= Guide.CurrentInstanceId() then Guide.Select(instanceId) end
    else
        state.instanceId = nil
    end
    state.pickerOpen = false
    local shown = state.instanceId or Guide.SelectedInstanceId()
    if state.shownId ~= shown then
        state.shownId = shown
        state.boss, state.rare, state.lootPage, state.listPage, state.trashPage, state.detailPage, state.floor = 1, 1, 1, 1, 1, 1, nil
        state.encounterPage = nil
    end
    if bossIndex then
        state.boss, state.detailPage, state.encounterPage = bossIndex, 1, nil
        state.tab = "bosses"
        prefs().tab = "bosses"
        local boss = Guide.Dungeon(shown) and Guide.Dungeon(shown).bosses[bossIndex]
        local pin = boss and Guide.PinFor(shown, boss)
        if pin then state.floor = pin.floor end
    end
    main:Open("guide")
    if GuideUI.view then showTab(GuideUI.view, state.tab or "overview") end
    GuideUI.Refresh()
    return true
end

-- Leaves the picked dungeon when the player enters another instance (the
-- guide follows the player unless they picked one while inside). Inside a
-- known dungeon, out of combat, its detail is built and its bosses' faces
-- start loading, so the HUD's tooltips and faces are ready in the fight.
function GuideUI.OnInstanceChanged()
    state.instanceId = nil
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
    for _, row in ipairs(Guide.TopMechanics(boss, Guide.Role(), 3)) do table.insert(lines, GuideUI.AbilityText(row)) end
    for _, row in ipairs(Guide.CreatureLoot(boss)) do
        if row.wanted and not row.acquired then
            table.insert(lines, Theme.Colorize("Wishlist: " .. ((row.item and row.item.n) or ("Item " .. row.itemId)), "alertWishlist"))
        end
    end
    if #lines == 0 then return nil end
    table.insert(lines, Theme.Colorize(Guide.REFERENCE_NOTE .. ". Click for the guide.", "textFaint"))
    return lines
end

function GuideUI.OpenForEntry(instanceId, entry)
    local _, index = GuideUI.BossForEntry(instanceId, entry)
    return GuideUI.Show(instanceId, index)
end

-- The expanded HUD's guide line: the next boss's (or the fight's) top two
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
        for _, row in ipairs(Guide.TopMechanics(boss, Guide.Role(), 2)) do
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
