-- TALOD - Auction desk: the numbers behind /talod ah. Built on the price
-- ladders Prices.lua keeps (every buyout of an item at one look):
--
--   * Buyout cost: what buying every unit up to a price costs.
--   * Control plans ("resets"): buy the cheapest tiers, relist everything
--     1c under the next seller's auction (its whole stack). For each step: units, cost,
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
-- A listing period at its longest (48 h): what the market takes in one, at most.
Desk.DEMAND_DAYS = 2
Desk.CONTROL_SHARE = 0.5       -- one seller with half the units "holds" the item
-- [VERIFY] Deposit share of the vendor price when you have posted nothing
-- yet (vanilla faction AH, medium duration). Your own posts replace it.
Desk.DEPOSIT_FALLBACK = 0.15
local LISTING_MAX_AGE = 48 * 3600
-- The legacy owner list's time-left bands (Prices.lua): the longest each can
-- run (over 8 h: a Classic auction lasts at most 24 h).
local LEGACY_LEFT_MAX = { ["under 30 min"] = 1800, ["30 min - 2 h"] = 7200, ["2 - 8 h"] = 28800, ["over 8 h"] = 86400 }

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
-- The game's deposit scales with the auction's duration (12 / 24 / 48 h on
-- the modern house): one median over posts of every duration can be 4x off.
-- So the rate is learned per hour of duration where the post says its
-- duration, and a plan assumes your usual duration (the median of your posts).
-- Returns the deposit share of the vendor price for a post of your usual
-- duration, the posts it is based on, the share per hour (nil: no post with a
-- duration), your usual hours (nil: unknown), and whether your posts used
-- more than one duration. Kept until the economy data changes (every plan asks).
function Desk.DepositRate()
    local v = ns.Data.Memo("desk:deposit", ns.Data.Key("economy"), Desk.BuildDepositRate)
    return v[1], v[2], v[3], v[4], v[5]
end

local function DurationHours(text)
    local h = type(text) == "string" and tonumber(text:match("^(%d+)")) or nil
    return (h and h > 0) and h or nil
end

function Desk.BuildDepositRate()
    local ratios, perHour, hours, kinds, nKinds = {}, {}, {}, {}, 0
    for _, c in pairs(db().economy or {}) do
        for _, a in ipairs(c.auctions or {}) do
            local id = LinkID(a.name)
            if id and type(a.deposit) == "number" and a.deposit > 0 then
                local _, _, _, sell = Market.ItemInfo(id)
                if type(sell) == "number" and sell > 0 then
                    local r = a.deposit / (sell * (a.count or 1))
                    ratios[#ratios + 1] = r
                    local h = DurationHours(a.duration)
                    if h then
                        perHour[#perHour + 1] = r / h
                        hours[#hours + 1] = h
                        if not kinds[h] then kinds[h], nKinds = true, nKinds + 1 end
                    end
                end
            end
        end
    end
    local function Mid(list)
        table.sort(list)
        return #list > 0 and list[math.floor((#list + 1) / 2)] or nil
    end
    local hourly, usualHours = Mid(perHour), Mid(hours)
    local rate = (hourly and usualHours) and hourly * usualHours or Mid(ratios) or Desk.DEPOSIT_FALLBACK
    return { rate, #ratios, hourly, usualHours, nKinds > 1 }
end

-- Deposit for posting `units` of an item (copper), nil without a vendor
-- price: the deposit is a share of it, and an unknown is never 0. hours: the
-- auction's duration; nil = your usual duration (a plan's assumption).
-- [VERIFY] the modern auction house charges at least 1 silver per auction;
-- not modelled until checked on Forever.
function Desk.Deposit(id, units, hours)
    local _, _, _, sell = Market.ItemInfo(id)
    if type(sell) ~= "number" or sell <= 0 then return nil end
    local rate, _, hourly = Desk.DepositRate()
    if hours and hourly then rate = hourly * hours end
    return math.floor(sell * (units or 1) * rate + 0.5)
end

-- One unit's share of a post's deposit, not rounded (nil without a vendor
-- price): a per-unit value multiplied by the units must not carry a
-- whole-copper rounding per unit (3c vendor: 0.45c, not 0; 10c: 1.5c, not 2).
function Desk.DepositUnit(id)
    local _, _, _, sell = Market.ItemInfo(id)
    if type(sell) ~= "number" or sell <= 0 then return nil end
    return sell * Desk.DepositRate()
end

-- What posting `units` once is worth, with sell rate r (nil: unknown):
-- r x units x net + (1 - r) x (units x vendor - deposit). Sold units refund
-- the deposit; unsold ones come back, worth the vendor price, and the deposit
-- is lost (so that outcome is below 0 when the deposit is over the vendor
-- value). Returns the expected value (nil when r or the deposit is unknown)
-- and the value if every unit sells (deposits refunded). netUnit is not
-- rounded (Market.Net): the total is, once.
function Desk.PostValue(netUnit, units, r, vendorUnit, deposit)
    if not netUnit then return nil, nil end
    local ifAll = math.floor(netUnit * units + 1e-6)
    if not r or not deposit then return nil, ifAll end
    local back = (vendorUnit or 0) * units - deposit
    return math.floor(r * ifAll + (1 - r) * back), ifAll
end

---------------------------------------------------------------------------
-- Ladders
---------------------------------------------------------------------------
-- The usual price from looks before the latest (today's price must not set
-- the yardstick it is measured with); nil with a single look.
function Desk.Usual(id)
    local s = Market.Stats(id)
    if not s or s.looks < 2 or s.usualBeforeStale then return nil, s end
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

-- What a walk over every ladder reads once, not per plan: your auctions
-- indexed by item and the deposit rate.
function Desk.Context()
    return { index = Market.SalesIndex(), depositRate = Desk.DepositRate() }
end

-- The control plan of one item for lists, or nil without a ladder. Lists hold
-- thousands, so it keeps only what rows and the verdict read: {
--   id, usual, rate (your sell rate or nil), age, stale,
--   atLeast (some auctions not seen: costs are lower bounds), holders,
--   ladder = { t, low (the cheapest tier's price), units, auctions },
--   move = { key, hex, label } (does it sell: Market.MoveKey),
--   best (the reset step with the highest profit, if any makes money; see Detail),
--   all = { units, cost, relist, deposit, revenue, profit, roi },
-- }
-- base / ctx: Data.Key(SOURCES) and Desk.Context() when the caller walks
-- many items.
-- Every plan lives in one map kept like a memo (same key and age): a memo
-- record and name per item was more than a megabyte over thousands of
-- ladders. The map is this file's own cache: plans are added as asked for.
function Desk.Plan(id, base, ctx)
    ns.Data.Step()      -- a walk over every ladder pauses here, as it did at each memo
    local map = Kept("plans", "", function() return {} end, base, PLAN_AGE)
    local plan = map[id]
    if plan == nil then
        plan = Desk.BuildPlan(id, false, ctx) or false
        map[id] = plan
    end
    plan = plan or nil
    if plan then
        plan.age = time() - plan.ladder.t
        plan.stale = plan.age > Desk.FRESH
    end
    return plan
end

-- The whole plan of one item (the Control tab's detail, tooltips, the report):
-- the slim plan's fields plus ladder.tiers ({ u, q, m } cheapest first, and
-- the ladder's sellers / mine / partial / bidOnly / more), steps (every
-- reset: { k, upTo, units, cost, relist, deposit, revenue, profit, roi,
-- overUsual, over (the relist is an overpriced price: never the best) }; best
-- is one of them), stats (Market.Stats) and moves (Market.Movement).
function Desk.Detail(id, base)
    -- Eight slots by item id, the id in the key: a full plan holds every tier
    -- and step, and hovering list rows for a session must not keep one per item.
    local slot = (tonumber(id) or 0) % 8
    local plan = Kept("detail:" .. slot, tostring(id), function() return Desk.BuildPlan(id, true) end, base, PLAN_AGE)
    if plan then
        plan.age = time() - plan.ladder.t
        plan.stale = plan.age > Desk.FRESH
    end
    return plan
end

-- Desk.Deposit with the vendor price and the rate already read (a plan asks for each step).
local function DepositFor(sell, units, rate)
    if type(sell) ~= "number" or sell <= 0 then return nil end
    return math.floor(sell * units * rate + 0.5)
end

local ladderCols = { u = {}, q = {}, m = {} }
local walls, wallK = {}, {}

function Desk.BuildPlan(id, full, ctx)
    -- Anything that can pause the build (a memo read) comes before the shared
    -- columns are filled.
    ctx = ctx or Desk.Context()
    local stats = Market.Stats(id)
    -- A usual price only from recent days: one from months-old looks would
    -- value the relist at a price the market left long ago.
    local usualOld = stats and stats.looks >= 2 and stats.usualBefore and stats.usualBeforeStale or nil
    local usual = (stats and stats.looks >= 2 and not usualOld) and stats.usualBefore or nil
    local _, _, rate = Market.SaleCounts(id, ctx.index)
    -- How many units one listing period can take (Market.Demand, per day, over
    -- the longest auction): a reset relists everything at once, and the sell
    -- rate of your single auctions says nothing about 500 units in one go.
    local demand = Market.Demand(id, ctx.index)
    local demandCap = demand and demand * Desk.DEMAND_DAYS or nil
    local moves, brief
    if full then
        moves = Market.Movement(id)
        brief = Market.MOVE_BRIEF[moves.key]
    else
        brief = Market.MOVE_BRIEF[(Market.MoveKey(id, ctx.index))]
    end
    local _, _, _, sell = Market.ItemInfo(id)
    local depositRate = ctx.depositRate

    local c = Prices.LadderColumns(id, ladderCols)
    if not c or c.count == 0 then return nil end
    local n, U, Q, M = c.count, c.u, c.q, c.m
    local cut = 1 - Market.CUT
    local plan = { id = id, usual = usual, usualOld = usualOld, rate = rate, demand = demand, age = time() - c.t, atLeast = c.partial or c.more > 0,
        holders = Desk.Holders(c), move = brief,
        ladder = { t = c.t, low = U[1], units = c.units, auctions = c.auctions } }
    plan.stale = plan.age > Desk.FRESH
    if full then
        local L = Prices.Ladder(id)
        L.low = U[1]
        plan.ladder, plan.stats, plan.moves, plan.steps = L, stats, moves, {}
    end
    -- The next seller's price is the wall you relist under: the nearest dearer
    -- tier with units that are not yours.
    -- Undercut it as it can be posted (Market.Undercut, as Listings' repost):
    -- 1c under the wall's whole stack, 1c a unit only for a commodity or an
    -- unknown stack size.
    local nextWall, nextK
    local K = c.k or {}
    for k = n, 1, -1 do
        walls[k], wallK[k] = nextWall, nextK
        if Q[k] - M[k] > 0 then nextWall, nextK = U[k], K[k] or nil end
    end
    local factor = Market.OUTLIER_FACTOR
    -- Every amount below is valued at min(relist, usual): listing above the
    -- usual price is upside, not the expected result (nobody is shown to have
    -- paid it). Without a usual price (under 4 looks) there is no yardstick:
    -- no profit at all, never the highest listing taken at its word.
    local cost, units, best = 0, 0, nil
    for k = 1, n do
        local q = Q[k] - M[k]
        cost, units = cost + q * U[k], units + q
        local wall = walls[k]
        local relist = wall and Market.Undercut(wall, wallK[k])
        -- A tier of only your units adds nothing to buy: no step of its own.
        if wall and q > 0 and relist > U[k] + 1e-6 then
            local deposit = DepositFor(sell, units, depositRate)
            local value = usual and math.min(relist, usual) or nil
            local netUnit = value and value * cut or nil
            local revenue, ifAll = Desk.PostValue(netUnit, units, rate, sell, deposit)
            local profit = revenue and revenue - cost or nil
            local over = usual and relist > usual * factor or nil
            local roi = (profit and cost + (deposit or 0) > 0) and profit / (cost + (deposit or 0)) or nil
            -- More units than the market has shown it takes in one listing (or
            -- that is unknown): the expected profit assumes they sell at your
            -- auctions' rate, which nothing supports. Never the best step.
            local overDemand = not demandCap or units > demandCap
            -- The best reset among the steps worth doing (ROI at least MIN_ROI):
            -- the most profit alone would pick a step that only adds capital at
            -- a poor return, and then fail the ROI test that a cheaper step passes.
            local better = profit and profit > 0 and not over and not overDemand and (roi or 0) >= Desk.MIN_ROI
                and (not best or profit > best.profit)
            -- Without your sell rate: the best step if it all sold, for display only
            -- (never an opportunity, never called expected).
            local betterIfAll = not profit and ifAll and ifAll - cost > 0 and not over
                and (not plan.bestIfAll or ifAll - cost > plan.bestIfAll.ifAll)
            if full or better or betterIfAll then
                local step = { k = k, upTo = U[k], units = units, cost = cost, relist = relist, relistK = wallK[k], value = value, deposit = deposit,
                    revenue = revenue, profit = profit, ifAll = ifAll and ifAll - cost or nil,
                    -- Capital at risk: what you pay for the units and the deposits up front.
                    roi = roi,
                    overUsual = usual and usual > 0 and (relist - usual) / usual or nil, over = over, overDemand = overDemand or nil }
                if full then plan.steps[#plan.steps + 1] = step end
                if better then best = step end
                if betterIfAll then plan.bestIfAll = step end
            end
        end
    end
    plan.best = best
    -- Everything, relisted at the usual price.
    local deposit = DepositFor(sell, units, depositRate)
    local netUnit = usual and usual * cut or nil
    local revenue, ifAll = Desk.PostValue(netUnit, units, rate, sell, deposit)
    local profit = revenue and revenue - cost or nil
    plan.all = { units = units, cost = cost, relist = usual, deposit = deposit, revenue = revenue,
        overDemand = (not demandCap or units > demandCap) or nil,
        profit = profit, ifAll = ifAll and ifAll - cost or nil,
        roi = (profit and cost + (deposit or 0) > 0) and profit / (cost + (deposit or 0)) or nil }
    return plan
end

-- Why a step has no expected profit, naming the input that is missing: your
-- sell rate, the deposit (no vendor price known yet) or the usual price.
function Desk.MissingText(plan, step)
    if not plan.rate then
        return string.format("no sell rate of yours yet (%d ended auctions)", Market.SELL_MIN_ENDED)
    end
    if not plan.usual and plan.usualOld then return "the usual price is from old looks only (look at it again for a few days)" end
    if not plan.usual then return "no usual price yet (too few looks)" end
    if step and not step.deposit then return "the deposit is unknown (no vendor price for it yet)" end
    return "not enough data"
end

-- For writes that bypass Prices / Economy (tests): rebuilt on the next read.
function Desk.Invalidate() ns.Data.Forget("desk:") end

-- The item IDs with a ladder, in `pairs` order, collected first so a walk can
-- pause between items (a paused `pairs` over saved data breaks on new keys).
local function LadderIDs()
    local ids = {}
    for id in pairs(Prices.AllLadders()) do ids[#ids + 1] = id end
    return ids
end

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
    local base, ctx = ns.Data.Key(SOURCES), Desk.Context()
    for _, id in ipairs(LadderIDs()) do
        local plan = Desk.Plan(id, base, ctx)
        local best = plan and plan.best
        -- Only on evidence: a usual price, your own sell rate (the expected
        -- profit needs it), every auction seen (a partial ladder hides supply,
        -- so its profit is at most), a recent ladder, and an item that sells.
        if best and plan.rate and plan.usual and not plan.atLeast and plan.age <= Desk.OLD and best.profit >= minProfit
            and (best.roi or 0) >= Desk.MIN_ROI and plan.move.key ~= "dead" then
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
    local base, ctx = ns.Data.Key(SOURCES), Desk.Context()
    for _, id in ipairs(LadderIDs()) do
        local name = Market.ItemInfo(id)
        if not search or search == "" or name:lower():find(search, 1, true) then
            local plan = Desk.Plan(id, base, ctx)
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
    local cols = { u = {}, q = {}, m = {} }
    for i, d in ipairs(Market.Deals()) do
        if i % 64 == 0 then ns.Data.Step() end
        local c = Prices.LadderColumns(d.id, cols)
        if c and math.abs(c.t - d.s.t) <= 600 then
            local limit = d.usual * Market.DEAL_FACTOR
            local units, cost = 0, 0
            for k = 1, c.count do
                if c.u[k] > limit then break end
                local q = c.q[k] - c.m[k]
                units, cost = units + q, cost + q * c.u[k]
            end
            -- Resold at the usual price: expected with your sell rate, else only
            -- "if all resold" (never sorted as if it were sure).
            local _, _, rate = Market.SaleCounts(d.id)
            local _, _, _, sell = Market.ItemInfo(d.id)
            local value, ifAll = Desk.PostValue(Market.Net(d.usual), units, rate, sell, Desk.Deposit(d.id, units))
            d.units, d.cost, d.rate = units, cost, rate
            d.totalGain = value and value - cost or nil
            d.gainIfAll = ifAll and ifAll - cost or nil
        end
        -- Nothing there to buy that is not yours: no deal.
        if d.units ~= 0 then out[#out + 1] = d end
    end
    -- Expected gains first, most first; then the "if all resold" ones; an
    -- expected loss last (it is not a deal). One C sort; equal keys keep the
    -- order of Market.Deals.
    return ns.Utils.SortBy(out, function(d)
        local group = d.totalGain and (d.totalGain > 0 and "0" or "2") or "1"
        return group .. ns.Utils.NumKey(d.totalGain or d.gainIfAll or d.gain, true)
    end)
end

---------------------------------------------------------------------------
-- Your listings
---------------------------------------------------------------------------
-- Where your listing of `unit` copper each stands: { state = "lowest" /
-- "tied" (another seller at your price, none under) / "undercut" / "unknown", ahead (units cheaper, not yours; nil unknown),
-- lowest (cheapest other price), repost (1c under it), age }.
function Desk.Standing(id, unit)
    if not unit then return { state = "unknown" } end
    local L = Prices.Ladder(id)
    -- A newer look than the ladder (a browse page or a search over several
    -- items updates the price, not the ladder) is the market now: the ladder
    -- does not speak over it.
    local entry = Prices.Entry(id)
    if L and entry and entry.t > (L.t or 0) + 600 then L = nil end
    if L and #L.tiers > 0 then
        local ahead, lowest, tied, lowestK = 0, nil, false, nil
        for _, t in ipairs(L.tiers) do
            local q = t.q - t.m
            if q > 0 and not lowest then lowest = t.u end
            -- Exact prices per unit on both sides (Prices.Exact): 81c and 99c for
            -- 20 are 4.05c and 4.95c, not both "5c" and tied.
            if t.u < unit - 1e-6 then ahead = ahead + q end
            if math.abs(t.u - unit) <= 1e-6 and q > 0 then tied = true end
            if q > 0 and not lowestK and lowest == t.u then lowestK = t.k end
        end
        local out = { ahead = ahead, lowest = lowest, age = time() - L.t, partial = L.partial }
        out.state = ahead > 0 and "undercut" or (tied and "tied" or "lowest")
        -- "Lowest" is a claim about now: an old look, or one that did not see
        -- every auction, cannot make it (someone may be cheaper since).
        if out.state ~= "undercut" and (out.age > Desk.FRESH or L.partial) then out.state = "unknown" end
        -- "Undercut" and its repost price are claims about now too: the cheaper
        -- auctions of an old look may have sold or ended. A partial look that
        -- saw a cheaper one still shows an undercut; an old one only says it
        -- was (oldUndercut, no repost price).
        if out.state == "undercut" and out.age > Desk.FRESH then out.state, out.oldUndercut = "unknown", true end
        if not out.oldUndercut and lowest and lowest <= unit then out.repost = Market.Undercut(lowest, lowestK) end
        return out
    end
    local e = entry
    if not e then return { state = "unknown" } end
    local age = time() - e.t
    -- Without a ladder the lowest price may be your own auction.
    if e.p < unit then
        if age > Desk.FRESH then return { state = "unknown", oldUndercut = true, lowest = e.p, age = age } end
        return { state = "undercut", lowest = e.p, repost = Market.Undercut(e.p), age = age }
    end
    -- "Lowest" is a claim about now, as on the ladder path: an old look cannot make it.
    return { state = (e.p > unit and age <= Desk.FRESH) and "lowest" or "unknown", lowest = e.p, age = age }
end

local function DurationSeconds(text)
    local h = type(text) == "string" and tonumber(text:match("^(%d+)")) or nil
    return h and h * 3600 or nil
end

-- This character's active listings: { source = "game" / "log", t (when
-- the game showed them), list = { { id, name, count, unit, left, endsAt,
-- deposit (paid, from your posting log), depositGuess (no logged post: from
-- your deposit rate), overdue, standing, value (after the cut) } } }.
-- Kept for a minute: "overdue" and the looks' ages move with the clock, the
-- rest with prices (the live list is saved with a prices bump) and your
-- auction log; the window redraws every second a scan changes anything.
function Desk.Listings()
    local char = ns.Gear and ns.Gear.CharKey and ns.Gear.CharKey()
    return Kept("listings", char, Desk.BuildListings, nil, 60)
end

-- One listing from your posting log.
local function LogEntry(a)
    local id = LinkID(a.name)
    local count = a.count or 1
    local secs = DurationSeconds(a.duration)
    local e = { id = id, name = type(a.name) == "string" and (a.name:match("|h%[(.-)%]|h") or a.name) or "?",
        -- Exact like the ladder's tiers, so Standing compares on one basis.
        count = count, unit = (a.buyout and a.buyout > 0) and Prices.Exact(a.buyout / count) or nil,
        buyout = (a.buyout and a.buyout > 0) and a.buyout or nil,
        deposit = a.deposit, endsAt = secs and (a.t + secs) or nil }
    e.overdue = e.endsAt and time() > e.endsAt or false
    return e
end

function Desk.BuildListings()
    local out = { list = {} }
    local live = Prices.Owned()
    if live and time() - live.t < LISTING_MAX_AGE then
        out.source, out.t = "game", live.t
        -- The game's list has no deposit: take it from the posting log, one
        -- logged post (same item and count, newest first) per live auction.
        -- No match: depositGuess from your learned deposit rate, kept apart.
        local posts = {}
        local c = ns.Economy and ns.Economy.Char and ns.Economy.Char()
        -- The log since the list was read: an auction a letter closed after it
        -- has left the house (sold, expired or cancelled: one live auction of
        -- the same item and count each), and a post made after it is not on
        -- it (added below from the log).
        local closed, newer = {}, {}
        for _, a in ipairs(c and c.auctions or {}) do
            local aid = LinkID(a.name)
            local k = aid and (aid .. ":" .. (a.count or 1))
            if k and (a.t or 0) <= live.t then
                if a.status == "listed" and type(a.deposit) == "number" then
                    posts[k] = posts[k] or {}
                    table.insert(posts[k], 1, a.deposit)
                elseif a.status ~= "listed" and ((a.closedAt or a.ended or 0) > live.t) then
                    closed[k] = (closed[k] or 0) + 1
                end
            elseif k and a.status == "listed" then
                newer[#newer + 1] = a
            end
        end
        local now = time()
        for _, a in ipairs(live.list or {}) do
            local k = a.id and (a.id .. ":" .. (a.count or 1))
            local gone = not a.sold and k and (closed[k] or 0) > 0
            if gone then closed[k] = closed[k] - 1 end
            if not a.sold and not gone then
                local queue = a.id and posts[a.id .. ":" .. (a.count or 1)]
                -- The time left was read at live.t: it ends by live.t + left (a
                -- legacy band: its longest), so an old list does not keep ended
                -- auctions as listed. Time left now = what is left of it.
                local left = a.left
                local most = type(left) == "number" and left or LEGACY_LEFT_MAX[left]
                local e = { id = a.id, name = a.name, count = a.count, unit = a.unit, left = left,
                    seenAt = live.t, deposit = queue and table.remove(queue, 1) or nil }
                if most then
                    e.endsAt = live.t + most
                    e.overdue = now > e.endsAt
                    if type(left) == "number" then e.left = math.max(0, left - (now - live.t)) end
                end
                -- The game's list shows time left, not the duration, and the deposit
                -- scales with it: a guess only when all your posts used one duration.
                local _, _, _, _, mixed = Desk.DepositRate()
                if not e.deposit and e.id and not mixed then
                    -- No vendor price (or not cached yet): the deposit stays unknown.
                    local guess = Desk.Deposit(e.id, e.count)
                    e.depositGuess = (guess and guess > 0) and guess or nil
                end
                out.list[#out.list + 1] = e
            end
        end
        -- Posted after the list was read: from the log (not past their own duration).
        for _, a in ipairs(newer) do
            local e = LogEntry(a)
            if not e.overdue then
                out.list[#out.list + 1] = e
                out.source = "game + log"
            end
        end
    else
        out.source = "log"
        local c = ns.Economy and ns.Economy.Char and ns.Economy.Char()
        for _, a in ipairs(c and c.auctions or {}) do
            if a.status == "listed" then out.list[#out.list + 1] = LogEntry(a) end
        end
    end
    for _, e in ipairs(out.list) do
        e.standing = e.id and Desk.Standing(e.id, e.unit) or { state = "unknown" }
        -- The cut is taken once, from the auction's whole price (rounded once,
        -- not per unit: 20 at 1c each brings 19c, not 0).
        local total = e.buyout or (e.unit and math.floor(e.unit * e.count + 0.5))
        e.value = total and Market.NetTotal(total) or nil
        if e.id and not e.name then e.name = Market.ItemInfo(e.id) end
    end
    local ORDER = { undercut = 1, tied = 2, unknown = 3, lowest = 4 }
    table.sort(out.list, function(a, b)
        if a.overdue ~= b.overdue then return not a.overdue end
        local oa, ob = ORDER[a.standing.state] or 3, ORDER[b.standing.state] or 3
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
    -- unpriced: listings without a buyout (bid only, or not read): never counted as 0.
    local value, undercut, overdue, unpriced = 0, 0, 0, 0
    for _, e in ipairs(listings.list) do
        if not e.overdue then
            if e.value then value = value + e.value else unpriced = unpriced + 1 end
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
    return { listings = listings, listed = #listings.list - overdue, value = value, unpriced = unpriced, undercut = undercut, overdue = overdue,
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
    local plan = Desk.Detail(found)
    local L = plan.ladder
    ns.Print(string.format("%s: %d units in %d auctions, %s ago.", Market.ItemText(found), L.units, L.auctions or 0, Prices.Age(L.t)))
    local function Q(c) return c and Money(c) or "?" end
    local all = plan.all
    print(string.format("  Buy them all: %s%s (%d units), relist at %s: %s.", plan.atLeast and "at least " or "", Money(all.cost),
        all.units, all.relist and (Money(all.relist) .. " (usual)") or "? (too few looks for a usual price)",
        all.profit and (Desk.Signed(all.profit) .. " expected") or (all.ifAll and (Desk.Signed(all.ifAll) .. " if it all sells") or "?")))
    local b = plan.best or plan.bestIfAll
    if b then
        print(string.format("  Best reset: buy up to %s (%d units, %s), relist at %s: %s.", Money(b.upTo), b.units,
            Money(b.cost), Q(b.relist), b.profit and (Desk.Signed(b.profit) .. " expected") or (Desk.Signed(b.ifAll) .. " if it all sells")))
    end
    if not plan.rate then print("  No sell rate of yours yet (5 ended auctions): profits are only if everything sells.") end
    if ns.AuctionDeskUI then ns.AuctionDeskUI.Show("control", found) end
    return true
end

ns.RegisterModule("AuctionDesk", {
    defaults = { deskMinProfit = 5000 },
    slash = Slash,
})
