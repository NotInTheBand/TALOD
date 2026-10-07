-- TALOD - Data: how the addon's logs reach the windows. Every kind of
-- data (economy, prices, guild, fishing, gear, skills, crafts) is a source
-- with a version; the module that writes it calls Data.Changed(name), the
-- windows that show it watch it (Data.Window), and their lists are built
-- through Data.List: kept until a source or the view's filters change, rows
-- formatted only when they scroll into view, redraws from game events at
-- most once a second. Walking a 5000-entry log on every loot is what made
-- the big windows lag. Big builds also run in the background (below), so
-- the first open after login and the open after a full scan do not stall.

local ADDON_NAME, ns = ...
local Style = ns.Style
local HEX = Style.HEX

local Data = {}
ns.Data = Data

---------------------------------------------------------------------------
-- Background work
---------------------------------------------------------------------------
-- A build over a few thousand items (a desk plan per ladder after a full
-- scan, every price in the Market) is a visible hitch when a window does it
-- in the frame it opens. Jobs run in a coroutine a few milliseconds per
-- frame instead, never in combat:
--  * warm-up: a while after login, each window's opts.prebuild (its frames)
--    and opts.warm (the memos its first tab reads) from Data.Window;
--  * revalidation: a memo whose last build was slow, asked for by an open
--    window after its key changed or its maxAge passed, gives the window
--    the value it had and is rebuilt here; the window redraws when it is.
-- Builds pause at Data.Step (Data.Memo and Data.List's add call it). It must
-- never be reached through pcall: Lua 5.1 cannot yield across one.
local BUDGET_MS = 4     -- per frame
local SLOW_MS = 8       -- a build this slow is rebuilt in the background
local WARM_DELAY = 5    -- seconds after login before the warm-up

-- Milliseconds, or nil without debugprofilestop (the test mock): every
-- build then counts as fast and jobs run to the end in one frame.
local function Clock() return debugprofilestop and debugprofilestop() or nil end

local jobs, queued = {}, {}   -- waiting jobs in order; name -> job
local current                 -- the job being run (it may span frames)
local thread, sliceEnd        -- its coroutine while resumed; when its slice ends
local startAt = math.huge     -- set at login
local drawing                 -- a Data.Window window is redrawing: true, or "ready" (redraw after rebuilds)
local drawingSources          -- that window's sources
local windows = {}            -- Data.Window windows' redraws for rebuilt data
local landed = {}             -- memo names rebuilt since the last "ready" redraw
local driver

-- Where a build may pause: when it runs as a job and its slice is used up.
function Data.Step()
    if thread and sliceEnd and coroutine.running() == thread then
        local t = Clock()
        if t and t >= sliceEnd then coroutine.yield() end
    end
end

local function Versions(names)
    local parts = {}
    for i, name in ipairs(names) do parts[i] = tostring(Data.Version(name)) end
    return table.concat(parts, ",")
end

-- job = { name, run, sources (dropped when one changes after the request:
-- its key is out of date, and a walk it paused may meet new keys), again
-- (start over instead: the warm-up; a revalidation is asked for again by the
-- next redraw), done (after a finished run) }.
local function Queue(job)
    job.versions = Versions(job.sources or {})
    local old = queued[job.name]
    if old then
        -- Not started yet: the newest request replaces it (a newer key).
        if old ~= current then for k, v in pairs(job) do old[k] = v end end
        return
    end
    queued[job.name] = job
    jobs[#jobs + 1] = job
    if driver then driver:Show() end
end

local function Finish(job)
    current, queued[job.name] = nil, nil
    job.thread = nil
end

-- Once the queue is empty, open windows redraw with what was rebuilt.
local function Landed()
    if not next(landed) then return end
    for _, redraw in ipairs(windows) do ns.SafeCall(redraw) end
    wipe(landed)
end

local function RunSlice()
    drawing = nil
    if GetTime() < startAt or (InCombatLockdown and InCombatLockdown()) then return end
    local t0 = Clock()
    sliceEnd = t0 and (t0 + BUDGET_MS)
    while true do
        local job = current
        if not job then
            job = table.remove(jobs, 1)
            if not job then
                driver:Hide()
                Landed()
                return
            end
            current = job
            if job.again then job.versions = Versions(job.sources or {}) end
            job.thread = coroutine.create(job.run)
        end
        if Versions(job.sources or {}) ~= job.versions then
            -- Its data changed since it was asked for, or while it was
            -- paused: a table it was walking may have new keys, and `next`
            -- cannot go on over those.
            Finish(job)
            if job.again then Queue(job) end
            job = nil
        end
        if job then
            thread = job.thread
            local ok, err = coroutine.resume(thread)
            thread = nil
            if not ok then
                Finish(job)
                ns.SafeCall(error, "background " .. job.name .. ": " .. tostring(err), 0)
            elseif coroutine.status(job.thread) == "dead" then
                Finish(job)
                if job.done then ns.SafeCall(job.done) end
            end
        end
        local t = Clock()
        if not t or t >= sliceEnd then return end
    end
end

driver = CreateFrame("Frame")
driver:Hide()
driver:SetScript("OnUpdate", RunSlice)

-- Runs fn() as a background job (replacing one of that name not started
-- yet), dropped when one of `sources` changes before it is done. For a
-- module's own long walk: put Data.Step() in its loops.
function Data.Background(name, fn, sources)
    Queue({ name = name, run = fn, sources = sources })
end

-- True while background work is waiting or running.
function Data.Busy() return current ~= nil or #jobs > 0 end

---------------------------------------------------------------------------
-- Memo and coalesced calls
---------------------------------------------------------------------------
-- Derived data (totals, merged histories, sorted rows) kept until `key`
-- changes, or `maxAge` seconds pass when given (for what the key cannot see,
-- like "days ago" moving on). Callers must not change the result.
local memo, serial = {}, 0

local function Make(name, key, build)
    serial = serial + 1
    local mine, t0 = serial, Clock()
    local value = build()
    local t1 = Clock()
    local c = memo[name]
    -- A window built the same thing while this job was paused: keep that
    -- one, callers may already hold it.
    if c and c.key == key and c.serial > mine then return c.value end
    memo[name] = { key = key, at = GetTime(), value = value, serial = mine,
        slow = t0 ~= nil and t1 ~= nil and t1 - t0 >= SLOW_MS }
    return value
end

function Data.Memo(name, key, build, maxAge)
    Data.Step()
    local c = memo[name]
    if c and c.key == key and (not maxAge or GetTime() - c.at < maxAge) then return c.value end
    -- A slow build an open window asks for again: the value it had now, the
    -- new one from the background. One whose key moved on again as soon as
    -- it landed is built here: a key that never holds must not loop.
    if c and c.slow and drawing and not (drawing == "ready" and landed[name]) then
        Queue({ name = "memo:" .. name, sources = drawingSources,
            run = function() Make(name, key, build) end, done = function() landed[name] = true end })
        return c.value
    end
    return Make(name, key, build)
end

-- Drops every memo whose name starts with `prefix` (all of them without one).
function Data.Forget(prefix)
    for name in pairs(memo) do
        if not prefix or name:sub(1, #prefix) == prefix then memo[name] = nil end
    end
end

-- fn wrapped so that calls run it at most once per `gap` seconds: the first
-- right away, the rest folded into one call when the gap is over.
function Data.Coalesce(fn, gap)
    local last, pending = nil, false
    return function()
        if pending then return end
        local now = GetTime()
        local wait = last and (last + gap - now) or 0
        if wait <= 0 or not (C_Timer and C_Timer.After) then
            last = now
            fn()
            return
        end
        pending = true
        C_Timer.After(wait, function()
            pending = false
            last = GetTime()
            fn()
        end)
    end
end

---------------------------------------------------------------------------
-- Sources
---------------------------------------------------------------------------
local sources = {}

local function Get(name)
    local s = sources[name]
    if not s then
        s = { version = 0, watchers = {} }
        sources[name] = s
    end
    return s
end

-- Declares a source. opts.sig() -> string: a cheap look at the data (counts,
-- the newest entry) so a write that forgot Data.Changed still shows.
function Data.Source(name, opts)
    local s = Get(name)
    if opts and opts.sig then s.sig = opts.sig end
    return s
end

-- The data changed: lists built on it are rebuilt, windows showing it redraw.
function Data.Changed(name)
    local s = Get(name)
    s.version = s.version + 1
    for _, fn in ipairs(s.watchers) do ns.SafeCall(fn, name) end
end

-- Changed without telling the windows yet (one per price in a full scan);
-- Data.Notify once the batch is in.
function Data.Bump(name)
    local s = Get(name)
    s.version = s.version + 1
end

function Data.Notify(name)
    for _, fn in ipairs(Get(name).watchers) do ns.SafeCall(fn, name) end
end

function Data.Version(name) return Get(name).version end

function Data.Watch(name, fn)
    local w = Get(name).watchers
    w[#w + 1] = fn
end

-- A string that changes whenever one of these sources does.
function Data.Key(names)
    if type(names) == "string" then names = { names } end
    local parts = {}
    for _, name in ipairs(names or {}) do
        local s = Get(name)
        parts[#parts + 1] = name .. "#" .. s.version
        if s.sig then
            local ok, sig = pcall(s.sig)
            parts[#parts + 1] = ok and tostring(sig) or "?"
        end
    end
    return table.concat(parts, ";")
end

---------------------------------------------------------------------------
-- Windows and lists
---------------------------------------------------------------------------
-- Makes UI (with Refresh and IsShown) redraw when one of `names` changes,
-- only while it is open, at most once a second per source (a busy source,
-- like a scan every second, never holds back a rare one). opts.shows(name)
-- -> false skips a change the open tab does not show (a scan while on the
-- roster). Sets UI.RefreshSoon for other data-driven calls.
-- Background work (see above): opts.prebuild() creates the window's frames
-- and opts.warm() reads the memos its first tab shows, both a while after
-- login, so the first open is not the one that builds them. UI.Refresh is
-- wrapped: slow memos it reads are rebuilt in the background.
function Data.Window(UI, names, opts)
    opts = opts or {}
    local refresh, ready = UI.Refresh, false
    local function WithStack(message)
        return tostring(message) .. "\n" .. (debugstack and debugstack(2, 12, 0) or "")
    end
    function UI.Refresh()
        local was, wasSources = drawing, drawingSources
        drawing, drawingSources = ready and "ready" or true, names
        ready = false
        -- Put back even when the redraw errors: a stuck flag would give
        -- every later caller (slash, tooltips) old values.
        local ok, err = xpcall(refresh, WithStack)
        drawing, drawingSources = was, wasSources
        if not ok then error(err, 0) end
    end
    local function Redraw() if UI.IsShown() then UI.Refresh() end end
    UI.RefreshSoon = Data.Coalesce(Redraw, opts.gap or 1)
    for _, name in ipairs(names) do
        local soon = Data.Coalesce(Redraw, opts.gap or 1)
        Data.Watch(name, function(src)
            if UI.IsShown() and (not opts.shows or opts.shows(src)) then soon() end
        end)
    end
    windows[#windows + 1] = function()
        if UI.IsShown() then
            ready = true
            UI.Refresh()
        end
    end
    local id = #windows
    if opts.prebuild then Queue({ name = "prebuild:" .. id, run = opts.prebuild }) end
    if opts.warm then Queue({ name = "warm:" .. id, run = opts.warm, sources = names, again = true }) end
end


-- A row whose fields come from make(arg) when it is first drawn or searched
-- (Style.List calls `build`). `fields` are set now: what sorting or
-- filtering needs (time, id, header).
function Data.Row(make, arg, fields)
    local row = fields or {}
    row.build = function(self)
        for k, v in pairs(make(arg)) do self[k] = v end
    end
    return row
end

-- Fills a Style.List from data, kept between redraws.
-- spec = {
--   name     unique memo name ("economy:transactions"),
--   sources  source names the rows come from,
--   key      the view's own filters (a value or a list: scope, range, sort...),
--   maxAge   seconds, when rows show ages ("5 min ago"),
--   build    function(add, raw) -> extra table or nil: add(arg, fields) a lazy
--            row made by spec.row(arg); raw(row) a ready row (headers),
--   row      function(arg) -> row fields,
--   empty    text when there are no rows,
-- }
-- Returns the extra table (counts, totals) with .rows.
function Data.List(list, spec)
    local key = spec.key
    if type(key) == "table" then
        local parts = {}
        for i = 1, #key do parts[i] = tostring(key[i]) end
        key = table.concat(parts, "|")
    end
    local full = Data.Key(spec.sources) .. "|" .. tostring(key)
    local v = Data.Memo(spec.name, full, function()
        local rows = {}
        local function add(arg, fields)
            Data.Step()
            rows[#rows + 1] = Data.Row(spec.row, arg, fields)
        end
        local function raw(row) rows[#rows + 1] = row end
        local extra = spec.build(add, raw) or {}
        extra.rows = rows
        return extra
    end, spec.maxAge)
    if list then
        -- The placeholder goes outside the memo: the kept table never changes.
        list:SetItems(#v.rows > 0 and v.rows or (spec.empty and { { text = HEX.muted .. spec.empty .. "|r" } } or {}))
    end
    return v
end

---------------------------------------------------------------------------
-- Bags (a live game read, not a log, but read by several modules per redraw)
---------------------------------------------------------------------------
-- { [itemID] = { n, link } } over bags 0-4 (Economy.ScanBags), shared: kept
-- until the bags change, a second at most. Economy reads its own copy (it
-- compares before and after each change). Callers must not change it.
function Data.Bags()
    return Data.Memo("bags", Data.Key("bags"), function()
        return (ns.Economy and ns.Economy.ScanBags and ns.Economy.ScanBags()) or {}
    end, 1)
end

-- Registered first (Data.lua loads before the modules), so the "bags"
-- source has moved on before any module handles the same event.
ns.RegisterModule("Data", {
    -- The warm-up waits for the loading screen and the other addons.
    init = function()
        startAt = GetTime() + WARM_DELAY
        if #jobs > 0 then driver:Show() end
    end,
    events = { "BAG_UPDATE", "BAG_UPDATE_DELAYED", "PLAYER_EQUIPMENT_CHANGED" },
    onEvent = function() Data.Changed("bags") end,
})
