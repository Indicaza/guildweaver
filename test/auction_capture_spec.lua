-- Auction house observations against the real TOC in the fake client.

local Env = dofile("test/support/wow_env.lua")

local function equal(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function truthy(value, label)
    if not value then error((label or "value") .. ": expected truthy value", 2) end
end

local ah

local function installAuctionHouse(_, options)
    options = options or {}
    local calls = { search = 0, buy = 0, post = 0, replicateRequest = 0 }
    ah = {
        commodities = {}, items = {}, browse = {}, replicate = {}, calls = calls,
    }
    local G = _G
    G.C_AuctionHouse = {
        -- Anything that searches, buys or posts counts as a call: Guildweaver must never make one.
        SendSearchQuery = function() calls.search = calls.search + 1 end,
        SendBrowseQuery = function() calls.search = calls.search + 1 end,
        PlaceBid = function() calls.buy = calls.buy + 1 end,
        StartCommoditiesPurchase = function() calls.buy = calls.buy + 1 end,
        PostItem = function() calls.post = calls.post + 1 end,
        ReplicateItems = function() calls.replicateRequest = calls.replicateRequest + 1 end,
        GetNumCommoditySearchResults = function(itemId) return #(ah.commodities[itemId] or {}) end,
        GetCommoditySearchResultInfo = function(itemId, index)
            local row = ah.commodities[itemId][index]
            return { itemID = itemId, unitPrice = row[1], quantity = row[2], owners = { "Secret Seller" }, auctionID = index }
        end,
        HasFullCommoditySearchResults = function() return options.partial ~= true end,
        GetNumItemSearchResults = function(itemKey) return #(ah.items[itemKey.itemID] or {}) end,
        GetItemSearchResultInfo = function(itemKey, index)
            local row = ah.items[itemKey.itemID][index]
            return { itemKey = itemKey, buyoutAmount = row[1], quantity = row[2], bidAmount = row[3], owners = { "Seller" }, bidder = "Bidder-Guid" }
        end,
        HasFullItemSearchResults = function() return true end,
        GetBrowseResults = function() return ah.browse end,
        GetNumReplicateItems = function() return #ah.replicate end,
        GetReplicateItemInfo = function(index)
            local row = ah.replicate[index + 1]
            return "Name", 1, row.count, 1, true, 1, 0, row.minBid or 0, 0, row.buyout or 0, 0, false, "Bidder", "Owner", "Owner-Realm", 0, row.itemId, true
        end,
        GetReplicateItemLink = function(index)
            local row = ah.replicate[index + 1]
            return "|cffffffff|Hitem:" .. row.itemId .. "::::::" .. (row.suffix or 0) .. ":::::|h[x]|h|r"
        end,
    }
    G.GetItemInfoInstant = function(itemId) return itemId, "Armor", "Mail", "INVTYPE_CHEST", 1, (itemId >= 10000) and 4 or 7, 1 end
    G.UnitFactionGroup = function() return options.faction or "Alliance", "Alliance" end
    G.C_Map = G.C_Map or {}
    G.C_Map.GetBestMapForUnit = function() return options.mapId or 1453 end
    G.C_AddOns.IsAddOnLoaded = function(name) return name == "Auctionator" and options.auctionator == true end
    return calls
end

local function boot(options)
    local env = Env.new()
    local addon = env:load()
    local calls = installAuctionHouse(env, options)
    env:login()
    env:advance(3)
    return env, addon, calls
end

local function scans(env)
    local found = {}
    for key, record in pairs(env:telemetry()) do
        if key:find("auction_scan:", 1, true) == 1 then table.insert(found, record.envelope) end
    end
    table.sort(found, function(a, b) return a.payload.scanId < b.payload.scanId end)
    return found
end

local function itemsOf(envelope)
    local byId = {}
    for _, item in ipairs(envelope.payload.items) do byId[item.itemId .. ":" .. tostring(item.suffix or 0)] = item end
    return byId
end

-- Commodity and item searches, flushed after a quiet spell ----------------------
do
    local env, _, calls = boot({ auctionator = true })
    env:dispatch("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
    equal(#scans(env), 0, "nothing outside an open auction house")
    env:dispatch("AUCTION_HOUSE_SHOW")
    ah.commodities[2589] = { { 12, 200 }, { 12, 40 }, { 15, 20 }, { 999, 1 } }
    env:dispatch("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
    ah.items[15210] = { { 50000, 1, 40000 }, { 120000, 2 } }
    env:dispatch("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 15210, itemSuffix = -1081, itemLevel = 30 })
    equal(#scans(env), 0, "waits for the player to stop searching")
    env:advance(6)
    local written = scans(env)
    equal(#written, 2, "one event per query kind")
    local commodity, item
    for _, envelope in ipairs(written) do
        if envelope.payload.query.kind == "commodity" then commodity = envelope else item = envelope end
    end
    equal(commodity.eventType, "auction_scan")
    equal(commodity.payload.schemaVersion, 1)
    equal(commodity.payload.market.faction, "alliance")
    equal(commodity.payload.coverage, "items")
    equal(commodity.payload.observedWith.auctionator, true, "notes another AH addon without touching it")
    local cloth = itemsOf(commodity)["2589:0"]
    equal(cloth.quantity, 261)
    equal(cloth.listings, 4)
    equal(cloth.minUnitBuyout, 12)
    equal(cloth.complete, true)
    equal(#cloth.prices, 3, "equal prices merged")
    equal(cloth.prices[1][1], 12)
    equal(cloth.prices[1][2], 240)
    local sword = itemsOf(item)["15210:-1081"]
    truthy(sword, "random suffix kept as its own variant")
    equal(sword.minUnitBuyout, 50000)
    equal(sword.prices[2][1], 60000, "stack buyout became a unit price")
    for _, envelope in ipairs(written) do
        for _, value in ipairs(envelope.payload.items) do
            equal(value.owners, nil, "no seller names")
            equal(value.bidder, nil, "no bidder")
        end
    end

    -- The same results again: nothing new is written.
    env:dispatch("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
    env:advance(6)
    equal(#scans(env), 2, "unchanged results are not re-sent")
    -- A changed price is.
    ah.commodities[2589] = { { 11, 200 } }
    env:dispatch("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
    env:dispatch("AUCTION_HOUSE_CLOSED")
    equal(#scans(env), 3, "closing flushes at once")
    equal(calls.search + calls.buy + calls.post + calls.replicateRequest, 0, "never searched, bought, posted or scanned")
end

-- Partial results are labelled; browse rows never replace a detailed search ------
do
    local env = boot({ partial = true, mapId = 1446 })
    env:dispatch("AUCTION_HOUSE_SHOW")
    ah.commodities[2770] = { { 30, 10 } }
    env:dispatch("COMMODITY_SEARCH_RESULTS_UPDATED", 2770)
    ah.browse = { { itemKey = { itemID = 2770, itemSuffix = 0 }, minPrice = 25, totalQuantity = 99 },
        { itemKey = { itemID = 2771, itemSuffix = 0 }, minPrice = 80, totalQuantity = 5 } }
    env:dispatch("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    env:dispatch("AUCTION_HOUSE_CLOSED")
    local written = scans(env)
    local commodity, browse
    for _, envelope in ipairs(written) do
        if envelope.payload.query.kind == "commodity" then commodity = envelope else browse = envelope end
    end
    equal(commodity.payload.market.faction, "neutral", "Gadgetzan is a Blackwater house")
    equal(commodity.payload.market.basis, "zone")
    equal(itemsOf(commodity)["2770:0"].complete, false, "client said results were partial")
    equal(itemsOf(commodity)["2770:0"].minUnitBuyout, 30, "the detailed search was kept over the browse row")
    equal(itemsOf(browse)["2771:0"].quantity, 5)
    equal(itemsOf(browse)["2771:0"].prices, nil, "browse rows have no listings")
end

-- A full scan someone else ran is read in slices, never in one frame -------------
do
    local env, addon = boot()
    env:dispatch("AUCTION_HOUSE_SHOW")
    for index = 1, 2400 do
        local itemId = 1000 + index % 300
        table.insert(ah.replicate, { itemId = itemId, count = 1 + index % 5, buyout = (100 + index % 7) * (1 + index % 5) })
    end
    table.insert(ah.replicate, { itemId = 15210, count = 1, buyout = 50000, suffix = -1081 })
    table.insert(ah.replicate, { itemId = 15210, count = 1, buyout = 40000, suffix = -1082 })
    table.insert(ah.replicate, { itemId = 5000, count = 1, minBid = 300 })
    env.eventsInFrames = true
    env:dispatch("REPLICATE_ITEM_LIST_UPDATE")
    equal(#scans(env), 0, "not read inside the event")
    local worst = env:advance(3)
    local written = scans(env)
    equal(#written, 1)
    local payload = written[1].payload
    equal(payload.coverage, "full")
    equal(payload.query.kind, "full")
    local items = itemsOf(written[1])
    equal(items["15210:-1081"].minUnitBuyout, 50000)
    equal(items["15210:-1082"].minUnitBuyout, 40000, "suffix variants are not merged")
    equal(items["5000:0"].minUnitBuyout, nil, "bid-only items have no buyout")
    truthy(#items["1001:0"].prices <= 5, "full scans keep a few price points per item")
    truthy(worst < 8, "full scan never takes a long frame (" .. worst .. " ms)")
    local perf = addon.Perf.Category("auction_capture")
    truthy(perf and perf.count > 0, "timed under auction_capture")
end

-- Large full scans are split into bounded events ---------------------------------
do
    local env = boot()
    env:dispatch("AUCTION_HOUSE_SHOW")
    for index = 1, 2500 do table.insert(ah.replicate, { itemId = 20000 + index, count = 1, buyout = 100 }) end
    env:dispatch("REPLICATE_ITEM_LIST_UPDATE")
    env:advance(10)
    local written = scans(env)
    equal(#written, 3, "2500 items in chunks of 1000")
    for _, envelope in ipairs(written) do
        truthy(#envelope.payload.items <= 1000, "bounded chunk")
        equal(envelope.payload.query.chunks, 3)
    end
end

-- Missing or secret APIs: nothing breaks, nothing is recorded ---------------------
do
    local env = boot()
    _G.C_AuctionHouse = nil
    env:dispatch("AUCTION_HOUSE_SHOW")
    env:dispatch("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
    env:dispatch("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    env:dispatch("REPLICATE_ITEM_LIST_UPDATE")
    env:dispatch("AUCTION_HOUSE_CLOSED")
    equal(#scans(env), 0, "no auction API, no data")

    installAuctionHouse(env)
    local secret = setmetatable({}, {})
    _G.issecretvalue = function(value) return value == secret end
    _G.UnitFactionGroup = function() return secret end
    env:dispatch("AUCTION_HOUSE_SHOW")
    ah.commodities[2589] = { { 12, 5 } }
    env:dispatch("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
    env:dispatch("AUCTION_HOUSE_CLOSED")
    equal(#scans(env), 0, "unknown market: nothing recorded rather than guessed")

    _G.UnitFactionGroup = function() return "Horde" end
    env:dispatch("AUCTION_HOUSE_SHOW")
    ah.commodities[2589] = { { secret, 5 }, { 14, 3 } }
    env:dispatch("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
    env:dispatch("AUCTION_HOUSE_CLOSED")
    local written = scans(env)
    equal(#written, 1)
    equal(itemsOf(written[1])["2589:0"].minUnitBuyout, 14, "secret prices skipped")
    equal(written[1].payload.market.faction, "horde")
end

print("auction capture tests passed")
