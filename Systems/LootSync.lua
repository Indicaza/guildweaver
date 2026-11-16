local _, GW = ...

-- What the website knows that loot alerts need: this character's gear
-- wishlist and a short list of valuable Bind-on-Equip items on its auction
-- house. The bridge writes both to Data/BridgeLoot.generated.lua
-- (GW.BridgeLoot); WoW reads that file at login and /reload only.
--
-- The file is never trusted as it is. It is checked field by field and
-- copied, bounded, into SavedVariables (sync.inbound.loot). A missing,
-- damaged or older file changes nothing: the copy from the last good load
-- stays, so alerts keep working offline and after an add-on update.
--
-- Nothing here reads the game: lookups are table reads, cheap enough for
-- a roll event in the middle of a fight.
GW.LootSync = GW.LootSync or {}

local Sync = GW.LootSync

local SCHEMA_VERSION = 1
local LIMITS = { characters = 20, aliases = 8, wishlistItems = 200, markets = 4, boeItems = 300, text = 160 }
local PRIORITIES = { high = true, normal = true, low = true }
local CONFIDENCES = { high = true, medium = true }
Sync.LIMITS = LIMITS

local function isTable(value)
    return type(value) == "table"
end

local function wholeNumber(value, min)
    return type(value) == "number" and value == math.floor(value) and value >= (min or 0) and value < 2 ^ 53
end

local function text(value, max)
    if type(value) ~= "string" then return nil end
    return string.sub(value, 1, max or LIMITS.text)
end

-- "i:15210" or "i:15210:s-1081" for an item id; nil when it is not a key
-- of that item.
local function validKey(key, itemId)
    if type(key) ~= "string" then return false end
    local id = string.match(key, "^i:(%d+)$") or string.match(key, "^i:(%d+):s%-?%d+$") or string.match(key, "^i:(%d+):[sb][%d%.:sb%-]+$")
    return tonumber(id) == itemId
end

-- The key of an item as it dropped: its id, and its random suffix if any.
function Sync.ItemKey(itemId, suffixId)
    itemId = tonumber(itemId)
    if not itemId then return nil end
    suffixId = tonumber(suffixId)
    if suffixId and suffixId ~= 0 then
        return "i:" .. itemId .. ":s" .. suffixId
    end
    return "i:" .. itemId
end

local function wishlistItem(raw)
    if not isTable(raw) or not wholeNumber(raw.itemId, 1) or not validKey(raw.itemKey, raw.itemId) or not PRIORITIES[raw.priority] then
        return nil
    end
    return {
        itemId = raw.itemId, itemKey = raw.itemKey, priority = raw.priority,
        note = text(raw.note, 140), name = text(raw.name, 80), source = text(raw.source, 80),
        qualityId = wholeNumber(raw.qualityId) and raw.qualityId or nil,
    }
end

local function character(raw, markets)
    if not isTable(raw) or not text(raw.id) or not text(raw.name) or not isTable(raw.wishlist) or not isTable(raw.wishlist.items) then
        return nil
    end
    local items, seen = {}, {}
    for index, entry in ipairs(raw.wishlist.items) do
        if index > LIMITS.wishlistItems then break end
        local item = wishlistItem(entry)
        if not item then return nil end
        if not seen[item.itemKey] then
            seen[item.itemKey] = true
            table.insert(items, item)
        end
    end
    local aliases = {}
    for index, alias in ipairs(isTable(raw.aliases) and raw.aliases or {}) do
        if index > LIMITS.aliases then break end
        if type(alias) == "string" then table.insert(aliases, string.sub(alias, 1, 400)) end
    end
    local marketKey = text(raw.marketKey)
    return {
        id = string.sub(raw.id, 1, 400), name = text(raw.name, 80), realm = text(raw.realm, 120) or "", region = text(raw.region, 32) or "",
        aliases = aliases, marketKey = marketKey and markets[marketKey] and marketKey or nil,
        wishlist = { revision = wholeNumber(raw.wishlist.revision) and raw.wishlist.revision or 0,
            updatedAt = wholeNumber(raw.wishlist.updatedAt) and raw.wishlist.updatedAt or 0, items = items },
    }
end

local function market(raw)
    if not isTable(raw) or not isTable(raw.items) then return nil end
    local items = {}
    for index, entry in ipairs(raw.items) do
        if index > LIMITS.boeItems then break end
        -- k: item key, id: item id, v: copper, t: observed at, c: confidence.
        if not isTable(entry) or not wholeNumber(entry.id, 1) or not validKey(entry.k, entry.id) or not wholeNumber(entry.v, 1)
            or not wholeNumber(entry.t, 1) or not CONFIDENCES[entry.c] then
            return nil
        end
        items[entry.k] = { value = entry.v, observedAt = entry.t, confidence = entry.c }
    end
    return { name = text(raw.name, 80) or "", items = items }
end

-- The bridge's file as a bounded copy, or nil and why. One malformed part
-- refuses the whole file: half a wishlist is worse than yesterday's.
function Sync.Validate(inbox)
    if not isTable(inbox) then return nil, "missing" end
    if inbox.schemaVersion ~= SCHEMA_VERSION then return nil, "unsupported_schema" end
    if type(inbox.digest) ~= "string" or inbox.digest == "" or not wholeNumber(inbox.revision) or not wholeNumber(inbox.generatedAt, 1) then
        return nil, "invalid_header"
    end
    if not isTable(inbox.characters) or not isTable(inbox.boe) or not isTable(inbox.boe.markets)
        or not wholeNumber(inbox.boe.floorCopper, 1) or not wholeNumber(inbox.boe.maxAgeSeconds, 60) then
        return nil, "invalid_shape"
    end
    local markets, marketCount = {}, 0
    for key, raw in pairs(inbox.boe.markets) do
        if marketCount >= LIMITS.markets then break end
        local clean = type(key) == "string" and market(raw) or nil
        if not clean then return nil, "invalid_market" end
        markets[string.sub(key, 1, LIMITS.text)] = clean
        marketCount = marketCount + 1
    end
    local characters = {}
    for index, raw in ipairs(inbox.characters) do
        if index > LIMITS.characters then break end
        local clean = character(raw, markets)
        if not clean then return nil, "invalid_character" end
        table.insert(characters, clean)
    end
    return {
        schemaVersion = SCHEMA_VERSION, digest = string.sub(inbox.digest, 1, 64), revision = inbox.revision, generatedAt = inbox.generatedAt,
        characters = characters,
        boe = { floorCopper = inbox.boe.floorCopper, maxAgeSeconds = inbox.boe.maxAgeSeconds, markets = markets },
    }
end

local function serverTime()
    return type(GetServerTime) == "function" and tonumber(GetServerTime()) or 0
end

local function inbound()
    local db = GW.Store and GW.Store.GetDatabase and GW.Store.GetDatabase()
    if not isTable(db) or not isTable(db.sync) then return nil end
    db.sync.inbound = isTable(db.sync.inbound) and db.sync.inbound or {}
    return db.sync.inbound
end

-- Loads the bridge's file once per login. Returns what happened:
--   "applied"    a new valid file replaced the saved copy
--   "unchanged"  the file is the one already saved
--   "stale"      the file is older than the saved copy; the copy stays
--   "kept"       no usable file (missing or invalid); the copy stays
--   "empty"      no usable file and nothing saved yet
function Sync.Initialize()
    Sync.active = nil
    Sync.status = { result = "empty" }
    local store = inbound()
    if not store then return "empty" end
    local saved = isTable(store.loot) and store.loot or nil
    local inbox, reason = Sync.Validate(GW.BridgeLoot)
    local result
    if not inbox then
        result = saved and "kept" or "empty"
    elseif saved and saved.digest == inbox.digest then
        result = "unchanged"
    elseif saved and tonumber(saved.generatedAt) and inbox.generatedAt < saved.generatedAt then
        result, reason = "stale", "stale_revision"
    else
        inbox.receivedAt = serverTime()
        store.loot = inbox
        -- The website has caught up with what was looted since the last
        -- file: its list is the truth again.
        store.lootAcquired = nil
        result = "applied"
    end
    Sync.status = { result = result, reason = reason }
    return result
end

local function lower(value)
    return type(value) == "string" and string.lower(value) or ""
end

-- Which saved character entry is the one logged in: by the add-on's own
-- id for it, else by name and realm when exactly one entry fits.
local function matchCharacter(loot, identity)
    for _, entry in ipairs(loot.characters) do
        for _, alias in ipairs(entry.aliases) do
            if identity.characterId and alias == identity.characterId then return entry, "alias" end
        end
    end
    local found, count = nil, 0
    local name, realm = lower(identity.name), lower(identity.realm)
    if name == "" then return nil end
    local function firstWord(value) return string.match(value, "^(%S+)") or value end
    local single = not string.find(name, " ", 1, true)
    for _, entry in ipairs(loot.characters) do
        local entryName = lower(entry.name)
        -- Forever surnames: "Rook Shepard" is "Rook" where one side has no
        -- surname yet, but never "Rook Ravenstar".
        local sameName = entryName == name
            or ((single or not string.find(entryName, " ", 1, true)) and firstWord(entryName) == firstWord(name))
        local sameRealm = realm == "" or entry.realm == "" or lower(entry.realm) == realm
        if sameName and sameRealm then
            found, count = entry, count + 1
        end
    end
    if count == 1 then return found, "name" end
    return nil
end

local function identity()
    local snapshot = GW.Character and GW.Character.GetCurrentSnapshot and GW.Character.GetCurrentSnapshot()
    if isTable(snapshot) and snapshot.characterId then
        return { characterId = snapshot.characterId, name = snapshot.name, realm = snapshot.realm }
    end
    local name = type(UnitName) == "function" and UnitName("player") or nil
    local realm = type(GetRealmName) == "function" and GetRealmName() or nil
    if type(name) ~= "string" or name == "" then return nil end
    return { name = name, realm = realm }
end

-- The logged-in character's wishlist and market as lookup tables, built
-- once and kept until the next Initialize. nil until the character is
-- known (the first roll can only come after that).
function Sync.Active()
    if Sync.active then return Sync.active end
    local store = inbound()
    local loot = store and isTable(store.loot) and store.loot or nil
    if not loot or not isTable(loot.characters) then return nil end
    local who = identity()
    if not who then return nil end
    local entry, how = matchCharacter(loot, who)
    local active = { matched = entry ~= nil, how = how, character = entry, byKey = {}, baseById = {}, market = nil,
        maxAgeSeconds = loot.boe and loot.boe.maxAgeSeconds or 0, count = 0 }
    if entry then
        for _, item in ipairs(entry.wishlist.items) do
            active.byKey[item.itemKey] = item
            active.count = active.count + 1
            if item.itemKey == "i:" .. item.itemId then active.baseById[item.itemId] = item end
        end
        active.market = entry.marketKey and loot.boe and loot.boe.markets[entry.marketKey] or nil
    end
    -- Only a matched character is cached: until the character snapshot
    -- exists, the next call tries again.
    if entry or (GW.Character and GW.Character.GetCurrentSnapshot and GW.Character.GetCurrentSnapshot()) then
        Sync.active = active
    end
    return active
end

-- The wishlist entry an item matches: the exact variant, or the base item
-- (wanting "Deviate Scale Belt" means any suffix of it).
function Sync.WishlistEntry(itemId, itemKey)
    local active = Sync.Active()
    if not active or not active.matched then return nil end
    return (itemKey and active.byKey[itemKey]) or active.baseById[tonumber(itemId) or 0] or nil
end

-- The estimated auction value of an item on this character's own market,
-- or nil and why not. A suffixed item is valued only by its exact key: a
-- "of the Bear" never borrows the price of another suffix or of the base.
function Sync.BoeValue(itemId, itemKey, now)
    local active = Sync.Active()
    if not active or not active.matched then return nil, "no_character" end
    if not active.market then return nil, "no_market" end
    -- The key must be this item's own: a value is never read under another id.
    local entry = itemKey and validKey(itemKey, tonumber(itemId)) and active.market.items[itemKey] or nil
    if not entry then return nil, "not_listed" end
    now = tonumber(now) or serverTime()
    local age = now - entry.observedAt
    if age < 0 then age = 0 end
    if active.maxAgeSeconds > 0 and age > active.maxAgeSeconds then return nil, "stale" end
    return { value = entry.value, observedAt = entry.observedAt, ageSeconds = age, confidence = entry.confidence }
end

-- Items the game said this character received since the last file. They
-- stop alerting at once; the website confirms it from the next sync.
local MAX_ACQUIRED = 100

function Sync.MarkAcquired(itemKey)
    local store = inbound()
    if not store or type(itemKey) ~= "string" then return false end
    local acquired = isTable(store.lootAcquired) and store.lootAcquired or {}
    local count = 0
    for _ in pairs(acquired) do count = count + 1 end
    if count >= MAX_ACQUIRED then acquired = {} end
    acquired[itemKey] = serverTime()
    store.lootAcquired = acquired
    return true
end

function Sync.IsAcquired(itemKey)
    local store = inbound()
    return store ~= nil and isTable(store.lootAcquired) and store.lootAcquired[itemKey] ~= nil
end

-- For /gw loot: what is loaded and for whom.
function Sync.Status()
    local store = inbound()
    local loot = store and isTable(store.loot) and store.loot or nil
    local active = Sync.Active()
    local watch = 0
    if active and active.market then
        for _ in pairs(active.market.items) do watch = watch + 1 end
    end
    return {
        result = Sync.status and Sync.status.result or "empty", reason = Sync.status and Sync.status.reason or nil,
        loaded = loot ~= nil, revision = loot and loot.revision or nil, generatedAt = loot and loot.generatedAt or nil,
        receivedAt = loot and loot.receivedAt or nil, characters = loot and #loot.characters or 0,
        matched = active ~= nil and active.matched == true, how = active and active.how or nil,
        characterName = active and active.character and active.character.name or nil,
        wanted = active and active.count or 0, market = active and active.market and active.market.name or nil, watch = watch,
    }
end
