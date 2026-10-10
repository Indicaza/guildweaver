local _, GW = ...

GW.TelemetryDomains = GW.TelemetryDomains or {}

GW.TelemetryDomains.Character = GW.TelemetryDomain.Define({
    name = "Character",
    eventType = "character",
    payloadSchemaVersion = 1,
    capture = function(snapshot)
        snapshot = type(snapshot) == "table" and snapshot or {}
        return {
            characterKey = snapshot.characterKey,
            name = snapshot.name,
            firstName = snapshot.firstName,
            lastName = snapshot.lastName,
            fullName = snapshot.fullName,
            gameBuild = snapshot.gameBuild,
            addonVersion = snapshot.addonVersion,
            realm = snapshot.realm,
            region = snapshot.region,
            level = snapshot.level,
            sex = snapshot.sex,
            bodyType = snapshot.bodyType,
            race = snapshot.race,
            class = snapshot.class,
            guild = snapshot.guild,
            specialization = snapshot.specialization,
        }
    end,
})