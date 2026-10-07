local _, GW = ...

local function currentRealm()
    if type(GetRealmName) ~= "function" then
        return nil
    end

    local ok, realm = pcall(GetRealmName)
    if not ok or type(realm) ~= "string" or realm == "" then
        return nil
    end

    return realm
end

local function normalize(value)
    return string.lower((tostring(value or ""):gsub("[^%w]", "")))
end

local function splitCharacterKey(characterKey)
    if type(characterKey) ~= "string" then
        return nil, nil, nil
    end

    local first, second, third = characterKey:match("^([^:]+):([^:]+):?(.*)$")
    if not first or not second then
        return nil, nil, nil
    end

    return first, second, third ~= "" and third or nil
end

local function identityFromKey(characterKey, snapshot)
    local realm = currentRealm()
    local keyRealm, keyName, keyLastName = splitCharacterKey(characterKey)
    local firstName = snapshot and (snapshot.firstName or snapshot.name) or keyName
    local lastName = snapshot and (snapshot.lastName or snapshot.surname) or keyLastName
    local reportedSecondName = snapshot and snapshot.realm or nil

    if realm and not lastName and reportedSecondName and normalize(reportedSecondName) ~= normalize(realm) then
        -- Before the compatibility layer runs, Character.lua still has the
        -- original-cased second UnitFullName value in snapshot.realm. Forever
        -- uses that value for the surname, so prefer it over the lowercased key.
        lastName = reportedSecondName
    end

    if realm and keyRealm and keyName and not lastName and normalize(keyRealm) ~= normalize(realm) then
        -- WoW Forever returns the character surname as UnitFullName's second value.
        -- Older Guildweaver builds mistook that value for a realm and produced
        -- keys like "darkwing:rook". Preserve it as the surname instead.
        lastName = keyRealm
    end

    if not firstName or firstName == "" then
        return realm, nil, nil, characterKey
    end

    if not realm or realm == "" then
        return realm, firstName, lastName, characterKey
    end

    local canonical = string.lower(realm .. ":" .. firstName)
    if lastName and lastName ~= "" then
        canonical = canonical .. ":" .. string.lower(lastName)
    end

    return realm, firstName, lastName, canonical
end

local function migrateTableKey(values, oldKey, newKey)
    if type(values) ~= "table" or not oldKey or not newKey or oldKey == newKey then
        return
    end

    local oldValue = values[oldKey]
    if oldValue == nil then
        return
    end

    if values[newKey] == nil then
        values[newKey] = oldValue
        values[oldKey] = nil
        return
    end

    if values[newKey] == oldValue then
        values[oldKey] = nil
    end
end

local function migrateCharacterKey(oldKey, newKey, firstName, lastName)
    if not newKey then
        return
    end

    local database = GW.Store.GetDatabase()
    if type(database) ~= "table" then
        return
    end

    database.meta = database.meta or {}
    database.meta.characterIds = database.meta.characterIds or {}
    database.characters = database.characters or {}

    local candidates = {}
    local realm = currentRealm()
    if realm and firstName then
        table.insert(candidates, string.lower(realm .. ":" .. firstName))
    end
    if oldKey then
        table.insert(candidates, oldKey)
    end
    if lastName and firstName then
        table.insert(candidates, string.lower(lastName .. ":" .. firstName))
    end

    local outbound = database.sync and database.sync.outbound and database.sync.outbound.characters

    for _, candidate in ipairs(candidates) do
        if candidate ~= newKey then
            migrateTableKey(database.meta.characterIds, candidate, newKey)
            migrateTableKey(database.characters, candidate, newKey)
            migrateTableKey(outbound, candidate, newKey)
        end
    end
end

local originalGetCharacterId = GW.Store.GetCharacterId
local originalGetCharacterSnapshot = GW.Store.GetCharacterSnapshot
local originalSetCharacterSnapshot = GW.Store.SetCharacterSnapshot
local originalSetTelemetrySnapshot = GW.Store.SetTelemetrySnapshot

function GW.Store.GetCharacterId(characterKey)
    local _, firstName, lastName, canonicalKey = identityFromKey(characterKey)
    migrateCharacterKey(characterKey, canonicalKey, firstName, lastName)
    return originalGetCharacterId(canonicalKey)
end

function GW.Store.GetCharacterSnapshot(characterKey)
    local _, firstName, lastName, canonicalKey = identityFromKey(characterKey)
    migrateCharacterKey(characterKey, canonicalKey, firstName, lastName)
    return originalGetCharacterSnapshot(canonicalKey)
end

function GW.Store.SetCharacterSnapshot(characterKey, snapshot)
    local realm, firstName, lastName, canonicalKey = identityFromKey(characterKey, snapshot)
    migrateCharacterKey(characterKey, canonicalKey, firstName, lastName)

    if type(snapshot) == "table" then
        snapshot.schemaVersion = math.max(tonumber(snapshot.schemaVersion) or 0, 3)
        snapshot.characterKey = canonicalKey
        snapshot.realm = realm or snapshot.realm
        snapshot.firstName = firstName or snapshot.firstName or snapshot.name
        snapshot.lastName = lastName or nil
        snapshot.displayName = snapshot.firstName or snapshot.name or ""
        if snapshot.lastName and snapshot.lastName ~= "" then
            snapshot.displayName = snapshot.displayName .. " " .. snapshot.lastName
        end
    end

    return originalSetCharacterSnapshot(canonicalKey, snapshot)
end

function GW.Store.SetTelemetrySnapshot(streamKey, envelope)
    local realm = currentRealm()
    if realm and type(envelope) == "table" and envelope.eventType == "character_snapshot" then
        envelope.realm = realm
        if type(envelope.payload) == "table" then
            envelope.payload.realm = realm
        end
    end

    return originalSetTelemetrySnapshot(streamKey, envelope)
end
