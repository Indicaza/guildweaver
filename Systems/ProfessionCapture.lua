local _, GW = ...

GW.ProfessionCapture = GW.ProfessionCapture or {}

local RETRY_DELAY_SECONDS = 0.25
local MAX_CAPTURE_ATTEMPTS = 20

local function tradeSkillReady()
    local api = C_TradeSkillUI
    if type(api) ~= "table" then
        return true
    end

    if type(api.IsDataSourceChanging) == "function" then
        local ok, changing = pcall(api.IsDataSourceChanging)
        if not ok or changing == true then
            return false
        end
    end

    if type(api.IsTradeSkillReady) == "function" then
        local ok, ready = pcall(api.IsTradeSkillReady)
        if not ok or ready == false then
            return false
        end
    end

    return true
end

function GW.ProfessionCapture:Schedule(reason)
    self.captureGeneration = (self.captureGeneration or 0) + 1
    local generation = self.captureGeneration

    local function attempt(attemptNumber)
        C_Timer.After(RETRY_DELAY_SECONDS, function()
            if self.captureGeneration ~= generation then
                return
            end

            if tradeSkillReady() then
                GW.Character.CaptureProfessionRecipes(reason)
                return
            end

            if attemptNumber < MAX_CAPTURE_ATTEMPTS then
                attempt(attemptNumber + 1)
            end
        end)
    end

    attempt(1)
end

function GW.ProfessionCapture:Initialize()
    if self.eventFrame then
        return
    end

    local frame = CreateFrame("Frame")
    local registered = pcall(frame.RegisterEvent, frame, "TRADE_SKILL_DATA_SOURCE_CHANGED")
    if not registered then
        return
    end

    frame:SetScript("OnEvent", function(_, event)
        if event == "TRADE_SKILL_DATA_SOURCE_CHANGED" then
            self:Schedule(event)
        end
    end)

    self.eventFrame = frame
end

GW.ProfessionCapture:Initialize()
