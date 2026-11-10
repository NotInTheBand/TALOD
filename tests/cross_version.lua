-- Cross-version saved data (run by tests/cross_version.py after wowmock.lua):
-- one session of one addon version on a saved TALODDB, from login to logout,
-- and the saved tables as text. Compared by the Python side.
XV = {}

---------------------------------------------------------------------------
-- Saved tables as text: keys sorted, so two equal tables give equal text.
---------------------------------------------------------------------------
local function KeyOrder(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    if ta == "number" or ta == "string" then return a < b end
    return tostring(a) < tostring(b)
end

local function Scalar(v)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" then
        if v ~= v then return "(0/0)" end
        if v == math.huge then return "(1/0)" end
        if v == -math.huge then return "(-1/0)" end
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
        return string.format("%.17g", v)
    end
    if t == "boolean" or t == "nil" then return tostring(v) end
    error("not saved data: a " .. t)
end

local function Write(v, out, seen)
    if type(v) ~= "table" then out[#out + 1] = Scalar(v) return end
    if seen[v] then error("a table saved twice (a cycle or a shared table)") end
    seen[v] = true
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, KeyOrder)
    out[#out + 1] = "{"
    for _, k in ipairs(keys) do
        out[#out + 1] = "[" .. Scalar(k) .. "]="
        Write(v[k], out, seen)
        out[#out + 1] = ","
    end
    out[#out + 1] = "}"
    seen[v] = nil
end

function XV.Serialize(v)
    local out = {}
    Write(v, out, {})
    return table.concat(out)
end

function XV.Parse(text)
    if text == nil or text == "" or text == "nil" then return nil end
    return assert(loadstring("return " .. text))()
end

-- Where two saved values differ: up to `max` paths ("a.b[3]: x -> y").
function XV.Diff(textA, textB, max)
    local out = {}
    local function Show(v)
        if type(v) == "table" then return "{...}" end
        local s = Scalar(v)
        return #s > 60 and s:sub(1, 57) .. "..." or s
    end
    local function Walk(a, b, path)
        if #out >= max then return end
        if type(a) ~= "table" or type(b) ~= "table" then
            if a ~= b and not (a ~= a and b ~= b) then out[#out + 1] = path .. ": " .. Show(a) .. " -> " .. Show(b) end
            return
        end
        local keys = {}
        for k in pairs(a) do keys[#keys + 1] = k end
        for k in pairs(b) do if a[k] == nil then keys[#keys + 1] = k end end
        table.sort(keys, KeyOrder)
        for _, k in ipairs(keys) do
            Walk(a[k], b[k], path .. (type(k) == "number" and ("[" .. k .. "]") or ("." .. tostring(k))))
        end
    end
    Walk(XV.Parse(textA), XV.Parse(textB), "")
    return out
end

-- Tables put together from several saved files: maps merged key by key,
-- of two lists the longer, of two values the first.
local function IsList(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n > 0 and n == #t
end

local function Merge(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        if a == nil then return b end
        return a
    end
    if IsList(a) or IsList(b) then return #b > #a and b or a end
    for k, v in pairs(b) do a[k] = Merge(a[k], v) end
    return a
end

function XV.MergeTexts(texts)
    local v
    for _, text in ipairs(texts) do v = Merge(v, XV.Parse(text)) end
    return XV.Serialize(v)
end

-- Top-level key -> its text, for the Python side to compare key by key.
function XV.SerializeTop(t)
    local out = {}
    for k, v in pairs(type(t) == "table" and t or {}) do out[tostring(k)] = XV.Serialize(v) end
    return out
end

---------------------------------------------------------------------------
-- Loading the files as the game does: a file that errors is reported and
-- the next one still loads; an event handler that errors does not stop the
-- other frames.
---------------------------------------------------------------------------
XV.errors = {}
local function Note(where, err) XV.errors[#XV.errors + 1] = where .. ": " .. tostring(err) end

function XV.LoadFiles(files)
    local ns = {}
    for _, f in ipairs(files) do
        local chunk, err = loadfile(f.path)
        if not chunk then Note("load " .. f.name, err)
        else
            local ok, e = pcall(chunk, ADDON_NAME, ns)
            if not ok then Note("run " .. f.name, e) end
        end
    end
    MOCK.ns = ns
    return ns
end

function XV.Fire(event, ...)
    for frame, events in pairs(MOCK.events) do
        local want = events[event]
        if want == true or (type(want) == "table" and want[(...)]) then
            local ok, e = pcall(frame.Fire, frame, "OnEvent", event, ...)
            if not ok then Note(event, e) end
        end
    end
end

local function Try(what, fn, ...)
    local ok, e = pcall(fn, ...)
    if not ok then Note(what, e) end
    return ok
end
XV.Try = Try

---------------------------------------------------------------------------
-- One session: o = { files, db (text), archive (text), version, iface,
-- windows = true (open every page) }.
---------------------------------------------------------------------------
function XV.Session(o)
    MOCK.iface = o.iface or 11509
    MOCK.metadata = { Version = o.version }
    XV.views = o.views
    -- Texture files added since the game started: a /reload does not see them.
    if o.noMedia then
        for _, f in ipairs({ "Glyphs.tga", "Hatch.tga", "Shadow.tga" }) do
            MOCK.missingFiles["Interface\\AddOns\\" .. ADDON_NAME .. "\\media\\textures\\" .. f] = true
        end
    end
    TALODDB = XV.Parse(o.db)
    local before = {}
    for _, e in ipairs(type(TALODDB) == "table" and type(TALODDB.errorLog) == "table" and TALODDB.errorLog or {}) do
        before[tostring(e.message)] = e.count or 1
    end
    _G[ADDON_NAME .. "ArchiveDB"] = XV.Parse(o.archive)
    MOCK.units.player = { exists = true, guid = "Player-1-0001", name = "Tester", level = 20, faction = "Alliance" }
    MOCK.SetGuild()
    MOCK.inGuild = true
    local ns = XV.LoadFiles(o.files)
    XV.Fire("ADDON_LOADED", ADDON_NAME)
    Try("tick", MOCK.Tick, 0.3)
    XV.Fire("PLAYER_ENTERING_WORLD")
    for _ = 1, 12 do Try("tick", MOCK.Tick, 0.5) end
    Try("timers", MOCK.RunTimers)
    if o.windows then XV.OpenAll(ns) end
    for _ = 1, 4 do Try("tick", MOCK.Tick, 0.5) end
    XV.Fire("PLAYER_LOGOUT")
    -- Errors this session caught (the saved log may hold an earlier one's).
    local log = type(TALODDB) == "table" and TALODDB.errorLog or {}
    for _, e in ipairs(type(log) == "table" and log or {}) do
        if (e.count or 1) > (before[tostring(e.message)] or 0) then Note("caught", e.stack or e.message) end
    end
    local stores = {}
    for _, def in ipairs(ns.Store and ns.Store.DEFS or {}) do stores[#stores + 1] = def.key end
    return {
        stores = stores,
        db = XV.SerializeTop(TALODDB),
        archive = XV.Serialize(_G[ADDON_NAME .. "ArchiveDB"]),
        errors = XV.errors,
        windows = XV.opened or {},
    }
end

-- Every page (and in a version with tabs in its page list, every tab and
-- view), Settings, and the floating pieces that are built at login.
function XV.OpenAll(ns)
    local Nav = ns.Nav
    XV.opened = {}
    local function Opened(name, ok) XV.opened[#XV.opened + 1] = name .. (ok and "" or " FAILED") end
    if Nav and Nav.Pages then
        for _, page in ipairs(Nav.Pages()) do
            local ok = Try("open " .. page.key, function() assert(Nav.Open(page.key), "Nav.Open false") end)
            Opened(page.key, ok)
            -- A version without tabs in its page list: each module's views
            -- (o.views[module] = { view keys }, read from its source).
            local mod = page.module and ns[page.module]
            if not Nav.Go and mod and mod.Show then
                for _, view in ipairs(XV.views and XV.views[page.module] or {}) do
                    Opened(page.key .. "/" .. view, Try("show " .. page.module .. " " .. view, mod.Show, view))
                end
            end
            if Nav.Go then
                for _, tab in ipairs(page.tabs or {}) do
                    if type(tab) == "table" and tab.key then
                        Opened(page.key .. "/" .. tab.key, Try("go " .. page.key .. "/" .. tab.key, Nav.Go, page.key, tab.key))
                        for _, v in ipairs(tab.views or {}) do
                            Try("go " .. page.key .. "/" .. tab.key .. "#" .. v, Nav.Go, page.key, tab.key, v)
                        end
                    end
                end
            end
        end
        if Nav.CloseAll then Try("close", Nav.CloseAll) end
    end
    if ns.Options and ns.Options.Open then Opened("options", Try("options", ns.Options.Open)) end
    Opened("panel", _G[ADDON_NAME .. "Panel"] ~= nil)
end
