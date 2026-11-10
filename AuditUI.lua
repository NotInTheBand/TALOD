-- TALOD - the Audit page: one list of characters (guild members, flagged
-- records, everyone on record) and a detail pane for the one selected (its
-- ledger with the flag rules on top, or its history of looks).

local ADDON_NAME, ns = ...
local Style = ns.Style
local COLORS, HEX = Style.COLORS, Style.HEX
local Audit, Guild, Data = ns.Audit, ns.Guild, ns.Data

local UI = {}
ns.AuditUI = UI

local PAD = 12
local frame
local views = {}
-- scope: guild / flagged / everyone; detail: ledger / history.
local state = { scope = "guild", detail = "ledger", noStats = true, showReviewed = false, membersOnly = false }

local function Hex(c) return string.format("|cff%02x%02x%02x", (c[1] or 1) * 255, (c[2] or 1) * 255, (c[3] or 1) * 255) end
local function NameText(full, classFile) return Hex(ns.ClassColor(classFile)) .. Guild.Short(full) .. "|r" end
local function ShortDate(t) return t and date("%b %d", t) or "?" end
local function Muted(s) return HEX.muted .. s .. "|r" end
local function Gold(n) return n and (HEX.gold .. Audit.Gold(n) .. "|r") or Style.TagText("", "unknown") end
-- A list cell: a counter the game did not give is unknown, never 0.
local function GoldCell(n) return n and (HEX.gold .. Audit.Gold(n) .. "|r") or ns.UNKNOWN end

local function Age(t)
    if not t then return "?" end
    local s = time() - t
    if s < 3600 then return math.max(1, math.floor(s / 60)) .. " min ago" end
    if s < 86400 then return math.floor(s / 3600) .. " h ago" end
    return math.floor(s / 86400) .. " d ago"
end

local SOURCE = { self = "your own", inspect = "inspected (the server's figures)", shared = "shared by them (their addon's figures)" }

-- Built when asked: the colours follow the look and the colorblind setting.
function UI.Badge(flags)
    if not flags then return Style.TagText("no statistics", "unknown") end
    if flags.reviewed then return Muted("Reviewed") end
    if flags.level == "look" then return Style.TagText("Worth a look", "bad") end
    if flags.level == "watch" then return Style.TagText("Watch", "gold") end
    if flags.level == "none" then return Style.TagText("No flags", "good") end
    -- Some rules could not be checked: missing counters never count as fine.
    return Style.TagText("", "unknown")
end

local function Flagged(f) return f ~= nil and (f.level == "look" or f.level == "watch") end

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
    lines[#lines + 1] = Muted("Click: show it in the detail pane.")
    ns.Tooltip.Text(owner, lines)
end

local function Select(full)
    Audit.selected = full
    UI.Refresh()
end

---------------------------------------------------------------------------
-- The character list: Guild / Flagged / Everyone
---------------------------------------------------------------------------
local SCOPES = { { key = "guild", label = "Guild" }, { key = "flagged", label = "Flagged" }, { key = "everyone", label = "Everyone" } }
local TOGGLES = {
    { key = "noStats", label = "No statistics" }, { key = "showReviewed", label = "Show reviewed" },
    { key = "membersOnly", label = "Members only" },
}
local COLUMNS = {
    guild = { name = "Member", label = "Lvl", "Most owned", "Acquired", "Last look" },
    flagged = { name = "Character", label = "Lvl", "Most owned", "Other sources", "Last look" },
    everyone = { name = "Character", label = "Lvl", "Most owned", "Acquired", "Last look" },
}
local EMPTY = {
    guild = "No members to show.",
    flagged = "Nothing flagged.",
    everyone = "No statistics yet. Click My character, or target a player and click Target.",
}

-- Which records each chip shows. Members without statistics come last
-- (No statistics on): they are unknown, so they are never left out as fine.
local function Wanted(x, scope)
    if scope == "guild" then return x.member end
    if state.membersOnly and not x.member then return false end
    if scope == "flagged" then return Flagged(x.flags) and (state.showReviewed or not x.flags.reviewed) end
    return true
end

function UI.Rows(scope)
    scope = scope or state.scope
    local rows, counts = {}, { guild = 0, flagged = 0, everyone = 0 }
    local known = {}
    for _, x in ipairs(Audit.Rows()) do
        known[x.full] = true
        counts.everyone = counts.everyone + 1
        if x.member then counts.guild = counts.guild + 1 end
        if Flagged(x.flags) and not x.flags.reviewed then counts.flagged = counts.flagged + 1 end
        if Wanted(x, scope) then rows[#rows + 1] = x end
    end
    Audit.Sort(rows, "flags")
    local missing = {}
    local g = Guild.Mine() and Guild.Data()
    if g then
        for full, m in pairs(g.members) do
            if not m.missing and not known[full] then missing[#missing + 1] = { full = full, m = m, missing = true } end
        end
        table.sort(missing, function(a, b) return a.full < b.full end)
    end
    counts.missing = #missing
    if state.noStats then
        for _, x in ipairs(missing) do rows[#rows + 1] = x end
    end
    return rows, counts
end

local function CharacterRow(x)
    if x.missing then
        local m = x.m
        return {
            label = tostring(m.level or "?"), sort = { label = m.level },
            text = NameText(x.full, m.classFile) .. Muted("  " .. tostring(m.rankName or "")) .. "   " .. UI.Badge(nil),
            cols = { ns.UNKNOWN, ns.UNKNOWN, Muted("-") },
            tooltip = function(owner)
                ns.Tooltip.Text(owner, { Guild.Short(x.full), "No statistics yet.",
                    Muted("Inspect them (the Audit button on the Inspect window), or ask members to share (officers).") })
            end,
        }
    end
    local s = x.snap
    local level = s.level or x.c.level or (x.m and x.m.level)
    local first = x.flags and x.flags.list[1]
    local scope = state.scope
    return {
        label = tostring(level or "?"), sort = { label = level },
        text = NameText(x.full, x.c.classFile or (x.m and x.m.classFile))
            .. (scope == "guild" and x.m and Muted("  " .. tostring(x.m.rankName or "")) or "")
            .. (scope ~= "guild" and x.member and Muted("  member") or "")
            .. (scope ~= "guild" and s.guild and not x.member and Muted("  <" .. s.guild .. ">") or "")
            .. "   " .. UI.Badge(x.flags) .. (first and Muted("  " .. first.title) or ""),
        cols = { GoldCell(Audit.V(s, "peak")), GoldCell(scope == "flagged" and Audit.Other(s) or Audit.V(s, "acquired")), Muted(Age(s.t)) },
        accent = x.flags and not x.flags.reviewed and x.flags.level == "look" and COLORS.bad or nil,
        tooltip = function(owner) RecordTooltip(owner, x) end,
    }
end

local function BuildList(parent)
    local v = CreateFrame("Frame", nil, parent)
    v.card = Style.Card(v, "Characters")
    v.card:SetAllPoints()
    v.list = Style.List(v.card.content, { labelWidth = 28, colWidths = { 84, 84, 60 }, search = true, hint = "Search names, ranks, guilds...",
        columns = COLUMNS.guild,
        selected = function(item) return item.full ~= nil and item.full == Audit.selected end,
        onClick = function(item) if item.full then Select(item.full) end end })
    local shownScope = "guild"

    function v:Refresh()
        local scope = state.scope
        if shownScope ~= scope then
            shownScope = scope
            self.list:SetColumns(COLUMNS[scope])
        end
        local data = Data.List(self.list, {
            name = "audit:list", sources = { "audit", "guild" }, maxAge = 60, empty = EMPTY[scope],
            key = { scope, state.noStats, state.showReviewed, state.membersOnly, Guild.Key() },
            build = function(add)
                local rows, counts = UI.Rows(scope)
                for _, x in ipairs(rows) do
                    local search = Guild.Short(x.full) .. " " .. tostring(x.m and x.m.rankName or "") .. " "
                        .. tostring(x.snap and x.snap.guild or "")
                    add(x, { full = x.full, search = search })
                end
                counts.n = #rows
                return counts
            end,
            row = CharacterRow,
        })
        self.counts = data
        local g = Guild.Mine()
        self.card.sub:SetText(scope == "guild" and not g and "You are not in a guild: Everyone lists every record."
            or (data.n .. " shown" .. (data.missing > 0 and ("  ·  " .. data.missing .. " members without statistics") or "")))
    end
    return v
end

---------------------------------------------------------------------------
-- Detail: Ledger
---------------------------------------------------------------------------
local function CounterRow(snap, key, label)
    local f = Audit.BY_KEY[key]
    local value = Audit.Value(snap, key)
    return {
        text = label or f[3],
        cols = { value and (f[4] and (HEX.gold .. value .. "|r") or (HEX.white .. value .. "|r")) or ns.UNKNOWN },
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

local function LedgerRows(snap)
    local g = {}
    g[#g + 1] = { header = true, text = "Income" }
    for _, key in ipairs({ "acquired", "peak", "looted", "quests", "vendors", "auctions" }) do g[#g + 1] = CounterRow(snap, key) end
    local other = Audit.Other(snap)
    g[#g + 1] = { text = "Other sources (trade, mail, ...)", cols = { GoldCell(other) },
        tooltip = function(owner) ns.Tooltip.Text(owner, { "Other sources",
            "Total gold acquired minus loot, quests, vendors and auctions. Unknown when any of those is missing." }) end }
    local gap = Audit.Gap(snap)
    g[#g + 1] = { text = "Peak above recorded income", cols = { GoldCell(gap) },
        tooltip = function(owner) ns.Tooltip.Text(owner, { "Peak above recorded income",
            "Most gold ever owned minus total gold acquired, at least 0. Above 0, gold reached them that the counters did not count." }) end }
    if snap.wallet then g[#g + 1] = { text = "Gold carried now", cols = { HEX.gold .. Audit.Gold(snap.wallet) .. "|r" } } end
    g[#g + 1] = { header = true, text = "Auctions" }
    for _, key in ipairs({ "posted", "purchases", "largestSale", "largestBid" }) do g[#g + 1] = CounterRow(snap, key) end
    g[#g + 1] = { header = true, text = "Spending" }
    for _, key in ipairs({ "daily", "travel", "postage", "barber", "respec" }) do g[#g + 1] = CounterRow(snap, key) end
    g[#g + 1] = { header = true, text = "Activity" }
    for _, key in ipairs(Audit.ACTIVITY_KEYS) do g[#g + 1] = CounterRow(snap, key) end
    g[#g + 1] = { header = true, text = "Professions" }
    local profs = {}
    for _, key in ipairs(Audit.PROFESSION_KEYS) do profs[#profs + 1] = { key = key, n = Audit.V(snap, key) } end
    table.sort(profs, function(x, y)
        if (x.n == nil) ~= (y.n == nil) then return x.n ~= nil end
        if x.n ~= y.n then return x.n > y.n end
        return x.key < y.key
    end)
    for _, p in ipairs(profs) do g[#g + 1] = CounterRow(snap, p.key, Audit.BY_KEY[p.key][3] .. (Audit.BY_KEY[p.key][5] and " *" or "")) end
    return g
end

local function NoteBox(parent)
    local box = CreateFrame("EditBox", nil, parent)
    box:SetHeight(22)
    box:SetAutoFocus(false)
    box:SetFontObject("GameFontHighlightSmall")
    box:SetTextInsets(8, 8, 0, 0)
    box:SetMaxLetters(200)
    local bg = Style.Texture(box, "BACKGROUND", Style.IsLedger() and COLORS.well or COLORS.button)
    bg:SetAllPoints()
    Style.Border(box, COLORS.border)
    box.hint = Style.Text(box, "GameFontDisableSmall")
    box.hint:SetPoint("LEFT", 8, 0)
    box.hint:SetText("Note (Enter saves)")
    box:SetScript("OnTextChanged", function(self) self.hint:SetShown((self:GetText() or "") == "") end)
    box:SetScript("OnEnterPressed", function(self)
        if Audit.selected then Audit.SetNote(Audit.selected, self:GetText()) end
        self:ClearFocus()
    end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() UI.Refresh() end)
    return box
end

local function BuildLedger(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    -- The flag rules of a flagged character, on top.
    v.notice = Style.Notice(nil, nil, { flat = true, parent = v, width = 360, tone = "bad" })
    v.notice:SetPoint("TOPLEFT", 4, -4)
    v.notice:SetPoint("TOPRIGHT", -4, -4)
    v.summary = Style.Text(v, "GameFontHighlightSmall")
    if v.summary.SetWordWrap then v.summary:SetWordWrap(true) end
    v.summary:SetJustifyV("TOP")
    if v.summary.SetSpacing then v.summary:SetSpacing(3) end

    local actions = CreateFrame("Frame", nil, v)
    actions:SetHeight(22)
    v.actions = actions
    v.ok = Style.Button(actions, "Looked: fine", 96, function()
        if Audit.selected then Audit.SetReview(Audit.selected, "ok") end
    end, "Marks the flags you see now as reviewed. A new flag brings the record back.")
    v.ok:SetPoint("LEFT")
    v.watch = Style.Button(actions, "Watch", 64, function()
        if Audit.selected then Audit.SetReview(Audit.selected, "watch") end
    end, "Keeps this record on watch (shown in its tooltip).")
    v.watch:SetPoint("LEFT", v.ok, "RIGHT", 4, 0)
    v.clear = Style.Button(actions, "Clear review", 92, function()
        if Audit.selected then Audit.SetReview(Audit.selected, nil) end
    end)
    v.clear:SetPoint("LEFT", v.watch, "RIGHT", 4, 0)
    v.delete = Style.Button(actions, "Delete", 70, function()
        if Audit.selected and IsShiftKeyDown() then
            Audit.Delete(Audit.selected)
            Audit.selected = nil
            UI.Refresh()
        else
            ns.Print("Shift + click Delete to remove this character's record.")
        end
    end, "Shift + click: removes every look of this character from your saved data.")
    v.delete:SetPoint("RIGHT")
    v.note = NoteBox(v)

    local holder = CreateFrame("Frame", nil, v)
    holder:SetPoint("BOTTOMRIGHT")
    v.holder = holder
    v.list = Style.List(holder, { colWidths = { 110 } })

    -- Everything under the notice follows its height (it grows with the rules).
    local function Place(top)
        v.summary:ClearAllPoints()
        v.summary:SetPoint("TOPLEFT", 8, top - 6)
        v.summary:SetPoint("RIGHT", -8, 0)
        local h = math.max(14, v.summary:GetStringHeight() or 14)
        local y = top - 6 - h - 8
        actions:ClearAllPoints()
        actions:SetPoint("TOPLEFT", 4, y)
        actions:SetPoint("TOPRIGHT", -4, y)
        v.note:ClearAllPoints()
        v.note:SetPoint("TOPLEFT", 4, y - 26)
        v.note:SetPoint("TOPRIGHT", -4, y - 26)
        holder:SetPoint("TOPLEFT", 0, y - 54)
    end

    function v:Footer() return Audit.DISCLAIMER end

    function v:Refresh(full, c, snap)
        local flags = Audit.FlagsOf(full)
        local top = 0
        if Flagged(flags) or (flags.level == "unknown" and #flags.list == 0) then
            local blocks = {}
            for _, f in ipairs(flags.list) do blocks[#blocks + 1] = { heading = f.title, text = f.text } end
            local tone, headline, sub
            if Flagged(flags) then
                local strong = false
                for _, f in ipairs(flags.list) do if f.weight >= 2 then strong = true end end
                tone = strong and "bad" or "gold"
                headline = flags.level == "look" and "Worth a look" or "Watch"
                sub = "Counters that do not add up the way played gold does. A reason to look, not proof: check before you act."
            else
                tone, headline = "unknown", "Some rules could not be checked"
                sub = "Counters are missing. A missing counter never raises or clears a flag, and is never counted as fine."
            end
            self.notice:Set({ tone = tone, headline = headline, sub = sub, pages = { { key = "rules", blocks = blocks } } })
            self.notice:Show()
            top = -(4 + (self.notice:GetHeight() or 60))
        else
            self.notice:Hide()
        end
        local member, m = Audit.IsMember(full)
        local a = Audit.Assess(snap)
        local lines = {}
        lines[#lines + 1] = "Activity: " .. HEX.white .. a.title .. "|r" .. Muted("  " .. a.summary .. "  (" .. a.coverage .. ")")
        lines[#lines + 1] = "Flags: " .. UI.Badge(flags) .. Muted("  ·  last look " .. Age(snap.t) .. ", " .. (SOURCE[snap.src] or "?"))
        local r = c.review
        if r and r.state then
            lines[#lines + 1] = Muted((r.state == "ok" and "Reviewed as fine" or "On watch") .. " by " .. Guild.Short(r.by) .. ", " .. ShortDate(r.t))
        end
        lines[#lines + 1] = Muted(#c.snaps .. " looks since " .. ShortDate(c.first) .. "  ·  " .. snap.n .. " / " .. #Audit.FIELDS
            .. " counters" .. (member and ("  ·  " .. tostring(m.rankName or "member")) or ""))
        self.summary:SetText(table.concat(lines, "\n"))
        Place(top)
        self.ok:SetOn(r and r.state == "ok")
        self.watch:SetOn(r and r.state == "watch")
        if not self.note:HasFocus() then self.note:SetText(r and r.note or "") end
        self.list:SetItems(LedgerRows(snap))
    end
    return v
end

---------------------------------------------------------------------------
-- Detail: History, every look of one character
---------------------------------------------------------------------------
local function Delta(a, b, key)
    local x, y = Audit.V(a, key), Audit.V(b, key)
    if x == nil or y == nil then return nil end
    return y - x
end

local function BuildHistory(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.list = Style.List(v, { colWidths = { 84, 84, 84 },
        columns = { name = "Look", "Acquired", "Most owned", "Other sources" } })

    function v:Footer() return "Every saved look, newest first. A drop in gold acquired means a reset: no change is shown." end

    function v:Refresh(full, c)
        local rows = {}
        for i = #c.snaps, 1, -1 do
            local s, prev = c.snaps[i], c.snaps[i - 1]
            local function col(value, d)
                if not value then return ns.UNKNOWN end
                local text = HEX.gold .. Audit.Gold(value) .. "|r"
                if d and d ~= 0 then text = text .. (d > 0 and (HEX.good .. " +") or (HEX.bad .. " -")) .. Audit.Gold(math.abs(d)) .. "|r" end
                return text
            end
            local reset = prev and Delta(prev, s, "acquired") and Delta(prev, s, "acquired") < 0
            local function d(key) return prev and not reset and Delta(prev, s, key) or nil end
            local oa, ob = prev and Audit.Other(prev), Audit.Other(s)
            rows[#rows + 1] = {
                sort = { [0] = s.t },
                text = date("%b %d %H:%M", s.t) .. Muted("  " .. (s.src == "shared" and "shared" or s.src == "inspect" and "inspected" or "own")
                    .. "  " .. tostring(s.level or "?")) .. (reset and (HEX.gold .. "  reset?|r") or ""),
                cols = { col(Audit.V(s, "acquired"), d("acquired")), col(Audit.V(s, "peak"), d("peak")),
                    col(ob, (not reset and oa and ob) and (ob - oa) or nil) },
                tooltip = function(owner)
                    local lines = { date("%Y-%m-%d %H:%M", s.t), (SOURCE[s.src] or "?") .. Muted(", client " .. tostring(s.build)) }
                    if s.seen then lines[#lines + 1] = Muted("Unchanged up to " .. ShortDate(s.seen)) end
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

local DETAILS = { { key = "ledger", label = "Ledger" }, { key = "history", label = "History" } }

local function BuildDetail(parent)
    local v = CreateFrame("Frame", nil, parent)
    v.card = Style.Card(v, "")
    v.card:SetAllPoints()
    v.switch = Style.Views(v.card, DETAILS, function(key) state.detail = key UI.Refresh() end)
    v.switch:SetPoint("TOPRIGHT", -6, -math.floor((Style.M.cardHeader - 20) / 2))
    -- Ledger: title and sub share the header line; classic: two lines.
    if not Style.IsLedger() then v.card.title:SetPoint("RIGHT", v.switch, "LEFT", -8, 0) end
    v.card.sub:SetPoint("RIGHT", v.switch, "LEFT", -8, 0)
    v.ledger = BuildLedger(v.card.content)
    v.history = BuildHistory(v.card.content)
    v.empty = Style.Text(v.card.content, "GameFontDisable", "CENTER")
    v.empty:SetPoint("TOPLEFT", 12, -40)
    v.empty:SetPoint("RIGHT", -12, 0)
    if v.empty.SetWordWrap then v.empty:SetWordWrap(true) end

    function v:Footer() return state.detail == "history" and self.history:Footer() or self.ledger:Footer() end

    function v:Refresh()
        self.switch:Select(state.detail)
        local full = Audit.selected
        local c = full and Audit.Record(full)
        local snap = Audit.Latest(c)
        self.ledger:SetShown(snap ~= nil and state.detail == "ledger")
        self.history:SetShown(c ~= nil and state.detail == "history")
        self.empty:SetShown(snap == nil)
        if not full then
            self.card.title:SetText("No character selected")
            self.card.sub:SetText("")
            self.empty:SetText("Pick a character in the list, or click My character / Target above.")
            return
        end
        local _, m = Audit.IsMember(full)
        local level = snap and snap.level or (c and c.level) or (m and m.level)
        self.card.title:SetText(NameText(full, (c and c.classFile) or (m and m.classFile)))
        self.card.sub:SetText(Muted(tostring(level or "?") .. (snap and snap.guild and ("  <" .. snap.guild .. ">") or "")))
        if not snap then
            self.empty:SetText(Guild.Short(full) .. ": no statistics yet. Target them nearby and click Target, "
                .. "or open their Inspect window.")
            return
        end
        if state.detail == "history" then self.history:Refresh(full, c) else self.ledger:Refresh(full, c, snap) end
    end
    return v
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
-- /talod audit status, and the status line's tooltip.
local function StatusTip(owner)
    local lines = { "Statistics", Audit.status or "No request yet." }
    for _, line in ipairs(Audit.StatusLines and Audit.StatusLines() or {}) do lines[#lines + 1] = Muted(line) end
    lines[#lines + 1] = Muted("Also " .. ns.Cmd.Text("audit", "status") .. ".")
    ns.Tooltip.Text(owner, lines)
end

local function Build()
    frame = Style.Window(ns.FRAME .. "AuditWindow", "Audit", nil, nil, { nav = "audit", settings = "audit", section = "Guild" })
    local top = Style.M.titleBar + 10

    -- Title bar: My character, Target (one comparison request per click), status.
    frame.target = Style.Button(frame, "Target", 78, function()
        Audit.Request("target", "window")
        state.detail = "ledger"
        UI.Refresh()
    end, "Asks the server for your target's statistics: one request per click, player nearby, out of combat, 5 s apart.",
        { kind = "send" })
    frame.me = Style.Button(frame, "My character", 100, function()
        Audit.Request("player")
        state.detail = "ledger"
        UI.Refresh()
    end, "Reads your own statistics (no request to the server).")
    frame.header:Add(frame.target)
    frame.header:Add(frame.me)
    frame:SetStatus("")
    frame.statusHit = CreateFrame("Button", nil, frame)
    frame.statusHit:SetAllPoints(frame.status)
    frame.statusHit:SetScript("OnEnter", StatusTip)
    frame.statusHit:SetScript("OnLeave", function() ns.Tooltip.Hide() end)

    -- Toolbar: the three filters, the switches, Ask members.
    frame.scopes = Style.Chips(frame, SCOPES, function(key)
        state.scope = key
        UI.Refresh()
    end)
    frame.scopes:SetPoint("TOPLEFT", PAD, -top)
    frame.toggles = Style.Chips(frame, TOGGLES, function(key, on)
        state[key] = on and true or false
        UI.Refresh()
    end)
    frame.toggles:SetPoint("LEFT", frame.scopes, "RIGHT", 14, 0)
    frame.ask = Style.Button(frame, "Ask members", 110, function()
        if ns.GuildSync then ns.GuildSync.RequestMembers() end
        UI.Refresh()
    end, "One request to the guild. Each member's addon answers with only what that member said Yes to "
        .. "(Members page, Sharing: \"Gold and activity statistics\").", { kind = "send", small = true })
    frame.ask:SetPoint("TOPRIGHT", -PAD, -top)

    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", PAD, -(top + 28))
    body:SetPoint("BOTTOMRIGHT", -PAD, 34)
    views.list = BuildList(body)
    views.detail = BuildDetail(body)
    views.list:SetPoint("TOPLEFT")
    views.list:SetPoint("BOTTOMLEFT")
    views.list:SetPoint("RIGHT", body, "CENTER", -4, 0)
    views.detail:SetPoint("TOPLEFT", body, "TOP", 4, 0)
    views.detail:SetPoint("BOTTOMRIGHT")
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
    frame.scopes:Select(state.scope)
    for _, t in ipairs(TOGGLES) do frame.toggles:SetOn(t.key, state[t.key]) end
    views.list:Refresh()
    local counts = views.list.counts or {}
    for _, s in ipairs(SCOPES) do frame.scopes:SetCount(s.key, counts[s.key]) end
    views.detail:Refresh()
    frame.footer:SetText(views.detail:Footer() or "")
    local supported = Audit.Supported()
    -- Members share statistics only where the game has them (Forever).
    local officer = supported and ns.GuildSync and ns.GuildSync.IAmOfficer() and Guild.Mine()
    frame.ask:SetShown(state.scope == "guild" and officer and true or false)
    frame.me:SetShown(supported)
    frame.target:SetShown(supported)
    frame:SetStatus(supported and (Audit.status or "Statistics: 1 request per click")
        or (HEX.gold .. "The game's statistics exist on WoW Forever only: saved records show, new ones cannot be read.|r"))
end

-- Old and new names of what the page shows: the three filters, the two
-- views of the selected character.
local SCOPE_OF = { guild = "guild", members = "guild", flagged = "flagged", flags = "flagged", everyone = "everyone",
    characters = "everyone" }
local DETAIL_OF = { ledger = "ledger", history = "history" }

local function Apply(word)
    if type(word) ~= "string" then return end
    word = word:lower()
    if SCOPE_OF[word] then state.scope = SCOPE_OF[word] end
    if DETAIL_OF[word] then state.detail = DETAIL_OF[word] end
end

-- The page contract: tab (none here) or view = a filter or a detail view;
-- arg = a character's full name to select.
function UI.ShowPage(tab, view, arg)
    if not frame then
        Build()
        Audit.ReadSelf()
    end
    Apply(tab)
    Apply(view)
    if type(arg) == "string" and arg ~= "" then Audit.selected = arg end
    if frame:IsShown() then UI.Refresh() else frame:Show() end
    return true
end

function UI.Show(view) return UI.ShowPage(nil, view) end

function UI.Toggle(view)
    if frame and frame:IsShown() and not view then frame:Hide() else UI.Show(view) end
end

function UI.IsShown() return frame ~= nil and frame:IsShown() end

-- Home and the page list: how many records are flagged (not reviewed).
function UI.PageStatus()
    local n = Data.Memo("audit:flagged", Data.Key({ "audit", "guild" }), function()
        local count = 0
        for _, x in ipairs(Audit.Rows()) do
            if Flagged(x.flags) and not x.flags.reviewed then count = count + 1 end
        end
        return count
    end)
    if n > 0 then return { text = n .. " flagged", tone = "bad" } end
    return nil
end

UI.views, UI.state = views, state
function UI.Frame() return frame end
Data.Window(UI, { "audit", "audit.request", "guild" })

---------------------------------------------------------------------------
-- Settings tab
---------------------------------------------------------------------------
local function ReadingGroup(parent, y)
    local W = ns.Options.Widgets
    y = W.Paragraph(parent, y, "Keeps the game's statistics for you, players you inspect and guild members who share theirs: "
        .. "gold acquired, most gold owned, gold by source, auctions, quests, kills, professions. Flags records whose counters do "
        .. "not add up the way played gold does. A flag is a reason to look, not proof. Type |cffffffff" .. ns.Cmd.Text("audit") .. "|r for the window.",
        "GameFontHighlightSmall")
    y = W.Checkbox(parent, y, "auditOnInspect", "Read a player's statistics when I inspect them",
        "One request each time you open the Inspect window. Off: only the Audit button and the Target button ask.")
    return y
end

local function FlagsGroup(parent, y)
    local W = ns.Options.Widgets
    y = W.Fine(parent, y)
    y = W.Slider(parent, y, "auditGapGold", "Peak above recorded income", 5, 500, 5, "%d gold",
        "Most gold ever owned above total gold acquired: gold reached them the counters did not count.")
    y = W.Slider(parent, y, "auditOtherGold", "Income from other sources", 50, 2000, 50, "%d gold",
        "Total acquired minus loot, quests, vendors and auctions (trades, mail...). Flagged above this and the share below.")
    y = W.Slider(parent, y, "auditOtherShare", "... and at least this share of income", 10, 90, 5, "%d%%")
    y = W.Slider(parent, y, "auditJumpGold", "Sudden gold between two looks", 25, 1000, 25, "%d gold",
        "Unexplained gold between two looks at most 14 days apart.")
    y = W.Checkbox(parent, y, "auditLevelRule", "Flag peak gold high for the level (below 55)",
        "A guide from 10 gold at level 10 to 1200 gold at 55. Auction players and alts fed by a main also get here.")
    return y
end

ns.Options.AddSection("audit", {
    status = function()
        local n = 0
        for _ in pairs(ns.Audit.Records() or {}) do n = n + 1 end
        return n .. (n == 1 and " character kept" or " characters kept")
    end,
    groups = { { label = "Reading", build = ReadingGroup }, { label = "Flag thresholds", build = FlagsGroup } },
})
