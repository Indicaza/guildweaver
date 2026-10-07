local _, GW = ...

local Globals = _G or {}

local ATTRIBUTE_NAMES = {
    [1] = "strength",
    [2] = "agility",
    [3] = "stamina",
    [4] = "intellect",
    [5] = "spirit",
}

local RESISTANCE_NAMES = {
    [0] = "physical",
    [1] = "holy",
    [2] = "fire",
    [3] = "nature",
    [4] = "frost",
    [5] = "shadow",
    [6] = "arcane",
}

local SPELL_SCHOOLS = {
    [1] = "physical",
    [2] = "holy",
    [3] = "fire",
    [4] = "nature",
    [5] = "frost",
    [6] = "shadow",
    [7] = "arcane",
}

local RATING_CONSTANTS = {
    defense = "CR_DEFENSE_SKILL",
    dodge = "CR_DODGE",
    parry = "CR_PARRY",
    block = "CR_BLOCK",
    hitMelee = "CR_HIT_MELEE",
    hitRanged = "CR_HIT_RANGED",
    hitSpell = "CR_HIT_SPELL",
    critMelee = "CR_CRIT_MELEE",
    critRanged = "CR_CRIT_RANGED",
    critSpell = "CR_CRIT_SPELL",
    hasteMelee = "CR_HASTE_MELEE",
    hasteRanged = "CR_HASTE_RANGED",
    hasteSpell = "CR_HASTE_SPELL",
    expertise = "CR_EXPERTISE",
    armorPenetration = "CR_ARMOR_PENETRATION",
    resilience = "CR_RESILIENCE_PLAYER_DAMAGE_TAKEN",
    mastery = "CR_MASTERY",
    versatilityDamageDone = "CR_VERSATILITY_DAMAGE_DONE",
    versatilityDamageTaken = "CR_VERSATILITY_DAMAGE_TAKEN",
    speed = "CR_SPEED",
    leech = "CR_LIFESTEAL",
    avoidance = "CR_AVOIDANCE",
}

local WEAPON_SKILL_NAMES = {
    ["axes"] = true,
    ["two-handed axes"] = true,
    ["2h axes"] = true,
    ["bows"] = true,
    ["crossbows"] = true,
    ["daggers"] = true,
    ["fist weapons"] = true,
    ["guns"] = true,
    ["maces"] = true,
    ["two-handed maces"] = true,
    ["2h maces"] = true,
    ["polearms"] = true,
    ["staves"] = true,
    ["swords"] = true,
    ["two-handed swords"] = true,
    ["2h swords"] = true,
    ["thrown"] = true,
    ["unarmed"] = true,
    ["wands"] = true,
}

local function safeCall(name, ...)
    local func = Globals[name]
    if type(func) ~= "function" then
        return nil
    end

    local ok, a, b, c, d, e, f, g, h = pcall(func, ...)
    if not ok then
        return nil
    end
    return a, b, c, d, e, f, g, h
end

local function number(value)
    local parsed = tonumber(value)
    if not parsed or parsed ~= parsed then
        return nil
    end
    return parsed
end

local function hasNumbers(value)
    if type(value) ~= "table" then
        return false
    end
    for _, field in pairs(value) do
        if type(field) == "number" then
            return true
        end
    end
    return false
end

local function statBundle(current, effective, positive, negative)
    local result = {
        current = number(current),
        effective = number(effective),
        positive = number(positive),
        negative = number(negative),
    }
    return hasNumbers(result) and result or nil
end

local function modifierBundle(base, positive, negative)
    base = number(base)
    positive = number(positive)
    negative = number(negative)
    if not base and not positive and not negative then
        return nil
    end
    return {
        base = base,
        positive = positive,
        negative = negative,
        effective = (base or 0) + (positive or 0) + (negative or 0),
    }
end

local function collectResources()
    local health = number(safeCall("UnitHealth", "player"))
    local maxHealth = number(safeCall("UnitHealthMax", "player"))
    local powerTypeId, powerToken = safeCall("UnitPowerType", "player")
    powerTypeId = number(powerTypeId)
    local power = number(safeCall("UnitPower", "player", powerTypeId))
    local maxPower = number(safeCall("UnitPowerMax", "player", powerTypeId))
    local baseRegen, castingRegen = safeCall("GetPowerRegen")
    local manaBase, manaCasting = safeCall("GetManaRegen")

    return {
        health = (health or maxHealth) and { current = health, max = maxHealth } or nil,
        power = (power or maxPower or powerTypeId) and {
            typeId = powerTypeId,
            token = type(powerToken) == "string" and powerToken or nil,
            current = power,
            max = maxPower,
        } or nil,
        powerRegen = (number(baseRegen) or number(castingRegen)) and {
            inactive = number(baseRegen),
            active = number(castingRegen),
        } or nil,
        manaRegen = (number(manaBase) or number(manaCasting)) and {
            inactive = number(manaBase),
            active = number(manaCasting),
        } or nil,
    }
end

local function collectAttributes()
    local result = {}
    for statId, name in pairs(ATTRIBUTE_NAMES) do
        local current, effective, positive, negative = safeCall("UnitStat", "player", statId)
        local value = statBundle(current, effective, positive, negative)
        if value then
            result[name] = value
        end
    end
    return result
end

local function collectArmorAndResistances()
    local base, effective, armor, positive, negative = safeCall("UnitArmor", "player")
    local armorRecord = {
        base = number(base),
        effective = number(effective),
        armor = number(armor),
        positive = number(positive),
        negative = number(negative),
    }

    local resistances = {}
    for index = 0, 6 do
        local resistanceBase, total, bonus, minus = safeCall("UnitResistance", "player", index)
        if number(total) or number(resistanceBase) then
            resistances[RESISTANCE_NAMES[index]] = {
                base = number(resistanceBase),
                total = number(total),
                bonus = number(bonus),
                negative = number(minus),
            }
        end
    end

    return hasNumbers(armorRecord) and armorRecord or nil, resistances
end

local function collectWeaponSkills()
    local count = number(safeCall("GetNumSkillLines")) or 0
    if count <= 0 then
        return nil
    end

    local skills = {}
    for index = 1, count do
        local name, isHeader, _, rank, temporary, modifier, maxRank = safeCall("GetSkillLineInfo", index)
        local key = type(name) == "string" and string.lower(name) or nil
        if not isHeader and key and WEAPON_SKILL_NAMES[key] then
            table.insert(skills, {
                name = name,
                current = number(rank),
                max = number(maxRank),
                temporary = number(temporary),
                modifier = number(modifier),
            })
        end
    end

    return #skills > 0 and skills or nil
end

local function collectRatings()
    local getRating = Globals.GetCombatRating
    if type(getRating) ~= "function" then
        return nil
    end

    local getBonus = Globals.GetCombatRatingBonus
    local result = {}
    for key, globalName in pairs(RATING_CONSTANTS) do
        local ratingId = number(Globals[globalName])
        if ratingId then
            local ok, raw = pcall(getRating, ratingId)
            if ok and number(raw) then
                local bonus = nil
                if type(getBonus) == "function" then
                    local bonusOk, value = pcall(getBonus, ratingId)
                    if bonusOk then bonus = number(value) end
                end
                result[key] = { rating = number(raw), bonus = bonus }
            end
        end
    end

    return next(result) and result or nil
end

local function collectSpellStats()
    local schools = {}
    for schoolId, schoolName in pairs(SPELL_SCHOOLS) do
        local damage = number(safeCall("GetSpellBonusDamage", schoolId))
        local crit = number(safeCall("GetSpellCritChance", schoolId))
        if damage or crit then
            schools[schoolName] = {
                id = schoolId,
                damage = damage,
                crit = crit,
            }
        end
    end

    local healing = number(safeCall("GetSpellBonusHealing"))
    local hit = number(safeCall("GetSpellHitModifier"))
    local penetration = number(safeCall("GetSpellPenetration"))
    local haste = number(safeCall("UnitSpellHaste", "player")) or number(safeCall("GetSpellHaste"))

    if not next(schools) and not healing and not hit and not penetration and not haste then
        return nil
    end

    return {
        schools = schools,
        healing = healing,
        hit = hit,
        penetration = penetration,
        haste = haste,
    }
end

local function collectOffense()
    local attackBase, attackPositive, attackNegative = safeCall("UnitAttackPower", "player")
    local rangedBase, rangedPositive, rangedNegative = safeCall("UnitRangedAttackPower", "player")
    local minDamage, maxDamage, offhandMin, offhandMax, damagePositive, damageNegative, damagePercent = safeCall("UnitDamage", "player")
    local rangedSpeed, rangedMin, rangedMax, rangedDamagePositive, rangedDamageNegative, rangedPercent = safeCall("UnitRangedDamage", "player")
    local mainSpeed, offhandSpeed = safeCall("UnitAttackSpeed", "player")
    local expertiseMain, expertiseOffhand, expertiseRanged = safeCall("GetExpertise")
    local expertisePercentMain, expertisePercentOffhand = safeCall("GetExpertisePercent")

    return {
        attackPower = modifierBundle(attackBase, attackPositive, attackNegative),
        rangedAttackPower = modifierBundle(rangedBase, rangedPositive, rangedNegative),
        meleeDamage = (number(minDamage) or number(maxDamage)) and {
            min = number(minDamage),
            max = number(maxDamage),
            offhandMin = number(offhandMin),
            offhandMax = number(offhandMax),
            positive = number(damagePositive),
            negative = number(damageNegative),
            multiplier = number(damagePercent),
        } or nil,
        rangedDamage = (number(rangedMin) or number(rangedMax) or number(rangedSpeed)) and {
            speed = number(rangedSpeed),
            min = number(rangedMin),
            max = number(rangedMax),
            positive = number(rangedDamagePositive),
            negative = number(rangedDamageNegative),
            multiplier = number(rangedPercent),
        } or nil,
        attackSpeed = (number(mainSpeed) or number(offhandSpeed)) and {
            mainHand = number(mainSpeed),
            offHand = number(offhandSpeed),
        } or nil,
        crit = {
            melee = number(safeCall("GetCritChance")),
            ranged = number(safeCall("GetRangedCritChance")),
        },
        hit = {
            melee = number(safeCall("GetHitModifier")),
            ranged = number(safeCall("GetRangedHitModifier")),
        },
        haste = {
            melee = number(safeCall("GetMeleeHaste")) or number(safeCall("GetHaste")),
            ranged = number(safeCall("GetRangedHaste")),
        },
        expertise = (number(expertiseMain) or number(expertisePercentMain)) and {
            mainHand = number(expertiseMain),
            offHand = number(expertiseOffhand),
            ranged = number(expertiseRanged),
            mainHandPercent = number(expertisePercentMain),
            offHandPercent = number(expertisePercentOffhand),
        } or nil,
        armorPenetration = number(safeCall("GetArmorPenetration")),
        spell = collectSpellStats(),
        weaponSkills = collectWeaponSkills(),
    }
end

local function collectDefense()
    local defenseBase, defenseModifier = safeCall("UnitDefense", "player")
    local armor, resistances = collectArmorAndResistances()

    return {
        armor = armor,
        defenseSkill = (number(defenseBase) or number(defenseModifier)) and {
            base = number(defenseBase),
            modifier = number(defenseModifier),
            effective = (number(defenseBase) or 0) + (number(defenseModifier) or 0),
        } or nil,
        dodge = number(safeCall("GetDodgeChance")),
        parry = number(safeCall("GetParryChance")),
        block = number(safeCall("GetBlockChance")),
        shieldBlock = number(safeCall("GetShieldBlock")),
        avoidance = number(safeCall("GetAvoidance")),
        resilience = number(safeCall("GetCombatRatingBonus", number(Globals.CR_RESILIENCE_PLAYER_DAMAGE_TAKEN))),
        resistances = resistances,
    }
end

local function collectUtility()
    local currentSpeed, runSpeed, flightSpeed, swimSpeed = safeCall("GetUnitSpeed", "player")
    local averageEquipped, averageOverall = safeCall("GetAverageItemLevel")
    local xp = number(safeCall("UnitXP", "player"))
    local xpMax = number(safeCall("UnitXPMax", "player"))
    local rested = number(safeCall("GetXPExhaustion"))

    return {
        movement = (number(currentSpeed) or number(runSpeed)) and {
            currentYardsPerSecond = number(currentSpeed),
            runYardsPerSecond = number(runSpeed),
            flightYardsPerSecond = number(flightSpeed),
            swimYardsPerSecond = number(swimSpeed),
            bonusPercent = number(safeCall("GetSpeed")),
        } or nil,
        itemLevel = (number(averageEquipped) or number(averageOverall)) and {
            equipped = number(averageEquipped),
            overall = number(averageOverall),
        } or nil,
        experience = (xp or xpMax or rested) and {
            current = xp,
            max = xpMax,
            rested = rested,
        } or nil,
        mastery = number(safeCall("GetMasteryEffect")),
        versatility = number(safeCall("GetVersatilityBonus")),
        leech = number(safeCall("GetLifesteal")),
        avoidance = number(safeCall("GetAvoidance")),
    }
end

local function capture()
    return {
        schemaVersion = 1,
        resources = collectResources(),
        attributes = collectAttributes(),
        offense = collectOffense(),
        defense = collectDefense(),
        ratings = collectRatings(),
        utility = collectUtility(),
    }
end

GW.CharacterStats = GW.CharacterStats or {}
GW.CharacterStats.Capture = capture
