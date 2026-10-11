local _, GW = ...

GW.HerbalismCapture = GW.HerbalismCapture or {}

local Globals = _G or {}
local PENDING_TIMEOUT_SECONDS = 10
local HERBALISM_SPELL_IDS = {
    [2366] = true,
    [2368] = true,
    [3570] = true,
    [11993] = true,
    [28695] = true,
}

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

local function safeText(value)
    if type(Globals.issecretvalue) == "function" then
        local ok, secret = pcall(Globals.issecretvalue, value)
        if ok and secret then
            return nil
        end
    end
    return type(value) == "string" and value ~= "" and value or nil
end

local function spellName(spellId)
    local api = Globals.C_Spell
    if type(api) == "table" and type(api.GetSpellInfo) == "function" then
        local info = safe(api.GetSpellInfo, spellId)
        if type(info) == "table" then
            return safeText(info.name)
        end
    end

    if type(Globals.GetSpellInfo) == "function" then
        return safeText(safe(Globals.GetSpellInfo, spellId))
    end

    return nil
end

local function isHerbalismSpell(spellId)
    spellId = tonumber(spellId)
    if spellId and HERBALISM_SPELL_IDS[spellId] then
        return true
    end

    local name = spellName(spellId)
    if not name then
        return false
    end
    local normalized = string.lower(name)
    return normalized == "herbalism"
        or normalized == "herb gathering"
        or normalized == "gathering herbs"
end

local function elapsed()
    return tonumber(safe(Globals.GetTime)) or 0
end

local function pendingExpired(pending)
    if type(pending) ~= "table" then
        return true
    end
    local armedAt = tonumber(pending.armedAt)
    return armedAt and elapsed() - armedAt > PENDING_TIMEOUT_SECONDS or false
end

local function arm(target, castGuid, spellId)
    if not isHerbalismSpell(spellId) then
        return false
    end

    GW.HerbalismCapture.pending = {
        sourceName = safeText(target),
        castGuid = safeText(castGuid),
        spellId = tonumber(spellId),
        spellName = spellName(spellId),
        armedAt = elapsed(),
        context = GW.GatheringTelemetry and GW.GatheringTelemetry.CaptureContext
            and GW.GatheringTelemetry.CaptureContext("herbalism") or nil,
    }
    return true
end

local function publishPending()
    local pending = GW.HerbalismCapture.pending
    if pendingExpired(pending) then
        GW.HerbalismCapture.pending = nil
        return nil
    end
    if type(pending) ~= "table" or type(GW.GatheringTelemetry) ~= "table"
        or type(GW.GatheringTelemetry.PublishHerbalism) ~= "function" then
        return nil
    end

    local result = GW.GatheringTelemetry.PublishHerbalism(pending)
    if result then
        GW.HerbalismCapture.pending = nil
    end
    return result
end

local function safeRegister(frame, event)
    return pcall(frame.RegisterEvent, frame, event)
end

function GW.HerbalismCapture:Initialize()
    if self.eventFrame or type(Globals.CreateFrame) ~= "function" then
        return
    end

    local frame = Globals.CreateFrame("Frame")
    local events = {
        "PLAYER_LOGIN",
        "TRAIT_CONFIG_UPDATED",
        "TRAIT_CONFIG_LIST_UPDATED",
        "TRAIT_TREE_CURRENCY_INFO_UPDATED",
        "UNIT_SPELLCAST_SENT",
        "UNIT_SPELLCAST_START",
        "UNIT_SPELLCAST_FAILED",
        "UNIT_SPELLCAST_INTERRUPTED",
        "LOOT_READY",
        "LOOT_OPENED",
        "LOOT_CLOSED",
    }
    for _, event in ipairs(events) do
        safeRegister(frame, event)
    end

    frame:SetScript("OnEvent", function(_, event, unit, arg2, arg3, arg4)
        if event == "PLAYER_LOGIN" or string.find(event, "TRAIT_", 1, true) == 1 then
            if GW.GatheringTelemetry and GW.GatheringTelemetry.RefreshEconomicModifiers then
                GW.GatheringTelemetry.RefreshEconomicModifiers()
            end
            return
        end

        if event == "UNIT_SPELLCAST_SENT" then
            if unit == "player" then
                arm(arg2, arg3, arg4)
            end
            return
        end

        if event == "UNIT_SPELLCAST_START" then
            if unit == "player" and not self.pending then
                arm(nil, arg2, arg3)
            end
            return
        end

        if event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED" then
            if unit == "player" and self.pending then
                local castGuid = safeText(arg2)
                if not castGuid or not self.pending.castGuid or castGuid == self.pending.castGuid then
                    self.pending = nil
                end
            end
            return
        end

        if event == "LOOT_READY" or event == "LOOT_OPENED" then
            publishPending()
            return
        end

        if event == "LOOT_CLOSED" then
            self.pending = nil
        end
    end)

    self.eventFrame = frame
end

GW.HerbalismCapture:Initialize()
