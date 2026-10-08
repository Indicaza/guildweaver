local _, GW = ...

GW.CaptureIntegrity = GW.CaptureIntegrity or {}

local TEARDOWN_REASONS = {
    PLAYER_LOGOUT = true,
    RELOAD_FLUSH = true,
}

local TRANSITIONAL_REASONS = {
    PLAYER_LOGIN = true,
    PLAYER_ENTERING_WORLD = true,
    SESSION_START = true,
    POST_RELOAD_RECONCILE = true,
}

local function sectionStatus(reason)
    if TEARDOWN_REASONS[reason] then
        return "unavailable"
    end
    if TRANSITIONAL_REASONS[reason] then
        return "partial"
    end
    return "complete"
end

local function recipeStatus(reason)
    if TEARDOWN_REASONS[reason] then
        return "unavailable"
    end

    local normalized = string.upper(tostring(reason or ""))
    if normalized:find("TRADE_SKILL", 1, true) or normalized:find("RECIPE", 1, true) then
        return "complete"
    end

    return "partial"
end

local function captureMetadata(reason)
    local normalizedReason = tostring(reason or "manual")
    local status = sectionStatus(normalizedReason)
    return {
        integrityVersion = 1,
        reason = normalizedReason,
        sections = {
            identity = "complete",
            stats = status,
            equipment = status,
            talents = status,
            professions = status,
            recipes = recipeStatus(normalizedReason),
            guild = status,
            specialization = status,
        },
    }
end

local originalCapture = GW.Character and GW.Character.Capture

if type(originalCapture) == "function" then
    function GW.Character.Capture(reason, ...)
        local originalSetCharacterSnapshot = GW.Store.SetCharacterSnapshot

        GW.Store.SetCharacterSnapshot = function(characterKey, snapshot)
            if type(snapshot) == "table" then
                snapshot.installationId = GW.Store.GetInstallationId()
                snapshot.capture = captureMetadata(reason)
            end
            return originalSetCharacterSnapshot(characterKey, snapshot)
        end

        local ok, result = pcall(originalCapture, reason, ...)
        GW.Store.SetCharacterSnapshot = originalSetCharacterSnapshot

        if not ok then
            error(result, 0)
        end

        return result
    end
end

GW.CaptureIntegrity.MetadataForReason = captureMetadata
