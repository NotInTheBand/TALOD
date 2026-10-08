-- Auction desk: price ladders (legacy search, full scan, commodity and item
-- results), your listings (the game's list and the posting log), control
-- plans, deals with depth, the window and /talod ah routing.
local scenarios, T = ...
local check, boot, slash, printed = T.check, T.boot, T.slash, T.printed

local function itemInfo()
    function GetItemInfo(id)
        if id == 2589 then return "Linen Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132889, 13, 7, 5, 0 end
        if id == 4289 then return "Salt", nil, 1, 5, 0, "Trade Goods", "Other", 20, "", 132891, 10, 7, 5, 0 end
        if id == 2592 then return "Wool Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132911, 33, 7, 5, 0 end
        if id == 9001 then return "Bound Ring", nil, 2, 20, 15, "Armor", "Misc", 1, "INVTYPE_FINGER", 133345, 250, 4, 0, 1 end
    end
end

-- A legacy page: { name, count, buyout, owner, id } rows; GetAuctionItemInfo("list" / "owner", i).
local function legacyAH(lists)
    function GetNumAuctionItems(kind)
        local l = lists[kind] or {}
        return #l, l.total or #l
    end
    function GetAuctionItemInfo(kind, i)
        local r = (lists[kind] or {})[i]
        if not r then return nil end
        return r[1], 0, r[2], 1, true, 1, "", 10, 1, r[3], 0, false, nil, r[4], nil, r.sold and 1 or 0, r[5]
    end
    function GetAuctionItemTimeLeft() return 3 end
end

scenarios.auction_desk_ladder = function()
    itemInfo()
    local ns = boot(11509)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    local Pr, Desk, M = ns.Prices, ns.AuctionDesk, ns.Market
    local now = time()
    -- Linen usually 100c (three earlier looks).
    Pr.Record(2589, 100, 30, now - 3 * 86400, 3, "Linen Cloth")
    Pr.Record(2589, 100, 30, now - 2 * 86400, 3)
    Pr.Record(2589, 100, 30, now - 86400, 3)

    -- Exact search: every Linen auction on one page.
    local lists = { list = {
        { "Linen Cloth", 5, 50, "Al", 2589 },      -- 10c each
        { "Linen Cloth", 10, 200, "Bo", 2589 },    -- 20c each
        { "Linen Cloth", 5, 150, "Tester", 2589 }, -- 30c each: yours
        { "Linen Cloth", 20, 2000, "Al", 2589 },   -- 100c each
        { "Linen Cloth", 3, 0, "Cy", 2589 },       -- bid only
    } }
    legacyAH(lists)
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")   -- the game sends it again as items load: replaced, not doubled
    local L = Pr.Ladder(2589)
    check(L and #L.tiers == 4 and L.units == 40 and L.mine == 5 and L.bidOnly == 3 and not L.partial, "ladder: "
        .. tostring(L and #L.tiers) .. " " .. tostring(L and L.units))
    check(L.tiers[1].u == 10 and L.tiers[1].q == 5 and L.tiers[3].m == 5, "tiers cheapest first, yours marked")
    check(L.sellers == 4 and L.topName == "Al" and L.top == 25, "sellers: " .. tostring(L.sellers) .. " " .. tostring(L.topName))
    check(Pr.Entry(2589).p == 10, "lowest price still logged")

    -- Control plan (deposit: 15% of the 13c vendor price until you post; no sell rate yet).
    local plan = Desk.Plan(2589)
    check(plan and plan.usual == 100 and #plan.steps == 2, "plan steps: " .. tostring(plan and #plan.steps))
    local s1, s2 = plan.steps[1], plan.steps[2]
    check(s1.units == 5 and s1.cost == 50 and s1.relist == 19 and s1.deposit == 10 and s1.profit == 5 * 18 - 50 - 10, "step 1: " .. s1.profit)
    -- Step 2 relists under Al's 100c (your own 30c tier is no wall).
    check(s2.units == 15 and s2.cost == 250 and s2.relist == 99 and s2.profit == 15 * 94 - 250 - 29, "step 2: " .. s2.profit)
    check(plan.best == s2, "best reset")
    check(plan.all.units == 35 and plan.all.cost == 2250 and plan.all.relist == 100 and plan.all.profit == 35 * 95 - 2250 - 68,
        "own it all: " .. plan.all.cost .. " " .. plan.all.profit)
    check(plan.holders and plan.holders.name == "Al" and math.abs(plan.holders.share - 25 / 43) < 1e-9 and not plan.holders.mine, "holders")

    -- Buyout cost to a price.
    local cost, units = Desk.BuyoutCost(L, 20)
    check(cost == 250 and units == 15, "buyout to 20c")

    -- Deals with depth: 15 units under 80c (yours not counted).
    local deals = Desk.Deals()
    check(#deals == 1 and deals[1].units == 15 and deals[1].cost == 250 and deals[1].totalGain == 5 * 85 + 10 * 75 - 29,
        "deal depth: " .. tostring(deals[1] and deals[1].totalGain))

    -- Opportunities: above the profit setting only.
    check(#Desk.Opportunities() == 0, "1131c under the default 50s")
    TALODDB.deskMinProfit = 1000
    Desk.Invalidate()
    -- 30 units listed three days running: nothing leaves the AH, so no reset.
    check(ns.Market.Movement(2589).key == "dead" and #Desk.Opportunities() == 0, "doesn't sell: left out")
    -- Units leaving between looks: it moves, the reset shows.
    local e = Pr.Entry(2589)
    local looks = Pr.Looks(e)
    looks[1].n, looks[2].n, looks[3].n = 90, 60, 45
    e.h = Pr.PackLooks(looks)
    Desk.Invalidate()
    check(ns.Market.Movement(2589).key ~= "dead" and #Desk.Opportunities() == 1, "shown from 10s")

    -- A page with two items: no ladder (it may not show every auction). More pages: partial.
    lists.list = { { "Salt", 5, 50, "Al", 4289 }, { "Wool Cloth", 5, 500, "Bo", 2592 } }
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    check(not Pr.Ladder(4289) and not Pr.Ladder(2592) and Pr.Entry(4289), "browse page: prices, no ladders")
    lists.list = { { "Salt", 5, 50, "Al", 4289 }, total = 120 }
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    check(Pr.Ladder(4289) and Pr.Ladder(4289).partial and Desk.Plan(4289).atLeast, "more pages: partial ladder, costs at least")

    -- Your listings: from the posting log first (no live list yet).
    TALODDB.economy[ns.Gear.CharKey()] = TALODDB.economy[ns.Gear.CharKey()] or { log = {}, days = {} }
    local c = TALODDB.economy[ns.Gear.CharKey()]
    c.auctions = { { id = 1, t = now - 3600, name = MOCK.ItemLink(2589, "Linen Cloth"), count = 5, buyout = 150, deposit = 10,
        duration = "8 h", status = "listed" } }
    M.InvalidateSales()
    local data = Desk.Listings()
    check(data.source == "log" and #data.list == 1 and data.list[1].unit == 30, "listing from the log")
    local st = data.list[1].standing
    check(st.state == "undercut" and st.ahead == 15 and st.lowest == 10 and st.repost == 9, "undercut: " .. tostring(st.ahead))
    -- Deposit learned from that post: 10 / (13 * 5).
    local rate, posts = Desk.DepositRate()
    check(posts == 1 and math.abs(rate - 10 / 65) < 1e-9, "deposit rate learned: " .. rate)

    -- The game's own list replaces the log.
    lists.owner = { { "Linen Cloth", 5, 150, "Tester", 2589 }, { "Salt", 5, 25, "Tester", 4289, sold = true } }
    MOCK.FireEvent("AUCTION_OWNED_LIST_UPDATE")
    data = Desk.Listings()
    check(data.source == "game" and #data.list == 1 and data.list[1].left == "2 - 8 h", "live list, sold left out")
    local sum = Desk.Summary()
    check(sum.listed == 1 and sum.undercut == 1 and sum.ladders == 2, "summary")

    -- Standing without a ladder: the lowest price may be yours.
    TALODDB.ladders = {}
    Desk.Invalidate()
    check(Desk.Standing(2589, 10).state == "unknown" and Desk.Standing(2589, 30).state == "undercut", "no ladder: lowest price only")
end

scenarios.auction_desk_window = function()
    itemInfo()
    MOCK.skillLines = { { "Professions", true, true }, { "Tailoring", false, nil, 60, 0, 0, 75 } }
    local ns = boot(11509)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    local Pr = ns.Prices
    local now = time()
    Pr.Record(2589, 100, 30, now - 2 * 86400, 3, "Linen Cloth")
    Pr.Record(2589, 100, 30, now - 86400, 3)
    Pr.Record(2589, 10, 30, now, 3)
    Pr.RecordLadder(2589, { { 10, 5, "Al" }, { 20, 10, "Bo" }, { 100, 20, "Al" } }, false, now)
    Pr.RecordLadder(4289, { { 5, 50 } }, false, now - 3 * 86400)   -- old, sellers unknown

    -- /talod ah: the desk, not the scan panel.
    slash("ah")
    local UI = ns.AuctionDeskUI
    check(UI.IsShown() and UI.state.view == "overview", "/talod ah opens the desk")
    check(not (ns.AHHelper.Panel() and ns.AHHelper.Panel():IsShown()), "scan panel stays closed")
    for _, key in ipairs({ "overview", "listings", "deals", "margins", "control" }) do
        UI.Show(key)
        check(UI.state.view == key, "tab " .. key)
    end
    -- Control: the plan, the ladder; the old ladder with unknown sellers says so.
    UI.Show("control", 2589)
    local detail = UI.views.control.detail
    check(UI.state.selected == 2589 and #detail.all > 8, "control detail: " .. #detail.all)
    UI.Show("control", 4289)
    local texts = {}
    for _, r in ipairs(UI.views.control.detail.all) do texts[#texts + 1] = r.text or "" end
    local joined = table.concat(texts, "\n")
    check(joined:find("did not name them") and joined:find("search it again"), "unknown sellers and old look said")
    check(UI.views.control.sort == nil, "no sort button: the column titles sort")

    -- /talod ah <item>: the plan in chat and the Control tab on it.
    MOCK.prints = {}
    slash("ah linen")
    check(printed("Buy them all") and printed("Best reset") and UI.state.selected == 2589, "/talod ah linen")
    slash("ah nothing like this")
    check(printed("no full look"), "unknown item said")

    -- /talod ah scan: the scan panel; /talod ah toggles the desk off.
    slash("ah scan")
    check(ns.AHHelper.Panel() and ns.AHHelper.Panel():IsShown(), "/talod ah scan opens the scan panel")
    UI.Show("overview")
    slash("ah")
    check(not UI.IsShown(), "/talod ah toggles")
end

-- Full scan and modern results: ladders with sellers, commodity rows with
-- several owners, partial results, the modern owned list.
scenarios.auction_desk_modern = function()
    itemInfo()
    local ns = boot(16001)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    local Pr = ns.Prices

    -- Full scan rows carry the seller.
    local rows = { { 20, 400, 4289, "Salt", "Al" }, { 10, 300, 4289, "Salt", "Tester" }, { 5, 0, 4289, "Salt", "Bo" } }
    local done
    Pr.ReadBulk(function() return #rows end, function(i) return unpack(rows[i]) end, 1, function() done = true end)
    MOCK.RunTimers() MOCK.RunTimers()
    local L = Pr.Ladder(4289)
    check(done and L and L.units == 30 and L.mine == 10 and L.bidOnly == 5 and L.sellers == 3 and L.topName == "Al", "full scan ladder")

    local more = true
    C_AuctionHouse = {
        GetNumCommoditySearchResults = function() return 2 end,
        GetCommoditySearchResultInfo = function(_, i)
            if i == 1 then return { unitPrice = 30, quantity = 40, owners = { "Al" }, numOwnerItems = 0 } end
            return { unitPrice = 45, quantity = 60, owners = { "Bo", "player" }, numOwnerItems = 20 }
        end,
        HasFullCommoditySearchResults = function() return not more end,
        GetNumItemSearchResults = function() return 2 end,
        GetItemSearchResultInfo = function(_, i)
            if i == 1 then return { buyoutAmount = 500, quantity = 5, owners = { "Cy" }, containsOwnerItem = false } end
            return { buyoutAmount = 900, quantity = 3, owners = { "player" }, containsOwnerItem = true }
        end,
        HasFullItemSearchResults = function() return true end,
        GetNumOwnedAuctions = function() return 2 end,
        GetOwnedAuctionInfo = function(i)
            if i == 1 then return { itemKey = { itemID = 2589 }, quantity = 20, buyoutAmount = 45, status = 0, timeLeftSeconds = 7200 } end
            return { itemKey = { itemID = 9001 }, quantity = 1, buyoutAmount = 300, status = 0, timeLeftSeconds = 60 }
        end,
        -- The game's takes an ItemLocation: an item ID is an error.
        GetItemCommodityStatus = function(loc) if type(loc) ~= "table" then error("bad argument") end return 1 end,
    }
    MOCK.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
    L = Pr.Ladder(2589)
    check(L and L.units == 100 and L.mine == 20 and L.partial and not L.sellers, "commodity: mine counted, partial, sellers unknown")
    MOCK.FireEvent("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 9001 })
    L = Pr.Ladder(9001)
    check(L and L.tiers[1].u == 100 and L.tiers[2].u == 300 and L.tiers[2].m == 3 and not L.partial, "item results ladder")

    MOCK.FireEvent("OWNED_AUCTIONS_UPDATED")
    local data = ns.AuctionDesk.Listings()
    check(data.source == "game" and #data.list == 2, "modern owned list")
    local byId = {}
    for _, e in ipairs(data.list) do byId[e.id] = e end
    check(byId[2589].unit == 45 and byId[9001].unit == 300, "unit prices: commodity per unit, item per auction")
    check(byId[2589].standing.state == "undercut" and byId[2589].standing.ahead == 40, "commodity listing undercut by Al's 40")
    check(byId[9001].standing.state == "undercut" and byId[9001].standing.ahead == 5, "item listing undercut")
    check(byId[2589].deposit == nil and byId[9001].deposit == nil, "nothing in the posting log: deposits unknown")

    -- Deposits come from the posting log: same item and count, newest post first, each used once.
    local c = ns.Economy.Char()
    c.auctions = {
        { name = "|Hitem:2589::|h[Linen Cloth]|h", count = 20, deposit = 60, status = "listed", t = time() - 7200 },
        { name = "|Hitem:2589::|h[Linen Cloth]|h", count = 20, deposit = 80, status = "listed", t = time() - 60 },
        { name = "|Hitem:9001::|h[Bound Ring]|h", count = 1, deposit = 500, status = "sold", t = time() - 60 },
    }
    byId = {}
    for _, e in ipairs(ns.AuctionDesk.Listings().list) do byId[e.id] = e end
    check(byId[2589].deposit == 80, "newest matching post's deposit: " .. tostring(byId[2589].deposit))
    check(byId[9001].deposit == nil and byId[9001].depositGuess and byId[9001].depositGuess > 0,
        "a sold post is not a live listing's deposit; estimated instead")
    ns.AuctionDeskUI.Show("listings")
    local sub = ns.AuctionDeskUI.views.listings.card.sub:GetText()
    check(sub:find("deposits at stake 80c %+ about") and sub:find("estimated"), "paid and estimated apart: " .. sub)
    C_AuctionHouse = nil
end

-- Lists read before 0.9.4 divided a commodity's unit price by its quantity:
-- dropped on load, the posting log stands in until the Auctions tab is read.
scenarios.auction_desk_owned_migration = function()
    TALODDB = { store = { v = { ahOwned = 2 } }, ahOwned = { ["Tester-Mockrealm"] = { t = time(), list = {
        { id = 4603, count = 87, unit = 0, left = 60000 } } } } }
    local ns = boot(16001)
    check(next(ns.DB().ahOwned) == nil, "old owned lists dropped")
    check(ns.DB().store.v.ahOwned == 3, "store at v3")
    check(ns.AuctionDesk.Listings().source == "log", "posting log stands in")
end

-- Modern PostItem with quantity 20 is 20 auctions of one; the server charges
-- the deposits in batches that need not match the items leaving the bags.
scenarios.auction_post_item_quantity = function()
    MOCK.money = 100000
    C_AuctionHouse = { PostItem = function() end }
    itemInfo()
    local ns = boot(16001)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(2.2) MOCK.Tick(0.3)
    local c = ns.Economy.Char()
    local function changed() MOCK.FireEvent("PLAYER_MONEY") MOCK.FireEvent("BAG_UPDATE_DELAYED") MOCK.Tick(0.5) end
    MOCK.bags[1] = MOCK.bags[1] or {}
    for i = 1, 20 do MOCK.bags[i <= 10 and 0 or 1][(i - 1) % 10 + 1] = MOCK.ItemLink(9001, "Bound Ring") end
    changed()
    MOCK.FireEvent("AUCTION_HOUSE_SHOW")
    C_AuctionHouse.PostItem({}, 1, 20, nil, 1300)
    -- 11 deposits with 12 rings gone, one deposit alone, then 3, 3, 1 (+1 ring).
    local function settle(rings, deposits)
        for _ = 1, rings do
            local gone = false
            for bag = 1, 0, -1 do
                for slot = 10, 1, -1 do
                    if not gone and MOCK.bags[bag][slot] then MOCK.bags[bag][slot], gone = nil, true end
                end
            end
        end
        MOCK.money = MOCK.money - 69 * deposits
        changed()
    end
    settle(12, 11) settle(0, 1) settle(3, 3) settle(3, 3) settle(2, 2)
    local n, sum, all69 = 0, 0, true
    for _, a in ipairs(c.auctions or {}) do
        n, sum = n + 1, sum + (a.deposit or 0)
        if a.count ~= 1 or a.buyout ~= 1300 or a.deposit ~= 69 then all69 = false end
    end
    check(n == 20, "20 auctions of one: " .. n)
    check(all69 and sum == 1380, "each 13s buyout, 69c deposit: " .. sum)
    local posted = 0
    for _, e in ipairs(c.log) do if e.kind == "auction" and e.sub ~= "posted" then posted = posted + 1 end end
    local subs = {}
    for _, e in ipairs(c.log) do if e.kind == "auction" then subs[#subs + 1] = tostring(e.sub) end end
    check(posted == 0, "no deposit charge filed as a bid: " .. table.concat(subs, ","))
    MOCK.FireEvent("AUCTION_HOUSE_CLOSED")
    C_AuctionHouse = nil
end
