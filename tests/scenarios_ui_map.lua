-- The interface map (tests/ui_map.lua) against the addon: every route a node
-- names resolves to a declared page, tab, view, Settings section, floating
-- piece or command; Nav.Go reaches every page, tab and view; Home, Go to and
-- the minimap button route where the map says.
local scenarios, T = ...
local check, boot, slash = T.check, T.boot, T.slash

local function loadMap()
    local dir = (EXTRA_SCENARIO_FILES[1] or ""):match("^(.*)/[^/]*$") or (ADDON_DIR .. "/tests")
    return assert(loadfile(dir .. "/ui_map.lua"))()
end

local function plain(text) return (tostring(text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end

-- The words of a command node's path ("type /talod fish now|spots") as typed:
-- placeholders dropped, the first of each choice.
local function Typed(ns, path)
    local text = path:gsub("^type%s+", "")
    text = text:match("^(.-)%s+·%s+") or text
    local prefix = ns.Cmd.PREFIX
    if text:sub(1, #prefix) ~= prefix then return nil, text end
    local words = {}
    for w in text:sub(#prefix + 1):gmatch("%S+") do
        if w:find("^[<%[]") then break end
        words[#words + 1] = w:match("^([^|]+)") or w
    end
    return table.concat(words, " ")
end

local MACROS = { AHNextButton = true, FishingLureButton = true, FishingSwapButton = true }

-- page[/tab][#view] against Nav.PAGES (exact keys, no old keys).
local function ResolvePage(Nav, route)
    local base, view = route:match("^([^#]*)#?(.*)$")
    local pk, tk = base:match("^([^/]+)/?(.*)$")
    local page
    for _, p in ipairs(Nav.PAGES) do if p.key == pk then page = p end end
    if not page then return false, "no page " .. tostring(pk) end
    local holder = page
    if tk ~= "" then
        local tab
        for _, t in ipairs(page.tabs) do if t.key == tk then tab = t end end
        if not tab then return false, "no tab " .. tk .. " on " .. pk end
        holder = tab
    end
    if view ~= "" and not Nav.View(holder, view) then return false, "no view " .. view .. " in " .. base end
    return true
end

local function Resolve(ns, map, route, node)
    local Nav = ns.Nav
    if route == "command" then
        local path = node and node.path or ""
        if path == "Slash command" then return true end
        local click = path:match("^type /click (%S+)")
        if click then
            return click:sub(1, #ns.FRAME) == ns.FRAME and MACROS[click:sub(#ns.FRAME + 1)] or false, "macro " .. click
        end
        local typed, raw = Typed(ns, path)
        if not typed then return false, "not a command: " .. tostring(raw) end
        local id = ns.Cmd.Parse(typed)
        return id ~= nil, "command does not parse: " .. typed
    end
    local section = route:match("^settings/([%w_]+)")
    if section then
        local inNav, inMap = false, false
        for _, s in ipairs(Nav.SECTIONS) do if s.key == section then inNav = true end end
        for _, s in ipairs(map.sections) do if s.key == section then inMap = true end end
        return inNav and inMap, "no settings section " .. section
    end
    local float = route:match("^float/(%w+)$")
    if float then return Nav.FLOATING[float] ~= nil, "no floating piece " .. float end
    if Nav.SURFACES[route] then return true end
    return ResolvePage(Nav, route)
end

-- (a) Every route in the map resolves.
scenarios.ui_map_routes = function()
    local ns = boot(11509)
    local Nav, map = ns.Nav, loadMap()

    -- The page list is the map's, in order, with the same tabs and views.
    local i = 0
    for _, group in ipairs(map.nav) do
        for _, mp in ipairs(group.pages) do
            i = i + 1
            local page = Nav.PAGES[i]
            check(page and page.key == mp.key, "page " .. i .. ": " .. tostring(page and page.key) .. " = " .. mp.key)
            local want = group.group == "TALOD" and ns.NAME or group.group
            check(page.group == want, mp.key .. ": section " .. tostring(page.group))
            check(page.label == mp.label and page.glyph == mp.icon, mp.key .. ": label and glyph")
            check(#page.tabs == #mp.tabs, mp.key .. ": tab count")
            for n, label in ipairs(mp.tabs) do
                check(page.tabs[n].label == label, mp.key .. ": tab " .. n .. " " .. tostring(page.tabs[n].label))
                for k, v in ipairs(mp.views[label] or {}) do
                    check(page.tabs[n].views and page.tabs[n].views[k] == v, mp.key .. "/" .. label .. ": view " .. v)
                end
            end
            check(page.module ~= nil or page.key == "home", mp.key .. ": module named")
        end
    end
    check(i == #Nav.PAGES and i == 13, "13 pages")
    for _, page in ipairs(Nav.PAGES) do
        check(ns.Style.GLYPHS and page.glyph, page.key .. ": glyph")
        local known = false
        for _, g in ipairs(ns.Style.GLYPHS) do if g == page.glyph then known = true end end
        check(known, page.key .. ": glyph in the atlas")
    end
    -- Modules per the build contract.
    local MODULES = { enemies = "EnemiesUI", fishing = "FishingUI", groups = "GroupsUI", gear = "GearUI",
        prof = "ProfessionsUI", gold = "EconomyUI", ah = "MarketUI", recruit = "RecruitUI", members = "MembersUI",
        audit = "AuditUI", settings = "Options", about = "AboutUI" }
    for key, m in pairs(MODULES) do check(Nav.Page(key).module == m, key .. " module " .. m) end

    -- Sections: the 13 of the Settings page.
    check(#Nav.SECTIONS == #map.sections, "section count")
    for n, s in ipairs(map.sections) do check(Nav.SECTIONS[n].key == s.key, "section " .. s.key) end

    -- Every location and every node.
    for route, loc in pairs(map.locations) do
        local ok, why = Resolve(ns, map, route, { path = "Slash command" })
        check(ok, "location " .. route .. ": " .. tostring(why))
        if loc.kind == "page" or loc.kind == "tab" then
            local pk, tk = route:match("^([^/#]+)/?([^#]*)")
            local where = Nav.Location(pk, tk ~= "" and tk or nil)
            check(where ~= "", "location label for " .. route)
        end
    end
    local n = 0
    for id, node in pairs(map.nodes) do
        local ok, why = Resolve(ns, map, node.new, node)
        check(ok, "node " .. id .. " -> " .. node.new .. ": " .. tostring(why))
        n = n + 1
    end
    check(n > 1000, "nodes checked: " .. n)
    -- Old page keys map to their pages.
    for old, want in pairs({ character = "gear", economy = "gold", market = "ah", desk = "ah", guild = "recruit",
        changelog = "about", credits = "about" }) do
        check(Nav.Page(old) and Nav.Page(old).key == want, "old key " .. old)
    end
end

-- (b) Nav.Go reaches every page, tab and view, and remembers the last tab.
scenarios.ui_map_go = function()
    local ns = boot(11509)
    local Nav = ns.Nav
    MOCK.prints = {}
    for _, page in ipairs(Nav.PAGES) do
        check(Nav.Go(page.key), "go " .. page.key)
        for _, tab in ipairs(page.tabs) do
            check(Nav.Go(page.key, tab.key), "go " .. page.key .. "/" .. tab.key)
            check(Nav.LastTab(page.key) == tab.key, "last tab " .. page.key .. "/" .. tab.key)
            if not (page.key == "about" and tab.key == "commands") then
                check(Nav.Current() ~= nil, "a window for " .. page.key .. "/" .. tab.key)
            end
            for _, v in ipairs(tab.views or {}) do
                check(Nav.Go(page.key, tab.key, v), "go " .. page.key .. "/" .. tab.key .. "#" .. v)
                check(Nav.LastView(page.key, tab.key) == v, "last view " .. v)
            end
        end
        for _, v in ipairs(page.views or {}) do
            check(Nav.Go(page.key, nil, v), "go " .. page.key .. "#" .. v)
        end
    end
    check(Nav.Go("about", "commands") and ns.AboutUI.IsShown("commands"), "about/commands opens the Commands tab")
    -- Labels work as well as keys; the page alone opens its last tab.
    local MS = ns.MarketUI.state
    Nav.Go("ah", "My auctions", "by item")
    local first = MS.view
    Nav.Go("ah", "Buy", "Bids")
    check(first == "sellthrough" and MS.view == "bids", "labels and short views: " .. tostring(first) .. "," .. tostring(MS.view))
    Nav.Go("ah", "prices")
    Nav.Go("ah", "Buy")
    check(MS.view == "bids", "a tab alone: its last view")
    Nav.Go("ah")
    check(MS.view == "bids", "the page alone: last tab and view")
    -- Nav.Go(): where you left it.
    Nav.Go("gold", "trades")
    Nav.CloseAll()
    check(Nav.Go() and TALODEconomyWindow:IsShown() and Nav.LastTab("gold") == "trades", "Nav.Go() reopens the last page")
    check(TALODDB.navLast == "gold", "last page saved")

    -- /talod help prints the list once.
    MOCK.prints = {}
    slash("help")
    local heads = 0
    for _, line in ipairs(MOCK.prints) do if line:find("^Enemies:") then heads = heads + 1 end end
    check(heads == 1, "help printed once: " .. heads)

    -- A page module's ShowPage replaces the fallback; PageHidden leaves it out.
    local got
    ns.RecruitUI = {
        ShowPage = function(tab, view, arg) got = { tab, view, arg } end,
        PageStatus = function() return { text = "3 new", count = "3", tone = "accent", tab = "invited" } end,
    }
    check(Nav.Go("recruit", "Invited", nil, "x") and got[1] == "invited" and got[3] == "x", "ShowPage called with the tab key")
    Nav.ShowHome()
    local rail = TALODMainMenu.navRail
    Nav.RefreshHome()
    check(rail.buttons.recruit.tag:IsShown() and rail.buttons.recruit.tag:GetText() == "3", "count tag from PageStatus")
    TALODMainMenu.lineByKey.recruit:Fire("OnClick", "LeftButton")
    check(got[1] == "invited", "Home line opens the tab its status is about")
    ns.RecruitUI.PageHidden = function() return true end
    Nav.ShowHome()
    check(not rail.buttons.recruit:IsShown() and not TALODMainMenu.lineByKey.recruit:IsShown(), "hidden page left out")
    got = nil
    check(Nav.Go("recruit") and got, "a hidden page still opens when asked for")
    for _, page in ipairs(Nav.Pages()) do check(page.key ~= "recruit", "hidden page not listed") end
end

-- (c) Home: a line per page, On screen switches (combat waits), the notice.
scenarios.ui_map_home = function()
    -- In a guild with the invite right: Recruit has its line.
    MOCK.SetGuild()
    local ns = boot(11509, { db = { welcomeShown = true } })
    local Nav = ns.Nav
    local binds = {}
    ns.Options.Bind = function(key, kind, where) binds[#binds + 1] = key .. "|" .. kind .. "|" .. where end
    slash("home")
    local home = TALODMainMenu
    check(home and home:IsShown(), "Home opens")
    for key, line in pairs(home.lineByKey) do
        check(line:IsShown() and (line.status:GetText() or "") ~= "", "line " .. key .. " shows")
    end
    check(plain(home.lineByKey.enemies.status:GetText()):find("PvP off", 1, true), "enemy line: flag")
    check(plain(home.lineByKey.gold.status:GetText()):find("Today", 1, true), "gold line")
    -- Nothing waiting: the page's description.
    check(ns.RecruitUI.PageStatus() ~= nil or plain(home.lineByKey.recruit.status:GetText()):find(Nav.Page("recruit").desc, 1, true),
        "recruit line")

    -- Quick switches bound once, only declared ones (and the minimap button's).
    local map = loadMap()
    for _, b in ipairs(binds) do
        local key, kind, where = b:match("^([^|]+)|([^|]+)|(.+)$")
        check(kind == "quick" and where == "home" and (map.quick[key] or key == "minimapButton"), "declared quick switch: " .. b)
    end
    for _, key in ipairs({ "alertsEnabled", "panelShown", "flagIndicator", "fishHud", "guildMiniShown", "ahHelper", "minimapButton" }) do
        local found = false
        for _, b in ipairs(binds) do if b == key .. "|quick|home" then found = true end end
        check(found, "bound: " .. key)
    end

    -- Mute alerts.
    local alerts = TALODDB.alertsEnabled
    home.mute:Fire("OnClick", "LeftButton")
    check(TALODDB.alertsEnabled == not alerts, "mute alerts")
    home.mute:Fire("OnClick", "LeftButton")

    -- A switch for a piece with secure buttons waits for the end of combat.
    local shown = TALODDB.panelShown
    MOCK.lockdown = true
    home.pieces.panel.switch:Fire("OnClick", "LeftButton")
    check(TALODDB.panelShown == shown and Nav.PiecePending("panel") == not shown, "panel waits in combat")
    check(home.pieces.panel.state:GetText():find("after combat", 1, true), "says it waits")
    local flag = TALODDB.flagIndicator
    home.pieces.flag.switch:Fire("OnClick", "LeftButton")
    check(TALODDB.flagIndicator == not flag, "flag indicator switches in combat")
    MOCK.lockdown = false
    MOCK.FireEvent("PLAYER_REGEN_ENABLED")
    check(TALODDB.panelShown == not shown and Nav.PiecePending("panel") == nil, "applied after combat")
    -- Mini window, scan panel, minimap button.
    home.pieces.mini.switch:Fire("OnClick", "LeftButton")
    check(TALODDB.guildMiniShown == true and TALODGuildMini and TALODGuildMini:IsShown(), "mini window shown")
    home.pieces.mini.switch:Fire("OnClick", "LeftButton")
    check(TALODDB.guildMiniShown == false and not TALODGuildMini:IsShown(), "mini window hidden")
    home.pieces.scan.switch:Fire("OnClick", "LeftButton")
    check(TALODDB.ahHelper == false, "scan panel off")
    -- Craft tracker: nothing tracked, the switch stays off.
    home.pieces.tracker.switch:Fire("OnClick", "LeftButton")
    check(not home.pieces.tracker.switch:GetOn() and home.pieces.tracker.state:GetText() == "nothing tracked", "tracker: nothing tracked")

    -- The pages-moved notice, until dismissed.
    check(home.notice:IsShown(), "pages moved notice after an update")
    check(plain(home.notice.blocks[1].text:GetText()):find("Market, Auction desk", 1, true), "lists old names")
    home.notice.buttons[2]:Fire("OnClick", "LeftButton")
    check(not home.notice:IsShown() and TALODDB.navMovedSeen == true, "dismissed for good")
    home:Hide()
    Nav.ShowHome()
    check(not home.notice:IsShown(), "stays dismissed")
end

scenarios.ui_map_home_fresh = function()
    local ns = boot(11509)
    ns.Nav.ShowHome()
    check(not TALODMainMenu.notice:IsShown() and TALODDB.navMovedSeen == true, "a first install has nothing that moved")
end

-- Every unit read secret: the enemy line says "?" and "PvP: ?", no number,
-- no safe tone; the rail's count tag is the unknown "?".
scenarios.ui_map_home_secret = function()
    local ns = boot(16001, { secrets = true })
    MOCK.secretMode = true
    MOCK.secretRange = true
    local saved = UnitIsPVP
    UnitIsPVP = nil
    T.plateAdd("nameplate1", MOCK.Enemy({ level = 20, health = 900, healthMax = 2000,
        secret = { health = true, healthMax = true, combat = true, pvp = true, enemy = true, canAttack = true, reaction = true } }))
    ns.Nav.ShowHome()
    local text = TALODMainMenu.lineByKey.enemies.status:GetText()
    local unknown = ns.ColorCode("unknown")
    check(text:find(unknown .. "PvP: ?", 1, true), "PvP: ? in the unknown tone: " .. text)
    check(text:find(unknown .. "? hostility hidden", 1, true), "hostility hidden: " .. text)
    check(text:find(unknown .. "? yd", 1, true), "range unknown: " .. text)
    check(not plain(text):find("%d"), "no number: " .. plain(text))
    check(not text:find(ns.ColorCode("safe"), 1, true), "no safe tone")
    local tag = TALODMainMenu.navRail.buttons.enemies.tag
    check(tag:IsShown() and tag:GetText() == "?" and tag.tone == "unknown", "rail tag is the unknown ?")
    UnitIsPVP = saved
end

-- (d) Go to: old names, tabs, settings, commands (copied, never run).
scenarios.ui_map_goto = function()
    MOCK.SetGuild()
    local ns = boot(11509)
    local Nav = ns.Nav
    -- One exact match goes there.
    local _, went = Nav.GoTo("Market")
    check(went and went.kind == "Was" and Nav.CurrentPage() == "ah", "Market -> Auction House")
    _, went = Nav.GoTo("replies")
    check(went and Nav.CurrentPage() == "recruit" and Nav.LastTab("recruit") == "invited",
        "replies -> Recruit > Invited")
    check(went.path:find("Recruit › Invited", 1, true), "path names the new place: " .. went.path)
    slash("find sell-through")
    check(Nav.LastTab("ah") == "mine" and Nav.LastView("ah", "mine") == "By item", "/talod find: one exact match opens it")

    -- A setting label (from Settings' own list).
    ns.Options.SETTINGS = ns.Options.SETTINGS or { { key = "fishHud", label = "Show the fishing HUD", home = "settings/fishing" } }
    local opened
    ns.Options.OpenSection = function(section, search) opened = { section, search } end
    local label
    for _, row in ipairs(ns.Options.SETTINGS) do if row.key == "fishHud" then label = row.label end end
    local hit
    for _, e in ipairs(Nav.Find(label)) do if e.kind == "Setting" and e.key == "fishHud" then hit = e end end
    check(hit and hit.path:find("Fishing", 1, true), "setting found: " .. tostring(label))
    Nav.Pick(hit)
    check(opened and opened[1] == "fishing", "setting opens its section")

    -- A command: shown and copied, never run.
    TALODDB.errorLog = { { message = "x", count = 1 } }
    local cmd
    for _, e in ipairs(Nav.Find("debug errors")) do if e.kind == "Command" then cmd = e break end end
    check(cmd and cmd.label:find("debug errors", 1, true), "command found")
    MOCK.popup, MOCK.popupData = nil, nil
    Nav.Pick(cmd)
    check(MOCK.popup == "TALOD_COPY" and MOCK.popupData == cmd.label, "command copied")
    check(#TALODDB.errorLog == 1, "command not run")
    TALODDB.errorLog = {}

    -- The palette: several matches, arrows, Enter.
    local p = Nav.OpenGoTo("crafting")
    check(p:IsShown() and p.results[1]:IsShown() and p.results[2]:IsShown(), "results listed")
    check(plain(p.results[1].label:GetText()) == "Crafting" or plain(p.results[1].label:GetText()):find("Crafting"), "match first")
    p.box:Fire("OnArrowPressed", "DOWN")
    check(p.selected == 2 and p.results[2].sel:IsShown(), "down moves the selection")
    local entry = p.found[2]
    p.box:Fire("OnEnterPressed")
    check(not p:IsShown(), "Enter goes and closes")
    check(Nav.LastPage() == entry.page or entry.kind == "Command" or entry.kind == "Setting" or entry.kind == "Section",
        "went to the picked entry")
    Nav.OpenGoTo("")
    p.box:Fire("OnEscapePressed")
    check(not p:IsShown(), "Escape closes")
    -- The rail's field opens it.
    Nav.ShowHome()
    TALODMainMenu.navRail.gotoField:Fire("OnClick", "LeftButton")
    check(Nav.GoToShown(), "rail field opens Go to")
    Nav.CloseGoTo()
end

-- (e) Minimap clicks route to the pages of the map.
scenarios.ui_map_minimap = function()
    Minimap = CreateFrame("Frame", "Minimap", UIParent)
    Minimap._cx, Minimap._cy = 1000, 700
    local ns = boot(11509)
    local Nav = ns.Nav
    local b = TALODMinimapButton
    local keys = {}
    function IsShiftKeyDown() return keys.shift end
    function IsAltKeyDown() return keys.alt end
    function IsControlKeyDown() return keys.ctrl end
    local function click(button, mods)
        keys = mods or {}
        b:Fire("OnClick", button)
        keys = {}
    end
    click("LeftButton")
    check(Nav.MenuShown(), "left-click: Home the first time")
    click("LeftButton", { shift = true })
    check(Nav.CurrentPage() == "gold", "shift: Gold")
    click("LeftButton", { alt = true })
    check(Nav.CurrentPage() == "ah", "alt: Auction House")
    click("RightButton")
    check(Nav.CurrentPage() == "settings", "right: Settings")
    click("RightButton")
    check(Nav.Current() == nil, "right again: closed")
    click("RightButton", { shift = true })
    check(Nav.CurrentPage() == "recruit", "shift-right: Recruit by default")
    local asked = {}
    ns.GuildUI.Show = function(v) asked[#asked + 1] = v end
    Nav.Go("members", "log")
    Nav.CloseAll()
    click("RightButton", { shift = true })
    check(asked[#asked] == "log", "shift-right: the Guild page used last (Members, on its last tab)")
    Nav.CloseAll()
    click("LeftButton")
    check(asked[#asked] == "log", "left-click: where you left it")
    -- Ctrl: the panel, after combat when in combat.
    local shown = TALODDB.panelShown
    click("LeftButton", { ctrl = true })
    check(TALODDB.panelShown == not shown, "ctrl: panel toggled")
    MOCK.lockdown = true
    click("LeftButton", { ctrl = true })
    check(TALODDB.panelShown == not shown and T.printed("when combat ends"), "ctrl in combat waits")
    MOCK.lockdown = false
    MOCK.FireEvent("PLAYER_REGEN_ENABLED")
    check(TALODDB.panelShown == shown, "applied after combat")
    b:Fire("OnEnter")
    check(GameTooltip:IsShown(), "tooltip")
    -- Addon compartment: Home.
    Nav.CloseAll()
    TALOD_OnAddonCompartmentClick()
    check(Nav.MenuShown(), "compartment opens Home")
end

-- (c) One home per setting. After every page, tab and view has been built,
-- Home and Settings: each row of the map has exactly one binding that is not a
-- quick switch, at its home (preferences in their Settings section, tool
-- options on their page, consent on Members > Sharing). Quick switches only
-- for the declared keys, plus the minimap button's show/hide switch on Home.
local function OneHome(iface)
    MOCK.SetGuild()
    -- A fishing pole in hand, so the fishing HUD builds too.
    local ns = T.fishingSetup(iface)
    local Nav, O = ns.Nav, ns.Options
    for _, page in ipairs(Nav.PAGES) do
        ns.SafeCall(Nav.Go, page.key)
        for _, tab in ipairs(page.tabs) do
            ns.SafeCall(Nav.Go, page.key, tab.key)
            for _, v in ipairs(tab.views or {}) do ns.SafeCall(Nav.Go, page.key, tab.key, v) end
        end
        for _, v in ipairs(page.views or {}) do ns.SafeCall(Nav.Go, page.key, nil, v) end
    end
    Nav.Go("home")
    O.Open()
    -- The floating pieces: panel (built at login), fishing HUD (pole in
    -- hand), mini recruit window, craft tracker, the scan panel at the AH.
    MOCK.Tick(1)
    check(TALODPanel and TALODPanel.floatBar, "panel with its bar")
    check(TALODFishingHUD and TALODFishingHUD.floatBar, "fishing HUD with its bar")
    TALODDB.guildMiniShown = true
    ns.GuildUI.RefreshMini({})
    check(TALODGuildMini and TALODGuildMini.floatBar, "mini window with its bar")
    local _, recipe = next(ns.ProfessionData.recipes)
    ns.CraftTrackUI.Open(recipe)
    check(TALODCraftTrack and TALODCraftTrack.floatBar, "craft tracker with its bar")
    ns.AHHelper.Show()
    check(TALODAHPanel and TALODAHPanel.floatBar, "scan panel with its bar")
    local map = loadMap()
    local bindings = O.Bindings()
    -- Every declared quick switch with a control on a floating piece is
    -- bound there; a floating piece binds nothing else and nothing but quick.
    local FLOAT = { ["float/panel"] = { alertsEnabled = true, panelLocked = true, panelShown = true },
        ["float/hud"] = { fishHudLocked = true, fishHud = true }, ["float/mini"] = { guildMiniShown = true } }
    for where, keys in pairs(FLOAT) do
        for key in pairs(keys) do
            check(map.quick[key] ~= nil, key .. " is a declared quick switch")
            check(bindings[key] and bindings[key][where] == "quick", key .. ": quick switch at " .. where)
        end
    end
    for key, b in pairs(bindings) do
        for where, kind in pairs(b) do
            if where:find("^float/") then
                check(kind == "quick" and FLOAT[where] and FLOAT[where][key], key .. ": bound at " .. where .. " as " .. kind)
            end
        end
    end

    -- Guild pages bind their own options only once they exist.
    local GUILD = { recruit = ns.RecruitUI, members = ns.MembersUI }
    -- Classic Era only: the client's invite needs a second click there.
    -- Statistics are shared only where the client has them (Audit).
    local MAY_BE_ABSENT = { guildDelayedInvite = ns.Guild.WhisperFirst and true or false,
        ["guildShare.stats"] = not (ns.Audit and ns.Audit.Supported and ns.Audit.Supported()) }
    local function AtHome(where, home)
        return where == home or where == home:match("^([^#]*)")
    end
    local checked = 0
    for _, row in ipairs(map.settings) do
        local pageKey = row.home:match("^([^/#]+)")
        local skip = row.type == "internal"
            or (GUILD[pageKey] == nil and (pageKey == "recruit" or pageKey == "members"))
        if not skip then
            for key in (row.key .. " / "):gmatch("(.-) / ") do
                local homes = {}
                for where, kind in pairs(bindings[key] or {}) do
                    if kind ~= "quick" then homes[#homes + 1] = where end
                end
                if not (MAY_BE_ABSENT[key] and #homes == 0) then
                    check(#homes == 1 and AtHome(homes[1], row.home), key .. " (" .. row.type .. "): one home at "
                        .. row.home .. ", got " .. table.concat(homes, ", "))
                    local want = row.type == "preference" and "home" or (row.type == "consent" and "consent" or "tool")
                    check(#homes ~= 1 or bindings[key][homes[1]] == want, key .. ": bound as " .. want)
                end
                checked = checked + 1
            end
        end
    end
    check(checked >= 130, "settings checked: " .. checked)
    for key, b in pairs(bindings) do
        for where, kind in pairs(b) do
            if kind == "quick" then
                check(map.quick[key] ~= nil or (key == "minimapButton" and where == "home"),
                    key .. ": quick switch at " .. where .. " only where declared")
            end
            if where:find("^settings/") then check(kind == "home", key .. ": Settings binds homes only") end
        end
    end
    -- The switches the pages were asked for.
    for key, where in pairs({ fishAutoLoot = "fishing", fishLoudSplash = "fishing", fishHud = "fishing", ahHelper = "ah",
        minimapButton = "home", panelShown = "home", censusEnabled = "enemies/census" }) do
        check(bindings[key] and bindings[key][where] == "quick", key .. ": quick switch at " .. where)
    end
    return ns
end

scenarios.ui_map_one_home = function()
    local ns = OneHome(11509)
    check(ns.RecruitUI and ns.MembersUI, "the guild pages exist")
end

scenarios.ui_map_one_home_forever = function()
    OneHome(16001)
end
