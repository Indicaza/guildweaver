-- Gameplay performance regressions, run against the real TOC in a
-- deterministic fake client (test/support/wow_env.lua): fake frame clock,
-- simulated per-call costs, and API call counters.

local Env = dofile("test/support/wow_env.lua")

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

local function atMost(actual, limit, label)
    if actual > limit then
        error((label or "value") .. ": expected at most " .. tostring(limit) .. ", got " .. tostring(actual), 2)
    end
end

local function count(addon, category)
    local entry = addon.Perf.Category(category)
    return entry and entry.count or 0
end

local function start(options)
    local env = Env.new(options)
    local addon = env:load()
    env:login()
    env:advance(3)
    return env, addon
end

local function revision(env, prefix)
    local record = env:stream(prefix)
    return record and record.revision or 0
end

-- Login ---------------------------------------------------------------------------

do
    local env = Env.new()
    local addon = env:load()
    env:login()
    env:advance(10)
    equal(env.reloads, 0, "login never reloads the UI")
    equal(count(addon, "character_capture"), 1, "one full reconciliation at startup")
    truthy(env:stream("character_session:"), "session start checkpoint captured without a reload")
    truthy(env:stream("inventory_snapshot:"), "inventory captured at startup")
    for _, message in ipairs(env.printed) do
        truthy(not message:find("Reloading", 1, true), "no reload announcement at login")
    end

    -- Explicit synchronization still reloads on request.
    SlashCmdList.GUILDWEAVER("sync")
    env:advance(1)
    equal(env.reloads, 1, "/gw sync reloads on request")
end

-- Stat and aura bursts ------------------------------------------------------------

do
    local env, addon = start()
    local statsBefore = revision(env, "stats:")
    env:resetCalls()
    addon.Perf.Reset()

    for _ = 1, 50 do
        env:dispatch("UNIT_AURA", "player")
        env:dispatch("UNIT_STATS", "player")
        env:dispatch("COMBAT_RATING_UPDATE")
    end
    env:advance(2)

    equal(count(addon, "stats_capture"), 1, "a burst shares one stats refresh")
    equal(count(addon, "character_capture"), 0, "no full character capture")
    equal(env:callCount("GetTalentInfo"), 0, "no talent scan")
    equal(env:callCount("GetInventoryItemLink"), 0, "no equipment scan")
    equal(env:callCount("GetRecipeInfo"), 0, "no recipe scan")
    equal(env:callCount("GetContainerItemInfo"), 0, "no bag scan")
    equal(env:tooltipScans(), 0, "no tooltip scans")
    atMost(count(addon, "fingerprint"), 1, "stats payload fingerprinted at most once")
    equal(revision(env, "stats:"), statsBefore, "unchanged stats keep their revision")

    env.stats[1] = 99
    env:dispatch("UNIT_STATS", "player")
    env:advance(2)
    equal(revision(env, "stats:"), statsBefore + 1, "changed stats publish exactly one revision")
    local snapshot = addon.Character.GetCurrentSnapshot()
    equal(snapshot.stats.attributes.strength.effective, 99, "cached snapshot stays coherent")

    -- Events for other units never reach the handler (RegisterUnitEvent).
    addon.Perf.Reset()
    local delivered = 0
    for _ = 1, 20 do
        env.delivered = 0
        env:dispatch("UNIT_AURA", "party1")
        env:dispatch("UNIT_AURA", "nameplate3")
        delivered = delivered + env.delivered
    end
    env:advance(2)
    equal(count(addon, "stats_capture"), 0, "other units cause no captures")
    truthy(delivered < 40, "unit events are filtered by the client for the player")

    -- Auras in combat are folded into one refresh after combat.
    addon.Perf.Reset()
    env.inCombat = true
    env:dispatch("PLAYER_REGEN_DISABLED")
    for _ = 1, 30 do
        env:dispatch("UNIT_AURA", "player")
        env:advance(0.5)
    end
    equal(count(addon, "stats_capture"), 0, "no stats work during combat")
    env.inCombat = false
    env:dispatch("PLAYER_REGEN_ENABLED")
    env:advance(2)
    equal(count(addon, "stats_capture"), 1, "one stats refresh after combat")
end

-- Clients without RegisterUnitEvent filter in Lua.
do
    local env, addon = start({ unitEvents = false })
    addon.Perf.Reset()
    for _ = 1, 20 do
        env:dispatch("UNIT_AURA", "raid7")
    end
    env:advance(2)
    equal(count(addon, "stats_capture"), 0, "unit filtering without RegisterUnitEvent")
end

-- Fingerprinting --------------------------------------------------------------------

do
    local env, addon = start()
    local snapshot = addon.Character.GetCurrentSnapshot()
    addon.Perf.Reset()
    local first = addon.TelemetryDomains.Stats.Publish(snapshot)
    local second = addon.TelemetryDomains.Stats.Publish(snapshot)
    equal(second.changed, false, "unchanged stats deduped")
    equal(second.revision, first.revision, "unchanged stats keep the revision")
    equal(count(addon, "fingerprint"), 2, "each unchanged publish fingerprints once")

    addon.Perf.Reset()
    local professions = addon.TelemetryDomains.Professions.Publish(snapshot)
    local inventory = addon.TelemetryDomains.Inventory.Publish(snapshot)
    -- Only the small live profession list is compared; the recipe payload
    -- and the inventory payload are not serialized again.
    atMost(count(addon, "fingerprint"), 1, "revisioned domains skip unchanged payloads")
    atMost(addon.Perf.Counter("fingerprint_bytes"), 1024, "no large payload serialized")
    equal(professions.cached, true, "profession payload reused by revision")
    equal(inventory.cached, true, "inventory payload reused by revision")

    -- The stored fingerprint is the store's fingerprint of the payload.
    local record = env:stream("stats:")
    equal(record.fingerprint, addon.Store.Fingerprint(record.envelope.payload), "single fingerprint matches the store's")
end

-- Inventory ---------------------------------------------------------------------------

do
    local env = start({ bagItems = 20 })
    local before = revision(env, "inventory_snapshot:")

    env:resetCalls()
    env.money = env.money + 250
    env:dispatch("PLAYER_MONEY")
    env:advance(2)
    equal(env:itemTooltipScans(), 0, "money changes perform no tooltip scans")
    equal(env:callCount("GetContainerItemInfo"), 0, "money changes read no bag slots")
    equal(revision(env, "inventory_snapshot:"), before + 1, "money publishes a revision")
    local payload = env:stream("inventory_snapshot:").envelope.payload
    equal(payload.money.copper, env.money, "fresh money")
    local stamp = env:stream("inventory_snapshot:").envelope.capturedAt
    equal(stamp, env.serverTime, "fresh capture timestamp")

    -- One stack changes: only its bag is read and only that item rescanned.
    env:resetCalls()
    env.bags[2].slots[1].stackCount = 17
    env:dispatch("BAG_UPDATE", 2)
    env:dispatch("BAG_UPDATE_DELAYED")
    env:advance(2)
    equal(env:callCount("GetContainerItemInfo"), env.bags[2].size, "only the dirty bag is read")
    equal(env:callCount("tooltip:SetBagItem"), 1, "only the changed item is rescanned")
    payload = env:stream("inventory_snapshot:").envelope.payload
    local totals = {}
    for _, total in ipairs(payload.totals) do
        totals[total.itemId] = total.count
    end
    equal(totals[2835], 17, "changed total")
    equal(totals[2770], 14, "unchanged totals retained across stacks")

    -- Moving an item between bags keeps totals and reuses its tooltip.
    env:resetCalls()
    env.bags[3].slots[5] = env.bags[1].slots[1]
    env.bags[1].slots[1] = nil
    env:dispatch("BAG_UPDATE", 1)
    env:dispatch("BAG_UPDATE", 3)
    env:dispatch("BAG_UPDATE_DELAYED")
    env:advance(2)
    equal(env:callCount("tooltip:SetBagItem"), 0, "a moved item keeps its tooltip")
    payload = env:stream("inventory_snapshot:").envelope.payload
    local found = false
    for _, container in ipairs(payload.containers) do
        for _, slot in ipairs(container.slots) do
            if container.bagId == 3 and slot.slot == 5 and slot.itemId == 2447 then
                found = true
            end
        end
    end
    truthy(found, "moved item reported at its new slot")

    -- An enchant changes the item string: a distinct instance, rescanned.
    env:resetCalls()
    env.bags[1].slots[2].hyperlink = Env.itemLink(765, "Silverleaf", 1, ":1900:::::::30:::::::")
    env:dispatch("BAG_UPDATE", 1)
    env:dispatch("BAG_UPDATE_DELAYED")
    env:advance(2)
    equal(env:callCount("tooltip:SetBagItem"), 1, "changed instance state rescans that item")
    payload = env:stream("inventory_snapshot:").envelope.payload
    local enchanted = false
    for _, item in ipairs(payload.items) do
        if item.itemId == 765 and item.enchantId == 1900 then
            enchanted = true
        end
    end
    truthy(enchanted, "enchanted instance described")

    -- A change without its event is repaired by the periodic full read.
    env.bags[0].slots[4].stackCount = 5
    env:advance(901)
    env:dispatch("BAG_UPDATE", 1)
    env:dispatch("BAG_UPDATE_DELAYED")
    env:advance(2)
    payload = env:stream("inventory_snapshot:").envelope.payload
    for _, total in ipairs(payload.totals) do
        if total.itemId == 2589 then
            equal(total.count, 5, "full reconciliation repairs a missed change")
        end
    end

    -- Bag refreshes wait for combat to end.
    env:resetCalls()
    env.inCombat = true
    env:dispatch("PLAYER_REGEN_DISABLED")
    env.bags[2].slots[2].stackCount = 1
    env:dispatch("BAG_UPDATE", 2)
    env:dispatch("BAG_UPDATE_DELAYED")
    env:advance(3)
    equal(env:callCount("GetContainerItemInfo"), 0, "no bag reads in combat")
    env.inCombat = false
    env:dispatch("PLAYER_REGEN_ENABLED")
    env:advance(2)
    truthy(env:callCount("GetContainerItemInfo") > 0, "bags refreshed after combat")
end

-- Uncached items resolve without endless scans.
do
    local env, addon = start()
    env.items[40000] = { itemId = 40000, name = "Late Loader", quality = 1, class = "Trade Goods", equipLocation = "", icon = 1 }
    env.uncached[40000] = true
    env.put(4, 1, 40000, 1)
    env:resetCalls()
    env:dispatch("BAG_UPDATE", 4)
    env:dispatch("BAG_UPDATE_DELAYED")
    env:advance(15)
    local attempts = env:callCount("tooltip:SetBagItem")
    -- Three inventory description attempts plus three item-catalog attempts.
    atMost(attempts, 6, "bounded attempts for an uncached item")
    for _ = 1, 10 do
        env:dispatch("BAG_UPDATE", 0)
        env:dispatch("BAG_UPDATE_DELAYED")
        env:advance(2)
    end
    equal(env:callCount("tooltip:SetBagItem"), attempts, "no further scans for an exhausted item")

    env.uncached[40000] = nil
    env:dispatch("GET_ITEM_INFO_RECEIVED", 40000, true)
    env:advance(3)
    local payload = env:stream("inventory_snapshot:").envelope.payload
    local resolved = nil
    for _, item in ipairs(payload.items) do
        if item.itemId == 40000 then
            resolved = item
        end
    end
    truthy(resolved and resolved.name == "Late Loader" and resolved.tooltip, "item data resolves once it arrives")
    addon.Perf.Reset()
end

-- Professions -------------------------------------------------------------------------

local function professionBook(_, skillLineId)
    for _, characterCache in pairs(GuildweaverDB.professionTelemetry or {}) do
        local book = characterCache.recipeBooks and characterCache.recipeBooks["skill:" .. skillLineId]
        if book then
            return book
        end
    end
    return nil
end

do
    local env, addon = start({ recipes = 600 })
    local budget = addon.WorkQueue.FRAME_BUDGET_MS
    local professionRevision = revision(env, "profession_snapshot:")
    env:resetCalls()
    env.tradeSkillOpen = true
    env:dispatch("TRADE_SKILL_SHOW")

    local framesWithRecipes = 0
    local worst = 0
    for _ = 1, 600 do
        local recipesBefore = env:callCount("GetRecipeInfo")
        local cpu = env:nextFrame()
        if env:callCount("GetRecipeInfo") > recipesBefore then
            framesWithRecipes = framesWithRecipes + 1
            worst = math.max(worst, cpu)
        end
    end
    local book = professionBook(env, 164)
    truthy(book, "large book published")
    equal(#book.recipes, 600, "every recipe published")
    truthy(framesWithRecipes >= 10, "scan spread across frames (" .. framesWithRecipes .. ")")
    -- A unit never starts after the budget is spent, so a frame overruns by
    -- at most one unit (one recipe with its reagents and a tooltip render).
    atMost(worst, budget + 1, "per-frame scan time within budget")
    equal(revision(env, "profession_snapshot:"), professionRevision + 1, "one consistent publish")
    local published = env:stream("profession_snapshot:").envelope.payload
    local publishedRecipes = nil
    for _, profession in ipairs(published.professions) do
        if profession.skillLineId == 164 then
            publishedRecipes = profession.recipes
        end
    end
    truthy(publishedRecipes and #publishedRecipes == 600, "profession_snapshot carries the recipe book")
    equal(env:stream("profession_snapshot:").fingerprint, addon.Store.Fingerprint(published),
        "resumable payload fingerprint matches the store's")

    -- The incremental result equals the synchronous reader's.
    local sync = addon.ProfessionTelemetry.CollectOpenRecipeBook("tradeskill")
    local same, why = Env.deepEqual(book.recipes, sync.recipes)
    truthy(same, "incremental recipes equal the synchronous scan: " .. tostring(why))
    same, why = Env.deepEqual(book.categories, sync.categories)
    truthy(same, "categories equal: " .. tostring(why))
    same, why = Env.deepEqual(book.items, sync.items)
    truthy(same, "reagent items equal: " .. tostring(why))

    -- The local snapshot's recipes, converted across frames, equal what a
    -- full character recapture would have stored.
    local expected = addon.TelemetrySchema.NormalizeCharacterSnapshot({
        professions = { { skillLineId = 164, name = "Blacksmithing",
            recipes = addon.ProfessionTelemetry.ToCharacterRecipeOverride(book).recipes } },
    }).professions[1].recipes
    local local164 = nil
    for _, profession in ipairs(addon.Character.GetCurrentSnapshot().professions) do
        if profession.skillLineId == 164 then
            local164 = profession.recipes
        end
    end
    same, why = Env.deepEqual(local164, expected)
    truthy(same, "snapshot recipes equal a full recapture: " .. tostring(why))
    equal(addon.Perf.Category("recipe_publish"), nil, "no full character recapture after a scan")

    -- A rescan with unchanged recipes reuses tooltips and publishes nothing.
    env:resetCalls()
    env:dispatch("TRADE_SKILL_LIST_UPDATE")
    env:advance(10)
    equal(revision(env, "profession_snapshot:"), professionRevision + 1, "unchanged rescan deduped")
    equal(env:callCount("tooltip:GetSpellByID"), 0, "recipe spell tooltips cached")
    equal(env:callCount("tooltip:SetHyperlink"), 0, "crafted and reagent tooltips cached")
    -- Crafting fires a list update per craft; with the same skill and recipe
    -- count the book is not rescanned at all.
    equal(env:callCount("GetRecipeInfo"), 0, "unchanged list update skips the rescan")
    truthy((addon.Perf.Counter("recipe_scans_skipped_unchanged") or 0) >= 1, "skip is counted")

    -- Closing the window mid-scan publishes nothing and keeps the book.
    env.recipeCount = 300
    env:dispatch("TRADE_SKILL_LIST_UPDATE")
    env:advance(1.5)
    equal(addon.WorkQueue.Get("profession:tradeskill"), nil, "list updates settle before rescanning")
    env:dispatch("TRADE_SKILL_LIST_UPDATE")
    env:advance(2.03)
    truthy(addon.WorkQueue.Get("profession:tradeskill"), "rescan in progress")
    env.tradeSkillOpen = false
    env:dispatch("TRADE_SKILL_CLOSE")
    env:advance(10)
    equal(revision(env, "profession_snapshot:"), professionRevision + 1, "closed window publishes nothing")
    equal(#professionBook(env, 164).recipes, 600, "complete book kept after an interrupted scan")

    -- Reopening the unchanged book does not scan it again.
    env.tradeSkillOpen = true
    env.recipeCount = 600
    env:resetCalls()
    env:dispatch("TRADE_SKILL_SHOW")
    env:advance(3)
    equal(env:callCount("GetRecipeInfo"), 0, "reopening an unchanged book skips the scan")
    env.tradeSkillOpen = false
    env:dispatch("TRADE_SKILL_CLOSE")
    env:advance(1)

    -- Switching profession mid-scan cancels the stale job.
    env.tradeSkillOpen = true
    env.recipeCount = 601
    env:dispatch("TRADE_SKILL_SHOW")
    env:advance(1.0)
    truthy(addon.WorkQueue.Get("profession:tradeskill"), "scan in progress before the switch")
    env.openProfession = 186
    env.recipeCount = 50
    env:advance(2)
    equal(#professionBook(env, 164).recipes, 600, "switching does not publish a mixed book")
    equal(professionBook(env, 186), nil, "stale job does not publish the new profession")
    env:dispatch("TRADE_SKILL_DATA_SOURCE_CHANGED")
    env:advance(10)
    equal(#professionBook(env, 186).recipes, 50, "the new profession is scanned on its own")
    equal(#professionBook(env, 164).recipes, 600, "other profession untouched")

    -- Optional work pauses in combat and resumes afterwards.
    env.openProfession = 164
    env.recipeCount = 610
    env:dispatch("TRADE_SKILL_DATA_SOURCE_CHANGED")
    env:advance(0.28)
    truthy(addon.WorkQueue.Get("profession:tradeskill"), "scan in progress before combat")
    env.inCombat = true
    env:dispatch("PLAYER_REGEN_DISABLED")
    local during = env:callCount("GetRecipeInfo")
    env:advance(5)
    equal(env:callCount("GetRecipeInfo"), during, "no recipe work in combat")
    equal(#professionBook(env, 164).recipes, 600, "nothing published in combat")
    env.inCombat = false
    env:dispatch("PLAYER_REGEN_ENABLED")
    env:advance(15)
    equal(#professionBook(env, 164).recipes, 600, "capped book published after combat")
    truthy(env:callCount("GetRecipeInfo") > during, "work resumed after combat")

    -- A skill-up changes the profession list; the large payload is
    -- published across frames rather than inside the capture's frame.
    env:advance(5)
    local beforeSkillUp = revision(env, "profession_snapshot:")
    env.professions[1].skill = 151
    env:dispatch("SKILL_LINES_CHANGED")
    local skillWorst = 0
    for _ = 1, 300 do
        skillWorst = math.max(skillWorst, env:nextFrame())
    end
    equal(revision(env, "profession_snapshot:"), beforeSkillUp + 1, "skill-up publishes once")
    local skillPayload = env:stream("profession_snapshot:").envelope.payload
    equal(skillPayload.professions[1].skillLevel, 151, "new skill level published")
    equal(#skillPayload.professions[1].recipes, 600, "recipes kept with the new skill level")
    truthy(addon.Perf.Category("domain_publish"), "profession payload published by the work queue")
    atMost(skillWorst, budget + 4, "skill-up frames stay near budget")

    -- No permanent OnUpdate and no queued work when idle.
    equal(addon.WorkQueue.Size(), 0, "queue drained")
    for _, frame in ipairs(env.frames) do
        if frame.name ~= "GameTooltip" then
            equal(frame.scripts.OnUpdate, nil, "no OnUpdate script on " .. tostring(frame.name))
        end
    end
end

-- Loot and gathering -------------------------------------------------------------------

do
    local env, addon = start()
    env.items[785] = { itemId = 785, name = "Mageroyal", quality = 1, class = "Trade Goods", equipLocation = "", icon = 2 }
    local herb = Env.itemLink(785, "Mageroyal", 1)
    env:dispatch("UNIT_SPELLCAST_SENT", "player", "Mageroyal", "Cast-1", 2366)
    env.loot = { { link = herb, quantity = 2, source = "GameObject-0-1-2-3-4-1617-0000" } }
    env:resetCalls()
    env:dispatch("LOOT_READY")
    env:dispatch("LOOT_OPENED")

    -- Evidence is stored before any frame passes or the window closes.
    local gathering = env:stream("gathering_loot:")
    truthy(gathering, "gathering loot recorded immediately")
    equal(gathering.envelope.payload.outputs[1].itemId, 785, "loot output retained")
    -- Looting itself renders nothing; definitions are built afterwards.
    equal(env:itemTooltipScans(), 0, "no tooltip rendered during the loot events")
    equal(env:stream("item_definition:item:785"), nil, "item definition deferred")
    equal(env:stream("game_item_definition:item:785"), nil, "public base definition deferred")
    atMost(env:callCount("GetLootSourceInfo"), 2, "collectors share one read of the window per event")

    -- While the window is still open, the exact loot slot is rendered.
    env:nextFrame()
    local definition = env:stream("item_definition:item:785")
    truthy(definition, "item definition captured from the live loot slot")
    equal(definition.envelope.payload.item.tooltip.method, "SetLootItem", "authoritative loot slot tooltip")
    equal(env:callCount("tooltip:SetLootItem"), 1, "loot slot scanned once across collectors")

    env.loot = nil
    env:dispatch("LOOT_CLOSED")
    env:advance(1)
    truthy(env:stream("game_item_definition:item:785"), "deferred definition completes after the window")

    -- Fast auto-loot: the window is gone before the next frame, so the item
    -- link is rendered instead.
    env.items[2453] = { itemId = 2453, name = "Bruiseweed", quality = 1, class = "Trade Goods", equipLocation = "", icon = 3 }
    env.loot = { { link = Env.itemLink(2453, "Bruiseweed", 1), quantity = 1, source = "Creature-0-1-2-3-99-000777" } }
    env:dispatch("LOOT_READY")
    env:dispatch("LOOT_OPENED")
    env.loot = nil
    env:dispatch("LOOT_CLOSED")
    env:advance(1)
    local fast = env:stream("item_definition:item:2453")
    truthy(fast, "definition still captured after a fast auto-loot")
    equal(fast.envelope.payload.item.tooltip.method, "SetHyperlink", "falls back to the item link")

    -- Known items cost nothing on later loots, even after a reload.
    env:resetCalls()
    env.loot = { { link = herb, quantity = 1, source = "Creature-0-1-2-3-99-000778" } }
    env:dispatch("LOOT_READY")
    env:dispatch("LOOT_OPENED")
    env.loot = nil
    env:dispatch("LOOT_CLOSED")
    env:advance(1)
    equal(env:itemTooltipScans(), 0, "an already defined item is never rendered again")
    addon.Perf.Reset()
end

-- Reload and logout ----------------------------------------------------------------------

do
    local env, addon = start({ recipes = 120 })
    env.tradeSkillOpen = true
    env:dispatch("TRADE_SKILL_SHOW")
    env:advance(5)
    local professionRevision = revision(env, "profession_snapshot:")
    truthy(professionRevision >= 1, "recipes captured")

    env:dispatch("PLAYER_LOGOUT")
    local snapshot = addon.Character.GetCurrentSnapshot()
    truthy(#snapshot.equipment > 0, "logout keeps the rich snapshot")
    local checkpoint = nil
    for key, record in pairs(env:telemetry()) do
        if key:find(":end", 1, true) and key:find("character_session:", 1, true) == 1 then
            checkpoint = record
        end
    end
    truthy(checkpoint, "end checkpoint written at logout")
    for _, profession in ipairs(checkpoint.envelope.payload.professions) do
        equal(profession.recipes, nil, "checkpoints do not repeat recipe books")
        if profession.skillLineId == 164 then
            equal(profession.recipeCount, 120, "checkpoint keeps the recipe count")
        end
    end

    -- Reload: the saved database is kept and nothing is re-sent.
    local saved = GuildweaverDB
    local reloaded = Env.new({ recipes = 120 })
    reloaded:load()
    GuildweaverDB = saved
    local professionCaptures = 0
    local professionDomain = reloaded.addon.TelemetryDomains.Professions
    local captureProfessions = professionDomain.Capture
    professionDomain.Capture = function(...)
        professionCaptures = professionCaptures + 1
        return captureProfessions(...)
    end
    reloaded:login()
    reloaded:advance(5)
    equal(reloaded.reloads, 0, "no reload after reloading")
    equal(revision(reloaded, "profession_snapshot:"), professionRevision, "recipes survive reload unchanged")
    equal(professionCaptures, 0, "unchanged recipe payload not rebuilt after reload")
    truthy(#reloaded.addon.Character.GetCurrentSnapshot().professions[1].recipes > 0, "snapshot recipes retained")
end

-- Recipe books cached by earlier versions under the surname-shaped key are
-- adopted by the canonical character and published.
do
    local env = Env.new()
    local addon = env:load()
    GuildweaverDB = {
        gameRelease = "forever-live",
        professionTelemetry = {
            ["ravenstar:rook"] = {
                professions = { ["skill:164"] = { skillLineId = 164, name = "Blacksmithing" } },
                order = { "skill:164" },
                recipeBooks = {
                    ["skill:164"] = {
                        source = "C_TradeSkillUI",
                        capturedAt = 1791000000,
                        fingerprint = "legacy",
                        recipes = { { recipeId = 2660, name = "Rough Sharpening Stone", known = true } },
                    },
                },
            },
        },
    }
    env:login()
    env:advance(3)
    local payload = env:stream("profession_snapshot:").envelope.payload
    local adopted = nil
    for _, profession in ipairs(payload.professions) do
        if profession.skillLineId == 164 then
            adopted = profession.recipes
        end
    end
    truthy(adopted and adopted[1].recipeId == 2660, "previously collected recipes are published")
    equal(GuildweaverDB.professionTelemetry["ravenstar:rook"], nil, "alias cache removed after adoption")
    truthy(addon.Character.ProfessionCacheKey() == "live realm:rook ravenstar", "canonical cache key")
end

-- Live-client guard -----------------------------------------------------------------------

do
    local env = Env.new()
    env.player.realm = "Classic Beta PvE 2"
    env:load()
    env:login()
    env:advance(3)
    equal(GuildweaverDB.gameRelease, nil, "beta client never marked live")
    local beta = GuildweaverDB
    local live = Env.new()
    live:load()
    GuildweaverDB = beta
    live:dispatch("ADDON_LOADED", "Guildweaver")
    equal(next(GuildweaverDB.characters), nil, "beta data is not ingested by the live client")
end

-- Work queue bounds ------------------------------------------------------------------------

do
    local _, addon = start()
    local queue = addon.WorkQueue
    for index = 1, queue.MAX_JOBS + 10 do
        queue.Enqueue({ key = "test:" .. index, optional = true, step = function() return true end })
    end
    atMost(queue.Size(), queue.MAX_JOBS, "queue bounded")
    truthy(queue.Stats().dropped >= 10, "oldest optional jobs dropped")
    local same = queue.Enqueue({ key = "test:dup", optional = true, step = function() return true end })
    equal(queue.Enqueue({ key = "test:dup", optional = true, step = function() return true end }), same, "duplicate jobs coalesce")
end

-- Sustained work backs off instead of taking a slice of every frame.
do
    local env, addon = start()
    local queue = addon.WorkQueue
    local steps = 0
    queue.Enqueue({ key = "test:long", optional = true, step = function()
        steps = steps + 1
        return steps >= 200
    end })
    local busyFrames = 0
    for _ = 1, 120 do
        local before = steps
        env:nextFrame()
        if steps > before then
            busyFrames = busyFrames + 1
        end
    end
    truthy(queue.Stats().backoffs >= 1, "long-running work backs off")
    truthy(busyFrames < 120, "the queue skips frames under sustained load (" .. busyFrames .. "/120)")
    env:advance(10)
    equal(steps, 200, "backed-off work still finishes")
end

-- Area loot: many new items in one window render nothing in the loot frame
-- and are defined over the following frames within the budget.
do
    local env, addon = start()
    env.eventsInFrames = true
    local entries = {}
    for index = 1, 12 do
        local itemId = 30000 + index
        table.insert(entries, { link = Env.itemLink(itemId, "Reagent " .. index, 1), quantity = 1,
            source = string.format("Creature-0-1-2-3-55-%06d", index) })
    end
    env.loot = entries
    env:resetCalls()
    env:dispatch("LOOT_READY", true)
    env:dispatch("LOOT_OPENED", true)
    equal(env:itemTooltipScans(), 0, "area loot renders no tooltip during the events")
    local corpses = 0
    for key in pairs(env:telemetry()) do
        if key:find("mob_loot:", 1, true) == 1 then
            corpses = corpses + 1
        end
    end
    equal(corpses, 12, "every corpse recorded immediately")
    local worst = 0
    for _ = 1, 120 do
        worst = math.max(worst, env:nextFrame())
    end
    env.loot = nil
    env:dispatch("LOOT_CLOSED")
    env:advance(2)
    for index = 1, 12 do
        truthy(env:stream("item_definition:item:" .. (30000 + index)), "item " .. index .. " defined afterwards")
    end
    atMost(worst, addon.WorkQueue.FRAME_BUDGET_MS + 1, "enrichment frames stay within budget")

    -- After a reload the stored definitions are not built again.
    local saved = GuildweaverDB
    local reloaded = Env.new()
    reloaded:load()
    GuildweaverDB = saved
    reloaded:login()
    reloaded:advance(3)
    reloaded.loot = entries
    reloaded:resetCalls()
    reloaded:dispatch("LOOT_READY", true)
    reloaded.loot = nil
    reloaded:dispatch("LOOT_CLOSED")
    reloaded:advance(2)
    equal(reloaded:itemTooltipScans(), 0, "items defined in an earlier session are not rendered again")
end

-- The saved corpse cache stays bounded and is not walked on every loot.
do
    local env, addon = start()
    local db = addon.Store.GetDatabase()
    db.meta.mobLootSeen = {}
    for index = 1, 1200 do
        db.meta.mobLootSeen["x:" .. index] = { at = env.serverTime - 100 + index % 50, outputs = {} }
    end
    addon.MobLootCapture.ResetSeenCache()
    local function loot(guid)
        env.loot = { { link = Env.itemLink(2589, "Linen Cloth", 1), quantity = 1, source = guid } }
        env:dispatch("LOOT_READY", true)
        env.loot = nil
        env:dispatch("LOOT_CLOSED")
        env:advance(0.5)
    end
    loot("Creature-0-1-2-3-77-000001")
    local remembered = 0
    for _ in pairs(db.meta.mobLootSeen) do
        remembered = remembered + 1
    end
    atMost(remembered, 1000, "corpse cache cut back below its limit")
    local revisionBefore = revision(env, "mob_loot:")
    loot("Creature-0-1-2-3-77-000001")
    equal(revision(env, "mob_loot:"), revisionBefore, "the same corpse is still not counted twice")
end

-- Quickly opening and closing professions starts no scan; a gear swap
-- renders only the changed slot.
do
    local env = start({ recipes = 300 })
    env:resetCalls()
    for _ = 1, 8 do
        env.tradeSkillOpen = true
        env:dispatch("TRADE_SKILL_SHOW")
        env:advance(0.3)
        env.tradeSkillOpen = false
        env:dispatch("TRADE_SKILL_CLOSE")
        env:advance(0.2)
    end
    env:advance(5)
    equal(env:callCount("GetRecipeInfo"), 0, "open/close spam never starts a scan")

    env:resetCalls()
    env.equipment[5] = Env.itemLink(10018, "Gear Piece 18", 2)
    env:dispatch("PLAYER_EQUIPMENT_CHANGED", 5, true)
    env:advance(2)
    equal(env:callCount("tooltip:SetInventoryItem"), 1, "only the changed slot is rendered again")
end

print("performance regressions spec passed")
