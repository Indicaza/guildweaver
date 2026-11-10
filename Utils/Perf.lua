local _, GW = ...

-- Lightweight, in-memory performance counters for /gw perf.
--
-- Every measured operation updates a fixed set of numbers per category
-- (count, total, last, worst, and how often it went over 1/5/16 ms), modelled
-- on Blizzard's AddOn profiler buckets. Work done in the same rendered frame is
-- also summed into a per-frame total, so a frame that ran several small
-- captures is visible as one spike. Only the five worst frames are kept.
-- Nothing is written to SavedVariables and nothing is printed unless asked.

local Globals = _G or {}

GW.Perf = GW.Perf or {}
local Perf = GW.Perf

local WORST_FRAMES = 5
local THRESHOLDS = { 1, 5, 16 }

local categories = {}
local counters = {}
local worstFrames = {}
local frameStamp = nil
local frameTotal = 0
local frameLabel = nil
local frameLabelMs = 0

-- debugprofilestop is a high-resolution millisecond counter available on
-- every client generation; GetTimePreciseSec is the modern fallback. GetTime
-- only changes once per frame, so it is a last resort.
local clockName = "none"
local function resolveClock()
    if type(Globals.debugprofilestop) == "function" then
        clockName = "debugprofilestop"
        return Globals.debugprofilestop
    end
    if type(Globals.GetTimePreciseSec) == "function" then
        clockName = "GetTimePreciseSec"
        local precise = Globals.GetTimePreciseSec
        return function()
            return precise() * 1000
        end
    end
    if type(Globals.GetTime) == "function" then
        clockName = "GetTime"
        local getTime = Globals.GetTime
        return function()
            return getTime() * 1000
        end
    end
    if type(os) == "table" and type(os.clock) == "function" then
        clockName = "os.clock"
        return function()
            return os.clock() * 1000
        end
    end
    return function()
        return 0
    end
end

local clock = resolveClock()

-- Tests install a fake clock; the game never calls this.
function Perf.SetClock(fn, name)
    if type(fn) == "function" then
        clock = fn
        clockName = name or "custom"
    else
        clock = resolveClock()
    end
end

function Perf.Now()
    return clock()
end

function Perf.ClockName()
    return clockName
end

-- GetTime() is constant for the duration of a rendered frame, which makes it
-- a cheap frame identity.
local function currentFrame()
    local getTime = Globals.GetTime
    if type(getTime) ~= "function" then
        return nil
    end
    local ok, value = pcall(getTime)
    return ok and value or nil
end

local function recordFrame()
    if frameStamp == nil or frameTotal <= 0 then
        return
    end
    local entry = { at = frameStamp, ms = frameTotal, label = frameLabel }
    local insertAt = nil
    for index = 1, #worstFrames do
        if frameTotal > worstFrames[index].ms then
            insertAt = index
            break
        end
    end
    if insertAt then
        table.insert(worstFrames, insertAt, entry)
    elseif #worstFrames < WORST_FRAMES then
        table.insert(worstFrames, entry)
    end
    while #worstFrames > WORST_FRAMES do
        table.remove(worstFrames)
    end
end

local function addToFrame(name, ms)
    local stamp = currentFrame()
    if stamp ~= frameStamp then
        recordFrame()
        frameStamp = stamp
        frameTotal = 0
        frameLabel = nil
        frameLabelMs = 0
    end
    frameTotal = frameTotal + ms
    if ms > frameLabelMs then
        frameLabel = name
        frameLabelMs = ms
    end
end

local function category(name)
    local entry = categories[name]
    if not entry then
        entry = { count = 0, total = 0, last = 0, worst = 0, over = { 0, 0, 0 } }
        categories[name] = entry
    end
    return entry
end

-- Records one finished operation. Nested measurements are recorded per
-- category but only top-level ones add to the frame total.
function Perf.Record(name, ms, nested)
    ms = tonumber(ms) or 0
    if ms < 0 then
        ms = 0
    end
    local entry = category(name)
    entry.count = entry.count + 1
    entry.total = entry.total + ms
    entry.last = ms
    if ms > entry.worst then
        entry.worst = ms
    end
    for index = 1, #THRESHOLDS do
        if ms > THRESHOLDS[index] then
            entry.over[index] = entry.over[index] + 1
        end
    end
    if not nested then
        addToFrame(name, ms)
    end
end

-- Categories that only ever run inside another measured operation; they are
-- reported on their own but not added to the frame total twice.
local NESTED = {
    fingerprint = true,
    recipe_step = true,
    item_catalog = true,
    loot_enrich = true,
    loot_capture = true,
    domain_publish = true,
}

-- Usage: local started = Perf.Begin(); ...; Perf.End("category", started)
function Perf.Begin()
    return clock()
end

function Perf.End(name, started)
    if started == nil then
        return 0
    end
    local ms = clock() - started
    Perf.Record(name, ms, NESTED[name] == true)
    return ms
end

-- Runs fn(...) measured under name and returns its results. Errors are
-- re-raised after the timing is recorded.
function Perf.Measure(name, fn, ...)
    local started = Perf.Begin()
    local results = { pcall(fn, ...) }
    Perf.End(name, started)
    if not results[1] then
        error(results[2], 0)
    end
    return unpack(results, 2, table.maxn(results))
end

function Perf.Count(name, amount)
    counters[name] = (counters[name] or 0) + (tonumber(amount) or 1)
end

function Perf.Counter(name)
    return counters[name] or 0
end

function Perf.Category(name)
    return categories[name]
end

local memoryBaseline = nil

-- This addon's memory (KB), only when asked: UpdateAddOnMemoryUsage walks
-- every addon, so it is never called during play.
local function addonMemory()
    local update = Globals.UpdateAddOnMemoryUsage
    local get = Globals.GetAddOnMemoryUsage
    if type(update) ~= "function" or type(get) ~= "function" then
        return nil
    end
    local ok = pcall(update)
    if not ok then
        return nil
    end
    local okGet, value = pcall(get, GW.name or "Guildweaver")
    return okGet and tonumber(value) or nil
end

function Perf.Reset()
    memoryBaseline = nil
    categories = {}
    counters = {}
    worstFrames = {}
    frameStamp = nil
    frameTotal = 0
    frameLabel = nil
    frameLabelMs = 0
end

function Perf.WorstFrames()
    recordFrame()
    frameTotal = 0
    return worstFrames
end

local REPORT_ORDER = {
    "loot_event",
    "loot_capture",
    "loot_enrich",
    "item_catalog",
    "stats_capture",
    "character_capture",
    "inventory_scan",
    "inventory_money",
    "recipe_step",
    "recipe_scan_elapsed",
    "domain_publish",
    "fingerprint",
    "queue_tick",
}

local function format(ms)
    return string.format("%.2f", tonumber(ms) or 0)
end

-- Optional client profiler metrics for this addon, when the client offers
-- C_AddOnProfiler and it is enabled.
local function profilerLines(addonName)
    local profiler = Globals.C_AddOnProfiler
    if type(profiler) ~= "table" or type(profiler.GetAddOnMetric) ~= "function" then
        return nil
    end
    if type(profiler.IsEnabled) == "function" then
        local ok, enabled = pcall(profiler.IsEnabled)
        if not ok or not enabled then
            return nil
        end
    end
    local enum = type(Globals.Enum) == "table" and Globals.Enum.AddOnProfilerMetric or nil
    if type(enum) ~= "table" then
        return nil
    end
    local function metric(key)
        local id = enum[key]
        if id == nil then
            return nil
        end
        local ok, value = pcall(profiler.GetAddOnMetric, addonName, id)
        return ok and tonumber(value) or nil
    end
    local recent, peak, over5, over10 = metric("RecentAverageTime"), metric("PeakTime"), metric("CountTimeOver5Ms"), metric("CountTimeOver10Ms")
    if not recent and not peak then
        return nil
    end
    return {
        "Client profiler: recent avg " .. format(recent) .. " ms/frame, peak " .. format(peak)
            .. " ms, frames >5 ms " .. tostring(over5 or "?") .. ", >10 ms " .. tostring(over10 or "?"),
    }
end

-- Compact report lines; the caller decides how to print them.
function Perf.Report(extra)
    local lines = { "Perf (" .. clockName .. ", this session, synthetic counters):" }
    local seen = {}
    local function line(name)
        local entry = categories[name]
        seen[name] = true
        if not entry or entry.count == 0 then
            return
        end
        table.insert(lines, string.format("  %s: %d runs, avg %s ms, last %s, worst %s, >5ms %d, >16ms %d",
            name, entry.count, format(entry.total / entry.count), format(entry.last), format(entry.worst),
            entry.over[2], entry.over[3]))
    end
    for _, name in ipairs(REPORT_ORDER) do
        line(name)
    end
    local others = {}
    for name in pairs(categories) do
        if not seen[name] then
            table.insert(others, name)
        end
    end
    table.sort(others)
    for _, name in ipairs(others) do
        line(name)
    end

    local counterNames = {}
    for name in pairs(counters) do
        table.insert(counterNames, name)
    end
    table.sort(counterNames)
    if #counterNames > 0 then
        local parts = {}
        for _, name in ipairs(counterNames) do
            table.insert(parts, name .. "=" .. tostring(counters[name]))
        end
        table.insert(lines, "  counts: " .. table.concat(parts, ", "))
    end

    if type(extra) == "table" then
        for _, value in ipairs(extra) do
            table.insert(lines, "  " .. tostring(value))
        end
    end

    local frames = Perf.WorstFrames()
    if #frames > 0 then
        local parts = {}
        for _, frame in ipairs(frames) do
            table.insert(parts, format(frame.ms) .. " ms (" .. tostring(frame.label or "?") .. ")")
        end
        table.insert(lines, "  worst frames: " .. table.concat(parts, ", "))
    end

    local memory = addonMemory()
    if memory then
        if memoryBaseline then
            table.insert(lines, string.format("  addon memory: %.0f KB (%+.0f KB since the previous /gw perf)", memory, memory - memoryBaseline))
        else
            table.insert(lines, string.format("  addon memory: %.0f KB", memory))
        end
        memoryBaseline = memory
    end

    for _, value in ipairs(profilerLines(GW.name or "Guildweaver") or {}) do
        table.insert(lines, "  " .. value)
    end
    return lines
end
