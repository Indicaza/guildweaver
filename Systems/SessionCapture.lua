local _, GW = ...

GW.SessionCapture = GW.SessionCapture or {}

local INITIAL_CAPTURE_DELAY_SECONDS = 2
local RELOAD_DELAY_SECONDS = 0.35

local function guildTelemetryId(snapshot)
    if not snapshot.guild then
        return nil
    end

    return "guild-" .. GW.Store.Fingerprint({
        name = snapshot.guild.name,
        realm = snapshot.guild.realm,
    })
end

-- Recipe books are published in their own profession_snapshot stream and
-- can be hundreds of recipes per profession; repeating them in every session
-- checkpoint only grew SavedVariables. Checkpoints keep each profession with
-- a recipe count instead. (The collector does not read recipes from
-- checkpoints; they are shown in the telemetry inspector only.)
local function checkpointProfessions(professions)
    if type(professions) ~= "table" then
        return professions
    end
    local result = {}
    for index, profession in ipairs(professions) do
        if type(profession) == "table" and type(profession.recipes) == "table" then
            local copy = {}
            for key, value in pairs(profession) do
                if key ~= "recipes" then
                    copy[key] = value
                end
            end
            copy.recipeCount = #profession.recipes
            result[index] = copy
        else
            result[index] = profession
        end
    end
    return result
end

local function checkpointPayload(snapshot, sessionId, checkpoint, reason)
    local payload = {}
    for key, value in pairs(snapshot) do
        payload[key] = value
    end
    payload.professions = checkpointProfessions(snapshot.professions)
    payload.sessionId = sessionId
    payload.checkpoint = checkpoint
    payload.checkpointReason = reason
    return payload
end

function GW.SessionCapture.CaptureCheckpoint(checkpoint, reason)
    local sessionId = GW.Store.GetCaptureSession()
    if not sessionId then
        sessionId = GW.Store.BeginCaptureSession()
    end

    local snapshot = GW.Character.Capture(reason or ("SESSION_" .. string.upper(checkpoint)))
    if not snapshot then
        return nil
    end

    local capturedAt = GetServerTime()
    local envelope = {
        schemaVersion = 1,
        eventType = "character_session_checkpoint",
        capturedAt = capturedAt,
        gameBuild = snapshot.gameBuild,
        realm = snapshot.realm,
        region = snapshot.region,
        installationId = GW.Store.GetInstallationId(),
        characterId = snapshot.characterId,
        guildId = guildTelemetryId(snapshot),
        sessionId = sessionId,
        checkpoint = checkpoint,
        payload = checkpointPayload(snapshot, sessionId, checkpoint, reason),
    }

    local streamKey = "character_session:" .. tostring(snapshot.characterId) .. ":" .. tostring(sessionId) .. ":" .. tostring(checkpoint)
    GW.Store.SetTelemetryEvent(streamKey, envelope)
    return snapshot
end

-- Explicit, user-requested synchronization (/gw sync): WoW only writes
-- SavedVariables to disk on reload or logout, so the bridge sees new data
-- after this reload. Never called automatically.
function GW.SessionCapture.CaptureAndReload(reason)
    local sessionId = GW.Store.GetCaptureSession()
    if not sessionId then
        GW.Store.BeginCaptureSession()
    end

    local snapshot = GW.SessionCapture.CaptureCheckpoint("manual", reason or "MANUAL_CHECKPOINT")
    if not snapshot then
        return false
    end

    GW.Store.MarkCaptureReloadPending()
    C_Timer.After(RELOAD_DELAY_SECONDS, function()
        ReloadUI()
    end)
    return true
end

function GW.SessionCapture:Initialize()
    if self.eventFrame then
        return
    end

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("PLAYER_LOGIN")
    frame:RegisterEvent("PLAYER_LOGOUT")
    frame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_LOGIN" then
            local _, resumedAfterReload = GW.Store.BeginCaptureSession()

            -- One full reconciliation per login or reload. The session
            -- baseline stays in memory and reaches disk the next time WoW
            -- writes SavedVariables (reload, logout, or /gw sync); there is
            -- no automatic reload.
            if self.startupScheduled then
                return
            end
            self.startupScheduled = true
            C_Timer.After(resumedAfterReload and 0.5 or INITIAL_CAPTURE_DELAY_SECONDS, function()
                if resumedAfterReload then
                    GW.Character.Capture("POST_RELOAD_RECONCILE")
                    return
                end

                GW.SessionCapture.CaptureCheckpoint("start", "SESSION_START")
            end)
            return
        end

        if GW.Store.IsCaptureReloadPending() then
            GW.Character.Capture("RELOAD_FLUSH")
            return
        end

        GW.SessionCapture.CaptureCheckpoint("end", "PLAYER_LOGOUT")
        GW.Store.EndCaptureSession()
    end)

    self.eventFrame = frame
end