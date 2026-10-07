-- Does it sell: market movement from your looks, your auctions (with the
-- real sale time from the letter), the verdict in tooltips and the desk.
local scenarios, T = ...
local check, boot = T.check, T.boot

scenarios.movement = function()
    function GetItemInfo(id)
        if id == 2589 then return "Linen Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132889, 13, 7, 5, 0 end
        if id == 4289 then return "Salt", nil, 1, 5, 0, "Trade Goods", "Other", 20, "", 132891, 10, 7, 5, 0 end
        if id == 2592 then return "Wool Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132911, 33, 7, 5, 0 end
        if id == 9001 then return "Bound Ring", nil, 2, 20, 15, "Armor", "Misc", 1, "INVTYPE_FINGER", 133345, 250, 4, 0, 1 end
    end
    local ns = boot(11509)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    local M, Pr = ns.Market, ns.Prices
    local now = time()

    -- Linen: 100 listed, ~40 leave a day -> moves fast (40%).
    Pr.Record(2589, 50, 100, now - 3 * 86400, 10, "Linen Cloth")
    Pr.Record(2589, 50, 60, now - 2 * 86400, 6)
    Pr.Record(2589, 50, 100, now - 86400, 10)   -- restocked: new listings are not sales
    Pr.Record(2589, 50, 60, now, 6)
    local mm = M.MarketMovement(2589)
    check(mm and math.abs(mm.gonePerDay - 80 / 3) < 1e-6 and mm.avgListed == 80, "market: gone per day "
        .. tostring(mm and mm.gonePerDay))
    check(math.abs(mm.lasts - 3) < 1e-6, "supply lasts 3 days")
    local mv = M.Movement(2589)
    check(mv.key == "fast" and mv.source == "market", "linen moves fast: " .. mv.key)

    -- Salt: 50 listed for three days, nothing leaves -> doesn't sell.
    for d = 3, 0, -1 do Pr.Record(4289, 20, 50, now - d * 86400, 5, "Salt") end
    mv = M.Movement(4289)
    check(mv.key == "dead" and mv.market.stuck, "salt: doesn't sell")
    check(M.MovementLines(mv)[1]:find("nothing left the AH"), "said: " .. M.MovementLines(mv)[1])

    -- Looks too close or a single one: not enough data.
    Pr.Record(2592, 300, 20, now - 900, 2, "Wool Cloth")
    check(M.Movement(2592).key == "unknown", "one look: unknown")

    -- Your auctions decide once 2 have ended: wool posted twice, never sold.
    local key = ns.Gear.CharKey()
    TALODDB.economy[key] = TALODDB.economy[key] or { log = {}, days = {} }
    local c = TALODDB.economy[key]
    local wool = MOCK.ItemLink(2592, "Wool Cloth")
    c.auctions = {
        { id = 1, t = now - 3 * 86400, name = wool, count = 20, deposit = 99, status = "expired", ended = now - 2 * 86400 },
        { id = 2, t = now - 2 * 86400, name = wool, count = 20, deposit = 99, status = "expired", ended = now - 86400 },
        { id = 3, t = now - 10 * 3600, name = MOCK.ItemLink(2589, "Linen Cloth"), count = 10, status = "listed" },
    }
    M.InvalidateSales()
    mv = M.Movement(2592)
    check(mv.key == "dead" and mv.source == "you", "wool: never sold for you")

    -- A sale letter that came 4 h ago: sold 5 h ago (1 h mail delay), 5 h after posting.
    local a = ns.Economy.SettleListing(c, "Linen Cloth", "sold", 600, now - 4 * 3600)
    check(a and a.closedAt == now - 5 * 3600 and a.ended == now, "real sale time kept: " .. tostring(a and a.closedAt))
    M.InvalidateSales()
    check(M.MySales(2589).sellTime == 5 * 3600, "time to sell")
    -- The letter's arrival comes from daysLeft (30-day auction mail).
    local header = GetInboxHeaderInfo
    function GetInboxHeaderInfo() return nil, nil, "Auction House", "Auction successful: Linen Cloth", 600, 0, 29.5, 0 end
    function GetInboxInvoiceInfo() return "seller", "Linen Cloth", "Bob" end
    local _, _, info = ns.Economy.DescribeMail(1)
    check(info.arrived == math.floor(now - 0.5 * 86400), "arrived from daysLeft: " .. tostring(info.arrived))
    GetInboxHeaderInfo = header

    -- Tooltip: the verdict, not on bound items, not on items never seen nor posted.
    local tip = {}
    local add = GameTooltip.AddDoubleLine
    GameTooltip.AddDoubleLine = function(_, l, r) tip[#tip + 1] = tostring(l) .. " | " .. tostring(r) end
    ns.Tooltip.ItemLines(GameTooltip, 4289)
    check(table.concat(tip, " || "):find("Sells | doesn't sell"), "salt tooltip: " .. table.concat(tip, " || "))
    tip = {}
    ns.Tooltip.ItemLines(GameTooltip, 9001)
    check(not table.concat(tip, " || "):find("sells"), "bound: no verdict")
    tip = {}
    TALODDB.tooltipMovement = false
    ns.Tooltip.ItemLines(GameTooltip, 4289)
    check(not table.concat(tip, " || "):find("sells"), "setting off")
    TALODDB.tooltipMovement = true
    GameTooltip.AddDoubleLine = add

    -- Desk: what you posted that doesn't sell, with the deposits it cost.
    local waste = ns.AuctionDesk.NotWorthIt()
    check(#waste == 1 and waste[1].id == 2592 and waste[1].sales.depositLost == 198, "not worth posting: wool")
    check(M.MoveTag(4289):find("doesn't sell") and M.MoveTag(2589) == "", "list tags")
    ns.AuctionDeskUI.Show("overview")
    local found
    for _, r in ipairs(ns.AuctionDeskUI.views.overview.list.all) do
        if r.header and r.text:find("Not worth posting") then found = true end
    end
    check(found, "overview section")
    Pr.RecordLadder(4289, { { 20, 50, "Al" } }, false, now)
    ns.AuctionDeskUI.Show("control", 4289)
    local said
    for _, r in ipairs(ns.AuctionDeskUI.views.control.detail.all) do
        if (r.text or ""):find("a reset would only sit") then said = true end
    end
    check(said, "control: doesn't sell said")
    ns.MarketUI.Show("prices")
    ns.MarketUI.state.selected = 4289
    ns.MarketUI.Refresh()
end
