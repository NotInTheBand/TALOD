-- Leveling planner and crafting profit: training at the rank cap, the
-- shopping list's "vendor" only when the plan priced the vendor, recipes the
-- game says you know, and no profit figure from a material with no price.
local scenarios, T = ...
local check, boot = T.check, T.boot

scenarios.prof_plan_fixes = function()
    -- Tailoring read at 75 / 75: the next thing to do is train Journeyman.
    MOCK.skillLines = { { "Professions", true, true }, { "Tailoring", false, nil, 75, 0, 0, 75 } }
    function GetItemCount() return 0 end
    local ns = boot(11509)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    local P, Pr, M = ns.Professions, ns.Prices, ns.Market
    local plan = P.PlanFor(nil, "Tailoring", 150)
    check(plan.steps[1] and plan.steps[1].kind == "train", "at the cap the plan starts with training: "
        .. tostring(plan.steps[1] and plan.steps[1].kind))
    check(plan.training > 0, "training cost counted: " .. tostring(plan.training))

    -- Coarse Thread seen cheaper at the AH than the vendor: the list says AH, as priced.
    local vendor = P.DATA.items[2320].vendor
    Pr.Record(2320, math.max(1, vendor - 5), 20, nil, 1, "Coarse Thread")
    local _, src = P.ItemPrice(2320)
    check(src ~= "vendor" and not P.HowToGet(2320):find("^vendor"), "AH-priced thread not shown as vendor: " .. P.HowToGet(2320))

    -- Recipes the game says you know count as known before the window is read.
    local learnBefore = P.PlanFor(nil, "Tailoring", 150).learn
    IsPlayerSpell = function(id) local r = P.DATA.recipes[id] return r and r.prof == "Tailoring" or false end
    ns.Data.Changed("skills")
    local learnAfter = P.PlanFor(nil, "Tailoring", 150).learn
    check(learnBefore > 0 and learnAfter == 0, "known spells: no learning fees (" .. learnBefore .. " -> " .. learnAfter .. ")")
    IsPlayerSpell = nil

    -- A material nobody has a price for: no profit, cost only the priced part.
    local recipe, missing
    for _, r in pairs(P.DATA.recipes) do
        for _, rg in ipairs(r.reagents or {}) do
            if r.creates and select(2, P.ItemPrice(rg[1])) == "unknown" then recipe, missing = r, rg[1] break end
        end
        if recipe then break end
    end
    check(recipe, "data has a recipe with an unpriced material")
    Pr.Record(recipe.creates, 500000, 1, nil, 1, recipe.name)
    local pr = M.CraftProfit(recipe)
    check(pr.unknown and not pr.priced and pr.profit == nil and pr.value, "unknown material: value shown, no profit ("
        .. recipe.name .. ", item " .. missing .. ")")
    for _, row in ipairs(M.CraftList(ns.Gear.CharKey(), "all")) do
        check(not (row.priced and row.unknown), "craft list never prices an unknown cost")
    end
end
