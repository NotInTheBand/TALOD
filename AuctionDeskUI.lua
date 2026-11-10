-- TALOD - the auction desk's parts of the Auction House page (MarketUI.lua):
-- Today (your listings, best resets, deals, not worth posting, crafts, your
-- data: each card opens its tab), My auctions (your live listings with their
-- standing, and every auction you posted with how it ended, in one list) and
-- the control plan shown on Prices for an item with a full look (the market,
-- own it all, resets, the ladder). Numbers come from AuctionDesk.lua and
-- Economy.lua; nothing here buys or posts.
--
-- AuctionDeskUI.Show(view, id) stays for old callers: it opens the page on
-- the matching tab.

local ADDON_NAME, ns = ...
local Style = ns.Style
local COLORS, HEX = Style.COLORS, Style.HEX
local Market, Prices, Desk = ns.Market, ns.Prices, ns.AuctionDesk

local UI = {}
ns.AuctionDeskUI = UI

local function Page() return ns.MarketUI end

local function Money(c)
    if not c then return HEX.dim .. "-|r" end
    return ns.Professions.Money(c)
end

local function Profit(c)
    if not c then return HEX.dim .. "-|r" end
    return (c >= 0 and HEX.good or HEX.bad) .. Desk.Signed(c) .. "|r"
end

-- Listings' worth with those that have no buyout said apart: "at least X + 2 without a buyout".
local function ListedWorth(value, unpriced)
    if (unpriced or 0) == 0 then return Money(value) end
    return ((value or 0) > 0 and "at least " or "") .. ns.Professions.MoneyKnown(value, unpriced, "without a buyout")
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

local function LinkID(link) return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil end
local function LinkName(link)
    if type(link) ~= "string" then return "?" end
    return link:match("|h%[(.-)%]|h") or link
end

-- An item on Prices (with its plan when it has a full look).
local function Open(id)
    if not id then return end
    Page().OpenPrices(id, Prices.Ladder(id) and true or nil)
end

local function ItemRow(id, text, cols, tooltip)
    local _, icon = Market.ItemInfo(id)
    return { id = id, icon = icon, text = text, cols = cols, tooltip = tooltip }
end

-- Where a listing stands, as a tag in the trade tones: lowest (good),
-- tied (compare), undercut (bad); unknown when no look tells.
local function StandingTag(e)
    if e.overdue then return { tag = "should have ended", tone = "plain", sort = 5 } end
    local st = e.standing or {}
    if st.state == "undercut" then
        return { tag = "undercut" .. (st.ahead and (" · " .. st.ahead .. " under") or ""), tone = "bad", sort = 1 }
    end
    -- Undercut at an old look: those auctions may be gone. Said with its age, no repost.
    if st.oldUndercut and st.age then return { tag = "undercut " .. Prices.Age(time() - st.age), tone = "unknown" } end
    if st.state == "tied" then return { tag = "tied", tone = "compare", sort = 2 } end
    if st.state == "lowest" then return { tag = "lowest", tone = "good", sort = 3 } end
    return ns.UNKNOWN
end
UI.StandingTag = StandingTag

-- The repost price as the price to type: the whole auction, floored so it
-- stays under the other seller (a per-unit 19.999s shown as "20s" x 20 is
-- 4g, over their 3g 99s 99c).
-- Every coin shown (Money drops the copper from 1g): it is the price to type.
local function RepostText(unit, count)
    count = count or 1
    local total = math.max(0, math.floor(unit * count + 1e-6))
    local g, s, c = math.floor(total / 10000), math.floor(total / 100) % 100, total % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "c" end
    return table.concat(parts, " ") .. (count > 1 and (" for " .. count) or " each")
end
UI.RepostText = RepostText

-- A reset step's relist price: per stack of the wall's size when it was one.
local function RelistText(step)
    if step.relistK and step.relistK > 1 then return RepostText(step.relist, step.relistK) end
    return Money(step.relist) .. " each"
end

local function ListingTooltip(e)
    return function(owner)
        local st = e.standing or {}
        local lines = { (e.id and Market.ItemText(e.id) or (e.name or "?")) .. "  x" .. (e.count or 1) }
        lines[#lines + 1] = "Yours: " .. Money(e.unit) .. " each, " .. Money(e.value) .. " after the cut for all."
        if st.state == "undercut" then
            lines[#lines + 1] = HEX.bad .. (st.ahead and (st.ahead .. " units listed under yours") or "Listed under yours") .. "|r"
                .. ", the lowest at " .. Money(st.lowest) .. "."
            if st.repost then lines[#lines + 1] = "To be the lowest again: cancel and repost at " .. RepostText(st.repost, e.count) .. "." end
        elseif st.state == "lowest" then
            lines[#lines + 1] = HEX.good .. "Nobody else is cheaper|r" .. (st.lowest and ("; the next seller asks " .. Money(st.lowest) .. ".") or ".")
        elseif st.state == "tied" then
            lines[#lines + 1] = HEX.compare .. "Another seller asks the same price|r; nobody is cheaper. Buyers may take theirs first."
        else
            lines[#lines + 1] = HEX.muted .. "No look at this item that tells: search it on the Auction House.|r"
        end
        if st.age then lines[#lines + 1] = HEX.muted .. "Market look " .. Prices.Age(time() - st.age) .. (st.partial and ", partial" or "") .. ".|r" end
        if e.left then lines[#lines + 1] = "Time left: " .. (type(e.left) == "number" and (math.floor(e.left / 3600) .. " h " .. math.floor(e.left % 3600 / 60) .. " min")
            or (e.left .. (e.seenAt and (" when read, " .. Prices.Age(e.seenAt)) or ""))) end
        if e.endsAt then lines[#lines + 1] = (e.overdue and "Should have ended " or "Ends about ") .. date("%b %d %H:%M", e.endsAt) .. (e.overdue and ": check your mail." or ".") end
        if e.deposit then lines[#lines + 1] = "Deposit paid: " .. Money(e.deposit) .. " (lost if it does not sell)."
        elseif e.depositGuess then lines[#lines + 1] = "Deposit about " .. Money(e.depositGuess) .. HEX.muted .. " (not in your posting log: from your deposit rate)|r" end
        if e.id then
            local mv = Market.Movement(e.id)
            lines[#lines + 1] = "Sells: " .. mv.hex .. mv.label .. "|r"
            for _, l in ipairs(Market.MovementLines(mv)) do lines[#lines + 1] = HEX.muted .. "  " .. l .. "|r" end
        end
        lines[#lines + 1] = HEX.muted .. "Click: its prices (and a search at the open Auction House).|r"
        ns.Tooltip.Text(owner, lines)
    end
end

local function ResetText(step)
    return string.format("buy %d up to %s, relist at %s", step.units, Money(step.upTo), RelistText(step))
end

-- The list's plan is slim: the tooltip reads the item's full plan when shown.
local function PlanTooltip(slim)
    return function(owner)
        local plan = Desk.Detail(slim.id) or slim
        local lines = { Market.ItemText(plan.id) }
        local L = plan.ladder
        lines[#lines + 1] = string.format("%d units in %d auctions, look %s%s", L.units, L.auctions or 0, Prices.Age(L.t),
            plan.atLeast and " (partial: costs are at least)" or "")
        local b = plan.best or plan.bestIfAll
        if b then
            lines[#lines + 1] = string.format("Reset: buy %d units up to %s for %s.", b.units, Money(b.upTo), Money(b.cost))
            lines[#lines + 1] = string.format("Relist at %s, valued at %s each (never above the usual price), deposit %s.",
                RelistText(b), b.value and Money(b.value) or "?", b.deposit and Money(b.deposit) or "?")
            if b.profit then
                lines[#lines + 1] = string.format("Expected with your %d%% sell rate: %s", math.floor(plan.rate * 100 + 0.5), Profit(b.profit))
                    .. (b.roi and ("  (" .. math.floor(b.roi * 100 + 0.5) .. "% on the money and deposits)") or "")
            end
            lines[#lines + 1] = "If it all sells: " .. Profit(b.ifAll)
            if not b.profit then lines[#lines + 1] = HEX.muted .. Desk.MissingText(plan, b) .. ": not an expected result.|r" end
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
        lines[#lines + 1] = HEX.muted .. "Click: its prices, ladder and plans.|r"
        ns.Tooltip.Text(owner, lines)
    end
end

---------------------------------------------------------------------------
-- Today: six cards, each opens its tab
---------------------------------------------------------------------------
local GAP = 8

-- Card definitions: key, title, link label and where the link goes.
local CARDS = {
    { key = "listings", title = "Your listings", link = "My auctions", go = function() Page().ShowPage("mine", "auctions", "listed") end },
    { key = "resets", title = "Best resets", link = "Prices", go = function()
        Page().state.priceFilter = "full"
        Page().ShowPage("prices")
    end },
    { key = "deals", title = "Deals", link = "Buy", go = function() Page().ShowPage("buy", "deals") end },
    { key = "waste", title = "Not worth posting", link = "By item", go = function() Page().ShowPage("mine", "by item") end },
    { key = "crafts", title = "Crafts that pay", link = "Profit", go = function() Page().OpenProfit() end },
    { key = "data", title = "Your data", link = "Scan log", go = function() Page().ShowScanLog() end },
}

local function TodayCard(v, def)
    local card = Style.Card(v, def.title)
    card:SetLink(def.link, def.go)
    card.list = Style.List(card.content, { colWidths = { 76, 70 }, onClick = function(item)
        if item.go then item.go() elseif item.id then Open(item.id) end
    end })
    card.def = def
    return card
end

-- What the cards show, row lists by card key (also for the tests).
local function TodayRows()
    local out, subs, foots = {}, {}, {}
    local sum = Desk.Summary()
    local go = {}
    for _, def in ipairs(CARDS) do go[def.key] = def.go end

    -- Your listings: the count and worth, then the undercut ones.
    local rows = {}
    rows[#rows + 1] = { go = go.listings, text = string.format("%d active, worth %s after the cut", sum.listed,
            ListedWorth(sum.value, sum.unpriced)),
        cols = { sum.undercut > 0 and { tag = sum.undercut .. " undercut", tone = "bad" } or { tag = "none undercut", tone = "good" },
            sum.overdue > 0 and (HEX.muted .. sum.overdue .. " ended?|r") or "" },
        tooltip = function(o) ns.Tooltip.Text(o, { "Your listings", "Click: My auctions, listed only." }) end }
    local shown = 0
    for _, e in ipairs(sum.listings.list) do
        if shown >= 5 then break end
        if not e.overdue and e.standing.state == "undercut" and e.id then
            shown = shown + 1
            rows[#rows + 1] = ItemRow(e.id, Market.ItemText(e.id) .. HEX.muted .. "  x" .. e.count .. "|r",
                { StandingTag(e), Money(e.unit) }, ListingTooltip(e))
        end
    end
    out.listings = rows
    subs.listings = sum.undercut > 0 and (HEX.bad .. sum.undercut .. " undercut|r") or ""
    foots.listings = sum.listings.source ~= "log"
        and ("As the Auction House showed them " .. Prices.Age(sum.listings.t) .. (sum.listings.source == "game + log" and ", and your posts since." or "."))
        or "From your posting log (open the Auction House's Auctions tab once)."

    -- Best resets.
    local opps = Desk.Opportunities()
    rows = {}
    for i = 1, math.min(6, #opps) do
        local p = opps[i]
        rows[#rows + 1] = ItemRow(p.id, Market.ItemText(p.id) .. HEX.muted .. "  " .. ResetText(p.best) .. "|r",
            { Profit(p.best.profit), Money(p.best.cost) }, PlanTooltip(p))
    end
    if #opps == 0 then
        rows[1] = { text = HEX.muted .. "None above " .. Money(ns.DB().deskMinProfit or 5000) .. " profit. A full scan gives every item's ladder.|r" }
    elseif #opps > 6 then
        rows[#rows + 1] = { go = go.resets, text = HEX.muted .. (#opps - 6) .. " more on Prices >|r" }
    end
    out.resets, subs.resets = rows, #opps > 0 and (HEX.muted .. #opps .. "|r") or ""
    foots.resets = "Buy the cheap end, relist under the next seller. After the cut and a deposit learned from your posts."

    -- Deals, with how many units sit under the deal price.
    local deals = Desk.Deals()
    rows = {}
    for i = 1, math.min(5, #deals) do
        local d = deals[i]
        rows[#rows + 1] = ItemRow(d.id, Market.ItemText(d.id) .. HEX.muted .. (d.units and ("  x" .. d.units) or "  ? units")
                .. "  usual " .. Money(math.floor(d.usual + 0.5)) .. "|r",
            { d.totalGain and Profit(d.totalGain)
                or (d.gainIfAll and (HEX.muted .. "if all |r" .. Profit(d.gainIfAll)))
                or (HEX.good .. "+" .. Money(d.gain) .. "|r" .. HEX.muted .. " each|r"),
              HEX.white .. Money(d.p or d.s.p) .. "|r" })
        rows[#rows].deal = d
    end
    if #deals == 0 then rows[1] = { text = HEX.muted .. "None at your last looks.|r" } end
    out.deals, subs.deals = rows, #deals > 0 and (HEX.muted .. #deals .. "|r") or ""
    foots.deals = "Well under the usual price at your last look: a deal may be gone."

    -- Not worth posting: what you posted that doesn't sell.
    local waste = Desk.NotWorthIt()
    rows = {}
    for i = 1, math.min(5, #waste) do
        local w = waste[i]
        local s = w.sales
        rows[#rows + 1] = ItemRow(w.id, Market.ItemText(w.id) .. HEX.muted .. "  " .. Market.MovementLines(w.moves)[1] .. "|r",
            { s.depositLost > 0 and (HEX.bad .. "-" .. Money(s.depositLost) .. "|r") or "", w.moves.hex .. w.moves.label .. "|r" })
    end
    if #waste == 0 then rows[1] = { text = HEX.muted .. "Nothing you posted sits unsold.|r" } end
    out.waste, foots.waste = rows, "What you posted that doesn't sell, with the deposits it cost."

    -- Crafts that pay (the full list is on Professions > Profit).
    local crafts = Market.CraftList(ns.Gear.CharKey(), "known")
    rows = {}
    for _, pr in ipairs(crafts) do
        if #rows >= 4 or not pr.priced or pr.profit <= 0 then break end
        rows[#rows + 1] = ItemRow(pr.r.creates, Market.ItemText(pr.r.creates) .. HEX.muted .. "  " .. pr.r.prof .. "|r",
            { Pct(pr.cost > 0 and pr.profit / pr.cost or nil, true), Profit(pr.profit) })
    end
    if #rows == 0 then
        rows[1] = { go = go.crafts, text = HEX.muted .. "No profitable craft priced yet (open your profession window once, then look up the products).|r" }
    end
    out.crafts, foots.crafts = rows, "Recipes you know, materials at the best known prices."

    -- Your data.
    local rate, posts = Desk.DepositRate()
    local H = ns.AHHelper
    local wait, last = 0, nil
    if H then wait, last = H.NextFullScan() end
    rows = {
        { text = "Items with a price", cols = { HEX.white .. sum.items .. "|r" } },
        { text = "With a full ladder" .. (sum.ladderNewest and (HEX.muted .. ", newest " .. Prices.Age(sum.ladderNewest) .. "|r") or ""),
            cols = { HEX.white .. sum.ladders .. "|r" } },
        { text = "Last full scan", cols = { last and (HEX.white .. Prices.Age(last) .. "|r") or (HEX.muted .. "none yet|r") } },
        { text = "Next full scan", cols = { wait > 0 and string.format("%d:%02d", math.floor(wait / 60), wait % 60) or (HEX.good .. "ready|r") } },
        { text = string.format("Deposit: %d%% of the vendor price", math.floor(rate * 100 + 0.5)),
            cols = { posts > 0 and (HEX.muted .. posts .. " posts|r") or (HEX.muted .. "a guess|r") },
            tooltip = function(o) ns.Tooltip.Text(o, { "Deposit", posts > 0 and ("Learned from your " .. posts .. " posts.")
                or "A guess until you post something." }) end },
    }
    out.data, subs.data = rows, HEX.muted .. (Prices.RealmKey() or "?") .. "|r"
    foots.data = "One full scan per click; the server allows one every 15 minutes."
    return out, subs, foots, sum, opps, deals
end
UI.TodayRows = TodayRows

function UI.BuildToday(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.cards = {}
    for i, def in ipairs(CARDS) do v.cards[def.key] = TodayCard(v, def) v.cards[i] = v.cards[def.key] end
    -- Three cards across, two down, whatever the window's size.
    local function Layout(self)
        local W, H = self:GetWidth() or 900, self:GetHeight() or 500
        local w, h = math.floor((W - 2 * GAP) / 3), math.floor((H - GAP) / 2)
        for i, card in ipairs(self.cards) do
            local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
            card:ClearAllPoints()
            card:SetSize(w, h)
            card:SetPoint("TOPLEFT", col * (w + GAP), -row * (h + GAP))
        end
    end
    v:SetScript("OnSizeChanged", Layout)
    Layout(v)

    function v:Footer()
        return "Every number is from your own looks at the Auction House. A full scan or an exact search keeps an item's whole price ladder."
    end

    function v:Refresh()
        local rows, subs, foots = TodayRows()
        local all = {}
        for _, card in ipairs(self.cards) do
            local key = card.def.key
            card.list:SetItems(rows[key])
            card.sub:SetText(subs[key] or "")
            card:SetFoot(foots[key])
            for _, r in ipairs(rows[key]) do all[#all + 1] = r end
        end
        self.all = all
    end
    return v
end

---------------------------------------------------------------------------
-- My auctions > Auctions: your live listings (standing against the lowest)
-- and every auction you posted (sold, expired, cancelled), one list
---------------------------------------------------------------------------
local FILTERS = {
    { key = "all", label = "All" }, { key = "listed", label = "Listed" }, { key = "sold", label = "Sold" },
    { key = "expired", label = "Expired" }, { key = "cancelled", label = "Cancelled" },
}
local MINE_COLUMNS = { name = "Item", "By", "Posted", "Left / got", "Standing", "Lowest now", "Yours, each", "Stack" }
local MINE_WIDTHS = { 64, 62, 86, 116, 72, 72, 38 }
local OUTCOME = { sold = { "sold", "good" }, expired = { "expired", "bad" }, cancelled = { "cancelled", "plain" } }

local function CharShort(key) return tostring(key or "?"):match("^([^-]+)") or "?" end

local function LeftText(e)
    if e.overdue then return HEX.muted .. "ended?|r" end
    if type(e.left) == "number" then
        local h = math.floor(e.left / 3600)
        return h > 0 and (h .. " h") or (math.max(1, math.floor(e.left / 60)) .. " min")
    end
    if e.left then return tostring(e.left) end
    if e.endsAt then
        local h = math.floor(math.max(0, e.endsAt - time()) / 3600)
        return h > 0 and ("about " .. h .. " h") or "under 1 h"
    end
    return ns.UNKNOWN
end

-- One of your posts from the posting log (Economy): how it ended.
local function AuctionTooltip(it)
    return function(owner)
        local a = it.a
        local lines = { LinkName(a.name) .. (a.count and a.count > 1 and (" x" .. a.count) or ""),
            "Posted " .. date("%b %d %H:%M", a.t) .. "  ·  " .. tostring(a.duration or "?") .. "  ·  " .. tostring(it.char),
            "Buyout " .. (a.buyout and Money(a.buyout) or "-") .. "   bid " .. (a.bid and Money(a.bid) or "-"),
            "Deposit " .. Money(a.deposit or 0),
            -- When it sold or ended (from its letter); else when the letter was taken, said so.
            "Status: " .. (OUTCOME[it.status] and OUTCOME[it.status][1] or (it.status == "unknown" and "ended?" or it.status))
                .. (a.closedAt and ("  (" .. date("%b %d %H:%M", a.closedAt) .. ")")
                    or (a.ended and ("  (letter taken " .. date("%b %d %H:%M", a.ended) .. ")")) or "") }
        if it.status == "unknown" then
            lines[#lines + 1] = "Its time ran out and no auction letter closed it: sold, expired or cancelled is unknown."
        end
        if a.received then
            lines[#lines + 1] = "Sold for " .. Money(a.received - (a.deposit or 0)) .. " after the cut"
            lines[#lines + 1] = "Letter paid " .. Money(a.received) .. (a.deposit and a.deposit > 0
                and ("  (with your deposit " .. Money(a.deposit) .. " back)") or "")
        end
        lines[#lines + 1] = HEX.muted .. "Click: its prices (and a search at the open Auction House).|r"
        ns.Tooltip.Text(owner, lines)
    end
end

local function MineRow(it)
    local id = it.id
    local icon = id and select(2, Market.ItemInfo(id)) or nil
    local e, a = it.e, it.a
    local count = e and e.count or (a and a.count) or 1
    local name = id and Market.ItemText(id) or (HEX.white .. (e and e.name or LinkName(a and a.name)) .. "|r")
    local posted = it.t and (HEX.muted .. Prices.Age(it.t) .. "|r") or ns.UNKNOWN
    local by = HEX.muted .. CharShort(it.char) .. "|r"
    if it.status == "listed" then
        local st = e and e.standing or (id and it.unit and Desk.Standing(id, it.unit)) or { state = "unknown" }
        local entry = e or { id = id, name = LinkName(a.name), count = count, unit = it.unit, standing = st,
            deposit = a.deposit, endsAt = it.endsAt }
        return {
            icon = icon, text = name,
            cols = { by, posted, LeftText(entry), StandingTag(entry), st.lowest and Money(st.lowest) or ns.UNKNOWN,
                entry.unit and Money(entry.unit) or ns.UNKNOWN, tostring(count) },
            sort = { [6] = entry.unit, [7] = count },
            tooltip = ListingTooltip(entry),
        }
    end
    local result
    if it.status == "sold" then
        result = a.received and (HEX.good .. Money(a.received - (a.deposit or 0)) .. "|r") or ns.UNKNOWN
    elseif it.status == "expired" or it.status == "cancelled" then
        result = HEX.bad .. "-" .. Money(a.deposit or 0) .. "|r"
    else
        result = ns.UNKNOWN
    end
    local o = OUTCOME[it.status]
    return {
        icon = icon, text = name,
        cols = { by, posted, result, o and { tag = o[1], tone = o[2] } or { tag = "ended", tone = "unknown" }, "",
            (a.buyout and a.buyout > 0) and Money(math.floor(a.buyout / count + 0.5)) or ns.UNKNOWN, tostring(count) },
        sort = { [3] = a.received and (a.received - (a.deposit or 0)) or (a.deposit and -a.deposit) or nil, [7] = count },
        tooltip = AuctionTooltip(it),
    }
end

-- Every row of the list (all filters), counted by status: the live listings
-- of this character (with the posting time from the log when it matches),
-- then every other post of every character, newest first.
local function MineBuild(add, filter)
    local Economy = ns.Economy
    local me = ns.Gear and ns.Gear.CharKey()
    local counts = { all = 0, listed = 0, sold = 0, expired = 0, cancelled = 0, unknown = 0 }
    local function Put(it, fields)
        counts.all = counts.all + 1
        counts[it.status] = (counts[it.status] or 0) + 1
        if filter == "all" or filter == it.status then add(it, fields) end
    end
    local listings = Desk.Listings()
    local posted = {}
    local mine = Economy and Economy.Char and Economy.Char()
    for _, a in ipairs(mine and mine.auctions or {}) do
        local id = LinkID(a.name)
        if id and a.status == "listed" and a.t then
            local k = id .. ":" .. (a.count or 1)
            posted[k] = posted[k] or {}
            table.insert(posted[k], 1, a.t)
        end
    end
    local sums = { value = 0, deposits = 0, guessed = 0, noDeposit = 0, undercut = 0, unpriced = 0, live = 0 }
    for _, e in ipairs(listings.list) do
        -- An overdue one has ended: the posting log has it (sold, expired or not known).
        if not e.overdue then
            local k = e.id and (e.id .. ":" .. (e.count or 1))
            local t = k and posted[k] and table.remove(posted[k], 1) or nil
            sums.live = sums.live + 1
            if e.value then sums.value = sums.value + e.value else sums.unpriced = sums.unpriced + 1 end
            sums.deposits = sums.deposits + (e.deposit or 0)
            if not e.deposit then
                if e.depositGuess then sums.guessed = sums.guessed + e.depositGuess else sums.noDeposit = sums.noDeposit + 1 end
            end
            if e.standing.state == "undercut" then sums.undercut = sums.undercut + 1 end
            Put({ status = "listed", e = e, id = e.id, char = me, t = t }, { id = e.id, timed = false })
        end
    end
    local rest, every = {}, {}
    for key, c in pairs(Economy and Economy.Scope("all") or {}) do
        for _, a in ipairs(c.auctions or {}) do
            every[#every + 1] = a
            local status = Economy.ListingOver(a) and "unknown" or a.status
            -- This character's own listed posts are the live listings above.
            if not (key == me and status == "listed") then rest[#rest + 1] = { status = status, a = a, char = key, t = a.t } end
        end
    end
    -- Listed first, then newest first (one C sort).
    ns.Utils.SortBy(rest, function(it)
        return (it.status == "listed" and "0" or "1") .. ns.Utils.NumKey(it.t or 0, true)
    end)
    for i, it in ipairs(rest) do
        if i % 256 == 0 then ns.Data.Step() end
        local a = it.a
        it.id = LinkID(a.name)
        if it.status == "listed" then
            local count = a.count or 1
            it.unit = (a.buyout and a.buyout > 0) and Prices.Exact(a.buyout / count) or nil
            local hours = type(a.duration) == "string" and tonumber(a.duration:match("^(%d+)")) or nil
            it.endsAt = hours and a.t and (a.t + hours * 3600) or nil
            Put(it, { id = it.id, timed = false })
        else
            -- In a time range by when it ended (the money's day), not when it was
            -- posted; one whose time ran out with no letter by when it would have.
            local when = a.closedAt or a.ended or a.t
            if it.status == "unknown" then
                local hours = type(a.duration) == "string" and tonumber(a.duration:match("^(%d+)")) or 48
                when = (a.t or 0) + hours * 3600
            end
            Put(it, { id = it.id, time = when })
        end
    end
    return { counts = counts, totals = Economy and Economy.AuctionTotals(every) or {}, sums = sums, listings = listings }
end

function UI.BuildMine(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "My auctions")
    v.card:SetAllPoints()
    v.chips = Style.Chips(v.card.content, FILTERS, function(key)
        Page().state.mineFilter = key
        Page().Refresh()
    end)
    v.chips:SetPoint("TOPLEFT", 6, -4)
    local holder = CreateFrame("Frame", nil, v.card.content)
    holder:SetPoint("TOPLEFT", 0, -28)
    holder:SetPoint("BOTTOMRIGHT")
    v.list = Style.List(holder, { colWidths = MINE_WIDTHS, columns = MINE_COLUMNS, search = true, time = true,
        hint = "Search your auctions...", onClick = function(item)
            if not item.id then return end
            Page().ShowOnAH(item.id)
            if Prices.Entry(item.id) then Open(item.id) end
        end })

    function v:Footer()
        return "Your live listings (standing against the lowest at your last look) and every auction you posted, all characters, "
            .. "closed by the auction letters. Standing: lowest, tied or undercut; ? when no look tells."
    end

    function v:Refresh()
        local filter = Page().state.mineFilter or "all"
        self.chips:Select(filter)
        local data = ns.Data.List(self.list, {
            name = "desk:mine", sources = { "prices", "economy" }, key = { tostring(Desk.Listings()), filter }, maxAge = 60,
            row = MineRow, empty = filter == "all" and "No auctions yet: post something at the Auction House."
                or "None with this status.",
            build = function(add) return MineBuild(add, filter) end,
        })
        local c, t, s = data.counts, data.totals, data.sums
        for _, f in ipairs(FILTERS) do self.chips:SetCount(f.key, c[f.key] or 0) end
        local F = ns.Economy and ns.Economy.FormatMoney or Money
        local unpriced = (t.unpriced or 0) > 0 and (" + " .. t.unpriced .. " with no payment known") or ""
        local unknown = (c.unknown or 0) > 0 and ("  ·  " .. c.unknown .. " ended, outcome unknown") or ""
        self.card.sub:SetText(string.format("%d listed  ·  %d undercut  ·  %d sold for %s after the cut%s  ·  %d expired  ·  %d cancelled%s  ·  deposits lost %s  ·  profit %s",
            c.listed, s.undercut, t.sold or 0, F(t.income or 0), unpriced, t.expired or 0, t.cancelled or 0, unknown, F(t.lost or 0),
            F(t.profit or 0, true)))
        -- Paid deposits, then the estimated ones (no logged post) apart, then any with no estimate at all.
        local L = data.listings
        local stake = (s.deposits > 0 or s.guessed == 0) and Money(s.deposits) or ""
        if s.guessed > 0 then stake = stake .. (stake ~= "" and " + " or "") .. "about " .. Money(s.guessed) .. " (estimated)" end
        if s.noDeposit > 0 then stake = stake .. string.format(" + ? (%d not in your posting log)", s.noDeposit) end
        self.card:SetFoot(string.format("%s  ·  %d live listings worth %s after the cut  ·  deposits at stake %s",
            L.source ~= "log" and ("As the Auction House showed them " .. Prices.Age(L.t)
                .. (L.source == "game + log" and ", and your posts since" or "")) or "From your posting log",
            s.live, ListedWorth(s.value, s.unpriced), stake))
    end
    return v
end

---------------------------------------------------------------------------
-- Prices: the control plan of an item with a full look
---------------------------------------------------------------------------
function UI.ControlRows(plan)
    local out = {}
    local L = plan.ladder
    out[#out + 1] = { header = true, control = true, text = "Full look" .. HEX.muted .. "  (every auction of it at one look)|r" }
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
                l[#l + 1] = HEX.muted .. "Your auctions decide once " .. Market.SELL_MIN_ENDED .. " have sold or expired; else the change in units listed between your looks (sales, expiries and new posts all move it).|r"
                ns.Tooltip.Text(o, l) end }
        if ev[2] then out[#out + 1] = { label = "", text = HEX.muted .. ev[2] .. "|r" } end
        if mv.key == "dead" then out[#out + 1] = { label = "", text = HEX.bad .. "Doesn't sell: a reset would only sit there.|r" } end
    end

    local all = plan.all
    out[#out + 1] = { header = true, text = "Own it all" }
    out[#out + 1] = { label = "Buy", text = string.format("%s%s for %d units", plan.atLeast and "at least " or "", Money(all.cost), all.units) }
    out[#out + 1] = { label = "Relist", text = all.relist and (string.format("at %s each (usual)  ·  deposit %s", Money(all.relist),
        all.deposit and Money(all.deposit) or "?") .. (all.overDemand and (HEX.gold .. "  ·  more than sells in one listing|r") or ""))
        or (HEX.muted .. (plan.usualOld and "the usual price is from old looks only|r" or "no usual price yet (4 looks needed)|r")),
        cols = { all.profit and Profit(all.profit) or (all.ifAll and (HEX.muted .. "if all sells |r" .. Profit(all.ifAll)) or Profit(nil)) } }

    out[#out + 1] = { header = true, text = "Resets" .. HEX.muted .. "  (relist 1c under the next seller's auction)|r", sortId = "resets",
        label = "Buy up to", cols = { "Profit" } }
    if #plan.steps == 0 then out[#out + 1] = { text = HEX.muted .. "No gap in the ladder to relist under.|r" } end
    for _, s in ipairs(plan.steps) do
        local best = plan.best == s
        out[#out + 1] = { label = "to " .. Money(s.upTo), text = string.format("%d for %s, relist %s", s.units, Money(s.cost), RelistText(s))
            .. (s.over and (HEX.bad .. "  overpriced|r") or "")
            .. (s.overUsual and (HEX.muted .. "  (" .. Pct(s.overUsual, false) .. HEX.muted .. " vs usual)|r") or "")
            .. ((s.overDemand and s.profit) and (HEX.gold .. "  more than sells in one listing|r") or ""),
            cols = { s.profit and Profit(s.profit) or (s.ifAll and (HEX.muted .. "if all sells |r" .. Profit(s.ifAll)) or Profit(nil)) },
            accent = best and COLORS.accent or nil,
            tooltip = function(o) ns.Tooltip.Text(o, { string.format("Buy every unit up to %s: %d units for %s.", Money(s.upTo), s.units, Money(s.cost)),
                string.format("Relist at %s, valued at %s each (never above the usual price); deposit %s.", RelistText(s),
                    s.value and Money(s.value) or "?", s.deposit and Money(s.deposit) or "?"),
                s.profit and ("Expected with your sell rate: " .. Profit(s.profit) .. (s.roi and ("  (" .. math.floor(s.roi * 100 + 0.5) .. "%)") or ""))
                    or ("No expected profit: " .. Desk.MissingText(plan, s) .. "."),
                "If it all sells: " .. Profit(s.ifAll),
                s.over and (HEX.bad .. "The next seller is over " .. Market.OUTLIER_FACTOR .. "x the usual price: nobody pays that, so this is never the best reset.|r") or nil,
                -- The expected profit sells every unit at your auctions' rate: only
                -- believable while the market has shown it takes that many.
                s.overDemand and (HEX.gold .. (plan.demand
                    and string.format("About %s a day sold lately (yours or the AH's): %d units is more than one listing takes, so this is never the best reset.",
                        plan.demand >= 10 and tostring(math.floor(plan.demand + 0.5)) or string.format("%.1f", plan.demand), s.units)
                    or "How many sell in one listing is unknown (no recent sales or looks): this is never the best reset.") .. "|r") or nil,
                HEX.muted .. "A plan is arithmetic on what you saw: " .. ns.NAME .. " never buys or posts.|r" }) end }
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

-- A row of Prices' "With a full look" list (Desk.Markets).
function UI.MarketRow(p)
    local h = p.holders
    return ItemRow(p.id, Market.ItemText(p.id) .. HEX.muted .. "  " .. p.ladder.units .. " units · " .. Prices.Age(p.ladder.t) .. "|r"
        .. ((p.move.key == "slow" or p.move.key == "dead") and (p.move.hex .. "  · " .. p.move.label .. "|r") or ""),
        { (p.atLeast and (HEX.muted .. ">=|r") or "") .. Money(p.all.cost), p.best and Profit(p.best.profit) or (HEX.dim .. "-|r"),
            h and ((h.share >= Desk.CONTROL_SHARE and not h.mine and HEX.gold or HEX.muted) .. math.floor(h.share * 100 + 0.5) .. "%|r") or ns.UNKNOWN },
        PlanTooltip(p))
end

---------------------------------------------------------------------------
-- Old callers: the desk window is the Auction House page now
---------------------------------------------------------------------------
-- view: overview / listings / deals / margins / control (old tab keys);
-- id: the item to show with its ladder (Prices).
function UI.Show(view, id)
    local M = Page()
    if view == "margins" then return M.OpenProfit() end
    if view == "control" or id then
        M.ShowPage("prices")
        if id then M.OpenPrices(id, true) else M.state.priceFilter = "full" M.Refresh() end
        return true
    end
    if view == "listings" then return M.ShowPage("mine", "auctions", "listed") end
    if view == "deals" then return M.ShowPage("buy", "deals") end
    if view == "overview" then return M.ShowPage("today") end
    return M.ShowPage(nil)
end

function UI.Toggle(view)
    local M = Page()
    if M.IsShown() and not view then M.Frame():Hide() else UI.Show(view) end
end

function UI.IsShown() return Page().IsShown() end
function UI.Refresh() return Page().Refresh() end
