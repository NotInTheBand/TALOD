-- TALOD - Gear: a ledger of your gear and what it did to your character.
--
-- Snapshots hold every equipped item (full links, enchants included), your
-- measured character stats and the conditions behind them (level, talents,
-- passive spells, form, weapon enchants, buffs: see Conditions.lua), so two
-- snapshots taken under different conditions are flagged, not compared blindly.
-- Talent changes get their own ledger entries with the stat difference. They are taken when your gear changes (after it
-- settles, so a set swap is one change), on level-up, at login when the gear
-- differs from the last one, and on demand with a name.
--
-- The ledger says what changed and what it did: the measured stat difference
-- right before and right after the swap (what the character sheet really
-- gained, including effects tooltips do not list), and the item-stat
-- difference from the tooltips (unaffected by buffs). A buff that started or
-- ended during the swap is flagged, since it moves the measured numbers.
-- Level-ups get their own entries, so gear and leveling stay apart.
--
-- New equippable items in your bags are noted with where they came from: the
-- window you had open (loot, quest reward, vendor, mail, trade, crafting,
-- auction house). Chat messages are not parsed: they may be secret on Forever.
--
-- WoW Forever hides your own stats from addons in combat. Nothing is
-- measured then: changes made in combat (a level-up from a kill, a weapon
-- swap) are measured when combat ends, and "before" is only refreshed out of
-- combat. A snapshot saved with hidden stats anyway (older versions, or
-- stats still hidden two minutes after combat) is marked partial and filled
-- in at the next readable moment with the same level and gear.
--
-- Data is per character, account wide: TALODDB.gear["Name-Realm"].

local ADDON_NAME, ns = ...
local S = ns.Secret

local Gear = {}
ns.Gear = Gear

-- Paper-doll order.
local SLOTS = {
    { 1, "Head" }, { 2, "Neck" }, { 3, "Shoulder" }, { 15, "Back" }, { 5, "Chest" }, { 4, "Shirt" }, { 19, "Tabard" },
    { 9, "Wrist" }, { 10, "Hands" }, { 6, "Waist" }, { 7, "Legs" }, { 8, "Feet" }, { 11, "Finger 1" }, { 12, "Finger 2" },
    { 13, "Trinket 1" }, { 14, "Trinket 2" }, { 16, "Main hand" }, { 17, "Off hand" }, { 18, "Ranged" },
}
Gear.SLOTS = SLOTS
local SLOT_NAMES = {}
for _, s in ipairs(SLOTS) do SLOT_NAMES[s[1]] = s[2] end
Gear.SLOT_NAMES = SLOT_NAMES

-- Measured stats, in display order. fmt: "%d" whole numbers, "%.2f%%" percent, ...
local STATS = {
    { "str", "Strength" }, { "agi", "Agility" }, { "sta", "Stamina" }, { "int", "Intellect" }, { "spi", "Spirit" },
    { "hp", "Health" }, { "mana", "Mana" }, { "armor", "Armor" }, { "def", "Defense" },
    { "dodge", "Dodge", "pct" }, { "parry", "Parry", "pct" }, { "block", "Block", "pct" },
    { "ap", "Attack power" }, { "rap", "Ranged attack power" }, { "crit", "Melee crit", "pct" },
    { "rcrit", "Ranged crit", "pct" }, { "hit", "Hit (gear)", "pct" },
    { "dmgMin", "Main hand min" }, { "dmgMax", "Main hand max" }, { "speed", "Main hand speed", "dec" }, { "dps", "Main hand DPS", "dec" },
    { "spell", "Spell damage" }, { "heal", "Healing" }, { "scrit", "Spell crit", "pct" }, { "shit", "Spell hit (gear)", "pct" },
    { "regen", "Mana regen (per 5 s)", "dec" },
    { "resFire", "Fire resistance" }, { "resNature", "Nature resistance" }, { "resFrost", "Frost resistance" },
    { "resShadow", "Shadow resistance" }, { "resArcane", "Arcane resistance" },
}
Gear.STATS = STATS
local RESISTANCES = { [2] = "resFire", [3] = "resNature", [4] = "resFrost", [5] = "resShadow", [6] = "resArcane" }

-- Measured stat -> the tooltip stat it comes from, for "from gear" figures.
Gear.ITEM_STAT_FOR = {
    str = "ITEM_MOD_STRENGTH_SHORT", agi = "ITEM_MOD_AGILITY_SHORT", sta = "ITEM_MOD_STAMINA_SHORT",
    int = "ITEM_MOD_INTELLECT_SHORT", spi = "ITEM_MOD_SPIRIT_SHORT", armor = "RESISTANCE0_NAME",
}

local SETTLE = 2               -- seconds after the last equipment change before measuring
local REFRESH = 5              -- seconds between "before" refreshes while nothing changes
local MAX_SNAPSHOTS, MAX_LEDGER, MAX_ACQUIRED = 500, 1000, 1000
local SOURCE_GRACE = 4         -- an item arriving this soon after a window closed came from it
local GIVE_UP = 120            -- out of combat with stats still hidden this long: record what is readable
local since = {}               -- kind -> GetTime() of the first event of a pending change
local lastCombat = 0           -- GetTime() while last seen in combat

local current                  -- last stable capture: the "before" of the next change
local pendingEquip, pendingBefore, pendingLevel, pendingTalents
local Conditions = ns.Conditions
local lastRefresh = 0
local loginAt
local context = { open = {}, closed = {} }   -- window kind -> true / GetTime() of closing

local function db() return ns.DB() end

local function Round(v, places)
    local m = 10 ^ (places or 2)
    return math.floor(v * m + 0.5) / m
end

local function Num(v) return type(v) == "number" and v or nil end

---------------------------------------------------------------------------
-- Reading the character
---------------------------------------------------------------------------
function Gear.CharKey() return ns.Store.CharKey() end

-- The record for a character (default: you), created on demand.
function Gear.Char(key)
    key = key or Gear.CharKey()
    if not key then return nil end
    local all = db().gear
    local c = all[key]
    if not c then
        c = { snapshots = {}, ledger = {}, acquired = {}, seen = {} }
        all[key] = c
    end
    return c, key
end

local function ReadStats()
    local s = {}
    for i, key in ipairs({ "str", "agi", "sta", "int", "spi" }) do
        s[key] = Num((select(2, S.CallMulti(2, UnitStat, "player", i))))
    end
    s.hp = Num(S.Call(UnitHealthMax, "player"))
    if S.Call(UnitPowerType, "player") == 0 then s.mana = Num(S.Call(UnitPowerMax, "player", 0)) end
    s.armor = Num((select(2, S.CallMulti(2, UnitArmor, "player"))))
    local base, mod = S.CallMulti(2, UnitDefense, "player")
    if Num(base) then s.def = base + (Num(mod) or 0) end
    s.dodge, s.parry, s.block = Num(S.Call(GetDodgeChance)), Num(S.Call(GetParryChance)), Num(S.Call(GetBlockChance))
    local ap, pos, neg = S.CallMulti(3, UnitAttackPower, "player")
    if Num(ap) then s.ap = ap + (Num(pos) or 0) + (Num(neg) or 0) end
    local rap, rpos, rneg = S.CallMulti(3, UnitRangedAttackPower, "player")
    if Num(rap) then s.rap = rap + (Num(rpos) or 0) + (Num(rneg) or 0) end
    s.crit, s.rcrit = Num(S.Call(GetCritChance)), Num(S.Call(GetRangedCritChance))
    s.hit, s.shit = Num(S.Call(GetHitModifier)), Num(S.Call(GetSpellHitModifier))
    local lo, hi = S.CallMulti(2, UnitDamage, "player")
    s.dmgMin, s.dmgMax = Num(lo), Num(hi)
    s.speed = Num(S.Call(UnitAttackSpeed, "player"))
    if s.dmgMin and s.dmgMax and s.speed and s.speed > 0 then s.dps = (s.dmgMin + s.dmgMax) / 2 / s.speed end
    -- Spell schools 2-7 (holy .. arcane): the best one is what a caster cares about.
    local spell, scrit
    for school = 2, 7 do
        local d, c = Num(S.Call(GetSpellBonusDamage, school)), Num(S.Call(GetSpellCritChance, school))
        if d and (not spell or d > spell) then spell = d end
        if c and (not scrit or c > scrit) then scrit = c end
    end
    s.spell, s.scrit = spell, scrit
    s.heal = Num(S.Call(GetSpellBonusHealing))
    local regen = Num(S.Call(GetManaRegen))
    if regen and s.mana then s.regen = regen * 5 end
    for index, key in pairs(RESISTANCES) do
        s[key] = Num((select(2, S.CallMulti(2, UnitResistance, "player", index))))
    end
    -- Stored compactly: zeros and float noise dropped.
    for key, v in pairs(s) do
        v = Round(v, 2)
        s[key] = v ~= 0 and v or nil
    end
    return s
end
Gear.ReadStats = ReadStats

local function ZoneName()
    local zone = S.Call(GetZoneText)
    return type(zone) == "string" and zone ~= "" and zone or nil
end

local function Capture()
    local items = {}
    for _, slot in ipairs(SLOTS) do
        local link = S.Call(GetInventoryItemLink, "player", slot[1])
        items[slot[1]] = type(link) == "string" and link or nil
    end
    local cond = Conditions.Capture()
    local stats = ReadStats()
    return { t = time(), level = Num(S.Call(UnitLevel, "player")), zone = ZoneName(), items = items,
        stats = stats, complete = Gear.StatsReadable(stats) and not ns.InCombat(),
        buffSig = cond.buffs, buffs = cond.buffCount,
        talents = cond.talents, passives = cond.passives, form = cond.form, weapon = cond.weapon }
end
Gear.Capture = Capture

-- Primary stats and armor present: the game let us read the sheet.
function Gear.StatsReadable(stats)
    return type(stats) == "table" and stats.sta ~= nil and stats.armor ~= nil
end

-- A stored snapshot whose stats were hidden when it was taken.
function Gear.IsPartial(snap)
    return snap and (snap.partial or not Gear.StatsReadable(snap.stats)) and true or false
end

local function SameItems(a, b)
    for _, slot in ipairs(SLOTS) do
        if a[slot[1]] ~= b[slot[1]] then return false end
    end
    return true
end

---------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------
-- Tooltip stats of an item link: { ITEM_MOD_STAMINA_SHORT = 5, ... }, or nil
-- while the item is not cached yet.
function Gear.ItemStats(link)
    if type(link) ~= "string" then return nil end
    local fn = (C_Item and C_Item.GetItemStats) or GetItemStats
    if type(fn) ~= "function" then return nil end
    local ok, t = pcall(fn, link)
    t = ok and S.Value(t) or nil
    if type(t) ~= "table" then return nil end
    local out = {}
    for k, v in pairs(t) do
        if type(k) == "string" and Num(S.Value(v)) then out[k] = S.Value(v) end
    end
    return out
end

-- Sum of tooltip stats over a set of items; complete is false when an item
-- was not cached.
function Gear.ItemTotals(items)
    local total, complete = {}, true
    for _, link in pairs(items or {}) do
        local st = Gear.ItemStats(link)
        if st then
            for k, v in pairs(st) do total[k] = (total[k] or 0) + v end
        else
            complete = false
        end
    end
    return total, complete
end

-- Icon and equip location without needing the item cache.
function Gear.ItemBasics(link)
    if type(link) ~= "string" then return nil end
    local fn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if type(fn) ~= "function" then return nil end
    local ok, id, _, _, equipLoc, icon = pcall(fn, link)
    if not ok then return nil end
    return S.Value(id), S.Value(equipLoc), S.Value(icon)
end

-- "Item name" from a link, for chat and plain text.
function Gear.ItemName(link)
    return type(link) == "string" and link:match("|h%[(.-)%]|h") or link
end

-- Label for a tooltip stat key: the game's own string when it has one.
function Gear.ItemStatLabel(key)
    local text = _G[key]
    if type(text) == "string" and not text:find("%%") then return text end
    return (key:gsub("^ITEM_MOD_", ""):gsub("_SHORT$", ""):gsub("_", " "):lower():gsub("^%l", string.upper))
end

local function Diff(a, b)
    local out, any = {}, false
    for k, v in pairs(b or {}) do
        local d = Round(v - ((a or {})[k] or 0), 2)
        if d ~= 0 then out[k], any = d, true end
    end
    for k, v in pairs(a or {}) do
        if (b or {})[k] == nil and v ~= 0 then out[k], any = -v, true end
    end
    return any and out or nil
end
Gear.Diff = Diff

---------------------------------------------------------------------------
-- Snapshots and ledger
---------------------------------------------------------------------------
local TALENT_EVENT = {}
for _, event in ipairs(Conditions.TALENT_EVENTS) do TALENT_EVENT[event] = true end

-- The key of a talent / passive read (capture table) or stored key (string).
function Gear.Sig(v)
    if type(v) == "table" then return v.sig end
    return v
end

function Gear.TalentSet(c, key) return c and c.talentSets and c.talentSets[key] or nil end
function Gear.PassiveSet(c, key) return c and c.passiveSets and c.passiveSets[key] or nil end

-- Lines saying how the conditions of two snapshots differ (empty = same).
function Gear.ConditionDiff(c, a, b)
    return Conditions.Describe(a, b, function(k) return Gear.TalentSet(c, k) end, function(k) return Gear.PassiveSet(c, k) end)
end

local function Trim(list, max)
    while #list > max do table.remove(list, 1) end
end

local function SaveSnapshot(c, cap, reason, name)
    local snap = { t = cap.t, level = cap.level, zone = cap.zone, items = cap.items, stats = cap.stats,
        buffs = cap.buffs > 0 and cap.buffs or nil, buffList = (cap.buffSig or "") ~= "" and cap.buffSig or nil,
        form = cap.form, weapon = cap.weapon, reason = reason, name = name,
        partial = (not Gear.StatsReadable(cap.stats)) or nil }
    -- Talent and passive sets are stored once each; snapshots point at them.
    if cap.talents then
        c.talentSets = c.talentSets or {}
        local t = cap.talents
        c.talentSets[t.sig] = c.talentSets[t.sig] or { summary = t.summary, source = t.source, tabs = t.tabs, picks = t.picks }
        snap.talents = t.sig
    end
    if cap.passives then
        c.passiveSets = c.passiveSets or {}
        c.passiveSets[cap.passives.sig] = c.passiveSets[cap.passives.sig] or { ids = cap.passives.ids }
        snap.passives = cap.passives.sig
    end
    c.snapshots[#c.snapshots + 1] = snap
    -- Manual snapshots are the player's: trim automatic ones first.
    while #c.snapshots > MAX_SNAPSHOTS do
        local victim = 1
        for i, s in ipairs(c.snapshots) do
            if s.reason ~= "manual" then victim = i break end
        end
        table.remove(c.snapshots, victim)
    end
    for _, link in pairs(cap.items) do c.seen[link] = true end
    return snap
end

local function SourceOf(c, link)
    for i = #c.acquired, 1, -1 do
        local a = c.acquired[i]
        if a.link == link then return a end
    end
    return nil
end

local function AddLedger(c, entry)
    c.ledger[#c.ledger + 1] = entry
    Trim(c.ledger, MAX_LEDGER)
    ns.Data.Changed("gear")
    return entry
end

-- Measured difference, only when both sheets were readable.
local function Measured(before, after)
    if not (before and Gear.StatsReadable(before.stats) and Gear.StatsReadable(after.stats)) then return nil end
    return Diff(before.stats, after.stats)
end

-- Fills in the newest snapshot when it was saved with hidden stats and the
-- character is still at that level in that gear, and recomputes the
-- measured change of its ledger entry from the snapshot before it.
local function Repair(c, cap)
    local s = c and c.snapshots[#c.snapshots]
    if not s or not cap.complete or not Gear.IsPartial(s) then return end
    if s.level ~= cap.level or not SameItems(s.items, cap.items) then return end
    s.stats, s.partial, s.repaired = cap.stats, nil, true
    local prev = c.snapshots[#c.snapshots - 1]
    for i = #c.ledger, 1, -1 do
        local e = c.ledger[i]
        if e.snapTime == s.t then
            if prev and Gear.StatsReadable(prev.stats) then e.delta = Diff(prev.stats, s.stats) end
            e.hidden, e.repaired = nil, true
            break
        end
        if (e.snapTime or e.t or 0) < s.t then break end
    end
    ns.Data.Changed("gear")
end
Gear.Repair = Repair

-- Still waiting for readable stats for this pending change? Counted from
-- the change or the end of combat, whichever is later: changes made in
-- combat stay queued until it ends, then get GIVE_UP seconds to be readable.
local function Waiting(kind, cap)
    if cap.complete then return false end
    return GetTime() - math.max(since[kind] or GetTime(), lastCombat) < GIVE_UP
end

-- Records a gear change from `before` to `after` (both captures).
local function RecordChange(c, before, after, offline)
    local changes = {}
    local oldItems, newItems = {}, {}
    for _, slot in ipairs(SLOTS) do
        local id = slot[1]
        local old, new = before.items[id], after.items[id]
        if old ~= new then
            local src = new and SourceOf(c, new)
            changes[#changes + 1] = { slot = id, old = old, new = new,
                src = src and { kind = src.kind, detail = src.detail, zone = src.zone, level = src.level, t = src.t, cost = src.cost } or nil }
            oldItems[id], newItems[id] = old, new
        end
    end
    if #changes == 0 then return nil end
    local snap = SaveSnapshot(c, after, "equip")
    local oldTotals, oldComplete = Gear.ItemTotals(oldItems)
    local newTotals, newComplete = Gear.ItemTotals(newItems)
    return AddLedger(c, {
        kind = "gear", t = after.t, level = after.level, zone = after.zone, changes = changes,
        delta = Measured(before, after),
        hidden = Measured(before, after) == nil and not (Gear.StatsReadable(before.stats) and Gear.StatsReadable(after.stats)) or nil,
        itemDelta = (oldComplete and newComplete) and Diff(oldTotals, newTotals) or nil,
        buffsChanged = before.buffSig ~= after.buffSig or nil,
        levelChanged = before.level ~= after.level or nil,
        talentsChanged = Gear.Sig(before.talents) ~= Gear.Sig(after.talents) or nil,
        formChanged = (before.form ~= after.form and before.form and after.form) and true or nil,
        weaponChanged = (before.weapon ~= after.weapon and before.weapon and after.weapon) and true or nil,
        offline = offline or nil,
        snapTime = snap.t,
    })
end

local function CommitEquip()
    local after = Capture()
    if Waiting("equip", after) then return end
    local c = Gear.Char()
    local before = pendingBefore
    pendingEquip, pendingBefore, since.equip = nil, nil, nil
    if c and before then RecordChange(c, before, after) end
    if after.complete or not current then current = after end
end

-- Talents or passive spells changed (respec, a point spent, a new passive):
-- an entry with what changed and the measured stat difference.
local function CommitTalents()
    local after = Capture()
    if Waiting("talents", after) then return end
    pendingTalents, since.talents = nil, nil
    local c = Gear.Char()
    local before = current
    if after.complete then current = after end
    if not c or not before then return end
    local talentsChanged = Gear.Sig(before.talents) ~= Gear.Sig(after.talents)
    local passivesChanged = Gear.Sig(before.passives) ~= Gear.Sig(after.passives)
    if not talentsChanged and not passivesChanged then return end
    SaveSnapshot(c, after, "talents")
    local entry = { kind = "talents", t = after.t, level = after.level, zone = after.zone,
        delta = Measured(before, after), hidden = not after.complete or nil, buffsChanged = before.buffSig ~= after.buffSig or nil,
        levelChanged = before.level ~= after.level or nil, snapTime = after.t }
    if talentsChanged then
        entry.talentsBefore = before.talents and before.talents.summary
        entry.talentsAfter = after.talents and after.talents.summary
        entry.talentsGained, entry.talentsLost = Conditions.TalentDiff(before.talents, after.talents)
    end
    if passivesChanged then
        entry.passivesGained, entry.passivesLost = Conditions.PassiveDiff(before.passives, after.passives)
    end
    AddLedger(c, entry)
end

local function CommitLevel()
    local after = Capture()
    if Waiting("level", after) then return end
    pendingLevel, since.level = nil, nil
    local c = Gear.Char()
    if not c then return end
    local before = current
    SaveSnapshot(c, after, "level")
    AddLedger(c, { kind = "level", t = after.t, level = after.level, zone = after.zone,
        delta = Measured(before, after), hidden = not after.complete or nil,
        buffsChanged = before and before.buffSig ~= after.buffSig or nil, snapTime = after.t })
    if after.complete then current = after end
end

-- At login: a first snapshot, or a change made while the addon was off.
local function LoginCheck()
    local c = Gear.Char()
    if not c then return end
    local cap = Capture()
    local last = c.snapshots[#c.snapshots]
    if not last then
        SaveSnapshot(c, cap, "first")
    elseif not SameItems(last.items, cap.items) then
        RecordChange(c, { items = last.items, stats = last.stats, level = last.level, buffSig = last.buffList or "",
            talents = last.talents, passives = last.passives, form = last.form, weapon = last.weapon }, cap, true)
    end
    local name = S.Call(UnitName, "player")
    c.name = type(name) == "string" and name or c.name
    c.class = select(2, S.CallMulti(2, UnitClass, "player")) or c.class
    c.race = select(2, S.CallMulti(2, UnitRace, "player")) or c.race
    c.faction = S.CallMulti(1, UnitFactionGroup, "player") or c.faction
    c.level = cap.level or c.level
    current = cap
end

function Gear.TakeSnapshot(name)
    local c = Gear.Char()
    if not c then return nil end
    local cap = Capture()
    local snap = SaveSnapshot(c, cap, "manual", (name and name ~= "") and name or nil)
    current = current or cap
    ns.Data.Changed("gear")
    return snap
end

function Gear.DeleteSnapshot(key, index)
    local c = db().gear[key]
    if c and c.snapshots[index] then table.remove(c.snapshots, index) end
end

function Gear.DeleteCharacter(key)
    db().gear[key] = nil
    if key == Gear.CharKey() then current = nil end
end

---------------------------------------------------------------------------
-- Where items came from
---------------------------------------------------------------------------
local WINDOW_EVENTS = {
    LOOT_OPENED = { "loot", true }, LOOT_CLOSED = { "loot", false },
    QUEST_COMPLETE = { "quest", true }, QUEST_FINISHED = { "quest", false },
    MERCHANT_SHOW = { "vendor", true }, MERCHANT_CLOSED = { "vendor", false },
    MAIL_SHOW = { "mail", true }, MAIL_CLOSED = { "mail", false },
    TRADE_SHOW = { "trade", true }, TRADE_CLOSED = { "trade", false },
    TRADE_SKILL_SHOW = { "craft", true }, TRADE_SKILL_CLOSE = { "craft", false },
    AUCTION_HOUSE_SHOW = { "auction", true }, AUCTION_HOUSE_CLOSED = { "auction", false },
}
local SOURCE_ORDER = { "loot", "quest", "vendor", "trade", "craft", "mail", "auction" }

local function CurrentSource()
    local now = GetTime()
    for _, kind in ipairs(SOURCE_ORDER) do
        if context.open[kind] then return kind end
    end
    local best, bestT
    for kind, t in pairs(context.closed) do
        if now - t <= SOURCE_GRACE and (not bestT or t > bestT) then best, bestT = kind, t end
    end
    return best or "other"
end

local function OnWindow(event)
    local w = WINDOW_EVENTS[event]
    local kind, open = w[1], w[2]
    context.open[kind] = open or nil
    if not open then context.closed[kind] = GetTime() end
    if kind == "vendor" and open then context.money = Num(S.Call(GetMoney)) end
    if kind == "quest" and open then
        local title = S.Call(GetTitleText)
        context.quest = type(title) == "string" and title ~= "" and title or nil
    end
    if kind == "loot" and open then
        local name = S.Call(UnitName, "target")
        context.lootFrom = (S.Call(UnitIsDead, "target") and type(name) == "string") and name or nil
    end
end

-- Gear never sits in the reagent bag.
local function EachBagLink(fn)
    ns.Utils.EachBagSlot(function(_, _, link) fn(link) end, "general")
end

local function IsGear(link)
    local _, equipLoc = Gear.ItemBasics(link)
    return type(equipLoc) == "string" and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE"
        and equipLoc ~= "INVTYPE_BAG" and equipLoc ~= "INVTYPE_AMMO" and equipLoc ~= "INVTYPE_QUIVER"
end

function Gear.ScanBags()
    local c = Gear.Char()
    if not c then return end
    local baseline = not c.baseline
    local kind = CurrentSource()
    local added = false
    EachBagLink(function(link)
        if not IsGear(link) or c.seen[link] then return end
        c.seen[link] = true
        added = true
        if baseline or not db().gearSources then return end
        local a = { t = time(), link = link, kind = kind, zone = ZoneName(), level = Num(S.Call(UnitLevel, "player")) }
        if kind == "quest" then a.detail = context.quest
        elseif kind == "loot" then a.detail = context.lootFrom
        elseif kind == "vendor" and context.money then
            local now = Num(S.Call(GetMoney))
            if now and now < context.money then a.cost = context.money - now end
            context.money = now
        end
        c.acquired[#c.acquired + 1] = a
        Trim(c.acquired, MAX_ACQUIRED)
    end)
    c.baseline = true
    -- Every loot lands here: windows redraw only when a new item came in.
    if added or baseline then ns.Data.Changed("gear") end
end

---------------------------------------------------------------------------
-- Events and tick
---------------------------------------------------------------------------
local function OnEvent(event, ...)
    if not db().gearEnabled then return end
    if WINDOW_EVENTS[event] then
        OnWindow(event)
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        if not current then return end
        pendingBefore = pendingBefore or current
        pendingEquip = GetTime()
        since.equip = since.equip or pendingEquip
    elseif event == "PLAYER_LEVEL_UP" then
        pendingLevel = GetTime()
        since.level = since.level or pendingLevel
    elseif event == "BAG_UPDATE_DELAYED" then
        if current then Gear.ScanBags() end
    elseif event == "PLAYER_ENTERING_WORLD" then
        loginAt = loginAt or GetTime()
    elseif TALENT_EVENT[event] then
        Conditions.Invalidate((event == "SPELLS_CHANGED" or event == "LEARNED_SPELL_IN_TAB") and "passives" or nil)
        if current then
            pendingTalents = GetTime()
            since.talents = since.talents or pendingTalents
        end
    end
end

local function Tick()
    if not db().gearEnabled then return end
    local now = GetTime()
    -- Stats are not final for a moment after login.
    -- Your stats are hidden in combat: measure nothing until it ends.
    if ns.InCombat() then
        lastCombat = now
        return
    end
    if not current and loginAt and now - loginAt >= 3 then
        LoginCheck()
        Gear.ScanBags()
        return
    end
    if not current then return end
    if pendingEquip and now - pendingEquip >= SETTLE then CommitEquip() end
    if pendingLevel and now - pendingLevel >= SETTLE and not pendingEquip then CommitLevel() end
    if pendingTalents and now - pendingTalents >= SETTLE and not pendingEquip and not pendingLevel then CommitTalents() end
    -- Keep "before" fresh (buffs come and go) while nothing is pending.
    if not pendingEquip and not pendingLevel and not pendingTalents and now - lastRefresh >= REFRESH then
        lastRefresh = now
        local cap = Capture()
        if SameItems(cap.items, current.items) then
            if cap.complete then
                current = cap
                Repair(Gear.Char(), cap)
            end
        else
            -- A change without an event (rare): measure it like one.
            pendingBefore, pendingEquip = current, now
            since.equip = since.equip or now
        end
    end
end

function Gear.Stats(key)
    local c = key and db().gear[key] or Gear.Char()
    if not c then return 0, 0, 0 end
    return #c.snapshots, #c.ledger, #c.acquired
end

function Gear.Characters()
    local out = {}
    for key in pairs(db().gear) do out[#out + 1] = key end
    table.sort(out)
    return out
end

-- Text for a stat value. kind: nil whole number, "pct", "dec".
function Gear.FormatStat(kind, v, signed)
    if v == nil then return "-" end
    local text
    if kind == "pct" then text = string.format("%.2f%%", v)
    elseif kind == "dec" then text = string.format("%.2f", v)
    else text = string.format("%d", math.floor(v + 0.5)) end
    if signed and v > 0 then text = "+" .. text end
    return text
end

function Gear.StatInfo(key)
    for _, s in ipairs(STATS) do
        if s[1] == key then return s[2], s[3] end
    end
    return key, nil
end

-- "Armor +62 · Stamina +4 · Agility -1", biggest first, at most `max`.
function Gear.DeltaText(delta, max, itemStats)
    if not delta then return nil end
    local parts = {}
    for k, v in pairs(delta) do
        local label, kind
        if itemStats then label = Gear.ItemStatLabel(k) else label, kind = Gear.StatInfo(k) end
        parts[#parts + 1] = { label = label, v = v, text = Gear.FormatStat(kind, v, true) }
    end
    table.sort(parts, function(a, b)
        if (a.v > 0) ~= (b.v > 0) then return a.v > 0 end
        return math.abs(a.v) > math.abs(b.v)
    end)
    local out = {}
    for i, p in ipairs(parts) do
        if max and i > max then out[#out + 1] = "..." break end
        out[#out + 1] = (p.v > 0 and "|cff40ff40" or "|cffff5050") .. p.label .. " " .. p.text .. "|r"
    end
    return table.concat(out, "  ")
end

local SOURCE_LABELS = { loot = "Loot", quest = "Quest", vendor = "Vendor", trade = "Trade", craft = "Crafted",
    mail = "Mail", auction = "Auction house", other = "Other" }
function Gear.SourceText(src)
    if not src then return nil end
    local text = SOURCE_LABELS[src.kind] or src.kind
    if src.detail then text = text .. ": " .. src.detail end
    if src.cost and GetCoinTextureString then
        local ok, coins = pcall(GetCoinTextureString, src.cost)
        if ok then text = text .. " (" .. coins .. ")" end
    elseif src.cost then
        text = text .. string.format(" (%dg %ds %dc)", math.floor(src.cost / 10000), math.floor(src.cost / 100) % 100, src.cost % 100)
    end
    if src.zone then text = text .. ", " .. src.zone end
    if src.level then text = text .. ", level " .. src.level end
    return text
end

local function Slash(command, rest)
    if command ~= "gear" and command ~= "character" then return false end
    if command ~= "gear" then
        if ns.GearUI then ns.GearUI.Toggle() end
        return true
    end
    local sub, arg = (rest or ""):match("^(%S*)%s*(.-)$")
    sub = sub:lower()
    if sub == "snap" or sub == "snapshot" then
        local snap = Gear.TakeSnapshot(arg)
        if snap then ns.Print("snapshot taken" .. (snap.name and (": " .. snap.name) or "") .. ".") end
    elseif sub == "status" then
        local snaps, ledger, acquired = Gear.Stats()
        ns.Print(string.format("gear ledger %s: %d snapshots, %d ledger entries, %d items with a source.",
            db().gearEnabled and "on" or "off", snaps, ledger, acquired))
    elseif sub == "on" or sub == "off" then
        db().gearEnabled = sub == "on"
        ns.Print("gear ledger " .. sub .. ".")
    elseif ns.GearUI then
        ns.GearUI.Toggle("snapshots")
    end
    return true
end

---------------------------------------------------------------------------
-- Settings tab
---------------------------------------------------------------------------
local function BuildPage(parent)
    local W = ns.Options.Widgets
    local y = -12
    y = W.Paragraph(parent, y, "A ledger of your gear: snapshots of everything you wear and your character stats, what each "
        .. "change did to your stats (measured before and after, and from the tooltips), level-ups, and where each item "
        .. "came from. Per character; your alts are kept too.", "GameFontHighlightSmall")
    local rowY = y
    W.Button(parent, rowY, "Open gear window", 170, function() if ns.GearUI then ns.GearUI.Show() end end,
        "Also " .. ns.Cmd.Text("gear") .. ".")
    W.Button(parent, rowY, "Take a snapshot", 170, function()
        StaticPopup_Show(ns.POPUP .. "GEAR_SNAPSHOT")
    end, "Saves what you wear now, with a name you choose.", 200)
    y = y - 34
    y = W.Header(parent, y, "Recording")
    y = W.Checkbox(parent, y, "gearEnabled", "Track my gear and stats",
        "Snapshots on gear changes, level-ups and login.")
    y = W.Checkbox(parent, y, "gearSources", "Note where new items came from",
        "Loot, quest reward, vendor (with the price), mail, trade, crafting or auction house: the window you had open.")
    y = W.LiveText(parent, y, 30, function()
        local snaps, ledger, acquired = Gear.Stats()
        return string.format("This character: %d snapshots, %d ledger entries, %d items with a source. Characters: %d.",
            snaps, ledger, acquired, #Gear.Characters())
    end)
    y = W.Header(parent, y, "Delete")
    y = W.Button(parent, y, "Delete this character's gear data", 240, function()
        StaticPopup_Show(ns.POPUP .. "GEAR_DELETE", Gear.CharKey() or "?", nil, Gear.CharKey())
    end)
    return -y + 10
end

StaticPopupDialogs[ns.POPUP .. "GEAR_SNAPSHOT"] = {
    text = "Name this gear snapshot (optional):",
    button1 = OKAY or "OK",
    button2 = CANCEL or "Cancel",
    hasEditBox = true,
    maxLetters = 40,
    OnAccept = function(self)
        -- The edit box accessor differs between client generations.
        local box = self and ((self.GetEditBox and self:GetEditBox()) or self.editBox or self.EditBox)
        local name = box and box:GetText() or nil
        Gear.TakeSnapshot(name)
        ns.Print("snapshot taken" .. ((name and name ~= "") and (": " .. name) or "") .. ".")
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        StaticPopupDialogs[ns.POPUP .. "GEAR_SNAPSHOT"].OnAccept(parent)
        parent:Hide()
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs[ns.POPUP .. "GEAR_DELETE"] = {
    text = "Delete all " .. ns.NAME .. " gear data of %s?",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function(self, key)
        if key then Gear.DeleteCharacter(key) end
        ns.Print("gear data deleted.")
        ns.Refresh()
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- One "Character" settings tab; Skills adds its page to it.
ns.CharacterTab = { label = "Character", pages = { { label = "Gear", build = BuildPage } } }
ns.Options.AddTab(ns.CharacterTab)

local events = { "PLAYER_EQUIPMENT_CHANGED", "PLAYER_LEVEL_UP", "BAG_UPDATE_DELAYED", "PLAYER_ENTERING_WORLD" }
for event in pairs(WINDOW_EVENTS) do events[#events + 1] = event end
for _, event in ipairs(Conditions.TALENT_EVENTS) do events[#events + 1] = event end

ns.RegisterModule("Gear", {
    defaults = {
        gearEnabled = true,
        gearSources = true,
        gear = {},
    },
    events = events,
    onEvent = OnEvent,
    tick = Tick,
    slash = Slash,
})
