-- Speed work that must not change results: the seal checksum and text,
-- packed values, sorting by text keys, the seal digested over frames, a
-- warm-up that gives up on data that never holds still, list rows that make
-- their parts on first use.
local scenarios, T = ...
local check, boot = T.check, T.boot

-- The checksum one byte at a time, as it was first written.
local function SlowHash(s, h1, h2)
    local M1, M2 = 4294967291, 4294967279
    h1, h2 = h1 or 2166136261, h2 or 1540483477
    for i = 1, #s do
        local b = s:byte(i)
        h1 = (h1 * 257 + b + 1) % M1
        h2 = (h2 * 263 + b * 7 + 3) % M2
    end
    return h1, h2
end

local function RandomText(n)
    local out = {}
    for i = 1, n do out[i] = string.char(math.random(0, 255)) end
    return table.concat(out)
end

scenarios.perf_hash_and_serialize = function()
    local ns = boot(11509)
    local St = ns.Store
    math.randomseed(7)
    for _, n in ipairs({ 0, 1, 7, 8, 9, 15, 16, 17, 63, 64, 65, 1000, 4099 }) do
        local s = RandomText(n)
        local a1, a2 = St.Hash(s)
        local b1, b2 = SlowHash(s)
        check(a1 == b1 and a2 == b2, "same checksum, " .. n .. " bytes")
        -- Near the top of both lanes (every product must stay exact).
        local c1, c2 = St.Hash(string.rep("\255", n), 4294967290, 4294967278)
        local d1, d2 = SlowHash(string.rep("\255", n), 4294967290, 4294967278)
        check(c1 == d1 and c2 == d2, "same checksum at the top, " .. n .. " bytes")
        -- In pieces, as the background digest hashes it.
        local cut = math.floor(n / 3)
        local p1, p2 = St.Hash(s:sub(1, cut))
        p1, p2 = St.Hash(s:sub(cut + 1), p1, p2)
        check(p1 == b1 and p2 == b2, "same checksum in pieces, " .. n .. " bytes")
    end
    -- The text a seal is taken over: whole numbers, big ones, keys of every kind.
    local v = { 1791467751, 99999999999999, 100000000000000, -5, 0, 2.5, [true] = "x", alpha = { 3, 2, 1 }, [10] = false }
    check(St.Serialize(v) == "{1=1791467751;2=99999999999999;3=100000000000000;4=-5;5=0;6=2.5000;10=F;5:alpha={1=3;2=2;3=1;};T=1:x;}",
        "serialized text: " .. St.Serialize(v))
end

scenarios.perf_sort_by = function()
    local ns = boot(11509)
    local U = ns.Utils
    math.randomseed(11)
    local items = {}
    for i = 1, 400 do
        local v = math.random(1, 9) == 1 and nil or (math.random(-5000, 5000) + (math.random(0, 3) / 4))
        items[i] = { v = v, name = string.char(65 + math.random(0, 5)), i = i }
    end
    local expected = {}
    for i, x in ipairs(items) do expected[i] = x end
    table.sort(expected, function(a, b)
        local x, y = a.v or -1e12, b.v or -1e12
        if x ~= y then return x > y end
        if a.name ~= b.name then return a.name < b.name end
        return a.i < b.i
    end)
    local got = {}
    for i, x in ipairs(items) do got[i] = x end
    U.SortBy(got, function(x) return U.NumKey(x.v, true) .. x.name end)
    for i = 1, #got do check(got[i] == expected[i], "same order at " .. i) end
    check(U.NumKey(1e13) == U.NumKey(1e12) and U.NumKey(-1e13) < U.NumKey(-5), "clamped, still ordered")
end

-- The recruiting seal is digested over the frames after login; a seal state
-- asked for before it is done finishes it then. Either way the same as at once.
scenarios.perf_seal_in_background = function()
    BNGetInfo = function() return 1, "Tester#1234" end
    local recruits = {}
    for i = 1, 3000 do
        recruits["Recruit" .. i .. "-Mockrealm"] = { status = "invited", t = 1700000000 + i, invited = 1700000000 + i,
            by = "Tester-Mockrealm", level = 10 + i % 50, classFile = "MAGE" }
    end
    local ns = boot(11509, { db = { guild = { guilds = { ["Brave Souls-Mockrealm"] = { recruits = recruits, members = {}, log = {}, events = {} } } } } })
    MOCK.SetGuild()
    local St = ns.Store
    local sealGet
    for _, s in ipairs(St.SEALS) do if s.name == "recruiting" then sealGet = s.get end end
    check(#St.Serialize(sealGet()) > 65536, "big enough to be digested in pieces")
    MOCK.FireEvent("PLAYER_LOGOUT")
    -- Next login, nothing changed: ok, asked for at once.
    St.Load()
    check(St.SealState("recruiting") == "ok", "unchanged: " .. tostring(St.SealState("recruiting")))
    -- And after the frames did it.
    MOCK.FireEvent("PLAYER_LOGOUT")
    St.Load()
    for _ = 1, 50 do MOCK.Tick(0.02) end
    check(St.SealState("recruiting") == "ok", "unchanged, digested over frames")
    -- An edit made while the game was closed is still seen.
    MOCK.FireEvent("PLAYER_LOGOUT")
    local g = TALODDB.guild.guilds["Brave Souls-Mockrealm"]
    rawset(g.recruits["Recruit5-Mockrealm"], "by", "Someone-Mockrealm")
    St.Load()
    check(St.SealState("recruiting") == "edited", "edit seen: " .. tostring(St.SealState("recruiting")))
    -- A logout right after login still marks it before sealing again.
    MOCK.FireEvent("PLAYER_LOGOUT")
    St.Load()
    check(TALODDB.store.edited.recruiting ~= nil, "the mark stays")
end

-- A warm-up whose data changes under it every time gives up instead of
-- running (and making garbage) forever.
scenarios.perf_warm_gives_up = function()
    local ns = boot(11509)
    local D = ns.Data
    local runs = 0
    D.Source("test.busy")
    local UI = { IsShown = function() return false end, Refresh = function() end }
    D.Window(UI, { "test.busy" }, { warm = function()
        runs = runs + 1
        D.Changed("test.busy")          -- the data moves on while it works
        coroutine.yield()
    end })
    for _ = 1, 60 do MOCK.Tick(0.25) end
    check(runs <= 4 and runs >= 1, "gave up after a few tries: " .. runs)
    check(not D.Busy(), "nothing left running")
end

-- List rows make the accent, icon, bar, label and columns when a row first
-- shows one, and hide them for rows that do not.
scenarios.perf_list_parts = function()
    local ns = boot(11509)
    local parent = CreateFrame("Frame")
    parent:SetSize(400, 300)
    local list = ns.Style.List(parent, { labelWidth = 60, colWidths = { 50, 50 } })
    list:SetItems({ { text = "plain" } })
    local r = list.rows[1]
    check(r.icon == nil and r.barBg == nil and r.accent == nil and r.cols[1] == nil, "a plain row makes nothing extra")
    list:SetItems({ { text = "full", label = "L", icon = 134400, bar = { 1, 2 }, accent = { 1, 0, 0, 1 }, cols = { "a", "b" } } })
    check(r.icon and r.icon:IsShown() and r.barBg:IsShown() and r.accent:IsShown() and r.cols[1]:IsShown() and r.cols[2]:IsShown()
        and r.label:IsShown(), "made and shown when needed")
    check(r.cols[1]:GetText() == "a" and r.text:GetText() == "full", "texts set")
    list:SetItems({ { text = "plain again" } })
    check(not r.icon:IsShown() and not r.barBg:IsShown() and not r.accent:IsShown() and not r.cols[1]:IsShown(),
        "hidden again for a plain row")
end
