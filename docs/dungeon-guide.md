# Dungeon Guide

The website's Dungeon Atlas, in the game and offline: bosses and their
mechanics, reference loot with your wishlist marked, rares, dangerous trash,
dungeon quests and a spawn layout. Dashboard → **Dungeon Guide**, `/gw guide`,
the **?** button on the dungeon HUD, or a click on a boss face in the HUD.

Everything here is **Classic reference data, unverified on WoW Forever**, and
every panel says so. Nothing is invented: a boss, an ability, an item or a
field the atlas does not have is simply not shown, with an empty state.

## Where the data comes from

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
the spawn layout's 1% grid cells, and provenance lines. Left out: art URLs,
provenance URLs, area triggers, long descriptions, drop chances (none exist).

## Data size and memory

| | |
| --- | --- |
| Packaged file | 437 KB (budget 480 KB, enforced by the exporter and the spec) |
| Lua memory at login | about 840 KB (compiled data; no tables are built) |
| Coverage | 26 dungeons and raids, 240 bosses (203 with reference loot, 176 with abilities, 203 on the layout), 173 dangerous trash, 27 rares, 275 quests (220 with objectives, 199 with rewards), 786 spells (173 interruptible casts), 2,027 items |

At login only a small index exists (names, level bands, encounter and NPC
lookups). Each dungeon's detail, the spell table and the item table are
functions in the file: their tables are built the first time the guide needs
them and cached for the session. Nothing goes to SavedVariables except the
guide's three preferences (tab, role, follow) and the last dungeon picked.

## How it behaves

- **Current dungeon.** The guide follows the instance you are in (by instance
  ID, `GetInstanceInfo`). Picking another dungeon while inside stops following
  until you pick "Where I am" again. The last pick survives `/reload`.
- **Bosses.** Matched by encounter ID first, then NPC ID, then name (case and
  punctuation ignored); a name never overrides a different known encounter ID.
  Each boss shows its 2–4 most important mechanics first, ordered for your role
  (the Any/Tank/Heal/DPS switch, or the group role when the client has one),
  then **All** for the full list. Labels: **KICK** (only a cast the client marks
  interruptible; an interrupt-category spell without that mark says CAST),
  **TANK**, **HEAL**, **DISPEL**, **MOVE**, **CC**, **NOTE**.
- **Portraits.** Only from a creature display ID the add-on already knows
  (`Data/DungeonBosses.lua` or what the HUD read from the client's journal).
- **Loot.** Reference loot by boss, rare and "other" drops, with the item's
  facts. Your website wishlist (`GW.LootSync`, read-only) marks wanted items
  with a purple ◆ and acquired ones with a ✓; wishlist items whose source names
  this dungeon are listed even when the reference list lacks them. Hovering an
  item shows the game's own tooltip with the source and wishlist note under it.
  The wishlist is edited on the website; nothing here writes to it.
- **Rares and trash.** One list (rares ★, then dangerous trash !) with the same
  detail panel.
- **Spawn layout.** The site-drawn picture of every spawn, north up, with boss
  numbers and rare stars; click a marker for its guide. Labelled "not an
  in-game map; floors overlap".

### HUD

- **?** button in the HUD header (compact and expanded) opens the guide.
- Boss faces: hovering adds the boss's top mechanics and wanted drops to the
  tooltip; clicking opens the guide on that boss.
- Expanded HUD: a "NEXT:" (or "NOW:") line with the next boss's two top
  mechanics, under the existing rows. The timer, splits, objectives, boss
  tracking, PB logic and combat collapse are unchanged.

### Combat and performance

- No OnUpdate handlers, no tickers, no tooltip or item scans, no combat log,
  no protected calls, no hooks on Blizzard functions.
- The dashboard view is built on first open. In combat it is never built: the
  ? button and face clicks open it only if it already exists (otherwise a chat
  line says it opens out of combat). Nothing opens by itself.
- In combat the HUD only reads a dungeon already built; it never builds one.
- The layout's dots (up to ~590 textures for the biggest dungeon) are drawn
  only out of combat, once per dungeon, from a reused pool.
- `GW.Perf` records `guide:build`, `guide:layout` and `guide:refresh`
  (`/gw perf`).

## Tests

`test/dungeon_guide_spec.lua` (CI runs it with every spec): exporter
determinism, Lua 5.1 validity and problem detection on a real excerpt
(`test/fixtures/atlas_mini.json`, `reference_loot_mini.json`); the packaged
file's size, memory and integrity (every ability has facts, every interrupt is
interruptible, every loot item has facts, names kept, lookups consistent);
encounter/NPC/name matching; role ordering; wishlist and acquired state;
current-instance detection; selection across `/reload`; every tab of every
dungeon; combat restrictions; the HUD tooltip and click; no item queries,
tooltip scans or OnUpdate handlers while browsing all 26 dungeons.

## In-game checklist (not yet done in the client)

Nothing below has been tried in the WoW client yet.

1. `/reload`, then `/gw guide` outside a dungeon: opens on the last picked (or
   the first) dungeon. No Lua errors (`/console scriptErrors 1`).
2. Dashboard sidebar shows **Dungeon Guide**; the four tabs switch; the
   Dungeon ▾ menu lists bands and dungeons; picking one changes every tab.
3. Enter the Deadmines: the guide (and `/gw guide`) follows it; subtitle says
   "You are here".
4. Bosses tab: VanCleef shows mechanics with labels and the reference note;
   **All** expands; Cookie shows a KICK. Change the role switch: order changes.
5. Loot tab: items show quality colours and facts; hover shows the game's
   tooltip plus "Drops from …"; wishlist items carry ◆ (check one you have on
   the website after a bridge sync and `/reload`); the Wishlist filter works.
6. Overview: the spawn layout draws; boss numbers and the rare star sit on it;
   clicking a number opens that boss.
7. HUD: the **?** button sits left of the +/– buttons and does not overlap the
   title; hover a boss face: mechanics appear; click it: the guide opens on
   that boss; the timer keeps running.
8. Expanded HUD: the NEXT: line shows the next boss's two mechanics.
9. Pull a pack with the guide closed and never opened this session: click a
   face in combat → only a chat line, nothing opens. After combat a click opens it.
10. Open the guide, pull, switch tabs in combat: no hitching; the layout of a
   new dungeon says it draws after combat, and does.
11. `/gw perf`: guide:build / guide:layout / guide:refresh are small; loot
    roll alerts, boss tracking and the timer behave as before.
12. Portraits: a boss with a known display ID shows a face in the detail.

## Needs from the website or bridge later

- **Regenerate after Indicaza/holdfast#297 merges** (and on every atlas change):
  the generated file names its commit.
- **Faction on quests** is used when present; quest `startsInside` and
  locations show only where the atlas has them.
- **Forever-verified data**: when the atlas gains `official-client` or
  `forever-reference` abilities, the guide shows them without the reference
  note (`v=true`); nothing needs to change in the add-on.
- **Display IDs** for boss portraits are not in the atlas; adding
  `displayId` per boss (from the client's CreatureDisplayInfo) would give
  every boss a face.
- **Wishlist edits from the game** would need a bridge protocol change
  (out of scope: the guide is read-only).
