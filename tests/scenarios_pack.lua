-- Packed records: Store's packed values, settled recruit records kept as one
-- string each (every field reads the same through Guild.Recruit, a write makes
-- the record live first, stats and the shared seal unchanged), the text
-- dictionary, the v4 migration, price history as one string.
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
    "invites", "seq", "ack", "guid", "saidNo", "noFrom", "whisper", "echo", "echoT", "unsent", "last", "chat", "ignoring" }
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

-- The shared seal over a fixed window (the seal keeps the window's start
-- with it; here one is given so the clock cannot move between two calls).
local function sealOf(ns)
    local get, keep
    for _, s in ipairs(ns.Store.SEALS) do if s.name == "recruiting" then get, keep = s.get, s.keep end end
    return ns.Store.Digest(get(MOCK.now - keep * DAY))
end

scenarios.pack_recruits = function()
    local ns = boot(11509)
    local G = ns.Guild
    local g = guild(ns)
    local now = MOCK.now
    local function rec(full) return G.Recruit(full) end
    g.recruits["Old-Mockrealm"] = oldRecord(now)
    g.recruits["Second-Mockrealm"] = oldRecord(now, { chat = { { t = now - 9 * DAY, me = true, text = ODD, c = 1 },
        { t = now - 9 * DAY + 3, me = true, text = "follow-up", c = 2 } }, echo = "other", unsent = "x", saidNo = now - 9 * DAY, noFrom = "invited" })
    g.recruits["Third-Mockrealm"] = oldRecord(now, { unsent = "x", status = "invited", ack = true })
    -- A record with a reply is settled too (it is read from its string).
    g.recruits["Answered-Mockrealm"] = oldRecord(now, { chat = { { t = now - 9 * DAY, text = "no thanks" } }, replied = now - 9 * DAY })
    g.recruits["Recent-Mockrealm"] = oldRecord(now, { t = now - DAY })
    g.recruits["Unread-Mockrealm"] = oldRecord(now, { unread = 1 })
    g.recruits["Inviting-Mockrealm"] = oldRecord(now, { status = "inviting" })
    g.recruits["Unknown-Mockrealm"] = oldRecord(now, { future = 1 })
    local before = {}
    for full in pairs(g.recruits) do before[full] = view(rec(full)) end
    local stats = copy(G.BuildRecruiters(g))
    local seal = sealOf(ns)

    check(G.PackAll(g, now) == 4, "four settled records packed")
    local cold = { "Old-Mockrealm", "Second-Mockrealm", "Third-Mockrealm", "Answered-Mockrealm" }
    for _, full in ipairs(cold) do
        check(G.IsCold(full) and g.recruits[full] == nil and type(g.cold[full]) == "string", full .. " is cold")
    end
    for _, full in ipairs({ "Recent-Mockrealm", "Unread-Mockrealm", "Inviting-Mockrealm", "Unknown-Mockrealm" }) do
        check(not G.IsCold(full) and g.recruits[full], full .. " left as it is")
    end
    for full in pairs(before) do
        local ok, why = same(view(rec(full)), before[full])
        check(ok, full .. " reads the same: " .. tostring(why))
    end
    check(same(copy(G.BuildRecruiters(g)), stats), "recruiter stats unchanged")
    check(sealOf(ns) == seal, "shared seal unchanged")
    local cs = G.ColdStats(g)
    check(cs.n == 4 and cs.status.declined == 3 and cs.status.invited == 1 and (cs.unconfirmed or 0) == 0 and cs.sum == 4 * (now - 10 * DAY),
        "cold counts")
    -- Fields read from the string, no decoding.
    check(G.ColdField(g.cold["Second-Mockrealm"], "unsent", g) == "x" and G.ColdField(g.cold["Old-Mockrealm"], "chat", g)[1].text == ODD
        and G.ColdField(g.cold["Old-Mockrealm"], "echo", g) == ODD and G.ColdField(g.cold["Old-Mockrealm"], "zone", g) == "Stormwind City", "ColdField")
    -- The texts that repeat are in the dictionary: who invited, the opener, "x".
    check(#g.dict == 3 and g.cold["Old-Mockrealm"]:match("^[^|]*|[^|]*|[^|]*|(d%d+)|") ~= nil, "dictionary tags: " .. #g.dict)
    check(not g.cold["Old-Mockrealm"]:find("Me-Mockrealm", 1, true), "no copy of the recruiter in the string")

    -- Reading is not changing: the chat list handed out is a decoded copy.
    local s = g.cold["Old-Mockrealm"]
    local r = rec("Old-Mockrealm")
    table.insert(r.chat, { t = now, text = "lost" })
    check(G.IsCold("Old-Mockrealm") and g.cold["Old-Mockrealm"] == s, "in-place change of a read list does not stick")

    -- Any write makes the record live first, with every field.
    r.status = "joined"
    check(not G.IsCold("Old-Mockrealm") and g.recruits["Old-Mockrealm"] and r.status == "joined" and r.zone == "Stormwind City",
        "a write makes the record live")
    local live = rec("Old-Mockrealm")
    check(live == g.recruits["Old-Mockrealm"] and #live.chat == 1 and live.chat[1].text == ODD and live.name == "Jusch Mee",
        "the live record has everything, and not the change to the copy")
    r.zone = "Ironforge"
    check(g.recruits["Old-Mockrealm"].zone == "Ironforge" and r.zone == "Ironforge", "later writes through the same handle land")
    local r2 = rec("Second-Mockrealm")
    r2.whisper = nil
    check(not G.IsCold("Second-Mockrealm") and g.recruits["Second-Mockrealm"].whisper == nil and r2.echo == "other", "a deletion lands")
    check(G.ColdStats(g).n == 2, "counts follow")

    -- Thaw (before a change to the chat list in place) and MakeLive.
    local rt = rec("Third-Mockrealm")
    G.Thaw(rt)
    table.insert(rt.chat, { t = now, me = true, text = "hello", c = 1 })
    check(not G.IsCold("Third-Mockrealm") and #g.recruits["Third-Mockrealm"].chat == 2, "Thaw: the list is changed in place")
    check(G.MakeLive("Answered-Mockrealm") == g.recruits["Answered-Mockrealm"] and not G.IsCold("Answered-Mockrealm")
        and G.MakeLive("Nobody-Mockrealm") == nil, "MakeLive")

    -- Packed again at the next login with what was changed.
    G.PackAll(g, now)
    check(G.IsCold("Old-Mockrealm") and rec("Old-Mockrealm").status == "joined" and rec("Old-Mockrealm").zone == "Ironforge", "packed again")

    -- Forget removes it from both.
    G.Forget("Old-Mockrealm")
    check(rec("Old-Mockrealm") == nil and not G.IsCold("Old-Mockrealm") and g.recruits["Old-Mockrealm"] == nil, "forgotten")
end

scenarios.pack_blocked_and_names = function()
    local ns = boot(11509)
    local G = ns.Guild
    local g = guild(ns)
    local now = MOCK.now
    -- Newest first by t; Blocked reads status and t from the string.
    for i, name in ipairs({ "Aa", "Bb", "Cc", "Dd" }) do
        g.recruits[name .. "-Mockrealm"] = oldRecord(now, { t = now - (10 + i) * DAY, invited = now - (10 + i) * DAY, status = "skipped" })
    end
    g.recruits["Ee-Mockrealm"] = oldRecord(now, { t = now - 4 * DAY, invited = now - 4 * DAY, status = "invited" })
    g.recruits["Gg-Mockrealm"] = oldRecord(now, { t = now - 9 * DAY, invited = now - 9 * DAY, status = "invited" })
    G.PackAll(g, now)
    local names = G.ColdNames()
    check(table.concat(names, ",") == "Ee-Mockrealm,Gg-Mockrealm,Aa-Mockrealm,Bb-Mockrealm,Cc-Mockrealm,Dd-Mockrealm",
        "newest first: " .. table.concat(names, ","))
    check(G.Blocked("Aa-Mockrealm", g) == "skipped", "a skipped cold record stays blocked")
    check(G.Blocked("Ee-Mockrealm", g) == "invited", "a recent invite blocks")
    check(G.Blocked("Gg-Mockrealm", g) == nil, "an invite older than the reinvite days does not block")
    g.recruits["Ff-Mockrealm"] = oldRecord(now, { t = now - 5 * DAY, invited = now - 5 * DAY })
    G.PackAll(g, now)
    names = G.ColdNames()
    check(names[1] == "Ee-Mockrealm" and names[2] == "Ff-Mockrealm" and #names == 7, "the list follows new cold records")
    G.Forget("Ee-Mockrealm")
    check(#G.ColdNames() == 7 and not G.IsCold("Ee-Mockrealm"), "a name forgotten stays in the array; readers skip it")
end

scenarios.pack_reply_and_strip = function()
    local ns = boot(11509)
    local G = ns.Guild
    local g = guild(ns)
    local now = MOCK.now
    g.recruits["Newbie-Mockrealm"] = oldRecord(now, { name = "Newbie" })
    g.recruits["Chatty-Mockrealm"] = oldRecord(now, { name = "Chatty", replied = now - 9 * DAY, last = now - 9 * DAY,
        chat = { { t = now - 9 * DAY, me = true, text = ODD, c = 1 }, { t = now - 9 * DAY + 5, text = "maybe later" } } })
    G.PackAll(g, now)
    check(G.IsCold("Newbie-Mockrealm") and G.IsCold("Chatty-Mockrealm"), "packed")
    -- A cold player who answered is a conversation, read from the string.
    ns.Data.Bump("guild.replies")
    local convos = G.Conversations()
    check(#convos == 1 and convos[1].full == "Chatty-Mockrealm" and convos[1].r.chat[2].text == "maybe later" and convos[1].r.name == "Chatty"
        and G.IsCold("Chatty-Mockrealm"), "a cold conversation is listed without being made live")

    MOCK.FireEvent("CHAT_MSG_WHISPER", "sure, thanks!", "Newbie-Mockrealm")
    local r = G.Recruit("Newbie-Mockrealm")
    check(not G.IsCold("Newbie-Mockrealm") and g.recruits["Newbie-Mockrealm"] == r and #r.chat == 2 and r.chat[2].text == "sure, thanks!"
        and r.chat[1].text == ODD, "a reply makes the record live and is kept")
    check(#G.Conversations() == 2 and G.Unread() == 1, "both are conversations, one unread")
    MOCK.FireEvent("CHAT_MSG_WHISPER", "hi again", "Chatty-Mockrealm")
    check(not G.IsCold("Chatty-Mockrealm") and #G.Recruit("Chatty-Mockrealm").chat == 3, "a second reply is kept too")

    -- The text rule on cold records: blanked in the string, kept cold.
    g.recruits["Quiet-Mockrealm"] = oldRecord(now, { t = now - 30 * DAY, invited = now - 30 * DAY })
    g.recruits["Quiet2-Mockrealm"] = oldRecord(now, { t = now - 30 * DAY, invited = now - 30 * DAY, name = "Quiet2" })
    g.recruits["Waiting-Mockrealm"] = oldRecord(now, { t = now - 30 * DAY, invited = now - 30 * DAY, status = "uninvited" })
    G.PackAll(g, now)
    check(G.IsCold("Quiet-Mockrealm") and G.IsCold("Waiting-Mockrealm") and g.cold["Quiet-Mockrealm"]:find("|d%d+|"), "quiet ones packed with dictionary tags")
    local kept = {}
    check(G.StripOldOpeners(now - 14 * DAY, false) == 2, "preview counts the cold records: " .. G.StripOldOpeners(now - 14 * DAY, false))
    local n = G.StripOldOpeners(now - 14 * DAY, true, function(key, value) kept[key] = value end)
    local q = G.Recruit("Quiet-Mockrealm")
    check(n == 2 and G.IsCold("Quiet-Mockrealm") and q.whisper == nil and q.chat == nil and q.echo == nil and q.unsent == nil
        and q.name == "Jusch Mee" and q.status == "declined", "stripped and still cold")
    local w = G.Recruit("Waiting-Mockrealm")
    check(G.IsCold("Waiting-Mockrealm") and w.whisper == ODD, "an opener sent without the invite is kept")
    local value = kept["Brave Souls-Mockrealm/Quiet-Mockrealm"] or ""
    local f = ns.Store.SplitList(value, ";")
    check(ns.Store.UnpackValue(f[1] or "") == ODD and ns.Store.UnpackValue(f[2] or "") == ODD and (f[4] or ""):find("^s") ~= nil, "the archive holds the real texts: " .. value)
    for i = 1, 5 do check(not (f[i] or ""):find("^d%d+$"), "no dictionary tag in the archive value") end
    check(G.StripOldOpeners(now - 14 * DAY, false) == 0, "nothing left to strip")
end

scenarios.pack_dictionary = function()
    local ns = boot(11509)
    local G = ns.Guild
    local g = guild(ns)
    local now = MOCK.now
    local records = {}
    for i = 1, 3 do
        records[i] = oldRecord(now, { by = "Rec-Mockrealm", whisper = "Hello " .. ODD, echo = "Hello " .. ODD, unsent = "later " .. ODD,
            chat = { { t = now - 10 * DAY, me = true, text = "Hello " .. ODD, c = 1 } } })
        g.recruits["D" .. i .. "-Mockrealm"] = records[i]
    end
    local before = view(records[1])
    G.PackAll(g, now)
    check(#g.dict == 3, "three texts in the dictionary: " .. #g.dict)
    for i = 1, 3 do
        local ok, why = same(view(G.Recruit("D" .. i .. "-Mockrealm")), before)
        check(ok, "round trip " .. i .. ": " .. tostring(why))
    end
    check(G.ColdField(g.cold["D1-Mockrealm"], "by", g) == "Rec-Mockrealm" and G.ColdField(g.cold["D1-Mockrealm"], "unsent", g) == "later " .. ODD,
        "dictionary fields")
    -- A text past the limit is written in the string.
    for i = #g.dict + 1, 200 do g.dict[i] = "filler " .. i end
    local s = G.PackRecruit(oldRecord(now, { whisper = "brand new text", echo = "brand new text" }), g)
    check(#g.dict == 200 and s and s:find("brand new text", 1, true) and G.ColdField(s, "whisper", g) == "brand new text", "over the cap: inline")
    -- PackRecruit adds a text while there is room.
    g.dict = { "a" }
    local s2 = G.PackRecruit(oldRecord(now, { whisper = "fresh" }), g)
    check(#g.dict == 3 and g.dict[3] == "fresh" and G.ColdField(s2, "whisper", g) == "fresh" and not s2:find("fresh", 1, true), "added with room")
    -- A tag whose place is missing reads nil.
    g.dict = {}
    check(G.ColdField(s2, "whisper", g) == nil, "missing dictionary place: nil")
    -- A record with a field the format does not know stays a table.
    check(G.PackRecruit({ status = "invited", future = 1 }, g) == nil, "unknown field: not packed")
end

scenarios.pack_migrate_cold = function()
    local ns = boot(11509)
    local G, St = ns.Guild, ns.Store
    local g = guild(ns)
    local now = MOCK.now
    local t = now - 10 * DAY
    -- A record as guild v3 saved it: hot fields + one string of the rest.
    local OLD = { "name", "race", "zone", "src", "first", "invites", "seq", "ack", "guid", "saidNo", "noFrom", "whisper", "echo", "echoT", "unsent", "last" }
    local src = oldRecord(now, { whisper = "Old " .. ODD, echo = "Old " .. ODD, chat = { { t = t, me = true, text = "Old " .. ODD, c = 1 },
        { t = t + 4, text = "reply; with | odd ~ chars", c = 1 } }, replied = t + 4, last = t + 4, guid = "Player-1-AB" })
    local parts = {}
    for i, k in ipairs(OLD) do parts[i] = k == "echo" and "W" or St.PackValue(src[k]) end
    parts[17] = "#" .. St.PackValue(t) .. ";T;W;" .. St.PackValue(1) .. "~" .. St.PackValue(t + 4) .. ";;"
        .. St.PackValue("reply; with | odd ~ chars") .. ";" .. St.PackValue(1)
    local old = { x = table.concat(parts, "|") }
    for _, k in ipairs({ "status", "t", "invited", "by", "level", "classFile", "replied", "ignoring" }) do old[k] = src[k] end
    g.recruits["Migrated-Mockrealm"] = old
    g.recruits["Migrated2-Mockrealm"] = { x = old.x, status = "invited", t = t, invited = t, by = "Me-Mockrealm" }
    g.recruits["Odd-Mockrealm"] = { x = old.x, status = "invited", t = t, invited = t, by = "Me-Mockrealm", future = 1 }
    g.recruits["Live-Mockrealm"] = oldRecord(now, { t = now - DAY })
    local want = view(src)
    St.Def("guild").migrate[4](TALODDB.guild)
    check(g.recruits["Migrated-Mockrealm"] == nil and type(g.cold["Migrated-Mockrealm"]) == "string", "converted")
    local ok, why = same(view(G.Recruit("Migrated-Mockrealm")), want)
    check(ok, "reads the same: " .. tostring(why))
    check(g.recruits["Odd-Mockrealm"] and g.recruits["Odd-Mockrealm"].x == nil and g.recruits["Odd-Mockrealm"].future == 1
        and g.recruits["Odd-Mockrealm"].chat[2].text == "reply; with | odd ~ chars", "a record with an unknown field is made a plain table")
    check(g.recruits["Live-Mockrealm"] and type(g.dict) == "table" and #g.dict >= 1 and g.cold["Migrated2-Mockrealm"], "plain records stay; dictionary made")
    -- The load check keeps cold strings and the dictionary.
    St.Def("guild").check(TALODDB.guild)
    check(type(g.cold["Migrated-Mockrealm"]) == "string" and #g.dict >= 1, "kept by the load check")
    g.cold["Bad-Mockrealm"] = { 1 }
    g.dict[#g.dict + 1] = 5
    St.Def("guild").check(TALODDB.guild)
    check(g.cold["Bad-Mockrealm"] == nil and g.dict[#g.dict] == "", "a bad cold entry is dropped, a bad dictionary entry blanked")
end

scenarios.pack_short_name = function()
    local ns = boot(11509)
    local G = ns.Guild
    local g = guild(ns)
    local now = MOCK.now
    g.recruits["Far Away-Otherrealm"] = oldRecord(now, { name = "Far Away" })
    g.recruits["Twin-Firstrealm"] = oldRecord(now, { name = "Twin" })
    g.recruits["Twin-Secondrealm"] = oldRecord(now, { name = "Twin" })
    G.PackAll(g, now)
    -- The same answers from the index and from the scan past SHORT_INDEX_MAX records.
    for _, max in ipairs({ 20000, 1 }) do
        G.SetShortIndexMax(max)
        local r, full = G.InvitedRecruit("Far Away")
        check(r and full == "Far Away-Otherrealm" and r.invited and G.IsCold(full), "a cold player found by short name, still cold (" .. max .. ")")
        check(G.InvitedRecruit("Nobody") == nil, "unknown name (" .. max .. ")")
        check(G.InvitedRecruit("Twin") == nil, "two of that name: not guessed (" .. max .. ")")
        check(G.InvitedRecruit("Wins") == nil and G.InvitedRecruit("Away") == nil, "a part of a name is not the name (" .. max .. ")")
    end
    -- A live record of the same short name makes it two (the scan path is still on).
    g.recruits["Far Away-Thirdrealm"] = oldRecord(now, { name = "Far Away", t = now - DAY })
    ns.Data.Bump("guild")
    MOCK.Tick(3)
    check(G.InvitedRecruit("Far Away") == nil, "live and cold of that name: not guessed")
    G.Forget("Far Away-Thirdrealm")
    ns.Data.Bump("guild")
    MOCK.Tick(3)
    local _, again = G.InvitedRecruit("Far Away")
    check(again == "Far Away-Otherrealm", "found again once the other is gone")
    -- Made live by a reply: still found.
    G.MakeLive("Far Away-Otherrealm")
    local _, live = G.InvitedRecruit("Far Away")
    check(live == "Far Away-Otherrealm", "found as a live record")
    G.SetShortIndexMax(20000)
end

-- A cold row of the Invited list answers a left click like a live one: an
-- unconfirmed invite is sent again, and the record becomes live.
scenarios.pack_invited_click = function()
    local ns = boot(11509)
    local G, UI = ns.Guild, ns.GuildUI
    local g = guild(ns)
    local now = MOCK.now
    TALODDB.guildAckSeen = true
    g.recruits["Quiet-Mockrealm"] = oldRecord(now, { status = "invited", ack = false, name = "Quiet" })
    g.recruits["Idle-Mockrealm"] = oldRecord(now, { status = "declined", name = "Idle" })
    G.PackAll(g, now)
    check(G.IsCold("Quiet-Mockrealm") and G.IsCold("Idle-Mockrealm"), "cold")
    ns.Data.Bump("guild")
    UI.Show("invited")
    local list = UI.views.invited.list
    check(UI.views.invited.card.title:GetText():find("1 unconfirmed"), "title counts the cold unconfirmed one: " .. UI.views.invited.card.title:GetText())
    list._height = 200
    list:Draw()
    local function rowOf(full)
        for _, r in ipairs(list.rows) do if r.item and r.item.full == full then return r end end
    end
    local invites = #MOCK.guildInvites
    local idle = rowOf("Idle-Mockrealm")
    check(idle and idle.item.cold, "cold row drawn")
    idle:Fire("OnClick", "LeftButton")
    check(#MOCK.guildInvites == invites and G.IsCold("Idle-Mockrealm"), "a declined row does nothing on a click")
    local row = rowOf("Quiet-Mockrealm")
    check(row and row.item.cold, "unconfirmed cold row drawn")
    row:Fire("OnClick", "LeftButton")
    check(#MOCK.guildInvites == invites + 1 and not G.IsCold("Quiet-Mockrealm") and g.recruits["Quiet-Mockrealm"],
        "one invite sent, the record is live")
    check(g.recruits["Quiet-Mockrealm"].status == "invited" and g.recruits["Quiet-Mockrealm"].zone == "Stormwind City", "with all its fields")
    -- Right-click still forgets.
    rowOf("Idle-Mockrealm"):Fire("OnClick", "RightButton")
    check(not G.IsCold("Idle-Mockrealm") and G.Recruit("Idle-Mockrealm") == nil, "right-click forgets a cold row")
end

scenarios.pack_invited_list = function()
    local ns = boot(11509)
    local G, UI = ns.Guild, ns.GuildUI
    local g = guild(ns)
    local now = MOCK.now
    local CAP = UI.INVITED_COLD_MAX
    for i = 1, CAP + 20 do
        local full = string.format("Cold%04d-Mockrealm", i)
        local r = oldRecord(now, { t = now - (10 * DAY + i), invited = now - (10 * DAY + i), name = string.format("Cold%04d", i) })
        r.whisper, r.echo, r.chat = nil, nil, nil
        g.recruits[full] = r
    end
    g.recruits["Zed Findme-Mockrealm"] = oldRecord(now, { t = now - 40 * DAY, invited = now - 40 * DAY, name = "Zed Findme", status = "joined" })
    g.recruits["Live One-Mockrealm"] = oldRecord(now, { t = now - 60, invited = now - 60, name = "Live One", status = "invited" })
    check(G.PackAll(g, now) == CAP + 21, "packed")
    ns.Data.Bump("guild")
    UI.Show("invited")
    local v = UI.views.invited
    local title = v.card.title:GetText()
    check(title:find("1 joined") and title:find((CAP + 20) .. " declined"), "counts include the cold ones: " .. title)
    local rows = v.list.all
    check(#rows == 1 + CAP, "live rows + the newest " .. CAP .. " cold: " .. #rows)
    local seen = {}
    for _, row in ipairs(rows) do seen[row.full] = row end
    check(seen["Live One-Mockrealm"] and seen["Cold0001-Mockrealm"] and seen[string.format("Cold%04d-Mockrealm", CAP)] and not seen["Zed Findme-Mockrealm"],
        "newest cold rows listed, the oldest not")
    check(seen["Cold0001-Mockrealm"].cold and ns.Style.ReadyRow(seen["Cold0001-Mockrealm"]).text:find("Cold0001"), "a cold row draws from its record")
    check(v:Footer():find("Showing the newest 3,000 of 3,021 older invites", 1, true), "capped: " .. v:Footer():sub(-120))
    -- A search finds a name beyond the cap.
    v.list.searchBox:SetText("zed find")
    v.list.searchBox:Fire("OnTextChanged")
    local found
    for _, row in ipairs(v.list.items) do if row.full == "Zed Findme-Mockrealm" then found = row end end
    check(found and #v.list.items == 1, "the search finds an older invite: " .. #v.list.items)
    v.list.searchBox:SetText("")
    v.list.searchBox:Fire("OnTextChanged")
    check(#v.list.items == 1 + CAP, "search cleared")
    -- A guild that cannot see more than it lists says nothing about a cap.
    G.Forget("Zed Findme-Mockrealm")
    check(not G.IsCold("Zed Findme-Mockrealm"), "forgotten")
end

scenarios.pack_sync_payload = function()
    local ns = boot(11509)
    local G, Sync = ns.Guild, ns.GuildSync
    local g = guild(ns)
    local now = MOCK.now
    g.recruits["Live-Mockrealm"] = oldRecord(now, { t = now - 60, invited = now - 60, status = "invited" })
    g.recruits["Cold1-Mockrealm"] = oldRecord(now, { t = now - 5 * DAY, invited = now - 5 * DAY, status = "joined", replied = now - 4 * DAY })
    g.recruits["Cold2-Mockrealm"] = oldRecord(now, { t = now - 20 * DAY, invited = now - 20 * DAY, status = "declined" })
    g.recruits["Cold3-Mockrealm"] = oldRecord(now, { t = now - 45 * DAY, invited = now - 45 * DAY, status = "declined" })
    local function sorted(text)
        local items = {}
        for item in (text .. ";"):gmatch("(.-);") do if item ~= "" then items[#items + 1] = item end end
        table.sort(items)
        return table.concat(items, ";")
    end
    local before = sorted(Sync.Payload("recruiting"))
    check(before:find("Cold1", 1, true) and before:find("Cold2", 1, true) and not before:find("Cold3", 1, true), "window: " .. before)
    G.PackAll(g, now)
    check(G.IsCold("Cold1-Mockrealm") and G.IsCold("Cold3-Mockrealm") and not G.IsCold("Live-Mockrealm"), "packed")
    local after = Sync.Payload("recruiting")
    check(sorted(after) == before, "the same records are shared once cold: " .. after)
    check(after:find("^Live%-Mockrealm") and after:find("Cold1%-Mockrealm:%d+:joined:1;Cold2"), "live first, then cold newest first: " .. after)
end

scenarios.pack_backfill_makes_live = function()
    local ns = boot(11509)
    local G = ns.Guild
    local g = guild(ns)
    local now = MOCK.now
    g.recruits["Old-Mockrealm"] = oldRecord(now)
    G.PackAll(g, now)
    check(G.IsCold("Old-Mockrealm"), "cold")
    -- A save from before openers were kept at send time holds no cold records; if one does, it is made live first.
    g.chatV = 1
    G.BackfillOpeners(g)
    check(not G.IsCold("Old-Mockrealm") and g.recruits["Old-Mockrealm"] and g.chatV == 2 and next(g.cold) == nil, "made live, then migrated")
    check(G.ColdStats(g).n == 0, "counts follow")
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
