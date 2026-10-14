local _, GW = ...

GW.Store = GW.Store or {}

local MAX_TELEMETRY_STREAMS = 4096
local MAX_CATALOG_STREAMS = 1500
local CATALOG_EVENT_TYPES = { item_definition = true, game_item_definition = true }
local FINGERPRINT_IGNORED_KEYS = {
    capturedAt = true,
    reason = true,
}

local defaults = {
    schemaVersion = 4,
    characters = {},
    meta = {
        installationId = nil,
        characterIds = {},
        capture = {
            sessionId = nil,
            startedAt = nil,
            reloadPending = false,
        },
    },
    sync = {
        inbound = {
            quests = {
                revision = 0,
                updatedAt = nil,
                items = {},
            },
        },
        outbound = {
            telemetry = {},
            questActions = {},
            nextQuestActionId = 0,
        },
    },
    ui = {
        mainFrame = {
            point = "CENTER",
            relativePoint = "CENTER",
            x = 0,
            y = 0,
        },
    },
}

local function applyDefaults(source, target)
    for key, value in pairs(source) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then
                target[key] = {}
            end
            applyDefaults(value, target[key])
        elseif target[key] == nil then
            target[key] = value
        end
    end
end

local function generateId(prefix)
    local now = type(GetServerTime) == "function" and GetServerTime() or 0
    local randomA = math.random(0, 2147483647)
    local randomB = math.random(0, 2147483647)
    return string.format("%s-%x-%x-%x", prefix, now, randomA, randomB)
end

local function appendStable(parts, value, ignoredKeys, depth)
    local valueType = type(value)

    if depth > 24 then
        table.insert(parts, "<depth>")
        return
    end

    if valueType ~= "table" then
        table.insert(parts, valueType)
        table.insert(parts, ":")
        table.insert(parts, tostring(value))
        table.insert(parts, ";")
        return
    end

    local keys = {}
    for key in pairs(value) do
        if not ignoredKeys or not ignoredKeys[key] then
            table.insert(keys, key)
        end
    end

    table.sort(keys, function(left, right)
        local leftType = type(left)
        local rightType = type(right)
        if leftType == rightType then
            return tostring(left) < tostring(right)
        end
        return leftType < rightType
    end)

    table.insert(parts, "{")
    for _, key in ipairs(keys) do
        appendStable(parts, key, nil, depth + 1)
        appendStable(parts, value[key], ignoredKeys, depth + 1)
    end
    table.insert(parts, "}")
end

local function fingerprint(value)
    local parts = {}
    appendStable(parts, value, FINGERPRINT_IGNORED_KEYS, 0)
    local serialized = table.concat(parts)
    local hash = 5381

    for index = 1, #serialized do
        hash = (hash * 33 + string.byte(serialized, index)) % 4294967296
    end

    return string.format("%08x", hash)
end

local function telemetryTier(record)
    if type(record) == "table" and (record.tier == "catalog"
        or CATALOG_EVENT_TYPES[record.envelope and record.envelope.eventType]) then
        return 0
    end
    return type(record) == "table" and record.kind == "event" and 1 or 2
end

local function pruneTelemetry(outbound, protectedKey)
    local count, catalogCount = 0, 0
    for _, record in pairs(outbound) do
        local tier = telemetryTier(record)
        count = count + 1
        if tier == 0 then catalogCount = catalogCount + 1 end
    end
    if count <= MAX_TELEMETRY_STREAMS and catalogCount <= MAX_CATALOG_STREAMS then return end
    local candidates = {}
    for key, record in pairs(outbound) do
        if key ~= protectedKey then
            candidates[#candidates + 1] = { key = key, tier = telemetryTier(record), timestamp = tonumber(record and record.updatedAt) or 0 }
        end
    end
    table.sort(candidates, function(a, b)
        if a.tier ~= b.tier then return a.tier < b.tier end
        if a.timestamp ~= b.timestamp then return a.timestamp < b.timestamp end
        return a.key < b.key
    end)
    for _, candidate in ipairs(candidates) do
        if count <= MAX_TELEMETRY_STREAMS and catalogCount <= MAX_CATALOG_STREAMS then break end
        local record = outbound[candidate.key]
        if type(record) == "table" and record.kind == "state" then
            local revisions = GuildweaverDB.sync.telemetryRevisions or {}
            GuildweaverDB.sync.telemetryRevisions = revisions
            revisions[candidate.key] = math.max(tonumber(revisions[candidate.key]) or 0, tonumber(record.revision) or 0)
        end
        outbound[candidate.key] = nil
        count = count - 1
        if candidate.tier == 0 then catalogCount = catalogCount - 1 end
    end
end

local function captureMeta()
    GuildweaverDB.meta = GuildweaverDB.meta or {}
    GuildweaverDB.meta.capture = GuildweaverDB.meta.capture or {}
    return GuildweaverDB.meta.capture
end

function GW.Store.Initialize()
    if type(GuildweaverDB) ~= "table" then
        GuildweaverDB = {}
    end

    applyDefaults(defaults, GuildweaverDB)
    GuildweaverDB.schemaVersion = defaults.schemaVersion
    GuildweaverDB.meta = GuildweaverDB.meta or {}
    GuildweaverDB.meta.characterIds = GuildweaverDB.meta.characterIds or {}
    GuildweaverDB.meta.capture = GuildweaverDB.meta.capture or {}
    GuildweaverDB.meta.addonVersion = GW.version
    GuildweaverDB.meta.characterFingerprints = GuildweaverDB.meta.characterFingerprints or {}

    -- Whole character snapshots are no longer sent; each data type has its
    -- own telemetry stream. Drop what older versions left for the bridge.
    GuildweaverDB.sync.outbound.characters = nil
    for streamKey in pairs(GuildweaverDB.sync.outbound.telemetry) do
        if string.find(streamKey, "character_snapshot:", 1, true) == 1 then
            GuildweaverDB.sync.outbound.telemetry[streamKey] = nil
        end
    end
end

function GW.Store.GetDatabase()
    return GuildweaverDB
end

function GW.Store.GetInstallationId()
    if not GuildweaverDB.meta.installationId then
        GuildweaverDB.meta.installationId = generateId("install")
    end

    return GuildweaverDB.meta.installationId
end

function GW.Store.GetCharacterId(characterKey)
    local ids = GuildweaverDB.meta.characterIds
    if not ids[characterKey] then
        ids[characterKey] = generateId("character")
    end

    return ids[characterKey]
end

function GW.Store.GetCharacterSnapshot(characterKey)
    return GuildweaverDB.characters[characterKey]
end

function GW.Store.Fingerprint(value)
    return fingerprint(value)
end

function GW.Store.BeginCaptureSession()
    local capture = captureMeta()

    if capture.sessionId and capture.reloadPending then
        capture.reloadPending = false
        return capture.sessionId, true
    end

    if capture.sessionId then
        return capture.sessionId, false
    end

    capture.sessionId = generateId("session")
    capture.startedAt = type(GetServerTime) == "function" and GetServerTime() or 0
    capture.reloadPending = false
    return capture.sessionId, false
end

function GW.Store.GetCaptureSession()
    local capture = captureMeta()
    return capture.sessionId, capture.startedAt
end

function GW.Store.MarkCaptureReloadPending()
    captureMeta().reloadPending = true
end

function GW.Store.IsCaptureReloadPending()
    return captureMeta().reloadPending == true
end

function GW.Store.EndCaptureSession()
    local capture = captureMeta()
    local sessionId = capture.sessionId
    capture.sessionId = nil
    capture.startedAt = nil
    capture.reloadPending = false
    return sessionId
end

-- The latest local snapshot, which the telemetry domains read from. Returns
-- whether its stable data changed.
function GW.Store.SetCharacterSnapshot(characterKey, snapshot)
    GuildweaverDB.characters[characterKey] = snapshot

    local fingerprints = GuildweaverDB.meta.characterFingerprints
    local nextFingerprint = fingerprint(snapshot)
    if fingerprints[characterKey] == nextFingerprint then
        return false
    end
    fingerprints[characterKey] = nextFingerprint
    return true
end

-- The last revision of every state stream, kept apart from the outbound
-- records so a stream that was pruned and recreated continues its revisions
-- instead of restarting at 1 (which the bridge would read as already sent).
local function telemetryRevisions()
    GuildweaverDB.sync.telemetryRevisions = GuildweaverDB.sync.telemetryRevisions or {}
    return GuildweaverDB.sync.telemetryRevisions
end

function GW.Store.SetTelemetrySnapshot(streamKey, envelope)
    local outbound = GuildweaverDB.sync.outbound.telemetry
    local existing = outbound[streamKey]
    local nextFingerprint = fingerprint(envelope.payload)

    if existing and existing.fingerprint == nextFingerprint then
        return false
    end

    local revisions = telemetryRevisions()
    local revision = math.max(existing and tonumber(existing.revision) or 0, tonumber(revisions[streamKey]) or 0)
    revisions[streamKey] = revision + 1
    outbound[streamKey] = {
        kind = "state",
        tier = CATALOG_EVENT_TYPES[envelope.eventType] and "catalog" or "character",
        revision = revision + 1,
        updatedAt = envelope.capturedAt,
        fingerprint = nextFingerprint,
        envelope = envelope,
    }
    pruneTelemetry(outbound, streamKey)
    return true
end

function GW.Store.SetTelemetryEvent(streamKey, envelope)
    local outbound = GuildweaverDB.sync.outbound.telemetry
    local existing = outbound[streamKey]
    local nextFingerprint = fingerprint(envelope.payload)

    if existing and existing.fingerprint == nextFingerprint then
        return false
    end

    local revision = existing and tonumber(existing.revision) or 0
    outbound[streamKey] = {
        kind = "event",
        revision = revision + 1,
        updatedAt = envelope.capturedAt,
        fingerprint = nextFingerprint,
        envelope = envelope,
    }
    pruneTelemetry(outbound, streamKey)
    return true
end

function GW.Store.GetTelemetryStatus()
    local outbound = GuildweaverDB and GuildweaverDB.sync and GuildweaverDB.sync.outbound and GuildweaverDB.sync.outbound.telemetry or {}
    local streams = {}

    for streamKey, record in pairs(outbound) do
        table.insert(streams, {
            streamKey = streamKey,
            kind = record.kind or "state",
            revision = tonumber(record.revision) or 0,
            updatedAt = record.updatedAt,
            eventType = record.envelope and record.envelope.eventType or nil,
            schemaVersion = record.envelope and record.envelope.schemaVersion or nil,
        })
    end

    table.sort(streams, function(left, right)
        return tostring(left.streamKey) < tostring(right.streamKey)
    end)

    return {
        count = #streams,
        limit = MAX_TELEMETRY_STREAMS,
        streams = streams,
    }
end

function GW.Store.GetMainFramePosition()
    return GuildweaverDB.ui.mainFrame
end

function GW.Store.SetMainFramePosition(point, relativePoint, x, y)
    local position = GuildweaverDB.ui.mainFrame
    position.point = point
    position.relativePoint = relativePoint
    position.x = x
    position.y = y
end

function GW.Store.ResetMainFramePosition()
    local position = GuildweaverDB.ui.mainFrame
    position.point = defaults.ui.mainFrame.point
    position.relativePoint = defaults.ui.mainFrame.relativePoint
    position.x = 0
    position.y = 0
end