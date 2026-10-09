local _, GW = ...

GW.TelemetryDomains = GW.TelemetryDomains or {}

GW.TelemetryDomains.Equipment = GW.TelemetryDomain.Define({
    name = "Equipment",
    eventType = "equipment",
    payloadSchemaVersion = 1,
    capture = function(snapshot)
        snapshot = type(snapshot) == "table" and snapshot or {}
        return {
            equipment = type(snapshot.equipment) == "table" and snapshot.equipment or {},
        }
    end,
})