local _, GW = ...

GW.TelemetryDomains = GW.TelemetryDomains or {}

GW.TelemetryDomains.Talents = GW.TelemetryDomain.Define({
    name = "Talents",
    eventType = "talents",
    payloadSchemaVersion = 1,
    capture = function(snapshot)
        snapshot = type(snapshot) == "table" and snapshot or {}
        return {
            talents = snapshot.talents,
        }
    end,
})