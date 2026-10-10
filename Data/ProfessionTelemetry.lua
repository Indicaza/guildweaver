local _, GW = ...

-- Profession telemetry: profession identity from the skill APIs and recipe
-- books from whichever crafting window is open. Recipes are only exposed while
-- a profession window is open, so the last captured recipe book per profession
-- is cached per character and merged into every profession_snapshot.

local Globals = _G or {}

GW.ProfessionTelemetry = GW.ProfessionTelemetry or {}

local MAX_RECIPES_PER_BOOK = 600
local MAX_REAGENTS_PER_RECIPE = 16
local COOLDOWN_ROUNDING_SECONDS = 60

local PROFESSION_KIND_BY_SKILL_LINE = {
    [129] = "first_aid",
    [185] = "cooking",
    [356] = "fishing",
    [794] = "archaeology",
}

-- Enum.TradeskillRelativeDifficulty
local MODERN_DIFFICULTY = {
    [0] = "optimal",
    [1] = "medium",
    [2] = "easy",
    [3] = "trivial",
}

local function safe(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local results = { pcall(fn, ...) }
    if not results[1] then
        return nil
    end
    return unpack(results, 2, table.maxn(results))
end

local function cleanText(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    return (value:gsub("Player%-%d+%-%x+", "Player-REDACTED"))
end

local function positiveNumber(value)
    local number = tonumber(value)
    return number and number > 0 and number or nil
end

local function now()
    return safe(Globals.GetServerTime) or 0
end

local function recipeIdFromLink(link)
    if type(link) ~= "string" then
        return nil
    end
    return tonumber(link:match("enchant:(%d+)")) or tonumber(link:match("spell:(%d+)"))
end

local function itemIdFromLink(link)
    if type(link) ~= "string" then
        return nil
    end
    return tonumber(link:match("item:(%d+)"))
end

local function describeItem(itemIdOrLink, includeTooltip)
    if not itemIdOrLink then
        return nil
    end
    local describe = GW.ItemTelemetry and GW.ItemTelemetry.Describe
    if type(describe) == "function" then
        local ok, item = pcall(describe, itemIdOrLink, { tooltip = includeTooltip == true })
        if ok and type(item) == "table" then
            return item
        end
    end
    local itemId = tonumber(itemIdOrLink) or itemIdFromLink(itemIdOrLink)
    return itemId and { itemId = itemId } or nil
end

-- Remaining cooldown seconds change on every capture; a rounded ready-at time
-- stays stable, so cooldowns only change the fingerprint when they really do.
local function cooldownRecord(remaining, isDayCooldown, charges, maxCharges)
    local seconds = tonumber(remaining) or 0
    local maximum = tonumber(maxCharges)
    if seconds <= 0 and not (maximum and maximum > 0) then
        return nil
    end
    local readyAt = nil
    if seconds > 0 then
        readyAt = math.floor((now() + seconds) / COOLDOWN_ROUNDING_SECONDS + 0.5) * COOLDOWN_ROUNDING_SECONDS
    end
    return {
        readyAt = readyAt,
        isDayCooldown = isDayCooldown == true or nil,
        charges = tonumber(charges),
        maxCharges = maximum,
    }
end

local function craftedItem(itemIdOrLink, minQuantity, maxQuantity, includeTooltip)
    local item = describeItem(itemIdOrLink, includeTooltip)
    if not item then
        return nil
    end
    item.minQuantity = positiveNumber(minQuantity)
    item.maxQuantity = positiveNumber(maxQuantity)
    return item
end

local function reagentRecord(itemIdOrLink, fields)
    local reagent = describeItem(itemIdOrLink, false) or {}
    for key, value in pairs(fields) do
        if reagent[key] == nil then
            reagent[key] = value
        end
    end
    return next(reagent) and reagent or nil
end

-- Profession identity ------------------------------------------------------

local function professionSpecialization(skillLineId)
    local profSpecs = Globals.C_ProfSpecs
    if not skillLineId or type(profSpecs) ~= "table" then
        return nil
    end

    local configId = safe(profSpecs.GetConfigIDForSkillLine, skillLineId)
    if not configId then
        return nil
    end

    local traits = Globals.C_Traits
    local configInfo = type(traits) == "table" and safe(traits.GetConfigInfo, configId) or nil
    return {
        configId = configId,
        name = type(configInfo) == "table" and cleanText(configInfo.name) or nil,
        treeIds = type(configInfo) == "table" and configInfo.treeIDs or nil,
    }
end

local function professionKey(skillLineId, name)
    if tonumber(skillLineId) then
        return "skill:" .. tostring(tonumber(skillLineId))
    end
    if type(name) == "string" and name ~= "" then
        return "name:" .. string.lower(name)
    end
    return nil
end

-- Returns the character's professions, or nil when the profession API is not
-- available (so callers keep the last known state instead of clearing it).
function GW.ProfessionTelemetry.CollectProfessions()
    local getProfessions = Globals.GetProfessions
    local getProfessionInfo = Globals.GetProfessionInfo
    if type(getProfessions) ~= "function" or type(getProfessionInfo) ~= "function" then
        return nil
    end

    local results = { pcall(getProfessions) }
    if not results[1] then
        return nil
    end

    local professions = {}
    -- GetProfessions returns prof1, prof2, archaeology, fishing, cooking (and
    -- first aid on some clients); unlearned slots are nil, so walk positions.
    for position = 2, 7 do
        local index = results[position]
        if index then
            local name, icon, skillLevel, maxSkillLevel, _, _, skillLineId, skillModifier, specializationIndex, _, skillLineName =
                safe(getProfessionInfo, index)
            if name then
                local id = tonumber(skillLineId)
                table.insert(professions, {
                    skillLineId = id,
                    name = cleanText(name),
                    skillLineName = cleanText(skillLineName),
                    kind = PROFESSION_KIND_BY_SKILL_LINE[id] or (position <= 3 and "primary" or "secondary"),
                    iconFileDataId = icon,
                    skillLevel = tonumber(skillLevel) or 0,
                    maxSkillLevel = tonumber(maxSkillLevel) or 0,
                    skillModifier = tonumber(skillModifier) or 0,
                    specializationIndex = tonumber(specializationIndex),
                    specialization = professionSpecialization(id),
                })
            end
        end
    end

    return professions
end

-- Recipe books -------------------------------------------------------------

-- Required tools and crafting stations (an Anvil, a Blacksmith Hammer), as the
-- schematic form's "Requires:" line lists them; met is whether the character
-- currently has or stands at each one.
local function modernTools(api, recipeId)
    local requirements = safe(api.GetRecipeRequirements, recipeId)
    if type(requirements) ~= "table" then
        return nil
    end

    local tools = {}
    for _, requirement in ipairs(requirements) do
        local name = type(requirement) == "table" and cleanText(requirement.name) or nil
        if name then
            table.insert(tools, { name = name, available = requirement.met == true })
        end
    end
    return #tools > 0 and tools or nil
end

local function modernReagents(schematic)
    if type(schematic) ~= "table" or type(schematic.reagentSlotSchematics) ~= "table" then
        return nil
    end

    local reagents = {}
    for slotIndex, slot in ipairs(schematic.reagentSlotSchematics) do
        if type(slot) == "table" then
            for _, entry in ipairs(type(slot.reagents) == "table" and slot.reagents or {}) do
                if type(entry) == "table" and #reagents < MAX_REAGENTS_PER_RECIPE then
                    local nested = type(entry.reagent) == "table" and entry.reagent or {}
                    local itemId = entry.itemID or nested.itemID
                    local reagent = reagentRecord(itemId, {
                        currencyId = entry.currencyID or nested.currencyID,
                        quantity = tonumber(entry.quantityRequired or slot.quantityRequired),
                        required = slot.required,
                        slotIndex = slotIndex,
                    })
                    if reagent then
                        table.insert(reagents, reagent)
                    end
                end
            end
        end
    end
    return #reagents > 0 and reagents or nil
end

-- Some clients (Forever) lack GetAllRecipeIDs. Their GetFilteredRecipeIDs
-- spans every known profession, so it is narrowed to the open one here.
-- Never written onto C_TradeSkillUI: other addons and Blizzard's UI share it.
local function allRecipeIds(api)
    if type(api.GetAllRecipeIDs) == "function" then
        return safe(api.GetAllRecipeIDs)
    end

    local ids = safe(api.GetFilteredRecipeIDs)
    if type(ids) ~= "table" or type(api.IsRecipeInSkillLine) ~= "function" then
        return ids
    end

    local skillLines, seen = {}, {}
    for _, infoFunction in ipairs({ api.GetChildProfessionInfo, api.GetBaseProfessionInfo }) do
        local info = safe(infoFunction)
        local skillLineId = type(info) == "table" and tonumber(info.professionID) or nil
        if skillLineId and not seen[skillLineId] then
            seen[skillLineId] = true
            table.insert(skillLines, skillLineId)
        end
    end

    local filtered = {}
    for _, recipeId in ipairs(ids) do
        for _, skillLineId in ipairs(skillLines) do
            if safe(api.IsRecipeInSkillLine, recipeId, skillLineId) == true then
                table.insert(filtered, recipeId)
                break
            end
        end
    end
    return filtered
end

local function collectModernBook()
    local api = Globals.C_TradeSkillUI
    if type(api) ~= "table" or type(api.GetRecipeInfo) ~= "function" then
        return nil
    end

    local ids = allRecipeIds(api)
    if type(ids) ~= "table" or #ids == 0 then
        return nil
    end

    local recipeIds = {}
    for _, recipeId in ipairs(ids) do
        table.insert(recipeIds, recipeId)
    end
    table.sort(recipeIds)

    local base = safe(api.GetBaseProfessionInfo)
    local child = safe(api.GetChildProfessionInfo)
    local info = type(child) == "table" and child.professionID and child or (type(base) == "table" and base or {})
    local profession = {
        skillLineId = tonumber(info.professionID),
        parentSkillLineId = type(base) == "table" and tonumber(base.professionID) or nil,
        name = cleanText(info.professionName),
        skillLevel = tonumber(info.skillLevel),
        maxSkillLevel = tonumber(info.maxSkillLevel),
        skillModifier = tonumber(info.skillModifier),
    }

    local recipes = {}
    for _, recipeId in ipairs(recipeIds) do
        if #recipes >= MAX_RECIPES_PER_BOOK then
            break
        end

        local recipe = safe(api.GetRecipeInfo, recipeId)
        if type(recipe) == "table" then
            local known = recipe.learned == true
            local skillLineId = safe(api.GetTradeSkillLineForRecipe, recipeId)
            local output = safe(api.GetRecipeOutputItemData, recipeId)
            local schematic = safe(api.GetRecipeSchematic, recipeId, false)
            local cooldown, isDayCooldown, charges, maxCharges = safe(api.GetRecipeCooldown, recipeId)
            local outputItemId = type(output) == "table" and output.itemID
                or type(schematic) == "table" and schematic.outputItemID
                or nil
            local outputLink = type(output) == "table" and output.hyperlink or nil

            table.insert(recipes, {
                recipeId = recipeId,
                spellId = recipeId,
                name = cleanText(recipe.name),
                iconFileDataId = recipe.icon,
                recipeLink = cleanText(recipe.hyperlink),
                known = known,
                craftable = recipe.craftable,
                disabled = recipe.disabled or nil,
                categoryId = recipe.categoryID,
                skillLineAbilityId = recipe.skillLineAbilityID,
                professionSkillLineId = tonumber(skillLineId) or profession.skillLineId,
                difficulty = MODERN_DIFFICULTY[recipe.relativeDifficulty],
                relativeDifficulty = recipe.relativeDifficulty,
                skillUps = tonumber(recipe.numSkillUps),
                maxTrivialLevel = tonumber(recipe.maxTrivialLevel),
                unlockedRecipeLevel = tonumber(recipe.unlockedRecipeLevel),
                description = cleanText(safe(api.GetRecipeDescription, recipeId)),
                cooldown = cooldownRecord(cooldown, isDayCooldown, charges, maxCharges),
                crafted = craftedItem(
                    outputLink or outputItemId,
                    type(schematic) == "table" and schematic.quantityMin or nil,
                    type(schematic) == "table" and schematic.quantityMax or nil,
                    known
                ),
                tools = modernTools(api, recipeId),
                reagents = modernReagents(schematic),
            })
        end
    end

    if #recipes == 0 then
        return nil
    end
    return { source = "C_TradeSkillUI", profession = profession, recipes = recipes }
end

-- The legacy trade-skill and craft (Classic Enchanting) frames expose the
-- same shape through different global functions.
local LEGACY_APIS = {
    tradeskill = {
        source = "legacy_tradeskill",
        count = "GetNumTradeSkills",
        info = "GetTradeSkillInfo",
        line = "GetTradeSkillLine",
        recipeLink = "GetTradeSkillRecipeLink",
        itemLink = "GetTradeSkillItemLink",
        icon = "GetTradeSkillIcon",
        numMade = "GetTradeSkillNumMade",
        cooldown = "GetTradeSkillCooldown",
        description = "GetTradeSkillDescription",
        tools = "GetTradeSkillTools",
        numReagents = "GetTradeSkillNumReagents",
        reagentInfo = "GetTradeSkillReagentInfo",
        reagentLink = "GetTradeSkillReagentItemLink",
    },
    craft = {
        source = "legacy_craft",
        count = "GetNumCrafts",
        info = "GetCraftInfo",
        line = "GetCraftDisplaySkillLine",
        recipeLink = "GetCraftRecipeLink",
        itemLink = "GetCraftItemLink",
        icon = "GetCraftIcon",
        description = "GetCraftDescription",
        tools = "GetCraftSpellFocus",
        numReagents = "GetCraftNumReagents",
        reagentInfo = "GetCraftReagentInfo",
        reagentLink = "GetCraftReagentItemLink",
    },
}

local function legacyCall(apis, name, ...)
    return safe(Globals[apis[name] or ""], ...)
end

local function legacyTools(apis, index)
    local tools = {}
    local values = { safe(Globals[apis.tools or ""], index) }
    for position = 1, #values, 2 do
        local name = cleanText(values[position])
        if name then
            table.insert(tools, { name = name, available = values[position + 1] and true or false })
        end
    end
    return #tools > 0 and tools or nil
end

local function collectLegacyBook(kind)
    local apis = LEGACY_APIS[kind]
    local count = tonumber(legacyCall(apis, "count")) or 0
    if count < 1 then
        return nil
    end

    local lineName, skillLevel, maxSkillLevel = legacyCall(apis, "line")
    local profession = {
        name = cleanText(lineName),
        skillLevel = tonumber(skillLevel),
        maxSkillLevel = tonumber(maxSkillLevel),
    }

    local recipes = {}
    for index = 1, count do
        if #recipes >= MAX_RECIPES_PER_BOOK then
            break
        end

        local name, secondary, recipeType, _, _, extra1, extra2 = legacyCall(apis, "info", index)
        -- Trade skills: name, skillType, numAvailable, isExpanded, altVerb, numSkillUps.
        -- Crafts: name, subSpellName, craftType, numAvailable, isExpanded, trainingPointCost, requiredLevel.
        local skillType = kind == "craft" and recipeType or secondary
        if name and skillType ~= "header" and skillType ~= "subheader" then
            local recipeLink = legacyCall(apis, "recipeLink", index)
            local itemLink = legacyCall(apis, "itemLink", index)
            local minMade, maxMade = legacyCall(apis, "numMade", index)
            local reagents = {}
            local reagentCount = tonumber(legacyCall(apis, "numReagents", index)) or 0
            for reagentIndex = 1, math.min(reagentCount, MAX_REAGENTS_PER_RECIPE) do
                local reagentName, reagentIcon, quantity = legacyCall(apis, "reagentInfo", index, reagentIndex)
                local reagentLink = legacyCall(apis, "reagentLink", index, reagentIndex)
                local reagent = reagentRecord(reagentLink, {
                    name = cleanText(reagentName),
                    iconFileDataId = reagentIcon,
                    quantity = tonumber(quantity),
                    required = true,
                    slotIndex = reagentIndex,
                })
                if reagent then
                    table.insert(reagents, reagent)
                end
            end

            local recipeId = recipeIdFromLink(recipeLink) or recipeIdFromLink(itemLink)
            table.insert(recipes, {
                recipeId = recipeId,
                spellId = recipeId,
                name = cleanText(name),
                subName = kind == "craft" and cleanText(secondary) or nil,
                iconFileDataId = legacyCall(apis, "icon", index),
                recipeLink = cleanText(recipeLink),
                known = true,
                difficulty = skillType,
                skillUps = kind == "tradeskill" and tonumber(extra1) or nil,
                trainingPointCost = kind == "craft" and tonumber(extra1) or nil,
                requiredLevel = kind == "craft" and tonumber(extra2) or nil,
                description = cleanText(legacyCall(apis, "description", index)),
                cooldown = cooldownRecord(legacyCall(apis, "cooldown", index)),
                tools = legacyTools(apis, index),
                crafted = itemIdFromLink(itemLink) and craftedItem(itemLink, minMade, maxMade, true) or nil,
                reagents = #reagents > 0 and reagents or nil,
            })
        end
    end

    if #recipes == 0 then
        return nil
    end
    return { source = apis.source, profession = profession, recipes = recipes }
end

-- Reads the recipe book from the open profession window. Pass "craft" for the
-- Classic craft frame (CRAFT_* events); anything else reads the trade skill UI.
function GW.ProfessionTelemetry.CollectOpenRecipeBook(kind)
    if kind == "craft" then
        return collectLegacyBook("craft")
    end
    return collectModernBook() or collectLegacyBook("tradeskill")
end

-- Per-character cache -------------------------------------------------------

local function cacheFor(characterKey)
    if type(GuildweaverDB) ~= "table" or not characterKey then
        return nil
    end
    GuildweaverDB.professionTelemetry = GuildweaverDB.professionTelemetry or {}
    local root = GuildweaverDB.professionTelemetry
    root[characterKey] = root[characterKey] or { professions = {}, order = {}, recipeBooks = {} }
    return root[characterKey]
end

local function copyTable(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, entry in pairs(value) do
        result[key] = copyTable(entry)
    end
    return result
end

-- Replaces the known profession list. nil means "unknown right now" and keeps
-- the cached list; an empty table means the character has no professions.
function GW.ProfessionTelemetry.RememberProfessions(characterKey, professions)
    local cache = cacheFor(characterKey)
    if not cache or type(professions) ~= "table" then
        return false
    end

    cache.professions = {}
    cache.order = {}
    for _, profession in ipairs(professions) do
        local key = professionKey(profession.skillLineId, profession.name)
        if key and not cache.professions[key] then
            cache.professions[key] = copyTable(profession)
            table.insert(cache.order, key)
        end
    end
    return true
end

local function bookProfessionKey(cache, profession)
    local candidates = {
        professionKey(profession.skillLineId),
        professionKey(profession.parentSkillLineId),
        professionKey(nil, profession.name),
    }
    for position = 1, 3 do
        local key = candidates[position]
        if key and cache.professions[key] then
            return key
        end
    end
    -- Match by name against known professions whose key is a skill line.
    for key, known in pairs(cache.professions) do
        if profession.name and known.name and string.lower(known.name) == string.lower(profession.name) then
            return key
        end
    end
    return candidates[1] or candidates[3]
end

-- Stores a recipe book. The capture time only moves when the recipes change,
-- so reopening an unchanged profession window does not emit a new revision.
function GW.ProfessionTelemetry.RememberRecipeBook(characterKey, book)
    local cache = cacheFor(characterKey)
    if not cache or type(book) ~= "table" or type(book.recipes) ~= "table" then
        return false
    end

    local profession = book.profession or {}
    local key = bookProfessionKey(cache, profession)
    if not key then
        return false
    end

    if not cache.professions[key] then
        cache.professions[key] = {
            skillLineId = profession.skillLineId,
            name = profession.name,
            kind = PROFESSION_KIND_BY_SKILL_LINE[tonumber(profession.skillLineId)] or "primary",
            skillLevel = profession.skillLevel,
            maxSkillLevel = profession.maxSkillLevel,
            skillModifier = profession.skillModifier,
        }
        table.insert(cache.order, key)
    end

    local fingerprint = GW.Store.Fingerprint({ recipes = book.recipes, categories = book.categories, items = book.items })
    local existing = cache.recipeBooks[key]
    if existing and existing.fingerprint == fingerprint then
        return false
    end

    cache.recipeBooks[key] = {
        source = book.source,
        capturedAt = now(),
        fingerprint = fingerprint,
        recipes = book.recipes,
        categories = book.categories,
        items = book.items,
    }
    return true
end

-- Builds the profession_snapshot payload from the cache.
function GW.ProfessionTelemetry.BuildPayload(characterKey)
    local cache = cacheFor(characterKey)
    local professions = {}
    for _, key in ipairs(cache and cache.order or {}) do
        local profession = copyTable(cache.professions[key])
        if profession then
            local book = cache.recipeBooks[key]
            if book then
                local known = 0
                for _, recipe in ipairs(book.recipes) do
                    if recipe.known then
                        known = known + 1
                    end
                end
                profession.recipeBook = {
                    source = book.source,
                    capturedAt = book.capturedAt,
                    recipeCount = #book.recipes,
                    knownCount = known,
                }
                profession.recipes = book.recipes
                profession.categories = book.categories
                profession.items = book.items
            end
            table.insert(professions, profession)
        end
    end
    return { professions = professions }
end

-- Shape accepted by the local character snapshot's profession recipes, so a
-- capture without the profession window open keeps the last known recipes.
function GW.ProfessionTelemetry.ToCharacterRecipeOverride(book)
    if type(book) ~= "table" then
        return nil
    end
    local recipes = {}
    for _, recipe in ipairs(book.recipes or {}) do
        local reagents = {}
        for _, reagent in ipairs(recipe.reagents or {}) do
            table.insert(reagents, {
                itemId = reagent.itemId,
                currencyId = reagent.currencyId,
                quantityRequired = reagent.quantity,
            })
        end
        table.insert(recipes, {
            id = recipe.recipeId,
            name = recipe.name,
            known = recipe.known,
            icon = recipe.iconFileDataId,
            professionId = recipe.professionSkillLineId,
            skillLineAbilityId = recipe.skillLineAbilityId,
            relativeDifficulty = recipe.relativeDifficulty,
            maxTrivialLevel = recipe.maxTrivialLevel,
            unlockedRecipeLevel = recipe.unlockedRecipeLevel,
            craftedItemId = recipe.crafted and recipe.crafted.itemId or nil,
            craftedItemLink = recipe.crafted and recipe.crafted.itemLink or nil,
            reagents = #reagents > 0 and { { slotIndex = 1, reagents = reagents } } or nil,
        })
    end
    local profession = book.profession or {}
    return {
        source = book.source,
        capturedAt = now(),
        professionId = profession.skillLineId,
        professionName = profession.name,
        recipes = recipes,
    }
end
