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
GetServerTime = function() return 1791322510 end

local addon = { version = "test" }
local function loadAddonFile(path)
    local chunk = assert(loadfile(path))
    return chunk("Guildweaver", addon)
end

loadAddonFile("Data/Store.lua")
addon.Store.Initialize()
loadAddonFile("Data/TelemetryEnvelope.lua")
loadAddonFile("Telemetry/Domain.lua")
loadAddonFile("Telemetry/Domains/Character.lua")
loadAddonFile("Telemetry/Domains/Stats.lua")
loadAddonFile("Telemetry/Domains/Equipment.lua")
loadAddonFile("Telemetry/Domains/Professions.lua")
loadAddonFile("Telemetry/Domains/Talents.lua")
loadAddonFile("Telemetry/Registry.lua")

local snapshot = {
    schemaVersion = 3,
    capturedAt = 1791322510,
    characterKey = "darkwing:rook",
    characterId = "character-rook",
    name = "Rook",
    realm = "Darkwing",
    region = "US",
    level = 20,
    class = { id = 1, name = "Warrior", token = "WARRIOR" },
    race = { id = 4, name = "Night Elf", token = "NightElf" },
    specialization = { id = 73, name = "Protection" },
    gameBuild = { version = "1.60.1", build = "70235", interface = 16001 },
    stats = { schemaVersion = 1, attributes = { strength = { effective = 83 } } },
    equipment = { { slot = "main_hand", itemId = 5191, itemLevel = 18 } },
    professions = { { skillLineId = 164, name = "Blacksmithing", skillLevel = 150 } },
    talents = { api = "legacy", pointsSpent = 11, allocations = { { nodeId = 1, rank = 5 } } },
}

local first = addon.Telemetry.PublishCharacterSnapshot(snapshot)
truthy(first.Character.changed, "character first publish")
truthy(first.Stats.changed, "stats first publish")
truthy(first.Equipment.changed, "equipment first publish")
truthy(first.Professions.changed, "professions first publish")
truthy(first.Talents.changed, "talents first publish")

local telemetry = GuildweaverDB.sync.outbound.telemetry
local expected = {
    character = "character:character-rook",
    stats = "stats:character-rook",
    equipment = "equipment:character-rook",
    professions = "professions:character-rook",
    talents = "talents:character-rook",
}

for eventType, streamKey in pairs(expected) do
    local record = telemetry[streamKey]
    truthy(record, eventType .. " stream")
    equal(record.revision, 1, eventType .. " revision")
    equal(record.envelope.schemaVersion, 1, eventType .. " envelope version")
    equal(record.envelope.payloadSchemaVersion, 1, eventType .. " payload version")
    equal(record.envelope.eventType, eventType, eventType .. " event type")
    equal(record.envelope.characterId, snapshot.characterId, eventType .. " character id")
    equal(record.envelope.payload.schemaVersion, 1, eventType .. " embedded payload version")
end

local characterPayload = telemetry[expected.character].envelope.payload
equal(characterPayload.name, "Rook", "character owns identity")
equal(characterPayload.equipment, nil, "character excludes equipment")
equal(characterPayload.professions, nil, "character excludes professions")
equal(characterPayload.talents, nil, "character excludes talents")
equal(characterPayload.stats, nil, "character excludes stats")

equal(telemetry[expected.stats].envelope.payload.stats.attributes.strength.effective, 83, "stats payload")
equal(telemetry[expected.equipment].envelope.payload.equipment[1].itemId, 5191, "equipment payload")
equal(telemetry[expected.professions].envelope.payload.professions[1].skillLineId, 164, "professions payload")
equal(telemetry[expected.talents].envelope.payload.talents.pointsSpent, 11, "talents payload")

local second = addon.Telemetry.PublishCharacterSnapshot(snapshot)
equal(second.Character.changed, false, "unchanged character deduped")
equal(second.Equipment.changed, false, "unchanged equipment deduped")
equal(telemetry[expected.character].revision, 1, "character revision stable")

table.insert(snapshot.equipment, { slot = "off_hand", itemId = 1201, itemLevel = 17 })
local third = addon.Telemetry.PublishCharacterSnapshot(snapshot)
equal(third.Character.changed, false, "character unaffected by equipment change")
truthy(third.Equipment.changed, "equipment changed")
equal(telemetry[expected.equipment].revision, 2, "equipment revision increments independently")
equal(telemetry[expected.character].revision, 1, "character revision remains independent")
equal(telemetry[expected.stats].revision, 1, "stats revision remains independent")

print("telemetry domains spec passed")