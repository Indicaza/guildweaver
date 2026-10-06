local _, GW = ...

GW.CollectorHealthTelemetry = GW.CollectorHealthTelemetry or {}

local REGION_NAMES = {
    [1] = "US",
    [2] = "KR",
    [3] = "EU",
    [4] = "TW",
    [5] = "CN",
}

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

local function collectGameBuild()
    if type(GetBuildInfo) ~= "function" then
        return nil
    end

    local ok, version, build, buildDate, interfaceVersion = pcall(GetBuildInfo)
    if not ok then
        return nil
    end

    return {
        version = version,
        build = build,
        buildDate = buildDate,
        interface = interfaceVersion,
    }
end

local function currentIdentity()
    local name, realm = UnitFullName("player")
    name = name or UnitName("player")
    realm = realm or GetRealmName()

    if not name or name == "" then
        return nil
    end

    local key = string.lower((realm or "") .. ":" .. name)
    return {
        realm = realm,
        region = REGION_NAMES[tonumber(safeCall(GetCurrentRegion))],
        installationId = GW.Store.GetInstallationId(),
        characterId = GW.Store.GetCharacterId(key),
        gameBuild = collectGameBuild(),
    }
end

local function currentGuildId()
    if type(GetGuildInfo) ~= "function" then
        return nil
    end

    local guildName, _, _, guildRealm = GetGuildInfo("player")
    if not guildName then
        return nil
    end

    return "guild-" .. GW.Store.Fingerprint({
        name = guildName,
        realm = guildRealm or GetRealmName(),
    })
end

local function envelope(identity, payload, capturedAt)
    return {
        schemaVersion = 1,
        eventType = "collector_health_snapshot",
        capturedAt = capturedAt,
        gameBuild = identity.gameBuild,
        realm = identity.realm,
        region = identity.region,
        installationId = identity.installationId,
        characterId = identity.characterId,
        guildId = currentGuildId(),
        payload = payload,
    }
end

local function streamInventory(database)
    local types = {}
    local seen = {}
    local count = 0
    local telemetry = database
        and database.sync
        and database.sync.outbound
        and database.sync.outbound.telemetry
        or {}

    for streamKey, record in pairs(telemetry) do
        local eventType = record and record.envelope and record.envelope.eventType or nil
        if eventType ~= "collector_health_snapshot" then
            count = count + 1
            local normalized = eventType or tostring(streamKey):match("^([^:]+)") or "unknown"
            if not seen[normalized] then
                seen[normalized] = true
                table.insert(types, normalized)
            end
        end
    end

    table.sort(types)
    return count, types
end

local function professionCoverage(snapshot)
    local professionCount = 0
    local knownRecipeCount = 0

    for _, profession in ipairs(snapshot and snapshot.professions or {}) do
        professionCount = professionCount + 1
        for _, recipe in ipairs(profession.recipes or {}) do
            if recipe.known ~= false then
                knownRecipeCount = knownRecipeCount + 1
            end
        end
    end

    return professionCount, knownRecipeCount
end

function GW.CollectorHealthTelemetry.Capture(reason)
    local identity = currentIdentity()
    if not identity then
        return nil
    end

    local database = GW.Store.GetDatabase()
    local characterSnapshot = GW.Character and GW.Character.GetCurrentSnapshot and GW.Character.GetCurrentSnapshot() or nil
    local stateStreamCount, stateStreamTypes = streamInventory(database)
    local professionCount, knownRecipeCount = professionCoverage(characterSnapshot)
    local eventStats = GW.TelemetryEvents and GW.TelemetryEvents.GetStats and GW.TelemetryEvents.GetStats() or nil
    local capturedAt = GetServerTime()
    local payload = {
        schemaVersion = 1,
        capturedAt = capturedAt,
        reason = reason or "manual",
        addonVersion = GW.version,
        savedVariablesSchemaVersion = tonumber(database and database.schemaVersion) or nil,
        capabilities = {
            characterSnapshot = GW.Character ~= nil,
            professionSnapshot = GW.ProfessionTelemetry ~= nil,
            recipeCatalogSnapshot = GW.ProfessionTelemetry ~= nil,
            inventorySnapshot = GW.InventoryTelemetry ~= nil,
            lootObservation = GW.LootTelemetry ~= nil,
            auctionObservation = GW.AuctionTelemetry ~= nil,
            orderedEventQueue = GW.TelemetryEvents ~= nil,
        },
        observed = {
            characterSnapshot = characterSnapshot ~= nil,
            talentApi = characterSnapshot and characterSnapshot.talents and characterSnapshot.talents.api or nil,
            professionCount = professionCount,
            knownRecipeCount = knownRecipeCount,
            stateStreamCount = stateStreamCount,
            stateStreamTypes = stateStreamTypes,
        },
        eventQueue = eventStats,
    }

    GW.Store.SetTelemetrySnapshot(
        "collector_health_snapshot:" .. identity.characterId,
        envelope(identity, payload, capturedAt)
    )

    return payload
end

function GW.CollectorHealthTelemetry.GetDiagnostics()
    return GW.CollectorHealthTelemetry.Capture("DIAGNOSTIC")
end

local function safeRegister(frame, event)
    pcall(frame.RegisterEvent, frame, event)
end

function GW.CollectorHealthTelemetry:Initialize()
    if self.eventFrame then
        return
    end

    local frame = CreateFrame("Frame")
    safeRegister(frame, "PLAYER_LOGIN")
    safeRegister(frame, "PLAYER_ENTERING_WORLD")

    local capturePending = false
    frame:SetScript("OnEvent", function(_, event)
        if capturePending then
            return
        end

        capturePending = true
        C_Timer.After(2, function()
            capturePending = false
            GW.CollectorHealthTelemetry.Capture(event)
        end)
    end)

    self.eventFrame = frame

    C_Timer.After(5, function()
        GW.CollectorHealthTelemetry.Capture("INITIAL_DELAY")
    end)
end
