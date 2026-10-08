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
GetServerTime = function() return 1791392500 end
GetRealmName = function() return "Classic Beta PvE 2" end
GetLocale = function() return "enUS" end

local descriptionLoaded = false
local Globals = _G
Globals.C_Traits = {
    GetTreeHash = function(treeId)
        equal(treeId, 1111, "tree hash id")
        return "tree-hash-v1"
    end,
}
Globals.C_Spell = {
    GetSpellName = function(spellId)
        equal(spellId, 14162, "spell name id")
        return "Improved Eviscerate"
    end,
    GetSpellTexture = function() return 132292 end,
    GetSpellDescription = function()
        if descriptionLoaded then
            return "Increases the damage done by your Eviscerate ability by 15%."
        end
        return nil
    end,
    GetSpellLink = function() return "|Hspell:14162|h[Improved Eviscerate]|h" end,
}
Globals.C_TooltipInfo = {
    GetSpellByID = function(spellId)
        equal(spellId, 14162, "tooltip spell id")
        return {
            lines = {
                { leftText = "Improved Eviscerate", leftColor = { r = 1, g = 0.82, b = 0, a = 1 } },
                { leftText = "Rank 1/3" },
                { leftText = "Increases Eviscerate damage by 15%." },
            },
        }
    end,
}

local addon = { version = "test" }
local function loadAddonFile(path)
    local chunk = assert(loadfile(path))
    return chunk("Guildweaver", addon)
end

loadAddonFile("Data/Store.lua")
addon.Store.Initialize()
loadAddonFile("Data/CharacterIdentity.lua")
loadAddonFile("Data/SpellTelemetry.lua")
loadAddonFile("Data/TelemetrySchema.lua")

addon.CharacterStats = {
    Capture = function()
        return {
            schemaVersion = 1,
            attributes = { agility = { current = 42, effective = 48, positive = 6, negative = 0 } },
        }
    end,
}

loadAddonFile("Data/CharacterTelemetryEnrichment.lua")

local function makeSnapshot()
    return {
        schemaVersion = 2,
        capturedAt = 1791392500,
        addonVersion = "test",
        characterKey = "classic beta pve 2:rook",
        characterId = "character-rook",
        name = "Rook",
        realm = "Classic Beta PvE 2",
        gameBuild = { build = "70245", version = "1.60.1", interface = 16001 },
        level = 22,
        race = { id = 4, name = "Night Elf", file = "NightElf" },
        class = { id = 4, name = "Rogue", file = "ROGUE" },
        specialization = {
            index = 1,
            id = 259,
            name = "Assassination",
            description = "A deadly master of poisons.",
            icon = 132292,
            role = "DAMAGER",
        },
        professions = {},
        equipment = {},
        talents = {
            api = "traits",
            kind = "combat",
            configId = 12467088,
            name = "Rogue",
            treeIds = { 1111 },
            pointsSpent = 1,
            pointsAvailable = 0,
            currencies = {},
            trees = {
                {
                    id = 1111,
                    rootNodeId = 105708,
                    nodes = {
                        {
                            id = 105708,
                            type = 0,
                            position = { x = 5020, y = 2130 },
                            activeRank = 1,
                            currentRank = 1,
                            ranksPurchased = 1,
                            maxRanks = 3,
                            isAvailable = true,
                            isVisible = true,
                            meetsEdgeRequirements = true,
                            conditionIds = { 43441 },
                            conditions = {
                                { id = 43441, type = 1, isMet = true, isGate = true, isSufficient = true, ranksGranted = 0 },
                            },
                            entries = {
                                {
                                    id = 130437,
                                    definitionId = 135238,
                                    spellId = 14162,
                                    maxRanks = 3,
                                    selected = true,
                                    rank = 1,
                                    isAvailable = true,
                                },
                            },
                        },
                    },
                    edges = {},
                },
            },
        },
    }
end

local streamKey = "talent_tree_definition:rogue:259:1111:tree-hash-v1:enus"
local snapshot = makeSnapshot()
addon.Store.SetCharacterSnapshot(snapshot.characterKey, snapshot)

equal(snapshot.schemaVersion, 3, "character schema")
equal(snapshot.stats.attributes.agility.effective, 48, "character stats preserved")
truthy(snapshot.talents.nodeStates, "node states included")
equal(snapshot.talents.nodeStates[1].nodeId, 105708, "node state id")
equal(snapshot.talents.nodeStates[1].isAvailable, true, "node availability")
equal(snapshot.talents.nodeStates[1].conditions[1].isMet, true, "condition state")
equal(snapshot.talents.nodeStates[1].entries[1].isActiveEntry, true, "entry active state")
equal(snapshot.talents.treeHashes[1].treeId, 1111, "tree hash state id")
equal(snapshot.talents.treeHashes[1].treeHash, "tree-hash-v1", "tree hash state value")

local definition = GuildweaverDB.sync.outbound.telemetry[streamKey]
truthy(definition, "versioned definition emitted")
equal(definition.revision, 1, "definition emitted once")
equal(definition.envelope.payload.schemaVersion, 3, "definition schema")
equal(definition.envelope.payload.treeHash, "tree-hash-v1", "definition tree hash")
equal(definition.envelope.payload.locale, "enUS", "definition locale")
equal(definition.envelope.payload.specialization.id, 259, "definition specialization")

local entry = definition.envelope.payload.nodes[1].entries[1]
equal(entry.spellId, 14162, "spell id")
equal(entry.name, "Improved Eviscerate", "resolved talent name")
equal(entry.iconFileDataId, 132292, "resolved talent icon")
equal(entry.description, nil, "description initially unavailable")
equal(entry.spellLink, "|Hspell:14162|h[Improved Eviscerate]|h", "resolved spell link")
equal(entry.tooltip.source, "C_TooltipInfo.GetSpellByID", "tooltip source")
equal(entry.tooltip.lines[2].left, "Rank 1/3", "tooltip rank line")
truthy(entry.tooltip.lines[1].leftColor, "tooltip color retained")

descriptionLoaded = true
local refreshedSnapshot = makeSnapshot()
refreshedSnapshot.capturedAt = refreshedSnapshot.capturedAt + 1
addon.Store.SetCharacterSnapshot(refreshedSnapshot.characterKey, refreshedSnapshot)

local healedDefinition = GuildweaverDB.sync.outbound.telemetry[streamKey]
equal(healedDefinition.revision, 2, "definition revision advances when metadata heals")
equal(
    healedDefinition.envelope.payload.nodes[1].entries[1].description,
    "Increases the damage done by your Eviscerate ability by 15%.",
    "description heals on later capture"
)

print("talent enrichment spec passed")
