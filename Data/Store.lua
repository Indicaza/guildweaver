local _, GW = ...

GW.Store = GW.Store or {}

local MAX_TELEMETRY_STREAMS = 4096
local FINGERPRINT_IGNORED_KEYS = {
    capturedAt = true,
    reason = true,
}
-- The local snapshot's change detection leaves out recipe lists: they are
-- versioned by the profession_snapshot stream, and serializing hundreds of
-- recipes on every character capture was a large part of its cost.
local CHARACTER_FINGERPRINT_IGNORED_KEYS = {
    capturedAt = true,
    reason = true,
    recipes = true,
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

-- Fingerprints serialize a value in a stable key order and hash it (djb2,
-- mod 2^32). The exact byte sequence and hash are a contract: stored records
-- and the bridge compare fingerprints across versions, so any change here
-- would make every stream look changed once. The implementation below is
-- optimized (no per-scalar table.insert, no tostring inside the sort
-- comparator, four bytes hashed per modulo) but produces identical output;
-- test/fingerprint_spec.lua pins it against the original algorithm.
local parts = {}
local partCount = 0

local function push(value)
    partCount = partCount + 1
    parts[partCount] = value
end

-- The original comparator: by type name, then by tostring(key).
local function mixedKeyBefore(left, right)
    if left.keyType == right.keyType then
        return left.sortKey < right.sortKey
    end
    return left.keyType < right.keyType
end

-- Key arrays are reused per nesting depth (a parent finishes iterating its
-- keys only after its children, which use the next depth).
local keyPool = {}
local keyPoolSizes = {}

local function keyArray(depth, size)
    local keys = keyPool[depth]
    if not keys then
        keys = {}
        keyPool[depth] = keys
    end
    for index = size + 1, keyPoolSizes[depth] or 0 do
        keys[index] = nil
    end
    keyPoolSizes[depth] = size
    return keys
end

local appendStable

local function appendScalar(valueType, value)
    push(valueType)
    push(":")
    push(tostring(value))
    push(";")
end

local function isInteger(value)
    -- tostring uses "%.14g": integers below 1e14 round-trip exactly.
    return value == math.floor(value) and value > -1e14 and value < 1e14
end

appendStable = function(value, ignoredKeys, depth)
    local valueType = type(value)

    if depth > 24 then
        push("<depth>")
        return
    end

    if valueType ~= "table" then
        appendScalar(valueType, value)
        return
    end

    -- Classify the keys: all strings and all integers have fast paths that
    -- sort plain strings with the default comparator; anything else uses
    -- the general (allocating) path.
    local keyCount = 0
    local allStrings = true
    local allIntegers = true
    for key in pairs(value) do
        if not ignoredKeys or not ignoredKeys[key] then
            keyCount = keyCount + 1
            local keyType = type(key)
            if keyType ~= "string" then
                allStrings = false
            end
            if keyType ~= "number" or not isInteger(key) then
                allIntegers = false
            end
        end
    end

    push("{")
    if keyCount == 0 then
        push("}")
        return
    end

    if allStrings or allIntegers then
        local keys = keyArray(depth, keyCount)
        local index = 0
        for key in pairs(value) do
            if not ignoredKeys or not ignoredKeys[key] then
                index = index + 1
                keys[index] = allStrings and key or tostring(key)
            end
        end
        if keyCount > 1 then
            table.sort(keys)
        end
        local keyType = allStrings and "string" or "number"
        -- Keys are serialized one level deeper, so they hit the depth limit
        -- too, exactly as in the original.
        local keyTooDeep = depth + 1 > 24
        for position = 1, keyCount do
            local sortKey = keys[position]
            local key = allStrings and sortKey or tonumber(sortKey)
            if keyTooDeep then
                push("<depth>")
            else
                push(keyType)
                push(":")
                push(sortKey)
                push(";")
            end
            appendStable(value[key], ignoredKeys, depth + 1)
        end
        push("}")
        return
    end

    local entries = {}
    local count = 0
    for key in pairs(value) do
        if not ignoredKeys or not ignoredKeys[key] then
            count = count + 1
            entries[count] = { key = key, keyType = type(key), sortKey = tostring(key) }
        end
    end
    table.sort(entries, mixedKeyBefore)
    for index = 1, count do
        local entry = entries[index]
        appendStable(entry.key, nil, depth + 1)
        appendStable(value[entry.key], ignoredKeys, depth + 1)
    end
    push("}")
end

local byte = string.byte
local MODULUS = 4294967296

-- djb2 over the serialized bytes. Four steps fit in a double exactly
-- (2^32 * 33^4 + 255 * 33^3 ... < 2^53), so the modulo is applied every
-- four bytes instead of every byte.
local function hashString(serialized)
    local hash = 5381
    local length = #serialized
    local index = 1
    while index + 7 <= length do
        local a, b, c, d, e, f, g, h = byte(serialized, index, index + 7)
        hash = ((((hash * 33 + a) * 33 + b) * 33 + c) * 33 + d) % MODULUS
        hash = ((((hash * 33 + e) * 33 + f) * 33 + g) * 33 + h) % MODULUS
        index = index + 8
    end
    while index <= length do
        hash = (hash * 33 + byte(serialized, index)) % MODULUS
        index = index + 1
    end
    return hash
end

local function fingerprint(value, ignoredKeys)
    local perf = GW.Perf
    local started = perf and perf.Begin and perf.Begin() or nil
    partCount = 0
    appendStable(value, ignoredKeys or FINGERPRINT_IGNORED_KEYS, 0)
    local serialized = table.concat(parts, "", 1, partCount)
    -- Release references from a large serialization instead of keeping them
    -- alive until the next call.
    if partCount > 4096 then
        parts = {}
    end
    partCount = 0
    local result = string.format("%08x", hashString(serialized))
    if perf and perf.End then
        perf.End("fingerprint", started)
        perf.Count("fingerprint_bytes", #serialized)
    end
    return result
end

-- Resumable fingerprints ---------------------------------------------------------
--
-- The same serialization and hash as fingerprint(), computed by an explicit
-- traversal that can stop after any number of pieces and resume later, so a
-- large payload (a full recipe book) can be fingerprinted across frames. djb2
-- is sequential, so hashing piece by piece equals hashing the concatenation.

local function hashAppend(hash, piece)
    local length = #piece
    local index = 1
    while index + 7 <= length do
        local a, b, c, d, e, f, g, h = byte(piece, index, index + 7)
        hash = ((((hash * 33 + a) * 33 + b) * 33 + c) * 33 + d) % MODULUS
        hash = ((((hash * 33 + e) * 33 + f) * 33 + g) * 33 + h) % MODULUS
        index = index + 8
    end
    while index <= length do
        hash = (hash * 33 + byte(piece, index)) % MODULUS
        index = index + 1
    end
    return hash
end

local function sortedKeys(value, ignoredKeys)
    local keys = {}
    local count = 0
    local allStrings = true
    local allIntegers = true
    for key in pairs(value) do
        if not ignoredKeys or not ignoredKeys[key] then
            count = count + 1
            keys[count] = key
            local keyType = type(key)
            if keyType ~= "string" then
                allStrings = false
            end
            if keyType ~= "number" or not isInteger(key) then
                allIntegers = false
            end
        end
    end
    if allStrings then
        table.sort(keys)
        return keys, count
    end
    local entries = {}
    for index = 1, count do
        local key = keys[index]
        entries[index] = { key = key, keyType = type(key), sortKey = tostring(key) }
    end
    table.sort(entries, allIntegers and function(left, right)
        return left.sortKey < right.sortKey
    end or mixedKeyBefore)
    for index = 1, count do
        keys[index] = entries[index].key
    end
    return keys, count
end

local function resumableEmit(state, piece)
    state.hash = hashAppend(state.hash, piece)
    state.bytes = state.bytes + #piece
    state.pieces = state.pieces + 1
end

local function resumableVisit(state, value, ignoredKeys, depth)
    if depth > 24 then
        resumableEmit(state, "<depth>")
        return
    end
    local valueType = type(value)
    if valueType ~= "table" then
        resumableEmit(state, valueType)
        resumableEmit(state, ":")
        resumableEmit(state, tostring(value))
        resumableEmit(state, ";")
        return
    end
    resumableEmit(state, "{")
    local keys, count = sortedKeys(value, ignoredKeys)
    local stack = state.stack
    stack[#stack + 1] = { value = value, keys = keys, count = count, index = 1, ignoredKeys = ignoredKeys, depth = depth }
end

-- Starts a fingerprint of value; see StepFingerprint.
function GW.Store.BeginFingerprint(value)
    local state = { hash = 5381, bytes = 0, pieces = 0, stack = {}, done = false }
    resumableVisit(state, value, FINGERPRINT_IGNORED_KEYS, 0)
    if #state.stack == 0 then
        state.done = true
    end
    return state
end

-- Serializes and hashes about maxPieces more pieces. Returns true and the
-- fingerprint (identical to GW.Store.Fingerprint) once finished.
function GW.Store.StepFingerprint(state, maxPieces)
    if state.done then
        return true, state.result or string.format("%08x", state.hash)
    end
    local limit = state.pieces + (tonumber(maxPieces) or 512)
    local stack = state.stack
    while #stack > 0 and state.pieces < limit do
        local frame = stack[#stack]
        if frame.index > frame.count then
            resumableEmit(state, "}")
            stack[#stack] = nil
        else
            local key = frame.keys[frame.index]
            frame.index = frame.index + 1
            resumableVisit(state, key, nil, frame.depth + 1)
            resumableVisit(state, frame.value[key], frame.ignoredKeys, frame.depth + 1)
        end
    end
    if #stack == 0 then
        state.done = true
        state.result = string.format("%08x", state.hash)
        local perf = GW.Perf
        if perf and perf.Count then
            perf.Count("fingerprint_resumable")
            perf.Count("fingerprint_bytes", state.bytes)
        end
        return true, state.result
    end
    return false
end

-- Keeps the outbound telemetry bounded. One-off events (session
-- checkpoints, corpse loot) go first, oldest first; a character's state
-- streams are only pruned when nothing else is left.
--
-- Pruning runs in batches: once the queue passes its limit, it is sorted
-- once and cut back to PRUNE_TARGET, leaving room for PRUNE_BATCH more
-- writes before the next sort. Pruning one record per write instead re-sorted
-- every record on every write once the queue was full, a hitch on every loot.
local PRUNE_BATCH = 512
local PRUNE_TARGET = MAX_TELEMETRY_STREAMS - PRUNE_BATCH
local streamCount = nil

local function recordRank(record)
    local timestamp = tonumber(record and record.updatedAt) or 0
    return (record and record.kind == "event" and 0 or 1e12) + timestamp
end

local function countStreams(outbound)
    local count = 0
    for _ in pairs(outbound) do
        count = count + 1
    end
    return count
end

local function evictionBefore(left, right)
    if left.rank ~= right.rank then
        return left.rank < right.rank
    end
    return left.sortKey < right.sortKey
end

local function noteWrite(outbound, isNew)
    if streamCount == nil then
        streamCount = countStreams(outbound)
    elseif isNew then
        streamCount = streamCount + 1
    end
end

local function pruneTelemetry(outbound)
    if (streamCount or 0) <= MAX_TELEMETRY_STREAMS then
        return
    end
    streamCount = countStreams(outbound)
    if streamCount <= MAX_TELEMETRY_STREAMS then
        return
    end
    local queue = {}
    for key, record in pairs(outbound) do
        queue[#queue + 1] = { key = key, rank = recordRank(record), sortKey = tostring(key) }
    end
    table.sort(queue, evictionBefore)
    local index = 1
    while streamCount > PRUNE_TARGET and index <= #queue do
        outbound[queue[index].key] = nil
        streamCount = streamCount - 1
        index = index + 1
    end
    local perf = GW.Perf
    if perf and perf.Count then
        perf.Count("telemetry_pruned", index - 1)
    end
end

-- Fingerprints of state records the bridge confirmed delivered and the
-- addon then dropped. A later capture with the same content is not queued
-- again. Bounded: past MAX_DELIVERED it starts over, which only costs a
-- re-send of unchanged state.
local MAX_DELIVERED = 8192

local function deliveredTelemetry()
    GuildweaverDB.sync.deliveredTelemetry = GuildweaverDB.sync.deliveredTelemetry or {}
    return GuildweaverDB.sync.deliveredTelemetry
end

-- Drops outbound records the bridge has delivered. The bridge writes
-- Data/BridgeAcks.generated.lua (stream key -> fingerprint) after reading a
-- save; it loads with the addon, so this runs once per login or reload.
-- Without it every record stayed in memory and in every save until the
-- queue's cap pushed it out.
local function dropAcknowledgedTelemetry()
    local acks = GW.BridgeAcks and GW.BridgeAcks.telemetry
    if type(acks) ~= "table" then
        return
    end
    local outbound = GuildweaverDB.sync.outbound.telemetry
    local delivered = deliveredTelemetry()
    local deliveredCount = 0
    for _ in pairs(delivered) do
        deliveredCount = deliveredCount + 1
    end
    local dropped = 0
    for streamKey, acknowledged in pairs(acks) do
        local record = outbound[streamKey]
        if type(record) == "table" and type(acknowledged) == "string" and record.fingerprint == acknowledged then
            outbound[streamKey] = nil
            dropped = dropped + 1
            if record.kind ~= "event" then
                if deliveredCount >= MAX_DELIVERED then
                    delivered = {}
                    GuildweaverDB.sync.deliveredTelemetry = delivered
                    deliveredCount = 0
                end
                if delivered[streamKey] == nil then
                    deliveredCount = deliveredCount + 1
                end
                delivered[streamKey] = acknowledged
            end
        end
    end
    local perf = GW.Perf
    if perf and perf.Count then
        perf.Count("telemetry_acknowledged_dropped", dropped)
    end
end

local function captureMeta()
    GuildweaverDB.meta = GuildweaverDB.meta or {}
    GuildweaverDB.meta.capture = GuildweaverDB.meta.capture or {}
    return GuildweaverDB.meta.capture
end

function GW.Store.ConfirmLiveClient()
    local realm = type(GetRealmName) == "function" and GetRealmName() or nil
    local interface = nil
    if type(GetBuildInfo) == "function" then
        local _, _, _, value = GetBuildInfo()
        interface = tonumber(value)
    end
    local testClient = type(IsTestBuild) == "function" and IsTestBuild()
    local testRealm = type(realm) == "string" and (
        string.lower(realm):match("%f[%a]beta%f[%A]") or string.lower(realm):match("%f[%a]ptr%f[%A]")
    )
    if type(realm) ~= "string" or realm == "" or testClient or testRealm
        or not interface or interface < 16000 or interface >= 17000 then
        GuildweaverDB.gameRelease = nil
        return false
    end
    GuildweaverDB.gameRelease = "forever-live"
    return true
end

function GW.Store.Initialize()
    streamCount = nil
    if type(GuildweaverDB) ~= "table" or GuildweaverDB.gameRelease ~= "forever-live" then
        GuildweaverDB = {}
    end

    GW.Store.ConfirmLiveClient()
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

    dropAcknowledgedTelemetry()
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
    local nextFingerprint = fingerprint(snapshot, CHARACTER_FINGERPRINT_IGNORED_KEYS)
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

-- precomputedFingerprint, when given, must be GW.Store.Fingerprint of
-- envelope.payload; callers that already computed it pass it on so the
-- payload is serialized and hashed only once.
function GW.Store.SetTelemetrySnapshot(streamKey, envelope, precomputedFingerprint)
    local outbound = GuildweaverDB.sync.outbound.telemetry
    local existing = outbound[streamKey]
    local nextFingerprint = type(precomputedFingerprint) == "string" and precomputedFingerprint
        or fingerprint(envelope.payload)

    if existing and existing.fingerprint == nextFingerprint then
        return false
    end
    local delivered = GuildweaverDB.sync.deliveredTelemetry
    if not existing and delivered and delivered[streamKey] == nextFingerprint then
        -- The server already has exactly this.
        return false
    end
    if delivered then
        delivered[streamKey] = nil
    end

    local revisions = telemetryRevisions()
    local revision = math.max(existing and tonumber(existing.revision) or 0, tonumber(revisions[streamKey]) or 0)
    revisions[streamKey] = revision + 1
    local record = {
        kind = "state",
        revision = revision + 1,
        updatedAt = envelope.capturedAt,
        fingerprint = nextFingerprint,
        envelope = envelope,
    }
    outbound[streamKey] = record
    noteWrite(outbound, existing == nil)
    pruneTelemetry(outbound)
    return true
end

-- The stored outbound record of a stream, if any.
function GW.Store.GetTelemetryRecord(streamKey)
    local database = GuildweaverDB
    local outbound = type(database) == "table" and database.sync and database.sync.outbound
        and database.sync.outbound.telemetry or nil
    return outbound and outbound[streamKey] or nil
end

function GW.Store.SetTelemetryEvent(streamKey, envelope, precomputedFingerprint)
    local outbound = GuildweaverDB.sync.outbound.telemetry
    local existing = outbound[streamKey]
    local nextFingerprint = type(precomputedFingerprint) == "string" and precomputedFingerprint
        or fingerprint(envelope.payload)

    if existing and existing.fingerprint == nextFingerprint then
        return false
    end

    local revision = existing and tonumber(existing.revision) or 0
    local record = {
        kind = "event",
        revision = revision + 1,
        updatedAt = envelope.capturedAt,
        fingerprint = nextFingerprint,
        envelope = envelope,
    }
    outbound[streamKey] = record
    noteWrite(outbound, existing == nil)
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