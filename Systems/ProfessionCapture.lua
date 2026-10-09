local _, GW = ...

GW.ProfessionCapture = GW.ProfessionCapture or {}

local RETRY_DELAY_SECONDS = 0.25
local MAX_CAPTURE_ATTEMPTS = 20

local function activeProfessionSkillLines(api)
    local skillLines = {}
    local seen = {}

    local function add(infoFunction)
        if type(infoFunction) ~= "function" then
            return
        end
        local ok, info = pcall(infoFunction)
        local skillLineId = ok and type(info) == "table" and tonumber(info.professionID) or nil
        if skillLineId and not seen[skillLineId] then
            seen[skillLineId] = true
            table.insert(skillLines, skillLineId)
        end
    end

    add(api.GetChildProfessionInfo)
    add(api.GetBaseProfessionInfo)
    return skillLines
end

local function installRecipeEnumerationCompatibility()
    local api = C_TradeSkillUI
    if type(api) ~= "table"
        or type(api.GetAllRecipeIDs) == "function"
        or type(api.GetFilteredRecipeIDs) ~= "function" then
        return
    end

    api.GetAllRecipeIDs = function()
        local ok, recipeIds = pcall(api.GetFilteredRecipeIDs)
        if not ok or type(recipeIds) ~= "table" then
            return {}
        end

        if type(api.IsRecipeInSkillLine) ~= "function" then
            return recipeIds
        end

        local skillLines = activeProfessionSkillLines(api)
        if #skillLines == 0 then
            return {}
        end

        local filtered = {}
        for _, recipeId in ipairs(recipeIds) do
            for _, skillLineId in ipairs(skillLines) do
                local matchOk, matches = pcall(api.IsRecipeInSkillLine, recipeId, skillLineId)
                if matchOk and matches == true then
                    table.insert(filtered, recipeId)
                    break
                end
            end
        end
        return filtered
    end
end

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

    installRecipeEnumerationCompatibility()

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
