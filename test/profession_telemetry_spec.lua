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

local serverTime = 1791322510
GuildweaverDB = nil
GetServerTime = function() return serverTime end

-- Item info for the crafted item and reagents.
local ITEMS = {
    [2840] = { "Copper Bar", "|cffffffff|Hitem:2840::::::::|h[Copper Bar]|h|r", 1, 135232 },
    [2862] = { "Rough Sharpening Stone", "|cffffffff|Hitem:2862::::::::|h[Rough Sharpening Stone]|h|r", 1, 135248 },
    [2835] = { "Rough Stone", "|cffffffff|Hitem:2835::::::::|h[Rough Stone]|h|r", 1, 135232 },
}
GetItemInfo = function(link)
    local id = tonumber(link) or tonumber(tostring(link):match("item:(%d+)"))
    local item = ITEMS[id]
    if not item then
        return nil
    end
    return item[1], item[2], item[3], 5, 1, "Trade Goods", "Parts", 20, "", item[4]
end

local addon = { version = "test" }
local function loadAddonFile(path)
    local chunk = assert(loadfile(path))
    return chunk("Guildweaver", addon)
end

loadAddonFile("Data/Store.lua")
addon.Store.Initialize()
loadAddonFile("Data/ItemTelemetry.lua")
loadAddonFile("Data/TelemetryEnvelope.lua")
loadAddonFile("Data/ProfessionTelemetry.lua")
loadAddonFile("Telemetry/Domain.lua")
loadAddonFile("Telemetry/Domains/Professions.lua")

local professions = addon.ProfessionTelemetry
local domain = addon.TelemetryDomains.Professions

-- Profession identity --------------------------------------------------------

GetProfessions = function() return 1, nil, nil, 4, 5 end
GetProfessionInfo = function(index)
    if index == 1 then
        return "Blacksmithing", 136241, 120, 150, 30, 0, 164, 5, nil, nil, "Blacksmithing"
    elseif index == 4 then
        return "Fishing", 136245, 75, 150, 1, 0, 356, 0, nil, nil, "Fishing"
    elseif index == 5 then
        return "Cooking", 133971, 40, 75, 10, 0, 185, 0, nil, nil, "Cooking"
    end
end

local identity = professions.CollectProfessions()
equal(#identity, 3, "unlearned slots are skipped, later slots still read")
equal(identity[1].skillLineId, 164, "primary skill line")
equal(identity[1].kind, "primary", "primary kind")
equal(identity[1].skillModifier, 5, "skill modifier")
equal(identity[2].kind, "fishing", "fishing kind")
equal(identity[3].kind, "cooking", "cooking kind")

-- Modern recipe book ----------------------------------------------------------

C_TradeSkillUI = {
    GetAllRecipeIDs = function() return { 2674, 2660 } end,
    GetBaseProfessionInfo = function() return { professionID = 164, professionName = "Blacksmithing", skillLevel = 120, maxSkillLevel = 150 } end,
    GetRecipeInfo = function(recipeId)
        if recipeId == 2660 then
            return { recipeID = 2660, name = "Rough Sharpening Stone", icon = 135248, learned = true, craftable = true,
                relativeDifficulty = 3, numSkillUps = 1, maxTrivialLevel = 25, skillLineAbilityID = 777, categoryID = 1 }
        end
        return { recipeID = 2674, name = "Copper Bracers", icon = 132605, learned = false, relativeDifficulty = 0 }
    end,
    GetTradeSkillLineForRecipe = function() return 164, "Blacksmithing" end,
    GetRecipeOutputItemData = function(recipeId)
        if recipeId == 2660 then
            return { itemID = 2862, hyperlink = ITEMS[2862][2] }
        end
    end,
    GetRecipeSchematic = function(recipeId)
        if recipeId == 2660 then
            return {
                quantityMin = 1,
                quantityMax = 2,
                reagentSlotSchematics = {
                    { quantityRequired = 1, required = true, reagents = { { itemID = 2835 } } },
                },
            }
        end
        return { reagentSlotSchematics = {} }
    end,
    -- Remaining seconds count down like the game's; the ready time is fixed.
    GetRecipeCooldown = function(recipeId)
        if recipeId == 2660 then
            return 1791326110 - serverTime, true, nil, nil
        end
    end,
    GetRecipeDescription = function(recipeId)
        return recipeId == 2660 and "Sharpens a bladed weapon." or nil
    end,
}

local book = professions.CollectOpenRecipeBook("tradeskill")
truthy(book, "modern book")
equal(book.source, "C_TradeSkillUI", "modern source")
equal(#book.recipes, 2, "learned and unlearned recipes")
local stone = book.recipes[1]
equal(stone.recipeId, 2660, "recipes sorted by id")
equal(stone.known, true, "known state")
equal(stone.difficulty, "trivial", "difficulty named from relativeDifficulty")
equal(stone.skillUps, 1, "skill ups")
equal(stone.maxTrivialLevel, 25, "trivial threshold")
equal(stone.description, "Sharpens a bladed weapon.", "description")
equal(stone.crafted.itemId, 2862, "crafted item id")
equal(stone.crafted.name, "Rough Sharpening Stone", "crafted item enriched by shared item telemetry")
equal(stone.crafted.iconFileDataId, 135248, "crafted item icon")
equal(stone.crafted.maxQuantity, 2, "crafted quantity range")
equal(stone.reagents[1].itemId, 2835, "reagent id")
equal(stone.reagents[1].name, "Rough Stone", "reagent name enriched")
equal(stone.reagents[1].quantity, 1, "reagent quantity")
equal(stone.reagents[1].tooltip, nil, "reagents skip tooltips")
equal(stone.cooldown.isDayCooldown, true, "day cooldown")
equal(stone.cooldown.readyAt % 60, 0, "cooldown ready time rounded to a minute")
equal(book.recipes[2].known, false, "unlearned recipe")

-- Publishing ------------------------------------------------------------------

local snapshot = { characterKey = "darkwing:rook", characterId = "character-rook", realm = "Darkwing", capturedAt = serverTime }
-- Category and reagent details (Data/RecipeBookDetails.lua) travel with the book.
book.categories = { { categoryId = 2460, name = "Weapon Stones", parentCategoryId = 2425, order = 20 } }
book.items = { { itemId = 2835, name = "Rough Stone", tooltip = { lines = { { left = "Rough Stone" } } } } }
truthy(professions.RememberRecipeBook(snapshot.characterKey, book), "first recipe book stored")

local first = domain.Publish(snapshot)
truthy(first.changed, "first publish")
equal(first.streamKey, "profession_snapshot:character-rook", "stream key")
equal(first.envelope.eventType, "profession_snapshot", "event type")
equal(first.envelope.payloadSchemaVersion, 1, "payload schema version")
local payload = first.envelope.payload
equal(#payload.professions, 3, "all professions present")
local smithing = payload.professions[1]
equal(smithing.name, "Blacksmithing", "profession name")
equal(smithing.recipeBook.recipeCount, 2, "recipe count")
equal(smithing.recipeBook.knownCount, 1, "known count")
equal(smithing.recipeBook.source, "C_TradeSkillUI", "book source")
equal(smithing.recipes[1].crafted.name, "Rough Sharpening Stone", "recipes carried in payload")
equal(smithing.categories[1].name, "Weapon Stones", "recipe categories carried in payload")
equal(smithing.items[1].itemId, 2835, "reagent details carried in payload")
equal(payload.professions[2].recipes, nil, "professions without an opened window have no recipes")

-- Reopening the window a minute later with identical recipes changes nothing.
serverTime = serverTime + 30
local reopened = professions.CollectOpenRecipeBook("tradeskill")
reopened.categories = book.categories
reopened.items = book.items
equal(professions.RememberRecipeBook(snapshot.characterKey, reopened), false, "unchanged book not re-stored")
equal(domain.Publish(snapshot).changed, false, "unchanged professions deduped")

-- Skill gain changes the payload.
GetProfessionInfo = function(index)
    if index == 1 then
        return "Blacksmithing", 136241, 121, 150, 30, 0, 164, 5, nil, nil, "Blacksmithing"
    elseif index == 4 then
        return "Fishing", 136245, 75, 150, 1, 0, 356, 0, nil, nil, "Fishing"
    elseif index == 5 then
        return "Cooking", 133971, 40, 75, 10, 0, 185, 0, nil, nil, "Cooking"
    end
end
local skillUp = domain.Publish(snapshot)
truthy(skillUp.changed, "skill gain publishes")
equal(skillUp.revision, 2, "revision increments")
equal(skillUp.envelope.payload.professions[1].recipes[1].recipeId, 2660, "cached recipes survive identity refresh")

-- Logout: the profession API is unavailable, last known state is kept.
GetProfessions = function() error("unavailable during teardown") end
local teardown = domain.Publish({
    characterKey = snapshot.characterKey,
    characterId = snapshot.characterId,
    capture = { sections = { professions = "unavailable" } },
})
equal(teardown.changed, false, "teardown does not clear professions")

-- Legacy trade skill window ---------------------------------------------------

C_TradeSkillUI = nil
GetNumTradeSkills = function() return 2 end
GetTradeSkillLine = function() return "Blacksmithing", 121, 150 end
GetTradeSkillInfo = function(index)
    if index == 1 then
        return "Materials", "header"
    end
    return "Copper Chain Belt", "optimal", 0, false, nil, 2
end
GetTradeSkillRecipeLink = function() return "|cffffd000|Henchant:2661|h[Copper Chain Belt]|h|r" end
GetTradeSkillItemLink = function() return ITEMS[2840][2] end
GetTradeSkillIcon = function() return 132492 end
GetTradeSkillNumMade = function() return 1, 1 end
GetTradeSkillCooldown = function() return nil end
GetTradeSkillDescription = function() return nil end
GetTradeSkillTools = function() return "Blacksmith Hammer", 1 end
GetTradeSkillNumReagents = function() return 1 end
GetTradeSkillReagentInfo = function() return "Copper Bar", 133217, 6, 0 end
GetTradeSkillReagentItemLink = function() return ITEMS[2840][2] end

local legacy = professions.CollectOpenRecipeBook("tradeskill")
truthy(legacy, "legacy book")
equal(legacy.source, "legacy_tradeskill", "legacy source")
equal(#legacy.recipes, 1, "headers skipped")
local belt = legacy.recipes[1]
equal(belt.recipeId, 2661, "recipe id from enchant link")
equal(belt.difficulty, "optimal", "legacy difficulty")
equal(belt.skillUps, 2, "legacy skill ups")
equal(belt.tools[1].name, "Blacksmith Hammer", "required tools")
equal(belt.reagents[1].quantity, 6, "legacy reagent quantity")
equal(belt.reagents[1].itemId, 2840, "legacy reagent item id")

local override = professions.ToCharacterRecipeOverride(legacy)
equal(override.recipes[1].id, 2661, "character snapshot override keeps recipe id")
equal(override.recipes[1].reagents[1].reagents[1].quantityRequired, 6, "override reagent quantity")

print("profession telemetry spec passed")
