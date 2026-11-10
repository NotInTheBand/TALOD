-- Pages Audit, Fishing, Groups and About: each builds in both looks, every
-- tab and view opens through ShowPage, the filters show the right records,
-- the old command words land on the right tab.
local scenarios, T = ...
local check, slash = T.check, T.slash

local GOLD = 10000

-- The game's statistics calls (Forever).
local STATS
local function statsApi()
    STATS = { mine = {}, theirs = {}, sets = 0, clears = 0 }
    GetStatistic = function(id) return STATS.mine[id] end
    GetComparisonStatistic = function(id) return STATS.theirs[id] end
    SetAchievementComparisonUnit = function(unit) STATS.sets = STATS.sets + 1 STATS.unit = unit end
    ClearAchievementComparisonUnit = function() STATS.clears = STATS.clears + 1 end
    CanInspect = function() return true end
end

local function plain(text) return (tostring(text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end

-- Rows of a list, built (lazy rows fill in when drawn or searched).
local function rowsOf(ns, list)
    for _, it in ipairs(list.items) do ns.Style.ReadyRow(it) end
    return list.items
end

local function hasRow(ns, list, needle)
    for _, it in ipairs(rowsOf(ns, list)) do
        if plain(it.text):find(needle, 1, true) or plain(it.label):find(needle, 1, true) then return it end
    end
    return nil
end

-- Every page of this set, every tab and view, in the look given.
local function buildEvery(classic)
    statsApi()
    local ns = T.fishingSetup(16001, { db = { classicLook = classic or nil } })
    local label = classic and "classic" or "ledger"
    check(ns.Style.Look() == label, "look: " .. ns.Style.Look())
    local A, F, G, About = ns.AuditUI, ns.FishingUI, ns.GroupsUI, ns.AboutUI

    -- Audit: no tabs; three filters, two detail views.
    for _, view in ipairs({ "Guild", "Flagged", "Everyone", "Ledger", "History", "members", "flags", "characters", "ledger", "history" }) do
        check(A.ShowPage(nil, view) and A.IsShown(), label .. ": audit " .. view)
    end
    check(A.state.scope == "everyone" and A.state.detail == "history", "audit: last filter and view kept")
    A.ShowPage(nil, "Guild")
    check(A.state.scope == "guild", "audit Guild")
    local af = TALODAuditWindow
    check(af.me and af.target and af.status and af.scopes and af.toggles, label .. ": audit title bar and toolbar")

    -- Fishing: tabs Now, Spots, Map, Log, Goals; Log's two views.
    for _, tab in ipairs({ "now", "spots", "map", "log", "goals" }) do
        check(F.ShowPage(tab) and F.IsShown() and TALODFishingWindow.tabs.selected == tab, label .. ": fishing " .. tab)
    end
    F.ShowPage("log", "Sessions")
    check(F.state.view == "sessions" and TALODFishingWindow.tabs.selected == "log" and TALODFishingWindow.logViews:IsShown(),
        label .. ": Log > Sessions")
    F.ShowPage("log", "Casts and encounters")
    check(F.state.view == "log" and TALODFishingWindow.logViews.selected == "log", label .. ": Log > Casts and encounters")
    F.ShowPage("now")
    check(not TALODFishingWindow.logViews:IsShown(), label .. ": view switch only on Log")

    -- Groups: Now, History (chips), one group.
    for _, tab in ipairs({ "now", "history" }) do
        check(G.ShowPage(tab) and G.IsShown() and G.state.view == tab, label .. ": groups " .. tab)
    end
    for chip, key in pairs({ All = "all", Parties = "party", Raids = "raid" }) do
        G.ShowPage("history", chip)
        check(G.state.chip == key and G.views.history:IsShown(), label .. ": groups chip " .. chip)
    end

    -- About: What's new, Commands, Credits.
    for _, tab in ipairs({ "changelog", "commands", "credits" }) do
        check(About.ShowPage(tab) and About.IsShown(tab), label .. ": about " .. tab)
    end
    check(TALODChangelogWindow.check, label .. ": Check for updates in the title bar")
    -- One page at a time: the last one opened is the one shown.
    check(TALODChangelogWindow:IsShown() and not TALODGroupsWindow:IsShown(), label .. ": one page at a time")
    return ns
end

scenarios.misc_pages_ledger = function() buildEvery(false) end
scenarios.misc_pages_classic = function() buildEvery(true) end

---------------------------------------------------------------------------
-- Audit: the filters, the detail pane, the Target button
---------------------------------------------------------------------------
local function auditSetup()
    statsApi()
    local roster = {
        { name = "Boss", rank = 0, level = 60, online = true, classFile = "WARRIOR" },
        { name = "Pal", rank = 3, level = 20, online = true, classFile = "PALADIN" },
        { name = "Tester", rank = 1, level = 20, online = true, classFile = "WARRIOR" },
    }
    MOCK.SetGuild({ rankIndex = 1, rankName = "Officer", roster = roster, can = { invite = true, promote = true } })
    local ns = T.boot(16001)
    MOCK.FireEvent("GUILD_ROSTER_UPDATE")
    MOCK.Tick(2.1)
    local A = ns.Audit
    local function look(t, v, level)
        return { t = t, src = "inspect", n = 9, v = v, d = {}, miss = {}, level = level or 20, build = "x" }
    end
    local flagged = { acquired = 300 * GOLD, peak = 280 * GOLD, looted = 20 * GOLD, quests = 15 * GOLD, vendors = 5 * GOLD,
        auctions = 0, questCount = 40, kills = 400, dungeons = 1 }
    local t0 = time()
    A.Save({ full = "Pal-Mockrealm", classFile = "PALADIN" }, look(t0 - 86400, { acquired = 100 * GOLD, peak = 20 * GOLD,
        looted = 50 * GOLD, quests = 40 * GOLD, vendors = 10 * GOLD, auctions = 0, questCount = 40, kills = 400, dungeons = 1 }))
    A.Save({ full = "Pal-Mockrealm", classFile = "PALADIN" }, look(t0, flagged))
    A.Save({ full = "Rich-Mockrealm" }, look(t0, flagged))
    -- Only the peak known: the rules cannot be checked (unknown, never fine).
    A.Save({ full = "Ghost-Mockrealm" }, { t = t0, src = "inspect", n = 1, v = { peak = 5 * GOLD }, d = {}, miss = {}, level = 60 })
    return ns
end

local function names(rows)
    local out = {}
    for _, x in ipairs(rows) do out[#out + 1] = x.full end
    table.sort(out)
    return table.concat(out, ",")
end

scenarios.misc_audit_filters = function()
    local ns = auditSetup()
    local A, UI = ns.Audit, ns.AuditUI
    check(A.FlagsOf("Pal-Mockrealm").level == "look" and A.FlagsOf("Rich-Mockrealm").level == "look", "two flagged")
    check(A.FlagsOf("Ghost-Mockrealm").level == "unknown", "one unknown")

    UI.state.noStats = false
    check(names(UI.Rows("guild")) == "Pal-Mockrealm", "Guild: members with statistics: " .. names(UI.Rows("guild")))
    check(names(UI.Rows("flagged")) == "Pal-Mockrealm,Rich-Mockrealm", "Flagged: " .. names(UI.Rows("flagged")))
    check(names(UI.Rows("everyone")) == "Ghost-Mockrealm,Pal-Mockrealm,Rich-Mockrealm", "Everyone: " .. names(UI.Rows("everyone")))
    UI.state.noStats = true
    local guild = UI.Rows("guild")
    check(names(guild) == "Boss-Mockrealm,Pal-Mockrealm,Tester-Mockrealm", "Guild + No statistics: " .. names(guild))
    check(guild[#guild].missing, "members without statistics come last")
    UI.state.membersOnly = true
    UI.state.noStats = false
    check(names(UI.Rows("flagged")) == "Pal-Mockrealm", "Flagged, members only")
    UI.state.membersOnly = false
    A.SetReview("Rich-Mockrealm", "ok")
    check(names(UI.Rows("flagged")) == "Pal-Mockrealm", "reviewed left out")
    UI.state.showReviewed = true
    check(names(UI.Rows("flagged")) == "Pal-Mockrealm,Rich-Mockrealm", "Show reviewed")
    UI.state.showReviewed, UI.state.noStats = false, true

    -- The chips on the page.
    UI.ShowPage(nil, "Guild")
    local f = TALODAuditWindow
    local list = UI.views.list.list
    check(hasRow(ns, list, "Pal") and hasRow(ns, list, "Boss") and not hasRow(ns, list, "Rich"), "Guild list")
    local boss = hasRow(ns, list, "Boss")
    check(boss.cols[1] == ns.UNKNOWN, "no statistics: unknown, never 0")
    f.scopes.chips[2]:Fire("OnClick", "LeftButton")
    check(UI.state.scope == "flagged" and hasRow(ns, list, "Pal") and not hasRow(ns, list, "Rich"), "Flagged chip")
    f.scopes.chips[3]:Fire("OnClick", "LeftButton")
    check(UI.state.scope == "everyone" and hasRow(ns, list, "Ghost") and hasRow(ns, list, "Rich"), "Everyone chip")
    local ghost = hasRow(ns, list, "Ghost")
    check(plain(ghost.text):find("?", 1, true) and not plain(ghost.text):find("No flags", 1, true), "unknown never shown as fine")
    f.toggles.chips[3]:Fire("OnClick", "LeftButton")
    check(UI.state.membersOnly and not hasRow(ns, list, "Ghost"), "Members only chip")
    f.toggles.chips[3]:Fire("OnClick", "LeftButton")
    -- Unknown counters: the Ghost's other sources stay unknown.
    check(A.Other(A.Latest(A.Record("Ghost-Mockrealm"))) == nil, "unknown other sources")

    -- Detail: a row click selects; Ledger has the flag rules on top.
    UI.ShowPage(nil, "Guild")
    local pal = hasRow(ns, list, "Pal")
    list.rows[1]:GetScript("OnClick")(list.rows[1], "LeftButton")
    local clicked = list.rows[1].item and list.rows[1].item.full
    check(clicked and A.selected == clicked, "a row click selects: " .. tostring(clicked))
    UI.ShowPage(nil, "Ledger", "Pal-Mockrealm")
    local d = UI.views.detail
    check(A.selected == "Pal-Mockrealm" and d.ledger:IsShown() and d.ledger.notice:IsShown(), "Ledger with the flag rules")
    check(plain(d.ledger.notice.headline:GetText()) == "Worth a look", "rules headline")
    check(hasRow(ns, d.ledger.list, "Income") and hasRow(ns, d.ledger.list, "Professions"), "ledger counters")
    d.switch.buttons[2]:Fire("OnClick", "LeftButton")
    check(UI.state.detail == "history" and d.history:IsShown() and #d.history.list.items == 2, "History: both looks")
    UI.ShowPage(nil, "Ledger", "Ghost-Mockrealm")
    check(d.ledger.notice:IsShown() and d.ledger.notice.headline:GetText():find("could not be checked"), "unknown: says so")
    UI.ShowPage(nil, "Ledger", "Boss-Mockrealm")
    check(d.empty:IsShown() and not d.ledger:IsShown(), "no statistics: no ledger")
    UI.ShowPage(nil, "Ledger", "Pal-Mockrealm")
    check(not hasRow(ns, d.ledger.list, "Gold carried now"), "no wallet for another player")

    -- Status line: hover shows what /talod audit status prints.
    f.statusHit:GetScript("OnEnter")(f.statusHit)
    check(f.status:GetText() ~= "", "status line")
    -- Page status: flagged records (Rich reviewed: one left).
    local st = UI.PageStatus()
    check(st and st.text == "1 flagged" and st.tone == "bad", "page status: " .. tostring(st and st.text))
end

scenarios.misc_audit_target = function()
    local ns = auditSetup()
    local A, UI = ns.Audit, ns.AuditUI
    MOCK.units.target = MOCK.Friend({ name = "Buddy", guid = "Player-1-00000B0D", level = 30 })
    UI.ShowPage()
    local f = TALODAuditWindow
    check(f.target.kind == "send", "Target is a send button")
    MOCK.Tick(6)
    local sets = STATS.sets
    f.target:Fire("OnClick", "LeftButton")
    check(STATS.sets == sets + 1, "one click: one comparison request")
    f.target:Fire("OnClick", "LeftButton")
    check(STATS.sets == sets + 1, "a second click while waiting: no second request")
    MOCK.FireEvent("INSPECT_ACHIEVEMENT_READY", "Player-1-00000B0D")
    MOCK.Tick(0.3)
    f.target:Fire("OnClick", "LeftButton")
    check(STATS.sets == sets + 1 and A.status:find("Wait"), "5 s apart: " .. tostring(A.status))
    -- Nothing goes out on its own.
    for _ = 1, 40 do MOCK.Tick(0.5) end
    check(STATS.sets == sets + 1, "never from a timer")
    f.target:Fire("OnClick", "LeftButton")
    check(STATS.sets == sets + 2, "the next click after the gap")
    f.me:Fire("OnClick", "LeftButton")
    check(A.selected == ns.Guild.Me() and UI.state.detail == "ledger", "My character selects you")
    check(STATS.sets == sets + 2, "your own statistics need no request")
end

---------------------------------------------------------------------------
-- Fishing: Log views, title bar switches, Now rows
---------------------------------------------------------------------------
scenarios.misc_fishing_page = function()
    local ns = T.fishingSetup(11509)
    local bound = {}
    ns.Options.Bind = function(key, kind, where) bound[#bound + 1] = key .. ":" .. kind .. ":" .. where end
    local UI = ns.FishingUI
    UI.ShowPage("now")
    local f = TALODFishingWindow
    table.sort(bound)
    check(table.concat(bound, ",") == "fishAutoLoot:quick:fishing,fishHud:quick:fishing,fishLoudSplash:quick:fishing",
        "quick switches bound: " .. table.concat(bound, ","))
    check(f.status:GetText():find("Fishing skill", 1, true), "skill in the title bar")
    check(not f.endSession:IsShown() and UI.PageStatus() == nil, "no session: no End session")
    local now = UI.views.now.list
    for _, label in ipairs({ "Zone level", "Gear", "Lures" }) do
        check(hasRow(ns, now, label), "Now row: " .. label)
    end
    local lures = hasRow(ns, now, "Lures")
    check(lures.copy == "/click TALODFishingLureButton", "Lures row copies the lure macro")
    local hud = TALODDB.fishHud
    f.hudButton:Fire("OnClick", "LeftButton")
    check(TALODDB.fishHud == not hud, "HUD switch")
    f.hudButton:Fire("OnClick", "LeftButton")
    check(TALODDB.fishHud == hud, "HUD switch back")

    -- A session: End session shows, and ends it.
    ns.Prices.Record(6291, 120, 40, time(), 3, "Raw Brilliant Smallfish")
    T.catch({ { 6291, "Raw Brilliant Smallfish", 1 } })
    UI.Refresh()
    check(f.endSession:IsShown() and UI.PageStatus() and UI.PageStatus().text:find("1 caught"), "session running")
    f.endSession:Fire("OnClick", "LeftButton")
    check(ns.Fishing.Session() == nil and not f.endSession:IsShown(), "End session ends it")

    -- Log: Casts and encounters, Sessions; the tab remembers the last view.
    UI.ShowPage("log")
    check(UI.state.view == "log" and f.logViews:IsShown(), "Log opens on Casts and encounters")
    f.logViews.buttons[2]:Fire("OnClick", "LeftButton")
    check(UI.state.view == "sessions" and UI.views.sessions:IsShown() and not UI.views.log:IsShown(), "Sessions view")
    UI.ShowPage("spots")
    f.tabs[4]:Fire("OnClick", "LeftButton")
    check(UI.state.view == "sessions", "the Log tab reopens its last view")
    -- Old words.
    slash("fish sessions")
    check(UI.state.view == "sessions" and f.tabs.selected == "log", "/fish sessions: Log > Sessions")
    slash("fish log")
    check(UI.state.view == "log", "/fish log")
    slash("fish map")
    check(UI.state.view == "map", "/fish map")
    slash("fish goals")
    check(UI.state.view == "goals" and f.tabs.selected == "goals", "/fish goals")
end

---------------------------------------------------------------------------
-- Groups: History chips, a row opens the group, Back
---------------------------------------------------------------------------
scenarios.misc_groups_history = function()
    local now = os.time()
    MOCK.now = now
    local party = { id = 1, c = 1, kind = "party", start = now - 7200, stop = now - 6000, packed = true,
        m = { "sBuddy-Mockrealm" }, names = "Buddy" }
    local raid = { id = 2, c = 1, kind = "raid", start = now - 3600, stop = now - 1800, packed = true, m = {}, names = "" }
    local ns = T.boot(11509, { db = { store = { v = {} }, groups = { n = 2, list = { party, raid } } } })
    local G, UI = ns.Groups, ns.GroupsUI
    UI.ShowPage("now")
    check(UI.PageStatus() == nil, "solo: no page status")
    MOCK.SetGroup({ MOCK.Friend({ name = "Healy", guid = "Player-1-H", class = "PRIEST", level = 25 }) })
    for _ = 1, 3 do MOCK.now = MOCK.now + 1 MOCK.Tick(1) end
    check(UI.PageStatus() and UI.PageStatus().text:find("players"), "in a group: page status")
    UI.ShowPage("history", "All")
    local list = UI.views.history.list
    local all = #list.items
    check(all == #G.Sessions() and all == 3, "All: every group: " .. all)
    UI.ShowPage("history", "Parties")
    for _, it in ipairs(rowsOf(ns, list)) do check(G.ById(it.id).kind == "party", "Parties: parties only") end
    UI.ShowPage("history", "Raids")
    for _, it in ipairs(rowsOf(ns, list)) do check(G.ById(it.id).kind == "raid", "Raids: raids only") end
    -- A row opens the group in full; Back returns.
    local id = list.items[1].id
    list.rows[1]:GetScript("OnClick")(list.rows[1], "LeftButton")
    check(UI.state.view == "session" and UI.state.session == id and TALODGroupsWindow.tabs.selected == "history", "row -> group")
    UI.views.session.modes.buttons[4]:Fire("OnClick", "LeftButton")
    check(UI.state.mode == "timeline", "timeline of that group")
    UI.views.session.back:Fire("OnClick", "LeftButton")
    check(UI.state.view == "history" and UI.state.chip == "raid", "Back: the list as it was")
    -- Old words.
    slash("groups parties")
    check(UI.state.view == "history" and UI.state.chip == "party", "/groups parties")
    slash("groups raid")
    check(UI.state.chip == "raid", "/groups raid")
    slash("groups now")
    check(UI.state.view == "now", "/groups now")
end

---------------------------------------------------------------------------
-- About: every command, the macro lines with Copy, Credits, What's new
---------------------------------------------------------------------------
scenarios.misc_about_page = function()
    local ns = T.boot(11509)
    local About = ns.AboutUI
    About.ShowPage("commands")
    local list = About.views.commands.list
    local copies = {}
    for _, it in ipairs(list.items) do if it.copy then copies[it.copy] = it end end
    for _, r in ipairs(ns.Cmd.List()) do
        check(copies[r.canonical], "listed: " .. r.canonical)
    end
    for _, m in ipairs(About.MacroLines()) do
        check(copies[m[1]] and copies[m[1]].macro, "macro line: " .. m[1])
    end
    check(copies["/click " .. ns.FRAME .. "FishingSwapButton"], "swap button macro")
    local headers = 0
    for _, it in ipairs(list.items) do if it.header then headers = headers + 1 end end
    check(headers >= 10, "grouped by page: " .. headers)
    -- Copy: the row's button opens the copy box with the line.
    local item = copies["/click " .. ns.FRAME .. "FishingLureButton"]
    MOCK.popup, MOCK.popupData = nil, nil
    About.RowButton(item).onClick(item, "LeftButton")
    check(MOCK.popup == "TALOD_COPY" and MOCK.popupData == "/click TALODFishingLureButton", "copy box")
    -- Search narrows the list.
    list.searchBox:SetText("lure")
    list.searchBox:GetScript("OnTextChanged")(list.searchBox)
    check(#list.items < #About.CommandRows() and hasRow(ns, list, "FishingLureButton"), "search")

    -- Credits and What's new; old words land there.
    slash("credits")
    check(About.IsShown("credits"), "/credits: About > Credits")
    slash("discord")
    check(not About.IsShown(), "/discord toggles it closed")
    slash("donate")
    check(About.IsShown("credits"), "/donate")
    local list2 = ns.CHANGELOGS
    slash("changelog " .. list2[2].v)
    check(About.IsShown("changelog") and ns.Changelog.Selected() == list2[2], "/changelog <version>")
    About.ShowPage("changelog", nil, list2[1].v)
    check(ns.Changelog.Selected() == list2[1], "ShowPage selects a version")
    -- Check for updates = /talod version.
    TALODChangelogWindow.check:Fire("OnClick", "LeftButton")
    check(TALODUpdateNotice and TALODUpdateNotice:IsShown(), "Check for updates shows the version notice")
end

---------------------------------------------------------------------------
-- Old audit words still do what they did
---------------------------------------------------------------------------
scenarios.misc_audit_words = function()
    local ns = auditSetup()
    local UI = ns.AuditUI
    slash("audit flags")
    check(UI.IsShown() and UI.state.scope == "flagged", "/audit flags")
    slash("audit members")
    check(UI.state.scope == "guild", "/audit members")
    slash("audit characters")
    check(UI.state.scope == "everyone", "/audit characters")
    slash("audit history")
    check(UI.state.detail == "history", "/audit history")
    slash("audit ledger")
    check(UI.state.detail == "ledger", "/audit ledger")
    slash("audit flagged")
    check(UI.state.scope == "flagged", "/audit flagged")
    slash("audit guild")
    check(UI.state.scope == "guild", "/audit guild")
    slash("audit everyone")
    check(UI.state.scope == "everyone", "/audit everyone")
    MOCK.prints = {}
    slash("audit status")
    check(T.printed("statistic IDs checked"), "/audit status")
    slash("audit")
    check(not UI.IsShown(), "/audit toggles closed")
end
