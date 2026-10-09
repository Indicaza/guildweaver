local _, GW = ...

-- Recipe categories and reagent details for captured recipe books.
--
-- The Professions window groups recipes into categories (for example
-- "Plate Helmets" under Blacksmithing); each recipe only carries a category
-- ID, so the category names, parents and order are read once per book.
--
-- Reagents are described once per book, with their tooltips, instead of on
-- every recipe that uses them, which keeps the snapshot small while still
-- giving the website a tooltip for each reagent of a known recipe.

local Globals = _G or {}
local MAX_CATEGORIES = 200
local MAX_ITEMS = 400

local professions = GW.ProfessionTelemetry
if type(professions) ~= "table" or type(professions.CollectOpenRecipeBook) ~= "function" then
    return
end

local function cleanText(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    return value
end

local function categoryRecord(api, categoryId)
    local ok, info = pcall(api.GetCategoryInfo, categoryId)
    if not ok or type(info) ~= "table" then
        return nil
    end
    return {
        categoryId = tonumber(info.categoryID) or categoryId,
        name = cleanText(info.name),
        parentCategoryId = tonumber(info.parentCategoryID),
        order = tonumber(info.uiOrder),
    }
end

local function collectCategories(recipes)
    local api = Globals.C_TradeSkillUI
    if type(api) ~= "table" or type(api.GetCategoryInfo) ~= "function" then
        return nil
    end

    local seen = {}
    local categories = {}
    for _, recipe in ipairs(recipes) do
        -- Walk up to the profession's root so nested categories keep their parents.
        local categoryId = tonumber(recipe.categoryId)
        while categoryId and categoryId > 0 and not seen[categoryId] and #categories < MAX_CATEGORIES do
            seen[categoryId] = true
            local record = categoryRecord(api, categoryId)
            if not record then
                break
            end
            table.insert(categories, record)
            categoryId = record.parentCategoryId
        end
    end
    return #categories > 0 and categories or nil
end

local function collectItems(recipes)
    local describe = GW.ItemTelemetry and GW.ItemTelemetry.Describe
    if type(describe) ~= "function" then
        return nil
    end

    local seen = {}
    local items = {}
    for _, recipe in ipairs(recipes) do
        if recipe.known ~= false then
            for _, reagent in ipairs(type(recipe.reagents) == "table" and recipe.reagents or {}) do
                local itemId = tonumber(reagent.itemId)
                if itemId and not seen[itemId] and #items < MAX_ITEMS then
                    seen[itemId] = true
                    local ok, item = pcall(describe, itemId, { tooltip = true })
                    if ok and type(item) == "table" and (item.name or item.tooltip or item.iconFileDataId) then
                        table.insert(items, {
                            itemId = itemId,
                            itemLink = item.itemLink,
                            name = item.name,
                            iconFileDataId = item.iconFileDataId,
                            qualityId = item.qualityId,
                            itemLevel = item.itemLevel,
                            requiredLevel = item.requiredLevel,
                            tooltip = item.tooltip,
                        })
                    end
                end
            end
        end
    end
    return #items > 0 and items or nil
end

local originalCollectOpenRecipeBook = professions.CollectOpenRecipeBook

professions.CollectOpenRecipeBook = function(kind)
    local book = originalCollectOpenRecipeBook(kind)
    if type(book) ~= "table" or type(book.recipes) ~= "table" then
        return book
    end

    book.categories = collectCategories(book.recipes)
    book.items = collectItems(book.recipes)
    return book
end
