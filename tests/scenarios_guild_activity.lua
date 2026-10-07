-- Guild activity (GuildActivity.lua, the Activity tab): guild chat lines per
-- member, quiet vs not seen, officers and the guild master only.
local scenarios, T = ...
local check, boot, slash = T.check, T.boot, T.slash

local KEY = "Brave Souls-Mockrealm"

local ROSTER = {
    { name = "Alpha", rank = 0, level = 60, classFile = "WARRIOR", online = true },
    { name = "Bravo", rank = 3, level = 30, classFile = "MAGE", online = true },
    { name = "Charlie", rank = 3, level = 20, classFile = "PRIEST", offline = { 0, 0, 3, 0 } },
}

local function setup(guild)
    guild = guild or {}
    guild.roster = guild.roster or ROSTER
    MOCK.SetGuild(guild)
    local ns = boot(11509)
    MOCK.FireEvent("GUILD_ROSTER_UPDATE")
    MOCK.Tick(2.1)
    return ns
end

local function data() return TALODDB.guild.guilds[KEY] end

scenarios.guild_activity_chat = function()
    local ns = setup()
    local A, UI = ns.GuildActivity, ns.GuildUI
    check(ns.Guild.IsOfficer() == true, "promote right: officer")

    -- Lines from guild chat; the roster's name form or the chat's.
    MOCK.FireEvent("CHAT_MSG_GUILD", "hello all", "Alpha-Mockrealm")
    MOCK.FireEvent("CHAT_MSG_GUILD", "o/", "Alpha")
    local rec = data().chat["Alpha-Mockrealm"]
    check(rec and rec.n == 2, "two lines for Alpha: " .. tostring(rec and rec.n))

    -- A hidden sender is counted apart, never given to anyone.
    MOCK.FireEvent("CHAT_MSG_GUILD", "???", nil)
    check(data().chatHidden == 1, "hidden sender counted apart")

    -- Online with you (the roster) but silent = quiet; offline and silent = not seen.
    MOCK.Tick(61)
    check(A.Chat("Alpha-Mockrealm").status == "active", "Alpha active")
    check(A.Chat("Bravo-Mockrealm").status == "quiet", "Bravo quiet: " .. A.Chat("Bravo-Mockrealm").status)
    check(A.Chat("Charlie-Mockrealm").status == "unseen", "Charlie not seen")
    local watched = A.Watched()
    check(watched == 1, "one day watched: " .. tostring(watched))

    -- Past the window, Alpha's lines no longer count as active.
    MOCK.now = MOCK.now + 8 * 86400
    check(A.Chat("Alpha-Mockrealm").status == "unseen", "old lines and old online day: not seen")
    local c = A.Chat("Alpha-Mockrealm", 7)
    check(c.lines == 0 and c.last ~= nil, "lines outside the window not counted, last kept")
    check(A.Chat("Alpha-Mockrealm", 30).lines == 2, "30-day window still has them")

    -- The tab: listed for an officer, filters, window button.
    slash("guild activity")
    check(UI.state.view == "activity", "slash opens the Activity tab")
    local v = UI.views.activity
    check(v.list:IsShown() and not v.note:IsShown(), "officer sees the list")
    check(#v.list.all == 3, "three members: " .. #v.list.all)
    for _, row in ipairs(v.list.all) do if row.tooltip then row.tooltip(TALODGuildWindow) end end
    v.filters[3]:Fire("OnClick", "LeftButton")   -- Quiet
    check(UI.state.activity == "quiet", "quiet filter")
    v.window:Fire("OnClick", "LeftButton")
    check(TALODDB.guildChatDays == 14, "window 7 -> 14: " .. tostring(TALODDB.guildChatDays))
    v.filters[1]:Fire("OnClick", "LeftButton")
    check(v.card.title:GetText():find("3 members"), "title counts members")

    -- A chat line while the tab is open redraws it.
    MOCK.now = MOCK.now + 1
    MOCK.FireEvent("CHAT_MSG_GUILD", "back", "Charlie-Mockrealm")
    MOCK.Tick(1.1)
    check(A.Chat("Charlie-Mockrealm").status == "active", "Charlie active now")

    -- Clear needs Shift.
    v.clear:Fire("OnClick", "LeftButton")
    check(data().chat ~= nil, "plain click keeps the counts")
    MOCK.shift = true
    v.clear:Fire("OnClick", "LeftButton")
    MOCK.shift = false
    check(data().chat == nil, "shift-click clears")

    -- A signal added later is one more column.
    A.AddSignal({ key = "test", label = "Test", width = 40, read = function() return 1, "x" end })
    check(#A.signals == 4, "fourth signal")
    local list = A.Members("all")
    check(list[1].cells[4].text == "x", "signal read per member")
end

scenarios.guild_activity_member_only = function()
    -- Rank 3, invite right only: not an officer by the game's permissions.
    local ns = setup({ rankName = "Member", rankIndex = 3, can = { invite = true } })
    local A, UI = ns.GuildActivity, ns.GuildUI
    check(ns.Guild.IsOfficer() == false, "member is not an officer")
    MOCK.FireEvent("CHAT_MSG_GUILD", "hi", "Alpha-Mockrealm")
    MOCK.Tick(61)
    check(data().chat == nil, "nothing recorded for a member")

    -- The tab is not offered; asking for it lands on the roster.
    slash("guild activity")
    check(UI.state.view == "roster", "activity refused: " .. tostring(UI.state.view))
    local tab
    for _, t in ipairs(TALODGuildWindow.tabs) do if t.key == "activity" then tab = t end end
    check(tab and not tab:IsShown(), "Activity tab hidden")

    -- Officer notes right: an officer (cached check read again).
    CanViewOfficerNote = function() return true end
    A.Recheck()
    check(ns.Guild.IsOfficer() == true, "officer-note right: officer")
    ns.GuildUI.Show("activity")
    check(UI.state.view == "activity" and tab:IsShown(), "tab shown once an officer")
    CanViewOfficerNote = nil

    -- The guild master by rank alone.
    MOCK.guild.rankIndex, MOCK.guild.can = 0, {}
    check(ns.Guild.IsOfficer() == true, "rank 0 is the guild master")
end
