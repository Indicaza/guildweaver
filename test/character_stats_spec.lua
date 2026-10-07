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

Globals.UnitHealth = function() return 818 end
Globals.UnitHealthMax = function() return 1050 end
Globals.UnitPowerType = function() return 1, "RAGE" end
Globals.UnitPower = function() return 72 end
Globals.UnitPowerMax = function() return 100 end
Globals.GetPowerRegen = function() return 2.5, 1.25 end
Globals.GetManaRegen = function() return 8, 3 end

local stats = {
    [1] = { 69, 72, 5, -2 },
    [2] = { 38, 43, 5, 0 },
    [3] = { 83, 90, 7, 0 },
    [4] = { 23, 23, 0, 0 },
    [5] = { 17, 17, 0, 0 },
}
Globals.UnitStat = function(_, id)
    local value = stats[id]
    return value[1], value[2], value[3], value[4]
end

Globals.UnitAttackPower = function() return 178, 12, -4 end
Globals.UnitRangedAttackPower = function() return 55, 3, 0 end
Globals.UnitDamage = function() return 21.5, 34.75, 10, 16, 2, -1, 1 end
Globals.UnitRangedDamage = function() return 2.6, 15, 24, 1, 0, 1 end
Globals.UnitAttackSpeed = function() return 2.4, 1.8 end
Globals.GetCritChance = function() return 12.5 end
Globals.GetRangedCritChance = function() return 9.25 end
Globals.GetHitModifier = function() return 3 end
Globals.GetRangedHitModifier = function() return 2 end
Globals.GetMeleeHaste = function() return 4.5 end
Globals.GetRangedHaste = function() return 1.5 end
Globals.GetExpertise = function() return 6, 4, 0 end
Globals.GetExpertisePercent = function() return 1.5, 1 end
Globals.GetArmorPenetration = function() return 7 end

Globals.GetSpellBonusDamage = function(school) return school == 3 and 44 or 0 end
Globals.GetSpellCritChance = function(school) return school == 3 and 6.5 or 0 end
Globals.GetSpellBonusHealing = function() return 31 end
Globals.GetSpellHitModifier = function() return 2.25 end
Globals.GetSpellPenetration = function() return 10 end
Globals.UnitSpellHaste = function() return 3.5 end

Globals.UnitArmor = function() return 1100, 1297, 1297, 197, 0 end
Globals.UnitResistance = function(_, school)
    if school == 2 then return 0, 15, 15, 0 end
    return 0, 0, 0, 0
end
Globals.UnitDefense = function() return 95, 4 end
Globals.GetDodgeChance = function() return 8.75 end
Globals.GetParryChance = function() return 6.25 end
Globals.GetBlockChance = function() return 5 end
Globals.GetShieldBlock = function() return 12 end
Globals.GetAvoidance = function() return 2.5 end

Globals.CR_HIT_MELEE = 6
Globals.CR_CRIT_MELEE = 9
Globals.CR_RESILIENCE_PLAYER_DAMAGE_TAKEN = 15
Globals.GetCombatRating = function(id) return id * 10 end
Globals.GetCombatRatingBonus = function(id) return id / 2 end

Globals.GetNumSkillLines = function() return 2 end
Globals.GetSkillLineInfo = function(index)
    if index == 1 then return "Daggers", false, false, 42, 1, 2, 75 end
    return "Cooking", false, false, 70, 0, 0, 150
end

Globals.GetUnitSpeed = function() return 7, 7, 0, 4.722 end
Globals.GetSpeed = function() return 0 end
Globals.GetAverageItemLevel = function() return 55, 48, 60 end
Globals.UnitXP = function() return 1234 end
Globals.UnitXPMax = function() return 5000 end
Globals.GetXPExhaustion = function() return 2500 end
Globals.GetMasteryEffect = function() return 4 end
Globals.GetVersatilityBonus = function() return 2 end
Globals.GetLifesteal = function() return 1 end

local addon = {}
local function loadAddonFile(path)
    local chunk = assert(loadfile(path))
    return chunk("Guildweaver", addon)
end

loadAddonFile("Data/CharacterStats.lua")
loadAddonFile("Data/CharacterStatsFinalize.lua")

local snapshot = addon.CharacterStats.Capture()
equal(snapshot.schemaVersion, 1, "stat schema")
equal(snapshot.resources.health.current, 818, "health current")
equal(snapshot.resources.health.max, 1050, "health max")
equal(snapshot.resources.power.token, "RAGE", "power token")
equal(snapshot.resources.power.current, 72, "power current")

equal(snapshot.attributes.strength.effective, 72, "strength")
equal(snapshot.attributes.agility.effective, 43, "agility")
equal(snapshot.attributes.stamina.effective, 90, "stamina")

equal(snapshot.offense.attackPower.effective, 186, "attack power")
equal(snapshot.offense.meleeDamage.min, 21.5, "melee min")
equal(snapshot.offense.meleeDamage.max, 34.75, "melee max")
equal(snapshot.offense.crit.melee, 12.5, "melee crit")
equal(snapshot.offense.expertise.mainHand, 6, "expertise")
equal(snapshot.offense.spell.schools.fire.damage, 44, "fire spell power")
equal(snapshot.offense.weaponSkills[1].name, "Daggers", "weapon skill")
equal(snapshot.offense.weaponSkills[1].current, 42, "weapon skill current")

equal(snapshot.defense.armor.effective, 1297, "armor")
equal(snapshot.defense.defenseSkill.effective, 99, "defense skill")
equal(snapshot.defense.dodge, 8.75, "dodge")
equal(snapshot.defense.resistances.fire.total, 15, "fire resistance")

equal(snapshot.ratings.hitMelee.rating, 60, "hit rating")
equal(snapshot.ratings.hitMelee.bonus, 3, "hit rating bonus")
equal(snapshot.ratings.critMelee.rating, 90, "crit rating")

equal(snapshot.utility.itemLevel.overall, 55, "overall item level")
equal(snapshot.utility.itemLevel.equipped, 48, "equipped item level")
equal(snapshot.utility.itemLevel.pvp, 60, "pvp item level")
equal(snapshot.utility.movement.runYardsPerSecond, 7, "run speed")
equal(snapshot.utility.experience.rested, 2500, "rested xp")
truthy(snapshot.utility.mastery, "mastery retained")

print("character stats spec passed")
