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

local function currentRegion()
    if type(GetCurrentRegion) ~= "function" then return nil end
    local ok, value = pcall(GetCurrentRegion)
    local regions = { [1] = "US", [2] = "KR", [3] = "EU", [4] = "TW", [5] = "CN" }
    return ok and regions[tonumber(value)] or nil
end

local function canonicalCharacterKey(characterKey, characterName)
    local realm = currentRealm()
    local _, _, fullName = currentCharacterNames()
    local name = fullName or characterName or nameFromKey(characterKey)

    if not name or name == "" then return characterKey end
    if realm then return string.lower(realm .. ":" .. name) end
    return "region-" .. normalized(currentRegion() or "unknown") .. ":" .. normalized(name)
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

    local fingerprints = database.meta.characterFingerprints
    if type(fingerprints) == "table" then
        if fingerprints[oldKey] and not fingerprints[newKey] then
            fingerprints[newKey] = fingerprints[oldKey]
        end
        fingerprints[oldKey] = nil
    end
end

local function migrateKnownAliases(characterKey, canonicalKey)
    local realm = currentRealm()
    local firstName, _, fullName = currentCharacterNames()
    if not realm then
        local database = GW.Store.GetDatabase()
        local region = normalized(currentRegion())
        if type(database) ~= "table" or region == "" or not fullName then return end
        local ids = database.meta and database.meta.characterIds or {}
        if ids[canonicalKey] then return end
        local candidate = nil
        for key, snapshot in pairs(database.characters or {}) do
            if key ~= canonicalKey and ids[key] and type(snapshot) == "table"
                and normalized(snapshot.fullName or snapshot.name) == normalized(fullName)
                and normalized(snapshot.region) == region then
                if candidate then return end
                candidate = key
            end
        end
        if candidate then migrateCharacterKey(candidate, canonicalKey) end
        return
    end
    migrateCharacterKey(characterKey, canonicalKey)
    if firstName then
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
        snapshot.realm = realm
        snapshot.realmUnavailable = not realm
        snapshot.region = snapshot.region or currentRegion()
        snapshot.firstName = reportedFirstName
        snapshot.lastName = lastName or snapshot.lastName
        snapshot.fullName = reportedFullName
        snapshot.name = reportedFullName
    end

    return originalSetCharacterSnapshot(canonicalKey, snapshot)
end
