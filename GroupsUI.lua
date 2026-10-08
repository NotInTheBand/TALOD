-- TALOD - the Groups window: the group you are in now (live), every party
-- and raid you were in, and one group's members, chat, loot and timeline.

local ADDON_NAME, ns = ...
local S = ns.Secret
local Style = ns.Style
local COLORS, HEX = Style.COLORS, Style.HEX
local Groups, Data = ns.Groups, ns.Data

local UI = {}
ns.GroupsUI = UI

local PAD = 12
local frame
local views = {}
local state = { view = "now", mode = "members" }

local function Hex(c) return string.format("|cff%02x%02x%02x", (c[1] or 1) * 255, (c[2] or 1) * 255, (c[3] or 1) * 255) end
local function Muted(s) return HEX.muted .. s .. "|r" end
local function White(s) return HEX.white .. s .. "|r" end
local function Name(key, classFile) return Hex(ns.ClassColor(classFile)) .. Groups.Short(key) .. "|r" end

local function Dur(secs)
    secs = math.floor(secs or 0)
    if secs < 60 then return secs .. " s" end
    if secs < 3600 then return math.floor(secs / 60) .. " min" end
    return string.format("%d h %02d", math.floor(secs / 3600), math.floor(secs % 3600 / 60))
end

local function When(t) return t and date("%b %d %H:%M", t) or "?" end
local function Clock(t) return t and date("%H:%M", t) or "?" end

local ROLE = { TANK = "tank", HEALER = "healer", DAMAGER = "damage", MAINTANK = "main tank", MAINASSIST = "main assist" }
local LEAD = { [2] = "leader", [1] = "assist" }
local KIND = { party = "Party", raid = "Raid" }

local function Paint(b, on)
    b.borderColor = on and COLORS.accent or nil
    local col = on and COLORS.accent or COLORS.border
    b:SetBorderColor(col[1], col[2], col[3], 1)
    b.label:SetTextColor(on and 1 or 0.6, on and 1 or 0.6, on and 1 or 0.6)
end

local function Note(parent)
    local fs = Style.Text(parent, "GameFontDisable", "CENTER")
    fs:SetPoint("TOPLEFT", 20, -60)
    fs:SetPoint("RIGHT", -20, 0)
    return fs
end

local function Open(id)
    state.session = id
    UI.Show("session")
end

-- "Raid · Molten Core" etc.
local function Title(s)
    local kind = s.bg and "Battleground" or KIND[s.kind] or "?"
    local zones = Groups.Zones(s)
    return kind .. (zones[1] and (" · " .. zones[1][1]) or "")
end

-- What the game showed of a member, for tooltips.
local function MemberLines(m, s)
    local lines = { Name(m.key, m.cls) }
    local level = m.lvl and (m.lvl0 and m.lvl0 ~= m.lvl and (m.lvl0 .. " → " .. m.lvl) or tostring(m.lvl)) or "?"
    lines[#lines + 1] = "Level " .. level .. "  " .. (m.race or "") .. " " .. ns.ClassName(m.cls)
    if m.g then lines[#lines + 1] = HEX.gold .. "<" .. m.g .. ">|r" .. (m.gr and Muted("  " .. m.gr) or "") end
    local tags = {}
    if m.role then tags[#tags + 1] = ROLE[m.role] or m.role:lower() end
    if m.lead then tags[#tags + 1] = LEAD[m.lead] end
    if m.ml then tags[#tags + 1] = "master looter" end
    if m.sub then tags[#tags + 1] = "group " .. m.sub end
    if #tags > 0 then lines[#lines + 1] = table.concat(tags, ", ") end
    lines[#lines + 1] = "Grouped with you " .. White(Dur(m.secs)) .. Muted("  joined " .. Clock(m.join)
        .. (m.left and (", left " .. Clock(m.left)) or ""))
    lines[#lines + 1] = "Deaths seen " .. White(tostring(m.dead or 0)) .. "   offline " .. White(Dur(m.off or 0))
        .. "   AFK " .. White(Dur(m.afk or 0))
    lines[#lines + 1] = "Most health " .. (m.hp and White(ns.FormatNumber(m.hp)) or Muted("?"))
        .. "   " .. (m.pw and (m.pw:sub(1, 1) .. m.pw:sub(2):lower()) or "Power") .. " " .. (m.pwm and White(ns.FormatNumber(m.pwm)) or Muted("?"))
    if m.zone then lines[#lines + 1] = Muted("Last seen in " .. m.zone) end
    local others = Groups.With(m.key)
    if #others > 1 then lines[#lines + 1] = Muted("In " .. #others .. " of your groups") end
    local audit = ns.Audit and ns.Audit.Record(m.key)
    if audit and ns.AuditUI then
        lines[#lines + 1] = "Audit: " .. ns.AuditUI.Badge(ns.Audit.FlagsOf(m.key)) .. Muted("  (click: open the ledger)")
    end
    return lines
end

local function OpenAudit(key)
    if not (ns.Audit and ns.AuditUI and ns.Audit.Record(key)) then return false end
    ns.Audit.selected = key
    ns.AuditUI.Show("ledger")
    return true
end

---------------------------------------------------------------------------
-- Now: the group you are in, read live
---------------------------------------------------------------------------
local function BuildNow(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Your group now")
    v.card:SetAllPoints()
    local bar = CreateFrame("Frame", nil, v.card.content)
    bar:SetPoint("TOPLEFT", 6, -4)
    bar:SetPoint("TOPRIGHT", -6, -4)
    bar:SetHeight(22)
    v.open = Style.Button(bar, "Chat, loot, timeline", 150, function()
        local s = Groups.Current()
        if s then Open(s.id) end
    end, "This group's full record.")
    v.open:SetPoint("TOPRIGHT")
    v.where = Style.Text(bar, "GameFontHighlightSmall")
    v.where:SetPoint("LEFT")
    v.where:SetPoint("RIGHT", v.open, "LEFT", -8, 0)
    local holder = CreateFrame("Frame", nil, v.card.content)
    holder:SetPoint("TOPLEFT", 0, -30)
    holder:SetPoint("BOTTOMRIGHT")
    v.list = Style.List(holder, { colWidths = { 60, 64, 50 }, search = true, hint = "Search names, guilds, classes...",
        columns = { name = "Member", "Health", "Together", "Deaths" },
        onClick = function(item) if item.key then OpenAudit(item.key) end end })
    v.note = Note(v.card.content)
    local vitals = {}

    function v:Footer() return "Health is read live; ? when the game hides it. Deaths: seen alive, then dead, while grouped." end

    function v:Refresh()
        local s = Groups.Current()
        self.list:SetShown(s ~= nil)
        self.open:SetShown(s ~= nil)
        self.where:SetShown(s ~= nil)
        self.note:SetShown(s == nil)
        if not s then
            self.card.title:SetText("Your group now")
            self.card.sub:SetText("")
            self.note:SetText(ns.DB().groupsLog and "You are not in a group. Parties and Raids list the groups you were in."
                or "Group records are off (settings, Groups).")
            return
        end
        self.card.title:SetText(Title(s) .. Muted("  " .. Groups.MemberCount(s) .. " players · " .. Dur(Groups.Duration(s))))
        self.card.sub:SetText("Since " .. When(s.start) .. (s.leader and ("  ·  led by " .. Groups.Short(s.leader)) or "")
            .. "  ·  " .. #(s.chat or {}) .. " chat lines  ·  " .. (s.deaths or 0) .. " deaths")
        self.where:SetText(Muted("Now in ") .. White(s.zone or "?"))
        local rows = {}
        for _, m in ipairs(Groups.Members(s)) do
            if not m.left then
                local unit = Groups.UnitOf(m.key)
                local hp, hpMax, dead, off, afk
                if unit then
                    ns.ReadVitals(unit, vitals)
                    hp, hpMax = vitals.hp, vitals.hpMax
                    dead = S.Call(UnitIsDeadOrGhost, unit)
                    off = S.Call(UnitIsConnected, unit) == false
                    afk = UnitIsAFK and S.Call(UnitIsAFK, unit) == true
                end
                local tags = {}
                if off then tags[#tags + 1] = HEX.muted .. "offline|r"
                elseif dead == true then tags[#tags + 1] = HEX.bad .. "dead|r" end
                if afk then tags[#tags + 1] = HEX.gold .. "AFK|r" end
                if m.lead then tags[#tags + 1] = Muted(LEAD[m.lead]) end
                if m.role then tags[#tags + 1] = Muted(ROLE[m.role] or m.role:lower()) end
                if m.sub then tags[#tags + 1] = Muted("g" .. m.sub) end
                local pct = (hp and hpMax) and math.floor(hp / hpMax * 100 + 0.5) or nil
                local m2 = m
                rows[#rows + 1] = {
                    key = m.key,
                    search = Groups.Short(m.key) .. " " .. (m.g or "") .. " " .. ns.ClassName(m.cls),
                    text = Name(m.key, m.cls) .. Muted("  " .. tostring(m.lvl or "?")) .. (#tags > 0 and ("  " .. table.concat(tags, " ")) or ""),
                    bar = (hp and hpMax) and { hp, hpMax } or nil,
                    cols = { pct and ((pct < 35 and HEX.bad or HEX.white) .. pct .. "%|r") or Muted("?"), Muted(Dur(m.secs)),
                        (m.dead or 0) > 0 and (HEX.bad .. m.dead .. "|r") or Muted("0") },
                    tooltip = function(owner) ns.Tooltip.Text(owner, MemberLines(m2, s)) end,
                }
            end
        end
        if #rows == 0 then rows[1] = { text = Muted("Reading the group...") } end
        self.list:SetItems(rows)
    end
    return v
end

---------------------------------------------------------------------------
-- Parties / Raids: every group of a kind
---------------------------------------------------------------------------
local function BuildSessions(parent, kind)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, kind == "raid" and "Raids" or "Parties")
    v.card:SetAllPoints()
    v.card.sub:SetText(kind == "raid" and "Every raid and battleground group you were in, newest first. Search a name to find who you played with."
        or "Every party you were in, newest first. Search a name to find who you played with.")
    v.list = Style.List(v.card.content, { labelWidth = 84, colWidths = { 60, 48, 48 }, search = true, time = true,
        hint = "Search players, zones...",
        columns = { name = "Group", label = "Started", "Length", "Players", "Chat" },
        onClick = function(item) if item.id then Open(item.id) end end })

    function v:Footer() return "Click a group: its members, chat, loot and timeline." end

    function v:Refresh()
        local data = Data.List(self.list, {
            name = "groups:" .. kind, sources = { "groups" }, key = { kind }, maxAge = 30,
            empty = kind == "raid" and "No raids yet." or "No parties yet.",
            build = function(add)
                local list = Groups.Sessions(kind)
                for _, s in ipairs(list) do
                    add(s, { id = s.id, time = s.start, search = Groups.SearchText(s) })
                end
                return { n = #list }
            end,
            row = function(s)
                local members = Groups.Members(s)
                local names = {}
                for i = 1, math.min(4, #members) do names[i] = Name(members[i].key, members[i].cls) end
                local more = #members - #names
                local open = Groups.IsOpen(s)
                return {
                    id = s.id,
                    label = When(s.start), sort = { label = s.start },
                    text = (open and (HEX.good .. "now|r  ") or "") .. Muted(Title(s) .. "  ") .. table.concat(names, ", ")
                        .. (more > 0 and Muted("  +" .. more) or ""),
                    accent = open and COLORS.accent or nil,
                    cols = { Dur(Groups.Duration(s)), tostring(Groups.MemberCount(s)), tostring(#(s.chat or {})) },
                    tooltip = function(owner)
                        local lines = { Title(s), When(s.start) .. " to " .. (open and "now" or When(s.stop)) .. Muted("  (" .. Dur(Groups.Duration(s)) .. ")") }
                        if s.c then lines[#lines + 1] = Muted("Your character: " .. tostring(ns.Store.CharName(s.c) or "?")) end
                        if s.leader then lines[#lines + 1] = "Led by " .. Groups.Short(s.leader) end
                        local zones = {}
                        for _, z in ipairs(Groups.Zones(s)) do zones[#zones + 1] = z[1] .. Muted(" " .. Dur(z[2])) end
                        if #zones > 0 then lines[#lines + 1] = "Where: " .. table.concat(zones, ", ") end
                        lines[#lines + 1] = (s.deaths or 0) .. " deaths seen · " .. #(s.loot or {}) .. " items looted"
                        lines[#lines + 1] = Muted("Click: open this group.")
                        ns.Tooltip.Text(owner, lines)
                    end,
                }
            end,
        })
        self.card.title:SetText((kind == "raid" and "Raids" or "Parties") .. "  " .. Muted(tostring(data.n)))
    end
    return v
end

---------------------------------------------------------------------------
-- One group
---------------------------------------------------------------------------
local MODES = { { "members", "Members" }, { "chat", "Chat" }, { "loot", "Loot" }, { "timeline", "Timeline" } }
local COLUMNS = {
    members = { name = "Member", label = "Level", "Together", "Deaths", "Offline" },
    chat = { name = "Line", label = "Time" },
    loot = { name = "Item", label = "Time" },
    timeline = { name = "What happened", label = "Time" },
}

local function MemberRow(m, s)
    local tags = {}
    if m.lead then tags[#tags + 1] = LEAD[m.lead] end
    if m.role then tags[#tags + 1] = ROLE[m.role] or m.role:lower() end
    if m.sub then tags[#tags + 1] = "g" .. m.sub end
    return {
        key = m.key,
        label = m.lvl and (m.lvl0 and m.lvl0 ~= m.lvl and (m.lvl0 .. "→" .. m.lvl) or tostring(m.lvl)) or "?",
        text = Name(m.key, m.cls) .. (m.g and (HEX.gold .. "  <" .. m.g .. ">|r") or "") .. (#tags > 0 and Muted("  " .. table.concat(tags, ", ")) or ""),
        sort = { [1] = m.secs or 0, [2] = m.dead or 0, [3] = m.off or 0 },
        cols = { Dur(m.secs), (m.dead or 0) > 0 and (HEX.bad .. m.dead .. "|r") or Muted("0"), (m.off or 0) > 0 and Dur(m.off) or Muted("-") },
        tooltip = function(owner) ns.Tooltip.Text(owner, MemberLines(m, s)) end,
    }
end

local EVENT_TEXT = {
    join = "joined", back = "came back", left = "left", died = "died", raid = "the party became a raid", zone = "you went to",
}

local function BuildSession(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.top = Style.Card(v, "")
    v.top:SetPoint("TOPLEFT")
    v.top:SetPoint("TOPRIGHT")
    v.top:SetHeight(112)
    v.summary = Style.Text(v.top.content, "GameFontHighlightSmall")
    v.summary:SetPoint("TOPLEFT", 8, -4)
    v.summary:SetPoint("RIGHT", -8, 0)
    if v.summary.SetSpacing then v.summary:SetSpacing(3) end

    v.body = Style.Card(v, "")
    v.body:SetPoint("TOPLEFT", v.top, "BOTTOMLEFT", 0, -8)
    v.body:SetPoint("BOTTOMRIGHT")
    local bar = CreateFrame("Frame", nil, v.body.content)
    bar:SetPoint("TOPLEFT", 6, -4)
    bar:SetPoint("TOPRIGHT", -6, -4)
    bar:SetHeight(22)
    v.modes = {}
    local x = 0
    for _, mode in ipairs(MODES) do
        local b = Style.Button(bar, mode[2], 90, function() state.mode = mode[1] UI.Refresh() end)
        b:SetPoint("TOPLEFT", x, 0)
        b.key = mode[1]
        v.modes[#v.modes + 1] = b
        x = x + 94
    end
    v.delete = Style.Button(bar, "Delete", 80, function()
        if state.session and IsShiftKeyDown() then
            Groups.Delete(state.session)
            state.session = nil
            UI.Refresh()
        else
            ns.Print("Shift + click Delete to remove this group's record.")
        end
    end, "Shift + click: removes this group (members, chat, loot) from your saved data.")
    v.delete:SetPoint("TOPRIGHT")
    local holder = CreateFrame("Frame", nil, v.body.content)
    holder:SetPoint("TOPLEFT", 0, -30)
    holder:SetPoint("BOTTOMRIGHT")
    v.list = Style.List(holder, { labelWidth = 52, colWidths = { 60, 46, 56 }, search = true, hint = "Search...",
        columns = COLUMNS.members,
        onClick = function(item) if item.key then OpenAudit(item.key) end end })
    v.empty = Note(v)
    local shownMode

    function v:Footer() return "Who was in the group and what the game showed of them while grouped. Unknown shows ?, never 0." end

    function v:Refresh()
        local s = state.session and Groups.ById(state.session)
        self.top:SetShown(s ~= nil)
        self.body:SetShown(s ~= nil)
        self.empty:SetShown(s == nil)
        if not s then
            self.empty:SetText("Pick a group in Parties or Raids.")
            return
        end
        local open = Groups.IsOpen(s)
        self.top.title:SetText(Title(s) .. (open and (HEX.good .. "  now|r") or ""))
        self.top.sub:SetText(When(s.start) .. " to " .. (open and "now" or When(s.stop)) .. "  ·  " .. Dur(Groups.Duration(s))
            .. (s.c and ("  ·  as " .. tostring(ns.Store.CharName(s.c) or "?")) or ""))
        local lines = {}
        local zones = {}
        for _, z in ipairs(Groups.Zones(s)) do
            zones[#zones + 1] = White(z[1]) .. (z[3] and Muted(" (" .. z[3] .. ")") or "") .. Muted(" " .. Dur(z[2]))
        end
        lines[#lines + 1] = "Where: " .. (#zones > 0 and table.concat(zones, ", ") or Muted("?"))
        lines[#lines + 1] = "Players: " .. White(tostring(Groups.MemberCount(s))) .. Muted(" (most at once " .. tostring(s.size or "?") .. ")")
            .. (s.leader and ("   Led by " .. White(Groups.Short(s.leader))) or "")
            .. (s.raidAt and s.kind == "raid" and Muted("   raid from " .. Clock(s.raidAt)) or "")
        lines[#lines + 1] = "Deaths seen: " .. White(tostring(s.deaths or 0)) .. "   Chat: " .. White(tostring(#(s.chat or {})))
            .. ((s.chatHidden or 0) > 0 and Muted(" (+" .. s.chatHidden .. " hidden by the game)") or "")
            .. ((s.chatDrop or 0) > 0 and Muted(" (" .. s.chatDrop .. " oldest dropped)") or "")
            .. "   Loot: " .. White(tostring(#(s.loot or {})))
        if (s.hidden or 0) > 0 then lines[#lines + 1] = Muted("Some reads of a member's name were hidden by the game: those are not listed.") end
        self.summary:SetText(table.concat(lines, "\n"))
        for _, b in ipairs(self.modes) do Paint(b, b.key == state.mode) end

        if shownMode ~= state.mode then
            shownMode = state.mode
            self.list:SetColumns(COLUMNS[state.mode])
        end
        local mode = state.mode
        Data.List(self.list, {
            name = "groups:session", sources = { "groups" }, key = { s.id, mode }, maxAge = open and 5 or 300,
            empty = mode == "chat" and "No group chat." or mode == "loot" and "No loot seen." or "Nothing yet.",
            build = function(add, raw)
                if mode == "members" then
                    for _, m in ipairs(Groups.Members(s)) do raw(MemberRow(m, s)) end
                elseif mode == "chat" then
                    local chat = Groups.Chat(s)
                    for i = #chat, 1, -1 do
                        local c = chat[i]
                        add(c, { time = c[1], search = Groups.Short(c[2]) .. " " .. tostring(c[4]) })
                    end
                elseif mode == "loot" then
                    local loot = Groups.Loot(s)
                    for i = #loot, 1, -1 do
                        local l = loot[i]
                        add(l, { time = l[1], search = Groups.Short(l[2]) .. " " .. tostring(l[3]) })
                    end
                else
                    local ev = Groups.Events(s)
                    for i = #ev, 1, -1 do
                        local e = ev[i]
                        add(e, { time = e[1], search = tostring(e[2]) .. " " .. (e[3] and Groups.Short(e[3]) or "") })
                    end
                end
            end,
            row = function(x)
                if mode == "timeline" then
                    local kind, who = x[2], x[3]
                    local text
                    if kind == "zone" then text = "You went to " .. White(tostring(who))
                    elseif kind == "raid" then text = HEX.gold .. "The party became a raid|r"
                    else
                        text = (who and Groups.Short(who) or "?") .. " " .. (kind == "died" and (HEX.bad .. "died|r") or (EVENT_TEXT[kind] or tostring(kind)))
                    end
                    return { label = Clock(x[1]), sort = { label = x[1] }, text = text }
                end
                if mode == "chat" then
                    local ch = x[3]
                    local color = (ch == "w" and HEX.bad) or ((ch == "r" or ch == "R") and HEX.gold) or HEX.white
                    return { label = Clock(x[1]), sort = { label = x[1] },
                        text = Muted("[" .. (Groups.CHANNEL_NAMES[ch] or ch) .. "] ") .. Groups.Short(x[2]) .. ": " .. color .. tostring(x[4]) .. "|r",
                        tooltip = function(owner) ns.Tooltip.Text(owner, { Groups.Short(x[2]) .. Muted("  " .. When(x[1])), tostring(x[4]) }) end }
                end
                return { label = Clock(x[1]), sort = { label = x[1] },
                    text = Groups.Short(x[2]) .. ": " .. tostring(x[3]) .. ((x[4] or 1) > 1 and Muted(" x" .. x[4]) or ""),
                    link = x[3],
                    tooltip = function(owner) ns.Tooltip.Item(owner, x[3]) end }
            end,
        })
    end
    return v
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local VIEWS = {
    { key = "now", label = "Now", build = BuildNow },
    { key = "party", label = "Parties", build = function(p) return BuildSessions(p, "party") end },
    { key = "raid", label = "Raids", build = function(p) return BuildSessions(p, "raid") end },
    { key = "session", label = "Group", build = BuildSession },
}

local function Build()
    frame = Style.Window(ns.FRAME .. "GroupsWindow", "Groups", nil, nil, { nav = "groups" })
    local tabHolder = CreateFrame("Frame", nil, frame)
    tabHolder:SetPoint("TOPLEFT", PAD, -44)
    tabHolder:SetPoint("TOPRIGHT", -PAD, -44)
    tabHolder:SetHeight(26)
    frame.tabs = Style.Tabs(tabHolder, VIEWS, function(key) state.view = key UI.Refresh() end, 100)
    local line = Style.HLine(frame)
    line:SetPoint("TOPLEFT", PAD, -70)
    line:SetPoint("TOPRIGHT", -PAD, -70)

    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", PAD, -78)
    body:SetPoint("BOTTOMRIGHT", -PAD, 34)
    for _, def in ipairs(VIEWS) do views[def.key] = def.build(body) end
    frame.footer = Style.Text(frame, "GameFontDisableSmall")
    frame.footer:SetPoint("BOTTOMLEFT", PAD + 2, 12)
    frame.footer:SetPoint("RIGHT", -PAD, 0)
    frame:HookScript("OnShow", function() UI.Refresh() end)
end

function UI.Refresh()
    if not frame or not frame:IsShown() then return end
    frame.tabs:Select(state.view)
    for key, v in pairs(views) do v:SetShown(key == state.view) end
    local v = views[state.view]
    v:Refresh()
    frame.footer:SetText(v:Footer() or "")
end

function UI.Show(view)
    if not frame then Build() end
    if view and views[view] then state.view = view end
    if frame:IsShown() then UI.Refresh() else frame:Show() end
end

function UI.Toggle(view)
    if frame and frame:IsShown() and (not view or view == state.view) then frame:Hide() else UI.Show(view) end
end

function UI.IsShown() return frame ~= nil and frame:IsShown() end
UI.views, UI.state = views, state
Data.Window(UI, { "groups", "groups.live" }, { shows = function(src) return src ~= "groups.live" or state.view == "now" end })

---------------------------------------------------------------------------
-- Settings tab
---------------------------------------------------------------------------
local QUALITIES = {
    { value = 0, label = "Everything" }, { value = 1, label = "Common and better" }, { value = 2, label = "Uncommon and better" },
    { value = 3, label = "Rare and better" }, { value = 4, label = "Epic and better" },
}

local function BuildPage(parent)
    local W = ns.Options.Widgets
    local y = -12
    y = W.Paragraph(parent, y, "Keeps a record of every party and raid you are in: who was there (class, level, guild, role, "
        .. "time grouped with you, deaths seen), where you went, the group's chat and the loot. One record per group, not per "
        .. "player: search a name in Parties or Raids to find every group you shared. Type |cffffffff" .. ns.Cmd.Text("groups")
        .. "|r for the window.", "GameFontHighlightSmall")
    W.Button(parent, y, "Open the groups window", 200, function() UI.Show() end)
    y = y - 34
    y = W.Header(parent, y, "Recording")
    y = W.Checkbox(parent, y, "groupsLog", "Keep a record of my parties and raids",
        "Off: nothing new is recorded; the records you have stay.")
    y = W.Checkbox(parent, y, "groupsChat", "Keep the group's chat (party, raid, raid warnings, instance)",
        "Up to " .. Groups.MAX_CHAT .. " lines per group; the oldest go first.")
    y = W.Checkbox(parent, y, "groupsLoot", "Keep the loot the group's loot messages show")
    y = W.Cycle(parent, y, "groupsLootQuality", "Loot to keep", QUALITIES)
    return -y + 10
end

ns.Options.AddTab({ label = "Groups", pages = { { label = "Groups", build = BuildPage } } })
