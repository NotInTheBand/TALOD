-- TALOD - core: settings, colors, range checks, enemy-player facts and the
-- threat score. Everything here reads only what the game already shows the
-- player; anything hidden (a secret value) is "unknown", never a guess.

local ADDON_NAME, ns = ...
local S = ns.Secret

-- The version comes from the TOC (written there with version.json by tools/version.py).
-- No number in the fallback: a stale one would claim a version that isn't loaded.
do
    local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local ok, version = false, nil
    if getMetadata then ok, version = pcall(getMetadata, ADDON_NAME, "Version") end
    ns.VERSION = (ok and type(version) == "string" and version ~= "") and version or "?"
end

local C = {}
ns.C = C

C.TICK_INTERVAL = 0.25           -- panel / range refresh
C.NAMEPLATE_DISTANCE_CVAR = "nameplateMaxDistance"
C.RECOMMENDED_NAMEPLATE_DISTANCE = 41
C.SKULL_MIN_DELTA = 10           -- Classic shows "??" (UnitLevel -1) at 10+ levels above you
C.MAX_RANGE_UNITS = 20           -- range-probe at most this many nameplates per tick
C.CLASSES = { "WARRIOR", "ROGUE", "MAGE", "PRIEST", "WARLOCK", "HUNTER", "DRUID", "SHAMAN", "PALADIN" }

ns.COLORS = {
    safe = {0.20, 1.00, 0.20},
    threshold = {1.00, 0.82, 0.15},
    danger = {1.00, 0.20, 0.20},
    neutral = {0.85, 0.85, 0.85},
    dim = {0.60, 0.60, 0.60},
    title = {1.00, 0.50, 0.25},
}

-- Blue / orange / magenta stays distinguishable for the common forms of
-- color blindness, where green vs red does not.
ns.COLORBLIND_COLORS = {
    safe = {0.35, 0.70, 1.00},
    threshold = {1.00, 0.60, 0.10},
    danger = {0.95, 0.25, 0.85},
}

function ns.GetColor(state)
    if ns.DB() and ns.DB().colorblind and ns.COLORBLIND_COLORS[state] then
        return ns.COLORBLIND_COLORS[state]
    end
    return ns.COLORS[state] or ns.COLORS.neutral
end

local function Hex(c)
    return string.format("|cff%02x%02x%02x", math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255))
end
ns.Hex = Hex

function ns.ColorCode(state) return Hex(ns.GetColor(state)) end

local FALLBACK_CLASS_COLORS = {
    WARRIOR = {0.78, 0.61, 0.43}, ROGUE = {1.00, 0.96, 0.41}, MAGE = {0.41, 0.80, 0.94},
    PRIEST = {1.00, 1.00, 1.00}, WARLOCK = {0.58, 0.51, 0.79}, HUNTER = {0.67, 0.83, 0.45},
    DRUID = {1.00, 0.49, 0.04}, SHAMAN = {0.00, 0.44, 0.87}, PALADIN = {0.96, 0.55, 0.73},
}

function ns.ClassColor(classFile)
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if type(c) == "table" and c.r then return { c.r, c.g, c.b } end
    return FALLBACK_CLASS_COLORS[classFile or ""] or ns.COLORS.neutral
end

function ns.ClassName(classFile)
    local names = LOCALIZED_CLASS_NAMES_MALE
    return (names and classFile and names[classFile]) or (classFile and (classFile:sub(1, 1) .. classFile:sub(2):lower())) or "?"
end

-- Level text and color relative to the player, like the game's own con
-- colors. A skull ("??") is always red.
function ns.LevelText(facts)
    if facts.skull then return "??" end
    return facts.level and tostring(facts.level) or "?"
end

function ns.LevelColor(facts)
    if facts.skull then return ns.GetColor("danger") end
    local mine = S.Call(UnitLevel, "player")
    if not facts.level or not mine then return ns.COLORS.neutral end
    local gap = facts.level - mine
    if gap >= 5 then return ns.GetColor("danger") end
    if gap >= 3 then return { 1.00, 0.50, 0.25 } end
    if gap >= -2 then return { 1.00, 1.00, 0.00 } end
    if gap >= -8 then return { 0.25, 0.75, 0.25 } end
    return ns.COLORS.dim
end

ns.defaults = {
    enabled = true,
    colorblind = false,

    -- Alerts
    alertsEnabled = true,
    alertOnNameplate = true,
    alertOnTarget = true,
    alertOnMouseover = true,
    alertMinLevelGap = -60,          -- alert only for enemies at least this many levels relative to you
    alertRepeatSeconds = 120,        -- per player
    alertCenterText = true,
    alertSound = true,
    alertSoundChoice = "raidwarning",
    alertChat = true,
    alertLoudAbove = 3,              -- "louder" alert for this many levels above you (and ??)
    alertLoudClasses = {},           -- [classFile] = true: always the loud alert
    alertLoudKoS = true,

    -- Nearby panel
    panelShown = true,
    panelLocked = false,
    panelScale = 1.0,
    panelRows = 8,
    panelPoint = { "TOPLEFT", "UIParent", "TOPLEFT", 260, -180 },
    panelFadeSeconds = 60,           -- keep an enemy listed this long after its nameplate is gone
    panelClickTarget = true,
    panelHideEmpty = false,
    panelDetails = true,             -- health, power, state tags and auras under each live row
    panelMaxAuras = 10,              -- aura icons per row (the row fits 10)

    -- Nameplate badges
    badgesEnabled = true,

    -- Target readout
    targetReadout = true,
    targetSpells = true,

    -- Safety (Hardcore)
    flagIndicator = true,
    flagLocked = false,
    flagPoint = { "TOP", "UIParent", "TOP", 0, -120 },
    flagWarnTarget = true,
    zoneBanner = true,

    -- Stealth
    vanishAlert = false,             -- heuristic, opt-in
    vanishMaxRange = 30,

    -- Journal
    journalEnabled = true,
    journalMax = 5000,
    journalMergeMinutes = 10,        -- one row per player per this many minutes
    players = {},                    -- [key] = { name, realm, class, race, level, guild, list, note, seen, firstSeen, lastSeen, kills, deaths }
    journal = {},                    -- sighting rows, oldest first

    -- One-time hints
    welcomeShown = false,
    distanceHintShown = false,
}

function ns.CopyDefaults(dst, src)
    for k, v in pairs(src) do
        if dst[k] == nil then
            if type(v) == "table" then
                dst[k] = {}
                ns.CopyDefaults(dst[k], v)
            else
                dst[k] = v
            end
        elseif type(v) == "table" and type(dst[k]) == "table" then
            ns.CopyDefaults(dst[k], v)
        end
    end
end

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------
function ns.FormatNumber(n)
    if n == nil then return "?" end
    if math.abs(n - math.floor(n)) < 0.001 then
        return tostring(math.floor(n))
    end
    return string.format("%.1f", n)
end

-- A range bracket as text. Unknown is "?", never a reassuring number.
function ns.FormatRange(lo, hi)
    if lo and hi then
        return ns.FormatNumber(lo) .. "–" .. ns.FormatNumber(hi) .. " yd"
    elseif hi then
        return "< " .. ns.FormatNumber(hi) .. " yd"
    elseif lo then
        return "> " .. ns.FormatNumber(lo) .. " yd"
    end
    return "? yd"
end

function ns.FormatAge(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    if seconds < 2 then return "now" end
    if seconds < 60 then return seconds .. "s" end
    if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
    if seconds < 86400 then return math.floor(seconds / 3600) .. "h" end
    return math.floor(seconds / 86400) .. "d"
end

---------------------------------------------------------------------------
-- Range checks
---------------------------------------------------------------------------
-- The game only tells addons whether a unit is within certain distances: the
-- range of a harmful item, the duel interact distance and your own spells.
-- Running all of them brackets the distance (lastOut < d <= firstIn). On
-- modern clients these answer for hostile units out of combat; in combat they
-- may return nothing, which shows as "?".
ns.ITEM_PROBES = {
    {5, 8149, "Voodoo Charm"},
    {10, 9606, "Treant Muisek Vessel"},
    {15, 4559, "CHU's QUEST ITEM"},
    {20, 1191, "Bag of Marbles"},
    {25, 13289, "Egan's Blaster"},
    {30, 835, "Large Rope Net"},
    {35, 18904, "Zorbin's Ultra-Shrinker"},
    {40, 4945, "Faintly Glowing Skull"},
}

-- Harmful spells with no minimum range, by class (rank 1 IDs; the range is
-- read from the client at runtime, so talents that add range are included).
local CLASS_RANGE_SPELLS = {
    ROGUE = { 2764, 2094, 6770, 921 },             -- Throw, Blind, Sap, Pick Pocket
    WARRIOR = { 2764, 5246 },                      -- Throw, Intimidating Shout
    HUNTER = { 1130 },                             -- Hunter's Mark
    MAGE = { 133, 116, 118, 2136, 2139, 5019 },    -- Fireball, Frostbolt, Polymorph, Fire Blast, Counterspell, Shoot
    PRIEST = { 585, 589, 8092, 5019 },             -- Smite, SW:Pain, Mind Blast, Shoot
    WARLOCK = { 686, 172, 348, 5782, 702, 5019 },  -- Shadow Bolt, Corruption, Immolate, Fear, Curse of Weakness, Shoot
    DRUID = { 5176, 8921, 339, 770 },              -- Wrath, Moonfire, Entangling Roots, Faerie Fire
    SHAMAN = { 403, 8042 },                        -- Lightning Bolt, Earth Shock
    PALADIN = { 853, 20271 },                      -- Hammer of Justice, Judgement
}

-- Spells worth knowing the range of before a fight, by class (rank 1 IDs).
-- Shown on the target readout as in range / out of range; minimum ranges
-- (Charge 8-25, Auto Shot 8-35) come from the client.
local CLASS_KEY_SPELLS = {
    WARRIOR = { 100, 20252, 1715, 6552, 5246 },    -- Charge, Intercept, Hamstring, Pummel, Intimidating Shout
    ROGUE = { 1766, 6770, 2094, 408, 2764 },       -- Kick, Sap, Blind, Kidney Shot, Throw
    MAGE = { 2139, 118, 116, 2136 },               -- Counterspell, Polymorph, Frostbolt, Fire Blast
    PRIEST = { 15487, 8092, 589, 585 },            -- Silence, Mind Blast, SW:Pain, Smite
    WARLOCK = { 5782, 6789, 686, 17877 },          -- Fear, Death Coil, Shadow Bolt, Shadowburn
    HUNTER = { 75, 19503, 5116, 2974, 1130 },      -- Auto Shot, Scatter Shot, Concussive Shot, Wing Clip, Hunter's Mark
    DRUID = { 339, 5211, 8921, 770 },              -- Entangling Roots, Bash, Moonfire, Faerie Fire
    SHAMAN = { 8042, 8056, 370, 403 },             -- Earth Shock, Frost Shock, Purge, Lightning Bolt
    PALADIN = { 853, 20271, 20066 },               -- Hammer of Justice, Judgement, Repentance
}

-- CheckInteractDistance index 3 (duel) on hostile units, measured by
-- LibRangeCheck-3.0; a few races differ.
local INTERACT_DUEL_RANGE = { Tauren = 6, Scourge = 7 }

local checkers = {}
ns.RANGE_CHECKERS = checkers
local keySpells = {}
ns.KEY_SPELLS = keySpells

local function SpellInfo(spellID)
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
        if ok and type(info) == "table" then
            return S.Value(info.minRange) or 0, S.Value(info.maxRange), S.Value(info.name)
        end
    end
    if GetSpellInfo then
        local ok, name, _, _, _, minRange, maxRange = pcall(GetSpellInfo, spellID)
        if ok then return S.Value(minRange) or 0, S.Value(maxRange), S.Value(name) end
    end
    return nil
end

local function KnowsSpell(spellID)
    if IsPlayerSpell then return S.Call(IsPlayerSpell, spellID) == true end
    if IsSpellKnown then return S.Call(IsSpellKnown, spellID) == true end
    return false
end

-- Returns true / false, or nil when the game gives no (readable) answer.
local function SpellInRange(spellID, name, unit)
    local ok, raw
    if C_Spell and C_Spell.IsSpellInRange then
        ok, raw = pcall(C_Spell.IsSpellInRange, spellID, unit)
    elseif IsSpellInRange and name then
        ok, raw = pcall(IsSpellInRange, name, unit)
    else
        return nil
    end
    if not ok or S.IsSecret(raw) then return nil end
    if raw == true or raw == 1 then return true end
    if raw == false or raw == 0 then return false end
    return nil
end

local function HasRange(range)
    for _, c in ipairs(checkers) do
        if math.abs(c.range - range) < 0.25 then return true end
    end
    return false
end

function ns.BuildRangeCheckers()
    for i = #checkers, 1, -1 do checkers[i] = nil end
    for i = #keySpells, 1, -1 do keySpells[i] = nil end
    for _, probe in ipairs(ns.ITEM_PROBES) do
        checkers[#checkers + 1] = { range = probe[1], kind = "item", id = probe[2], label = probe[3] }
    end
    if CheckInteractDistance then
        -- select(), not "UnitRace and UnitRace()": `and` keeps only the first return.
        local race = UnitRace and select(2, UnitRace("player"))
        local range = INTERACT_DUEL_RANGE[race or ""] or 8
        if not HasRange(range) then
            checkers[#checkers + 1] = { range = range, kind = "interact", id = 3, label = "Interact (duel)" }
        end
    end
    local classFile = UnitClass and select(2, UnitClass("player"))
    for _, spellID in ipairs(CLASS_RANGE_SPELLS[classFile or ""] or {}) do
        if KnowsSpell(spellID) then
            local minRange, maxRange, name = SpellInfo(spellID)
            if minRange == 0 and maxRange and maxRange >= 3 and maxRange <= 45 and not HasRange(maxRange) then
                checkers[#checkers + 1] = { range = maxRange, kind = "spell", id = spellID, label = name or ("spell " .. spellID) }
            end
        end
    end
    table.sort(checkers, function(a, b) return a.range < b.range end)

    for _, spellID in ipairs(CLASS_KEY_SPELLS[classFile or ""] or {}) do
        if KnowsSpell(spellID) then
            local minRange, maxRange, name = SpellInfo(spellID)
            keySpells[#keySpells + 1] = { id = spellID, name = name or ("spell " .. spellID), minRange = minRange or 0, maxRange = maxRange }
        end
    end
end

local function RunChecker(checker, unit)
    local ok, raw
    if checker.kind == "item" then
        if not ns.IsItemInRange then return nil end
        ok, raw = pcall(ns.IsItemInRange, checker.id, unit)
    elseif checker.kind == "interact" then
        ok, raw = pcall(CheckInteractDistance, unit, checker.id)
    else
        return SpellInRange(checker.id, checker.label, unit)
    end
    if not ok or S.IsSecret(raw) then return nil end
    if raw == true or raw == 1 then return true end
    if raw == false or raw == 0 then return false end
    return nil
end
ns.RunChecker = RunChecker

-- Returns lo, hi (either may be nil) and ok. Non-monotonic answers (OUT after
-- IN) mean the checks cannot be trusted right now: no bracket at all.
function ns.ProbeUnitRange(unit)
    if #checkers == 0 then ns.BuildRangeCheckers() end
    local lastOut, firstIn, sawIn, usable = nil, nil, false, 0
    for _, checker in ipairs(checkers) do
        local inRange = RunChecker(checker, unit)
        if inRange == false then
            usable = usable + 1
            if sawIn then return nil, nil, false end
            lastOut = checker.range
        elseif inRange == true then
            usable = usable + 1
            sawIn = true
            if firstIn == nil then firstIn = checker.range end
        end
    end
    if usable == 0 then return nil, nil, false end
    return lastOut, firstIn, true
end

-- Key spells for the target readout: { name, inRange (true/false/nil) } in
-- class order. Reuses one result table.
local spellResults, spellUnit, spellTick = {}, nil, nil
function ns.KeySpellRanges(unit)
    -- The plate readout and the panel footer both ask for the target each tick.
    local tick = ns.TickReads()
    if tick and spellTick == tick and spellUnit == unit then return spellResults end
    for i = #spellResults, #keySpells + 1, -1 do spellResults[i] = nil end
    if #checkers == 0 then ns.BuildRangeCheckers() end
    for i, spell in ipairs(keySpells) do
        local r = spellResults[i] or {}
        spellResults[i] = r
        r.name, r.minRange, r.maxRange = spell.name, spell.minRange, spell.maxRange
        r.inRange = SpellInRange(spell.id, spell.name, unit)
    end
    spellUnit, spellTick = unit, tick
    return spellResults
end

function ns.RequestProbeItemData()
    for _, probe in ipairs(ns.ITEM_PROBES) do ns.RequestItem(probe[2]) end
    ns.BuildRangeCheckers()
end

---------------------------------------------------------------------------
-- Enemy-player facts
---------------------------------------------------------------------------
-- True when a player is on your side even though UnitIsEnemy did not say so
-- (it is hidden at times, in combat especially, and an ally would then be
-- listed as an unknown "?" player). Your own
-- faction, your group or UnitIsFriend count; a readable "can attack" (duel,
-- mind control) or free-for-all PvP (Gurubashi Arena) always keeps them. With
-- hostile == true, only a readable "cannot attack" plus your faction filters.
function ns.IsAlly(unit, hostile)
    local canAttack = S.Call(UnitCanAttack, "player", unit)
    if canAttack == true then return false end
    if S.Call(UnitIsPVPFreeForAll, unit) == true then return false end
    if select(2, ns.ZonePvPInfo()) == true then return false end
    local mine = S.Call(UnitFactionGroup, "player")
    local theirs = S.Call(UnitFactionGroup, unit)
    local sameFaction = type(mine) == "string" and mine ~= "" and mine == theirs
    if hostile == true then return sameFaction and canAttack == false end
    if sameFaction then return true end
    if S.Call(UnitInParty, unit) == true or type(S.Call(UnitInRaid, unit)) == "number" then return true end
    return S.Call(UnitIsFriend, "player", unit) == true
end

-- Unit reads shared within one tick. Main.Tick brackets every module's tick
-- with Begin/EndTickReads; a read made there is kept for the rest of that
-- tick only (and only in the same frame, should EndTickReads ever be
-- skipped), never across events, where the target or a plate can change.
local tickActive, tickSerial, tickAt = false, 0, nil
local factsCache, unitCache = {}, {}

function ns.BeginTickReads()
    tickSerial, tickActive, tickAt = tickSerial + 1, true, GetTime()
    wipe(factsCache)
    wipe(unitCache)
end

function ns.EndTickReads()
    tickActive = false
    wipe(factsCache)
    wipe(unitCache)
end

-- The running tick's number while its reads are shared, else nil.
function ns.TickReads()
    if tickActive and tickAt == GetTime() then return tickSerial end
    return nil
end

-- A player's name, class, race, guild and honor rank do not change while
-- the same GUID stays on a nameplate: Spotter re-reads them this often.
local FIXED_FACTS_SECONDS = 5

-- Reads a unit as a player, friend or foe. Returns facts, or nil and a reason:
--   "missing", "not a player", "self", "restricted" (hidden facts).
-- Hostility is not looked at here; see ReadPlayerUnit. `known` (optional):
-- the last facts for this unit (a Spotter entry, with fullAt); while its GUID
-- still matches, only what changes (level, PvP flag, dead) is read again.
-- facts.fullAt is when the fixed facts were read.
local function ReadFacts(unit, known)
    local exists, existsSecret = S.Call(UnitExists, unit)
    if existsSecret then return nil, "restricted" end
    if not exists then return nil, "missing" end
    local isPlayer, playerSecret = S.Call(UnitIsPlayer, unit)
    if playerSecret then return nil, "restricted" end
    if not isPlayer then return nil, "not a player" end
    if S.Call(UnitIsUnit, unit, "player") then return nil, "self" end

    local f = { unit = unit }
    f.guid = S.Call(UnitGUID, unit)
    if known and f.guid and known.guid == f.guid and known.fullAt and GetTime() - known.fullAt < FIXED_FACTS_SECONDS then
        f.name, f.realm, f.className, f.classFile = known.name, known.realm, known.className, known.classFile
        f.race, f.raceFile, f.guild = known.race, known.raceFile, known.guild
        f.rankName, f.rankNumber = known.rankName, known.rankNumber
        f.key = known.factKey or ns.PlayerKey(f.name, f.realm) or f.guid
        f.fullAt = known.fullAt
    else
        f.name, f.realm = S.CallMulti(2, UnitName, unit)
        if f.realm == "" then f.realm = nil end
        f.className, f.classFile = S.CallMulti(2, UnitClass, unit)
        f.race, f.raceFile = S.CallMulti(2, UnitRace, unit)
        if GetGuildInfo then f.guild = S.CallMulti(1, GetGuildInfo, unit) end
        -- Honor rank: UnitPVPRank is 0 for none, 5+ for Private and up;
        -- GetPVPRankInfo turns it into the rank name and 1-14.
        local rank = UnitPVPRank and S.Call(UnitPVPRank, unit)
        if type(rank) == "number" and rank > 0 and GetPVPRankInfo then
            local rankName, rankNumber = S.CallMulti(2, GetPVPRankInfo, rank, unit)
            if type(rankName) == "string" and type(rankNumber) == "number" and rankNumber > 0 then
                f.rankName, f.rankNumber = rankName, rankNumber
            end
        end
        f.key = ns.PlayerKey(f.name, f.realm) or f.guid
        f.fullAt = GetTime()
    end
    local level = S.Call(UnitLevel, unit)
    if level and level < 0 then
        f.skull = true
    elseif level and level > 0 then
        f.level = level
    end
    if UnitIsPVP then f.flagged = S.Call(UnitIsPVP, unit) end
    f.dead = S.Call(UnitIsDeadOrGhost, unit) == true
    return f
end

function ns.ReadPlayerFacts(unit, known)
    if not ns.TickReads() then return ReadFacts(unit, known) end
    local c = factsCache[unit]
    if not c then
        c = { ReadFacts(unit, known) }
        factsCache[unit] = c
    end
    return c[1], c[2]
end

-- Reads a unit as an enemy player. Returns facts, or nil and a reason (those
-- of ReadPlayerFacts, or "friendly"). "friendly" also returns the player's
-- key (when readable) so a listed entry that turns out to be an ally can be
-- dropped. facts.hostile is true for an enemy, nil when the game hides it.
local function ReadUnit(unit, known)
    local f, reason = ns.ReadPlayerFacts(unit, known)
    if not f then return nil, reason end
    local enemy, enemySecret = S.Call(UnitIsEnemy, "player", unit)
    if enemySecret then
        f.hostile = nil
    elseif enemy then
        f.hostile = true
    else
        return nil, "friendly", f.key
    end
    if ns.IsAlly(unit, f.hostile) then return nil, "friendly", f.key end
    return f
end

function ns.ReadPlayerUnit(unit, known)
    if not ns.TickReads() then return ReadUnit(unit, known) end
    local c = unitCache[unit]
    if not c then
        c = { ReadUnit(unit, known) }
        unitCache[unit] = c
    end
    return c[1], c[2], c[3]
end

---------------------------------------------------------------------------
-- Live unit state (panel details): health, power, target, cast, auras
---------------------------------------------------------------------------
-- Read fresh every refresh and never kept on the entry: a value from a plate
-- that is gone would be stale. Readable values are plain fields; a secret
-- comes back only as <field>Raw, for widget setters (see S.CallRaw).

local POWER_COLORS = {
    MANA = {0.00, 0.55, 1.00}, RAGE = {1.00, 0.00, 0.00}, FOCUS = {1.00, 0.50, 0.25}, ENERGY = {1.00, 1.00, 0.00},
}
local POWER_TOKENS = { [0] = "MANA", [1] = "RAGE", [2] = "FOCUS", [3] = "ENERGY" }

function ns.PowerColor(token)
    local c = token and PowerBarColor and PowerBarColor[token]
    if type(c) == "table" and c.r then return { c.r, c.g, c.b } end
    return POWER_COLORS[token or ""] or POWER_COLORS.MANA
end

-- Fills v (reused) with: hp, hpMax, power, powerMax, powerToken (readable)
-- and hpRaw, hpMaxRaw, powerRaw, powerMaxRaw (secret); inCombat and
-- targetingYou are true / false / nil (nil = hidden); targetName; casting is
-- the spell name, "?" when a cast is hidden, nil when none.
function ns.ReadVitals(unit, v)
    v = v or {}
    v.hp, v.hpRaw = S.CallRaw(UnitHealth, unit)
    v.hpMax, v.hpMaxRaw = S.CallRaw(UnitHealthMax, unit)
    if v.hpMax and v.hpMax <= 0 then v.hpMax = nil end
    local powerType, token = S.CallMulti(2, UnitPowerType, unit)
    if type(token) ~= "string" then token = POWER_TOKENS[powerType or -1] end
    v.powerToken = token
    v.power, v.powerRaw = S.CallRaw(UnitPower, unit)
    v.powerMax, v.powerMaxRaw = S.CallRaw(UnitPowerMax, unit)
    if v.powerMax and v.powerMax <= 0 then v.powerMax = nil end

    local inCombat, combatSecret = S.Call(UnitAffectingCombat, unit)
    if combatSecret then v.inCombat = nil else v.inCombat = inCombat == true end

    local targetUnit = unit .. "target"
    local hasTarget, targetSecret = S.Call(UnitExists, targetUnit)
    v.targetName = nil
    if targetSecret then
        v.targetingYou = nil
    elseif not hasTarget then
        v.targetingYou = false
    else
        local isYou, youSecret = S.Call(UnitIsUnit, targetUnit, "player")
        if youSecret then v.targetingYou = nil else v.targetingYou = isYou == true end
        v.targetName = S.CallMulti(1, UnitName, targetUnit)
    end

    local cast, castSecret = S.Call(UnitCastingInfo, unit)
    if not cast and not castSecret then cast, castSecret = S.Call(UnitChannelInfo, unit) end
    v.casting = (type(cast) == "string" and cast) or (castSecret and "?") or nil
    return v
end

-- Auras worth spotting at a glance, by spell ID (all vanilla ranks): an
-- enemy's big defensive / offensive cooldowns ("buff") and crowd control
-- ("cc"). Anything else is shown, just not highlighted.
local NOTABLE = {
    buff = {
        642, 1020, 498, 5573, 1022, 5599, 10278, 1044,          -- Divine Shield, Divine Protection, BoP, Freedom
        11958, 11426, 13031, 13032, 13033, 12042, 12043, 11129, -- Ice Block, Ice Barrier, Arcane Power, PoM, Combustion
        5277, 1856, 1857, 11327, 11329, 2983, 8696, 11305,      -- Evasion, Vanish (spells and their buffs), Sprint
        14177, 13750, 13877, 19263,                             -- Cold Blood, AR, Blade Flurry, Deterrence
        871, 12975, 1719, 12292, 18499, 12328,                  -- Shield Wall, Last Stand, Recklessness, Death Wish, Berserker Rage, Sweeping Strikes
        22812, 1850, 9821, 29166, 17116,                        -- Barkskin, Dash, Innervate, Nature's Swiftness
        16188, 16166, 10060, 14751, 6346,                       -- NS (shaman), Elemental Mastery, Power Infusion, Inner Focus, Fear Ward
        3045, 19574, 7744, 20600, 20594, 6615, 24364,           -- Rapid Fire, Bestial Wrath, WotF, Perception, Stoneform, Free Action, Living Action
    },
    cc = {
        118, 12824, 12825, 12826, 28270, 28271, 28272,          -- Polymorph
        6770, 2070, 11297, 2094, 1776, 1777, 8629, 11285, 11286, -- Sap, Blind, Gouge
        408, 8643, 1833, 853, 5588, 5589, 10308, 20066,         -- Kidney Shot, Cheap Shot, Hammer of Justice, Repentance
        5782, 6213, 6215, 5484, 17928, 6789, 17925, 17926, 6358, -- Fear, Howl of Terror, Death Coil, Seduction
        8122, 8124, 10888, 10890, 15487, 605, 10911, 10912,     -- Psychic Scream, Silence, Mind Control
        5246, 7922, 20253, 20614, 20615, 12809, 18469, 18425,   -- Intimidating Shout, Charge/Intercept stun, Concussion Blow, silences
        122, 865, 6131, 10230, 339, 1062, 5195, 5196, 9852, 9853, -- Frost Nova, Entangling Roots
        2637, 18657, 18658, 5211, 6798, 8983,                   -- Hibernate, Bash
        19503, 19386, 24132, 24133, 3355, 14308, 14309, 20549,  -- Scatter Shot, Wyvern Sting, Freezing Trap, War Stomp
    },
}
ns.NOTABLE_AURAS = {}
for kind, ids in pairs(NOTABLE) do
    for _, id in ipairs(ids) do ns.NOTABLE_AURAS[id] = kind end
end

local function AuraAt(unit, index, filter)
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, unit, index, filter)
        if not ok then return nil, true end
        if type(a) == "nil" then return nil, false end
        if type(a) ~= "table" or not S.IsReadable(a) then return nil, true end
        return a, false
    end
    local fn = (filter == "HELPFUL" and UnitBuff) or (filter == "HARMFUL" and UnitDebuff) or nil
    if not fn then return nil, false end
    local ok, name, icon, count, dispel, duration, expires, _, _, _, spellId = pcall(fn, unit, index)
    if not ok then return nil, true end
    if type(name) == "nil" then return nil, false end
    return { name = name, icon = icon, applications = count, dispelName = dispel, duration = duration,
        expirationTime = expires, spellId = spellId }, false
end

-- Fills out (a reused array of reused tables) with up to max auras of the
-- filter ("HELPFUL" / "HARMFUL"): name, icon / iconRaw, count, duration,
-- expires, spellId, dispel, notable. Returns how many (read out[1..n] only;
-- later slots are stale), and how many the game
-- hid entirely — the panel shows those as "?", never as "no auras".
function ns.ReadAuras(unit, filter, max, out)
    local n, hidden = 0, 0
    for index = 1, 40 do
        if n >= max then break end
        local a, isHidden = AuraAt(unit, index, filter)
        if isHidden then
            hidden = hidden + 1
        elseif not a then
            break
        else
            local icon, iconRaw = S.Value(a.icon), nil
            if icon == nil and type(a.icon) ~= "nil" then iconRaw = a.icon end
            if icon == nil and iconRaw == nil then
                hidden = hidden + 1
            else
                n = n + 1
                local r = out[n] or {}
                out[n] = r
                r.name, r.icon, r.iconRaw = S.Value(a.name), icon, iconRaw
                r.count, r.duration, r.expires = S.Value(a.applications), S.Value(a.duration), S.Value(a.expirationTime)
                r.spellId, r.dispel = S.Value(a.spellId), S.Value(a.dispelName)
                r.notable = r.spellId and ns.NOTABLE_AURAS[r.spellId] or nil
            end
        end
    end
    return n, hidden
end

-- "Name" on your own realm, "Name-Realm" otherwise; nil when hidden.
function ns.PlayerKey(name, realm)
    if type(name) ~= "string" or name == "" then return nil end
    if realm and realm ~= "" then
        local mine = GetRealmName and S.Call(GetRealmName)
        if realm ~= mine then return name .. "-" .. realm end
    end
    return name
end

-- The saved player record (KoS/avoid list, notes, history), or nil.
function ns.PlayerRecord(key, create)
    if not key or not ns.DB() then return nil end
    local players = ns.DB().players
    local rec = players[key]
    if not rec and create then
        rec = { seen = 0, kills = 0, deaths = 0 }
        players[key] = rec
    end
    return rec
end

function ns.ListOf(key)
    local rec = ns.PlayerRecord(key)
    return rec and rec.list or nil
end

-- Higher = more dangerous. Skull, level gap, your lists and class choices,
-- and closeness. Unknown level counts like an equal-level enemy: never as
-- harmless.
function ns.ThreatScore(f, lo, hi)
    local score = 0
    local mine = S.Call(UnitLevel, "player")
    if f.skull then
        score = score + 45
    elseif f.level and mine then
        score = score + math.max(-30, math.min(30, (f.level - mine) * 3))
    end
    local list = ns.ListOf(f.key)
    if list == "kos" then score = score + 60 elseif list == "avoid" then score = score + 30 end
    if f.classFile and ns.DB().alertLoudClasses[f.classFile] then score = score + 20 end
    if f.hostile == nil then score = score + 5 end
    if hi then score = score + math.max(0, (45 - hi) / 3) elseif lo then score = score + math.max(0, (40 - lo) / 4) end
    return score
end

-- True when this enemy deserves the loud alert.
function ns.IsLoud(f)
    local db = ns.DB()
    if db.alertLoudKoS and ns.ListOf(f.key) == "kos" then return true end
    if f.classFile and db.alertLoudClasses[f.classFile] then return true end
    if f.skull then return true end
    local mine = S.Call(UnitLevel, "player")
    if f.level and mine and f.level - mine >= (db.alertLoudAbove or 3) then return true end
    return false
end
