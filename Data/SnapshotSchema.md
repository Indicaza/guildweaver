# Character snapshot contract

Guildweaver persists one current snapshot per character in `GuildweaverDB.characters` and mirrors each snapshot into `GuildweaverDB.sync.outbound.characters` with a monotonically increasing local revision.

Each outbound entry contains:

- `revision`
- `updatedAt`
- `payload`

The payload includes identity, realm, level, race, class, guild rank, specialization, professions with skill levels, equipped item links, addon version, capture reason, and capture timestamp.

The companion bridge should treat SavedVariables as an eventually-consistent mailbox. It should upload outbound entries, remember the last acknowledged revision per character, and never mutate gameplay state.
