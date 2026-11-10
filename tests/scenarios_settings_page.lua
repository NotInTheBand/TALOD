-- Settings as one page: every preference has exactly one home (its section),
-- tool options and consent live on their pages, search finds by label, help
-- text and saved key, the filters (Alerts and chat, Changed with reset),
-- opening at a section, the bulk deletes that ask first and reset all.
local scenarios, T = ...
local check, boot, slash = T.check, T.boot, T.slash

local function loadMap()
    local dir = (EXTRA_SCENARIO_FILES[1] or ""):match("^(.*)/[^/]*$") or (ADDON_DIR .. "/tests")
    return assert(loadfile(dir .. "/ui_map.lua"))()
end

local function keysOf(list)
    local out = {}
    for _, row in ipairs(list) do out[row.key] = true end
    return out
end

local function count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

-- (The one-home check over every page is ui_map_one_home.)
scenarios.settings_page_one_home = function()
    local ns = boot(11509)
    ns.Options.Open()
    local map = loadMap()
    local bindings = ns.Options.Bindings()

    -- Every preference has its row on the page.
    local preferences = 0
    for _, row in ipairs(map.settings) do
        if row.type == "preference" then
            preferences = preferences + 1
            check(ns.Options.Row(row.key) ~= nil, row.key .. ": a row on the page")
        end
    end
    check(preferences >= 120, "preferences checked: " .. preferences)

    -- The look's three settings, in General.
    for _, key in ipairs({ "classicLook", "textSize", "compactRows" }) do
        check(bindings[key] and bindings[key]["settings/general"] == "home", key .. " in General")
    end
    local cb = ns.Options.Row("classicLook").control
    cb:SetChecked(true); cb:Fire("OnClick")
    check(TALODDB.classicLook == true and ns.Style.Look() == "classic", "Classic look applies the look")
    cb:SetChecked(false); cb:Fire("OnClick")
    check(ns.Style.Look() == "ledger", "and back")

    -- The duplicate alerts checkbox is gone: one alertsEnabled control.
    local alertBoxes = 0
    for _, f in ipairs(MOCK.frames) do
        if f._kind == "CheckButton" and f.label and (f.label:GetText() == "Enemy alerts (center text, sound, chat)"
            or f.label:GetText() == "Enable alerts") then
            alertBoxes = alertBoxes + 1
        end
    end
    check(alertBoxes == 1, "one alerts checkbox: " .. alertBoxes)

    -- Thirteen sections in page order, each with a status line.
    check(#ns.Options.SECTIONS == #map.sections, "13 sections")
    local last = -1
    for i, sec in ipairs(map.sections) do
        check(ns.Options.SECTIONS[i].key == sec.key, "section order " .. sec.key)
        local top = ns.Options.SectionTop(sec.key)
        check(top and top > last, "section " .. sec.key .. " below the one before")
        last = top or last
    end
    check(ns.Options.SETTINGS and #ns.Options.SETTINGS >= #map.settings, "the settings list ships")

    -- Content that left Settings: no journal overview, no lists, no census page.
    local win = _G[ns.FRAME .. "OptionsWindow"]
    local function inSettings(f)
        local p = f
        while p do
            if p == win then return true end
            p = p.GetParent and p:GetParent() or nil
        end
        return false
    end
    for _, f in ipairs(MOCK.frames) do
        local text = f._kind == "FontString" and f:GetText() or ""
        check(not (tostring(text):find("Where you meet enemies") and inSettings(f)), "journal overview is on the Enemies page")
    end
end

scenarios.settings_search_and_filters = function()
    local ns = boot(11509)
    local O = ns.Options
    O.Open()
    local map = loadMap()

    -- By label, by help words, by saved key.
    O.SetSearch("apply-lure")
    check(O.ResultsShown() and keysOf(O.Results(O.Search(), O.Filter())).fishLureButton, "search by label")
    check(#O.ResultRows() >= 1, "result rows drawn")
    O.SetSearch("bobber")
    check(keysOf(O.Results(O.Search(), O.Filter())).fishEnemySound, "search by help text")
    O.SetSearch("journalMergeMinutes")
    local found = O.Results(O.Search(), O.Filter())
    check(#found == 1 and found[1].key == "journalMergeMinutes", "search by saved key")

    -- A tool option: where it lives, and Go opens that page.
    O.SetSearch("Hands Free: a click")
    found = O.Results(O.Search(), O.Filter())
    check(keysOf(found).guildHandsFree, "tool option found")
    local row
    for _, r in ipairs(O.ResultRows()) do if r.key == "guildHandsFree" then row = r end end
    check(row and row.path:GetText():find("Guild > Recruit > Find"), "says where it lives")
    local went
    ns.Nav = ns.Nav or {}
    local oldGo = ns.Nav.Go
    ns.Nav.Go = function(page, tab, view) went = page .. "/" .. tostring(tab) return true end
    row.go:Fire("OnClick", "LeftButton")
    check(went == "recruit/find", "Go opens the Recruit page: " .. tostring(went))
    ns.Nav.Go = oldGo

    -- Go on a setting of this page scrolls to it and flashes it.
    O.GoTo("panelRows")
    check(not O.ResultsShown() and O.Search() == "", "back on the page")
    check(O.LastFlash() == "panelRows" and O.ScrollOffset() > 0, "scrolled to the row and flashed it")

    -- Alerts and chat: every notify setting, once per key.
    local notify = {}
    for _, r in ipairs(map.settings) do if r.notify then notify[r.key] = true end end
    O.SetFilter("notify")
    check(O.ResultsShown() and #O.Results("", "notify") == count(notify), "Alerts and chat: " .. #O.Results("", "notify")
        .. " of " .. count(notify))

    -- Changed: one more after changing a value; reset brings the default back.
    O.SetFilter("changed")
    local before = #O.Results("", "changed")
    TALODDB.panelRows = 12
    ns.Refresh()
    local after = O.Results("", "changed")
    check(#after == before + 1 and keysOf(after).panelRows, "Changed lists it")
    local resetRow
    for _, r in ipairs(O.ResultRows()) do if r.key == "panelRows" then resetRow = r end end
    check(resetRow and resetRow.reset:IsShown(), "with a reset arrow")
    resetRow.reset:Fire("OnClick", "LeftButton")
    check(TALODDB.panelRows == 8 and #O.Results("", "changed") == before, "reset restores the default")
    -- The reset glyph on the row itself.
    TALODDB.alertRepeatSeconds = 300
    ns.Refresh()
    local r = O.Row("alertRepeatSeconds")
    check(r.mark:IsShown() and r.reset:IsShown(), "changed mark and reset on the row")
    r.reset:Fire("OnClick", "LeftButton")
    check(TALODDB.alertRepeatSeconds == 120 and not r.mark:IsShown(), "row reset")

    O.SetFilter("all")
    check(not O.ResultsShown(), "All shows the page")
end

scenarios.settings_open_section = function()
    local ns = boot(11509)
    local O = ns.Options
    O.OpenSection("data")
    check(O.IsShown() and O.CurrentSection() == "data", "opens at Data")
    check(O.ScrollOffset() == O.SectionTop("data") and O.ScrollOffset() > 0, "scrolled to Data")
    O.OpenSection("prof")
    check(O.CurrentSection() == "professions", "a page word opens its section")
    O.OpenSection("Auction House")
    check(O.CurrentSection() == "ah", "a section label")
    ns.Style.OpenSettings("fishing")
    check(O.CurrentSection() == "fishing", "the page gear")
    O.OpenSection(nil, "loud")
    check(O.ResultsShown() and O.Search() == "loud", "search words")
    O.OpenSection("splash sound")
    check(O.ResultsShown() and keysOf(O.Results(O.Search(), O.Filter())).fishLoudSplash, "unknown words search")
    O.OpenSection("general")
    check(not O.ResultsShown() and O.CurrentSection() == "general", "a section clears the search")
    slash("settings guild")
    check(O.CurrentSection() == "guild", "/talod settings <section>")

    -- The left list jumps.
    local went
    ns.Nav = ns.Nav or {}
    local oldGo = ns.Nav.Go
    ns.Nav.Go = function(page, tab) went = page .. "/" .. tostring(tab) return true end
    -- Old callers: the journal and the lists are on the Enemies page.
    O.OpenTab(O.TabIndex("Journal"), 2)
    check(went == "enemies/lists", "old Journal tab opens Enemies > Lists: " .. tostring(went))
    slash("journal")
    check(went == "enemies/journal", "/talod journal")
    O.OpenTab(O.TabIndex("Fishing"), 1)
    check(O.CurrentSection() == "fishing", "old Fishing tab")
    O.Section("audit").openButton:Fire("OnClick", "LeftButton")
    check(went == "audit/nil", "Open page")
    ns.Nav.Go = oldGo
end

scenarios.settings_delete_data_asks = function()
    local ns = boot(11509)
    local O = ns.Options
    TALODDB.journal[1] = { key = "Old", name = "Old", t = MOCK.now - 40 * 86400, zone = "Elwynn Forest" }
    TALODDB.journal[2] = { key = "New", name = "New", t = MOCK.now - 60, zone = "Elwynn Forest" }
    local q = ns.Store.Quarantined()
    q[#q + 1] = { t = MOCK.now, key = "x", path = "x", reason = "test" }
    O.OpenSection("data")

    local function press(store, text)
        local b = O.DeleteButton(store, text)
        check(b ~= nil, store .. " / " .. text .. " button")
        MOCK.popup = nil
        b:Fire("OnClick", "LeftButton")
        return MOCK.popup
    end

    -- Asking, then No: nothing goes.
    check(press("Sightings", "30+ days") == ns.POPUP .. "DELETE", "sightings ask first")
    check(#TALODDB.journal == 2, "nothing deleted before Yes")
    MOCK.popup = nil
    check(#TALODDB.journal == 2, "No keeps them")
    press("Sightings", "30+ days")
    MOCK.AcceptPopup()
    check(#TALODDB.journal == 1 and TALODDB.journal[1].key == "New", "Yes deletes the old one")
    press("Sightings", "All")
    MOCK.AcceptPopup()
    check(#TALODDB.journal == 0, "all sightings")

    check(press("Set-aside entries", "Delete") == ns.POPUP .. "SET_ASIDE_DELETE", "set-aside entries ask first")
    check(#ns.Store.Quarantined() == 1, "kept until Yes")
    MOCK.AcceptPopup()
    check(#ns.Store.Quarantined() == 0, "deleted on Yes")

    check(press("Census", "All") == ns.POPUP .. "CENSUS_DELETE", "census asks")
    MOCK.popup = nil
    check(press("Fishing casts", "Delete") == ns.POPUP .. "FISHING_DELETE" and MOCK.popupData == "casts", "fishing casts ask")
    MOCK.popup = nil
    check(press("All fishing data", "Delete") == ns.POPUP .. "FISHING_DELETE" and MOCK.popupData == "all", "all fishing asks")
    MOCK.popup = nil
    check(press("Gear", "This character") == ns.POPUP .. "GEAR_DELETE", "gear asks")
    MOCK.popup = nil
    check(press("Skills", "This character") == ns.POPUP .. "SKILLS_DELETE", "skills asks")
    MOCK.popup = nil
    check(press("Economy", "This character") == ns.POPUP .. "ECONOMY_DELETE", "economy asks")
    MOCK.popup = nil
end

scenarios.settings_reset_all_asks = function()
    local ns = boot(11509)
    local O = ns.Options
    O.OpenSection("advanced")
    TALODDB.panelRows = 15
    MOCK.popup = nil
    O.resetButton:Fire("OnClick", "LeftButton")
    check(MOCK.popup == ns.POPUP .. "RESET" and TALODDB.panelRows == 15, "asks first, changes nothing yet")
    MOCK.AcceptPopup()
    check(TALODDB.panelRows == 8, "reset on Yes")
    -- Never in combat.
    TALODDB.panelRows = 15
    MOCK.lockdown = true
    MOCK.popup = nil
    O.resetButton:Fire("OnClick", "LeftButton")
    check(MOCK.popup == nil and TALODDB.panelRows == 15, "not in combat")
    MOCK.lockdown = false

    -- The other Advanced rows build and act.
    TALODDB.outboxBurst = 3
    O.Refresh()
    check(ns.Outbox.Learned(), "a learned limit")
    local forget
    for _, f in ipairs(MOCK.frames) do
        if f._kind == "Button" and f.label and f.label:GetText() == "Forget learned limit" then forget = f end
    end
    forget:Fire("OnClick", "LeftButton")
    check(not ns.Outbox.Learned(), "Forget learned limit")
end
