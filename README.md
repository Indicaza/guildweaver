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
- draggable native WoW frame
- persisted frame position
- Lua syntax and lint checks in GitHub Actions

## Commands

- `/gw` toggles the Guildweaver window
- `/gw version` prints the current addon version
- `/gw snapshot` captures a diagnostic snapshot; normal synchronization does not require it
- `/gw inventory` rescans your bags and prints the inventory telemetry revision
- `/gw reset` resets the window position
- `/gw help` prints command help

## Synchronization

Guildweaver is designed so players do not need to export data manually. The addon continuously updates its in-memory outbound SavedVariables state as character data changes. When WoW writes SavedVariables to disk, including during `/reload` and logout, the Guildweaver Bridge notices the new revision and sends it to the paired Holdfast service automatically.

## Local development

Clone the repository somewhere convenient, then create a Windows directory junction from the WoW Forever addon directory to the repository.

Example PowerShell command:

```powershell
New-Item -ItemType Junction -Path "C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\Guildweaver" -Target "C:\Users\Zach\Projects\guildweaver\addon"
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

### Corpse loot and public item definitions

`mob_loot` reports one Creature/Vehicle source with only its assigned items from `GetLootSourceInfo` GUID/quantity pairs. Area loot splits the same item stack across sources. Missing or inconsistent assignments, non-item slots, player sources, and object/container loot do not create mob facts. Skinning remains `gathering_loot`; skinned corpses are excluded from later corpse reopens.

Reports retain the source NPC ID, a name only when the exact source GUID was observed as target/mouseover, dungeon instance/difficulty, game build, locale, loot visibility, and map coordinates when available. Coordinates are normalized UI-map **player positions at looting**, not NPC spawn positions. Loot-window quantities describe what was offered, not proof of acquisition. Empty windows and unseen corpses are not zero-drop samples.

A persisted seen cache (1,000 corpses / two hours) prevents duplicate ready/opened events and reopens across reloads. Additional items or larger stacks produce cumulative revisions on the same corpse stream. The collector and website preserve maximum observed quantities rather than adding duplicate party views. No combat-log or chat-log capture is introduced.

`game_item_definition` is a separate envelope-v1 state stream. It scans a bare `item:<id>` reference, without character identity or item-instance links, for public base definitions. Existing rich `item_definition` records remain available to authenticated tools. Both definition streams retry after item-cache load events. Locale is additive envelope metadata; SavedVariables remains schema 4.

Live-client checks after servers return: ordinary corpse; area-loot two NPC types; shared party corpse; reopen/reload; skin a looted corpse; dungeon boss; uncached item; map with unavailable player coordinates. Inspect `/gw telemetry` and sync after a reload/logout.
