local _, GW = ...

GW.TelemetryEvents = GW.TelemetryEvents or {}

local MAX_EVENTS = 512
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

local function ensureQueue()
    local database = GW.Store.GetDatabase()
    database.sync = database.sync or {}
    database.sync.outbound = database.sync.outbound or {}

    local queue = database.sync.outbound.events
    if type(queue) ~= "table" then
        queue = {}
        database.sync.outbound.events = queue
    end

    queue.nextSequence = tonumber(queue.nextSequence) or 0
    queue.dropped = tonumber(queue.dropped) or 0
    queue.items = type(queue.items) == "table" and queue.items or {}
    return queue
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

local function countItems(items)
    local count = 0
    for _ in pairs(items) do
        count = count + 1
    end
    return count
end

local function prune(queue)
    local count = countItems(queue.items)

    while count > MAX_EVENTS do
        local oldestId = nil
        local oldestSequence = math.huge

        for eventId, record in pairs(queue.items) do
            local sequence = tonumber(record and record.sequence) or math.huge
            if sequence < oldestSequence then
                oldestSequence = sequence
                oldestId = eventId
            end
        end

        if not oldestId then
            return
        end

        queue.items[oldestId] = nil
        queue.dropped = queue.dropped + 1
        count = count - 1
    end
end

function GW.TelemetryEvents.Queue(eventType, payload, options)
    if type(eventType) ~= "string" or eventType == "" then
        return nil, "invalid_event_type"
    end

    if type(payload) ~= "table" then
        return nil, "invalid_payload"
    end

    local currentIdentity = identity()
    if not currentIdentity then
        return nil, "character_unavailable"
    end

    local queue = ensureQueue()
    queue.nextSequence = queue.nextSequence + 1

    local sequence = queue.nextSequence
    local capturedAt = options and options.capturedAt or GetServerTime()
    local eventId = currentIdentity.installationId
        .. ":"
        .. currentIdentity.characterId
        .. ":"
        .. tostring(sequence)

    local record = {
        schemaVersion = 1,
        eventId = eventId,
        sequence = sequence,
        createdAt = capturedAt,
        envelope = {
            schemaVersion = 1,
            eventType = eventType,
            capturedAt = capturedAt,
            gameBuild = currentIdentity.gameBuild,
            realm = currentIdentity.realm,
            region = currentIdentity.region,
            installationId = currentIdentity.installationId,
            characterId = currentIdentity.characterId,
            guildId = guildId(),
            payload = payload,
        },
    }

    queue.items[eventId] = record
    prune(queue)
    return record
end

function GW.TelemetryEvents.GetQueue()
    return ensureQueue()
end

function GW.TelemetryEvents.GetStats()
    local queue = ensureQueue()
    return {
        queued = countItems(queue.items),
        capacity = MAX_EVENTS,
        nextSequence = queue.nextSequence,
        dropped = queue.dropped,
    }
end
