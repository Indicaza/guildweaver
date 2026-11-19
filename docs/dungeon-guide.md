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
  --commit $(git -C ../web/holdfast rev-parse HEAD)
```

`--check` (same arguments) fails when the packaged file does not match the
inputs. The output is deterministic: the same inputs and commit give the same
bytes. The exporter refuses an atlas with problems (an ability claiming
Forever verification from a Classic source, an encounter in two dungeons, a
loot item without facts, a spell classified two ways, coordinates out of
range) and a file over 480 KB.

The packaged file's header names the Holdfast commit: currently `main` at
`46af21b` (after Indicaza/holdfast#297 and #298). Regenerate it whenever the
atlas or the reference loot changes on Holdfast `main`.

What is exported (only what the game shows): names, level bands, zone and
entrance, encounter and NPC IDs, up to 12 abilities per creature (name,
category, priority, interruptible, the client's short summary), dangerous
trash, rares, up to 40 quests per dungeon (objective, giver and where,
rewards, prerequisites, faction), boss/rare/other loot item IDs, item facts,
the spawn layout's 1% grid cells (kept in the file; the journal no longer
draws them), and provenance lines. Left out: art URLs,
provenance URLs, area triggers, long descriptions, drop chances (none exist).

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
| Atlas file | 437 KB (budget 480 KB, enforced by the exporter and the spec) |
| Atlas, Lua memory at login | about 840 KB (compiled data; no tables are built) |
| Art file | 23 KB; about 89 KB of compiled Lua at login, tables built on first use |
| Atlas coverage | 26 dungeons and raids, 240 bosses (203 with reference loot, 176 with abilities), 173 dangerous trash, 27 rares, 275 quests, 786 spells (173 interruptible casts), 2,027 items |

At login only small indexes exist. A dungeon's detail, the spell, item and
art tables are built the first time the guide (or entering that dungeon)
needs them and cached for the session. Nothing goes to SavedVariables except
the journal's preferences (follow the current instance, the last dungeon
opened) and the dashboard's size.

## How it behaves

The window opens at 1050 x 700 and can be resized from the grip in its
bottom-right corner (never below 740 x 500, never beyond the screen). The
size is saved with the dashboard's preferences and restored after `/reload`;
Settings -> **Reset window** restores the default size and position. Every
dashboard view lays itself out for the size once the drag ends (in combat:
when combat ends).

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
(minimum, screen, combat, every view), and that nothing from `references/`
(or a glyph the game font lacks) is shipped. `test/ui_overhaul_spec.lua`
covers the dashboard: one Dungeons entry, the strip's timer and End run,
and the window size kept across `/reload`.

The fake client proves behaviour, not looks: it draws nothing.

## In-game checklist (not yet done in the client)

Nothing below has been tried in the WoW client yet. `/console scriptErrors 1`
first; no Lua error should appear at any step.

1. `/reload`, open the dashboard: about 1050 x 700. The sidebar has one
   **Dungeons** entry. Click it: the dungeon cards, nothing opened by itself.
2. Cards: names, levels, zones, map strips behind the text (not grey, not
   stretched badly); Naxxramas plain. Your-level dungeons first. Scroll with
   the wheel and the bar.
3. Search "dead", filter Raids, then 50+, then All: the grid follows.
4. Drag the bottom-right grip smaller and larger: the cards go 2 / 3
   columns, nothing overlaps or clips; `/reload` keeps the size; Settings ->
   Reset window restores it. Try a smaller UI scale.
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
