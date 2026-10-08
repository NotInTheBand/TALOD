-- TALOD - Groups: every party and raid you were in, one record per group.
--
-- A session starts when you join a group and ends when you are on your own
-- again (SOLO_CONFIRM seconds, so a loading screen or a quick re-invite does
-- not split it). A party that becomes a raid stays one session, marked raid
-- from then on. After a /reload or a relog within RESUME seconds, still in a
-- group, the open session goes on; otherwise it ends at the last time it was
-- seen.
--
-- Per session: when, how long, where (time per zone, instances), who led,
-- every member (what the game shows of them while grouped: class, race,
-- level at join and last, guild and guild rank, role, raid subgroup and
-- rank, highest health and power seen, time grouped with you, time offline
-- and AFK, deaths seen), joins / leaves / deaths in order, group chat, and
-- loot from the loot messages.
--
-- Unknown stays unknown: a member whose name the game hides is not recorded
-- (counted in `hidden`), a hidden chat line counts in `chatHidden`, a hidden
-- value is left out, never stored as 0. Deaths count only when the member was
-- seen alive and then dead.
--
-- Unit reads are spread over ticks (PASS_READS per tick, a pass at most once
-- a second): a 40-player raid read in one frame is a visible hitch.
--
-- Saved data: TALODDB.groups = { n (last id), cur = the open session, list =
-- closed sessions (oldest first) }. Session = { id, c, kind = "party" /
-- "raid", bg (a battleground), raidAt, start, last, stop, size (most members),
-- leader, zone, zones = { [zone] = seconds }, zl = { zones in the order first
-- seen }, zi = { [zone] = instance type }, m, names (closed: every member's
-- name, for search), ev = { "t|kind|who" }, chat = { "t|who|channel|text" },
-- chatHidden, chatDrop, loot = { "t|who|link|count" }, deaths, hidden }.
-- m: open session { [Name-Realm] = member }; closed { packed member strings }
-- (MEMBER_FIELDS, Store.PackList with "|"; read with Groups.Members).

local ADDON_NAME, ns = ...
local S = ns.Secret

local Groups = {}
ns.Groups = Groups

local STEP = 1                 -- seconds between passes over the group
local PASS_READS = 10          -- units read per tick
local GAP = 30                 -- a longer gap between reads (loading, a freeze) is not counted as time
local SOLO_CONFIRM = 5         -- seconds out of a group before the session ends
local RESUME = 15 * 60         -- an open session goes on after a reload / relog this soon
local LOGIN_GRACE = 10         -- seconds after login before "not in a group" ends a session
local MIN_KEEP = 60            -- shorter sessions with no chat are not kept (a stray invite)
local MAX_SESSIONS = 500
local MAX_CHAT = 1000          -- lines per session (the oldest go first; counted in chatDrop)
local MAX_EVENTS = 600
local MAX_LOOT = 400

Groups.MAX_CHAT = MAX_CHAT

local function db() return ns.DB() end

local function Store()
    local d = db().groups
    if type(d) ~= "table" then
        d = { n = 0, list = {} }
        db().groups = d
    end
    d.list = d.list or {}
    d.n = d.n or 0
    return d
end
Groups.Store = Store

local function Changed() ns.Data.Changed("groups") end

---------------------------------------------------------------------------
-- Packed records
---------------------------------------------------------------------------
local MEMBER_FIELDS = { "key", "cls", "race", "lvl0", "lvl", "g", "gr", "role", "sub", "lead", "ml",
    "join", "left", "secs", "off", "afk", "dead", "hp", "pw", "pwm", "zone" }
Groups.MEMBER_FIELDS = MEMBER_FIELDS

local function PackMember(m)
    local values = {}
    for i, f in ipairs(MEMBER_FIELDS) do values[i] = m[f] end
    return ns.Store.PackList(values, #MEMBER_FIELDS, "|")
end

local function UnpackMember(s)
    local raw = ns.Store.SplitList(s, "|")
    local m = {}
    for i, f in ipairs(MEMBER_FIELDS) do m[f] = raw[i] and ns.Store.UnpackValue(raw[i]) or nil end
    return m
end
Groups.PackMember, Groups.UnpackMember = PackMember, UnpackMember

local function Pack(...)
    local n = select("#", ...)
    return ns.Store.PackList({ ... }, n, "|")
end

local function Unpack(s)
    local out = {}
    for i, raw in ipairs(ns.Store.SplitList(s, "|")) do out[i] = ns.Store.UnpackValue(raw) end
    return out
end

local function Push(list, value, max)
    list[#list + 1] = value
    local over = #list - max
    if over > 0 then
        for _ = 1, over do table.remove(list, 1) end
    end
    return over > 0 and over or 0
end

---------------------------------------------------------------------------
-- Names
---------------------------------------------------------------------------
-- Members are keyed the server's way ("Name-Realm"; "First Surname-Realm" on
-- Forever), as the guild and audit records are, so one player is one key.
local function UnitKey(unit)
    local name, realm = S.CallMulti(2, UnitName, unit)
    if type(name) ~= "string" or name == "" or name == (UNKNOWNOBJECT or "Unknown") then return nil end
    return ns.Guild.FullName(name, realm)
end

local function ChatKey(sender)
    if type(sender) ~= "string" or sender == "" then return nil end
    return ns.Guild.FromFull(sender)
end

function Groups.Short(key) return ns.Guild.Short(key) end

---------------------------------------------------------------------------
-- Sessions
---------------------------------------------------------------------------
local live = {}                -- [key] = { at = GetTime() of the last read, dead = last known, unit }
local pass                     -- { units, i, seen } a walk over the group in progress
local passAt = -math.huge
local soloAt                   -- GetTime() the group was first seen gone
local loginAt                  -- GetTime() at init
local resumed = false          -- the open session from the saved data was checked
local lastStep

function Groups.Current() return db() and Store().cur or nil end

local function Event(s, kind, who)
    s.ev = s.ev or {}
    Push(s.ev, Pack(time(), kind, who), MAX_EVENTS)
end

local function Open(kind)
    local d = Store()
    d.n = d.n + 1
    local now = time()
    local s = { id = d.n, c = ns.Store.Me(), kind = kind, start = now, last = now, size = 1, m = {}, zones = {}, zl = {},
        ev = {}, chat = {}, loot = {}, deaths = 0 }
    if kind == "raid" then s.raidAt = now end
    d.cur = s
    live, pass = {}, nil
    Changed()
    return s
end

-- Every member's name in one string: the session lists search it without unpacking.
local function NameList(s)
    local names = {}
    for key in pairs(s.m) do names[#names + 1] = Groups.Short(key) end
    table.sort(names)
    return table.concat(names, " ")
end

local function Close(s, stop)
    local d = Store()
    if d.cur == s then d.cur = nil end
    live, pass, soloAt = {}, nil, nil
    s.stop = stop or s.last or time()
    for _, m in pairs(s.m) do
        if not m.left then m.left = s.stop end
    end
    if s.stop - s.start < MIN_KEEP and #(s.chat or {}) == 0 then
        Changed()
        return nil
    end
    s.names = NameList(s)
    local packed = {}
    for key, m in pairs(s.m) do
        m.here, m.key = nil, key
        local p = PackMember(m)
        if p then packed[#packed + 1] = p end
    end
    s.m, s.packed = packed, true
    if #s.ev == 0 then s.ev = nil end
    if #s.chat == 0 then s.chat = nil end
    if #s.loot == 0 then s.loot = nil end
    Push(d.list, s, MAX_SESSIONS)
    Changed()
    return s
end
Groups.Close = Close

-- Ends the open session now (tests, the window's End button).
function Groups.End()
    local s = Groups.Current()
    if s then return Close(s, time()) end
end

---------------------------------------------------------------------------
-- Reading the group
---------------------------------------------------------------------------
local function Units(kind, size)
    local out = {}
    if kind == "raid" then
        for i = 1, math.min(size or 0, 40) do out[#out + 1] = { "raid" .. i, i } end
    else
        for i = 1, math.min(math.max((size or 1) - 1, 0), 4) do out[#out + 1] = { "party" .. i } end
    end
    return out
end

local function Num(v) return type(v) == "number" and v == v end

local function ReadMember(s, unit, raidIndex, now, clock)
    local exists = S.Call(UnitExists, unit)
    if not exists then return nil end
    if S.Call(UnitIsUnit, unit, "player") then return nil end
    local key = UnitKey(unit)
    if not key then
        s.hidden = (s.hidden or 0) + 1
        return nil
    end
    local m = s.m[key]
    if not m then
        m = { join = now, secs = 0 }
        s.m[key] = m
        if now - s.start > STEP * 3 then Event(s, "join", key) end
    elseif not m.here and m.left then
        m.left = nil
        Event(s, "back", key)
    end
    m.here = true
    local l = live[key]
    if not l then l = {} live[key] = l end
    local dt = l.at and math.min(clock - l.at, GAP) or 0
    if dt < 0 then dt = 0 end
    l.at, l.unit = clock, unit

    local _, classFile = S.CallMulti(2, UnitClass, unit)
    if type(classFile) == "string" then m.cls = classFile end
    local race = S.CallMulti(1, UnitRace, unit)
    if type(race) == "string" then m.race = race end
    local level = S.Call(UnitLevel, unit)
    if Num(level) and level > 0 then
        m.lvl = level
        m.lvl0 = m.lvl0 or level
    end
    if GetGuildInfo then
        local guild, rankName = S.CallMulti(2, GetGuildInfo, unit)
        if type(guild) == "string" and guild ~= "" then m.g, m.gr = guild, type(rankName) == "string" and rankName or m.gr end
    end
    local hpMax = S.Call(UnitHealthMax, unit)
    if Num(hpMax) and hpMax > (m.hp or 0) then m.hp = hpMax end
    local _, token = S.CallMulti(2, UnitPowerType, unit)
    if type(token) == "string" then m.pw = token end
    local pMax = S.Call(UnitPowerMax, unit)
    if Num(pMax) and pMax > (m.pwm or 0) then m.pwm = pMax end
    if UnitGroupRolesAssigned then
        local role = S.Call(UnitGroupRolesAssigned, unit)
        if type(role) == "string" and role ~= "NONE" and role ~= "" then m.role = role end
    end

    local zone
    if raidIndex and GetRaidRosterInfo then
        local _, rank, subgroup, _, _, _, rzone, _, _, raidRole, isML = S.CallMulti(11, GetRaidRosterInfo, raidIndex)
        if Num(subgroup) then m.sub = subgroup end
        if Num(rank) then m.lead = rank > 0 and rank or nil end
        if type(rzone) == "string" and rzone ~= "" then zone = rzone end
        if type(raidRole) == "string" and raidRole ~= "" and not m.role then m.role = raidRole:upper() end
        if isML == true then m.ml = true end
    else
        if UnitIsGroupLeader and S.Call(UnitIsGroupLeader, unit) == true then m.lead = 2
        elseif UnitIsGroupAssistant and S.Call(UnitIsGroupAssistant, unit) == true then m.lead = 1
        else m.lead = nil end
    end
    if zone then m.zone = zone end
    if m.lead == 2 then s.leader = key end

    m.secs = (m.secs or 0) + dt
    local connected, hidden = S.Call(UnitIsConnected, unit)
    if connected == false and not hidden then m.off = (m.off or 0) + dt end
    if UnitIsAFK and S.Call(UnitIsAFK, unit) == true then m.afk = (m.afk or 0) + dt end
    local dead, deadHidden = S.Call(UnitIsDeadOrGhost, unit)
    if not deadHidden and connected ~= false then
        dead = dead == true
        if dead and l.dead == false then
            m.dead = (m.dead or 0) + 1
            s.deaths = (s.deaths or 0) + 1
            Event(s, "died", key)
        end
        l.dead = dead
    else
        l.dead = nil
    end
    return key
end

-- Members not seen in a whole pass have left.
local function FinishPass(s, seen)
    local now = time()
    for key, m in pairs(s.m) do
        if m.here and not seen[key] then
            m.here, m.left = nil, now
            live[key] = nil
            Event(s, "left", key)
        end
    end
    ns.Data.Changed("groups.live")
end

local function ReadZone(s, dt)
    local zone = (GetRealZoneText and S.Call(GetRealZoneText)) or (GetZoneText and S.Call(GetZoneText))
    if type(zone) ~= "string" or zone == "" then return end
    if not s.zones[zone] then
        s.zones[zone] = 0
        s.zl[#s.zl + 1] = zone
    end
    s.zones[zone] = s.zones[zone] + dt
    if s.zone ~= zone then
        s.zone = zone
        if #s.zl > 1 then Event(s, "zone", zone) end
    end
    if GetInstanceInfo then
        local _, instanceType = S.CallMulti(2, GetInstanceInfo)
        if type(instanceType) == "string" and instanceType ~= "none" and instanceType ~= "" then
            s.zi = s.zi or {}
            s.zi[zone] = instanceType
            if instanceType == "pvp" then s.bg = true end
        end
    end
end

local function Step()
    local d = db()
    if not d then return end
    local clock = GetTime()
    local kind, size = ns.GroupState()
    local g = Store()
    local s = g.cur

    if not d.groupsLog then
        if s then Close(s, s.last) end
        return
    end

    if kind == "solo" then
        if not s then return end
        soloAt = soloAt or clock
        local graceOver = not loginAt or clock - loginAt >= LOGIN_GRACE
        if graceOver and clock - soloAt >= SOLO_CONFIRM then Close(s, s.last) end
        return
    end
    soloAt = nil

    local now = time()
    if s and not resumed then
        resumed = true
        if now - (s.last or s.start) > RESUME then
            Close(s, s.last)
            s = nil
        else
            for _, m in pairs(s.m) do m.here = nil end
        end
    end
    resumed = true
    if not s then s = Open(kind) end
    if kind == "raid" and s.kind ~= "raid" then
        s.kind, s.raidAt = "raid", now
        Event(s, "raid", nil)
    end
    if (size or 0) > (s.size or 0) then s.size = size end
    if S.Call(UnitIsGroupLeader, "player") == true then s.leader = ns.Guild.Me() end

    local dt = lastStep and math.min(clock - lastStep, GAP) or 0
    lastStep = clock
    if dt > 0 then ReadZone(s, dt) end
    s.last = now

    if not pass and clock - passAt >= STEP then
        passAt = clock
        pass = { units = Units(kind, size), i = 1, seen = {} }
    end
    if pass then
        local reads = 0
        while pass.i <= #pass.units and reads < PASS_READS do
            local u = pass.units[pass.i]
            pass.i = pass.i + 1
            reads = reads + 1
            local key = ReadMember(s, u[1], u[2], now, clock)
            if key then pass.seen[key] = true end
        end
        if pass.i > #pass.units then
            FinishPass(s, pass.seen)
            pass = nil
        end
    end
end
Groups.Step = Step

-- The unit token of a member of the open session (for live reads), or nil.
function Groups.UnitOf(key)
    local l = live[key]
    if not l or not l.unit then return nil end
    if UnitKey(l.unit) ~= key then return nil end
    return l.unit
end

---------------------------------------------------------------------------
-- Chat and loot
---------------------------------------------------------------------------
local CHANNELS = {
    CHAT_MSG_PARTY = "p", CHAT_MSG_PARTY_LEADER = "P",
    CHAT_MSG_RAID = "r", CHAT_MSG_RAID_LEADER = "R", CHAT_MSG_RAID_WARNING = "w",
    CHAT_MSG_INSTANCE_CHAT = "i", CHAT_MSG_INSTANCE_CHAT_LEADER = "I",
    CHAT_MSG_BATTLEGROUND = "i", CHAT_MSG_BATTLEGROUND_LEADER = "I",
}
Groups.CHANNEL_NAMES = { p = "Party", P = "Party leader", r = "Raid", R = "Raid leader", w = "Raid warning",
    i = "Instance", I = "Instance leader" }

-- The open session, opened now when you are in a group (a line can come
-- before the first tick of a new group).
local function Ensure()
    local s = Groups.Current()
    if s or not db().groupsLog then return s end
    local kind = ns.GroupState()
    if kind == "solo" then return nil end
    resumed = true
    return Open(kind)
end

function Groups.NoteChat(event, text, sender)
    local ch = CHANNELS[event]
    if not ch or not db().groupsChat then return false end
    local s = Ensure()
    if not s then return false end
    text, sender = S.Value(text), S.Value(sender)
    local who = type(text) == "string" and ChatKey(sender)
    if not who then
        s.chatHidden = (s.chatHidden or 0) + 1
        return false
    end
    s.chat = s.chat or {}
    local dropped = Push(s.chat, Pack(time(), who, ch, text), MAX_CHAT)
    if dropped > 0 then s.chatDrop = (s.chatDrop or 0) + dropped end
    Changed()
    return true
end

-- The game's loot lines as patterns: "%s receives loot: %s." -> "^(.+) receives loot: (.+)%.$".
local function Pattern(format)
    if type(format) ~= "string" then return nil end
    local p = format:gsub("([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
    p = p:gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")
    return "^" .. p .. "$"
end

local lootPatterns
local function LootPatterns()
    if not lootPatterns then
        lootPatterns = {}
        local function Add(format, self, multiple)
            local p = Pattern(format)
            if p then lootPatterns[#lootPatterns + 1] = { p, self, multiple } end
        end
        -- Longest first: "x%d" must match before the plain form takes it.
        Add(LOOT_ITEM_MULTIPLE or "%s receives loot: %sx%d.", false, true)
        Add(LOOT_ITEM_SELF_MULTIPLE or "You receive loot: %sx%d.", true, true)
        Add(LOOT_ITEM or "%s receives loot: %s.", false, false)
        Add(LOOT_ITEM_SELF or "You receive loot: %s.", true, false)
    end
    return lootPatterns
end

-- Item quality from the link's color (0 poor ... 5 legendary), nil when unknown.
local QUALITY_COLORS = { ff9d9d9d = 0, ffffffff = 1, ff1eff00 = 2, ff0070dd = 3, ffa335ee = 4, ffff8000 = 5 }
function Groups.LinkQuality(link)
    local hex = type(link) == "string" and link:match("|c(%x%x%x%x%x%x%x%x)")
    return hex and QUALITY_COLORS[hex:lower()] or nil
end

function Groups.NoteLoot(text)
    if not db().groupsLoot then return false end
    local s = Groups.Current()
    text = S.Value(text)
    if not s or type(text) ~= "string" then return false end
    for _, p in ipairs(LootPatterns()) do
        local a, b, c = text:match(p[1])
        if a then
            local who, link, count
            if p[2] then who, link, count = ns.Guild.Me(), a, p[3] and tonumber(b) or 1
            else who, link, count = ChatKey(a), b, p[3] and tonumber(c) or 1 end
            local q = Groups.LinkQuality(link)
            if q and q < (tonumber(db().groupsLootQuality) or 2) then return false end
            if not who or not link then return false end
            s.loot = s.loot or {}
            Push(s.loot, Pack(time(), who, link, count), MAX_LOOT)
            Changed()
            return true
        end
    end
    return false
end

---------------------------------------------------------------------------
-- Reading sessions
---------------------------------------------------------------------------
function Groups.ById(id)
    local d = Store()
    if d.cur and d.cur.id == id then return d.cur end
    for i = #d.list, 1, -1 do
        if d.list[i].id == id then return d.list[i] end
    end
end

-- Sessions of a kind ("party", "raid", nil = all), newest first, the open one first.
function Groups.Sessions(kind)
    local d = Store()
    local out = {}
    if d.cur and (not kind or d.cur.kind == kind) then out[1] = d.cur end
    for i = #d.list, 1, -1 do
        local s = d.list[i]
        if not kind or s.kind == kind then out[#out + 1] = s end
    end
    return out
end

function Groups.Duration(s) return math.max(0, (s.stop or s.last or time()) - s.start) end
function Groups.IsOpen(s) return s ~= nil and s == Groups.Current() end

local function Decode(s, field, name)
    local list = s[field]
    if not list or #list == 0 then return {} end
    local key = s.id .. ":" .. #list .. ":" .. tostring(list[#list])
    return ns.Data.Memo("groups:" .. name .. ":" .. s.id, key, function()
        local out = {}
        for i, raw in ipairs(list) do out[i] = Unpack(raw) end
        return out
    end, 300)
end

-- Members as tables, most time together first. Shared: callers never change them.
function Groups.Members(s)
    if not s then return {} end
    if not s.packed then
        local out = {}
        for key, m in pairs(s.m) do
            local copy = { key = key }
            for k, v in pairs(m) do copy[k] = v end
            out[#out + 1] = copy
        end
        table.sort(out, function(a, b)
            if (a.secs or 0) ~= (b.secs or 0) then return (a.secs or 0) > (b.secs or 0) end
            return a.key < b.key
        end)
        return out
    end
    return ns.Data.Memo("groups:members:" .. s.id, s.id .. ":" .. #s.m, function()
        local out = {}
        for _, raw in ipairs(s.m) do out[#out + 1] = UnpackMember(raw) end
        table.sort(out, function(a, b)
            if (a.secs or 0) ~= (b.secs or 0) then return (a.secs or 0) > (b.secs or 0) end
            return (a.key or "") < (b.key or "")
        end)
        return out
    end, 300)
end

function Groups.MemberCount(s)
    if not s then return 0 end
    if s.packed then return #s.m end
    local n = 0
    for _ in pairs(s.m) do n = n + 1 end
    return n
end

-- { t, who, channel, text } oldest first.
function Groups.Chat(s) return Decode(s, "chat", "chat") end
-- { t, who, link, count } oldest first.
function Groups.Loot(s) return Decode(s, "loot", "loot") end
-- { t, kind (join / back / left / died / raid / zone), who or zone } oldest first.
function Groups.Events(s) return Decode(s, "ev", "ev") end

-- What the session lists search: every member's name and every zone.
function Groups.SearchText(s)
    local names = s.names or NameList(s)
    return names .. " " .. table.concat(s.zl or {}, " ")
end

-- Zones by time spent, most first: { { zone, seconds, instance type } }.
function Groups.Zones(s)
    local out = {}
    for zone, secs in pairs(s.zones or {}) do out[#out + 1] = { zone, secs, s.zi and s.zi[zone] } end
    table.sort(out, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
    return out
end

-- Every session a player was in, newest first.
function Groups.With(key)
    local short = Groups.Short(key):lower()
    local out = {}
    for _, s in ipairs(Groups.Sessions()) do
        local hay = (s.names or NameList(s)):lower()
        if (" " .. hay .. " "):find(" " .. short .. " ", 1, true) then out[#out + 1] = s end
    end
    return out
end

function Groups.Delete(id)
    local d = Store()
    if d.cur and d.cur.id == id then
        d.cur = nil
        live, pass = {}, nil
        Changed()
        return true
    end
    for i = #d.list, 1, -1 do
        if d.list[i].id == id then
            table.remove(d.list, i)
            Changed()
            return true
        end
    end
    return false
end

-- Cleanup rule: closed sessions that ended before cutoff.
function Groups.DropOld(cutoff, apply)
    local d = Store()
    local keep, n = {}, 0
    for _, s in ipairs(d.list) do
        if (s.stop or s.last or s.start) < cutoff then n = n + 1 else keep[#keep + 1] = s end
    end
    if apply and n > 0 then d.list = keep end
    return n
end

ns.Cleanup.Add({ id = "groups", label = "Party and raid history", source = "groups",
    desc = "Groups you were in: members, where, chat and loot. The open group is never removed.",
    days = 365, min = 30, max = 1080, step = 30,
    run = function(cutoff, apply) return Groups.DropOld(cutoff, apply) end })

---------------------------------------------------------------------------
-- Module
---------------------------------------------------------------------------
local function OnEvent(event, ...)
    if CHANNELS[event] then
        local text, sender = ...
        Groups.NoteChat(event, text, sender)
    elseif event == "CHAT_MSG_LOOT" then
        Groups.NoteLoot((...))
    elseif event == "GROUP_ROSTER_UPDATE" or event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" then
        passAt = -math.huge     -- read the new roster on the next tick
    end
end

local events = { "CHAT_MSG_LOOT", "GROUP_ROSTER_UPDATE", "RAID_ROSTER_UPDATE", "PARTY_MEMBERS_CHANGED" }
for event in pairs(CHANNELS) do events[#events + 1] = event end
table.sort(events)

local function Slash(command, rest)
    if command ~= "groups" then return false end
    local arg = (rest or ""):lower():match("^(%S*)")
    local views = { now = "now", parties = "party", party = "party", raids = "raid", raid = "raid" }
    if ns.GroupsUI then ns.GroupsUI.Show(views[arg]) end
    return true
end

ns.RegisterModule("Groups", {
    defaults = { groupsLog = true, groupsChat = true, groupsLoot = true, groupsLootQuality = 2 },
    init = function()
        ns.Data.Source("groups")
        ns.Data.Source("groups.live")
        loginAt = GetTime()
    end,
    tick = Step,
    events = events,
    onEvent = OnEvent,
    slash = Slash,
})
