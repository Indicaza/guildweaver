local function equal(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local resolved = {}
local book = {
    source = "C_TradeSkillUI",
    recipes = {
        { recipeId = 12045, spellId = 12045, name = "Simple Linen Boots", known = true },
        { recipeId = 12046, spellId = 12046, name = "Unknown Pattern", known = false },
    },
}

local addon = {
    ProfessionTelemetry = {
        CollectOpenRecipeBook = function(kind)
            equal(kind, "tradeskill", "collector kind forwarded")
            return book
        end,
    },
    SpellTelemetry = {
        Resolve = function(spellId)
            table.insert(resolved, spellId)
            return {
                spellId = spellId,
                name = "Resolved Recipe",
                iconFileDataId = 136249,
                description = "Creates a useful item.",
                spellLink = "|Hspell:" .. tostring(spellId) .. "|h[Resolved Recipe]|h",
                tooltip = {
                    source = "C_TooltipInfo.GetSpellByID",
                    lines = {
                        { left = "Resolved Recipe", leftColor = { r = 1, g = 1, b = 1 } },
                        { left = "Creates a useful item.", leftColor = { r = 1, g = 0.82, b = 0 } },
                    },
                },
            }
        end,
    },
}

assert(loadfile("Data/RecipeTooltipTelemetry.lua"))("Guildweaver", addon)
local enriched = addon.ProfessionTelemetry.CollectOpenRecipeBook("tradeskill")

equal(#resolved, 1, "only learned recipes resolve rich tooltip data")
equal(resolved[1], 12045, "learned recipe resolved by spell id")
equal(enriched.recipes[1].tooltip.source, "C_TooltipInfo.GetSpellByID", "client tooltip attached")
equal(enriched.recipes[1].description, "Creates a useful item.", "missing description enriched")
equal(enriched.recipes[1].spellLink, "|Hspell:12045|h[Resolved Recipe]|h", "spell link enriched")
equal(enriched.recipes[2].tooltip, nil, "unknown recipe remains lightweight")

print("recipe tooltip telemetry spec passed")
