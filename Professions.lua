-- TALOD - Professions: a leveling plan for a crafting profession or a
-- secondary skill (First Aid, Cooking): from your rank to a target, which
-- recipe to make at each skill, about how many, what to buy (minus what is
-- in your bags and bank), what to make first (Bolt of Linen Cloth before the
-- shirts), and where to train the next rank.
--
-- The math is the vanilla skill-up rule: orange recipes always give a
-- point; from the start of yellow to grey the chance falls in a straight
-- line, (grey - skill) / (grey - yellow) (100% at the first yellow point,
-- about half where green starts, 0 at grey). The expected number of crafts per point
-- is 1 / chance, and at every point the plan picks the recipe whose expected
-- cost per point is lowest (prices: vendor, else Wowhead's auction average).
-- It is an estimate: skill-ups are random, auction prices differ by server,
-- and the intermediates you make on the way (bolts, bars) give skill too.
--
-- All recipe and item data is ProfessionData.lua, generated from Wowhead
-- Classic by tools/gen_professions.py (docs/DATA.md).
-- The recipes you know are read from your profession window when you open it.

local ADDON_NAME, ns = ...
local S = ns.Secret

local Prof = {}
ns.Professions = Prof

local DATA = ns.ProfessionData or { ranks = {}, recipes = {}, items = {}, gathering = {} }
Prof.DATA = DATA

-- Copper per unit when nothing has a price: only a ranking penalty when the
-- planner picks recipes (possible, not preferred). Never shown or added to an
-- amount: ItemPrice says "unknown" with it, BuyCost returns nil.
local UNKNOWN_PRICE = 2000
local PATTERN_PENALTY = 1.5     -- a dropped / quest pattern you do not have costs luck or a trip
local LEARN_SPREAD = 15         -- a recipe's training fee is spread over this many points when comparing
local STICKY = 1.1              -- keep the current recipe unless another is >10% cheaper per point
local RESALE_FLOOR = 0.25       -- with resale on, a craft still costs at least this share of its materials
local MAX_DEPTH = 4             -- intermediates made from intermediates

local function db() return ns.DB() end

-- Recipes per profession, by the skill they are learned at.
local byProf = {}
for sid, r in pairs(DATA.recipes) do
    r.id = sid
    byProf[r.prof] = byProf[r.prof] or {}
    table.insert(byProf[r.prof], r)
end
for _, list in pairs(byProf) do
    table.sort(list, function(a, b) return a.skill < b.skill or (a.skill == b.skill and a.id < b.id) end)
end

function Prof.Recipes(prof) return byProf[prof] or {} end

-- Professions with recipe data, sorted.
function Prof.Names()
    local out = {}
    for name in pairs(DATA.ranks) do out[#out + 1] = name end
    table.sort(out)
    return out
end

function Prof.IsGathering(prof) return DATA.gathering and DATA.gathering[prof] ~= nil end

function Prof.MaxSkill(prof)
    local ranks = DATA.ranks[prof]
    return ranks and ranks[#ranks].max or 300
end

-- The rank whose maximum covers `skill` (Apprentice for 1..74, ...).
function Prof.RankFor(prof, skill)
    for _, r in ipairs(DATA.ranks[prof] or {}) do
        if skill < r.max then return r end
    end
end

function Prof.NextRank(prof, max)
    for _, r in ipairs(DATA.ranks[prof] or {}) do
        if r.max > max then return r end
    end
end

---------------------------------------------------------------------------
-- Difficulty
---------------------------------------------------------------------------
-- colors = { orange, yellow, green, grey }: the skill each color starts at.
function Prof.Color(r, skill)
    local c = r.colors
    if skill >= c[4] then return "grey" elseif skill >= c[3] then return "green" elseif skill >= c[2] then return "yellow" end
    return "orange"
end

function Prof.Chance(r, skill)
    local yellow, grey = r.colors[2], r.colors[4]
    if skill >= grey then return 0 end
    if skill < yellow or grey <= yellow then return 1 end
    return (grey - skill) / (grey - yellow)
end

function Prof.IsPattern(r)
    for _, src in ipairs(r.src or {}) do
        if src == "trainer" or src == "starter" then return false end
    end
    return true
end

-- What learning it costs you: the trainer fee or a vendor pattern's price
-- (nil for a dropped pattern: no price).
function Prof.LearnCost(r)
    if Prof.IsPattern(r) then return r.patternPrice end
    if not r.cost then
        -- Starter recipes come with the profession: free, not unknown.
        for _, src in ipairs(r.src or {}) do if src == "starter" then return 0 end end
    end
    return r.cost
end

---------------------------------------------------------------------------
-- Items and prices
---------------------------------------------------------------------------
function Prof.Item(id) return DATA.items[id] end

function Prof.ItemName(id)
    local it = DATA.items[id]
    return it and it.name or ("item " .. tostring(id))
end

function Prof.ItemIcon(id)
    local it = DATA.items[id]
    return it and it.icon and ("Interface\\Icons\\" .. it.icon) or 134400
end

-- Copper for one (the lowest you know: one unit, not n; see BuyCost), where
-- the price comes from, and when it was seen:
-- "seen" (the Auction House as you last looked, see Prices.lua) or
-- "auctionator" (its scans), "vendor" when a vendor sells it for less (or
-- it was not seen), "ah" (Wowhead's Classic Era auction average: the last
-- resort) or "unknown".
function Prof.ItemPrice(id)
    local it = DATA.items[id]
    local vendor = it and it.vendor and it.vendor > 0 and it.vendor or nil
    local p, t, src
    if ns.Prices then p, t, src = ns.Prices.Get(id) end
    -- Your Auction House looks come first; a vendor only when it is cheaper.
    if vendor and (not p or vendor <= p) then return vendor, "vendor" end
    if p then return p, src, t end
    if it and it.ah and it.ah > 0 then return it.ah, "ah" end
    return UNKNOWN_PRICE, "unknown"
end

-- Buying `n` of an item, units `from` + 1 .. `from` + n (from: units already
-- bought earlier in the same plan, default 0), counted along the price ladder:
--   Prof.BuyCost(id, n, from) -> cost | nil, info
--   cost  copper for all n, nil when some units have no price (never a guess)
--   info  { src = "vendor" / "ladder" / "lowest" / "ah" / "unknown",
--           estimated = true when not counted along a ladder (the lowest price
--           times n, or Wowhead's average): thin data,
--           short = units without a price, partial = copper for the priced
--           units (always a number), age = ladder age in seconds or nil,
--           surplus = units bought past n: only whole stacks were for sale,
--           and cost is the money for all of them }
-- ItemPrice's lowest times n assumes every unit is as cheap as the cheapest
-- auction: 144 Linen with 5 listed at 30c is not 144 x 30c. A vendor sells
-- without limit, so it caps every tier and covers what the ladder does not.
-- Units past a ladder's end (or past what it kept) have no price: the ladder
-- is the whole market you saw, more may or may not be listed now.
local STALE_LADDER = 7 * 86400
function Prof.BuyCost(id, n, from)
    n, from = math.max(0, math.floor(n or 0)), math.max(0, math.floor(from or 0))
    local it = DATA.items[id]
    local vendor = it and it.vendor and it.vendor > 0 and it.vendor or nil
    local info = { src = "unknown", estimated = false, short = 0, partial = 0 }
    if n == 0 then
        info.src = vendor and "vendor" or "unknown"
        return 0, info
    end
    local Pr = ns.Prices
    local c2, got2, age = nil, nil, nil
    if Pr and Pr.LadderBuy then c2, got2, age = Pr.LadderBuy(id, from + n, vendor) end
    -- The ladder counts only while no newer price exists (a search over many
    -- items, a browse row or Auctionator's later scan update the price, not
    -- the ladder): an old ladder is not today's market. Then the newest
    -- lowest price stands in, estimated.
    if c2 and Pr.Get then
        local _, seen = Pr.Get(id)
        if seen and age and seen > time() - age + 600 then c2 = nil end
    end
    if c2 then
        local c1, got1 = 0, 0
        if from > 0 then c1, got1 = Pr.LadderBuy(id, from, vendor) end
        -- Whole auctions: the units bought can be more than needed (a stack of
        -- 20 for 3); the money is spent all the same, and the spare units are
        -- owned: a later need takes them first at no extra cost. So this step
        -- costs what buying from + n costs more than buying `from`, and its
        -- units past the ladder are those short of from + n less those already
        -- short of `from` (counted by the step before).
        got1, got2 = got1 or 0, got2 or 0
        local lack = math.max(0, math.max(0, from + n - got2) - math.max(0, from - got1))
        local covered = n - lack
        info.surplus = (c2 > c1 and got2 > from + n) and got2 - (from + n) or nil
        info.age = age
        -- An old ladder (and nothing newer): its cost is what the market was.
        info.stale = (age and age > STALE_LADDER) or nil
        if vendor then
            local full2 = c2 + math.max(0, from + n - got2) * vendor
            local full1 = c1 + math.max(0, from - got1) * vendor
            info.partial = math.max(0, full2 - full1)
            info.src = covered > 0 and "ladder" or "vendor"
            return info.partial, info
        end
        local cost = math.max(0, c2 - c1)
        info.src, info.partial, info.short = "ladder", cost, lack
        if lack > 0 then return nil, info end
        return cost, info
    end
    -- No ladder: the lowest price you know for every unit (vendor exact).
    local p, src = Prof.ItemPrice(id)
    if src == "unknown" then
        info.short = n
        return nil, info
    end
    if src == "vendor" then
        info.src, info.partial = "vendor", p * n
        return info.partial, info
    end
    info.src, info.estimated, info.partial = (src == "ah") and "ah" or "lowest", true, p * n
    return info.partial, info
end

-- Cheapest way to get `n` of an item: buy them (BuyCost) or make them with a
-- recipe makers(id, depth) offers, its materials bought or made the same way.
-- Returns cost | nil (some part has no price), recipe | nil (nil = buy).
-- A route with a price always beats one without. `path` stops cycles
-- (essences that turn into each other). `bought` (optional): { [id] = units
-- already bought } by the plan or tree around this route: a reagent is priced
-- after those along its ladder, and after what the same route buys of it in
-- an earlier branch, never from the cheapest tier again.
-- Third return: what a made route buys, { { id, units } }, so the caller's
-- later branches price after it.
function Prof.RouteCost(id, n, makers, depth, maxDepth, path, from, bought)
    depth, maxDepth = depth or 0, maxDepth or 4
    local best = Prof.BuyCost(id, n, from)
    local recipe, buys
    if depth >= maxDepth or n <= 0 then return best, nil end
    path = path or {}
    bought = bought or {}
    path[id] = true
    for _, r in ipairs(makers(id, depth) or {}) do
        local crafts = math.ceil(n / math.max(r.makes or 1, 1))
        local cost, ok = 0, true
        local claims, undo = {}, {}
        local function Claim(cid, units)
            claims[#claims + 1] = { cid, units }
            undo[#undo + 1] = { cid, rawget(bought, cid) }
            bought[cid] = (bought[cid] or 0) + units
        end
        for _, rg in ipairs(r.reagents or {}) do
            if path[rg[1]] then ok = false break end
            local m = rg[2] * crafts
            local c, sub, subBuys = Prof.RouteCost(rg[1], m, makers, depth + 1, maxDepth, path, bought[rg[1]] or 0, bought)
            if not c then ok = false break end
            cost = cost + c
            -- What this branch buys: later branches of the route buy after it.
            if sub then
                for _, b in ipairs(subBuys or {}) do Claim(b[1], b[2]) end
            else
                Claim(rg[1], m)
            end
        end
        for k = #undo, 1, -1 do rawset(bought, undo[k][1], undo[k][2]) end
        if ok and (not best or cost < best) then best, recipe, buys = cost, r, claims end
    end
    path[id] = nil
    return best, recipe, buys
end

-- An amount where part has no price: "1g 20s", "1g 20s + 3 without a price",
-- or "? (3 without a price)". Unknown is never shown as a number.
function Prof.MoneyKnown(copper, unpriced, what)
    if not unpriced or unpriced <= 0 then return Prof.Money(copper) end
    what = what or "without a price"
    if (copper or 0) > 0 then return Prof.Money(copper) .. " + " .. unpriced .. " " .. what end
    return "? (" .. unpriced .. " " .. what .. ")"
end

-- "AH 25c, 2 h ago" / "AH ~25c (Wowhead average)" / "vendor 10c".
function Prof.PriceText(id)
    local p, src, t = Prof.ItemPrice(id)
    if src == "vendor" then return "vendor " .. Prof.Money(p) end
    if src == "seen" then return "AH " .. Prof.Money(p) .. ", " .. ns.Prices.Age(t) end
    if src == "auctionator" then return "AH " .. Prof.Money(p) .. ", Auctionator " .. ns.Prices.Age(t, src) end
    if src == "ah" then return "AH ~" .. Prof.Money(p) .. " (Wowhead average)" end
    return "no price"
end

function Prof.Money(copper)
    copper = math.floor((copper or 0) + 0.5)
    if copper <= 0 then return "0c" end
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if c > 0 and g == 0 then parts[#parts + 1] = c .. "c" end
    return table.concat(parts, " ")
end

-- What one unit of a product brings when you sell it: the Auction House
-- after the cut (your last look or Auctionator) or a vendor, whichever is
-- more. Returns copper, "ah" / "vendor", when seen. Wowhead's average is
-- not used: an unseen market is not money you can count on.
local AH_CUT = 0.05
function Prof.SellValue(id)
    -- One rule everywhere (Market.SaleValue: your sell rate, soulbound, grey).
    -- Also returns the vendor price and the units listed at your last look
    -- (nil: not seen), so a caller can tell how far the AH value reaches.
    local listed = ns.Prices and ns.Prices.Entry and ns.Prices.Entry(id)
    listed = type(listed) == "table" and listed.n or nil
    local it = DATA.items[id]
    if ns.Market and ns.Market.SaleValue then
        local v, how, info = ns.Market.SaleValue(id)
        -- The supply of the look that gave the price: an Auctionator price has
        -- none of its own (nil: unknown, never 0 nor an older look's count).
        if not (info and info.src == "seen") then listed = nil end
        return v, how, info and info.t, (info and info.vendor) or (it and it.sell) or 0, listed
    end
    local vendor = it and it.sell or 0
    local p, t = nil, nil
    if ns.Prices then p, t = ns.Prices.Get(id) end
    local net = p and math.floor(p * (1 - ((ns.Market and ns.Market.CUT) or AH_CUT))) or 0
    if net > vendor then return net, "ah", t, vendor, listed end
    if vendor > 0 then return vendor, "vendor", nil, vendor, listed end
    return 0, nil, nil, vendor, listed
end

-- At your last look: units and auctions listed (nil: not seen).
function Prof.Supply(id)
    local e = ns.Prices and ns.Prices.Entry(id)
    if not e then return nil end
    return e.n, e.a, e.t
end

-- How you get an item, in a few words.
function Prof.HowToGet(id)
    local it = DATA.items[id]
    if not it then return "drop or Auction House" end
    -- Say what the plan priced: a vendor item seen cheaper at the Auction
    -- House is costed (and so shown) at the AH.
    local _, priced = Prof.ItemPrice(id)
    if it.vendor and priced == "vendor" then return "vendor " .. Prof.Money(it.vendor) end
    if it.made and it.made[1] then
        local r = DATA.recipes[it.made[1]]
        if r then return string.format("made: %s %d", r.prof, r.skill) end
    end
    local _, src = Prof.ItemPrice(id)
    if it.get then return it.get .. ((src == "seen" or src == "auctionator") and (" · " .. Prof.PriceText(id)) or "") end
    if src ~= "unknown" then return Prof.PriceText(id) end
    return "drop or Auction House"
end

-- Bags, reagent bag and bank: GetItemCount(id, true) is the game's own
-- total. The slot-by-slot scan (Economy's: bags 0-4 only, no reagent bag)
-- is only a floor for clients where GetItemCount is missing or unreadable;
-- trusting it alone missed Salt in the reagent bag on WoW Forever.
local function BagCounts() return ns.Data.Bags() end

function Prof.Count(id)
    local e = BagCounts()[id]
    local bags = e and e.n or 0
    local fn = (C_Item and C_Item.GetItemCount) or GetItemCount
    local all
    if type(fn) == "function" then
        local ok, n = pcall(fn, id, true)
        all = ok and S.Value(n) or nil
    end
    return math.max(type(all) == "number" and all or 0, bags)
end

---------------------------------------------------------------------------
-- Known recipes and your rank, read from the profession window. Classic
-- Era: the TradeSkill API (and the Craft API for Enchanting). Newer engine
-- (WoW Forever): C_TradeSkillUI, whose recipe IDs are the spell IDs of the
-- data. Merged, never replaced: a search or filter shows only part of it.
---------------------------------------------------------------------------
local function KnownFor(prof)
    local c = ns.Skills and ns.Skills.Char()
    if not c then return nil end
    c.recipes = c.recipes or {}
    c.recipes[prof] = c.recipes[prof] or {}
    return c.recipes[prof]
end

local function ReadClassicWindow(api)
    local lineFn, numFn, infoFn, typePos
    if api == "craft" then
        lineFn, numFn, infoFn, typePos = GetCraftDisplaySkillLine, GetNumCrafts, GetCraftInfo, 3
    else
        lineFn, numFn, infoFn, typePos = GetTradeSkillLine, GetNumTradeSkills, GetTradeSkillInfo, 2
    end
    if type(lineFn) ~= "function" or type(numFn) ~= "function" or type(infoFn) ~= "function" then return nil end
    local prof, rank, max = S.CallMulti(3, lineFn)
    if type(prof) ~= "string" or not DATA.ranks[prof] then return nil end
    if ns.Skills then ns.Skills.FromWindow(prof, rank, max) end
    local n = S.Call(numFn)
    if type(n) ~= "number" or n <= 0 then return prof, 0 end
    local known = KnownFor(prof)
    if not known then return nil end
    local added = 0
    for i = 1, n do
        local values = { S.CallMulti(3, infoFn, i) }
        local name, kind = values[1], values[typePos]
        if type(name) == "string" and kind ~= "header" and kind ~= "subheader" then
            if not known[name] then added = added + 1 end
            known[name] = true
        end
    end
    return prof, added
end

local function ReadModernWindow()
    local T = C_TradeSkillUI
    if type(T) ~= "table" or type(T.GetBaseProfessionInfo) ~= "function" then return nil end
    local info = S.Call(T.GetBaseProfessionInfo)
    if type(info) ~= "table" then return nil end
    local prof = S.Value(info.professionName)
    if type(prof) ~= "string" or not DATA.ranks[prof] then return nil end
    local rank, max = S.Value(info.skillLevel), S.Value(info.maxSkillLevel)
    -- Some clients keep the rank on the "child" (expansion) profession.
    local child = type(T.GetChildProfessionInfo) == "function" and S.Call(T.GetChildProfessionInfo) or nil
    if type(child) == "table" and type(S.Value(child.maxSkillLevel)) == "number" and S.Value(child.maxSkillLevel) > 0 then
        rank, max = S.Value(child.skillLevel), S.Value(child.maxSkillLevel)
    end
    if ns.Skills then ns.Skills.FromWindow(prof, rank, max) end
    local ids = type(T.GetAllRecipeIDs) == "function" and S.Call(T.GetAllRecipeIDs) or nil
    local known = KnownFor(prof)
    if type(ids) ~= "table" or not known then return prof, 0 end
    local added = 0
    for _, id in ipairs(ids) do
        id = S.Value(id)
        local ri = type(id) == "number" and type(T.GetRecipeInfo) == "function" and S.Call(T.GetRecipeInfo, id) or nil
        local learned = type(ri) == "table" and S.Value(ri.learned)
        if learned then
            local r = DATA.recipes[id]
            local name = r and r.name or S.Value(ri.name)
            if type(name) == "string" then
                if not known[name] then added = added + 1 end
                known[name] = true
            end
        end
    end
    return prof, added
end

---------------------------------------------------------------------------
-- Crafting from a step: one click, one game command, the same as typing the
-- count in the profession window and pressing Create (the game repeats the
-- craft, not the addon). The window must be open on that profession: an
-- addon cannot open it on Classic Era; the newer engine's can be.
---------------------------------------------------------------------------
local SKILL_LINE = { Alchemy = 171, Blacksmithing = 164, Cooking = 185, Enchanting = 333, Engineering = 202,
    ["First Aid"] = 129, Leatherworking = 165, Tailoring = 197, Mining = 186 }

local function Started(r, k, count)
    return true, string.format("crafting %d x %s%s.", k, r.name,
        k < count and string.format(" (materials for %d of %d)", k, count) or "")
end

-- Returns ok, message.
function Prof.Craft(r, count)
    if not r then return false, "no recipe." end
    if ns.InCombat() then return false, "not in combat." end
    count = math.max(1, math.floor(count or 1))

    -- Classic Era: TradeSkill window.
    if type(GetTradeSkillLine) == "function" and type(DoTradeSkill) == "function" and S.Call(GetTradeSkillLine) == r.prof then
        for i = 1, S.Call(GetNumTradeSkills) or 0 do
            local name, kind, avail = S.CallMulti(3, GetTradeSkillInfo, i)
            if name == r.name and kind ~= "header" and kind ~= "subheader" then
                avail = type(avail) == "number" and avail or 0
                if avail <= 0 then return false, "you lack the materials for " .. r.name .. "." end
                local k = math.min(count, avail)
                if not pcall(DoTradeSkill, i, k) then return false, "the game did not start the craft." end
                return Started(r, k, count)
            end
        end
        return false, r.name .. " is not in your " .. r.prof .. " list: not learned, or hidden by a search / filter."
    end

    -- Classic Era: Craft window (Enchanting). One per click: an enchant asks
    -- which item to put it on.
    if type(GetCraftDisplaySkillLine) == "function" and type(DoCraft) == "function" and S.Call(GetCraftDisplaySkillLine) == r.prof then
        for i = 1, S.Call(GetNumCrafts) or 0 do
            local name, _, kind, avail = S.CallMulti(4, GetCraftInfo, i)
            if name == r.name and kind ~= "header" then
                if type(avail) == "number" and avail <= 0 then return false, "you lack the materials for " .. r.name .. "." end
                if not pcall(DoCraft, i) then return false, "the game did not start the craft." end
                return true, r.creates and ("crafting 1 x " .. r.name .. " (Enchanting: one per click).")
                    or (r.name .. ": pick the item to enchant (one per click).")
            end
        end
        return false, r.name .. " is not in your Enchanting list: not learned, or hidden by a filter."
    end

    -- Newer engine: C_TradeSkillUI (recipe ID = the data's spell ID).
    local T = C_TradeSkillUI
    if type(T) == "table" and type(T.CraftRecipe) == "function" then
        local info = type(T.GetBaseProfessionInfo) == "function" and S.Call(T.GetBaseProfessionInfo) or nil
        local open = type(info) == "table" and S.Value(info.professionName) or nil
        if open == r.prof then
            local ri = type(T.GetRecipeInfo) == "function" and S.Call(T.GetRecipeInfo, r.id) or nil
            if type(ri) ~= "table" or not S.Value(ri.learned) then
                return false, "you have not learned " .. r.name .. " yet."
            end
            local avail = S.Value(ri.numAvailable)
            local k = count
            if type(avail) == "number" then
                if avail <= 0 then return false, "you lack the materials for " .. r.name .. "." end
                k = math.min(count, avail)
            end
            if not pcall(T.CraftRecipe, r.id, k) then return false, "the game did not start the craft." end
            return Started(r, k, count)
        end
        if type(T.OpenTradeSkill) == "function" and SKILL_LINE[r.prof] and pcall(T.OpenTradeSkill, SKILL_LINE[r.prof]) then
            return false, "opened your " .. r.prof .. " window: click the step again."
        end
    end
    return false, "open your " .. r.prof .. " window first, then click the step again."
end

local function ReadWindow(api)
    local prof, added = ReadClassicWindow(api)
    if prof then return prof, added end
    return ReadModernWindow()
end
Prof.ReadWindow = ReadWindow

function Prof.Known(charKey, prof)
    local c = charKey and db().skills and db().skills[charKey]
    return c and c.recipes and c.recipes[prof] or nil
end

-- Recipes are spells (the data's IDs are spell IDs): the game's own answer.
-- Only a true is trusted: a false may be a recipe ID this client numbers
-- differently, and a secret is unknown.
function Prof.KnowsSpell(r)
    local fn = IsPlayerSpell or IsSpellKnown
    if not (r and r.id) or type(fn) ~= "function" then return nil end
    return S.Call(fn, r.id) == true or nil
end

-- A recipe learned while the profession window was closed (a pattern from
-- the Auction House) would stay "not learned" until the window is read again.
local function Learned(r)
    local known = r and KnownFor(r.prof)
    if not known or known[r.name] then return end
    known[r.name] = true
    ns.Data.Changed("crafts")
end
Prof.Learned = Learned

local LEARN_PATTERN
local function LearnPattern()
    if LEARN_PATTERN == nil then
        local fmt = type(ERR_LEARN_RECIPE_S) == "string" and ERR_LEARN_RECIPE_S or "You have learned how to create a new item: %s."
        LEARN_PATTERN = "^" .. fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)") .. "$"
    end
    return LEARN_PATTERN
end

local function RecipeByName(name)
    for _, r in pairs(DATA.recipes) do
        if r.name == name then return r end
    end
end

---------------------------------------------------------------------------
-- Planner
---------------------------------------------------------------------------
local UnitCost

-- Expected copper for one craft at `skill`, and how many of its materials
-- have no price (their cost in the copper is a placeholder: a recipe with
-- unpriced materials never ranks above one fully priced).
local function CraftCost(r, ctx, skill, depth)
    local total, unpriced = 0, 0
    for _, rg in ipairs(r.reagents) do
        local c, _, unk = UnitCost(rg[1], ctx, skill, depth)
        total = total + rg[2] * c
        unpriced = unpriced + (unk or 0)
    end
    return total, unpriced
end

-- Cheapest way to get one: buy it, or make it with a recipe you can use
-- now (this profession at `skill`, or another profession you have, e.g.
-- smelting bars as a miner). Returns cost, maker, unpriced (materials with
-- no price on the chosen route; a priced route beats an unpriced one).
function UnitCost(id, ctx, skill, depth)
    -- A plan asks for the same reagents at every point and in every recipe:
    -- prices are fixed while it is built, costs for one skill point.
    local memo = ctx.memo
    local key = id * 8 + (depth or 0)
    if memo then
        if memo.skill ~= skill then memo.skill, memo.cost, memo.maker, memo.unk = skill, {}, {}, {} end
        local c = memo.cost[key]
        if c then return c, memo.maker[key] or nil, memo.unk[key] end
    end
    local best = memo and memo.price[id]
    local unk = memo and memo.priceUnk and memo.priceUnk[id]
    if not best then
        local src
        best, src = Prof.ItemPrice(id)
        unk = src == "unknown" and 1 or 0
        if memo then
            memo.price[id] = best
            memo.priceUnk = memo.priceUnk or {}
            memo.priceUnk[id] = unk
        end
    end
    unk = unk or 0
    local maker
    local it = DATA.items[id]
    if it and it.made and (depth or 0) < MAX_DEPTH then
        for _, sid in ipairs(it.made) do
            local r = DATA.recipes[sid]
            local at = r and (r.prof == ctx.prof and skill or ctx.ranks[r.prof])
            if r and at and r.skill <= at and ctx.Allowed(r, true) then
                local c, cu = CraftCost(r, ctx, skill, (depth or 0) + 1)
                c = c / (r.makes or 1)
                cu = cu > 0 and 1 or 0
                if cu < unk or (cu == unk and c < best) then best, maker, unk = c, r, cu end
            end
        end
    end
    if memo then memo.cost[key], memo.maker[key], memo.unk[key] = best, maker or false, unk end
    return best, maker, unk
end

-- prof: profession name; from / to: skill; opts:
--   max      your current maximum (training), default the rank `from` is in
--   known    { [recipe name] = true } recipes you know
--   ranks    { [profession] = rank } your other professions (for intermediates)
--   patterns allow recipes that need a pattern you do not know
--   excluded { [recipe id] = true } recipes you do not want
--   count    function(itemID) -> how many you have (nil: count none)
--   level    your character level (training warnings)
function Prof.Plan(prof, from, to, opts)
    opts = opts or {}
    local known, excluded = opts.known or {}, opts.excluded or {}
    local plan = { prof = prof, from = from, to = to, steps = {}, gaps = {}, shopping = {}, tools = {},
        crafts = 0, materials = 0, learn = 0, training = 0, unknownTraining = 0, unknownPrices = 0, unpriced = 0, unknownLearn = 0 }
    local recipes = byProf[prof]
    if not recipes then
        plan.error = Prof.IsGathering(prof) and ("levels by " .. DATA.gathering[prof]) or "no recipe data"
        return plan
    end
    to = math.min(to, Prof.MaxSkill(prof))
    plan.to = to
    -- Mining: smelting gives skill too, but the profession levels by gathering.
    if Prof.IsGathering(prof) then plan.note = "levels mostly by " .. DATA.gathering[prof] end

    local ctx = { prof = prof, ranks = opts.ranks or {}, memo = { price = {} } }
    function ctx.Allowed(r, intermediate)
        if excluded[r.id] or r.cooldown then return false end
        if r.prof == prof and known[r.name] then return true end
        if r.spec then return false end
        if Prof.IsPattern(r) then return opts.patterns and not intermediate end
        return true
    end

    -- 1. Pick a recipe for every point.
    local cap = opts.max or (Prof.RankFor(prof, from) or {}).max or 75
    -- Your maximum not read and the start at a rank's end (75 / 150 / 225):
    -- whether that rank is trained is unknown, so the training is counted
    -- (its fee and its level), never assumed done for free.
    if not opts.max then
        for _, rk in ipairs(DATA.ranks[prof] or {}) do
            if rk.max == from then cap = from break end
        end
    end
    local used, seg = {}, nil
    local s = from
    while s < to do
        -- A plan prices every recipe at every point: rebuilt in the
        -- background (Data.lua), it pauses here between points.
        ns.Data.Step()
        if s >= cap then
            local rank = Prof.NextRank(prof, cap)
            if not rank then break end
            plan.steps[#plan.steps + 1] = { kind = "train", at = s, rank = rank }
            -- A rank taught by a book costs the book (its price is not in the
            -- data), and a fee missing from the data is unknown: neither is 0.
            local book = type(rank.note) == "string" and rank.note:find("^a book") ~= nil
            if rank.cost == nil or book then
                plan.unknownTraining = plan.unknownTraining + 1
            else
                plan.training = plan.training + rank.cost
            end
            if rank.level and opts.level and opts.level < rank.level then plan.levelShort = rank end
            cap = rank.max
            seg = nil
        else
            local best, bestScore, bestChance, bestUnk
            local function Consider(r)
                local chance = Prof.Chance(r, s)
                if chance <= 0 or not ctx.Allowed(r) then return end
                local cost, unk = CraftCost(r, ctx, s, 0)
                -- Resale: what the product brings back lowers its cost (never
                -- below a quarter of it, so fewer crafts still win).
                if opts.resale and r.creates then
                    cost = math.max(cost - Prof.SellValue(r.creates) * (r.makes or 1), cost * RESALE_FLOOR)
                end
                local score = cost / (chance * (r.up or 1))
                if not known[r.name] then
                    if Prof.IsPattern(r) and not r.patternPrice then score = score * PATTERN_PENALTY + 100 end
                    local learn = Prof.LearnCost(r)
                    if learn and not used[r.id] then score = score + learn / LEARN_SPREAD end
                end
                if seg and seg.recipe == r then score = score / STICKY end
                -- Fewer materials without a price first: a placeholder price never outranks a real one.
                if not bestScore or unk < bestUnk or (unk == bestUnk and score < bestScore) then
                    best, bestScore, bestChance, bestUnk = r, score, chance, unk
                end
            end
            for _, r in ipairs(recipes) do
                if r.skill > s then break end
                Consider(r)
            end
            if not best then
                local last = plan.gaps[#plan.gaps]
                if last and last[2] == s then last[2] = s + 1 else plan.gaps[#plan.gaps + 1] = { s, s + 1 } end
                seg = nil
            else
                local expect = 1 / (bestChance * (best.up or 1))
                if seg and seg.recipe == best then
                    seg.to, seg.expect = s + 1, seg.expect + expect
                else
                    seg = { kind = "craft", from = s, to = s + 1, recipe = best, expect = expect,
                        color = Prof.Color(best, s), known = known[best.name] and true or false,
                        pattern = Prof.IsPattern(best) and not known[best.name] }
                    if not seg.known and not used[best.id] then
                        seg.learn = Prof.LearnCost(best)
                        -- A dropped / quest pattern (or a fee the data lacks)
                        -- costs something unknown, never 0.
                        if not seg.learn then seg.learnUnknown = true end
                    end
                    used[best.id] = true
                    plan.steps[#plan.steps + 1] = seg
                end
                seg.endColor = Prof.Color(best, s)
            end
            s = s + 1
        end
    end
    if s < to then plan.gaps[#plan.gaps + 1] = { s, to } end

    -- 2. Materials, per step, in the order you would do it: what earlier
    -- steps made, what is in your bags, then make (intermediates, their own
    -- materials first) or buy. step.mats = { line }, line = { id, n, made,
    -- have, make, recipe, buy, cost, children }; step.prep lists the makes.
    local bagAvail, madeAvail, shopIndex, toolSeen = {}, {}, {}, {}
    local function Bags(id)
        if bagAvail[id] == nil then bagAvail[id] = opts.count and opts.count(id) or 0 end
        return bagAvail[id]
    end
    local function Shop(id)
        local e = shopIndex[id]
        if not e then
            local unit, src, seen = Prof.ItemPrice(id)
            -- unit: the lowest price, for "each" texts only (nil: no price);
            -- cost / short: what buying `buy` along the ladder costs.
            e = { id = id, need = 0, have = 0, buy = 0, unit = src ~= "unknown" and unit or nil, src = src, seen = seen,
                cost = 0, short = 0 }
            shopIndex[id] = e
            plan.shopping[#plan.shopping + 1] = e
        end
        return e
    end
    -- Recipes you can use for an intermediate at skill `at` (UnitCost's rule).
    local makersAt = {}
    local NONE = {}
    local function Makers(id, at, depth)
        local it = DATA.items[id]
        if not (it and it.made) or (depth or 0) >= MAX_DEPTH then return NONE end
        local key = id * 1024 + at
        local list = makersAt[key]
        if list then return list end
        list = {}
        for _, sid in ipairs(it.made) do
            local r = DATA.recipes[sid]
            local skill = r and (r.prof == ctx.prof and at or ctx.ranks[r.prof])
            if r and skill and r.skill <= skill and ctx.Allowed(r, true) then list[#list + 1] = r end
        end
        makersAt[key] = list
        return list
    end
    local function Tool(id)
        if toolSeen[id] then return end
        toolSeen[id] = true
        plan.tools[#plan.tools + 1] = { id = id, have = Bags(id) > 0 }
    end
    -- Units the plan bought so far, per item (RouteCost adds its own claims on top and takes them back).
    local boughtView = setmetatable({}, { __index = function(_, k) return shopIndex[k] and shopIndex[k].buy or nil end })
    local Need
    -- n of item id at skill `at`, appended to `out` (a step's or a line's list).
    function Need(id, n, at, step, depth, out)
        local line = { id = id, n = n, depth = depth }
        out[#out + 1] = line
        local made = math.min(madeAvail[id] or 0, n)
        if made > 0 then
            madeAvail[id] = madeAvail[id] - made
            line.made, n = made, n - made
        end
        local have = math.min(Bags(id), n)
        if have > 0 then
            bagAvail[id] = bagAvail[id] - have
            local e = Shop(id)
            e.need, e.have = e.need + have, e.have + have
            line.have, n = have, n - have
        end
        if n <= 0 then return line end
        -- Make or buy for this many: buying more walks up the ladder (after
        -- what earlier steps already bought), so a cheap tier that wins for
        -- one unit can lose for 144.
        local maker
        if (depth or 0) < MAX_DEPTH and Makers(id, at, depth)[1] then
            local function MakersAt(x, d) return Makers(x, at, (depth or 0) + d) end
            local from = shopIndex[id] and shopIndex[id].buy or 0
            -- Reagents priced after what earlier steps already bought of them.
            maker = select(2, Prof.RouteCost(id, n, MakersAt, 0, MAX_DEPTH - (depth or 0), nil, from, boughtView))
        end
        if maker then
            local crafts = math.ceil(n / (maker.makes or 1))
            line.make, line.recipe, line.children = crafts, maker, {}
            step.prep = step.prep or {}
            table.insert(step.prep, { recipe = maker, crafts = crafts, item = id, n = n, depth = depth })
            for _, tid in ipairs(maker.tools or {}) do Tool(tid) end
            for _, rg in ipairs(maker.reagents) do Need(rg[1], rg[2] * crafts, at, step, depth + 1, line.children) end
            local extra = crafts * (maker.makes or 1) - n
            if extra > 0 then madeAvail[id] = (madeAvail[id] or 0) + extra end
        else
            local e = Shop(id)
            local _, info = Prof.BuyCost(id, n, e.buy)
            e.need, e.buy = e.need + n, e.buy + n
            if info.short > 0 and e.short == 0 then plan.unknownPrices = plan.unknownPrices + 1 end
            e.cost, e.short, e.buySrc = e.cost + info.partial, e.short + info.short, info.src
            e.estimated = e.estimated or info.estimated or nil
            line.buy, line.cost, line.short = n, info.partial, info.short > 0 and info.short or nil
            step.cost = (step.cost or 0) + info.partial
            if info.short > 0 then step.short = (step.short or 0) + info.short end
            plan.materials = plan.materials + info.partial
            plan.unpriced = plan.unpriced + info.short
        end
        return line
    end
    for _, step in ipairs(plan.steps) do
        if step.kind == "craft" then
            local r = step.recipe
            step.crafts = math.ceil(step.expect - 0.05)
            step.mats = {}
            plan.crafts = plan.crafts + step.crafts
            plan.learn = plan.learn + (step.learn or 0)
            if step.learnUnknown then plan.unknownLearn = plan.unknownLearn + 1 end
            for _, tid in ipairs(r.tools or {}) do Tool(tid) end
            for _, rg in ipairs(r.reagents) do Need(rg[1], rg[2] * step.crafts, step.from, step, 0, step.mats) end
            if r.creates then madeAvail[r.creates] = (madeAvail[r.creates] or 0) + step.crafts * (r.makes or 1) end
        end
    end
    -- What you end up with: products not used by later steps, and what selling them brings.
    -- The Auction House value counts only for as many units as the market
    -- listed at your last look; the rest at the vendor price. A market that
    -- carries 5 does not take 200 of yours at its lowest price, and walking up
    -- the ladder would be worse (those dearer listings are other sellers
    -- waiting too). Nothing tells how many would sell: the vendor is the one
    -- price that takes any number, so it is the floor for the rest.
    plan.products, plan.resale = {}, 0
    for _, step in ipairs(plan.steps) do
        local id = step.kind == "craft" and step.recipe.creates
        if id and (madeAvail[id] or 0) > 0 then
            local left = madeAvail[id]
            madeAvail[id] = 0
            local value, src, seen, vendor, listed = Prof.SellValue(id)
            local worth, atAH = left * value, left
            -- Supply unknown: only the vendor price is sure (worth is then a
            -- lower bound, said so: supplyUnknown), never "0 were listed".
            local supplyUnknown = src == "ah" and listed == nil or nil
            if src == "ah" then
                atAH = math.min(left, listed or 0)
                worth = atAH * value + (left - atAH) * (vendor or 0)
            end
            plan.products[#plan.products + 1] = { id = id, n = left, unit = value, src = src, seen = seen,
                worth = worth, atAH = (src == "ah" and not supplyUnknown) and atAH or nil, vendor = vendor, supplyUnknown = supplyUnknown }
            if supplyUnknown then plan.resaleAtLeast = true end
            plan.resale = plan.resale + worth
        end
    end
    plan.total = plan.materials + plan.learn + plan.training
    plan.net = plan.total - plan.resale
    return plan
end

-- The plan for a character (default: you) with the saved options.
-- Where the plan starts: your rank as last read (Skills tab, or the
-- profession window), or a start you set by hand when that is missing or
-- out of date. A hand start below your read rank is ignored: you are past it.
-- Returns skill, source ("rank" read, "set" by hand, "none"), your read rank.
function Prof.Start(charKey, prof)
    local c = charKey and db().skills and db().skills[charKey]
    local cur = c and c.current and c.current[prof]
    local read = cur and cur.rank or nil
    local per = db().profPlanFrom[charKey or ""]
    local set = per and per[prof]
    if type(set) == "number" and set > (read or 1) then return set, "set", read end
    if read then return read, "rank", read end
    return 1, "none", nil
end

-- What a plan is built from (Prof.PlanFor's memo key); Auctionator's prices
-- change without a source, hence the age limit.
local PLAN_SOURCES = { "prices", "skills", "crafts", "economy" }
local PLAN_SOURCES_BAGS = { "prices", "skills", "crafts", "economy", "bags" }
local PLAN_MAX_AGE = 300

-- n nil: back to your read rank.
function Prof.SetStart(charKey, prof, n)
    if not charKey then return end
    local per = db().profPlanFrom[charKey] or {}
    db().profPlanFrom[charKey] = per
    per[prof] = n and math.max(1, math.min(Prof.MaxSkill(prof) - 1, math.floor(n))) or nil
end

function Prof.PlanFor(charKey, prof, target)
    local me = ns.Gear.CharKey()
    charKey = charKey or me
    local c = charKey and db().skills and db().skills[charKey]
    local cur = c and c.current and c.current[prof]
    local ranks = {}
    for name, s in pairs(c and c.current or {}) do ranks[name] = s.rank end
    local from, source = Prof.Start(charKey, prof)
    target = target or Prof.Target(prof, from)
    -- Your trained maximum only counts from your read rank; a hand start
    -- past it means you trained since. At the cap (75 / 75) the next step is
    -- training: the maximum stays.
    local max = cur and cur.max or nil
    if max and from > max then max = nil end
    local opts = {
        max = max,
        known = Prof.Known(charKey, prof),
        ranks = ranks,
        patterns = db().profPlanPatterns,
        resale = db().profPlanResale,
        excluded = db().profPlanExcluded,
        count = (db().profPlanBags and charKey == me) and Prof.Count or nil,
        level = charKey == me and S.Call(UnitLevel, "player") or nil,
    }
    -- A plan prices every recipe at every skill point (tens of thousands of
    -- lookups): kept until a price, a skill, a recipe, the sell rate, the
    -- bags (when counted) or a planner setting changes. Callers must not change it.
    local excluded = {}
    for id, on in pairs(opts.excluded or {}) do if on then excluded[#excluded + 1] = tostring(id) end end
    table.sort(excluded)
    local key = table.concat({ ns.Data.Key(opts.count and PLAN_SOURCES_BAGS or PLAN_SOURCES), tostring(charKey), prof,
        from, source, target, tostring(max), tostring(opts.patterns), tostring(opts.resale), tostring(opts.level),
        table.concat(excluded, ",") }, "|")
    return ns.Data.Memo("prof:plan:" .. tostring(charKey) .. ":" .. prof, key, function()
        -- The window list is only filled once the profession window was read:
        -- for you, the game's own spell list counts too (CraftTrack does the same).
        if charKey == me then
            local known = {}
            for name, on in pairs(opts.known or {}) do known[name] = on end
            for _, r in pairs(DATA.recipes) do
                if r.prof == prof and not known[r.name] and Prof.KnowsSpell(r) then known[r.name] = true end
            end
            opts.known = known
        end
        local plan = Prof.Plan(prof, from, target, opts)
        plan.source, plan.rank, plan.max = source, cur and cur.rank or nil, cur and cur.max or nil
        return plan
    end, PLAN_MAX_AGE)
end

-- Saved target for a profession, else the end of the rank you are in.
function Prof.Target(prof, from)
    local t = db().profPlanTargets and db().profPlanTargets[prof]
    if type(t) == "number" and t > (from or 1) then return t end
    local rank = Prof.RankFor(prof, from or 1)
    return rank and rank.max or Prof.MaxSkill(prof)
end

function Prof.SetTarget(prof, t)
    db().profPlanTargets[prof] = math.max(2, math.min(Prof.MaxSkill(prof), math.floor(t)))
end

-- A one-paragraph summary for chat.
function Prof.Summary(plan)
    if plan.error then return plan.prof .. ": " .. plan.error end
    return string.format("%s %d -> %d: about %d crafts, est. %s (materials %s, recipes %s, training %s)%s",
        plan.prof, plan.from, plan.to, plan.crafts, Prof.TotalText(plan), Prof.MaterialsText(plan),
        Prof.LearnText(plan), Prof.TrainingText(plan),
        #plan.gaps > 0 and string.format("; no recipe for %d-%d", plan.gaps[1][1], plan.gaps[1][2]) or "")
end

-- A plan's amounts with what has no price said, never counted as a number:
-- plan.total / materials / learn hold the priced part only.
function Prof.MaterialsText(plan)
    return Prof.MoneyKnown(plan.materials, plan.unpriced or 0, (plan.unpriced or 0) == 1 and "unit without a price" or "units without a price")
end

function Prof.LearnText(plan)
    local n = plan.unknownLearn or 0
    return Prof.MoneyKnown(plan.learn, n, n == 1 and "pattern without a price" or "patterns without a price")
end

function Prof.TrainingText(plan)
    local n = plan.unknownTraining or 0
    return Prof.MoneyKnown(plan.training, n, n == 1 and "rank without a price" or "ranks without a price")
end

function Prof.TotalText(plan)
    local u, l, tr = plan.unpriced or 0, plan.unknownLearn or 0, plan.unknownTraining or 0
    if u == 0 and l == 0 and tr == 0 then return Prof.Money(plan.total) end
    return "at least " .. Prof.Money(plan.total)
end

---------------------------------------------------------------------------
-- Events and slash
---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- Crafting log: every craft, from any window (a successful cast of a recipe
-- spell), merged while you keep making the same recipe. The skill points
-- the Skills module sees right after are credited to it. Materials and cost
-- come from the data, not from your bags. Per character:
-- TALODDB.skills[key].crafts = { { id, n, t, t2, from, to, zone, level } }.
---------------------------------------------------------------------------
local CRAFT_MERGE = 300       -- seconds between crafts of one recipe that still count as one batch
local CREDIT_SECONDS = 30     -- a skill-up this soon after a craft is that craft's
local MAX_CRAFTS = 2000

function Prof.Crafts(charKey)
    local c = charKey and db().skills and db().skills[charKey]
    return c and c.crafts or {}
end

-- What the materials of one craft are worth at the lowest prices you know
-- (bought, not made): copper for the priced ones, and how many materials have
-- no price (left out, never counted at a placeholder). A value of what was
-- used, not a purchase, so one price per unit.
function Prof.ReagentCost(r)
    local total, unpriced = 0, 0
    for _, rg in ipairs(r.reagents or {}) do
        local p, src = Prof.ItemPrice(rg[1])
        if src == "unknown" then unpriced = unpriced + 1 else total = total + rg[2] * p end
    end
    return total, unpriced
end

function Prof.RecordCraft(spellID, now)
    local r = DATA.recipes[spellID]
    if not r or not db().craftLogEnabled then return nil end
    local c = ns.Skills and ns.Skills.Char()
    if not c then return nil end
    c.crafts = c.crafts or {}
    now = now or time()
    local last = c.crafts[#c.crafts]
    if last and last.id == spellID and now - (last.t2 or last.t) <= CRAFT_MERGE then
        last.n, last.t2 = last.n + 1, now
        ns.Data.Changed("crafts")
        return last
    end
    local cur = c.current and c.current[r.prof]
    local zone = S.Call(GetZoneText)
    local e = { id = spellID, n = 1, t = now, t2 = now, from = cur and cur.rank or nil, to = cur and cur.rank or nil,
        zone = (type(zone) == "string" and zone ~= "") and zone or nil, level = S.Call(UnitLevel, "player") }
    c.crafts[#c.crafts + 1] = e
    while #c.crafts > MAX_CRAFTS do table.remove(c.crafts, 1) end
    ns.Data.Changed("crafts")
    return e
end

-- Called by Skills when a rank rises.
function Prof.OnRank(c, name, from, to)
    local last = c and c.crafts and c.crafts[#c.crafts]
    local r = last and DATA.recipes[last.id]
    if not r or r.prof ~= name or time() - (last.t2 or last.t) > CREDIT_SECONDS then return end
    last.from = last.from or from
    last.to = math.max(last.to or to, to)
    -- Skills announces the rank change itself.
    ns.Data.Bump("crafts")
end

local function OnEvent(event, ...)
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        if S.Value(unit) ~= "player" then return end
        spellID = S.Value(spellID)
        if type(spellID) == "number" and DATA.recipes[spellID] then Prof.RecordCraft(spellID) end
        return
    end
    if not db().skillsEnabled then return end
    if event == "NEW_RECIPE_LEARNED" or event == "LEARNED_SPELL_IN_TAB" then
        local id = S.Value((...))
        if type(id) == "number" then Learned(DATA.recipes[id]) end
        return
    end
    if event == "CHAT_MSG_SYSTEM" then
        local text = S.Value((...))
        local name = type(text) == "string" and text:match(LearnPattern())
        if name then Learned(RecipeByName(name)) end
        return
    end
    local api = (event == "CRAFT_SHOW" or event == "CRAFT_UPDATE") and "craft" or "trade"
    local prof = ReadWindow(api)
    if prof then ns.Data.Changed("crafts") end
end

-- Finds a profession by a typed prefix ("tail", "first").
function Prof.Match(text)
    text = (text or ""):lower()
    if text == "" then return nil end
    for _, name in ipairs(Prof.Names()) do
        if name:lower():sub(1, #text) == text then return name end
    end
end

local function Slash(command, rest)
    if command == "crafts" then
        ns.ProfessionsUI.Toggle("log")
        return true
    end
    if command ~= "plan" then return false end
    -- "tailoring 150" or "tailoring 60-150" (start set by hand).
    local word, a, b = (rest or ""):match("^%s*([%a ]-)%s*(%d*)%-?(%d*)%s*$")
    local prof = Prof.Match(word)
    if prof then
        db().profPlanProf = prof
        if b and b ~= "" then
            Prof.SetStart(ns.Gear.CharKey(), prof, tonumber(a))
            Prof.SetTarget(prof, tonumber(b))
        elseif a and a ~= "" then
            Prof.SetTarget(prof, tonumber(a))
        end
        ns.Print(Prof.Summary(Prof.PlanFor(nil, prof)))
        ns.ProfessionsUI.Show("plan")
    elseif word and word ~= "" then
        ns.Print("unknown profession \"" .. word .. "\". Known: " .. table.concat(Prof.Names(), ", "))
    else
        ns.ProfessionsUI.Toggle("plan")
    end
    return true
end

ns.RegisterModule("Professions", {
    defaults = { profPlanTargets = {}, profPlanFrom = {}, profPlanPatterns = true, profPlanBags = true, profPlanExcluded = {},
        profPlanResale = true,
        craftLogEnabled = true },
    events = { "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "CRAFT_SHOW", "CRAFT_UPDATE",
        "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED",
        "NEW_RECIPE_LEARNED", "LEARNED_SPELL_IN_TAB", "CHAT_MSG_SYSTEM" },
    playerEvents = { "UNIT_SPELLCAST_SUCCEEDED" },
    onEvent = OnEvent,
    slash = Slash,
})
