-- Loot alerts in the fake client: the wishlist and watchlist the bridge
-- writes, the rule engine, Need/Greed rolls from START_LOOT_ROLL to
-- cleanup, the passive glow on the game's roll frame, the Guildweaver
-- notice, the chime, and the telemetry a roll leaves behind. These prove
-- behaviour, not looks: the fake client renders nothing.

local Env = dofile("test/support/wow_env.lua")

local function equal(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function truthy(value, label)
    if not value then error((label or "value") .. ": expected truthy value", 2) end
end

local function falsy(value, label)
    if value then error((label or "value") .. ": expected nil or false, got " .. tostring(value), 2) end
end

local world

local SM = { name = "Scarlet Monastery", type = "party", difficultyId = 1, difficultyName = "Normal", maxPlayers = 5, id = 189 }

local function link(itemId, name, suffix)
    return "|cff0070dd|Hitem:" .. itemId .. ":0:0:0:0:0:" .. (suffix or 0) .. ":0|h[" .. name .. "]|h|r"
end

-- Rolls the client knows: [rollId] = { link, texture, name, count, quality, bindOnPickUp }.
local ROLLS = {
    barb = { link(5191, "Cruel Barb"), "Interface\\Icons\\INV_Sword_27", "Cruel Barb", 1, 3, true },
    shield = { link(6694, "Phantom Shield"), "Interface\\Icons\\INV_Shield_05", "Phantom Shield", 1, 3, false },
    bearBelt = { link(6468, "Deviate Scale Belt of the Bear", -1081), "Interface\\Icons\\INV_Belt_04", "Deviate Scale Belt of the Bear", 1, 3, false },
    owlBelt = { link(6468, "Deviate Scale Belt of the Owl", -754), "Interface\\Icons\\INV_Belt_04", "Deviate Scale Belt of the Owl", 1, 3, false },
    rompers = { link(2168, "Corpse Rompers"), "Interface\\Icons\\INV_Boots_05", "Corpse Rompers", 1, 2, false },
    stale = { link(9999, "Old Listing"), "Interface\\Icons\\INV_Misc_Gem_01", "Old Listing", 1, 2, false },
    cape = { link(5193, "Cape of the Brotherhood"), "Interface\\Icons\\INV_Misc_Cape_02", "Cape of the Brotherhood", 1, 2, true },
    junk = { link(4444, "Black Husk Shield"), "Interface\\Icons\\INV_Shield_02", "Black Husk Shield", 1, 2, false },
}

local function installWorld(env)
    local G = _G
    world = { instance = nil, rolls = {}, sounds = {}, decisions = 0 }
    G.IsInInstance = function() return world.instance ~= nil, world.instance and world.instance.type or "none" end
    G.GetInstanceInfo = function()
        local instance = world.instance
        if not instance then return "Elwynn Forest", "none", 0, "", 0, 0, false, 0 end
        return instance.name, instance.type, instance.difficultyId, instance.difficultyName, instance.maxPlayers, 0, false, instance.id
    end
    G.UnitXP = function() return 1000 end
    G.UnitXPMax = function() return 5000 end
    G.GetMaxPlayerLevel = function() return 60 end
    G.GetNumGroupMembers = function() return 5 end
    G.GetInstanceLockTimeRemaining = function() return 3600, false, 3, 0 end
    G.GetLootRollItemLink = function(rollId) local roll = world.rolls[rollId]; return roll and roll[1] or nil end
    G.GetLootRollItemInfo = function(rollId)
        local roll = world.rolls[rollId]
        if not roll or roll.infoMissing then return nil end
        return roll[2], roll[3], roll[4], roll[5], roll[6], true, true, true
    end
    G.PlaySound = function(id, channel) table.insert(world.sounds, { id = id, channel = channel }) end
    G.NUM_GROUP_LOOT_FRAMES = 4
    G.LOOT_ITEM_SELF = "You receive loot: %s."
    G.LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d."
    -- Deciding a roll, and anything protected: an add-on that calls these
    -- is rolling for the player. Guildweaver must never call any of them.
    for _, name in ipairs({ "RollOnLoot", "ConfirmLootRoll", "CastSpellByName", "UseAction", "TargetUnit", "RunMacroText", "PickupContainerItem", "UseContainerItem" }) do
        G[name] = function() world.decisions = world.decisions + 1 end
    end
    for index = 1, 4 do G["GroupLootFrame" .. index] = nil end
    env.world = world
end

-- The game's own roll frame, strict: reading what it shows is fine, and
-- anything else done to it (a write, a script, moving, hiding, parenting)
-- is counted.
local function rollFrame(index, rollId)
    local state = { shown = true, touched = {} }
    local allowed = {
        IsShown = function() return state.shown end,
        IsForbidden = function() return false end,
        GetFrameStrata = function() return "DIALOG" end,
        GetFrameLevel = function() return 5 end,
        GetName = function() return "GroupLootFrame" .. index end,
    }
    local frame = setmetatable({ rollID = rollId }, {
        __index = function(_, key)
            if allowed[key] then return allowed[key] end
            return function() table.insert(state.touched, key) end
        end,
        __newindex = function(_, key) table.insert(state.touched, "write:" .. tostring(key)) end,
    })
    _G["GroupLootFrame" .. index] = frame
    return frame, state
end

local function fixtureInbox()
    local holder = {}
    assert(loadfile("test/fixtures/BridgeLoot.generated.lua"))("Guildweaver", holder)
    return holder.BridgeLoot
end

local function boot(options)
    options = options or {}
    local env = Env.new()
    local addon = env:load()
    installWorld(env)
    if options.db then GuildweaverDB = options.db end
    if options.inbox ~= false then addon.BridgeLoot = options.inbox or fixtureInbox() end
    env:login()
    env:advance(3)
    return env, addon
end

local function startRoll(env, rollId, which, options)
    world.rolls[rollId] = which and { which[1], which[2], which[3], which[4], which[5], which[6] } or nil
    if options and options.infoMissing then world.rolls[rollId].infoMissing = true end
    env:dispatch("START_LOOT_ROLL", rollId, 60000)
end

local function rollStream(env, addon, rollId)
    local roll = addon.LootRolls.active[rollId]
    for key, record in pairs(env:telemetry()) do
        if key:find("loot_roll:", 1, true) == 1 and roll and key:find(roll.key, 1, true) then return record, key end
    end
    return nil
end

local function countStreams(env, prefix)
    local count = 0
    for key in pairs(env:telemetry()) do
        if key:find(prefix, 1, true) == 1 then count = count + 1 end
    end
    return count
end

-- The bridge's file ------------------------------------------------------------------------

do
    local env, addon = boot()
    local sync = addon.LootSync
    local status = sync.Status()
    equal(status.result, "applied", "the bridge's own output loads and validates")
    equal(status.matched, true, "the logged-in character is found")
    equal(status.how, "name", "by name and realm when the id is not listed (Forever surnames included)")
    equal(status.characterName, "Rook Ravenstar")
    equal(status.wanted, 3)
    equal(status.watch, 4)
    equal(status.revision, 5)
    equal(GuildweaverDB.sync.inbound.loot.digest, "c2b55187c75b0262", "the validated copy is saved")
    equal(GuildweaverDB.sync.inbound.loot.characters[1].wishlist.items[3].note, 'Tank "swap"\nset', "website text arrives as data, exactly")

    -- Matching: exact variant, base item for any suffix, nothing else.
    equal(sync.WishlistEntry(5191, "i:5191").priority, "high")
    equal(sync.WishlistEntry(6468, "i:6468:s-1081").priority, "low", "the wanted variant")
    falsy(sync.WishlistEntry(6468, "i:6468:s-754"), "another suffix of a wanted variant is not wanted")
    falsy(sync.WishlistEntry(6468, "i:6468"), "nor is the plain item")
    equal(sync.WishlistEntry(6694, "i:6694:s-17").itemId, 6694, "a wanted base item matches any suffix")
    falsy(sync.WishlistEntry(5193, "i:5193"), "another character's wishlist never matches")
    equal(sync.ItemKey(6468, -1081), "i:6468:s-1081")
    equal(sync.ItemKey(6468, 0), "i:6468")

    -- Values: this character's market, exact key, fresh.
    equal(sync.BoeValue(6694, "i:6694").value, 250000)
    equal(sync.BoeValue(6468, "i:6468:s-1081").confidence, "high")
    local none, why = sync.BoeValue(6468, "i:6468:s-754")
    falsy(none, "a suffix is never valued by another suffix")
    equal(why, "not_listed")
    equal(select(2, sync.BoeValue(9999, "i:9999")), "stale", "a value observed too long ago")
    equal(sync.BoeValue(9999, "i:9999", 1790000100).value, 900000, "which was fine when it was fresh")

    -- Reload with the same file: nothing to do.
    equal(sync.Initialize(), "unchanged")

    -- By the add-on's own id, when the website lists it.
    local snapshot = addon.Character.GetCurrentSnapshot()
    truthy(snapshot and snapshot.characterId, "character snapshot")
    local inbox = fixtureInbox()
    inbox.digest, inbox.generatedAt = "aliasdigest", inbox.generatedAt + 10
    inbox.characters[1].name = "Someone Else"
    inbox.characters[2].aliases = { snapshot.characterId }
    addon.BridgeLoot = inbox
    equal(sync.Initialize(), "applied")
    equal(sync.Status().how, "alias")
    equal(sync.Status().characterName, "Fern")
    equal(sync.Status().market, nil, "that character has no market")
    equal(select(2, sync.BoeValue(6694, "i:6694")), "no_market")
    truthy(sync.WishlistEntry(5193, "i:5193"))

    -- Nobody matches: no wishlist, no value, no alerts.
    inbox = fixtureInbox()
    inbox.digest, inbox.generatedAt = "nomatch", inbox.generatedAt + 20
    inbox.characters[1].name, inbox.characters[2].name = "Thorn", "Moss"
    addon.BridgeLoot = inbox
    equal(sync.Initialize(), "applied")
    equal(sync.Status().matched, false)
    falsy(sync.WishlistEntry(5191, "i:5191"))
    equal(select(2, sync.BoeValue(6694, "i:6694")), "no_character")
    falsy(addon.LootAlerts.Evaluate({ itemId = 5191, itemKey = "i:5191", bindOnPickUp = true }))
    equal(env.world.decisions, 0)
end

-- A bad, missing or older file never replaces the last good one ---------------------------

do
    local env, addon = boot()
    local sync = addon.LootSync
    local good = GuildweaverDB.sync.inbound.loot
    local function with(change)
        local inbox = fixtureInbox()
        inbox.digest = "changed"
        inbox.generatedAt = inbox.generatedAt + 100
        change(inbox)
        return inbox
    end
    local bad = {
        missing = false,
        text = "GW.BridgeLoot = nil",
        schema = with(function(inbox) inbox.schemaVersion = 2 end),
        header = with(function(inbox) inbox.revision = "5" end),
        noDigest = with(function(inbox) inbox.digest = "" end),
        characters = with(function(inbox) inbox.characters = "none" end),
        boe = with(function(inbox) inbox.boe = nil end),
        item = with(function(inbox) inbox.characters[1].wishlist.items[2].itemId = "6468" end),
        key = with(function(inbox) inbox.characters[1].wishlist.items[1].itemKey = "i:999" end),
        priority = with(function(inbox) inbox.characters[1].wishlist.items[1].priority = "urgent" end),
        value = with(function(inbox) inbox.boe.markets["game:us:live-realm:alliance"].items[1].v = -4 end),
        confidence = with(function(inbox) inbox.boe.markets["game:us:live-realm:alliance"].items[1].c = "low" end),
        market = with(function(inbox) inbox.boe.markets["game:us:live-realm:alliance"] = 7 end),
    }
    for name, inbox in pairs(bad) do
        addon.BridgeLoot = inbox or nil
        equal(sync.Initialize(), "kept", name .. ": the saved wishlist stays")
        equal(GuildweaverDB.sync.inbound.loot, good, name .. ": untouched")
        equal(sync.WishlistEntry(5191, "i:5191").priority, "high", name .. ": and still answers")
    end
    -- Older than what is saved (a delayed write): ignored.
    local older = fixtureInbox()
    older.digest, older.generatedAt, older.characters = "older", older.generatedAt - 500, {}
    addon.BridgeLoot = older
    equal(sync.Initialize(), "stale")
    equal(sync.Status().reason, "stale_revision")
    equal(GuildweaverDB.sync.inbound.loot, good)

    -- Offline, across a relog with no file at all: the saved copy works.
    env:dispatch("PLAYER_LOGOUT")
    local _, again = boot({ db = GuildweaverDB, inbox = false })
    equal(again.LootSync.Status().result, "kept")
    equal(again.LootSync.Status().wanted, 3, "the last valid wishlist is available offline")
    equal(again.LootSync.WishlistEntry(5191, "i:5191").note, "Main hand until 30")

    -- Bounds: far more than the limits is cut, not loaded whole.
    local big = fixtureInbox()
    big.digest, big.generatedAt = "big", big.generatedAt + 1000
    for index = 1, 500 do
        table.insert(big.characters[1].wishlist.items, { itemId = 20000 + index, itemKey = "i:" .. (20000 + index), priority = "normal", note = string.rep("n", 500) })
    end
    again.BridgeLoot = big
    equal(again.LootSync.Initialize(), "applied")
    equal(#GuildweaverDB.sync.inbound.loot.characters[1].wishlist.items, again.LootSync.LIMITS.wishlistItems)
    equal(#GuildweaverDB.sync.inbound.loot.characters[1].wishlist.items[4].note, 140)

    -- With nothing ever loaded there is simply no alert.
    local _, fresh = boot({ inbox = false })
    equal(fresh.LootSync.Status().result, "empty")
    falsy(fresh.LootAlerts.Evaluate({ itemId = 5191, itemKey = "i:5191", bindOnPickUp = true }))
end

-- The rule engine --------------------------------------------------------------------------

do
    local _, addon = boot()
    local alerts, theme = addon.LootAlerts, addon.Theme
    local prefs = alerts.Prefs()

    local wish = alerts.Evaluate({ itemId = 5191, itemKey = "i:5191", bindOnPickUp = true })
    equal(wish.category, "wishlist")
    equal(#wish.reasons, 1)
    equal(wish.primary.wishPriority, "high")
    equal(wish.primary.note, "Main hand until 30")
    equal(wish.value, nil)
    equal(wish.sound, true)

    local boe = alerts.Evaluate({ itemId = 2168, itemKey = "i:2168", bindOnPickUp = false })
    falsy(boe, "6g is under the default 10g threshold")
    prefs.boeThreshold = 50000
    boe = alerts.Evaluate({ itemId = 2168, itemKey = "i:2168", bindOnPickUp = false })
    equal(boe.category, "valuable_boe")
    equal(boe.value, 60000)
    equal(boe.valueConfidence, "medium")
    truthy(boe.valueAge and boe.valueAge >= 0, "freshness travels with the value")
    prefs.boeThreshold = 100000

    -- Both reasons: purple first, and the value is still there.
    local both = alerts.Evaluate({ itemId = 6694, itemKey = "i:6694", bindOnPickUp = false })
    equal(both.category, "wishlist", "Wishlist > Valuable BoE")
    equal(#both.reasons, 2)
    equal(both.reasons[2].id, "valuable_boe", "the secondary reason is kept")
    equal(both.value, 250000)
    truthy(both.priority > both.reasons[2].priority)
    local title, detail = alerts.Describe(both)
    equal(title, "Wishlist + Valuable BoE")
    truthy(detail:find("~25g on the AH", 1, true), "the estimate is shown: " .. detail)
    truthy(detail:find("Tank", 1, true), "with the wishlist note")
    truthy(not detail:find("yours", 1, true) and not detail:find("won", 1, true), "an alert never says the item is the player's")

    -- No gold alert without proof the item is tradeable and worth it.
    falsy(alerts.Evaluate({ itemId = 2168, itemKey = "i:2168", bindOnPickUp = true }), "binds on pickup")
    falsy(alerts.Evaluate({ itemId = 2168, itemKey = "i:2168" }), "binding unknown")
    falsy(alerts.Evaluate({ itemId = 9999, itemKey = "i:9999", bindOnPickUp = false }), "stale price")
    falsy(alerts.Evaluate({ itemId = 4444, itemKey = "i:4444", bindOnPickUp = false, quality = 4 }), "an epic with no price is not valuable by colour")
    falsy(alerts.Evaluate({ itemId = 6468, itemKey = "i:6468:s-754", bindOnPickUp = false }), "a suffix that cannot be valued")
    falsy(alerts.Evaluate({}), "no item")
    falsy(alerts.Evaluate(nil))

    -- Each category can be turned off on its own.
    prefs.boe = false
    equal(#alerts.Evaluate({ itemId = 6694, itemKey = "i:6694", bindOnPickUp = false }).reasons, 1, "wishlist still alerts")
    prefs.boe, prefs.wishlist = true, false
    equal(alerts.Evaluate({ itemId = 6694, itemKey = "i:6694", bindOnPickUp = false }).category, "valuable_boe", "gold still alerts")
    falsy(alerts.Evaluate({ itemId = 5191, itemKey = "i:5191", bindOnPickUp = true }))
    prefs.wishlist, prefs.sound = true, false
    equal(alerts.Evaluate({ itemId = 5191, itemKey = "i:5191", bindOnPickUp = true }).sound, false)
    prefs.sound = true

    -- The upgrade category is reserved: known to the theme, raised by nothing.
    local upgrade
    for _, rule in ipairs(alerts.rules) do
        if rule.id == "upgrade" then upgrade = rule end
    end
    truthy(upgrade and upgrade.reserved, "the category exists in the engine")
    truthy(theme.alerts.upgrade, "and has its colour")
    falsy(alerts.Evaluate({ itemId = 77777, itemKey = "i:77777", bindOnPickUp = true, itemLevel = 99 }), "but nothing claims an upgrade")
    equal(alerts.rules[1].id, "wishlist")
    equal(alerts.rules[2].id, "valuable_boe")
    equal(alerts.rules[3].id, "upgrade")

    -- Colours live in the theme, one per category, all different.
    local purple, gold, blue = theme.AlertColor("wishlist"), theme.AlertColor("valuable_boe"), theme.AlertColor("upgrade")
    truthy(purple[3] > purple[2] and purple[1] > purple[2], "wishlist is purple")
    truthy(gold[1] > gold[3] and gold[2] > gold[3], "valuable BoE is gold")
    truthy(blue[3] > blue[1], "potential upgrade is blue")
    equal(theme.AlertLabel("valuable_boe"), "Valuable BoE")

    -- A new category needs no change anywhere else.
    truthy(alerts.Register({ id = "transmog", priority = 150, evaluate = function(item) return item.itemId == 31337 and { note = "new look" } or nil end }))
    local custom = alerts.Evaluate({ itemId = 31337, itemKey = "i:31337" })
    equal(custom.category, "transmog")
    equal(alerts.rules[3].id, "transmog", "ordered by priority")
    -- A rule that throws is one rule failing, not the roll.
    alerts.Register({ id = "broken", priority = 999, evaluate = function() error("boom") end })
    equal(alerts.Evaluate({ itemId = 5191, itemKey = "i:5191", bindOnPickUp = true }).category, "wishlist")

    equal(alerts.FormatValue(254300), "25g 43s")
    equal(alerts.FormatValue(2500000), "250g")
    equal(alerts.FormatValue(8500), "85s")
    equal(alerts.FormatAge(600), "10m old")
    equal(alerts.FormatAge(7200), "2h old")
    equal(alerts.FormatAge(259200), "3d old")
end

-- Rolls: detection, glow, notice, chime, cleanup -------------------------------------------

do
    local env, addon = boot()
    local rolls, ui, alerts, theme = addon.LootRolls, addon.LootAlertUI, addon.LootAlerts, addon.Theme
    truthy(rolls.registered.START_LOOT_ROLL and rolls.registered.CANCEL_LOOT_ROLL, "roll events are registered")
    world.instance = SM
    env:dispatch("PLAYER_ENTERING_WORLD", false, false)
    env:advance(2)
    truthy(addon.DungeonHud.visible, "the dungeon HUD is on screen")
    local modeBefore = addon.DungeonHud.Mode()

    -- A wishlisted item comes up, with the game's roll frame showing it.
    local frame, frameState = rollFrame(1, 11)
    startRoll(env, 11, ROLLS.barb)
    local roll = rolls.active[11]
    truthy(roll and roll.item, "the roll is resolved")
    equal(roll.item.itemId, 5191)
    equal(roll.item.itemKey, "i:5191")
    equal(roll.item.bindOnPickUp, true)
    equal(roll.alert.category, "wishlist")
    truthy(roll.halo, "the game's roll frame gets a glow")
    equal(roll.halo.target, frame, "around that roll's own frame")
    equal(roll.halo.color, theme.AlertColor("wishlist"), "in the wishlist's purple")
    equal(roll.halo.frame.shown, true)
    equal(#frameState.touched, 0, "the game's frame is only looked at: " .. table.concat(frameState.touched, ","))
    equal(#world.sounds, 1, "one chime")
    equal(world.sounds[1].id, 3081)

    -- The Guildweaver notice: under the HUD, which glows too.
    equal(ui.frame.shown, true)
    equal(ui.anchoredTo, "hud")
    equal(#ui.entries, 1)
    equal(ui.rows[1].text, "Wishlist | High priority \194\183 Main hand until 30")
    equal(ui.hudHalo.lit, true, "the dungeon HUD glows")
    equal(ui.hudHalo.target, addon.DungeonHud.frame)
    equal(ui.hudHalo.color, theme.AlertColor("wishlist"))
    equal(addon.DungeonHud.Mode(), modeBefore, "the HUD's mode is left alone")
    falsy(addon.MainFrame.frame and addon.MainFrame.frame.shown and addon.MainFrame.opened, "the dashboard is not opened")

    -- The same roll announced again: no second alert, sound or telemetry.
    env:dispatch("START_LOOT_ROLL", 11, 60000)
    env:dispatch("START_LOOT_ROLL", 11, 60000)
    equal(rolls.stats.duplicates, 2)
    equal(#world.sounds, 1, "no repeated chime")
    equal(#ui.entries, 1, "no repeated notice")
    equal(countStreams(env, "loot_roll:"), 1, "one roll, one stream")

    -- Telemetry: an offer, in this dungeon, by this character. Not a win.
    local record = rollStream(env, addon, 11)
    truthy(record, "the roll is reported")
    equal(record.kind, "event")
    local payload = record.envelope.payload
    equal(record.envelope.eventType, "loot_roll")
    equal(payload.evidence, "group_roll")
    equal(payload.outcome, "offered")
    equal(payload.acquired, nil, "an offer is not an acquisition")
    equal(payload.item.itemId, 5191)
    equal(payload.item.itemKey, "i:5191")
    equal(payload.item.bindOnPickUp, true)
    equal(payload.context.instance.instanceId, 189)
    equal(payload.context.instance.type, "party")
    equal(payload.context.source, nil, "no creature is named without proof")
    truthy(payload.context.dungeonRun and payload.context.dungeonRun.runId, "linked to the open run")
    truthy(payload.rollKey:match("^[%w:%.%-_]+$") and #payload.rollKey <= 160, "a key the website accepts: " .. payload.rollKey)
    truthy(record.envelope.characterId and record.envelope.gameBuild, "with the character and the game build")

    -- More rolls at once, each on its own frame with its own colour.
    local shieldFrame = rollFrame(2, 12)
    local rompersFrame = rollFrame(3, 13)
    env:advance(2)
    alerts.Prefs().boeThreshold = 50000
    startRoll(env, 12, ROLLS.shield)
    startRoll(env, 13, ROLLS.rompers)
    startRoll(env, 14, ROLLS.junk)
    equal(rolls.active[12].alert.category, "wishlist", "a wanted BoE is purple")
    equal(rolls.active[12].alert.value, 250000, "and still carries its value")
    equal(rolls.active[12].halo.target, shieldFrame)
    equal(rolls.active[12].halo.color, theme.AlertColor("wishlist"))
    equal(rolls.active[13].alert.category, "valuable_boe")
    equal(rolls.active[13].halo.target, rompersFrame)
    equal(rolls.active[13].halo.color, theme.AlertColor("valuable_boe"), "gold for a valuable BoE")
    truthy(rolls.active[11].halo ~= rolls.active[12].halo and rolls.active[12].halo ~= rolls.active[13].halo, "one glow per roll")
    falsy(rolls.active[14].alert, "an ordinary item is left alone")
    falsy(rolls.active[14].halo)
    equal(#ui.entries, 3)
    equal(ui.entries[1].item.itemId, 2168, "newest first")
    truthy(ui.rows[1].text:find("Valuable BoE | ~6g on the AH", 1, true), ui.rows[1].text)
    truthy(ui.rows[2].text:find("Wishlist + Valuable BoE", 1, true), ui.rows[2].text)
    equal(ui.hudHalo.color, theme.AlertColor("valuable_boe"), "the newest alert colours the HUD's glow")
    equal(#world.sounds, 2, "rolls that start together share one chime")
    equal(countStreams(env, "loot_roll:"), 4, "every roll is reported, alert or not")

    -- A roll ends: its glow and its notice go, the others stay.
    local glow12 = rolls.active[12].halo
    env:dispatch("CANCEL_LOOT_ROLL", 12)
    falsy(rolls.active[12], "the roll is gone")
    equal(glow12.frame.shown, false, "its glow is removed with it")
    falsy(glow12.target, "and let go of the game's frame")
    equal(#ui.entries, 2)
    truthy(rolls.active[11].halo and rolls.active[13].halo, "other rolls keep their glow")
    equal(rolls.active[11].halo.frame.shown, true)
    -- The game reuses a frame for another roll: the old glow lets go by itself.
    local glow11 = rolls.active[11].halo
    rawset(frame, "rollID", 99)
    glow11.frame.scripts.OnUpdate(glow11.frame, 0.3)
    falsy(rolls.active[11].halo, "a glow never stays on a frame showing another roll")
    equal(glow11.frame.shown, false)
    -- Notices dismiss themselves.
    env:advance(ui.SECONDS + 1)
    equal(#ui.entries, 0)
    equal(ui.frame.shown, false)
    equal(ui.hudHalo.lit, false, "the HUD stops glowing")
    -- And rolls nobody cancels expire with their timer.
    env:advance(70)
    falsy(next(rolls.active), "no roll is kept forever")
    equal(#frameState.touched, 0, "nothing was ever done to the game's frame")
    equal(world.decisions, 0, "Guildweaver never rolls, passes or calls anything protected")
end

-- Chime cooldown, sound off, and the frame not being there ---------------------------------

do
    local env, addon = boot()
    local rolls, ui, alerts = addon.LootRolls, addon.LootAlertUI, addon.LootAlerts
    -- No GroupLootFrame at all (another loot add-on replaced the roll UI).
    startRoll(env, 21, ROLLS.barb)
    env:advance(2)
    local roll = rolls.active[21]
    equal(roll.alert.category, "wishlist")
    falsy(roll.halo, "no native glow without the game's frame")
    falsy(roll.nativeGlow)
    equal(roll.noticeShown, true, "the Guildweaver notice still shows")
    equal(ui.anchoredTo, "screen", "on its own, since the HUD is not on screen")
    equal(ui.frame.shown, true)
    equal(ui.hudHalo.lit, false)
    equal(#world.sounds, 1)

    -- A frame that is there but refuses to be read: the alert still works.
    _G.GroupLootFrame1 = setmetatable({}, { __index = function() error("forbidden") end })
    startRoll(env, 22, ROLLS.shield)
    env:advance(2)
    truthy(rolls.active[22].alert, "a broken roll frame does not break the alert")
    falsy(rolls.active[22].halo)
    _G.GroupLootFrame1 = nil
    -- A forbidden or hidden frame is left alone.
    local hidden = rollFrame(2, 23)
    rawset(hidden, "rollID", 23)
    getmetatable(hidden).__index = function(_, key)
        if key == "IsShown" then return function() return false end end
        if key == "IsForbidden" then return function() return true end end
        return function() error("touched " .. tostring(key)) end
    end
    startRoll(env, 23, ROLLS.bearBelt)
    env:advance(2)
    truthy(rolls.active[23].alert)
    falsy(rolls.active[23].halo, "a forbidden frame is never touched")

    -- Cooldown: two alerts within a moment chime once; later ones chime again.
    equal(#world.sounds, 3)
    startRoll(env, 24, ROLLS.rompers)
    alerts.Prefs().boeThreshold = 50000
    startRoll(env, 25, ROLLS.rompers)
    equal(#world.sounds, 4 - 1 + 1, "a chime within the cooldown is skipped")
    env:advance(alerts.CHIME_COOLDOWN + 0.5)
    startRoll(env, 26, ROLLS.shield)
    local before = #world.sounds
    startRoll(env, 27, ROLLS.barb)
    equal(#world.sounds, before, "back to back: one chime")

    -- Sound off: everything else still happens.
    env:advance(5)
    alerts.Prefs().sound = false
    local silent = #world.sounds
    startRoll(env, 28, ROLLS.barb)
    equal(#world.sounds, silent, "no chime when sound is off")
    truthy(rolls.active[28].alert and rolls.active[28].noticeShown)
    alerts.Prefs().sound = true
    alerts.Prefs().chime = "bell"
    env:advance(5)
    startRoll(env, 29, ROLLS.barb)
    equal(world.sounds[#world.sounds].id, 878, "the chosen chime")
    -- A client where PlaySound errors is a silent client, not a broken roll.
    _G.PlaySound = function() error("no sound device") end
    env:advance(5)
    startRoll(env, 30, ROLLS.barb)
    truthy(rolls.active[30].alert)
    equal(world.decisions, 0)

    -- HUD hidden and toasts off: sound only.
    _G.PlaySound = function(id) table.insert(world.sounds, { id = id }) end
    for id in pairs(rolls.active) do env:dispatch("CANCEL_LOOT_ROLL", id) end
    env:advance(ui.SECONDS + 1)
    alerts.Prefs().toast = false
    local sounds = #world.sounds
    startRoll(env, 31, ROLLS.barb)
    equal(#world.sounds, sounds + 1, "the chime still plays")
    equal(rolls.active[31].noticeSkipped, true)
    equal(#ui.entries, 0, "no toast when the player turned it off")
    equal(ui.frame.shown, false)

    -- Wishlist alerts off: no purple, no chime for it; gold unaffected.
    env:advance(5)
    alerts.Prefs().toast, alerts.Prefs().wishlist = true, false
    sounds = #world.sounds
    startRoll(env, 32, ROLLS.barb)
    falsy(rolls.active[32].alert)
    equal(#world.sounds, sounds)
    startRoll(env, 33, ROLLS.rompers)
    equal(rolls.active[33].alert.category, "valuable_boe")
    alerts.Prefs().wishlist, alerts.Prefs().boe = true, false
    env:advance(5)
    startRoll(env, 34, ROLLS.rompers)
    falsy(rolls.active[34].alert, "gold alerts off")
    startRoll(env, 35, ROLLS.shield)
    equal(rolls.active[35].alert.category, "wishlist")
    equal(rolls.active[35].alert.value, nil, "and no value is shown for it either")
end

-- Item info that arrives late, or never ----------------------------------------------------

do
    local env, addon = boot()
    local rolls = addon.LootRolls
    -- The roll is announced before the client knows its link.
    world.rolls[41] = nil
    env:dispatch("START_LOOT_ROLL", 41, 60000)
    falsy(rolls.active[41].item, "nothing is guessed while the item is unknown")
    falsy(rolls.active[41].alert)
    equal(#world.sounds, 0)
    equal(countStreams(env, "loot_roll:"), 0, "and nothing is reported about it")
    world.rolls[41] = ROLLS.barb
    env:advance(1)
    truthy(rolls.active[41].item, "resolved on a retry")
    equal(rolls.active[41].alert.category, "wishlist")
    equal(#world.sounds, 1)
    equal(countStreams(env, "loot_roll:"), 1)

    -- The link is known but the roll's details are not: the wishlist can
    -- still match on the item; a gold alert cannot, binding being unknown.
    startRoll(env, 42, ROLLS.shield, { infoMissing = true })
    equal(rolls.active[42].item.bindOnPickUp, nil)
    equal(rolls.active[42].item.name, "Phantom Shield", "the name comes from the link")
    equal(rolls.active[42].alert.category, "wishlist")
    equal(#rolls.active[42].alert.reasons, 1, "no value without confirmed binding")
    startRoll(env, 43, ROLLS.rompers, { infoMissing = true })
    addon.LootAlerts.Prefs().boeThreshold = 50000
    falsy(rolls.active[43].alert, "binding unknown: no gold alert")

    -- A roll the client never describes is dropped quietly.
    world.rolls[44] = nil
    env:dispatch("START_LOOT_ROLL", 44, 60000)
    env:advance(10)
    falsy(rolls.active[44].item)
    equal(rolls.stats.unresolved, 1)
    env:dispatch("CANCEL_LOOT_ROLL", 44)
    falsy(rolls.active[44])
    -- Events with nonsense arguments are ignored.
    env:dispatch("START_LOOT_ROLL", nil, nil)
    env:dispatch("START_LOOT_ROLL", "abc", 0)
    env:dispatch("CANCEL_LOOT_ROLL", 777)
    env:dispatch("CHAT_MSG_LOOT", nil)
    equal(world.decisions, 0)

    equal(select(1, rolls.ParseLink(ROLLS.bearBelt[1])), 6468)
    equal(select(2, rolls.ParseLink(ROLLS.bearBelt[1])), -1081)
    equal(select(2, rolls.ParseLink(ROLLS.barb[1])), nil)
    equal(rolls.ParseLink("not a link"), nil)
    equal(rolls.ParseLink(nil), nil)
end

-- Winning: only the game's own receipt counts ----------------------------------------------

do
    local env, addon = boot()
    local rolls, sync = addon.LootRolls, addon.LootSync
    world.instance = SM
    env:dispatch("PLAYER_ENTERING_WORLD", false, false)
    env:advance(2)

    -- The boss dies, this client loots it and sees the barb on that corpse alone.
    env:dispatch("ENCOUNTER_END", 3, "Herod", 1, 5, 1)
    rolls.NoteLootWindow({ ["Creature-0-1-189-3-3975-000001"] = { npcId = 3975, name = "Herod", outputs = { [5191] = { itemId = 5191 } } } })
    startRoll(env, 51, ROLLS.barb)
    local record = rollStream(env, addon, 51)
    equal(record.envelope.payload.context.source.npcId, 3975, "the creature is named when this client saw the item on one corpse")
    equal(record.envelope.payload.context.source.basis, "loot_window_single_source")
    equal(record.envelope.payload.context.encounter.name, "Herod")
    equal(record.revision, 1)

    -- Somebody else receives one: not ours.
    env:dispatch("CHAT_MSG_LOOT", "Fern receives loot: " .. ROLLS.barb[1] .. ".")
    equal(rolls.active[51].outcome, "offered")
    -- Choosing Need closes the frame; the roll is still only an offer.
    env:dispatch("CANCEL_LOOT_ROLL", 51)
    equal(rolls.ended[#rolls.ended].outcome, "offered")
    falsy(sync.IsAcquired("i:5191"))
    truthy(addon.LootAlerts.Evaluate({ itemId = 5191, itemKey = "i:5191", bindOnPickUp = true }), "still wanted")
    -- Another item received: not this roll.
    env:dispatch("CHAT_MSG_LOOT", "You receive loot: " .. ROLLS.cape[1] .. ".")
    equal(rolls.ended[#rolls.ended].outcome, "offered")

    -- The game says this character received it.
    env:advance(20)
    env:dispatch("CHAT_MSG_LOOT", "You receive loot: " .. ROLLS.barb[1] .. ".")
    equal(rolls.ended[#rolls.ended].outcome, "won")
    equal(rolls.stats.won, 1)
    local won = record.envelope and env:telemetry()
    local stream
    for key, value in pairs(won) do
        if key:find("loot_roll:", 1, true) == 1 then stream = value end
    end
    equal(stream.revision, 2, "the same roll, updated: not a second roll")
    equal(stream.envelope.payload.outcome, "won")
    equal(stream.envelope.payload.acquired.basis, "chat_loot_self")
    equal(countStreams(env, "loot_roll:"), 1)
    -- It stops alerting at once, before the website has heard.
    truthy(sync.IsAcquired("i:5191"))
    falsy(addon.LootAlerts.Evaluate({ itemId = 5191, itemKey = "i:5191", bindOnPickUp = true }), "an item just won does not alert again")
    -- The receipt counted once.
    env:dispatch("CHAT_MSG_LOOT", "You receive loot: " .. ROLLS.barb[1] .. ".")
    equal(rolls.stats.won, 1)

    -- Receiving something else while a roll is open wins nothing.
    startRoll(env, 53, ROLLS.rompers)
    env:dispatch("CHAT_MSG_LOOT", "You receive loot: " .. ROLLS.cape[1] .. ".")
    equal(rolls.active[53].outcome, "offered", "another item's receipt is not this roll's")
    equal(rolls.stats.won, 1)
    env:dispatch("CHAT_MSG_LOOT", "You receive loot: " .. ROLLS.rompers[1] .. "x2.")
    equal(rolls.active[53].outcome, "won", "the stacked form of the receipt counts too")

    -- The item seen on two corpses: the roll names neither.
    rolls.NoteLootWindow({ ["Creature-0-1-189-3-4000-000002"] = { npcId = 4000, outputs = { [6694] = { itemId = 6694 } } },
        ["Creature-0-1-189-3-4001-000003"] = { npcId = 4001, outputs = { [6694] = { itemId = 6694 } } } })
    startRoll(env, 52, ROLLS.shield)
    equal(rollStream(env, addon, 52).envelope.payload.context.source, nil, "two corpses: the source is not guessed")

    -- A reload keeps what was won until the website's list catches up.
    env:dispatch("PLAYER_LOGOUT")
    local _, again = boot({ db = GuildweaverDB })
    truthy(again.LootSync.IsAcquired("i:5191"), "still suppressed with the same file")
    local newer = fixtureInbox()
    newer.digest, newer.generatedAt = "after-sync", newer.generatedAt + 600
    table.remove(newer.characters[1].wishlist.items, 1)
    again.BridgeLoot = newer
    equal(again.LootSync.Initialize(), "applied")
    falsy(again.LootSync.IsAcquired("i:5191"), "the website's list is the truth again")
    falsy(again.LootSync.WishlistEntry(5191, "i:5191"), "and no longer wants it")
    equal(world.decisions, 0)
end

-- Combat: a roll costs a few table reads, and nothing runs while idle ----------------------

do
    local env, addon = boot()
    local rolls = addon.LootRolls
    world.instance = SM
    env:dispatch("PLAYER_ENTERING_WORLD", false, false)
    env:advance(5)
    env.inCombat = true
    env:dispatch("PLAYER_REGEN_DISABLED")
    env:resetCalls()
    rollFrame(1, 61)
    for rollId = 61, 64 do startRoll(env, rollId, rollId % 2 == 0 and ROLLS.shield or ROLLS.barb) end
    truthy(rolls.active[61].alert and rolls.active[62].alert, "alerts work in combat")
    truthy(rolls.active[61].halo, "and so does the passive glow")
    equal(env:callCount("GetContainerNumSlots") + env:callCount("C_Container.GetContainerNumSlots"), 0, "a roll never scans bags")
    equal(env:itemTooltipScans(), 0, "nor tooltips")
    equal(addon.WorkQueue.Size(), 0, "nor queues work")
    -- The journal scan refuses to start in combat.
    local started, reason = addon.LootJournal.Scan()
    equal(started, false)
    truthy(reason == "unsupported" or reason == "in_combat", "no journal work in combat: " .. tostring(reason))
    equal(addon.DungeonHud:DisplayMode(), "minimized", "the HUD stays collapsed for the fight")
    equal(addon.LootAlertUI.anchoredTo, "hud")
    for rollId = 61, 64 do env:dispatch("CANCEL_LOOT_ROLL", rollId) end
    env:advance(15)
    -- Idle: no ticker, no OnUpdate left behind.
    equal(addon.LootAlertUI.frame.shown, false)
    falsy(next(rolls.active))
    equal(world.decisions, 0)
end

-- The journal: probe and scan, only with what the client really has ------------------------

do
    local env, addon = boot()
    local journal = addon.LootJournal
    equal(journal.Supported(), false, "no Encounter Journal API is assumed")
    local lines = journal.Probe()
    truthy(#lines >= 6, "the probe reports")
    local report = table.concat(lines, "\n")
    truthy(report:find("missing: ", 1, true) and report:find("EJ_GetLootInfoByIndex", 1, true), "it names what is missing")
    truthy(report:find("GetLootRollItemLink", 1, true), "and what is present")
    truthy(report:find("not available on this client", 1, true))
    equal(select(2, journal.Scan()), "unsupported")

    -- A client that has the journal.
    local G = _G
    local selected, filter, filtersSet = nil, { 8, 62 }, {}
    local LOOT = {
        [91] = { { "Ravager", 1, "Two-Hand", "Axe", 7717, link(7717, "Ravager") }, { "Herod's Shoulder", 1, "Shoulder", "Mail", 7718, link(7718, "Herod's Shoulder") } },
        [92] = { { itemID = 7711, name = "Robe of Doan", icon = 135021 }, { itemID = 7712, name = "Mantle of Doan" }, { itemID = 7711, name = "Robe of Doan" } },
        [93] = { { "Loading", 1, "", "", nil, nil } },
    }
    G.C_Map = G.C_Map or {}
    G.C_Map.GetBestMapForUnit = function() return 435 end
    G.EJ_GetInstanceForMap = function() return 316 end
    G.EJ_SelectInstance = function() end
    G.EJ_GetEncounterInfoByIndex = function(index)
        local list = { { "Herod", 91 }, { "Arcanist Doan", 92 }, { "Houndmaster Loksey", 93 } }
        local entry = list[index]
        if not entry then return nil end
        return entry[1], "", entry[2], 0, "", 0, 0, 189
    end
    G.EJ_SelectEncounter = function(id) selected = id end
    G.EJ_GetNumLoot = function() return #(LOOT[selected] or {}) end
    G.EJ_GetLootInfoByIndex = function(index)
        local row = LOOT[selected][index]
        if row.itemID then return row end
        return row[1], row[2], row[3], row[4], row[5], row[6]
    end
    G.EJ_GetLootFilter = function() return filter[1], filter[2] end
    G.EJ_SetLootFilter = function(classId, specId) filter = { classId, specId }; table.insert(filtersSet, classId .. ":" .. specId) end
    equal(journal.Supported(), true)
    equal(select(2, journal.Scan()), "not_in_instance", "only inside a dungeon or raid")

    world.instance = SM
    env:dispatch("PLAYER_ENTERING_WORLD", false, false)
    env:advance(2)
    env.inCombat = true
    equal(select(2, journal.Scan()), "in_combat", "never started in combat")
    env.inCombat = false
    G.EncounterJournal = { IsShown = function() return true end }
    equal(select(2, journal.Scan()), "journal_open", "never while the player is using the journal")
    G.EncounterJournal = nil

    local result
    equal(journal.Scan(function(done) result = done end), true)
    equal(countStreams(env, "loot_catalog:"), 0, "nothing is read in the call itself")
    env:advance(2)
    truthy(result, "the scan finishes over a few frames")
    equal(result.encounters, 3)
    equal(result.sent, true)
    equal(result.complete, false, "a boss whose loot had not loaded makes the snapshot incomplete")
    equal(filter[1] .. ":" .. filter[2], "8:62", "the player's loot filter is put back")
    truthy(filtersSet[1] == "0:0", "after reading unfiltered")
    local record = env:stream("loot_catalog:316:1")
    truthy(record, "one snapshot for this dungeon and difficulty")
    local payload = record.envelope.payload
    equal(record.envelope.eventType, "loot_catalog_snapshot")
    equal(payload.sourceApi, "encounter_journal")
    equal(payload.instance.instanceId, 189)
    equal(payload.instance.journalInstanceId, 316)
    equal(payload.instance.type, "party")
    equal(payload.difficultyId, 1)
    equal(payload.complete, false)
    equal(payload.filters.classId, 0)
    equal(#payload.encounters, 3)
    equal(payload.encounters[1].name, "Herod")
    equal(payload.encounters[1].journalEncounterId, 91)
    equal(payload.encounters[1].complete, true)
    equal(payload.encounters[1].items[1].itemId, 7717, "the classic return order")
    equal(payload.encounters[2].items[2].itemId, 7712, "the table return shape")
    equal(#payload.encounters[2].items, 2, "a repeated row is one item")
    equal(payload.encounters[2].complete, true)
    equal(payload.encounters[3].complete, false, "an unresolved row is not a complete list")
    equal(#payload.encounters[3].items, 0)
    truthy(record.envelope.gameBuild, "with the game build")

    -- Scanned again with everything loaded: complete, and a new revision of the same stream.
    LOOT[93] = { { "Loksey's Training Stick", 1, "Staff", "", 3456, link(3456, "Loksey's Training Stick") } }
    equal(journal.Scan(), true)
    env:advance(2)
    local again = env:stream("loot_catalog:316:1")
    equal(again.envelope.payload.complete, true)
    equal(again.revision, 2)
    equal(countStreams(env, "loot_catalog:"), 1)

    -- Leaving the instance mid-scan cancels it and restores the filter.
    filter = { 3, 0 }
    equal(journal.Scan(), true)
    world.instance = nil
    env:advance(2)
    equal(filter[1], 3, "the filter is the player's again")
    equal(world.decisions, 0)
    for _, name in ipairs({ "EJ_GetInstanceForMap", "EJ_SelectInstance", "EJ_GetEncounterInfoByIndex", "EJ_SelectEncounter", "EJ_GetNumLoot", "EJ_GetLootInfoByIndex",
        "EJ_GetLootFilter", "EJ_SetLootFilter" }) do
        G[name] = nil
    end
end

-- Settings and commands --------------------------------------------------------------------

do
    local env, addon = boot()
    local alerts, ui = addon.LootAlerts, addon.LootAlertUI
    local slash = SlashCmdList.GUILDWEAVER
    local function printed(needle)
        for _, line in ipairs(env.printed) do
            if tostring(line):find(needle, 1, true) then return true end
        end
        return false
    end
    slash("loot")
    truthy(printed("Wishlist for Rook Ravenstar: 3 wanted item(s)"), "the status says what is loaded: " .. tostring(env.printed[#env.printed - 1]))
    slash("loot wishlist off")
    equal(alerts.Prefs().wishlist, false)
    slash("loot wishlist on")
    equal(alerts.Prefs().wishlist, true)
    slash("loot boe off")
    equal(alerts.Prefs().boe, false)
    slash("loot boe")
    equal(alerts.Prefs().boe, true, "without on/off it toggles")
    slash("loot sound off")
    equal(alerts.Prefs().sound, false)
    slash("loot sound coin")
    equal(alerts.Prefs().chime, "coin")
    equal(alerts.Prefs().sound, true)
    equal(world.sounds[#world.sounds].id, 120, "choosing a chime plays it")
    slash("loot threshold 25")
    equal(alerts.Threshold(), 250000)
    slash("loot threshold nonsense")
    equal(alerts.Threshold(), 250000)
    slash("loot toast off")
    equal(alerts.Prefs().toast, false)
    slash("loot toast on")
    slash("loot probe")
    truthy(printed("Loot API probe"))
    slash("loot scan")
    truthy(printed("no Encounter Journal loot API"), "the scan explains why it cannot run")
    slash("loot test")
    equal(#ui.entries, 1, "a preview shows the notice")
    equal(ui.rows[1].text, "Wishlist | High priority \194\183 Your note shows here")
    equal(countStreams(env, "loot_roll:"), 0, "and records nothing")
    slash("loot test boe")
    truthy(ui.rows[1].text:find("Valuable BoE | ~25g 43s on the AH (2h old)", 1, true), ui.rows[1].text)

    -- The settings page has the four controls, and they are the same settings.
    addon.MainFrame:Open("settings")
    local view = addon.MainFrame.views.settings
    truthy(view.lootWishlistToggle and view.lootBoeToggle and view.lootSoundToggle and view.lootThreshold, "loot alert settings are on the settings page")
    view.lootWishlistToggle:GetScript("OnClick")()
    equal(alerts.Prefs().wishlist, false)
    view.lootBoeToggle:GetScript("OnClick")()
    equal(alerts.Prefs().boe, false)
    view.lootSoundToggle:GetScript("OnClick")()
    equal(alerts.Prefs().sound, false)
    view.lootThreshold.buttons[1]:GetScript("OnClick")()
    equal(alerts.Threshold(), 50000)

    -- They survive a reload, and a first run has sensible defaults.
    env:dispatch("PLAYER_LOGOUT")
    local _, again = boot({ db = GuildweaverDB })
    equal(again.LootAlerts.Prefs().wishlist, false)
    equal(again.LootAlerts.Threshold(), 50000)
    equal(again.LootAlerts.Prefs().chime, "coin")
    local _, fresh = boot({ inbox = false })
    local defaults = fresh.LootAlerts.Prefs()
    equal(defaults.wishlist, true)
    equal(defaults.boe, true)
    equal(defaults.sound, true)
    equal(defaults.toast, true)
    equal(fresh.LootAlerts.Threshold(), 100000, "a modest default: 10g")
    fresh.LootSync.Status()
    SlashCmdList.GUILDWEAVER("loot")
    equal(world.decisions, 0)
end

print("loot alert tests passed")
