local _, GW = ...

GW.AuctionTelemetry = GW.AuctionTelemetry or {}

local MAX_ROWS = 200
local DEDUPE_WINDOW_SECONDS = 5

local function safeCall(func, ...)
    if type(func) ~= "function" then
        return nil
    end

    local ok, value = pcall(func, ...)
    if not ok then
        return nil
    end

    return value
end

local function itemIdFromLink(link)
    if type(link) ~= "string" then
        return nil
    end

    return tonumber(link:match("item:(%d+)"))
end

local function serializeItemKey(itemKey)
    if type(itemKey) ~= "table" then
        return nil
    end

    return {
        itemId = itemKey.itemID,
        itemLevel = itemKey.itemLevel,
        itemSuffix = itemKey.itemSuffix,
        battlePetSpeciesId = itemKey.battlePetSpeciesID,
    }
end

local function rowFingerprint(row)
    return table.concat({
        tostring(row.itemId or (row.itemKey and row.itemKey.itemId) or "?"),
        tostring(row.quantity or row.totalQuantity or 0),
        tostring(row.unitPrice or row.buyoutAmount or row.minPrice or 0),
        tostring(row.minBid or 0),
        tostring(row.itemLevel or (row.itemKey and row.itemKey.itemLevel) or 0),
    }, ":")
end

local function observationFingerprint(mode, rows)
    local parts = { mode }
    for _, row in ipairs(rows) do
        table.insert(parts, "|")
        table.insert(parts, rowFingerprint(row))
    end
    return table.concat(parts)
end

local function queueObservation(mode, rows, metadata)
    if #rows == 0 then
        return nil, "empty_results"
    end

    local now = GetServerTime()
    local fingerprint = observationFingerprint(mode, rows)
    local previous = GW.AuctionTelemetry.lastObservations and GW.AuctionTelemetry.lastObservations[mode] or nil

    if previous and previous.fingerprint == fingerprint and now - previous.capturedAt <= DEDUPE_WINDOW_SECONDS then
        return nil, "duplicate_results"
    end

    GW.AuctionTelemetry.lastObservations = GW.AuctionTelemetry.lastObservations or {}
    GW.AuctionTelemetry.lastObservations[mode] = {
        fingerprint = fingerprint,
        capturedAt = now,
    }

    local payload = {
        schemaVersion = 1,
        observedAt = now,
        mode = mode,
        api = metadata and metadata.api or nil,
        query = metadata and metadata.query or nil,
        totalResults = metadata and metadata.totalResults or #rows,
        truncated = metadata and metadata.truncated or false,
        rows = rows,
    }

    local record, queueError = GW.TelemetryEvents.Queue("auction_observation", payload, {
        capturedAt = now,
    })
    if not record then
        return nil, queueError
    end

    return payload
end

function GW.AuctionTelemetry.CaptureBrowse()
    local api = _G.C_AuctionHouse
    if not api or type(api.GetBrowseResults) ~= "function" then
        return nil, "browse_api_unavailable"
    end

    local results = safeCall(api.GetBrowseResults)
    if type(results) ~= "table" or #results == 0 then
        return nil, "empty_results"
    end

    local rows = {}
    for index, info in ipairs(results) do
        if index > MAX_ROWS then
            break
        end

        if type(info) == "table" then
            table.insert(rows, {
                itemKey = serializeItemKey(info.itemKey),
                itemId = type(info.itemKey) == "table" and info.itemKey.itemID or nil,
                totalQuantity = info.totalQuantity,
                minPrice = info.minPrice,
                appearanceLink = info.appearanceLink,
            })
        end
    end

    return queueObservation("browse", rows, {
        api = "C_AuctionHouse",
        totalResults = #results,
        truncated = #results > MAX_ROWS,
    })
end

function GW.AuctionTelemetry.CaptureCommodity(itemId)
    local api = _G.C_AuctionHouse
    itemId = tonumber(itemId)
    if not itemId or not api
        or type(api.GetNumCommoditySearchResults) ~= "function"
        or type(api.GetCommoditySearchResultInfo) ~= "function" then
        return nil, "commodity_api_unavailable"
    end

    local total = tonumber(safeCall(api.GetNumCommoditySearchResults, itemId)) or 0
    if total < 1 then
        return nil, "empty_results"
    end

    local rows = {}
    for index = 1, math.min(total, MAX_ROWS) do
        local info = safeCall(api.GetCommoditySearchResultInfo, itemId, index)
        if type(info) == "table" then
            table.insert(rows, {
                itemId = info.itemID or itemId,
                quantity = info.quantity,
                unitPrice = info.unitPrice,
                auctionId = info.auctionID,
                timeLeft = info.timeLeft,
            })
        end
    end

    return queueObservation("commodity_search", rows, {
        api = "C_AuctionHouse",
        query = { itemId = itemId },
        totalResults = total,
        truncated = total > MAX_ROWS,
    })
end

function GW.AuctionTelemetry.CaptureItemSearch(itemKey)
    local api = _G.C_AuctionHouse
    if type(itemKey) ~= "table" or not api
        or type(api.GetNumItemSearchResults) ~= "function"
        or type(api.GetItemSearchResultInfo) ~= "function" then
        return nil, "item_search_api_unavailable"
    end

    local total = tonumber(safeCall(api.GetNumItemSearchResults, itemKey)) or 0
    if total < 1 then
        return nil, "empty_results"
    end

    local rows = {}
    for index = 1, math.min(total, MAX_ROWS) do
        local info = safeCall(api.GetItemSearchResultInfo, itemKey, index)
        if type(info) == "table" then
            local link = info.itemLink
            table.insert(rows, {
                itemKey = serializeItemKey(info.itemKey or itemKey),
                itemId = (type(info.itemKey) == "table" and info.itemKey.itemID)
                    or itemKey.itemID
                    or itemIdFromLink(link),
                itemLink = link,
                quantity = info.quantity,
                minBid = info.minBid,
                bidAmount = info.bidAmount,
                buyoutAmount = info.buyoutAmount,
                auctionId = info.auctionID,
                timeLeft = info.timeLeft,
                saleStatus = info.saleStatus,
            })
        end
    end

    return queueObservation("item_search", rows, {
        api = "C_AuctionHouse",
        query = { itemKey = serializeItemKey(itemKey) },
        totalResults = total,
        truncated = total > MAX_ROWS,
    })
end

function GW.AuctionTelemetry.CaptureLegacy()
    if type(_G.GetNumAuctionItems) ~= "function" or type(_G.GetAuctionItemInfo) ~= "function" then
        return nil, "legacy_api_unavailable"
    end

    local ok, batchCount, totalCount = pcall(_G.GetNumAuctionItems, "list")
    if not ok or not batchCount or batchCount < 1 then
        return nil, "empty_results"
    end

    local rows = {}
    for index = 1, math.min(batchCount, MAX_ROWS) do
        local infoOk, name, icon, count, quality, canUse, level, levelColumn, minBid, minIncrement, buyoutAmount, bidAmount, _, _, _, _, saleStatus, itemId, hasAllInfo = pcall(_G.GetAuctionItemInfo, "list", index)
        if infoOk and name then
            local link = type(_G.GetAuctionItemLink) == "function" and safeCall(_G.GetAuctionItemLink, "list", index) or nil
            table.insert(rows, {
                itemId = tonumber(itemId) or itemIdFromLink(link),
                itemLink = link,
                name = name,
                icon = icon,
                quantity = count,
                quality = quality,
                canUse = canUse,
                itemLevel = level,
                levelColumn = levelColumn,
                minBid = minBid,
                minIncrement = minIncrement,
                buyoutAmount = buyoutAmount,
                bidAmount = bidAmount,
                saleStatus = saleStatus,
                hasAllInfo = hasAllInfo,
            })
        end
    end

    return queueObservation("legacy_list", rows, {
        api = "legacy_auction",
        totalResults = tonumber(totalCount) or tonumber(batchCount) or #rows,
        truncated = (tonumber(batchCount) or 0) > MAX_ROWS,
    })
end

local function safeRegister(frame, event)
    pcall(frame.RegisterEvent, frame, event)
end

function GW.AuctionTelemetry:Initialize()
    if self.eventFrame then
        return
    end

    local frame = CreateFrame("Frame")
    safeRegister(frame, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    safeRegister(frame, "ITEM_SEARCH_RESULTS_UPDATED")
    safeRegister(frame, "COMMODITY_SEARCH_RESULTS_UPDATED")
    safeRegister(frame, "AUCTION_ITEM_LIST_UPDATE")

    frame:SetScript("OnEvent", function(_, event, ...)
        if event == "ITEM_SEARCH_RESULTS_UPDATED" then
            GW.AuctionTelemetry.CaptureItemSearch(...)
            return
        end

        if event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
            GW.AuctionTelemetry.CaptureCommodity(...)
            return
        end

        if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
            GW.AuctionTelemetry.CaptureBrowse()
            return
        end

        if event == "AUCTION_ITEM_LIST_UPDATE" then
            GW.AuctionTelemetry.CaptureLegacy()
        end
    end)

    self.eventFrame = frame
end
