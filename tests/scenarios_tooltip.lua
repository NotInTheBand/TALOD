-- Tooltip.lua: every tooltip goes through one builder. Titles, pairs and tones
-- land the same way everywhere; item tooltips get one header over the
-- modules' sections, and nothing at all when no section has anything to say.
local scenarios, T = ...
local check, boot = T.check, T.boot

-- A fake tooltip that records what it was given.
local function Recorder()
    local r = { lines = {} }
    function r:SetText(t, cr, cg, cb) self.lines[#self.lines + 1] = { kind = "title", text = t, c = { cr, cg, cb } } end
    function r:AddLine(t, cr, cg, cb, wrap) self.lines[#self.lines + 1] = { kind = "line", text = t, c = { cr, cg, cb }, wrap = wrap } end
    function r:AddDoubleLine(l, v, lr, lg, lb, cr, cg, cb)
        self.lines[#self.lines + 1] = { kind = "pair", text = l, value = v, c = { cr, cg, cb } }
    end
    function r:Show() self.shown = true end
    return r
end

scenarios.tooltip_builder = function()
    local ns = boot(16001)
    local Tip = ns.Tooltip

    -- Text: first line is the title, the rest wrap.
    local owner = CreateFrame("Frame", nil, UIParent)
    Tip.Text(owner, { "Title", "Body" })
    check(GameTooltip:IsOwned(owner) and GameTooltip:IsShown(), "Text owns and shows GameTooltip")
    Tip.HideFor(CreateFrame("Frame", nil, UIParent))
    check(GameTooltip:IsShown(), "HideFor leaves another owner's tooltip")
    Tip.HideFor(owner)
    check(not GameTooltip:IsShown(), "HideFor hides its own")

    -- Builder on a recorder: lines, pairs, tones.
    local rec = Recorder()
    local t = Tip.On(rec)
    t.n = 0
    t:Title("Name"):Pair("Distance", "? yd"):More("detail"):Hint("Click: target"):Note("old")
    local L = rec.lines
    check(L[1].kind == "title" and L[1].text == "Name", "title first")
    check(L[2].kind == "pair" and L[2].text == "Distance" and L[2].value == "? yd", "pair")
    check(L[3].kind == "pair" and L[3].text == " " and L[3].value == "detail", "more on the right")
    check(L[4].c[2] == Tip.TONES.hint[2] and L[5].c[1] == Tip.TONES.muted[1], "hint / note tones")

    -- Safety tones follow the colorblind setting.
    TALODDB.colorblind = false
    local r1, g1, b1 = Tip.RGB("danger")
    TALODDB.colorblind = true
    local r2, g2, b2 = Tip.RGB("danger")
    check(r1 == ns.COLORS.danger[1] and b2 == ns.COLORBLIND_COLORS.danger[3] and (r1 ~= r2 or b1 ~= b2), "danger tone is colorblind aware")
    TALODDB.colorblind = false
    local r, g, b = Tip.RGB({ r = 0.1, g = 0.2, b = 0.3 })
    check(r == 0.1 and g == 0.2 and b == 0.3, "r/g/b table tone")

    -- Item tooltips: one header, sections in order, none when empty.
    local order = {}
    Tip.AddItemSection("zz_test_b", 90, function(tb, id) order[#order + 1] = "b"; tb:Pair("B", id) end)
    Tip.AddItemSection("zz_test_a", 80, function(tb, id) order[#order + 1] = "a"; tb:Pair("A", id) end)
    TALODDB.tooltipPrices, TALODDB.tooltipMovement = false, false
    rec = Recorder()
    Tip.ItemLines(rec, 4289)
    check(order[1] == "a" and order[2] == "b", "sections by order")
    check(rec.lines[1].kind == "line" and rec.lines[1].text == ns.TITLE, "one header first")
    check(rec.lines[2].text == "A" and rec.lines[3].text == "B" and #rec.lines == 3 and rec.shown, "sections under it")
    Tip.AddItemSection("zz_test_a", 80, function() end)
    Tip.AddItemSection("zz_test_b", 90, function() end)
    rec = Recorder()
    Tip.ItemLines(rec, 4289)
    check(#rec.lines == 0 and not rec.shown, "no header when no section says anything")
    rec = Recorder()
    Tip.ItemLines(rec, nil)
    check(#rec.lines == 0, "no item id: nothing")

    -- Extras follow GameTooltip and hide with it.
    local shown, hidden = 0, 0
    Tip.AddItemExtra("zz_test", { show = function() shown = shown + 1 end, hide = function() hidden = hidden + 1 end })
    GameTooltip:Show()
    Tip.ItemLines(GameTooltip, 4289)
    Tip.ItemLines(rec, 4289)
    check(shown == 1, "extras only on GameTooltip")
    GameTooltip:Hide()
    check(hidden == 1, "extras hide with GameTooltip")
end
