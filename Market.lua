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
-- A deal seen longer ago than this is most likely bought or gone: not listed.
local DEAL_MAX_AGE = 2 * 86400

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
local OUTLIER_FACTOR = 2      -- a look over 2x the median is overpriced, under half of it underpriced
local OUTLIER_LOOKS = 3       -- marking needs this many looks
Market.OUTLIER_FACTOR, Market.OUTLIER_LOOKS = OUTLIER_FACTOR, OUTLIER_LOOKS
-- The usual price follows the market now: it comes from the days within
-- USUAL_DAYS of the newest look. A price held for months does not outvote a
-- week at a new level. With no kept day that recent, the older days stand in
-- and the price is marked stale (usualStale): it says what the market was.
local USUAL_DAYS = 14
Market.USUAL_DAYS = USUAL_DAYS

-- The low median: for an even count the lower middle value, never the mean
-- of the two. With two clusters (100c, 120c | 9999g, 9999g) the mean of the
-- middle pair is a price nobody ever asked; the lower one is a real price and
-- errs on the side of not overvaluing.
local function Median(list)
    if #list == 0 then return nil end
    local v = {}
    for i, x in ipairs(list) do v[i] = x end
    table.sort(v)
    return v[math.floor((#v + 1) / 2)]
end
Market.Median = Median

-- A look under half the yardstick is a throwaway only when it is thin: one
-- auction, or units well under the usual supply. A cheap look with normal or
-- more supply is the market price now (a real drop): selling must reckon
-- with it, never with the higher price before it.
local THIN_SHARE = 0.25
Market.THIN_SHARE = THIN_SHARE

-- Thin is about supply: with the units known they decide (one commodity price
-- row can hold 200 units: a = 1 says how the server grouped them, not how
-- many there are); a single auction counts as thin only when the units are unknown.
local function Thin(n, a, medN)
    if type(n) == "number" then return medN ~= nil and n <= medN * THIN_SHARE end
    return a == 1
end

-- A high look that is the market, not a greedy listing: an exact look with a
-- known, normal supply (not thin). Two of them in a row are a price level
-- that held: a lasting rise is the price to sell at, never "overpriced".
local function Solid(p, n, a, browse, ref)
    return p > ref.base * OUTLIER_FACTOR and not browse and type(n) == "number" and n > 0 and not Thin(n, a, ref.medN)
end
Market.SolidLook = Solid

-- How one look stands against the yardstick `ref` ({ base, medN, keepExact }):
-- "over", "under" or nil. keepExact: only one exact look exists, so the base
-- comes from browse rows (maybe not per unit) and never judges an exact look.
-- A look over 2x the base is overpriced when it is thin, a browse row (its
-- price may not be per unit), of unknown supply, or alone: neither look next
-- to it (prevSolid / nextSolid: Market.SolidLook of the neighbours) held the
-- same high level with a normal supply. The low side the same way: under
-- half the base only when thin.
function Market.OddLook(p, n, a, browse, ref, prevSolid, nextSolid)
    local base = ref and ref.base
    if not base then return nil end
    if ref.keepExact and not browse then return nil end
    if p > base * OUTLIER_FACTOR then
        if Solid(p, n, a, browse, ref) and (prevSolid or nextSolid) then return nil end
        return "over"
    end
    if p * OUTLIER_FACTOR < base and Thin(n, a, ref.medN) then return "under" end
    return nil
end
local OddLook = Market.OddLook

-- Marks the overpriced points (pt.over = true) and the thin underpriced
-- ones (pt.under) and returns the usual price of the rest, the yardstick
-- they were measured with, how many were marked over, and the yardstick
-- as a table for Market.OddLook. The yardstick is the median of the exact
-- looks (auction lists, scans) when there are 2+, else of every look: browse
-- rows (pt.b) may not be per unit, so they never set it while exact looks
-- exist, and never mark a lone exact look. The usual price comes from the
-- exact looks kept, when any.
function Market.MarkOverpriced(points)
    local all, exact, units = {}, {}, {}
    for _, pt in ipairs(points) do
        pt.over, pt.under = nil, nil
        all[#all + 1] = pt.p
        if not pt.b then exact[#exact + 1] = pt.p end
        if type(pt.n) == "number" and pt.n > 0 then units[#units + 1] = pt.n end
    end
    -- medN: the true median (as MarkColumns).
    table.sort(units)
    local medN = #units > 0 and ((#units % 2 == 0) and (units[#units / 2] + units[#units / 2 + 1]) / 2 or units[(#units + 1) / 2]) or nil
    local ref = { base = Median(#exact >= 2 and exact or all), medN = medN, keepExact = #exact == 1 }
    local kept, keptExact, over = {}, {}, 0
    local solid = {}
    if ref.base then
        for i, pt in ipairs(points) do solid[i] = Solid(pt.p, pt.n, pt.a, pt.b, ref) end
    end
    -- One value per day (its lowest kept look), from the recent days only, as MarkColumns.
    local dayOf, dayOfX, keptD, keptXD = {}, {}, {}, {}
    local function Keep(list, days, index, pt)
        local d = ns.Prices.DayKey(pt.t)
        local k = index[d]
        if k then list[k] = math.min(list[k], pt.p)
        else list[#list + 1] = pt.p days[#list] = d index[d] = #list end
    end
    local newest
    for i, pt in ipairs(points) do
        newest = math.max(newest or pt.t, pt.t)
        local odd = #points >= OUTLIER_LOOKS and OddLook(pt.p, pt.n, pt.a, pt.b, ref, solid[i - 1], solid[i + 1]) or nil
        if odd == "over" then
            pt.over, over = true, over + 1
        elseif odd == "under" then
            pt.under = true
        else
            Keep(kept, keptD, dayOf, pt)
            if not pt.b then Keep(keptExact, keptXD, dayOfX, pt) end
        end
    end
    local list, days = kept, keptD
    if #keptExact > 0 then list, days = keptExact, keptXD end
    local recent = {}
    local from = newest and (ns.Prices.DayKey(newest) - Market.USUAL_DAYS) or nil
    for k, v in ipairs(list) do if days[k] > from then recent[#recent + 1] = v end end
    return Median(#recent > 0 and recent or list), ref.base, over, ref
end

-- { p, t, n, a, looks, usual, usualBefore, low, high, highAll, over, overNow,
--   prev, trend, avgN, supplyTrend }
-- usual: median of the looks not marked overpriced; usualBefore: the same
-- from the looks before the latest (today's price must not set the yardstick
-- it is measured with; nil with one look); low / high: of the kept looks
-- (highAll: of every look); over: looks marked; overNow: the latest is.
-- trend: price now vs trendBase, the true median of the earlier days' true
-- medians (-0.14 = 14% under; nil with one look); avgN: the usual units
-- listed (median over the earlier days of each day's most units, 2+ counted
-- looks); supplyTrend: units now vs avgN.
-- Memoized per item on what the entry holds (a look in the same session
-- changes p / t / n / a in place; a new look adds to h): the Prices and
-- Deals tabs ask for every item on each redraw. Callers must not change it.
-- No looks are kept here (a full scan is thousands of items, up to 31 looks
-- each): Market.Points(id) decodes one item's.
function Market.Stats(id)
    local e = ns.Prices.Entry(id)
    if not e then return nil end
    local h = e.h
    local key = tostring(e) .. ":" .. e.p .. ":" .. e.t .. ":" .. (e.n or "") .. ":" .. (e.a or "") .. ":" .. tostring(e.b or "")
        .. ":" .. (type(h) == "table" and #h or type(h) == "string" and #h or 0)
    return ns.Data.Memo("market:stats:" .. id, key, function() return Market.BuildStats(e) end)
end

-- Scratch arrays for the walk over every item: the looks as columns and the
-- lists the medians sort. Nothing here yields (no Data.Step between fill and
-- use), so one set serves every build.
local cols = { t = {}, p = {}, n = {}, a = {}, b = {} }
local over, under, solid = {}, {}, {}
local pool = { all = { len = 0 }, exact = { len = 0 }, kept = { len = 0 }, keptExact = { len = 0 }, units = { len = 0 },
    -- Per kept day: its day key, newest look and the day's true median (the trend's value).
    keptD = { len = 0 }, keptT = { len = 0 }, keptM = { len = 0 }, keptXD = { len = 0 }, keptXT = { len = 0 }, keptXM = { len = 0 },
    dayVals = { len = 0 }, dayValsX = { len = 0 }, selLow = { len = 0 }, selMid = { len = 0 },
    dayUnits = { len = 0 } }
local markRef = {}

local function Clear(list)
    for i = list.len, 1, -1 do list[i] = nil end
    list.len = 0
end

local function Push(list, v)
    local n = list.len + 1
    list[n], list.len = v, n
end

-- Median of a scratch list (sorted in place), as Median above. Second
-- return: the true median (the mean of the middle two for an even count),
-- the trend's yardstick: it must not lean one way (the low one hid every
-- drop seen in two looks and doubled every rise).
local function MedianOfList(list)
    local n = list.len
    if n == 0 then return nil end
    table.sort(list)
    local lo = list[math.floor((n + 1) / 2)]
    return lo, (n % 2 == 0) and (lo + list[n / 2 + 1]) / 2 or lo
end

-- MarkOverpriced over the first n entries of the columns: over[i] / under[i]
-- for an odd look; returns the usual price of the rest, the yardstick, how
-- many were marked over, and the median units listed (the thin test).
-- The usual price takes one value per day (that day's lowest kept look), so
-- how often you looked does not weigh: twelve looks in one evening at the
-- old price must not outvote three days at the new one.
-- fromDay: only the days after it give the usual price and the trend's
-- yardstick (none of them: every day, marked stale).
local function MarkColumns(T, P, B, N, A, n, fromDay)
    local all, exact, kept, keptExact, units = pool.all, pool.exact, pool.kept, pool.keptExact, pool.units
    Clear(all) Clear(exact) Clear(kept) Clear(keptExact) Clear(units)
    for i = 1, n do
        Push(all, P[i])
        if not B[i] then Push(exact, P[i]) end
        if type(N[i]) == "number" and N[i] > 0 then Push(units, N[i]) end
    end
    markRef.keepExact = exact.len == 1
    markRef.base = MedianOfList(exact.len >= 2 and exact or all)
    -- The usual supply for the thin test is the true median: with half the
    -- looks single units at a joke price, the low median would be 1 unit and
    -- nothing would read as thin (Thin no longer takes one auction alone).
    local _, midN = MedianOfList(units)
    markRef.medN, markRef.midN = midN, midN
    local marked = 0
    local base = markRef.base
    for i = 1, n do solid[i] = base ~= nil and Solid(P[i], N[i], A[i], B[i], markRef) end
    solid[n + 1] = false
    local DayKey = ns.Prices.DayKey
    local keptD, keptT, keptM, keptXD, keptXT, keptXM = pool.keptD, pool.keptT, pool.keptM, pool.keptXD, pool.keptXT, pool.keptXM
    local dayVals, dayValsX, dayUnits = pool.dayVals, pool.dayValsX, pool.dayUnits
    Clear(keptD) Clear(keptT) Clear(keptM) Clear(keptXD) Clear(keptXT) Clear(keptXM) Clear(dayVals) Clear(dayValsX) Clear(dayUnits)
    -- A day's values close when the next day starts: its lowest (the usual
    -- price's value), its newest look and its true median (the trend's).
    local day, low, lastT, dayX, lowX, lastX
    local function Close(list, days, times, mids, vals, d, lo, t)
        Push(list, lo) Push(days, d) Push(times, t)
        local _, m = MedianOfList(vals)
        Push(mids, m)
        Clear(vals)
    end
    local unitDay, unitMax
    for i = 1, n do
        over[i], under[i] = false, false
        -- The usual supply: one value per day too (its most units), so a dump
        -- looked at twelve times in one evening is one day, not twelve looks.
        if type(N[i]) == "number" and N[i] > 0 then
            local d = DayKey(T[i])
            if d ~= unitDay then
                if unitMax then Push(dayUnits, unitMax) end
                unitDay, unitMax = d, N[i]
            elseif N[i] > unitMax then unitMax = N[i] end
        end
        local odd = n >= OUTLIER_LOOKS and OddLook(P[i], N[i], A[i], B[i], markRef, solid[i - 1], solid[i + 1]) or nil
        if odd == "over" then
            over[i], marked = true, marked + 1
        elseif odd == "under" then
            under[i] = true
        else
            local d = DayKey(T[i])
            if d ~= day then
                if low then Close(kept, keptD, keptT, keptM, dayVals, day, low, lastT) end
                day, low = d, P[i]
            elseif P[i] < low then low = P[i] end
            lastT = T[i]
            Push(dayVals, P[i])
            if not B[i] then
                if d ~= dayX then
                    if lowX then Close(keptExact, keptXD, keptXT, keptXM, dayValsX, dayX, lowX, lastX) end
                    dayX, lowX = d, P[i]
                elseif P[i] < lowX then lowX = P[i] end
                lastX = T[i]
                Push(dayValsX, P[i])
            end
        end
    end
    if unitMax then Push(dayUnits, unitMax) end
    if low then Close(kept, keptD, keptT, keptM, dayVals, day, low, lastT) end
    if lowX then Close(keptExact, keptXD, keptXT, keptXM, dayValsX, dayX, lowX, lastX) end
    local list, days, times, mids = kept, keptD, keptT, keptM
    if keptExact.len > 0 then list, days, times, mids = keptExact, keptXD, keptXT, keptXM end
    -- The recent days only (fromDay on); none: every day, and the result is stale.
    local selLow, selMid = pool.selLow, pool.selMid
    Clear(selLow) Clear(selMid)
    local newestT, stale = nil, false
    for k = 1, list.len do
        if not fromDay or days[k] > fromDay then
            Push(selLow, list[k]) Push(selMid, mids[k])
            newestT = math.max(newestT or times[k], times[k])
        end
    end
    if selLow.len == 0 and list.len > 0 then
        stale = true
        for k = 1, list.len do
            Push(selLow, list[k]) Push(selMid, mids[k])
            newestT = math.max(newestT or times[k], times[k])
        end
    end
    local usual = MedianOfList(selLow)
    local _, mid = MedianOfList(selMid)
    local _, midN = MedianOfList(dayUnits)
    return usual, markRef.base, marked, markRef.medN, mid, newestT, stale, midN
end

function Market.BuildStats(e)
    local c = ns.Prices.LookColumns(e, cols)
    local T, P, N, A, B = c.t, c.p, c.n, c.a, c.b
    local n = c.count + 1
    T[n], P[n], N[n], A[n], B[n] = e.t, e.p, e.n, e.a, e.b and true or false
    -- The earlier looks on their own first (the marks are redone for all of them).
    -- Only from enough looks to have marked the odd ones: from two looks the
    -- "usual" could be a 9999g joke listing, and Deals and the desk measure
    -- against it.
    -- The trend's yardsticks come from the earlier looks too: the true median
    -- of the price (kept looks) and the median of the units listed (two counted
    -- looks at least: one is just that look). A median, not a mean: one dump
    -- of 2000 units among looks of 20 is not the usual supply.
    -- The trend's yardstick is the true median of each earlier day's true
    -- median: a single look now against days' lowest would read a rise
    -- whenever you look more than once a day (the least of k looks sits under
    -- one look).
    -- Recent days only (Market.USUAL_DAYS before the newest look): the window
    -- is measured from the latest look, not the clock, so the memo holds.
    local fromDay = ns.Prices.DayKey(e.t) - USUAL_DAYS
    local usualBefore, trendBase, usualN, usualBeforeT, usualBeforeStale
    if n > 1 then
        local before, _, _, _, mid, beforeT, beforeStale, daysN = MarkColumns(T, P, B, N, A, n - 1, fromDay)
        if n - 1 >= OUTLIER_LOOKS then usualBefore, usualBeforeT, usualBeforeStale = before, beforeT, beforeStale end
        trendBase = mid
        if pool.units.len >= 2 then usualN = daysN end
    end
    local usual, base, overCount, medN, _, usualT, usualStale = MarkColumns(T, P, B, N, A, n, fromDay)
    local keepExact = markRef.keepExact
    -- The latest look a browse row (its price may not be per unit) while exact
    -- looks exist: it is not "now" against them. No trend, and selling counts
    -- the usual price (from the exact looks) instead.
    local roughNow = B[n] and pool.exact.len > 0 or false
    if roughNow then trendBase = nil end
    local low, high, highAll, countN = nil, nil, nil, 0
    for i = 1, n do
        local p = P[i]
        if not over[i] and not under[i] then
            low = (not low or p < low) and p or low
            high = (not high or p > high) and p or high
        end
        highAll = (not highAll or p > highAll) and p or highAll
        local x = N[i]
        if type(x) == "number" and x > 0 then countN = countN + 1 end
    end
    local nowN = (type(e.n) == "number" and e.n > 0) and e.n or nil
    return {
        -- base / medN / keepExact: the yardstick the looks were marked with (the price graph marks the same way).
        base = base, medN = medN, keepExact = keepExact, countN = countN,
        p = e.p, t = e.t, n = e.n, a = e.a, looks = n, usual = usual, usualBefore = usualBefore,
        -- usualT: the newest look behind the usual price (its age when it stands
        -- in for the latest look); *Stale: no kept day within USUAL_DAYS, so it
        -- comes from older days.
        usualT = usualT, usualStale = usualStale, usualBeforeT = usualBeforeT, usualBeforeStale = usualBeforeStale,
        trendBase = trendBase,
        low = low, high = high, highAll = highAll, over = overCount, overNow = over[n] or false, underNow = under[n] or false,
        roughNow = roughNow,
        few = n < OUTLIER_LOOKS,
        prev = n > 1 and P[n - 1] or nil,
        trend = (trendBase and trendBase > 0) and (e.p - trendBase) / trendBase or nil,
        -- avgN: the usual units listed (median of the earlier days).
        avgN = usualN, supplyTrend = (usualN and usualN > 0 and nowN) and (nowN - usualN) / usualN or nil,
    }
end

-- One item's looks, the latest included, as tables with the overpriced ones
-- marked (pt.over): { t, p, n, a, b } oldest first. New tables each call
-- (the Market window's "Every look" rows); nil without an entry.
function Market.Points(id)
    local e = ns.Prices.Entry(id)
    if not e then return nil end
    local points = ns.Prices.Looks(e)
    for _, x in ipairs(points) do x.c, x.b = nil, x.b and true or nil end
    points[#points + 1] = { t = e.t, p = e.p, n = e.n, a = e.a, b = e.b and true or nil }
    Market.MarkOverpriced(points)
    return points
end

-- The price to reckon with when selling: the lowest at your last look,
-- unless that look is overpriced, then the usual price. Returns price, stats,
-- and true when the usual price stood in.
function Market.FairPrice(id)
    local s = Market.Stats(id)
    if not s then return nil, nil end
    if (s.overNow or s.underNow or s.roughNow) and s.usual then return s.usual, s, true end
    return s.p, s, false
end

-- What one unit sells for on the AH after the cut, at price p: not rounded.
-- The cut is taken from a whole auction's price, so a per-unit figure is
-- multiplied by the count first and rounded once (Market.NetTotal): floored
-- per unit, 20 units at 2c netted 20c instead of 38c and 1c a unit nothing.
function Market.Net(p) return p and p * (1 - Market.CUT) or nil end

-- What one auction (or one sale) of `total` copper brings after the cut, in
-- whole copper. Floored: never more than the seller is paid.
-- [VERIFY] the game's own rounding of the cut on Forever.
function Market.NetTotal(total) return total and math.floor(total * (1 - Market.CUT) + 1e-6) or nil end

---------------------------------------------------------------------------
-- Your sales (Economy's auction log, every character)
---------------------------------------------------------------------------
local function ShortName(link) return type(link) == "string" and (link:match("|h%[(.-)%]|h") or link) or nil end

local function LinkID(link) return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil end

-- Ended auctions before your sell rate counts. 2 of 2 sold is not "100%":
-- its 95% interval is 34-100%. From 5 the estimate (smoothed, below) is a
-- usable guide.
local SELL_MIN_ENDED = 5
local STALE_PRICE = 7 * 86400  -- a price older than this is marked stale
Market.STALE_PRICE = STALE_PRICE
local HARD_RATE = 0.5          -- under this (with 2+ failures): "hard to sell"
local HALF_LIFE_DAYS = 14      -- markets change: an auction counts half as much every 14 days
local RECENT_DAYS = 30
local FAST_RATE = 0.75         -- at or over this: "sells well" / "moves fast"
Market.SELL_MIN_ENDED, Market.HARD_RATE, Market.HALF_LIFE_DAYS, Market.RECENT_DAYS = SELL_MIN_ENDED, HARD_RATE, HALF_LIFE_DAYS, RECENT_DAYS
Market.FAST_RATE = FAST_RATE

-- A sell rate as a whole percent that stays on the side of the verdict it is
-- shown with: 0.745 is "74%" next to "moves" (rounded, 75% would read as
-- "sells well"), 0.495 is "49%" next to "hard to sell".
function Market.RatePct(rate)
    if not rate then return nil end
    local pct = math.floor(rate * 100 + 0.5)
    if rate < FAST_RATE then pct = math.min(pct, FAST_RATE * 100 - 1) end
    if rate < HARD_RATE then pct = math.min(pct, HARD_RATE * 100 - 1) end
    if rate >= HARD_RATE then pct = math.max(pct, HARD_RATE * 100) end
    return pct
end

local function NewSales()
    return { sold = 0, units = 0, pricedUnits = 0, received = 0, proceeds = 0, listed = 0, expired = 0, cancelled = 0, failed = 0, depositLost = 0,
        wSold = 0, wEnded = 0, wEnded2 = 0, recentSold = 0, recentEnded = 0, sellTimes = {} }
end

-- A commodity sold in parts (Economy.SettleListing) is one posting kept as
-- several rows, each with `of` (the posting). The posting is one trial of
-- the sell rate, sold when any part sold: four part-sale letters of one
-- posting are not four sold auctions.
local function PostingKey(a) return a.of end

local function AddTrial(out, sold, closed)
    local days = math.max(0, (time() - (closed or time())) / 86400)
    local w = 0.5 ^ (days / HALF_LIFE_DAYS)
    out.wEnded, out.wEnded2 = out.wEnded + w, out.wEnded2 + w * w
    if sold then out.wSold = out.wSold + w end
    if days <= RECENT_DAYS then
        out.recentEnded = out.recentEnded + 1
        if sold then out.recentSold = out.recentSold + 1 end
    end
end

local function AddSale(out, a)
    -- One listing is one auction (Economy splits multi-stack posts); older
    -- data may still carry stacks with count = all of them.
    local units = a.count or 1
    local key = PostingKey(a)
    if key and (a.status == "sold" or a.status == "expired") then
        out.postings = out.postings or {}
        local g = out.postings[key] or {}
        out.postings[key] = g
        if a.status == "sold" then g.sold = true else g.expired = true end
        local ct = a.closedAt or a.ended or a.t
        if ct then g.closed = math.max(g.closed or 0, ct) end
        -- Time to sell: one per posting (its first part sold), as one trial.
        if a.status == "sold" and a.closedAt and a.t then
            g.sellTime = math.min(g.sellTime or math.huge, a.closedAt - a.t)
        end
    end
    -- A cancelled auction is your choice (often to undercut), not the market
    -- saying no: it is not a trial of the sell rate (its deposit is still lost).
    if not key and (a.status == "sold" or a.status == "expired") then
        AddTrial(out, a.status == "sold", a.closedAt or a.ended or a.t)
    end
    if a.status == "sold" then
        if not key then out.sold = out.sold + 1 end
        out.units = out.units + (a.count or 1)
        out.received = out.received + (a.received or 0)
        -- The sale letter pays your deposit back with the sale: your own money,
        -- not what the item sold for. The price per unit counts only sales
        -- whose payment is known (an unknown payment is not 0c).
        if a.received then
            out.proceeds = out.proceeds + (a.received - (a.deposit or 0))
            out.pricedUnits = out.pricedUnits + (a.count or 1)
        end
        out.last = math.max(out.last or 0, a.closedAt or a.ended or a.t or 0)
        -- Time to sell: only when the letter told when it sold.
        if not key and a.closedAt and a.t then out.sellTimes[#out.sellTimes + 1] = a.closedAt - a.t end
    elseif a.status == "listed" then
        out.listed = out.listed + units
    elseif a.status == "expired" or a.status == "cancelled" then
        if not (key and a.status == "expired") then
            out[a.status] = out[a.status] + 1
            out.failed = out.failed + 1
        end
        out.depositLost = out.depositLost + (a.deposit or 0)
        out.lastFailed = math.max(out.lastFailed or 0, a.closedAt or a.ended or a.t or 0)
    end
end

-- The sell rate: the share sold weighted to recent auctions (wSold / wEnded),
-- smoothed by Laplace's rule of succession over the effective number of
-- auctions behind that share, (nEff x share + 1) / (nEff + 2). Small samples
-- pull toward one half instead of reading 2 of 2 as certain or 0 of 2 as
-- never. nEff = wEnded^2 / sum(w^2) (Kish): auctions of one age count in
-- full (50 expired long ago is still "doesn't sell", not a coin flip), but
-- one recent auction among old ones is one auction: it sets the share, so
-- it must not borrow the old ones' confidence (one sale yesterday after ten
-- old failures is not "92%, sells well").
local function EffectiveN(wEnded, wEnded2)
    return (wEnded2 or 0) > 0 and wEnded * wEnded / wEnded2 or 0
end

local function Smoothed(wSold, wEnded, nEff)
    nEff = nEff or wEnded
    local share = wEnded > 0 and wSold / wEnded or 0
    return (nEff * share + 1) / (nEff + 2)
end
Market.SmoothedRate, Market.EffectiveN = Smoothed, EffectiveN

-- Enough evidence for a rate: SELL_MIN_ENDED auctions, still about that many
-- once their ages are weighed (rounded: five auctions over a few days weigh
-- 4.99, not five; one recent among ten old ones weighs about one).
local function RateKnown(ended, nEff)
    return ended >= SELL_MIN_ENDED and nEff >= SELL_MIN_ENDED - 0.5
end

-- Sell rate and verdict from what you counted.
local function FinishSales(out)
    -- Postings sold in parts: one trial each.
    for _, g in pairs(out.postings or {}) do
        if g.sold then
            out.sold = out.sold + 1
        else
            out.expired, out.failed = out.expired + 1, out.failed + 1
        end
        AddTrial(out, g.sold, g.closed)
        if g.sold and g.sellTime and g.sellTime < math.huge then out.sellTimes[#out.sellTimes + 1] = g.sellTime end
    end
    out.postings = nil
    out.unsold = out.expired                    -- expired only: the market's no
    out.expired = out.expired + out.cancelled   -- older callers: every auction that did not sell
    -- After the cut, without the refunded deposit; nil when no sale's payment is known.
    out.perUnit = out.pricedUnits > 0 and out.proceeds / out.pricedUnits or nil
    -- Trials of the sell rate: sold or expired (a cancel is not one).
    out.ended = out.sold + out.unsold
    -- Weighted to recent auctions: what sold last month says more than last year.
    out.rawRate = out.ended > 0 and out.sold / out.ended or nil
    out.nEff = EffectiveN(out.wEnded, out.wEnded2)
    out.rate = RateKnown(out.ended, out.nEff) and Smoothed(out.wSold, out.wEnded, out.nEff) or nil
    -- Enough auctions, but of such different ages that too few weigh on the share.
    out.rateOld = out.rate == nil and out.ended >= SELL_MIN_ENDED or nil
    -- Hard to sell: recent failures, not last year's.
    out.hard = out.rate ~= nil and out.rate < HARD_RATE and (out.recentEnded - out.recentSold) >= 2
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

function Market.SalesIndex() return SalesIndex() end

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
    -- Records with only a name join the item whose name it is (as MySales
    -- counts them): one item, one tally everywhere.
    local idOfName = {}
    for _, c in pairs(ns.DB().economy or {}) do
        for _, a in ipairs(c.auctions or {}) do
            local id = LinkID(a.name)
            if id and not idOfName[ShortName(a.name)] then
                idOfName[ShortName(a.name)] = id
                idOfName[Market.ItemInfo(id)] = idOfName[Market.ItemInfo(id)] or id
            end
        end
    end
    for _, c in pairs(ns.DB().economy or {}) do
        for _, a in ipairs(c.auctions or {}) do
            local key = LinkID(a.name) or idOfName[ShortName(a.name)] or ShortName(a.name)
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
--   SELL_MIN_ENDED have ended), against the vendor: the better wins. An item
--   that keeps expiring drops to the vendor by itself.
-- Returns copper per unit (not rounded; 0 unknown), how ("ah" / "vendor" / nil) and info:
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
        local fair, s, over = Market.FairPrice(id)
        -- The usual price stands in: it is as old as the looks it comes from,
        -- not as new as the odd look it replaces.
        if over then p, t, info.over = fair, s.usualT or t, true end
        info.few = s and s.few or nil
    end
    info.p, info.t, info.src, info.net = p, t, src, Market.Net(p)
    -- An old price, or one of unknown age, is never shown as today's.
    info.stale = (not t or (time() - t) > STALE_PRICE) or nil
    -- Posting once, with your sell rate r: r * net + (1 - r) * (what an unsold
    -- one is still worth: the vendor price, less the deposit you lost). The
    -- unsold item comes back, so it is not worth 0; the deposit is gone either
    -- way, so that outcome can be below 0 (a deposit over the vendor price).
    -- Without a known rate the AH value is what it brings IF it sells
    -- (info.rateUnknown says so).
    -- Per unit and not rounded (the deposit's share too): callers multiply by
    -- the units and round the total once, as the desk does for a whole stack.
    local r = sales.rate
    if r then
        local dep = ns.AuctionDesk and ns.AuctionDesk.DepositUnit and ns.AuctionDesk.DepositUnit(id) or 0
        info.deposit = dep
        info.expected = r * info.net + (1 - r) * (vendor - (dep or 0))
    else
        info.expected, info.rateUnknown = info.net, true
    end
    if info.expected > vendor and info.expected > 0 then return info.expected, "ah", info end
    return vendor, vendor > 0 and "vendor" or nil, info
end

-- What Market.SaleValue counted, in words (how, info as it returned them):
-- the one label every window uses, so the number can be checked from it.
function Market.SaleValueText(how, info)
    if how == "vendor" then return "the vendor price" end
    if how ~= "ah" or not info then return "no price" end
    local Money = ns.Professions and ns.Professions.Money or tostring
    if info.rateUnknown then
        if info.sales and info.sales.rateOld then
            return "the Auction House after the cut, if it sells (your auctions of it are too old to know your sell rate now)"
        end
        return "the Auction House after the cut, if it sells (too few of your auctions ended to know your sell rate)"
    end
    return string.format("%s each if it sells on the Auction House (after the cut), %d%% sell rate; the unsold share at the "
        .. "vendor price less %s deposit", Money(info.net), Market.RatePct(info.rate) or 0, Money(info.deposit or 0))
end

-- "sold 3 of 5 (60%)", "2 expired, none sold", or nil without ended auctions.
function Market.SellRateText(sales)
    if not sales or sales.ended == 0 then return nil end
    -- The same trials as "sold X of Y": expired auctions (a cancel is your choice, said apart).
    if sales.sold == 0 then
        local n = sales.unsold or sales.ended
        return n .. " expired, none sold" .. ((sales.cancelled or 0) > 0 and (", " .. sales.cancelled .. " cancelled") or "")
    end
    return string.format("sold %d of %d auctions (%d%%)", sales.sold, sales.ended, math.floor(sales.sold / sales.ended * 100 + 0.5))
end

local function DaysAgo(t)
    if not t then return nil end
    local d = math.floor((time() - t) / 86400)
    return d <= 0 and "today" or (d == 1 and "yesterday" or (d .. " days ago"))
end
Market.DaysAgo = DaysAgo

-- Likelihood to sell, for tooltips: the weighted rate as a word and %,
-- plus how fresh the evidence is. nil without ended auctions.
-- Returns line, detail line, r, g, b.
function Market.SellChanceLines(sales)
    if not sales or sales.ended == 0 then return nil end
    -- The word from the rate itself (as Movement decides), the % kept on its side.
    local pct = Market.RatePct(sales.rate)
    local word, r, g, b
    if not pct then
        word, r, g, b = sales.rateOld and "too few recent auctions to tell" or "too few auctions to tell", 0.62, 0.62, 0.62
    elseif sales.hard then word, r, g, b = "hard to sell", 1, 0.31, 0.31
    elseif sales.rate >= FAST_RATE then word, r, g, b = "sells well", 0.25, 1, 0.25
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
--   market: your looks at it: the drop in units listed between two looks
--           (sold, cancelled or expired, less what was newly posted: neither
--           a lower nor an upper bound on sales), per day, against the units
--           listed. "Doesn't sell" from the market alone needs the listings to
--           stand still: the same units at the same price for days (new posts
--           hide sales, so a flat count is not proof).
-- Your auctions decide when SELL_MIN_ENDED have ended recently enough to
-- give a rate (Market.MySales); else the market (under
-- HARD_RATE is "slow", as the tooltip calls it "hard to sell": one scale).
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
-- "Moves" or "moves fast" from the market needs this many units gone: one
-- unit gone in 12 h may be one cancel (a drop is not a sale), and a rate
-- from one event says almost nothing. Fewer can still say "slow" (few gone
-- of many listed).
local MOVE_MIN_GONE = 3
Market.MOVE_MIN_GONE = MOVE_MIN_GONE

-- The market verdict from turnover, units gone and stuck (both paths).
local function MarketKey(turnover, gone, stuck)
    if stuck then return "dead" end
    if not turnover then return "unknown" end
    if turnover >= MOVE_SLOW and (gone or 0) < MOVE_MIN_GONE then return "unknown" end
    if turnover >= MOVE_FAST then return "fast" end
    if turnover >= MOVE_SLOW then return "moves" end
    return "slow"
end

-- The market's evidence is recent or it says nothing about now: only looks
-- from the last MOVE_WINDOW count (a burst of sales weeks ago must not veto a
-- recent stretch where nothing left, nor old stillness stand for today), and
-- when the newest look in a pair is older than STALE_PRICE the verdict is
-- unknown. asOf (the newest look used) says how old the evidence is.
local MOVE_WINDOW = 14 * 86400
Market.MOVE_WINDOW = MOVE_WINDOW

-- Units leaving the AH from your looks: { gonePerDay, avgListed, turnover
-- (share of supply leaving per day), lasts (days the supply lasts), span
-- (seconds covered), pairs, stuck (nothing left over span), asOf } or nil.
function Market.MarketMovement(id)
    local now = time()
    local pts = {}
    for _, pt in ipairs(ns.Prices.History(id, "looks")) do
        if pt.t >= now - MOVE_WINDOW then pts[#pts + 1] = pt end
    end
    local asOf
    local gone, span, pairs, listed, nListed, moved, lastUsed = 0, 0, 0, 0, 0, false, nil
    -- Any change between two looks in reach is movement, however close they are.
    for i = 2, #pts do
        local a, b = pts[i - 1], pts[i]
        if b.t - a.t <= PAIR_MAX and type(a.n) == "number" and type(b.n) == "number" and (a.n ~= b.n or a.p ~= b.p) then moved = true end
    end
    -- Pairs: each look with the first look at least PAIR_MIN later (then on
    -- from that one), so looks every 15 minutes still pair up.
    local i = 1
    while i < #pts do
        local j = i + 1
        while j <= #pts and pts[j].t - pts[i].t < PAIR_MIN do j = j + 1 end
        if j > #pts then break end
        local a, b = pts[i], pts[j]
        local dt = b.t - a.t
        if dt <= PAIR_MAX and type(a.n) == "number" and type(b.n) == "number" then
            gone = gone + math.max(0, a.n - b.n)
            span, pairs = span + dt, pairs + 1
            -- Listed: from the same looks as what left (each look once), as the
            -- daily path does: looks in no pair (weeks old) are not this rate's supply.
            if a.n > 0 and lastUsed ~= i then listed, nListed = listed + a.n, nListed + 1 end
            if b.n > 0 then listed, nListed = listed + b.n, nListed + 1 end
            lastUsed = j
            asOf = math.max(asOf or b.t, b.t)
        end
        i = j
    end
    -- Too few close looks: the daily summary (one point per day, consecutive days).
    -- Movement seen between looks still counts: a day keeps only its most units.
    local daily = span < MOVE_MIN_SPAN
    local seen = span   -- time the "nothing moved" verdict rests on
    if daily then
        local days = {}
        local fromDay = ns.Prices.DayKey(now - MOVE_WINDOW)
        for _, x in ipairs(ns.Prices.History(id, "days")) do
            if x.day >= fromDay then days[#days + 1] = x end
        end
        asOf = nil
        -- When each day's count was seen (the look with the day's most units)
        -- and its first and last look: a pair of days is the real time
        -- between them (23:50 and 00:10 are 20 minutes, not a day). A day
        -- known only from the daily summary has no time: its pairs count a
        -- day for the rate but never for "doesn't sell".
        local at = {}
        for _, pt in ipairs(pts) do
            local d = ns.Prices.DayKey(pt.t)
            local x = at[d]
            if not x then x = { first = pt.t, last = pt.t } at[d] = x end
            x.first, x.last = math.min(x.first, pt.t), math.max(x.last, pt.t)
            if type(pt.n) == "number" and (not x.n or pt.n > x.n) then x.n, x.t = pt.n, pt.t end
        end
        gone, span, pairs, listed, nListed = 0, 0, 0, 0, 0
        local used, untimed, firstT, lastT = {}, false, nil, nil
        for k = 2, #days do
            local a, b = days[k - 1], days[k]
            -- A day whose looks never said how many were listed is skipped, not 0.
            if b.day - a.day == 1 and type(a.n) == "number" and type(b.n) == "number" then
                local ta, tb = at[a.day], at[b.day]
                local dt = 86400
                if ta and tb and ta.t and tb.t then
                    dt = math.min(PAIR_MAX, math.max(0, tb.t - ta.t))
                    firstT = math.min(firstT or ta.first, ta.first)
                    lastT = math.max(lastT or tb.last, tb.last)
                    asOf = math.max(asOf or tb.last, tb.last)
                else
                    untimed = true
                    asOf = math.max(asOf or b.t, b.t)
                end
                gone = gone + math.max(0, a.n - b.n)
                span, pairs = span + dt, pairs + 1
                if a.n ~= b.n or a.p ~= b.p then moved = true end
                used[k - 1], used[k] = true, true
            end
        end
        seen = (not untimed and firstT and lastT) and (lastT - firstT) or 0
        -- Listed: from the same days as what left.
        for k in next, used do
            if days[k].n > 0 then listed, nListed = listed + days[k].n, nListed + 1 end
        end
    end
    if pairs == 0 or span < MOVE_MIN_SPAN then return nil end
    if not asOf or now - asOf > STALE_PRICE then return nil end
    local out = { span = span, pairs = pairs, gone = gone, gonePerDay = gone / (span / 86400), avgListed = nListed > 0 and listed / nListed or nil,
        asOf = asOf }
    -- Nothing says how many were listed: the turnover is unknown, not 0.
    out.turnover = out.avgListed and out.gonePerDay / out.avgListed or nil
    out.lasts = (out.avgListed and out.gonePerDay > 0) and out.avgListed / out.gonePerDay or nil
    out.stuck = not moved and seen >= MOVE_DEAD_SPAN
    if out.stuck then out.span = seen end
    return out
end

-- The verdict: { key ("fast" / "moves" / "slow" / "dead" / "unknown"),
-- label, r, g, b, hex, source ("you" / "market" / nil), sales, market }.
function Market.Movement(id)
    local sales = Market.MySales(id)
    local market = Market.MarketMovement(id)
    local key, source
    -- Your auctions decide while they give a rate and some ended lately; all
    -- of them older than RECENT_DAYS leave it to the market when your looks
    -- say something now (five auctions from last year do not outvote this
    -- week's AH), and still decide when nothing newer exists.
    if sales.rate and (sales.recentEnded > 0 or not market) then
        source = "you"
        if sales.sold == 0 then key = "dead"
        elseif (sales.rate or 0) >= FAST_RATE then key = "fast"
        elseif (sales.rate or 0) >= HARD_RATE then key = "moves"
        else key = "slow" end
    elseif market then
        source = "market"
        key = MarketKey(market.turnover, market.gone, market.stuck)
    else
        key = "unknown"
    end
    local m = MOVE[key]
    return { key = key, label = m.label, r = m.r, g = m.g, b = m.b, hex = m.hex, source = source, sales = sales, market = market }
end

-- Shared { key, hex, label } per verdict: what a list keeps of a movement.
local MOVE_BRIEF = {}
for key, m in pairs(MOVE) do MOVE_BRIEF[key] = { key = key, hex = m.hex, label = m.label } end
Market.MOVE_BRIEF = MOVE_BRIEF

-- Your sell rate, the way AddSale / FinishSales count it, without the tables:
-- returns auctions ended, auctions sold, weighted rate (nil under
-- SELL_MIN_ENDED effective auctions: RateKnown), units sold and auctions
-- ended in the last RECENT_DAYS, and when the first of those units was posted.
local NO_SALES = {}
local function SaleTally(byID, byName, now)
    local sold, failed, wSold, wEnded, wEnded2, recentUnits, recentEnded = 0, 0, 0, 0, 0, 0, 0
    local recentSince
    local postings
    for pass = 1, 2 do
        local list
        if pass == 1 then list = byID else list = byName end
        for _, a in ipairs(list or NO_SALES) do
            local status = a.status
            -- Units you sold lately (every part of a posting): what you have shown sells.
            if status == "sold" and now - (a.closedAt or a.ended or a.t or now) <= RECENT_DAYS * 86400 then
                recentUnits = recentUnits + (a.count or 1)
                -- Since when you were selling them (the earliest such post).
                local from = a.t or a.closedAt or a.ended or now
                recentSince = math.min(recentSince or from, from)
            end
            if status == "sold" or status == "expired" then
                local key = PostingKey(a)
                if key then
                    -- One posting sold in parts: one trial (as AddSale).
                    postings = postings or {}
                    local g = postings[key] or {}
                    postings[key] = g
                    if status == "sold" then g.sold = true end
                    local ct = a.closedAt or a.ended or a.t
                    if ct then g.closed = math.max(g.closed or 0, ct) end
                else
                    local days = math.max(0, (now - (a.closedAt or a.ended or a.t or now)) / 86400)
                    local w = 0.5 ^ (days / HALF_LIFE_DAYS)
                    wEnded, wEnded2 = wEnded + w, wEnded2 + w * w
                    if days <= RECENT_DAYS then recentEnded = recentEnded + 1 end
                    if status == "sold" then wSold = wSold + w sold = sold + 1 else failed = failed + 1 end
                end
            end
        end
    end
    for _, g in pairs(postings or NO_SALES) do
        local days = math.max(0, (now - (g.closed or now)) / 86400)
        local w = 0.5 ^ (days / HALF_LIFE_DAYS)
        wEnded, wEnded2 = wEnded + w, wEnded2 + w * w
        if days <= RECENT_DAYS then recentEnded = recentEnded + 1 end
        if g.sold then wSold = wSold + w sold = sold + 1 else failed = failed + 1 end
    end
    local ended = sold + failed
    local nEff = EffectiveN(wEnded, wEnded2)
    return ended, sold, RateKnown(ended, nEff) and Smoothed(wSold, wEnded, nEff) or nil, recentUnits, recentEnded, recentSince
end

local dayList, dayN, dayP, dayT, dayTN, dayFirst, dayLast = {}, {}, {}, {}, {}, {}, {}

-- Auctions ended, sold and the weighted sell rate of one item (the numbers of
-- Market.MySales without its tables); `index` as for MoveKey.
function Market.SaleCounts(id, index)
    index = index or SalesIndex()
    local byName
    if next(index.byName) then
        local name = Market.ItemInfo(id)
        byName = name and index.byName[name] or nil
    end
    return SaleTally(index.byID[id], byName, time())
end

-- Market.MarketMovement's turnover / stuck from the looks as columns:
-- returns turnover (nil: no evidence at all), stuck, units gone. Same pairs,
-- same daily fallback, no tables per look or per day.
local function MarketTurnover(e)
    local c = ns.Prices.LookColumns(e, cols)
    local T, N, P = c.t, c.n, c.p
    local n = c.count + 1
    T[n], N[n], P[n] = e.t, e.n, e.p
    -- The recent looks only (MOVE_WINDOW), as Market.MarketMovement: the
    -- columns from the first recent look on.
    local now = time()
    local first = 1
    while first <= n and T[first] < now - MOVE_WINDOW do first = first + 1 end
    if first > 1 then
        local k = 0
        for i = first, n do
            k = k + 1
            T[k], N[k], P[k] = T[i], N[i], P[i]
        end
        n = k
    end
    local asOf
    local gone, span, pairsN, moved = 0, 0, 0, false
    local listed, nListed, lastUsed = 0, 0, nil
    for i = 2, n do
        if T[i] - T[i - 1] <= PAIR_MAX and type(N[i - 1]) == "number" and type(N[i]) == "number"
            and (N[i - 1] ~= N[i] or P[i - 1] ~= P[i]) then moved = true end
    end
    local i = 1
    while i < n do
        local j = i + 1
        while j <= n and T[j] - T[i] < PAIR_MIN do j = j + 1 end
        if j > n then break end
        if T[j] - T[i] <= PAIR_MAX and type(N[i]) == "number" and type(N[j]) == "number" then
            gone = gone + math.max(0, N[i] - N[j])
            span, pairsN = span + (T[j] - T[i]), pairsN + 1
            -- Listed: the looks of the counted pairs only, each once.
            if N[i] > 0 and lastUsed ~= i then listed, nListed = listed + N[i], nListed + 1 end
            if N[j] > 0 then listed, nListed = listed + N[j], nListed + 1 end
            lastUsed = j
            asOf = math.max(asOf or T[j], T[j])
        end
        i = j
    end
    local seen = span
    if span < MOVE_MIN_SPAN then
        listed, nListed = 0, 0
        -- The daily summary merged with the looks: most units listed and the
        -- lowest price per day (false: no look that day said how many), and
        -- from the looks the time of the day's count and its first / last
        -- look (Market.MarketMovement: real time, not a day per pair).
        local days = 0
        local fromDay = ns.Prices.DayKey(now - MOVE_WINDOW)
        asOf = nil
        if type(e.d) == "string" then
            for day, lo, _, units in e.d:gmatch("(%d+):([%d%.]+):([%d%.]+):(%d*)") do
                day = tonumber(day)
                if day < fromDay then
                    -- Older than the window: not this rate's evidence.
                elseif dayN[day] == nil then days = days + 1 dayList[days] = day end
                if day >= fromDay then dayN[day], dayP[day] = tonumber(units) or false, tonumber(lo) end
            end
        end
        for i = 1, n do
            local day = ns.Prices.DayKey(T[i])
            local x = dayN[day]
            if x == nil then
                days = days + 1 dayList[days] = day
                dayN[day], dayP[day] = N[i] or false, P[i]
            else
                if N[i] then dayN[day] = x and math.max(x, N[i]) or N[i] end
                dayP[day] = math.min(dayP[day] or P[i], P[i])
            end
            dayFirst[day] = math.min(dayFirst[day] or T[i], T[i])
            dayLast[day] = math.max(dayLast[day] or T[i], T[i])
            if N[i] and (not dayTN[day] or N[i] > dayTN[day]) then dayTN[day], dayT[day] = N[i], T[i] end
        end
        for i = #dayList, days + 1, -1 do dayList[i] = nil end
        table.sort(dayList)
        gone, span, pairsN = 0, 0, 0
        local prevUsed = false
        local untimed, firstT, lastT = false, nil, nil
        for k = 2, days do
            local a, b = dayList[k - 1], dayList[k]
            if b - a == 1 and dayN[a] and dayN[b] then
                local dt = 86400
                if dayT[a] and dayT[b] then
                    dt = math.min(PAIR_MAX, math.max(0, dayT[b] - dayT[a]))
                    firstT = math.min(firstT or dayFirst[a], dayFirst[a])
                    lastT = math.max(lastT or dayLast[b], dayLast[b])
                    asOf = math.max(asOf or dayLast[b], dayLast[b])
                else
                    untimed = true
                    local noon = ns.Prices.DayNoon(b)
                    asOf = math.max(asOf or noon, noon)
                end
                gone = gone + math.max(0, dayN[a] - dayN[b])
                span, pairsN = span + dt, pairsN + 1
                if dayN[a] ~= dayN[b] or dayP[a] ~= dayP[b] then moved = true end
                -- Listed: from the same days as what left (each day once).
                if prevUsed ~= a and dayN[a] > 0 then listed, nListed = listed + dayN[a], nListed + 1 end
                if dayN[b] > 0 then listed, nListed = listed + dayN[b], nListed + 1 end
                prevUsed = b
            end
        end
        seen = (not untimed and firstT and lastT) and (lastT - firstT) or 0
        for k = 1, days do
            local d = dayList[k]
            dayN[d], dayP[d], dayT[d], dayTN[d], dayFirst[d], dayLast[d] = nil, nil, nil, nil, nil, nil
        end
    end
    if pairsN == 0 or span < MOVE_MIN_SPAN then return nil end
    if not asOf or now - asOf > STALE_PRICE then return nil end
    -- Nothing says how many were listed: false (some evidence, turnover unknown).
    local gonePerDay = gone / (span / 86400)
    return nListed > 0 and gonePerDay / (listed / nListed) or false, not moved and seen >= MOVE_DEAD_SPAN, gone, gonePerDay
end

-- Units a day the market has shown it takes: the larger of what you sold in
-- the last RECENT_DAYS (per day over the time you were selling them, at
-- least one listing period: twenty sold today are not twenty a month) and
-- what left the AH between your recent looks. nil when neither says anything
-- (no sale of yours lately and no market evidence): unknown, never a number.
local LISTING_DAYS = 2
function Market.Demand(id, index)
    local _, _, _, recentUnits, _, since = Market.SaleCounts(id, index)
    local own
    if recentUnits > 0 and since then
        local days = math.min(RECENT_DAYS, math.max(LISTING_DAYS, (time() - since) / 86400))
        own = recentUnits / days
    end
    local market
    local A = ns.Archive
    if A and A.Loaded and A.Loaded() then
        local m = Market.MarketMovement(id)
        market = m and m.gonePerDay
    else
        local e = ns.Prices.Entry(id)
        if e then market = select(4, MarketTurnover(e)) end
    end
    if own and market then return math.max(own, market) end
    return own or market
end

-- Market.Movement(id)'s verdict (key, hex, label) without its sales and
-- market tables: what a list of thousands keeps. `index` (optional) is the
-- sales index when the caller has it (a walk reads it once).
function Market.MoveKey(id, index)
    local A = ns.Archive
    if A and A.Loaded and A.Loaded() then
        -- Archived looks join the history (sorted by time): the full path.
        local mv = Market.Movement(id)
        local m = MOVE_BRIEF[mv.key]
        return m.key, m.hex, m.label
    end
    local _, sold, rate, _, recentEnded = Market.SaleCounts(id, index)
    local key
    -- As Market.Movement: old auctions of yours give way to market evidence.
    local turnover, stuck, gone
    if not rate or recentEnded == 0 then
        local e = ns.Prices.Entry(id)
        if e then turnover, stuck, gone = MarketTurnover(e) end
    end
    if rate and (recentEnded > 0 or turnover == nil) then
        if sold == 0 then key = "dead"
        elseif (rate or 0) >= FAST_RATE then key = "fast"
        elseif (rate or 0) >= HARD_RATE then key = "moves"
        else key = "slow" end
    else
        if turnover == nil then key = "unknown"
        else key = MarketKey(turnover or nil, gone, stuck) end
    end
    local m = MOVE_BRIEF[key]
    return m.key, m.hex, m.label
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
        local listed = m.avgListed and tostring(math.floor(m.avgListed + 0.5)) or "?"
        if m.stuck then
            lines[#lines + 1] = string.format("market: nothing left the AH in %s (%s listed)", Market.Duration(m.span), listed)
        else
            -- At the precision measured: 1 unit in 3 days is ~0.3 a day, never "~0".
            local g = m.gonePerDay
            local rate = g >= 10 and tostring(math.floor(g + 0.5)) or (g > 0 and string.format("%.1f", math.max(0.1, g))) or "0"
            lines[#lines + 1] = string.format("market: ~%s a day leave of ~%s listed%s", rate, listed,
                m.lasts and ("  ·  supply lasts ~" .. Market.Duration(m.lasts * 86400)) or "")
        end
        -- How old the evidence is, once it is not from today.
        if m.asOf and time() - m.asOf >= 86400 then lines[#lines] = lines[#lines] .. "  ·  as of " .. DaysAgo(m.asOf) end
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

-- One craft's materials, bought along the price ladders (Professions.BuyCost:
-- the cheapest auctions first, a vendor when cheaper), against what the
-- product brings: Market.SaleValue (the better of the Auction House, after
-- the cut and your sell rate, and the vendor) times what one craft makes.
-- { cost, value, profit, priced, seen, unknown, guessed }: cost is the priced
-- part; unknown = a material nobody has a price for (then no profit, priced
-- false: never a guess shown as a number); priced = both sides known.
-- crafts (optional, default 1): the materials of that many crafts bought
-- together (one whole stack can serve them all). Fourth return: true when
-- only whole stacks were for sale and some materials are left over.
local function MaterialsCost(r, P, crafts)
    crafts = crafts or 1
    local cost, guessed, unknown, spare = 0, false, false, false
    for _, rg in ipairs(r.reagents or {}) do
        local c, info = P.BuyCost(rg[1], rg[2] * crafts)
        if c then
            cost = cost + c
        else
            unknown = true
            cost = cost + (info and info.partial or 0)
        end
        -- An old ladder (Prof.BuyCost's stale) is an estimate of today's cost too.
        if info and (info.estimated or info.stale or info.src == "ah") then guessed = true end
        if info and info.surplus then spare = true end
    end
    return cost, guessed, unknown, spare
end
Market.MaterialsCost = MaterialsCost

function Market.CraftProfit(r)
    local P = ns.Professions
    local cost, guessed, unknown = MaterialsCost(r, P)
    local out = { cost = cost, guessed = guessed, unknown = unknown or nil }
    if r.creates then
        local v, how, info = Market.SaleValue(r.creates)
        local makes = r.makes or 1
        if how then
            out.value, out.how = v * makes, how
            out.seen, out.seenSrc, out.rate, out.hard = info.t, info.src, info.rate, info.hard
            out.rateUnknown, out.few, out.stale = info.rateUnknown, info.few, info.stale
            if not unknown then out.profit, out.priced = out.value - cost, true end
        end
        local _, _, _, sell = Market.ItemInfo(r.creates)
        out.vendor = sell and sell * makes or nil
    end
    return out
end

-- `crafts` crafts of a recipe against their materials, the planner's rule:
-- the products are worth the AH value only for as many as the market listed
-- at your last look, the rest the vendor price (a market of 3 does not buy
-- 30); the materials are what buying all of them costs along the ladders.
-- Returns profit, or nil when a material or the product has no price.
function Market.BatchProfit(r, crafts)
    local P = ns.Professions
    if not (P and r.creates) or crafts <= 0 then return nil end
    local units = crafts * (r.makes or 1)
    local v, how, info = Market.SaleValue(r.creates)
    if not how then return nil end
    local worth = units * v
    if how == "ah" then
        local e = ns.Prices.Entry(r.creates)
        -- The supply of the look that gave the price; unknown (an Auctionator
        -- price, or a look that did not count them): only the vendor price is
        -- sure, so the profit is unknown, never a vendor-only number.
        local listed = info.src == "seen" and e and type(e.n) == "number" and e.n or nil
        if not listed then return nil end
        local atAH = math.min(units, listed)
        worth = atAH * v + (units - atAH) * (info.vendor or 0)
    end
    local cost = 0
    for _, rg in ipairs(r.reagents or {}) do
        local c = P.BuyCost(rg[1], rg[2] * crafts)
        if not c then return nil end
        cost = cost + c
    end
    return math.floor(worth + 0.5) - cost
end

-- What one unit costs to craft: the cheapest recipe that makes it, one
-- craft's materials bought along the ladders, divided by how many it makes.
-- { each, r, estimated } or nil. A recipe with a material nobody has a price
-- for is skipped (its cost is unknown, never a guess); estimated = a material
-- priced without a ladder (thin data). Cooldown recipes count too.
-- spare: only whole stacks of a material were for sale, so one craft pays
-- for more than it uses: `each` is then the price of making just one batch,
-- not a price per unit for more (Market.CraftPlan prices the whole amount).
function Market.CraftCost(id)
    local P = ns.Professions
    if not P then return nil end
    local best
    for _, r in ipairs(Market.MadeBy(id)) do
        if r.reagents and #r.reagents > 0 then
            local cost, estimated, unknown, spare = MaterialsCost(r, P)
            if not unknown then
                local each = cost / math.max(r.makes or 1, 1)
                if not best or each < best.each then best = { each = each, r = r, estimated = estimated, spare = spare or nil } end
            end
        end
    end
    return best
end

-- One craft's materials against your bags: { reagents = { { id, need, have,
-- unit, src, t, sub, craft } }, canMake, buyCost, unknown }. canMake = crafts
-- your bags cover now; buyCost = the materials one craft needs that your bags
-- lack, bought along the ladders (unknown = how many of them have no price;
-- buyCost is then the priced part). sub = all `need` bought (nil: unknown).
-- craft = Market.CraftCost of a material when making it beats buying.
function Market.CraftPlan(r, bags)
    local P = ns.Professions
    bags = bags or ns.Data.Bags()
    local out = { reagents = {}, buyCost = 0, unknown = 0 }
    local canMake
    for _, rg in ipairs(r.reagents or {}) do
        local id, need = rg[1], rg[2]
        local have = bags[id] and bags[id].n or 0
        local unit, src, t = P.ItemPrice(id)
        local sub = P.BuyCost(id, need)
        local e = { id = id, need = need, have = have, unit = unit, src = src, t = t, sub = sub }
        -- Making `need` takes whole crafts: 1 Silver Contact is a whole craft of
        -- 5 (one bar), not a fifth of one. craft.whole = what those crafts cost.
        local craft = Market.CraftCost(id)
        if craft then
            local makes = math.max(craft.r.makes or 1, 1)
            local crafts = math.ceil(need / makes)
            -- The materials of every craft bought together: one whole stack
            -- serves several crafts, never charged once per craft.
            local whole, _, unknown = MaterialsCost(craft.r, P, crafts)
            if not unknown and (not sub or whole < sub) then
                e.craft = { each = craft.each, r = craft.r, estimated = craft.estimated, whole = whole,
                    crafts = crafts, spare = crafts * makes - need }
            end
        end
        out.reagents[#out.reagents + 1] = e
        local n = math.floor(have / need)
        canMake = canMake and math.min(canMake, n) or n
        local lack = math.max(0, need - have)
        if lack > 0 then
            local c, info = P.BuyCost(id, lack)
            if c then out.buyCost = out.buyCost + c
            else
                out.buyCost = out.buyCost + (info and info.partial or 0)
                out.unknown = out.unknown + ((info and info.short) or lack)
            end
        end
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
        -- Copies already bound to you (a bind-on-equip item you wore): a vendor only.
        local boundN = 0
        if not info.bound then
            for _, sl in ipairs(b.slots or {}) do
                if ns.Utils.SlotBound(sl.bag, sl.slot) then boundN = boundN + (sl.n or 1) end
            end
        end
        if boundN > 0 then
            out[#out + 1] = { id = id, n = boundN, link = b.link, vendor = sell, bound = true,
                verdict = sell and "vendor" or "keep" }
        end
        local e = { id = id, n = b.n - boundN, link = b.link, p = info.p, t = info.t, src = info.src, net = info.net, vendor = sell,
            bound = info.bound, expected = info.expected, rate = info.rate, sales = info.sales, hard = info.hard, over = info.over,
            deposit = info.deposit, stale = info.stale }
        if info.unseen then
            e.verdict = "unseen"
        elseif how == "ah" then
            e.verdict = "ah"
        elseif how == "vendor" then
            e.verdict = "vendor"
        else
            e.verdict = "keep"
        end
        if e.n > 0 then out[#out + 1] = e end
    end
    local ORDER = { ah = 1, unseen = 2, vendor = 3, keep = 4 }
    table.sort(out, function(a, b)
        if ORDER[a.verdict] ~= ORDER[b.verdict] then return ORDER[a.verdict] < ORDER[b.verdict] end
        -- By what the row is worth: the expected value the verdict used, not the price if it all sells.
        local va = a.verdict == "ah" and (a.expected or a.net) or (a.vendor or a.net)
        local vb = b.verdict == "ah" and (b.expected or b.net) or (b.vendor or b.net)
        return (va or 0) * a.n > (vb or 0) * b.n
    end)
    return out
end

---------------------------------------------------------------------------
-- Deals: listed now well under the usual price
---------------------------------------------------------------------------
-- The cheapest price per unit someone else asks at the look `s`: from the
-- ladder of that same look, your own units left out. Returns the price, or
-- false when every unit on that ladder is yours, or nil without a ladder of
-- that look (then the look's lowest is all there is, and may be yours).
-- Second return: that auction's stack size (whole-auction ladders only).
function Market.OthersLowest(id, s)
    local L = ns.Prices.Ladder(id)
    if not (L and s and math.abs((L.t or 0) - s.t) <= 600) then return nil end
    for _, t in ipairs(L.tiers) do
        if t.q - (t.m or 0) > 0 then return t.u, t.k end
    end
    return false
end

-- 1c under a price per unit `u`, as you can post it: for a stack of k (the
-- legacy list prices the whole stack) 1c under that stack's total, (u x k -
-- 1) / k each; by the unit (k unknown, a commodity) 1c a unit under, in whole
-- copper. 20 for 39c is undercut at 38c for 20, not 20c.
function Market.Undercut(u, k)
    if k and k > 1 then
        local total = math.floor(u * k + 0.5)
        if total > 1 then return (total - 1) / k end
        return u
    end
    return math.max(1, math.ceil(u - 1e-6) - 1)
end

-- { id, s (stats), p (the price to buy at: the cheapest not yours), gain }
-- where gain = resell at the usual price after the cut, minus that price, per unit.
function Market.Deals()
    local out, ids = {}, {}
    -- The keys first: a paused walk (Data.Step) must not be inside `pairs`.
    for id in pairs(ns.Prices.All()) do ids[#ids + 1] = id end
    for i = 1, #ids do
        if i % 64 == 0 then ns.Data.Step() end
        local id = ids[i]
        local s = Market.Stats(id)
        -- "Usual" from the earlier looks: today's low price must not drag
        -- down the yardstick it is compared with.
        -- And from recent days: a level held months ago is not "usual" now.
        local usual = s and not s.usualBeforeStale and s.usualBefore
        if usual and s.looks >= DEAL_LOOKS and s.p <= usual * DEAL_FACTOR and time() - s.t <= DEAL_MAX_AGE then
            -- A deal is something you can buy: your own cheap listing is not one.
            local p = Market.OthersLowest(id, s)
            if p == nil then p = s.p end
            if p and p <= usual * DEAL_FACTOR then
                local gain = Market.Net(usual) - p
                if gain > 0 then out[#out + 1] = { id = id, s = s, p = p, gain = gain, usual = usual } end
            end
        end
    end
    -- Biggest gain for the money first (the ratio scaled: NumKey keeps two decimals).
    return ns.Utils.SortBy(out, function(d) return ns.Utils.NumKey(d.gain / math.max(1, d.p) * 1e6, true) end)
end
Market.DEAL_FACTOR, Market.DEAL_LOOKS, Market.DEAL_MAX_AGE = DEAL_FACTOR, DEAL_LOOKS, DEAL_MAX_AGE

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
            local fair, s, odd = Market.FairPrice(id)
            -- The lowest at your look may be your own listing: what others ask instead.
            if fair and not odd then
                local others = Market.OthersLowest(id, s)
                if others then fair = others elseif others == false then fair = s.usual end
            end
            -- Prices per unit are kept exact (Prices.Exact): the saving is against what
            -- buying the same units costs, rounded once.
            -- The price compared with must be from about the bid look's time: a
            -- buyout from weeks ago (the bid look had only bid-only auctions,
            -- so no new price) is not a saving today; the look's own cheapest
            -- buyout (b.low) is.
            if fair and not (s and math.abs(s.t - b.t) <= 600) then fair = nil end
            local price = fair or b.low
            -- The bid's search had pages not read: the cheapest buyout may be on one
            -- of them. Only a complete look (a ladder of every auction, as new as the
            -- bids) gives a price to save against; else the saving is unknown.
            if b.partial then
                local L = ns.Prices.Ladder(id)
                local complete = L and not L.partial and (L.more or 0) == 0 and (L.t or 0) >= b.t - 600
                    and s and math.abs((L.t or 0) - s.t) <= 600
                if not complete then price = nil end
            end
            local usual = s and s.usual
            for _, r in ipairs(b.rows) do
                local saving = price and (price * r.count - r.next) or nil
                -- A bid at or over the cheapest buyout of its look is no bargain:
                -- buying out costs less and cannot be outbid.
                local dearer = b.low and r.next / r.count >= b.low
                if not dearer and (not saving or saving > 0.5) then
                    out[#out + 1] = { id = id, r = r, t = b.t, api = b.api, price = price, usual = usual,
                        saving = saving and math.floor(saving + 0.5) or nil,
                        pct = saving and price > 0 and saving / (price * r.count) or nil,
                        resale = usual and (Market.NetTotal(usual * r.count) - r.next) or nil }
                end
            end
        end
    end
    -- By the latest time each can end (look time + its band's longest): bands
    -- seen at looks hours apart do not compare.
    table.sort(out, function(a, b)
        if a.r.ends ~= b.r.ends then return a.r.ends < b.r.ends end
        if (a.pct ~= nil) ~= (b.pct ~= nil) then return a.pct ~= nil end
        if a.pct and b.pct and a.pct ~= b.pct then return a.pct > b.pct end
        return a.id < b.id
    end)
    return out
end

-- Suggested posting price per unit: just under the lowest at your last look
-- (1c under its stack: Market.Undercut); the usual price when that look was
-- overpriced (third return true); your own lowest when only your auctions
-- were listed (fourth return true). Fifth: the stack size it undercuts (the
-- price to type is the stack's total), nil when priced by the unit.
function Market.PostPrice(id)
    local s = Market.Stats(id)
    if not s then return nil end
    -- An odd look either way (one greedy or one thin throwaway auction) is not
    -- the price to post under: the usual price instead.
    if (s.overNow or s.underNow or s.roughNow) and s.usual then return s.usual, s, true end
    -- The lowest auction may be your own: with a ladder from the same look,
    -- go under the cheapest one that is not yours (1c under its stack).
    local others, stack = Market.OthersLowest(id, s)
    if others then return Market.Undercut(others, stack), s, false, nil, stack end
    -- Only yours listed: nobody to undercut (a cancel and repost would lose a deposit for nothing).
    if others == false then return s.p, s, false, true end
    -- No ladder: on the legacy list (stacks priced whole) the look's stack size
    -- when every auction held the same (units / auctions); the modern house
    -- prices commodities by the unit in whole copper.
    local legacy = not (C_AuctionHouse and C_AuctionHouse.PostCommodity)
    local k = (legacy and type(s.n) == "number" and type(s.a) == "number" and s.a > 0 and s.n % s.a == 0) and s.n / s.a or nil
    return Market.Undercut(s.p, k), s, false, nil, k
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
    local pct = mv.source == "you" and mv.sales.rate and ("  " .. Market.RatePct(mv.sales.rate) .. "%") or ""
    t:Pair("Sells", mv.label .. pct, mv)
    for _, l in ipairs(Market.MovementLines(mv)) do t:More(l) end
end

ns.Tooltip.AddItemSection("prices", 10, PriceSection)
ns.Tooltip.AddItemSection("sells", 20, SellsSection)

ns.RegisterModule("Market", {
    defaults = { tooltipPrices = true, tooltipMovement = true, tooltipGraph = true, tooltipGraphAlways = false },
})
