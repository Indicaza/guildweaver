local function assertEqual(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
    end
end

local surname = "Darkwing"
GuildweaverDB = nil
GetServerTime = function() return 1791320496 end
GetRealmName = function() return "Classic Beta PvE 2" end
UnitFullName = function() return "Rook", surname end
UnitName = function() return "Rook" end

local addon = {}
local function loadAddonFile(path)
    local chunk = assert(loadfile(path))
    return chunk("Guildweaver", addon)
end

loadAddonFile("Data/Store.lua")
addon.Store.Initialize()

GuildweaverDB.meta.characterIds["darkwing:rook"] = "character-existing"
GuildweaverDB.characters["darkwing:rook"] = {
    name = "Rook",
    realm = "Darkwing",
    characterKey = "darkwing:rook",
}
GuildweaverDB.sync.outbound.characters["darkwing:rook"] = {
    revision = 14,
    updatedAt = 1791320400,
    fingerprint = "legacy",
    payload = GuildweaverDB.characters["darkwing:rook"],
}

loadAddonFile("Data/CharacterIdentity.lua")

local characterId = addon.Store.GetCharacterId("darkwing:rook")
assertEqual(characterId, "character-existing", "character id is preserved")
assertEqual(GuildweaverDB.meta.characterIds["darkwing:rook"], nil, "legacy surname-as-realm key id removed")
assertEqual(GuildweaverDB.meta.characterIds["classic beta pve 2:rook darkwing"], "character-existing", "full-name realm key migrated")
assertEqual(GuildweaverDB.sync.outbound.characters["classic beta pve 2:rook darkwing"].revision, 14, "outbound revision preserved")

local snapshot = {
    name = "Rook",
    realm = "Darkwing",
    characterKey = "darkwing:rook",
    capturedAt = 1791320496,
}
addon.Store.SetCharacterSnapshot("darkwing:rook", snapshot)
assertEqual(snapshot.realm, "Classic Beta PvE 2", "snapshot realm uses server realm")
assertEqual(snapshot.characterKey, "classic beta pve 2:rook darkwing", "snapshot key uses server realm and full name")
assertEqual(snapshot.firstName, "Rook", "first name captured")
assertEqual(snapshot.lastName, "Darkwing", "surname captured")
assertEqual(snapshot.fullName, "Rook Darkwing", "full name captured")
assertEqual(GuildweaverDB.sync.outbound.characters["classic beta pve 2:rook darkwing"].revision, 15, "revision continues after repair")

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

surname = "Ravenstar"
local secondCharacterId = addon.Store.GetCharacterId("darkwing:rook")
if secondCharacterId == characterId then
    error("same first name with a different Forever surname must receive a distinct character id")
end
assertEqual(GuildweaverDB.meta.characterIds["classic beta pve 2:rook ravenstar"], secondCharacterId, "second surname receives its own canonical key")

-- Standard WoW returns the realm in UnitFullName's second position. Confirm we
-- do not reinterpret that as a surname.
surname = "Classic Beta PvE 2"
local standardSnapshot = { name = "Rook" }
addon.Store.SetCharacterSnapshot("classic beta pve 2:rook", standardSnapshot)
assertEqual(standardSnapshot.lastName, nil, "realm return is not treated as surname")
assertEqual(standardSnapshot.fullName, "Rook", "standard client keeps first name as full name")

print("realm identity spec passed")
