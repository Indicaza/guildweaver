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

local now = 1000
local level = 20

GuildweaverDB = nil
GetServerTime = function() return now end
GetCurrentRegion = function() return 1 end
GetBuildInfo = function() return "1.60.1", "60001", "Oct 5 2026", 16001 end
UnitFullName = function() return "Rook", "Realm" end
UnitName = function() return "Rook" end
GetRealmName = function() return "Realm" end
UnitRace = function() return "Night Elf", "NightElf", 4 end
UnitClass = function() return "Warrior", "WARRIOR", 1 end
UnitLevel = function() return level end
UnitSex = function() return 2 end
GetGuildInfo = function() return nil end
GetProfessions = function() return nil, nil, nil, nil, nil end
GetProfessionInfo = function() return nil end
GetInventorySlotInfo = function() return 1 end
GetInventoryItemLink = function() return nil end
C_SpecializationInfo = nil
C_ClassTalents = nil
C_Traits = nil
C_ProfSpecs = nil
C_TradeSkillUI = nil

local GW = { version = "test" }
assert(loadfile("Data/Store.lua"))("Guildweaver", GW)
assert(loadfile("Data/ProfessionTelemetry.lua"))("Guildweaver", GW)
assert(loadfile("Systems/Character.lua"))("Guildweaver", GW)

GW.Store.Initialize()
local first = GW.Character.Capture("FIRST")
truthy(first, "first snapshot")
equal(first.name, "Rook", "character name")
equal(first.region, "US", "region")
equal(first.gameBuild.build, "60001", "game build")
equal(#first.equipment, 0, "empty equipment")
truthy(first.characterId, "anonymous character id")
truthy(GW.Store.GetInstallationId(), "anonymous installation id")

-- Whole snapshots stay local; each data type has its own telemetry stream.
equal(GuildweaverDB.sync.outbound.characters, nil, "no legacy character mailbox")
equal(GuildweaverDB.sync.outbound.telemetry["character_snapshot:" .. first.characterId], nil, "no character_snapshot stream")
truthy(GuildweaverDB.meta.characterFingerprints["realm:rook"], "snapshot fingerprint kept for change detection")

now = 1001
local fingerprint = GuildweaverDB.meta.characterFingerprints["realm:rook"]
GW.Character.Capture("UNCHANGED")
equal(GuildweaverDB.meta.characterFingerprints["realm:rook"], fingerprint, "unchanged capture keeps its fingerprint")

level = 21
GW.Character.Capture("LEVEL_UP")
truthy(GuildweaverDB.meta.characterFingerprints["realm:rook"] ~= fingerprint, "changed capture updates its fingerprint")

C_ClassTalents = {
    GetActiveConfigID = function() return 10 end,
}
C_Traits = {
    GetConfigInfo = function()
        return { name = "Arms", treeIDs = { 20 } }
    end,
    GetTreeInfo = function()
        return { rootNodeID = 30 }
    end,
    GetTreeNodes = function()
        return { 30 }
    end,
    GetTreeCurrencyInfo = function()
        return { { traitCurrencyID = 1, quantity = 1, spent = 2, spentInTree = 2 } }
    end,
    GetNodeInfo = function()
        return {
            posX = 100,
            posY = 200,
            entryIDs = { 40 },
            activeEntry = { entryID = 40, rank = 2 },
            activeRank = 2,
            currentRank = 2,
            ranksPurchased = 2,
            maxRanks = 2,
            isAvailable = true,
            isVisible = true,
            meetsEdgeRequirements = true,
            conditionIDs = { 50 },
            visibleEdges = { { targetNode = 31, type = 3, isActive = true } },
        }
    end,
    GetEntryInfo = function()
        return { definitionID = 60, maxRanks = 2, isAvailable = true }
    end,
    GetDefinitionInfo = function()
        return { spellID = 70, overrideIcon = 80, overrideName = "Mock Talent" }
    end,
    GetConditionInfo = function()
        return { type = 1, isMet = true, isGate = false }
    end,
}

now = 1002
local talentSnapshot = GW.Character.Capture("TALENT_UPDATE")
equal(talentSnapshot.talents.api, "traits", "talent api")
equal(talentSnapshot.talents.configId, 10, "talent config")
equal(talentSnapshot.talents.pointsSpent, 2, "talent points spent")
equal(talentSnapshot.talents.pointsAvailable, 1, "talent points available")
equal(talentSnapshot.talents.trees[1].nodes[1].entries[1].spellId, 70, "talent spell")
equal(talentSnapshot.talents.trees[1].nodes[1].entries[1].rank, 2, "talent rank")
equal(talentSnapshot.talents.trees[1].edges[1].targetNodeId, 31, "talent edge")

GetProfessions = function() return 1, nil, nil, nil, nil end
GetProfessionInfo = function()
    return "Blacksmithing", 123, 100, 150, nil, nil, 164, 5, nil, nil, "Blacksmithing"
end
C_TradeSkillUI = {
    GetAllRecipeIDs = function() return { 1001 } end,
    GetRecipeInfo = function()
        return {
            name = "Copper Bracers",
            learned = true,
            icon = 456,
            skillLineAbilityID = 789,
            relativeDifficulty = 2,
            maxTrivialLevel = 25,
        }
    end,
    GetBaseProfessionInfo = function()
        return { professionID = 164, professionName = "Blacksmithing", skillLevel = 100, maxSkillLevel = 150, skillModifier = 5 }
    end,
    GetChildProfessionInfo = function()
        return { professionID = 164, professionName = "Blacksmithing", skillLevel = 100, maxSkillLevel = 150, skillModifier = 5 }
    end,
    GetRecipeOutputItemData = function()
        return {
            itemID = 2853,
            icon = 456,
            hyperlink = "|cff1eff00|Hitem:2853::::::::21:::::::|h[Copper Bracers]|h|r",
        }
    end,
    GetRecipeSchematic = function()
        return {
            reagentSlotSchematics = {
                {
                    dataSlotIndex = 1,
                    quantityRequired = 2,
                    required = true,
                    reagents = {
                        { itemID = 2840, quantityRequired = 2 },
                    },
                },
            },
        }
    end,
    GetTradeSkillLineForRecipe = function()
        return 164, "Blacksmithing", 164
    end,
}

now = 1003
local recipeSnapshot = GW.Character.CaptureProfessionRecipes("TRADE_SKILL_SHOW")
truthy(recipeSnapshot, "recipe snapshot")
equal(recipeSnapshot.professions[1].recipes[1].id, 1001, "recipe id")
equal(recipeSnapshot.professions[1].recipes[1].known, true, "recipe known")
equal(recipeSnapshot.professions[1].recipes[1].craftedItemId, 2853, "crafted item id")
equal(recipeSnapshot.professions[1].recipes[1].reagents[1].reagents[1].itemId, 2840, "recipe reagent")

C_TradeSkillUI.GetRecipeInfo = function() return nil end
now = 1004
local unavailable = GW.Character.CaptureProfessionRecipes("PARTIAL_API")
equal(unavailable, nil, "partial recipe api")
equal(GW.Character.GetCurrentSnapshot().professions[1].recipes[1].id, 1001, "preserved recipes")

print("character telemetry tests passed")
