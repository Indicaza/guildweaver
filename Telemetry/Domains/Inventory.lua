local _, GW = ...

GW.TelemetryDomains = GW.TelemetryDomains or {}

-- inventory_snapshot: carried bags and money (see Data/InventoryTelemetry.lua).
-- Versioned and fingerprinted independently of the character snapshot, and
-- also published on its own when bag contents or money change
-- (Systems/InventoryCapture.lua).
GW.TelemetryDomains.Inventory = GW.TelemetryDomain.Define({
    name = "Inventory",
    eventType = "inventory_snapshot",
    payloadSchemaVersion = 1,
    capture = function(snapshot)
        snapshot = type(snapshot) == "table" and snapshot or {}
        local module = GW.InventoryTelemetry
        if type(module) ~= "table" or not snapshot.characterKey then
            return nil
        end
        return module.Current(snapshot.characterKey)
    end,
})
