-- Test fixture: exactly what guildweaver-bridge writes to Data/BridgeLoot.generated.lua
-- (bridge src/lootSync.js, lootInboxSource). Regenerate it with the bridge when the
-- contract changes; do not edit it by hand.
-- Guildweaver Bridge loot c2b55187c75b0262
local _, GW = ...

GW.BridgeLoot = {
    schemaVersion = 1, digest = "c2b55187c75b0262", revision = 5, generatedAt = 1791322000,
    characters = {
        { id = "guildweaver-id:character-rook", name = "Rook Ravenstar", realm = "Live Realm", region = "US", marketKey = "game:us:live-realm:alliance", aliases = { "character-rook" },
          wishlist = { revision = 3, updatedAt = 1791321000, items = {
            { itemId = 5191, itemKey = "i:5191", priority = "high", note = "Main hand until 30", name = "Cruel Barb", qualityId = 3, source = "The Deadmines" },
            { itemId = 6468, itemKey = "i:6468:s-1081", priority = "low", name = "Deviate Scale Belt", qualityId = 3, source = "Wailing Caverns" },
            { itemId = 6694, itemKey = "i:6694", priority = "normal", note = "Tank \"swap\"\010set", name = "Phantom Shield", qualityId = 3 },
          } } },
        { id = "guildweaver-id:character-fern", name = "Fern", realm = "Live Realm", region = "US", aliases = { "character-fern" },
          wishlist = { revision = 1, updatedAt = 1791320000, items = {
            { itemId = 5193, itemKey = "i:5193", priority = "normal", name = "Cape of the Brotherhood", qualityId = 2 },
          } } },
    },
    boe = { floorCopper = 10000, maxAgeSeconds = 259200, markets = {
        ["game:us:live-realm:alliance"] = { name = "Live Realm Alliance", items = {
            { k = "i:6694", id = 6694, v = 250000, t = 1791321900, c = "medium" },
            { k = "i:6468:s-1081", id = 6468, v = 300000, t = 1791321900, c = "high" },
            { k = "i:2168", id = 2168, v = 60000, t = 1791321900, c = "medium" },
            { k = "i:9999", id = 9999, v = 900000, t = 1790000000, c = "high" },
        } },
    } },
}
