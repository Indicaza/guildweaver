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
    -- A new cached scan (bags or money) is the only way the payload changes,
    -- so an unchanged scan is never fingerprinted again.
    revision = function(snapshot)
        local module = GW.InventoryTelemetry
        local characterKey = type(snapshot) == "table" and snapshot.characterKey or nil
        if type(module) ~= "table" or type(module.PayloadRevision) ~= "function" or not characterKey then
            return nil
        end
        local revision = module.PayloadRevision(characterKey)
        return revision and (tostring(characterKey) .. "#" .. tostring(revision)) or nil
    end,
    capture = function(snapshot)
        snapshot = type(snapshot) == "table" and snapshot or {}
        local module = GW.InventoryTelemetry
        if type(module) ~= "table" or not snapshot.characterKey then
            return nil
        end
        -- Without a scan yet, a character capture asks for one instead of
        -- reading every bag inside its own frame.
        local capture = GW.InventoryCapture
        if type(module.Latest) == "function" and capture and type(capture.Schedule) == "function"
            and capture.eventFrame and not module.Latest(snapshot.characterKey) then
            module.MarkAllDirty()
            capture:Schedule("CHARACTER_CAPTURE")
            return nil
        end
        return module.Current(snapshot.characterKey)
    end,
})
