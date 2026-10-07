-- TALOD - the Audit window: guild members' statistics, flags worth a
-- look, every character on record, one character's ledger and its history.

local ADDON_NAME, ns = ...
local Style = ns.Style
local COLORS, HEX = Style.COLORS, Style.HEX
local Audit, Guild, Data = ns.Audit, ns.Guild, ns.Data

local UI = {}
ns.AuditUI = UI

local PAD = 12
local frame
local views = {}
local state = { view = "members", memberFilter = "all", sort = "flags", showReviewed = false }

local function db() return ns.DB() end

local function Hex(c) return string.format("|cff%02x%02x%02x", (c[1] or 1) * 255, (c[2] or 1) * 255, (c[3] or 1) * 255) end
local function NameText(full, classFile) return Hex(ns.ClassColor(classFile)) .. Guild.Short(full) .. "|r" end
local function ShortDate(t) return t and date("%b %d", t) or "?" end
local function Muted(s) return HEX.muted .. s .. "|r" end
local function Gold(n) return n and (HEX.gold .. Audit.Gold(n) .. "|r") or Muted("?") end

local function Age(t)
    if not t then return "?" end
    local s = time() - t
    if s < 3600 then return math.max(1, math.floor(s / 60)) .. " min ago" end
    if s < 86400 then return math.floor(s / 3600) .. " h ago" end
    return math.floor(s / 86400) .. " d ago"
end

local SOURCE = { self = "your own", inspect = "inspected (the server's figures)", shared = "shared by them (their addon's figures)" }

local BADGE = {
    look = HEX.bad .. "Worth a look|r", watch = HEX.gold .. "Watch|r", none = HEX.good .. "No flags|r", unknown = Muted("?"),
}
function UI.Badge(flags)
    if not flags then return Muted("no statistics") end
    if flags.reviewed then return Muted("Reviewed") end
    return BADGE[flags.level] or Muted("?")
end

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

local function Open(full)
    Audit.selected = full
    UI.Show("ledger")
end

-- Tooltip lines for a record's flags.
local function FlagLines(lines, flags, c)
    if not flags then return end
    lines[#lines + 1] = "Flags: " .. UI.Badge(flags)
    for _, f in ipairs(flags.list) do
        lines[#lines + 1] = (f.weight >= 2 and HEX.bad or HEX.gold) .. f.title .. "|r  " .. HEX.white .. f.text .. "|r"
    end
    if #flags.list == 0 and flags.level == "unknown" then
        lines[#lines + 1] = Muted("Some rules could not be checked: counters missing (missing is never counted as fine).")
    end
    local r = c and c.review
    if r and r.state then
        lines[#lines + 1] = Muted((r.state == "ok" and "Reviewed as fine" or "On watch") .. " by " .. Guild.Short(r.by) .. ", " .. ShortDate(r.t))
    end
    if r and r.note then lines[#lines + 1] = Muted("Note: ") .. r.note end
end

local function RecordTooltip(owner, x)
    local s = x.snap
    local lines = { Guild.Short(x.full) }
    lines[#lines + 1] = "Level " .. tostring(s.level or x.c.level or "?") .. (s.guild and ("  <" .. s.guild .. ">") or "")
        .. Muted("  ·  last look " .. Age(s.t) .. ", " .. (SOURCE[s.src] or "?"))
    lines[#lines + 1] = "Most gold owned " .. Gold(Audit.V(s, "peak")) .. "   acquired " .. Gold(Audit.V(s, "acquired"))
        .. "   other sources " .. Gold(Audit.Other(s))
    FlagLines(lines, x.flags, x.c)
    lines[#lines + 1] = Muted("Click: open the ledger.")
    ns.Tooltip.Text(owner, lines)
end

---------------------------------------------------------------------------
-- Members: your roster with what is known of each
---------------------------------------------------------------------------
local MEMBER_FILTERS = { { "all", "All members" }, { "flagged", "Flagged" }, { "missing", "No statistics" } }

local function BuildMembers(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Guild members")
    v.card:SetAllPoints()
    v.card.sub:SetText("Statistics come from Inspect (the server's figures) or from members who share theirs with officers.")
    local bar = CreateFrame("Frame", nil, v.card.content)
    bar:SetPoint("TOPLEFT", 6, -4)
    bar:SetPoint("TOPRIGHT", -6, -4)
    bar:SetHeight(22)
    v.filters = {}
    local x = 0
    for _, f in ipairs(MEMBER_FILTERS) do
        local b = Style.Button(bar, f[2], 110, function() state.memberFilter = f[1] UI.Refresh() end)
        b:SetPoint("TOPLEFT", x, 0)
        b.key = f[1]
        v.filters[#v.filters + 1] = b
        x = x + 114
    end
    v.ask = Style.Button(bar, "Ask members", 120, function()
        if ns.GuildSync then ns.GuildSync.RequestMembers() end
        UI.Refresh()
    end, "One request to the guild. Each member's addon answers with only what that member said Yes to "
        .. "(Guild window, Sharing tab: \"Gold and activity statistics\").")
    v.ask:SetPoint("TOPRIGHT")
    local holder = CreateFrame("Frame", nil, v.card.content)
    holder:SetPoint("TOPLEFT", 0, -30)
    holder:SetPoint("BOTTOMRIGHT")
    v.list = Style.List(holder, { colWidths = { 96, 96, 72 }, search = true, hint = "Search names, ranks...",
        columns = { name = "Member", "Most owned", "Acquired", "Last look" },
        onClick = function(item) if item.full then Open(item.full) end end })
    v.note = Note(v.card.content)

    function v:Footer() return "Most owned: the most gold ever owned at once. Acquired: all gold ever received. Unknown shows ?, never 0." end

    function v:Refresh()
        local g = Guild.Mine() and Guild.Data()
        for _, b in ipairs(self.filters) do Paint(b, b.key == state.memberFilter) end
        local officer = ns.GuildSync and ns.GuildSync.IAmOfficer()
        self.ask:SetShown(g and officer and true or false)
        self.list:SetShown(g ~= nil)
        self.note:SetShown(g == nil)
        self.note:SetText("You are not in a guild. The Characters tab lists everyone you have looked at.")
        if not g then return end
        local data = Data.List(self.list, {
            name = "audit:members", sources = { "audit", "guild" }, key = { state.memberFilter, Guild.Key() }, maxAge = 60,
            empty = state.memberFilter == "flagged" and "No member is flagged." or "No members to show.",
            build = function(add)
                local rows, counts = {}, { members = 0, known = 0, flagged = 0 }
                for full, m in pairs(g.members) do
                    if not m.missing then
                        counts.members = counts.members + 1
                        local c = Audit.Record(full)
                        local snap = Audit.Latest(c)
                        local flags = snap and Audit.FlagsOf(full) or nil
                        local flagged = flags and not flags.reviewed and (flags.level == "look" or flags.level == "watch")
                        if snap then counts.known = counts.known + 1 end
                        if flagged then counts.flagged = counts.flagged + 1 end
                        local f = state.memberFilter
                        if f == "all" or (f == "flagged" and flagged) or (f == "missing" and not snap) then
                            rows[#rows + 1] = { full = full, m = m, c = c, snap = snap, flags = flags }
                        end
                    end
                end
                table.sort(rows, function(a, b)
                    local av = a.flags and ((a.flags.reviewed and 0 or Audit.LEVEL_ORDER[a.flags.level] or 0) * 1000 + a.flags.score) or -1
                    local bv = b.flags and ((b.flags.reviewed and 0 or Audit.LEVEL_ORDER[b.flags.level] or 0) * 1000 + b.flags.score) or -1
                    if av ~= bv then return av > bv end
                    local ap, bp = Audit.V(a.snap, "peak") or -1, Audit.V(b.snap, "peak") or -1
                    if ap ~= bp then return ap > bp end
                    return a.full < b.full
                end)
                for _, x in ipairs(rows) do
                    add(x, { full = x.full, search = Guild.Short(x.full) .. " " .. tostring(x.m.rankName or "") })
                end
                return counts
            end,
            row = function(x)
                local s = x.snap
                return {
                    text = NameText(x.full, x.m.classFile) .. Muted("  " .. tostring(x.m.level or "?") .. "  " .. tostring(x.m.rankName or ""))
                        .. "   " .. UI.Badge(x.flags) .. (x.flags and x.flags.list[1] and Muted("  " .. x.flags.list[1].title) or ""),
                    cols = s and { Gold(Audit.V(s, "peak")), Gold(Audit.V(s, "acquired")), Muted(Age(s.t)) } or { Muted("-"), Muted("-"), Muted("-") },
                    tooltip = function(owner)
                        if s then RecordTooltip(owner, x) return end
                        ns.Tooltip.Text(owner, { Guild.Short(x.full), "No statistics yet.",
                            Muted("Inspect them (the Audit button on the Inspect window), or ask members to share (officers).") })
                    end,
                }
            end,
        })
        self.card.title:SetText("Guild members  " .. Muted(data.members .. " · " .. data.known .. " with statistics · ")
            .. (data.flagged > 0 and (HEX.bad .. data.flagged .. " flagged|r") or Muted("none flagged")))
    end
    return v
end

---------------------------------------------------------------------------
-- Flags: every record worth a look
---------------------------------------------------------------------------
local function BuildFlags(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Flags")
    v.card:SetAllPoints()
    v.card.sub:SetText("Counters that do not add up the way played gold does. A reason to look, not proof: check before you act.")
    local bar = CreateFrame("Frame", nil, v.card.content)
    bar:SetPoint("TOPLEFT", 6, -4)
    bar:SetPoint("TOPRIGHT", -6, -4)
    bar:SetHeight(22)
    v.members = Style.Button(bar, "Members only", 120, function() state.flagMembers = not state.flagMembers UI.Refresh() end)
    v.members:SetPoint("TOPLEFT")
    v.reviewed = Style.Button(bar, "Show reviewed", 120, function() state.showReviewed = not state.showReviewed UI.Refresh() end,
        "Records an officer marked as fine. A new flag (a new jump) brings a record back on its own.")
    v.reviewed:SetPoint("LEFT", v.members, "RIGHT", 4, 0)
    local holder = CreateFrame("Frame", nil, v.card.content)
    holder:SetPoint("TOPLEFT", 0, -30)
    holder:SetPoint("BOTTOMRIGHT")
    v.list = Style.List(holder, { colWidths = { 96, 96, 72 }, search = true, hint = "Search names, guilds...",
        columns = { name = "Character", "Most owned", "Acquired", "Last look" },
        columns = { name = "Character", "Most owned", "Other sources", "Last look" },
        onClick = function(item) if item.full then Open(item.full) end end })

    function v:Footer() return "Other sources: gold from trade, mail and the like. Thresholds: settings, Audit." end

    function v:Refresh()
        Paint(self.members, state.flagMembers)
        Paint(self.reviewed, state.showReviewed)
        local data = Data.List(self.list, {
            name = "audit:flags", sources = { "audit", "guild" }, key = { state.flagMembers, state.showReviewed }, maxAge = 60,
            empty = "Nothing flagged.",
            build = function(add)
                local rows = {}
                for _, x in ipairs(Audit.Rows()) do
                    local f = x.flags
                    if f and (f.level == "look" or f.level == "watch") and (state.showReviewed or not f.reviewed)
                        and (x.member or not state.flagMembers) then
                        rows[#rows + 1] = x
                    end
                end
                Audit.Sort(rows, "flags")
                for _, x in ipairs(rows) do
                    add(x, { full = x.full, search = Guild.Short(x.full) .. " " .. tostring(x.snap.guild or "") })
                end
                return { n = #rows }
            end,
            row = function(x)
                local titles = {}
                for _, f in ipairs(x.flags.list) do titles[#titles + 1] = f.title end
                return {
                    text = NameText(x.full, x.c.classFile) .. Muted("  " .. tostring(x.snap.level or "?"))
                        .. (x.member and Muted("  member") or "") .. "   " .. UI.Badge(x.flags) .. Muted("  " .. table.concat(titles, ", ")),
                    cols = { Gold(Audit.V(x.snap, "peak")), Gold(Audit.Other(x.snap)), Muted(Age(x.snap.t)) },
                    accent = not x.flags.reviewed and x.flags.level == "look" and { 1, 0.31, 0.31 } or nil,
                    tooltip = function(owner) RecordTooltip(owner, x) end,
                }
            end,
        })
        self.card.title:SetText("Flags  " .. Muted(tostring(data.n)))
    end
    return v
end

---------------------------------------------------------------------------
-- Characters: every record
---------------------------------------------------------------------------
-- Orders with no column of their own (the column titles sort the rest).
local SORTS = { { "flags", "Flags" }, { "other", "Other sources" }, { "level", "Level" } }

local function BuildCharacters(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Characters")
    v.card:SetAllPoints()
    v.card.sub:SetText("Everyone on record: you, players you inspected, members who shared. The newest look of each.")
    local bar = CreateFrame("Frame", nil, v.card.content)
    bar:SetPoint("TOPLEFT", 6, -4)
    bar:SetPoint("TOPRIGHT", -6, -4)
    bar:SetHeight(22)
    v.sort = Style.Button(bar, "", 190, nil, "Click: choose the order. Unknown figures sort last.")
    v.sort:SetPoint("TOPLEFT")
    v.sort:SetScript("OnClick", function(self)
        local items = {}
        for _, s in ipairs(SORTS) do
            items[#items + 1] = { label = s[2], selected = s[1] == state.sort, pick = function() state.sort = s[1] UI.Refresh() end }
        end
        Style.OpenDropdown(self, items)
    end)
    local holder = CreateFrame("Frame", nil, v.card.content)
    holder:SetPoint("TOPLEFT", 0, -30)
    holder:SetPoint("BOTTOMRIGHT")
    v.list = Style.List(holder, { colWidths = { 96, 96, 72 }, search = true, hint = "Search names, guilds...",
        onClick = function(item) if item.full then Open(item.full) end end })

    function v:Footer() return "Most owned: the most gold ever owned at once. Acquired: all gold ever received." end

    function v:Refresh()
        local label = "?"
        for _, s in ipairs(SORTS) do if s[1] == state.sort then label = s[2] end end
        self.sort:SetLabel("Order: " .. label .. " >")
        local data = Data.List(self.list, {
            name = "audit:chars", sources = { "audit", "guild" }, key = { state.sort }, maxAge = 60,
            empty = "No statistics yet. Click My character, or target a player and click Target.",
            build = function(add)
                local rows = Audit.Sort(Audit.Rows(), state.sort)
                for _, x in ipairs(rows) do
                    add(x, { full = x.full, search = Guild.Short(x.full) .. " " .. tostring(x.snap.guild or "") })
                end
                return { n = #rows }
            end,
            row = function(x)
                return {
                    text = NameText(x.full, x.c.classFile) .. Muted("  " .. tostring(x.snap.level or "?")
                        .. (x.snap.guild and ("  <" .. x.snap.guild .. ">") or "") .. "  " .. #x.c.snaps .. " looks") .. "   " .. UI.Badge(x.flags),
                    cols = { Gold(Audit.V(x.snap, "peak")), Gold(Audit.V(x.snap, "acquired")), Muted(Age(x.snap.t)) },
                    tooltip = function(owner) RecordTooltip(owner, x) end,
                }
            end,
        })
        self.card.title:SetText("Characters  " .. Muted(tostring(data.n)))
    end
    return v
end

---------------------------------------------------------------------------
-- Ledger: one character
---------------------------------------------------------------------------
local function CounterRow(snap, key, label)
    local f = Audit.BY_KEY[key]
    local value = Audit.Value(snap, key)
    return {
        text = label or f[3],
        cols = { value and (f[4] and (HEX.gold .. value .. "|r") or (HEX.white .. value .. "|r")) or Muted("?") },
        tooltip = function(owner)
            local lines = { f[3] .. (f[5] and " (highest recorded)" or "") }
            if value then
                lines[#lines + 1] = "Statistic " .. f[2] .. ", " .. (SOURCE[snap.src] or "?") .. ", " .. date("%Y-%m-%d %H:%M", snap.t) .. "."
                if f[5] then lines[#lines + 1] = Muted("The highest rank ever recorded: they may have dropped this profession since.") end
            else
                lines[#lines + 1] = Audit.Reason(snap, key)
            end
            ns.Tooltip.Text(owner, lines)
        end,
    }
end

local function BuildLedger(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.top = Style.Card(v, "")
    v.top:SetPoint("TOPLEFT")
    v.top:SetPoint("TOPRIGHT")
    v.top:SetHeight(176)
    v.summary = Style.Text(v.top.content, "GameFontHighlightSmall")
    v.summary:SetPoint("TOPLEFT", 8, -4)
    v.summary:SetPoint("RIGHT", -8, 0)
    if v.summary.SetSpacing then v.summary:SetSpacing(3) end
    local actions = CreateFrame("Frame", nil, v.top.content)
    actions:SetPoint("BOTTOMLEFT", 6, 4)
    actions:SetPoint("BOTTOMRIGHT", -6, 4)
    actions:SetHeight(22)
    v.ok = Style.Button(actions, "Looked: fine", 100, function()
        if Audit.selected then Audit.SetReview(Audit.selected, "ok") end
    end, "Marks the flags you see now as reviewed. A new flag brings the record back.")
    v.ok:SetPoint("LEFT")
    v.watch = Style.Button(actions, "Watch", 70, function()
        if Audit.selected then Audit.SetReview(Audit.selected, "watch") end
    end, "Keeps this record on watch (shown in its tooltip).")
    v.watch:SetPoint("LEFT", v.ok, "RIGHT", 4, 0)
    v.clear = Style.Button(actions, "Clear review", 90, function()
        if Audit.selected then Audit.SetReview(Audit.selected, nil) end
    end)
    v.clear:SetPoint("LEFT", v.watch, "RIGHT", 4, 0)
    v.note = CreateFrame("EditBox", nil, actions)
    v.note:SetHeight(22)
    v.note:SetPoint("LEFT", v.clear, "RIGHT", 8, 0)
    v.note:SetPoint("RIGHT", -96, 0)
    v.note:SetAutoFocus(false)
    v.note:SetFontObject("GameFontHighlightSmall")
    v.note:SetTextInsets(8, 8, 0, 0)
    v.note:SetMaxLetters(200)
    local nbg = Style.Texture(v.note, "BACKGROUND", COLORS.button)
    nbg:SetAllPoints()
    Style.Border(v.note, COLORS.border)
    v.note.hint = Style.Text(v.note, "GameFontDisableSmall")
    v.note.hint:SetPoint("LEFT", 8, 0)
    v.note.hint:SetText("Note (Enter saves)")
    v.note:SetScript("OnTextChanged", function(self) self.hint:SetShown((self:GetText() or "") == "") end)
    v.note:SetScript("OnEnterPressed", function(self)
        if Audit.selected then Audit.SetNote(Audit.selected, self:GetText()) end
        self:ClearFocus()
    end)
    v.note:SetScript("OnEscapePressed", function(self) self:ClearFocus() UI.Refresh() end)
    v.delete = Style.Button(actions, "Delete", 86, function()
        if Audit.selected and IsShiftKeyDown() then
            Audit.Delete(Audit.selected)
            Audit.selected = nil
            UI.Refresh()
        else
            ns.Print("Shift + click Delete to remove this character's record.")
        end
    end, "Shift + click: removes every look of this character from your saved data.")
    v.delete:SetPoint("RIGHT")

    v.gold = Style.Card(v, "Gold")
    v.gold:SetPoint("TOPLEFT", v.top, "BOTTOMLEFT", 0, -8)
    v.gold:SetPoint("BOTTOMRIGHT", v, "BOTTOM", -4, 0)
    v.gold.sub:SetText("Gross income, not profit or the gold they carry now.")
    v.goldList = Style.List(v.gold.content, { colWidths = { 130 } })
    v.act = Style.Card(v, "Activity and professions")
    v.act:SetPoint("TOPLEFT", v.top, "BOTTOM", 4, -8)
    v.act:SetPoint("BOTTOMRIGHT")
    v.actList = Style.List(v.act.content, { colWidths = { 90 } })
    v.empty = Note(v)

    function v:Footer() return Audit.DISCLAIMER end

    function v:Refresh()
        local full = Audit.selected
        local c = full and Audit.Record(full)
        local snap = Audit.Latest(c)
        local has = snap ~= nil
        self.top:SetShown(has)
        self.gold:SetShown(has)
        self.act:SetShown(has)
        self.empty:SetShown(not has)
        if not has then
            self.empty:SetText(full and (Guild.Short(full) .. ": no statistics yet. Target them nearby and click Target.")
                or "Pick a character in Members, Flags or Characters, or click My character / Target above.")
            return
        end
        local member, m = Audit.IsMember(full)
        local flags = Audit.FlagsOf(full)
        local a = Audit.Assess(snap)
        self.top.title:SetText(NameText(full, c.classFile) .. Muted("  level " .. tostring(snap.level or c.level or "?"))
            .. (snap.guild and (HEX.gold .. "  <" .. snap.guild .. ">|r") or "")
            .. (member and Muted("  ·  " .. tostring(m.rankName or "member")) or ""))
        self.top.sub:SetText("Last look " .. Age(snap.t) .. " (" .. date("%Y-%m-%d %H:%M", snap.t) .. "), " .. (SOURCE[snap.src] or "?")
            .. "  ·  " .. #c.snaps .. " looks since " .. ShortDate(c.first) .. "  ·  " .. snap.n .. " / " .. #Audit.FIELDS .. " counters")
        local lines = {}
        lines[#lines + 1] = "Activity: " .. HEX.white .. a.title .. "|r" .. Muted("  " .. a.summary .. "  (" .. a.coverage .. ")")
        lines[#lines + 1] = "Flags: " .. UI.Badge(flags) .. (flags.level == "unknown" and #flags.list == 0
            and Muted("  some rules could not be checked (counters missing)") or "")
        for i, f in ipairs(flags.list) do
            if i > 3 then lines[#lines + 1] = Muted("  +" .. (#flags.list - 3) .. " more (hover a row in Flags)") break end
            lines[#lines + 1] = "  " .. (f.weight >= 2 and HEX.bad or HEX.gold) .. f.title .. "|r  " .. Muted(f.text)
        end
        local r = c.review
        if r and r.state then
            lines[#lines + 1] = Muted((r.state == "ok" and "Reviewed as fine" or "On watch") .. " by " .. Guild.Short(r.by) .. ", " .. ShortDate(r.t))
        end
        self.summary:SetText(table.concat(lines, "\n"))
        Paint(self.ok, r and r.state == "ok")
        Paint(self.watch, r and r.state == "watch")
        if not self.note:HasFocus() then self.note:SetText(r and r.note or "") end

        local g = {}
        g[#g + 1] = { header = true, text = "Income" }
        for _, key in ipairs({ "acquired", "peak", "looted", "quests", "vendors", "auctions" }) do g[#g + 1] = CounterRow(snap, key) end
        local other = Audit.Other(snap)
        g[#g + 1] = { text = "Other sources (trade, mail, ...)", cols = { other and (HEX.gold .. Audit.Gold(other) .. "|r") or Muted("?") },
            tooltip = function(owner) ns.Tooltip.Text(owner, { "Other sources",
                "Total gold acquired minus loot, quests, vendors and auctions. Unknown when any of those is missing." }) end }
        local gap = Audit.Gap(snap)
        g[#g + 1] = { text = "Peak above recorded income", cols = { gap and (HEX.gold .. Audit.Gold(gap) .. "|r") or Muted("?") },
            tooltip = function(owner) ns.Tooltip.Text(owner, { "Peak above recorded income",
                "Most gold ever owned minus total gold acquired, at least 0. Above 0, gold reached them that the counters did not count." }) end }
        if snap.wallet then g[#g + 1] = { text = "Gold carried now", cols = { HEX.gold .. Audit.Gold(snap.wallet) .. "|r" } } end
        g[#g + 1] = { header = true, text = "Auctions" }
        for _, key in ipairs({ "posted", "purchases", "largestSale", "largestBid" }) do g[#g + 1] = CounterRow(snap, key) end
        g[#g + 1] = { header = true, text = "Spending" }
        for _, key in ipairs({ "daily", "travel", "postage", "barber", "respec" }) do g[#g + 1] = CounterRow(snap, key) end
        self.goldList:SetItems(g)

        local act = { { header = true, text = "Activity" } }
        for _, key in ipairs(Audit.ACTIVITY_KEYS) do act[#act + 1] = CounterRow(snap, key) end
        act[#act + 1] = { header = true, text = "Professions" }
        local profs = {}
        for _, key in ipairs(Audit.PROFESSION_KEYS) do profs[#profs + 1] = { key = key, n = Audit.V(snap, key) } end
        table.sort(profs, function(x, y)
            if (x.n == nil) ~= (y.n == nil) then return x.n ~= nil end
            if x.n ~= y.n then return x.n > y.n end
            return x.key < y.key
        end)
        for _, p in ipairs(profs) do act[#act + 1] = CounterRow(snap, p.key, Audit.BY_KEY[p.key][3] .. (Audit.BY_KEY[p.key][5] and " *" or "")) end
        self.actList:SetItems(act)
    end
    return v
end

---------------------------------------------------------------------------
-- History: every look of one character
---------------------------------------------------------------------------
local function Delta(a, b, key)
    local x, y = Audit.V(a, key), Audit.V(b, key)
    if x == nil or y == nil then return nil end
    return y - x
end

local function BuildHistory(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "History")
    v.card:SetAllPoints()
    v.card.sub:SetText("Every saved look, newest first, with the change since the one before.")
    v.list = Style.List(v.card.content, { labelWidth = 110, colWidths = { 110, 110, 110 },
        columns = { name = "Source", label = "When", "Acquired", "Most owned", "Other sources" } })
    v.empty = Note(v)

    function v:Footer() return "A drop in gold acquired means a reset: no change is shown." end

    function v:Refresh()
        local full = Audit.selected
        local c = full and Audit.Record(full)
        self.list:SetShown(c ~= nil)
        self.empty:SetShown(c == nil)
        if not c then
            self.empty:SetText("Pick a character first (Members, Flags or Characters).")
            return
        end
        self.card.title:SetText("History  " .. NameText(full, c.classFile) .. Muted("  " .. #c.snaps .. " looks"))
        local rows = {}
        for i = #c.snaps, 1, -1 do
            local s, prev = c.snaps[i], c.snaps[i - 1]
            local function col(value, d)
                local text = value and (HEX.gold .. Audit.Gold(value) .. "|r") or Muted("?")
                if d and d ~= 0 then text = text .. (d > 0 and (HEX.good .. " +") or (HEX.bad .. " -")) .. Audit.Gold(math.abs(d)) .. "|r" end
                return text
            end
            local reset = prev and Delta(prev, s, "acquired") and Delta(prev, s, "acquired") < 0
            local function d(key) return prev and not reset and Delta(prev, s, key) or nil end
            local oa, ob = prev and Audit.Other(prev), Audit.Other(s)
            rows[#rows + 1] = {
                label = date("%Y-%m-%d %H:%M", s.t), sort = { label = s.t },
                text = (s.src == "shared" and "shared" or s.src == "inspect" and "inspected" or "your own") .. Muted("  level " .. tostring(s.level or "?"))
                    .. (s.seen and Muted("  unchanged to " .. ShortDate(s.seen)) or "") .. (reset and (HEX.gold .. "  reset?|r") or ""),
                cols = { col(Audit.V(s, "acquired"), d("acquired")), col(Audit.V(s, "peak"), d("peak")),
                    col(ob, (not reset and oa and ob) and (ob - oa) or nil) },
                tooltip = function(owner)
                    local lines = { date("%Y-%m-%d %H:%M", s.t), (SOURCE[s.src] or "?") .. Muted(", client " .. tostring(s.build)) }
                    for _, key in ipairs(Audit.SOURCE_KEYS) do
                        local dd = d(key)
                        lines[#lines + 1] = Audit.BY_KEY[key][3] .. ": " .. Gold(Audit.V(s, key))
                            .. (dd and dd ~= 0 and Muted("  (+" .. Audit.Gold(dd) .. ")") or "")
                    end
                    ns.Tooltip.Text(owner, lines)
                end,
            }
        end
        self.list:SetItems(rows)
    end
    return v
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local VIEWS = {
    { key = "members", label = "Members", build = BuildMembers },
    { key = "flags", label = "Flags", build = BuildFlags },
    { key = "characters", label = "Characters", build = BuildCharacters },
    { key = "ledger", label = "Ledger", build = BuildLedger },
    { key = "history", label = "History", build = BuildHistory },
}

local function Build()
    frame = Style.Window(ns.FRAME .. "AuditWindow", "Audit", nil, nil, { nav = "audit" })
    local tabHolder = CreateFrame("Frame", nil, frame)
    tabHolder:SetPoint("TOPLEFT", PAD, -44)
    tabHolder:SetPoint("TOPRIGHT", -PAD, -44)
    tabHolder:SetHeight(26)
    frame.tabs = Style.Tabs(tabHolder, VIEWS, function(key) state.view = key UI.Refresh() end, 100)
    local line = Style.HLine(frame)
    line:SetPoint("TOPLEFT", PAD, -70)
    line:SetPoint("TOPRIGHT", -PAD, -70)

    frame.me = Style.Button(frame, "My character", 104, function() Audit.Request("player") state.view = "ledger" UI.Refresh() end,
        "Reads your own statistics (no request to the server).")
    frame.me:SetPoint("TOPLEFT", PAD, -78)
    frame.target = Style.Button(frame, "Target", 80, function() Audit.Request("target", "window") state.view = "ledger" UI.Refresh() end,
        "Asks the server for your target's statistics: one request per click, player nearby, out of combat.")
    frame.target:SetPoint("LEFT", frame.me, "RIGHT", 4, 0)
    frame.status = Style.Text(frame, "GameFontHighlightSmall")
    frame.status:SetPoint("LEFT", frame.target, "RIGHT", 10, 0)
    frame.status:SetPoint("RIGHT", -PAD, 0)

    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", PAD, -108)
    body:SetPoint("BOTTOMRIGHT", -PAD, 34)
    for _, def in ipairs(VIEWS) do views[def.key] = def.build(body) end
    frame.footer = Style.Text(frame, "GameFontDisableSmall")
    frame.footer:SetPoint("BOTTOMLEFT", PAD + 2, 12)
    frame.footer:SetPoint("RIGHT", -PAD, 0)
    frame:HookScript("OnShow", function()
        Audit.ReadSelf()
        UI.Refresh()
    end)
end

function UI.Refresh()
    if not frame or not frame:IsShown() then return end
    frame.tabs:Select(state.view)
    for key, v in pairs(views) do v:SetShown(key == state.view) end
    local v = views[state.view]
    v:Refresh()
    frame.footer:SetText(v:Footer() or "")
    local supported = Audit.Supported()
    frame.me:SetShown(supported)
    frame.target:SetShown(supported)
    frame.status:SetText(supported and Muted(Audit.status or "Inspect a player, or target one and click Target. Shift + click Delete removes a record.")
        or (HEX.gold .. "The game's statistics exist on WoW Forever only: this client can show saved records but not read new ones.|r"))
end

function UI.Show(view)
    if not frame then
        Build()
        Audit.ReadSelf()
    end
    if view and views[view] then state.view = view end
    if frame:IsShown() then UI.Refresh() else frame:Show() end
end

function UI.Toggle(view)
    if frame and frame:IsShown() and (not view or view == state.view) then frame:Hide() else UI.Show(view) end
end

function UI.IsShown() return frame ~= nil and frame:IsShown() end
UI.views = views
Data.Window(UI, { "audit", "audit.request", "guild" })

---------------------------------------------------------------------------
-- Settings tab
---------------------------------------------------------------------------
local function BuildPage(parent)
    local W = ns.Options.Widgets
    local y = -12
    y = W.Paragraph(parent, y, "Keeps the game's statistics for you, players you inspect and guild members who share theirs: "
        .. "gold acquired, most gold owned, gold by source, auctions, quests, kills, professions. Flags records whose counters do "
        .. "not add up the way played gold does. A flag is a reason to look, not proof. Type |cffffffff" .. ns.Cmd.Text("audit") .. "|r for the window.",
        "GameFontHighlightSmall")
    W.Button(parent, y, "Open the audit window", 200, function() UI.Show() end)
    y = y - 34
    y = W.Header(parent, y, "Reading")
    y = W.Checkbox(parent, y, "auditOnInspect", "Read a player's statistics when I inspect them",
        "One request each time you open the Inspect window. Off: only the Audit button and the Target button ask.")
    y = W.Header(parent, y, "Flags")
    y = W.Slider(parent, y, "auditGapGold", "Peak above recorded income", 5, 500, 5, "%d gold",
        "Most gold ever owned above total gold acquired: gold reached them the counters did not count.")
    y = W.Slider(parent, y, "auditOtherGold", "Income from other sources", 50, 2000, 50, "%d gold",
        "Total acquired minus loot, quests, vendors and auctions (trades, mail...). Flagged above this and the share below.")
    y = W.Slider(parent, y, "auditOtherShare", "... and at least this share of income", 10, 90, 5, "%d%%")
    y = W.Slider(parent, y, "auditJumpGold", "Sudden gold between two looks", 25, 1000, 25, "%d gold",
        "Unexplained gold between two looks at most 14 days apart.")
    y = W.Checkbox(parent, y, "auditLevelRule", "Flag peak gold high for the level (below 55)",
        "A guide from 10 gold at level 10 to 1200 gold at 55. Auction players and alts fed by a main also get here.")
    return -y + 10
end

ns.Options.AddTab({ label = "Audit", pages = { { label = "Audit", build = BuildPage } } })
