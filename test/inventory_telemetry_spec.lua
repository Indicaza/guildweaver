local function equal(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function truthy(value, label)
    if not value then
        error((label or "value") .. ": expected truthy value", 2)
    end
end

local now = 5000
local copperCount = 7

GuildweaverDB = nil
NUM_BAG_SLOTS = 1
GetServerTime = function() return now end
GetCurrentRegion = function() return 1 end
GetBuildInfo = function() return "1.60.1", "60001", "Oct 6 2026", 16001 end
UnitFullName = function() return "Rook", "Realm" end
UnitName = function() return "Rook" end
GetRealmName = function() return "Realm" end
GetGuildInfo = function() return "Holdfast", "Private", 8, "Realm" end
C_Container = {
    GetContainerNumSlots = function(bag)
        if bag == 0 then return 2 end
        if bag == 1 then return 2 end
        return 0
    end,
    GetContainerItemInfo = function(bag, slot)
        if bag == 0 and slot == 1 then
            return {
                itemID = 2840,
                hyperlink = "|cffffffff|Hitem:2840::::::::30:::::::|h[Copper Bar]|h|r",
                iconFileID = 133216,
                stackCount = copperCount,
                quality = 1,
                isBound = false,
            }
        end
        if bag == 0 and slot == 2 then
            return {
                itemID = 2840,
                hyperlink = "|cffffffff|Hitem:2840::::::::30:::::::|h[Copper Bar]|h|r",
                iconFileID = 133216,
                stackCount = 3,
                quality = 1,
                isBound = true,
            }
        end
        if bag == 1 and slot == 1 then
            return {
                itemID = 765,
                hyperlink = "|cffffffff|Hitem:765::::::::30:::::::|h[Silverleaf]|h|r",
                iconFileID = 134190,
                stackCount = 5,
                quality = 1,
                isBound = false,
            }
        end
        return nil
    end,
}

local GW = { version = "test" }
assert(loadfile("Data/Store.lua"))("Guildweaver", GW)
assert(loadfile("Systems/InventoryTelemetry.lua"))("Guildweaver", GW)
GW.Store.Initialize()

local payload = GW.InventoryTelemetry.Capture("TEST")
truthy(payload, "inventory payload")
equal(payload.scope, "carried_bags", "inventory scope")
equal(#payload.bags, 2, "bag count")
equal(payload.bags[1].used, 2, "backpack used slots")
equal(payload.bags[2].free, 1, "bag free slots")
equal(#payload.items, 2, "aggregated item count")
equal(payload.items[1].itemId, 765, "sorted first item")
equal(payload.items[1].count, 5, "silverleaf count")
equal(payload.items[2].itemId, 2840, "sorted copper item")
equal(payload.items[2].count, 10, "copper aggregate count")
equal(payload.items[2].stacks, 2, "copper stacks")
equal(payload.items[2].boundCount, 3, "bound copper count")
equal(payload.items[2].unboundCount, 7, "unbound copper count")

local characterId = GW.Store.GetCharacterId("realm:rook")
local streamKey = "inventory_snapshot:" .. characterId
local stream = GuildweaverDB.sync.outbound.telemetry[streamKey]
truthy(stream, "inventory telemetry stream")
equal(stream.revision, 1, "initial inventory revision")
equal(stream.envelope.eventType, "inventory_snapshot", "inventory event type")

now = now + 1
GW.InventoryTelemetry.Capture("UNCHANGED")
equal(GuildweaverDB.sync.outbound.telemetry[streamKey].revision, 1, "unchanged inventory revision")

copperCount = 8
now = now + 1
GW.InventoryTelemetry.Capture("BAG_UPDATE_DELAYED")
equal(GuildweaverDB.sync.outbound.telemetry[streamKey].revision, 2, "changed inventory revision")
equal(GuildweaverDB.sync.outbound.telemetry[streamKey].envelope.payload.items[2].count, 11, "updated aggregate count")

print("inventory telemetry tests passed")
