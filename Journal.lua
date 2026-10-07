-- TALOD - Journal: every enemy player you have seen (who, where, when),
-- your kill-on-sight and avoid lists, notes, and how encounters ended when the
-- game lets us tell.
--
-- Without a combat log, outcomes are limited to what is visible: you died
-- while an enemy player was (recently) your target, or your enemy target died.
-- Rows say exactly that; they never claim who landed the killing blow.

local ADDON_NAME, ns = ...
local S = ns.Secret

local Journal = {}
ns.Journal = Journal

local recentRow = {}       -- [key] = row, this session: merges repeat sightings
local lastEnemyTarget      -- { key, t } the last enemy player you targeted
local targetAlive = {}     -- [key] = true while your enemy target is alive
local OUTCOME_WINDOW = 20  -- seconds after untargeting that a death still counts

local function db() return ns.DB() end

-- A player's counts for one character (pc[character number] = { s seen, k
-- kills, d deaths }); the record's seen / kills / deaths are the account's.
local function Mine(rec)
    local id = ns.Store.Me()
    if not id then return nil end
    rec.pc = rec.pc or {}
    local c = rec.pc[id]
    if not c then
        c = { s = 0, k = 0, d = 0 }
        rec.pc[id] = c
    end
    return c
end

local function Zone()
    local zone = GetZoneText and S.Call(GetZoneText) or nil
    local sub = GetSubZoneText and S.Call(GetSubZoneText) or nil
    local mapID = C_Map and C_Map.GetBestMapForUnit and S.Call(C_Map.GetBestMapForUnit, "player") or nil
    if sub == "" then sub = nil end
    return zone, sub, mapID
end

-- Adds a sighting, or extends the player's last row when it is recent.
function Journal.Record(e, source)
    if not db().journalEnabled or not e.keyed or e.hostile ~= true then return end
    local now = time()
    local rec = ns.PlayerRecord(e.key, true)
    rec.name, rec.realm = e.name or rec.name, e.realm or rec.realm
    rec.class, rec.race = e.classFile or rec.class, e.race or rec.race
    rec.guild = e.guild or rec.guild
    if e.skull then rec.level = -1 elseif e.level then rec.level = e.level end
    rec.firstSeen = rec.firstSeen or now
    rec.lastSeen = now

    local zone, sub, mapID = Zone()
    local row = recentRow[e.key]
    if row and now - (row.t2 or row.t) < (db().journalMergeMinutes or 10) * 60 and row.zone == zone then
        row.t2 = now
        row.level = rec.level
        row.guild = e.guild or row.guild
        if e.flagged then row.flagged = true end
        return row
    end
    row = { key = e.key, t = now, t2 = now, name = e.name, realm = e.realm, class = e.classFile, race = e.race,
        level = rec.level, guild = e.guild, zone = zone, subzone = sub, mapID = mapID, source = source,
        flagged = e.flagged or nil, c = ns.Store.Me() }
    local journal = db().journal
    journal[#journal + 1] = row
    while #journal > (db().journalMax or 5000) do table.remove(journal, 1) end
    recentRow[e.key] = row
    rec.seen = (rec.seen or 0) + 1
    local mine = Mine(rec)
    if mine then mine.s = mine.s + 1 end
    return row
end

-- Marks the player's latest row: "you died" or "they died".
function Journal.SetOutcome(key, outcome)
    local rec = ns.PlayerRecord(key)
    if not rec then return end
    local row = recentRow[key]
    if not row then
        local journal = db().journal
        for i = #journal, 1, -1 do
            if journal[i].key == key then row = journal[i] break end
        end
    end
    if row then row.outcome = outcome end
    local mine = Mine(rec)
    if outcome == "you died" then
        rec.deaths = (rec.deaths or 0) + 1
        if mine then mine.d = mine.d + 1 end
    else
        rec.kills = (rec.kills or 0) + 1
        if mine then mine.k = mine.k + 1 end
    end
end

---------------------------------------------------------------------------
-- Lists and notes
---------------------------------------------------------------------------
-- Resolves "target" or a typed name to a player key and display name.
function Journal.ResolveName(text)
    text = text and text:match("^%s*(.-)%s*$") or ""
    if text == "" or text:lower() == "target" then
        local f = ns.ReadPlayerUnit("target")
        if f and f.key then return f.key, f end
        -- Friendly players can go on a list too (a ganker in your own faction
        -- on a PvP realm is rare, but notes are useful).
        local name, realm = S.CallMulti(2, UnitName, "target")
        if name and S.Call(UnitIsPlayer, "target") then return ns.PlayerKey(name, realm), nil end
        return nil
    end
    -- Typed names: capitalized like the game does ("sHADOW" -> "Shadow"); a
    -- realm after "-" is left as typed. Non-ASCII letters pass unchanged.
    local name, realm = text:match("^([^-]+)%-?(.*)$")
    name = name:sub(1, 1):upper() .. name:sub(2):lower()
    return (realm ~= "" and (name .. "-" .. realm) or name), nil
end

function Journal.SetList(key, list, facts)
    local rec = ns.PlayerRecord(key, true)
    rec.list = list
    rec.listBy = ns.Store.Me()
    if facts then
        rec.name, rec.class, rec.level, rec.guild = facts.name or rec.name, facts.classFile or rec.class,
            facts.skull and -1 or facts.level or rec.level, facts.guild or rec.guild
    end
    rec.name = rec.name or key
end

function Journal.SetNote(key, note)
    local rec = ns.PlayerRecord(key, true)
    rec.name = rec.name or key
    rec.note = (note and note ~= "") and note or nil
    rec.noteBy = rec.note and ns.Store.Me() or nil
end

function Journal.ListMembers(list)
    local out = {}
    for key, rec in pairs(db().players) do
        if rec.list == list then out[#out + 1] = key end
    end
    table.sort(out)
    return out
end

---------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------
-- Distinct enemies seen in a zone within `seconds`; returns count and the
-- most recent row.
function Journal.ZoneSummary(zone, seconds)
    local since = time() - (seconds or 86400)
    local seen, count, latest = {}, 0, nil
    local journal = db().journal
    for i = #journal, 1, -1 do
        local row = journal[i]
        if (row.t2 or row.t) < since then break end
        if row.zone == zone and not seen[row.key] then
            seen[row.key] = true
            count = count + 1
            latest = latest or row
        end
    end
    return count, latest
end

function Journal.Stats()
    local players, kos, avoid = 0, 0, 0
    for _, rec in pairs(db().players) do
        players = players + 1
        if rec.list == "kos" then kos = kos + 1 elseif rec.list == "avoid" then avoid = avoid + 1 end
    end
    return #db().journal, players, kos, avoid
end

-- The n most recent rows, newest first.
function Journal.Recent(n)
    local out, journal = {}, db().journal
    for i = #journal, math.max(1, #journal - n + 1), -1 do out[#out + 1] = journal[i] end
    return out
end

-- Sightings per zone (most first): { zone, count }.
function Journal.ByZone()
    local counts = {}
    for _, row in ipairs(db().journal) do
        local zone = row.zone or "?"
        counts[zone] = (counts[zone] or 0) + 1
    end
    local out = {}
    for zone, n in pairs(counts) do out[#out + 1] = { zone = zone, count = n } end
    table.sort(out, function(a, b) return a.count > b.count end)
    return out
end

-- Deletes rows older than `days` (all rows when nil). Player records keep
-- their lists and notes; records with neither and no remaining rows go.
function Journal.Delete(days)
    local journal = db().journal
    local removed = 0
    if days then
        local cutoff = time() - days * 86400
        local kept = {}
        for _, row in ipairs(journal) do
            if (row.t2 or row.t) >= cutoff then kept[#kept + 1] = row else removed = removed + 1 end
        end
        wipe(journal)
        for i, row in ipairs(kept) do journal[i] = row end
    else
        removed = #journal
        wipe(journal)
    end
    wipe(recentRow)
    local present = {}
    for _, row in ipairs(journal) do present[row.key] = true end
    for key, rec in pairs(db().players) do
        if not present[key] and not rec.list and not rec.note then db().players[key] = nil end
    end
    return removed
end

function Journal.Describe(key)
    local rec = ns.PlayerRecord(key)
    if not rec then return key .. ": never seen, not on a list." end
    local level = rec.level == -1 and "??" or tostring(rec.level or "?")
    local parts = { string.format("%s: %s %s", key, level, ns.ClassName(rec.class)) }
    if rec.guild then parts[#parts + 1] = "<" .. rec.guild .. ">" end
    if rec.list then parts[#parts + 1] = "[" .. (rec.list == "kos" and "KoS" or "avoid") .. "]" end
    parts[#parts + 1] = string.format("seen %d×", rec.seen or 0)
    if rec.lastSeen then parts[#parts + 1] = "last " .. ns.FormatAge(time() - rec.lastSeen) .. " ago" end
    if (rec.kills or 0) + (rec.deaths or 0) > 0 then
        parts[#parts + 1] = string.format("they died %d× / you died %d×", rec.kills or 0, rec.deaths or 0)
    end
    if rec.note then parts[#parts + 1] = '"' .. rec.note .. '"' end
    return table.concat(parts, " ")
end

---------------------------------------------------------------------------
-- Outcomes
---------------------------------------------------------------------------
local function CheckTargetDeath()
    local f = ns.ReadPlayerUnit("target")
    if not f or not f.key or f.hostile ~= true then return end
    -- Still targeted: the outcome window keeps running from now.
    if lastEnemyTarget and lastEnemyTarget.key == f.key then
        lastEnemyTarget.t = GetTime()
    else
        lastEnemyTarget = { key = f.key, t = GetTime() }
    end
    if f.dead then
        if targetAlive[f.key] then
            targetAlive[f.key] = nil
            Journal.SetOutcome(f.key, "they died")
        end
    else
        targetAlive[f.key] = true
    end
end

-- Your target dying is noticed by the tick (every 0.25 s): UNIT_HEALTH
-- arrives for every unit in sight, hundreds a second in a battleground.
local function OnEvent(event)
    if event == "PLAYER_TARGET_CHANGED" then
        wipe(targetAlive)
        local f = ns.ReadPlayerUnit("target")
        if f and f.key and f.hostile == true then
            lastEnemyTarget = { key = f.key, t = GetTime() }
            if not f.dead then targetAlive[f.key] = true end
        elseif lastEnemyTarget then
            lastEnemyTarget.t = GetTime()   -- the window starts when you untarget
        end
    elseif event == "PLAYER_DEAD" then
        if lastEnemyTarget and GetTime() - lastEnemyTarget.t <= OUTCOME_WINDOW then
            Journal.SetOutcome(lastEnemyTarget.key, "you died")
            lastEnemyTarget = nil
        end
    end
end

ns.RegisterModule("Journal", {
    events = { "PLAYER_TARGET_CHANGED", "PLAYER_DEAD" },
    onEvent = OnEvent,
    tick = CheckTargetDeath,
    init = function()
        ns.Spotter.On("spotted", function(e, source, isNew)
            if isNew or recentRow[e.key] then Journal.Record(e, source) end
        end)
    end,
})
