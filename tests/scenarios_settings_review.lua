-- Settings: what counts as changed and what reset restores, reset all
-- settings and the look, widgets that write through opts.set, each key
-- listed once, and the Enemies fallback never loops.
local scenarios, T = ...
local check, boot = T.check, T.boot

local function changedKeys(O)
    local out = {}
    for _, r in ipairs(O.Results("", "changed")) do out[#out + 1] = r.key end
    return out
end

-- A first install: nothing reads as changed; resetting automatic cleanup
-- keeps it on (what a new install gets).
scenarios.settings_review_fresh_unchanged = function()
    local ns = boot(11509)
    local O = ns.Options
    O.Open()
    check(TALODDB.cleanAuto == true, "first install: automatic cleanup on")
    check(O.Default("cleanAuto") == true, "its default: on")
    check(not O.IsChanged("cleanAuto"), "not changed")
    local keys = changedKeys(O)
    check(#keys == 0, "first install: nothing changed: " .. table.concat(keys, ", "))
    O.ResetKey("cleanAuto")
    check(TALODDB.cleanAuto == true, "reset keeps automatic cleanup on")
    -- Turned off (as an update decides): changed, and reset is the one click back on.
    TALODDB.cleanAuto = false
    check(O.IsChanged("cleanAuto"), "off reads as changed")
    O.ResetKey("cleanAuto")
    check(TALODDB.cleanAuto == true, "reset: on")
end

-- Reset all settings applies the look and text size it reset to.
scenarios.settings_review_reset_all_look = function()
    local ns = boot(11509)
    TALODDB.classicLook = true
    TALODDB.textSize = 13
    ns.Style.ApplySettings()
    check(ns.Style.Look() == "classic", "classic look on")
    ns.Main.ResetSettings()
    check(TALODDB.classicLook == false and ns.Style.Look() == "ledger", "after reset: the default look " .. ns.Style.Look())
    check(ns.Style.textSize == TALODDB.textSize, "after reset: text size " .. tostring(ns.Style.textSize))
end

-- Slider and Cycle read through opts.get and write through opts.set, like Checkbox.
scenarios.settings_review_widget_get_set = function()
    local ns = boot(11509)
    local W = ns.Options.Widgets
    local parent = CreateFrame("Frame", nil, UIParent)
    local store = { slide = 4, cyc = "b" }
    local sets = {}
    local _, s = W.Slider(parent, -10, "reviewSlideKey", "Slide", 1, 10, 1, "%d", nil,
        { where = "settings/general", get = function() return store.slide end,
          set = function(v) store.slide = v sets[#sets + 1] = "slide" end })
    s:Refresh()
    check(s:GetValue() == 4, "slider shows get(): " .. tostring(s:GetValue()))
    s:SetValue(7)
    check(store.slide == 7 and sets[1] == "slide" and TALODDB.reviewSlideKey == nil, "slider writes through set, not the key")
    local choices = { { value = "a", label = "A" }, { value = "b", label = "B" }, { value = "c", label = "C" } }
    local _, c = W.Cycle(parent, -50, "reviewCycleKey", "Cycle", choices, nil,
        { where = "settings/general", get = function() return store.cyc end,
          set = function(v) store.cyc = v sets[#sets + 1] = "cycle" end })
    c:Refresh()
    c:Fire("OnClick", "LeftButton")
    check(store.cyc == "c" and sets[2] == "cycle" and TALODDB.reviewCycleKey == nil, "cycle: the next after get(), through set: " .. tostring(store.cyc))
    c:Fire("OnClick", "RightButton")
    check(store.cyc == "b", "cycle back: " .. tostring(store.cyc))
end

-- alertsEnabled is listed once, under the checkbox's label.
scenarios.settings_review_alerts_once = function()
    local ns = boot(11509)
    local O = ns.Options
    local n = 0
    for _, row in ipairs(O.SETTINGS) do if row.key == "alertsEnabled" then n = n + 1 end end
    check(n == 1, "one alertsEnabled row: " .. n)
    check(O.Setting("alertsEnabled").label == "Enable alerts", "its label: " .. O.Setting("alertsEnabled").label)
    O.Open()
    local found = 0
    for _, r in ipairs(O.Results("alertsEnabled", "all")) do if r.key == "alertsEnabled" then found = found + 1 end end
    check(found == 1, "search finds it once: " .. found)
end

-- The old Census settings tab builder is gone (its bulk deletes live in
-- Data > Delete data).
scenarios.settings_review_census_page_gone = function()
    local ns = boot(11509)
    check(ns.Census.BuildPage == nil, "no Census.BuildPage")
end

-- Without the Enemies page, its fallback opens the Enemies settings and does
-- not go round through Options.OpenTab and back.
scenarios.settings_review_enemies_fallback = function()
    local ns = boot(11509)
    local E = ns.EnemiesUI
    local saved = E and E.ShowPage
    if E then E.ShowPage = nil end
    local ok, err = pcall(ns.Nav.Go, "enemies", "journal")
    if E then E.ShowPage = saved end
    check(ok, "no loop: " .. tostring(err))
    check(ns.Options.CurrentSection() == "enemies", "Enemies settings: " .. tostring(ns.Options.CurrentSection()))
    check(ns.Options.OpenTab and pcall(ns.Options.OpenTab, "Journal", 1), "OpenTab Journal still works")
end
