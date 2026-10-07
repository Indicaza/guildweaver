local function assertEqual(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
    end
end

local function assertNotEqual(actual, expected, label)
    if actual == expected then
        error(string.format("%s: expected values to differ, both were %s", label, tostring(actual)))
    end
end

GuildweaverDB = nil
GetServerTime = function() return 1791320496 end
GetRealmName = function() return "Classic Beta PvE 2" end

local addon = {}
local function loadAddonFile(path)
    local chunk = assert(loadfile(path))
    return chunk("Guildweaver", addon)
end

loadAddonFile("Data/Store.lua")
addon.Store.Initialize()

-- This is the shape produced by the previous realm repair: surname was no
-- longer mistaken for the realm, but same-first-name characters still shared
-- a single realm:name key.
GuildweaverDB.meta.characterIds["classic beta pve 2:rook"] = "character-existing"
GuildweaverDB.characters["classic beta pve 2:rook"] = {
    name = "Rook",
    realm = "Classic Beta PvE 2",
    characterKey = "classic beta pve 2:rook",
}
GuildweaverDB.sync.outbound.characters["classic beta pve 2:rook"] = {
    revision = 14,
    updatedAt = 1791320400,
    fingerprint = "legacy",
    payload = GuildweaverDB.characters["classic beta pve 2:rook"],
}

loadAddonFile("Data/CharacterIdentity.lua")

-- Forever supplies surname in UnitFullName's second position, so Character.lua
-- still initially asks the store about "darkwing:rook". The identity layer
-- converts that into realm:first:last without losing the existing anonymous ID.
local characterId = addon.Store.GetCharacterId("darkwing:rook")
assertEqual(characterId, "character-existing", "character id is preserved")
assertEqual(GuildweaverDB.meta.characterIds["classic beta pve 2:rook"], nil, "legacy first-name key removed")
assertEqual(GuildweaverDB.meta.characterIds["classic beta pve 2:rook:darkwing"], "character-existing", "surname-aware key migrated")
assertEqual(GuildweaverDB.sync.outbound.characters["classic beta pve 2:rook:darkwing"].revision, 14, "outbound revision preserved")

local snapshot = {
    schemaVersion = 2,
    name = "Rook",
    realm = "Darkwing",
    characterKey = "darkwing:rook",
    capturedAt = 1791320496,
}
addon.Store.SetCharacterSnapshot("darkwing:rook", snapshot)
assertEqual(snapshot.schemaVersion, 3, "surname identity bumps payload schema")
assertEqual(snapshot.realm, "Classic Beta PvE 2", "snapshot realm uses server realm")
assertEqual(snapshot.firstName, "Rook", "first name preserved")
assertEqual(snapshot.lastName, "Darkwing", "surname preserved")
assertEqual(snapshot.displayName, "Rook Darkwing", "display name composed")
assertEqual(snapshot.characterKey, "classic beta pve 2:rook:darkwing", "snapshot key uses surname-aware identity")
assertEqual(GuildweaverDB.sync.outbound.characters["classic beta pve 2:rook:darkwing"].revision, 15, "revision continues after repair")

-- A second Rook on the same realm must no longer inherit the first Rook's ID.
local secondId = addon.Store.GetCharacterId("ravenstar:rook")
assertNotEqual(secondId, characterId, "same first name with another surname receives a distinct id")
local secondSnapshot = {
    schemaVersion = 2,
    name = "Rook",
    realm = "Ravenstar",
    characterKey = "ravenstar:rook",
    capturedAt = 1791320497,
}
addon.Store.SetCharacterSnapshot("ravenstar:rook", secondSnapshot)
assertEqual(secondSnapshot.characterKey, "classic beta pve 2:rook:ravenstar", "second surname has distinct key")
assertEqual(secondSnapshot.displayName, "Rook Ravenstar", "second display name composed")
assertEqual(GuildweaverDB.meta.characterIds["classic beta pve 2:rook:darkwing"], characterId, "first Rook id remains")
assertEqual(GuildweaverDB.meta.characterIds["classic beta pve 2:rook:ravenstar"], secondId, "second Rook id remains")

local envelope = {
    schemaVersion = 1,
    eventType = "character_snapshot",
    capturedAt = 1791320496,
    realm = "Darkwing",
    payload = snapshot,
}
addon.Store.SetTelemetrySnapshot("character_snapshot:" .. characterId, envelope)
assertEqual(envelope.realm, "Classic Beta PvE 2", "envelope realm uses server realm")
assertEqual(envelope.payload.realm, "Classic Beta PvE 2", "payload realm stays canonical")

print("realm and surname identity spec passed")
