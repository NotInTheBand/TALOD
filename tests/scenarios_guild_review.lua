-- Guild pages, the send buttons on rows and in the conversation: a
-- right-click on a row button is the row's right-click (never a send), a
-- rank that cannot invite gets no send, a button whose action changed since
-- it was drawn sends nothing, labels say what the click sends, and the
-- guild page opened first fits the rank.
local scenarios, T = ...
local check, boot, slash, printed, plateAdd, resetOutput = T.check, T.boot, T.slash, T.printed, T.plateAdd, T.resetOutput

local function setup(iface, guild, opts)
    MOCK.SetGuild(guild)
    local ns = boot(iface or 11509, opts)
    MOCK.cvars.nameplateShowFriends = "1"
    return ns
end

local function wait(seconds)
    for _ = 1, math.ceil(seconds / 0.5) do MOCK.Tick(0.5) end
end

local function sent() return #MOCK.whispers, #MOCK.guildInvites end

local function rowFor(list, full)
    list._height = 400
    list:Draw()
    for _, r in ipairs(list.rows) do
        if r:IsShown() and r.item and r.item.full == full then return r end
    end
end

local function newbie()
    plateAdd("nameplate1", MOCK.Friend({ name = "Newbie", guid = "Player-1-N", level = 12 }))
    wait(5)
end

-- Style.List: a right-click on the row button runs the row's right-click,
-- a left-click the button's own action.
scenarios.guild_review_list_rowbutton_mouse = function()
    local ns = boot(11509)
    local Style = ns.Style
    local parent = CreateFrame("Frame", nil, UIParent)
    parent:SetSize(400, 300)
    local rowClicks, buttonClicks = {}, 0
    local list = Style.List(parent, { rowButtonWidth = 60,
        onClick = function(item, button) rowClicks[#rowClicks + 1] = item.key .. ":" .. tostring(button) end,
        rowButton = function(item) return { label = "Go", kind = "send", onClick = function() buttonClicks = buttonClicks + 1 end } end })
    list:SetItems({ { key = "a", text = "A" } })
    list._height = 300
    list:Draw()
    local row = list.rows[1]
    check(row and row.rowButton and row.rowButton:IsShown(), "row button drawn")
    row.rowButton:Fire("OnClick", "RightButton")
    check(buttonClicks == 0 and rowClicks[1] == "a:RightButton", "right-click on the button: the row's right-click only")
    row.rowButton:Fire("OnClick", "LeftButton")
    check(buttonClicks == 1 and #rowClicks == 1, "left-click: the button's action only")
    row.rowButton:Fire("OnClick", "MiddleButton")
    check(buttonClicks == 1 and #rowClicks == 1, "another mouse button: nothing")
end

-- Find (Era and Forever): a right-click on the row's send button skips, as
-- on the row; nothing is sent.
local function findRightClick(iface)
    local ns = setup(iface)
    local G, UI = ns.Guild, ns.GuildUI
    newbie()
    UI.Show("recruit")
    local row = rowFor(UI.views.recruit.list, "Newbie-Mockrealm")
    check(row and row.rowButton and row.rowButton:IsShown(), "Find row button")
    local w0, i0 = sent()
    row.rowButton:Fire("OnClick", "RightButton")
    local w1, i1 = sent()
    check(w1 == w0 and i1 == i0, iface .. ": right-click on the Find button sends nothing")
    local r = G.Recruit("Newbie-Mockrealm")
    check(r and r.status == "skipped", iface .. ": right-click on the button skips, like the row: " .. tostring(r and r.status))
end
scenarios.guild_review_find_button_rightclick_era = function() findRightClick(11509) end
scenarios.guild_review_find_button_rightclick_forever = function() findRightClick(16001) end

-- Invited (Era): a right-click on the row's send button forgets, as on the row.
scenarios.guild_review_invited_button_rightclick = function()
    local ns = setup(11509)
    local G, UI = ns.Guild, ns.GuildUI
    newbie()
    UI.Show("recruit")
    rowFor(UI.views.recruit.list, "Newbie-Mockrealm"):Fire("OnClick", "LeftButton")
    wait(10.5)
    UI.Show("invited")
    local row = rowFor(UI.views.invited.list, "Newbie-Mockrealm")
    check(row and row.rowButton and row.rowButton:IsShown() and row.rowButton.label:GetText() == "Invite", "Invite button once ready")
    local w0, i0 = sent()
    row.rowButton:Fire("OnClick", "RightButton")
    local w1, i1 = sent()
    check(w1 == w0 and i1 == i0, "right-click on the Invited button sends nothing")
    check(G.Recruit("Newbie-Mockrealm") == nil, "right-click on the button forgets, like the row")
end

-- A rank without the invite right: no send on Invited rows or in the
-- conversation, and Guild.SendOpener refuses.
local function noRight(iface)
    local ns = setup(iface)
    local G, UI = ns.Guild, ns.GuildUI
    G.Invite("Newbie-Mockrealm", { name = "Newbie", level = 5 })
    MOCK.FireEvent("CHAT_MSG_WHISPER", "sure!", "Newbie-Mockrealm")
    local r = G.Recruit("Newbie-Mockrealm")
    r.unsent = "Join us!"
    UI.Show("invited")
    UI.state.chat = "Newbie-Mockrealm"
    UI.Refresh()
    check(UI.InvitedAction("Newbie-Mockrealm") ~= nil, iface .. ": with the right, a send is offered")
    MOCK.guild.can.invite = false
    UI.Refresh()
    local v = UI.views.invited
    check(UI.InvitedAction("Newbie-Mockrealm") == nil, iface .. ": without the right, no action")
    local row = rowFor(v.list, "Newbie-Mockrealm")
    check(row and not (row.rowButton and row.rowButton:IsShown()), iface .. ": no row button")
    check(not v.act:IsShown(), iface .. ": no send in the conversation")
    check(not (v.invite and v.invite:IsShown()), iface .. ": no Invite again")
    local w0, i0 = sent()
    local ok, why = G.SendOpener("Newbie-Mockrealm")
    local w1, i1 = sent()
    check(ok == false and why == "rank" and w1 == w0 and i1 == i0, iface .. ": SendOpener refuses: " .. tostring(why))
    check(r.unsent == "Join us!", iface .. ": the opener stays unsent")
    MOCK.guild.can.invite = true
    ok = G.SendOpener("Newbie-Mockrealm")
    check(ok == true and #MOCK.whispers == w0 + 1, iface .. ": with the right again, one whisper")
end
scenarios.guild_review_no_invite_right_era = function() noRight(11509) end
scenarios.guild_review_no_invite_right_forever = function() noRight(16001) end

-- Era: a "Send message" button drawn before the record moved on (the
-- invite became ready) sends nothing and is drawn again.
scenarios.guild_review_invited_button_stale = function()
    local ns = setup(11509)
    local G, UI = ns.Guild, ns.GuildUI
    newbie()
    UI.Show("recruit")
    rowFor(UI.views.recruit.list, "Newbie-Mockrealm"):Fire("OnClick", "LeftButton")
    local r = G.Recruit("Newbie-Mockrealm")
    r.unsent = "Join us!"
    UI.Show("invited")
    local v = UI.views.invited
    local row = rowFor(v.list, "Newbie-Mockrealm")
    check(row.rowButton.label:GetText() == "Send message", "drawn as Send message: " .. tostring(row.rowButton.label:GetText()))
    local stale = row.rowButton:GetScript("OnClick")
    UI.state.chat = "Newbie-Mockrealm"
    UI.Refresh()
    check(v.act:IsShown() and v.act.label:GetText() == "Send message", "conversation button: Send message")
    -- The message went out meanwhile (no redraw yet): the button's action is gone.
    r.unsent = nil
    local w0, i0 = sent()
    v.act:Fire("OnClick", "LeftButton")
    local w1, i1 = sent()
    check(w1 == w0 and i1 == i0, "conversation button drawn as Send message: nothing sent")
    check(not v.act:IsShown(), "conversation button drawn again (no action now)")
    -- The invite becomes ready: the row button drawn before still says Send message.
    wait(10.5)
    check(UI.InvitedAction("Newbie-Mockrealm").label == "Invite", "the action is now Invite")
    stale(row.rowButton, "LeftButton")
    local w2, i2 = sent()
    check(w2 == w0 and i2 == i0, "row button drawn as Send message: no invite, nothing sent")
    v:Pane()
    check(v.act:IsShown() and v.act.label:GetText() == "Invite", "conversation button: Invite")
    v.act:Fire("OnClick", "LeftButton")
    local _, i3 = sent()
    check(i3 == i0 + 1, "the redrawn button: one invite")
end

-- Era, Delayed invite off: the Find button says it whispers and invites.
scenarios.guild_review_find_label_delayed_off = function()
    local ns = setup(11509)
    local UI = ns.GuildUI
    newbie()
    UI.Show("recruit")
    local list = UI.views.recruit.list
    local row = rowFor(list, "Newbie-Mockrealm")
    check(row.rowButton.label:GetText() == "Whisper", "delayed on: Whisper")
    ns.DB().guildDelayedInvite = false
    UI.Refresh()
    row = rowFor(list, "Newbie-Mockrealm")
    check(row.rowButton.label:GetText() == "Whisper + invite", "delayed off: " .. tostring(row.rowButton.label:GetText()))
    local w0, i0 = sent()
    row.rowButton:Fire("OnClick", "LeftButton")
    local w1, i1 = sent()
    check(w1 == w0 + 1 and i1 == i0 + 1, "the click: one whisper and one invite, as the label says")
    ns.DB().guildWhisper = false
    UI.Refresh()
    plateAdd("nameplate2", MOCK.Friend({ name = "Second", guid = "Player-1-S", level = 14 }))
    wait(5)
    row = rowFor(list, "Second-Mockrealm")
    check(row and row.rowButton.label:GetText() == "Invite", "no whisper: Invite")
end

-- The guild page opened first: Members for a rank that cannot invite.
scenarios.guild_review_first_guild_page = function()
    local ns = setup(11509)
    MOCK.guild.can.invite = false
    check(ns.Nav.LastGuildPage() == "members" and ns.GuildUI.LastGuildPage() == "members", "no invite right: Members first")
    slash("guild")
    check(TALODMembersWindow and TALODMembersWindow:IsShown(), "bare guild opens Members")
    check(not (TALODGuildWindow and TALODGuildWindow:IsShown()), "not the Recruit page")

    ns = setup(11509)
    check(ns.Nav.LastGuildPage() == "recruit", "with the right: Recruit first")
    MOCK.guild.can.invite = false
    ns.Nav.Go("members")
    check(ns.Nav.LastGuildPage() == "members", "used last: Members")
    MOCK.guild.can.invite = true
    check(ns.Nav.LastGuildPage() == "members", "the page used last wins")
end

-- Minimap Shift + right-click for a rank that cannot invite: Members.
scenarios.guild_review_minimap_guild_page = function()
    Minimap = CreateFrame("Frame", "Minimap", UIParent)
    Minimap:SetSize(140, 140)
    Minimap._cx, Minimap._cy = 1000, 700
    Minimap.GetEffectiveScale = function() return 1 end
    local ns = setup(11509)
    MOCK.guild.can.invite = false
    local b = TALODMinimapButton
    check(b ~= nil, "minimap button")
    MOCK.shift = true
    b:Fire("OnClick", "RightButton")
    MOCK.shift = nil
    check(ns.Nav.CurrentPage() == "members" and TALODMembersWindow:IsShown(), "Shift + right-click: Members")
    Minimap = nil
end

-- Era: "Invite again" in the conversation whenever you are talking and
-- they did not say no, also when the row has another action; one invite
-- per click, no whisper.
scenarios.guild_review_invite_again = function()
    local ns = setup(11509)
    local G, UI = ns.Guild, ns.GuildUI
    newbie()
    ns.DB().guildDelayedInvite = false
    UI.Show("recruit")
    rowFor(UI.views.recruit.list, "Newbie-Mockrealm"):Fire("OnClick", "LeftButton")
    MOCK.FireEvent("CHAT_MSG_SYSTEM", "You have invited Newbie to join your guild.")
    MOCK.FireEvent("CHAT_MSG_WHISPER", "sure!", "Newbie-Mockrealm")
    -- Past the guard against a double click.
    MOCK.now = MOCK.now + 61
    wait(11)
    local r = G.Recruit("Newbie-Mockrealm")
    check(r and r.status == "invited", "invited: " .. tostring(r and r.status))
    -- Their opener did not go: the row's action is Send message.
    r.unsent = "Join us!"
    UI.Show("invited")
    UI.state.chat = "Newbie-Mockrealm"
    UI.Refresh()
    local v = UI.views.invited
    check(v.act:IsShown() and v.act.label:GetText() == "Send message", "the row's action: Send message")
    check(v.invite and v.invite:IsShown() and v.invite.kind == "send", "Invite again beside it (send button)")
    local w0, i0 = sent()
    v.invite:Fire("OnClick", "LeftButton")
    local w1, i1 = sent()
    check(w1 == w0 and i1 == i0 + 1, "Invite again: one invite, no whisper")
    -- Said no: no Invite again.
    G.SaidNo("Newbie-Mockrealm", true)
    UI.Refresh()
    check(not v.invite:IsShown(), "said no: no Invite again")
    -- Forever never builds it.
    ns = setup(16001)
    check(ns.GuildUI.views.invited == nil or ns.GuildUI.views.invited.invite == nil, "Forever: no Invite again")
end

-- Look up: why no /who went out.
scenarios.guild_review_lookup_messages = function()
    local ns = setup(11509)
    local G, UI = ns.Guild, ns.GuildUI
    G.Invite("Newbie-Mockrealm", { name = "Newbie", level = 5 })
    MOCK.FireEvent("CHAT_MSG_WHISPER", "sure!", "Newbie-Mockrealm")
    wait(10)
    UI.Show("invited")
    UI.state.chat = "Newbie-Mockrealm"
    UI.Refresh()
    local v = UI.views.invited
    local q = #MOCK.whoQueries
    v.lookup:Fire("OnClick", "LeftButton")
    check(#MOCK.whoQueries == q + 1, "first Look up: one /who")
    resetOutput()
    v.lookup:Fire("OnClick", "LeftButton")
    check(#MOCK.whoQueries == q + 1 and printed("has not answered yet"), "a search still out: says so")
    MOCK.FireEvent("WHO_LIST_UPDATE")
    resetOutput()
    v.lookup:Fire("OnClick", "LeftButton")
    check(#MOCK.whoQueries == q + 1 and printed("one search every few seconds"), "the pace wait: says so")
    wait(6)
    local saved = C_FriendList
    local savedSend = SendWho
    C_FriendList, SendWho = nil, nil
    resetOutput()
    v.lookup:Fire("OnClick", "LeftButton")
    C_FriendList, SendWho = saved, savedSend
    check(#MOCK.whoQueries == q + 1 and printed("offers no /who"), "no /who in this client: says so")
end
