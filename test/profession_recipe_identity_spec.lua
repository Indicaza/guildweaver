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
GetServerTime = function() return 1791523133 end

GetProfessions = function()
    return 1
end

GetProfessionInfo = function(index)
    if index == 1 then
        return "Tailoring", 136249, 102, 150, 0, 0, 197, 0, nil, nil, "Tailoring"
    end
end

C_TradeSkillUI = {
    GetAllRecipeIDs = function()
        return { 120001 }
    end,
    GetBaseProfessionInfo = function()
        return {
            professionID = 197,
            professionName = "Tailoring",
            skillLevel = 102,
            maxSkillLevel = 150,
        }
    end,
    GetChildProfessionInfo = function()
        return {
            professionID = 2823,
            professionName = "Classic Tailoring",
            skillLevel = 102,
            maxSkillLevel = 150,
        }
    end,
    GetRecipeInfo = function(recipeId)
        return {
            recipeID = recipeId,
            name = "Brown Linen Robe",
            icon = 132665,
            learned = true,
            craftable = true,
            relativeDifficulty = 2,
            skillLineAbilityID = 9001,
            categoryID = 1,
        }
    end,
    GetTradeSkillLineForRecipe = function()
        return 2823, "Classic Tailoring"
    end,
}

local addon = { version = "test" }
local function loadAddonFile(path)
    local chunk = assert(loadfile(path))
    return chunk("Guildweaver", addon)
end

loadAddonFile("Data/Store.lua")
addon.Store.Initialize()
loadAddonFile("Data/ProfessionTelemetry.lua")
loadAddonFile("Data/ProfessionRecipeLink.lua")

local professions = addon.ProfessionTelemetry
local book = professions.CollectOpenRecipeBook("tradeskill")
truthy(book, "modern recipe book")
equal(book.profession.skillLineId, 2823, "child profession id")
equal(book.profession.parentSkillLineId, 197, "base profession id")
equal(#book.recipes, 1, "recipe captured")

local characterKey = "classic beta pve 2:quill riftward"
truthy(professions.RememberRecipeBook(characterKey, book), "recipe book stored")

local payload = professions.BuildPayload(characterKey)
equal(#payload.professions, 1, "canonical profession count")
equal(payload.professions[1].skillLineId, 197, "book attached to base profession")
equal(payload.professions[1].name, "Tailoring", "base profession retained")
equal(payload.professions[1].recipeBook.recipeCount, 1, "recipe book visible")
equal(payload.professions[1].recipes[1].recipeId, 120001, "recipe visible")

local override = professions.ToCharacterRecipeOverride(book)
equal(override.professionId, 197, "character merge uses base profession id")
equal(override.childProfessionId, 2823, "child profession retained for diagnostics")
equal(#override.recipes, 1, "character override keeps recipes")

print("profession recipe identity spec passed")
