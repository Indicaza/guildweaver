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

local function characterKey(name, realm)
    return string.lower((realm or "") .. ":" .. (name or ""))
end

local function collectSpecialization()
    if not C_SpecializationInfo or not C_SpecializationInfo.GetSpecialization then
        return nil
    end

    local index = C_SpecializationInfo.GetSpecialization()
    if not index then
        return nil
    end

    local id, name, _, icon, role = C_SpecializationInfo.GetSpecializationInfo(index)
    if not id and not name then
        return nil
    end

    return {
        index = index,
        id = id,
        name = name or "",
        icon = icon,
        role = role or "",
    }
end

local function collectProfessions()
    local professions = {}
    local indices = { GetProfessions() }

    for position, index in ipairs(indices) do
        if index then
            local name, icon, skillLevel, maxSkillLevel, _, _, skillLineId, skillModifier, _, _, skillLineName = GetProfessionInfo(index)

            if name then
                table.insert(professions, {
                    name = name,
                    kind = PROFESSION_KINDS[position] or "secondary",
                    icon = icon,
                    skillLevel = skillLevel or 0,
                    maxSkillLevel = maxSkillLevel or 0,
                    skillLineId = skillLineId,
                    skillModifier = skillModifier or 0,
                    skillLineName = skillLineName or "",
                })
            end
        end
    end

    return professions
end

local function collectEquipment()
    local equipment = {}

    for _, slotName in ipairs(EQUIPMENT_SLOTS) do
        local slotId = GetInventorySlotInfo(slotName)
        local itemLink = slotId and GetInventoryItemLink("player", slotId) or nil

        if itemLink then
            table.insert(equipment, {
                slot = slotName,
                slotId = slotId,
                itemLink = itemLink,
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

function GW.Character.Capture(reason)
    local name, realm = UnitFullName("player")
    name = name or UnitName("player")
    realm = realm or GetRealmName()

    if not name or name == "" then
        return nil
    end

    local raceName, raceFile, raceId = UnitRace("player")
    local className, classFile, classId = UnitClass("player")
    local capturedAt = GetServerTime()
    local key = characterKey(name, realm)

    local snapshot = {
        schemaVersion = 1,
        capturedAt = capturedAt,
        reason = reason or "manual",
        addonVersion = GW.version,
        characterKey = key,
        guid = UnitGUID("player"),
        name = name,
        realm = realm,
        level = UnitLevel("player"),
        sex = UnitSex("player"),
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
        guild = collectGuild(),
        specialization = collectSpecialization(),
        professions = collectProfessions(),
        equipment = collectEquipment(),
    }

    GW.Store.SetCharacterSnapshot(key, snapshot)
    return snapshot
end

function GW.Character.GetCurrentSnapshot()
    local name, realm = UnitFullName("player")
    name = name or UnitName("player")
    realm = realm or GetRealmName()

    if not name then
        return nil
    end

    return GW.Store.GetCharacterSnapshot(characterKey(name, realm))
end

function GW.Character:Initialize()
    if self.eventFrame then
        return
    end

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("PLAYER_LOGIN")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("PLAYER_LOGOUT")
    frame:RegisterEvent("PLAYER_LEVEL_UP")
    frame:RegisterEvent("PLAYER_GUILD_UPDATE")
    frame:RegisterEvent("GUILD_ROSTER_UPDATE")
    frame:RegisterEvent("SKILL_LINES_CHANGED")
    frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    frame:SetScript("OnEvent", function(_, event, unit)
        if event == "PLAYER_SPECIALIZATION_CHANGED" and unit and unit ~= "player" then
            return
        end

        GW.Character.Capture(event)
    end)

    self.eventFrame = frame

    C_Timer.After(2, function()
        GW.Character.Capture("INITIAL_DELAY")
    end)
end
