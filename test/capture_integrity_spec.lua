local function equal(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function truthy(value, label)
    if not value then
        error((label or "value") .. ": expected truthy value", 2)
    end
end

GuildweaverDB = nil
GetServerTime = function() return 1791450000 end
GetRealmName = function() return "Classic Beta PvE 2" end
UnitFullName = function() return "Rook", "Classic Beta PvE 2" end
UnitName = function() return "Rook" end

local GW = { version = "test", Character = {} }
assert(loadfile("Data/Store.lua"))("Guildweaver", GW)
GW.Store.Initialize()
assert(loadfile("Data/CharacterIdentity.lua"))("Guildweaver", GW)
assert(loadfile("Data/TelemetrySchema.lua"))("Guildweaver", GW)

local originalCaptureCount = 0
GW.Character.Capture = function(reason)
    originalCaptureCount = originalCaptureCount + 1
    local snapshot = {
        schemaVersion = 2,
        capturedAt = GetServerTime(),
        reason = reason,
        characterKey = "classic beta pve 2:rook",
        characterId = "character-rook",
        name = "Rook",
        realm = "Classic Beta PvE 2",
        region = "US",
        level = 30,
        race = { id = 4, file = "NightElf", name = "Night Elf" },
        class = { id = 1, file = "WARRIOR", name = "Warrior" },
        professions = {},
        equipment = {},
    }
    GW.Store.SetCharacterSnapshot(snapshot.characterKey, snapshot)
    return snapshot
end

GW.Character.GetCurrentSnapshot = function()
    return GuildweaverDB.characters["classic beta pve 2:rook"]
end

assert(loadfile("Data/CaptureIntegrity.lua"))("Guildweaver", GW)

local logout = GW.Character.Capture("PLAYER_LOGOUT")
equal(logout.schemaVersion, 3, "normalized schema")
truthy(logout.installationId, "installation id preserved")
equal(logout.capture.integrityVersion, 1, "integrity version")
equal(logout.capture.reason, "PLAYER_LOGOUT", "capture reason")
equal(logout.capture.sections.identity, "complete", "identity remains authoritative")
equal(logout.capture.sections.equipment, "unavailable", "logout equipment is non-authoritative")
equal(logout.capture.sections.talents, "unavailable", "logout talents are non-authoritative")
equal(logout.capture.sections.professions, "unavailable", "logout professions are non-authoritative")
equal(logout.capture.sections.recipes, "unavailable", "logout recipes are non-authoritative")

local enteringWorld = GW.Character.Capture("PLAYER_ENTERING_WORLD")
equal(enteringWorld.capture.sections.equipment, "partial", "entering world equipment is partial")
equal(enteringWorld.capture.sections.professions, "partial", "entering world professions are partial")

local equipment = GW.Character.Capture("PLAYER_EQUIPMENT_CHANGED")
equal(equipment.capture.sections.equipment, "complete", "equipment event is authoritative")
equal(equipment.capture.sections.recipes, "partial", "ordinary capture cannot clear recipes")

local tradeSkill = GW.Character.Capture("TRADE_SKILL_SHOW")
equal(tradeSkill.capture.sections.professions, "complete", "trade skill professions are authoritative")
equal(tradeSkill.capture.sections.recipes, "complete", "trade skill recipes are authoritative")

local stored = GW.Store.GetCharacterSnapshot("classic beta pve 2:rook")
truthy(stored, "stored snapshot")
equal(stored.capture.sections.recipes, "complete", "capture contract reaches the stored snapshot")
equal(stored.installationId, GW.Store.GetInstallationId(), "installation id reaches the stored snapshot")

local richSnapshot = GW.Character.GetCurrentSnapshot()
local richFingerprint = GuildweaverDB.meta.characterFingerprints["classic beta pve 2:rook"]
local capturesBeforeTeardown = originalCaptureCount
local teardown = GW.Character.Capture("PLAYER_LOGOUT")
equal(teardown, richSnapshot, "logout preserves rich snapshot")
equal(originalCaptureCount, capturesBeforeTeardown, "logout does not recapture from teardown APIs")
equal(GuildweaverDB.meta.characterFingerprints["classic beta pve 2:rook"], richFingerprint, "logout does not replace the rich snapshot")
equal(teardown.capture.reason, "TRADE_SKILL_SHOW", "last rich capture metadata survives logout")
equal(teardown.capture.sections.professions, "complete", "rich profession section survives logout")

local reloadFlush = GW.Character.Capture("RELOAD_FLUSH")
equal(reloadFlush, richSnapshot, "reload flush preserves rich snapshot")
equal(originalCaptureCount, capturesBeforeTeardown, "reload flush does not recapture")

print("capture integrity spec passed")