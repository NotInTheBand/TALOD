-- FishingGear: best fishing gear you own, lures, the apply-lure button,
-- profession plan tags and pool casts guessed from the tooltip.
local scenarios, T = ...
local check = T.check

local function bagItem(slot, id, name, count)
    MOCK.bags[0][slot] = MOCK.ItemLink(id, name)
    if count then MOCK.bagCounts["0:" .. slot] = count end
end

local function hudText()
    local out = {}
    local hud = TALODFishingHUD
    for _, r in ipairs(hud and hud.rows or {}) do
        if r:IsShown() then out[#out + 1] = (r.label:GetText() or "") .. " " .. (r.value:GetText() or "") end
    end
    return table.concat(out, "\n")
end

scenarios.fishing_gear_best = function()
    -- Level 30: the Big Iron Fishing Pole needs level 25.
    local ns = T.fishingSetup(11509, { playerLevel = 30 })
    local G = ns.FishingGear
    -- Bags: Big Iron (+20, Fishing 100), Arcanite (+35, needs Fishing 300), Lucky Fishing Hat (+5).
    bagItem(1, 6367, "Big Iron Fishing Pole")
    bagItem(2, 19970, "Arcanite Fishing Pole")
    bagItem(3, 19972, "Lucky Fishing Hat")
    G.Invalidate()
    local owned = G.Owned()
    local pole, hat, boots = owned[1], owned[2], owned[3]
    check(pole.worn == 0 and pole.better and pole.better.id == 6367 and pole.better.gain == 20,
        "Big Iron is better than the plain pole; Arcanite needs skill 300: " .. tostring(pole.better and pole.better.id))
    check(hat.better and hat.better.id == 19972 and hat.better.gain == 5, "hat in bags beats an empty head")
    check(not boots.better and not boots.best, "no boots")
    MOCK.Tick(1.1)
    check(hudText():find("better in bags:.*Big Iron Fishing Pole %(%+20%)"), "HUD warns about the better pole:\n" .. hudText())

    -- Wear the Big Iron and the hat: nothing better left (Arcanite still too high).
    MOCK.items[6367] = { classID = 2, subclassID = 20, equipLoc = "INVTYPE_2HWEAPON" }
    MOCK.equippedIDs[16], MOCK.equippedIDs[1] = 6367, 19972
    bagItem(1, 6256, "Fishing Pole")
    MOCK.bags[0][3] = nil
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED")
    MOCK.Tick(1.1)
    owned = G.Owned()
    check(owned[1].worn == 20 and not owned[1].better and owned[1].best.id == 6367 and owned[1].best.where == "worn", "worn pole is the best")
    check(owned[2].worn == 5 and not owned[2].better, "worn hat")
    check(not hudText():find("better in bags"), "no warning once worn:\n" .. hudText())
    check(G.GearText():find("Big Iron Fishing Pole"), "gear text: " .. G.GearText())

    -- An unlisted pole: its bonus is unknown, never "worse" than the bags.
    MOCK.items[99999] = { classID = 2, subclassID = 20, equipLoc = "INVTYPE_2HWEAPON" }
    MOCK.equippedIDs[16] = 99999
    G.Invalidate()
    owned = G.Owned()
    check(owned[1].worn == nil and not owned[1].better, "unknown pole: no 'better' claim")

    T.resetOutput()
    T.slash("fish gear")
    check(T.printed("Pole: wearing %?") and T.printed("Hat: wearing Lucky Fishing Hat %+5") and T.printed("Lures: none"), "slash summary")
end

scenarios.fishing_gear_hidden = function()
    local ns = T.fishingSetup(16001, { secrets = true, playerLevel = 30 })
    bagItem(1, 6367, "Big Iron Fishing Pole")
    -- What you wear is hidden: unknown, so nothing in the bags is called better.
    GetInventoryItemID = function() return MOCK.Secret(6256) end
    ns.FishingGear.Invalidate()
    local owned = ns.FishingGear.Owned()
    check(owned[1].worn == nil and not owned[1].better and owned[1].best.id == 6367, "hidden worn item: no warning")
    MOCK.Tick(1.1)
end

scenarios.fishing_gear_lures = function()
    local ns = T.fishingSetup(11509)
    local G = ns.FishingGear
    bagItem(1, 6530, "Nightcrawlers", 5)
    bagItem(2, 6533, "Aquadynamic Fish Attractor", 3)
    bagItem(3, 6529, "Shiny Bauble", 2)
    G.Invalidate()
    local list = G.Lures()
    check(#list == 3 and list[1].id == 6533 and list[1].n == 3 and list[2].id == 6530 and list[3].id == 6529, "lures sorted best first")
    local text = G.LureText()
    check(text:find("^3 Aquadynamic Fish Attractor .-%(%+100%).-, 5 Nightcrawlers .-%(%+50%)"), "lure text: " .. text)
    check(G.PickLure().id == 6533, "best lure")
    TALODDB.fishLurePrefer = "cheap"
    check(G.PickLure().id == 6529, "smallest lure")
    TALODDB.fishLurePrefer = "best"
    -- Skill below a lure's requirement: not picked.
    MOCK.skillLines[2][4] = 60
    MOCK.FireEvent("SKILL_LINES_CHANGED") MOCK.Tick(0.6)
    check(G.PickLure().id == 6530, "Attractor needs Fishing 100: " .. G.PickLure().id)
    check(G.LureText():find("skill too low"), "too-low lure marked")
    MOCK.Tick(1.1)
    check(hudText():find("Lures"), "HUD lures line:\n" .. hudText())
    ns.FishingUI.Show("now")
end

scenarios.fishing_gear_lure_button = function()
    local ns = T.fishingSetup(11509)
    bagItem(1, 6533, "Aquadynamic Fish Attractor", 3)
    bagItem(2, 6530, "Nightcrawlers", 5)
    ns.FishingGear.Invalidate()
    MOCK.Tick(1.1) MOCK.Tick(0.6)
    local b = TALODFishingLureButton
    check(b and b:IsShown(), "lure button shown with the pole on and a lure in the bags")
    check(b._template == "SecureActionButtonTemplate", "secure button")
    check(b:GetAttribute("type") == "macro" and b:GetAttribute("macrotext") == "/use item:6533\n/use 16",
        "macro: " .. tostring(b:GetAttribute("macrotext")))
    b:Fire("OnEnter")

    -- A lure already on: no button (and nothing to /click).
    MOCK.lureMs = 60000
    MOCK.Tick(0.6)
    check(not b:IsShown() and b:GetAttribute("macrotext") == nil, "hidden and cleared while a lure is on")
    MOCK.lureMs = nil
    MOCK.Tick(0.6)
    check(b:IsShown(), "back when the lure runs out")

    -- Combat: hidden, and never touched until it ends.
    local setInCombat = 0
    local orig = b.SetAttribute
    b.SetAttribute = function(self, k, v)
        if MOCK.lockdown then setInCombat = setInCombat + 1 end
        return orig(self, k, v)
    end
    MOCK.FireEvent("PLAYER_REGEN_DISABLED")
    MOCK.lockdown = true
    check(not b:IsShown(), "hidden in combat")
    MOCK.bags[0][1] = nil
    MOCK.FireEvent("BAG_UPDATE_DELAYED")
    MOCK.Tick(0.6) MOCK.Tick(0.6)
    check(setInCombat == 0 and not b:IsShown() and b:GetAttribute("macrotext") == "/use item:6533\n/use 16", "no setup in combat")
    MOCK.lockdown = false
    MOCK.FireEvent("PLAYER_REGEN_ENABLED")
    MOCK.Tick(1.1)
    check(b:IsShown() and b:GetAttribute("macrotext") == "/use item:6530\n/use 16", "after combat: the next lure")

    -- Pole off: the HUD and the button go.
    MOCK.equippedIDs[16] = nil
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED")
    MOCK.Tick(1.1)
    check(not b:IsShown(), "no pole, no button")
    -- Setting off.
    MOCK.equippedIDs[16] = 6256
    TALODDB.fishLureButton = false
    MOCK.Tick(1.1)
    check(not b:IsShown() and b:GetAttribute("type") == nil, "setting off")
end

scenarios.fishing_gear_lure_again = function()
    local ns = T.fishingSetup(11509)
    local G = ns.FishingGear
    bagItem(1, 6530, "Nightcrawlers", 5)
    bagItem(2, 6811, "Aquadynamic Fish Lens", 2)
    bagItem(3, 6533, "Aquadynamic Fish Attractor", 3)
    G.Invalidate()
    MOCK.Tick(1.1) MOCK.Tick(0.6)
    local function again() return TALODFishingLureAgainButton end
    local function macro(id) return "/use item:" .. id .. "\n/use 16" end
    check(not (again() and again():IsShown()), "no lure used yet: nothing to put on again")

    -- A lure used from the bags is remembered; the Lure row gets the button.
    C_Container.UseContainerItem(0, 2)
    check(G.LastLure() == 6811, "remembered from the bag click: " .. tostring(G.LastLure()))
    MOCK.Tick(0.6)
    local b = again()
    check(b and b:IsShown() and b._template == "SecureActionButtonTemplate", "lure-again button shown")
    check(b:GetAttribute("type") == "macro" and b:GetAttribute("macrotext") == macro(6811),
        "macro: " .. tostring(b:GetAttribute("macrotext")))
    check(b.row and b.row.key == "lure" and b.row == ns.FishingUI.HUDRowByKey("lure"), "lies over the Lure row")
    b:Fire("OnEnter")

    -- On the pole and agreeing (+50): still the Lens, also while a lure is on.
    MOCK.lureMs, MOCK.lureEnchant = 300000, 264
    MOCK.Tick(0.6)
    check(b:IsShown() and b:GetAttribute("macrotext") == macro(6811), "same lure while it is on")
    -- A +75 lure (enchant 265, Bright Baubles, measured in game) put on by a
    -- macro: none in the bags, no button; then one is.
    MOCK.lureEnchant = 265
    MOCK.Tick(0.6)
    check(not b:IsShown() and b:GetAttribute("macrotext") == nil, "disagrees with the pole and no +75 lure: hidden")
    bagItem(4, 6532, "Bright Baubles", 4)
    G.Invalidate()
    MOCK.Tick(0.6)
    check(b:IsShown() and b:GetAttribute("macrotext") == macro(6532), "the +75 lure in the bags")
    -- The enchant table can be wrong: the skill modifier (less gear) wins.
    MOCK.lureEnchant = 264
    MOCK.skillLines[2][6] = 75
    MOCK.FireEvent("SKILL_LINES_CHANGED")
    MOCK.Tick(0.6) MOCK.Tick(0.6)
    check(G.MeasuredLureBonus() == 75, "measured bonus: " .. tostring(G.MeasuredLureBonus()))
    check(b:IsShown() and b:GetAttribute("macrotext") == macro(6532), "measured +75 beats the table's +50")
    MOCK.lureEnchant = 265
    MOCK.skillLines[2][6] = 0
    MOCK.FireEvent("SKILL_LINES_CHANGED")
    MOCK.Tick(0.6) MOCK.Tick(0.6)
    -- Run out: the kind last seen still counts.
    MOCK.lureMs = nil
    MOCK.Tick(0.6)
    check(b:IsShown() and b:GetAttribute("macrotext") == macro(6532), "after it runs out")

    -- A click on the apply button remembers its lure.
    local apply = TALODFishingLureButton
    check(apply and apply:IsShown() and apply.lureID == 6533, "apply button: best lure")
    apply:Fire("PostClick", "LeftButton", false)
    MOCK.Tick(0.6)
    check(G.LastLure() == 6533 and b:GetAttribute("macrotext") == macro(6533), "apply click remembered")

    -- Combat: hidden, never set up until it ends.
    local setInCombat = 0
    local orig = b.SetAttribute
    b.SetAttribute = function(self, k, v)
        if MOCK.lockdown then setInCombat = setInCombat + 1 end
        return orig(self, k, v)
    end
    MOCK.FireEvent("PLAYER_REGEN_DISABLED")
    MOCK.lockdown = true
    check(not b:IsShown(), "hidden in combat")
    C_Container.UseContainerItem(0, 1)
    MOCK.Tick(0.6) MOCK.Tick(0.6)
    check(setInCombat == 0 and not b:IsShown(), "no setup in combat")
    MOCK.lockdown = false
    MOCK.FireEvent("PLAYER_REGEN_ENABLED")
    MOCK.Tick(0.6)
    check(b:IsShown() and b:GetAttribute("macrotext") == macro(6530), "after combat: the lure used in combat")

    -- Setting off, then pole off.
    TALODDB.fishLureAgain = false
    MOCK.Tick(0.6)
    check(not b:IsShown() and b:GetAttribute("type") == nil, "setting off")
    TALODDB.fishLureAgain = true
    MOCK.equippedIDs[16] = nil
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED")
    MOCK.Tick(1.1)
    check(not b:IsShown(), "no pole, no button")
end

scenarios.fishing_gear_plan_tag = function()
    local ns = T.fishingSetup(11509)
    local G = ns.FishingGear
    TALODDB.profPlanProf = "Cooking"
    local asked = {}
    ns.Professions.PlanFor = function(_, prof)
        asked[#asked + 1] = prof
        return { shopping = { { id = 6291, need = 12, buy = 8, have = 4 }, { id = 2678, need = 3, buy = 0, have = 3 } } }
    end
    check(G.PlanTag(6291) and G.PlanTag(6291):find("needed: 8 for your Cooking plan"), "tag: " .. tostring(G.PlanTag(6291)))
    check(G.PlanTag(2678):find("plan uses 3"), "have enough")
    check(G.PlanTag(6303) == nil, "not in the plan")
    check(#asked == 1 and asked[1] == "Cooking", "plan computed once (cached)")
    TALODDB.fishPlanTag = false
    check(G.PlanTag(6291) == nil, "setting off")
    TALODDB.fishPlanTag = true
    T.catch({ { 6291, "Raw Brilliant Smallfish", 1 } })
    ns.FishingUI.Show("now")
end

scenarios.fishing_gear_pools = function()
    local ns = T.fishingSetup(11509)
    local G = ns.FishingGear
    local F = ns.Fishing
    local line = MOCK.NewWidget("FontString", "GameTooltipTextLeft1", GameTooltip)
    local tagged = {}
    F.On("start", function(cast) tagged[#tagged + 1] = cast.tags.pool == true end)
    local function hover(text)
        GameTooltip:Hide()
        line:SetText(text)
        GameTooltip:Show()
        GameTooltip:Hide()
    end
    check(G.IsPoolName("Oily Blackmouth School") and G.IsPoolName("Floating Wreckage") and not G.IsPoolName("Kobold Vermin"), "names")

    -- Hovered a pool, then cast: a pool cast.
    hover("Oily Blackmouth School")
    MOCK.Tick(3)
    T.catch({ { 6358, "Oily Blackmouth", 1 } })
    check(tagged[1] == true, "pool cast tagged")
    local t = G.PoolTally(1429, "Crystal Lake")
    check(t and t.n == 1 and t.c == 1 and t.it[6358] == 1, "pool tally")
    -- A cast at the pool without a catch (its result code is Fishing.lua's).
    T.castStart() MOCK.Tick(5) T.castStop() MOCK.Tick(2)
    check(tagged[2] == true and t.n == 2 and t.c == 1, "second pool cast counted, not a catch")

    -- Stale: long after the tooltip, no tag.
    MOCK.Tick(40)
    T.catch({ { 6291, "Raw Brilliant Smallfish", 1 } })
    check(tagged[3] == false and t.n == 2, "stale tooltip: not a pool cast")

    -- A unit's tooltip is no pool, nor is one seen in another subzone.
    local getUnit = GameTooltip.GetUnit
    GameTooltip.GetUnit = function() return "Oily Blackmouth School", "mouseover" end
    hover("Oily Blackmouth School")
    GameTooltip.GetUnit = getUnit
    T.catch({ { 6291, "Raw Brilliant Smallfish", 1 } })
    check(tagged[4] == false, "unit tooltip ignored")
    hover("Floating Wreckage")
    MOCK.subzone = "Elsewhere"
    T.catch({ { 6291, "Raw Brilliant Smallfish", 1 } })
    check(tagged[5] == false, "other subzone: not tagged")
    MOCK.subzone = "Crystal Lake"

    -- Another client language: unknown, never tagged.
    MOCK.Tick(40)
    GetLocale = function() return "deDE" end
    hover("Oily Blackmouth School")
    T.catch({ { 6291, "Raw Brilliant Smallfish", 1 } })
    check(tagged[6] == false, "non-English client: no guess")
    GetLocale = nil

    -- The spot rows and the settings page build; delete all clears the tally.
    ns.FishingUI.Show("spots")
    local page
    for _, p in ipairs(F.settingsTab.pages) do if p.label == "Gear" then page = p end end
    check(page and type(page.build(CreateFrame("Frame"))) == "number", "Gear settings page")
    F.Delete("all")
    check(G.PoolTally(1429, "Crystal Lake") == nil, "pools deleted with all fishing data")
end
