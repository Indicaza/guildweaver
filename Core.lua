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

local function printPerf()
    local perf = GW.Perf
    if not perf or type(perf.Report) ~= "function" then
        GW.Print("Performance counters unavailable.")
        return
    end
    local extra = {}
    local queue = GW.WorkQueue
    if queue and type(queue.Stats) == "function" then
        local stats = queue.Stats()
        table.insert(extra, string.format(
            "work queue: %d queued (max %d), %d done, %d cancelled, %d dropped, %d ms/frame budget, combat paused %s",
            queue.Size(), stats.maxDepth, stats.completed, stats.cancelled, stats.dropped,
            queue.FRAME_BUDGET_MS, tostring(queue.InCombat())))
    end
    for _, line in ipairs(perf.Report(extra)) do
        GW.Print(line)
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
        GW.Store.ConfirmLiveClient()
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

    if command == "farm start" then
        GW.Print(GW.FarmingSessions.Start() and "Farming timer started. /gw farm stop ends the run. Travel and waiting count."
            or "Timer already running, or character data is not ready.")
        return
    end

    if command == "farm stop" then
        local result = GW.FarmingSessions.Stop()
        GW.Print(result and "Farming run saved. Use /gw sync to send it now." or "No farming timer is running.")
        return
    end

    if command == "farm" then
        local context = GW.FarmingSessions.Context()
        GW.Print(context and "Farming run: " .. context.mode .. ". /gw farm stop ends it."
            or "Automatic farming estimates are enabled. /gw farm start begins a measured run.")
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

    if command == "perf" then
        printPerf()
        return
    end

    if command == "perf reset" then
        if GW.Perf and GW.Perf.Reset then
            GW.Perf.Reset()
        end
        GW.Print("Performance counters reset.")
        return
    end

    if command == "capture" or command == "sync" then
        if GW.SessionCapture.CaptureAndReload("MANUAL_CHECKPOINT") then
            GW.Print("Telemetry checkpoint captured. Reloading so WoW writes it to disk for the bridge now.")
        else
            GW.Print("Telemetry checkpoint unavailable.")
        end
        return
    end

    if command == "telemetry" then
        printTelemetryStatus()
        return
    end

    if command == "inventory" then
        local result = GW.InventoryCapture and GW.InventoryCapture.Publish("SLASH_COMMAND")
        local payload = result and result.envelope and result.envelope.payload
        if not payload then
            GW.Print("Inventory unavailable.")
            return
        end
        local copper = payload.money and payload.money.copper or 0
        GW.Print(
            "Inventory: "
                .. tostring(payload.slotCount - payload.freeSlots)
                .. "/"
                .. tostring(payload.slotCount)
                .. " slots, "
                .. tostring(#payload.items)
                .. " distinct items, "
                .. string.format("%dg %ds %dc", math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100)
                .. " | rev "
                .. tostring(result.revision)
                .. (result.changed and " (new)" or " (unchanged)")
        )
        return
    end

    if command == "reset" then
        GW.MainFrame:ResetPosition()
        GW.Print("Window position reset.")
        return
    end

    if command == "help" then
        GW.Print("/gw farm start and /gw farm stop measure a farming run. /gw farm shows its status.")
        GW.Print("/gw opens Guildweaver. Telemetry capture is automatic at session start, during play, and logout. WoW writes it to disk on /reload and logout, when the bridge syncs it. /gw sync (or /gw capture) forces a checkpoint and a reload to sync now. /gw snapshot captures a diagnostic snapshot. /gw telemetry shows captured telemetry streams. /gw inventory rescans your bags and shows the inventory revision. /gw perf shows capture timings and counts (/gw perf reset clears them). /gw version shows the addon version. /gw reset resets the window position.")
        return
    end

    GW.Print("Unknown command. Try /gw help.")
end
