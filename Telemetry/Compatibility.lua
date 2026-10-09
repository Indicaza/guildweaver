local _, GW = ...

if not GW.Character or type(GW.Character.Capture) ~= "function" then
    return
end

local originalCapture = GW.Character.Capture

GW.Character.Capture = function(...)
    local snapshot = originalCapture(...)
    if type(snapshot) == "table" and GW.Telemetry and type(GW.Telemetry.PublishCharacterSnapshot) == "function" then
        GW.Telemetry.PublishCharacterSnapshot(snapshot)
    end
    return snapshot
end