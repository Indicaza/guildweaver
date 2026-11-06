local _, GW = ...

GW.FishingCapture = GW.FishingCapture or {}

local Globals = _G or {}
local PENDING_TIMEOUT_SECONDS = 45
-- Fishing ranks on Classic-era clients (Apprentice to Artisan) and the
-- modern single spell. Other locales fall back to the spell name.
local FISHING_SPELL_IDS = {
    [7620] = true,
    [7731] = true,
    [7732] = true,
    [18248] = true,
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

-- Session counters for /gw fishing. In memory only.
local function stats()
    local capture = GW.FishingCapture
    capture.stats = capture.stats or { casts = 0, catches = 0, catchesWithoutCast = 0, poolCatches = 0 }
    return capture.stats
end

function GW.FishingCapture.Stats()
    return stats()
end

local function applyPoolCandidate(pending, probeNow)
    if type(pending) ~= "table" then
        return
    end

    local probe = GW.FishingPoolProbe
    if type(probe) ~= "table" then
        return
    end

    if probeNow and type(probe.ProbeNow) == "function" then
        probe:ProbeNow()
    end

    local candidate = type(probe.CandidateForCast) == "function"
        and probe:CandidateForCast(pending.armedAt) or nil
    if type(candidate) == "table" and candidate.looksLikePool then
        pending.sourceName = safeText(candidate.name) or "Fishing Pool"
        pending.sourceKind = "fishing_pool"
        pending.sourceGuid = safeText(candidate.guid)
        pending.sourceObjectId = tonumber(candidate.objectId)
        pending.sourceGuidKind = pending.sourceGuid and "GameObject" or nil
        pending.sourceDetection = safeText(candidate.detection) or "world_cursor_tooltip"
        pending.sourceConfidence = safeText(candidate.confidence) or "strong"
        pending.sourceProbe = candidate
        return
    end

    if pending.sourceKind ~= "fishing_pool" then
        pending.sourceName = "Open Water"
        pending.sourceKind = "fishing_water"
        pending.sourceDetection = "open_water_fallback"
        pending.sourceConfidence = "fallback"
        pending.sourceProbe = type(probe.GetLastProbe) == "function" and probe:GetLastProbe(8) or nil
    end
end

local function resetProbe()
    local probe = GW.FishingPoolProbe
    if type(probe) == "table" and type(probe.Reset) == "function" then
        probe:Reset()
    end
end

local function newPending(castGuid, spellId)
    return {
        sourceName = "Open Water",
        sourceKind = "fishing_water",
        sourceDetection = "open_water_fallback",
        sourceConfidence = "fallback",
        castGuid = safeText(castGuid),
        spellId = tonumber(spellId),
        spellName = spellId and spellName(spellId) or "Fishing",
        armedAt = elapsed(),
        context = GW.GatheringTelemetry and GW.GatheringTelemetry.CaptureContext
            and GW.GatheringTelemetry.CaptureContext("fishing") or nil,
        attemptPublished = false,
    }
end

local function arm(castGuid, spellId)
    if not isFishingSpell(spellId) then
        return false
    end

    local pending = newPending(castGuid, spellId)
    GW.FishingCapture.pending = pending
    -- A new cast leads to a new loot window.
    GW.FishingCapture.catchPublished = false
    applyPoolCandidate(pending, true)
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
        resetProbe()
        return nil
    end
    if type(pending) ~= "table" or pending.attemptPublished
        or type(GW.GatheringTelemetry) ~= "table"
        or type(GW.GatheringTelemetry.PublishFishingAttempt) ~= "function" then
        return nil
    end

    applyPoolCandidate(pending, true)
    local result = GW.GatheringTelemetry.PublishFishingAttempt(pending)
    if result then
        pending.attemptPublished = true
        pending.attemptObservationId = result.observationId
        stats().casts = stats().casts + 1
    end
    return result
end

-- true or false when the client can tell, nil when it cannot.
local function fishingLootState()
    if type(Globals.IsFishingLoot) ~= "function" then
        return nil
    end
    return safe(Globals.IsFishingLoot) == true
end

local function rememberCatch(result, pending)
    local counters = stats()
    counters.catches = counters.catches + 1
    if pending.castObserved == false then
        counters.catchesWithoutCast = counters.catchesWithoutCast + 1
    end
    local payload = result and result.envelope and result.envelope.payload or nil
    local source = payload and payload.source or {}
    if source.kind == "fishing_pool" then
        counters.poolCatches = counters.poolCatches + 1
    end
    local location = payload and payload.context and payload.context.location or {}
    local items = 0
    for _, output in ipairs(payload and payload.outputs or {}) do
        items = items + (tonumber(output.quantity) or 1)
    end
    counters.last = {
        sourceName = source.name,
        sourceKind = source.kind,
        detection = payload and payload.capture and payload.capture.sourceDetection or nil,
        zone = location.zone,
        subzone = location.subzone,
        mapId = location.mapId,
        x = location.x,
        y = location.y,
        items = items,
    }
end

-- A catch is published when a fishing loot window opens. The cast that led
-- to it is normally known, but the channel can end or be interrupted before
-- the loot window, and a cast can start before a /reload. When the client
-- confirms fishing loot, the catch is still recorded, with the context read
-- at loot time. One catch is published per loot window.
local function publishCatch()
    local capture = GW.FishingCapture
    if capture.catchPublished then
        return nil
    end
    if type(GW.GatheringTelemetry) ~= "table" or type(GW.GatheringTelemetry.PublishFishing) ~= "function" then
        return nil
    end

    local pending = capture.pending
    if pendingExpired(pending) then
        capture.pending = nil
        pending = nil
    end

    local fishingLoot = fishingLootState()
    if fishingLoot == false then
        return nil
    end
    if not (pending and pending.attemptPublished) and fishingLoot ~= true then
        -- Without an accepted cast, only the client can confirm a catch.
        return nil
    end

    if not pending then
        pending = newPending(nil, nil)
        pending.castObserved = false
    end

    applyPoolCandidate(pending, false)
    local result = GW.GatheringTelemetry.PublishFishing(pending)
    if result then
        capture.pending = nil
        capture.catchPublished = true
        rememberCatch(result, pending)
        resetProbe()
    end
    return result
end

-- Spellcast events fire for every unit in range; where the client supports
-- it they are registered for the player only. The handler still checks the
-- unit for clients without RegisterUnitEvent.
local function safeRegister(frame, event)
    if string.find(event, "UNIT_", 1, true) == 1 and type(frame.RegisterUnitEvent) == "function" then
        local ok, registered = pcall(frame.RegisterUnitEvent, frame, event, "player")
        if ok and registered ~= false then
            return true
        end
    end
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
        "LOOT_CLOSED",
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
                resetProbe()
            end
            return
        end

        if event == "LOOT_READY" or event == "LOOT_OPENED" then
            publishCatch()
            return
        end

        if event == "LOOT_CLOSED" then
            self.catchPublished = false
        end
    end)

    self.eventFrame = frame
end

GW.FishingCapture:Initialize()
