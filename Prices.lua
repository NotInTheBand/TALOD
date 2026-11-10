-- TALOD - Prices: auction prices as you see them. Whatever the Auction
-- House shows you (a search, a browse page, an item's listings) is logged:
-- the lowest buyout per unit and when. Per realm and faction (vanilla
-- auction houses are per faction).
--
-- Both auction APIs: the legacy list (AUCTION_ITEM_LIST_UPDATE +
-- GetAuctionItemInfo, Classic Era) and C_AuctionHouse (browse, commodity
-- and item results; WoW Forever loads the modern one).
-- When we have not seen an item ourselves, Auctionator's price (its scans)
-- is asked, if it is installed. Prices.Get returns the newer of the two.
--
-- Data: TALODDB.prices["Realm-Faction"][itemID] = { p, t, n, a, name, h }:
-- p copper per unit (lowest buyout), t when, n units listed, a auctions (or
-- price rows for a commodity), c the character that saw it (Store.lua),
-- b = 1 when only browse rows priced the look (their price may not be per
-- unit: Market never lets such looks set the usual price),
-- h older sightings { {t, p, n, a, c, b} }, d days
-- "day:low:high:units,..." (day = t / 86400, the last MAX_DAYS days with a
-- look: the price graph's long view after h's 30 looks roll off). Several
-- pages of one look keep the lowest price and the largest counts seen.
--
-- Ladders: when a look shows every auction of an item (a full scan, an
-- exact search on one page, a commodity / item result list) its whole price
-- ladder is kept too, newest only: TALODDB.ladders["Realm-Faction"]
-- [itemID] = { t, l = "unit:qty[:mine[:stack]],...", a, s, top, tn, my, part, bid,
-- more, c }: price tiers cheapest first (at most MAX_TIERS; `more` units above
-- them), auctions, distinct sellers / the top seller's units and name (only
-- when every row named its seller), your own units, part = some auctions
-- not seen (costs are then "at least"), bid = bid-only units (no buyout).
-- The Auction desk (AuctionDesk.lua) reads it for buyout and control costs.
--
-- Bids: the auctions you saw whose next bid is under the lowest buyout, with
-- the game's time-left band (TALODDB.ahBids, see "Bids" below); Market's
-- Bids tab compares them with the item's price.

local ADDON_NAME, ns = ...
local S = ns.Secret

local Prices = {}
ns.Prices = Prices

local SESSION = 600          -- sightings this close are one look at the AH: keep the lowest
local MAX_HISTORY = 30
local MAX_DAYS = 60          -- days kept in an entry's daily summary
local find, byte = string.find, string.byte
local MAX_TIERS = 30         -- price tiers kept per ladder (a full scan writes thousands of ladders)

local function db() return ns.DB() end

-- Kept once both parts are read: a character's realm and faction do not
-- change in a session, and every price lookup (tens of thousands in a
-- profession plan or the Deals list) asks for it.
local realmKey
function Prices.RealmKey()
    if realmKey then return realmKey end
    local realm = S.Call(GetRealmName)
    local faction = S.Call(UnitFactionGroup, "player")
    if type(realm) ~= "string" then return nil end
    if type(faction) ~= "string" then return realm .. "-?" end
    realmKey = realm .. "-" .. faction
    return realmKey
end

local function Realm(create)
    local key = Prices.RealmKey()
    if not key then return nil end
    local all = db().prices
    if not all[key] and create then all[key] = {} end
    return all[key]
end

-- Copper per unit kept to 1/10000 copper: a stack's buyout over its count
-- (20 for 39c is 1.95c each, 20 for 21c is 1.05c). Whole copper per unit made
-- cheap stacks look up to twice as dear, merged different prices into one
-- and undercut by a whole copper a unit; amounts are rounded once, where they
-- are summed or shown. Never 0: a 9c stack of 200 is not free.
local function Exact(x) return math.max(1e-4, math.floor(x * 10000 + 0.5) / 10000) end
Prices.Exact = Exact

-- The player's calendar day of `t` as a day number (t / 86400 is the UTC
-- day: for a player at UTC-7 it ends at 5 pm, splitting one evening's looks
-- into two days and joining it to the next day's). The offset is read once
-- per hour (date() is slow, a walk over every item asks thousands of times).
local function CivilDays(y, m, d)
    y = m <= 2 and y - 1 or y
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * ((m + 9) % 12) + 2) / 5) + d - 1
    return era * 146097 + yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy - 719468
end
local offsets, nOffsets = {}, 0
local function UtcOffset(t)
    local h = math.floor(t / 3600)
    local off = offsets[h]
    if not off then
        local l, u = date("*t", h * 3600), date("!*t", h * 3600)
        off = (CivilDays(l.year, l.month, l.day) - CivilDays(u.year, u.month, u.day)) * 86400
            + (l.hour - u.hour) * 3600 + (l.min - u.min) * 60
        if nOffsets >= 4096 then offsets, nOffsets = {}, 0 end
        offsets[h], nOffsets = off, nOffsets + 1
    end
    return off
end
function Prices.DayKey(t) return math.floor((t + UtcOffset(t)) / 86400) end
-- Local noon of a day key: where that day's point is drawn (and dated).
function Prices.DayNoon(day)
    local t = day * 86400 + 43200
    return t - UtcOffset(t)
end

-- Days of a daily summary string: { [day] = { day, low, high, units } }.
local function ParseDays(d)
    local out = {}
    -- Units may be empty: no look that day said how many were listed.
    for day, lo, hi, n in (type(d) == "string" and d or ""):gmatch("(%d+):([%d%.]+):([%d%.]+):(%d*)") do
        day = tonumber(day)
        out[day] = { day, tonumber(lo), tonumber(hi), tonumber(n) }
    end
    return out
end

-- The larger of two unit counts where nil is unknown (never 0: an unknown
-- count read as 0 would look like every unit sold).
local function MaxN(a, b)
    if a == nil then return b end
    if b == nil then return a end
    return math.max(a, b)
end
Prices.MaxN = MaxN

-- A daily summary as its string, the last MAX_DAYS days.
local function DaysText(days)
    local order = {}
    for k in pairs(days) do order[#order + 1] = k end
    table.sort(order)
    local parts = {}
    for i = math.max(1, #order - MAX_DAYS + 1), #order do
        local x = days[order[i]]
        parts[#parts + 1] = x[1] .. ":" .. x[2] .. ":" .. x[3] .. ":" .. (x[4] or "")
    end
    return table.concat(parts, ",")
end

-- Folds one look into the daily summary: lowest, highest, most units that day.
local function FoldDay(d, t, p, n)
    local days = ParseDays(d)
    local day = Prices.DayKey(t)
    local e = days[day]
    if e then
        e[2], e[3], e[4] = math.min(e[2], p), math.max(e[3], p), MaxN(e[4], n)
    else
        days[day] = { day, p, p, n }
    end
    return DaysText(days)
end

-- Older saves keyed the daily summary by the UTC day (t / 86400);
-- the looks are now folded by the local day, so the two keys of one evening
-- would merge another day's units into it (Store migration v4). The days the
-- kept looks cover are folded again from them by the local day; older days
-- keep their key (only the day number was saved: they cannot be moved).
function Prices.RekeyDays(d)
    for _, realm in pairs(type(d) == "table" and d or {}) do
        for _, e in pairs(type(realm) == "table" and realm or {}) do
            if type(e) == "table" and type(e.d) == "string" then
                local looks = Prices.Looks(e)
                local t0
                for _, x in ipairs(looks) do t0 = math.min(t0 or x.t, x.t) end
                if t0 then
                    local days = ParseDays(e.d)
                    local cut = math.min(math.floor(t0 / 86400), Prices.DayKey(t0))
                    for day in pairs(days) do if day >= cut then days[day] = nil end end
                    for _, x in ipairs(looks) do
                        local day = Prices.DayKey(x.t)
                        local y = days[day]
                        if y then y[2], y[3], y[4] = math.min(y[2], x.p), math.max(y[3], x.p), MaxN(y[4], x.n)
                        else days[day] = { day, x.p, x.p, x.n } end
                    end
                    e.d = DaysText(days)
                end
            end
        end
    end
end

-- Every write here bumps the "prices" source (Data.lua): prices, ladders and
-- your listings. One results event or scan chunk writes hundreds, so they
-- Bump and the windows are told once (Data.Notify) when the batch is in.
local function Bumped() ns.Data.Bump("prices") end

-- Earlier looks (`h`): one string, oldest first, "t:p:n:a:c:b" per look
-- joined by ",", empty for nil. A full scan writes thousands of items with
-- up to MAX_HISTORY looks each; as tables (one per look) they were most of
-- the price data's memory. Saved tables from before (Store v3 packs them)
-- are still read.
local function Field(x) return x == nil and "" or tostring(x) end
local function LookText(t, p, n, a, c, b)
    return Field(t) .. ":" .. Field(p) .. ":" .. Field(n) .. ":" .. Field(a) .. ":" .. Field(c) .. ":" .. Field(b)
end

local function LookOf(text)
    local t, p, n, a, c, b = text:match("^([^:]*):([^:]*):([^:]*):([^:]*):([^:]*):([^:]*)$")
    if not t then return nil end
    return { t = tonumber(t), p = tonumber(p), n = tonumber(n), a = tonumber(a), c = tonumber(c), b = tonumber(b) }
end

-- { { t, p, n, a, c, b } } of an entry's earlier looks, oldest first (new tables: the caller may keep them).
function Prices.Looks(e)
    local h, out = e and e.h, {}
    if type(h) == "string" then
        for text in h:gmatch("[^,]+") do
            local look = LookOf(text)
            if look and look.t and look.p then out[#out + 1] = look end
        end
    elseif type(h) == "table" then
        for _, x in ipairs(h) do
            if type(x) == "table" then out[#out + 1] = { t = x[1], p = x[2], n = x[3], a = x[4], c = x[5], b = x[6] } end
        end
    end
    return out
end

-- The looks of an entry as parallel arrays, no table per look (a walk over
-- thousands of items reads them all): { t, p, n, a, b, count }; b[i] is true
-- for a browse-only look, n / a hold nil where the look did not say. Same
-- looks, same order, same skipping of broken ones as Prices.Looks. `into`
-- (optional) is refilled in place: a caller reading item after item keeps one
-- and must finish with the result before the next call.
function Prices.LookColumns(e, into)
    local c = into or {}
    local T, P, N, A, B = c.t or {}, c.p or {}, c.n or {}, c.a or {}, c.b or {}
    c.t, c.p, c.n, c.a, c.b = T, P, N, A, B
    local count = 0
    local h = e and e.h
    if type(h) == "string" then
        -- One find per look, anchored where the last one ended; a segment that
        -- is not exactly six fields is skipped to the next comma.
        local pos, len = 1, #h
        while pos <= len do
            local first, last, t, p, n, a, _, b = find(h, "^([^:,]*):([^:,]*):([^:,]*):([^:,]*):([^:,]*):([^:,]*)", pos)
            if first and (last == len or byte(h, last + 1) == 44) then
                t, p = tonumber(t), tonumber(p)
                if t and p then
                    count = count + 1
                    T[count], P[count], N[count], A[count], B[count] = t, p, tonumber(n), tonumber(a), tonumber(b) ~= nil
                end
                pos = last + 2
            else
                local comma = find(h, ",", pos, true)
                if not comma then break end
                pos = comma + 1
            end
        end
    elseif type(h) == "table" then
        for _, x in ipairs(h) do
            if type(x) == "table" and x[1] and x[2] then
                count = count + 1
                T[count], P[count], N[count], A[count], B[count] = x[1], x[2], x[3], x[4], x[6] and true or false
            end
        end
    end
    c.count = count
    return c
end

-- The string form of a list of looks (nil when empty).
function Prices.PackLooks(looks)
    local parts = {}
    for i, x in ipairs(looks) do parts[i] = LookText(x.t, x.p, x.n, x.a, x.c, x.b) end
    return #parts > 0 and table.concat(parts, ",") or nil
end

-- Every old table history of a `prices` store packed (Store migration v3).
function Prices.PackStore(d)
    for _, realm in pairs(type(d) == "table" and d or {}) do
        for _, e in pairs(type(realm) == "table" and realm or {}) do
            if type(e) == "table" and type(e.h) == "table" then e.h = Prices.PackLooks(Prices.Looks(e)) end
        end
    end
end

local function AddLook(h, e)
    if type(h) == "table" then h = Prices.PackLooks(Prices.Looks({ h = h })) end
    local text = LookText(e.t, e.p, e.n, e.a, e.c, e.b)
    h = (h and h ~= "") and (h .. "," .. text) or text
    local _, commas = h:gsub(",", ",")
    for _ = 1, commas + 1 - MAX_HISTORY do h = h:gsub("^[^,]*,", "", 1) end
    return h
end

-- One sighting: `unit` copper each, `qty` units in `auctions` auctions.
-- rough: the price comes from a browse row (not checked per unit).
-- fresh: a new complete read of the item (an exact search's first page, a
-- commodity / item result list, a full scan): it shows the market as it is
-- now, so inside the visit it replaces the price and counts instead of
-- keeping the visit's lowest (an auction bought out since is not the price).
function Prices.Record(id, unit, qty, now, auctions, name, rough, fresh)
    if not db().auctionPrices or type(id) ~= "number" or type(unit) ~= "number" or unit <= 0 then return end
    local realm = Realm(true)
    if not realm then return end
    Bumped()
    now = now or time()
    unit = Exact(unit)
    local e = realm[id]
    if type(name) ~= "string" or name == "" then name = e and e.name or nil end
    -- One look = one visit: sightings within SESSION of the look's first one
    -- merge. The window does not slide (e.t stays): a sighting every 9 minutes
    -- for hours would otherwise be one look holding the lowest of all of them.
    if e and now >= e.t and now - e.t <= SESSION then
        if rough and not e.b then
            -- A browse row may not be per unit: it never changes an exact look's price.
        elseif not rough and e.b then
            -- The first exact read replaces the rough price.
            e.p, e.b = unit, nil
        elseif fresh and not rough then
            e.p, e.n, e.a = unit, qty, auctions
        else
            e.p = math.min(e.p, unit)
        end
        if not (fresh and not rough) then
            e.n = MaxN(e.n, qty)
            if auctions then e.a = math.max(e.a or 0, auctions) end
        end
        e.name = name
        e.c = ns.Store.Me() or e.c
        return e
    end
    local h = e and e.h
    local d = e and e.d
    if e then
        h = AddLook(h, e)
        d = FoldDay(d, e.t, e.p, e.n)
    end
    e = { p = unit, t = now, n = qty, a = auctions, name = name, h = h, d = d, c = ns.Store.Me(),
        b = rough and 1 or nil }
    realm[id] = e
    return e
end

-- Midnight (local) `days` days ago.
local function DayStart(days)
    local d = date("*t", time() - (days or 0) * 86400)
    return time({ year = d.year, month = d.month, day = d.day, hour = 0 })
end

-- Auctionator's price (copper) and when it was seen. Auctionator only keeps
-- the day of its scan ("0 days" = some time today), so the time is the start
-- of that day: never newer than the scan really is. Show it with
-- Prices.Age(t, "auctionator") ("today", "2 days ago").
local function FromAuctionator(id)
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if type(api) ~= "table" or type(api.GetAuctionPriceByItemID) ~= "function" then return nil end
    local ok, price = pcall(api.GetAuctionPriceByItemID, ADDON_NAME, id)
    if not ok or type(price) ~= "number" or price <= 0 then return nil end
    local okAge, days = false, nil
    if type(api.GetAuctionAgeByItemID) == "function" then okAge, days = pcall(api.GetAuctionAgeByItemID, ADDON_NAME, id) end
    local t = (okAge and type(days) == "number" and days >= 0) and DayStart(math.floor(days)) or nil
    return price, t
end

-- Copper per unit, when it was seen (nil: unknown), and the source:
-- "seen" (you saw it) or "auctionator". nil when neither has it. Your own
-- look wins unless Auctionator's scan is from a later day.
function Prices.Get(id)
    local realm = Realm(false)
    local e = realm and realm[id]
    local ap, at = FromAuctionator(id)
    if e and (not ap or not at or e.t >= at) then return e.p, e.t, "seen" end
    if ap then return ap, at, "auctionator" end
    return nil
end

-- An item's price over time, oldest first. mode "looks": every look kept
-- ({ t, p, n, a, c = the character that looked, b = browse only }); "days": one point per day ({ t (noon), day, p = lowest,
-- hi = highest, n = most units listed }) from the daily summary and the looks.
-- Looks the cleanup moved to the archive (Archive.lua), when it is loaded:
-- trimmed history, and whole entries of items not seen for months.
local function ArchivedLooks(id, into)
    local A = ns.Archive
    local realm = Prices.RealmKey()
    if not (A and realm and A.Loaded()) then return nil end
    local key = realm .. "/" .. tostring(id)
    local days
    for _, v in ipairs(A.Lookup("priceHistory", key)) do
        for _, x in ipairs(Prices.Looks({ h = v })) do into[#into + 1] = x end
    end
    for _, v in ipairs(A.Lookup("priceUnseen", key)) do
        local f = ns.Store.SplitList(v, ";")
        local U = ns.Store.UnpackValue
        for _, x in ipairs(Prices.Looks({ h = U(f[7] or "") })) do into[#into + 1] = x end
        local p, t = U(f[1] or ""), U(f[2] or "")
        if type(p) == "number" and type(t) == "number" then into[#into + 1] = { t = t, p = p, n = U(f[3] or ""), a = U(f[4] or ""), c = U(f[6] or "") } end
        days = U(f[8] or "") or days
    end
    return days
end

function Prices.History(id, mode)
    local e = Prices.Entry(id)
    local old = {}
    local oldDays = ArchivedLooks(id, old)
    if not e and #old == 0 then return {} end
    local looks = {}
    for _, x in ipairs(old) do looks[#looks + 1] = { t = x.t, p = x.p, n = x.n, a = x.a, c = x.c, b = x.b and true or nil } end
    for _, x in ipairs(e and Prices.Looks(e) or {}) do looks[#looks + 1] = { t = x.t, p = x.p, n = x.n, a = x.a, c = x.c, b = x.b and true or nil } end
    if e then looks[#looks + 1] = { t = e.t, p = e.p, n = e.n, a = e.a, c = e.c, b = e.b and true or nil } end
    if #old > 0 then table.sort(looks, function(a, b) return a.t < b.t end) end
    if mode ~= "days" then return looks end
    -- The archived daily summary and the live one together: an item that came
    -- back after the cleanup archived it has both (min / max / most units
    -- per day: folding a day twice changes nothing).
    local days = ParseDays(oldDays)
    for day, x in pairs(ParseDays(e and e.d)) do
        local y = days[day]
        if y then y[2], y[3], y[4] = math.min(y[2], x[2]), math.max(y[3], x[3]), MaxN(y[4], x[4]) else days[day] = x end
    end
    for _, pt in ipairs(looks) do
        local day = Prices.DayKey(pt.t)
        local x = days[day]
        if x then
            x[2], x[3], x[4] = math.min(x[2], pt.p), math.max(x[3], pt.p), MaxN(x[4], pt.n)
        else
            days[day] = { day, pt.p, pt.p, pt.n }
        end
    end
    local out = {}
    for day, x in pairs(days) do out[#out + 1] = { t = Prices.DayNoon(day), day = day, p = x[2], hi = x[3], n = x[4] } end
    table.sort(out, function(a, b) return a.day < b.day end)
    return out
end

function Prices.Entry(id)
    local realm = Realm(false)
    return realm and realm[id]
end

-- Every item seen on this realm's auction house: { [itemID] = entry }.
function Prices.All()
    return Realm(false) or {}
end

function Prices.Delete(id)
    local realm = Realm(false)
    if realm then realm[id] = nil ns.Data.Changed("prices") end
end

function Prices.Count()
    local realm = Realm(false)
    local n, newest = 0, nil
    for _, e in pairs(realm or {}) do
        n = n + 1
        if not newest or e.t > newest then newest = e.t end
    end
    return n, newest
end

---------------------------------------------------------------------------
-- Ladders: every buyout of one item at one look
---------------------------------------------------------------------------
local function Ladders(create)
    local key = Prices.RealmKey()
    if not key then return nil end
    if type(db().ladders) ~= "table" then db().ladders = {} end
    local all = db().ladders
    if not all[key] and create then all[key] = {} end
    return all[key]
end

function Prices.PlayerName()
    local name = S.Call(UnitName, "player")
    return type(name) == "string" and name or nil
end

-- rows: { { unit, qty, owner, mine } }: unit nil = bid only; owner nil =
-- not said (then no seller counts); mine = units of yours in the row (or
-- true: all of them). whole: every row is one auction bought whole (the
-- legacy list, an item's auctions); without it rows are a commodity's prices,
-- bought by the unit. A whole ladder keeps the stack size per tier (one tier
-- per price and stack size): 3 Linen out of a stack of 20 cost the stack.
function Prices.RecordLadder(id, rows, partial, now, whole)
    if not db().auctionPrices or type(id) ~= "number" or type(rows) ~= "table" then return end
    local store = Ladders(true)
    if not store then return end
    Bumped()
    local tiers, owners, ownersKnown, auctions, bid, my = {}, {}, true, 0, 0, 0
    for _, r in ipairs(rows) do
        local unit, qty = r[1], r[2]
        if type(qty) == "number" and qty > 0 then
            auctions = auctions + 1
            if type(unit) == "number" and unit > 0 then
                unit = Exact(unit)
                local mine = r[4] == true and qty or (type(r[4]) == "number" and math.min(qty, r[4]) or 0)
                local k = whole and math.floor(qty) or nil
                local key = k and (unit .. "/" .. k) or unit
                local t = tiers[key] or { 0, 0, unit, k }
                t[1], t[2] = t[1] + qty, t[2] + mine
                tiers[key] = t
                my = my + mine
            else
                bid = bid + qty
            end
            if type(r[3]) == "string" and r[3] ~= "" then
                owners[r[3]] = (owners[r[3]] or 0) + qty
            else
                ownersKnown = false
            end
        end
    end
    local order = {}
    for _, t in pairs(tiers) do order[#order + 1] = t end
    table.sort(order, function(a, b)
        if a[3] ~= b[3] then return a[3] < b[3] end
        return (a[4] or 0) < (b[4] or 0)
    end)
    local parts, more = {}, 0
    for i, t in ipairs(order) do
        if i <= MAX_TIERS then
            -- "unit:qty[:mine[:stack]]"
            parts[#parts + 1] = t[3] .. ":" .. t[1] .. ((t[2] > 0 or t[4]) and (":" .. t[2]) or "") .. (t[4] and (":" .. t[4]) or "")
        else
            more = more + t[1]
        end
    end
    local e = { t = now or time(), l = table.concat(parts, ","), a = auctions, my = my > 0 and my or nil,
        part = partial and true or nil, bid = bid > 0 and bid or nil, more = more > 0 and more or nil, c = ns.Store.Me() }
    if ownersKnown and auctions > 0 then
        local n, top, tn = 0, 0, nil
        for name, q in pairs(owners) do
            n = n + 1
            if q > top or (q == top and tn and name < tn) then top, tn = q, name end
        end
        e.s, e.top, e.tn = n, top, tn
    end
    store[id] = e
    return e
end

-- A ladder's tiers, cheapest first: unit, qty, mine, stack ("": by the unit).
local function EachTier(l)
    return l:gmatch("([%d%.]+):(%d+):?(%d*):?(%d*)")
end

-- { t, tiers = { { u, q, m, k (stack size: whole auctions only) } } cheapest first, units (with a buyout),
-- auctions, sellers, top, topName, mine, partial, bidOnly, more } or nil.
function Prices.Ladder(id)
    local store = Ladders(false)
    local e = store and store[id]
    if type(e) ~= "table" or type(e.l) ~= "string" then return nil end
    local out = { t = e.t, tiers = {}, units = 0, auctions = e.a, sellers = e.s, top = e.top, topName = e.tn,
        mine = e.my or 0, partial = e.part and true or false, bidOnly = e.bid or 0, more = e.more or 0 }
    for u, q, m, k in EachTier(e.l) do
        local tier = { u = tonumber(u), q = tonumber(q), m = tonumber(m) or 0, k = tonumber(k) }
        out.tiers[#out.tiers + 1] = tier
        out.units = out.units + tier.q
    end
    out.units = out.units + out.more
    return out
end

-- Covering `need` units from the tiers (other sellers' units only): cost,
-- units got. A commodity tier sells by the unit; a tier of whole auctions
-- only whole stacks (the legacy list buys the whole auction or nothing).
-- Units short are covered by the vendor at maxUnit (not bought here: the
-- caller adds the vendor part); without one, covering more units always wins
-- over paying less.
-- Whole stacks need every count of a tier weighed, none included: taking as
-- many as fit first is not the cheapest (two 19-stacks at 100c a unit then a
-- 20-stack at 105c cost 3800c for 20 units; the 20-stack alone costs 2100c).
-- A min-cost cover (bounded knapsack, each tier's stacks split 1, 2, 4, ...)
-- over units got, capped at need: cost[g] / got[g] = the cheapest way to hold
-- g units (or `need` and more). By the unit only (no stack over 1), the
-- cheapest units first is already the best.
local function Cover(tiers, need, maxUnit)
    if need <= 0 then return 0, 0 end
    local use, stacked = {}, false
    for _, t in ipairs(tiers) do
        local q = math.max(0, t.q - (t.m or 0))
        if q > 0 and not (maxUnit and t.u > maxUnit) then
            use[#use + 1] = t
            if t.k and t.k > 1 then stacked = true end
        end
    end
    if not stacked then
        local cost, got = 0, 0
        for _, t in ipairs(use) do
            if got >= need then break end
            local take = math.min(math.max(0, t.q - (t.m or 0)), need - got)
            cost, got = cost + take * t.u, got + take
        end
        return cost, got
    end
    local cost, got = { [0] = 0 }, { [0] = 0 }
    for _, t in ipairs(use) do
        local q = math.max(0, t.q - (t.m or 0))
        local k = (t.k and t.k > 0) and t.k or 1
        local left = math.min(math.floor(q / k), math.ceil(need / k))
        local piece = 1
        while left > 0 do
            local p = math.min(piece, left)
            local units, c = p * k, p * k * t.u
            for g = need, 0, -1 do
                local base = cost[g]
                if base then
                    local ng, nc = math.min(need, g + units), base + c
                    if not cost[ng] or nc < cost[ng] - 1e-9 then cost[ng], got[ng] = nc, got[g] + units end
                end
            end
            left, piece = left - p, piece * 2
        end
    end
    -- Units short are bought from the vendor at maxUnit; without one, the most
    -- units the ladder can give win, then the cheapest.
    local bestG
    for g = need, 0, -1 do
        if cost[g] then
            if not bestG then
                bestG = g
                if not maxUnit then break end
            elseif cost[g] + (need - g) * maxUnit < cost[bestG] + (need - bestG) * maxUnit - 1e-9 then
                bestG = g
            end
        end
    end
    return cost[bestG], got[bestG]
end

-- Buying `n` units along the price ladder (cheapest first, other sellers'
-- auctions only): copper you pay (rounded up once, for the whole), units you
-- get (more than n when only a whole stack covers the rest: the surplus is
-- yours, the money is spent all the same), ladder age (s), partial (more
-- pages / more tiers than kept). maxUnit (optional): stop at tiers dearer
-- than this (a vendor that sells it cheaper). nil without a ladder.
-- The lowest price times n assumes every unit is as cheap as the cheapest
-- auction: wrong as soon as the cheapest tier holds fewer than n.
function Prices.LadderBuy(id, n, maxUnit)
    local L = Prices.Ladder(id)
    if not L or type(n) ~= "number" then return nil end
    local cost, got = Cover(L.tiers, math.floor(n), maxUnit)
    return math.ceil(cost - 0.05), got, time() - (L.t or 0), (L.partial or (L.more or 0) > 0) and true or false
end

-- Prices.Ladder as columns, no table per tier (the desk reads thousands of
-- ladders): { t, u, q, m, count (tiers), units, auctions, sellers, top,
-- topName, mine, partial, bidOnly, more } or nil. `into` is refilled in place
-- like Prices.LookColumns': finish with the result before the next call.
function Prices.LadderColumns(id, into)
    local store = Ladders(false)
    local e = store and store[id]
    if type(e) ~= "table" or type(e.l) ~= "string" then return nil end
    local c = into or { u = {}, q = {}, m = {} }
    local U, Q, M = c.u, c.q, c.m
    c.k = c.k or {}
    local K = c.k
    local count, units = 0, 0
    for u, q, m, k in EachTier(e.l) do
        count = count + 1
        q = tonumber(q)
        U[count], Q[count], M[count], K[count] = tonumber(u), q, tonumber(m) or 0, tonumber(k) or false
        units = units + q
    end
    c.count = count
    c.t, c.auctions, c.sellers, c.top, c.topName = e.t, e.a, e.s, e.top, e.tn
    c.mine, c.partial, c.bidOnly, c.more = e.my or 0, e.part and true or false, e.bid or 0, e.more or 0
    c.units = units + c.more
    return c
end

function Prices.AllLadders() return Ladders(false) or {} end

---------------------------------------------------------------------------
-- Bids: auctions whose next bid is under the item's lowest buyout
---------------------------------------------------------------------------
-- TALODDB.ahBids["Realm-Faction"][itemID] = { t, api, low, c, part, l =
-- { "count:next:buyout:band:flags", ... } }: the newest look of each item,
-- its BID_ROWS cheapest auctions per unit to bid on (others' only). next =
-- the least the game takes as your bid (the whole auction), buyout 0 = none,
-- low = the lowest buyout per unit at that look, band = the game's time
-- left at the look (0 unknown), flags h = you are the high bidder, b =
-- someone has bid. Commodities on C_AuctionHouse cannot be bid on: none here.
-- Only a snapshot: others can bid after you looked.
local BID_ROWS = 10
local BID_MERGE = 120        -- pages of one search this close are one look
local BID_KEEP = 86400       -- time left unknown: dropped a day after the look
-- Time-left bands, 1 = shortest: { longest seconds, text }. The legacy list's
-- (GetAuctionItemTimeLeft 1-4; Classic Era auctions last 2 / 8 / 24 h) and
-- C_AuctionHouse's (Enum.AuctionHouseTimeLeftBand 0-3, read as 1-4) differ.
Prices.BANDS = {
    legacy = { { 1800, "under 30 min" }, { 7200, "30 min - 2 h" }, { 28800, "2 - 8 h" }, { 86400, "over 8 h" } },
    modern = { { 1800, "under 30 min" }, { 7200, "30 min - 2 h" }, { 43200, "2 - 12 h" }, { 172800, "over 12 h" } },
}

local function BidStore(create)
    local key = Prices.RealmKey()
    if not key then return nil end
    if type(db().ahBids) ~= "table" then db().ahBids = {} end
    local all = db().ahBids
    if not all[key] and create then all[key] = {} end
    return all[key]
end

-- The latest a row can end: its band's longest time after the look.
local function BidEnds(t, api, band)
    local b = (Prices.BANDS[api] or Prices.BANDS.legacy)[band or 0]
    return (t or 0) + (b and b[1] or BID_KEEP)
end

local function ParseBid(s)
    local count, nxt, buyout, band, flags = s:match("^(%d+):(%d+):(%d+):(%d+):(%a*)$")
    if not count then return nil end
    return { count = tonumber(count), next = tonumber(nxt), buyout = tonumber(buyout) > 0 and tonumber(buyout) or nil,
        band = tonumber(band) > 0 and tonumber(band) or nil, high = flags:find("h", 1, true) ~= nil, bids = flags:find("b", 1, true) ~= nil }
end

local function BidString(r)
    return r.count .. ":" .. r.next .. ":" .. (r.buyout or 0) .. ":" .. (r.band or 0) .. ":" .. (r.high and "h" or "") .. (r.bids and "b" or "")
end

-- rows: { { count, next, buyout, band, high, bids } } of others' auctions (next
-- and buyout for the whole auction, nil = none / unknown). api "legacy" or
-- "modern" (which bands). merge: a later page of the same search adds to
-- the look instead of replacing it. partial: the search had pages not read,
-- so `low` may not be the item's cheapest buyout (Market.Bids: no saving).
function Prices.RecordBids(id, rows, api, now, merge, store, partial)
    if not db().auctionPrices or type(id) ~= "number" or type(rows) ~= "table" then return end
    store = store or BidStore(true)
    if not store then return end
    now = now or time()
    -- Every row of this read is an auction of its own (two sellers' identical
    -- stacks are two chances to bid). Merging with the earlier read keeps,
    -- per identical row, the larger count of the two reads: a page read again
    -- is not new auctions.
    local list, low = {}, nil
    local oldRows, newCount = {}, {}
    local old = store[id]
    if merge and type(old) == "table" and old.api == api and now - (old.t or 0) <= BID_MERGE then
        low = old.low
        for _, s in ipairs(type(old.l) == "table" and old.l or {}) do
            if ParseBid(s) then oldRows[#oldRows + 1] = s end
        end
    end
    for _, r in ipairs(rows) do
        local count, buyout = r[1], r[3]
        if type(count) == "number" and count > 0 and type(buyout) == "number" and buyout > 0 then
            local unit = buyout / count
            if not low or unit < low then low = unit end
        end
    end
    for _, r in ipairs(rows) do
        local count, nxt = r[1], r[2]
        if type(count) == "number" and count > 0 and type(nxt) == "number" and nxt > 0 then
            local row = { count = math.floor(count), next = math.floor(nxt + 0.5),
                buyout = (type(r[3]) == "number" and r[3] > 0) and math.floor(r[3] + 0.5) or nil,
                band = (type(r[4]) == "number" and r[4] >= 1 and r[4] <= 4) and math.floor(r[4]) or nil,
                high = r[5] == true, bids = r[6] == true }
            local s = BidString(row)
            newCount[s] = (newCount[s] or 0) + 1
            list[#list + 1] = row
        end
    end
    -- Earlier rows beyond what this read holds of the same kind stay.
    local used = {}
    for _, s in ipairs(oldRows) do
        used[s] = (used[s] or 0) + 1
        if used[s] > (newCount[s] or 0) then list[#list + 1] = ParseBid(s) end
    end
    -- A bid is worth a look only under the cheapest buyout (with none listed:
    -- every one, Market compares it with the usual price).
    local keep = {}
    for _, r in ipairs(list) do
        if not low or r.next / r.count < low then keep[#keep + 1] = r end
    end
    table.sort(keep, function(a, b) return a.next / a.count < b.next / b.count end)
    if #keep == 0 then
        if store[id] then Bumped() end
        store[id] = nil
        return nil
    end
    local parts = {}
    for i = 1, math.min(#keep, BID_ROWS) do parts[i] = BidString(keep[i]) end
    Bumped()
    local e = { t = now, api = api, low = low and Exact(low) or nil, l = parts, c = ns.Store.Me(), part = partial and true or nil }
    store[id] = e
    return e
end

-- A full scan saw every auction: its bids replace the realm's.
-- bids = { [itemID] = rows } as for RecordBids.
function Prices.ReplaceBids(bids, api, now)
    local key = Prices.RealmKey()
    if not key or not db().auctionPrices then return end
    if type(db().ahBids) ~= "table" then db().ahBids = {} end
    local store = {}
    db().ahBids[key] = store
    Bumped()
    for id, rows in pairs(bids) do Prices.RecordBids(id, rows, api, now, false, store) end
end

-- One item's bids as last seen, rows still running (by their band):
-- { t, api, low, rows = { { count, next, buyout, band, high, bids, unit, ends } } } or nil.
function Prices.Bids(id, now)
    local store = BidStore(false)
    local e = store and store[id]
    if type(e) ~= "table" or type(e.l) ~= "table" then return nil end
    now = now or time()
    local out = { t = e.t, api = e.api, low = e.low, partial = e.part and true or false, rows = {} }
    for _, s in ipairs(e.l) do
        local r = ParseBid(s)
        if r then
            r.unit, r.ends = r.next / r.count, BidEnds(e.t, e.api, r.band)
            if r.ends > now then out.rows[#out.rows + 1] = r end
        end
    end
    return #out.rows > 0 and out or nil
end

function Prices.AllBids() return BidStore(false) or {} end

-- Drops the looks whose every auction has ended (at login).
function Prices.PruneBids(now)
    now = now or time()
    for _, realm in pairs(type(db().ahBids) == "table" and db().ahBids or {}) do
        for id, e in pairs(realm) do
            local live = false
            for _, s in ipairs(type(e) == "table" and type(e.l) == "table" and e.l or {}) do
                local r = ParseBid(s)
                if r and BidEnds(e.t, e.api, r.band) > now then live = true break end
            end
            if not live then realm[id] = nil end
        end
    end
end

-- The next bid the game takes on a legacy auction: the current bid plus
-- the increment, else the minimum bid.
local function LegacyNextBid(minBid, increment, bid)
    if type(bid) == "number" and bid > 0 then return bid + (type(increment) == "number" and increment or 0) end
    return type(minBid) == "number" and minBid > 0 and minBid or nil
end
Prices.LegacyNextBid = LegacyNextBid

-- "2 h ago", "3 days ago". src "auctionator": by day only ("today",
-- "yesterday", "3 days ago"), as Auctionator keeps it.
function Prices.Age(t, src)
    if not t then return "age unknown" end
    if src == "auctionator" then
        local days = math.floor((DayStart(0) - t) / 86400 + 0.5)
        return days <= 0 and "today" or (days == 1 and "yesterday" or (days .. " days ago"))
    end
    local s = math.max(0, time() - t)
    if s < 3600 then return math.max(1, math.floor(s / 60)) .. " min ago" end
    if s < 86400 then return math.floor(s / 3600) .. " h ago" end
    local d = math.floor(s / 86400)
    return d .. (d == 1 and " day ago" or " days ago")
end

---------------------------------------------------------------------------
-- Reading the Auction House
---------------------------------------------------------------------------
-- The last legacy query (any sender: the game's window, the AH helper, another
-- addon), from a hook on QueryAuctionItems: { text, page, exact, all, at }.
-- Pages of one exact search add up to one ladder: { text, id, rows, at }.
local PAGE_SIZE = 50
local lastQuery, pages, bidPages
local function HookQueries()
    if type(QueryAuctionItems) ~= "function" or type(hooksecurefunc) ~= "function" then return end
    hooksecurefunc("QueryAuctionItems", function(text, minLevel, maxLevel, page, usable, rarity, getAll, exact, filters)
        lastQuery = { text = type(text) == "string" and text or "", page = type(page) == "number" and page or 0,
            exact = exact and true or false, all = getAll and true or false, at = GetTime(),
            -- Any filter beyond the text: an empty answer then proves nothing about the item.
            filtered = (minLevel or maxLevel or usable or (rarity and rarity ~= -1 and rarity ~= 0) or filters) and true or false }
    end)
end
Prices.HookQueries = HookQueries
function Prices.LastQuery() return lastQuery end

-- Legacy list: up to 50 auctions per page; the lowest buyout per unit for
-- each item on the page.
local function ReadLegacyList()
    if type(GetNumAuctionItems) ~= "function" or type(GetAuctionItemInfo) ~= "function" then return 0 end
    local n, total = S.CallMulti(2, GetNumAuctionItems, "list")
    if type(n) == "number" and n <= 0 then
        -- A search for one item by its name that found nothing: none of its
        -- auctions is up, so the bids kept from an earlier look are gone too
        -- (as a full scan or an empty item result clears them).
        local q = lastQuery
        if q and not q.all and not q.filtered and (q.page or 0) == 0 and q.text ~= "" then
            local want = q.text:lower()
            for id, e in pairs(Realm(false) or {}) do
                if type(e) == "table" and type(e.name) == "string" and e.name:lower() == want then
                    Prices.RecordBids(id, {}, "legacy")
                end
            end
        end
        return 0
    end
    if type(n) ~= "number" then return 0 end
    -- A full scan's list (getAll): the AH helper reads it in chunks, and the
    -- game fires this event again for it as item info loads, during and after
    -- that read. Reading it here would read every row at once.
    if (lastQuery and lastQuery.all) or n > PAGE_SIZE or Prices.Bulk() then return 0 end
    local low, qty, auctions, names, rows, bids = {}, {}, {}, {}, {}, {}
    local only, freshID
    local me = Prices.PlayerName()
    for i = 1, n do
        local v = { S.CallMulti(17, GetAuctionItemInfo, "list", i) }
        local count, buyout, id = v[3], v[10], v[17]
        if type(id) == "number" and type(count) == "number" and count > 0 then
            -- Bid-only auctions count toward the supply, not the price.
            qty[id] = (qty[id] or 0) + count
            auctions[id] = (auctions[id] or 0) + 1
            names[id] = v[1]
            only = (only == nil or only == id) and id or false
            local owner = type(v[14]) == "string" and v[14] or nil
            rows[#rows + 1] = { (type(buyout) == "number" and buyout > 0) and buyout / count or nil, count, owner,
                me ~= nil and owner == me }
            local b = bids[id] or {}
            bids[id] = b
            if not (me ~= nil and owner == me) then
                local band = type(GetAuctionItemTimeLeft) == "function" and S.Call(GetAuctionItemTimeLeft, "list", i) or nil
                b[#b + 1] = { count, LegacyNextBid(v[8], v[9], v[11]), buyout, band,
                    v[12] == true or v[12] == 1, type(v[11]) == "number" and v[11] > 0 }
            end
            if type(buyout) == "number" and buyout > 0 then
                local unit = buyout / count
                if not low[id] or unit < low[id] then low[id] = unit end
            end
        end
    end
    -- One item on the page is that item's whole search only when the search
    -- had a single page or asked for that item by name: a broad search ("cloth")
    -- can have a page of Linen Cloth alone, and its total counts every item.
    local more = type(total) == "number" and total > n
    local q = lastQuery
    local named = q and only and (q.exact or (names[only] and q.text:lower() == tostring(names[only]):lower()))
    if only and (named or not more) then
        -- The game's total counts the whole query: that item's own auctions only
        -- for an exact search (a name search also finds "Bolt of Linen Cloth").
        if more then auctions[only] = (q and q.exact) and total or nil end
        -- Page by page: the ladder joins this page to the earlier ones of the same
        -- search. Each page once: the game fires this event again for a page as
        -- item info loads (and a page can be read again), which replaces it.
        local page = q and q.page or 0
        -- A new query for the first page starts over; the same query firing again does not.
        local queryAt = q and q.at
        if not (pages and pages.id == only and pages.text == (q and q.text) and GetTime() - pages.at < 300)
            or (page == 0 and pages.firstAt ~= queryAt) then
            pages = { id = only, text = q and q.text, byPage = {}, at = GetTime(), firstAt = page == 0 and queryAt or nil }
            -- A new search's first page: a new read of the item (Prices.Record's
            -- fresh). Only for a search the hook saw start: without it, a page
            -- cannot be told from a later page of the same search.
            freshID = (page == 0 and queryAt) and only or nil
        end
        pages.byPage[page], pages.at = rows, GetTime()
        local all = {}
        for _, list in pairs(pages.byPage) do
            for _, r in ipairs(list) do all[#all + 1] = r end
        end
        local partial = more and #all < total
        Prices.RecordLadder(only, all, partial, nil, true)
        -- The supply: every page of this search so far, not this page alone;
        -- unknown until the pages read cover every auction (a part read as the
        -- whole would look like units sold between two looks).
        local units = 0
        for _, r in ipairs(all) do units = units + (r[2] or 0) end
        qty[only] = (not partial) and units or nil
    end
    -- Other items of a search over several pages: this page holds part of
    -- their supply, so the count is unknown (a part read as the whole would
    -- look like units sold between two looks).
    if more then
        for id in pairs(qty) do
            if not (only and named and id == only) then qty[id], auctions[id] = nil, nil end
        end
    end
    -- Every item on the page: its bids. Pages of one search add up; a page
    -- read again (the list reloads after a bid) replaces what that page gave,
    -- or one auction whose bid changed would be kept twice. The look's time
    -- is its first page's, so the time left is never stretched by a re-read.
    -- Until every page of the search is read, the cheapest buyout of an item
    -- may be on a page not read: its bids are marked partial.
    local now = time()
    local qa = q and q.at
    -- A new query for the first page starts over; the same query firing again does not.
    if not (q and bidPages and bidPages.text == q.text and bidPages.exact == q.exact and now - bidPages.t <= 300)
        or ((q.page or 0) == 0 and bidPages.firstAt ~= qa) then
        bidPages = q and { text = q.text, exact = q.exact, t = now, firstAt = (q.page or 0) == 0 and qa or nil, byPage = {}, sizes = {} } or nil
    end
    if bidPages then
        local page = q.page or 0
        bidPages.byPage[page], bidPages.sizes[page] = bids, n
        local read = 0
        for _, size in pairs(bidPages.sizes) do read = read + size end
        local complete = not (type(total) == "number" and total > read)
        local merged = {}
        for _, list in pairs(bidPages.byPage) do
            for id, b in pairs(list) do
                local m = merged[id] or {}
                merged[id] = m
                for _, r in ipairs(b) do m[#m + 1] = r end
            end
        end
        for id, b in pairs(merged) do Prices.RecordBids(id, b, "legacy", bidPages.t, false, nil, not complete) end
    else
        for id, b in pairs(bids) do Prices.RecordBids(id, b, "legacy", now, false, nil, more or nil) end
    end
    local recorded = 0
    for id, unit in pairs(low) do
        Prices.Record(id, unit, qty[id], nil, auctions[id], names[id], nil, id == freshID)
        recorded = recorded + 1
    end
    return recorded
end

---------------------------------------------------------------------------
-- Full scan: every auction at once (legacy getAll, or C_AuctionHouse.
-- ReplicateItems). Thousands of rows: read in chunks over frames so the
-- game does not freeze; the lowest price and the whole supply per item.
---------------------------------------------------------------------------
local BULK_STEP = 500
local bulk

function Prices.Bulk() return bulk end

-- count(): rows; row(i) -> count, buyout, itemID, name, owner, bid; first: 0 or 1.
-- bid (optional): { next, band, high, bids, api } as for RecordBids, nil = the
-- auction cannot be bid on or is yours.
-- onFail(reason) when a chunk errors: the read stops instead of hanging.
function Prices.ReadBulk(count, row, first, onDone, onFail, onGrow)
    local total = count() or 0
    if type(total) ~= "number" then total = 0 end
    bulk = { i = first, last = first + total - 1, total = total, low = {}, qty = {}, auctions = {}, names = {}, rows = {},
        bids = {}, me = Prices.PlayerName(), onDone = onDone, clock = GetTime(),
        -- The legacy getAll list is whole auctions; the modern replicate list prices commodities by the unit.
        whole = first == 1 }
    local Step
    local function Chunk()
        local b = bulk
        if not b then return end
        b.clock = GetTime()
        -- The list changed under the read (window closed, a new query): what
        -- was read is not the whole Auction House. Stop; never record it as one.
        local still = count()
        -- More rows than at the start: the answer is still arriving (Forever
        -- sends a full scan in parts). Nothing is recorded yet: the caller
        -- reads again once the list stops growing.
        if onGrow and type(still) == "number" and still > b.total then
            bulk = nil
            onGrow(still)
            return
        end
        if still ~= b.total then
            bulk = nil
            if onFail then onFail(string.format("the list changed during the read (%d / %d)", b.i - first, b.total)) end
            return
        end
        local stop = math.min(b.last, b.i + BULK_STEP - 1)
        for i = b.i, stop do
            local cnt, buyout, id, name, owner, bid = row(i)
            if type(id) == "number" and type(cnt) == "number" and cnt > 0 then
                b.qty[id] = (b.qty[id] or 0) + cnt
                owner = type(owner) == "string" and owner or nil
                local list = b.rows[id] or {}
                b.rows[id] = list
                list[#list + 1] = { (type(buyout) == "number" and buyout > 0) and buyout / cnt or nil, cnt, owner,
                    b.me ~= nil and owner == b.me }
                b.auctions[id] = (b.auctions[id] or 0) + 1
                if type(name) == "string" then b.names[id] = name end
                -- Every auction not yours: those without a bid still set the cheapest buyout.
                if not (b.me ~= nil and owner == b.me) then
                    bid = type(bid) == "table" and bid or {}
                    b.api = bid[5] or b.api
                    local bl = b.bids[id] or {}
                    b.bids[id] = bl
                    bl[#bl + 1] = { cnt, bid[1], buyout, bid[2], bid[3], bid[4] }
                end
                if type(buyout) == "number" and buyout > 0 then
                    local unit = buyout / cnt
                    if not b.low[id] or unit < b.low[id] then b.low[id] = unit end
                end
            end
        end
        b.i = stop + 1
        if b.i <= b.last then
            if C_Timer and C_Timer.After then C_Timer.After(0, Step) else Step() end
            return
        end
        -- Proof of a real update: what the answer added or changed.
        local now, items, new, changed = time(), 0, 0, 0
        for id, unit in pairs(b.low) do
            local before = Prices.Entry(id)
            local oldP = before and before.p
            Prices.Record(id, unit, b.qty[id], now, b.auctions[id], b.names[id], nil, true)
            local e = Prices.Entry(id)
            if e then e.scan = now end
            Prices.RecordLadder(id, b.rows[id], false, now, b.whole)
            if not before then new = new + 1 elseif oldP ~= Exact(unit) then changed = changed + 1 end
            items = items + 1
        end
        -- The scan saw every auction: no row for an item = nothing to bid on.
        if b.api then Prices.ReplaceBids(b.bids, b.api, now) end
        bulk = nil
        if b.onDone then b.onDone(items, b.total, { new = new, changed = changed }) end
    end
    -- Chunks after the first run from timers: unprotected, an error there
    -- would leave the read half done forever.
    Step = function()
        local b = bulk
        if ns.SafeCall(Chunk) or bulk ~= b then return end
        bulk = nil
        if onFail then onFail(string.format("error while reading row %d of %d (" .. ns.Cmd.Text("errors") .. ")", math.min(b.i - first + 1, b.total), b.total)) end
    end
    Step()
end

-- Seconds since the running bulk read last moved, or nil.
function Prices.BulkIdle()
    return bulk and GetTime() - (bulk.clock or 0) or nil
end

function Prices.CancelBulk() bulk = nil end

-- Progress of a running bulk read: done, total.
function Prices.BulkProgress()
    if not bulk then return nil end
    return bulk.i - (bulk.last - bulk.total + 1), bulk.total
end

local function ItemIDOfKey(key)
    return type(key) == "table" and S.Value(key.itemID) or nil
end

-- Browse page: the lowest price per item the AH lists.
local function ReadBrowse(results)
    local AH = C_AuctionHouse
    if not results and type(AH) == "table" and type(AH.GetBrowseResults) == "function" then results = S.Call(AH.GetBrowseResults) end
    if type(results) ~= "table" then return 0 end
    local recorded = 0
    for _, r in ipairs(results) do
        local id = type(r) == "table" and ItemIDOfKey(r.itemKey)
        if id then
            -- [VERIFY] minPrice per unit for stacked vanilla items on Forever: flagged rough until then.
            Prices.Record(id, S.Value(r.minPrice), S.Value(r.totalQuantity), nil, nil, nil, true)
            recorded = recorded + 1
        end
    end
    return recorded
end

-- A commodity's listings: sorted cheapest first, unit prices.
local function ReadCommodity(id)
    local AH = C_AuctionHouse
    if type(id) ~= "number" or type(AH) ~= "table" or type(AH.GetCommoditySearchResultInfo) ~= "function" then return 0 end
    local n = type(AH.GetNumCommoditySearchResults) == "function" and S.Call(AH.GetNumCommoditySearchResults, id) or 0
    local low, qty, rows = nil, 0, 0
    -- A row whose quantity cannot be read makes the supply unknown, never 0.
    local known = true
    local ladder = {}
    for i = 1, (type(n) == "number" and n or 0) do
        local info = S.Call(AH.GetCommoditySearchResultInfo, id, i)
        local unit = type(info) == "table" and S.Value(info.unitPrice)
        if type(unit) == "number" and unit > 0 then
            if not low or unit < low then low = unit end
            local q = S.Value(info.quantity)
            if type(q) == "number" and q > 0 then qty = qty + q else known = false end
            -- A row can be several sellers: a name only when it is one.
            local owners = S.Value(info.owners)
            local owner = type(owners) == "table" and #owners == 1 and S.Value(owners[1]) or nil
            local mine = S.Value(info.numOwnerItems)
            if type(mine) ~= "number" then mine = S.Value(info.containsOwnerItem) == true end
            ladder[#ladder + 1] = { unit, type(q) == "number" and q or 0, type(owner) == "string" and owner or nil, mine }
            -- A row is one price; it says how many auctions make it up when it can.
            local count = S.Value(info.numAuctions) or S.Value(info.auctionCount)
            rows = rows + (type(count) == "number" and count or 1)
        end
    end
    if low then
        -- Part of the results: the lowest is right (cheapest first), the supply unknown.
        local full = type(AH.HasFullCommoditySearchResults) == "function" and S.Call(AH.HasFullCommoditySearchResults, id)
        local whole = type(AH.HasFullCommoditySearchResults) ~= "function" or full ~= false
        Prices.Record(id, low, (whole and known) and qty or nil, nil, whole and rows or nil, nil, nil, whole and known)
        Prices.RecordLadder(id, ladder, full == false or not known)
        return 1
    end
    return 0
end

-- An item's listings: buyout per auction, divided by its stack size.
local function ReadItemResults(key)
    local AH = C_AuctionHouse
    local id = ItemIDOfKey(key)
    if not id or type(AH) ~= "table" or type(AH.GetItemSearchResultInfo) ~= "function" then return 0 end
    local n = type(AH.GetNumItemSearchResults) == "function" and S.Call(AH.GetNumItemSearchResults, key) or 0
    local low, qty, rows, known = nil, 0, 0, true
    local ladder, bids = {}, {}
    local myGuid = S.Call(UnitGUID, "player")
    for i = 1, (type(n) == "number" and n or 0) do
        local info = S.Call(AH.GetItemSearchResultInfo, key, i)
        rows = rows + 1
        -- [VERIFY] minBid is the least the game takes as your next bid (Forever); bidder = the high bidder's GUID.
        if type(info) == "table" and S.Value(info.containsOwnerItem) ~= true then
            local cnt = S.Value(info.quantity)
            cnt = type(cnt) == "number" and math.max(1, cnt) or 1
            local band, bidder, bid = S.Value(info.timeLeft), S.Value(info.bidder), S.Value(info.bidAmount)
            bids[#bids + 1] = { cnt, S.Value(info.minBid), S.Value(info.buyoutAmount), type(band) == "number" and band + 1 or nil,
                type(bidder) == "string" and type(myGuid) == "string" and bidder == myGuid,
                (type(bidder) == "string" and bidder ~= "") or (type(bid) == "number" and bid > 0) }
        end
        local buyout = type(info) == "table" and S.Value(info.buyoutAmount)
        local count = type(info) == "table" and S.Value(info.quantity) or nil
        -- Supply counts every auction, bid-only ones too (as the full scan and the
        -- legacy list do): one definition of units across looks, or a bid-only
        -- stack read here and in a scan would look like units gone. A quantity
        -- that cannot be read makes the supply unknown.
        if type(count) == "number" and count > 0 then qty = qty + count else known = false end
        count = type(count) == "number" and math.max(1, count) or 1
        local unit = (type(buyout) == "number" and buyout > 0) and buyout / count or nil
        if unit and (not low or unit < low) then low = unit end
        local owners = type(info) == "table" and S.Value(info.owners)
        local owner = type(owners) == "table" and #owners == 1 and S.Value(owners[1]) or nil
        ladder[#ladder + 1] = { unit, count, type(owner) == "string" and owner or nil,
            type(info) == "table" and S.Value(info.containsOwnerItem) == true }
    end
    local hadBids = Prices.RecordBids(id, bids, "modern")
    if low then
        local full = type(AH.HasFullItemSearchResults) == "function" and S.Call(AH.HasFullItemSearchResults, key)
        local whole = type(AH.HasFullItemSearchResults) ~= "function" or full ~= false
        Prices.Record(id, low, (whole and known) and qty or nil, nil, whole and rows or nil, nil, nil, whole and known)
        Prices.RecordLadder(id, ladder, full == false or not known, nil, true)
        return 1
    end
    return hadBids and 1 or 0
end

---------------------------------------------------------------------------
-- Your listings as the Auction House shows them (its Auctions tab)
---------------------------------------------------------------------------
-- TALODDB.ahOwned["Name-Realm"] = { t, realm, list = { { id, name,
-- count, unit, bid, left, sold } } }: replaced whenever the game sends the
-- list (nothing is queried from here). left: seconds, or the legacy time
-- left as text.
local LEGACY_LEFT = { "under 30 min", "30 min - 2 h", "2 - 8 h", "over 8 h" }

local function SaveOwned(list)
    local key = ns.Gear and ns.Gear.CharKey and ns.Gear.CharKey()
    if not key then return end
    if type(db().ahOwned) ~= "table" then db().ahOwned = {} end
    db().ahOwned[key] = { t = time(), realm = Prices.RealmKey(), list = list }
    Bumped()
end

local function ReadOwnedLegacy()
    if type(GetNumAuctionItems) ~= "function" or type(GetAuctionItemInfo) ~= "function" then return 0 end
    local n = S.Call(GetNumAuctionItems, "owner")
    if type(n) ~= "number" then return 0 end
    local list = {}
    for i = 1, n do
        local v = { S.CallMulti(17, GetAuctionItemInfo, "owner", i) }
        local count, buyout, id = v[3], v[10], v[17]
        if type(id) == "number" and type(count) == "number" and count > 0 then
            local left = type(GetAuctionItemTimeLeft) == "function" and S.Call(GetAuctionItemTimeLeft, "owner", i) or nil
            list[#list + 1] = { id = id, name = type(v[1]) == "string" and v[1] or nil, count = count,
                -- Exact like the ladder's tiers, so the two compare on one basis.
                unit = (type(buyout) == "number" and buyout > 0) and Exact(buyout / count) or nil,
                bid = type(v[8]) == "number" and v[8] or nil, left = LEGACY_LEFT[left], sold = v[16] == 1 or nil }
        end
    end
    SaveOwned(list)
    return #list
end

local function ReadOwnedModern()
    local AH = C_AuctionHouse
    if type(AH) ~= "table" or type(AH.GetNumOwnedAuctions) ~= "function" or type(AH.GetOwnedAuctionInfo) ~= "function" then return 0 end
    local n = S.Call(AH.GetNumOwnedAuctions)
    if type(n) ~= "number" then return 0 end
    local list = {}
    for i = 1, n do
        local info = S.Call(AH.GetOwnedAuctionInfo, i)
        local id = type(info) == "table" and ItemIDOfKey(info.itemKey)
        local qty = type(info) == "table" and S.Value(info.quantity)
        if id and type(qty) == "number" and qty > 0 then
            local buyout = S.Value(info.buyoutAmount)
            -- buyoutAmount is the unit price: an auction of more than one is a commodity, priced per unit
            -- (Forever 2026-10-07: 87 fish posted for 957c read 11, 500 scales for 93500c read 187); an
            -- auction of one costs the same either way. Never divided by the quantity.
            local unit = (type(buyout) == "number" and buyout > 0) and math.floor(buyout + 0.5) or nil
            local secs = S.Value(info.timeLeftSeconds)
            list[#list + 1] = { id = id, count = qty, unit = unit, bid = S.Value(info.bidAmount),
                left = type(secs) == "number" and secs or nil, sold = S.Value(info.status) == 1 or nil }
        end
    end
    SaveOwned(list)
    return #list
end
Prices.ReadOwnedLegacy, Prices.ReadOwnedModern = ReadOwnedLegacy, ReadOwnedModern

-- A character's listings as the game last showed them (this auction
-- house only), or nil.
function Prices.Owned(key)
    local all = db().ahOwned
    local e = type(all) == "table" and all[key or (ns.Gear and ns.Gear.CharKey()) or ""] or nil
    if type(e) ~= "table" or (e.realm and e.realm ~= Prices.RealmKey()) then return nil end
    return e
end

Prices.ReadLegacyList, Prices.ReadBrowse, Prices.ReadCommodity, Prices.ReadItemResults = ReadLegacyList, ReadBrowse, ReadCommodity, ReadItemResults

local function OnEvent(event, ...)
    if not db().auctionPrices then return end
    local n = 0
    -- A full scan's list is read by the AH helper, in chunks.
    if event == "AUCTION_ITEM_LIST_UPDATE" and Prices.fullScanPending then return end
    if event == "AUCTION_ITEM_LIST_UPDATE" then
        n = ReadLegacyList()
    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
        n = ReadBrowse()
    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
        n = ReadBrowse((...))
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        n = ReadCommodity(S.Value((...)))
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
        n = ReadItemResults((...))
    elseif event == "AUCTION_OWNED_LIST_UPDATE" then
        n = ReadOwnedLegacy()
    elseif event == "OWNED_AUCTIONS_UPDATED" then
        n = ReadOwnedModern()
    end
    -- The windows showing prices redraw (once a second at most: a page per event).
    if n > 0 then ns.Data.Notify("prices") end
end

-- /talod price: the Auction House page on Prices. /talod price <name>: the
-- matches in chat, and Prices searching for it (the first match chosen).
local function Slash(command, rest)
    if command ~= "price" then return false end
    rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if rest == "" then
        if ns.MarketUI then ns.MarketUI.Toggle("prices") end
        return true
    end
    local needle, found = rest:lower(), 0
    for id in pairs(Prices.All()) do
        local name = ns.Market and ns.Market.ItemInfo(id) or tostring(id)
        if name:lower():find(needle, 1, true) and found < 8 then
            local p, t, src = Prices.Get(id)
            found = found + 1
            ns.Print(string.format("%s: %s each, %s%s", name, ns.Professions.Money(p), src == "auctionator" and "Auctionator, " or "", Prices.Age(t, src)))
        end
    end
    if found == 0 then ns.Print("\"" .. rest .. "\" not seen on the Auction House yet.") end
    if ns.MarketUI then ns.MarketUI.Show("prices", rest) end
    return true
end

---------------------------------------------------------------------------
-- Cleanup rules
---------------------------------------------------------------------------
-- Earlier looks older than the cutoff (`h` is in time order). The daily
-- summary `d` keeps the graph's long view.
-- keep (archive): key "Realm-Faction/itemID", value the removed looks (same string form as `h`).
local function TrimHistory(cutoff, apply, keep)
    local n = 0
    for rkey, realm in pairs(db().prices or {}) do
        for id, e in pairs(realm) do
            if type(e) == "table" and e.h then
                local looks, kept, gone = Prices.Looks(e), {}, {}
                for _, x in ipairs(looks) do
                    if x.t < cutoff then n = n + 1 gone[#gone + 1] = x else kept[#kept + 1] = x end
                end
                if apply and #kept < #looks then
                    if keep then keep(rkey .. "/" .. tostring(id), Prices.PackLooks(gone)) end
                    e.h = Prices.PackLooks(kept)
                end
            end
        end
    end
    return n
end

-- An item last seen before the cutoff: its price, ladder and bids go
-- together (a newer ladder or bid look keeps its own entry).
-- keep (archive): the price entry only (ladders and bids are the newest
-- look, not history): key "Realm-Faction/itemID", value "p;t;n;a;name;c;h;d".
local function DropUnseen(cutoff, apply, keep)
    local n = 0
    for _, key in ipairs({ "prices", "ladders", "ahBids" }) do
        for rkey, realm in pairs(db()[key] or {}) do
            local gone
            for id, e in pairs(realm) do
                if type(e) == "table" and (tonumber(e.t) or 0) < cutoff then
                    if key == "prices" then n = n + 1 end
                    if apply then
                        gone = gone or {}
                        gone[#gone + 1] = id
                        if keep and key == "prices" then
                            local h = type(e.h) == "string" and e.h or Prices.PackLooks(Prices.Looks(e))
                            keep(rkey .. "/" .. tostring(id), ns.Store.PackList({ e.p, e.t, e.n, e.a, e.name, e.c, h,
                                type(e.d) == "string" and e.d or nil }, 8, ";"))
                        end
                    end
                end
            end
            for _, id in ipairs(gone or {}) do realm[id] = nil end
        end
    end
    return n
end

ns.Cleanup.Add({ id = "priceHistory", label = "Price history", source = "prices",
    desc = "Each earlier Auction House look at an item (price, units listed). The latest look and the daily summary "
        .. "behind the price graph are kept.",
    days = 60, min = 15, max = 360, step = 15, archive = true, run = TrimHistory })
ns.Cleanup.Add({ id = "priceUnseen", label = "Items not seen on the Auction House", source = "prices",
    desc = "Every price, price ladder and bid of an item you have not seen listed for this long.",
    days = 180, min = 30, max = 720, step = 30, archive = true, run = DropUnseen })

ns.RegisterModule("Prices", {
    defaults = { auctionPrices = true, prices = {}, ladders = {}, ahOwned = {}, ahBids = {} },
    init = function() Prices.PruneBids() HookQueries() end,
    events = { "AUCTION_ITEM_LIST_UPDATE", "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
        "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED", "AUCTION_OWNED_LIST_UPDATE", "OWNED_AUCTIONS_UPDATED" },
    onEvent = OnEvent,
    slash = Slash,
})
