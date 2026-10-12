local _, GW = ...

GW.FishingPoolProbe = GW.FishingPoolProbe or {}

local Probe = GW.FishingPoolProbe
local Globals = _G or {}
local PROBE_INTERVAL_SECONDS = 0.5
local STRONG_PRECAST_SECONDS = 8
local WEAK_PRECAST_SECONDS = 2
local ACTIVE_CAST_SECONDS = 35

local POOL_WORDS = {
    "school",
    "pool",
    "wreckage",
    "oil spill",
    "pure water",
    "floating debris",
    "floating wreckage",
    "waterlogged wreckage",
    "elemental water",
}

local function safe(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, value = pcall(fn, ...)
    if not ok then
        return nil
    end
    return value
end

local function isSecret(value)
    if type(Globals.issecretvalue) ~= "function" then
        return false
    end
    local ok, secret = pcall(Globals.issecretvalue, value)
    return ok and secret == true
end

local function readableText(value)
    if isSecret(value) then
        return nil
    end
    return type(value) == "string" and value ~= "" and value or nil
end

local function elapsed()
    return tonumber(safe(Globals.GetTime)) or 0
end

local function objectTooltipType()
    local enum = Globals.Enum and Globals.Enum.TooltipDataType
    return type(enum) == "table" and enum.Object or 4
end

local function gameObjectIdentity(guid)
    guid = readableText(guid)
    if not guid then
        return nil, nil
    end

    local parts = {}
    for part in string.gmatch(guid, "[^%-]+") do
        table.insert(parts, part)
    end
    if parts[1] ~= "GameObject" then
        return nil, nil
    end
    return guid, tonumber(parts[6])
end

local function tooltipFirstLine(tooltip)
    if tooltip and type(tooltip.GetLeftLine) == "function" then
        local line = safe(tooltip.GetLeftLine, tooltip, 1)
        if line and type(line.GetText) == "function" then
            local text = safe(line.GetText, line)
            if text ~= nil then
                return text
            end
        end
    end

    if tooltip and type(tooltip.GetName) == "function" then
        local tooltipName = readableText(safe(tooltip.GetName, tooltip))
        if tooltipName then
            local line = Globals[tooltipName .. "TextLeft1"]
            if line and type(line.GetText) == "function" then
                return safe(line.GetText, line)
            end
        end
    end

    return nil
end

local function looksLikePool(name)
    name = readableText(name)
    if not name then
        return false
    end

    local lowered = string.lower(name)
    for _, word in ipairs(POOL_WORDS) do
        if string.find(lowered, word, 1, true) then
            return true
        end
    end
    return false
end

local function copyProbe(probe)
    if type(probe) ~= "table" then
        return nil
    end
    return {
        at = probe.at,
        name = probe.name,
        guid = probe.guid,
        objectId = probe.objectId,
        dataType = probe.dataType,
        looksLikePool = probe.looksLikePool == true,
        nameRestricted = probe.nameRestricted == true,
        confidence = probe.confidence,
        detection = probe.detection,
    }
end

function Probe:ObserveTooltip(tooltip)
    local api = Globals.C_TooltipInfo
    if type(api) ~= "table" or type(api.GetWorldCursor) ~= "function" then
        return nil
    end

    local data = safe(api.GetWorldCursor)
    if type(data) ~= "table" then
        return nil
    end

    local dataType = data.type
    if isSecret(dataType) or (dataType ~= nil and tonumber(dataType) ~= tonumber(objectTooltipType())) then
        return nil
    end

    local guid, objectId = gameObjectIdentity(data.guid)
    local rawName = tooltipFirstLine(tooltip)
    local nameRestricted = rawName ~= nil and isSecret(rawName)
    local name = readableText(rawName)
    local poolName = looksLikePool(name)
    local now = elapsed()

    local probe = {
        at = now,
        name = name,
        guid = guid,
        objectId = objectId,
        dataType = tonumber(dataType) or tonumber(objectTooltipType()),
        looksLikePool = poolName,
        nameRestricted = nameRestricted,
        detection = "world_cursor_tooltip",
        confidence = poolName and "strong" or "probe",
    }
    self.lastProbe = probe

    if poolName then
        self.lastPool = probe
        return copyProbe(probe)
    end

    if nameRestricted and objectId then
        local restricted = {
            at = now,
            name = "Fishing Pool",
            guid = guid,
            objectId = objectId,
            dataType = probe.dataType,
            looksLikePool = true,
            nameRestricted = true,
            detection = "world_cursor_tooltip_restricted",
            confidence = "weak",
        }
        self.lastPool = restricted
        return copyProbe(restricted)
    end

    return copyProbe(probe)
end

function Probe:ProbeNow()
    return self:ObserveTooltip(Globals.GameTooltip)
end

function Probe:CandidateForCast(castAt)
    local pool = self.lastPool
    if type(pool) ~= "table" then
        return nil
    end

    local now = elapsed()
    castAt = tonumber(castAt) or now
    local maxPrecast = pool.confidence == "weak" and WEAK_PRECAST_SECONDS or STRONG_PRECAST_SECONDS
    local ageFromCast = castAt - (tonumber(pool.at) or 0)
    local ageNow = now - (tonumber(pool.at) or 0)

    if ageFromCast > maxPrecast or ageFromCast < -ACTIVE_CAST_SECONDS or ageNow > ACTIVE_CAST_SECONDS then
        return nil
    end

    return copyProbe(pool)
end

function Probe:GetLastProbe(maxAge)
    local probe = self.lastProbe
    if type(probe) ~= "table" then
        return nil
    end
    maxAge = tonumber(maxAge) or STRONG_PRECAST_SECONDS
    if elapsed() - (tonumber(probe.at) or 0) > maxAge then
        return nil
    end
    return copyProbe(probe)
end

function Probe:Reset()
    self.lastProbe = nil
    self.lastPool = nil
end

function Probe:Initialize()
    if self.initialized then
        return
    end
    self.initialized = true

    local tooltip = Globals.GameTooltip
    if not tooltip or type(tooltip.HookScript) ~= "function" then
        return
    end

    tooltip:HookScript("OnShow", function(frame)
        Probe:ObserveTooltip(frame)
    end)

    local accumulated = 0
    tooltip:HookScript("OnUpdate", function(frame, delta)
        accumulated = accumulated + (tonumber(delta) or 0)
        if accumulated < PROBE_INTERVAL_SECONDS then
            return
        end
        accumulated = 0
        Probe:ObserveTooltip(frame)
    end)
end

Probe:Initialize()
