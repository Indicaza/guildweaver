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
