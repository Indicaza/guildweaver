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

local registered = {}
local onEvent = nil
local timers = {}

CreateFrame = function()
    return {
        RegisterEvent = function(_, event)
            registered[event] = true
        end,
        SetScript = function(_, script, callback)
            if script == "OnEvent" then
                onEvent = callback
            end
        end,
    }
end

C_Timer = {
    After = function(delay, callback)
        table.insert(timers, { delay = delay, callback = callback })
    end,
}

local changing = true
local ready = false
C_TradeSkillUI = {
    IsDataSourceChanging = function()
        return changing
    end,
    IsTradeSkillReady = function()
        return ready
    end,
    GetFilteredRecipeIDs = function()
        return { 2660, 2575, 2538 }
    end,
    GetChildProfessionInfo = function()
        return { professionID = 164, professionName = "Blacksmithing" }
    end,
    GetBaseProfessionInfo = function()
        return { professionID = 164, professionName = "Blacksmithing" }
    end,
    IsRecipeInSkillLine = function(recipeId, skillLineId)
        return skillLineId == 164 and recipeId == 2660
    end,
}

local captures = {}
local GW = {
    Character = {
        CaptureProfessionRecipes = function(reason)
            table.insert(captures, reason)
        end,
    },
}

assert(loadfile("Systems/ProfessionCapture.lua"))("Guildweaver", GW)
truthy(registered.TRADE_SKILL_DATA_SOURCE_CHANGED, "data source changed event registered")
truthy(onEvent, "event handler installed")
truthy(type(C_TradeSkillUI.GetAllRecipeIDs) == "function", "Forever recipe enumeration compatibility installed")

local compatibleRecipeIds = C_TradeSkillUI.GetAllRecipeIDs()
equal(#compatibleRecipeIds, 1, "recipe enumeration limited to active profession")
equal(compatibleRecipeIds[1], 2660, "active profession recipe retained")

onEvent(nil, "TRADE_SKILL_DATA_SOURCE_CHANGED")
equal(#timers, 1, "capture scheduled")
equal(timers[1].delay, 0.25, "initial capture delay")

timers[1].callback()
equal(#captures, 0, "changing data source is not captured")
equal(#timers, 2, "changing data source retries")

changing = false
timers[2].callback()
equal(#captures, 0, "not-ready trade skill is not captured")
equal(#timers, 3, "not-ready trade skill retries")

ready = true
timers[3].callback()
equal(#captures, 1, "ready trade skill captured")
equal(captures[1], "TRADE_SKILL_DATA_SOURCE_CHANGED", "capture reason")

onEvent(nil, "UNRELATED_EVENT")
equal(#timers, 3, "unrelated event ignored")

print("profession capture timing spec passed")
