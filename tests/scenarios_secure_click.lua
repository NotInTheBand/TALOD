-- Secure buttons and clicks.
-- 1. A model of the client's protected-frame rule: in combat, no restricted
--    call (show, hide, move, size, scale, parent, attribute, level, strata,
--    mouse) on a secure button, nor a move / size / show on a frame a secure
--    button anchors to (with that frame's parents and anchors), through every
--    redraw, look switch, drag, reset, page and piece switch.
-- 2. Floating pieces sit above the Enemies panel's target overlays; the swap
--    and lure buttons above the fishing HUD.
-- 3. A click acts on the item that was under the cursor when the press
--    began: a list redrawn between press and release sends nothing.
-- 4. The Weapon row button stays away once combat starts, even when a redraw
--    runs before the lock; nameplate distance is not changed in combat.
local scenarios, T = ...
local check, plateAdd, printed, resetOutput = T.check, T.plateAdd, T.printed, T.resetOutput

local SWORD, SHIELD, POLE = 2000, 2001, 6256

---------------------------------------------------------------------------
-- The protected-frame model
---------------------------------------------------------------------------
local Widget
do
    local idx = getmetatable(UIParent).__index
    for i = 1, 10 do
        local n, v = debug.getupvalue(idx, i)
        if n == "Widget" then Widget = v break end
        if not n then break end
    end
end

local SECURE_CALLS = { Show = 1, Hide = 1, SetShown = 1, SetPoint = 1, ClearAllPoints = 1, SetAllPoints = 1, SetSize = 1,
    SetWidth = 1, SetHeight = 1, SetScale = 1, SetParent = 1, SetAttribute = 1, SetFrameLevel = 1, SetFrameStrata = 1, EnableMouse = 1 }
local FAMILY_CALLS = { Show = 1, Hide = 1, SetShown = 1, SetPoint = 1, ClearAllPoints = 1, SetAllPoints = 1, SetSize = 1,
    SetWidth = 1, SetHeight = 1, SetScale = 1, SetParent = 1 }

local violations, seen = {}, {}
local probe = { on = false, step = nil, family = nil }

local function nameOf(w)
    if w == nil then return "nil" end
    if w._name then return w._name end
    local p, path = w, {}
    while p and not p._name do path[#path + 1] = p._kind or "?" p = p._parent end
    return (p and p._name or "?") .. "/" .. table.concat(path, "<")
end

local function anchorsOf(w)
    local out = {}
    for _, p in ipairs(w._points or {}) do
        local rel = p[2]
        if type(rel) == "string" then rel = _G[rel] end
        if type(rel) == "table" and rel ~= UIParent then out[#out + 1] = rel end
    end
    if w._allPoints and w._allPoints ~= UIParent then out[#out + 1] = w._allPoints end
    return out
end

local function isSecure(w) return w._template == "SecureActionButtonTemplate" end

local function family()
    local fam = {}
    local function add(f, why)
        if not f or f == UIParent or fam[f] then return end
        fam[f] = why
        if f._parent then add(f._parent, why) end
        for _, a in ipairs(anchorsOf(f)) do add(a, why) end
    end
    for _, w in ipairs(MOCK.frames) do
        if isSecure(w) then
            for _, a in ipairs(anchorsOf(w)) do add(a, nameOf(w)) end
        end
    end
    return fam
end

local installed = false
local function install()
    if installed then return end
    installed = true
    -- The mock keeps no record of SetAllPoints: kept here for anchorsOf.
    Widget.SetAllPoints = function(self, rel) self._allPoints = rel end
    local clear = Widget.ClearAllPoints
    Widget.ClearAllPoints = function(self) self._allPoints = nil return clear(self) end
    for m in pairs(SECURE_CALLS) do
        local orig = Widget[m]
        Widget[m] = function(self, ...)
            if MOCK.lockdown and probe.on then
                local what
                if isSecure(self) then what = "secure"
                elseif FAMILY_CALLS[m] and probe.family and probe.family[self] then what = "anchor family of " .. probe.family[self] end
                if what then
                    local key = m .. "|" .. tostring(self)
                    if not seen[key] then
                        seen[key] = true
                        local tb = debug.traceback("", 2):gsub("\n%s*%[C%][^\n]*", "")
                        local lines = {}
                        for l in tb:gmatch("[^\n]+") do
                            local at = l:match("[/\\]([%w_]+%.lua:%d+)")
                            if at and not l:find("tests[/\\]") then lines[#lines + 1] = at end
                            if #lines >= 4 then break end
                        end
                        violations[#violations + 1] = string.format("[%s] %s:%s(%s)  <- %s", probe.step or "?", nameOf(self), m, what,
                            table.concat(lines, " | "))
                    end
                end
            end
            if orig then return orig(self, ...) end
        end
    end
end

local function equip(mh, oh)
    MOCK.equippedIDs[17] = oh
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 17, oh == nil)
    MOCK.equippedIDs[16] = mh
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 16, mh == nil)
    MOCK.Tick(1.2)
end

-- Everything built and shown: the panel with enemies and overlays, the HUD
-- with the Weapon row and lure buttons, the swap button, the mini recruit
-- window, the craft tracker and the AH scan panel.
local function setup()
    install()
    MOCK.SetGuild()
    MOCK.items[SWORD] = { classID = 2, subclassID = 7, equipLoc = "INVTYPE_WEAPON" }
    MOCK.items[SHIELD] = { classID = 4, subclassID = 6, equipLoc = "INVTYPE_SHIELD" }
    local ns = T.fishingSetup(11509, {})
    equip(SWORD, SHIELD)
    MOCK.equippedIDs[17] = nil
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 17, true)
    MOCK.Tick(0.3)
    equip(POLE, nil)
    MOCK.Tick(1.1)
    MOCK.bags[0][1] = MOCK.ItemLink(6533, "Aquadynamic Fish Attractor")
    MOCK.bagCounts["0:1"] = 3
    ns.FishingGear.Invalidate()
    MOCK.Tick(1.1) MOCK.Tick(0.6)
    TALODDB.guildMiniShown = true
    ns.GuildUI.RefreshMini({})
    local _, recipe = next(ns.ProfessionData.recipes)
    ns.CraftTrackUI.Open(recipe)
    function CanSendAuctionQuery() return true, true end
    function QueryAuctionItems() end
    function GetNumAuctionItems() return 0, 0 end
    function GetAuctionItemInfo() return nil end
    MOCK.FireEvent("AUCTION_HOUSE_SHOW")
    MOCK.RunTimers()
    plateAdd("nameplate1", MOCK.Enemy({ level = 30 }))
    plateAdd("nameplate2", MOCK.Enemy({ level = 31, name = "Other" }))
    MOCK.Tick(0.3) MOCK.Tick(1.1)
    return ns
end

local function step(name, fn)
    probe.step = name
    local ok, err = pcall(fn)
    if not ok then violations[#violations + 1] = "[" .. name .. "] Lua error: " .. tostring(err) end
end

local function exercise(ns)
    step("tick", function() MOCK.Tick(0.3) MOCK.Tick(1.1) end)
    step("enemy leaves/new", function()
        plateAdd("nameplate3", MOCK.Enemy({ level = 32, name = "Third" }))
        MOCK.Tick(0.3) MOCK.Tick(1.1)
    end)
    step("refresh", function() ns.Refresh() end)
    step("look classic", function() TALODDB.classicLook = true ns.Style.ApplySettings() ns.Refresh() end)
    step("look ledger", function() TALODDB.classicLook = nil ns.Style.ApplySettings() ns.Refresh() end)
    step("compact/text", function() TALODDB.compactRows = true TALODDB.textSize = 13 ns.Style.ApplySettings() ns.Refresh() MOCK.Tick(0.3) end)
    step("panel scale", function() TALODDB.panelScale = 1.2 ns.Refresh() MOCK.Tick(0.3) end)
    step("panel bar lock/mute", function()
        TALODPanel.floatBar.lock:Fire("OnClick", "LeftButton")
        TALODPanel.floatBar.switch:Fire("OnClick", "LeftButton")
        TALODPanel.floatBar.switch:Fire("OnClick", "LeftButton")
    end)
    step("hud bar lock", function() TALODFishingHUD.floatBar.lock:Fire("OnClick", "LeftButton") end)
    step("panel drag", function() TALODPanel:Fire("OnDragStart") TALODPanel:Fire("OnDragStop") end)
    step("hud drag", function()
        TALODFishingHUD._cx, TALODFishingHUD._cy = 100, 100
        UIParent._cx, UIParent._cy = 960, 540
        TALODFishingHUD:Fire("OnDragStart") TALODFishingHUD:Fire("OnDragStop")
    end)
    step("hud reset", function() if ns.FishingUI.ResetHUD then ns.FishingUI.ResetHUD() end end)
    step("panel reset", function() ns.Panel.ResetPosition() end)
    for _, key in ipairs({ "panel", "hud", "tracker", "mini", "scan", "flag", "minimap" }) do
        step("SetPiece " .. key .. " off", function() ns.Nav.SetPiece(key, false) MOCK.Tick(0.3) end)
        step("SetPiece " .. key .. " on", function() ns.Nav.SetPiece(key, true) MOCK.Tick(0.3) end)
    end
    step("bar hides", function()
        for _, f in ipairs({ TALODPanel, TALODFishingHUD, TALODCraftTrack, TALODAHPanel }) do
            if f and f.floatBar and f.floatBar.hide then f.floatBar.hide:Fire("OnClick", "LeftButton") end
        end
        MOCK.Tick(0.3)
    end)
    step("home / pages", function()
        for _, p in ipairs(ns.Nav.PAGES or {}) do ns.Nav.Go(p.key) MOCK.Tick(0.3) end
        ns.Nav.CloseAll()
    end)
    step("escape", function()
        for _, n in ipairs(UISpecialFrames) do local f = _G[n] if f and f.IsShown and f:IsShown() then f:Hide() end end
    end)
    step("enemy plates gone", function()
        MOCK.FireEvent("NAME_PLATE_UNIT_REMOVED", "nameplate1")
        MOCK.FireEvent("NAME_PLATE_UNIT_REMOVED", "nameplate2")
        MOCK.FireEvent("NAME_PLATE_UNIT_REMOVED", "nameplate3")
        MOCK.Tick(0.3) MOCK.Tick(1.1)
    end)
    step("panel off", function() TALODDB.panelShown = false ns.Refresh() MOCK.Tick(0.3) end)
    step("disable addon", function() TALODDB.enabled = false ns.Refresh() MOCK.Tick(0.3) TALODDB.enabled = true ns.Refresh() end)
    step("swap to sword", function() equip(SWORD, SHIELD) MOCK.Tick(1.1) end)
    step("pole again", function() equip(POLE, nil) MOCK.Tick(1.1) end)
    step("AH closed", function() MOCK.FireEvent("AUCTION_HOUSE_CLOSED") MOCK.Tick(0.3) end)
end

local function shownSecure()
    local out = {}
    for _, w in ipairs(MOCK.frames) do
        if isSecure(w) and w:IsShown() then
            local a = anchorsOf(w)[1]
            out[#out + 1] = nameOf(w) .. (a and (" anchored->" .. nameOf(a)) or "")
        end
    end
    return out
end

scenarios.secure_no_restricted_calls_in_combat = function()
    local ns = setup()
    local before = shownSecure()
    check(#before >= 4, "before combat: overlays, row, lure and swap buttons shown: " .. table.concat(before, ", "))
    MOCK.FireEvent("PLAYER_REGEN_DISABLED")
    MOCK.lockdown = true
    probe.family = family()
    local famList = {}
    for f, why in pairs(probe.family) do famList[#famList + 1] = nameOf(f) .. " (" .. why .. ")" end
    check(#famList == 0, "in combat no secure button is anchored to an addon frame: " .. table.concat(famList, ", "))
    for _, s in ipairs(shownSecure()) do
        check(not s:find("anchored->", 1, true), "shown in combat, anchored to UIParent only: " .. s)
    end
    probe.on = true
    exercise(ns)
    probe.on = false
    MOCK.lockdown = false
    for _, v in ipairs(violations) do print("VIOLATION " .. v) end
    check(#violations == 0, #violations .. " restricted call(s) in combat: " .. table.concat(violations, " ; "))
end

---------------------------------------------------------------------------
-- Frame order: floating pieces over the panel's overlays
---------------------------------------------------------------------------
local STRATA = { BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5, FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8 }
local function Above(a, b)
    local sa, sb = STRATA[a:GetFrameStrata() or "MEDIUM"] or 3, STRATA[b:GetFrameStrata() or "MEDIUM"] or 3
    if sa ~= sb then return sa > sb end
    return (a:GetFrameLevel() or 0) > (b:GetFrameLevel() or 0)
end

scenarios.secure_float_pieces_above_overlays = function()
    setup()
    local overlays = {}
    for _, w in ipairs(MOCK.frames) do
        if isSecure(w) and w:GetAttribute("type") == "target" and w:IsShown() then overlays[#overlays + 1] = w end
    end
    check(#overlays >= 2, "panel target overlays shown: " .. #overlays)
    for _, name in ipairs({ "GuildMini", "FishingHUD", "CraftTrack", "AHPanel" }) do
        local f = _G["TALOD" .. name]
        check(f ~= nil and f:IsShown(), name .. " built and shown")
        for _, o in ipairs(overlays) do
            check(f and Above(f, o), name .. " is above the panel overlays (" .. tostring(f and f:GetFrameStrata()) .. " "
                .. tostring(f and f:GetFrameLevel()) .. " vs " .. tostring(o:GetFrameStrata()) .. " " .. tostring(o:GetFrameLevel()) .. ")")
        end
    end
    -- The overlays keep their place: still over the panel's rows.
    for _, o in ipairs(overlays) do
        local a = anchorsOf(o)[1]
        check(a and a._parent == TALODPanel, "overlay still covers a panel row")
        check(Above(o, TALODPanel), "overlay above its panel")
    end
    -- Under the HUD: the swap and lure buttons stay above it.
    local hud = TALODFishingHUD
    for _, name in ipairs({ "FishingSwapButton", "FishingLureButton" }) do
        local b = _G["TALOD" .. name]
        check(b and b:IsShown(), name .. " shown")
        check(b and Above(b, hud), name .. " above the HUD (" .. tostring(b and b:GetFrameLevel()) .. " vs " .. tostring(hud:GetFrameLevel()) .. ")")
        local a = b and b._points and b._points[1]
        local rel = a and a[2]
        if type(rel) == "string" then rel = _G[rel] end
        if name == "FishingSwapButton" then check(rel == UIParent, "the swap button is still anchored to UIParent") end
    end
    -- The Weapon row button is over its row, above the HUD.
    local rb = TALODFishingWeaponRowButton
    check(rb and rb:IsShown() and Above(rb, hud), "the Weapon row button above the HUD")
end

---------------------------------------------------------------------------
-- A click acts on the item pressed
---------------------------------------------------------------------------
scenarios.secure_list_click_acts_on_pressed_item = function()
    local ns = T.boot(11509)
    local Style = ns.Style
    local parent = CreateFrame("Frame", nil, UIParent)
    parent:SetSize(400, 300)
    local rowClicks, buttonClicks = {}, {}
    local labels = {}
    local list = Style.List(parent, { rowButtonWidth = 60,
        onClick = function(item, button) rowClicks[#rowClicks + 1] = item.key .. ":" .. tostring(button) end,
        rowButton = function(item)
            return { label = labels[item.key] or "Go", kind = "send", onClick = function(it) buttonClicks[#buttonClicks + 1] = it.key end }
        end })
    list._height = 300
    local function rows(...)
        local out = {}
        for _, k in ipairs({ ... }) do out[#out + 1] = { key = k, text = k } end
        return out
    end
    list:SetItems(rows("a", "b"))
    list:Draw()
    local row = list.rows[1]
    check(row.item.key == "a", "row 1 shows a")

    -- A click with no press seen (a key binding, /click): the row as it is.
    row:Fire("OnClick", "LeftButton")
    check(rowClicks[1] == "a:LeftButton", "no press seen: acts on the row")

    -- Pressed on a, the list redraws (a left), released on b: nothing.
    resetOutput()
    row:Fire("OnMouseDown", "LeftButton")
    list:SetItems(rows("b"))
    check(row.item.key == "b", "row 1 now shows b")
    row:Fire("OnClick", "LeftButton")
    check(#rowClicks == 1, "the row changed under the press: no action")
    check(printed("list changed"), "the player is told")
    -- The next whole click: b.
    row:Fire("OnMouseDown", "LeftButton")
    row:Fire("OnClick", "LeftButton")
    check(rowClicks[2] == "b:LeftButton", "a new press on b acts on b")

    -- A redraw that keeps the same item (new tables, same key) still clicks.
    row:Fire("OnMouseDown", "RightButton")
    list:SetItems(rows("b"))
    row:Fire("OnClick", "RightButton")
    check(rowClicks[3] == "b:RightButton", "same item after a redraw: the click goes through")

    -- The row's send button: same rule.
    list:SetItems(rows("a", "b"))
    local rb = row.rowButton
    check(rb and rb:IsShown(), "row button drawn")
    rb:Fire("OnMouseDown", "LeftButton")
    list:SetItems(rows("b", "a"))
    rb:Fire("OnClick", "LeftButton")
    check(#buttonClicks == 0, "row button: the item changed under the press, nothing sent")
    rb:Fire("OnMouseDown", "LeftButton")
    rb:Fire("OnClick", "LeftButton")
    check(buttonClicks[1] == "b", "row button: a new press sends to b")
    -- Same item, but the action changed ("Craft 5" became "Craft 4").
    rb:Fire("OnMouseDown", "LeftButton")
    labels.b = "Other"
    list:Draw()
    check(rb.label:GetText() == "Other", "button relabelled")
    rb:Fire("OnClick", "LeftButton")
    check(#buttonClicks == 1, "row button: the action changed under the press, nothing sent")
    rb:Fire("OnMouseDown", "LeftButton")
    rb:Fire("OnClick", "LeftButton")
    check(#buttonClicks == 2, "a new press: sent")
    -- A right-click on the button is the row's right-click, checked once.
    local n = #rowClicks
    rb:Fire("OnMouseDown", "RightButton")
    rb:Fire("OnClick", "RightButton")
    check(#rowClicks == n + 1 and #buttonClicks == 2, "right-click on the button: the row's right-click, no send")
end

-- The mini recruit window: the candidate under the press gets the whisper;
-- a list that shifted under the press sends nothing.
scenarios.secure_mini_click_pressed_candidate = function()
    MOCK.SetGuild()
    local ns = T.boot(11509)
    MOCK.cvars.nameplateShowFriends = "1"
    local UI = ns.GuildUI
    plateAdd("nameplate1", MOCK.Friend({ name = "Newbie", guid = "Player-1-N", level = 12 }))
    plateAdd("nameplate2", MOCK.Friend({ name = "Second", guid = "Player-1-S", level = 14 }))
    for _ = 1, 10 do MOCK.Tick(0.5) end
    TALODDB.guildMiniShown = true
    UI.RefreshMini()
    local list = TALODGuildMini.list
    list._height = 300
    list:Draw()
    local byName = {}
    for _, r in ipairs(list.rows) do
        if r:IsShown() and r.item and r.item.full then byName[r.item.full] = r.item end
    end
    check(byName["Newbie-Mockrealm"] and byName["Second-Mockrealm"], "both candidates listed")
    local row = list.rows[1]
    local first = row.item.full
    local other = first == "Newbie-Mockrealm" and "Second-Mockrealm" or "Newbie-Mockrealm"
    local w0, i0 = #MOCK.whispers, #MOCK.guildInvites
    row:Fire("OnMouseDown", "LeftButton")
    -- The first candidate walks out of range: the other moves up.
    list:SetItems({ byName[other] })
    check(row.item.full == other, "row 1 now shows the other player")
    row:Fire("OnClick", "LeftButton")
    check(#MOCK.whispers == w0 and #MOCK.guildInvites == i0, "nothing sent to the player who moved under the press")
    row:Fire("OnMouseDown", "LeftButton")
    row:Fire("OnClick", "LeftButton")
    check(#MOCK.whispers == w0 + 1, "a new press: one whisper")
    local last = MOCK.whispers[#MOCK.whispers]
    local to = type(last) == "table" and (last.target or last.to or last[2] or last[1]) or tostring(last)
    check(tostring(to):find(other:match("^[^-]+"), 1, true), "to the player under the press: " .. tostring(to))
end

-- Professions: a Craft button whose count changed under the press crafts nothing.
scenarios.secure_craft_button_pressed_step = function()
    MOCK.skillLines = { { "Professions", true, true }, { "Tailoring", false, nil, 60, 0, 0, 75 } }
    for i = 1, 5 do MOCK.bags[0][i] = MOCK.ItemLink(2589, "Linen Cloth") end
    function GetItemInfo(id)
        if id == 2589 then return "Linen Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132889, 13, 7, 5, 0 end
        if id == 2996 then return "Bolt of Linen Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132890, 40, 7, 5, 0 end
        if id == 2320 then return "Coarse Thread", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132891, 2, 7, 5, 0 end
    end
    local ns = T.boot(11509)
    local P = ns.ProfessionsUI
    TALODDB.profPlanProf = "Tailoring"
    TALODDB.profPlanTargets["Tailoring"] = 75
    P.ShowPage("plan")
    local v = P.views.plan
    v.steps:SetHeight(600)
    v.steps:Fire("OnSizeChanged")
    local row
    for _, r in ipairs(v.steps.rows) do
        if r:IsShown() and r.rowButton and r.rowButton:IsShown() and r.item.craft then row = r break end
    end
    check(row, "a step with a Craft button")
    local craft = row.item.craft
    local calls = {}
    function GetTradeSkillLine() return "Tailoring", 60, 75 end
    function GetNumTradeSkills() return 1 end
    function GetTradeSkillInfo(i) if i == 1 then return craft.recipe.name, "optimal", 99 end end
    function DoTradeSkill(i, k) calls[#calls + 1] = { i, k } end
    C_TradeSkillUI = nil

    -- Rows rebuilt with the same steps (a bag change): the click goes through.
    local function rebuilt(countDelta)
        local items = {}
        for i, it in ipairs(v.steps.all) do
            local copy = {}
            for k, x in pairs(it) do copy[k] = x end
            if it.craft then copy.craft = { recipe = it.craft.recipe, count = it.craft.count + (it == row.item and countDelta or 0) } end
            items[i] = copy
        end
        return items
    end
    row.rowButton:Fire("OnMouseDown", "LeftButton")
    v.steps:SetItems(rebuilt(0))
    row.rowButton:Fire("OnClick", "LeftButton")
    check(#calls == 1 and calls[1][2] == craft.count, "same step after a rebuild: one craft")
    -- The count changed under the press: no craft.
    row.rowButton:Fire("OnMouseDown", "LeftButton")
    v.steps:SetItems(rebuilt(1))
    check(row.rowButton.label:GetText() == "Craft " .. (craft.count + 1), "the button shows the new count")
    row.rowButton:Fire("OnClick", "LeftButton")
    check(#calls == 1, "the count changed under the press: nothing crafted")
    row.rowButton:Fire("OnMouseDown", "LeftButton")
    row.rowButton:Fire("OnClick", "LeftButton")
    check(#calls == 2 and calls[2][2] == craft.count + 1, "a new press: the count it shows")
end

---------------------------------------------------------------------------
-- Combat entry: the Weapon row button; nameplate distance
---------------------------------------------------------------------------
scenarios.secure_weapon_row_waits_for_combat_end = function()
    local ns = setup()
    local rb = TALODFishingWeaponRowButton
    check(rb and rb:IsShown(), "Weapon row button over the HUD before combat")
    -- PLAYER_REGEN_DISABLED is handed out before the lock: a redraw from a
    -- later handler must not put the button back over the HUD.
    MOCK.FireEvent("PLAYER_REGEN_DISABLED")
    check(not rb:IsShown(), "hidden as combat starts")
    ns.Refresh()
    if ns.FishingUI.UpdateHUD then ns.FishingUI.UpdateHUD() end
    ns.FishingSafety.UpdateRowButton()
    check(not rb:IsShown() and #anchorsOf(rb) == 0, "a redraw before the lock leaves it away")
    MOCK.lockdown = true
    MOCK.Tick(1.1)
    check(not rb:IsShown(), "still away in combat")
    MOCK.lockdown = false
    MOCK.FireEvent("PLAYER_REGEN_ENABLED")
    MOCK.Tick(1.1)
    check(rb:IsShown(), "back over the row after combat")
end

scenarios.secure_nameplate_distance_not_in_combat = function()
    local ns = T.boot(11509)
    MOCK.cvars.nameplateMaxDistance = "20"
    MOCK.lockdown = true
    resetOutput()
    ns.Main.SetMaxNameplateDistance()
    check(tostring(MOCK.cvars.nameplateMaxDistance) == "20", "nameplate distance untouched in combat")
    check(printed("cannot change in combat"), "the player is told")
    MOCK.lockdown = false
    ns.Main.SetMaxNameplateDistance()
    check(tonumber(MOCK.cvars.nameplateMaxDistance) == 41, "out of combat: set")
end
