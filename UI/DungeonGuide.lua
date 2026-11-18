local _, GW = ...

-- The Dungeon Guide: a dashboard view (Overview | Bosses | Loot | Rares) and
-- the dungeon HUD's links into it (the Guide button, clickable boss faces,
-- a "next boss" line in the expanded HUD and mechanics in boss tooltips).
--
-- Built on first open, like every dashboard view. Nothing here runs on a
-- timer or OnUpdate: the view repaints when it is shown, when the player
-- picks something, or when the instance changes. Lists are fixed pools of
-- rows with paging instead of scroll frames. The spawn layout's dots are
-- drawn only when the Overview shows a dungeon, out of combat, and reused.
--
-- Wishlists are read-only here: the website is where they are edited.
GW.DungeonGuideUI = GW.DungeonGuideUI or {}

local GuideUI = GW.DungeonGuideUI
local Globals = _G or {}
local UI, Theme = GW.UI, GW.Theme
local Guide = GW.DungeonGuide

local CONTENT_WIDTH = 532
local BODY_TOP = -84
local ROW = 18
local DOT = "\194\183"
local DASH = "\226\128\148"
local DIAMOND = "\226\151\134"
local CHECK = "\226\156\147"
local STAR = "\226\152\133"

local TABS = { { "overview", "Overview" }, { "bosses", "Bosses" }, { "loot", "Loot" }, { "rares", "Rares" } }
local QUALITY = { [0] = "9d9d9d", [1] = "ffffff", [2] = "1eff00", [3] = "0070dd", [4] = "a335ee", [5] = "ff8000" }

local function inCombat()
    if type(Globals.InCombatLockdown) ~= "function" then return false end
    local ok, value = pcall(Globals.InCombatLockdown)
    return ok and value == true
end
GuideUI.InCombat = inCombat

local function prefs()
    return GW.UiPrefs and GW.UiPrefs.Get and GW.UiPrefs.Get("dungeonGuide") or {}
end

local function colorize(text, hex)
    return "|cff" .. hex .. tostring(text) .. "|r"
end

function GuideUI.ItemName(row)
    local item = row.item or {}
    local name = item.n or ("Item " .. row.itemId)
    return colorize(name, QUALITY[item.q or 1] or QUALITY[1])
end

function GuideUI.ItemFacts(item)
    if type(item) ~= "table" then return nil end
    local parts = {}
    if item.s then table.insert(parts, item.s) end
    if item.sc and item.sc ~= item.s then table.insert(parts, item.sc) end
    if item.l then table.insert(parts, "ilvl " .. item.l) end
    if item.r then table.insert(parts, "req " .. item.r) end
    if item.dps then table.insert(parts, item.dps .. " dps") end
    if item.b == "BoE" then table.insert(parts, "BoE") end
    return #parts > 0 and table.concat(parts, " " .. DOT .. " ") or nil
end

-- What a wishlist state looks like in a list: a purple diamond for wanted,
-- a check for acquired.
function GuideUI.WishMark(row)
    if row.acquired then return Theme.Colorize(CHECK, "good") end
    if row.wanted then return Theme.Colorize(DIAMOND, "alertWishlist") end
    return ""
end

-- The client's own item tooltip when it can show one, with what the guide
-- knows underneath.
function GuideUI.ShowItemTooltip(owner, row)
    local tooltip = Globals.GameTooltip
    if not tooltip or type(tooltip.SetOwner) ~= "function" then return end
    pcall(tooltip.SetOwner, tooltip, owner, "ANCHOR_RIGHT")
    local shown = type(tooltip.SetHyperlink) == "function" and pcall(tooltip.SetHyperlink, tooltip, "item:" .. row.itemId)
    if not shown then
        pcall(tooltip.ClearLines, tooltip)
        pcall(tooltip.AddLine, tooltip, (row.item and row.item.n) or ("Item " .. row.itemId), 1, 1, 1)
        local facts = GuideUI.ItemFacts(row.item)
        if facts then pcall(tooltip.AddLine, tooltip, facts, 0.8, 0.8, 0.8, true) end
    end
    local muted = Theme.colors.textMuted
    if row.from then pcall(tooltip.AddLine, tooltip, "Drops from " .. row.from, muted[1], muted[2], muted[3]) end
    if row.item and row.item.set then pcall(tooltip.AddLine, tooltip, "Set: " .. row.item.set, muted[1], muted[2], muted[3]) end
    if row.acquired then
        local good = Theme.colors.good
        pcall(tooltip.AddLine, tooltip, "On your wishlist " .. DASH .. " acquired", good[1], good[2], good[3])
    elseif row.wanted then
        local wish = Theme.colors.alertWishlist
        pcall(tooltip.AddLine, tooltip, "On your wishlist (" .. tostring(row.wanted.priority) .. ")" .. (row.wanted.note and row.wanted.note ~= "" and (": " .. row.wanted.note) or ""),
            wish[1], wish[2], wish[3], true)
    end
    if row.kind ~= "wishlist" then
        local faint = Theme.colors.textFaint
        pcall(tooltip.AddLine, tooltip, "Reference loot: " .. Guide.REFERENCE_NOTE .. ". Drop chances not shown.", faint[1], faint[2], faint[3], true)
    end
    pcall(tooltip.Show, tooltip)
end

-- Ability lines for tooltips and the HUD.
function GuideUI.AbilityText(row)
    local color = Guide.LABEL_COLORS[row.label] or "textMuted"
    return Theme.Colorize(row.label, color) .. "  " .. tostring(row.spell.n) .. (row.spell.s and Theme.Colorize("  " .. row.spell.s, "textFaint") or "")
end

-- Widgets ------------------------------------------------------------------------------

-- A list row: a mark, a left text and a right text. Clickable when onClick.
local function listRow(parent, width, onClick)
    local row = UI.CreateFrame("Button", parent)
    row:SetSize(width, ROW)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints(row)
    Theme.Fill(row.bg, "bgActive")
    row.bg:Hide()
    row.mark = UI.Text(row, "label", "text", "CENTER")
    row.mark:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.mark:SetWidth(14)
    row.left = UI.Text(row, "label", "text")
    row.left:SetPoint("LEFT", row, "LEFT", 16, 0)
    row.right = UI.Text(row, "small", "textMuted", "RIGHT")
    row.right:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.left:SetPoint("RIGHT", row.right, "LEFT", -6, 0)
    pcall(row.left.SetWordWrap, row.left, false)
    pcall(row.right.SetWordWrap, row.right, false)
    pcall(row.RegisterForClicks, row, "LeftButtonUp")
    row:SetScript("OnClick", function(self) if onClick and self.gwData then onClick(self.gwData, self) end end)
    row:SetScript("OnEnter", function(self) if self.gwEnter and self.gwData then self.gwEnter(self, self.gwData) end end)
    row:SetScript("OnLeave", UI.HideTooltip)
    function row:Fill(data, mark, left, right, selected, onEnter)
        self.gwData, self.gwEnter = data, onEnter
        UI.SetText(self.mark, mark or "")
        UI.SetText(self.left, left or "")
        UI.SetText(self.right, right or "")
        UI.SetShown(self.bg, selected == true)
        self:Show()
    end
    function row:Clear()
        self.gwData, self.gwEnter = nil, nil
        self:Hide()
    end
    return row
end

local function rows(parent, count, width, onClick, top, left)
    local list = {}
    for index = 1, count do
        local row = listRow(parent, width, onClick)
        row:SetPoint("TOPLEFT", parent, "TOPLEFT", left or 0, top - (index - 1) * ROW)
        list[index] = row
    end
    return list
end

local function emptyText(parent, width)
    local text = UI.Text(parent, "label", "textFaint")
    text:SetWidth(width)
    pcall(text.SetWordWrap, text, true)
    pcall(text.SetJustifyV, text, "TOP")
    return text
end

local function pager(parent, onPage)
    local frame = UI.CreateFrame("Frame", parent)
    frame:SetSize(96, 20)
    frame.prev = UI.Button(frame, "\226\128\185", { width = 22, height = 20, variant = "ghost", onClick = function() onPage(-1) end })
    frame.prev:SetPoint("LEFT", frame, "LEFT", 0, 0)
    frame.label = UI.Text(frame, "small", "textMuted", "CENTER")
    frame.label:SetPoint("LEFT", frame.prev, "RIGHT", 2, 0)
    frame.label:SetWidth(48)
    frame.next = UI.Button(frame, "\226\128\186", { width = 22, height = 20, variant = "ghost", onClick = function() onPage(1) end })
    frame.next:SetPoint("LEFT", frame.label, "RIGHT", 2, 0)
    function frame:Set(page, pages)
        UI.SetShown(self, pages > 1)
        UI.SetText(self.label, page .. "/" .. pages)
        self.prev:SetEnabled(page > 1)
        self.next:SetEnabled(page < pages)
    end
    return frame
end

-- Detail panel: a creature's name, facts, its priority mechanics (2-4),
-- every ability on demand, and its loot. Used by Bosses and Rares.
local DETAIL_ABILITIES, DETAIL_LOOT = 12, 6

local function detailPanel(view, parent, width)
    local panel = UI.CreateFrame("Frame", parent)
    panel:SetSize(width, 330)
    panel.portrait = panel:CreateTexture(nil, "ARTWORK")
    panel.portrait:SetSize(36, 36)
    panel.portrait:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    panel.portrait:Hide()
    panel.name = UI.Text(panel, "title", "goldBright")
    panel.name:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -2)
    panel.name:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
    pcall(panel.name.SetWordWrap, panel.name, false)
    panel.facts = UI.Text(panel, "small", "textFaint")
    panel.facts:SetPoint("TOPLEFT", panel.name, "BOTTOMLEFT", 0, -3)
    panel.facts:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
    pcall(panel.facts.SetWordWrap, panel.facts, false)
    panel.mechanicsHeader = UI.SectionHeader(panel, "Watch for")
    panel.mechanicsHeader:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -42)
    panel.mechanicsHeader:SetWidth(width)
    panel.toggle = UI.Button(panel, "All", { width = 74, height = 18, variant = "ghost", role = "small", onClick = function()
        view.showAll = not view.showAll
        GuideUI.Refresh()
    end })
    panel.toggle:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, -40)
    panel.abilities = {}
    for index = 1, DETAIL_ABILITIES do
        local line = UI.Text(panel, "label", "text")
        line:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -66 - (index - 1) * ROW)
        line:SetWidth(width)
        pcall(line.SetWordWrap, line, false)
        panel.abilities[index] = line
    end
    panel.lootHeader = UI.SectionHeader(panel, "Loot")
    panel.lootHeader:SetWidth(width)
    panel.lootRows = rows(panel, DETAIL_LOOT, width, nil, 0)
    panel.note = UI.Text(panel, "small", "textFaint")
    panel.note:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 0)
    panel.note:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
    pcall(panel.note.SetWordWrap, panel.note, false)
    panel.empty = emptyText(panel, width)
    panel.empty:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -66)
    return panel
end

local function displayIdFor(instanceId, creature)
    if not creature or not creature.e then return nil end
    local registry = GW.DungeonBosses
    local displayId = registry and registry.DisplayId and registry.DisplayId(instanceId, creature.e, creature.name) or nil
    if displayId then return displayId end
    -- What the HUD already read from the client's journal (never read here).
    local hud = GW.DungeonHud
    local journal = hud and hud.journal and hud.journal[instanceId]
    for _, boss in ipairs(type(journal) == "table" and journal or {}) do
        if boss.encounterId == creature.e and boss.displayId then return boss.displayId end
    end
    return nil
end

local function paintDetail(view, panel, instanceId, creature, kind)
    if not creature then
        panel:Hide()
        return
    end
    panel:Show()
    local displayId = kind == "boss" and displayIdFor(instanceId, creature) or nil
    local hasPortrait = displayId and type(Globals.SetPortraitTextureFromCreatureDisplayID) == "function"
        and pcall(Globals.SetPortraitTextureFromCreatureDisplayID, panel.portrait, displayId)
    UI.SetShown(panel.portrait, hasPortrait)
    panel.name:ClearAllPoints()
    panel.name:SetPoint("TOPLEFT", panel, "TOPLEFT", hasPortrait and 44 or 0, -2)
    panel.name:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
    UI.SetText(panel.name, creature.name)
    local facts = {}
    local levels = Guide.LevelText(creature.lmin, creature.lmax)
    if kind == "rare" then table.insert(facts, creature.elite and "Rare elite" or "Rare") end
    if kind == "trash" then table.insert(facts, "Dangerous trash" .. (creature.n and creature.n > 1 and (" \195\151" .. creature.n) or "")) end
    if levels then table.insert(facts, "Level " .. levels) end
    if creature.e then table.insert(facts, "Encounter " .. creature.e) end
    if creature.npc then table.insert(facts, "NPC " .. creature.npc) end
    if creature.x then table.insert(facts, "on the layout") end
    UI.SetText(panel.facts, table.concat(facts, "  " .. DOT .. "  "))

    local role = Guide.Role()
    local top, total = Guide.TopMechanics(creature, role, 4)
    local list = view.showAll and Guide.Abilities(creature) or top
    panel.mechanicsHeader:SetTitle(view.showAll and ("All abilities (" .. total .. ")") or ("Watch for" .. (role and (" " .. DASH .. " " .. role) or "")))
    UI.SetShown(panel.toggle, total > #top or view.showAll)
    panel.toggle:SetLabel(view.showAll and "Top only" or ("All " .. total))
    for index, line in ipairs(panel.abilities) do
        local row = list[index]
        if row then
            UI.SetText(line, GuideUI.AbilityText(row))
            line:Show()
        else
            line:Hide()
        end
    end
    UI.SetText(panel.empty, total == 0 and "No abilities in the atlas for this creature. That does not mean it has none." or "")
    UI.SetShown(panel.empty, total == 0)

    local shownAbilities = math.max(#list, total == 0 and 2 or 0)
    local lootTop = -66 - shownAbilities * ROW - 10
    local loot = Guide.CreatureLoot(creature)
    local roomForLoot = not view.showAll or #list <= 5
    panel.lootHeader:ClearAllPoints()
    panel.lootHeader:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, lootTop)
    UI.SetShown(panel.lootHeader, roomForLoot and kind ~= "trash")
    panel.lootHeader:SetTitle("Loot" .. (#loot > 0 and (" (" .. #loot .. ")") or ""))
    for index, rowFrame in ipairs(panel.lootRows) do
        local row = loot[index]
        rowFrame:ClearAllPoints()
        rowFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, lootTop - 24 - (index - 1) * ROW)
        if row and roomForLoot and kind ~= "trash" and index <= math.floor((lootTop + 300) / ROW) then
            row.from = creature.name
            local right = GuideUI.ItemFacts(row.item)
            if index == DETAIL_LOOT and #loot > DETAIL_LOOT then right = "+" .. (#loot - DETAIL_LOOT + 1) .. " more on the Loot tab" end
            rowFrame:Fill(row, GuideUI.WishMark(row), GuideUI.ItemName(row), right, row.wanted and not row.acquired, GuideUI.ShowItemTooltip)
        else
            rowFrame:Clear()
        end
    end
    if roomForLoot and kind ~= "trash" and #loot == 0 then
        panel.lootRows[1]:Fill({ none = true }, "", Theme.Colorize("No reference loot listed.", "textFaint"), "")
    end
    local verified = false
    for _, row in ipairs(Guide.Abilities(creature)) do
        if Guide.IsVerified(row.spell) then verified = true end
    end
    UI.SetText(panel.note, verified and "Some entries verified on Forever." or Guide.REFERENCE_NOTE)
end

-- The spawn layout: a site-drawn picture of where creatures stand, not an
-- in-game map. Dots are a pooled set of textures, reused per dungeon.
local MAP_WIDTH, MAP_HEIGHT = 238, 190

local function layoutFrame(parent, onMarker)
    local frame = UI.CreateFrame("Frame", parent)
    frame:SetSize(MAP_WIDTH, MAP_HEIGHT)
    Theme.Skin(frame, "bgInset", "border")
    frame.dots = {}
    frame.markers = {}
    frame.caption = UI.Text(parent, "small", "textFaint")
    frame.caption:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -4)
    frame.caption:SetWidth(MAP_WIDTH)
    pcall(frame.caption.SetWordWrap, frame.caption, true)
    frame.caption:SetText("Spawn layout: creature positions, north up. Not an in-game map; floors overlap. Classic reference.")
    function frame:Marker(index)
        local marker = self.markers[index]
        if not marker then
            marker = UI.CreateFrame("Button", self)
            marker:SetSize(14, 14)
            Theme.Skin(marker, "bgRaised", "gold")
            marker.text = UI.Text(marker, "small", "goldBright", "CENTER")
            marker.text:SetPoint("CENTER", marker, "CENTER", 0, 0)
            pcall(marker.RegisterForClicks, marker, "LeftButtonUp")
            marker:SetScript("OnClick", function(current) if current.gwData then onMarker(current.gwData) end end)
            marker:SetScript("OnEnter", function(current)
                if current.gwData then UI.ShowTooltip(current, current.gwData.name, { current.gwData.kind == "rare" and "Rare" or "Boss" }, "ANCHOR_TOP") end
            end)
            marker:SetScript("OnLeave", UI.HideTooltip)
            self.markers[index] = marker
        end
        return marker
    end
    return frame
end

local function drawLayout(frame, instanceId, selected)
    local dungeon = Guide.Dungeon(instanceId)
    local layout = dungeon and dungeon.layout
    if not layout then
        frame:Hide()
        frame.caption:Hide()
        frame.drawn = nil
        return false
    end
    frame:Show()
    frame.caption:Show()
    -- Fit the layout's aspect ratio into the box.
    local aspect = (layout.w > 0 and layout.h > 0) and (layout.w / layout.h) or 1.5
    local width, height = MAP_WIDTH - 8, (MAP_WIDTH - 8) / aspect
    if height > MAP_HEIGHT - 8 then
        height = MAP_HEIGHT - 8
        width = height * aspect
    end
    local left, top = (MAP_WIDTH - width) / 2, -(MAP_HEIGHT - height) / 2
    if frame.drawn ~= instanceId then
        if GW.Perf and GW.Perf.Begin then frame.perfStarted = GW.Perf.Begin() end
        local points = Guide.LayoutPoints(instanceId)
        for index, point in ipairs(points) do
            local dot = frame.dots[index]
            if not dot then
                dot = frame:CreateTexture(nil, "ARTWORK")
                dot:SetSize(2, 2)
                Theme.Fill(dot, "textMuted", 0.55)
                frame.dots[index] = dot
            end
            dot:ClearAllPoints()
            dot:SetPoint("TOPLEFT", frame, "TOPLEFT", left + point[1] * width - 1, top - point[2] * height + 1)
            dot:Show()
        end
        for index = #points + 1, #frame.dots do frame.dots[index]:Hide() end
        frame.drawn = instanceId
        if frame.perfStarted then GW.Perf.End("guide:layout", frame.perfStarted) end
    end
    local count = 0
    local function place(creature, label, kind, index)
        if not creature.x or not creature.y then return end
        count = count + 1
        local marker = frame:Marker(count)
        marker.gwData = { name = creature.name, kind = kind, index = index }
        UI.SetText(marker.text, label)
        Theme.SetBorder(marker, (selected == creature) and "goldBright" or (kind == "rare" and "alertBoe" or "gold"))
        Theme.SetBackground(marker, (selected == creature) and "bgActive" or "bgRaised")
        marker:ClearAllPoints()
        marker:SetPoint("CENTER", frame, "TOPLEFT", left + creature.x / 1000 * width, top - creature.y / 1000 * height)
        marker:Show()
    end
    for index, boss in ipairs(dungeon.bosses) do place(boss, tostring(index), "boss", index) end
    for index, rare in ipairs(dungeon.rares) do place(rare, STAR, "rare", index) end
    for index = count + 1, #frame.markers do
        frame.markers[index].gwData = nil
        frame.markers[index]:Hide()
    end
    return true
end
GuideUI.DrawLayout = drawLayout

-- The view ----------------------------------------------------------------------------

local LIST_WIDTH, DETAIL_LEFT = 168, 184
local DETAIL_WIDTH = CONTENT_WIDTH - DETAIL_LEFT
local LIST_ROWS = 17
local LOOT_ROWS = 15
local QUEST_ROWS = 7

local state = { tab = nil, boss = 1, rare = 1, lootPage = 1, lootFilter = "all", listPage = 1 }
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

local function dungeonMenu(anchor)
    local list = Guide.List()
    local current = Guide.CurrentInstanceId()
    local bands = {
        { "Dungeons, levels 10\226\128\14729", function(d) return d.kind ~= "raid" and (d.lmin or 0) < 30 end },
        { "Dungeons, levels 30\226\128\14749", function(d) return d.kind ~= "raid" and (d.lmin or 0) >= 30 and (d.lmin or 0) < 50 end },
        { "Dungeons, levels 50+", function(d) return d.kind ~= "raid" and (d.lmin or 0) >= 50 end },
        { "Raids", function(d) return d.kind == "raid" end },
    }
    local items = {}
    if current then
        table.insert(items, { text = "Where I am: " .. tostring(Guide.Index()[current].name), onClick = function()
            Guide.FollowCurrent()
            GuideUI.Show(current)
        end })
        table.insert(items, { separator = true })
    end
    local shown = selectedId()
    for _, band in ipairs(bands) do
        table.insert(items, { text = band[1], onClick = function()
            local sub = {}
            for _, dungeon in ipairs(list) do
                if band[2](dungeon) then
                    table.insert(sub, { text = dungeon.name .. "  " .. Theme.Colorize(Guide.LevelText(dungeon.lmin, dungeon.lmax) or "", "textFaint"),
                        checked = dungeon.id == shown, onClick = function()
                            Guide.Select(dungeon.id)
                            GuideUI.Show(dungeon.id)
                        end })
                end
            end
            UI.ShowMenu(anchor, sub)
        end })
    end
    UI.ShowMenu(anchor, items)
end

local function buildOverview(view, body)
    local columnWidth = CONTENT_WIDTH - MAP_WIDTH - 20
    local glance = UI.SectionHeader(body, "At a glance")
    glance:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    glance:SetWidth(columnWidth)
    body.glance = {}
    for index = 1, 4 do
        local line = UI.Text(body, "label", "text")
        line:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -26 - (index - 1) * ROW)
        line:SetWidth(columnWidth)
        pcall(line.SetWordWrap, line, false)
        body.glance[index] = line
    end
    local quests = UI.SectionHeader(body, "Quests")
    quests:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -110)
    quests:SetWidth(columnWidth)
    body.questHeader = quests
    body.questRows = rows(body, QUEST_ROWS, columnWidth, nil, -136)
    body.questEmpty = emptyText(body, columnWidth)
    body.questEmpty:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -136)
    local layoutHeader = UI.SectionHeader(body, "Spawn layout")
    layoutHeader:SetPoint("TOPLEFT", body, "TOPLEFT", columnWidth + 20, 0)
    layoutHeader:SetWidth(MAP_WIDTH)
    body.layout = layoutFrame(body, function(data)
        if data.kind == "rare" then
            state.rare = data.index
            showTab(view, "rares")
        else
            state.boss = data.index
            showTab(view, "bosses")
        end
        GuideUI.Refresh()
    end)
    body.layout:SetPoint("TOPLEFT", body, "TOPLEFT", columnWidth + 20, -26)
    body.layoutEmpty = emptyText(body, MAP_WIDTH)
    body.layoutEmpty:SetPoint("TOPLEFT", body, "TOPLEFT", columnWidth + 20, -26)
end

local function questTooltip(owner, quest)
    local lines = {}
    if quest.obj then table.insert(lines, quest.obj) end
    if quest.giver then table.insert(lines, "From " .. quest.giver .. (quest.where and (", " .. quest.where .. (quest.x and (" " .. Guide.Coordinates(quest.x, quest.y)) or "")) or "")) end
    if quest.inside then table.insert(lines, "Starts inside the dungeon.") end
    if quest.pre then table.insert(lines, "After: " .. table.concat(quest.pre, ", ")) end
    if quest.rew then
        local names = {}
        for _, itemId in ipairs(quest.rew) do
            local item = Guide.Item(itemId)
            local wanted = Guide.Wanted(itemId)
            table.insert(names, ((item and item.n) or ("Item " .. itemId)) .. (wanted and (" " .. DIAMOND) or ""))
        end
        table.insert(lines, (quest.choice and "Choose one: " or "Rewards: ") .. table.concat(names, ", "))
    end
    table.insert(lines, Guide.REFERENCE_NOTE)
    UI.ShowTooltip(owner, quest.name, lines)
end

local function refreshOverview(_, body, instanceId, dungeon)
    local entry = Guide.Index()[instanceId] or {}
    local wanted = Guide.WantedCount(instanceId)
    local lootRows = Guide.LootRows(instanceId)
    local glance = {
        (#dungeon.bosses .. " bosses  " .. DOT .. "  " .. #dungeon.rares .. " rares  " .. DOT .. "  " .. #dungeon.trash .. " dangerous trash"),
        (#lootRows > 0 and (#lootRows .. " reference items") or "No reference loot listed"),
        (wanted > 0 and Theme.Colorize(DIAMOND .. " " .. wanted .. (wanted == 1 and " wishlist item drops here" or " wishlist items drop here"), "alertWishlist")
            or Theme.Colorize("No wishlist items from here", "textFaint")),
        (dungeon.entrance and ("Entrance: " .. tostring(entry.zone or dungeon.zone or "?") .. " " .. Guide.Coordinates(dungeon.entrance.x, dungeon.entrance.y))
            or Theme.Colorize("Entrance not known", "textFaint")),
    }
    for index, line in ipairs(body.glance) do UI.SetText(line, glance[index] or "") end

    local quests = Guide.Quests(instanceId)
    body.questHeader:SetTitle("Quests" .. (#quests > 0 and (" (" .. #quests .. ")") or ""))
    for index, rowFrame in ipairs(body.questRows) do
        local quest = quests[index]
        if quest and index < QUEST_ROWS then
            local reward = quest.rew and Theme.Colorize("reward", "textMuted") or ""
            rowFrame:Fill(quest, quest.lvl and Theme.Colorize(tostring(quest.lvl), "textFaint") or "", quest.name, reward, false, questTooltip)
        elseif quest and index == QUEST_ROWS then
            rowFrame:Fill({ more = true }, "", Theme.Colorize("+" .. (#quests - QUEST_ROWS + 1) .. " more", "textFaint"), "")
        else
            rowFrame:Clear()
        end
    end
    UI.SetText(body.questEmpty, #quests == 0 and "No dungeon quests in the atlas for your faction." or "")
    UI.SetShown(body.questEmpty, #quests == 0)

    if inCombat() and body.layout.drawn ~= instanceId then
        -- Drawing hundreds of dots waits for the end of the fight.
        body.layout:Hide()
        body.layout.caption:Hide()
        UI.SetText(body.layoutEmpty, "The layout draws after combat.")
        body.layoutEmpty:Show()
        GuideUI.pending = true
        return
    end
    local drawn = drawLayout(body.layout, instanceId, nil)
    UI.SetText(body.layoutEmpty, drawn and "" or "No spawn layout for this dungeon.")
    UI.SetShown(body.layoutEmpty, not drawn)
end

local function buildCreatureTab(view, body, kind)
    body.list = rows(body, LIST_ROWS, LIST_WIDTH, function(data)
        if kind == "bosses" then state.boss = data.index else state.rare = data.index end
        view.showAll = false
        GuideUI.Refresh()
    end, 0)
    body.listEmpty = emptyText(body, LIST_WIDTH)
    body.listEmpty:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    body.detail = detailPanel(view, body, DETAIL_WIDTH)
    body.detail:SetPoint("TOPLEFT", body, "TOPLEFT", DETAIL_LEFT, 0)
end

local function refreshBosses(view, body, instanceId, dungeon)
    local selected = math.max(1, math.min(state.boss or 1, #dungeon.bosses))
    for index, rowFrame in ipairs(body.list) do
        local boss = dungeon.bosses[index]
        if boss then
            local mark = Guide.HasWantedLoot(boss) and Theme.Colorize(DIAMOND, "alertWishlist") or Theme.Colorize(tostring(index), "textFaint")
            local kicks = 0
            for _, row in ipairs(Guide.Abilities(boss)) do if row.label == "KICK" then kicks = kicks + 1 end end
            rowFrame:Fill({ index = index }, mark, boss.name, kicks > 0 and Theme.Colorize("KICK", "info") or "", index == selected)
        else
            rowFrame:Clear()
        end
    end
    UI.SetText(body.listEmpty, #dungeon.bosses == 0 and "No bosses in the atlas for this dungeon." or "")
    UI.SetShown(body.listEmpty, #dungeon.bosses == 0)
    paintDetail(view, body.detail, instanceId, dungeon.bosses[selected], "boss")
end

-- Rares first, then dangerous trash, in one list.
local function rareEntries(dungeon)
    local list = {}
    for _, rare in ipairs(dungeon.rares) do table.insert(list, { creature = rare, kind = "rare" }) end
    for _, creature in ipairs(dungeon.trash) do table.insert(list, { creature = creature, kind = "trash" }) end
    return list
end

local function refreshRares(view, body, instanceId, dungeon)
    local list = rareEntries(dungeon)
    local selected = math.max(1, math.min(state.rare or 1, #list))
    local shownRare = false
    for index, rowFrame in ipairs(body.list) do
        local entry = list[index]
        if entry then
            local mark = entry.kind == "rare" and Theme.Colorize(STAR, "alertBoe") or Theme.Colorize("!", "warn")
            if entry.kind == "rare" then shownRare = true end
            local right = Guide.LevelText(entry.creature.lmin, entry.creature.lmax) or ""
            rowFrame:Fill({ index = index }, mark, entry.creature.name, right, index == selected)
        else
            rowFrame:Clear()
        end
    end
    local text = ""
    if #list == 0 then text = "No rares or dangerous trash in the atlas for this dungeon." end
    UI.SetText(body.listEmpty, text)
    UI.SetShown(body.listEmpty, #list == 0)
    local entry = list[selected]
    paintDetail(view, body.detail, instanceId, entry and entry.creature, entry and (entry.kind == "rare" and "rare" or "trash"))
    return shownRare
end

local function buildLoot(view, body)
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
    body.pager:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, 0)
    body.status = UI.Text(body, "small", "textFaint")
    body.status:SetPoint("LEFT", body.filter, "RIGHT", 12, 0)
    body.rows = rows(body, LOOT_ROWS, CONTENT_WIDTH, function(data)
        if data.bossIndex then
            state.boss = data.bossIndex
            showTab(view, "bosses")
            GuideUI.Refresh()
        end
    end, -28)
    body.empty = emptyText(body, CONTENT_WIDTH)
    body.empty:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -30)
    body.note = UI.Text(body, "small", "textFaint")
    body.note:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0)
    body.note:SetText("Reference loot, " .. Guide.REFERENCE_NOTE .. ". No drop chances. Your wishlist is edited on the website.")
end

local function refreshLoot(_, body, instanceId)
    local all = Guide.LootRows(instanceId)
    local list = {}
    for _, row in ipairs(all) do
        if state.lootFilter ~= "wanted" or row.wanted then table.insert(list, row) end
    end
    local pages = math.max(1, math.ceil(#list / LOOT_ROWS))
    state.lootPage = math.max(1, math.min(state.lootPage, pages))
    body.pager:Set(state.lootPage, pages)
    body.filter:Refresh()
    local loot = GW.LootSync
    local status = loot and loot.Status and loot.Status() or {}
    UI.SetText(body.status, status.matched and ("Wishlist: " .. tostring(status.characterName)) or "No website wishlist for this character")
    for index, rowFrame in ipairs(body.rows) do
        local row = list[(state.lootPage - 1) * LOOT_ROWS + index]
        if row then
            local facts = GuideUI.ItemFacts(row.item)
            local from = row.from or (row.kind == "wishlist" and "wishlist source" or nil)
            local right = table.concat({ facts or "", from and Theme.Colorize(from, "textFaint") or "" }, (facts and from) and ("  " .. DOT .. "  ") or "")
            rowFrame:Fill(row, GuideUI.WishMark(row), GuideUI.ItemName(row), right, row.wanted and not row.acquired, GuideUI.ShowItemTooltip)
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

local function buildView(view)
    GuideUI.view = view
    view.title = UI.Text(view, "pageTitle", "goldBright")
    view.title:SetPoint("TOPLEFT", view, "TOPLEFT", 0, 0)
    view.title:SetWidth(CONTENT_WIDTH - 200)
    pcall(view.title.SetWordWrap, view.title, false)
    view.subtitle = UI.Text(view, "label", "textMuted")
    view.subtitle:SetPoint("TOPLEFT", view.title, "BOTTOMLEFT", 0, -6)
    view.subtitle:SetWidth(CONTENT_WIDTH - 200)
    pcall(view.subtitle.SetWordWrap, view.subtitle, false)
    view.pick = UI.Button(view, "Dungeon \226\150\190", { width = 96, height = 22, onClick = function(button) dungeonMenu(button) end })
    view.pick:SetPoint("TOPRIGHT", view, "TOPRIGHT", 0, 0)
    view.role = UI.Segmented(view, { { "auto", "Any" }, { "tank", "Tank" }, { "healer", "Heal" }, { "dps", "DPS" } },
        function() return prefs().role or "auto" end,
        function(value)
            prefs().role = value
            GuideUI.Refresh()
        end, { segmentWidth = 44, height = 20 })
    view.role:SetPoint("TOPRIGHT", view.pick, "BOTTOMRIGHT", 0, -8)
    view.tabBar = UI.Segmented(view, TABS, function() return state.tab end, function(value)
        showTab(view, value)
        GuideUI.Refresh()
    end, { segmentWidth = 82, height = 22 })
    view.tabBar:SetPoint("TOPLEFT", view, "TOPLEFT", 0, -54)
    view.tabs = {}
    for _, tab in ipairs(TABS) do
        local body = UI.CreateFrame("Frame", view)
        body:SetPoint("TOPLEFT", view, "TOPLEFT", 0, BODY_TOP)
        body:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", 0, 0)
        body:Hide()
        view.tabs[tab[1]] = body
    end
    buildOverview(view, view.tabs.overview)
    buildCreatureTab(view, view.tabs.bosses, "bosses")
    buildCreatureTab(view, view.tabs.rares, "rares")
    buildLoot(view, view.tabs.loot)
    view.missing = emptyText(view, CONTENT_WIDTH)
    view.missing:SetPoint("TOPLEFT", view, "TOPLEFT", 0, BODY_TOP)
    showTab(view, state.tab or prefs().tab or "overview")
end

local function refreshView(view)
    local started = GW.Perf and GW.Perf.Begin and GW.Perf.Begin()
    local instanceId = selectedId()
    local dungeon = instanceId and Guide.Dungeon(instanceId)
    if state.shownId ~= instanceId then
        state.shownId = instanceId
        state.boss, state.rare, state.lootPage, view.showAll = 1, 1, 1, false
    end
    view.role:Refresh()
    if not dungeon then
        UI.SetText(view.title, "Dungeon Guide")
        UI.SetText(view.subtitle, Guide.Available() and "Pick a dungeon." or "No atlas data is packaged with this version.")
        for _, body in pairs(view.tabs) do body:Hide() end
        UI.SetText(view.missing, Guide.Available() and "Pick a dungeon with the button on the right." or "The Dungeon Atlas data file is missing.")
        view.missing:Show()
        return
    end
    view.missing:Hide()
    local parts = { dungeon.kind == "raid" and "Raid" or "Dungeon" }
    local levels = Guide.LevelText(dungeon.lmin, dungeon.lmax)
    if levels then table.insert(parts, "Levels " .. levels) end
    if dungeon.zone then table.insert(parts, dungeon.zone) end
    if instanceId == Guide.CurrentInstanceId() then table.insert(parts, Theme.Colorize("You are here", "good")) end
    UI.SetText(view.title, dungeon.name)
    UI.SetText(view.subtitle, table.concat(parts, "  " .. DOT .. "  "))
    showTab(view, state.tab or "overview")
    local body = view.tabs[state.tab]
    if state.tab == "overview" then refreshOverview(view, body, instanceId, dungeon)
    elseif state.tab == "bosses" then refreshBosses(view, body, instanceId, dungeon)
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
    if state.shownId ~= (state.instanceId or Guide.SelectedInstanceId()) then
        state.shownId = state.instanceId or Guide.SelectedInstanceId()
        state.boss, state.rare, state.lootPage = 1, 1, 1
    end
    if bossIndex then
        state.boss = bossIndex
        state.tab = "bosses"
        prefs().tab = "bosses"
    end
    main:Open("guide")
    if GuideUI.view then showTab(GuideUI.view, state.tab or "overview") end
    GuideUI.Refresh()
    return true
end

-- Leaves the picked dungeon when the player enters another instance (the
-- guide follows the player unless they picked one while inside).
function GuideUI.OnInstanceChanged()
    state.instanceId = nil
    GuideUI.Refresh()
end

function GuideUI.OnCombatEnded()
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

-- Lines for a HUD face's tooltip: the boss's top mechanics and wanted loot.
function GuideUI.TooltipLines(instanceId, entry)
    local boss = GuideUI.BossForEntry(instanceId, entry)
    if not boss then return nil end
    local lines = {}
    for _, row in ipairs(Guide.TopMechanics(boss, Guide.Role(), 3)) do table.insert(lines, GuideUI.AbilityText(row)) end
    for _, row in ipairs(Guide.CreatureLoot(boss)) do
        if row.wanted and not row.acquired then
            table.insert(lines, Theme.Colorize(DIAMOND .. " " .. ((row.item and row.item.n) or ("Item " .. row.itemId)), "alertWishlist"))
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
    frame.title = UI.Text(frame, "small", "gold")
    frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    frame.title:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
    pcall(frame.title.SetWordWrap, frame.title, false)
    frame.line = UI.Text(frame, "small", "text")
    frame.line:SetPoint("TOPLEFT", frame.title, "BOTTOMLEFT", 0, -3)
    frame.line:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
    pcall(frame.line.SetWordWrap, frame.line, false)
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

-- Events: instance changes and the end of combat. Registered once at load;
-- the handlers only touch an open window.
local events = type(Globals.CreateFrame) == "function" and Globals.CreateFrame("Frame") or nil
if events then
    events:RegisterEvent("PLAYER_ENTERING_WORLD")
    events:RegisterEvent("PLAYER_REGEN_ENABLED")
    events:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_ENABLED" then
            GuideUI.OnCombatEnded()
        else
            GuideUI.OnInstanceChanged()
        end
    end)
    GuideUI.events = events
end
