-- TALOD - Journal: every enemy player you have seen (who, where, when),
-- your kill-on-sight and avoid lists, notes, and how encounters ended when the
-- game lets us tell.
--
-- Without a combat log, outcomes are limited to what is visible: you died
-- while an enemy player was (recently) your target, or your enemy target died.
-- Rows say exactly that; they never claim who landed the killing blow.

local ADDON_NAME, ns = ...
local S = ns.Secret

local Journal = {}
ns.Journal = Journal

local recentRow = {}       -- [key] = row, this session: merges repeat sightings
local lastEnemyTarget      -- { key, t } the last enemy player you targeted
local targetAlive = {}     -- [key] = true while your enemy target is alive
local OUTCOME_WINDOW = 20  -- seconds after untargeting that a death still counts

local function db() return ns.DB() end

-- Windows see the journal through Data (source "journal"); the signature
-- catches a write that forgot Data.Changed.
local function Changed() ns.Data.Changed("journal") end
ns.Data.Source("journal", { sig = function()
    local j = db().journal
    local last = j[#j]
    return #j .. ":" .. tostring(last and (last.t2 or last.t) or 0)
end })

-- A player's counts for one character (pc[character number] = { s seen, k
-- kills, d deaths }); the record's seen / kills / deaths are the account's.
local function Mine(rec)
    local id = ns.Store.Me()
    if not id then return nil end
    rec.pc = rec.pc or {}
    local c = rec.pc[id]
    if not c then
        c = { s = 0, k = 0, d = 0 }
        rec.pc[id] = c
    end
    return c
end

local function Zone()
    local zone = GetZoneText and S.Call(GetZoneText) or nil
    local sub = GetSubZoneText and S.Call(GetSubZoneText) or nil
    local mapID = C_Map and C_Map.GetBestMapForUnit and S.Call(C_Map.GetBestMapForUnit, "player") or nil
    if sub == "" then sub = nil end
    return zone, sub, mapID
end

-- Adds a sighting, or extends the player's last row when it is recent.
function Journal.Record(e, source)
    if not db().journalEnabled or not e.keyed or e.hostile ~= true then return end
    local now = time()
    local rec = ns.PlayerRecord(e.key, true)
    rec.name, rec.realm = e.name or rec.name, e.realm or rec.realm
    rec.class, rec.race = e.classFile or rec.class, e.race or rec.race
    rec.guild = e.guild or rec.guild
    if e.skull then rec.level = -1 elseif e.level then rec.level = e.level end
    rec.firstSeen = rec.firstSeen or now
    rec.lastSeen = now

    local zone, sub, mapID = Zone()
    local row = recentRow[e.key]
    if row and now - (row.t2 or row.t) < (db().journalMergeMinutes or 10) * 60 and row.zone == zone then
        row.t2 = now
        row.level = rec.level
        row.guild = e.guild or row.guild
        if e.flagged then row.flagged = true end
        Changed()
        return row
    end
    row = { key = e.key, t = now, t2 = now, name = e.name, realm = e.realm, class = e.classFile, race = e.race,
        level = rec.level, guild = e.guild, zone = zone, subzone = sub, mapID = mapID, source = source,
        flagged = e.flagged or nil, c = ns.Store.Me() }
    local journal = db().journal
    journal[#journal + 1] = row
    while #journal > (db().journalMax or 5000) do table.remove(journal, 1) end
    recentRow[e.key] = row
    rec.seen = (rec.seen or 0) + 1
    local mine = Mine(rec)
    if mine then mine.s = mine.s + 1 end
    Changed()
    return row
end

-- Marks the player's latest row: "you died" or "they died".
function Journal.SetOutcome(key, outcome)
    local rec = ns.PlayerRecord(key)
    if not rec then return end
    local row = recentRow[key]
    if not row then
        local journal = db().journal
        for i = #journal, 1, -1 do
            if journal[i].key == key then row = journal[i] break end
        end
    end
    if row then row.outcome = outcome end
    local mine = Mine(rec)
    if outcome == "you died" then
        rec.deaths = (rec.deaths or 0) + 1
        if mine then mine.d = mine.d + 1 end
    else
        rec.kills = (rec.kills or 0) + 1
        if mine then mine.k = mine.k + 1 end
    end
    Changed()
end

---------------------------------------------------------------------------
-- Lists and notes
---------------------------------------------------------------------------
-- Resolves "target" or a typed name to a player key and display name.
function Journal.ResolveName(text)
    text = text and text:match("^%s*(.-)%s*$") or ""
    if text == "" or text:lower() == "target" then
        local f = ns.ReadPlayerUnit("target")
        if f and f.key then return f.key, f end
        -- Friendly players can go on a list too (a ganker in your own faction
        -- on a PvP realm is rare, but notes are useful).
        local name, realm = S.CallMulti(2, UnitName, "target")
        if name and S.Call(UnitIsPlayer, "target") then return ns.PlayerKey(name, realm), nil end
        return nil
    end
    -- Typed names: capitalized like the game does ("sHADOW" -> "Shadow"); a
    -- realm after "-" is left as typed. Non-ASCII letters pass unchanged.
    local name, realm = text:match("^([^-]+)%-?(.*)$")
    name = name:sub(1, 1):upper() .. name:sub(2):lower()
    return (realm ~= "" and (name .. "-" .. realm) or name), nil
end

function Journal.SetList(key, list, facts)
    local rec = ns.PlayerRecord(key, true)
    rec.list = list
    rec.listBy = ns.Store.Me()
    if facts then
        rec.name, rec.class, rec.level, rec.guild = facts.name or rec.name, facts.classFile or rec.class,
            facts.skull and -1 or facts.level or rec.level, facts.guild or rec.guild
    end
    rec.name = rec.name or key
    Changed()
end

-- Takes a player off both lists; false when they were on neither.
function Journal.Unlist(key)
    local rec = ns.PlayerRecord(key)
    if not (rec and rec.list) then return false end
    rec.list, rec.listBy = nil, nil
    Changed()
    return true
end

function Journal.SetNote(key, note)
    local rec = ns.PlayerRecord(key, true)
    rec.name = rec.name or key
    rec.note = (note and note ~= "") and note or nil
    rec.noteBy = rec.note and ns.Store.Me() or nil
    Changed()
end

function Journal.ListMembers(list)
    local out = {}
    for key, rec in pairs(db().players) do
        if rec.list == list then out[#out + 1] = key end
    end
    table.sort(out)
    return out
end

---------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------
-- Distinct enemies seen in a zone within `seconds`; returns count and the
-- most recent row.
function Journal.ZoneSummary(zone, seconds)
    local since = time() - (seconds or 86400)
    local seen, count, latest = {}, 0, nil
    local journal = db().journal
    for i = #journal, 1, -1 do
        local row = journal[i]
        if (row.t2 or row.t) < since then break end
        if row.zone == zone and not seen[row.key] then
            seen[row.key] = true
            count = count + 1
            latest = latest or row
        end
    end
    return count, latest
end

function Journal.Stats()
    local players, kos, avoid = 0, 0, 0
    for _, rec in pairs(db().players) do
        players = players + 1
        if rec.list == "kos" then kos = kos + 1 elseif rec.list == "avoid" then avoid = avoid + 1 end
    end
    return #db().journal, players, kos, avoid
end

-- The n most recent rows, newest first.
function Journal.Recent(n)
    local out, journal = {}, db().journal
    for i = #journal, math.max(1, #journal - n + 1), -1 do out[#out + 1] = journal[i] end
    return out
end

-- Sightings per zone (most first): { zone, count }.
function Journal.ByZone()
    local counts = {}
    for _, row in ipairs(db().journal) do
        local zone = row.zone or "?"
        counts[zone] = (counts[zone] or 0) + 1
    end
    local out = {}
    for zone, n in pairs(counts) do out[#out + 1] = { zone = zone, count = n } end
    table.sort(out, function(a, b) return a.count > b.count end)
    return out
end

-- Deletes rows older than `days` (all rows when nil). Player records keep
-- their lists and notes; records with neither and no remaining rows go.
function Journal.Delete(days)
    local journal = db().journal
    local removed = 0
    if days then
        local cutoff = time() - days * 86400
        local kept = {}
        for _, row in ipairs(journal) do
            if (row.t2 or row.t) >= cutoff then kept[#kept + 1] = row else removed = removed + 1 end
        end
        wipe(journal)
        for i, row in ipairs(kept) do journal[i] = row end
    else
        removed = #journal
        wipe(journal)
    end
    wipe(recentRow)
    local present = {}
    for _, row in ipairs(journal) do present[row.key] = true end
    for key, rec in pairs(db().players) do
        if not present[key] and not rec.list and not rec.note then db().players[key] = nil end
    end
    Changed()
    return removed
end

function Journal.Describe(key)
    local rec = ns.PlayerRecord(key)
    if not rec then return key .. ": never seen, not on a list." end
    local level = rec.level == -1 and "??" or tostring(rec.level or "?")
    local parts = { string.format("%s: %s %s", key, level, ns.ClassName(rec.class)) }
    if rec.guild then parts[#parts + 1] = "<" .. rec.guild .. ">" end
    if rec.list then parts[#parts + 1] = "[" .. (rec.list == "kos" and "KoS" or "avoid") .. "]" end
    parts[#parts + 1] = string.format("seen %d×", rec.seen or 0)
    if rec.lastSeen then parts[#parts + 1] = "last " .. ns.FormatAge(time() - rec.lastSeen) .. " ago" end
    if (rec.kills or 0) + (rec.deaths or 0) > 0 then
        parts[#parts + 1] = string.format("they died %d× / you died %d×", rec.kills or 0, rec.deaths or 0)
    end
    if rec.note then parts[#parts + 1] = '"' .. rec.note .. '"' end
    return table.concat(parts, " ")
end

---------------------------------------------------------------------------
-- Outcomes
---------------------------------------------------------------------------
local function CheckTargetDeath()
    local f = ns.ReadPlayerUnit("target")
    if not f or not f.key or f.hostile ~= true then return end
    -- Still targeted: the outcome window keeps running from now.
    if lastEnemyTarget and lastEnemyTarget.key == f.key then
        lastEnemyTarget.t = GetTime()
    else
        lastEnemyTarget = { key = f.key, t = GetTime() }
    end
    if f.dead then
        if targetAlive[f.key] then
            targetAlive[f.key] = nil
            Journal.SetOutcome(f.key, "they died")
        end
    else
        targetAlive[f.key] = true
    end
end

-- Your target dying is noticed by the tick (every 0.25 s): UNIT_HEALTH
-- arrives for every unit in sight, hundreds a second in a battleground.
local function OnEvent(event)
    if event == "PLAYER_TARGET_CHANGED" then
        wipe(targetAlive)
        local f = ns.ReadPlayerUnit("target")
        if f and f.key and f.hostile == true then
            lastEnemyTarget = { key = f.key, t = GetTime() }
            if not f.dead then targetAlive[f.key] = true end
        elseif lastEnemyTarget then
            lastEnemyTarget.t = GetTime()   -- the window starts when you untarget
        end
    elseif event == "PLAYER_DEAD" then
        if lastEnemyTarget and GetTime() - lastEnemyTarget.t <= OUTCOME_WINDOW then
            Journal.SetOutcome(lastEnemyTarget.key, "you died")
            lastEnemyTarget = nil
        end
    end
end

---------------------------------------------------------------------------
-- World > Enemies: the page for the journal, the lists and the census.
-- The Enemies nearby panel stays a floating piece (its rows carry secure
-- target buttons); this page holds no secure button and sends nothing.
---------------------------------------------------------------------------
local Style, Data = ns.Style, ns.Data
local COLORS, HEX = Style.COLORS, Style.HEX

local UI = {}
ns.EnemiesUI = UI

local TABS = { { key = "journal", label = "Journal" }, { key = "lists", label = "Lists" }, { key = "census", label = "Census" } }
local RANGES = { { key = "today", label = "Today" }, { key = "week", label = "7 days" }, { key = "month", label = "30 days" },
    { key = "all", label = "All" } }
local LISTS = { { key = "kos", label = "Kill on sight" }, { key = "avoid", label = "Avoid" } }
local LIST_TAG = { kos = { tag = "Kill on sight", tone = "danger" }, avoid = { tag = "Avoid", tone = "threshold" } }
local PAD, SIDE_W = 12, 286
local VIEWER = "python tools/census_viewer.py"

local frame
local views = {}
local state = { tab = "journal", range = "month", search = "", lists = { kos = true, avoid = true } }
UI.state, UI.views = state, views

-- The census log is Census.lua's; this signature lets the census tab see
-- new points without Census telling anyone.
Data.Source("census", { sig = function()
    local c = db().census
    local p = type(c) == "table" and c.points
    if type(p) ~= "table" then return "0" end
    local last = p[#p]
    return #p .. ":" .. (type(last) == "string" and last:sub(1, 16) or "")
end })

local function Muted(s) return HEX.muted .. tostring(s) .. "|r" end
local function Trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function Bind(key, where)
    if ns.Options and ns.Options.Bind then ns.Options.Bind(key, "quick", where) end
end

-- A level the game showed, a skull, or the unknown tag (never blank, never 0).
local function LevelCell(level)
    if level == -1 then return { tag = "??", tone = "danger", sort = 1000 } end
    if type(level) == "number" then return tostring(level) end
    return ns.UNKNOWN
end

local function NameText(name, class)
    return (class and ns.Hex(ns.ClassColor(class)) or HEX.white) .. tostring(name) .. "|r"
end

-- "Orc Rogue  <Guild>" on a list row; what the game hid reads "? class".
local function FactsText(rec, row)
    local race = (rec and rec.race) or (row and row.race)
    local class = (rec and rec.class) or (row and row.class)
    local guild = (rec and rec.guild) or (row and row.guild)
    local who = class and Muted((race and (race .. " ") or "") .. ns.ClassName(class)) or Style.TagText("class", "unknown")
    return who .. "  " .. (guild and Muted("<" .. guild .. ">") or Style.TagText("guild", "unknown"))
end

local function Matches(rec, key)
    if state.search == "" then return true end
    local name = tostring(rec and rec.name or key):lower()
    return name:find(state.search, 1, true) ~= nil or tostring(key):lower():find(state.search, 1, true) ~= nil
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------
-- p = { key, row (latest sighting in the range), n (sightings), t, lists }.
local function PlayerRow(p)
    local rec = ns.PlayerRecord(p.key)
    local row = p.row
    local name = (rec and rec.name) or (row and row.name) or p.key
    local class = (rec and rec.class) or (row and row.class)
    local level = rec and rec.level
    if level == nil and row then level = row.level end
    local list = rec and rec.list
    local middle
    if p.lists then
        middle = tostring(rec and rec.seen or 0)
    else
        middle = row and (row.subzone or row.zone) or ns.UNKNOWN
    end
    return {
        key = p.key,
        label = p.t and ns.FormatAge(time() - p.t) or Muted("never"),
        text = NameText(name, class) .. "  " .. FactsText(rec, row),
        cols = { list and LIST_TAG[list] or "", middle, LevelCell(level) },
        sort = { [0] = tostring(name):lower(), label = p.t or 0 },
        tooltip = function(owner)
            local lines = { tostring(name), Journal.Describe(p.key) }
            if not p.lists then lines[#lines + 1] = Muted(p.n .. " sightings in this range.") end
            lines[#lines + 1] = Muted("Click: the player card.")
            ns.Tooltip.Text(owner, lines)
        end,
    }
end

-- Players seen in the range, newest first, and the zones you met them in.
local function JournalData(list)
    return Data.List(list, {
        name = "enemies:journal", sources = { "journal" }, key = { state.range, state.search }, maxAge = 60,
        empty = state.search ~= "" and "Nobody by that name in this range. Enter: look the name up."
            or "No enemy players seen in this range.",
        build = function(add)
            local journal = db().journal
            local since = Style.RangeStart(state.range)
            local byKey, order, sightings = {}, {}, 0
            local zones, zoneList = {}, {}
            for i = #journal, 1, -1 do
                Data.Step()
                local row = journal[i]
                local t = row.t2 or row.t or 0
                if since and t < since then break end
                local key = row.key
                if key then
                    local zone = row.zone
                    if zone then
                        local z = zones[zone]
                        if not z then
                            z = { zone = zone, n = 0, kos = 0, seen = {} }
                            zones[zone] = z
                            zoneList[#zoneList + 1] = z
                        end
                        z.n = z.n + 1
                        if not z.seen[key] then
                            z.seen[key] = true
                            if ns.ListOf(key) == "kos" then z.kos = z.kos + 1 end
                        end
                    end
                    local p = byKey[key]
                    if p == nil then
                        if Matches(ns.PlayerRecord(key), key) then
                            p = { key = key, row = row, n = 0, t = t }
                            order[#order + 1] = p
                        else
                            p = false
                        end
                        byKey[key] = p
                    end
                    if p then
                        p.n = p.n + 1
                        sightings = sightings + 1
                    end
                end
            end
            for _, z in ipairs(zoneList) do z.seen = nil end
            table.sort(zoneList, function(a, b) return a.n > b.n end)
            for _, p in ipairs(order) do add(p, { key = p.key, time = p.t }) end
            return { players = #order, sightings = sightings, zones = zoneList }
        end,
        row = PlayerRow,
    })
end

local function ListsData(list)
    return Data.List(list, {
        name = "enemies:lists", sources = { "journal" }, key = { state.lists.kos, state.lists.avoid, state.search }, maxAge = 60,
        empty = state.search ~= "" and "Nobody by that name on these lists. Enter: show the name's card, then list them there."
            or "Nobody on these lists.",
        build = function(add)
            local keys, counts = {}, { kos = 0, avoid = 0 }
            for key, rec in pairs(db().players) do
                local l = rec.list
                if l == "kos" or l == "avoid" then
                    counts[l] = counts[l] + 1
                    if state.lists[l] and Matches(rec, key) then keys[#keys + 1] = key end
                end
            end
            table.sort(keys)
            for _, key in ipairs(keys) do
                local rec = ns.PlayerRecord(key)
                add({ key = key, t = rec.lastSeen, lists = true }, { key = key, time = rec.lastSeen })
            end
            return { players = #keys, counts = counts }
        end,
        row = PlayerRow,
    })
end

-- The zone you meet a player in most, from the journal: "Zone (3 of 5)".
local function Usually(key)
    return Data.Memo("enemies:usually", Data.Key("journal") .. "|" .. key, function()
        local counts, best, total = {}, nil, 0
        for _, row in ipairs(db().journal) do
            if row.key == key and row.zone then
                total = total + 1
                counts[row.zone] = (counts[row.zone] or 0) + 1
                if not best or counts[row.zone] > counts[best] then best = row.zone end
            end
        end
        return best and string.format("%s (%d of %d)", best, counts[best], total) or false
    end)
end

---------------------------------------------------------------------------
-- The player card: what the who command prints, the note, the list buttons
---------------------------------------------------------------------------
local PAIRS = { "Level", "Race and class", "Guild", "Seen", "First, last", "Usually in", "They died", "You died" }
local PAIR_H = 16

local function Times(n) return n .. (n == 1 and " time" or " times") end

local function BuildCard(parent)
    local card = Style.Card(parent, "Player")
    local c = card.content
    card.tag = Style.Tag(card)
    card.tag:SetPoint("RIGHT", card, "TOPRIGHT", -8, -Style.M.cardHeader / 2)
    card.tag:Hide()
    card.empty = Style.Text(c, "body")
    card.empty:SetPoint("TOPLEFT", 6, -6)
    card.empty:SetPoint("RIGHT", -6, 0)
    if card.empty.SetWordWrap then card.empty:SetWordWrap(true) end
    card.empty:SetText(Muted("Click a row, or search a name and press Enter: what the journal knows about that player."))
    card.body = CreateFrame("Frame", nil, c)
    card.body:SetAllPoints()
    local b = card.body
    card.pairs = {}
    for i, label in ipairs(PAIRS) do
        local p = CreateFrame("Frame", nil, b)
        p:SetHeight(PAIR_H)
        p:SetPoint("TOPLEFT", 4, -4 - (i - 1) * PAIR_H)
        p:SetPoint("RIGHT", -4, 0)
        p.label = Style.Text(p, "body")
        p.label:SetPoint("LEFT")
        p.label:SetText(label)
        p.label:SetTextColor(COLORS.t3[1], COLORS.t3[2], COLORS.t3[3])
        p.value = Style.Text(p, "body", "RIGHT")
        p.value:SetPoint("RIGHT")
        p.value:SetPoint("LEFT", p.label, "RIGHT", 8, 0)
        p.tag = Style.Tag(p)
        p.tag:SetPoint("RIGHT")
        p.tag:Hide()
        -- value: text, ns.UNKNOWN (the unknown tag) or { tag, tone }.
        function p:Set(value)
            if value == ns.UNKNOWN or type(value) == "table" then
                local text, tone = "", "unknown"
                if value ~= ns.UNKNOWN then text, tone = value.tag, value.tone end
                self.tag:Set(text, tone)
                self.tag:Show()
                self.value:SetText("")
                self.shown, self.tone = self.tag:GetText(), tone
            else
                self.tag:Hide()
                self.value:SetText(value)
                self.shown, self.tone = value, nil
            end
        end
        card.pairs[label] = p
    end
    local y = -4 - #PAIRS * PAIR_H - 2
    card.outcomeNote = Style.Text(b, "meta")
    card.outcomeNote:SetPoint("TOPLEFT", 4, y)
    card.outcomeNote:SetPoint("RIGHT", -4, 0)
    card.outcomeNote:SetText("Deaths: only what was visible while you had them targeted. Never who killed whom.")
    y = y - 18
    card.noteLabel = Style.Text(b, "label")
    card.noteLabel:SetPoint("TOPLEFT", 4, y)
    card.noteLabel:SetText("Note")
    y = y - 14
    local note = CreateFrame("EditBox", nil, b)
    note:SetHeight(22)
    note:SetPoint("TOPLEFT", 4, y)
    note:SetPoint("RIGHT", -4, 0)
    note:SetAutoFocus(false)
    note:SetFontObject(Style.Font("body"))
    note:SetTextInsets(6, 6, 0, 0)
    if note.SetMaxLetters then note:SetMaxLetters(200) end
    note.bg = Style.Texture(note, "BACKGROUND", COLORS.well)
    note.bg:SetAllPoints()
    Style.Border(note, COLORS.border)
    note.hint = Style.Text(note, "meta")
    note.hint:SetPoint("LEFT", 6, 0)
    note.hint:SetText("Enter saves; empty clears")
    note:SetScript("OnTextChanged", function(self) self.hint:SetShown((self:GetText() or "") == "") end)
    note:SetScript("OnEnterPressed", function(self)
        UI.SaveNote(self:GetText())
        self:ClearFocus()
    end)
    note:SetScript("OnEscapePressed", function(self)
        local rec = state.selected and ns.PlayerRecord(state.selected)
        self:SetText(rec and rec.note or "")
        self:ClearFocus()
    end)
    card.note = note
    y = y - 30
    card.kos = Style.Button(b, "Kill on sight", 96, function() UI.SetList("kos") end,
        "Puts this player on your kill-on-sight list: the loud alert and the badge.", { small = true })
    card.kos:SetPoint("TOPLEFT", 4, y)
    card.avoid = Style.Button(b, "Avoid", 64, function() UI.SetList("avoid") end,
        "Puts this player on your avoid list: a warning badge.", { small = true })
    card.avoid:SetPoint("LEFT", card.kos, "RIGHT", 4, 0)
    card.unlist = Style.Button(b, "Unlist", 64, function() UI.SetList(nil) end,
        "Takes this player off your lists. Sightings and the note stay.", { small = true })
    card.unlist:SetPoint("LEFT", card.avoid, "RIGHT", 4, 0)
    card.height = Style.M.cardHeader + 4 - y + 28
    card:SetHeight(card.height)

    function card:ShowPlayer(key)
        self.key = key
        if not key then
            self.title:SetText("Player")
            self.tag:Hide()
            self.body:Hide()
            self.empty:Show()
            return
        end
        self.empty:Hide()
        self.body:Show()
        local rec = ns.PlayerRecord(key)
        self.title:SetText(NameText(rec and rec.name or key, rec and rec.class))
        local list = rec and rec.list
        if list then self.tag:Set(LIST_TAG[list].tag, LIST_TAG[list].tone) self.tag:Show() else self.tag:Hide() end
        local P = self.pairs
        P["Level"]:Set(LevelCell(rec and rec.level))
        P["Race and class"]:Set(rec and rec.class and ((rec.race and (rec.race .. " ") or "") .. ns.ClassName(rec.class)) or ns.UNKNOWN)
        P["Guild"]:Set(rec and rec.guild and ("<" .. rec.guild .. ">") or ns.UNKNOWN)
        if rec and (rec.seen or 0) > 0 then
            local me = ns.Store.Me()
            local mine = me and rec.pc and rec.pc[me]
            P["Seen"]:Set(Times(rec.seen) .. (mine and Muted(", " .. mine.s .. " on this character") or ""))
        else
            P["Seen"]:Set(Muted("never seen"))
        end
        if rec and rec.firstSeen then
            P["First, last"]:Set(date("%d %b", rec.firstSeen) .. ", "
                .. (rec.lastSeen and (ns.FormatAge(time() - rec.lastSeen) .. " ago") or ns.UnknownText()))
        else
            P["First, last"]:Set(Muted("never seen"))
        end
        P["Usually in"]:Set(Usually(key) or Muted("no zone yet"))
        P["They died"]:Set((rec and (rec.kills or 0) > 0) and Times(rec.kills) or Muted("not seen"))
        P["You died"]:Set((rec and (rec.deaths or 0) > 0) and Times(rec.deaths) or Muted("not seen"))
        -- A redraw while typing would wipe what is being typed.
        if not (self.note.HasFocus and self.note:HasFocus()) then
            self.note:SetText(rec and rec.note or "")
            self.note.hint:SetShown((rec and rec.note or "") == "")
        end
        self.kos:SetOn(list == "kos")
        self.avoid:SetOn(list == "avoid")
        self.unlist:SetEnabled(list ~= nil, "not on a list")
    end
    return card
end

---------------------------------------------------------------------------
-- Journal and Lists: one view; the toolbar and the side column change
---------------------------------------------------------------------------
local ZONE_ROWS = 6

local function BuildZones(parent)
    local card = Style.Card(parent, "Where you meet enemies")
    card.rows = {}
    for i = 1, ZONE_ROWS do
        local r = CreateFrame("Frame", nil, card.content)
        r:SetHeight(18)
        r:SetPoint("TOPLEFT", 4, -2 - (i - 1) * 19)
        r:SetPoint("RIGHT", -4, 0)
        r.zone = Style.Text(r, "body")
        r.zone:SetPoint("LEFT")
        r.zone:SetWidth(120)
        r.kos = Style.Text(r, "meta", "RIGHT")
        r.kos:SetPoint("RIGHT")
        r.kos:SetWidth(44)
        r.n = Style.Text(r, "body", "RIGHT")
        r.n:SetPoint("RIGHT", r.kos, "LEFT", -4, 0)
        r.n:SetWidth(34)
        r.meter = Style.Meter(r, 5)
        r.meter:SetPoint("LEFT", r.zone, "RIGHT", 6, 0)
        r.meter:SetPoint("RIGHT", r.n, "LEFT", -6, 0)
        card.rows[i] = r
    end
    card.none = Style.Text(card.content, "body")
    card.none:SetPoint("TOPLEFT", 6, -6)
    card.none:SetText(Muted("No sightings in this range."))
    function card:Fill(zones)
        local top = zones[1] and zones[1].n or 1
        for i, r in ipairs(self.rows) do
            local z = zones[i]
            r:SetShown(z ~= nil)
            if z then
                r.zone:SetText(z.zone)
                r.n:SetText(tostring(z.n))
                r.meter:SetValue(z.n, top)
                r.kos:SetText(z.kos > 0 and (ns.ColorCode("danger") .. z.kos .. " KoS|r") or "")
            end
        end
        self.none:SetShown(zones[1] == nil)
    end
    return card
end

local function BuildPeople(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    local bar = CreateFrame("Frame", nil, v)
    bar:SetHeight(22)
    bar:SetPoint("TOPLEFT")
    bar:SetPoint("TOPRIGHT")
    v.search = Style.SearchBox(bar, function(text)
        local s = Trim(text):lower()
        if s ~= state.search then
            state.search = s
            UI.Refresh()
        end
    end, "Search any player")
    v.search:SetWidth(210)
    v.search:SetPoint("LEFT")
    v.search:SetScript("OnEnterPressed", function(self)
        local text = Trim(self:GetText())
        if text ~= "" then UI.Select(Journal.ResolveName(text)) end
        self:ClearFocus()
    end)
    v.ranges = Style.Chips(bar, RANGES, function(key)
        state.range = key
        UI.Refresh()
    end)
    v.ranges:SetPoint("LEFT", v.search, "RIGHT", 8, 0)
    v.lists = Style.Chips(bar, LISTS, function(key, on)
        state.lists[key] = on
        UI.Refresh()
    end)
    v.lists:SetPoint("LEFT", v.search, "RIGHT", 8, 0)
    v.count = Style.Text(bar, "body", "RIGHT")
    v.count:SetPoint("RIGHT")
    v.count:SetTextColor(COLORS.t3[1], COLORS.t3[2], COLORS.t3[3])

    local side = CreateFrame("Frame", nil, v)
    side:SetWidth(SIDE_W)
    side:SetPoint("TOPRIGHT", 0, -30)
    side:SetPoint("BOTTOMRIGHT")
    v.side = side
    v.card = BuildCard(side)
    v.zones = BuildZones(side)
    v.zones:SetPoint("TOPLEFT", v.card, "BOTTOMLEFT", 0, -8)
    v.zones:SetPoint("BOTTOMRIGHT")

    v.listCard = Style.Card(v, "Recent sightings")
    v.listCard:SetPoint("TOPLEFT", 0, -30)
    v.listCard:SetPoint("BOTTOMRIGHT", side, "BOTTOMLEFT", -8, 0)
    v.list = Style.List(v.listCard.content, { labelWidth = 44, colWidths = { 84, 118, 30 },
        columns = { name = "Player", label = "Last", "List", "Zone", "Lvl" },
        selected = function(item) return item.key ~= nil and item.key == state.selected end,
        onClick = function(item) if item.key then UI.Select(item.key) end end })

    function v:Refresh()
        local lists = state.tab == "lists"
        self.ranges:SetShown(not lists)
        self.lists:SetShown(lists)
        self.zones:SetShown(not lists)
        self.search.hint:SetText(lists and "Add or find a player by name" or "Search any player")
        local data
        if lists then
            self.lists:SetOn("kos", state.lists.kos)
            self.lists:SetOn("avoid", state.lists.avoid)
            self.listCard.title:SetText("Kill on sight and avoid")
            if self.columns ~= "lists" then
                self.columns = "lists"
                self.list:SetColumns({ name = "Player", label = "Last", "List", "Seen", "Lvl" })
            end
            data = ListsData(self.list)
            self.lists:SetCount("kos", data.counts.kos)
            self.lists:SetCount("avoid", data.counts.avoid)
            self.count:SetText(data.players .. (data.players == 1 and " listed player" or " listed players"))
            self.listCard:SetFoot("Kill on sight: the loud alert and a badge. Avoid: a warning badge. "
                .. ns.Cmd.Text("kos") .. ", " .. ns.Cmd.Text("avoid") .. " and " .. ns.Cmd.Text("unlist") .. " take a name or your target.")
        else
            self.ranges:Select(state.range)
            self.listCard.title:SetText("Recent sightings")
            if self.columns ~= "journal" then
                self.columns = "journal"
                self.list:SetColumns({ name = "Player", label = "Last", "List", "Zone", "Lvl" })
            end
            data = JournalData(self.list)
            self.count:SetText(ns.FormatNumber(data.players) .. " players, " .. ns.FormatNumber(data.sightings) .. " sightings")
            self.listCard:SetFoot("A sighting is one player in one zone; repeats a few minutes apart are merged.")
            self.zones:Fill(data.zones)
        end
        local card, side = self.card, self.side
        card:ClearAllPoints()
        card:SetPoint("TOPLEFT", side, "TOPLEFT")
        card:SetPoint("TOPRIGHT", side, "TOPRIGHT")
        if lists then card:SetPoint("BOTTOM", side, "BOTTOM") else card:SetHeight(card.height) end
        card:ShowPlayer(state.selected)
        self.data = data
    end
    function v:Footer()
        if state.tab == "lists" then
            return "Click a row for the player card. A name on no list: type it, press Enter, then list them on the card."
        end
        return "Click a row for the player card. Any name, even one never seen: type it and press Enter ("
            .. ns.Cmd.Text("who", "<name>") .. " shows the same)."
    end
    return v
end

---------------------------------------------------------------------------
-- Census
---------------------------------------------------------------------------
local function Figure(parent, label)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(150, 52)
    f.bg = Style.Texture(f, "BACKGROUND", COLORS.raise)
    f.bg:SetAllPoints()
    Style.Border(f, COLORS.cardBorder)
    f.label = Style.Text(f, "label")
    f.label:SetPoint("TOPLEFT", 8, -6)
    f.label:SetText(label)
    f.value = Style.Text(f, "figure")
    f.value:SetPoint("TOPLEFT", 8, -19)
    f.sub = Style.Text(f, "meta")
    f.sub:SetPoint("BOTTOMLEFT", 8, 5)
    f.sub:SetPoint("RIGHT", -6, 0)
    return f
end

-- The enemy share of what was counted in a zone. Players whose side the game
-- hid are never counted as your side: the cell is then the unknown tag.
local function ShareCell(z)
    if z.counted <= 0 then return ns.UNKNOWN end
    local pct = math.floor(z.enemy / z.counted * 100 + 0.5)
    if z.hidden > 0 then return { tag = pct .. "% enemy", tone = "unknown" } end
    if z.enemy == 0 then return Muted("your side only") end
    if pct >= 50 then return ns.ColorCode("danger") .. pct .. "% enemy|r" end
    return pct .. "% enemy"
end

local function BuildCensus(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    local bar = CreateFrame("Frame", nil, v)
    bar:SetHeight(22)
    bar:SetPoint("TOPLEFT")
    bar:SetPoint("TOPRIGHT")
    v.switch = Style.Switch(bar, function(on)
        db().censusEnabled = on
        ns.Refresh()
        UI.Refresh()
    end, { "Log players I see", "Every player you see, both factions, with where you stood: what the heat maps are drawn from." })
    v.switch:SetPoint("LEFT", 2, 0)
    Bind("censusEnabled", "enemies/census")
    v.switchLabel = Style.Text(bar, "body")
    v.switchLabel:SetPoint("LEFT", v.switch, "RIGHT", 8, 0)
    v.switchLabel:SetText("Log players I see")
    v.friendlyButton = Style.Button(bar, "Turn on friendly nameplates", 180, function()
        ns.Census.ShowFriendlyPlates()
        UI.Refresh()
    end, "Sets the game's Friendly Player Nameplates option. Out of combat only.", { small = true })
    v.friendlyButton:SetPoint("RIGHT")
    v.friendly = Style.Text(bar, "body", "RIGHT")
    v.friendly:SetPoint("RIGHT", v.friendlyButton, "LEFT", -8, 0)

    v.figures = {}
    for i, label in ipairs({ "Points logged", "Map squares", "Maps", "Your side" }) do
        local f = Figure(v, label)
        f:SetPoint("TOPLEFT", (i - 1) * 158, -30)
        v.figures[i] = f
    end

    local side = CreateFrame("Frame", nil, v)
    side:SetWidth(SIDE_W)
    side:SetPoint("TOPRIGHT", 0, -90)
    side:SetPoint("BOTTOMRIGHT")
    v.maps = Style.Card(side, "Heat maps")
    v.maps:SetAllPoints()
    local text = Style.Text(v.maps.content, "body")
    text:SetPoint("TOPLEFT", 4, -4)
    text:SetPoint("RIGHT", -4, 0)
    if text.SetWordWrap then text:SetWordWrap(true) end
    text:SetText("Logs every player you see, enemies and allies, with where you were, the distance, their class, race, "
        .. "level and guild, and the time. Their own position is never read: a point is where you stood, within "
        .. "nameplate range (~41 yd).\n\nThe maps are drawn outside the game from your saved data: log out or /reload so "
        .. "the file is written, then run " .. HEX.white .. VIEWER .. "|r in the addon folder.")
    v.mapsText = text
    v.copy = ns.Utils.CopyButton(v.maps.content, "Copy command", 110, VIEWER, "command")
    v.copy:SetPoint("BOTTOMLEFT", 4, 4)

    v.zoneCard = Style.Card(v, "By zone")
    v.zoneCard:SetPoint("TOPLEFT", 0, -90)
    v.zoneCard:SetPoint("BOTTOMRIGHT", side, "BOTTOMLEFT", -8, 0)
    v.zoneCard.sub:SetText("once per player per map square per visit, kept for good")
    v.list = Style.List(v.zoneCard.content, { colWidths = { 60, 110, 70 },
        columns = { name = "Zone", "Squares", "Enemy share", "Counted" } })

    function v:Refresh()
        local d = db()
        local C = ns.Census
        self.switch:SetOn(d.censusEnabled)
        local plates = C.FriendlyPlatesOn()
        -- Shown only while it would change something.
        self.friendlyButton:SetShown(not plates)
        self.friendly:SetText(plates and Muted("Friendly nameplates on: allies are logged from their plates.")
            or Muted("Friendly nameplates off: allies only from your target and mouseover."))
        local points, cells, maps = C.Stats()
        local F = self.figures
        F[1].value:SetText(ns.FormatNumber(points))
        F[1].sub:SetText("of " .. ns.FormatNumber(d.censusMaxPoints or 0) .. " kept")
        F[2].value:SetText(ns.FormatNumber(cells))
        F[2].sub:SetText("summary, kept for good")
        F[3].value:SetText(ns.FormatNumber(maps))
        F[3].sub:SetText("zones and cities")
        F[4].value:SetText(d.censusAllies and "logged" or "not logged")
        F[4].sub:SetText(d.censusEnabled and "census on" or "census off")
        self.data = Data.List(self.list, {
            name = "enemies:census", sources = { "census" }, key = "zones", maxAge = 30,
            empty = "Nothing counted yet.",
            build = function(add)
                local zones = C.Zones and C.Zones() or {}
                for _, z in ipairs(zones) do add(z) end
                return { zones = #zones }
            end,
            row = function(z)
                return {
                    text = z.name,
                    cols = { tostring(z.squares), ShareCell(z), ns.FormatNumber(z.counted) },
                    sort = { [3] = z.counted, [1] = z.squares },
                    tooltip = function(owner)
                        ns.Tooltip.Text(owner, { z.name, z.counted .. " counted: " .. z.enemy .. " enemy, " .. z.hidden
                            .. " whose side the game hid, the rest your side.", Muted(z.squares .. " map squares.") })
                    end,
                }
            end,
        })
        self.zoneCard:SetFoot(C.StatusLine())
    end
    function v:Footer()
        return "What the census logs and how much it keeps: Settings > Enemies (the gear). Deleting it: Settings > Data."
    end
    return v
end

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------
-- Live enemies by what the game showed: hostile, and hidden hostility.
local function Nearby()
    local known, hidden = 0, 0
    for _, e in pairs(ns.Spotter and ns.Spotter.nearby or {}) do
        if e.unit then
            if e.hostile == true then known = known + 1 elseif e.hostile == nil then hidden = hidden + 1 end
        end
    end
    return known, hidden
end

-- { text, tone } for Home and the rail. A count never reads 0 while the
-- game hides who is hostile: then it is "?".
function UI.PageStatus()
    local known, hidden = Nearby()
    local rows = db() and db().journal and #db().journal or 0
    local tail = ", " .. ns.FormatNumber(rows) .. " sightings"
    if known > 0 then
        return { text = known .. " nearby" .. (hidden > 0 and " + ? hidden" or "") .. tail, tone = "danger" }
    end
    if hidden > 0 then return { text = "? nearby" .. tail, tone = "unknown" } end
    return { text = "none nearby" .. tail, tone = nil }
end

local function UpdateStatus()
    if not frame then return end
    local s = UI.PageStatus()
    frame:SetStatus(s.tone and Style.TagText(s.text, s.tone) or Muted(s.text))
end

local function UpdateHeader()
    local d = db()
    local b = frame.buttons
    b.panel:SetLabel(d.panelShown and "Panel shown" or "Panel hidden")
    b.panel:SetOn(d.panelShown)
    b.alerts:SetLabel(d.alertsEnabled and "Alerts on" or "Alerts muted")
    b.alerts:SetOn(d.alertsEnabled)
end

local function Build()
    frame = Style.Window(ns.FRAME .. "EnemiesWindow", "Enemies", nil, nil, { nav = "enemies", settings = "enemies", section = "World" })
    local top = (Style.M.titleBar or 38) + 6
    local Main = function() return ns.Main end
    local buttons = {}
    frame.buttons = buttons
    -- Placed right to left.
    buttons.remove = frame.header:Add(Style.Button(frame, "Remove", 58, function() Main().ListCommand("unlist", "target") end,
        "Takes your target off your lists.", { small = true }))
    buttons.avoid = frame.header:Add(Style.Button(frame, "Avoid", 50, function() Main().ListCommand("avoid", "target") end,
        "Puts your target on the avoid list.", { small = true }))
    buttons.kos = frame.header:Add(Style.Button(frame, "Target: kill on sight", 118, function() Main().ListCommand("kos", "target") end,
        "Puts your target on the kill-on-sight list.", { small = true }))
    buttons.clear = frame.header:Add(Style.Button(frame, "Clear nearby", 80, function()
        Main().Run("clear", "")
        UpdateStatus()
    end, "Empties the Enemies nearby list; players still in view come back.", { small = true }))
    buttons.alerts = frame.header:Add(Style.Button(frame, "Alerts on", 76, function()
        db().alertsEnabled = not db().alertsEnabled
        ns.Refresh()
        UpdateHeader()
    end, "Enemy spotted alerts: on, or muted.", { small = true }))
    buttons.panel = frame.header:Add(Style.Button(frame, "Panel shown", 84, function()
        db().panelShown = not db().panelShown
        ns.Refresh()
        UpdateHeader()
    end, "The Enemies nearby panel: shown, or hidden.", { small = true }))
    Bind("panelShown", "enemies")
    Bind("alertsEnabled", "enemies")

    local tabHolder = CreateFrame("Frame", nil, frame)
    tabHolder:SetPoint("TOPLEFT", PAD, -top)
    tabHolder:SetPoint("TOPRIGHT", -PAD, -top)
    tabHolder:SetHeight(26)
    frame.tabs = Style.Tabs(tabHolder, TABS, function(key) UI.ShowPage(key) end)
    local line = Style.HLine(frame)
    line:SetPoint("TOPLEFT", PAD, -(top + 26))
    line:SetPoint("TOPRIGHT", -PAD, -(top + 26))

    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", PAD, -(top + 34))
    body:SetPoint("BOTTOMRIGHT", -PAD, 30)
    views.people = BuildPeople(body)
    views.census = BuildCensus(body)
    frame.footer = Style.Text(frame, "meta")
    frame.footer:SetPoint("BOTTOMLEFT", PAD + 2, 11)
    frame.footer:SetPoint("RIGHT", -PAD, 0)
    frame:HookScript("OnShow", function() UI.Refresh() end)
end

function UI.Refresh()
    if not frame or not frame:IsShown() then return end
    frame.tabs:Select(state.tab)
    local v = state.tab == "census" and views.census or views.people
    views.people:SetShown(v == views.people)
    views.census:SetShown(v == views.census)
    v:Refresh()
    frame.footer:SetText(v:Footer() or "")
    UpdateHeader()
    UpdateStatus()
end

local TAB_KEYS = { journal = "journal", lists = "lists", census = "census" }
local LIST_VIEWS = { kos = "kos", ["kill on sight"] = "kos", avoid = "avoid" }

-- The page contract (Navigation): tab "journal" | "lists" | "census" (also
-- "enemies/lists" or the label); view on Lists: "kos" / "avoid" shows that
-- list only; arg: a player key to show on the card.
function UI.ShowPage(tab, view, arg)
    if not frame then Build() end
    tab = tab and tostring(tab):lower():gsub("^enemies/", "")
    if tab and TAB_KEYS[tab] then state.tab = TAB_KEYS[tab] end
    local only = view and LIST_VIEWS[tostring(view):lower()]
    if only and state.tab == "lists" then
        state.lists.kos, state.lists.avoid = only == "kos", only == "avoid"
    end
    if type(arg) == "string" and arg ~= "" then state.selected = arg end
    if frame:IsShown() then UI.Refresh() else frame:Show() end
    return true
end

function UI.Show(tab) return UI.ShowPage(tab) end
function UI.Toggle(tab)
    if frame and frame:IsShown() and (not tab or tab == state.tab) then frame:Hide() else UI.ShowPage(tab) end
end
function UI.IsShown() return frame ~= nil and frame:IsShown() end
function UI.Frame() return frame end

-- The player on the card (a key, or nil to clear it).
function UI.Select(key)
    state.selected = key
    if state.tab == "census" then state.tab = "journal" end
    UI.Refresh()
end

function UI.SaveNote(text)
    local key = state.selected
    if not key then return end
    Journal.SetNote(key, Trim(text))
    UI.Refresh()
end

-- list: "kos", "avoid", or nil (off both lists).
function UI.SetList(list)
    local key = state.selected
    if not key then return end
    if list then Journal.SetList(key, list) else Journal.Unlist(key) end
    ns.Refresh()
    UI.Refresh()
end

Data.Window(UI, { "journal", "census" }, {
    shows = function(src) return (src == "census") == (state.tab == "census") end,
})

-- The nearby count in the title bar follows the panel's list.
local StatusSoon = Data.Coalesce(function() if UI.IsShown() then UpdateStatus() end end, 1)
UI.StatusSoon = StatusSoon

ns.RegisterModule("Journal", {
    events = { "PLAYER_TARGET_CHANGED", "PLAYER_DEAD" },
    onEvent = OnEvent,
    tick = CheckTargetDeath,
    -- Settings and commands change what the page shows (panel, alerts, census).
    refresh = function() if UI.IsShown() then UI.Refresh() end end,
    init = function()
        ns.Spotter.On("spotted", function(e, source, isNew)
            if isNew or recentRow[e.key] then Journal.Record(e, source) end
            UI.StatusSoon()
        end)
        ns.Spotter.On("vanished", UI.StatusSoon)
        ns.Spotter.On("removed", UI.StatusSoon)
    end,
})
