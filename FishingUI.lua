-- TALOD - Fishing window (/talod fish): Now (this session and this spot),
-- Spots (every spot ranked by gold per hour at your skill, catch rate or
-- danger), Map (heat map of casts, catches, value, one fish, attacks or
-- enemies seen), Log (casts and encounters) and Sessions. Plus the HUD that
-- shows while you fish. Numbers come from Fishing.lua.

local ADDON_NAME, ns = ...
local S = ns.Secret
local Style = ns.Style
local COLORS, HEX = Style.COLORS, Style.HEX
local Fishing = ns.Fishing

local UI = {}
ns.FishingUI = UI

local PAD = 12
-- The heat map keeps the 3:2 of the game's map art and grows with the window;
-- the list beside it keeps at least MAP_SIDE px.
local MAP_RATIO, MAP_MIN_W, MAP_SIDE = 1.5, 360, 260
local state = { view = "now", sort = "gph", skill = "mine", selected = nil, map = nil, metric = "casts" }
local frame, hud
local views = {}

local function db() return ns.DB() end

-- Extension points for the other fishing modules (FishingSafety, FishingGoals,
-- FishingGear). Register at load time, before the window or HUD is built.
--   UI.AddView({ key, label, build })        another window tab
--   UI.AddSpotSort({ key, label, cmp })      cmp(a, b) on Fishing.SpotList entries
--   UI.AddHUDLine(fn)   fn(session, rates) -> row { key, label, value, tip, warn, icon } or nil
--   UI.AddItemTag(fn)   fn(itemID) -> text appended to a catch row, or nil
--   UI.AddSpotRows(fn)  fn(rows, mapID, spotName, skill) appends detail rows of a spot
--   UI.AddNowRows(fn)   fn(rows) appends rows to the Now view's session card
--   UI.OnHUDBuilt(fn)   fn(hud) once the HUD frame exists; UI.HUDFrame() returns it
--   UI.OnHUDUpdated(fn) fn(hud) after every HUD redraw (rows may have moved);
--                       UI.HUDRowByKey(key) returns the shown row with that key
local hooks = { hudLines = {}, itemTags = {}, spotRows = {}, nowRows = {}, hudBuilt = {}, hudUpdated = {}, sorts = {}, views = {} }
function UI.AddView(def) hooks.views[#hooks.views + 1] = def end
function UI.AddSpotSort(def) hooks.sorts[#hooks.sorts + 1] = def end
function UI.AddHUDLine(fn) hooks.hudLines[#hooks.hudLines + 1] = fn end
function UI.AddItemTag(fn) hooks.itemTags[#hooks.itemTags + 1] = fn end
function UI.AddSpotRows(fn) hooks.spotRows[#hooks.spotRows + 1] = fn end
function UI.AddNowRows(fn) hooks.nowRows[#hooks.nowRows + 1] = fn end
function UI.OnHUDBuilt(fn)
    hooks.hudBuilt[#hooks.hudBuilt + 1] = fn
    if hud then ns.SafeCall(fn, hud) end
end
function UI.HUDFrame() return hud end
function UI.OnHUDUpdated(fn) hooks.hudUpdated[#hooks.hudUpdated + 1] = fn end

local function RunHooks(list, ...)
    for _, fn in ipairs(list) do ns.SafeCall(fn, ...) end
end

-- A hook's return value; its errors still go to /talod errors (and fail the tests).
local function HookValue(fn, ...)
    local out
    local args, n = { ... }, select("#", ...)
    ns.SafeCall(function() out = fn(unpack(args, 1, n)) end)
    return out
end

local function Money(c)
    if not c then return HEX.dim .. "?|r" end
    return ns.Professions.Money(c)
end

local function Pct(x)
    if not x then return HEX.dim .. "?|r" end
    return math.floor(x * 100 + 0.5) .. "%"
end

local function Date(t) return t and date("%b %d  %H:%M", t) or "?" end

local function ResultText(r)
    return ({ c = HEX.good .. "caught|r", a = HEX.gold .. "got away|r", m = HEX.muted .. "missed (nothing hooked)|r",
        t = HEX.muted .. "no bite clicked|r", i = HEX.bad .. "interrupted|r" })[r] or "?"
end

local KIND_TEXT = {
    N = HEX.bad .. "NPC attack|r", P = HEX.bad .. "Player attack|r", ["?"] = HEX.bad .. "Attack (who: ?)|r",
    E = HEX.gold .. "Enemy player seen|r", e = HEX.muted .. "Player seen (hostility hidden)|r", D = HEX.bad .. "You died|r",
}

local function WhoText(r)
    if not r.who then return "" end
    local level = r.lvl == -1 and "??" or (r.lvl and tostring(r.lvl) or "")
    local class = r.cls and ns.ClassName(r.cls) or ""
    local name = r.cls and (ns.Hex(ns.ClassColor(r.cls)) .. r.who .. "|r") or r.who
    return "  " .. name .. (level ~= "" and ("  " .. level) or "") .. (class ~= "" and (" " .. class) or "")
end

-- Item rows of a tally: icon, name, count, share of catches, value.
local function ItemRows(rows, items, catches)
    local list = {}
    for id, n in pairs(items or {}) do list[#list + 1] = { id = id, n = n } end
    table.sort(list, function(a, b) return a.n > b.n end)
    for _, it in ipairs(list) do
        local v, how, unseen, info = Fishing.ItemValue(it.id)
        local tags = ""
        for _, fn in ipairs(hooks.itemTags) do
            local tag = HookValue(fn, it.id)
            if type(tag) == "string" and tag ~= "" then tags = tags .. "  " .. tag end
        end
        rows[#rows + 1] = {
            icon = Fishing.ItemIcon(it.id),
            text = Fishing.ItemText(it.id) .. HEX.muted .. "  x" .. it.n .. "|r"
                .. (info.hard and (HEX.bad .. "  hard to sell|r") or "") .. (unseen and (HEX.gold .. "  not seen on the AH|r") or "") .. tags,
            cols = { (catches and catches > 0) and (HEX.muted .. Pct(it.n / catches) .. "|r") or "",
                v > 0 and (Money(v * it.n) .. (unseen and (HEX.gold .. "*|r") or "")) or (HEX.dim .. "no price|r") },
            tooltip = function(owner)
                local lines = { Fishing.ItemName(it.id), string.format("%d caught%s", it.n,
                    (catches and catches > 0) and string.format(", %s of catches", Pct(it.n / catches)) or "") }
                if v > 0 then
                    lines[#lines + 1] = "Counted at " .. Money(v) .. " each: " .. (how == "ah" and "Auction House after the cut"
                        .. ((info.rate and info.rate < 1) and " x your sell rate" or "") or "vendor")
                end
                if info.p then lines[#lines + 1] = "AH: " .. Money(info.p) .. " (" .. (info.src == "auctionator" and "Auctionator, " or "") .. ns.Prices.Age(info.t, info.src) .. ")" end
                local rate = ns.Market.SellRateText(info.sales)
                if rate then lines[#lines + 1] = (info.hard and HEX.bad or "") .. "Your auctions: " .. rate .. (info.hard and "|r" or "") end
                if unseen then lines[#lines + 1] = HEX.gold .. "Never seen on the Auction House: counted at the vendor price, likely too low. Look it up there.|r" end
                if info.bound then lines[#lines + 1] = "Soulbound: vendor only." end
                if v <= 0 then lines[#lines + 1] = "No price: look it up at the Auction House." end
                ns.Tooltip.Text(owner, lines)
            end,
        }
    end
    if #list == 0 then rows[#rows + 1] = { text = HEX.muted .. "Nothing caught yet.|r" } end
end

-- Rows comparing lures: catch rate, gold per hour, the average skill
-- modifier the casts had (the lure's bonus sits in it, with gear).
local function LureRows(rows, lures, title)
    local list = {}
    for key, t in pairs(lures or {}) do
        if (t.n or 0) > 0 then list[#list + 1] = { key = key, t = t, r = Fishing.Rates(t) } end
    end
    if #list == 0 then return end
    table.sort(list, function(a, b) return (a.t.n or 0) > (b.t.n or 0) end)
    rows[#rows + 1] = { header = true, text = title }
    for _, e in ipairs(list) do
        local avg = (e.t.mn or 0) > 0 and e.t.ms / e.t.mn or nil
        rows[#rows + 1] = { label = Fishing.LureLabel(e.key),
            text = Pct(e.r.catchPct) .. " caught" .. HEX.muted .. string.format("  ·  %d casts  ·  %s/h%s|r", e.r.casts,
                e.r.gph and Money(e.r.gph) or "?", avg and string.format("  ·  skill +%d", math.floor(avg + 0.5)) or ""),
            tooltip = function(o) ns.Tooltip.Text(o, { Fishing.LureLabel(e.key), string.format("%d casts, %d caught, %d got away, %d missed",
                e.r.casts, e.r.catches, e.r.escaped, e.r.missed), "Skill +N: the average skill modifier of these casts (lure and gear)." }) end }
    end
end
UI.LureRows = LureRows

-- Detail rows of one spot for a skill (or nil: all skills).
local function SpotRows(mapID, name, skill)
    local rows = {}
    local spot = Fishing.GetSpot(mapID, name)
    if not spot then
        rows[1] = { text = HEX.muted .. "You have not fished here yet. Cast and this fills in.|r" }
        return rows
    end
    local tally, basis, label = Fishing.SpotTally(spot, skill)
    local r = Fishing.Rates(tally)
    rows[#rows + 1] = { header = true, text = "At " .. label }
    rows[#rows + 1] = { label = "Catch rate", text = Pct(r.catchPct) .. HEX.muted .. string.format("  of %d casts (got away: %d, missed: %d)|r", r.casts, r.escaped, r.missed),
        tooltip = function(o) ns.Tooltip.Text(o, { "Catch rate", "Catches of catches plus fish that got away (\"Your fish got away!\": your skill lost the bite).",
            "Left out: missed clicks with nothing hooked, early stops, timeouts and interrupted casts: they say nothing about the spot.",
            "Casts logged before misses were told apart count early stops as \"got away\"." }) end }
    rows[#rows + 1] = { label = "Per catch", text = Money(r.perCatch) .. (r.unpriced > 0 and (HEX.muted .. "  (" .. r.unpriced .. " kinds without a price)|r") or "")
        .. (r.unseen > 0 and (HEX.gold .. "  · " .. r.unseen .. " not seen on the AH: vendor price, likely low|r") or "") }
    rows[#rows + 1] = { label = "Per hour", text = (r.gph and (HEX.white .. Money(r.gph) .. "|r") or (HEX.dim .. "?|r"))
        .. HEX.muted .. "  ·  " .. (r.perHour and (math.floor(r.perHour + 0.5) .. " catches") or "?") .. "  ·  " .. Fishing.Minutes(r.hours * 60) .. " fished|r",
        tooltip = function(o) ns.Tooltip.Text(o, { "Per hour of fishing", "Channels plus the gaps between casts up to 30 s: breaks do not count.",
            "Shown after " .. Fishing.MIN_MINUTES .. " minutes fished." }) end }
    if r.perHour then
        local ups = Fishing.SkillUpsPerHour(r)
        rows[#rows + 1] = { label = "Skill-ups", text = (ups and string.format("~%.1f per hour", ups) or (HEX.dim .. "?|r")) .. HEX.muted .. "  ·  "
            .. math.floor(r.perHour + 0.5) .. " catches per hour fished|r",
            tooltip = function(o) ns.Tooltip.Text(o, { "Skill-ups per hour", "The skill-up chance per catch depends on your skill, not the spot: "
                .. "the spot with the most catches per hour fished (escapes cost time) levels you fastest.",
                "From the catches each of your last skill points took (your log)." }) end }
    end
    if basis == "higher" then rows[#rows + 1] = { label = "", text = HEX.gold .. "Only data from a higher skill: expect more fish to get away.|r" } end

    rows[#rows + 1] = { header = true, text = "By skill" }
    local bands = {}
    for b, t in pairs(spot.b) do bands[#bands + 1] = { b = b, t = t } end
    table.sort(bands, function(a, b)
        if type(a.b) ~= type(b.b) then return type(a.b) == "number" end
        return a.b < b.b
    end)
    for _, e in ipairs(bands) do
        local br = Fishing.Rates(e.t)
        local mine = skill and type(e.b) == "number" and Fishing.Band(skill) == e.b
        rows[#rows + 1] = { label = type(e.b) == "number" and string.format("%d-%d", e.b, e.b + Fishing.BAND - 1) or "?",
            text = (mine and HEX.accent or "") .. Pct(br.catchPct) .. " caught" .. (mine and "  (you)|r" or "")
                .. HEX.muted .. string.format("  ·  %d casts  ·  %s/h|r", br.casts, br.gph and Money(br.gph) or "?") }
    end

    LureRows(rows, spot.l, "By lure  " .. HEX.muted .. "(all skills)|r")

    rows[#rows + 1] = { header = true, text = "Danger while fishing  " .. HEX.muted .. "(all skills)|r" }
    local lines = Fishing.DangerLines(spot)
    for _, line in ipairs(lines) do rows[#rows + 1] = { label = "", text = line } end
    local quiet = Fishing.QuietestHours(spot)
    if quiet then rows[#rows + 1] = { label = "", text = "Quietest time: " .. quiet .. HEX.muted .. "  (fewest attacks per minute fished)|r" } end
    if spot.pn > 0 then
        local near = Fishing.CensusNear(mapID, spot.px / spot.pn, spot.py / spot.pn)
        if near then
            rows[#rows + 1] = { label = "", text = string.format("Census: %d enemy player visits around here %s(any time, not only fishing)|r", near, HEX.muted) }
        end
    end

    RunHooks(hooks.spotRows, rows, mapID, name, skill)
    rows[#rows + 1] = { header = true, text = "Catches  " .. HEX.muted .. "(" .. label .. ")|r" }
    ItemRows(rows, tally.it, tally.c)
    rows[#rows + 1] = { header = true, text = "Fished" }
    rows[#rows + 1] = { label = "", text = string.format("%s to %s", Date(spot.first), Date(spot.last)) }
    return rows
end

---------------------------------------------------------------------------
-- Now: this session and this spot
---------------------------------------------------------------------------
local function SkillText()
    local rank, mod, max = Fishing.Skill()
    if not rank then return HEX.muted .. "? (open your Skills tab once)|r" end
    return string.format("%d%s / %d", rank, (mod or 0) ~= 0 and (HEX.good .. " +" .. mod .. "|r") or "", max or 0)
end

local function LureText()
    local pole = Fishing.PoleEquipped()
    if pole == false then return HEX.gold .. "no fishing pole equipped|r" end
    local on, left = Fishing.Lure()
    if on == true then
        return HEX.good .. "on|r" .. (left and string.format("  %d:%02d left", math.floor(left / 60), math.floor(left % 60)) or "")
    elseif on == false then
        return HEX.muted .. "none|r"
    end
    return HEX.dim .. "?|r"
end

local function NextText()
    local need, capped, per = Fishing.NextPoint()
    if capped then return HEX.gold .. "at the maximum: train the next rank|r" end
    if not need then return HEX.muted .. "? (after a few skill-ups)|r" end
    local s = Fishing.Session()
    local r = s and Fishing.Rates(s)
    local eta = r and r.perHour and r.perHour > 0 and (need / r.perHour * 60) or nil
    return string.format("~%d catches%s%s", need, eta and (" (" .. Fishing.Minutes(eta) .. ")") or "",
        HEX.muted .. string.format("  ·  ~%.1f per point lately|r", per or 0))
end

local function BuildNow(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.left = Style.Card(v, "This session")
    v.left:SetPoint("TOPLEFT")
    v.left:SetPoint("BOTTOMLEFT")
    v.left:SetWidth(440)
    v.list = Style.List(v.left.content, { labelWidth = 74, colWidths = { 44, 70 } })
    v.right = Style.Card(v, "Here")
    v.right:SetPoint("TOPLEFT", v.left, "TOPRIGHT", 10, 0)
    v.right:SetPoint("BOTTOMRIGHT")
    v.detail = Style.List(v.right.content, { labelWidth = 74, colWidths = { 44, 70 } })

    function v:Footer()
        return "Value: the Auction House after the cut (your looks) or a vendor, whichever is more. Catch rate counts catches "
            .. "and fish that got away; missed clicks, timeouts and interrupted casts are left out."
    end

    function v:Refresh()
        local rows = {}
        local s = Fishing.Session()
        if s then
            local r = Fishing.Rates(s)
            self.left.sub:SetText(string.format("%s  ·  started %s", s.zone or "?", date("%H:%M", s.start)))
            rows[#rows + 1] = { label = "Fished", text = Fishing.Minutes(r.hours * 60) .. HEX.muted .. "  (channels and short gaps)|r" }
            rows[#rows + 1] = { label = "Casts", text = string.format("%d  ·  %s%d caught|r  ·  %d got away  ·  %d missed  ·  %d no bite  ·  %d interrupted",
                s.n or 0, HEX.good, s.c or 0, s.a or 0, s.m or 0, s.t or 0, s.i or 0) }
            rows[#rows + 1] = { label = "Catch rate", text = Pct(r.catchPct) .. HEX.muted .. "  ·  " .. (r.perHour and (math.floor(r.perHour + 0.5) .. " catches/h") or "?/h") .. "|r" }
            rows[#rows + 1] = { label = "Value", text = HEX.white .. Money(r.value) .. "|r" .. HEX.muted .. "  ·  " .. (r.gph and (Money(r.gph) .. "/h") or "?/h")
                .. (r.unpriced > 0 and ("  ·  " .. r.unpriced .. " kinds without a price") or "") .. "|r"
                .. (r.unseen > 0 and (HEX.gold .. "  ·  " .. r.unseen .. " not seen on the AH|r") or "") }
            local gained = (s.skill1 and s.skill0) and s.skill1 - s.skill0 or 0
            rows[#rows + 1] = { label = "Skill", text = SkillText() .. (gained > 0 and (HEX.good .. "  +" .. gained .. " this session|r") or "") }
        else
            self.left.sub:SetText("No session running: cast to start one")
            rows[#rows + 1] = { label = "Skill", text = SkillText() }
        end
        rows[#rows + 1] = { label = "Next point", text = NextText(),
            tooltip = function(o) ns.Tooltip.Text(o, { "Next skill point", "From the catches each of your last skill points took (your log)." }) end }
        rows[#rows + 1] = { label = "Lure", text = LureText() }
        local free = Fishing.FreeSlots()
        rows[#rows + 1] = { label = "Bags", text = free and ((free <= (db().fishBagWarn or 2) and HEX.bad or "") .. free .. " free" .. (free <= (db().fishBagWarn or 2) and "|r" or "")) or "?" }
        local live = ns.Spotter.Count()
        rows[#rows + 1] = { label = "Enemies", text = live > 0 and (HEX.bad .. live .. " in view|r") or (HEX.muted .. "none in view|r") }
        RunHooks(hooks.nowRows, rows)
        if s then
            rows[#rows + 1] = { header = true, text = "Caught this session" }
            ItemRows(rows, s.it, s.c)
            rows[#rows + 1] = { header = true, text = "Encounters this session" }
            for _, line in ipairs((Fishing.DangerLines(s))) do rows[#rows + 1] = { label = "", text = line } end
        else
            local f = Fishing.Store()
            local last = f.sessions[#f.sessions]
            if last then
                rows[#rows + 1] = { header = true, text = "Last session" }
                rows[#rows + 1] = { label = date("%b %d", last.start), text = Fishing.SessionSummary(last) }
            end
        end
        self.list:SetItems(rows)

        local p = Fishing.Place()
        self.right.title:SetText("Here  " .. HEX.accent .. (p.sub or "?") .. "|r" .. ((p.zone and p.zone ~= p.sub) and (HEX.muted .. "  " .. p.zone .. "|r") or ""))
        self.right.sub:SetText(p.x and string.format("%.1f, %.1f  ·  your skill %s", p.x * 100, p.y * 100, Fishing.Effective() or "?") or "position unknown")
        self.detail:SetItems(p.mapID and SpotRows(p.mapID, p.sub, Fishing.Effective()) or { { text = HEX.muted .. "The game gives no map position here.|r" } })
    end
    return v
end

---------------------------------------------------------------------------
-- Spots
---------------------------------------------------------------------------
local SORTS = {
    { key = "gph", label = "Gold per hour" }, { key = "catch", label = "Catch rate" }, { key = "safe", label = "Fewest attacks" },
    { key = "time", label = "Most fished" }, { key = "recent", label = "Recent" },
    { key = "skillups", label = "Skill-ups per hour" },
}

local function Cycle(list, key, button)
    local i = 1
    for n, s in ipairs(list) do if s.key == key then i = n end end
    i = i + (button == "RightButton" and -1 or 1)
    if i > #list then i = 1 elseif i < 1 then i = #list end
    return list[i].key, list[i]
end

local function DangerShort(z)
    if z.minutes < Fishing.MIN_MINUTES then return HEX.dim .. "?|r" end
    if z.attacks == 0 then return HEX.muted .. "0 in " .. Fishing.Minutes(z.minutes) .. "|r" end
    return HEX.bad .. "1/" .. Fishing.Minutes(z.attackEvery) .. "|r"
end

local function SpotRow(e)
    local sel = state.selected and state.selected[1] == e.mapID and state.selected[2] == e.name
    return {
        text = (sel and HEX.accent or "") .. e.name .. (sel and "|r" or "") .. HEX.muted .. "  " .. (e.map ~= e.name and e.map or "")
            .. (e.basis == "higher" and "  (higher skill)" or "") .. "|r",
        cols = { state.sort == "skillups" and (e.rates.perHour and (math.floor(e.rates.perHour + 0.5) .. "/h") or (HEX.dim .. "?|r"))
            or (e.rates.gph and Money(e.rates.gph) or (HEX.dim .. "?|r")), Pct(e.rates.catchPct), DangerShort(e.danger) },
        sort = { [2] = e.rates.catchPct,
            [3] = e.danger.minutes >= Fishing.MIN_MINUTES and e.danger.attacks / e.danger.minutes or nil },
        accent = sel and COLORS.accent or nil,
        tint = sel and { COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.12 } or nil,
        tooltip = function(owner)
            local lines = { e.name .. "  ·  " .. e.map, e.label, string.format("%d casts, %s fished", e.rates.casts, Fishing.Minutes(e.rates.hours * 60)) }
            if e.rates.perHour then
                local ups = Fishing.SkillUpsPerHour(e.rates)
                lines[#lines + 1] = string.format("%d catches per hour fished%s", math.floor(e.rates.perHour + 0.5),
                    ups and string.format(" (~%.1f skill-ups)", ups) or "")
            end
            for _, line in ipairs((Fishing.DangerLines(e.spot))) do lines[#lines + 1] = line end
            ns.Tooltip.Text(owner, lines)
        end,
    }
end

local function BuildSpots(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.left = Style.Card(v, "Spots")
    v.left:SetPoint("TOPLEFT")
    v.left:SetPoint("BOTTOMLEFT")
    v.left:SetWidth(470)
    local top = CreateFrame("Frame", nil, v.left.content)
    top:SetPoint("TOPLEFT", 6, -4)
    top:SetPoint("TOPRIGHT", -6, -4)
    top:SetHeight(24)
    v.sort = Style.Button(top, "", 150, function(_, button)
        state.sort = Cycle(SORTS, state.sort, button)
        UI.Refresh()
    end, "Left-click: next order. Right-click: previous.", { title = "Sort" })
    v.sort:SetPoint("TOPLEFT")
    Style.AttachDropdown(v.sort, function()
        return Style.ChoiceItems(SORTS, state.sort, function(key) state.sort = key UI.Refresh() end)
    end)
    v.skill = Style.Button(top, "", 150, function()
        state.skill = state.skill == "mine" and "all" or "mine"
        UI.Refresh()
    end, "Numbers at your skill (your band, else lower skill: you would do at least as well), or every cast.", { title = "Skill" })
    v.skill:SetPoint("LEFT", v.sort, "RIGHT", 6, 0)
    Style.AttachDropdown(v.skill, function()
        return Style.ChoiceItems({ { key = "mine", label = "At my skill (" .. (Fishing.Effective() or "?") .. ")" }, { key = "all", label = "All skills" } },
            state.skill, function(key) state.skill = key UI.Refresh() end)
    end)
    local holder = CreateFrame("Frame", nil, v.left.content)
    holder:SetPoint("TOPLEFT", 0, -32)
    holder:SetPoint("BOTTOMRIGHT")
    v.list = Style.List(holder, { colWidths = { 64, 40, 70 }, search = true, time = true, hint = "Search spots and zones...",
        columns = { name = "Spot", "Gold/h", "Caught", "Attacks" }, onClick = function(item)
        if item.mapID then state.selected = { item.mapID, item.name } UI.Refresh() end
    end })
    v.right = Style.Card(v, "")
    v.right:SetPoint("TOPLEFT", v.left, "TOPRIGHT", 10, 0)
    v.right:SetPoint("BOTTOMRIGHT")
    v.detail = Style.List(v.right.content, { labelWidth = 74, colWidths = { 44, 70 } })

    function v:Footer()
        return "Gold/h: per hour fished (catches per hour when sorted by skill-ups). Attacks: one per ... fished. "
            .. "\"?\" = too little fishing there to tell."
    end

    function v:Refresh()
        local skill = state.skill == "mine" and Fishing.Effective() or nil
        -- Every spot's rates: kept until a cast, the skill or the sort changes
        -- (a minute at most: prices move the gold per hour).
        local list = ns.Data.Memo("fishing:spots", ns.Data.Key({ "fishing", "prices" }) .. "|" .. tostring(skill) .. "|" .. state.sort, function()
            local out = Fishing.SpotList(skill)
            local cmp = {
                gph = function(a, b) return (a.rates.gph or -1) > (b.rates.gph or -1) end,
                catch = function(a, b) return (a.rates.catchPct or -1) > (b.rates.catchPct or -1) end,
                safe = function(a, b)
                    local ea = a.danger.minutes >= Fishing.MIN_MINUTES and a.danger.attacks / a.danger.minutes or math.huge
                    local eb = b.danger.minutes >= Fishing.MIN_MINUTES and b.danger.attacks / b.danger.minutes or math.huge
                    if ea ~= eb then return ea < eb end
                    return a.danger.minutes > b.danger.minutes
                end,
                time = function(a, b) return (a.spot.s or 0) > (b.spot.s or 0) end,
                -- The skill-up chance per catch does not depend on the spot: most catches per hour fished wins.
                skillups = function(a, b)
                    local pa, pb = a.rates.perHour or -1, b.rates.perHour or -1
                    if pa ~= pb then return pa > pb end
                    return (a.rates.catchPct or -1) > (b.rates.catchPct or -1)
                end,
                recent = function(a, b) return (a.spot.last or 0) > (b.spot.last or 0) end,
            }
            for _, def in ipairs(hooks.sorts) do cmp[def.key] = cmp[def.key] or def.cmp end
            table.sort(out, cmp[state.sort] or cmp.gph)
            return out
        end, 60)
        for _, s in ipairs(SORTS) do if s.key == state.sort then self.sort:SetLabel(s.label .. "  >") end end
        self.skill:SetLabel(state.skill == "mine" and ("At my skill (" .. (Fishing.Effective() or "?") .. ")  >") or "All skills  >")
        if not state.selected and list[1] then state.selected = { list[1].mapID, list[1].name } end
        local sel = state.selected and (state.selected[1] .. "|" .. state.selected[2]) or ""
        ns.Data.List(self.list, {
            name = "fishing:spotrows", key = { tostring(list), sel }, maxAge = 60, row = SpotRow,
            empty = "No spots yet: go fishing and every place you fish appears here.",
            build = function(add)
                for _, e in ipairs(list) do add(e, { mapID = e.mapID, name = e.name, time = e.spot.last }) end
            end,
        })
        self.list:SetColumns({ name = "Spot", state.sort == "skillups" and "Catches/h" or "Gold/h", "Caught", "Attacks" })
        self.left.sub:SetText(string.format("%d spots  ·  by subzone", #list))
        if state.selected and Fishing.GetSpot(state.selected[1], state.selected[2]) then
            local mapName = Fishing.Store().maps[state.selected[1]] or "?"
            self.right.title:SetText(state.selected[2] .. HEX.muted .. "  " .. mapName .. "|r")
            local spot = Fishing.GetSpot(state.selected[1], state.selected[2])
            self.right.sub:SetText(string.format("%s fished  ·  %s", Fishing.Minutes((spot.s or 0) / 60),
                spot.pn > 0 and string.format("around %.0f, %.0f", spot.px / spot.pn * 100, spot.py / spot.pn * 100) or "position unknown"))
            self.detail:SetItems(SpotRows(state.selected[1], state.selected[2], skill))
        else
            self.right.title:SetText("")
            self.right.sub:SetText("")
            self.detail:SetItems({})
        end
    end
    return v
end

---------------------------------------------------------------------------
-- Map: heat map of one map
---------------------------------------------------------------------------
local BASE_METRICS = {
    { key = "casts", label = "Casts" }, { key = "catches", label = "Catches" }, { key = "value", label = "Value caught" },
    { key = "attacks", label = "Attacks" }, { key = "enemies", label = "Enemies seen" },
}

local function Metrics(mapID)
    local out = {}
    for _, m in ipairs(BASE_METRICS) do out[#out + 1] = m end
    local items = {}
    for _, t in pairs(Fishing.Store().cells[mapID] or {}) do
        for id, n in pairs(t.it or {}) do items[id] = (items[id] or 0) + n end
    end
    local list = {}
    for id, n in pairs(items) do list[#list + 1] = { id = id, n = n } end
    table.sort(list, function(a, b) return a.n > b.n end)
    for _, it in ipairs(list) do out[#out + 1] = { key = "item:" .. it.id, label = Fishing.ItemName(it.id), id = it.id } end
    return out
end

local function CellValue(t, metric)
    if metric == "casts" then return t.n or 0 end
    if metric == "catches" then return t.c or 0 end
    if metric == "value" then return (Fishing.ItemsValue(t.it)) end
    if metric == "attacks" then return (t.x or 0) + (t.p or 0) + (t.u or 0) end
    if metric == "enemies" then return t.e or 0 end
    local id = tonumber(metric:match("^item:(%d+)"))
    return id and t.it and t.it[id] or 0
end

-- Cold to hot: blue, yellow, red.
local function Heat(f)
    if f < 0.5 then
        local k = f * 2
        return 0.2 + 0.8 * k, 0.55 + 0.3 * k, 1 - 0.8 * k
    end
    local k = (f - 0.5) * 2
    return 1, 0.85 - 0.6 * k, 0.2 - 0.05 * k
end

-- The map's own art behind the squares, as the world map draws it (tiles of
-- its first art layer). Not every client gives addons the tiles.
local function DrawArt(v, mapID)
    for _, t in ipairs(v.tiles) do t:Hide() end
    if not (C_Map and C_Map.GetMapArtLayers and C_Map.GetMapArtLayerTextures) then return false end
    local ok, layers = pcall(C_Map.GetMapArtLayers, mapID)
    local L = ok and type(layers) == "table" and layers[1] or nil
    if type(L) ~= "table" then return false end
    local lw, lh, tw, th = S.Value(L.layerWidth), S.Value(L.layerHeight), S.Value(L.tileWidth), S.Value(L.tileHeight)
    if not (type(lw) == "number" and type(lh) == "number" and type(tw) == "number" and type(th) == "number" and lw > 0 and lh > 0 and tw > 0 and th > 0) then return false end
    local ok2, textures = pcall(C_Map.GetMapArtLayerTextures, mapID, 1)
    if not ok2 or type(textures) ~= "table" or #textures == 0 then return false end
    local cols, rows = math.ceil(lw / tw), math.ceil(lh / th)
    local sx, sy = v.mapW / lw, v.mapH / lh
    local i = 0
    for r = 1, rows do
        for c = 1, cols do
            local tex = textures[(r - 1) * cols + c]
            if tex then
                i = i + 1
                local t = v.tiles[i]
                if not t then
                    t = v.canvas:CreateTexture(nil, "BACKGROUND", nil, 1)
                    v.tiles[i] = t
                end
                t:SetTexture(tex)
                t:SetSize(tw * sx, th * sy)
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", (c - 1) * tw * sx, -(r - 1) * th * sy)
                t:SetAlpha(0.65)
                t:Show()
            end
        end
    end
    return i > 0
end

local function BuildMap(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.tiles, v.cells, v.labels = {}, {}, {}
    local top = CreateFrame("Frame", nil, v)
    top:SetPoint("TOPLEFT")
    top:SetPoint("TOPRIGHT")
    top:SetHeight(24)
    v.mapButton = Style.Button(top, "", 290, function(_, button)
        local maps = Fishing.Maps()
        if #maps == 0 then return end
        local list = {}
        for _, m in ipairs(maps) do list[#list + 1] = { key = m.mapID } end
        state.map = Cycle(list, state.map, button)
        state.metric = "casts"
        UI.Refresh()
    end, "Left-click: next map. Right-click: previous.", { title = "Map" })
    v.mapButton:SetPoint("TOPLEFT")
    Style.AttachDropdown(v.mapButton, function()
        local list = {}
        for _, m in ipairs(Fishing.Maps()) do list[#list + 1] = { key = m.mapID, label = m.name } end
        return Style.ChoiceItems(list, state.map, function(key) state.map, state.metric = key, "casts" UI.Refresh() end)
    end)
    v.metricButton = Style.Button(top, "", 300, function(_, button)
        if not state.map then return end
        state.metric = Cycle(Metrics(state.map), state.metric, button)
        UI.Refresh()
    end, "What the squares show. After the five totals come the fish you caught on this map, most first: "
        .. "where each one bites.", { title = "Show" })
    v.metricButton:SetPoint("LEFT", v.mapButton, "RIGHT", 10, 0)
    Style.AttachDropdown(v.metricButton, function()
        if not state.map then return {} end
        return Style.ChoiceItems(Metrics(state.map), state.metric, function(key) state.metric = key UI.Refresh() end)
    end)

    v.canvas = CreateFrame("Frame", nil, v)
    v.canvas:SetPoint("TOPLEFT", 0, -32)
    v.mapW, v.mapH = 600, 400
    -- Size from the space the view has: as wide as leaves the list its room,
    -- no taller than the view.
    local function FitCanvas()
        local w = (v:GetWidth() or 0) - 10 - MAP_SIDE
        local h = (v:GetHeight() or 0) - 32
        if w <= 0 or h <= 0 then return false end
        w = math.max(MAP_MIN_W, math.min(w, h * MAP_RATIO))
        w, h = math.floor(w), math.floor(w / MAP_RATIO)
        if w == v.mapW and h == v.mapH then return false end
        v.mapW, v.mapH = w, h
        v.canvas:SetSize(w, h)
        return true
    end
    v.canvas:SetSize(v.mapW, v.mapH)
    v:SetScript("OnSizeChanged", function(self) if FitCanvas() and self:IsShown() then self:Refresh() end end)
    Style.Surface(v.canvas)
    if v.canvas.SetClipsChildren then v.canvas:SetClipsChildren(true) end
    v.empty = Style.Text(v.canvas, "GameFontDisable", "CENTER")
    v.empty:SetPoint("CENTER")

    v.right = Style.Card(v, "")
    v.right:SetPoint("TOPLEFT", v.canvas, "TOPRIGHT", 10, 32)
    v.right:SetPoint("BOTTOMRIGHT")
    v.list = Style.List(v.right.content, { colWidths = { 54 } })

    function v:Footer()
        return "Each square is 2% of the map where you stood (as the Census). Brighter = more (square-root scale). "
            .. "Hover a square for its numbers."
    end

    local function CellButton(i)
        local b = v.cells[i]
        if b then return b end
        b = CreateFrame("Button", nil, v.canvas)
        b.tex = Style.Texture(b, "ARTWORK")
        b.tex:SetPoint("TOPLEFT", 1, -1)
        b.tex:SetPoint("BOTTOMRIGHT", -1, 1)
        b:SetScript("OnEnter", function(self) if self.tip then self.tip(self) end end)
        b:SetScript("OnLeave", function() ns.Tooltip.Hide() end)
        v.cells[i] = b
        return b
    end

    local function Label(i)
        local fs = v.labels[i]
        if not fs then
            fs = Style.Text(v.canvas, "GameFontHighlightSmall", "CENTER")
            v.labels[i] = fs
        end
        return fs
    end

    function v:Refresh()
        FitCanvas()
        local maps = Fishing.Maps()
        local valid = false
        for _, m in ipairs(maps) do if m.mapID == state.map then valid = true end end
        if not valid then
            local here = Fishing.Place().mapID
            state.map = nil
            for _, m in ipairs(maps) do if m.mapID == here then state.map = here end end
            state.map = state.map or (maps[1] and maps[1].mapID)
            state.metric = "casts"
        end
        for _, b in ipairs(self.cells) do b:Hide() end
        for _, fs in ipairs(self.labels) do fs:Hide() end
        if not state.map then
            for _, t in ipairs(self.tiles) do t:Hide() end
            self.mapButton:SetLabel("No maps yet")
            self.metricButton:SetLabel("")
            self.empty:SetText("Nothing fished yet: every cast lands on this map.")
            self.empty:Show()
            self.right.title:SetText("")
            self.right.sub:SetText("")
            self.list:SetItems({})
            return
        end
        self.empty:Hide()
        local f = Fishing.Store()
        local mapName = f.maps[state.map] or tostring(state.map)
        self.mapButton:SetLabel(mapName .. "  >")
        local metric
        for _, m in ipairs(Metrics(state.map)) do if m.key == state.metric then metric = m end end
        if not metric then state.metric, metric = "casts", BASE_METRICS[1] end
        self.metricButton:SetLabel("Show: " .. metric.label .. "  >")
        local art = DrawArt(self, state.map)

        local cells = f.cells[state.map] or {}
        local max, list = 0, {}
        for key, t in pairs(cells) do
            local value = CellValue(t, state.metric)
            if value > 0 then
                local cx, cy = key:match("^(%d+):(%d+)$")
                list[#list + 1] = { key = key, t = t, value = value, cx = tonumber(cx), cy = tonumber(cy) }
                if value > max then max = value end
            end
        end
        table.sort(list, function(a, b) return a.value > b.value end)
        local cw, ch = self.mapW / Fishing.GRID, self.mapH / Fishing.GRID
        local isMoney = state.metric == "value"
        for i, e in ipairs(list) do
            local b = CellButton(i)
            b:SetSize(cw, ch)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", e.cx * cw, -e.cy * ch)
            local frac = math.sqrt(e.value / max)
            local r, g, bl = Heat(frac)
            b.tex:SetColorTexture(r, g, bl, art and (0.55 + 0.4 * frac) or 0.85)
            b.tip = function(owner)
                local t = e.t
                local rates = Fishing.Rates(t)
                local lines = { string.format("%s  %.0f, %.0f", mapName, (e.cx + 0.5) * 2, (e.cy + 0.5) * 2),
                    string.format("%d casts, %d caught (%s), %s fished", t.n or 0, t.c or 0, Pct(rates.catchPct), Fishing.Minutes((t.s or 0) / 60)),
                    "Value " .. Money(rates.value) .. (rates.gph and (", " .. Money(rates.gph) .. "/h") or "") }
                local attacks = (t.x or 0) + (t.p or 0) + (t.u or 0)
                if attacks > 0 or (t.e or 0) > 0 then
                    lines[#lines + 1] = string.format("Attacks: %d NPC, %d player, %d ?  ·  enemies seen: %d", t.x or 0, t.p or 0, t.u or 0, t.e or 0)
                end
                local items = {}
                for id, n in pairs(t.it or {}) do items[#items + 1] = { id = id, n = n } end
                table.sort(items, function(a, b) return a.n > b.n end)
                for k, it in ipairs(items) do
                    if k > 8 then break end
                    lines[#lines + 1] = string.format("  %dx %s", it.n, Fishing.ItemName(it.id))
                end
                ns.Tooltip.Text(owner, lines)
            end
            b:Show()
        end
        -- Without the map's art: spot names where you fished.
        if not art then
            local n = 0
            for name, spot in pairs(f.spots[state.map] or {}) do
                if spot.pn > 0 then
                    n = n + 1
                    local fs = Label(n)
                    fs:ClearAllPoints()
                    fs:SetPoint("CENTER", v.canvas, "TOPLEFT", spot.px / spot.pn * self.mapW, -spot.py / spot.pn * self.mapH - 10)
                    fs:SetText(HEX.muted .. name .. "|r")
                    fs:Show()
                end
            end
        end

        self.right.title:SetText(metric.label)
        self.right.sub:SetText(string.format("%d squares  ·  most: %s", #list, isMoney and Money(max) or tostring(max)))
        local rows = { { header = true, text = "Top squares" } }
        for i, e in ipairs(list) do
            if i > 15 then break end
            local near
            local best
            for name, spot in pairs(f.spots[state.map] or {}) do
                if spot.pn > 0 then
                    local dx, dy = spot.px / spot.pn - (e.cx + 0.5) / Fishing.GRID, spot.py / spot.pn - (e.cy + 0.5) / Fishing.GRID
                    local d = dx * dx + dy * dy
                    if not best or d < best then best, near = d, name end
                end
            end
            rows[#rows + 1] = { text = string.format("%.0f, %.0f", (e.cx + 0.5) * 2, (e.cy + 0.5) * 2) .. HEX.muted .. "  " .. (near or "") .. "|r",
                cols = { isMoney and Money(e.value) or tostring(e.value) } }
        end
        if #list == 0 then rows[#rows + 1] = { text = HEX.muted .. "Nothing for this on this map.|r" } end
        if metric.id then
            rows[#rows + 1] = { header = true, text = "This fish" }
            local v1 = Fishing.ItemValue(metric.id)
            rows[#rows + 1] = { icon = Fishing.ItemIcon(metric.id), text = Fishing.ItemText(metric.id), cols = { v1 > 0 and Money(v1) or (HEX.dim .. "?|r") } }
        end
        if not art then rows[#rows + 1] = { text = HEX.muted .. "No map image from the game here: labels mark where you fished.|r" } end
        self.list:SetItems(rows)
    end
    return v
end

---------------------------------------------------------------------------
-- Log: casts and encounters
---------------------------------------------------------------------------
local function CastRow(e)
    local parts = {}
    local value = 0
    for id, n in pairs(e.items) do
        parts[#parts + 1] = (n > 1 and (n .. "x ") or "") .. Fishing.ItemText(id)
        value = value + Fishing.ItemValue(id) * n
    end
    return { label = Date(e.t), text = (e.result == "c" and table.concat(parts, ", ") or ResultText(e.result))
        .. HEX.muted .. "  ·  " .. (e.sub or "?") .. "|r",
        cols = { e.result == "c" and value > 0 and Money(value) or "" },
        tooltip = function(owner)
            local lines = { ResultText(e.result), Date(e.t) .. "  ·  " .. (e.sub or "?")
                .. (e.serverMin and string.format("  ·  server time %02d:%02d", e.serverHour, e.serverMin % 60) or ""),
                "Skill " .. (e.skill or "?") .. ((e.mod or 0) ~= 0 and (" +" .. e.mod) or "")
                    .. (e.lureID and ("  ·  " .. Fishing.LureLabel(e.lureID)) or (e.lure and "  ·  lure on" or "")) }
            if e.channel then lines[#lines + 1] = string.format("Channel: %.1f s", e.channel) end
            local tags = {}
            for k, val in pairs(e.tags or {}) do tags[#tags + 1] = val == true and k or (k .. " " .. tostring(val)) end
            table.sort(tags)
            if #tags > 0 then lines[#lines + 1] = "Tags: " .. table.concat(tags, ", ") end
            ns.Tooltip.Text(owner, lines)
        end }
end

local function ThreatRow(r)
    return { label = Date(r.t), text = (KIND_TEXT[r.k] or r.k) .. WhoText(r) .. (r.died and (HEX.bad .. "  · you died|r") or "")
        .. HEX.muted .. "  ·  " .. (r.sub or "?") .. "|r" }
end

local function BuildLog(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.left = Style.Card(v, "Casts")
    v.left:SetPoint("TOPLEFT")
    v.left:SetPoint("BOTTOMLEFT")
    v.left:SetWidth(470)
    v.list = Style.List(v.left.content, { labelWidth = 82, colWidths = { 60 }, search = true, time = true, hint = "Search fish, spots, results..." })
    v.right = Style.Card(v, "Encounters while fishing")
    v.right:SetPoint("TOPLEFT", v.left, "TOPRIGHT", 10, 0)
    v.right:SetPoint("BOTTOMRIGHT")
    v.threats = Style.List(v.right.content, { labelWidth = 82, search = true, time = true, hint = "Search names, kinds, spots..." })

    function v:Footer()
        return "Attacks are combat you did not start while fishing; the attacker is whoever targeted you (\"?\" when nothing readable did)."
    end

    function v:Refresh()
        ns.Data.List(self.list, {
            name = "fishing:casts", sources = { "fishing", "prices" }, row = CastRow, empty = "No casts logged yet.",
            build = function(add)
                for _, e in ipairs(Fishing.RecentCasts(400)) do add(e, { time = e.t }) end
            end,
        })
        local f = Fishing.Store()
        self.left.sub:SetText(string.format("newest first  ·  %d kept (max %d)", #f.casts, db().fishMaxCasts or 0))

        local data = ns.Data.List(self.threats, {
            name = "fishing:threats", sources = { "fishing" }, row = ThreatRow, empty = "No attacks or enemy players while fishing so far.",
            build = function(add)
                local counts = { N = 0, P = 0, ["?"] = 0, E = 0 }
                for i = #f.threats, 1, -1 do
                    local r = f.threats[i]
                    if counts[r.k] then counts[r.k] = counts[r.k] + 1 end
                    add(r, { time = r.t })
                end
                return { counts = counts }
            end,
        })
        local counts = data.counts
        self.right.sub:SetText(string.format("%d NPC attacks  ·  %d player attacks  ·  %d unclear  ·  %d enemies seen",
            counts.N, counts.P, counts["?"], counts.E))
    end
    return v
end

---------------------------------------------------------------------------
-- Sessions
---------------------------------------------------------------------------
local function SessionRow(x)
    local s, current = x.s, x.current
    local r = Fishing.Rates(s)
    local gained = (s.skill1 and s.skill0) and s.skill1 - s.skill0 or 0
    local attacks = (s.x or 0) + (s.p or 0) + (s.u or 0)
    return {
        label = date("%b %d %H:%M", s.start),
        text = (current and (HEX.accent .. "now  |r") or "") .. (s.zone or "?") .. HEX.muted .. string.format("  ·  %s  ·  %d/%d caught%s%s|r",
            Fishing.Minutes(r.hours * 60), s.c or 0, s.n or 0, attacks > 0 and string.format("  ·  %d attacks", attacks) or "",
            (s.e or 0) > 0 and string.format("  ·  %d enemies", s.e) or ""),
        cols = { Money(r.value), r.gph and Money(r.gph) or (HEX.dim .. "?|r"), gained > 0 and (HEX.good .. "+" .. gained .. "|r") or (HEX.dim .. "-|r") },
        accent = current and COLORS.accent or nil,
        tooltip = function(owner)
            local lines = { (s.zone or "?") .. "  ·  " .. (s.char or "?"), Fishing.SessionSummary(s) }
            local items = {}
            for id, n in pairs(s.it or {}) do items[#items + 1] = { id = id, n = n } end
            table.sort(items, function(a, b) return a.n > b.n end)
            for k, it in ipairs(items) do
                if k > 10 then break end
                lines[#lines + 1] = string.format("  %dx %s", it.n, Fishing.ItemName(it.id))
            end
            ns.Tooltip.Text(owner, lines)
        end,
    }
end

local function BuildSessions(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Sessions")
    v.card:SetAllPoints()
    v.list = Style.List(v.card.content, { labelWidth = 92, colWidths = { 70, 70, 50 }, search = true, time = true, hint = "Search zones, characters...",
        columns = { name = "Zone", label = "Started", "Value", "Per hour", "Skill" } })

    function v:Footer()
        return "A session ends after 5 minutes without a cast or on another map. Value: the catch at today's prices."
    end

    function v:Refresh()
        local f = Fishing.Store()
        -- Kept until a cast or a session ends (a minute at most: the open
        -- session's time and today's prices move).
        local data = ns.Data.List(self.list, {
            name = "fishing:sessions", sources = { "fishing", "prices" }, maxAge = 60, row = SessionRow, empty = "No sessions yet.",
            build = function(add)
                local d = { value = 0, seconds = 0 }
                if f.session then add({ s = f.session, current = true }, { time = f.session.start }) end
                for i = #f.sessions, 1, -1 do
                    local s = f.sessions[i]
                    add({ s = s }, { time = s.start, search = (s.zone or "") .. " " .. (s.char or "") })
                    d.value = d.value + (Fishing.ItemsValue(s.it))
                    d.seconds = d.seconds + (s.s or 0)
                end
                return d
            end,
        })
        local value, seconds = data.value, data.seconds
        self.card.sub:SetText(string.format("%d sessions  ·  %s fished  ·  %s caught at today's prices%s", #f.sessions,
            Fishing.Minutes(seconds / 60), Money(value), seconds >= 600 and ("  ·  " .. Money(value / (seconds / 3600)) .. "/h") or ""))
    end
    return v
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local VIEWS = {
    { key = "now", label = "Now", build = BuildNow },
    { key = "spots", label = "Spots", build = BuildSpots },
    { key = "map", label = "Map", build = BuildMap },
    { key = "log", label = "Log", build = BuildLog },
    { key = "sessions", label = "Sessions", build = BuildSessions },
}

local function Build()
    for _, def in ipairs(hooks.views) do VIEWS[#VIEWS + 1] = def end
    for _, def in ipairs(hooks.sorts) do SORTS[#SORTS + 1] = { key = def.key, label = def.label } end
    frame = Style.Window(ns.FRAME .. "FishingWindow", "Fishing", nil, nil, { nav = "fishing" })
    frame.skill = Style.Text(frame, "GameFontDisableSmall", "RIGHT")
    frame.skill:SetPoint("TOPRIGHT", -44, -16)
    frame.autoLoot = Style.Button(frame, "", 150, function()
        Fishing.SetAutoLoot(not db().fishAutoLoot)
        UI.Refresh()
    end, function()
        local on = Fishing.AutoLootOn()
        return "On: the game's Auto Loot option is turned on at your first cast (if it is off) and put back the moment "
            .. "you unequip your fishing pole, also after a /reload. Your Auto Loot option is " .. (on == nil and "?" or (on and "on" or "off")) .. " now."
    end, { title = "Auto loot while fishing" })
    frame.autoLoot:SetPoint("TOPRIGHT", -250, -9)
    frame.splash = Style.Button(frame, "", 130, function()
        Fishing.SetLoudSplash(not db().fishLoudSplash)
        UI.Refresh()
    end, "Addons get no event when a fish bites, so the splash is made hard to miss: sound effects full, music and ambience "
        .. "off, and sound on while the game is in the background. Put back when you stop fishing; anything you change "
        .. "yourself meanwhile stays.", { title = "Loud splash while fishing" })
    frame.splash:SetPoint("RIGHT", frame.autoLoot, "LEFT", -6, 0)
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

local lastRefresh = 0
function UI.Refresh()
    if not frame or not frame:IsShown() then return end
    lastRefresh = GetTime()
    frame.skill:SetText("Fishing skill " .. SkillText())
    frame.splash:SetLabel("Splash: " .. (db().fishLoudSplash and (HEX.good .. "loud|r") or (HEX.muted .. "normal|r")))
    frame.autoLoot:SetLabel("Auto loot: " .. (db().fishAutoLoot and (HEX.good .. "on|r") or (HEX.muted .. "off|r")))
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
-- Casts, attacks and sessions redraw the window (the Now tab also follows
-- the clock, below); prices move the gold columns.
ns.Data.Window(UI, { "fishing", "prices" })
UI.state, UI.views = state, views

---------------------------------------------------------------------------
-- HUD: the panel that shows while a fishing pole is equipped. Same look as
-- the Enemies nearby panel (title bar with buttons, lock, rows, footer, its
-- Size setting) and it snaps to that panel: drag one next to the other's
-- edge and they dock; docked, the HUD moves with the panel. Dragging the
-- HUD away undocks it.
---------------------------------------------------------------------------
local HUD_WIDTH, HUD_ROW, HUD_HEADER, HUD_FOOTER, HUD_INSET = 344, 18, 30, 22, 6
local SNAP = 24                 -- pixels between edges that still snap
local hudRows = {}

local ICON = {
    session = "Interface\\Icons\\INV_Misc_Fish_02", value = "Interface\\Icons\\INV_Misc_Coin_02",
    skill = "Interface\\Icons\\Trade_Fishing", lure = "Interface\\Icons\\INV_Misc_Food_26",
    bags = "Interface\\Icons\\INV_Misc_Bag_08", enemies = "Interface\\Icons\\Ability_Rogue_Sprint",
}

local function Panel() return _G[ns.FRAME .. "Panel"] end

-- Edges in screen pixels (scale applied), or nil when not laid out.
local function Edges(f)
    if not f then return nil end
    local l, r, t, b = f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
    if not (l and r and t and b) then return nil end
    local s = f:GetEffectiveScale() or 1
    return { l = l * s, r = r * s, t = t * s, b = b * s }
end

-- Where `moving` would dock on `fixed`: "bottom", "top", "right", "left" or nil.
local function SnapSide(moving, fixed)
    local m, f = Edges(moving), Edges(fixed)
    if not m or not f or not fixed:IsShown() then return nil end
    local overlapX = m.l < f.r and m.r > f.l
    local overlapY = m.b < f.t and m.t > f.b
    if overlapX and math.abs(m.t - f.b) <= SNAP then return "bottom" end
    if overlapX and math.abs(m.b - f.t) <= SNAP then return "top" end
    if overlapY and math.abs(m.l - f.r) <= SNAP then return "right" end
    if overlapY and math.abs(m.r - f.l) <= SNAP then return "left" end
    return nil
end
UI.SnapSide = SnapSide

local function PlaceHUD()
    hud:ClearAllPoints()
    local dock, panel = db().fishHudDock, Panel()
    if dock and panel then
        if dock == "bottom" then hud:SetPoint("TOPLEFT", panel, "BOTTOMLEFT", 0, 1)
        elseif dock == "top" then hud:SetPoint("BOTTOMLEFT", panel, "TOPLEFT", 0, -1)
        elseif dock == "right" then hud:SetPoint("TOPLEFT", panel, "TOPRIGHT", -1, 0)
        else hud:SetPoint("TOPRIGHT", panel, "TOPLEFT", 1, 0) end
        return
    end
    local pos = db().fishHudPos
    if type(pos) == "table" and pos[1] and pos[2] then
        hud:SetPoint("CENTER", UIParent, "CENTER", pos[1], pos[2])
    else
        hud:SetPoint("CENTER", UIParent, "CENTER", 0, -180)
    end
end

-- Docks the HUD on the panel if they touch; else saves where it is.
local function SnapOrSave()
    local panel = Panel()
    local side = panel and SnapSide(hud, panel)
    if side then
        db().fishHudDock = side
    else
        -- The panel next to the HUD: the HUD docks on that side of it.
        local back = panel and SnapSide(panel, hud)
        local opposite = { bottom = "top", top = "bottom", right = "left", left = "right" }
        if back then
            db().fishHudDock = opposite[back]
        else
            db().fishHudDock = nil
            local cx, cy = hud:GetCenter()
            local ux, uy = UIParent:GetCenter()
            if cx and ux then db().fishHudPos = { math.floor(cx - ux + 0.5), math.floor(cy - uy + 0.5) } end
        end
    end
    PlaceHUD()
end
UI.SnapOrSave = SnapOrSave

local function HUDRow(i)
    local r = hudRows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, hud)
    r:SetSize(HUD_WIDTH - 2, HUD_ROW)
    r:EnableMouse(true)
    r.bg = Style.Texture(r, "BACKGROUND")
    r.bg:SetAllPoints()
    r.accent = Style.Texture(r, "ARTWORK")
    r.accent:SetWidth(3)
    r.accent:SetPoint("TOPLEFT")
    r.accent:SetPoint("BOTTOMLEFT")
    r.iconFrame, r.icon = Style.IconFrame(r, 16)
    r.iconFrame:SetPoint("TOPLEFT", HUD_INSET - 1, -1)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.label = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.label:SetPoint("TOPLEFT", 18 + HUD_INSET, -2)
    r.label:SetSize(70, 14)
    r.label:SetJustifyH("LEFT")
    r.value = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.value:SetPoint("TOPLEFT", 92 + HUD_INSET, -2)
    r.value:SetSize(HUD_WIDTH - 104 - HUD_INSET, 14)
    r.value:SetJustifyH("LEFT")
    if r.value.SetWordWrap then r.value:SetWordWrap(false) end
    r:SetScript("OnEnter", function(self) if self.tip then ns.Tooltip.Text(self, self.tip) end end)
    r:SetScript("OnLeave", function() ns.Tooltip.Hide() end)
    r:SetPoint("TOPLEFT", hud, "TOPLEFT", 1, -HUD_HEADER - (i - 1) * HUD_ROW)
    hudRows[i] = r
    return r
end

local function HUDTitleButton(icon, tooltip, onClick)
    return Style.Button(hud, nil, 18, onClick, tooltip, { icon = icon, height = 18, title = "" })
end

local function ApplyHUDStyle()
    if not hud then return end
    hud:SetScale(db().panelScale or 1)
    local locked = db().fishHudLocked
    hud.lock.tex:SetTexture(locked and "Interface\\Buttons\\LockButton-Locked-Up" or "Interface\\Buttons\\LockButton-Unlocked-Up")
    local c = locked and COLORS.border or COLORS.accent
    hud:SetBorderColor(c[1], c[2], c[3], locked and 1 or 0.9)
end
UI.ApplyHUDStyle = ApplyHUDStyle

local function BuildHUD()
    hud = CreateFrame("Frame", ns.FRAME .. "FishingHUD", UIParent)
    hud:SetSize(HUD_WIDTH, HUD_HEADER + HUD_ROW * 6 + HUD_FOOTER)
    hud:SetFrameStrata("MEDIUM")
    hud:SetMovable(true)
    hud:SetClampedToScreen(true)
    hud:EnableMouse(true)
    hud:RegisterForDrag("LeftButton")
    Style.Surface(hud, "hud")
    local bar = Style.Texture(hud, "BACKGROUND", COLORS.titleBar)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:SetHeight(HUD_HEADER - 6)
    -- The cast: a thin bar under the title fills over the channel (its length from the game, else 30 s).
    hud.cast = Style.Texture(hud, "ARTWORK", COLORS.accent)
    hud.cast:SetHeight(2)
    hud.cast:SetPoint("TOPLEFT", 1, -(HUD_HEADER - 6))
    hud.cast:Hide()
    -- Unlocked: drag anywhere. Locked: Shift + drag still moves it (as the panel).
    hud:SetScript("OnDragStart", function(self)
        if db().fishHudLocked and not IsShiftKeyDown() then return end
        -- Docked: start from where it is, free of the panel.
        local cx, cy = self:GetCenter()
        local ux, uy = UIParent:GetCenter()
        if cx and ux then
            self:ClearAllPoints()
            self:SetPoint("CENTER", UIParent, "CENTER", cx - ux, cy - uy)
        end
        self:StartMoving()
    end)
    hud:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SnapOrSave()
    end)
    hud.title = hud:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hud.title:SetPoint("TOPLEFT", 9, -7)
    hud.title:SetPoint("RIGHT", hud, "RIGHT", -90, 0)
    hud.title:SetJustifyH("LEFT")
    if hud.title.SetWordWrap then hud.title:SetWordWrap(false) end

    local settings = HUDTitleButton("Interface\\Icons\\INV_Misc_Gear_01", "Fishing settings",
        function() ns.Options.OpenTab(ns.Options.TabIndex("Fishing"), 1) end)
    settings:SetPoint("TOPRIGHT", -4, -3)
    local window = HUDTitleButton("Interface\\Icons\\Trade_Fishing", "Fishing window: spots, heat map, log, sessions",
        function() UI.Toggle("now") end)
    window:SetPoint("RIGHT", settings, "LEFT", -3, 0)
    local lock = HUDTitleButton(nil, function()
        return db().fishHudLocked and "Locked (Shift + drag still moves it)" or "Unlocked: drag to move. Drop it next to the Enemies nearby panel to snap them together."
    end, function()
        db().fishHudLocked = not db().fishHudLocked
        ApplyHUDStyle()
    end)
    lock.tex = lock:CreateTexture(nil, "ARTWORK")
    lock.tex:SetPoint("TOPLEFT", 1, -1)
    lock.tex:SetPoint("BOTTOMRIGHT", -1, 1)
    lock:SetPoint("RIGHT", window, "LEFT", -3, 0)
    hud.lock = lock

    hud.footerLine = Style.HLine(hud)
    hud.footerLine:SetPoint("BOTTOMLEFT", 1, HUD_FOOTER - 2)
    hud.footerLine:SetPoint("BOTTOMRIGHT", -1, HUD_FOOTER - 2)
    hud.footer = hud:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hud.footer:SetPoint("BOTTOMLEFT", 9, 6)
    hud.footer:SetPoint("RIGHT", hud, "RIGHT", -9, 0)
    hud.footer:SetJustifyH("LEFT")
    if hud.footer.SetWordWrap then hud.footer:SetWordWrap(false) end

    -- Dragging the panel next to the HUD snaps them too.
    local panel = Panel()
    if panel and panel.HookScript then
        panel:HookScript("OnDragStop", function()
            if hud and hud:IsShown() and not db().fishHudDock and SnapSide(panel, hud) then SnapOrSave() end
        end)
    end
    hud.rows = hudRows
    PlaceHUD()
    ApplyHUDStyle()
    hud:Hide()
    RunHooks(hooks.hudBuilt, hud)
end

function UI.HUDRowByKey(key)
    if not hud or not hud:IsShown() then return nil end
    for _, r in ipairs(hudRows) do
        if r:IsShown() and r.key == key then return r end
    end
    return nil
end

function UI.ResetHUD()
    db().fishHudDock = nil
    if hud then PlaceHUD() end
end

-- The rows: { key, label, value, tip, warn }.
local function HUDLines(s, r)
    local d = db()
    local lines = {}
    if r then
        local gained = (s.skill1 and s.skill0) and s.skill1 - s.skill0 or 0
        lines[#lines + 1] = { key = "session", label = "Session", value = string.format("%s  ·  %s%d|r/%d caught (%s)",
            Fishing.Minutes(r.hours * 60), HEX.good, s.c or 0, s.n or 0, Pct(r.catchPct)),
            tip = { "This session", "Fishing time (channels and short gaps), catches of casts, catch rate (catches and fish that got away; "
                .. "missed clicks, timeouts and interruptions left out)." } }
        lines[#lines + 1] = { key = "value", label = "Value", value = Money(r.value) .. (r.gph and (HEX.muted .. "  ·  " .. Money(r.gph) .. " per hour|r") or "")
            .. (r.unseen > 0 and (HEX.gold .. "  ·  " .. r.unseen .. " not on AH|r") or ""),
            tip = { "Value caught", "AH after the cut x your sell rate, or vendor, whichever is more.", "Per hour after 5 minutes fished." } }
        local need, capped = Fishing.NextPoint()
        lines[#lines + 1] = { key = "skill", label = "Skill", value = SkillText() .. (gained > 0 and (HEX.good .. "  +" .. gained .. "|r") or "")
            .. HEX.muted .. "  ·  next " .. (capped and (HEX.gold .. "train|r") or (need and ("~" .. need .. " catches") or "?")) .. "|r",
            warn = capped, tip = { "Fishing skill", "With lure and gear. Next point: from the catches your last points took." } }
    else
        local need, capped = Fishing.NextPoint()
        lines[#lines + 1] = { key = "skill", label = "Skill", value = SkillText() .. HEX.muted .. "  ·  next "
            .. (capped and (HEX.gold .. "train|r") or (need and ("~" .. need .. " catches") or "?")) .. "|r", warn = capped,
            tip = { "Fishing skill", "With lure and gear." } }
    end
    local on, left = Fishing.Lure()
    lines[#lines + 1] = { key = "lure", label = "Lure", value = LureText(), warn = on == false or (left ~= nil and left < 30),
        tip = { "Lure", "A lure on your pole raises your skill while it lasts. You are warned when it runs out." } }
    local free = Fishing.FreeSlots()
    local low = free and free <= (d.fishBagWarn or 2)
    lines[#lines + 1] = { key = "bags", label = "Bags", value = free and ((low and HEX.bad or "") .. free .. " free" .. (low and "|r" or "")) or "?",
        warn = low, tip = { "Bag space", "Free slots in your bags." } }
    local live = ns.Spotter.Count()
    lines[#lines + 1] = { key = "enemies", label = "Enemies", value = live > 0 and (HEX.bad .. live .. " in view|r") or (HEX.muted .. "none in view|r"),
        warn = live > 0, tip = { "Enemy players in view", "From their nameplates (the Enemies nearby panel lists them)." } }
    for _, fn in ipairs(hooks.hudLines) do
        local line = HookValue(fn, s, r)
        if type(line) == "table" then lines[#lines + 1] = line end
    end
    return lines
end

function UI.UpdateHUD()
    local d = db()
    local s = Fishing.Session()
    -- Shown while a fishing pole is in your hands; when the game does not
    -- say what you hold, while you fish.
    local pole = Fishing.PoleEquipped()
    local want = d.fishHud and d.fishingEnabled and (pole == true or (pole == nil and Fishing.IsFishing()))
    if not want then
        if hud then hud:Hide() end
    else
        if not hud then BuildHUD() end
        local r = s and Fishing.Rates(s)
        local elapsed, duration = Fishing.CastElapsed()
        duration = duration or 30
        hud.title:SetText("Fishing" .. (elapsed and string.format("  %s%ds|r", elapsed >= duration - 5 and HEX.gold or HEX.white, math.floor(elapsed)) or "")
            .. (s and (HEX.muted .. "  " .. (s.zone or "") .. "|r") or ""))
        if elapsed then
            hud.cast:SetWidth(math.max(1, (HUD_WIDTH - 2) * math.min(1, elapsed / duration)))
            hud.cast:Show()
        else
            hud.cast:Hide()
        end
        local lines = HUDLines(s, r)
        for i, line in ipairs(lines) do
            local row = HUDRow(i)
            row.bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.03 or 0)
            row.accent:SetShown(line.warn == true)
            if line.warn then row.accent:SetColorTexture(1, 0.82, 0.2, 1) end
            row.icon:SetTexture(line.icon or ICON[line.key])
            row.iconFrame:SetColorTexture(0.3, 0.3, 0.3, 0.9)
            row.label:SetText(HEX.muted .. line.label .. "|r")
            row.value:SetText(line.value)
            row.tip, row.key = line.tip, line.key
            row:Show()
        end
        for i = #lines + 1, #hudRows do hudRows[i]:Hide() end
        local p = Fishing.Place()
        local spot = p.mapID and Fishing.GetSpot(p.mapID, p.sub)
        local danger
        if spot then
            local z = Fishing.Danger(spot)
            if z.minutes < Fishing.MIN_MINUTES then
                danger = HEX.muted .. "? (new spot)|r"
            elseif z.attacks == 0 then
                danger = HEX.muted .. "no attacks in " .. Fishing.Minutes(z.minutes) .. "|r"
            else
                danger = HEX.gold .. "an attack every " .. Fishing.Minutes(z.attackEvery) .. "|r"
            end
        else
            danger = HEX.muted .. "? (new spot)|r"
        end
        hud.footer:SetText("Here: " .. (p.sub or "?") .. "  ·  " .. danger)
        hud:SetHeight(HUD_HEADER + #lines * HUD_ROW + HUD_FOOTER + 4)
        hud:Show()
    end
    if hud then RunHooks(hooks.hudUpdated, hud) end
    -- The open window follows along once a second at most.
    if frame and frame:IsShown() and GetTime() - lastRefresh >= 1 and state.view == "now" then UI.Refresh() end
end
