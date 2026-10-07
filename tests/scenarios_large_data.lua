-- Large data (Data.lua: sources, Data.List, Data.Window, Data.Memo, Data.Coalesce):
-- windows over thousands of entries format only the rows on screen, keep
-- their lists until the data changes, and redraw at most once a second
-- from data events.
local scenarios, T = ...
local check, boot = T.check, T.boot

-- Rows a list has formatted so far (a lazy row loses `build` when drawn).
local function built(list)
    local n = 0
    for _, item in ipairs(list.all) do if not item.build then n = n + 1 end end
    return n
end

local function counted(v)
    local base, n = v.Refresh, { 0 }
    v.Refresh = function(self) n[1] = n[1] + 1 return base(self) end
    return n
end

scenarios.large_data_helpers = function()
    local ns = boot(11509)
    -- Memo: same value while the key holds, rebuilt when it changes or ages out.
    local builds = 0
    local function get(key, age) return ns.Data.Memo("test:x", key, function() builds = builds + 1 return {} end, age) end
    local a = get("k1")
    check(get("k1") == a and builds == 1, "memo kept for the same key")
    check(get("k2") ~= a and builds == 2, "memo rebuilt on a new key")
    local b = get("k2", 10)
    MOCK.Tick(11)
    check(get("k2", 10) ~= b and builds == 3, "memo rebuilt after maxAge")
    ns.Data.Forget("test:")
    get("k2")
    check(builds == 4, "ForgetMemo drops it")

    -- Coalesce: the first call runs now, a burst folds into one more.
    local runs = 0
    local soon = ns.Data.Coalesce(function() runs = runs + 1 end, 1)
    soon()
    check(runs == 1, "first call runs at once")
    for _ = 1, 20 do soon() end
    check(runs == 1, "a burst waits")
    MOCK.RunTimers()
    check(runs == 2, "the burst runs once: " .. runs)
    MOCK.Tick(2)
    soon()
    check(runs == 3, "after the gap a call runs at once")

    -- Lazy rows: built when drawn or searched, never twice.
    local made = 0
    local row = ns.Data.Row(function(n) made = made + 1 return { text = "row " .. n } end, 7, { time = 1 })
    check(row.time == 1 and row.text == nil, "lazy row waits")
    ns.Style.ReadyRow(row)
    ns.Style.ReadyRow(row)
    check(row.text == "row 7" and made == 1, "built once")
end

-- Sources: versions, watchers, signatures; windows redraw per source at
-- most once a second; the shared bag read follows bag events.
scenarios.large_data_sources = function()
    local ns = boot(11509)
    local D = ns.Data
    local told = 0
    D.Watch("test", function() told = told + 1 end)
    local k0 = D.Key("test")
    D.Bump("test")
    check(told == 0 and D.Key("test") ~= k0, "Bump: new key, nobody told")
    D.Notify("test")
    D.Changed("test")
    check(told == 2 and D.Version("test") == 2, "Notify and Changed tell the watchers")
    local sig = "a"
    D.Source("test", { sig = function() return sig end })
    local k1 = D.Key("test")
    sig = "b"
    check(D.Key("test") ~= k1, "the signature catches unannounced writes")

    -- A window: per-source coalescing, skipped while hidden or not shown.
    local shown, draws = true, 0
    local W = { IsShown = function() return shown end, Refresh = function() draws = draws + 1 end }
    D.Window(W, { "busy", "rare" }, { shows = function(src) return src ~= "hidden" end })
    D.Changed("busy")
    D.Changed("busy")
    check(draws == 1, "a busy source waits: " .. draws)
    D.Changed("rare")
    check(draws == 2, "a rare source is not held back by a busy one: " .. draws)
    MOCK.RunTimers()
    check(draws == 3, "the busy source's second change lands once: " .. draws)
    shown = false
    MOCK.Tick(2)
    D.Changed("rare")
    check(draws == 3, "closed windows are not redrawn")

    -- Bags: one shared read, new after a bag event.
    local bags = D.Bags()
    check(D.Bags() == bags, "bag read shared")
    MOCK.FireEvent("BAG_UPDATE_DELAYED")
    check(D.Bags() ~= bags, "a bag event reads again")
end

-- The character window's growing logs (ledger, sources, skills, crafts),
-- the Auction desk's plans and Fishing's goal tally follow their sources.
scenarios.large_data_more = function()
    local ns = boot(11509)
    local D = ns.Data
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3)
    local now = time()
    local c = ns.Gear.Char()
    check(c, "gear data")
    c.ledger, c.acquired = {}, {}
    local link = "|cffffffff|Hitem:2589::::::::|h[Linen Cloth]|h|r"
    for i = 1, 1000 do
        c.ledger[i] = { t = now - (1000 - i) * 60, kind = "equip", level = 20, changes = { { slot = 1, new = link } }, delta = { 1 } }
        c.acquired[i] = { t = now - i, link = link }
    end
    D.Changed("gear")
    ns.GearUI.Show("ledger")
    local lv = ns.GearUI.views.ledger
    check(lv.card.title:GetText():find("1000 entries"), "ledger count")
    check(built(lv.list) < #lv.list.all, "ledger item rows wait: " .. built(lv.list) .. " of " .. #lv.list.all)
    local rows = lv.list.all
    ns.GearUI.Refresh()
    check(lv.list.all == rows, "ledger kept")
    c.ledger[#c.ledger + 1] = { t = now, kind = "level", level = 21 }
    D.Changed("gear")
    ns.GearUI.Refresh()
    check(lv.list.all ~= rows, "ledger rebuilt on a gear change")
    ns.GearUI.Show("sources")
    check(#ns.GearUI.views.sources.list.all == 1000 and built(ns.GearUI.views.sources.list) <= 40, "sources lazy")
    for _, view in ipairs({ "skills", "crafting", "professions", "enhance", "snapshots", "progress" }) do
        if ns.GearUI.views[view] then ns.GearUI.Show(view) end
    end

    -- Auction desk: plans and lists kept until prices change.
    local Desk, Pr = ns.AuctionDesk, ns.Prices
    local m = Desk.Markets("profit", "")
    check(Desk.Markets("profit", "") == m, "desk markets kept")
    Pr.Record(2589, 10, 5, now, 1, "Linen Cloth")
    check(Desk.Markets("profit", "") ~= m, "a price rebuilds them")
    local rate = Desk.DepositRate()
    check(type(rate) == "number", "deposit rate")
    ns.AuctionDeskUI.Show()
    for _, view in ipairs({ "listings", "deals", "margins", "control", "overview" }) do ns.AuctionDeskUI.Show(view) end

    -- Fishing: the goal tally walks the whole cast log once per change.
    local G = ns.FishingGoals
    local caught = G.Caught()
    check(G.Caught() == caught, "goal tally kept")
    D.Changed("fishing")
    check(G.Caught() ~= caught, "rebuilt after a cast")
    ns.FishingUI.Show()
    for _, view in ipairs({ "spots", "log", "sessions", "goals", "map", "now" }) do ns.FishingUI.Show(view) end

    -- Guild actions (ns.Refresh) move the guild source on.
    local v = D.Version("guild")
    ns.Refresh()
    check(D.Version("guild") > v, "ns.Refresh bumps guild")
end

scenarios.large_data_economy = function()
    local ns = boot(11509)
    local E, UI = ns.Economy, ns.EconomyUI
    local now = time()
    -- Two characters, 5000 entries each, 400 days with gaps in the gold readings.
    for c = 1, 2 do
        local log, days = {}, {}
        for i = 1, 5000 do
            log[i] = { t = now - (5000 - i) * 600, kind = (i % 3 == 0) and "loot" or "vendor", amount = (i % 7) - 3,
                detail = "Entry " .. c .. "-" .. i, gained = { { "|cffffffff|Hitem:2589::::::::|h[Linen Cloth]|h|r", 2 } } }
        end
        for d = 0, 399 do
            local day = date("%Y-%m-%d", now - d * 86400)
            days[day] = { inc = d, exp = 1, by = { vendor = d - 1 }, money = (d % (c + 2) == 0) and (c * 100000 + d) or nil }
        end
        TALODDB.economy["Alt" .. c .. "-Mockrealm"] = { log = log, days = days, auctions = {} }
    end

    -- ScopeDays (now one pass) gives the same gold as the old day-by-day search.
    local out, order = E.ScopeDays("all")
    check(#order == 400, "400 days: " .. #order)
    for _, day in ipairs({ order[1], order[57], order[200], order[400] }) do
        local want, any = 0, false
        for _, c in pairs(TALODDB.economy) do
            local best
            for d2, dd in pairs(c.days) do if d2 <= day and dd.money and (not best or d2 > best) then best = d2 end end
            if best then want, any = want + c.days[best].money, true end
        end
        check(out[day].money == (any and want or nil), "gold on " .. day .. ": " .. tostring(out[day].money) .. " vs " .. want)
    end
    check(E.ScopeDays("all") == out, "ScopeDays memoized")

    UI.Show("transactions")
    UI.state.range = 0
    UI.Refresh()
    local v = UI.views.transactions
    check(#v.list.all == 10000, "every entry listed: " .. #v.list.all)
    check(built(v.list) <= 40, "only the rows on screen formatted: " .. built(v.list))
    check(v.card.title:GetText():find("10000"), "count in the title")
    local rows = v.list.all
    UI.Refresh()
    check(v.list.all == rows, "unchanged data: rows kept")
    -- Searching formats each row once and keeps it.
    v.list.searchBox:SetText("entry 2-4999")
    v.list.searchBox:Fire("OnTextChanged")
    check(#v.list.items == 1 and v.list.items[1].text:find("Entry 2%-4999"), "search finds the row: " .. #v.list.items)
    v.list.searchBox:SetText("")
    v.list.searchBox:Fire("OnTextChanged")

    -- A new entry (the economy log's write path) changes the key.
    local log = TALODDB.economy["Alt1-Mockrealm"].log
    log[#log + 1] = { t = now, kind = "vendor", amount = 5, detail = "Fresh" }
    E.Changed()
    UI.Refresh()
    check(v.list.all ~= rows and #v.list.all == 10001, "new entry listed")

    -- Data events redraw at most once a second.
    local draws = counted(v)
    for _ = 1, 30 do UI.RefreshSoon() end
    check(draws[1] == 1, "a burst redraws once now: " .. draws[1])
    MOCK.RunTimers()
    check(draws[1] == 2, "and once after the gap: " .. draws[1])

    for _, view in ipairs({ "overview", "auctions", "trades" }) do UI.Show(view) end
end

scenarios.large_data_market = function()
    local ns = boot(11509)
    local Pr, M, UI = ns.Prices, ns.Market, ns.MarketUI
    local now = time()
    for id = 1, 3000 do
        Pr.Record(id, 100 + id, 5, now - 7200, 2, "Thing " .. id)
        Pr.Record(id, 90 + id, 4, now, 2, "Thing " .. id)
    end
    local s = M.Stats(42)
    check(s and s.looks == 2 and M.Stats(42) == s, "stats memoized")
    Pr.Record(42, 50, 9, now + 10, 3)
    check(M.Stats(42) ~= s and M.Stats(42).p == 50, "stats follow a new look")

    UI.Show("prices")
    local v = UI.views.prices
    check(#v.list.all == 3000, "every item listed: " .. #v.list.all)
    check(built(v.list) <= 40, "only the rows on screen formatted: " .. built(v.list))
    local rows = v.list.all
    UI.Refresh()
    check(v.list.all == rows, "unchanged prices: rows kept")
    Pr.Record(7, 1, 1, now + 20, 1)
    UI.Refresh()
    check(v.list.all ~= rows, "a new price rebuilds")

    -- AH result pages coalesce.
    local draws = counted(v)
    for _ = 1, 10 do UI.RefreshSoon() end
    check(draws[1] <= 1, "a burst of pages redraws once now: " .. draws[1])
    MOCK.RunTimers()
    check(draws[1] <= 2, "and once after the gap: " .. draws[1])

    UI.Show("deals")
    UI.Show("prices")
end

-- Background work: the big windows' frames and first-tab memos are built
-- after login a few ms per frame (never in combat, never closing the open
-- window), and a slow memo asked for by an open window after a change gives
-- the old value while the new one is built in the background.
scenarios.large_data_background = function()
    -- A fake profiler clock: 1 ms per read, so a job's slice (4 ms) ends
    -- after a few memo steps and each background build counts as slow.
    local ms = 0
    debugprofilestop = function() ms = ms + 1 return ms end
    local ns = boot(11509)
    local D, Desk, Pr = ns.Data, ns.AuctionDesk, ns.Prices
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    local now = time()
    local ids = {}
    for id in pairs(ns.ProfessionData.items) do ids[#ids + 1] = id end
    table.sort(ids)
    for i = 1, 300 do
        local id = ids[i]
        Pr.Record(id, 200, 10, now - 86400, 2)
        Pr.Record(id, 100, 10, now, 2)
        Pr.RecordLadder(id, { { 50, 2, "Al" }, { 100, 5, "Bo" }, { 300, 5, "Cy" } }, false, now)
    end
    D.Changed("prices")
    local builds = 0
    local base = Desk.BuildOpportunities
    Desk.BuildOpportunities = function() builds = builds + 1 return base() end
    local function settle()
        local frames = 0
        while D.Busy() and frames < 5000 do MOCK.Tick(0.02) frames = frames + 1 end
        return frames
    end

    -- Another main window open before the warm-up: it stays open.
    ns.GearUI.Show()
    check(D.Busy() and not _G.TALODAuctionDesk, "warm-up waits after login")
    MOCK.Tick(1)
    check(not _G.TALODAuctionDesk and builds == 0, "nothing built during the delay")
    MOCK.lockdown = true
    MOCK.Tick(5)
    check(not _G.TALODAuctionDesk, "no warm-up in combat")
    MOCK.lockdown = false
    local frames = settle()
    check(not D.Busy(), "warm-up finished")
    check(frames > 20, "spread over frames: " .. frames)
    for _, name in ipairs({ "TALODAuctionDesk", "TALODMarketWindow", "TALODEconomyWindow" }) do
        check(_G[name] and not _G[name]:IsShown(), name .. " built hidden")
    end
    check(ns.GearUI.IsShown(), "the open window stayed open")
    check(builds == 1, "opportunities built once: " .. builds)

    -- First open: no build of its own.
    ns.AuctionDeskUI.Show()
    check(ns.AuctionDeskUI.IsShown() and builds == 1, "first open served from the warm-up: " .. builds)
    local opps = Desk.Opportunities()

    -- A new price while it is open: the redraw keeps the old list and the
    -- background builds the new one; the window redraws when it lands.
    Pr.Record(ids[1], 90, 10, now + 5, 2)
    ns.AuctionDeskUI.Refresh()
    check(builds == 1 and D.Busy(), "redraw: old value now, rebuild queued")
    MOCK.Tick(0.02)
    -- A write while the rebuild is paused: dropped (it may be mid-walk), and
    -- the next redraw asks again.
    Pr.Record(ids[2], 90, 10, now + 6, 2)
    MOCK.Tick(0.02)
    check(not D.Busy(), "changed data mid-build: rebuild dropped")
    ns.AuctionDeskUI.Refresh()
    local draws = counted(ns.AuctionDeskUI.views.overview)
    settle()
    check(builds >= 2, "rebuilt in the background: " .. builds)
    check(draws[1] == 1, "the open window redrew once when it landed: " .. draws[1])
    local fresh = Desk.Opportunities()
    check(fresh ~= opps, "callers outside a redraw get the new list")
    local n = builds
    ns.AuctionDeskUI.Refresh()
    check(builds == n and not D.Busy(), "nothing more to do once it landed")

    -- Outside a redraw (slash, tooltips) a changed key builds at once.
    Pr.Record(ids[3], 80, 10, now + 7, 2)
    check(Desk.Opportunities() ~= fresh and builds == n + 1, "direct callers never get old data")
    debugprofilestop = nil
end
