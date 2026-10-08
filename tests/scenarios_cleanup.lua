-- Cleanup (Cleanup.lua): automatic cleanup on for a first install and off
-- after an update, the rules (recruit messages, price history, unseen
-- items, set-aside entries), the daily run one rule per tick out of combat,
-- the memory cap, the Data settings tab and the commands.
local scenarios, T = ...
local check, boot, printed, slash = T.check, T.boot, T.printed, T.slash

local DAY = 86400

local function recruits(ns)
    MOCK.SetGuild()
    local g = ns.Guild.Data()
    local old, now = MOCK.now - 30 * DAY, MOCK.now
    local function opener(t) return { { t = t, me = true, text = "Hey, looking for a guild?" } } end
    g.recruits["Old-Mockrealm"] = { status = "declined", t = old, invited = old, by = "Me-Mockrealm",
        whisper = "Hey, looking for a guild?", echo = "Hey, looking for a guild?", chat = opener(old) }
    g.recruits["Talked-Mockrealm"] = { status = "declined", t = old, invited = old, by = "Me-Mockrealm",
        whisper = "Hey", chat = { { t = old, me = true, text = "Hey" }, { t = old + 5, text = "no thanks" } } }
    g.recruits["Waiting-Mockrealm"] = { status = "uninvited", t = old, invited = old, whisper = "Hey", chat = opener(old) }
    g.recruits["Unread-Mockrealm"] = { status = "invited", t = old, invited = old, whisper = "Hey", unread = 1, chat = opener(old) }
    g.recruits["New-Mockrealm"] = { status = "declined", t = now, invited = now, whisper = "Hey", chat = opener(now) }
    ns.Data.Changed("guild")
    return g
end

scenarios.cleanup_first_install_vs_update = function()
    local ns = boot(11509)
    check(TALODDB.cleanAuto == true, "a first install cleans up automatically")
    check(TALODDB.memoryCapMB == 150 and TALODDB.cleanRecruitTextDays == 14, "defaults")
end

scenarios.cleanup_update_stays_off = function()
    local ns = boot(11509, { db = { journal = {}, store = { v = {} } } })
    check(TALODDB.cleanAuto == false, "an update leaves it off")
    check(ns.Cleanup.rules.recruitText and ns.Cleanup.rules.priceHistory and ns.Cleanup.rules.setAside, "rules registered")
end

scenarios.cleanup_recruit_text = function()
    local ns = boot(11509)
    local g = recruits(ns)
    local rule = ns.Cleanup.rules.recruitText
    check(ns.Cleanup.Preview(rule) == 1, "only the old, settled, unanswered opener: " .. ns.Cleanup.Preview(rule))
    local before = ns.Guild.Recruiters()
    local ok, n = ns.Cleanup.Run(false)
    check(ok and n == 1, "one record stripped")
    local r = g.recruits["Old-Mockrealm"]
    check(r.chat == nil and r.whisper == nil and r.echo == nil, "its text is gone")
    check(r.status == "declined" and r.by == "Me-Mockrealm" and r.invited, "who, when and how it ended stay")
    check(g.recruits["Talked-Mockrealm"].chat[2].text == "no thanks", "a conversation is kept whole")
    check(g.recruits["Waiting-Mockrealm"].whisper, "an opener waiting for its invite keeps its text")
    check(g.recruits["Unread-Mockrealm"].chat, "unread kept")
    check(g.recruits["New-Mockrealm"].chat, "recent kept")
    local after = ns.Guild.Recruiters()
    check(#after == #before, "recruiter stats unchanged")
    local log = ns.Store.CleanLog()
    check(log[#log].id == "recruitText" and log[#log].n == 1 and log[#log].c == 1, "the run is logged with the character")
    check(ns.Cleanup.Preview(rule) == 0, "preview follows the data")
    check(printed("cleanup removed 1 old entry"), "one line in chat")
end

scenarios.cleanup_prices = function()
    local ns = boot(11509)
    TALODDB.auctionPrices = true
    local P = ns.Prices
    local start = MOCK.now
    MOCK.now = start - 200 * DAY
    P.Record(2589, 100, 5, MOCK.now, 1, "Linen Cloth")
    P.RecordLadder(2589, { { 100, 5 } }, false)
    for i = 1, 5 do
        MOCK.now = start - (100 - i) * DAY
        P.Record(2592, 200 + i, 5, MOCK.now, 1, "Wool Cloth")
    end
    MOCK.now = start - DAY
    P.Record(2592, 250, 5, MOCK.now, 1, "Wool Cloth")
    MOCK.now = start
    local realm = TALODDB.prices[P.RealmKey()]
    check(#P.Looks(realm[2592]) == 5, "five earlier looks")
    local hist, unseen = ns.Cleanup.rules.priceHistory, ns.Cleanup.rules.priceUnseen
    check(ns.Cleanup.Preview(hist) == 5 and ns.Cleanup.Preview(unseen) == 1, "previews")
    ns.Cleanup.Run(false)
    check(realm[2592].h == nil and realm[2592].p == 250, "old looks gone, latest kept")
    check(realm[2589] == nil and TALODDB.ladders[P.RealmKey()][2589] == nil, "unseen item and its ladder gone")
end

scenarios.cleanup_auto_run = function()
    -- Off after an update: nothing goes.
    local ns = boot(11509, { db = { store = { v = {} } } })
    local g = recruits(ns)
    for _ = 1, 40 do MOCK.Tick(1) end
    check(g.recruits["Old-Mockrealm"].chat, "automatic cleanup off: kept")
end

-- On: waits for the delay, never runs in combat, one rule per tick.
scenarios.cleanup_auto_run_on = function()
    local ns = boot(11509)
    local g = recruits(ns)
    MOCK.Tick(5)
    check(g.recruits["Old-Mockrealm"].chat, "not right after login")
    MOCK.lockdown = true
    for _ = 1, 40 do MOCK.Tick(1) end
    check(g.recruits["Old-Mockrealm"].chat and ns.Cleanup.Running() == false, "not in combat")
    MOCK.lockdown = false
    MOCK.Tick(1)
    check(ns.Cleanup.Running(), "started after combat")
    for _ = 1, 10 do MOCK.Tick(1) end
    check(not ns.Cleanup.Running() and g.recruits["Old-Mockrealm"].chat == nil, "done")
    check(TALODDB.cleanLast == MOCK.now, "once a day")
end

scenarios.cleanup_memory_cap = function()
    local mb = 40
    UpdateAddOnMemoryUsage = function() end
    GetAddOnMemoryUsage = function() return mb * 1024 end
    local ns = boot(11509, { db = { store = { v = {} } } })
    for _ = 1, 70 do MOCK.Tick(1) end
    check(ns.Cleanup.Memory() == 40 and not printed("over your cap"), "under the cap: quiet")
    mb = 200
    ns.Cleanup.Measure()
    TALODDB.cleanAuto = true
    for _ = 1, 15 * 60 do MOCK.Tick(1) end
    check(printed("over your cap of 150 MB"), "one warning")
    check(TALODDB.cleanLast, "automatic cleanup ran for the cap")
    local warnings = 0
    for _, line in ipairs(MOCK.prints) do if line:find("over your cap") then warnings = warnings + 1 end end
    for _ = 1, 15 * 60 do MOCK.Tick(1) end
    check(warnings == 1, "once per session")
end

scenarios.cleanup_settings_and_commands = function()
    UpdateAddOnMemoryUsage = function() end
    GetAddOnMemoryUsage = function() return 12 * 1024 end
    local ns = boot(11509)
    recruits(ns)
    TALODDB.store.quarantine[1] = { t = MOCK.now - 60 * DAY, key = "x", path = "x", reason = "test" }
    slash("")
    for top = 1, 20 do
        for sub = 1, 3 do ns.Options.SelectTab(top, sub) end
    end
    slash("clean")
    check(printed("Recruit messages: 1 older than 14 days") and printed("Set%-aside entries: 1"), "preview by rule")
    slash("memory")
    check(printed("Memory: 12 MB") and printed("Guild"), "memory and largest stores")
    slash("clean auto off")
    check(TALODDB.cleanAuto == false, "auto off")
    TALODDB.cleanRecruitText = false
    slash("clean now")
    check(#TALODDB.store.quarantine == 0, "set-aside entries removed")
    check(ns.Guild.Data().recruits["Old-Mockrealm"].chat, "a rule turned off removes nothing")
end
