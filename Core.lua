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

local function telemetrySummary()
    if GW.CollectorHealthTelemetry and GW.CollectorHealthTelemetry.GetDiagnostics then
        local diagnostics = GW.CollectorHealthTelemetry.GetDiagnostics()
        if diagnostics then
            local observed = diagnostics.observed or {}
            local eventQueue = diagnostics.eventQueue or {}
            local talentApi = observed.talentApi or "no talent API"

            return "streams: "
                .. tostring(observed.stateStreamCount or 0)
                .. " | talents: "
                .. talentApi
                .. " | professions: "
                .. tostring(observed.professionCount or 0)
                .. " | known recipes: "
                .. tostring(observed.knownRecipeCount or 0)
                .. " | events: "
                .. tostring(eventQueue.queued or 0)
                .. "/"
                .. tostring(eventQueue.capacity or 0)
                .. " queued, "
                .. tostring(eventQueue.dropped or 0)
                .. " dropped"
        end
    end

    if not GW.ProfessionTelemetry or not GW.ProfessionTelemetry.GetDiagnostics then
        return "Telemetry diagnostics unavailable."
    end

    local diagnostics = GW.ProfessionTelemetry.GetDiagnostics()
    local specName = diagnostics.specialization and diagnostics.specialization.name or "unknown spec"
    local talentApi = diagnostics.talentApi or "no talent API"
    local eventStats = GW.TelemetryEvents and GW.TelemetryEvents.GetStats and GW.TelemetryEvents.GetStats() or nil
    local queueSummary = ""

    if eventStats then
        queueSummary = " | events: "
            .. tostring(eventStats.queued)
            .. "/"
            .. tostring(eventStats.capacity)
            .. " queued, "
            .. tostring(eventStats.dropped)
            .. " dropped"
    end

    return "Level "
        .. tostring(diagnostics.level or "?")
        .. " | "
        .. specName
        .. " | talents: "
        .. talentApi
        .. " | professions: "
        .. tostring(diagnostics.professionCount or 0)
        .. " | known recipes: "
        .. tostring(diagnostics.knownRecipeCount or 0)
        .. queueSummary
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
        GW.ProfessionTelemetry:Initialize()
        GW.LootTelemetry:Initialize()
        GW.InventoryTelemetry:Initialize()
        GW.AuctionTelemetry:Initialize()
        GW.CollectorHealthTelemetry:Initialize()
        return
    end

    if event == "PLAYER_LOGIN" then
        GW.Print("v" .. GW.version .. " loaded. Type /gw to open.")
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

    if command == "telemetry" then
        GW.Print(telemetrySummary())
        return
    end

    if command == "reset" then
        GW.MainFrame:ResetPosition()
        GW.Print("Window position reset.")
        return
    end

    if command == "help" then
        GW.Print("/gw opens Guildweaver. Sync is automatic on normal play, reload, and logout. /gw snapshot captures the current character. /gw telemetry shows collector coverage and event queue health. /gw version shows the addon version. /gw reset resets the window position.")
        return
    end

    GW.Print("Unknown command. Try /gw help.")
end
