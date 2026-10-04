# Guildweaver

Guildweaver is a guild operating layer for World of Warcraft: Forever. It is being built as a generic addon that guilds can pair with external services for quests, progression, rewards, roster data, and synchronization.

Holdfast is the first guild using Guildweaver, but Guildweaver itself is intentionally guild-agnostic.

## Current milestone

The first milestone establishes a reliable addon foundation:

- WoW Forever Interface 16001
- Lua 5.1-compatible code
- SavedVariables through `GuildweaverDB`
- `/gw` and `/guildweaver` slash commands
- draggable native WoW frame
- persisted frame position
- Lua syntax and lint checks in GitHub Actions

## Commands

- `/gw` toggles the Guildweaver window
- `/gw version` prints the current addon version
- `/gw reset` resets the window position
- `/gw help` prints command help

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
