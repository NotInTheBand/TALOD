-- Archive (Archive.lua + the TALOD_Archive load-on-demand addon): rules move
-- old entries there instead of deleting them, only into a loaded archive;
-- the automatic run waits for a batch; a click loads it; archived prices
-- come back in price history; commands and the settings page.
local scenarios, T = ...
local check, boot, printed, slash = T.check, T.boot, T.printed, T.slash

local DAY = 86400

-- The game's addon calls for an installed (or missing) archive addon.
local function archiveAddon(installed, saved)
    local state = { loaded = false, loads = 0 }
    C_AddOns = C_AddOns or {}
    C_AddOns.GetAddOnInfo = function(name)
        if name ~= "TALOD_Archive" then error("unknown addon") end
        if not installed then return name, name, "", false, "MISSING" end
        return name, name, "", true, "DEMAND_LOADED"
    end
    C_AddOns.IsAddOnLoaded = function(name) return name == "TALOD_Archive" and state.loaded end
    C_AddOns.LoadAddOn = function(name)
        if name ~= "TALOD_Archive" or not installed then return false, "MISSING" end
        state.loaded, state.loads = true, state.loads + 1
        TALODArchiveDB = saved
        return true
    end
    return state
end

local function oldRecruit(g, full, now, days)
    local t = now - days * DAY
    g.recruits[full] = { status = "declined", t = t, invited = t, by = "Me-Mockrealm", name = full:match("^[^-]+"),
        whisper = "Hey, join us?", chat = { { t = t, me = true, text = "Hey, join us?", c = 1 } } }
end

scenarios.archive_missing_deletes = function()
    archiveAddon(false)
    local ns = boot(11509)
    check(ns.Archive.State() == "missing" and not ns.Cleanup.Archiving(), "no archive addon: rules delete")
    check(ns.Archive.StateText():find("not installed"), "said so")
    check(not ns.Archive.Load(), "cannot load")
end

scenarios.archive_waits_then_moves = function()
    local addon = archiveAddon(true)
    local ns = boot(11509)
    MOCK.SetGuild()
    local g = ns.Guild.Data()
    local now = MOCK.now
    oldRecruit(g, "Quiet-Mockrealm", now, 30)
    TALODDB.store.quarantine[1] = { t = now - 60 * DAY, key = "x", path = "x", reason = "test" }
    ns.Data.Changed("guild")
    check(ns.Archive.State() == "unloaded" and ns.Cleanup.Archiving(), "installed, not loaded")
    check(ns.Cleanup.Waiting() == 1, "one entry waits")

    -- The automatic run: below the batch, the archive is not loaded and nothing it would keep is deleted.
    for _ = 1, 45 do MOCK.Tick(1) end
    check(addon.loads == 0 and g.recruits["Quiet-Mockrealm"].whisper, "kept, archive not loaded")
    check(#TALODDB.store.quarantine == 0, "a rule the archive does not keep still ran")
    check(printed("wait for the archive"), "said what waits")

    -- A click: loaded, moved.
    local ok, n = ns.Cleanup.Run(false)
    check(ok and n == 1 and addon.loads == 1, "loaded on the click and moved")
    local r = g.recruits["Quiet-Mockrealm"]
    check(r.whisper == nil and r.chat == nil and r.by == "Me-Mockrealm", "text left the save file")
    check(ns.Archive.Count("recruitText") == 1 and ns.Cleanup.Waiting() == 0, "in the archive")
    local _, e = ns.Archive.Entries("recruitText")()
    check(e.key == ns.Guild.Key() .. "/Quiet-Mockrealm" and e.c == 1 and e.t == MOCK.now, "key, character, time")
    local f = ns.Store.SplitList(e.value, ";")
    check(ns.Store.UnpackValue(f[1]) == "Hey, join us?" and ns.Store.UnpackValue(f[4]):sub(1, 1) == "#", "whisper and chat kept")
    check(type(TALODArchiveDB.stores.recruitText[1]) == "string", "one string per entry")
    local log = ns.Store.CleanLog()
    check(log[#log].archived, "the run is logged as archived")
end

scenarios.archive_batch_loads = function()
    local addon = archiveAddon(true)
    local ns = boot(11509)
    MOCK.SetGuild()
    local g = ns.Guild.Data()
    for i = 1, 2000 do oldRecruit(g, "R" .. i .. "-Mockrealm", MOCK.now, 30) end
    ns.Data.Changed("guild")
    for _ = 1, 45 do MOCK.Tick(1) end
    check(addon.loads == 1 and ns.Archive.Count("recruitText") == 2000, "a full batch: loaded and moved")
    check(g.recruits["R1-Mockrealm"].whisper == nil, "gone from the save file")
end

scenarios.archive_prices_come_back = function()
    archiveAddon(true)
    local ns = boot(11509)
    TALODDB.auctionPrices = true
    local P = ns.Prices
    local start = MOCK.now
    for i = 1, 4 do
        MOCK.now = start - (100 - i) * DAY
        P.Record(2592, 200 + i, 5, MOCK.now, 1, "Wool Cloth")
    end
    MOCK.now = start - 300 * DAY
    P.Record(2589, 77, 5, MOCK.now, 1, "Linen Cloth")
    MOCK.now = start - DAY
    P.Record(2592, 250, 5, MOCK.now, 1, "Wool Cloth")
    MOCK.now = start
    check(#P.History(2592) == 5, "five looks before")
    TALODDB.cleanArchive = true
    ns.Cleanup.Run(false)
    local e = P.Entry(2592)
    check(e.h == nil and P.Entry(2589) == nil, "old looks and the unseen item left the save file")
    check(ns.Archive.Count("priceHistory") == 1 and ns.Archive.Count("priceUnseen") == 1, "archived")
    local h = P.History(2592)
    check(#h == 5 and h[1].p == 201 and h[5].p == 250, "history reads the archive while it is loaded: " .. #h)
    local old = P.History(2589)
    check(#old == 1 and old[1].p == 77, "an item gone from the save file still has its history")
    check(#P.History(2592, "days") >= 2, "daily view too")
end

scenarios.archive_guild_events = function()
    archiveAddon(true)
    local ns = boot(11509)
    MOCK.SetGuild()
    local g = ns.Guild.Data()
    local now = MOCK.now
    g.events = { ns.Guild.PackEvent({ t = now - 400 * DAY, k = "join", a = "Old-Mockrealm" }),
        ns.Guild.PackEvent({ t = now - DAY, k = "join", a = "New-Mockrealm" }) }
    ns.Archive.Load()
    local n = ns.Guild.DropOldEvents(now - 360 * DAY, true, function(k, v) ns.Archive.Put("guildEvents", k, v) end)
    check(n == 1 and #g.events == 1, "dropped")
    local _, e = ns.Archive.Entries("guildEvents")()
    check(ns.Guild.Event(e.value).a == "Old-Mockrealm", "the event string archived as it was")
end

scenarios.archive_commands_and_page = function()
    archiveAddon(true, { v = 1, stores = { recruitText = { "n1|n1|sKey|sValue" } } })
    local ns = boot(11509)
    slash("archive")
    check(printed("installed, not loaded"), "status")
    slash("archive load")
    check(ns.Archive.Loaded() and ns.Archive.Total() == 1 and printed("1 entries"), "loaded what was saved")
    check(#ns.Archive.Lookup("recruitText", "Key") == 1, "lookup by key")
    slash("archive move")
    slash("")
    for top = 1, 20 do
        for sub = 1, 3 do ns.Options.SelectTab(top, sub) end
    end
    check(ns.Archive.Clear() == 1 and ns.Archive.Total() == 0, "cleared")
end
