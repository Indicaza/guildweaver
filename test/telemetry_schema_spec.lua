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

local function falsy(value, label)
    if value then
        error((label or "value") .. ": expected falsy value", 2)
    end
end

GuildweaverDB = nil
GetServerTime = function() return 1791322510 end
GetRealmName = function() return "Classic Beta PvE 2" end

local addon = { version = "test" }
local function loadAddonFile(path)
    local chunk = assert(loadfile(path))
    return chunk("Guildweaver", addon)
end

loadAddonFile("Data/Store.lua")
addon.Store.Initialize()
loadAddonFile("Data/CharacterIdentity.lua")
loadAddonFile("Data/TelemetrySchema.lua")

local snapshot = {
    schemaVersion = 2,
    capturedAt = 1791322510,
    reason = "PLAYER_LOGOUT",
    addonVersion = "0.5.0-alpha.1",
    characterKey = "darkwing:rook",
    characterId = "character-existing",
    name = "Rook",
    realm = "Darkwing",
    level = 7,
    sex = 3,
    bodyType = "female",
    gameBuild = {
        interface = 16001,
        version = "1.60.1",
        build = "70235",
    },
    race = { id = 4, file = "NightElf", name = "Night Elf" },
    class = { id = 4, file = "ROGUE", name = "Rogue" },
    specialization = { index = 1, id = 0, name = "", description = "", role = "" },
    professions = {
        {
            id = 129,
            skillLineId = 129,
            name = "First Aid",
            skillLineName = "First Aid",
            kind = "archaeology",
            icon = 135966,
            skillLevel = 1,
            maxSkillLevel = 75,
            skillModifier = 0,
            specialization = { configId = 0, treeIds = {} },
        },
    },
    equipment = {
        {
            slot = "ChestSlot",
            slotId = 5,
            itemId = 5957,
            itemLink = "|cnIQ2:|Hitem:5957:15:::::::7:1488::::::::Player-4620-014B5E8E:|h[Handstitched Leather Vest]|h|r",
            itemString = "item:5957:15:::::::7:1488::::::::Player-4620-014B5E8E:",
            quality = 2,
            icon = 132760,
            enchantId = 15,
            gemIds = {},
            bonusIds = {},
            modifierData = { 5957, 15, "", "", "", "", "", "", 7, 1488 },
            class = "Armor",
            subclass = "Leather",
            classId = 4,
            subclassId = 2,
            equipLocation = "INVTYPE_CHEST",
        },
    },
    talents = {
        api = "traits",
        kind = "combat",
        configId = 12467088,
        name = "Rogue",
        treeIds = { 1111 },
        pointsSpent = 1,
        pointsAvailable = 0,
        currencies = {
            { treeId = 1111, traitCurrencyId = 3820, quantity = 0, spent = 1, spentInTree = 1 },
        },
        trees = {
            {
                id = 1111,
                rootNodeId = 105708,
                edges = {
                    { sourceNodeId = 105708, targetNodeId = 105709, type = 2, visualStyle = 1, isActive = true },
                },
                nodes = {
                    {
                        id = 105708,
                        type = 0,
                        maxRanks = 3,
                        currentRank = 0,
                        activeRank = 0,
                        ranksPurchased = 0,
                        position = { x = 5020, y = 2130 },
                        conditionIds = {},
                        entries = {
                            {
                                id = 130437,
                                definitionId = 135238,
                                spellId = 14162,
                                icon = 132292,
                                name = "Improved Eviscerate",
                                maxRanks = 3,
                                selected = true,
                                rank = 0,
                            },
                        },
                    },
                    {
                        id = 105709,
                        type = 0,
                        maxRanks = 1,
                        currentRank = 1,
                        activeRank = 1,
                        ranksPurchased = 1,
                        position = { x = 1620, y = 4530 },
                        conditionIds = { 43441 },
                        entries = {
                            {
                                id = 130438,
                                definitionId = 135239,
                                spellId = 1310707,
                                icon = 132147,
                                name = "Purchased Talent",
                                maxRanks = 1,
                                selected = true,
                                rank = 1,
                            },
                        },
                    },
                },
            },
        },
    },
}

addon.Store.SetCharacterSnapshot("darkwing:rook", snapshot)

equal(snapshot.schemaVersion, 3, "character schema")
equal(snapshot.realm, "Classic Beta PvE 2", "canonical realm")
equal(snapshot.characterKey, "classic beta pve 2:rook", "canonical key")
equal(snapshot.class.token, "ROGUE", "class token")
equal(snapshot.race.token, "NightElf", "race token")
falsy(snapshot.class.file, "legacy class file removed")
falsy(snapshot.specialization, "empty specialization omitted")
falsy(snapshot.captureReason, "capture reason is not state")
falsy(snapshot.reason, "legacy reason removed")

equal(snapshot.professions[1].skillLineId, 129, "profession skill line")
equal(snapshot.professions[1].kind, "first_aid", "first aid kind")
equal(snapshot.professions[1].iconFileDataId, 135966, "profession icon")
falsy(snapshot.professions[1].id, "duplicate profession id removed")
falsy(snapshot.professions[1].skillLineName, "duplicate profession name removed")
falsy(snapshot.professions[1].specialization, "empty profession specialization omitted")

local item = snapshot.equipment[1]
equal(item.slot, "chest", "normalized equipment slot")
equal(item.itemId, 5957, "equipment item id")
equal(item.name, "Handstitched Leather Vest", "item name derived from link")
equal(item.qualityId, 2, "item quality id")
equal(item.iconFileDataId, 132760, "item icon file data id")
equal(item.enchantId, 15, "item enchant")
equal(item.linkLevel, 7, "item link level")
equal(item.specializationId, 1488, "item link specialization")
truthy(item.rawItemString:find("Player%-REDACTED"), "player guid scrubbed from raw item string")
falsy(item.rawItemString:find("014B5E8E"), "raw player guid removed")
falsy(item.modifierData, "serialized modifier array removed")
falsy(item.itemString, "legacy item string field removed")

local talents = snapshot.talents
equal(talents.configId, 12467088, "talent config")
equal(#talents.allocations, 1, "only purchased talents remain in character state")
equal(talents.allocations[1].nodeId, 105709, "purchased talent node")
equal(talents.allocations[1].activeEntryId, 130438, "active purchased entry")
falsy(talents.trees, "static talent tree removed from character state")

local definitionKey = "talent_tree_definition:rogue:70235:1111"
local definitionRecord = GuildweaverDB.sync.outbound.telemetry[definitionKey]
truthy(definitionRecord, "talent definition stream emitted")
equal(definitionRecord.envelope.eventType, "talent_tree_definition", "talent definition event type")
equal(definitionRecord.envelope.payload.nodes[1].entries[1].spellId, 14162, "definition keeps spell id")
equal(definitionRecord.envelope.payload.nodes[1].entries[1].iconFileDataId, 132292, "definition keeps icon id")
falsy(definitionRecord.envelope.payload.nodes[1].entries[1].selected, "dynamic selected flag removed from definition")

addon.Store.SetTelemetrySnapshot("character_snapshot:character-existing", {
    schemaVersion = 1,
    eventType = "character_snapshot",
    capturedAt = snapshot.capturedAt,
    gameBuild = snapshot.gameBuild,
    realm = "Darkwing",
    characterId = snapshot.characterId,
    payload = snapshot,
})

local characterRecord = GuildweaverDB.sync.outbound.telemetry["character_snapshot:character-existing"]
equal(characterRecord.envelope.realm, "Classic Beta PvE 2", "telemetry envelope realm")
equal(characterRecord.envelope.payload.schemaVersion, 3, "telemetry payload schema")
equal(definitionRecord.revision, 1, "definition revision remains stable")

print("telemetry schema spec passed")
