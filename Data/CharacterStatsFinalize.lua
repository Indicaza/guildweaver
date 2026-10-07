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

local function capture()
    local snapshot = type(originalCapture) == "function" and originalCapture() or { schemaVersion = 1 }
    snapshot.utility = type(snapshot.utility) == "table" and snapshot.utility or {}

    local getAverageItemLevel = Globals.GetAverageItemLevel
    if type(getAverageItemLevel) == "function" then
        local ok, overall, equipped, pvp = pcall(getAverageItemLevel)
        if ok and (tonumber(overall) or tonumber(equipped) or tonumber(pvp)) then
            snapshot.utility.itemLevel = {
                overall = tonumber(overall),
                equipped = tonumber(equipped),
                pvp = tonumber(pvp),
            }
        end
    end

    return compact(snapshot)
end

GW.CharacterStats = GW.CharacterStats or {}
GW.CharacterStats.Capture = capture
