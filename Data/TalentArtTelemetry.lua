local _, GW = ...

GW.TalentArtTelemetry = GW.TalentArtTelemetry or {}

local function nonEmpty(value)
    return type(value) == "string" and value ~= ""
end

local function currentSpecializationIndex(snapshot)
    local index = snapshot and snapshot.specialization and tonumber(snapshot.specialization.index) or nil
    if index then
        return index
    end

    local getter = C_SpecializationInfo and C_SpecializationInfo.GetSpecialization or GetSpecialization
    if type(getter) ~= "function" then
        return nil
    end

    local ok, value = pcall(getter)
    return ok and tonumber(value) or nil
end

local function collectSpecializationArt(snapshot)
    local index = currentSpecializationIndex(snapshot)
    if not index then
        return nil
    end

    local getter = C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo or GetSpecializationInfo
    if type(getter) ~= "function" then
        return nil
    end

    local ok, id, name, description, icon, role, primaryStat, pointsSpent, background, previewPointsSpent, isUnlocked = pcall(getter, index)
    if not ok then
        return nil
    end

    if not id and not nonEmpty(name) and not icon and not nonEmpty(background) then
        return nil
    end

    return {
        source = "C_SpecializationInfo.GetSpecializationInfo",
        index = index,
        id = id,
        name = name,
        description = nonEmpty(description) and description or nil,
        iconFileDataId = icon,
        role = nonEmpty(role) and role or nil,
        primaryStat = primaryStat,
        pointsSpent = pointsSpent,
        background = nonEmpty(background) and background or nil,
        previewPointsSpent = previewPointsSpent,
        isUnlocked = isUnlocked,
    }
end

local function talentBackgroundTextures(background)
    if not nonEmpty(background) then
        return nil
    end

    local prefix = "Interface\\TalentFrame\\" .. background
    return {
        topLeft = prefix .. "-TopLeft",
        topRight = prefix .. "-TopRight",
        bottomLeft = prefix .. "-BottomLeft",
        bottomRight = prefix .. "-BottomRight",
    }
end

local function collectTalentTabs()
    if type(GetNumTalentTabs) ~= "function" or type(GetTalentTabInfo) ~= "function" then
        return nil
    end

    local okCount, count = pcall(GetNumTalentTabs)
    if not okCount or not tonumber(count) or tonumber(count) < 1 then
        return nil
    end

    local tabs = {}
    for index = 1, tonumber(count) do
        local ok, first, second, third, fourth, fifth, sixth, seventh, eighth = pcall(GetTalentTabInfo, index)
        if ok then
            local tab = nil

            -- Current Classic/Forever-compatible shape:
            -- id, name, description, icon, pointsSpent, background, previewPointsSpent, isUnlocked
            if type(first) == "number" and type(second) == "string" then
                tab = {
                    id = first,
                    name = second,
                    description = nonEmpty(third) and third or nil,
                    iconFileDataId = fourth,
                    pointsSpent = fifth,
                    background = nonEmpty(sixth) and sixth or nil,
                    previewPointsSpent = seventh,
                    isUnlocked = eighth,
                }
            -- Older Classic shape retained as a defensive fallback:
            -- name, icon, pointsSpent, background
            elseif type(first) == "string" then
                tab = {
                    id = index,
                    name = first,
                    iconFileDataId = second,
                    pointsSpent = third,
                    background = nonEmpty(fourth) and fourth or nil,
                }
            end

            if tab then
                tab.index = index
                tab.source = "GetTalentTabInfo"
                tab.backgroundTextures = talentBackgroundTextures(tab.background)
                table.insert(tabs, tab)
            end
        end
    end

    return #tabs > 0 and tabs or nil
end

local function collectTreeArt(snapshot)
    local result = {}
    local talents = snapshot and snapshot.talents
    local configId = talents and tonumber(talents.configId) or nil

    if not configId or not C_Traits or type(C_Traits.GetTreeInfo) ~= "function" then
        return result
    end

    for _, tree in ipairs(type(talents.trees) == "table" and talents.trees or {}) do
        if type(tree) == "table" and tree.id then
            local ok, info = pcall(C_Traits.GetTreeInfo, configId, tree.id)
            if ok and type(info) == "table" then
                result[tostring(tree.id)] = {
                    source = "C_Traits.GetTreeInfo",
                    treeId = tree.id,
                    uiTextureKit = nonEmpty(info.uiTextureKit) and info.uiTextureKit or nil,
                    titleText = nonEmpty(info.titleText) and info.titleText or nil,
                    hideSingleRankNumbers = info.hideSingleRankNumbers,
                    cannotRefund = info.cannotRefund,
                }
            end
        end
    end

    return result
end

local function collectArt(snapshot)
    return {
        schemaVersion = 1,
        specialization = collectSpecializationArt(snapshot),
        talentTabs = collectTalentTabs(),
        trees = collectTreeArt(snapshot),
    }
end

local function hasArt(art)
    return art and (art.specialization or art.talentTabs or next(art.trees or {}) ~= nil)
end

local originalNormalize = GW.TelemetrySchema and GW.TelemetrySchema.NormalizeCharacterSnapshot

if type(originalNormalize) == "function" then
    function GW.TelemetrySchema.NormalizeCharacterSnapshot(snapshot)
        local art = collectArt(snapshot)
        local normalized, definitions = originalNormalize(snapshot)

        if type(normalized) == "table" and hasArt(art) then
            if type(normalized.specialization) == "table" and art.specialization then
                normalized.specialization.background = art.specialization.background
                normalized.specialization.primaryStat = art.specialization.primaryStat
                normalized.specialization.pointsSpent = art.specialization.pointsSpent
                normalized.specialization.previewPointsSpent = art.specialization.previewPointsSpent
                normalized.specialization.isUnlocked = art.specialization.isUnlocked
            end

            if type(normalized.talents) == "table" then
                normalized.talents.art = art
            end

            for _, definition in ipairs(type(definitions) == "table" and definitions or {}) do
                local treeArt = art.trees and art.trees[tostring(definition.treeId or "")] or nil
                definition.art = {
                    schemaVersion = 1,
                    specialization = art.specialization,
                    talentTabs = art.talentTabs,
                    tree = treeArt,
                }
            end
        end

        return normalized, definitions
    end
end

GW.TalentArtTelemetry.Collect = collectArt
