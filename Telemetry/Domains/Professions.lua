local _, GW = ...

GW.TelemetryDomains = GW.TelemetryDomains or {}

-- profession_snapshot: profession identity plus the cached recipe book for
-- each profession (see Data/ProfessionTelemetry.lua). Versioned and
-- fingerprinted independently of the character snapshot.
--
-- Recipe books make this the largest payload, so it is only rebuilt and
-- fingerprinted when the profession cache's revision moves: a changed
-- profession list (skill-ups, learning or dropping a profession) or a new
-- recipe book.
local function professionsUnavailable(snapshot)
    local sections = type(snapshot.capture) == "table" and snapshot.capture.sections or nil
    return type(sections) == "table" and sections.professions == "unavailable"
end

local function refreshProfessions(module, snapshot, characterKey)
    if professionsUnavailable(snapshot) then
        return
    end
    local live = module.CollectProfessions()
    if live then
        module.RememberProfessions(characterKey, live)
    elseif type(snapshot.professions) == "table" and #snapshot.professions > 0 then
        -- No profession API on this client: fall back to the character
        -- snapshot's profession list.
        module.RememberProfessions(characterKey, snapshot.professions)
    end
end

-- The snapshot whose live professions were already refreshed by revision()
-- during the current Publish, so capture() does not read them twice.
local refreshedSnapshot = nil

GW.TelemetryDomains.Professions = GW.TelemetryDomain.Define({
    name = "Professions",
    eventType = "profession_snapshot",
    payloadSchemaVersion = 1,
    persistRevision = true,
    -- Recipe payloads are large; changed ones are published across frames.
    deferred = true,
    revision = function(snapshot)
        snapshot = type(snapshot) == "table" and snapshot or {}
        local module = GW.ProfessionTelemetry
        local characterKey = snapshot.characterKey
        if type(module) ~= "table" or not characterKey or type(module.Revision) ~= "function" then
            return nil
        end
        refreshProfessions(module, snapshot, characterKey)
        refreshedSnapshot = snapshot
        local character = GW.Character
        if type(module.AdoptAliasCache) == "function" and character and type(character.ProfessionCacheAlias) == "function" then
            module.AdoptAliasCache(characterKey, character.ProfessionCacheAlias())
        end
        local revision = module.Revision(characterKey)
        local epoch = type(module.CacheEpoch) == "function" and module.CacheEpoch(characterKey) or ""
        return revision and (tostring(characterKey) .. "#" .. tostring(epoch) .. "#" .. tostring(revision)) or nil
    end,
    capture = function(snapshot)
        snapshot = type(snapshot) == "table" and snapshot or {}
        local module = GW.ProfessionTelemetry
        local characterKey = snapshot.characterKey
        if type(module) ~= "table" or not characterKey then
            return nil
        end

        if refreshedSnapshot ~= snapshot then
            refreshProfessions(module, snapshot, characterKey)
        end
        refreshedSnapshot = nil

        return module.BuildPayload(characterKey)
    end,
})
