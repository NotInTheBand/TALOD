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
-- Legacy: saved data from another version is either brought up to date or
-- cleared, never left half-read (see "Legacy" below): retired keys
-- (RETIRED), keys no code declares any more (only when an older version
-- saved the file), settings whose shape changed, stores older than their
-- `floor` or whose migration failed, and stores saved by a newer version
-- (parked untouched until a version that reads them is back).
--
-- TALODDB.store = { v = { [key] = version }, addon = version that saved the
-- file, salt, seals = { [name] = { h, t, bt, v } }, edited = { [name] = { t } },
-- since = { [name] = time of the first seal }, quarantine = { { t, key, path,
-- reason, value, ver } }, cleaned = { { t, id, n, auto, c } } (Cleanup.lua's
-- runs, newest last), legacy = { { t, key, what, from, to } } (newest last),
-- parked = { [key] = { v, data, t, ver } } (stores a newer version saved) }.

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

local floor, format = math.floor, string.format
local putYield, putCount = false, 0     -- a background digest pauses every PUT_STEP values
local PUT_STEP = 3000

local function Put(buf, v, depth)
    if putYield then
        putCount = putCount + 1
        if putCount >= PUT_STEP then putCount = 0 coroutine.yield() end
    end
    local t = type(v)
    if t == "table" then
        if depth > 16 then buf[#buf + 1] = "{..}" return end
        local keys, n, kind, mixed = {}, 0, nil, false
        for k in pairs(v) do
            n = n + 1
            keys[n] = k
            local tk = type(k)
            if kind == nil then kind = tk elseif tk ~= kind then mixed = true end
        end
        -- All strings or all numbers (nearly always): the built-in order is
        -- KeyLess's, without a Lua call per comparison.
        if mixed or (kind ~= "string" and kind ~= "number") then table.sort(keys, KeyLess) else table.sort(keys) end
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
        elseif v == floor(v) then buf[#buf + 1] = (v > -1e14 and v < 1e14) and tostring(v) or format("%.0f", v)
        else buf[#buf + 1] = format("%.4f", v) end
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
-- Login hashes megabytes (every recruit): eight bytes per read, and two
-- bytes folded before each modulo. The value is the same as one byte at a
-- time (h < 2^32, so h * 263^2 + ... < 2^49 stays exact).
local P1, P2 = 257 * 257, 263 * 263
local function Hash(s, h1, h2)
    h1, h2 = h1 or 2166136261, h2 or 1540483477
    local byte = string.byte
    local n = #s
    local i = 1
    while i + 7 <= n do
        local a, b, c, d, e, f, g, h = byte(s, i, i + 7)
        h1 = (h1 * P1 + (a + 1) * 257 + b + 1) % M1
        h2 = (h2 * P2 + (a * 7 + 3) * 263 + b * 7 + 3) % M2
        h1 = (h1 * P1 + (c + 1) * 257 + d + 1) % M1
        h2 = (h2 * P2 + (c * 7 + 3) * 263 + d * 7 + 3) % M2
        h1 = (h1 * P1 + (e + 1) * 257 + f + 1) % M1
        h2 = (h2 * P2 + (e * 7 + 3) * 263 + f * 7 + 3) % M2
        h1 = (h1 * P1 + (g + 1) * 257 + h + 1) % M1
        h2 = (h2 * P2 + (g * 7 + 3) * 263 + h * 7 + 3) % M2
        i = i + 8
    end
    for j = i, n do
        local b = byte(s, j)
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
-- Packed values
---------------------------------------------------------------------------
-- Every Lua table costs memory of its own (about 60 bytes, plus 40 per
-- field rounded up to a power of two), and the whole saved file sits in
-- memory while you play. Records that are read far more than they are
-- written are kept as one string instead. Each value is tagged: "" nil,
-- "T" / "F" a boolean, "n<number>", "s<text>" with the separators escaped
-- (%XX), so any value comes back exactly.
local SEPARATORS = "[%%|;~,:#]"
local function Esc(s) return (s:gsub(SEPARATORS, function(c) return string.format("%%%02X", c:byte()) end)) end
-- Packed logs are read by the thousand in one window build: most values hold
-- no escape at all (plain find, no new string), and the rest look the code
-- up in a table instead of calling a function per match.
local UNESC = {}
for i = 0, 255 do
    local h = string.format("%02X", i)
    UNESC[h], UNESC[h:lower()] = string.char(i), string.char(i)
end
local function Unesc(s)
    if not s:find("%", 1, true) then return s end
    return (s:gsub("%%(%x%x)", UNESC))
end
Store.Unesc = Unesc

local B_S, B_N, B_T, B_F = ("s"):byte(), ("n"):byte(), ("T"):byte(), ("F"):byte()

function Store.PackValue(v)
    local t = type(v)
    if v == nil then return "" end
    if t == "boolean" then return v and "T" or "F" end
    if t == "number" then return (v == v and v ~= math.huge and v ~= -math.huge) and ("n" .. tostring(v)) or "" end
    if t == "string" then return "s" .. Esc(v) end
    return nil      -- a table or anything else: not packable
end

function Store.UnpackValue(s)
    local tag = s:byte(1)
    if tag == B_S then return Unesc(s:sub(2)) end
    if tag == B_N then return tonumber(s:sub(2)) end
    if tag == B_T then return true end
    if tag == B_F then return false end
    return nil
end

-- values[1..n] joined by `sep` (one of | ; ~ , :), or nil when one cannot be packed.
function Store.PackList(values, n, sep)
    local parts = {}
    for i = 1, n do
        local p = Store.PackValue(values[i])
        if not p then return nil end
        parts[i] = p
    end
    return table.concat(parts, sep)
end

-- The raw fields of a packed list (still tagged), in order.
function Store.SplitList(s, sep)
    local out, n, pos = {}, 0, 1
    while true do
        local i = s:find(sep, pos, true)
        n = n + 1
        if not i then out[n] = s:sub(pos) return out end
        out[n] = s:sub(pos, i - 1)
        pos = i + 1
    end
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
    m.cleaned = Tab(m.cleaned) and m.cleaned or {}
    m.legacy = Tab(m.legacy) and m.legacy or {}
    m.parked = Tab(m.parked) and m.parked or {}
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
-- { key, scope, label, version, migrate = { [n] = fn(data) }, floor, check =
-- fn(data) -> data, count = fn(data) -> entries, byChar = fn(data, add):
-- add(character number or nil, n) per entry }.
-- floor: the oldest saved version still migrated. Raising it lets the
-- migrations below it be deleted: older data is cleared as legacy instead.
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
    -- v3: each item's earlier looks packed into one string (Prices.Looks).
    { key = "prices", scope = "realm", label = "Auction prices", version = 3,
        migrate = { [3] = function(d) ns.Prices.PackStore(d) end },
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
    -- v3: the guild event log's entries packed into strings (Guild.Event).
    { key = "guild", scope = "guild", label = "Guild (roster log, recruits)", version = 3,
        migrate = { [3] = function(d) ns.Guild.PackEvents(d) end },
        check = function(d)
            if not Tab(d) then Store.Quarantine("guild", "guild", "not a table", d) return nil end
            d.guilds = Map("guild", "guild.guilds", d.guilds, Tab, "not a guild")
            for key, g in pairs(d.guilds or {}) do
                local p = "guild.guilds." .. key
                g.members = Map("guild", p .. ".members", g.members, Tab, "not a member")
                g.recruits = Map("guild", p .. ".recruits", g.recruits, Tab, "not a recruit")
                g.log = List("guild", p .. ".log", g.log, IsLogEntry, "not a log entry")
                g.events = List("guild", p .. ".events", g.events, function(e)
                    return (Str(e) and e:match("^n%d") ~= nil) or IsLogEntry(e)
                end, "not a guild event")
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
    { key = "groups", scope = "account", label = "Parties and raids",
        check = function(d)
            if not Tab(d) then Store.Quarantine("groups", "groups", "not a table", d) return nil end
            local function Session(s) return Tab(s) and Num(s.id) and Num(s.start) and Tab(s.m) end
            d.list = List("groups", "groups.list", d.list, Session, "not a group")
            if d.cur ~= nil and not Session(d.cur) then
                Store.Quarantine("groups", "groups.cur", "not a group", d.cur)
                d.cur = nil
            end
            return d
        end,
        count = function(d) return #(d.list or {}) + (d.cur and 1 or 0) end,
        byChar = function(d, add)
            for _, s in ipairs(d.list or {}) do add(s.c, 1) end
            if d.cur then add(d.cur.c, 1) end
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
-- shared), get = fn() -> the sealed value, copy (get builds a fresh table
-- nothing else changes: digested in the background) }. Seal names are GuildSync's
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
    { name = "recruiting", v = 1, keep = 35, get = SharedRecruits, copy = true },
    { name = "activity", v = 1, keep = 65, get = function() return db().guildActivity end },
    { name = "prof", v = 1, keep = 7, get = SharedSkills, copy = true },
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

-- A big guild's recruiting is megabytes of text: serializing and hashing it
-- in the login frame was most of the login cost. A seal whose get() builds
-- a fresh copy (`copy`) already holds the data exactly as loaded, so it is
-- serialized and hashed over the next frames (BUDGET_MS each); the others
-- are read at once. Anything that needs the result sooner (a seal state
-- asked for, logout) finishes it then.
local HASH_CHUNK = 65536        -- bytes hashed between pauses
local BUDGET_MS = 3             -- per frame
local hashing = {}              -- coroutines still digesting, in order
local hashFrame

local function Resume(co)
    putYield = true
    local ok, err = coroutine.resume(co)
    putYield, putCount = false, 0
    if not ok then ns.SafeCall(error, "seal digest: " .. tostring(err), 0) end
    return coroutine.status(co) == "dead"
end

-- Works through the digests for `ms` milliseconds (all of them without a
-- clock or with `ms` nil); true when nothing is left.
local function HashSome(ms)
    local clock = ms and debugprofilestop
    local stop = clock and (clock() + ms)
    while hashing[1] do
        if Resume(hashing[1]) then table.remove(hashing, 1) end
        if stop and clock() >= stop then break end
    end
    return hashing[1] == nil
end

local function Digester(name, value)
    return coroutine.create(function()
        local text = Store.Serialize(value)
        local h1, h2
        for i = 1, #text, HASH_CHUNK do
            h1, h2 = Hash(text:sub(i, i + HASH_CHUNK - 1), h1, h2)
            coroutine.yield()
        end
        if not h1 then h1, h2 = Hash("") end
        digests[name] = string.format("%08x%08x", h1, h2)
    end)
end

local function DigestAll()
    wipe(hashing)
    for _, s in ipairs(Store.SEALS) do
        local value
        ns.SafeCall(function() value = s.get() end)
        if s.copy then
            digests[s.name] = nil
            hashing[#hashing + 1] = Digester(s.name, value)
        else
            digests[s.name] = Store.Digest(value)
        end
    end
end

local verifyPending     -- the login check runs once the hashing is done

-- Finishes the login check now (the hashing too).
local function Settle()
    if not verifyPending then return end
    HashSome(nil)
    if hashFrame then hashFrame:Hide() end
    verifyPending = nil
    if not Store.Verify(false) then verifyWait = GetTime() end
end

hashFrame = CreateFrame("Frame")
hashFrame:Hide()
hashFrame:SetScript("OnUpdate", function()
    if HashSome(BUDGET_MS) then Settle() end
end)

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
    -- An edit found at this login must be marked before the new seal covers it.
    Settle()
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
    Settle()
    local m = db() and Meta()
    return states[name] or "unknown", m and m.since[name] or nil
end

---------------------------------------------------------------------------
-- Legacy
---------------------------------------------------------------------------
-- Top-level keys no longer used. [key] = why (removed at the next login), or
-- fn(value, data) that carries what is worth keeping into its new home first.
-- A key renamed or dropped goes here, so players who update lose nothing
-- silently and keep nothing that no code reads.
Store.RETIRED = {
    guildWhoBracket = "the /who level bracket setting was removed",
    -- The whisper limit used to be Guild's own.
    guildWhisperBurst = function(v, d) if d.outboxBurst == nil then d.outboxBurst = v end end,
}

-- Top-level keys written without a default (and not a store above).
-- tests/run.py fails when a scenario leaves a key that is not declared
-- anywhere, so the unknown-key sweep never takes data a module still uses.
Store.EXTRA_KEYS = {
    store = true, chars = true, errorLog = true, lastProbe = true, cleanAuto = true, cleanLast = true,
    fishAutoLootLast = true, fishSoundLast = true, fishSoundRestore = true, guildAckSeen = true,
    guildMessageIndex = true, guildMessages = true, guildMyNames = true, outboxBurst = true, profPlanProf = true,
    fishAutoLootRestore = true, craftTrackPos = true,
}

local MAX_LEGACY = 100
local KEEP_KEYS = 50           -- a set-aside table with more top-level keys than this is described, not copied

-- Sets a whole store or setting aside without serializing a big one at login.
local function Aside(key, reason, v)
    if Tab(v) then
        local n = 0
        for _ in pairs(v) do n = n + 1 if n > KEEP_KEYS then break end end
        if n > KEEP_KEYS then v = "(a table of more than " .. KEEP_KEYS .. " entries: too big to keep)" end
    end
    -- Counted once as legacy, not again as an unreadable entry.
    local before = report and report.dropped
    Store.Quarantine(key, key, reason, v)
    if before then report.dropped = before end
end

local function Note(key, what, from, to)
    local list = Meta().legacy
    list[#list + 1] = { t = time(), key = key, what = what, from = from, to = to }
    while #list > MAX_LEGACY do table.remove(list, 1) end
    if report then
        report.legacy[#report.legacy + 1] = key
        if what ~= "updated" then report.cleared = report.cleared + 1 end
    end
end

-- "0.11.2" -> { 0, 11, 2 }; nil when it is not a version ("?", a dev string).
local function Parts(v)
    if not Str(v) or not v:match("^%d+[%.%d]*$") then return nil end
    local out = {}
    for n in v:gmatch("%d+") do out[#out + 1] = tonumber(n) end
    return out
end

-- -1 when a is older than b, 0 the same, 1 newer, nil when either is unreadable.
function Store.CompareVersions(a, b)
    local pa, pb = Parts(a), Parts(b)
    if not pa or not pb then return nil end
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x < y and -1 or 1 end
    end
    return 0
end

local function DefaultCopy(key)
    local d = ns.defaults and ns.defaults[key]
    if not Tab(d) then return d end
    local t = {}
    ns.CopyDefaults(t, d)
    return t
end

-- Every top-level key this version declares.
local function Known(key)
    return BY_KEY[key] ~= nil or (ns.defaults and ns.defaults[key] ~= nil) or Store.EXTRA_KEYS[key]
        or (ns.Main and ns.Main.POSITION_KEYS and ns.Main.POSITION_KEYS[key]) or false
end

Store.Known = Known

function Store.Unknown()
    local out = {}
    for key in pairs(db() or {}) do
        if not Known(key) and not Store.RETIRED[key] then out[#out + 1] = tostring(key) end
    end
    table.sort(out)
    return out
end

-- Before the stores are migrated. `older`: the file was saved by an older
-- version (or before versions were recorded): only then are undeclared keys
-- legacy. A newer version's keys are left alone, so going back a version
-- and forward again loses nothing.
local function SweepKeys(older)
    local d = db()
    for key, why in pairs(Store.RETIRED) do
        if d[key] ~= nil then
            if type(why) == "function" then ns.SafeCall(why, d[key], d) end
            Aside(key, "retired", d[key])
            d[key] = nil
            Note(key, type(why) == "string" and why or "carried over and removed")
        end
    end
    if older then
        for _, key in ipairs(Store.Unknown()) do
            Aside(key, "not used by this version", d[key])
            d[key] = nil
            Note(key, "not used by this version")
        end
    end
    -- A setting that changed shape (a switch that became a list, or back)
    -- would break whatever reads it: back to its default. Stores have checks.
    for key, def in pairs(ns.defaults or {}) do
        local v = d[key]
        if v ~= nil and not BY_KEY[key] and Tab(def) ~= Tab(v) then
            Aside(key, "setting of another shape", v)
            d[key] = DefaultCopy(key)
            Note(key, "reset to its default (its shape changed)")
        end
    end
end

-- One store before it is migrated. Returns the data and the version to
-- migrate from, or nil when it was cleared, parked or is new.
local function Bring(def, m)
    local key, d = def.key, db()
    local data = d[key]
    local parked = m.parked[key]
    -- A store a newer version saved, and this one can read it again.
    if Tab(parked) and Num(parked.v) and parked.v <= def.version then
        if data ~= nil then Aside(key, "gathered while an older version ran", data) end
        data, d[key] = parked.data, parked.data
        m.v[key] = parked.v
        m.parked[key] = nil
        Note(key, "restored from version " .. tostring(parked.ver or "?"), parked.v, def.version)
    end
    if data == nil then return nil end
    -- Data saved before the handler existed is version 1.
    local from = m.v[key] or 1
    if from > def.version then
        -- This version cannot read it, and an older check would cut it to
        -- what it understands: keep it untouched for the newer version.
        m.parked[key] = { v = from, data = data, t = time(), ver = m.addon }
        d[key] = DefaultCopy(key)
        Note(key, "saved by a newer version: kept aside until it is back", from, def.version)
        return nil
    end
    if def.floor and from < def.floor then
        Aside(key, "too old to bring up to date (v" .. from .. ")", data)
        d[key] = DefaultCopy(key)
        Note(key, "cleared: saved in a format this version no longer reads", from, def.version)
        return nil
    end
    return data, from
end

-- The migration steps of one store; a failed step sets the store aside
-- (half-migrated data would break the windows that read it).
local function Migrate(def, data, from)
    for n = from + 1, def.version do
        local fn = def.migrate and def.migrate[n]
        if fn and not ns.SafeCall(fn, data) then
            Aside(def.key, "update to v" .. n .. " failed", data)
            db()[def.key] = DefaultCopy(def.key)
            Note(def.key, "cleared: the update to this version failed", from, def.version)
            return false
        end
    end
    if from < def.version then
        report.migrated[def.key] = from
        Note(def.key, "updated", from, def.version)
    end
    return true
end

-- What the last logins changed, newest last.
function Store.LegacyLog() return Meta().legacy end
function Store.Parked() return Meta().parked end

---------------------------------------------------------------------------
-- Load
---------------------------------------------------------------------------
-- Runs once, before the modules start: seals are checked against the data
-- exactly as it was loaded, then each store is migrated and checked.
-- `fresh`: no saved data existed (a first install). Automatic cleanup is
-- decided here once: on for a first install, off for an update, so an
-- update never deletes data its owner did not agree to.
function Store.Load(fresh)
    if not db() then return end
    if db().cleanAuto == nil then db().cleanAuto = fresh and true or false end
    report = { dropped = 0, migrated = {}, legacy = {}, cleared = 0 }
    for k in pairs(states) do states[k] = nil end
    local m = Meta()
    DigestAll()
    Store.Me()
    -- Older: saved by an older version, or before the version was recorded.
    local cmp = Store.CompareVersions(m.addon, ns.VERSION)
    local older = not fresh and (m.addon == nil or cmp == -1)
    ns.SafeCall(SweepKeys, older)
    for _, def in ipairs(Store.DEFS) do
        local data, from = Bring(def, m)
        if data ~= nil and Migrate(def, data, from) and def.check then
            local checked, ran = nil, false
            ns.SafeCall(function() checked, ran = def.check(data), true end)
            if ran then db()[def.key] = checked end
        end
        m.v[def.key] = def.version
    end
    -- A newer file stays marked newer, so its keys are never swept.
    if cmp ~= 1 then m.addon = ns.VERSION end
    verifyPending = true
    if hashing[1] then hashFrame:Show() else Settle() end
    local done = report
    report = nil
    if done.cleared > 0 then
        ns.Print("saved data from another version: " .. done.cleared .. " old part" .. (done.cleared == 1 and " was" or "s were")
            .. " cleared or kept aside (" .. ns.Cmd.Text("data") .. " lists them).")
    end
    if done.dropped > 0 then
        ns.Print(done.dropped .. " unreadable saved entr" .. (done.dropped == 1 and "y was" or "ies were")
            .. " set aside (" .. ns.Cmd.Text("data") .. " shows them).")
    end
    return done
end

-- For Cleanup.lua: the set-aside list and the log of cleanup runs.
function Store.Quarantined() return Meta().quarantine end
function Store.CleanLog() return Meta().cleaned end

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
    local legacy = Meta().legacy
    if #legacy > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Data from other versions (updated or cleared, newest last):"
        for i = math.max(1, #legacy - 30), #legacy do
            local e = legacy[i]
            lines[#lines + 1] = string.format("  %s  %s: %s%s", date("%Y-%m-%d %H:%M", e.t or 0), tostring(e.key), tostring(e.what),
                e.from and e.to and string.format(" (v%s -> v%s)", tostring(e.from), tostring(e.to)) or "")
        end
    end
    for key, p in pairs(Meta().parked) do
        lines[#lines + 1] = string.format("  kept for a newer version: %s (v%s, from %s)", tostring(key), tostring(p.v), tostring(p.ver or "?"))
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
