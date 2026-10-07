-- Market: overpriced looks are marked and kept, but the usual price, the
-- trend, deals, sale values, the posting price and the desk's relist leave
-- them out; browse rows never set the yardstick while exact looks exist.
local scenarios, T = ...
local check, boot = T.check, T.boot

local function setup()
    function GetItemInfo(id)
        if id == 2589 then return "Linen Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132889, 13, 7, 5, 0 end
        if id == 2592 then return "Wool Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132911, 33, 7, 5, 0 end
    end
    local ns = boot(11509)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    return ns
end

scenarios.market_outliers = function()
    local ns = setup()
    local M, Pr = ns.Market, ns.Prices
    local now = time()
    -- Linen goes for ~100c; two looks saw only a 1000c listing left.
    Pr.Record(2589, 100, 200, now - 5 * 86400, 10, "Linen Cloth")
    Pr.Record(2589, 1000, 5, now - 4 * 86400, 1)
    Pr.Record(2589, 110, 180, now - 3 * 86400, 9)
    Pr.Record(2589, 90, 220, now - 2 * 86400, 11)
    Pr.Record(2589, 1000, 5, now - 86400, 1)
    Pr.Record(2589, 100, 200, now, 10)
    local s = M.Stats(2589)
    check(s.looks == 6 and s.over == 2 and s.usual == 100 and s.high == 110 and s.highAll == 1000 and not s.overNow,
        "two overpriced looks marked, usual stays 100: " .. tostring(s.usual) .. " over " .. tostring(s.over))
    local marked = 0
    for _, pt in ipairs(s.points) do if pt.over then marked = marked + 1 check(pt.p == 1000, "only the 1000c looks marked") end end
    check(marked == 2, "marks kept on the points")
    check(math.abs(s.trend) < 1e-9, "trend against the usual, not the inflated average")

    -- The latest look overpriced: selling counts the usual price.
    Pr.Record(2589, 1200, 3, now + 3600, 1)
    s = M.Stats(2589)
    check(s.overNow and s.trend > 5, "latest look marked overpriced")
    local fair, _, over = M.FairPrice(2589)
    check(fair == 100 and over, "fair price = usual")
    local post, _, atUsual = M.PostPrice(2589)
    check(post == 100 and atUsual, "post at the usual price, not 1c under 1200")
    local value, how, info = M.SaleValue(2589)
    check(how == "ah" and info.over and info.p == 100 and info.net == M.Net(100), "sale value at usual: " .. tostring(info.p))
    check(#M.Deals() == 0, "an overpriced look is no deal")

    -- A deal is measured against the earlier looks without their outliers.
    Pr.Record(2589, 50, 400, now + 7200, 20)
    local deals = M.Deals()
    check(#deals == 1 and deals[1].usual == 100, "deal vs usual 100: " .. tostring(deals[1] and deals[1].usual))

    -- Browse rows (maybe not per unit) never set the yardstick while exact looks exist.
    Pr.Record(2592, 40, 100, now - 4 * 86400, 5, "Wool Cloth", true)
    Pr.Record(2592, 400, 100, now - 3 * 86400, 5, nil, true)
    Pr.Record(2592, 420, 100, now - 2 * 86400, 5, nil, true)
    Pr.Record(2592, 45, 100, now - 86400, 5)
    Pr.Record(2592, 40, 100, now, 5)
    s = M.Stats(2592)
    check(s.over == 2 and s.usual == 40, "browse stack prices marked against exact looks: usual " .. tostring(s.usual))
    check(Pr.Entry(2592).h[2][6] == 1 and Pr.Entry(2592).b == nil, "browse flag stored per look")
    -- An exact read in the same look clears the flag.
    Pr.Record(2592, 500, 100, now + 60, 5, nil, true)
    check(Pr.Entry(2592).b == nil, "exact look stays exact after a browse row")

    -- Two looks are too few to call one overpriced.
    local e = { p = 1000, t = now, h = { { now - 86400, 100 } } }
    check(M.BuildStats(e).over == 0, "no marks under 3 looks")

    -- The graph keeps them and marks them.
    local pts, usual, cap = ns.PriceChart.Data(2589, "looks")
    local red = 0
    for _, pt in ipairs(pts) do if pt.over then red = red + 1 end end
    check(red == 3 and usual == 100 and cap == 200, "graph marks: " .. red)
end

scenarios.market_outliers_desk = function()
    local ns = setup()
    local Pr, Desk = ns.Prices, ns.AuctionDesk
    local now = time()
    Pr.Record(2589, 100, 30, now - 3 * 86400, 3, "Linen Cloth")
    Pr.Record(2589, 100, 30, now - 2 * 86400, 3)
    Pr.Record(2589, 2000, 1, now - 86400, 1)
    Pr.Record(2589, 80, 31, now, 4)
    -- Ladder: 30 at 80c, one troll listing at 5000c.
    Pr.RecordLadder(2589, { { 80, 10, "A" }, { 80, 20, "B" }, { 5000, 1, "C" } }, false, now)
    Desk.Invalidate()
    local plan = Desk.Plan(2589)
    check(plan and plan.usual == 100, "desk usual leaves the 2000c look out: " .. tostring(plan and plan.usual))
    check(plan.all.relist == 100, "own-it-all relists at usual, not the 5000c tier: " .. tostring(plan.all.relist))
    check(#plan.steps == 1 and plan.steps[1].over and plan.best == nil, "a reset under a troll listing is marked, never best")
end

-- Prices tab: the crafting price of an item (cheapest recipe's materials per
-- unit) in the detail and on the row; unknown materials give no number.
scenarios.market_craft_price = function()
    local ns = setup()
    local M, Pr, D = ns.Market, ns.Prices, ns.ProfessionData
    local now = time()
    -- No price of yours for linen: Wowhead's average (41c) stands in, marked.
    local c = M.CraftCost(2996)
    check(c and c.each == 82 and c.estimated, "estimated from Wowhead: " .. tostring(c and c.each))
    -- No price anywhere: no number.
    local saved = D.items[2589]
    D.items[2589] = nil
    check(M.CraftCost(2996) == nil, "no craft price without a linen price")
    D.items[2589] = saved
    Pr.Record(2589, 30, 200, now, 10, "Linen Cloth")
    Pr.Record(2996, 100, 20, now, 4, "Bolt of Linen Cloth")
    c = M.CraftCost(2996)
    check(c and c.each == 60 and c.r.creates == 2996 and not c.estimated, "bolt crafts at 2 x 30c: " .. tostring(c and c.each))
    check(M.CraftCost(2589) == nil, "linen is not crafted")
    -- The window draws the craft line without errors.
    ns.MarketUI.Show("prices", "bolt")
end

-- Crafting tab: list + detail, bag counts, filters and sorts, materials
-- breakdown; a material with no price shows "?" instead of a number.
scenarios.market_crafting_tab = function()
    MOCK.skillLines = { { "Professions", true, true }, { "Tailoring", false, nil, 60, 0, 0, 75 } }
    for i = 1, 5 do MOCK.bags[0][i] = MOCK.ItemLink(2589, "Linen Cloth") end
    local ns = setup()
    local M, Pr = ns.Market, ns.Prices
    local now = time()
    Pr.Record(2589, 30, 200, now, 10, "Linen Cloth")
    Pr.Record(2996, 300, 20, now, 4, "Bolt of Linen Cloth")
    local list = M.CraftList(ns.Gear.CharKey(), "all", { bags = true })
    local bolt
    for _, pr in ipairs(list) do if pr.r.creates == 2996 then bolt = pr end end
    check(bolt and bolt.canMake == 2 and bolt.margin and bolt.margin > 0, "5 linen make 2 bolts: " .. tostring(bolt and bolt.canMake))
    local plan = M.CraftPlan(bolt.r)
    check(plan.canMake == 2 and plan.buyCost == 0 and plan.reagents[1].have == 5 and plan.reagents[1].sub == 60, "bolt plan")

    local ui = ns.MarketUI
    ui.Show("crafting")
    local v = ui.views.crafting
    check(ui.state.craftSel and ui.state.craftSel.creates, "a recipe selected")
    for _ = 1, 3 do v.filter:Fire("OnClick", "LeftButton") end
    check(ui.state.craftFilter == "all", "filter cycles back")
    v.filter:Fire("OnClick", "LeftButton")
    check(ui.state.craftFilter == "profit", "profitable only")
    check(v.sort == nil, "no sort button: the column titles sort")
    ui.state.craftSel = bolt.r
    ui.Refresh()
    local rows = v.detail.items or {}
    local found
    for _, row in ipairs(rows) do if row.label == "Can make" and tostring(row.text):find("2 crafts") then found = true end end
    check(found, "detail says 2 crafts")
    ui.Show("prices")
end
