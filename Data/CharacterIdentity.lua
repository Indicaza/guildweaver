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

local function normalized(value)
    if type(value) ~= "string" then
        return ""
    end
    return string.lower(value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function currentCharacterNames()
    local firstName = nil
    local secondValue = nil

    if type(UnitFullName) == "function" then
        local ok, first, second = pcall(UnitFullName, "player")
        if ok then
            firstName = first
            secondValue = second
        end
    end

    if (not firstName or firstName == "") and type(UnitName) == "function" then
        local ok, value = pcall(UnitName, "player")
        if ok then
            firstName = value
        end
    end

    if not firstName or firstName == "" then
        return nil, nil, nil
    end

    local realm = currentRealm()
    local lastName = nil

    -- Retail/Classic normally return the realm as UnitFullName's second value.
    -- WoW Forever currently returns the character surname there instead. Treat a
    -- second value that differs from GetRealmName() as a surname so both clients
    -- remain compatible.
    if type(secondValue) == "string" and secondValue ~= "" then
        if not realm or normalized(secondValue) ~= normalized(realm) then
            lastName = secondValue
        end
    end

    local fullName = firstName
    if lastName and lastName ~= "" then
        fullName = firstName .. " " .. lastName
    end

    return firstName, lastName, fullName
end

local function nameFromKey(characterKey)
    if type(characterKey) ~= "string" then
        return nil
    end

    return characterKey:match("^[^:]*:(.+)$")
end

local function canonicalCharacterKey(characterKey, characterName)
    local realm = currentRealm()
    local _, _, fullName = currentCharacterNames()
    local name = fullName or characterName or nameFromKey(characterKey)

    if not realm or not name or name == "" then
        return characterKey
    end

    return string.lower(realm .. ":" .. name)
end

local function migrateCharacterKey(oldKey, newKey)
    if not oldKey or not newKey or oldKey == newKey then
        return
    end

    local database = GW.Store.GetDatabase()
    if type(database) ~= "table" then
        return
    end

    database.meta = database.meta or {}
    database.meta.characterIds = database.meta.characterIds or {}
    local ids = database.meta.characterIds
    if ids[oldKey] and not ids[newKey] then
        ids[newKey] = ids[oldKey]
    end
    ids[oldKey] = nil

    database.characters = database.characters or {}
    if database.characters[oldKey] and not database.characters[newKey] then
        database.characters[newKey] = database.characters[oldKey]
    end
    database.characters[oldKey] = nil

    local outbound = database.sync and database.sync.outbound and database.sync.outbound.characters
    if type(outbound) == "table" then
        if outbound[oldKey] and not outbound[newKey] then
            outbound[newKey] = outbound[oldKey]
        end
        outbound[oldKey] = nil
    end
end

local function migrateKnownAliases(characterKey, canonicalKey)
    migrateCharacterKey(characterKey, canonicalKey)

    local realm = currentRealm()
    local firstName = currentCharacterNames()
    if realm and firstName then
        -- The previous compatibility layer already repaired the realm but keyed
        -- every Forever character by first name only. The first surnamed
        -- character seen after this upgrade inherits that stable ID; another
        -- character with the same first name then receives its own ID.
        migrateCharacterKey(string.lower(realm .. ":" .. firstName), canonicalKey)
    end
end

local originalGetCharacterId = GW.Store.GetCharacterId
local originalGetCharacterSnapshot = GW.Store.GetCharacterSnapshot
local originalSetCharacterSnapshot = GW.Store.SetCharacterSnapshot
local originalSetTelemetrySnapshot = GW.Store.SetTelemetrySnapshot

function GW.Store.GetCharacterId(characterKey)
    local canonicalKey = canonicalCharacterKey(characterKey)
    migrateKnownAliases(characterKey, canonicalKey)
    return originalGetCharacterId(canonicalKey)
end

function GW.Store.GetCharacterSnapshot(characterKey)
    local canonicalKey = canonicalCharacterKey(characterKey)
    migrateKnownAliases(characterKey, canonicalKey)
    return originalGetCharacterSnapshot(canonicalKey)
end

function GW.Store.SetCharacterSnapshot(characterKey, snapshot)
    local firstName, lastName, fullName = currentCharacterNames()
    local canonicalKey = canonicalCharacterKey(characterKey, fullName or (snapshot and snapshot.name))
    migrateKnownAliases(characterKey, canonicalKey)

    local realm = currentRealm()
    if type(snapshot) == "table" then
        local reportedFirstName = firstName or snapshot.firstName or snapshot.name
        local reportedFullName = fullName or snapshot.fullName or snapshot.name
        snapshot.characterKey = canonicalKey
        snapshot.realm = realm or snapshot.realm
        snapshot.firstName = reportedFirstName
        snapshot.lastName = lastName or snapshot.lastName
        snapshot.fullName = reportedFullName
        snapshot.name = reportedFullName
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
