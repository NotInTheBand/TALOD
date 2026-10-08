-- Frame cost with a long recruiting history and the profession planner:
-- the recruit list keeps its order between changes (a click moves one
-- record), the unread count and the conversations are not recounted by
-- invites, a plan is kept until what it is built from changes, and
-- /talod perf lists what was slow.
local scenarios, T = ...
local check, boot, slash = T.check, T.boot, T.slash

local function guildSetup()
    MOCK.SetGuild()
    local ns = boot(11509)
    return ns, ns.Guild
end

local function sorted(list)
    for i = 2, #list do
        if (list[i].r.t or 0) > (list[i - 1].r.t or 0) then return false, i end
    end
    return true
end

scenarios.lag_recruit_order = function()
    local ns, G = guildSetup()
    local g = G.Data()
    for i = 1, 300 do g.recruits["R" .. i .. "-Mockrealm"] = { status = "declined", t = 1000 + (i * 7919) % 300 } end
    ns.Data.Bump("guild")
    local list = G.Recruits()
    check(#list == 300 and sorted(list), "first build: every record, newest first")
    check(G.Recruits() == list, "kept while nothing changes")

    -- One record touched (a click): to the top, the rest in order.
    g.recruits["R150-Mockrealm"].t = 5000
    G.Changed()
    list = G.Recruits()
    check(#list == 300 and sorted(list) and list[1].full == "R150-Mockrealm", "touched record first, all in order")

    -- New ones and a forgotten one.
    for i = 301, 303 do g.recruits["R" .. i .. "-Mockrealm"] = { status = "invited", t = 4000 + i } end
    G.Forget("R10-Mockrealm")
    list = G.Recruits()
    local has10 = false
    for _, x in ipairs(list) do if x.full == "R10-Mockrealm" then has10 = true end end
    check(#list == 302 and sorted(list) and not has10, "added and forgotten records: " .. #list)

    -- Many changed at once: still fully sorted.
    for i = 1, 100 do if g.recruits["R" .. i .. "-Mockrealm"] then g.recruits["R" .. i .. "-Mockrealm"].t = 9000 - i end end
    G.Changed()
    list = G.Recruits()
    check(#list == 302 and sorted(list) and list[1].full == "R1-Mockrealm", "a hundred moved: sorted")
end

scenarios.lag_unread_and_conversations = function()
    local ns, G = guildSetup()
    local g = G.Data()
    for i = 1, 50 do g.recruits["R" .. i .. "-Mockrealm"] = { status = "declined", t = 1000 + i } end
    local talk = { status = "invited", invited = time(), t = time(), name = "Talky",
        chat = { { t = time(), me = true, text = "hi" } } }
    g.recruits["Talky-Mockrealm"] = talk
    ns.Data.Bump("guild.replies")
    check(G.Unread() == 0 and #G.Conversations() == 0, "only your opener: no reply")

    -- Their whisper goes through AddChat: counted and listed.
    G.AddChat("Talky", "sure, invite me", false)
    check(G.Unread() == 1, "their whisper counted: " .. G.Unread())
    local convos = G.Conversations()
    check(#convos == 1 and convos[1].full == "Talky-Mockrealm", "their conversation listed")

    -- Invites and system lines change the guild data, not the conversations.
    G.Changed()
    G.Changed()
    check(G.Conversations() == convos, "an invite does not rebuild the conversations")

    G.MarkRead("Talky-Mockrealm")
    check(G.Unread() == 0, "read: not counted")
    G.ClearChat("Talky-Mockrealm")
    check(#G.Conversations() == 0, "cleared: gone")
end

-- The game answers every guild window open with its whole event log: a long
-- saved history is merged without rescanning or re-sorting all of it.
scenarios.lag_event_log_merge = function()
    local ns, G = guildSetup()
    local g = G.Data()
    g.events = {}
    local now = time()
    -- 5000 saved, oldest first, one every 10 minutes up to 2 days ago.
    for i = 1, 5000 do
        g.events[i] = G.PackEvent({ t = now - 2 * 86400 - (5000 - i) * 600, k = "invite", a = "Old" .. i .. "-Mockrealm",
            b = "Rec" .. i .. "-Mockrealm" })
    end
    -- The game's log: the newest 40 saved ones again, 30 new ones from 3 to 1
    -- days ago (older than some saved ones), 30 new from the last hours.
    local log = {}
    for i = 4961, 5000 do
        local age = 2 * 86400 + (5000 - i) * 600
        log[#log + 1] = { "invite", "Old" .. i, "Rec" .. i, nil, 0, 0, math.floor(age / 86400), math.floor(age % 86400 / 3600) }
    end
    for i = 1, 30 do log[#log + 1] = { "join", "Mid" .. i, nil, nil, 0, 0, 1 + i % 3, 0 } end
    for i = 1, 30 do log[#log + 1] = { "join", "New" .. i, nil, nil, 0, 0, 0, i % 20 } end
    MOCK.guildEvents = log
    local ok, added = G.ReadEventLog()
    check(ok and added == 60, "new entries added, saved ones not repeated: " .. tostring(added))
    check(#g.events == 5060, "kept: " .. #g.events)
    local inOrder = true
    for i = 2, #g.events do
        if G.EventTime(g.events[i]) < G.EventTime(g.events[i - 1]) then inOrder = false break end
    end
    check(inOrder, "oldest first after the merge")
    ok, added = G.ReadEventLog()
    check(ok and added == 0 and #g.events == 5060, "the same log again adds nothing")
end

scenarios.lag_plan_kept = function()
    local ns = boot(11509)
    local P = ns.Professions
    local plan = P.PlanFor(nil, "First Aid", 75)
    check(plan and plan.steps and #plan.steps > 0, "a plan")
    check(P.PlanFor(nil, "First Aid", 75) == plan, "kept while nothing changes")
    TALODDB.profPlanResale = not TALODDB.profPlanResale
    local resale = P.PlanFor(nil, "First Aid", 75)
    check(resale ~= plan, "a planner setting: rebuilt")
    check(P.PlanFor(nil, "First Aid", 60) ~= resale, "another target: another plan")
    local again = P.PlanFor(nil, "First Aid", 75)
    ns.Data.Changed("prices")
    check(P.PlanFor(nil, "First Aid", 75) ~= again, "a price changed: rebuilt")
    TALODDB.profPlanExcluded[3275] = true
    local excl = P.PlanFor(nil, "First Aid", 75)
    check(excl.steps[1].recipe == nil or excl.steps[1].recipe.id ~= 3275, "excluded recipe left out")
end

scenarios.lag_perf_report = function()
    local clock = 0
    debugprofilestop = function() clock = clock + 0.5 return clock end
    local ns = boot(11509)
    MOCK.FireEvent("PLAYER_MONEY")
    MOCK.Tick(0.3)
    local list = ns.Data.Timings()
    local kinds = {}
    for _, t in ipairs(list) do kinds[t.kind] = true end
    check(kinds.tick and kinds.event, "ticks and events timed")
    for i = 2, #list do check(list[i].max <= list[i - 1].max, "slowest first") end
    slash("perf")
    slash("perf reset")
    check(#ns.Data.Timings() == 0, "reset empties the list")
    debugprofilestop = nil
end
