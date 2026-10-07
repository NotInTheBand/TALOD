-- TALOD - Store: the save-file handler.
--
-- Every store in the saved data (a top-level key of the saved variable) is
-- defined in DEFS below, in one list: how it is keyed (scope), its version
-- and the migrations up to it, a check run at every login that moves
-- unusable entries to the quarantine (instead of letting them break a
-- window), and how its entries name the character that gathered them.
-- Main calls Store.Load() after the defaults are merged and before any
-- module starts.
--
-- Characters: every character of the account gets a small number in
-- TALODDB.chars ({ ids = { [Name-Realm] = n }, names = { [n] = Name-Realm },
-- info = { [n] = { class, race, faction, realm, level, full, first, last } }, n }).
-- Account-wide logs carry that number as `c` on each entry (a field of its
-- own in string records), so a view can show the account or one character.
-- Entries from before this have no `c`: unknown, never guessed, except where
-- another record names the character (fishing sessions; your own Audit looks).
--
-- Tamper seal: the data that leaves this client for officers (recruiting,
-- play time, profession ranks) is sealed at logout: a checksum of it mixed
-- with a salt kept in the file and, when the game gives it, the account's
-- BattleTag. At the next login, data that no longer matches its seal was
-- changed outside the game: the seal is marked "edited" for SEAL_KEEP days
-- and officers are told along with what is shared (GuildSync A2). This is a
-- deterrent, not security: the method is in this file and anyone who reads
-- it can forge a seal. It stops a hand edit of the saved file, and a file
-- copied from another account (another BattleTag). Receivers never trust a
-- seal on its own: GuildSync checks what is possible, Audit compares with
-- the server's figures.
--
-- TALODDB.store = { v = { [key] = version }, salt, seals = { [name] =
-- { h, t, bt, v } }, edited = { [name] = { t } }, since = { [name] = time
-- of the first seal }, quarantine = { { t, key, path, reason, value, ver } } }.

local ADDON_NAME, ns = ...
local S = ns.Secret

local Store = {}
ns.Store = Store

local MAX_QUARANTINE = 200
local KEEP_VALUE = 4000        -- characters of a quarantined value kept (bigger: described only)
local BT_WAIT = 60             -- seconds a seal check waits for the BattleTag before it says "unknown"

local function db() return ns.DB() end

local function Num(x) return type(x) == "number" and x == x end      -- not NaN
local function Tab(x) return type(x) == "table" end
local function Str(x) return type(x) == "string" end

---------------------------------------------------------------------------
-- Checksums
---------------------------------------------------------------------------
-- A value as text, the same every time for the same content: keys sorted,
-- strings with their length (no separator can be faked), numbers that are
-- not whole rounded to 4 decimals (the saved file keeps fewer digits than
-- memory, and a seal must survive the round trip).
local TYPE_ORDER = { number = 1, string = 2, boolean = 3 }
local function KeyLess(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return (TYPE_ORDER[ta] or 9) < (TYPE_ORDER[tb] or 9) end
    if ta == "number" or ta == "string" then return a < b end
    return tostring(a) < tostring(b)
end

local function Put(buf, v, depth)
    local t = type(v)
    if t == "table" then
        if depth > 16 then buf[#buf + 1] = "{..}" return end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, KeyLess)
        buf[#buf + 1] = "{"
        for _, k in ipairs(keys) do
            Put(buf, k, depth + 1)
            buf[#buf + 1] = "="
            Put(buf, v[k], depth + 1)
            buf[#buf + 1] = ";"
        end
        buf[#buf + 1] = "}"
    elseif t == "number" then
        if v ~= v then buf[#buf + 1] = "nan"
        elseif v == math.floor(v) then buf[#buf + 1] = string.format("%.0f", v)
        else buf[#buf + 1] = string.format("%.4f", v) end
    elseif t == "string" then
        buf[#buf + 1] = #v .. ":" .. v
    elseif t == "boolean" then
        buf[#buf + 1] = v and "T" or "F"
    else
        buf[#buf + 1] = "?"
    end
end

function Store.Serialize(v)
    local buf = {}
    Put(buf, v, 0)
    return table.concat(buf)
end

-- Two polynomial checksums over the bytes, each below 2^32 (every product
-- stays exact in a double).
local M1, M2 = 4294967291, 4294967279
local function Hash(s, h1, h2)
    h1, h2 = h1 or 2166136261, h2 or 1540483477
    local byte = string.byte
    for i = 1, #s do
        local b = byte(s, i)
        h1 = (h1 * 257 + b + 1) % M1
        h2 = (h2 * 263 + b * 7 + 3) % M2
    end
    return h1, h2
end
Store.Hash = Hash

function Store.Digest(v)
    return string.format("%08x%08x", Hash(Store.Serialize(v)))
end

---------------------------------------------------------------------------
-- Characters
---------------------------------------------------------------------------
-- "Name-Realm": the key every per-character store uses.
function Store.CharKey()
    local name = S.Call(UnitName, "player")
    local realm = S.Call(GetRealmName)
    if type(name) ~= "string" or name == "" then return nil end
    return type(realm) == "string" and realm ~= "" and (name .. "-" .. realm) or name
end

local function Chars()
    local c = db().chars
    if not Tab(c) then c = {} db().chars = c end
    c.ids = Tab(c.ids) and c.ids or {}
    c.names = Tab(c.names) and c.names or {}
    c.info = Tab(c.info) and c.info or {}
    c.n = Num(c.n) and c.n or 0
    return c
end

-- A character's number, created on first use with `create`.
function Store.CharId(name, create)
    if not Str(name) or name == "" or not db() then return nil end
    local c = Chars()
    local id = c.ids[name]
    if id or not create then return id end
    c.n = c.n + 1
    id = c.n
    c.ids[name], c.names[id] = id, name
    c.info[id] = { first = time() }
    return id
end

function Store.CharName(id)
    local c = db() and db().chars
    return Tab(c) and Tab(c.names) and c.names[id] or nil
end

local meId, meName
-- This character's number (nil until the game gives the name).
function Store.Me()
    if meId then return meId end
    if not db() then return nil end
    local name = Store.CharKey()
    if not name then return nil end
    meName = name
    meId = Store.CharId(name, true)
    Store.NoteMe()
    return meId
end

function Store.IsMe(id) return id ~= nil and id == Store.Me() end

-- What the registry knows of this character, refreshed at login and logout.
function Store.NoteMe()
    if not meId then return end
    local info = Chars().info[meId] or { first = time() }
    Chars().info[meId] = info
    info.class = S.Value(select(2, S.CallMulti(2, UnitClass, "player"))) or info.class
    info.race = S.Value(select(2, S.CallMulti(2, UnitRace, "player"))) or info.race
    info.faction = S.Call(UnitFactionGroup, "player") or info.faction
    info.realm = S.Call(GetRealmName) or info.realm
    local level = S.Call(UnitLevel, "player")
    if Num(level) then info.level = level end
    local ok, full = pcall(function() return ns.Guild and ns.Guild.Me and ns.Guild.Me() end)
    if ok and Str(full) then info.full = full end
    info.last = time()
end

-- Every character on record: { id, name, info } by name.
function Store.Chars()
    local c = Chars()
    local out = {}
    for id, name in pairs(c.names) do out[#out + 1] = { id = id, name = name, info = c.info[id] or {} } end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Stamps a log entry with this character; returns it.
function Store.Tag(entry)
    if Tab(entry) then entry.c = Store.Me() end
    return entry
end

-- The character number of a full name ("First Surname-Realm" on Forever), via
-- the registry's `full` or the guild's own-names list; nil when unknown.
function Store.CharIdOfFull(full)
    if not Str(full) then return nil end
    local c = Chars()
    for id, info in pairs(c.info) do if info.full == full then return id end end
    local mine = db().guildMyNames
    for short, f in pairs(Tab(mine) and mine or {}) do
        if f == full then return c.ids[short] end
    end
    return c.ids[full]
end

-- A per-character key ("Name-Realm") becomes a registered character.
local function Adopt(map)
    for name in pairs(Tab(map) and map or {}) do
        if Str(name) and name:find("-", 1, true) then Store.CharId(name, true) end
    end
end

---------------------------------------------------------------------------
-- Quarantine
---------------------------------------------------------------------------
local report        -- the running Load: { dropped = n, migrated = { key = from } }

local function Meta()
    local m = db().store
    if not Tab(m) then m = {} db().store = m end
    m.v = Tab(m.v) and m.v or {}
    m.seals = Tab(m.seals) and m.seals or {}
    m.edited = Tab(m.edited) and m.edited or {}
    m.since = Tab(m.since) and m.since or {}
    m.quarantine = Tab(m.quarantine) and m.quarantine or {}
    if not Str(m.salt) or #m.salt < 8 then
        m.salt = string.format("%08x%08x", math.random(0, 0x7fffffff), (time() * 7919 + math.random(0, 0xffff)) % 0x7fffffff)
    end
    return m
end
Store.Meta = Meta

local function Keep(value)
    if type(value) == "table" then
        local text = Store.Serialize(value)
        return #text <= KEEP_VALUE and text or ("(a table, " .. #text .. " characters: too big to keep)")
    end
    if type(value) == "string" and #value > KEEP_VALUE then return value:sub(1, KEEP_VALUE) .. "..." end
    return value
end

function Store.Quarantine(key, path, reason, value)
    local list = Meta().quarantine
    list[#list + 1] = { t = time(), key = key, path = path, reason = reason, value = Keep(value), ver = ns.VERSION }
    while #list > MAX_QUARANTINE do table.remove(list, 1) end
    if report then report.dropped = report.dropped + 1 end
end

-- Keeps the entries of an array that pass ok(e), in order; the rest go to the quarantine.
local function List(key, path, list, ok, why)
    if list == nil then return nil end
    if not Tab(list) then
        Store.Quarantine(key, path, "not a list", list)
        return {}
    end
    local n, j = #list, 0
    for i = 1, n do
        local e = list[i]
        if ok(e) then
            j = j + 1
            if j ~= i then list[j] = e end
        else
            Store.Quarantine(key, path .. "[" .. i .. "]", why, e)
        end
    end
    for i = j + 1, n do list[i] = nil end
    return list
end
Store.List = List

-- Keeps the values of a map that pass ok(v, k); the rest go to the quarantine.
local function Map(key, path, map, ok, why)
    if map == nil then return nil end
    if not Tab(map) then
        Store.Quarantine(key, path, "not a table", map)
        return {}
    end
    local bad
    for k, v in pairs(map) do
        if not ok(v, k) then bad = bad or {} bad[#bad + 1] = k end
    end
    for _, k in ipairs(bad or {}) do
        Store.Quarantine(key, path .. "." .. tostring(k), why, map[k])
        map[k] = nil
    end
    return map
end
Store.Map = Map

local function IsLogEntry(e) return Tab(e) and Num(e.t) end

---------------------------------------------------------------------------
-- The stores
---------------------------------------------------------------------------
-- { key, scope, label, version, migrate = { [n] = fn(data) }, check =
-- fn(data) -> data, count = fn(data) -> entries, byChar = fn(data, add):
-- add(character number or nil, n) per entry }.
-- scope: "account" (one for the account; entries tagged `c`), "char" (keyed
-- by Name-Realm), "realm" (keyed by Realm-Faction; entries tagged `c`),
-- "guild" (per guild; entries tagged `c` or by name), "observed" (keyed by the
-- player looked at; each look names who looked), "meta".
local function CountMap(t)
    local n = 0
    for _ in pairs(Tab(t) and t or {}) do n = n + 1 end
    return n
end

-- A per-character store counted by its keys.
local function ByName(data, add, size)
    for name, v in pairs(Tab(data) and data or {}) do add(Store.CharId(name), size and size(v) or 1) end
end

-- The last comma field of a string record (census point, fishing cast) as a character number.
local function LastField(s, index)
    if not Str(s) then return nil end
    local i, n = 0, nil
    for piece in (s .. ","):gmatch("([^,]*),") do
        i = i + 1
        if i == index then n = tonumber(piece) break end
    end
    return n
end
Store.Field = LastField

local CAST_CHAR = 16           -- fishing cast field: the character that cast (census points end in ",#<n>")
Store.CAST_CHAR = CAST_CHAR

-- Fishing casts and threats from before tagging: the session that covers
-- their time names the character.
local function TagFishingFromSessions(f)
    local spans, all = {}, {}
    for _, s in ipairs(Tab(f.sessions) and f.sessions or {}) do all[#all + 1] = s end
    all[#all + 1] = f.session
    for _, s in ipairs(all) do
        local id = Tab(s) and Num(s.start) and (s.cid or Store.CharId(s.char, s.char ~= "?"))
        if id then spans[#spans + 1] = { s.start - 60, (Num(s.last) and s.last or s.start) + 60, id } end
    end
    local function Who(t)
        if not Num(t) then return nil end
        for _, sp in ipairs(spans) do if t >= sp[1] and t <= sp[2] then return sp[3] end end
    end
    if #spans == 0 then return end
    for i, rec in ipairs(Tab(f.casts) and f.casts or {}) do
        if Str(rec) then
            local fields = { strsplit(",", rec) }
            if #fields < CAST_CHAR then
                local id = Who(tonumber(fields[1]))
                if id then
                    for j = #fields + 1, CAST_CHAR - 1 do fields[j] = "" end
                    fields[CAST_CHAR] = id
                    f.casts[i] = table.concat(fields, ",")
                end
            end
        end
    end
    for _, t in ipairs(Tab(f.threats) and f.threats or {}) do
        if Tab(t) and t.c == nil then t.c = Who(t.t) end
    end
end

Store.DEFS = {
    { key = "players", scope = "account", label = "Journal players (KoS, avoid, notes)",
        check = function(d) return Map("players", "players", d, Tab, "not a player record") end,
        count = CountMap,
        byChar = function(d, add)
            for _, rec in pairs(d) do
                for id in pairs(Tab(rec.pc) and rec.pc or {}) do add(id, 1) end
                if not Tab(rec.pc) then add(nil, 1) end
            end
        end },
    { key = "journal", scope = "account", label = "Journal sightings",
        check = function(d) return List("journal", "journal", d, function(e) return IsLogEntry(e) and Str(e.key) end, "not a sighting") end,
        count = function(d) return #d end,
        byChar = function(d, add) for _, e in ipairs(d) do add(e.c, 1) end end },
    { key = "census", scope = "account", label = "Census points",
        check = function(d)
            if not Tab(d) then Store.Quarantine("census", "census", "not a table", d) return nil end
            d.points = List("census", "census.points", d.points, Str, "not a point")
            d.cells = Map("census", "census.cells", d.cells, Tab, "not a map's cells")
            return d
        end,
        count = function(d) return #(d.points or {}) end,
        byChar = function(d, add) for _, p in ipairs(d.points or {}) do add(tonumber(p:match(",#(%d+)$")), 1) end end },
    { key = "gear", scope = "char", label = "Gear ledger",
        migrate = { [2] = Adopt },
        check = function(d) return Map("gear", "gear", d, Tab, "not a character's gear") end,
        count = function(d) local n = 0 for _, c in pairs(d) do n = n + #(Tab(c.ledger) and c.ledger or {}) end return n end,
        byChar = function(d, add) ByName(d, add, function(c) return #(Tab(c.ledger) and c.ledger or {}) end) end },
    { key = "skills", scope = "char", label = "Skills and crafting",
        migrate = { [2] = Adopt },
        check = function(d) return Map("skills", "skills", d, Tab, "not a character's skills") end,
        count = CountMap,
        byChar = function(d, add) ByName(d, add, function(c) return #(Tab(c.log) and c.log or {}) end) end },
    { key = "economy", scope = "char", label = "Economy log",
        migrate = { [2] = Adopt },
        check = function(d)
            d = Map("economy", "economy", d, Tab, "not a character's economy")
            for name, c in pairs(d or {}) do
                c.log = List("economy", "economy." .. name .. ".log", c.log, IsLogEntry, "not a log entry")
            end
            return d
        end,
        count = function(d) local n = 0 for _, c in pairs(d) do n = n + #(c.log or {}) end return n end,
        byChar = function(d, add) ByName(d, add, function(c) return #(c.log or {}) end) end },
    { key = "prices", scope = "realm", label = "Auction prices",
        check = function(d)
            d = Map("prices", "prices", d, Tab, "not a realm's prices")
            for realm, items in pairs(d or {}) do
                Map("prices", "prices." .. realm, items, function(e) return Tab(e) and Num(e.p) and Num(e.t) end, "not a price")
            end
            return d
        end,
        count = function(d) local n = 0 for _, r in pairs(d) do n = n + CountMap(r) end return n end,
        byChar = function(d, add) for _, r in pairs(d) do for _, e in pairs(r) do add(e.c, 1) end end end },
    { key = "ladders", scope = "realm", label = "Auction ladders",
        check = function(d)
            d = Map("ladders", "ladders", d, Tab, "not a realm's ladders")
            for realm, items in pairs(d or {}) do
                Map("ladders", "ladders." .. realm, items, function(e) return Tab(e) and Str(e.l) end, "not a ladder")
            end
            return d
        end,
        count = function(d) local n = 0 for _, r in pairs(d) do n = n + CountMap(r) end return n end,
        byChar = function(d, add) for _, r in pairs(d) do for _, e in pairs(r) do add(e.c, 1) end end end },
    -- v3: lists read before 0.9.4 divided a commodity's unit price by its quantity again. They are only the
    -- Auctions tab as last seen, so drop them: the posting log stands in until the tab is opened again.
    { key = "ahOwned", scope = "char", label = "Your auction listings", version = 3,
        migrate = { [2] = Adopt, [3] = function(d) for name in pairs(d) do d[name] = nil end end },
        check = function(d) return Map("ahOwned", "ahOwned", d, Tab, "not a listing list") end,
        count = CountMap, byChar = function(d, add) ByName(d, add) end },
    { key = "ahBids", scope = "realm", label = "Auction bids under the buyout",
        check = function(d)
            d = Map("ahBids", "ahBids", d, Tab, "not a realm's bids")
            for realm, items in pairs(d or {}) do
                Map("ahBids", "ahBids." .. realm, items, function(e) return Tab(e) and Num(e.t) and Tab(e.l) end, "not a bid look")
            end
            return d
        end,
        count = function(d) local n = 0 for _, r in pairs(d) do n = n + CountMap(r) end return n end,
        byChar = function(d, add) for _, r in pairs(d) do for _, e in pairs(r) do add(e.c, 1) end end end },
    { key = "ahScanLog", scope = "account", label = "Full scan log",
        check = function(d) return List("ahScanLog", "ahScanLog", d, IsLogEntry, "not a scan entry") end,
        count = function(d) return #d end,
        byChar = function(d, add) for _, e in ipairs(d) do add(e.c, 1) end end },
    { key = "fishing", scope = "account", label = "Fishing casts",
        migrate = { [2] = function(f) if Tab(f) then TagFishingFromSessions(f) end end },
        check = function(f)
            if not Tab(f) then Store.Quarantine("fishing", "fishing", "not a table", f) return nil end
            f.casts = List("fishing", "fishing.casts", f.casts, Str, "not a cast")
            f.threats = List("fishing", "fishing.threats", f.threats, IsLogEntry, "not a threat")
            f.sessions = List("fishing", "fishing.sessions", f.sessions, Tab, "not a session")
            f.spots = Map("fishing", "fishing.spots", f.spots, Tab, "not a map's spots")
            return f
        end,
        count = function(f) return #(f.casts or {}) end,
        byChar = function(f, add) for _, c in ipairs(f.casts or {}) do add(LastField(c, CAST_CHAR), 1) end end },
    { key = "craftTrack", scope = "char", label = "Tracked craft and mailbox counts",
        check = function(d)
            d = Map("craftTrack", "craftTrack", d, Tab, "not a character's tracked craft")
            for name, c in pairs(d or {}) do
                c.mail = Map("craftTrack", "craftTrack." .. name .. ".mail", c.mail, Tab, "not a mailbox count")
                c.buys = List("craftTrack", "craftTrack." .. name .. ".buys", c.buys, function(b) return Tab(b) and Num(b.id) and Num(b.n) end, "not a purchase")
            end
            return d
        end,
        count = CountMap, byChar = function(d, add) ByName(d, add) end },
    { key = "fishSwap", scope = "char", label = "Fishing weapon swap",
        migrate = { [2] = Adopt },
        check = function(d) return Map("fishSwap", "fishSwap", d, Tab, "not a weapon pair") end,
        count = CountMap, byChar = function(d, add) ByName(d, add) end },
    { key = "guild", scope = "guild", label = "Guild (roster log, recruits)",
        check = function(d)
            if not Tab(d) then Store.Quarantine("guild", "guild", "not a table", d) return nil end
            d.guilds = Map("guild", "guild.guilds", d.guilds, Tab, "not a guild")
            for key, g in pairs(d.guilds or {}) do
                local p = "guild.guilds." .. key
                g.members = Map("guild", p .. ".members", g.members, Tab, "not a member")
                g.recruits = Map("guild", p .. ".recruits", g.recruits, Tab, "not a recruit")
                g.log = List("guild", p .. ".log", g.log, IsLogEntry, "not a log entry")
                g.events = List("guild", p .. ".events", g.events, IsLogEntry, "not a guild event")
            end
            return d
        end,
        count = function(d) local n = 0 for _, g in pairs(d.guilds or {}) do n = n + #(g.log or {}) end return n end,
        byChar = function(d, add) for _, g in pairs(d.guilds or {}) do for _, e in ipairs(g.log or {}) do add(e.c, 1) end end end },
    { key = "guildActivity", scope = "char", label = "Play time (shared)",
        check = function(d)
            d = Map("guildActivity", "guildActivity", d, Tab, "not a character's play time")
            for name, days in pairs(d or {}) do
                -- No day has more than 86400 seconds: anything else was not counted by the addon.
                Map("guildActivity", "guildActivity." .. name, days, function(s, day)
                    return Num(s) and s >= 0 and s <= 86400 and Str(day) and day:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil
                end, "impossible play time")
            end
            return d
        end,
        count = CountMap,
        byChar = function(d, add)
            for name, days in pairs(d) do add(Store.CharId(name) or Store.CharIdOfFull(name), CountMap(days)) end
        end },
    { key = "guildShare", scope = "account", label = "Guild sharing consent",
        check = function(d) return Map("guildShare", "guildShare", d, function(v) return type(v) == "boolean" end, "not a yes / no") end,
        count = CountMap },
    { key = "audit", scope = "observed", label = "Audit looks",
        migrate = { [2] = function(a)
            -- Your own looks were taken by that character.
            for full, c in pairs(Tab(a) and Tab(a.chars) and a.chars or {}) do
                local id = Tab(c) and c.own and Store.CharIdOfFull(full)
                for _, s in ipairs(Tab(c) and Tab(c.snaps) and c.snaps or {}) do
                    if Tab(s) and s.src == "self" and s.by == nil then s.by = id end
                end
            end
        end },
        check = function(a)
            if not Tab(a) then Store.Quarantine("audit", "audit", "not a table", a) return nil end
            a.chars = Map("audit", "audit.chars", a.chars, Tab, "not a character record")
            for full, c in pairs(a.chars or {}) do
                c.snaps = List("audit", "audit.chars." .. full .. ".snaps", c.snaps, function(s) return IsLogEntry(s) and Tab(s.v) end, "not a look")
            end
            return a
        end,
        count = function(a) local n = 0 for _, c in pairs(a.chars or {}) do n = n + #(c.snaps or {}) end return n end,
        byChar = function(a, add) for _, c in pairs(a.chars or {}) do for _, s in ipairs(c.snaps or {}) do add(s.by, 1) end end end },
}

local BY_KEY = {}
for _, def in ipairs(Store.DEFS) do
    def.version = def.version or 2
    BY_KEY[def.key] = def
end
function Store.Def(key) return BY_KEY[key] end

---------------------------------------------------------------------------
-- Seals: what is shared with officers
---------------------------------------------------------------------------
-- { name, v (bump when get changes: an old seal then counts as "new", not
-- "edited"), keep (days an "edited" mark stays: longer than the data is
-- shared), get = fn() -> the sealed value }. Seal names are GuildSync's
-- category keys.
local function SharedSkills()
    local out = {}
    for name, c in pairs(Tab(db().skills) and db().skills or {}) do
        local mine = {}
        for skill, s in pairs(Tab(c) and Tab(c.current) and c.current or {}) do
            if Tab(s) and (s.cat == "Professions" or s.cat == "Secondary Skills") then mine[skill] = { s.rank, s.max } end
        end
        out[name] = mine
    end
    return out
end

local function SharedRecruits()
    local out = {}
    local guilds = Tab(db().guild) and db().guild.guilds
    for key, g in pairs(Tab(guilds) and guilds or {}) do
        local mine = {}
        for full, r in pairs(Tab(g) and Tab(g.recruits) and g.recruits or {}) do
            if Tab(r) and r.invited then mine[full] = { r.invited, r.status, r.replied and true or false, r.by } end
        end
        out[key] = mine
    end
    return out
end

Store.SEALS = {
    { name = "recruiting", v = 1, keep = 35, get = SharedRecruits },
    { name = "activity", v = 1, keep = 65, get = function() return db().guildActivity end },
    { name = "prof", v = 1, keep = 7, get = SharedSkills },
}
local SEAL = {}
for _, s in ipairs(Store.SEALS) do SEAL[s.name] = s end

local digests = {}      -- [name] = digest of the data as loaded
local states = {}       -- [name] = "ok" | "edited" | "new" | "unknown" | nil (not checked yet)
local verifyWait        -- GetTime() the check started waiting for the BattleTag

local function BattleTag()
    if type(BNGetInfo) ~= "function" then return nil end
    local ok, _, tag = pcall(BNGetInfo)
    tag = ok and S.Value(tag) or nil
    return Str(tag) and tag ~= "" and tag or nil
end

-- The seal: both checksums of everything that goes in, each folded a few
-- rounds through x -> (x * 40503 + rotated other lane) mod a prime (40503:
-- the golden ratio's 16-bit multiplier). No meaning beyond making a seal
-- tedious to compute by hand.
local function SealOf(name, digest, salt, tag, editedT)
    local h1, h2 = Hash(table.concat({ name, digest, salt, tag or "", tostring(editedT or "") }, "|"))
    for _ = 1, 3 do
        h1 = (h1 * 40503 + math.floor(h2 / 65536) + (h2 % 65536) * 65536 % M1) % M1
        h2 = (h2 * 40503 + math.floor(h1 / 256)) % M2
    end
    return string.format("%08x%08x", h1, h2)
end

local function DigestAll()
    for _, s in ipairs(Store.SEALS) do
        local value
        ns.SafeCall(function() value = s.get() end)
        digests[s.name] = Store.Digest(value)
    end
end

-- Compares the loaded data with the seals of the last logout. `force`: stop
-- waiting for the BattleTag (seals that used it become "unknown").
function Store.Verify(force)
    local m = Meta()
    local tag = BattleTag()
    local now = time()
    local waiting = false
    for _, s in ipairs(Store.SEALS) do
        local rec = m.seals[s.name]
        local mark = m.edited[s.name]
        local markT = Tab(mark) and mark.t or nil
        -- The mark is part of the seal: compared as saved, dropped only after.
        local expired = Num(markT) and now - markT > s.keep * 86400
        if not Tab(rec) or rec.v ~= s.v or not Str(rec.h) then
            if expired then m.edited[s.name], mark = nil, nil end
            states[s.name] = mark and "edited" or "new"
        elseif rec.bt and not tag then
            if force then states[s.name] = mark and "edited" or "unknown" else waiting = true end
        else
            local fresh = SealOf(s.name, digests[s.name] or "", m.salt, rec.bt and tag or nil, markT)
            if fresh ~= rec.h then
                m.edited[s.name] = { t = now }
                states[s.name] = "edited"
            elseif expired then
                m.edited[s.name] = nil
                states[s.name] = "ok"
            else
                states[s.name] = mark and "edited" or "ok"
            end
        end
    end
    if waiting then return false end
    verifyWait = nil
    return true
end

-- At logout (after every module): seals what will be shared next time.
function Store.SealAll()
    if not db() then return end
    local m = Meta()
    local tag = BattleTag()
    Store.NoteMe()
    for _, s in ipairs(Store.SEALS) do
        local value
        ns.SafeCall(function() value = s.get() end)
        local mark = m.edited[s.name]
        local markT = Tab(mark) and mark.t or nil
        m.seals[s.name] = { h = SealOf(s.name, Store.Digest(value), m.salt, tag, markT), t = time(), bt = tag and true or nil, v = s.v }
        m.since[s.name] = m.since[s.name] or time()
    end
end

-- "ok" (matches the seal of the last logout), "edited" (changed outside
-- the game, within the mark's days), "new" (never sealed yet), "unknown"
-- (could not be checked), and when the seal chain began.
function Store.SealState(name)
    if not SEAL[name] then return nil end
    local m = db() and Meta()
    return states[name] or "unknown", m and m.since[name] or nil
end

---------------------------------------------------------------------------
-- Load
---------------------------------------------------------------------------
-- Runs once, before the modules start: seals are checked against the data
-- exactly as it was loaded, then each store is migrated and checked.
function Store.Load()
    if not db() then return end
    report = { dropped = 0, migrated = {} }
    for k in pairs(states) do states[k] = nil end
    local m = Meta()
    DigestAll()
    Store.Me()
    for _, def in ipairs(Store.DEFS) do
        local data = db()[def.key]
        -- Data saved before the handler existed is version 1.
        local from = m.v[def.key] or (data ~= nil and 1 or def.version)
        if data ~= nil then
            for n = from + 1, def.version do
                local fn = def.migrate and def.migrate[n]
                if fn then ns.SafeCall(fn, data) end
            end
            if from < def.version then report.migrated[def.key] = from end
            if def.check then
                local checked, ran = nil, false
                ns.SafeCall(function() checked, ran = def.check(data), true end)
                if ran then db()[def.key] = checked end
            end
        end
        m.v[def.key] = def.version
    end
    if not Store.Verify(false) then verifyWait = GetTime() end
    local done = report
    report = nil
    if done.dropped > 0 then
        ns.Print(done.dropped .. " unreadable saved entr" .. (done.dropped == 1 and "y was" or "ies were")
            .. " set aside (" .. ns.Cmd.Text("data") .. " shows them).")
    end
    return done
end

---------------------------------------------------------------------------
-- Report: account and characters
---------------------------------------------------------------------------
-- { { def, total, chars = { [id or "?"] = n } } } for every defined store.
function Store.Report()
    local out = {}
    for _, def in ipairs(Store.DEFS) do
        local data = db()[def.key]
        local row = { def = def, total = 0, chars = {} }
        if data ~= nil then
            row.total = def.count and def.count(data) or 0
            if def.byChar then
                def.byChar(data, function(id, n)
                    local k = id or "?"
                    row.chars[k] = (row.chars[k] or 0) + (n or 1)
                end)
            end
        end
        out[#out + 1] = row
    end
    return out
end

local STATE_TEXT = { ok = "sealed, unchanged", edited = "EDITED outside the game", new = "not sealed yet (seals at logout)",
    unknown = "not checked (BattleTag not readable)" }
Store.STATE_TEXT = STATE_TEXT

function Store.ReportText()
    local lines = { ns.NAME .. " " .. tostring(ns.VERSION) .. " saved data", "" }
    lines[#lines + 1] = "Characters:"
    for _, c in ipairs(Store.Chars()) do
        local i = c.info
        lines[#lines + 1] = string.format("  #%d %s%s  level %s %s%s", c.id, c.name, Store.IsMe(c.id) and " (you)" or "",
            tostring(i.level or "?"), tostring(i.class or "?"), i.last and ("  last " .. date("%Y-%m-%d", i.last)) or "")
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Stores (entries: account / by character):"
    for _, row in ipairs(Store.Report()) do
        local parts = {}
        for _, c in ipairs(Store.Chars()) do
            if row.chars[c.id] then parts[#parts + 1] = c.name .. " " .. row.chars[c.id] end
        end
        if row.chars["?"] then parts[#parts + 1] = "unknown " .. row.chars["?"] end
        lines[#lines + 1] = string.format("  %s [%s, v%d]: %d%s", row.def.label, row.def.scope, row.def.version, row.total,
            #parts > 0 and ("  (" .. table.concat(parts, ", ") .. ")") or "")
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Shared with officers (tamper seal):"
    for _, s in ipairs(Store.SEALS) do
        local state, since = Store.SealState(s.name)
        lines[#lines + 1] = "  " .. s.name .. ": " .. (STATE_TEXT[state] or state) .. (since and ("  (sealed since " .. date("%Y-%m-%d", since) .. ")") or "")
    end
    local q = Meta().quarantine
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Set aside (unreadable entries, newest last): " .. #q
    for i = math.max(1, #q - 40), #q do
        local e = q[i]
        lines[#lines + 1] = string.format("  %s  %s  %s: %s", date("%Y-%m-%d %H:%M", e.t or 0), tostring(e.path), tostring(e.reason),
            tostring(e.value):sub(1, 200))
    end
    return table.concat(lines, "\n")
end

local function Slash(command, rest)
    if command ~= "data" then return false end
    local arg = ((rest or ""):match("^(%S*)") or ""):lower()
    if arg == "clear" then
        Meta().quarantine = {}
        ns.Print("set-aside entries deleted.")
    elseif ns.Probe and ns.Probe.ShowText then
        ns.Probe.ShowText(Store.ReportText())
    else
        ns.Print(Store.ReportText())
    end
    return true
end

ns.RegisterModule("Store", {
    tick = function()
        if verifyWait and (BattleTag() or GetTime() - verifyWait >= BT_WAIT) then Store.Verify(true) end
    end,
    events = { "PLAYER_LEVEL_UP" },
    onEvent = function() Store.NoteMe() end,
    slash = Slash,
})
