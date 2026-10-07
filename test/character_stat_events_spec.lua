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
local handler = nil
local scheduled = {}
local frame = {}

function frame:RegisterEvent(event)
    registered[event] = true
end

function frame:SetScript(script, callback)
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
local addon = {
    Character = {
        Capture = function(reason)
            table.insert(captures, reason)
        end,
    },
}

local chunk = assert(loadfile("Systems/CharacterStatEvents.lua"))
chunk("Guildweaver", addon)

truthy(registered.UNIT_STATS, "unit stats registered")
truthy(registered.UNIT_AURA, "unit aura registered")
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

print("character stat events spec passed")
