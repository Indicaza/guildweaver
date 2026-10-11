local _, GW = ...

GW.FishingCapture = GW.FishingCapture or {}

local Globals = _G or {}
local PENDING_TIMEOUT_SECONDS = 45
local FISHING_SPELL_IDS = {
    [7620] = true,
    [131474] = true,
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

local function isFishingSpell(spellId)
    spellId = tonumber(spellId)
    if spellId and FISHING_SPELL_IDS[spellId] then
        return true
    end

    local name = spellName(spellId)
    return name and string.lower(name) == "fishing" or false
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

local function arm(castGuid, spellId)
    if not isFishingSpell(spellId) then
        return false
    end

    GW.FishingCapture.pending = {
        sourceName = "Open Water",
        castGuid = safeText(castGuid),
        spellId = tonumber(spellId),
        spellName = spellName(spellId) or "Fishing",
        armedAt = elapsed(),
        context = GW.GatheringTelemetry and GW.GatheringTelemetry.CaptureContext
            and GW.GatheringTelemetry.CaptureContext("fishing") or nil,
        attemptPublished = false,
    }
    return true
end

local function matchesPending(castGuid, spellId)
    local pending = GW.FishingCapture.pending
    if type(pending) ~= "table" then
        return false
    end

    castGuid = safeText(castGuid)
    spellId = tonumber(spellId)
    if castGuid and pending.castGuid and castGuid ~= pending.castGuid then
        return false
    end
    if spellId and pending.spellId and spellId ~= pending.spellId then
        return false
    end
    return true
end

local function publishAttempt()
    local pending = GW.FishingCapture.pending
    if pendingExpired(pending) then
        GW.FishingCapture.pending = nil
        return nil
    end
    if type(pending) ~= "table" or pending.attemptPublished
        or type(GW.GatheringTelemetry) ~= "table"
        or type(GW.GatheringTelemetry.PublishFishingAttempt) ~= "function" then
        return nil
    end

    local result = GW.GatheringTelemetry.PublishFishingAttempt(pending)
    if result then
        pending.attemptPublished = true
        pending.attemptObservationId = result.observationId
    end
    return result
end

local function fishingLootWindow()
    if type(Globals.IsFishingLoot) ~= "function" then
        return true
    end
    return safe(Globals.IsFishingLoot) == true
end

local function publishCatch()
    local pending = GW.FishingCapture.pending
    if pendingExpired(pending) then
        GW.FishingCapture.pending = nil
        return nil
    end
    if type(pending) ~= "table" or not pending.attemptPublished or not fishingLootWindow()
        or type(GW.GatheringTelemetry) ~= "table"
        or type(GW.GatheringTelemetry.PublishFishing) ~= "function" then
        return nil
    end

    local result = GW.GatheringTelemetry.PublishFishing(pending)
    if result then
        GW.FishingCapture.pending = nil
    end
    return result
end

local function safeRegister(frame, event)
    return pcall(frame.RegisterEvent, frame, event)
end

function GW.FishingCapture:Initialize()
    if self.eventFrame or type(Globals.CreateFrame) ~= "function" then
        return
    end

    local frame = Globals.CreateFrame("Frame")
    local events = {
        "UNIT_SPELLCAST_SENT",
        "UNIT_SPELLCAST_SUCCEEDED",
        "UNIT_SPELLCAST_FAILED",
        "UNIT_SPELLCAST_INTERRUPTED",
        "LOOT_READY",
        "LOOT_OPENED",
    }
    for _, event in ipairs(events) do
        safeRegister(frame, event)
    end

    frame:SetScript("OnEvent", function(_, event, unit, arg2, arg3, arg4)
        if event == "UNIT_SPELLCAST_SENT" then
            if unit == "player" and isFishingSpell(arg4) then
                arm(arg3, arg4)
            end
            return
        end

        if event == "UNIT_SPELLCAST_SUCCEEDED" then
            if unit ~= "player" or not isFishingSpell(arg3) then
                return
            end
            if not matchesPending(arg2, arg3) then
                arm(arg2, arg3)
            end
            publishAttempt()
            return
        end

        if event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED" then
            if unit == "player" and matchesPending(arg2, arg3) then
                self.pending = nil
            end
            return
        end

        if event == "LOOT_READY" or event == "LOOT_OPENED" then
            publishCatch()
        end
    end)

    self.eventFrame = frame
end

GW.FishingCapture:Initialize()
