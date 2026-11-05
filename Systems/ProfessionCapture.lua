local _, GW = ...

-- Recipe book capture, coordinated in one place.
--
-- Profession window events (show, list updates, learned recipes, data
-- source changes) all funnel into Request/Schedule. A burst of events is
-- coalesced: every request supersedes the previous one, and the capture
-- starts once the trade skill UI reports it is ready. The scan then runs as
-- one keyed job on GW.WorkQueue, a recipe at a time within a per-frame
-- budget, followed by spell tooltips, categories and reagent descriptions.
-- Only a finished scan is stored and published; closing the window,
-- switching profession, a data-source change or a newer request cancels the
-- job, so a partial scan never replaces a complete recipe book. The work is
-- optional and pauses in combat.

local Globals = _G or {}

GW.ProfessionCapture = GW.ProfessionCapture or {}

local RETRY_DELAY_SECONDS = 0.25
local MAX_CAPTURE_ATTEMPTS = 20
-- Fingerprint pieces between budget checks.
local FINGERPRINT_PIECES = 256
-- List updates fire after every craft; a crafting session settles first.
local LIST_UPDATE_SETTLE_SECONDS = 2.0

local function tradeSkillReady()
    local api = C_TradeSkillUI
    if type(api) ~= "table" then
        return true
    end

    if type(api.IsDataSourceChanging) == "function" then
        local ok, changing = pcall(api.IsDataSourceChanging)
        if not ok or changing == true then
            return false
        end
    end

    if type(api.IsTradeSkillReady) == "function" then
        local ok, ready = pcall(api.IsTradeSkillReady)
        if not ok or ready == false then
            return false
        end
    end

    return true
end

local function kindForEvent(event)
    return string.find(tostring(event or ""), "CRAFT", 1, true) and "craft" or "tradeskill"
end

local function professionId(fn)
    if type(fn) ~= "function" then
        return ""
    end
    local ok, info = pcall(fn)
    return ok and type(info) == "table" and tostring(info.professionID) or ""
end

-- What the open window shows; a change means the job's data is stale.
local function sourceIdentity(kind)
    if kind ~= "craft" then
        local api = Globals.C_TradeSkillUI
        if type(api) == "table" and type(api.GetBaseProfessionInfo) == "function" then
            return "modern:" .. professionId(api.GetBaseProfessionInfo) .. ":" .. professionId(api.GetChildProfessionInfo)
        end
    end
    local lineFunction = kind == "craft" and Globals.GetCraftDisplaySkillLine or Globals.GetTradeSkillLine
    if type(lineFunction) == "function" then
        local ok, name = pcall(lineFunction)
        return "legacy:" .. tostring(ok and name or "")
    end
    return "unknown"
end

local function dataSourceChanging()
    local api = Globals.C_TradeSkillUI
    if type(api) ~= "table" or type(api.IsDataSourceChanging) ~= "function" then
        return false
    end
    local ok, changing = pcall(api.IsDataSourceChanging)
    return ok and changing == true
end

local function shouldYield()
    local queue = GW.WorkQueue
    return queue and queue.ShouldYield() or false
end

local function perfRecord(name, ms)
    local perf = GW.Perf
    if perf and perf.Record then
        perf.Record(name, ms, true)
    end
end

local function perfNow()
    local perf = GW.Perf
    return perf and perf.Now and perf.Now() or 0
end

local function finishScan(job, professions)
    local book = professions.ScanResult(job.scan)
    if not book and job.scan.mode == "modern" and not job.triedLegacy
        and type(professions.BeginLegacyScan) == "function" then
        -- Same fallback as CollectOpenRecipeBook.
        job.triedLegacy = true
        job.scan = professions.BeginLegacyScan("tradeskill")
        return job.scan == nil
    end
    if not book then
        return true
    end
    job.book = book
    job.phase = "tooltips"
    job.index = 1
    return false
end

-- One step of the scan job. Returns true when the job is finished.
local function stepJob(job)
    local professions = GW.ProfessionTelemetry
    if type(professions) ~= "table" then
        return true
    end

    if job.phase == "begin" then
        job.startedAt = perfNow()
        job.scan = professions.BeginScan(job.kind)
        if not job.scan then
            return true
        end
        job.phase = "scan"
    end

    if job.phase == "scan" then
        repeat
            if professions.StepScan(job.scan) then
                return finishScan(job, professions)
            end
        until shouldYield()
        return false
    end

    local book = job.book
    if job.phase == "tooltips" then
        local enrich = professions.EnrichRecipeTooltip
        if type(enrich) == "function" then
            while job.index <= #book.recipes do
                enrich(book.recipes[job.index])
                job.index = job.index + 1
                if shouldYield() then
                    return false
                end
            end
        end
        job.phase = "categories"
        return false
    end

    if job.phase == "categories" then
        if type(professions.CollectBookCategories) == "function" then
            book.categories = professions.CollectBookCategories(book.recipes)
        end
        job.phase = "items"
        job.itemIds = type(professions.BookItemIds) == "function" and professions.BookItemIds(book.recipes) or {}
        job.items = {}
        job.index = 1
        return false
    end

    if job.phase == "items" then
        local describeItem = professions.DescribeBookItem
        local limit = tonumber(professions.MAX_BOOK_ITEMS) or 400
        if type(describeItem) == "function" then
            while job.index <= #job.itemIds and #job.items < limit do
                local item = describeItem(job.itemIds[job.index])
                job.index = job.index + 1
                if item then
                    table.insert(job.items, item)
                end
                if shouldYield() then
                    return false
                end
            end
            book.items = #job.items > 0 and job.items or nil
        end
        job.phase = "bookFingerprint"
        job.fingerprint = GW.Store.BeginFingerprint({ recipes = book.recipes, categories = book.categories, items = book.items })
        return false
    end

    -- Serializing a large book takes longer than a frame, so its change
    -- check and the profession_snapshot fingerprint are resumable.
    if job.phase == "bookFingerprint" then
        repeat
            local done, fingerprint = GW.Store.StepFingerprint(job.fingerprint, FINGERPRINT_PIECES)
            if done then
                job.bookFingerprint = fingerprint
                job.phase = "remember"
                return false
            end
        until shouldYield()
        return false
    end

    if job.phase == "remember" then
        local character = GW.Character
        local key = type(character.ProfessionCacheKey) == "function" and character.ProfessionCacheKey() or nil
        -- From here on the book is complete; later phases only publish it.
        job.remembered = true
        if not key or not professions.RememberRecipeBook(key, book, job.bookFingerprint) then
            -- Unchanged book: nothing to publish.
            local perf = GW.Perf
            if perf and perf.Count then
                perf.Count("recipe_scans_unchanged")
            end
            perfRecord("recipe_scan_elapsed", perfNow() - (job.startedAt or perfNow()))
            return true
        end
        local domain = GW.TelemetryDomains and GW.TelemetryDomains.Professions
        local snapshot = character.GetCurrentSnapshot and character.GetCurrentSnapshot() or nil
        if domain and type(domain.PublishPrepared) == "function" and type(snapshot) == "table" then
            job.domain = domain
            job.snapshot = snapshot
            job.token = domain.Revision and domain.Revision(snapshot) or nil
            job.payload = domain.Capture(snapshot)
            if type(job.payload) == "table" then
                job.payload.schemaVersion = domain.PayloadSchemaVersion
                job.fingerprint = GW.Store.BeginFingerprint(job.payload)
                job.phase = "payloadFingerprint"
                return false
            end
        end
        job.phase = "publish"
        return false
    end

    if job.phase == "payloadFingerprint" then
        repeat
            local done, fingerprint = GW.Store.StepFingerprint(job.fingerprint, FINGERPRINT_PIECES)
            if done then
                local context = {}
                for key, value in pairs(job.snapshot) do
                    context[key] = value
                end
                context.capturedAt = type(GetServerTime) == "function" and GetServerTime() or job.snapshot.capturedAt
                job.domain.PublishPrepared(context, job.payload, fingerprint, job.token)
                job.phase = "publish"
                return false
            end
        until shouldYield()
        return false
    end

    if job.phase == "publish" then
        -- profession_snapshot is already stored; this refreshes the local
        -- snapshot's recipes (the profession domain is reused by revision).
        local started = perfNow()
        GW.Character.PublishProfessionRecipes(book, job.reason)
        perfRecord("recipe_publish", perfNow() - started)
        perfRecord("recipe_scan_elapsed", perfNow() - (job.startedAt or started))
        local perf = GW.Perf
        if perf and perf.Count then
            perf.Count("recipe_scans_completed")
            perf.Count("recipes_scanned", #book.recipes)
        end
        return true
    end

    return true
end

function GW.ProfessionCapture:Generation(kind)
    self.generations = self.generations or {}
    return self.generations[kind] or 0
end

local function bumpGeneration(self, kind)
    self.generations = self.generations or {}
    self.generations[kind] = (self.generations[kind] or 0) + 1
    return self.generations[kind]
end

-- Queues the scan for the open window (or captures synchronously on a
-- client without the work queue).
function GW.ProfessionCapture:Enqueue(reason, kind)
    kind = kind or kindForEvent(reason)
    local queue = GW.WorkQueue
    if not queue or type(queue.Enqueue) ~= "function"
        or type(GW.ProfessionTelemetry) ~= "table" or type(GW.ProfessionTelemetry.BeginScan) ~= "function" then
        return GW.Character.CaptureProfessionRecipes(reason)
    end

    local capture = self
    local job = {
        key = "profession:" .. kind,
        optional = true,
        category = "recipe_step",
        kind = kind,
        reason = reason,
        generation = self:Generation(kind),
        identity = sourceIdentity(kind),
        phase = "begin",
        step = stepJob,
        isStale = function(current)
            if current.remembered then
                -- The complete book is stored; finishing its publish is
                -- correct even if the window has closed since.
                return false
            end
            if capture:Generation(kind) ~= current.generation then
                return true
            end
            if capture.closed and capture.closed[kind] then
                return true
            end
            if kind ~= "craft" and dataSourceChanging() then
                return true
            end
            return sourceIdentity(kind) ~= current.identity
        end,
    }
    return queue.Enqueue(job, "replace")
end

-- Coalesces requests: each one supersedes earlier ones (including a scan in
-- progress), and the scan starts once the trade skill UI is ready.
function GW.ProfessionCapture:Schedule(reason, kind, initialDelay)
    kind = kind or kindForEvent(reason)
    local generation = bumpGeneration(self, kind)

    local function attempt(attemptNumber)
        local delay = attemptNumber == 1 and tonumber(initialDelay) or RETRY_DELAY_SECONDS
        C_Timer.After(delay, function()
            if self:Generation(kind) ~= generation then
                return
            end

            if kind == "craft" or tradeSkillReady() then
                self:Enqueue(reason, kind)
                return
            end

            if attemptNumber < MAX_CAPTURE_ATTEMPTS then
                attempt(attemptNumber + 1)
            end
        end)
    end

    attempt(1)
end

function GW.ProfessionCapture:Request(event)
    local kind = kindForEvent(event)
    self.closed = self.closed or {}
    if event == "TRADE_SKILL_CLOSE" or event == "CRAFT_CLOSE" then
        self.closed[kind] = true
        bumpGeneration(self, kind)
        if GW.WorkQueue and GW.WorkQueue.Cancel then
            GW.WorkQueue.Cancel("profession:" .. kind, "closed")
        end
        return
    end
    if event == "TRADE_SKILL_SHOW" or event == "CRAFT_SHOW" or event == "TRADE_SKILL_DATA_SOURCE_CHANGED" then
        self.closed[kind] = false
    end
    if event == "NEW_RECIPE_LEARNED" and GW.ItemTelemetry and GW.ItemTelemetry.ClearDescriptionCache then
        -- "Already known" and similar text may have changed.
        GW.ItemTelemetry.ClearDescriptionCache()
    end
    local settle = (event == "TRADE_SKILL_LIST_UPDATE" or event == "CRAFT_UPDATE") and LIST_UPDATE_SETTLE_SECONDS or nil
    self:Schedule(event, kind, settle)
end

function GW.ProfessionCapture:Initialize()
    if self.eventFrame then
        return
    end

    local frame = CreateFrame("Frame")
    local registered = pcall(frame.RegisterEvent, frame, "TRADE_SKILL_DATA_SOURCE_CHANGED")
    if not registered then
        return
    end

    frame:SetScript("OnEvent", function(_, event)
        if event == "TRADE_SKILL_DATA_SOURCE_CHANGED" then
            self:Request(event)
        end
    end)

    self.eventFrame = frame
end

GW.ProfessionCapture:Initialize()
