# Character telemetry contract

Guildweaver SavedVariables schema 4 keeps the existing per-character snapshot mailbox and adds a generic bounded telemetry outbox.

## Existing compatibility mailbox

`GuildweaverDB.characters` stores the latest local character snapshot.

`GuildweaverDB.sync.outbound.characters[characterKey]` contains:

- `revision`
- `updatedAt`
- `fingerprint`
- `payload`

The revision only changes when stable character data changes. Capture timestamps and capture reasons do not create a new revision by themselves.

## Generic telemetry mailbox

`GuildweaverDB.sync.outbound.telemetry[streamKey]` stores the newest unsuperseded snapshot for a telemetry stream. Initial streams use `character_snapshot:<anonymous character id>`.

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

The outbox is bounded and keeps only the latest revision per stream. This is intentionally suitable for state snapshots rather than an unbounded event log.

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

Recipe capture is opportunistic and never opens profession UI on the player's behalf. Previously captured recipe data is retained when later character captures occur outside the profession UI.

## Privacy

Guildweaver does not collect BattleTags, account identifiers, whispers, chat logs, or private messages. Installation and character identifiers are locally generated anonymous ids. The generic telemetry payload does not depend on inspect spam or remote-player inspection.
