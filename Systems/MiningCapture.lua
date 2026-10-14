local _, GW = ...

GW.MiningCapture = GW.MiningCapture or {}

local Globals = _G or {}
local PENDING_TIMEOUT_SECONDS = 10
local MINING_SPELL_IDS = {
    [2575] = true,
    [2576] = true,
    [3564] = true,
    [10248] = true,
    [29354] = true,
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

local function isMiningSpell(spellId)
    spellId = tonumber(spellId)
    if spellId and MINING_SPELL_IDS[spellId] then
        return true
    end

    local name = spellName(spellId)
    if not name then
        return false
    end
    local normalized = string.lower(name)
    return normalized == "mining"
        or normalized == "mine"
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
    if not isMiningSpell(spellId) then
        return false
    end

    GW.MiningCapture.pending = {
        sourceName = safeText(target),
        castGuid = safeText(castGuid),
        spellId = tonumber(spellId),
        spellName = spellName(spellId),
        armedAt = elapsed(),
        context = GW.GatheringTelemetry and GW.GatheringTelemetry.CaptureContext
            and GW.GatheringTelemetry.CaptureContext("mining") or nil,
    }
    return true
end

local function publishPending()
    local pending = GW.MiningCapture.pending
    if pendingExpired(pending) then
        GW.MiningCapture.pending = nil
        return nil
    end
    if type(pending) ~= "table" or type(GW.GatheringTelemetry) ~= "table"
        or type(GW.GatheringTelemetry.PublishMining) ~= "function" then
        return nil
    end

    local result = GW.GatheringTelemetry.PublishMining(pending)
    if result then
        GW.MiningCapture.lootWindowActive = true
        GW.MiningCapture.pending = nil
    end
    return result
end

local function safeRegister(frame, event)
    return pcall(frame.RegisterEvent, frame, event)
end

function GW.MiningCapture:Initialize()
    if self.eventFrame or type(Globals.CreateFrame) ~= "function" then
        return
    end

    local frame = Globals.CreateFrame("Frame")
    local events = {
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
            self.lootWindowActive = nil
            self.pending = nil
        end
    end)

    self.eventFrame = frame
end

GW.MiningCapture:Initialize()
