# Guildweaver

Guildweaver is a guild operating layer for World of Warcraft: Forever. It is being built as a generic addon that guilds can pair with external services for quests, progression, rewards, roster data, and synchronization.

Holdfast is the first guild using Guildweaver, but Guildweaver itself is intentionally guild-agnostic.

## Current milestone

The first milestone establishes a reliable addon foundation:

- WoW Forever Interface 16001
- Lua 5.1-compatible code
- SavedVariables through `GuildweaverDB`
- automatic character snapshots during normal play
- automatic final snapshot on `/reload`, logout, or UI shutdown before SavedVariables are flushed
- background bridge sync with no manual export step
- `/gw` and `/guildweaver` slash commands
- a minimap launcher and an in-game dashboard (see [Interface](#interface))
- persisted window, HUD and launcher positions
- Lua syntax and lint checks in GitHub Actions

## Commands

- `/gw` toggles the Guildweaver dashboard
- `/gw settings` opens the dashboard on Settings
- `/gw minimap` shows or hides the minimap button
- `/gw version` prints the current addon version
- `/gw snapshot` captures a diagnostic snapshot; normal synchronization does not require it
- `/gw inventory` rescans your bags and prints the inventory telemetry revision
- `/gw sync` (or `/gw capture`) records a checkpoint and reloads the UI so WoW writes it to disk for the bridge now
- `/gw fishing` prints the fishing casts and catches recorded this session and where the last catch came from
- `/gw perf` prints capture counts, timings, worst frames, work-queue state and tooltip-scan counts for this session; `/gw perf reset` clears them
- `/gw reset` resets the window position
- `/gw help` prints command help

## Interface

**Minimap button.** The Guildweaver emblem on the minimap edge. Click opens or closes the dashboard; double-click opens it on Settings (a single click waits out the double-click window, so a double-click never opens and closes the window first); right-click shows quick actions (open, show or hide the dungeon HUD, start or stop a timed farming run, Sync & data, Settings, hide the button); drag moves it around the minimap. Its angle and visibility are saved. `/gw` always works, with or without it.

**Dashboard.** One window with a sidebar: **Overview** (a card per module), **Dungeons** (the open run with Start/Pause/Resume, Split and End run, recent runs, objectives), **Farming** (start or stop a timed run, elapsed time and gathers, this session's fishing), **Guild Quests** (the quest log: Available, My Quests, Completed, join and leave objectives), **Sync & Data** (what is waiting for the bridge, Sync now, and an Advanced section with the diagnostic commands) and **Settings**. It remembers its position and the last view, closes with Escape, and is built the first time it is opened. While open it updates live numbers once a second; closed it costs nothing.

**Settings** are grouped by module: the minimap button and window position; the dungeon HUD (show in dungeons, collapse in combat, lock position, default view, size, reset position). Data collection has no switch: hiding the HUD or any window never stops recording.

The look (blue-black panels, hairline borders, antique gold accents) and the controls live in `UI/Theme.lua` and `UI/Widgets.lua`, shared by every window, the HUD and the launcher. Everything is plain frames and textures with no secure templates and no protected calls. `docs/ui-acceptance.md` is the in-game visual checklist.

## Synchronization

Guildweaver is designed so players do not need to export data manually. The addon continuously updates its in-memory outbound SavedVariables state as character data changes. WoW only writes SavedVariables to disk during `/reload` and logout; the Guildweaver Bridge then notices the new revisions and sends them to the paired Holdfast service automatically. Guildweaver never reloads the UI on its own (earlier versions reloaded once after login); use `/gw sync` to write to disk immediately.

## Performance

Capture work is scoped to what changed so it stays out of the way during play:

- Stat, aura and combat-rating events refresh and publish only the stats stream, coalesced to one refresh per burst and deferred until combat ends. Unit events are registered for the player only.
- Gear, talent and level changes re-read only the affected sections. Equipped-item tooltips are reused until the slot, its durability or weapon enchant changes; a gear swap re-renders only the changed slots and set pieces.
- Bag events re-read only the bags that changed and rescan tooltips only for items whose link, count, binding or durability changed. Money changes never read bags. All bags are re-read every 15 minutes, on entering the world and on bag swaps, to repair missed events.
- Recipe books, tooltip enrichment, item-catalog definitions and large payload fingerprints run on one work queue with a 2 ms per-frame budget and a cap of 24 work items per frame, paused in combat and idle when empty. After 30 busy frames in a row it runs every 50 ms instead of every frame. Closing or switching a profession cancels a scan in progress, so only complete books are published.
- Looting renders no tooltips. All collectors share one read of the loot window per event, and corpse and gathering records are stored at once. New items are noted and defined afterwards from the work queue: from the live loot slot if the window is still open, otherwise from the item link. Items already defined, this session or an earlier one, cost nothing. The saved corpse cache is swept at most once a minute.
- Opening a profession waits 0.75 s before scanning (a quick open/close starts nothing). A book whose profession, skill rank and recipe count match a full scan from the last 6 hours, in this session or a saved one, is not scanned again; learning a recipe forces the next scan. Profession list updates (one per craft) skip the rescan the same way. A finished scan updates the character's recipes in small steps instead of recapturing the character.
- The outbound queue drops what the bridge has delivered on the next login (`Data/BridgeAcks.generated.lua`), so SavedVariables hold only undelivered data. At its cap it is pruned in batches, not one record per write.
- Each telemetry payload is fingerprinted once per publish. Profession and inventory payloads are skipped entirely while their cache revision is unchanged, and large payloads are fingerprinted across frames.

`/gw perf` shows what the addon did this session: per-collector runs and worst times (`loot_event`, `loot_capture`, `loot_enrich`, `item_catalog`, `recipe_step`, `domain_publish`, ...), tooltip scan counts, work-queue depth, total and worst frame time, worst single step, backoffs, dropped and combat-deferred work, the five worst frames, and this addon's memory with its growth since the previous `/gw perf`. Timing uses `debugprofilestop` (falling back to `GetTimePreciseSec`), and the client's own AddOn profiler metrics are included when `C_AddOnProfiler` is available and enabled. Nothing from `/gw perf` is saved.

`test/bench/perf_bench.lua` replays common gameplay in the fake client from `test/support/wow_env.lua` against any checkout. Its numbers are synthetic and are not in-game measurements.

## Local development

Clone the repository somewhere convenient, then create a Windows directory junction from the WoW Forever addon directory to the repository.

Example PowerShell command:

```powershell
New-Item -ItemType Junction -Path "C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns\Guildweaver" -Target "C:\Users\Zach\Projects\guildweaver"
```

After Guildweaver appears in the in-game addon list, use `/reload` while iterating.

## Direction

The near-term build order is:

1. addon foundation
2. Blizzard-style Guild Quest Log using local mock data
3. quest state actions
4. character snapshotting
5. SavedVariables sync contract
6. companion bridge and website round trip

The addon UI should feel native to WoW rather than like a web dashboard embedded in the game.

## Farming runs and coordinates

Gathering automatically groups herb, ore, skinning and fishing loot observations into candidate runs. A gap over 10 minutes starts another run. Automatic duration is the first-to-last observed harvest window; it is always an estimate and includes travel and waiting between those observations. Short samples still contribute to yield/drop statistics.

For measured elapsed time, use **Start farming** in `/gw`, or `/gw farm start`, then **Stop farming** or `/gw farm stop`. `/gw farm` shows the mode. Travel, combat and waiting remain in elapsed time; reported AFK time is recorded separately. Missing AFK support remains unknown. Runs end on logout or UI reload so offline time is never added. `/gw sync` flushes a checkpoint via reload and therefore ends a run; stop a measured run first.

`farming_session` is an envelope-v1 event stream with cumulative sequence-numbered checkpoints every minute and a final `complete` record. Gathering events link through `context.farming.sessionId`. The session's material basis is `loot_window`: loot offered, not proof of items acquired. The website suppresses hourly rates until the run is complete, at least 20 minutes/10 harvests, and every declared harvest has synced. All timing is local/client-reported evidence, not authoritative server measurement.

Gathering locations preserve UI `mapId` and normalized `x`/`y` in `[0,1]`, rounded to five decimals, plus zone/subzone. `coordinateSystem=ui_map_normalized` and `positionKind=player_at_cast` explicitly describe the player position observed at cast time; this is approximate evidence of the source's location. Missing or invalid positions are omitted, never replaced by zero. No continuous movement trail is collected.

### Dungeon runs

Entering a dungeon or raid starts a run automatically, and a HUD shows inside instances. It has three modes: **minimized** (the clock with a status light: grey ready, green running, amber paused, gold cleared), **compact** (the default: the dungeon, the clock with **Start**/**Pause**/**Resume**, boss progress pips, one line of numbers such as deaths and XP/hour, and your current objective) and **expanded** (adds **Split**, small boss faces, time inside, deaths, XP, XP/hour, the wallet change, your best and pace, recent splits, objectives, **End run** and **Options**). Nothing is shown before it has a value: no `-/h`, no "PB: none yet". Right-click it, or use its `–`/`+` buttons, to change mode; `×` hides it for the current run (the run is still recorded; the minimap menu or the dashboard brings it back). In combat it collapses to minimized by default and returns to your mode afterwards; a mode you pick during a fight lasts until the fight ends. Drag it to move it unless locked; it keeps its top-left corner when the mode changes. Mode, position, size, lock and the combat preference are saved. It is a plain frame on the LOW strata (below action bars and dialogs), with no sounds, no animations and no protected calls. It is laid out only on run events; once a second only its clock text is updated, and a full refresh every 15 seconds keeps XP/hour current.

After resetting and re-entering the same dungeon, use `/gw dungeon new` to close the previous attempt and start a fresh one. Records use the timed clock and require a verified clear with one uninterrupted start. Manual starts, first pulls, and entry-timed runs have separate records.

**The timer.** The clock is the timed run, not the time since you zoned in. It is *ready* when you enter (`0:00`, "Starts on your first pull"), starts by itself the first time you enter combat or a boss encounter starts, and can be paused and resumed by hand with the **Start**/**Pause**/**Resume** button or `/gw dungeon start|stop`. **Pause** stops the clock and leaves the run open; **End run** (expanded HUD or the dashboard, click twice) or `/gw dungeon finish` closes the run. Combat never restarts a timer you paused. The last boss of the lockout stops it ("Cleared"). Boss kills and splits are stamped with the timer, so split times, pace and personal bests all compare timed runs. The run's elapsed online time since entry is still kept and sent as `durationSeconds`.

**Boss progress.** Pips under the clock, one per boss the lockout lists: gold when down, red for the fight. Without a lockout total the HUD says how many bosses are down. During a fight the boss's name and a thin health bar show under the clock. The expanded HUD adds a row of small round faces, one per boss kill (gold ring) and per split (blue ring) and for the fight (red ring); bosses not yet reached get no placeholder. The face is the client's own portrait of the unit while it is on screen: the boss frame (`boss1`) or your target with that name for a fight, and the fight's circle becomes the kill's when the boss falls, so its face stays. A **Split** with an NPC targeted is named after it and takes its face, so bosses the client does not report still get a name and a portrait; a split with a player targeted, or none, is just "Split n". After a reload, faces show an icon instead. Hover a face for its name and time.

Commands: `/gw dungeon` shows the run, `/gw dungeon start`, `/gw dungeon stop` and `/gw dungeon timer` (toggle) control the timer, `/gw dungeon split [name]` marks a split (named after your target without a name), `/gw dungeon finish` ends it as completed, `/gw dungeon mode [min|compact|full]` sets or cycles the mode, `/gw dungeon pb` shows your best here and the pace, `/gw dungeon hud on|off` turns the tracker on or off (runs are recorded either way), `/gw dungeon reset` moves it back.

A run continues through a /reload, a disconnect or a run back from the graveyard if you are back in the same instance within 10 minutes; offline time never counts. It ends as **completed** when every boss in the lockout is down (or on `/gw dungeon finish`), **abandoned** when you leave and do not come back without a confirmed full clear (5-player instances without a lockout report no boss total, so leaving them ends as abandoned unless you use `/gw dungeon finish`), **interrupted** when you log out and do not return. Bosses come only from `ENCOUNTER_END`/`BOSS_KILL` when the client sends them; otherwise use splits. One kill per boss: the same encounter id, the same boss name, or (with neither) a second report within 10 seconds counts once. The combat log is never read. XP is XP gained over the run's elapsed online time (inside plus time outside between leaving and coming back), including level-ups; it is not split into quest and kill XP and is not reported at the level cap. Gold is the wallet change during the run, not profit. Deaths are your character's own, never a wipe.

**Personal bests** are local: the fastest clear of the same instance at the same difficulty by the same character, kept only when the clear is proven by the lockout or by every boss's kill event, never for a hand-finished or partial run. The best shown is the timed run. Pace is shown only at checkpoints both runs recorded the same way (a boss by its encounter id, or by name; a split by its name), comparing their timer times.

**Objectives** are a small per-character checklist: `/gw obj` lists them, `/gw obj add <text>`, `/gw obj boss <name>` (completes when the client reports that boss's kill), `/gw obj done|undo|up|down|remove <n>`, `/gw obj edit <n> <text>`. The first open one is the current objective in the tracker. Manual splits and loot never complete an objective. The website keeps its own list per character; the two are not synced yet.

`dungeon_run` is an envelope-v1 event stream, one stream key per run, payload schema 2. It is written when the game saves (/reload, logout) as an open checkpoint and once more when the run ends; each write has a higher `sequence`, and the website ignores anything after a finished run. Schema 2 adds `checkpoints` (boss kills and manual splits with stable ids, at most 40, kept apart from the timeline), `completion.basis` (`lockout`, `encounters`, `manual` or `none`), a `complete` timeline marker and `bosses.duplicatesIgnored`. The timer adds `timer` (`state`: ready, running or stopped; `seconds`; `starts`; `startedBy`: combat, encounter, manual or entry; `stoppedBy`: manual or complete; `startedAtOffset`), `timerAt` on every checkpoint next to its elapsed `at`, and `timer_start`/`timer_stop` timeline events. The timeline keeps at most 60 events, and the add-on keeps the last 10 runs for the window. Corpse loot and gathering inside a run carry `context.dungeonRun.runId`. A run started by an older version continues after updating: its checkpoints are rebuilt from its timeline, and its timer counts as running since entry.

Not yet verified in the live Forever client: whether Forever fires `ENCOUNTER_END`/`BOSS_KILL` in 5-player dungeons, and what it passes for encounter ids and names (without them, bosses and pace come from manual splits only, which the target-named **Split** is for); whether `boss1` exists in 5-player dungeons (otherwise the fight's face comes from your target); and that `SetPortraitTexture` with a circular mask texture renders on Forever as it does on the modern client. The boss row is drawn with plain textures and falls back to icons wherever a face cannot be drawn.

### Auction House

While the auction house is open, Guildweaver records what the client already shows: commodity and item searches (every listing of that item: unit price, quantity), browse rows (the lowest price and total per item) and full scans another addon or the player ran (read a slice per frame through the work queue). It never searches, scans, buys, bids, posts or cancels, needs no other addon, and never reads seller or bidder names. Results are written as `auction_scan` events (at most 1,000 items each) a few seconds after the last search or when the auction house closes; unchanged results are not re-sent for 10 minutes. Each item says whether every listing was visible (`complete`). The market is the realm plus the house: neutral in Booty Bay, Gadgetzan and Everlook, otherwise the player's faction. If the faction cannot be read, nothing is recorded. Prices reach the website after /reload or logout, like all telemetry.

Forever's auction house is the classic browse frame. Guildweaver reads each page the player (or Auctionator, or any other addon) brings up through `AUCTION_ITEM_LIST_UPDATE` and `GetAuctionItemInfo("list", i)`, with the item's name, quality and required level. `QueryAuctionItems` is only observed with `hooksecurefunc`, after the call, to know which search and page a result belongs to: pages of one search are merged, and an item is marked complete once every page of its search was seen. A "get all" scan someone else ran is read in slices once it stops arriving and sent as one full snapshot. The modern `C_AuctionHouse` API is read too where the client has it.

Not yet verified in the live Forever client (only against a deterministic fake client): which of the two APIs Forever exposes, whether `AUCTION_ITEM_LIST_UPDATE` fires once per page or again as item details load (both are handled), and how long a "get all" scan takes to fill. To check in game: open the auction house, search "linen cloth", page through the results, close it, `/reload`, and confirm an `auction_scan` event with `query.kind = "page"` with `/gw telemetry`, then on the website's Auction House Diagnostics tab.

### Fishing

Each accepted Fishing cast is a `gathering_attempt` (`activity=cast`) and each fishing loot window a `gathering_loot` (`activity=catch`). Casts are recognized by the Classic-era rank spell ids (7620, 7731, 7732, 18248), the modern spell (131474), or the spell name. A catch is recorded once per loot window. When the client reports fishing loot (`IsFishingLoot`) but the cast was not seen, because the channel ended first or the cast started before a reload, the catch is still recorded with context read at loot time and `capture.castObserved=false`.

The source is open water unless a pool is identified. A pool tooltip under the cursor shortly before or during the cast names it (`sourceDetection=world_cursor_tooltip`). Loot from a game object other than the player's bobber (object 35591) came from a pool, so that object id identifies the pool even when no tooltip was seen (`sourceDetection=loot_source`, `sourceConfidence=confirmed`); its name comes from a pool tooltip seen earlier in the session, or is `Fishing Pool`. A bobber loot source never replaces a pool found by tooltip. The website keeps open water per map and pools per name (or object id) and map.

### Corpse loot and public item definitions

`mob_loot` reports one Creature/Vehicle source with only its assigned items from `GetLootSourceInfo` GUID/quantity pairs. Area loot splits the same item stack across sources. Missing or inconsistent assignments, non-item slots, player sources, and object/container loot do not create mob facts. Skinning remains `gathering_loot`; skinned corpses are excluded from later corpse reopens.

Reports retain the source NPC ID, a name only when the exact source GUID was observed as target/mouseover, dungeon instance/difficulty, game build, locale, loot visibility, and map coordinates when available. Coordinates are normalized UI-map **player positions at looting**, not NPC spawn positions. Loot-window quantities describe what was offered, not proof of acquisition. Empty windows and unseen corpses are not zero-drop samples.

A persisted seen cache (1,000 corpses / two hours) prevents duplicate ready/opened events and reopens across reloads. Additional items or larger stacks produce cumulative revisions on the same corpse stream. The collector and website preserve maximum observed quantities rather than adding duplicate party views. No combat-log or chat-log capture is introduced.

`game_item_definition` is a separate envelope-v1 state stream. It scans a bare `item:<id>` reference, without character identity or item-instance links, for public base definitions. Existing rich `item_definition` records remain available to authenticated tools. Both definition streams retry after item-cache load events. Locale is additive envelope metadata; SavedVariables remains schema 4.

Live-client checks after servers return: ordinary corpse; area-loot two NPC types; shared party corpse; reopen/reload; skin a looted corpse; dungeon boss; uncached item; map with unavailable player coordinates. Inspect `/gw telemetry` and sync after a reload/logout.
