local _, GW = ...

-- A dungeon's map from the client's own art: Blizzard's dungeon map of each
-- floor, 12 tiles of 256 px in 4 columns by 3 rows, of which the picture is
-- the top-left 1002 x 668 px (the last column shows 234 px, the last row
-- 156). The tiles are texture file IDs (GW.DungeonGuide.Floors); nothing is
-- bundled. Bosses are pinned only where Blizzard's journal placed them
-- (GW.DungeonGuide.Pins); everyone else stays in the encounter list.
--
-- One map per view, built on first use. The 12 tiles and the pins are
-- reused; a floor's textures are set only when the floor changes, never in
-- combat (the caller is told "deferred" and redraws after combat).
GW.DungeonMap = GW.DungeonMap or {}

local DungeonMap = GW.DungeonMap
local Globals = _G or {}
local UI, Theme = GW.UI, GW.Theme
local Guide = GW.DungeonGuide

DungeonMap.PICTURE_W, DungeonMap.PICTURE_H = 1002, 668
DungeonMap.ASPECT = 1002 / 668
DungeonMap.PREV = "Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up"
DungeonMap.NEXT = "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up"
local PIN = 22

-- A frame's level as a number (0 where the client gives none).
function DungeonMap.FrameLevel(frame)
    local ok, level = pcall(frame.GetFrameLevel, frame)
    return ok and tonumber(level) or 0
end

local function inCombat()
    if type(Globals.InCombatLockdown) ~= "function" then return false end
    local ok, value = pcall(Globals.InCombatLockdown)
    return ok and value == true
end

-- Where each of the 12 tiles goes in a map `width` wide: { x, y, w, h, u, v }
-- (u, v: how much of the tile's texture to show).
function DungeonMap.TileLayout(width)
    local scale = width / DungeonMap.PICTURE_W
    local tiles = {}
    for row = 0, 2 do
        for column = 0, 3 do
            local u = column == 3 and (234 / 256) or 1
            local v = row == 2 and (156 / 256) or 1
            table.insert(tiles, { x = column * 256 * scale, y = row * 256 * scale, w = 256 * u * scale, h = 256 * v * scale, u = u, v = v })
        end
    end
    return tiles
end

-- A page arrow from the client's spellbook buttons.
local function arrow(parent, texture, onClick)
    local button = UI.CreateFrame("Button", parent)
    button:SetSize(22, 22)
    pcall(button.SetNormalTexture, button, texture)
    pcall(button.SetPushedTexture, button, (texture:gsub("%-Up$", "-Down")))
    pcall(button.SetDisabledTexture, button, (texture:gsub("%-Up$", "-Disabled")))
    pcall(button.SetHighlightTexture, button, "Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    pcall(button.RegisterForClicks, button, "LeftButtonUp")
    button:SetScript("OnClick", function() if button.gwEnabled ~= false then onClick() end end)
    function button:SetActive(enabled)
        self.gwEnabled = enabled
        if enabled then pcall(self.Enable, self) else pcall(self.Disable, self) end
    end
    return button
end
DungeonMap.Arrow = arrow

-- New map. opts.onPin(pin) on a click, opts.onPinEnter(pin, frame) for its
-- tooltip, opts.onFloor(floor) when the player turns the floor.
function DungeonMap.New(parent, width, opts)
    opts = opts or {}
    local height = math.floor(width / DungeonMap.ASPECT + 0.5)
    local map = UI.CreateFrame("Frame", parent)
    map:SetSize(width + 2, height + 2)
    Theme.Skin(map, "bgInset", "borderGold", 0.6)
    map.gwWidth, map.gwHeight = width, height
    map.canvas = UI.CreateFrame("Frame", map)
    map.canvas:SetPoint("TOPLEFT", map, "TOPLEFT", 1, -1)
    map.canvas:SetSize(width, height)
    map.tiles = {}
    map.pins = {}
    map.empty = UI.Text(map, "label", "textFaint", "CENTER")
    map.empty:SetPoint("CENTER", map, "CENTER", 0, 0)
    map.empty:SetWidth(width - 40)
    pcall(map.empty.SetWordWrap, map.empty, true)
    map.empty:Hide()

    -- The floor bar under the map.
    local bar = UI.CreateFrame("Frame", parent)
    bar:SetSize(width + 2, 22)
    bar:SetPoint("TOPLEFT", map, "BOTTOMLEFT", 0, -4)
    bar.prev = arrow(bar, DungeonMap.PREV, function() map:TurnFloor(-1) end)
    bar.prev:SetPoint("LEFT", bar, "LEFT", 0, 0)
    bar.next = arrow(bar, DungeonMap.NEXT, function() map:TurnFloor(1) end)
    bar.next:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
    bar.label = UI.Text(bar, "label", "gold", "CENTER")
    bar.label:SetPoint("LEFT", bar.prev, "RIGHT", 4, 0)
    bar.label:SetPoint("RIGHT", bar.next, "LEFT", -4, 0)
    pcall(bar.label.SetWordWrap, bar.label, false)
    map.bar = bar

    local function tile(index)
        local texture = map.tiles[index]
        if not texture then
            texture = map.canvas:CreateTexture(nil, "ARTWORK")
            map.tiles[index] = texture
        end
        return texture
    end

    local function pin(index)
        local button = map.pins[index]
        if not button then
            button = UI.Portrait(map.canvas, PIN, {
                onClick = function(self) if self.gwPin and opts.onPin then opts.onPin(self.gwPin) end end,
                onEnter = function(self) if self.gwPin and opts.onPinEnter then opts.onPinEnter(self.gwPin, self) end end,
            })
            button.number = UI.Text(button, "small", "goldBright", "CENTER")
            button.number:SetPoint("TOP", button, "BOTTOM", 0, 1)
            pcall(button.SetFrameLevel, button, DungeonMap.FrameLevel(map.canvas) + 2)
            map.pins[index] = button
        end
        return button
    end

    -- Shows a dungeon's floor with its pins. selected: the creature to ring
    -- in gold; states: creature -> portrait state. Returns "drawn",
    -- "nomap" or "deferred" (in combat, the floor's art waits).
    function map:ShowDungeon(instanceId, floor, selected, states)
        local floors = Guide.Floors(instanceId)
        self.gwInstance = instanceId
        if #floors == 0 then
            for _, texture in ipairs(self.tiles) do texture:Hide() end
            for _, button in ipairs(self.pins) do button.gwPin = nil; button:Hide() end
            self.gwDrawn = nil
            UI.SetText(self.empty, "The client has no map of this instance. Its bosses are in the list.")
            self.empty:Show()
            self.bar:Hide()
            return "nomap"
        end
        floor = math.max(1, math.min(tonumber(floor) or 1, #floors))
        self.gwFloor, self.gwFloorCount = floor, #floors
        local key = instanceId .. ":" .. floor
        if self.gwDrawn ~= key then
            if inCombat() then
                for _, texture in ipairs(self.tiles) do texture:Hide() end
                for _, button in ipairs(self.pins) do button.gwPin = nil; button:Hide() end
                UI.SetText(self.empty, "The map draws after combat.")
                self.empty:Show()
                self.bar:Hide()
                return "deferred"
            end
            local started = GW.Perf and GW.Perf.Begin and GW.Perf.Begin()
            local missing = 0
            for index, place in ipairs(DungeonMap.TileLayout(self.gwWidth)) do
                local texture = tile(index)
                local fileId = floors[floor].t[index]
                texture:ClearAllPoints()
                texture:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", place.x, -place.y)
                texture:SetSize(place.w, place.h)
                pcall(texture.SetTexCoord, texture, 0, place.u, 0, place.v)
                -- SetTexture answers false for a file the client lacks.
                local ok, result = pcall(texture.SetTexture, texture, fileId)
                if not ok or result == false then missing = missing + 1 end
                texture.gwFile = fileId
                texture:Show()
            end
            self.gwDrawn, self.gwMissing = key, missing
            if started then GW.Perf.End("guide:map", started) end
        end
        if (self.gwMissing or 0) >= 12 then
            UI.SetText(self.empty, "This client has none of the map's pictures. Its bosses are in the list.")
            self.empty:Show()
        else
            self.empty:Hide()
        end
        -- Pins on this floor.
        local count = 0
        for _, place in ipairs(Guide.Pins(instanceId)) do
            if place.floor == floor then
                count = count + 1
                local button = pin(count)
                button.gwPin = place
                button:ClearAllPoints()
                button:SetPoint("CENTER", self.canvas, "TOPLEFT", place.x * self.gwWidth, -place.y * self.gwHeight)
                button:SetCreature(Guide.DisplayId(instanceId, place.creature))
                local state = states and states[place.creature] or nil
                button:SetState(place.creature == selected and "selected" or state or "available")
                UI.SetText(button.number, tostring(place.index))
                button:Show()
            end
        end
        for index = count + 1, #self.pins do
            self.pins[index].gwPin = nil
            self.pins[index]:Hide()
        end
        self.gwPinCount = count
        -- The floor bar: only for more than one floor.
        local name = floors[floor].n
        UI.SetShown(self.bar, #floors > 1 or name ~= nil)
        UI.SetText(self.bar.label, (#floors > 1 and (floor .. "/" .. #floors .. "  ") or "") .. (name or ""))
        UI.SetShown(self.bar.prev, #floors > 1)
        UI.SetShown(self.bar.next, #floors > 1)
        self.bar.prev:SetActive(floor > 1)
        self.bar.next:SetActive(floor < #floors)
        return "drawn"
    end

    function map:TurnFloor(step)
        local count = self.gwFloorCount or 1
        local floor = math.max(1, math.min(count, (self.gwFloor or 1) + step))
        if floor ~= self.gwFloor and opts.onFloor then opts.onFloor(floor) end
    end

    return map
end
