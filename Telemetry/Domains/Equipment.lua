local _, GW = ...

GW.TelemetryDomains = GW.TelemetryDomains or {}

GW.TelemetryDomains.Equipment = GW.TelemetryDomain.Define({
    name = "Equipment",
    eventType = "equipment",
    payloadSchemaVersion = 1,
    -- Equipment only changes when the section is read again, or when a
    -- tooltip that was still loading completes; otherwise the payload is not
    -- rebuilt or fingerprinted (profession and stat refreshes reuse it).
    revision = function(snapshot)
        local character = GW.Character
        local revision = type(character) == "table" and type(character.SectionRevision) == "function"
            and character.SectionRevision("equipment") or nil
        if type(snapshot) ~= "table" or not snapshot.characterKey or not revision or revision == 0
            or type(snapshot.equipment) ~= "table" then
            return nil
        end
        local full = 0
        local items = GW.ItemTelemetry
        for _, item in ipairs(snapshot.equipment) do
            if type(item) == "table" and items and type(items.IsFullTooltip) == "function" and items.IsFullTooltip(item.tooltip) then
                full = full + 1
            end
        end
        return tostring(snapshot.characterKey) .. "#" .. tostring(revision) .. "#" .. #snapshot.equipment .. "#" .. full
    end,
    capture = function(snapshot)
        snapshot = type(snapshot) == "table" and snapshot or {}
        return {
            equipment = type(snapshot.equipment) == "table" and snapshot.equipment or {},
        }
    end,
})