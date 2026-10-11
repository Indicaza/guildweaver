local _, GW = ...

local Globals = _G or {}
local SKINNING_SKILL_LINE_ID = 393

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

local function currentSnapshot()
    local character = GW.Character
    if type(character) ~= "table" or type(character.GetCurrentSnapshot) ~= "function" then
        return nil
    end
    local snapshot = safe(character.GetCurrentSnapshot)
    return type(snapshot) == "table" and snapshot or nil
end

local function skinningProfession()
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
        local skillLineId = tonumber(profession.skillLineId or profession.id)
        local name = cleanString(profession.name)
        if skillLineId == SKINNING_SKILL_LINE_ID or (name and string.lower(name) == "skinning") then
            return {
                skillLineId = skillLineId,
                name = name,
                skillLevel = tonumber(profession.skillLevel),
                maxSkillLevel = tonumber(profession.maxSkillLevel),
                skillModifier = tonumber(profession.skillModifier) or 0,
                specialization = type(profession.specialization) == "table" and profession.specialization or nil,
            }
        end
    end

    return nil
end

local function npcIdFromGuid(guid)
    guid = cleanString(guid)
    if not guid then
        return nil
    end

    local parts = {}
    for part in string.gmatch(guid, "[^%-]+") do
        table.insert(parts, part)
    end
    local kind = parts[1]
    if kind ~= "Creature" and kind ~= "Vehicle" then
        return nil
    end
    return tonumber(parts[6])
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

function GW.GatheringTelemetry.PublishSkinning(pending)
    pending = type(pending) == "table" and pending or {}
    local snapshot = currentSnapshot()
    if not snapshot or not snapshot.characterId or type(GW.TelemetryEnvelope) ~= "table" then
        return nil
    end

    local loot = GW.GatheringTelemetry.ReadLoot()
    if not loot then
        return nil
    end

    local capturedAt = tonumber(safe(Globals.GetServerTime)) or 0
    local context = type(pending.context) == "table" and pending.context
        or GW.GatheringTelemetry.CaptureContext("skinning") or {}
    local payload = {
        schemaVersion = 1,
        activity = "harvest",
        discipline = "skinning",
        source = {
            kind = "creature",
            name = cleanString(pending.sourceName),
            guid = loot.sourceGuid,
            npcId = npcIdFromGuid(loot.sourceGuid),
            guidKind = loot.sourceKind,
            guids = #loot.sourceGuids > 1 and loot.sourceGuids or nil,
        },
        outputs = loot.outputs,
        context = {
            attemptedAt = context.attemptedAt,
            characterLevel = context.characterLevel,
            profession = skinningProfession(),
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
