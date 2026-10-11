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

local now = 5100
local elapsed = 90
local eventFrame = nil

GuildweaverDB = nil
GetServerTime = function() return now end
_G.GetTime = function() return elapsed end
UnitLevel = function() return 18 end
_G.GetRealZoneText = function() return "Dun Morogh" end
_G.GetSubZoneText = function() return "Gol'Bolar Quarry" end
_G.GetNumLootItems = function() return 3 end
_G.GetLootSlotInfo = function(slot)
    if slot == 1 then
        return 134566, "Copper Ore", 3, nil, 1
    end
    if slot == 2 then
        return 135242, "Rough Stone", 2, nil, 1
    end
    return 134106, "Malachite", 1, nil, 2
end
_G.GetLootSlotLink = function(slot)
    if slot == 1 then
        return "|Hitem:2770::::::::|h[Copper Ore]|h"
    end
    if slot == 2 then
        return "|Hitem:2835::::::::|h[Rough Stone]|h"
    end
    return "|Hitem:774::::::::|h[Malachite]|h"
end
_G.GetLootSourceInfo = function()
    return "GameObject-0-1-2-3-1731-000001", 1
end
_G.C_Map = {
    GetBestMapForUnit = function() return 1426 end,
    GetPlayerMapPosition = function()
        return { GetXY = function() return 0.51, 0.42 end }
    end,
}
_G.C_Spell = {
    GetSpellInfo = function(spellId)
        return { name = spellId == 2575 and "Mining" or "Other" }
    end,
}
CreateFrame = function()
    local frame = { events = {} }
    function frame:RegisterEvent(event)
        self.events[event] = true
    end
    function frame:SetScript(kind, fn)
        if kind == "OnEvent" then
            self.onEvent = fn
        end
    end
    eventFrame = frame
    return frame
end

local GW = { version = "test" }
assert(loadfile("Data/Store.lua"))("Guildweaver", GW)
GW.Store.Initialize()
assert(loadfile("Data/TelemetryEnvelope.lua"))("Guildweaver", GW)

GW.Character = {
    GetCurrentSnapshot = function()
        return {
            characterId = "character-1",
            realm = "Realm",
            region = "US",
            gameBuild = { build = "70338" },
            level = 18,
        }
    end,
}
GW.ProfessionTelemetry = {
    CollectProfessions = function()
        return {
            {
                skillLineId = 186,
                name = "Mining",
                skillLevel = 48,
                maxSkillLevel = 150,
                skillModifier = 5,
            },
        }
    end,
}

assert(loadfile("Data/GatheringTelemetry.lua"))("Guildweaver", GW)
assert(loadfile("Systems/MiningCapture.lua"))("Guildweaver", GW)
truthy(eventFrame, "event frame")

eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SENT", "player", "Copper Vein", "Cast-Mine-1", 2575)
truthy(GW.MiningCapture.pending, "pending mining cast")

now = 5101
elapsed = 91
eventFrame.onEvent(eventFrame, "LOOT_OPENED")
equal(GW.MiningCapture.pending, nil, "pending cleared after capture")

local records = {}
for _, record in pairs(GuildweaverDB.sync.outbound.telemetry) do
    table.insert(records, record)
end
equal(#records, 1, "one mining event")

local record = records[1]
equal(record.kind, "event", "event kind")
equal(record.envelope.eventType, "gathering_loot", "event type")
local payload = record.envelope.payload
equal(payload.discipline, "mining", "discipline")
equal(payload.activity, "harvest", "activity")
equal(payload.source.kind, "ore_vein", "source kind")
equal(payload.source.name, "Copper Vein", "source name")
equal(payload.source.objectId, 1731, "source object id")
equal(payload.outputs[1].itemId, 2770, "ore item")
equal(payload.outputs[1].quantity, 3, "ore quantity")
equal(payload.outputs[2].itemId, 2835, "stone item")
equal(payload.outputs[2].quantity, 2, "stone quantity")
equal(payload.outputs[3].itemId, 774, "gem item")
equal(payload.context.characterLevel, 18, "character level")
equal(payload.context.profession.skillLineId, 186, "mining skill line")
equal(payload.context.profession.skillLevel, 48, "mining skill")
equal(payload.context.profession.skillModifier, 5, "mining modifier")
equal(payload.context.modifiers, nil, "herbalism modifiers omitted")
equal(payload.context.location.zone, "Dun Morogh", "zone")
equal(payload.context.location.mapId, 1426, "map id")
equal(payload.context.location.x, 0.51, "map x")
equal(payload.context.location.y, 0.42, "map y")
truthy(payload.observationId, "observation id")

eventFrame.onEvent(eventFrame, "LOOT_READY")
local count = 0
for _ in pairs(GuildweaverDB.sync.outbound.telemetry) do
    count = count + 1
end
equal(count, 1, "duplicate loot event suppressed")

print("mining gathering telemetry tests passed")
