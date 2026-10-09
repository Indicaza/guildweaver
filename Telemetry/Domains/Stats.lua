local _, GW = ...

GW.TelemetryDomains = GW.TelemetryDomains or {}

GW.TelemetryDomains.Stats = GW.TelemetryDomain.Define({
    name = "Stats",
    eventType = "stats",
    payloadSchemaVersion = 1,
    capture = function(snapshot)
        snapshot = type(snapshot) == "table" and snapshot or {}
        return {
            stats = snapshot.stats,
        }
    end,
})