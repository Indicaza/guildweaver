local _, GW = ...

-- Auction house observations. Guildweaver never searches, scans, buys,
-- posts or cancels anything: it only reads results the client already has
-- because the player (or another addon such as Auctionator) asked for them.
--
--   commodity search  C_AuctionHouse.GetCommoditySearchResultInfo   every listing of one commodity
--   item search       C_AuctionHouse.GetItemSearchResultInfo        every listing of one item
--   browse            C_AuctionHouse.GetBrowseResults                lowest price and total per item
--   full scan         C_AuctionHouse.GetReplicateItemInfo           the whole house (when someone ran one)
--   classic page      GetAuctionItemInfo("list", i)                 one page of the classic browse frame
--   classic get-all   GetAuctionItemInfo("list", i), getAll query    the whole house (when someone ran one)
--
-- The classic browse frame (QueryAuctionItems, AUCTION_ITEM_LIST_UPDATE) is
-- what Forever's auction house looks like; the modern API is read too where
-- it exists. QueryAuctionItems is only observed with hooksecurefunc, after
-- the call, to know which query and page a result belongs to: never called,
-- repeated or changed.
--
-- Results are collected while the auction house is open and written to the
-- telemetry queue in a few events (at most MAX_ITEMS items each) when it
-- has been quiet for a few seconds or closes. A full scan is read a slice
-- at a time through the work queue, never in one frame. Seller and bidder
-- names are never read.
GW.AuctionCapture = GW.AuctionCapture or {}

local Globals = _G or {}
local Capture = GW.AuctionCapture
local MAX_ITEMS = 1000
local MAX_PRICE_POINTS = 20
local FULL_SCAN_PRICE_POINTS = 5
local MAX_ROWS_PER_ITEM = 500
local FLUSH_QUIET_SECONDS = 5
local REPEAT_SECONDS = 600
local REPLICATE_STEP = 250
local MAX_REPLICATE_ROWS = 200000
-- The Blackwater (neutral) auction houses: Booty Bay, Gadgetzan, Everlook.
local NEUTRAL_MAPS = { [1434] = true, [1446] = true, [1452] = true }

Capture.MAX_ITEMS = MAX_ITEMS
Capture.MAX_PRICE_POINTS = MAX_PRICE_POINTS

local function isSecret(value)
    if type(Globals.issecretvalue) ~= "function" then
        return false
    end
    local ok, secret = pcall(Globals.issecretvalue, value)
    return ok and secret == true
end

local function scalar(value)
    if value == nil or isSecret(value) then
        return nil
    end
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" then
        return value
    end
    return nil
end

local function number(value)
    value = tonumber(scalar(value))
    if value == nil or value ~= value or value == math.huge or value == -math.huge then
        return nil
    end
    return value
end

local function call(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r = pcall(fn, ...)
    if not ok then
        return nil
    end
    return a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r
end

local function api()
    local ah = Globals.C_AuctionHouse
    return type(ah) == "table" and ah or nil
end

local function serverNow()
    return number(call(Globals.GetServerTime)) or 0
end

local function clock()
    return number(call(Globals.GetTime)) or serverNow()
end

local state = {
    open = false,
    market = nil,
    items = {},      -- variant key -> collected item
    count = 0,
    lastChange = 0,
    flushScheduled = false,
    sent = {},       -- variant key -> { fingerprint, at }
    sentCount = 0,
    sequence = 0,
}
Capture.state = state

local function variantKey(itemId, suffix)
    suffix = number(suffix) or 0
    return suffix ~= 0 and (tostring(itemId) .. ":" .. tostring(suffix)) or tostring(itemId)
end

-- The auction house in use: neutral in the Blackwater towns, otherwise the
-- player's faction. Recorded with how it was decided.
local function readMarket()
    local mapId = nil
    local maps = Globals.C_Map
    if type(maps) == "table" then
        mapId = number(call(maps.GetBestMapForUnit, "player"))
    end
    if mapId and NEUTRAL_MAPS[mapId] then
        return { faction = "neutral", basis = "zone", mapId = mapId }
    end
    local faction = scalar(call(Globals.UnitFactionGroup, "player"))
    faction = type(faction) == "string" and string.lower(faction) or nil
    if faction ~= "alliance" and faction ~= "horde" then
        return nil
    end
    return { faction = faction, basis = "player_faction", mapId = mapId }
end

local function perfCount(name, amount)
    local perf = GW.Perf
    if perf and perf.Count then
        perf.Count(name, amount or 1)
    end
end

-- Price points: cheapest first, equal prices merged, at most `limit`.
local function addPoint(points, unitPrice, quantity, count)
    for _, point in ipairs(points) do
        if point[1] == unitPrice then
            point[2] = point[2] + quantity
            point[3] = (point[3] or 1) + (count or 1)
            return
        end
    end
    table.insert(points, { unitPrice, quantity, count or 1 })
end

local function trimPoints(points, limit)
    table.sort(points, function(a, b) return a[1] < b[1] end)
    while #points > limit do
        table.remove(points)
    end
    return points
end

local scheduleFlush

local function store(entry, quietly)
    local key = variantKey(entry.itemId, entry.suffix)
    if not state.items[key] then
        state.count = state.count + 1
    end
    state.items[key] = entry
    if not quietly then
        state.lastChange = clock()
        scheduleFlush()
    end
end

-- One commodity's listings (all sellers, sorted by price by the client).
function Capture.ReadCommodity(itemId)
    local ah = api()
    itemId = number(itemId)
    if not ah or not itemId then return nil end
    local total = number(call(ah.GetNumCommoditySearchResults, itemId)) or 0
    if total < 1 then return nil end
    local points, quantity, listings, rows = {}, 0, 0, math.min(total, MAX_ROWS_PER_ITEM)
    local minUnit = nil
    for index = 1, rows do
        local info = call(ah.GetCommoditySearchResultInfo, itemId, index)
        if type(info) == "table" then
            local unit = number(info.unitPrice)
            local count = number(info.quantity)
            if unit and count and count > 0 then
                quantity = quantity + count
                listings = listings + 1
                minUnit = minUnit and math.min(minUnit, unit) or unit
                addPoint(points, unit, count, 1)
            end
        end
    end
    if listings == 0 then return nil end
    local full = call(ah.HasFullCommoditySearchResults, itemId) == true and total <= MAX_ROWS_PER_ITEM
    local entry = { itemId = itemId, quantity = quantity, listings = listings, minUnitBuyout = minUnit,
        complete = full, prices = trimPoints(points, MAX_PRICE_POINTS), query = "commodity" }
    store(entry)
    return entry
end

-- One item's listings. Prices are per stack in this API; they become unit
-- prices here so stack and unit prices are never mixed.
function Capture.ReadItem(itemKey)
    local ah = api()
    if not ah or type(itemKey) ~= "table" then return nil end
    local itemId = number(itemKey.itemID)
    if not itemId then return nil end
    local suffix = number(itemKey.itemSuffix) or 0
    local total = number(call(ah.GetNumItemSearchResults, itemKey)) or 0
    if total < 1 then return nil end
    local points, quantity, listings, minUnit = {}, 0, 0, nil
    for index = 1, math.min(total, MAX_ROWS_PER_ITEM) do
        local info = call(ah.GetItemSearchResultInfo, itemKey, index)
        if type(info) == "table" then
            local count = number(info.quantity) or 1
            local buyout = number(info.buyoutAmount)
            if count > 0 then
                quantity = quantity + count
                listings = listings + 1
                if buyout and buyout > 0 then
                    local unit = math.floor(buyout / count + 0.5)
                    minUnit = minUnit and math.min(minUnit, unit) or unit
                    addPoint(points, unit, count, 1)
                end
            end
        end
    end
    if listings == 0 then return nil end
    local full = call(ah.HasFullItemSearchResults, itemKey) == true and total <= MAX_ROWS_PER_ITEM
    local entry = { itemId = itemId, suffix = suffix ~= 0 and suffix or nil, quantity = quantity, listings = listings,
        minUnitBuyout = minUnit, complete = full, prices = trimPoints(points, MAX_PRICE_POINTS), query = "item" }
    store(entry)
    return entry
end

-- Browse rows: the server's lowest price and total quantity per item. No
-- listing detail, so no typical price, but both numbers cover every listing.
function Capture.ReadBrowse(results)
    local ah = api()
    if not ah then return 0 end
    results = type(results) == "table" and results or call(ah.GetBrowseResults)
    if type(results) ~= "table" then return 0 end
    local stored = 0
    for _, row in ipairs(results) do
        local itemKey = type(row) == "table" and row.itemKey or nil
        local itemId = type(itemKey) == "table" and number(itemKey.itemID) or nil
        local minPrice = number(row and row.minPrice)
        local quantity = number(row and row.totalQuantity)
        if itemId and minPrice and quantity and quantity > 0 then
            local suffix = number(itemKey.itemSuffix) or 0
            local key = variantKey(itemId, suffix)
            -- A browse row never replaces a detailed search of the same item.
            local existing = state.items[key]
            if not existing or existing.query == "browse" then
                store({ itemId = itemId, suffix = suffix ~= 0 and suffix or nil, quantity = quantity, minUnitBuyout = minPrice,
                    complete = true, query = "browse" })
                stored = stored + 1
            end
        end
    end
    return stored
end

-- Payloads ---------------------------------------------------------------------

local function fingerprint(entry)
    return table.concat({ tostring(entry.minUnitBuyout), tostring(entry.quantity), tostring(entry.listings) }, ":")
end

local function rememberSent(key, value)
    if not state.sent[key] then
        state.sentCount = state.sentCount + 1
        if state.sentCount > 5000 then
            state.sent = {}
            state.sentCount = 1
        end
    end
    state.sent[key] = value
end

local function snapshotIdentity()
    local character = GW.Character
    local ok, snapshot = pcall(character and character.GetCurrentSnapshot)
    if ok and type(snapshot) == "table" and snapshot.characterId and snapshot.region and snapshot.realm then
        return snapshot
    end
    return nil
end

local function observedWith()
    local addons = Globals.C_AddOns
    local loaded = function(name)
        return type(addons) == "table" and call(addons.IsAddOnLoaded, name) == true or nil
    end
    return { auctionator = loaded("Auctionator"), tsm = loaded("TradeSkillMaster") }
end

-- Writes collected items as auction_scan events (chunks of MAX_ITEMS).
-- Items unchanged since they were last sent (within REPEAT_SECONDS) are
-- left out, so reopening the same search records nothing new.
local function writeScan(items, queryKind, coverage)
    local identity = snapshotIdentity()
    if not identity or not state.market or #items == 0 then
        return 0
    end
    local now = serverNow()
    state.sequence = state.sequence + 1
    local scanBase = string.format("ah-%x-%x-%d", now, math.random(0, 2147483647), state.sequence)
    local written = 0
    local chunks = math.ceil(#items / MAX_ITEMS)
    for chunk = 1, chunks do
        local slice = {}
        for index = (chunk - 1) * MAX_ITEMS + 1, math.min(#items, chunk * MAX_ITEMS) do
            table.insert(slice, items[index])
        end
        local scanId = chunks > 1 and (scanBase .. "-" .. chunk) or scanBase
        local payload = {
            schemaVersion = 1,
            scanId = scanId,
            observedAt = now,
            market = { faction = state.market.faction, basis = state.market.basis, mapId = state.market.mapId },
            query = { kind = queryKind, chunk = chunk, chunks = chunks },
            coverage = coverage,
            observedWith = observedWith(),
            items = slice,
        }
        local envelope = GW.TelemetryEnvelope.Build("auction_scan", payload, {
            capturedAt = now, characterId = identity.characterId, realm = identity.realm,
            region = identity.region, gameBuild = identity.gameBuild,
        })
        if envelope and GW.Store.SetTelemetryEvent("auction_scan:" .. tostring(identity.characterId) .. ":" .. scanId, envelope) then
            written = written + 1
        end
    end
    perfCount("auction_scan_events", written)
    return written
end

local function payloadItem(entry, pointLimit)
    local prices = entry.prices
    if prices and #prices > pointLimit then
        local trimmed = {}
        for index = 1, pointLimit do trimmed[index] = prices[index] end
        prices = trimmed
    end
    return { itemId = entry.itemId, suffix = entry.suffix, quantity = entry.quantity, listings = entry.listings,
        minUnitBuyout = entry.minUnitBuyout, complete = entry.complete, prices = prices,
        name = entry.name, qualityId = entry.qualityId, requiredLevel = entry.requiredLevel }
end

local commitLegacyPages

function Capture.Flush()
    state.flushScheduled = false
    commitLegacyPages()
    if state.count == 0 then
        return 0
    end
    local perf = GW.Perf
    local started = perf and perf.Begin and perf.Begin() or nil
    local now = serverNow()
    local byKind = { commodity = {}, item = {}, browse = {}, page = {} }
    for key, entry in pairs(state.items) do
        local current = fingerprint(entry)
        local previous = state.sent[key]
        if not previous or previous.fingerprint ~= current or now - previous.at > REPEAT_SECONDS then
            rememberSent(key, { fingerprint = current, at = now })
            table.insert(byKind[entry.query] or byKind.item, payloadItem(entry, MAX_PRICE_POINTS))
        else
            perfCount("auction_items_unchanged")
        end
    end
    state.items = {}
    state.count = 0
    local written = 0
    for kind, items in pairs(byKind) do
        if #items > 0 then
            table.sort(items, function(a, b) return a.itemId < b.itemId end)
            written = written + writeScan(items, kind, "items")
        end
    end
    if perf and perf.End then perf.End("auction_capture", started) end
    return written
end

scheduleFlush = function()
    if state.flushScheduled then return end
    local timer = Globals.C_Timer
    if not timer or type(timer.After) ~= "function" then
        return
    end
    state.flushScheduled = true
    local function check()
        if not state.flushScheduled then return end
        -- Wait until FLUSH_QUIET_SECONDS have passed since the last result
        -- (a small tolerance absorbs frame timing).
        local quiet = clock() - state.lastChange
        if not state.open or quiet >= FLUSH_QUIET_SECONDS - 0.1 then
            Capture.Flush()
        else
            timer.After(math.max(0.5, FLUSH_QUIET_SECONDS - quiet), check)
        end
    end
    timer.After(FLUSH_QUIET_SECONDS, check)
end

-- Full scans -----------------------------------------------------------------------

local function suffixFromLink(link)
    if type(link) ~= "string" then return 0 end
    local suffix = link:match("item:%-?%d+:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:(%-?%d+)")
    return tonumber(suffix) or 0
end

local function isEquipment(cache, itemId)
    local known = cache[itemId]
    if known == nil then
        local _, _, _, _, _, classId = call(Globals.GetItemInfoInstant, itemId)
        known = classId == 2 or classId == 4
        cache[itemId] = known
    end
    return known
end

-- Reads a whole-house scan a slice per step through the work queue, then
-- writes it as one full snapshot. `readRow(row)` returns itemId, count,
-- buyout, minBid and a link getter; never a seller or bidder.
local function readFullScan(key, first, last, readRow, queryKind)
    local queue = GW.WorkQueue
    if not state.market or not queue or type(queue.Enqueue) ~= "function" or last < first then return false end
    local market = state.market
    local aggregate, keys, index = {}, {}, first
    local equipment = {}
    queue.Enqueue({
        key = key,
        category = "auction_capture",
        optional = true,
        isStale = function() return state.market ~= market end,
        step = function()
            local stop = math.min(last, index + REPLICATE_STEP - 1)
            for row = index, stop do
                local itemId, count, buyout, minBid, link = readRow(row)
                itemId, count, buyout, minBid = number(itemId), number(count), number(buyout), number(minBid)
                if itemId and count and count > 0 then
                    local suffix = isEquipment(equipment, itemId) and suffixFromLink(scalar(link and link())) or 0
                    local variant = variantKey(itemId, suffix)
                    local entry = aggregate[variant]
                    if not entry then
                        entry = { itemId = itemId, suffix = suffix ~= 0 and suffix or nil, quantity = 0, listings = 0, prices = {}, complete = true }
                        aggregate[variant] = entry
                        table.insert(keys, variant)
                    end
                    entry.quantity = entry.quantity + count
                    entry.listings = entry.listings + 1
                    if buyout and buyout > 0 then
                        local unit = math.floor(buyout / count + 0.5)
                        entry.minUnitBuyout = entry.minUnitBuyout and math.min(entry.minUnitBuyout, unit) or unit
                        addPoint(entry.prices, unit, count, 1)
                    elseif minBid then
                        entry.bidOnly = true
                    end
                end
            end
            index = stop + 1
            if index <= last then return false end
            local items = {}
            for _, variant in ipairs(keys) do
                local entry = aggregate[variant]
                trimPoints(entry.prices, FULL_SCAN_PRICE_POINTS)
                table.insert(items, payloadItem(entry, FULL_SCAN_PRICE_POINTS))
            end
            table.sort(items, function(a, b) return a.itemId < b.itemId end)
            local saved = state.market
            state.market = market
            writeScan(items, queryKind, "full")
            state.market = saved
            perfCount("auction_full_scans")
            return true
        end,
    }, "replace")
    return true
end

-- A modern full scan (REPLICATE_ITEM_LIST_UPDATE). Rows are 0-based.
-- Never started by Guildweaver: only when the player or another addon ran it.
function Capture.ReadReplicate()
    local ah = api()
    if not ah then return false end
    local total = math.min(number(call(ah.GetNumReplicateItems)) or 0, MAX_REPLICATE_ROWS)
    if total < 1 then return false end
    return readFullScan("auction_replicate", 0, total - 1, function(row)
        -- name, texture, count, quality, usable, level, levelType, minBid, minIncrement,
        -- buyout, bidAmount, highBidder, bidderFullName, owner, ownerFullName, saleStatus, itemID, hasAllInfo
        local _, _, count, _, _, _, _, minBid, _, buyout, _, _, _, _, _, _, itemId = call(ah.GetReplicateItemInfo, row)
        return itemId, count, buyout, minBid, function() return call(ah.GetReplicateItemLink, row) end
    end, "full")
end

-- Classic browse frame ------------------------------------------------------------------

local LEGACY_PAGE = 50
local GETALL_QUIET_SECONDS = 3
local legacy = { query = nil, hooked = false, scan = nil, getAllAt = nil, getAllScheduled = false }
Capture.legacy = legacy

local function hookQueries()
    if legacy.hooked or type(Globals.hooksecurefunc) ~= "function" or type(Globals.QueryAuctionItems) ~= "function" then return end
    legacy.hooked = pcall(Globals.hooksecurefunc, "QueryAuctionItems", function(text, minLevel, maxLevel, page, usable, rarity, getAll, exactMatch)
        legacy.query = {
            signature = table.concat({ tostring(scalar(text) or ""), tostring(number(minLevel) or ""), tostring(number(maxLevel) or ""),
                usable and "1" or "0", tostring(number(rarity) or ""), exactMatch and "1" or "0" }, "|"),
            page = number(page) or 0,
            getAll = getAll == true,
        }
    end) == true
end

local function legacyRow(index)
    -- name, texture, count, quality, canUse, level, levelColHeader, minBid, minIncrement,
    -- buyoutPrice, bidAmount, highBidder, bidderFullName, owner, ownerFullName, saleStatus, itemId, hasAllInfo
    local name, _, count, quality, _, level, _, minBid, _, buyout, _, _, _, _, _, _, itemId = call(Globals.GetAuctionItemInfo, "list", index)
    return name, count, quality, level, minBid, buyout, itemId
end

-- The pages of one query, merged. An item is complete once every page of
-- its query was seen (or the whole result fit on one page).
commitLegacyPages = function()
    local scan = legacy.scan
    legacy.scan = nil
    if not scan or scan.pageCount == 0 then return end
    local pagesNeeded = math.max(1, math.ceil((scan.total or 0) / LEGACY_PAGE))
    local complete = (scan.signature ~= nil and scan.pageCount >= pagesNeeded) or (scan.pageCount == 1 and (scan.total or 0) <= scan.firstBatch)
    local merged, order = {}, {}
    for _, rows in pairs(scan.pages) do
        for key, row in pairs(rows) do
            local entry = merged[key]
            if not entry then
                entry = { itemId = row.itemId, suffix = row.suffix, quantity = 0, listings = 0, prices = {}, name = row.name,
                    qualityId = row.qualityId, requiredLevel = row.requiredLevel, query = "page" }
                merged[key] = entry
                table.insert(order, key)
            end
            entry.quantity = entry.quantity + row.quantity
            entry.listings = entry.listings + row.listings
            if row.minUnitBuyout then entry.minUnitBuyout = entry.minUnitBuyout and math.min(entry.minUnitBuyout, row.minUnitBuyout) or row.minUnitBuyout end
            for _, point in ipairs(row.prices) do addPoint(entry.prices, point[1], point[2], point[3]) end
        end
    end
    for _, key in ipairs(order) do
        local entry = merged[key]
        entry.complete = complete
        trimPoints(entry.prices, MAX_PRICE_POINTS)
        -- A detailed modern search of the same item is never replaced.
        local existing = state.items[key]
        if not existing or existing.query == "page" or existing.query == "browse" then store(entry, true) end
    end
end

local function readLegacyAll(total)
    return readFullScan("auction_getall", 1, total, function(row)
        local _, count, _, _, minBid, buyout, itemId = legacyRow(row)
        return itemId, count, buyout, minBid, function() return call(Globals.GetAuctionItemLink, "list", row) end
    end, "getall")
end

-- A "get all" scan fills the list over several updates; it is read once
-- the updates stop.
local function scheduleGetAll()
    legacy.getAllAt = clock()
    if legacy.getAllScheduled then return end
    local timer = Globals.C_Timer
    if not timer or type(timer.After) ~= "function" then return end
    legacy.getAllScheduled = true
    local function check()
        if not state.open then legacy.getAllScheduled = false return end
        local quiet = clock() - legacy.getAllAt
        if quiet >= GETALL_QUIET_SECONDS - 0.1 then
            legacy.getAllScheduled = false
            local batch = number(call(Globals.GetNumAuctionItems, "list")) or 0
            readLegacyAll(math.min(batch, MAX_REPLICATE_ROWS))
        else
            timer.After(math.max(0.5, GETALL_QUIET_SECONDS - quiet), check)
        end
    end
    timer.After(GETALL_QUIET_SECONDS, check)
end

-- One page of the classic browse frame (at most 50 rows): read at once.
function Capture.ReadLegacyList()
    hookQueries()
    local batch, total = call(Globals.GetNumAuctionItems, "list")
    batch, total = number(batch) or 0, number(total) or 0
    if batch < 1 then return 0 end
    local query = legacy.query
    if (query and query.getAll) or batch > LEGACY_PAGE * 2 then
        scheduleGetAll()
        return 0
    end
    local signature = query and query.signature or nil
    local page = query and query.page or 0
    local scan = legacy.scan
    if not scan or not signature or scan.signature ~= signature then
        commitLegacyPages()
        scan = { signature = signature, pages = {}, pageCount = 0, firstBatch = batch }
        legacy.scan = scan
    end
    scan.total = total
    local rows, equipment = {}, {}
    for index = 1, batch do
        local name, count, quality, level, _, buyout, itemId = legacyRow(index)
        itemId, count, buyout = number(itemId), number(count), number(buyout)
        if itemId and count and count > 0 then
            local suffix = isEquipment(equipment, itemId) and suffixFromLink(scalar(call(Globals.GetAuctionItemLink, "list", index))) or 0
            local key = variantKey(itemId, suffix)
            local row = rows[key]
            if not row then
                row = { itemId = itemId, suffix = suffix ~= 0 and suffix or nil, quantity = 0, listings = 0, prices = {},
                    name = type(scalar(name)) == "string" and string.sub(name, 1, 120) or nil, qualityId = number(quality), requiredLevel = number(level) }
                rows[key] = row
            end
            row.quantity = row.quantity + count
            row.listings = row.listings + 1
            if buyout and buyout > 0 then
                local unit = math.floor(buyout / count + 0.5)
                row.minUnitBuyout = row.minUnitBuyout and math.min(row.minUnitBuyout, unit) or unit
                addPoint(row.prices, unit, count, 1)
            end
        end
    end
    -- The same page again (item details arriving) replaces, never adds.
    if not scan.pages[page] then scan.pageCount = scan.pageCount + 1 end
    scan.pages[page] = rows
    state.lastChange = clock()
    scheduleFlush()
    return batch
end

-- Events -----------------------------------------------------------------------------

local handlers = {
    AUCTION_HOUSE_SHOW = function()
        state.open = true
        state.market = readMarket()
        hookQueries()
    end,
    AUCTION_HOUSE_CLOSED = function()
        state.open = false
        Capture.Flush()
    end,
    COMMODITY_SEARCH_RESULTS_UPDATED = function(itemId) Capture.ReadCommodity(itemId) end,
    ITEM_SEARCH_RESULTS_UPDATED = function(itemKey) Capture.ReadItem(itemKey) end,
    AUCTION_HOUSE_BROWSE_RESULTS_UPDATED = function() Capture.ReadBrowse() end,
    AUCTION_HOUSE_BROWSE_RESULTS_ADDED = function(added) Capture.ReadBrowse(added) end,
    REPLICATE_ITEM_LIST_UPDATE = function() Capture.ReadReplicate() end,
    AUCTION_ITEM_LIST_UPDATE = function() Capture.ReadLegacyList() end,
}

function Capture.HandleEvent(event, ...)
    local handler = handlers[event]
    if not handler then return end
    if event ~= "AUCTION_HOUSE_SHOW" and not state.open then return end
    if event ~= "AUCTION_HOUSE_SHOW" and event ~= "AUCTION_HOUSE_CLOSED" and not state.market then return end
    local perf = GW.Perf
    local started = perf and perf.Begin and perf.Begin() or nil
    pcall(handler, ...)
    if perf and perf.End then perf.End("auction_event", started) end
end

function Capture:Initialize()
    if self.frame or type(Globals.CreateFrame) ~= "function" then
        return
    end
    local frame = Globals.CreateFrame("Frame")
    local registered = 0
    for event in pairs(handlers) do
        local ok, result = pcall(frame.RegisterEvent, frame, event)
        if ok and result ~= false then
            registered = registered + 1
        end
    end
    self.supportedEvents = registered
    frame:SetScript("OnEvent", function(_, event, ...) Capture.HandleEvent(event, ...) end)
    self.frame = frame
    hookQueries()
end

GW.AuctionCapture:Initialize()
