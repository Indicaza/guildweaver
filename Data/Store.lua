local _, GW = ...

GW.Store = GW.Store or {}

local MAX_TELEMETRY_STREAMS = 64
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
            characters = {},
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

local function pruneTelemetry(outbound)
    local count = 0
    for _ in pairs(outbound) do
        count = count + 1
    end

    while count > MAX_TELEMETRY_STREAMS do
        local oldestKey = nil
        local oldestTimestamp = math.huge

        for key, record in pairs(outbound) do
            local timestamp = tonumber(record and record.updatedAt) or 0
            if timestamp < oldestTimestamp then
                oldestTimestamp = timestamp
                oldestKey = key
            end
        end

        if not oldestKey then
            return
        end

        outbound[oldestKey] = nil
        count = count - 1
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

function GW.Store.SetCharacterSnapshot(characterKey, snapshot)
    GuildweaverDB.characters[characterKey] = snapshot

    local outbound = GuildweaverDB.sync.outbound.characters
    local existing = outbound[characterKey]
    local nextFingerprint = fingerprint(snapshot)

    if existing and existing.fingerprint == nextFingerprint then
        return false
    end

    local revision = existing and tonumber(existing.revision) or 0
    outbound[characterKey] = {
        revision = revision + 1,
        updatedAt = snapshot.capturedAt,
        fingerprint = nextFingerprint,
        payload = snapshot,
    }

    return true
end

function GW.Store.SetTelemetrySnapshot(streamKey, envelope)
    local outbound = GuildweaverDB.sync.outbound.telemetry
    local existing = outbound[streamKey]
    local nextFingerprint = fingerprint(envelope.payload)

    if existing and existing.fingerprint == nextFingerprint then
        return false
    end

    local revision = existing and tonumber(existing.revision) or 0
    outbound[streamKey] = {
        kind = "state",
        revision = revision + 1,
        updatedAt = envelope.capturedAt,
        fingerprint = nextFingerprint,
        envelope = envelope,
    }
    pruneTelemetry(outbound)
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
    pruneTelemetry(outbound)
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