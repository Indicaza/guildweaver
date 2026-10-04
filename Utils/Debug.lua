local _, GW = ...

GW.Debug = GW.Debug or {}

local prefix = "|cffffd100Guildweaver|r"

function GW.Print(message)
    DEFAULT_CHAT_FRAME:AddMessage(prefix .. ": " .. tostring(message))
end

function GW.Debug.Dump(label, value)
    GW.Print(tostring(label) .. " = " .. tostring(value))
end
