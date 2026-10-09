-- TALOD - startup, event routing, the update tick and slash commands.
--
-- The slash command is /talod, never /pvp: /pvp is the game's
-- own command that toggles your PvP flag, and a Hardcore player must never
-- flag by mistyping an addon command.

local ADDON_NAME, ns = ...
local S = ns.Secret
local C = ns.C

local Main = {}
ns.Main = Main

local frame = CreateFrame("Frame")
ns.eventFrame = frame     -- the AH helper keeps it registered while it mutes the others during a full scan
local initialized = false
local elapsedSinceTick = 0

local function db() return ns.DB() end

-- Called by the settings page and slash commands after any change.
function ns.Refresh()
    if not initialized then return end
    if not db().enabled and ns.Plates then ns.Plates.HideAll() end
    for _, module in ipairs(ns.modules) do
        if module.refresh then ns.SafeCall(module.refresh) end
    end
    if ns.Options then ns.Options.Refresh() end
end

-- Unit reads are shared for the length of one tick (Core.lua, BeginTickReads):
-- Spotter, Census, Guild, the panel and the plates read the same nameplates
-- and target, and nothing in the game changes between them.
local function Tick()
    if not initialized then return end
    ns.BeginTickReads()
    if db().enabled then ns.SafeCall(ns.Spotter.Tick) end
    local Clock, Time = ns.Data.Clock, ns.Data.Time
    for _, module in ipairs(ns.modules) do
        if module.tick then
            local t0 = Clock()
            ns.SafeCall(module.tick)
            local t1 = Clock()
            if t0 and t1 then Time("tick", module.name, t1 - t0) end
        end
    end
    ns.EndTickReads()
end
Main.Tick = Tick

function Main.SetMaxNameplateDistance()
    local ok = ns.SetCVarValue(C.NAMEPLATE_DISTANCE_CVAR, C.RECOMMENDED_NAMEPLATE_DISTANCE)
    local current = ns.GetCVarNumber(C.NAMEPLATE_DISTANCE_CVAR)
    if ok and current and current + 0.01 >= C.RECOMMENDED_NAMEPLATE_DISTANCE then
        ns.Print(string.format("Nameplate Distance set to %d yd.", C.RECOMMENDED_NAMEPLATE_DISTANCE))
    else
        ns.Print("the game did not accept the nameplate-distance change. Set it manually under Options > Nameplates.")
    end
    ns.Refresh()
end

-- Saved data that has a default but is the player's history, not a setting.
-- Everything without a default (error log, AH scan log, the fishing sound /
-- auto loot values to put back, ...) is runtime data and is kept as well, so
-- a new data store can never be wiped by a settings reset.
Main.DATA_KEYS = { "players", "journal", "census", "gear", "skills", "economy", "fishing", "guild", "prices", "ahFullScan", "ladders", "ahOwned", "ahBids",
    "profPlanTargets", "profPlanFrom", "profPlanExcluded", "versionNews", "versionAskedAt" }
-- Positions saved without a default: a reset moves those frames back too.
Main.POSITION_KEYS = { fishHudPos = true, fishHudDock = true, guildNoticePos = true, guildMiniPos = true, navPos = true, navSize = true }

-- The slowest work this session (Data.Timings), in the copy window so it
-- can be pasted into a bug report about frame lag.
function Main.ShowTimings(arg)
    if arg == "reset" then
        ns.Data.ResetTimings()
        ns.Print("timings cleared: play a while, then " .. ns.Cmd.Text("perf") .. " again.")
        return
    end
    local list = ns.Data.Timings()
    if #list == 0 then
        ns.Print("no timings yet (this client cannot measure them, or nothing ran).")
        return
    end
    local lines = { ns.NAME .. " " .. tostring(ns.VERSION) .. " timings this session (" .. ns.FLAVOR .. "), slowest first:",
        "  max ms   avg ms    runs  what", "" }
    for i = 1, math.min(#list, 60) do
        local t = list[i]
        lines[#lines + 1] = string.format("%8.1f %8.1f %7d  %s %s", t.max, t.avg, t.n, t.kind, t.name)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "build / background: only runs of 1 ms or more are counted. " .. ns.Cmd.Text("perf", "reset") .. " starts over."
    if ns.Probe and ns.Probe.ShowText then ns.Probe.ShowText(table.concat(lines, "\n")) end
end

function Main.ResetSettings()
    local old, kept = db(), {}
    for _, key in ipairs(Main.DATA_KEYS) do kept[key] = old[key] end
    for key, value in pairs(old) do
        if ns.defaults[key] == nil and not Main.POSITION_KEYS[key] then kept[key] = value end
    end
    local fresh = ns.SetDB({})
    for key, value in pairs(kept) do fresh[key] = value end
    ns.CopyDefaults(ns.DB(), ns.defaults)
    ns.DB().welcomeShown, ns.DB().distanceHintShown = true, true
    if ns.Panel then ns.Panel.RestorePosition() end
    if ns.Safety then ns.Safety.RestorePosition() end
    if ns.FishingUI and ns.FishingUI.ResetHUD then ns.FishingUI.ResetHUD() end
    if ns.GuildUI and ns.GuildUI.ResetNotice then ns.GuildUI.ResetNotice() end
    if ns.GuildUI and ns.GuildUI.ResetMini then ns.GuildUI.ResetMini() end
    ns.Print("settings reset (journal, lists, census, gear, skills, economy, prices, fishing and guild kept).")
    ns.Refresh()
end

---------------------------------------------------------------------------
-- Lists
---------------------------------------------------------------------------
-- kind: "kos", "avoid", "unlist", "note", "who". rest: a name or "target",
-- then the note text for "note".
function Main.ListCommand(kind, rest)
    local J = ns.Journal
    rest = rest or ""
    local nameText, noteText = rest:match("^(%S*)%s*(.-)$")
    local key, facts = J.ResolveName(nameText)
    if not key then
        ns.Print("target a player or give a name: " .. ns.Cmd.Text(kind, "<name>"))
        return
    end
    if kind == "kos" or kind == "avoid" then
        J.SetList(key, kind, facts)
        ns.Print(key .. " added to " .. (kind == "kos" and "kill on sight" or "avoid") .. ".")
    elseif kind == "unlist" then
        local rec = ns.PlayerRecord(key)
        if rec and rec.list then
            rec.list, rec.listBy = nil, nil
            ns.Print(key .. " removed from your lists.")
        else
            ns.Print(key .. " is not on a list.")
        end
    elseif kind == "note" then
        J.SetNote(key, noteText)
        ns.Print(noteText ~= "" and ("note saved for " .. key .. ".") or ("note cleared for " .. key .. "."))
    elseif kind == "who" then
        ns.Print(J.Describe(key))
    end
    ns.Refresh()
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local function PrintHelp()
    print("|cff" .. ns.COLOR .. ns.NAME .. " v" .. ns.VERSION .. "|r (" .. ns.FLAVOR_NAME .. ")")
    for _, line in ipairs(ns.Cmd.HelpLines()) do print(line) end
end

local function ParseOnOff(value)
    if value == "on" then return true end
    if value == "off" then return false end
    return nil
end

local function Toggle(key, value, usage)
    local enable = ParseOnOff(value)
    if enable == nil then
        ns.Print("use " .. usage)
        return
    end
    db()[key] = enable
    ns.Refresh()
end

-- The typed word becomes its id (Commands.lua), so renaming a command there
-- never touches this routing or the modules.
local function HandleSlash(msg)
    local word, rest = (msg or ""):match("^(%S*)%s*(.-)$")
    local command = ns.Cmd.Resolve(word)
    rest = rest or ""
    local value = string.lower(rest)

    if command == nil then
        PrintHelp()

    elseif command == "settings" then
        ns.Options.Open()

    elseif command == "help" then
        PrintHelp()

    elseif command == "panel" then
        if value == "lock" or value == "unlock" then
            db().panelLocked = value == "lock"
            if value == "unlock" then db().panelShown = true end
            ns.Refresh()
        elseif value == "reset" then
            ns.Panel.ResetPosition()
        else
            Toggle("panelShown", value, ns.Cmd.Text("panel") .. " on|off|lock|unlock|reset")
        end

    elseif command == "alerts" then
        if value == "test" then
            ns.Alerts.Reset()
            ns.Alerts.Test()
        else
            Toggle("alertsEnabled", value, ns.Cmd.Text("alerts") .. " on|off|test")
        end

    elseif command == "badges" then
        Toggle("badgesEnabled", value, ns.Cmd.Text("badges") .. " on|off")

    elseif command == "flag" then
        if value == "reset" then
            ns.Safety.ResetPosition()
        else
            Toggle("flagIndicator", value, ns.Cmd.Text("flag") .. " on|off|reset")
        end

    elseif command == "kos" or command == "avoid" or command == "unlist" or command == "note" or command == "who" then
        Main.ListCommand(command, rest)

    elseif command == "journal" or command == "lists" then
        ns.Options.OpenTab(ns.Options.TabIndex("Journal"), command == "lists" and 2 or 1)

    elseif command == "distance" then
        if value == "max" then
            Main.SetMaxNameplateDistance()
        else
            local current = ns.GetCVarNumber(C.NAMEPLATE_DISTANCE_CVAR)
            ns.Print(current and string.format("Nameplate Distance is %s yd (enemies are spotted up to there). Max: %d yd, " .. ns.Cmd.Text("distance") .. " max.",
                ns.FormatNumber(current), C.RECOMMENDED_NAMEPLATE_DISTANCE) or "could not read the Nameplate Distance setting.")
        end

    elseif command == "probe" then
        Tick()
        ns.Probe.Run()

    elseif command == "errors" then
        if value == "clear" then
            db().errorLog = {}
            ns.Print("error log cleared.")
        else
            ns.ShowErrors()
        end

    elseif command == "perf" then
        Main.ShowTimings(value)

    elseif command == "clear" then
        ns.Spotter.Clear()
        ns.Spotter.ScanPlates()
        ns.Refresh()

    elseif command == "reset" then
        Main.ResetSettings()

    else
        for _, module in ipairs(ns.modules) do
            if module.slash and module.slash(command, rest) then return end
        end
        PrintHelp()
    end
end

-- Addon compartment (minimap addon menu) entry; named in the TOC.
_G[ns.COMPARTMENT_FUNC] = function()
    if ns.Nav then ns.Nav.ShowMenu() elseif ns.Options then ns.Options.Open() end
end

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------
local function MaybePrintHints()
    if not db().welcomeShown then
        db().welcomeShown = true
        ns.Print("v" .. ns.VERSION .. " — enemy players near you show in the |cffffffffEnemies nearby|r panel and raise an alert. "
            .. "Type |cffffffff" .. ns.Cmd.PREFIX .. "|r for settings, |cffffffff" .. ns.Cmd.Text("help") .. "|r for commands.")
    end
    if not db().distanceHintShown then
        local current = ns.GetCVarNumber(C.NAMEPLATE_DISTANCE_CVAR)
        if current then
            db().distanceHintShown = true
            if current + 0.01 < C.RECOMMENDED_NAMEPLATE_DISTANCE then
                ns.Print(string.format("enemies are spotted by their nameplates, now up to %s yd. |cffffffff" .. ns.Cmd.Text("distance") .. " max|r raises that to %d yd.",
                    ns.FormatNumber(current), C.RECOMMENDED_NAMEPLATE_DISTANCE))
            end
        end
    end
end

local function Initialize()
    local fresh = ns.DB() == nil
    ns.SetDB(ns.DB() or {})
    ns.CopyDefaults(ns.DB(), ns.defaults)

    -- Errors logged by other versions say nothing about this one.
    if type(db().errorLog) == "table" then
        for i = #db().errorLog, 1, -1 do
            if db().errorLog[i].version ~= ns.VERSION then table.remove(db().errorLog, i) end
        end
    end

    -- Migrations, checks and the tamper seal see the data as it was loaded, before any module touches it.
    ns.Store.Load(fresh)

    ns.RequestProbeItemData()
    for _, module in ipairs(ns.modules) do
        if module.init then ns.SafeCall(module.init) end
    end
    ns.Options.Register()

    for i, cmd in ipairs(ns.Cmd.Slashes()) do _G["SLASH_" .. ns.SLASH_KEY .. i] = cmd end
    SlashCmdList[ns.SLASH_KEY] = HandleSlash

    initialized = true
    MaybePrintHints()
    ns.Spotter.ScanPlates()
    ns.Refresh()
end

-- Spotter first, so entries exist before alerts, journal and panel see the event.
local routes = {}
local function Route(event, handler)
    routes[event] = routes[event] or {}
    table.insert(routes[event], handler)
end

for _, event in ipairs(ns.Spotter.EVENTS) do Route(event, ns.Spotter.OnEvent) end
for _, module in ipairs(ns.modules) do
    for _, event in ipairs(module.events or {}) do Route(event, module.onEvent) end
end
-- The seal goes last, after every module's own logout writes.
Route("PLAYER_LOGOUT", function() ns.Store.SealAll() end)
-- Your spells (and so range checks) change with level and talents.
for _, event in ipairs({ "SPELLS_CHANGED", "PLAYER_LEVEL_UP" }) do
    Route(event, function() ns.BuildRangeCheckers() end)
end

frame:RegisterEvent("ADDON_LOADED")
for event in pairs(routes) do ns.RegisterEventSafe(frame, event) end

-- UNIT_* events a module wants for "player" only (module.playerEvents) come
-- through their own frame, so other units' events never reach the addon.
local unitFrame = CreateFrame("Frame")
local unitRoutes = {}
for _, module in ipairs(ns.modules) do
    for _, event in ipairs(module.playerEvents or {}) do
        unitRoutes[event] = unitRoutes[event] or {}
        table.insert(unitRoutes[event], module.onEvent)
    end
end
for event in pairs(unitRoutes) do ns.RegisterUnitEventSafe(unitFrame, event, "player") end

local NONE = {}
function Main.OnEvent(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON_NAME then return end
        self:UnregisterEvent("ADDON_LOADED")
        Initialize()
        return
    end
    if not initialized then return end
    local t0 = ns.Data.Clock()
    for _, handler in ipairs((self == unitFrame and unitRoutes or routes)[event] or NONE) do
        ns.SafeCall(handler, event, ...)
    end
    local t1 = ns.Data.Clock()
    if t0 and t1 then ns.Data.Time("event", event, t1 - t0) end
end

local function OnEvent(self, event, ...)
    ns.SafeCall(Main.OnEvent, self, event, ...)
end
frame:SetScript("OnEvent", OnEvent)
unitFrame:SetScript("OnEvent", OnEvent)

frame:SetScript("OnUpdate", function(self, elapsed)
    elapsedSinceTick = elapsedSinceTick + elapsed
    if elapsedSinceTick < C.TICK_INTERVAL then return end
    elapsedSinceTick = 0
    ns.SafeCall(Tick)
end)
