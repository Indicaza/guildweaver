local _, GW = ...

GW.TelemetrySchema = GW.TelemetrySchema or {}

local PROFESSION_KIND_BY_SKILL_LINE = {
    [129] = "first_aid",
    [185] = "cooking",
    [356] = "fishing",
    [794] = "archaeology",
}

local EQUIPMENT_SLOT_KEYS = {
    HeadSlot = "head",
    NeckSlot = "neck",
    ShoulderSlot = "shoulder",
    BackSlot = "back",
    ChestSlot = "chest",
    ShirtSlot = "shirt",
    TabardSlot = "tabard",
    WristSlot = "wrist",
    HandsSlot = "hands",
    WaistSlot = "waist",
    LegsSlot = "legs",
    FeetSlot = "feet",
    Finger0Slot = "finger_1",
    Finger1Slot = "finger_2",
    Trinket0Slot = "trinket_1",
    Trinket1Slot = "trinket_2",
    MainHandSlot = "main_hand",
    SecondaryHandSlot = "off_hand",
}

local function nonEmpty(value)
    return type(value) == "string" and value ~= ""
end

local function copyArray(values)
    local result = {}
    for _, value in ipairs(type(values) == "table" and values or {}) do
        table.insert(result, value)
    end
    return result
end

local function replaceTable(target, source)
    for key in pairs(target) do
        target[key] = nil
    end
    for key, value in pairs(source) do
        target[key] = value
    end
end

local function sanitizePlayerGuid(value)
    if type(value) ~= "string" then
        return value
    end

    return (value:gsub("Player%-%d+%-%x+", "Player-REDACTED"))
end

local function itemNameFromLink(itemLink)
    if type(itemLink) ~= "string" then
        return nil
    end

    return itemLink:match("%[(.-)%]")
end

local function normalizeIdentity(value)
    if type(value) ~= "table" then
        return nil
    end

    return {
        id = value.id,
        name = value.name,
        token = value.token or value.file,
    }
end

local function normalizeSpecialization(value)
    if type(value) ~= "table" then
        return nil
    end

    local id = tonumber(value.id)
    local hasIdentity = (id and id > 0) or nonEmpty(value.name) or nonEmpty(value.role)
    if not hasIdentity then
        return nil
    end

    return {
        index = value.index,
        id = id,
        name = value.name,
        description = nonEmpty(value.description) and value.description or nil,
        iconFileDataId = value.iconFileDataId or value.icon,
        role = nonEmpty(value.role) and value.role or nil,
    }
end

local function normalizeProfessionSpecialization(value)
    if type(value) ~= "table" then
        return nil
    end

    local configId = tonumber(value.configId)
    local treeIds = copyArray(value.treeIds)
    if (not configId or configId <= 0) and not nonEmpty(value.name) and #treeIds == 0 then
        return nil
    end

    return {
        configId = configId,
        name = value.name,
        treeIds = treeIds,
    }
end

local function normalizeRecipeReagents(slots)
    local result = {}

    for _, slot in ipairs(type(slots) == "table" and slots or {}) do
        local normalizedSlot = {
            slotIndex = slot.slotIndex,
            dataSlotIndex = slot.dataSlotIndex,
            quantityRequired = slot.quantityRequired,
            required = slot.required,
            reagents = {},
        }

        for _, reagent in ipairs(type(slot.reagents) == "table" and slot.reagents or {}) do
            table.insert(normalizedSlot.reagents, {
                itemId = reagent.itemId,
                currencyId = reagent.currencyId,
                name = reagent.name,
                iconFileDataId = reagent.iconFileDataId or reagent.icon,
                quantityRequired = reagent.quantityRequired,
            })
        end

        table.insert(result, normalizedSlot)
    end

    return #result > 0 and result or nil
end

local function normalizeRecipe(recipe)
    if type(recipe) ~= "table" then
        return nil
    end

    return {
        recipeId = recipe.recipeId or recipe.id,
        name = recipe.name,
        known = recipe.known,
        iconFileDataId = recipe.iconFileDataId or recipe.icon,
        professionSkillLineId = recipe.professionSkillLineId or recipe.professionId,
        professionName = recipe.professionName,
        skillLineAbilityId = recipe.skillLineAbilityId,
        relativeDifficulty = recipe.relativeDifficulty,
        maxTrivialLevel = recipe.maxTrivialLevel,
        unlockedRecipeLevel = recipe.unlockedRecipeLevel,
        craftedItemId = recipe.craftedItemId,
        craftedItemLink = sanitizePlayerGuid(recipe.craftedItemLink),
        reagents = normalizeRecipeReagents(recipe.reagents),
    }
end

local function normalizeProfession(profession)
    if type(profession) ~= "table" then
        return nil
    end

    local skillLineId = tonumber(profession.skillLineId or profession.id)
    local recipes = nil
    if type(profession.recipes) == "table" then
        recipes = {}
        for _, recipe in ipairs(profession.recipes) do
            local normalized = normalizeRecipe(recipe)
            if normalized then
                table.insert(recipes, normalized)
            end
        end
        if #recipes == 0 then
            recipes = nil
        end
    end

    return {
        skillLineId = skillLineId,
        name = profession.name or profession.skillLineName,
        kind = PROFESSION_KIND_BY_SKILL_LINE[skillLineId] or profession.kind or "secondary",
        iconFileDataId = profession.iconFileDataId or profession.icon,
        skillLevel = profession.skillLevel,
        maxSkillLevel = profession.maxSkillLevel,
        skillModifier = profession.skillModifier,
        specialization = normalizeProfessionSpecialization(profession.specialization),
        recipeSnapshotAt = profession.recipeSnapshotAt,
        recipeSource = profession.recipeSource,
        recipes = recipes,
    }
end

local function positiveNumber(value)
    local number = tonumber(value)
    if number and number > 0 then
        return number
    end
    return nil
end

local function normalizeEquipmentItem(item)
    if type(item) ~= "table" then
        return nil
    end

    local modifiers = type(item.modifierData) == "table" and item.modifierData or {}
    local itemLink = sanitizePlayerGuid(item.itemLink)
    local rawItemString = sanitizePlayerGuid(item.rawItemString or item.itemString)
    local itemClass = nil
    if item.classId or nonEmpty(item.class) then
        itemClass = { id = item.classId, name = item.class }
    end
    local itemSubclass = nil
    if item.subclassId or nonEmpty(item.subclass) then
        itemSubclass = { id = item.subclassId, name = item.subclass }
    end

    return {
        slot = EQUIPMENT_SLOT_KEYS[item.slot] or item.slot,
        slotId = item.slotId,
        itemId = item.itemId,
        name = item.name or itemNameFromLink(item.itemLink),
        qualityId = item.qualityId or item.quality,
        itemLevel = item.itemLevel,
        requiredLevel = item.requiredLevel,
        iconFileDataId = item.iconFileDataId or item.icon,
        enchantId = positiveNumber(item.enchantId),
        gemItemIds = copyArray(item.gemItemIds or item.gemIds),
        bonusIds = copyArray(item.bonusIds),
        suffixId = positiveNumber(item.suffixId or modifiers[7]),
        linkLevel = positiveNumber(item.linkLevel or modifiers[9]),
        specializationId = positiveNumber(item.specializationId or modifiers[10]),
        upgradeTypeId = positiveNumber(item.upgradeTypeId or modifiers[11]),
        instanceDifficultyId = positiveNumber(item.instanceDifficultyId or modifiers[12]),
        itemClass = itemClass,
        itemSubclass = itemSubclass,
        equipLocation = item.equipLocation,
        bindType = item.bindType,
        expansionId = item.expansionId,
        setId = item.setId,
        itemLink = itemLink,
        rawItemString = rawItemString,
    }
end

local function copyCurrencies(currencies)
    local result = {}
    for _, currency in ipairs(type(currencies) == "table" and currencies or {}) do
        table.insert(result, {
            treeId = currency.treeId,
            traitCurrencyId = currency.traitCurrencyId,
            quantity = currency.quantity,
            maxQuantity = currency.maxQuantity,
            spent = currency.spent,
            spentInTree = currency.spentInTree,
        })
    end
    return result
end

local function normalizeTalentDefinitionEntry(entry)
    return {
        entryId = entry.id,
        definitionId = entry.definitionId,
        spellId = entry.spellId,
        iconFileDataId = entry.iconFileDataId or entry.icon,
        name = entry.name,
        maxRanks = entry.maxRanks,
    }
end

local function normalizeTalentTreeDefinition(tree, snapshot, talents)
    local definition = {
        schemaVersion = 1,
        sourceApi = talents.api,
        kind = talents.kind,
        treeId = tree.id,
        rootNodeId = tree.rootNodeId,
        class = normalizeIdentity(snapshot.class),
        gameBuild = snapshot.gameBuild,
        nodes = {},
        edges = {},
    }

    for _, node in ipairs(type(tree.nodes) == "table" and tree.nodes or {}) do
        local normalizedNode = {
            nodeId = node.id,
            type = node.type,
            position = node.position,
            maxRanks = node.maxRanks,
            conditionIds = copyArray(node.conditionIds),
            entries = {},
        }

        for _, entry in ipairs(type(node.entries) == "table" and node.entries or {}) do
            table.insert(normalizedNode.entries, normalizeTalentDefinitionEntry(entry))
        end
        table.insert(definition.nodes, normalizedNode)
    end

    for _, edge in ipairs(type(tree.edges) == "table" and tree.edges or {}) do
        table.insert(definition.edges, {
            sourceNodeId = edge.sourceNodeId,
            targetNodeId = edge.targetNodeId,
            type = edge.type,
            visualStyle = edge.visualStyle,
        })
    end

    return definition
end

local function talentAllocation(node)
    local rank = tonumber(node.currentRank) or tonumber(node.activeRank) or tonumber(node.ranksPurchased) or 0
    local purchased = tonumber(node.ranksPurchased) or rank
    if rank <= 0 and purchased <= 0 then
        return nil
    end

    local activeEntryId = nil
    local activeEntryRank = nil
    for _, entry in ipairs(type(node.entries) == "table" and node.entries or {}) do
        local entryRank = tonumber(entry.rank) or 0
        if entry.selected and (entryRank > 0 or rank > 0) then
            activeEntryId = entry.id
            activeEntryRank = entryRank > 0 and entryRank or rank
            break
        end
    end

    return {
        nodeId = node.id,
        rank = rank,
        ranksPurchased = purchased,
        activeEntryId = activeEntryId,
        activeEntryRank = activeEntryRank,
    }
end

local function normalizeTalents(talents, snapshot)
    if type(talents) ~= "table" then
        return nil, {}
    end

    if type(talents.allocations) == "table" and not talents.trees then
        return talents, {}
    end

    local state = {
        api = talents.api,
        kind = talents.kind,
        configId = talents.configId,
        name = talents.name,
        treeIds = copyArray(talents.treeIds),
        pointsSpent = talents.pointsSpent,
        pointsAvailable = talents.pointsAvailable,
        currencies = copyCurrencies(talents.currencies),
        allocations = {},
    }
    local definitions = {}
    local hasDeclaredTreeIds = #state.treeIds > 0

    for _, tree in ipairs(type(talents.trees) == "table" and talents.trees or {}) do
        if not hasDeclaredTreeIds then
            table.insert(state.treeIds, tree.id)
        end

        table.insert(definitions, normalizeTalentTreeDefinition(tree, snapshot, talents))
        for _, node in ipairs(type(tree.nodes) == "table" and tree.nodes or {}) do
            local allocation = talentAllocation(node)
            if allocation then
                table.insert(state.allocations, allocation)
            end
        end
    end

    return state, definitions
end

local function normalizeCharacterSnapshot(snapshot)
    if type(snapshot) ~= "table" then
        return snapshot, {}
    end

    if tonumber(snapshot.schemaVersion) == 3 then
        return snapshot, {}
    end

    local normalized = {
        schemaVersion = 3,
        capturedAt = snapshot.capturedAt,
        addonVersion = snapshot.addonVersion,
        characterKey = snapshot.characterKey,
        characterId = snapshot.characterId,
        name = snapshot.name,
        realm = snapshot.realm,
        region = snapshot.region,
        gameBuild = snapshot.gameBuild,
        level = snapshot.level,
        sex = snapshot.sex,
        bodyType = snapshot.bodyType,
        race = normalizeIdentity(snapshot.race),
        class = normalizeIdentity(snapshot.class),
        guild = snapshot.guild,
        specialization = normalizeSpecialization(snapshot.specialization),
        professions = {},
        equipment = {},
    }

    normalized.talents, normalized.talentDefinitions = normalizeTalents(snapshot.talents, normalized)

    for _, profession in ipairs(type(snapshot.professions) == "table" and snapshot.professions or {}) do
        local value = normalizeProfession(profession)
        if value then
            table.insert(normalized.professions, value)
        end
    end

    for _, item in ipairs(type(snapshot.equipment) == "table" and snapshot.equipment or {}) do
        local value = normalizeEquipmentItem(item)
        if value then
            table.insert(normalized.equipment, value)
        end
    end

    local definitions = normalized.talentDefinitions or {}
    normalized.talentDefinitions = nil
    return normalized, definitions
end

local function streamKeyPart(value)
    local normalized = string.lower(tostring(value or "unknown")):gsub("[^%w]+", "-")
    return normalized
end

local originalSetCharacterSnapshot = GW.Store.SetCharacterSnapshot
local originalSetTelemetrySnapshot = GW.Store.SetTelemetrySnapshot

local function emitTalentDefinitions(snapshot, definitions)
    local classToken = snapshot.class and snapshot.class.token or (snapshot.class and snapshot.class.name)
    local build = snapshot.gameBuild and snapshot.gameBuild.build or "unknown"

    for _, definition in ipairs(definitions or {}) do
        local streamKey = table.concat({
            "talent_tree_definition",
            streamKeyPart(classToken),
            streamKeyPart(build),
            streamKeyPart(definition.treeId),
        }, ":")

        originalSetTelemetrySnapshot(streamKey, {
            schemaVersion = 1,
            eventType = "talent_tree_definition",
            capturedAt = snapshot.capturedAt,
            gameBuild = snapshot.gameBuild,
            realm = snapshot.realm,
            region = snapshot.region,
            installationId = GW.Store.GetInstallationId(),
            payload = definition,
        })
    end
end

function GW.Store.SetCharacterSnapshot(characterKey, snapshot)
    if type(snapshot) ~= "table" then
        return originalSetCharacterSnapshot(characterKey, snapshot)
    end

    local normalized, definitions = normalizeCharacterSnapshot(snapshot)
    if normalized ~= snapshot then
        replaceTable(snapshot, normalized)
    end

    local changed = originalSetCharacterSnapshot(characterKey, snapshot)
    emitTalentDefinitions(snapshot, definitions)
    return changed
end

function GW.Store.SetTelemetrySnapshot(streamKey, envelope)
    if type(envelope) == "table" and envelope.eventType == "character_snapshot" and type(envelope.payload) == "table" then
        local normalized, definitions = normalizeCharacterSnapshot(envelope.payload)
        if normalized ~= envelope.payload then
            replaceTable(envelope.payload, normalized)
        end
        emitTalentDefinitions(envelope.payload, definitions)
    end

    return originalSetTelemetrySnapshot(streamKey, envelope)
end

GW.TelemetrySchema.NormalizeCharacterSnapshot = normalizeCharacterSnapshot
