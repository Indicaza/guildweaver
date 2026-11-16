local _, GW = ...

-- Group loot rolls: notices each Need/Greed roll, works out what the item
-- is, asks the alert engine about it once, and hands any alert to the
-- presenters (UI/LootAlertUI.lua). It also reports the roll as telemetry.
--
-- What this never does: it does not roll, does not touch the roll frame's
-- buttons, and does not call anything protected. The game's own
-- Need/Greed/Pass frame stays exactly as it is.
--
-- A roll is three separate facts, never merged:
--   offered   the item was put up for a roll (START_LOOT_ROLL)
--   won       the game then told this character it received that item
--             (its own "You receive loot" line), within a few minutes
--   owned     the bags changed, which the inventory stream reports itself
-- The corpse's loot window is its own observation (MobLootCapture); a roll
-- only borrows the creature from it when this client saw the item on
-- exactly one corpse just before, and says so.
--
-- Everything here is event driven: no scanning, no timers beyond one per
-- roll, nothing while idle.
GW.LootRolls = GW.LootRolls or {}

local Rolls = GW.LootRolls
local Globals = _G or {}

local DUPLICATE_SECONDS = 2
local RESOLVE_RETRY_SECONDS = 0.4
local MAX_RESOLVE_RETRIES = 6
local DEFAULT_ROLL_SECONDS = 180
-- How long after a roll a "You receive loot" line still counts as its win.
local WIN_WINDOW_SECONDS = 300
local WINDOW_SECONDS = 120
local MAX_ENDED = 40
local MAX_WINDOW_ITEMS = 200

Rolls.active = {}
Rolls.ended = {}
Rolls.windowItems = {}
Rolls.windowCount = 0
Rolls.stats = { started = 0, duplicates = 0, alerts = 0, unresolved = 0, won = 0 }

local function plain(value)
    if value == nil or (type(Globals.issecretvalue) == "function" and Globals.issecretvalue(value)) then return nil end
    return value
end

local function clock()
    return type(Globals.GetTime) == "function" and tonumber(Globals.GetTime()) or 0
end

local function serverTime()
    return type(Globals.GetServerTime) == "function" and tonumber(Globals.GetServerTime()) or 0
end

local function after(seconds, callback)
    local timer = Globals.C_Timer
    if type(timer) == "table" and type(timer.After) == "function" then
        timer.After(seconds, callback)
        return true
    end
    return false
end

-- itemId and random suffix from an item link ("item:6468:0:0:0:0:0:-1081").
function Rolls.ParseLink(link)
    if type(link) ~= "string" then return nil end
    local itemString = string.match(link, "item:([%-%d:]+)")
    if not itemString then return nil end
    local fields = {}
    for field in string.gmatch(itemString .. ":", "([^:]*):") do
        table.insert(fields, field)
    end
    local itemId = tonumber(fields[1])
    if not itemId or itemId <= 0 then return nil end
    local suffixId = tonumber(fields[7])
    return itemId, suffixId ~= 0 and suffixId or nil
end

-- What the client says a roll is for, or nil while it does not know yet.
local function readRoll(rollId)
    if type(Globals.GetLootRollItemLink) ~= "function" then return nil end
    local okLink, link = pcall(Globals.GetLootRollItemLink, rollId)
    link = okLink and plain(link) or nil
    local itemId, suffixId = Rolls.ParseLink(link)
    if not itemId then return nil end
    local item = { itemId = itemId, suffixId = suffixId, itemKey = GW.LootSync.ItemKey(itemId, suffixId), link = link }
    if type(Globals.GetLootRollItemInfo) == "function" then
        local ok, texture, name, count, quality, bindOnPickUp = pcall(Globals.GetLootRollItemInfo, rollId)
        if ok then
            item.texture, item.name, item.quality = plain(texture), plain(name), tonumber(plain(quality))
            item.quantity = tonumber(plain(count))
            -- Only a real boolean counts: anything else is "not known".
            bindOnPickUp = plain(bindOnPickUp)
            if bindOnPickUp == true or bindOnPickUp == false then item.bindOnPickUp = bindOnPickUp end
        end
    end
    if type(item.name) ~= "string" or item.name == "" then
        item.name = string.match(link, "%[(.-)%]")
    end
    return item
end

local function instanceContext()
    if type(Globals.GetInstanceInfo) ~= "function" then return nil end
    local ok, name, kind, difficultyId, difficultyName, _, _, _, instanceId = pcall(Globals.GetInstanceInfo)
    if not ok then return nil end
    return { name = plain(name), type = plain(kind), difficultyId = tonumber(plain(difficultyId)), difficultyName = plain(difficultyName),
        instanceId = tonumber(plain(instanceId)) }
end

-- Loot windows ---------------------------------------------------------------------------

-- MobLootCapture tells us what it just saw on which corpses, so a roll
-- that follows can name its creature when there is no doubt about it.
function Rolls.NoteLootWindow(sources)
    if type(sources) ~= "table" then return end
    local now = clock()
    if Rolls.windowCount > MAX_WINDOW_ITEMS then
        Rolls.windowItems, Rolls.windowCount = {}, 0
    end
    for guid, source in pairs(sources) do
        for itemId in pairs(type(source) == "table" and type(source.outputs) == "table" and source.outputs or {}) do
            local seen = Rolls.windowItems[itemId]
            if not seen or now - seen.at > WINDOW_SECONDS then
                if not seen then Rolls.windowCount = Rolls.windowCount + 1 end
                seen = { at = now, corpses = {}, count = 0 }
                Rolls.windowItems[itemId] = seen
            end
            if not seen.corpses[guid] then
                seen.corpses[guid] = { npcId = source.npcId, name = source.name }
                seen.count = seen.count + 1
            end
            seen.at = now
        end
    end
end

local function pinnedSource(itemId)
    local seen = Rolls.windowItems[itemId]
    if not seen or seen.count ~= 1 or clock() - seen.at > WINDOW_SECONDS then return nil end
    local _, corpse = next(seen.corpses)
    if not corpse or not tonumber(corpse.npcId) then return nil end
    return { npcId = corpse.npcId, name = corpse.name, basis = "loot_window_single_source" }
end

-- Telemetry ------------------------------------------------------------------------------

-- One event stream per roll; a later outcome is a new revision of it.
local function publish(roll)
    local snapshot = GW.Character and GW.Character.GetCurrentSnapshot and GW.Character.GetCurrentSnapshot()
    if type(snapshot) ~= "table" or not snapshot.characterId or not GW.TelemetryEnvelope or not GW.Store then return false end
    local item = roll.item
    local payload = {
        schemaVersion = 1,
        rollKey = tostring(snapshot.characterId) .. ":" .. roll.key,
        evidence = "group_roll",
        outcome = roll.outcome,
        startedAt = roll.startedAt,
        item = { itemId = item.itemId, itemKey = item.itemKey, name = item.name, qualityId = item.quality, quantity = item.quantity,
            bindOnPickUp = item.bindOnPickUp },
        acquired = roll.outcome == "won" and { basis = "chat_loot_self" } or nil,
        context = roll.context,
    }
    local envelope = GW.TelemetryEnvelope.Build("loot_roll", payload, { capturedAt = roll.startedAt, characterId = snapshot.characterId,
        realm = snapshot.realm, region = snapshot.region, gameBuild = snapshot.gameBuild })
    if not envelope then return false end
    return GW.Store.SetTelemetryEvent("loot_roll:" .. tostring(snapshot.characterId) .. ":" .. roll.key, envelope)
end

-- Rolls ----------------------------------------------------------------------------------

local function remember(roll)
    table.insert(Rolls.ended, roll)
    while #Rolls.ended > MAX_ENDED do table.remove(Rolls.ended, 1) end
end

-- The roll is over or gone: its glow and toast go with it.
function Rolls.End(rollId, reason)
    local roll = Rolls.active[rollId]
    if not roll then return false end
    Rolls.active[rollId] = nil
    roll.endedAt = clock()
    roll.endReason = reason
    if roll.item then remember(roll) end
    local ui = GW.LootAlertUI
    if ui and ui.Release then pcall(ui.Release, roll) end
    return true
end

local function resolve(roll)
    if roll.item or Rolls.active[roll.rollId] ~= roll then return end
    local item = readRoll(roll.rollId)
    if not item then
        roll.retries = roll.retries + 1
        if roll.retries > MAX_RESOLVE_RETRIES or not after(RESOLVE_RETRY_SECONDS, function() resolve(roll) end) then
            -- The client never said what the roll was for: nothing to alert
            -- on, nothing to report, and nothing to guess.
            Rolls.stats.unresolved = Rolls.stats.unresolved + 1
        end
        return
    end
    roll.item = item
    roll.outcome = "offered"
    local source = pinnedSource(item.itemId)
    local dungeon = GW.DungeonSessions and GW.DungeonSessions.Context and GW.DungeonSessions.Context() or nil
    local encounter = Rolls.lastEncounter
    roll.context = { instance = instanceContext(), source = source, dungeonRun = dungeon,
        encounter = encounter and clock() - encounter.at <= WINDOW_SECONDS and
            { id = encounter.id, name = encounter.name, secondsSinceEnd = math.floor(clock() - encounter.at) } or nil }
    pcall(publish, roll)

    local alert = GW.LootAlerts.Evaluate(item)
    if alert and not roll.notified then
        roll.alert = alert
        roll.notified = true
        Rolls.stats.alerts = Rolls.stats.alerts + 1
        local ui = GW.LootAlertUI
        if ui and ui.Present then pcall(ui.Present, roll) end
        if alert.sound then GW.LootAlerts.PlayChime() end
    end
end

-- START_LOOT_ROLL. The same roll announced again (some clients fire it
-- twice, and other add-ons re-fire it) is the same roll.
function Rolls.Start(rollId, rollTime)
    rollId = tonumber(plain(rollId))
    if not rollId then return nil end
    local now = clock()
    local existing = Rolls.active[rollId]
    if existing then
        if now - existing.at <= DUPLICATE_SECONDS or (existing.item and existing.expiresAt > now) then
            Rolls.stats.duplicates = Rolls.stats.duplicates + 1
            return existing
        end
        -- The id was reused for a new roll before the old one was cleaned up.
        Rolls.End(rollId, "replaced")
    end
    local seconds = tonumber(plain(rollTime))
    seconds = seconds and seconds > 0 and seconds / 1000 or DEFAULT_ROLL_SECONDS
    local startedAt = serverTime()
    Rolls.sequence = (Rolls.sequence or 0) + 1
    local roll = { rollId = rollId, at = now, startedAt = startedAt, expiresAt = now + seconds, retries = 0,
        key = tostring(startedAt) .. "." .. tostring(rollId) .. "." .. tostring(Rolls.sequence) }
    Rolls.active[rollId] = roll
    Rolls.stats.started = Rolls.stats.started + 1
    resolve(roll)
    -- Clients that never send CANCEL_LOOT_ROLL still let go of the roll.
    after(seconds + 1, function()
        if Rolls.active[rollId] == roll then Rolls.End(rollId, "expired") end
    end)
    return roll
end

-- Wins -----------------------------------------------------------------------------------

local selfPatterns = nil

-- "You receive loot: %s." as a pattern, from the client's own strings (so
-- it works in every language), with English as the fallback.
local function selfLootPatterns()
    if selfPatterns then return selfPatterns end
    selfPatterns = {}
    for _, name in ipairs({ "LOOT_ITEM_SELF", "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF", "LOOT_ITEM_PUSHED_SELF_MULTIPLE" }) do
        local format = Globals[name]
        if type(format) == "string" and format ~= "" then
            local pattern = string.gsub(format, "[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0")
            pattern = string.gsub(pattern, "%%s", "(.+)")
            pattern = string.gsub(pattern, "%%d", "(%%d+)")
            table.insert(selfPatterns, "^" .. pattern .. "$")
        end
    end
    if #selfPatterns == 0 then
        selfPatterns = { "^You receive loot: (.+)%.$", "^You receive item: (.+)%.$" }
    end
    return selfPatterns
end

-- CHAT_MSG_LOOT. Only the character's own receipt counts; another
-- player's "receives loot" line never does.
function Rolls.NoteLootMessage(message)
    message = plain(message)
    if type(message) ~= "string" or (not next(Rolls.active) and #Rolls.ended == 0) then return false end
    local received = nil
    for _, pattern in ipairs(selfLootPatterns()) do
        received = string.match(message, pattern)
        if received then break end
    end
    local itemId, suffixId = Rolls.ParseLink(received)
    if not itemId then return false end
    local itemKey = GW.LootSync.ItemKey(itemId, suffixId)
    local now = clock()
    local won = nil
    local function consider(roll)
        if roll.item and roll.item.itemKey == itemKey and roll.outcome ~= "won" and now - roll.at <= WIN_WINDOW_SECONDS + (roll.expiresAt - roll.at) then
            if not won or roll.at > won.at then won = roll end
        end
    end
    for _, roll in pairs(Rolls.active) do consider(roll) end
    for _, roll in ipairs(Rolls.ended) do consider(roll) end
    if not won then return false end
    won.outcome = "won"
    Rolls.stats.won = Rolls.stats.won + 1
    pcall(publish, won)
    -- It stops alerting now; the website confirms it from the next sync.
    local entry = GW.LootSync.WishlistEntry(itemId, itemKey)
    if entry then GW.LootSync.MarkAcquired(entry.itemKey) end
    return true
end

-- Events ---------------------------------------------------------------------------------

Rolls.EVENTS = { "START_LOOT_ROLL", "CANCEL_LOOT_ROLL", "CHAT_MSG_LOOT", "ENCOUNTER_END", "PLAYER_ENTERING_WORLD" }

function Rolls.OnEvent(event, ...)
    if event == "START_LOOT_ROLL" then
        Rolls.Start(...)
    elseif event == "CANCEL_LOOT_ROLL" then
        Rolls.End(tonumber(plain((...))), "cancelled")
    elseif event == "CHAT_MSG_LOOT" then
        Rolls.NoteLootMessage((...))
    elseif event == "ENCOUNTER_END" then
        local id, name, _, _, success = ...
        success = plain(success)
        if success == 1 or success == true then
            Rolls.lastEncounter = { id = tonumber(plain(id)), name = plain(name), at = clock() }
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- A loading screen ends every roll frame; none survives a reload.
        local ids = {}
        for rollId in pairs(Rolls.active) do table.insert(ids, rollId) end
        for _, rollId in ipairs(ids) do Rolls.End(rollId, "world") end
    end
end

function Rolls:Initialize()
    if self.eventFrame or type(Globals.CreateFrame) ~= "function" then return end
    local frame = Globals.CreateFrame("Frame")
    self.registered = {}
    for _, event in ipairs(Rolls.EVENTS) do
        local ok, result = pcall(frame.RegisterEvent, frame, event)
        self.registered[event] = ok and result ~= false
    end
    frame:SetScript("OnEvent", function(_, event, ...)
        -- A roll must never raise a Lua error into the middle of a fight.
        pcall(Rolls.OnEvent, event, ...)
    end)
    self.eventFrame = frame
end

Rolls:Initialize()
