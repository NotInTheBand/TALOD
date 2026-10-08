-- TALOD - Auction desk: the numbers behind /talod ah. Built on the price
-- ladders Prices.lua keeps (every buyout of an item at one look):
--
--   * Buyout cost: what buying every unit up to a price costs.
--   * Control plans ("resets"): buy the cheapest tiers, relist everything
--     1c under the next seller's price. For each step: units, cost,
--     deposit, what the relist brings after the cut (times your sell rate
--     for the item once known) and the profit. Buying it all = owning the
--     market: its cost, and the relist at the usual / highest price.
--   * Who holds the supply (top seller's share) when the look named sellers.
--   * Your listings (the game's own list, else Economy's auction log)
--     against the ladder: lowest, or how many units sit under yours.
--   * Deals with depth: how many units are listed under the deal price and
--     what buying them all would gain.
--
-- Only what you saw: a ladder is one look, its age is shown everywhere, a
-- partial look gives "at least" costs, unknown sellers stay unknown.
-- Nothing here buys, posts or searches: the desk advises, you click.

local ADDON_NAME, ns = ...
local Market, Prices = ns.Market, ns.Prices

local Desk = {}
ns.AuctionDesk = Desk

Desk.FRESH = 3600              -- an older ladder: "look again before buying"
Desk.OLD = 2 * 86400           -- an older ladder is left out of the opportunity list
Desk.MIN_ROI = 0.15            -- a reset worth showing makes 15% on the money put in
Desk.CONTROL_SHARE = 0.5       -- one seller with half the units "holds" the item
-- [VERIFY] Deposit share of the vendor price when you have posted nothing
-- yet (vanilla faction AH, medium duration). Your own posts replace it.
Desk.DEPOSIT_FALLBACK = 0.15
local LISTING_MAX_AGE = 48 * 3600

local function db() return ns.DB() end
local function Money(c) return ns.Professions.Money(c) end

-- "-1g 20s" for losses (Professions.Money only does amounts).
function Desk.Signed(c)
    if not c then return "?" end
    return (c < 0 and "-" or "+") .. Money(math.abs(c))
end

local function LinkID(link) return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil end

---------------------------------------------------------------------------
-- Deposits: learned from your own posts (Economy's auction log)
---------------------------------------------------------------------------
-- Deposit as a share of the vendor price, the median of your posts with a
-- known deposit (all characters). Returns rate, posts it is based on. Kept
-- until the economy data changes (every plan asks).
function Desk.DepositRate()
    local v = ns.Data.Memo("desk:deposit", ns.Data.Key("economy"), Desk.BuildDepositRate)
    return v[1], v[2]
end

function Desk.BuildDepositRate()
    local ratios = {}
    for _, c in pairs(db().economy or {}) do
        for _, a in ipairs(c.auctions or {}) do
            local id = LinkID(a.name)
            if id and type(a.deposit) == "number" and a.deposit > 0 then
                local _, _, _, sell = Market.ItemInfo(id)
                if type(sell) == "number" and sell > 0 then ratios[#ratios + 1] = a.deposit / (sell * (a.count or 1)) end
            end
        end
    end
    table.sort(ratios)
    local rate = #ratios > 0 and ratios[math.floor((#ratios + 1) / 2)] or Desk.DEPOSIT_FALLBACK
    return { rate, #ratios }
end

-- Deposit for posting `units` of an item (copper; 0 without a vendor price).
function Desk.Deposit(id, units)
    local _, _, _, sell = Market.ItemInfo(id)
    if type(sell) ~= "number" or sell <= 0 then return 0 end
    return math.floor(sell * (units or 1) * Desk.DepositRate() + 0.5)
end

---------------------------------------------------------------------------
-- Ladders
---------------------------------------------------------------------------
-- The usual price from looks before the latest (today's price must not set
-- the yardstick it is measured with); nil with a single look.
function Desk.Usual(id)
    local s = Market.Stats(id)
    if not s or s.looks < 2 then return nil, s end
    return s.usualBefore, s
end

-- Buying every unit (not yours) priced up to `maxUnit`: cost, units.
function Desk.BuyoutCost(ladder, maxUnit)
    local cost, units = 0, 0
    for _, t in ipairs(ladder and ladder.tiers or {}) do
        if maxUnit and t.u > maxUnit then break end
        local q = t.q - t.m
        cost, units = cost + q * t.u, units + q
    end
    return cost, units
end

-- Who holds the supply: share (0-1) of the top seller, name, sellers, mine.
function Desk.Holders(ladder)
    if not ladder or not ladder.top then return nil end
    local total = ladder.units + ladder.bidOnly
    if total <= 0 then return nil end
    local me = Prices.PlayerName()
    return { share = ladder.top / total, name = ladder.topName, sellers = ladder.sellers, mine = ladder.topName ~= nil and ladder.topName == me }
end

-- Plans and lists read prices, ladders and your auctions: kept until one
-- changes (Data.lua), or their age runs out (below).
local SOURCES = { "prices", "economy" }
-- base: Data.Key(SOURCES) when the caller already has it (a walk over every
-- ladder asks for thousands of plans: the key is read once, not per plan).
-- maxAge: LIST_AGE by default. Lists filter on ages (FRESH an hour, OLD two
-- days): a few minutes late is nothing, and an open desk does not rebuild
-- them every minute.
local LIST_AGE = 300
local function Kept(name, extra, build, base, maxAge)
    return ns.Data.Memo("desk:" .. name, (base or ns.Data.Key(SOURCES)) .. "|" .. tostring(extra), build, maxAge or LIST_AGE)
end

-- A plan's numbers change only with prices and your auctions; its age moves
-- with the clock and is refreshed on each read. Rebuilding every plan each
-- minute for the age alone was thousands of plans a minute while the desk
-- was open. The sell rate drifts over days: PLAN_AGE bounds that.
local PLAN_AGE = 1800

-- The control plan for one item, or nil without a ladder. {
--   id, ladder, stats, usual, rate (your sell rate or nil), age, stale,
--   atLeast (some auctions not seen: costs are lower bounds), holders,
--   steps = { { k, upTo, units, cost, relist, deposit, revenue, profit, roi, overUsual,
--     over (the relist is an overpriced price: never the best) } },
--   best (the step with the highest profit, if any makes money),
--   all = { units, cost, relist, deposit, revenue, profit, roi },
-- }
function Desk.Plan(id, base)
    local plan = Kept("plan:" .. tostring(id), "", function() return Desk.BuildPlan(id) end, base, PLAN_AGE)
    if plan then
        plan.age = time() - plan.ladder.t
        plan.stale = plan.age > Desk.FRESH
    end
    return plan
end

function Desk.BuildPlan(id)
    local L = Prices.Ladder(id)
    local plan
    if L and #L.tiers > 0 then
        local usual, stats = Desk.Usual(id)
        local sales = Market.MySales(id)
        local rate = sales.rate
        local cut = 1 - Market.CUT
        plan = { id = id, ladder = L, stats = stats, usual = usual, rate = rate, age = time() - L.t,
            atLeast = L.partial or L.more > 0, holders = Desk.Holders(L), steps = {}, moves = Market.Movement(id) }
        plan.stale = plan.age > Desk.FRESH
        local cost, units = 0, 0
        for k, t in ipairs(L.tiers) do
            local q = t.q - t.m
            cost, units = cost + q * t.u, units + q
            -- The next seller's price is the wall you relist under.
            local wall
            for j = k + 1, #L.tiers do
                if L.tiers[j].q - L.tiers[j].m > 0 then wall = L.tiers[j].u break end
            end
            -- A tier of only your units adds nothing to buy: no step of its own.
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
        -- Everything: relist at the usual price or the highest listed, whichever is more.
        -- Tiers overpriced against the usual (Market.OUTLIER_FACTOR) are not a price
        -- anyone pays: the relist stops under them.
        local top = 0
        for _, t in ipairs(L.tiers) do
            if not (usual and t.u > usual * Market.OUTLIER_FACTOR) then top = t.u end
        end
        local relist = math.max(math.floor(usual or 0), top)
        local deposit = Desk.Deposit(id, units)
        local revenue = math.floor(math.floor(relist * cut) * units * (rate or 1))
        plan.all = { units = units, cost = cost, relist = relist, deposit = deposit, revenue = revenue,
            profit = revenue - cost - deposit, roi = cost > 0 and (revenue - cost - deposit) / cost or nil }
    end
    return plan
end

-- For writes that bypass Prices / Economy (tests): rebuilt on the next read.
function Desk.Invalidate() ns.Data.Forget("desk:") end

-- Resets worth a look: best step profit >= the setting and ROI >= MIN_ROI,
-- ladders under OLD, and not an item that doesn't sell (relisting it all
-- would only sit); most profit first. Soulbound items never show (they are
-- not on the AH).
function Desk.Opportunities()
    return Kept("opportunities", db().deskMinProfit, Desk.BuildOpportunities)
end

function Desk.BuildOpportunities()
    local out = {}
    local minProfit = db().deskMinProfit or 5000
    local base = ns.Data.Key(SOURCES)
    for id in pairs(Prices.AllLadders()) do
        local plan = Desk.Plan(id, base)
        local best = plan and plan.best
        if best and plan.age <= Desk.OLD and best.profit >= minProfit and (best.roi or 0) >= Desk.MIN_ROI
            and plan.moves.key ~= "dead" then
            out[#out + 1] = plan
        end
    end
    ns.Utils.SortBy(out, function(p) return ns.Utils.NumKey(p.best.profit, true) end)
    return out
end

-- Every item with a ladder, for the Control tab: { plan } sorted by `sort`
-- ("profit", "cost" = cheapest to own, "held" = most concentrated, "name").
function Desk.Markets(sort, search)
    return Kept("markets", tostring(sort) .. "|" .. tostring(search), function() return Desk.BuildMarkets(sort, search) end)
end

function Desk.BuildMarkets(sort, search)
    local out = {}
    local base = ns.Data.Key(SOURCES)
    for id in pairs(Prices.AllLadders()) do
        local name = Market.ItemInfo(id)
        if not search or search == "" or name:lower():find(search, 1, true) then
            local plan = Desk.Plan(id, base)
            if plan then
                plan.name = name
                out[#out + 1] = plan
            end
        end
    end
    local N = ns.Utils.NumKey
    local keyOf = {
        profit = function(p) return N(p.best and p.best.profit, true) .. p.name end,
        cost = function(p) return N(p.all.cost) .. p.name end,
        held = function(p) return N(p.holders and p.holders.share or -1, true) .. p.name end,
        name = function(p) return p.name end,
        recent = function(p) return N(p.ladder.t, true) .. p.name end,
    }
    return ns.Utils.SortBy(out, keyOf[sort] or keyOf.profit)
end

---------------------------------------------------------------------------
-- Deals with depth
---------------------------------------------------------------------------
-- Market.Deals plus, when the ladder is from the same look: units listed
-- at or under the deal price (DEAL_FACTOR x usual) and their total gain.
function Desk.Deals()
    return Kept("deals", "", Desk.BuildDeals)
end

function Desk.BuildDeals()
    local out = {}
    for _, d in ipairs(Market.Deals()) do
        local L = Prices.Ladder(d.id)
        if L and math.abs(L.t - d.s.t) <= 600 then
            local limit = d.usual * Market.DEAL_FACTOR
            local net = Market.Net(d.usual)
            local units, cost, gain = 0, 0, 0
            for _, t in ipairs(L.tiers) do
                if t.u > limit then break end
                local q = t.q - t.m
                units, cost, gain = units + q, cost + q * t.u, gain + q * (net - t.u)
            end
            d.units, d.cost, d.totalGain = units, cost, gain - Desk.Deposit(d.id, units)
        end
        out[#out + 1] = d
    end
    table.sort(out, function(a, b)
        local ga, gb = a.totalGain or a.gain, b.totalGain or b.gain
        return ga > gb
    end)
    return out
end

---------------------------------------------------------------------------
-- Your listings
---------------------------------------------------------------------------
-- Where your listing of `unit` copper each stands: { state = "lowest" /
-- "undercut" / "unknown", ahead (units cheaper, not yours; nil unknown),
-- lowest (cheapest other price), repost (1c under it), age }.
function Desk.Standing(id, unit)
    if not unit then return { state = "unknown" } end
    local L = Prices.Ladder(id)
    if L and #L.tiers > 0 then
        local ahead, lowest = 0, nil
        for _, t in ipairs(L.tiers) do
            local q = t.q - t.m
            if q > 0 and not lowest then lowest = t.u end
            if t.u < unit then ahead = ahead + q end
        end
        local out = { ahead = ahead, lowest = lowest, age = time() - L.t, partial = L.partial }
        out.state = ahead > 0 and "undercut" or "lowest"
        if lowest and lowest <= unit then out.repost = math.max(1, lowest - 1) end
        return out
    end
    local e = Prices.Entry(id)
    if not e then return { state = "unknown" } end
    -- Without a ladder the lowest price may be your own auction.
    if e.p < unit then return { state = "undercut", lowest = e.p, repost = math.max(1, e.p - 1), age = time() - e.t } end
    return { state = e.p == unit and "unknown" or "lowest", lowest = e.p, age = time() - e.t }
end

local function DurationSeconds(text)
    local h = type(text) == "string" and tonumber(text:match("^(%d+)")) or nil
    return h and h * 3600 or nil
end

-- This character's active listings: { source = "game" / "log", t (when
-- the game showed them), list = { { id, name, count, unit, left, endsAt,
-- deposit (paid, from your posting log), depositGuess (no logged post: from
-- your deposit rate), overdue, standing, value (after the cut) } } }.
function Desk.Listings()
    local out = { list = {} }
    local live = Prices.Owned()
    if live and time() - live.t < LISTING_MAX_AGE then
        out.source, out.t = "game", live.t
        -- The game's list has no deposit: take it from the posting log, one
        -- logged post (same item and count, newest first) per live auction.
        -- No match: depositGuess from your learned deposit rate, kept apart.
        local posts = {}
        local c = ns.Economy and ns.Economy.Char and ns.Economy.Char()
        for _, a in ipairs(c and c.auctions or {}) do
            local id = a.status == "listed" and type(a.deposit) == "number" and LinkID(a.name)
            if id then
                local k = id .. ":" .. (a.count or 1)
                posts[k] = posts[k] or {}
                table.insert(posts[k], 1, a.deposit)
            end
        end
        for _, a in ipairs(live.list or {}) do
            if not a.sold then
                local queue = a.id and posts[a.id .. ":" .. (a.count or 1)]
                local e = { id = a.id, name = a.name, count = a.count, unit = a.unit, left = a.left,
                    seenAt = live.t, deposit = queue and table.remove(queue, 1) or nil }
                if not e.deposit and e.id then
                    local guess = Desk.Deposit(e.id, e.count)
                    e.depositGuess = guess > 0 and guess or nil
                end
                out.list[#out.list + 1] = e
            end
        end
    else
        out.source = "log"
        local c = ns.Economy and ns.Economy.Char and ns.Economy.Char()
        for _, a in ipairs(c and c.auctions or {}) do
            if a.status == "listed" then
                local id = LinkID(a.name)
                local count = a.count or 1
                local secs = DurationSeconds(a.duration)
                local e = { id = id, name = type(a.name) == "string" and (a.name:match("|h%[(.-)%]|h") or a.name) or "?",
                    count = count, unit = (a.buyout and a.buyout > 0) and math.floor(a.buyout / count + 0.5) or nil,
                    deposit = a.deposit, endsAt = secs and (a.t + secs) or nil }
                e.overdue = e.endsAt and time() > e.endsAt or false
                out.list[#out.list + 1] = e
            end
        end
    end
    for _, e in ipairs(out.list) do
        e.standing = e.id and Desk.Standing(e.id, e.unit) or { state = "unknown" }
        e.value = e.unit and Market.Net(e.unit) * e.count or nil
        if e.id and not e.name then e.name = Market.ItemInfo(e.id) end
    end
    local ORDER = { undercut = 1, unknown = 2, lowest = 3 }
    table.sort(out.list, function(a, b)
        if a.overdue ~= b.overdue then return not a.overdue end
        local oa, ob = ORDER[a.standing.state], ORDER[b.standing.state]
        if oa ~= ob then return oa < ob end
        return (a.value or 0) > (b.value or 0)
    end)
    return out
end

---------------------------------------------------------------------------
-- Not worth posting: what you posted that does not sell
---------------------------------------------------------------------------
-- Items whose movement (your auctions first) is "dead" or "slow", with the
-- deposits they cost you: { id, name, moves, sales }, dead first.
function Desk.NotWorthIt()
    return Kept("notworthit", "", Desk.BuildNotWorthIt)
end

function Desk.BuildNotWorthIt()
    local out = {}
    for _, e in ipairs(Market.SellThroughList()) do
        if e.id then
            local mv = Market.Movement(e.id)
            if mv.key == "dead" or mv.key == "slow" then out[#out + 1] = { id = e.id, name = e.name, moves = mv, sales = e.sales } end
        end
    end
    table.sort(out, function(a, b)
        if a.moves.key ~= b.moves.key then return a.moves.key == "dead" end
        return a.sales.depositLost > b.sales.depositLost
    end)
    return out
end

---------------------------------------------------------------------------
-- Overview numbers
---------------------------------------------------------------------------
function Desk.Summary()
    local listings = Desk.Listings()
    local value, undercut, overdue = 0, 0, 0
    for _, e in ipairs(listings.list) do
        if not e.overdue then
            value = value + (e.value or 0)
            if e.standing.state == "undercut" then undercut = undercut + 1 end
        else
            overdue = overdue + 1
        end
    end
    local ladders, newest = 0, nil
    for _, e in pairs(Prices.AllLadders()) do
        ladders = ladders + 1
        if type(e.t) == "number" and (not newest or e.t > newest) then newest = e.t end
    end
    local items = Prices.Count()
    return { listings = listings, listed = #listings.list - overdue, value = value, undercut = undercut, overdue = overdue,
        ladders = ladders, ladderNewest = newest, items = items }
end

---------------------------------------------------------------------------
-- Slash: /talod ah [item], /talod desk
---------------------------------------------------------------------------
local function Slash(command, rest)
    if command ~= "ah" then return false end
    rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if rest == "" then
        if ns.AuctionDeskUI then ns.AuctionDeskUI.Toggle() end
        return true
    end
    -- An item: its control plan in chat, and the Control tab on it.
    local needle, found = rest:lower(), nil
    for id in pairs(Prices.AllLadders()) do
        local name = Market.ItemInfo(id)
        if name:lower() == needle then found = id break end
        if not found and name:lower():find(needle, 1, true) then found = id end
    end
    if not found then
        ns.Print("\"" .. rest .. "\": no full look at its auctions yet (search it on the Auction House, or a full scan).")
        return true
    end
    local plan = Desk.Plan(found)
    local L = plan.ladder
    ns.Print(string.format("%s: %d units in %d auctions, %s ago.", Market.ItemText(found), L.units, L.auctions or 0, Prices.Age(L.t)))
    print(string.format("  Buy them all: %s%s (%d units), relist at %s: %s.", plan.atLeast and "at least " or "", Money(plan.all.cost),
        plan.all.units, Money(plan.all.relist), Desk.Signed(plan.all.profit)))
    if plan.best then
        print(string.format("  Best reset: buy up to %s (%d units, %s), relist at %s: %s.", Money(plan.best.upTo), plan.best.units,
            Money(plan.best.cost), Money(plan.best.relist), Desk.Signed(plan.best.profit)))
    end
    if ns.AuctionDeskUI then ns.AuctionDeskUI.Show("control", found) end
    return true
end

ns.RegisterModule("AuctionDesk", {
    defaults = { deskMinProfit = 5000 },
    slash = Slash,
})
