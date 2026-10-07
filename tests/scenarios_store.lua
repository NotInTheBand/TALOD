-- Save-file handler (Store.lua): characters, tags on account-wide logs,
-- migrations, checks + quarantine, the tamper seal, and what officers do
-- with what members send (GuildSync checks, Audit's "claim" flag).
local scenarios, T = ...
local check, boot, printed, slash = T.check, T.boot, T.printed, T.slash

local DAY = 86400

scenarios.store_chars_and_tags = function()
    local ns = boot(11509)
    local St = ns.Store
    check(St.Me() == 1 and St.CharName(1) == "Tester-Mockrealm", "you are character 1")
    local info = TALODDB.chars.info[1]
    check(info.level == 20 and info.faction == "Alliance" and info.realm == "Mockrealm", "what the registry knows")
    check(St.CharId("Alt-Mockrealm", true) == 2 and St.CharId("Alt-Mockrealm") == 2, "a second character")

    -- Account-wide logs name the character that gathered them.
    T.plateAdd("nameplate1", MOCK.Enemy({ level = 24 }))
    check(TALODDB.journal[1].c == 1, "journal row")
    local rec = TALODDB.players.Shadowfang
    check(rec.pc and rec.pc[1] and rec.pc[1].s == 1 and rec.seen == 1, "player counts per character and for the account")
    slash("kos Shadowfang")
    check(rec.listBy == 1, "who put them on the list")
    TALODDB.auctionPrices = true
    local e = ns.Prices.Record(2589, 100, 5, MOCK.now, 1, "Linen Cloth")
    check(e and e.c == 1, "price look")
    MOCK.now = MOCK.now + 3600
    e = ns.Prices.Record(2589, 90, 5, MOCK.now, 1, "Linen Cloth")
    check(e.h[1][5] == 1 and ns.Prices.History(2589)[1].c == 1, "price history keeps who looked")
    local l = ns.Prices.RecordLadder(2589, { { 90, 5 } }, false)
    check(l.c == 1, "ladder")

    -- The report: account totals and each character.
    local report
    for _, row in ipairs(St.Report()) do if row.def.key == "journal" then report = row end end
    check(report.total == 1 and report.chars[1] == 1, "journal by character")
    St.ReportText()
    slash("data")
    check(St.Def("census") and St.Def("census").scope == "account", "store definitions")
end

scenarios.store_migration = function()
    local t0 = 1700000000
    local ns = boot(11509, { db = {
        gear = { ["Alt-Mockrealm"] = { snapshots = {}, ledger = {} } },
        guildMyNames = { ["Tester-Mockrealm"] = "Tester-Mockrealm" },
        fishing = {
            casts = { t0 + 100 .. ",1429,420,650,c,100,0,0,20,6291:1,Crystal Lake",
                t0 + 9000 .. ",1429,420,650,c,100,0,0,20,6291:1,Crystal Lake" },
            threats = { { t = t0 + 200, m = 1429, k = "N" } },
            sessions = { { start = t0, last = t0 + 300, char = "Alt-Mockrealm", n = 1, c = 1 } },
        },
        audit = { chars = { ["Tester-Mockrealm"] = { own = true, snaps = {
            { t = t0, src = "self", v = { acquired = 5 }, n = 1 },
            { t = t0 + 10, src = "inspect", v = { acquired = 5 }, n = 1 } } } } },
    } })
    local St = ns.Store
    local alt = St.CharId("Alt-Mockrealm")
    check(alt ~= nil, "per-character stores register their characters")
    local f = TALODDB.fishing
    check(f.casts[1]:match(",(%d+)$") == tostring(alt), "a cast inside a session names its character: " .. f.casts[1])
    check(ns.Fishing.ParseCast(f.casts[1]).c == alt, "parsed")
    check(select(2, f.casts[2]:gsub(",", ",")) == 10, "a cast outside every session stays unknown: " .. f.casts[2])
    check(f.threats[1].c == alt, "threat")
    local snaps = TALODDB.audit.chars["Tester-Mockrealm"].snaps
    check(snaps[1].by == St.Me() and snaps[2].by == nil, "your own looks are yours; an old inspect stays unknown")
    check(TALODDB.store.v.fishing == 2 and TALODDB.store.v.journal == 2, "versions recorded")
end

scenarios.store_quarantine = function()
    local ns = boot(11509, { db = {
        journal = { { t = 1700000000, key = "Good" }, "garbage", { key = "NoTime" } },
        guildActivity = { ["Tester-Mockrealm"] = { ["2026-10-01"] = 3600, ["2026-10-02"] = 90000, ["yesterday"] = 60 } },
        prices = { ["Mockrealm-Alliance"] = { [2589] = { p = 5, t = 1700000000 }, [2592] = "cheap" } },
        guildShare = { activity = true, prof = "yes please" },
    } })
    check(#TALODDB.journal == 1 and TALODDB.journal[1].key == "Good", "bad sightings set aside, order kept")
    local days = TALODDB.guildActivity["Tester-Mockrealm"]
    check(days["2026-10-01"] == 3600 and days["2026-10-02"] == nil and days.yesterday == nil, "a day longer than a day is dropped")
    check(TALODDB.prices["Mockrealm-Alliance"][2592] == nil and TALODDB.prices["Mockrealm-Alliance"][2589], "bad price dropped")
    check(TALODDB.guildShare.prof == nil and TALODDB.guildShare.activity == true, "consent is a yes or a no")
    local q = TALODDB.store.quarantine
    check(#q == 6, "six entries kept aside, got " .. #q)
    check(q[1].path == "journal[2]" and q[1].value == "garbage", "path and value kept: " .. tostring(q[1].path))
    check(printed("6 unreadable saved entries were set aside"), "said once")
    slash("data")
    slash("data clear")
    check(#TALODDB.store.quarantine == 0, "cleared")
end

scenarios.store_seal = function()
    BNGetInfo = function() return 1, "Tester#1234" end
    local ns = boot(11509, { db = { guildActivity = { ["Tester-Mockrealm"] = { ["2026-10-01"] = 3600 } } } })
    local St = ns.Store
    check(St.SealState("activity") == "new", "never sealed: new")
    MOCK.FireEvent("PLAYER_LOGOUT")
    local seal = TALODDB.store.seals.activity
    check(seal and seal.bt == true and type(seal.h) == "string" and #seal.h == 16, "sealed at logout with the BattleTag")
    check(not tostring(TALODDB.store.seals.activity.h):find("Tester"), "the BattleTag itself is not saved")

    -- Next login, nothing changed: ok.
    St.Load()
    local state, since = St.SealState("activity")
    check(state == "ok" and since, "unchanged: " .. tostring(state))

    -- Edited by hand: edited, and it stays so across logouts.
    MOCK.FireEvent("PLAYER_LOGOUT")
    TALODDB.guildActivity["Tester-Mockrealm"]["2026-10-01"] = 36000
    St.Load()
    check(St.SealState("activity") == "edited" and TALODDB.store.edited.activity, "hand edit seen")
    MOCK.FireEvent("PLAYER_LOGOUT")
    St.Load()
    check(St.SealState("activity") == "edited", "the mark stays after a logout")
    -- Deleting the mark breaks the seal again.
    MOCK.FireEvent("PLAYER_LOGOUT")
    TALODDB.store.edited.activity = nil
    St.Load()
    check(St.SealState("activity") == "edited", "deleting the mark does not clear it")
    -- After its days the mark goes.
    TALODDB.store.edited.activity.t = MOCK.now - 70 * DAY
    MOCK.FireEvent("PLAYER_LOGOUT")
    St.Load()
    check(St.SealState("activity") == "ok" and TALODDB.store.edited.activity == nil, "mark expired: " .. tostring(St.SealState("activity")))

    -- The file on another account (another BattleTag): edited.
    MOCK.FireEvent("PLAYER_LOGOUT")
    BNGetInfo = function() return 1, "Someone#999" end
    St.Load()
    check(St.SealState("activity") == "edited", "another account's file")

    -- No BattleTag at login: waits, then says unknown (never ok).
    TALODDB.store.edited = {}
    BNGetInfo = function() return 1, "Tester#1234" end
    MOCK.FireEvent("PLAYER_LOGOUT")
    BNGetInfo = function() return 1, nil end
    St.Load()
    for _ = 1, 4 do MOCK.Tick(20) end
    check(St.SealState("activity") == "unknown", "no BattleTag: unknown, got " .. tostring(St.SealState("activity")))
    -- A seal of an older format is "new", never "edited".
    TALODDB.store.seals.prof.v = 0
    St.Load()
    check(St.SealState("prof") == "new", "older seal format: " .. tostring(St.SealState("prof")))
end

-- An officer receives a member's data: checked, never trusted.
scenarios.store_guild_checks = function()
    MOCK.SetGuild({ rankIndex = 1, rankName = "Officer", can = { invite = true, promote = true }, roster = {
        { name = "Boss", rank = 0, level = 60, online = true, classFile = "WARRIOR" },
        { name = "Pal", rank = 3, level = 30, online = true, classFile = "PALADIN" },
        { name = "Newbie", rank = 4, level = 12, online = true, classFile = "MAGE" },
        { name = "Tester", rank = 1, level = 20, online = true, classFile = "WARRIOR" },
    } })
    local now = MOCK.now
    MOCK.guildEvents = { { "invite", "Pal", "Newbie", nil, 0, 0, 1, 0 }, { "join", "Newbie", nil, nil, 0, 0, 1, 0 } }
    local ns = boot(11509)
    MOCK.FireEvent("GUILD_ROSTER_UPDATE")
    MOCK.Tick(2.1)
    local g = ns.Guild.Data()
    ns.Guild.ReadEventLog()
    g.eventsSince = now - 20 * DAY
    local function msg(text) MOCK.FireEvent("CHAT_MSG_ADDON", "TALODG", text, "WHISPER", "Pal-Mockrealm") end
    msg("A0~recruiting,alts,prof,activity")
    msg("A1~prof~70;Mining:300:300;Cooking:75:150")
    msg("A1~activity~200.0:150.0:3")
    msg("A1~recruiting~Newbie-Mockrealm:" .. (now - DAY) .. ":joined:1;Ghost-Mockrealm:" .. (now - 2 * DAY) .. ":joined:0;Late-Mockrealm:" .. (now + 9999) .. ":invited:0")
    msg("A1~alts~Boss-Mockrealm;Nobody-Mockrealm")
    msg("A2~recruiting=ok:" .. (now - 30 * DAY) .. ",activity=edited:" .. (now - 30 * DAY) .. ",prof=new:0,bogus=ok:1")
    local d = g.shared["Pal-Mockrealm"]
    check(d.prof.level == nil, "level 70 is not a level: dropped")
    check(#d.prof.skills == 1 and d.prof.skills[1].name == "Cooking", "Mining 300 needs level 35, the roster says 30: dropped")
    check(d.activity == nil and d.bad.activity, "impossible play time dropped")
    check(#d.recruiting == 2, "a recruit invited in the future dropped")
    local byName = {}
    for _, r in ipairs(d.recruiting) do byName[r.full] = r end
    check(byName["Newbie-Mockrealm"].check == "seen", "joined: in the guild log")
    check(byName["Ghost-Mockrealm"].check == "missing", "joined: not in the guild log")
    check(#d.alts == 1 and d.alts[1] == "Boss-Mockrealm", "an alt not in the guild dropped")
    check(d.seal.activity.state == "edited" and d.seal.prof.state == "new" and d.seal.bogus == nil, "seal states kept")
    -- Seal starts over: noted.
    msg("A2~recruiting=ok:" .. now .. ",activity=edited:" .. (now - 30 * DAY))
    check(d.seal.recruiting.restarted, "a restarted seal is noted")
    ns.GuildUI.Show("members")
    check(ns.GuildUI.IsShown(), "members tab draws")
end

scenarios.store_guild_member_sends_seals = function()
    MOCK.SetGuild({ rankIndex = 3, rankName = "Member", can = {}, roster = {
        { name = "Offi", rank = 1, level = 60, online = true, classFile = "MAGE" },
        { name = "Tester", rank = 3, level = 20, online = true, classFile = "WARRIOR" },
    } })
    local ns = boot(11509)
    MOCK.FireEvent("GUILD_ROSTER_UPDATE")
    MOCK.Tick(2.1)
    for _, c in ipairs(ns.GuildSync.CATEGORIES) do ns.GuildSync.SetConsent(c.key, true) end
    local mark = #MOCK.addonMessages
    MOCK.FireEvent("CHAT_MSG_ADDON", "TALODG", "Q1", "GUILD", "Offi-Mockrealm")
    for _ = 1, 12 do MOCK.Tick(1.3) end
    local a2
    for i = mark + 1, #MOCK.addonMessages do
        local m = MOCK.addonMessages[i]
        if tostring(m[2]):find("^A2~") then a2 = m end
    end
    check(a2 and a2[3] == "WHISPER" and a2[4] == "Offi-Mockrealm", "seals go to the officer who asked")
    check(a2[2]:find("recruiting=new:0") and a2[2]:find("activity=new:0") and a2[2]:find("prof=new:0") and not a2[2]:find("alts="),
        "each sealed category: " .. tostring(a2 and a2[2]))
end

-- Audit: a shared figure the server contradicts.
scenarios.store_audit_claim = function()
    local ns = boot(11509)
    local A = ns.Audit
    local G = 10000
    local function look(t, src, acquired, build)
        return { t = t, src = src, build = build or "1.60.1.70124", v = { acquired = acquired, peak = 10 * G }, d = {}, miss = {}, n = 2 }
    end
    local info = { full = "Pal-Mockrealm", classFile = "PALADIN", level = 45 }
    A.Save(info, look(MOCK.now - 3 * DAY, "shared", 900 * G))
    A.Save(info, look(MOCK.now - DAY, "inspect", 100 * G))
    local c = A.Record("Pal-Mockrealm")
    check(c.snaps[1].by == ns.Store.Me(), "who received it")
    local x = A.Contradictions(c)
    check(#x == 1 and x[1].key == "acquired", "contradiction found")
    local f = A.Flags(c)
    check(f.keys:find("claim:"), "claim flag: " .. tostring(f.keys))
    -- Another build (a reset may come with it), or the server agreeing: nothing.
    local d = A.Record("Pal-Mockrealm")
    d.snaps[2].build = "1.61.0.1"
    check(#A.Contradictions(d) == 0, "different builds are not compared")
    d.snaps[2].build = "1.60.1.70124"
    d.snaps[2].v.acquired = 950 * G
    check(#A.Contradictions(d) == 0, "the server shows more later: fine")
end
