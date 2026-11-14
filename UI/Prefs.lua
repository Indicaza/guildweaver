local _, GW = ...

-- Interface preferences, saved per account under GuildweaverDB.ui. These
-- only decide what is drawn: no preference here turns data collection off.
-- The dungeon HUD keeps its own table (ui.dungeonHud, see DungeonHud.lua)
-- and the window position stays in ui.mainFrame (Store).
GW.UiPrefs = GW.UiPrefs or {}

local Prefs = GW.UiPrefs

local DEFAULTS = {
    minimap = { hide = false, angle = 215 },
    dashboard = { view = "overview" },
}
Prefs.DEFAULTS = DEFAULTS

local function ui()
    local db = GW.Store and GW.Store.GetDatabase and GW.Store.GetDatabase()
    if type(db) ~= "table" then
        return nil
    end
    db.ui = type(db.ui) == "table" and db.ui or {}
    return db.ui
end

-- The table for a section with its defaults filled in; nil before the
-- database is loaded.
function Prefs.Get(section)
    local root = ui()
    local defaults = DEFAULTS[section]
    if not root or not defaults then
        return nil
    end
    local value = type(root[section]) == "table" and root[section] or {}
    for key, default in pairs(defaults) do
        if value[key] == nil then value[key] = default end
    end
    root[section] = value
    return value
end

function Prefs.MinimapHidden()
    local value = Prefs.Get("minimap")
    return value ~= nil and value.hide == true
end

function Prefs.SetMinimapHidden(hidden)
    local value = Prefs.Get("minimap")
    if value then value.hide = hidden == true end
    if GW.MinimapButton and GW.MinimapButton.Refresh then
        GW.MinimapButton:Refresh()
    end
end

function Prefs.MinimapAngle()
    local value = Prefs.Get("minimap")
    return value and tonumber(value.angle) or DEFAULTS.minimap.angle
end

function Prefs.SetMinimapAngle(angle)
    local value = Prefs.Get("minimap")
    if value and tonumber(angle) then value.angle = math.floor(tonumber(angle) * 10 + 0.5) / 10 % 360 end
end

function Prefs.LastView()
    local value = Prefs.Get("dashboard")
    return value and value.view or DEFAULTS.dashboard.view
end

function Prefs.SetLastView(view)
    local value = Prefs.Get("dashboard")
    if value then value.view = view end
end
