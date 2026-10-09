local _, GW = ...

GW.Character = GW.Character or {}

local EQUIPMENT_SLOTS = {
    "HeadSlot",
    "NeckSlot",
    "ShoulderSlot",
    "BackSlot",
    "ChestSlot",
    "ShirtSlot",
    "TabardSlot",
    "WristSlot",
    "HandsSlot",
    "WaistSlot",
    "LegsSlot",
    "FeetSlot",
    "Finger0Slot",
    "Finger1Slot",
    "Trinket0Slot",
    "Trinket1Slot",
    "MainHandSlot",
    "SecondaryHandSlot",
}

local PROFESSION_KINDS = {
    "primary",
    "primary",
    "archaeology",
    "fishing",
    "cooking",
}

local REGION_NAMES = {
    [1] = "US",
    [2] = "KR",
    [3] = "EU",
    [4] = "TW",
    [5] = "CN",
}

local function safeCall(func, ...)
    if type(func) ~= "function" then
        return nil
    end

    local ok, value = pcall(func, ...)
    if not ok then
        return nil
    end

    return value
end

local function characterKey(name, realm)
    return string.lower((realm or "") .. ":" .. (name or ""))
end

local function currentCharacterIdentity()
    local name, realm = UnitFullName("player")
    name = name or UnitName("player")
    realm = realm or GetRealmName()

    if not name or name == "" then
        return nil, nil, nil
    end

    return name, realm, characterKey(name, realm)
end

local function collectRegion()
    local region = safeCall(GetCurrentRegion)
    return REGION_NAMES[tonumber(region)] or nil
end

local function collectGameBuild()
    if type(GetBuildInfo) ~= "function" then
        return nil
    end

    local ok, version, build, buildDate, interfaceVersion = pcall(GetBuildInfo)
    if not ok then
        return nil
    end

    return {
        version = version,
        build = build,
        buildDate = buildDate,
        interface = interfaceVersion,
    }
end

local function collectSpecialization()
    local index = nil

    if C_SpecializationInfo and type(C_SpecializationInfo.GetSpecialization) == "function" then
        index = safeCall(C_SpecializationInfo.GetSpecialization)
    elseif type(GetSpecialization) == "function" then
        index = safeCall(GetSpecialization)
    end

    if not index then
        return nil
    end

    local infoFunction = nil
    if C_SpecializationInfo and type(C_SpecializationInfo.GetSpecializationInfo) == "function" then
        infoFunction = C_SpecializationInfo.GetSpecializationInfo
    elseif type(GetSpecializationInfo) == "function" then
        infoFunction = GetSpecializationInfo
    end

    if not infoFunction then
        return { index = index }
    end

    local ok, id, name, description, icon, role = pcall(infoFunction, index)
    if not ok then
        return { index = index }
    end

    return {
        index = index,
        id = id,
        name = name or "",
        description = description or "",
        icon = icon,
        role = role or "",
    }
end

local function collectTraitConditions(configId, conditionIds)
    if not C_Traits or type(C_Traits.GetConditionInfo) ~= "function" then
        return nil
    end

    local conditions = {}
    for _, conditionId in ipairs(conditionIds or {}) do
        local info = safeCall(C_Traits.GetConditionInfo, configId, conditionId)
        if type(info) == "table" then
            table.insert(conditions, {
                id = conditionId,
                type = info.type,
                isMet = info.isMet,
                isGate = info.isGate,
                isSufficient = info.isSufficient,
                ranksGranted = info.ranksGranted,
            })
        end
    end

    return #conditions > 0 and conditions or nil
end

local function collectTraitConfig(configId, kind)
    if not configId or not C_Traits or type(C_Traits.GetConfigInfo) ~= "function" then
        return nil
    end

    local configInfo = safeCall(C_Traits.GetConfigInfo, configId)
    if type(configInfo) ~= "table" then
        return nil
    end

    local result = {
        api = "traits",
        kind = kind,
        configId = configId,
        name = configInfo.name,
        treeIds = configInfo.treeIDs or {},
        trees = {},
        currencies = {},
    }

    local totalSpent = 0
    local totalAvailable = 0

    for _, treeId in ipairs(configInfo.treeIDs or {}) do
        local treeInfo = type(C_Traits.GetTreeInfo) == "function" and safeCall(C_Traits.GetTreeInfo, configId, treeId) or nil
        local nodeIds = type(C_Traits.GetTreeNodes) == "function" and safeCall(C_Traits.GetTreeNodes, treeId) or {}
        local tree = {
            id = treeId,
            rootNodeId = type(treeInfo) == "table" and treeInfo.rootNodeID or nil,
            nodes = {},
            edges = {},
        }

        if type(C_Traits.GetTreeCurrencyInfo) == "function" then
            local currencies = safeCall(C_Traits.GetTreeCurrencyInfo, configId, treeId, true)
            if type(currencies) == "table" then
                for _, currency in ipairs(currencies) do
                    if type(currency) == "table" then
                        local spent = tonumber(currency.spent) or 0
                        local quantity = tonumber(currency.quantity) or 0
                        totalSpent = totalSpent + spent
                        totalAvailable = totalAvailable + quantity
                        table.insert(result.currencies, {
                            treeId = treeId,
                            traitCurrencyId = currency.traitCurrencyID,
                            quantity = currency.quantity,
                            maxQuantity = currency.maxQuantity,
                            spent = currency.spent,
                            spentInTree = currency.spentInTree,
                        })
                    end
                end
            end
        end

        for _, nodeId in ipairs(type(nodeIds) == "table" and nodeIds or {}) do
            local nodeInfo = type(C_Traits.GetNodeInfo) == "function" and safeCall(C_Traits.GetNodeInfo, configId, nodeId) or nil
            if type(nodeInfo) == "table" then
                local node = {
                    id = nodeId,
                    type = nodeInfo.type,
                    position = {
                        x = nodeInfo.posX,
                        y = nodeInfo.posY,
                    },
                    activeRank = nodeInfo.activeRank,
                    currentRank = nodeInfo.currentRank,
                    ranksPurchased = nodeInfo.ranksPurchased,
                    maxRanks = nodeInfo.maxRanks,
                    isAvailable = nodeInfo.isAvailable,
                    isVisible = nodeInfo.isVisible,
                    meetsEdgeRequirements = nodeInfo.meetsEdgeRequirements,
                    conditionIds = nodeInfo.conditionIDs or {},
                    conditions = collectTraitConditions(configId, nodeInfo.conditionIDs),
                    entries = {},
                }

                local activeEntryId = type(nodeInfo.activeEntry) == "table" and nodeInfo.activeEntry.entryID or nil
                local activeEntryRank = type(nodeInfo.activeEntry) == "table" and nodeInfo.activeEntry.rank or 0

                for _, entryId in ipairs(nodeInfo.entryIDs or {}) do
                    local entryInfo = type(C_Traits.GetEntryInfo) == "function" and safeCall(C_Traits.GetEntryInfo, configId, entryId) or nil
                    local definitionInfo = nil

                    if type(entryInfo) == "table" and entryInfo.definitionID and type(C_Traits.GetDefinitionInfo) == "function" then
                        definitionInfo = safeCall(C_Traits.GetDefinitionInfo, entryInfo.definitionID)
                    end

                    table.insert(node.entries, {
                        id = entryId,
                        definitionId = type(entryInfo) == "table" and entryInfo.definitionID or nil,
                        spellId = type(definitionInfo) == "table" and definitionInfo.spellID or nil,
                        icon = type(definitionInfo) == "table" and (definitionInfo.overrideIcon or definitionInfo.overrideIconID) or nil,
                        name = type(definitionInfo) == "table" and definitionInfo.overrideName or nil,
                        maxRanks = type(entryInfo) == "table" and entryInfo.maxRanks or nodeInfo.maxRanks,
                        selected = activeEntryId == entryId,
                        rank = activeEntryId == entryId and activeEntryRank or 0,
                        isAvailable = type(entryInfo) == "table" and entryInfo.isAvailable or nil,
                    })
                end

                for _, edgeInfo in ipairs(nodeInfo.visibleEdges or {}) do
                    if type(edgeInfo) == "table" and edgeInfo.targetNode then
                        table.insert(tree.edges, {
                            sourceNodeId = nodeId,
                            targetNodeId = edgeInfo.targetNode,
                            type = edgeInfo.type,
                            visualStyle = edgeInfo.visualStyle,
                            isActive = edgeInfo.isActive,
                        })
                    end
                end

                table.insert(tree.nodes, node)
            end
        end

        table.insert(result.trees, tree)
    end

    result.pointsSpent = totalSpent
    result.pointsAvailable = totalAvailable
    return result
end

local function collectLegacyTalents()
    if type(GetNumTalentTabs) ~= "function" or type(GetTalentTabInfo) ~= "function" or type(GetNumTalents) ~= "function" or type(GetTalentInfo) ~= "function" then
        return nil
    end

    local tabCount = safeCall(GetNumTalentTabs) or 0
    local result = {
        api = "legacy",
        trees = {},
        pointsSpent = 0,
    }

    for tabIndex = 1, tabCount do
        local ok, name, icon, pointsSpent = pcall(GetTalentTabInfo, tabIndex)
        local tree = {
            id = tabIndex,
            name = ok and name or nil,
            icon = ok and icon or nil,
            nodes = {},
            edges = {},
        }

        result.pointsSpent = result.pointsSpent + (ok and tonumber(pointsSpent) or 0)
        local talentCount = safeCall(GetNumTalents, tabIndex) or 0

        for talentIndex = 1, talentCount do
            local infoOk, talentName, talentIcon, tier, column, rank, maxRank, isExceptional, meetsPrereq = pcall(GetTalentInfo, tabIndex, talentIndex)
            if infoOk and talentName then
                local spellId = nil
                if type(GetTalentLink) == "function" then
                    local link = safeCall(GetTalentLink, tabIndex, talentIndex)
                    spellId = type(link) == "string" and tonumber(link:match("spell:(%d+)")) or nil
                end

                table.insert(tree.nodes, {
                    id = talentIndex,
                    position = { x = column, y = tier },
                    currentRank = rank,
                    activeRank = rank,
                    maxRanks = maxRank,
                    meetsEdgeRequirements = meetsPrereq,
                    entries = {
                        {
                            id = talentIndex,
                            spellId = spellId,
                            icon = talentIcon,
                            name = talentName,
                            selected = (tonumber(rank) or 0) > 0,
                            rank = rank,
                            maxRanks = maxRank,
                            isExceptional = isExceptional,
                        },
                    },
                })
            end
        end

        table.insert(result.trees, tree)
    end

    if type(UnitCharacterPoints) == "function" then
        result.pointsAvailable = safeCall(UnitCharacterPoints, "player")
    end

    return result
end

local function collectTalents()
    if C_ClassTalents and C_Traits and type(C_ClassTalents.GetActiveConfigID) == "function" then
        local configId = safeCall(C_ClassTalents.GetActiveConfigID)
        local modern = collectTraitConfig(configId, "combat")
        if modern then
            return modern
        end
    end

    return collectLegacyTalents()
end

local function collectProfessionSpecialization(skillLineId)
    if not skillLineId or not C_ProfSpecs or type(C_ProfSpecs.GetConfigIDForSkillLine) ~= "function" then
        return nil
    end

    local configId = safeCall(C_ProfSpecs.GetConfigIDForSkillLine, skillLineId)
    if not configId then
        return nil
    end

    local configInfo = C_Traits and type(C_Traits.GetConfigInfo) == "function" and safeCall(C_Traits.GetConfigInfo, configId) or nil
    return {
        configId = configId,
        name = type(configInfo) == "table" and configInfo.name or nil,
        treeIds = type(configInfo) == "table" and (configInfo.treeIDs or {}) or {},
    }
end

local function previousProfessionRecipes(previousSnapshot)
    local byId = {}
    local byName = {}

    for _, profession in ipairs(previousSnapshot and previousSnapshot.professions or {}) do
        if profession.id then
            byId[tostring(profession.id)] = profession
        end
        if profession.name and profession.name ~= "" then
            byName[string.lower(profession.name)] = profession
        end
    end

    return byId, byName
end

local function recipeOverrideMatches(profession, recipeOverride)
    if not recipeOverride then
        return false
    end

    if profession.id and recipeOverride.professionId and tonumber(profession.id) == tonumber(recipeOverride.professionId) then
        return true
    end

    if profession.name and recipeOverride.professionName and string.lower(profession.name) == string.lower(recipeOverride.professionName) then
        return true
    end

    return false
end

local function collectProfessions(previousSnapshot, recipeOverride)
    local professions = {}
    local indices = { GetProfessions() }
    local previousById, previousByName = previousProfessionRecipes(previousSnapshot)

    for position, index in ipairs(indices) do
        if index then
            local name, icon, skillLevel, maxSkillLevel, _, _, skillLineId, skillModifier, _, _, skillLineName = GetProfessionInfo(index)

            if name then
                local profession = {
                    id = skillLineId,
                    name = name,
                    kind = PROFESSION_KINDS[position] or "secondary",
                    icon = icon,
                    skillLevel = skillLevel or 0,
                    maxSkillLevel = maxSkillLevel or 0,
                    skillLineId = skillLineId,
                    skillModifier = skillModifier or 0,
                    skillLineName = skillLineName or "",
                    specialization = collectProfessionSpecialization(skillLineId),
                }

                local previous = skillLineId and previousById[tostring(skillLineId)] or previousByName[string.lower(name)]
                if previous and previous.recipes then
                    profession.recipes = previous.recipes
                    profession.recipeSnapshotAt = previous.recipeSnapshotAt
                    profession.recipeSource = previous.recipeSource
                end

                if recipeOverrideMatches(profession, recipeOverride) then
                    profession.recipes = recipeOverride.recipes
                    profession.recipeSnapshotAt = recipeOverride.capturedAt
                    profession.recipeSource = recipeOverride.source
                end

                table.insert(professions, profession)
            end
        end
    end

    return professions
end

local function parseItemLinkData(itemLink)
    if type(itemLink) ~= "string" then
        return nil
    end

    local itemString = itemLink:match("|H(item:[^|]+)|h") or itemLink:match("(item:[%-%d:]+)")
    if not itemString then
        return nil
    end

    local payload = itemString:match("^item:(.*)$")
    if not payload then
        return nil
    end

    local fields = {}
    for field in string.gmatch(payload .. ":", "(.-):") do
        local numeric = tonumber(field)
        table.insert(fields, numeric or field)
    end

    local gemIds = {}
    for index = 3, 6 do
        local gemId = tonumber(fields[index])
        if gemId and gemId > 0 then
            table.insert(gemIds, gemId)
        end
    end

    local bonusIds = {}
    local bonusCount = tonumber(fields[13]) or 0
    for index = 1, bonusCount do
        local bonusId = tonumber(fields[13 + index])
        if bonusId then
            table.insert(bonusIds, bonusId)
        end
    end

    return {
        itemString = itemString,
        fields = fields,
        itemId = tonumber(fields[1]),
        enchantId = tonumber(fields[2]),
        gemIds = gemIds,
        suffixId = tonumber(fields[7]),
        uniqueId = tonumber(fields[8]),
        linkLevel = tonumber(fields[9]),
        specializationId = tonumber(fields[10]),
        upgradeTypeId = tonumber(fields[11]),
        instanceDifficultyId = tonumber(fields[12]),
        bonusIds = bonusIds,
    }
end

local function collectItemMetadata(itemLink)
    if type(GetItemInfo) ~= "function" then
        return nil
    end

    local ok, name, link, quality, itemLevel, requiredLevel, itemClass, itemSubClass, stackCount, equipLocation, icon, sellPrice, classId, subClassId, bindType, expansionId, setId, isCraftingReagent = pcall(GetItemInfo, itemLink)
    if not ok or not name then
        return nil
    end

    return {
        name = name,
        link = link,
        quality = quality,
        itemLevel = itemLevel,
        requiredLevel = requiredLevel,
        class = itemClass,
        subclass = itemSubClass,
        stackCount = stackCount,
        equipLocation = equipLocation,
        icon = icon,
        sellPrice = sellPrice,
        classId = classId,
        subclassId = subClassId,
        bindType = bindType,
        expansionId = expansionId,
        setId = setId,
        isCraftingReagent = isCraftingReagent,
    }
end

local function collectEquipment()
    local equipment = {}

    for _, slotName in ipairs(EQUIPMENT_SLOTS) do
        local slotId = GetInventorySlotInfo(slotName)
        local itemLink = slotId and GetInventoryItemLink("player", slotId) or nil

        if itemLink then
            local linkData = parseItemLinkData(itemLink) or {}
            local metadata = collectItemMetadata(itemLink) or {}
            local itemId = type(GetInventoryItemID) == "function" and safeCall(GetInventoryItemID, "player", slotId) or linkData.itemId
            local quality = type(GetInventoryItemQuality) == "function" and safeCall(GetInventoryItemQuality, "player", slotId) or metadata.quality
            local icon = type(GetInventoryItemTexture) == "function" and safeCall(GetInventoryItemTexture, "player", slotId) or metadata.icon
            local itemLevel = type(GetDetailedItemLevelInfo) == "function" and safeCall(GetDetailedItemLevelInfo, itemLink) or metadata.itemLevel

            table.insert(equipment, {
                slot = slotName,
                slotId = slotId,
                itemId = itemId,
                itemLink = itemLink,
                itemString = linkData.itemString,
                quality = quality,
                itemLevel = itemLevel,
                icon = icon,
                enchantId = linkData.enchantId,
                gemIds = linkData.gemIds or {},
                bonusIds = linkData.bonusIds or {},
                modifierData = linkData.fields or {},
                name = metadata.name,
                requiredLevel = metadata.requiredLevel,
                class = metadata.class,
                subclass = metadata.subclass,
                classId = metadata.classId,
                subclassId = metadata.subclassId,
                equipLocation = metadata.equipLocation,
                bindType = metadata.bindType,
                expansionId = metadata.expansionId,
                setId = metadata.setId,
            })
        end
    end

    return equipment
end

local function collectGuild()
    local guildName, rankName, rankIndex, guildRealm = GetGuildInfo("player")

    if not guildName then
        return nil
    end

    return {
        name = guildName,
        rankName = rankName or "",
        rankIndex = rankIndex,
        realm = guildRealm or GetRealmName(),
    }
end

function GW.Character.Capture(reason, recipeOverride)
    local name, realm, key = currentCharacterIdentity()
    if not key then
        return nil
    end

    local raceName, raceFile, raceId = UnitRace("player")
    local className, classFile, classId = UnitClass("player")
    local capturedAt = GetServerTime()
    local previousSnapshot = GW.Store.GetCharacterSnapshot(key)
    local guild = collectGuild()
    local characterId = GW.Store.GetCharacterId(key)
    local installationId = GW.Store.GetInstallationId()
    local gameBuild = collectGameBuild()
    local sex = UnitSex("player")
    local snapshot = {
        schemaVersion = 2,
        capturedAt = capturedAt,
        reason = reason or "manual",
        addonVersion = GW.version,
        characterKey = key,
        characterId = characterId,
        name = name,
        realm = realm,
        region = collectRegion(),
        gameBuild = gameBuild,
        level = UnitLevel("player"),
        sex = sex,
        bodyType = sex == 2 and "male" or (sex == 3 and "female" or nil),
        race = {
            name = raceName or "",
            file = raceFile or "",
            id = raceId,
        },
        class = {
            name = className or "",
            file = classFile or "",
            id = classId,
        },
        guild = guild,
        specialization = collectSpecialization(),
        talents = collectTalents(),
        professions = collectProfessions(previousSnapshot, recipeOverride),
        equipment = collectEquipment(),
    }

    GW.Store.SetCharacterSnapshot(key, snapshot)

    local envelope = {
        schemaVersion = 1,
        eventType = "character_snapshot",
        capturedAt = capturedAt,
        gameBuild = gameBuild,
        realm = realm,
        region = snapshot.region,
        installationId = installationId,
        characterId = characterId,
        guildId = guild and ("guild-" .. GW.Store.Fingerprint({ name = guild.name, realm = guild.realm })) or nil,
        payload = snapshot,
    }

    GW.Store.SetTelemetrySnapshot("character_snapshot:" .. characterId, envelope)
    return snapshot
end

function GW.Character.CaptureProfessionRecipes(reason)
    local professions = GW.ProfessionTelemetry
    if not professions then
        return nil
    end

    local kind = string.find(tostring(reason or ""), "CRAFT", 1, true) and "craft" or "tradeskill"
    local book = professions.CollectOpenRecipeBook(kind)
    if not book then
        return nil
    end

    local _, _, key = currentCharacterIdentity()
    professions.RememberRecipeBook(key, book)
    -- Capturing the character publishes every telemetry domain, including
    -- profession_snapshot; the override keeps character_snapshot's recipes
    -- populated for older website builds.
    return GW.Character.Capture(reason or "TRADE_SKILL", professions.ToCharacterRecipeOverride(book))
end

function GW.Character.GetCurrentSnapshot()
    local _, _, key = currentCharacterIdentity()
    if not key then
        return nil
    end

    return GW.Store.GetCharacterSnapshot(key)
end

local function safeRegister(frame, event)
    pcall(frame.RegisterEvent, frame, event)
end

function GW.Character:Initialize()
    if self.eventFrame then
        return
    end

    local frame = CreateFrame("Frame")
    local characterEvents = {
        "PLAYER_LOGIN",
        "PLAYER_ENTERING_WORLD",
        "PLAYER_LOGOUT",
        "PLAYER_LEVEL_UP",
        "PLAYER_GUILD_UPDATE",
        "GUILD_ROSTER_UPDATE",
        "SKILL_LINES_CHANGED",
        "PLAYER_EQUIPMENT_CHANGED",
        "PLAYER_SPECIALIZATION_CHANGED",
        "PLAYER_TALENT_UPDATE",
        "ACTIVE_TALENT_GROUP_CHANGED",
        "TRAIT_CONFIG_UPDATED",
    }
    local professionEvents = {
        "TRADE_SKILL_SHOW",
        "TRADE_SKILL_LIST_UPDATE",
        "NEW_RECIPE_LEARNED",
        "CRAFT_SHOW",
        "CRAFT_UPDATE",
    }

    for _, event in ipairs(characterEvents) do
        safeRegister(frame, event)
    end
    for _, event in ipairs(professionEvents) do
        safeRegister(frame, event)
    end

    local professionCapturePending = {}
    frame:SetScript("OnEvent", function(_, event, unit)
        if event == "PLAYER_SPECIALIZATION_CHANGED" and unit and unit ~= "player" then
            return
        end

        if event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_LIST_UPDATE" or event == "NEW_RECIPE_LEARNED"
            or event == "CRAFT_SHOW" or event == "CRAFT_UPDATE" then
            -- Debounce bursts of list updates; trade skill and craft windows
            -- are tracked separately so one cannot swallow the other.
            local kind = string.find(event, "CRAFT", 1, true) and "craft" or "tradeskill"
            if not professionCapturePending[kind] then
                professionCapturePending[kind] = true
                C_Timer.After(0.5, function()
                    professionCapturePending[kind] = false
                    GW.Character.CaptureProfessionRecipes(event)
                end)
            end
            return
        end

        GW.Character.Capture(event)
    end)

    self.eventFrame = frame

    C_Timer.After(2, function()
        GW.Character.Capture("INITIAL_DELAY")
    end)
end
