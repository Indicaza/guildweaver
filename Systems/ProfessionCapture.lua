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
-- Opening a window waits briefly, so the window's own first frames are not
-- shared with the scan and a quick open/close starts nothing.
local SHOW_SETTLE_SECONDS = 0.75
-- An unchanged book (same profession, skill and recipe count) scanned within
-- this long, in this session or a saved one, is not scanned again.
local SCAN_FRESH_SECONDS = 6 * 3600

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

-- A cheap summary of the open book: its profession, skill rank and recipe
-- count. List updates fire after every craft; while this is unchanged the
-- book is too (bar reagent counts), so they skip the full rescan.
local function bookSignature(kind)
    if kind ~= "craft" then
        local api = Globals.C_TradeSkillUI
        if type(api) == "table" and type(api.GetBaseProfessionInfo) == "function" then
            local parts = {}
            for _, fn in ipairs({ api.GetBaseProfessionInfo, api.GetChildProfessionInfo or false }) do
                local ok, info = false, nil
                if type(fn) == "function" then
                    ok, info = pcall(fn)
                end
                if ok and type(info) == "table" then
                    parts[#parts + 1] = tostring(info.professionID) .. "@" .. tostring(info.skillLevel)
                        .. "/" .. tostring(info.maxSkillLevel)
                end
            end
            local listFunction = api.GetAllRecipeIDs or api.GetFilteredRecipeIDs
            local ok, ids = false, nil
            if type(listFunction) == "function" then
                ok, ids = pcall(listFunction)
            end
            parts[#parts + 1] = "#" .. tostring(ok and type(ids) == "table" and #ids or "?")
            return table.concat(parts, ";")
        end
    end
    local lineFunction = kind == "craft" and Globals.GetCraftDisplaySkillLine or Globals.GetTradeSkillLine
    local countFunction = kind == "craft" and Globals.GetNumCrafts or Globals.GetNumTradeSkills
    if type(lineFunction) ~= "function" or type(countFunction) ~= "function" then
        return nil
    end
    local ok, name, rank, maxRank = pcall(lineFunction)
    local counted, count = pcall(countFunction)
    if not ok or not counted then
        return nil
    end
    return table.concat({ tostring(name), tostring(rank), tostring(maxRank), tostring(count) }, ";")
end

local function isListUpdate(reason)
    return reason == "TRADE_SKILL_LIST_UPDATE" or reason == "CRAFT_UPDATE"
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
        GW.ProfessionCapture.scanned = GW.ProfessionCapture.scanned or {}
        GW.ProfessionCapture.scanned[job.kind] = job.signature
        local character = GW.Character
        local key = type(character.ProfessionCacheKey) == "function" and character.ProfessionCacheKey() or nil
        if key and job.signature and type(professions.NoteScan) == "function" then
            professions.NoteScan(key, job.signature)
        end
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
        -- profession_snapshot is already stored; what is left is the local
        -- snapshot's copy of the recipes, converted a few at a time.
        local schema = GW.TelemetrySchema
        if type(professions.ToCharacterRecipe) == "function" and type(schema) == "table"
            and type(schema.NormalizeRecipe) == "function" and type(GW.Character.ApplyProfessionRecipes) == "function" then
            job.characterRecipes = {}
            job.index = 1
            job.phase = "convert"
            return false
        end
        job.phase = "recapture"
        return false
    end

    if job.phase == "convert" then
        local schema = GW.TelemetrySchema
        while job.index <= #book.recipes do
            local recipe = schema.NormalizeRecipe(professions.ToCharacterRecipe(book.recipes[job.index]))
            if recipe then
                job.characterRecipes[#job.characterRecipes + 1] = recipe
            end
            job.index = job.index + 1
            if shouldYield() then
                return false
            end
        end
        local profession = book.profession or {}
        local recipes = #job.characterRecipes > 0 and schema.MarkNormalizedRecipes(job.characterRecipes) or nil
        local now = type(GetServerTime) == "function" and GetServerTime() or nil
        if GW.Character.ApplyProfessionRecipes(profession.skillLineId, profession.name, recipes, now, book.source) then
            job.phase = "done"
        else
            job.phase = "recapture"
        end
        return false
    end

    if job.phase == "recapture" or job.phase == "done" then
        local started = perfNow()
        if job.phase == "recapture" then
            -- No matching profession on the snapshot yet: a full refresh.
            GW.Character.PublishProfessionRecipes(book, job.reason)
            perfRecord("recipe_publish", perfNow() - started)
        end
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
        signature = bookSignature(kind),
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
                local scanned = self.scanned and self.scanned[kind]
                local signature = bookSignature(kind)
                local unchanged = isListUpdate(reason) and scanned ~= nil and scanned == signature
                if not unchanged and signature and reason ~= "NEW_RECIPE_LEARNED" then
                    local professions = GW.ProfessionTelemetry
                    local key = GW.Character and type(GW.Character.ProfessionCacheKey) == "function"
                        and GW.Character.ProfessionCacheKey() or nil
                    unchanged = key ~= nil and type(professions) == "table" and type(professions.ScanIsFresh) == "function"
                        and professions.ScanIsFresh(key, signature, SCAN_FRESH_SECONDS)
                end
                if unchanged then
                    local perf = GW.Perf
                    if perf and perf.Count then
                        perf.Count("recipe_scans_skipped_unchanged")
                    end
                    self.scanned = self.scanned or {}
                    self.scanned[kind] = signature
                    return
                end
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
    if event == "NEW_RECIPE_LEARNED" then
        if GW.ItemTelemetry and GW.ItemTelemetry.ClearDescriptionCache then
            -- "Already known" and similar text may have changed.
            GW.ItemTelemetry.ClearDescriptionCache()
        end
        local professions = GW.ProfessionTelemetry
        local key = GW.Character and type(GW.Character.ProfessionCacheKey) == "function" and GW.Character.ProfessionCacheKey() or nil
        if key and type(professions) == "table" and type(professions.ForgetScans) == "function" then
            professions.ForgetScans(key)
        end
        if self.scanned then
            self.scanned[kind] = nil
        end
    end
    local settle = nil
    if event == "TRADE_SKILL_LIST_UPDATE" or event == "CRAFT_UPDATE" then
        settle = LIST_UPDATE_SETTLE_SECONDS
    elseif event == "TRADE_SKILL_SHOW" or event == "CRAFT_SHOW" then
        settle = SHOW_SETTLE_SECONDS
    end
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
