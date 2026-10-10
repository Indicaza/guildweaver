# Character telemetry contract

Guildweaver SavedVariables schema 4 sends character data as one telemetry stream per data type through a bounded telemetry outbox.

## Local character snapshot

`GuildweaverDB.characters` stores the latest local character snapshot, which the telemetry domains read from. It is not sent as a whole: the per-character `sync.outbound.characters` mailbox and the `character_snapshot` stream were removed, and are cleared on load. `GuildweaverDB.meta.characterFingerprints[characterKey]` records the snapshot's stable data, so capture timestamps and reasons alone do not count as a change.

## Generic telemetry mailbox

`GuildweaverDB.sync.outbound.telemetry[streamKey]` stores the newest unsuperseded snapshot for a telemetry stream, keyed `<eventType>:<anonymous character id>` (for example `character:`, `stats:`, `equipment:`, `talents:`, `professions:`, `profession_snapshot:`, `inventory_snapshot:`).

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

## Profession payload (`profession_snapshot`)

Stream key `profession_snapshot:<anonymous character id>`, payload schema 1, emitted by `Telemetry/Domains/Professions.lua` from `Data/ProfessionTelemetry.lua`. It is versioned and fingerprinted independently of the character snapshot, so it only gets a new revision when profession data changes.

`payload.professions[]`:

- `skillLineId`, `name`, `skillLineName`, `kind` (primary, secondary, cooking, fishing, first_aid, archaeology), `iconFileDataId`
- `skillLevel`, `maxSkillLevel`, `skillModifier`, `specializationIndex`, `specialization` (`configId`, `name`, `treeIds`)
- `recipeBook` (`source`, `capturedAt`, `recipeCount`, `knownCount`) and `recipes[]` once that profession's window has been opened

`recipes[]` fields, as exposed by the client: `recipeId`/`spellId`, `name`, `iconFileDataId`, `recipeLink`, `known`, `craftable`, `difficulty` (optimal, medium, easy, trivial), `relativeDifficulty`, `skillUps`, `maxTrivialLevel`, `unlockedRecipeLevel`, `skillLineAbilityId`, `categoryId`, `trainingPointCost`/`requiredLevel` (Classic crafts), `description`, `tools[]`, `cooldown` (`readyAt` rounded to the minute, `isDayCooldown`, `charges`, `maxCharges`), `crafted` (shared item description plus `minQuantity`/`maxQuantity`; tooltip only for known recipes) and `reagents[]` (shared item description without tooltip, plus `quantity`, `required`, `slotIndex`, `currencyId`).

Recipe books come from `C_TradeSkillUI`, the legacy trade skill API, or the Classic craft frame (`legacy_craft`). The last book per profession is cached in `GuildweaverDB.professionTelemetry[characterKey]`; its `capturedAt` only moves when the recipes change. When the profession API is unavailable (logout teardown), the cached state is published unchanged rather than cleared.

## Privacy

Guildweaver does not collect BattleTags, account identifiers, whispers, chat logs, or private messages. Installation and character identifiers are locally generated anonymous ids. The generic telemetry payload does not depend on inspect spam or remote-player inspection.
