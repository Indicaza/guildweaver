local GW = {}
local x, y = 0, 1
_G.C_Map = {
    GetBestMapForUnit = function() return 1431 end,
    GetPlayerMapPosition = function() return { GetXY = function() return x, y end } end,
}
assert(loadfile("Data/GatheringTelemetry.lua"))("Guildweaver", GW)
local point = GW.GatheringTelemetry.CurrentLocation()
assert(point.x == 0 and point.y == 1)
assert(point.positionKind == "player_at_cast" and point.coordinateSystem == "ui_map_normalized")
x, y = 0.1234567, 0.8765432
point = GW.GatheringTelemetry.CurrentLocation()
assert(point.x == 0.12346 and point.y == 0.87654)
for _, invalid in ipairs({ -0.1, 1.1, math.huge, 0 / 0 }) do
    x = invalid
    point = GW.GatheringTelemetry.CurrentLocation()
    assert(point.x == nil and point.y == nil)
end
_G.C_Map.GetPlayerMapPosition = function() return nil end
point = GW.GatheringTelemetry.CurrentLocation()
assert(point.mapId == 1431 and point.x == nil and point.y == nil)
_G.C_Map = nil
point = GW.GatheringTelemetry.CurrentLocation()
assert(point.mapId == nil and point.x == nil and point.y == nil)
print("gathering map coordinates tests passed")
