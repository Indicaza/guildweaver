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

local function safeCall(func, ...)
    if type(func) ~= "function" then
        return nil
    end

    local ok, value = pcall(func, ...)
    if not ok then
        return nil
    end

    return value
end

local function spellMetadataComplete(value)
    return type(value) == "table"
        and value.name ~= nil
        and value.iconFileDataId ~= nil
        and value.description ~= nil
end

local function resolveSpell(spellId)
    spellId = tonumber(spellId)
    if not spellId or spellId <= 0 then
        return nil
    end

    if spellCache[spellId] ~= nil then
        return spellCache[spellId]
    end

    local resolver = GW.SpellTelemetry and GW.SpellTelemetry.Resolve
    local resolved = type(resolver) == "function" and resolver(spellId) or nil

    if spellMetadataComplete(resolved) then
        spellCache[spellId] = resolved
    end

    return resolved
end

local function currentLocale()
    return safeCall(GetLocale)
end

local function canonicalTreeHash(value)
    if type(value) == "table" then
        local bytes = {}
        local hex = {}

        for _, rawByte in ipairs(value) do
            local byte = tonumber(rawByte)
            if not byte or byte < 0 or byte > 255 then
                return nil, nil
            end

            byte = math.floor(byte)
            table.insert(bytes, byte)
            table.insert(hex, string.format("%02x", byte))
        end

        if #hex == 0 then
            return nil, nil
        end

        return table.concat(hex), bytes
    end

    if type(value) == "string" and value ~= "" then
        return value, nil
    end

    if type(value) == "number" then
        return tostring(value), nil
    end

    return nil, nil
end

local function treeHash(treeId)
    if not C_Traits or type(C_Traits.GetTreeHash) ~= "function" then
        return nil, nil
    end

    return canonicalTreeHash(safeCall(C_Traits.GetTreeHash, treeId))
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

local function markEntryMetadata(entry)
    local missing = {}

    if not entry.name or entry.name == "" then
        table.insert(missing, "name")
    end
    if not entry.iconFileDataId then
        table.insert(missing, "iconFileDataId")
    end
    if not entry.description or entry.description == "" then
        table.insert(missing, "description")
    end

    entry.metadataStatus = #missing == 0 and "complete" or "partial"
    entry.missingMetadata = #missing > 0 and missing or nil
    return #missing == 0
end

local function enrichDefinition(definition, rawTree, snapshot)
    if type(definition) ~= "table" then
        return
    end

    local hash, hashBytes = treeHash(definition.treeId)
    definition.schemaVersion = 4
    definition.treeHash = hash
    definition.treeHashBytes = hashBytes
    definition.locale = currentLocale()
    definition.specialization = snapshot and snapshot.specialization or nil

    if type(rawTree) == "table" then
        definition.name = rawTree.name
        definition.iconFileDataId = rawTree.iconFileDataId or rawTree.icon
    end

    local incompleteEntries = 0
    local entryCount = 0
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

            entryCount = entryCount + 1
            if not markEntryMetadata(entry) then
                incompleteEntries = incompleteEntries + 1
            end
        end
    end

    definition.metadata = {
        status = incompleteEntries == 0 and "complete" or "partial",
        entryCount = entryCount,
        incompleteEntryCount = incompleteEntries,
    }
end

local function addTreeHashes(talents, definitions)
    if type(talents) ~= "table" then
        return
    end

    local hashes = {}
    for _, definition in ipairs(definitions or {}) do
        table.insert(hashes, {
            treeId = definition.treeId,
            treeHash = definition.treeHash,
        })
    end
    talents.treeHashes = hashes
end

local function streamKeyPart(value)
    local normalized = string.lower(tostring(value or "unknown")):gsub("[^%w]+", "-")
    return normalized
end

local originalSetCharacterSnapshot = GW.Store.SetCharacterSnapshot
local originalSetTelemetrySnapshot = GW.Store.SetTelemetrySnapshot

local function emitDefinitions(snapshot, definitions)
    local classToken = snapshot.class and (snapshot.class.token or snapshot.class.name) or "unknown"
    local specialization = snapshot.specialization and (snapshot.specialization.id or snapshot.specialization.name) or "unknown"
    local build = snapshot.gameBuild and snapshot.gameBuild.build or "unknown"

    for _, definition in ipairs(definitions or {}) do
        local version = definition.treeHash or build
        originalSetTelemetrySnapshot(table.concat({
            "talent_tree_definition",
            streamKeyPart(classToken),
            streamKeyPart(specialization),
            streamKeyPart(definition.treeId),
            streamKeyPart(version),
            streamKeyPart(definition.locale),
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
            enrichDefinition(definition, treesById[tostring(definition.treeId or "")], normalized)
        end
        addTreeHashes(normalized.talents, definitions)

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
