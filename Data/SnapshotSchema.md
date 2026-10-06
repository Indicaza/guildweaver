# Character telemetry contract

Guildweaver SavedVariables schema 4 keeps the existing per-character snapshot mailbox and adds generic state and event telemetry outboxes.

## Existing compatibility mailbox

`GuildweaverDB.characters` stores the latest local character snapshot.

`GuildweaverDB.sync.outbound.characters[characterKey]` contains:

- `revision`
- `updatedAt`
- `fingerprint`
- `payload`

The revision only changes when stable character data changes. Capture timestamps and capture reasons do not create a new revision by themselves.

## Generic telemetry state mailbox

`GuildweaverDB.sync.outbound.telemetry[streamKey]` stores the newest unsuperseded snapshot for a telemetry stream.

Current state streams include:

- `character_snapshot:<anonymous character id>`
- `profession_snapshot:<anonymous character id>`
- `recipe_catalog_snapshot:<anonymous character id>:<profession key>`
- `inventory_snapshot:<anonymous character id>`

Each record contains:

- `revision`
- `updatedAt`
- `fingerprint`
- `envelope`

Envelope schema 1 contains:

- `schemaVersion`
- `eventType`
- `capturedAt`
- `gameBuild`
- `realm`
- `region`
- `installationId`
- `characterId`
- optional `guildId`
- `payload`

The state outbox is bounded and keeps only the latest revision per stream.

## Generic telemetry event queue

High-volume observations must not use latest-state semantics. `GuildweaverDB.sync.outbound.events` is a separate bounded queue for append-only observations such as loot, gathering, crafts, recipe discoveries, vendors, and future AH samples.

The queue contains:

- monotonic `nextSequence`
- cumulative `dropped` count
- `items[eventId]`

Each event record contains:

- record `schemaVersion`
- stable `eventId`
- monotonic `sequence`
- `createdAt`
- the same generic envelope schema used by state telemetry

The queue retains the newest 512 events. When offline long enough to exceed the bound, the oldest observation is dropped and `dropped` increments. Event ids are stable across bridge retries, allowing server-side idempotency even if bridge state is lost.

`GW.TelemetryEvents.Queue(eventType, payload)` is the collector-facing API. Domain collectors should enqueue observations through it rather than writing SavedVariables directly.

## Loot observations

`loot_observation` records the contents of an observed loot window rather than claiming every visible item was actually acquired. One observation contains:

- capture reason/time
- zone, subzone, map id and normalized map coordinates when exposed
- instance context when exposed
- current target GUID metadata when available
- every visible loot slot with item id/link, icon, name, quantity, quality, currency id and quest flags
- the source GUID/quantity pairs returned for each loot slot, including parsed GUID type and object id when the standard GUID shape exposes it

`LOOT_READY` and `LOOT_OPENED` are both feature-detected. Equivalent windows observed within two seconds are deduplicated so clients that fire both events do not double-count the same drop table.

This event is the foundation for rare-drop and gathering-yield analysis. Server-side analysis should treat it as an observation of a loot result, not proof that a player clicked every item.

## Carried inventory state

`inventory_snapshot` records the current character's carried bags using modern `C_Container` APIs when available and legacy container APIs as a fallback.

The payload includes:

- per-bag slot/used/free counts
- item id/link, icon and quality
- aggregate quantity and stack count per item
- aggregate bound vs unbound quantities when the client exposes binding state

The collector intentionally excludes gold, bank contents, mail and Auction House state. Bag changes are fingerprinted as latest state, so repeated unchanged captures do not create new revisions.

## Character payload

Character payload schema 2 includes:

- anonymous character id
- name, realm, region, race, class, body type/sex, level
- game build and addon version
- guild name/rank when available
- active specialization
- active talent/trait config, trees, nodes, entries, ranks, spell/definition ids, icons, positions, conditions, visible edges, and point currencies when exposed by the client
- professions, skill values, modifiers, profession specialization config ids/tree ids
- recipe snapshots collected opportunistically while the profession UI exposes them
- every equipped slot with item id/link, quality, item level, icon, parsed enchant/gem/bonus/link modifier data, and safely cached item metadata

## Profession and recipe payloads

`profession_snapshot` is independently collected with explicit profession slots instead of iterating the potentially sparse return values from `GetProfessions()`. It records primary and secondary profession names, skill/max skill, modifiers, specialization metadata, recipe scan freshness, and recipe counts.

`recipe_catalog_snapshot` is emitted per profession whenever the character collector has a recipe catalog available. It carries the profession skill state plus the retained recipe list, crafted item ids, icons, and reagent metadata already exposed by the character collector.

Recipe capture is opportunistic and never opens profession UI on the player's behalf. Previously captured recipe data is retained when later character captures occur outside the profession UI.

`/gw telemetry` prints a compact local coverage summary including event queue occupancy/drop count so missing data can be distinguished from transport or offline-backlog problems.

## Privacy

Guildweaver does not collect BattleTags, account identifiers, whispers, chat logs, or private messages. Installation and character identifiers are locally generated anonymous ids. The generic telemetry payload does not depend on inspect spam or remote-player inspection.
