local function equal(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function truthy(value, label)
    if not value then
        error((label or "value") .. ": expected truthy value", 2)
    end
end

local Globals = _G
local registered = {}
local unitRegistered = {}
local handler = nil
local scheduled = {}
local frame = {}

frame.RegisterEvent = function(_, event)
    registered[event] = true
end
frame.RegisterUnitEvent = function(_, event, unit)
    unitRegistered[event] = unit
    return true
end

frame.SetScript = function(_, script, callback)
    equal(script, "OnEvent", "event script")
    handler = callback
end

Globals.CreateFrame = function()
    return frame
end
Globals.C_Timer = {
    After = function(delay, callback)
        equal(delay, 0.75, "debounce delay")
        table.insert(scheduled, callback)
    end,
}

local captures = {}
local fullCaptures = 0
local addon = {
    Character = {
        Capture = function()
            fullCaptures = fullCaptures + 1
        end,
        -- Stat and aura changes take the lightweight stats-only path.
        CaptureStats = function(reason)
            table.insert(captures, reason)
        end,
    },
}

local chunk = assert(loadfile("Systems/CharacterStatEvents.lua"))
chunk("Guildweaver", addon)

equal(unitRegistered.UNIT_STATS, "player", "unit stats registered for the player only")
equal(unitRegistered.UNIT_AURA, "player", "unit aura registered for the player only")
equal(registered.UNIT_AURA, nil, "unit aura not registered for every unit")
truthy(registered.COMBAT_RATING_UPDATE, "combat rating registered")
truthy(registered.UPDATE_SHAPESHIFT_FORM, "shapeshift registered")
equal(registered.UNIT_POWER_UPDATE, nil, "power tick spam not registered")
truthy(handler, "event handler installed")

handler(frame, "UNIT_STATS", "party1")
equal(#scheduled, 0, "other unit ignored")

handler(frame, "UNIT_STATS", "player")
equal(#scheduled, 1, "first stat event schedules capture")
handler(frame, "UNIT_AURA", "player")
equal(#scheduled, 1, "second event coalesced")

scheduled[1]()
equal(#captures, 1, "one capture emitted")
equal(captures[1], "UNIT_AURA", "latest coalesced reason used")

handler(frame, "COMBAT_RATING_UPDATE")
equal(#scheduled, 2, "next change schedules again")
scheduled[2]()
equal(#captures, 2, "second capture emitted")
equal(captures[2], "COMBAT_RATING_UPDATE", "global stat event captured")

equal(fullCaptures, 0, "stat events never trigger a full character capture")

-- Changes during combat are folded into one refresh when combat ends.
handler(frame, "PLAYER_REGEN_DISABLED")
handler(frame, "UNIT_AURA", "player")
handler(frame, "UNIT_STATS", "player")
equal(#scheduled, 2, "nothing scheduled in combat")
handler(frame, "PLAYER_REGEN_ENABLED")
equal(#scheduled, 3, "one refresh after combat")
scheduled[3]()
equal(#captures, 3, "post-combat refresh emitted")

print("character stat events spec passed")
