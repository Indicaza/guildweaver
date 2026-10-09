local _, GW = ...

-- Enrich recipe books with client-authored spell tooltip telemetry. Unknown
-- recipes stay lightweight: the telemetry layer may retain them for future
-- intelligence features, while the armory only needs rich data for learned
-- recipes that it can actually display.

local professions = GW.ProfessionTelemetry
local spells = GW.SpellTelemetry

if type(professions) == "table"
    and type(professions.CollectOpenRecipeBook) == "function"
    and type(spells) == "table"
    and type(spells.Resolve) == "function" then
    local originalCollectOpenRecipeBook = professions.CollectOpenRecipeBook

    professions.CollectOpenRecipeBook = function(kind)
        local book = originalCollectOpenRecipeBook(kind)
        if type(book) ~= "table" or type(book.recipes) ~= "table" then
            return book
        end

        for _, recipe in ipairs(book.recipes) do
            if type(recipe) == "table" and recipe.known ~= false then
                local spellId = tonumber(recipe.spellId or recipe.recipeId)
                if spellId then
                    local ok, spell = pcall(spells.Resolve, spellId)
                    if ok and type(spell) == "table" then
                        recipe.tooltip = spell.tooltip
                        recipe.spellLink = recipe.spellLink or spell.spellLink
                        recipe.description = recipe.description or spell.description
                        recipe.name = recipe.name or spell.name
                        recipe.iconFileDataId = recipe.iconFileDataId or spell.iconFileDataId
                    end
                end
            end
        end

        return book
    end
end
