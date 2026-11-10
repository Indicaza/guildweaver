-- Synthetic before/after benchmark. Not run by CI.
--
--   lua5.1 test/bench/perf_bench.lua <addon root> <small|large>
--
-- Loads the addon at <addon root> (for example a checkout of an older commit)
-- in the fake client from test/support/wow_env.lua and replays common
-- gameplay. Reports, per scenario: tooltip renders, API calls, simulated
-- client time (fixed per-call costs, see wow_env.lua), the worst simulated
-- frame, and real Lua CPU time in this interpreter (os.clock). These are
-- synthetic measurements, not in-game results.

local Env = dofile("test/support/wow_env.lua")
local root = arg[1] or "."
local size = arg[2] or "small"
local options = size == "large" and { recipes = 600, bagItems = 30 } or { recipes = 40, bagItems = 0 }
options.root = root
options.realClock = true

local env = Env.new(options)
env.eventsInFrames = true
local GW = env:load()

-- Real interpreter time per rendered frame: event handlers dispatched since
-- the previous frame plus the timers that run in this one.
local worstLuaFrame = 0
local eventLua = 0
local dispatch = env.dispatch
function env.dispatch(self, ...)
    local started = os.clock()
    local delivered = dispatch(self, ...)
    eventLua = eventLua + (os.clock() - started) * 1000
    return delivered
end
local nextFrame = env.nextFrame
function env.nextFrame(self)
    local started = os.clock()
    local cpu = nextFrame(self)
    worstLuaFrame = math.max(worstLuaFrame, (os.clock() - started) * 1000 + eventLua)
    eventLua = 0
    return cpu
end

local rows = {}
local function totalCalls()
    local total = 0
    for _, value in pairs(env.calls) do
        total = total + value
    end
    return total
end

-- The collector is paused during each scenario so allocation can be
-- measured; a forced full collection beforehand distorted the next frame.
local function scenario(name, run)
    env:resetCalls()
    env.worstFrameCpu = 0
    env.lastFrameEndCpu = env.cpu
    worstLuaFrame = 0
    eventLua = 0
    local cpuBefore = env.cpu
    local memoryBefore = collectgarbage("count")
    local clockBefore = os.clock()
    collectgarbage("stop")
    run()
    local allocated = collectgarbage("count") - memoryBefore
    collectgarbage("restart")
    table.insert(rows, {
        name = name,
        tooltips = env:tooltipScans(),
        calls = totalCalls(),
        simulated = env.cpu - cpuBefore,
        worst = env.worstFrameCpu or 0,
        lua = (os.clock() - clockBefore) * 1000,
        worstLua = worstLuaFrame,
        allocated = allocated,
    })
end

scenario("login + 10 s", function()
    env:login()
    env:advance(5)
end)

scenario("100 player aura/stat events over 10 s", function()
    for index = 1, 100 do
        env:dispatch("UNIT_AURA", "player")
        if index % 10 == 0 then
            env.stats[2] = env.stats[2] + 1
            env:dispatch("UNIT_STATS", "player")
        end
        env:advance(0.1)
    end
    env:advance(2)
end)

scenario("400 raid/nameplate aura events", function()
    for index = 1, 400 do
        env:dispatch("UNIT_AURA", "raid" .. (index % 40 + 1))
    end
    env:advance(2)
end)

scenario("10 money changes", function()
    for _ = 1, 10 do
        env.money = env.money + 37
        env:dispatch("PLAYER_MONEY")
        env:advance(1.5)
    end
end)

scenario("10 single-stack bag changes", function()
    for index = 1, 10 do
        env.bags[2].slots[1].stackCount = 10 + index
        env:dispatch("BAG_UPDATE", 2)
        env:dispatch("BAG_UPDATE_DELAYED")
        env:advance(1.5)
    end
end)

scenario("open profession window (first scan)", function()
    env.tradeSkillOpen = true
    env:dispatch("TRADE_SKILL_SHOW")
    env:advance(15)
end)

scenario("5 profession list updates", function()
    for _ = 1, 5 do
        env:dispatch("TRADE_SKILL_LIST_UPDATE")
        env:advance(3)
    end
    env:advance(10)
end)

scenario("equipment change", function()
    env.equipment[5] = Env.itemLink(10018, "Gear Piece 18", 2)
    env:dispatch("PLAYER_EQUIPMENT_CHANGED", 5, true)
    env:advance(2)
end)

local function countStreams(prefix)
    local total = 0
    for key in pairs(Env.telemetry()) do
        if key:find(prefix, 1, true) == 1 then
            total = total + 1
        end
    end
    return total
end

-- Looting corpses: what a leveling or farming session does all day. Each
-- corpse drops a common item and one of 120 different reagents, so new
-- items keep appearing as they do in play. The window closes in the same
-- frame (fast auto-loot), the worst case for reading the live loot slot.
local corpse = 0
local function corpseGuid()
    corpse = corpse + 1
    return string.format("Creature-0-1-2-3-%d-%06d", 1000 + corpse % 7, corpse)
end
local function lootWindow(entries, framesBetween)
    env.loot = entries
    env:dispatch("LOOT_READY", true)
    env:dispatch("LOOT_OPENED", true)
    env.loot = nil
    env:dispatch("LOOT_CLOSED")
    env:advance((framesBetween or 60) / 60)
end
local function lootCorpses(count, framesBetween)
    for _ = 1, count do
        local guid = corpseGuid()
        local reagent = 30000 + corpse % 120
        lootWindow({
            { link = Env.itemLink(2589, "Linen Cloth", 1), quantity = 2, source = guid },
            { link = Env.itemLink(reagent, "Reagent " .. (reagent - 30000), 1), quantity = 1, source = guid },
        }, framesBetween)
    end
end

scenario("20 corpses looted", function()
    lootCorpses(20)
end)

scenario("60 corpses looted rapidly (6 frames apart)", function()
    lootCorpses(60, 6)
    env:advance(3)
end)

scenario("area loot: 8 corpses, 16 slots in one window", function()
    local entries = {}
    for _ = 1, 8 do
        local guid = corpseGuid()
        local reagent = 30000 + corpse % 120
        table.insert(entries, { link = Env.itemLink(reagent, "Reagent " .. (reagent - 30000), 1), quantity = 1, source = guid })
        table.insert(entries, { link = Env.itemLink(20000 + corpse % 700, "Crafted Item " .. (corpse % 700), 2), quantity = 1, source = guid })
    end
    lootWindow(entries)
    env:advance(3)
end)

-- The outbound queue is only emptied by a newer SavedVariables write after
-- the bridge reads it, so a long session fills it to its cap.
scenario("20 corpses looted, outbound queue full", function()
    local outbound = Env.telemetry()
    local now = env.serverTime
    for index = 1, 4200 do
        local event = index % 3 ~= 0
        outbound[(event and "mob_loot:filler:" or "game_item_definition:item:") .. index] = {
            kind = event and "event" or "state",
            revision = 1,
            updatedAt = now - 5000 + index,
            fingerprint = "00000000",
            envelope = { payload = { index = index } },
        }
    end
    -- As after a /reload: the store recounts its streams on the next write.
    GW.Store.Initialize()
    lootCorpses(20)
end)

-- A long session: the corpse cache saved across reloads is full.
scenario("20 corpses looted, 1000 remembered corpses", function()
    local db = GW.Store.GetDatabase()
    db.meta.mobLootSeen = db.meta.mobLootSeen or {}
    local now = env.serverTime
    for index = 1, 1000 do
        db.meta.mobLootSeen["::Live Realm:Creature-0-1-2-3-9-" .. index] = { at = now - 3000 + index, outputs = {} }
    end
    lootCorpses(20)
end)

scenario("reopen profession window (unchanged)", function()
    env.tradeSkillOpen = false
    env:dispatch("TRADE_SKILL_CLOSE")
    env:advance(1)
    env.tradeSkillOpen = true
    env:dispatch("TRADE_SKILL_SHOW")
    env:advance(15)
end)

scenario("craft 15 times with the window open", function()
    for index = 1, 15 do
        env.bags[2].slots[1].stackCount = 20 - index
        env:dispatch("BAG_UPDATE", 2)
        env:dispatch("TRADE_SKILL_LIST_UPDATE")
        env:dispatch("BAG_UPDATE_DELAYED")
        env:advance(2.5)
    end
    env:advance(5)
end)

scenario("open and close professions 10 times quickly", function()
    for index = 1, 10 do
        env.openProfession = index % 2 == 0 and 164 or 186
        env.tradeSkillOpen = true
        env:dispatch("TRADE_SKILL_SHOW")
        env:advance(0.3)
        env.tradeSkillOpen = false
        env:dispatch("TRADE_SKILL_CLOSE")
        env:advance(0.2)
    end
    env.openProfession = 164
    env:advance(10)
end)

scenario("dungeon pull: combat, loot, gear and bags", function()
    for pull = 1, 5 do
        env.inCombat = true
        env:dispatch("PLAYER_REGEN_DISABLED")
        for _ = 1, 20 do
            env:dispatch("UNIT_AURA", "player")
            env:advance(0.25)
        end
        env.inCombat = false
        env:dispatch("PLAYER_REGEN_ENABLED")
        lootCorpses(4, 20)
        env.bags[1].slots[1].stackCount = 5 + pull
        env:dispatch("BAG_UPDATE", 1)
        env:dispatch("BAG_UPDATE_DELAYED")
        env.equipment[6] = Env.itemLink(10006 + pull % 2 * 10, "Gear Piece " .. (6 + pull % 2 * 10), 2)
        env:dispatch("PLAYER_EQUIPMENT_CHANGED", 6, true)
        env:dispatch("UPDATE_INVENTORY_DURABILITY")
        env:advance(2)
    end
    env:advance(10)
end)

-- The dungeon tracker alone: a run with frequent XP, money and roster
-- events, boss kills and deaths, then leaving. Older roots ignore it.
scenario("dungeon tracker: 300 XP/money/roster events, 5 bosses", function()
    local inside = true
    _G.IsInInstance = function() return inside, inside and "party" or "none" end
    _G.GetInstanceInfo = function()
        if not inside then return "Elwynn Forest", "none", 0, "", 0, 0, false, 0 end
        return "The Deadmines", "party", 1, "Normal", 5, 0, false, 36
    end
    _G.UnitXP = function() return 100 end
    _G.UnitXPMax = function() return 5000 end
    _G.GetNumGroupMembers = function() return 5 end
    env:dispatch("PLAYER_ENTERING_WORLD", false, false)
    env:advance(2)
    for index = 1, 100 do
        env:dispatch("PLAYER_XP_UPDATE", "player")
        env:dispatch("PLAYER_MONEY")
        env:dispatch("GROUP_ROSTER_UPDATE")
        if index % 20 == 0 then
            env:dispatch("ENCOUNTER_START", index, "Boss " .. index, 1, 5)
            env:dispatch("PLAYER_DEAD")
            env:dispatch("ENCOUNTER_END", index, "Boss " .. index, 1, 5, 1)
        end
        env:advance(0.1)
    end
    inside = false
    env:dispatch("PLAYER_ENTERING_WORLD", false, false)
    env:advance(5)
end)

print(string.format("root=%s size=%s reloads=%d mob_loot=%d item_definitions=%d gathering=%d", root, size, env.reloads,
    countStreams("mob_loot:"), countStreams("item_definition:"), countStreams("gathering_loot:")))
print("| Scenario | Tooltip renders | API calls | Simulated client ms | Worst simulated frame ms | Lua CPU ms | Worst Lua frame ms | Lua KB allocated |")
print("|---|---:|---:|---:|---:|---:|---:|---:|")
for _, row in ipairs(rows) do
    print(string.format("| %s | %d | %d | %.1f | %.1f | %.1f | %.1f | %.0f |",
        row.name, row.tooltips, row.calls, row.simulated, row.worst, row.lua, row.worstLua, row.allocated))
end
local dungeonPerf = env.addon and env.addon.Perf and env.addon.Perf.Category and env.addon.Perf.Category("dungeon_event")
if dungeonPerf then
    print(string.format("dungeon_event: %d events, %.2f ms total, worst %.3f ms", dungeonPerf.count or 0,
        dungeonPerf.totalMs or dungeonPerf.total or 0, dungeonPerf.worstMs or dungeonPerf.worst or 0))
end
