-- The Character pages: Gear (Gear / Enhance / Ledger with Changes and New
-- items / Progress) and Professions (Plan / Profit / Skills / Log) build in
-- both looks and open on every tab and view; Profit's column sets, chips and
-- double-click; one craft command per click on a plan step; the tool
-- options bound once on their page; old view keys and old commands land on
-- the new pages.
local scenarios, T = ...
local check, boot, slash = T.check, T.boot, T.slash

local function setup(opts)
    opts = opts or {}
    MOCK.skillLines = { { "Professions", true, true }, { "Tailoring", false, nil, 60, 0, 0, 75 } }
    for i = 1, 5 do MOCK.bags[0][i] = MOCK.ItemLink(2589, "Linen Cloth") end
    function GetItemInfo(id)
        if id == 2589 then return "Linen Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132889, 13, 7, 5, 0 end
        if id == 2996 then return "Bolt of Linen Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132890, 40, 7, 5, 0 end
        if id == 2320 then return "Coarse Thread", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132891, 2, 7, 5, 0 end
    end
    local ns = boot(11509, { db = opts.db })
    -- Every setting binding made while the pages build (Options.Bind may not
    -- exist on this build: recorded either way).
    local binds = {}
    if opts.binds then
        local O = ns.Options
        local real = O.Bind
        O.Bind = function(key, kind, where)
            binds[#binds + 1] = { key = key, kind = kind, where = where }
            if real then return real(key, kind, where) end
        end
    end
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    local now = time()
    ns.Prices.Record(2589, 30, 200, now, 10, "Linen Cloth")
    ns.Prices.Record(2996, 300, 20, now, 4, "Bolt of Linen Cloth")
    return ns, binds
end

local function hideAll(ns)
    for _, M in ipairs({ ns.GearUI, ns.ProfessionsUI }) do
        local f = M.Frame()
        if f then f:Hide() end
    end
end

-- Shown page and where it stands: "gear/ledger:sources".
local function where(ns)
    for _, pair in ipairs({ { "gear", ns.GearUI }, { "prof", ns.ProfessionsUI } }) do
        if pair[2].IsShown() then
            local tab, view = pair[2].Current()
            return pair[1] .. "/" .. tostring(tab) .. ":" .. tostring(view)
        end
    end
    return "none"
end

-- Every tab and view through the page list's entry point.
local function walk(ns, label)
    local G, P = ns.GearUI, ns.ProfessionsUI
    check(type(G.ShowPage) == "function" and type(P.ShowPage) == "function", label .. ": ShowPage")
    local cases = {
        { G, { "gear" }, "gear/gear:gear" },
        { G, { "enhance" }, "gear/enhance:enhance" },
        { G, { "ledger" }, "gear/ledger:ledger" },
        { G, { "ledger", "New items" }, "gear/ledger:sources" },
        { G, { "progress" }, "gear/progress:progress" },
        { G, { "ledger" }, "gear/ledger:sources" },           -- the view is remembered
        { G, { "Ledger", "changes" }, "gear/ledger:ledger" },
        { G, { "ledger", "items" }, "gear/ledger:sources" },
        { P, { "plan" }, "prof/plan:plan" },
        { P, { "profit" }, "prof/profit:profit" },
        { P, { "skills" }, "prof/skills:skills" },
        { P, { "log" }, "prof/log:log" },
        { P, { "Plan" }, "prof/plan:plan" },
    }
    for _, c in ipairs(cases) do
        c[1].ShowPage(c[2][1], c[2][2])
        check(where(ns) == c[3], label .. ": ShowPage " .. table.concat(c[2], "/") .. " -> " .. where(ns))
        local f = c[1].Frame()
        local _, view = c[1].Current()
        check(c[1].views[view]:IsShown(), label .. ": view shown " .. view)
        check(f.footer:GetText() ~= nil, label .. ": footer")
    end
    -- The view switch shows only on Ledger.
    G.ShowPage("ledger")
    check(G.Frame().viewSwitch.ledger:IsShown(), label .. ": Changes / New items on Ledger")
    G.ShowPage("gear")
    check(not G.Frame().viewSwitch.ledger:IsShown(), label .. ": no view switch on Gear")
    -- Title bars: character picker on both, Snapshot now, the tracker switch.
    check(G.Frame().charButton and G.Frame().snapshot, label .. ": gear title bar")
    check(P.Frame().charButton and P.Frame().trackerSwitch, label .. ": professions title bar")
    check(G.Frame() == _G[ns.FRAME .. "CharacterWindow"] and P.Frame() == _G[ns.FRAME .. "ProfessionsWindow"], label .. ": frame names")
    -- Every tab once more by clicking it.
    P.ShowPage("plan")
    for _, b in ipairs(P.Frame().tabs) do b:Fire("OnClick", "LeftButton") end
    check(where(ns) == "prof/log:log", label .. ": tab clicks")
    -- What the page list shows beside them.
    local st = P.PageStatus()
    check(st == nil or type(st.text) == "string", label .. ": professions status")
    st = G.PageStatus()
    check(st == nil or type(st.text) == "string", label .. ": gear status")
    -- A character picked on a page.
    P.Frame().charButton:Fire("OnClick", "LeftButton")
    check(P.CharKey() ~= nil, label .. ": a character")
end

scenarios.character_pages_ledger = function()
    local ns = setup()
    check(ns.Style.Look() == "ledger", "ledger look")
    walk(ns, "ledger")
    -- Arguments: a slot on Enhance, a profession on Plan.
    ns.GearUI.ShowPage("enhance", nil, 16)
    check(ns.Enhance.state.slot == 16 and where(ns) == "gear/enhance:enhance", "enhance on a slot")
    ns.ProfessionsUI.ShowPage("plan", nil, "first")
    check(TALODDB.profPlanProf == "First Aid" and where(ns) == "prof/plan:plan", "plan on a profession")
end

scenarios.character_pages_classic = function()
    local ns = setup({ db = { classicLook = true } })
    check(ns.Style.Look() == "classic", "classic look")
    walk(ns, "classic")
end

-- Profit: Market > Crafting and Auction desk > Margins as one list.
scenarios.character_profit = function()
    local ns = setup()
    local P = ns.ProfessionsUI
    P.ShowPage("profit")
    local v = P.views.profit
    local function header() return v.list.all[1] end
    local function recipes()
        local n, all = 0, {}
        for _, item in ipairs(v.list.all) do if item.pr then n = n + 1 all[#all + 1] = item.pr end end
        return n, all
    end

    -- Column sets.
    local h = header()
    check(h.header and h.cols[1] == "Materials" and h.cols[2] == "Profit" and h.cols[3] == "Margin", "profit columns")
    local n = recipes()
    check(n > 0, "recipes listed: " .. n)
    v.columns.buttons[2]:Fire("OnClick", "LeftButton")
    check(P.profit.cols == "market", "market column set picked")
    h = header()
    check(h.cols[1] == "Sells for" and h.cols[2] == "Listed" and h.cols[3] == "Seen", "market columns")
    local drawn
    for _, r in ipairs(v.list.rows) do
        if r:IsShown() and r.item and r.item.pr and r.item.pr.priced then drawn = r end
    end
    check(drawn and drawn.item.cols and #drawn.item.cols == 3, "a priced row drawn with three market cells")
    v.columns.buttons[1]:Fire("OnClick", "LeftButton")
    check(P.profit.cols == "profit", "back to the profit columns")

    -- Chips: mode (one of two) and two filters.
    local chip = {}
    for _, b in ipairs(v.chips.chips) do chip[b.key] = b end
    check(chip.all.on and not chip.known.on and not chip.profit.on and not chip.bags.on, "default: all I can make")
    local total = recipes()
    chip.profit:Fire("OnClick", "LeftButton")
    local k, list = recipes()
    check(P.profit.profitable and k > 0 and k < total, "profitable only: " .. k .. " of " .. total)
    for _, pr in ipairs(list) do check(pr.priced and pr.profit > 0, "only profitable: " .. pr.r.name) end
    chip.bags:Fire("OnClick", "LeftButton")
    k, list = recipes()
    check(P.profit.bags and k > 0, "in my bags too: " .. k)
    for _, pr in ipairs(list) do check((pr.canMake or 0) > 0 and pr.profit > 0, "bags and profitable: " .. pr.r.name) end
    chip.profit:Fire("OnClick", "LeftButton")
    chip.bags:Fire("OnClick", "LeftButton")
    check(recipes() == total, "filters off: all again")
    chip.known:Fire("OnClick", "LeftButton")
    check(P.profit.mode == "known" and chip.known.on and not chip.all.on, "recipes I know")
    check(recipes() == 0, "no recipe known yet (profession window never opened)")
    chip.all:Fire("OnClick", "LeftButton")
    check(P.profit.mode == "all" and recipes() == total, "all I can make")
    -- A chip clicked twice stays the mode (one of the two is always on).
    chip.all:Fire("OnClick", "LeftButton")
    check(P.profit.mode == "all" and chip.all.on, "mode chip stays on")

    -- The product's graph and detail for the selection.
    check(P.profit.sel and v.chart and v.detail.all and #v.detail.all > 0, "a recipe selected with its detail")

    -- One click selects, two quick clicks track; slow clicks only select.
    local UI = ns.CraftTrackUI
    local row
    for _, r in ipairs(v.list.rows) do if r:IsShown() and r.item and r.item.pr then row = r break end end
    check(row, "a recipe row drawn")
    local r = row.item.pr.r
    row:Fire("OnClick", "LeftButton")
    check(P.profit.sel == r and not UI.IsShown(), "one click only selects")
    MOCK.time = MOCK.time + 1
    for _, rr in ipairs(v.list.rows) do if rr:IsShown() and rr.item and rr.item.pr and rr.item.pr.r == r then row = rr end end
    row:Fire("OnClick", "LeftButton")
    check(not UI.IsShown(), "two slow clicks only select")
    MOCK.time = MOCK.time + 0.2
    for _, rr in ipairs(v.list.rows) do if rr:IsShown() and rr.item and rr.item.pr and rr.item.pr.r == r then row = rr end end
    row:Fire("OnClick", "LeftButton")
    check(UI.IsShown(), "a double click opens the tracker")
    check(P.Frame().trackerSwitch:GetOn(), "title-bar switch follows the tracker")

    -- The switch hides it; Track opens it on the selection.
    P.Frame().trackerSwitch:Fire("OnClick", "LeftButton")
    check(not UI.IsShown() and not P.Frame().trackerSwitch:GetOn(), "switch hides the tracker")
    check(P.Frame().action:IsShown() and P.Frame().action.label:GetText() == "Track", "Track in the footer")
    P.Frame().action:Fire("OnClick", "LeftButton")
    check(UI.IsShown(), "Track opens the tracker")
    P.Frame().trackerSwitch:Fire("OnClick", "LeftButton")
    P.Frame().trackerSwitch:Fire("OnClick", "LeftButton")
    check(UI.IsShown(), "switch shows it again (on the selected recipe)")
end

-- A plan step's Craft button: exactly one craft command per click, never
-- from a row click, never in combat.
scenarios.character_plan_craft = function()
    local ns = setup()
    local P = ns.ProfessionsUI
    TALODDB.profPlanProf = "Tailoring"
    TALODDB.profPlanTargets["Tailoring"] = 75
    P.ShowPage("plan")
    local v = P.views.plan
    -- The mock has no layout: give the steps list room for its rows.
    v.steps:SetHeight(600)
    v.steps:Fire("OnSizeChanged")
    local row
    for _, r in ipairs(v.steps.rows) do
        if r:IsShown() and r.rowButton and r.rowButton:IsShown() and r.item.craft then row = r break end
    end
    check(row, "a step with a Craft button")
    local craft = row.item.craft
    check(row.rowButton.kind == "send", "the Craft button is a send button")
    check(row.rowButton.label:GetText() == "Craft " .. craft.count, "button says the count: " .. tostring(row.rowButton.label:GetText()))

    -- The Tailoring window is open and lists the recipe.
    local calls = {}
    function GetTradeSkillLine() return "Tailoring", 60, 75 end
    function GetNumTradeSkills() return 1 end
    function GetTradeSkillInfo(i) if i == 1 then return craft.recipe.name, "optimal", 99 end end
    function DoTradeSkill(i, k) calls[#calls + 1] = { i, k } end
    C_TradeSkillUI = nil

    row.rowButton:Fire("OnClick", "LeftButton")
    check(#calls == 1 and calls[1][1] == 1 and calls[1][2] == craft.count, "one click: one craft command with the count")
    row:Fire("OnClick", "LeftButton")
    check(#calls == 1, "a click on the row itself crafts nothing")
    MOCK.RunTimers()
    MOCK.Tick(1)
    check(#calls == 1, "nothing repeats by itself")
    row.rowButton:Fire("OnClick", "LeftButton")
    check(#calls == 2, "the next click: the next command")
    MOCK.units.player.combat = true
    P.Refresh()
    for _, r in ipairs(v.steps.rows) do if r:IsShown() and r.item and r.item.craft == craft then row = r end end
    check(not row.rowButton:IsEnabled(), "Craft disabled in combat")
    row.rowButton:Fire("OnClick", "LeftButton")
    check(#calls == 2, "no craft in combat")
    MOCK.units.player.combat = false

    -- Right-click a step header: skip that recipe (an exclusion, no craft).
    local excluded
    for _, r in ipairs(v.steps.rows) do
        if r:IsShown() and r.item and r.item.recipe and not r.item.craft then
            local id = r.item.recipe.id
            r:Fire("OnClick", "RightButton")
            check(TALODDB.profPlanExcluded[id], "right-click excludes")
            excluded = true
            break
        end
    end
    check(excluded and #calls == 2, "exclusion crafts nothing")
end

-- Tool options: bound once, as tool options, at their page.
scenarios.character_tool_options = function()
    local ns, binds = setup({ binds = true })
    ns.GearUI.ShowPage("enhance")
    ns.ProfessionsUI.ShowPage("plan")
    hideAll(ns)
    ns.GearUI.ShowPage("gear")
    ns.ProfessionsUI.ShowPage("profit")
    local want = {
        profPlanPatterns = "prof/plan", profPlanBags = "prof/plan", profPlanResale = "prof/plan",
        profPlanTargets = "prof/plan", profPlanFrom = "prof/plan", profPlanExcluded = "prof/plan",
        enhanceHidden = "gear/enhance", enhanceMineOnly = "gear/enhance",
    }
    local seen = {}
    for _, b in ipairs(binds) do
        if want[b.key] then
            seen[b.key] = (seen[b.key] or 0) + 1
            check(b.kind == "tool" and b.where == want[b.key], b.key .. " bound as a tool at " .. want[b.key] .. ": " .. tostring(b.where))
        end
    end
    for key in pairs(want) do check(seen[key] == 1, key .. " bound once: " .. tostring(seen[key])) end
    -- The saved keys keep their shapes.
    check(type(TALODDB.profPlanTargets) == "table" and type(TALODDB.profPlanFrom) == "table" and type(TALODDB.profPlanExcluded) == "table"
        and type(TALODDB.enhanceHidden) == "table" and type(TALODDB.enhanceMineOnly) == "boolean", "shapes unchanged")
end

-- Old view keys and old commands land on the new pages.
scenarios.character_old_routes = function()
    local ns = setup()
    local G = ns.GearUI
    local keys = {
        { "gear", "gear/gear:gear" }, { "snapshots", "gear/gear:gear" }, { "ledger", "gear/ledger:ledger" },
        { "sources", "gear/ledger:sources" }, { "progress", "gear/progress:progress" }, { "enhance", "gear/enhance:enhance" },
        { "skills", "prof/skills:skills" }, { "professions", "prof/plan:plan" }, { "crafting", "prof/log:log" },
    }
    for _, k in ipairs(keys) do
        hideAll(ns)
        G.Show(k[1])
        check(where(ns) == k[2], "GearUI.Show(" .. k[1] .. ") -> " .. where(ns))
        hideAll(ns)
        G.Toggle(k[1])
        check(where(ns) == k[2], "GearUI.Toggle(" .. k[1] .. ") -> " .. where(ns))
    end
    local commands = {
        { "char", "gear/" }, { "character", "gear/" }, { "gear", "gear/gear:gear" },
        { "skills", "prof/skills:skills" }, { "enhance", "gear/enhance:enhance" }, { "enchants", "gear/enhance:enhance" },
        { "plan", "prof/plan:plan" }, { "professions", "prof/plan:plan" }, { "prof", "prof/plan:plan" },
        { "crafts", "prof/log:log" }, { "crafting", "prof/log:log" },
    }
    for _, c in ipairs(commands) do
        hideAll(ns)
        slash(c[1])
        check(where(ns):sub(1, #c[2]) == c[2], "/" .. c[1] .. " -> " .. where(ns))
    end
    -- The same word again closes it (toggle), as before.
    slash("crafts")
    check(not ns.ProfessionsUI.IsShown(), "crafts again closes")

    -- Plan with a profession and a target / range.
    hideAll(ns)
    slash("plan tailoring 70")
    check(where(ns) == "prof/plan:plan" and TALODDB.profPlanProf == "Tailoring" and TALODDB.profPlanTargets.Tailoring == 70, "plan tailoring 70")
    slash("plan tailoring 60-90")
    check(where(ns) == "prof/plan:plan" and TALODDB.profPlanTargets.Tailoring == 90, "plan from-to keeps the page open")
    check(ns.ProfessionsUI.views.plan.plan.from == 60, "start set by hand")

    -- Snapshot now: the command and the title-bar button.
    local c = TALODDB.gear[ns.Gear.CharKey()]
    local before = c and #c.snapshots or 0
    hideAll(ns)
    slash("gear snap Raid set")
    c = TALODDB.gear[ns.Gear.CharKey()]
    check(c and #c.snapshots == before + 1 and c.snapshots[#c.snapshots].name == "Raid set", "gear snap")
    check(not ns.GearUI.IsShown(), "gear snap opens nothing")
    ns.GearUI.ShowPage("gear")
    local shown
    local real = StaticPopup_Show
    StaticPopup_Show = function(name) shown = name end
    ns.GearUI.Frame().snapshot:Fire("OnClick", "LeftButton")
    StaticPopup_Show = real
    check(shown == ns.POPUP .. "GEAR_SNAPSHOT", "Snapshot now asks for a name")
    -- Enhance from a slot on the Gear tab.
    ns.Enhance.ShowSlot(5)
    check(where(ns) == "gear/enhance:enhance" and ns.Enhance.state.slot == 5, "slot click opens Enhance")
end
