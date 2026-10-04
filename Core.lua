local addonName, GW = ...

GW.name = addonName
GW.version = C_AddOns.GetAddOnMetadata(addonName, "Version") or "dev"

local function normalizeCommand(message)
    local trimmed = (message or ""):match("^%s*(.-)%s*$")
    return string.lower(trimmed)
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon ~= addonName then
            return
        end

        GW.Store:Initialize()
        GW.MainFrame:Initialize()
        return
    end

    if event == "PLAYER_LOGIN" then
        GW:Print("v" .. GW.version .. " loaded. Type /gw to open.")
    end
end)

SLASH_GUILDWEAVER1 = "/guildweaver"
SLASH_GUILDWEAVER2 = "/gw"

SlashCmdList.GUILDWEAVER = function(message)
    local command = normalizeCommand(message)

    if command == "" then
        GW.MainFrame:Toggle()
        return
    end

    if command == "version" then
        GW:Print("Version " .. GW.version)
        return
    end

    if command == "reset" then
        GW.MainFrame:ResetPosition()
        GW:Print("Window position reset.")
        return
    end

    if command == "help" then
        GW:Print("/gw opens Guildweaver. /gw version shows the addon version. /gw reset resets the window position.")
        return
    end

    GW:Print("Unknown command. Try /gw help.")
end
