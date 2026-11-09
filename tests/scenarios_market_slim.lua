-- Market and Auction desk keep little per item: statistics without a table per
-- look, desk plans without tiers / steps / stats / movement tables. Every number
-- must equal what the full versions gave, so this file holds copies of the old
-- build functions (the oracle) and compares them with the slim ones over a few
-- hundred random price histories, ladders and auction logs.
local scenarios, T = ...
local check, boot = T.check, T.boot

---------------------------------------------------------------------------
-- Oracle: the statistics and the plan as they were built before the slimming
---------------------------------------------------------------------------
local OUTLIER_FACTOR, OUTLIER_LOOKS = 2, 3

local function OldMedian(list)
    if #list == 0 then return nil end
    local v = {}
    for i, x in ipairs(list) do v[i] = x end
    table.sort(v)
    local m = math.floor((#v + 1) / 2)
    return #v % 2 == 1 and v[m] or (v[m] + v[m + 1]) / 2
end

local function OldMark(points)
    local all, exact = {}, {}
    for _, pt in ipairs(points) do
        pt.over = nil
        all[#all + 1] = pt.p
        if not pt.b then exact[#exact + 1] = pt.p end
    end
    local base = OldMedian(#exact >= 2 and exact or all)
    local kept, over = {}, 0
    for _, pt in ipairs(points) do
        if #points >= OUTLIER_LOOKS and base and pt.p > base * OUTLIER_FACTOR then
            pt.over, over = true, over + 1
        else
            kept[#kept + 1] = pt.p
        end
    end
    return OldMedian(kept), base, over
end

local function OldBuildStats(ns, e)
    local points = ns.Prices.Looks(e)
    for _, x in ipairs(points) do x.c, x.b = nil, x.b and true or nil end
    points[#points + 1] = { t = e.t, p = e.p, n = e.n, a = e.a, b = e.b and true or nil }
    local usualBefore
    if #points > 1 then
        local before = {}
        for i = 1, #points - 1 do before[i] = points[i] end
        usualBefore = OldMark(before)
    end
    local usual, _, over = OldMark(points)
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

local STAT_FIELDS = { "p", "t", "n", "a", "looks", "usual", "usualBefore", "low", "high", "highAll", "over", "overNow",
    "prev", "trend", "avgN", "supplyTrend" }

local function SameStats(new, old, what)
    check((new == nil) == (old == nil), what .. ": one side nil")
    if not new then return end
    for _, f in ipairs(STAT_FIELDS) do
        check(new[f] == old[f], what .. ": " .. f .. " " .. tostring(new[f]) .. " vs " .. tostring(old[f]))
    end
    check(new.points == nil, what .. ": no points kept")
end

-- The old plan: the whole ladder, every step, the stats and the movement.
local function OldPlan(ns, id, stats)
    local Desk, Market, Prices = ns.AuctionDesk, ns.Market, ns.Prices
    local L = Prices.Ladder(id)
    if not (L and #L.tiers > 0) then return nil end
    local usual = (stats and stats.looks >= 2) and stats.usualBefore or nil
    local sales = Market.MySales(id)
    local rate = sales.rate
    local cut = 1 - Market.CUT
    local plan = { id = id, ladder = L, stats = stats, usual = usual, rate = rate, age = time() - L.t,
        atLeast = L.partial or L.more > 0, holders = Desk.Holders(L), steps = {}, moves = Market.Movement(id) }
    plan.stale = plan.age > Desk.FRESH
    local cost, units = 0, 0
    for k, t in ipairs(L.tiers) do
        local q = t.q - t.m
        cost, units = cost + q * t.u, units + q
        local wall
        for j = k + 1, #L.tiers do
            if L.tiers[j].q - L.tiers[j].m > 0 then wall = L.tiers[j].u break end
        end
        if wall and q > 0 and wall - 1 > t.u then
            local relist = wall - 1
            local deposit = Desk.Deposit(id, units)
            local revenue = math.floor(math.floor(relist * cut) * units * (rate or 1))
            local profit = revenue - cost - deposit
            plan.steps[#plan.steps + 1] = { k = k, upTo = t.u, units = units, cost = cost, relist = relist, deposit = deposit,
                revenue = revenue, profit = profit, roi = cost > 0 and profit / cost or nil,
                overUsual = usual and usual > 0 and (relist - usual) / usual or nil,
                over = usual and relist > usual * Market.OUTLIER_FACTOR or nil }
        end
    end
    for _, step in ipairs(plan.steps) do
        if step.profit > 0 and not step.over and (not plan.best or step.profit > plan.best.profit) then plan.best = step end
    end
    local top = 0
    for _, t in ipairs(L.tiers) do
        if not (usual and t.u > usual * Market.OUTLIER_FACTOR) then top = t.u end
    end
    local relist = math.max(math.floor(usual or 0), top)
    local deposit = Desk.Deposit(id, units)
    local revenue = math.floor(math.floor(relist * cut) * units * (rate or 1))
    plan.all = { units = units, cost = cost, relist = relist, deposit = deposit, revenue = revenue,
        profit = revenue - cost - deposit, roi = cost > 0 and (revenue - cost - deposit) / cost or nil }
    return plan
end

-- Fields (values, not identity) of two tables equal, nil on both sides allowed.
local function SameFields(a, b, fields, what)
    check((a == nil) == (b == nil), what .. ": one side nil")
    if not a then return end
    for _, f in ipairs(fields) do
        check(a[f] == b[f], what .. ": " .. f .. " " .. tostring(a[f]) .. " vs " .. tostring(b[f]))
    end
end

local STEP_FIELDS = { "k", "upTo", "units", "cost", "relist", "deposit", "revenue", "profit", "roi", "overUsual", "over" }
local ALL_FIELDS = { "units", "cost", "relist", "deposit", "revenue", "profit", "roi" }
local HOLDER_FIELDS = { "share", "name", "sellers", "mine" }

---------------------------------------------------------------------------
-- Random data
---------------------------------------------------------------------------
local function pick(list) return list[math.random(1, #list)] end

local function makeData(ns, count, now)
    local Pr = ns.Prices
    local realm = ns.DB().prices[Pr.RealmKey()] or {}
    ns.DB().prices[Pr.RealmKey()] = realm
    local ids = {}
    for id = 1001, 1000 + count do
        ids[#ids + 1] = id
        local L = pick({ 0, 0, 1, 2, 2, 3, 3, 4, 6, 12, 30, 30, 31 })
        local t = now - pick({ 0, 60, 1800, 7200, 86400, 3 * 86400 })
        local base = math.random(20, 3000)
        local looks, tt = {}, t
        local gapKinds = math.random() < 0.3 and { 700, 1200, 3000 } or { 700, 3600, 4 * 3600, 86400, 2 * 86400, 5 * 86400 }
        for i = L, 1, -1 do
            tt = tt - pick(gapKinds)
            local p = base + math.random(-math.floor(base / 5), math.floor(base / 5))
            if math.random() < 0.18 then p = base end
            if math.random() < 0.12 then p = p * math.random(3, 9) end
            if math.random() < 0.08 then p = math.max(1, math.floor(base / 3)) end
            looks[i] = { t = tt, p = p, n = (math.random() < 0.12) and nil or math.random(0, 400),
                a = (math.random() < 0.2) and nil or math.random(1, 40), c = math.random(1, 3), b = (math.random() < 0.3) and 1 or nil }
        end
        local p = base + math.random(-math.floor(base / 6), math.floor(base / 6))
        local r = math.random()
        if r < 0.1 then p = base * math.random(3, 9) elseif r < 0.2 then p = math.max(1, math.floor(base * 0.4)) end
        local e = { p = p, t = t, n = (math.random() < 0.1) and nil or math.random(0, 300), a = math.random(1, 30),
            name = "Item " .. id, c = 1, b = (math.random() < 0.25) and 1 or nil }
        if #looks > 0 then
            if math.random() < 0.15 then
                local tbl = {}
                for i, x in ipairs(looks) do tbl[i] = { x.t, x.p, x.n, x.a, x.c, x.b } end
                e.h = tbl
            else
                e.h = Pr.PackLooks(looks)
            end
        end
        if math.random() < 0.4 then
            -- A daily summary: the days of the looks and some older days.
            local days, seen, order = {}, {}, {}
            local function add(day, lo, hi, n)
                if not seen[day] then seen[day] = true order[#order + 1] = day end
                days[day] = lo .. ":" .. hi .. ":" .. n
            end
            for _, x in ipairs(looks) do if math.random() < 0.7 then add(math.floor(x.t / 86400), x.p, x.p, math.random(0, 300)) end end
            for d = 1, math.random(0, 4) do add(math.floor(t / 86400) - 10 - d, base, base, math.random(0, 300)) end
            table.sort(order)
            local parts = {}
            for _, day in ipairs(order) do parts[#parts + 1] = day .. ":" .. days[day] end
            if #parts > 0 then e.d = table.concat(parts, ",") end
        end
        realm[id] = e
    end
    return ids
end

local function makeLadders(ns, ids, now)
    local Pr = ns.Prices
    local with = {}
    for i, id in ipairs(ids) do
        if math.random() < 0.65 then
            local e = Pr.Entry(id)
            local rows, rowCount = {}, math.random(1, 10)
            local named = math.random() < 0.5
            local unit = e and e.p or 200
            for _ = 1, rowCount do
                local u = (math.random() < 0.12) and nil or math.max(1, unit + math.random(-10, 40) * math.random(1, 5))
                rows[#rows + 1] = { u, math.random(1, 20), named and pick({ "Al", "Bo", "Cy", "Tester" }) or nil,
                    math.random() < 0.2 and pick({ true, 1, 3 }) or nil }
            end
            -- A look at the same time as the price entry (deals with depth), or older.
            local at = (e and math.random() < 0.7) and e.t or (now - pick({ 100, 4000, 90000, 200000 }))
            Pr.RecordLadder(id, rows, math.random() < 0.15, at)
            with[#with + 1] = id
        end
    end
    -- Items with a ladder and no price entry at all.
    for id = 5001, 5004 do
        Pr.RecordLadder(id, { { 100, 5, "Al" }, { 140, 3, "Bo" }, { 400, 2, "Al" } }, false, now - 500)
        with[#with + 1] = id
    end
    return with
end

local function makeAuctions(ns, ids, now)
    local key = ns.Gear.CharKey()
    ns.DB().economy[key] = ns.DB().economy[key] or { log = {}, days = {} }
    local list = {}
    for _, id in ipairs(ids) do
        if math.random() < 0.3 then
            for _ = 1, math.random(1, 6) do
                local status = pick({ "sold", "sold", "expired", "cancelled", "listed" })
                local t = now - math.random(1, 40) * 86400
                local a = { id = #list + 1, t = t, name = MOCK.ItemLink(id, "Item " .. id), count = math.random(1, 20),
                    deposit = math.random(1, 80), status = status, buyout = math.random(50, 5000) }
                if status ~= "listed" then
                    a.ended = t + 86400
                    a.closedAt = math.random() < 0.7 and (t + math.random(100, 80000)) or nil
                    if status == "sold" then a.received = math.random(40, 4000) end
                end
                list[#list + 1] = a
            end
        end
    end
    ns.DB().economy[key].auctions = list
end

local function setup()
    function GetItemInfo(id)
        return "Item " .. id, nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132889, 10 + (id % 7) * 9, 7, 5, 0
    end
    local ns = boot(11509)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    return ns
end

---------------------------------------------------------------------------
-- Scenarios
---------------------------------------------------------------------------
scenarios.market_slim_stats = function()
    local ns = setup()
    local M, Pr = ns.Market, ns.Prices
    math.randomseed(20261020)
    local now = time()
    local ids = makeData(ns, 360, now)
    ns.Data.Changed("prices")
    check(M.OUTLIER_FACTOR == OUTLIER_FACTOR and M.OUTLIER_LOOKS == OUTLIER_LOOKS, "outlier constants as the oracle's")

    local withPoints, overs = 0, 0
    for _, id in ipairs(ids) do
        local e = Pr.Entry(id)
        local old = OldBuildStats(ns, e)
        local new = M.Stats(id)
        SameStats(new, old, "stats " .. id)
        if old.over > 0 then overs = overs + 1 end
        -- Points: the decoded, marked looks of the old statistics.
        local pts = M.Points(id)
        check(#pts == #old.points, "points " .. id .. ": count " .. #pts .. " vs " .. #old.points)
        for i, pt in ipairs(pts) do
            local o = old.points[i]
            check(pt.t == o.t and pt.p == o.p and pt.n == o.n and pt.a == o.a and pt.b == o.b and pt.over == o.over
                and pt.c == nil, "points " .. id .. "[" .. i .. "] fields and marks")
        end
        withPoints = withPoints + #pts
        -- A table caller marks the same way.
        local copy = Pr.Looks(e)
        for _, x in ipairs(copy) do x.c, x.b = nil, x.b and true or nil end
        copy[#copy + 1] = { t = e.t, p = e.p, n = e.n, a = e.a, b = e.b and true or nil }
        local usual, base, over = M.MarkOverpriced(copy)
        local ousual, obase, oover = OldMark(old.points)
        check(usual == ousual and base == obase and over == oover, "MarkOverpriced " .. id)
    end
    check(withPoints > 2000 and overs > 40, "the data has looks and outliers: " .. withPoints .. " " .. overs)
    check(M.Points(999999) == nil, "no entry, no points")
    check(M.Stats(999999) == nil, "no entry, no stats")

    -- A look in the same session changes the entry in place: the memo follows.
    local id = ids[1]
    local e = Pr.Entry(id)
    local before = M.Stats(id).p
    e.p = e.p + 7
    local s = M.Stats(id)
    check(s.p == before + 7, "stats follow the entry")
    SameStats(s, OldBuildStats(ns, e), "after an in-place look")
end

scenarios.market_slim_columns = function()
    local ns = setup()
    local Pr = ns.Prices
    -- String and table form give the same columns; a malformed look is skipped as Prices.Looks does.
    local e1 = { h = "100:50:3:2:1:,200:60:::2:1,x:y,300:70:5:1::1,bad,400:80:1:1:1:" }
    local e2 = { h = { { 100, 50, 3, 2, 1 }, { 200, 60, nil, nil, 2, 1 }, { 300, 70, 5, 1, nil, 1 }, { 400, 80, 1, 1, 1 } } }
    local looks = Pr.Looks(e1)
    for _, e in ipairs({ e1, e2 }) do
        local c = Pr.LookColumns(e)
        check(c.count == #looks and c.count == 4, "column count " .. tostring(c.count))
        for i, x in ipairs(looks) do
            check(c.t[i] == x.t and c.p[i] == x.p and c.n[i] == x.n and c.a[i] == x.a and (c.b[i] == true) == (x.b ~= nil),
                "column " .. i)
        end
    end
    -- Reused columns carry nothing over from the item before.
    local into = Pr.LookColumns({ h = "100:50:3:2:1:1,200:60:4:2:1:1,300:70:5:1:1:1" }, {})
    local again = Pr.LookColumns({ h = "100:50:::1:" }, into)
    check(again == into and again.count == 1 and again.n[1] == nil and again.a[1] == nil and again.b[1] == false, "reused columns cleared")
    check(Pr.LookColumns(nil).count == 0 and Pr.LookColumns({}).count == 0, "no looks")
end

scenarios.market_slim_plans = function()
    local ns = setup()
    local M, Pr, Desk = ns.Market, ns.Prices, ns.AuctionDesk
    math.randomseed(777001)
    local now = time()
    local ids = makeData(ns, 360, now)
    local ladderIds = makeLadders(ns, ids, now)
    makeAuctions(ns, ids, now)
    ns.Data.Changed("prices")
    ns.Data.Changed("economy")
    M.InvalidateSales()
    Desk.Invalidate()

    local oldPlans, bests, withSteps, withHolders = {}, 0, 0, 0
    local kinds = {}
    for _, id in ipairs(ladderIds) do
        local e = Pr.Entry(id)
        local stats = e and OldBuildStats(ns, e) or nil
        local old = OldPlan(ns, id, stats)
        oldPlans[id] = old
        local slim, full = Desk.Plan(id), Desk.Detail(id)
        check((slim == nil) == (old == nil) and (full == nil) == (old == nil), "plan exists " .. id)
        if old then
            -- The slim plan keeps only what lists read.
            check(slim.steps == nil and slim.stats == nil and slim.moves == nil and slim.ladder.tiers == nil, "slim plan " .. id .. " keeps no tables")
            check(slim.id == old.id and slim.usual == old.usual and slim.rate == old.rate and slim.age == old.age
                and slim.stale == old.stale and slim.atLeast == old.atLeast, "plan scalars " .. id)
            check(slim.ladder.t == old.ladder.t and slim.ladder.units == old.ladder.units and slim.ladder.auctions == old.ladder.auctions
                and slim.ladder.low == old.ladder.tiers[1].u, "plan ladder summary " .. id)
            SameFields(slim.holders, old.holders, HOLDER_FIELDS, "holders " .. id)
            SameFields(slim.best, old.best, STEP_FIELDS, "best " .. id)
            SameFields(slim.all, old.all, ALL_FIELDS, "all " .. id)
            check(slim.move.key == old.moves.key and slim.move.hex == old.moves.hex and slim.move.label == old.moves.label, "move " .. id)
            local key = M.MoveKey(id)
            check(key == old.moves.key, "MoveKey " .. id)
            kinds[key] = (kinds[key] or 0) + 1
            -- The detail has all of it, and agrees with the slim plan.
            check(full.id == slim.id and full.usual == slim.usual and full.rate == slim.rate and full.age == slim.age
                and full.stale == slim.stale and full.atLeast == slim.atLeast, "detail scalars " .. id)
            check(#full.ladder.tiers == #old.ladder.tiers and full.ladder.units == old.ladder.units and full.ladder.low == slim.ladder.low,
                "detail ladder " .. id)
            for i, t in ipairs(old.ladder.tiers) do
                local x = full.ladder.tiers[i]
                check(x.u == t.u and x.q == t.q and x.m == t.m, "detail tier " .. id .. "[" .. i .. "]")
            end
            check(#full.steps == #old.steps, "detail steps " .. id .. ": " .. #full.steps .. " vs " .. #old.steps)
            for i, st in ipairs(old.steps) do SameFields(full.steps[i], st, STEP_FIELDS, "detail step " .. id .. "[" .. i .. "]") end
            check((full.best == nil) == (old.best == nil), "detail best " .. id)
            if full.best then
                local found
                for _, st in ipairs(full.steps) do if st == full.best then found = true end end
                check(found, "detail best is one of its steps " .. id)
                SameFields(full.best, old.best, STEP_FIELDS, "detail best " .. id)
            end
            SameFields(full.all, old.all, ALL_FIELDS, "detail all " .. id)
            SameFields(full.holders, old.holders, HOLDER_FIELDS, "detail holders " .. id)
            check(full.stats == M.Stats(id) and (old.stats == nil) == (full.stats == nil), "detail stats " .. id)
            check(full.moves.key == old.moves.key and full.moves.source == old.moves.source
                and (full.moves.market == nil) == (old.moves.market == nil), "detail movement " .. id)
            check(full.move.key == full.moves.key, "detail move " .. id)
            if old.best then bests = bests + 1 end
            if #old.steps > 0 then withSteps = withSteps + 1 end
            if old.holders then withHolders = withHolders + 1 end
        end
    end
    check(bests > 20 and withSteps > 40 and withHolders > 20, "the data has resets and sellers: " .. bests .. " " .. withSteps .. " " .. withHolders)
    local nk = 0
    for _ in pairs(kinds) do nk = nk + 1 end
    check(nk >= 3, "several movement verdicts covered: " .. nk)
    check(Desk.Detail(999999) == nil and Desk.Plan(999999) == nil, "no ladder, no plan")

    -- Lists: the same ids in the same order as the old build gave.
    local minProfit = ns.DB().deskMinProfit or 5000
    local opps = Desk.Opportunities()
    local want = {}
    for id in pairs(Pr.AllLadders()) do
        local p = oldPlans[id]
        if p and p.best and p.age <= Desk.OLD and p.best.profit >= minProfit and (p.best.roi or 0) >= Desk.MIN_ROI and p.moves.key ~= "dead" then
            want[#want + 1] = p
        end
    end
    ns.Utils.SortBy(want, function(p) return ns.Utils.NumKey(p.best.profit, true) end)
    check(#opps == #want, "opportunities: " .. #opps .. " vs " .. #want)
    for i, p in ipairs(want) do check(opps[i].id == p.id and opps[i].best.profit == p.best.profit, "opportunity " .. i) end
    check(#opps >= 3 or minProfit > 0, "opportunities exist")

    local N = ns.Utils.NumKey
    local keyOf = {
        profit = function(p) return N(p.best and p.best.profit, true) .. p.name end,
        cost = function(p) return N(p.all.cost) .. p.name end,
        held = function(p) return N(p.holders and p.holders.share or -1, true) .. p.name end,
        name = function(p) return p.name end,
        recent = function(p) return N(p.ladder.t, true) .. p.name end,
    }
    for sort in pairs(keyOf) do
        for _, search in ipairs({ "", "item 10" }) do
            local got = Desk.Markets(sort, search)
            local list = {}
            for id in pairs(Pr.AllLadders()) do
                local name = M.ItemInfo(id)
                if search == "" or name:lower():find(search, 1, true) then
                    local p = oldPlans[id]
                    if p then p.name = name list[#list + 1] = p end
                end
            end
            ns.Utils.SortBy(list, keyOf[sort])
            check(#got == #list, "markets " .. sort .. " '" .. search .. "': " .. #got .. " vs " .. #list)
            for i, p in ipairs(list) do
                check(got[i].id == p.id and got[i].name == p.name, "markets " .. sort .. " order " .. i)
                check(got[i].all.cost == p.all.cost and got[i].ladder.units == p.ladder.units, "markets " .. sort .. " row " .. i)
            end
        end
    end
end

scenarios.market_slim_deals = function()
    local ns = setup()
    local M, Pr, Desk = ns.Market, ns.Prices, ns.AuctionDesk
    math.randomseed(31337)
    local now = time()
    local ids = makeData(ns, 360, now)
    makeLadders(ns, ids, now)
    ns.Data.Changed("prices")
    Desk.Invalidate()

    -- The old Market.Deals and Desk.BuildDeals over the old statistics (ties keep the order they came in).
    local order = {}
    for id in pairs(Pr.All()) do order[#order + 1] = id end
    local list = {}
    for _, id in ipairs(order) do
        local s = OldBuildStats(ns, Pr.Entry(id))
        local usual = s.usualBefore
        if usual and s.looks >= M.DEAL_LOOKS and s.p <= usual * M.DEAL_FACTOR then
            local gain = M.Net(usual) - s.p
            if gain > 0 then list[#list + 1] = { id = id, s = s, gain = gain, usual = usual } end
        end
    end
    ns.Utils.SortBy(list, function(d) return ns.Utils.NumKey(d.gain / math.max(1, d.s.p) * 1e6, true) end)
    local deals = M.Deals()
    check(#deals == #list and #list > 20, "market deals: " .. #deals .. " vs " .. #list)
    for i, d in ipairs(list) do
        check(deals[i].id == d.id and deals[i].gain == d.gain and deals[i].usual == d.usual and deals[i].s.p == d.s.p, "market deal " .. i)
    end

    local depth = 0
    for _, d in ipairs(list) do
        local L = Pr.Ladder(d.id)
        if L and math.abs(L.t - d.s.t) <= 600 then
            local limit = d.usual * M.DEAL_FACTOR
            local net = M.Net(d.usual)
            local units, cost, gain = 0, 0, 0
            for _, t in ipairs(L.tiers) do
                if t.u > limit then break end
                local q = t.q - t.m
                units, cost, gain = units + q, cost + q * t.u, gain + q * (net - t.u)
            end
            d.units, d.cost, d.totalGain = units, cost, gain - Desk.Deposit(d.id, units)
            depth = depth + 1
        end
    end
    for i, d in ipairs(list) do d.at = i end
    table.sort(list, function(a, b)
        local ga, gb = a.totalGain or a.gain, b.totalGain or b.gain
        if ga ~= gb then return ga > gb end
        return a.at < b.at
    end)
    local got = Desk.Deals()
    check(#got == #list, "desk deals: " .. #got .. " vs " .. #list)
    check(depth > 5, "some deals have depth: " .. depth)
    for i, d in ipairs(list) do
        check(got[i].id == d.id and got[i].units == d.units and got[i].cost == d.cost and got[i].totalGain == d.totalGain
            and got[i].gain == d.gain, "desk deal " .. i .. " " .. d.id .. " vs " .. tostring(got[i].id))
    end
end
