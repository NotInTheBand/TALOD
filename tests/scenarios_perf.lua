-- Frame cost: Census reads its pass over several ticks, one tick's unit reads
-- are shared and a nameplate's fixed facts are not read again every tick,
-- UNIT_* events come for the player only, SafeCall still works both ways.
local scenarios, T = ...
local check, boot = T.check, T.boot

local function enemy(i)
    return MOCK.Enemy({ name = "Foe" .. i, guid = "Player-4372-F" .. i })
end

scenarios.perf_census_pass_spread = function()
    local ns = boot(11509)
    local c = TALODDB.census
    MOCK.now = MOCK.now + 2
    for i = 1, 30 do
        MOCK.units["nameplate" .. i] = enemy(i)
        MOCK.FireEvent("NAME_PLATE_UNIT_ADDED", "nameplate" .. i)
    end
    MOCK.Tick(0.3)
    check(#c.points == 12, "first tick reads 12 players: " .. #c.points)
    MOCK.Tick(0.3)
    check(#c.points == 24, "second tick 12 more: " .. #c.points)
    MOCK.Tick(0.3)
    check(#c.points == 30, "pass done on the third: " .. #c.points)
    local last = {}
    for v in (c.points[#c.points] .. ","):gmatch("([^,]*),") do last[#last + 1] = v end
    check(last[15] == "30", "every enemy in view counted: " .. tostring(last[15]))
    MOCK.Tick(0.3)
    check(#c.points == 30, "no new pass within the second")
    check(ns.Census.Scan(MOCK.now + 10) == 30, "a whole pass at once still works")
end

scenarios.perf_tick_shared_reads = function()
    local ns = boot(11509)
    for i = 1, 5 do
        MOCK.units["nameplate" .. i] = enemy(i)
        MOCK.FireEvent("NAME_PLATE_UNIT_ADDED", "nameplate" .. i)
    end
    MOCK.Tick(0.3)   -- Census pass (time() unchanged from here on: no new one)
    local calls = 0
    local real = UnitClass
    UnitClass = function(...) calls = calls + 1 return real(...) end
    MOCK.Tick(0.3)
    check(calls == 0, "same players on the plates: class not read again, got " .. calls)
    MOCK.Tick(5.1)
    check(calls == 5, "fixed facts read again after 5 s: " .. calls)
    UnitClass = real

    -- What changes is still read every tick.
    MOCK.units.nameplate1.level = 30
    MOCK.Tick(0.3)
    check(ns.Spotter.Get("Foe1").level == 30, "level change seen")
    MOCK.units.nameplate2 = MOCK.Friend({ name = "Foe2", guid = "Player-4372-F2" })
    MOCK.Tick(0.3)
    check(ns.Spotter.Get("Foe2") == nil, "turned friendly: dropped")
    -- Another player on the same plate (no event): never shown as the first.
    MOCK.units.nameplate3 = enemy(99)
    MOCK.Tick(0.3)
    check(ns.Spotter.Get("Foe3").unit == nil, "the plate's old player is no longer live")

    -- Reads are shared inside a tick only.
    ns.BeginTickReads()
    local a = ns.ReadPlayerUnit("nameplate4")
    check(ns.ReadPlayerUnit("nameplate4") == a, "same read inside a tick")
    ns.EndTickReads()
    check(ns.ReadPlayerUnit("nameplate4") ~= a and ns.TickReads() == nil, "fresh read outside")
end

scenarios.perf_player_unit_events = function()
    local ns = boot(11509)
    local plain, player = {}, {}
    for _, events in pairs(MOCK.events) do
        for event, want in pairs(events) do
            if want == true then plain[event] = true elseif type(want) == "table" and want.player then player[event] = true end
        end
    end
    check(not plain.UNIT_HEALTH, "UNIT_HEALTH not registered")
    check(not plain.UNIT_SPELLCAST_SUCCEEDED and player.UNIT_SPELLCAST_SUCCEEDED, "casts succeeded: player only")
    check(not plain.UNIT_SPELLCAST_CHANNEL_STOP and player.UNIT_SPELLCAST_CHANNEL_STOP, "channel stop: player only")

    local got
    check(ns.SafeCall(function(a, b, c) got = a + b + (c or 0) end, 1, 2) and got == 3, "arguments passed on")
    check(ns.SafeCall(function() error("perf boom") end) == false, "an error is caught")
    check(TALODDB.errorLog[1].message:find("perf boom"), "and logged")
    TALODDB.errorLog = {}
end
