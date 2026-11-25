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
            "work queue: %d queued (max %d), %d done, %d cancelled, %d dropped, %s ms/frame budget, in combat %s",
            queue.Size(), stats.maxDepth, stats.completed, stats.cancelled, stats.dropped,
            tostring(queue.FRAME_BUDGET_MS), tostring(queue.InCombat())))
        table.insert(extra, string.format(
            "work queue time: %d frames, %.1f ms total, worst frame %.2f ms, worst step %.2f ms (%s), %d over 2x budget, %d backoffs, %d combat waits",
            stats.ticks or 0, stats.totalMs or 0, stats.worstTick or 0, stats.worstStep or 0,
            tostring(stats.worstStepCategory or "-"), stats.overBudget or 0, stats.backoffs or 0, stats.combatWaits or 0))
        if type(queue.Depths) == "function" and queue.Size() > 0 then
            local parts = {}
            for name, depth in pairs(queue.Depths()) do
                table.insert(parts, name .. "=" .. depth)
            end
            table.sort(parts)
            table.insert(extra, "queued now: " .. table.concat(parts, ", "))
        end
    end
    for _, line in ipairs(perf.Report(extra)) do
        GW.Print(line)
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon ~= addonName then
            return
        end

        GW.Store.Initialize()
        GW.Quests.Initialize()
        GW.LootSync.Initialize()
        GW.MainFrame:Initialize()
        GW.MinimapButton:Initialize()
        GW.Character:Initialize()
        GW.CharacterQuests.Initialize()
        GW.SessionCapture:Initialize()
        return
    end

    if event == "PLAYER_LOGIN" then
        GW.Store.ConfirmLiveClient()
        GW.Print("v" .. GW.version .. " loaded. Click the minimap button or type /gw to open Guildweaver.")
    elseif event == "PLAYER_ENTERING_WORLD" then
        if not GW.Store.RetryLiveClient() then
            local _, reloading = ...
            local initialLogin = ...
            if initialLogin or reloading then
                for _, delay in ipairs({ 1, 3, 10 }) do
                    C_Timer.After(delay, function()
                        GW.Store.RetryLiveClient()
                    end)
                end
            end
        end
    end
end)

-- Credits and licences (the add-on's Appropriate Legal Notices).
local function printCredits()
    GW.Print("Guildweaver credits and licences:")
    GW.Print("  Game data from World of Warcraft: Forever (Blizzard Entertainment), via Holdfast.")
    local guide = GW.DungeonGuide
    local credit = guide and guide.ForeverDbCredit and guide.ForeverDbCredit()
    if credit then
        GW.Print("  " .. credit .. ": drop rates and item facts in Data/ForeverDB.generated.lua,")
        GW.Print("    GPL-3.0 with ForeverDB.net's attribution term (Licenses/ForeverDB-LICENSE.txt, Licenses/ForeverDB-COPYING.txt).")
    end
    GW.Print("  Classic reference data: AzerothCore (GPL-2.0), DungeonPlanner. See Licenses/README.md.")
end
GW.PrintCredits = printCredits

local function printFishing()
    local stats = GW.FishingCapture and GW.FishingCapture.Stats and GW.FishingCapture.Stats() or nil
    if not stats or (stats.casts == 0 and stats.catches == 0) then
        GW.Print("No fishing recorded this session. Casts are recorded when they start, catches when the loot window opens.")
        return
    end
    GW.Print(string.format("Fishing this session: %d casts, %d catches (%d from pools, %d without a seen cast).",
        stats.casts, stats.catches, stats.poolCatches, stats.catchesWithoutCast))
    local last = stats.last
    if last then
        local place = tostring(last.zone or "unknown zone")
        if last.subzone then
            place = place .. " - " .. tostring(last.subzone)
        end
        if last.x and last.y then
            place = place .. string.format(" (%.1f, %.1f)", last.x * 100, last.y * 100)
        end
        GW.Print(string.format("Last catch: %s, %s, %d item(s), detected by %s.",
            tostring(last.sourceName or "unknown source"), place, last.items or 0, tostring(last.detection or "unknown")))
    end
    GW.Print("Recorded catches reach the website after /reload or logout. /gw sync sends them now.")
end

SLASH_GUILDWEAVER1 = "/guildweaver"
SLASH_GUILDWEAVER2 = "/gw"

SlashCmdList.GUILDWEAVER = function(message)
    local command = normalizeCommand(message)

    if command == "" then
        GW.MainFrame:Toggle()
        return
    end

    if command == "settings" or command == "options" or command == "config" then
        GW.MainFrame:Open("settings")
        return
    end

    if command == "minimap" then
        local hidden = not GW.UiPrefs.MinimapHidden()
        GW.UiPrefs.SetMinimapHidden(hidden)
        GW.Print(hidden and "Minimap button hidden. /gw minimap shows it again." or "Minimap button shown.")
        return
    end

    if command == "credits" or command == "licenses" or command == "licences" then
        printCredits()
        return
    end

    if command == "version" then
        GW.Store.RetryLiveClient()
        GW.Print("Version " .. GW.version)
        local database = GW.Store.GetDatabase()
        local validation = database.meta and database.meta.releaseValidation or {}
        GW.Print("Release: " .. tostring(database.gameRelease or "unconfirmed")
            .. " | " .. tostring(validation.reason or "unknown")
            .. " | realm: " .. tostring(validation.realm)
            .. " | interface: " .. tostring(validation.interface)
            .. " | test build: " .. tostring(validation.testBuild))
        return
    end

    if command == "guide" then
        GW.DungeonGuideUI.Show()
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

    if command == "dungeon" or command:find("^dungeon ") then
        local action, rest = command:match("^dungeon%s*(%S*)%s*(.-)$")
        local sessions, hud = GW.DungeonSessions, GW.DungeonHud
        if action == "split" then
            local label = message:match("^%s*%S+%s+%S+%s+(.-)%s*$")
            local entry = sessions.Split(label ~= "" and label or nil)
            GW.Print(entry and ("Split recorded: " .. tostring(entry.name) .. " at " .. hud.FormatDuration(entry.at) .. ".")
                or "No dungeon run is open.")
        elseif action == "new" then
            GW.Print(sessions.NewRun() and "New dungeon run started." or "Enter the new instance first.")
        elseif action == "finish" then
            GW.Print(sessions.Finish() and "Dungeon run saved as completed. It reaches the website after /reload or logout."
                or "No dungeon run is open.")
        elseif action == "start" or action == "stop" or action == "timer" then
            local state = sessions.TimerState()
            if not state then
                GW.Print("No dungeon run is open. Runs start when you enter a dungeon or raid.")
            elseif action == "timer" then
                GW.Print("Dungeon timer " .. tostring(sessions.ToggleTimer()) .. ", " .. hud.ClockText(sessions.Current()) .. ".")
            elseif action == "start" then
                GW.Print(sessions.StartTimer() and "Dungeon timer started. It also starts by itself on your first pull."
                    or "The dungeon timer is already running.")
            else
                GW.Print(sessions.StopTimer() and ("Dungeon timer stopped at " .. hud.ClockText(sessions.Current()) .. ". /gw dungeon start resumes it; the run stays open.")
                    or "The dungeon timer is not running.")
            end
        elseif action == "hud" then
            local enabled = hud:SetEnabled(rest == "on" or (rest ~= "off" and not hud:IsEnabled()))
            GW.Print(enabled and "Dungeon HUD on. It shows inside dungeons and raids." or "Dungeon HUD off. Runs are still recorded.")
            GW.MainFrame:RefreshDungeon()
        elseif action == "details" then
            hud:ToggleExpanded()
        elseif action == "mode" then
            local mode = (rest == "min" or rest == "minimized") and "minimized" or (rest == "full" or rest == "expanded") and "expanded"
                or rest == "compact" and "compact" or nil
            local applied = mode and hud:SetMode(mode) or hud:CycleMode()
            GW.Print("Dungeon HUD: " .. tostring(applied) .. ".")
        elseif action == "pb" then
            local run = sessions.Current()
            if run and run.pb then
                GW.Print("Personal best here: " .. hud.FormatDuration(run.pb.seconds or run.pb.durationSeconds) .. (run.pace and (", now " .. hud.FormatPace(run.pace, false)) or "") .. ".")
            else
                GW.Print("No personal best for this dungeon and difficulty yet. A clear counts when every boss kill is reported.")
            end
        elseif action == "reset" then
            hud:ResetPosition()
            GW.Print("Dungeon HUD position reset.")
        elseif action == "bosses" then
            for _, line in ipairs(sessions.Diagnostics()) do GW.Print(line) end
        elseif action == "quests" then
            -- What the client gave for this character's quests (APIs, coverage).
            local quests = GW.CharacterQuests
            if quests and quests.Capture then quests.Capture("command", true) end
            for _, line in ipairs(quests and quests.Report and quests.Report() or { "Quest state not loaded." }) do GW.Print(line) end
        elseif action == "catalog" then
            -- For atlas maintainers: unknown instances entered, what the client says of WoW Forever's dungeons.
            local catalog = GW.DungeonCatalog
            for _, line in ipairs(catalog and catalog.Report and catalog.Report() or { "Dungeon catalog not loaded." }) do GW.Print(line) end
        else
            local run = sessions.Current()
            if run then
                for _, line in ipairs(hud.Lines(run, true)) do GW.Print(line) end
            else
                GW.Print("No dungeon run is open. Runs start when you enter a dungeon or raid.")
            end
            GW.Print("/gw dungeon start|stop (the timer also starts on your first pull), /gw dungeon split [name], /gw dungeon finish, /gw dungeon hud on|off, /gw dungeon mode [min|compact|full], /gw dungeon pb, /gw dungeon reset, /gw dungeon bosses (what the run knows about its bosses), /gw dungeon catalog (instances the atlas does not know), /gw dungeon quests (what the client gives for your quests).")
        end
        return
    end

    if command == "obj" or command:find("^obj ") or command == "objective" or command:find("^objective ") then
        local objectives = GW.DungeonObjectives
        local action, number, rest = message:match("^%s*%S+%s*(%S*)%s*(%d*)%s*(.-)%s*$")
        action = string.lower(action or "")
        number = tonumber(number)
        local function say(ok, done)
            GW.Print(ok and done or "No such objective. /gw obj lists them.")
        end
        if action == "add" then
            local text = message:match("^%s*%S+%s+%S+%s+(.-)%s*$")
            local objective, reason = objectives.Add(text)
            GW.Print(objective and ("Objective added: " .. objective.text) or (reason == "full" and "The list is full (20)." or "Usage: /gw obj add <text>"))
        elseif action == "boss" then
            local boss = message:match("^%s*%S+%s+%S+%s+(.-)%s*$")
            local objective = boss and objectives.Add("Kill " .. boss, boss)
            GW.Print(objective and ("Objective added: " .. objective.text .. ". It completes when the client reports that kill.") or "Usage: /gw obj boss <boss name>")
        elseif action == "done" or action == "undo" then
            say(objectives.SetDone(number, action == "done"), action == "done" and "Objective done." or "Objective reopened.")
        elseif action == "edit" then
            say(number and rest ~= "" and objectives.Edit(number, rest), "Objective changed.")
        elseif action == "up" or action == "down" then
            say(objectives.Move(number, action == "up" and -1 or 1), "Objective moved.")
        elseif action == "remove" or action == "del" then
            say(objectives.Remove(number), "Objective removed.")
        else
            local list = objectives.List()
            if #list == 0 then
                GW.Print("No objectives. /gw obj add <text>, or /gw obj boss <name> to complete it on that boss's kill.")
            end
            for index, objective in ipairs(list) do
                GW.Print(string.format("%d. %s%s%s", index, objective.done and "[done] " or "", objective.text,
                    objective.boss and (" (boss: " .. objective.boss .. ")") or ""))
            end
            GW.Print("/gw obj add <text>, boss <name>, done|undo|up|down|remove <n>, edit <n> <text>.")
        end
        return
    end

    if command == "loot" or command:find("^loot ") then
        local action, rest = command:match("^loot%s*(%S*)%s*(.-)$")
        local alerts, sync = GW.LootAlerts, GW.LootSync
        local prefs = alerts.Prefs()
        local function onOff(key, label)
            if rest == "on" or rest == "off" then prefs[key] = rest == "on" else prefs[key] = prefs[key] == false end
            GW.Print(label .. (prefs[key] ~= false and " on." or " off."))
            GW.MainFrame:RefreshView()
        end
        if action == "test" then
            GW.LootAlertUI.Preview(rest == "boe" and "valuable_boe" or "wishlist")
            GW.Print("Preview of a " .. (rest == "boe" and "valuable BoE" or "wishlist") .. " alert. /gw loot test boe shows the other kind. A real one also glows on the roll frame.")
        elseif action == "wishlist" then
            onOff("wishlist", "Wishlist alerts")
        elseif action == "boe" then
            onOff("boe", "Valuable BoE alerts")
        elseif action == "toast" then
            onOff("toast", "Loot toast when the HUD is hidden")
        elseif action == "sound" then
            if alerts.CHIMES[rest] then
                prefs.chime, prefs.sound = rest, true
                alerts.PlayChime(true)
                GW.Print("Loot alert chime: " .. alerts.CHIMES[rest].label .. ".")
                GW.MainFrame:RefreshView()
            else
                onOff("sound", "Loot alert sound")
            end
        elseif action == "threshold" then
            local gold = tonumber(rest)
            if gold and gold >= 1 and gold <= 100000 then
                prefs.boeThreshold = math.floor(gold * 10000)
                GW.MainFrame:RefreshView()
            end
            GW.Print("Valuable BoE alerts start at " .. alerts.FormatValue(alerts.Threshold()) .. " (estimated auction value). /gw loot threshold <gold> changes it.")
        elseif action == "probe" then
            for _, line in ipairs(GW.LootJournal.Probe()) do GW.Print(line) end
        elseif action == "scan" then
            local started, reason = GW.LootJournal.Scan(function(result)
                GW.Print(result.sent and ("Journal loot read for " .. result.encounters .. " bosses" .. (result.complete and "" or " (incomplete: some items had not loaded; scan again later)")
                    .. ". It reaches the website after /reload or logout.") or "The journal listed nothing to send.")
            end)
            GW.Print(started and "Reading the Encounter Journal's loot for this instance, a boss at a time." or GW.LootJournal.REASONS[reason] or "The scan could not start.")
        else
            local status = sync.Status()
            if not status.loaded then
                GW.Print("No wishlist has reached the game yet. Build one on the website (Dungeon runs > Loot & wishlist); Guildweaver on your computer brings it in, then /reload.")
            elseif not status.matched then
                GW.Print("A wishlist file is loaded (" .. status.characters .. " character(s)), but none of them is this character. Sync this character once (/reload), then check the website.")
            else
                GW.Print(string.format("Wishlist for %s: %d wanted item(s), revision %s. Valuable BoE list: %s.", tostring(status.characterName), status.wanted, tostring(status.revision),
                    status.market and (status.watch .. " item(s) on " .. status.market .. ", alerting from " .. alerts.FormatValue(alerts.Threshold())) or "none (no auction data for this character's faction and realm yet)"))
            end
            if status.result == "kept" or status.result == "stale" then
                GW.Print("The newest file from the bridge was " .. (status.result == "stale" and "older than the one already loaded" or "missing or unreadable") .. "; the last good wishlist is in use.")
            end
            GW.Print("Alerts: wishlist " .. (prefs.wishlist ~= false and "on" or "off") .. ", valuable BoE " .. (prefs.boe ~= false and "on" or "off") .. ", sound " .. (prefs.sound ~= false and "on" or "off")
                .. ". /gw loot test previews one; /gw loot wishlist|boe|sound|toast on|off, /gw loot sound soft|bell|coin, /gw loot threshold <gold>, /gw loot probe, /gw loot scan.")
        end
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

    if command == "fishing" or command == "fish" then
        printFishing()
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
        if GW.WorkQueue and GW.WorkQueue.ResetStats then
            GW.WorkQueue.ResetStats()
        end
        GW.Print("Performance counters reset.")
        return
    end

    if command == "capture" or command == "sync" then
        if not GW.Store.RetryLiveClient() then
            local validation = GW.Store.GetDatabase().meta.releaseValidation or {}
            GW.Print("Live release not confirmed (" .. tostring(validation.reason or "unknown") .. "); telemetry stays local. /gw version for details.")
        end
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
        GW.Print("/gw dungeon shows the open dungeon run. Its timer starts on your first pull; /gw dungeon start and /gw dungeon stop control it by hand. /gw dungeon split [name] marks a split (named after your target without a name), /gw dungeon finish ends the run, /gw dungeon hud on|off shows or hides the tracker, /gw dungeon mode cycles minimized/compact/expanded. /gw obj manages your dungeon objectives.")
        GW.Print("/gw guide opens the Dungeon Guide (bosses, mechanics, loot, rares) on the dungeon you are in or the last one picked.")
        GW.Print("/gw settings opens the settings; /gw minimap shows or hides the minimap button.")
        GW.Print("/gw loot shows the wishlist the website sent and the alert settings. Wishlist items glow purple and valuable Bind-on-Equip items gold in Need/Greed rolls, with a chime. /gw loot test previews an alert; /gw loot wishlist|boe|sound|toast on|off; /gw loot threshold <gold>.")
        GW.Print("/gw opens Guildweaver. Telemetry capture is automatic at session start, during play, and logout. WoW writes it to disk on /reload and logout, when the bridge syncs it. /gw sync (or /gw capture) forces a checkpoint and a reload to sync now. /gw snapshot captures a diagnostic snapshot. /gw telemetry shows captured telemetry streams. /gw inventory rescans your bags and shows the inventory revision. /gw fishing shows the casts and catches recorded this session. /gw perf shows capture timings and counts (/gw perf reset clears them). /gw version shows the addon version. /gw reset resets the window position.")
        return
    end

    GW.Print("Unknown command. Try /gw help.")
end
