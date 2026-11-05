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
env:load()

-- Real interpreter time per rendered frame (all addon work in that frame).
local worstLuaFrame = 0
local nextFrame = env.nextFrame
function env.nextFrame(self)
    local started = os.clock()
    local cpu = nextFrame(self)
    worstLuaFrame = math.max(worstLuaFrame, (os.clock() - started) * 1000)
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
    worstLuaFrame = 0
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

print(string.format("root=%s size=%s reloads=%d", root, size, env.reloads))
print("| Scenario | Tooltip renders | API calls | Simulated client ms | Worst simulated frame ms | Lua CPU ms | Worst Lua frame ms | Lua KB allocated |")
print("|---|---:|---:|---:|---:|---:|---:|---:|")
for _, row in ipairs(rows) do
    print(string.format("| %s | %d | %d | %.1f | %.1f | %.1f | %.1f | %.0f |",
        row.name, row.tooltips, row.calls, row.simulated, row.worst, row.lua, row.worstLua, row.allocated))
end
