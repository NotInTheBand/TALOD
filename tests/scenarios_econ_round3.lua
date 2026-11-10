-- Economy formulas, third pass: a lasting, well-supplied rise is the price
-- (not "overpriced"); trend against the earlier looks and their true median;
-- usual supply a median; prices per unit kept exact (stacks undercut by 1c a
-- stack, ladders summed once, bids measured exactly, standing not merged);
-- whole stacks bought whole; the cut taken once per auction; supply counted
-- the same way by every read, unknown quantities never 0; the player's own
-- days; sell rate words and numbers on one scale; market movement from what
-- was measured; the Sell tab and crafting lines saying what they count; the
-- desk's best reset among those worth doing; deposits that add up; gold of
-- characters not yet seen not counted as a gain.
local scenarios, T = ...
local check, boot = T.check, T.boot

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

-- Your auction log (current character), replaced; memos rebuilt.
local function auctions(ns, list)
    local c = ns.Economy.Char()
    c.auctions = list
    ns.Data.Changed("economy")
    ns.Market.InvalidateSales()
    ns.AuctionDesk.Invalidate()
    return c
end

local function near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-6 end

---------------------------------------------------------------------------
-- Usual price, trend and supply
---------------------------------------------------------------------------
scenarios.econ_r3_lasting_rise = function()
    local ns = setup()
    local M, Pr = ns.Market, ns.Prices
    local now = time()
    -- 100c for four days, then 250c for three, each with 200 units in 20 auctions.
    for i, p in ipairs({ 100, 100, 100, 100, 250, 250, 250 }) do Pr.Record(SILK, p, 200, now - (7 - i) * 86400, 20, "Silk Cloth") end
    local s = M.Stats(SILK)
    check(not s.overNow and s.over == 0, "a lasting, supplied rise is not overpriced: over " .. tostring(s.over))
    local fair, _, odd = M.FairPrice(SILK)
    check(fair == 250 and not odd, "fair price is the market's now: " .. tostring(fair))
    -- Stacks of 10 at 250c each: 1c under the stack.
    check(near(M.PostPrice(SILK), 249.9), "post under 250c, not at 100c: " .. tostring(M.PostPrice(SILK)))
    local v, how = M.SaleValue(SILK)
    check(how == "ah" and near(v, 250 * 0.95), "sale value at the price now: " .. tostring(v))
    -- 10, 10, 10, 12, 22, 25, 25, 25 with 50 units each: 25c is the price, the AH beats the 13c vendor.
    for i, p in ipairs({ 10, 10, 10, 12, 22, 25, 25, 25 }) do Pr.Record(LINEN, p, 50, now - (8 - i) * 86400, 5, "Linen Cloth") end
    s = M.Stats(LINEN)
    check(s.base == 12 and s.over == 0 and M.FairPrice(LINEN) == 25, "25c held three looks: " .. tostring(M.FairPrice(LINEN)))
    v, how = M.SaleValue(LINEN)
    check(how == "ah" and near(v, 23.75), "AH 23.75c, not the vendor's 13c: " .. tostring(v) .. " " .. tostring(how))
    -- One well-supplied jump alone is still overpriced (it may be a mistake).
    for i = 1, 5 do Pr.Record(WOOL, 100, 200, now - (6 - i) * 86400, 20, "Wool Cloth") end
    Pr.Record(WOOL, 250, 200, now, 20)
    check(M.Stats(WOOL).overNow and M.FairPrice(WOOL) == 100, "a lone jump: overpriced")
end

scenarios.econ_r3_trend_baseline = function()
    local ns = setup()
    local M, Pr = ns.Market, ns.Prices
    local now = time()
    -- Two looks: the earlier one is the yardstick, a drop shows.
    Pr.Record(LINEN, 100, 200, now - 86400, 10, "Linen Cloth")
    Pr.Record(LINEN, 50, 200, now, 10)
    check(near(M.Stats(LINEN).trend, -0.5), "halved: -50%, not 0: " .. tostring(M.Stats(LINEN).trend))
    Pr.Record(WOOL, 50, 200, now - 86400, 10, "Wool Cloth")
    Pr.Record(WOOL, 100, 200, now, 10)
    check(near(M.Stats(WOOL).trend, 1), "doubled: +100%")
    -- 100, 100, 45, 45: against 100 (the earlier looks), not 45 (itself).
    for i, p in ipairs({ 100, 100, 45, 45 }) do Pr.Record(SILK, p, 200, now - (4 - i) * 86400, 10, "Silk Cloth") end
    check(near(M.Stats(SILK).trend, -0.55), "-55%: " .. tostring(M.Stats(SILK).trend))
    -- 100, 200, 200, 100: the true median of the earlier ones (200), the price fell by half.
    for i, p in ipairs({ 100, 200, 200, 100 }) do Pr.Record(SALT, p, 200, now - (4 - i) * 86400, 10, "Salt") end
    check(near(M.Stats(SALT).trend, -0.5), "-50%: " .. tostring(M.Stats(SALT).trend))
    -- Three looks: the mean of the middle two of the earlier pair (150), not the low one.
    Pr.Record(CHEAP, 100, 200, now - 2 * 86400, 10, "Cheap Thing")
    Pr.Record(CHEAP, 200, 200, now - 86400, 10)
    Pr.Record(CHEAP, 150, 200, now, 10)
    check(near(M.Stats(CHEAP).trend, 0), "150c against 100c and 200c: 0%: " .. tostring(M.Stats(CHEAP).trend))
    -- One look: nothing to compare with.
    Pr.Record(2840, 20, 50, now, 5, "Copper Bar")
    check(M.Stats(2840).trend == nil, "one look: no trend")
end

scenarios.econ_r3_supply_median = function()
    local ns = setup()
    local M, Pr = ns.Market, ns.Prices
    local now = time()
    for i, n in ipairs({ 20, 20, 20, 20, 2000, 20 }) do Pr.Record(LINEN, 100, n, now - (6 - i) * 86400, 4, "Linen Cloth") end
    local s = M.Stats(LINEN)
    check(s.avgN == 20 and near(s.supplyTrend, 0), "one dump is not the usual supply: " .. tostring(s.avgN) .. " " .. tostring(s.supplyTrend))
    -- The latest look is measured against the earlier ones, not itself.
    for i, n in ipairs({ 100, 100, 300 }) do Pr.Record(WOOL, 100, n, now - (3 - i) * 86400, 4, "Wool Cloth") end
    check(near(M.Stats(WOOL).supplyTrend, 2), "+200%: " .. tostring(M.Stats(WOOL).supplyTrend))
end

---------------------------------------------------------------------------
-- Exact prices per unit
---------------------------------------------------------------------------
scenarios.econ_r3_stack_prices = function()
    local ns = setup()
    local M, Pr, P = ns.Market, ns.Prices, ns.Professions
    local now = time()
    -- Stacks of 20 at 39c (1.95c each): undercut the stack by 1c (38c for 20), not 1c each.
    for d = 2, 0, -1 do Pr.Record(LINEN, 39 / 20, 60, now - d * 86400, 3, "Linen Cloth") end
    Pr.RecordLadder(LINEN, { { 39 / 20, 20, "Al" }, { 39 / 20, 20, "Bo" }, { 39 / 20, 20, "Cy" } }, false, now, true)
    check(Pr.Entry(LINEN).p == 1.95, "1.95c each: " .. Pr.Entry(LINEN).p)
    local post = M.PostPrice(LINEN)
    check(near(post * 20, 38), "post 38c for 20: " .. tostring(post))
    -- 10 stacks of 20 at 21c: 200 units cost 210c, not 400c.
    local rows = {}
    for i = 1, 10 do rows[i] = { 21 / 20, 20, "Seller" .. i } end
    Pr.Record(SALT, 21 / 20, 200, now, 10, "Salt")
    Pr.RecordLadder(SALT, rows, false, now, true)
    check(Pr.LadderBuy(SALT, 200) == 210 and P.BuyCost(SALT, 200) == 210, "200 for 210c: " .. tostring(Pr.LadderBuy(SALT, 200)))
    check(select(1, Pr.Get(SALT)) == 1.05, "1.05c each")
    -- The daily summary keeps the exact price too.
    Pr.Record(SALT, 2, 200, now + 2 * 86400, 10)
    local days = Pr.History(SALT, "days")
    check(days[1].p == 1.05, "day summary exact: " .. tostring(days[1].p))
end

scenarios.econ_r3_whole_stacks = function()
    local ns = setup()
    local Pr, P = ns.Prices, ns.Professions
    local now = time()
    -- The legacy list sells whole auctions: 3 Linen from one stack of 20 cost the stack.
    Pr.RecordLadder(LINEN, { { 10, 20, "Al" } }, false, now, true)
    local cost, info = P.BuyCost(LINEN, 3)
    check(cost == 200 and info.surplus == 17, "3 of a 20-stack: 200c, 17 spare: " .. tostring(cost) .. " " .. tostring(info.surplus))
    -- A stack of 20 at 10c and five singles at 15c: 5 units cost the singles (75c).
    Pr.RecordLadder(LINEN, { { 10, 20, "Al" }, { 15, 1, "Bo" }, { 15, 1, "Bo" }, { 15, 1, "Cy" }, { 15, 1, "Cy" }, { 15, 1, "Di" } },
        false, now, true)
    local c5, got5 = Pr.LadderBuy(LINEN, 5)
    check(c5 == 75 and got5 == 5, "5 singles, not a part of the stack: " .. tostring(c5))
    local c25, got25 = Pr.LadderBuy(LINEN, 25)
    check(c25 == 275 and got25 == 25, "the stack and five singles: " .. tostring(c25))
    -- A commodity (bought by the unit) still splits.
    Pr.RecordLadder(WOOL, { { 10, 20, "Al" } }, false, now)
    check(Pr.LadderBuy(WOOL, 3) == 30, "a commodity sells by the unit")
end

scenarios.econ_r3_cut_once = function()
    local ns = setup()
    local M, Pr, Desk = ns.Market, ns.Prices, ns.AuctionDesk
    local now = time()
    check(near(M.Net(2), 1.9) and M.Net(1) > 0, "the cut is not floored per unit: " .. M.Net(2))
    -- At 2c a unit against a 1c vendor, the AH pays more.
    Pr.Record(CHEAP, 2, 100, now, 5, "Cheap Thing")
    local v, how = M.SaleValue(CHEAP)
    check(how == "ah" and near(v, 1.9), "AH, not the vendor: " .. tostring(how))
    -- Relisting 200 at 2c: 380c after the cut, not 200c.
    check(select(2, Desk.PostValue(M.Net(2), 200)) == 380, "desk: cut on the total: " .. tostring(select(2, Desk.PostValue(M.Net(2), 200))))
    -- Your listing of 20 for 99c is worth 94c after the cut (once, on the whole auction).
    TALODDB.ahOwned = {}
    auctions(ns, { { name = MOCK.ItemLink(LINEN, "Linen Cloth"), count = 20, buyout = 99, deposit = 6, status = "listed", t = now } })
    local e = Desk.Listings().list[1]
    check(e.value == 94, "listing worth 94c: " .. tostring(e.value))
    auctions(ns, { { name = MOCK.ItemLink(LINEN, "Linen Cloth"), count = 20, buyout = 20, deposit = 6, status = "listed", t = now } })
    check(Desk.Listings().list[1].value == 19, "20 at 1c each: 19c, not 0")
end

scenarios.econ_r3_standing_exact = function()
    local ns = setup()
    local Pr, Desk = ns.Prices, ns.AuctionDesk
    local now = time()
    -- Al's 20 for 81c (4.05c) and yours 20 for 99c (4.95c): Al is cheaper, not "tied".
    Pr.RecordLadder(LINEN, { { 81 / 20, 20, "Al" }, { 99 / 20, 20, "Tester", true } }, false, now, true)
    local st = Desk.Standing(LINEN, Pr.Exact(99 / 20))
    check(st.state == "undercut" and st.ahead == 20, "undercut by Al: " .. st.state)
    check(near(st.repost * 20, 80), "repost 1c under his stack (80c for 20): " .. tostring(st.repost))
    -- The other way round: you are the lowest.
    Pr.RecordLadder(WOOL, { { 81 / 20, 20, "Tester", true }, { 99 / 20, 20, "Al" } }, false, now, true)
    check(Desk.Standing(WOOL, Pr.Exact(81 / 20)).state == "lowest", "lowest")
end

scenarios.econ_r3_bids_exact = function()
    local ns = setup()
    local M, Pr = ns.Market, ns.Prices
    local now = time()
    -- Al's stack of 20 for 101c (5.05c each); Bo's bid-only 20 takes 100c: it saves 1c, not 20c.
    Pr.Record(LINEN, 101 / 20, 40, now, 2, "Linen Cloth")
    Pr.RecordBids(LINEN, { { 20, 101, 101, 3 }, { 20, 100, 0, 3 } }, "legacy", now)
    local row
    for _, b in ipairs(M.Bids(now)) do if b.id == LINEN then row = b end end
    check(row and row.saving == 1 and row.pct < 0.02, "saves 1c: " .. tostring(row and row.saving))
    -- Pages merged against the exact cheapest buyout: 5.5c each (110c for 20) keeps Bo's 100c, drops Cy's 112c.
    Pr.RecordBids(WOOL, { { 20, 110, 110, 3 }, { 20, 100, 0, 3 } }, "legacy", now, true)
    Pr.RecordBids(WOOL, { { 20, 112, 0, 3 } }, "legacy", now + 5, true)
    local b = Pr.Bids(WOOL, now + 5)
    check(b and #b.rows == 1 and b.rows[1].next == 100, "a bid over the buyout is no bid to make: " .. (b and #b.rows or 0))
    check(b.low == 5.5, "the cheapest buyout kept exact: " .. tostring(b.low))
end

---------------------------------------------------------------------------
-- Price recording
---------------------------------------------------------------------------
scenarios.econ_r3_item_results_supply = function()
    local ns = setup(16001)
    local Pr, M = ns.Prices, ns.Market
    local results = { { quantity = 5, buyoutAmount = 500 }, { quantity = 10, buyoutAmount = 0, minBid = 300 } }
    C_AuctionHouse = {
        GetNumItemSearchResults = function() return #results end,
        GetItemSearchResultInfo = function(_, i) return results[i] end,
        HasFullItemSearchResults = function() return true end,
    }
    Pr.ReadItemResults({ itemID = LINEN })
    local e = Pr.Entry(LINEN)
    check(e.n == 15 and e.a == 2, "bid-only units are supply too: " .. tostring(e.n))
    -- A quantity that cannot be read: the supply is unknown, not short.
    results[2].quantity = nil
    Pr.Record(WOOL, 100, 50, time() - 86400, 2, "Wool Cloth")
    Pr.ReadItemResults({ itemID = WOOL })
    check(Pr.Entry(WOOL).n == nil, "unreadable quantity: supply unknown: " .. tostring(Pr.Entry(WOOL).n))
    C_AuctionHouse = nil
end

scenarios.econ_r3_commodity_unknown_quantity = function()
    local ns = setup(16001)
    local Pr, M, Chart = ns.Prices, ns.Market, ns.PriceChart
    local now = time()
    Pr.Record(LINEN, 100, 100, now - 2 * 86400, 5, "Linen Cloth")
    Pr.Record(LINEN, 100, 100, now - 86400, 5)
    C_AuctionHouse = {
        GetNumCommoditySearchResults = function() return 1 end,
        GetCommoditySearchResultInfo = function() return { unitPrice = 100 } end,
        HasFullCommoditySearchResults = function() return true end,
    }
    MOCK.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", LINEN)
    check(Pr.Entry(LINEN).n == nil, "no quantity read: unknown, not 0: " .. tostring(Pr.Entry(LINEN).n))
    check(M.Stats(LINEN).supplyTrend == nil, "no supply trend from an unknown")
    local pts = Chart.Data(LINEN, "looks")
    check(pts[#pts].gone == nil and not table.concat(Chart.PointLines(pts[#pts], "looks"), "\n"):find("Listed: 0"), "graph: nothing gone")
    C_AuctionHouse = nil
end

scenarios.econ_r3_local_days = function()
    local ns = setup()
    -- A player at UTC-7: the day ends at local midnight, not at 5 pm.
    local realDate = date
    date = function(fmt, t)
        t = t or time()
        if type(fmt) == "string" and fmt:sub(1, 1) ~= "!" then return realDate("!" .. fmt, t - 7 * 3600) end
        return realDate(fmt, t)
    end
    local Pr, Chart = ns.Prices, ns.PriceChart
    local now = time()
    -- 3 pm and 6 pm on one local evening, across UTC midnight.
    local utcMidnight = math.floor(now / 86400) * 86400 - 3 * 86400
    Pr.Record(LINEN, 100, 50, utcMidnight - 2 * 3600, 5, "Linen Cloth")
    Pr.Record(LINEN, 90, 40, utcMidnight + 3600, 5)
    local days = Pr.History(LINEN, "days")
    check(#days == 1 and days[1].p == 90 and days[1].hi == 100, "one evening, one day: " .. #days)
    check(date("%H", days[1].t) == "12" and date("%d", days[1].t) == date("%d", utcMidnight - 2 * 3600), "drawn at local noon of that day")
    check(Pr.DayKey(utcMidnight - 2 * 3600) == Pr.DayKey(utcMidnight + 3600), "one day key")
    date = realDate
end

---------------------------------------------------------------------------
-- Sell rate and verdicts
---------------------------------------------------------------------------
scenarios.econ_r3_sales_per_unit = function()
    local ns = setup()
    local M = ns.Market
    -- 20 sold for 2000c: cut 100c, the letter pays 1940c with the 40c deposit back.
    auctions(ns, { { name = MOCK.ItemLink(LINEN, "Linen Cloth"), count = 20, status = "sold", received = 1940, deposit = 40,
        t = time() - 3600, ended = time() } })
    check(M.MySales(LINEN).perUnit == 95, "95c each, not 97c: " .. tostring(M.MySales(LINEN).perUnit))
end

scenarios.econ_r3_rate_words = function()
    local ns = setup()
    local M = ns.Market
    local line = M.SellChanceLines({ ended = 6, sold = 5, rate = 0.74529, hard = false, recentEnded = 6, recentSold = 5 })
    check(line:find("74%%") and line:find("sells sometimes"), "under 75%: not 'sells well': " .. line)
    line = M.SellChanceLines({ ended = 99, sold = 49, rate = 50 / 101, hard = true, recentEnded = 99, recentSold = 49, unsold = 50 })
    check(line:find("49%%") and line:find("hard to sell"), "hard to sell is under 50%: " .. line)
    check(M.RatePct(0.75) == 75 and M.RatePct(0.5) == 50 and M.RatePct(0.4999) == 49, "pct on the verdict's side")
    -- 2 sold, 3 expired: hard to sell, so "slow" too (one scale).
    local link = MOCK.ItemLink(LINEN, "Linen Cloth")
    local list = {}
    for i = 1, 5 do list[i] = { name = link, count = 1, status = i <= 2 and "sold" or "expired", t = time() - 3600, ended = time() } end
    auctions(ns, list)
    local s = M.MySales(LINEN)
    check(s.hard and M.Movement(LINEN).key == "slow" and M.MoveKey(LINEN) == "slow", "hard to sell and slow: " .. M.Movement(LINEN).key)
end

---------------------------------------------------------------------------
-- Market movement
---------------------------------------------------------------------------
scenarios.econ_r3_movement_measured = function()
    local ns = setup()
    local M, Pr = ns.Market, ns.Prices
    local now = time()
    -- One unit in 3 days: "~0.3 a day", never "~0".
    for i, n in ipairs({ 2, 2, 2, 1 }) do Pr.Record(LINEN, 100, n, now - (4 - i) * 86400, n, "Linen Cloth") end
    local lines = table.concat(M.MovementLines(M.Movement(LINEN)), "\n")
    check(lines:find("~0.3 a day"), "the rate as measured: " .. lines)
    -- Supply from the looks that were measured: weeks-old looks of 200 are not today's.
    for d = 30, 5, -5 do Pr.Record(WOOL, 100, 200, now - d * 86400, 10, "Wool Cloth") end
    Pr.Record(WOOL, 100, 10, now - 12 * 3600, 2)
    Pr.Record(WOOL, 100, 5, now, 1)
    local mv = M.Movement(WOOL)
    check(mv.market and near(mv.market.avgListed, 7.5) and mv.key == "fast", "10 then 5 in 12 h: fast: " .. mv.key)
    check(M.MoveKey(WOOL) == "fast", "the list says the same")
    -- One unit gone in 12 h is no evidence of "moves fast".
    Pr.Record(SILK, 100, 2, now - 12 * 3600, 2, "Silk Cloth")
    Pr.Record(SILK, 100, 1, now, 1)
    check(M.Movement(SILK).key == "unknown" and M.MoveKey(SILK) == "unknown", "one unit gone: not enough data: " .. M.Movement(SILK).key)
end

---------------------------------------------------------------------------
-- Sale value: the Sell tab, the deposit, crafting
---------------------------------------------------------------------------
scenarios.econ_r3_sell_tab = function()
    MOCK.bags[0][1] = MOCK.ItemLink(SALT, "Salt")
    MOCK.bagCounts["0:1"] = 200
    local ns = setup()
    local M, Pr = ns.Market, ns.Prices
    local now = time()
    Pr.Record(SALT, 20, 100, now, 5, "Salt")
    -- 5 sold, 5 expired: rate 1/2; deposits 2c for one (20% of the 10c vendor price).
    local link = MOCK.ItemLink(SALT, "Salt")
    local list = {}
    for i = 1, 10 do list[i] = { name = link, count = 1, deposit = 2, status = i <= 5 and "sold" or "expired", t = now - 3600, ended = now } end
    auctions(ns, list)
    local v, how, info = M.SaleValue(SALT)
    check(how == "ah" and near(v, 0.5 * 19 + 0.5 * (10 - 2)) and near(info.deposit, 2), "expected 13.5c: " .. tostring(v))
    ns.MarketUI.Show("sell")
    local view = ns.MarketUI.views.sell
    local row
    for _, it in ipairs(view.list.items or {}) do if it.id == SALT then row = it end end
    check(row and tostring(row.cols[3]):find("27s"), "the row counts what the total counts: " .. tostring(row and row.cols[3]))
    check(not view:Footer():find("deposit not counted"), "the footer says what is counted")
    -- The deposit's share is not rounded per unit: 15% of 10c is 1.5c, not 2c.
    for _, a in ipairs(list) do a.deposit = nil end
    auctions(ns, list)
    v, how, info = M.SaleValue(SALT)
    check(near(info.deposit, 1.5) and near(v, 0.5 * 19 + 0.5 * 8.5), "1.5c deposit share: " .. tostring(info.deposit))
end

scenarios.econ_r3_craft_lines = function()
    MOCK.skillLines = { { "Professions", true, true }, { "Tailoring", false, nil, 75, 0, 0, 75 } }
    for i = 1, 3 do
        MOCK.bags[0][i] = MOCK.ItemLink(WOOL, "Wool Cloth")
        MOCK.bagCounts["0:" .. i] = 30
    end
    local ns = setup()
    local M, Pr = ns.Market, ns.Prices
    local now = time()
    local BOLT = 2997
    local recipe = ns.ProfessionData.recipes[2964]
    Pr.Record(WOOL, 15, 200, now, 1, "Wool Cloth")
    Pr.RecordLadder(WOOL, { { 15, 200, "Al" } }, false, now)
    Pr.Record(BOLT, 300, 3, now, 3, "Bolt of Woolen Cloth")
    -- 30 bolts with 3 listed: 3 at the AH (285c), 27 at the vendor (100c), against 90 wool (1350c).
    check(M.BatchProfit(recipe, 30) == 3 * 285 + 27 * 100 - 90 * 15, "as far as the market reaches: " .. tostring(M.BatchProfit(recipe, 30)))
    -- (The recipe's detail is drawn on Professions > Profit: the numbers it shows.)
    local plan = M.CraftPlan(recipe)
    check(plan.canMake == 30 and M.BatchProfit(recipe, plan.canMake) == 2205, "the can-make numbers: " .. tostring(plan.canMake))
    -- A product that goes to the vendor (your auctions of it mostly expire) is not "after the cut".
    Pr.Record(BOLT, 150, 3, now + 60, 3)
    local link = MOCK.ItemLink(BOLT, "Bolt of Woolen Cloth")
    local list = {}
    for i = 1, 10 do list[i] = { name = link, count = 1, status = i == 1 and "sold" or "expired", t = now - 3600, ended = now } end
    auctions(ns, list)
    local pr
    for _, x in ipairs(M.CraftList(ns.Gear.CharKey(), "all")) do if x.r == recipe then pr = x end end
    check(pr and pr.how == "vendor", "valued as a vendor price: " .. tostring(pr and pr.how))
    ns.MarketUI.Show("prices")
end

scenarios.econ_r3_make_whole_crafts = function()
    local ns = setup()
    local M, Pr = ns.Market, ns.Prices
    local now = time()
    local bomb = ns.ProfessionData.recipes[3950]
    -- A Silver Contact is made 5 at a time from a 100c bar; one bought costs 50c.
    Pr.Record(2842, 100, 1, now, 1, "Silver Bar")
    Pr.RecordLadder(2842, { { 100, 1, "Al" } }, false, now)
    Pr.Record(4404, 50, 10, now, 2, "Silver Contact")
    Pr.RecordLadder(4404, { { 50, 10, "Bo" } }, false, now)
    local contact
    for _, e in ipairs(M.CraftPlan(bomb).reagents) do if e.id == 4404 then contact = e end end
    check(contact and contact.craft == nil, "making 1 takes a whole craft (100c): buy it at 50c")
    -- At 120c a contact, the craft wins, with 4 spare.
    Pr.RecordLadder(4404, { { 120, 10, "Bo" } }, false, now)
    for _, e in ipairs(M.CraftPlan(bomb).reagents) do if e.id == 4404 then contact = e end end
    check(contact.craft and contact.craft.whole == 100 and contact.craft.crafts == 1 and contact.craft.spare == 4, "one craft, 4 spare")
end

---------------------------------------------------------------------------
-- Auction desk plans
---------------------------------------------------------------------------
scenarios.econ_r3_desk_best_roi = function()
    local ns = setup()
    local M, Pr, Desk = ns.Market, ns.Prices, ns.AuctionDesk
    local now = time()
    for d = 3, 1, -1 do Pr.Record(LINEN, 10000, 35, now - d * 86400, 3, "Linen Cloth") end
    Pr.Record(LINEN, 3000, 35, now, 3)
    Pr.RecordLadder(LINEN, { { 3000, 10, "Al" }, { 7500, 20, "Bo" }, { 10001, 5, "Cy" } }, false, now)
    local link = MOCK.ItemLink(LINEN, "Linen Cloth")
    local list = {}
    for i = 1, 5 do list[i] = { name = link, count = 5, deposit = 10, status = i <= 4 and "sold" or "expired", received = 400, t = now - 3600, ended = now } end
    auctions(ns, list)
    TALODDB.deskMinProfit = 100
    Desk.Invalidate()
    local plan = Desk.Detail(LINEN)
    check(plan.steps[1].roi > 0.6 and plan.steps[2].roi < Desk.MIN_ROI, "step 1 pays 70%, step 2 13%")
    check(plan.best == plan.steps[1], "the best reset is one worth doing: step " .. tostring(plan.best and plan.best.k))
    local opp = Desk.Opportunities()
    check(#opp == 1 and opp[1].id == LINEN, "still an opportunity: " .. #opp)
end

scenarios.econ_r3_desk_missing_input = function()
    local ns = setup()
    local Desk = ns.AuctionDesk
    check(Desk.MissingText({ rate = 0.7, usual = 100 }, { deposit = nil }):find("deposit"), "the deposit is what is missing")
    check(Desk.MissingText({ usual = 100 }, {}):find("sell rate"), "the sell rate is what is missing")
end

---------------------------------------------------------------------------
-- Gold ledger
---------------------------------------------------------------------------
scenarios.econ_r3_deposit_split = function()
    MOCK.money = 100000
    for slot = 1, 3 do
        MOCK.bags[0][slot] = MOCK.ItemLink(LINEN, "Linen Cloth")
        MOCK.bagCounts["0:" .. slot] = 5
    end
    local ns = setup()
    local c = ns.Economy.Char()
    local function changed() MOCK.FireEvent("PLAYER_MONEY") MOCK.FireEvent("BAG_UPDATE_DELAYED") MOCK.Tick(0.5) end
    MOCK.FireEvent("AUCTION_HOUSE_SHOW")
    MOCK.sellItem = { "Linen Cloth", 5 }
    PostAuction(50, 100, 3, 5, 3)
    for slot = 1, 3 do MOCK.bags[0][slot] = nil end
    MOCK.money = MOCK.money - 100
    changed()
    local sum, n = 0, 0
    for _, a in ipairs(c.auctions or {}) do sum, n = sum + (a.deposit or 0), n + 1 end
    check(n == 3 and sum == 100, "100c over 3 listings adds up to 100c: " .. sum)
    MOCK.FireEvent("AUCTION_HOUSE_CLOSED")
end

scenarios.econ_r3_late_deposit = function()
    MOCK.money = 100000
    C_AuctionHouse = { PostItem = function() end }
    itemInfo()
    local ns = boot(16001)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(2.2) MOCK.Tick(0.3)
    local c = ns.Economy.Char()
    local function changed() MOCK.FireEvent("PLAYER_MONEY") MOCK.FireEvent("BAG_UPDATE_DELAYED") MOCK.Tick(0.5) end
    for i = 1, 12 do MOCK.bags[0][i] = MOCK.ItemLink(LINEN, "Linen Cloth") end
    changed()
    MOCK.FireEvent("AUCTION_HOUSE_SHOW")
    C_AuctionHouse.PostItem({}, 1, 12, nil, 1300)
    -- 11 deposits as all 12 leave the bags, the 12th in the next settle.
    for i = 1, 12 do MOCK.bags[0][i] = nil end
    MOCK.money = MOCK.money - 69 * 11
    changed()
    MOCK.money = MOCK.money - 69
    changed()
    local n, sum = 0, 0
    for _, a in ipairs(c.auctions or {}) do n, sum = n + 1, sum + (a.deposit or 0) end
    check(n == 12 and sum == 828, "12 listings, 828c deposits: " .. n .. " " .. sum)
    for _, e in ipairs(c.log) do check(not (e.kind == "auction" and e.sub == "bid"), "the late deposit is not a bid") end
    MOCK.FireEvent("AUCTION_HOUSE_CLOSED")
    C_AuctionHouse = nil
end

scenarios.econ_r3_alt_first_seen = function()
    local ns = setup()
    local E = ns.Economy
    local function day(money) return { inc = 0, exp = 0, by = {}, money = money } end
    TALODDB.economy = {
        ["Main-Mockrealm"] = { log = {}, auctions = {}, days = { ["2026-11-05"] = day(1000000), ["2026-11-08"] = day(1000000) } },
        ["Alt-Mockrealm"] = { log = {}, auctions = {}, days = { ["2026-11-08"] = day(10000000) } },
    }
    ns.Data.Changed("economy")
    local out = E.ScopeDays("all")
    check(out["2026-11-05"].money == nil, "the alt's gold unknown before its first reading: not a sum")
    check(out["2026-11-08"].money == 11000000, "both known: the sum")
    local one = E.ScopeDays("Main-Mockrealm")
    check(one["2026-11-05"].money == 1000000, "one character: its own readings")
end
