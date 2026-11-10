-- Economy formulas, second pass: a well-supplied price drop is the price, a
-- lone exact look is never judged by browse rows, the price graph marks what
-- the usual price left out, unknown counts stay unknown (graph, partial pages,
-- partial results, usual supply), page re-reads counted once, identical bids
-- kept apart, sell-through groups and rate wording, old evidence keeps its
-- word, one tally per item, deposits over the vendor price, fishing values
-- with unknown catches, bound copies, movement from day counts and dense
-- looks, your own cheap listing is no deal, desk deals and listings (losses
-- last, ties, unknown deposits and values, stale looks, rounding), Open All
-- letters, partial commodity sales, own characters by name and realm,
-- make-or-buy after what was bought, unpriced materials in the planner,
-- training at a rank's end and book ranks, and the tracker's sale value.
local scenarios, T = ...
local check, boot = T.check, T.boot

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

-- Your auction log (current character), replaced; memos rebuilt.
local function auctions(ns, list)
    local c = ns.Economy.Char()
    c.auctions = list
    ns.Data.Changed("economy")
    ns.Market.InvalidateSales()
    ns.AuctionDesk.Invalidate()
    return c
end

---------------------------------------------------------------------------
-- Usual price and outliers
---------------------------------------------------------------------------
scenarios.econ_r2_supplied_drop = function()
    local ns = setup()
    local M, Pr = ns.Market, ns.Prices
    local now = time()
    -- Five days at 100c (200 units), then three at 45c with 300 units in 30 auctions: the market fell.
    for i = 1, 5 do Pr.Record(LINEN, 100, 200, now - (8 - i) * 86400, 10, "Linen Cloth") end
    for i = 6, 8 do Pr.Record(LINEN, 45, 300, now - (8 - i) * 86400, 30) end
    local s = M.Stats(LINEN)
    check(not s.underNow and s.low == 45, "a supplied drop is not a throwaway: under " .. tostring(s.underNow) .. " low " .. tostring(s.low))
    local fair, _, odd = M.FairPrice(LINEN)
    check(fair == 45 and not odd, "fair price is the price now: " .. tostring(fair))
    -- Stacks of 10 at 45c each (450c): 1c under the stack.
    check(math.abs(M.PostPrice(LINEN) - 44.9) < 1e-9, "post under the price now: " .. tostring(M.PostPrice(LINEN)))
    local v, how = M.SaleValue(LINEN)
    check(v == 45 * 0.95 and how == "ah", "sale value from the price now: " .. tostring(v))
    -- One thin cheap unit is still a throwaway.
    for i = 1, 5 do Pr.Record(WOOL, 100, 200, now - (7 - i) * 86400, 10, "Wool Cloth") end
    Pr.Record(WOOL, 30, 1, now, 1)
    check(M.Stats(WOOL).underNow and M.FairPrice(WOOL) == 100, "one unit at 30c: the usual price stands in")
end

scenarios.econ_r2_lone_exact = function()
    local ns = setup()
    local M, Pr = ns.Market, ns.Prices
    local now = time()
    -- Two browse rows (a 20-stack's price, maybe) and one exact look at 100c.
    Pr.Record(LINEN, 2000, 20, now - 2 * 86400, nil, "Linen Cloth", true)
    Pr.Record(LINEN, 2000, 20, now - 86400, nil, nil, true)
    Pr.Record(LINEN, 100, 20, now, 3)
    local s = M.Stats(LINEN)
    check(s.looks == 3 and s.usual == 100 and not s.underNow, "usual from the exact look: " .. tostring(s.usual))
    check(M.FairPrice(LINEN) == 100 and M.PostPrice(LINEN) == 99, "fair 100c, post 99c: " .. tostring(M.FairPrice(LINEN)))
    check(select(1, M.SaleValue(LINEN)) == 95, "sale value 95c: " .. tostring(M.SaleValue(LINEN)))
end

scenarios.econ_r2_chart_marks = function()
    local ns = setup()
    local M, Pr, Chart = ns.Market, ns.Prices, ns.PriceChart
    local now = time()
    for i, p in ipairs({ 10, 10, 10, 12, 22, 25, 25, 25 }) do Pr.Record(LINEN, p, 50, now - (8 - i) * 86400, 5, "Linen Cloth") end
    -- Three well-supplied looks at 25c in a row are a price that held, not overpriced.
    local s = M.Stats(LINEN)
    check(s.base == 12 and s.high == 25 and s.over == 0, "stats: base 12, 25 kept: " .. tostring(s.base) .. " " .. tostring(s.high))
    for _, mode in ipairs({ "days", "looks" }) do
        local pts = Chart.Data(LINEN, mode)
        local over, kept22 = 0, false
        for _, pt in ipairs(pts) do
            if pt.over then over = over + 1 end
            if pt.p == 22 and not pt.over then kept22 = true end
        end
        check(over == 0 and kept22, mode .. ": the chart marks what the usual left out (" .. over .. ")")
    end
    -- One greedy 1-unit look at 99c among them is still overpriced, in both.
    Pr.Record(SALT, 10, 50, now - 4 * 86400, 5, "Salt")
    Pr.Record(SALT, 10, 50, now - 3 * 86400, 5)
    Pr.Record(SALT, 99, 1, now - 2 * 86400, 1)
    Pr.Record(SALT, 10, 50, now - 86400, 5)
    check(M.Stats(SALT).over == 1, "a thin high look: overpriced")
    local silkOver = 0
    for _, pt in ipairs(Chart.Data(SALT, "looks")) do if pt.over then silkOver = silkOver + 1 end end
    check(silkOver == 1, "the chart marks it too")
    -- A thin throwaway is marked too.
    for i = 1, 5 do Pr.Record(WOOL, 100, 200, now - (7 - i) * 86400, 10, "Wool Cloth") end
    Pr.Record(WOOL, 30, 1, now, 1)
    local pts = Chart.Data(WOOL, "looks")
    check(pts[#pts].under and not pts[#pts].over, "throwaway marked in the graph")
    -- Unknown counts: nothing gone, never "0 listed".
    Pr.Record(SILK, 100, 200, now - 3 * 3600, 5, "Silk Cloth")
    Pr.Record(SILK, 100, nil, now - 2 * 3600, 5)
    Pr.Record(SILK, 100, 200, now - 3600, 5)
    pts = Chart.Data(SILK, "looks")
    check(pts[2].gone == nil and pts[3].gone == nil, "unknown count: no units gone: " .. tostring(pts[2].gone))
end

scenarios.econ_r2_usual_supply = function()
    local ns = setup()
    local M, Pr = ns.Market, ns.Prices
    local now = time()
    Pr.Record(LINEN, 100, nil, now - 86400, 3, "Linen Cloth")
    Pr.Record(LINEN, 100, 40, now, 3)
    local s = M.Stats(LINEN)
    check(s.avgN == nil and s.supplyTrend == nil, "one counted look is no usual supply: " .. tostring(s.avgN))
end

---------------------------------------------------------------------------
-- Price recording
---------------------------------------------------------------------------
scenarios.econ_r2_pages = function()
    local ns = setup()
    local Pr = ns.Prices
    local lists = {}
    function GetNumAuctionItems(kind) local l = lists[kind] or {} return #l, l.total or #l end
    function GetAuctionItemInfo(kind, i)
        local r = (lists[kind] or {})[i]
        if not r then return nil end
        return r[1], 0, r[2], 1, true, 1, "", 10, 1, r[3], 0, false, nil, r[4], nil, 0, r[5]
    end
    function QueryAuctionItems() end
    Pr.HookQueries()
    -- Page 1 of 2 only: the supply is unknown, not the part read.
    QueryAuctionItems("Salt", nil, nil, 0, nil, nil, false, true)
    lists.list = { { "Salt", 5, 50, "Al", SALT }, total = 2 }
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    check(Pr.Entry(SALT).n == nil and Pr.Ladder(SALT).partial, "page 1 of 2: supply unknown")
    -- Page 2, its event fired twice: counted once.
    QueryAuctionItems("Salt", nil, nil, 1, nil, nil, false, true)
    lists.list = { { "Salt", 5, 80, "Bo", SALT }, total = 2 }
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    local L = Pr.Ladder(SALT)
    check(L.units == 10 and not L.partial and Pr.Entry(SALT).n == 10, "each page once: " .. tostring(L.units) .. " units")
    QueryAuctionItems = nil
    -- A unit price under half a copper is 1c, never free.
    Pr.Record(LINEN, 9 / 20, 20, time(), 1, "Linen Cloth")
    check(Pr.Entry(LINEN).p == 0.45 and select(1, Pr.Get(LINEN)) == 0.45, "9c for 20: 0.45c each, not 0: " .. Pr.Entry(LINEN).p)
end

scenarios.econ_r2_partial_results = function()
    local ns = setup(16001)
    local Pr, Chart = ns.Prices, ns.PriceChart
    Pr.Record(LINEN, 100, 1000, time() - 3600, 20, "Linen Cloth")
    C_AuctionHouse = {
        GetNumCommoditySearchResults = function() return 2 end,
        GetCommoditySearchResultInfo = function(_, i) return ({ { unitPrice = 100, quantity = 50 }, { unitPrice = 110, quantity = 50 } })[i] end,
        HasFullCommoditySearchResults = function() return false end,
    }
    MOCK.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", LINEN)
    local e = Pr.Entry(LINEN)
    check(e.p == 100 and e.n == nil and e.a == nil, "part of the results: price kept, supply unknown: " .. tostring(e.n))
    local pts = Chart.Data(LINEN, "looks")
    check(pts[#pts].gone == nil, "no units gone from a partial read")
    C_AuctionHouse = nil
end

scenarios.econ_r2_bids = function()
    local ns = setup()
    local Pr = ns.Prices
    local rows = { { 5, 40, 0, 3 }, { 5, 40, 0, 3 }, { 5, 40, 0, 3 } }
    Pr.RecordBids(LINEN, rows, "legacy", time(), true)
    check(#Pr.Bids(LINEN).rows == 3, "three identical auctions are three: " .. #Pr.Bids(LINEN).rows)
    -- The same page read again adds nothing.
    Pr.RecordBids(LINEN, rows, "legacy", time(), true)
    check(#Pr.Bids(LINEN).rows == 3, "a re-read is not new auctions: " .. #Pr.Bids(LINEN).rows)
end

---------------------------------------------------------------------------
-- Sell rate and verdicts
---------------------------------------------------------------------------
scenarios.econ_r2_sell_rate = function()
    local ns = setup()
    local M = ns.Market
    local now = time()
    local silk, linen = MOCK.ItemLink(SILK, "Silk Cloth"), MOCK.ItemLink(LINEN, "Linen Cloth")
    -- 20 of 20 sold today: the "Sells" group.
    local list = {}
    for _ = 1, 20 do list[#list + 1] = { name = silk, count = 1, status = "sold", received = 90, t = now, ended = now } end
    -- 50 of 50 expired 120 days ago: still "doesn't sell", not a coin flip.
    local old = now - 120 * 86400
    for _ = 1, 50 do list[#list + 1] = { name = linen, count = 1, status = "expired", deposit = 1, t = old, ended = old } end
    auctions(ns, list)
    local ls = M.MySales(LINEN)
    check(ls.rate < 0.05, "old failures keep their word: " .. tostring(ls.rate))
    ns.MarketUI.Show("sellthrough")
    local items = ns.MarketUI.views.sellthrough.list.items
    local sells = false
    for _, it in ipairs(items) do if it.header and it.text:find("^Sells") then sells = true end end
    check(sells, "20 of 20 sold: listed under Sells")

    -- Linked and name-only records of one item: one tally.
    list = {}
    for _ = 1, 3 do list[#list + 1] = { name = silk, count = 1, status = "sold", received = 90, t = now, ended = now } end
    for _ = 1, 3 do list[#list + 1] = { name = "Silk Cloth", count = 1, status = "expired", deposit = 5, t = now, ended = now } end
    auctions(ns, list)
    local rows = {}
    for _, e in ipairs(M.SellThroughList()) do if e.name == "Silk Cloth" then rows[#rows + 1] = e end end
    check(#rows == 1 and rows[1].id == SILK and rows[1].sales.ended == 6 and rows[1].sales.depositLost == 15,
        "one row for Silk: " .. #rows)

    -- None sold: the text counts expired auctions, cancels apart.
    list = {}
    for _ = 1, 5 do list[#list + 1] = { name = linen, count = 1, status = "expired", t = now, ended = now } end
    for _ = 1, 4 do list[#list + 1] = { name = linen, count = 1, status = "cancelled", t = now, ended = now } end
    auctions(ns, list)
    local text = M.SellRateText(M.MySales(LINEN))
    check(text == "5 expired, none sold, 4 cancelled", "rate text: " .. tostring(text))
end

scenarios.econ_r2_deposit_over_vendor = function()
    local ns = setup()
    local M, Pr, Desk = ns.Market, ns.Prices, ns.AuctionDesk
    local now = time()
    -- A deposit over the vendor value: the unsold part loses money.
    local v = Desk.PostValue(95, 10, 0.5, 10, 1200)
    check(v == math.floor(0.5 * 950 + 0.5 * (100 - 1200)), "posting value with a deposit over vendor: " .. tostring(v))
    -- Your posts show a deposit of 20x the vendor price (260c on a 13c item); 2 of 10 sold.
    local linen = MOCK.ItemLink(LINEN, "Linen Cloth")
    local list = {}
    for _ = 1, 2 do list[#list + 1] = { name = linen, count = 1, status = "sold", deposit = 260, received = 190, t = now, ended = now } end
    for _ = 1, 8 do list[#list + 1] = { name = linen, count = 1, status = "expired", deposit = 260, t = now, ended = now } end
    auctions(ns, list)
    Pr.Record(LINEN, 200, 50, now, 5, "Linen Cloth")
    local value, how, info = M.SaleValue(LINEN)
    check(info.expected < 13 and how == "vendor" and value == 13, "the vendor is better: " .. tostring(info.expected) .. " " .. tostring(how))
end

---------------------------------------------------------------------------
-- Fishing and your bags
---------------------------------------------------------------------------
scenarios.econ_r2_fishing_unknown = function()
    local ns = setup()
    local F, Pr = ns.Fishing, ns.Prices
    Pr.Record(SILK, 100, 50, time(), 5, "Silk Cloth")
    local items = { [SILK] = 10, [777001] = 10 }
    local value, _, _, unknown = F.ItemsValue(items)
    check(value == 950 and unknown == 1, "one kind of unknown value: " .. tostring(value) .. " " .. tostring(unknown))
    local r = F.Rates({ n = 20, c = 20, s = 1800, it = items })
    check(r.partial and F.ValueText(r.gph, r.unknown):find("^at least"), "gold per hour is a lower bound")
    local line = F.SessionSummary({ zone = "Elwynn", s = 1800, c = 20, n = 20, it = items })
    check(line:find("at least"), "session summary says at least: " .. line)
end

scenarios.econ_r2_bound_copy = function()
    local ns = setup()
    local M, Pr = ns.Market, ns.Prices
    Pr.Record(SILK, 500, 50, time(), 5, "Silk Cloth")
    MOCK.bags[0][1] = MOCK.ItemLink(SILK, "Silk Cloth")
    MOCK.bagCounts["0:1"] = 5
    MOCK.bags[0][2] = MOCK.ItemLink(SILK, "Silk Cloth")
    MOCK.bagCounts["0:2"] = 3
    local oldIL, oldBound = ItemLocation, C_Item.IsBound
    ItemLocation = { CreateFromBagAndSlot = function(_, bag, slot) return { bag = bag, slot = slot } end }
    C_Item.IsBound = function(loc) return loc.slot == 2 end
    local ah, vendor
    for _, e in ipairs(M.SellList()) do
        if e.id == SILK and e.verdict == "ah" then ah = e end
        if e.id == SILK and e.bound then vendor = e end
    end
    check(ah and ah.n == 5 and vendor and vendor.n == 3 and vendor.verdict == "vendor", "bound copies only to a vendor")
    ItemLocation, C_Item.IsBound = oldIL, oldBound
end

---------------------------------------------------------------------------
-- Market movement
---------------------------------------------------------------------------
scenarios.econ_r2_move_day_counts = function()
    local ns = setup()
    local M, Pr = ns.Market, ns.Prices
    local now = time()
    local today = math.floor(now / 86400)
    -- Looks without a count; the daily summary says 50 then 20 units.
    for k = 3, 0, -1 do Pr.Record(LINEN, 100, nil, now - k * 86400, nil, "Linen Cloth") end
    Pr.Entry(LINEN).d = (today - 5) .. ":100:100:50," .. (today - 4) .. ":100:100:20"
    ns.Data.Changed("prices")
    local mv = M.Movement(LINEN)
    check(mv.key == "fast" and mv.market and math.abs(mv.market.avgListed - 35) < 1e-9, "turnover from the day counts: " .. mv.key)
    check(M.MoveKey(LINEN) == "fast", "list verdict the same: " .. M.MoveKey(LINEN))
    for _, l in ipairs(M.MovementLines(mv)) do check(not l:find("1 min"), "no absurd supply time: " .. l) end
end

scenarios.econ_r2_move_dense = function()
    local ns = setup()
    local M, Pr = ns.Market, ns.Prices
    local now = time()
    local today = math.floor(now / 86400)
    -- Looks every 15 minutes: units leave (20 -> 10), then a restock.
    local counts = {}
    for i = 0, 10 do counts[#counts + 1] = 20 - i end
    for _ = 1, 16 do counts[#counts + 1] = 15 end
    counts[#counts + 1], counts[#counts + 1] = 20, 20
    for i, n in ipairs(counts) do Pr.Record(LINEN, 100, n, now - (#counts - i) * 900, 3, "Linen Cloth") end
    Pr.Entry(LINEN).d = (today - 2) .. ":100:100:20," .. (today - 1) .. ":100:100:20"
    ns.Data.Changed("prices")
    check(M.Movement(LINEN).key ~= "dead" and M.MoveKey(LINEN) ~= "dead", "units seen leaving: not 'doesn't sell': "
        .. M.Movement(LINEN).key .. " / " .. M.MoveKey(LINEN))
end

---------------------------------------------------------------------------
-- Deals, posting, the desk
---------------------------------------------------------------------------
scenarios.econ_r2_own_listing = function()
    local ns = setup()
    local M, Pr = ns.Market, ns.Prices
    local now = time()
    for i = 1, 3 do Pr.Record(LINEN, 100, 30, now - (4 - i) * 86400, 3, "Linen Cloth") end
    Pr.Record(LINEN, 50, 15, now, 2)
    Pr.RecordLadder(LINEN, { { 50, 5, "Tester", true }, { 90, 10, "Al" } }, false, now)
    for _, d in ipairs(M.Deals()) do check(d.id ~= LINEN, "your own cheap listing is no deal") end
    -- Only yours listed: post at your own price, not 1c under it.
    for i = 1, 3 do Pr.Record(WOOL, 100, 30, now - (4 - i) * 86400, 3, "Wool Cloth") end
    Pr.Record(WOOL, 100, 5, now, 1)
    Pr.RecordLadder(WOOL, { { 100, 5, "Tester", true } }, false, now)
    local post, _, _, onlyMine = M.PostPrice(WOOL)
    check(post == 100 and onlyMine, "nobody to undercut: " .. tostring(post))
end

scenarios.econ_r2_desk_deals = function()
    local ns = setup()
    local Pr, Desk = ns.Prices, ns.AuctionDesk
    local now = time()
    for _, id in ipairs({ LINEN, SALT }) do
        for i = 1, 3 do Pr.Record(id, 100, 30, now - (4 - i) * 86400, 3, id == LINEN and "Linen Cloth" or "Salt") end
        Pr.Record(id, 70, 20, now, 2)
        Pr.RecordLadder(id, { { 70, 20, "Al" } }, false, now)
    end
    -- Linen: 1 sold of 5 (deposit 40 for 20): resold, an expected loss.
    local linen = MOCK.ItemLink(LINEN, "Linen Cloth")
    local list = { { name = linen, count = 20, status = "sold", deposit = 40, received = 1900, t = now, ended = now } }
    for _ = 1, 4 do list[#list + 1] = { name = linen, count = 20, status = "expired", deposit = 40, t = now, ended = now } end
    auctions(ns, list)
    local deals = Desk.Deals()
    check(#deals == 2 and deals[1].id == SALT and deals[2].id == LINEN and deals[2].totalGain < 0,
        "an expected loss goes last: " .. tostring(deals[1] and deals[1].id))
    ns.AuctionDeskUI.Show("overview")
    local loss = false
    for _, it in ipairs(ns.MarketUI.views.today.cards.deals.list.items) do
        -- The Deals card's row: the gain column shows the loss, signed.
        if it.id == LINEN and it.cols then loss = tostring(it.cols[1]):find("%-") ~= nil end
    end
    check(loss, "the loss is shown as a loss")
    -- Buy > Deals: the same loss in the Gain column, with the units and their cost.
    ns.MarketUI.ShowPage("buy", "deals")
    local row
    for _, it in ipairs(ns.MarketUI.views.deals.list.all) do
        if it.id == LINEN then row = ns.Style.ReadyRow(it) end
    end
    check(row and tostring(row.cols[1]):find("%-") and row.cols[3] == "20", "deals list: loss, 20 units: " .. tostring(row and row.cols[3]))
end

scenarios.econ_r2_listings = function()
    local ns = setup()
    local Pr, Desk = ns.Prices, ns.AuctionDesk
    local now = time()
    Pr.RecordLadder(SALT, { { 20, 5, "Al" }, { 20, 5, "Tester", true } }, false, now)
    Pr.RecordLadder(LINEN, { { 30, 5, "Tester", true }, { 50, 5, "Al" } }, false, now)
    TALODDB.ahOwned = TALODDB.ahOwned or {}
    TALODDB.ahOwned[ns.Gear.CharKey()] = { t = now, realm = Pr.RealmKey(), list = {
        { id = SALT, count = 5, unit = 20 }, { id = LINEN, count = 5, unit = 30 },
        { id = 7777, count = 2, unit = 500 }, { id = WOOL, count = 20, bid = 5000 } } }
    ns.Data.Changed("prices")
    Desk.Invalidate()
    local ok, data = pcall(Desk.Listings)
    check(ok, "listings build with a tie and an unknown deposit: " .. tostring(data))
    local by = {}
    for _, e in ipairs(data.list) do by[e.id] = e end
    check(by[SALT].standing.state == "tied" and by[LINEN].standing.state == "lowest" and by[7777].depositGuess == nil,
        "tied, lowest, deposit unknown")
    local sum = Desk.Summary()
    check(sum.unpriced == 1 and -- The cut once per auction, from its whole price.
        sum.value == math.floor(100 * 0.95) + math.floor(150 * 0.95) + math.floor(1000 * 0.95),
        "a listing without a buyout is not 0: " .. tostring(sum.unpriced))
    ns.AuctionDeskUI.Show("overview")
    local found = false
    for _, it in ipairs(ns.MarketUI.views.today.all) do
        if it.text and it.text:find("without a buyout") then found = true end
    end
    check(found, "Today says what has no buyout")
    ns.AuctionDeskUI.Show("listings")
    check(ns.MarketUI.state.view == "mine" and ns.MarketUI.state.mineFilter == "listed", "listings: My auctions, listed")
end

scenarios.econ_r2_standing = function()
    local ns = setup()
    local Pr, Desk = ns.Prices, ns.AuctionDesk
    local now = time()
    -- A month-old look and no ladder: nobody can say you are the lowest now.
    Pr.Record(WOOL, 100, 30, now - 30 * 86400, 3, "Wool Cloth")
    check(Desk.Standing(WOOL, 90).state == "unknown", "old look: unknown")
    -- Your 20 for 2009c (100.45c each) against Al's 20 for 2002c (100.10c): one basis.
    Pr.RecordLadder(LINEN, { { 2002 / 20, 20, "Al" }, { 2009 / 20, 20, "Tester", true } }, false, now)
    auctions(ns, { { name = MOCK.ItemLink(LINEN, "Linen Cloth"), count = 20, buyout = 2009, deposit = 60, status = "listed", t = now } })
    TALODDB.ahOwned = {}
    local e = Desk.Listings().list[1]
    check(e.unit == 100.45 and e.standing.state == "undercut", "exact like the ladder: " .. e.unit .. " " .. e.standing.state)
end

---------------------------------------------------------------------------
-- Gold ledger
---------------------------------------------------------------------------
local function linenWool(slots)
    for slot, x in pairs(slots) do
        MOCK.bags[0][slot] = MOCK.ItemLink(x[1], x[1] == LINEN and "Linen Cloth" or "Wool Cloth")
        MOCK.bagCounts["0:" .. slot] = x[2]
    end
end

scenarios.econ_r2_open_all = function()
    function GetInboxInvoiceInfo(i)
        local m = MOCK.inbox[i]
        if m and m.invoice then return m.invoice, m.item, m.player, m.bid, m.buyout, m.deposit, m.cut end
    end
    linenWool({ [1] = { LINEN, 20 }, [2] = { WOOL, 10 }, [3] = { LINEN, 20 } })
    MOCK.money = 100000
    local ns = setup()
    local c = ns.Economy.Char()
    local function changed() MOCK.FireEvent("PLAYER_MONEY") MOCK.FireEvent("BAG_UPDATE_DELAYED") MOCK.Tick(0.5) end
    local function post(slot, name, count, buyout, deposit)
        MOCK.sellItem = { name, count }
        PostAuction(math.floor(buyout / 2), buyout, 3, count, 1)
        MOCK.bags[0][slot] = nil
        MOCK.money = MOCK.money - deposit
        changed()
    end
    MOCK.FireEvent("AUCTION_HOUSE_SHOW")
    post(1, "Linen Cloth", 20, 2000, 60)
    post(2, "Wool Cloth", 10, 1000, 90)
    post(3, "Linen Cloth", 20, 2000, 60)
    MOCK.FireEvent("AUCTION_HOUSE_CLOSED")
    MOCK.Tick(4)
    local l1, wool, l2 = c.auctions[1], c.auctions[2], c.auctions[3]
    -- Two expired letters taken at once: one settle, both listings closed.
    MOCK.inbox[1] = { sender = "Auction House", subject = "Auction expired: Linen Cloth", items = { { LINEN, "Linen Cloth", 20 } } }
    MOCK.inbox[2] = { sender = "Auction House", subject = "Auction expired: Wool Cloth", items = { { WOOL, "Wool Cloth", 10 } } }
    MOCK.FireEvent("MAIL_SHOW")
    AutoLootMailItem(1)
    AutoLootMailItem(2)
    linenWool({ [1] = { LINEN, 20 }, [2] = { WOOL, 10 } })
    changed()
    check(l1.status == "expired" and wool.status == "expired", "both closed: " .. tostring(l1.status) .. " / " .. tostring(wool.status))
    -- A sale's money and a returned stack in one settle.
    MOCK.inbox[3] = { sender = "Auction House", subject = "Auction successful: Linen Cloth", money = 1960, invoice = "seller",
        item = "Linen Cloth", player = "Bob", bid = 2000, buyout = 2000, deposit = 60, cut = 100 }
    c.auctions[#c.auctions + 1] = { id = 99, t = time(), name = MOCK.ItemLink(WOOL, "Wool Cloth"), count = 10, deposit = 90, status = "listed" }
    MOCK.inbox[4] = { sender = "Auction House", subject = "Auction expired: Wool Cloth", items = { { WOOL, "Wool Cloth", 10 } } }
    TakeInboxMoney(3)
    AutoLootMailItem(4)
    linenWool({ [4] = { WOOL, 10 } })
    changed()
    check(l2.status == "sold" and c.auctions[#c.auctions].status == "expired", "sale and return in one settle: "
        .. tostring(l2.status) .. " / " .. tostring(c.auctions[#c.auctions].status))
    MOCK.FireEvent("MAIL_CLOSED")
end

scenarios.econ_r2_partial_sale = function()
    local ns = setup()
    local E = ns.Economy
    local c = E.Char()
    c.auctions = { { id = 1, t = time(), name = "Linen Cloth", count = 200, deposit = 600, status = "listed" } }
    local a = E.SettleListing(c, "Linen Cloth", "sold", 9800, nil, { count = 100 })
    check(a and a.count == 100 and a.deposit == 300 and c.auctions[1].status == "listed" and c.auctions[1].count == 100,
        "part sold, the rest still listed")
    E.SettleListing(c, "Linen Cloth", "sold", 9800, nil, { count = 100 })
    local t = E.AuctionTotals(c.auctions)
    check(t.sold == 2 and t.profit == 19000, "both parts counted: sold " .. tostring(t.sold) .. " profit " .. tostring(t.profit))
end

scenarios.econ_r2_own_names = function()
    local ns = setup()
    local E = ns.Economy
    TALODDB.economy["Buddy-OtherRealm"] = { log = {}, days = {} }
    check(not E.IsOwn("Buddy"), "a namesake on your realm is not your alt")
    check(E.IsOwn("Buddy-OtherRealm"), "your alt with its realm is")
    TALODDB.economy["Alt-" .. GetRealmName()] = { log = {}, days = {} }
    check(E.IsOwn("Alt"), "an alt on your realm")
end

scenarios.econ_r2_forever_names = function()
    local ns = setup(16001)
    local E = ns.Economy
    local me = E.Char()
    check(type(me.full) == "string" and me.full == ns.Guild.Me(), "your server name is noted: " .. tostring(me.full))
    TALODDB.economy["Alt-" .. GetRealmName()] = { log = {}, days = {}, full = "Alt Shadeleaf-" .. GetRealmName() }
    check(E.IsOwn("Alt Shadeleaf"), "mail from 'First Surname' of your alt")
    check(not E.IsOwn("Alt Otherkin"), "another family is not your alt")
end

---------------------------------------------------------------------------
-- Crafting and leveling costs
---------------------------------------------------------------------------
local function profSetup(rank)
    MOCK.skillLines = { { "Professions", true, true }, { "Tailoring", false, nil, rank or 60, 0, 0, 75 },
        { "Secondary Skills", true, true }, { "First Aid", false, nil, 1, 0, 0, 75 } }
    function GetItemCount() return 0 end
    return setup()
end

scenarios.econ_r2_route_after_bought = function()
    local ns = profSetup()
    local P, Pr = ns.Professions, ns.Prices
    local now = time()
    local BAR, FLUX, TUBE, BOLTS, GUN = 900010, 900011, 900001, 900002, 900100
    Pr.RecordLadder(BAR, { { 10, 2, "Al" }, { 2000, 100, "Bo" } }, false, now)
    Pr.RecordLadder(FLUX, { { 100, 10, "Al" } }, false, now)
    Pr.RecordLadder(TUBE, { { 500, 10, "Al" } }, false, now)
    Pr.RecordLadder(BOLTS, { { 100, 10, "Al" } }, false, now)
    local recipes = {
        [TUBE] = { { name = "Tube", makes = 1, reagents = { { BAR, 2 }, { FLUX, 1 } } } },
        [BOLTS] = { { name = "Bolts", makes = 1, reagents = { { BAR, 1 } } } },
        [GUN] = { { name = "Gun", makes = 1, reagents = { { TUBE, 1 }, { BOLTS, 1 } } } },
    }
    local function makers(id) return recipes[id] or {} end
    local cost = P.RouteCost(GUN, 1, makers, 0, 4)
    -- The tube made (2 bars at 10c + flux), then the bolts bought: their bar would be the third, at 2000c.
    check(cost == 20 + 100 + 100, "make or buy after what was bought: " .. tostring(cost))
end

scenarios.econ_r2_unpriced_material = function()
    local ns = profSetup()
    local P, Pr = ns.Professions, ns.Prices
    Pr.Record(900201, 3000, 50, time(), 5, "Pricey Herb")
    local list = P.Recipes("First Aid")
    local excluded = {}
    for _, r in ipairs(list) do excluded[r.id] = true end
    local A = { id = 990001, name = "Priced Salve", prof = "First Aid", skill = 1, colors = { 1, 50, 60, 70 }, up = 1,
        src = { "trainer" }, cost = 0, creates = 990101, reagents = { { 900201, 1 } } }
    local B = { id = 990002, name = "Unpriced Salve", prof = "First Aid", skill = 1, colors = { 1, 50, 60, 70 }, up = 1,
        src = { "trainer" }, cost = 0, creates = 990102, reagents = { { 900202, 1 } } }
    table.insert(list, 1, B)
    table.insert(list, 1, A)
    local plan = P.Plan("First Aid", 1, 3, { excluded = excluded, known = { ["Priced Salve"] = true, ["Unpriced Salve"] = true } })
    table.remove(list, 1) table.remove(list, 1)
    check(plan.steps[1] and plan.steps[1].recipe == A and plan.unpriced == 0,
        "a priced recipe beats one with a material nobody priced: " .. tostring(plan.steps[1] and plan.steps[1].recipe.name))
end

scenarios.econ_r2_training = function()
    local ns = profSetup()
    local P = ns.Professions
    -- At 75 with no maximum read: Journeyman is counted, not assumed trained.
    local plan = P.Plan("First Aid", 75, 80, {})
    check(plan.steps[1] and plan.steps[1].kind == "train" and plan.training == 500, "rank end: training counted: " .. tostring(plan.training))
    -- Expert First Aid comes from a book: its cost is unknown, never 0.
    plan = P.Plan("First Aid", 150, 155, { max = 150 })
    check(plan.unknownTraining == 1 and P.TotalText(plan):find("^at least") and not P.Summary(plan):find("training 0c"),
        "book rank: " .. P.Summary(plan))
end

scenarios.econ_r2_tracker_value = function()
    local ns = profSetup()
    local P, Pr, Track = ns.Professions, ns.Prices, ns.CraftTrack
    Pr.Record(2996, 300, 2, time(), 2, "Bolt of Linen Cloth")
    local bolt = ns.ProfessionData.recipes[2963]
    local plan = Track.Plan(bolt, 50)
    local v, src, _, vendor, listed = P.SellValue(2996)
    check(src == "ah" and listed == 2 and plan.value == 2 * v + 48 * (vendor or 0),
        "only what the market listed at the AH price: " .. tostring(plan.value))
end
