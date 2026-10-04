local _, GW = ...

GW.Store = GW.Store or {}

local defaults = {
    schemaVersion = 1,
    ui = {
        mainFrame = {
            point = "CENTER",
            relativePoint = "CENTER",
            x = 0,
            y = 0,
        },
    },
}

local function applyDefaults(source, target)
    for key, value in pairs(source) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then
                target[key] = {}
            end
            applyDefaults(value, target[key])
        elseif target[key] == nil then
            target[key] = value
        end
    end
end

function GW.Store:Initialize()
    if type(GuildweaverDB) ~= "table" then
        GuildweaverDB = {}
    end

    applyDefaults(defaults, GuildweaverDB)

    GuildweaverDB.meta = GuildweaverDB.meta or {}
    GuildweaverDB.meta.addonVersion = GW.version
end

function GW.Store:GetDatabase()
    return GuildweaverDB
end

function GW.Store:GetMainFramePosition()
    return GuildweaverDB.ui.mainFrame
end

function GW.Store:SetMainFramePosition(point, relativePoint, x, y)
    local position = GuildweaverDB.ui.mainFrame
    position.point = point
    position.relativePoint = relativePoint
    position.x = x
    position.y = y
end

function GW.Store:ResetMainFramePosition()
    local position = GuildweaverDB.ui.mainFrame
    position.point = defaults.ui.mainFrame.point
    position.relativePoint = defaults.ui.mainFrame.relativePoint
    position.x = defaults.ui.mainFrame.x
    position.y = defaults.ui.mainFrame.y
end
