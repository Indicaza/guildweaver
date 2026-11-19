local _, GW = ...

-- A small, versioned list of what is actually known about a few dungeons'
-- encounters, keyed by instance ID (the 8th return of GetInstanceInfo).
-- It only adds knowledge: a dungeon that is not here is tracked exactly as
-- before, from the client's encounter events and lockout.
--
-- Every encounter carries where the knowledge came from and how sure it is:
--   observed    seen in the Forever client (an ENCOUNTER_END the game sent)
--   documented  from the game's published design, not yet seen on Forever
-- and a role: "final", "required", "optional" or "unknown". Nothing is
-- invented: an ID, NPC ID or creature display ID that has not been seen is
-- left out, and a boss whose role is not established is "unknown".
--
-- A definition marked complete = true lists every encounter of the dungeon
-- with a known role; only then is its mandatory roster (required and final
-- bosses) known, and killing all of it is a full clear. Optional encounters
-- (rares, side bosses) never block a clear and never count toward one.
--
-- The final boss alone also completes a run:
--   * an "observed" final boss matched by encounter ID proves the clear
--     (completion basis "final_boss", eligible for personal bests);
--   * a "documented" final boss matched by name only completes the run but
--     is labelled unconfirmed ("final_boss_unconfirmed", never a PB).
-- /gw dungeon bosses prints what a run in progress saw, to fill this in.
GW.DungeonBosses = GW.DungeonBosses or {}

local Bosses = GW.DungeonBosses

Bosses.VERSION = 1

Bosses.instances = {
    -- Excavation Site: Wetlands (Forever). Two encounters observed with IDs
    -- in Details! encounter records on 2026-11-13 (ENCOUNTER_END, kill = true,
    -- zoneMapId 2998, difficulty 1). A third boss segment, "Relic Guardian",
    -- was recorded in the same session without an encounter ID. The lockout
    -- reports 4 encounters; the fourth and the final boss are not known yet.
    [2998] = {
        name = "Excavation Site: Wetlands",
        encounters = {
            { encounterId = 3480, name = "Saltspine", role = "unknown", confidence = "observed",
                source = "Details! encounter record, Forever, 2026-11-13" },
            { encounterId = 3481, name = "Shadetooth", role = "unknown", confidence = "observed",
                source = "Details! encounter record, Forever, 2026-11-13" },
            { name = "Relic Guardian", role = "unknown", confidence = "observed",
                source = "Details! boss segment without an encounter ID, Forever, 2026-11-13" },
        },
    },
    -- Blackfathom Deeps. Aku'mai is the dungeon's last boss in the game's
    -- design. No encounter IDs from Forever are known yet, so the match is by
    -- (English) name and the completion is labelled unconfirmed until an ID
    -- is observed. The lockout reports 7 encounters on Forever.
    [48] = {
        name = "Blackfathom Deeps",
        encounters = {
            { name = "Aku'mai", role = "final", confidence = "documented",
                source = "Blackfathom Deeps' final boss in the game's dungeon design; not yet seen on Forever" },
        },
    },
}

local function lower(value)
    return type(value) == "string" and string.lower(value) or nil
end

-- The definition for an instance, or nil.
function Bosses.For(instanceId)
    return instanceId and Bosses.instances[tonumber(instanceId)] or nil
end

-- The registry entry for an encounter: by encounter ID when the entry has
-- one, else by name. Returns the entry and how it matched ("id" or "name").
function Bosses.Match(instanceId, encounterId, name)
    local definition = Bosses.For(instanceId)
    if not definition then
        return nil
    end
    local wanted = lower(name)
    for _, entry in ipairs(definition.encounters) do
        if encounterId and entry.encounterId and entry.encounterId == encounterId then
            return entry, "id"
        end
    end
    for _, entry in ipairs(definition.encounters) do
        if wanted and lower(entry.name) == wanted and (not entry.encounterId or not encounterId) then
            return entry, "name"
        end
    end
    return nil
end

-- What a boss kill proves about completion: "final_boss" (an observed final
-- boss matched by ID), "final_boss_unconfirmed" (a final boss matched by
-- name or not yet observed), or nil.
function Bosses.FinalBossProof(instanceId, encounterId, name)
    local entry, how = Bosses.Match(instanceId, encounterId, name)
    if not entry or entry.role ~= "final" then
        return nil, entry
    end
    if how == "id" and entry.confidence == "observed" then
        return "final_boss", entry
    end
    return "final_boss_unconfirmed", entry
end

-- The display ID to draw a boss's portrait from, only when one is known.
function Bosses.DisplayId(instanceId, encounterId, name)
    local entry = Bosses.Match(instanceId, encounterId, name)
    return entry and tonumber(entry.displayId) or nil
end

local ROLES = { required = true, final = true, optional = true }

-- The role of an encounter: "required", "final", "optional", or "unknown"
-- (not in the registry, or listed without an established role). Also the
-- registry entry and how it matched ("id" or "name"). An unknown encounter
-- is never assumed to be required or optional.
function Bosses.Role(instanceId, encounterId, name)
    local entry, how = Bosses.Match(instanceId, encounterId, name)
    if not entry or not ROLES[entry.role] then
        return "unknown", entry, how
    end
    return entry.role, entry, how
end

-- The bosses a dungeon clear needs (roles "required" and "final"), only when
-- the definition is marked complete: every encounter of the dungeon listed,
-- none of unknown role. Nil otherwise: the mandatory roster is not known.
function Bosses.MandatoryRoster(instanceId)
    local definition = Bosses.For(instanceId)
    if not definition or definition.complete ~= true then
        return nil
    end
    local roster = {}
    for _, entry in ipairs(definition.encounters) do
        if not ROLES[entry.role] then
            return nil
        end
        if entry.role ~= "optional" then
            table.insert(roster, entry)
        end
    end
    return #roster > 0 and roster or nil
end
