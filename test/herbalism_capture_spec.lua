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

local now = 3100
local elapsed = 50
local eventFrame = nil

GuildweaverDB = nil
GetServerTime = function() return now end
GetTime = function() return elapsed end
UnitLevel = function() return 30 end
GetRealZoneText = function() return "Duskwood" end
GetSubZoneText = function() return "The Rotting Orchard" end
GetNumLootItems = function() return 2 end
GetLootSlotInfo = function(slot)
    if slot == 1 then
        return 134183, "Peacebloom", 2, nil, 1
    end
    return 134419, "Frilled Lichen", 1, nil, 2
end
GetLootSlotLink = function(slot)
    if slot == 1 then
        return "|Hitem:2447::::::::|h[Peacebloom]|h"
    end
    return "|Hitem:249399::::::::|h[Frilled Lichen]|h"
end
GetLootSourceInfo = function()
    return "GameObject-0-1-2-3-1618-000001", 1
end
C_Map = {
    GetBestMapForUnit = function() return 1431 end,
    GetPlayerMapPosition = function()
        return { GetXY = function() return 0.42, 0.58 end }
    end,
}
C_Spell = {
    GetSpellInfo = function(spellId)
        return { name = spellId == 2366 and "Herbalism" or "Other" }
    end,
}
Enum = { TraitConfigType = { Legacy = 7 } }
C_Traits = {
    GetConfigsByType = function() return { 77 } end,
    GetConfigInfo = function() return { name = "Legacy Professions", treeIDs = { 88 } } end,
    GetTreeNodes = function() return { 99 } end,
    GetNodeInfo = function()
        return { entryIDs = { 100 }, ranksPurchased = 3, maxRanks = 5 }
    end,
    GetEntryInfo = function() return { definitionID = 101, maxRanks = 5 } end,
    GetDefinitionInfo = function() return { spellID = 1225435 } end,
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
            level = 30,
        }
    end,
}
GW.ProfessionTelemetry = {
    CollectProfessions = function()
        return {
            {
                skillLineId = 182,
                name = "Herbalism",
                skillLevel = 87,
                maxSkillLevel = 150,
                skillModifier = 5,
            },
        }
    end,
}

assert(loadfile("Data/GatheringTelemetry.lua"))("Guildweaver", GW)
assert(loadfile("Systems/HerbalismCapture.lua"))("Guildweaver", GW)
truthy(eventFrame, "event frame")

eventFrame.onEvent(eventFrame, "PLAYER_LOGIN")
eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SENT", "player", "Peacebloom", "Cast-1", 2366)
truthy(GW.HerbalismCapture.pending, "pending herb cast")

now = 3101
elapsed = 51
eventFrame.onEvent(eventFrame, "LOOT_OPENED")
equal(GW.HerbalismCapture.pending, nil, "pending cleared after capture")

local records = {}
for _, record in pairs(GuildweaverDB.sync.outbound.telemetry) do
    table.insert(records, record)
end
equal(#records, 1, "one gathering event")

local record = records[1]
equal(record.kind, "event", "event kind")
equal(record.envelope.eventType, "gathering_loot", "event type")
local payload = record.envelope.payload
equal(payload.discipline, "herbalism", "discipline")
equal(payload.source.name, "Peacebloom", "source name")
equal(payload.source.objectId, 1618, "source object id")
equal(payload.outputs[1].itemId, 2447, "common herb item")
equal(payload.outputs[1].quantity, 2, "common herb quantity")
equal(payload.outputs[2].itemId, 249399, "rare herb item")
equal(payload.context.characterLevel, 30, "character level")
equal(payload.context.profession.skillLevel, 87, "herbalism skill")
equal(payload.context.profession.skillModifier, 5, "herbalism modifier")
equal(payload.context.modifiers.bountifulHarvest.rank, 3, "bountiful harvest rank")
equal(payload.context.location.mapId, 1431, "map id")
equal(payload.context.location.x, 0.42, "map x")
equal(payload.context.location.y, 0.58, "map y")
truthy(payload.observationId, "observation id")

eventFrame.onEvent(eventFrame, "LOOT_READY")
local count = 0
for _ in pairs(GuildweaverDB.sync.outbound.telemetry) do
    count = count + 1
end
equal(count, 1, "duplicate loot event suppressed")

print("herbalism gathering telemetry tests passed")
