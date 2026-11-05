local _, GW = ...

-- Stat, aura and combat-rating changes only affect the character's stats, so
-- they refresh and publish just the stats domain (GW.Character.CaptureStats)
-- instead of a full character capture with talents, professions and
-- equipment tooltips.
--
-- Unit events are registered for the player only where the client supports
-- RegisterUnitEvent, so raid and nameplate auras never reach Lua; the unit
-- check below remains for clients without it. A burst of events shares one
-- debounced refresh. Buffs come and go constantly in combat, so changes seen
-- in combat are folded into a single refresh when combat ends.

local Globals = _G or {}

local DEBOUNCE_SECONDS = 0.75

local UNIT_EVENTS = {
    "UNIT_STATS",
    "UNIT_ATTACK_POWER",
    "UNIT_RANGED_ATTACK_POWER",
    "UNIT_ATTACK_SPEED",
    "UNIT_RESISTANCES",
    "UNIT_AURA",
}

local EVENTS = {
    "COMBAT_RATING_UPDATE",
    "MASTERY_UPDATE",
    "SPEED_UPDATE",
    "PLAYER_DAMAGE_DONE_MODS",
    "UPDATE_SHAPESHIFT_FORM",
    "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED",
}

local function safeRegister(frame, event)
    return pcall(frame.RegisterEvent, frame, event)
end

-- Registers a unit event for the player only. Returns true when the client
-- filtered it (RegisterUnitEvent), false when the handler must filter.
local function registerPlayerEvent(frame, event)
    if type(frame.RegisterUnitEvent) == "function" then
        local ok, registered = pcall(frame.RegisterUnitEvent, frame, event, "player")
        if ok and registered ~= false then
            return true
        end
    end
    safeRegister(frame, event)
    return false
end

GW.CharacterStatEvents = GW.CharacterStatEvents or {}

local function combatLocked()
    local lockdown = Globals.InCombatLockdown
    if type(lockdown) ~= "function" then
        return false
    end
    local ok, value = pcall(lockdown)
    return ok and value == true
end

local function initialize()
    if not GW.Character or GW.Character.statEventFrame then
        return
    end
    if type(CreateFrame) ~= "function" or type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then
        return
    end

    local frame = CreateFrame("Frame")
    local unitFiltered = {}
    for _, event in ipairs(UNIT_EVENTS) do
        unitFiltered[event] = registerPlayerEvent(frame, event)
    end
    for _, event in ipairs(EVENTS) do
        safeRegister(frame, event)
    end

    local state = GW.CharacterStatEvents
    state.unitFiltered = unitFiltered
    state.pending = false
    state.dirty = false
    state.inCombat = combatLocked()
    local latestReason = nil

    local function capture()
        state.pending = false
        state.dirty = false
        local reason = latestReason or "STAT_UPDATE"
        latestReason = nil
        local character = GW.Character
        if character and type(character.CaptureStats) == "function" then
            character.CaptureStats(reason)
        elseif character and type(character.Capture) == "function" then
            character.Capture(reason)
        end
    end

    local function schedule()
        if state.pending then
            return
        end
        state.pending = true
        C_Timer.After(DEBOUNCE_SECONDS, function()
            if state.inCombat then
                -- Combat started while waiting: finish after combat.
                state.pending = false
                state.dirty = true
                return
            end
            capture()
        end)
    end

    frame:SetScript("OnEvent", function(_, event, unit)
        if unit and unit ~= "player" then
            return
        end

        if event == "PLAYER_REGEN_DISABLED" then
            state.inCombat = true
            return
        end
        if event == "PLAYER_REGEN_ENABLED" then
            state.inCombat = false
            -- Leaving combat changes regeneration stats as well; refresh once.
            latestReason = latestReason or event
            schedule()
            return
        end

        latestReason = event
        if state.inCombat then
            state.dirty = true
            return
        end
        schedule()
    end)

    GW.Character.statEventFrame = frame
end

initialize()
