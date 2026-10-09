local function equal(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

-- Forever's Blacksmithing categories: a root for the skill line, then the
-- groups the Professions window shows as accordions.
local CATEGORIES = {
    [2425] = { categoryID = 2425, name = "Blacksmithing", parentCategoryID = 0, uiOrder = 0 },
    [2460] = { categoryID = 2460, name = "Weapon Stones", parentCategoryID = 2425, uiOrder = 20 },
    [2472] = { categoryID = 2472, name = "Plate Bracers", parentCategoryID = 2425, uiOrder = 60 },
}
local categoryLookups = 0
C_TradeSkillUI = {
    GetCategoryInfo = function(categoryId)
        categoryLookups = categoryLookups + 1
        return CATEGORIES[categoryId]
    end,
}

local described = {}
local book = {
    source = "C_TradeSkillUI",
    recipes = {
        { recipeId = 2660, name = "Rough Sharpening Stone", known = true, categoryId = 2460,
            reagents = { { itemId = 2835, quantity = 1 } } },
        { recipeId = 2663, name = "Copper Bracers", known = true, categoryId = 2472,
            reagents = { { itemId = 2840, quantity = 2 }, { itemId = 2835, quantity = 1 } } },
        { recipeId = 3115, name = "Rough Weightstone", known = false, categoryId = 2460,
            reagents = { { itemId = 3576, quantity = 1 } } },
    },
}

local addon = {
    ProfessionTelemetry = {
        CollectOpenRecipeBook = function(kind)
            equal(kind, "tradeskill", "collector kind forwarded")
            return book
        end,
    },
    ItemTelemetry = {
        Describe = function(itemId, options)
            table.insert(described, itemId)
            equal(options.tooltip, true, "reagents are described with tooltips")
            if itemId == 2840 then
                -- Not cached yet: only the instant icon is known.
                return { itemId = itemId, iconFileDataId = 133216 }
            end
            return {
                itemId = itemId,
                name = "Rough Stone",
                iconFileDataId = 135232,
                qualityId = 1,
                itemLevel = 5,
                tooltip = { source = "C_TooltipInfo", lines = { { left = "Rough Stone" }, { left = "Max Stack: 20" } } },
            }
        end,
    },
}

assert(loadfile("Data/RecipeBookDetails.lua"))("Guildweaver", addon)
local enriched = addon.ProfessionTelemetry.CollectOpenRecipeBook("tradeskill")

-- Categories: each used category plus its parent, each looked up once.
equal(#enriched.categories, 3, "used categories and their root")
equal(categoryLookups, 3, "each category read once")
equal(enriched.categories[1].categoryId, 2460, "first used category")
equal(enriched.categories[1].name, "Weapon Stones", "category name")
equal(enriched.categories[1].parentCategoryId, 2425, "category parent")
equal(enriched.categories[1].order, 20, "category order")
equal(enriched.categories[2].categoryId, 2425, "root category follows its first child")
equal(enriched.categories[3].name, "Plate Bracers", "second category")

-- Reagents: described once per book, only for known recipes.
equal(#described, 2, "each reagent of a known recipe described once")
equal(#enriched.items, 2, "both reagents recorded")
equal(enriched.items[1].itemId, 2835, "first reagent")
equal(enriched.items[1].tooltip.lines[2].left, "Max Stack: 20", "reagent tooltip kept")
equal(enriched.items[2].iconFileDataId, 133216, "uncached reagent keeps its instant icon")
for _, item in ipairs(enriched.items) do
    if item.itemId == 3576 then
        error("unknown recipe reagents are not described")
    end
end

-- Without the category API (legacy clients) books are left as they were.
C_TradeSkillUI = nil
book.categories = nil
local legacy = addon.ProfessionTelemetry.CollectOpenRecipeBook("tradeskill")
equal(legacy.categories, nil, "no categories without the API")

print("recipe book details spec passed")
