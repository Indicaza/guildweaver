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

GetSpecialization = function() return 1 end
GetSpecializationInfo = function()
    return 1491, "Warrior", "A master of armed combat.", 132355, "DAMAGER", 1, 12, "Warrior", 12, true
end
GetNumTalentTabs = function() return 3 end
GetTalentTabInfo = function(index)
    local tabs = {
        { 71, "Arms", "A battle-hardened master of two-handed weapons.", 132355, 5, "WarriorArms", 5, true },
        { 72, "Fury", "A furious berserker wielding a weapon in each hand.", 132347, 5, "WarriorFury", 5, true },
        { 73, "Protection", "A stalwart protector who uses a shield.", 132341, 2, "WarriorProtection", 2, true },
    }
    local tab = tabs[index]
    return unpack(tab)
end
GetFileIDFromPath = function(path)
    local ids = {
        ["Interface\\TalentFrame\\WarriorArms-TopLeft"] = 900001,
        ["Interface\\TalentFrame\\WarriorArms-TopRight"] = 900002,
        ["Interface\\TalentFrame\\WarriorArms-BottomLeft"] = 900003,
        ["Interface\\TalentFrame\\WarriorArms-BottomRight"] = 900004,
    }
    return ids[path] or 0
end

C_SpecializationInfo = {
    GetSpecialization = GetSpecialization,
    GetSpecializationInfo = GetSpecializationInfo,
}

C_Traits = {
    GetTreeInfo = function(configId, treeId)
        equal(configId, 12467088, "tree art config")
        equal(treeId, 1117, "tree art id")
        return {
            rootNodeID = 105708,
            hideSingleRankNumbers = false,
            cannotRefund = false,
            uiTextureKit = "warrior-talents",
            titleText = "Warrior",
        }
    end,
}

local addon = { version = "test" }
local function loadAddonFile(path)
    local chunk = assert(loadfile(path))
    return chunk("Guildweaver", addon)
end

loadAddonFile("Data/TelemetrySchema.lua")
loadAddonFile("Data/TalentArtTelemetry.lua")

local snapshot = {
    schemaVersion = 2,
    gameBuild = { build = "70245", version = "1.60.1", interface = 16001 },
    class = { id = 1, name = "Warrior", file = "WARRIOR" },
    specialization = { index = 1, id = 1491, name = "Warrior", icon = 132355, role = "DAMAGER" },
    professions = {},
    equipment = {},
    talents = {
        api = "traits",
        kind = "combat",
        configId = 12467088,
        name = "Warrior",
        treeIds = { 1117 },
        trees = {
            {
                id = 1117,
                rootNodeId = 105708,
                nodes = {},
                edges = {},
            },
        },
    },
}

local normalized, definitions = addon.TelemetrySchema.NormalizeCharacterSnapshot(snapshot)
truthy(normalized.talents.art, "character talent art")
equal(normalized.specialization.background, "Warrior", "specialization background")
equal(normalized.specialization.pointsSpent, 12, "specialization points")
equal(normalized.talents.art.specialization.iconFileDataId, 132355, "specialization icon")
equal(#normalized.talents.art.talentTabs, 3, "talent tab count")
equal(normalized.talents.art.talentTabs[1].background, "WarriorArms", "arms background")
equal(
    normalized.talents.art.talentTabs[1].backgroundTextures.topLeft.path,
    "Interface\\TalentFrame\\WarriorArms-TopLeft",
    "classic background texture path"
)
equal(normalized.talents.art.talentTabs[1].backgroundTextures.topLeft.fileDataId, 900001, "background file data id")
equal(normalized.talents.art.talentTabs[1].backgroundTextures.bottomRight.fileDataId, 900004, "background bottom right file data id")
equal(normalized.talents.art.talentTabs[2].backgroundTextures.topLeft.fileDataId, nil, "unresolved background id stays nil")

local definition = definitions[1]
truthy(definition.art, "definition art")
equal(definition.art.schemaVersion, 1, "art schema")
equal(definition.art.specialization.background, "Warrior", "definition specialization art")
equal(definition.art.talentTabs[2].background, "WarriorFury", "definition fury art")
equal(definition.art.tree.uiTextureKit, "warrior-talents", "tree texture kit")
equal(definition.art.tree.titleText, "Warrior", "tree title")

print("talent art spec passed")
