-- TALOD - Cleanup: rules that keep the saved data small, and the memory cap.
--
-- The game reads the whole saved file into memory at login and writes it
-- back at logout: nothing stays on disk while you play, so every entry kept
-- costs memory and loading time (a 14 MB file is about 35 MB of Lua
-- memory). Rules remove what is old and no longer read. Each rule belongs to
-- the module whose records it touches (Cleanup.Add at file load): only that
-- module knows what its records mean.
--
-- Automatic cleanup (cleanAuto) is on for a first install and off after an
-- update (Store.Load decides once): nobody loses data they did not agree to
-- delete. It runs each enabled rule once a day, CLEAN_DELAY seconds after
-- login, one rule per tick and never in combat.
--
-- Memory: the game's figure for this addon. UpdateAddOnMemoryUsage walks
-- every loaded addon, so it is read rarely: MEMORY_FIRST seconds after login,
-- then every MEMORY_EVERY, out of combat, or on demand. Over the cap
-- (memoryCapMB): one warning per session, and the enabled rules run then if
-- cleanup is automatic. Nothing beyond the rules is ever deleted for the cap.
-- The figure includes garbage not collected yet, so it drops some time after
-- a cleanup, not at once.
--
-- Archive (Archive.lua, setting cleanArchive): rules that can keep what they
-- remove (rule.archive) move it to the archive addon instead, but only into
-- a loaded archive. Loading it reads its whole file and keeps it in memory
-- until /reload, so the automatic run loads it only once ARCHIVE_BATCH
-- entries are waiting; until then those rules wait (nothing is deleted).
-- A click (Clean up now, Move now) loads it at once.

local ADDON_NAME, ns = ...
local S = ns.Secret

local Cleanup = {}
ns.Cleanup = Cleanup

local DAY = 86400
local CLEAN_DELAY = 30          -- seconds after login before the daily run
local CLEAN_EVERY = 20 * 3600   -- "once a day" without drifting later each day
local MEMORY_FIRST = 60
local MEMORY_EVERY = 15 * 60
local MAX_LOG = 100
local ARCHIVE_BATCH = 2000      -- entries waiting before the automatic run loads the archive

local function db() return ns.DB() end
local function InCombat() return InCombatLockdown and InCombatLockdown() end

---------------------------------------------------------------------------
-- Rules
---------------------------------------------------------------------------
-- { id, label, desc, source (Data source told after a run), days (default),
-- min, max, step, archive (true: run hands what it removes to `keep`),
-- run = fn(cutoff, apply, keep) -> entries that are (apply) or would be
-- (not apply) removed }. cutoff: time(); older goes. keep(key, value), when
-- given, receives each removed entry (value: a string or number).
local rules = {}
Cleanup.rules = rules

local function OnKey(rule) return "clean" .. rule.id:sub(1, 1):upper() .. rule.id:sub(2) end
local function DaysKey(rule) return OnKey(rule) .. "Days" end
Cleanup.OnKey, Cleanup.DaysKey = OnKey, DaysKey

function Cleanup.Add(rule)
    rules[#rules + 1] = rule
    rules[rule.id] = rule
    ns.defaults[OnKey(rule)] = true
    ns.defaults[DaysKey(rule)] = rule.days
end

local function Days(rule) return tonumber(db()[DaysKey(rule)]) or rule.days end
local function Cutoff(rule) return time() - Days(rule) * DAY end
function Cleanup.Enabled(rule) return db()[OnKey(rule)] and true or false end

-- What a rule would remove now (kept a minute, or until its data changes).
function Cleanup.Preview(rule)
    local key = Days(rule) .. "|" .. ns.Data.Key({ rule.source })
    return ns.Data.Memo("clean:" .. rule.id, key, function()
        local n, t0 = 0, ns.Data.Clock()
        ns.SafeCall(function() n = rule.run(Cutoff(rule), false) or 0 end)
        local t1 = ns.Data.Clock()
        if t0 and t1 then ns.Data.Time("cleanup", rule.id .. " (count)", t1 - t0) end
        return n
    end, 60)
end

function Cleanup.PreviewTotal()
    local n = 0
    for _, rule in ipairs(rules) do
        if Cleanup.Enabled(rule) then n = n + Cleanup.Preview(rule) end
    end
    return n
end

local function Log(rule, n, auto, archived)
    local log = ns.Store.CleanLog()
    log[#log + 1] = { t = time(), id = rule.id, n = n, auto = auto or nil, archived = archived or nil, c = ns.Store.Me() }
    while #log > MAX_LOG do table.remove(log, 1) end
end

-- Old entries go to the archive (not deleted) for rules that can keep them.
function Cleanup.Archiving() return db().cleanArchive and ns.Archive.Usable() or false end
local function Archived(rule) return rule.archive and Cleanup.Archiving() end

local function RunRule(rule, auto)
    local keep
    if Archived(rule) then
        keep = function(key, value) ns.Archive.Put(rule.id, key, value) end
    end
    local n, t0 = 0, ns.Data.Clock()
    ns.SafeCall(function() n = rule.run(Cutoff(rule), true, keep) or 0 end)
    local t1 = ns.Data.Clock()
    if t0 and t1 then ns.Data.Time("cleanup", rule.id, t1 - t0) end
    if n > 0 then
        Log(rule, n, auto, keep ~= nil)
        if rule.source then ns.Data.Changed(rule.source) end
        if keep then ns.Data.Changed("archive") end
        ns.Data.Forget("clean:")
    end
    return n
end

-- Entries that wait for the archive: rules that would move them while it is not loaded.
function Cleanup.Waiting()
    if not Cleanup.Archiving() or ns.Archive.Loaded() then return 0 end
    local n = 0
    for _, rule in ipairs(rules) do
        if rule.archive and Cleanup.Enabled(rule) then n = n + Cleanup.Preview(rule) end
    end
    return n
end

local pending          -- { rules left, auto, removed } of a run in progress
local function Finish()
    local run = pending
    pending = nil
    db().cleanLast = time()
    if run.removed > 0 then
        ns.Print("cleanup " .. (run.archived and "moved or removed " or "removed ") .. run.removed .. " old entr"
            .. (run.removed == 1 and "y" or "ies") .. " (" .. ns.Cmd.Text("clean") .. " for the rules).")
    end
    if run.held > 0 then
        ns.Print(run.held .. " old entries wait for the archive (moved when " .. ARCHIVE_BATCH .. " wait, or Settings, Data, "
            .. "Archive: Move now).")
    end
    ns.Refresh()
end

-- Runs the enabled rules: now (a click, a command), or one per tick (the
-- automatic run, so a large data set never stalls a frame for long).
-- Rules that move to the archive run only into a loaded one: a click loads
-- it, the automatic run once a batch is waiting; otherwise they wait.
function Cleanup.Run(auto)
    if pending then return false end
    local held = 0
    if Cleanup.Archiving() and not ns.Archive.Loaded() then
        local waiting = Cleanup.Waiting()
        if waiting > 0 and (not auto or waiting >= ARCHIVE_BATCH) then
            local ok, why = ns.Archive.Load()
            if not ok then ns.Print("the archive could not be loaded (" .. tostring(why) .. "): its rules wait.") end
        end
        if not ns.Archive.Loaded() then held = Cleanup.Waiting() end
    end
    local list = {}
    for _, rule in ipairs(rules) do
        if Cleanup.Enabled(rule) and not (Archived(rule) and not ns.Archive.Loaded()) then list[#list + 1] = rule end
    end
    pending = { list = list, auto = auto, removed = 0, held = held, archived = Cleanup.Archiving() and ns.Archive.Loaded() }
    if auto then return true end
    for _, rule in ipairs(list) do pending.removed = pending.removed + RunRule(rule, false) end
    local removed = pending.removed
    Finish()
    return true, removed
end

function Cleanup.Running() return pending ~= nil end

---------------------------------------------------------------------------
-- Memory
---------------------------------------------------------------------------
local memory = { mb = nil, at = nil }      -- last reading (nil: none yet / not readable)
local warned = false
local capRun = false

-- MB used by this addon, read from the game now. nil when the game does not say.
function Cleanup.Measure()
    if type(UpdateAddOnMemoryUsage) ~= "function" or type(GetAddOnMemoryUsage) ~= "function" then return nil end
    local t0 = ns.Data.Clock()
    S.Call(UpdateAddOnMemoryUsage)
    local kb = S.Call(GetAddOnMemoryUsage, ADDON_NAME)
    local t1 = ns.Data.Clock()
    if t0 and t1 then ns.Data.Time("cleanup", "memory read (every addon)", t1 - t0) end
    if type(kb) ~= "number" then return nil end
    memory.mb, memory.at = kb / 1024, time()
    return memory.mb
end

function Cleanup.Memory() return memory.mb, memory.at end
function Cleanup.Cap() return tonumber(db().memoryCapMB) or 150 end
function Cleanup.OverCap() return memory.mb ~= nil and memory.mb > Cleanup.Cap() end

local function CheckCap()
    if not Cleanup.OverCap() then return end
    if db().memoryWarn and not warned then
        warned = true
        ns.Print(string.format("saved data uses %d MB of memory, over your cap of %d MB. Settings, Data: cleanup rules "
            .. "and the largest stores (%s).", math.floor(memory.mb + 0.5), Cleanup.Cap(), ns.Cmd.Text("memory")))
    end
    if db().cleanAuto and not capRun and not pending then
        capRun = true
        Cleanup.Run(true)
    end
end

-- Each store's share of the saved data, largest first: { { def, weight,
-- share } }. A walk over every table: on demand only. The weights are a
-- rough model of Lua 5.1 memory (a table, a field, a string's bytes), good
-- for comparing stores, not for adding up to the game's figure.
local function Weigh(v, seen)
    local w = 0
    local stack, n = { v }, 1
    while n > 0 do
        local x = stack[n]
        stack[n] = nil
        n = n - 1
        local tx = type(x)
        if tx == "table" then
            if not seen[x] then
                seen[x] = true
                w = w + 64
                for k, y in pairs(x) do
                    w = w + 40
                    if type(k) == "string" then w = w + #k end
                    if type(y) == "table" then n = n + 1 stack[n] = y
                    elseif type(y) == "string" then w = w + 24 + #y end
                end
            end
        elseif tx == "string" then
            w = w + 24 + #x
        end
    end
    return w
end

function Cleanup.Weights()
    local out, total, seen = {}, 0, {}
    for _, def in ipairs(ns.Store.DEFS) do
        local data = db()[def.key]
        if type(data) == "table" then
            local w = Weigh(data, seen)
            out[#out + 1] = { def = def, weight = w }
            total = total + w
        end
    end
    table.sort(out, function(a, b) return a.weight > b.weight end)
    for _, row in ipairs(out) do row.share = total > 0 and row.weight / total or 0 end
    return out
end

---------------------------------------------------------------------------
-- Text
---------------------------------------------------------------------------
local function Ago(t)
    if not t then return "never" end
    local d = time() - t
    if d < 3600 then return math.max(1, math.floor(d / 60)) .. " min ago" end
    if d < DAY then return math.floor(d / 3600) .. " h ago" end
    return math.floor(d / DAY) .. " days ago"
end

function Cleanup.MemoryText()
    local mb = memory.mb
    if not mb then return "Memory: not read yet (the game reads it out of combat; " .. ns.Cmd.Text("memory") .. " reads it now)." end
    local over = mb > Cleanup.Cap()
    return string.format("%sMemory: %d MB of your %d MB cap|r  (read %s)", over and ns.ColorCode("danger") or "|cffffffff",
        math.floor(mb + 0.5), Cleanup.Cap(), Ago(memory.at))
end

function Cleanup.WeightsText(limit)
    local lines = {}
    for i, row in ipairs(Cleanup.Weights()) do
        if i > (limit or 8) or row.share < 0.005 then break end
        lines[#lines + 1] = string.format("  %3d%%  %s", math.floor(row.share * 100 + 0.5), row.def.label)
    end
    return table.concat(lines, "\n")
end

function Cleanup.LastText()
    local log = ns.Store.CleanLog()
    local last = db().cleanLast
    if not last then return "Never cleaned up." end
    local n = 0
    for i = #log, 1, -1 do
        if (log[i].t or 0) < last - 60 then break end
        n = n + (log[i].n or 0)
    end
    return "Last cleanup " .. Ago(last) .. ": " .. n .. " entr" .. (n == 1 and "y" or "ies") .. " removed."
end

function Cleanup.PreviewText()
    local lines = {}
    for _, rule in ipairs(rules) do
        lines[#lines + 1] = string.format("  %s%s: %d older than %d days", Cleanup.Enabled(rule) and "" or "(off) ",
            rule.label, Cleanup.Preview(rule), Days(rule))
    end
    return table.concat(lines, "\n")
end

---------------------------------------------------------------------------
-- Settings: the Data tab
---------------------------------------------------------------------------
local function CleanupPage(parent)
    local W = ns.Options.Widgets
    local y = -12
    y = W.Paragraph(parent, y, "The game loads all of " .. ns.NAME .. "'s saved data into memory when you log in and writes it "
        .. "back when you log out, so everything kept costs memory and loading time. These rules remove old entries "
        .. "that nothing reads any more. Removed entries are gone for good.", "GameFontHighlightSmall")
    y = W.Header(parent, y, "Automatic cleanup")
    y = W.Checkbox(parent, y, "cleanAuto", "Clean up automatically",
        "Runs the rules below once a day, 30 seconds after login, out of combat. On for a new install; after an update "
        .. "it stays off until you turn it on, so nothing you had is deleted without your say.")
    y = W.LiveText(parent, y, 18, Cleanup.LastText)
    local rowY = y
    W.Button(parent, rowY, "Clean up now", 140, function()
        local n = Cleanup.PreviewTotal()
        if n == 0 then ns.Print("nothing to clean up with the rules that are on.") return end
        StaticPopup_Show(ns.POPUP .. "CLEAN", Cleanup.ConfirmText(n))
    end, "Runs the rules that are on, once, now.")
    y = y - 34
    for _, rule in ipairs(rules) do
        y = W.Header(parent, y, rule.label, rule.desc)
        y = W.Checkbox(parent, y, OnKey(rule), "Use this rule")
        y = W.Slider(parent, y, DaysKey(rule), "Older than", rule.min, rule.max, rule.step, "%d days")
        y = W.LiveText(parent, y, 18, function()
            local n = Cleanup.Preview(rule)
            return (n > 0 and "|cffffffff" or "|cff9d9d9d") .. n .. " entr" .. (n == 1 and "y" or "ies") .. " would go now.|r"
        end)
    end
    y = W.Header(parent, y, "Capped elsewhere")
    y = W.Paragraph(parent, y, "These logs drop their oldest entries on their own: census points (Census tab), fishing "
        .. "casts, the economy log, the journal, guild roster log, skills and gear ledgers.", "GameFontHighlightSmall")
    return -y + 10
end

local function MemoryPage(parent)
    local W = ns.Options.Widgets
    local y = -12
    y = W.Paragraph(parent, y, "How much memory " .. ns.NAME .. " uses, as the game reports it. Reading it costs a little, "
        .. "so it is read a minute after login and every 15 minutes out of combat.", "GameFontHighlightSmall")
    y = W.Header(parent, y, "Cap")
    y = W.Slider(parent, y, "memoryCapMB", "Memory cap", 50, 1000, 25, "%d MB",
        "Above this, " .. ns.NAME .. " warns once per session and, if automatic cleanup is on, runs the cleanup rules. "
        .. "It never deletes anything the rules would not.")
    y = W.Checkbox(parent, y, "memoryWarn", "Warn in chat when over the cap")
    y = W.LiveText(parent, y, 18, Cleanup.MemoryText)
    local rowY = y
    local weights = ""
    W.Button(parent, rowY, "Read now", 120, function()
        Cleanup.Measure()
        weights = Cleanup.WeightsText(8)
        ns.Refresh()
    end, "Reads the memory figure and works out which stores take the most (a short pause with a lot of data).")
    y = y - 34
    y = W.Header(parent, y, "Largest stores")
    y = W.LiveText(parent, y, 130, function()
        return weights ~= "" and weights or "|cff9d9d9dRead now to see them.|r"
    end)
    return -y + 10
end

local function ArchiveCountsText()
    if not ns.Archive.Loaded() then return "|cff9d9d9dLoad the archive to see what it holds.|r" end
    local lines = {}
    for _, rule in ipairs(rules) do
        if rule.archive then lines[#lines + 1] = string.format("  %s: %d", rule.label, ns.Archive.Count(rule.id)) end
    end
    return table.concat(lines, "\n")
end

local function ArchivePage(parent)
    local W = ns.Options.Widgets
    local y = -12
    y = W.Paragraph(parent, y, "The archive is a second addon, " .. ns.ARCHIVE_ADDON .. ", that comes with " .. ns.NAME
        .. ". The game reads its saved file only when it is loaded, so what is in it costs no memory and no loading "
        .. "time until you open it. Once loaded it stays in memory until you /reload.", "GameFontHighlightSmall")
    y = W.Header(parent, y, "Archive")
    y = W.LiveText(parent, y, 18, ns.Archive.StateText)
    y = W.Checkbox(parent, y, "cleanArchive", "Move old entries to the archive instead of deleting them",
        "For the rules that can (recruit messages, price history and items, the guild event log). The automatic "
        .. "cleanup moves them once " .. ARCHIVE_BATCH .. " are waiting, so the archive is not loaded every day; "
        .. "until then they stay where they are. Without the archive addon, the rules delete.")
    y = W.LiveText(parent, y, 18, function()
        local n = Cleanup.Waiting()
        return n > 0 and ("|cffffffff" .. n .. " entr" .. (n == 1 and "y waits" or "ies wait") .. " for the archive.|r")
            or "|cff9d9d9dNothing waits for the archive.|r"
    end)
    local rowY = y
    W.Button(parent, rowY, "Load archive", 130, function()
        local ok, why = ns.Archive.Load()
        if not ok then ns.Print("the archive could not be loaded: " .. tostring(why) .. ".") end
        ns.Refresh()
    end, "Reads the archive into memory until you /reload. Price graphs then include archived prices.")
    W.Button(parent, rowY, "Move now", 130, function()
        local n = Cleanup.Waiting()
        if n == 0 then ns.Print("nothing waits for the archive.") return end
        StaticPopup_Show(ns.POPUP .. "CLEAN", Cleanup.ConfirmText(n))
    end, "Loads the archive and runs the cleanup rules that are on.", 160)
    y = y - 34
    y = W.Header(parent, y, "In the archive")
    y = W.LiveText(parent, y, 90, ArchiveCountsText)
    return -y + 10
end

ns.Options.AddTab({ label = "Data", pages = {
    { label = "Cleanup", build = CleanupPage },
    { label = "Memory", build = MemoryPage },
    { label = "Archive", build = ArchivePage },
} })

function Cleanup.ConfirmText(n)
    if Cleanup.Archiving() then
        return "Clean up " .. n .. " old " .. ns.NAME .. " entries now? Those the archive can keep are moved there "
            .. "(it stays loaded until /reload); the rest are deleted."
    end
    return "Remove " .. n .. " old " .. ns.NAME .. " entries now? This cannot be undone."
end

StaticPopupDialogs[ns.POPUP .. "CLEAN"] = {
    text = "%s",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function()
        local _, n = Cleanup.Run(false)
        if n == 0 then ns.Print("nothing was old enough to remove.") end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

---------------------------------------------------------------------------
-- Set-aside entries (Store's quarantine): a rule of the save-file handler.
---------------------------------------------------------------------------
Cleanup.Add({ id = "setAside", label = "Set-aside entries",
    desc = "Saved entries that could not be read at login and were put aside instead of breaking a window.",
    days = 30, min = 10, max = 180, step = 10,
    run = function(cutoff, apply)
        local q = ns.Store.Quarantined()
        local n, j = 0, 0
        for i = 1, #q do
            local e = q[i]
            if (e.t or 0) < cutoff then
                n = n + 1
            elseif apply then
                j = j + 1
                q[j] = e
            end
        end
        if apply then for i = #q, j + 1, -1 do q[i] = nil end end
        return n
    end })

---------------------------------------------------------------------------
-- Slash and tick
---------------------------------------------------------------------------
local function Slash(command, rest)
    if command == "archive" then
        local arg = ((rest or ""):match("^(%S*)") or ""):lower()
        if arg == "load" then
            local ok, why = ns.Archive.Load()
            ns.Print(ok and ns.Archive.StateText() or ("the archive could not be loaded: " .. tostring(why) .. "."))
        elseif arg == "move" then
            if not Cleanup.Archiving() then ns.Print("moving to the archive is off, or the archive is not installed.") return true end
            local _, n = Cleanup.Run(false)
            if n == 0 then ns.Print("nothing was old enough to move.") end
        else
            ns.Print(ns.Archive.StateText() .. ". " .. Cleanup.Waiting() .. " entries wait for it.")
        end
        ns.Refresh()
        return true
    end
    if command == "memory" then
        local mb = Cleanup.Measure()
        ns.Print(mb and Cleanup.MemoryText() or "the game does not report addon memory here.")
        ns.Print("largest stores:\n" .. Cleanup.WeightsText(8))
        return true
    end
    if command ~= "clean" then return false end
    local arg, val = (rest or ""):lower():match("^(%S*)%s*(%S*)")
    if arg == "now" then
        if pending then ns.Print("a cleanup is already running.") return true end
        local _, n = Cleanup.Run(false)
        if n == 0 then ns.Print("nothing was old enough to remove.") end
    elseif arg == "auto" and (val == "on" or val == "off") then
        db().cleanAuto = val == "on"
        ns.Print("automatic cleanup " .. val .. ".")
        ns.Refresh()
    else
        ns.Print("cleanup rules (automatic: " .. (db().cleanAuto and "on" or "off") .. "). " .. Cleanup.LastText()
            .. "\n" .. Cleanup.PreviewText())
    end
    return true
end

local loginAt, autoChecked, nextMemory

function Cleanup.Tick()
    local now = GetTime()
    loginAt = loginAt or now
    nextMemory = nextMemory or (loginAt + MEMORY_FIRST)
    if InCombat() then return end
    if pending and pending.auto then
        local rule = table.remove(pending.list, 1)
        if rule then pending.removed = pending.removed + RunRule(rule, true) else Finish() end
        return
    end
    if not autoChecked and now - loginAt >= CLEAN_DELAY then
        autoChecked = true
        if db().cleanAuto and time() - (tonumber(db().cleanLast) or 0) >= CLEAN_EVERY then Cleanup.Run(true) end
    end
    if now >= nextMemory then
        nextMemory = now + MEMORY_EVERY
        Cleanup.Measure()
        CheckCap()
    end
end

ns.RegisterModule("Cleanup", {
    defaults = { memoryCapMB = 150, memoryWarn = true, cleanArchive = true },
    tick = Cleanup.Tick,
    slash = Slash,
})
