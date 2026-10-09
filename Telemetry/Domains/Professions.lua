local _, GW = ...

GW.TelemetryDomains = GW.TelemetryDomains or {}

-- profession_snapshot: profession identity plus the cached recipe book for
-- each profession (see Data/ProfessionTelemetry.lua). Versioned and
-- fingerprinted independently of the character snapshot.
local function professionsUnavailable(snapshot)
    local sections = type(snapshot.capture) == "table" and snapshot.capture.sections or nil
    return type(sections) == "table" and sections.professions == "unavailable"
end

GW.TelemetryDomains.Professions = GW.TelemetryDomain.Define({
    name = "Professions",
    eventType = "profession_snapshot",
    payloadSchemaVersion = 1,
    capture = function(snapshot)
        snapshot = type(snapshot) == "table" and snapshot or {}
        local module = GW.ProfessionTelemetry
        local characterKey = snapshot.characterKey
        if type(module) ~= "table" or not characterKey then
            return nil
        end

        if not professionsUnavailable(snapshot) then
            local live = module.CollectProfessions()
            if live then
                module.RememberProfessions(characterKey, live)
            elseif type(snapshot.professions) == "table" and #snapshot.professions > 0 then
                -- No profession API on this client: fall back to the character
                -- snapshot's profession list.
                module.RememberProfessions(characterKey, snapshot.professions)
            end
        end

        return module.BuildPayload(characterKey)
    end,
})
