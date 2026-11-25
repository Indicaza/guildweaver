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

-- This is the shape produced by the previous realm repair: real realm, but
-- first-name-only identity. The upgrade must preserve the ID/revision while
-- adding the Forever surname to the canonical key.
GuildweaverDB.meta.characterIds["classic beta pve 2:rook"] = "character-existing"
GuildweaverDB.characters["classic beta pve 2:rook"] = {
    name = "Rook",
    realm = "Classic Beta PvE 2",
    characterKey = "classic beta pve 2:rook",
}
GuildweaverDB.meta.characterFingerprints["classic beta pve 2:rook"] = "legacy"

loadAddonFile("Data/CharacterIdentity.lua")

local characterId = addon.Store.GetCharacterId("classic beta pve 2:rook")
assertEqual(characterId, "character-existing", "character id is preserved")
assertEqual(GuildweaverDB.meta.characterIds["classic beta pve 2:rook"], nil, "first-name-only id removed")
assertEqual(GuildweaverDB.meta.characterIds["classic beta pve 2:rook darkwing"], "character-existing", "full-name id migrated")
assertEqual(GuildweaverDB.meta.characterFingerprints["classic beta pve 2:rook darkwing"], "legacy", "fingerprint follows the full-name key")

local snapshot = {
    name = "Rook",
    realm = "Classic Beta PvE 2",
    characterKey = "classic beta pve 2:rook",
    capturedAt = 1791320496,
}
addon.Store.SetCharacterSnapshot("classic beta pve 2:rook", snapshot)
assertEqual(snapshot.realm, "Classic Beta PvE 2", "snapshot realm uses server realm")
assertEqual(snapshot.characterKey, "classic beta pve 2:rook darkwing", "snapshot key uses server realm and full name")
assertEqual(snapshot.firstName, "Rook", "first name captured")
assertEqual(snapshot.lastName, "Darkwing", "surname captured")
assertEqual(snapshot.fullName, "Rook Darkwing", "full name captured")
assertEqual(snapshot.name, "Rook Darkwing", "legacy name field uses full display name")
assertEqual(GuildweaverDB.meta.characterFingerprints["classic beta pve 2:rook"], nil, "no fingerprint under the old key")

surname = "Ravenstar"
local secondCharacterId = addon.Store.GetCharacterId("classic beta pve 2:rook")
if secondCharacterId == characterId then
    error("same first name with a different Forever surname must receive a distinct character id")
end
assertEqual(GuildweaverDB.meta.characterIds["classic beta pve 2:rook ravenstar"], secondCharacterId, "second surname receives its own canonical key")

local secondSnapshot = { name = "Rook" }
addon.Store.SetCharacterSnapshot("classic beta pve 2:rook", secondSnapshot)
assertEqual(secondSnapshot.name, "Rook Ravenstar", "second character exports its full display name")
assertEqual(secondSnapshot.lastName, "Ravenstar", "second surname captured")

-- Standard WoW returns the realm in UnitFullName's second position. Confirm we
-- do not reinterpret that as a surname.
surname = "Classic Beta PvE 2"
local standardSnapshot = { name = "Rook" }
addon.Store.SetCharacterSnapshot("classic beta pve 2:rook", standardSnapshot)
assertEqual(standardSnapshot.lastName, nil, "realm return is not treated as surname")
assertEqual(standardSnapshot.fullName, "Rook", "standard client keeps first name as full name")
assertEqual(standardSnapshot.name, "Rook", "standard client display name remains unchanged")

print("realm identity spec passed")

-- Since 71037 the server name is unavailable. Keep the full name and
-- region, never use the surname as a realm, and migrate only unique matches.
GetRealmName = function() return "" end
GetCurrentRegion = function() return 1 end
surname = "Smith"
GuildweaverDB.characters["camwow us2 realm 4 pvp:rook smith"] = {
    name = "Rook Smith", fullName = "Rook Smith", region = "US", realm = "CAMWOW US2 Realm 4 PvP",
}
GuildweaverDB.meta.characterIds["camwow us2 realm 4 pvp:rook smith"] = "character-live-smith"
assertEqual(addon.Store.GetCharacterId("smith:rook"), "character-live-smith", "known identity survives hidden realm")
local hidden = { name = "Rook", realm = "Smith", region = "US" }
addon.Store.SetCharacterSnapshot("smith:rook", hidden)
assertEqual(hidden.characterKey, "region-us:rook smith", "region and full name key")
assertEqual(hidden.realm, nil, "surname is not a realm")
assertEqual(hidden.realmUnavailable, true, "missing realm recorded explicitly")
assertEqual(hidden.name, "Rook Smith", "surname preserved")
surname = "Other"
local other = addon.Store.GetCharacterId("other:rook")
if other == "character-live-smith" then error("different names share an id") end
print("realm-free identity spec passed")
