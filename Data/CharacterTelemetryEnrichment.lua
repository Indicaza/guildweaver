local _, GW = ...

local spellCache = {}

local function replaceTable(target, source)
    for key in pairs(target) do
        target[key] = nil
    end
    for key, value in pairs(source) do
        target[key] = value
    end
end

local function resolveSpell(spellId)
    spellId = tonumber(spellId)
    if not spellId or spellId <= 0 then
        return nil
    end

    if spellCache[spellId] ~= nil then
        return spellCache[spellId] or nil
    end

    local resolver = GW.SpellTelemetry and GW.SpellTelemetry.Resolve
    local resolved = type(resolver) == "function" and resolver(spellId) or nil
    spellCache[spellId] = resolved or false
    return resolved
end

local function conditionStates(conditions)
    local result = {}
    for _, condition in ipairs(type(conditions) == "table" and conditions or {}) do
        if type(condition) == "table" then
            table.insert(result, {
                id = condition.id,
                type = condition.type,
                isMet = condition.isMet,
                isGate = condition.isGate,
                isSufficient = condition.isSufficient,
                ranksGranted = condition.ranksGranted,
            })
        end
    end
    return #result > 0 and result or nil
end

local function entryStates(entries)
    local result = {}
    for _, entry in ipairs(type(entries) == "table" and entries or {}) do
        if type(entry) == "table" and (entry.isAvailable ~= nil or entry.selected ~= nil) then
            table.insert(result, {
                entryId = entry.id,
                isAvailable = entry.isAvailable,
                isActiveEntry = entry.selected == true,
            })
        end
    end
    return #result > 0 and result or nil
end

local function collectNodeStates(rawTalents)
    local result = {}
    for _, tree in ipairs(type(rawTalents) == "table" and rawTalents.trees or {}) do
        for _, node in ipairs(type(tree) == "table" and tree.nodes or {}) do
            if type(node) == "table" then
                table.insert(result, {
                    nodeId = node.id,
                    isAvailable = node.isAvailable,
                    isVisible = node.isVisible,
                    meetsEdgeRequirements = node.meetsEdgeRequirements,
                    conditions = conditionStates(node.conditions),
                    entries = entryStates(node.entries),
                })
            end
        end
    end
    return #result > 0 and result or nil
end

local function rawTreeMap(rawTalents)
    local result = {}
    for _, tree in ipairs(type(rawTalents) == "table" and rawTalents.trees or {}) do
        if type(tree) == "table" and tree.id then
            result[tostring(tree.id)] = tree
        end
    end
    return result
end

local function rawNodeMap(tree)
    local result = {}
    for _, node in ipairs(type(tree) == "table" and tree.nodes or {}) do
        if type(node) == "table" and node.id then
            result[tostring(node.id)] = node
        end
    end
    return result
end

local function rawEntryMap(node)
    local result = {}
    for _, entry in ipairs(type(node) == "table" and node.entries or {}) do
        if type(entry) == "table" and entry.id then
            result[tostring(entry.id)] = entry
        end
    end
    return result
end

local function enrichDefinition(definition, rawTree)
    if type(definition) ~= "table" then
        return
    end

    definition.schemaVersion = 2
    if type(rawTree) == "table" then
        definition.name = rawTree.name
        definition.iconFileDataId = rawTree.iconFileDataId or rawTree.icon
    end

    local nodesById = rawNodeMap(rawTree)
    for _, node in ipairs(type(definition.nodes) == "table" and definition.nodes or {}) do
        local rawNode = nodesById[tostring(node.nodeId or "")]
        local entriesById = rawEntryMap(rawNode)
        for _, entry in ipairs(type(node.entries) == "table" and node.entries or {}) do
            local rawEntry = entriesById[tostring(entry.entryId or "")]
            local resolved = resolveSpell(entry.spellId)

            entry.name = entry.name or (type(rawEntry) == "table" and rawEntry.name) or (resolved and resolved.name)
            entry.iconFileDataId = entry.iconFileDataId
                or (type(rawEntry) == "table" and (rawEntry.iconFileDataId or rawEntry.icon))
                or (resolved and resolved.iconFileDataId)
            entry.description = (type(rawEntry) == "table" and rawEntry.description) or (resolved and resolved.description)
            entry.spellLink = (type(rawEntry) == "table" and rawEntry.spellLink) or (resolved and resolved.spellLink)
            entry.tooltip = (type(rawEntry) == "table" and rawEntry.tooltip) or (resolved and resolved.tooltip)
        end
    end
end

local function streamKeyPart(value)
    local normalized = string.lower(tostring(value or "unknown")):gsub("[^%w]+", "-")
    return normalized
end

local originalSetCharacterSnapshot = GW.Store.SetCharacterSnapshot
local originalSetTelemetrySnapshot = GW.Store.SetTelemetrySnapshot

local function emitDefinitions(snapshot, definitions)
    local classToken = snapshot.class and (snapshot.class.token or snapshot.class.name) or "unknown"
    local build = snapshot.gameBuild and snapshot.gameBuild.build or "unknown"

    for _, definition in ipairs(definitions or {}) do
        originalSetTelemetrySnapshot(table.concat({
            "talent_tree_definition",
            streamKeyPart(classToken),
            streamKeyPart(build),
            streamKeyPart(definition.treeId),
        }, ":"), {
            schemaVersion = 1,
            eventType = "talent_tree_definition",
            capturedAt = snapshot.capturedAt,
            gameBuild = snapshot.gameBuild,
            realm = snapshot.realm,
            region = snapshot.region,
            installationId = GW.Store.GetInstallationId(),
            payload = definition,
        })
    end
end

function GW.Store.SetCharacterSnapshot(characterKey, snapshot)
    if type(snapshot) ~= "table" then
        return originalSetCharacterSnapshot(characterKey, snapshot)
    end

    local rawTalents = snapshot.talents
    local normalized, definitions = GW.TelemetrySchema.NormalizeCharacterSnapshot(snapshot)
    if normalized ~= snapshot then
        normalized.stats = GW.CharacterStats and GW.CharacterStats.Capture and GW.CharacterStats.Capture() or nil
        if type(normalized.talents) == "table" then
            normalized.talents.nodeStates = collectNodeStates(rawTalents)
        end

        local treesById = rawTreeMap(rawTalents)
        for _, definition in ipairs(definitions or {}) do
            enrichDefinition(definition, treesById[tostring(definition.treeId or "")])
        end

        replaceTable(snapshot, normalized)
        local changed = originalSetCharacterSnapshot(characterKey, snapshot)
        emitDefinitions(snapshot, definitions)
        return changed
    end

    if not snapshot.stats and GW.CharacterStats and GW.CharacterStats.Capture then
        snapshot.stats = GW.CharacterStats.Capture()
    end
    return originalSetCharacterSnapshot(characterKey, snapshot)
end

GW.CharacterTelemetryEnrichment = GW.CharacterTelemetryEnrichment or {}
GW.CharacterTelemetryEnrichment.CollectNodeStates = collectNodeStates
