local _, GW = ...

GW.TelemetryDomain = GW.TelemetryDomain or {}

local function streamKeyPart(value)
    return string.lower(tostring(value or "unknown")):gsub("[^%w%-_]+", "-")
end

local function defaultStreamKey(module, snapshot)
    return table.concat({ module.EventType, streamKeyPart(snapshot and snapshot.characterId) }, ":")
end

function GW.TelemetryDomain.Define(config)
    local module = {
        Name = assert(config.name, "telemetry domain name is required"),
        EventType = assert(config.eventType, "telemetry domain eventType is required"),
        PayloadSchemaVersion = tonumber(config.payloadSchemaVersion) or 1,
    }

    module.Capture = assert(config.capture, "telemetry domain capture is required")
    module.StreamKey = config.streamKey or function(snapshot)
        return defaultStreamKey(module, snapshot)
    end
    module.Fingerprint = config.fingerprint or function(payload)
        return GW.Store.Fingerprint(payload)
    end

    function module.Publish(snapshot)
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

        local fingerprint = module.Fingerprint(payload)
        local changed = GW.Store.SetTelemetrySnapshot(streamKey, envelope)
        local database = GW.Store.GetDatabase()
        local record = database
            and database.sync
            and database.sync.outbound
            and database.sync.outbound.telemetry
            and database.sync.outbound.telemetry[streamKey]
            or nil

        return {
            changed = changed == true,
            skipped = false,
            streamKey = streamKey,
            fingerprint = fingerprint,
            revision = record and tonumber(record.revision) or nil,
            envelope = envelope,
        }
    end

    return module
end