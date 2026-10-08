-- TALOD - Market: what the auction prices you have seen (Prices.lua)
-- say. Per item: the price now against its usual price (the median of
-- your looks, overpriced ones marked and left out), lowest and highest, supply (auctions and units listed) and
-- its trend; what selling it brings on the AH (after the cut) or at a
-- vendor; your own sales of it (Economy's auction log); the recipes that
-- make or use it. Lists: what in your bags to sell where, which recipes
-- you can craft at a profit, and deals (well under the usual price).
--
-- Only numbers you have seen: an item you never looked at has no market
-- price here (Auctionator's or Wowhead's are shown apart, labeled).

local ADDON_NAME, ns = ...
local S = ns.Secret

local Market = {}
ns.Market = Market

-- The faction auction house keeps 5% of a sale (vanilla; the neutral one 15%).
Market.CUT = 0.05
local DEAL_FACTOR = 0.8       -- a deal: at most 80% of the usual price
local DEAL_LOOKS = 3          -- ... with at least this many looks to know "usual"

local function DATA() return ns.ProfessionData or { recipes = {}, items = {} } end

---------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------
-- name, icon, quality, vendor sell price, bind type (1 = on pickup), from the
-- game's item cache when it has the item, else the recipe data or the name
-- the auction house showed.
function Market.ItemInfo(id)
    local name, quality, sell, bind, icon
    local fn = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if type(fn) == "function" then
        local v = { S.CallMulti(14, fn, id) }
        name, quality, icon, sell, bind = v[1], v[3], v[10], v[11], v[14]
    end
    local d = DATA().items[id]
    local e = ns.Prices.Entry(id)
    name = type(name) == "string" and name or (d and d.name) or (e and e.name) or ("item " .. tostring(id))
    if type(quality) ~= "number" then quality = d and d.q or 1 end
    if not icon then icon = (d and d.icon and ("Interface\\Icons\\" .. d.icon)) or 134400 end
    if type(sell) ~= "number" then sell = d and d.sell or nil end
    return name, icon, quality, sell, bind
end

local QUALITY_HEX = { [0] = "|cff9d9d9d", [1] = "|cffffffff", [2] = "|cff1eff00", [3] = "|cff0070dd", [4] = "|cffa335ee", [5] = "|cffff8000" }
function Market.ItemText(id)
    local name, _, quality = Market.ItemInfo(id)
    return (QUALITY_HEX[quality] or "|cffffffff") .. name .. "|r"
end

---------------------------------------------------------------------------
-- Statistics of one item's looks
---------------------------------------------------------------------------
-- Overpriced looks. A look's lowest price can sit far over what the item
-- really goes for: the cheap auctions just sold and one greedy listing is
-- left, or a browse row whose price was not per unit. Such a look stays in
-- the history and is marked (`over`), but the usual price, the trend, deals,
-- sale values and the desk's relist leave it out. Usual = the median of the
-- other looks: one odd look moves it little either way.
local OUTLIER_FACTOR = 2      -- a look over 2x the median is overpriced
local OUTLIER_LOOKS = 3       -- marking needs this many looks
Market.OUTLIER_FACTOR, Market.OUTLIER_LOOKS = OUTLIER_FACTOR, OUTLIER_LOOKS

local function Median(list)
    if #list == 0 then return nil end
    local v = {}
    for i, x in ipairs(list) do v[i] = x end
    table.sort(v)
    local m = math.floor((#v + 1) / 2)
    return #v % 2 == 1 and v[m] or (v[m] + v[m + 1]) / 2
end
Market.Median = Median

-- Marks the overpriced points (pt.over = true) and returns the usual price
-- of the rest, the yardstick they were measured with, and how many were
-- marked. The yardstick is the median of the exact looks (auction lists,
-- scans) when there are 2+, else of every look: browse rows (pt.b) may not
-- be per unit, so they never set it while exact looks exist.
function Market.MarkOverpriced(points)
    local all, exact = {}, {}
    for _, pt in ipairs(points) do
        pt.over = nil
        all[#all + 1] = pt.p
        if not pt.b then exact[#exact + 1] = pt.p end
    end
    local base = Median(#exact >= 2 and exact or all)
    local kept, over = {}, 0
    for _, pt in ipairs(points) do
        if #points >= OUTLIER_LOOKS and base and pt.p > base * OUTLIER_FACTOR then
            pt.over, over = true, over + 1
        else
            kept[#kept + 1] = pt.p
        end
    end
    return Median(kept), base, over
end

-- { p, t, n, a, looks, usual, usualBefore, low, high, highAll, over, overNow,
--   prev, trend, avgN, supplyTrend, points }
-- usual: median of the looks not marked overpriced; usualBefore: the same
-- from the looks before the latest (today's price must not set the yardstick
-- it is measured with; nil with one look); low / high: of the kept looks
-- (highAll: of every look); over: looks marked; overNow: the latest is.
-- trend: price now vs usual (-0.14 = 14% under); supplyTrend: units now vs usual.
-- Memoized per item on what the entry holds (a look in the same session
-- changes p / t / n / a in place; a new look adds to h): the Prices and
-- Deals tabs ask for every item on each redraw. Callers must not change it.
function Market.Stats(id)
    local e = ns.Prices.Entry(id)
    if not e then return nil end
    local h = e.h
    local key = tostring(e) .. ":" .. e.p .. ":" .. e.t .. ":" .. (e.n or "") .. ":" .. (e.a or "") .. ":" .. tostring(e.b or "")
        .. ":" .. (type(h) == "table" and #h or type(h) == "string" and #h or 0)
    return ns.Data.Memo("market:stats:" .. id, key, function() return Market.BuildStats(e) end)
end

function Market.BuildStats(e)
    -- Prices.Looks hands out new tables: they are the points (the warm-up
    -- builds this for every item seen, so no copies).
    local points = ns.Prices.Looks(e)
    for _, x in ipairs(points) do x.c, x.b = nil, x.b and true or nil end
    points[#points + 1] = { t = e.t, p = e.p, n = e.n, a = e.a, b = e.b and true or nil }
    -- The earlier looks on their own first (MarkOverpriced clears and redoes
    -- the marks, so the same tables serve both).
    local usualBefore
    if #points > 1 then
        local before = {}
        for i = 1, #points - 1 do before[i] = points[i] end
        usualBefore = Market.MarkOverpriced(before)
    end
    local usual, _, over = Market.MarkOverpriced(points)
    local low, high, highAll, sumN, countN = nil, nil, nil, 0, 0
    for _, pt in ipairs(points) do
        if not pt.over then
            low = (not low or pt.p < low) and pt.p or low
            high = (not high or pt.p > high) and pt.p or high
        end
        highAll = (not highAll or pt.p > highAll) and pt.p or highAll
        if type(pt.n) == "number" and pt.n > 0 then sumN, countN = sumN + pt.n, countN + 1 end
    end
    local avgN = countN > 0 and sumN / countN or nil
    return {
        p = e.p, t = e.t, n = e.n, a = e.a, looks = #points, usual = usual, usualBefore = usualBefore,
        low = low, high = high, highAll = highAll, over = over, overNow = points[#points].over or false,
        prev = #points > 1 and points[#points - 1].p or nil,
        trend = (#points > 1 and usual and usual > 0) and (e.p - usual) / usual or nil,
        avgN = avgN, supplyTrend = (countN > 1 and avgN and avgN > 0 and e.n) and (e.n - avgN) / avgN or nil,
        points = points,
    }
end

-- The price to reckon with when selling: the lowest at your last look,
-- unless that look is overpriced, then the usual price. Returns price, stats,
-- and true when the usual price stood in.
function Market.FairPrice(id)
    local s = Market.Stats(id)
    if not s then return nil, nil end
    if s.overNow and s.usual then return s.usual, s, true end
    return s.p, s, false
end

-- What one sells for on the AH after the cut, at its current price.
function Market.Net(p) return p and math.floor(p * (1 - Market.CUT)) or nil end

---------------------------------------------------------------------------
-- Your sales (Economy's auction log, every character)
---------------------------------------------------------------------------
local function ShortName(link) return type(link) == "string" and (link:match("|h%[(.-)%]|h") or link) or nil end

local function LinkID(link) return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil end

local SELL_MIN_ENDED = 2       -- ended auctions before your sell rate counts
local HARD_RATE = 0.5          -- under this (with 2+ failures): "hard to sell"
local HALF_LIFE_DAYS = 14      -- markets change: an auction counts half as much every 14 days
local RECENT_DAYS = 30
Market.SELL_MIN_ENDED, Market.HARD_RATE, Market.HALF_LIFE_DAYS, Market.RECENT_DAYS = SELL_MIN_ENDED, HARD_RATE, HALF_LIFE_DAYS, RECENT_DAYS

local function NewSales()
    return { sold = 0, units = 0, received = 0, listed = 0, expired = 0, cancelled = 0, failed = 0, depositLost = 0,
        wSold = 0, wEnded = 0, recentSold = 0, recentEnded = 0, sellTimes = {} }
end

local function AddSale(out, a)
    -- One listing is one auction (Economy splits multi-stack posts); older
    -- data may still carry stacks with count = all of them.
    local units = a.count or 1
    if a.status == "sold" or a.status == "expired" or a.status == "cancelled" then
        local days = math.max(0, (time() - (a.closedAt or a.ended or a.t or time())) / 86400)
        local w = 0.5 ^ (days / HALF_LIFE_DAYS)
        out.wEnded = out.wEnded + w
        if a.status == "sold" then out.wSold = out.wSold + w end
        if days <= RECENT_DAYS then
            out.recentEnded = out.recentEnded + 1
            if a.status == "sold" then out.recentSold = out.recentSold + 1 end
        end
    end
    if a.status == "sold" then
        out.sold, out.units = out.sold + 1, out.units + (a.count or 1)
        out.received = out.received + (a.received or 0)
        out.last = math.max(out.last or 0, a.closedAt or a.ended or a.t or 0)
        -- Time to sell: only when the letter told when it sold.
        if a.closedAt and a.t then out.sellTimes[#out.sellTimes + 1] = a.closedAt - a.t end
    elseif a.status == "listed" then
        out.listed = out.listed + units
    elseif a.status == "expired" or a.status == "cancelled" then
        out[a.status] = out[a.status] + 1
        out.failed = out.failed + 1
        out.depositLost = out.depositLost + (a.deposit or 0)
        out.lastFailed = math.max(out.lastFailed or 0, a.closedAt or a.ended or a.t or 0)
    end
end

-- Sell rate and verdict from what you counted.
local function FinishSales(out)
    out.expired = out.expired + out.cancelled   -- older callers: every auction that did not sell
    out.perUnit = out.units > 0 and out.received / out.units or nil
    out.ended = out.sold + out.failed
    -- Weighted to recent auctions: what sold last month says more than last year.
    out.rawRate = out.ended > 0 and out.sold / out.ended or nil
    out.rate = (out.ended >= SELL_MIN_ENDED and out.wEnded > 0) and out.wSold / out.wEnded or nil
    out.hard = out.rate ~= nil and out.rate < HARD_RATE and out.failed >= 2
    -- Median time from posting to sale (seconds), when known.
    table.sort(out.sellTimes)
    out.sellTime = #out.sellTimes > 0 and out.sellTimes[math.floor((#out.sellTimes + 1) / 2)] or nil
    return out
end

-- Your auctions of one item, every character (Economy's auction log, closed
-- by the auction letters): { sold, units, received, perUnit, listed,
-- expired (expired + cancelled), cancelled, failed, depositLost, ended,
-- rate (sold / ended, each auction weighted 0.5 per 14 days of age; nil
-- under 2 ended), rawRate, recentSold / recentEnded (last 30 days), hard,
-- last (sold), lastFailed }.
-- The planner asks for many items in one go: the auction log is indexed by
-- item ID and name, kept until the economy data changes.
local function SalesIndex()
    return ns.Data.Memo("market:sales", ns.Data.Key("economy"), Market.BuildSalesIndex)
end

function Market.BuildSalesIndex()
    local salesIndex = { byID = {}, byName = {} }
    for _, c in pairs(ns.DB().economy or {}) do
        for _, a in ipairs(c.auctions or {}) do
            local aid, name = LinkID(a.name), ShortName(a.name)
            local list
            if aid then
                list = salesIndex.byID[aid] or {}
                salesIndex.byID[aid] = list
            elseif name then
                list = salesIndex.byName[name] or {}
                salesIndex.byName[name] = list
            end
            if list then list[#list + 1] = a end
        end
    end
    return salesIndex
end

-- For writes that bypass Economy (tests): rebuilt on the next read.
function Market.InvalidateSales() ns.Data.Forget("market:sales") end

function Market.MySales(id)
    local index = SalesIndex()
    local out = NewSales()
    for _, a in ipairs(index.byID[id] or {}) do AddSale(out, a) end
    local name = Market.ItemInfo(id)
    for _, a in ipairs(name and index.byName[name] or {}) do AddSale(out, a) end
    return FinishSales(out)
end

-- Your sales of one item (every character): { { t = when it sold, units } },
-- oldest first. The price graph's "you sold" bars.
function Market.SoldList(id)
    local index = SalesIndex()
    local out = {}
    local name = Market.ItemInfo(id)
    for _, list in ipairs({ index.byID[id] or {}, name and index.byName[name] or {} }) do
        for _, a in ipairs(list) do
            if a.status == "sold" then out[#out + 1] = { t = a.closedAt or a.ended or a.t or 0, units = a.count or 1 } end
        end
    end
    table.sort(out, function(a, b) return a.t < b.t end)
    return out
end

-- Every item you ever put up, worst sellers first: { id, name, sales }.
function Market.SellThroughList()
    local by = {}
    for _, c in pairs(ns.DB().economy or {}) do
        for _, a in ipairs(c.auctions or {}) do
            local key = LinkID(a.name) or ShortName(a.name)
            if key then
                by[key] = by[key] or { id = type(key) == "number" and key or nil, name = ShortName(a.name), sales = NewSales() }
                AddSale(by[key].sales, a)
            end
        end
    end
    local out = {}
    for _, e in pairs(by) do
        FinishSales(e.sales)
        if e.id then e.name = Market.ItemInfo(e.id) end
        out[#out + 1] = e
    end
    table.sort(out, function(a, b)
        local ra, rb = a.sales.rate or 2, b.sales.rate or 2
        if ra ~= rb then return ra < rb end
        if a.sales.failed ~= b.sales.failed then return a.sales.failed > b.sales.failed end
        return (a.name or "") < (b.name or "")
    end)
    return out
end

-- What one unit really brings when you sell it — the one rule the Market
-- window, the profession planner and fishing all use:
--   soulbound or grey: a vendor only;
--   else the Auction House after the cut (your last look, or Auctionator
--   when newer) times the share of your own auctions of it that sold (once
--   2+ have ended), against the vendor: the better wins. An item that keeps
--   expiring drops to the vendor by itself.
-- Returns copper (0 unknown), how ("ah" / "vendor" / nil) and info:
-- { p, t, src, net, expected, vendor, rate, sales, unseen (could go to the
-- AH but never seen there), hard (your auctions of it mostly fail), bound,
-- over (your last look was overpriced: p is the usual price instead) }.
function Market.SaleValue(id)
    local _, _, quality, sell, bind = Market.ItemInfo(id)
    local d = DATA().items[id]
    local vendor = (type(sell) == "number" and sell > 0 and sell) or (d and d.sell) or 0
    local info = { vendor = vendor, bound = bind == 1 }
    if bind == 1 or quality == 0 then return vendor, vendor > 0 and "vendor" or nil, info end
    local p, t, src = ns.Prices.Get(id)
    local sales = Market.MySales(id)
    info.sales, info.rate, info.hard = sales, sales.rate, sales.hard
    if not p then
        info.unseen = true
        return vendor, vendor > 0 and "vendor" or nil, info
    end
    if src == "seen" then
        local fair, _, over = Market.FairPrice(id)
        if over then p, info.over = math.floor(fair + 0.5), true end
    end
    info.p, info.t, info.src, info.net = p, t, src, Market.Net(p)
    info.expected = math.floor(info.net * (sales.rate or 1))
    if info.expected >= vendor and info.expected > 0 then return info.expected, "ah", info end
    return vendor, vendor > 0 and "vendor" or nil, info
end

-- "sold 3 of 5 (60%)", "2 expired, none sold", or nil without ended auctions.
function Market.SellRateText(sales)
    if not sales or sales.ended == 0 then return nil end
    if sales.sold == 0 then return sales.failed .. (sales.failed == 1 and " auction" or " auctions") .. " ended unsold, none sold" end
    return string.format("sold %d of %d auctions (%d%%)", sales.sold, sales.ended, math.floor(sales.sold / sales.ended * 100 + 0.5))
end

local function DaysAgo(t)
    if not t then return nil end
    local d = math.floor((time() - t) / 86400)
    return d <= 0 and "today" or (d == 1 and "yesterday" or (d .. " days ago"))
end

-- Likelihood to sell, for tooltips: the weighted rate as a word and %,
-- plus how fresh the evidence is. nil without ended auctions.
-- Returns line, detail line, r, g, b.
function Market.SellChanceLines(sales)
    if not sales or sales.ended == 0 then return nil end
    local pct = sales.rate and math.floor(sales.rate * 100 + 0.5) or nil
    local word, r, g, b
    if not pct then word, r, g, b = "too few auctions to tell", 0.62, 0.62, 0.62
    elseif sales.hard then word, r, g, b = "hard to sell", 1, 0.31, 0.31
    elseif pct >= 75 then word, r, g, b = "sells well", 0.25, 1, 0.25
    else word, r, g, b = "sells sometimes", 1, 0.82, 0 end
    local line = (pct and (pct .. "% likely to sell — ") or "") .. word
    local parts = { string.format("%d of %d sold", sales.sold, sales.ended) }
    if sales.recentEnded > 0 and sales.recentEnded < sales.ended then
        parts[#parts + 1] = string.format("last %d days: %d of %d", RECENT_DAYS, sales.recentSold, sales.recentEnded)
    elseif sales.recentEnded == 0 then
        parts[#parts + 1] = "none in the last " .. RECENT_DAYS .. " days: may be out of date"
    end
    if sales.last then parts[#parts + 1] = "last sold " .. DaysAgo(sales.last) end
    if sales.lastFailed then parts[#parts + 1] = "last unsold " .. DaysAgo(sales.lastFailed) end
    return line, table.concat(parts, "  ·  "), r, g, b
end

---------------------------------------------------------------------------
-- Movement: does it sell, or is posting it a waste of time?
---------------------------------------------------------------------------
-- Two kinds of evidence, both your own:
--   you:    your auctions of it (sell rate, never sold, time to sell);
--   market: your looks at it: units that left the AH between two looks
--           (sold, cancelled or expired: the AH does not say which, so this
--           is an upper bound on sales), per day, against the units listed.
-- Your auctions decide when 2+ have ended; else the market.
local MOVE = {
    fast = { label = "moves fast", r = 0.25, g = 1, b = 0.25, hex = "|cff40ff40" },
    moves = { label = "moves", r = 0.6, g = 0.9, b = 0.35, hex = "|cff99e659" },
    slow = { label = "slow", r = 1, g = 0.82, b = 0, hex = "|cffffd100" },
    dead = { label = "doesn't sell", r = 1, g = 0.31, b = 0.31, hex = "|cffff4f4f" },
    unknown = { label = "not enough data", r = 0.62, g = 0.62, b = 0.62, hex = "|cff9e9e9e" },
}
Market.MOVE = MOVE
local MOVE_MIN_SPAN = 12 * 3600     -- market evidence needs looks spanning this
local MOVE_DEAD_SPAN = 2 * 86400    -- nothing leaving for this long = doesn't sell
local MOVE_FAST, MOVE_SLOW = 0.3, 0.1   -- share of the listed units leaving per day
local PAIR_MIN, PAIR_MAX = 1800, 3 * 86400

-- Units leaving the AH from your looks: { gonePerDay, avgListed, turnover
-- (share of supply leaving per day), lasts (days the supply lasts), span
-- (seconds covered), pairs, stuck (nothing left over span) } or nil.
function Market.MarketMovement(id)
    local pts = ns.Prices.History(id, "looks")
    local gone, span, pairs, listed, nListed = 0, 0, 0, 0, 0
    for i = 2, #pts do
        local a, b = pts[i - 1], pts[i]
        local dt = b.t - a.t
        if dt >= PAIR_MIN and dt <= PAIR_MAX and type(a.n) == "number" and type(b.n) == "number" then
            gone = gone + math.max(0, a.n - b.n)
            span, pairs = span + dt, pairs + 1
        end
    end
    -- Too few close looks: the daily summary (one point per day, consecutive days).
    if span < MOVE_MIN_SPAN then
        local days = ns.Prices.History(id, "days")
        gone, span, pairs = 0, 0, 0
        for i = 2, #days do
            if days[i].day - days[i - 1].day == 1 then
                gone = gone + math.max(0, (days[i - 1].n or 0) - (days[i].n or 0))
                span, pairs = span + 86400, pairs + 1
            end
        end
    end
    for _, p in ipairs(pts) do
        if type(p.n) == "number" and p.n > 0 then listed, nListed = listed + p.n, nListed + 1 end
    end
    if pairs == 0 or span < MOVE_MIN_SPAN then return nil end
    local out = { span = span, pairs = pairs, gonePerDay = gone / (span / 86400), avgListed = nListed > 0 and listed / nListed or 0 }
    out.turnover = out.avgListed > 0 and out.gonePerDay / out.avgListed or nil
    out.lasts = out.gonePerDay > 0 and out.avgListed / out.gonePerDay or nil
    out.stuck = gone == 0 and span >= MOVE_DEAD_SPAN
    return out
end

-- The verdict: { key ("fast" / "moves" / "slow" / "dead" / "unknown"),
-- label, r, g, b, hex, source ("you" / "market" / nil), sales, market }.
function Market.Movement(id)
    local sales = Market.MySales(id)
    local market = Market.MarketMovement(id)
    local key, source
    if sales.ended >= SELL_MIN_ENDED then
        source = "you"
        if sales.sold == 0 then key = "dead"
        elseif (sales.rate or 0) >= 0.75 then key = "fast"
        elseif (sales.rate or 0) >= 0.4 then key = "moves"
        else key = "slow" end
    elseif market then
        source = "market"
        if market.stuck then key = "dead"
        elseif (market.turnover or 0) >= MOVE_FAST then key = "fast"
        elseif (market.turnover or 0) >= MOVE_SLOW then key = "moves"
        else key = "slow" end
    else
        key = "unknown"
    end
    local m = MOVE[key]
    return { key = key, label = m.label, r = m.r, g = m.g, b = m.b, hex = m.hex, source = source, sales = sales, market = market }
end

-- "  · slow" / "  · doesn't sell" for lists; "" when it moves or is unknown.
function Market.MoveTag(id)
    local mv = Market.Movement(id)
    if mv.key ~= "slow" and mv.key ~= "dead" then return "", mv end
    return mv.hex .. "  · " .. mv.label .. "|r", mv
end

function Market.Duration(secs)
    if not secs then return "?" end
    if secs < 3600 then return math.max(1, math.floor(secs / 60)) .. " min" end
    if secs < 2 * 86400 then return math.floor(secs / 3600 + 0.5) .. " h" end
    return math.floor(secs / 86400 + 0.5) .. " days"
end

-- Tooltip / detail text: the verdict line and up to two evidence lines.
function Market.MovementLines(mv)
    local lines = {}
    local s = mv.sales
    if s.ended > 0 then
        local parts = { string.format("you sold %d of %d", s.sold, s.ended) }
        if s.sellTime then parts[#parts + 1] = "usually in " .. Market.Duration(s.sellTime) end
        if s.sold == 0 then parts[#parts + 1] = "none ever sold" end
        -- Recent auctions weigh more: say so when they differ from the total.
        if s.recentEnded > 0 and s.recentEnded < s.ended then
            parts[#parts + 1] = string.format("last %d days: %d of %d", RECENT_DAYS, s.recentSold, s.recentEnded)
        end
        if s.last then parts[#parts + 1] = "last sold " .. DaysAgo(s.last) end
        if s.recentEnded == 0 then parts[#parts + 1] = "none in " .. RECENT_DAYS .. " days" end
        lines[#lines + 1] = table.concat(parts, "  ·  ")
    end
    local m = mv.market
    if m then
        if m.stuck then
            lines[#lines + 1] = string.format("market: nothing left the AH in %s (%d listed)", Market.Duration(m.span), math.floor(m.avgListed + 0.5))
        else
            lines[#lines + 1] = string.format("market: ~%d a day leave of ~%d listed%s", math.floor(m.gonePerDay + 0.5), math.floor(m.avgListed + 0.5),
                m.lasts and ("  ·  supply lasts ~" .. Market.Duration(m.lasts * 86400)) or "")
        end
    end
    if #lines == 0 then lines[1] = "post it or look at it on the AH a few times to know" end
    return lines
end

---------------------------------------------------------------------------
-- Recipes
---------------------------------------------------------------------------
function Market.MadeBy(id)
    local d = DATA().items[id]
    local out = {}
    for _, sid in ipairs(d and d.made or {}) do
        if DATA().recipes[sid] then out[#out + 1] = DATA().recipes[sid] end
    end
    return out
end

local usedIndex
function Market.UsedIn(id)
    if not usedIndex then
        usedIndex = {}
        for _, r in pairs(DATA().recipes) do
            for _, rg in ipairs(r.reagents or {}) do
                usedIndex[rg[1]] = usedIndex[rg[1]] or {}
                table.insert(usedIndex[rg[1]], r)
            end
        end
        for _, list in pairs(usedIndex) do table.sort(list, function(a, b) return a.skill < b.skill end) end
    end
    return usedIndex[id] or {}
end

-- Materials (bought at the best known prices) against what the product
-- sells for on the AH after the cut. { cost, value, profit, priced, seen }:
-- priced false when the product has no auction price; seen = its look's time.
function Market.CraftProfit(r)
    local P = ns.Professions
    local cost, guessed = 0, false
    for _, rg in ipairs(r.reagents or {}) do
        local unit, src = P.ItemPrice(rg[1])
        if src == "ah" or src == "unknown" then guessed = true end
        cost = cost + rg[2] * unit
    end
    local out = { cost = cost, guessed = guessed }
    if r.creates then
        local p, t, src = ns.Prices.Get(r.creates)
        if p then
            -- After the cut and your sell rate for it (Market.SaleValue).
            local _, _, info = Market.SaleValue(r.creates)
            out.value = (info.expected or Market.Net(p)) * (r.makes or 1)
            out.profit, out.priced, out.seen, out.seenSrc, out.rate, out.hard = out.value - cost, true, t, src, info.rate, info.hard
        end
        local _, _, _, sell = Market.ItemInfo(r.creates)
        out.vendor = sell and sell * (r.makes or 1) or nil
    end
    return out
end

-- What one unit costs to craft: the cheapest recipe that makes it, its
-- materials at the best known prices divided by how many it makes.
-- { each, r, estimated } or nil. A recipe with a material nobody has a price
-- for is skipped (its cost is unknown, never a guess); estimated = a material
-- priced only by Wowhead's Classic Era average. Cooldown recipes count too.
function Market.CraftCost(id)
    local P = ns.Professions
    if not P then return nil end
    local best
    for _, r in ipairs(Market.MadeBy(id)) do
        local cost, estimated, known = 0, false, (r.reagents and #r.reagents > 0) or false
        for _, rg in ipairs(r.reagents or {}) do
            local unit, src = P.ItemPrice(rg[1])
            if src == "unknown" then known = false break end
            if src == "ah" then estimated = true end
            cost = cost + rg[2] * unit
        end
        if known then
            local each = cost / math.max(r.makes or 1, 1)
            if not best or each < best.each then best = { each = each, r = r, estimated = estimated } end
        end
    end
    return best
end

-- One craft's materials against your bags: { reagents = { { id, need, have,
-- unit, src, t, sub, craft } }, canMake, buyCost }. canMake = crafts your bags
-- cover now; buyCost = the materials one craft needs that your bags lack.
-- craft = Market.CraftCost of a material when making it beats its price.
function Market.CraftPlan(r, bags)
    local P = ns.Professions
    bags = bags or ns.Data.Bags()
    local out = { reagents = {}, buyCost = 0 }
    local canMake
    for _, rg in ipairs(r.reagents or {}) do
        local id, need = rg[1], rg[2]
        local have = bags[id] and bags[id].n or 0
        local unit, src, t = P.ItemPrice(id)
        local e = { id = id, need = need, have = have, unit = unit, src = src, t = t, sub = unit * need }
        local craft = Market.CraftCost(id)
        if craft and (src == "unknown" or craft.each < unit) then e.craft = craft end
        out.reagents[#out.reagents + 1] = e
        local n = math.floor(have / need)
        canMake = canMake and math.min(canMake, n) or n
        out.buyCost = out.buyCost + math.max(0, need - have) * unit
    end
    out.canMake = canMake or 0
    return out
end

-- Recipes of your professions you can make now, best profit first.
-- mode "known": only recipes you know (read from the profession window).
-- opts.cooldowns: also the once-a-day recipes (transmutes, Mooncloth),
-- marked pr.cooldown; opts.bags: add canMake from your bags.
function Market.CraftList(charKey, mode, opts)
    opts = opts or {}
    local c = charKey and ns.DB().skills and ns.DB().skills[charKey]
    local bags = opts.bags and ns.Data.Bags() or nil
    local out = {}
    for prof, s in pairs(c and c.current or {}) do
        local known = ns.Professions.Known(charKey, prof)
        for _, r in ipairs(ns.Professions.Recipes(prof)) do
            if r.creates and r.skill <= s.rank and (opts.cooldowns or not r.cooldown) and (mode ~= "known" or (known and known[r.name])) then
                local pr = Market.CraftProfit(r)
                pr.r, pr.known, pr.cooldown = r, known and known[r.name] or false, r.cooldown and true or nil
                pr.margin = pr.profit and pr.cost > 0 and pr.profit / pr.cost or nil
                if bags then
                    local n
                    for _, rg in ipairs(r.reagents or {}) do
                        local k = math.floor((bags[rg[1]] and bags[rg[1]].n or 0) / rg[2])
                        n = n and math.min(n, k) or k
                    end
                    pr.canMake = n or 0
                end
                out[#out + 1] = pr
            end
        end
    end
    table.sort(out, function(a, b)
        if (a.priced or false) ~= (b.priced or false) then return a.priced and true or false end
        if a.priced then return a.profit > b.profit end
        return a.r.name < b.r.name
    end)
    return out
end

---------------------------------------------------------------------------
-- Selling: your bags
---------------------------------------------------------------------------
-- { id, n, link, p, t, src, net, vendor, bound, verdict } per item in your
-- bags. verdict: "ah", "vendor", "keep" (no price anywhere), "unseen".
function Market.SellList()
    local bags = ns.Economy and ns.Economy.ScanBags and ns.Economy.ScanBags() or {}
    local out = {}
    for id, b in pairs(bags) do
        local value, how, info = Market.SaleValue(id)
        local sell = info.vendor > 0 and info.vendor or nil
        local e = { id = id, n = b.n, link = b.link, p = info.p, t = info.t, src = info.src, net = info.net, vendor = sell,
            bound = info.bound, expected = info.expected, rate = info.rate, sales = info.sales, hard = info.hard, over = info.over }
        if info.unseen then
            e.verdict = "unseen"
        elseif how == "ah" then
            e.verdict = "ah"
        elseif how == "vendor" then
            e.verdict = "vendor"
        else
            e.verdict = "keep"
        end
        out[#out + 1] = e
    end
    local ORDER = { ah = 1, unseen = 2, vendor = 3, keep = 4 }
    table.sort(out, function(a, b)
        if ORDER[a.verdict] ~= ORDER[b.verdict] then return ORDER[a.verdict] < ORDER[b.verdict] end
        return (a.net or a.vendor or 0) * a.n > (b.net or b.vendor or 0) * b.n
    end)
    return out
end

---------------------------------------------------------------------------
-- Deals: listed now well under the usual price
---------------------------------------------------------------------------
-- { id, s (stats), gain } where gain = resell at the usual price after the
-- cut, minus the price now, per unit.
function Market.Deals()
    local out = {}
    for id in pairs(ns.Prices.All()) do
        local s = Market.Stats(id)
        -- "Usual" from the earlier looks: today's low price must not drag
        -- down the yardstick it is compared with.
        local usual = s and s.usualBefore
        if usual and s.looks >= DEAL_LOOKS and s.p <= usual * DEAL_FACTOR then
            local gain = Market.Net(usual) - s.p
            if gain > 0 then out[#out + 1] = { id = id, s = s, gain = gain, usual = usual } end
        end
    end
    -- Biggest gain for the money first (the ratio scaled: NumKey keeps two decimals).
    return ns.Utils.SortBy(out, function(d) return ns.Utils.NumKey(d.gain / math.max(1, d.s.p) * 1e6, true) end)
end
Market.DEAL_FACTOR, Market.DEAL_LOOKS = DEAL_FACTOR, DEAL_LOOKS

-- Auctions to bid on: every auction still running (Prices.Bids) whose next
-- bid is under the item's price. Price = Market.FairPrice (the lowest buyout
-- at your last look, the usual price when that look was overpriced), else
-- the cheapest buyout at the bid look. No price at all: listed with
-- saving nil ("?"), never as a bargain. Soonest to end first, then the
-- biggest saving. { id, r = bid row, t, api, price, saving, pct, usual,
-- resale (usual after the cut x count − bid) }.
function Market.Bids(now)
    now = now or time()
    local out = {}
    for id in pairs(ns.Prices.AllBids()) do
        local b = ns.Prices.Bids(id, now)
        if b then
            local fair, s = Market.FairPrice(id)
            local price = fair or b.low
            local usual = s and s.usual
            for _, r in ipairs(b.rows) do
                local saving = price and (price * r.count - r.next) or nil
                if not saving or saving > 0 then
                    out[#out + 1] = { id = id, r = r, t = b.t, api = b.api, price = price, usual = usual,
                        saving = saving and math.floor(saving + 0.5) or nil,
                        pct = saving and price > 0 and saving / (price * r.count) or nil,
                        resale = usual and (Market.Net(usual) * r.count - r.next) or nil }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        local ba, bb = a.r.band or 99, b.r.band or 99
        if ba ~= bb then return ba < bb end
        if (a.pct ~= nil) ~= (b.pct ~= nil) then return a.pct ~= nil end
        if a.pct and b.pct and a.pct ~= b.pct then return a.pct > b.pct end
        return a.r.ends < b.r.ends
    end)
    return out
end

-- Suggested posting price per unit: just under the lowest at your last look;
-- the usual price when that look was overpriced (third return true).
function Market.PostPrice(id)
    local s = Market.Stats(id)
    if not s then return nil end
    if s.overNow and s.usual then return math.max(1, math.floor(s.usual + 0.5)), s, true end
    return math.max(1, s.p - 1), s, false
end

---------------------------------------------------------------------------
-- Item tooltips: your Auction House price on every item tooltip.
---------------------------------------------------------------------------
-- Lines under every item tooltip (Tooltip.lua owns the hook and the look).
local function PriceSection(t, id)
    if not ns.DB().tooltipPrices then return end
    local Money = ns.Professions.Money
    local p, at, src = ns.Prices.Get(id)
    if not p then
        t:Pair("Auction", "not seen yet", "muted")
        return
    end
    t:Pair("Auction", Money(p) .. " each  ·  " .. (src == "auctionator" and "Auctionator, " or "") .. ns.Prices.Age(at, src))
    local e = ns.Prices.Entry(id)
    if src == "seen" and e and e.scan then t:More("in the full scan " .. ns.Prices.Age(e.scan)) end
    local s = Market.Stats(id)
    if s then
        local parts = {}
        if s.a and s.a > 0 then parts[#parts + 1] = s.a .. " auctions" end
        if s.n and s.n > 0 then parts[#parts + 1] = s.n .. " units" end
        if s.looks > 1 and s.usual then parts[#parts + 1] = "usual " .. Money(math.floor(s.usual + 0.5)) end
        if #parts > 0 then t:More(table.concat(parts, "  ·  ")) end
        if s.overNow then t:More("last look overpriced (over " .. OUTLIER_FACTOR .. "x usual): left out of the usual") end
    end
end

-- Does it sell: your auctions first, else how fast it leaves the AH.
local function SellsSection(t, id)
    if not ns.DB().tooltipMovement then return end
    local _, _, quality, _, bind = Market.ItemInfo(id)
    if bind == 1 or quality == 0 then return end
    local mv = Market.Movement(id)
    -- An item never seen nor posted: nothing to say.
    if mv.key == "unknown" and not ns.Prices.Get(id) and mv.sales.ended == 0 then return end
    local pct = mv.source == "you" and mv.sales.rate and ("  " .. math.floor(mv.sales.rate * 100 + 0.5) .. "%") or ""
    t:Pair("Sells", mv.label .. pct, mv)
    for _, l in ipairs(Market.MovementLines(mv)) do t:More(l) end
end

ns.Tooltip.AddItemSection("prices", 10, PriceSection)
ns.Tooltip.AddItemSection("sells", 20, SellsSection)

ns.RegisterModule("Market", {
    defaults = { tooltipPrices = true, tooltipMovement = true, tooltipGraph = true, tooltipGraphAlways = false },
})
