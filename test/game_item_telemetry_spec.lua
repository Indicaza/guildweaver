local events = {}
local record
local ready = false
_G.GetServerTime = function() return 1000 end
_G.GetLocale = function() return "deDE" end
_G.CreateFrame = function() return { RegisterEvent = function() end, SetScript = function(_, _, fn) events[#events + 1] = fn end } end
_G.C_Item = { RequestLoadItemDataByID = function(id) assert(id == 2589) end }
local GW = { version = "test", Character = { GetCurrentSnapshot = function() return { gameBuild = { build = "70338" } } end },
    Store = { SetTelemetrySnapshot = function(key, envelope) record = { key = key, envelope = envelope }; return true end } }
assert(loadfile("Data/TelemetryEnvelope.lua"))("Guildweaver", GW)
GW.ItemTelemetry = {
    BaseDefinition = function(id)
        assert(type(id) == "number" and id == 2589)
        return { itemId = id, name = "Linen Cloth", tooltip = { complete = ready, lines = { { left = "Linen Cloth" } } } }
    end,
    IsFullTooltip = function(tooltip) return tooltip.complete end,
}
assert(loadfile("Data/GameItemTelemetry.lua"))("Guildweaver", GW)
assert(GW.GameItemTelemetry.Publish(2589) == nil)
assert(record == nil)
ready = true
events[1](nil, "GET_ITEM_INFO_RECEIVED", 2589, true)
assert(record.envelope.eventType == "game_item_definition")
assert(record.envelope.payload.basis == "base_item_id")
assert(record.envelope.payload.reference == "item:2589")
assert(record.envelope.characterId == nil)
assert(record.envelope.locale == "deDE")
assert(GW.GameItemTelemetry.Publish(2589) == nil)
print("base game item telemetry tests passed")
