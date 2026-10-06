local _, GW = ...

GW.InventoryTelemetry = GW.InventoryTelemetry or {}

local REGION_NAMES = {
    [1] = "US",
    [2] = "KR",
    [3] = "EU",
    [4] = "TW",
    [5] = "CN",
}

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

local function collectGameBuild()
    if type(GetBuildInfo) ~= "function" then
        return nil
    end

    local ok, version, build, buildDate, interfaceVersion = pcall(GetBuildInfo)
    if not ok then
        return nil
    end

    return {
        version = version,
        build = build,
        buildDate = buildDate,
        interface = interfaceVersion,
    }
end

local function identity()
    local name, realm = UnitFullName("player")
    name = name or UnitName("player")
    realm = realm or GetRealmName()

    if not name or name == "" then
        return nil
    end

    local characterKey = string.lower((realm or "") .. ":" .. name)
    return {
        realm = realm,
        region = REGION_NAMES[tonumber(safeCall(GetCurrentRegion))],
        installationId = GW.Store.GetInstallationId(),
        characterId = GW.Store.GetCharacterId(characterKey),
        gameBuild = collectGameBuild(),
    }
end

local function guildId()
    if type(GetGuildInfo) ~= "function" then
        return nil
    end

    local name, _, _, realm = GetGuildInfo("player")
    if not name then
        return nil
    end

    return "guild-" .. GW.Store.Fingerprint({
        name = name,
        realm = realm or GetRealmName(),
    })
end

local function containerNumSlots(bag)
    local containerApi = _G.C_Container
    if containerApi and type(containerApi.GetContainerNumSlots) == "function" then
        return tonumber(safeCall(containerApi.GetContainerNumSlots, bag)) or 0
    end

    return tonumber(safeCall(_G.GetContainerNumSlots, bag)) or 0
end

local function modernContainerItem(bag, slot)
    local containerApi = _G.C_Container
    if not containerApi or type(containerApi.GetContainerItemInfo) ~= "function" then
        return nil
    end

    local info = safeCall(containerApi.GetContainerItemInfo, bag, slot)
    if type(info) ~= "table" then
        return nil
    end

    local link = info.hyperlink
    if not link and type(containerApi.GetContainerItemLink) == "function" then
        link = safeCall(containerApi.GetContainerItemLink, bag, slot)
    end

    local itemId = info.itemID
    if not itemId and type(containerApi.GetContainerItemID) == "function" then
        itemId = safeCall(containerApi.GetContainerItemID, bag, slot)
    end
    itemId = tonumber(itemId) or itemIdFromLink(link)

    if not itemId then
        return nil
    end

    return {
        itemId = itemId,
        itemLink = link,
        icon = info.iconFileID,
        count = tonumber(info.stackCount) or 1,
        quality = info.quality,
        isLocked = info.isLocked,
        isBound = info.isBound,
        hasNoValue = info.hasNoValue,
    }
end

local function legacyContainerItem(bag, slot)
    if type(_G.GetContainerItemInfo) ~= "function" then
        return nil
    end

    local ok, icon, count, locked, quality, _, _, link, _, hasNoValue, itemId, isBound = pcall(_G.GetContainerItemInfo, bag, slot)
    if not ok then
        return nil
    end

    if not link and type(_G.GetContainerItemLink) == "function" then
        link = safeCall(_G.GetContainerItemLink, bag, slot)
    end

    itemId = tonumber(itemId) or itemIdFromLink(link)
    if not itemId then
        return nil
    end

    return {
        itemId = itemId,
        itemLink = link,
        icon = icon,
        count = tonumber(count) or 1,
        quality = quality,
        isLocked = locked,
        isBound = isBound,
        hasNoValue = hasNoValue,
    }
end

local function containerItem(bag, slot)
    return modernContainerItem(bag, slot) or legacyContainerItem(bag, slot)
end

local function aggregateItem(target, item)
    local key = tostring(item.itemId)
    local current = target[key]

    if not current then
        current = {
            itemId = item.itemId,
            itemLink = item.itemLink,
            icon = item.icon,
            quality = item.quality,
            count = 0,
            stacks = 0,
            boundCount = 0,
            unboundCount = 0,
        }
        target[key] = current
    end

    local count = tonumber(item.count) or 0
    current.count = current.count + count
    current.stacks = current.stacks + 1

    if item.isBound == true then
        current.boundCount = current.boundCount + count
    else
        current.unboundCount = current.unboundCount + count
    end

    current.itemLink = current.itemLink or item.itemLink
    current.icon = current.icon or item.icon
    current.quality = current.quality or item.quality
end

local function bagLimit()
    return tonumber(_G.NUM_BAG_SLOTS) or 4
end

local function collectBags()
    local aggregated = {}
    local bags = {}
    local maxBag = bagLimit()

    for bag = 0, maxBag do
        local slots = containerNumSlots(bag)
        local used = 0

        for slot = 1, slots do
            local item = containerItem(bag, slot)
            if item then
                used = used + 1
                aggregateItem(aggregated, item)
            end
        end

        table.insert(bags, {
            bag = bag,
            slots = slots,
            used = used,
            free = math.max(0, slots - used),
        })
    end

    local items = {}
    for _, item in pairs(aggregated) do
        table.insert(items, item)
    end

    table.sort(items, function(left, right)
        return tonumber(left.itemId) < tonumber(right.itemId)
    end)

    return bags, items
end

function GW.InventoryTelemetry.Capture(reason)
    local currentIdentity = identity()
    if not currentIdentity then
        return nil, "character_unavailable"
    end

    local capturedAt = GetServerTime()
    local bags, items = collectBags()
    local payload = {
        schemaVersion = 1,
        capturedAt = capturedAt,
        reason = reason or "manual",
        scope = "carried_bags",
        excludes = { "gold", "bank", "mail", "auction_house" },
        bags = bags,
        items = items,
    }

    GW.Store.SetTelemetrySnapshot(
        "inventory_snapshot:" .. currentIdentity.characterId,
        {
            schemaVersion = 1,
            eventType = "inventory_snapshot",
            capturedAt = capturedAt,
            gameBuild = currentIdentity.gameBuild,
            realm = currentIdentity.realm,
            region = currentIdentity.region,
            installationId = currentIdentity.installationId,
            characterId = currentIdentity.characterId,
            guildId = guildId(),
            payload = payload,
        }
    )

    return payload
end

local function safeRegister(frame, event)
    pcall(frame.RegisterEvent, frame, event)
end

function GW.InventoryTelemetry:Initialize()
    if self.eventFrame then
        return
    end

    local frame = CreateFrame("Frame")
    safeRegister(frame, "PLAYER_LOGIN")
    safeRegister(frame, "PLAYER_ENTERING_WORLD")
    safeRegister(frame, "BAG_UPDATE_DELAYED")
    safeRegister(frame, "BAG_UPDATE")

    local capturePending = false
    frame:SetScript("OnEvent", function(_, event)
        if capturePending then
            return
        end

        capturePending = true
        C_Timer.After(0.75, function()
            capturePending = false
            GW.InventoryTelemetry.Capture(event)
        end)
    end)

    self.eventFrame = frame

    C_Timer.After(3.5, function()
        GW.InventoryTelemetry.Capture("INITIAL_DELAY")
    end)
end
