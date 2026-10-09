local _, GW = ...

GW.Telemetry = GW.Telemetry or {}

local DOMAINS = {
    GW.TelemetryDomains.Character,
    GW.TelemetryDomains.Stats,
    GW.TelemetryDomains.Equipment,
    GW.TelemetryDomains.Professions,
    GW.TelemetryDomains.Talents,
}

function GW.Telemetry.GetDomains()
    return DOMAINS
end

function GW.Telemetry.PublishCharacterSnapshot(snapshot)
    local results = {}
    for _, domain in ipairs(DOMAINS) do
        if domain and type(domain.Publish) == "function" then
            local ok, result = pcall(domain.Publish, snapshot)
            results[domain.Name or domain.EventType or tostring(#results + 1)] = ok and result or {
                changed = false,
                skipped = true,
                error = tostring(result),
            }
        end
    end
    return results
end