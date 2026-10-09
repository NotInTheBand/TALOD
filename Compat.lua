-- TALOD - client compatibility layer. Loads first.
--
-- WoW Forever (game type "camelot") is the 12.1 engine with vanilla content. It
-- reports WOW_PROJECT_MAINLINE, so it is detected by interface range only:
-- Classic Era reports 115xx, Forever 16xxx, retail 12xxxx.
--
-- Forever runs under the 12.x addon restrictions: unit APIs can hand back
-- secret values, the combat log is not available to addons, and several
-- legacy globals are gone. Every client difference TALOD cares about is
-- funneled through this file.

local ADDON_NAME, ns = ...

local iface = select(4, GetBuildInfo())
ns.interfaceVersion = tonumber(iface) or 0
ns.IS_FOREVER = ns.interfaceVersion >= 16000 and ns.interfaceVersion < 20000
ns.IS_ERA = ns.interfaceVersion > 0 and ns.interfaceVersion < 16000
ns.FLAVOR = ns.IS_FOREVER and "forever" or (ns.IS_ERA and "era" or "other")
ns.FLAVOR_NAME = ns.IS_FOREVER and "WoW Forever" or (ns.IS_ERA and "Classic Era" or "unsupported client")

ns.CHAT_PREFIX = ns.ICON_TAG .. " " .. ns.TITLE

---------------------------------------------------------------------------
-- Secret values
---------------------------------------------------------------------------
-- type() is safe on a secret; ==, <, truthiness, concatenation, strsplit and
-- table indexing are not. Every unit read goes through these helpers, and a
-- secret is treated as "unknown".
local S = {}
ns.Secret = S

local issecretvalue = issecretvalue
local canaccessvalue = canaccessvalue

function S.IsReadable(v)
    if type(v) == "nil" then return false end
    if type(canaccessvalue) == "function" then
        local ok, readable = pcall(canaccessvalue, v)
        return ok and readable == true
    end
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, v)
        return ok and not secret
    end
    return true
end

-- True when v is a secret (as opposed to nil or readable).
function S.IsSecret(v)
    if type(v) == "nil" then return false end
    return not S.IsReadable(v)
end

-- v when readable, otherwise nil.
function S.Value(v)
    if S.IsReadable(v) then return v end
    return nil
end

-- Calls fn(...) protected. Returns its first result when readable; the second
-- return is true when the call worked but the value was secret.
function S.Call(fn, ...)
    if type(fn) ~= "function" then return nil, false end
    local ok, v = pcall(fn, ...)
    if not ok then return nil, false end
    if type(v) == "nil" then return nil, false end
    if S.IsReadable(v) then return v, false end
    return nil, true
end

-- Like S.Call, but returns up to `count` results, each nil when secret.
function S.CallMulti(count, fn, ...)
    if type(fn) ~= "function" then return end
    local results = { pcall(fn, ...) }
    if not results[1] then return end
    local out = {}
    for i = 1, count do out[i] = S.Value(results[i + 1]) end
    return unpack(out, 1, count)
end

-- Like S.Call, but a secret result comes back as the second return instead of
-- being dropped. 12.x widgets (StatusBar:SetValue, Texture:SetTexture, ...)
-- may display secrets addons cannot read, so the raw value may only be passed
-- to a widget setter inside pcall — never compared, formatted or stored past
-- the current refresh.
function S.CallRaw(fn, ...)
    if type(fn) ~= "function" then return nil, nil end
    local ok, v = pcall(fn, ...)
    if not ok or type(v) == "nil" then return nil, nil end
    if S.IsReadable(v) then return v, nil end
    return nil, v
end

-- Describes a value for /talod probe: "SECRET", "nil", or its tostring().
function S.Describe(v)
    if type(v) == "nil" then return "nil" end
    if not S.IsReadable(v) then return "SECRET" end
    return tostring(v)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
function ns.IsEventValid(event)
    if C_EventUtils and C_EventUtils.IsEventValid then
        local ok, valid = pcall(C_EventUtils.IsEventValid, event)
        if ok and valid == false then return false end
    end
    return true
end

-- Registers only events the client knows, and never lets a restricted event
-- raise an error at load time.
function ns.RegisterEventSafe(frame, event)
    if not ns.IsEventValid(event) then return false end
    local ok = pcall(frame.RegisterEvent, frame, event)
    return ok
end

-- A UNIT_* event for one unit only. Registered plainly, UNIT_SPELLCAST_* and
-- the like arrive for every nameplate and group member (hundreds a second in
-- a battleground) just to be dropped by the handler. Handlers still check the
-- unit: without RegisterUnitEvent this falls back to the plain registration.
function ns.RegisterUnitEventSafe(frame, event, unit)
    if not ns.IsEventValid(event) then return false end
    if frame.RegisterUnitEvent and pcall(frame.RegisterUnitEvent, frame, event, unit) then return true end
    return (pcall(frame.RegisterEvent, frame, event))
end

---------------------------------------------------------------------------
-- CVars, items, misc
---------------------------------------------------------------------------
function ns.GetCVarNumber(name)
    local value
    if C_CVar and C_CVar.GetCVar then
        value = S.Call(C_CVar.GetCVar, name)
    elseif GetCVar then
        value = S.Call(GetCVar, name)
    end
    return tonumber(value)
end

function ns.SetCVarValue(name, value)
    if C_CVar and C_CVar.SetCVar then
        return pcall(C_CVar.SetCVar, name, tostring(value))
    elseif SetCVar then
        return pcall(SetCVar, name, tostring(value))
    end
    return false
end

ns.IsItemInRange = (C_Item and C_Item.IsItemInRange) or IsItemInRange

function ns.ItemExists(itemID)
    local fn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not fn then return nil end
    local ok, result = pcall(fn, itemID)
    if not ok then return nil end
    return result ~= nil
end

function ns.RequestItem(itemID)
    if C_Item and C_Item.RequestLoadItemDataByID then
        pcall(C_Item.RequestLoadItemDataByID, itemID)
    end
end

-- "solo", "party" or "raid", and the group size.
function ns.GroupState()
    local size = GetNumGroupMembers and (S.Call(GetNumGroupMembers)) or 0
    if IsInRaid and S.Call(IsInRaid) == true then return "raid", size end
    if (IsInGroup and S.Call(IsInGroup) == true) or (size or 0) > 1 then return "party", size end
    return "solo", 1
end

function ns.InCombat()
    return (S.Call(UnitAffectingCombat, "player")) == true
end

-- The zone's PvP type: "contested", "hostile", "friendly", "sanctuary",
-- "arena", "combat" or nil, plus whether the zone forces the flag on.
function ns.ZonePvPInfo()
    local fn = (C_PvP and C_PvP.GetZonePVPInfo) or GetZonePVPInfo
    if not fn then return nil end
    local ok, pvpType, isFFA, faction = pcall(fn)
    if not ok then return nil end
    return S.Value(pvpType), S.Value(isFFA), S.Value(faction)
end

-- Creates a frame from a template, falling back to a bare frame when the
-- template does not exist on this client.
function ns.CreateFrameSafe(frameType, name, parent, template)
    if template then
        local ok, frame = pcall(CreateFrame, frameType, name, parent, template)
        if ok and frame then return frame, true end
    end
    return CreateFrame(frameType, name, parent), false
end

-- Runs fn protected. TALOD errors are kept in TALODDB.errorLog (with
-- a stack) and shown in a copyable window by /talod errors, because chat cannot
-- be copied. Each distinct error is announced once per session.
local announced = {}
-- One handler for every call: SafeCall runs for each event, handler and
-- module tick, and a closure (plus an argument table) per call was a steady
-- stream of garbage the collector then stalls frames for.
local function ErrorHandler(message)
    local stack = debugstack and debugstack(2, 12, 0) or ""
    return tostring(message) .. "\n" .. stack
end
-- WoW's xpcall passes extra arguments on; plain Lua 5.1's (the test mock) does not.
local XPCALL_ARGS = select(2, xpcall(function(a) return a end, ErrorHandler, true)) == true

function ns.SafeCall(fn, ...)
    local ok, err
    if XPCALL_ARGS then
        ok, err = xpcall(fn, ErrorHandler, ...)
    elseif select("#", ...) == 0 then
        ok, err = xpcall(fn, ErrorHandler)
    else
        local args, n = { ... }, select("#", ...)
        ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, ErrorHandler)
    end
    if ok then return true end
    local db = ns.DB()
    if type(db) ~= "table" then
        -- Before startup there is nowhere to keep it: show it plainly.
        print(ns.CHAT_PREFIX .. ": |cffff5555error|r " .. tostring(err))
    else
        db.errorLog = type(db.errorLog) == "table" and db.errorLog or {}
        local first = err:match("^[^\n]*") or err
        local entry
        for _, e in ipairs(db.errorLog) do
            if e.message == first then entry = e break end
        end
        if entry then
            entry.count = (entry.count or 1) + 1
            entry.last = date("%Y-%m-%d %H:%M:%S")
        else
            table.insert(db.errorLog, 1, { message = first, stack = err, count = 1,
                first = date("%Y-%m-%d %H:%M:%S"), last = date("%Y-%m-%d %H:%M:%S"),
                version = ns.VERSION, client = ns.FLAVOR })
            while #db.errorLog > 30 do table.remove(db.errorLog) end
        end
        if not announced[first] then
            announced[first] = true
            print(ns.CHAT_PREFIX .. ": |cffff5555error|r caught and logged — type |cffffffff" .. ns.Cmd.Text("errors") .. "|r to copy it.")
        end
    end
    return false
end

function ns.ShowErrors()
    local log = ns.DB() and ns.DB().errorLog or {}
    if #log == 0 then
        ns.Print("no errors logged.")
        return
    end
    local lines = { ns.NAME .. " " .. tostring(ns.VERSION) .. " errors (" .. ns.FLAVOR .. "), newest first:", "" }
    for i, e in ipairs(log) do
        lines[#lines + 1] = string.format("#%d  x%d  first %s  last %s  (v%s %s)", i, e.count or 1,
            tostring(e.first), tostring(e.last), tostring(e.version), tostring(e.client))
        lines[#lines + 1] = tostring(e.stack or e.message)
        lines[#lines + 1] = ""
    end
    if ns.Probe and ns.Probe.ShowText then ns.Probe.ShowText(table.concat(lines, "\n")) end
end

-- Optional modules register here so they can be removed by deleting their
-- TOC lines: { defaults = {...}, init = fn, refresh = fn, events = {...},
-- playerEvents = {...} (UNIT_* events wanted for "player" only),
-- onEvent = fn(event, ...), tick = fn(elapsed), slash = fn(command, rest) ->
-- handled }. command is the id from Commands.lua (its words and help live there). Defaults are merged into ns.defaults at load,
-- before SavedVariables are read.
ns.modules = {}
function ns.RegisterModule(name, module)
    module.name = name
    ns.modules[#ns.modules + 1] = module
    ns.modules[name] = module
    if module.defaults and ns.defaults then
        for key, value in pairs(module.defaults) do
            if ns.defaults[key] == nil then ns.defaults[key] = value end
        end
    end
end

function ns.Print(msg)
    print(ns.CHAT_PREFIX .. ": " .. tostring(msg))
end

function ns.PlaySoundKit(kit)
    if not kit or not PlaySound then return end
    pcall(PlaySound, kit, "Master")
end
