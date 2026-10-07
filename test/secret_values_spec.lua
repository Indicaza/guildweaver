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

local Globals = _G
local SECRET = {}
local builtinTonumber = tonumber

-- Approximate the Forever secret-value contract in plain Lua: callers can ask
-- whether a value is accessible, but trying to coerce our sentinel is fatal.
Globals.canaccessvalue = function(value)
    return value ~= SECRET
end
Globals.issecretvalue = function(value)
    return value == SECRET
end
Globals.tonumber = function(value, base)
    if value == SECRET then
        error("simulated secret value was inspected")
    end
    return builtinTonumber(value, base)
end

Globals.UnitHealth = function() return SECRET end
Globals.UnitHealthMax = function() return 1050 end
Globals.UnitPowerType = function() return SECRET, SECRET end
Globals.UnitPower = function() return SECRET end
Globals.UnitPowerMax = function() return 100 end
Globals.GetPowerRegen = function() return SECRET, 1.25 end
Globals.GetManaRegen = function() return 8, SECRET end

Globals.UnitStat = function(_, id)
    if id == 1 then return SECRET, 72, 5, -2 end
    if id == 2 then return 38, SECRET, 5, 0 end
    return 0, 0, 0, 0
end

Globals.UnitAttackPower = function() return SECRET, 12, -4 end
Globals.UnitRangedAttackPower = function() return 55, 3, 0 end
Globals.UnitDamage = function() return SECRET, 34.75, 10, 16, 2, -1, 1 end
Globals.UnitRangedDamage = function() return 2.6, 15, 24, 1, 0, 1 end
Globals.UnitAttackSpeed = function() return SECRET, 1.8 end
Globals.GetCritChance = function() return SECRET end
Globals.GetRangedCritChance = function() return 9.25 end
Globals.GetHitModifier = function() return 3 end
Globals.GetRangedHitModifier = function() return SECRET end
Globals.GetMeleeHaste = function() return 4.5 end
Globals.GetRangedHaste = function() return 1.5 end
Globals.GetExpertise = function() return SECRET, 4, 0 end
Globals.GetExpertisePercent = function() return 1.5, 1 end
Globals.GetArmorPenetration = function() return SECRET end

Globals.GetSpellBonusDamage = function(school) return school == 3 and SECRET or 0 end
Globals.GetSpellCritChance = function(school) return school == 3 and 6.5 or 0 end
Globals.GetSpellBonusHealing = function() return SECRET end
Globals.GetSpellHitModifier = function() return 2.25 end
Globals.GetSpellPenetration = function() return SECRET end
Globals.UnitSpellHaste = function() return 3.5 end

Globals.UnitArmor = function() return SECRET, 1297, 1297, 197, 0 end
Globals.UnitResistance = function(_, school)
    if school == 2 then return SECRET, 15, 15, 0 end
    return 0, 0, 0, 0
end
Globals.UnitDefense = function() return SECRET, 4 end
Globals.GetDodgeChance = function() return SECRET end
Globals.GetParryChance = function() return 6.25 end
Globals.GetBlockChance = function() return 5 end
Globals.GetShieldBlock = function() return SECRET end
Globals.GetAvoidance = function() return 2.5 end

Globals.CR_HIT_MELEE = 6
Globals.CR_RESILIENCE_PLAYER_DAMAGE_TAKEN = 15
Globals.GetCombatRating = function(id)
    if id == 6 then return SECRET end
    return id * 10
end
Globals.GetCombatRatingBonus = function(id)
    if id == 15 then return SECRET end
    return id / 2
end

Globals.GetNumSkillLines = function() return 1 end
Globals.GetSkillLineInfo = function()
    return "Daggers", false, false, SECRET, 1, 2, 75
end

Globals.GetUnitSpeed = function() return SECRET, 7, 0, 4.722 end
Globals.GetSpeed = function() return SECRET end
Globals.GetAverageItemLevel = function() return SECRET, 48, SECRET end
Globals.UnitXP = function() return SECRET end
Globals.UnitXPMax = function() return 5000 end
Globals.GetXPExhaustion = function() return SECRET end
Globals.GetMasteryEffect = function() return SECRET end
Globals.GetVersatilityBonus = function() return 2 end
Globals.GetLifesteal = function() return SECRET end

local addon = {}
local function loadAddonFile(path)
    local chunk = assert(loadfile(path))
    return chunk("Guildweaver", addon)
end

loadAddonFile("Data/CharacterStats.lua")
loadAddonFile("Data/CharacterStatsFinalize.lua")

local ok, snapshot = pcall(addon.CharacterStats.Capture)
truthy(ok, "secret values do not abort stat capture")
equal(snapshot.schemaVersion, 1, "stat schema")

equal(snapshot.resources.health.current, nil, "secret health omitted")
equal(snapshot.resources.health.max, 1050, "accessible max health retained")
equal(snapshot.resources.power.current, nil, "secret power omitted")
equal(snapshot.resources.power.max, 100, "accessible max power retained")
equal(snapshot.resources.power.token, nil, "secret power token omitted")

equal(snapshot.attributes.strength.current, nil, "secret strength current omitted")
equal(snapshot.attributes.strength.effective, 72, "accessible strength effective retained")
equal(snapshot.attributes.agility.effective, nil, "secret agility effective omitted")
equal(snapshot.attributes.agility.current, 38, "accessible agility current retained")

equal(snapshot.offense.attackPower.base, nil, "secret attack power base omitted")
equal(snapshot.offense.attackPower.effective, 8, "accessible AP modifiers still combine")
equal(snapshot.offense.meleeDamage.min, nil, "secret melee minimum omitted")
equal(snapshot.offense.meleeDamage.max, 34.75, "accessible melee maximum retained")
equal(snapshot.offense.crit.melee, nil, "secret crit omitted")
equal(snapshot.offense.crit.ranged, 9.25, "accessible ranged crit retained")
equal(snapshot.offense.weaponSkills[1].current, nil, "secret weapon skill omitted")
equal(snapshot.offense.weaponSkills[1].max, 75, "accessible weapon max retained")

equal(snapshot.defense.armor.base, nil, "secret armor base omitted")
equal(snapshot.defense.armor.effective, 1297, "accessible armor retained")
equal(snapshot.defense.defenseSkill.base, nil, "secret defense base omitted")
equal(snapshot.defense.defenseSkill.effective, 4, "accessible defense modifier retained")
equal(snapshot.defense.dodge, nil, "secret dodge omitted")
equal(snapshot.defense.parry, 6.25, "accessible parry retained")

equal(snapshot.ratings.hitMelee, nil, "secret combat rating omitted")
equal(snapshot.utility.itemLevel.overall, nil, "secret overall item level omitted")
equal(snapshot.utility.itemLevel.equipped, 48, "accessible equipped item level retained")
equal(snapshot.utility.itemLevel.pvp, nil, "secret pvp item level omitted")
equal(snapshot.utility.movement.currentYardsPerSecond, nil, "secret current speed omitted")
equal(snapshot.utility.movement.runYardsPerSecond, 7, "accessible run speed retained")
equal(snapshot.utility.experience.current, nil, "secret xp omitted")
equal(snapshot.utility.experience.max, 5000, "accessible xp max retained")
equal(snapshot.utility.mastery, nil, "secret mastery omitted")
equal(snapshot.utility.versatility, 2, "accessible versatility retained")

-- Defense in depth: even if the underlying collector throws for an unforeseen
-- client behavior, finalization must return a valid partial snapshot instead of
-- aborting CharacterTelemetryEnrichment.SetCharacterSnapshot.
local failingAddon = {
    CharacterStats = {
        Capture = function()
            error("unexpected stat collector failure")
        end,
        SafeNumber = addon.CharacterStats.SafeNumber,
    },
}
local finalizeChunk = assert(loadfile("Data/CharacterStatsFinalize.lua"))
finalizeChunk("Guildweaver", failingAddon)
local guardOk, guarded = pcall(failingAddon.CharacterStats.Capture)
truthy(guardOk, "finalizer contains stat collector failures")
equal(guarded.schemaVersion, 1, "guarded stat schema")

print("secret value stat spec passed")
