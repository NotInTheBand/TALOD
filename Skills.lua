-- TALOD - Skills: your professions, secondary skills, weapon skills and
-- defense over time. Every skill-up is logged with date, zone and your level
-- (merged while you keep raising one skill in one zone), and so are training
-- (a new maximum), new skills and dropped ones.
--
-- Read from the Skills tab's lines (GetSkillLineInfo). Categories you
-- collapsed there are not read: expanding them would change your UI, so
-- their skills keep their last known values until you expand them.
-- The newer engine (WoW Forever) has no GetSkillLineInfo global; the same
-- list is C_SkillInfo.GetNumSkillLines / GetSkillLineInfo(i), which returns
-- a table (name, rank, maxRank, ...). Only if neither
-- exists: professions (GetProfessions / GetProfessionInfo)
-- plus defense and the skill of the weapons you hold from the character
-- stats (UnitDefense, UnitAttackBothHands, UnitRangedAttack), plus what the
-- profession window says when you open it (Skills.FromWindow).
-- Chat messages are not parsed (they may be secret on Forever).
--
-- Data is per character: TALODDB.skills["Name-Realm"].

local ADDON_NAME, ns = ...
local S = ns.Secret
local Style = ns.Style
local COLORS, HEX = Style.COLORS, Style.HEX

local Skills = {}
ns.Skills = Skills

local READ_DELAY = 0.5        -- seconds after SKILL_LINES_CHANGED
local MERGE_SECONDS = 600     -- skill-ups of one skill in one zone within this merge into one entry
local MAX_LOG = 3000
local MAX_HISTORY = 400       -- rank points kept per skill

local pendingAt, loginAt, ready = nil, nil, false
local windowSkills = {}       -- [name] = { rank, max, cat } from the open profession window
local SECONDARY = { ["First Aid"] = true, Cooking = true, Fishing = true }

local function db() return ns.DB() end

-- The skill line functions: the classic globals, else C_SkillInfo.
local function LineAPI()
    if type(GetNumSkillLines) == "function" and type(GetSkillLineInfo) == "function" then
        return GetNumSkillLines, GetSkillLineInfo, "GetSkillLineInfo"
    end
    local C = C_SkillInfo
    if type(C) == "table" and type(C.GetNumSkillLines) == "function" and type(C.GetSkillLineInfo) == "function" then
        return C.GetNumSkillLines, C.GetSkillLineInfo, "C_SkillInfo"
    end
end

function Skills.HasSkillLines() return LineAPI() ~= nil end
function Skills.Source() return select(3, LineAPI()) or (Skills.HasProfessions() and "professions") or "none" end

function Skills.HasProfessions()
    return type(GetProfessions) == "function" and type(GetProfessionInfo) == "function"
end

function Skills.Available()
    return Skills.HasSkillLines() or Skills.HasProfessions()
end

function Skills.Char(key)
    key = key or ns.Gear.CharKey()
    if not key then return nil end
    local c = db().skills[key]
    if not c then
        c = { current = {}, log = {}, history = {} }
        db().skills[key] = c
    end
    return c, key
end

-- Category of a skill when the list has no headers (vanilla's grouping).
local WEAPON_SKILLS = {
    Axes = true, ["Two-Handed Axes"] = true, Bows = true, Crossbows = true, Daggers = true, ["Fist Weapons"] = true,
    Guns = true, Maces = true, ["Two-Handed Maces"] = true, Polearms = true, Staves = true, Swords = true,
    ["Two-Handed Swords"] = true, Thrown = true, Wands = true, Unarmed = true, Defense = true,
}
local PROFESSIONS = {
    Alchemy = true, Blacksmithing = true, Enchanting = true, Engineering = true, Herbalism = true,
    Leatherworking = true, Mining = true, Skinning = true, Tailoring = true,
}
local function CategoryOf(name)
    if WEAPON_SKILLS[name] then return "Weapon Skills" end
    if PROFESSIONS[name] then return "Professions" end
    if SECONDARY[name] then return "Secondary Skills" end
    return nil
end
Skills.CategoryOf = CategoryOf

-- One line: (name, isHeader, isExpanded, rank, mod, max, category). The
-- C_SkillInfo version returns a table; its field names are not documented,
-- so the likely ones are tried.
local function LineInfo(infoFn, i)
    local v = { S.CallMulti(7, infoFn, i) }
    -- Classic returns: an expanded header is 1 / true, a collapsed one nil / false.
    if type(v[1]) ~= "table" then return v[1], v[2], v[3] and true or false, v[4], v[6], v[7], nil end
    local t = v[1]
    local function F(...)
        for k = 1, select("#", ...) do
            local x = S.Value(t[select(k, ...)])
            if x ~= nil then return x end
        end
    end
    return F("name", "skillName"), F("isHeader", "header"), F("isExpanded", "expanded"),
        F("rank", "skillRank", "skillLevel", "currentRank"), F("modifier", "skillModifier", "rankModifier", "tempPoints"),
        F("maxRank", "skillMaxRank", "maxSkillLevel", "max"), F("category", "categoryName", "skillType")
end

-- Weapon item subclasses -> vanilla skill names.
local WEAPON_SUBCLASS = {
    [0] = "Axes", [1] = "Two-Handed Axes", [2] = "Bows", [3] = "Guns", [4] = "Maces", [5] = "Two-Handed Maces",
    [6] = "Polearms", [7] = "Swords", [8] = "Two-Handed Swords", [10] = "Staves", [13] = "Fist Weapons",
    [15] = "Daggers", [16] = "Thrown", [18] = "Crossbows", [19] = "Wands",
}

local function WeaponSkillName(slot)
    local id = S.Call(GetInventoryItemID, "player", slot)
    if type(id) ~= "number" then return slot == 16 and "Unarmed" or nil end
    local fn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    local _, _, _, _, _, classID, subclassID = S.CallMulti(7, fn, id)
    if classID ~= 2 then return slot == 16 and "Unarmed" or nil end
    return WEAPON_SUBCLASS[subclassID]
end

-- Defense and the weapons you hold, from the character stats. Maximum:
-- 5 per level (vanilla). Weapons you do not hold keep their last value.
local function ReadCombatStats(out)
    local level = S.Call(UnitLevel, "player")
    local max = type(level) == "number" and level * 5 or nil
    if not max then return end
    local function Put(name, base, mod)
        if type(name) == "string" and type(base) == "number" and base > 0 then
            out[name] = { rank = base, max = max, mod = (type(mod) == "number" and mod ~= 0) and mod or nil,
                cat = "Weapon Skills", keep = true }
        end
    end
    if type(UnitDefense) == "function" then Put("Defense", S.CallMulti(2, UnitDefense, "player")) end
    if type(UnitAttackBothHands) == "function" then
        local mainBase, mainMod, offBase, offMod = S.CallMulti(4, UnitAttackBothHands, "player")
        Put(WeaponSkillName(16), mainBase, mainMod)
        local off = WeaponSkillName(17)
        if off then Put(off, offBase, offMod) end
    end
    if type(UnitRangedAttack) == "function" then
        local ranged = WeaponSkillName(18)
        if ranged then Put(ranged, S.CallMulti(2, UnitRangedAttack, "player")) end
    end
end

-- Newer engine without skill lines: GetProfessions returns profession
-- indexes with nil holes (primary 1, primary 2, archaeology, fishing, cooking, ...).
local function ReadProfessions()
    local out = {}
    ReadCombatStats(out)
    local idx = { S.CallMulti(8, GetProfessions) }
    for slot = 1, 8 do
        local i = idx[slot]
        if type(i) == "number" then
            local name, _, rank, max, _, _, _, mod = S.CallMulti(8, GetProfessionInfo, i)
            if type(name) == "string" and type(rank) == "number" and type(max) == "number" then
                out[name] = { rank = rank, max = max, mod = (type(mod) == "number" and mod ~= 0) and mod or nil,
                    cat = (slot <= 2 and not SECONDARY[name]) and "Professions" or "Secondary Skills" }
            end
        end
    end
    for name, s in pairs(windowSkills) do
        if not out[name] then out[name] = { rank = s.rank, max = s.max, cat = s.cat, window = true } end
    end
    return out, {}
end

-- { [name] = { rank, max, mod, cat } } for every visible skill line, plus
-- the set of categories that are collapsed (their skills are not listed).
local function ReadLines()
    local numFn, infoFn = LineAPI()
    if not numFn then
        if Skills.HasProfessions() then return ReadProfessions() end
        return nil
    end
    local out, collapsed, cat = {}, {}, nil
    local n = S.Call(numFn) or 0
    for i = 1, n do
        local name, isHeader, isExpanded, rank, mod, max, category = LineInfo(infoFn, i)
        if type(name) == "string" then
            if isHeader then
                cat = name
                if isExpanded == false then collapsed[name] = true end
            elseif type(rank) == "number" then
                -- Proficiencies and languages without ranks (max 1) are not skills to level.
                if type(max) == "number" and max > 1 then
                    out[name] = { rank = rank, max = max, mod = (type(mod) == "number" and mod ~= 0) and mod or nil,
                        cat = cat or (type(category) == "string" and category) or CategoryOf(name) or "Other" }
                end
            end
        end
    end
    return out, collapsed
end
Skills.ReadLines = ReadLines

local function ZoneName()
    local zone = S.Call(GetZoneText)
    return type(zone) == "string" and zone ~= "" and zone or nil
end

local function AddLog(c, entry)
    c.log[#c.log + 1] = entry
    while #c.log > MAX_LOG do table.remove(c.log, 1) end
end

local function AddHistory(c, name, now, rank, level)
    local h = c.history[name] or {}
    c.history[name] = h
    h[#h + 1] = { now, rank, level }
    while #h > MAX_HISTORY do table.remove(h, 1) end
end

local function SkillUp(c, name, from, to, max, now, level, zone)
    local last
    for i = #c.log, math.max(1, #c.log - 20), -1 do
        local e = c.log[i]
        if e.name == name then last = e break end
    end
    if last and last.kind == "up" and last.zone == zone and now - (last.t2 or last.t) <= MERGE_SECONDS and last.to == from then
        last.to, last.t2, last.max, last.level2 = to, now, max, level
    else
        AddLog(c, { kind = "up", name = name, from = from, to = to, max = max, t = now, t2 = now, level = level, zone = zone })
    end
end

-- Compares a fresh read with what we knew and logs the differences.
function Skills.Update()
    local lines, collapsed = ReadLines()
    if not lines then return false end
    local c = Skills.Char()
    if not c then return false end
    local now = time()
    local level = S.Call(UnitLevel, "player")
    local zone = ZoneName()
    local first = not c.baseline
    for name, s in pairs(lines) do
        local old = c.current[name]
        if not old then
            if not first then AddLog(c, { kind = "learned", name = name, to = s.rank, max = s.max, t = now, level = level, zone = zone }) end
            AddHistory(c, name, now, s.rank, level)
        else
            if s.rank > old.rank then
                SkillUp(c, name, old.rank, s.rank, s.max, now, level, zone)
                AddHistory(c, name, now, s.rank, level)
                if ns.Professions and ns.Professions.OnRank then ns.Professions.OnRank(c, name, old.rank, s.rank) end
            end
            -- Weapon skills' maximum grows with your level by itself; only
            -- professions and secondary skills are "trained".
            if s.max > old.max and old.cat ~= nil and not tostring(old.cat):find("Weapon") then
                AddLog(c, { kind = "trained", name = name, from = old.max, to = s.max, t = now, level = level, zone = zone })
            end
        end
        c.current[name] = s
    end
    for name, old in pairs(c.current) do
        -- A skill only the profession window reported stays until the window says otherwise.
        if not lines[name] and not (old.cat and collapsed[old.cat]) and not old.window and not old.keep then
            AddLog(c, { kind = "dropped", name = name, from = old.rank, max = old.max, t = now, level = level, zone = zone })
            c.current[name] = nil
        end
    end
    c.baseline = true
    c.collapsed = next(collapsed) and collapsed or nil
    ns.Data.Changed("skills")
    return true
end

-- The open profession window's rank (Professions reads it): on the newer
-- engine the only source for a skill GetProfessions does not list.
function Skills.FromWindow(name, rank, max)
    if type(name) ~= "string" or type(rank) ~= "number" or type(max) ~= "number" or Skills.HasSkillLines() then return end
    windowSkills[name] = { rank = rank, max = max, cat = SECONDARY[name] and "Secondary Skills" or "Professions" }
    if ready then pendingAt = GetTime() end
end

-- Sum of skill points gained since `since` for a skill (or all when nil).
function Skills.GainedSince(c, name, since)
    local total = 0
    for _, e in ipairs(c and c.log or {}) do
        if e.kind == "up" and (e.t2 or e.t) >= since and (not name or e.name == name) then
            total = total + (e.to - e.from)
        end
    end
    return total
end

local function OnEvent(event)
    if not db().skillsEnabled then return end
    if event == "PLAYER_ENTERING_WORLD" then
        loginAt = loginAt or GetTime()
    elseif ready then
        pendingAt = GetTime()
    end
end

local function Tick()
    if not db().skillsEnabled then return end
    local now = GetTime()
    if not ready then
        if loginAt and now - loginAt >= 3 then
            ready = true
            Skills.Update()
        end
        return
    end
    if pendingAt and now - pendingAt >= READ_DELAY then
        pendingAt = nil
        Skills.Update()
    end
end

---------------------------------------------------------------------------
-- Character window view
---------------------------------------------------------------------------
local selected       -- skill name shown on the right, nil = all

local function Date(t) return t and date("%b %d  %H:%M", t) or "?" end

local function LogText(e)
    if e.kind == "up" then
        return string.format("%s  %d -> %d  %s(+%d)|r", e.name, e.from, e.to, HEX.good, e.to - e.from)
    elseif e.kind == "trained" then
        return string.format("%s  %strained: max %d -> %d|r", e.name, HEX.gold, e.from, e.to)
    elseif e.kind == "learned" then
        return string.format("%s  %slearned (%d / %d)|r", e.name, HEX.accent, e.to, e.max or 0)
    elseif e.kind == "dropped" then
        return string.format("%s  %sdropped at %d|r", e.name, HEX.bad, e.from or 0)
    end
    return e.name or "?"
end

local function SkillLogRow(e)
    return { label = Date(e.t), text = LogText(e)
        .. HEX.muted .. "  ·  " .. (e.zone or "?") .. (e.level and ("  ·  level " .. e.level) or "") .. "|r",
        tooltip = function(owner)
            local lines = { LogText(e), Date(e.t) .. ((e.t2 and e.t2 ~= e.t) and ("  to  " .. Date(e.t2)) or "") }
            if e.zone then lines[#lines + 1] = e.zone end
            if e.level then lines[#lines + 1] = "Your level: " .. e.level .. ((e.level2 and e.level2 ~= e.level) and (" -> " .. e.level2) or "") end
            ns.Tooltip.Text(owner, lines)
        end }
end

local function BuildView(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.left = Style.Card(v, "Skills")
    v.left:SetPoint("TOPLEFT")
    v.left:SetPoint("BOTTOMLEFT")
    v.left:SetWidth(400)
    v.list = Style.List(v.left.content, { colWidths = { 64, 52 }, search = true, hint = "Search skills...", onClick = function(item)
        selected = (selected == item.name) and nil or item.name
        ns.GearUI.Refresh()
    end })
    v.right = Style.Card(v, "History")
    v.right:SetPoint("TOPLEFT", v.left, "TOPRIGHT", 10, 0)
    v.right:SetPoint("BOTTOMRIGHT")
    v.log = Style.List(v.right.content, { labelWidth = 92, search = true, time = true, hint = "Search skills, zones..." })

    function v:Footer()
        return "Click a skill for its history (click again for all). Collapsed categories in your Skills tab are not read."
    end

    function v:Refresh()
        local key = ns.GearUI.CharKey()
        local c = key and db().skills[key]
        if not Skills.Available() then
            self.list:SetItems({ { text = HEX.muted .. "This client gives addons neither skill lines nor professions.|r" } })
            self.log:SetItems({})
            self.left.sub:SetText("")
            return
        end
        local week = time() - 7 * 86400
        -- Group by category, in the order the game lists them.
        local cats, byCat = {}, {}
        for name, s in pairs(c and c.current or {}) do
            local cat = s.cat or "Other"
            if not byCat[cat] then byCat[cat] = {} cats[#cats + 1] = cat end
            table.insert(byCat[cat], name)
        end
        local ORDER = { Professions = 1, ["Secondary Skills"] = 2, ["Weapon Skills"] = 3, ["Class Skills"] = 4 }
        table.sort(cats, function(a, b) return (ORDER[a] or 9) < (ORDER[b] or 9) or ((ORDER[a] or 9) == (ORDER[b] or 9) and a < b) end)
        local rows, count = {}, 0
        for _, cat in ipairs(cats) do
            rows[#rows + 1] = { header = true, text = cat .. ((c.collapsed and c.collapsed[cat]) and "  (collapsed: not updating)" or ""),
                sortId = "skills", cols = { "Rank", "7 days" } }
            table.sort(byCat[cat])
            for _, name in ipairs(byCat[cat]) do
                local s = c.current[name]
                local gained = Skills.GainedSince(c, name, week)
                local capped = s.rank >= s.max
                count = count + 1
                rows[#rows + 1] = {
                    name = name,
                    text = (selected == name and HEX.accent or "") .. name .. (selected == name and "|r" or "")
                        .. (s.mod and (HEX.good .. "  +" .. s.mod .. "|r") or ""),
                    bar = { s.rank, s.max, color = capped and { 0.30, 0.70, 0.35 } or nil },
                    cols = { string.format("%d / %d", s.rank, s.max), gained > 0 and (HEX.good .. "+" .. gained .. "|r") or (HEX.dim .. "-|r") },
                    sort = { [2] = gained },
                    accent = selected == name and COLORS.accent or nil,
                    tooltip = function(owner)
                        local lines = { name, string.format("%d / %d%s", s.rank, s.max, s.mod and (" (+" .. s.mod .. " from gear or buffs)") or ""),
                            string.format("Last 7 days: +%d  ·  last 24 h: +%d", gained, Skills.GainedSince(c, name, time() - 86400)) }
                        if capped then lines[#lines + 1] = HEX.gold .. "At the maximum: train or level up to go on.|r" end
                        ns.Tooltip.Text(owner, lines)
                    end,
                }
            end
        end
        if count == 0 then
            rows = { { text = HEX.muted .. (Skills.HasSkillLines() and "No skills read yet (a few seconds after login)."
                or "No professions read yet. Learn one, or open your profession window once.") .. "|r" } }
        elseif not Skills.HasSkillLines() then
            rows[#rows + 1] = { text = HEX.muted .. "This client has no skill list for addons: professions, defense and the "
                .. "weapons you hold are read instead. Open a profession window to add one it leaves out.|r" }
        end
        self.list:SetItems(rows)
        self.left.sub:SetText(count .. " skills  ·  bars: rank of max  ·  7 days: gained in the last 7 days")

        -- The skill-up log (thousands of lines): kept until skills change.
        ns.Data.List(self.log, {
            name = "skills:log", sources = { "skills" }, key = { key, selected }, row = SkillLogRow,
            empty = "Nothing logged yet: skill-ups appear here as they happen.",
            build = function(add)
                local log = c and c.log or {}
                for i = #log, 1, -1 do
                    local e = log[i]
                    if not selected or e.name == selected then add(e, { time = e.t }) end
                end
            end,
        })
        if selected and c and c.current[selected] then
            local first = c.history[selected] and c.history[selected][1]
            self.right.title:SetText("History  " .. HEX.accent .. selected .. "|r")
            self.right.sub:SetText(string.format("%d / %d now%s  ·  +%d in the last 7 days", c.current[selected].rank, c.current[selected].max,
                first and string.format("  ·  %d on %s", first[2], date("%b %d", first[1])) or "", Skills.GainedSince(c, selected, week)))
        else
            self.right.title:SetText("History  " .. HEX.muted .. "all skills|r")
            self.right.sub:SetText(string.format("+%d skill points in the last 7 days", Skills.GainedSince(c, nil, week)))
        end
    end
    return v
end

ns.GearUI.AddView({ key = "skills", label = "Skills", build = BuildView })

---------------------------------------------------------------------------
-- Settings and slash
---------------------------------------------------------------------------
local function BuildPage(parent)
    local W = ns.Options.Widgets
    local y = -12
    y = W.Paragraph(parent, y, "Tracks your professions, secondary skills, weapon skills and defense: every skill-up with "
        .. "date, zone and your level, training and new skills. Shown in the character window's Skills tab.", "GameFontHighlightSmall")
    y = W.Button(parent, y, "Open the Skills tab", 170, function() ns.GearUI.Show("skills") end, "Also " .. ns.Cmd.Text("skills") .. ".")
    y = y - 4
    y = W.Header(parent, y, "Recording")
    y = W.Checkbox(parent, y, "skillsEnabled", "Track my skills", "Reads your Skills tab when the game says skills changed.")
    y = W.LiveText(parent, y, 30, function()
        if not Skills.Available() then return "This client gives addons neither skill lines nor professions." end
        local c = Skills.Char()
        local n = 0
        for _ in pairs(c and c.current or {}) do n = n + 1 end
        return string.format("This character: %d skills, %d log entries.", n, c and #c.log or 0)
    end)
    y = W.Header(parent, y, "Leveling planner")
    y = W.Button(parent, y, "Open the Professions tab", 190, function() ns.GearUI.Show("professions") end,
        "What to craft, buy and train to reach a target skill. Also " .. ns.Cmd.Text("plan") .. " tailoring 225.")
    y = W.Checkbox(parent, y, "profPlanPatterns", "Plan with patterns too",
        "Also use recipes taught by a pattern (vendor or drop). Off: trainer recipes and the ones you know.")
    y = W.Checkbox(parent, y, "profPlanBags", "Count my bags and bank", "Subtract what you have from the shopping list.")
    y = W.Header(parent, y, "Auction prices")
    y = W.Checkbox(parent, y, "auctionPrices", "Log the prices I see at the Auction House",
        "The lowest buyout per unit of everything the Auction House shows you, with the time. The planner and the crafting log use them.")
    y = W.LiveText(parent, y, 30, function()
        local n, newest = ns.Prices.Count()
        return string.format("%d prices logged for %s%s. Also " .. ns.Cmd.Text("price") .. " <item>.", n, ns.Prices.RealmKey() or "?",
            newest and (", newest " .. ns.Prices.Age(newest)) or "")
    end)
    y = W.Checkbox(parent, y, "tooltipPrices", "Show my Auction House price on item tooltips",
        "Lowest price at your last look, how long ago, the supply and the usual price.")
    y = W.Checkbox(parent, y, "tooltipMovement", "Show on item tooltips whether it sells",
        "Moves fast / moves / slow / doesn't sell: from your own auctions of it, else from how fast it leaves the AH between your looks.")
    y = W.Checkbox(parent, y, "tooltipGraph", "Price graph under item tooltips at the Auction House",
        "Lowest price over time, units listed and what you sold, under the tooltip of any item you have seen on the AH.")
    y = W.Checkbox(parent, y, "tooltipGraphAlways", "... everywhere, not only at the Auction House",
        "Also in your bags, the bank, chat links.")
    y = W.Checkbox(parent, y, "ahLookupClick", "Click an item in the Market window: search it on the open Auction House",
        "While the Auction House is open, a click on an item in the Market window searches it there (one search per click).")
    y = W.Checkbox(parent, y, "ahHelper", "Scan panel next to the Auction House",
        "A panel with a full scan (every price at once, every 15 minutes) and a search list (one item per click). Also " .. ns.Cmd.Text("ah") .. " scan.")
    y = W.Button(parent, y, "Open the Auction desk", 190, function() ns.AuctionDeskUI.Show() end,
        "Your listings against the market, deals, crafting margins and what owning an item's market costs. Also " .. ns.Cmd.Text("ah") .. ".")
    y = W.Slider(parent, y, "deskMinProfit", "Auction desk: resets worth showing from", 0, 500000, 2500,
        function(v) return ns.Professions.Money(v) end, "A reset (buy the cheap end, relist under the next seller) shows on the desk from this profit.")
    y = W.Header(parent, y, "Crafting log")
    y = W.Checkbox(parent, y, "craftLogEnabled", "Log my crafts", "Every craft with the skill it gave, the materials it used, when and where.")
    y = W.Button(parent, y, "Open the Crafting tab", 170, function() ns.GearUI.Show("crafting") end, "Also " .. ns.Cmd.Text("crafts") .. ".")
    y = W.Header(parent, y, "Delete")
    y = W.Button(parent, y, "Delete this character's skill log", 240, function()
        StaticPopup_Show(ns.POPUP .. "SKILLS_DELETE", ns.Gear.CharKey() or "?", nil, ns.Gear.CharKey())
    end)
    return -y + 10
end

StaticPopupDialogs[ns.POPUP .. "SKILLS_DELETE"] = {
    text = "Delete the " .. ns.NAME .. " skill log of %s?",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function(self, key)
        if key then db().skills[key] = nil end
        ns.Print("skill log deleted.")
        ready = false
        loginAt = GetTime() - 3
        ns.Refresh()
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

if ns.CharacterTab then
    table.insert(ns.CharacterTab.pages, { label = "Skills", build = BuildPage })
end

local function Slash(command)
    if command ~= "skills" then return false end
    ns.GearUI.Toggle("skills")
    return true
end

ns.RegisterModule("Skills", {
    defaults = { skillsEnabled = true, skills = {} },
    events = { "SKILL_LINES_CHANGED", "CHAT_MSG_SKILL", "PLAYER_ENTERING_WORLD", "PLAYER_LEVEL_UP",
        "SPELLS_CHANGED", "TRADE_SKILL_DETAILS_UPDATE" },
    onEvent = OnEvent,
    tick = Tick,
    slash = Slash,
})
