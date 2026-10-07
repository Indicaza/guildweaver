local addonName, GW = ...

GW.name = addonName
GW.version = C_AddOns.GetAddOnMetadata(addonName, "Version") or "dev"

local function normalizeCommand(message)
    local trimmed = (message or ""):match("^%s*(.-)%s*$")
    return string.lower(trimmed)
end

local function professionSummary(snapshot)
    local names = {}

    for _, profession in ipairs(snapshot.professions or {}) do
        if profession.kind == "primary" then
            table.insert(names, profession.name .. " " .. tostring(profession.skillLevel))
        end
    end

    if #names == 0 then
        return "No primary professions"
    end

    return table.concat(names, ", ")
end

local function printTelemetryStatus()
    local status = GW.Store.GetTelemetryStatus()
    GW.Print("Telemetry streams: " .. tostring(status.count) .. "/" .. tostring(status.limit))

    if status.count == 0 then
        GW.Print("No telemetry captured yet.")
        return
    end

    for _, stream in ipairs(status.streams) do
        GW.Print(
            tostring(stream.streamKey)
                .. " | "
                .. tostring(stream.kind)
                .. " | rev "
                .. tostring(stream.revision)
                .. " | "
                .. tostring(stream.eventType or "unknown")
                .. " | schema "
                .. tostring(stream.schemaVersion or "?")
                .. " | captured "
                .. tostring(stream.updatedAt or "?")
        )
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon ~= addonName then
            return
        end

        GW.Store.Initialize()
        GW.Quests.Initialize()
        GW.MainFrame:Initialize()
        GW.Character:Initialize()
        GW.SessionCapture:Initialize()
        return
    end

    if event == "PLAYER_LOGIN" then
        GW.Print("v" .. GW.version .. " loaded. Telemetry capture is automatic; /gw opens Guildweaver.")
    end
end)

SLASH_GUILDWEAVER1 = "/guildweaver"
SLASH_GUILDWEAVER2 = "/gw"

SlashCmdList.GUILDWEAVER = function(message)
    local command = normalizeCommand(message)

    if command == "" then
        GW.MainFrame:Toggle()
        return
    end

    if command == "version" then
        GW.Print("Version " .. GW.version)
        return
    end

    if command == "snapshot" then
        local snapshot = GW.Character.Capture("SLASH_COMMAND")

        if not snapshot then
            GW.Print("Character snapshot unavailable.")
            return
        end

        GW.Print(
            snapshot.name
                .. " - Level "
                .. tostring(snapshot.level)
                .. " "
                .. snapshot.class.name
                .. " - "
                .. professionSummary(snapshot)
        )
        return
    end

    if command == "capture" or command == "sync" then
        if GW.SessionCapture.CaptureAndReload("MANUAL_CHECKPOINT") then
            GW.Print("Telemetry checkpoint captured. Reloading so the bridge can sync it now.")
        else
            GW.Print("Telemetry checkpoint unavailable.")
        end
        return
    end

    if command == "telemetry" then
        printTelemetryStatus()
        return
    end

    if command == "reset" then
        GW.MainFrame:ResetPosition()
        GW.Print("Window position reset.")
        return
    end

    if command == "help" then
        GW.Print("/gw opens Guildweaver. Telemetry capture is automatic at session start, during play, and logout. /gw capture forces a checkpoint and reload for immediate bridge sync. /gw snapshot captures a diagnostic snapshot. /gw telemetry shows captured telemetry streams. /gw version shows the addon version. /gw reset resets the window position.")
        return
    end

    GW.Print("Unknown command. Try /gw help.")
end