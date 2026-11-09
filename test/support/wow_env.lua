-- A deterministic fake WoW Forever client for integration tests and the
-- benchmark. It loads the addon's real TOC in order and provides:
--   * frames with RegisterEvent/RegisterUnitEvent and unit-filtered dispatch
--   * C_Timer.After/NewTicker driven by a fake frame clock (60 fps)
--   * debugprofilestop that advances by a fixed simulated cost per API call,
--     so per-frame budgets are testable without real timing
--   * hidden GameTooltip scanners that "render" item and spell text
--   * per-API call counters (env.calls[name])
--   * a configurable character, bags, professions and loot window
--
-- Synthetic: simulated API costs are illustrative, not measured in game.

local Env = {}
Env.__index = Env

local FRAME_SECONDS = 1 / 60

-- Simulated cost in milliseconds of one call; tooltip renders dominate.
local DEFAULT_COSTS = {
    default = 0.002,
    tooltip = 0.15,
    tooltipInfo = 0.08,
    GetRecipeInfo = 0.01,
    GetRecipeSchematic = 0.01,
    GetItemInfo = 0.004,
}

local function deepCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, entry in pairs(value) do
        result[key] = deepCopy(entry)
    end
    return result
end
Env.deepCopy = deepCopy

function Env.deepEqual(left, right, path)
    path = path or "value"
    if type(left) ~= type(right) then
        return false, path .. ": type " .. type(left) .. " ~= " .. type(right)
    end
    if type(left) ~= "table" then
        if left ~= right then
            return false, path .. ": " .. tostring(left) .. " ~= " .. tostring(right)
        end
        return true
    end
    for key, value in pairs(left) do
        local ok, message = Env.deepEqual(value, right[key], path .. "." .. tostring(key))
        if not ok then
            return false, message
        end
    end
    for key in pairs(right) do
        if left[key] == nil then
            return false, path .. "." .. tostring(key) .. ": missing on left"
        end
    end
    return true
end

-- Item database ----------------------------------------------------------------

local function itemLink(itemId, name, quality, extra)
    local color = quality == 2 and "ff1eff00" or (quality == 3 and "ff0070dd" or "ffffffff")
    return "|c" .. color .. "|Hitem:" .. itemId .. (extra or "::::::::30:::::::") .. "|h[" .. name .. "]|h|r"
end
Env.itemLink = itemLink

local function defaultItems()
    local items = {}
    local function add(itemId, name, quality, class, equipLocation)
        items[itemId] = { itemId = itemId, name = name, quality = quality or 1, class = class or "Trade Goods",
            equipLocation = equipLocation or "", icon = 130000 + itemId % 1000 }
    end
    add(2770, "Copper Ore")
    add(2771, "Tin Ore")
    add(2589, "Linen Cloth")
    add(2447, "Peacebloom")
    add(765, "Silverleaf")
    add(2835, "Rough Stone")
    add(2840, "Copper Bar")
    add(6948, "Hearthstone")
    add(4238, "Linen Bag", 1, "Container", "INVTYPE_BAG")
    for slot = 1, 18 do
        add(10000 + slot, "Gear Piece " .. slot, 2, "Armor", "INVTYPE_CHEST")
    end
    for index = 1, 700 do
        add(20000 + index, "Crafted Item " .. index, 2, "Armor")
        add(30000 + (index % 120), "Reagent " .. (index % 120), 1)
    end
    return items
end

-- Construction -----------------------------------------------------------------

function Env.new(options)
    options = options or {}
    local env = setmetatable({}, Env)
    env.calls = {}
    env.costs = deepCopy(DEFAULT_COSTS)
    env.cpu = 0
    env.time = 1000
    env.serverTime = 1791322510
    env.frameCount = 0
    env.timers = {}
    env.timerSeq = 0
    env.frames = {}
    env.reloads = 0
    env.inCombat = false
    env.printed = {}
    env.items = defaultItems()
    env.uncached = {}
    env.money = 1234567
    env.root = options.root or "."
    env.unitEvents = options.unitEvents ~= false
    -- realClock adds real interpreter time to the simulated API costs (for
    -- the benchmark); tests keep the deterministic clock.
    env.realClock = options.realClock == true
    env.durability = {}
    env.weaponEnchant = { false, nil, nil, nil, false, nil, nil, nil }

    -- Character
    env.player = { name = "Rook", surname = "Ravenstar", realm = "Live Realm", level = 30, guid = "Player-1-0001" }
    env.stats = { 50, 40, 60, 30, 20 }
    env.talents = {}
    for tab = 1, 3 do
        env.talents[tab] = {}
        for index = 1, 15 do
            env.talents[tab][index] = { rank = (tab == 1 and index <= 5) and 1 or 0, maxRank = 3 }
        end
    end

    -- Equipment: slots 1..18 hold gear pieces (some empty)
    env.equipment = {}
    for slot = 1, 18 do
        if slot ~= 4 and slot ~= 19 then
            env.equipment[slot] = itemLink(10000 + slot, "Gear Piece " .. slot, 2)
        end
    end

    -- Bags: backpack 16 slots, bag 1..4 with 10 slots each
    env.bags = { [0] = { size = 16, slots = {} } }
    for bag = 1, 4 do
        env.bags[bag] = { size = 10, slots = {}, item = itemLink(4238, "Linen Bag", 1) }
    end
    local function put(bag, slot, itemId, count, bound)
        local item = env.items[itemId]
        env.bags[bag].slots[slot] = { itemID = itemId, stackCount = count or 1, quality = item.quality,
            iconFileID = item.icon, hyperlink = itemLink(itemId, item.name, item.quality), isBound = bound }
    end
    env.put = put
    put(0, 1, 2770, 10)
    put(0, 2, 2770, 4)
    put(0, 3, 6948, 1, true)
    put(0, 4, 2589, 20)
    put(1, 1, 2447, 5)
    put(1, 2, 765, 3)
    put(2, 1, 2835, 20)
    put(2, 2, 2840, 8)
    put(3, 1, 2771, 7)
    local extraItems = tonumber(options.bagItems) or 0
    for index = 1, extraItems do
        local bag = 1 + (index % 4)
        local slot = 3 + math.floor(index / 4)
        if slot <= env.bags[bag].size then
            put(bag, slot, 20000 + index, 1, true)
        end
    end

    -- Professions
    env.professions = {
        { name = "Blacksmithing", skillLineId = 164, skill = 150, max = 225 },
        { name = "Mining", skillLineId = 186, skill = 140, max = 225 },
    }
    env.recipeCount = tonumber(options.recipes) or 40
    env.tradeSkillOpen = false
    env.openProfession = 164
    env.dataSourceChanging = false

    -- Loot window
    env.loot = nil

    return env
end

function Env:count(name, cost)
    self.calls[name] = (self.calls[name] or 0) + 1
    self.cpu = self.cpu + (cost or self.costs[name] or self.costs.default)
end

function Env:callCount(name)
    return self.calls[name] or 0
end

function Env:resetCalls()
    self.calls = {}
end

-- Wraps an API so it is counted and charged its simulated cost.
function Env:api(name, fn)
    local env = self
    return function(...)
        env:count(name)
        return fn(...)
    end
end

-- Frames -----------------------------------------------------------------------

-- Unknown frame members are callable no-op stand-ins (UI layout calls,
-- template children such as TitleText). They are tables, not functions, so
-- capability checks like type(frame.X) == "function" still see them absent.
local permissive
local stubMeta = {}
stubMeta.__index = function()
    return permissive({})
end
stubMeta.__call = function()
    return permissive({})
end

permissive = function(object)
    return setmetatable(object, stubMeta)
end

function Env.newFrame(env, frameType, name)
    local frame = {
        frameType = frameType,
        name = name,
        events = {},
        unitFilters = {},
        scripts = {},
        hooks = {},
        shown = true,
    }
    function frame:RegisterEvent(event)
        self.events[event] = true
        return true
    end
    if env.unitEvents then
        function frame:RegisterUnitEvent(event, ...)
            self.events[event] = true
            local units = {}
            for index = 1, select("#", ...) do
                units[select(index, ...)] = true
            end
            self.unitFilters[event] = units
            return true
        end
    end
    function frame:UnregisterEvent(event)
        self.events[event] = nil
        self.unitFilters[event] = nil
    end
    function frame:UnregisterAllEvents()
        self.events = {}
        self.unitFilters = {}
    end
    function frame:SetScript(script, callback)
        self.scripts[script] = callback
    end
    function frame:GetScript(script)
        return self.scripts[script]
    end
    function frame:HookScript(script, callback)
        self.hooks[script] = self.hooks[script] or {}
        table.insert(self.hooks[script], callback)
    end
    function frame:Show() self.shown = true end
    function frame:Hide() self.shown = false end
    function frame:IsShown() return self.shown end
    function frame:GetName() return self.name end
    table.insert(env.frames, frame)
    if name then
        _G[name] = frame
    end
    return permissive(frame)
end

-- Delivers an event to every frame registered for it (respecting unit
-- filters), as the client does.
function Env:dispatch(event, ...)
    local unit = ...
    local delivered = 0
    for _, frame in ipairs(self.frames) do
        if frame.events[event] then
            local filter = frame.unitFilters[event]
            if not filter or filter[unit] then
                local handler = frame.scripts.OnEvent
                if handler then
                    delivered = delivered + 1
                    handler(frame, event, ...)
                end
            end
        end
    end
    self.delivered = (self.delivered or 0) + delivered
    return delivered
end

-- Tooltips ---------------------------------------------------------------------

function Env:itemFromLink(link)
    local itemId = tonumber(tostring(link):match("item:(%d+)"))
    return itemId and self.items[itemId] or nil, itemId
end

function Env:newTooltip(name)
    local env = self
    local tooltip = self:newFrame("GameTooltip", name)
    local raw = getmetatable(tooltip) and tooltip
    local lines = {}

    local function render(textLines)
        lines = textLines or {}
        for index = 1, 40 do
            local text = lines[index]
            _G[name .. "TextLeft" .. index] = {
                GetText = function() return text end,
                GetTextColor = function() return 1, 1, 1, 1 end,
            }
            _G[name .. "TextRight" .. index] = { GetText = function() return nil end }
        end
    end

    local function itemLines(link, extra)
        local item = env:itemFromLink(link)
        if not item or env.uncached[item.itemId] then
            return {}
        end
        local result = { item.name }
        for _, line in ipairs(extra or {}) do
            table.insert(result, line)
        end
        table.insert(result, item.class)
        return result
    end

    raw.SetOwner = function() end
    raw.ClearLines = function() lines = {} end
    raw.NumLines = function() return #lines end
    raw.SetHyperlink = function(_, link)
        env:count("tooltip:SetHyperlink", env.costs.tooltip)
        if tostring(link):find("spell:", 1, true) then
            render({ "Spell " .. tostring(link):match("spell:(%d+)") })
            return
        end
        render(itemLines(link))
    end
    raw.SetBagItem = function(_, bag, slot)
        env:count("tooltip:SetBagItem", env.costs.tooltip)
        local info = env.bags[bag] and env.bags[bag].slots[slot]
        if not info then
            render({})
            return
        end
        local extra = {}
        if info.isBound then
            table.insert(extra, "Soulbound")
        end
        if info.itemID == 6948 then
            table.insert(extra, "Cooldown remaining: " .. tostring(env.serverTime % 300) .. " sec")
        end
        render(itemLines(info.hyperlink, extra))
    end
    raw.SetInventoryItem = function(_, _, slot)
        env:count("tooltip:SetInventoryItem", env.costs.tooltip)
        local link = env.equipment[slot]
        local durability = env.durability[slot]
        render(link and itemLines(link, { "Soulbound", durability and ("Durability " .. durability .. " / 100") or nil }) or {})
    end
    raw.SetLootItem = function(_, slot)
        env:count("tooltip:SetLootItem", env.costs.tooltip)
        local entry = env.loot and env.loot[slot]
        render(entry and itemLines(entry.link, { "Crafting Reagent" }) or {})
    end
    raw.SetSpellByID = function(_, spellId)
        env:count("tooltip:SetSpellByID", env.costs.tooltip)
        render({ "Spell " .. tostring(spellId), "Creates something." })
    end
    render({})
    return tooltip
end

function Env:tooltipScans()
    local total = 0
    for name, count in pairs(self.calls) do
        if name:find("^tooltip:") then
            total = total + count
        end
    end
    return total
end

function Env:itemTooltipScans()
    return self:callCount("tooltip:SetBagItem") + self:callCount("tooltip:SetInventoryItem")
        + self:callCount("tooltip:SetHyperlink") + self:callCount("tooltip:SetLootItem")
end

-- Timers and frames --------------------------------------------------------------

function Env:after(delay, callback)
    self.timerSeq = self.timerSeq + 1
    table.insert(self.timers, { at = self.time + math.max(0, tonumber(delay) or 0), seq = self.timerSeq,
        frame = self.frameCount, callback = callback })
end

-- Advances one rendered frame and runs the timers that are due. A timer
-- created during this frame with delay 0 waits for the next frame.
function Env:nextFrame()
    self.frameCount = self.frameCount + 1
    self.time = self.time + FRAME_SECONDS
    self.frameStartCpu = self.cpu
    local due = {}
    local remaining = {}
    for _, timer in ipairs(self.timers) do
        if timer.at <= self.time + 1e-9 and timer.frame < self.frameCount then
            table.insert(due, timer)
        else
            table.insert(remaining, timer)
        end
    end
    table.sort(due, function(left, right)
        if left.at ~= right.at then
            return left.at < right.at
        end
        return left.seq < right.seq
    end)
    self.timers = remaining
    for _, timer in ipairs(due) do
        timer.callback()
    end
    local frameCpu = self.cpu - self.frameStartCpu
    self.worstFrameCpu = math.max(self.worstFrameCpu or 0, frameCpu)
    return frameCpu
end

function Env:advance(seconds)
    local target = self.time + seconds
    local worst = 0
    while self.time + FRAME_SECONDS <= target + 1e-9 do
        worst = math.max(worst, self:nextFrame())
    end
    return worst
end

-- Runs frames until no timers remain (or the limit is reached).
function Env:settle(maxSeconds)
    local frames = 0
    local limit = math.floor((maxSeconds or 30) / FRAME_SECONDS)
    while #self.timers > 0 and frames < limit do
        self:nextFrame()
        frames = frames + 1
    end
    return frames
end

-- Globals ------------------------------------------------------------------------

function Env.install(env)
    local G = _G
    local function api(name, fn)
        G[name] = env:api(name, fn)
    end

    GuildweaverDB = nil
    G.GW_ENV = env
    G.NUM_BAG_SLOTS = 4
    G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, message) table.insert(env.printed, message) end }
    G.UIParent = permissive({})
    G.UISpecialFrames = {}
    G.SlashCmdList = {}
    G.ReloadUI = function() env.reloads = env.reloads + 1 end
    G.InCombatLockdown = function() return env.inCombat end
    G.debugprofilestop = function()
        if env.realClock then
            return env.cpu + os.clock() * 1000
        end
        return env.cpu
    end
    G.GetTime = function() return env.time end
    G.GetServerTime = function() return env.serverTime end
    G.C_Timer = {
        After = function(delay, callback) env:after(delay, callback) end,
        NewTicker = function(interval, callback)
            local ticker = { cancelled = false }
            local function tick()
                if ticker.cancelled then return end
                callback()
                env:after(interval, tick)
            end
            env:after(interval, tick)
            function ticker:Cancel() self.cancelled = true end
            return ticker
        end,
    }
    G.CreateFrame = function(frameType, name)
        if frameType == "GameTooltip" then
            return env:newTooltip(name or ("Tooltip" .. #env.frames))
        end
        return env:newFrame(frameType, name)
    end
    G.GameTooltip = env:newFrame("GameTooltip", "GameTooltip")
    G.C_AddOns = { GetAddOnMetadata = function() return "0.5.0" end }

    api("GetBuildInfo", function() return "1.60.1", "70338", "Nov 2026", 16001 end)
    api("GetRealmName", function() return env.player.realm end)
    api("GetCurrentRegion", function() return 1 end)
    api("GetLocale", function() return "enUS" end)
    api("UnitFullName", function() return env.player.name, env.player.surname end)
    api("UnitName", function(unit) return unit == "player" and env.player.name or "Mob" end)
    api("UnitGUID", function(unit) return unit == "player" and env.player.guid or nil end)
    api("UnitRace", function() return "Night Elf", "NightElf", 4 end)
    api("UnitClass", function() return "Warrior", "WARRIOR", 1 end)
    api("UnitSex", function() return 2 end)
    api("UnitLevel", function() return env.player.level end)
    api("GetGuildInfo", function() return "Holdfast", "Member", 3 end)
    api("GetMoney", function() return env.money end)

    -- Stats (a representative subset; missing ones read as unavailable)
    api("UnitStat", function(_, index) local value = env.stats[index] or 0; return value, value, 0, 0 end)
    api("UnitArmor", function() return 900, 900, 900, 0, 0 end)
    api("UnitResistance", function() return 0, 0, 0, 0 end)
    api("UnitAttackPower", function() return 120, 10, 0 end)
    api("UnitAttackSpeed", function() return 2.4, 0 end)
    api("UnitHealth", function() return 900 end)
    api("UnitHealthMax", function() return 1000 end)
    api("GetCritChance", function() return 5.5 end)
    api("GetDodgeChance", function() return 4.0 end)
    api("GetAverageItemLevel", function() return 30, 29, 0 end)

    -- Talents (legacy API)
    api("GetNumTalentTabs", function() return #env.talents end)
    api("GetTalentTabInfo", function(tab) return "Tree " .. tab, 100 + tab, 0 end)
    api("GetNumTalents", function(tab) return #env.talents[tab] end)
    api("GetTalentInfo", function(tab, index)
        local talent = env.talents[tab][index]
        return "Talent " .. tab .. "-" .. index, 200 + index, math.ceil(index / 4), (index - 1) % 4 + 1,
            talent.rank, talent.maxRank, false, true
    end)
    api("GetTalentLink", function(tab, index) return "|Hspell:" .. (5000 + tab * 100 + index) .. "|h[Talent]|h" end)
    api("UnitCharacterPoints", function() return 0 end)

    -- Equipment
    local SLOT_IDS = {
        HeadSlot = 1, NeckSlot = 2, ShoulderSlot = 3, BackSlot = 15, ChestSlot = 5, ShirtSlot = 4,
        TabardSlot = 19, WristSlot = 9, HandsSlot = 10, WaistSlot = 6, LegsSlot = 7, FeetSlot = 8,
        Finger0Slot = 11, Finger1Slot = 12, Trinket0Slot = 13, Trinket1Slot = 14,
        MainHandSlot = 16, SecondaryHandSlot = 17,
    }
    api("GetInventorySlotInfo", function(name) return SLOT_IDS[name] end)
    api("GetInventoryItemLink", function(_, slot)
        if slot >= 20 and slot <= 23 then
            local bag = env.bags[slot - 19]
            return bag and bag.item or nil
        end
        return env.equipment[slot]
    end)
    api("GetInventoryItemID", function(_, slot)
        local link = env.equipment[slot]
        return link and tonumber(link:match("item:(%d+)")) or nil
    end)
    api("GetInventoryItemQuality", function() return 2 end)
    api("GetInventoryItemTexture", function() return 133000 end)
    api("GetInventoryItemDurability", function(slot)
        local value = env.durability[slot]
        if value then return value, 100 end
        return nil
    end)
    api("GetWeaponEnchantInfo", function() return unpack(env.weaponEnchant, 1, 8) end)
    api("GetItemInfo", function(link)
        local item, itemId = env:itemFromLink(tonumber(link) and ("item:" .. link) or link)
        if not item or env.uncached[itemId] then
            return nil
        end
        return item.name, itemLink(itemId, item.name, item.quality), item.quality, 20, 10, item.class, "Misc",
            20, item.equipLocation, item.icon, 5, 7, 7, 0, 0, nil, item.class == "Trade Goods"
    end)
    api("GetItemInfoInstant", function(itemId) local item = env.items[tonumber(itemId)]; return itemId, nil, nil, nil, item and item.icon end)
    api("GetItemStats", function() return {} end)
    api("GetItemSpell", function() return nil end)
    api("GetDetailedItemLevelInfo", function() return 30 end)

    -- Bags
    G.C_Container = {}
    local container = G.C_Container
    container.GetContainerNumSlots = env:api("GetContainerNumSlots", function(bag) return env.bags[bag] and env.bags[bag].size or 0 end)
    container.GetContainerNumFreeSlots = env:api("GetContainerNumFreeSlots", function(bag)
        local data = env.bags[bag]
        local used = 0
        for _ in pairs(data and data.slots or {}) do used = used + 1 end
        return (data and data.size or 0) - used, 0
    end)
    container.GetContainerItemInfo = env:api("GetContainerItemInfo", function(bag, slot)
        local data = env.bags[bag]
        local info = data and data.slots[slot]
        return info and deepCopy(info) or nil
    end)
    container.GetBagName = env:api("GetBagName", function(bag) return bag == 0 and "Backpack" or "Linen Bag" end)
    container.ContainerIDToInventoryID = function(bag) return 19 + bag end
    container.GetContainerItemDurability = env:api("GetContainerItemDurability", function() return nil end)

    -- Spells
    G.C_Spell = {
        GetSpellName = env:api("GetSpellName", function(spellId) return "Spell " .. spellId end),
        GetSpellTexture = env:api("GetSpellTexture", function() return 136000 end),
        GetSpellDescription = env:api("GetSpellDescription", function() return "Creates something." end),
        GetSpellLink = env:api("GetSpellLink", function(spellId) return "|Hspell:" .. spellId .. "|h[Spell]|h" end),
    }
    G.C_TooltipInfo = {
        GetSpellByID = function(spellId)
            env:count("tooltip:GetSpellByID", env.costs.tooltipInfo)
            return { lines = { { leftText = "Spell " .. spellId }, { leftText = "Creates something." } } }
        end,
    }

    -- Professions
    api("GetProfessions", function() return 1, 2 end)
    api("GetProfessionInfo", function(index)
        local profession = env.professions[index]
        if not profession then return nil end
        return profession.name, 136000, profession.skill, profession.max, 0, 0, profession.skillLineId, 0, nil, nil, profession.name
    end)
    G.C_TradeSkillUI = {}
    local trade = G.C_TradeSkillUI
    local function recipeIds()
        local ids = {}
        for index = 1, env.recipeCount do
            ids[index] = env.openProfession * 10000 + index
        end
        return ids
    end
    trade.IsTradeSkillReady = env:api("IsTradeSkillReady", function() return env.tradeSkillOpen end)
    trade.IsDataSourceChanging = env:api("IsDataSourceChanging", function() return env.dataSourceChanging end)
    trade.GetAllRecipeIDs = env:api("GetAllRecipeIDs", function()
        return env.tradeSkillOpen and recipeIds() or {}
    end)
    trade.GetBaseProfessionInfo = env:api("GetBaseProfessionInfo", function()
        if not env.tradeSkillOpen then return nil end
        return { professionID = env.openProfession, professionName = env.openProfession == 164 and "Blacksmithing" or "Mining",
            skillLevel = 150, maxSkillLevel = 225 }
    end)
    trade.GetChildProfessionInfo = trade.GetBaseProfessionInfo
    trade.GetRecipeInfo = env:api("GetRecipeInfo", function(recipeId)
        if not env.tradeSkillOpen then return nil end
        local index = recipeId % 10000
        return { recipeID = recipeId, name = "Recipe " .. recipeId, icon = 134000, learned = index % 3 ~= 0,
            categoryID = 1000 + index % 12, relativeDifficulty = index % 4, numSkillUps = 1, craftable = true }
    end)
    trade.GetTradeSkillLineForRecipe = env:api("GetTradeSkillLineForRecipe", function() return env.openProfession end)
    trade.GetRecipeOutputItemData = env:api("GetRecipeOutputItemData", function(recipeId)
        local index = recipeId % 10000
        return { itemID = 20000 + index }
    end)
    trade.GetRecipeSchematic = env:api("GetRecipeSchematic", function(recipeId)
        local index = recipeId % 10000
        return { outputItemID = 20000 + index, quantityMin = 1, quantityMax = 1,
            reagentSlotSchematics = { { required = true, quantityRequired = 2, reagents = { { itemID = 30000 + index % 120 } } } } }
    end)
    trade.GetRecipeCooldown = env:api("GetRecipeCooldown", function() return 0 end)
    trade.GetRecipeDescription = env:api("GetRecipeDescription", function(recipeId) return "Recipe " .. recipeId .. " description" end)
    trade.GetRecipeRequirements = env:api("GetRecipeRequirements", function() return { { name = "Anvil", met = true } } end)
    trade.GetCategoryInfo = env:api("GetCategoryInfo", function(categoryId)
        return { categoryID = categoryId, name = "Category " .. categoryId, parentCategoryID = categoryId == 999 and 0 or 999, uiOrder = categoryId }
    end)

    -- Loot
    api("GetNumLootItems", function() return env.loot and #env.loot or 0 end)
    api("GetLootSlotInfo", function(slot)
        local entry = env.loot and env.loot[slot]
        if not entry then return nil end
        local item = env:itemFromLink(entry.link)
        return item.icon, item.name, entry.quantity, nil, item.quality, false, false, nil, true, false
    end)
    api("GetLootSlotLink", function(slot) local entry = env.loot and env.loot[slot]; return entry and entry.link end)
    api("GetLootSourceInfo", function(slot)
        local entry = env.loot and env.loot[slot]
        if not entry then return nil end
        return entry.source, entry.quantity
    end)
    api("GetSpellInfo", function(spellId) return spellId == 2366 and "Herb Gathering" or ("Spell " .. tostring(spellId)) end)
end

-- Loads the addon from env.root in TOC order. Returns the addon table.
function Env:load()
    self:install()
    local addon = {}
    local toc = assert(io.open(self.root .. "/Guildweaver.toc", "r"))
    for line in toc:lines() do
        line = line:gsub("\r$", "")
        if line ~= "" and not line:find("^#") and line ~= "Data/BridgeInbox.generated.lua"
            and line ~= "Data/BridgeAcks.generated.lua" then
            local chunk = assert(loadfile(self.root .. "/" .. line))
            chunk("Guildweaver", addon)
        end
    end
    toc:close()
    self.addon = addon
    return addon
end

-- Login sequence as the client fires it.
function Env:login()
    self:dispatch("ADDON_LOADED", "Guildweaver")
    self:dispatch("PLAYER_LOGIN")
    self:dispatch("PLAYER_ENTERING_WORLD", true, false)
    self:dispatch("BAG_UPDATE_DELAYED")
    self:advance(5)
end

function Env.telemetry()
    return GuildweaverDB and GuildweaverDB.sync and GuildweaverDB.sync.outbound and GuildweaverDB.sync.outbound.telemetry or {}
end

function Env:stream(prefix)
    for key, record in pairs(self:telemetry()) do
        if key:find(prefix, 1, true) == 1 then
            return record, key
        end
    end
    return nil
end

return Env
