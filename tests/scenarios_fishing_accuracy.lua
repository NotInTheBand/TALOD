-- Fishing accuracy: escaped vs missed (UI_ERROR_MESSAGE), the real channel
-- length (UnitChannelInfo), server time, which lure, cast tags, old saved
-- data and the skill-ups sort. Run by tests/run.py (see scenarios.lua).
local scenarios, T = ...
local check = T.check

local function castWith(seconds, message, ...)
    T.castStart() MOCK.Tick(seconds)
    if message then MOCK.FireEvent("UI_ERROR_MESSAGE", message, ...) end
    T.castStop() MOCK.Tick(2)
end

local function lastCast(F) return F.RecentCasts(1)[1] end

-- "Your fish got away!" is an escape (counts against the spot), "No fish are
-- hooked." and an early stop without any message are misses (do not).
scenarios.fishing_escaped_vs_missed = function()
    local ns = T.fishingSetup(11509)
    local F = ns.Fishing
    T.catch({ { 6291, "Raw Brilliant Smallfish", 1 } })
    -- Modern engine: (errorType, message), sent before the channel stops.
    T.castStart() MOCK.Tick(6) MOCK.FireEvent("UI_ERROR_MESSAGE", 412, "Your fish got away!") T.castStop() MOCK.Tick(2)
    check(lastCast(F).result == "a", "escape: " .. tostring(lastCast(F).result))
    -- Old clients: (message) only; and a message after the stop still counts.
    T.castStart() MOCK.Tick(3) T.castStop() MOCK.Tick(0.3) MOCK.FireEvent("UI_ERROR_MESSAGE", "No fish are hooked.") MOCK.Tick(2)
    check(lastCast(F).result == "m", "nothing hooked: " .. tostring(lastCast(F).result))
    -- Early stop, no message: missed, not "got away".
    castWith(4)
    check(lastCast(F).result == "m", "early stop without a message: " .. tostring(lastCast(F).result))
    -- Other red errors say nothing.
    castWith(4, 50, "You are moving.")
    check(lastCast(F).result == "m", "unrelated error ignored")
    -- No cast running: ignored, no error.
    MOCK.FireEvent("UI_ERROR_MESSAGE", 412, "Your fish got away!")
    local s = F.Session()
    check(s.n == 5 and s.c == 1 and s.a == 1 and s.m == 3, string.format("session n=%d c=%d a=%d m=%d", s.n, s.c, s.a, s.m))
    local r = F.Rates(s)
    check(math.abs(r.catchPct - 0.5) < 0.001 and r.escaped == 1 and r.missed == 3, "catch rate c / (c + a): " .. tostring(r.catchPct))
    local spot = F.GetSpot(1429, "Crystal Lake")
    check(spot.b[100].m == 3 and F.Store().cells[1429]["21:32"].m == 3, "missed in the spot band and square")
    -- The views show both.
    ns.FishingUI.Show("now")
    local found = false
    for _, row in ipairs(ns.FishingUI.views.now.list.items) do
        if row.text and row.text:find("1 got away") and row.text:find("3 missed") then found = true end
    end
    check(found, "Now: got away and missed")
    found = false
    for _, row in ipairs(ns.FishingUI.views.now.detail.items) do
        if row.text and row.text:find("got away: 1, missed: 3") then found = true row.tooltip(TALODFishingWindow) end
    end
    check(found, "Here: got away and missed")
    ns.FishingUI.Show("log")
    check(ns.FishingUI.views.log.list.items[1].text:find("missed"), "log: missed")
    ns.FishingUI.Show("sessions")
    F.CloseSession()
    check(F.Store().sessions[1].m == 3, "session keeps the misses")
end

-- The game's own strings (another language) are used when it has them.
scenarios.fishing_escaped_localized = function()
    ERR_FISH_ESCAPED, ERR_FISH_NOT_HOOKED = "Dein Fisch ist entkommen!", "Es ist kein Fisch am Haken."
    local ns = T.fishingSetup(11509)
    local F = ns.Fishing
    castWith(5, 0, "Dein Fisch ist entkommen!")
    check(lastCast(F).result == "a", "localized escape")
    castWith(5, 0, "Your fish got away!")
    check(lastCast(F).result == "m", "English text not the game's here: missed")
end

-- Forever: a hidden message is unknown, so the cast is a miss (never an escape).
scenarios.fishing_escaped_secret = function()
    local ns = T.fishingSetup(16001, { secrets = true })
    local F = ns.Fishing
    castWith(5, MOCK.Secret(412), MOCK.Secret("Your fish got away!"))
    check(lastCast(F).result == "m", "secret message: " .. tostring(lastCast(F).result))
    castWith(5, MOCK.Secret(412), "Your fish got away!")
    check(lastCast(F).result == "a", "readable message next to a hidden type")
    -- A hidden lure is unknown ("?"), never "none".
    GetWeaponEnchantInfo = function() return MOCK.Secret(true), 0, 0, MOCK.Secret(263) end
    T.catch({ { 6291, "Raw Brilliant Smallfish", 1 } })
    check(F.GetSpot(1429, "Crystal Lake").l["?"].n == 1 and lastCast(F).lureID == nil, "hidden lure: ?")
end

-- Channel length from UnitChannelInfo; 30 s when it gives nothing readable.
scenarios.fishing_channel_length = function()
    local ns = T.fishingSetup(11509)
    local F = ns.Fishing
    local length = 20
    UnitChannelInfo = function(unit)
        if unit ~= "player" then return nil end
        return "Fishing", "", 136245, MOCK.time * 1000, (MOCK.time + length) * 1000, false, false, 7620
    end
    T.castStart() MOCK.Tick(10)
    local elapsed, duration = F.CastElapsed()
    check(elapsed == 10 and duration == 20, "elapsed / duration: " .. tostring(elapsed) .. " " .. tostring(duration))
    check(math.abs(TALODFishingHUD.cast._width - (344 - 2) * 0.5) < 0.01, "HUD bar over the real length: " .. TALODFishingHUD.cast._width)
    MOCK.Tick(8.5) T.castStop() MOCK.Tick(2)
    check(lastCast(F).result == "t" and lastCast(F).channel == 20, "ran out near its real end: " .. tostring(lastCast(F).result))
    castWith(15)
    check(lastCast(F).result == "m", "stopped 5 s early: missed")
    -- No stop event: closed after its end, as run out.
    T.castStart() MOCK.Tick(31.5) MOCK.Tick(0.2)
    check(F.CastElapsed() == nil and lastCast(F).result == "t", "no stop event: closed as timed out")
    -- Unreadable: 30 s assumed, the log field empty.
    UnitChannelInfo = function() return MOCK.Secret("Fishing"), nil, nil, MOCK.Secret(1), MOCK.Secret(2) end
    T.castStart() MOCK.Tick(1)
    check(select(2, F.CastElapsed()) == 30, "fallback 30 s")
    MOCK.Tick(28.5) T.castStop() MOCK.Tick(2)
    check(lastCast(F).result == "t" and lastCast(F).channel == nil, "30 s fallback timed out")
    castWith(25)
    check(lastCast(F).result == "m", "25 of 30 s: missed")
    UnitChannelInfo = function() return "Fishing", "", 1, 1000, 999000 end    -- nonsense length
    T.castStart() MOCK.Tick(1)
    check(select(2, F.CastElapsed()) == 30, "implausible length ignored")
    T.castStop() MOCK.Tick(2)
    -- Started from UNIT_SPELLCAST_SUCCEEDED: the length is read when the channel starts.
    UnitChannelInfo = function() return nil end
    MOCK.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 7620)
    length = 22
    UnitChannelInfo = function() return "Fishing", "", 1, MOCK.time * 1000, (MOCK.time + length) * 1000 end
    MOCK.Tick(0.3) T.castStart()
    check(select(2, F.CastElapsed()) == 22, "length read at channel start: " .. tostring(select(2, F.CastElapsed())))
    T.castStop() MOCK.Tick(2)
end

-- Server time (GetGameTime) in every record; nothing when unreadable.
scenarios.fishing_server_time = function()
    local ns = T.fishingSetup(11509)
    local F = ns.Fishing
    GetGameTime = function() return 21, 5 end
    T.catch({ { 6291, "Raw Brilliant Smallfish", 1 } })
    local e = lastCast(F)
    check(e.serverMin == 21 * 60 + 5 and e.serverHour == 21, "server time: " .. tostring(e.serverMin))
    check(select(13, strsplit(",", F.Store().casts[1])) == "1265", "field 13: " .. F.Store().casts[1])
    GetGameTime = function() return MOCK.Secret(3), MOCK.Secret(0) end
    castWith(4)
    check(lastCast(F).serverMin == nil and lastCast(F).serverHour == nil, "hidden: empty")
    GetGameTime = nil
    castWith(4)
    check(lastCast(F).serverMin == nil, "missing function: empty")
    ns.FishingUI.Show("log")
    ns.FishingUI.views.log.list.items[3].tooltip(TALODFishingWindow)
end

-- The lure's enchant ID per cast and a tally per lure (spot and overall).
scenarios.fishing_lure_id = function()
    local ns = T.fishingSetup(11509)
    local F = ns.Fishing
    MOCK.lureMs = 600000                -- the mock's enchant 263 (+25)
    MOCK.skillLines[2][6] = 25
    MOCK.FireEvent("SKILL_LINES_CHANGED") MOCK.Tick(0.6)
    check(select(2, F.Skill()) == 25, "skill modifier read: " .. tostring(select(2, F.Skill())))
    local on, left, id = F.Lure()
    check(on == true and id == 263 and left == 600, "lure and its ID")
    T.catch({ { 6291, "Raw Brilliant Smallfish", 1 } })
    castWith(5, 0, "Your fish got away!")
    local e = lastCast(F)
    check(e.lureID == 263 and e.lure == true, "lure ID in the log")
    local f = F.Store()
    local spot = F.GetSpot(1429, "Crystal Lake")
    check(spot.l[263] and spot.l[263].n == 2 and spot.l[263].c == 1 and spot.l[263].a == 1 and spot.l[263].ms == 50 and spot.l[263].mn == 2,
        "per-lure tally at the spot")
    check(f.lures[263] and f.lures[263].n == 2, "per-lure tally overall")
    check(F.LureLabel(263) == "+25 lure" and F.LureLabel(9999) == "Lure #9999" and F.LureLabel("none") == "No lure", "labels")
    -- No lure.
    MOCK.lureMs = nil
    MOCK.skillLines[2][6] = 0
    MOCK.FireEvent("SKILL_LINES_CHANGED") MOCK.Tick(0.6)
    T.catch({ { 6291, "Raw Brilliant Smallfish", 1 } })
    check(spot.l.none and spot.l.none.n == 1 and lastCast(F).lureID == nil and lastCast(F).lure == false, "no lure")
    -- A client without the enchant ID: "on".
    local orig = GetWeaponEnchantInfo
    GetWeaponEnchantInfo = function() return true, 60000 end
    T.catch({ { 6291, "Raw Brilliant Smallfish", 1 } })
    check(spot.l.on and spot.l.on.n == 1 and lastCast(F).lure == true and lastCast(F).lureID == nil, "lure without an ID")
    GetWeaponEnchantInfo = orig
    -- Shown with the spot (Now and Spots).
    ns.FishingUI.Show("now")
    local header, lureRow = false, false
    for _, row in ipairs(ns.FishingUI.views.now.detail.items) do
        if row.header and row.text:find("By lure") then header = true end
        if row.label == "+25 lure" and row.text:find("50%%") and row.text:find("skill %+25") then lureRow = true row.tooltip(TALODFishingWindow) end
    end
    check(header and lureRow, "By lure rows")
    ns.FishingUI.Show("spots")
end

-- cast.tags from other modules round-trip through the log; old records parse.
scenarios.fishing_cast_tags = function()
    local ns = T.fishingSetup(11509)
    local F = ns.Fishing
    F.On("start", function(c) c.tags.pool = true c.tags.x = 3 c.tags["bad,key"] = "a;b=c" c.tags.off = false end)
    T.catch({ { 6291, "Raw Brilliant Smallfish", 1 } })
    local f = F.Store()
    check(f.casts[1]:find(",badkey=abc;pool;x=3,1$"), "tags field, then the character: " .. f.casts[1])
    local e = lastCast(F)
    check(e.tags.pool == true and e.tags.x == 3 and e.tags.badkey == "abc" and e.tags.off == nil, "tags parsed")
    check(e.result == "c" and e.items[6291] == 1 and e.sub == "Crystal Lake", "earlier fields intact")
    -- A record from before the new fields (11 of them).
    f.casts[#f.casts + 1] = "1700000000,1429,420,650,a,100,0,1,20,,Old Pond"
    e = lastCast(F)
    check(e.result == "a" and e.lure == true and e.sub == "Old Pond" and e.skill == 100 and e.lureID == nil and e.serverMin == nil
        and e.channel == nil and next(e.tags) == nil and e.x == 0.42, "old record parsed")
    f.casts[#f.casts + 1] = "1700000001,,,,c,,,0,,6291:2,Somewhere"
    e = lastCast(F)
    check(e.mapID == nil and e.x == nil and e.items[6291] == 2, "old record with empty fields")
    check(F.ParseCast(nil) == nil, "not a string")
    ns.FishingUI.Show("log")
    for i = 1, 3 do ns.FishingUI.views.log.list.items[i].tooltip(TALODFishingWindow) end
    check(ns.FishingUI.views.log.list.items[3].text:find("Raw Brilliant Smallfish"), "log rows")
end

-- Saved data from before "m" and spot lure tallies: everything still works.
scenarios.fishing_old_data = function()
    local old = { n = 12, c = 6, a = 4, t = 2, i = 0, s = 600, it = { [6291] = 6 } }
    local ns = T.fishingSetup(11509, { db = { fishing = {
        version = 1,
        casts = { "1700000000,1429,420,650,a,100,0,1,20,,Crystal Lake" },
        spots = { [1429] = { ["Crystal Lake"] = { b = { [100] = old }, s = 600, x = 0, p = 0, u = 0, e = 0, d = 0, h = {}, px = 0.42, py = 0.65, pn = 1 } } },
        cells = { [1429] = { ["21:32"] = { n = 12, c = 6, a = 4, t = 2, i = 0, s = 600, it = { [6291] = 6 } } } },
        sessions = { { n = 12, c = 6, a = 4, t = 2, i = 0, s = 600, it = {}, start = 1700000000, last = 1700000600, char = "x", zone = "Elwynn Forest" } },
        maps = { [1429] = "Elwynn Forest" },
    } } })
    local F = ns.Fishing
    local spot = F.GetSpot(1429, "Crystal Lake")
    local r = F.Rates((F.SpotTally(spot, 100)))
    check(math.abs(r.catchPct - 0.6) < 0.001 and r.missed == 0, "old tally rates")
    local merged = F.SpotTally(spot, nil)
    check(merged.m == 0 and merged.c == 6, "merged old tally")
    for _, view in ipairs({ "now", "spots", "map", "log", "sessions" }) do ns.FishingUI.Show(view) end
    T.catch({ { 6291, "Raw Brilliant Smallfish", 1 } })
    check(spot.l and spot.b[100].n == 13 and spot.b[100].c == 7, "old spot takes new casts")
    ns.FishingUI.Show("spots")
end

-- Spots sorted by skill-ups per hour: most catches per hour fished at your skill.
scenarios.fishing_skillups_sort = function()
    local ns = T.fishingSetup(11509)
    local F = ns.Fishing
    ns.Prices.Record(6291, 500, 40, time(), 3, "Raw Brilliant Smallfish")
    local f = F.Store()
    local function spot(c, a, item)
        return { b = { [100] = { n = c + a, c = c, a = a, m = 5, t = 0, i = 0, s = 3600, it = { [item] = c } } },
            s = 3600, x = 0, p = 0, u = 0, e = 0, d = 0, h = {}, px = 0, py = 0, pn = 0, l = {} }
    end
    f.spots[1429] = { ["Pricey Pond"] = spot(60, 40, 6291), ["Busy Brook"] = spot(90, 10, 6303) }
    f.maps[1429] = "Elwynn Forest"
    f.ranks[99], f.ranks[98], f.ranks[97] = 3, 3, 3
    local list = F.SpotList(100)
    for _, e in ipairs(list) do
        if e.name == "Busy Brook" then
            check(math.abs(F.SkillUpsPerHour(e.rates, 100) - 30) < 0.01, "skill-ups per hour: " .. tostring(F.SkillUpsPerHour(e.rates, 100)))
        end
    end
    local UI = ns.FishingUI
    UI.Show("spots")
    UI.state.sort = "gph" UI.Refresh()
    check(UI.views.spots.list.items[1].name == "Pricey Pond", "gold per hour: " .. tostring(UI.views.spots.list.items[1].name))
    -- Cycling the sort button reaches it.
    local seen = false
    for _ = 1, 8 do
        UI.views.spots.sort:Fire("OnClick", "LeftButton")
        if UI.state.sort == "skillups" then seen = true break end
    end
    check(seen and UI.views.spots.sort.label:GetText():find("Skill%-ups per hour"), "sort button")
    local first = UI.views.spots.list.items[1]
    check(first.name == "Busy Brook" and first.cols[1] == "90/h", "skill-ups first: " .. tostring(first.name) .. " " .. tostring(first.cols[1]))
    first.tooltip(TALODFishingWindow)
    UI.state.selected = { 1429, "Busy Brook" } UI.Refresh()
    local row = false
    for _, r in ipairs(UI.views.spots.detail.items) do
        if r.label == "Skill-ups" and r.text:find("~30.0 per hour") then row = true end
    end
    check(row, "skill-ups row in the spot detail")
end
