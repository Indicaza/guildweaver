local _, GW = ...

GW.MockData = GW.MockData or {}

GW.MockData.Quests = {
    {
        id = "plant-the-flag",
        campaign = "Welcome to Azeroth",
        title = "Plant the Flag",
        description = "Help secure the guild name at launch by gathering founders, charter signatures, and the silver needed to establish Holdfast.",
        priority = "Gold",
        status = "active",
        rewards = {
            { type = "rep", label = "Rep", amount = 75 },
            { type = "marks", label = "Marks", amount = 20 },
        },
        objectives = {
            {
                id = "charter-signatures",
                title = "Gather charter signatures",
                description = "Meet in Stormwind and help gather the first ten charter signatures.",
                progress = { current = 7, target = 10, label = "Signatures" },
                assignment = { status = "available", members = { "Rook", "Quill" } },
            },
            {
                id = "founder-silver",
                title = "Bring founder silver",
                description = "Contribute toward the first guild registration and tabard costs.",
                progress = { current = 62, target = 100, label = "Silver" },
                assignment = { status = "assigned", me = true, members = { "Rook" } },
            },
            {
                id = "stormwind-rally",
                title = "Rally in Stormwind",
                description = "Meet the founding group in Stormwind when the charter is ready.",
                assignment = { status = "available", members = {} },
            },
        },
    },
    {
        id = "linen-drive",
        campaign = "Gathering",
        title = "The Linen Drive",
        description = "Stock the first guild bags and tailoring pipeline so new members can get out of six-slot misery quickly.",
        priority = "Blue",
        status = "active",
        rewards = {
            { type = "rep", label = "Rep", amount = 40 },
            { type = "marks", label = "Marks", amount = 10 },
        },
        objectives = {
            {
                id = "linen-cloth",
                title = "Gather Linen Cloth",
                description = "Bring linen to the guild tailoring pool.",
                progress = { current = 83, target = 120, label = "Linen" },
                assignment = { status = "available", members = { "Finch", "Bran" } },
            },
        },
    },
    {
        id = "copper-reserve",
        campaign = "Gathering",
        title = "Copper Reserve",
        description = "Build a shared copper reserve for blacksmithing, engineering, and early equipment crafts.",
        priority = "Green",
        status = "active",
        rewards = {
            { type = "rep", label = "Rep", amount = 30 },
            { type = "marks", label = "Marks", amount = 8 },
        },
        objectives = {
            {
                id = "copper-bars",
                title = "Smelt Copper Bars",
                description = "Deposit smelted copper for guild crafting work.",
                progress = { current = 28, target = 60, label = "Bars" },
                assignment = { status = "assigned", me = true, members = { "Rook", "Bran" } },
            },
        },
    },
    {
        id = "first-company",
        campaign = "Welcome to Azeroth",
        title = "First Company",
        description = "The first dungeon groups formed, cleared their objectives, and brought the results home.",
        priority = "Gold",
        status = "complete",
        rewards = {
            { type = "rep", label = "Rep", amount = 50 },
        },
        objectives = {
            {
                id = "first-dungeon",
                title = "Complete a guild dungeon",
                description = "Finish a dungeon with fellow guild members.",
                progress = { current = 1, target = 1, label = "Dungeon" },
                assignment = { status = "complete", me = true, members = { "Rook", "Quill" } },
            },
        },
    },
}
