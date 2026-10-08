-- TALOD - Market window (/talod price): Prices (every item you have seen
-- on the Auction House, searchable, with its price graph and detail), Sell (your bags: AH or
-- vendor), Crafting (profit per craft for your professions) and Deals
-- (listed well under the usual price). Numbers come from Market.lua.

local ADDON_NAME, ns = ...
local Style = ns.Style
local COLORS, HEX = Style.COLORS, Style.HEX
local Market, Prices = ns.Market, ns.Prices

local UI = {}
ns.MarketUI = UI

local PAD = 12
local state = { view = "prices", search = "", selected = nil, craftMode = "all", craftFilter = "all" }
local frame
local views = {}

local function Money(c)
    if not c then return HEX.dim .. "-|r" end
    return ns.Professions.Money(c)
end

local function Pct(x)
    if not x then return HEX.dim .. "-|r" end
    local v = math.floor(x * 100 + (x >= 0 and 0.5 or -0.5))
    if v == 0 then return HEX.muted .. "0%|r" end
    return (v < 0 and HEX.good or HEX.bad) .. (v > 0 and "+" or "") .. v .. "%|r"
end

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

local function Supply(n, a)
    local parts = {}
    if a and a > 0 then parts[#parts + 1] = a .. (a == 1 and " auction" or " auctions") end
    if n and n > 0 then parts[#parts + 1] = n .. " units" end
    return #parts > 0 and table.concat(parts, ", ") or "supply ?"
end

---------------------------------------------------------------------------
-- Prices: list + detail
---------------------------------------------------------------------------
local function SearchBox(parent, onChange)
    local box = CreateFrame("EditBox", nil, parent)
    box:SetHeight(22)
    box:SetAutoFocus(false)
    box:SetFontObject("GameFontHighlightSmall")
    box:SetTextInsets(8, 8, 0, 0)
    Style.Surface(box, "button")
    Style.Border(box, COLORS.border)
    box.hint = Style.Text(box, "GameFontDisableSmall")
    box.hint:SetPoint("LEFT", 8, 0)
    box.hint:SetText("Search items...")
    box:SetScript("OnTextChanged", function(self)
        local text = self:GetText() or ""
        self.hint:SetShown(text == "")
        onChange(text)
    end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    return box
end

local function DetailRows(id)
    local out = {}
    local s = Market.Stats(id)
    local name, _, _, sell, bind = Market.ItemInfo(id)
    if not s then return { { text = HEX.muted .. "Not seen on the Auction House yet.|r" } } end
    out[#out + 1] = { header = true, text = "Now" }
    out[#out + 1] = { label = "Lowest", text = HEX.white .. Money(s.p) .. "|r each  ·  " .. AgeText(s.t)
            .. (s.overNow and (HEX.bad .. "  overpriced|r") or ""), cols = { Pct(s.trend) },
        tooltip = function(o) ns.Tooltip.Text(o, { "Lowest buyout per unit at your last look.", "Right: against its usual price.",
            s.overNow and string.format("Over %dx the usual price: the cheap ones are gone or the price was not per unit. "
                .. "Left out of the usual; selling counts the usual price instead.", Market.OUTLIER_FACTOR) or nil }) end }
    out[#out + 1] = { label = "Supply", text = Supply(s.n, s.a), cols = { Pct(s.supplyTrend) },
        tooltip = function(o) ns.Tooltip.Text(o, { "Auctions and units listed at your last look.",
            s.avgN and string.format("Usually %d units. Right: now against that.", math.floor(s.avgN + 0.5)) or "One look so far." }) end }
    out[#out + 1] = { label = "Usual", text = string.format("%s  ·  low %s  ·  high %s  ·  %d looks", Money(s.usual and math.floor(s.usual + 0.5)),
        Money(s.low), Money(s.high), s.looks),
        tooltip = function(o) ns.Tooltip.Text(o, { "Usual price", string.format("The middle (median) of your looks, leaving out the overpriced "
            .. "ones (over %dx the middle; marked red in the graph and under Every look). Low and high: of the looks kept.", Market.OUTLIER_FACTOR) }) end }
    local craft = Market.CraftCost(id)
    if craft then
        local each = math.floor(craft.each + 0.5)
        local diff = s.p and s.p > 0 and (each - s.p) / s.p or nil
        out[#out + 1] = { label = "Craft", text = HEX.white .. Money(each) .. "|r" .. HEX.muted .. " each  ·  " .. craft.r.name
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
    local post, _, atUsual = Market.PostPrice(id)
    out[#out + 1] = { label = "Post at", text = HEX.white .. Money(post) .. "|r" .. HEX.muted
        .. (atUsual and "  each: the usual price (the lowest now is overpriced)" or "  each: 1c under the lowest at your last look")
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
                    .. "Values everywhere are the AH price after the cut times this rate, once 2 have ended." }) end }
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
                .. (pr.guessed and " (partly estimated)" or "") .. "|r",
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
    out[#out + 1] = { header = true, text = "Every look" }
    for i = #s.points, 1, -1 do
        local pt = s.points[i]
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
    local sel = state.selected == it.id
    local _, icon = Market.ItemInfo(it.id)
    return {
        icon = icon,
        text = (sel and HEX.accent or "") .. Market.ItemText(it.id) .. (sel and "|r" or "")
            .. HEX.muted .. "  " .. Supply(it.e.n, it.e.a) .. "|r" .. CraftTag(it.id, it.e.p),
        cols = { AgeText(it.e.t), it.s.overNow and (HEX.bad .. "over|r") or Pct(it.s.trend), HEX.white .. Money(it.e.p) .. "|r" },
        sort = { it.e.t, it.s.trend, it.e.p },
        accent = sel and COLORS.accent or nil,
        tint = sel and { COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.12 } or nil,
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
    top:SetHeight(24)
    v.search = SearchBox(top, function(text)
        state.search = text:lower()
        UI.Refresh()
    end)
    v.search:SetPoint("TOPLEFT")
    v.search:SetPoint("TOPRIGHT")
    local holder = CreateFrame("Frame", nil, v.left.content)
    holder:SetPoint("TOPLEFT", 0, -32)
    holder:SetPoint("BOTTOMRIGHT")
    v.list = Style.List(holder, { colWidths = { 58, 46, 64 }, columns = { name = "Item", "Seen", "Trend", "Price" }, time = true, onClick = function(item)
        if item.id then state.selected = item.id UI.Refresh() ShowOnAH(item.id) end
    end })

    v.right = Style.Card(v, "")
    v.right:SetPoint("TOPLEFT", v.left, "TOPRIGHT", 10, 0)
    v.right:SetPoint("BOTTOMRIGHT")
    -- The price graph on top, the detail under it.
    v.chart = ns.PriceChart.New(v.right.content)
    v.chart:SetPoint("TOPLEFT", 2, -2)
    v.chart:SetPoint("TOPRIGHT", -2, -2)
    v.chart:SetHeight(150)
    local detailHolder = CreateFrame("Frame", nil, v.right.content)
    detailHolder:SetPoint("TOPLEFT", 0, -158)
    detailHolder:SetPoint("BOTTOMRIGHT")
    v.detail = Style.List(detailHolder, { labelWidth = 74, colWidths = { 110 } })

    function v:Footer()
        return "Logged as you browse the Auction House: lowest buyout per unit, auctions and units listed. "
            .. "Usual = the middle of your looks, overpriced ones (over " .. Market.OUTLIER_FACTOR .. "x) marked red and left out; "
            .. "green % = cheaper than usual."
    end

    function v:Refresh()
        local items = PriceItems()
        if state.selected and not Prices.Entry(state.selected) then state.selected = nil end
        if not state.selected and items[1] then state.selected = items[1].id end
        ns.Data.List(self.list, {
            name = "market:pricerows", key = { tostring(items), state.selected }, maxAge = 60, row = PriceRow,
            empty = state.search ~= "" and "Nothing matches." or "Nothing yet: browse or search the Auction House and prices appear here.",
            build = function(add)
                for _, it in ipairs(items) do add(it, { id = it.id, time = it.e.t }) end
            end,
        })
        local n, newest = Prices.Count()
        self.left.sub:SetText(string.format("%d items  ·  %s  ·  newest look %s", n,
            Prices.RealmKey() or "?", newest and Prices.Age(newest) or "-"))

        if state.selected then
            local _, _, quality = Market.ItemInfo(state.selected)
            self.right.title:SetText(Market.ItemText(state.selected))
            local s = Market.Stats(state.selected)
            self.right.sub:SetText(s and string.format("%s now%s  ·  usual %s  ·  %s", Money(s.p), s.overNow and (HEX.bad .. " (overpriced)|r") or "",
                Money(s.usual and math.floor(s.usual + 0.5)), Supply(s.n, s.a)) or "")
            self.detail:SetItems(DetailRows(state.selected))
            self.chart:SetItem(state.selected)
        else
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
local VERDICT = {
    ah = HEX.good .. "Auction House|r", vendor = HEX.gold .. "Vendor|r", unseen = HEX.muted .. "check the AH|r", keep = HEX.dim .. "no value|r",
}

local function BuildSell(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Your bags")
    v.card:SetAllPoints()
    v.list = Style.List(v.card.content, { colWidths = { 110, 90, 90 }, search = true, hint = "Search your bags...", onClick = function(item)
        ShowOnAH(item.id)
        if item.id and Prices.Entry(item.id) then
            state.view, state.selected = "prices", item.id
            UI.Refresh()
        end
    end })

    function v:Footer()
        return "AH = the lowest price at your last look, after the " .. math.floor(Market.CUT * 100)
            .. "% cut (deposit not counted). Click an item seen on the AH for its detail."
    end

    function v:Refresh()
        local list = Market.SellList()
        local rows, totalAH, totalVendor, unseen = {}, 0, 0, 0
        local current
        for _, e in ipairs(list) do
            if e.verdict ~= current then
                current = e.verdict
                local titles = { ah = "Sell on the Auction House", unseen = "Not seen on the Auction House: look it up there",
                    vendor = "Sell to a vendor", keep = "No vendor or auction value" }
                rows[#rows + 1] = { header = true, text = titles[e.verdict], sortId = "sell", cols = { "Where", "Vendor", "AH after cut" } }
            end
            if e.verdict == "ah" then totalAH = totalAH + (e.expected or e.net or 0) * e.n end
            if e.verdict == "vendor" then totalVendor = totalVendor + (e.vendor or 0) * e.n end
            if e.verdict == "unseen" then unseen = unseen + 1 end
            local _, icon = Market.ItemInfo(e.id)
            rows[#rows + 1] = {
                id = e.id, icon = icon, link = e.link,
                text = Market.ItemText(e.id) .. HEX.muted .. "  x" .. e.n .. "|r" .. (e.bound and "" or Market.MoveTag(e.id)),
                cols = { VERDICT[e.verdict],
                    e.vendor and e.vendor > 0 and Money(e.vendor * e.n) or (HEX.dim .. "-|r"),
                    e.net and Money(e.net * e.n) or (HEX.dim .. "-|r") },
                tooltip = function(owner)
                    local lines = { Market.ItemText(e.id) .. "  x" .. e.n }
                    if e.p then
                        lines[#lines + 1] = string.format("AH: %s each (%s%s%s), %s after the cut", Money(e.p),
                            e.over and "usual price: the lowest now is overpriced, " or "",
                            e.src == "auctionator" and "Auctionator, " or "", Prices.Age(e.t, e.src), Money(e.net))
                        local post = Market.PostPrice(e.id)
                        if post then lines[#lines + 1] = string.format("Post at %s each (%s for all %d)", Money(post), Money(post * e.n), e.n) end
                    else
                        lines[#lines + 1] = "Not seen on the Auction House yet."
                    end
                    lines[#lines + 1] = "Vendor: " .. ((e.vendor and e.vendor > 0) and (Money(e.vendor) .. " each") or "no")
                    local rate = Market.SellRateText(e.sales)
                    if rate then
                        lines[#lines + 1] = (e.hard and HEX.bad or "") .. "You: " .. rate .. (e.hard and " — hard to sell|r" or "")
                        if e.expected and e.net and e.expected < e.net then
                            lines[#lines + 1] = "Counted at " .. Money(e.expected) .. " each (AH after the cut x your sell rate)."
                        end
                    end
                    if e.bound then lines[#lines + 1] = HEX.bad .. "Binds when picked up.|r" end
                    ns.Tooltip.Text(owner, lines)
                end,
            }
        end
        if #rows == 0 then rows[1] = { text = HEX.muted .. "Your bags are empty (or could not be read).|r" } end
        self.list:SetItems(rows)
        self.card.sub:SetText(string.format("Auction House about %s after the cut  ·  vendor %s  ·  %d items not seen on the AH",
            Money(totalAH), Money(totalVendor), unseen))
    end
    return v
end

---------------------------------------------------------------------------
-- Crafting: profit per craft, list + detail
---------------------------------------------------------------------------
local CRAFT_FILTERS = {
    { key = "all", label = "All recipes" }, { key = "profit", label = "Profitable only" }, { key = "make", label = "In my bags" },
}
local DOUBLE_CLICK = 0.4      -- seconds between the two clicks that open the craft tracker
local CRAFT_MODES = { { key = "known", label = "Recipes I know" }, { key = "all", label = "All I can make" } }

local function ProfitText(p)
    if not p then return HEX.dim .. "-|r" end
    return (p >= 0 and HEX.good or (HEX.bad .. "-")) .. Money(math.abs(p)) .. "|r"
end

local function MarginText(m)
    if not m then return HEX.dim .. "-|r" end
    local v = math.floor(m * 100 + (m >= 0 and 0.5 or -0.5))
    return (v >= 0 and HEX.good or HEX.bad) .. (v > 0 and "+" or "") .. v .. "%|r"
end

local function CraftRow(pr)
    local r = pr.r
    local sel = state.craftSel == r
    local tags = {}
    if not pr.known then tags[#tags + 1] = "not learned" end
    if pr.cooldown then tags[#tags + 1] = "once a day" end
    local make = (pr.canMake or 0) > 0 and (HEX.good .. "  · make " .. pr.canMake .. "|r") or ""
    return {
        icon = ns.Professions.ItemIcon(r.creates),
        text = (sel and HEX.accent or "") .. Market.ItemText(r.creates) .. (sel and "|r" or "")
            .. ((r.makes or 1) ~= 1 and (" x" .. r.makes) or "") .. HEX.muted .. "  " .. r.prof
            .. (#tags > 0 and ("  (" .. table.concat(tags, ", ") .. ")") or "") .. "|r" .. make
            .. (pr.priced and Market.MoveTag(r.creates) or ""),
        cols = { Money(pr.cost) .. (pr.guessed and (HEX.muted .. "*|r") or ""), ProfitText(pr.profit), MarginText(pr.margin) },
        accent = sel and COLORS.accent or nil,
        tint = sel and { COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.12 } or nil,
    }
end

-- The detail of one recipe: per craft, the product's market, each material
-- (price, where from, in your bags, cheaper to make), what your bags make.
local function CraftDetailRows(pr)
    local r = pr.r
    local out = {}
    local makes = r.makes or 1
    local plan = Market.CraftPlan(r)
    out[#out + 1] = { header = true, text = "Per craft" .. (makes ~= 1 and (HEX.muted .. "  (makes " .. makes .. ")|r") or "") }
    out[#out + 1] = { label = "Materials", text = HEX.white .. Money(pr.cost) .. "|r" .. HEX.muted
        .. (makes ~= 1 and ("  ·  " .. Money(pr.cost / makes) .. " each") or "")
        .. (pr.guessed and "  ·  partly estimated" or "") .. "|r" }
    if pr.priced then
        out[#out + 1] = { label = "Sells for", text = Money(pr.value) .. HEX.muted .. "  after the " .. math.floor(Market.CUT * 100) .. "% cut"
            .. (pr.rate and (" and your " .. math.floor(pr.rate * 100 + 0.5) .. "% sell rate") or "") .. "|r",
            tooltip = function(o) ns.Tooltip.Text(o, { "Sells for", "The product's lowest buyout at your last look (the usual price when that "
                .. "look was overpriced), after the Auction House cut, times your sell rate once 2 of your auctions of it have ended." }) end }
        out[#out + 1] = { label = "Profit", text = ProfitText(pr.profit) .. HEX.muted .. "  ·  margin |r" .. MarginText(pr.margin) }
    else
        out[#out + 1] = { label = "Sells for", text = HEX.muted .. "not seen on the Auction House: search it there|r" }
    end
    if pr.vendor then
        out[#out + 1] = { label = "Vendor", text = Money(pr.vendor) .. ((pr.vendor > pr.cost) and (HEX.good .. "  more than the materials|r") or "") }
    end

    if pr.priced then
        local s = Market.Stats(r.creates)
        out[#out + 1] = { header = true, text = "Its market" }
        if s then
            out[#out + 1] = { label = "Lowest", text = Money(s.p) .. " each  ·  " .. AgeText(s.t) .. HEX.muted .. "  ·  usual "
                .. Money(s.usual and math.floor(s.usual + 0.5)) .. "|r", cols = { Pct(s.trend) },
                id = r.creates, tooltip = function(o) ns.Tooltip.Text(o, { "Click: its prices." }) end }
            out[#out + 1] = { label = "Supply", text = Supply(s.n, s.a) }
        end
        local mv = Market.Movement(r.creates)
        local ev = Market.MovementLines(mv)
        out[#out + 1] = { label = "Moves", text = mv.hex .. mv.label .. "|r" .. HEX.muted .. "  " .. ev[1] .. "|r" }
        if ev[2] then out[#out + 1] = { label = "", text = HEX.muted .. ev[2] .. "|r" } end
    end

    out[#out + 1] = { header = true, text = "Materials" .. HEX.muted .. "  (price each, in your bags)|r", sortId = "materials", cols = { "Per craft" } }
    for _, e in ipairs(plan.reagents) do
        local price = e.src == "unknown" and (HEX.bad .. "no price|r") or (HEX.muted .. ns.Professions.PriceText(e.id) .. "|r")
        out[#out + 1] = { label = e.need .. " x", text = Market.ItemText(e.id) .. "  " .. price
                .. HEX.muted .. "  ·  have |r" .. (e.have >= e.need and HEX.good or HEX.muted) .. e.have .. "|r",
            cols = { e.src == "unknown" and (HEX.dim .. "?|r") or Money(e.sub) },
            id = Prices.Entry(e.id) and e.id or nil }
        if e.craft then
            out[#out + 1] = { label = "", text = HEX.gold .. "make it: " .. Money(math.floor(e.craft.each + 0.5)) .. " each|r"
                .. HEX.muted .. "  (" .. e.craft.r.name .. ", " .. e.craft.r.prof .. (e.craft.estimated and ", estimated" or "") .. ")|r" }
        end
    end

    out[#out + 1] = { header = true, text = "From your bags" }
    if plan.canMake > 0 then
        out[#out + 1] = { label = "Can make", text = HEX.good .. plan.canMake .. (plan.canMake == 1 and " craft" or " crafts") .. "|r"
            .. HEX.muted .. "  (" .. plan.canMake * makes .. " items)|r"
            .. (pr.priced and (HEX.muted .. "  ·  |r" .. ProfitText(pr.profit * plan.canMake) .. HEX.muted .. " over the materials' price|r") or "") }
    else
        out[#out + 1] = { label = "Can make", text = HEX.muted .. "none yet|r" }
        out[#out + 1] = { label = "Buy", text = Money(plan.buyCost) .. HEX.muted .. "  of materials you lack for one craft|r" }
    end

    out[#out + 1] = { header = true, text = "Recipe" }
    out[#out + 1] = { label = r.prof:sub(1, 12), text = r.name .. HEX.muted .. "  ·  skill " .. r.skill
        .. (pr.known and "  ·  you know it" or "  ·  not learned (or the profession window not opened yet)")
        .. (pr.cooldown and "  ·  once a day" or "") .. "|r" }
    if r.colors then
        out[#out + 1] = { label = "Skill-ups", text = HEX.muted .. string.format("orange %d, yellow %d, green %d, grey %d", r.colors[1] or 0,
            r.colors[2] or 0, r.colors[3] or 0, r.colors[4] or 0) .. "|r" }
    end
    return out
end

-- Most profit first (the column titles sort it otherwise); unpriced by name.
local function ByProfit(a, b) return (a.profit or -math.huge) > (b.profit or -math.huge) end
local function ByName(a, b) return a.r.name < b.r.name end

-- A button that cycles through choices (right-click back) with a dropdown.
local function CycleButton(parent, width, items, get, set, tip, title)
    local b = Style.Button(parent, "", width, function(_, button)
        local i = 1
        for n, it in ipairs(items) do if it.key == get() then i = n end end
        i = i + (button == "RightButton" and -1 or 1)
        if i > #items then i = 1 elseif i < 1 then i = #items end
        set(items[i].key)
        UI.Refresh()
    end, tip, { title = title })
    Style.AttachDropdown(b, function()
        return Style.ChoiceItems(items, get(), function(key) set(key) UI.Refresh() end)
    end)
    function b:Update()
        for _, it in ipairs(items) do if it.key == get() then self:SetLabel(it.label .. "  >") end end
    end
    return b
end

local function BuildCrafting(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Crafting for profit")
    v.card:SetPoint("TOPLEFT")
    v.card:SetPoint("BOTTOMLEFT")
    v.card:SetWidth(470)
    local top = CreateFrame("Frame", nil, v.card.content)
    top:SetPoint("TOPLEFT", 6, -4)
    top:SetPoint("TOPRIGHT", -6, -4)
    top:SetHeight(24)
    v.mode = CycleButton(top, 140, CRAFT_MODES, function() return state.craftMode end, function(k) state.craftMode = k end,
        "Only recipes you know (open your profession window once), or every recipe your skill allows.", "Recipes")
    v.mode:SetPoint("TOPLEFT")
    v.filter = CycleButton(top, 140, CRAFT_FILTERS, function() return state.craftFilter end, function(k) state.craftFilter = k end,
        "All recipes, only those that make money, or only those your bags hold the materials for.", "Show")
    v.filter:SetPoint("LEFT", v.mode, "RIGHT", 6, 0)
    local holder = CreateFrame("Frame", nil, v.card.content)
    holder:SetPoint("TOPLEFT", 0, -32)
    holder:SetPoint("BOTTOMRIGHT")
    v.list = Style.List(holder, { colWidths = { 64, 64, 46 }, search = true, hint = "Search recipes, professions...",
        onClick = function(item)
            if not item.pr then return end
            local r, now = item.pr.r, GetTime()
            -- A second click on the same recipe within DOUBLE_CLICK seconds
            -- (list rows have no double-click of their own): the floating
            -- tracker, with what it takes, the cheapest route and Craft next.
            local double = v.lastClick and v.lastClick.r == r and now - v.lastClick.at <= DOUBLE_CLICK
            v.lastClick = not double and { r = r, at = now } or nil
            state.craftSel = r
            UI.Refresh()
            if double and ns.CraftTrackUI then ns.CraftTrackUI.Open(r) end
            if not double then ShowOnAH(r.creates) end
        end })

    v.right = Style.Card(v, "")
    v.right:SetPoint("TOPLEFT", v.card, "TOPRIGHT", 10, 0)
    v.right:SetPoint("BOTTOMRIGHT")
    v.chart = ns.PriceChart.New(v.right.content)
    v.chart:SetPoint("TOPLEFT", 2, -2)
    v.chart:SetPoint("TOPRIGHT", -2, -2)
    v.chart:SetHeight(110)
    local detailHolder = CreateFrame("Frame", nil, v.right.content)
    detailHolder:SetPoint("TOPLEFT", 0, -118)
    detailHolder:SetPoint("BOTTOMRIGHT")
    v.detail = Style.List(detailHolder, { labelWidth = 74, colWidths = { 70 }, onClick = function(item)
        ShowOnAH(item.id)
        if item.id and Prices.Entry(item.id) then state.view, state.selected = "prices", item.id UI.Refresh() end
    end })

    function v:Footer()
        return "Materials at the best known prices (vendor, your AH looks, else Wowhead estimates *) against the product's AH price "
            .. "after the cut and your sell rate. Click a column title to sort."
    end

    function v:Refresh()
        self.mode:Update() self.filter:Update()
        -- Every recipe's materials priced: kept until prices, skills, known
        -- recipes, your sales or your bags change.
        local data = ns.Data.List(self.list, {
            name = "market:crafting", sources = { "prices", "skills", "crafts", "economy", "bags" },
            key = { ns.Gear.CharKey(), state.craftMode, state.craftFilter, state.craftSel }, row = CraftRow,
            build = function(add, raw)
                local all = Market.CraftList(ns.Gear.CharKey(), state.craftMode, { cooldowns = true, bags = true })
                local priced, unpriced, winners, seen = {}, {}, 0, 0
                for _, pr in ipairs(all) do
                    if pr.priced then seen = seen + 1 end
                    if pr.priced and pr.profit > 0 then winners = winners + 1 end
                    local keep = state.craftFilter == "all" or (state.craftFilter == "profit" and pr.priced and pr.profit > 0)
                        or (state.craftFilter == "make" and (pr.canMake or 0) > 0)
                    if keep then table.insert(pr.priced and priced or unpriced, pr) end
                end
                table.sort(priced, ByProfit)
                table.sort(unpriced, ByName)
                raw({ header = true, text = "Recipe", sortId = "craft", cols = { "Materials", "Profit", "Margin" } })
                for _, pr in ipairs(priced) do add(pr, { pr = pr }) end
                if #priced == 0 then
                    raw({ text = HEX.muted .. "No product of these recipes seen on the Auction House yet. Search for what you can make there.|r" })
                end
                if #unpriced > 0 then
                    raw({ header = true, text = "Not seen on the Auction House" .. HEX.muted .. "  (search them there)|r", sortId = "craft",
                        cols = { "Materials", "", "" } })
                    for _, pr in ipairs(unpriced) do add(pr, { pr = pr }) end
                end
                return { all = all, seen = seen, winners = winners }
            end,
        })
        local sel
        for _, pr in ipairs(data.all) do if pr.r == state.craftSel then sel = pr end end
        if not sel then
            -- Nothing chosen yet: the best earner, else the first recipe.
            for _, pr in ipairs(data.all) do
                if pr.priced and (not sel or pr.profit > sel.profit) then sel = pr end
            end
            sel = sel or data.all[1]
        end
        state.craftSel = sel and sel.r or nil
        self.card.sub:SetText(string.format("%d recipes  ·  %d make money  ·  %d not seen on the AH", #data.all, data.winners,
            #data.all - data.seen))
        if sel then
            local r = sel.r
            self.right.title:SetText(Market.ItemText(r.creates) .. ((r.makes or 1) ~= 1 and (" x" .. r.makes) or ""))
            self.right.sub:SetText(sel.priced and ("profit " .. ProfitText(sel.profit) .. " per craft  ·  margin " .. MarginText(sel.margin))
                or ("materials " .. Money(sel.cost) .. "  ·  product not seen on the AH"))
            self.detail:SetItems(CraftDetailRows(sel))
            self.chart:SetItem(sel.priced and r.creates or nil)
        else
            self.right.title:SetText("")
            self.right.sub:SetText("")
            self.detail:SetItems({ { text = HEX.muted .. "No recipes: learn a profession, or open its window once.|r" } })
            self.chart:SetItem(nil)
        end
    end
    return v
end

---------------------------------------------------------------------------
-- Deals
---------------------------------------------------------------------------
local function DealRow(d)
    local _, icon = Market.ItemInfo(d.id)
    return {
        icon = icon,
        text = Market.ItemText(d.id) .. HEX.muted .. "  " .. Supply(d.s.n, d.s.a) .. "  ·  " .. Prices.Age(d.s.t) .. "|r",
        cols = { HEX.white .. Money(d.s.p) .. "|r", Money(math.floor(d.usual + 0.5)), HEX.good .. "+" .. Money(d.gain)
            .. HEX.muted .. " (" .. math.floor(d.gain / math.max(1, d.s.p) * 100) .. "%)|r" },
    }
end

local function BuildDeals(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Deals")
    v.card:SetAllPoints()
    v.list = Style.List(v.card.content, { colWidths = { 90, 90, 100 }, search = true, time = true, onClick = function(item)
        if item.id then state.view, state.selected = "prices", item.id UI.Refresh() ShowOnAH(item.id) end
    end })

    function v:Footer()
        return string.format("At most %d%% of the usual price, with %d+ looks. Gain: resold at the usual price after the cut. "
            .. "Prices are your last look: check they are still there.", Market.DEAL_FACTOR * 100, Market.DEAL_LOOKS)
    end

    function v:Refresh()
        -- Every priced item is checked: kept until a price changes (a minute
        -- at most, for the ages), rows formatted when drawn.
        local data = ns.Data.List(self.list, {
            name = "market:deals", sources = { "prices" }, key = Prices.RealmKey(), maxAge = 60, row = DealRow,
            build = function(add, raw)
                raw({ header = true, text = "Item", cols = { "Now", "Usual", "Gain each" } })
                local n = 0
                for _, d in ipairs(Market.Deals()) do add(d, { id = d.id, time = d.s.t }) n = n + 1 end
                if n == 0 then raw({ text = HEX.muted .. "No deals at your last looks. The more you browse, the better \"usual\" gets.|r" }) end
                return { count = n }
            end,
        })
        self.card.sub:SetText(data.count .. " items under their usual price  ·  click one for its detail")
    end
    return v
end

---------------------------------------------------------------------------
-- Bids: auctions whose next bid is under the item's price, soonest to end first
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
                t:Pair("Resold", (d.resale >= 0 and "+" or "-") .. Money(math.abs(math.floor(d.resale + 0.5))), d.resale >= 0 and "safe" or "danger")
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
                for _, d in ipairs(Market.Bids()) do
                    if not d.saving then
                        unpriced[#unpriced + 1] = d
                    else
                        local band = d.r.band and Prices.BANDS[d.api] and Prices.BANDS[d.api][d.r.band]
                        local title = band and ("Time left " .. band[2] .. " at your look") or "Time left unknown"
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
-- Window
---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- Sell-through: how your own auctions ended, worst sellers first
---------------------------------------------------------------------------
local function SellThroughRow(e)
    local s = e.sales
    local icon
    if e.id then icon = select(2, Market.ItemInfo(e.id)) end
    return {
        icon = icon,
        text = (e.id and Market.ItemText(e.id) or (HEX.white .. (e.name or "?") .. "|r"))
            .. (s.listed > 0 and (HEX.muted .. "  ·  " .. s.listed .. " listed now|r") or ""),
        cols = { (s.rate and ((s.hard and HEX.bad or "") .. math.floor(s.rate * 100 + 0.5) .. "% sold" .. (s.hard and "|r" or ""))
                or (HEX.dim .. "?|r")) .. HEX.muted .. string.format("  %d/%d|r", s.sold, s.ended),
            s.failed > 0 and (HEX.bad .. s.failed .. " unsold|r" .. (s.depositLost > 0 and (HEX.muted .. " -" .. Money(s.depositLost) .. "|r") or ""))
                or (HEX.dim .. "-|r"),
            s.perUnit and Money(math.floor(s.perUnit)) or (HEX.dim .. "-|r") },
        tooltip = function(owner)
            local lines = { e.name or "?", Market.SellRateText(s) or "Nothing ended yet." }
            lines[#lines + 1] = string.format("%d expired, %d cancelled, deposits lost %s", s.expired - s.cancelled, s.cancelled, Money(s.depositLost))
            if s.perUnit then lines[#lines + 1] = "Sold for " .. Money(math.floor(s.perUnit)) .. " each on average (what you received)." end
            if s.lastFailed then lines[#lines + 1] = "Last unsold: " .. date("%b %d", s.lastFailed) end
            if s.last then lines[#lines + 1] = "Last sold: " .. date("%b %d", s.last) end
            if e.id then
                local value, how = Market.SaleValue(e.id)
                lines[#lines + 1] = "Counted at " .. Money(value) .. " each (" .. (how == "ah" and "AH x your sell rate" or (how or "no price")) .. ")"
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
        if item.id and Prices.Entry(item.id) then state.view, state.selected = "prices", item.id UI.Refresh() end
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
                    e.group = s.ended == 0 and "open" or (not s.rate and "few") or (s.hard and "hard") or (s.rate < 1 and "mixed" or "good")
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
                            sortId = "sellthrough", cols = { "Sell rate", "Unsold", "Average sale" } })
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

local VIEWS = {
    { key = "prices", label = "Prices", build = BuildPrices },
    { key = "sell", label = "Sell", build = BuildSell },
    { key = "crafting", label = "Crafting", build = BuildCrafting },
    { key = "deals", label = "Deals", build = BuildDeals },
    { key = "bids", label = "Bids", build = BuildBids },
    { key = "sellthrough", label = "Sell-through", build = BuildSellThrough },
}

local function Build()
    frame = Style.Window(ns.FRAME .. "MarketWindow", "Market", nil, nil, { nav = "market", hidden = true })
    frame.realm = Style.Text(frame, "GameFontDisableSmall", "RIGHT")
    frame.realm:SetPoint("TOPRIGHT", -44, -16)
    local tabHolder = CreateFrame("Frame", nil, frame)
    tabHolder:SetPoint("TOPLEFT", PAD, -44)
    tabHolder:SetPoint("TOPRIGHT", -PAD, -44)
    tabHolder:SetHeight(26)
    frame.tabs = Style.Tabs(tabHolder, VIEWS, function(key) state.view = key UI.Refresh() end, 110)
    local line = Style.HLine(frame)
    line:SetPoint("TOPLEFT", PAD, -70)
    line:SetPoint("TOPRIGHT", -PAD, -70)
    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", PAD, -80)
    body:SetPoint("BOTTOMRIGHT", -PAD, 34)
    for _, def in ipairs(VIEWS) do views[def.key] = def.build(body) end
    frame.footer = Style.Text(frame, "GameFontDisableSmall")
    frame.footer:SetPoint("BOTTOMLEFT", PAD + 2, 12)
    frame.footer:SetPoint("RIGHT", -PAD, 0)
    frame:HookScript("OnShow", function() UI.Refresh() end)
end

function UI.Refresh()
    if not frame or not frame:IsShown() then return end
    frame.realm:SetText("Auction house: " .. (Prices.RealmKey() or "?"))
    frame.tabs:Select(state.view)
    for key, v in pairs(views) do v:SetShown(key == state.view) end
    local v = views[state.view]
    v:Refresh()
    frame.footer:SetText(v:Footer() or "")
end

-- view: tab key; search: text for the Prices search box.
function UI.Show(view, search)
    if not frame then Build() end
    if view and views[view] then state.view = view end
    if search then
        state.search = search:lower()
        views.prices.search:SetText(search)
    end
    frame:Show()
    UI.Refresh()
end

function UI.Toggle(view)
    if frame and frame:IsShown() and (not view or view == state.view) then frame:Hide() else UI.Show(view) end
end

function UI.IsShown() return frame ~= nil and frame:IsShown() end
UI.state, UI.views = state, views
-- Redrawn when prices (an AH page), your auctions or your recipes change.
-- Frames and the Prices list are built after login, before the first open.
-- Bags only matter to the Sell and Crafting tabs.
ns.Data.Window(UI, { "prices", "economy", "skills", "crafts", "bags" }, {
    shows = function(src) return src ~= "bags" or state.view == "sell" or state.view == "crafting" end,
    prebuild = function() if not frame then Build() end end,
    warm = function() PriceItems() end,
})
