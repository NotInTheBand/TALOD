-- TALOD - fishing gear, lures and pools: the best fishing gear you own
-- (worn or in your bags) and a warning when something better than what you
-- wear sits in your bags; the lures in your bags and a one-click "apply
-- lure" button; a tag on fish your profession plan needs; and casts at a
-- fishing pool, guessed from the pool's tooltip.
--
-- Bags are bags 0-4 (Economy.ScanBags); the bank is not read (the game
-- tells addons nothing about it unless it is open).
--
-- The lure button is a SecureActionButton (type "macro": "/use item:<lure>"
-- then "/use 16", the classic way to put a lure on the main-hand pole). One
-- click is one lure used, like clicking the lure in your bag; nothing here
-- clicks it, repeats it or times it. Its attributes are only set out of
-- combat and it is hidden when combat starts (the Panel pattern).
--
-- "Lure again": a second secure button of the same kind lies over the HUD's
-- Lure row. One click puts the lure you used last on the pole again (same
-- macro, one lure). The pole's enchant does not name the item (two lures
-- give +50, two +75), so the item is remembered when you use one: from the
-- buttons here or from your bags (a post-hook on UseContainerItem). When the
-- enchant on the pole disagrees with what was remembered (a lure put on by a
-- macro), the lure in your bags with the enchant's bonus is used instead.
-- TALODDB.fishing.lastLure[character] = item ID.
--
-- Pools: addons cannot see fishing pools, but their tooltip names them when
-- you hover one. A cast that starts within POOL_WINDOW seconds of such a
-- tooltip, in the same subzone, is tagged cast.tags.pool. A guess: you may
-- have hovered the pool and cast elsewhere. Only English pool names are
-- known; on other clients no cast is tagged (unknown, never "no pool").
--
-- Data in TALODDB.fishing.pools[mapID][spot] = tally (n, c, a, t, i, it)
-- of the casts tagged as pool casts.

local ADDON_NAME, ns = ...
local S = ns.Secret
local Style = ns.Style
local HEX = Style.HEX
local Fishing = ns.Fishing

local Gear = {}
ns.FishingGear = Gear

local SCAN_CACHE = 1          -- seconds a bag scan is reused
local PLAN_CACHE = 15         -- seconds the profession plans' needs are reused
local POOL_WINDOW = 30        -- a pool tooltip this recent before a cast tags it
local UPDATE_EVERY = 0.5      -- lure button refresh

local function db() return ns.DB() end

---------------------------------------------------------------------------
-- Data. Copied from Wowhead Classic item tooltips (docs/DATA.md):
-- https://nether.wowhead.com/classic/tooltip/item/<id>, read
-- 2026-10-04. bonus = "Equip: Increased Fishing +N"; skill / level = the
-- item's "Requires Fishing (N)" / "Requires Level N".
---------------------------------------------------------------------------
local SLOT_POLE, SLOT_HEAD, SLOT_FEET = 16, 1, 8
local SLOTS = {
    { slot = SLOT_POLE, label = "Pole" },
    { slot = SLOT_HEAD, label = "Hat" },
    { slot = SLOT_FEET, label = "Boots" },
}

local GEAR = {
    [6256] = { slot = SLOT_POLE, bonus = 0, name = "Fishing Pole" },
    [12225] = { slot = SLOT_POLE, bonus = 3, skill = 1, name = "Blump Family Fishing Pole" },
    [6365] = { slot = SLOT_POLE, bonus = 5, skill = 10, level = 5, name = "Strong Fishing Pole" },
    [6366] = { slot = SLOT_POLE, bonus = 15, skill = 50, level = 15, name = "Darkwood Fishing Pole" },
    [6367] = { slot = SLOT_POLE, bonus = 20, skill = 100, level = 25, name = "Big Iron Fishing Pole" },
    [19022] = { slot = SLOT_POLE, bonus = 25, skill = 100, name = "Nat Pagle's Extreme Angler FC-5000" },
    [19970] = { slot = SLOT_POLE, bonus = 35, skill = 300, name = "Arcanite Fishing Pole" },
    [7996] = { slot = SLOT_HEAD, bonus = 5, skill = 1, level = 15, name = "Worn Fishing Hat" },
    [19972] = { slot = SLOT_HEAD, bonus = 5, skill = 1, name = "Lucky Fishing Hat" },
    [19969] = { slot = SLOT_FEET, bonus = 5, skill = 1, name = "Nat Pagle's Extreme Anglin' Boots" },
}
Gear.GEAR = GEAR

-- "Use: When applied to your fishing pole, increases Fishing by N for M min."
local LURES = {
    [6529] = { bonus = 25, minutes = 10, name = "Shiny Bauble" },
    [6530] = { bonus = 50, minutes = 10, skill = 50, name = "Nightcrawlers" },
    [6811] = { bonus = 50, minutes = 10, skill = 50, name = "Aquadynamic Fish Lens" },
    [6532] = { bonus = 75, minutes = 10, skill = 100, name = "Bright Baubles" },
    [7307] = { bonus = 75, minutes = 10, skill = 100, name = "Flesh Eating Worm" },
    [6533] = { bonus = 100, minutes = 5, skill = 100, name = "Aquadynamic Fish Attractor" },
}
Gear.LURES = LURES

-- Fishing pool names (game objects of type 25, "fishing hole"), English
-- client: https://www.wowhead.com/classic/objects/fishing-pools, read
-- 2026-10-04. The patterns catch a renamed or new pool of the same kind.
local POOL_NAMES = {
    ["Floating Wreckage"] = true, ["Floating Debris"] = true, ["Oil Spill"] = true,
    ["Patch of Elemental Water"] = true, ["Sagefish School"] = true, ["Greater Sagefish School"] = true,
    ["Firefin Snapper School"] = true, ["Oily Blackmouth School"] = true, ["School of Deviate Fish"] = true,
    ["Stonescale Eel Swarm"] = true, ["Muddy Churning Waters"] = true,
}
local POOL_PATTERNS = { " School$", "^School of ", " Swarm$", " Wreckage$", " Debris$", " Pool$", "Churning Waters$" }

---------------------------------------------------------------------------
-- What you own
---------------------------------------------------------------------------
local function Bags() return ns.Data.Bags() end
function Gear.Invalidate() ns.Data.Forget("bags") ns.Data.Forget("fishing:planneeds") end

local function Name(id, fallback)
    local name = ns.Market and ns.Market.ItemInfo(id)
    if type(name) == "string" and not name:find("^item %d") then return name end
    return fallback or ("item " .. tostring(id))
end
Gear.Name = Name

-- true / false, or nil when your skill or level is unknown.
local function CanUse(req)
    local rank = Fishing.Skill()
    if req.skill and req.skill > 1 then
        if not rank then return nil end
        if rank < req.skill then return false end
    end
    if req.level then
        local level = S.Call(UnitLevel, "player")
        if type(level) ~= "number" then return nil end
        if level < req.level then return false end
    end
    return true
end

-- The fishing bonus of what you wear in a slot: number, or nil unknown
-- (a hidden item, or a fishing pole this list does not know).
local function WornBonus(slot)
    local id, secret = S.Call(GetInventoryItemID, "player", slot)
    if secret then return nil, nil end
    if type(id) ~= "number" then return 0, nil end
    local g = GEAR[id]
    if g and g.slot == slot then return g.bonus, id end
    if slot == SLOT_POLE and Fishing.PoleEquipped() ~= false then return nil, id end
    return 0, id
end

-- Per slot: { slot, label, worn (bonus or nil), wornID, best = { id, bonus,
-- where }, better = { id, bonus, gain } (only when the bags beat what you
-- wear and what you wear is known), bags = { { id, bonus, usable } } }.
function Gear.Owned()
    local bags = Bags()
    local out = {}
    for _, def in ipairs(SLOTS) do
        local worn, wornID = WornBonus(def.slot)
        local e = { slot = def.slot, label = def.label, worn = worn, wornID = wornID, bags = {} }
        for id, it in pairs(bags) do
            local g = GEAR[id]
            if g and g.slot == def.slot then
                e.bags[#e.bags + 1] = { id = id, bonus = g.bonus, usable = CanUse(g), n = it.n }
            end
        end
        table.sort(e.bags, function(a, b) return a.bonus > b.bonus or (a.bonus == b.bonus and a.id < b.id) end)
        -- An item you cannot use yet is never "better"; unknown (skill not
        -- read) is offered, the game will say no if it must.
        local bestBag
        for _, b in ipairs(e.bags) do
            if b.usable ~= false then bestBag = b break end
        end
        if worn and wornID and GEAR[wornID] then e.best = { id = wornID, bonus = worn, where = "worn" } end
        if bestBag and (not e.best or bestBag.bonus > e.best.bonus) then
            e.best = { id = bestBag.id, bonus = bestBag.bonus, where = "bags" }
        end
        if bestBag and worn and bestBag.bonus > worn then
            e.better = { id = bestBag.id, bonus = bestBag.bonus, gain = bestBag.bonus - worn }
        end
        out[#out + 1] = e
    end
    return out
end

-- Lures in your bags: { { id, n, bonus, minutes, usable } }, best first.
function Gear.Lures()
    local out = {}
    for id, it in pairs(Bags()) do
        local l = LURES[id]
        if l then out[#out + 1] = { id = id, n = it.n, bonus = l.bonus, minutes = l.minutes, usable = CanUse(l) } end
    end
    table.sort(out, function(a, b)
        if a.bonus ~= b.bonus then return a.bonus > b.bonus end
        if a.minutes ~= b.minutes then return a.minutes > b.minutes end
        return a.id < b.id
    end)
    return out
end

-- The lure the button uses: the highest bonus, or with fishLurePrefer
-- "cheap" the smallest one (lures cost more the more they give).
function Gear.PickLure()
    local list = Gear.Lures()
    local pick
    for _, l in ipairs(list) do
        if l.usable ~= false then
            if db().fishLurePrefer ~= "cheap" then return l end
            pick = l
        end
    end
    return pick
end

-- The bonus of the lure last seen on the pole (this session): after it runs
-- out it still says which kind you had, until you use another.
local seenBonus

-- The lure item you used last on this character.
local function CharKey() return ns.Gear and ns.Gear.CharKey and ns.Gear.CharKey() or "?" end

function Gear.LastLure()
    local t = Fishing.Store().lastLure
    local id = type(t) == "table" and t[CharKey()] or nil
    return (id and LURES[id]) and id or nil
end

function Gear.RememberLure(id)
    if not (id and LURES[id]) then return end
    local f = Fishing.Store()
    if type(f.lastLure) ~= "table" then f.lastLure = {} end
    f.lastLure[CharKey()] = id
    seenBonus = nil
end

-- The bonus of the lure on the pole, measured: your Fishing skill modifier
-- less what your pole, hat and boots give. Preferred over the enchant ID
-- table (an ID there was wrong once). nil when a part is unknown or the
-- rest is no lure's bonus.
function Gear.MeasuredLureBonus()
    local rank, mod = Fishing.Skill()
    if not rank or type(mod) ~= "number" then return nil end
    local gear = 0
    for _, def in ipairs(SLOTS) do
        local b = WornBonus(def.slot)
        if b == nil then return nil end
        gear = gear + b
    end
    local bonus = mod - gear
    for _, l in pairs(LURES) do
        if l.bonus == bonus then return bonus end
    end
    return nil
end

-- The lure "Lure again" uses: the remembered one while it agrees with the
-- pole's enchant, else one in your bags with that enchant's bonus. nil when
-- none is known or none is left.
function Gear.AgainLure()
    local on, _, enchant = Fishing.Lure()
    local bonus
    if on == true then bonus = Gear.MeasuredLureBonus() or (enchant and Fishing.LURE_BONUS[enchant]) end
    if bonus then seenBonus = bonus end
    bonus = bonus or seenBonus
    local last = Gear.LastLure()
    local fallback
    for _, l in ipairs(Gear.Lures()) do
        if l.usable ~= false then
            if l.id == last and (not bonus or l.bonus == bonus) then return l end
            if bonus and l.bonus == bonus and not fallback then fallback = l end
        end
    end
    return fallback
end

local function BagItemID(bag, slot)
    local api = C_Container or {}
    local fn = api.GetContainerItemID or GetContainerItemID
    local id = type(fn) == "function" and S.Call(fn, bag, slot) or nil
    if type(id) == "number" then return id end
    fn = api.GetContainerItemLink or GetContainerItemLink
    local link = type(fn) == "function" and S.Call(fn, bag, slot) or nil
    return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

-- A lure used from the bags (a click on it there): remember which.
local function HookBagUse()
    local function OnUse(bag, slot)
        if type(bag) ~= "number" or type(slot) ~= "number" then return end
        Gear.RememberLure(BagItemID(bag, slot))
    end
    if C_Container and type(C_Container.UseContainerItem) == "function" then
        hooksecurefunc(C_Container, "UseContainerItem", function(bag, slot) ns.SafeCall(OnUse, bag, slot) end)
    end
    if type(UseContainerItem) == "function" and UseContainerItem ~= (C_Container and C_Container.UseContainerItem) then
        hooksecurefunc("UseContainerItem", function(bag, slot) ns.SafeCall(OnUse, bag, slot) end)
    end
end

function Gear.MacroText(id) return "/use item:" .. id .. "\n/use " .. SLOT_POLE end

---------------------------------------------------------------------------
-- Text
---------------------------------------------------------------------------
local function Bonus(n) return n and ("+" .. n) or "+?" end

function Gear.GearText()
    local parts, any = {}, false
    for _, e in ipairs(Gear.Owned()) do
        if e.best or e.worn == nil then
            any = true
            local text
            if e.better then
                text = string.format("%s: %s%s %s in bags (+%d over yours)|r", e.label, HEX.gold, Name(e.better.id, GEAR[e.better.id].name),
                    Bonus(e.better.bonus), e.better.gain)
            elseif e.best then
                text = string.format("%s: %s %s%s|r", e.label, Name(e.best.id, GEAR[e.best.id].name), HEX.good, Bonus(e.best.bonus))
                    .. (e.best.where == "bags" and (HEX.muted .. " (bags)|r") or "")
            else
                text = e.label .. ": " .. HEX.dim .. "?|r"
            end
            parts[#parts + 1] = text
        end
    end
    if not any then return HEX.muted .. "no fishing gear worn or in your bags|r" end
    return table.concat(parts, HEX.muted .. "  ·  |r")
end

function Gear.LureText(max)
    local list = Gear.Lures()
    if #list == 0 then return nil end
    local parts = {}
    for i, l in ipairs(list) do
        if max and i > max then
            parts[#parts + 1] = HEX.muted .. "+" .. (#list - max) .. " more|r"
            break
        end
        parts[#parts + 1] = string.format("%d %s %s(%s)|r%s", l.n, Name(l.id, LURES[l.id].name), HEX.good, Bonus(l.bonus),
            l.usable == false and (HEX.bad .. " skill too low|r") or "")
    end
    return table.concat(parts, ", ")
end

function Gear.SummaryLines()
    local lines = {}
    for _, e in ipairs(Gear.Owned()) do
        local worn = e.worn == nil and "?" or (e.wornID and GEAR[e.wornID] and (Name(e.wornID, GEAR[e.wornID].name) .. " " .. Bonus(e.worn)) or "nothing for fishing")
        local line = e.label .. ": wearing " .. worn
        if e.better then
            line = line .. "; better in your bags: " .. Name(e.better.id, GEAR[e.better.id].name) .. " " .. Bonus(e.better.bonus)
                .. " (+" .. e.better.gain .. ")"
        end
        lines[#lines + 1] = line
    end
    lines[#lines + 1] = "Lures: " .. (Gear.LureText() or "none in your bags")
    local pick = Gear.PickLure()
    if pick then
        lines[#lines + 1] = "Lure button uses: " .. Name(pick.id, LURES[pick.id].name) .. " (/click " .. ns.FRAME .. "FishingLureButton)"
    end
    return lines
end

---------------------------------------------------------------------------
-- Profession plans: fish (or anything) your plans still need
---------------------------------------------------------------------------
-- { [itemID] = { need, buy, prof } } over your planned professions: the one
-- chosen in the Professions tab, and Cooking when you have it.
-- Planning is heavy: kept until the bags or the plan change (PLAN_CACHE
-- seconds at most, for skill-ups and prices).
function Gear.PlanNeeds()
    return ns.Data.Memo("fishing:planneeds", ns.Data.Key("bags") .. "|" .. tostring(db().profPlanProf) .. "|"
        .. tostring(ns.Gear.CharKey()), Gear.BuildPlanNeeds, PLAN_CACHE)
end

function Gear.BuildPlanNeeds()
    local out = {}
    local P = ns.Professions
    if P and P.PlanFor and P.DATA then
        local profs, seen = {}, {}
        local function Add(p) if p and P.DATA.ranks[p] and not seen[p] then seen[p] = true profs[#profs + 1] = p end end
        Add(db().profPlanProf)
        local c = db().skills and db().skills[ns.Gear.CharKey() or ""]
        if c and c.current and c.current.Cooking then Add("Cooking") end
        for _, prof in ipairs(profs) do
            local plan = P.PlanFor(nil, prof)
            for _, e in ipairs(plan.shopping or {}) do
                if (e.need or 0) > 0 then
                    local cur = out[e.id]
                    if not cur then
                        out[e.id] = { need = e.need, buy = e.buy or 0, prof = prof }
                    else
                        cur.need, cur.buy = cur.need + e.need, cur.buy + (e.buy or 0)
                        cur.prof = cur.prof .. " / " .. prof
                    end
                end
            end
        end
    end
    return out
end

function Gear.PlanTag(id)
    if not db().fishPlanTag then return nil end
    local e = Gear.PlanNeeds()[id]
    if not e then return nil end
    if e.buy > 0 then return string.format("%sneeded: %d for your %s plan|r", HEX.accent, e.buy, e.prof) end
    return string.format("%syour %s plan uses %d (in your bags)|r", HEX.muted, e.prof, e.need)
end

---------------------------------------------------------------------------
-- Pools, from the tooltip
---------------------------------------------------------------------------
local lastPool        -- { at, name, sub }

function Gear.IsPoolName(text)
    if type(text) ~= "string" or text == "" then return false end
    if POOL_NAMES[text] then return true end
    for _, p in ipairs(POOL_PATTERNS) do
        if text:find(p) then return true end
    end
    return false
end

-- Pool names are English only: another client language is unknown.
local function EnglishClient()
    local locale = S.Call(GetLocale)
    return type(locale) ~= "string" or locale == "enUS" or locale == "enGB"
end

local function SeenPool(text)
    if not Gear.IsPoolName(text) then return end
    lastPool = { at = GetTime(), name = text, sub = Fishing.Place().sub }
end

-- A world-object tooltip: no unit, no item, owned by UIParent (the default
-- anchor). Any of these hidden counts as "not a pool".
local function ReadGameTooltip()
    if not db().fishPoolTag or not EnglishClient() then return end
    local tip = GameTooltip
    if not tip or S.Call(tip.IsShown, tip) ~= true then return end
    local ok, name, unit = pcall(tip.GetUnit, tip)
    if not ok or type(name) ~= "nil" or type(unit) ~= "nil" then return end
    local okItem, itemName, link = pcall(tip.GetItem, tip)
    if not okItem or type(itemName) ~= "nil" or type(link) ~= "nil" then return end
    local owner, ownerSecret = S.Call(tip.GetOwner, tip)
    if ownerSecret or (owner ~= nil and owner ~= UIParent) then return end
    local line = _G.GameTooltipTextLeft1
    local text = line and S.Call(line.GetText, line)
    SeenPool(text)
end
Gear.ReadGameTooltip = ReadGameTooltip

-- Newer clients describe the tooltip as data: a game object's first line.
local function OnTooltipData(tooltip, data)
    if tooltip ~= GameTooltip or not db().fishPoolTag or not EnglishClient() then return end
    data = S.Value(data)
    local lines = type(data) == "table" and S.Value(data.lines)
    local first = type(lines) == "table" and S.Value(lines[1])
    SeenPool(type(first) == "table" and S.Value(first.leftText) or nil)
end

local hooked = false
local function HookTooltip()
    if hooked or not GameTooltip then return end
    hooked = true
    if GameTooltip.HookScript then
        GameTooltip:HookScript("OnShow", function() ns.SafeCall(ReadGameTooltip) end)
    end
    local TDP = TooltipDataProcessor
    local objectType = Enum and Enum.TooltipDataType and Enum.TooltipDataType.Object
    if type(TDP) == "table" and type(TDP.AddTooltipPostCall) == "function" and objectType then
        pcall(TDP.AddTooltipPostCall, objectType, function(tooltip, data) ns.SafeCall(OnTooltipData, tooltip, data) end)
    end
end

-- The pool read for a cast starting now in subzone `sub`, or nil.
function Gear.RecentPool(sub)
    if not lastPool or GetTime() - lastPool.at > POOL_WINDOW then return nil end
    if sub and lastPool.sub ~= sub then return nil end
    return lastPool
end

local function PoolStore()
    local f = Fishing.Store()
    if type(f.pools) ~= "table" then f.pools = {} end
    return f.pools
end
Gear.PoolStore = PoolStore

function Gear.PoolTally(mapID, spot)
    local m = PoolStore()[mapID]
    return m and m[spot]
end

local function OnCastStart(cast)
    if not db().fishPoolTag then return end
    if Gear.RecentPool(cast.place and cast.place.sub) then
        cast.tags = cast.tags or {}
        cast.tags.pool = true
    end
end

local function OnCastFinish(cast, result)
    if not (cast.tags and cast.tags.pool) then return end
    local p = cast.place
    if not (p and p.mapID and p.sub) then return end
    local pools = PoolStore()
    pools[p.mapID] = pools[p.mapID] or {}
    local t = pools[p.mapID][p.sub]
    if not t then
        t = Fishing.NewTally()
        pools[p.mapID][p.sub] = t
    end
    t.n = (t.n or 0) + 1
    t[result] = (t[result] or 0) + 1
    if result == "c" then
        t.it = t.it or {}
        for id, n in pairs(cast.items or {}) do t.it[id] = (t.it[id] or 0) + n end
    end
end

---------------------------------------------------------------------------
-- The lure button
---------------------------------------------------------------------------
local button, combatLocked, lastUpdate = nil, false, -math.huge

local function ButtonTooltip(self)
    local l = self.lureID and LURES[self.lureID]
    if not l then return end
    ns.Tooltip.Text(self, {
        "Apply " .. Name(self.lureID, l.name),
        string.format("+%d Fishing for %d min. One click uses one lure on your fishing pole (main hand).", l.bonus, l.minutes),
        "Picks " .. (db().fishLurePrefer == "cheap" and "your smallest lure" or "your best lure") .. " (Fishing settings > Gear).",
        "Keybind: a macro with /click " .. ns.FRAME .. "FishingLureButton",
        HEX.muted .. "Set up out of combat only; hidden in combat.|r",
    })
end

local function CreateButton()
    if button or InCombatLockdown() then return button end
    local ok, b = pcall(CreateFrame, "Button", ns.FRAME .. "FishingLureButton", UIParent, "SecureActionButtonTemplate")
    if not ok or not b then return nil end
    b:RegisterForClicks("AnyUp", "AnyDown")
    b:SetSize(200, 20)
    Style.Surface(b, "hud")
    b.iconFrame, b.icon = Style.IconFrame(b, 16)
    b.iconFrame:SetPoint("LEFT", 2, 0)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.label = Style.Text(b, "GameFontHighlightSmall")
    b.label:SetPoint("LEFT", 22, 0)
    b.label:SetPoint("RIGHT", -6, 0)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    b:SetScript("OnEnter", ButtonTooltip)
    b:SetScript("OnLeave", function() ns.Tooltip.Hide() end)
    b:HookScript("PostClick", function(self) Gear.RememberLure(self.lureID) end)
    b:Hide()
    button = b
    return b
end

local function ClearButton()
    if not button or button.lureID == nil then return end
    button:SetAttribute("type", nil)
    button:SetAttribute("macrotext", nil)
    button.lureID = nil
end

function Gear.UpdateButton()
    if combatLocked or InCombatLockdown() then return end
    local hud = ns.FishingUI and ns.FishingUI.HUDFrame()
    local pick
    local want = db().fishLureButton and db().fishingEnabled and hud ~= nil and hud:IsShown()
        and Fishing.PoleEquipped() == true and Fishing.Lure() ~= true
    if want then pick = Gear.PickLure() end
    if not pick then
        if button then
            ClearButton()
            if button:IsShown() then button:Hide() end
        end
        return
    end
    local b = CreateButton()
    if not b then return end
    if b.lureID ~= pick.id then
        b:SetAttribute("type", "macro")
        b:SetAttribute("macrotext", Gear.MacroText(pick.id))
        b.lureID = pick.id
    end
    b.icon:SetTexture(Fishing.ItemIcon(pick.id))
    b.label:SetText(string.format("Apply %s %s(+%d)|r  %sx%d|r", Name(pick.id, LURES[pick.id].name), HEX.good, pick.bonus, HEX.muted, pick.n))
    b:SetScale(hud:GetScale() or 1)
    b:SetFrameStrata(hud:GetFrameStrata() or "MEDIUM")
    b:SetWidth(hud:GetWidth() or 200)
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", hud, "BOTTOMLEFT", 0, -2)
    b:Show()
end

---------------------------------------------------------------------------
-- Lure again: the secure button over the HUD's Lure row
---------------------------------------------------------------------------
local again

local function AgainTooltip(self)
    local l = self.lureID and LURES[self.lureID]
    if not l then return end
    local on, left = Fishing.Lure()
    ns.Tooltip.Text(self, {
        "Lure",
        on == true and ("On your pole" .. (left and string.format(", %d:%02d left", math.floor(left / 60), math.floor(left % 60)) or "") .. ".")
            or "A lure on your pole raises your skill while it lasts.",
        HEX.good .. "Click: put " .. Name(self.lureID, l.name) .. " on again|r " .. string.format("(+%d for %d min, %d in your bags).", l.bonus, l.minutes, self.count or 0),
        "One click uses one lure on your fishing pole (main hand).",
        HEX.muted .. "Set up out of combat only; hidden in combat.|r",
    })
end

local function CreateAgain()
    if again or InCombatLockdown() then return again end
    local ok, b = pcall(CreateFrame, "Button", ns.FRAME .. "FishingLureAgainButton", UIParent, "SecureActionButtonTemplate")
    if not ok or not b then return nil end
    b:RegisterForClicks("AnyUp", "AnyDown")
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    b.hint = Style.Text(b, "GameFontHighlightSmall")
    b.hint:SetPoint("RIGHT", -6, 0)
    b.hint:SetJustifyH("RIGHT")
    b:SetScript("OnEnter", AgainTooltip)
    b:SetScript("OnLeave", function() ns.Tooltip.Hide() end)
    b:HookScript("PostClick", function(self) Gear.RememberLure(self.lureID) end)
    b:Hide()
    again = b
    return b
end

local function ClearAgain()
    if not again then return end
    if again.lureID ~= nil then
        again:SetAttribute("type", nil)
        again:SetAttribute("macrotext", nil)
        again.lureID = nil
    end
    again.row = nil
    if again:IsShown() then again:Hide() end
end

-- Runs after every HUD redraw (its rows can move) and on the button tick.
function Gear.UpdateAgain()
    if combatLocked or InCombatLockdown() then return end
    local UI = ns.FishingUI
    local row = UI and UI.HUDRowByKey and UI.HUDRowByKey("lure")
    local pick
    if row and db().fishLureAgain and db().fishingEnabled and Fishing.PoleEquipped() == true then pick = Gear.AgainLure() end
    if not pick then return ClearAgain() end
    local b = CreateAgain()
    if not b then return end
    if b.lureID ~= pick.id then
        b:SetAttribute("type", "macro")
        b:SetAttribute("macrotext", Gear.MacroText(pick.id))
        b.lureID = pick.id
    end
    b.count = pick.n
    b.hint:SetText(HEX.muted .. "click: " .. Name(pick.id, LURES[pick.id].name) .. " again|r")
    if b.row ~= row then
        local hud = UI.HUDFrame()
        b:SetScale(hud and hud:GetScale() or 1)
        b:SetFrameStrata(hud and hud:GetFrameStrata() or "MEDIUM")
        b:SetFrameLevel((row:GetFrameLevel() or 1) + 5)
        b:ClearAllPoints()
        b:SetAllPoints(row)
        b.row = row
    end
    if not b:IsShown() then b:Show() end
end

-- Secure frames cannot be hidden or moved in combat: away before it starts.
local function EnterCombat()
    combatLocked = true
    if button then
        button:Hide()
        button:ClearAllPoints()
    end
    if again then
        again:Hide()
        again:ClearAllPoints()
        again.row = nil
    end
end

---------------------------------------------------------------------------
-- Window, HUD, settings, slash
---------------------------------------------------------------------------
local UI = ns.FishingUI

UI.AddNowRows(function(rows)
    if not db().fishGearShow then return end
    rows[#rows + 1] = { label = "Gear", text = Gear.GearText(),
        tooltip = function(o) ns.Tooltip.Text(o, { "Fishing gear you own", "Best fishing pole, hat and boots, worn or in your bags (not the bank).",
            "Gold: something better than what you wear is in your bags." }) end }
    rows[#rows + 1] = { label = "Lures", text = Gear.LureText() or (HEX.muted .. "none in your bags|r") }
end)

UI.AddHUDLine(function()
    if not db().fishGearWarn then return nil end
    for _, e in ipairs(Gear.Owned()) do
        if e.better then
            return { key = "gear", label = "Gear", warn = true, icon = Fishing.ItemIcon(e.better.id),
                value = string.format("%sbetter in bags:|r %s (+%d)", HEX.gold, Name(e.better.id, GEAR[e.better.id].name), e.better.gain),
                tip = { "Better fishing gear in your bags", e.label .. ": " .. Name(e.better.id, GEAR[e.better.id].name) .. " " .. Bonus(e.better.bonus)
                    .. ", " .. e.better.gain .. " more than what you wear." } }
        end
    end
    return nil
end)

UI.AddHUDLine(function()
    if not db().fishGearShow then return nil end
    local text = Gear.LureText(2)
    if not text then return nil end
    local pick = Gear.PickLure()
    return { key = "lures", label = "Lures", value = text, icon = pick and Fishing.ItemIcon(pick.id) or nil,
        tip = { "Lures in your bags", Gear.LureText() or "", "The button under the HUD applies one (Fishing settings > Gear)." } }
end)

UI.AddItemTag(function(id) return Gear.PlanTag(id) end)

UI.AddSpotRows(function(rows, mapID, name)
    local t = Gear.PoolTally(mapID, name)
    if not t or (t.n or 0) == 0 then return end
    local tries = (t.c or 0) + (t.a or 0)
    rows[#rows + 1] = { label = "Pools", text = string.format("Pool casts here: %d, catch rate %s %s(guessed from the pool tooltip)|r", t.n,
        tries > 0 and (math.floor((t.c or 0) / tries * 100 + 0.5) .. "%") or "?", HEX.muted),
        tooltip = function(o) ns.Tooltip.Text(o, { "Pool casts (a guess)", "Casts that started within " .. POOL_WINDOW
            .. " s of hovering a fishing pool here (its tooltip). You may have cast elsewhere: it is a guess.",
            "Only English pool names are known." }) end }
end)

UI.OnHUDUpdated(function() Gear.UpdateAgain() end)

UI.OnHUDBuilt(function(hud)
    if hud.HookScript then
        hud:HookScript("OnShow", function() ns.SafeCall(Gear.UpdateButton) end)
        hud:HookScript("OnHide", function() ns.SafeCall(Gear.UpdateButton) end)
    end
end)

Fishing.On("start", OnCastStart)
Fishing.On("finish", OnCastFinish)

Fishing.AddSlash(function(arg)
    if arg ~= "gear" and arg ~= "lures" then return false end
    for _, line in ipairs(Gear.SummaryLines()) do ns.Print(line) end
    return true
end, "gear")

local function BuildPage(parent)
    local W = ns.Options.Widgets
    local y = -12
    y = W.Paragraph(parent, y, "Your best fishing pole, hat and boots (worn or in your bags), the lures you carry, a button that "
        .. "applies one, what your profession plans need, and casts at fishing pools.", "GameFontHighlightSmall")
    y = W.Header(parent, y, "Gear and lures")
    y = W.Checkbox(parent, y, "fishGearShow", "Show fishing gear and lures", "In the fishing window (Now) and a Lures line on the HUD.")
    y = W.Checkbox(parent, y, "fishGearWarn", "Warn when better fishing gear is in my bags",
        "A HUD line when a pole, hat or boots in your bags give more Fishing than what you wear.")
    y = W.Checkbox(parent, y, "fishLureButton", "Apply-lure button under the HUD",
        "Shown while your pole is equipped, no lure is on and a lure is in your bags. One click uses one lure on your pole. "
        .. "Keybind: a macro with /click " .. ns.FRAME .. "FishingLureButton. Set up out of combat only; hidden in combat.")
    y = W.Checkbox(parent, y, "fishLureAgain", "Click the HUD's Lure line to use the same lure again",
        "One click puts the lure you used last on your pole again (one lure, from your bags). Set up out of combat only; hidden in combat.")
    y = W.Cycle(parent, y, "fishLurePrefer", "The button uses", {
        { value = "best", label = "my best lure" }, { value = "cheap", label = "my smallest lure" } })
    y = W.Header(parent, y, "Plans and pools")
    y = W.Checkbox(parent, y, "fishPlanTag", "Tag fish my profession plan needs",
        "In the catch lists: \"needed: N for your Cooking plan\" (the profession chosen in the Professions tab, and Cooking).")
    y = W.Checkbox(parent, y, "fishPoolTag", "Guess pool casts from the pool tooltip",
        "Hover a fishing pool (\"Oily Blackmouth School\", \"Floating Wreckage\") before you cast: casts within "
        .. POOL_WINDOW .. " s in the same place count as pool casts. English pool names only.")
    y = W.Header(parent, y, "Now")
    y = W.LiveText(parent, y, 60, function() return table.concat(Gear.SummaryLines(), "\n") end)
    return -y + 10
end

table.insert(Fishing.settingsTab.pages, { label = "Gear", build = BuildPage })

local function OnEvent(event)
    if event == "PLAYER_REGEN_DISABLED" then
        EnterCombat()
    elseif event == "PLAYER_REGEN_ENABLED" then
        combatLocked = false
        Gear.UpdateButton()
        Gear.UpdateAgain()
    elseif event == "BAG_UPDATE_DELAYED" or event == "PLAYER_EQUIPMENT_CHANGED" or event == "BAG_UPDATE" then
        lastUpdate = -math.huge
    end
end

ns.RegisterModule("FishingGear", {
    defaults = {
        fishGearShow = true,
        fishGearWarn = true,
        fishLureButton = true,
        fishLurePrefer = "best",
        fishLureAgain = true,
        fishPlanTag = true,
        fishPoolTag = true,
    },
    events = { "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "BAG_UPDATE_DELAYED", "BAG_UPDATE", "PLAYER_EQUIPMENT_CHANGED" },
    init = function()
        HookTooltip()
        HookBagUse()
    end,
    onEvent = OnEvent,
    tick = function()
        -- A tooltip that stays up while the mouse rests on a pool keeps it fresh.
        if Fishing.PoleEquipped() == true then ReadGameTooltip() end
        if GetTime() - lastUpdate >= UPDATE_EVERY then
            lastUpdate = GetTime()
            Gear.UpdateButton()
            Gear.UpdateAgain()
        end
    end,
})
