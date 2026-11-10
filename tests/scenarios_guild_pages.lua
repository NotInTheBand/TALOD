-- The Guild pages (GuildUI.lua): Recruit (Find, Invited, Results) and
-- Members (Roster with Basics / Activity / Shared, Promotions, Log,
-- Sharing). A click on an Invited row only selects; the send is the row's
-- button (and the same button in the conversation), one click = what a row
-- click sent before. Find rows still send on a click. Old command words
-- land on the same content; the reply notice opens Invited on Replied.
local scenarios, T = ...
local check, boot, slash, printed, plateAdd, resetOutput = T.check, T.boot, T.slash, T.printed, T.plateAdd, T.resetOutput

local KEY = "Brave Souls-Mockrealm"

local function setup(iface, guild, opts)
    MOCK.SetGuild(guild)
    local ns = boot(iface or 11509, opts)
    MOCK.cvars.nameplateShowFriends = "1"
    return ns
end

local function wait(seconds)
    for _ = 1, math.ceil(seconds / 0.5) do MOCK.Tick(0.5) end
end

local function data() return TALODDB.guild.guilds[KEY] end

local function sent() return #MOCK.whispers, #MOCK.guildInvites, #(MOCK.partyInvites or {}) end

local function rowFor(list, full)
    list._height = 400
    list:Draw()
    for _, r in ipairs(list.rows) do
        if r:IsShown() and r.item and r.item.full == full then return r end
    end
end

local function hideAll()
    if TALODGuildWindow then TALODGuildWindow:Hide() end
    if TALODMembersWindow then TALODMembersWindow:Hide() end
end

-- Classic Era: a click on an Invited row sends nothing; its Invite button
-- sends the one invite the click used to; the conversation's button too.
scenarios.guild_pages_invited_era = function()
    local ns = setup(11509)
    local G, UI = ns.Guild, ns.GuildUI
    plateAdd("nameplate1", MOCK.Friend({ name = "Newbie", guid = "Player-1-N", level = 12 }))
    plateAdd("nameplate2", MOCK.Friend({ name = "Second", guid = "Player-1-S", level = 14 }))
    wait(5)

    -- Find: a row click is still the one-click whisper, and the row carries the send mark.
    UI.Show("recruit")
    local find = UI.views.recruit
    check(TALODGuildWindow:IsShown() and find:IsShown(), "Recruit page on Find")
    check(find.delayed and find.delayed:IsShown(), "Era: Delayed switch")
    check(find.nextStep.label:GetText():find("Next invite", 1, true), "Era: Next invite")
    local row = rowFor(find.list, "Newbie-Mockrealm")
    check(row and row.rowButton and row.rowButton:IsShown() and row.rowButton.kind == "send", "Find row: send button")
    local w0, i0 = sent()
    row:Fire("OnClick", "LeftButton")
    local w1, i1 = sent()
    check(w1 == w0 + 1 and i1 == i0, "Find row click: one whisper (delayed invite)")
    -- The Find row button: the same click.
    row = rowFor(find.list, "Second-Mockrealm")
    row.rowButton:Fire("OnClick", "LeftButton")
    local w2, i2 = sent()
    check(w2 == w1 + 1 and i2 == i1, "Find row button: the same one whisper")
    wait(10.5)

    -- Invited: Newbie's delayed invite is ready.
    UI.Show("invited")
    local v = UI.views.invited
    check(TALODGuildWindow:IsShown() and v:IsShown() and UI.state.invitedChip == "all", "Invited on All")
    row = rowFor(v.list, "Newbie-Mockrealm")
    check(row, "Newbie listed")
    local w, i = sent()
    row:Fire("OnClick", "LeftButton")
    local wa, ia = sent()
    check(wa == w and ia == i and UI.state.chat == "Newbie-Mockrealm", "row click: selected, nothing sent")
    row = rowFor(v.list, "Newbie-Mockrealm")
    check(row.item.selected or row.selBar == nil or row.selBar:IsShown(), "selected row drawn")
    check(row.rowButton and row.rowButton:IsShown() and row.rowButton.label:GetText() == "Invite" and row.rowButton.kind == "send",
        "row button reads Invite: " .. tostring(row.rowButton and row.rowButton.label:GetText()))
    check(v.act:IsShown() and v.act.label:GetText() == "Invite" and v.act.kind == "send", "the conversation has the same button")
    row.rowButton:Fire("OnClick", "LeftButton")
    local wb, ib = sent()
    check(wb == w and ib == i + 1 and MOCK.guildInvites[#MOCK.guildInvites] == "Newbie", "row button: one invite, no whisper")
    -- A second click on the row (or the button again at once) sends nothing more.
    row = rowFor(v.list, "Newbie-Mockrealm")
    row:Fire("OnClick", "LeftButton")
    check(select(2, sent()) == ib, "row click after: nothing")

    -- The conversation's button: Second's invite, the one the row click would have sent.
    rowFor(v.list, "Second-Mockrealm"):Fire("OnClick", "LeftButton")
    check(UI.state.chat == "Second-Mockrealm" and v.act:IsShown() and v.act.label:GetText() == "Invite", "pane button for Second")
    v.act:Fire("OnClick", "LeftButton")
    local wc, ic = sent()
    check(wc == wb and ic == ib + 1 and MOCK.guildInvites[#MOCK.guildInvites] == "Second", "pane button: one invite")

    -- Not invited (the game refused it): invite only, no second whisper, as the row click did.
    local r = data().recruits["Newbie-Mockrealm"]
    r.status, r.ack = "uninvited", nil
    MOCK.now = MOCK.now + 120
    wait(61)
    ns.Data.Bump("guild")
    UI.Refresh()
    row = rowFor(v.list, "Newbie-Mockrealm")
    check(row.rowButton:IsShown() and row.rowButton.label:GetText() == "Invite", "uninvited: Invite")
    row.rowButton:Fire("OnClick", "LeftButton")
    local wd, id = sent()
    check(wd == wc and id == ic + 1, "uninvited: one invite, no whisper")

    -- Right-click still forgets; the check report opens in the report window.
    local shown, real = nil, ns.Probe.ShowText
    ns.Probe.ShowText = function(text) shown = text end
    v.check:Fire("OnClick", "LeftButton")
    ns.Probe.ShowText = real
    check(shown and shown:find("invites in the last hour", 1, true), "Check invites: the report window")
    rowFor(v.list, "Second-Mockrealm"):Fire("OnClick", "RightButton")
    check(G.Recruit("Second-Mockrealm") == nil, "right-click forgets")
    local we, ie = sent()
    check(we == wd and ie == id, "nothing sent by the list since")
end

-- Forever: one layout, Next whisper, no Delayed switch, no invite queue;
-- the /ginvite command is copied, never typed or sent for you.
scenarios.guild_pages_invited_forever = function()
    local ns = setup(16001)
    local G, UI = ns.Guild, ns.GuildUI
    check(G.WhisperFirst, "whisper-first on Forever")
    plateAdd("nameplate1", MOCK.Friend({ name = "Alpha", guid = "Player-1-A", level = 12 }))
    plateAdd("nameplate2", MOCK.Friend({ name = "Gamma", guid = "Player-1-G", level = 12 }))
    wait(6)
    UI.Show("recruit")
    local find = UI.views.recruit
    check(find.delayed == nil and find.nextStep.label:GetText() == "Next whisper", "Forever: Next whisper, no Delayed")
    local row = rowFor(find.list, "Alpha-Mockrealm")
    check(row.rowButton:IsShown() and row.rowButton.label:GetText() == "Whisper", "Find row button: Whisper")
    local w0, i0 = sent()
    row:Fire("OnClick", "LeftButton")
    wait(2)
    local w1, i1 = sent()
    check(w1 == w0 + 1 and i1 == i0, "Find row click: one whisper, never an invite")
    rowFor(find.list, "Gamma-Mockrealm").rowButton:Fire("OnClick", "LeftButton")
    wait(2)
    local w2, i2 = sent()
    check(w2 == w1 + 1 and i2 == i1, "Find row button: one whisper")

    -- Invited: asked rows give the command to copy through their button only.
    UI.Show("invited")
    local v = UI.views.invited
    MOCK.popup, MOCK.popupData = nil, nil
    row = rowFor(v.list, "Alpha-Mockrealm")
    row:Fire("OnClick", "LeftButton")
    check(MOCK.popup == nil and select(1, sent()) == w2 and UI.state.chat == "Alpha-Mockrealm", "row click: selected, no copy box, nothing sent")
    row = rowFor(v.list, "Alpha-Mockrealm")
    check(row.rowButton:IsShown() and row.rowButton.label:GetText() == "/ginvite" and row.rowButton.kind == "send", "row button: /ginvite")
    check(v.typed and v.typed:IsShown() and not v.act:IsShown(), "the conversation shows the typed-invite box instead")
    row.rowButton:Fire("OnClick", "LeftButton")
    check(MOCK.popup == "TALOD_COPY" and MOCK.popupData == "/ginvite Alpha", "copy box: " .. tostring(MOCK.popupData))
    MOCK.popup = nil
    v.copyInvite:Fire("OnClick", "LeftButton")
    check(MOCK.popupData == "/ginvite Alpha", "the box's copy button: the same command")
    local w3, i3 = sent()
    check(w3 == w2 and i3 == i2, "copying sends nothing")

    -- An opener that never went out: the row's button sends it, one whisper.
    local r = data().recruits["Gamma-Mockrealm"]
    r.unsent, r.whisper = "Hi Gamma!", nil
    ns.Data.Bump("guild")
    UI.Refresh()
    row = rowFor(v.list, "Gamma-Mockrealm")
    check(row.rowButton.label:GetText() == "Send message", "unsent opener: Send message")
    row:Fire("OnClick", "LeftButton")
    check(select(1, sent()) == w3, "row click: nothing")
    check(v.act:IsShown() and v.act.label:GetText() == "Send message", "pane: Send message")
    row = rowFor(v.list, "Gamma-Mockrealm")
    row.rowButton:Fire("OnClick", "LeftButton")
    local w4, i4 = sent()
    check(w4 == w3 + 1 and i4 == i3 and MOCK.whispers[w4].text == "Hi Gamma!", "row button: that one whisper")
    v.act:Fire("OnClick", "LeftButton")
    check(select(1, sent()) == w4, "sent once: nothing left to send")

    -- The game's own line makes it invited; no button then.
    MOCK.FireEvent("CHAT_MSG_SYSTEM", "You have invited Alpha to join your guild.")
    UI.Refresh()
    row = rowFor(v.list, "Alpha-Mockrealm")
    check(not (row.rowButton and row.rowButton:IsShown()), "confirmed: no button")
    check(#MOCK.guildInvites == 0, "Forever: no invite ever called")
end

-- Find: the name box and Target are one click = one whisper or invite;
-- the Hands Free line opens the last presses.
scenarios.guild_pages_find_tools = function()
    local ns = setup(11509)
    local G, UI = ns.Guild, ns.GuildUI
    TALODDB.guildDelayedInvite = false
    UI.Show("recruit")
    local v = UI.views.recruit
    v.nameBox:SetText("Typed")
    local w, i = sent()
    v.inviteName:Fire("OnClick", "LeftButton")
    local w1, i1 = sent()
    check(w1 == w + 1 and i1 == i + 1 and MOCK.guildInvites[i1] == "Typed", "name box: whisper + invite in one click (delay off)")
    check(v.nameBox:GetText() == "", "box cleared once sent")
    v.inviteName:Fire("OnClick", "LeftButton")
    check(select(1, sent()) == w1 and printed("type a name"), "empty box: nothing sent")
    resetOutput()
    v.inviteTarget:Fire("OnClick", "LeftButton")
    check(select(1, sent()) == w1 and printed("target a player"), "no target: nothing sent")
    T.setTarget(MOCK.Friend({ name = "Targy", guid = "Player-1-T", level = 20 }))
    v.inviteTarget:Fire("OnClick", "LeftButton")
    local w2, i2 = sent()
    check(w2 == w1 + 1 and i2 == i1 + 1 and MOCK.guildInvites[i2] == "Targy", "target: one whisper + invite")

    -- Hands Free: the line opens the last presses and why it paused.
    G.SetHandsFree(true)
    UI.Refresh()
    check(not v.presses:IsShown(), "closed")
    v.statusButton:Fire("OnClick", "LeftButton")
    check(v.presses:IsShown() and v.presses.text:GetText():find("No click", 1, true), "opened: " .. tostring(v.presses.text:GetText()))
    local lines = UI.PressLines()
    check(#lines <= 10, "short")
    v.statusButton:Fire("OnClick", "LeftButton")
    check(not v.presses:IsShown(), "closed again")
    check(select(1, sent()) == w2, "the status line sends nothing")
end

-- Tool options bind once, on their page; the consent on Sharing; the
-- mini window's quick switch in the Recruit title bar.
local function bindings(iface)
    local ns = setup(iface)
    ns.GuildUI.Show("recruit")
    ns.GuildUI.Show("roster")
    ns.GuildUI.Show("invited")
    ns.GuildUI.Show("recruit")
    local got = {}
    for _, b in ipairs(ns.GuildUI.bound) do got[#got + 1] = b.key .. "|" .. b.kind .. "|" .. b.where end
    check(#got > 0, "bindings told")
    local keys = {}
    for _, b in ipairs(got) do
        local key = b:match("^([^|]+)")
        check(not keys[key], "bound once: " .. key)
        keys[key] = b
    end
    return keys
end

scenarios.guild_pages_bindings = function()
    local keys = bindings(11509)
    for _, key in ipairs({ "guildWhisper", "guildDelayedInvite", "guildHandsFree", "guildWhoZone", "guildRecruitMinLevel",
        "guildRecruitMaxLevel", "guildRecruitHideClass", "guildRecruitHideScript", "guildMessages", "guildMessageIndex" }) do
        check(keys[key] == key .. "|tool|recruit/find", "tool option on Find: " .. key .. " = " .. tostring(keys[key]))
    end
    check(keys.guildChatDays == "guildChatDays|tool|members/roster#Activity", "guildChatDays on Roster Activity: " .. tostring(keys.guildChatDays))
    check(keys.guildShare == "guildShare|consent|members/sharing", "consent on Sharing")
    check(keys["guildShare.recruiting"] == "guildShare.recruiting|consent|members/sharing", "each category's consent")
    check(keys.guildMiniShown == "guildMiniShown|quick|recruit", "mini window quick switch in the Recruit title bar")
    -- Forever has no Delayed switch: no binding for it.
    keys = bindings(16001)
    check(keys.guildDelayedInvite == nil and keys.guildWhisper, "Forever: no Delayed binding")
end

-- Officer views: a plain member sees Basics only; the rank menu on every Roster view.
scenarios.guild_pages_roster_views = function()
    local ns = setup(11509, { rankName = "Member", rankIndex = 3, can = { invite = true },
        roster = { { name = "Alpha", rank = 0, level = 60, online = true }, { name = "Ini", rank = 4, level = 5, online = true } } })
    local UI = ns.GuildUI
    MOCK.FireEvent("GUILD_ROSTER_UPDATE")
    MOCK.Tick(2.1)
    check(ns.Guild.IsOfficer() == false, "not an officer")
    UI.Show("roster")
    check(TALODMembersWindow:IsShown() and not TALODGuildWindow:IsShown(), "Members page, one window")
    check(table.concat(UI.RosterViews(), ",") == "roster", "Basics only: " .. table.concat(UI.RosterViews(), ","))
    for _, sw in pairs(TALODMembersWindow.switches or {}) do check(not sw:IsShown(), "no view switch") end
    for _, view in ipairs({ "activity", "members" }) do
        UI.Show(view)
        check(UI.state.view == "roster" and not UI.views[view]:IsShown(), view .. " refused for a member")
    end

    -- An officer: three views, a switch, the rank menu on each.
    ns = setup(11509, { roster = { { name = "Alpha", rank = 0, level = 60, online = true }, { name = "Ini", rank = 4, level = 5, online = true } } })
    UI = ns.GuildUI
    MOCK.FireEvent("GUILD_ROSTER_UPDATE")
    MOCK.Tick(2.1)
    UI.Show("roster")
    check(table.concat(UI.RosterViews(), ",") == "roster,activity,members", "officer: " .. table.concat(UI.RosterViews(), ","))
    local switch
    for _, sw in pairs(TALODMembersWindow.switches or {}) do if sw:IsShown() then switch = sw end end
    check(switch and #switch.buttons == 3, "view switch with three views")
    for _, view in ipairs({ "roster", "activity", "members" }) do
        for _, b in ipairs(switch.buttons) do if b.key == view then b:Fire("OnClick", "LeftButton") end end
        check(UI.state.view == view and UI.views[view]:IsShown(), "view " .. view)
        local list = UI.views[view].list
        list:SetItems({ { full = "Ini-Mockrealm", text = "Ini" } })
        local row = rowFor(list, "Ini-Mockrealm")
        MOCK.cursorX, MOCK.cursorY = 300, 300
        if TALODContextMenu then TALODContextMenu:Hide() end
        row:Fire("OnClick", "RightButton")
        check(TALODContextMenu and TALODContextMenu:IsShown() and TALODContextMenu.title:GetText():find("Ini"), "rank menu on " .. view)
        TALODContextMenu:Hide()
    end
    -- The Roster tab reopens on the view used last.
    UI.Show("log")
    for _, tab in ipairs(TALODMembersWindow.tabs) do if tab.key == "roster" then tab:Fire("OnClick", "LeftButton") end end
    check(UI.state.view == "members", "Roster tab: the view used last")
    -- Title bar: Refresh roster and Ask members (officers).
    local before = MOCK.rosterRequests
    TALODMembersWindow.refresh:Fire("OnClick", "LeftButton")
    check(MOCK.rosterRequests == before + 1, "Refresh roster from the title bar")
    check(TALODMembersWindow.ask:IsShown() and UI.views.members.ask == TALODMembersWindow.ask, "Ask members in the title bar")
end

-- Every old guild word lands where it did; the page words too.
scenarios.guild_pages_commands = function()
    local ns = setup(11509)
    local UI = ns.GuildUI
    local function land(words, page, view)
        hideAll()
        slash(words)
        local f = page == "recruit" and TALODGuildWindow or TALODMembersWindow
        check(f and f:IsShown() and UI.state.view == view, words .. " -> " .. page .. "/" .. view .. " (got " .. tostring(UI.state.view) .. ")")
    end
    land("guild recruit", "recruit", "recruit")
    land("guild invited", "recruit", "invited")
    land("guild replies", "recruit", "invited")
    check(UI.state.invitedChip == "replied", "replies: the Replied filter")
    land("guild recruiters", "recruit", "recruiters")
    land("guild roster", "members", "roster")
    land("guild activity", "members", "activity")
    land("guild promote", "members", "promote")
    land("guild promotions", "members", "promote")
    land("guild log", "members", "log")
    land("guild members", "members", "members")
    land("guild sharing", "members", "sharing")
    land("g invited", "recruit", "invited")
    -- The new words (through the page list when there is one, else these windows).
    -- A page word alone reopens the page where it was left.
    land("recruit", "recruit", "invited")
    land("recruit find", "recruit", "recruit")
    land("recruit invited", "recruit", "invited")
    land("recruit results", "recruit", "recruiters")
    land("members", "members", "sharing")
    land("members roster", "members", "roster")
    land("members promotions", "members", "promote")
    land("members log", "members", "log")
    land("members sharing", "members", "sharing")
    land("members activity", "members", "activity")
    land("members shared", "members", "members")
    land("guild shared", "members", "members")
    -- Bare guild: the page used last, and again closes it.
    hideAll()
    slash("guild")
    check(TALODMembersWindow:IsShown(), "guild: the page used last (Members)")
    slash("guild")
    check(not TALODMembersWindow:IsShown(), "guild again: closed")
    check(ns.RecruitUI.LastGuildPage() == "members", "LastGuildPage")

    -- Page module contract.
    hideAll()
    check(ns.RecruitUI.ShowPage("invited", "Replied") and UI.state.view == "invited" and UI.state.invitedChip == "replied", "ShowPage invited/Replied")
    check(ns.RecruitUI.ShowPage("results") and UI.state.view == "recruiters", "ShowPage results")
    check(ns.MembersUI.ShowPage("roster", "Activity") and UI.state.view == "activity", "ShowPage roster/Activity")
    check(ns.MembersUI.ShowPage("roster", "Shared") and UI.state.view == "members", "ShowPage roster/Shared")
    check(ns.MembersUI.ShowPage("roster", "Basics") and UI.state.view == "roster", "ShowPage roster/Basics")
    check(ns.MembersUI.ShowPage("promotions") and UI.state.view == "promote", "ShowPage promotions")
    check(ns.RecruitUI.PageHidden() == false and ns.MembersUI.PageHidden() == false, "shown to a rank that may invite")
    MOCK.guild.can.invite = false
    check(ns.RecruitUI.PageHidden() == true, "Recruit hidden from a rank that cannot invite")
    MOCK.guild.can.invite = true

    -- The other words keep doing what they do.
    slash("guild mini")
    check(TALODDB.guildMiniShown == true and TALODGuildMini and TALODGuildMini:IsShown(), "mini")
    slash("guild mini")
    check(TALODDB.guildMiniShown == false, "mini again")
    slash("guild who")
    check(#MOCK.whoQueries == 1, "who: one search")
    slash("guild handsfree")
    check(TALODDB.guildHandsFree == true, "handsfree on")
    resetOutput()
    slash("guild handsfree why")
    check(printed("Hands Free"), "handsfree why")
    slash("guild handsfree")
    check(TALODDB.guildHandsFree == false, "handsfree off")
    local w = #MOCK.whispers
    slash("guild invite Named")
    check(#MOCK.whispers == w + 1, "invite <name>: one whisper")
    slash("guild pace")
    local shown, real = nil, ns.Probe.ShowText
    ns.Probe.ShowText = function(text) shown = text end
    slash("guild check")
    ns.Probe.ShowText = real
    check(shown and shown:find("invites in the last hour", 1, true), "check: the report window")
end

-- The reply notice opens Recruit › Invited on Replied with the conversation.
scenarios.guild_pages_reply_notice = function()
    local ns = setup(11509)
    local G, UI = ns.Guild, ns.GuildUI
    G.Invite("Newbie-Mockrealm", { name = "Newbie", level = 5 })
    G.Invite("Other-Mockrealm", { name = "Other", level = 5 })
    MOCK.FireEvent("CHAT_MSG_WHISPER", "sure!", "Newbie-Mockrealm")
    check(UI.notice and UI.notice:IsShown(), "notice shown")
    local w, i = sent()
    UI.notice:Fire("OnClick", "LeftButton")
    check(TALODGuildWindow:IsShown() and UI.state.view == "invited" and UI.state.invitedChip == "replied", "Invited on Replied")
    check(UI.state.chat == "Newbie-Mockrealm" and not UI.notice:IsShown(), "their conversation, read")
    local v = UI.views.invited
    local names = {}
    for _, item in ipairs(v.list.items) do if item.full then names[#names + 1] = item.full end end
    check(#names == 1 and names[1] == "Newbie-Mockrealm", "only who replied: " .. table.concat(names, ","))
    check(v.box:IsShown() and v.party:IsShown() and v.report:IsShown(), "reply box and the buttons as before")
    local w2, i2 = sent()
    check(w2 == w and i2 == i, "opening sends nothing")
    -- The tab shows unread replies while you are elsewhere.
    UI.Show("recruit")
    MOCK.FireEvent("CHAT_MSG_WHISPER", "hello?", "Newbie-Mockrealm")
    UI.Refresh()
    check(TALODGuildWindow.tabs[2].tag and TALODGuildWindow.tabs[2].tag:IsShown(), "unread tag on Invited")
    local st = ns.RecruitUI.PageStatus()
    check(st and st.text:find("1 reply", 1, true) and st.tone == "accent", "page status: " .. tostring(st and st.text))
end

-- Selecting Invited rows (with a conversation or not) sends nothing: no
-- /who, whisper or invite. The /who for one player is the Look up button's.
scenarios.guild_pages_select_sends_nothing = function()
    local ns = setup(11509)
    local G, UI = ns.Guild, ns.GuildUI
    G.Invite("Newbie-Mockrealm", { name = "Newbie", level = 5 })
    G.Invite("Other-Mockrealm", { name = "Other", level = 5 })
    G.Invite("Quiet-Mockrealm", { name = "Quiet", level = 5 })
    MOCK.FireEvent("CHAT_MSG_WHISPER", "sure!", "Newbie-Mockrealm")
    MOCK.FireEvent("CHAT_MSG_WHISPER", "maybe", "Other-Mockrealm")
    wait(30)
    local function counts() return #MOCK.whispers, #MOCK.guildInvites, #MOCK.whoQueries end
    local w, i, q = counts()
    UI.Show("invited")
    local v = UI.views.invited
    for _ = 1, 2 do
        for _, full in ipairs({ "Newbie-Mockrealm", "Other-Mockrealm", "Quiet-Mockrealm" }) do
            local row = rowFor(v.list, full)
            check(row, full .. " listed")
            row:Fire("OnClick", "LeftButton")
            check(UI.state.chat == full, "selected " .. full)
            local w2, i2, q2 = counts()
            check(w2 == w and i2 == i and q2 == q, "selecting " .. full .. " sends nothing")
        end
    end
    wait(5)
    check(select(3, counts()) == q, "nothing later from a timer")
    -- The explicit Look up: one /who for that one name.
    rowFor(v.list, "Newbie-Mockrealm"):Fire("OnClick", "LeftButton")
    check(v.lookup and v.lookup:IsShown() and v.lookup.kind == "send", "Look up in the conversation (send)")
    v.lookup:Fire("OnClick", "LeftButton")
    local w3, i3, q3 = counts()
    check(q3 == q + 1 and MOCK.whoQueries[#MOCK.whoQueries] == 'n-"Newbie"' and w3 == w and i3 == i,
        "Look up: one /who, nothing else")
    rowFor(v.list, "Quiet-Mockrealm"):Fire("OnClick", "LeftButton")
    check(not v.lookup:IsShown(), "no conversation: no Look up")
end

-- Both pages build and refresh in both looks.
local function bothPages(classic)
    local ns = setup(11509, nil, { db = { classicLook = classic or nil } })
    local UI = ns.GuildUI
    for _, view in ipairs({ "recruit", "invited", "recruiters", "roster", "activity", "members", "promote", "log", "sharing" }) do
        UI.Show(view)
        check(UI.state.view == view, (classic and "classic" or "ledger") .. ": " .. view)
        local v = UI.views[view]
        check(v:IsShown(), view .. " shown")
        if v.Footer then v:Footer() end
    end
    check(TALODGuildWindow.miniButton and TALODMembersWindow.refresh, "title bar buttons")
end
scenarios.guild_pages_ledger = function() bothPages(false) end
scenarios.guild_pages_classic = function() bothPages(true) end
