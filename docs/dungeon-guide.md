# Dungeon Guide

The website's Dungeon Atlas as an in-game dungeon journal, offline: the
client's own dungeon maps with boss pins, boss portraits, encounters with
their mechanics and spell icons, reference loot with item icons and your
wishlist, rares, dangerous trash and dungeon quests. Dashboard -> **Dungeon
Guide**, `/gw guide`, the **?** button on the dungeon HUD, or a click on a
boss face in the HUD.

Everything from the atlas is **Classic reference data, unverified on WoW
Forever**, and every panel says so. Nothing is invented: a boss, an ability,
an item, a position or a face the data does not have is simply not shown.

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
the guide's preferences (tab, role, follow) and the last dungeon picked.

## How it behaves

The view is a journal in the dashboard's content area (532 x 418): the
dungeon's name is the picker, then the tabs, then navigation on the left and
the map or the encounter panel on the right.

- **Picker.** Click the dungeon's name (or its arrow). Search by name, filter
  by level band (10-29, 30-49, 50+) and by dungeon or raid; 26 entries on two
  pages; the dungeon you are in says "here". **Where I am** (in the header and
  the picker) returns to the dungeon you are in. The last pick survives
  `/reload`. Outside an instance with nothing picked, the guide opens on a
  dungeon for your level, not the first in the list.
- **Overview.** The encounter list (portraits, level, observed state) and the
  client's map of the dungeon with numbered boss portraits where the journal
  placed them; arrows turn the floors (named as the game names them). Hover a
  pin for the boss's top mechanics; click it (or a list entry) for its
  encounter. Under the map: the entrance, how many bosses are placed, wanted
  drops and quests (hover for the list).
- **Encounters.** Encounter frames: portrait, name, level, the state the
  dungeon run observed (In combat, Defeated), the top mechanics' spell icons
  and a purple diamond (raid mark) with the count of wanted drops. The panel:
  a large portrait, name, level and class, then **Watch for**: two to four
  mechanics ordered for your role (Any/Tank/Heal/DPS, or the group role),
  each with its spell icon and label (KICK only for a cast the client marks
  interruptible; else CAST; TANK, HEAL, DISPEL, MOVE, CC, NOTE). Then
  **Abilities** (every ability, spell icon, paged) or **Loot** (item rows).
  Every panel says "Classic reference, unverified on Forever".
- **Portrait states.** Available (plain ring), selected (gold), engaged (red,
  only while the run's encounter is in progress), defeated (gold ring, greyed
  face, a check: killed in this run), unknown (no display ID: a skull). States
  come only from `GW.DungeonSessions`' run in that dungeon.
- **Loot.** Rows with the client's item icon in a quality-coloured frame, the
  quality-coloured name, slot and type, item level, required level, the source
  and the wishlist mark (purple diamond wanted, check acquired). All or
  Wishlist only; click a boss drop for its encounter. Your website wishlist
  (`GW.LootSync`) is read-only here.
- **Tooltips.** Items show the game's own item tooltip (`item:<id>`) with
  the source and wishlist note under it, and Blizzard's comparison while
  shift is held (or always-compare is on; pressing or releasing shift updates
  it). Spells show the game's spell tooltip with the label and the reference
  note. Every tooltip opens just right of and above the cursor, clamped to
  the screen, and goes on mouse leave (this fixes item tooltips that opened
  at the far right edge of the wide rows).
- **Trash & Rares.** Compact rows (rare star or skull, name, count, KICK when
  one of its casts is interruptible) and the same panel, without loot.

### HUD

- **?** button in the HUD header opens the guide.
- Boss faces use the same portrait engine; a face the client's journal gave
  no art for takes the guide's display ID. Hover: the boss's top mechanics
  and wanted drops; click: the guide on that boss.
- Expanded HUD: a "NEXT:" (or "NOW:") line with the next boss's two top
  mechanics. Timer, splits, objectives, boss tracking, PB logic and combat
  collapse are unchanged.

### Combat and performance

- No OnUpdate handlers, no tickers, no tooltip or item scans (item icons come
  from the client's item table, not `GetItemInfo`), no combat log, no
  protected calls, no hooks on Blizzard functions, no reloads.
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

`test/dungeon_guide_spec.lua` (atlas exporter, packaged atlas, lookups,
roles, wishlist, selection, every tab of every dungeon, combat, the HUD) and
`test/dungeon_journal_spec.lua`: the art exporter on an excerpt of the
references (`test/fixtures/journal_refs/`, with their licences), the packaged
art table's integrity, floors, pins and display IDs (never an NPC ID; Sneed
without his Shredder's face), observed encounter states, the default
dungeon, the portrait engine (loading, the shared timer, combat, missing
IDs), the map renderer (tile geometry, floors, pins, missing textures, no
map), encounter frames and panels, item rows, cursor-anchored tooltips and
shift comparison, the picker (search, filters, pick, remembered, Where I am),
the HUD's faces, and that nothing from `references/` (or a glyph the game
font lacks) is shipped.

## In-game checklist (not yet done in the client)

Nothing below has been tried in the WoW client yet.

1. `/console scriptErrors 1`, `/reload`, `/gw guide` outside a dungeon: it
   opens on a dungeon near your level; no Lua errors.
2. Click the dungeon's name: the picker opens; type "dead": only the
   Deadmines; pick Raids, then 50+; clear; pick Ragefire Chasm; `/reload`;
   `/gw guide` reopens on it.
3. Ragefire Chasm, Overview: the map shows the cave (not grey, not black);
   aspect looks right; no pins (expected: no journal positions); the four
   bosses in the list have faces (they may appear a moment after the list).
4. Deadmines, Overview: floor 1 shows the mine with Rhahk'Zor and Sneed
   pinned; the right arrow turns to Ironclad Cove with five pins; each pin
   sits on its boss's spot; hover one (tooltip next to the cursor), click it.
5. Encounters: faces in the list (Sneed shows a skull); VanCleef's panel has a
   large face, "Level 21  Rare elite", Watch for with spell icons; Cookie
   shows KICK; change the role switch: the order changes.
6. Abilities and Loot switches in the panel; loot rows show real item icons,
   quality colours, slot/ilvl/req; Cruel Barb (or any item on your website
   wishlist after a bridge sync and `/reload`) has the purple diamond.
7. Hover an item in the Loot tab at the right side of the window: the tooltip
   opens beside the cursor (not at the screen's right edge) and inside the
   screen; hold shift: Blizzard's comparison appears; release: it goes; move
   away: the tooltip goes.
8. Trash & Rares: Miner Johnson (star), trash rows with counts and KICK;
   the panel shows no loot switch for trash.
9. Inside the Deadmines: "You are here" in the subtitle; pick another dungeon,
   then **Where I am** returns. Kill Rhahk'Zor: his frame turns Defeated (gold
   ring, grey face, check); during Cookie's fight his frame shows In combat.
10. HUD: the ? button; faces show portraits (also Sneed's skull); hover and
    click a face; the timer keeps running.
11. Pull with the guide never opened this session: click a face in combat,
    only a chat line. Open a new dungeon's Overview in combat: "The map draws
    after combat", then it draws. No hitching.
12. `/gw perf`: guide:build, guide:map and guide:refresh are small; loot roll
    alerts, boss tracking and the timer behave as before.
13. Smaller UI scale (Interface options): the window's controls stay
    reachable; no text runs into the icons.

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
