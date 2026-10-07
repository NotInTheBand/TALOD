-- Audit (Audit.lua, AuditUI.lua): statistics read for you and a target,
-- coin text, flags, reviews, guild sharing of the "stats" category.
local scenarios, T = ...
local check, boot, printed = T.check, T.boot, T.printed

local GOLD = 10000
local ICON = { g = "Interface\\MoneyFrame\\UI-GoldIcon:0:0:2:0", s = "Interface\\MoneyFrame\\UI-SilverIcon:0:0:2:0",
    c = "Interface\\MoneyFrame\\UI-CopperIcon:0:0:2:0" }
-- The game's money text for an amount of copper.
local function coins(copper)
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local out = {}
    if g > 0 then out[#out + 1] = g .. "|T" .. ICON.g .. "|t" end
    if s > 0 then out[#out + 1] = s .. "|T" .. ICON.s .. "|t" end
    if c > 0 or #out == 0 then out[#out + 1] = c .. "|T" .. ICON.c .. "|t" end
    return table.concat(out, " ")
end

-- Statistic IDs -> raw values the way the game returns them (strings).
local function statTable(f)
    return {
        [328] = f.acquired and coins(f.acquired), [334] = f.peak and coins(f.peak), [333] = f.looted and coins(f.looted),
        [326] = f.quests and coins(f.quests), [921] = f.vendors and coins(f.vendors), [919] = f.auctions and coins(f.auctions),
        [98] = f.questCount and tostring(f.questCount), [107] = f.kills and tostring(f.kills), [932] = f.dungeons and tostring(f.dungeons),
        [1537] = f.mining and tostring(f.mining),
    }
end

local STATS
local function statsApi()
    STATS = { mine = {}, theirs = {}, sets = 0, clears = 0 }
    GetStatistic = function(id) return STATS.mine[id] end
    GetComparisonStatistic = function(id) return STATS.theirs[id] end
    SetAchievementComparisonUnit = function(unit) STATS.sets = STATS.sets + 1 STATS.unit = unit end
    ClearAchievementComparisonUnit = function() STATS.clears = STATS.clears + 1 end
    CanInspect = function() return true end
end

local function forever(opts)
    statsApi()
    return boot(16001, opts)
end

scenarios.audit_parse = function()
    local ns = forever()
    local A = ns.Audit
    check(A.ParseMoney(coins(123405)) == 123405, "coin icons -> copper")
    check(A.ParseMoney(coins(5)) == 5, "copper only")
    check(A.ParseMoney("1,234|T" .. ICON.g .. "|t") == 12340000, "grouped gold")
    check(A.ParseMoney("12|T" .. ICON.s .. "|t 3|T" .. ICON.g .. "|t") == nil, "silver before gold is not an amount")
    check(A.ParseMoney("150|T" .. ICON.s .. "|t") == nil, "150 silver is not an amount")
    check(A.ParseMoney(4200) == 4200, "a plain number")
    check(A.ParseMoney("1,2345|T" .. ICON.g .. "|t") == nil, "broken grouping is not an amount")
    check(A.ParseMoney("1.234.567|T" .. ICON.g .. "|t") == 12345670000, "dot grouping")
    check(A.ParseMoney("3|A:coin-gold:0:0|a 7|A:coin-copper:0:0|a") == 30007, "atlas coins")
    check(A.ParseMoney("3|TInterface\\Icons\\INV_Misc_Gem:0|t") == nil, "an unknown icon is not a coin")
    check(A.ParseMoney("3|T" .. ICON.g .. "|t extra") == nil, "text after the coins")
    check(A.ParseMoney("") == nil and A.ParseMoney("12") == 12, "empty / digits only")
    check(A.Entry("1,234", false) == 1234, "grouped count")
    check(A.Entry("1.5", false) == nil, "a decimal is not a count")
    local n, display = A.Entry("12 Goldstücke", true)
    check(n == nil and display == "12 Goldstücke", "unknown format: shown, not counted")
    check(A.Entry(MOCK.Secret("5"), false) == nil, "a secret is unknown")
    check(A.Gold(12345678) == "1,234g 56s", "gold text: " .. A.Gold(12345678))
    check(A.Gold(nil) == "?", "unknown gold is ?")
end

scenarios.audit_self = function()
    local ns = forever()
    local A = ns.Audit
    MOCK.money = 42 * GOLD
    STATS.mine = statTable({ acquired = 500 * GOLD, peak = 30 * GOLD, looted = 200 * GOLD, quests = 150 * GOLD, vendors = 100 * GOLD,
        auctions = 40 * GOLD, questCount = 180, kills = 3000, dungeons = 12, mining = 225 })
    MOCK.Tick(6)   -- the login read
    local me = ns.Guild.Me()
    local c = A.Record(me)
    check(c and #c.snaps == 1, "own look saved at login")
    local s = A.Latest(c)
    check(s.src == "self" and s.wallet == 42 * GOLD, "own wallet kept")
    check(A.V(s, "acquired") == 500 * GOLD and A.V(s, "mining") == 225, "counters read")
    check(A.Other(s) == 10 * GOLD, "other sources: " .. tostring(A.Other(s)))
    check(s.miss.fishCaught == "notReported", "a missing counter keeps its reason")
    check(A.Assess(s).key == "active", "active play: " .. A.Assess(s).key)
    -- Unchanged: no second look.
    A.ReadSelf()
    check(#c.snaps == 1, "unchanged look not stored twice")
    STATS.mine[328] = coins(510 * GOLD)
    STATS.mine[333] = coins(210 * GOLD)
    MOCK.now = MOCK.now + 60
    A.ReadSelf()
    check(#c.snaps == 2, "a change is a new look")
    local f = A.FlagsOf(me)
    check(f.level == "none", "played gold: no flags, got " .. f.level .. " " .. f.keys)
end

-- Unknown is never shown as fine.
scenarios.audit_unknown = function()
    local ns = forever()
    local A = ns.Audit
    A.Save({ full = "Ghost-Mockrealm" }, { t = time(), src = "inspect", n = 1, v = { peak = 5 * GOLD }, d = {}, miss = {}, level = 60 })
    local f = A.FlagsOf("Ghost-Mockrealm")
    check(f.level == "unknown", "peak alone: unknown, got " .. f.level)
    check(A.Other(A.Latest(A.Record("Ghost-Mockrealm"))) == nil, "other sources unknown")
end

scenarios.audit_assess = function()
    local ns = forever()
    local A = ns.Audit
    local function look(v) return { v = v } end
    check(A.Assess(look({})).key == "unknown", "nothing readable")
    check(A.Assess(look({ questCount = 0, kills = 0 })).key == "limited", "readable but empty")
    check(A.Assess(look({ questCount = 30, kills = 250 })).key == "active", "two adventuring areas")
    check(A.Assess(look({ dungeons = 5, fishCaught = 60, mining = 80 })).key == "active", "one adventuring area and three in all")
    check(A.Assess(look({ dungeons = 5, kills = 3 })).key == "some", "one adventuring area only")
    check(A.Assess(look({ mining = 150, posted = 40, questCount = 2 })).key == "specialist", "crafter / trader")
    local a = A.Assess(look({ questCount = 3 }))
    check(a.key == "some" and a.positive == 1 and a.meaningful == 0, "some activity counted")
end

scenarios.audit_flags = function()
    local ns = forever()
    local A = ns.Audit
    local who = "Rich-Mockrealm"
    local function look(t, v, level)
        return { t = t, src = "inspect", n = 9, v = v, d = {}, miss = {}, level = level or 20, build = "x" }
    end
    local t0 = time()
    -- Level 20: 300 g acquired, 260 g of it from other sources, peak 280 g.
    A.Save({ full = who }, look(t0, { acquired = 300 * GOLD, peak = 280 * GOLD, looted = 20 * GOLD, quests = 15 * GOLD, vendors = 5 * GOLD,
        auctions = 0, questCount = 40, kills = 400, dungeons = 1 }))
    local f = A.FlagsOf(who)
    check(f.level == "look", "look: " .. f.level)
    check(f.keys:find("other") and f.keys:find("level") and not f.keys:find("gap"), "flags: " .. f.keys)
    -- Reviewed as fine: hidden until something new.
    A.SetReview(who, "ok", "sells boosts")
    f = A.FlagsOf(who)
    check(f.reviewed, "reviewed")
    -- Three days later 400 g more, none of it from the sources; peak above income too.
    A.Save({ full = who }, look(t0 + 3 * 86400, { acquired = 700 * GOLD, peak = 760 * GOLD, looted = 22 * GOLD, quests = 16 * GOLD,
        vendors = 5 * GOLD, auctions = 0, questCount = 41, kills = 420, dungeons = 1 }))
    f = A.FlagsOf(who)
    check(f.keys:find("jump:") and f.keys:find("gap"), "jump and gap: " .. f.keys)
    check(not f.reviewed, "a new flag reopens the review")
    check(A.Record(who).review.note == "sells boosts", "note kept")
    -- A drop in acquired (a reset) is no jump.
    A.Save({ full = "Reset-Mockrealm" }, look(t0, { acquired = 900 * GOLD, peak = 50 * GOLD, looted = 800 * GOLD, quests = 50 * GOLD,
        vendors = 50 * GOLD, auctions = 0 }, 60))
    A.Save({ full = "Reset-Mockrealm" }, look(t0 + 86400, { acquired = 10 * GOLD, peak = 50 * GOLD, looted = 10 * GOLD, quests = 0,
        vendors = 0, auctions = 0 }, 60))
    check(not A.FlagsOf("Reset-Mockrealm").keys:find("jump"), "reset: no jump")
    -- Thresholds come from the settings.
    TALODDB.auditOtherGold = 2000
    TALODDB.auditLevelRule = false
    A.Save({ full = "Mid-Mockrealm" }, look(t0, { acquired = 300 * GOLD, peak = 280 * GOLD, looted = 20 * GOLD, quests = 15 * GOLD,
        vendors = 5 * GOLD, auctions = 0, questCount = 40, kills = 400, dungeons = 1 }))
    check(A.FlagsOf("Mid-Mockrealm").level == "none", "below the thresholds: " .. A.FlagsOf("Mid-Mockrealm").keys)
    -- Gold with play in one area at most: a bank alt, or worth a look.
    A.Save({ full = "Bank-Mockrealm" }, look(t0, { acquired = 300 * GOLD, peak = 280 * GOLD, looted = 20 * GOLD, quests = 15 * GOLD,
        vendors = 5 * GOLD, auctions = 0, questCount = 3, kills = 0, dungeons = 0 }, 60))
    check(A.FlagsOf("Bank-Mockrealm").keys == "thin", "thin: " .. A.FlagsOf("Bank-Mockrealm").keys)
    -- Sort: flagged first, unknown peaks last.
    local rows = A.Sort(A.Rows(), "flags")
    check(rows[1].full == who, "most flagged first: " .. rows[1].full)
end

scenarios.audit_request = function()
    local ns = forever()
    local A = ns.Audit
    MOCK.units.target = MOCK.Friend({ name = "Buddy", guid = "Player-1-00000B0D", level = 30 })
    STATS.theirs = statTable({ acquired = 90 * GOLD, peak = 40 * GOLD, looted = 50 * GOLD, quests = 30 * GOLD, vendors = 9 * GOLD,
        auctions = 0, questCount = 60, kills = 900, dungeons = 3 })
    check(A.Request("target"), "request sent")
    check(STATS.sets == 1 and STATS.unit == "target", "one comparison request")
    check(not A.Request("target") or STATS.sets == 1, "same target while waiting: no second request")
    MOCK.FireEvent("INSPECT_ACHIEVEMENT_READY", "Player-1-00000B0D")
    MOCK.Tick(0.3)
    local c = A.Record("Buddy-Mockrealm")
    check(c and A.Latest(c).src == "inspect" and A.V(A.Latest(c), "acquired") == 90 * GOLD, "inspected look saved")
    check(STATS.clears >= 1, "request released")
    -- 5 s between requests.
    check(not A.Request("target") and A.status:find("Wait"), "spacing: " .. tostring(A.status))
    MOCK.Tick(6)
    -- No answer: times out, never retried.
    check(A.Request("target"), "second request")
    local sets = STATS.sets
    for _ = 1, 70 do MOCK.Tick(0.25) end
    check(A.Pending() == nil and A.status:find("No answer"), "timeout: " .. tostring(A.status))
    check(STATS.sets == sets, "no retry")
    -- Another addon takes the shared request: yield.
    MOCK.Tick(6)
    check(A.Request("target"), "third request")
    SetAchievementComparisonUnit("target")
    check(A.Pending() == nil and A.status:find("Another addon"), "yielded: " .. tostring(A.status))
    -- In combat: nothing sent.
    MOCK.Tick(6)
    MOCK.lockdown = true
    sets = STATS.sets
    check(not A.Request("target") and STATS.sets == sets, "no request in combat")
    MOCK.lockdown = false
    -- Classic Era: no statistics, no requests.
end

scenarios.audit_era = function()
    statsApi()
    local ns = boot(11509)
    check(not ns.Audit.Supported(), "not on Era")
    check(not ns.Audit.Request("player"), "nothing read on Era")
    for _, c in ipairs(ns.GuildSync.CATEGORIES) do check(c.key ~= "stats", "no stats sharing on Era") end
    ns.AuditUI.Show("members")
end

local function guildSetup(rank)
    statsApi()
    local roster = {
        { name = "Boss", rank = 0, level = 60, online = true, classFile = "WARRIOR" },
        { name = "Offi", rank = 1, level = 60, online = true, classFile = "MAGE" },
        { name = "Pal", rank = 3, level = 45, online = true, classFile = "PALADIN" },
        { name = "Tester", rank = rank, level = 20, online = true, classFile = "WARRIOR" },
    }
    local names = { [0] = "Guild Master", [1] = "Officer", [3] = "Member" }
    MOCK.SetGuild({ rankIndex = rank, rankName = names[rank], roster = roster, can = { invite = rank <= 1, promote = rank <= 1 } })
    local ns = boot(16001)
    MOCK.FireEvent("GUILD_ROSTER_UPDATE")
    MOCK.Tick(2.1)
    return ns
end

local function msg(text, sender, dist) MOCK.FireEvent("CHAT_MSG_ADDON", "TALODG", text, dist or "WHISPER", sender) end

scenarios.audit_share_officer = function()
    local ns = guildSetup(1)
    local A = ns.Audit
    local payload = MOCK.now .. ";1.60.1.70124;45;acquired=" .. (900 * GOLD) .. ";peak=" .. (950 * GOLD) .. ";looted=" .. (100 * GOLD)
        .. ";quests=" .. (50 * GOLD) .. ";vendors=" .. (40 * GOLD) .. ";auctions=0;questCount=200;kills=5000;dungeons=20;bogus=7"
    msg("A0~stats", "Pal-Mockrealm")
    msg("A1~stats~" .. payload, "Pal-Mockrealm")
    local c = A.Record("Pal-Mockrealm")
    check(c and A.Latest(c).src == "shared", "shared look saved")
    check(A.V(A.Latest(c), "peak") == 950 * GOLD and A.Latest(c).v.bogus == nil, "known keys only")
    check(c.classFile == "PALADIN", "class from the roster")
    local f = A.FlagsOf("Pal-Mockrealm")
    check(f.keys:find("gap") and f.keys:find("other"), "flags on shared data: " .. f.keys)
    -- Not a member: ignored.
    msg("A0~stats", "Stranger-Mockrealm")
    msg("A1~stats~" .. payload, "Stranger-Mockrealm")
    check(A.Record("Stranger-Mockrealm") == nil, "non-member ignored")
    -- They say No: their shared looks go.
    msg("A0~", "Pal-Mockrealm")
    check(A.Record("Pal-Mockrealm") == nil, "dropped after No")
    -- The window draws every tab.
    msg("A0~stats", "Pal-Mockrealm")
    msg("A1~stats~" .. payload, "Pal-Mockrealm")
    for _, view in ipairs({ "members", "flags", "characters", "ledger", "history" }) do ns.AuditUI.Show(view) end
    A.selected = "Pal-Mockrealm"
    ns.AuditUI.Show("ledger")
    ns.AuditUI.Show("history")
    check(ns.Nav.Page("audit") and ns.AuditUI.IsShown(), "audit page in the navigation")
end

scenarios.audit_share_member = function()
    local ns = guildSetup(3)
    local Sync = ns.GuildSync
    STATS.mine = statTable({ acquired = 77 * GOLD, peak = 30 * GOLD, looted = 40 * GOLD, quests = 30 * GOLD, vendors = 7 * GOLD, auctions = 0 })
    local mark = #MOCK.addonMessages
    msg("Q1", "Offi-Mockrealm", "GUILD")
    for _ = 1, 12 do MOCK.Tick(1.3) end
    for i = mark + 1, #MOCK.addonMessages do
        check(not tostring(MOCK.addonMessages[i][2]):find("stats"), "nothing about stats before a Yes")
    end
    Sync.SetConsent("stats", true)
    MOCK.Tick(61)
    mark = #MOCK.addonMessages
    msg("Q1", "Offi-Mockrealm", "GUILD")
    for _ = 1, 20 do MOCK.Tick(1.3) end
    local found
    for i = mark + 1, #MOCK.addonMessages do
        local m = MOCK.addonMessages[i]
        if tostring(m[2]):find("^A1~stats~") then found = m end
    end
    check(found and found[3] == "WHISPER" and found[4] == "Offi-Mockrealm", "stats whispered to the officer")
    check(found[2]:find("acquired=" .. (77 * GOLD)) and not found[2]:find("wallet"), "counters shared, not the wallet")
end

scenarios.audit_slash = function()
    local ns = forever()
    T.slash("audit status")
    check(printed("statistic IDs checked"), "status printed")
    T.slash("audit me")
    check(ns.AuditUI.IsShown(), "window opened")
    T.slash("audit flags")
    T.slash("irs")
    check(not ns.AuditUI.IsShown(), "toggled closed")
end
