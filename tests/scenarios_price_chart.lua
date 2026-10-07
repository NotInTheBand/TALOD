-- Price graph: daily summary past the 30 kept looks, volume (listed, gone,
-- your sales), the Market and desk charts, hover, and the tooltip graph.
local scenarios, T = ...
local check, boot = T.check, T.boot

scenarios.price_chart = function()
    function GetItemInfo(id)
        if id == 2589 then return "Linen Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132889, 13, 7, 5, 0 end
    end
    local ns = boot(11509)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    local Pr, Chart = ns.Prices, ns.PriceChart
    local now = time()
    local today = math.floor(now / 86400)

    -- 40 days, two looks a day (6 h apart): 80 looks, only 30 kept raw.
    for d = 40, 1, -1 do
        local noon = (today - d) * 86400 + 43200
        Pr.Record(2589, 100 + d, 200 - d, noon - 3 * 3600, 10, "Linen Cloth")
        Pr.Record(2589, 90 + d, 210 - d, noon + 3 * 3600, 11)
    end
    Pr.Record(2589, 50, 120, now, 6)
    local looks, days = Pr.History(2589, "looks"), Pr.History(2589, "days")
    check(#looks == 31, "30 looks kept + the current: " .. #looks)
    check(#days == 41, "every day kept in the summary: " .. #days)
    local d40 = days[1]
    check(d40.day == today - 40 and d40.p == 130 and d40.hi == 140 and d40.n == 170, "a day: lowest, highest, most units: "
        .. d40.p .. " " .. d40.hi .. " " .. d40.n)
    check(days[#days].p == 50 and days[#days].n == 120, "today from the current look")
    check(Chart.AutoMode(2589) == "days", "days when seen on 3+ days")

    -- Your sales: 20 sold yesterday.
    local key = ns.Gear.CharKey()
    TALODDB.economy[key] = TALODDB.economy[key] or { log = {}, days = {} }
    TALODDB.economy[key].auctions = { { id = 1, t = now - 2 * 86400, ended = (today - 1) * 86400 + 40000,
        name = MOCK.ItemLink(2589, "Linen Cloth"), count = 20, buyout = 2000, status = "sold" } }
    ns.Market.InvalidateSales()
    local pts = Chart.Data(2589, "days")
    check(pts[#pts - 1].sold == 20, "sold on its day")
    check(pts[#pts].gone == (209 - 120), "gone: fewer units than the day before: " .. tostring(pts[#pts].gone))
    local lp = Chart.Data(2589, "looks")
    local soldLook
    for _, pt in ipairs(lp) do if pt.sold then soldLook = pt end end
    check(soldLook and soldLook.sold == 20, "looks: sales since the look before")

    -- Market window: the graph on the Prices detail; switching modes; hover readout.
    ns.MarketUI.Show("prices")
    ns.MarketUI.state.selected = 2589
    ns.MarketUI.Refresh()
    local chart = ns.MarketUI.views.prices.chart
    check(chart.pts and #chart.pts == 41 and chart.shownMode == "days", "market chart drawn")
    chart.looks:Fire("OnClick", "LeftButton")
    check(chart.shownMode == "looks" and #chart.pts == 31, "looks mode")
    chart.plot.IsMouseOver = function() return true end
    MOCK.cursorX = chart.pts[5].x
    chart.plot:Fire("OnUpdate", 0.1)
    check(chart.hovering == 5 and GameTooltip:IsShown(), "hover: nearest point")
    local lines = Chart.PointLines(lp[#lp], "looks")
    check(table.concat(lines, "\n"):find("Listed: 120 units") , "readout: volume")

    -- One look only: said, nothing drawn.
    Pr.Record(4289, 20, 5, now, 1, "Salt")
    chart:SetItem(4289)
    check(not chart.pts and chart.empty:GetText():find("One look"), "one look")

    -- Desk Control: the same graph.
    Pr.RecordLadder(2589, { { 50, 120, "Al" } }, false, now)
    ns.AuctionDeskUI.Show("control", 2589)
    check(ns.AuctionDeskUI.views.control.chart.pts, "desk chart drawn")

    -- Tooltip graph: at the Auction House only (by default).
    ns.Tooltip.ItemLines(GameTooltip, 2589)
    check(not (TALODPriceGraphTip and TALODPriceGraphTip:IsShown()), "away from the AH: no graph")
    local ah = CreateFrame("Frame", "AuctionFrame", UIParent)
    AuctionFrame = ah
    GameTooltip:Show()
    ns.Tooltip.ItemLines(GameTooltip, 2589)
    check(TALODPriceGraphTip and TALODPriceGraphTip:IsShown() and TALODPriceGraphTip.chart.pts, "graph under the tooltip at the AH")
    GameTooltip:Hide()
    check(not TALODPriceGraphTip:IsShown(), "hides with the tooltip")
    ns.Tooltip.ItemLines(GameTooltip, 4289)
    check(not TALODPriceGraphTip:IsShown(), "one look: no graph")
    ah:Hide()
    TALODDB.tooltipGraphAlways = true
    ns.Tooltip.ItemLines(GameTooltip, 2589)
    check(TALODPriceGraphTip:IsShown(), "everywhere when set")
    TALODDB.tooltipGraph = false
    ns.Tooltip.ItemLines(GameTooltip, 2589)
    check(not TALODPriceGraphTip:IsShown(), "off")
end
