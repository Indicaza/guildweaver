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

local function checkpointPayload(snapshot, sessionId, checkpoint, reason)
    local payload = {}
    for key, value in pairs(snapshot) do
        payload[key] = value
    end
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

            C_Timer.After(resumedAfterReload and 0.5 or INITIAL_CAPTURE_DELAY_SECONDS, function()
                if resumedAfterReload then
                    GW.Character.Capture("POST_RELOAD_RECONCILE")
                    return
                end

                local snapshot = GW.SessionCapture.CaptureCheckpoint("start", "SESSION_START")
                if not snapshot then
                    return
                end

                GW.Store.MarkCaptureReloadPending()
                GW.Print("Initial telemetry captured. Reloading once so the bridge can sync the session baseline.")
                C_Timer.After(RELOAD_DELAY_SECONDS, function()
                    ReloadUI()
                end)
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