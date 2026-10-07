-- Market Bids: auctions whose next bid is under the item's price, from the
-- legacy search list, C_AuctionHouse item results and full scans; time-left
-- bands, ended auctions dropping off, your own auctions left out, unknown
-- prices never shown as a saving, and the Bids tab.
local scenarios, T = ...
local check, boot = T.check, T.boot

local function itemInfo()
    function GetItemInfo(id)
        if id == 7001 then return "Green Ring", nil, 2, 20, 15, "Armor", "Misc", 1, "INVTYPE_FINGER", 133345, 250, 4, 0, 2 end
        if id == 7002 then return "Blue Cloak", nil, 3, 30, 25, "Armor", "Cloth", 1, "INVTYPE_CLOAK", 133762, 500, 4, 1, 2 end
        if id == 7003 then return "Odd Trinket", nil, 2, 30, 25, "Armor", "Misc", 1, "INVTYPE_TRINKET", 133434, 100, 4, 0, 2 end
    end
end

local function setup(interface)
    itemInfo()
    local ns = boot(interface)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    return ns
end

-- A legacy page: { count, minBid, increment, buyout, bid, highBidder, owner, id, band } rows.
local function legacyPage(rows)
    function GetNumAuctionItems(kind) if kind == "list" then return #rows, #rows end return 0, 0 end
    function GetAuctionItemInfo(kind, i)
        local r = kind == "list" and rows[i]
        if not r then return nil end
        return "x", 0, r[1], 2, true, 1, "", r[2], r[3], r[4], r[5], r[6], nil, r[7], nil, 0, r[8]
    end
    function GetAuctionItemTimeLeft(kind, i) return rows[i] and rows[i][9] end
end

scenarios.market_bids_legacy = function()
    local ns = setup(11509)
    local Pr, M = ns.Prices, ns.Market
    local me = UnitName("player")
    local now = time()
    -- The ring usually sells for 1000c.
    Pr.Record(7001, 1000, 3, now - 3 * 86400, 3, "Green Ring")
    Pr.Record(7001, 1000, 3, now - 2 * 86400, 3)
    Pr.Record(7001, 1000, 3, now - 86400, 3)
    legacyPage({
        { 1, 300, 10, 1000, 0, false, "Al", 7001, 1 },     -- ends within 30 min, no bids: next 300
        { 1, 200, 20, 1100, 400, false, "Bo", 7001, 2 },   -- has a bid of 400: next 420
        { 1, 10, 1, 1050, 0, false, me, 7001, 1 },         -- yours: never listed
        { 1, 1200, 10, 1500, 0, false, "Cy", 7001, 3 },    -- next bid over the cheapest buyout: dropped
    })
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    local b = Pr.Bids(7001)
    check(b and #b.rows == 2 and b.low == 1000, "two bids kept, lowest buyout 1000: " .. tostring(b and #b.rows))
    check(b.rows[1].next == 300 and b.rows[1].band == 1 and not b.rows[1].bids, "cheapest first, band, no bids")
    check(b.rows[2].next == 420 and b.rows[2].bids and b.rows[2].band == 2, "next bid = bid + increment, has bids")
    check(b.rows[1].ends == b.t + 1800, "latest end = look + 30 min")

    -- The same page again (the game sends it more than once): no duplicates.
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    check(#Pr.Bids(7001).rows == 2, "a page read twice is not counted twice")

    local list = M.Bids()
    check(#list == 2 and list[1].r.next == 300 and list[1].saving == 700 and math.abs(list[1].pct - 0.7) < 1e-9,
        "soonest band first, saving against the price: " .. tostring(list[1] and list[1].saving))
    check(list[2].saving == 580 and list[1].resale == math.floor(1000 * 0.95) - 300, "second row and resale")

    -- The window: one section per band, rows built.
    ns.MarketUI.Show("bids")
    local v = ns.MarketUI.views.bids
    check(v.card.sub:GetText():find("2 auctions under the price", 1, true), "Bids tab: " .. tostring(v.card.sub:GetText()))

    -- 31 minutes on: the short auction may have ended, so it is gone.
    MOCK.now = MOCK.now + 31 * 60
    b = Pr.Bids(7001)
    check(b and #b.rows == 1 and b.rows[1].next == 420, "ended band dropped")
    -- A day later nothing runs: pruned at login.
    MOCK.now = MOCK.now + 86400
    check(Pr.Bids(7001) == nil, "nothing left a day later")
    Pr.PruneBids()
    check(Pr.AllBids()[7001] == nil, "pruned")
end

scenarios.market_bids_legacy_pages = function()
    local ns = setup(11509)
    local Pr = ns.Prices
    legacyPage({ { 1, 300, 10, 1000, 0, false, "Al", 7001, 4 } })
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    -- The next page of the same search, a minute later: added to the look.
    MOCK.now = MOCK.now + 60
    legacyPage({ { 1, 250, 10, 0, 0, false, "Bo", 7001, 3 } })
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    local b = Pr.Bids(7001)
    check(b and #b.rows == 2 and b.rows[1].next == 250 and not b.rows[1].buyout, "pages merged, bid-only row kept")
    -- A new search later replaces it.
    MOCK.now = MOCK.now + 600
    legacyPage({ { 1, 900, 10, 950, 0, false, "Cy", 7001, 4 } })
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    b = Pr.Bids(7001)
    check(b and #b.rows == 1 and b.rows[1].next == 900, "a later search replaces the look")

    -- No price anywhere (no buyout seen, no history): "?" never a saving.
    legacyPage({ { 1, 500, 10, 0, 0, false, "Di", 7003, 4 } })
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    local found
    for _, d in ipairs(ns.Market.Bids()) do if d.id == 7003 then found = d end end
    check(found and found.saving == nil and found.pct == nil, "unpriced bid: saving unknown")
    ns.MarketUI.Show("bids")
    check(ns.MarketUI.views.bids.card.sub:GetText():find("1 without a price", 1, true), "unpriced counted apart")
end

scenarios.market_bids_modern = function()
    local ns = setup(16001)
    local Pr, M = ns.Prices, ns.Market
    local myGuid = UnitGUID("player")
    local now = time()
    Pr.Record(7002, 2000, 2, now - 2 * 86400, 2, "Blue Cloak")
    Pr.Record(7002, 2000, 2, now - 86400, 2)
    C_AuctionHouse = {
        GetNumItemSearchResults = function() return 4 end,
        GetItemSearchResultInfo = function(_, i)
            if i == 1 then return { quantity = 1, buyoutAmount = 2000, minBid = 900, timeLeft = 0, owners = { "Al" } } end
            if i == 2 then return { quantity = 1, buyoutAmount = 2200, minBid = 1300, bidAmount = 1200, bidder = myGuid, timeLeft = 2, owners = { "Bo" } } end
            if i == 3 then return { quantity = 1, buyoutAmount = 2100, minBid = 50, timeLeft = 0, owners = { "player" }, containsOwnerItem = true } end
            return { quantity = 1, buyoutAmount = 1900, timeLeft = 0, owners = { "Cy" } }   -- buyout only: no bid
        end,
        HasFullItemSearchResults = function() return true end,
    }
    MOCK.FireEvent("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 7002 })
    local b = Pr.Bids(7002)
    check(b and b.api == "modern" and #b.rows == 2 and b.low == 1900, "modern: two bids, yours and buyout-only left out")
    check(b.rows[1].next == 900 and b.rows[1].band == 1 and b.rows[2].high and b.rows[2].band == 3, "bands from the enum, you are high bidder")
    check(b.rows[2].ends == b.t + 43200, "modern long band: 12 h")
    -- Price now = the latest lowest buyout (1900 from this look).
    local list = M.Bids()
    check(#list == 2 and list[1].saving == 1000 and list[2].saving == 600, "savings against 1900: " .. tostring(list[1] and list[1].saving))

    -- A full scan: every auction seen, its bids replace the realm's.
    local rows = {
        { 1, 3000, 7003, "Odd Trinket", "Al", { 1000, 4, false, false, "modern" } },
        { 1, 2500, 7003, "Odd Trinket", "Bo", nil },
    }
    local done
    Pr.ReadBulk(function() return #rows end, function(i) return unpack(rows[i], 1, 6) end, 1, function() done = true end)
    MOCK.RunTimers() MOCK.RunTimers()
    check(done and Pr.Bids(7002) == nil, "the cloak's bids are gone after a scan without them")
    b = Pr.Bids(7003)
    check(b and #b.rows == 1 and b.rows[1].next == 1000 and b.low == 2500, "scan bid kept under the 2500 buyout")
    ns.MarketUI.Show("bids")
end
