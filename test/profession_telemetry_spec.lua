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

GuildweaverDB = nil
GetServerTime = function() return 2000 end
GetCurrentRegion = function() return 1 end
GetBuildInfo = function() return "1.60.1", "60001", "Oct 6 2026", 16001 end
UnitFullName = function() return "Bran", "Realm" end
UnitName = function() return "Bran" end
GetRealmName = function() return "Realm" end
UnitLevel = function() return 30 end
GetGuildInfo = function() return "Holdfast", "Private", 8, "Realm" end
GetProfessions = function() return nil, 2, nil, 4, 5 end
GetProfessionInfo = function(index)
    if index == 2 then
        return "Alchemy", 100, 150, 225, nil, nil, 171, 7, nil, nil, "Alchemy"
    end
    if index == 4 then
        return "Fishing", 200, 75, 150, nil, nil, 356, 0, nil, nil, "Fishing"
    end
    if index == 5 then
        return "Cooking", 300, 100, 150, nil, nil, 185, 0, nil, nil, "Cooking"
    end
end
C_ProfSpecs = nil
C_Traits = nil

local GW = { version = "test" }
assert(loadfile("Data/Store.lua"))("Guildweaver", GW)

GW.Character = {
    GetCurrentSnapshot = function()
        return {
            level = 30,
            specialization = { name = "Restoration" },
            talents = { api = "traits" },
            professions = {
                {
                    id = 171,
                    name = "Alchemy",
                    recipeSnapshotAt = 1999,
                    recipeSource = "C_TradeSkillUI",
                    recipes = {
                        { id = 1001, name = "Mock Potion", known = true, craftedItemId = 2001 },
                        { id = 1002, name = "Unknown Formula", known = false },
                    },
                },
            },
        }
    end,
}

assert(loadfile("Systems/ProfessionTelemetry.lua"))("Guildweaver", GW)
GW.Store.Initialize()

local payload = GW.ProfessionTelemetry.Capture("TEST")
truthy(payload, "profession payload")
equal(#payload.professions, 3, "profession count across nil slots")
equal(payload.professions[1].name, "Alchemy", "second primary profession")
equal(payload.professions[1].kind, "primary", "second primary kind")
equal(payload.professions[1].skillLevel, 150, "profession skill")
equal(payload.professions[1].maxSkillLevel, 225, "profession max skill")
equal(payload.professions[1].skillModifier, 7, "profession modifier")
equal(payload.professions[1].knownRecipeCount, 1, "known recipe count")
equal(payload.professions[2].name, "Fishing", "fishing survives nil gaps")
equal(payload.professions[3].name, "Cooking", "cooking survives nil gaps")

local professionStream = GuildweaverDB.sync.outbound.telemetry[
    "profession_snapshot:" .. payload.characterId
]
truthy(professionStream, "profession telemetry stream")
equal(professionStream.envelope.eventType, "profession_snapshot", "profession event type")

local recipeStream = GuildweaverDB.sync.outbound.telemetry[
    "recipe_catalog_snapshot:" .. payload.characterId .. ":171"
]
truthy(recipeStream, "recipe catalog telemetry stream")
equal(recipeStream.envelope.eventType, "recipe_catalog_snapshot", "recipe event type")
equal(recipeStream.envelope.payload.recipes[1].id, 1001, "recipe catalog payload")

local diagnostics = GW.ProfessionTelemetry.GetDiagnostics()
equal(diagnostics.level, 30, "diagnostic level")
equal(diagnostics.specialization.name, "Restoration", "diagnostic specialization")
equal(diagnostics.professionCount, 3, "diagnostic profession count")
equal(diagnostics.knownRecipeCount, 1, "diagnostic recipe count")

print("profession telemetry tests passed")
