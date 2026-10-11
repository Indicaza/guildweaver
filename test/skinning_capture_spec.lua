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

local now = 4100
local elapsed = 75
local eventFrame = nil

GuildweaverDB = nil
GetServerTime = function() return now end
_G.GetTime = function() return elapsed end
UnitLevel = function() return 24 end
_G.GetRealZoneText = function() return "Wetlands" end
_G.GetSubZoneText = function() return "Bluegill Marsh" end
_G.GetNumLootItems = function() return 2 end
_G.GetLootSlotInfo = function(slot)
    if slot == 1 then
        return 134252, "Light Leather", 2, nil, 1
    end
    return 134365, "Light Hide", 1, nil, 1
end
_G.GetLootSlotLink = function(slot)
    if slot == 1 then
        return "|Hitem:2318::::::::|h[Light Leather]|h"
    end
    return "|Hitem:783::::::::|h[Light Hide]|h"
end
_G.GetLootSourceInfo = function()
    return "Creature-0-1-2-3-12345-000001", 1
end
_G.C_Map = {
    GetBestMapForUnit = function() return 1437 end,
    GetPlayerMapPosition = function()
        return { GetXY = function() return 0.37, 0.61 end }
    end,
}
_G.C_Spell = {
    GetSpellInfo = function(spellId)
        return { name = spellId == 8613 and "Skinning" or "Other" }
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
            level = 24,
        }
    end,
}
GW.ProfessionTelemetry = {
    CollectProfessions = function()
        return {
            {
                skillLineId = 393,
                name = "Skinning",
                skillLevel = 92,
                maxSkillLevel = 150,
                skillModifier = 5,
            },
        }
    end,
}

assert(loadfile("Data/GatheringTelemetry.lua"))("Guildweaver", GW)
assert(loadfile("Systems/SkinningCapture.lua"))("Guildweaver", GW)
truthy(eventFrame, "event frame")

eventFrame.onEvent(eventFrame, "UNIT_SPELLCAST_SENT", "player", "Young Crocolisk", "Cast-Skin-1", 8613)
truthy(GW.SkinningCapture.pending, "pending skinning cast")

now = 4101
elapsed = 76
eventFrame.onEvent(eventFrame, "LOOT_OPENED")
equal(GW.SkinningCapture.pending, nil, "pending cleared after capture")

local records = {}
for _, record in pairs(GuildweaverDB.sync.outbound.telemetry) do
    table.insert(records, record)
end
equal(#records, 1, "one skinning event")

local record = records[1]
equal(record.kind, "event", "event kind")
equal(record.envelope.eventType, "gathering_loot", "event type")
local payload = record.envelope.payload
equal(payload.discipline, "skinning", "discipline")
equal(payload.activity, "harvest", "activity")
equal(payload.source.kind, "creature", "source kind")
equal(payload.source.name, "Young Crocolisk", "source name")
equal(payload.source.npcId, 12345, "source npc id")
equal(payload.outputs[1].itemId, 2318, "leather item")
equal(payload.outputs[1].quantity, 2, "leather quantity")
equal(payload.outputs[2].itemId, 783, "hide item")
equal(payload.context.characterLevel, 24, "character level")
equal(payload.context.profession.skillLineId, 393, "skinning skill line")
equal(payload.context.profession.skillLevel, 92, "skinning skill")
equal(payload.context.profession.skillModifier, 5, "skinning modifier")
equal(payload.context.modifiers, nil, "herbalism modifiers omitted")
equal(payload.context.location.mapId, 1437, "map id")
equal(payload.context.location.x, 0.37, "map x")
equal(payload.context.location.y, 0.61, "map y")
truthy(payload.observationId, "observation id")

eventFrame.onEvent(eventFrame, "LOOT_READY")
local count = 0
for _ in pairs(GuildweaverDB.sync.outbound.telemetry) do
    count = count + 1
end
equal(count, 1, "duplicate loot event suppressed")

print("skinning gathering telemetry tests passed")
