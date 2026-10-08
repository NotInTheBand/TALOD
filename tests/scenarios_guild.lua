-- Guild (Guild.lua, GuildUI.lua): recruits without a guild, one-click
-- whisper + invite, /who, roster diffs and the log, promotion rules, window.
local scenarios, T = ...
local check, boot, slash, printed, plateAdd, plateRemove, setTarget, resetOutput =
    T.check, T.boot, T.slash, T.printed, T.plateAdd, T.plateRemove, T.setTarget, T.resetOutput

local KEY = "Brave Souls-Mockrealm"

local function setup(iface, opts)
    opts = opts or {}
    MOCK.SetGuild(opts.guild)
    local ns = boot(iface or 11509, opts)
    MOCK.cvars.nameplateShowFriends = "1"
    return ns
end

local function wait(seconds)
    for _ = 1, math.ceil(seconds / 0.5) do MOCK.Tick(0.5) end
end

local function readRoster()
    MOCK.FireEvent("GUILD_ROSTER_UPDATE")
    MOCK.Tick(2.1)
end

local function data() return TALODDB.guild.guilds[KEY] end

local function names(list)
    local out = {}
    for _, c in ipairs(list) do out[#out + 1] = c.name or c.full end
    return table.concat(out, ",")
end

scenarios.guild_recruit = function()
    local ns = setup()
    local G = ns.Guild

    -- No guild on the first read is not enough: the data may not be there yet.
    plateAdd("nameplate1", MOCK.Friend({ name = "Newbie", guid = "Player-1-N", level = 12 }))
    check(#G.Candidates() == 0, "not listed on the first read")
    wait(5)
    check(names(G.Candidates()) == "Newbie", "listed after two reads: " .. names(G.Candidates()))

    -- In a guild, the other faction, an unknown faction: never listed.
    plateAdd("nameplate2", MOCK.Friend({ name = "Guilded", guid = "Player-1-G", guild = "Other" }))
    plateAdd("nameplate3", MOCK.Enemy({ name = "Hordie", guid = "Player-1-H", guild = nil }))
    plateAdd("nameplate4", MOCK.Friend({ name = "Nofaction", guid = "Player-1-F", faction = false }))
    wait(5)
    check(names(G.Candidates()) == "Newbie", "only the unguilded ally: " .. names(G.Candidates()))

    -- A guild showing up later takes them off the list.
    MOCK.units.nameplate1.guild = "Late Guild"
    wait(1.5)
    check(#G.Candidates() == 0, "guild read later: dropped")
    MOCK.units.nameplate1.guild = nil
    wait(5)

    -- Level filter.
    TALODDB.guildRecruitMaxLevel = 10
    check(#G.Candidates() == 0, "above the level filter")
    TALODDB.guildRecruitMaxLevel = 60

    -- Time passing never sends anything.
    wait(30)
    check(#MOCK.whispers == 0 and #MOCK.guildInvites == 0, "nothing sent from the tick")

    -- Delayed invite (default): the first click is the whisper; 10 s later
    -- they are back on the list in red and the second click is the invite.
    -- Never from the tick: the game blocks a guild invite outside a click.
    check(TALODDB.guildDelayedInvite == true, "delayed invite on by default")
    local full = "Newbie-Mockrealm"
    check(G.Invite(full) == true, "first click accepted")
    check(#MOCK.whispers == 1 and MOCK.whispers[1].target == "Newbie", "one whisper to Newbie")
    check(MOCK.whispers[1].text:find("^Hi Newbie!") and MOCK.whispers[1].text:find("<Brave Souls>"), "message filled: " .. MOCK.whispers[1].text)
    local r = data().recruits[full]
    check(#MOCK.guildInvites == 0 and r.status == "inviting", "the invite waits for the whisper to be read")
    check(#G.Candidates() == 0, "inviting: off the list")
    check(G.Invite(full) == false and #MOCK.guildInvites == 0, "a click before its time sends nothing")
    wait(9)
    check(#MOCK.guildInvites == 0 and #G.Candidates() == 0, "not back before 10 s")
    wait(1.5)
    check(#MOCK.guildInvites == 0, "no invite from the tick")
    local back = G.Candidates()
    check(#back == 1 and back[1].full == full and back[1].ready, "back on the list, ready")
    local rows = ns.GuildUI.CandidateRows()
    check(rows[1].tint == ns.GuildUI.TINT_READY, "red bar on the ready row")
    check(G.InviteIn(full) == 0 and G.InvitesReady() == 1, "ready counted")
    check(G.Invite(full) == true, "second click")
    check(MOCK.guildInvites[1] == "Newbie" and #MOCK.guildInvites == 1 and #MOCK.whispers == 1, "one invite, no second whisper")
    check(r and r.status == "invited" and r.level == 12 and r.by == "Tester-Mockrealm", "recruit recorded")
    check(#G.Candidates() == 0, "invited: off the list")

    -- A third click right away sends nothing.
    G.Invite(full)
    check(#MOCK.whispers == 1 and #MOCK.guildInvites == 1, "double click guarded")

    -- The game's answer.
    MOCK.FireEvent("CHAT_MSG_SYSTEM", "Newbie declines your guild invitation.")
    check(r.status == "declined", "declined: " .. tostring(r.status))
    MOCK.FireEvent("CHAT_MSG_WHISPER", "no thanks", "Newbie")
    check(r.replied ~= nil, "reply noticed")

    -- Offered again after the re-invite time.
    MOCK.now = MOCK.now + 8 * 86400
    wait(1.5)
    check(names(G.Candidates()) == "Newbie", "offered again after 7 days")

    -- Skip and forget.
    G.Skip(full)
    check(#G.Candidates() == 0 and r.status == "skipped", "skipped")
    MOCK.now = MOCK.now + 30 * 86400
    check(#G.Candidates() == 0, "skipped stays off")
    G.Forget(full)
    check(names(G.Candidates()) == "Newbie", "forgotten: listed again")

    -- Whisper off: invite only (game time passes too: the Outbox does not
    -- send the same invite twice within seconds).
    wait(11)
    TALODDB.guildWhisper = false
    G.Invite(full)
    check(#MOCK.whispers == 1 and #MOCK.guildInvites == 2, "no whisper when off")
    TALODDB.guildWhisper = true

    -- A rank without the Invite permission sends nothing.
    resetOutput()
    MOCK.guild.can.invite = false
    G.Forget(full)
    G.Invite(full)
    check(#MOCK.guildInvites == 2 and printed("cannot invite"), "rank cannot invite")
    MOCK.guild.can.invite = true

    -- Typed command on your target.
    setTarget(MOCK.Friend({ name = "Targ", guid = "Player-1-T", level = 30 }))
    slash("guild invite")
    wait(10.5)
    slash("guild invite")  -- second click: the invite
    check(MOCK.guildInvites[3] == "Targ" and MOCK.whispers[2].target == "Targ", "slash invite on target")
    check(data().recruits["Targ-Mockrealm"].level == 30, "target facts kept")

    -- A guild member is not invited again.
    MOCK.guild.roster = { { name = "Member", rank = 3, level = 20, classFile = "MAGE", online = true } }
    readRoster()
    resetOutput()
    G.Invite("Member-Mockrealm")
    check(#MOCK.guildInvites == 3 and printed("already in your guild"), "member not invited")
end

scenarios.guild_who = function()
    local ns = setup()
    local G = ns.Guild
    -- The Forever beta stops at level 30: the whole range is one search.
    GetMaxPlayerLevel = function() return 30 end
    check(select(2, G.LevelRange()) == 30, "range capped at the game's top level")
    slash("guild who")
    check(MOCK.whoQueries[1] == 'z-"Elwynn Forest" 1-30', "whole range in this zone: " .. tostring(MOCK.whoQueries[1]))
    MOCK.whoResults = {
        { fullName = "Solo", fullGuildName = "", level = 7, filename = "MAGE", area = "Elwynn Forest", raceStr = "Gnome" },
        { fullName = "Taken", fullGuildName = "Some Guild", level = 8, filename = "ROGUE", area = "Elwynn Forest" },
    }
    MOCK.FireEvent("WHO_LIST_UPDATE")
    local list = G.Candidates()
    check(names(list) == "Solo" and list[1].src == "who" and list[1].classFile == "MAGE", "unguilded /who result listed at once")
    check(G.WhoStatus():find("1 without a guild, 1 in one"), "status: " .. tostring(G.WhoStatus()))

    -- Results nobody asked for are ignored.
    MOCK.whoResults = { { fullName = "Stray", fullGuildName = "", level = 9, filename = "MAGE" } }
    MOCK.FireEvent("WHO_LIST_UPDATE")
    check(names(G.Candidates()) == "Solo", "unrequested results ignored")

    -- Five seconds between searches.
    check(G.Who() == false and #MOCK.whoQueries == 1, "too soon: nothing sent")
    check(ns.GuildUI.WhoLabel():find("wait"), "button shows the wait")
    MOCK.Tick(4.1)
    check(G.WhoWait() > 0, "still waiting after 4 s")
    MOCK.Tick(1)
    check(G.WhoWait() == 0, "wait over")

    -- Not full: the next click searches the whole range again.
    MOCK.whoResults = {}
    G.Who()
    MOCK.FireEvent("WHO_LIST_UPDATE")
    check(MOCK.whoQueries[2] == 'z-"Elwynn Forest" 1-30', "whole range again: " .. tostring(MOCK.whoQueries[2]))

    -- A full answer: the next clicks split it, a full part is split again, then back to the whole.
    local function fullAnswer()
        MOCK.whoResults = {}
        for i = 1, 50 do MOCK.whoResults[i] = { fullName = "P" .. i, fullGuildName = "G", level = 10 } end
        MOCK.FireEvent("WHO_LIST_UPDATE")
    end
    local function next(full)
        MOCK.Tick(5.1)
        G.Who()
        if full then fullAnswer() else MOCK.whoResults = {} MOCK.FireEvent("WHO_LIST_UPDATE") end
        return MOCK.whoQueries[#MOCK.whoQueries]:gsub('^z%-"[^"]*" ', "")
    end
    TALODDB.guildWhoZone = false
    check(next(true) == "1-30", "whole range, full")
    check(G.WhoStatus():find("the list was full") and G.WhoStatus():find("next 1%-10"), "status says what comes: " .. G.WhoStatus())
    check(next(true) == "1-10", "first part, full again")
    check(next(false) == "1-5", "its first half")
    check(next(false) == "6-10", "its second half")
    check(next(false) == "11-20", "second part")
    check(next(false) == "21-30", "third part")
    check(G.WhoStatus():find("every level range searched"), "done: " .. G.WhoStatus())
    check(next(false) == "1-30", "back to the whole range")

    -- Level filter narrower than the cap; Classic Era goes to 60.
    TALODDB.guildRecruitMinLevel, TALODDB.guildRecruitMaxLevel = 15, 25
    check(next(false) == "15-25", "level filter")
    GetMaxPlayerLevel = function() return 60 end
    TALODDB.guildRecruitMinLevel, TALODDB.guildRecruitMaxLevel = 1, 60
    check(next(false) == "1-60", "Classic Era: 1-60")

    -- Ticks never search.
    local n = #MOCK.whoQueries
    wait(60)
    check(#MOCK.whoQueries == n, "no /who from the tick")
end

-- Hands Free: a click on the open world is the next recruit click (red row,
-- else the next whisper, else one /who); windows, units and combat excluded.
scenarios.guild_hands_free = function()
    local ns = setup()
    local G = ns.Guild
    local function click(button) MOCK.MouseDown(button) end

    -- Off by default: world clicks do nothing.
    check(TALODDB.guildHandsFree == false, "off by default")
    click()
    check(#MOCK.whoQueries == 0 and #MOCK.whispers == 0, "off: nothing")

    slash("guild handsfree")
    check(TALODDB.guildHandsFree == true, "slash turns it on")

    -- No click seen yet: the trace says so.
    resetOutput()
    slash("guild handsfree why")
    check(printed("no click or key"), "why: no click seen")

    -- Nobody listed: the click runs a /who; the next one waits only for the
    -- /who button's own 5 s.
    click()
    check(#MOCK.whoQueries == 1, "/who from a world click")
    MOCK.whoResults = {}
    MOCK.FireEvent("WHO_LIST_UPDATE")
    wait(2)
    click()
    check(#MOCK.whoQueries == 1, "no second /who within the button's wait")
    local p = G.HandsFreePresses()
    check(#p == 2 and p[1].result == "/who" and p[2].result:find("next /who in"), "trace: " .. tostring(p[2] and p[2].result))

    -- Ticks and events never act, even while on.
    wait(40)
    check(#MOCK.whoQueries == 1 and #MOCK.whispers == 0, "nothing from the tick")

    -- A recruit on the list: a /who that is due still goes first (searching
    -- goes on while nameplates fill the list), then the whisper; ten seconds
    -- later the next click invites.
    plateAdd("nameplate1", MOCK.Friend({ name = "Newbie", guid = "Player-1-N", level = 12 }))
    wait(5)
    check(names(G.Candidates()) == "Newbie", "listed")
    -- A click on a window or on a unit is used already.
    MOCK.focus = UIParent
    click()
    check(#MOCK.whispers == 0 and #MOCK.whoQueries == 1, "click on a window: nothing")
    MOCK.focus = nil
    MOCK.units.mouseover = MOCK.Friend({ name = "Npc", guid = "Creature-1" })
    click("RightButton")
    check(#MOCK.whispers == 0 and #MOCK.whoQueries == 1, "click on a unit: nothing")
    MOCK.units.mouseover = nil
    p = G.HandsFreePresses()
    check(p[#p - 1].result:find("window") and p[#p].result:find("unit"), "trace: window, unit")
    click("MiddleButton")
    check(#MOCK.whispers == 0, "middle button: nothing")
    click("RightButton")
    check(#MOCK.whoQueries == 2 and #MOCK.whispers == 0, "list not empty, /who due: the /who first")
    MOCK.FireEvent("WHO_LIST_UPDATE")
    wait(2)
    click("RightButton")
    check(#MOCK.whispers == 1 and MOCK.whispers[1].target == "Newbie", "right-click on the world: the whisper")
    check(G.HandsFreeLast().what == "whisper", "last action kept")
    click()
    check(#MOCK.whispers == 1 and #MOCK.guildInvites == 0, "nothing left to do: nothing sent")
    wait(11)
    check(#MOCK.guildInvites == 0, "no invite from the tick")
    -- In combat: paused.
    MOCK.lockdown = true
    click()
    check(#MOCK.guildInvites == 0 and G.HandsFreeBlocked() == "in combat", "paused in combat")
    MOCK.lockdown = false
    click()
    check(MOCK.guildInvites[1] == "Newbie" and #MOCK.whispers == 1, "the next world click: the invite")

    wait(1)
    resetOutput()
    click()
    check(#MOCK.whoQueries == 3, "/who again once the button's wait is over")
    slash("guild handsfree why")
    check(printed("over WorldFrame: /who"), "why lists the clicks")

    -- A refusal outside a step (another of the addon's calls) is not Hands Free's.
    MOCK.FireEvent("ADDON_ACTION_BLOCKED", "TALOD", "SomethingElse()")
    check(TALODDB.guildHandsFree == true, "a block elsewhere: stays on")

    -- The game blocks the /who inside the call (it fires the event there and
    -- the call returns as if it went): traced, Hands Free stays on; three in
    -- a row and world clicks leave the /who alone, keys still try it.
    local realSend = C_FriendList.SendWho
    C_FriendList.SendWho = function() MOCK.FireEvent("ADDON_ACTION_BLOCKED", "TALOD", "C_FriendList.SendWho()") end
    resetOutput()
    for _ = 1, 3 do
        wait(5.1)
        click()
    end
    p = G.HandsFreePresses()
    check(TALODDB.guildHandsFree == true, "blocked: stays on")
    check(p[#p].result:find("blocked by the game"), "trace says blocked: " .. tostring(p[#p].result))
    check(printed("blocked the /who from world clicks 3 times"), "told once it backs off")
    C_FriendList.SendWho = realSend
    wait(5.1)
    local whos = #MOCK.whoQueries
    click()
    check(#MOCK.whoQueries == whos, "world clicks leave the /who alone now")
    MOCK.KeyDown("W")
    check(#MOCK.whoQueries == whos + 1, "a move key still runs it")
    resetOutput()
    slash("guild handsfree why")
    check(printed("left alone") and printed("mouse:who"), "why names what is left alone")
    slash("guild handsfree")
    check(TALODDB.guildHandsFree == false, "off again")

    -- Delayed invite on, the game blocks Hands Free's invite to a red row: the
    -- row stays red for your click (which sends it at once, no "repeat"),
    -- and Hands Free never tries that player again (it used to loop on them).
    slash("guild handsfree")
    plateAdd("nameplate4", MOCK.Friend({ name = "Stuck", guid = "Player-1-S", level = 16 }))
    wait(5)
    G.Who()
    MOCK.MouseDown("LeftButton")   -- the whisper
    check(data().recruits["Stuck-Mockrealm"].status == "inviting", "Stuck: whispered")
    wait(11)
    G.Who()
    local tries = 0
    local realInvite = C_GuildInfo.Invite
    C_GuildInfo.Invite = function()
        tries = tries + 1
        MOCK.FireEvent("ADDON_ACTION_BLOCKED", "TALOD", "C_GuildInfo.Invite()")
    end
    resetOutput()
    MOCK.MouseDown("LeftButton")
    check(tries == 1 and printed("blocked the guild invite to Stuck") and printed("click their red row"), "blocked, told once")
    local back = G.Candidates()
    check(#back >= 1 and back[#back].full == "Stuck-Mockrealm" and back[#back].ready, "still a red row")
    check(G.HandsFreeBlockedFor("Stuck-Mockrealm"), "marked for your click")
    wait(2)
    MOCK.MouseDown("LeftButton")
    check(tries == 1, "Hands Free does not try them again")
    C_GuildInfo.Invite = realInvite
    local before = #MOCK.guildInvites
    check(G.Invite("Stuck-Mockrealm") and #MOCK.guildInvites == before + 1, "your click on the row sends it at once")
    check(data().recruits["Stuck-Mockrealm"].status == "invited", "invited")
    slash("guild handsfree")

    -- One Hands Free step a second: a click or key sooner does nothing (and
    -- says so); the recruit key does not wait.
    slash("guild handsfree")
    plateAdd("nameplate2", MOCK.Friend({ name = "Alpha", guid = "Player-1-A", level = 14 }))
    plateAdd("nameplate3", MOCK.Friend({ name = "Bravo", guid = "Player-1-B", level = 15 }))
    wait(5)
    G.Who()   -- the /who button: its wait keeps the next clicks on the list
    local sent = #MOCK.whispers
    click()
    click()
    MOCK.KeyDown("W")
    check(#MOCK.whispers + ns.Outbox.Pending() == sent + 1, "three quick presses: one whisper")
    p = G.HandsFreePresses()
    check(p[#p].result:find("too soon") and p[#p - 1].result:find("too soon"), "the others: too soon")
    wait(0.5)
    click()
    check(#MOCK.whispers + ns.Outbox.Pending() == sent + 1, "half a second later: still waiting")
    wait(0.5)
    click()
    check(#MOCK.whispers + ns.Outbox.Pending() == sent + 2, "a second later: the next whisper")
    wait(3)
    check(#MOCK.whispers == sent + 2, "both sent")
    slash("guild handsfree")

    -- Move and jump keys (bound keys, not letters) count as clicks; the key
    -- still reaches the game.
    slash("guild handsfree")
    check(TALODDB.guildHandsFreeKeys == true and G.HandsFreeKeys().W and G.HandsFreeKeys().SPACE, "move keys read")
    wait(5)   -- before Alpha's delayed invite is ready (10 s after the whisper), after the /who's wait
    local whos = #MOCK.whoQueries
    MOCK.KeyDown("E")
    check(#MOCK.whoQueries == whos, "a key not bound to moving: nothing")
    MOCK.KeyDown("SPACE")
    check(#MOCK.whoQueries == whos + 1, "Space: the /who")
    check(MOCK.keysEaten == 0, "keys handed on to the game")
    MOCK.bindings.MOVEFORWARD = { "E" }
    MOCK.FireEvent("UPDATE_BINDINGS")
    wait(6)
    MOCK.KeyDown("E")
    local last = G.HandsFreePresses()[#G.HandsFreePresses()]
    check(last.button == "E" and last.result == "invite Alpha", "rebound key follows the binding (red row first): " .. tostring(last.result))
    resetOutput()
    slash("guild handsfree why")
    check(printed("key E: invite Alpha"), "why lists keys")
    TALODDB.guildHandsFreeKeys = false
    wait(6)
    local n = #G.HandsFreePresses()
    MOCK.KeyDown("E")
    check(#G.HandsFreePresses() == n, "keys off: nothing")
    TALODDB.guildHandsFreeKeys = true
    slash("guild handsfree")

    -- The toggle in the Recruit tab and the mini window.
    TALODDB.guildMiniShown = true
    ns.GuildUI.Show("recruit")
    ns.Refresh()
    local v = ns.GuildUI.views and ns.GuildUI.views.recruit
    check(v and v.handsFree and ns.GuildUI.mini and ns.GuildUI.mini.handsFree, "toggles built")
    v.handsFree:Fire("OnClick", "LeftButton")
    check(TALODDB.guildHandsFree == true, "Recruit tab toggle")
    ns.GuildUI.mini.handsFree:Fire("OnClick", "LeftButton")
    check(TALODDB.guildHandsFree == false, "mini window toggle")
end

-- A /who the game drops from a world click raises nothing: no answer comes.
-- The /who button's wait is given back at once, and after two in a row
-- world clicks leave the /who to the button; keys and the button still work.
scenarios.guild_hands_free_who_dropped = function()
    local ns = setup()
    local G = ns.Guild
    slash("guild handsfree")
    local realSend = C_FriendList.SendWho
    local dropped = 0
    C_FriendList.SendWho = function() dropped = dropped + 1 end   -- returns, never answers
    MOCK.MouseDown("LeftButton")
    check(dropped == 1 and G.WhoWait() > 0, "sent, the button waits")
    wait(4.5)
    check(G.WhoWait() == 0, "no answer: the button is free again")
    check(G.WhoStatus():find("no answer"), "status says so: " .. tostring(G.WhoStatus()))
    resetOutput()
    MOCK.MouseDown("LeftButton")
    wait(4.5)
    check(dropped == 2 and printed("does not answer a /who sent from world clicks"), "two in a row: told")
    MOCK.MouseDown("LeftButton")
    check(dropped == 2, "world clicks leave the /who alone")
    check(G.Who() and dropped == 3, "the /who button still searches")
    C_FriendList.SendWho = realSend
    wait(5.5)
    MOCK.KeyDown("W")
    check(#MOCK.whoQueries == 1, "a move key still runs it")
    MOCK.whoResults = {}
    MOCK.FireEvent("WHO_LIST_UPDATE")
    wait(5)
    check(G.WhoWait() == 0 and not G.WhoStatus():find("no answer"), "answered: no miss counted")
end

-- Set recruit key: the next key you press becomes a click binding on the
-- step button (saved); Escape cancels, a lone modifier waits, the old key
-- goes, combat refuses. The bound key then does one step.
scenarios.guild_recruit_key = function()
    local ns = setup()
    local G = ns.Guild
    check(G.StepKey() == nil, "no key yet")
    slash("guild key")
    MOCK.KeyDown("LSHIFT")
    check(G.StepKey() == nil, "a lone modifier waits")
    MOCK.KeyDown("F6")
    check(G.StepKey() == "F6" and MOCK.savedBindings == 1, "F6 set and saved: " .. tostring(G.StepKey()))
    check(GetBindingAction("F6") == "CLICK TALODRecruitStep:LeftButton", "a click binding on the step button")
    slash("guild key")
    MOCK.KeyDown("F7")
    check(G.StepKey() == "F7" and GetBindingAction("F6") == "", "the old key goes")
    slash("guild key")
    MOCK.KeyDown("ESCAPE")
    check(G.StepKey() == "F7", "Escape: unchanged")
    MOCK.KeyDown("F8")
    check(G.StepKey() == "F7", "after Escape, keys are not taken")
    resetOutput()
    MOCK.lockdown = true
    slash("guild key")
    check(printed("out of combat"), "refused in combat")
    MOCK.lockdown = false
    -- What the key does: one step.
    _G["TALODRecruitStep"]:Click()
    check(#MOCK.whoQueries == 1, "the key's click: one step (a /who)")
end

scenarios.guild_roster_log = function()
    local ns = setup(nil, { guild = { roster = {
        { name = "Alpha", rank = 0, level = 60, classFile = "WARRIOR", online = true },
        { name = "Bravo", rank = 3, level = 30, classFile = "MAGE", offline = { 0, 0, 2, 0 } },
        { name = "Charlie", rank = 3, level = 20, classFile = "PRIEST", offline = { 0, 2, 5, 0 } },
    } } })
    local G = ns.Guild
    readRoster()
    local g = data()
    check(g and g.baseline and #g.log == 0, "first read is the baseline, no events")
    check(g.members["Alpha-Mockrealm"].before == true and g.members["Bravo-Mockrealm"].rankName == "Member", "members read")
    check(names(G.Roster("inactive")) == "Charlie-Mockrealm", "65 days offline is inactive: " .. names(G.Roster("inactive")))
    check(names(G.Roster("online")) == "Alpha-Mockrealm", "online filter")
    check(math.floor(G.DaysOffline(g.members["Bravo-Mockrealm"]) + 0.5) == 2, "days offline")

    -- An invited recruit joins.
    g.recruits["Delta-Mockrealm"] = { status = "invited", invited = MOCK.now, t = MOCK.now }
    table.insert(MOCK.guild.roster, { name = "Delta", rank = 4, level = 10, classFile = "ROGUE", online = true })
    readRoster()
    local e = g.log[#g.log]
    check(e.k == "join" and e.n == "Delta-Mockrealm" and e.to == "Initiate", "join logged")
    check(g.recruits["Delta-Mockrealm"].status == "joined", "recruit joined")
    check(not g.members["Delta-Mockrealm"].before, "new member's date is real")

    -- Promotion, then the system message names who did it.
    MOCK.guild.roster[2].rank = 2
    readRoster()
    e = g.log[#g.log]
    check(e.k == "promote" and e.from == "Member" and e.to == "Veteran" and e.by == nil, "promotion logged")
    MOCK.FireEvent("CHAT_MSG_SYSTEM", "Alpha has promoted Bravo to Veteran.")
    check(e.by == "Alpha-Mockrealm", "by added from the message: " .. tostring(e.by))
    check(ns.GuildUI.LogText(e):find("Bravo") and ns.GuildUI.LogText(e):find("by Alpha"), "log text")

    -- Missing once is not "left"; a later read a minute on is.
    table.remove(MOCK.guild.roster, 3)
    readRoster()
    check(g.members["Charlie-Mockrealm"] and g.members["Charlie-Mockrealm"].missing, "missing once: kept")
    check(g.log[#g.log].k ~= "leave", "not logged yet")
    table.insert(MOCK.guild.roster, { name = "Charlie", rank = 3, level = 20, classFile = "PRIEST" })
    readRoster()
    check(g.members["Charlie-Mockrealm"].missing == nil, "back: not missing")
    table.remove(MOCK.guild.roster, 4)
    readRoster()
    MOCK.now = MOCK.now + 61
    readRoster()
    e = g.log[#g.log]
    check(e.k == "leave" and e.n == "Charlie-Mockrealm" and g.members["Charlie-Mockrealm"] == nil, "left after confirmation")

    -- Kicked, with the message first.
    MOCK.FireEvent("CHAT_MSG_SYSTEM", "Delta has been kicked out of the guild by Alpha.")
    table.remove(MOCK.guild.roster, 3)
    readRoster()
    MOCK.now = MOCK.now + 61
    readRoster()
    e = g.log[#g.log]
    check(e.k == "kick" and e.by == "Alpha-Mockrealm", "kick with by: " .. tostring(e.k) .. " " .. tostring(e.by))

    -- An empty or broken read changes nothing.
    local n = #g.log
    local saved = MOCK.guild.roster
    MOCK.guild.roster = {}
    readRoster()
    MOCK.now = MOCK.now + 120
    readRoster()
    check(#g.log == n and g.members["Alpha-Mockrealm"], "empty roster read ignored")
    MOCK.guild.roster = { { name = "Alpha", rank = 0, level = 60, online = true }, { rank = 3 } }
    readRoster()
    MOCK.now = MOCK.now + 120
    readRoster()
    check(#g.log == n and g.members["Bravo-Mockrealm"], "incomplete roster read ignored")
    MOCK.guild.roster = saved

    -- Leaving the guild: nothing is read or logged.
    MOCK.guild = nil
    readRoster()
    check(#g.log == n, "no guild: nothing")
end

scenarios.guild_promotions = function()
    local ns = setup(nil, { guild = { roster = {
        { name = "Alpha", rank = 0, level = 60, online = true },
        { name = "Vet", rank = 2, level = 50, online = true },
        { name = "Mem1", rank = 3, level = 30, online = true },
        { name = "Mem2", rank = 3, level = 10, online = true },
        { name = "Mem3", rank = 3, level = 40 },
        { name = "Ini", rank = 4, level = 5, offline = { 0, 0, 20, 0 } },
    } } })
    local G = ns.Guild
    readRoster()
    local targets = G.PromotableRanks()
    check(#targets == 2 and targets[1] == 2 and targets[2] == 3, "officer can promote into Veteran and Member")
    check(#G.PromotionCandidates() == 0, "rules start off")

    local rule = G.Rule(2)
    rule.on, rule.level, rule.days, rule.active = true, 20, 0, 7
    check(names(G.PromotionCandidates()) == "Mem1-Mockrealm", "level and last online known: " .. names(G.PromotionCandidates()))
    rule.days = 14
    check(#G.PromotionCandidates() == 0, "days in guild not known yet")
    check(G.RuleCheck(data().members["Mem1-Mockrealm"], rule) == "days unknown", "says why")
    rule.days = 0
    local r3 = G.Rule(3)
    r3.on, r3.level, r3.days, r3.active = true, 1, 0, 7
    check(#G.PromotionCandidates() == 1, "inactive initiate not listed")
    r3.active = 30
    check(names(G.PromotionCandidates()) == "Mem1-Mockrealm,Ini-Mockrealm", "both rules: " .. names(G.PromotionCandidates()))

    check(G.Promote("Mem1-Mockrealm") == true and MOCK.promoted[1] == "Mem1", "one click promotes one member")
    resetOutput()
    check(G.Promote("Vet-Mockrealm") == false and printed("rank below yours"), "not into your own rank")
    MOCK.guild.can.promote = false
    check(G.Promote("Ini-Mockrealm") == false and #MOCK.promoted == 1, "no permission: nothing")
    wait(60)
    check(#MOCK.promoted == 1, "nothing promoted by the tick")
end

scenarios.guild_name_scripts = function()
    local ns = setup(nil, { guild = { roster = { { name = "Alpha", rank = 0, level = 60, classFile = "WARRIOR", online = true } } } })
    local G = ns.Guild
    local function set(t) local out = {} for k in pairs(t) do out[#out + 1] = k end table.sort(out) return table.concat(out, ",") end
    check(set(G.NameScripts("Zoë Brontë")) == "latin", "accented Latin is Latin")
    check(set(G.NameScripts("Иван")) == "cyrillic", "Cyrillic")
    check(set(G.NameScripts("Λέων")) == "greek", "Greek")
    check(set(G.NameScripts("李雷")) == "han", "Han")
    check(set(G.NameScripts("さくら")) == "kana", "kana")
    check(set(G.NameScripts("山田さくら")) == "han,kana", "Japanese: Han + kana")
    check(set(G.NameScripts("민수")) == "hangul", "Hangul")
    check(set(G.NameScripts("สมชาย")) == "thai", "Thai")
    check(set(G.NameScripts("Ivan Иванов")) == "cyrillic,latin", "mixed name")
    check(set(G.NameScripts("Bad\200name")) == "latin,other", "broken UTF-8 is other")
    check(G.ScriptHidden("Иван-Иванград") == false, "nothing hidden by default")

    local list = { { "Zoë", "Z" }, { "Иван", "I" }, { "민수", "M" }, { "李雷", "L" }, { "Λέων", "G" } }
    for i, p in ipairs(list) do plateAdd("nameplate" .. i, MOCK.Friend({ name = p[1], guid = "Player-1-" .. p[2], level = 20 })) end
    wait(5)
    check(#G.Candidates() == 5, "all five listed: " .. names(G.Candidates()))

    -- The Recruit tab's alphabet card.
    slash("guild")
    ns.GuildUI.Show("recruit")
    local rv = ns.GuildUI.views.recruit
    check(#rv.scriptChips == #G.SCRIPTS and rv.abc.sub:GetText():find("Every alphabet"), "alphabet card")
    local chips = {}
    for _, chip in ipairs(rv.scriptChips) do chips[chip.script] = chip end
    chips.cyrillic:Fire("OnClick", "LeftButton")
    check(TALODDB.guildRecruitHideScript.cyrillic == true and #G.Candidates() == 4, "Cyrillic hidden: " .. names(G.Candidates()))
    check(rv.abc.sub:GetText():find("1 player hidden"), "count shown: " .. tostring(rv.abc.sub:GetText()))
    for _, id in ipairs({ "greek", "han", "kana", "hangul", "thai", "arabic", "hebrew", "other" }) do chips[id]:Fire("OnClick", "LeftButton") end
    check(names(G.Candidates()) == "Zoë", "Latin only: " .. names(G.Candidates()))
    check(rv.list.all[1].full == "Zoë-Mockrealm" and #rv.list.all == 1, "list redrawn")
    -- The realm is not part of the check: a Latin name on a Cyrillic realm stays.
    check(G.ScriptHidden("Zoë-Гордунни") == false, "realm ignored")
    chips.latin:Fire("OnClick", "LeftButton")
    check(#G.Candidates() == 0, "Latin hidden too: nobody")
    for _, chip in ipairs(rv.scriptChips) do chip:Fire("OnClick", "LeftButton") end
    check(next(TALODDB.guildRecruitHideScript) == nil and #G.Candidates() == 5, "every chip again: all alphabets")
end

scenarios.guild_window = function()
    Minimap = CreateFrame("Frame", "Minimap", UIParent)
    Minimap._cx, Minimap._cy = 1000, 700
    local ns = setup(nil, { guild = { roster = {
        { name = "Alpha", rank = 0, level = 60, classFile = "WARRIOR", online = true },
        { name = "Bravo", rank = 3, level = 30, classFile = "MAGE", offline = { 0, 1, 2, 0 }, note = "alt of Alpha" },
    } } })
    local G, UI = ns.Guild, ns.GuildUI
    plateAdd("nameplate1", MOCK.Friend({ name = "Newbie", guid = "Player-1-N", level = 12 }))
    wait(5)
    slash("guild")
    check(TALODGuildWindow and TALODGuildWindow:IsShown(), "window open")
    check(MOCK.rosterRequests >= 1, "opening asks for the roster")
    readRoster()
    for _, view in ipairs({ "invited", "roster", "promote", "log", "recruit" }) do
        UI.Show(view)
        check(UI.state.view == view, "view " .. view)
    end
    check(UI.views.recruit.list.all[1].full == "Newbie-Mockrealm", "candidate row")
    check(ns.Options.TabIndex("Guild") ~= nil, "settings tab")
    check(UI.views.roster.list.all[2].text:find("alt of Alpha"), "roster row with note")

    -- Recruit filters: level buttons, class chips.
    local rv = UI.views.recruit
    plateAdd("nameplate2", MOCK.Friend({ name = "Warry", guid = "Player-1-W", class = "WARRIOR", level = 40 }))
    plateAdd("nameplate3", MOCK.Friend({ name = "Mystery", guid = "Player-1-M", class = "MAGE", level = 20 }))
    wait(5)
    check(#G.Candidates() == 3, "three recruits: " .. names(G.Candidates()))
    local chips = {}
    for _, chip in ipairs(rv.classChips) do chips[chip.classFile] = chip end
    -- Forever has Alliance shamans: every class gets a chip.
    check(chips.PALADIN and chips.SHAMAN and #rv.classChips == 9, "all nine classes")
    chips.WARRIOR:Fire("OnClick", "LeftButton")
    check(names(G.Candidates()) == "Mystery,Newbie" or names(G.Candidates()) == "Newbie,Mystery", "warrior hidden: " .. names(G.Candidates()))
    check(G.ClassOK(nil) == false, "unknown class hidden while a class is hidden")
    chips.WARRIOR:Fire("OnClick", "LeftButton")
    chips.PRIEST:Fire("OnClick", "RightButton")
    check(names(G.Candidates()) == "Newbie", "only priests")
    check(TALODDB.guildRecruitHideClass.SHAMAN == true, "only priests hides shamans too")
    chips.PRIEST:Fire("OnClick", "RightButton")
    check(next(TALODDB.guildRecruitHideClass) == nil and #G.Candidates() == 3, "right-click again: all")
    check(G.ClassOK(nil) == true, "unknown class shown with no class hidden")
    MOCK.shift = true
    rv.minLevel:Fire("OnClick", "LeftButton")
    rv.minLevel:Fire("OnClick", "LeftButton")
    MOCK.shift = false
    check(TALODDB.guildRecruitMinLevel == 21, "min level 21")
    check(names(G.Candidates()) == "Warry", "level filter: " .. names(G.Candidates()))
    for _ = 1, 25 do rv.maxLevel:Fire("OnClick", "RightButton") end
    check(TALODDB.guildRecruitMaxLevel == 35 and #G.Candidates() == 0, "max 35")
    check(rv.list.all[1].text:find("level / class / name alphabet filter"), "filtered empty text")
    MOCK.shift = true
    for _ = 1, 3 do rv.maxLevel:Fire("OnClick", "RightButton") end
    MOCK.shift = false
    check(TALODDB.guildRecruitMaxLevel == 5 and TALODDB.guildRecruitMinLevel == 5, "min follows max down")
    TALODDB.guildRecruitMinLevel, TALODDB.guildRecruitMaxLevel = 1, 60
    plateRemove("nameplate2") plateRemove("nameplate3")

    -- Message editor: new, edit, delete; the shown message is the one sent.
    local v = UI.views.recruit
    v.new:Fire("OnClick", "LeftButton")
    check(#G.Messages() == 3 and G.MessageIndex() == 3, "new message selected")
    v.box:SetText("Yo {name}, join <{guild}>!\n")
    v.box:Fire("OnTextChanged", true)
    check(G.Messages()[3] == "Yo {name}, join <{guild}>! ", "edited: " .. G.Messages()[3])
    check(G.FormatMessage(G.CurrentMessage(), { name = "X" }) == "Yo X, join <Brave Souls>!", "formatted")
    v.prev:Fire("OnClick", "LeftButton")
    check(G.MessageIndex() == 2 and v.box:GetText() == G.Messages()[2], "previous message shown")
    for _ = 1, 3 do v.del:Fire("OnClick", "LeftButton") end
    check(#G.Messages() == 0 and G.CurrentMessage() == nil, "all deleted")
    G.Invite("Newbie-Mockrealm")
    check(#MOCK.whispers == 0 and MOCK.guildInvites[1] == "Newbie", "no message: invite only")

    -- Deleted messages stay deleted across a reload of the defaults.
    ns.CopyDefaults(TALODDB, ns.defaults)
    check(#G.Messages() == 0, "defaults do not bring messages back")

    -- Permissions and no guild: views explain instead of listing.
    MOCK.guild.can.invite, MOCK.guild.can.promote = false, false
    UI.Show("recruit")
    check(v.note:IsShown() and not v.list:IsShown(), "recruit: rank note")
    UI.Show("promote")
    check(UI.views.promote.note:IsShown(), "promotions: rank note")
    MOCK.guild = nil
    for _, view in ipairs({ "recruit", "invited", "roster", "promote", "log" }) do UI.Show(view) end
    check(UI.views.log.note:GetText():find("not in a guild"), "no guild note")

    -- Minimap: Shift + right-click toggles the window.
    TALODGuildWindow:Hide()
    MOCK.shift = true
    TALODMinimapButton:Fire("OnClick", "RightButton")
    MOCK.shift = false
    check(TALODGuildWindow:IsShown(), "minimap shift right-click")
end

scenarios.guild_forever_secrets = function()
    local ns = setup(16001, { secrets = true })
    MOCK.secretMode = true
    local G = ns.Guild
    plateAdd("nameplate1", MOCK.Friend({ name = "Hidden", guid = "Player-1-S", guild = "", secret = { guild = true } }))
    plateAdd("nameplate2", MOCK.Friend({ name = "Nofac", guid = "Player-1-Q", secret = { faction = true } }))
    plateAdd("nameplate3", MOCK.Friend({ name = "Plain", guid = "Player-1-P" }))
    wait(6)
    check(names(G.Candidates()) == "Plain", "secret guild / faction never listed: " .. names(G.Candidates()))
    G.Invite("Plain-Mockrealm")
    wait(10.5)
    G.Invite("Plain-Mockrealm")  -- second click: the invite
    local r = data().recruits["Plain-Mockrealm"]
    MOCK.FireEvent("CHAT_MSG_SYSTEM", MOCK.Secret("Plain declines your guild invitation."))
    check(r.status == "invited", "secret message ignored")
    MOCK.FireEvent("CHAT_MSG_WHISPER", MOCK.Secret("hi"), MOCK.Secret("Plain"))
    check(r.replied == nil, "secret sender ignored")
end

scenarios.guild_replies = function()
    local ns = setup()
    local G, UI = ns.Guild, ns.GuildUI
    plateAdd("nameplate1", MOCK.Friend({ name = "Newbie", guid = "Player-1-N", level = 12 }))
    wait(5)
    G.Invite("Newbie-Mockrealm")
    local r = data().recruits["Newbie-Mockrealm"]
    local sent = MOCK.whispers[1].text

    -- The game echoes your whisper; it opens the conversation and stays out of chat.
    MOCK.FireEvent("CHAT_MSG_WHISPER_INFORM", sent, "Newbie-Mockrealm")
    check(r.chat and #r.chat == 1 and r.chat[1].me and r.unread == nil, "your whisper recorded")
    check(MOCK.ChatHidden("CHAT_MSG_WHISPER_INFORM", sent, "Newbie-Mockrealm"), "your invite whisper hidden from chat")
    check(MOCK.ChatHidden("CHAT_MSG_SYSTEM", "You have invited Newbie to join your guild."), "invite line hidden")
    check(not MOCK.ChatHidden("CHAT_MSG_WHISPER", "hey", "Stranger-Mockrealm"), "other whispers untouched")
    check(not MOCK.ChatHidden("CHAT_MSG_SYSTEM", "Stranger declines your guild invitation."), "other system lines untouched")
    check(not MOCK.ChatHidden("CHAT_MSG_SYSTEM", "Alpha has joined the guild."), "guild news untouched")

    -- Their reply: unread, notice shown while the window is closed.
    MOCK.FireEvent("CHAT_MSG_WHISPER", "sure, thanks!", "Newbie-Mockrealm")
    check(r.unread == 1 and r.replied and #r.chat == 2, "reply recorded as unread")
    check(MOCK.ChatHidden("CHAT_MSG_WHISPER", "sure, thanks!", "Newbie-Mockrealm"), "reply kept out of chat")
    check(G.Unread() == 1 and UI.notice and UI.notice:IsShown() and UI.notice.label:GetText():find("1"), "notice shown")

    -- Reading it: the conversation opens, read, notice gone.
    UI.notice:Fire("OnClick", "LeftButton")
    check(UI.state.view == "replies" and UI.state.chat == "Newbie-Mockrealm", "notice opens the conversation")
    check(r.unread == nil and not UI.notice:IsShown(), "read, notice hidden")
    check(UI.views.replies.list.all[1].full == "Newbie-Mockrealm", "conversation listed")
    check(UI.ChatLine("Newbie-Mockrealm", r, r.chat[2]):find("sure, thanks!"), "chat line")

    -- Answer from the box (Enter = one whisper).
    local v = UI.views.replies
    v.box:SetText("welcome aboard!")
    v.box:Fire("OnEnterPressed")
    local w = MOCK.whispers[#MOCK.whispers]
    check(w.target == "Newbie" and w.text == "welcome aboard!" and v.box:GetText() == "", "reply sent")
    -- A second Enter with the same text (client lag) is not sent again; later it is.
    local sentCount = #MOCK.whispers
    v.box:SetText("welcome aboard!")
    v.box:Fire("OnEnterPressed")
    check(#MOCK.whispers == sentCount and v.box:GetText() == "" and T.printed("not sent twice"), "double Enter: one whisper")
    v.box:SetText("and have fun")
    v.box:Fire("OnEnterPressed")
    check(#MOCK.whispers == sentCount + 1, "a different line goes out")
    MOCK.Tick(10.5)
    check(G.Reply("Newbie-Mockrealm", "welcome aboard!") and #MOCK.whispers == sentCount + 2, "the same line later goes out")

    -- Once you write back, the conversation shows in chat: your line and theirs.
    check(not MOCK.ChatHidden("CHAT_MSG_WHISPER_INFORM", "welcome aboard!", "Newbie-Mockrealm"), "your typed reply shows in chat")
    MOCK.FireEvent("CHAT_MSG_WHISPER_INFORM", "welcome aboard!", "Newbie-Mockrealm")
    check(not MOCK.ChatHidden("CHAT_MSG_WHISPER", "thanks!", "Newbie-Mockrealm"), "their answers show once you talk")
    check(MOCK.ChatHidden("CHAT_MSG_WHISPER_INFORM", sent, "Newbie-Mockrealm"), "the opening whisper stays hidden")
    check(#r.chat == 3 and r.chat[3].text == "welcome aboard!", "typed reply recorded")

    -- The same short reply twice is two lines (only the opener's echo is skipped).
    MOCK.FireEvent("CHAT_MSG_WHISPER_INFORM", "ok", "Newbie-Mockrealm")
    MOCK.FireEvent("CHAT_MSG_WHISPER_INFORM", "ok", "Newbie-Mockrealm")
    check(#r.chat == 5 and r.chat[5].text == "ok", "same reply twice kept twice")
    -- Names without the realm (or another form) still find the one recruit.
    MOCK.FireEvent("CHAT_MSG_WHISPER_INFORM", "see you in guild chat", "Newbie")
    MOCK.FireEvent("CHAT_MSG_WHISPER", "will do", "newbie")
    check(#r.chat == 7 and r.chat[7].text == "will do" and not r.chat[7].me, "name without realm matched")
    -- A line the game hides is kept as a note, never dropped.
    MOCK.FireEvent("CHAT_MSG_WHISPER", MOCK.Secret("secret words"), "Newbie-Mockrealm")
    check(#r.chat == 8 and r.chat[8].text:find("hidden by the game"), "hidden text noted")
    -- A full list still redraws on every new line, even within the same second.
    UI.Show("replies")
    for i = 1, 70 do MOCK.FireEvent("CHAT_MSG_WHISPER", "line " .. i, "Newbie-Mockrealm") end
    UI.Refresh()
    local shownKey = v.shown
    MOCK.FireEvent("CHAT_MSG_WHISPER_INFORM", "last one", "Newbie-Mockrealm")
    check(#r.chat == 60 and v.shown ~= shownKey and r.chat[60].text == "last one", "full list redrawn")

    -- The game refuses the invite that follows the whisper: the recruit is
    -- marked "not invited", and one click invites without a second whisper.
    plateAdd("nameplate2", MOCK.Friend({ name = "Laggy", guid = "Player-1-L", level = 14 }))
    wait(5)
    local realInvite = C_GuildInfo.Invite
    C_GuildInfo.Invite = function() error("busy") end
    local before, beforeInv = #MOCK.whispers, #MOCK.guildInvites
    resetOutput()
    check(G.Invite("Laggy-Mockrealm") and #MOCK.whispers == before + 1, "whisper out")
    wait(10.5)
    check(not G.Invite("Laggy-Mockrealm"), "second click: refused")
    local laggy = data().recruits["Laggy-Mockrealm"]
    check(laggy.status == "uninvited" and printed("did not accept the invite for Laggy"), "invite refused: " .. tostring(laggy.status))
    C_GuildInfo.Invite = realInvite
    check(G.Invite("Laggy-Mockrealm", nil, laggy.unsent == nil), "second click")
    check(#MOCK.whispers == before + 1 and #MOCK.guildInvites == beforeInv + 1 and laggy.status == "invited",
        "second click: invite only")

    -- Invite again: the invite only, no whisper (you are already talking).
    MOCK.now = MOCK.now + 61
    local whispers, invites = #MOCK.whispers, #MOCK.guildInvites
    v.invite:Fire("OnClick", "LeftButton")
    check(#MOCK.guildInvites == invites + 1 and MOCK.guildInvites[#MOCK.guildInvites] == "Newbie", "invited again")
    check(#MOCK.whispers == whispers, "no whisper with Invite again")

    -- Setting off: chat shows everything again.
    TALODDB.guildHideChat = false
    check(not MOCK.ChatHidden("CHAT_MSG_WHISPER", "ok", "Newbie-Mockrealm"), "hide off")
    TALODDB.guildHideChat = true

    -- Notice setting off; new reply while the tab is closed.
    TALODGuildWindow:Hide()
    TALODDB.guildReplyNotice = false
    MOCK.FireEvent("CHAT_MSG_WHISPER", "one more thing", "Newbie-Mockrealm")
    check(r.unread == 1 and not UI.notice:IsShown(), "no notice when off")

    -- A whisper from someone never invited is not kept.
    MOCK.FireEvent("CHAT_MSG_WHISPER", "wts boots", "Seller-Mockrealm")
    check(#G.Conversations() == 1, "only invited players")
    G.ClearChat("Newbie-Mockrealm")
    check(#G.Conversations() == 0 and G.Unread() == 0, "conversation deleted")
end

scenarios.guild_report = function()
    local ns = setup()
    local G, UI = ns.Guild, ns.GuildUI
    plateAdd("nameplate1", MOCK.Friend({ name = "Rude", guid = "Player-1-R", level = 12 }))
    wait(5)
    G.Invite("Rude-Mockrealm")
    local r = data().recruits["Rude-Mockrealm"]

    -- No whisper from them yet: nothing to point the report at.
    check(G.ReportRoute("Rude-Mockrealm") == nil and not G.Report("Rude-Mockrealm") and #MOCK.reports == 0, "nothing to report yet")

    -- Their whisper carries the chat line ID (arg 11) and GUID (arg 12).
    MOCK.FireEvent("CHAT_MSG_WHISPER", "get lost", "Rude-Mockrealm", "", "", "", "", 0, 0, "", 0, 4711, "Player-1-R")
    check(r.guid == "Player-1-R", "GUID kept")
    UI.Show("replies")
    local v = UI.views.replies
    check(v.report:IsShown(), "report button shown")
    v.report:Fire("OnClick", "LeftButton")
    local rep = MOCK.reports[#MOCK.reports]
    check(#MOCK.reports == 1 and rep.kind == Enum.ReportType.Chat and rep.lineID == 4711 and rep.name == "Rude",
        "report window opened on their last whisper")

    -- Secret line ID / GUID: unknown, the last good ones stay.
    MOCK.FireEvent("CHAT_MSG_WHISPER", "again", "Rude-Mockrealm", "", "", "", "", 0, 0, "", 0, MOCK.Secret(5000), MOCK.Secret("Player-1-X"))
    check(select(2, G.ReportRoute("Rude-Mockrealm")) == 4711 and r.guid == "Player-1-R", "secret values ignored")

    -- After a reload line IDs are gone: the report names the player by GUID.
    local saved = r.guid
    G = setup().Guild
    check(data().recruits["Rude-Mockrealm"].guid == saved, "GUID saved")
    local kind, arg = G.ReportRoute("Rude-Mockrealm")
    check(kind == "player" and arg == "Player-1-R", "report by GUID after reload")

    -- A client without the report window says so instead of failing.
    local realFrame = ReportFrame
    ReportFrame = nil
    resetOutput()
    check(not G.Report("Rude-Mockrealm") and printed("no report window"), "no report window")
    ReportFrame = realFrame
end

-- "Said no" in the Replies tab: the delayed invite never comes back for its
-- click, they are not offered again, and Undo puts them back.
scenarios.guild_said_no = function()
    local ns = setup()
    local G, UI = ns.Guild, ns.GuildUI
    plateAdd("nameplate1", MOCK.Friend({ name = "Nope", guid = "Player-1-P", level = 12 }))
    wait(5)
    local full = "Nope-Mockrealm"
    check(G.Invite(full) and #MOCK.whispers == 1, "opener sent")
    local r = data().recruits[full]
    MOCK.FireEvent("CHAT_MSG_WHISPER_INFORM", MOCK.whispers[1].text, full)
    MOCK.FireEvent("CHAT_MSG_WHISPER", "no thanks, not interested", full)

    UI.Show("replies")
    local v = UI.views.replies
    check(UI.state.chat == full and v.no:IsShown() and v.no.label:GetText() == "Said no", "Said no button shown")
    v.no:Fire("OnClick", "LeftButton")
    check(r.status == "skipped" and r.saidNo and r.noFrom == "inviting", "marked: " .. tostring(r.status))
    check(UI.StatusOf(r)[1] == "said no" and v.no.label:GetText() == "Undo no" and not v.invite:IsShown(), "shown as said no")

    -- The 10 s pass: they never come back for the invite click.
    wait(11)
    check(#G.Candidates() == 0 and G.InvitesReady() == 0 and not G.InviteReady(full), "not back on the list")
    check(G.Invite(full) == false and #MOCK.guildInvites == 0, "no invite goes")
    MOCK.now = MOCK.now + 30 * 86400
    wait(1)
    check(#G.Candidates() == 0, "never offered again")
    check(#G.Conversations() == 1, "conversation kept")

    -- Undo: back to "not invited" (its wait is gone); a click invites without a second whisper.
    v.no:Fire("OnClick", "LeftButton")
    check(r.status == "uninvited" and r.saidNo == nil and v.invite:IsShown(), "undone: " .. tostring(r.status))
    check(G.Invite(full) and #MOCK.guildInvites == 1 and #MOCK.whispers == 1, "invite only after undo")
end

scenarios.guild_full_names = function()
    local ns = setup(nil, { guild = { roster = {
        { name = "Alpha Prime", rank = 0, level = 60, online = true },
        { name = "Mira Stone", rank = 3, level = 30, online = true },
    } } })
    local G = ns.Guild
    readRoster()
    local g = data()
    check(g.members["Mira Stone-Mockrealm"] and g.members["Alpha Prime-Mockrealm"], "roster keeps first + last names")
    check(G.Short("Mira Stone-Mockrealm") == "Mira Stone" and G.Target("Mira Stone-Mockrealm") == "Mira Stone", "short and target")
    check(G.FullName("Tom Reed") == "Tom Reed-Mockrealm", "own realm added")
    check(G.FromFull("Tom Reed-Otherrealm") == "Tom Reed-Otherrealm" and G.Short("Tom Reed-Otherrealm") == "Tom Reed", "other realm")
    check(G.Target("Tom Reed-Otherrealm") == "Tom Reed", "Forever: whispers and invites go to First Surname, no realm")
    check(G.FullName("Tom Reed-Otherrealm") == "Tom Reed-Otherrealm", "known realm not added twice")

    -- Promotion message with two-word names on both sides and a two-word rank.
    MOCK.guild.ranks[2] = "Senior Member"
    MOCK.guild.roster[2].rank = 2
    readRoster()
    MOCK.FireEvent("CHAT_MSG_SYSTEM", "Alpha Prime has promoted Mira Stone to Senior Member.")
    local e = g.log[#g.log]
    check(e.n == "Mira Stone-Mockrealm" and e.by == "Alpha Prime-Mockrealm" and e.to == "Senior Member", "names split right")

    -- A recruit with a first and last name: whisper, {first}, invite, answers.
    plateAdd("nameplate1", MOCK.Friend({ name = "Rook Vale", guid = "Player-1-R", level = 20 }))
    wait(5)
    check(names(G.Candidates()) == "Rook Vale", "candidate: " .. names(G.Candidates()))
    TALODDB.guildMessages, TALODDB.guildMessageIndex = { "Hi {first}! Welcome, {name}." }, 1
    G.Invite("Rook Vale-Mockrealm")
    wait(10.5)
    G.Invite("Rook Vale-Mockrealm")  -- second click: the invite
    check(MOCK.whispers[1].target == "Rook Vale" and MOCK.whispers[1].text == "Hi Rook! Welcome, Rook Vale.", "message: " .. MOCK.whispers[1].text)
    check(MOCK.guildInvites[1] == "Rook Vale", "invite by full name")
    MOCK.FireEvent("CHAT_MSG_SYSTEM", "Rook Vale declines your guild invitation.")
    check(g.recruits["Rook Vale-Mockrealm"].status == "declined", "decline with a two-word name")
    MOCK.FireEvent("CHAT_MSG_WHISPER", "maybe later", "Rook Vale-Mockrealm")
    local rook = g.recruits["Rook Vale-Mockrealm"].chat
    check(#rook == 2 and rook[1].me and rook[1].text == "Hi Rook! Welcome, Rook Vale." and rook[2].text == "maybe later",
        "opening whisper kept at send, then the reply")

    slash("guild invite Tom Reed")
    wait(10.5)
    slash("guild invite Tom Reed")
    check(MOCK.guildInvites[2] == "Tom Reed", "typed two-word name")
end

scenarios.guild_recruiters = function()
    local ns = setup(nil, { guild = { roster = {
        { name = "Alpha", rank = 0, level = 60, online = true },
        { name = "Bob", rank = 3, level = 40, online = true },
        { name = "Cara", rank = 3, level = 40, online = true },
        { name = "Gus", rank = 4, level = 10, online = true },
    } } })
    local G, UI = ns.Guild, ns.GuildUI
    local function ev(k, a, b, days) return { k, a, b, nil, 0, 0, days, 0 } end
    MOCK.guildEvents = {
        ev("invite", "Alpha", "Bob", 10), ev("join", "Bob", nil, 10),
        ev("invite", "Alpha", "Dan", 9), ev("join", "Dan", nil, 9), ev("quit", "Dan", nil, 8),
        ev("invite", "Cara", "Eve", 5), ev("join", "Eve", nil, 5), ev("quit", "Eve", nil, 4),
        ev("invite", "Cara", "Eve", 3), ev("join", "Eve", nil, 3), ev("quit", "Eve", nil, 2),
        ev("invite", "Bob", "Gus", 6), ev("join", "Gus", nil, 6),
        ev("invite", "Alpha", "Fay", 1),
    }
    readRoster()
    slash("guild recruiters")
    check(MOCK.eventLogQueries >= 1, "opening the window asks for the guild log")
    MOCK.FireEvent("GUILD_EVENT_LOG_UPDATE")
    local g = data()
    check(#g.events == 14, "events kept: " .. #g.events)

    local by = {}
    for _, st in ipairs(G.Recruiters()) do by[st.by] = st end
    local a, c, b = by["Alpha-Mockrealm"], by["Cara-Mockrealm"], by["Bob-Mockrealm"]
    check(a.invitedCount == 3 and a.joined == 2 and a.here == 1 and a.left == 1 and a.quick == 1, "Alpha: invited 3, joined 2, 1 here, 1 quick quit")
    check(c.invitedCount == 1 and c.joined == 1 and c.here == 0 and c.left == 2 and c.quick == 2 and c.rejoins == 1,
        "Cara: one person joined twice, quit twice")
    check(b.here == 1, "Bob kept Gus")
    check(G.InvitedBy("Gus-Mockrealm") == "Bob-Mockrealm", "invited by")

    -- Reading the same log again, a day later, adds nothing.
    MOCK.FireEvent("GUILD_EVENT_LOG_UPDATE")
    MOCK.now = MOCK.now + 86400
    for _, e in ipairs(MOCK.guildEvents) do e[7] = e[7] + 1 end
    MOCK.FireEvent("GUILD_EVENT_LOG_UPDATE")
    check(#g.events == 14, "no duplicates: " .. #g.events)

    -- After the game's log drops old entries, the kept history still counts.
    MOCK.guildEvents = { ev("invite", "Alpha", "Hal", 0) }
    MOCK.FireEvent("GUILD_EVENT_LOG_UPDATE")
    by = {}
    for _, st in ipairs(G.Recruiters()) do by[st.by] = st end
    check(#g.events == 15 and by["Alpha-Mockrealm"].invitedCount == 4 and by["Alpha-Mockrealm"].joined == 2, "history kept")

    -- Your own invites count too, through the roster.
    G.Invite("Newbie-Mockrealm", { name = "Newbie", level = 5 })
    table.insert(MOCK.guild.roster, { name = "Newbie", rank = 4, level = 5, online = true })
    readRoster()
    by = {}
    for _, st in ipairs(G.Recruiters()) do by[st.by] = st end
    check(by["Tester-Mockrealm"] and by["Tester-Mockrealm"].joined == 1 and by["Tester-Mockrealm"].here == 1, "your invite credited")

    -- Promotion rule on recruits kept.
    local rule = G.Rule(2)
    rule.on, rule.level, rule.days, rule.active, rule.recruits = true, 1, 0, 7, 1
    check(names(G.PromotionCandidates()) == "Bob-Mockrealm", "only Bob kept a recruit: " .. names(G.PromotionCandidates()))
    rule.recruits = 2
    check(#G.PromotionCandidates() == 0, "nobody kept two")

    -- The tab and its tooltips.
    UI.Show("recruiters")
    local rows = UI.views.recruiters.list.all
    check(#rows >= 3, "recruiter rows")
    for _, row in ipairs(rows) do if row.tooltip then row.tooltip(TALODGuildWindow) end end
    check(UI.StayText({ joined = MOCK.now - 3 * 86400, left = MOCK.now - 2 * 86400, how = "quit" }):find("1 d"), "stay text")
    UI.Show("roster")
    for _, row in ipairs(UI.views.roster.list.all) do if row.tooltip then row.tooltip(TALODGuildWindow) end end
end

scenarios.guild_mini_window = function()
    local ns = setup()
    local G, UI = ns.Guild, ns.GuildUI
    check(TALODDB.guildMiniShown == false and TALODGuildMini == nil, "off by default, not even built")

    plateAdd("nameplate1", MOCK.Friend({ name = "Newbie", guid = "Player-1-N", level = 12 }))
    wait(5)
    -- Turned on from the Recruit tab.
    UI.Show("recruit")
    UI.views.recruit.miniToggle:Fire("OnClick", "LeftButton")
    check(TALODDB.guildMiniShown and TALODGuildMini and TALODGuildMini:IsShown(), "shown from the Recruit tab")
    check(UI.views.recruit.miniToggle.label:GetText():find("on"), "button says on")
    TALODGuildWindow:Hide()

    -- Stays on screen with the guild window closed, and keeps up with new players.
    plateAdd("nameplate2", MOCK.Friend({ name = "Second", guid = "Player-1-S", level = 30 }))
    wait(5)
    local rows = UI.mini.list.all
    check(#rows == 2 and TALODGuildMini:IsShown(), "both recruits listed: " .. #rows)
    check(UI.mini.title:GetText():find("2"), "count in the title")

    -- Same clicks on the window's own rows: left invites, right skips.
    local function rowFor(full)
        for _, r in ipairs(UI.mini.list.rows) do
            if r.item and r.item.full == full then return r end
        end
    end
    UI.mini.list._height = 200
    UI.mini.list:Draw()
    check(rowFor("Newbie-Mockrealm") and rowFor("Second-Mockrealm"), "rows drawn")
    rowFor("Newbie-Mockrealm"):Fire("OnClick", "LeftButton")
    check(#MOCK.whispers == 1 and #MOCK.guildInvites == 0 and not rowFor("Newbie-Mockrealm"), "left-click: whisper, off the list")
    wait(10.5)
    UI.mini.list:Draw()
    local ready = rowFor("Newbie-Mockrealm")
    check(ready and ready.item.tint == UI.TINT_READY and rowFor("Second-Mockrealm").item.tint == UI.TINT_NEW,
        "back in red; the other one gray")
    local order = UI.CandidateRows(true)
    check(order[1].full == "Second-Mockrealm" and order[2].full == "Newbie-Mockrealm",
        "red rows below the ones not messaged yet: " .. tostring(order[1].full))
    ready:Fire("OnClick", "LeftButton")
    check(MOCK.guildInvites[1] == "Newbie" and #MOCK.whispers == 1, "second left-click: the invite")
    check(UI.mini.delayed:IsShown(), "delayed toggle next to /who")
    rowFor("Second-Mockrealm"):Fire("OnClick", "RightButton")
    check(data().recruits["Second-Mockrealm"].status == "skipped", "right-click: skip")
    check(#UI.mini.list.all == 1 and UI.mini.list.all[1].full == nil, "empty text after both")

    -- The filters apply here too.
    plateAdd("nameplate3", MOCK.Friend({ name = "Third", guid = "Player-1-T", level = 50 }))
    wait(5)
    check(#UI.mini.list.all == 1 and UI.mini.list.all[1].full == "Third-Mockrealm", "third listed")
    TALODDB.guildRecruitMaxLevel = 40
    ns.Refresh()
    check(UI.mini.list.all[1].full == nil, "level filter applies")
    TALODDB.guildRecruitMaxLevel = 60

    -- /who from the mini window: one search per click.
    UI.mini.who:Fire("OnClick", "LeftButton")
    check(#MOCK.whoQueries == 1, "one /who")

    -- The X hides it and turns the setting off; /talod guild mini brings it back.
    UI.mini.close:Fire("OnClick", "LeftButton")
    check(TALODDB.guildMiniShown == false and not TALODGuildMini:IsShown(), "closed")
    slash("guild mini")
    check(TALODGuildMini:IsShown(), "slash shows it")

    -- Dragged somewhere, then a settings reset puts it back.
    TALODGuildMini:Fire("OnDragStop")
    check(type(TALODDB.guildMiniPos) == "table", "position saved")
    slash("reset")
    check(TALODDB.guildMiniPos == nil and TALODDB.guildMiniShown == false and not TALODGuildMini:IsShown(),
        "reset: back to off and default place")

    -- A rank without invite: a note instead of the list.
    TALODDB.guildMiniShown = true
    MOCK.guild.can.invite = false
    ns.Refresh()
    check(UI.mini.note:IsShown() and not UI.mini.list:IsShown(), "rank note")
end

-- WoW Forever as the saved data showed it (2026-10-05): UnitName gives the
-- surname where the realm goes ("Gandi", "Moros"); /who, the roster and the
-- game's messages write "Gandi Moros". One player must be one record.
scenarios.guild_forever_split_names = function()
    local now = os.time()
    local db = { guild = { guilds = { ["Brave Souls-Mockrealm"] = {
        members = {}, log = {}, rules = {}, ranks = {},
        recruits = {
            ["Gandi-Moros"] = { name = "Gandi", src = "plate", status = "invited", invited = now - 300, t = now - 300,
                invites = 1, by = "Aalina-Mockrealm", level = 20, classFile = "MAGE" },
            ["Gandi Moros-Mockrealm"] = { name = "Gandi Moros", src = "who", status = "declined", invited = now - 100,
                t = now - 90, invites = 1, by = "Aalina-Mockrealm", chat = { { t = now - 95, text = "no thanks" } } },
            ["Lyrah-Shadeleaf"] = { name = "Lyrah", src = "plate", status = "invited", invited = now - 50, t = now - 50,
                invites = 1, by = "Aalina-Mockrealm" },
        } } } } }
    MOCK.SetGuild({ roster = { { name = "Aalina Windsong", rank = 1, level = 30, online = true } } })
    MOCK.units.player = nil
    local ns
    do
        MOCK.iface = 16001
        TALODDB = db
        MOCK.units.player = { exists = true, guid = "Player-1-0001", name = "Aalina", realm = "Windsong", level = 30, faction = "Alliance" }
        ns = MOCK.LoadAddon(ADDON_DIR, ADDON_FILES, ADDON_NAME)
        MOCK.FireEvent("ADDON_LOADED", ADDON_NAME)
        MOCK.Tick(0.3)
    end
    MOCK.cvars.nameplateShowFriends = "1"
    local G = ns.Guild
    check(G.SplitNames(), "Forever names detected from your own name")
    check(G.Me() == "Aalina Windsong-Mockrealm", "your name in full: " .. tostring(G.Me()))

    -- The old double record is merged into one, the server's way.
    local g = G.Data()
    local r = g.recruits["Gandi Moros-Mockrealm"]
    check(g.recruits["Gandi-Moros"] == nil and r, "merged into the server's form")
    check(r.status == "declined" and r.invites == 2 and r.level == 20 and #r.chat == 1, "kept the later answer and both invites")
    check(r.by == "Aalina Windsong-Mockrealm", "your invites credited to your full name: " .. tostring(r.by))
    check(g.recruits["Lyrah Shadeleaf-Mockrealm"] and g.recruits["Lyrah Shadeleaf-Mockrealm"].name == "Lyrah Shadeleaf", "single record renamed")

    -- A nameplate and /who now give the same player one key.
    plateAdd("nameplate1", MOCK.Friend({ name = "Faladorian", realm = "Dawnsight", guid = "Player-1-F", level = 22 }))
    for _ = 1, 10 do MOCK.Tick(0.5) end
    local c = G.Candidates()
    check(#c == 1 and c[1].full == "Faladorian Dawnsight-Mockrealm", "plate name in full: " .. tostring(c[1] and c[1].full))
    G.Who()
    MOCK.whoResults = { { fullName = "Faladorian Dawnsight", fullGuildName = "", level = 22, filename = "PALADIN" } }
    MOCK.FireEvent("WHO_LIST_UPDATE")
    check(#G.Candidates() == 1, "/who finds the same player, not a second one: " .. #G.Candidates())

    -- One click: whisper and invite to "First Surname" (no realm); a second click does nothing.
    G.Invite("Faladorian Dawnsight-Mockrealm")
    wait(10.5)
    G.Invite("Faladorian Dawnsight-Mockrealm")  -- second click: the invite
    check(MOCK.guildInvites[1] == "Faladorian Dawnsight" and MOCK.whispers[1].target == "Faladorian Dawnsight", "sent to First Surname")
    check(#G.Candidates() == 0, "off the list")
    G.Invite("Faladorian Dawnsight-Mockrealm")
    check(#MOCK.guildInvites == 1, "no second invite")

    -- The game's answers and their whispers find the same record.
    MOCK.FireEvent("CHAT_MSG_SYSTEM", "Faladorian Dawnsight declines your guild invitation.")
    check(g.recruits["Faladorian Dawnsight-Mockrealm"].status == "declined", "decline matched")
    MOCK.FireEvent("CHAT_MSG_WHISPER", "maybe later", "Faladorian Dawnsight-Mockrealm")
    MOCK.FireEvent("CHAT_MSG_WHISPER", "brb", "Faladorian-Dawnsight")
    local fal = g.recruits["Faladorian Dawnsight-Mockrealm"].chat
    check(#fal == 3 and fal[1].me, "your opening whisper, then both sender forms in one conversation")
    -- The game's echo of the opener, in either name form, is not kept twice.
    MOCK.FireEvent("CHAT_MSG_WHISPER_INFORM", MOCK.whispers[1].text, "Faladorian-Dawnsight")
    MOCK.FireEvent("CHAT_MSG_WHISPER_INFORM", MOCK.whispers[1].text, "Faladorian Dawnsight-Mockrealm")
    check(#fal == 3, "echo not doubled")

    -- Openers lost before (old data): put back from the saved whisper text.
    local lyrah = g.recruits["Lyrah Shadeleaf-Mockrealm"]
    check(lyrah.chat == nil, "no whisper saved for Lyrah: nothing to put back")
    local gandi = g.recruits["Gandi Moros-Mockrealm"]
    check(gandi.chat[1].text == "no thanks", "no saved whisper text: nothing invented")

    -- Replies lists players who wrote back, not every invite.
    local listed = {}
    for _, x in ipairs(G.Conversations()) do listed[#listed + 1] = x.full end
    table.sort(listed)
    check(table.concat(listed, ",") == "Faladorian Dawnsight-Mockrealm,Gandi Moros-Mockrealm", "conversations: " .. table.concat(listed, ","))
end

scenarios.guild_backfill_openers = function()
    local now = os.time()
    TALODDB = { guild = { guilds = { ["Brave Souls-Mockrealm"] = {
        members = {}, log = {}, rules = {}, ranks = {}, namesV = 2,
        recruits = {
            ["Doxa Qt-Mockrealm"] = { status = "invited", invited = now - 60, t = now - 60, whisper = "Hi Doxa Qt!",
                replied = now - 30, chat = { { t = now - 30, text = "sure!" } } },
            ["Quiet One-Mockrealm"] = { status = "invited", invited = now - 50, t = now - 50, whisper = "Hi Quiet One!" },
            ["Has It-Mockrealm"] = { status = "invited", invited = now - 40, t = now - 40, whisper = "Hi Has It!",
                chat = { { t = now - 40, me = true, text = "Hi Has It!" }, { t = now - 20, text = "ok" } } },
        } } } } }
    MOCK.SetGuild()
    local ns = T.boot(11509)
    local g = ns.Guild.Data()
    local doxa = g.recruits["Doxa Qt-Mockrealm"].chat
    check(#doxa == 2 and doxa[1].me and doxa[1].text == "Hi Doxa Qt!" and doxa[2].text == "sure!", "opener put back before the reply")
    check(#g.recruits["Has It-Mockrealm"].chat == 2, "not doubled where it was kept")
    check(g.chatV == 2, "done once")
    local listed = {}
    for _, x in ipairs(ns.Guild.Conversations()) do listed[#listed + 1] = x.full end
    table.sort(listed)
    check(table.concat(listed, ",") == "Doxa Qt-Mockrealm,Has It-Mockrealm", "only players who wrote back: " .. table.concat(listed, ","))
end

-- A big guild's window must not redraw on every scan or roster update, and
-- the cached recruiter history must follow the data it is built from.
scenarios.guild_refresh_cost = function()
    local ns = setup(nil, { guild = { roster = {
        { name = "Alpha", rank = 0, level = 60, online = true },
        { name = "Bob", rank = 3, level = 40, online = true },
    } } })
    local G, UI = ns.Guild, ns.GuildUI
    readRoster()
    UI.Show("roster")
    local v = UI.views.roster
    local base, draws = v.Refresh, 0
    v.Refresh = function(self) draws = draws + 1 return base(self) end

    wait(5)
    check(draws == 0, "scans do not redraw the roster tab: " .. draws)
    readRoster()
    check(draws == 0, "an unchanged roster read does not redraw: " .. draws)
    MOCK.guild.roster[2].level = 41
    readRoster()
    check(draws == 1, "a changed roster redraws once: " .. draws)
    MOCK.guild.roster[2].online = false
    readRoster()
    check(draws == 2, "going offline redraws: " .. draws)
    MOCK.FireEvent("GUILD_EVENT_LOG_UPDATE")
    check(draws == 2, "an empty event log does not redraw: " .. draws)

    -- The Recruit tab still follows the scan.
    UI.Show("recruit")
    local r = UI.views.recruit
    local rBase, rDraws = r.Refresh, 0
    r.Refresh = function(self) rDraws = rDraws + 1 return rBase(self) end
    wait(3)
    check(rDraws >= 2, "the Recruit tab redraws with the scan: " .. rDraws)

    -- Cached history: same table while nothing changes, rebuilt when it does.
    local first = G.Recruiters()
    check(G.Recruiters() == first, "cached between calls")
    MOCK.guildEvents = { { "invite", "Alpha", "Cid", nil, 0, 0, 1, 0 }, { "join", "Cid", nil, nil, 0, 0, 1, 0 } }
    UI.Show("recruiters")
    local rv = UI.views.recruiters
    local cBase, cDraws = rv.Refresh, 0
    rv.Refresh = function(self) cDraws = cDraws + 1 return cBase(self) end
    MOCK.FireEvent("GUILD_EVENT_LOG_UPDATE")
    check(cDraws == 1, "new log entries redraw: " .. cDraws)
    local after = G.Recruiters()
    check(after ~= first and after[1] and after[1].by == "Alpha-Mockrealm" and after[1].invitedCount == 1, "rebuilt from the new log")
    G.Invite("Newbie-Mockrealm", { name = "Newbie", level = 5 })
    local mine
    for _, st in ipairs(G.Recruiters()) do if st.by == "Tester-Mockrealm" then mine = st end end
    check(mine and mine.invitedCount == 1, "your invite shows without waiting")

    -- A recruit click redraws the guild window once and nothing else (the
    -- whole-addon refresh was a visible hitch per click).
    UI.Show("recruit")
    local optBase, optDraws = ns.Options.Refresh, 0
    ns.Options.Refresh = function(...) optDraws = optDraws + 1 return optBase(...) end
    rDraws = 0
    G.Invite("Other-Mockrealm", { name = "Other", level = 7 })
    G.Skip("Third-Mockrealm")
    check(rDraws == 2, "invite and skip each redraw the Recruit tab once: " .. rDraws)
    check(optDraws == 0, "a guild action leaves the settings page alone: " .. optDraws)
    ns.Options.Refresh = optBase

    -- That one redraw reads the guild a few times, not per listed player
    -- (40 players x 3 lists x 2 reads was a frame hitch per click).
    for i = 1, 30 do
        plateAdd("nameplate" .. i, MOCK.Friend({ name = "Lone" .. i, guid = "Player-1-L" .. i, level = 10 + i }))
    end
    wait(5)
    TALODDB.guildMiniShown = true
    UI.Refresh()
    local n = #G.Candidates()
    check(n >= 30 and #UI.mini.list.all == n, "the players listed in both windows: " .. n)
    local gi, reads = GetGuildInfo, 0
    GetGuildInfo = function(...) reads = reads + 1 return gi(...) end
    rDraws = 0
    G.Invite("Lone1-Mockrealm")
    GetGuildInfo = gi
    check(rDraws == 1, "one redraw: " .. rDraws)
    check(reads < 25, "guild read a few times per click, not per player: " .. reads)
    check(#UI.mini.list.all == n - 1 and UI.views.recruit.card.title:GetText():find(tostring(n - 1), 1, true),
        "both lists drop the whispered player")

    -- The unread count (tab, notice) without listing every conversation.
    local rec = data().recruits["Lone1-Mockrealm"]
    -- Written around Guild.AddChat, which announces its writes: bumped here.
    rec.unread = 2
    ns.Data.Bump("guild.replies")
    check(G.Unread() == 0, "unread without a line of theirs: not counted")
    rec.chat[#rec.chat + 1] = { t = time(), text = "sure" }
    ns.Data.Bump("guild.replies")
    check(G.Unread() == 2, "their line: counted")
    G.MarkRead("Lone1-Mockrealm")
    check(G.Unread() == 0, "read: no longer counted (MarkRead announces it)")
    TALODDB.guildMiniShown = false
end

-- The game delivers about one whisper a second: a run of invites queues the
-- openers for minutes. A late echo is not a second line; the whispers wait
-- in the Outbox and each player is back to click for the invite 10 s after
-- their own whisper.
scenarios.guild_whisper_queue = function()
    local ns = setup()
    local G = ns.Guild
    G.Invite("Late Echo-Mockrealm", { name = "Late Echo", level = 10 })
    local r = data().recruits["Late Echo-Mockrealm"]
    local sent = MOCK.whispers[1].text
    MOCK.now = MOCK.now + 240
    MOCK.FireEvent("CHAT_MSG_WHISPER_INFORM", sent, "Late Echo-Mockrealm")
    check(#r.chat == 1, "an echo four minutes late is not a second line: " .. #r.chat)
    MOCK.now = MOCK.now + 900
    MOCK.FireEvent("CHAT_MSG_WHISPER_INFORM", sent, "Late Echo-Mockrealm")
    check(#r.chat == 2, "the same text sent again much later is a line")

    -- A burst: every whisper goes first (past the queue limit they wait in
    -- the Outbox, in click order), each invite a click at least 10 s after its own whisper.
    MOCK.Tick(30)
    local before, beforeInv = #MOCK.whispers, #MOCK.guildInvites
    local whisperAt, inviteAt = {}, {}
    local baseSend, baseInvite = SendChatMessage, C_GuildInfo.Invite
    SendChatMessage = function(text, kind, lang, target)
        whisperAt[target] = GetTime()
        return baseSend(text, kind, lang, target)
    end
    C_GuildInfo.Invite = function(name)
        inviteAt[name] = GetTime()
        return baseInvite(name)
    end
    resetOutput()
    for i = 1, 12 do G.Invite("Burst" .. i .. "-Mockrealm", { name = "Burst" .. i }) end
    check(#MOCK.guildInvites == beforeInv, "no invite before its whisper: " .. #MOCK.guildInvites)
    check(#MOCK.whispers - before == 10, "whispers stop at the queue limit: " .. (#MOCK.whispers - before))
    check(T.printed("back on the list to invite 10 s after their message"), "said how it goes")
    local r12 = data().recruits["Burst12-Mockrealm"]
    check(r12.status == "inviting" and r12.unsent ~= nil and G.OpenerQueued("Burst12-Mockrealm"), "opener queued, not lost")
    local listed = G.Candidates()
    check(#listed == 1 and listed[1].full == "Late Echo-Mockrealm" and listed[1].ready,
        "waiting recruits are not offered again (only the earlier one, ready): " .. #listed)
    check(ns.Outbox.Pending() == 2, "two waiting: " .. ns.Outbox.Pending())
    G.Invite("After-Mockrealm", { name = "After" })
    check(#MOCK.whispers - before == 10 and ns.Outbox.Pending() == 3, "a new opener queues behind the others")
    -- A forgotten recruit gets neither the queued whisper nor the invite.
    G.Forget("Burst11-Mockrealm")
    wait(30)
    check(#MOCK.whispers - before == 12 and ns.Outbox.Pending() == 0, "the queue drains: " .. (#MOCK.whispers - before))
    check(MOCK.whispers[#MOCK.whispers].target == "After", "in click order")
    check(#MOCK.guildInvites == beforeInv, "no invite without its click")
    -- 11 bursts (one forgotten), After and the earlier Late Echo.
    check(G.InvitesReady() == 13, "all back to click: " .. G.InvitesReady())
    for i = 1, 12 do
        if i ~= 11 then G.Invite("Burst" .. i .. "-Mockrealm") end
    end
    G.Invite("After-Mockrealm")
    check(#MOCK.guildInvites - beforeInv == 12, "every invite sent once: " .. (#MOCK.guildInvites - beforeInv))
    for _, name in ipairs({ "Burst1", "Burst10", "Burst12", "After" }) do
        local gap = (inviteAt[name] or 0) - (whisperAt[name] or math.huge)
        check(gap >= 10, name .. ": invite at least 10 s after its whisper: " .. gap)
    end
    check(r12.whisper ~= nil and r12.unsent == nil and #r12.chat == 1 and r12.status == "invited", "queued opener recorded when it goes")
    check(not G.OpenerQueued("Burst12-Mockrealm"), "no longer queued")
    check(whisperAt.Burst11 == nil and inviteAt.Burst11 == nil, "forgotten recruit: nothing sent")
    SendChatMessage, C_GuildInfo.Invite = baseSend, baseInvite

    -- A reload empties the queue: a recruit whose opener was still queued is
    -- marked "not invited"; one whose opener went out still waits for its click.
    local rr = data().recruits["Burst1-Mockrealm"]
    rr.status = "inviting"
    local rq = data().recruits["Burst2-Mockrealm"]
    rq.status, rq.unsent = "inviting", "queued text"
    G = setup().Guild
    check(data().recruits["Burst2-Mockrealm"].status == "uninvited", "opener lost in the queue: not invited")
    check(data().recruits["Burst1-Mockrealm"].status == "inviting" and G.InviteReady("Burst1-Mockrealm"), "opener out: ready to click")
    local whispers, invites = #MOCK.whispers, #MOCK.guildInvites
    check(G.Invite("Burst1-Mockrealm"), "click invites")
    check(#MOCK.whispers == whispers and #MOCK.guildInvites == invites + 1, "invite only: they had the whisper")
end

-- The game's chat throttle: the dropped opener is marked "no message",
-- whispers pause (queued ones and their invites wait), the queue limit drops for next time,
-- a click sends the held message once the pause is over, a late echo puts
-- a dropped one back.
scenarios.guild_whisper_throttle = function()
    local ns = setup()
    local G = ns.Guild
    local THROTTLED = "The number of messages that can be sent is limited, please wait to send another message."
    for i = 1, 4 do G.Invite("Run" .. i .. "-Mockrealm", { name = "Run" .. i }) end
    check(#MOCK.whispers == 4, "four openers out")
    -- Two lines, as the game shows them; the same text in chat is not counted again.
    MOCK.FireEvent("UI_INFO_MESSAGE", 0, THROTTLED)
    MOCK.FireEvent("UI_INFO_MESSAGE", 0, THROTTLED)
    MOCK.FireEvent("CHAT_MSG_SYSTEM", THROTTLED)
    local rec = data().recruits
    check(rec["Run4-Mockrealm"].unsent and not rec["Run4-Mockrealm"].whisper, "newest opener counted as dropped")
    check(rec["Run3-Mockrealm"].unsent and not rec["Run2-Mockrealm"].unsent, "one per line: " .. tostring(rec["Run2-Mockrealm"].unsent))
    check(#(rec["Run4-Mockrealm"].chat or {}) == 0, "dropped opener not in the conversation")
    check(ns.Outbox.Hold() > 14 and ns.Outbox.Hold() <= 15, "paused: " .. ns.Outbox.Hold())
    check(ns.Outbox.Burst() < 10, "own limit lowered: " .. ns.Outbox.Burst())
    check(T.printed("limiting your messages"), "said why")

    -- Paused: the whisper waits in the queue, and its invite waits for it.
    local before = #MOCK.whispers
    check(G.Invite("Held-Mockrealm", { name = "Held" }), "click during the pause")
    check(#MOCK.whispers == before and MOCK.guildInvites[#MOCK.guildInvites] ~= "Held", "nothing to Held yet")
    check(rec["Held-Mockrealm"].unsent ~= nil and G.OpenerQueued("Held-Mockrealm"), "held opener queued")
    local ok, why = G.SendOpener("Held-Mockrealm")
    check(not ok and why == "held" and #MOCK.whispers == before, "no send by hand while paused")
    check(G.OpenerQueued("Held-Mockrealm"), "still queued after the refused click")
    local rok, rwhy = G.Reply("Run1-Mockrealm", "hello")
    check(not rok and rwhy == "held", "replies wait too")

    -- After the pause the queued opener goes by itself, once.
    MOCK.Tick(16)
    check(ns.Outbox.Hold() == 0, "pause over")
    check(#MOCK.whispers == before + 1 and MOCK.whispers[#MOCK.whispers].target == "Held", "queued opener sent after the pause")
    check(rec["Held-Mockrealm"].whisper and not rec["Held-Mockrealm"].unsent and #rec["Held-Mockrealm"].chat == 1, "now an opener")
    wait(11)
    check(#MOCK.whispers == before + 1, "sent once")
    G.Invite("Held-Mockrealm")
    G.Invite("Run4-Mockrealm")
    check(MOCK.guildInvites[#MOCK.guildInvites - 1] == "Held" and rec["Held-Mockrealm"].status == "invited", "invite after the whisper")
    check(rec["Run4-Mockrealm"].status == "invited", "a dropped whisper's invite still goes")

    -- A dropped one (not queued): one click = one whisper.
    check(not G.OpenerQueued("Run4-Mockrealm"), "dropped one is not queued")
    check(G.SendOpener("Run4-Mockrealm") and #MOCK.whispers == before + 2, "sent on click")
    check(rec["Run4-Mockrealm"].whisper and not rec["Run4-Mockrealm"].unsent, "click restores it")

    -- A dropped one that went out after all (its echo): put back.
    MOCK.FireEvent("CHAT_MSG_WHISPER_INFORM", rec["Run3-Mockrealm"].unsent, "Run3-Mockrealm")
    check(rec["Run3-Mockrealm"].whisper and not rec["Run3-Mockrealm"].unsent, "echo restores it")

    -- A second throttle soon after doubles the pause.
    MOCK.Tick(2)
    G.Invite("Again-Mockrealm", { name = "Again" })
    MOCK.FireEvent("UI_INFO_MESSAGE", 0, THROTTLED)
    check(ns.Outbox.Hold() > 29, "longer pause: " .. ns.Outbox.Hold())
    slash("guild pace reset")
    check(TALODDB.outboxBurst == nil and ns.Outbox.Burst() == 10, "learned limit forgotten")
end

scenarios.guild_dedupe_openers = function()
    local now = os.time()
    local hi = "Hi Bishash Nagas!"
    TALODDB = { guild = { guilds = { ["Brave Souls-Mockrealm"] = {
        members = {}, log = {}, rules = {}, ranks = {}, namesV = 2, chatV = 1,
        recruits = {
            ["Bishash Nagas-Mockrealm"] = { status = "joined", invited = now - 400, t = now - 400, whisper = hi,
                chat = { { t = now - 400, me = true, text = hi }, { t = now - 168, me = true, text = hi },
                    { t = now - 147, text = "im in your gulid" }, { t = now - 60, me = true, text = "x3 sorry" } } },
        } } } } }
    MOCK.SetGuild()
    local ns = T.boot(11509)
    local chat = ns.Guild.Data().recruits["Bishash Nagas-Mockrealm"].chat
    check(#chat == 3 and chat[1].text == hi and chat[2].text == "im in your gulid", "late echo dropped: " .. #chat)
    check(ns.Guild.Data().chatV == 2, "done once")
end

scenarios.guild_reply_buttons = function()
    local ns = setup(nil, { guild = { roster = { { name = "Alpha", rank = 0, level = 60, online = true } } } })
    local G, UI = ns.Guild, ns.GuildUI
    readRoster()
    G.Invite("Newbie-Mockrealm", { name = "Newbie", level = 5 })
    MOCK.FireEvent("CHAT_MSG_WHISPER", "hi!", "Newbie-Mockrealm")
    UI.Show("replies")
    local v = UI.views.replies
    check(UI.state.chat == "Newbie-Mockrealm" and v.party:IsShown() and v.bnet:IsShown() and v.copy:IsShown(), "buttons shown")

    v.party:Fire("OnClick", "LeftButton")
    check(#MOCK.partyInvites == 1 and MOCK.partyInvites[1] == "Newbie", "one party invite: " .. tostring(MOCK.partyInvites[1]))

    v.copy:Fire("OnClick", "LeftButton")
    check(MOCK.popup == "TALOD_COPY" and MOCK.popupText == "name" and MOCK.popupData == "Newbie",
        "copy box with the name (shared Utils.Copy)")

    -- Not in the guild and not targeted: no route, nothing sent.
    v.bnet:Fire("OnClick", "LeftButton")
    check(#MOCK.bnetRequests == 0 and T.printed("guild member or a player you target"), "no Battle.net route yet")
    -- Targeted: through the unit.
    setTarget(MOCK.Friend({ name = "Newbie", guid = "Player-1-N", level = 5 }))
    v.bnet:Fire("OnClick", "LeftButton")
    check(MOCK.bnetRequests[1] == "unit:target", "request through the target: " .. tostring(MOCK.bnetRequests[1]))
    -- Joined: through the guild roster.
    setTarget(nil)
    table.insert(MOCK.guild.roster, { name = "Newbie", rank = 4, level = 5, online = true })
    readRoster()
    v.bnet:Fire("OnClick", "LeftButton")
    check(MOCK.bnetRequests[2] == "member:Newbie", "request as a guild member: " .. tostring(MOCK.bnetRequests[2]))
    MOCK.bnetConnected = false
    v.bnet:Fire("OnClick", "LeftButton")
    check(#MOCK.bnetRequests == 2 and T.printed("not connected"), "Battle.net offline: nothing")
end

-- Did the invites reach them? The game's "You have invited X" confirms one;
-- its answers find the recruit in any name form, during "inviting" too; an
-- invite never confirmed shows "unconfirmed" and a click invites again.
scenarios.guild_invite_check = function()
    local ns = setup()
    local G, UI = ns.Guild, ns.GuildUI
    local rec = function(full) return data().recruits[full] end

    -- Before the client ever showed a confirmation: nothing claimed either way.
    G.Invite("Alpha One-Mockrealm", { name = "Alpha One" })
    wait(10.5)
    G.Invite("Alpha One-Mockrealm", { name = "Alpha One" })  -- second click: the invite
    check(rec("Alpha One-Mockrealm").status == "invited" and rec("Alpha One-Mockrealm").ack == false, "sent, not confirmed")
    check(G.InviteCheck(rec("Alpha One-Mockrealm")) == nil, "no confirmation seen on this client yet: unknown, not unconfirmed")
    MOCK.FireEvent("CHAT_MSG_SYSTEM", "You have invited Alpha One to join your guild.")
    check(G.InviteCheck(rec("Alpha One-Mockrealm")) == "confirmed" and TALODDB.guildAckSeen, "confirmed by the game")

    -- An invite the game never confirms.
    G.Invite("Quiet-Mockrealm", { name = "Quiet" })
    wait(10.5)
    G.Invite("Quiet-Mockrealm", { name = "Quiet" })  -- second click: the invite
    local quiet = rec("Quiet-Mockrealm")
    check(G.InviteCheck(quiet) == "waiting", "waiting for the game")
    MOCK.now = MOCK.now + 61
    wait(50)
    check(G.InviteCheck(quiet) == "unconfirmed", "unconfirmed after a minute")
    local c = G.Check()
    check(c.sent == 2 and c.confirmed == 1 and #c.unconfirmed == 1 and c.unconfirmed[1] == "Quiet-Mockrealm", "check counts")
    UI.Show("invited")
    check(UI.views.invited.card.title:GetText():find("1 unconfirmed"), "title counts it")
    for _, row in ipairs(UI.views.invited.list.all) do if row.tooltip then row.tooltip(TALODGuildWindow) end end
    local whispers, invites = #MOCK.whispers, #MOCK.guildInvites
    local list = UI.views.invited.list
    list._height = 200
    list:Draw()
    local row
    for _, r in ipairs(list.rows) do if r.item and r.item.full == "Quiet-Mockrealm" then row = r end end
    check(row and row.item.unconfirmed, "row marked")
    row:Fire("OnClick", "LeftButton")
    check(#MOCK.guildInvites == invites + 1 and #MOCK.whispers == whispers, "click: one invite, no whisper")
    check(quiet.ack == false and G.InviteCheck(quiet) == "waiting", "the new invite waits for its own confirmation")

    -- A decline written without the realm the key has (a realm of the group).
    data().recruits["Far Away-Otherrealm"] = { name = "Far Away", status = "invited", invited = time() - 300, t = time() - 300, invites = 1 }
    MOCK.FireEvent("CHAT_MSG_SYSTEM", "Far Away declines your guild invitation.")
    check(rec("Far Away-Otherrealm").status == "declined", "decline found by name: " .. tostring(rec("Far Away-Otherrealm").status))
    -- A late decline (after the old two-minute window) still counts.
    data().recruits["Slow-Mockrealm"] = { name = "Slow", status = "invited", invited = time() - 400, t = time() - 400, invites = 1 }
    MOCK.FireEvent("CHAT_MSG_SYSTEM", "Slow declines your guild invitation.")
    check(rec("Slow-Mockrealm").status == "declined", "late decline")

    -- Offline: the opener bounces while "inviting", and the invite is not sent.
    invites = #MOCK.guildInvites
    G.Invite("Gone-Mockrealm", { name = "Gone" })
    MOCK.FireEvent("CHAT_MSG_SYSTEM", "No player named 'Gone' is currently playing.")
    check(rec("Gone-Mockrealm").status == "notfound", "offline during inviting: " .. tostring(rec("Gone-Mockrealm").status))
    wait(11)
    check(#MOCK.guildInvites == invites, "no invite to an offline player")
    -- The guild command's own "not found".
    data().recruits["Typo-Mockrealm"] = { name = "Typo", status = "invited", invited = time() - 5, t = time() - 5, invites = 1 }
    MOCK.FireEvent("CHAT_MSG_SYSTEM", "\"Typo\" not found.")
    check(rec("Typo-Mockrealm").status == "notfound", "guild not found")

    -- A line nobody recognizes right after a send is kept for the check.
    G.Invite("Odd-Mockrealm", { name = "Odd" })
    MOCK.FireEvent("CHAT_MSG_SYSTEM", "Something new the server says.")
    check(G.Check().unmatched[1].text == "Something new the server says.", "unmatched line kept")
    resetOutput()
    slash("guild check")
    check(printed("invites in the last hour") and printed("Something new the server says"), "check printed")
    -- Old records (sent before this check existed) are never called unconfirmed.
    data().recruits["Old-Mockrealm"] = { name = "Old", status = "invited", invited = time() - 3000, t = time() - 3000, invites = 1 }
    check(G.InviteCheck(rec("Old-Mockrealm")) == nil, "old record: unknown")
end

-- Delayed invite off: the whisper and the invite in the same click. The
-- toggle sits next to /who on the Recruit tab, flips the setting, and the
-- tick never sends an invite either way.
scenarios.guild_delayed_off = function()
    local ns = setup()
    local G, UI = ns.Guild, ns.GuildUI
    UI.Show("recruit")
    local v = UI.views and UI.views.recruit
    local tab = v or nil
    TALODDB.guildDelayedInvite = true
    if tab and tab.delayed then
        tab.delayed:Fire("OnClick", "LeftButton")
        check(TALODDB.guildDelayedInvite == false, "toggle turns it off")
    else
        TALODDB.guildDelayedInvite = false
    end
    plateAdd("nameplate1", MOCK.Friend({ name = "Quick", guid = "Player-1-Q", level = 12 }))
    wait(5)
    check(#G.Candidates() == 1 and UI.CandidateRows()[1].tint == UI.TINT_NEW, "gray bar before the click")
    check(G.Invite("Quick-Mockrealm"), "one click")
    check(#MOCK.whispers == 1 and MOCK.guildInvites[1] == "Quick", "whisper and invite in the same click")
    check(data().recruits["Quick-Mockrealm"].status == "invited", "invited")
    wait(15)
    check(#MOCK.guildInvites == 1 and #G.Candidates() == 0, "nothing more, not listed again")

    -- A repeat (the same invite went seconds ago, a double click): it counts.
    plateAdd("nameplate2", MOCK.Friend({ name = "Twice", guid = "Player-1-W", level = 13 }))
    wait(5)
    ns.Outbox.GuildInvite("Twice")
    local invites = #MOCK.guildInvites
    check(G.Invite("Twice-Mockrealm") == true, "repeat: accepted")
    local r = data().recruits["Twice-Mockrealm"]
    check(r.status == "invited" and r.whisper and #MOCK.guildInvites == invites, "counted as invited, no second invite: " .. tostring(r.status))

    -- The same-click invite the game does not take: it waits in the queue,
    -- ready once the whisper is out; the next accepted input sends it.
    local realInvite = C_GuildInfo.Invite
    C_GuildInfo.Invite = function() error("refused") end
    plateAdd("nameplate3", MOCK.Friend({ name = "Later", guid = "Player-1-L", level = 14 }))
    plateAdd("nameplate4", MOCK.Friend({ name = "Queued", guid = "Player-1-Q2", level = 15 }))
    plateAdd("nameplate6", MOCK.Friend({ name = "Early", guid = "Player-1-E", level = 16 }))
    wait(5)
    TALODDB.outboxBurst = 2   -- two whispers on their way at most: the third waits in the queue
    check(G.Invite("Early-Mockrealm") == true, "first click")
    check(G.Invite("Later-Mockrealm") == true, "click: the whisper went, the invite did not")
    check(G.Invite("Queued-Mockrealm") == true, "second click: its whisper is queued behind")
    C_GuildInfo.Invite = realInvite
    r = data().recruits["Later-Mockrealm"]
    check(r.status == "inviting" and r.whisper, "Later: in the invite queue")
    local why, _, readyIn = G.InviteWhy("Later-Mockrealm")
    check(why == "failed" and readyIn == 0, "Later: ready, why failed: " .. tostring(why))
    check(G.InviteWhy("Queued-Mockrealm") == "message", "Queued: waits for its whisper")
    local list = G.Candidates()
    check(#list == 2 and list[1].full == "Early-Mockrealm" and list[2].full == "Later-Mockrealm" and list[2].why == "failed",
        "Early and Later ready, oldest first")
    check(G.InviteQueue().ready == 2 and G.InviteQueue().message == 1, "queue: 2 ready, 1 waiting for its message")
    -- The tooltips say why; the Next invite button counts the ready ones.
    UI.Show("recruit")
    ns.Refresh()
    local rv = UI.views.recruit
    check(rv.next.label:GetText():find("Next invite %(2%)"), "Next invite (2): " .. tostring(rv.next.label:GetText()))
    local rows = UI.CandidateRows()
    rows[2].tooltip(UIParent)
    rv.next:Fire("OnEnter")
    rv.handsFree:Fire("OnEnter")
    local tip = table.concat(UI.NextTip(), " | ")
    check(tip:find("Early") and tip:find("Ready: 2") and tip:find("Waiting for their message to go out first: 1"), "Next tip: " .. tip)
    wait(2)
    check(G.InviteWhy("Queued-Mockrealm") == "failed" and G.InviteQueue().ready == 3, "Queued: whisper out, ready")
    invites = #MOCK.guildInvites
    check(G.InviteNext() == "Early-Mockrealm", "next invite: the oldest first")
    check(G.InviteNext() == "Later-Mockrealm" and #MOCK.guildInvites == invites + 2, "then the next")
    check(G.InviteNext() == "Queued-Mockrealm" and #MOCK.guildInvites == invites + 3, "then the last")
    check(G.InviteNext() == nil, "queue empty")
    check(ns.GuildUI.WhyText and ns.GuildUI.WhyText("failed"):find("did not accept"), "tooltip explains why")

    -- A Hands Free invite the game blocks: back in the queue for another input.
    plateAdd("nameplate5", MOCK.Friend({ name = "Held", guid = "Player-1-H2", level = 14 }))
    wait(5)
    G.Who()   -- the /who's wait keeps the click on the list
    TALODDB.guildHandsFree = true
    C_GuildInfo.Invite = function() MOCK.FireEvent("ADDON_ACTION_BLOCKED", "TALOD", "C_GuildInfo.Invite()") end
    MOCK.MouseDown("LeftButton")
    C_GuildInfo.Invite = realInvite
    r = data().recruits["Held-Mockrealm"]
    check(r and r.status == "inviting", "blocked invite: queued: " .. tostring(r and r.status))
    check(G.InviteWhy("Held-Mockrealm") == "blocked" and G.HandsFreeBlockedFor("Held-Mockrealm") == "mouse", "why blocked, from world clicks")
    invites = #MOCK.guildInvites
    MOCK.MouseDown("LeftButton")
    check(#MOCK.guildInvites == invites, "world clicks do not try it again")
    -- The recruit key binding is a real key press: it sends it, Hands Free on or off.
    TALODDB.guildHandsFree = false
    _G["TALODRecruitStep"]:Click()
    check(#MOCK.guildInvites == invites + 1 and MOCK.guildInvites[#MOCK.guildInvites] == "Held", "the binding sends it")
    check(G.HandsFreePresses()[#G.HandsFreePresses()].result == "invite Held", "traced as the binding")
end

-- A reply you typed shows in the conversation as "sending" until the game's
-- echo puts it in; one the throttle dropped is marked, and an unanswered one
-- leaves the list after a minute.
scenarios.guild_replies_outgoing = function()
    local ns = setup()
    local G, UI = ns.Guild, ns.GuildUI
    plateAdd("nameplate1", MOCK.Friend({ name = "Newbie", guid = "Player-1-N", level = 12 }))
    wait(5)
    G.Invite("Newbie-Mockrealm")
    MOCK.FireEvent("CHAT_MSG_WHISPER", "hi!", "Newbie-Mockrealm")
    UI.Show("replies")
    local v = UI.views.replies
    check(UI.state.chat == "Newbie-Mockrealm", "conversation open")

    v.box:SetText("welcome!")
    v.box:Fire("OnEnterPressed")
    local out = G.Outgoing("Newbie-Mockrealm")
    check(#out == 1 and out[1].state == "sending" and out[1].text == "welcome!", "sent reply shown as sending")
    check(v.shown and v.shown:find("sendingwelcome!", 1, true), "drawn in the conversation")

    MOCK.FireEvent("CHAT_MSG_WHISPER_INFORM", "welcome!", "Newbie-Mockrealm")
    local r = data().recruits["Newbie-Mockrealm"]
    check(#G.Outgoing("Newbie-Mockrealm") == 0 and r.chat[#r.chat].text == "welcome!", "the echo replaces it")
    check(not v.shown:find("sending", 1, true), "redrawn without it")

    -- Dropped by the game's throttle.
    MOCK.Tick(2)
    v.box:SetText("you there?")
    v.box:Fire("OnEnterPressed")
    MOCK.FireEvent("CHAT_MSG_SYSTEM", "The number of messages that can be sent is limited, please wait to send another message.")
    out = G.Outgoing("Newbie-Mockrealm")
    check(#out == 1 and out[1].state == "lost", "dropped reply marked")
    wait(301)
    check(#G.Outgoing("Newbie-Mockrealm") == 0, "dropped mark leaves after a while")

    -- No echo at all: gone after a minute.
    check(G.Reply("Newbie-Mockrealm", "last try"), "sent")
    wait(61)
    check(#G.Outgoing("Newbie-Mockrealm") == 0, "no echo: leaves the list")
end

-- Replies: a tag per conversation (joined / declined / invited / blocked)
-- with filters, a search over the messages, and opening one brings the
-- player's level up to date (a unit showing them, else one /who).
scenarios.guild_replies_filters_lookup = function()
    local ns = setup()
    local G, UI = ns.Guild, ns.GuildUI
    plateAdd("nameplate1", MOCK.Friend({ name = "Newbie", guid = "Player-1-N", level = 12 }))
    plateAdd("nameplate2", MOCK.Friend({ name = "Oldie", guid = "Player-1-O", level = 20 }))
    plateAdd("nameplate3", MOCK.Friend({ name = "Grump", guid = "Player-1-G", level = 30 }))
    wait(5)
    G.Invite("Newbie-Mockrealm")
    G.Invite("Oldie-Mockrealm")
    G.Invite("Grump-Mockrealm")
    MOCK.FireEvent("CHAT_MSG_WHISPER", "hi, do you raid?", "Newbie-Mockrealm")
    MOCK.FireEvent("CHAT_MSG_WHISPER", "no thanks", "Oldie-Mockrealm")
    MOCK.FireEvent("CHAT_MSG_WHISPER", "go away", "Grump-Mockrealm")
    local rec = data().recruits
    rec["Oldie-Mockrealm"].status = "declined"
    MOCK.FireEvent("CHAT_MSG_IGNORED", "", "Grump")
    check(G.ReplyGroup(rec["Newbie-Mockrealm"]) == "invited", "invited")
    check(G.ReplyGroup(rec["Oldie-Mockrealm"]) == "declined", "declined")
    check(G.ReplyGroup(rec["Grump-Mockrealm"]) == "blocked", "blocked")
    rec["Newbie-Mockrealm"].status = "joined"
    check(G.ReplyGroup(rec["Newbie-Mockrealm"]) == "joined", "joined")
    ns.Data.Bump("guild.replies")

    UI.Show("replies")
    local v = UI.views.replies
    local function shown()
        local out = {}
        for _, item in ipairs(v.list.items) do if item.full then out[#out + 1] = item.full:match("^[^-]+") end end
        table.sort(out)
        return table.concat(out, ",")
    end
    check(shown() == "Grump,Newbie,Oldie", "all three: " .. shown())
    local tags = {}
    for _, item in ipairs(v.list.items) do if item.full then tags[item.full] = item.cols and item.cols[1] or "" end end
    check(tags["Grump-Mockrealm"]:find("Blocked", 1, true) and tags["Newbie-Mockrealm"]:find("Joined", 1, true)
        and tags["Oldie-Mockrealm"]:find("Declined", 1, true), "each tagged")
    for _, b in ipairs(v.groups) do if b.key == "blocked" then b:Fire("OnClick", "LeftButton") end end
    check(UI.state.replyGroup == "blocked" and shown() == "Grump", "Blocked filter: " .. shown())
    UI.state.replyGroup = "all"

    -- The second search box: words said, not names.
    v.words:SetText("RAID")
    v.words:Fire("OnTextChanged")
    check(shown() == "Newbie", "message search: " .. shown())
    v.words:SetText("zebra")
    v.words:Fire("OnTextChanged")
    check(shown() == "" and v.list.items[1] and v.list.items[1].text:find("No conversation matches", 1, true), "nothing said: " .. shown())
    v.words:SetText("")
    v.words:Fire("OnTextChanged")
    check(shown() == "Grump,Newbie,Oldie", "cleared")

    -- Opening a conversation: a unit showing them is read first.
    rec["Newbie-Mockrealm"].status = "invited"
    MOCK.units.nameplate1.level = 14
    check(G.LookUp("Newbie-Mockrealm") == "unit" and rec["Newbie-Mockrealm"].level == 14, "level from the nameplate")
    check(#MOCK.whoQueries == 0, "no /who needed")
    -- Out of sight: one /who for that one name.
    plateRemove("nameplate1")
    check(G.LookUp("Newbie-Mockrealm") == "who" and MOCK.whoQueries[1] == 'n-"Newbie"', "one /who: " .. tostring(MOCK.whoQueries[1]))
    MOCK.whoResults = { { fullName = "Newbie", fullGuildName = "", level = 16, filename = "MAGE" } }
    MOCK.FireEvent("WHO_LIST_UPDATE")
    check(rec["Newbie-Mockrealm"].level == 16, "level from /who")
    check(#G.Candidates() == 0, "a look-up adds no recruit candidate")
    plateRemove("nameplate2")
    check(G.LookUp("Oldie-Mockrealm") == nil and #MOCK.whoQueries == 1, "the /who wait holds a second one")
    wait(1)
    check(#MOCK.whoQueries == 1, "never from the tick")
end

-- The language filter stars words out of the echo; being ignored or an
-- offline player marks the reply as not delivered.
scenarios.guild_replies_filtered_ignored = function()
    local ns = setup()
    local G, UI = ns.Guild, ns.GuildUI
    check(G.SameWhisper("a shit talking dude", "a @#$% talking dude"), "starred word matches")
    check(G.SameWhisper("this shitty day, ok", "this @#$%ty day, ok"), "starred part of a word matches")
    check(not G.SameWhisper("hello there", "hello where"), "another word does not")
    check(not G.SameWhisper("hello there", "hello there friend"), "more words do not")
    check(not G.SameWhisper("hello", "@#$% there"), "fewer words do not")

    plateAdd("nameplate1", MOCK.Friend({ name = "Newbie", guid = "Player-1-N", level = 12 }))
    wait(5)
    G.Invite("Newbie-Mockrealm")
    MOCK.FireEvent("CHAT_MSG_WHISPER", "hi!", "Newbie-Mockrealm")
    UI.Show("replies")
    local v = UI.views.replies
    local r = data().recruits["Newbie-Mockrealm"]

    check(G.Reply("Newbie-Mockrealm", "no shit talking here"), "sent")
    MOCK.FireEvent("CHAT_MSG_WHISPER_INFORM", "no @#$% talking here", "Newbie-Mockrealm")
    check(#G.Outgoing("Newbie-Mockrealm") == 0 and r.chat[#r.chat].text == "no @#$% talking here", "filtered echo replaces it")

    MOCK.Tick(2)
    check(G.Reply("Newbie-Mockrealm", "you there?"), "sent")
    MOCK.FireEvent("CHAT_MSG_IGNORED", "", "Newbie")
    local out = G.Outgoing("Newbie-Mockrealm")
    check(#out == 1 and out[1].state == "ignoring", "marked: they ignore you")
    check(r.ignoring ~= nil, "kept on the record")
    UI.Refresh()
    check(v.shown and v.shown:find("ignoring", 1, true), "drawn as not delivered")

    MOCK.FireEvent("CHAT_MSG_WHISPER", "sorry, misclick", "Newbie-Mockrealm")
    check(r.ignoring == nil, "a whisper from them clears it")

    MOCK.Tick(2)
    check(G.Reply("Newbie-Mockrealm", "back?"), "sent")
    MOCK.FireEvent("CHAT_MSG_SYSTEM", "Newbie is ignoring you.")
    check(G.Outgoing("Newbie-Mockrealm")[2].state == "ignoring", "system line works too")

    MOCK.Tick(2)
    check(G.Reply("Newbie-Mockrealm", "offline?"), "sent")
    MOCK.FireEvent("CHAT_MSG_SYSTEM", "No player named 'Newbie' is currently playing.")
    out = G.Outgoing("Newbie-Mockrealm")
    check(out[#out].state == "notfound", "offline marked")
end

-- Right-click a member: every rank in order, one game command per pick,
-- warnings for rights the new rank adds, gone once the mouse moves away.
scenarios.guild_rank_menu = function()
    local ns = setup(nil, { guild = { roster = {
        { name = "Alpha", rank = 0, level = 60, online = true },
        { name = "Vet", rank = 2, level = 50, online = true },
        { name = "Mem1", rank = 3, level = 30, online = true },
        { name = "Ini", rank = 4, level = 5, online = true },
    } } })
    MOCK.guild.can = { promote = true, demote = true }
    local G, UI = ns.Guild, ns.GuildUI
    readRoster()

    local function choices(full)
        local out = {}
        for _, c in ipairs(G.RankChoices(full)) do out[c.rank] = c end
        return out
    end
    local c = choices("Ini-Mockrealm")
    check(c[0] and c[4] and c[4].current, "every rank in order, theirs marked")
    check(not c[0].ok and not c[1].ok and c[1].why:find("not below your rank"), "not into your rank or above")
    check(c[2].ok and c[3].ok, "the ranks below yours")
    check(c[2].gained == nil, "rights unknown: nil, never \"none\"")
    check(not choices("Alpha-Mockrealm")[3].ok, "the guild master cannot be moved")

    MOCK.guild.flags = { [2] = { [7] = true, [11] = true }, [3] = {}, [4] = {} }
    c = choices("Ini-Mockrealm")
    check(table.concat(c[2].gained, ",") == "invite,read officer notes" and #c[3].gained == 0, "rights the new rank adds")
    check(#choices("Vet-Mockrealm")[4].lost == 2, "rights a demotion takes")

    check(G.SetRank("Ini-Mockrealm", 3) == true and MOCK.promoted[1] == "Ini", "one step up: the game's promote")
    check(G.SetRank("Mem1-Mockrealm", 4) == true and MOCK.demoted[1] == "Mem1", "one step down: the game's demote")
    check(G.SetRank("Ini-Mockrealm", 2) == true and #MOCK.rankSets == 1
        and MOCK.rankSets[1][1] == 4 and MOCK.rankSets[1][2] == 3, "a jump: one SetGuildMemberRank, rank counted from 1")
    resetOutput()
    check(G.SetRank("Ini-Mockrealm", 1) == false and printed("not below your rank"), "refused with the reason")
    check(G.SetRank("Ini-Mockrealm", 4) == false and #MOCK.demoted == 1, "their own rank: nothing")

    local saved = SetGuildMemberRank
    SetGuildMemberRank = nil
    check(not choices("Ini-Mockrealm")[2].ok and choices("Ini-Mockrealm")[3].ok, "no rank pick on this client: one step only")
    SetGuildMemberRank = saved
    MOCK.guild.can.demote = false
    check(not choices("Mem1-Mockrealm")[4].ok and choices("Mem1-Mockrealm")[2].ok, "no demote right: only up")
    MOCK.guild.can.demote = true

    -- The window: right-click a Roster row.
    UI.Show("roster")
    local list = UI.views.roster.list
    list._height = 400
    list:Draw()
    local row
    for _, r in ipairs(list.rows) do
        if r:IsShown() and r.item and r.item.full == "Ini-Mockrealm" then row = r end
    end
    check(row ~= nil, "roster row")
    MOCK.cursorX, MOCK.cursorY = 300, 300
    row:Fire("OnClick", "RightButton")
    local menu = TALODContextMenu
    check(menu and menu:IsShown(), "menu opens on a right-click")
    check(menu.title:GetText():find("Ini"), "titled with the member")
    menu.list._height = 400
    menu.list:Draw()
    local warned, picked
    for _, r in ipairs(menu.list.rows) do
        if r:IsShown() and r.item and r.item.text:find("Veteran") then
            warned = r.item.text:find("gains invite") ~= nil
            picked = r
        end
    end
    check(warned, "the promotion that adds rights carries a warning")
    local sets = #MOCK.rankSets
    picked:Fire("OnClick", "LeftButton")
    check(#MOCK.rankSets == sets + 1 and not menu:IsShown(), "a pick: one command, menu closes")
    row:Fire("OnClick", "LeftButton")
    check(not menu:IsShown(), "a left-click does not open it")

    -- Moving away closes it; staying near keeps it.
    row:Fire("OnClick", "RightButton")
    row._l, row._r, row._b, row._t = 100, 500, 290, 310
    menu._l, menu._r, menu._b, menu._t = 288, 528, 306, 500
    MOCK.cursorX, MOCK.cursorY = 400, 400
    menu:Fire("OnUpdate", 0.1)
    check(menu:IsShown(), "over the menu: stays")
    MOCK.cursorX, MOCK.cursorY = 520, 280
    menu:Fire("OnUpdate", 0.1)
    check(menu:IsShown(), "a little off both: stays")
    MOCK.cursorX, MOCK.cursorY = 900, 100
    menu:Fire("OnUpdate", 0.1)
    check(not menu:IsShown(), "well away from both: gone")
    row:Fire("OnClick", "RightButton")
    row:Hide()
    menu:Fire("OnUpdate", 0.1)
    check(not menu:IsShown(), "the row hides: gone")
    row:Show()

    -- The other tabs open it too; a recruiter who left has nothing to pick.
    for _, view in ipairs({ "recruiters", "members", "activity", "promote" }) do
        UI.Show(view)
        check(UI.views[view].list ~= nil, "view " .. view)
    end
    local gone = UI.RankMenu("Gone-Mockrealm")
    check(#gone.items == 1 and gone.items[1].disabled, "not in the roster: a note")

    -- The game forbids a rank call to addons (seen on Forever): no Lua error,
    -- nothing changes. Said in chat, never "done", and greyed out after.
    readRoster()
    MOCK.forbidden.SetGuildMemberRank = true
    local mem = choices("Ini-Mockrealm")
    check(mem[2].ok, "before: the jump is offered")
    local setsBefore, reqs = #MOCK.rankSets, MOCK.rosterRequests
    resetOutput()
    check(G.SetRank("Ini-Mockrealm", 2) == false and #MOCK.rankSets == setsBefore, "forbidden: false, nothing changed")
    check(printed("own guild window"), "says the game keeps it to its own window")
    check(G.Refused("setRank") and not G.Refused("promote"), "remembers which call")
    mem = choices("Ini-Mockrealm")
    check(not mem[2].ok and mem[2].why:find("own guild window") and mem[3].ok, "the jump greyed out, one step still offered")
    MOCK.forbidden.GuildPromote = true
    resetOutput()
    check(G.Promote("Mem1-Mockrealm") == false and printed("own guild window"), "Promotions tab: the same")
    check(G.Refused("promote") and not choices("Mem1-Mockrealm")[2].ok, "promote remembered")
    resetOutput()
    check(G.Promote("Mem1-Mockrealm") == false and printed("own guild window"), "later clicks say so without calling")
    TALODDB.guildRefused.build = "older"
    check(not G.Refused("promote"), "a new game build: tried again")
    MOCK.forbidden = {}
    check(MOCK.rosterRequests == reqs, "a refused change asks for no roster")
    local n = #MOCK.promoted + #MOCK.demoted + #MOCK.rankSets
    wait(60)
    check(#MOCK.promoted + #MOCK.demoted + #MOCK.rankSets == n, "nothing from the tick")
end
