local _, GW = ...
local Globals = _G or {}
GW.MobLootCapture = GW.MobLootCapture or {}
local MAX_SEEN = 1000
local SEEN_SECONDS = 7200

-- Creatures seen this session, by GUID: their name and what the client says
-- about them, kept long enough to name a corpse looted after its unit is
-- gone (target changed, nameplate hidden, creature dead). Only a unit whose
-- GUID was read together with its name is ever named; a name for one GUID is
-- never given to another. By NPC ID only the name is kept, and it is reported
-- as such ("npc"), never as a sighting of that corpse. No display IDs: the
-- client has no unit API for them (docs/dungeon-guide.md).
local MAX_CREATURES = 400
local CREATURE_SECONDS = 1800
local MAX_NPC_NAMES = 400
local creatures = {}
local creatureCount = 0
local npcNames = {}
local npcNameCount = 0

local function safe(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if not ok then return nil end
    if type(Globals.issecretvalue) == "function" and Globals.issecretvalue(value) then return nil end
    return value
end

local function elapsed()
    return tonumber(safe(Globals.GetTime)) or 0
end

-- Drops expired entries, then the oldest, down to three quarters of the cap.
-- Runs only when an insert finds the cache full.
local function pruneCreatures(now)
    local ages = {}
    for guid, entry in pairs(creatures) do
        if now - entry.seenAt > CREATURE_SECONDS or now < entry.seenAt then
            creatures[guid] = nil
            creatureCount = creatureCount - 1
        else
            ages[#ages + 1] = entry.seenAt
        end
    end
    local target = math.floor(MAX_CREATURES * 3 / 4)
    if creatureCount <= target then return end
    table.sort(ages)
    local cutoff = ages[creatureCount - target]
    for guid, entry in pairs(creatures) do
        if creatureCount <= target then break end
        if entry.seenAt <= cutoff then
            creatures[guid] = nil
            creatureCount = creatureCount - 1
        end
    end
end

local function rememberNpcName(npcId, name)
    if npcNames[npcId] == nil then
        if npcNameCount >= MAX_NPC_NAMES then npcNames = {}; npcNameCount = 0 end
        npcNameCount = npcNameCount + 1
    end
    npcNames[npcId] = name
end

local function rememberUnit(unit)
    if type(unit) ~= "string" then return end
    local guid = safe(Globals.UnitGUID, unit)
    local _, _, npcId = GW.GatheringTelemetry.SourceIdentity(guid)
    if not npcId then return end
    local now = elapsed()
    local known = creatures[guid]
    if known and known.name then
        known.seenAt = now
        return
    end
    -- The client's own creature ID, where it has one, must agree with the
    -- GUID's; a unit that changed under us is not named.
    local creatureId = tonumber(safe(Globals.UnitCreatureID, unit))
    if creatureId and creatureId ~= npcId then return end
    local name = safe(Globals.UnitName, unit)
    if type(name) ~= "string" or name == "" then return end
    local classification = safe(Globals.UnitClassification, unit)
    if not known then
        if creatureCount >= MAX_CREATURES then pruneCreatures(now) end
        creatureCount = creatureCount + 1
    end
    creatures[guid] = { name = name, npcId = npcId, seenAt = now,
        classification = type(classification) == "string" and classification ~= "" and classification or nil }
    rememberNpcName(npcId, name)
end

-- What is known about a corpse's creature: { name, nameSource, classification }.
-- nameSource "unit" is this very creature; "npc" another of the same NPC ID.
local function identityOf(guid, npcId)
    local entry = creatures[guid]
    if entry and entry.name then
        return { name = entry.name, nameSource = "unit", classification = entry.classification }
    end
    local name = npcId and npcNames[npcId]
    if name then return { name = name, nameSource = "npc" } end
    return {}
end

function GW.MobLootCapture.CreatureIdentity(guid, npcId)
    return identityOf(guid, npcId)
end

-- Tests start the session caches over.
function GW.MobLootCapture.ResetCreatureCache()
    creatures, creatureCount, npcNames, npcNameCount = {}, 0, {}, 0
end

local function instanceContext()
    if type(Globals.GetInstanceInfo) ~= "function" then return nil end
    local ok, name, kind, difficultyId, difficultyName, _, _, _, instanceId = pcall(Globals.GetInstanceInfo)
    if not ok then return nil end
    local function scalar(value)
        if type(Globals.issecretvalue) == "function" and Globals.issecretvalue(value) then return nil end
        return value
    end
    return {
        name = scalar(name), type = scalar(kind), difficultyId = tonumber(scalar(difficultyId)),
        difficultyName = scalar(difficultyName), instanceId = tonumber(scalar(instanceId)),
    }
end

-- Corpses already recorded, saved across reloads so a corpse looted twice
-- (or reopened) is not counted twice. Bounded by age and count. Expired
-- entries are swept at most once a minute, and a full cache is cut back in
-- one batch, so a loot never walks the whole cache.
local PRUNE_INTERVAL_SECONDS = 60
local PRUNE_TARGET = MAX_SEEN - 100
local seenCount = nil
local lastPrune = nil

local function pruneSeen(seen, now)
    local count = 0
    local kept = {}
    for key, value in pairs(seen) do
        if type(value) ~= "table" or not tonumber(value.at) or now - value.at > SEEN_SECONDS or now < value.at then
            seen[key] = nil
        else
            count = count + 1
            kept[count] = value.at
        end
    end
    if count > MAX_SEEN then
        -- Drop the oldest down to PRUNE_TARGET: find the cut-off time once.
        table.sort(kept)
        local cutoff = kept[count - PRUNE_TARGET]
        for key, value in pairs(seen) do
            if count <= PRUNE_TARGET then break end
            if value.at <= cutoff then
                seen[key] = nil
                count = count - 1
            end
        end
    end
    seenCount = count
    lastPrune = now
end

local function seenStore(now)
    local db = GW.Store.GetDatabase()
    if not db or not db.meta then return nil end
    local seen = db.meta.mobLootSeen
    if type(seen) ~= "table" then
        seen = {}
        db.meta.mobLootSeen = seen
        seenCount = 0
    end
    if seenCount == nil or lastPrune == nil or now - lastPrune >= PRUNE_INTERVAL_SECONDS
        or now < lastPrune or seenCount > MAX_SEEN then
        pruneSeen(seen, now)
    end
    return seen
end

local function remember(seen, key, value)
    if seen[key] == nil then
        seenCount = (seenCount or 0) + 1
    end
    seen[key] = value
end

-- Tests and /reload of the store start the count over.
function GW.MobLootCapture.ResetSeenCache()
    seenCount = nil
    lastPrune = nil
end

-- An atlas boss or rare (Data/DungeonAtlas.generated.lua's NPC index): the
-- creatures whose loot windows count as loot opportunities even when they
-- held only coins.
local function atlasCreature(npcId)
    local guide = GW.DungeonGuide
    return npcId and guide and type(guide.InstanceFor) == "function" and guide.InstanceFor(nil, npcId) ~= nil or false
end

-- Whether this window shows a corpse's whole loot (docs/dungeon-guide.md,
-- "Loot observations"): every slot mapped to its corpse, and nobody else
-- could have taken items first (free-for-all in a group). "partial" windows
-- still report what they saw, but never count toward a drop rate's
-- denominator.
local function inspectionOf(loot)
    -- Coins (and currencies) carry no item; their amounts never match a
    -- corpse's quantity, so only item slots are checked.
    for _, output in ipairs(loot.outputs) do
        local item = not output.isCoin and (not output.currencyId or output.currencyId == 0)
        if item and not output.sourceMappingComplete then return "partial", "unmapped-slot" end
    end
    local group = tonumber(safe(Globals.GetNumGroupMembers)) or 0
    if group > 1 and safe(Globals.GetLootMethod) == "freeforall" then return "partial", "free-for-all" end
    return "complete", nil
end

local function skinningWindow()
    local capture = GW.SkinningCapture
    if not capture then return false end
    if capture.lootWindowActive then return true end
    local pending = capture.pending
    return type(pending) == "table" and elapsed() - (tonumber(pending.armedAt) or 0) <= 10
end

function GW.MobLootCapture.Capture()
    local perf = GW.Perf
    local started = perf and perf.Begin and perf.Begin() or nil
    local result = GW.MobLootCapture.CaptureNow()
    if perf and perf.End then
        perf.End("loot_event", started)
    end
    return result
end

function GW.MobLootCapture.CaptureNow()
    local snapshot = GW.Character and GW.Character.GetCurrentSnapshot and GW.Character.GetCurrentSnapshot()
    if type(snapshot) ~= "table" or not snapshot.characterId then return nil end
    local loot = GW.GatheringTelemetry.ReadLoot()
    if not loot then return nil end
    local now = tonumber(safe(Globals.GetServerTime)) or 0
    local seen = seenStore(now)
    if not seen then return nil end
    local function scopeKey(guid)
        local build = type(snapshot.gameBuild) == "table" and (snapshot.gameBuild.build or snapshot.gameBuild.version) or ""
        return table.concat({ tostring(build or ""), tostring(snapshot.region or ""), tostring(snapshot.realm or ""), guid }, ":")
    end
    if skinningWindow() then
        for _, guid in ipairs(loot.sourceGuids or {}) do
            remember(seen, scopeKey(guid), { at = now, outputs = {}, skinned = true })
        end
        return nil
    end
    local sources = {}
    local inspection, partialReason = inspectionOf(loot)
    for _, output in ipairs(loot.outputs) do
        if output.itemId and output.sourceMappingComplete and not output.isCoin and (not output.currencyId or output.currencyId == 0) then
            local assigned = {}
            for _, source in ipairs(output.sources or {}) do
                if source.npcId and not (seen[scopeKey(source.guid)] or {}).skinned then
                    assigned[source.guid] = (assigned[source.guid] or 0) + source.quantity
                    sources[source.guid] = sources[source.guid] or { npcId = source.npcId, outputs = {} }
                end
            end
            for guid, quantity in pairs(assigned) do
                local items = sources[guid].outputs
                local item = items[output.itemId] or {
                    itemId = output.itemId, name = output.name, qualityId = output.qualityId,
                    iconFileDataId = output.iconFileDataId, quantity = 0, isQuestItem = output.isQuestItem,
                }
                item.quantity = item.quantity + quantity
                items[output.itemId] = item
            end
        end
    end
    -- A boss or rare whose window held only coins: no item dropped. With a
    -- complete inspection that is an opportunity with no drop, so it is
    -- reported too (bosses and rares only, which keeps the volume small).
    if inspection == "complete" then
        for _, output in ipairs(loot.outputs) do
            if output.isCoin then
                for _, source in ipairs(output.sources or {}) do
                    if source.npcId and not sources[source.guid] and atlasCreature(source.npcId) then
                        sources[source.guid] = { npcId = source.npcId, outputs = {} }
                    end
                end
            end
        end
    end
    -- A Need/Greed roll that follows can name its creature from this
    -- window, when the item was on exactly one corpse (LootRolls).
    if GW.LootRolls and GW.LootRolls.NoteLootWindow then
        for guid, source in pairs(sources) do source.name = identityOf(guid, source.npcId).name end
        pcall(GW.LootRolls.NoteLootWindow, sources)
    end
    local count = 0
    local dungeon = GW.DungeonSessions
    local dungeonRun = dungeon and dungeon.Context and dungeon.Context() or nil
    for guid, source in pairs(sources) do
        local scope = scopeKey(guid)
        local first = seen[scope] == nil
        local previous = seen[scope] or { at = now, outputs = {} }
        -- A first look at a corpse is always reported (even with no items);
        -- a look again only when it shows more.
        local changed = first
        for id, output in pairs(source.outputs) do
            if not previous.outputs[id] or output.quantity > previous.outputs[id].quantity then
                previous.outputs[id] = output
                changed = true
            end
        end
        if changed then
            local outputs = {}
            for _, output in pairs(previous.outputs) do table.insert(outputs, output) end
            table.sort(outputs, function(a, b) return a.itemId < b.itemId end)
            local location = GW.GatheringTelemetry.CurrentLocation()
            location.positionKind = "player_at_loot"
            local envelope = GW.TelemetryEnvelope.Build("mob_loot", {
                schemaVersion = 1, observationId = guid, activity = "corpse_loot",
                source = (function()
                    local identity = identityOf(guid, source.npcId)
                    return { guid = guid, npcId = source.npcId, name = identity.name, nameSource = identity.nameSource,
                        classification = identity.classification, kind = "creature" }
                end)(),
                outputs = outputs,
                context = { location = location, instance = instanceContext(), lootMethod = safe(Globals.GetLootMethod),
                    dungeonRun = dungeonRun },
                capture = { attribution = "loot_source_pairs", visibility = "visible_to_observer", yieldBasis = "loot_window",
                    inspection = inspection, partialReason = partialReason, slotCount = #loot.outputs },
            }, { capturedAt = previous.at, characterId = snapshot.characterId, realm = snapshot.realm,
                region = snapshot.region, gameBuild = snapshot.gameBuild })
            if envelope and GW.Store.SetTelemetryEvent("mob_loot:" .. tostring(snapshot.characterId) .. ":" .. guid, envelope) then
                remember(seen, scope, previous)
                count = count + 1
                if dungeonRun and dungeon.NoteLoot then dungeon.NoteLoot() end
            end
        end
    end
    return count
end

function GW.MobLootCapture:Initialize()
    if self.eventFrame or type(Globals.CreateFrame) ~= "function" then return end
    local frame = Globals.CreateFrame("Frame")
    -- Nameplates, focus and boss frames name creatures the player never
    -- targets or mouses over. Events the client lacks are skipped.
    for _, event in ipairs({ "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "PLAYER_FOCUS_CHANGED", "NAME_PLATE_UNIT_ADDED",
        "INSTANCE_ENCOUNTER_ENGAGE_UNIT", "LOOT_READY", "LOOT_OPENED" }) do
        pcall(frame.RegisterEvent, frame, event)
    end
    frame:SetScript("OnEvent", function(_, event, unit)
        if event == "PLAYER_TARGET_CHANGED" then rememberUnit("target")
        elseif event == "UPDATE_MOUSEOVER_UNIT" then rememberUnit("mouseover")
        elseif event == "PLAYER_FOCUS_CHANGED" then rememberUnit("focus")
        elseif event == "NAME_PLATE_UNIT_ADDED" then rememberUnit(unit)
        elseif event == "INSTANCE_ENCOUNTER_ENGAGE_UNIT" then
            for index = 1, 5 do rememberUnit("boss" .. index) end
        else rememberUnit("target"); rememberUnit("mouseover"); pcall(GW.MobLootCapture.Capture) end
    end)
    self.eventFrame = frame
end
GW.MobLootCapture:Initialize()
