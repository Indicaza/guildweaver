# Dungeon journal (Dashboard -> Dungeons)

The website's Dungeon Atlas as an in-game dungeon journal, offline: a card
for every dungeon and raid, the client's own dungeon maps with boss pins,
boss portraits, encounters with their mechanics and spell icons, each boss's
and creature's loot as a grid of item icons with your wishlist marked,
dungeon quests, and your runs. Dashboard -> **Dungeons** (the only dungeon
entry in the sidebar), `/gw guide`, the **?** button on the dungeon HUD, or a
click on a boss face in the HUD.

Everything from the atlas is **Classic reference data, unverified on WoW
Forever**; a small "Reference" indicator on every page says where it comes
from. Nothing is invented: a boss, an ability, an item, a position or a face
the data does not have is simply not shown.

## Where the atlas data comes from

One source: Holdfast's atlas (`Indicaza/holdfast`):

- `backend/src/Atlas/data/atlas.json`: dungeons, bosses (client encounter IDs,
  emulator NPC IDs), abilities with their rule-derived category, dangerous
  trash, rares, quests, spawn layouts, provenance.
- `backend/src/Atlas/data/reference-loot.json` (optional): Classic reference
  loot per boss, rare and dungeon, with item facts (name, quality, slot, item
  level, required level, armour/weapon type, set). No drop chances exist in
  it and none are shown.

`scripts/exportDungeonAtlas.lua` (plain Lua 5.1, no dependencies) turns them
into `Data/DungeonAtlas.generated.lua`, packaged with the add-on. The game
loads that file like any other; it never downloads or parses anything.

```
lua5.1 scripts/exportDungeonAtlas.lua \
  --atlas ../web/holdfast/backend/src/Atlas/data/atlas.json \
  --loot  ../web/holdfast/backend/src/Atlas/data/reference-loot.json \
  --wings ../web/holdfast/backend/src/Atlas/data/wing-manifest.json \
  --quests ../web/holdfast/backend/src/Atlas/data/quest-catalog.json \
  --commit $(git -C ../web/holdfast rev-parse HEAD)
cp ../web/holdfast/backend/src/Atlas/data/wing-manifest.json test/fixtures/wing-manifest.json
```

`--check` (same arguments) fails when the packaged file does not match the
inputs. The output is deterministic: the same inputs and commit give the same
bytes. The exporter refuses an atlas with problems (an ability claiming
Forever verification from a Classic source, an encounter in two dungeons, a
loot item without facts, a spell classified two ways, coordinates out of
range), a creature with more drops than `MAX_LOOT` (64; it fails rather than
cutting the list) and a file over 480 KB.

The packaged file's header names the Holdfast commit: currently `dc66556`
(Indicaza/holdfast#309, on #306–#308: item facts from the WoW Forever
client, boss loot relationships and reference drop rates). Regenerate it
whenever the atlas, the reference loot or the quest catalog changes on
Holdfast `main` (after #306–#309 merge, regenerate from `main` so the header
names a `main` commit).

### Licences: ForeverDB's data in its own file

The atlas file is exported from Holdfast's MIT base reference loot (the
Forever and Classic clients only) and holds nothing from ForeverDB.net.
ForeverDB's data (reference drop rates, its players' loot records, item
facts it supplies) is GPL-3.0 with ForeverDB's attribution term, so it is
exported apart, into `Data/ForeverDB.generated.lua`:

```
lua5.1 scripts/exportForeverDb.lua \
  --atlas ../web/holdfast/backend/src/Atlas/data/atlas.json \
  --base-loot ../web/holdfast/backend/src/Atlas/data/reference-loot.json \
  --foreverdb-loot ../web/holdfast/backend/src/Atlas/data/foreverdb/reference-loot.json \
  --relationships ../web/holdfast/backend/src/Atlas/data/foreverdb/loot-relationships.json \
  --wings ../web/holdfast/backend/src/Atlas/data/wing-manifest.json \
  --quests ../web/holdfast/backend/src/Atlas/data/quest-catalog.json \
  --commit $(git -C ../web/holdfast rev-parse HEAD)
```

It holds only what ForeverDB's data changes: item facts that differ or
exist only with it (marked `fd` when loaded), and per boss and rare the
loot list, listed-by codes (`4`: only ForeverDB lists it), reference rates
(`rt`: `percent:kills:o` observed in WoW Forever over that many looted
kills, `percent::c` Classic data) and drops still known by id only. Its
first line is ForeverDB's notice line, unchanged, as its attribution term
asks. `Guide.ApplyForeverDb` applies it when the guide builds a dungeon;
without the file (remove it from the TOC) the journal shows the base data.
Its licence ships in `Licenses/` (copied into the release by
`release.yml`); the credit "Data from ForeverDB.net (https://foreverdb.net)"
shows in item tooltips that use its data, in `/gw credits`, in
`Licenses/README.md` and in the README. Guildweaver's own observed rates are
on the website only (preliminary until the loot-window coverage is verified
in game).

Item facts: an item no source grades has no quality (`q` nil; the tooltip
says so). Items carry `qi` (a quest item) and `fv` (an item WoW Forever
added, its facts from no Classic source).

The item table is packed: each item is a positional row whose repeated
strings (slot, armour or weapon type, bind, set) are indexes into one list,
and `A.items()` unpacks it into the same tables as before when the guide first
asks. This keeps all 2,204 items and the nine new dungeons well under budget
without dropping anything.

### WoW Forever's own dungeons

City of Dalaran (2959), The Drowned City (2970), Blackmaw Hold (2974), Alcaz
Prison (2994), Excavation Site: Wetlands (2998), Ruins of Lordaeron (2999),
Shaper's Terrace (3001), Krol'dok Stronghold (3039) and The Hall of Thanes
(3065) come from Holdfast with `origin = "forever"`: IDs, level bands,
entrances and the bosses' names from the Forever client's own tables
(OpenMap). Per dungeon the file adds `origin`, `cov` (what is known:
`enc` encounter IDs, `npc` NPC IDs, `maps`, `ab` abilities), `floors` (floor
names), `qlist = false` when no quest list exists (Blackmaw Hold, Shaper's
Terrace: unknown, not zero), and `unres`: drops a guide lists by item ID that
have no item facts (WoW Forever's own items), on the boss or rare when its
NPC ID matches, else on the dungeon. The same `unres` lists Forever's new
drops in original dungeons. Quests come from Holdfast's quest catalog with
`prek = false`: their chains are not known.

Nothing is guessed: only the two observed encounter IDs (3480 Saltspine,
3481 Shadetooth) are set, no abilities or maps are claimed, and the guide
labels these pages "WoW Forever" instead of "Classic reference". A run in one
is tracked like any instance: kills of encounters the boss registry does not
know count as "unknown", never toward a clear; the client's lockout count is
what completes it.

### Instances the atlas does not know (`/gw dungeon catalog`)

`Systems/DungeonCatalog.lua` keeps, in SavedVariables only
(`dungeon.catalog`), up to 20 instances entered that the atlas does not know
(client name, type, difficulty, size, lockout encounter count, visits) and,
for the nine Forever dungeons, the client's name and lockout count. It writes
when DungeonSessions reads the instance on entering the world or changing
zone, never per frame or on the combat path. Nothing is published.
`/gw dungeon catalog` prints the atlas's coverage, those facts (flagging a
lockout count that differs from the atlas's boss count), the candidates and,
out of combat only, LFG activities whose instance map the atlas lacks
(`C_LFGList`, read defensively). A maintainer checks them and adds them to
Holdfast by hand.

What is exported (only what the game shows): names, level bands, zone and
entrance, encounter and NPC IDs, up to 12 abilities per creature (name,
category, priority, interruptible, the client's short summary), dangerous
trash, rares, up to 40 quests per dungeon (objective, giver and where,
rewards, prerequisites, faction; a known limit: the zone quests of
Zul'Gurub, Ahn'Qiraj Temple and Naxxramas run past 40), boss/rare/other loot
item IDs with who lists each (`ls`: 1 AzerothCore, 2 DungeonPlanner, 3 both;
shown in the item tooltip), a boss's own chest (`chest`), shared drops named
by their creatures or chest, item facts,
the spawn layout's 1% grid cells (kept in the file; the journal no longer
draws them), and provenance lines. Left out: art URLs,
provenance URLs, area triggers, long descriptions, drop chances (none exist).

## Quest readiness (sprint step 4B)

The Quests tab shows, for the character you are playing, where each of a
dungeon's quests stands, and the overview line says whether you are ready.
The rules are Holdfast's (`backend/src/Atlas/atlasReadiness.js`,
`docs/dungeon-quest-readiness.md` there), carried over line for line in
`Systems/DungeonReadiness.lua`:

| Quest state | When |
| --- | --- |
| Completed | the client says it is completed (repeatable quests never stay completed) |
| In quest log | it is in your quest log ("Ready to turn in" when its objectives are done) |
| Pick up | you can take it now: eligible, prerequisites done, not taken |
| Needs an earlier quest | a prerequisite is known not to be done |
| Not for you | faction, race, class or level rules it out (only counted) |
| Not known | a fact it needs was not read, or (WoW Forever) its chain is not known |

Readiness is over the required (`dungeon`) quests that apply: **Quests
ready** (every one completed or in the log), **Quests to pick up**,
**Quests blocked**, **Quests not known**, or **No quest list known**.
Optional, prerequisite and repeatable quests never change it. A character
is never ready while a required quest's state is unknown, so a client that
reads nothing is "not known", never "ready". A dungeon no source lists
quests for (Blackmaw Hold, Shaper's Terrace, Zul'Gurub, Ahn'Qiraj Temple,
Onyxia's Lair) says that no list is known, not that it has none.

The Quests tab groups them, most urgent first: Pick up before you go,
Needs an earlier quest first, Not known yet, In your quest log,
Prerequisite chains, Optional quests, Completed. Each row shows the giver
and where (from the atlas when it lists the quest, else the catalog), the
prerequisite chain with where each step stands, and, when the atlas has
them, the objective and rewards. A summary line on top says what the client
could not give (for example a collapsed quest log header).

### The quests: `Data/DungeonQuests.generated.lua`

Holdfast's quest catalog, every quest a dungeon shows by default (753
quests, 35 dungeons, no cap; the 159 zone-only raid turn-ins are left out,
as the website hides them): name, levels, faction (an unknown faction stays
unknown), races, classes, repeatable, reputation, prerequisite ids (and
`mustBeActive`), whether the chain is known, the wing, the giver's name and
single spawn. No objectives or rewards: the atlas file has those for the
quests it lists. 72 KB; the file defines one function (about 194 KB of
compiled Lua at login) and the tables (about 470 KB) are built the first
time the journal or the quest capture asks.

```
lua5.1 scripts/exportDungeonQuests.lua \
  --quests ../web/holdfast/backend/src/Atlas/data/quest-catalog.json \
  --commit $(git -C ../web/holdfast rev-parse HEAD)
```

`--check` verifies the packaged file. Currently from Holdfast `d00c489`
(main after #303). The 40-quest cap of the atlas file is unchanged: that
list only feeds objectives and rewards now.

### Your quests: `Systems/CharacterQuests.lua`

Not `Systems/Quests.lua` (Guildweaver's own guild quest assignments). It
reads what the client says about the character's World of Warcraft quests.
Every API is feature-detected; none is assumed to exist on the Forever
client:

| What | APIs, in order of preference | Coverage |
| --- | --- | --- |
| Completed quests | `C_QuestLog.GetAllCompletedQuestIDs`, `GetQuestsCompleted` | `full`, only when the list came back with ids (an empty list may not be loaded yet) |
| | `C_QuestLog.IsQuestFlaggedCompleted`, `IsQuestFlaggedCompleted`, for every catalog quest | `checked`, with exactly the ids asked |
| | none | `none` |
| Quest log | `C_QuestLog.GetNumQuestLogEntries` + `GetInfo` (+ `IsComplete`), `GetNumQuestLogEntries` + `GetQuestLogTitle` | `full`, only after a `QUEST_LOG_UPDATE` and a scan that read every entry's quest id with no collapsed header; else `none` |
| Who | `UnitFactionGroup`, `UnitRace` (token), `UnitClass` (token), `UnitLevel` | missing facts stay unknown |

OpenMap (Interface 16001) uses `C_QuestLog.IsQuestFlaggedCompleted`,
`C_QuestLog.GetLogIndexForQuestID` and `C_QuestLog.IsComplete` on Forever,
so `checked` is the least the add-on should get there; whether the whole
list and the log enumeration exist is for the in-game checklist
(`/gw dungeon quests`).

Events: `PLAYER_ENTERING_WORLD`, `QUEST_ACCEPTED`, `QUEST_REMOVED`,
`QUEST_TURNED_IN`, `QUEST_LOG_UPDATE`, `PLAYER_LEVEL_UP` (each registered
only if the client has it). They mark what changed; one capture runs 2
seconds after the last, never in combat (it waits for `PLAYER_REGEN_ENABLED`).
The completed list is reread only on login, turn-ins and removals; the log
on its own updates. A turn-in counts as completed at once, even before the
client's list catches up. After entering the world nothing is published
until the log has loaded (or 30 seconds have passed), so a `/reload` does
not publish a state without the log and then the full one.

### The `quest_state` stream

One state stream per character, `quest_state:<characterId>`
(`Telemetry/Domains/QuestState.lua`), the contract in Holdfast's
`docs/dungeon-quest-readiness.md`: faction, race and class tokens, level,
`completed { coverage, questIds, checkedQuestIds? }`,
`questLog { coverage, entries = { { questId, isComplete } } }` and
`capturedAt`. Only ids and tokens: no titles or other text. It is stored
with a fingerprint of its content (not `capturedAt`), so an unchanged state
is never stored or sent again, across `/reload` too. The bridge carries it
like any other stream; Holdfast validates it and shows the website's
readiness from it. It reaches the website only after the game writes
SavedVariables (`/reload` or logging out) and the bridge syncs.

`/gw dungeon quests` rereads the client and prints which APIs answered,
each coverage, how many quests were read, and the last record saved.

### Keeping it the same as Holdfast

`test/fixtures/readiness-parity.json` holds 117 cases Holdfast's engine
computed (13 dungeons and wings, 9 character states).
`test/dungeon_readiness_spec.lua` requires the same readiness, counts, and
quest-by-quest states and reasons here. Regenerate it when Holdfast's rules
or catalog change, along with `Data/DungeonQuests.generated.lua`:

```
node scripts/readinessParity.mjs ../web/holdfast/backend test/fixtures/readiness-parity.json
```

(Node, run against a Holdfast checkout; it imports Holdfast's own
`atlasRepository.js`. Currently from Holdfast `dc54ca8`, Indicaza/holdfast#305,
whose rules are main's.)

## Quest preparation checklist

The quest tab opens with an ordered checklist: what to collect, from whom
and where, what a group member could share instead, when to go in, and
what to turn in after the run. `Systems/DungeonQuestPlan.lua` is a port of
Holdfast's planner (`backend/src/Atlas/atlasQuestPlan.js`,
`docs/dungeon-quest-planner.md` there), built on `GW.DungeonReadiness`.

- Sections shown: Collect before you go, Or ask your group to share,
  Enter, After the run (turn-ins and follow-ups), Not known. Optional and
  repeatable quests stay in the quest groups below the checklist.
- Top-level steps are numbered, their parts lettered; the next step is
  highlighted and named in the summary.
- Built only out of combat (the last one stays during a fight) and cached
  by page and character state. `GW.CharacterQuests` re-reads the quest log
  on QUEST_LOG_UPDATE / QUEST_ACCEPTED / QUEST_TURNED_IN, debounced, and
  the journal refreshes when the state changes.
- Waypoint button: TomTom (`TomTom:AddWaypoint(mapId, x, y, { title,
  from = "Guildweaver" })`, the previous one removed), else the client's
  user waypoint (`C_Map.SetUserWaypoint`, super-tracked), else the
  coordinates as text. A waypoint is set only when `C_Map.GetMapInfo(mapId)`
  exists and names the record's zone: catalog map ids are projected from
  AzerothCore spawns and not verified on Forever.
- Published quest edits from Holdfast's Dungeon Content Studio are packaged
  at export time (no download in game) and laid over the catalog before any
  state is decided, as Holdfast does: shareability, prerequisite chains,
  giver and turn-in locations (waypoints marked `editorial`, verified or
  not), the entrance, a quest's steps (lettered notes under it) and
  per-section instructions (note lines, never the next step). Without an
  edit, a turn-in location is "not in our data".
- The quest data (`Data/DungeonQuests.generated.lua`) now carries each
  zone's UiMap id (table `M`) and the shareable flag (`s`/`n`).

Packaging the edits: export the studio's bundle from Holdfast
(`GET /api/admin/atlas-studio/export/addon`, or
`node backend/scripts/exportEditorialBundle.mjs --out bundle.json`), then

```
lua5.1 scripts/exportDungeonQuests.lua   --quests ../web/holdfast/backend/src/Atlas/data/quest-catalog.json   --commit $(git -C ../web/holdfast rev-parse HEAD) --editorial bundle.json
```

It writes `E[instanceId]` (contract schema 1, permille coordinates) into
`Data/DungeonQuests.generated.lua`. It refuses, never cuts: a bundle whose
`questPlanProblems` is not empty, a text over its bound (step or
instruction 200 bytes, notes 500), coordinates outside 0-1, a duplicate
dungeon or quest, or a file over the 256 KB budget. Without `--editorial`
the file is as before, with an empty `E`.

Parity: `node scripts/questPlanParity.mjs <holdfast backend> test/fixtures/quest-plan-parity.json`
regenerates the cases `test/dungeon_quest_plan_spec.lua` checks (ids,
kinds, statuses, order, waypoints, next, readiness; not text), including
18 cases with SYNTHETIC published edits for Deadmines, The Hall of Thanes
and Uldaman (made up for the test, not game facts), packaged through the
exporter's own code. `test/fixtures/editorial_quest_bundle.json` is the
same synthetic edits as a studio bundle.

## The look (sprint step 5A)

The journal draws its frames with the game's own interface art, through the
theme (`UI/Theme.lua`), never one-off styling in a view:

| Piece | Art | Without it |
| --- | --- | --- |
| Dungeon cards, the boss header (`Theme.Panel` "stone") | `FrameGeneral\UI-Background-Rock`, darkened, in `Tooltips\UI-Tooltip-Border` (bronze at rest, gold on hover and when selected) | the flat panel and hairline |
| The map (`Theme.Panel` "gold") | the rock in `DialogFrame\UI-DialogBox-Gold-Border` | the flat inset and a gold hairline |
| The quest summary (`Theme.Panel` "inset") | the rock, darker, in the tooltip border, with a stripe in the readiness colour | the flat inset |
| Loot and reward cells | `Buttons\UI-Quickslot2` round the icon (64 px round a 37 px button, as the client's item buttons), tinted in the item's quality from Uncommon up | the quality hairline |
| Clickable rows and cards | `QuestFrame\UI-QuestTitleHighlight` on hover | the hover fill |
| Quest states | `GossipFrame\AvailableQuestIcon`, `IncompleteQuestIcon` (in the log), `ActiveQuestIcon` (ready to turn in) | |
| Section headers | a one-pixel bronze line from the title to the edge, fading out (`Theme.Divider`); the bright gold underlines are gone | a flat bronze line |
| Cards without map art (WoW Forever's dungeons, Naxxramas) | the Guildweaver emblem, large and faint | |

Every file in the table is used by OpenMap, an add-on built for the WoW
Forever client (Interface 16001), so it is known to exist there. Each goes
through `Theme.Texture`, which notices a file the client lacks (`SetTexture`
answers false); borders need the client's `BackdropTemplate`. Either
missing, the view keeps the flat look it had before, never an empty frame.
No art is downloaded or bundled; the add-on's own `Media/` is unchanged.

Key mechanics on a boss page are callouts: a stripe and a faint wash in the
category's colour (kick blue, tank red, healer green, dispel purple, move
amber, crowd control gold), and the ability name in the body font. Other
abilities stay plain rows. The boss header is framed, with an 80 px
portrait (was 72). Cards show the character's quest readiness under the
level band ("2 quests to pick up", "Quests ready"), only for dungeons with
required quests; the quest tables are never built for them mid-fight.

Cost (fake client, `test/journal_polish_spec.lua` and a timing script):
login memory is unchanged; the first open makes one border frame per framed
panel (258 frames instead of 216) and builds the quest tables for the
cards' readiness (about 470 KB, once a session; already built at login
where the client only offers per-quest completion checks). Navigation,
resizing and boss pages make no new frames and cost the same as before.

### Creature identity

A corpse's `mob_loot` report names its creature when the add-on saw that
very creature (`source.nameSource = "unit"`): on the target, mouseover,
focus, a nameplate or a boss frame, with its GUID and name read together and
`UnitCreatureID` agreeing with the GUID's NPC ID. The sighting is kept for 30
minutes (at most 400 creatures), so a corpse looted after its unit is gone
is still named. Otherwise the name of another creature with the same NPC ID
may be given (`nameSource = "npc"`), and nothing else is borrowed. The
creature's classification (`elite`, `rare`, ...) comes only from its own
sighting. The client has no unit API for creature display IDs, so none is
reported: portraits keep using the art table's display IDs by NPC ID.

## Loot observations (drop rates)

`Systems/MobLootCapture.lua` already reports each corpse's loot window
(`mob_loot`, one per corpse GUID, saved across `/reload` so a corpse is never
reported twice). For drop rates (Holdfast `docs/loot-sources.md`, "Observed
drop rates") each report now says whether the window was a complete look at
the corpse's loot:

- `capture.inspection = "complete"`: every item slot was tied to its corpse
  (`GetLootSourceInfo`) and nobody could have taken items first; `"partial"`
  with `partialReason` `unmapped-slot` (a slot with no corpse) or
  `free-for-all` (free-for-all looting in a group). `slotCount`: the window's slots.
- An atlas boss's or rare's window that held only coins is reported with no
  items (complete windows only): a kill without an item drop, so Holdfast
  has an honest denominator. Trash coin-only windows are not reported.

Nothing else changed: no new events, no new SavedVariables, no network.
Holdfast counts one corpse once however many Guildweaver players saw it.

Not verified in the client: that `GetLootSourceInfo` maps every slot on
Forever, and what a second looter sees under group loot.

## Client art: maps and portraits

`Data/DungeonJournalArt.generated.lua` (`GW.DungeonJournalArt`) holds IDs
only. The client draws the art; Guildweaver ships no Blizzard picture.

- **Maps**: Blizzard's own dungeon map of each floor, still in the client as
  12 textures (4 columns x 3 rows of 256 px; the picture is the top-left
  1002 x 668 px). File IDs from OpenMap (MIT,
  `OpenMap/Data/Forever/DungeonMaps.lua`, read from the game's UiMap tables).
- **Boss pins**: where Blizzard's dungeon journal places each boss on those
  floors, from OpenMap (`OpenMap/Data/Forever/DungeonBosses.lua`). Only these
  are pinned. The atlas's spawn layout is another projection and is never
  laid over the map; a boss without a journal position is only listed.
- **Portraits**: creature display IDs (and levels) per NPC ID from
  DungeonPlanner (MIT, `Data/Bosses/*.lua`; Wowhead Classic,
  warcraft.wiki.gg). A boss entry's display belongs to its own NPC only (Sneed
  does not get his Shredder's face). The guide asks, in order: the verified
  registry (`Data/DungeonBosses.lua`), the client's journal (what the HUD
  read), then this table.

`scripts/exportJournalArt.lua` (Lua 5.1) writes it from read-only checkouts
of the two add-ons (`../references`, never part of this add-on):

```
lua5.1 scripts/exportJournalArt.lua --openmap ../references/openmap \
  --planner ../references/DungeonPlanner [--check]
```

The file's header names both reference commits. The exporter refuses a floor
without 12 tiles, a pin off the picture or on a missing floor, and an NPC
with two display IDs.

| Coverage | |
| --- | --- |
| Maps | 25 of 26 instances, 63 floors (Naxxramas: none in the client) |
| Boss pins | 150 of 240 bosses, in 21 instances. Deadmines 7/7 (two floors); Ragefire Chasm, Stockade, Scarlet Monastery, Scholomance, Naxxramas: none |
| Boss portraits | 215 of 240 bosses (Ragefire Chasm 4/4, Deadmines 6/7) |
| Rare and trash portraits | none (no display IDs in either source): the rare star / skull icon |

## Data size and memory

| | |
| --- | --- |
| Atlas file | 406 KB (416,030 bytes; budget 480 KB, enforced by the exporter and the spec): 2,227 items, nothing from ForeverDB |
| ForeverDB file | 74 KB (75,755 bytes; budget 160 KB): its item facts, loot lists and rates (GPL-3.0, `Licenses/`) |
| Lua memory at login | atlas about 946 KB (was 940 KB), ForeverDB file about 182 KB (compiled data; no tables are built until the guide asks) |
| Art file | 23 KB; about 89 KB of compiled Lua at login, tables built on first use |
| Quest catalog file | 72 KB (73,646 bytes; budget 256 KB, enforced by its exporter); about 194 KB of compiled Lua at login, about 470 KB once the journal's Quests tab or the quest capture builds it |
| Quest state | no SavedVariables of its own: the outbound `quest_state` record (the ids the bridge sends) and nothing else |
| Atlas coverage | 35 dungeons and raids (26 original, 9 WoW Forever), 298 bosses (WoW Forever: 58, 35 with NPC IDs, 2 with encounter IDs), 339 quests (64 in WoW Forever dungeons), 191 drops by item ID without facts (135 in WoW Forever dungeons). The original 26: 240 bosses (230 with reference loot, 176 with abilities), 173 dangerous trash, 27 rares (all with loot), 275 quests, 786 spells (173 interruptible casts), 2,204 items, 205 shared drops (every one named) |

At login only small indexes exist. A dungeon's detail, the spell, item and
art tables are built the first time the guide (or entering that dungeon)
needs them and cached for the session. Nothing goes to SavedVariables except
the journal's preferences (follow the current instance, the last dungeon
opened) and the dashboard's size.

## How it behaves

The window opens at 1050 x 700 and can be resized from the grip in its
bottom-right corner, never below 740 x 500 (a 531 x 417 content area, what
every dashboard view is built for) and never beyond the screen. The size and
position are saved with the dashboard's preferences and restored after
`/reload`; Settings -> **Reset window** restores the default size and
position. A UI scale or resolution change clamps the window to the new
screen and restores the chosen size when there is room again.

The content follows the window's real size: every size change (the grip
while it is dragged, a clamp, the client) schedules one light layout at most
every 50 ms, which only moves and sizes existing frames (cards, rows, the
map, the loot grid, quests, the breadcrumb) and reads no data; the end of
the drag repaints. In combat the layout waits until combat ends. Layout:

- **Cards:** as many columns of at least 240 px as fit the grid, one to
  three (531 px: two, 841 px: three).
- **Search and filters:** one row when they fit; else the switches wrap
  under the search; else each on its own row.
- **Overview:** the list (200 to 280 px) beside the map; under 520 px the
  list sits over the map. The map takes the room left, its 1002 x 668
  aspect kept, and its pins move with it.
- **A boss:** the loot grid has as many 40 px columns as the panel holds.
- **Breadcrumb:** the deepest crumbs shorten (and truncate) to leave room
  for the arrows and **Current dungeon**; the run strip's name gives way to
  its buttons; the dungeon's subtitle stops before the Reference indicator.

(One column and the stacked overview only occur below the window's minimum
content width; they are tested directly, not reachable by resizing.)

One navigation, three levels: **Dungeons** -> a dungeon -> a boss or
creature. **Back** and **Forward** (the arrows top left) walk the journal's
own history; the breadcrumb (`Dungeons > Deadmines > Captain Greenskin`)
goes up a level. Each page keeps its scroll position and each dungeon its
floor. A boss opens the same page from its map pin, from the list, or from
its face in the HUD. Inside a known instance, **Current dungeon** (top right)
opens it.

- **Dungeons (the landing page).** A grid of cards, two or three columns as
  the width allows, scrolling. Each card: the dungeon's name, a strip of its
  own map from the client as art (none where the client has no map), levels,
  zone, Dungeon or Raid, boss count, and when known: your wishlist count (the
  purple raid diamond), your runs there, "You are here" or "Your level".
  The dungeon you are in comes first, then those for your level, then the
  rest. Search by name, filter by level band (10-29, 30-49, 50+) and by
  dungeon or raid. Nothing is opened by itself. **My Runs** lists every
  finished run (date, duration, bosses, outcome); a click opens that
  dungeon's runs.
- **A dungeon: Overview.** Title, levels and zone, the Reference indicator
  (the entrance and the sources in its tooltip). Left, scrolling: **Bosses**
  (portrait, level, the state the open run observed, the top mechanics'
  spell icons, the wishlist diamond), **Rares**, **Dangerous trash** (count,
  KICK when one of its casts is interruptible) and **Other dungeon loot**.
  Right: the client's map, as large as the window allows, with numbered boss
  portraits where Blizzard's journal placed them; the floor arrows turn the
  floors. Hover a pin for the boss's top mechanics; click it for the boss.
- **A boss or creature.** A large portrait, name, level and classification,
  the observed state, then **Key mechanics** (up to four), **Other
  abilities**, and **Loot**: bag-sized item icons in a grid with the quality
  colour on the frame, a purple raid diamond on wishlist items and a check on
  acquired ones. Rares the same; dangerous trash a compact page with the
  drops the atlas names it as the source of. There is no item click action.
- **Loot belongs to its source.** A boss's and a rare's own lists; an atlas
  drop whose named source is exactly a listed creature goes to that creature;
  everything else (no source, or a source the atlas lists no creature for,
  and wishlist items naming the dungeon but missing from the reference
  lists) is under **Other dungeon loot**, never guessed onto a boss.
- **Mechanics order** (the same for everyone; there is no role switch):
  dangerous interrupts (KICK only for a cast the client marks
  interruptible), then lethal or major mechanics (high priority, TANK, HEAL,
  MOVE), then dispels and crowd control, then the rest; within a group the
  atlas's priority, then its order.
- **Spell icons** come from `C_Spell.GetSpellTexture` (then
  `C_Spell.GetSpellInfo`, then the old globals). The guide used to call only
  the global `GetSpellTexture`, which this client does not answer, so every
  spell showed the red question mark. A spell the client has no icon for
  shows an empty slot, dimmed, with its name and label.
- **Quests.** Name, level, required level, faction, giver and where, the
  quests before it, the objective, and reward item icons ("Choose one" where
  the reward is a choice); a check and "Completed" only when the client
  confirms it (`C_QuestLog.IsQuestFlaggedCompleted`).
- **My Runs (a dungeon's).** Its finished runs: date, duration, bosses,
  deaths, outcome.
- **The run strip.** While a run is open, one slim line under the top bar:
  the run's name (a click opens it), clock, state, bosses, deaths, and
  Start/Pause/Resume, End run (click twice) and Show/Hide HUD. Splits and
  everything else stay in the HUD, the tracker in combat.
- **Tooltips.** Items show the game's own item tooltip (`item:<id>`) with
  the source and wishlist note under it, and Blizzard's comparison while
  shift is held (or always-compare is on; pressing or releasing shift updates
  it). Spells show the game's spell tooltip with the label and the reference
  note. Every tooltip in the journal opens just right of and above the
  cursor, clamped to the screen, and goes on mouse leave.
- **Removed:** the separate Dungeon Guide entry, the old Dungeons page with
  its large "No run open" panel and command hints, the Loot tab, the item
  rows, the Any/Tank/Heal/DPS switch, paging, and manual objectives (neither
  the dashboard nor the HUD shows them; `GW.DungeonObjectives` and its saved
  list are untouched).

### HUD

- **?** button in the HUD header opens the guide.
- Boss faces use the same portrait engine; a face the client's journal gave
  no art for takes the guide's display ID. Hover: the boss's top mechanics
  and wanted drops; click: the guide on that boss.
- Expanded HUD: a "NEXT:" (or "NOW:") line with the next boss's two top
  mechanics. Timer, splits, boss tracking, PB logic and combat collapse are
  unchanged; manual objectives are no longer shown.

### Combat and performance

- Rows, cards, item cells and quest rows are pools that grow to the largest
  list shown and are reused; the mouse wheel and the scroll bars only move an
  offset. Browsing every page of every dungeon grows the pools once (about
  250 frames in the test client), a second pass creates none.
- No OnUpdate handlers, no tickers, no tooltip or item scans (item icons come
  from the client's item table, not `GetItemInfo`), no combat log, no
  protected calls, no hooks on Blizzard functions, no reloads.
- No layout in combat: a resize that ends in combat is laid out when combat
  ends; a card's map strip is set out of combat only.
- The dashboard view is built on first open, never in combat (the ? button
  and face clicks only show it if it already exists; otherwise a chat line).
- Portraits: a creature's first draw loads its model; one shared
  `C_Timer.After` (2.5 s, only while something loads) redraws it. In combat a
  creature not loaded yet is not drawn: the fallback stays until the fight
  ends. Entering a known dungeon out of combat builds it and starts loading
  its bosses' faces into a few reused off-screen textures.
- Maps: 12 reused textures; a floor's art is set only when the floor changes
  and never in combat ("The map draws after combat"). Pins are pooled.
- `GW.Perf` records `guide:build`, `guide:map` and `guide:refresh`
  (`/gw perf`).

## Editorial content (Dungeon Content Studio)

Holdfast's Dungeon Content Studio (`/admin/dungeons`) publishes editorial content over the atlas: boss guides, mechanics callouts, dungeon notes, and edited names, levels and entrances. Its `docs/dungeon-content-studio.md` describes the studio itself.

Publishing on the website does not change the add-on. Content reaches players with the next add-on release, which takes three steps:

1. **Holdfast, against the production data directory.** This writes the bundle of active published revisions and the packaged textures:

   ```
   node backend/scripts/exportEditorialBundle.mjs --out editorial-bundle.json --art Media/Atlas
   ```

2. **Here.** Regenerate the atlas with the same arguments as above, plus the bundle:

   ```
   lua5.1 scripts/exportDungeonAtlas.lua ... --editorial editorial-bundle.json --commit <holdfast sha>
   ```

3. Release the add-on as usual.

How the export behaves:

- **The rules live in Holdfast.** `Atlas/Editorial/addonTransform.js` decides what wins over the import, cuts text to the limits and orders mechanics by priority. The exporter only checks the bundle against the same limits (`Export.EDITORIAL`) and renders it with the same literal syntax (`Export.literal`).
- **Limits stop the export.** An entry over a limit, an unknown field, a boss key the atlas lacks, or more than 6144 bytes per dungeon / 49152 in all stops the export. Nothing is cut silently.
- **The CMS's add-on preview and byte count are exact.** `test/dungeon_editorial_spec.lua` compares the rendering with Holdfast's expected lines byte for byte, using `test/fixtures/editorial_*`, written by Holdfast's `backend/scripts/addonEditorialParity.mjs`.
- **Without `--editorial`, the generated file is unchanged.**
- **In the generated file**:
  - `A.editorial()` returns the entries by instance ID (keys documented in the exporter).
  - `A.editorialArt` lists packaged textures.
  - `GW.DungeonGuide.ApplyEditorial` lays an entry over a built dungeon: name, level band and entrance, and `boss.ed` and `dungeon.ed`. The boss order stays the atlas's, because runs refer to bosses by position.
- **In the journal**:
  - Boss pages get a **Guide** section: mechanics callouts (label, ability, high priority, roles, unverified) and the guide's text.
  - The dungeon's notes are added to its source badge tooltip.
  - Packaged card art replaces the map strip on the dungeon card.
  - A packaged portrait is used only when the client has no creature model for the boss.
- **Art formats.** The client loads add-on textures from the add-on folder, and this add-on ships uncompressed `.tga` (`Media/*.tga`). Everything else it draws comes from client file IDs and display IDs.
  - CMS art therefore arrives only as power-of-two TGA textures (card 512×256, portrait 128×128) under `Media/Atlas/`, converted by Holdfast from PNG uploads. JPEG and WebP stay website-only, with the originals kept in the CMS.
  - A 512×256 texture is 512 KB uncompressed in the zip.
  - There is no runtime download.
- **Not yet checked in the WoW Forever client**:
  - that packaged `Media/Atlas` textures draw on cards and portraits;
  - that the Guide section's text wraps and scrolls well in a real window;
  - that the badge tooltip with notes is readable.

## Tests

`test/dungeon_guide_spec.lua` (atlas exporter, packaged atlas, lookups, the
mechanics order, loot by source with nothing dropped or invented, wishlist,
selection, the journal's pages and empty states, combat, performance over
every page of every dungeon, the HUD) and `test/dungeon_journal_spec.lua`:
the art exporter on an excerpt of the references (`test/fixtures/journal_refs/`,
with their licences), the packaged art table, floors, pins and display IDs
(never an NPC ID), observed encounter states, the portrait engine, the map
renderer, the dungeon cards (art, filters, order, scrolling), Back / Forward
and the breadcrumb, a boss's page and its loot grid, tooltips at the cursor
and shift comparison, spell icons through `C_Spell` and the empty-slot
fallback, trash and other loot, quests (completed only when the client says
so), runs and the run strip, the HUD's faces and deep links, resizing
(test/dungeon_journal_layout_spec.lua: the minimum, medium and large
windows, three/two/one columns, wrapping controls, the compact overview,
the map's aspect, loot grid reflow, the breadcrumb's bounds, repeated
shrinking and growing without new frames, a drag that reads no data,
combat, /reload, UI scale and screen changes, every other view), and that
nothing from `references/`
(or a glyph the game font lacks) is shipped. `test/ui_overhaul_spec.lua`
covers the dashboard: one Dungeons entry, the strip's timer and End run,
and the window size kept across `/reload`.

`test/dungeon_forever_spec.lua` covers WoW Forever's own dungeons: the
exporter's Forever fields (origin, coverage, floors, quests without known
chains, `qlist = false`, drops by item ID on their boss or the dungeon), the
packed item table unpacking to the same facts, the packaged nine (only
observed encounter IDs, no Classic loot or abilities claimed), a run in one
(unknown encounters never complete it; the lockout does), saved runs after
`/reload`, and the catalog (candidates bounded, never on the combat path,
never published; the report with and without an LFG list, not scanned in
combat).

`test/dungeon_readiness_spec.lua` covers the packaged quest catalog (counts,
no cap, unknown faction kept, class rules, wings, Forever chains, no list
for Blackmaw Hold), its exporter, and parity with Holdfast's readiness on
117 cases. `test/character_quests_spec.lua` covers the capture on a made-up
client: the whole completed list, checked-only, an empty list never "full",
the classic APIs, no APIs at all, the log waiting for `QUEST_LOG_UPDATE`,
accepting, turning in (completed before the list catches up), abandoning,
a collapsed header, level-up, bursts of events (one capture), combat, a
minute of questing (bounded captures and list reads), the payload's shape
(ids and tokens only), SavedVariables round trip, `/reload` (nothing stored
again), a second character's own stream, and the journal's summary, groups
and chains.

`test/journal_polish_spec.lua` covers the look: the art asked for (rock,
borders, slot frames, highlights) and the fallbacks when the client lacks a
file or the backdrop template; card borders at rest and on hover; no
underline; readiness on cards; the emblem for cards without art; the framed
map, boss header and quest summary; mechanic callouts; slot tinting; every
page (46: the dungeons, all 11 wings, all 9 WoW Forever dungeons, the 7
raids, their quest tabs and last bosses) laid out within bounds at four
sizes from 420 x 380 to 1700 x 980; and that the cards never build the
quest tables in combat.

The fake client proves behaviour, not looks: it draws nothing.

## In-game checklist (not yet done in the client)

The look (sprint step 5A), at the smallest, the default and a large window:

- Cards: Blizzard's dark rock inside a thin bronze tooltip border; hovering
  brightens the border to gold with a soft highlight; the map strip shows
  through, or the faint emblem on WoW Forever dungeons and Naxxramas. The
  name has no underline. The readiness line reads well over the art.
- The map: a gold dialog edge that does not cover pins at the map's edges;
  the floor arrows and label under it.
- Section headers ("Bosses", "Key mechanics", "Loot", the quest groups): a
  thin line from the title to the right edge, no bright underline.
- A boss page (Deadmines, VanCleef): the rock header with the round
  portrait, name and facts readable; the first mechanics with coloured
  stripes; other abilities plain.
- Loot: each icon in the bag-slot frame, Uncommon and better tinted; the
  wishlist diamond and acquired check still on top; tooltips unchanged.
- Quests: the summary box with its coloured stripe; the grey "?" for quests
  in the log, the gold "?" when ready to turn in, the "!" to pick up.
- If a file is missing on the client, the journal shows the old flat panel
  there instead, and nothing broken.


Quest readiness:

- `/gw dungeon quests` after login: note which APIs answered for completed
  quests (`full` or `checked`) and the quest log, and how many quests each
  read. With every quest log header expanded the log must say `full`.
- Accept a dungeon quest, wait 2 seconds: the Quests tab moves it to "In your
  quest log"; abandon it: back to "Pick up before you go".
- Turn one in: "Completed" at once.
- Collapse a quest log header: the summary says the log could not be read;
  expand it again: back to normal.
- Quest in combat: nothing changes until the fight ends.
- `/reload`, then sync with the bridge: the website's dungeon page shows the
  same readiness, with "Quests as of" the capture time.
- Log another character: its own readiness, its own website state.
- A WoW Forever dungeon (Hall of Thanes): quests not yet taken are "Not
  known" (their chain is not known); completed and accepted ones still show.


WoW Forever dungeons (each of 2959, 2970, 2974, 2994, 2998, 2999, 3001,
3039, 3065):

- Entering it opens its guide page ("WoW Forever" badge) and starts a run.
- `/gw dungeon catalog`: the client's name matches the atlas's, and the
  lockout's encounter count matches the atlas's boss count (a mismatch says
  "counts differ").
- `/gw dungeon bosses` after each kill: note each encounter ID and name, to
  add to `Data/DungeonBosses.lua` (and Holdfast's `FOREVER_OBSERVED`), with its
  role once the final boss is known.
- Boss pages list "N drops listed without item details yet (item ...)"; a
  boss name in the client's own words.
- The run completes only when the lockout shows every encounter down.
- Any instance entered that the atlas lacks shows as a candidate in
  `/gw dungeon catalog`; LFG activities for unknown maps are listed there.


Nothing below has been tried in the WoW client yet. `/console scriptErrors 1`
first; no Lua error should appear at any step.

1. `/reload`, open the dashboard: about 1050 x 700. The sidebar has one
   **Dungeons** entry. Click it: the dungeon cards, nothing opened by itself.
2. Cards: names, levels, zones, map strips behind the text (not grey, not
   stretched badly); Naxxramas plain. Your-level dungeons first. Scroll with
   the wheel and the bar.
3. Search "dead", filter Raids, then 50+, then All: the grid follows.
4. Drag the bottom-right grip smaller and larger, slowly and quickly, on
   the cards, a dungeon's map, VanCleef's page and Quests: the content
   follows during the drag; cards go 3 -> 2 columns; the search, filters and
   Journal / My Runs stay inside the window; the map keeps its shape and
   its pins stay on the bosses; the loot grid rewraps. Try to drag past the
   screen edge and below the minimum. `/reload` keeps size and position;
   Settings -> Reset window restores them. Change the UI scale (Interface
   options) with the window open: it stays on screen and lays out again.
5. Click Deadmines: a large map of the mine with Rhahk'Zor and Sneed
   pinned; the arrow turns to Ironclad Cove with five pins, each on its
   boss's spot. Ragefire Chasm: map, no pins.
6. Click Captain Greenskin's pin: his page (portrait, mechanics with real
   spell icons, no red question marks; a spell without an icon shows an
   empty slot with its name), loot as a grid of icons.
7. Hover an item at the right edge of the window: the item tooltip next to
   the cursor, inside the screen; shift shows the comparison; leaving hides
   it. Cruel Barb (VanCleef) has the purple diamond if it is on your
   wishlist.
8. Back: the Deadmines on the floor you left; Back: the cards where you had
   scrolled; Forward twice: Greenskin again. Click "Deadmines" in the
   breadcrumb: up one level.
9. Miner Johnson, a trash entry (count, KICK) and Other dungeon loot each
   open their own page; trash shows only the drops named for it.
10. Quests: names, levels, giver, objective, reward icons with tooltips; a
    quest you have done says Completed (only if the client reports it).
11. In the Deadmines: the run strip (clock ticking, bosses), Current dungeon
    from another dungeon. Kill Rhahk'Zor: Defeated in the list; during
    Cookie, In combat. The HUD's ? and a boss face open the journal on that
    dungeon and boss. End run (twice): it appears under My Runs.
12. In combat: open a new dungeon's overview ("The map draws after combat",
    then it draws); resizing in combat lays out after combat. No hitching.
13. `/gw perf`: guide:build, guide:map and guide:refresh stay small; loot
    roll alerts, boss tracking and the timer behave as before.

## Needs from the website or bridge later

- **Regenerate** `Data/DungeonAtlas.generated.lua` on every atlas change on
  Holdfast `main`, and `Data/DungeonJournalArt.generated.lua` when OpenMap or
  DungeonPlanner add maps, pins or display IDs.
- **Journal positions** for Ragefire Chasm, the Stockade, Scarlet Monastery
  and Scholomance bosses (OpenMap has none): they are listed, not pinned.
- **Display IDs** for rares and dangerous trash, and for the 25 bosses without
  one, would give them faces (the atlas could carry `displayId`).
- **Faction on quests** is used when present.
- **Wishlist edits from the game** would need a bridge protocol change (out
  of scope: the guide is read-only).

## Dungeon wings

Scarlet Monastery (Graveyard, Library, Armory, Cathedral), Dire Maul (East,
West, North), Stratholme (Live, Undead) and Blackrock Spire (Lower, Upper)
are several dungeons on one game map: every wing has the same instance ID.
The wings come from Holdfast's generated `wing-manifest.json` (built from its
`Atlas/atlasWings.js`, the one roster both sides use):
- stable keys, the same as the website's (`scarlet-monastery:library`);
- level bands;
- the bosses and rares each wing owns, by NPC and encounter ID;
- floor names and entrances;
- the bosses no wing owns.

The exporter checks the manifest against the atlas: a boss the atlas does not
know, or one placed in two wings, stops the export. It packages the wings
beside the atlas. `test/fixtures/wing-manifest.json` is a verbatim copy of the
manifest, and `test/dungeon_wings_spec.lua` fails when the packaged wings
drift from it.

**Journal.** Each wing is its own card and page. A wing page shows:
- its own bosses and rares, and their loot;
- the shared quests and other loot of its dungeon, never a sibling wing's
  drops;
- "Not placed in a wing" for the bosses no source assigns.

Its map shows the floors its sources name. Blackrock Spire's floors are not
named per wing by any source, so each of its wings shows the floors Blizzard's
journal pins one of its bosses on. A pin on another wing's floor is not shown:
Postmaster Malown is an Undead boss, but his journal pin is on the Live floor.
A wing without a known floor shows no map. The dungeon's own page (opened by
its instance ID) still lists every boss and names its wings.

**Which wing a run is in.** The run keeps the dungeon until real evidence
names one wing. Evidence is either:
- the client's kill of a boss (by encounter ID) that one wing owns; or
- the map floor the client reports for the player (`C_Map` floor names, read
  on zone changes and never in combat), when that floor belongs to one wing.

Rules for that evidence:
- A boss kill always wins over a floor.
- Kills in two wings leave the run on the dungeon. This can happen in Dire
  Maul, Stratholme and Blackrock Spire, whose wings connect.
- Bosses no wing owns are not evidence.
- The wing selected in the journal is never evidence.
- The evidence is saved with the run, so it survives `/reload`.

**Progress and completion.**
- A resolved wing counts its own bosses ("Bosses 1/2").
- That roster is Classic reference data (DungeonPlanner, InstanceJournal), not
  confirmed on Forever, and it may list a rare spawn (for example Tsu'zee in
  Dire Maul West).
- Every listed boss down is an unconfirmed full clear. It never sets a
  personal best.
- Fewer is "Completion unknown", never a failed or partial clear.
- A clear the lockout proves is verified, as before.
- Personal bests are kept per wing, so a Library clear never paces an Armory
  run. An unresolved run's bests are the dungeon's.

**Telemetry.**
- A run carries an optional `wing` field (`dungeonKey`, `evidence`,
  `encounterId`). Every Holdfast version accepts it: unknown keys are ignored,
  and Holdfast derives a run's wing from its boss checkpoints.
- Holdfast accepts the mandatory-roster completion values (`required_bosses`,
  `required_bosses_unconfirmed`) only from Indicaza/holdfast#300 on. Until
  then, a clear proved that way is sent with `completion.basis` `"none"` and
  the addon's own value in `completion.claimed`. Setting
  `DungeonSessions.WIRE_REQUIRED_BASES` to true sends the real values.

Not verified in the Forever client:
- whether its dungeon floors carry these names through
  `C_Map.GetMapGroupMembersInfo`;
- whether each Scarlet Monastery wing has its own lockout.
