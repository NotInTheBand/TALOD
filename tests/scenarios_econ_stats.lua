-- Price statistics and the Auction desk against standard formulas: robust
-- usual price (low median, odd looks either way), no yardstick from too few
-- looks, unknown supply never read as 0, partial pages, one look per visit,
-- the smoothed sell rate, stale deals, "doesn't sell" only when nothing
-- moved, posting under the cheapest auction that is not yours, and desk
-- profits valued at the usual price with your sell rate (else only "if it
-- all sells").
local scenarios, T = ...
local check, boot = T.check, T.boot

local function setup()
    function GetItemInfo(id)
        if id == 2589 then return "Linen Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132889, 13, 7, 5, 0 end
        if id == 2592 then return "Wool Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132911, 33, 7, 5, 0 end
        if id == 4306 then return "Silk Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132905, 38, 7, 5, 0 end
    end
    local ns = boot(11509)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    return ns
end

scenarios.econ_stats_robust_usual = function()
    local ns = setup()
    local M, Pr = ns.Market, ns.Prices
    local now = time()
    -- Five looks at ~100c, then one throwaway unit at 3c: marked, not the price.
    for i, p in ipairs({ 100, 105, 95, 100, 102 }) do Pr.Record(2589, p, 200, now - (7 - i) * 86400, 10, "Linen Cloth") end
    Pr.Record(2589, 3, 1, now, 1)
    local s = M.Stats(2589)
    check(s.underNow and s.usual == 100, "low odd look marked: usual " .. tostring(s.usual))
    local fair, _, odd = M.FairPrice(2589)
    check(fair == 100 and odd, "fair price is the usual one")
    check(M.PostPrice(2589) == 100, "post at the usual price, not 2c: " .. tostring(M.PostPrice(2589)))
    -- ...but it is still a deal (bought, not posted under).
    local found
    for _, d in ipairs(M.Deals()) do if d.id == 2589 then found = d end end
    check(found and found.s.p == 3, "a 3c unit is a deal")

    -- Two looks are no yardstick: [100c, 9999g] then 120c is no 4749g deal.
    Pr.Record(2592, 100, 50, now - 2 * 86400, 5, "Wool Cloth")
    Pr.Record(2592, 99990000, 1, now - 86400, 1)
    Pr.Record(2592, 120, 50, now, 5)
    s = M.Stats(2592)
    check(s.usualBefore == nil, "no usual-before from two looks: " .. tostring(s.usualBefore))
    for _, d in ipairs(M.Deals()) do check(d.id ~= 2592, "no deal against a two-look median") end

    -- Two clusters: the low median is a real price, not the mean of 120c and 9999g.
    Pr.Record(4306, 100, 50, now - 4 * 86400, 5, "Silk Cloth")
    Pr.Record(4306, 120, 50, now - 3 * 86400, 5)
    Pr.Record(4306, 99990000, 1, now - 2 * 86400, 1)
    Pr.Record(4306, 99990000, 1, now - 86400, 1)
    s = M.Stats(4306)
    check(s.usual == 100 and s.over == 2, "two clusters: usual " .. tostring(s.usual) .. ", marked " .. tostring(s.over))
end

scenarios.econ_stats_supply = function()
    local ns = setup()
    local M, Pr = ns.Market, ns.Prices
    local now = time()
    -- Unknown counts stay unknown: 200, ?, 200, ?, 200 over 27 h is no evidence of sales.
    for i = 0, 4 do Pr.Record(2589, 100, (i % 2 == 0) and 200 or nil, now - (4 - i) * 6.75 * 3600, 10, "Linen Cloth") end
    check(Pr.Looks(Pr.Entry(2589))[2].n == nil, "unknown count kept as unknown")
    local mv = M.Movement(2589)
    check(mv.key ~= "fast" and mv.key ~= "moves", "no sales invented from unknown counts: " .. mv.key)

    -- One look per visit: a sighting every 9 minutes for 2 hours is several looks.
    for i = 0, 13 do Pr.Record(2592, 100 - i, 50, now - 3 * 86400 + i * 540, 5, "Wool Cloth") end
    check(#Pr.Looks(Pr.Entry(2592)) >= 6, "the merge window does not slide: " .. #Pr.Looks(Pr.Entry(2592)))

    -- A browse row (rough) never lowers an exact look's price in the same visit.
    Pr.Record(4306, 400, 30, now, 5, "Silk Cloth")
    Pr.Record(4306, 40, 30, now + 60, 5, nil, true)
    check(Pr.Entry(4306).p == 400 and not Pr.Entry(4306).b, "exact look kept: " .. Pr.Entry(4306).p)

    -- "Doesn't sell" from the market only when nothing moved: 50 units at 20c for 3 days.
    for d = 3, 0, -1 do Pr.Record(4289, 20, 50, now - d * 86400 - 7200, 5, "Salt") end
    check(M.Movement(4289).key == "dead", "standing still: doesn't sell")
    -- Supply flat but the price moved (sales replaced by new posts): not "doesn't sell".
    for d = 3, 0, -1 do Pr.Record(2840, 20 + d, 50, now - d * 86400 - 7200, 5, "Copper Bar") end
    check(M.Movement(2840).key ~= "dead", "price moved: not dead, got " .. M.Movement(2840).key)
end

scenarios.econ_stats_pages = function()
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
    -- A broad search over several pages: page 1 holds part of each item's supply.
    QueryAuctionItems("cloth", nil, nil, 0, nil, nil, false, false)
    lists.list = { { "Linen Cloth", 20, 2000, "Al", 2589 }, { "Wool Cloth", 5, 500, "Bo", 2592 }, total = 140 }
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    check(Pr.Entry(2589) and Pr.Entry(2589).n == nil and Pr.Entry(2592).n == nil, "partial page: supply unknown")
    -- An exact search over pages: the supply adds up.
    QueryAuctionItems("Salt", nil, nil, 0, nil, nil, false, true)
    -- Two auctions on two pages (a page of one, for the test): the count is known once both are read.
    lists.list = { { "Salt", 50, 500, "Al", 4289 }, total = 2 }
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    QueryAuctionItems("Salt", nil, nil, 1, nil, nil, false, true)
    lists.list = { { "Salt", 40, 400, "Bo", 4289 }, total = 2 }
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    check(Pr.Entry(4289).n == 90, "pages summed: " .. tostring(Pr.Entry(4289).n))
    -- Per-unit prices kept exact (to 1/10000 copper), never 0: 20 for 2009c is 100.45c; 3 for 1c is 0.3333c.
    Pr.RecordLadder(2840, { { 2009 / 20, 20, "Al" }, { 1 / 3, 3, "Bo" } }, false, time())
    local L = Pr.Ladder(2840)
    check(L.tiers[1].u == 0.3333 and L.tiers[2].u == 100.45, "ladder units exact: " .. L.tiers[1].u .. " " .. L.tiers[2].u)
    QueryAuctionItems = nil
end

scenarios.econ_stats_sell_rate = function()
    local ns = setup()
    local M, Pr = ns.Market, ns.Prices
    local now = time()
    local key = ns.Gear.CharKey()
    TALODDB.economy[key] = TALODDB.economy[key] or { log = {}, days = {} }
    local link = MOCK.ItemLink(4306, "Silk Cloth")
    -- 2 of 2 sold is not "100%": too few to tell.
    TALODDB.economy[key].auctions = {
        { name = link, count = 1, status = "sold", received = 380, t = now, ended = now },
        { name = link, count = 1, status = "sold", received = 380, t = now, ended = now },
    }
    M.InvalidateSales()
    local s = M.MySales(4306)
    check(s.rate == nil and M.Movement(4306).source ~= "you", "two sales: no rate yet")
    -- A cancel is not a trial: 5 sold + 3 cancelled = 5 trials, 6/7.
    local list = TALODDB.economy[key].auctions
    for _ = 1, 3 do list[#list + 1] = { name = link, count = 1, status = "sold", received = 380, t = now, ended = now } end
    for _ = 1, 3 do list[#list + 1] = { name = link, count = 1, status = "cancelled", deposit = 5, t = now, ended = now } end
    M.InvalidateSales()
    s = M.MySales(4306)
    check(s.ended == 5 and math.abs(s.rate - 6 / 7) < 1e-9 and s.depositLost == 15, "cancels lose the deposit but are no trial: "
        .. tostring(s.rate))
    -- A deal seen three days ago is most likely gone: not listed.
    for i = 1, 4 do Pr.Record(2589, 100, 200, now - (8 - i) * 86400, 10, "Linen Cloth") end
    Pr.Record(2589, 40, 200, now - 3 * 86400, 10)
    for _, d in ipairs(M.Deals()) do check(d.id ~= 2589, "stale deal left out") end
    -- Your own auction is the lowest: post under the cheapest one that is not yours.
    Pr.Record(2592, 90, 30, now, 3, "Wool Cloth")
    Pr.RecordLadder(2592, { { 90, 5, "Tester", true }, { 120, 5, "Al" } }, false, now)
    check(M.PostPrice(2592) == 119, "post under the cheapest other seller: " .. tostring(M.PostPrice(2592)))
end

scenarios.econ_stats_desk = function()
    local ns = setup()
    local Pr, Desk = ns.Prices, ns.AuctionDesk
    local now = time()
    -- One look and a 500g unit on top: no usual price, so no profit at all.
    Pr.Record(4289, 10, 16, now, 3, "Salt")
    Pr.RecordLadder(4289, { { 10, 5, "Al" }, { 20, 10, "Bo" }, { 5000000, 1, "Cy" } }, false, now)
    Desk.Invalidate()
    local plan = Desk.Detail(4289)
    check(plan.usual == nil and plan.best == nil and plan.bestIfAll == nil and plan.all.profit == nil and plan.all.ifAll == nil,
        "no usual price: no profit figures")
    check(#Desk.Opportunities() == 0, "and no opportunity")
    -- Standing: a look over an hour old says nothing about now; a tie is a tie.
    Pr.RecordLadder(2589, { { 50, 5, "Al" }, { 60, 5, "Bo" } }, false, now - 7200)
    check(Desk.Standing(2589, 40).state == "unknown", "old look: unknown, not lowest")
    Pr.RecordLadder(2589, { { 50, 5, "Al" }, { 60, 5, "Bo" } }, false, now)
    check(Desk.Standing(2589, 50).state == "tied" and Desk.Standing(2589, 40).state == "lowest", "tied at the same price")
    -- Deposit unknown without a vendor price: never 0.
    check(Desk.Deposit(999999, 5) == nil, "unknown deposit")
    -- Posting value: r x units x net + (1 - r) x (units x vendor - deposit).
    local v, all = Desk.PostValue(95, 10, 0.5, 13, 20)
    check(v == math.floor(0.5 * 950 + 0.5 * (130 - 20)) and all == 950, "posting value: " .. tostring(v))
    check(select(1, Desk.PostValue(95, 10, nil, 13, 20)) == nil, "no rate: no expected value")
end
