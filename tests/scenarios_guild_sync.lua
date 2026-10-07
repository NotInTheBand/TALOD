-- Guild sharing (GuildSync.lua): consent, officer ranks, member data to
-- officers by whisper, promotion rules to members, message pieces.
local scenarios, T = ...
local check, boot, printed, resetOutput = T.check, T.boot, T.printed, T.resetOutput

local KEY = "Brave Souls-Mockrealm"
local P = "TALODG"

local function roster()
    return {
        { name = "Boss", rank = 0, level = 60, online = true, classFile = "WARRIOR" },
        { name = "Offi", rank = 1, level = 60, online = true, classFile = "MAGE" },
        { name = "Pal", rank = 3, level = 45, online = true, classFile = "PALADIN" },
        { name = "Tester", rank = 3, level = 20, online = true, classFile = "WARRIOR" },
        { name = "Alt", rank = 4, level = 10, online = true, classFile = "PRIEST" },
    }
end

local function setup(rank)
    local names = { [0] = "Guild Master", [1] = "Officer", [2] = "Veteran", [3] = "Member", [4] = "Initiate" }
    local r = roster()
    r[4].rank = rank
    MOCK.SetGuild({ rankIndex = rank, rankName = names[rank], roster = r, can = { invite = rank <= 1, promote = rank <= 1 } })
    local ns = boot(11509)
    MOCK.FireEvent("GUILD_ROSTER_UPDATE")
    MOCK.Tick(2.1)
    return ns
end

local function data() return TALODDB.guild.guilds[KEY] end
local function msg(text, sender, dist) MOCK.FireEvent("CHAT_MSG_ADDON", P, text, dist or "GUILD", sender) end
local function pump(seconds) for _ = 1, math.ceil((seconds or 15) / 1.3) do MOCK.Tick(1.3) end end

-- Addon messages sent since `from`, as { text, dist, target }.
local function sent(from)
    local out = {}
    for i = (from or 0) + 1, #MOCK.addonMessages do
        local m = MOCK.addonMessages[i]
        if m[1] == P then out[#out + 1] = { text = m[2], dist = m[3], target = m[4] } end
    end
    return out
end
local function find(list, pattern)
    for _, m in ipairs(list) do if m.text:find(pattern) then return m end end
end

scenarios.guild_sync_member = function()
    local ns = setup(3)
    local Sync = ns.GuildSync
    check(Sync.IsOfficer("Offi-Mockrealm") and not Sync.IsOfficer("Pal-Mockrealm"), "default officers: ranks 0 and 1")
    check(Sync.OfficerSource() == "default", "no permission flags in the mock")

    -- Never answered: nothing goes out, one chat line says how to choose.
    resetOutput()
    msg("Q1", "Offi-Mockrealm")
    pump()
    check(#sent() == 0, "nothing sent before a Yes")
    check(printed("asked for your guild info"), "told once")

    -- Say Yes to everything, with data to share.
    TALODDB.skills = { ["Tester-Mockrealm"] = { current = {
        Mining = { rank = 120, max = 150, cat = "Professions" }, Cooking = { rank = 75, max = 150, cat = "Secondary Skills" },
        Swords = { rank = 100, max = 100, cat = "Weapon Skills" } }, log = {}, history = {} } }
    TALODDB.gear = { ["Alt-Mockrealm"] = {}, ["Stranger-Mockrealm"] = {} }
    data().recruits["Newbie-Mockrealm"] = { invited = MOCK.now, t = MOCK.now, status = "joined", by = "Tester-Mockrealm" }
    for _, c in ipairs(Sync.CATEGORIES) do Sync.SetConsent(c.key, true) end
    for _ = 1, 3 do MOCK.Tick(61) end
    local h7 = Sync.PlayTime()
    check(h7 > 0.03, "play time counted: " .. h7)

    -- The officer asks (again, a minute later): answers go to that officer only.
    local mark = #MOCK.addonMessages
    msg("Q1", "Offi-Mockrealm")
    pump()
    local out = sent(mark)
    local a0 = find(out, "^A0~")
    check(a0 and a0.dist == "WHISPER" and a0.target == "Offi-Mockrealm" and a0.text == "A0~recruiting,alts,prof,activity", "A0: " .. tostring(a0 and a0.text))
    check(find(out, "^A1~prof~20;Cooking:75:150;Mining:120:150$"), "professions (no weapon skills)")
    check(find(out, "^A1~alts~Alt%-Mockrealm$"), "alts in the guild only")
    check(find(out, "^A1~recruiting~Newbie%-Mockrealm:%d+:joined:0$"), "recruiting")
    check(find(out, "^A1~activity~[%d.]+:[%d.]+:1$"), "activity")
    for _, m in ipairs(out) do check(m.dist == "WHISPER" and m.target == "Offi-Mockrealm", "never to the whole guild: " .. m.text) end

    -- Not an officer: no answer. Asked again too soon: no answer.
    mark = #MOCK.addonMessages
    msg("Q1", "Pal-Mockrealm")
    msg("Q1", "Offi-Mockrealm")
    pump()
    check(#sent(mark) == 0, "no answer to a member or a repeat within a minute")

    -- Officer ranks: only the guild master can set them.
    msg("O1~0,3", "Offi-Mockrealm")
    check(Sync.OfficerSource() == "default", "O1 from an officer ignored")
    msg("O1~0,3", "Boss-Mockrealm")
    check(Sync.OfficerSource() == "gm" and Sync.IsOfficer("Pal-Mockrealm") and not Sync.IsOfficer("Offi-Mockrealm"), "O1 from the guild master")
    msg("O1~", "Boss-Mockrealm")
    check(Sync.OfficerSource() == "default", "back to permissions")

    -- A No tells officers to drop it.
    mark = #MOCK.addonMessages
    Sync.SetConsent("activity", false)
    pump()
    local drop = find(sent(mark), "^A0~")
    check(drop and drop.dist == "GUILD" and drop.text == "A0~recruiting,alts,prof", "No goes out: " .. tostring(drop and drop.text))

    -- Rules from an officer; your progress.
    msg("R1~2:1:20:0:7:0;3:0:1:0:7:0", "Alt-Mockrealm")
    check(Sync.GuildRules() == nil, "rules from a non-officer ignored")
    msg("R1~2:1:20:0:7:0;3:0:1:0:7:0", "Offi-Mockrealm")
    local rules = Sync.GuildRules()
    check(rules and rules.by == "Offi-Mockrealm" and rules.rules[2].on and rules.rules[2].level == 20, "rules kept")
    local target, rule, why = Sync.MyProgress()
    check(target == 2 and rule and why == nil, "you meet the Veteran rule: " .. tostring(why))
    local text = ns.GuildUI.ProgressText()
    check(text:find("Next rank") and text:find("Veteran") and text:find("You meet every rule"), "progress text: " .. text)
    msg("R1~2:1:30:0:7:0", "Offi-Mockrealm")
    check(select(3, Sync.MyProgress()) == "level", "level 30 needed")

    -- The window: Sharing and Promotions render; a click on Yes / No changes consent.
    ns.GuildUI.Show("sharing")
    local v = ns.GuildUI.views.sharing
    v.rows[4].yes:Fire("OnClick", "LeftButton")
    check(Sync.Consent("activity") == true, "Yes button")
    ns.GuildUI.Show("promote")
    check(ns.GuildUI.views.promote.note:GetText():find("Next rank"), "promotions tab shows your progress")
    ns.GuildUI.Show("members")
    check(ns.GuildUI.views.members.note:GetText():find("Only officers"), "members tab: officers only")

    -- Not in a guild: nothing is sent at all.
    MOCK.guild = nil
    mark = #MOCK.addonMessages
    Sync.SetConsent("prof", false)
    msg("Q1", "Offi-Mockrealm")
    pump()
    check(#sent(mark) == 0, "no guild: silent")
end

scenarios.guild_sync_officer = function()
    local ns = setup(1)
    local Sync = ns.GuildSync
    check(Sync.IAmOfficer(), "you are an officer")

    -- One request per click.
    resetOutput()
    local mark = #MOCK.addonMessages
    ns.GuildUI.Show("members")
    ns.GuildUI.views.members.ask:Fire("OnClick", "LeftButton")
    Sync.RequestMembers()
    pump()
    local q = sent(mark)
    local n = 0
    for _, m in ipairs(q) do if m.text == "Q1" then n = n + 1 check(m.dist == "GUILD", "Q1 to the guild") end end
    check(n == 1 and printed("asked a moment ago"), "one request")

    -- Answers, one in pieces.
    msg("A0~recruiting,prof", "Pal-Mockrealm", "WHISPER")
    msg("A1~prof~45;Mining:200:225;Tailoring:150:225", "Pal-Mockrealm", "WHISPER")
    local items = {}
    for i = 1, 30 do items[i] = "Recruit" .. i .. "-Mockrealm:" .. (MOCK.now - i) .. ":" .. (i % 3 == 0 and "joined" or "invited") .. ":0" end
    mark = #MOCK.addonMessages
    Sync.Send("WHISPER", "A1~recruiting~" .. table.concat(items, ";"), nil, "Tester-Mockrealm")
    pump(30)
    local pieces = sent(mark)
    check(#pieces >= 4 and pieces[1].text:find("^C%d+:1:"), "long message in pieces: " .. #pieces)
    for i = #pieces, 1, -1 do msg(pieces[i].text, "Pal-Mockrealm", "WHISPER") end
    msg("A1~alts~Sneaky-Mockrealm", "Pal-Mockrealm", "WHISPER")
    local d = data().shared["Pal-Mockrealm"]
    check(d.prof.level == 45 and d.prof.skills[1].name == "Mining" and d.prof.skills[2].rank == 150, "professions received")
    check(#d.recruiting == 30 and d.recruiting[3].status == "joined", "pieces put together, out of order")
    check(d.alts == nil, "a category they did not share is ignored")

    -- Someone outside the guild is ignored.
    msg("A0~prof", "Stranger-Mockrealm", "WHISPER")
    check(data().shared["Stranger-Mockrealm"] == nil, "stranger ignored")

    -- The tab and its tooltips.
    ns.GuildUI.Show("members")
    local rows = ns.GuildUI.views.members.list.all
    check(rows[1].text:find("Mining 200") and rows[1].cols[2]:find("30 invited, 10 joined"), "members row: " .. rows[1].text)
    rows[1].tooltip(TALODGuildWindow)

    -- They stop sharing: the data goes.
    msg("A0~", "Pal-Mockrealm", "GUILD")
    check(d.prof == nil and d.recruiting == nil, "dropped after their No")

    -- Rules go to members once the clicking stops; a member asking gets them.
    ns.GuildUI.Show("promote")
    local pv = ns.GuildUI.views.promote
    mark = #MOCK.addonMessages
    pv.ruleRows[1].on:Fire("OnClick", "LeftButton")
    pv.ruleRows[1].fields[1]:Fire("OnClick", "LeftButton")
    pv.ruleRows[1].fields[1]:Fire("OnClick", "LeftButton")
    pump(3)
    check(not find(sent(mark), "^R1~"), "not while clicking")
    pump(8)
    local r1 = sent(mark)
    local count = 0
    for _, m in ipairs(r1) do if m.text:find("^R1~") then count = count + 1 end end
    check(count == 1 and find(r1, "^R1~2:1:11:"), "one R1 with the new rule")
    mark = #MOCK.addonMessages
    msg("Q2", "Pal-Mockrealm")
    pump()
    check(find(sent(mark), "^R1~"), "Q2 answered")
end

scenarios.guild_sync_gm = function()
    local ns = setup(0)
    local Sync = ns.GuildSync
    check(Sync.IAmGM(), "guild master")
    ns.GuildUI.Show("sharing")
    local v = ns.GuildUI.views.sharing
    check(v.rankChips[2] and v.rankChips[2]:IsShown(), "rank chips for the guild master")
    local mark = #MOCK.addonMessages
    v.rankChips[2]:Fire("OnClick", "LeftButton")
    pump()
    check(Sync.OfficerSource() == "gm" and Sync.RankIsOfficer(1) and Sync.RankIsOfficer(2), "Veteran made an officer rank")
    check(find(sent(mark), "^O1~0,1,2$"), "O1 sent")
    -- A member asks who the officers are.
    for _ = 1, 50 do MOCK.Tick(1.3) end
    mark = #MOCK.addonMessages
    msg("Q0", "Pal-Mockrealm")
    pump()
    check(find(sent(mark), "^O1~0,1,2$"), "Q0 answered")
    v.auto:Fire("OnClick", "LeftButton")
    check(Sync.OfficerSource() == "default", "back to permissions")
end
