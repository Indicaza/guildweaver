local function equal(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function truthy(value, label)
    if not value then
        error((label or "value") .. ": expected truthy value", 2)
    end
end

local now = 6000

GuildweaverDB = nil
GetServerTime = function() return now end
GetCurrentRegion = function() return 1 end
GetBuildInfo = function() return "1.60.1", "60001", "Oct 6 2026", 16001 end
UnitFullName = function() return "Quill", "Realm" end
UnitName = function() return "Quill" end
GetRealmName = function() return "Realm" end
GetGuildInfo = function() return "Holdfast", "Private", 8, "Realm" end
C_AuctionHouse = {
    GetBrowseResults = function()
        return {
            {
                itemKey = { itemID = 765, itemLevel = 0, itemSuffix = 0 },
                totalQuantity = 37,
                minPrice = 3100,
                appearanceLink = nil,
            },
            {
                itemKey = { itemID = 2840, itemLevel = 0, itemSuffix = 0 },
                totalQuantity = 82,
                minPrice = 1800,
            },
        }
    end,
    GetNumCommoditySearchResults = function(itemId)
        if itemId == 765 then return 2 end
        return 0
    end,
    GetCommoditySearchResultInfo = function(_, index)
        if index == 1 then
            return {
                itemID = 765,
                quantity = 10,
                unitPrice = 3100,
                auctionID = 10001,
                timeLeft = 2,
                owners = { "PrivatePlayer" },
            }
        end
        return {
            itemID = 765,
            quantity = 20,
            unitPrice = 3200,
            auctionID = 10002,
            timeLeft = 3,
            owners = { "AnotherPrivatePlayer" },
        }
    end,
    GetNumItemSearchResults = function() return 1 end,
    GetItemSearchResultInfo = function(itemKey)
        return {
            itemKey = itemKey,
            itemLink = "|cff1eff00|Hitem:5191::::::::30:::::::|h[Cruel Barb]|h|r",
            quantity = 1,
            minBid = 90000,
            bidAmount = 0,
            buyoutAmount = 125000,
            auctionID = 20001,
            timeLeft = 1,
            saleStatus = 0,
            owners = { "HiddenOwner" },
            bidder = "HiddenBidder",
        }
    end,
}

local GW = { version = "test" }
assert(loadfile("Data/Store.lua"))("Guildweaver", GW)
assert(loadfile("Systems/TelemetryEvents.lua"))("Guildweaver", GW)
assert(loadfile("Systems/AuctionTelemetry.lua"))("Guildweaver", GW)
GW.Store.Initialize()

local browse = GW.AuctionTelemetry.CaptureBrowse()
truthy(browse, "browse observation")
equal(browse.mode, "browse", "browse mode")
equal(#browse.rows, 2, "browse rows")
equal(browse.rows[1].itemId, 765, "browse item")
equal(browse.rows[1].minPrice, 3100, "browse min price")
equal(GW.TelemetryEvents.GetStats().queued, 1, "browse queued")

local duplicate, duplicateReason = GW.AuctionTelemetry.CaptureBrowse()
equal(duplicate, nil, "duplicate browse suppressed")
equal(duplicateReason, "duplicate_results", "duplicate browse reason")

local commodity = GW.AuctionTelemetry.CaptureCommodity(765)
truthy(commodity, "commodity observation")
equal(commodity.mode, "commodity_search", "commodity mode")
equal(commodity.rows[1].unitPrice, 3100, "commodity unit price")
equal(commodity.rows[1].owners, nil, "owners excluded")
equal(GW.TelemetryEvents.GetStats().queued, 2, "commodity queued")

local itemKey = { itemID = 5191, itemLevel = 24, itemSuffix = 0 }
local itemSearch = GW.AuctionTelemetry.CaptureItemSearch(itemKey)
truthy(itemSearch, "item search observation")
equal(itemSearch.rows[1].buyoutAmount, 125000, "item buyout")
equal(itemSearch.rows[1].itemId, 5191, "item search id")
equal(itemSearch.rows[1].owners, nil, "item owners excluded")
equal(itemSearch.rows[1].bidder, nil, "bidder excluded")
equal(GW.TelemetryEvents.GetStats().queued, 3, "item search queued")

now = now + 6
local later = GW.AuctionTelemetry.CaptureBrowse()
truthy(later, "browse resampled after dedupe window")
equal(GW.TelemetryEvents.GetStats().queued, 4, "later browse queued")

local queue = GW.TelemetryEvents.GetQueue()
local auctionCount = 0
for _, record in pairs(queue.items) do
    if record.envelope.eventType == "auction_observation" then
        auctionCount = auctionCount + 1
    end
end
equal(auctionCount, 4, "auction event count")

print("auction telemetry tests passed")
