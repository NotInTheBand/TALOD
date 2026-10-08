-- Packed records: Store's packed values, settled recruit records kept as
-- one string with a metatable (every field reads the same, a write unpacks
-- first, stats and the shared seal unchanged), price history as one string.
local scenarios, T = ...
local check, boot = T.check, T.boot

local DAY = 86400
local ODD = "100% sure | a;b~c,d:e #1 \\ \"q\""

local function same(a, b, path)
    path = path or "record"
    if type(a) ~= type(b) then return false, path .. ": " .. tostring(a) .. " vs " .. tostring(b) end
    if type(a) ~= "table" then return a == b, path .. ": " .. tostring(a) .. " vs " .. tostring(b) end
    for k, v in pairs(a) do
        local ok, why = same(v, b[k], path .. "." .. tostring(k))
        if not ok then return false, why end
    end
    for k in pairs(b) do if a[k] == nil then return false, path .. "." .. tostring(k) .. " extra" end end
    return true
end

local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

-- A field by field read through the record (metatable included).
local FIELDS = { "status", "t", "invited", "by", "level", "classFile", "replied", "name", "race", "zone", "src", "first",
    "invites", "seq", "ack", "guid", "saidNo", "noFrom", "whisper", "echo", "echoT", "unsent", "last", "chat" }
local function view(r)
    local out = {}
    for _, k in ipairs(FIELDS) do out[k] = copy(r[k]) end
    return out
end

scenarios.pack_values = function()
    local ns = boot(11509)
    local St = ns.Store
    for _, v in ipairs({ ODD, "", 0, -3.25, 1791367309, true, false }) do
        check(St.UnpackValue(St.PackValue(v)) == v, "round trip: " .. tostring(v))
    end
    check(St.PackValue(nil) == "" and St.UnpackValue("") == nil, "nil")
    check(St.PackValue({}) == nil, "a table is not packable")
    local list = St.PackList({ ODD, nil, 5 }, 3, "|")
    local f = St.SplitList(list, "|")
    check(#f == 3 and St.UnpackValue(f[1]) == ODD and f[2] == "" and St.UnpackValue(f[3]) == 5, "list with a hole: " .. list)
end

local function guild(ns)
    MOCK.SetGuild()
    return ns.Guild.Data()
end

local function oldRecord(now, extra)
    local t = now - 10 * DAY
    local r = { status = "declined", t = t, invited = t, by = "Me-Mockrealm", level = 22, classFile = "HUNTER",
        name = "Jusch Mee", race = "Human", zone = "Stormwind City", src = "plate", first = t, invites = 1, seq = 1,
        ack = false, whisper = ODD, echo = ODD, echoT = t, chat = { { t = t, me = true, text = ODD, c = 1 } } }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end

scenarios.pack_recruits = function()
    local ns = boot(11509)
    local G = ns.Guild
    local g = guild(ns)
    local now = MOCK.now
    g.recruits["Old-Mockrealm"] = oldRecord(now)
    g.recruits["Second-Mockrealm"] = oldRecord(now, { chat = { { t = now - 9 * DAY, me = true, text = ODD, c = 1 },
        { t = now - 9 * DAY + 3, me = true, text = "follow-up", c = 2 } }, echo = "other", unsent = "x", saidNo = now - 9 * DAY, noFrom = "invited" })
    g.recruits["Recent-Mockrealm"] = oldRecord(now, { t = now - DAY })
    g.recruits["Answered-Mockrealm"] = oldRecord(now, { chat = { { t = now - 9 * DAY, text = "no thanks" } } })
    g.recruits["Unread-Mockrealm"] = oldRecord(now, { unread = 1 })
    g.recruits["Inviting-Mockrealm"] = oldRecord(now, { status = "inviting" })
    g.recruits["Unknown-Mockrealm"] = oldRecord(now, { future = 1 })
    local before = {}
    for full, r in pairs(g.recruits) do before[full] = view(r) end
    local stats = copy(G.BuildRecruiters(g))
    local sealGet
    for _, s in ipairs(ns.Store.SEALS) do if s.name == "recruiting" then sealGet = s.get end end
    local seal = ns.Store.Digest(sealGet())

    check(G.PackAll(g, now) == 2, "two settled records packed")
    for _, full in ipairs({ "Old-Mockrealm", "Second-Mockrealm" }) do
        local r = g.recruits[full]
        check(G.IsPacked(r) and rawget(r, "name") == nil and type(rawget(r, "x")) == "string", full .. " packed")
    end
    for _, full in ipairs({ "Recent-Mockrealm", "Answered-Mockrealm", "Unread-Mockrealm", "Inviting-Mockrealm", "Unknown-Mockrealm" }) do
        check(not G.IsPacked(g.recruits[full]), full .. " left as it is")
    end
    for full, r in pairs(g.recruits) do
        local ok, why = same(view(r), before[full])
        check(ok, full .. " reads the same: " .. tostring(why))
    end
    check(same(copy(G.BuildRecruiters(g)), stats), "recruiter stats unchanged")
    check(ns.Store.Digest(sealGet()) == seal, "shared seal unchanged")

    -- The chat list handed out is a copy: changing it in place changes nothing.
    local r = g.recruits["Old-Mockrealm"]
    table.insert(r.chat, { t = now, text = "lost" })
    check(#r.chat == 1 and G.IsPacked(r), "in-place change of a read copy does not stick")

    -- A write to a packed field unpacks first; a hot field stays packed.
    r.status = "joined"
    check(G.IsPacked(r) and r.status == "joined" and r.zone == "Stormwind City", "hot field written in place")
    r.zone = "Ironforge"
    check(not G.IsPacked(r) and rawget(r, "zone") == "Ironforge" and r.name == "Jusch Mee" and r.chat[1].text == ODD,
        "a packed field unpacks the record")
    local r2 = g.recruits["Second-Mockrealm"]
    r2.whisper = nil
    check(not G.IsPacked(r2) and r2.whisper == nil and r2.echo == "other", "a deletion lands")

    -- What the game saves (raw fields only) reads back the same after login.
    G.PackAll(g, now)
    r = g.recruits["Old-Mockrealm"]
    local saved = {}
    for k, v in pairs(r) do saved[k] = v end     -- pairs sees the raw fields, as the game's writer does
    check(saved.x and saved.zone == nil, "saved packed")
    local loaded = G.Attach(saved)
    check(same(view(loaded), view(r)), "saved and loaded record reads the same")
end

scenarios.pack_reply_and_strip = function()
    local ns = boot(11509)
    local G = ns.Guild
    local g = guild(ns)
    local now = MOCK.now
    g.recruits["Newbie-Mockrealm"] = oldRecord(now, { name = "Newbie" })
    G.PackAll(g, now)
    check(G.IsPacked(g.recruits["Newbie-Mockrealm"]), "packed")
    MOCK.FireEvent("CHAT_MSG_WHISPER", "sure, thanks!", "Newbie-Mockrealm")
    local r = g.recruits["Newbie-Mockrealm"]
    check(not G.IsPacked(r) and #r.chat == 2 and r.chat[2].text == "sure, thanks!" and r.chat[1].text == ODD,
        "a reply unpacks the record and is kept")
    check(#G.Conversations() == 1, "it is a conversation")

    -- The text rule on a packed record: stripped and packed again.
    g.recruits["Quiet-Mockrealm"] = oldRecord(now, { t = now - 30 * DAY, invited = now - 30 * DAY })
    G.PackAll(g, now)
    local q = g.recruits["Quiet-Mockrealm"]
    check(G.IsPacked(q), "quiet one packed")
    local n = G.StripOldOpeners(now - 14 * DAY, true)
    q = g.recruits["Quiet-Mockrealm"]
    check(n == 1 and G.IsPacked(q) and q.whisper == nil and q.chat == nil and q.name == "Jusch Mee", "stripped and still packed")
end

scenarios.pack_price_history = function()
    local ns = boot(11509)
    TALODDB.auctionPrices = true
    local P = ns.Prices
    local start = MOCK.now
    for i = 1, 35 do
        MOCK.now = start + i * 3600
        P.Record(2589, 100 + i, 5, MOCK.now, i % 2 == 0 and 1 or nil, "Linen Cloth")
    end
    local e = TALODDB.prices[P.RealmKey()][2589]
    check(type(e.h) == "string", "history is one string")
    local looks = P.Looks(e)
    check(#looks == 30 and looks[30].p == 134 and looks[1].p == 105, "30 looks kept, oldest dropped: " .. #looks)
    check(P.History(2589)[1].t and #P.History(2589) == 31, "History reads it with the current look")
    -- Old saved tables are read too, and migrated.
    e.h = { { start, 50, 5, 1, 1 }, { start + 1, 60, 5, 1, 1, 1 } }
    check(#P.Looks(e) == 2 and P.Looks(e)[2].b == 1, "old table form still read")
    ns.Store.Def("prices").migrate[3](TALODDB.prices)
    check(type(e.h) == "string" and #P.Looks(e) == 2 and P.Looks(e)[1].p == 50, "migrated to a string")
end

scenarios.pack_guild_events = function()
    local ns = boot(11509)
    local G = ns.Guild
    local g = guild(ns)
    local now = MOCK.now
    g.events = { { t = now - 400 * DAY, k = "invite", a = "Al-Mockrealm", b = "Bo|b;~-Mockrealm" },
        { t = now - 10 * DAY, k = "join", a = "Bo|b;~-Mockrealm" }, { t = now - DAY, k = "promote", a = "Al-Mockrealm", b = "Bo|b;~-Mockrealm", rank = "Veteran" } }
    local before = {}
    for i, e in G.Events(g) do before[i] = copy(e) end
    ns.Store.Def("guild").migrate[3](TALODDB.guild)
    check(type(g.events[1]) == "string" and type(g.events[3]) == "string", "packed: " .. tostring(g.events[1]))
    for i, e in G.Events(g) do check(same(e, before[i]), "event " .. i .. " reads the same") end
    check(G.EventTime(g.events[2]) == now - 10 * DAY, "time read from the string")
    -- The load check keeps packed entries.
    ns.Store.Def("guild").check(TALODDB.guild)
    check(#g.events == 3, "kept by the load check")
    -- The age rule: the oldest goes, and the log no longer claims to reach back.
    g.eventsSince = now - 400 * DAY
    check(G.DropOldEvents(now - 360 * DAY, false) == 1, "preview")
    check(G.DropOldEvents(now - 360 * DAY, true) == 1 and #g.events == 2 and g.eventsSince == now - 360 * DAY, "dropped, since moved")
end
