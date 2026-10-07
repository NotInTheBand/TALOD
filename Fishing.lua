-- TALOD - Fishing: every cast you make, where, at what skill, and what
-- it brought; what each spot is worth per hour at your skill; and how often
-- you were attacked there (by NPCs or enemy players) or saw an enemy player
-- while fishing. Feeds the fishing window (FishingUI.lua), its HUD and
-- tools/fishing_viewer.py (HTML heat maps).
--
-- A cast is the Fishing channel (UNIT_SPELLCAST_CHANNEL_START / _STOP); its
-- length comes from UnitChannelInfo (30 s when unreadable). Its result:
-- "c" caught (fishing loot opened: IsFishingLoot), "a" the fish got away
-- (the game's "Your fish got away!": a bite your skill lost), "m" missed
-- (clicked with nothing hooked, or stopped early with no message: you moved,
-- cast something else), "t" the channel ran out (no bite clicked), "i"
-- combat began during the cast. Catch rate is c / (c + a): only an escape
-- says something about the spot at your skill. Saved data from before "m"
-- existed counts early stops as "a".
-- Fishing time is the channels plus the gaps between casts up to 30 s, so
-- per-hour numbers ignore breaks.
--
-- Attacks: combat that starts while you fish (or within 45 s of a cast) and
-- that you did not start yourself (no spell or auto-attack of yours in the
-- 3 s before). The attacker is the unit targeting you among your target,
-- mouseover and nameplates: a player ("P"), else an NPC ("N"); "?" when
-- nothing readable targets you (enemy nameplates off, or hidden values). Who
-- attacked is never guessed from a nearby enemy: unknown stays "?".
-- Enemy players seen while fishing come from the Spotter.
--
-- Data in TALODDB.fishing (account-wide; sessions name the character):
--   casts    recent casts, one string each, capped at fishMaxCasts:
--            1 time, 2 mapID, 3 x, 4 y (0-1000, empty unknown), 5 result,
--            6 skill, 7 skill modifier, 8 lure (1/0), 9 your level,
--            10 items (id:n;id:n), 11 spot (subzone, commas removed),
--            then (added later; older records stop at 11):
--            12 lure enchant ID (empty: none or unknown), 13 server time
--            (minutes after midnight, GetGameTime), 14 channel length in
--            seconds as the game gave it (empty: unreadable, 30 assumed),
--            15 cast tags from other modules (key;key=value), 16 the
--            number of the character that cast (Store.lua; empty: unknown)
--            New fields only ever go at the end.
--   spots    [mapID][spot] = { b = { [band] = tally }, s, x, p, u, e, d,
--            h = { [4-hour bucket] = { seconds, attacks } }, px, py, pn,
--            l = { [lure] = tally + ms, mn } }
--            band = skill / 25 (with the modifier: lure, gear)
--   lures    [lure] = tally + ms, mn: every spot. lure = enchant ID, "on"
--            (a lure, ID unread), "none", "?" (unknown); ms / mn = average
--            skill modifier with it (the lure's bonus sits in the modifier)
--   cells    [mapID]["cx:cy"] = tally + x, p, u, e (50 x 50 grid, as Census)
--   tally    { n casts, c, a, m, t, i, s fishing seconds, it = { [itemID] = n } }
--            (m missing in older data)
--   threats  { t, m, x, y, k (N, P, ?, E seen, e seen with hostility hidden,
--            D died), who, lvl, cls, sub, died, c (character number) }
--   sessions finished sessions (tally + char, cid (character number), zone, start, last, skill0/1,
--            x, p, u, e, d); session = the current one
--   ranks    [skill rank] = catches made at that rank (catches per point)
--   names, icons, maps  item names / icons and map names for the viewer

local ADDON_NAME, ns = ...
local S = ns.Secret
local Style = ns.Style
local HEX = Style.HEX

local Fishing = {}
ns.Fishing = Fishing

local FORMAT_VERSION = 1
local GRID = 50               -- squares per map side, same as Census
local BAND = 25               -- skill band width
local GAP_MAX = 30            -- seconds between casts still counted as fishing
local DEFAULT_CHANNEL = 30    -- vanilla's Fishing channel, when the game does not say
local TIMEOUT_MARGIN = 2      -- a channel this close to its end ran out
local MAX_OVERRUN = 10        -- a cast with no stop event this long after its end is closed
local LOOT_GRACE = 1.5        -- seconds after the channel for the loot window
local RECENT = 45             -- "fishing" this long after a cast
local SESSION_IDLE = 300      -- a session ends after this long without a cast
local ATTACK_SCAN = 2         -- seconds to find who attacked
local SELF_START = 3          -- your own action this soon before combat: you started it
local DEATH_WINDOW = 120      -- a death this soon after an attack while fishing belongs to it
local MIN_CASTS = 10          -- casts in your band before other bands are left out
local MIN_MINUTES = 5         -- fishing time before per-hour numbers are shown
local DANGER_MINUTES = 15     -- fishing time before "chance of a quiet half hour"
local MAX_SESSIONS = 300
local MAX_THREATS = 2000
local ENEMY_SOUND_REPEAT = 60

Fishing.GRID, Fishing.BAND, Fishing.MIN_MINUTES, Fishing.DANGER_MINUTES = GRID, BAND, MIN_MINUTES, DANGER_MINUTES

-- Fishing ranks (Apprentice to Artisan); other spells are matched by name.
local FISHING_SPELLS = { [7620] = true, [7731] = true, [7732] = true, [18248] = true }

local cast                    -- the cast in progress
local lastCastEnd             -- GetTime() of the last finished cast
local lastActivity            -- GetTime() of the last cast start / end / loot
local lastCatchAt             -- GetTime() of the last catch (its second loot event is ignored)
local pendingAttack           -- combat began while fishing: who attacked?
local lastThreat              -- { at, rec } for deaths
local lastOwnAction = -math.huge
local lureWasOn, lureWarned, bagWarned, capWarned = false, false, false, false
local enemySoundAt = {}
local spellIsFishing = {}

local function db() return ns.DB() end

-- Other fishing modules (FishingSafety, FishingGoals, FishingGear) listen
-- here instead of patching this file: "start" (cast), "finish" (cast,
-- result), "loot" (items of a catch).
local listeners = {}
function Fishing.On(name, fn)
    listeners[name] = listeners[name] or {}
    table.insert(listeners[name], fn)
end
local function Fire(name, ...)
    for _, fn in ipairs(listeners[name] or {}) do ns.SafeCall(fn, ...) end
end

-- Extra "/talod fish <word>" commands: fn(arg) returns true when it took it.
local slashHandlers, slashUsage = {}, {}
function Fishing.AddSlash(fn, usage)
    slashHandlers[#slashHandlers + 1] = fn
    if usage then slashUsage[#slashUsage + 1] = usage end
end
local function Num(v) return type(v) == "number" and v or nil end

local function Store()
    local f = db().fishing
    if type(f) ~= "table" then
        f = {}
        db().fishing = f
    end
    f.version = f.version or FORMAT_VERSION
    for _, key in ipairs({ "casts", "spots", "cells", "maps", "threats", "sessions", "ranks", "names", "icons", "lures" }) do
        if type(f[key]) ~= "table" then f[key] = {} end
    end
    return f
end
Fishing.Store = Store

---------------------------------------------------------------------------
-- What the game tells
---------------------------------------------------------------------------
local function IsFishingSpell(id)
    id = Num(S.Value(id))
    if not id then return false end
    if FISHING_SPELLS[id] then return true end
    if spellIsFishing[id] == nil then
        local name = ns.Conditions and ns.Conditions.SpellName(id)
        local fishing = ns.Conditions and ns.Conditions.SpellName(7620) or "Fishing"
        spellIsFishing[id] = name ~= nil and name == fishing
    end
    return spellIsFishing[id]
end
Fishing.IsFishingSpell = IsFishingSpell

-- Your Fishing skill from the Skills module: rank, modifier (lure, gear), max.
function Fishing.Skill()
    local c = ns.Skills and ns.Skills.Char()
    local cur = c and c.current
    if not cur then return nil end
    local s = cur.Fishing
    if not s then
        local name = ns.Conditions and ns.Conditions.SpellName(7620)
        s = name and cur[name]
    end
    if not s then return nil end
    return s.rank, s.mod or 0, s.max
end

function Fishing.Effective()
    local rank, mod = Fishing.Skill()
    return rank and rank + (mod or 0) or nil
end

-- true / false, or nil when the game does not say.
function Fishing.PoleEquipped()
    local id = S.Call(GetInventoryItemID, "player", 16)
    if type(id) ~= "number" then return false end
    local fn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if type(fn) ~= "function" then return nil end
    local _, _, _, _, _, classID, subclassID = S.CallMulti(7, fn, id)
    if type(classID) ~= "number" then return nil end
    return classID == 2 and subclassID == 20
end

-- A lure is a temporary enchant on the fishing pole: on (true / false, nil
-- unknown), seconds left and its enchant ID (nil when the game does not say).
function Fishing.Lure()
    if type(GetWeaponEnchantInfo) ~= "function" or Fishing.PoleEquipped() ~= true then return nil end
    -- Older clients return nil for "no enchant": only a secret is unknown
    -- (S.CallMulti would turn both into nil).
    local ok, has, expires, _, enchantID = pcall(GetWeaponEnchantInfo)
    if not ok or S.IsSecret(has) then return nil end
    if not has then return false end
    expires = Num(S.Value(expires))
    enchantID = Num(S.Value(enchantID))
    return true, expires and expires / 1000 or nil, (enchantID and enchantID > 0) and enchantID or nil
end

-- Fishing lures by temporary-enchant ID: their skill bonus. Only for the
-- label; what a cast really had is its skill modifier (lure and gear).
-- 265 = +75 (Bright Baubles) was measured in game 2026-10-04: 20 casts with
-- it averaged a +75 modifier with a plain pole. 266 and 2603 are not seen
-- yet ([VERIFY] in docs/PLAN.md).
local LURE_BONUS = { [263] = 25, [264] = 50, [265] = 75, [266] = 100, [2603] = 75 }
Fishing.LURE_BONUS = LURE_BONUS

-- The key a cast's lure is tallied under: enchant ID, "on" (a lure, ID not
-- given), "none", or "?" (the game did not say).
local function LureKey(c)
    if c.lureID then return c.lureID end
    if c.lureState == true then return "on" end
    if c.lureState == false then return "none" end
    return "?"
end
Fishing.LureKey = LureKey

function Fishing.LureLabel(key)
    if key == "none" then return "No lure" end
    if key == "on" then return "Lure (which: ?)" end
    if key == "?" then return "Lure: ?" end
    local bonus = LURE_BONUS[tonumber(key)]
    return bonus and string.format("+%d lure", bonus) or ("Lure #" .. tostring(key))
end

-- The game's own texts for a fishing click (GlobalStrings), English when missing.
local function FishMessages()
    local escaped, notHooked = S.Value(_G.ERR_FISH_ESCAPED), S.Value(_G.ERR_FISH_NOT_HOOKED)
    return type(escaped) == "string" and escaped or "Your fish got away!",
        type(notHooked) == "string" and notHooked or "No fish are hooked."
end

-- How long this channel lasts (UnitChannelInfo: start and end in ms), and
-- whether the game said so. Vanilla's is 30 s; Forever may differ.
local function ChannelSeconds()
    local _, _, _, startMs, endMs = S.CallMulti(5, UnitChannelInfo, "player")
    if type(startMs) == "number" and type(endMs) == "number" then
        local d = (endMs - startMs) / 1000
        if d >= 5 and d <= 120 then return d, true end
    end
    return DEFAULT_CHANNEL, false
end

-- The realm's clock (GetGameTime) in minutes after midnight: the game's day
-- and night, and fish that bite only at some hours, follow it, not your PC's.
local function ServerMinutes()
    local h, m = S.CallMulti(2, GetGameTime)
    if type(h) == "number" and type(m) == "number" and h >= 0 and h < 24 and m >= 0 and m < 60 then
        return math.floor(h) * 60 + math.floor(m)
    end
    return nil
end
Fishing.ServerMinutes = ServerMinutes

-- Free slots in your general bags (nil unknown).
function Fishing.FreeSlots()
    local fn = (C_Container and C_Container.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
    if type(fn) ~= "function" then return nil end
    local total, any = 0, false
    for _, bag in ipairs(ns.Utils.BagIDs("general")) do
        local free, family = S.CallMulti(2, fn, bag)
        if type(free) == "number" and (family == nil or family == 0) then
            total, any = total + free, true
        end
    end
    return any and total or nil
end

local function Place()
    local mapID, x, y
    if ns.Census and ns.Census.MapPosition then mapID, x, y = ns.Census.MapPosition("player") end
    local zone = S.Call(GetZoneText)
    zone = type(zone) == "string" and zone ~= "" and zone or nil
    local sub = S.Call(GetSubZoneText)
    sub = type(sub) == "string" and sub ~= "" and sub or zone or "?"
    return { mapID = mapID, x = x, y = y, zone = zone, sub = (sub:gsub(",", "")) }
end
Fishing.Place = Place

local function RememberMap(f, mapID, zone)
    if not mapID or f.maps[mapID] then return end
    local name
    if C_Map and C_Map.GetMapInfo then
        local ok, info = pcall(C_Map.GetMapInfo, mapID)
        info = ok and S.Value(info) or nil
        name = type(info) == "table" and S.Value(info.name) or nil
    end
    f.maps[mapID] = type(name) == "string" and name or zone or tostring(mapID)
end

local function CellKey(x, y)
    if not x then return nil end
    return math.min(GRID - 1, math.floor(x * GRID)) .. ":" .. math.min(GRID - 1, math.floor(y * GRID))
end
Fishing.CellKey = CellKey

function Fishing.Band(skill) return skill and math.floor(skill / BAND) * BAND or nil end

---------------------------------------------------------------------------
-- Items and value
---------------------------------------------------------------------------
-- What one sells for: Market.SaleValue, the rule the Market window and
-- the planner use too (AH after the cut x your own sell rate, against a
-- vendor; soulbound and grey: vendor). Returns copper (0 unknown), how
-- ("ah" / "vendor" / nil), true when it could go to the AH but was never
-- seen there (vendor price: likely too low), and Market's info.
function Fishing.ItemValue(id)
    if not (ns.Market and ns.Market.SaleValue) then return 0, nil, false, {} end
    local v, how, info = ns.Market.SaleValue(id)
    return v or 0, how, info.unseen == true, info
end

-- Total value of { [id] = n }, kinds without any price, and kinds valued
-- at the vendor only because they were never seen on the AH.
function Fishing.ItemsValue(items)
    local total, unpriced, unseen = 0, 0, 0
    for id, n in pairs(items or {}) do
        local v, _, notSeen = Fishing.ItemValue(id)
        if v > 0 then total = total + v * n else unpriced = unpriced + 1 end
        if notSeen then unseen = unseen + 1 end
    end
    return total, unpriced, unseen
end

function Fishing.ItemName(id)
    local f = Store()
    local name = ns.Market and ns.Market.ItemInfo(id)
    if (not name or name:find("^item %d")) and f.names[id] then return f.names[id] end
    return name or f.names[id] or ("item " .. tostring(id))
end

function Fishing.ItemText(id)
    local f = Store()
    local name = ns.Market and ns.Market.ItemInfo(id)
    if name and not name:find("^item %d") then return ns.Market.ItemText(id) end
    return HEX.white .. (f.names[id] or ("item " .. tostring(id))) .. "|r"
end

function Fishing.ItemIcon(id)
    local f = Store()
    if f.icons[id] then return f.icons[id] end
    local _, icon = ns.Market and ns.Market.ItemInfo(id)
    return icon or 134400
end

---------------------------------------------------------------------------
-- Tallies
---------------------------------------------------------------------------
local function AddTally(t, result, seconds, items)
    t.n = (t.n or 0) + 1
    t[result] = (t[result] or 0) + 1
    t.s = (t.s or 0) + seconds
    if items then
        t.it = t.it or {}
        for id, n in pairs(items) do t.it[id] = (t.it[id] or 0) + n end
    end
end

local function MergeInto(dst, t)
    for _, k in ipairs({ "n", "c", "a", "m", "t", "i", "s" }) do dst[k] = (dst[k] or 0) + (t[k] or 0) end
    dst.it = dst.it or {}
    for id, n in pairs(t.it or {}) do dst.it[id] = (dst.it[id] or 0) + n end
end
Fishing.MergeInto = MergeInto

local function NewTally() return { n = 0, c = 0, a = 0, m = 0, t = 0, i = 0, s = 0, it = {} } end
Fishing.NewTally = NewTally

local function Spot(f, mapID, name)
    local m = f.spots[mapID] or {}
    f.spots[mapID] = m
    local s = m[name]
    if not s then
        s = { b = {}, s = 0, x = 0, p = 0, u = 0, e = 0, d = 0, h = {}, px = 0, py = 0, pn = 0, l = {} }
        m[name] = s
    end
    s.l = s.l or {}
    return s
end

-- A cast into a lure tally (lures[key]), with the skill modifier it had.
local function AddLure(list, c, result, seconds, items)
    local key = LureKey(c)
    local t = list[key] or NewTally()
    list[key] = t
    AddTally(t, result, seconds, items)
    if c.mod then t.ms, t.mn = (t.ms or 0) + c.mod, (t.mn or 0) + 1 end
end

local function Cell(f, mapID, key)
    if not mapID or not key then return nil end
    local m = f.cells[mapID] or {}
    f.cells[mapID] = m
    m[key] = m[key] or NewTally()
    return m[key]
end

-- Danger buckets use your PC's clock on purpose: they answer "when in my own
-- day is it quiet here" (player attacks follow when people are online, not
-- the game's day and night). The cast log keeps the server time separately,
-- for the fish.
local function Hour(t) return math.floor((tonumber(date("%H", t)) or 0) / 4) end

local function CharKey() return ns.Gear and ns.Gear.CharKey() or "?" end

---------------------------------------------------------------------------
-- Sessions
---------------------------------------------------------------------------
local function SessionSummary(s)
    local value = Fishing.ItemsValue(s.it)
    local minutes = (s.s or 0) / 60
    local gained = (s.skill1 and s.skill0) and (s.skill1 - s.skill0) or 0
    return string.format("%s: %d min fished, %d caught of %d casts, %s%s%s%s", s.zone or "?", math.floor(minutes + 0.5),
        s.c or 0, s.n or 0, ns.Professions.Money(value),
        minutes >= MIN_MINUTES and (" (" .. ns.Professions.Money(value / (minutes / 60)) .. "/h)") or "",
        gained > 0 and (", +" .. gained .. " skill") or "",
        ((s.x or 0) + (s.p or 0) + (s.u or 0)) > 0 and (", " .. ((s.x or 0) + (s.p or 0) + (s.u or 0)) .. " attacks") or "")
end
Fishing.SessionSummary = SessionSummary

function Fishing.CloseSession()
    local f = Store()
    local s = f.session
    if not s then return nil end
    f.session = nil
    capWarned, bagWarned = false, false
    if (s.n or 0) == 0 then return nil end
    f.sessions[#f.sessions + 1] = s
    while #f.sessions > MAX_SESSIONS do table.remove(f.sessions, 1) end
    ns.Data.Changed("fishing")
    if db().fishSessionSummary then ns.Print("fishing session ended — " .. SessionSummary(s)) end
    return s
end

local function OpenSession(place)
    local f = Store()
    local s = f.session
    local now = time()
    if s and (now - (s.last or 0) > SESSION_IDLE or s.char ~= CharKey() or (place.mapID and s.mapID and s.mapID ~= place.mapID)) then
        Fishing.CloseSession()
        s = nil
    end
    if not s then
        local rank = Fishing.Skill()
        s = NewTally()
        s.start, s.last, s.char, s.cid, s.mapID, s.zone = now, now, CharKey(), ns.Store.Me(), place.mapID, place.zone
        s.x, s.p, s.u, s.e, s.d = 0, 0, 0, 0, 0
        s.skill0, s.skill1 = rank, rank
        f.session = s
    end
    return s
end

function Fishing.Session() return Store().session end

---------------------------------------------------------------------------
-- Casts
---------------------------------------------------------------------------
function Fishing.IsFishing()
    if cast then return true end
    return lastActivity ~= nil and GetTime() - lastActivity <= RECENT
end

local function Trim(list, max)
    if #list <= max + math.max(10, math.floor(max / 10)) then return end
    local drop = #list - max
    for i = 1, max do list[i] = list[i + drop] end
    for i = #list, max + 1, -1 do list[i] = nil end
end

local function ItemsString(items)
    if not items then return "" end
    local parts = {}
    for id, n in pairs(items) do parts[#parts + 1] = id .. ":" .. n end
    table.sort(parts)
    return table.concat(parts, ";")
end

-- cast.tags (set by other modules on "start") as one log field: "key" for
-- true, "key=value" for a number or text; separators taken out.
local function TagsString(tags)
    local parts = {}
    for k, v in pairs(tags or {}) do
        k, v = S.Value(k), S.Value(v)
        if type(k) == "string" and k ~= "" then
            local key = (k:gsub("[,;=]", ""))
            if v == true then
                parts[#parts + 1] = key
            elseif type(v) == "number" or type(v) == "string" then
                parts[#parts + 1] = key .. "=" .. (tostring(v):gsub("[,;=]", ""))
            end
        end
    end
    table.sort(parts)
    return table.concat(parts, ";")
end
Fishing.TagsString = TagsString

local function ParseTags(s)
    local tags = {}
    for part in (s or ""):gmatch("[^;]+") do
        local k, v = part:match("^([^=]+)=(.*)$")
        if k then tags[k] = tonumber(v) or v else tags[part] = true end
    end
    return tags
end
Fishing.ParseTags = ParseTags

-- What an ended cast was. The game names two cases (UI_ERROR_MESSAGE): the
-- fish got away (a bite your skill lost: the spot's signal, "a") and a
-- click with nothing hooked ("m"). Combat during the cast is "i"; a channel
-- that ran to its end, "t". An early stop with no message (you moved,
-- jumped, cast something else, a loading screen) is "m" too: nothing says
-- a fish bit, and an unknown must not count against the spot's catch rate.
local function Outcome(c, now)
    if c.items then return "c" end
    if c.escaped then return "a" end
    if c.interrupted then return "i" end
    if c.notHooked then return "m" end
    local ended = c.ended or now or GetTime()
    if ended - c.start >= (c.duration or DEFAULT_CHANNEL) - TIMEOUT_MARGIN then return "t" end
    return "m"
end
Fishing.Outcome = Outcome

local function Finish(result)
    local c = cast
    if not c then return end
    cast = nil
    local now = GetTime()
    local ended = c.ended or now
    local seconds = math.min((c.duration or DEFAULT_CHANNEL) + MAX_OVERRUN, math.max(0, ended - c.start)) + (c.gap or 0)
    lastCastEnd, lastActivity = ended, now
    if result == "c" then lastCatchAt = now end
    if not db().fishingEnabled then return end
    Fire("finish", c, result)
    local f = Store()
    local p = c.place
    local items = result == "c" and c.items or nil
    local s = OpenSession(p)
    AddTally(s, result, seconds, items)
    s.last = time()
    s.skill1 = Fishing.Skill() or s.skill1
    if p.mapID then
        RememberMap(f, p.mapID, p.zone)
        local spot = Spot(f, p.mapID, p.sub)
        local band = Fishing.Band(c.skill and (c.skill + (c.mod or 0)))
        if band then
            spot.b[band] = spot.b[band] or NewTally()
            AddTally(spot.b[band], result, seconds, items)
        else
            spot.b.unknown = spot.b.unknown or NewTally()
            AddTally(spot.b.unknown, result, seconds, items)
        end
        spot.s = spot.s + seconds
        spot.first = spot.first or c.t
        spot.last = c.t
        if p.x then spot.px, spot.py, spot.pn = spot.px + p.x, spot.py + p.y, spot.pn + 1 end
        local hb = Hour(c.t)
        spot.h[hb] = spot.h[hb] or { 0, 0 }
        spot.h[hb][1] = spot.h[hb][1] + seconds
        local cell = Cell(f, p.mapID, CellKey(p.x, p.y))
        if cell then AddTally(cell, result, seconds, items) end
        AddLure(spot.l, c, result, seconds, items)
    end
    AddLure(f.lures, c, result, seconds, items)
    if result == "c" and c.skill then f.ranks[c.skill] = (f.ranks[c.skill] or 0) + 1 end
    f.casts[#f.casts + 1] = table.concat({
        c.t, p.mapID or "", p.x and math.floor(p.x * 1000 + 0.5) or "", p.y and math.floor(p.y * 1000 + 0.5) or "",
        result, c.skill or "", c.mod or "", c.lure and 1 or 0, c.level or "", ItemsString(items), p.sub,
        c.lureID or "", c.serverMin or "", c.channelRead and math.floor(c.duration * 10 + 0.5) / 10 or "", TagsString(c.tags),
        ns.Store.Me() or "",
    }, ",")
    Trim(f.casts, db().fishMaxCasts or 20000)
    ns.Data.Changed("fishing")
end
Fishing.Finish = Finish

local function StartCast()
    local now = GetTime()
    if cast and now - cast.start < 1 then
        -- Started from UNIT_SPELLCAST_SUCCEEDED: the channel's length comes now.
        if not cast.channelRead then cast.duration, cast.channelRead = ChannelSeconds() end
        return
    end
    if cast then
        cast.ended = cast.ended or now
        Finish(Outcome(cast, now))
    end
    local rank, mod = Fishing.Skill()
    local gap = (lastCastEnd and now - lastCastEnd <= GAP_MAX) and (now - lastCastEnd) or 0
    local lureState, _, lureID = Fishing.Lure()
    local duration, channelRead = ChannelSeconds()
    cast = { start = now, t = time(), place = Place(), skill = rank, mod = mod, lure = lureState == true,
        lureState = lureState, lureID = lureID, serverMin = ServerMinutes(), duration = duration, channelRead = channelRead,
        level = S.Call(UnitLevel, "player"), gap = gap, tags = {} }
    lastActivity = now
    if db().fishingEnabled then OpenSession(cast.place) end
    Fire("start", cast)
end

local function StopCast()
    if not cast or cast.ended then return end
    cast.ended = GetTime()
    if cast.items then Finish("c") end
end

-- { [itemID] = n } of the open loot window (nil when it holds no items).
local function ReadLoot()
    local n = Num(S.Call(GetNumLootItems)) or 0
    local f = Store()
    local items, any = {}, false
    for slot = 1, n do
        local link = S.Call(GetLootSlotLink, slot)
        local id = type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
        if id then
            local icon, name, qty = S.CallMulti(3, GetLootSlotInfo, slot)
            items[id] = (items[id] or 0) + ((type(qty) == "number" and qty > 0) and qty or 1)
            if type(name) == "string" and name ~= "" then f.names[id] = name end
            if icon ~= nil and (type(icon) == "number" or type(icon) == "string") then f.icons[id] = icon end
            any = true
        end
    end
    return any and items or nil
end

local function OnLoot()
    local fishy = type(IsFishingLoot) == "function" and S.Call(IsFishingLoot) or nil
    local now = GetTime()
    if fishy == nil then
        -- No answer: loot right at the end of a fishing cast is the catch.
        fishy = cast ~= nil and (not cast.ended or now - cast.ended <= LOOT_GRACE + 1)
    end
    if fishy ~= true then return end
    -- LOOT_READY and LOOT_OPENED both fire, before or after the channel stops.
    if cast and cast.items then return end
    if not cast and lastCatchAt and now - lastCatchAt <= LOOT_GRACE + 2 then return end
    local items = ReadLoot() or {}
    if not cast then
        -- Loot without a cast we saw (a reload mid-cast): a catch here, now.
        cast = { start = now, t = time(), place = Place(), level = S.Call(UnitLevel, "player"), gap = 0, tags = {},
            duration = DEFAULT_CHANNEL, serverMin = ServerMinutes() }
        cast.skill, cast.mod = Fishing.Skill()
        local lureState, _, lureID = Fishing.Lure()
        cast.lure, cast.lureState, cast.lureID = lureState == true, lureState, lureID
        cast.ended = now
    end
    cast.items = items
    lastActivity = now
    Fire("loot", items)
    if cast.ended then Finish("c") end
end

-- The game's red error text after a click on the bobber. Its arguments are
-- (errorType, message) on the modern engine and (message) on old clients:
-- every readable string is compared.
local function OnUIError(...)
    if not cast then return end
    local escaped, notHooked = FishMessages()
    for i = 1, select("#", ...) do
        local v = S.Value((select(i, ...)))
        if type(v) == "string" then
            if v == escaped then cast.escaped = true return end
            if v == notHooked then cast.notHooked = true return end
        end
    end
end

---------------------------------------------------------------------------
-- Encounters
---------------------------------------------------------------------------
local SCAN_UNITS = { "target", "mouseover" }
for i = 1, 40 do SCAN_UNITS[#SCAN_UNITS + 1] = "nameplate" .. i end

-- Who is attacking you: "P" (a player), "N" (an NPC) with { name, level,
-- class }, or nil when nothing readable targets you.
function Fishing.ScanAttacker()
    local npc
    for _, unit in ipairs(SCAN_UNITS) do
        if S.Call(UnitExists, unit) == true and S.Call(UnitIsUnit, unit .. "target", "player") == true
            and S.Call(UnitCanAttack, "player", unit) == true and S.Call(UnitIsDeadOrGhost, unit) ~= true then
            if S.Call(UnitIsPlayer, unit) == true then
                local facts = ns.ReadPlayerFacts(unit)
                return "P", { name = facts and facts.name, level = facts and (facts.skull and -1 or facts.level),
                    class = facts and facts.classFile }
            end
            if not npc then
                local name = S.Call(UnitName, unit)
                npc = { name = type(name) == "string" and name or nil, level = Num(S.Call(UnitLevel, unit)) }
            end
        end
    end
    if npc then return "N", npc end
    return nil
end

local function AddThreat(kind, who, place)
    local f = Store()
    local now = time()
    local rec = { t = now, m = place.mapID, x = place.x and math.floor(place.x * 1000 + 0.5) or nil,
        y = place.y and math.floor(place.y * 1000 + 0.5) or nil, k = kind, sub = place.sub, c = ns.Store.Me() }
    if who then
        rec.who = who.name and (who.name:gsub(",", "")) or nil
        rec.lvl, rec.cls = who.level, who.class
    end
    f.threats[#f.threats + 1] = rec
    while #f.threats > MAX_THREATS do table.remove(f.threats, 1) end
    local field = ({ N = "x", P = "p", ["?"] = "u", E = "e", e = "e", D = "d" })[kind]
    local s = f.session
    if s and field then s[field] = (s[field] or 0) + 1 s.last = now end
    if place.mapID and field then
        RememberMap(f, place.mapID, place.zone)
        local spot = Spot(f, place.mapID, place.sub)
        spot[field] = (spot[field] or 0) + 1
        if kind == "N" or kind == "P" or kind == "?" then
            local hb = Hour(now)
            spot.h[hb] = spot.h[hb] or { 0, 0 }
            spot.h[hb][2] = spot.h[hb][2] + 1
        end
        local cell = Cell(f, place.mapID, CellKey(place.x, place.y))
        if cell then cell[field] = (cell[field] or 0) + 1 end
    end
    if kind == "N" or kind == "P" or kind == "?" then lastThreat = { at = GetTime(), rec = rec } end
    ns.Data.Changed("fishing")
    return rec
end

local function ResolveAttack(kind, who)
    local p = pendingAttack
    pendingAttack = nil
    if not p or not db().fishingEnabled then return end
    AddThreat(kind or "?", who, p.place)
end

local function OnCombat()
    if not Fishing.IsFishing() then return end
    if cast then cast.interrupted = true end
    lastActivity = GetTime()
    if GetTime() - lastOwnAction <= SELF_START then return end
    pendingAttack = { at = GetTime(), place = Place() }
    local kind, who = Fishing.ScanAttacker()
    if kind then ResolveAttack(kind, who) end
end

local function OnDeath()
    if not db().fishingEnabled then return end
    local recent = lastThreat and GetTime() - lastThreat.at <= DEATH_WINDOW
    if not Fishing.IsFishing() and not recent then return end
    if recent then
        lastThreat.rec.died = true
        local f = Store()
        local p = lastThreat.rec
        if f.session then f.session.d = (f.session.d or 0) + 1 end
        local spot = p.m and f.spots[p.m] and f.spots[p.m][p.sub]
        if spot then spot.d = (spot.d or 0) + 1 end
        lastThreat = nil
    else
        AddThreat("D", nil, Place())
    end
end

-- Enemy players the Spotter lists while you fish.
local function OnSpotted(entry, source, isNew)
    if not isNew or not db().fishingEnabled or not Fishing.IsFishing() or entry.dead then return end
    local hostile = entry.hostile == true
    AddThreat(hostile and "E" or "e", { name = entry.name, level = entry.skull and -1 or entry.level, class = entry.classFile }, Place())
    -- Hidden hostility never alerts (unknown is not "enemy"); it is only counted.
    if hostile and db().fishEnemySound and db().enabled and db().alertsEnabled then
        local key = entry.key or "?"
        if GetTime() - (enemySoundAt[key] or -math.huge) >= ENEMY_SOUND_REPEAT then
            enemySoundAt[key] = GetTime()
            -- The enemy alert already played the sound for a loud enemy.
            if not (db().alertsEnabled and db().alertSound and ns.IsLoud(entry)) then ns.Alerts.PlayChosenSound() end
        end
    end
end

---------------------------------------------------------------------------
-- Reading the numbers
---------------------------------------------------------------------------
-- Catch rate, catches and value per hour of a tally (nil when too little).
function Fishing.Rates(t)
    t = t or NewTally()
    local hours = (t.s or 0) / 3600
    local tries = (t.c or 0) + (t.a or 0)
    local value, unpriced, unseen = Fishing.ItemsValue(t.it)
    local enough = (t.s or 0) >= MIN_MINUTES * 60
    return {
        casts = t.n or 0, catches = t.c or 0, hours = hours, escaped = t.a or 0, missed = t.m or 0,
        catchPct = tries > 0 and (t.c or 0) / tries or nil,
        perHour = enough and (t.c or 0) / hours or nil,
        value = value, unpriced = unpriced, unseen = unseen,
        perCatch = (t.c or 0) > 0 and value / t.c or nil,
        gph = enough and value / hours or nil,
    }
end

-- Attacks and sightings per fishing time. Rates are nil until there is
-- enough fishing time: little data is "?", never "safe".
function Fishing.Danger(d)
    local minutes = (d.s or 0) / 60
    local attacks = (d.x or 0) + (d.p or 0) + (d.u or 0)
    local out = { minutes = minutes, attacks = attacks, npc = d.x or 0, player = d.p or 0, unknown = d.u or 0,
        seen = d.e or 0, died = d.d or 0 }
    if minutes >= MIN_MINUTES then
        out.attackEvery = attacks > 0 and minutes / attacks or nil
        out.npcEvery = (d.x or 0) > 0 and minutes / d.x or nil
        out.playerEvery = (d.p or 0) > 0 and minutes / d.p or nil
        out.seenEvery = (d.e or 0) > 0 and minutes / d.e or nil
    end
    -- Attacks as a Poisson process: the chance of 30 minutes without one.
    if minutes >= DANGER_MINUTES then out.quiet30 = math.exp(-30 * attacks / minutes) end
    return out
end

local function Minutes(m)
    if not m then return "?" end
    if m >= 90 then return string.format("%.1f h", m / 60) end
    return math.floor(m + 0.5) .. " min"
end
Fishing.Minutes = Minutes

-- Lines describing the danger of a spot or session.
function Fishing.DangerLines(d)
    local z = Fishing.Danger(d)
    local lines = {}
    if z.minutes < MIN_MINUTES then
        lines[1] = HEX.muted .. "Danger: ? (" .. Minutes(z.minutes) .. " fished: too little to tell)|r"
        return lines, z
    end
    local function Every(n, every, what)
        if n == 0 then return HEX.muted .. "no " .. what .. " in " .. Minutes(z.minutes) .. " fished|r" end
        return string.format("%d — one every %s fished", n, Minutes(every))
    end
    lines[#lines + 1] = "NPC attacks: " .. Every(z.npc, z.npcEvery, "NPC attacks")
    lines[#lines + 1] = "Player attacks: " .. Every(z.player, z.playerEvery, "player attacks")
    if z.unknown > 0 then lines[#lines + 1] = "Attacks by ?: " .. z.unknown .. HEX.muted .. "  (nothing readable targeted you)|r" end
    lines[#lines + 1] = "Enemy players seen: " .. Every(z.seen, z.seenEvery, "enemy players")
    if z.died > 0 then lines[#lines + 1] = HEX.bad .. "You died here " .. z.died .. (z.died == 1 and " time" or " times") .. " while fishing.|r" end
    if z.quiet30 then
        lines[#lines + 1] = string.format("Chance of 30 min without an attack: ~%d%%  %s(from your log)|r",
            math.floor(z.quiet30 * 100 + 0.5), HEX.muted)
    else
        lines[#lines + 1] = HEX.muted .. "Chance of a quiet half hour: ? (needs " .. DANGER_MINUTES .. " min fished)|r"
    end
    return lines, z
end

-- A spot's tally for your skill: your band if it has enough casts, else
-- the bands below yours (you would do at least as well), else above.
-- Returns tally, basis ("band", "lower", "higher", "all") and a label.
function Fishing.SpotTally(spot, skill)
    local merged = NewTally()
    if not skill then
        for _, t in pairs(spot.b) do MergeInto(merged, t) end
        return merged, "all", "all skills"
    end
    local band = Fishing.Band(skill)
    local own = spot.b[band]
    if own and (own.n or 0) >= MIN_CASTS then return own, "band", string.format("skill %d-%d", band, band + BAND - 1) end
    local lower, higher = NewTally(), NewTally()
    for b, t in pairs(spot.b) do
        if type(b) == "number" and b <= band then MergeInto(lower, t) elseif type(b) == "number" then MergeInto(higher, t) end
    end
    if lower.n > 0 then return lower, "lower", "skill up to " .. (band + BAND - 1) end
    if higher.n > 0 then return higher, "higher", HEX.gold .. "higher skill than yours|r" end
    for _, t in pairs(spot.b) do MergeInto(merged, t) end
    return merged, "all", "skill unknown"
end

-- Every spot: { mapID, name, map, spot, tally, basis, label, rates, danger }.
function Fishing.SpotList(skill)
    local f = Store()
    local out = {}
    for mapID, spots in pairs(f.spots) do
        for name, spot in pairs(spots) do
            local tally, basis, label = Fishing.SpotTally(spot, skill)
            out[#out + 1] = { mapID = mapID, name = name, map = f.maps[mapID] or tostring(mapID), spot = spot,
                tally = tally, basis = basis, label = label, rates = Fishing.Rates(tally), danger = Fishing.Danger(spot) }
        end
    end
    return out
end

function Fishing.GetSpot(mapID, name)
    local m = Store().spots[mapID]
    return m and m[name]
end

-- Maps you fished on: { { mapID, name, casts } } busiest first.
function Fishing.Maps()
    local f = Store()
    local out = {}
    for mapID, cells in pairs(f.cells) do
        local n = 0
        for _, t in pairs(cells) do n = n + (t.n or 0) + (t.e or 0) end
        out[#out + 1] = { mapID = mapID, name = f.maps[mapID] or tostring(mapID), casts = n }
    end
    table.sort(out, function(a, b) return a.casts > b.casts end)
    return out
end

-- The quietest 4-hour block of a spot with at least 10 minutes fished.
function Fishing.QuietestHours(spot)
    local best, bestRate
    for hb, v in pairs(spot.h or {}) do
        if v[1] >= 600 then
            local rate = v[2] / v[1]
            if not bestRate or rate < bestRate then best, bestRate = hb, rate end
        end
    end
    if not best then return nil end
    return string.format("%02d-%02d h", best * 4, best * 4 + 4), spot.h[best]
end

-- Catches per skill point over your last completed ranks (nil: too few).
function Fishing.CatchesPerPoint(rank)
    if not rank then return nil end
    local f = Store()
    local total, points = 0, 0
    for r = rank - 1, math.max(1, rank - 15), -1 do
        local n = f.ranks[r]
        if n then total, points = total + n, points + 1 end
        if points >= 5 then break end
    end
    if points < 2 then return nil end
    return total / points
end

-- Catches still needed for the next point (estimate), or nil.
function Fishing.NextPoint()
    local rank, _, max = Fishing.Skill()
    if not rank then return nil end
    if max and rank >= max then return 0, true end
    local per = Fishing.CatchesPerPoint(rank)
    if not per then return nil end
    return math.max(1, math.floor(per - (Store().ranks[rank] or 0) + 0.5)), false, per
end

-- Enemy player visits the Census counted within one square of a position.
function Fishing.CensusNear(mapID, x, y)
    if not (ns.Census and mapID and x) then return nil end
    local cells = ns.Census.Store().cells[mapID]
    if not cells then return 0 end
    local cx, cy = math.floor(x * GRID), math.floor(y * GRID)
    local n = 0
    for key, count in pairs(cells) do
        local kx, ky, _, rel = key:match("^(%d+):(%d+):([^:]*):([^:]*)")
        if kx and rel == "E" and math.abs(tonumber(kx) - cx) <= 1 and math.abs(tonumber(ky) - cy) <= 1 then n = n + count end
    end
    return n
end

-- Skill-ups per hour fished: vanilla's skill-up chance depends on your
-- skill, not the spot, so it is catches per hour over catches per point
-- (nil while either is unknown).
function Fishing.SkillUpsPerHour(rates, rank)
    local per = Fishing.CatchesPerPoint(rank or Fishing.Skill())
    if not (rates and rates.perHour and per and per > 0) then return nil end
    return rates.perHour / per
end

-- One cast log record parsed (11 fields in older records, more since).
function Fishing.ParseCast(s)
    if type(s) ~= "string" then return nil end
    local v = { strsplit(",", s) }
    local items = {}
    for id, n in (v[10] or ""):gmatch("(%d+):(%d+)") do items[tonumber(id)] = tonumber(n) end
    local serverMin = tonumber(v[13] or "")
    local x, y = tonumber(v[3] or ""), tonumber(v[4] or "")
    return { t = tonumber(v[1]), mapID = tonumber(v[2]), x = x and x / 1000, y = y and y / 1000, result = v[5],
        skill = tonumber(v[6] or ""), mod = tonumber(v[7] or ""), lure = v[8] == "1", level = tonumber(v[9] or ""),
        items = items, sub = v[11], lureID = tonumber(v[12] or ""), serverMin = serverMin,
        serverHour = serverMin and math.floor(serverMin / 60) or nil, channel = tonumber(v[14] or ""), tags = ParseTags(v[15]),
        c = tonumber(v[16] or "") }
end

-- Recent casts parsed: newest first, at most `max`.
function Fishing.RecentCasts(max)
    local f = Store()
    local out = {}
    for i = #f.casts, math.max(1, #f.casts - (max or 300) + 1), -1 do
        local e = Fishing.ParseCast(f.casts[i])
        if e then out[#out + 1] = e end
    end
    return out
end

---------------------------------------------------------------------------
-- Helpers while you fish: lure, bags, skill cap
---------------------------------------------------------------------------
local function Warn(text)
    if ns.Alerts then ns.Alerts.Show(text, { 1, 0.82, 0.2 }, false) end
    if db().alertSound and ns.Alerts then ns.Alerts.PlayChosenSound() end
end

local function CheckHelpers()
    if not db().fishAlerts or not Fishing.IsFishing() then
        lureWasOn = Fishing.Lure() == true
        return
    end
    local lure = Fishing.Lure()
    if lure == true then
        lureWasOn, lureWarned = true, false
    elseif lure == false and lureWasOn and not lureWarned then
        lureWarned, lureWasOn = true, false
        Warn("Fishing: your lure ran out")
    end
    local free = Fishing.FreeSlots()
    if free and free <= (db().fishBagWarn or 2) then
        if not bagWarned then
            bagWarned = true
            Warn(free == 0 and "Fishing: your bags are full" or ("Fishing: " .. free .. " bag slots left"))
        end
    elseif free then
        bagWarned = false
    end
    local rank, _, max = Fishing.Skill()
    if rank and max and rank >= max and max < 300 then
        if not capWarned then
            capWarned = true
            Warn(string.format("Fishing %d / %d: train the next rank to keep gaining skill", rank, max))
        end
    else
        capWarned = false
    end
end

---------------------------------------------------------------------------
-- Auto loot while fishing: the game's own "Auto Loot" option (CVar
-- autoLootDefault) is turned on at your first cast and put back when you
-- unequip your fishing pole. The value it had is saved (fishAutoLootRestore), so a
-- /reload or logout mid-fishing still restores it at the next login. If you
-- change the option yourself meanwhile, your choice is left alone.
---------------------------------------------------------------------------
-- Auto loot and the loud splash stay while the pole is in your hands and
-- go back the moment you take it off; when the game does not say what you
-- hold, 45 s after your last cast.
local function FishingSettingsEnd()
    local pole = Fishing.PoleEquipped()
    if pole ~= nil then return pole == false end
    return not Fishing.IsFishing()
end

local AUTOLOOT_CVAR = "autoLootDefault"

-- True when the game took the new value (SetCVar can say no without an error).
local function TrySetCVar(name, value)
    local ok, accepted = ns.SetCVarValue(name, value)
    return ok and accepted ~= false
end


function Fishing.AutoLootOn()
    local v = ns.GetCVarNumber(AUTOLOOT_CVAR)
    if v == nil then return nil end
    return v > 0
end

local function AutoLootStart()
    if not db().fishAutoLoot or db().fishAutoLootRestore ~= nil then return end
    if not Fishing.CheckLeftovers() then return end
    local on = Fishing.AutoLootOn()
    if on ~= nil then db().fishAutoLootLast = on and 1 or 0 end
    if on ~= false then return end
    if TrySetCVar(AUTOLOOT_CVAR, 1) then db().fishAutoLootRestore = "0" end
end

-- Puts your setting back (if we changed it and you did not since).
-- A saved value is dropped only once it is back, or you changed the setting
-- yourself; a write the game refused is tried again on the next tick. When
-- the setting cannot be read, it is put back anyway (we set it, so "back"
-- is the safe side).
function Fishing.AutoLootRestore()
    local restore = db().fishAutoLootRestore
    if restore == nil then return end
    if Fishing.AutoLootOn() == false or TrySetCVar(AUTOLOOT_CVAR, restore) then db().fishAutoLootRestore = nil end
end

-- Loud splash while fishing: addons get no event when a fish bites (the
-- bobber is a game object they cannot watch), so the splash is made hard to
-- miss instead: sound effects full, music and ambience off, and sound kept
-- on while the game is in the background. Same rule as auto loot: only
-- settings that differ are changed, the old values are saved
-- (fishSoundRestore) and put back when you stop fishing, and a setting you
-- change yourself meanwhile is left alone.
-- The game's master sound switch (Sound_EnableAllSound) is never touched: a
-- game you muted stays muted.
local SPLASH_CVARS = {
    { "Sound_EnableSFX", 1 }, { "Sound_SFXVolume", 1 },
    { "Sound_MusicVolume", 0 }, { "Sound_AmbienceVolume", 0 }, { "Sound_EnableSoundWhenGameIsInBG", 1 },
}

local function IsFishingValue(name, value)
    for _, cv in ipairs(SPLASH_CVARS) do
        if cv[1] == name then return value ~= nil and math.abs(value - cv[2]) <= 0.001 end
    end
    return false
end

local function SplashStart()
    if not db().fishLoudSplash or db().fishSoundRestore ~= nil then return end
    if not Fishing.CheckLeftovers() then return end
    -- Your usual sound, kept across sessions: after a crash it is the only
    -- record of it. Not learned from values that already are the fishing ones.
    local normal, differs = {}, false
    for _, cv in ipairs(SPLASH_CVARS) do
        normal[cv[1]] = ns.GetCVarNumber(cv[1])
        if normal[cv[1]] ~= nil and not IsFishingValue(cv[1], normal[cv[1]]) then differs = true end
    end
    if differs then db().fishSoundLast = normal end
    local saved = {}
    for _, cv in ipairs(SPLASH_CVARS) do
        local current = ns.GetCVarNumber(cv[1])
        if current ~= nil and math.abs(current - cv[2]) > 0.001 and TrySetCVar(cv[1], cv[2]) then
            saved[cv[1]] = current
        end
    end
    db().fishSoundRestore = saved
end

function Fishing.SplashRestore()
    local saved = db().fishSoundRestore
    if saved == nil then return end
    local ours = {}
    for _, cv in ipairs(SPLASH_CVARS) do ours[cv[1]] = cv[2] end
    for name, old in pairs(saved) do
        local current = ns.GetCVarNumber(name)
        local changedByYou = current ~= nil and ours[name] ~= nil and math.abs(current - ours[name]) > 0.001
        if changedByYou or TrySetCVar(name, old) then saved[name] = nil end
    end
    if next(saved) == nil then db().fishSoundRestore = nil end
end

---------------------------------------------------------------------------
-- After a crash. Logout puts everything back, but a crash skips logout and
-- the game then saves no addon data either: the note of what to put back
-- is lost, while the game may have kept the fishing sound / auto loot. So
-- your usual settings are also kept from your last clean session
-- (fishSoundLast, fishAutoLootLast), and at login, or your first cast, if
-- the settings are exactly the fishing ones with nothing pending, you are
-- asked whether to put your usual ones back. Asked, not done: you may have
-- chosen those values yourself.
---------------------------------------------------------------------------
local leftoverChecked, leftoverPending = false, nil
local enteredAt                -- GetTime() of the first PLAYER_ENTERING_WORLD

-- At a clean logout (fishing settings already put back): what you have now
-- is your usual, so a change you made yourself is never taken for a leftover.
function Fishing.LearnUsual()
    local normal, differs = {}, false
    for _, cv in ipairs(SPLASH_CVARS) do
        normal[cv[1]] = ns.GetCVarNumber(cv[1])
        if normal[cv[1]] ~= nil and not IsFishingValue(cv[1], normal[cv[1]]) then differs = true end
    end
    if db().fishSoundRestore == nil then db().fishSoundLast = differs and normal or nil end
    local on = Fishing.AutoLootOn()
    if on ~= nil and db().fishAutoLootRestore == nil then db().fishAutoLootLast = on and 1 or 0 end
end

-- What looks left over: { sound = { [cvar] = usual }, loot = true } or nil.
function Fishing.FindLeftovers()
    local d = db()
    local out
    local last = d.fishSoundLast
    if d.fishSoundRestore == nil and type(last) == "table" then
        local fix, all = {}, true
        for _, cv in ipairs(SPLASH_CVARS) do
            local usual = last[cv[1]]
            if usual ~= nil and not IsFishingValue(cv[1], usual) then
                if IsFishingValue(cv[1], ns.GetCVarNumber(cv[1])) then fix[cv[1]] = usual else all = false end
            end
        end
        if all and next(fix) then out = { sound = fix } end
    end
    if d.fishAutoLoot and d.fishAutoLootRestore == nil and d.fishAutoLootLast == 0 and Fishing.AutoLootOn() == true then
        out = out or {}
        out.loot = true
    end
    return out
end

-- Runs once per session. Returns false while the question is open (the
-- fishing settings wait, so they do not learn the leftovers as "usual").
function Fishing.CheckLeftovers()
    if leftoverPending then return false end
    if leftoverChecked then return true end
    leftoverChecked = true
    local found = Fishing.FindLeftovers()
    if not found then return true end
    leftoverPending = found
    local what = {}
    if found.sound then what[#what + 1] = "sound (music / ambience off, effects full)" end
    if found.loot then what[#what + 1] = "Auto Loot on" end
    StaticPopup_Show(ns.POPUP .. "FISHING_LEFTOVER", table.concat(what, " and "), nil, found)
    return false
end

function Fishing.FixLeftovers(found, apply)
    leftoverPending = nil
    if not found then return end
    if apply then
        for name, usual in pairs(found.sound or {}) do TrySetCVar(name, usual) end
        if found.loot then TrySetCVar(AUTOLOOT_CVAR, 0) end
        ns.Print("your usual sound and auto loot settings are back.")
    else
        -- Yours now: remember them as usual.
        if found.sound then db().fishSoundLast = nil end
        if found.loot then db().fishAutoLootLast = 1 end
    end
end

StaticPopupDialogs[ns.POPUP .. "FISHING_LEFTOVER"] = {
    text = ns.NAME .. ": your %s look like its fishing settings, left over from a game that closed while you fished "
        .. "(a crash?). Put back your usual settings?",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function(self, found) Fishing.FixLeftovers(found, true) end,
    OnCancel = function(self, found) Fishing.FixLeftovers(found, false) end,
    timeout = 0, whileDead = true, hideOnEscape = false, preferredIndex = 3,
}

function Fishing.SetLoudSplash(on)
    db().fishLoudSplash = on and true or false
    if on then
        if cast or Fishing.IsFishing() then SplashStart() end
    else
        Fishing.SplashRestore()
    end
    ns.Print("loud splash while fishing " .. (on and "on: sound effects up, music and ambience off while you fish, put back when you unequip your pole (a muted game stays muted)."
        or "off."))
end

---------------------------------------------------------------------------
-- Sound check and repair, for when the splash settings got stuck (a crash
-- with no record of your usual sound never asks the leftover question).
-- Each setting goes back to the value saved when fishing changed it, else
-- your usual from your last clean session, else the game's own default.
-- "Game defaults" skips the first two. The master switch is only reported.
---------------------------------------------------------------------------
local SOUND_LABELS = {
    Sound_EnableSFX = "Sound effects", Sound_SFXVolume = "Effects volume", Sound_MusicVolume = "Music volume",
    Sound_AmbienceVolume = "Ambience volume", Sound_EnableSoundWhenGameIsInBG = "Sound in background",
}

local function CVarDefault(name)
    local fn = (C_CVar and C_CVar.GetCVarDefault) or GetCVarDefault
    if type(fn) ~= "function" then return nil end
    return tonumber((S.Call(fn, name)))
end

local function SoundTarget(name, defaults)
    if not defaults then
        local pending = type(db().fishSoundRestore) == "table" and Num(db().fishSoundRestore[name])
        if pending then return pending, "saved when fishing changed it" end
        local last = type(db().fishSoundLast) == "table" and Num(db().fishSoundLast[name])
        if last and not IsFishingValue(name, last) then return last, "your usual" end
    end
    local default = CVarDefault(name)
    if default ~= nil then return default, "game default" end
    return nil, "unknown"
end

-- { { name, label, now, fishing, target, from }, ... }, masterOn (nil = unknown)
function Fishing.SoundReport(defaults)
    local rows = {}
    for _, cv in ipairs(SPLASH_CVARS) do
        local now = ns.GetCVarNumber(cv[1])
        local target, from = SoundTarget(cv[1], defaults)
        rows[#rows + 1] = { name = cv[1], label = SOUND_LABELS[cv[1]] or cv[1], now = now,
            fishing = IsFishingValue(cv[1], now), target = target, from = from }
    end
    local master = ns.GetCVarNumber("Sound_EnableAllSound")
    if master == nil then return rows, nil end
    return rows, master > 0
end

local function Fmt(v)
    if v == nil then return "?" end
    return (string.format("%.2f", v):gsub("%.?0+$", ""))
end

function Fishing.SoundCheck()
    local rows, master = Fishing.SoundReport()
    ns.Print("sound check (loud splash " .. (db().fishLoudSplash and "on" or "off") .. "):")
    local stuck, fishingNow = 0, Fishing.PoleEquipped() == true
    for _, r in ipairs(rows) do
        local off = r.now ~= nil and r.target ~= nil and math.abs(r.now - r.target) > 0.001
        if off and r.fishing then stuck = stuck + 1 end
        ns.Print("  " .. r.label .. ": " .. Fmt(r.now) .. (r.fishing and " (fishing value)" or "")
            .. (off and ("  →  back to " .. Fmt(r.target) .. " (" .. r.from .. ")") or "  ok"))
    end
    if master == false then
        ns.Print("  Master sound is OFF (the game's switch; " .. ns.NAME .. " never touches it): Ctrl+S or the game's Sound settings.")
    end
    if db().fishSoundRestore ~= nil then
        ns.Print(fishingNow and "Changed for fishing now; put back when you unequip your pole."
            or "Waiting to be put back (retried every second). Stuck? " .. ns.Cmd.Text("fish") .. " sound reset")
    elseif stuck > 0 and not fishingNow then
        ns.Print("Looks left over from fishing: " .. ns.Cmd.Text("fish") .. " sound reset (your usual) or " .. ns.Cmd.Text("fish") .. " sound default (game defaults).")
    else
        ns.Print("Nothing looks stuck.")
    end
end

-- Puts every splash setting back. Returns how many changed and how many the game refused.
function Fishing.RestoreSound(defaults)
    local changed, failed = 0, 0
    local pending = db().fishSoundRestore
    for _, r in ipairs((Fishing.SoundReport(defaults))) do
        local ok = true
        if r.target ~= nil and (r.now == nil or math.abs(r.now - r.target) > 0.001) then
            ok = TrySetCVar(r.name, r.target)
            if ok then changed = changed + 1 else failed = failed + 1 end
        end
        if ok and type(pending) == "table" then pending[r.name] = nil end
    end
    if type(pending) == "table" and next(pending) == nil then db().fishSoundRestore = nil end
    if failed == 0 then db().fishSoundRestore = nil end
    -- What you have now is your usual (the leftover check compares against it).
    Fishing.LearnUsual()
    ns.Print((defaults and "game default sound" or "your usual sound") .. " back: " .. changed .. " setting(s) changed"
        .. (failed > 0 and (", " .. failed .. " refused by the game (try again out of combat)") or "") .. "."
        .. (db().fishLoudSplash and " Loud splash is still on: your next cast turns it loud again (" .. ns.Cmd.Text("fish") .. " splash off)." or ""))
    return changed, failed
end

-- Seconds into the cast in progress and the channel's length (from the game,
-- else 30 s), or nil.
function Fishing.CastElapsed()
    if not cast or cast.ended then return nil end
    return GetTime() - cast.start, cast.duration or DEFAULT_CHANNEL
end

function Fishing.SetAutoLoot(on)
    db().fishAutoLoot = on and true or false
    if on then
        if cast or Fishing.IsFishing() then AutoLootStart() end
    else
        Fishing.AutoLootRestore()
    end
    ns.Print("auto loot while fishing " .. (on and "on: your Auto Loot option is turned on while you fish and put back when you unequip your pole."
        or "off."))
end

---------------------------------------------------------------------------
-- Events and tick
---------------------------------------------------------------------------
local function OnEvent(event, ...)
    -- Your settings come back even with the fishing log turned off.
    if event == "PLAYER_ENTERING_WORLD" then enteredAt = enteredAt or GetTime() end
    if event == "PLAYER_LOGOUT" then
        -- The game writes its settings at logout: yours, not the fishing ones,
        -- in case TALOD is not there next time. The next cast sets them again.
        Fishing.AutoLootRestore()
        Fishing.SplashRestore()
        if not leftoverPending then Fishing.LearnUsual() end
        return
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        if db().fishAutoLootRestore ~= nil and FishingSettingsEnd() then Fishing.AutoLootRestore() end
        if db().fishSoundRestore ~= nil and FishingSettingsEnd() then Fishing.SplashRestore() end
        if ns.FishingUI then ns.FishingUI.UpdateHUD() end
        return
    end
    if not db().fishingEnabled then return end
    if event == "UNIT_SPELLCAST_CHANNEL_START" or event == "UNIT_SPELLCAST_SUCCEEDED" or event == "UNIT_SPELLCAST_START" then
        local unit, _, spellID = ...
        if S.Value(unit) ~= "player" then return end
        if IsFishingSpell(spellID) then
            if event == "UNIT_SPELLCAST_CHANNEL_START" or not cast then StartCast() end
            AutoLootStart()
            SplashStart()
        else
            lastOwnAction = GetTime()
        end
    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        local unit, _, spellID = ...
        if S.Value(unit) == "player" and (IsFishingSpell(spellID) or S.Value(spellID) == nil) then StopCast() end
    elseif event == "LOOT_OPENED" or event == "LOOT_READY" then
        OnLoot()
    elseif event == "UI_ERROR_MESSAGE" then
        OnUIError(...)
    elseif event == "PLAYER_ENTER_COMBAT" then
        lastOwnAction = GetTime()
    elseif event == "PLAYER_REGEN_DISABLED" then
        OnCombat()
    elseif event == "PLAYER_DEAD" then
        OnDeath()

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- A loading screen ends any cast.
        if cast then cast.ended = cast.ended or GetTime() Finish(Outcome(cast)) end
        pendingAttack = nil
    end
end

local lastHelperCheck = 0
local function Tick()
    if not leftoverChecked and enteredAt and GetTime() - enteredAt >= 3 then Fishing.CheckLeftovers() end
    if not db().fishingEnabled then
        if db().fishAutoLootRestore ~= nil then Fishing.AutoLootRestore() end
        if db().fishSoundRestore ~= nil then Fishing.SplashRestore() end
        return
    end
    local now = GetTime()
    if cast then
        local duration = cast.duration or DEFAULT_CHANNEL
        if cast.ended and now - cast.ended >= LOOT_GRACE then
            Finish(Outcome(cast))
        elseif not cast.ended and now - cast.start > duration + MAX_OVERRUN then
            -- No stop event (missed during a loading screen): it ran out.
            cast.ended = cast.start + duration
            Finish(Outcome(cast))
        end
    end
    if pendingAttack then
        local kind, who = Fishing.ScanAttacker()
        if kind or now - pendingAttack.at >= ATTACK_SCAN then ResolveAttack(kind, who) end
    end
    if now - lastHelperCheck >= 1 then
        lastHelperCheck = now
        CheckHelpers()
        if db().fishAutoLootRestore ~= nil and FishingSettingsEnd() then Fishing.AutoLootRestore() end
        if db().fishSoundRestore ~= nil and FishingSettingsEnd() then Fishing.SplashRestore() end
        local s = Store().session
        if s and not cast and time() - (s.last or 0) > SESSION_IDLE then Fishing.CloseSession() end
        if ns.FishingUI then ns.FishingUI.UpdateHUD() end
    end
end

---------------------------------------------------------------------------
-- Chat summary, delete
---------------------------------------------------------------------------
function Fishing.SummaryLines()
    local lines = {}
    local s = Store().session
    local rank, mod, max = Fishing.Skill()
    lines[#lines + 1] = "Fishing skill: " .. (rank and string.format("%d%s / %d", rank, (mod or 0) ~= 0 and (" (+" .. mod .. ")") or "", max or 0) or "?")
    if s then
        lines[#lines + 1] = "This session — " .. SessionSummary(s)
    else
        lines[#lines + 1] = "No fishing session running."
    end
    local p = Place()
    local spot = p.mapID and Fishing.GetSpot(p.mapID, p.sub)
    if spot then
        local tally, _, label = Fishing.SpotTally(spot, Fishing.Effective())
        local r = Fishing.Rates(tally)
        lines[#lines + 1] = string.format("Here (%s, %s): %s caught, %s per catch, %s/h", p.sub, label,
            r.catchPct and (math.floor(r.catchPct * 100 + 0.5) .. "%") or "?",
            r.perCatch and ns.Professions.Money(r.perCatch) or "?", r.gph and ns.Professions.Money(r.gph) or "?")
        for _, line in ipairs((Fishing.DangerLines(spot))) do lines[#lines + 1] = "  " .. line end
    else
        lines[#lines + 1] = "Not fished here yet."
    end
    return lines
end

-- what: "casts" (recent cast log only) or "all".
function Fishing.Delete(what)
    local f = Store()
    f.casts = {}
    if what == "all" then
        for _, key in ipairs({ "spots", "cells", "maps", "threats", "sessions", "ranks", "lures", "pools", "goals" }) do f[key] = {} end
        f.session = nil
    end
    cast, pendingAttack, lastThreat = nil, nil, nil
end

StaticPopupDialogs[ns.POPUP .. "FISHING_DELETE"] = {
    text = "Delete " .. ns.NAME .. " %s?",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function(self, what)
        Fishing.Delete(what)
        ns.Print(what == "all" and "fishing data deleted." or "recent fishing casts deleted (spots, heat map and sessions kept).")
        ns.Refresh()
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local function StatusLine()
    local f = Store()
    local spots, maps = 0, 0
    for _, m in pairs(f.spots) do
        maps = maps + 1
        for _ in pairs(m) do spots = spots + 1 end
    end
    return string.format("%d recent casts (max %d), %d spots on %d maps, %d sessions, %d encounters.", #f.casts,
        db().fishMaxCasts or 0, spots, maps, #f.sessions, #f.threats)
end

local function Slash(command, rest)
    if command ~= "fish" then return false end
    local arg = (rest or ""):lower()
    local UI = ns.FishingUI
    if arg == "" then
        UI.Toggle("now")
    elseif arg == "spots" or arg == "map" or arg == "log" or arg == "sessions" or arg == "now" then
        UI.Show(arg)
    elseif arg == "hud" then
        db().fishHud = not db().fishHud
        ns.Print("fishing HUD " .. (db().fishHud and "on (shows while you fish)." or "off."))
    elseif arg == "hud reset" then
        db().fishHudPos = nil
        if UI.ResetHUD then UI.ResetHUD() end
    elseif arg == "stats" or arg == "here" then
        for _, line in ipairs(Fishing.SummaryLines()) do ns.Print(line) end
    elseif arg == "on" or arg == "off" then
        db().fishingEnabled = arg == "on"
        ns.Print("fishing log " .. arg .. ".")
    elseif arg == "autoloot" or arg == "autoloot on" or arg == "autoloot off" then
        Fishing.SetAutoLoot(arg == "autoloot" and not db().fishAutoLoot or arg == "autoloot on")
    elseif arg == "splash" or arg == "splash on" or arg == "splash off" then
        Fishing.SetLoudSplash(arg == "splash" and not db().fishLoudSplash or arg == "splash on")
    elseif arg == "sound" or arg == "sound check" then
        Fishing.SoundCheck()
    elseif arg == "sound reset" or arg == "sound default" then
        Fishing.RestoreSound(arg == "sound default")
    elseif arg == "end" then
        local s = Fishing.CloseSession()
        ns.Print(s and ("session ended — " .. SessionSummary(s)) or "no fishing session running.")
    elseif arg == "clear" then
        StaticPopup_Show(ns.POPUP .. "FISHING_DELETE", "fishing data (all spots, heat maps, sessions and logs)", nil, "all")
    else
        local handled = false
        for _, fn in ipairs(slashHandlers) do
            if fn(arg) then handled = true break end
        end
        if not handled then
            ns.Print(ns.Cmd.Text("fish") .. " [now|spots|map|log|sessions|stats|hud|hud reset|autoloot|splash|sound|sound reset|sound default|end|on|off|clear"
                .. (#slashUsage > 0 and ("|" .. table.concat(slashUsage, "|")) or "") .. "]")
        end
    end
    ns.Refresh()
    return true
end

---------------------------------------------------------------------------
-- Settings tab
---------------------------------------------------------------------------
local function BuildPage(parent)
    local W = ns.Options.Widgets
    local y = -12
    y = W.Paragraph(parent, y, "Logs every cast: where, your skill and lure, what you caught or that it got away. "
        .. "Shows what each spot is worth per hour at your skill, a heat map of where each fish came from, and how "
        .. "often NPCs or enemy players attacked you there. Attackers are read from units targeting you: turn on enemy "
        .. "nameplates (V) so NPCs are seen too. Run |cffffffffpython tools/fishing_viewer.py|r for HTML heat maps.",
        "GameFontHighlightSmall")
    local rowY = y
    W.Button(parent, rowY, "Open the fishing window", 190, function() ns.FishingUI.Show("now") end, "Also " .. ns.Cmd.Text("fish") .. ".")
    W.Button(parent, rowY, "Heat map", 120, function() ns.FishingUI.Show("map") end, "Also " .. ns.Cmd.Text("fish") .. " map.", 214)
    y = y - 34
    y = W.Header(parent, y, "Recording")
    y = W.Checkbox(parent, y, "fishingEnabled", "Log my fishing", "Casts, catches, spots, attacks and enemy players seen while fishing.")
    y = W.Header(parent, y, "While fishing")
    y = W.Checkbox(parent, y, "fishHud", "Show the fishing HUD", "A panel like Enemies nearby while a fishing pole is equipped (gone when "
        .. "you swap it out): session, value and gold per hour, skill and the next point, lure, bag space, enemies in view, danger here, "
        .. "and a bar for the cast. Drop it next to the Enemies nearby panel to snap them together; General > Panel's Size applies to both.")
    y = W.Checkbox(parent, y, "fishHudLocked", "Lock the fishing HUD", "Locked: Shift + drag still moves it.")
    y = W.Checkbox(parent, y, "fishAlerts", "Warn me", "When your lure runs out, your bags are almost full or your skill reaches its maximum.")
    y = W.Slider(parent, y, "fishBagWarn", "Bags almost full at", 0, 10, 1, "%d free")
    y = W.Checkbox(parent, y, "fishEnemySound", "Sound for every enemy player while fishing",
        "Your alert sound for each enemy player spotted while you fish, not only loud ones (fishing keeps your eyes on the bobber). "
        .. "Never for a player whose hostility is hidden.")
    y = W.LiveText(parent, y, 18, function()
        local on = Fishing.AutoLootOn()
        return "Auto loot while fishing: " .. (db().fishAutoLoot and "|cff40ff40on|r" or "off") .. "  ·  the game's Auto Loot option is "
            .. (on == nil and "?" or (on and "on" or "off")) .. (db().fishAutoLootRestore ~= nil and " (turned on for fishing, put back after)" or "")
    end)
    y = W.Button(parent, y, "Auto loot while fishing: on / off", 240, function()
        Fishing.SetAutoLoot(not db().fishAutoLoot)
        ns.Refresh()
    end, "Turns the game's Auto Loot option on at your first cast if it is off, and back off once you stop fishing "
        .. "(the moment you unequip your fishing pole, also after a /reload). Also " .. ns.Cmd.Text("fish") .. " autoloot.")
    y = W.Button(parent, y, "Loud splash while fishing: on / off", 240, function()
        Fishing.SetLoudSplash(not db().fishLoudSplash)
        ns.Refresh()
    end, "The game tells addons nothing when a fish bites, so the splash is made hard to miss: sound effects full, "
        .. "music and ambience off, sound on while the game is in the background. Put back as soon as you unequip your "
        .. "fishing pole. Also " .. ns.Cmd.Text("fish") .. " splash.")
    y = W.LiveText(parent, y, 18, function()
        return "Loud splash while fishing: " .. (db().fishLoudSplash and "|cff40ff40on|r" or "off")
            .. (db().fishSoundRestore ~= nil and "  (sound changed for fishing now, put back after)" or "")
    end)
    rowY = y
    W.Button(parent, rowY, "Check my sound", 130, function() Fishing.SoundCheck() end,
        "Prints each sound setting the loud splash changes: now, and what it goes back to. Also " .. ns.Cmd.Text("fish") .. " sound.")
    W.Button(parent, rowY, "Put my sound back", 150, function() Fishing.RestoreSound(false) ns.Refresh() end,
        "Each setting back to the value before fishing, else your usual from your last clean session, else the game's "
        .. "default. For sound stuck after a crash or a bug. Also " .. ns.Cmd.Text("fish") .. " sound reset.", 154)
    W.Button(parent, rowY, "Game default sound", 150, function() Fishing.RestoreSound(true) ns.Refresh() end,
        "Effects, music, ambience and background sound to the game's own defaults. The master sound switch is never "
        .. "changed. Also " .. ns.Cmd.Text("fish") .. " sound default.", 312)
    y = y - 34
    y = W.Checkbox(parent, y, "fishSessionSummary", "Chat summary when a session ends", "A session ends after 5 minutes without a cast.")
    y = W.Button(parent, y, "Reset the HUD position", 190, function()
        db().fishHudPos = nil
        if ns.FishingUI.ResetHUD then ns.FishingUI.ResetHUD() end
    end)
    y = W.Header(parent, y, "Data")
    y = W.LiveText(parent, y, 30, StatusLine)
    y = W.Slider(parent, y, "fishMaxCasts", "Keep at most", 2000, 50000, 2000, "%d casts",
        "The cast log is detail; spots, heat map squares and sessions are kept forever.")
    rowY = y
    W.Button(parent, rowY, "Delete the cast log", 170, function()
        StaticPopup_Show(ns.POPUP .. "FISHING_DELETE", "recent fishing casts (spots, heat map and sessions are kept)", nil, "casts")
    end)
    W.Button(parent, rowY, "Delete all fishing data", 170, function()
        StaticPopup_Show(ns.POPUP .. "FISHING_DELETE", "fishing data (all spots, heat maps, sessions and logs)", nil, "all")
    end, nil, 200)
    y = y - 34
    return -y + 10
end

-- Other fishing modules add their own pages to this tab (Fishing.settingsTab.pages).
Fishing.settingsTab = { label = "Fishing", pages = { { label = "Fishing", build = BuildPage } } }
ns.Options.AddTab(Fishing.settingsTab)

-- The "fishing" source (Data.lua): casts, attacks and sessions say when they
-- change; the signature catches writes that do not.
ns.Data.Source("fishing", { sig = function()
    local s = Store()
    return #s.casts .. ":" .. tostring(s.casts[#s.casts]) .. ":" .. #s.threats .. ":" .. #s.sessions
end })

ns.RegisterModule("Fishing", {
    defaults = {
        fishingEnabled = true,
        fishHud = true,
        fishHudLocked = false,
        fishAlerts = true,
        fishBagWarn = 2,
        fishEnemySound = true,
        fishSessionSummary = false,
        fishAutoLoot = false,
        fishLoudSplash = true,
        fishMaxCasts = 20000,
        fishing = {},
    },
    playerEvents = { "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_SUCCEEDED",
        "UNIT_SPELLCAST_START" },
    events = { "LOOT_OPENED", "LOOT_READY", "UI_ERROR_MESSAGE", "PLAYER_ENTER_COMBAT", "PLAYER_REGEN_DISABLED",
        "PLAYER_DEAD", "PLAYER_ENTERING_WORLD", "PLAYER_EQUIPMENT_CHANGED", "PLAYER_LOGOUT" },
    init = function()
        Store()
        ns.Spotter.On("spotted", OnSpotted)
    end,
    onEvent = OnEvent,
    tick = Tick,
    -- The panel's Size setting applies to the HUD too (they snap together).
    refresh = function() if ns.FishingUI and ns.FishingUI.ApplyHUDStyle then ns.FishingUI.ApplyHUDStyle() end end,
    slash = Slash,
})
