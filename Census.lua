-- TALOD - Census: a detailed log of every player you see, both factions,
-- for heat maps of where players of a class, level or faction travel.
--
-- Other players' positions cannot be read. A sample records where *you* were
-- when you saw them, plus the distance bracket: nameplates only show within
-- ~41 yd, so the point is accurate to that on a zone map. Group members' own
-- map positions are readable outside instances and are logged as they are.
--
-- Two stores in TALODDB.census:
--   points  recent samples, one string each (compact in SavedVariables),
--           capped at censusMaxPoints, oldest dropped first.
--   cells   permanent counts per map grid square by faction, relation,
--           class, level band and time of day, counted once per player per
--           square per visit. Heat maps keep working after points roll over.
-- tools/census_viewer.py turns the SavedVariables file into an HTML page.
--
-- Point fields, comma separated (guild last: the viewer splits at most 17 times):
--   time, mapID, x, y (0-1000, empty when unknown), faction (A/H/?),
--   relation (E enemy, F friendly, ? hidden), class, level (-1 skull, empty
--   unknown), race, lo, hi (yd bracket, empty unknown), source (n plate,
--   t target, m mouseover, g group: x/y are their own), your level,
--   flags (c in combat, d dead, p PvP flagged, y you in combat, f you
--   flagged), enemies in view, allies in view, key, guild, then (added
--   later; older points stop at guild) "#" and the number of the character
--   that saw it (Store.lua): the "#" tells it from a guild name with a comma.
--   cells are the account's: they do not say which character counted.

local ADDON_NAME, ns = ...
local S = ns.Secret

local Census = {}
ns.Census = Census

local FORMAT_VERSION = 1
local SCAN_INTERVAL = 1        -- seconds between scans of plates and group
local GRID = 50                -- cells per map side (2% of the map each)
local VISIT_SECONDS = 600      -- a player counts again in the same cell after this
local CAPITALS = { [1453] = true, [1454] = true, [1455] = true, [1456] = true, [1457] = true, [1458] = true }
local FACTIONS = { Alliance = "A", Horde = "H" }

local lastScan = 0
local lastSample = {}          -- [key] = time of the last point for that player
local lastCell = {}            -- [key] = { cell, t } for visit counting
local scanned = {}             -- reused: keys seen in the current pass
local pending = {}             -- reused: samples of the current step
local pass = { units = {}, sources = {}, i = 0 }   -- the running pass; done when i == #units
local inView = {}              -- [token] = relation at its latest read (players in view per point)
local PASS_READS = 12          -- unit reads per tick
local lastPrune = 0
local PRUNE_EVERY = 60
local FORGET_AFTER = 900       -- seconds unseen before a player's throttle is dropped

local function db() return ns.DB() end

local function Store()
    local c = db().census
    if type(c) ~= "table" then
        c = {}
        db().census = c
    end
    c.version = c.version or FORMAT_VERSION
    c.points = c.points or {}
    c.cells = c.cells or {}
    c.maps = c.maps or {}
    c.labels = c.labels or {}
    return c
end
Census.Store = Store

-- mapID, x, y (0-1) for a unit; x/y nil when the game does not give them
-- (instances, or hidden).
local function MapPosition(unit)
    if not C_Map then return nil end
    local mapID = S.Call(C_Map.GetBestMapForUnit, unit)
    if type(mapID) ~= "number" then return nil end
    local ok, pos = pcall(C_Map.GetPlayerMapPosition or function() end, mapID, unit)
    pos = ok and S.Value(pos) or nil
    if type(pos) ~= "table" or type(pos.GetXY) ~= "function" then return mapID end
    local x, y = S.CallMulti(2, pos.GetXY, pos)
    if type(x) ~= "number" or type(y) ~= "number" or (x <= 0 and y <= 0) or x > 1 or y > 1 then return mapID end
    return mapID, x, y
end
Census.MapPosition = MapPosition

local function RememberMap(c, mapID)
    if c.maps[mapID] or not (C_Map and C_Map.GetMapInfo) then return end
    local ok, info = pcall(C_Map.GetMapInfo, mapID)
    info = ok and S.Value(info) or nil
    local name = type(info) == "table" and S.Value(info.name) or nil
    c.maps[mapID] = type(name) == "string" and name or tostring(mapID)
end

-- Subzone names at the average of your positions there, so the viewer can
-- label a map that has no background image.
local function RememberLabel(c, mapID, x, y)
    local sub = GetSubZoneText and S.Call(GetSubZoneText)
    if type(sub) ~= "string" or sub == "" then return end
    local labels = c.labels[mapID] or {}
    c.labels[mapID] = labels
    local l = labels[sub]
    if not l then
        labels[sub] = { x, y, 1 }
    elseif l[3] < 500 then
        l[1], l[2], l[3] = l[1] + x, l[2] + y, l[3] + 1
    end
end

local function Relation(unit)
    local enemy, secret = S.Call(UnitIsEnemy, "player", unit)
    if not secret and enemy == true then
        return ns.IsAlly(unit, true) and "F" or "E"
    elseif not secret then
        return "F"
    end
    return ns.IsAlly(unit, nil) and "F" or "?"
end

local function LevelBand(level)
    if level == -1 then return "s" end
    if not level then return "?" end
    return tostring(math.floor((level - 1) / 10) * 10 + 1)   -- 1, 11, 21, ...
end

local function Num(v) return type(v) == "number" and tostring(v) or "" end

local function CountCell(c, s, now)
    local cell
    if s.x then
        cell = math.min(GRID - 1, math.floor(s.x * GRID)) .. ":" .. math.min(GRID - 1, math.floor(s.y * GRID))
    else
        cell = "-"
    end
    local visitKey = s.key or s.token
    local last = lastCell[visitKey]
    if last and last[1] == s.mapID .. "/" .. cell and now - last[2] < VISIT_SECONDS then return end
    lastCell[visitKey] = { s.mapID .. "/" .. cell, now }
    local hour = tonumber(date("%H", now)) or 0
    local key = table.concat({ cell, s.faction, s.relation, s.class or "?", LevelBand(s.level), math.floor(hour / 4) }, ":")
    local cells = c.cells[s.mapID] or {}
    c.cells[s.mapID] = cells
    cells[key] = (cells[key] or 0) + 1
end

local function Trim(points, max)
    if #points <= max + math.max(10, math.floor(max / 10)) then return end
    local drop = #points - max
    for i = 1, max do points[i] = points[i + drop] end
    for i = #points, max + 1, -1 do points[i] = nil end
end

-- Reads one unit into the pass's pending samples. Returns true when added.
local function Collect(unit, source)
    local f = ns.ReadPlayerFacts(unit)
    if not f then return false end
    local id = f.key or ("?" .. unit)
    if scanned[id] then return false end
    scanned[id] = true
    local relation = Relation(unit)
    if relation == "F" and not db().censusAllies and source ~= "g" then return false end
    local s = { key = f.key, token = id, relation = relation, source = source, f = f, unit = unit }
    s.faction = FACTIONS[S.CallMulti(1, UnitFactionGroup, unit) or ""] or "?"
    s.class, s.level = f.classFile, f.skull and -1 or f.level
    if source == "g" then s.mapID, s.x, s.y = MapPosition(unit) end
    s.combat = S.Call(UnitAffectingCombat, unit) == true
    pending[#pending + 1] = s
    return true
end

-- Writes the pending samples as points and summary counts.
local function Write(d, now)
    if #pending == 0 then return 0 end
    local c = Store()
    local myMap, myX, myY = MapPosition("player")
    local myLevel = S.Call(UnitLevel, "player")
    local myFlags = (ns.InCombat() and "y" or "") .. (S.Call(UnitIsPVP, "player") == true and "f" or "")
    -- Players in view: the latest read of every token (this pass or the last).
    local enemies, allies = 0, 0
    for _, relation in pairs(inView) do
        if relation == "E" then enemies = enemies + 1 elseif relation == "F" then allies = allies + 1 end
    end
    if myMap then
        RememberMap(c, myMap)
        if myX then RememberLabel(c, myMap, myX, myY) end
    end

    local written = 0
    for _, s in ipairs(pending) do
        if s.source ~= "g" then s.mapID, s.x, s.y = myMap, myX, myY end
        local interval = s.relation == "F" and d.censusAllySeconds or d.censusEnemySeconds
        local id = s.token
        if s.mapID and now - (lastSample[id] or -math.huge) >= (interval or 5) then
            lastSample[id] = now
            if s.source ~= "g" then s.lo, s.hi = ns.ProbeUnitRange(s.unit) end
            RememberMap(c, s.mapID)
            CountCell(c, s, now)
            -- Your own faction in a capital is only counted, not tracked:
            -- it would fill the log in minutes.
            local capitalAlly = d.censusSkipCapitals and CAPITALS[s.mapID] and s.relation == "F"
            if not capitalAlly then
                local f = s.f
                local flags = (s.combat and "c" or "") .. (f.dead and "d" or "") .. (f.flagged == true and "p" or "") .. myFlags
                c.points[#c.points + 1] = table.concat({
                    now, s.mapID, s.x and math.floor(s.x * 1000 + 0.5) or "", s.y and math.floor(s.y * 1000 + 0.5) or "",
                    s.faction, s.relation, s.class or "", Num(s.level), f.raceFile or "", Num(s.lo), Num(s.hi),
                    s.source, Num(myLevel), flags, enemies, allies, s.key or "", f.guild or "", ns.Store.Me() and ("#" .. ns.Store.Me()) or nil,
                }, ",")
                written = written + 1
            end
        end
    end
    Trim(c.points, d.censusMaxPoints or 30000)
    return written
end

-- Drops the per-player throttles of players not seen for a while (they
-- would otherwise grow all session in a city).
local function Prune(now)
    if now - lastPrune < PRUNE_EVERY then return end
    lastPrune = now
    for id, t in pairs(lastSample) do
        if now - t > FORGET_AFTER then lastSample[id] = nil end
    end
    for id, v in pairs(lastCell) do
        if now - v[2] > VISIT_SECONDS then lastCell[id] = nil end
    end
end

-- A pass: group first (a party member with a nameplate is logged at their
-- own position, not yours), then nameplates, target and mouseover.
local function StartPass(d, now)
    Prune(now)
    for k in pairs(scanned) do scanned[k] = nil end
    for i = #pass.units, 1, -1 do pass.units[i], pass.sources[i] = nil, nil end
    local function Add(unit, source)
        pass.units[#pass.units + 1], pass.sources[#pass.sources + 1] = unit, source
    end
    if d.censusGroup then
        local raid = IsInRaid and S.Call(IsInRaid)
        local prefix, count = raid and "raid" or "party", raid and 40 or 4
        for i = 1, count do Add(prefix .. i, "g") end
    end
    for i = 1, 40 do Add("nameplate" .. i, "n") end
    Add("target", "t")
    Add("mouseover", "m")
    pass.i = 0
end

-- Reads up to `budget` units that exist (all when nil) and writes their
-- samples. Returns points written and true when the pass is done.
local function StepPass(d, now, budget)
    for i = #pending, 1, -1 do pending[i] = nil end
    local reads = 0
    while pass.i < #pass.units and not (budget and reads >= budget) do
        pass.i = pass.i + 1
        local unit, source = pass.units[pass.i], pass.sources[pass.i]
        local added = false
        if S.Call(UnitExists, unit) then
            reads = reads + 1
            added = Collect(unit, source)
        end
        if source ~= "g" then inView[unit] = added and pending[#pending].relation or nil end
    end
    return Write(d, now), pass.i >= #pass.units
end

-- One whole pass at once (tests, commands).
function Census.Scan(now)
    local d = db()
    if not d.enabled or not d.censusEnabled then return 0 end
    StartPass(d, now)
    return (StepPass(d, now, nil))
end

-- A pass starts once a second and reads at most PASS_READS units per tick:
-- 80 players (raid and nameplates) read in one frame was a hitch every second.
function Census.Tick()
    local d = db()
    if not d.enabled or not d.censusEnabled then
        pass.i = #pass.units
        wipe(inView)
        return
    end
    local now = time()
    if pass.i >= #pass.units then
        if now - lastScan < SCAN_INTERVAL then return end
        lastScan = now
        StartPass(d, now)
    end
    StepPass(d, now, PASS_READS)
end

function Census.Stats()
    local c = Store()
    local maps, cells = 0, 0
    for _, mapCells in pairs(c.cells) do
        maps = maps + 1
        for _ in pairs(mapCells) do cells = cells + 1 end
    end
    return #c.points, cells, maps
end

-- what: "points" (recent samples only) or "all".
function Census.Delete(what)
    local c = Store()
    c.points = {}
    if what == "all" then c.cells, c.maps, c.labels = {}, {}, {} end
    for k in pairs(lastSample) do lastSample[k] = nil end
    for k in pairs(lastCell) do lastCell[k] = nil end
end

function Census.ShowFriendlyPlates()
    if InCombatLockdown and InCombatLockdown() then
        ns.Print("nameplate settings cannot change in combat.")
        return
    end
    if ns.SetCVarValue("nameplateShowFriends", 1) then
        ns.Print("friendly nameplates on: allies are logged as soon as their plates show.")
    else
        ns.Print("the game did not accept it. Turn on Friendly Player Nameplates under Options > Nameplates.")
    end
end

local function FriendlyPlatesOn() return (ns.GetCVarNumber("nameplateShowFriends") or 0) > 0 end
Census.FriendlyPlatesOn = FriendlyPlatesOn

local function StatusLine()
    local points, cells, maps = Census.Stats()
    return string.format("census %s: %d recent points (max %d), %d summary cells on %d maps. Allies %s, friendly nameplates %s.",
        db().censusEnabled and "on" or "off", points, db().censusMaxPoints or 0, cells, maps,
        db().censusAllies and "logged" or "not logged", FriendlyPlatesOn() and "on" or "off")
end
Census.StatusLine = StatusLine

local function Slash(command, rest)
    if command ~= "census" then return false end
    local arg = (rest or ""):lower()
    if arg == "on" or arg == "off" then
        db().censusEnabled = arg == "on"
        ns.Print("census " .. arg .. ".")
    elseif arg == "allies on" or arg == "allies off" then
        db().censusAllies = arg == "allies on"
        ns.Print("allies " .. (db().censusAllies and "logged." or "not logged."))
    elseif arg == "friendly" then
        Census.ShowFriendlyPlates()
    elseif arg == "clear" then
        StaticPopup_Show(ns.POPUP .. "CENSUS_DELETE", "all census data", nil, "all")
    else
        ns.Print(StatusLine())
    end
    ns.Refresh()
    return true
end

StaticPopupDialogs[ns.POPUP .. "CENSUS_DELETE"] = {
    text = "Delete " .. ns.NAME .. " %s?",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function(self, what)
        Census.Delete(what)
        ns.Print(what == "all" and "census data deleted." or "recent census points deleted (summary kept).")
        ns.Refresh()
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

---------------------------------------------------------------------------
-- Settings tab
---------------------------------------------------------------------------
local function BuildPage(parent)
    local W = ns.Options.Widgets
    local y = -12
    y = W.Paragraph(parent, y, "Logs every player you see, enemies and allies, with where you were, the distance, "
        .. "their class, race, level and guild, and the time. Their own position is never read: a point is where you "
        .. "stood, within nameplate range (~41 yd). Run |cffffffffpython tools/census_viewer.py|r in the addon folder "
        .. "to turn the log into heat maps.", "GameFontHighlightSmall")
    y = W.Header(parent, y, "Recording")
    y = W.Checkbox(parent, y, "censusEnabled", "Log players I see",
        "Enemies every few seconds while in view, allies less often.")
    y = W.Checkbox(parent, y, "censusAllies", "Include my own faction",
        "Allies are only seen through their nameplates (turn friendly nameplates on below), your target and your mouseover.")
    y = W.Checkbox(parent, y, "censusGroup", "Include my party / raid at their own position",
        "The game reports group members' map positions outside instances.")
    y = W.Checkbox(parent, y, "censusSkipCapitals", "Only count allies in capital cities",
        "Allies in Stormwind, Orgrimmar and the other capitals are counted in the summary but get no track points.")
    y = W.Slider(parent, y, "censusEnemySeconds", "Enemy: one point every", 1, 30, 1, "%d s")
    y = W.Slider(parent, y, "censusAllySeconds", "Ally: one point every", 5, 120, 5, "%d s")
    y = W.Slider(parent, y, "censusMaxPoints", "Keep at most", 5000, 100000, 5000, "%d points",
        "Recent points are kept for detail; the summary is kept forever. 30 000 points is about 2-3 MB of saved data.")
    y = y - 4
    y = W.Header(parent, y, "Friendly nameplates")
    local rowY = y
    W.Button(parent, rowY, "Turn on friendly nameplates", 200, function() Census.ShowFriendlyPlates() ns.Refresh() end,
        "Sets the game's Friendly Player Nameplates option. Out of combat only.")
    y = y - 30
    y = W.LiveText(parent, y, 18, function()
        return FriendlyPlatesOn() and "Friendly nameplates are on." or "|cffffd100Friendly nameplates are off: allies are only logged when you target or mouse over them.|r"
    end)
    y = W.Header(parent, y, "Data")
    y = W.LiveText(parent, y, 30, StatusLine)
    rowY = y
    W.Button(parent, rowY, "Delete recent points", 170, function()
        StaticPopup_Show(ns.POPUP .. "CENSUS_DELETE", "recent census points (the summary is kept)", nil, "points")
    end)
    W.Button(parent, rowY, "Delete all census data", 170, function()
        StaticPopup_Show(ns.POPUP .. "CENSUS_DELETE", "all census data", nil, "all")
    end, nil, 200)
    y = y - 34
    return -y + 10
end

ns.Options.AddTab({ label = "Census", pages = { { label = "Census", build = BuildPage } } })

ns.RegisterModule("Census", {
    defaults = {
        censusEnabled = true,
        censusAllies = true,
        censusGroup = true,
        censusSkipCapitals = true,
        censusEnemySeconds = 5,
        censusAllySeconds = 30,
        censusMaxPoints = 30000,
        census = {},
    },
    tick = Census.Tick,
    slash = Slash,
})
