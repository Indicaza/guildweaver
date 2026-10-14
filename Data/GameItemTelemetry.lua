local _, GW = ...
local Globals = _G or {}
GW.GameItemTelemetry = GW.GameItemTelemetry or {}
local complete = {}
local pending = {}

function GW.GameItemTelemetry.Publish(itemId)
    itemId = tonumber(itemId)
    if not itemId or itemId <= 0 or complete[itemId] then return nil end
    local telemetry = GW.ItemTelemetry
    if not telemetry or type(telemetry.BaseDefinition) ~= "function" then return nil end
    local ok, item = pcall(telemetry.BaseDefinition, itemId)
    if not ok or type(item) ~= "table" or not item.name or not telemetry.IsFullTooltip(item.tooltip) then
        pending[itemId] = true
        local api = Globals.C_Item
        if type(api) == "table" and type(api.RequestLoadItemDataByID) == "function" then
            pcall(api.RequestLoadItemDataByID, itemId)
        end
        return nil
    end
    local snapshot = GW.Character and GW.Character.GetCurrentSnapshot and GW.Character.GetCurrentSnapshot() or {}
    local envelope = GW.TelemetryEnvelope.Build("game_item_definition", {
        schemaVersion = 1,
        basis = "base_item_id",
        reference = "item:" .. tostring(itemId),
        item = item,
    }, { gameBuild = snapshot.gameBuild })
    if not envelope then return nil end
    local changed = GW.Store.SetTelemetrySnapshot("game_item_definition:item:" .. tostring(itemId), envelope)
    complete[itemId] = true
    pending[itemId] = nil
    return changed
end

if type(Globals.CreateFrame) == "function" then
    local frame = Globals.CreateFrame("Frame")
    pcall(frame.RegisterEvent, frame, "GET_ITEM_INFO_RECEIVED")
    pcall(frame.RegisterEvent, frame, "ITEM_DATA_LOAD_RESULT")
    frame:SetScript("OnEvent", function(_, _, itemId, success)
        itemId = tonumber(itemId)
        if success ~= false and itemId and pending[itemId] then
            pcall(GW.GameItemTelemetry.Publish, itemId)
        end
    end)
end
