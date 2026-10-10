local _, GW = ...

local professions = GW.ProfessionTelemetry
if type(professions) ~= "table" then
    return
end

-- Forever's modern profession UI can expose a child skill line (for example,
-- Classic Tailoring) while GetProfessions() reports the base profession
-- (Tailoring). Prime the profession cache before storing a recipe book so the
-- existing parent-skill-line fallback can attach the book to the canonical
-- base profession instead of creating an orphaned child entry.
local originalRememberRecipeBook = professions.RememberRecipeBook
if type(originalRememberRecipeBook) == "function" then
    function professions.RememberRecipeBook(characterKey, book)
        if characterKey
            and type(professions.CollectProfessions) == "function"
            and type(professions.RememberProfessions) == "function" then
            local ok, live = pcall(professions.CollectProfessions)
            if ok and type(live) == "table" then
                professions.RememberProfessions(characterKey, live)
            end
        end

        return originalRememberRecipeBook(characterKey, book)
    end
end

-- The local character snapshot keeps each profession's recipes. Use the base profession ID for that merge while retaining
-- the child ID for diagnostics. Without this, a child skill line such as 2823
-- cannot match GetProfessions()' base skill line such as 197.
local originalToCharacterRecipeOverride = professions.ToCharacterRecipeOverride
if type(originalToCharacterRecipeOverride) == "function" then
    function professions.ToCharacterRecipeOverride(book)
        local override = originalToCharacterRecipeOverride(book)
        if type(override) ~= "table" then
            return override
        end

        local profession = type(book) == "table" and book.profession or nil
        if type(profession) == "table" then
            local childProfessionId = tonumber(profession.skillLineId)
            local parentProfessionId = tonumber(profession.parentSkillLineId)
            override.childProfessionId = childProfessionId
            override.professionId = parentProfessionId or childProfessionId
        end

        return override
    end
end
