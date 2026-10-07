-- Fishing goals (FishingGoals.lua, FishingData.lua): zone fishing levels,
-- fish of the server's hours and seasons, the goals checklist, the
-- Stranglethorn Fishing Extravaganza clock, and the data's sanity.
local scenarios, T = ...
local check = T.check

-- The server's clock in the mock: GetGameTime, and the realm calendar when given.
local function serverClock(hour, minute, calendar)
    GetGameTime = function() return hour, minute end
    if calendar then
        C_DateAndTime = C_DateAndTime or {}
        C_DateAndTime.GetCurrentCalendarTime = function()
            return { hour = hour, minute = minute, weekday = calendar.weekday, month = calendar.month, monthDay = calendar.day }
        end
    elseif C_DateAndTime then
        C_DateAndTime.GetCurrentCalendarTime = nil
    end
end

local function hudRow(label)
    local hud = TALODFishingHUD
    for _, r in ipairs(hud and hud.rows or {}) do
        if r:IsShown() and (r.label:GetText() or ""):find(label, 1, true) then return r end
    end
    return nil
end

local function listHas(list, pattern)
    for _, item in ipairs(list.all or {}) do
        if (item.text or ""):find(pattern, 1, true) or (item.label or ""):find(pattern, 1, true) then return item end
    end
    return nil
end

scenarios.fishing_goals_zone_lookup = function()
    local ns = T.fishingSetup(11509)
    local G = ns.FishingGoals
    local elwynn = G.ZoneLevel(1429, "Crystal Lake", "Elwynn Forest")
    check(elwynn and elwynn.name == "Elwynn Forest" and elwynn.base == -70 and elwynn.full == 25 and elwynn.min == 1, "Elwynn by map ID")
    local stv = G.ZoneLevel(nil, "Booty Bay", "Stranglethorn Vale")
    check(stv and stv.base == 130 and stv.full == 225, "Stranglethorn by zone name")
    local jaguero = G.ZoneLevel(1434, "Jaguero Isle", "Stranglethorn Vale")
    check(jaguero and jaguero.base == 205 and jaguero.parent == "Stranglethorn Vale", "a subzone's own level wins over its zone")
    local dungeon = G.ZoneLevel(nil, "", "The Deadmines")
    check(dungeon and dungeon.full == 75, "dungeon by name")
    check(G.ZoneLevel(99999, "Nowhere", "Nowhere") == nil, "unknown water: nil")
    check(G.Chance(100, stv) == 0 and G.Chance(130, stv) == 5 and G.Chance(200, stv) == 75 and G.Chance(260, stv) == 100,
        "hook chance: skill - base + 5, none below the base")
    check(G.Chance(nil, stv) == nil and G.Chance(100, nil) == nil, "unknown skill or zone: nil chance")
    T.slash("fish zone")
    check(T.printed("Crystal Lake: needs ~25 %(you 100%)"), "/talod fish zone")
end

scenarios.fishing_goals_hud = function()
    local ns = T.fishingSetup(11509)
    local F = ns.Fishing
    MOCK.Tick(1.1)
    local row = hudRow("Zone")
    check(row and row.value:GetText():find("needs ~25 %(you 100%)") and not row.accent:IsShown(), "Elwynn: above the level, no warning")
    check(row.value:GetText():find("none get away"), "none get away above the level")
    -- Stranglethorn: below the base, every fish gets away.
    MOCK.mapID, MOCK.zone, MOCK.subzone = 1434, "Stranglethorn Vale", "Nek'mani Wellspring"
    MOCK.Tick(1.1)
    row = hudRow("Zone")
    check(row and row.value:GetText():find("needs ~225 %(you 100%)") and row.value:GetText():find("all get away") and row.accent:IsShown(),
        "below the base: warned, all get away")
    -- Lure and skill between the base and the level: some get away.
    local effective = F.Effective
    F.Effective = function() return 200 end
    MOCK.Tick(1.1)
    row = hudRow("Zone")
    check(row.value:GetText():find("~75%% hooked") and row.accent:IsShown(), "between: warned with the hook chance")
    F.Effective = function() return 230 end
    MOCK.Tick(1.1)
    check(not hudRow("Zone").accent:IsShown(), "at or above the level: no warning")
    -- Unknown skill: "?", never "none get away".
    F.Effective = function() return nil end
    MOCK.Tick(1.1)
    row = hudRow("Zone")
    check(row.value:GetText():find("you %?%)") and not row.value:GetText():find("none get away"), "unknown skill: ?")
    F.Effective = effective
    -- Unknown water: "?".
    MOCK.mapID, MOCK.zone, MOCK.subzone = 1419, "Blasted Lands", "Dreadmaul Hold"
    MOCK.Tick(1.1)
    check(hudRow("Zone").value:GetText():find("%? %(no data"), "no data: ?")
    -- Turned off on the settings page.
    TALODDB.fishZoneHud = false
    MOCK.Tick(1.1)
    check(hudRow("Zone") == nil, "zone line off")
end

scenarios.fishing_goals_time_of_day = function()
    local ns = T.fishingSetup(11509)
    local G = ns.FishingGoals
    local nightfin = G.timedById[13759]
    -- Server 14:05 whatever the computer's clock says.
    serverClock(14, 5)
    local clock = G.ServerClock()
    check(clock and clock.hour == 14 and clock.min == 5 and clock.how == "game", "server hour from GetGameTime")
    local text, open = G.TimedText(nightfin, clock)
    check(open == false and text:find("night only %(server 18%-06%), now: ") and text:find("day"), "Nightfin at 14:05: " .. text)
    serverClock(23, 30)
    text, open = G.TimedText(nightfin, G.ServerClock())
    check(open == true and text:find("night"), "Nightfin at 23:30")
    local sunscale = G.timedById[13760]
    check(G.TimedStatus(sunscale, { hour = 3, min = 0, wday = 1, month = 1, day = 1 }) == false, "Sunscale none 00-06")
    check(G.TimedStatus(sunscale, { hour = 13, min = 0, wday = 1, month = 1, day = 1 }) == true, "Sunscale at 13")
    -- The realm calendar wins: date and season from it.
    serverClock(2, 0, { weekday = 1, month = 1, day = 10 })
    clock = G.ServerClock()
    check(clock.how == "calendar" and clock.month == 1 and clock.day == 10 and clock.wday == 1, "realm calendar")
    local open2, best = G.TimedStatus(nightfin, clock)
    check(open2 == true and best == true, "Nightfin best hours 00-06")
    check(G.TimedStatus(G.timedById[13755], clock) == true and G.TimedStatus(G.timedById[13756], clock) == false, "January: Winter Squid, no Summer Bass")
    serverClock(12, 0, { weekday = 4, month = 7, day = 1 })
    clock = G.ServerClock()
    check(G.TimedStatus(G.timedById[13755], clock) == false and G.TimedStatus(G.timedById[13756], clock) == true, "July: Summer Bass")
    check(G.TimedStatus(G.timedById[13755], { hour = 12, min = 0, wday = 1, month = 9, day = 23 }) == true, "Winter Squid from Sep 23")
    -- No clock: unknown, never "open" or "closed".
    serverClock(nil, nil)
    C_DateAndTime.GetCurrentCalendarTime = nil
    check(G.ServerClock() == nil, "no server time: nil")
    text, open = G.TimedText(nightfin, nil)
    check(open == nil and text:find("now: .*%?"), "no clock: ?")
    -- Spot rows: the fish of this water with the hour, on Winterspring.
    serverClock(14, 5)
    MOCK.mapID, MOCK.zone, MOCK.subzone = 1452, "Winterspring", "Frostwhisper Gorge"
    T.catch({ { 13760, "Raw Sunscale Salmon", 1 } })
    ns.FishingUI.Show("spots")
    local view = ns.FishingUI.views.spots
    ns.FishingUI.state.selected = { 1452, "Frostwhisper Gorge" }
    ns.FishingUI.Refresh()
    check(listHas(view.detail, "needs ~425 (you 100)"), "spot rows: zone level")
    check(listHas(view.detail, "Raw Nightfin Snapper: night only (server 18-06), now: "), "spot rows: Nightfin with the hour")
    check(listHas(view.detail, "Your log"), "spot rows: your own catch rate as a supplement")
    ns.FishingUI.Show("now")
    check(listHas(ns.FishingUI.views.now.list, "needs ~425"), "Now row: zone level")
end

scenarios.fishing_goals_secret_clock = function()
    local ns = T.fishingSetup(16001, { secrets = true })
    local G = ns.FishingGoals
    GetGameTime = function() return MOCK.Secret(14), MOCK.Secret(5) end
    check(G.ServerClock() == nil, "a secret hour is unknown")
    C_DateAndTime = C_DateAndTime or {}
    C_DateAndTime.GetCurrentCalendarTime = function() return { hour = MOCK.Secret(1), minute = 0, weekday = 1, month = 1, monthDay = 1 } end
    check(G.ServerClock() == nil, "a secret calendar field is unknown")
    check(G.Extravaganza() == nil and G.ExtravaganzaText(nil):find("%?"), "Extravaganza: ?")
    MOCK.Tick(1.1)
    ns.FishingUI.Show("goals")
end

scenarios.fishing_goals_checklist = function()
    local ns = T.fishingSetup(11509)
    local G = ns.FishingGoals
    serverClock(10, 0)
    T.resetOutput()
    T.catch({ { 16967, "Feralas Ahi", 1 } })
    T.catch({ { 16967, "Feralas Ahi", 1 } })
    T.catch({ { 6291, "Raw Brilliant Smallfish", 1 } })
    local caught = G.Caught()
    check(caught[16967] and caught[16967].n == 2 and caught[16967].places[1].spot == "Crystal Lake"
        and caught[16967].places[1].bands[100] == 2, "goal caught twice, where and at which band")
    check(caught[6291] == nil, "not a goal: not listed")
    check(caught[16970] == nil, "not caught: nothing")
    local first = G.Store().first[16967]
    check(first and first.sub == "Crystal Lake" and first.skill == 100, "first catch recorded")
    check(T.printed("your first Feralas Ahi"), "first catch announced once")
    local announced = 0
    for _, line in ipairs(MOCK.prints) do if line:find("your first Feralas Ahi") then announced = announced + 1 end end
    check(announced == 1, "announced once: " .. announced)
    check(TALODDB.fishing.goals and TALODDB.fishing.goals.first[16967], "saved under fishing.goals")
    -- A catch with no map position comes from the cast log.
    MOCK.mapID = nil
    T.catch({ { 16970, "Misty Reed Mahi Mahi", 1 } })
    MOCK.mapID = 1429
    caught = G.Caught()
    check(caught[16970] and caught[16970].n == 1 and caught[16970].unplaced == 1, "catch without a map: from the cast log")
    -- The view: /talod fish goals opens it.
    T.slash("fish goals")
    check(ns.FishingUI.state.view == "goals" and TALODFishingWindow:IsShown(), "/talod fish goals opens the view")
    local view = ns.FishingUI.views.goals
    local row = listHas(view.list, "Feralas Ahi")
    check(row and row.text:find("[x]", 1, true) and row.cols[2]:find("x2"), "checklist: Feralas Ahi caught x2")
    local open = listHas(view.list, "Savage Coast Blue Sailfin")
    check(open and open.text:find("[  ]", 1, true), "checklist: Sailfin not yet")
    check(view.left.sub:GetText():find("2 of 20 caught"), "checklist count: " .. tostring(view.left.sub:GetText()))
    -- Detail of a goal: caught, where to look with the zone level, the quest.
    local clicked = false
    for _, r in ipairs(view.list.rows) do
        if r.item and r.item.goal == 16967 then r:Fire("OnClick", "LeftButton") clicked = true break end
    end
    check(clicked, "goal row clickable")
    check(view.right.title:GetText() == "Feralas Ahi", "detail of the clicked goal")
    check(listHas(view.detail, "Verdantis River"), "where to look")
    check(listHas(view.detail, "no get-aways from 300"), "where to look: zone level of Feralas")
    check(listHas(view.detail, "Nat Pagle, Angler Extreme"), "the quest")
    check(listHas(view.detail, "2x  Crystal Lake"), "where you caught it, with the band")
end

scenarios.fishing_goals_extravaganza = function()
    local ns = T.fishingSetup(11509)
    local G = ns.FishingGoals
    local st = G.Extravaganza({ wday = 1, hour = 14, min = 30 })
    check(st.on and st.left == 90, "Sunday 14:30: on, 90 min left")
    st = G.Extravaganza({ wday = 1, hour = 13, min = 15 })
    check(not st.on and st.untilStart == 45, "Sunday 13:15: in 45 min")
    st = G.Extravaganza({ wday = 1, hour = 16, min = 0 })
    check(not st.on and st.untilStart == 7 * 1440 - 120, "Sunday 16:00: over, next week")
    st = G.Extravaganza({ wday = 7, hour = 23, min = 0 })
    check(not st.on and st.untilStart == 15 * 60, "Saturday 23:00: in 15 h")
    check(G.ExtravaganzaText(st):find("starts in 15 h 00 min"), "text: " .. G.ExtravaganzaText(st))
    -- HUD: shown in the hour before and while it runs, not otherwise.
    serverClock(13, 30, { weekday = 1, month = 6, day = 7 })
    MOCK.Tick(1.1)
    local row = hudRow("Contest")
    check(row and row.value:GetText():find("starts in 30 min"), "HUD: 30 min before")
    serverClock(15, 0, { weekday = 1, month = 6, day = 7 })
    MOCK.Tick(1.1)
    row = hudRow("Contest")
    check(row and row.value:GetText():find("on now") and row.accent:IsShown(), "HUD: on now")
    serverClock(15, 0, { weekday = 4, month = 6, day = 10 })
    MOCK.Tick(1.1)
    check(hudRow("Contest") == nil, "HUD: not on a Wednesday")
    -- Chat reminder: off by default, once per event when on.
    serverClock(13, 30, { weekday = 1, month = 6, day = 7 })
    T.resetOutput()
    MOCK.Tick(31)
    check(not T.printed("Extravaganza"), "no chat reminder by default")
    TALODDB.fishExtravaganzaChat = true
    MOCK.Tick(31) MOCK.Tick(31)
    local n = 0
    for _, line in ipairs(MOCK.prints) do if line:find("Extravaganza starts in") then n = n + 1 end end
    check(n == 1, "one chat reminder per event: " .. n)
    serverClock(14, 10, { weekday = 1, month = 6, day = 7 })
    MOCK.Tick(31)
    check(not T.printed("Extravaganza is on"), "same event: no second reminder")
    -- Goals view shows the clock and the next start.
    ns.FishingUI.Show("goals")
    local view = ns.FishingUI.views.goals
    check(listHas(view.detail, "on now"), "goals view: on now")
    check(view.right.sub:GetText():find("Sunday 14:10"), "goals view: server clock")
    -- Settings page builds.
    TALODDB.fishExtravaganza = false
    MOCK.Tick(1.1)
    check(hudRow("Contest") == nil, "turned off")
end

scenarios.fishing_goals_settings = function()
    local ns = T.fishingSetup(11509)
    local page
    for _, p in ipairs(ns.Fishing.settingsTab.pages) do if p.label == "Goals" then page = p end end
    check(page, "Goals page in the Fishing tab")
    local parent = CreateFrame("Frame", nil, UIParent)
    local height = page.build(parent)
    check(type(height) == "number" and height > 100, "page height")
    check(TALODDB.fishZoneHud == true and TALODDB.fishExtravaganza == true and TALODDB.fishExtravaganzaChat == false,
        "defaults")
end

scenarios.fishing_goals_data = function()
    local ns = T.fishingSetup(11509)
    local D = ns.FishingData
    local bad = {}
    local function Bad(msg) bad[#bad + 1] = msg end
    local names = {}
    for id, a in pairs(D.areas) do
        if type(id) ~= "number" or id <= 0 then Bad("area id " .. tostring(id)) end
        if type(a[1]) ~= "string" or a[1] == "" then Bad("area name " .. tostring(id)) end
        if names[a[1]] then Bad("duplicate area name " .. a[1]) end
        names[a[1]] = true
        if a[2] ~= nil and type(a[2]) ~= "string" then Bad("parent " .. tostring(id)) end
        if type(a[3]) ~= "number" or a[3] < -100 or a[3] > 400 or a[3] % 1 ~= 0 then Bad("base " .. tostring(id)) end
    end
    local maps = 0
    for m, a in pairs(D.uiMapArea) do
        maps = maps + 1
        if type(m) ~= "number" or not D.areas[a] then Bad("uiMap " .. tostring(m)) end
    end
    if maps < 30 then Bad("too few UiMaps: " .. maps) end
    local seen = {}
    local groups = { pagle = 0, stv = 0, rare = 0 }
    for _, g in ipairs(D.goals) do
        if type(g.id) ~= "number" or g.id <= 0 or g.id % 1 ~= 0 then Bad("goal id " .. tostring(g.id)) end
        if seen[g.id] then Bad("duplicate goal " .. g.id) end
        seen[g.id] = true
        if groups[g.group] == nil then Bad("group " .. tostring(g.group)) else groups[g.group] = groups[g.group] + 1 end
        if type(g.name) ~= "string" or g.name == "" then Bad("goal name " .. g.id) end
        if not g.where and not g.whereNote then Bad("no place for " .. g.name) end
        for _, p in ipairs(g.where or {}) do
            if type(p[1]) ~= "string" or (p[2] ~= nil and type(p[2]) ~= "string") then Bad("where of " .. g.name) end
        end
        for _, q in ipairs(g.quests or {}) do
            if type(q.id) ~= "number" or type(q.count) ~= "number" or q.count < 1 or type(q.title) ~= "string" then Bad("quest of " .. g.name) end
        end
    end
    if groups.pagle ~= 4 then Bad("Nat Pagle's fish: " .. groups.pagle) end
    for _, t in ipairs(D.timed) do
        if not seen[t.id] then Bad("timed fish not a goal: " .. tostring(t.id)) end
        if not (t.hours or t.season) then Bad("timed fish without hours or season: " .. t.id) end
        for _, w in ipairs({ t.hours, t.best }) do
            if w and not (w[1] >= 0 and w[1] <= 24 and w[2] >= 0 and w[2] <= 24 and w[1] ~= w[2]) then Bad("hours of " .. t.id) end
        end
        if t.season then
            for _, md in ipairs(t.season) do
                local m, d = math.floor(md / 100), md % 100
                if m < 1 or m > 12 or d < 1 or d > 31 then Bad("season of " .. t.id) end
            end
        end
        if type(t.source) ~= "string" or t.source == "" then Bad("no source for " .. t.id) end
        if type(t.label) ~= "string" or type(t.open) ~= "string" or type(t.closed) ~= "string" then Bad("labels of " .. t.id) end
    end
    local e = D.extravaganza
    if not (e and e.weekday >= 1 and e.weekday <= 7 and e.start >= 0 and e.start < 1440 and e.length > 0 and e.length < 1440) then Bad("extravaganza") end
    if not (type(e.source) == "string" and e.source:find("^https://")) then Bad("extravaganza source") end
    check(#bad == 0, "fishing data problems: " .. table.concat(bad, "; "))
end
