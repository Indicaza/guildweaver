local _, GW = ...
local Globals = _G or {}
GW.MobLootCapture = GW.MobLootCapture or {}
local MAX_SEEN = 1000
local SEEN_SECONDS = 7200
local names = {}
local namesCount = 0

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

local function rememberUnit(unit)
    local guid = safe(Globals.UnitGUID, unit)
    local _, _, npcId = GW.GatheringTelemetry.SourceIdentity(guid)
    if not npcId then return end
    local name = safe(Globals.UnitName, unit)
    if type(name) ~= "string" or name == "" then return end
    if namesCount >= MAX_SEEN then names = {}; namesCount = 0 end
    if not names[guid] then namesCount = namesCount + 1 end
    names[guid] = name
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

local function seenStore(now)
    local db = GW.Store.GetDatabase()
    if not db or not db.meta then return nil end
    db.meta.mobLootSeen = db.meta.mobLootSeen or {}
    local seen = db.meta.mobLootSeen
    local count = 0
    local oldestKey, oldestTime = nil, math.huge
    for key, value in pairs(seen) do
        if type(value) ~= "table" or not tonumber(value.at) or now - value.at > SEEN_SECONDS or now < value.at then
            seen[key] = nil
        else
            count = count + 1
            if value.at < oldestTime then oldestKey, oldestTime = key, value.at end
        end
    end
    while count > MAX_SEEN and oldestKey do
        seen[oldestKey] = nil
        count = count - 1
        oldestKey, oldestTime = nil, math.huge
        for key, value in pairs(seen) do
            if value.at < oldestTime then oldestKey, oldestTime = key, value.at end
        end
    end
    return seen
end

local function skinningWindow()
    local capture = GW.SkinningCapture
    if not capture then return false end
    if capture.lootWindowActive then return true end
    local pending = capture.pending
    return type(pending) == "table" and elapsed() - (tonumber(pending.armedAt) or 0) <= 10
end

function GW.MobLootCapture.Capture()
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
            seen[scopeKey(guid)] = { at = now, outputs = {}, skinned = true }
        end
        seenStore(now)
        return nil
    end
    local sources = {}
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
    local count = 0
    for guid, source in pairs(sources) do
        local scope = scopeKey(guid)
        local previous = seen[scope] or { at = now, outputs = {} }
        local changed = false
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
                source = { guid = guid, npcId = source.npcId, name = names[guid], kind = "creature" },
                outputs = outputs,
                context = { location = location, instance = instanceContext(), lootMethod = safe(Globals.GetLootMethod) },
                capture = { attribution = "loot_source_pairs", visibility = "visible_to_observer", yieldBasis = "loot_window" },
            }, { capturedAt = previous.at, characterId = snapshot.characterId, realm = snapshot.realm,
                region = snapshot.region, gameBuild = snapshot.gameBuild })
            if envelope and GW.Store.SetTelemetryEvent("mob_loot:" .. tostring(snapshot.characterId) .. ":" .. guid, envelope) then
                seen[scope] = previous
                count = count + 1
            end
        end
    end
    seenStore(now)
    return count
end

function GW.MobLootCapture:Initialize()
    if self.eventFrame or type(Globals.CreateFrame) ~= "function" then return end
    local frame = Globals.CreateFrame("Frame")
    for _, event in ipairs({ "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "LOOT_READY", "LOOT_OPENED" }) do
        pcall(frame.RegisterEvent, frame, event)
    end
    frame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_TARGET_CHANGED" then rememberUnit("target")
        elseif event == "UPDATE_MOUSEOVER_UNIT" then rememberUnit("mouseover")
        else rememberUnit("target"); rememberUnit("mouseover"); pcall(GW.MobLootCapture.Capture) end
    end)
    self.eventFrame = frame
end
GW.MobLootCapture:Initialize()
