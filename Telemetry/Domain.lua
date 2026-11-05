local _, GW = ...

GW.TelemetryDomain = GW.TelemetryDomain or {}

local function streamKeyPart(value)
    local normalized = string.lower(tostring(value or "unknown")):gsub("[^%w%-_]+", "-")
    return normalized
end

local function defaultStreamKey(module, snapshot)
    return table.concat({ module.EventType, streamKeyPart(snapshot and snapshot.characterId) }, ":")
end

local function storedRecord(streamKey)
    local store = GW.Store
    if type(store.GetTelemetryRecord) == "function" then
        return store.GetTelemetryRecord(streamKey)
    end
    local database = store.GetDatabase()
    return database
        and database.sync
        and database.sync.outbound
        and database.sync.outbound.telemetry
        and database.sync.outbound.telemetry[streamKey]
        or nil
end

-- config.revision(snapshot), when given, returns a token that changes
-- whenever the payload could change (an explicit revision, not a table
-- identity). While the token and the stored record are unchanged, Publish
-- skips the capture, the fingerprint and the store entirely.
--
-- config.persistRevision also keeps the token on the outbound record
-- (record.sourceRevision; the bridge ignores record fields it does not
-- know), so an unchanged payload is not rebuilt after a reload either.
--
-- config.deferred publishes a changed payload from GW.WorkQueue instead of
-- inline: the payload is captured and fingerprinted across frames
-- (GW.Store.BeginFingerprint), then stored. Without the work queue it is
-- published inline as before.
local FINGERPRINT_PIECES = 256

local function deferredJob(module, snapshot, token, streamKey)
    return {
        key = "domain:" .. streamKey,
        optional = true,
        category = "domain_publish",
        phase = "capture",
        step = function(job)
            if job.phase == "capture" then
                job.payload = module.Capture(snapshot)
                if type(job.payload) ~= "table" then
                    return true
                end
                job.payload.schemaVersion = module.PayloadSchemaVersion
                job.fingerprint = GW.Store.BeginFingerprint(job.payload)
                job.phase = "fingerprint"
                return false
            end
            local queue = GW.WorkQueue
            repeat
                local done, fingerprint = GW.Store.StepFingerprint(job.fingerprint, FINGERPRINT_PIECES)
                if done then
                    local context = {}
                    for key, value in pairs(snapshot) do
                        context[key] = value
                    end
                    context.capturedAt = type(GetServerTime) == "function" and GetServerTime() or snapshot.capturedAt
                    module.PublishPrepared(context, job.payload, fingerprint, token)
                    return true
                end
            until queue.ShouldYield()
            return false
        end,
    }
end

function GW.TelemetryDomain.Define(config)
    local module = {
        Name = assert(config.name, "telemetry domain name is required"),
        EventType = assert(config.eventType, "telemetry domain eventType is required"),
        PayloadSchemaVersion = tonumber(config.payloadSchemaVersion) or 1,
    }

    local customFingerprint = type(config.fingerprint) == "function"
    module.Capture = assert(config.capture, "telemetry domain capture is required")
    module.Revision = config.revision
    module.StreamKey = config.streamKey or function(snapshot)
        return defaultStreamKey(module, snapshot)
    end
    module.Fingerprint = config.fingerprint or function(payload)
        return GW.Store.Fingerprint(payload)
    end

    -- streamKey -> { token, record } for the last publish that was stored or
    -- confirmed unchanged.
    local published = {}
    local persistRevision = config.persistRevision == true

    local function remember(streamKey, token, record)
        if token == nil or not record then
            return
        end
        published[streamKey] = { token = token, record = record }
        if persistRevision then
            record.sourceRevision = token
        end
    end

    local function unchanged(streamKey, token)
        if token == nil then
            return nil
        end
        local record = storedRecord(streamKey)
        if not record then
            return nil
        end
        local last = published[streamKey]
        if (last and last.token == token and last.record == record)
            or (persistRevision and record.sourceRevision == token) then
            return record
        end
        return nil
    end

    function module.Publish(snapshot)
        local token = nil
        local defaultKey = nil
        if type(module.Revision) == "function" then
            token = module.Revision(snapshot)
            defaultKey = module.StreamKey(snapshot)
            local record = unchanged(defaultKey, token)
            if record then
                return {
                    changed = false,
                    skipped = false,
                    cached = true,
                    streamKey = defaultKey,
                    fingerprint = record.fingerprint,
                    revision = tonumber(record.revision),
                    envelope = record.envelope,
                }
            end
            local queue = GW.WorkQueue
            if config.deferred and token ~= nil and type(defaultKey) == "string"
                and type(snapshot) == "table" and queue and type(queue.Enqueue) == "function" then
                queue.Enqueue(deferredJob(module, snapshot, token, defaultKey), "replace")
                return { changed = false, skipped = false, deferred = true, streamKey = defaultKey }
            end
        end

        local payload = module.Capture(snapshot)
        if type(payload) ~= "table" then
            return { changed = false, skipped = true }
        end

        payload.schemaVersion = module.PayloadSchemaVersion
        local streamKey = module.StreamKey(snapshot, payload)
        local envelope = GW.TelemetryEnvelope.Build(module.EventType, payload, snapshot)
        if not envelope or type(streamKey) ~= "string" or streamKey == "" then
            return { changed = false, skipped = true }
        end

        -- The default fingerprint is exactly what the store dedupes on, so it
        -- is computed once and handed over. A custom domain fingerprint is
        -- reported as before and the store keeps its own payload fingerprint.
        local fingerprint = module.Fingerprint(payload)
        local changed
        if customFingerprint then
            changed = GW.Store.SetTelemetrySnapshot(streamKey, envelope)
        else
            changed = GW.Store.SetTelemetrySnapshot(streamKey, envelope, fingerprint)
        end
        local record = storedRecord(streamKey)

        if streamKey == defaultKey then
            remember(streamKey, token, record)
        end

        return {
            changed = changed == true,
            skipped = false,
            streamKey = streamKey,
            fingerprint = fingerprint,
            revision = record and tonumber(record.revision) or nil,
            envelope = envelope,
        }
    end

    -- Stores a payload the caller captured and fingerprinted itself (for
    -- example across several frames with GW.Store.BeginFingerprint). token is
    -- the revision() value the payload was built from.
    function module.PublishPrepared(snapshot, payload, fingerprint, token)
        if type(payload) ~= "table" or type(fingerprint) ~= "string" then
            return { changed = false, skipped = true }
        end
        payload.schemaVersion = module.PayloadSchemaVersion
        local streamKey = module.StreamKey(snapshot, payload)
        local envelope = GW.TelemetryEnvelope.Build(module.EventType, payload, snapshot)
        if not envelope or type(streamKey) ~= "string" or streamKey == "" then
            return { changed = false, skipped = true }
        end
        local changed = GW.Store.SetTelemetrySnapshot(streamKey, envelope, fingerprint)
        local record = storedRecord(streamKey)
        remember(streamKey, token, record)
        return {
            changed = changed == true,
            skipped = false,
            streamKey = streamKey,
            fingerprint = fingerprint,
            revision = record and tonumber(record.revision) or nil,
            envelope = envelope,
        }
    end

    -- Forgets cached results, so the next publish captures and compares.
    function module.Invalidate()
        published = {}
    end

    return module
end
