local _, GW = ...

local Globals = _G or {}

GW.GatheringTelemetry = GW.GatheringTelemetry or {}

local PROFESSION_SKILL_LINE_IDS = {
    herbalism = 182,
    mining = 186,
    skinning = 393,
    fishing = 356,
}
local BOUNTIFUL_HARVEST_SPELL_ID = 1225435
local LEGACY_SYSTEM_PROBE_MAX = 120

local function safe(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, value = pcall(fn, ...)
    if not ok then
        return nil
    end
    return value
end

local function scalar(value)
    if type(Globals.issecretvalue) == "function" then
        local ok, secret = pcall(Globals.issecretvalue, value)
        if ok and secret then
            return nil
        end
    end
    return value
end

local function cleanString(value)
    value = scalar(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    return value
end

local function serverTime()
    return tonumber(safe(Globals.GetServerTime)) or 0
end

local function currentSnapshot()
    local character = GW.Character
    if type(character) ~= "table" or type(character.GetCurrentSnapshot) ~= "function" then
        return nil
    end
    local snapshot = safe(character.GetCurrentSnapshot)
    return type(snapshot) == "table" and snapshot or nil
end

local function currentLocation()
    local result = {
        zone = cleanString(safe(Globals.GetRealZoneText)),
        subzone = cleanString(safe(Globals.GetSubZoneText)),
    }

    local mapApi = Globals.C_Map
    if type(mapApi) == "table" and type(mapApi.GetBestMapForUnit) == "function" then
        local mapId = safe(mapApi.GetBestMapForUnit, "player")
        if tonumber(mapId) then
            result.mapId = tonumber(mapId)
            if type(mapApi.GetPlayerMapPosition) == "function" then
                local point = safe(mapApi.GetPlayerMapPosition, mapId, "player")
                if point then
                    local x, y = nil, nil
                    if type(point.GetXY) == "function" then
                        local ok, px, py = pcall(point.GetXY, point)
                        if ok then
                            x, y = px, py
                        end
                    else
                        x, y = point.x, point.y
                    end
                    x, y = tonumber(scalar(x)), tonumber(scalar(y))
                    if x and y then
                        result.x = math.floor(x * 100000 + 0.5) / 100000
                        result.y = math.floor(y * 100000 + 0.5) / 100000
                    end
                end
            end
        end
    end

    return result
end

local function professionMatches(profession, discipline)
    if type(profession) ~= "table" then
        return false
    end

    local expectedSkillLineId = PROFESSION_SKILL_LINE_IDS[discipline]
    local skillLineId = tonumber(profession.skillLineId or profession.id)
    if expectedSkillLineId and skillLineId == expectedSkillLineId then
        return true
    end

    local name = cleanString(profession.name)
    if not name or not discipline then
        return false
    end
    return string.find(string.lower(name), string.lower(discipline), 1, true) ~= nil
end

local function professionContext(discipline)
    local professions = nil
    local module = GW.ProfessionTelemetry
    if type(module) == "table" and type(module.CollectProfessions) == "function" then
        professions = safe(module.CollectProfessions)
    end

    if type(professions) ~= "table" then
        local snapshot = currentSnapshot()
        professions = snapshot and snapshot.professions or nil
    end

    for _, profession in ipairs(type(professions) == "table" and professions or {}) do
        if professionMatches(profession, discipline) then
            return {
                skillLineId = tonumber(profession.skillLineId or profession.id),
                name = cleanString(profession.name),
                skillLevel = tonumber(profession.skillLevel),
                maxSkillLevel = tonumber(profession.maxSkillLevel),
                skillModifier = tonumber(profession.skillModifier) or 0,
                specialization = type(profession.specialization) == "table" and profession.specialization or nil,
            }
        end
    end

    return nil
end

local function configIds()
    local traits = Globals.C_Traits
    if type(traits) ~= "table" then
        return {}
    end

    local ids = {}
    local seen = {}
    local function add(id)
        id = tonumber(id)
        if id and not seen[id] then
            seen[id] = true
            table.insert(ids, id)
        end
    end

    local enum = Globals.Enum and Globals.Enum.TraitConfigType
    if type(enum) == "table" and type(traits.GetConfigsByType) == "function" then
        for _, configType in pairs(enum) do
            if tonumber(configType) then
                local found = safe(traits.GetConfigsByType, configType)
                for _, id in ipairs(type(found) == "table" and found or {}) do
                    add(id)
                end
            end
        end
    end

    if type(traits.GetConfigIDBySystemID) == "function" then
        for systemId = 1, LEGACY_SYSTEM_PROBE_MAX do
            add(safe(traits.GetConfigIDBySystemID, systemId))
        end
    end

    return ids
end

local function findTraitSpell(spellId)
    local traits = Globals.C_Traits
    if type(traits) ~= "table" or type(traits.GetConfigInfo) ~= "function"
        or type(traits.GetTreeNodes) ~= "function" or type(traits.GetNodeInfo) ~= "function"
        or type(traits.GetEntryInfo) ~= "function" or type(traits.GetDefinitionInfo) ~= "function" then
        return nil
    end

    local best = nil
    for _, configId in ipairs(configIds()) do
        local config = safe(traits.GetConfigInfo, configId)
        for _, treeId in ipairs(type(config) == "table" and config.treeIDs or {}) do
            local nodes = safe(traits.GetTreeNodes, treeId)
            for _, nodeId in ipairs(type(nodes) == "table" and nodes or {}) do
                local node = safe(traits.GetNodeInfo, configId, nodeId)
                if type(node) == "table" then
                    for _, entryId in ipairs(node.entryIDs or {}) do
                        local entry = safe(traits.GetEntryInfo, configId, entryId)
                        local definition = type(entry) == "table" and entry.definitionID
                            and safe(traits.GetDefinitionInfo, entry.definitionID) or nil
                        if type(definition) == "table" and tonumber(definition.spellID) == tonumber(spellId) then
                            local rank = tonumber(node.ranksPurchased or node.currentRank or node.activeRank) or 0
                            if type(node.activeEntry) == "table" and tonumber(node.activeEntry.entryID) == tonumber(entryId) then
                                rank = tonumber(node.activeEntry.rank) or rank
                            end
                            local candidate = {
                                spellId = tonumber(spellId),
                                rank = rank,
                                maxRanks = tonumber(node.maxRanks) or tonumber(entry.maxRanks),
                                configId = tonumber(configId),
                                configName = cleanString(config.name),
                                treeId = tonumber(treeId),
                                nodeId = tonumber(nodeId),
                                entryId = tonumber(entryId),
                            }
                            if not best or candidate.rank > best.rank then
                                best = candidate
                            end
                        end
                    end
                end
            end
        end
    end

    return best
end

function GW.GatheringTelemetry.RefreshEconomicModifiers()
    GW.GatheringTelemetry.cachedModifiers = {
        bountifulHarvest = findTraitSpell(BOUNTIFUL_HARVEST_SPELL_ID),
    }
    return GW.GatheringTelemetry.cachedModifiers
end

local function economicModifiers(discipline)
    if discipline ~= "herbalism" then
        return nil
    end
    if type(GW.GatheringTelemetry.cachedModifiers) ~= "table" then
        GW.GatheringTelemetry.RefreshEconomicModifiers()
    end
    return GW.GatheringTelemetry.cachedModifiers
end

function GW.GatheringTelemetry.CaptureContext(discipline)
    local snapshot = currentSnapshot()
    if not snapshot then
        return nil
    end

    return {
        attemptedAt = serverTime(),
        characterLevel = tonumber(safe(Globals.UnitLevel, "player")) or tonumber(snapshot.level),
        profession = professionContext(discipline),
        modifiers = economicModifiers(discipline),
        location = currentLocation(),
    }
end

local function itemIdFromLink(link)
    if type(link) ~= "string" then
        return nil
    end
    return tonumber(link:match("item:(%d+)"))
end

local function sourceIdentity(guid)
    guid = cleanString(guid)
    if not guid then
        return nil, nil, nil
    end

    local parts = {}
    for part in string.gmatch(guid, "[^%-]+") do
        table.insert(parts, part)
    end
    local kind = parts[1]
    local entityId = tonumber(parts[6])
    local objectId = kind == "GameObject" and entityId or nil
    local npcId = (kind == "Creature" or kind == "Vehicle") and entityId or nil
    return kind, objectId, npcId
end

function GW.GatheringTelemetry.ReadLoot()
    if type(Globals.GetNumLootItems) ~= "function" or type(Globals.GetLootSlotInfo) ~= "function" then
        return nil
    end

    local slotCount = tonumber(safe(Globals.GetNumLootItems)) or 0
    if slotCount <= 0 then
        return nil
    end

    local outputs = {}
    local sourceGuids = {}
    local seenGuids = {}

    for slot = 1, slotCount do
        local ok, texture, itemName, quantity, _, quality = pcall(Globals.GetLootSlotInfo, slot)
        if ok then
            local itemLink = type(Globals.GetLootSlotLink) == "function" and safe(Globals.GetLootSlotLink, slot) or nil
            local itemId = itemIdFromLink(itemLink)
            itemName = cleanString(itemName)
            if itemId or itemName then
                table.insert(outputs, {
                    itemId = itemId,
                    itemLink = cleanString(itemLink),
                    name = itemName,
                    quantity = math.max(tonumber(quantity) or 1, 1),
                    qualityId = tonumber(quality),
                    iconFileDataId = tonumber(texture),
                })
            end
        end

        if type(Globals.GetLootSourceInfo) == "function" then
            local results = { pcall(Globals.GetLootSourceInfo, slot) }
            if results[1] then
                for index = 2, table.maxn(results), 2 do
                    local guid = cleanString(results[index])
                    if guid and not seenGuids[guid] then
                        seenGuids[guid] = true
                        table.insert(sourceGuids, guid)
                    end
                end
            end
        end
    end

    if #outputs == 0 then
        return nil
    end

    local primaryGuid = sourceGuids[1]
    local sourceKind, sourceObjectId, sourceNpcId = sourceIdentity(primaryGuid)
    return {
        slotCount = slotCount,
        outputs = outputs,
        sourceGuids = sourceGuids,
        sourceGuid = primaryGuid,
        sourceKind = sourceKind,
        sourceObjectId = sourceObjectId,
        sourceNpcId = sourceNpcId,
    }
end

local function observationId(snapshot, payload, capturedAt)
    local elapsed = tonumber(safe(Globals.GetTime)) or 0
    local nonce = math.random(0, 2147483647)
    return GW.Store.Fingerprint({
        characterId = snapshot.characterId,
        capturedAt = capturedAt,
        elapsed = elapsed,
        nonce = nonce,
        source = payload.source,
        outputs = payload.outputs,
    })
end

local function publishGathering(pending, discipline, sourceKind)
    pending = type(pending) == "table" and pending or {}
    local snapshot = currentSnapshot()
    if not snapshot or not snapshot.characterId or type(GW.TelemetryEnvelope) ~= "table" then
        return nil
    end

    local loot = GW.GatheringTelemetry.ReadLoot()
    if not loot then
        return nil
    end

    local capturedAt = serverTime()
    local source = {
        kind = sourceKind,
        name = cleanString(pending.sourceName),
        guid = loot.sourceGuid,
        objectId = loot.sourceObjectId,
        npcId = loot.sourceNpcId,
        guidKind = loot.sourceKind,
        guids = #loot.sourceGuids > 1 and loot.sourceGuids or nil,
    }
    local context = type(pending.context) == "table" and pending.context or GW.GatheringTelemetry.CaptureContext(discipline) or {}
    local payload = {
        schemaVersion = 1,
        activity = "harvest",
        discipline = discipline,
        source = source,
        outputs = loot.outputs,
        context = {
            attemptedAt = context.attemptedAt,
            characterLevel = context.characterLevel,
            profession = context.profession,
            modifiers = context.modifiers,
            location = context.location,
            trigger = {
                spellId = tonumber(pending.spellId),
                spellName = cleanString(pending.spellName),
                castGuid = cleanString(pending.castGuid),
            },
        },
        capture = {
            lootSlotCount = loot.slotCount,
            sourceCount = #loot.sourceGuids,
        },
    }
    payload.observationId = observationId(snapshot, payload, capturedAt)

    local envelope = GW.TelemetryEnvelope.Build("gathering_loot", payload, {
        capturedAt = capturedAt,
        characterId = snapshot.characterId,
        realm = snapshot.realm,
        region = snapshot.region,
        gameBuild = snapshot.gameBuild,
    })
    if not envelope then
        return nil
    end

    local streamKey = table.concat({ "gathering_loot", tostring(snapshot.characterId), payload.observationId }, ":")
    local changed = GW.Store.SetTelemetryEvent(streamKey, envelope)
    if not changed then
        return nil
    end

    return {
        streamKey = streamKey,
        envelope = envelope,
        observationId = payload.observationId,
    }
end

function GW.GatheringTelemetry.PublishHerbalism(pending)
    return publishGathering(pending, "herbalism", "herb_node")
end

function GW.GatheringTelemetry.PublishSkinning(pending)
    return publishGathering(pending, "skinning", "creature")
end

function GW.GatheringTelemetry.PublishMining(pending)
    return publishGathering(pending, "mining", "ore_node")
end
