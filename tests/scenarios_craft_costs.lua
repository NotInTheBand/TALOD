-- Crafting costs: buying many units walks up the price ladder (never the
-- cheapest listing times n), make-or-buy decided for the amount, no price is
-- never a number (materials, learning a pattern), and product resale only as
-- far as the market reaches.
local scenarios, T = ...
local check, boot = T.check, T.boot

local function setup(rank)
    MOCK.skillLines = { { "Professions", true, true }, { "Tailoring", false, nil, rank or 60, 0, 0, 75 },
        { "Secondary Skills", true, true }, { "First Aid", false, nil, 1, 0, 0, 75 } }
    function GetItemCount() return 0 end
    local ns = boot(11509)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    return ns
end

local function Find(node, id)
    if node.id == id and not node.root then return node end
    for _, ch in ipairs(node.children or {}) do
        local f = Find(ch, id)
        if f then return f end
    end
end

-- Defect: every unit was priced at the cheapest listing.
scenarios.craft_costs_buy_depth = function()
    local ns = setup()
    local P, Pr, Track = ns.Professions, ns.Prices, ns.CraftTrack
    local now = time()
    -- Linen: 5 at 30c, the rest at 100c.
    Pr.Record(2589, 30, 205, now, 2, "Linen Cloth")
    Pr.RecordLadder(2589, { { 30, 5, "Al" }, { 100, 200, "Bo" } }, false, now)
    local cost, info = P.BuyCost(2589, 144)
    check(cost == 5 * 30 + 139 * 100 and info.src == "ladder" and info.short == 0 and not info.estimated,
        "144 linen along the ladder: " .. tostring(cost))
    local a = P.BuyCost(2589, 10)
    local b = P.BuyCost(2589, 10, 10)
    check(a + b == P.BuyCost(2589, 20) and a == 5 * 30 + 5 * 100 and b == 1000, "after what was already bought: " .. a .. " + " .. b)
    -- Past the ladder's end: no price for the rest, the priced part kept.
    cost, info = P.BuyCost(2589, 210)
    check(cost == nil and info.short == 5 and info.partial == 5 * 30 + 200 * 100, "short of the ladder: unknown")
    -- A vendor caps every tier and covers what the ladder does not.
    Pr.RecordLadder(2320, { { 5, 3, "Al" }, { 50, 10, "Bo" } }, false, now)
    cost, info = P.BuyCost(2320, 10)
    check(cost == 3 * 5 + 7 * 10 and info.src == "ladder", "thread: 3 listed under the vendor, 7 from the vendor: " .. tostring(cost))
    -- No ladder: the lowest price times n, said to be an estimate.
    Pr.Record(4306, 25, 100, now, 3, "Silk Cloth")
    cost, info = P.BuyCost(4306, 4)
    check(cost == 100 and info.estimated and info.src == "lowest", "no ladder: estimated")
    -- Nothing anywhere: nil, never a placeholder.
    cost, info = P.BuyCost(987654, 3)
    check(cost == nil and info.short == 3 and info.partial == 0 and info.src == "unknown", "no price: unknown")

    -- Planner: the shopping list's linen walks the ladder for the total bought.
    local plan = P.Plan("First Aid", 1, 75, {})
    local linen
    for _, e in ipairs(plan.shopping) do if e.id == 2589 then linen = e end end
    check(linen and linen.buy > 5, "first aid buys linen")
    check(linen.cost == P.BuyCost(2589, linen.buy) and linen.cost > linen.buy * 30,
        "plan linen: " .. tostring(linen.cost) .. " for " .. linen.buy .. " (not " .. linen.buy * 30 .. ")")
    local sum = 0
    for _, step in ipairs(plan.steps) do
        for _, line in ipairs(step.mats or {}) do if line.id == 2589 and line.cost then sum = sum + line.cost end end
    end
    check(sum == linen.cost, "step lines add up to the list: " .. sum)

    -- Tracker: 10 bolts = 20 linen, 2 at 30c and the rest at 120c.
    Pr.RecordLadder(2589, { { 30, 2, "Al" }, { 120, 100, "Bo" } }, false, now)
    local bolt = ns.ProfessionData.recipes[2963]
    local tp = Track.Plan(bolt, 10)
    local ln = Find(tp.root, 2589)
    check(ln and ln.buy == 20 and ln.cost == 2 * 30 + 18 * 120 and tp.buyCost == 2220,
        "tracker: 20 linen = 2,220c, not 600c: " .. tostring(ln and ln.cost))
    -- Make or buy for the amount: 2 bolts listed at 50c, more at 1000c.
    Pr.Record(2996, 50, 12, now, 2, "Bolt of Linen Cloth")
    Pr.RecordLadder(2996, { { 50, 2, "Al" }, { 1000, 10, "Bo" } }, false, now)
    local vest = ns.ProfessionData.recipes[2385]
    local one = Find(Track.Plan(vest, 1).root, 2996)
    check(one and one.buy == 1 and one.cost == 50, "one vest: the 50c bolt beats making it (60c)")
    local ten = Find(Track.Plan(vest, 10).root, 2996)
    check(ten and ten.crafts == 10 and not ten.buy, "ten vests: making the bolts beats 8 at 1000c")
    -- The planner decides the same way for its intermediates.
    local tplan = P.Plan("Tailoring", 1, 75, { known = { ["Bolt of Linen Cloth"] = true } })
    local made
    for _, step in ipairs(tplan.steps) do
        for _, prep in ipairs(step.prep or {}) do if prep.item == 2996 and prep.n > 2 then made = prep end end
    end
    check(made, "planner makes the bolts it needs many of")

    -- The window draws the amounts.
    local UI = ns.CraftTrackUI
    UI.Open(vest)
    UI.Refresh()
    check(UI.IsShown(), "tracker window")
end

-- Defect: a material with no price was counted at 20s a unit.
scenarios.craft_costs_unknown_price = function()
    local ns = setup()
    local P = ns.Professions
    -- Linen with no price at all (no AH look, no Wowhead average, no vendor).
    P.DATA.items[2589].ah = nil
    -- Only Linen Bandage allowed, so the plan has to use it.
    local excluded = {}
    for _, r in ipairs(P.Recipes("First Aid")) do if r.id ~= 3275 then excluded[r.id] = true end end
    local plan = P.Plan("First Aid", 1, 30, { excluded = excluded })
    local linen
    for _, e in ipairs(plan.shopping) do if e.id == 2589 then linen = e end end
    check(linen and linen.buy > 0 and linen.short == linen.buy and linen.cost == 0, "linen: no price for any")
    check(plan.unpriced >= linen.buy and plan.unknownPrices >= 1, "plan counts the units without a price")
    check(plan.materials < linen.buy * 2000, "the placeholder is not in the materials: " .. plan.materials)
    check(plan.total == plan.materials + plan.learn + plan.training, "the priced part adds up")
    local summary = P.Summary(plan)
    check(summary:find("at least") and summary:find("without a price") and not summary:find("20s"), "summary says so: " .. summary)
    check(P.MoneyKnown(0, 3) == "? (3 without a price)" and P.MoneyKnown(150, 0) == "1s 50c", "money texts")

    -- Crafting log value: the priced materials and how many have none.
    local bandage = P.DATA.recipes[3275]
    local each, unpriced = P.ReagentCost(bandage)
    check(each == 0 and unpriced == 1, "bandage materials: unknown, not 2000: " .. tostring(each))

    -- The tab shows "?" for it.
    ns.DB().profPlanProf = "First Aid"
    ns.DB().profPlanTargets["First Aid"] = 30
    ns.DB().profPlanExcluded = excluded
    ns.GearUI.Show("professions")
    local v = ns.GearUI.views.professions
    check(v.left.sub:GetText():find("at least"), "tab summary: " .. v.left.sub:GetText())
    -- The crafting log's totals.
    ns.DB().craftLogEnabled = true
    P.RecordCraft(3275)
    ns.GearUI.Show("crafting")
    local lv = ns.GearUI.views.crafting
    check(lv.left.sub:GetText():find("without a price") or lv.left.sub:GetText():find("unpriced"), "log total: " .. lv.left.sub:GetText())
    P.DATA.items[2589].ah = 41
end

-- Defect: a dropped / quest pattern with no price cost 0 to learn.
scenarios.craft_costs_unknown_learn = function()
    local ns = setup()
    local P = ns.Professions
    local found
    for _, prof in ipairs({ "Tailoring", "Leatherworking", "Blacksmithing", "Alchemy", "Engineering", "Cooking", "First Aid" }) do
        local plan = P.Plan(prof, 1, P.MaxSkill(prof), { patterns = true })
        for _, step in ipairs(plan.steps) do
            if step.kind == "craft" and not step.known and step.learnUnknown then found = plan end
        end
        if found then break end
    end
    check(found, "a plan with a recipe to learn that has no price")
    check(found.unknownLearn > 0, "counted: " .. tostring(found.unknownLearn))
    check(P.TotalText(found):find("at least") and P.LearnText(found):find("without a price"), "shown: " .. P.LearnText(found))
    -- Starter recipes come with the profession: free, not unknown.
    check(P.LearnCost(P.DATA.recipes[2963]) == 0, "starter recipe is free")
end

-- Defect: every product counted at the lowest price, however many.
scenarios.craft_costs_resale = function()
    local ns = setup()
    local P, Pr = ns.Professions, ns.Prices
    local now = time()
    -- Bolts sell for 300c, but only 2 were listed when you looked.
    Pr.Record(2996, 300, 2, now, 1, "Bolt of Linen Cloth")
    local plan = P.Plan("Tailoring", 1, 30, { known = { ["Bolt of Linen Cloth"] = true }, excluded = {} })
    local prod
    for _, p in ipairs(plan.products) do if p.id == 2996 then prod = p end end
    check(prod and prod.n > 2, "bolts left over: " .. tostring(prod and prod.n))
    local value = P.SellValue(2996)
    check(prod.atAH == 2 and prod.worth == 2 * value + (prod.n - 2) * 40,
        "2 at the AH, the rest at the vendor: " .. tostring(prod.worth) .. " (not " .. prod.n * value .. ")")
    check(plan.resale >= prod.worth and plan.net == plan.total - plan.resale, "net")
end
