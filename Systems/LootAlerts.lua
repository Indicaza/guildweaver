local _, GW = ...

-- The loot alert rule engine: one evaluator for every reason an item in a
-- Need/Greed roll might deserve the player's attention.
--
-- A rule is { id, priority, evaluate(item) }. Evaluate(item) asks every
-- enabled rule and returns one alert:
--   reasons    every rule that matched, highest priority first
--   primary    reasons[1]: its category decides the glow colour
--   category   the primary reason's id (a key of Theme.alerts)
--   priority   the primary reason's priority
--   value      estimated auction value in copper, from whichever reason
--              knows it, with valueAge and valueConfidence
--   sound      true when a chime should play (the player's setting)
--
-- Wishlist > Valuable BoE > Potential upgrade. A wanted BoE glows purple
-- and still carries its value: secondary reasons are kept, not dropped.
--
-- Presenters (the roll-frame glow, the HUD glow, the toast) only read the
-- alert; none of them knows a rule. A new category is one Register call
-- here and one colour in Theme.alerts.
--
-- An alert says "look at this". It never says the item is the player's,
-- and nothing here (or anywhere in the add-on) rolls on anything.
GW.LootAlerts = GW.LootAlerts or {}

local Alerts = GW.LootAlerts
local Globals = _G or {}

Alerts.rules = {}
Alerts.PRIORITY = { wishlist = 300, valuable_boe = 200, upgrade = 100 }
-- Copper. The settings offer these; the website sends nothing below 1g.
Alerts.THRESHOLDS = { 50000, 100000, 250000, 500000, 1000000 }
Alerts.DEFAULT_THRESHOLD = 100000
-- One chime per moment, however many rolls start together.
Alerts.CHIME_COOLDOWN = 1.5
-- Sound kits by SOUNDKIT name, with the id they have had since Classic as
-- a fallback. All three are short and soft.
Alerts.CHIMES = {
    soft = { kit = "TELL_MESSAGE", id = 3081, label = "Soft" },
    bell = { kit = "IG_QUEST_LIST_COMPLETE", id = 878, label = "Bell" },
    coin = { kit = "LOOT_WINDOW_COIN_SOUND", id = 120, label = "Coin" },
}

local function prefs()
    local value = GW.UiPrefs and GW.UiPrefs.Get and GW.UiPrefs.Get("lootAlerts")
    return value or (GW.UiPrefs and GW.UiPrefs.DEFAULTS and GW.UiPrefs.DEFAULTS.lootAlerts) or {}
end
Alerts.Prefs = prefs

function Alerts.Threshold()
    local value = tonumber(prefs().boeThreshold)
    return value and value > 0 and value or Alerts.DEFAULT_THRESHOLD
end

-- Adds or replaces a rule. Rules are kept highest priority first.
function Alerts.Register(rule)
    if type(rule) ~= "table" or type(rule.id) ~= "string" or type(rule.evaluate) ~= "function" then return false end
    rule.priority = tonumber(rule.priority) or 0
    for index, existing in ipairs(Alerts.rules) do
        if existing.id == rule.id then table.remove(Alerts.rules, index) break end
    end
    table.insert(Alerts.rules, rule)
    table.sort(Alerts.rules, function(a, b)
        if a.priority ~= b.priority then return a.priority > b.priority end
        return a.id < b.id
    end)
    return true
end

-- item = { itemId, itemKey, name, quality, bindOnPickUp (true, false, or
-- nil when the client did not say), ... }. Returns an alert or nil.
function Alerts.Evaluate(item)
    if type(item) ~= "table" or not tonumber(item.itemId) then return nil end
    local reasons = {}
    for _, rule in ipairs(Alerts.rules) do
        if not rule.reserved and (not rule.enabled or rule.enabled()) then
            local ok, reason = pcall(rule.evaluate, item)
            if ok and type(reason) == "table" then
                reason.id = rule.id
                reason.priority = rule.priority
                table.insert(reasons, reason)
            end
        end
    end
    if #reasons == 0 then return nil end
    local primary = reasons[1]
    local alert = { reasons = reasons, primary = primary, category = primary.id, priority = primary.priority, sound = prefs().sound ~= false }
    for _, reason in ipairs(reasons) do
        if reason.value and not alert.value then
            alert.value, alert.valueAge, alert.valueConfidence = reason.value, reason.ageSeconds, reason.confidence
        end
    end
    return alert
end

-- "12g 50s", "85s": an estimate reads as one, never to the copper.
function Alerts.FormatValue(copper)
    copper = tonumber(copper) or 0
    local gold = math.floor(copper / 10000)
    local silver = math.floor(copper / 100) % 100
    if gold >= 100 then return gold .. "g" end
    if gold > 0 then return silver > 0 and (gold .. "g " .. silver .. "s") or (gold .. "g") end
    return silver .. "s"
end

function Alerts.FormatAge(seconds)
    seconds = tonumber(seconds) or 0
    if seconds < 5400 then return math.max(1, math.floor(seconds / 60 + 0.5)) .. "m old" end
    if seconds < 172800 then return math.floor(seconds / 3600 + 0.5) .. "h old" end
    return math.floor(seconds / 86400 + 0.5) .. "d old"
end

local PRIORITY_LABELS = { high = "High priority", normal = nil, low = "Low priority" }

-- The lines a presenter shows for an alert: what kind, then why.
function Alerts.Describe(alert)
    if type(alert) ~= "table" or not alert.primary then return nil, nil end
    local Theme = GW.Theme
    local parts = {}
    local primary = alert.primary
    if primary.id == "wishlist" then
        table.insert(parts, PRIORITY_LABELS[primary.wishPriority])
        table.insert(parts, primary.note ~= "" and primary.note or nil)
    end
    if alert.value then
        table.insert(parts, "~" .. Alerts.FormatValue(alert.value) .. " on the AH (" .. Alerts.FormatAge(alert.valueAge) .. ")")
    end
    local title = Theme and Theme.AlertLabel and Theme.AlertLabel(alert.category) or alert.category
    -- A second reason is named beside the first.
    if #alert.reasons > 1 and Theme and Theme.AlertLabel then
        title = title .. " + " .. Theme.AlertLabel(alert.reasons[2].id)
    end
    return title, table.concat(parts, " \194\183 ")
end

-- Sound --------------------------------------------------------------------------------

local lastChime = nil

function Alerts.ResetChime()
    lastChime = nil
end

-- Plays the player's chime unless one just played. Returns whether it did.
function Alerts.PlayChime(force)
    if prefs().sound == false and not force then return false end
    local now = type(Globals.GetTime) == "function" and tonumber(Globals.GetTime()) or 0
    if not force and lastChime and now - lastChime < Alerts.CHIME_COOLDOWN and now >= lastChime then return false end
    local chime = Alerts.CHIMES[prefs().chime] or Alerts.CHIMES.soft
    local kits = Globals.SOUNDKIT
    local id = type(kits) == "table" and tonumber(kits[chime.kit]) or chime.id
    if type(Globals.PlaySound) ~= "function" then return false end
    -- "Master", so it is heard with sound effects turned down in a fight;
    -- older clients take only the id.
    local ok = pcall(Globals.PlaySound, id, "Master")
    if not ok then ok = pcall(Globals.PlaySound, id) end
    if ok then lastChime = now end
    return ok
end

-- Rules --------------------------------------------------------------------------------

-- The item is on this character's wishlist and not yet received.
Alerts.Register({
    id = "wishlist",
    priority = Alerts.PRIORITY.wishlist,
    enabled = function() return prefs().wishlist ~= false end,
    evaluate = function(item)
        local sync = GW.LootSync
        local entry = sync and sync.WishlistEntry(item.itemId, item.itemKey)
        if not entry or sync.IsAcquired(entry.itemKey) then return nil end
        return { wishPriority = entry.priority, note = entry.note or "", source = entry.source }
    end,
})

-- A Bind-on-Equip item with a credible value on this character's auction
-- house, at or above the player's threshold. The roll itself must say the
-- item does not bind on pickup; quality and vendor price are never used.
Alerts.Register({
    id = "valuable_boe",
    priority = Alerts.PRIORITY.valuable_boe,
    enabled = function() return prefs().boe ~= false end,
    evaluate = function(item)
        if item.bindOnPickUp ~= false then return nil end
        local sync = GW.LootSync
        local estimate = sync and sync.BoeValue(item.itemId, item.itemKey)
        if not estimate or estimate.value < Alerts.Threshold() then return nil end
        return { value = estimate.value, ageSeconds = estimate.ageSeconds, confidence = estimate.confidence }
    end,
})

-- Reserved. Whether an item is an upgrade depends on the build: an item
-- level says little, and stat weights differ by spec. The category, its
-- colour and its priority exist so presenters already handle it; no rule
-- raises it yet.
Alerts.Register({
    id = "upgrade",
    priority = Alerts.PRIORITY.upgrade,
    reserved = true,
    evaluate = function() return nil end,
})
