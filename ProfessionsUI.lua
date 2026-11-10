-- TALOD - the Professions page's tabs (the window is made in GearUI.lua,
-- Skills comes from Skills.lua):
-- Plan: pick a profession and a target skill; the left side is the shopping
-- list (need, have, buy, estimated cost), the right side the steps in order
-- (train, make first, then craft N of a recipe from skill A to B). A step's
-- Craft button starts that craft (one game command per click). Right-click a
-- step to stop using that recipe (a pattern you cannot get); the plan is redone.
-- Profit: every recipe you can make by profit and margin, with the product's
-- price graph; Track (or a double-click) opens the craft tracker.
-- Log: what you made.

local ADDON_NAME, ns = ...
local S = ns.Secret
local Style = ns.Style
local COLORS, HEX = Style.COLORS, Style.HEX
local Prof = ns.Professions
local Money = Prof.Money
local Page = ns.ProfessionsUI

local QUALITY_HEX = { [0] = "|cff9d9d9d", [1] = "|cffffffff", [2] = "|cff1eff00", [3] = "|cff0070dd", [4] = "|cffa335ee", [5] = "|cffff8000" }
local COLOR_HEX = { orange = "|cffff8040", yellow = "|cffffff00", green = "|cff40c040", grey = "|cff808080" }
local PRESETS = { 75, 150, 225, 300 }

local function db() return ns.DB() end

-- Tool options: settings that change what this tab does, kept on it (not in
-- Settings). Each binds once, where its control is built.
local PLAN_TOOLS = { "profPlanPatterns", "profPlanBags", "profPlanResale", "profPlanTargets", "profPlanFrom", "profPlanExcluded" }
local function BindTools(keys, where)
    local O = ns.Options
    if not (O and O.Bind) then return end
    for _, key in ipairs(keys) do O.Bind(key, "tool", where) end
end

local function ItemText(id)
    local it = Prof.Item(id)
    return (QUALITY_HEX[it and it.q or 1] or HEX.white) .. Prof.ItemName(id) .. "|r"
end

local function Colored(color, text) return (COLOR_HEX[color] or "") .. text .. "|r" end

-- A cost column: the priced part, "+?" when some of it has no price, "?"
-- when none has (narrow columns; the tooltip says how many).
local function Amount(copper, unknown)
    if not unknown or unknown <= 0 then return Money(copper or 0) end
    if (copper or 0) > 0 then return Money(copper) .. HEX.bad .. "+?|r" end
    return HEX.dim .. "?|r"
end

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
    lines[#lines + 1] = HEX.accent .. "Craft button: craft " .. step.crafts .. " (your " .. r.prof .. " window must be open).|r"
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
            row.cols = { Amount(line.cost, line.short) }
            row.tooltip = function(owner)
                local tip = { ItemText(line.id), string.format("This step needs %d.", line.n),
                    gotText and ("Already: " .. gotText) or "You have none yet.",
                    string.format("Get %d more: %s", line.buy, Prof.HowToGet(line.id)) }
                if line.short then
                    tip[#tip + 1] = HEX.bad .. string.format("No price for %d of them: more than the Auction House listed when you looked.", line.short) .. "|r"
                end
                ns.Tooltip.Text(owner, tip)
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
                tip[#tip + 1] = HEX.accent .. "Craft button: craft " .. line.make .. " (your " .. line.recipe.prof .. " window must be open).|r"
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
        local prof, order = CurrentProf(Page.CharKey())
        local i = 1
        for n, name in ipairs(order) do if name == prof then i = n end end
        i = i + step
        if i > #order then i = 1 elseif i < 1 then i = #order end
        db().profPlanProf = order[i]
        Page.Refresh()
    end
    v.profButton = Style.Button(controls, "", 150, function(_, button) Cycle(button == "RightButton" and -1 or 1) end,
        "Left-click: next profession. Right-click: previous. Yours come first.", { title = "Profession" })
    v.profButton:SetPoint("TOPLEFT", 0, 0)
    Style.AttachDropdown(v.profButton, function()
        local prof, order, c = CurrentProf(Page.CharKey())
        local list = {}
        for _, name in ipairs(order) do
            local cur = c and c.current and c.current[name]
            list[#list + 1] = { key = name, label = name .. (cur and (HEX.muted .. "  " .. cur.rank .. "|r") or "") }
        end
        return Style.ChoiceItems(list, prof, function(key) db().profPlanProf = key Page.Refresh() end)
    end)

    local function Bump(delta)
        local prof = CurrentProf(Page.CharKey())
        if not prof then return end
        local plan = v.plan
        Prof.SetTarget(prof, math.max((plan and plan.from or 1) + 1, (plan and plan.to or 75) + delta))
        Page.Refresh()
    end
    v.minus = Style.Button(controls, "-", 24, function(_, button) Bump(button == "RightButton" and -25 or -5) end,
        "Target 5 lower (right-click: 25).", { title = "Target" })
    v.minus:SetPoint("LEFT", v.profButton, "RIGHT", 10, 0)
    v.target = Style.Button(controls, "", 92, function()
        local prof = CurrentProf(Page.CharKey())
        local cur = v.plan and v.plan.to or 0
        local nextT = PRESETS[1]
        for _, p in ipairs(PRESETS) do if p > cur then nextT = p break end end
        if v.plan and nextT <= v.plan.from then nextT = Prof.MaxSkill(prof) end
        Prof.SetTarget(prof, nextT)
        Page.Refresh()
    end, "Click: next rank end (75, 150, 225, 300).", { title = "Target skill" })
    v.target:SetPoint("LEFT", v.minus, "RIGHT", 4, 0)
    v.plus = Style.Button(controls, "+", 24, function(_, button) Bump(button == "RightButton" and 25 or 5) end,
        "Target 5 higher (right-click: 25).", { title = "Target" })
    v.plus:SetPoint("LEFT", v.target, "RIGHT", 4, 0)
    v.resale = Style.Button(controls, "", 90, function()
        db().profPlanResale = not db().profPlanResale
        Page.Refresh()
    end, "On: what the products sell for (Auction House after the cut, or a vendor) lowers a recipe's cost when choosing, "
        .. "so recipes whose products sell win. The products you end up with are listed either way.", { title = "Resale" })
    v.resale:SetPoint("LEFT", v.plus, "RIGHT", 6, 0)

    local function BumpStart(delta)
        local charKey = Page.CharKey()
        local prof = CurrentProf(charKey)
        if not prof or not v.plan then return end
        Prof.SetStart(charKey, prof, v.plan.from + delta)
        Page.Refresh()
    end
    v.fromMinus = Style.Button(controls, "-", 24, function(_, button) BumpStart(button == "RightButton" and -25 or -5) end,
        "Start 5 lower (right-click: 25). Never below your read rank.", { title = "Start" })
    v.fromMinus:SetPoint("TOPLEFT", 0, -28)
    v.from = Style.Button(controls, "", 92, function()
        local charKey = Page.CharKey()
        Prof.SetStart(charKey, CurrentProf(charKey), nil)
        Page.Refresh()
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
        Page.Refresh()
    end, "Also plan with recipes that need a pattern (bought from a vendor or dropped). Recipes you already know are always used.",
        { title = "Patterns" })
    v.patterns:SetPoint("LEFT", v.fromPlus, "RIGHT", 10, 0)
    v.bags = Style.Button(controls, "", 120, function()
        db().profPlanBags = not db().profPlanBags
        Page.Refresh()
    end, "Subtract what is in your bags and bank from the shopping list (only for the character you are playing).",
        { title = "Bags and bank" })
    v.bags:SetPoint("LEFT", v.patterns, "RIGHT", 6, 0)
    -- The planner's options live here, on the tool they change (target and
    -- start: the - / + buttons; excluded: right-click a step, "Use all recipes").
    BindTools(PLAN_TOOLS, "prof/plan")

    local shopHolder = CreateFrame("Frame", nil, v.left.content)
    shopHolder:SetPoint("TOPLEFT", 0, -60)
    shopHolder:SetPoint("BOTTOMRIGHT")
    v.shop = Style.List(shopHolder, { colWidths = { 64, 58 } })

    v.right = Style.Card(v, "Steps")
    v.right:SetPoint("TOPLEFT", v.left, "TOPRIGHT", 10, 0)
    v.right:SetPoint("BOTTOMRIGHT")
    -- Crafting from a step: the row's Craft button sends one game command
    -- per click (DoTradeSkill / CraftRecipe with the step's count, like the
    -- profession window's Create button), out of combat, that window open.
    -- Selecting or reading a row never crafts.
    v.steps = Style.List(v.right.content, { labelWidth = 62, colWidths = { 58 }, rowButtonWidth = 74,
        -- Rows are rebuilt on every bag change: a step is named by its recipe.
        itemKey = function(item)
            local r = item.craft and item.craft.recipe or item.recipe
            if r then return (item.craft and "craft:" or "step:") .. tostring(r.id or r.name) end
            return item.text
        end,
        onClick = function(item, button)
            if button == "RightButton" and item.recipe then
                db().profPlanExcluded[item.recipe.id] = true
                ns.Print("not using " .. item.recipe.name .. " (clear with the button at the bottom).")
                Page.Refresh()
            end
        end,
        rowButton = function(item)
            local craft = item.craft
            if not craft then return nil end
            local fighting = ns.InCombat()
            return { label = "Craft " .. craft.count, kind = "send", enabled = not fighting, why = fighting and "in combat" or nil,
                tooltip = { "Craft " .. craft.count .. " x " .. craft.recipe.name, "One click starts this craft with its count "
                    .. "(your " .. craft.recipe.prof .. " window must be open). Never repeated by itself." },
                onClick = function()
                    local _, msg = Prof.Craft(craft.recipe, craft.count)
                    if msg then ns.Print(msg) end
                end }
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
        Page.Refresh()
    end

    local function PaintToggle(b, on, label)
        b.borderColor = on and COLORS.accent or nil
        local c = on and COLORS.accent or COLORS.border
        b:SetBorderColor(c[1], c[2], c[3], 1)
        b:SetLabel(label)
    end

    function v:Refresh()
        local charKey = Page.CharKey()
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
        local partly = (plan.unpriced or 0) > 0 or (plan.unknownLearn or 0) > 0 or (plan.unknownTraining or 0) > 0
        -- The net with its sign: products worth more than the plan costs are a
        -- gain, never "0c". Unpriced parts make the cost a lower bound, so a
        -- gain is then at most that much.
        local netText = ""
        if plan.resale > 0 then
            if plan.net >= 0 then
                netText = string.format("  ·  sell the products: about -%s = %s%s%s|r", Money(plan.resale), HEX.good,
                    partly and "at least " or "", Money(plan.net))
            else
                netText = string.format("  ·  sell the products: about -%s = %s%s+%s gain|r", Money(plan.resale), HEX.good,
                    partly and "up to " or "", Money(-plan.net))
            end
        end
        self.left.sub:SetText(string.format("~%d crafts  ·  est. %s%s|r  (materials %s, recipes %s, training %s)%s",
            plan.crafts, HEX.gold, Prof.TotalText(plan), Prof.MaterialsText(plan), Prof.LearnText(plan), Prof.TrainingText(plan),
            netText))

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
                    e.buy > 0 and (trust .. Amount(e.cost, e.short) .. "|r") or (HEX.good .. "have|r") },
                tooltip = function(owner)
                    local lines = { ItemText(e.id),
                        string.format("Need %d  ·  have %d  ·  buy %d", e.need, e.have, e.buy),
                        e.unit and string.format("%s each at the lowest  ·  %s", Money(e.unit), srcText) or srcText }
                    if e.buy > 0 then
                        local priced = e.buy - (e.short or 0)
                        if e.buySrc == "ladder" and priced > 0 then
                            lines[#lines + 1] = string.format("%d along the listings you saw: %s (%s each on average)", priced,
                                Money(e.cost), Money(e.cost / priced))
                        elseif e.estimated and priced > 0 then
                            lines[#lines + 1] = HEX.muted .. string.format("%s for %d at the lowest price: every listing not seen, so an estimate.",
                                Money(e.cost), priced) .. "|r"
                        end
                        if (e.short or 0) > 0 then
                            lines[#lines + 1] = HEX.bad .. string.format("No price for %d: %s", e.short, e.unit
                                and "more than the Auction House listed when you looked." or "not seen anywhere yet.") .. "|r"
                        end
                    end
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
                        (p.worth or 0) > 0 and (HEX.good .. Money(p.worth) .. "|r") or (HEX.dim .. "-|r") },
                    tooltip = function(owner)
                        local lines = { ItemText(p.id) .. "  x" .. p.n }
                        if p.src == "ah" then
                            local _, how, info = ns.Market.SaleValue(p.id)
                            lines[#lines + 1] = string.format("%s each: %s (seen %s)", Money(p.unit),
                                ns.Market.SaleValueText(how, info), ns.Prices.Age(p.seen))
                            if p.supplyUnknown then
                                lines[#lines + 1] = HEX.gold .. string.format("How many are listed is unknown (no look of yours counted them): "
                                    .. "counted at the vendor price (%s each), so worth at least this.", Money(p.vendor or 0)) .. "|r"
                            elseif p.atAH and p.atAH < p.n then
                                lines[#lines + 1] = HEX.gold .. string.format("Counted at that price: %d, as many as were listed when you looked. "
                                    .. "The other %d at the vendor price (%s each): the market may not take more.",
                                    p.atAH, p.n - p.atAH, Money(p.vendor or 0)) .. "|r"
                            end
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
            rows[#rows + 1] = { text = HEX.bad .. string.format("%d %s without a price for all you need: left out of the cost "
                .. "(\"+?\"). Search %s on the Auction House.", plan.unknownPrices, plan.unknownPrices == 1 and "item" or "items",
                plan.unknownPrices == 1 and "it" or "them") .. "|r" }
        end
        if (plan.unknownLearn or 0) > 0 then
            rows[#rows + 1] = { text = HEX.gold .. string.format("%d %s without a price (dropped, quest, or no fee known): not in the cost.",
                plan.unknownLearn, plan.unknownLearn == 1 and "recipe" or "recipes") .. "|r" }
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
                else learn = "trainer" .. (r.guess and "?" or "") .. (step.learn and (" " .. Money(step.learn)) or (step.learnUnknown and " ?" or "")) end
                -- Header: the stage. Then the to-do lines in order, ending with the craft.
                out[#out + 1] = { recipe = r, label = step.from .. "-" .. step.to,
                    icon = r.creates and Prof.ItemIcon(r.creates) or nil,
                    text = Colored(step.color, r.name)
                        .. (step.endColor ~= step.color and (HEX.muted .. " -> |r" .. Colored(step.endColor, step.endColor)) or "")
                        .. HEX.muted .. "  ·  |r" .. learn,
                    cols = { Amount(step.cost, step.short) }, tint = { 1, 1, 1, 0.05 }, accent = COLORS.accent,
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
        self.right.sub:SetText("Top to bottom: get, make, then craft  ·  Craft: one click, one craft  ·  right-click a step: skip that recipe")
    end
    return v
end

Page.AddView({ key = "plan", label = "Plan", build = BuildView })
-- The plan the tab opens on, built after login.
Page.AddWarm(function()
    local prof = CurrentProf(ns.Gear.CharKey())
    if prof then Prof.PlanFor(nil, prof) end
end)

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
    local each, unpriced = Prof.ReagentCost(r)
    lines[#lines + 1] = unpriced > 0
        and ("Est. value of the materials: " .. Prof.MoneyKnown(each * e.n, unpriced, unpriced == 1 and "material without a price" or "materials without a price"))
        or string.format("Est. value of the materials: %s (%s each)", Money(each * e.n), Money(each))
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
                "Est. value of the materials: " .. (function()
                    local each, unpriced = Prof.ReagentCost(t.r)
                    return Prof.MoneyKnown(each * t.n, unpriced, unpriced == 1 and "material without a price" or "materials without a price")
                end)(), HEX.muted .. "Click: only this recipe in the log.|r" })
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
        cols = { HEX.muted .. (function()
            local each, unpriced = Prof.ReagentCost(r)
            return Amount(each * e.n, unpriced)
        end)() .. "|r" }, sort = { label = e.t },
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
        Page.Refresh()
    end, "Left-click: next range. Right-click: previous.", { title = "Range" })
    v.range:SetPoint("TOPRIGHT", -10, -10)
    Style.AttachDropdown(v.range, function()
        return Style.ChoiceItems(RANGES, logState.range, function(key) logState.range = key Page.Refresh() end)
    end)
    v.totals = Style.List(v.left.content, { colWidths = { 46, 50 }, onClick = function(item)
        if item.recipeId then
            logState.recipe = (logState.recipe == item.recipeId) and nil or item.recipeId
            Page.Refresh()
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
        Page.Refresh()
    end

    function v:Refresh()
        local crafts = Prof.Crafts(Page.CharKey())
        local since = RangeStart(logState.range)
        for _, r in ipairs(RANGES) do if r.key == logState.range then self.range:SetLabel(r.label .. "  >") end end

        -- Totals and log over up to MAX_CRAFTS entries: kept until a craft
        -- (or the range: a minute at most, "last 7 days" moves).
        local key = { Page.CharKey(), logState.range, logState.recipe }
        local totals = ns.Data.List(self.totals, {
            name = "crafts:totals", sources = { "crafts", "prices" }, key = key, maxAge = 60, row = CraftTotalRow,
            empty = "Nothing crafted in this range yet.",
            build = function(add, raw)
                local byProf, profOrder = {}, {}
                local d = { crafts = 0, gain = 0, cost = 0, unpriced = 0 }
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
                        local each, unpriced = Prof.ReagentCost(r)
                        d.crafts, d.gain, d.cost = d.crafts + e.n, d.gain + Gain(e), d.cost + each * e.n
                        if unpriced > 0 then d.unpriced = d.unpriced + e.n end
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
        self.left.sub:SetText(string.format("%d crafts  ·  +%d skill  ·  materials ~%s", totals.crafts, totals.gain,
            Prof.MoneyKnown(totals.cost, totals.unpriced or 0, (totals.unpriced or 0) == 1 and "craft with an unpriced material"
                or "crafts with an unpriced material")))

        -- The log, newest first.
        ns.Data.List(self.log, {
            name = "crafts:log", sources = { "crafts", "prices" }, key = key, maxAge = 60, row = CraftLogRow,
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

Page.AddView({ key = "log", label = "Log", build = BuildLogView })

---------------------------------------------------------------------------
-- Profit: every recipe you can make, by profit and margin at your prices
-- (Market.CraftList, the list the Auction House pages used to show), with
-- the product's price graph and the detail of one recipe. Two column sets:
-- Profit (materials, profit, margin) and Market (sells for, listed, seen).
-- A click selects (and searches the product on an open Auction House, one
-- search per click); two clicks on the same recipe within DOUBLE_CLICK, or
-- Track, open the craft tracker.
---------------------------------------------------------------------------
local DOUBLE_CLICK = 0.4      -- seconds between the two clicks that open the craft tracker
local PROFIT_CHIPS = {
    { key = "known", label = "Recipes I know" }, { key = "all", label = "All I can make" },
    { key = "profit", label = "Profitable only" }, { key = "bags", label = "In my bags" },
}
local PROFIT_COLUMNS = {
    profit = { "Materials", "Profit", "Margin" },
    market = { "Sells for", "Listed", "Seen" },
}
local profit = { mode = "all", profitable = false, bags = false, cols = "profit", sel = nil }
Page.profit = profit

local function Price(c)
    if not c then return HEX.dim .. "-|r" end
    return Money(c)
end

local function ProfitText(p)
    if not p then return HEX.dim .. "-|r" end
    return (p >= 0 and HEX.good or (HEX.bad .. "-")) .. Money(math.abs(p)) .. "|r"
end

local function MarginText(pr)
    local m = pr.margin
    if not m then
        -- Materials that cost nothing (a vendor gives them free, or none needed).
        if pr.priced and (pr.cost or 0) <= 0 then return HEX.muted .. "free|r" end
        return HEX.dim .. "-|r"
    end
    local v = math.floor(m * 100 + (m >= 0 and 0.5 or -0.5))
    return (v >= 0 and HEX.good or HEX.bad) .. (v > 0 and "+" or "") .. v .. "%|r"
end

local function Pct(x)
    if not x then return HEX.dim .. "-|r" end
    local v = x >= 0 and math.floor(x * 100 + 0.5) or -math.floor(-x * 100 + 0.5)
    if v == 0 then return HEX.muted .. "0%|r" end
    return (v < 0 and HEX.good or HEX.bad) .. (v > 0 and "+" or "") .. v .. "%|r"
end

-- Freshness: today green, this week gold, older grey.
local function AgeText(t, src)
    if not t then return HEX.dim .. "?|r" end
    local age = time() - t
    local color = age < 86400 and HEX.good or (age < 7 * 86400 and HEX.gold or HEX.muted)
    return color .. ns.Prices.Age(t, src) .. "|r"
end

local function Supply(n, a)
    local parts = {}
    if a and a > 0 then parts[#parts + 1] = a .. (a == 1 and " auction" or " auctions") end
    if n and n > 0 then parts[#parts + 1] = n .. " units" end
    return #parts > 0 and table.concat(parts, ", ") or "supply ?"
end

-- One search per click on an open Auction House (quiet when it is closed).
local function ShowOnAH(id)
    if not ns.AHHelper or type(id) ~= "number" then return end
    local ok, msg = ns.AHHelper.Lookup(id)
    if not ok and msg then ns.Print(msg) end
end

-- An item's prices on the Auction House page.
local function OpenPrices(id)
    if ns.MarketUI and ns.MarketUI.state then ns.MarketUI.state.selected = id end
    if ns.Nav and ns.Nav.Go then ns.Nav.Go("ah", "prices", nil, id)
    elseif ns.MarketUI then ns.MarketUI.Show("prices") end
end

local function ProfitRow(pr)
    local r, Market = pr.r, ns.Market
    local sel = profit.sel == r
    local tags = {}
    if not pr.known then tags[#tags + 1] = "not learned" end
    if pr.cooldown then tags[#tags + 1] = "once a day" end
    local make = (pr.canMake or 0) > 0 and (HEX.good .. "  · make " .. pr.canMake .. "|r") or ""
    local cols
    if profit.cols == "market" then
        local s = pr.priced and Market.Stats(r.creates)
        cols = { pr.value and Price(pr.value) or (HEX.dim .. "-|r"), s and s.n and (HEX.muted .. s.n .. "|r") or (HEX.dim .. "?|r"),
            pr.seen and AgeText(pr.seen, pr.seenSrc) or (HEX.dim .. "-|r") }
    else
        cols = { pr.unknown and (HEX.muted .. ">=|r" .. Price(pr.cost)) or (Price(pr.cost) .. (pr.guessed and (HEX.muted .. "*|r") or "")),
            ProfitText(pr.profit), MarginText(pr) }
    end
    return {
        icon = Prof.ItemIcon(r.creates),
        text = (sel and HEX.accent or "") .. Market.ItemText(r.creates) .. (sel and "|r" or "")
            .. ((r.makes or 1) ~= 1 and (" x" .. r.makes) or "") .. HEX.muted .. "  " .. r.prof
            .. (#tags > 0 and ("  (" .. table.concat(tags, ", ") .. ")") or "") .. "|r" .. make
            .. (pr.priced and Market.MoveTag(r.creates) or ""),
        cols = cols,
        accent = sel and COLORS.accent or nil,
        tint = sel and { COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.12 } or nil,
        tooltip = function(owner)
            local lines = { r.name, string.format("%s %d  ·  product seen %s", r.prof, r.skill, ns.Prices.Age(pr.seen, pr.seenSrc)) }
            for _, rg in ipairs(r.reagents or {}) do
                lines[#lines + 1] = string.format("  %d x %s  %s", rg[2], Market.ItemText(rg[1]), HEX.muted .. Prof.PriceText(rg[1]) .. "|r")
            end
            if pr.value then
                lines[#lines + 1] = "Sells for " .. Money(pr.value) .. (pr.how == "vendor" and " at a vendor (more than the Auction House brings you)"
                    or (" after the cut" .. (pr.rate and (" and your " .. (Market.RatePct(pr.rate) or 0) .. "% sell rate") or ""))) .. "."
            end
            if pr.guessed then lines[#lines + 1] = HEX.muted .. "* some materials not seen on the AH: estimated.|r" end
            lines[#lines + 1] = HEX.muted .. "Click: details. Double-click: the craft tracker.|r"
            ns.Tooltip.Text(owner, lines)
        end,
    }
end

-- The detail of one recipe: per craft, the product's market, each material
-- (price, where from, in your bags, cheaper to make), what your bags make.
local function ProfitDetailRows(pr)
    local r, Market = pr.r, ns.Market
    local out = {}
    local makes = r.makes or 1
    local plan = Market.CraftPlan(r)
    out[#out + 1] = { header = true, text = "Per craft" .. (makes ~= 1 and (HEX.muted .. "  (makes " .. makes .. ")|r") or "") }
    out[#out + 1] = { label = "Materials", text = HEX.white .. Price(pr.cost) .. "|r" .. HEX.muted
        .. (makes ~= 1 and ("  ·  " .. Price(pr.cost / makes) .. " each") or "")
        .. (pr.unknown and "  ·  plus materials nobody has a price for" or (pr.guessed and "  ·  partly estimated" or "")) .. "|r" }
    if pr.priced then
        local how = pr.how == "vendor" and "  at a vendor (more than the Auction House brings you)"
            or ("  on the Auction House after the " .. math.floor(Market.CUT * 100) .. "% cut"
                .. (pr.rate and (", your " .. (Market.RatePct(pr.rate) or 0) .. "% sell rate and the deposit") or ""))
        out[#out + 1] = { label = "Sells for", text = Price(pr.value) .. HEX.muted .. how .. "|r"
            .. ((pr.stale and pr.how ~= "vendor") and (HEX.gold .. "  ·  old price: look again|r") or ""),
            tooltip = function(o) ns.Tooltip.Text(o, { "Sells for", string.format("The product's lowest buyout at your last look (the usual price when that "
                .. "look was overpriced), after the Auction House cut. Once %d of your auctions of it have ended, your sell rate counts too: "
                .. "the unsold share at the vendor price, less the deposit. The vendor price instead when that is more.", Market.SELL_MIN_ENDED) }) end }
        out[#out + 1] = { label = "Profit", text = ProfitText(pr.profit) .. HEX.muted .. "  ·  margin |r" .. MarginText(pr) }
    elseif pr.value then
        out[#out + 1] = { label = "Sells for", text = Price(pr.value) .. HEX.muted .. "  after the cut|r" }
        out[#out + 1] = { label = "Profit", text = HEX.muted .. "unknown: a material has no price yet|r" }
    else
        out[#out + 1] = { label = "Sells for", text = HEX.muted .. "not seen on the Auction House: search it there|r" }
    end
    if pr.vendor then
        out[#out + 1] = { label = "Vendor", text = Price(pr.vendor) .. ((not pr.unknown and pr.vendor > pr.cost) and (HEX.good .. "  more than the materials|r") or "") }
    end

    if pr.priced then
        local s = Market.Stats(r.creates)
        out[#out + 1] = { header = true, text = "Its market" }
        if s then
            out[#out + 1] = { label = "Lowest", text = Price(s.p) .. " each  ·  " .. AgeText(s.t) .. HEX.muted .. "  ·  earlier "
                .. Price(s.trendBase and math.floor(s.trendBase + 0.5)) .. "  ·  usual " .. Price(s.usual and math.floor(s.usual + 0.5)) .. "|r",
                cols = { Pct(s.trend) }, id = r.creates,
                tooltip = function(o) ns.Tooltip.Text(o, { "Click: its prices on the Auction House page." }) end }
            out[#out + 1] = { label = "Supply", text = Supply(s.n, s.a) }
        end
        local mv = Market.Movement(r.creates)
        local ev = Market.MovementLines(mv)
        out[#out + 1] = { label = "Moves", text = mv.hex .. mv.label .. "|r" .. HEX.muted .. "  " .. ev[1] .. "|r" }
        if ev[2] then out[#out + 1] = { label = "", text = HEX.muted .. ev[2] .. "|r" } end
    end

    out[#out + 1] = { header = true, text = "Materials" .. HEX.muted .. "  (price each, in your bags)|r", sortId = "materials", cols = { "Per craft" } }
    for _, e in ipairs(plan.reagents) do
        local price = e.src == "unknown" and (HEX.bad .. "no price|r") or (HEX.muted .. Prof.PriceText(e.id) .. "|r")
        out[#out + 1] = { label = e.need .. " x", text = Market.ItemText(e.id) .. "  " .. price
                .. HEX.muted .. "  ·  have |r" .. (e.have >= e.need and HEX.good or HEX.muted) .. e.have .. "|r",
            cols = { e.sub and Price(e.sub) or (HEX.dim .. "?|r") },
            id = ns.Prices.Entry(e.id) and e.id or nil }
        if e.craft then
            local c = e.craft
            out[#out + 1] = { label = "", text = HEX.gold .. "make it: " .. Price(c.whole) .. "|r" .. HEX.muted
                .. "  (" .. c.crafts .. (c.crafts == 1 and " craft" or " crafts")
                .. (c.spare > 0 and (", " .. c.spare .. " spare") or "") .. "; " .. c.r.name .. ", " .. c.r.prof
                .. (c.estimated and ", estimated" or "") .. ")|r" }
        end
    end

    out[#out + 1] = { header = true, text = "From your bags" }
    if plan.canMake > 0 then
        local batch = pr.priced and Market.BatchProfit(r, plan.canMake)
        out[#out + 1] = { label = "Can make", text = HEX.good .. plan.canMake .. (plan.canMake == 1 and " craft" or " crafts") .. "|r"
            .. HEX.muted .. "  (" .. plan.canMake * makes .. " items)|r"
            .. (batch and (HEX.muted .. "  ·  |r" .. ProfitText(batch) .. HEX.muted .. " over the materials' price|r") or "") }
    else
        out[#out + 1] = { label = "Can make", text = HEX.muted .. "none yet|r" }
        out[#out + 1] = { label = "Buy", text = (plan.unknown > 0 and "at least " or "") .. Price(plan.buyCost) .. HEX.muted
            .. "  of materials you lack for one craft" .. (plan.unknown > 0 and (", + " .. plan.unknown .. " without a price") or "") .. "|r" }
    end

    out[#out + 1] = { header = true, text = "Recipe" }
    out[#out + 1] = { label = r.prof:sub(1, 12), text = r.name .. HEX.muted .. "  ·  skill " .. r.skill
        .. (pr.known and "  ·  you know it" or "  ·  not learned (or the profession window not opened yet)")
        .. (pr.cooldown and "  ·  once a day" or "") .. "|r" }
    if r.colors then
        out[#out + 1] = { label = "Skill-ups", text = HEX.muted .. string.format("orange %d, yellow %d, green %d, grey %d", r.colors[1] or 0,
            r.colors[2] or 0, r.colors[3] or 0, r.colors[4] or 0) .. "|r" }
    end
    return out
end

local function ByProfit(a, b) return (a.profit or -math.huge) > (b.profit or -math.huge) end
local function ByName(a, b) return a.r.name < b.r.name end

-- The craft tracker on a recipe (a preview until you press Track it there).
local function Track(r)
    if not (r and ns.CraftTrackUI) then return false end
    local ok = ns.CraftTrackUI.Open(r)
    Page.Refresh()
    return ok
end

local function BuildProfit(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Crafting for profit")
    v.card:SetPoint("TOPLEFT")
    v.card:SetPoint("BOTTOMLEFT")
    v.card:SetWidth(480)

    -- Column set: the cost side or the product's market.
    v.columns = Style.Views(v.card, { { key = "profit", label = "Profit" }, { key = "market", label = "Market" } }, function(key)
        profit.cols = key
        Page.Refresh()
    end)
    v.columns:SetPoint("TOPRIGHT", -8, -(((Style.M.cardHeader or 26) - 20) / 2))
    if Style.Look and Style.Look() == "ledger" then v.card.sub:SetPoint("RIGHT", v.columns, "LEFT", -8, 0) end

    v.chips = Style.Chips(v.card.content, PROFIT_CHIPS, function(key, on)
        if key == "known" or key == "all" then
            profit.mode = key
        elseif key == "profit" then
            profit.profitable = on
        elseif key == "bags" then
            profit.bags = on
        end
        Page.Refresh()
    end)
    v.chips:SetPoint("TOPLEFT", 6, -4)

    local holder = CreateFrame("Frame", nil, v.card.content)
    holder:SetPoint("TOPLEFT", 0, -30)
    holder:SetPoint("BOTTOMRIGHT")
    v.list = Style.List(holder, { colWidths = { 64, 64, 46 }, search = true, hint = "Search recipes, professions...",
        onClick = function(item)
            if not item.pr then return end
            local r, now = item.pr.r, GetTime()
            -- A second click on the same recipe within DOUBLE_CLICK seconds
            -- (list rows have no double-click of their own): the tracker.
            local double = v.lastClick and v.lastClick.r == r and now - v.lastClick.at <= DOUBLE_CLICK
            v.lastClick = not double and { r = r, at = now } or nil
            profit.sel = r
            Page.Refresh()
            if double then Track(r) else ShowOnAH(r.creates) end
        end })

    v.right = Style.Card(v, "")
    v.right:SetPoint("TOPLEFT", v.card, "TOPRIGHT", 10, 0)
    v.right:SetPoint("BOTTOMRIGHT")
    v.chart = ns.PriceChart.New(v.right.content)
    v.chart:SetPoint("TOPLEFT", 2, -2)
    v.chart:SetPoint("TOPRIGHT", -2, -2)
    v.chart:SetHeight(110)
    local detailHolder = CreateFrame("Frame", nil, v.right.content)
    detailHolder:SetPoint("TOPLEFT", 0, -118)
    detailHolder:SetPoint("BOTTOMRIGHT")
    v.detail = Style.List(detailHolder, { labelWidth = 74, colWidths = { 70 }, onClick = function(item)
        if not item.id then return end
        ShowOnAH(item.id)
        if ns.Prices.Entry(item.id) then OpenPrices(item.id) end
    end })

    function v:Footer()
        return "Materials at the best known prices (vendor, your AH looks, else Wowhead estimates *) against the product's AH price "
            .. "after the cut and your sell rate. Double-click a recipe: the craft tracker.", profit.sel and "Track" or nil
    end
    function v:FooterAction() Track(profit.sel) end

    function v:Refresh()
        local Market = ns.Market
        local charKey = Page.CharKey()
        self.columns:Select(profit.cols)
        self.chips:SetOn("known", profit.mode == "known")
        self.chips:SetOn("all", profit.mode == "all")
        self.chips:SetOn("profit", profit.profitable)
        self.chips:SetOn("bags", profit.bags)
        -- Every recipe's materials priced: kept until prices, skills, known
        -- recipes, your sales or your bags change.
        local data = ns.Data.List(self.list, {
            name = "prof:profit", sources = { "prices", "skills", "crafts", "economy", "bags" },
            key = { charKey, profit.mode, profit.profitable, profit.bags, profit.cols, profit.sel }, row = ProfitRow,
            build = function(add, raw)
                local all = Market.CraftList(charKey, profit.mode, { cooldowns = true, bags = true })
                local priced, unpriced, winners, seen, makeable = {}, {}, 0, 0, 0
                for _, pr in ipairs(all) do
                    local wins = pr.priced and pr.profit > 0
                    if pr.priced then seen = seen + 1 end
                    if wins then winners = winners + 1 end
                    if (pr.canMake or 0) > 0 then makeable = makeable + 1 end
                    local keep = (not profit.profitable or wins) and (not profit.bags or (pr.canMake or 0) > 0)
                    if keep then table.insert(pr.priced and priced or unpriced, pr) end
                end
                table.sort(priced, ByProfit)
                table.sort(unpriced, ByName)
                local cols = PROFIT_COLUMNS[profit.cols] or PROFIT_COLUMNS.profit
                raw({ header = true, text = "Recipe", sortId = "profit", cols = cols })
                for _, pr in ipairs(priced) do add(pr, { pr = pr }) end
                if #priced == 0 then
                    raw({ text = HEX.muted .. "No product of these recipes seen on the Auction House yet. Search for what you can make there.|r" })
                end
                if #unpriced > 0 then
                    raw({ header = true, text = "Not seen on the Auction House" .. HEX.muted .. "  (search them there)|r", sortId = "profit",
                        cols = { cols[1], "", "" } })
                    for _, pr in ipairs(unpriced) do add(pr, { pr = pr }) end
                end
                return { all = all, seen = seen, winners = winners, makeable = makeable, shown = #priced + #unpriced }
            end,
        })
        self.data = data
        self.chips:SetCount("profit", data.winners)
        self.chips:SetCount("bags", data.makeable)
        local sel
        for _, pr in ipairs(data.all) do if pr.r == profit.sel then sel = pr end end
        if not sel then
            -- Nothing chosen yet: the best earner, else the first recipe.
            for _, pr in ipairs(data.all) do
                if pr.priced and (not sel or pr.profit > sel.profit) then sel = pr end
            end
            sel = sel or data.all[1]
        end
        profit.sel = sel and sel.r or nil
        self.selected = sel
        self.card.sub:SetText(string.format("%d recipes  ·  %d make money  ·  %d not seen on the AH", #data.all, data.winners,
            #data.all - data.seen))
        if sel then
            local r = sel.r
            self.right.title:SetText(Market.ItemText(r.creates) .. ((r.makes or 1) ~= 1 and (" x" .. r.makes) or ""))
            self.right.sub:SetText(sel.priced and ("profit " .. ProfitText(sel.profit) .. " per craft  ·  margin " .. MarginText(sel))
                or ("materials " .. Price(sel.cost) .. "  ·  product not seen on the AH"))
            self.detail:SetItems(ProfitDetailRows(sel))
            self.chart:SetItem(sel.priced and r.creates or nil)
        else
            self.right.title:SetText("")
            self.right.sub:SetText("")
            self.detail:SetItems({ { text = HEX.muted .. "No recipes: learn a profession, or open its window once.|r" } })
            self.chart:SetItem(nil)
        end
    end
    return v
end

Page.AddView({ key = "profit", label = "Profit", build = BuildProfit })

-- The recipe selected on Profit (the tracker switch opens on it).
function Page.ProfitSelected() return profit.sel end
