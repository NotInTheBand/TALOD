-- Economy formulas, fifth pass: the usual price from recent days (old ones
-- stand in only marked stale, with their age); the usual supply one value a
-- day; the trend day medians against day medians; percents rounded both
-- ways; old daily summaries re-keyed by the local day; a sell rate whose
-- confidence matches the auctions behind its share; old auctions of yours
-- giving way to the market; one time to sell per posting; dated
-- sell-through; old prices marked on the Sell tab; unknown supply never 0;
-- market movement from recent looks only; bids against a price of their
-- time; an empty search clears its bids; deals, desk plans and standing on
-- recent looks only; resets within what sells; the live list against the
-- posting log; full scans never re-read; a new read replacing the visit's
-- price; archived day summaries kept; letters matched in time; loot never
-- across midnight; auctions dated by when they ended, ended ones not shown
-- listed; old ladders never an exact cost.
local scenarios, T = ...
local check, boot, slash = T.check, T.boot, T.slash

local LINEN, WOOL, SILK, SALT = 2589, 2592, 4306, 4289

local function itemInfo()
    function GetItemInfo(id)
        if id == LINEN then return "Linen Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132889, 13, 7, 5, 0 end
        if id == WOOL then return "Wool Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132911, 33, 7, 5, 0 end
        if id == SILK then return "Silk Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132905, 38, 7, 5, 0 end
        if id == SALT then return "Salt", nil, 1, 5, 0, "Trade Goods", "Other", 20, "", 132891, 10, 7, 5, 0 end
    end
end

local function setup(version)
    itemInfo()
    local ns = boot(version or 11509)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    return ns
end

local function auctions(ns, list)
    local c = ns.Economy.Char()
    c.auctions = list
    ns.Data.Changed("economy")
    ns.Market.InvalidateSales()
    ns.AuctionDesk.Invalidate()
    return c
end

local function near(a, b, eps) return type(a) == "number" and math.abs(a - b) < (eps or 1e-6) end

-- Local noon `d` days ago: looks on distinct days whatever the hour.
local function noon(ns, d)
    local Pr = ns.Prices
    return Pr.DayNoon(Pr.DayKey(time()) - d)
end

-- A legacy page: { count, minBid, increment, buyout, bid, highBidder, owner, id, band, name } rows.
local function legacyPage(rows, total)
    function GetNumAuctionItems(kind) if kind == "list" then return #rows, total or #rows end return 0, 0 end
    function GetAuctionItemInfo(kind, i)
        local r = kind == "list" and rows[i]
        if not r then return nil end
        return r[10] or "x", 0, r[1], 2, true, 1, "", r[2], r[3], r[4], r[5], r[6], nil, r[7], nil, 0, r[8]
    end
    function GetAuctionItemTimeLeft(kind, i) return rows[i] and rows[i][9] end
end

---------------------------------------------------------------------------
-- Usual price, trend and supply
---------------------------------------------------------------------------
scenarios.econ_r5_usual_recent = function()
    local ns = setup()
    local Pr, M = ns.Prices, ns.Market
    -- 1000c for 20 days half a year ago, then 400c for the last 6 days, 400c today.
    for d = 200, 181, -1 do Pr.Record(LINEN, 1000, 200, noon(ns, d), 10, "Linen Cloth") end
    for d = 6, 1, -1 do Pr.Record(LINEN, 400, 200, noon(ns, d), 10) end
    Pr.Record(LINEN, 400, 200, time(), 10)
    local s = M.Stats(LINEN)
    check(s.usual == 400 and s.usualBefore == 400 and not s.usualStale, "the market now: usual " .. tostring(s.usual)
        .. ", before " .. tostring(s.usualBefore))
    for _, d in ipairs(M.Deals()) do check(d.id ~= LINEN, "400c for a week is no deal against a price from months ago") end
    -- The graph's marks measure the same way.
    local copy = Pr.Looks(Pr.Entry(LINEN))
    local e = Pr.Entry(LINEN)
    copy[#copy + 1] = { t = e.t, p = e.p, n = e.n, a = e.a }
    check(M.MarkOverpriced(copy) == 400, "MarkOverpriced agrees: " .. tostring(M.MarkOverpriced(copy)))
end

scenarios.econ_r5_usual_age = function()
    local ns = setup()
    local Pr, M = ns.Prices, ns.Market
    -- Four days at 1000c half a year ago, then one auction of 1 at 150c today.
    for d = 200, 197, -1 do Pr.Record(SILK, 1000, 200, noon(ns, d), 10, "Silk Cloth") end
    Pr.Record(SILK, 150, 1, time(), 1)
    local s = M.Stats(SILK)
    check(s.underNow and s.usualStale and s.usualT <= noon(ns, 197), "the usual price comes from old looks: stale")
    local _, how, info = M.SaleValue(SILK)
    check(info.over and info.p == 1000 and info.t == s.usualT and info.stale, "the stand-in keeps its age: t "
        .. tostring(info.t) .. ", stale " .. tostring(info.stale))
    check(how == "ah", "still the AH value: " .. tostring(how))
end

scenarios.econ_r5_supply_per_day = function()
    local ns = setup()
    local Pr, M = ns.Prices, ns.Market
    for d = 4, 2, -1 do Pr.Record(WOOL, 100, 20, noon(ns, d), 2, "Wool Cloth") end
    -- A dump looked at twelve times in one evening.
    for i = 0, 11 do Pr.Record(WOOL, 100, 200, noon(ns, 1) + i * 660, 20) end
    Pr.Record(WOOL, 100, 20, time(), 2)
    local s = M.Stats(WOOL)
    check(s.avgN == 20 and near(s.supplyTrend, 0), "one value a day: usually " .. tostring(s.avgN) .. ", trend "
        .. tostring(s.supplyTrend))
end

scenarios.econ_r5_trend_like_with_like = function()
    local ns = setup()
    local Pr, M = ns.Prices, ns.Market
    -- Every day a look at 100c and one at 120c; now one at 120c.
    for d = 4, 1, -1 do
        Pr.Record(SALT, 100, 50, noon(ns, d), 5, "Salt")
        Pr.Record(SALT, 120, 50, noon(ns, d) + 3600, 5)
    end
    Pr.Record(SALT, 120, 50, time(), 5)
    local s = M.Stats(SALT)
    check(s.trendBase == 110 and near(s.trend, 120 / 110 - 1), "against the days' middle (110c), not their lows: "
        .. tostring(s.trend))
end

scenarios.econ_r5_pct_rounding = function()
    local ns = setup()
    local Pct = ns.MarketUI.Pct
    local function digits(x) return (Pct(x):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
    check(digits(-0.001) == "0%" and digits(-0.026) == "-3%" and digits(-0.012) == "-1%" and digits(0.012) == "+1%",
        "rounded both ways: " .. digits(-0.001) .. " " .. digits(-0.026) .. " " .. digits(-0.012))
end

scenarios.econ_r5_rekey_days = function()
    local ns = setup()
    local Pr, Store = ns.Prices, ns.Store
    local def
    for _, x in ipairs(Store.DEFS) do if x.key == "prices" then def = x end end
    check(def and def.version >= 4 and def.migrate[4], "prices store migrates its day summaries")
    -- A saved entry: two kept looks (40 then 20 units on consecutive days) and a
    -- summary that put 50 units on the second day (another day's count) plus an older day.
    local t1, t2 = noon(ns, 3), noon(ns, 2)
    local d1, d2 = Pr.DayKey(t1), Pr.DayKey(t2)
    local old = d1 - 10
    local e = { t = time(), p = 100, n = 20, h = Pr.PackLooks({ { t = t1, p = 100, n = 40 }, { t = t2, p = 90, n = 20 } }),
        d = old .. ":80:80:7," .. d2 .. ":90:100:50" }
    local saved = { realm = { [LINEN] = e } }
    Pr.RekeyDays(saved)
    local days = {}
    for day, lo, hi, n in e.d:gmatch("(%d+):([%d%.]+):([%d%.]+):(%d*)") do days[tonumber(day)] = { tonumber(lo), tonumber(hi), tonumber(n) } end
    check(days[d2] and days[d2][3] == 20 and days[d2][1] == 90, "the second day from its own look: " .. e.d)
    check(days[d1] and days[d1][3] == 40, "the first day folded by the local day")
    check(days[old] and days[old][3] == 7, "a day before the kept looks stays")
end

---------------------------------------------------------------------------
-- Sell rate and movement
---------------------------------------------------------------------------
scenarios.econ_r5_sell_rate_effective = function()
    local ns = setup()
    local M = ns.Market
    local now = time()
    local linen, wool, silk, salt = MOCK.ItemLink(LINEN, "Linen Cloth"), MOCK.ItemLink(WOOL, "Wool Cloth"),
        MOCK.ItemLink(SILK, "Silk Cloth"), MOCK.ItemLink(SALT, "Salt")
    local list = {}
    local function add(name, status, n, ago)
        for _ = 1, n do list[#list + 1] = { name = name, count = 1, status = status, received = status == "sold" and 90 or nil,
            t = now - ago - 3600, ended = now - ago } end
    end
    add(linen, "expired", 10, 90 * 86400) add(linen, "sold", 1, 0)      -- one recent sale after ten old failures
    add(wool, "expired", 50, 365 * 86400) add(wool, "sold", 1, 0)
    add(silk, "sold", 20, 120 * 86400) add(silk, "expired", 2, 0)       -- two recent failures after twenty old sales
    add(salt, "expired", 50, 120 * 86400)                               -- fifty of one age: they keep their word
    auctions(ns, list)
    for _, id in ipairs({ LINEN, WOOL, SILK }) do
        local s = M.MySales(id)
        check(s.rate == nil and s.rateOld and s.nEff < 3, "one or two recent auctions are no rate: " .. id .. " " .. tostring(s.rate))
        check(select(3, M.SaleCounts(id)) == nil, "the list counts it the same: " .. id)
    end
    local s = M.MySales(SALT)
    check(s.rate and s.rate < 0.05 and near(s.nEff, 50, 1e-6), "fifty old failures: " .. tostring(s.rate))
    check(near(select(3, M.SaleCounts(SALT)), s.rate), "SaleCounts agrees")
    local line = M.SellChanceLines(M.MySales(LINEN))
    check(line:find("too few recent auctions"), "said: " .. line)
end

scenarios.econ_r5_old_sales_market = function()
    local ns = setup()
    local Pr, M = ns.Prices, ns.Market
    local now = time()
    local link = MOCK.ItemLink(LINEN, "Linen Cloth")
    local list = {}
    for i = 1, 5 do list[i] = { name = link, count = 20, status = "expired", t = now - 201 * 86400, ended = now - 200 * 86400 } end
    auctions(ns, list)
    -- The market today: 100 -> 70 -> 40 -> 10 over 36 h.
    Pr.Record(LINEN, 50, 100, now - 36 * 3600, 10, "Linen Cloth")
    Pr.Record(LINEN, 50, 70, now - 24 * 3600, 7)
    Pr.Record(LINEN, 50, 40, now - 12 * 3600, 4)
    Pr.Record(LINEN, 50, 10, now, 1)
    local mv = M.Movement(LINEN)
    check(mv.key == "fast" and mv.source == "market", "old auctions give way to the market: " .. mv.key .. " " .. tostring(mv.source))
    check(M.MoveKey(LINEN) == "fast", "MoveKey too: " .. M.MoveKey(LINEN))
    -- No market evidence: your old auctions still say it.
    check(M.Movement(SALT).key == "unknown", "nothing at all: unknown")
end

scenarios.econ_r5_sell_time_posting = function()
    local ns = setup()
    local M = ns.Market
    local now = time()
    local link = MOCK.ItemLink(SALT, "Salt")
    local t0 = now - 5 * 86400
    local list = {}
    -- One posting of 100 sold in four parts, 1-4 h after posting.
    for k = 1, 4 do list[#list + 1] = { name = link, of = 1, count = 25, status = "sold", received = 2375, t = t0, closedAt = t0 + k * 3600, ended = t0 + k * 3600 } end
    -- Three other auctions, each sold after 40 h.
    for i = 1, 3 do list[#list + 1] = { name = link, count = 20, status = "sold", received = 1900, t = t0 + i, closedAt = t0 + i + 40 * 3600, ended = t0 + i + 40 * 3600 } end
    auctions(ns, list)
    local s = M.MySales(SALT)
    check(s.sold == 4 and s.sellTime == 40 * 3600, "one time per auction: usually " .. tostring(s.sellTime and s.sellTime / 3600) .. " h")
end

scenarios.econ_r5_sellthrough_dates = function()
    local ns = setup()
    local now = time()
    local link = MOCK.ItemLink(SALT, "Salt")
    local list = {}
    for i = 1, 5 do list[i] = { name = link, count = 20, status = "sold", received = 1900, t = now - 371 * 86400, ended = now - 370 * 86400 } end
    auctions(ns, list)
    ns.MarketUI.Show("sellthrough")
    local lines
    local real = ns.Tooltip.Text
    ns.Tooltip.Text = function(_, l) lines = l end
    for _, it in ipairs(ns.MarketUI.views.sellthrough.list.items) do
        if not it.header and it.tooltip and (it.id == SALT or (it.e and it.e.id == SALT)) then it.tooltip(ns.MarketUI.views.sellthrough) end
    end
    ns.Tooltip.Text = real
    local text = table.concat(lines or {}, " | ")
    check(text:find("Last sold: .-%d%d%d%d %(370 days ago%)"), "the year and the age: " .. text)
    TALODMarketWindow:Hide()
end

---------------------------------------------------------------------------
-- Sale value
---------------------------------------------------------------------------
scenarios.econ_r5_sell_tab_old = function()
    MOCK.bags[0][1] = MOCK.ItemLink(SILK, "Silk Cloth")
    MOCK.bagCounts["0:1"] = 20
    local ns = setup()
    local M, Pr = ns.Market, ns.Prices
    Pr.Record(SILK, 1000, 50, time() - 200 * 86400, 5, "Silk Cloth")
    local row
    for _, e in ipairs(M.SellList()) do if e.id == SILK then row = e end end
    check(row and row.verdict == "ah" and row.stale, "an old price is marked on the row")
    ns.MarketUI.Show("sell")
    local view = ns.MarketUI.views.sell
    check(view.card.sub:GetText():find("1 from old prices"), "and in the total: " .. view.card.sub:GetText())
    TALODMarketWindow:Hide()
    MOCK.bags[0][1] = nil
end

scenarios.econ_r5_supply_unknown = function()
    local ns = setup()
    local M, Pr, P = ns.Market, ns.Prices, ns.Professions
    -- A look that did not count the units: the price is known, the supply is not.
    Pr.Record(SILK, 500, nil, time(), nil, "Silk Cloth")
    local _, src, _, _, listed = P.SellValue(SILK)
    check(src == "ah" and listed == nil, "supply unknown, not 0: " .. tostring(listed))
    check(M.BatchProfit({ creates = SILK, makes = 1, reagents = {} }, 10) == nil, "no vendor-only profit from an unknown supply")
end

---------------------------------------------------------------------------
-- Market movement
---------------------------------------------------------------------------
scenarios.econ_r5_movement_recent = function()
    local ns = setup()
    local Pr, M = ns.Prices, ns.Market
    local now = time()
    -- 50 days ago 100 -> 55 -> 10 in a day; the last 10 days 10 listed every day, unchanged.
    Pr.Record(LINEN, 50, 100, now - 50 * 86400, 10, "Linen Cloth")
    Pr.Record(LINEN, 50, 55, now - 50 * 86400 + 12 * 3600, 6)
    Pr.Record(LINEN, 50, 10, now - 49 * 86400, 1)
    for d = 9, 0, -1 do Pr.Record(LINEN, 50, 10, noon(ns, d), 1) end
    local mm = M.MarketMovement(LINEN)
    check(mm and mm.gone == 0 and mm.stuck, "the old burst does not speak for now: gone " .. tostring(mm and mm.gone))
    check(M.Movement(LINEN).key == "dead" and M.MoveKey(LINEN) == "dead", "nothing left in 9 days: " .. M.Movement(LINEN).key)
    -- Only looked at 55 days ago: nothing about now.
    Pr.Record(SILK, 50, 60, now - 55 * 86400, 6, "Silk Cloth")
    Pr.Record(SILK, 50, 30, now - 55 * 86400 + 12 * 3600, 3)
    Pr.Record(SILK, 50, 5, now - 54 * 86400, 1)
    check(M.MarketMovement(SILK) == nil and M.Movement(SILK).key == "unknown" and M.MoveKey(SILK) == "unknown",
        "old looks only: not enough data")
end

---------------------------------------------------------------------------
-- Deals and bids
---------------------------------------------------------------------------
scenarios.econ_r5_bid_old_price = function()
    local ns = setup()
    local Pr, M = ns.Prices, ns.Market
    local now = time()
    for d = 63, 60, -1 do Pr.Record(SILK, 1000, 10, noon(ns, d), 2, "Silk Cloth") end
    -- Today: one bid-only auction, no buyout seen.
    Pr.RecordBids(SILK, { { 1, 300, 0, 4 } }, "legacy", now)
    local found
    for _, d in ipairs(M.Bids(now)) do if d.id == SILK then found = d end end
    check(found and found.saving == nil, "a buyout from two months ago is no saving today: " .. tostring(found and found.saving))
end

scenarios.econ_r5_empty_search_clears_bids = function()
    local ns = setup()
    local Pr = ns.Prices
    function QueryAuctionItems() end
    Pr.HookQueries()
    QueryAuctionItems("Linen Cloth", nil, nil, 0, nil, nil, false, true)
    legacyPage({ { 20, 100, 5, 0, 0, false, "Al", LINEN, 4, "Linen Cloth" }, { 20, 150, 5, 400, 0, false, "Bo", LINEN, 4, "Linen Cloth" } })
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    check(Pr.Bids(LINEN) and #Pr.Bids(LINEN).rows > 0, "bids kept")
    -- 30 minutes later the same search finds nothing.
    MOCK.now = MOCK.now + 1800
    MOCK.time = MOCK.time + 1800
    QueryAuctionItems("Linen Cloth", nil, nil, 0, nil, nil, false, true)
    legacyPage({})
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    local b = Pr.Bids(LINEN)
    check(not b or #b.rows == 0, "an empty search clears the item's bids")
    -- A filtered search that finds nothing proves nothing.
    QueryAuctionItems("Wool Cloth", nil, nil, 0, nil, nil, false, true)
    legacyPage({ { 20, 100, 5, 0, 0, false, "Al", WOOL, 4, "Wool Cloth" }, { 20, 150, 5, 400, 0, false, "Bo", WOOL, 4, "Wool Cloth" } })
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    QueryAuctionItems("Wool Cloth", 10, 20, 0, nil, nil, false, true)
    legacyPage({})
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    check(Pr.Bids(WOOL) and #Pr.Bids(WOOL).rows > 0, "a filtered empty search keeps them")
    QueryAuctionItems = nil
end

---------------------------------------------------------------------------
-- Posting price and standing
---------------------------------------------------------------------------
scenarios.econ_r5_old_undercut = function()
    local ns = setup()
    local Pr, Desk = ns.Prices, ns.AuctionDesk
    local now = time()
    Pr.RecordLadder(LINEN, { { 40, 20, "Al" }, { 50, 20, "Tester", true } }, false, now - 5 * 86400, true)
    local st = Desk.Standing(LINEN, 50)
    check(st.state == "unknown" and st.oldUndercut and st.repost == nil, "an undercut 5 days old: no repost: " .. st.state)
    -- No ladder, a price look from 30 days ago under yours: the same.
    Pr.Record(WOOL, 40, 20, now - 30 * 86400, 2, "Wool Cloth")
    st = Desk.Standing(WOOL, 50)
    check(st.state == "unknown" and st.repost == nil, "old entry: unknown: " .. st.state)
    -- A fresh undercut still says so.
    Pr.RecordLadder(SALT, { { 40, 20, "Al" }, { 50, 20, "Tester", true } }, false, now, true)
    st = Desk.Standing(SALT, 50)
    check(st.state == "undercut" and st.repost, "fresh: undercut with a repost")
end

scenarios.econ_r5_standing_newer_look = function()
    local ns = setup()
    local Pr, Desk = ns.Prices, ns.AuctionDesk
    local now = time()
    Pr.RecordLadder(LINEN, { { 80, 20, "Al" }, { 120, 20, "Bo" } }, false, now - 3 * 86400, true)
    Pr.Record(LINEN, 120, 20, now - 300, 1, "Linen Cloth")
    local st = Desk.Standing(LINEN, 100)
    check(st.state == "lowest" and st.repost == nil, "the newer look: you are the cheapest: " .. st.state)
end

scenarios.econ_r5_live_list_log = function()
    local ns = setup(16001)
    local Desk, Pr = ns.AuctionDesk, ns.Prices
    local now = time()
    local link = MOCK.ItemLink(SALT, "Salt")
    -- Read 20 h ago with 47 h left; the log closed it as sold 19 h ago.
    TALODDB.ahOwned = TALODDB.ahOwned or {}
    TALODDB.ahOwned[ns.Gear.CharKey()] = { t = now - 20 * 3600, realm = Pr.RealmKey(),
        list = { { id = SALT, name = "Salt", count = 20, unit = 500, left = 47 * 3600 } } }
    auctions(ns, { { id = 1, name = link, count = 20, buyout = 10000, deposit = 60, duration = "48 h", status = "sold",
        received = 9560, t = now - 21 * 3600, closedAt = now - 19 * 3600, ended = now - 3600 } })
    ns.Data.Changed("prices")
    Desk.Invalidate()
    local sum = Desk.Summary()
    check(sum.listed == 0 and sum.value == 0, "sold since the list was read: not active: " .. sum.listed)
    -- Read 5 h ago, empty; posted 1 h ago: in the listings.
    TALODDB.ahOwned[ns.Gear.CharKey()] = { t = now - 5 * 3600, realm = Pr.RealmKey(), list = {} }
    auctions(ns, { { id = 2, name = link, count = 20, buyout = 10000, deposit = 60, duration = "48 h", status = "listed", t = now - 3600 } })
    ns.Data.Changed("prices")
    Desk.Invalidate()
    sum = Desk.Summary()
    check(sum.listed == 1 and sum.value == 9500 and Desk.Listings().source == "game + log", "posted since: listed " .. sum.listed)
end

---------------------------------------------------------------------------
-- Auction desk plans
---------------------------------------------------------------------------
scenarios.econ_r5_desk_old_usual = function()
    local ns = setup()
    local Pr, Desk = ns.Prices, ns.AuctionDesk
    local now = time()
    for d = 204, 200, -1 do Pr.Record(SILK, 300, 80, noon(ns, d), 4, "Silk Cloth") end
    Pr.Record(SILK, 60, 80, now, 4)
    Pr.RecordLadder(SILK, { { 60, 20, "A1" }, { 60, 20, "A2" }, { 60, 20, "A3" }, { 60, 20, "A4" }, { 200, 20, "Bo" } }, false, now, true)
    Desk.Invalidate()
    local plan = Desk.Detail(SILK)
    check(plan.usual == nil and plan.usualOld, "a usual price from half a year ago is no yardstick")
    check(plan.best == nil and #Desk.Opportunities() == 0, "no expected profit from it")
end

scenarios.econ_r5_desk_demand = function()
    local ns = setup()
    local Pr, Desk = ns.Prices, ns.AuctionDesk
    local now = time()
    for d = 6, 1, -1 do Pr.Record(SILK, 100, 540, noon(ns, d), 27, "Silk Cloth") end
    Pr.Record(SILK, 50, 540, now, 27)
    local rows = {}
    for i = 1, 25 do rows[i] = { 50, 20, "S" .. i } end
    rows[26], rows[27] = { 150, 20, "Bo" }, { 150, 20, "Cy" }
    Pr.RecordLadder(SILK, rows, false, now, true)
    -- Your history: 5 auctions of 20, about one sold a day.
    local link = MOCK.ItemLink(SILK, "Silk Cloth")
    local list = {}
    for i = 1, 5 do list[i] = { name = link, count = 20, deposit = 10, status = "sold", received = 1900, t = now - i * 86400, ended = now - i * 86400 + 3600 } end
    auctions(ns, list)
    local plan = Desk.Detail(SILK)
    local step = plan.steps[1]
    check(step and step.units == 500 and step.profit and step.overDemand, "500 units: more than sells in one listing")
    check(plan.best == nil and #Desk.Opportunities() == 0, "never the best reset nor an opportunity")
    check(plan.demand and plan.demand < 25, "about 20 a day: " .. tostring(plan.demand))
end

---------------------------------------------------------------------------
-- Price recording
---------------------------------------------------------------------------
scenarios.econ_r5_fresh_read = function()
    local ns = setup()
    local Pr = ns.Prices
    function QueryAuctionItems() end
    Pr.HookQueries()
    QueryAuctionItems("Silk Cloth", nil, nil, 0, nil, nil, false, true)
    legacyPage({ { 5, 40, 5, 250, 0, false, "Al", SILK, 3, "Silk Cloth" }, { 20, 100, 5, 1600, 0, false, "Bo", SILK, 3, "Silk Cloth" } })
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    check(Pr.Entry(SILK).p == 50, "50c each")
    -- You buy the 5; the same search 3 minutes later shows only Bo's 20 at 80c.
    MOCK.now = MOCK.now + 180
    MOCK.time = MOCK.time + 180
    QueryAuctionItems("Silk Cloth", nil, nil, 0, nil, nil, false, true)
    legacyPage({ { 20, 100, 5, 1600, 0, false, "Bo", SILK, 3, "Silk Cloth" } })
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    local e = Pr.Entry(SILK)
    check(e.p == 80 and e.n == 20, "a new read is the market now: " .. e.p .. " / " .. tostring(e.n))
    QueryAuctionItems = nil
end

scenarios.econ_r5_scan_held_list = function()
    local ns = setup(16001)
    local H, Pr = ns.AHHelper, ns.Prices
    local rows = { { "Salt", 10, 3000, SALT } }
    C_AuctionHouse = {
        SendSearchQuery = function() end,
        MakeItemKey = function(id) return { itemID = id } end,
        ReplicateItems = function() end,
        GetNumReplicateItems = function() return #rows end,
        GetReplicateItemInfo = function(i)
            local r = rows[i + 1]
            if not r then return nil end
            return r[1], nil, r[2], nil, nil, nil, nil, nil, nil, r[3], nil, nil, nil, nil, nil, nil, r[4]
        end,
    }
    AuctionHouseFrame = CreateFrame("Frame", "AuctionHouseFrame", UIParent)
    MOCK.FireEvent("AUCTION_HOUSE_SHOW")
    MOCK.RunTimers()
    -- The client still holds an earlier scan's list: Salt at 300c.
    TALODDB.ahFullScan = {}
    H.FullScan()
    for _ = 1, 15 do MOCK.Tick(0.3) end
    MOCK.RunTimers() MOCK.RunTimers()
    check(H.state.scan and not H.state.scan.reading and not Pr.Entry(SALT), "the list held before the click is not read as the answer")
    -- The answer: Salt at 500c.
    rows[1] = { "Salt", 10, 5000, SALT }
    MOCK.FireEvent("REPLICATE_ITEM_LIST_UPDATE")
    MOCK.Tick(2.5)
    MOCK.RunTimers() MOCK.RunTimers() MOCK.RunTimers()
    check(Pr.Entry(SALT) and Pr.Entry(SALT).p == 500, "the answer read: " .. tostring(Pr.Entry(SALT) and Pr.Entry(SALT).p))
    C_AuctionHouse = nil
end

scenarios.econ_r5_archived_days = function()
    local ns = setup()
    local Pr, Store = ns.Prices, ns.Store
    -- 30 days archived when the item went unseen; it comes back and is seen twice.
    local parts = {}
    for d = 230, 201, -1 do parts[#parts + 1] = Pr.DayKey(noon(ns, d)) .. ":100:100:20" end
    local packed = Store.PackList({ 100, noon(ns, 200), 20, 2, nil, nil, nil, table.concat(parts, ",") }, 8, ";")
    local key = Pr.RealmKey() .. "/" .. LINEN
    ns.Archive = ns.Archive or {}
    local A = ns.Archive
    local loaded, lookup = A.Loaded, A.Lookup
    A.Loaded = function() return true end
    A.Lookup = function(rule, k) if rule == "priceUnseen" and k == key then return { packed } end return {} end
    Pr.Record(LINEN, 90, 20, noon(ns, 2), 2, "Linen Cloth")
    Pr.Record(LINEN, 95, 20, noon(ns, 1), 2)
    local days = Pr.History(LINEN, "days")
    A.Loaded, A.Lookup = loaded, lookup
    check(#days >= 32, "the archived days stay with the new ones: " .. #days)
end

---------------------------------------------------------------------------
-- Gold ledger
---------------------------------------------------------------------------
scenarios.econ_r5_letter_in_time = function()
    local ns = setup()
    local E = ns.Economy
    local now = time()
    local link = MOCK.ItemLink(LINEN, "Linen Cloth")
    local c = auctions(ns, { { id = 1, name = link, count = 20, deposit = 60, duration = "48 h", status = "listed", t = now - 3 * 86400 },
        { id = 2, name = link, count = 10, deposit = 30, duration = "48 h", status = "listed", t = now - 86400 } })
    -- 10 sold; the letter came 2.5 days ago: before listing 2 was posted.
    local a = E.SettleListing(c, "Linen Cloth", "sold", 950, now - 2.5 * 86400, { count = 10 })
    check(a and a.id ~= 2 and a.status == "sold", "the listing up at the time: " .. tostring(a and a.id))
    local two
    for _, x in ipairs(c.auctions) do if x.id == 2 then two = x end end
    check(two.status == "listed", "the later listing is still up")
    check(a.closedAt and a.closedAt - a.t > 0, "a real time to sell")
end

scenarios.econ_r5_loot_midnight = function()
    MOCK.money = 10000
    local ns = setup()
    local c = ns.Economy.Char()
    local function changed() MOCK.FireEvent("PLAYER_MONEY") MOCK.FireEvent("BAG_UPDATE_DELAYED") MOCK.Tick(0.5) end
    local midnight = ns.Prices.DayNoon(ns.Prices.DayKey(time())) - 43200
    MOCK.now = midnight - 60
    MOCK.FireEvent("LOOT_OPENED") MOCK.money = MOCK.money + 5000 changed() MOCK.FireEvent("LOOT_CLOSED") MOCK.Tick(4)
    MOCK.now = midnight + 30
    MOCK.FireEvent("LOOT_OPENED") MOCK.money = MOCK.money + 3000 changed() MOCK.FireEvent("LOOT_CLOSED") MOCK.Tick(4)
    local n = #c.log
    check(n >= 2 and c.log[n].kind == "loot" and c.log[n].amount == 3000 and c.log[n - 1].amount == 5000,
        "two days, two entries: " .. tostring(c.log[n] and c.log[n].amount))
end

scenarios.econ_r5_auctions_by_end = function()
    local ns = setup()
    local E = ns.Economy
    local now = time()
    local link = MOCK.ItemLink(LINEN, "Linen Cloth")
    -- Posted 8 days ago, sold 6 days ago; a 48 h listing from 40 days ago never closed.
    auctions(ns, { { id = 1, name = link, count = 20, deposit = 60, duration = "48 h", status = "sold", received = 9560,
        t = now - 8 * 86400, closedAt = now - 6 * 86400, ended = now - 86400 },
        { id = 2, name = link, count = 20, deposit = 60, duration = "48 h", status = "listed", t = now - 40 * 86400 } })
    check(E.ListingOver(ns.Economy.Char().auctions[2]) and not E.ListingOver(ns.Economy.Char().auctions[1]), "its time ran out")
    local t = E.AuctionTotals(ns.Economy.Char().auctions)
    check(t.listed == 0 and t.unknown == 1, "not counted as listed: " .. t.listed)
    ns.MarketUI.ShowPage("mine", "auctions", "all")
    local v = ns.MarketUI.views.mine
    local sub = v.card.sub:GetText()
    check(sub:find("1 sold", 1, true) and sub:find("0 listed", 1, true) and sub:find("1 ended, outcome unknown", 1, true),
        "the sale counted, the unclosed one not listed: " .. sub)
    -- In a time range by when it ended: the sale 6 days ago is in the last 7 days, the
    -- listing that ran out 38 days ago is not.
    v.list:SetRange("week")
    local n = 0
    for _, it in ipairs(v.list.items) do if not it.header and it.id then n = n + 1 end end
    check(n == 1, "7 days: the sale that ended in it: " .. n)
end

---------------------------------------------------------------------------
-- Crafting costs
---------------------------------------------------------------------------
scenarios.econ_r5_old_ladder_cost = function()
    local ns = setup()
    local Pr, P = ns.Prices, ns.Professions
    local now = time()
    Pr.RecordLadder(LINEN, { { 10, 200, "Al" } }, false, now - 30 * 86400, true)
    Pr.Record(LINEN, 10, 200, now - 30 * 86400, 10, "Linen Cloth")
    -- Today a broad search: 50c lowest, 40 listed (the price moves, the ladder does not).
    Pr.Record(LINEN, 50, 40, now, 4)
    local cost, info = P.BuyCost(LINEN, 20)
    check(cost == 1000 and info and info.src ~= "ladder" and info.estimated, "today's price, estimated: " .. tostring(cost))
    -- With nothing newer, an old ladder is still used but marked old.
    Pr.RecordLadder(WOOL, { { 10, 20, "Al" }, { 10, 20, "Bo" } }, false, now - 30 * 86400, true)
    Pr.Record(WOOL, 10, 200, now - 30 * 86400, 10, "Wool Cloth")
    cost, info = P.BuyCost(WOOL, 20)
    check(cost == 200 and info.stale, "old ladder: marked: " .. tostring(cost) .. " " .. tostring(info.src) .. " " .. tostring(info.age))
end
