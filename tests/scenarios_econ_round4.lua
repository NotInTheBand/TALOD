-- Economy formulas, fourth pass: the price graph marks what the usual price
-- left out (per look, a day only when all its looks were); the usual price
-- one value per day; thin by units, not by one price row; no trend or fair
-- price from a browse row against exact looks; the graph's first look and
-- gaps of days; a posting sold in parts is one trial; a price per unit only
-- from known payments; a plan that pays shows its gain; sale value labels
-- that say what was counted; market time measured, not a day per pair; bids
-- per page of a search, partial searches unpriced, soonest end first;
-- repost prices to type; old live lists age out; deposits per duration;
-- relist under the wall's stack; cheapest whole-stack cover; units bought
-- earlier counted; non-exact searches; sale amounts without the deposit;
-- returned stacks summed; the loot value in whole copper.
local scenarios, T = ...
local check, boot, slash = T.check, T.boot, T.slash

local LINEN, WOOL, SILK, SALT = 2589, 2592, 4306, 4289
local CHEAP = 7777            -- an item a vendor buys for 1c

local function itemInfo()
    function GetItemInfo(id)
        if id == LINEN then return "Linen Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132889, 13, 7, 5, 0 end
        if id == WOOL then return "Wool Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132911, 33, 7, 5, 0 end
        if id == SILK then return "Silk Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132905, 38, 7, 5, 0 end
        if id == SALT then return "Salt", nil, 1, 5, 0, "Trade Goods", "Other", 20, "", 132891, 10, 7, 5, 0 end
        if id == CHEAP then return "Cheap Thing", nil, 1, 5, 0, "Trade Goods", "Other", 20, "", 132891, 1, 7, 5, 0 end
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

local function near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-6 end

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
-- Usual price and outliers
---------------------------------------------------------------------------
scenarios.econ_r4_chart_day_marks = function()
    local ns = setup()
    local Pr, Chart, M = ns.Prices, ns.PriceChart, ns.Market
    -- (1) 100c for 4 days, 250c twice on day 5 (an hour apart), then 100c: Stats keep the 250c looks.
    for d = 6, 3, -1 do Pr.Record(SILK, 100, 200, noon(ns, d), 20, "Silk Cloth") end
    Pr.Record(SILK, 250, 200, noon(ns, 2), 20)
    Pr.Record(SILK, 250, 200, noon(ns, 2) + 3600, 20)
    Pr.Record(SILK, 100, 200, noon(ns, 1), 20)
    check(M.Stats(SILK).over == 0, "stats keep the held rise")
    local pts = Chart.Data(SILK, "days")
    for _, pt in ipairs(pts) do check(not pt.over, "no day marked overpriced the usual price kept: " .. pt.p) end
    -- (2) 10c three days, then browse rows at 200c on two days: Stats leave them out, so does the graph.
    for d = 5, 3, -1 do Pr.Record(LINEN, 10, 100, noon(ns, d), 5, "Linen Cloth") end
    Pr.Record(LINEN, 200, 100, noon(ns, 2), 5, nil, true)
    Pr.Record(LINEN, 200, 100, noon(ns, 1), 5, nil, true)
    check(M.Stats(LINEN).over == 2, "stats: browse rows over")
    local marked = 0
    for _, pt in ipairs(Chart.Data(LINEN, "days")) do if pt.p == 200 and pt.over then marked = marked + 1 end end
    check(marked == 2, "both browse days marked overpriced: " .. marked)
    -- (3) 100c / 40 units for 4 days, then one auction of 5 at 10c: a throwaway in both modes.
    for d = 5, 2, -1 do Pr.Record(WOOL, 100, 40, noon(ns, d), 4, "Wool Cloth") end
    Pr.Record(WOOL, 10, 5, noon(ns, 1), 1)
    check(M.Stats(WOOL).underNow, "stats: thin under")
    local days = Chart.Data(WOOL, "days")
    local looks = Chart.Data(WOOL, "looks")
    check(days[#days].under and looks[#looks].under, "the day and the look marked under")
end

scenarios.econ_r4_usual_per_day = function()
    local ns = setup()
    local Pr, M = ns.Prices, ns.Market
    -- 100c seen 12 times in one evening (11 min apart), then 60c on each of the next 3 days.
    local evening = noon(ns, 4) + 6 * 3600
    for i = 0, 11 do Pr.Record(WOOL, 100, 200, evening + i * 660, 10, "Wool Cloth") end
    for d = 3, 1, -1 do Pr.Record(WOOL, 60, 200, noon(ns, d), 10) end
    local s = M.Stats(WOOL)
    check(s.usual == 60 and s.usualBefore == 60, "how often you looked does not weigh: usual " .. tostring(s.usual))
    check(near(s.trend, 0), "no fall against itself: " .. tostring(s.trend))
    for _, d in ipairs(M.Deals()) do check(d.id ~= WOOL, "60c for three days is no deal") end
end

scenarios.econ_r4_thin_by_units = function()
    local ns = setup(16001)
    local Pr, M = ns.Prices, ns.Market
    -- 100c with 40 units in 4 auctions for 4 days, then one price row of 200 units at 40c.
    for d = 5, 2, -1 do Pr.Record(SILK, 100, 40, noon(ns, d), 4, "Silk Cloth") end
    Pr.Record(SILK, 40, 200, noon(ns, 1), 1)
    local s = M.Stats(SILK)
    check(not s.underNow, "200 units in one row are the market, not a throwaway")
    check(M.FairPrice(SILK) == 40, "fair price is the drop: " .. tostring(M.FairPrice(SILK)))
    -- One auction with an unknown count is still thin.
    for d = 5, 2, -1 do Pr.Record(WOOL, 100, 40, noon(ns, d), 4, "Wool Cloth") end
    Pr.Record(WOOL, 10, nil, noon(ns, 1), 1)
    check(M.Stats(WOOL).underNow, "one auction, units unknown: thin")
end

scenarios.econ_r4_rough_now = function()
    local ns = setup()
    local Pr, M = ns.Prices, ns.Market
    Pr.Record(LINEN, 100, 200, noon(ns, 1), 10, "Linen Cloth")
    Pr.Record(LINEN, 2000, 20, noon(ns, 0), 1, nil, true)
    local s = M.Stats(LINEN)
    check(s.trend == nil, "no trend from a browse row against an exact look: " .. tostring(s.trend))
    local fair, _, odd = M.FairPrice(LINEN)
    check(fair == 100 and odd, "fair price: the usual from exact looks: " .. tostring(fair))
end

---------------------------------------------------------------------------
-- The graph
---------------------------------------------------------------------------
scenarios.econ_r4_chart_first_look = function()
    local ns = setup()
    local Pr, Chart = ns.Prices, ns.PriceChart
    local now = time()
    local link = MOCK.ItemLink(LINEN, "Linen Cloth")
    local list = {}
    for i = 1, 25 do list[i] = { name = link, count = 20, status = "sold", received = 1900, t = now - 91 * 86400, ended = now - 90 * 86400 } end
    auctions(ns, list)
    Pr.Record(LINEN, 100, 40, now - 86400, 4, "Linen Cloth")
    Pr.Record(LINEN, 100, 30, now, 3)
    local pts = Chart.Data(LINEN, "looks")
    check(pts[1].sold == nil and pts[2].sold == nil, "no sale between the looks shown: " .. tostring(pts[1].sold))
end

scenarios.econ_r4_chart_day_gap = function()
    local ns = setup()
    local Pr, Chart = ns.Prices, ns.PriceChart
    Pr.Record(LINEN, 100, 200, noon(ns, 20), 10, "Linen Cloth")
    Pr.Record(LINEN, 100, 190, noon(ns, 19), 10)
    Pr.Record(LINEN, 100, 20, noon(ns, 2), 2)
    local pts = Chart.Data(LINEN, "days")
    check(pts[2].gone == 10, "consecutive days: 10 gone")
    check(pts[3].gone == nil, "17 days apart: not 'the day before'")
end

---------------------------------------------------------------------------
-- Sell rate
---------------------------------------------------------------------------
scenarios.econ_r4_partial_posting = function()
    local ns = setup()
    local E, M = ns.Economy, ns.Market
    local now = time()
    local c = auctions(ns, { { id = 1, name = MOCK.ItemLink(LINEN, "Linen Cloth"), count = 100, deposit = 100, buyout = 10000,
        status = "listed", t = now - 7200 } })
    for _ = 1, 4 do E.SettleListing(c, "Linen Cloth", "sold", 960, nil, { count = 10 }) end
    E.SettleListing(c, "Linen Cloth", "expired", nil, nil, { count = 60 })
    ns.Data.Changed("economy")
    M.InvalidateSales()
    local s = M.MySales(LINEN)
    check(s.ended == 1 and s.sold == 1 and s.rate == nil, "one posting is one auction: ended " .. s.ended .. ", rate " .. tostring(s.rate))
    check(s.units == 40, "40 units sold")
    local ended = M.SaleCounts(LINEN)
    check(ended == 1, "the list counts it the same: " .. ended)
end

scenarios.econ_r4_per_unit_known = function()
    local ns = setup()
    local M = ns.Market
    local link = MOCK.ItemLink(LINEN, "Linen Cloth")
    auctions(ns, { { name = link, count = 20, status = "sold", received = 1900, deposit = 0, t = time() - 3600, ended = time() },
        { name = link, count = 20, status = "sold", t = time() - 3600, ended = time() } })
    check(M.MySales(LINEN).perUnit == 95, "95c each from the known sale: " .. tostring(M.MySales(LINEN).perUnit))
    auctions(ns, { { name = link, count = 20, status = "sold", t = time() - 3600, ended = time() } })
    check(M.MySales(LINEN).perUnit == nil, "no payment known: unknown")
end

---------------------------------------------------------------------------
-- Sale value
---------------------------------------------------------------------------
scenarios.econ_r4_plan_gain = function()
    MOCK.skillLines = { { "Professions", true, true }, { "Tailoring", false, nil, 1, 0, 0, 75 } }
    function GetItemCount() return 0 end
    local ns = setup()
    local P = ns.Professions
    local real = P.PlanFor
    P.PlanFor = function(...)
        local plan = real(...)
        plan.resale = plan.total + 283150
        plan.net = plan.total - plan.resale
        return plan
    end
    slash("plan tailoring 75")
    local text = ns.ProfessionsUI.views.plan.left.sub:GetText()
    check(text:find("gain") and text:find("28g 31s") and not text:find("= .-0c|r"), "the gain shown: " .. text)
    P.PlanFor = real
end

scenarios.econ_r4_value_labels = function()
    local ns = setup()
    local M = ns.Market
    local unknown = M.SaleValueText("ah", { rateUnknown = true, net = 95 })
    check(unknown:find("if it sells") and not unknown:find("x your sell rate"), "unknown rate: if it sells: " .. unknown)
    local known = M.SaleValueText("ah", { rate = 4 / 7, net = 95, deposit = 5 })
    check(known:find("57%% sell rate") and known:find("vendor price less"), "the formula in words: " .. known)
    check(M.SaleValueText("vendor", {}) == "the vendor price", "vendor")
end

---------------------------------------------------------------------------
-- Market movement
---------------------------------------------------------------------------
scenarios.econ_r4_movement_real_time = function()
    local ns = setup()
    local Pr, M = ns.Prices, ns.Market
    -- 23:50, 00:01 and 33 looks from 00:01 to ~06:25: 30 h observed, never "doesn't sell".
    local d1 = noon(ns, 3) - 12 * 3600
    Pr.Record(SILK, 100, 10, d1 + 23 * 3600 + 50 * 60, 2, "Silk Cloth")
    Pr.Record(SILK, 100, 10, d1 + 86400 + 60, 2)
    for i = 0, 32 do Pr.Record(SILK, 100, 10, d1 + 2 * 86400 + 60 + i * 700, 2) end
    local mv = M.Movement(SILK)
    check(mv.key ~= "dead" and M.MoveKey(SILK) ~= "dead", "30 h unchanged is not 2 days: " .. mv.key)
    -- 23:40 (40) and 00:20 (20): 40 minutes, not a day.
    local d = noon(ns, 2) - 12 * 3600
    Pr.Record(WOOL, 100, 40, d + 23 * 3600 + 40 * 60, 4, "Wool Cloth")
    Pr.Record(WOOL, 100, 20, d + 86400 + 20 * 60, 2)
    check(M.MarketMovement(WOOL) == nil and M.Movement(WOOL).key == "unknown" and M.MoveKey(WOOL) == "unknown",
        "40 minutes is no day's rate: " .. M.Movement(WOOL).key)
    -- Once a day for three days, nothing changed: still "doesn't sell".
    for k = 3, 0, -1 do Pr.Record(SALT, 20, 50, noon(ns, k), 5, "Salt") end
    check(M.Movement(SALT).key == "dead" and M.MoveKey(SALT) == "dead", "three days unchanged: doesn't sell")
end

---------------------------------------------------------------------------
-- Bids
---------------------------------------------------------------------------
scenarios.econ_r4_bid_reread = function()
    local ns = setup()
    local Pr, M = ns.Prices, ns.Market
    function QueryAuctionItems() end
    Pr.HookQueries()
    QueryAuctionItems("Linen Cloth", nil, nil, 0, nil, nil, false, true)
    local t = time()
    legacyPage({ { 20, 100, 5, 0, 0, false, "Bo", LINEN, 3, "Linen Cloth" }, { 20, 150, 5, 200, 0, false, "Al", LINEN, 3, "Linen Cloth" } })
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    -- You bid 100c; the page reloads 30 s later: Bo's row now asks 105c.
    MOCK.now = MOCK.now + 30
    legacyPage({ { 20, 100, 5, 0, 100, true, "Bo", LINEN, 3, "Linen Cloth" }, { 20, 150, 5, 200, 0, false, "Al", LINEN, 3, "Linen Cloth" } })
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    local b = Pr.Bids(LINEN)
    local bo = 0
    for _, r in ipairs(b.rows) do if r.count == 20 and not r.buyout then bo = bo + 1 check(r.next == 105, "the new next bid") end end
    check(bo == 1, "one auction, one row: " .. bo)
    check(b.t == t and b.rows[1].ends == t + 28800, "the look's time is its first read")
    QueryAuctionItems = nil
end

scenarios.econ_r4_bid_partial_search = function()
    local ns = setup()
    local Pr, M = ns.Prices, ns.Market
    function QueryAuctionItems() end
    Pr.HookQueries()
    QueryAuctionItems("cloth", nil, nil, 0, nil, nil, false, false)
    legacyPage({ { 20, 150, 5, 200, 0, false, "Al", LINEN, 3, "Linen Cloth" }, { 20, 160, 5, 0, 0, false, "Bo", LINEN, 3, "Linen Cloth" },
        { 20, 300, 5, 400, 0, false, "Cy", WOOL, 3, "Wool Cloth" } }, 120)
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    check(Pr.Bids(LINEN).partial, "a search with pages not read: partial")
    for _, d in ipairs(M.Bids()) do
        if d.id == LINEN then check(d.saving == nil, "no saving against part of a search: " .. tostring(d.saving)) end
    end
    QueryAuctionItems = nil
end

scenarios.econ_r4_bids_soonest = function()
    local ns = setup()
    local Pr, M = ns.Prices, ns.Market
    local now = time()
    Pr.Record(LINEN, 10, 100, now - 7 * 3600, 5, "Linen Cloth")
    Pr.Record(WOOL, 10, 100, now, 5, "Wool Cloth")
    -- Linen seen 7 h ago, 2 - 8 h left: ends within the hour. Wool seen now, 30 min - 2 h left.
    Pr.RecordBids(LINEN, { { 20, 100, 0, 3 } }, "legacy", now - 7 * 3600)
    Pr.RecordBids(WOOL, { { 20, 100, 0, 2 } }, "legacy", now)
    local list = M.Bids(now)
    check(#list == 2 and list[1].id == LINEN, "the one ending first, first: " .. tostring(list[1] and list[1].id))
end

---------------------------------------------------------------------------
-- Posting price and standing
---------------------------------------------------------------------------
scenarios.econ_r4_repost_text = function()
    local ns = setup()
    local Pr, Desk = ns.Prices, ns.AuctionDesk
    local now = time()
    Pr.RecordLadder(LINEN, { { 39999 / 20, 20, "Al" }, { 45000 / 20, 20, "Tester", true } }, false, now, true)
    local st = Desk.Standing(LINEN, Pr.Exact(45000 / 20))
    local text = ns.AuctionDeskUI.RepostText(st.repost, 20)
    check(st.state == "undercut" and text == "3g 99s 98c for 20", "the price to type, under Al's: " .. text)
end

scenarios.econ_r4_live_list_ages = function()
    local ns = setup(16001)
    local Desk = ns.AuctionDesk
    local now = time()
    TALODDB.ahOwned = TALODDB.ahOwned or {}
    TALODDB.ahOwned[ns.Gear.CharKey()] = { t = now - 30 * 3600, realm = ns.Prices.RealmKey(),
        list = { { id = SALT, name = "Salt", count = 5, unit = 2000, left = 3600 } } }
    ns.Data.Changed("prices")
    Desk.Invalidate()
    local sum = Desk.Summary()
    check(sum.listed == 0 and sum.overdue == 1 and sum.value == 0, "ended 29 h ago: not active: " .. sum.listed)
end

scenarios.econ_r4_deposit_duration = function()
    local ns = setup()
    local Desk = ns.AuctionDesk
    local link = MOCK.ItemLink(LINEN, "Linen Cloth")
    local list = {}
    for i = 1, 3 do list[#list + 1] = { name = link, count = 20, deposit = 39, duration = "12 h", status = "sold", t = time() } end
    for i = 1, 2 do list[#list + 1] = { name = link, count = 20, deposit = 156, duration = "48 h", status = "sold", t = time() } end
    auctions(ns, list)
    check(Desk.Deposit(LINEN, 20, 48) == 156 and Desk.Deposit(LINEN, 20, 12) == 39, "per duration: " .. tostring(Desk.Deposit(LINEN, 20, 48)))
    check(Desk.Deposit(LINEN, 20) == 39, "plans: your usual duration")
    local _, _, _, _, mixed = Desk.DepositRate()
    check(mixed, "posts of two durations")
end

---------------------------------------------------------------------------
-- Auction desk plans
---------------------------------------------------------------------------
scenarios.econ_r4_relist_under_stack = function()
    local ns = setup()
    local Pr, Desk = ns.Prices, ns.AuctionDesk
    local now = time()
    for d = 3, 1, -1 do Pr.Record(CHEAP, 6, 220, now - d * 86400, 11, "Cheap Thing") end
    Pr.Record(CHEAP, 4, 220, now, 11)
    local rows = {}
    for i = 1, 10 do rows[i] = { 4, 20, "Al" } end
    rows[11] = { 5, 20, "Bo" }
    Pr.RecordLadder(CHEAP, rows, false, now, true)
    Desk.Invalidate()
    local plan = Desk.Detail(CHEAP)
    check(#plan.steps == 1 and near(plan.steps[1].relist, 4.95), "relist 99c for 20 under Bo's 100c: "
        .. tostring(plan.steps[1] and plan.steps[1].relist))
end

---------------------------------------------------------------------------
-- Price recording and costs
---------------------------------------------------------------------------
scenarios.econ_r4_cheapest_cover = function()
    local ns = setup()
    local Pr = ns.Prices
    local now = time()
    Pr.RecordLadder(LINEN, { { 100, 19, "Al" }, { 100, 19, "Bo" }, { 105, 20, "Cy" } }, false, now, true)
    local c, got = Pr.LadderBuy(LINEN, 20)
    check(c == 2100 and got == 20, "the 20-stack alone: " .. tostring(c))
    Pr.RecordLadder(WOOL, { { 10, 15, "Al" }, { 10, 15, "Bo" }, { 10, 15, "Cy" }, { 11, 20, "Di" } }, false, now, true)
    check(Pr.LadderBuy(WOOL, 20) == 220, "220c, not 300c: " .. tostring(Pr.LadderBuy(WOOL, 20)))
end

scenarios.econ_r4_bought_earlier = function()
    MOCK.skillLines = { { "Professions", true, true }, { "Secondary Skills", true, true }, { "First Aid", false, nil, 1, 0, 0, 75 } }
    function GetItemCount() return 0 end
    local ns = setup()
    local P, Pr = ns.Professions, ns.Prices
    local now = time()
    Pr.RecordLadder(LINEN, { { 10, 20, "Al" } }, false, now, true)
    local cost, info = P.BuyCost(LINEN, 3, 3)
    check(cost == 0 and info.short == 0, "3 more from the stack's 17 spare: " .. tostring(cost))
    Pr.RecordLadder(LINEN, { { 10, 200, "Al" } }, false, now, true)
    check(P.BuyCost(LINEN, 30) == 2000 and P.BuyCost(LINEN, 40, 30) == 0, "a 200-stack covers both steps")
    local plan = P.Plan("First Aid", 1, 75, {})
    local linen
    for _, e in ipairs(plan.shopping) do if e.id == LINEN then linen = e end end
    check(linen and linen.buy <= 200 and linen.short == 0 and linen.cost == 2000, "one stack, fully priced: "
        .. tostring(linen and linen.short) .. " " .. tostring(linen and linen.cost))
end

scenarios.econ_r4_make_whole_amount = function()
    local ns = setup()
    local Pr, M = ns.Prices, ns.Market
    local now = time()
    local rows = {}
    for i = 1, 5 do rows[i] = { 10, 20, "Seller" .. i } end
    Pr.RecordLadder(LINEN, rows, false, now, true)
    Pr.Record(2996, 83, 10, now, 1, "Bolt of Linen Cloth")
    Pr.RecordLadder(2996, { { 83, 10, "Al" } }, false, now)
    local craft = M.CraftCost(2996)
    check(craft and craft.each == 200 and craft.spare, "one bolt pays for a stack: said so")
    local bolt
    for _, e in ipairs(M.CraftPlan({ reagents = { { 2996, 3 } } }).reagents) do if e.id == 2996 then bolt = e end end
    check(bolt and bolt.craft and bolt.craft.whole == 200 and bolt.craft.crafts == 3, "3 bolts from one stack: 200c, not 600c: "
        .. tostring(bolt and bolt.craft and bolt.craft.whole))
end

scenarios.econ_r4_name_search = function()
    local ns = setup()
    local Pr = ns.Prices
    function QueryAuctionItems() end
    Pr.HookQueries()
    QueryAuctionItems("Linen Cloth", nil, nil, 0, nil, nil, false, false)
    local rows = {}
    for i = 1, 50 do rows[i] = { 20, 150, 5, 200, 0, false, "Al", LINEN, 3, "Linen Cloth" } end
    legacyPage(rows, 60)
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    check(Pr.Entry(LINEN).a ~= 60, "the query's total is not Linen's count: " .. tostring(Pr.Entry(LINEN).a))
    QueryAuctionItems = nil
end

---------------------------------------------------------------------------
-- Gold ledger
---------------------------------------------------------------------------
scenarios.econ_r4_sold_for = function()
    local ns = setup()
    local t = ns.Economy.AuctionTotals({ { status = "sold", received = 10500, deposit = 1000 } })
    check(t.income == 9500 and t.profit == 9500, "sold for 95s after the cut, not 1g 5s: " .. t.income)
    t = ns.Economy.AuctionTotals({ { status = "sold" } })
    check(t.income == 0 and t.unpriced == 1, "an unknown payment counted apart")
end

scenarios.econ_r4_returned_stacks = function()
    local ns = setup(16001)
    local E = ns.Economy
    local items = {}
    for j = 1, 10 do items[j] = { LINEN, "Linen Cloth", 20 } end
    MOCK.inbox = { { sender = "Auction House", subject = "Auction expired: Linen Cloth", items = items } }
    local _, _, hint = E.DescribeMail(1)
    check(hint and hint.count == 200, "every stack summed: " .. tostring(hint and hint.count))
    local link = MOCK.ItemLink(LINEN, "Linen Cloth")
    local c = auctions(ns, { { id = 1, name = link, count = 200, deposit = 600, status = "listed", t = time() - 3600 },
        { id = 2, name = link, count = 20, deposit = 60, status = "listed", t = time() - 3600 } })
    E.SettleListing(c, "Linen Cloth", "expired", nil, nil, hint)
    check(c.auctions[1].status == "expired" and c.auctions[2].status == "listed", "the 200 listing closed")
    MOCK.inbox = {}
end

scenarios.econ_r4_loot_value = function()
    local ns = setup()
    local Pr = ns.Prices
    Pr.Record(LINEN, 1234, 10, time(), 2, "Linen Cloth")
    local lines
    local real = ns.Tooltip.Text
    ns.Tooltip.Text = function(_, l) lines = l end
    ns.EconomyUI.EntryTooltip(nil, { char = "Tester", e = { kind = "loot", t = time(), amount = 0,
        gained = { { MOCK.ItemLink(LINEN, "Linen Cloth"), 1 }, { MOCK.ItemLink(987654, "Odd Epic"), 1 } } } })
    ns.Tooltip.Text = real
    local ah
    for _, l in ipairs(lines) do if l:find("On the Auction House") then ah = l end end
    check(ah and not ah:find("%.") and ah:find("1 of 2 items priced"), "whole copper, partial said: " .. tostring(ah))
end
