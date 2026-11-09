-- TALOD - Economy window (/talod economy): money for the whole account
-- (or one character), in the shared Style. Tabs: Overview (tiles, gold over
-- time, by source, per day), Transactions (filterable list), Auctions
-- (every listing and how it ended), Trades (with whom, what went each way).

local ADDON_NAME, ns = ...
local Economy = ns.Economy
local Style = ns.Style
local COLORS, HEX = Style.COLORS, Style.HEX
local FormatMoney = Economy.FormatMoney

local UI = {}
ns.EconomyUI = UI

local PAD = 12
local RANGES = { { 1, "Today" }, { 7, "7 days" }, { 30, "30 days" }, { 0, "All" } }
local state = { view = "overview", scope = "all", range = 7, hidden = {}, auctionFilter = "all" }
UI.state = state
local frame
local views = {}

local function db() return ns.DB() end
local KIND_LABEL = {}
for _, k in ipairs(Economy.KINDS) do KIND_LABEL[k.key] = k.label end

local function RangeStart()
    if state.range == 0 then return nil end
    return Economy.DayStart(nil, state.range - 1)
end

local function RangeLabel()
    for _, r in ipairs(RANGES) do if r[1] == state.range then return r[2] end end
    return "?"
end

local function ScopeLabel()
    return state.scope == "all" and "All characters" or state.scope
end

local function Today(t) return date("%Y-%m-%d", t) end

-- Every log entry in scope and range, newest first, with its character.
local function Entries(filter)
    local out = {}
    local since = RangeStart()
    for key, c in pairs(Economy.Scope(state.scope)) do
        for _, e in ipairs(c.log or {}) do
            if (not since or (e.t2 or e.t) >= since) and (not filter or filter(e)) then out[#out + 1] = { e = e, char = key } end
        end
    end
    table.sort(out, function(a, b) return a.e.t > b.e.t end)
    return out
end

-- A tab's own filters, for Data.List (the data itself is the "economy" source).
local function ViewKey(...)
    return { state.scope, tostring(RangeStart()), ... }
end

local function HiddenKey()
    local parts = {}
    for _, k in ipairs(Economy.KINDS) do if state.hidden[k.key] then parts[#parts + 1] = k.key end end
    return table.concat(parts, ",")
end

local function ItemsText(list, max)
    if not list or #list == 0 then return nil end
    local parts = {}
    for i, it in ipairs(list) do
        if i > (max or 2) then parts[#parts + 1] = HEX.muted .. "+" .. (#list - (max or 2)) .. " more|r" break end
        local link, n = it[1] or it.link, it[2] or it.n
        parts[#parts + 1] = (n and n > 1 and (n .. "x ") or "") .. tostring(link or "?")
    end
    return table.concat(parts, ", ")
end

local function Paint(b, on)
    b.borderColor = on and COLORS.accent or nil
    local col = on and COLORS.accent or COLORS.border
    b:SetBorderColor(col[1], col[2], col[3], 1)
    b.label:SetTextColor(on and 1 or 0.45, on and 1 or 0.45, on and 1 or 0.45)
end

local function CharShort(key)
    return state.scope == "all" and (HEX.muted .. tostring(key):match("^([^-]+)") .. "|r  ") or ""
end

local function EntryTooltip(owner, item)
    local e = item.e
    local lines = { (KIND_LABEL[e.kind] or e.kind) .. (e.detail and (": " .. e.detail) or ""),
        date("%b %d %H:%M", e.t) .. ((e.t2 and e.t2 ~= e.t) and (" - " .. date("%H:%M", e.t2)) or "")
            .. (e.zone and ("  ·  " .. e.zone) or "") .. (e.level and ("  ·  level " .. e.level) or ""),
        "Character: " .. tostring(item.char) }
    if e.amount ~= 0 then lines[#lines + 1] = "Money: " .. FormatMoney(e.amount, true) end
    if e.gave or e.got then
        lines[#lines + 1] = "You gave: " .. (ItemsText(e.gave, 7) or "nothing") .. "  " .. FormatMoney(e.gaveMoney or 0)
        lines[#lines + 1] = "You got: " .. (ItemsText(e.got, 7) or "nothing") .. "  " .. FormatMoney(e.gotMoney or 0)
    else
        if e.gained then lines[#lines + 1] = "Got: " .. ItemsText(e.gained, 10) end
        if e.lost then lines[#lines + 1] = "Gave: " .. ItemsText(e.lost, 10) end
    end
    if e.refund then lines[#lines + 1] = "Your own money back (bid or deposit): " .. FormatMoney(e.refund) .. HEX.muted .. "  not income|r" end
    if e.value then lines[#lines + 1] = "Items' vendor value: " .. FormatMoney(e.value) end
    -- The kept items at your Auction House prices (after the cut).
    if ns.Prices and ns.Market and e.gained then
        -- Whole copper as the seller is paid; items with no price are said, never 0.
        local ah, priced = 0, 0
        for _, it in ipairs(e.gained) do
            local id = type(it[1]) == "string" and tonumber(it[1]:match("item:(%d+)")) or nil
            local p = id and ns.Prices.Get(id)
            if p then ah, priced = ah + ns.Market.NetTotal(p * (it[2] or 1)), priced + 1 end
        end
        if priced > 0 then
            lines[#lines + 1] = "On the Auction House: " .. FormatMoney(ah) .. HEX.muted .. " (after the cut, your last looks"
                .. (priced < #e.gained and (string.format("; %d of %d items priced", priced, #e.gained)) or "") .. ")|r"
        end
    end
    if e.kind == "transfer" then lines[#lines + 1] = HEX.muted .. "Between your own characters: not income or spending for the account.|r" end
    ns.Tooltip.Text(owner, lines)
end
UI.EntryTooltip = EntryTooltip

local function EntryRow(item)
    local e = item.e
    local items
    if e.gave or e.got then
        local gave, got = ItemsText(e.gave), ItemsText(e.got)
        items = (got and ("got " .. got) or "") .. ((got and gave) and "  ·  " or "") .. (gave and ("gave " .. gave) or "")
    else
        local gained, lost = ItemsText(e.gained), ItemsText(e.lost)
        items = (gained and ("+ " .. gained) or "") .. ((gained and lost) and "  ·  " or "") .. (lost and ("- " .. lost) or "")
    end
    local text = CharShort(item.char) .. HEX.gold .. (KIND_LABEL[e.kind] or e.kind) .. "|r"
        .. (e.detail and ("  " .. e.detail) or "") .. (e.count and e.count > 1 and (HEX.muted .. "  x" .. e.count .. "|r") or "")
        .. ((items and items ~= "" and not (e.sub == "posted")) and ("  " .. items) or "")
    return { label = date("%b %d %H:%M", e.t), text = text,
        cols = { e.amount ~= 0 and FormatMoney(e.amount, true) or (HEX.dim .. "-|r") },
        tooltip = function(owner) EntryTooltip(owner, item) end }
end

---------------------------------------------------------------------------
-- Overview
---------------------------------------------------------------------------
local function BuildOverview(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.tiles = {}
    for i = 1, 6 do
        local t = CreateFrame("Frame", nil, v)
        t:SetHeight(58)
        local bg = Style.Texture(t, "BACKGROUND", { 1, 1, 1, 0.035 })
        bg:SetAllPoints()
        Style.Border(t, COLORS.cardBorder)
        t.label = Style.Text(t, "GameFontDisableSmall")
        t.label:SetPoint("TOPLEFT", 10, -8)
        t.label:SetPoint("RIGHT", -8, 0)
        t.value = Style.Text(t, "GameFontHighlightLarge")
        t.value:SetPoint("TOPLEFT", 10, -24)
        t.value:SetPoint("RIGHT", -8, 0)
        t.sub = Style.Text(t, "GameFontDisableSmall")
        t.sub:SetPoint("BOTTOMLEFT", 10, 6)
        t.sub:SetPoint("RIGHT", -8, 0)
        t:EnableMouse(true)
        t:SetScript("OnEnter", function(self) if self.tip then ns.Tooltip.Text(self, self.tip) end end)
        t:SetScript("OnLeave", function() ns.Tooltip.Hide() end)
        v.tiles[i] = t
    end
    v:SetScript("OnSizeChanged", function(self)
        local w = ((self:GetWidth() or 870) - 5 * 8) / 6
        for i, t in ipairs(self.tiles) do
            t:ClearAllPoints()
            t:SetWidth(w)
            t:SetPoint("TOPLEFT", (i - 1) * (w + 8), 0)
        end
    end)
    v:GetScript("OnSizeChanged")(v)

    -- Gold over time.
    v.chartCard = Style.Card(v, "Gold over time")
    v.chartCard:SetPoint("TOPLEFT", 0, -66)
    v.chartCard:SetPoint("BOTTOMLEFT")
    v.chartCard:SetWidth(520)
    local plot = CreateFrame("Frame", nil, v.chartCard.content)
    plot:SetPoint("TOPLEFT", 64, -12)
    plot:SetPoint("BOTTOMRIGHT", -14, 26)
    plot:EnableMouse(true)
    v.plot = plot
    plot.grid, plot.labels, plot.lines, plot.dots, plot.ticks = {}, {}, {}, {}, {}
    for i = 1, 4 do
        plot.grid[i] = Style.HLine(plot, i == 1 and { 1, 1, 1, 0.2 } or COLORS.grid)
        plot.labels[i] = Style.Text(plot, "GameFontDisableSmall", "RIGHT")
        plot.labels[i]:SetWidth(60)
    end
    plot.cross = Style.Texture(plot, "OVERLAY", { 1, 1, 1, 0.25 })
    plot.cross:SetWidth(1)
    plot.cross:Hide()
    plot.empty = Style.Text(plot, "GameFontDisable", "CENTER")
    plot.empty:SetPoint("CENTER")

    function plot:Draw(series)
        for _, l in pairs(self.lines) do l:Hide() end
        for _, d in pairs(self.dots) do d:Hide() end
        for _, t in pairs(self.ticks) do t:Hide() end
        self.series = series
        local n = #series
        self.empty:SetText(n == 0 and "No gold history yet." or "")
        self.empty:SetShown(n == 0)
        for i = 1, 4 do self.grid[i]:SetShown(n > 0) self.labels[i]:SetShown(n > 0) end
        if n == 0 then return end
        local lo, hi = math.huge, -math.huge
        for _, p in ipairs(series) do lo, hi = math.min(lo, p[2]), math.max(hi, p[2]) end
        local pad = math.max(100, (hi - lo) * 0.1)
        lo, hi = math.max(0, lo - pad), hi + pad
        local W, H = self:GetWidth() or 420, self:GetHeight() or 300
        if W < 10 or H < 10 then return end
        local function X(i) return n > 1 and (i - 1) / (n - 1) * (W - 12) + 6 or W / 2 end
        local function Y(m) return (m - lo) / (hi - lo) * H end
        self.X = X
        for i = 1, 4 do
            local f = (i - 1) / 3
            local y = f * H
            self.grid[i]:ClearAllPoints()
            self.grid[i]:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", 0, y)
            self.grid[i]:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", 0, y)
            self.labels[i]:ClearAllPoints()
            self.labels[i]:SetPoint("RIGHT", self, "BOTTOMLEFT", -6, y)
            self.labels[i]:SetText(FormatMoney(math.floor(lo + (hi - lo) * f)))
        end
        for i, p in ipairs(series) do
            if i > 1 and self.CreateLine then
                local l = self.lines[i - 1]
                if not l then
                    l = self:CreateLine(nil, "ARTWORK")
                    if l.SetThickness then l:SetThickness(2) end
                    self.lines[i - 1] = l
                end
                l:SetColorTexture(COLORS.bar[1], COLORS.bar[2], COLORS.bar[3], 1)
                l:SetStartPoint("BOTTOMLEFT", self, X(i - 1), Y(series[i - 1][2]))
                l:SetEndPoint("BOTTOMLEFT", self, X(i), Y(p[2]))
                l:Show()
            end
            local d = self.dots[i]
            if not d then d = Style.Texture(self, "OVERLAY", COLORS.bar) d:SetSize(7, 7) self.dots[i] = d end
            d:ClearAllPoints()
            d:SetPoint("CENTER", self, "BOTTOMLEFT", X(i), Y(p[2]))
            d:Show()
        end
        local labels = math.min(n, 5)
        for k = 1, labels do
            local idx = labels == 1 and 1 or math.floor((k - 1) * (n - 1) / (labels - 1) + 1.5)
            local t = self.ticks[k]
            if not t then t = Style.Text(self, "GameFontDisableSmall", "CENTER") t:SetWidth(70) self.ticks[k] = t end
            t:ClearAllPoints()
            t:SetPoint("TOP", self, "BOTTOMLEFT", X(idx), -6)
            t:SetText(series[idx][1]:sub(6))
            t:Show()
        end
    end
    plot:SetScript("OnUpdate", function(self)
        local series = self.series
        if not series or #series == 0 or not self.X or not (self.IsMouseOver and self:IsMouseOver()) then
            if self.hovering then self.hovering = nil self.cross:Hide() ns.Tooltip.Hide() end
            return
        end
        local scale = self.GetEffectiveScale and self:GetEffectiveScale() or 1
        local cx = (GetCursorPosition()) / scale - (self:GetLeft() or 0)
        local best, bestD
        for i = 1, #series do
            local d = math.abs(self.X(i) - cx)
            if not bestD or d < bestD then best, bestD = i, d end
        end
        if best == self.hovering then return end
        self.hovering = best
        self.cross:ClearAllPoints()
        self.cross:SetPoint("TOP", self, "TOPLEFT", self.X(best), 0)
        self.cross:SetPoint("BOTTOM", self, "BOTTOMLEFT", self.X(best), 0)
        self.cross:Show()
        local p, prev = series[best], series[best - 1]
        local lines = { p[1], "Gold: " .. FormatMoney(p[2]) }
        if prev then lines[#lines + 1] = "Change: " .. FormatMoney(p[2] - prev[2], true) end
        if p[3] then
            lines[#lines + 1] = "in " .. FormatMoney(p[3].inc) .. "   out " .. FormatMoney(p[3].exp)
            for k, val in pairs(p[3].by) do lines[#lines + 1] = (KIND_LABEL[k] or k) .. "  " .. FormatMoney(val, true) end
        end
        ns.Tooltip.Text(self, lines)
    end)
    plot:SetScript("OnSizeChanged", function() if v:IsShown() then v:Refresh() end end)

    -- By source and per day.
    v.side = Style.Card(v, "Where it came from")
    v.side:SetPoint("TOPLEFT", v.chartCard, "TOPRIGHT", 10, 0)
    v.side:SetPoint("BOTTOMRIGHT")
    v.sources = Style.List(v.side.content, { colWidths = { 110 } })

    function v:Footer() return "Money for " .. ScopeLabel() .. ". Transfers between your own characters are not income or spending for the account." end

    function v:Refresh()
        local since = RangeStart()
        local rangeLabel = RangeLabel()
        local total, chars = Economy.AllCharacters()
        local money = total
        if state.scope ~= "all" then
            money = nil
            for _, row in ipairs(chars) do if row[1] == state.scope then money = row[2] end end
        end
        local now = time()
        local tInc, tExp = Economy.ScopeTotals(state.scope, Economy.DayStart(now))
        local rInc, rExp, by = Economy.ScopeTotals(state.scope, since)
        local bestK, bestV, worstK, worstV
        for k, val in pairs(by) do
            if k ~= "transfer" then
                if val > 0 and (not bestV or val > bestV) then bestK, bestV = k, val end
                if val < 0 and (not worstV or val < worstV) then worstK, worstV = k, val end
            end
        end
        local sNet, sHour, sMoved
        if state.scope == "all" or state.scope == ns.Gear.CharKey() then
            local _
            sNet, sHour, _, sMoved = Economy.Session()
        end
        local sessionTip = { "This session", "Gold gained or spent since you logged in, without gold moved between your own characters." }
        if sMoved and sMoved ~= 0 then sessionTip[#sessionTip + 1] = "Moved to / from your characters: " .. FormatMoney(sMoved, true) end
        local charTip = { "Gold by character" }
        for _, row in ipairs(chars) do charTip[#charTip + 1] = row[1] .. "  " .. FormatMoney(row[2]) end
        local data = {
            { "Gold now", FormatMoney(money), state.scope == "all" and (#chars .. " characters") or state.scope, charTip },
            { "Today", FormatMoney(tInc - tExp, true), "in " .. FormatMoney(tInc) .. "  out " .. FormatMoney(tExp) },
            { rangeLabel .. " net", FormatMoney(rInc - rExp, true), "in " .. FormatMoney(rInc) .. "  out " .. FormatMoney(rExp) },
            { "This session", sNet and FormatMoney(sNet, true) or "-", sHour and (FormatMoney(sHour, true) .. " per hour") or "per hour after 5 min", sessionTip },
            { "Best income", bestK and KIND_LABEL[bestK] or "-", bestV and FormatMoney(bestV, true) or "" },
            { "Biggest cost", worstK and KIND_LABEL[worstK] or "-", worstV and FormatMoney(worstV, true) or "" },
        }
        for i, tile in ipairs(self.tiles) do
            tile.label:SetText(data[i][1])
            tile.value:SetText(data[i][2])
            tile.sub:SetText(data[i][3])
            tile.tip = data[i][4]
        end

        local days, order = Economy.ScopeDays(state.scope)
        local series = {}
        local from = since and Today(since) or nil
        for _, day in ipairs(order) do
            if (not from or day >= from) and days[day].money then series[#series + 1] = { day, days[day].money, days[day] } end
        end
        if money then
            local today = Today(now)
            if series[#series] and series[#series][1] == today then series[#series][2] = money
            elseif not from or today >= from then series[#series + 1] = { today, money, days[today] } end
        end
        self.chartCard.title:SetText("Gold over time  " .. HEX.muted .. ScopeLabel() .. "  ·  " .. rangeLabel .. "|r")
        self.chartCard.sub:SetText(#series > 1 and ("from " .. FormatMoney(series[1][2]) .. " to " .. FormatMoney(series[#series][2])
            .. "  (" .. FormatMoney(series[#series][2] - series[1][2], true) .. ")") or "one point per day: gold at the end of the day")
        self.plot:Draw(series)

        local rows = { { header = true, text = "By source" } }
        local kinds = {}
        for k, val in pairs(by) do kinds[#kinds + 1] = { k, val } end
        table.sort(kinds, function(a, b) return a[2] > b[2] end)
        local maxAbs = 0
        for _, kv in ipairs(kinds) do maxAbs = math.max(maxAbs, math.abs(kv[2])) end
        for _, kv in ipairs(kinds) do
            rows[#rows + 1] = { text = KIND_LABEL[kv[1]] or kv[1], cols = { FormatMoney(kv[2], true) },
                bar = { math.abs(kv[2]), maxAbs, color = kv[2] >= 0 and { 0.30, 0.70, 0.35 } or { 0.80, 0.30, 0.30 } } }
        end
        if #kinds == 0 then rows[#rows + 1] = { text = HEX.muted .. "Nothing yet in this range.|r" } end
        rows[#rows + 1] = { header = true, text = "Per day" }
        local maxDay = 0
        for _, day in ipairs(order) do
            if not from or day >= from then maxDay = math.max(maxDay, math.abs(days[day].inc - days[day].exp)) end
        end
        for i = #order, 1, -1 do
            local day = order[i]
            if from and day < from then break end
            local d = days[day]
            local net = d.inc - d.exp
            rows[#rows + 1] = { text = day, cols = { FormatMoney(net, true) },
                bar = { math.abs(net), maxDay, color = net >= 0 and { 0.30, 0.70, 0.35 } or { 0.80, 0.30, 0.30 } },
                tooltip = function(owner)
                    local lines = { day, "in " .. FormatMoney(d.inc) .. "   out " .. FormatMoney(d.exp) }
                    for k, val in pairs(d.by) do lines[#lines + 1] = (KIND_LABEL[k] or k) .. "  " .. FormatMoney(val, true) end
                    if d.money then lines[#lines + 1] = "Gold at the end: " .. FormatMoney(d.money) end
                    ns.Tooltip.Text(owner, lines)
                end }
        end
        self.sources:SetItems(rows)
        self.side.sub:SetText(rangeLabel .. "  ·  net " .. FormatMoney(rInc - rExp, true))
    end
    return v
end

---------------------------------------------------------------------------
-- Transactions
---------------------------------------------------------------------------
local function BuildTransactions(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Transactions")
    v.card:SetAllPoints()
    v.card.sub:SetText("Click a kind to hide it, right-click for only that kind.")
    local chipRow = CreateFrame("Frame", nil, v.card.content)
    chipRow:SetPoint("TOPLEFT", 6, -4)
    chipRow:SetPoint("TOPRIGHT", -6, -4)
    chipRow:SetHeight(22)
    v.chips = {}
    local x = 0
    for _, k in ipairs(Economy.KINDS) do
        local chip = Style.Button(chipRow, k.label, 74, function(_, button)
            if button == "RightButton" then
                local solo = true
                for _, other in ipairs(Economy.KINDS) do
                    if (other.key == k.key) == (state.hidden[other.key] == true) then solo = false end
                end
                for _, other in ipairs(Economy.KINDS) do state.hidden[other.key] = (not solo and other.key ~= k.key) or nil end
            else
                state.hidden[k.key] = not state.hidden[k.key] or nil
            end
            UI.Refresh()
        end, "Click: show or hide. Right-click: only this kind (again: all).", { height = 20, title = k.label })
        chip:SetPoint("TOPLEFT", x, 0)
        chip.key = k.key
        x = x + 77
        v.chips[#v.chips + 1] = chip
    end
    local holder = CreateFrame("Frame", nil, v.card.content)
    holder:SetPoint("TOPLEFT", 0, -30)
    holder:SetPoint("BOTTOMRIGHT")
    v.list = Style.List(holder, { labelWidth = 86, colWidths = { 110 }, search = true, hint = "Search items, names, kinds..." })

    function v:Footer() return "Read from the window you had open. Repairs: vendor spending with no item change. Loot in one zone is merged." end

    function v:Refresh()
        for _, chip in ipairs(self.chips) do Paint(chip, not state.hidden[chip.key]) end
        local data = ns.Data.List(self.list, {
            name = "economy:transactions", sources = { "economy" }, key = ViewKey(HiddenKey()),
            row = EntryRow, empty = "No transactions in this range (or all kinds are hidden).",
            build = function(add)
                local net = 0
                for _, item in ipairs(Entries(function(e) return not state.hidden[e.kind] end)) do
                    add(item)
                    if item.e.kind ~= "transfer" or state.scope ~= "all" then net = net + item.e.amount end
                end
                return { net = net }
            end,
        })
        self.card.title:SetText("Transactions  " .. HEX.muted .. #data.rows .. "  ·  " .. ScopeLabel() .. "  ·  " .. RangeLabel() .. "|r  "
            .. FormatMoney(data.net, true))
    end
    return v
end

---------------------------------------------------------------------------
-- Auctions: every listing, newest first, and how it ended
---------------------------------------------------------------------------
local STATUS = {
    listed = { "listed", HEX.compare }, sold = { "sold", HEX.good }, expired = { "expired", HEX.bad },
    cancelled = { "cancelled", HEX.muted }, unknown = { "ended?", HEX.gold },
}

-- A listing's status as shown: "unknown" once its time is up and no letter
-- closed it (Economy.ListingOver): never "listed" when it cannot still be.
local function StatusOf(a)
    if Economy.ListingOver(a) then return "unknown" end
    return a.status
end

local function AuctionRow(item)
    local a = item.a
    local status = StatusOf(a)
    local st = STATUS[status] or { status, "" }
    local result
    -- A sale letter pays your deposit back too: the sale is what it kept after the cut.
    if a.status == "sold" then result = a.received and (FormatMoney(a.received - (a.deposit or 0)) .. HEX.muted .. " after the cut|r")
        or (HEX.muted .. "? (payment unknown)|r")
    elseif a.status == "expired" or a.status == "cancelled" then result = HEX.muted .. "deposit lost|r " .. FormatMoney(-(a.deposit or 0), true)
    elseif status == "unknown" then result = HEX.muted .. "outcome unknown (no letter)|r"
    else result = HEX.muted .. "deposit|r " .. FormatMoney(a.deposit or 0) end
    return {
        label = date("%b %d %H:%M", a.t),
        text = CharShort(item.char) .. tostring(a.name) .. (a.count and a.count > 1 and (HEX.muted .. "  x" .. a.count .. "|r") or "")
            .. HEX.muted .. "  buyout|r " .. (a.buyout and FormatMoney(a.buyout) or "-")
            .. (a.bid and (HEX.muted .. "  bid|r " .. FormatMoney(a.bid)) or ""),
        cols = { st[2] .. st[1] .. "|r", result },
        tooltip = function(owner)
            local lines = { tostring(a.name) .. (a.count and a.count > 1 and (" x" .. a.count) or ""),
                "Posted " .. date("%b %d %H:%M", a.t) .. "  ·  " .. tostring(a.duration or "?") .. "  ·  " .. tostring(item.char),
                "Buyout " .. (a.buyout and FormatMoney(a.buyout) or "-") .. "   bid " .. (a.bid and FormatMoney(a.bid) or "-"),
                "Deposit " .. FormatMoney(a.deposit or 0),
                -- When it sold or ended (from its letter); else when the letter was taken, said so.
                "Status: " .. st[1] .. (a.closedAt and ("  (" .. date("%b %d %H:%M", a.closedAt) .. ")")
                    or (a.ended and ("  (letter taken " .. date("%b %d %H:%M", a.ended) .. ")")) or "") }
            if status == "unknown" then
                lines[#lines + 1] = "Its time ran out and no auction letter closed it: sold, expired or cancelled is unknown."
            end
            if a.received then
                lines[#lines + 1] = "Sold for " .. FormatMoney(a.received - (a.deposit or 0)) .. " after the cut"
                lines[#lines + 1] = "Letter paid " .. FormatMoney(a.received) .. (a.deposit and a.deposit > 0
                    and ("  (with your deposit " .. FormatMoney(a.deposit) .. " back)") or "")
            end
            ns.Tooltip.Text(owner, lines)
        end,
    }
end

local function BuildAuctions(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Auctions")
    v.card:SetAllPoints()
    local chipRow = CreateFrame("Frame", nil, v.card.content)
    chipRow:SetPoint("TOPLEFT", 6, -4)
    chipRow:SetHeight(22)
    chipRow:SetWidth(500)
    v.filters = {}
    local x = 0
    for _, f in ipairs({ { "all", "All" }, { "listed", "Listed" }, { "sold", "Sold" }, { "expired", "Expired" }, { "cancelled", "Cancelled" } }) do
        local b = Style.Button(chipRow, f[2], 84, function() state.auctionFilter = f[1] UI.Refresh() end, nil, { height = 20 })
        b:SetPoint("TOPLEFT", x, 0)
        b.key = f[1]
        x = x + 88
        v.filters[#v.filters + 1] = b
    end
    local holder = CreateFrame("Frame", nil, v.card.content)
    holder:SetPoint("TOPLEFT", 0, -30)
    holder:SetPoint("BOTTOMRIGHT")
    v.list = Style.List(holder, { labelWidth = 86, colWidths = { 90, 120 }, search = true, hint = "Search items, characters..." })

    function v:Footer() return "Listings come from posting at the auction house; the auction letters mark them sold, expired or cancelled." end

    function v:Refresh()
        for _, b in ipairs(self.filters) do Paint(b, b.key == state.auctionFilter) end
        local data = ns.Data.List(self.list, {
            -- maxAge: a listing's time running out changes what it shows, with no new data.
            name = "economy:auctions", sources = { "economy" }, key = ViewKey(state.auctionFilter), maxAge = 300,
            row = AuctionRow, empty = "No auctions here yet: post something at the auction house.",
            build = function(add)
                local since = RangeStart()
                local all = {}
                for key, c in pairs(Economy.Scope(state.scope)) do
                    for _, a in ipairs(c.auctions or {}) do
                        -- In the range by when it ended (the money's day), not when it
                        -- was posted; one still up is always shown, one whose time ran
                        -- out with no letter by when it would have ended.
                        local status = StatusOf(a)
                        local when = a.closedAt or a.ended or a.t
                        if status == "unknown" then
                            local hours = type(a.duration) == "string" and tonumber(a.duration:match("^(%d+)")) or 48
                            when = a.t + hours * 3600
                        end
                        if not since or status == "listed" or when >= since then all[#all + 1] = { a = a, char = key } end
                    end
                end
                table.sort(all, function(x1, x2) return x1.a.t > x2.a.t end)
                local listings = {}
                for _, item in ipairs(all) do
                    listings[#listings + 1] = item.a
                    if state.auctionFilter == "all" or state.auctionFilter == StatusOf(item.a) then
                        add(item)
                    end
                end
                return Economy.AuctionTotals(listings)
            end,
        })
        self.card.title:SetText("Auctions  " .. HEX.muted .. ScopeLabel() .. "  ·  " .. RangeLabel() .. "|r")
        local unpriced = (data.unpriced or 0) > 0 and (" + " .. data.unpriced .. " with no payment known") or ""
        local unknown = (data.unknown or 0) > 0 and ("  ·  " .. data.unknown .. " ended, outcome unknown") or ""
        self.card.sub:SetText(string.format("%d listed  ·  %d sold for %s after the cut%s  ·  %d expired  ·  %d cancelled%s  ·  deposits lost %s  ·  profit %s",
            data.listed, data.sold, FormatMoney(data.income), unpriced, data.expired, data.cancelled, unknown, FormatMoney(data.lost), FormatMoney(data.profit, true)))
    end
    return v
end

---------------------------------------------------------------------------
-- Trades
---------------------------------------------------------------------------
local function TradeRow(item)
    local e = item.e
    local partner = e.detail or "?"
    local gave = ItemsText(e.gave, 3)
    local got = ItemsText(e.got, 3)
    return {
        label = date("%b %d %H:%M", e.t),
        text = CharShort(item.char) .. (e.kind == "transfer" and (HEX.compare .. "transfer|r  ") or "") .. HEX.gold .. tostring(partner) .. "|r"
            .. (got and ("  got " .. got) or "") .. (gave and ("  gave " .. gave) or "")
            .. ((e.gotMoney or 0) > 0 and ("  got " .. FormatMoney(e.gotMoney)) or "")
            .. ((e.gaveMoney or 0) > 0 and ("  gave " .. FormatMoney(e.gaveMoney)) or ""),
        cols = { e.amount ~= 0 and FormatMoney(e.amount, true) or (HEX.dim .. "-|r") },
        tooltip = function(owner) EntryTooltip(owner, item) end,
    }
end

local function BuildTrades(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Trades")
    v.card:SetAllPoints()
    v.list = Style.List(v.card.content, { labelWidth = 86, colWidths = { 110 }, search = true, hint = "Search players, items..." })
    function v:Footer() return "Trades with other players, and mail and trades between your own characters (transfers)." end
    function v:Refresh()
        local data = ns.Data.List(self.list, {
            name = "economy:trades", sources = { "economy" }, key = ViewKey(),
            row = TradeRow, empty = "No trades in this range.",
            build = function(add)
                local partners, n = {}, 0
                for _, item in ipairs(Entries(function(e) return e.kind == "trade" or e.kind == "transfer" end)) do
                    local partner = item.e.detail or "?"
                    if not partners[partner] then partners[partner], n = true, n + 1 end
                    add(item)
                end
                return { partners = n }
            end,
        })
        self.card.title:SetText("Trades  " .. HEX.muted .. #data.rows .. " with " .. data.partners .. " players  ·  " .. ScopeLabel() .. "  ·  " .. RangeLabel() .. "|r")
    end
    return v
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local VIEWS = {
    { key = "overview", label = "Overview", build = BuildOverview },
    { key = "transactions", label = "Transactions", build = BuildTransactions },
    { key = "auctions", label = "Auctions", build = BuildAuctions },
    { key = "trades", label = "Trades", build = BuildTrades },
}

local function Build()
    frame = Style.Window(ns.FRAME .. "EconomyWindow", "Economy", nil, nil, { nav = "economy", hidden = true })

    -- Scope: all characters or one.
    frame.scope = Style.Button(frame, "", 200, function(_, button)
        local keys = { "all" }
        for key in pairs(db().economy) do keys[#keys + 1] = key end
        table.sort(keys, function(a, b) if a == "all" then return true elseif b == "all" then return false end return a < b end)
        local i = 1
        for n, key in ipairs(keys) do if key == state.scope then i = n end end
        i = i + (button == "RightButton" and -1 or 1)
        if i > #keys then i = 1 elseif i < 1 then i = #keys end
        state.scope = keys[i]
        UI.Refresh()
    end, "All characters together, or one. Left-click: next. Right-click: previous.")
    frame.scope:SetPoint("TOPRIGHT", -40, -8)
    Style.AttachDropdown(frame.scope, function()
        local list = { { key = "all", label = "All characters" } }
        local keys = {}
        for key in pairs(db().economy) do keys[#keys + 1] = key end
        table.sort(keys)
        for _, key in ipairs(keys) do list[#list + 1] = { key = key, label = key } end
        return Style.ChoiceItems(list, state.scope, function(key) state.scope = key UI.Refresh() end)
    end)

    -- Range, shared by every tab.
    frame.ranges = {}
    local prev
    for i = #RANGES, 1, -1 do
        local r = RANGES[i]
        local b = Style.Button(frame, r[2], 64, function() state.range = r[1] UI.Refresh() end, nil, { height = 22 })
        if prev then b:SetPoint("RIGHT", prev, "LEFT", -4, 0) else b:SetPoint("RIGHT", frame.scope, "LEFT", -12, 0) end
        b.range = r[1]
        prev = b
        frame.ranges[#frame.ranges + 1] = b
    end

    local tabHolder = CreateFrame("Frame", nil, frame)
    tabHolder:SetPoint("TOPLEFT", PAD, -44)
    tabHolder:SetPoint("TOPRIGHT", -PAD, -44)
    tabHolder:SetHeight(26)
    frame.tabs = Style.Tabs(tabHolder, VIEWS, function(key) state.view = key UI.Refresh() end, 110)
    local line = Style.HLine(frame)
    line:SetPoint("TOPLEFT", PAD, -70)
    line:SetPoint("TOPRIGHT", -PAD, -70)

    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", PAD, -80)
    body:SetPoint("BOTTOMRIGHT", -PAD, 34)
    for _, def in ipairs(VIEWS) do views[def.key] = def.build(body) end
    frame.footer = Style.Text(frame, "GameFontDisableSmall")
    frame.footer:SetPoint("BOTTOMLEFT", PAD + 2, 12)
    frame.footer:SetPoint("RIGHT", -PAD, 0)
    frame:HookScript("OnShow", function() UI.Refresh() end)
end

function UI.Refresh()
    if not frame or not frame:IsShown() then return end
    if state.scope ~= "all" and not db().economy[state.scope] then state.scope = "all" end
    frame.scope:SetLabel(ScopeLabel() .. "  >")
    for _, b in ipairs(frame.ranges) do Paint(b, b.range == state.range) end
    frame.tabs:Select(state.view)
    for key, v in pairs(views) do v:SetShown(key == state.view) end
    local v = views[state.view]
    v:Refresh()
    frame.footer:SetText(v:Footer() or "")
end

function UI.Show(view)
    if not frame then Build() end
    if view and views[view] then state.view = view end
    frame:Show()
    UI.Refresh()
end

function UI.Toggle(view)
    if frame and frame:IsShown() and (not view or view == state.view) then frame:Hide() else UI.Show(view) end
end

function UI.IsShown() return frame ~= nil and frame:IsShown() end
UI.views = views
-- Redrawn when the economy data changes (a loot, a sale), once a second at most.
-- Frames and the Overview's totals and gold history are built after login.
ns.Data.Window(UI, { "economy" }, {
    prebuild = function() if not frame then Build() end end,
    warm = function()
        Economy.ScopeTotals(state.scope, Economy.DayStart())
        Economy.ScopeTotals(state.scope, RangeStart())
        Economy.ScopeDays(state.scope)
    end,
})
