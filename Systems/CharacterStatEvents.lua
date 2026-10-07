local _, GW = ...

local DEBOUNCE_SECONDS = 0.75

local function safeRegister(frame, event)
    pcall(frame.RegisterEvent, frame, event)
end

local function initialize()
    if not GW.Character or GW.Character.statEventFrame then
        return
    end
    if type(CreateFrame) ~= "function" or type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then
        return
    end

    local frame = CreateFrame("Frame")
    local events = {
        "UNIT_STATS",
        "UNIT_ATTACK_POWER",
        "UNIT_RANGED_ATTACK_POWER",
        "UNIT_ATTACK_SPEED",
        "UNIT_RESISTANCES",
        "UNIT_AURA",
        "COMBAT_RATING_UPDATE",
        "MASTERY_UPDATE",
        "SPEED_UPDATE",
        "PLAYER_DAMAGE_DONE_MODS",
        "UPDATE_SHAPESHIFT_FORM",
        "PLAYER_REGEN_ENABLED",
    }

    for _, event in ipairs(events) do
        safeRegister(frame, event)
    end

    local pending = false
    local latestReason = nil
    frame:SetScript("OnEvent", function(_, event, unit)
        if unit and unit ~= "player" then
            return
        end

        latestReason = event
        if pending then
            return
        end

        pending = true
        C_Timer.After(DEBOUNCE_SECONDS, function()
            pending = false
            local reason = latestReason or "STAT_UPDATE"
            latestReason = nil
            if GW.Character and type(GW.Character.Capture) == "function" then
                GW.Character.Capture(reason)
            end
        end)
    end)

    GW.Character.statEventFrame = frame
end

initialize()
