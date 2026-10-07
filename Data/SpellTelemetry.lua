local _, GW = ...

local Globals = _G or {}
local MAX_TOOLTIP_LINES = 32
local MAX_TOOLTIP_TEXT = 420
local tooltipScanner = nil
local tooltipScannerInitialized = false

local function cleanText(value)
    if type(value) ~= "string" then
        return nil
    end

    local text = value:gsub("Player%-%d+%-%x+", "Player-REDACTED")
    if #text > MAX_TOOLTIP_TEXT then
        text = text:sub(1, MAX_TOOLTIP_TEXT)
    end
    return text ~= "" and text or nil
end

local function colorValue(value)
    if type(value) ~= "table" then
        return nil
    end

    local r = tonumber(value.r)
    local g = tonumber(value.g)
    local b = tonumber(value.b)
    local a = tonumber(value.a)
    if not r and not g and not b and not a then
        return nil
    end

    return { r = r, g = g, b = b, a = a }
end

local function normalizeTooltipLine(line)
    if type(line) ~= "table" then
        return nil
    end

    local left = cleanText(line.leftText or line.text or line.left)
    local right = cleanText(line.rightText or line.right)
    if not left and not right then
        return nil
    end

    return {
        left = left,
        right = right,
        leftColor = colorValue(line.leftColor or line.color),
        rightColor = colorValue(line.rightColor),
    }
end

local function normalizeTooltipData(data, source)
    if type(data) ~= "table" or type(data.lines) ~= "table" then
        return nil
    end

    local lines = {}
    for _, line in ipairs(data.lines) do
        if #lines >= MAX_TOOLTIP_LINES then
            break
        end
        local normalized = normalizeTooltipLine(line)
        if normalized then
            table.insert(lines, normalized)
        end
    end

    return #lines > 0 and { source = source, lines = lines } or nil
end

local function collectModernTooltip(spellId)
    local tooltipInfo = Globals.C_TooltipInfo
    if type(tooltipInfo) ~= "table" then
        return nil
    end

    if type(tooltipInfo.GetSpellByID) == "function" then
        local ok, data = pcall(tooltipInfo.GetSpellByID, spellId)
        if ok then
            local result = normalizeTooltipData(data, "C_TooltipInfo.GetSpellByID")
            if result then
                return result
            end
        end
    end

    if type(tooltipInfo.GetHyperlink) == "function" then
        local ok, data = pcall(tooltipInfo.GetHyperlink, "spell:" .. tostring(spellId))
        if ok then
            return normalizeTooltipData(data, "C_TooltipInfo.GetHyperlink")
        end
    end

    return nil
end

local function scannerFrame()
    if tooltipScannerInitialized then
        return tooltipScanner
    end
    tooltipScannerInitialized = true

    if type(CreateFrame) ~= "function" or not UIParent then
        return nil
    end

    local ok, frame = pcall(CreateFrame, "GameTooltip", "GuildweaverSpellScanTooltip", UIParent, "GameTooltipTemplate")
    if not ok or not frame then
        return nil
    end

    tooltipScanner = frame
    return tooltipScanner
end

local function fontStringText(value)
    if not value or type(value.GetText) ~= "function" then
        return nil
    end
    local ok, text = pcall(value.GetText, value)
    return ok and cleanText(text) or nil
end

local function fontStringColor(value)
    if not value or type(value.GetTextColor) ~= "function" then
        return nil
    end
    local ok, r, g, b, a = pcall(value.GetTextColor, value)
    if not ok then
        return nil
    end
    return colorValue({ r = r, g = g, b = b, a = a })
end

local function collectLegacyTooltip(spellId)
    local frame = scannerFrame()
    if not frame or type(frame.NumLines) ~= "function" then
        return nil
    end

    if type(frame.SetOwner) == "function" then
        pcall(frame.SetOwner, frame, UIParent, "ANCHOR_NONE")
    end
    if type(frame.ClearLines) == "function" then
        pcall(frame.ClearLines, frame)
    end

    local ok = false
    if type(frame.SetSpellByID) == "function" then
        ok = pcall(frame.SetSpellByID, frame, spellId)
    elseif type(frame.SetHyperlink) == "function" then
        ok = pcall(frame.SetHyperlink, frame, "spell:" .. tostring(spellId))
    end
    if not ok then
        return nil
    end

    local linesOk, lineCount = pcall(frame.NumLines, frame)
    if not linesOk then
        return nil
    end

    local lines = {}
    local count = math.min(tonumber(lineCount) or 0, MAX_TOOLTIP_LINES)
    for index = 1, count do
        local leftField = Globals["GuildweaverSpellScanTooltipTextLeft" .. index]
        local rightField = Globals["GuildweaverSpellScanTooltipTextRight" .. index]
        local left = fontStringText(leftField)
        local right = fontStringText(rightField)
        if left or right then
            table.insert(lines, {
                left = left,
                right = right,
                leftColor = fontStringColor(leftField),
                rightColor = fontStringColor(rightField),
            })
        end
    end

    if type(frame.Hide) == "function" then
        pcall(frame.Hide, frame)
    end

    return #lines > 0 and { source = "GameTooltip", lines = lines } or nil
end

local function modernSpellMetadata(spellId)
    local spellApi = Globals.C_Spell
    if type(spellApi) ~= "table" then
        return {}
    end

    local result = {}
    if type(spellApi.GetSpellName) == "function" then
        local ok, value = pcall(spellApi.GetSpellName, spellId)
        if ok then result.name = cleanText(value) end
    end
    if type(spellApi.GetSpellTexture) == "function" then
        local ok, value = pcall(spellApi.GetSpellTexture, spellId)
        if ok then result.iconFileDataId = tonumber(value) end
    end
    if type(spellApi.GetSpellDescription) == "function" then
        local ok, value = pcall(spellApi.GetSpellDescription, spellId)
        if ok then result.description = cleanText(value) end
    end
    if type(spellApi.GetSpellLink) == "function" then
        local ok, value = pcall(spellApi.GetSpellLink, spellId)
        if ok then result.spellLink = cleanText(value) end
    end

    return result
end

local function legacySpellMetadata(spellId)
    local result = {}
    local getSpellInfo = Globals.GetSpellInfo
    if type(getSpellInfo) == "function" then
        local ok, name, _, icon = pcall(getSpellInfo, spellId)
        if ok then
            result.name = cleanText(name)
            result.iconFileDataId = tonumber(icon)
        end
    end

    local getSpellDescription = Globals.GetSpellDescription
    if type(getSpellDescription) == "function" then
        local ok, value = pcall(getSpellDescription, spellId)
        if ok then result.description = cleanText(value) end
    end

    local getSpellLink = Globals.GetSpellLink
    if type(getSpellLink) == "function" then
        local ok, value = pcall(getSpellLink, spellId)
        if ok then result.spellLink = cleanText(value) end
    end

    return result
end

local function resolveSpell(spellId)
    spellId = tonumber(spellId)
    if not spellId or spellId <= 0 then
        return nil
    end

    local modern = modernSpellMetadata(spellId)
    local legacy = legacySpellMetadata(spellId)
    return {
        spellId = spellId,
        name = modern.name or legacy.name,
        iconFileDataId = modern.iconFileDataId or legacy.iconFileDataId,
        description = modern.description or legacy.description,
        spellLink = modern.spellLink or legacy.spellLink,
        tooltip = collectModernTooltip(spellId) or collectLegacyTooltip(spellId),
    }
end

GW.SpellTelemetry = GW.SpellTelemetry or {}
GW.SpellTelemetry.Resolve = resolveSpell
