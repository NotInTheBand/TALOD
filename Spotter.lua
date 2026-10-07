-- TALOD - Spotter: turns what the game shows (enemy nameplates, your
-- target, your mouseover) into a list of nearby enemy players.
--
-- There is no combat log on WoW Forever and enemy positions cannot be read, so
-- an enemy is "nearby" while its nameplate is up (nameplate distance, ~41 yd at
-- most) and is remembered for panelFadeSeconds after that. Each live entry
-- gets a distance bracket from the range checks every tick.

local ADDON_NAME, ns = ...
local S = ns.Secret
local C = ns.C

local Spotter = {}
ns.Spotter = Spotter

local nearby = {}        -- [key] = entry
local plateKeys = {}     -- [nameplate token] = key
local sorted = {}        -- reused by Spotter.Sorted
local listeners = { spotted = {}, vanished = {}, removed = {} }

Spotter.nearby = nearby

-- fn(entry, source, isNew) / fn(entry) / fn(entry)
function Spotter.On(kind, fn) listeners[kind][#listeners[kind] + 1] = fn end

local function Emit(kind, ...)
    for _, fn in ipairs(listeners[kind]) do ns.SafeCall(fn, ...) end
end

local STEALTH_CLASSES = { ROGUE = true, DRUID = true }

-- The nameplate token of a unit ("target", "mouseover"), when it has one.
local function PlateToken(unit)
    if unit:find("^nameplate") then return unit end
    if not C_NamePlate or not C_NamePlate.GetNamePlateForUnit then return nil end
    local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
    if not ok or type(plate) ~= "table" then return nil end
    local token = S.Value(rawget(plate, "namePlateUnitToken"))
    if type(token) == "string" then return token end
    return nil
end

local function CopyFacts(entry, f)
    entry.name, entry.realm = f.name or entry.name, f.realm or entry.realm
    entry.className, entry.classFile = f.className or entry.className, f.classFile or entry.classFile
    entry.race, entry.raceFile = f.race or entry.race, f.raceFile or entry.raceFile
    entry.guild = f.guild or entry.guild
    -- What ns.ReadPlayerFacts needs to skip the fixed facts next tick.
    entry.factKey, entry.fullAt = f.key, f.fullAt
    if f.skull then entry.skull, entry.level = true, nil
    elseif f.level then entry.skull, entry.level = nil, f.level end
    if f.flagged ~= nil then entry.flagged = f.flagged end
    if f.rankName then entry.rankName, entry.rankNumber = f.rankName, f.rankNumber end
    entry.hostile = f.hostile
    entry.dead = f.dead
    entry.guid = f.guid or entry.guid
end

local function Probe(entry, unit)
    local lo, hi, ok = ns.ProbeUnitRange(unit)
    entry.lo, entry.hi, entry.rangeOK = lo, hi, ok
    if ok then entry.rangeAt = GetTime() end
end

-- Drops an entry that turned out to be an ally (listed earlier while its
-- hostility was hidden).
local function Forget(key)
    local entry = nearby[key]
    if not entry then return end
    nearby[key] = nil
    for token, k in pairs(plateKeys) do
        if k == key then plateKeys[token] = nil end
    end
    Emit("removed", entry)
end

-- Reads a unit; adds or refreshes its entry. Returns the entry.
function Spotter.Observe(unit, source)
    if not ns.DB().enabled then return nil end
    local f, reason, allyKey = ns.ReadPlayerUnit(unit)
    if reason == "friendly" then
        Forget(allyKey or ("?" .. (PlateToken(unit) or unit)))
        return nil
    end
    if not f then return nil end
    -- A player whose name and GUID are both hidden cannot be told apart from
    -- the next one; it is listed by its nameplate token while visible.
    local key = f.key or ("?" .. unit)
    local token = PlateToken(unit)
    local now = GetTime()
    local entry = nearby[key]
    local isNew = entry == nil or (entry.unit == nil and now - (entry.lastSeen or 0) > (ns.DB().panelFadeSeconds or 60))
    if not entry then
        entry = { key = key, firstSeen = now, keyed = f.key ~= nil }
        nearby[key] = entry
    end
    CopyFacts(entry, f)
    entry.lastSeen = now
    entry.vanished = nil
    entry.source = entry.source or source
    if token then
        if entry.unit and entry.unit ~= token and plateKeys[entry.unit] == key then plateKeys[entry.unit] = nil end
        entry.unit = token
        plateKeys[token] = key
    end
    if token or unit == "target" then Probe(entry, token or unit) end
    entry.score = ns.ThreatScore(entry, entry.lo, entry.hi)
    if isNew then entry.firstSeen = now end
    Emit("spotted", entry, source, isNew)
    return entry
end

local function OnPlateRemoved(token, quiet)
    local key = plateKeys[token]
    plateKeys[token] = nil
    local entry = key and nearby[key]
    if not entry or entry.unit ~= token then return end
    entry.unit = nil
    -- A rogue or druid whose nameplate disappears close by, alive, most likely
    -- stealthed (or vanished). Heuristic: logging out or a loading screen look
    -- the same, so it is opt-in and worded as "probably".
    local db = ns.DB()
    if not quiet and db.vanishAlert and STEALTH_CLASSES[entry.classFile or ""] and not entry.dead and entry.hostile
        and entry.hi and entry.hi <= (db.vanishMaxRange or 30) and GetTime() - (entry.rangeAt or 0) < 1.5 then
        entry.vanished = GetTime()
        Emit("vanished", entry)
    end
end

-- Refreshes live entries: facts, distance, score. Drops faded entries.
function Spotter.Tick()
    local now = GetTime()
    local probed = 0
    local allies
    for token, key in pairs(plateKeys) do
        local entry = nearby[key]
        local f, reason, allyKey
        if entry then f, reason, allyKey = ns.ReadPlayerUnit(token, entry) end
        if reason == "friendly" and (allyKey == key or (allyKey == nil and key == "?" .. token)) then
            allies = allies or {}
            allies[#allies + 1] = key
        elseif not f or (f.key and f.key ~= key) then
            -- The token now belongs to someone else (or no one).
            plateKeys[token] = nil
            if entry and entry.unit == token then entry.unit = nil end
        else
            CopyFacts(entry, f)
            entry.lastSeen = now
            if probed < C.MAX_RANGE_UNITS then
                Probe(entry, token)
                probed = probed + 1
            end
        end
    end
    if allies then
        for _, key in ipairs(allies) do Forget(key) end
    end
    -- An enemy target without a nameplate (off screen, plates off) still has
    -- a distance.
    local tf = ns.ReadPlayerUnit("target")
    if tf and tf.key and nearby[tf.key] and not nearby[tf.key].unit then
        local entry = nearby[tf.key]
        CopyFacts(entry, tf)
        entry.lastSeen = now
        Probe(entry, "target")
    end
    local fade = ns.DB().panelFadeSeconds or 60
    for key, entry in pairs(nearby) do
        if not entry.unit and now - (entry.lastSeen or 0) > fade then
            nearby[key] = nil
            Emit("removed", entry)
        else
            entry.score = ns.ThreatScore(entry, entry.unit and entry.lo, entry.unit and entry.hi)
        end
    end
end

local function ByThreat(a, b)
    local la, lb = a.unit ~= nil, b.unit ~= nil
    if la ~= lb then return la end
    if la then
        if (a.score or 0) ~= (b.score or 0) then return (a.score or 0) > (b.score or 0) end
        return (a.lo or a.hi or 99) < (b.lo or b.hi or 99)
    end
    return (a.lastSeen or 0) > (b.lastSeen or 0)
end

-- Live entries by threat, then remembered ones by recency. Reused table.
function Spotter.Sorted()
    for i = #sorted, 1, -1 do sorted[i] = nil end
    for _, entry in pairs(nearby) do sorted[#sorted + 1] = entry end
    table.sort(sorted, ByThreat)
    return sorted
end

function Spotter.Count()
    local live, total = 0, 0
    for _, entry in pairs(nearby) do
        total = total + 1
        if entry.unit then live = live + 1 end
    end
    return live, total
end

function Spotter.Get(key) return key and nearby[key] end

function Spotter.Clear()
    for key in pairs(nearby) do nearby[key] = nil end
    for token in pairs(plateKeys) do plateKeys[token] = nil end
end

-- Picks up nameplates that were already visible at login or /reload.
function Spotter.ScanPlates()
    for i = 1, 40 do
        local token = "nameplate" .. i
        if S.Call(UnitExists, token) then Spotter.Observe(token, "nameplate") end
    end
end

function Spotter.OnEvent(event, unit)
    if event == "NAME_PLATE_UNIT_ADDED" then
        if unit then Spotter.Observe(unit, "nameplate") end
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        if unit then OnPlateRemoved(unit) end
    elseif event == "PLAYER_TARGET_CHANGED" then
        Spotter.Observe("target", "target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        Spotter.Observe("mouseover", "mouseover")
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Nameplate tokens do not survive a loading screen.
        for token in pairs(plateKeys) do OnPlateRemoved(token, true) end
        Spotter.ScanPlates()
    end
end

Spotter.EVENTS = { "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "PLAYER_TARGET_CHANGED",
    "UPDATE_MOUSEOVER_UNIT", "PLAYER_ENTERING_WORLD" }
