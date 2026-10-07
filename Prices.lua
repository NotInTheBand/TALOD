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
-- [itemID] = { t, l = "unit:qty[:mine],...", a, s, top, tn, my, part, bid,
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
local MAX_TIERS = 30         -- price tiers kept per ladder (a full scan writes thousands of ladders)

local function db() return ns.DB() end

function Prices.RealmKey()
    local realm = S.Call(GetRealmName)
    local faction = S.Call(UnitFactionGroup, "player")
    if type(realm) ~= "string" then return nil end
    return realm .. "-" .. (type(faction) == "string" and faction or "?")
end

local function Realm(create)
    local key = Prices.RealmKey()
    if not key then return nil end
    local all = db().prices
    if not all[key] and create then all[key] = {} end
    return all[key]
end

-- Days of a daily summary string: { [day] = { day, low, high, units } }.
local function ParseDays(d)
    local out = {}
    for day, lo, hi, n in (type(d) == "string" and d or ""):gmatch("(%d+):(%d+):(%d+):(%d+)") do
        day = tonumber(day)
        out[day] = { day, tonumber(lo), tonumber(hi), tonumber(n) }
    end
    return out
end

-- Folds one look into the daily summary: lowest, highest, most units that day.
local function FoldDay(d, t, p, n)
    local days = ParseDays(d)
    local day = math.floor(t / 86400)
    local e = days[day]
    if e then
        e[2], e[3], e[4] = math.min(e[2], p), math.max(e[3], p), math.max(e[4], n or 0)
    else
        days[day] = { day, p, p, n or 0 }
    end
    local order = {}
    for k in pairs(days) do order[#order + 1] = k end
    table.sort(order)
    local parts = {}
    for i = math.max(1, #order - MAX_DAYS + 1), #order do
        local x = days[order[i]]
        parts[#parts + 1] = x[1] .. ":" .. x[2] .. ":" .. x[3] .. ":" .. x[4]
    end
    return table.concat(parts, ",")
end

-- Every write here bumps the "prices" source (Data.lua): prices, ladders and
-- your listings. One results event or scan chunk writes hundreds, so they
-- Bump and the windows are told once (Data.Notify) when the batch is in.
local function Bumped() ns.Data.Bump("prices") end

-- One sighting: `unit` copper each, `qty` units in `auctions` auctions.
-- rough: the price comes from a browse row (not checked per unit).
function Prices.Record(id, unit, qty, now, auctions, name, rough)
    if not db().auctionPrices or type(id) ~= "number" or type(unit) ~= "number" or unit <= 0 then return end
    local realm = Realm(true)
    if not realm then return end
    Bumped()
    now = now or time()
    unit = math.floor(unit + 0.5)
    local e = realm[id]
    if type(name) ~= "string" or name == "" then name = e and e.name or nil end
    if e and now - e.t <= SESSION then
        e.p, e.t = math.min(e.p, unit), now
        e.n = math.max(e.n or 0, qty or 0)
        if auctions then e.a = math.max(e.a or 0, auctions) end
        e.name = name
        e.c = ns.Store.Me() or e.c
        -- One exact read in the look makes it exact.
        if not rough then e.b = nil end
        return e
    end
    local h = e and e.h or {}
    local d = e and e.d
    if e then
        h[#h + 1] = { e.t, e.p, e.n, e.a, e.c, e.b }
        while #h > MAX_HISTORY do table.remove(h, 1) end
        d = FoldDay(d, e.t, e.p, e.n)
    end
    e = { p = unit, t = now, n = qty or 0, a = auctions, name = name, h = #h > 0 and h or nil, d = d, c = ns.Store.Me(),
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
function Prices.History(id, mode)
    local e = Prices.Entry(id)
    if not e then return {} end
    local looks = {}
    for _, h in ipairs(e.h or {}) do looks[#looks + 1] = { t = h[1], p = h[2], n = h[3], a = h[4], c = h[5], b = h[6] and true or nil } end
    looks[#looks + 1] = { t = e.t, p = e.p, n = e.n, a = e.a, c = e.c, b = e.b and true or nil }
    if mode ~= "days" then return looks end
    local days = ParseDays(e.d)
    for _, pt in ipairs(looks) do
        local day = math.floor(pt.t / 86400)
        local x = days[day]
        if x then
            x[2], x[3], x[4] = math.min(x[2], pt.p), math.max(x[3], pt.p), math.max(x[4], pt.n or 0)
        else
            days[day] = { day, pt.p, pt.p, pt.n or 0 }
        end
    end
    local out = {}
    for day, x in pairs(days) do out[#out + 1] = { t = day * 86400 + 43200, day = day, p = x[2], hi = x[3], n = x[4] } end
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
-- true: all of them).
function Prices.RecordLadder(id, rows, partial, now)
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
                unit = math.floor(unit + 0.5)
                local mine = r[4] == true and qty or (type(r[4]) == "number" and math.min(qty, r[4]) or 0)
                local t = tiers[unit] or { 0, 0 }
                t[1], t[2] = t[1] + qty, t[2] + mine
                tiers[unit] = t
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
    for unit in pairs(tiers) do order[#order + 1] = unit end
    table.sort(order)
    local parts, more = {}, 0
    for i, unit in ipairs(order) do
        local t = tiers[unit]
        if i <= MAX_TIERS then
            parts[#parts + 1] = unit .. ":" .. t[1] .. (t[2] > 0 and (":" .. t[2]) or "")
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

-- { t, tiers = { { u, q, m } } cheapest first, units (with a buyout),
-- auctions, sellers, top, topName, mine, partial, bidOnly, more } or nil.
function Prices.Ladder(id)
    local store = Ladders(false)
    local e = store and store[id]
    if type(e) ~= "table" or type(e.l) ~= "string" then return nil end
    local out = { t = e.t, tiers = {}, units = 0, auctions = e.a, sellers = e.s, top = e.top, topName = e.tn,
        mine = e.my or 0, partial = e.part and true or false, bidOnly = e.bid or 0, more = e.more or 0 }
    for u, q, m in e.l:gmatch("(%d+):(%d+):?(%d*)") do
        local tier = { u = tonumber(u), q = tonumber(q), m = tonumber(m) or 0 }
        out.tiers[#out.tiers + 1] = tier
        out.units = out.units + tier.q
    end
    out.units = out.units + out.more
    return out
end

function Prices.AllLadders() return Ladders(false) or {} end

---------------------------------------------------------------------------
-- Bids: auctions whose next bid is under the item's lowest buyout
---------------------------------------------------------------------------
-- TALODDB.ahBids["Realm-Faction"][itemID] = { t, api, low, c, l =
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
-- the look instead of replacing it.
function Prices.RecordBids(id, rows, api, now, merge, store)
    if not db().auctionPrices or type(id) ~= "number" or type(rows) ~= "table" then return end
    store = store or BidStore(true)
    if not store then return end
    now = now or time()
    local list, seen, low = {}, {}, nil
    local old = store[id]
    if merge and type(old) == "table" and old.api == api and now - (old.t or 0) <= BID_MERGE then
        low = old.low
        for _, s in ipairs(type(old.l) == "table" and old.l or {}) do
            local r = ParseBid(s)
            if r and not seen[s] then seen[s] = true list[#list + 1] = r end
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
            if not seen[s] then seen[s] = true list[#list + 1] = row end
        end
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
    local e = { t = now, api = api, low = low and math.floor(low + 0.5) or nil, l = parts, c = ns.Store.Me() }
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
    local out = { t = e.t, api = e.api, low = e.low, rows = {} }
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
-- Legacy list: up to 50 auctions per page; the lowest buyout per unit for
-- each item on the page.
local function ReadLegacyList()
    if type(GetNumAuctionItems) ~= "function" or type(GetAuctionItemInfo) ~= "function" then return 0 end
    local n, total = S.CallMulti(2, GetNumAuctionItems, "list")
    if type(n) ~= "number" or n <= 0 then return 0 end
    local low, qty, auctions, names, rows, bids = {}, {}, {}, {}, {}, {}
    local only
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
    -- A search for one item: the total covers every page (the units only this one).
    if only and type(total) == "number" and total > n then auctions[only] = total end
    -- One item on the page (an exact search): its ladder; more pages = partial.
    if only then Prices.RecordLadder(only, rows, type(total) == "number" and total > n) end
    -- Every item on the page: its bids (the next page of the search adds to them).
    local now = time()
    for id, b in pairs(bids) do Prices.RecordBids(id, b, "legacy", now, true) end
    local recorded = 0
    for id, unit in pairs(low) do
        Prices.Record(id, unit, qty[id], nil, auctions[id], names[id])
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
function Prices.ReadBulk(count, row, first, onDone, onFail)
    local total = count() or 0
    if type(total) ~= "number" then total = 0 end
    bulk = { i = first, last = first + total - 1, total = total, low = {}, qty = {}, auctions = {}, names = {}, rows = {},
        bids = {}, me = Prices.PlayerName(), onDone = onDone, clock = GetTime() }
    local Step
    local function Chunk()
        local b = bulk
        if not b then return end
        b.clock = GetTime()
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
            Prices.Record(id, unit, b.qty[id], now, b.auctions[id], b.names[id])
            local e = Prices.Entry(id)
            if e then e.scan = now end
            Prices.RecordLadder(id, b.rows[id], false, now)
            if not before then new = new + 1 elseif oldP ~= math.floor(unit + 0.5) then changed = changed + 1 end
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
    local ladder = {}
    for i = 1, (type(n) == "number" and n or 0) do
        local info = S.Call(AH.GetCommoditySearchResultInfo, id, i)
        local unit = type(info) == "table" and S.Value(info.unitPrice)
        if type(unit) == "number" and unit > 0 then
            if not low or unit < low then low = unit end
            local q = S.Value(info.quantity)
            qty = qty + (type(q) == "number" and q or 0)
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
        Prices.Record(id, low, qty, nil, rows)
        local full = type(AH.HasFullCommoditySearchResults) == "function" and S.Call(AH.HasFullCommoditySearchResults, id)
        Prices.RecordLadder(id, ladder, full == false)
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
    local low, qty, rows = nil, 0, 0
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
        local count = type(info) == "table" and S.Value(info.quantity) or 1
        count = type(count) == "number" and math.max(1, count) or 1
        local unit = (type(buyout) == "number" and buyout > 0) and buyout / count or nil
        if unit then
            if not low or unit < low then low = unit end
            qty = qty + count
        end
        local owners = type(info) == "table" and S.Value(info.owners)
        local owner = type(owners) == "table" and #owners == 1 and S.Value(owners[1]) or nil
        ladder[#ladder + 1] = { unit, count, type(owner) == "string" and owner or nil,
            type(info) == "table" and S.Value(info.containsOwnerItem) == true }
    end
    local hadBids = Prices.RecordBids(id, bids, "modern")
    if low then
        Prices.Record(id, low, qty, nil, rows)
        local full = type(AH.HasFullItemSearchResults) == "function" and S.Call(AH.HasFullItemSearchResults, key)
        Prices.RecordLadder(id, ladder, full == false)
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
                unit = (type(buyout) == "number" and buyout > 0) and math.floor(buyout / count + 0.5) or nil,
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

-- /talod price: the Market window. /talod price <name>: the window searching
-- for it, and the matches in chat.
local function Slash(command, rest)
    if command ~= "price" then return false end
    rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if rest == "" then
        if ns.MarketUI then ns.MarketUI.Toggle() end
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

ns.RegisterModule("Prices", {
    defaults = { auctionPrices = true, prices = {}, ladders = {}, ahOwned = {}, ahBids = {} },
    init = function() Prices.PruneBids() end,
    events = { "AUCTION_ITEM_LIST_UPDATE", "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
        "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED", "AUCTION_OWNED_LIST_UPDATE", "OWNED_AUCTIONS_UPDATED" },
    onEvent = OnEvent,
    slash = Slash,
})
