-- TALOD - the Auction House page (Trade > Auction House), ordered the way a
-- visit goes: Today (what needs you), Buy (Deals | Bids), Sell (your bags),
-- My auctions (Auctions | By item) and Prices (every item you have seen, with
-- the price graph, and for an item with a full look its ladder, own-it-all
-- and reset plans). Numbers come from Market.lua and AuctionDesk.lua; Today,
-- My auctions and the control plan are built in AuctionDeskUI.lua, which
-- loads later and hands its parts in at build time. Nothing here buys or
-- posts; a search at the Auction House is one per click.

local ADDON_NAME, ns = ...
local Style = ns.Style
local COLORS, HEX = Style.COLORS, Style.HEX
local Market, Prices = ns.Market, ns.Prices

local UI = {}
ns.MarketUI = UI

local PAD = 12
-- view: the shown view (today, deals, bids, sell, mine, sellthrough, prices);
-- the tab follows from it. buyView / mineView: each tab's last view.
local state = { view = "today", search = "", selected = nil, buyView = "deals", mineView = "mine",
    mineFilter = "all", priceFilter = "all" }
local frame
local views = {}

local TABS = {
    { key = "today", label = "Today" }, { key = "buy", label = "Buy" }, { key = "sell", label = "Sell" },
    { key = "mine", label = "My auctions" }, { key = "prices", label = "Prices" },
}
local TAB_VIEWS = {
    buy = { { key = "deals", label = "Deals" }, { key = "bids", label = "Bids" } },
    mine = { { key = "mine", label = "Auctions" }, { key = "sellthrough", label = "By item" } },
}
local VIEW_TAB = { today = "today", deals = "buy", bids = "buy", sell = "sell", mine = "mine", sellthrough = "mine",
    prices = "prices" }
UI.TABS, UI.TAB_VIEWS, UI.VIEW_TAB = TABS, TAB_VIEWS, VIEW_TAB

local function db() return ns.DB() end

local function Money(c)
    if not c then return HEX.dim .. "-|r" end
    return ns.Professions.Money(c)
end

local function Pct(x)
    if not x then return HEX.dim .. "-|r" end
    -- Half away from zero on both sides: floor(x - 0.5) put every drop a point too low.
    local v = x >= 0 and math.floor(x * 100 + 0.5) or -math.floor(-x * 100 + 0.5)
    if v == 0 then return HEX.muted .. "0%|r" end
    return (v < 0 and HEX.good or HEX.bad) .. (v > 0 and "+" or "") .. v .. "%|r"
end
UI.Pct = Pct

-- Freshness color: today green, this week gold, older grey.
local function AgeText(t)
    if not t then return HEX.dim .. "?|r" end
    local age = time() - t
    local color = age < 86400 and HEX.good or (age < 7 * 86400 and HEX.gold or HEX.muted)
    return color .. Prices.Age(t) .. "|r"
end

-- A click on an item while the Auction House is open also searches it there
-- (one search per click, AHHelper.Lookup); quiet when the AH is closed.
local function ShowOnAH(id)
    if not ns.AHHelper or type(id) ~= "number" then return end
    local ok, msg = ns.AHHelper.Lookup(id)
    if not ok and msg then ns.Print(msg) end
end
UI.ShowOnAH = ShowOnAH

local function Supply(n, a)
    local parts = {}
    if a and a > 0 then parts[#parts + 1] = a .. (a == 1 and " auction" or " auctions") end
    if n and n > 0 then parts[#parts + 1] = n .. " units" end
    return #parts > 0 and table.concat(parts, ", ") or "supply ?"
end

local function Signed(c)
    if not c then return HEX.dim .. "-|r" end
    return (c >= 0 and HEX.good or HEX.bad) .. (ns.AuctionDesk and ns.AuctionDesk.Signed(c) or Money(c)) .. "|r"
end

-- One item on Prices, from anywhere on the page (its detail opens there).
local function OpenPrices(id, full)
    if id then state.selected = id end
    if full and id and Prices.Ladder(id) then state.priceFilter, state.focusControl = "full", true
    elseif id and not Prices.Ladder(id) then state.priceFilter = "all" end
    if id and state.search ~= "" then
        state.search = ""
        if views.prices then views.prices.search:SetText("") end
    end
    state.view = "prices"
    UI.Refresh()
end
UI.OpenPrices = OpenPrices

---------------------------------------------------------------------------
-- Prices: list + detail (with the control plan for an item with a full look)
---------------------------------------------------------------------------
-- extra: rows put in before "Every look" (the control plan).
local function DetailRows(id, extra)
    local out = {}
    local s = Market.Stats(id)
    local name, _, _, sell, bind = Market.ItemInfo(id)
    if not s then
        out[1] = { text = HEX.muted .. "Not seen on the Auction House yet.|r" }
        for _, r in ipairs(extra or {}) do out[#out + 1] = r end
        return out
    end
    out[#out + 1] = { header = true, text = "Now" }
    out[#out + 1] = { label = "Lowest", text = HEX.white .. Money(s.p) .. "|r each  ·  " .. AgeText(s.t)
            .. (s.overNow and (HEX.bad .. "  overpriced|r") or ""), cols = { Pct(s.trend) },
        tooltip = function(o) ns.Tooltip.Text(o, { "Lowest buyout per unit at your last look.",
            s.trendBase and ("Right: against your earlier looks (the middle of each day: " .. Money(math.floor(s.trendBase + 0.5)) .. ").")
                or "Right: against your earlier looks (none yet).",
            s.usual and ("Usual price " .. Money(math.floor(s.usual + 0.5)) .. (s.usualStale and ", from old looks only" or "") .. ".") or nil,
            s.overNow and string.format("Over %dx the usual price: the cheap ones are gone or the price was not per unit. "
                .. "Left out of the usual; selling counts the usual price instead.", Market.OUTLIER_FACTOR) or nil }) end }
    out[#out + 1] = { label = "Supply", text = Supply(s.n, s.a), cols = { Pct(s.supplyTrend) },
        tooltip = function(o) ns.Tooltip.Text(o, { "Auctions and units listed at your last look.",
            s.avgN and string.format("Usually %d units. Right: now against that.", math.floor(s.avgN + 0.5))
                or (s.looks > 1 and "Too few looks with a unit count for a usual supply." or "One look so far.") }) end }
    out[#out + 1] = { label = "Usual", text = string.format("%s  ·  low %s  ·  high %s  ·  %d looks", Money(s.usual and math.floor(s.usual + 0.5)),
        Money(s.low), Money(s.high), s.looks),
        tooltip = function(o) ns.Tooltip.Text(o, { "Usual price", string.format("The middle (median) of your looks, leaving out the overpriced "
            .. "ones (over %dx the middle; marked red in the graph and under Every look) and the thin cheap ones (under half of it "
            .. "with one auction or few units). Low and high: of the looks kept.", Market.OUTLIER_FACTOR) }) end }
    local craft = Market.CraftCost(id)
    if craft then
        local each = math.floor(craft.each + 0.5)
        local diff = s.p and s.p > 0 and (each - s.p) / s.p or nil
        out[#out + 1] = { label = "Craft", text = HEX.white .. Money(each) .. "|r" .. HEX.muted
                .. (craft.spare and " each, making one batch (whole stacks: materials left over)  ·  " or " each  ·  ") .. craft.r.name
                .. (craft.estimated and "  (partly estimated)" or "") .. "|r",
            cols = { Pct(diff) },
            tooltip = function(o) ns.Tooltip.Text(o, { "Crafting price", "Materials of the cheapest recipe that makes it, at the best "
                .. "known prices (vendor, your AH looks, else Wowhead's Classic Era average), divided by how many it makes.",
                "Right: against the lowest now (green = cheaper to craft).",
                craft.estimated and "Some materials have no price of yours yet: Wowhead's average stands in." or nil }) end }
    end
    if s.over > 0 then
        out[#out + 1] = { label = "Overpriced", text = HEX.bad .. s.over .. (s.over == 1 and " look" or " looks") .. "|r" .. HEX.muted
            .. "  left out (up to " .. Money(s.highAll) .. ")|r" }
    end
    out[#out + 1] = { header = true, text = "Selling it" }
    local post, _, atUsual, onlyMine, stack = Market.PostPrice(id)
    out[#out + 1] = { label = "Post at", text = HEX.white .. Money(post) .. "|r"
        .. ((stack and stack > 1 and post) and (HEX.white .. " (" .. Money(post * stack) .. " for " .. stack .. ")|r") or "") .. HEX.muted
        .. (atUsual and "  each: the usual price (the lowest now is odd)"
            or onlyMine and "  each: your own price (only your auctions were listed at your last look)"
            or "  each: 1c under the cheapest auction (its whole stack) at your last look")
        .. ((s.t and time() - s.t > 3600) and ", look again first" or "") .. "|r" }
    local fair = Market.FairPrice(id)
    out[#out + 1] = { label = "AH nets", text = Money(Market.Net(fair)) .. HEX.muted .. "  each after the " .. math.floor(Market.CUT * 100) .. "% cut"
        .. (atUsual and ", at the usual price" or "") .. "|r" }
    out[#out + 1] = { label = "Vendor", text = sell and sell > 0 and Money(sell) or (HEX.muted .. "cannot be sold to a vendor|r") }
    if bind == 1 then out[#out + 1] = { label = "", text = HEX.bad .. "Binds when picked up: no auction for you.|r" } end
    local mv = Market.Movement(id)
    local ev = Market.MovementLines(mv)
    out[#out + 1] = { label = "Moves", text = mv.hex .. mv.label .. "|r" .. HEX.muted .. "  " .. ev[1] .. "|r" }
    if ev[2] then out[#out + 1] = { label = "", text = HEX.muted .. ev[2] .. "|r" } end
    local sales = mv.sales
    if sales.sold > 0 or sales.listed > 0 or sales.expired > 0 then
        out[#out + 1] = { label = "You", text = string.format("sold %d auctions (%d units)%s%s%s", sales.sold, sales.units,
            sales.perUnit and (", " .. Money(math.floor(sales.perUnit)) .. " each") or "",
            sales.listed > 0 and (", " .. sales.listed .. " listed now") or "",
            sales.expired > 0 and (", " .. sales.expired .. " expired / cancelled") or "") }
        local rate = Market.SellRateText(sales)
        if rate then
            out[#out + 1] = { label = "Sells", text = (sales.hard and HEX.bad or "") .. rate .. (sales.hard and "  ·  hard to sell|r" or "")
                .. (sales.depositLost > 0 and (HEX.muted .. "  ·  " .. Money(sales.depositLost) .. " deposits lost|r") or ""),
                tooltip = function(o) ns.Tooltip.Text(o, { "Your sell rate", "Auctions of it that sold, of those that ended (every character). "
                    .. string.format("Once %d have ended, values everywhere count it: this share sells at the AH price after the cut, "
                        .. "the rest comes back and is worth the vendor price less the deposit.", Market.SELL_MIN_ENDED) }) end }
        end
    end
    out[#out + 1] = { header = true, text = "Other prices" }
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if api and api.GetAuctionPriceByItemID then
        local ok, ap = pcall(api.GetAuctionPriceByItemID, ADDON_NAME, id)
        out[#out + 1] = { label = "Auctionator", text = (ok and type(ap) == "number") and Money(ap) or (HEX.muted .. "no price|r") }
    end
    local d = ns.ProfessionData and ns.ProfessionData.items[id]
    if d and d.ah then out[#out + 1] = { label = "Wowhead", text = Money(d.ah) .. HEX.muted .. "  Classic Era average (not this server)|r" } end
    if d and d.vendor then out[#out + 1] = { label = "Vendor sells", text = Money(d.vendor) } end

    local made, used = Market.MadeBy(id), Market.UsedIn(id)
    if #made > 0 then
        out[#out + 1] = { header = true, text = "Made by" }
        for _, r in ipairs(made) do
            local pr = Market.CraftProfit(r)
            local makes = r.makes or 1
            out[#out + 1] = { label = r.prof:sub(1, 12), text = r.name .. HEX.muted .. "  " .. r.skill .. "  ·  materials " .. Money(pr.cost)
                .. (makes ~= 1 and string.format(" for %s (%s each)", makes, Money(pr.cost / makes)) or "")
                .. (pr.unknown and " + materials with no price" or (pr.guessed and " (partly estimated)" or "")) .. "|r",
                cols = { pr.profit and ((pr.profit >= 0 and HEX.good or (HEX.bad .. "-")) .. Money(math.abs(pr.profit)) .. "|r") or "" } }
        end
    end
    if #used > 0 then
        out[#out + 1] = { header = true, text = "Used in  " .. HEX.muted .. "(" .. #used .. " recipes)|r" }
        for i, r in ipairs(used) do
            if i > 10 then out[#out + 1] = { label = "", text = HEX.muted .. "and " .. (#used - 10) .. " more|r" } break end
            out[#out + 1] = { label = r.prof:sub(1, 12), text = r.name .. HEX.muted .. "  " .. r.skill .. "|r" }
        end
    end
    for _, r in ipairs(extra or {}) do out[#out + 1] = r end
    out[#out + 1] = { header = true, text = "Every look" }
    local points = Market.Points(id)
    for i = #points, 1, -1 do
        local pt = points[i]
        out[#out + 1] = { label = date("%b %d %H:%M", pt.t), text = Money(pt.p) .. " each"
            .. (pt.over and (HEX.bad .. "  overpriced, left out|r") or "") .. (pt.b and (HEX.muted .. "  (browse)|r") or ""),
            cols = { HEX.muted .. Supply(pt.n, pt.a) .. "|r" } }
    end
    return out
end

-- "  ·  craft 1g 20s" on a Prices row, green when crafting is cheaper than
-- the lowest buyout, "~" when a material is priced by Wowhead's average.
local function CraftTag(id, lowest)
    local craft = Market.CraftCost(id)
    if not craft then return "" end
    local each = math.floor(craft.each + 0.5)
    return HEX.muted .. "  ·  craft " .. ((lowest and each < lowest) and HEX.good or "") .. (craft.estimated and "~" or "")
        .. Money(each) .. "|r"
end

-- One row of the Prices tab (built when drawn: Data.List).
local function PriceRow(it)
    local _, icon = Market.ItemInfo(it.id)
    return {
        icon = icon,
        text = Market.ItemText(it.id) .. (Prices.Ladder(it.id) and (HEX.muted .. "  · ladder|r") or "")
            .. HEX.muted .. "  " .. Supply(it.e.n, it.e.a) .. "|r" .. CraftTag(it.id, it.e.p),
        cols = { AgeText(it.e.t), it.s.overNow and (HEX.bad .. "over|r") or Pct(it.s.trend), HEX.white .. Money(it.e.p) .. "|r" },
        sort = { it.e.t, it.s.trend, it.e.p },
    }
end

-- A full scan leaves thousands of items: the sorted list is kept until a
-- price or the search changes (a minute at most, for the ages),
-- and only the rows on screen are formatted. Also built ahead (warm-up).
local function PriceItems()
    local search = state.search
    -- Newest look first; the column titles sort it otherwise.
    return ns.Data.Memo("market:prices", ns.Data.Key("prices") .. "|" .. tostring(Prices.RealmKey())
        .. "|" .. search, function()
        local out = {}
        for id, e in pairs(Prices.All()) do
            local name = Market.ItemInfo(id)
            if search == "" or name:lower():find(search, 1, true) then
                out[#out + 1] = { id = id, e = e, name = name, s = Market.Stats(id) }
            end
        end
        return ns.Utils.SortBy(out, function(x) return ns.Utils.NumKey(x.e.t, true) end)
    -- Nothing here moves with the clock; the age picks up item names the
    -- game's item cache sends later.
    end, 300)
end

local function LadderCount()
    local n = 0
    for _ in pairs(Prices.AllLadders()) do n = n + 1 end
    return n
end

local PRICE_COLUMNS = { name = "Item", "Seen", "Trend", "Price" }
local CONTROL_COLUMNS = { name = "Item", "Own it all", "Best reset", "Top seller" }
local PRICE_WIDTHS, CONTROL_WIDTHS = { 58, 46, 64 }, { 84, 80, 60 }

-- The send button on the detail card: one search per click, only while the
-- Auction House is open.
local function SearchButtonState(id)
    local H = ns.AHHelper
    if not H or not id then return false, "pick an item first" end
    if not H.IsOpen() then return false, "open the Auction House first" end
    if H.state and H.state.scan then return false, "a full scan is running" end
    return true
end

local function BuildPrices(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.left = Style.Card(v, "Seen on the Auction House")
    v.left:SetPoint("TOPLEFT")
    v.left:SetPoint("BOTTOMLEFT")
    v.left:SetWidth(470)
    local top = CreateFrame("Frame", nil, v.left.content)
    top:SetPoint("TOPLEFT", 6, -4)
    top:SetPoint("TOPRIGHT", -6, -4)
    top:SetHeight(48)
    v.search = Style.SearchBox(top, function(text)
        state.search = (text or ""):lower()
        UI.Refresh()
    end, "Search items...")
    v.search:SetPoint("TOPLEFT")
    v.search:SetPoint("TOPRIGHT")
    v.chips = Style.Chips(top, { { key = "all", label = "All items" }, { key = "full", label = "With a full look" } }, function(key)
        state.priceFilter = key
        UI.Refresh()
    end)
    v.chips:SetPoint("TOPLEFT", 0, -26)
    local holder = CreateFrame("Frame", nil, v.left.content)
    holder:SetPoint("TOPLEFT", 0, -56)
    holder:SetPoint("BOTTOMRIGHT")
    v.list = Style.List(holder, { colWidths = PRICE_WIDTHS, columns = PRICE_COLUMNS, time = true,
        selected = function(item) return item.id ~= nil and item.id == state.selected end,
        onClick = function(item)
            if item.id then state.selected = item.id UI.Refresh() ShowOnAH(item.id) end
        end })

    v.right = Style.Card(v, "")
    v.right:SetPoint("TOPLEFT", v.left, "TOPRIGHT", 10, 0)
    v.right:SetPoint("BOTTOMRIGHT")
    v.lookup = Style.Button(v.right, "Search at the Auction House", 200, function(self)
        local ok, why = SearchButtonState(state.selected)
        if not ok then ns.Print(why .. ".") return end
        local done, msg = ns.AHHelper.Lookup(state.selected, true)
        if not done and msg then ns.Print(msg) end
    end, { "One search for this item in the Auction House window: one click, one search.",
        "Only while the Auction House is open." }, { kind = "send", small = true })
    v.lookup:SetPoint("TOPRIGHT", -6, -(Style.M.cardHeader - 18) / 2)
    v.right.sub:SetPoint("RIGHT", v.lookup, "LEFT", -8, 0)
    -- The price graph on top, the detail under it.
    v.chart = ns.PriceChart.New(v.right.content)
    v.chart:SetPoint("TOPLEFT", 2, -2)
    v.chart:SetPoint("TOPRIGHT", -2, -2)
    v.chart:SetHeight(150)
    local detailHolder = CreateFrame("Frame", nil, v.right.content)
    detailHolder:SetPoint("TOPLEFT", 0, -158)
    detailHolder:SetPoint("BOTTOMRIGHT")
    v.detail = Style.List(detailHolder, { labelWidth = 74, colWidths = { 110 }, onClick = function(item)
        if item.id and item.id ~= state.selected and Prices.Entry(item.id) then OpenPrices(item.id) end
    end })

    function v:Footer()
        if state.priceFilter == "full" then
            return "Items with a full look (a full scan or an exact search). Reset = buy the cheapest tiers, relist 1c under the "
                .. "next seller's auction. A plan is arithmetic on what you saw: " .. ns.NAME .. " never buys or posts."
        end
        return "Logged as you browse the Auction House: lowest buyout per unit, auctions and units listed. "
            .. "Usual = the middle of your looks, overpriced ones (over " .. Market.OUTLIER_FACTOR .. "x) marked red and left out; "
            .. "% = the price now against your earlier looks (green = cheaper)."
    end

    function v:Refresh()
        local full = state.priceFilter == "full"
        local Desk, DeskUI = ns.AuctionDesk, ns.AuctionDeskUI
        if full and not (Desk and DeskUI) then full, state.priceFilter = false, "all" end
        self.chips:Select(full and "full" or "all")
        local n, newest = Prices.Count()
        self.chips:SetCount("all", n)
        self.chips:SetCount("full", LadderCount())
        if self.mode ~= (full and "full" or "all") then
            self.mode = full and "full" or "all"
            self.list.colWidths = full and CONTROL_WIDTHS or PRICE_WIDTHS
            self.list:SetColumns(full and CONTROL_COLUMNS or PRICE_COLUMNS)
        end
        if full then
            -- Best reset first; the column titles sort it otherwise.
            local markets = Desk.Markets("profit", state.search)
            if state.selected and not Prices.Ladder(state.selected) then state.selected = nil end
            if not state.selected and markets[1] then state.selected = markets[1].id end
            ns.Data.List(self.list, {
                name = "market:control", key = { tostring(markets) }, maxAge = 60, row = DeskUI.MarketRow,
                empty = state.search ~= "" and "Nothing matches." or "No ladders yet: a full scan (or an exact search of one item) shows every auction of an item.",
                build = function(add)
                    for _, p in ipairs(markets) do add(p, { id = p.id }) end
                end,
            })
            self.left.sub:SetText(string.format("%d with a full look  ·  %s", #markets, Prices.RealmKey() or "?"))
        else
            local items = PriceItems()
            if state.selected and not Prices.Entry(state.selected) then state.selected = nil end
            -- A search that hides the chosen item: the first match is chosen.
            if state.selected and state.search ~= "" then
                local shown = false
                for _, it in ipairs(items) do if it.id == state.selected then shown = true break end end
                if not shown then state.selected = nil end
            end
            if not state.selected and items[1] then state.selected = items[1].id end
            ns.Data.List(self.list, {
                name = "market:pricerows", key = { tostring(items) }, maxAge = 60, row = PriceRow,
                empty = state.search ~= "" and "Nothing matches." or "Nothing yet: browse or search the Auction House and prices appear here.",
                build = function(add)
                    for _, it in ipairs(items) do add(it, { id = it.id, time = it.e.t }) end
                end,
            })
            self.left.sub:SetText(string.format("%d items  ·  %s  ·  newest look %s", n,
                Prices.RealmKey() or "?", newest and Prices.Age(newest) or "-"))
        end
        -- Rows are kept; the selection is drawn from state (opts.selected).
        self.list:Draw()

        local id = state.selected
        local ok, why = SearchButtonState(id)
        self.lookup:SetEnabled(ok, why)
        if id then
            self.right.title:SetText(Market.ItemText(id))
            local s = Market.Stats(id)
            self.right.sub:SetText(s and string.format("%s now%s  ·  usual %s  ·  %s", Money(s.p), s.overNow and (HEX.bad .. " (overpriced)|r") or "",
                Money(s.usual and math.floor(s.usual + 0.5)), Supply(s.n, s.a)) or "")
            -- The control plan, only for an item with a full look.
            local extra, plan
            if Desk and DeskUI and Prices.Ladder(id) then
                plan = Desk.Detail(id)
                if plan then extra = DeskUI.ControlRows(plan) end
            end
            self.hasControl = extra ~= nil
            local rows = DetailRows(id, extra)
            self.detail:SetItems(rows)
            if state.focusControl then
                state.focusControl = nil
                -- Opened for its ladder (/talod ah <item>): the plan at the top.
                for i, r in ipairs(rows) do
                    if r.control then self.detail.offset = i - 1 self.detail:Draw() break end
                end
            end
            self.chart:SetItem(id)
        else
            self.hasControl = false
            self.right.title:SetText("")
            self.right.sub:SetText("")
            self.detail:SetItems({})
            self.chart:SetItem(nil)
        end
    end
    return v
end

---------------------------------------------------------------------------
-- Sell: your bags
---------------------------------------------------------------------------
-- Built when drawn: the colour codes follow the look chosen at login.
local function Verdict(key)
    if key == "ah" then return HEX.good .. "Auction House|r" end
    if key == "vendor" then return HEX.gold .. "Vendor|r" end
    if key == "unseen" then return HEX.muted .. "check the AH|r" end
    return HEX.dim .. "no value|r"
end

local function BuildSell(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Your bags")
    v.card:SetAllPoints()
    v.list = Style.List(v.card.content, { colWidths = { 110, 90, 90 }, search = true, hint = "Search your bags...", onClick = function(item)
        ShowOnAH(item.id)
        if item.id and Prices.Entry(item.id) then OpenPrices(item.id) end
    end })

    function v:Footer()
        return "AH = the lowest price at your last look, after the " .. math.floor(Market.CUT * 100)
            .. "% cut; with your sell rate known, the unsold share at the vendor price and the deposit count too. "
            .. "Click an item seen on the AH for its detail."
    end

    function v:Refresh()
        local list = Market.SellList()
        local rows, totalAH, totalVendor, unseen, old = {}, 0, 0, 0, 0
        local current
        for _, e in ipairs(list) do
            if e.verdict ~= current then
                current = e.verdict
                local titles = { ah = "Sell on the Auction House", unseen = "Not seen on the Auction House: look it up there",
                    vendor = "Sell to a vendor", keep = "No vendor or auction value" }
                rows[#rows + 1] = { header = true, text = titles[e.verdict], sortId = "sell", cols = { "Where", "Vendor", "AH after cut" } }
            end
            if e.verdict == "ah" then
                totalAH = totalAH + (e.expected or e.net or 0) * e.n
                if e.stale then old = old + 1 end
            end
            if e.verdict == "vendor" then totalVendor = totalVendor + (e.vendor or 0) * e.n end
            if e.verdict == "unseen" then unseen = unseen + 1 end
            local _, icon = Market.ItemInfo(e.id)
            rows[#rows + 1] = {
                id = e.id, icon = icon, link = e.link,
                text = Market.ItemText(e.id) .. HEX.muted .. "  x" .. e.n .. "|r" .. (e.bound and "" or Market.MoveTag(e.id))
                    -- An old price (or one of unknown age) is not today's market: said on the row.
                    .. ((e.verdict == "ah" and e.stale) and (HEX.gold .. "  · old price: look again|r") or ""),
                cols = { Verdict(e.verdict),
                    e.vendor and e.vendor > 0 and Money(e.vendor * e.n) or (HEX.dim .. "-|r"),
                    -- The number the verdict and the total use: expected with your sell rate, else if it sells.
                    (e.expected or e.net) and Money((e.expected or e.net) * e.n) or (HEX.dim .. "-|r") },
                tooltip = function(owner)
                    local lines = { Market.ItemText(e.id) .. "  x" .. e.n }
                    if e.p then
                        lines[#lines + 1] = string.format("AH: %s each (%s%s%s), %s after the cut", Money(e.p),
                            e.over and "usual price: the lowest now is overpriced, " or "",
                            e.src == "auctionator" and "Auctionator, " or "", Prices.Age(e.t, e.src), Money(e.net))
                        -- Under a whole stack the price to type is the stack's, floored so it
                        -- stays under (a per-unit 4.9c shown as "5c" x 20 is over 99c).
                        local post, _, _, _, stack = Market.PostPrice(e.id)
                        if post and stack and stack > 1 then
                            lines[#lines + 1] = string.format("Post at %s for each %d (%s for all %d)", Money(math.floor(post * stack + 1e-6)),
                                stack, Money(math.floor(post * e.n + 1e-6)), e.n)
                        elseif post then
                            lines[#lines + 1] = string.format("Post at %s each (%s for all %d)", Money(post), Money(post * e.n), e.n)
                        end
                    else
                        lines[#lines + 1] = "Not seen on the Auction House yet."
                    end
                    lines[#lines + 1] = "Vendor: " .. ((e.vendor and e.vendor > 0) and (Money(e.vendor) .. " each") or "no")
                    local rate = Market.SellRateText(e.sales)
                    if rate then
                        lines[#lines + 1] = (e.hard and HEX.bad or "") .. "You: " .. rate .. (e.hard and " — hard to sell|r" or "")
                        if e.expected and e.net and e.expected ~= e.net then
                            lines[#lines + 1] = string.format("Counted at %s each: %s each if it sells, %d%% sell rate, the unsold "
                                .. "share at the vendor price less %s deposit (%s for all %d if every one sells).", Money(e.expected),
                                Money(e.net), Market.RatePct(e.rate) or 0, Money(e.deposit or 0), Money(e.net * e.n), e.n)
                        end
                    end
                    if e.bound then lines[#lines + 1] = HEX.bad .. "Bound to you: no auction for these.|r" end
                    ns.Tooltip.Text(owner, lines)
                end,
            }
        end
        if #rows == 0 then rows[1] = { text = HEX.muted .. "Your bags are empty (or could not be read).|r" } end
        self.list:SetItems(rows)
        self.card.sub:SetText(string.format("Auction House about %s after the cut%s  ·  vendor %s  ·  %d items not seen on the AH",
            Money(totalAH), old > 0 and string.format(" (%d from old prices)", old) or "", Money(totalVendor), unseen))
    end
    return v
end

---------------------------------------------------------------------------
-- Buy > Deals: one list, the Market's columns (each, usual, under) and the
-- desk's (units under the deal price, their cost, the gain)
---------------------------------------------------------------------------
local DEAL_COLUMNS = { name = "Item", "Gain", "Cost", "Units", "Under", "Usual", "Each" }

local function DealGain(d)
    if d.totalGain then return Signed(d.totalGain) end
    if d.gainIfAll then return HEX.muted .. "if all |r" .. Signed(d.gainIfAll) end
    return HEX.good .. "+" .. Money(d.gain) .. "|r" .. HEX.muted .. " each|r"
end

local function DealRow(d)
    local _, icon = Market.ItemInfo(d.id)
    local each = d.p or d.s.p
    local usual = math.floor(d.usual + 0.5)
    local under = (each and d.usual > 0) and (each / d.usual - 1) or nil
    return {
        icon = icon,
        text = Market.ItemText(d.id) .. HEX.muted .. "  " .. Supply(d.s.n, d.s.a) .. "  ·  " .. Prices.Age(d.s.t) .. "|r" .. Market.MoveTag(d.id),
        cols = { DealGain(d), d.cost and Money(d.cost) or ns.UNKNOWN, d.units and tostring(d.units) or ns.UNKNOWN,
            under and Pct(under) or ns.UNKNOWN, HEX.muted .. Money(usual) .. "|r", HEX.white .. Money(each) .. "|r" },
        sort = { d.totalGain or d.gainIfAll or d.gain, d.cost, d.units, under and -under, usual, each },
        tooltip = function(owner)
            local Desk = ns.AuctionDesk
            local t = ns.Tooltip.Open(owner)
            t:Title(Market.ItemText(d.id))
            t:Pair("Now", Money(each) .. " each")
            t:Pair("Usual", Money(usual) .. string.format(" (%d looks)", d.s.looks or 0))
            t:Line(string.format("Each resold at the usual price brings %s after the cut: +%s.", Money(Market.Net(d.usual)), Money(d.gain)))
            if d.units and d.totalGain then
                t:Line(string.format("%d units at the deal price cost %s; expected with your sell rate: %s.", d.units, Money(d.cost),
                    Desk and Desk.Signed(d.totalGain) or Money(d.totalGain)))
            elseif d.units then
                t:Line(string.format("%d units at the deal price cost %s; if all resold: %s (no sell rate of yours yet).", d.units,
                    Money(d.cost), Desk and Desk.Signed(d.gainIfAll or 0) or Money(d.gainIfAll)))
            else
                t:Line("How many are listed at that price: search it on the Auction House (a full look).", "muted")
            end
            t:Note("Look " .. Prices.Age(d.s.t) .. ": check it is still there.")
            t:Hint("Click: search it in the open Auction House (one search per click).")
            t:Show()
        end,
    }
end

local function BuildDeals(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Deals")
    v.card:SetAllPoints()
    v.list = Style.List(v.card.content, { colWidths = { 110, 74, 48, 52, 70, 74 }, columns = DEAL_COLUMNS, search = true,
        time = true, hint = "Search deals...", onClick = function(item)
        if item.id then OpenPrices(item.id) ShowOnAH(item.id) end
    end })

    function v:Footer()
        return string.format("Listed at most %d%% of the usual price (%d+ looks). Units and gain: every unit under that price, resold at "
            .. "the usual price after the cut and the deposit. A click searches it at the open Auction House: one search per click.",
            Market.DEAL_FACTOR * 100, Market.DEAL_LOOKS)
    end

    function v:Refresh()
        local Desk = ns.AuctionDesk
        local data = ns.Data.List(self.list, {
            name = "market:deals", sources = { "prices", "economy" }, key = Prices.RealmKey(), maxAge = 60, row = DealRow,
            empty = "No deals at your last looks. The more you browse, the better \"usual\" gets.",
            build = function(add)
                -- The desk's list: the Market's deals with their depth (none that are all yours).
                local deals = Desk and Desk.Deals() or Market.Deals()
                for _, d in ipairs(deals) do add(d, { id = d.id, time = d.s.t }) end
                return { count = #deals }
            end,
        })
        self.card.sub:SetText(data.count .. " items under their usual price  ·  click one for its prices")
    end
    return v
end

---------------------------------------------------------------------------
-- Buy > Bids: auctions whose next bid is under the item's price, soonest to end first
---------------------------------------------------------------------------
-- "by 14:30": the latest the auction can end (its band at your look).
local function EndsBy(ends, now)
    return HEX.white .. "by " .. date(ends - now > 20 * 3600 and "%a %H:%M" or "%H:%M", ends) .. "|r"
end

local function BidRow(d)
    local r, now = d.r, time()
    local _, icon = Market.ItemInfo(d.id)
    local tags = {}
    if r.high then tags[#tags + 1] = HEX.good .. "you are the high bidder|r" end
    if r.bids and not r.high then tags[#tags + 1] = HEX.gold .. "has bids|r" end
    return {
        icon = icon,
        text = Market.ItemText(d.id) .. (r.count > 1 and (HEX.muted .. "  x" .. r.count .. "|r") or "")
            .. (#tags > 0 and ("  " .. table.concat(tags, HEX.muted .. ", |r")) or "")
            .. HEX.muted .. "  ·  seen " .. Prices.Age(d.t) .. "|r",
        cols = { EndsBy(r.ends, now), HEX.white .. Money(r.next) .. "|r", Money(d.price and math.floor(d.price * r.count + 0.5)),
            d.saving and (HEX.good .. "+" .. Money(d.saving) .. HEX.muted .. " (" .. math.floor(d.pct * 100) .. "%)|r") or (HEX.dim .. "?|r") },
        sort = { r.ends, r.next, d.price and d.price * r.count or -1, d.pct or -1 },
        tooltip = function(owner)
            local t = ns.Tooltip.Open(owner)
            t:Title(Market.ItemText(d.id) .. (r.count > 1 and ("  x" .. r.count) or ""))
            t:Pair("Next bid", Money(r.next) .. (r.count > 1 and ("  (" .. Money(math.floor(r.unit + 0.5)) .. " each)") or ""))
            t:Pair("Its buyout", r.buyout and Money(r.buyout) or "none")
            t:Pair("Item price", d.price and (Money(math.floor(d.price + 0.5)) .. " each") or "?")
            if d.usual then t:Pair("Usual", Money(math.floor(d.usual + 0.5)) .. " each") end
            if d.resale then
                t:Pair("Resold", (d.resale >= 0 and "+" or "-") .. Money(math.abs(math.floor(d.resale + 0.5))), d.resale >= 0 and "good" or "bad")
                t:Note("At the usual price after the " .. math.floor(Market.CUT * 100) .. "% cut, less the bid (deposit not counted).")
            end
            local band = Prices.BANDS[d.api] and r.band and Prices.BANDS[d.api][r.band]
            t:Pair("Time left", band and (band[2] .. " at your look, " .. Prices.Age(d.t)) or "unknown")
            t:Note("Others can still outbid you until it ends, and the game raises the next bid each time. "
                .. "The numbers are from your last look: check them in the Auction House before you bid.")
            t:Hint("Click: search it in the open Auction House.")
            t:Show()
        end,
    }
end

local function BuildBids(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Bids under the price")
    v.card:SetAllPoints()
    v.list = Style.List(v.card.content, { colWidths = { 76, 80, 80, 110 }, search = true, time = true, onClick = function(item)
        if item.id then ShowOnAH(item.id) end
    end })

    function v:Footer()
        return "Auctions you saw on the AH whose next bid is under the item's price (lowest buyout, or usual when that is overpriced). "
            .. "\"by\" = the latest it can end. Others can outbid you: check before you bid."
    end

    function v:Refresh()
        -- Rebuilt when a price or bid changes, else once a minute (ended auctions drop off).
        local data = ns.Data.List(self.list, {
            name = "market:bids", sources = { "prices" }, key = Prices.RealmKey(), maxAge = 60, row = BidRow,
            build = function(add, raw)
                local cols = { "Ends", "Next bid", "Price", "Saving" }
                local current, unpriced, n = nil, {}, 0
                local now = time()
                for _, d in ipairs(Market.Bids()) do
                    if not d.saving then
                        unpriced[#unpriced + 1] = d
                    else
                        -- Grouped by the time left from now (the latest it can end), not
                        -- by the band at looks taken hours apart: the list's order.
                        local title = "Time left unknown"
                        if d.r.band then
                            local left = d.r.ends - now
                            title = "Ends within " .. Market.Duration(left)
                            for _, band in ipairs(Prices.BANDS[d.api] or Prices.BANDS.legacy) do
                                if left <= band[1] then title = "Ends within " .. Market.Duration(band[1]) break end
                            end
                        end
                        if title ~= current then
                            current = title
                            raw({ header = true, text = title, sortId = "bids", cols = cols })
                        end
                        add(d, { id = d.id, time = d.t })
                        n = n + 1
                    end
                end
                if #unpriced > 0 then
                    raw({ header = true, text = "No price to compare" .. HEX.muted .. "  (search the item on the AH)|r", sortId = "bids", cols = cols })
                    for _, d in ipairs(unpriced) do add(d, { id = d.id, time = d.t }) end
                end
                if n == 0 and #unpriced == 0 then
                    raw({ text = HEX.muted .. "No bids under the price at your last looks. Search items (or run a full scan) "
                        .. "and auctions you can bid on for less appear here, soonest to end first.|r" })
                end
                return { count = n, unpriced = #unpriced }
            end,
        })
        self.card.sub:SetText(string.format("%d auctions under the price%s  ·  click one to search it in the AH", data.count,
            data.unpriced > 0 and string.format(", %d without a price", data.unpriced) or ""))
    end
    return v
end

---------------------------------------------------------------------------
-- My auctions > By item: how your own auctions ended, worst sellers first
---------------------------------------------------------------------------
local function SellThroughRow(e)
    local s = e.sales
    local icon
    if e.id then icon = select(2, Market.ItemInfo(e.id)) end
    return {
        icon = icon,
        text = (e.id and Market.ItemText(e.id) or (HEX.white .. (e.name or "?") .. "|r"))
            .. (s.listed > 0 and (HEX.muted .. "  ·  " .. s.listed .. " listed now|r") or ""),
        cols = { (s.rate and ((s.hard and HEX.bad or "") .. Market.RatePct(s.rate) .. "% likely" .. (s.hard and "|r" or ""))
                or (HEX.dim .. "?|r")) .. HEX.muted .. string.format("  %d/%d|r", s.sold, s.ended),
            s.failed > 0 and (HEX.bad .. s.failed .. " unsold|r" .. (s.depositLost > 0 and (HEX.muted .. " -" .. Money(s.depositLost) .. "|r") or ""))
                or (HEX.dim .. "-|r"),
            s.perUnit and Money(math.floor(s.perUnit)) or (HEX.dim .. "-|r") },
        tooltip = function(owner)
            local lines = { e.name or "?", Market.SellRateText(s) or "Nothing ended yet." }
            lines[#lines + 1] = string.format("%d expired, %d cancelled, deposits lost %s", s.expired - s.cancelled, s.cancelled, Money(s.depositLost))
            if s.perUnit then lines[#lines + 1] = "Sold for " .. Money(math.floor(s.perUnit)) .. " each on average (after the cut, your deposit back not counted)." end
            -- With the age: a date without its year reads as this year's.
            if s.lastFailed then lines[#lines + 1] = "Last unsold: " .. date("%b %d %Y", s.lastFailed) .. " (" .. Market.DaysAgo(s.lastFailed) .. ")" end
            if s.last then lines[#lines + 1] = "Last sold: " .. date("%b %d %Y", s.last) .. " (" .. Market.DaysAgo(s.last) .. ")" end
            if e.id then
                local value, how, info = Market.SaleValue(e.id)
                lines[#lines + 1] = "Counted at " .. Money(value) .. " each: " .. Market.SaleValueText(how, info)
            end
            ns.Tooltip.Text(owner, lines)
        end,
    }
end

local function BuildSellThrough(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "What sells and what does not")
    v.card:SetAllPoints()
    v.list = Style.List(v.card.content, { colWidths = { 110, 110, 90 }, search = true, time = true, onClick = function(item)
        ShowOnAH(item.id)
        if item.id and Prices.Entry(item.id) then OpenPrices(item.id) end
    end })

    function v:Footer()
        return "Every auction you posted (all characters), closed by the auction letters. Under " .. math.floor(Market.HARD_RATE * 100)
            .. "% sold with 2+ failures = hard to sell. Values everywhere use your sell rate once " .. Market.SELL_MIN_ENDED .. " have ended."
    end

    function v:Refresh()
        -- Every auction of every character: kept until the economy data changes.
        local data = ns.Data.List(self.list, {
            name = "market:sellthrough", sources = { "economy" }, row = SellThroughRow,
            empty = "No auctions yet: post something and how it ends shows up here.",
            build = function(add, raw)
                local current
                local d = { sold = 0, failed = 0, lost = 0 }
                -- Grouped, worst first; the list's own order (worst sell rate first) is kept inside a group.
                -- Under SELL_MIN_ENDED ended auctions there is no rate: "too few", never "sells".
                local GROUP_ORDER = { hard = 1, mixed = 2, few = 3, good = 4, open = 5 }
                local list = Market.SellThroughList()
                for i, e in ipairs(list) do
                    local s = e.sales
                    -- The smoothed rate never reaches 1: "sells" is none unsold or a chance the movement calls fast.
                    e.group = s.ended == 0 and "open" or (not s.rate and "few") or (s.hard and "hard")
                        or ((s.unsold == 0 or s.rate >= 0.75) and "good" or "mixed")
                    e.order = i
                end
                table.sort(list, function(a, b)
                    if a.group ~= b.group then return GROUP_ORDER[a.group] < GROUP_ORDER[b.group] end
                    return a.order < b.order
                end)
                for _, e in ipairs(list) do
                    local s = e.sales
                    if e.group ~= current then
                        current = e.group
                        raw({ header = true, text = ({ hard = "Hard to sell", mixed = "Sometimes unsold", good = "Sells",
                            few = "Too few ended to tell", open = "Listed, nothing ended yet" })[e.group],
                            sortId = "sellthrough", cols = { "Sell chance", "Unsold", "Average sale" } })
                    end
                    d.sold, d.failed, d.lost = d.sold + s.sold, d.failed + s.failed, d.lost + s.depositLost
                    local last = math.max(s.last or 0, s.lastFailed or 0)
                    add(e, { id = e.id, time = last > 0 and last or nil })
                end
                return d
            end,
        })
        self.card.sub:SetText(string.format("%d sold  ·  %d unsold  ·  %s in deposits lost",
            data.sold, data.failed, Money(data.lost)))
    end
    return v
end

---------------------------------------------------------------------------
-- Title bar: Full scan, the scan panel, the scan log
---------------------------------------------------------------------------
-- The full scan's state for its button: enabled, why not, label.
local function FullScanState()
    local H = ns.AHHelper
    if not H then return false, "no scan panel on this client", "Full scan" end
    if H.state and H.state.scan then
        if H.state.scan.reading then return false, "the full scan is being read", "Reading the scan..." end
        return true, nil, "Stop the full scan"
    end
    local wait = H.NextFullScan()
    if wait > 0 then
        return false, "the server allows one full scan every 15 minutes", string.format("Full scan in %d:%02d", math.floor(wait / 60), wait % 60)
    end
    if not H.IsOpen() then return false, "open the Auction House first", "Full scan" end
    return true, nil, "Full scan"
end

-- One click = one full scan (or stops the one waiting for its answer): the
-- same call and the same limits as the scan panel's button.
local function FullScanClick()
    local ok, why = FullScanState()
    if not ok then ns.Print((why or "not now") .. ".") return end
    local done, msg = ns.AHHelper.FullScan()
    if not done and msg then ns.Print(msg) end
    UI.Refresh()
end
UI.FullScanClick = FullScanClick

function UI.ScanLogLines()
    local log = db().ahScanLog
    local lines = { ns.TITLE .. ": full scans, newest first" }
    if type(log) ~= "table" or #log == 0 then
        lines[#lines + 1] = "No full scans logged yet."
        return lines
    end
    local H = ns.AHHelper
    for i = #log, math.max(1, #log - 9), -1 do
        local e = log[i]
        local text = H and H.ScanText(e) or tostring(e.result)
        lines[#lines + 1] = date("%b %d %H:%M", e.t) .. "  " .. (e.realm or "?") .. "  "
            .. (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
    end
    return lines
end

-- The scan log in the report window (the same lines the command prints).
function UI.ShowScanLog()
    local lines = UI.ScanLogLines()
    if ns.Probe and ns.Probe.ShowText then ns.Probe.ShowText(table.concat(lines, "\n"))
    else for _, l in ipairs(lines) do ns.Print(l) end end
end

local function ScanPanelShown()
    local p = ns.AHHelper and ns.AHHelper.Panel()
    return db().ahHelper and true or false, p ~= nil and p:IsShown()
end

local function ToggleScanPanel()
    local H = ns.AHHelper
    if not H then return end
    db().ahHelper = not db().ahHelper
    if db().ahHelper then
        H.Show()
    else
        local p = H.Panel()
        if p then p:Hide() end
    end
    UI.Refresh()
end
UI.ToggleScanPanel = ToggleScanPanel

local function RefreshHeader()
    if not frame then return end
    local ok, why, label = FullScanState()
    frame.fullScan:SetLabel(label)
    frame.fullScan:SetEnabled(ok, why)
    local on = ScanPanelShown()
    frame.scanPanel:SetLabel("Scan panel: " .. (on and "shown" or "hidden"))
    frame.scanPanel:SetOn(on)
    frame:SetStatus("Auction house: " .. (Prices.RealmKey() or "?"))
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
-- Profit for crafts moved to Professions.
function UI.OpenProfit()
    if ns.Nav and ns.Nav.Go and ns.Nav.Go("prof", "profit") then return true end
    if ns.ProfessionsUI and ns.ProfessionsUI.ShowPage then
        ns.ProfessionsUI.ShowPage("profit")
        return true
    end
    ns.Print("crafting for profit is now on the Professions page (Profit).")
    return false
end

local BUILDERS = {
    { key = "deals", build = BuildDeals }, { key = "bids", build = BuildBids }, { key = "sell", build = BuildSell },
    { key = "sellthrough", build = BuildSellThrough }, { key = "prices", build = BuildPrices },
}

local function SelectView(key)
    state.view = key
    UI.Refresh()
end

local function SelectTab(tab)
    if tab == "buy" then SelectView(state.buyView or "deals")
    elseif tab == "mine" then SelectView(state.mineView or "mine")
    else SelectView(tab) end
end

local function Build()
    frame = Style.Window(ns.FRAME .. "MarketWindow", "Auction House", nil, nil,
        { nav = "ah", settings = "ah", section = "Trade", hidden = true })
    -- Title bar, right to left: scan log, scan panel, full scan.
    frame.scanLog = frame.header:Add(Style.Button(frame, "Scan log", 76, function() UI.ShowScanLog() end,
        "The last full scans, in the report window. Also " .. ns.Cmd.Text("ah", "log") .. ".", { small = true }))
    frame.scanPanel = frame.header:Add(Style.Button(frame, "Scan panel: shown", 130, function() ToggleScanPanel() end,
        "The panel next to the Auction House: full scan and the one-search-per-click list. Also " .. ns.Cmd.Text("ah", "scan") .. ".",
        { small = true, title = "Scan panel" }))
    if ns.Options and ns.Options.Bind then ns.Options.Bind("ahHelper", "quick", "ah") end
    frame.fullScan = frame.header:Add(Style.Button(frame, "Full scan", 140, function() FullScanClick() end,
        "Every auction at once (one every 15 minutes, at the Auction House): the price ladders the plans work from. One click, one scan.",
        { kind = "send", small = true, title = "Full scan" }))
    -- The wait counts down while the page is open.
    local since = 0
    frame:HookScript("OnUpdate", function(_, elapsed)
        since = since + (elapsed or 0)
        if since >= 1 then since = 0 RefreshHeader() end
    end)

    local tabHolder = CreateFrame("Frame", nil, frame)
    tabHolder:SetPoint("TOPLEFT", PAD, -44)
    tabHolder:SetPoint("TOPRIGHT", -PAD, -44)
    tabHolder:SetHeight(26)
    frame.tabs = Style.Tabs(tabHolder, TABS, SelectTab)
    frame.switches = {}
    for tab, defs in pairs(TAB_VIEWS) do
        local sw = Style.Views(tabHolder, defs, SelectView)
        sw:SetPoint("RIGHT", tabHolder, "RIGHT", 0, 0)
        sw:Hide()
        frame.switches[tab] = sw
    end
    local line = Style.HLine(frame)
    line:SetPoint("TOPLEFT", PAD, -70)
    line:SetPoint("TOPRIGHT", -PAD, -70)
    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", PAD, -80)
    body:SetPoint("BOTTOMRIGHT", -PAD, 34)
    frame.body = body
    local DeskUI = ns.AuctionDeskUI
    if DeskUI and DeskUI.BuildToday then views.today = DeskUI.BuildToday(body, UI) end
    if DeskUI and DeskUI.BuildMine then views.mine = DeskUI.BuildMine(body, UI) end
    for _, def in ipairs(BUILDERS) do views[def.key] = def.build(body) end
    frame.footer = Style.Text(frame, "GameFontDisableSmall")
    frame.footer:SetPoint("BOTTOMLEFT", PAD + 2, 12)
    frame.footer:SetPoint("RIGHT", -PAD, 0)
    frame:HookScript("OnShow", function() UI.Refresh() end)
end

function UI.Refresh()
    if not frame or not frame:IsShown() then return end
    if not views[state.view] then state.view = views.today and "today" or "prices" end
    local tab = VIEW_TAB[state.view]
    if tab == "buy" then state.buyView = state.view elseif tab == "mine" then state.mineView = state.view end
    RefreshHeader()
    frame.tabs:Select(tab)
    for key, sw in pairs(frame.switches) do
        sw:SetShown(key == tab)
        if key == tab then sw:Select(state.view) end
    end
    for key, v in pairs(views) do v:SetShown(key == state.view) end
    local v = views[state.view]
    v:Refresh()
    frame.footer:SetText(v:Footer() or "")
end

local TAB_ALIAS = { today = "today", buy = "buy", sell = "sell", mine = "mine", ["my auctions"] = "mine", prices = "prices",
    price = "prices", overview = "today" }
local MINE_FILTERS = { all = true, listed = true, sold = true, expired = true, cancelled = true }

-- Nav's entry point: tab (today / buy / sell / mine / prices, "ah/" allowed),
-- view (Deals / Bids / Auctions / By item, label or key), arg (an item id to
-- select on Prices, a search text for Prices, or a status for My auctions).
function UI.ShowPage(tab, view, arg)
    if not frame then Build() end
    tab = tab and tostring(tab):lower():gsub("^ah/", "") or nil
    tab = tab and TAB_ALIAS[tab] or nil
    local key
    local want = view and tostring(view):lower() or nil
    if tab and TAB_VIEWS[tab] then
        for _, def in ipairs(TAB_VIEWS[tab]) do
            if want and (want == def.key or want == def.label:lower() or (want == "byitem" and def.key == "sellthrough")
                or (want == "auctions" and def.key == "mine")) then key = def.key end
        end
        key = key or (tab == "buy" and state.buyView or state.mineView)
    elseif tab then
        key = tab
    end
    if key and views[key] then state.view = key end
    if type(arg) == "number" then
        -- One item: nothing may hide it (a search, or a filter it is not in).
        state.selected = arg
        if not Prices.Ladder(arg) then state.priceFilter = "all" end
        if state.search ~= "" then
            state.search = ""
            views.prices.search:SetText("")
        end
    elseif type(arg) == "string" and arg ~= "" then
        local a = arg:lower()
        if state.view == "mine" and MINE_FILTERS[a] then
            state.mineFilter = a
        elseif state.view == "prices" then
            state.search = a
            views.prices.search:SetText(arg)
        end
    end
    frame:Show()
    UI.Refresh()
    return true
end

-- Old view keys of the Market window: prices, sell, crafting, deals, bids,
-- sellthrough. view nil: where you left the page. search: Prices' search.
local OLD_VIEW = { prices = { "prices" }, sell = { "sell" }, deals = { "buy", "deals" }, bids = { "buy", "bids" },
    sellthrough = { "mine", "sellthrough" }, today = { "today" }, buy = { "buy" }, mine = { "mine" } }

function UI.Show(view, search)
    if view == "crafting" then return UI.OpenProfit() end
    local to = view and OLD_VIEW[view]
    if to then return UI.ShowPage(to[1], to[2], search) end
    return UI.ShowPage(nil, nil, search)
end

-- Open, or close when it already shows that view (any view when nil).
function UI.Toggle(view)
    if view == "crafting" then return UI.OpenProfit() end
    local to = view and OLD_VIEW[view]
    local shownView = to and (to[2] or (to[1] == "buy" and state.buyView) or (to[1] == "mine" and state.mineView) or to[1])
    if frame and frame:IsShown() and (not view or shownView == state.view) then frame:Hide() else UI.Show(view) end
end

function UI.IsShown() return frame ~= nil and frame:IsShown() end
function UI.Frame() return frame end

-- The Home line and the rail tag: what the Today page computes.
function UI.PageStatus()
    local Desk = ns.AuctionDesk
    if not Desk then return nil end
    local sum = Desk.Summary()
    -- Resets and deals walk every ladder: only what Today or the warm-up
    -- already built, never a build from the rail or Home.
    local opps, deals = ns.Data.Peek("desk:opportunities"), ns.Data.Peek("desk:deals")
    local _, newest = Prices.Count()
    local text = string.format("%d listed · %d undercut", sum.listed, sum.undercut)
        .. (opps and string.format(" · %d resets", #opps) or "")
        .. (deals and string.format(" · %d deals", #deals) or "")
        .. (newest and (" · look " .. Prices.Age(newest)) or " · no look yet")
    return { text = text, tone = sum.undercut > 0 and "bad" or nil, undercut = sum.undercut }
end

UI.state, UI.views = state, views
-- Redrawn when prices (an AH page), your auctions or your recipes change.
-- Frames, the Prices list and Today's numbers (a plan per ladder) are built
-- after login, before the first open. Bags only matter to the Sell tab.
ns.Data.Window(UI, { "prices", "economy", "skills", "crafts", "bags" }, {
    shows = function(src) return src ~= "bags" or state.view == "sell" end,
    prebuild = function() if not frame then Build() end end,
    warm = function()
        PriceItems()
        local Desk = ns.AuctionDesk
        if not Desk then return end
        Desk.Summary()
        Desk.Opportunities()
        Desk.Markets("profit", state.search)
        Desk.Deals()
        Desk.NotWorthIt()
        Desk.DepositRate()
        Market.CraftList(ns.Gear.CharKey(), "known")
    end,
})
