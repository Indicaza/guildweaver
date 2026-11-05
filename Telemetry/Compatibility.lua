local _, GW = ...

if not GW.Character or type(GW.Character.Capture) ~= "function" then
    return
end

local originalCapture = GW.Character.Capture

GW.Character.Capture = function(...)
    local perf = GW.Perf
    local started = perf and perf.Begin and perf.Begin() or nil
    local snapshot = originalCapture(...)
    if type(snapshot) == "table" and GW.Telemetry and type(GW.Telemetry.PublishCharacterSnapshot) == "function" then
        GW.Telemetry.PublishCharacterSnapshot(snapshot)
    end
    if perf and perf.End then
        perf.End("character_capture", started)
    end
    return snapshot
end