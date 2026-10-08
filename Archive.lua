-- TALOD - Archive: old entries kept in a second addon that loads on demand.
--
-- The game reads an addon's saved data when the addon loads. The archive
-- addon (ns.ARCHIVE_ADDON, its own folder, "## LoadOnDemand: 1") has its own
-- saved variable (ns.ARCHIVE_DB): while it is not loaded, its file is not
-- read, so archived data costs no memory and no loading time. Loaded on a
-- click or by the cleanup run (Cleanup.lua), it then stays in memory until
-- the next /reload or login: the game cannot unload an addon. An addon that
-- was not loaded in a session keeps its saved file as it was.
--
-- Cleanup rules that can keep what they remove (rule.archive) hand each
-- entry to Archive.Put instead of dropping it, while the archive is loaded.
--
-- TALODArchiveDB = { v = 1, stores = { [rule id] = { "t|c|key|value", ... } } }:
-- one packed string per entry (Store.PackList): t = when it was moved, c =
-- the character that moved it, key and value as the rule gives them.

local ADDON_NAME, ns = ...
local S = ns.Secret

local Archive = {}
ns.Archive = Archive

local VERSION = 1

local function API(name) return (C_AddOns and C_AddOns[name]) or _G[name] end

ns.Data.Source("archive")

function Archive.Loaded()
    local loaded = S.Call(API("IsAddOnLoaded"), ns.ARCHIVE_ADDON)
    return loaded and true or false
end

-- "loaded", "unloaded" (installed, not read: costs nothing), "disabled"
-- (turned off in the game's AddOn list) or "missing" (not installed).
function Archive.State()
    if Archive.Loaded() then return "loaded" end
    local name, _, _, _, reason = S.CallMulti(5, API("GetAddOnInfo"), ns.ARCHIVE_ADDON)
    if not name or reason == "MISSING" then return "missing" end
    if reason == "DISABLED" then return "disabled" end
    return "unloaded"
end

function Archive.Usable()
    local state = Archive.State()
    return state == "loaded" or state == "unloaded"
end

local function DB()
    local a = _G[ns.ARCHIVE_DB]
    if type(a) ~= "table" then a = {} _G[ns.ARCHIVE_DB] = a end
    a.v = a.v or VERSION
    if type(a.stores) ~= "table" then a.stores = {} end
    return a
end

-- Loads the archive (a click, a command, or the cleanup run out of
-- combat). true, or false and why.
function Archive.Load()
    if Archive.Loaded() then DB() return true end
    if InCombatLockdown and InCombatLockdown() then return false, "in combat" end
    local state = Archive.State()
    if state ~= "unloaded" then return false, state == "disabled" and "turned off in the AddOn list" or "not installed" end
    local t0 = ns.Data.Clock()
    local ok, why = S.CallMulti(2, API("LoadAddOn"), ns.ARCHIVE_ADDON)
    local t1 = ns.Data.Clock()
    if t0 and t1 then ns.Data.Time("archive", "load", t1 - t0) end
    if not ok then return false, tostring(why or "the game did not load it") end
    DB()
    ns.Data.Changed("archive")
    return true
end

-- Keeps one removed entry. Only while loaded (callers check).
function Archive.Put(id, key, value)
    local stores = DB().stores
    local list = stores[id]
    if not list then list = {} stores[id] = list end
    local entry = ns.Store.PackList({ time(), ns.Store.Me(), key, value }, 4, "|")
    if entry then
        list[#list + 1] = entry
        ns.Data.Bump("archive")
    end
end

local function Decode(s)
    local f = ns.Store.SplitList(s, "|")
    local U = ns.Store.UnpackValue
    return { t = U(f[1] or ""), c = U(f[2] or ""), key = U(f[3] or ""), value = U(f[4] or "") }
end
Archive.Decode = Decode

-- Entries of one rule (nothing while not loaded).
function Archive.Count(id)
    if not Archive.Loaded() then return 0 end
    local list = DB().stores[id]
    return type(list) == "table" and #list or 0
end

function Archive.Total()
    if not Archive.Loaded() then return 0 end
    local n = 0
    for _, list in pairs(DB().stores) do if type(list) == "table" then n = n + #list end end
    return n
end

-- for i, entry in Archive.Entries(id): { t, c, key, value }, oldest first.
function Archive.Entries(id)
    local list, i = Archive.Loaded() and DB().stores[id] or {}, 0
    return function()
        i = i + 1
        local s = list[i]
        if s == nil then return nil end
        return i, Decode(s)
    end
end

-- Every value archived under `key` by rule `id`, oldest first. An index per
-- rule, built on the first lookup and kept until the archive changes.
function Archive.Lookup(id, key)
    if not Archive.Loaded() then return {} end
    local index = ns.Data.Memo("archive:index:" .. id, ns.Data.Key({ "archive" }), function()
        local out = {}
        for _, e in Archive.Entries(id) do
            if e.key ~= nil then
                local list = out[e.key]
                if not list then list = {} out[e.key] = list end
                list[#list + 1] = e.value
            end
        end
        return out
    end)
    return index[key] or {}
end

-- Drops one rule's entries, or every entry. Only while loaded.
function Archive.Clear(id)
    if not Archive.Loaded() then return 0 end
    local stores, n = DB().stores, 0
    for name, list in pairs(stores) do
        if not id or name == id then
            n = n + (type(list) == "table" and #list or 0)
            stores[name] = nil
        end
    end
    ns.Data.Changed("archive")
    return n
end

local STATE_TEXT = {
    loaded = "loaded (until /reload)",
    unloaded = "installed, not loaded: costs no memory",
    disabled = "turned off in the game's AddOn list",
    missing = "not installed",
}

function Archive.StateText()
    local state = Archive.State()
    local text = "Archive: " .. STATE_TEXT[state]
    if state == "loaded" then text = text .. ", " .. Archive.Total() .. " entries" end
    return text
end
