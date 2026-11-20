# Third-party data and licences

| What | Files | Terms |
| --- | --- | --- |
| ForeverDB.net's data: reference drop rates, its players' loot records, item facts it supplies | `Data/ForeverDB.generated.lua` only | **GPL-3.0 with ForeverDB.net's attribution term** (`ForeverDB-COPYING.txt`, `ForeverDB-LICENSE.txt`, unchanged from ForeverDB's add-on; `ForeverDB-NOTICE.txt` says which data is its own). Data from ForeverDB.net (https://foreverdb.net) |
| World of Warcraft: Forever game data (item, map and encounter facts, via Holdfast) | `Data/DungeonAtlas.generated.lua`, `Data/DungeonJournalArt.generated.lua`, `Data/DungeonQuests.generated.lua` | Blizzard Entertainment's. World of Warcraft is a trademark of Blizzard Entertainment, Inc.; Guildweaver is not affiliated with or endorsed by Blizzard |
| Classic reference data (AzerothCore world database, DungeonPlanner lists), via Holdfast | `Data/DungeonAtlas.generated.lua`, `Data/DungeonQuests.generated.lua` | AzerothCore: GPL-2.0 (https://github.com/azerothcore/azerothcore-wotlk). See Holdfast's docs/dungeon-atlas-sources.md |

`Data/ForeverDB.generated.lua` keeps ForeverDB's notice line as its first
line, as its attribution term asks. The add-on's code only reads it: the
guide applies it over the atlas when it is loaded, and works without it
(remove the file from `Guildweaver.toc` and the journal shows the data
built without ForeverDB). `/gw credits` lists these credits in game.
