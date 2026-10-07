local _, GW = ...

local Globals = _G or {}

local function compact(value)
    if type(value) ~= "table" then return value end
    for key, child in pairs(value) do
        if type(child) == "table" then
            compact(child)
            if next(child) == nil then value[key] = nil end
        end
    end
    return value
end

local originalCapture = GW.CharacterStats and GW.CharacterStats.Capture
local safeNumber = GW.CharacterStats and GW.CharacterStats.SafeNumber

local function number(value)
    if type(safeNumber) ~= "function" then
        return nil
    end
    return safeNumber(value)
end

local function capture()
    -- Stats are useful enrichment, never a reason to abort the authoritative
    -- character snapshot. Any client/API surprise degrades to partial stats.
    local ok, snapshot = pcall(function()
        return type(originalCapture) == "function" and originalCapture() or { schemaVersion = 1 }
    end)
    if not ok or type(snapshot) ~= "table" then
        snapshot = { schemaVersion = 1 }
    end

    snapshot.utility = type(snapshot.utility) == "table" and snapshot.utility or {}

    local getAverageItemLevel = Globals.GetAverageItemLevel
    if type(getAverageItemLevel) == "function" then
        local callOk, overall, equipped, pvp = pcall(getAverageItemLevel)
        if callOk then
            local overallValue = number(overall)
            local equippedValue = number(equipped)
            local pvpValue = number(pvp)
            if overallValue or equippedValue or pvpValue then
                snapshot.utility.itemLevel = {
                    overall = overallValue,
                    equipped = equippedValue,
                    pvp = pvpValue,
                }
            end
        end
    end

    return compact(snapshot)
end

GW.CharacterStats = GW.CharacterStats or {}
GW.CharacterStats.Capture = capture
