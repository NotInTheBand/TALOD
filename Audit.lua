-- TALOD - Audit: a statistics ledger for your guild. The game keeps
-- counters on every character (its Statistics page): total gold acquired,
-- most gold ever owned, gold by source, auctions, quests, kills, dungeons,
-- profession ranks. Audit reads yours, a nearby player's on request (the
-- achievement comparison request: one per click or per Inspect), and those
-- guild members chose to share with officers (GuildSync category "stats");
-- keeps the last 20 looks per character; and flags records worth a second
-- look for bought gold.
--
-- The counters are the game's achievement statistics (IDs from its
-- Achievement table, checked on build Audit.DATA_BUILD). Another player's
-- come from the comparison request, a single slot the game shares between
-- every addon and its own achievement window: one request at a time, spaced,
-- given up after a while, and handed back the moment someone else takes it.
--
-- A flag is a reason to look, never a verdict. A missing counter never
-- raises or clears a flag (it shows "?"), shared figures come from the
-- member's own addon (inspected ones from the server), and nothing here
-- says where anyone's gold came from: only which counters do not add up.
--
-- Records are keyed by the server's full name ("First Surname-Realm"), the
-- guild roster's key, so an inspect and a member's shared look meet. Each
-- look names the character of yours that took or received it (`by`, a
-- Store.lua character number).
--
-- Shared looks are their addon's word; inspected ones are the server's. When
-- both exist, a shared figure the server contradicts (a counter that only
-- goes up, lower in a later inspect or higher than an earlier one) raises
-- the "claim" flag.

local ADDON_NAME, ns = ...
local S = ns.Secret
local Guild = ns.Guild
local Data = ns.Data

local Audit = {}
ns.Audit = Audit

local MAX_SNAPS = 20
local REQUEST_GAP = 5
local REQUEST_TIMEOUT = 15
local JUMP_DAYS = 14          -- two looks this close: a jump between them counts
local SELF_EVERY = 6 * 3600   -- an unchanged self look is saved again after this
local GOLD = 10000

Audit.DATA_BUILD = "1.60.1.70124"
Audit.DISCLAIMER = "Figures may be incomplete or out of date, and counters can reset. A flag is a reason to look, not proof of anything."

-- Statistic IDs by section. Audit.FIELDS lists them as { key, statistic ID,
-- label, money, highest-recorded profession rank } (the window reads that).
local MONEY = {
    { "acquired", 328, "Total gold acquired" }, { "peak", 334, "Most gold ever owned" },
    { "looted", 333, "Gold looted" }, { "quests", 326, "Quest rewards" }, { "vendors", 921, "Vendor sales" },
    { "auctions", 919, "Auction earnings" }, { "daily", 753, "Average earned per day" },
    { "travel", 1146, "Travel" }, { "postage", 1148, "Postage" }, { "barber", 1147, "Barber shops" },
    { "respec", 1150, "Talent respecs" },
    { "largestSale", 332, "Largest auction sale" }, { "largestBid", 331, "Largest auction bid" },
}
local COUNTS = {
    { "posted", 329, "Auctions posted" }, { "purchases", 330, "Auction purchases" },
    { "questCount", 98, "Quests completed" }, { "kills", 107, "Creatures killed" }, { "dungeons", 932, "Dungeons entered" },
    { "deaths", 60, "Total deaths" }, { "disenchanted", 181, "Items disenchanted" },
    { "disenchantMaterials", 183, "Disenchant materials" }, { "fishCaught", 1518, "Fish caught" },
    { "flights", 349, "Flight paths taken" }, { "honorableKills", 588, "Honorable kills" },
}
-- Secondary skills report the current rank; primary professions the highest
-- rank ever reached (it stays after the profession is dropped).
local SKILLS = {
    { "firstAid", 281, "First Aid" }, { "cooking", 1524, "Cooking" }, { "fishing", 1519, "Fishing" },
}
local PRIMARY = {
    { "alchemy", 1527, "Alchemy" }, { "blacksmithing", 1532, "Blacksmithing" }, { "enchanting", 1535, "Enchanting" },
    { "leatherworking", 1536, "Leatherworking" }, { "mining", 1537, "Mining" }, { "herbalism", 1538, "Herbalism" },
    { "skinning", 1541, "Skinning" }, { "tailoring", 1542, "Tailoring" }, { "engineering", 1544, "Engineering" },
}
Audit.FIELDS = {}
for _, section in ipairs({ { MONEY, true }, { COUNTS }, { SKILLS }, { PRIMARY, false, true } }) do
    for _, e in ipairs(section[1]) do
        Audit.FIELDS[#Audit.FIELDS + 1] = { e[1], e[2], e[3], section[2] or nil, section[3] }
    end
end
Audit.BY_KEY = {}
for _, f in ipairs(Audit.FIELDS) do Audit.BY_KEY[f[1]] = f end

Audit.GOLD_KEYS = { "acquired", "peak", "looted", "quests", "vendors", "auctions", "daily", "largestSale", "largestBid",
    "travel", "postage", "barber", "respec", "posted", "purchases" }
Audit.ACTIVITY_KEYS = { "questCount", "kills", "dungeons", "honorableKills", "deaths", "disenchanted",
    "disenchantMaterials", "fishCaught", "flights" }
Audit.PROFESSION_KEYS = { "firstAid", "cooking", "fishing", "alchemy", "blacksmithing", "enchanting", "leatherworking",
    "mining", "herbalism", "skinning", "tailoring", "engineering" }
-- Income the game breaks out by source; the rest of "Total gold acquired"
-- came some other way (trade, mail, ...).
Audit.SOURCE_KEYS = { "looted", "quests", "vendors", "auctions" }

Audit.REASONS = {
    notReported = "No value came back for this counter. Unknown, not zero.",
    unsupported = "This counter does not exist on this client.",
    skipped = "The game hides this counter.",
    unreadable = "The value that came back could not be read.",
    error = "Reading this counter failed.",
    api = "This client cannot read statistics.",
    notShared = "Not in what the member shared.",
}

local function db() return ns.DB() end

local function Store()
    local a = db().audit
    if type(a) ~= "table" then a = {} db().audit = a end
    if type(a.chars) ~= "table" then a.chars = {} end
    return a
end

local function Now()
    local t = S.Call(GetServerTime)
    return type(t) == "number" and t or time()
end

function Audit.Build()
    local version, build = S.CallMulti(2, GetBuildInfo)
    return tostring(version or "?") .. "." .. tostring(build or "?")
end

-- The statistic IDs were checked on Forever only; Classic Era has no
-- achievement statistics at all.
function Audit.Supported()
    return ns.IS_FOREVER == true and type(GetStatistic) == "function"
end

---------------------------------------------------------------------------
-- Reading the game's numbers
---------------------------------------------------------------------------
local MAX_EXACT = 2 ^ 53

-- A plain, known, non-negative number, else nil.
local function Number(v)
    if S.IsSecret(v) then return nil end
    v = tonumber(v)
    if v == nil or v ~= v or v < 0 or v > MAX_EXACT then return nil end
    return v
end
Audit.Number = Number

-- Whole number from text that may group thousands ("12,345", "12.345",
-- "12 345", with any space the game uses). A separator has to cut the digits
-- into threes, so "1.5" or "12,34" is not read as a number at all.
local function Digits(text)
    text = text:gsub("\194\160", " "):gsub("\226\128\175", " ")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text:find("^%d+$") then return Number(text) end
    local head, sep = text:match("^(%d+)([,%. ])")
    if not head or #head > 3 then return nil end
    local escaped = "%" .. sep
    if text:sub(#head + 1):gsub(escaped .. "%d%d%d", "") ~= "" then return nil end
    return Number((text:gsub(escaped, "")))
end

-- The coin a texture or atlas escape draws, in copper (nil: not a coin).
local COINS = { gold = 10000, silver = 100, copper = 1 }
local function CoinValue(escape)
    escape = escape:lower():gsub("\\", "/")
    local metal = escape:match("moneyframe/ui%-(%a+)icon") or escape:match("^:?coin%-(%a+)")
    return metal and COINS[metal]
end

-- Copper from the game's money text: amounts each followed by a coin icon,
-- gold before silver before copper, silver and copper under 100. Anything
-- else (an unknown icon, stray text, a wrong order) is not a sum: nil.
function Audit.ParseMoney(raw)
    local plain = Number(raw)
    if plain then return plain % 1 == 0 and plain or nil end
    if type(raw) ~= "string" or #raw > 400 then return nil end
    local rest = raw:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    local parts = {}
    while true do
        local a, b, _, inner = rest:find("|([TA])(.-)|[ta]")
        if not a then break end
        parts[#parts + 1] = { amount = rest:sub(1, a - 1), coin = CoinValue(inner) }
        rest = rest:sub(b + 1)
    end
    if #parts == 0 or not rest:find("^%s*$") then return nil end
    local total, previous = 0, math.huge
    for _, part in ipairs(parts) do
        local n = Digits(part.amount)
        if not (n and part.coin) or part.coin >= previous or (part.coin < 10000 and n >= 100) then return nil end
        total, previous = total + n * part.coin, part.coin
    end
    return Number(total)
end

-- A counter's raw value: its number, or (nil, text) when it holds digits in
-- a form not understood (shown as it came, never added up), or nil.
function Audit.Entry(raw, money)
    if S.IsSecret(raw) then return nil end
    local n
    if money then
        n = Audit.ParseMoney(raw)
    elseif type(raw) == "string" then
        n = Digits(raw)
    else
        n = Number(raw)
        if n and n % 1 ~= 0 then n = nil end
    end
    if n then return n end
    if type(raw) == "string" and #raw <= 400 and raw:find("%d") then
        return nil, (raw:gsub("|", "||"):gsub("%c", " "))
    end
    return nil
end

function Audit.Gold(copper)
    if copper == nil then return "?" end
    copper = math.floor(copper)
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local gs = tostring(g):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    if g > 0 then return gs .. "g" .. (s > 0 and (" " .. s .. "s") or "") end
    if s > 0 then return s .. "s" .. (c > 0 and (" " .. c .. "c") or "") end
    return c .. "c"
end

function Audit.Count(n)
    if n == nil then return "?" end
    return (string.format("%.0f", math.floor(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

---------------------------------------------------------------------------
-- Looks (snapshots)
--   { t, build, src = "self"/"inspect"/"shared", level, guild, n (counters
--     read), v = { [key] = number }, d = { [key] = display text },
--     miss = { [key] = reason }, wallet (self only) }
---------------------------------------------------------------------------
function Audit.V(snap, key) return snap and snap.v and snap.v[key] or nil end

function Audit.Value(snap, key)
    local n = Audit.V(snap, key)
    if n ~= nil then
        local f = Audit.BY_KEY[key]
        return f and f[4] and Audit.Gold(n) or Audit.Count(n)
    end
    return snap and snap.d and snap.d[key] or nil
end

function Audit.Reason(snap, key)
    return Audit.REASONS[snap and snap.miss and snap.miss[key] or ""] or "No readable value was captured; this is not a confirmed zero."
end

-- Sum of the income the game breaks out by source; nil if any is unknown.
function Audit.SourceSum(snap)
    local sum = 0
    for _, key in ipairs(Audit.SOURCE_KEYS) do
        local n = Audit.V(snap, key)
        if n == nil then return nil end
        sum = sum + n
    end
    return sum
end

-- Income not from loot, quests, vendors or auctions; nil when unknown.
function Audit.Other(snap)
    local acq, sum = Audit.V(snap, "acquired"), Audit.SourceSum(snap)
    if acq == nil or sum == nil then return nil end
    return math.max(0, acq - sum)
end

-- Peak gold above all recorded income: gold the counters did not see.
function Audit.Gap(snap)
    local peak, acq = Audit.V(snap, "peak"), Audit.V(snap, "acquired")
    if peak == nil or acq == nil then return nil end
    return math.max(0, peak - acq)
end

-- One counter -> value, display text, reason it is missing.
local function ReadOne(getter, field)
    local exists = C_AchievementInfo and C_AchievementInfo.IsValidAchievement
    if type(exists) == "function" then
        local ok, yes = pcall(exists, field[2])
        if not (ok and S.Value(yes)) then return nil, nil, "unsupported" end
    end
    if type(getter) ~= "function" then return nil, nil, "api" end
    local ok, raw, hidden = pcall(getter, field[2])
    if not ok then return nil, nil, "error" end
    if S.IsSecret(raw) then return nil, nil, "unreadable" end
    if S.Value(hidden) then return nil, nil, "skipped" end
    local n, display = Audit.Entry(raw, field[4])
    if n or display then return n, display end
    local empty = raw == nil or raw == "" or raw == "-" or raw == "--"
    return nil, nil, empty and "notReported" or "unreadable"
end

-- Every counter: your own (GetStatistic) or those of the player the last
-- comparison request answered for (GetComparisonStatistic).
function Audit.ReadCounters(own)
    local getter = own and GetStatistic or GetComparisonStatistic
    local s = { t = Now(), build = Audit.Build(), src = own and "self" or "inspect", v = {}, d = {}, miss = {}, n = 0 }
    for _, f in ipairs(Audit.FIELDS) do
        local n, display, why = ReadOne(getter, f)
        s.v[f[1]], s.d[f[1]], s.miss[f[1]] = n, display, why
        if not why then s.n = s.n + 1 end
    end
    if own then s.wallet = Number(S.Call(GetMoney)) end
    return s
end

local function SameValues(a, b)
    if not (a and b) or a.wallet ~= b.wallet then return false end
    for _, f in ipairs(Audit.FIELDS) do
        if a.v[f[1]] ~= b.v[f[1]] then return false end
    end
    return true
end

-- Who a unit is, for the record: { full, guid, classFile, level, guild }.
function Audit.Subject(unit)
    if not S.Call(UnitExists, unit) then return nil end
    local own = S.Call(UnitIsUnit, unit, "player") == true
    if not own and S.Call(UnitIsPlayer, unit) ~= true then return nil end
    local full = own and Guild.Me() or Guild.FullName(S.CallMulti(2, UnitFullName or UnitName, unit))
    if not full then return nil end
    local _, classFile = S.CallMulti(2, UnitClass, unit)
    local level = S.Call(UnitLevel, unit)
    local guild = GetGuildInfo and S.CallMulti(1, GetGuildInfo, unit)
    return { full = full, guid = S.Call(UnitGUID, unit), classFile = classFile, own = own,
        level = type(level) == "number" and level > 0 and level or nil, guild = type(guild) == "string" and guild or nil }
end

function Audit.Record(full) return Store().chars[full] end
function Audit.Records() return Store().chars end
function Audit.Latest(c) return c and c.snaps and c.snaps[#c.snaps] or nil end

-- Stores a look; false when it adds nothing (no counters, or a duplicate).
function Audit.Save(info, snap)
    if not (info and info.full and snap) or (snap.n == 0 and snap.wallet == nil) then return false end
    snap.level = snap.level or info.level
    snap.guild = snap.guild or info.guild
    snap.by = snap.by or ns.Store.Me()
    local chars = Store().chars
    local c = chars[info.full]
    if not c then
        c = { first = snap.t, snaps = {} }
        chars[info.full] = c
    end
    for _, old in ipairs(c.snaps) do
        if old.t == snap.t and old.src == snap.src then return false end
    end
    -- An unchanged look from the same source adds nothing (your own is
    -- read at every login): keep the newer time on the old one instead,
    -- unless SELF_EVERY passed (a dated "still the same" line in History).
    local last = c.snaps[#c.snaps]
    if last and last.src == snap.src and SameValues(last, snap) and snap.t - last.t < SELF_EVERY then
        last.seen = snap.t
        Data.Changed("audit")
        return false
    end
    table.insert(c.snaps, snap)
    table.sort(c.snaps, function(a, b) return a.t < b.t end)
    while #c.snaps > MAX_SNAPS do table.remove(c.snaps, 1) end
    c.guid = info.guid or c.guid
    c.classFile = info.classFile or c.classFile
    c.own = info.own or c.own
    c.first = math.min(c.first or snap.t, snap.t)
    local latest = c.snaps[#c.snaps]
    c.last, c.level, c.guild = latest.t, latest.level or c.level, latest.guild or c.guild
    Data.Changed("audit")
    return true
end

-- Your own counters, read now and saved (they are local: no request).
function Audit.ReadSelf()
    if not Audit.Supported() then return nil end
    local info = Audit.Subject("player")
    if not info then return nil end
    local snap = Audit.ReadCounters(true)
    Audit.Save(info, snap)
    return snap, info
end

function Audit.Delete(full)
    Store().chars[full] = nil
    Data.Changed("audit")
end

---------------------------------------------------------------------------
-- Activity: what the counters show of play, area by area. Gold never counts,
-- and a counter that could not be read is unknown, never zero.
---------------------------------------------------------------------------
-- Each area reads "none", "some" or "plenty" from its counters (the best
-- one wins). Questing, fighting and dungeons are adventuring: a played
-- character shows them; professions or the auction house alone are what a
-- crafter or a bank alt shows. "rank" is the highest profession rank.
local AREAS = {
    { key = "questing", adventure = true, some = { questCount = 1 }, plenty = { questCount = 25 } },
    { key = "fighting", adventure = true, some = { kills = 1, honorableKills = 1 }, plenty = { kills = 200, honorableKills = 10 } },
    { key = "dungeons", adventure = true, some = { dungeons = 1 }, plenty = { dungeons = 3 } },
    { key = "crafting", some = { rank = 2, disenchanted = 1 }, plenty = { rank = 75, disenchanted = 30 } },
    { key = "fishing", some = { fishCaught = 1 }, plenty = { fishCaught = 50 } },
    { key = "trading", some = { posted = 1, purchases = 1 }, plenty = { posted = 25, purchases = 25 } },
}
Audit.ASSESSMENT_RULES = "Six areas: questing (25 quests), fighting (200 kills or 10 honorable kills), dungeons (3), "
    .. "crafting (a profession at 75 or 30 disenchants), fishing (50 fish), trading (25 auctions posted or bought). "
    .. "Active play: two adventuring areas there (questing, fighting, dungeons), or one and three areas in all."

function Audit.Assess(snap)
    local values, known, total = {}, 0, 0
    local function read(key)
        local n = Audit.V(snap, key)
        total = total + 1
        if n ~= nil then known = known + 1 end
        return n
    end
    for _, key in ipairs({ "questCount", "kills", "honorableKills", "dungeons", "disenchanted", "fishCaught", "posted", "purchases" }) do
        values[key] = read(key)
    end
    for _, key in ipairs(Audit.PROFESSION_KEYS) do
        local r = read(key)
        if r and r > (values.rank or 0) then values.rank = r end
    end
    local function reaches(limits)
        for key, limit in pairs(limits) do
            if values[key] ~= nil and values[key] >= limit then return true end
        end
        return false
    end
    local some, plenty, adventure, specialist = 0, 0, 0, false
    for _, area in ipairs(AREAS) do
        if reaches(area.plenty) then
            plenty, some = plenty + 1, some + 1
            if area.adventure then adventure = adventure + 1 end
            if area.key == "crafting" or area.key == "trading" then specialist = true end
        elseif reaches(area.some) then
            some = some + 1
        end
    end
    local out
    if known == 0 then
        out = { key = "unknown", title = "Not enough data", summary = "No readable activity counters." }
    elseif adventure >= 2 or (adventure == 1 and plenty >= 3) then
        out = { key = "active", title = "Active play", summary = "Plenty of activity in " .. plenty .. " of " .. #AREAS .. " areas." }
    elseif specialist and adventure == 0 then
        out = { key = "specialist", title = "Crafting / trading profile",
            summary = "Professions or the auction house, little adventuring: a crafter or a bank alt looks like this." }
    elseif some > 0 then
        out = { key = "some", title = "Some activity", summary = "Activity in " .. some .. " of " .. #AREAS .. " areas, not much of it." }
    else
        out = { key = "limited", title = "Little play recorded",
            summary = "The counters show little activity. A new character or a bank alt looks like this." }
    end
    out.coverage = known .. " / " .. total .. " counters readable"
    out.known, out.total, out.positive, out.meaningful = known, total, some, plenty
    return out
end

---------------------------------------------------------------------------
-- Flags: counters that do not add up the way played gold does
---------------------------------------------------------------------------
-- Peak gold that stands out for a level below 55 (a guide, not a rule:
-- auction players and alts fed by a main also get here).
local LEVEL_CEILING = { { 10, 10 }, { 20, 40 }, { 30, 120 }, { 40, 300 }, { 50, 700 }, { 55, 1200 } }
function Audit.LevelCeiling(level)
    if type(level) ~= "number" or level >= 55 then return nil end
    local prev = { 1, LEVEL_CEILING[1][2] }
    for _, p in ipairs(LEVEL_CEILING) do
        if level <= p[1] then
            local f = (p[1] == prev[1]) and 1 or (level - prev[1]) / (p[1] - prev[1])
            return (prev[2] + (p[2] - prev[2]) * f) * GOLD
        end
        prev = p
    end
end

local function Setting(key, fallback)
    local v = db() and db()[key]
    return type(v) == "number" and v or fallback
end

-- Jumps between two looks within JUMP_DAYS: income from other sources (or
-- peak gold beyond all new income) that rose by at least the threshold.
local function Jumps(c, threshold)
    local out = {}
    local snaps = c.snaps or {}
    for i = 2, #snaps do
        local a, b = snaps[i - 1], snaps[i]
        local days = (b.t - a.t) / 86400
        local da = (Audit.V(b, "acquired") or -1) - (Audit.V(a, "acquired") or 0)
        -- A drop in total acquired is a reset or another build: no comparison.
        if days > 0 and days <= JUMP_DAYS and Audit.V(a, "acquired") and Audit.V(b, "acquired") and da >= 0 then
            local oa, ob = Audit.Other(a), Audit.Other(b)
            local dOther = (oa and ob) and (ob - oa) or nil
            local dPeak = (Audit.V(a, "peak") and Audit.V(b, "peak")) and (Audit.V(b, "peak") - Audit.V(a, "peak")) or nil
            local sa, sb = Audit.SourceSum(a), Audit.SourceSum(b)
            local dSources = (sa and sb) and (sb - sa) or nil
            local peakOver = dPeak and dSources and (dPeak - dSources) or nil
            local amount = math.max(dOther or 0, peakOver or 0)
            if amount >= threshold then
                out[#out + 1] = { from = a, to = b, days = days, other = dOther, peak = dPeak, sources = dSources, amount = amount }
            end
        end
    end
    return out
end

-- Counters that only go up (until a reset, which comes with another build).
local RISING = {}
for _, k in ipairs(Audit.GOLD_KEYS) do RISING[k] = true end
for _, k in ipairs(Audit.ACTIVITY_KEYS) do RISING[k] = true end
RISING.daily = nil            -- an average, not a counter
local CLOCK_SKEW = 600        -- a shared look's time is the sender's clock: pairs this close are not ordered

-- Shared looks the server contradicts: { shared, inspect, key, sv, iv }, one per pair of looks.
function Audit.Contradictions(c)
    local out = {}
    local snaps = c and c.snaps or {}
    for _, s in ipairs(snaps) do
        if s.src == "shared" then
            for _, i in ipairs(snaps) do
                local gap = i.src == "inspect" and i.build == s.build and math.abs(i.t - s.t) or nil
                if gap and gap > CLOCK_SKEW and gap <= JUMP_DAYS * 86400 then
                    for _, f in ipairs(Audit.FIELDS) do
                        local key = f[1]
                        local sv, iv = Audit.V(s, key), Audit.V(i, key)
                        if RISING[key] and sv and iv and ((i.t > s.t and iv < sv) or (i.t < s.t and sv < iv)) then
                            out[#out + 1] = { shared = s, inspect = i, key = key, sv = sv, iv = iv }
                            break
                        end
                    end
                end
            end
        end
    end
    return out
end

-- { level = "look" / "watch" / "none" / "unknown", score, list = { { key,
-- weight, title, text } }, keys = "a,b", checked (rules that had data) }.
-- "none" only when every rule could be checked; otherwise "unknown".
function Audit.Flags(c)
    local snap = Audit.Latest(c)
    local out = { list = {}, score = 0, checked = 0, rules = 5 }
    if not snap then out.level = "unknown" return out end
    local function add(key, weight, title, text)
        out.list[#out.list + 1] = { key = key, weight = weight, title = title, text = text }
        out.score = out.score + weight
    end
    local G = Audit.Gold

    local gap = Audit.Gap(snap)
    if gap ~= nil then
        out.checked = out.checked + 1
        if gap >= Setting("auditGapGold", 25) * GOLD then
            add("gap", 2, "Peak above recorded income", "Most gold ever owned (" .. G(Audit.V(snap, "peak")) .. ") is " .. G(gap)
                .. " more than all gold the counters saw come in (" .. G(Audit.V(snap, "acquired")) .. "). Gold the counters "
                .. "leave out reached them (trades or mail, if the game does not count those).")
        end
    end

    local other, acq = Audit.Other(snap), Audit.V(snap, "acquired")
    if other ~= nil then
        out.checked = out.checked + 1
        local share = acq > 0 and other / acq or 0
        if other >= Setting("auditOtherGold", 250) * GOLD and share * 100 >= Setting("auditOtherShare", 50) then
            add("other", 2, "Income from other sources", G(other) .. " of " .. G(acq) .. " acquired (" .. math.floor(share * 100 + 0.5)
                .. "%) came from neither loot, quests, vendors nor auctions: trades, mail and the like.")
        end
    end

    if #(c.snaps or {}) >= 2 then
        out.checked = out.checked + 1
        local jumps = Jumps(c, Setting("auditJumpGold", 100) * GOLD)
        for _, j in ipairs(jumps) do
            add("jump:" .. j.to.t, 3, "Sudden gold", G(j.amount) .. " that loot, quests, vendors and auctions do not explain, between "
                .. date("%b %d", j.from.t) .. " and " .. date("%b %d", j.to.t) .. string.format(" (%.1f days)", j.days) .. ".")
        end
    else
        out.rules = out.rules - 1   -- needs two looks: not counted as unchecked
    end

    local level = snap.level or c.level
    local peak = Audit.V(snap, "peak")
    if peak ~= nil and level then
        out.checked = out.checked + 1
        local ceiling = Audit.LevelCeiling(level)
        if ceiling and peak >= ceiling and db().auditLevelRule ~= false then
            add("level", 1, "Rich for the level", "Most gold ever owned " .. G(peak) .. " at level " .. level
                .. " (the guide for this level is " .. G(ceiling) .. "). Auction players and alts fed by a main get here too.")
        end
    end

    local a = Audit.Assess(snap)
    if peak ~= nil and a.key ~= "unknown" then
        out.checked = out.checked + 1
        -- Activity in one area at most: a level-20 with quests and kills is just playing.
        if peak >= 100 * GOLD and (a.key == "limited" or (a.key == "some" and a.positive <= 1)) then
            add("thin", 1, "Gold without much play", "Most gold ever owned " .. G(peak) .. " with " .. a.title:lower()
                .. " (" .. a.coverage .. "). Bank alts look like this too.")
        end
    end

    -- Checked only where both kinds of look exist: not counted among the rules.
    for _, x in ipairs(Audit.Contradictions(c)) do
        local f = Audit.BY_KEY[x.key]
        local fmt = function(n) return f[4] and G(n) or Audit.Count(n) end
        add("claim:" .. x.shared.t, 3, "Shared figures the server contradicts", f[3] .. ": their addon shared " .. fmt(x.sv)
            .. " on " .. date("%b %d", x.shared.t) .. ", the server showed " .. fmt(x.iv) .. " on " .. date("%b %d", x.inspect.t)
            .. ". This counter only goes up, so the shared figure was not the game's.")
    end

    table.sort(out.list, function(x, y) return x.weight > y.weight end)
    local keys = {}
    for _, f in ipairs(out.list) do keys[#keys + 1] = f.key end
    table.sort(keys)
    out.keys = table.concat(keys, ",")
    if out.score >= 2 then out.level = "look"
    elseif out.score >= 1 then out.level = "watch"
    elseif out.checked >= out.rules then out.level = "none"
    else out.level = "unknown" end
    -- A review covers the flags it saw; a new one (a new jump) reopens it.
    local r = c.review
    out.reviewed = false
    if r and r.state == "ok" and #out.list > 0 then
        local seen = {}
        for k in (r.keys or ""):gmatch("[^,]+") do seen[k] = true end
        out.reviewed = true
        for _, f in ipairs(out.list) do if not seen[f.key] then out.reviewed = false end end
    end
    return out
end

-- Flags of a record, kept until the data or the thresholds change.
function Audit.FlagsOf(full)
    local c = Audit.Record(full)
    if not c then return nil end
    local key = Data.Key("audit") .. "|" .. Setting("auditGapGold", 25) .. ":" .. Setting("auditOtherGold", 250) .. ":"
        .. Setting("auditOtherShare", 50) .. ":" .. Setting("auditJumpGold", 100) .. ":" .. tostring(db().auditLevelRule)
    local all = Data.Memo("audit:flags", key, function() return {} end)
    all[full] = all[full] or Audit.Flags(c)
    return all[full]
end

-- An officer's review: "ok" (looked, fine: hides the flags it covers),
-- "watch" (keep an eye on it), nil (clear).
function Audit.SetReview(full, state, note)
    local c = Audit.Record(full)
    if not c then return false end
    if state == nil then
        c.review = nil
    else
        local f = Audit.Flags(c)
        c.review = { state = state, note = note or (c.review and c.review.note), by = Guild.Me(), t = time(), keys = f.keys }
    end
    Data.Changed("audit")
    return true
end

function Audit.SetNote(full, note)
    local c = Audit.Record(full)
    if not c then return false end
    c.review = c.review or {}
    c.review.note = (note and note ~= "") and note:sub(1, 200) or nil
    if not c.review.state and not c.review.note then c.review = nil end
    Data.Changed("audit")
    return true
end

---------------------------------------------------------------------------
-- Lists for the window
---------------------------------------------------------------------------
-- Is this name in your guild's roster now?
function Audit.IsMember(full)
    local g = Guild.Mine() and Guild.Data()
    local m = g and g.members[full]
    return m ~= nil and not m.missing, m
end

-- Every record: { full, c, snap, flags, member }.
function Audit.Rows()
    local out = {}
    for full, c in pairs(Store().chars) do
        local snap = Audit.Latest(c)
        if snap then
            local member, m = Audit.IsMember(full)
            out[#out + 1] = { full = full, c = c, snap = snap, flags = Audit.FlagsOf(full), member = member, m = m }
        end
    end
    return out
end

local LEVEL_ORDER = { look = 4, watch = 3, unknown = 2, none = 1 }
Audit.LEVEL_ORDER = LEVEL_ORDER

-- Sort: "flags", "peak", "acquired", "other", "level", "name", "last".
function Audit.Sort(rows, key)
    local function v(r)
        if key == "peak" then return Audit.V(r.snap, "peak")
        elseif key == "acquired" then return Audit.V(r.snap, "acquired")
        elseif key == "other" then return Audit.Other(r.snap)
        elseif key == "level" then return r.snap.level or r.c.level
        elseif key == "last" then return r.snap.t
        elseif key == "flags" then
            return r.flags and ((r.flags.reviewed and 0 or LEVEL_ORDER[r.flags.level] or 0) * 1000 + r.flags.score) or nil
        end
    end
    table.sort(rows, function(a, b)
        if key ~= "name" then
            local av, bv = v(a), v(b)
            -- Unknown sorts last, never as zero.
            if av == nil and bv ~= nil then return false end
            if bv == nil and av ~= nil then return true end
            if av ~= bv then return av > bv end
        end
        return a.full < b.full
    end)
    return rows
end

---------------------------------------------------------------------------
-- Another player's counters: the comparison request
---------------------------------------------------------------------------
-- The game has one comparison slot (SetAchievementComparisonUnit) for every
-- addon and its own achievement window; the answer is the event
-- INSPECT_ACHIEVEMENT_READY with that player's GUID.
local req = {
    pending = nil,     -- { full, guid, unit, info, origin, started, deadline }
    holding = false,   -- the slot is set by us and not yet cleared
    ownCall = false,   -- true while we call Set / Clear ourselves
    notBefore = 0,     -- GetTime() before which no request goes out
    watching = false,  -- hooks on Set / Clear installed
    panel = nil,       -- the comparison panel the guard is on
}
Audit.status = nil

local function Say(text)
    Audit.status = text
    Data.Changed("audit.request")
end

-- Ends the current request (if any), says why, and clears the slot when it
-- is still ours (keepSlot: it is not ours any more, leave it alone).
local function Finish(text, keepSlot)
    req.pending = nil
    if req.holding and not keepSlot and type(ClearAchievementComparisonUnit) == "function" then
        req.ownCall = true
        pcall(ClearAchievementComparisonUnit)
        req.ownCall = false
    end
    if not keepSlot then req.holding = false end
    if text then Say(text) end
end

function Audit.Pending() return req.pending end

-- Someone else set or cleared the slot: it is theirs now. Our request (its
-- answer would be theirs) ends, and the next waits a gap.
local function SlotTaken()
    if req.ownCall then return end
    req.holding = false
    req.notBefore = math.max(req.notBefore, GetTime() + REQUEST_GAP)
    if req.pending then Finish("Another addon took the statistics request. Click Refresh to try again.", true) end
end

function Audit.InstallHooks()
    if req.watching or type(hooksecurefunc) ~= "function" then return end
    if type(SetAchievementComparisonUnit) ~= "function" or type(ClearAchievementComparisonUnit) ~= "function" then return end
    local okSet = pcall(hooksecurefunc, "SetAchievementComparisonUnit", SlotTaken)
    local okClear = pcall(hooksecurefunc, "ClearAchievementComparisonUnit", SlotTaken)
    req.watching = okSet and okClear
end

-- The achievement window's comparison panel handles every answer, even while
-- hidden, and one it did not ask for breaks its Summary page. It gets
-- answers only while it is on screen (its own scripts stay as they are).
local function PanelFollowsVisibility(panel)
    local method = panel:IsVisible() and "RegisterEvent" or "UnregisterEvent"
    panel[method](panel, "INSPECT_ACHIEVEMENT_READY")
end

local function GuardComparisonPanel()
    local panel = AchievementFrameComparison
    if not panel or req.panel == panel or not Audit.Supported() then return end
    req.panel = panel
    panel:HookScript("OnShow", PanelFollowsVisibility)
    panel:HookScript("OnHide", PanelFollowsVisibility)
    PanelFollowsVisibility(panel)
end

-- Why a request for unit cannot go out now (a status line), or nil.
local function Blocked(unit, info)
    if S.Call(InCombatLockdown) then return "Leave combat, then click Refresh." end
    if type(SetAchievementComparisonUnit) ~= "function" or type(GetComparisonStatistic) ~= "function" or not req.watching then
        return "This client has no comparison request for another player's statistics."
    end
    if type(CanInspect) ~= "function" or S.Call(CanInspect, unit, false) ~= true then
        return Guild.Short(info.full) .. " cannot be inspected right now: move closer and click Refresh."
    end
    if AchievementFrame and AchievementFrame:IsShown() and AchievementFrame.isComparison then
        return "Close the achievement comparison window first."
    end
    local wait = req.notBefore - GetTime()
    if wait > 0 then return "Wait " .. math.ceil(wait) .. " s, then click Refresh." end
end

-- Asks the server for a player's counters: one request per click or per
-- Inspect, never from a timer. True when a request went out (or is still
-- out for this player) or your own look was read.
function Audit.Request(unit, origin)
    unit = unit or "target"
    if not Audit.Supported() then Say("The game's statistics are not available on this client.") return false end
    local info = Audit.Subject(unit)
    if not info then Say("Target a player (or click My character).") return false end
    local p = req.pending
    if p and p.unit == unit and p.guid == info.guid then
        Say("Still waiting for " .. Guild.Short(info.full) .. " · " .. math.floor(GetTime() - p.started) .. " s")
        return true
    end
    Finish(nil)
    Audit.selected = info.full
    if info.own then
        local snap = Audit.ReadSelf()
        Say(snap and ("Your statistics: " .. snap.n .. " / " .. #Audit.FIELDS .. " counters.") or "Your statistics could not be read.")
        return snap ~= nil
    end
    local why = Blocked(unit, info)
    if why then Say(why) return false end
    local now = GetTime()
    req.notBefore = now + REQUEST_GAP
    req.pending = { full = info.full, guid = info.guid, unit = unit, info = info, origin = origin,
        started = now, deadline = now + REQUEST_TIMEOUT }
    req.holding, req.ownCall = true, true
    local ok, result = pcall(SetAchievementComparisonUnit, unit)
    req.ownCall = false
    if not ok or result == false then Finish("The statistics request failed. Try again with the player nearby.") return false end
    Say("Waiting for " .. Guild.Short(info.full) .. "'s statistics...")
    return true
end

local function OnReady(guid)
    local p = req.pending
    if not p or S.Value(guid) ~= p.guid then return end
    if GetTime() > p.deadline then Finish("The answer came too late. Click Refresh.") return end
    if S.Call(UnitGUID, p.unit) ~= p.guid then Finish("Your target changed. Click Refresh for the new one.") return end
    if S.Call(InCombatLockdown) then Finish("Combat interrupted the request. Click Refresh after combat.") return end
    local snap = Audit.ReadCounters(false)
    Finish(nil)
    if snap.n > 0 then
        Audit.Save(p.info, snap)
        Say(Guild.Short(p.full) .. ": " .. snap.n .. " / " .. #Audit.FIELDS .. " counters saved.")
    else
        Say("The game returned no readable statistics for " .. Guild.Short(p.full) .. ".")
    end
end
Audit.OnReady = OnReady

---------------------------------------------------------------------------
-- Inspect window: an Audit button, and (setting) a request on each Inspect
---------------------------------------------------------------------------
local inspectHooked = false
local function HookInspect()
    if inspectHooked or not InspectFrame or S.Call(InCombatLockdown) then return end
    inspectHooked = true
    InspectFrame:HookScript("OnShow", function(self)
        if db().auditOnInspect and self.unit then ns.SafeCall(Audit.Request, self.unit, "inspect") end
    end)
    InspectFrame:HookScript("OnHide", function()
        if req.pending and req.pending.origin == "inspect" then Finish(nil) end
    end)
    local b = CreateFrame("Button", ns.FRAME .. "AuditInspectButton", InspectFrame, "UIPanelButtonTemplate")
    b:SetSize(68, 22)
    b:SetPoint("BOTTOMRIGHT", InspectFrame, "BOTTOMRIGHT", -18, -29)
    b:SetText("Audit")
    b:SetScript("OnClick", function()
        if InspectFrame.unit then
            Audit.Request(InspectFrame.unit, "inspect")
            if ns.AuditUI then ns.AuditUI.Show("ledger") end
        end
    end)
end

---------------------------------------------------------------------------
-- Guild sharing: a member's own counters to the officer who asks
---------------------------------------------------------------------------
-- "t;build;level;key=value;..." (numbers only; display-only text stays home).
function Audit.SharePayload()
    local snap = Audit.ReadSelf()
    if not snap then return "" end
    local out = { tostring(snap.t), (snap.build:gsub("[^%w%.]", "")), tostring(S.Call(UnitLevel, "player") or "") }
    for _, f in ipairs(Audit.FIELDS) do
        local n = snap.v[f[1]]
        if n ~= nil then out[#out + 1] = f[1] .. "=" .. string.format("%.0f", n) end
    end
    return table.concat(out, ";")
end

-- A member's shared counters -> a look; nil when unusable. The time is
-- theirs: one in the future or older than 30 days becomes "now".
function Audit.ParseShared(payload)
    if type(payload) ~= "string" or payload == "" then return nil end
    local parts = {}
    for piece in (payload .. ";"):gmatch("(.-);") do parts[#parts + 1] = piece end
    local now = time()
    local t = tonumber(parts[1])
    if not t or t > now + 300 or t < now - 30 * 86400 then t = now end
    local level = tonumber(parts[3])
    local snap = { t = math.floor(t), build = (parts[2] or "?"):sub(1, 40), src = "shared", v = {}, d = {}, miss = {}, n = 0,
        level = level and level >= 1 and level <= 100 and math.floor(level) or nil }
    for i = 4, #parts do
        local key, value = parts[i]:match("^(%a+)=(%d+)$")
        local n = Number(value)
        if key and Audit.BY_KEY[key] and n and snap.v[key] == nil then
            snap.v[key] = n
            snap.n = snap.n + 1
        end
    end
    for _, f in ipairs(Audit.FIELDS) do
        if snap.v[f[1]] == nil then snap.miss[f[1]] = "notShared" end
    end
    if snap.n == 0 then return nil end
    return snap
end

function Audit.ReceiveShared(sender, snap)
    if not (sender and snap) then return end
    local _, m = Audit.IsMember(sender)
    Audit.Save({ full = sender, classFile = m and m.classFile, level = m and m.level, guild = Guild.Mine() }, snap)
end

-- They said No: their shared looks go (inspected ones are the server's).
function Audit.DropShared(sender)
    local c = Audit.Record(sender)
    if not c then return end
    local kept = {}
    for _, s in ipairs(c.snaps) do if s.src ~= "shared" then kept[#kept + 1] = s end end
    if #kept == #c.snaps then return end
    c.snaps = kept
    if #kept == 0 then Store().chars[sender] = nil end
    Data.Changed("audit")
end

-- Only where the game has the statistics: on Classic Era there is nothing to share.
if Audit.Supported() and ns.GuildSync and ns.GuildSync.AddCategory then
    ns.GuildSync.AddCategory({
        key = "stats", label = "Gold and activity statistics",
        text = "The game's statistics for this character: gold acquired, most gold owned, gold by source, auctions, "
            .. "quests, kills, dungeons, deaths, profession ranks. Not the gold you carry.",
        payload = function() return Audit.SharePayload() end,
        parse = function(p)
            local snap = Audit.ParseShared(p)
            return snap and { t = snap.t, n = snap.n, snap = snap } or nil
        end,
        received = function(sender, v) if v and v.snap then Audit.ReceiveShared(sender, v.snap) v.snap = nil end end,
        dropped = function(sender) Audit.DropShared(sender) end,
    })
end

---------------------------------------------------------------------------
-- Slash, module
---------------------------------------------------------------------------
local function Slash(command, rest)
    if command ~= "audit" then return false end
    local arg = ((rest or ""):match("^(%S*)") or ""):lower()
    if arg == "me" then
        Audit.Request("player")
        if ns.AuditUI then ns.AuditUI.Show("ledger") end
    elseif arg == "target" or arg == "refresh" then
        Audit.Request("target")
        if ns.AuditUI then ns.AuditUI.Show("ledger") end
    elseif arg == "flags" or arg == "members" or arg == "characters" or arg == "history" then
        if ns.AuditUI then ns.AuditUI.Show(arg) end
    elseif arg == "status" then
        ns.Print("audit: client " .. Audit.Build() .. ", statistic IDs checked on " .. Audit.DATA_BUILD .. ".")
        for _, name in ipairs({ "GetStatistic", "GetComparisonStatistic", "SetAchievementComparisonUnit", "ClearAchievementComparisonUnit" }) do
            ns.Print("  " .. name .. ": " .. type(_G[name]))
        end
        ns.Print("  " .. (req.pending and ("waiting for " .. Guild.Short(req.pending.full)) or (Audit.status or "no request yet")))
    else
        if ns.AuditUI then ns.AuditUI.Toggle() end
    end
    return true
end

local selfRead = nil
ns.RegisterModule("Audit", {
    defaults = { auditOnInspect = true, auditGapGold = 25, auditOtherGold = 250, auditOtherShare = 50, auditJumpGold = 100,
        auditLevelRule = true },
    init = function()
        Data.Source("audit")
        Data.Source("audit.request")
        Audit.InstallHooks()
        selfRead = GetTime() + 5
    end,
    tick = function()
        local now = GetTime()
        -- Your own look a few seconds after login (the counters load late).
        if selfRead and now >= selfRead then selfRead = nil Audit.ReadSelf() end
        if req.pending and now >= req.pending.deadline then
            Finish("No answer after " .. REQUEST_TIMEOUT .. " s. Move closer and click Refresh (nothing is retried on its own).")
        end
        HookInspect()
        GuardComparisonPanel()
    end,
    events = { "INSPECT_ACHIEVEMENT_READY", "PLAYER_TARGET_CHANGED", "PLAYER_REGEN_ENABLED", "PLAYER_LOGOUT" },
    onEvent = function(event, arg)
        if event == "INSPECT_ACHIEVEMENT_READY" then
            OnReady(arg)
        elseif event == "PLAYER_TARGET_CHANGED" then
            if req.pending and req.pending.unit == "target" and S.Call(UnitGUID, "target") ~= req.pending.guid then
                Finish("Target changed. Click Refresh for the new one.")
            end
        elseif event == "PLAYER_REGEN_ENABLED" then
            Audit.InstallHooks()
        elseif event == "PLAYER_LOGOUT" then
            Finish(nil)
        end
    end,
    slash = Slash,
})
