-- TALOD - Professions tab of the character window: pick a profession
-- and a target skill; the left side is the shopping list (need, have, buy,
-- estimated cost), the right side the steps in order (train, make first,
-- then craft N of a recipe from skill A to B). Right-click a step to stop
-- using that recipe (a pattern you cannot get); the plan is redone.

local ADDON_NAME, ns = ...
local S = ns.Secret
local Style = ns.Style
local COLORS, HEX = Style.COLORS, Style.HEX
local Prof = ns.Professions
local Money = Prof.Money

local QUALITY_HEX = { [0] = "|cff9d9d9d", [1] = "|cffffffff", [2] = "|cff1eff00", [3] = "|cff0070dd", [4] = "|cffa335ee", [5] = "|cffff8000" }
local COLOR_HEX = { orange = "|cffff8040", yellow = "|cffffff00", green = "|cff40c040", grey = "|cff808080" }
local PRESETS = { 75, 150, 225, 300 }

local function db() return ns.DB() end

local function ItemText(id)
    local it = Prof.Item(id)
    return (QUALITY_HEX[it and it.q or 1] or HEX.white) .. Prof.ItemName(id) .. "|r"
end

local function Colored(color, text) return (COLOR_HEX[color] or "") .. text .. "|r" end

-- Professions in the cycle: the character's own first, then the rest.
local function ProfOrder(charKey)
    local c = charKey and db().skills and db().skills[charKey]
    local mine, rest = {}, {}
    for _, name in ipairs(Prof.Names()) do
        if c and c.current and c.current[name] then mine[#mine + 1] = name else rest[#rest + 1] = name end
    end
    for _, name in ipairs(rest) do mine[#mine + 1] = name end
    return mine, c
end

local function CurrentProf(charKey)
    local order, c = ProfOrder(charKey)
    local p = db().profPlanProf
    if p and Prof.DATA.ranks[p] then return p, order, c end
    -- Default: the first crafting profession you have.
    return order[1], order, c
end

local function RecipeTooltip(owner, step)
    local r = step.recipe
    local lines = { HEX.gold .. r.name .. "|r", string.format("%s: learned at %d", r.prof, r.skill),
        string.format("%s%d|r  %s%d|r  %s%d|r  %s%d|r  (orange, yellow, green, grey from)",
            COLOR_HEX.orange, r.colors[1], COLOR_HEX.yellow, r.colors[2], COLOR_HEX.green, r.colors[3], COLOR_HEX.grey, r.colors[4]) }
    lines[#lines + 1] = string.format("Skill %d -> %d: about %d crafts (%.1f expected)", step.from, step.to, step.crafts, step.expect)
    lines[#lines + 1] = string.format("Chance of a point: %d%% at %d, %d%% at %d",
        math.floor(Prof.Chance(r, step.from) * 100 + 0.5), step.from, math.floor(Prof.Chance(r, step.to - 1) * 100 + 0.5), step.to - 1)
    lines[#lines + 1] = " "
    lines[#lines + 1] = "Per craft:"
    for _, rg in ipairs(r.reagents) do
        lines[#lines + 1] = string.format("  %d x %s  %s(%s)|r", rg[2], ItemText(rg[1]), HEX.muted, Prof.HowToGet(rg[1]))
    end
    for _, tid in ipairs(r.tools or {}) do lines[#lines + 1] = "  tool: " .. ItemText(tid) end
    if r.creates then lines[#lines + 1] = "Makes " .. (r.makes or 1) .. " x " .. ItemText(r.creates) end
    lines[#lines + 1] = " "
    if step.known then
        lines[#lines + 1] = HEX.good .. "You know this recipe.|r"
    elseif step.pattern then
        lines[#lines + 1] = HEX.gold .. "Taught by " .. (r.pattern and ItemText(r.pattern) or "a recipe item") .. HEX.gold
            .. ", not by the trainer.|r"
        lines[#lines + 1] = "From: " .. table.concat(r.src or {}, ", "):gsub("^pattern,? ?", "")
            .. (r.patternPrice and (" (vendor " .. Money(r.patternPrice) .. ")") or "")
    else
        lines[#lines + 1] = "Learned from: " .. table.concat(r.src or {}, ", ") .. (r.cost and (" (" .. Money(r.cost) .. ")") or "")
            .. (r.guess and (HEX.muted .. "  (Wowhead lists no source: probably the trainer)|r") or "")
    end
    lines[#lines + 1] = HEX.accent .. "Click: craft " .. step.crafts .. " (your " .. r.prof .. " window must be open).|r"
    lines[#lines + 1] = HEX.muted .. "Right-click: don't use this recipe (the plan is redone).|r"
    ns.Tooltip.Text(owner, lines)
end

local MaterialRows

local CHECK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t "

-- One step's materials as to-do lines, what has to happen first on top:
-- an intermediate's own materials, then "Make" it; "Get" what you must buy
-- or gather; a check for what you already have (bags, or made above).
MaterialRows = function(out, lines, indent)
    for _, line in ipairs(lines) do
        if line.children then MaterialRows(out, line.children, indent + 14) end
        local got = {}
        if line.have then got[#got + 1] = line.have .. " in your bags" end
        if line.made then got[#got + 1] = line.made .. " made above" end
        local gotText = #got > 0 and table.concat(got, ", ") or nil
        local row = { indent = indent, label = "", icon = Prof.ItemIcon(line.id) }
        if line.buy then
            row.text = HEX.gold .. "Get " .. line.buy .. "|r x " .. ItemText(line.id) .. HEX.muted .. "  ·  " .. Prof.HowToGet(line.id)
                .. (gotText and ("  (+" .. gotText .. ")") or "") .. "|r"
            row.cols = { Money(line.cost or 0) }
            row.tooltip = function(owner)
                ns.Tooltip.Text(owner, { ItemText(line.id), string.format("This step needs %d.", line.n),
                    gotText and ("Already: " .. gotText) or "You have none yet.",
                    string.format("Get %d more: %s", line.buy, Prof.HowToGet(line.id)) })
            end
        elseif line.make then
            row.craft = { recipe = line.recipe, count = line.make }
            row.text = HEX.accent .. "Make " .. line.make .. "|r x " .. ItemText(line.id)
                .. HEX.muted .. "  ·  " .. line.recipe.prof .. (gotText and ("  (+" .. gotText .. ")") or "") .. "|r"
            row.tooltip = function(owner)
                local tip = { line.recipe.name, string.format("This step needs %d %s.", line.n, Prof.ItemName(line.id)) }
                if gotText then tip[#tip + 1] = "Already: " .. gotText end
                local _, bsrc = Prof.ItemPrice(line.id)
                if bsrc ~= "unknown" then tip[#tip + 1] = HEX.muted .. "Buying instead: " .. Prof.PriceText(line.id)
                    .. " each. Making it is cheaper at these prices.|r" end
                tip[#tip + 1] = HEX.accent .. "Click: craft " .. line.make .. " (your " .. line.recipe.prof .. " window must be open).|r"
                ns.Tooltip.Text(owner, tip)
            end
        else
            row.text = CHECK .. HEX.good .. line.n .. " x |r" .. ItemText(line.id) .. HEX.muted .. "  " .. (gotText or "") .. "|r"
        end
        out[#out + 1] = row
    end
end

local function BuildView(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()

    v.left = Style.Card(v, "Plan")
    v.left:SetPoint("TOPLEFT")
    v.left:SetPoint("BOTTOMLEFT")
    v.left:SetWidth(420)

    local controls = CreateFrame("Frame", nil, v.left.content)
    controls:SetPoint("TOPLEFT", 6, -4)
    controls:SetPoint("TOPRIGHT", -6, -4)
    controls:SetHeight(52)

    local function Cycle(step)
        local prof, order = CurrentProf(ns.GearUI.CharKey())
        local i = 1
        for n, name in ipairs(order) do if name == prof then i = n end end
        i = i + step
        if i > #order then i = 1 elseif i < 1 then i = #order end
        db().profPlanProf = order[i]
        ns.GearUI.Refresh()
    end
    v.profButton = Style.Button(controls, "", 150, function(_, button) Cycle(button == "RightButton" and -1 or 1) end,
        "Left-click: next profession. Right-click: previous. Yours come first.", { title = "Profession" })
    v.profButton:SetPoint("TOPLEFT", 0, 0)
    Style.AttachDropdown(v.profButton, function()
        local prof, order, c = CurrentProf(ns.GearUI.CharKey())
        local list = {}
        for _, name in ipairs(order) do
            local cur = c and c.current and c.current[name]
            list[#list + 1] = { key = name, label = name .. (cur and (HEX.muted .. "  " .. cur.rank .. "|r") or "") }
        end
        return Style.ChoiceItems(list, prof, function(key) db().profPlanProf = key ns.GearUI.Refresh() end)
    end)

    local function Bump(delta)
        local prof = CurrentProf(ns.GearUI.CharKey())
        if not prof then return end
        local plan = v.plan
        Prof.SetTarget(prof, math.max((plan and plan.from or 1) + 1, (plan and plan.to or 75) + delta))
        ns.GearUI.Refresh()
    end
    v.minus = Style.Button(controls, "-", 24, function(_, button) Bump(button == "RightButton" and -25 or -5) end,
        "Target 5 lower (right-click: 25).", { title = "Target" })
    v.minus:SetPoint("LEFT", v.profButton, "RIGHT", 10, 0)
    v.target = Style.Button(controls, "", 92, function()
        local prof = CurrentProf(ns.GearUI.CharKey())
        local cur = v.plan and v.plan.to or 0
        local nextT = PRESETS[1]
        for _, p in ipairs(PRESETS) do if p > cur then nextT = p break end end
        if v.plan and nextT <= v.plan.from then nextT = Prof.MaxSkill(prof) end
        Prof.SetTarget(prof, nextT)
        ns.GearUI.Refresh()
    end, "Click: next rank end (75, 150, 225, 300).", { title = "Target skill" })
    v.target:SetPoint("LEFT", v.minus, "RIGHT", 4, 0)
    v.plus = Style.Button(controls, "+", 24, function(_, button) Bump(button == "RightButton" and 25 or 5) end,
        "Target 5 higher (right-click: 25).", { title = "Target" })
    v.plus:SetPoint("LEFT", v.target, "RIGHT", 4, 0)
    v.resale = Style.Button(controls, "", 90, function()
        db().profPlanResale = not db().profPlanResale
        ns.GearUI.Refresh()
    end, "On: what the products sell for (Auction House after the cut, or a vendor) lowers a recipe's cost when choosing, "
        .. "so recipes whose products sell win. The products you end up with are listed either way.", { title = "Resale" })
    v.resale:SetPoint("LEFT", v.plus, "RIGHT", 6, 0)

    local function BumpStart(delta)
        local charKey = ns.GearUI.CharKey()
        local prof = CurrentProf(charKey)
        if not prof or not v.plan then return end
        Prof.SetStart(charKey, prof, v.plan.from + delta)
        ns.GearUI.Refresh()
    end
    v.fromMinus = Style.Button(controls, "-", 24, function(_, button) BumpStart(button == "RightButton" and -25 or -5) end,
        "Start 5 lower (right-click: 25). Never below your read rank.", { title = "Start" })
    v.fromMinus:SetPoint("TOPLEFT", 0, -28)
    v.from = Style.Button(controls, "", 92, function()
        local charKey = ns.GearUI.CharKey()
        Prof.SetStart(charKey, CurrentProf(charKey), nil)
        ns.GearUI.Refresh()
    end, function()
        local plan = v.plan
        if not plan then return nil end
        if plan.source == "rank" then return "Your rank, read from the game. Use - / + if it is out of date." end
        if plan.source == "set" then return "Set by hand" .. (plan.rank and (" (the game last said " .. plan.rank .. ")") or "")
            .. ". Click: back to your read rank." end
        return "Your rank is not read yet: open the Skills tab, or this profession's window once. Or set it with - / +."
    end, { title = "Start skill" })
    v.from:SetPoint("LEFT", v.fromMinus, "RIGHT", 4, 0)
    v.fromPlus = Style.Button(controls, "+", 24, function(_, button) BumpStart(button == "RightButton" and 25 or 5) end,
        "Start 5 higher (right-click: 25), e.g. when you leveled it and the game has not told us yet.", { title = "Start" })
    v.fromPlus:SetPoint("LEFT", v.from, "RIGHT", 4, 0)

    v.patterns = Style.Button(controls, "", 120, function()
        db().profPlanPatterns = not db().profPlanPatterns
        ns.GearUI.Refresh()
    end, "Also plan with recipes that need a pattern (bought from a vendor or dropped). Recipes you already know are always used.",
        { title = "Patterns" })
    v.patterns:SetPoint("LEFT", v.fromPlus, "RIGHT", 10, 0)
    v.bags = Style.Button(controls, "", 120, function()
        db().profPlanBags = not db().profPlanBags
        ns.GearUI.Refresh()
    end, "Subtract what is in your bags and bank from the shopping list (only for the character you are playing).",
        { title = "Bags and bank" })
    v.bags:SetPoint("LEFT", v.patterns, "RIGHT", 6, 0)

    local shopHolder = CreateFrame("Frame", nil, v.left.content)
    shopHolder:SetPoint("TOPLEFT", 0, -60)
    shopHolder:SetPoint("BOTTOMRIGHT")
    v.shop = Style.List(shopHolder, { colWidths = { 64, 58 } })

    v.right = Style.Card(v, "Steps")
    v.right:SetPoint("TOPLEFT", v.left, "TOPRIGHT", 10, 0)
    v.right:SetPoint("BOTTOMRIGHT")
    v.steps = Style.List(v.right.content, { labelWidth = 62, colWidths = { 58 }, onClick = function(item, button)
        if button == "RightButton" and item.recipe then
            db().profPlanExcluded[item.recipe.id] = true
            ns.Print("not using " .. item.recipe.name .. " (clear with the button at the bottom).")
            ns.GearUI.Refresh()
        elseif button == "LeftButton" and item.craft then
            local _, msg = Prof.Craft(item.craft.recipe, item.craft.count)
            ns.Print(msg)
        end
    end })

    local function Excluded()
        local n = 0
        for _ in pairs(db().profPlanExcluded) do n = n + 1 end
        return n
    end

    function v:Footer()
        local n = Excluded()
        return "Estimate: skill-ups are random. Prices: vendor, else the Auction House as you last saw it (green today, gold this week), "
            .. "else Wowhead's average (grey). " .. ns.Cmd.Text("price") .. " for the market.",
            n > 0 and ("Use all recipes (" .. n .. ")") or nil
    end
    function v:FooterAction()
        db().profPlanExcluded = {}
        ns.GearUI.Refresh()
    end

    local function PaintToggle(b, on, label)
        b.borderColor = on and COLORS.accent or nil
        local c = on and COLORS.accent or COLORS.border
        b:SetBorderColor(c[1], c[2], c[3], 1)
        b:SetLabel(label)
    end

    function v:Refresh()
        local charKey = ns.GearUI.CharKey()
        local me = ns.Gear.CharKey()
        local prof, _, c = CurrentProf(charKey)
        local cur = prof and c and c.current and c.current[prof]
        self.profButton:SetLabel((prof or "?") .. (cur and (HEX.muted .. "  " .. cur.rank .. "|r") or "") .. "  >")
        PaintToggle(self.resale, db().profPlanResale, db().profPlanResale and "Resale: on" or "Resale: off")
        PaintToggle(self.patterns, db().profPlanPatterns, db().profPlanPatterns and "Patterns: on" or "Trainer only")
        PaintToggle(self.bags, db().profPlanBags and charKey == me,
            charKey ~= me and "Bags: other char" or (db().profPlanBags and "Bags: counted" or "Bags: ignored"))

        if not prof then
            self.shop:SetItems({ { text = HEX.muted .. "No profession data (ProfessionData.lua missing).|r" } })
            self.steps:SetItems({})
            return
        end
        local plan = Prof.PlanFor(charKey, prof)
        self.plan = plan
        self.target:SetLabel("to " .. plan.to)
        local fromColor = plan.source == "rank" and HEX.good or (plan.source == "set" and HEX.gold or HEX.bad)
        self.from:SetLabel(fromColor .. "from " .. plan.from .. "|r")

        if plan.error then
            self.left.title:SetText("Plan  " .. HEX.accent .. prof .. "|r")
            self.left.sub:SetText(plan.error)
            self.shop:SetItems({ { text = HEX.muted .. prof .. " " .. plan.error .. ".|r" } })
            self.steps:SetItems({})
            return
        end

        local startText = plan.source == "rank" and (HEX.muted .. "  (your rank " .. plan.rank .. " / " .. plan.max .. ")|r")
            or (plan.source == "set" and (HEX.gold .. "  (start set by hand)|r")
            or (HEX.bad .. "  (your rank: not read yet, or not learned)|r"))
        self.left.title:SetText(string.format("Plan  %s%s|r  %d -> %d%s", HEX.accent, prof, plan.from, plan.to, startText))
        self.left.sub:SetText(string.format("~%d crafts  ·  est. %s%s|r  (materials %s, recipes %s, training %s)%s",
            plan.crafts, HEX.gold, Money(plan.total), Money(plan.materials), Money(plan.learn), Money(plan.training),
            plan.resale > 0 and string.format("  ·  sell the products: -%s = %s%s|r", Money(plan.resale), HEX.good, Money(math.max(0, plan.net))) or ""))

        -- Shopping list.
        local rows = {}
        local buyRows, unseenRows, haveRows = {}, {}, {}
        for _, e in ipairs(plan.shopping) do
            -- Supply at your last look, and whether it covers what you need.
            local listed, auctions = Prof.Supply(e.id)
            local short = e.buy > 0 and listed and listed < e.buy and e.src ~= "vendor"
            local supplyText = (listed and e.src ~= "vendor") and ((short and HEX.bad or HEX.muted) .. "  ·  " .. listed .. " listed|r") or ""
            local srcText = Prof.PriceText(e.id)
            -- How much to trust it: green seen today, gold this week, grey older or an average.
            local age = e.seen and (time() - e.seen) or nil
            local trust = e.src == "vendor" and HEX.good or (age and (age < 86400 and HEX.good or (age < 7 * 86400 and HEX.gold or HEX.muted)) or HEX.muted)
            local row = {
                icon = Prof.ItemIcon(e.id),
                text = ItemText(e.id) .. HEX.muted .. "  " .. Prof.HowToGet(e.id) .. "|r" .. supplyText,
                cols = { (e.buy > 0 and (HEX.white .. e.buy .. "|r") or (HEX.good .. "0|r")) .. HEX.muted .. " / " .. e.need .. "|r",
                    e.buy > 0 and (trust .. Money(e.buy * e.unit) .. "|r") or (HEX.good .. "have|r") },
                tooltip = function(owner)
                    local lines = { ItemText(e.id),
                        string.format("Need %d  ·  have %d  ·  buy %d", e.need, e.have, e.buy),
                        string.format("%s each  ·  %s", Money(e.unit), srcText) }
                    if listed then
                        lines[#lines + 1] = string.format("At your last look: %s%d units|r%s", short and HEX.bad or "", listed,
                            auctions and (" in " .. auctions .. " auctions") or "")
                        if short then lines[#lines + 1] = HEX.bad .. "Fewer than you need: buy what is there, check again later.|r" end
                    end
                    if e.src == "ah" or e.src == "unknown" then
                        lines[#lines + 1] = HEX.muted .. "Not seen on the Auction House yet: search it there and the plan uses the real price.|r"
                    else
                        lines[#lines + 1] = Prof.HowToGet(e.id)
                    end
                    ns.Tooltip.Text(owner, lines)
                end,
            }
            if e.buy <= 0 then haveRows[#haveRows + 1] = row
            elseif e.src == "ah" or e.src == "unknown" then unseenRows[#unseenRows + 1] = row
            else buyRows[#buyRows + 1] = row end
        end
        table.sort(buyRows, function(a, b) return a.text < b.text end)
        table.sort(unseenRows, function(a, b) return a.text < b.text end)
        rows[#rows + 1] = { header = true, text = "To buy or gather", sortId = "shop", cols = { "Buy / need", "Cost" } }
        for _, r in ipairs(buyRows) do rows[#rows + 1] = r end
        if #buyRows == 0 and #unseenRows == 0 then rows[#rows + 1] = { text = HEX.good .. "Nothing: you have everything.|r" } end
        if #unseenRows > 0 then
            rows[#rows + 1] = { header = true, text = "Not seen on the Auction House  " .. HEX.muted .. "(look them up: estimated)|r",
                sortId = "shop", cols = { "Buy / need", "Cost" } }
            for _, r in ipairs(unseenRows) do rows[#rows + 1] = r end
        end
        if #haveRows > 0 then
            rows[#rows + 1] = { header = true, text = "Already in your bags or bank" }
            for _, r in ipairs(haveRows) do rows[#rows + 1] = r end
        end
        if #plan.tools > 0 then
            rows[#rows + 1] = { header = true, text = "Tools" }
            for _, t in ipairs(plan.tools) do
                rows[#rows + 1] = { icon = Prof.ItemIcon(t.id), text = ItemText(t.id) .. HEX.muted .. "  " .. Prof.HowToGet(t.id) .. "|r",
                    cols = { "", t.have and (HEX.good .. "have|r") or (HEX.bad .. "need|r") } }
            end
        end
        if #plan.products > 0 then
            rows[#rows + 1] = { header = true, text = "You end up with  " .. HEX.muted .. "(AH after the cut, or vendor)|r", sortId = "products",
                cols = { "Sell at", "Worth" } }
            for _, p in ipairs(plan.products) do
                rows[#rows + 1] = { icon = Prof.ItemIcon(p.id), text = ItemText(p.id) .. HEX.muted .. "  x" .. p.n .. "|r",
                    cols = { p.src and (HEX.muted .. (p.src == "ah" and "AH" or "vendor") .. "|r") or "",
                        p.unit > 0 and (HEX.good .. Money(p.unit * p.n) .. "|r") or (HEX.dim .. "-|r") },
                    tooltip = function(owner)
                        local lines = { ItemText(p.id) .. "  x" .. p.n }
                        if p.src == "ah" then
                            lines[#lines + 1] = string.format("%s each on the Auction House after the cut (seen %s)", Money(p.unit),
                                ns.Prices.Age(p.seen))
                        elseif p.src == "vendor" then
                            lines[#lines + 1] = Money(p.unit) .. " each from a vendor (not seen on the Auction House for more)."
                        else
                            lines[#lines + 1] = "No vendor price and not seen on the Auction House."
                        end
                        ns.Tooltip.Text(owner, lines)
                    end }
            end
        end
        if plan.unknownPrices > 0 then
            rows[#rows + 1] = { text = HEX.muted .. "Items without a price are counted at " .. Money(2000) .. " each.|r" }
        end
        self.shop:SetItems(rows)

        -- Steps.
        local out = {}
        if plan.note then out[#out + 1] = { text = HEX.gold .. prof .. " " .. plan.note .. "; the steps below are smelting only.|r" } end
        if plan.levelShort then
            out[#out + 1] = { text = HEX.bad .. string.format("You need level %d to train %s.", plan.levelShort.level, plan.levelShort.rank) .. "|r" }
        end
        for _, step in ipairs(plan.steps) do
            if step.kind == "train" then
                local rk = step.rank
                out[#out + 1] = { label = "at " .. step.at, accent = COLORS.accent, tint = { 1, 0.82, 0, 0.06 },
                    text = HEX.gold .. "Train " .. rk.rank .. " " .. prof .. "|r" .. HEX.muted .. "  (max " .. rk.max .. ")"
                        .. (rk.level and ("  ·  level " .. rk.level) or "") .. (rk.note and ("  ·  " .. rk.note) or "  ·  at a trainer") .. "|r",
                    cols = { rk.cost and Money(rk.cost) or "" } }
            else
                local r = step.recipe
                local learn
                if step.known then learn = HEX.good .. "known|r"
                elseif step.pattern then
                    learn = HEX.gold .. (r.patternPrice and ("pattern, vendor " .. Money(r.patternPrice)) or "pattern (drop / quest)") .. "|r"
                else learn = "trainer" .. (r.guess and "?" or "") .. (step.learn and (" " .. Money(step.learn)) or "") end
                -- Header: the stage. Then the to-do lines in order, ending with the craft.
                out[#out + 1] = { recipe = r, craft = { recipe = r, count = step.crafts }, label = step.from .. "-" .. step.to,
                    icon = r.creates and Prof.ItemIcon(r.creates) or nil,
                    text = Colored(step.color, r.name)
                        .. (step.endColor ~= step.color and (HEX.muted .. " -> |r" .. Colored(step.endColor, step.endColor)) or "")
                        .. HEX.muted .. "  ·  |r" .. learn,
                    cols = { Money(step.cost or 0) }, tint = { 1, 1, 1, 0.05 }, accent = COLORS.accent,
                    tooltip = function(owner) RecipeTooltip(owner, step) end }
                MaterialRows(out, step.mats or {}, 14)
                out[#out + 1] = { indent = 14, craft = { recipe = r, count = step.crafts }, label = "",
                    icon = r.creates and Prof.ItemIcon(r.creates) or nil,
                    text = HEX.accent .. "Make " .. step.crafts .. "|r x " .. Colored(step.color, r.name)
                        .. HEX.muted .. "  ->  " .. prof .. " " .. step.to
                        .. ((r.creates and Prof.SellValue(r.creates) > 0) and ("  ·  sells " .. Money(Prof.SellValue(r.creates)) .. " each") or "") .. "|r",
                    tooltip = function(owner) RecipeTooltip(owner, step) end }
                out[#out + 1] = { text = "" }
            end
        end
        for _, gap in ipairs(plan.gaps) do
            out[#out + 1] = { label = gap[1] .. "-" .. gap[2], text = HEX.bad .. "No usable recipe here"
                .. (db().profPlanPatterns and "" or ": try \"Patterns: allowed\"") .. "|r" }
        end
        if #out == 0 then out[1] = { text = HEX.good .. "Already at " .. plan.from .. ": raise the target.|r" } end
        self.steps:SetItems(out)
        self.right.sub:SetText("Top to bottom: get, make, then craft  ·  click a Make line to craft  ·  right-click a step: skip that recipe")
    end
    return v
end

ns.GearUI.AddView({ key = "professions", label = "Professions", build = BuildView })

---------------------------------------------------------------------------
-- Crafting tab: what you made (totals per recipe, left) and the log
-- (right). Click a recipe to see only its entries.
---------------------------------------------------------------------------
local RANGES = { { key = "all", label = "All time" }, { key = "week", label = "Last 7 days" }, { key = "day", label = "Today" } }
local logState = { range = "all", recipe = nil }

local function RangeStart(key)
    if key == "day" then
        local t = date("*t")
        return time({ year = t.year, month = t.month, day = t.day, hour = 0 })
    elseif key == "week" then
        return time() - 7 * 86400
    end
    return 0
end

local function Gain(e) return (e.from and e.to and e.to > e.from) and (e.to - e.from) or 0 end

local function CraftLines(e, r)
    local lines = { HEX.gold .. e.n .. " x " .. r.name .. "|r",
        date("%b %d %H:%M", e.t) .. ((e.t2 and e.t2 - e.t >= 60) and ("  to  " .. date("%H:%M", e.t2)) or "") }
    if e.from then
        lines[#lines + 1] = string.format("%s %d -> %d%s", r.prof, e.from, e.to or e.from,
            Gain(e) > 0 and (HEX.good .. "  (+" .. Gain(e) .. ")|r") or HEX.muted .. "  (no skill-up)|r")
    end
    if r.creates then lines[#lines + 1] = "Made " .. e.n * (r.makes or 1) .. " x " .. ItemText(r.creates) end
    lines[#lines + 1] = " "
    lines[#lines + 1] = "Materials used:"
    for _, rg in ipairs(r.reagents or {}) do
        lines[#lines + 1] = string.format("  %d x %s", rg[2] * e.n, ItemText(rg[1]))
    end
    lines[#lines + 1] = string.format("Est. value of the materials: %s (%s each)", Money(Prof.ReagentCost(r) * e.n), Money(Prof.ReagentCost(r)))
    if e.zone or e.level then
        lines[#lines + 1] = HEX.muted .. (e.zone or "?") .. (e.level and ("  ·  level " .. e.level) or "") .. "|r"
    end
    return lines
end

local function CraftTotalRow(t)
    local selected = logState.recipe == t.r.id
    return {
        icon = t.r.creates and Prof.ItemIcon(t.r.creates) or nil,
        text = (selected and HEX.accent or HEX.white) .. t.r.name .. "|r",
        cols = { "x" .. t.n, t.gain > 0 and (HEX.good .. "+" .. t.gain .. "|r") or (HEX.dim .. "-|r") },
        accent = selected and COLORS.accent or nil,
        tooltip = function(owner)
            ns.Tooltip.Text(owner, { t.r.name, string.format("Made %d times  ·  +%d skill", t.n, t.gain),
                "Est. value of the materials: " .. Money(Prof.ReagentCost(t.r) * t.n), HEX.muted .. "Click: only this recipe in the log.|r" })
        end,
    }
end

local function CraftLogRow(e)
    local r = Prof.DATA.recipes[e.id]
    return {
        label = date("%b %d %H:%M", e.t), icon = r.creates and Prof.ItemIcon(r.creates) or nil,
        text = HEX.white .. e.n .. "|r x " .. HEX.gold .. r.name .. "|r" .. HEX.muted .. "  ·  " .. r.prof
            .. (e.from and (" " .. e.from .. (Gain(e) > 0 and (" -> " .. e.to) or "")) or "") .. "|r"
            .. (Gain(e) > 0 and (HEX.good .. "  +" .. Gain(e) .. "|r") or ""),
        cols = { HEX.muted .. Money(Prof.ReagentCost(r) * e.n) .. "|r" }, sort = { label = e.t },
        tooltip = function(owner) ns.Tooltip.Text(owner, CraftLines(e, r)) end,
    }
end

local function BuildLogView(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()

    v.left = Style.Card(v, "Made")
    v.left:SetPoint("TOPLEFT")
    v.left:SetPoint("BOTTOMLEFT")
    v.left:SetWidth(380)
    v.range = Style.Button(v.left, "", 110, function(_, button)
        local i = 1
        for n, r in ipairs(RANGES) do if r.key == logState.range then i = n end end
        i = i + (button == "RightButton" and -1 or 1)
        if i > #RANGES then i = 1 elseif i < 1 then i = #RANGES end
        logState.range = RANGES[i].key
        ns.GearUI.Refresh()
    end, "Left-click: next range. Right-click: previous.", { title = "Range" })
    v.range:SetPoint("TOPRIGHT", -10, -10)
    Style.AttachDropdown(v.range, function()
        return Style.ChoiceItems(RANGES, logState.range, function(key) logState.range = key ns.GearUI.Refresh() end)
    end)
    v.totals = Style.List(v.left.content, { colWidths = { 46, 50 }, onClick = function(item)
        if item.recipeId then
            logState.recipe = (logState.recipe == item.recipeId) and nil or item.recipeId
            ns.GearUI.Refresh()
        end
    end })

    v.right = Style.Card(v, "Log")
    v.right:SetPoint("TOPLEFT", v.left, "TOPRIGHT", 10, 0)
    v.right:SetPoint("BOTTOMRIGHT")
    v.log = Style.List(v.right.content, { labelWidth = 86, colWidths = { 64 }, search = true, hint = "Search recipes, zones...",
        columns = { name = "Craft", label = "When", "Materials" } })

    function v:Footer()
        return "Every craft is logged as it happens, from any window. Hover an entry for the materials used.",
            logState.recipe and "Show all recipes" or nil
    end
    function v:FooterAction()
        logState.recipe = nil
        ns.GearUI.Refresh()
    end

    function v:Refresh()
        local crafts = Prof.Crafts(ns.GearUI.CharKey())
        local since = RangeStart(logState.range)
        for _, r in ipairs(RANGES) do if r.key == logState.range then self.range:SetLabel(r.label .. "  >") end end

        -- Totals and log over up to MAX_CRAFTS entries: kept until a craft
        -- (or the range: a minute at most, "last 7 days" moves).
        local key = { ns.GearUI.CharKey(), logState.range, logState.recipe }
        local totals = ns.Data.List(self.totals, {
            name = "crafts:totals", sources = { "crafts" }, key = key, maxAge = 60, row = CraftTotalRow,
            empty = "Nothing crafted in this range yet.",
            build = function(add, raw)
                local byProf, profOrder = {}, {}
                local d = { crafts = 0, gain = 0, cost = 0 }
                for _, e in ipairs(crafts) do
                    local r = Prof.DATA.recipes[e.id]
                    if r and (e.t2 or e.t) >= since then
                        local p = byProf[r.prof]
                        if not p then
                            p = { n = 0, gain = 0, recipes = {}, order = {} }
                            byProf[r.prof] = p
                            profOrder[#profOrder + 1] = r.prof
                        end
                        local t = p.recipes[e.id]
                        if not t then
                            t = { r = r, n = 0, gain = 0, last = 0 }
                            p.recipes[e.id] = t
                            p.order[#p.order + 1] = t
                        end
                        t.n, t.gain, t.last = t.n + e.n, t.gain + Gain(e), math.max(t.last, e.t2 or e.t)
                        p.n, p.gain = p.n + e.n, p.gain + Gain(e)
                        d.crafts, d.gain, d.cost = d.crafts + e.n, d.gain + Gain(e), d.cost + Prof.ReagentCost(r) * e.n
                    end
                end
                table.sort(profOrder)
                for _, prof in ipairs(profOrder) do
                    local p = byProf[prof]
                    raw({ header = true, text = prof .. HEX.muted .. "  " .. p.n .. " crafts" .. (p.gain > 0 and ("  ·  +" .. p.gain .. " skill") or "") .. "|r" })
                    table.sort(p.order, function(a, b) return a.last > b.last end)
                    for _, t in ipairs(p.order) do add(t, { recipeId = t.r.id }) end
                end
                return d
            end,
        })
        self.left.sub:SetText(string.format("%d crafts  ·  +%d skill  ·  materials ~%s", totals.crafts, totals.gain, Money(totals.cost)))

        -- The log, newest first.
        ns.Data.List(self.log, {
            name = "crafts:log", sources = { "crafts" }, key = key, maxAge = 60, row = CraftLogRow,
            empty = "Crafts appear here as you make them.",
            build = function(add)
                for i = #crafts, 1, -1 do
                    local e = crafts[i]
                    local r = Prof.DATA.recipes[e.id]
                    if r and (e.t2 or e.t) >= since and (not logState.recipe or logState.recipe == e.id) then add(e) end
                end
            end,
        })
        local sel = logState.recipe and Prof.DATA.recipes[logState.recipe]
        self.right.title:SetText("Log" .. (sel and ("  " .. HEX.accent .. sel.name .. "|r") or ""))
        self.right.sub:SetText("newest first  ·  materials: their estimated value")
    end
    return v
end

ns.GearUI.AddView({ key = "crafting", label = "Crafting", build = BuildLogView })
