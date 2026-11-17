local _, GW = ...

-- The client's Encounter Journal as a source of advertised dungeon loot,
-- and a probe that says which loot APIs this client actually has.
--
-- Whether WoW Forever has a working Encounter Journal is not assumed
-- anywhere. Every call is checked for existence and wrapped; a client
-- without the journal simply reports "not available". /gw loot probe
-- prints what was found, so it can be verified in the real client.
--
-- A scan (/gw loot scan, inside a dungeon or raid) reads the journal's
-- loot list for each boss of the current instance and difficulty, and
-- queues one loot_catalog_snapshot event for the website:
--   - never in combat: it runs on the work queue as an optional job, one
--     boss per step, and waits while the player fights
--   - resumable: an interrupted scan picks up at the boss it stopped on
--   - honest about completeness: a boss counts as complete only when
--     every listed item resolved; the snapshot as a whole only when every
--     boss did. The website only ever delists an item on a complete list.
--   - it changes the journal's selection and loot filter while it reads,
--     so it does not start while the journal window is open, and it puts
--     the player's loot filter back afterwards.
--
-- Scans are started by hand for now (settings: none). Once the probe has
-- been confirmed in the Forever client, entering a dungeon can start one.
GW.LootJournal = GW.LootJournal or {}

local Journal = GW.LootJournal
local Globals = _G or {}

local MAX_ENCOUNTERS = 40
local MAX_ITEMS = 200
local JOB_KEY = "loot_journal_scan"

Journal.FUNCTIONS = { "EJ_GetInstanceForMap", "EJ_SelectInstance", "EJ_GetEncounterInfoByIndex", "EJ_SelectEncounter", "EJ_GetNumLoot",
    "EJ_GetLootInfoByIndex", "EJ_SetLootFilter", "EJ_GetLootFilter", "EJ_ResetLootFilter", "EJ_SetDifficulty", "EJ_GetDifficulty",
    "GetLootRollItemInfo", "GetLootRollItemLink", "GetLootMethod", "RollOnLoot" }
Journal.NAMESPACED = { { "C_EncounterJournal", "GetLootInfoByIndex" }, { "C_EncounterJournal", "GetLootInfo" }, { "C_LootHistory", "GetItem" },
    { "C_LootHistory", "GetSortedInfoForDrop" } }
Journal.EVENTS = { "START_LOOT_ROLL", "CANCEL_LOOT_ROLL", "LOOT_ROLLS_COMPLETE", "LOOT_HISTORY_ROLL_CHANGED", "LOOT_HISTORY_UPDATE_DROP",
    "CHAT_MSG_LOOT", "ENCOUNTER_END", "EJ_LOOT_DATA_RECIEVED", "EJ_DIFFICULTY_UPDATE" }

local function plain(value)
    if value == nil or (type(Globals.issecretvalue) == "function" and Globals.issecretvalue(value)) then return nil end
    return value
end

local function call(name, ...)
    local fn = Globals[name]
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end

local function has(name)
    return type(Globals[name]) == "function"
end

-- Whether the calls a scan needs are all there.
function Journal.Supported()
    return has("EJ_GetInstanceForMap") and has("EJ_SelectInstance") and has("EJ_GetEncounterInfoByIndex") and has("EJ_SelectEncounter")
        and has("EJ_GetNumLoot") and has("EJ_GetLootInfoByIndex") and type(Globals.C_Map) == "table"
        and type(Globals.C_Map.GetBestMapForUnit) == "function"
end

local function instance()
    if type(Globals.GetInstanceInfo) ~= "function" then return nil end
    local ok, name, kind, difficultyId, _, _, _, _, instanceId = pcall(Globals.GetInstanceInfo)
    if not ok then return nil end
    kind = plain(kind)
    if kind ~= "party" and kind ~= "raid" then return nil end
    return { name = plain(name), type = kind, difficultyId = tonumber(plain(difficultyId)) or 0, instanceId = tonumber(plain(instanceId)) }
end

-- The item of one journal loot row. Clients differ: newer ones return a
-- table, older ones a list of values with the item id and link among them.
function Journal.ReadLootRow(...)
    local first = plain((...))
    if type(first) == "table" then
        local itemId = tonumber(plain(first.itemID))
        if not itemId then
            itemId = tonumber(string.match(tostring(plain(first.link) or ""), "item:(%d+)"))
        end
        if not itemId then return nil end
        return { itemId = itemId, name = type(plain(first.name)) == "string" and first.name or nil, iconFileDataId = tonumber(plain(first.icon)) }
    end
    local itemId, name
    for index = 1, select("#", ...) do
        local value = plain((select(index, ...)))
        if type(value) == "string" then
            local linked = tonumber(string.match(value, "item:(%d+)"))
            if linked then itemId = linked end
            if index == 1 and not string.find(value, "|", 1, true) then name = value end
        end
    end
    if not itemId then
        -- The classic order is name, icon, slot, armorType, itemID, link.
        itemId = tonumber(plain((select(5, ...))))
    end
    if not itemId or itemId <= 0 then return nil end
    return { itemId = itemId, name = name }
end

-- What this client has, as lines to print. Safe anywhere, in or out of
-- combat: it only looks, it does not call the journal.
function Journal.Probe()
    local lines = {}
    local present, missing = {}, {}
    for _, name in ipairs(Journal.FUNCTIONS) do
        table.insert(has(name) and present or missing, name)
    end
    for _, pair in ipairs(Journal.NAMESPACED) do
        local namespace = Globals[pair[1]]
        local label = pair[1] .. "." .. pair[2]
        table.insert(type(namespace) == "table" and type(namespace[pair[2]]) == "function" and present or missing, label)
    end
    local interface = nil
    if type(Globals.GetBuildInfo) == "function" then
        local ok, _, _, _, toc = pcall(Globals.GetBuildInfo)
        interface = ok and toc or nil
    end
    table.insert(lines, "Loot API probe (Guildweaver " .. tostring(GW.version) .. ", interface " .. tostring(interface or "?") .. "):")
    table.insert(lines, "present: " .. (#present > 0 and table.concat(present, ", ") or "none"))
    table.insert(lines, "missing: " .. (#missing > 0 and table.concat(missing, ", ") or "none"))
    local registered = GW.LootRolls and GW.LootRolls.registered or {}
    local events = {}
    if type(Globals.CreateFrame) == "function" then
        local frame = Globals.CreateFrame("Frame")
        for _, event in ipairs(Journal.EVENTS) do
            local ok, result = pcall(frame.RegisterEvent, frame, event)
            table.insert(events, event .. "=" .. ((ok and result ~= false) and "yes" or "no"))
        end
        pcall(frame.UnregisterAllEvents, frame)
    end
    table.insert(lines, "events the client accepts: " .. table.concat(events, ", "))
    local frames = {}
    for index = 1, 4 do
        local frame = Globals["GroupLootFrame" .. index]
        if type(frame) == "table" then table.insert(frames, "GroupLootFrame" .. index) end
    end
    table.insert(lines, "roll frames: " .. (#frames > 0 and table.concat(frames, ", ") or "none found (the glow falls back to the Guildweaver notice)")
        .. "; NUM_GROUP_LOOT_FRAMES=" .. tostring(Globals.NUM_GROUP_LOOT_FRAMES))
    table.insert(lines, "loot text: LOOT_ITEM_SELF=" .. tostring(Globals.LOOT_ITEM_SELF) .. "; SOUNDKIT=" .. type(Globals.SOUNDKIT))
    table.insert(lines, "roll events registered by Guildweaver: START_LOOT_ROLL=" .. tostring(registered.START_LOOT_ROLL) .. ", CANCEL_LOOT_ROLL="
        .. tostring(registered.CANCEL_LOOT_ROLL) .. ", CHAT_MSG_LOOT=" .. tostring(registered.CHAT_MSG_LOOT))
    table.insert(lines, Journal.Supported() and "Encounter Journal loot: the calls exist. /gw loot scan inside a dungeon reads it."
        or "Encounter Journal loot: not available on this client. The catalog still grows from loot windows and rolls.")
    return lines
end

local function journalOpen()
    local frame = Globals.EncounterJournal
    if type(frame) ~= "table" or type(frame.IsShown) ~= "function" then return false end
    local ok, value = pcall(frame.IsShown, frame)
    return ok and value == true
end

local function publish(scan)
    local snapshot = GW.Character and GW.Character.GetCurrentSnapshot and GW.Character.GetCurrentSnapshot()
    if type(snapshot) ~= "table" or not snapshot.characterId or #scan.encounters == 0 then return false end
    local complete = scan.listComplete == true
    for _, encounter in ipairs(scan.encounters) do
        if not encounter.complete then complete = false end
    end
    local payload = {
        schemaVersion = 1, sourceApi = "encounter_journal", complete = complete, difficultyId = scan.instance.difficultyId,
        filters = { classId = 0, specId = 0 },
        instance = { instanceId = scan.instance.instanceId, journalInstanceId = scan.journalInstanceId, name = scan.instance.name, type = scan.instance.type },
        encounters = scan.encounters,
    }
    local envelope = GW.TelemetryEnvelope.Build("loot_catalog_snapshot", payload, { characterId = snapshot.characterId, realm = snapshot.realm,
        region = snapshot.region, gameBuild = snapshot.gameBuild })
    if not envelope then return false end
    GW.Store.SetTelemetryEvent("loot_catalog:" .. tostring(scan.journalInstanceId) .. ":" .. tostring(scan.instance.difficultyId), envelope)
    return true, complete
end

-- Reads one boss's loot list. Returns the encounter entry.
local function readEncounter(boss)
    call("EJ_SelectEncounter", boss.journalEncounterId)
    local okCount, count = call("EJ_GetNumLoot")
    count = okCount and tonumber(plain(count)) or nil
    local items, seen, resolved = {}, {}, 0
    for index = 1, math.min(count or 0, MAX_ITEMS) do
        local row = Journal.ReadLootRow(select(2, call("EJ_GetLootInfoByIndex", index)))
        if row then
            resolved = resolved + 1
            if not seen[row.itemId] then
                seen[row.itemId] = true
                table.insert(items, row)
            end
        end
    end
    -- Complete: the journal gave a count, it fits, and every row resolved.
    return { journalEncounterId = boss.journalEncounterId, name = boss.name, items = items,
        complete = count ~= nil and count <= MAX_ITEMS and resolved == count }
end

-- Starts (or resumes) a scan of the instance the player is in. Returns
-- true and nil, or false and why not.
function Journal.Scan(onDone)
    if not Journal.Supported() then return false, "unsupported" end
    local where = instance()
    if not where or not where.instanceId then return false, "not_in_instance" end
    local queue = GW.WorkQueue
    if not queue or type(queue.Enqueue) ~= "function" then return false, "no_queue" end
    if journalOpen() then return false, "journal_open" end
    if queue.InCombat and queue.InCombat() then return false, "in_combat" end

    local okMap, uiMap = pcall(Globals.C_Map.GetBestMapForUnit, "player")
    local okInstance, journalInstance = call("EJ_GetInstanceForMap", okMap and plain(uiMap) or nil)
    journalInstance = okInstance and tonumber(plain(journalInstance)) or nil
    if not journalInstance or journalInstance == 0 then return false, "no_journal_instance" end

    -- A scan interrupted earlier for the same place continues where it was.
    local scan = Journal.pending
    if not scan or scan.journalInstanceId ~= journalInstance or scan.instance.difficultyId ~= where.difficultyId then
        scan = { instance = where, journalInstanceId = journalInstance, encounters = {}, bosses = nil, next = 1 }
        Journal.pending = scan
    end

    -- The player's own loot filter, as it was before the scan touched it.
    local function restoreFilter()
        if scan.filter and has("EJ_SetLootFilter") then call("EJ_SetLootFilter", scan.filter[1], scan.filter[2]) end
        scan.filter = nil
    end

    local job = queue.Enqueue({
        key = JOB_KEY,
        optional = true,
        category = "loot_journal",
        onCancel = restoreFilter,
        isStale = function()
            local now = instance()
            return not now or now.instanceId ~= where.instanceId or now.difficultyId ~= where.difficultyId
        end,
        step = function()
            -- The player opened the journal: it is theirs. Stop here; the
            -- next /gw loot scan continues from this boss.
            if journalOpen() then
                restoreFilter()
                return true
            end
            if not scan.bosses then
                -- The player's own filter is put back when the scan ends.
                local okFilter, classId, specId = call("EJ_GetLootFilter")
                scan.filter = okFilter and { tonumber(plain(classId)) or 0, tonumber(plain(specId)) or 0 } or nil
                call("EJ_SelectInstance", journalInstance)
                if has("EJ_SetDifficulty") and where.difficultyId > 0 then call("EJ_SetDifficulty", where.difficultyId) end
                if has("EJ_ResetLootFilter") then call("EJ_ResetLootFilter") elseif has("EJ_SetLootFilter") then call("EJ_SetLootFilter", 0, 0) end
                scan.bosses = {}
                scan.listComplete = false
                for index = 1, MAX_ENCOUNTERS + 1 do
                    local ok, name, _, journalEncounterId = call("EJ_GetEncounterInfoByIndex", index, journalInstance)
                    name = ok and plain(name) or nil
                    journalEncounterId = tonumber(plain(journalEncounterId))
                    if type(name) ~= "string" or not journalEncounterId then
                        scan.listComplete = true
                        break
                    end
                    if index <= MAX_ENCOUNTERS then table.insert(scan.bosses, { name = name, journalEncounterId = journalEncounterId }) end
                end
                return false
            end
            local boss = scan.bosses[scan.next]
            if boss then
                table.insert(scan.encounters, readEncounter(boss))
                scan.next = scan.next + 1
                return false
            end
            restoreFilter()
            local sent, complete = publish(scan)
            Journal.pending = nil
            Journal.last = { instanceId = where.instanceId, difficultyId = where.difficultyId, encounters = #scan.encounters, sent = sent, complete = complete }
            if type(onDone) == "function" then pcall(onDone, Journal.last) end
            return true
        end,
    })
    if not job then return false, "queue_full" end
    return true
end

Journal.REASONS = {
    unsupported = "This client has no Encounter Journal loot API (see /gw loot probe).",
    not_in_instance = "Enter a dungeon or raid first: the scan reads the journal for the instance you are in.",
    no_queue = "The work queue is not available.",
    journal_open = "Close the Encounter Journal window first: the scan changes its selection while it reads.",
    in_combat = "Not in combat. Try again after the fight.",
    no_journal_instance = "The journal has no entry for this instance.",
    queue_full = "Guildweaver is busy; try again in a moment.",
}
