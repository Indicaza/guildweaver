local _, GW = ...

-- One coordinated queue for expensive, deferrable enrichment (recipe books,
-- tooltip scans, catalog definitions).
--
-- Work runs from C_Timer.After(0) callbacks, at most once per rendered frame,
-- and only while there is something to do: there is no permanent OnUpdate.
-- Each frame gets a conservative time budget and a cap on work items; a job
-- is a step function that does one small unit per call and checks the
-- budget between units. Optional jobs wait while the player is in combat.
--
-- Jobs are keyed: enqueueing a key that is already queued either keeps the
-- existing job (coalescing duplicates) or replaces it (a newer request for the
-- same data). The queue is bounded; when full, the oldest optional job is
-- dropped. A job's isStale() is checked before every step so closing or
-- switching a profession cancels it instead of publishing stale data.
--
-- Sustained work backs off: after BUSY_FRAMES consecutive busy frames the
-- queue runs every BACKOFF_SECONDS instead of every frame, so a long scan
-- or a farming session's enrichment never costs a slice of every frame
-- indefinitely. A single step is still one unit of work; the budget is
-- checked between units, never inside one.

local Globals = _G or {}

GW.WorkQueue = GW.WorkQueue or {}
local Queue = GW.WorkQueue

Queue.FRAME_BUDGET_MS = 2
Queue.MAX_ITEMS_PER_FRAME = 24
Queue.MAX_JOBS = 64
Queue.BUSY_FRAMES = 30
Queue.BACKOFF_SECONDS = 0.05

local jobs = {}
local byKey = {}
local scheduled = false
local inCombat = false
local tickStarted = 0
local tickItems = 0
local busyFrames = 0

local function newStats()
    return { ticks = 0, dropped = 0, cancelled = 0, completed = 0, maxDepth = 0, overBudget = 0,
        worstTick = 0, totalMs = 0, backoffs = 0, combatWaits = 0, worstStep = 0, worstStepCategory = nil }
end
local stats = newStats()

local function now()
    local perf = GW.Perf
    if perf and type(perf.Now) == "function" then
        return perf.Now()
    end
    return 0
end

local function combatLocked()
    if inCombat then
        return true
    end
    local lockdown = Globals.InCombatLockdown
    if type(lockdown) == "function" then
        local ok, value = pcall(lockdown)
        return ok and value == true
    end
    return false
end

Queue.InCombat = combatLocked

local function removeAt(index)
    local job = table.remove(jobs, index)
    if job and byKey[job.key] == job then
        byKey[job.key] = nil
    end
    return job
end

local function indexOf(job)
    for index = 1, #jobs do
        if jobs[index] == job then
            return index
        end
    end
    return nil
end

local function finish(job, reason)
    local index = indexOf(job)
    if index then
        removeAt(index)
    end
    job.finished = true
    if reason ~= "done" and type(job.onCancel) == "function" then
        pcall(job.onCancel, job, reason)
    end
end

local tick

local function hasRunnable()
    local combat = nil
    for index = 1, #jobs do
        local job = jobs[index]
        if not job.optional then
            return true
        end
        if combat == nil then
            combat = combatLocked()
        end
        if not combat then
            return true
        end
    end
    return false
end

local function schedule()
    if scheduled or not hasRunnable() then
        return
    end
    local timer = Globals.C_Timer
    if type(timer) ~= "table" or type(timer.After) ~= "function" then
        return
    end
    scheduled = true
    if busyFrames >= Queue.BUSY_FRAMES then
        busyFrames = 0
        stats.backoffs = stats.backoffs + 1
        timer.After(Queue.BACKOFF_SECONDS, tick)
        return
    end
    timer.After(0, tick)
end

-- Whether the current step should stop and continue next frame. Steps call
-- this between units of work.
function Queue.ShouldYield()
    tickItems = tickItems + 1
    if tickItems >= Queue.MAX_ITEMS_PER_FRAME then
        return true
    end
    return now() - tickStarted >= Queue.FRAME_BUDGET_MS
end

-- Processes queued work for one frame. Exposed for tests and for /gw perf.
function Queue.RunFrame()
    tickStarted = now()
    tickItems = 0
    local perf = GW.Perf
    local combat = combatLocked()
    local index = 1
    while index <= #jobs do
        local job = jobs[index]
        if job.optional and combat then
            stats.combatWaits = stats.combatWaits + 1
            index = index + 1
        elseif type(job.isStale) == "function" and job:isStale() then
            stats.cancelled = stats.cancelled + 1
            finish(job, "stale")
        else
            local started = now()
            local ok, result = pcall(job.step, job)
            local stepMs = now() - started
            if perf and perf.Record and job.category then
                perf.Record(job.category, stepMs, true)
            end
            if stepMs > stats.worstStep then
                stats.worstStep = stepMs
                stats.worstStepCategory = job.category or tostring(job.key)
            end
            if not ok then
                stats.cancelled = stats.cancelled + 1
                job.error = result
                finish(job, "error")
            elseif result == true then
                stats.completed = stats.completed + 1
                finish(job, "done")
            else
                -- Not finished: it used up the frame (or asked to wait).
                index = index + 1
            end
            if tickItems >= Queue.MAX_ITEMS_PER_FRAME or now() - tickStarted >= Queue.FRAME_BUDGET_MS then
                break
            end
        end
    end
    local elapsed = now() - tickStarted
    if elapsed > Queue.FRAME_BUDGET_MS * 2 then
        stats.overBudget = stats.overBudget + 1
    end
    if elapsed > stats.worstTick then
        stats.worstTick = elapsed
    end
    stats.totalMs = stats.totalMs + elapsed
    stats.ticks = stats.ticks + 1
    return elapsed
end

tick = function()
    scheduled = false
    local perf = GW.Perf
    local elapsed = Queue.RunFrame()
    if perf and perf.Record then
        perf.Record("queue_tick", elapsed)
    end
    busyFrames = #jobs > 0 and busyFrames + 1 or 0
    schedule()
end

-- job = { key, step = function(job) -> true when done, optional, isStale,
-- onCancel, category }. mode "replace" cancels a queued job with the same
-- key; the default keeps it. Returns the job that is queued for the key.
function Queue.Enqueue(job, mode)
    if type(job) ~= "table" or type(job.step) ~= "function" or job.key == nil then
        return nil
    end
    local existing = byKey[job.key]
    if existing and not existing.finished then
        if mode ~= "replace" then
            return existing
        end
        stats.cancelled = stats.cancelled + 1
        finish(existing, "replaced")
    end

    if #jobs >= Queue.MAX_JOBS then
        local dropAt = nil
        for index = 1, #jobs do
            if jobs[index].optional then
                dropAt = index
                break
            end
        end
        if not dropAt then
            return nil
        end
        local dropped = jobs[dropAt]
        stats.dropped = stats.dropped + 1
        finish(dropped, "dropped")
    end

    job.finished = false
    table.insert(jobs, job)
    byKey[job.key] = job
    if #jobs > stats.maxDepth then
        stats.maxDepth = #jobs
    end
    schedule()
    return job
end

function Queue.Cancel(key, reason)
    local job = byKey[key]
    if job then
        stats.cancelled = stats.cancelled + 1
        finish(job, reason or "cancelled")
        return true
    end
    return false
end

function Queue.Get(key)
    return byKey[key]
end

function Queue.Size()
    return #jobs
end

function Queue.Stats()
    return stats
end

function Queue.ResetStats()
    stats = newStats()
    stats.maxDepth = #jobs
end

-- Queued jobs per category, for /gw perf.
function Queue.Depths()
    local depths = {}
    for index = 1, #jobs do
        local name = jobs[index].category or "other"
        depths[name] = (depths[name] or 0) + 1
    end
    return depths
end

-- Combat state comes from PLAYER_REGEN_* so a resume is scheduled the moment
-- combat ends; InCombatLockdown is also consulted for reloads mid-combat.
function Queue.SetCombat(value)
    inCombat = value == true
    if not inCombat then
        schedule()
    end
end

function Queue.Reset()
    jobs = {}
    byKey = {}
    scheduled = false
    inCombat = false
    busyFrames = 0
    stats = newStats()
end

function Queue.Initialize()
    if Queue.eventFrame or type(Globals.CreateFrame) ~= "function" then
        return
    end
    local frame = Globals.CreateFrame("Frame")
    pcall(frame.RegisterEvent, frame, "PLAYER_REGEN_DISABLED")
    pcall(frame.RegisterEvent, frame, "PLAYER_REGEN_ENABLED")
    frame:SetScript("OnEvent", function(_, event)
        Queue.SetCombat(event == "PLAYER_REGEN_DISABLED")
    end)
    Queue.eventFrame = frame
end

Queue.Initialize()
