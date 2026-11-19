local _, GW = ...

GW.TelemetryDomains = GW.TelemetryDomains or {}

-- quest_state: the character's World of Warcraft quest state, one stream
-- per character (quest_state:<characterId>, exactly as Holdfast checks it).
-- Systems/CharacterQuests.lua captures it and publishes it with
-- PublishPrepared and a fingerprint of the content (capturedAt left out),
-- so an unchanged state is never stored or sent again.
GW.TelemetryDomains.QuestState = GW.TelemetryDomain.Define({
    name = "QuestState",
    eventType = "quest_state",
    payloadSchemaVersion = 1,
    streamKey = function(snapshot)
        local characterId = type(snapshot) == "table" and snapshot.characterId or nil
        return characterId and ("quest_state:" .. tostring(characterId)) or nil
    end,
    capture = function(snapshot)
        return type(snapshot) == "table" and snapshot.questPayload or nil
    end,
})
