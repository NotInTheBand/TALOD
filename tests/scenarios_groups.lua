-- Groups (Groups.lua, GroupsUI.lua): one record per party / raid with its
-- members, zones, chat, loot and timeline; resumed after a reload; unknown
-- never recorded as a value; the window and its views.
local scenarios, T = ...
local check, boot, slash = T.check, T.boot, T.slash

-- Seconds of play: time() and GetTime() move together, one tick per second.
local function run(seconds)
    for _ = 1, seconds do
        MOCK.now = MOCK.now + 1
        MOCK.Tick(1)
    end
end

local function buddy(fields)
    local u = MOCK.Friend({ name = "Buddy", guid = "Player-1-B", class = "WARRIOR", level = 24, guild = "Brave Souls",
        role = "TANK", healthMax = 900, powerMax = 100, powerType = 1 })
    for k, v in pairs(fields or {}) do u[k] = v end
    return u
end

local function healy(fields)
    local u = MOCK.Friend({ name = "Healy", guid = "Player-1-H", class = "PRIEST", level = 25, role = "HEALER", leader = true })
    for k, v in pairs(fields or {}) do u[k] = v end
    return u
end

local GREEN = "|cff1eff00|Hitem:2000::::::::20:::::::|h[Green Belt]|h|r"
local GREY = "|cff9d9d9d|Hitem:2001::::::::20:::::::|h[Broken Tooth]|h|r"

scenarios.groups_party_record = function()
    local ns = boot(11509)
    local G = ns.Groups
    check(G.Current() == nil, "solo: no open group")
    MOCK.SetGroup({ buddy(), healy() })
    run(3)
    local s = G.Current()
    check(s and s.kind == "party" and s.c == ns.Store.Me(), "a party record opened for this character")
    check(G.MemberCount(s) == 2, "two members: " .. G.MemberCount(s))
    local b = s.m["Buddy-Mockrealm"]
    check(b and b.cls == "WARRIOR" and b.lvl == 24 and b.g == "Brave Souls" and b.role == "TANK", "facts read")
    check(b.hp == 900 and b.pw == "RAGE" and b.pwm == 100, "health and power maxima")
    check(s.leader == "Healy-Mockrealm" and s.m["Healy-Mockrealm"].lead == 2, "leader")
    check(s.zones["Elwynn Forest"] and s.zones["Elwynn Forest"] >= 2, "time in the zone")

    -- Chat: the group's lines; a hidden sender is counted, never given to anyone.
    MOCK.FireEvent("CHAT_MSG_PARTY", "pull in 5", "Healy-Mockrealm")
    MOCK.FireEvent("CHAT_MSG_PARTY_LEADER", "go", "Healy")
    MOCK.FireEvent("CHAT_MSG_PARTY", "?", nil)
    MOCK.FireEvent("CHAT_MSG_GUILD", "not group chat", "Healy")
    local chat = G.Chat(s)
    check(#chat == 2 and chat[1][2] == "Healy-Mockrealm" and chat[1][3] == "p" and chat[1][4] == "pull in 5", "two lines kept")
    check(chat[2][3] == "P", "leader channel")
    check(s.chatHidden == 1, "hidden sender counted apart")

    -- Loot from the loot messages: grey under the setting is skipped.
    MOCK.FireEvent("CHAT_MSG_LOOT", "Buddy receives loot: " .. GREEN .. ".")
    MOCK.FireEvent("CHAT_MSG_LOOT", "You receive loot: " .. GREEN .. "x2.")
    MOCK.FireEvent("CHAT_MSG_LOOT", "Buddy receives loot: " .. GREY .. ".")
    local loot = G.Loot(s)
    check(#loot == 2, "two items kept: " .. #loot)
    check(loot[1][2] == "Buddy-Mockrealm" and loot[1][3] == GREEN and loot[1][4] == 1, "who and what")
    check(loot[2][2] == ns.Guild.Me() and loot[2][4] == 2, "your own loot with its count")

    -- A death counts only after the member was seen alive.
    MOCK.units.party1.dead = true
    run(2)
    check(s.m["Buddy-Mockrealm"].dead == 1 and s.deaths == 1, "one death")
    run(2)
    check(s.m["Buddy-Mockrealm"].dead == 1, "still one while dead")
    MOCK.units.party1.dead = false
    MOCK.units.party1.connected = false
    run(3)
    check((s.m["Buddy-Mockrealm"].off or 0) >= 2, "offline time")
    check(s.m["Buddy-Mockrealm"].dead == 1, "offline is not a death")

    -- Buddy leaves; the party goes on.
    MOCK.SetGroup({ healy() })
    MOCK.FireEvent("GROUP_ROSTER_UPDATE")
    run(2)
    check(s.m["Buddy-Mockrealm"].left ~= nil and not s.m["Buddy-Mockrealm"].here, "left")
    local kinds = {}
    for _, e in ipairs(G.Events(s)) do kinds[#kinds + 1] = e[2] end
    local seq = table.concat(kinds, ",")
    check(seq:find("died") and seq:find("left"), "timeline: " .. seq)

    -- Out of the group: ended after a few seconds, packed.
    MOCK.SetGroup(nil)
    run(2)
    check(G.Current() ~= nil, "a moment out of the group does not end it")
    run(5)
    check(G.Current() == nil, "ended")
    local list = TALODDB.groups.list
    check(#list == 1 and list[1].packed and type(list[1].m[1]) == "string", "kept, members packed")
    check(list[1].names:find("Buddy") and list[1].names:find("Healy"), "names for search")
    local members = G.Members(list[1])
    check(#members == 2 and members[1].key == "Healy-Mockrealm", "most time together first: " .. tostring(members[1].key) .. "=" .. tostring(members[1].secs) .. " " .. tostring(members[2] and members[2].key) .. "=" .. tostring(members[2] and members[2].secs))
    check(members[2].key == "Buddy-Mockrealm" and members[2].dead == 1 and members[2].g == "Brave Souls", "unpacked facts")
    check(#G.With("Buddy-Mockrealm") == 1 and #G.With("Nobody-Mockrealm") == 0, "find the groups you shared")
    check(#G.Sessions("party") == 1 and #G.Sessions("raid") == 0, "listed as a party")
end

scenarios.groups_raid_and_short = function()
    local ns = boot(11509)
    local G = ns.Groups

    -- A stray invite (under a minute, no chat) is not kept.
    MOCK.SetGroup({ buddy() })
    run(20)
    MOCK.SetGroup(nil)
    run(8)
    check(G.Current() == nil and #G.Store().list == 0, "short group dropped")

    -- A party that becomes a raid is one record, a raid from then on.
    MOCK.SetGroup({ buddy() })
    run(30)
    local s = G.Current()
    MOCK.SetGroup({ buddy({ subgroup = 2, raidRank = 1, zone = "Molten Core" }), healy({ subgroup = 1, raidRank = 2, ml = true }) }, true)
    MOCK.zone = "Molten Core"
    MOCK.instance = { "Molten Core", "raid" }
    run(40)
    check(G.Current() == s and s.kind == "raid" and s.raidAt, "same record, now a raid")
    local b, h = s.m["Buddy-Mockrealm"], s.m["Healy-Mockrealm"]
    check(b.sub == 2 and b.lead == 1 and b.zone == "Molten Core", "raid roster: subgroup, assist, zone")
    check(h.lead == 2 and h.ml == true and s.leader == "Healy-Mockrealm", "raid leader, master looter")
    check(G.MemberCount(s) == 2, "the player's own raid unit is not a member")
    check(s.zi and s.zi["Molten Core"] == "raid", "instance noted")
    MOCK.FireEvent("CHAT_MSG_RAID_WARNING", "spread", "Healy")
    check(G.Chat(s)[1][3] == "w", "raid warning kept")
    MOCK.SetGroup(nil)
    run(8)
    check(#G.Sessions("raid") == 1 and #G.Sessions("party") == 0, "listed with raids")
    local zones = G.Zones(G.Sessions("raid")[1])
    check(zones[1][1] == "Molten Core", "most time: Molten Core")
end

scenarios.groups_hidden_and_resume = function()
    local now = os.time()
    MOCK.now = now
    local saved = { groups = { n = 7, list = {}, cur = { id = 7, c = 1, kind = "party", start = now - 600, last = now - 120,
        size = 2, m = { ["Buddy-Mockrealm"] = { join = now - 600, secs = 400, cls = "WARRIOR" } }, zones = {}, zl = {},
        ev = {}, chat = {}, loot = {}, deaths = 0 } } }
    MOCK.SetGroup({ buddy(), MOCK.Friend({ name = "Ghost", guid = "Player-1-G", secret = { name = true } }) })
    MOCK.secretMode = true
    local ns = boot(11509, { db = saved, secrets = true })
    local G = ns.Groups
    run(3)
    local s = G.Current()
    check(s and s.id == 7, "reload within minutes: the same record goes on")
    check(s.m["Buddy-Mockrealm"].secs >= 400, "time kept")
    local keys = {} for k in pairs(s.m) do keys[#keys + 1] = k end
    check(G.MemberCount(s) == 1 and (s.hidden or 0) > 0, "a hidden name is counted, not recorded: " .. table.concat(keys, ",") .. " hidden " .. tostring(s.hidden))
    for key in pairs(s.m) do check(key:find("^Buddy"), "only Buddy: " .. key) end
end

scenarios.groups_resume_old = function()
    local now = os.time()
    MOCK.now = now
    local saved = { groups = { n = 3, list = {}, cur = { id = 3, c = 1, kind = "party", start = now - 7200, last = now - 3600,
        size = 2, m = { ["Buddy-Mockrealm"] = { join = now - 7200, secs = 3000 } }, zones = {}, zl = {}, ev = {},
        chat = {}, loot = {}, deaths = 0 } } }
    MOCK.SetGroup({ buddy() })
    local ns = boot(11509, { db = saved })
    local G = ns.Groups
    run(2)
    local s = G.Current()
    check(s and s.id == 4, "an hour later: a new record")
    local old = G.ById(3)
    check(old and old.stop == now - 3600 and old.packed, "the old one ended at its last time")
    local m = G.Members(old)[1]
    check(m.key == "Buddy-Mockrealm" and m.left == now - 3600, "its members left then: " .. tostring(m.key) .. " " .. tostring(m.left) .. " vs " .. (now - 3600))
end

scenarios.groups_window = function()
    local ns = boot(11509)
    local G, UI = ns.Groups, ns.GroupsUI
    slash("groups")
    check(UI.IsShown() and UI.state.view == "now", "opens on Now")
    check(UI.views.now.note:IsShown(), "solo: says so")

    MOCK.SetGroup({ buddy({ health = 300 }), healy() })
    run(3)
    MOCK.FireEvent("CHAT_MSG_PARTY", "hello", "Buddy")
    UI.Refresh()
    local now = UI.views.now
    check(now.list:IsShown() and #now.list.items == 2, "two live rows")
    local found
    for _, item in ipairs(now.list.items) do
        if item.key == "Buddy-Mockrealm" then found = item end
    end
    check(found and found.bar and found.bar[1] == 300 and found.cols[1]:find("33%%"), "live health")

    slash("groups parties")
    check(UI.state.view == "party", "Parties tab")
    local plist = UI.views.party.list
    check(#plist.items == 1 and plist.items[1].id == G.Current().id, "the open group listed")
    check(plist.items[1].text:find("now"), "marked now")

    -- One group: members, chat, loot, timeline.
    UI.state.session = G.Current().id
    UI.Show("session")
    local v = UI.views.session
    check(v.top:IsShown() and #v.list.items == 2, "members of the group")
    UI.state.mode = "chat"
    UI.Refresh()
    check(#v.list.items == 1 and v.list.items[1].text:find("hello"), "chat line shown")
    UI.state.mode = "timeline"
    UI.Refresh()
    UI.state.mode = "loot"
    UI.Refresh()
    check(v.list.items[1].text:find("No loot"), "no loot yet")

    -- "raid" is a word for the same command; the Raids tab is empty.
    slash("groups raids")
    check(UI.state.view == "raid" and UI.views.raid.list.items[1].text:find("No raids"), "Raids tab empty")

    -- Out of the group, then deleted.
    UI.state.mode = "members"
    MOCK.SetGroup(nil)
    run(8)
    local id = G.Sessions()[1].id
    check(G.Delete(id) and #G.Sessions() == 0, "deleted")
end

scenarios.groups_cleanup_and_check = function()
    local now = os.time()
    MOCK.now = now
    local old = { id = 1, c = 1, kind = "party", start = now - 400 * 86400, stop = now - 400 * 86400 + 3600, packed = true,
        m = { "sBuddy-Mockrealm" }, names = "Buddy" }
    local recent = { id = 2, c = 1, kind = "raid", start = now - 86400, stop = now - 80000, packed = true, m = {}, names = "" }
    local ns = boot(11509, { db = { store = { v = {} }, groups = { n = 3, list = { old, recent, "junk" } } } })
    local G = ns.Groups
    check(#G.Store().list == 2, "an unreadable entry set aside at load")
    check(G.DropOld(now - 365 * 86400, false) == 1, "one older than a year")
    check(#G.Store().list == 2, "preview removes nothing")
    local rule = ns.Cleanup.rules.groups
    check(rule and ns.Cleanup.Preview(rule) == 1, "cleanup rule sees it")
    check(G.DropOld(now - 365 * 86400, true) == 1 and #G.Store().list == 1 and G.Store().list[1].id == 2, "removed")
    local m = G.Members(old)
    check(m[1].key == "Buddy-Mockrealm", "packed member reads back")
end
