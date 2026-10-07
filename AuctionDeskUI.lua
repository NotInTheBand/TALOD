-- TALOD - Auction desk window (/talod ah): Overview, Listings (yours
-- against the market), Deals (with how many units sit at the deal price),
-- Margins (crafting profit and margin) and Control (what owning an item's
-- market costs, the resets worth doing, who holds the supply, the price
-- graph with volume, the price ladder). Numbers come from AuctionDesk.lua; nothing here buys or posts.

local ADDON_NAME, ns = ...
local Style = ns.Style
local COLORS, HEX = Style.COLORS, Style.HEX
local Market, Prices, Desk = ns.Market, ns.Prices, ns.AuctionDesk

local UI = {}
ns.AuctionDeskUI = UI

local PAD = 12
local state = { view = "overview", search = "", selected = nil, craftMode = "known" }
local frame
local views = {}

local function Money(c)
    if not c then return HEX.dim .. "-|r" end
    return ns.Professions.Money(c)
end

local function Profit(c)
    if not c then return HEX.dim .. "-|r" end
    return (c >= 0 and HEX.good or HEX.bad) .. Desk.Signed(c) .. "|r"
end

local function Pct(x, goodHigh)
    if not x then return HEX.dim .. "-|r" end
    local v = math.floor(x * 100 + (x >= 0 and 0.5 or -0.5))
    local good = goodHigh and v > 0 or (not goodHigh and v < 0)
    return (v == 0 and HEX.muted or (good and HEX.good or HEX.bad)) .. (v > 0 and "+" or "") .. v .. "%|r"
end

-- A look's age: fresh green, under a day gold, older grey.
local function AgeText(t)
    if not t then return HEX.dim .. "?|r" end
    local age = time() - t
    local color = age < Desk.FRESH and HEX.good or (age < 86400 and HEX.gold or HEX.muted)
    return color .. Prices.Age(t) .. "|r"
end

local function Open(id)
    if not id then return end
    state.view, state.selected, state.search = "control", id, ""
    if views.control and views.control.search then views.control.search:SetText("") end
    UI.Refresh()
end

local function ItemRow(id, text, cols, tooltip)
    local _, icon = Market.ItemInfo(id)
    return { id = id, icon = icon, text = text, cols = cols, tooltip = tooltip }
end

local STANDING = {
    lowest = HEX.good .. "lowest|r", undercut = HEX.bad .. "undercut|r", unknown = HEX.muted .. "?|r",
}

local function StandingText(e)
    if e.overdue then return HEX.muted .. "should have ended|r" end
    local st = e.standing
    if st.state == "undercut" then
        return HEX.bad .. "undercut|r" .. HEX.muted .. (st.ahead and (" · " .. st.ahead .. " under") or "") .. "|r"
    end
    return STANDING[st.state]
end

local function ListingTooltip(e)
    return function(owner)
        local st = e.standing
        local lines = { (e.id and Market.ItemText(e.id) or (e.name or "?")) .. "  x" .. e.count }
        lines[#lines + 1] = "Yours: " .. Money(e.unit) .. " each, " .. Money(e.value) .. " after the cut for all."
        if st.state == "undercut" then
            lines[#lines + 1] = HEX.bad .. (st.ahead and (st.ahead .. " units listed under yours") or "Listed under yours") .. "|r"
                .. ", the lowest at " .. Money(st.lowest) .. "."
            if st.repost then lines[#lines + 1] = "To be the lowest again: cancel and repost at " .. Money(st.repost) .. " each." end
        elseif st.state == "lowest" then
            lines[#lines + 1] = HEX.good .. "Nobody else is cheaper|r" .. (st.lowest and ("; the next seller asks " .. Money(st.lowest) .. ".") or ".")
        else
            lines[#lines + 1] = HEX.muted .. "No look at this item that tells: search it on the Auction House.|r"
        end
        if st.age then lines[#lines + 1] = HEX.muted .. "Market look " .. Prices.Age(time() - st.age) .. (st.partial and ", partial" or "") .. ".|r" end
        if e.left then lines[#lines + 1] = "Time left: " .. (type(e.left) == "number" and (math.floor(e.left / 3600) .. " h " .. math.floor(e.left % 3600 / 60) .. " min") or e.left) end
        if e.endsAt then lines[#lines + 1] = (e.overdue and "Should have ended " or "Ends about ") .. date("%b %d %H:%M", e.endsAt) .. (e.overdue and ": check your mail." or ".") end
        if e.deposit then lines[#lines + 1] = "Deposit paid: " .. Money(e.deposit) .. " (lost if it does not sell)."
        elseif e.depositGuess then lines[#lines + 1] = "Deposit about " .. Money(e.depositGuess) .. HEX.muted .. " (not in your posting log: from your deposit rate)|r" end
        if e.id then
            local mv = Market.Movement(e.id)
            lines[#lines + 1] = "Sells: " .. mv.hex .. mv.label .. "|r"
            for _, l in ipairs(Market.MovementLines(mv)) do lines[#lines + 1] = HEX.muted .. "  " .. l .. "|r" end
        end
        ns.Tooltip.Text(owner, lines)
    end
end

local function ResetText(step)
    return string.format("buy %d up to %s, relist at %s", step.units, Money(step.upTo), Money(step.relist))
end

local function PlanTooltip(plan)
    return function(owner)
        local lines = { Market.ItemText(plan.id) }
        local L = plan.ladder
        lines[#lines + 1] = string.format("%d units in %d auctions, look %s%s", L.units, L.auctions or 0, Prices.Age(L.t),
            plan.atLeast and " (partial: costs are at least)" or "")
        if plan.best then
            local b = plan.best
            lines[#lines + 1] = string.format("Reset: buy %d units up to %s for %s.", b.units, Money(b.upTo), Money(b.cost))
            lines[#lines + 1] = string.format("Relist all at %s: %s after the %d%% cut%s, deposit %s.", Money(b.relist), Money(b.revenue),
                math.floor(Market.CUT * 100), plan.rate and (" and your " .. math.floor(plan.rate * 100 + 0.5) .. "% sell rate") or "", Money(b.deposit))
            lines[#lines + 1] = "Profit if it all sells: " .. Profit(b.profit) .. (b.roi and ("  (" .. math.floor(b.roi * 100 + 0.5) .. "% on the money)") or "")
            if b.overUsual and b.overUsual > 0.25 then
                lines[#lines + 1] = HEX.gold .. "The relist is " .. math.floor(b.overUsual * 100 + 0.5) .. "% over the usual price: it may sit.|r"
            end
        end
        local h = plan.holders
        if h and h.share >= Desk.CONTROL_SHARE and not h.mine then
            lines[#lines + 1] = HEX.gold .. (h.name or "One seller") .. " holds " .. math.floor(h.share * 100 + 0.5) .. "% of it: expect them to answer.|r"
        end
        local mv = plan.moves
        if mv then
            lines[#lines + 1] = "Sells: " .. mv.hex .. mv.label .. "|r"
            for _, l in ipairs(Market.MovementLines(mv)) do lines[#lines + 1] = HEX.muted .. "  " .. l .. "|r" end
        end
        if plan.stale then lines[#lines + 1] = HEX.bad .. "Old look: search it again before buying.|r" end
        lines[#lines + 1] = HEX.muted .. "Click: the Control tab.|r"
        ns.Tooltip.Text(owner, lines)
    end
end

---------------------------------------------------------------------------
-- Overview
---------------------------------------------------------------------------
local function BuildOverview(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Today at the Auction House")
    v.card:SetAllPoints()
    v.scan = Style.Button(v.card, "Full scan", 150, function()
        local ok, msg = false, "open the Auction House first."
        local host = AuctionHouseFrame or AuctionFrame
        if host and host.IsShown and host:IsShown() then ok, msg = ns.AHHelper.FullScan() end
        if not ok then ns.Print(msg) end
        UI.Refresh()
    end, "Every auction at once (one every 15 minutes, at the Auction House): the price ladders the desk works from.")
    v.scan:SetPoint("TOPRIGHT", -10, -10)
    v.panel = Style.Button(v.card, "Scan panel", 100, function()
        ns.DB().ahHelper = true
        ns.AHHelper.Show()
    end, "The panel that opens next to the Auction House: full scan and the one-search-per-click list. Also " .. ns.Cmd.Text("ah") .. " scan.")
    v.panel:SetPoint("RIGHT", v.scan, "LEFT", -6, 0)
    v.market = Style.Button(v.card, "Market window", 110, function() ns.MarketUI.Show() end, "Every price you have seen, selling your bags, sell-through. Also " .. ns.Cmd.Text("price") .. ".")
    v.market:SetPoint("RIGHT", v.panel, "LEFT", -6, 0)
    v.list = Style.List(v.card.content, { colWidths = { 110, 110, 100 }, onClick = function(item)
        if item.go then state.view = item.go UI.Refresh() elseif item.id then Open(item.id) end
    end })

    function v:Footer()
        return "Every number is from your own looks at the Auction House. A full scan or an exact search keeps an item's whole price ladder."
    end

    function v:Refresh()
        local wait = ns.AHHelper.NextFullScan()
        self.scan:SetLabel(wait > 0 and string.format("Full scan in %d:%02d", math.floor(wait / 60), wait % 60) or "Full scan")
        local sum = Desk.Summary()
        local rows = {}
        rows[#rows + 1] = { header = true, text = "Your listings" .. HEX.muted .. "  (" .. (sum.listings.source == "game"
            and ("as the Auction House showed them " .. Prices.Age(sum.listings.t)) or "from your posting log") .. ")|r" }
        rows[#rows + 1] = { go = "listings", text = string.format("%d active, worth %s after the cut", sum.listed, Money(sum.value)),
            cols = { sum.undercut > 0 and (HEX.bad .. sum.undercut .. " undercut|r") or (HEX.good .. "none undercut|r"),
                sum.overdue > 0 and (HEX.muted .. sum.overdue .. " should have ended|r") or "", HEX.muted .. "details >|r" } }
        local shown = 0
        for _, e in ipairs(sum.listings.list) do
            if shown >= 4 then break end
            if not e.overdue and e.standing.state == "undercut" and e.id then
                shown = shown + 1
                local r = ItemRow(e.id, Market.ItemText(e.id) .. HEX.muted .. "  x" .. e.count .. "|r", { StandingText(e), Money(e.unit),
                    e.standing.repost and (HEX.muted .. "repost|r " .. Money(e.standing.repost)) or "" }, ListingTooltip(e))
                r.indent = 12
                rows[#rows + 1] = r
            end
        end

        local opps = Desk.Opportunities()
        rows[#rows + 1] = { header = true, text = "Best resets" .. HEX.muted .. "  (buy the cheap end, relist under the next seller)|r",
            sortId = "resets", cols = { "Look", "Cost", "Profit" } }
        for i = 1, math.min(6, #opps) do
            local p = opps[i]
            rows[#rows + 1] = ItemRow(p.id, Market.ItemText(p.id) .. HEX.muted .. "  " .. ResetText(p.best) .. "|r",
                { AgeText(p.ladder.t), Money(p.best.cost), Profit(p.best.profit) }, PlanTooltip(p))
        end
        if #opps == 0 then
            rows[#rows + 1] = { text = HEX.muted .. "None above " .. Money(ns.DB().deskMinProfit or 5000) .. " profit. A full scan gives every item's ladder.|r" }
        elseif #opps > 6 then
            rows[#rows + 1] = { go = "control", text = HEX.muted .. (#opps - 6) .. " more in the Control tab >|r" }
        end

        local deals = Desk.Deals()
        rows[#rows + 1] = { header = true, text = "Deals" .. HEX.muted .. "  (well under the usual price)|r", sortId = "deals",
            cols = { "Now", "Units", "Gain" } }
        for i = 1, math.min(5, #deals) do
            local d = deals[i]
            rows[#rows + 1] = ItemRow(d.id, Market.ItemText(d.id) .. HEX.muted .. "  usual " .. Money(math.floor(d.usual + 0.5)) .. "|r",
                { HEX.white .. Money(d.s.p) .. "|r", d.units and (d.units .. " units") or (HEX.muted .. "? units|r"),
                    HEX.good .. "+" .. Money(d.totalGain or d.gain) .. "|r" })
        end
        if #deals == 0 then rows[#rows + 1] = { text = HEX.muted .. "None at your last looks.|r" } end

        local waste = Desk.NotWorthIt()
        if #waste > 0 then
            rows[#rows + 1] = { header = true, text = "Not worth posting" .. HEX.muted .. "  (what you posted that doesn't sell)|r",
                sortId = "waste", cols = { "Sells", "Lost", "" } }
            for i = 1, math.min(4, #waste) do
                local w = waste[i]
                local s = w.sales
                rows[#rows + 1] = ItemRow(w.id, Market.ItemText(w.id) .. HEX.muted .. "  " .. Market.MovementLines(w.moves)[1] .. "|r",
                    { w.moves.hex .. w.moves.label .. "|r", s.depositLost > 0 and (HEX.bad .. "-" .. Money(s.depositLost) .. "|r" .. HEX.muted .. " deposits|r") or "", "" })
            end
        end

        local crafts = Market.CraftList(ns.Gear.CharKey(), "known")
        rows[#rows + 1] = { header = true, text = "Crafts" .. HEX.muted .. "  (recipes you know, best profit)|r", sortId = "crafts",
            cols = { "Materials", "Margin", "Profit" } }
        local n = 0
        for _, pr in ipairs(crafts) do
            if n >= 3 or not pr.priced or pr.profit <= 0 then break end
            n = n + 1
            rows[#rows + 1] = ItemRow(pr.r.creates, Market.ItemText(pr.r.creates) .. HEX.muted .. "  " .. pr.r.prof .. "|r",
                { Money(pr.cost), Pct(pr.cost > 0 and pr.profit / pr.cost or nil, true), Profit(pr.profit) })
        end
        if n == 0 then rows[#rows + 1] = { go = "margins", text = HEX.muted .. "No profitable craft priced yet (open your profession window once, then look up the products).|r" } end

        rows[#rows + 1] = { header = true, text = "Your data" }
        local rate, posts = Desk.DepositRate()
        rows[#rows + 1] = { text = string.format("%d items priced, %d with a full ladder%s", sum.items, sum.ladders,
            sum.ladderNewest and (", newest " .. Prices.Age(sum.ladderNewest)) or ""),
            cols = { "", "", HEX.muted .. Prices.RealmKey() .. "|r" } }
        rows[#rows + 1] = { text = string.format("Deposit: %d%% of the vendor price %s", math.floor(rate * 100 + 0.5),
            posts > 0 and ("(from your " .. posts .. " posts)") or HEX.muted .. "(a guess until you post something)|r") }
        self.list:SetItems(rows)
        self.card.sub:SetText(string.format("%d listed  ·  %d undercut  ·  %d resets  ·  %d deals", sum.listed, sum.undercut, #opps, #deals))
    end
    return v
end

---------------------------------------------------------------------------
-- Listings
---------------------------------------------------------------------------
local function BuildListings(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Your listings")
    v.card:SetAllPoints()
    v.list = Style.List(v.card.content, { colWidths = { 150, 140, 100 }, search = true, hint = "Search your listings...",
        onClick = function(item) if item.id then Open(item.id) end end })

    function v:Footer()
        return "Undercut = someone else lists it cheaper at your last look. The live list comes from the Auction House's Auctions tab; "
            .. "otherwise from what you posted (Economy)."
    end

    function v:Refresh()
        local data = Desk.Listings()
        local rows, value, deposits, guessed, noDeposit, undercut = {}, 0, 0, 0, 0, 0
        rows[#rows + 1] = { header = true, text = "Item", cols = { "Standing", "Yours vs lowest", "After the cut" } }
        for _, e in ipairs(data.list) do
            if not e.overdue then
                value, deposits = value + (e.value or 0), deposits + (e.deposit or 0)
                if not e.deposit then
                    if e.depositGuess then guessed = guessed + e.depositGuess else noDeposit = noDeposit + 1 end
                end
                if e.standing.state == "undercut" then undercut = undercut + 1 end
            end
            local st = e.standing
            local text = (e.id and Market.ItemText(e.id) or (HEX.white .. (e.name or "?") .. "|r")) .. HEX.muted .. "  x" .. e.count .. "|r"
                .. (e.id and Market.MoveTag(e.id) or "")
            local prices = Money(e.unit) .. (st.lowest and st.lowest ~= e.unit and (HEX.muted .. " vs " .. "|r" .. Money(st.lowest)) or "")
            local row = { id = e.id, text = text, cols = { StandingText(e), prices, Money(e.value) }, tooltip = ListingTooltip(e) }
            if e.id then row.icon = select(2, Market.ItemInfo(e.id)) end
            if st.state == "undercut" and not e.overdue then row.accent = COLORS.bad or { 1, 0.3, 0.3 } end
            rows[#rows + 1] = row
        end
        if #rows == 1 then
            rows[2] = { text = HEX.muted .. "Nothing listed (or not seen yet: open the Auction House's Auctions tab once).|r" }
        end
        self.list:SetItems(rows)
        -- Paid deposits, then the estimated ones (no logged post) apart, then any with no estimate at all.
        local stake = (deposits > 0 or guessed == 0) and Money(deposits) or ""
        if guessed > 0 then stake = stake .. (stake ~= "" and " + " or "") .. "about " .. Money(guessed) .. HEX.muted .. " (estimated)|r" end
        if noDeposit > 0 then stake = stake .. string.format(" + ?%s (%d not in your posting log)|r", HEX.muted, noDeposit) end
        self.card.sub:SetText(string.format("%s  ·  %d listings worth %s after the cut  ·  %d undercut  ·  deposits at stake %s",
            data.source == "game" and ("as the Auction House showed them " .. Prices.Age(data.t)) or "from your posting log",
            #data.list, Money(value), undercut, stake))
    end
    return v
end

---------------------------------------------------------------------------
-- Deals
---------------------------------------------------------------------------
local function DealRow(d)
    return ItemRow(d.id, Market.ItemText(d.id) .. HEX.muted .. "  usual " .. Money(math.floor(d.usual + 0.5)) .. "|r" .. Market.MoveTag(d.id),
        { HEX.white .. Money(d.s.p) .. "|r",
            d.units and (d.units .. " for " .. Money(d.cost)) or (HEX.muted .. "one look: units ?|r"),
            HEX.good .. "+" .. Money(d.totalGain or d.gain) .. "|r" .. (d.totalGain and "" or (HEX.muted .. " each|r")) },
        function(owner)
            ns.Tooltip.Text(owner, { Market.ItemText(d.id),
                string.format("Now %s, usual %s (%d looks).", Money(d.s.p), Money(math.floor(d.usual + 0.5)), d.s.looks),
                string.format("Each resold at the usual price brings %s after the cut: +%s.", Money(Market.Net(d.usual)), Money(d.gain)),
                d.units and string.format("%d units at the deal price cost %s; all resold: +%s (deposit counted).", d.units, Money(d.cost), Money(d.totalGain))
                    or "How many are listed at that price: search it on the Auction House.",
                HEX.muted .. "Look " .. Prices.Age(d.s.t) .. ": check it is still there.|r" })
        end)
end

local function BuildDeals(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Deals")
    v.card:SetAllPoints()
    v.list = Style.List(v.card.content, { colWidths = { 100, 150, 110 }, search = true, time = true,
        onClick = function(item) if item.id then Open(item.id) end end })

    function v:Footer()
        return string.format("Listed at most %d%% of the usual price (%d+ looks). Units and gain: every unit under that price, resold at "
            .. "the usual price after the cut and the deposit.", Market.DEAL_FACTOR * 100, Market.DEAL_LOOKS)
    end

    function v:Refresh()
        local data = ns.Data.List(self.list, {
            name = "desk:dealrows", sources = { "prices", "economy" }, maxAge = 60, row = DealRow,
            build = function(add, raw)
                raw({ header = true, text = "Item", cols = { "Now", "Units under, cost", "Gain" } })
                local deals = Desk.Deals()
                for _, d in ipairs(deals) do add(d, { id = d.id, time = d.s.t }) end
                if #deals == 0 then raw({ text = HEX.muted .. "No deals at your last looks. The more you look, the better \"usual\" gets.|r" }) end
                return { count = #deals }
            end,
        })
        self.card.sub:SetText(data.count .. " items under their usual price  ·  click one for its ladder")
    end
    return v
end

---------------------------------------------------------------------------
-- Margins: crafting
---------------------------------------------------------------------------
local function MarginRow(pr)
    local r = pr.r
    return ItemRow(r.creates, Market.ItemText(r.creates) .. ((r.makes or 1) > 1 and (" x" .. r.makes) or "")
        .. HEX.muted .. "  " .. r.prof .. (pr.known and "" or "  (not learned)") .. "|r" .. Market.MoveTag(r.creates),
        { Money(pr.cost) .. (pr.guessed and (HEX.muted .. "*|r") or ""), Profit(pr.profit), pr.margin and Pct(pr.margin, true) or (HEX.muted .. "free|r") },
        function(owner)
            local lines = { r.name, string.format("%s %d  ·  product seen %s", r.prof, r.skill, Prices.Age(pr.seen, pr.seenSrc)) }
            for _, rg in ipairs(r.reagents or {}) do
                lines[#lines + 1] = string.format("  %d x %s  %s", rg[2], Market.ItemText(rg[1]), HEX.muted .. ns.Professions.PriceText(rg[1]) .. "|r")
            end
            lines[#lines + 1] = "Sells for " .. Money(pr.value) .. " after the cut" .. (pr.rate and (" and your " .. math.floor(pr.rate * 100 + 0.5) .. "% sell rate") or "") .. "."
            if pr.guessed then lines[#lines + 1] = HEX.muted .. "* some materials not seen on the AH: estimated.|r" end
            ns.Tooltip.Text(owner, lines)
        end)
end

local function BuildMargins(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Crafting margins")
    v.card:SetAllPoints()
    v.mode = Style.Button(v.card, "", 150, function()
        state.craftMode = state.craftMode == "known" and "all" or "known"
        UI.Refresh()
    end, "Only recipes you know (open your profession window once), or every recipe your skill allows.", { title = "Recipes" })
    v.mode:SetPoint("TOPRIGHT", -10, -10)
    v.list = Style.List(v.card.content, { colWidths = { 90, 90, 70 }, search = true, hint = "Search recipes...",
        onClick = function(item) if item.id and Prices.Ladder(item.id) then Open(item.id) end end })

    function v:Footer()
        return "Materials at the best known prices against the product's AH price after the cut and your sell rate. Margin = profit / materials."
    end

    function v:Refresh()
        self.mode:SetLabel(state.craftMode == "known" and "Recipes I know  >" or "All I can make  >")
        local data = ns.Data.List(self.list, {
            name = "desk:margins", sources = { "prices", "economy", "skills", "crafts" },
            key = { ns.Gear.CharKey(), state.craftMode }, row = MarginRow,
            build = function(add, raw)
                local list = {}
                for _, pr in ipairs(Market.CraftList(ns.Gear.CharKey(), state.craftMode)) do
                    if pr.priced then
                        pr.margin = pr.cost > 0 and pr.profit / pr.cost or nil
                        list[#list + 1] = pr
                    end
                end
                raw({ header = true, text = "Recipe", cols = { "Materials", "Profit", "Margin" } })
                for _, pr in ipairs(list) do add(pr, { id = pr.r.creates }) end
                if #list == 0 then raw({ text = HEX.muted .. "No product of your recipes seen on the Auction House yet.|r" }) end
                return { list = list }
            end,
        })
        local list = data.list
        local winners = 0
        for _, pr in ipairs(list) do if pr.profit > 0 then winners = winners + 1 end end
        self.card.sub:SetText(string.format("%d recipes priced  ·  %d make money", #list, winners))
    end
    return v
end

---------------------------------------------------------------------------
-- Control: owning a market
---------------------------------------------------------------------------
local function DetailRows(plan)
    local out = {}
    local L = plan.ladder
    out[#out + 1] = { header = true, text = "The market" }
    out[#out + 1] = { label = "Look", text = AgeText(L.t) .. (plan.stale and (HEX.bad .. "  search it again before buying|r") or "")
        .. (plan.atLeast and (HEX.gold .. "  partial: costs are at least|r") or "") }
    out[#out + 1] = { label = "Supply", text = string.format("%d units in %d auctions", L.units, L.auctions or 0)
        .. (L.bidOnly > 0 and (HEX.muted .. "  + " .. L.bidOnly .. " bid only|r") or "")
        .. (L.mine > 0 and (HEX.accent .. "  · " .. L.mine .. " yours|r") or "") }
    local h = plan.holders
    if h then
        local held = h.share >= Desk.CONTROL_SHARE
        out[#out + 1] = { label = "Sellers", text = string.format("%d  ·  top: %s with %d%%", h.sellers or 0, h.name or "?", math.floor(h.share * 100 + 0.5))
            .. (held and not h.mine and (HEX.gold .. "  holds it: expect them to answer|r") or "") .. (h.mine and (HEX.good .. "  (you)|r") or "") }
    else
        out[#out + 1] = { label = "Sellers", text = HEX.muted .. "? (this look did not name them)|r" }
    end
    out[#out + 1] = { label = "Usual", text = plan.usual and Money(math.floor(plan.usual + 0.5)) or (HEX.muted .. "one look: unknown|r"),
        cols = { plan.rate and ("you sell " .. math.floor(plan.rate * 100 + 0.5) .. "%") or (HEX.muted .. "sell rate ?|r") } }
    local mv = plan.moves
    if mv then
        local ev = Market.MovementLines(mv)
        out[#out + 1] = { label = "Sells", text = mv.hex .. mv.label .. "|r" .. HEX.muted .. "  " .. ev[1] .. "|r",
            tooltip = function(o) local l = { "Does it sell?" } for _, x in ipairs(ev) do l[#l + 1] = x end
                l[#l + 1] = HEX.muted .. "Your auctions decide once 2 have ended; else units leaving the AH between your looks (sold, cancelled or expired).|r"
                ns.Tooltip.Text(o, l) end }
        if ev[2] then out[#out + 1] = { label = "", text = HEX.muted .. ev[2] .. "|r" } end
        if mv.key == "dead" then out[#out + 1] = { label = "", text = HEX.bad .. "Doesn't sell: a reset would only sit there.|r" } end
    end

    local all = plan.all
    out[#out + 1] = { header = true, text = "Own it all" }
    out[#out + 1] = { label = "Buy", text = string.format("%s%s for %d units", plan.atLeast and "at least " or "", Money(all.cost), all.units) }
    out[#out + 1] = { label = "Relist", text = string.format("at %s each%s  ·  deposit %s", Money(all.relist),
        (plan.usual and all.relist <= plan.usual + 0.5) and " (usual)" or " (highest listed)", Money(all.deposit)), cols = { Profit(all.profit) } }

    out[#out + 1] = { header = true, text = "Resets" .. HEX.muted .. "  (relist 1c under the next seller)|r", sortId = "resets",
        label = "Buy up to", cols = { "Profit" } }
    if #plan.steps == 0 then out[#out + 1] = { text = HEX.muted .. "No gap in the ladder to relist under.|r" } end
    for _, s in ipairs(plan.steps) do
        local best = plan.best == s
        out[#out + 1] = { label = "to " .. Money(s.upTo), text = string.format("%d for %s, relist %s", s.units, Money(s.cost), Money(s.relist))
            .. (s.over and (HEX.bad .. "  overpriced|r") or "")
            .. (s.overUsual and (HEX.muted .. "  (" .. Pct(s.overUsual, false) .. HEX.muted .. " vs usual)|r") or ""),
            cols = { Profit(s.profit) }, accent = best and COLORS.accent or nil,
            tooltip = function(o) ns.Tooltip.Text(o, { string.format("Buy every unit up to %s: %d units for %s.", Money(s.upTo), s.units, Money(s.cost)),
                string.format("Relist all at %s: %s after the cut%s; deposit %s.", Money(s.relist), Money(s.revenue),
                    plan.rate and " and your sell rate" or "", Money(s.deposit)),
                "Profit if it all sells: " .. Profit(s.profit) .. (s.roi and ("  (" .. math.floor(s.roi * 100 + 0.5) .. "%)") or ""),
                s.over and (HEX.bad .. "The next seller is over " .. Market.OUTLIER_FACTOR .. "x the usual price: nobody pays that, so this is never the best reset.|r") or nil }) end }
    end

    out[#out + 1] = { header = true, text = "Ladder: units", sortId = "ladder", label = "Price", cols = { "Total to here" } }
    local cum = 0
    for _, t in ipairs(L.tiers) do
        cum = cum + (t.q - t.m) * t.u
        local over = plan.usual and t.u > plan.usual * Market.OUTLIER_FACTOR
        out[#out + 1] = { label = Money(t.u), text = t.q .. (t.q == 1 and " unit" or " units") .. (t.m > 0 and (HEX.accent .. "  (" .. t.m .. " yours)|r") or "")
            .. (over and (HEX.bad .. "  overpriced|r") or ""),
            cols = { Money(cum) }, bar = { cum, math.max(1, all.cost) } }
    end
    if L.more > 0 then out[#out + 1] = { label = "", text = HEX.muted .. "and " .. L.more .. " units at higher prices (not kept)|r" } end
    return out
end

local function MarketRow(p)
    local sel = state.selected == p.id
    local h = p.holders
    local r = ItemRow(p.id, (sel and HEX.accent or "") .. Market.ItemText(p.id) .. (sel and "|r" or "")
        .. HEX.muted .. "  " .. p.ladder.units .. " units · " .. Prices.Age(p.ladder.t) .. "|r" .. Market.MoveTag(p.id),
        { (p.atLeast and (HEX.muted .. ">=|r") or "") .. Money(p.all.cost), p.best and Profit(p.best.profit) or (HEX.dim .. "-|r"),
            h and ((h.share >= Desk.CONTROL_SHARE and not h.mine and HEX.gold or HEX.muted) .. math.floor(h.share * 100 + 0.5) .. "%|r") or (HEX.dim .. "?|r") },
        PlanTooltip(p))
    r.accent = sel and COLORS.accent or nil
    r.tint = sel and { COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.12 } or nil
    return r
end

local function BuildControl(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.left = Style.Card(v, "Markets")
    v.left:SetPoint("TOPLEFT")
    v.left:SetPoint("BOTTOMLEFT")
    v.left:SetWidth(480)
    local top = CreateFrame("Frame", nil, v.left.content)
    top:SetPoint("TOPLEFT", 6, -4)
    top:SetPoint("TOPRIGHT", -6, -4)
    top:SetHeight(24)
    v.search = Style.SearchBox(top, function(text)
        state.search = (text or ""):lower()
        UI.Refresh()
    end, "Search items...")
    v.search:SetPoint("TOPLEFT")
    v.search:SetPoint("TOPRIGHT")
    local holder = CreateFrame("Frame", nil, v.left.content)
    holder:SetPoint("TOPLEFT", 0, -32)
    holder:SetPoint("BOTTOMRIGHT")
    v.list = Style.List(holder, { colWidths = { 90, 90, 60 }, columns = { name = "Item", "Own it all", "Best reset", "Top seller" },
        onClick = function(item)
        if item.id then state.selected = item.id UI.Refresh() end
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
    v.detail = Style.List(detailHolder, { labelWidth = 70, colWidths = { 90 } })

    function v:Footer()
        return "From each item's last full look. Reset = buy the cheapest tiers, relist 1c under the next seller. "
            .. "Profit assumes it all sells: an item someone holds, or a relist far over usual, may not."
    end

    function v:Refresh()
        -- Best reset first; the column titles sort it otherwise.
        local markets = Desk.Markets("profit", state.search)
        if state.selected and not Prices.Ladder(state.selected) then state.selected = nil end
        if not state.selected and markets[1] then state.selected = markets[1].id end
        ns.Data.List(self.list, {
            name = "desk:control", key = { tostring(markets), state.selected }, maxAge = 60, row = MarketRow,
            empty = state.search ~= "" and "Nothing matches." or "No ladders yet: a full scan (or an exact search of one item) shows every auction of an item.",
            build = function(add)
                for _, p in ipairs(markets) do add(p, { id = p.id }) end
            end,
        })
        self.left.sub:SetText(string.format("%d items", #markets))
        local plan = state.selected and Desk.Plan(state.selected)
        if plan then
            self.right.title:SetText(Market.ItemText(plan.id))
            self.right.sub:SetText(string.format("lowest %s  ·  own it all %s%s  ·  best reset %s", Money(plan.ladder.tiers[1].u),
                plan.atLeast and ">= " or "", Money(plan.all.cost), plan.best and Profit(plan.best.profit) or "none"))
            self.detail:SetItems(DetailRows(plan))
            self.chart:SetItem(plan.id)
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
-- Window
---------------------------------------------------------------------------
local VIEWS = {
    { key = "overview", label = "Overview", build = BuildOverview },
    { key = "listings", label = "Listings", build = BuildListings },
    { key = "deals", label = "Deals", build = BuildDeals },
    { key = "margins", label = "Margins", build = BuildMargins },
    { key = "control", label = "Control", build = BuildControl },
}

local function Build()
    frame = Style.Window(ns.FRAME .. "AuctionDesk", "Auction desk", nil, nil, { nav = "desk", hidden = true })
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

-- view: tab key; id: the item to select in the Control tab.
function UI.Show(view, id)
    if not frame then Build() end
    if view and views[view] then state.view = view end
    if id then state.selected, state.search = id, "" end
    frame:Show()
    UI.Refresh()
end

function UI.Toggle(view)
    if frame and frame:IsShown() and (not view or view == state.view) then frame:Hide() else UI.Show(view) end
end

function UI.IsShown() return frame ~= nil and frame:IsShown() end
-- Redrawn when prices, ladders, your auctions or recipes change. Frames and
-- the Overview's numbers (a plan per ladder) are built after login.
ns.Data.Window(UI, { "prices", "economy", "skills", "crafts" }, {
    prebuild = function() if not frame then Build() end end,
    warm = function()
        Desk.Summary()
        Desk.Opportunities()
        Desk.Deals()
        Desk.NotWorthIt()
        Desk.DepositRate()
        Market.CraftList(ns.Gear.CharKey(), "known")
    end,
})
UI.state, UI.views = state, views
