local _, GW = ...

GW.TelemetryDomains = GW.TelemetryDomains or {}

GW.TelemetryDomains.Professions = GW.TelemetryDomain.Define({
    name = "Professions",
    eventType = "professions",
    payloadSchemaVersion = 1,
    capture = function(snapshot)
        snapshot = type(snapshot) == "table" and snapshot or {}
        return {
            professions = type(snapshot.professions) == "table" and snapshot.professions or {},
        }
    end,
})