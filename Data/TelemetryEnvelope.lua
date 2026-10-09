local _, GW = ...

GW.TelemetryEnvelope = GW.TelemetryEnvelope or {}
GW.TelemetryEnvelope.SchemaVersion = 1

local function optional(value)
    return value ~= nil and value or nil
end

function GW.TelemetryEnvelope.Build(eventType, payload, snapshot)
    if type(eventType) ~= "string" or eventType == "" then
        return nil
    end
    if type(payload) ~= "table" then
        return nil
    end

    snapshot = type(snapshot) == "table" and snapshot or {}
    local capturedAt = snapshot.capturedAt
    if capturedAt == nil and type(GetServerTime) == "function" then
        capturedAt = GetServerTime()
    end

    return {
        schemaVersion = GW.TelemetryEnvelope.SchemaVersion,
        eventType = eventType,
        capturedAt = capturedAt or 0,
        characterId = optional(snapshot.characterId),
        installationId = GW.Store and GW.Store.GetInstallationId and GW.Store.GetInstallationId() or nil,
        realm = optional(snapshot.realm),
        region = optional(snapshot.region),
        gameBuild = optional(snapshot.gameBuild),
        addon = {
            name = "Guildweaver",
            version = GW.version,
        },
        payloadSchemaVersion = tonumber(payload.schemaVersion) or 1,
        payload = payload,
    }
end