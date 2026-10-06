local _, GW = ...

GW.ProfessionTelemetry = GW.ProfessionTelemetry or {}

local PROFESSION_SLOTS = {
    { kind = "primary", label = "primary_1" },
    { kind = "primary", label = "primary_2" },
    { kind = "archaeology", label = "archaeology" },
    { kind = "fishing", label = "fishing" },
    { kind = "cooking", label = "cooking" },
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

local function currentIdentity()
    local name, realm = UnitFullName("player")
    name = name or UnitName("player")
    realm = realm or GetRealmName()

    if not name or name == "" then
        return nil
    end

    local key = string.lower((realm or "") .. ":" .. name)
    return {
        name = name,
        realm = realm,
        key = key,
        characterId = GW.Store.GetCharacterId(key),
        installationId = GW.Store.GetInstallationId(),
        region = REGION_NAMES[tonumber(safeCall(GetCurrentRegion))],
        gameBuild = collectGameBuild(),
    }
end

local function currentGuildId()
    if type(GetGuildInfo) ~= "function" then
        return nil
    end

    local guildName, _, _, guildRealm = GetGuildInfo("player")
    if not guildName then
        return nil
    end

    return "guild-" .. GW.Store.Fingerprint({
        name = guildName,
        realm = guildRealm or GetRealmName(),
    })
end

local function recipeIndex(snapshot)
    local byId = {}
    local byName = {}

    for _, profession in ipairs(snapshot and snapshot.professions or {}) do
        if profession.id then
            byId[tostring(profession.id)] = profession
        end
        if profession.name and profession.name ~= "" then
            byName[string.lower(profession.name)] = profession
        end
    end

    return byId, byName
end

local function professionSpecialization(skillLineId)
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

local function professionIndices()
    if type(GetProfessions) ~= "function" then
        return {}
    end

    local first, second, archaeology, fishing, cooking = GetProfessions()
    return { first, second, archaeology, fishing, cooking }
end

local function collectProfessions(characterSnapshot)
    local professions = {}
    local previousById, previousByName = recipeIndex(characterSnapshot)
    local indices = professionIndices()

    for position = 1, #PROFESSION_SLOTS do
        local index = indices[position]
        if index and type(GetProfessionInfo) == "function" then
            local ok, name, icon, skillLevel, maxSkillLevel, _, _, skillLineId, skillModifier, _, _, skillLineName = pcall(GetProfessionInfo, index)

            if ok and name then
                local previous = skillLineId and previousById[tostring(skillLineId)] or previousByName[string.lower(name)]
                local recipes = previous and previous.recipes or nil
                local knownRecipes = 0

                for _, recipe in ipairs(recipes or {}) do
                    if recipe.known ~= false then
                        knownRecipes = knownRecipes + 1
                    end
                end

                table.insert(professions, {
                    slot = PROFESSION_SLOTS[position].label,
                    kind = PROFESSION_SLOTS[position].kind,
                    index = index,
                    id = skillLineId,
                    skillLineId = skillLineId,
                    skillLineName = skillLineName or "",
                    name = name,
                    icon = icon,
                    skillLevel = tonumber(skillLevel) or 0,
                    maxSkillLevel = tonumber(maxSkillLevel) or 0,
                    skillModifier = tonumber(skillModifier) or 0,
                    specialization = professionSpecialization(skillLineId),
                    recipeSnapshotAt = previous and previous.recipeSnapshotAt or nil,
                    recipeSource = previous and previous.recipeSource or nil,
                    recipeCount = recipes and #recipes or 0,
                    knownRecipeCount = knownRecipes,
                    recipes = recipes,
                })
            end
        end
    end

    return professions
end

local function envelope(identity, eventType, payload, capturedAt)
    return {
        schemaVersion = 1,
        eventType = eventType,
        capturedAt = capturedAt,
        gameBuild = identity.gameBuild,
        realm = identity.realm,
        region = identity.region,
        installationId = identity.installationId,
        characterId = identity.characterId,
        guildId = currentGuildId(),
        payload = payload,
    }
end

local function professionStreamKey(profession)
    if profession.id then
        return tostring(profession.id)
    end

    return string.lower((profession.name or "unknown"):gsub("%s+", "-"))
end

function GW.ProfessionTelemetry.Capture(reason)
    local identity = currentIdentity()
    if not identity then
        return nil
    end

    local characterSnapshot = GW.Character and GW.Character.GetCurrentSnapshot and GW.Character.GetCurrentSnapshot() or nil
    local professions = collectProfessions(characterSnapshot)
    local capturedAt = GetServerTime()
    local payload = {
        schemaVersion = 1,
        capturedAt = capturedAt,
        reason = reason or "manual",
        characterId = identity.characterId,
        professions = professions,
    }

    GW.Store.SetTelemetrySnapshot(
        "profession_snapshot:" .. identity.characterId,
        envelope(identity, "profession_snapshot", payload, capturedAt)
    )

    for _, profession in ipairs(professions) do
        if profession.recipes and #profession.recipes > 0 then
            local recipePayload = {
                schemaVersion = 1,
                capturedAt = profession.recipeSnapshotAt or capturedAt,
                characterId = identity.characterId,
                profession = {
                    id = profession.id,
                    name = profession.name,
                    kind = profession.kind,
                    skillLevel = profession.skillLevel,
                    maxSkillLevel = profession.maxSkillLevel,
                    skillModifier = profession.skillModifier,
                },
                recipes = profession.recipes,
            }

            GW.Store.SetTelemetrySnapshot(
                "recipe_catalog_snapshot:" .. identity.characterId .. ":" .. professionStreamKey(profession),
                envelope(identity, "recipe_catalog_snapshot", recipePayload, recipePayload.capturedAt)
            )
        end
    end

    return payload
end

function GW.ProfessionTelemetry.GetDiagnostics()
    local snapshot = GW.Character and GW.Character.GetCurrentSnapshot and GW.Character.GetCurrentSnapshot() or nil
    local payload = GW.ProfessionTelemetry.Capture("DIAGNOSTIC")
    local recipeCount = 0

    for _, profession in ipairs(payload and payload.professions or {}) do
        recipeCount = recipeCount + (profession.knownRecipeCount or 0)
    end

    return {
        level = snapshot and snapshot.level or UnitLevel("player"),
        specialization = snapshot and snapshot.specialization or nil,
        talentApi = snapshot and snapshot.talents and snapshot.talents.api or nil,
        professionCount = payload and #payload.professions or 0,
        knownRecipeCount = recipeCount,
        professions = payload and payload.professions or {},
    }
end

local function safeRegister(frame, event)
    pcall(frame.RegisterEvent, frame, event)
end

function GW.ProfessionTelemetry:Initialize()
    if self.eventFrame then
        return
    end

    local frame = CreateFrame("Frame")
    local events = {
        "PLAYER_LOGIN",
        "PLAYER_ENTERING_WORLD",
        "SKILL_LINES_CHANGED",
        "TRADE_SKILL_SHOW",
        "TRADE_SKILL_LIST_UPDATE",
        "NEW_RECIPE_LEARNED",
    }

    for _, event in ipairs(events) do
        safeRegister(frame, event)
    end

    local capturePending = false
    frame:SetScript("OnEvent", function(_, event)
        if capturePending then
            return
        end

        capturePending = true
        C_Timer.After(0.9, function()
            capturePending = false
            GW.ProfessionTelemetry.Capture(event)
        end)
    end)

    self.eventFrame = frame

    C_Timer.After(3, function()
        GW.ProfessionTelemetry.Capture("INITIAL_DELAY")
    end)
end
