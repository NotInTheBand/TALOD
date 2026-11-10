-- TALOD - navigation: the pages in sections (Nav.PAGES), the page list docked
-- on the left of every main window, one main window at a time (the next one
-- opens where the last one stood), Home, and Go to.
--
-- A page is opened with Nav.Go(page, tab, view, arg). A page's module opens
-- it with M.ShowPage(tab, view, arg) once it has one; until then the window
-- that holds that content today opens (FALLBACK below). M.PageStatus() ->
-- { text, tone, count, tab, view, age } feeds the Home line and the count tag
-- in the list; M.PageHidden() -> true leaves the page out (permissions).
--
-- A window joins with Style.Window(name, title, nil, nil, { nav = key }). The
-- rail sits outside the window's own rect, so no window's layout had to
-- change. Every main window has the same size (navSize, set with the grip in
-- the bottom-right corner), so switching pages never changes the size: a
-- window's layout must follow its edges, not a fixed width.
-- Side panels (Auction House helper, report window, guild mini window, HUD)
-- are not main windows and stay open alongside.

local ADDON_NAME, ns = ...
local Style = ns.Style
local COLORS, HEX = Style.COLORS, Style.HEX
local S = ns.Secret

local Nav = {}
ns.Nav = Nav

local RAIL_WIDTH = 164
Nav.RAIL_WIDTH = RAIL_WIDTH
local ROW_HEIGHT = 24

local function db() return ns.DB() end

-- The shared size of the main windows. MIN_SIZE is the narrowest the widest
-- fixed-width pane (Guild Recruit's 540 px card + a list beside it) still fits.
Nav.DEFAULT_SIZE = { 940, 620 }
Nav.MIN_SIZE = { 860, 520 }

function Nav.Size()
    local s = db() and db().navSize
    local w, h = Nav.DEFAULT_SIZE[1], Nav.DEFAULT_SIZE[2]
    if type(s) == "table" and tonumber(s[1]) and tonumber(s[2]) then w, h = tonumber(s[1]), tonumber(s[2]) end
    -- A size saved on a bigger screen (or UI scale) still fits this one.
    local maxW, maxH = UIParent:GetWidth(), UIParent:GetHeight()
    if maxW and maxW > 0 then w = math.min(w, maxW - RAIL_WIDTH) end
    if maxH and maxH > 0 then h = math.min(h, maxH) end
    return math.max(Nav.MIN_SIZE[1], w), math.max(Nav.MIN_SIZE[2], h)
end

local function ApplySize(f)
    local w, h = Nav.Size()
    if f:GetWidth() ~= w or f:GetHeight() ~= h then f:SetSize(w, h) end
end

-- Runs fn, logs an error the way every other caught error is logged, and
-- returns fn's first value (nil after an error).
local function Try(fn, ...)
    local out
    local args, n = { ... }, select("#", ...)
    ns.SafeCall(function() out = fn(unpack(args, 1, n)) end)
    return out
end

-- Shared below: the open main window, Home, the rail's redraw.
local current, home, RefreshRail

local function InCombat()
    if InCombatLockdown and InCombatLockdown() then return true end
    return ns.InCombat and ns.InCombat() or false
end

---------------------------------------------------------------------------
-- Pages
---------------------------------------------------------------------------
-- tabs: { key (the part after the slash in a route, e.g. ah/mine), label,
-- desc (tooltip), views (labels of the view switch) }. page.views: views of a
-- page without tabs (Audit's filters and detail pane). section: the page's
-- part of the Settings page.
local function Tab(key, label, desc, views) return { key = key, label = label, desc = desc, views = views } end

local PAGES = {
    { key = "home", label = "Home", group = "", glyph = "home", section = "general",
        desc = "What needs you now on every page, and everything " .. ns.NAME .. " may put on your screen.", tabs = {} },

    { key = "enemies", label = "Enemies", group = "World", glyph = "swords", module = "EnemiesUI", section = "enemies",
        desc = "Enemy players you met: the journal, your kill-on-sight and avoid lists, notes, and the census.",
        tabs = {
            Tab("journal", "Journal", "recent sightings, and what the journal knows of a player"),
            Tab("lists", "Lists", "kill on sight and avoid"),
            Tab("census", "Census", "everyone seen, for the heat maps"),
        } },
    { key = "fishing", label = "Fishing", group = "World", glyph = "fish", module = "FishingUI", section = "fishing",
        desc = "Every cast logged: the best spots for your skill, gold per hour, rare fish still to catch, and the HUD.",
        tabs = {
            Tab("now", "Now", "this session and this spot"),
            Tab("spots", "Spots", "spots ranked by gold, catch rate or safety"),
            Tab("map", "Map", "heat map of where you fished"),
            Tab("log", "Log", "every cast and encounter; each trip as a session", { "Casts and encounters", "Sessions" }),
            Tab("goals", "Goals", "rare and quest fish, timed catches"),
        } },
    { key = "groups", label = "Groups", group = "World", glyph = "people", module = "GroupsUI", section = "groups",
        desc = "Every party and raid you were in: who was there, where, for how long, deaths, the group's chat and loot.",
        tabs = {
            Tab("now", "Now", "the group you are in, live"),
            Tab("history", "History", "past parties and raids; a row opens one group", { "Group" }),
        } },

    { key = "gear", label = "Gear", group = "Character", glyph = "armor", module = "GearUI", section = "gear",
        desc = "What you wore and what each change did to your stats.",
        tabs = {
            Tab("gear", "Gear", "your gear now beside an earlier set"),
            Tab("enhance", "Enhance", "enchants that fit each item, and their reagents"),
            Tab("ledger", "Ledger", "every change with its measured effect; new items", { "Changes", "New items" }),
            Tab("progress", "Progress", "your stats level by level"),
        } },
    { key = "prof", label = "Professions", group = "Character", glyph = "anvil", module = "ProfessionsUI", section = "professions",
        desc = "Level up cheaply, craft for profit, your skills and what you made. The craft tracker opens from here.",
        tabs = {
            Tab("plan", "Plan", "cheapest path to the next skill points"),
            Tab("profit", "Profit", "material cost against selling price"),
            Tab("skills", "Skills", "skill-ups, training and ranks"),
            Tab("log", "Log", "everything you made, and when"),
        } },

    { key = "gold", label = "Gold", group = "Trade", glyph = "coins", module = "EconomyUI", section = "gold",
        desc = "Where your gold comes from and where it goes, for one character or all.",
        tabs = {
            Tab("overview", "Overview", "totals by source and by day"),
            Tab("transactions", "Transactions", "every money change and the window it came from"),
            Tab("trades", "Trades", "trades with other players and between your characters"),
        } },
    { key = "ah", label = "Auction House", group = "Trade", glyph = "gavel", module = "MarketUI", section = "ah",
        desc = "What needs you at the Auction House, what to buy, what to sell, your auctions and every price you saw.",
        tabs = {
            Tab("today", "Today", "your listings, best resets, deals"),
            Tab("buy", "Buy", "deals under the usual price; cheap bids", { "Deals", "Bids" }),
            Tab("sell", "Sell", "your bags: Auction House or vendor"),
            Tab("mine", "My auctions", "each auction: lowest or undercut; what sells", { "Auctions", "By item" }),
            Tab("prices", "Prices", "an item's price, supply, graph and control plans"),
        } },

    { key = "recruit", label = "Recruit", group = "Guild", glyph = "horn", module = "RecruitUI", section = "guild",
        desc = "Find players without a guild, follow up on who you asked, and see what came of it.",
        tabs = {
            Tab("find", "Find", "players without a guild you have seen"),
            Tab("invited", "Invited", "who you asked, their replies, who joined"),
            Tab("results", "Results", "who brought whom, and who stayed"),
        } },
    { key = "members", label = "Members", group = "Guild", glyph = "banner", module = "MembersUI", section = "guild",
        desc = "Your guild's people: the roster, promotions, the log, and what you share with officers.",
        tabs = {
            Tab("roster", "Roster", "members, last online, activity, what they share", { "Basics", "Activity", "Shared" }),
            Tab("promotions", "Promotions", "members your rules say are due"),
            Tab("log", "Log", "joins, leaves, kicks and rank changes"),
            Tab("sharing", "Sharing", "what you share with officers"),
        } },
    { key = "audit", label = "Audit", group = "Guild", glyph = "scale", module = "AuditUI", section = "audit",
        desc = "Gold and activity from the game's statistics, for you and members who share: flags gold that looks bought.",
        tabs = {}, views = { "Guild", "Flagged", "Everyone", "Ledger", "History" } },

    { key = "settings", label = "Settings", group = ns.NAME, glyph = "gear", module = "Options", section = "general",
        desc = "Every preference on one page: the panel, alerts, safety, and each page's options.", tabs = {} },
    { key = "about", label = "About", group = ns.NAME, glyph = "info", module = "AboutUI",
        desc = "What changed in each version, every command, and who made " .. ns.NAME .. ".",
        tabs = {
            Tab("changelog", "What's new", "each version's notes, ready to copy"),
            Tab("commands", "Commands", "every command and its short forms"),
            Tab("credits", "Credits", "author, Discord, how to send gold"),
        } },
}
Nav.PAGES = PAGES

-- Sections of the page list, in order. The last one (the addon's own pages)
-- has no heading: a divider sets it apart.
Nav.GROUPS = { "", "World", "Character", "Trade", "Guild", ns.NAME }

-- The Settings page's sections (route settings/<key>).
Nav.SECTIONS = ns.Cmd.SECTIONS

-- What a route may name besides pages and Settings sections: the floating
-- pieces (float/<key>) and the other surfaces.
Nav.FLOATING = { panel = "Enemies nearby panel", flag = "PvP flag indicator", hud = "Fishing HUD",
    mini = "Mini recruit window", tracker = "Craft tracker", scan = "Auction House scan panel",
    notice = "Recruit-reply notice", update = "Update notice", copy = "Copy box", report = "Report window" }
Nav.SURFACES = { minimap = true, rail = true, home = true, passive = true, ["passive/tooltip"] = true,
    ["game/binding"] = true, ["game/inspect"] = true, ["game/options"] = true, external = true, command = true }

local byKey = {}
for _, page in ipairs(PAGES) do
    byKey[page.key] = page
    page.hidden = function() return Nav.Hidden(page) end
end

-- Old page keys (windows that still attach with them, old callers of Nav.Open).
local OLD_KEYS = {
    character = { page = "gear" }, economy = { page = "gold" },
    market = { page = "ah", tab = "prices" }, desk = { page = "ah", tab = "today" },
    guild = { page = "recruit" }, changelog = { page = "about", tab = "changelog" },
    credits = { page = "about", tab = "credits" }, menu = { page = "home" },
}
Nav.OLD_KEYS = OLD_KEYS

local function Norm(s) return (tostring(s or ""):lower():gsub("[^%w]", "")) end

function Nav.Page(key)
    if byKey[key] then return byKey[key] end
    local old = OLD_KEYS[key]
    return old and byKey[old.page] or nil
end

-- A tab of a page by its key or label.
function Nav.Tab(page, tab)
    page = type(page) == "table" and page or Nav.Page(page)
    if not page or tab == nil then return nil end
    local n = Norm(tab)
    for _, t in ipairs(page.tabs or {}) do
        if Norm(t.key) == n or Norm(t.label) == n then return t end
    end
    return nil
end

-- A view label of a tab (or of a page without tabs), by its label or short key.
function Nav.View(holder, view)
    if not holder or view == nil then return nil end
    local n = Norm(view)
    for _, v in ipairs(holder.views or {}) do
        if Norm(v) == n then return v end
    end
    return nil
end

local function Module(page) return page and page.module and ns[page.module] or nil end

function Nav.Hidden(page)
    local M = Module(page)
    if M and type(M.PageHidden) == "function" then return Try(M.PageHidden) and true or false end
    return false
end

-- The pages the list shows (a page its module hides is left out, not greyed).
function Nav.Pages()
    local out = {}
    for _, page in ipairs(PAGES) do
        if not Nav.Hidden(page) then out[#out + 1] = page end
    end
    return out
end

-- "Trade › Auction House › My auctions › By item".
function Nav.Location(pageKey, tabKey, viewKey)
    local page = Nav.Page(pageKey)
    if not page then return "" end
    local parts = {}
    if page.group ~= "" then parts[#parts + 1] = page.group end
    parts[#parts + 1] = page.label
    local tab = Nav.Tab(page, tabKey)
    if tab then parts[#parts + 1] = tab.label end
    local view = Nav.View(tab or page, viewKey)
    if view then parts[#parts + 1] = view end
    return table.concat(parts, " › ")
end

---------------------------------------------------------------------------
-- Status: the page's own PageStatus, else what Navigation reads itself from
-- the modules' existing functions. Every read is guarded.
---------------------------------------------------------------------------
local Tag = Style.TagText
local function Muted(text) return HEX.muted .. text .. "|r" end

local STATUS = {}
local OWN_STATUS = { enemies = true }

-- Unknown stays unknown: a hidden hostility is never counted as no enemy, a
-- hidden range is "? yd", a hidden flag is "PvP: ?".
STATUS.enemies = function()
    local Spotter, Safety = ns.Spotter, ns.Safety
    if not Spotter then return nil end
    local known, hidden, nearest = 0, 0, nil
    for _, e in ipairs(Spotter.Sorted()) do
        if e.unit then
            if e.hostile == true then
                known = known + 1
                nearest = nearest or e
            elseif e.hostile == nil then
                hidden = hidden + 1
                nearest = nearest or e
            end
        end
    end
    local parts = {}
    if known > 0 then parts[#parts + 1] = Tag(known .. " near", "danger") end
    if hidden > 0 then parts[#parts + 1] = Tag("hostility hidden", "unknown") end
    if known == 0 and hidden == 0 then parts[#parts + 1] = Muted("nobody in view") end
    if nearest then
        local name = type(nearest.name) == "string" and nearest.name or "?"
        parts[#parts + 1] = HEX.white .. name .. "|r " .. ns.FormatRange(nearest.lo, nearest.hi)
    end
    local flagged = Safety and Safety.PlayerFlag and Safety.PlayerFlag()
    if flagged == nil then
        parts[#parts + 1] = ns.UnknownText("PvP: ?")
    elseif flagged then
        parts[#parts + 1] = Tag("PvP on", "threshold")
    else
        parts[#parts + 1] = Muted("PvP off")
    end
    local count, tone
    if known > 0 then count, tone = tostring(known), "danger" elseif hidden > 0 then count, tone = "?", "unknown" end
    return { text = table.concat(parts, "  "), count = count, tone = tone, tab = "journal" }
end

STATUS.fishing = function()
    local F = ns.Fishing
    if not F or not F.Session then return nil end
    local s = F.Session()
    if not s then return { text = Muted("No session running"), tab = "log", view = "Sessions" } end
    local text = F.SessionSummary and F.SessionSummary(s) or "Session running"
    return { text = text, tab = "now", age = s.last and ns.FormatAge(time() - s.last) or nil }
end

STATUS.groups = function()
    local G = ns.Groups
    if not G or not G.Current then return nil end
    local s = G.Current()
    if not s then return { text = Muted("Not in a group"), tab = "history" } end
    local n = G.MemberCount and G.MemberCount(s)
    local kind = s.kind == "raid" and "In a raid" or "In a party"
    local minutes = G.Duration and math.floor(G.Duration(s) / 60) or nil
    return { text = kind .. (type(n) == "number" and (" · " .. n .. " players") or "")
        .. (minutes and (" · " .. minutes .. " min") or ""), tab = "now" }
end

STATUS.gold = function()
    local E = ns.Economy
    if not (E and E.ScopeTotals and E.DayStart and E.FormatMoney) then return nil end
    local inc, exp = E.ScopeTotals("all", E.DayStart())
    if type(inc) ~= "number" or type(exp) ~= "number" then return nil end
    return { text = "Today " .. E.FormatMoney(inc - exp, true) .. Muted("  (in " .. E.FormatMoney(inc) .. HEX.muted
        .. ", out " .. E.FormatMoney(exp) .. HEX.muted .. ")"), tab = "overview" }
end

-- From the desk's listings (kept a minute) and the newest full look (a memo
-- on prices): never a walk over every ladder per redraw.
STATUS.ah = function()
    local D, P, Data = ns.AuctionDesk, ns.Prices, ns.Data
    if not (D and D.Listings) then return nil end
    local listings = D.Listings()
    if type(listings) ~= "table" or type(listings.list) ~= "table" then return nil end
    local listed, undercut, overdue = 0, 0, 0
    for _, e in ipairs(listings.list) do
        if e.overdue then overdue = overdue + 1 else
            listed = listed + 1
            if e.standing and e.standing.state == "undercut" then undercut = undercut + 1 end
        end
    end
    local newest = P and P.AllLadders and Data.Memo("nav:ahlook", Data.Key("prices"), function()
        local t = 0
        for _, e in pairs(P.AllLadders()) do
            if type(e.t) == "number" and e.t > t then t = e.t end
        end
        return t
    end)
    local parts = { listed .. " listed" }
    if undercut > 0 then parts[#parts + 1] = Tag(undercut .. " undercut", "bad") end
    if overdue > 0 then parts[#parts + 1] = Muted(overdue .. " ended, no letter yet") end
    local age = (type(newest) == "number" and newest > 0) and ("look " .. ns.FormatAge(time() - newest) .. " ago") or nil
    return { text = table.concat(parts, "  ·  "), tab = undercut > 0 and "mine" or "today", age = age,
        count = undercut > 0 and tostring(undercut) or nil, tone = undercut > 0 and "bad" or nil }
end

STATUS.prof = function()
    local Track = ns.CraftTrack
    if not (Track and Track.Current) then return nil end
    local t = Track.Current()
    if not t then return { text = Muted("No craft tracked"), tab = "profit" } end
    local r = ns.ProfessionData and ns.ProfessionData.recipes and ns.ProfessionData.recipes[t.id]
    local name = r and r.name or "a recipe"
    return { text = "Tracking " .. HEX.white .. name .. "|r" .. ((t.n and t.n > 1) and (" ×" .. t.n) or ""), tab = "profit" }
end

STATUS.recruit = function()
    local G = ns.Guild
    if not (G and G.Unread) then return nil end
    local n = G.Unread()
    if type(n) ~= "number" or n <= 0 then return { text = Muted("No unread replies"), tab = "invited" } end
    return { text = Tag(n .. (n == 1 and " reply" or " replies"), "accent") .. "  unread", tab = "invited",
        count = tostring(n), tone = "accent" }
end

-- { text, tone, count, tab, view, age } or nil.
function Nav.Status(pageKey)
    local page = Nav.Page(pageKey)
    if not page then return nil end
    -- A window built by a background job (Data's warm-up) runs inside a
    -- coroutine: a status read may step a memo there, which cannot yield
    -- through the error guard. The status comes with the next redraw.
    local co, main = coroutine.running()
    if co and not main then return nil end
    local M = Module(page)
    local st
    -- The enemy line also carries your PvP flag, so Home keeps its own reading
    -- there even though the page has a status of its own.
    if M and type(M.PageStatus) == "function" and not OWN_STATUS[page.key] then
        st = Try(M.PageStatus)
    elseif STATUS[page.key] then
        st = Try(STATUS[page.key])
    end
    if type(st) ~= "table" then return nil end
    return st
end

---------------------------------------------------------------------------
-- Going to a page
---------------------------------------------------------------------------
local lastPage                 -- this session
local going                    -- the page Nav.Go is opening (a window that shows meanwhile is that page)
local lastTab, lastView = {}, {}
local lastGuild               -- nil until a guild page is used this session

local function ShowOld(moduleName, view, ...)
    local M = ns[moduleName]
    if not (M and M.Show) then return false end
    M.Show(view, ...)
    return true
end

-- Without the Enemies page: its settings section. Never Options.OpenTab
-- ("Journal" opens the Enemies page, which would land here again).
local function EnemiesSettings()
    local O = ns.Options
    if not O then return false end
    if O.OpenSection then O.OpenSection("enemies") else O.Open() end
    return true
end

local function PrintCommands()
    print("|cff" .. ns.COLOR .. ns.NAME .. "|r commands:")
    for _, line in ipairs(ns.Cmd.HelpLines()) do print(line) end
end

-- Today's window for each page, tab and view (used until the page's module
-- has ShowPage). tab and view are the declared key / label.
local FALLBACK = {
    home = function() Nav.ShowHome() return true end,
    enemies = function() return EnemiesSettings() end,
    fishing = function(tab, view)
        if tab == "log" and view == "Sessions" then return ShowOld("FishingUI", "sessions") end
        return ShowOld("FishingUI", tab or "now")
    end,
    groups = function(tab) return ShowOld("GroupsUI", tab == "history" and "party" or "now") end,
    gear = function(tab, view)
        local v = ({ gear = "snapshots", enhance = "enhance", ledger = "ledger", progress = "progress" })[tab] or "snapshots"
        if tab == "ledger" and view == "New items" then v = "sources" end
        return ShowOld("GearUI", v)
    end,
    prof = function(tab)
        if tab == "profit" then return ShowOld("MarketUI", "crafting") end
        return ShowOld("GearUI", ({ plan = "professions", skills = "skills", log = "crafting" })[tab] or "professions")
    end,
    gold = function(tab) return ShowOld("EconomyUI", tab or "overview") end,
    ah = function(tab, view, arg)
        if tab == "buy" then return ShowOld("MarketUI", view == "Bids" and "bids" or "deals") end
        if tab == "sell" then return ShowOld("MarketUI", "sell") end
        if tab == "mine" then
            if view == "By item" then return ShowOld("MarketUI", "sellthrough") end
            return ShowOld("AuctionDeskUI", "listings")
        end
        if tab == "prices" then return ShowOld("MarketUI", "prices", type(arg) == "string" and arg or nil) end
        return ShowOld("AuctionDeskUI", "overview")
    end,
    recruit = function(tab)
        return ShowOld("GuildUI", ({ find = "recruit", invited = "invited", results = "recruiters" })[tab] or "recruit")
    end,
    members = function(tab, view)
        local v = ({ roster = "roster", promotions = "promote", log = "log", sharing = "sharing" })[tab] or "roster"
        if v == "roster" and view == "Activity" then v = "activity" elseif v == "roster" and view == "Shared" then v = "members" end
        return ShowOld("GuildUI", v)
    end,
    audit = function(_, view)
        return ShowOld("AuditUI", ({ Guild = "members", Flagged = "flags", Everyone = "characters", Ledger = "ledger",
            History = "history" })[view])
    end,
    settings = function(tab)
        if not ns.Options then return false end
        if tab then Style.OpenSettings(tab) else ns.Options.Open() end
        return true
    end,
    about = function(tab, _, arg)
        if tab == "credits" then return ShowOld("Credits") end
        if tab == "commands" then
            -- /talod help printed them already.
            if not (type(arg) == "table" and arg.printed) then PrintCommands() end
            return true
        end
        return ShowOld("Changelog")
    end,
}

-- Opens a page on a tab and view (keys or labels). No page: where you left
-- it (Home the first time). Remembers the last tab and view of each page.
function Nav.Go(pageKey, tabKey, viewKey, arg)
    if pageKey == nil then
        pageKey = lastPage or (db() and db().navLast ~= "" and db().navLast) or "home"
        if not byKey[pageKey] or Nav.Hidden(byKey[pageKey]) then pageKey = "home" end
    end
    local old = OLD_KEYS[pageKey]
    if old then pageKey, tabKey = old.page, tabKey or old.tab end
    -- A hidden page is left out of the lists, but opens when asked for by
    -- name (a word, an old caller): it says itself why it is out of reach.
    local page = byKey[pageKey]
    if not page then return false end

    -- Settings has no tabs: a tab there is a section.
    local tab = Nav.Tab(page, tabKey)
    if not tab and tabKey == nil then tab = Nav.Tab(page, lastTab[page.key]) end
    local holder = tab or page
    local view = Nav.View(holder, viewKey)
    if not view and viewKey == nil then view = Nav.View(holder, lastView[page.key .. "/" .. (tab and tab.key or "")]) end

    lastPage = page.key
    if db() then db().navLast = page.key end
    if tab then lastTab[page.key] = tab.key end
    if view then lastView[page.key .. "/" .. (tab and tab.key or "")] = view end
    if page.key == "recruit" or page.key == "members" then lastGuild = page.key end

    local tKey = tab and tab.key or (page.key == "settings" and tabKey) or nil
    local M = Module(page)
    local ok
    going = page.key
    if M and type(M.ShowPage) == "function" then
        ok = Try(M.ShowPage, tKey, view, arg) ~= false
    else
        local fallback = FALLBACK[page.key]
        ok = fallback and Try(fallback, tKey, view, arg) and true or false
    end
    going = nil
    -- Today's windows hold parts of other pages (Market holds Profit): the
    -- list marks the page that was asked for.
    local cur = Nav.Current()
    if ok and cur and cur.navRail and cur ~= home then
        cur.navRail.key = page.key
        RefreshRail(cur.navRail)
    end
    return ok
end

-- Old callers: old keys open the page that holds that content now.
function Nav.Open(key)
    if not Nav.Page(key) then return false end
    return Nav.Go(key)
end

function Nav.LastTab(pageKey) return lastTab[pageKey] end
function Nav.LastView(pageKey, tabKey) return lastView[pageKey .. "/" .. (tabKey or "")] end
function Nav.LastPage() return lastPage end
-- Recruit the first time, Members for a rank the game does not let invite.
function Nav.LastGuildPage()
    if lastGuild then return lastGuild end
    local G = ns.Guild
    return (G and G.Mine() and not G.Can("invite")) and "members" or "recruit"
end

---------------------------------------------------------------------------
-- One main window at a time
---------------------------------------------------------------------------
local windows = {}   -- [frame] = true

local function SavePosition(f)
    local left, top = f:GetLeft(), f:GetTop()
    if left and top then db().navPos = { math.floor(left + 0.5), math.floor(top + 0.5) } end
end

local function PlaceAt(f, left, top)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
end


-- Called when a main window shows: the one before it closes, and the new one
-- takes its place (top-left corner, so the rail does not jump).
-- built: the window was just made (some are made shown and hidden at once,
-- so that is not a page the player opened).
local function Activate(f, built)
    ApplySize(f)
    if f.navPage and built ~= true and not going then
        lastPage = f.navPage
        if db() then db().navLast = f.navPage end
        if f.navPage == "recruit" or f.navPage == "members" then lastGuild = f.navPage end
    end
    if f.navRail then
        f.navRail.key = going or f.navPage
        RefreshRail(f.navRail)
    end
    if current == f then return end
    local prev = current
    current = f
    if prev and prev:IsShown() then
        local left, top = prev:GetLeft(), prev:GetTop()
        if left and top then PlaceAt(f, left, top) end
        prev:Hide()
    else
        local pos = db() and db().navPos
        if type(pos) == "table" and pos[1] and pos[2] then PlaceAt(f, pos[1], pos[2]) end
    end
end

function Nav.Current() return current and current:IsShown() and current or nil end

-- The page the open window shows (Market opened as Professions > Profit is prof).
function Nav.CurrentPage()
    local f = Nav.Current()
    return f and (f.navRail and f.navRail.key or f.navPage) or nil
end

function Nav.CloseAll()
    for f in pairs(windows) do
        if f:IsShown() then f:Hide() end
    end
end

---------------------------------------------------------------------------
-- The rail
---------------------------------------------------------------------------
-- The page's description, then what each of its tabs shows.
function Nav.PageTip(owner, page, anchor)
    local t = ns.Tooltip.Open(owner, anchor)
    t:Title(page.label)
    t:Line(page.desc)
    if page.tabs and #page.tabs > 0 then
        t:Blank()
        for _, tab in ipairs(page.tabs) do t:Pair(tab.label, tab.desc, "muted") end
    end
    return t:Show()
end

local function RailButton(rail, page)
    local b = CreateFrame("Button", nil, rail)
    b:SetSize(RAIL_WIDTH - 12, ROW_HEIGHT)
    b.bg = Style.Texture(b, "BACKGROUND", COLORS.clear)
    b.bg:SetAllPoints()
    b.accent = Style.Texture(b, "ARTWORK", COLORS.accent)
    b.accent:SetWidth(2)
    b.accent:SetPoint("TOPLEFT")
    b.accent:SetPoint("BOTTOMLEFT")
    b.glyph = Style.Glyph(b, page.glyph, 14, "t3")
    b.glyph:SetPoint("LEFT", 10, 0)
    b.text = Style.Text(b, "body")
    b.text:SetPoint("LEFT", 32, 0)
    b.text:SetPoint("RIGHT", -30, 0)
    b.text:SetText(page.label)
    b.tag = Style.Tag(b)
    b.tag:SetPoint("RIGHT", -4, 0)
    b.tag:Hide()
    local hl = Style.Texture(b, "HIGHLIGHT", COLORS.hover)
    hl:SetAllPoints()
    b:SetScript("OnClick", function() Nav.Go(page.key) end)
    b:SetScript("OnEnter", function(self) Nav.PageTip(self, page, "ANCHOR_RIGHT") end)
    b:SetScript("OnLeave", function() ns.Tooltip.Hide() end)
    b.key = page.key
    return b
end

local function MarkSelected(rail, key)
    for k, b in pairs(rail.buttons) do
        local on = k == key
        b.accent:SetShown(on)
        Style.Fill(b.bg, on and COLORS.selected or COLORS.clear)
        local c = on and COLORS.t1 or COLORS.t2
        b.text:SetTextColor(c[1], c[2], c[3])
        b.glyph:SetTone(on and "accent" or "t3")
    end
end

local function CharacterLine()
    local name = S and S.Call(UnitName, "player")
    local realm = S and S.Call(GetRealmName)
    local level = S and UnitLevel and S.Call(UnitLevel, "player")
    local top = type(name) == "string" and name or "?"
    if type(level) == "number" and level > 0 then top = top .. " · " .. level end
    local bottom = type(realm) == "string" and realm or ""
    if ns.FLAVOR_NAME then bottom = bottom ~= "" and (bottom .. " · " .. ns.FLAVOR_NAME) or ns.FLAVOR_NAME end
    return top .. "\n" .. bottom
end

-- Rows top to bottom; pages hidden by their module drop out. Count tags
-- from each page's status.
RefreshRail = function(rail)
    local y = rail.listTop
    local lastGroup
    for _, h in pairs(rail.heads) do h:Hide() end
    rail.divider:Hide()
    for _, page in ipairs(PAGES) do
        local b = rail.buttons[page.key]
        if Nav.Hidden(page) then
            b:Hide()
        else
            if page.group ~= lastGroup then
                lastGroup = page.group
                if page.group == ns.NAME then
                    y = y - 6
                    rail.divider:ClearAllPoints()
                    rail.divider:SetPoint("TOPLEFT", 12, y)
                    rail.divider:SetPoint("TOPRIGHT", -12, y)
                    rail.divider:Show()
                    y = y - 7
                elseif page.group ~= "" then
                    local h = rail.heads[page.group]
                    y = y - 6
                    h:ClearAllPoints()
                    h:SetPoint("TOPLEFT", 14, y)
                    h:Show()
                    y = y - 16
                end
            end
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", 6, y)
            b:Show()
            y = y - ROW_HEIGHT
            local st = Nav.Status(page.key)
            if st and st.count and st.count ~= "" then
                b.tag:Set(st.count, st.tone or "plain", false)
                b.tag:Show()
            else
                b.tag:Hide()
            end
        end
    end
    rail.foot:SetText(CharacterLine())
    MarkSelected(rail, rail.key)
end
Nav.RefreshRail = function(f) if f and f.navRail then RefreshRail(f.navRail) end end

local function BuildRail(f, key)
    local rail = CreateFrame("Frame", nil, f)
    rail.key = key
    rail:SetWidth(RAIL_WIDTH)
    -- 1 px overlap: the rail's right edge and the window's left edge share a line.
    rail:SetPoint("TOPRIGHT", f, "TOPLEFT", 1, 0)
    rail:SetPoint("BOTTOMRIGHT", f, "BOTTOMLEFT", 1, 0)
    rail:EnableMouse(true)
    rail:RegisterForDrag("LeftButton")
    rail:SetScript("OnDragStart", function() f:StartMoving() end)
    rail:SetScript("OnDragStop", function() f:StopMovingOrSizing() SavePosition(f) end)
    rail.surface = Style.Texture(rail, "BACKGROUND", COLORS.rail)
    rail.surface:SetAllPoints()
    Style.Border(rail, COLORS.border)

    -- Brand row, as tall as the window's title bar.
    local barH = Style.M.titleBar or 34
    local band = Style.Texture(rail, "BACKGROUND", COLORS.band)
    band:SetPoint("TOPLEFT", 1, -1)
    band:SetPoint("TOPRIGHT", -1, -1)
    band:SetHeight(barH - 1)
    rail.icon = rail:CreateTexture(nil, "ARTWORK")
    rail.icon:SetTexture(ns.TEX.icon64)
    rail.icon:SetSize(16, 16)
    rail.icon:SetPoint("LEFT", rail, "TOPLEFT", 10, -barH / 2)
    rail.title = Style.Text(rail, "title")
    rail.title:SetPoint("LEFT", rail.icon, "RIGHT", 6, 0)
    rail.title:SetText(ns.TITLE)
    rail.version = Style.Text(rail, "label", "RIGHT")
    rail.version:SetPoint("RIGHT", rail, "TOPRIGHT", -10, -barH / 2)
    rail.version:SetText(tostring(ns.VERSION or "?"))

    -- Go to: a field that opens the palette.
    local go = CreateFrame("Button", nil, rail)
    go:SetHeight(22)
    go:SetPoint("TOPLEFT", 8, -(barH + 8))
    go:SetPoint("TOPRIGHT", -8, -(barH + 8))
    go.bg = Style.Texture(go, "BACKGROUND", COLORS.well)
    go.bg:SetAllPoints()
    Style.Border(go, COLORS.line)
    go.glyph = Style.Glyph(go, "search", 12, "t4")
    go.glyph:SetPoint("LEFT", 7, 0)
    go.text = Style.Text(go, "meta")
    go.text:SetPoint("LEFT", 24, 0)
    go.text:SetText("Go to…")
    go:SetScript("OnClick", function() Nav.OpenGoTo() end)
    go:SetScript("OnEnter", function(self)
        ns.Tooltip.Text(self, { "Go to", "Pages, tabs, settings and commands, and the old page names too." })
    end)
    go:SetScript("OnLeave", function() ns.Tooltip.Hide() end)
    rail.gotoField = go
    rail.listTop = -(barH + 8 + 22 + 6)

    rail.heads = {}
    for _, g in ipairs(Nav.GROUPS) do
        if g ~= "" and g ~= ns.NAME then
            local h = Style.Text(rail, "label")
            h:SetText(string.upper(g))
            local c = COLORS.t4
            h:SetTextColor(c[1], c[2], c[3])
            rail.heads[g] = h
        end
    end
    rail.divider = Style.HLine(rail, COLORS.line)
    rail.buttons = {}
    for _, page in ipairs(PAGES) do rail.buttons[page.key] = RailButton(rail, page) end
    rail.foot = Style.Text(rail, "meta")
    if rail.foot.SetWordWrap then rail.foot:SetWordWrap(true) end
    rail.foot:SetPoint("BOTTOMLEFT", 12, 10)
    rail.foot:SetPoint("BOTTOMRIGHT", -12, 10)
    RefreshRail(rail)
    return rail
end

-- Style.Window calls this for a window made with { nav = key }. An old key
-- (character, market, guild...) marks the page that holds it now.
function Nav.Attach(f, key, title)
    local old = OLD_KEYS[key]
    local pageKey = old and old.page or key
    local page = byKey[pageKey]
    windows[f] = true
    f.navKey = key
    f.navPage = pageKey
    f.navRail = BuildRail(f, pageKey)
    -- The section in brass, the page's name; a window that is one part of a
    -- page today says which part.
    if page then
        if f.section then f.section:SetText(string.upper(page.group ~= "" and page.group or ns.NAME)) end
        local label = page.label
        if title and title ~= "" and title ~= page.label then label = label .. HEX.muted .. "  ·  " .. title .. "|r" end
        if f.title then f.title:SetText(HEX.white .. label .. "|r") end
    elseif f.title then
        f.title:SetText(HEX.white .. (title or "") .. "|r")
    end
    -- Keep the rail on screen as well.
    if f.SetClampRectInsets then f:SetClampRectInsets(-(RAIL_WIDTH - 1), 0, 0, 0) end
    f:HookScript("OnShow", Activate)
    f:HookScript("OnHide", function(self)
        if current == self then current = nil end
        if Nav.CloseGoTo then Nav.CloseGoTo() end
    end)
    f:HookScript("OnDragStop", SavePosition)
    Style.SizeGrip(f, {
        min = Nav.MIN_SIZE,
        onResized = function(w, h)
            db().navSize = { math.floor(w + 0.5), math.floor(h + 0.5) }
            SavePosition(f)
        end,
        onReset = function()
            db().navSize = nil
            ApplySize(f)
            SavePosition(f)
        end,
    })
    -- A new frame starts shown, so its first OnShow never fires.
    if f:IsShown() then Activate(f, true) end
end

---------------------------------------------------------------------------
-- On screen: every floating piece, one switch each
---------------------------------------------------------------------------
local pending = {}   -- [piece key] = on, applied when combat ends

local function TrackerFrame()
    local UI = ns.CraftTrackUI
    return UI and type(UI.frame) == "function" and UI.frame() or nil
end

-- secure: carries secure buttons, so it is shown / hidden out of combat only.
-- setting: the saved key it switches (bound as a quick switch on Home).
local PIECES = {
    { key = "panel", label = "Enemies nearby panel", setting = "panelShown", secure = true, section = "enemies",
        state = function(on) return on and (db().panelLocked and "shown · locked" or "shown") or "hidden" end },
    { key = "flag", label = "PvP flag indicator", setting = "flagIndicator", section = "alerts" },
    { key = "hud", label = "Fishing HUD", setting = "fishHud", secure = true, section = "fishing",
        state = function(on) return on and "while fishing" or "hidden" end },
    { key = "tracker", label = "Craft tracker", section = "professions",
        get = function() return ns.CraftTrackUI and ns.CraftTrackUI.IsShown() or false end,
        set = function(on)
            if on then return ns.CraftTrackUI and ns.CraftTrackUI.Open() or false end
            local f = TrackerFrame()
            if f then f:Hide() end
            return true
        end,
        enabled = function() return ns.CraftTrack and ns.CraftTrack.Current and ns.CraftTrack.Current() ~= nil end,
        state = function(on, enabled) if not enabled then return "nothing tracked" end return on and "shown" or "hidden" end },
    { key = "mini", label = "Mini recruit window", setting = "guildMiniShown", section = "guild" },
    { key = "scan", label = "Auction House scan panel", setting = "ahHelper", section = "ah",
        state = function(on) return on and "at the Auction House" or "off" end },
    -- A show/hide switch like the others; its one home stays Settings > General.
    { key = "minimap", label = "Minimap button", setting = "minimapButton", section = "general" },
}
Nav.PIECES = PIECES

local pieceByKey = {}
for _, p in ipairs(PIECES) do pieceByKey[p.key] = p end

local function PieceOn(p)
    if p.get then return p.get() and true or false end
    return db()[p.setting] and true or false
end

local function ApplyPiece(p, on)
    if p.set then
        p.set(on)
    else
        db()[p.setting] = on and true or false
        if p.key == "mini" and ns.GuildUI and ns.GuildUI.RefreshMini then ns.GuildUI.RefreshMini() end
        if p.key == "minimap" and ns.MinimapButton then ns.MinimapButton.Refresh() end
    end
    ns.Refresh()
end

-- Shows or hides a floating piece. A piece with secure buttons waits until
-- combat ends: returns "wait" then, else true.
function Nav.SetPiece(key, on)
    local p = pieceByKey[key]
    if not p then return false end
    if p.secure and InCombat() then
        pending[key] = on and true or false
        Nav.RefreshHome()
        return "wait"
    end
    pending[key] = nil
    ApplyPiece(p, on)
    return true
end

function Nav.PiecePending(key) return pending[key] end

---------------------------------------------------------------------------
-- Home
---------------------------------------------------------------------------
local PAD = 14

local MOVED = {
    { "Main menu", "Home" },
    { "Character", "Gear, Professions" },
    { "Economy", "Gold" },
    { "Market, Auction desk", "Auction House (crafting profit: Professions)" },
    { "Guild", "Recruit, Members" },
    { "Settings › Journal, Census", "Enemies" },
    { "Changelog, Credits", "About" },
}

local function MovedText()
    local lines = {}
    for _, m in ipairs(MOVED) do lines[#lines + 1] = m[1] .. "  →  " .. HEX.white .. m[2] .. "|r" end
    return table.concat(lines, "\n")
end

local function HomeLine(parent, page)
    local l = CreateFrame("Button", nil, parent)
    l:SetHeight(40)
    l.hl = Style.Texture(l, "HIGHLIGHT", COLORS.hover)
    l.hl:SetAllPoints()
    l.rule = Style.HLine(l, COLORS.line)
    l.rule:SetPoint("BOTTOMLEFT", 6, 0)
    l.rule:SetPoint("BOTTOMRIGHT", -6, 0)
    l.glyph = Style.Glyph(l, page.glyph, 16, "t3")
    l.glyph:SetPoint("LEFT", 10, 0)
    l.name = Style.Text(l, "cardTitle")
    l.name:SetPoint("LEFT", 34, 0)
    l.name:SetWidth(104)
    l.name:SetText(page.label)
    l.chevron = Style.Glyph(l, "chevronright", 10, "t4")
    l.chevron:SetPoint("RIGHT", -10, 0)
    l.age = Style.Text(l, "meta", "RIGHT")
    l.age:SetPoint("RIGHT", -26, 0)
    l.age:SetWidth(90)
    l.status = Style.Text(l, "body")
    l.status:SetPoint("LEFT", 142, 0)
    l.status:SetPoint("RIGHT", l.age, "LEFT", -8, 0)
    l.page = page
    l:SetScript("OnClick", function(self)
        local st = self.st
        Nav.Go(page.key, st and st.tab, st and st.view)
    end)
    l:SetScript("OnEnter", function(self) Nav.PageTip(self, page, "ANCHOR_RIGHT") end)
    l:SetScript("OnLeave", function() ns.Tooltip.Hide() end)
    return l
end

local function PieceRow(parent, p)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(26)
    r.switch = Style.Switch(r, function(on, sw)
        if p.enabled and not p.enabled() then sw:SetOn(false) return end
        local result = Nav.SetPiece(p.key, on)
        if result == "wait" then ns.Print(p.label .. ": " .. (on and "shows" or "hides") .. " when combat ends.") end
        Nav.RefreshHome()
    end, function()
        return { p.label, p.secure and "Shows or hides it. It carries buttons the game locks in combat, so a change waits until combat ends."
            or "Shows or hides it." }
    end)
    r.switch:SetPoint("LEFT", 8, 0)
    r.name = Style.Text(r, "body")
    r.name:SetPoint("LEFT", r.switch, "RIGHT", 10, 0)
    r.name:SetText(p.label)
    local c = COLORS.t1
    r.name:SetTextColor(c[1], c[2], c[3])
    r.state = Style.Text(r, "meta", "RIGHT")
    r.state:SetPoint("RIGHT", -30, 0)
    r.gear = Style.IconButton(r, "gear", function() Style.OpenSettings(p.section) end,
        { "Settings", "Opens its settings." }, { small = true })
    r.gear:SetPoint("RIGHT", -6, 0)
    r.piece = p
    return r
end

local function LayoutHome()
    if not home then return end
    local top = (Style.M.titleBar or 34) + 10
    local notice = home.notice
    if notice and notice:IsShown() then top = top + (notice:GetHeight() or 60) + 10 end
    home.lineCard:ClearAllPoints()
    home.lineCard:SetPoint("TOPLEFT", PAD, -top)
    home.lineCard:SetPoint("BOTTOMLEFT", PAD, PAD + 4)
    home.lineCard:SetPoint("RIGHT", home.pieceCard, "LEFT", -12, 0)
    home.pieceCard:ClearAllPoints()
    home.pieceCard:SetPoint("TOPRIGHT", -PAD, -top)
    -- Lines share the card's height: 40 each when they fit, never under 24.
    local visible = 0
    for _, l in ipairs(home.lines) do if l:IsShown() then visible = visible + 1 end end
    local head = Style.M.cardHeader or 26
    local avail = (home:GetHeight() or 620) - top - PAD - 4 - head - 8
    local h = math.max(24, math.min(40, math.floor(avail / math.max(1, visible))))
    local y = 0
    for _, l in ipairs(home.lines) do
        if l:IsShown() then
            l:SetHeight(h)
            l:ClearAllPoints()
            l:SetPoint("TOPLEFT", home.lineCard.content, "TOPLEFT", 0, -y)
            l:SetPoint("TOPRIGHT", home.lineCard.content, "TOPRIGHT", 0, -y)
            y = y + h
        end
    end
end

local function DismissMoved()
    db().navMovedSeen = true
    if home and home.notice then home.notice:Hide() end
    LayoutHome()
end

local function BuildHome()
    home = Style.Window(ns.FRAME .. "MainMenu", "Home", nil, nil, { nav = "home", settings = "general" })
    local Bind = ns.Options and ns.Options.Bind

    -- Title bar: Go to, Mute alerts.
    home.mute = Style.Button(home, "", 104, function()
        db().alertsEnabled = not db().alertsEnabled
        ns.Refresh()
        Nav.RefreshHome()
    end, function()
        return { db().alertsEnabled and "Enemy alerts are on" or "Enemy alerts are muted",
            "Center text, sound and chat line when an enemy player shows up." }
    end, { small = true, glyph = "bell" })
    if Bind then Bind("alertsEnabled", "quick", "home") end
    home.header:Add(home.mute)
    home.gotoButton = Style.Button(home, "Go to…", 84, function() Nav.OpenGoTo() end,
        { "Go to", "Pages, tabs, settings and commands, and the old page names too." }, { small = true, glyph = "search" })
    home.header:Add(home.gotoButton)

    -- What moved, until it is dismissed.
    local width = (home:GetWidth() or Nav.DEFAULT_SIZE[1]) - 2 * PAD
    home.notice = Style.Notice(nil, nil, { flat = true, parent = home, width = width, tone = "accent" })
    home.notice:SetPoint("TOPLEFT", PAD, -((Style.M.titleBar or 34) + 10))
    home.notice:Set({
        headline = ns.NAME .. "'s pages moved in this version",
        sub = "Every old command still works, and Go to finds the old names too.",
        pages = { { key = "moved", blocks = { { text = MovedText() } } } },
        buttons = {
            { label = "Where is…?", width = 100, onClick = function() Nav.OpenGoTo() end },
            { label = "Got it", width = 80, onClick = DismissMoved },
        },
    })
    home.notice:SetShown(not db().navMovedSeen)

    -- On screen.
    home.pieceCard = Style.Card(home, "On screen")
    home.pieceCard:SetWidth(312)
    home.pieces = {}
    for i, p in ipairs(PIECES) do
        local r = PieceRow(home.pieceCard.content, p)
        r:SetPoint("TOPLEFT", 0, -(i - 1) * 26)
        r:SetPoint("TOPRIGHT", 0, -(i - 1) * 26)
        home.pieces[p.key] = r
        if p.setting and not p.noBind and Bind then Bind(p.setting, "quick", "home") end
    end
    local head = Style.M.cardHeader or 26
    home.pieceCard:SetHeight(head + 8 + #PIECES * 26 + 4)
    home.pieceNote = Style.Text(home, "meta")
    if home.pieceNote.SetWordWrap then home.pieceNote:SetWordWrap(true) end
    home.pieceNote:SetPoint("TOPLEFT", home.pieceCard, "BOTTOMLEFT", 2, -8)
    home.pieceNote:SetPoint("TOPRIGHT", home.pieceCard, "BOTTOMRIGHT", -2, -8)
    home.pieceNote:SetText("A switch that shows or hides a piece with target or lure buttons waits until you leave combat.")

    -- Right now: one line per page.
    home.lineCard = Style.Card(home, "Right now")
    home.lineCard.sub:SetText("one line per page · click to open")
    home.lines, home.lineByKey = {}, {}
    for _, page in ipairs(PAGES) do
        if page.key ~= "home" and page.key ~= "settings" and page.key ~= "about" then
            local l = HomeLine(home.lineCard.content, page)
            home.lines[#home.lines + 1] = l
            home.lineByKey[page.key] = l
        end
    end
    home:HookScript("OnShow", function() Nav.RefreshHome() end)
    home:HookScript("OnSizeChanged", LayoutHome)
    LayoutHome()
end

function Nav.RefreshHome()
    if not home or not home:IsShown() then return end
    for _, l in ipairs(home.lines) do
        local hidden = Nav.Hidden(l.page)
        l:SetShown(not hidden)
        if not hidden then
            local st = Nav.Status(l.page.key)
            l.st = st
            if st and st.text then
                local text = st.text
                if st.tone and not st.count then text = Style.ToneHex(st.tone) .. text .. "|r" end
                l.status:SetText(text)
            else
                l.status:SetText(HEX.muted .. (l.page.desc or "") .. "|r")
            end
            l.age:SetText(st and st.age or "")
        end
    end
    for _, p in ipairs(PIECES) do
        local r = home.pieces[p.key]
        local enabled = not p.enabled or p.enabled()
        local on = PieceOn(p)
        local wait = pending[p.key]
        if wait ~= nil then
            r.switch:SetOn(wait)
            r.state:SetText((wait and "shows" or "hides") .. " after combat")
        else
            r.switch:SetOn(on and enabled)
            r.state:SetText(p.state and p.state(on, enabled) or (on and "shown" or "hidden"))
        end
        r.switch:SetAlpha(enabled and 1 or 0.5)
    end
    local muted = not db().alertsEnabled
    home.mute:SetLabel(muted and "Alerts muted" or "Mute alerts")
    home.mute:SetOn(muted)
    home.notice:SetShown(not db().navMovedSeen)
    LayoutHome()
    if home.navRail then RefreshRail(home.navRail) end
end

function Nav.ShowHome()
    if not home then BuildHome() end
    if not home:IsShown() then home:Show() end
    if home.Raise then home:Raise() end
    Nav.RefreshHome()
end
-- Older names.
Nav.ShowMenu = Nav.ShowHome
Nav.RefreshMenu = function() Nav.RefreshHome() end

-- /talod menu: closes Home when it is open, else shows it in place of
-- whatever main window is open.
function Nav.ToggleMenu()
    if home and home:IsShown() then home:Hide() else Nav.ShowHome() end
end

function Nav.MenuShown() return home ~= nil and home:IsShown() end
function Nav.Home() return home end

---------------------------------------------------------------------------
-- Go to: pages, tabs, views, settings, commands and old names
---------------------------------------------------------------------------
-- Old names: what players knew, and where that content is now.
local OLD_NAMES = {
    { "Main menu", "home" },
    { "Character", "gear" },
    { "Sources", "gear", "ledger", "New items" },
    { "Economy", "gold" },
    { "Auctions", "ah", "mine", "Auctions", note = "Economy" },
    { "Market", "ah" },
    { "Auction desk", "ah", "today" },
    { "Listings", "ah", "mine", "Auctions" },
    { "Control", "ah", "prices" },
    { "Margins", "prof", "profit" },
    { "Crafting", "prof", "profit", note = "Market" },
    { "Crafting", "prof", "log", note = "Character" },
    { "Professions", "prof", "plan", note = "Character" },
    { "Sell-through", "ah", "mine", "By item" },
    { "Changelog", "about", "changelog" },
    { "Credits", "about", "credits" },
    { "Guild", "recruit" },
    { "Recruit", "recruit", "find", note = "Guild" },
    { "Replies", "recruit", "invited" },
    { "Recruiters", "recruit", "results" },
    { "Activity", "members", "roster", "Activity" },
    { "Members", "members", "roster", "Shared", note = "Guild" },
    { "Members", "audit", nil, "Guild", note = "Audit" },
    { "Flags", "audit", nil, "Flagged" },
    { "Characters", "audit", nil, "Everyone" },
    { "Parties", "groups", "history" },
    { "Raids", "groups", "history" },
    { "Sessions", "fishing", "log", "Sessions" },
    { "Journal", "enemies", "journal", note = "Settings" },
    { "Census", "enemies", "census", note = "Settings" },
}
Nav.OLD_NAMES = OLD_NAMES

local KIND_ORDER = { Page = 1, Tab = 2, Was = 3, View = 4, Section = 5, Setting = 6, Command = 7 }

local function SectionLabel(key)
    for _, s in ipairs(Nav.SECTIONS or {}) do
        if s.key == key then return s.label end
    end
    return key
end

local function OpenSection(section, search)
    local O = ns.Options
    if not O then return end
    if O.OpenSection then O.OpenSection(section, search) else Style.OpenSettings(section) end
end

-- Every entry: { kind, label, path, hay (what matches), go = fn }.
function Nav.Index()
    local out = {}
    local function Add(e)
        e.hay = (e.label .. " " .. (e.extra or "")):lower()
        out[#out + 1] = e
    end
    for _, page in ipairs(Nav.Pages()) do
        Add({ kind = "Page", label = page.label, path = page.group ~= "" and page.group or "", page = page.key,
            go = function() Nav.Go(page.key) end })
        for _, tab in ipairs(page.tabs or {}) do
            Add({ kind = "Tab", label = tab.label, path = Nav.Location(page.key), page = page.key, tab = tab.key,
                extra = tab.desc, go = function() Nav.Go(page.key, tab.key) end })
            for _, v in ipairs(tab.views or {}) do
                Add({ kind = "View", label = v, path = Nav.Location(page.key, tab.key), page = page.key, tab = tab.key, view = v,
                    go = function() Nav.Go(page.key, tab.key, v) end })
            end
        end
        for _, v in ipairs(page.views or {}) do
            Add({ kind = "View", label = v, path = Nav.Location(page.key), page = page.key, view = v,
                go = function() Nav.Go(page.key, nil, v) end })
        end
    end
    for _, o in ipairs(OLD_NAMES) do
        local page = byKey[o[2]]
        if page and not Nav.Hidden(page) then
            Add({ kind = "Was", label = o[1], path = "now " .. Nav.Location(o[2], o[3], o[4]), page = o[2], tab = o[3],
                view = o[4], extra = o.note, go = function() Nav.Go(o[2], o[3], o[4]) end })
        end
    end
    for _, s in ipairs(Nav.SECTIONS or {}) do
        Add({ kind = "Section", label = s.label, path = "Settings", section = s.key,
            go = function() OpenSection(s.key) end })
    end
    local settings = ns.Options and ns.Options.SETTINGS
    if type(settings) == "table" then
        for _, row in ipairs(settings) do
            local section = type(row.section) == "string" and row.section
                or (type(row.home) == "string" and row.home:match("^settings/([%w_]+)")) or nil
            if type(row.label) == "string" and section then
                Add({ kind = "Setting", label = row.label, path = "Settings › " .. SectionLabel(section), section = section,
                    key = row.key, extra = row.key, go = function() OpenSection(section, row.label) end })
            end
        end
    end
    for _, r in ipairs(ns.Cmd.List()) do
        Add({ kind = "Command", label = r.canonical, path = r.help or "", command = r.canonical,
            extra = table.concat(r.aliases or {}, " ") .. " " .. (r.help or ""),
            go = function() ns.Utils.Copy(r.canonical, "command") end })
    end
    for i, e in ipairs(out) do e.n = i end
    return out
end

-- Entries matching every word of text, best first.
function Nav.Find(text)
    local needles = {}
    for w in (text or ""):lower():gmatch("%S+") do needles[#needles + 1] = w end
    local found = {}
    if #needles == 0 then return found end
    local whole = table.concat(needles, " ")
    for _, e in ipairs(Nav.Index()) do
        local all = true
        for _, n in ipairs(needles) do
            if not e.hay:find(n, 1, true) then all = false break end
        end
        if all then
            local label = e.label:lower()
            e.score = label == whole and 0 or (label:sub(1, #whole) == whole and 1) or (label:find(whole, 1, true) and 2) or 3
            found[#found + 1] = e
        end
    end
    table.sort(found, function(a, b)
        if a.score ~= b.score then return a.score < b.score end
        local ka, kb = KIND_ORDER[a.kind] or 9, KIND_ORDER[b.kind] or 9
        if ka ~= kb then return ka < kb end
        return a.n < b.n
    end)
    return found
end

local palette
local MAX_RESULTS = 10
local RESULT_H = 22

local function Highlight(label, text)
    local whole = (text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local s, e = label:lower():find(whole, 1, true)
    if whole == "" or not s then return HEX.white .. label .. "|r" end
    return HEX.white .. label:sub(1, s - 1) .. "|r" .. HEX.accent .. label:sub(s, e) .. "|r" .. HEX.white .. label:sub(e + 1) .. "|r"
end

function Nav.CloseGoTo()
    if palette and palette:IsShown() then palette:Hide() end
end

-- A command is shown and copied, never run.
function Nav.Pick(entry)
    if not entry then return end
    Nav.CloseGoTo()
    if entry.go then entry.go() end
end

local function ShowResults(text)
    local found = Nav.Find(text)
    palette.found = found
    palette.selected = found[1] and 1 or nil
    for i = 1, MAX_RESULTS do
        local b = palette.results[i]
        local e = found[i]
        if e then
            b.entry = e
            b.kind:SetText(string.upper(e.kind == "Was" and "Was" or e.kind))
            b.label:SetText(Highlight(e.label, text))
            b.path:SetText(e.path or "")
            b:Show()
        else
            b.entry = nil
            b:Hide()
        end
    end
    local n = math.min(#found, MAX_RESULTS)
    palette.empty:SetShown(text ~= "" and n == 0)
    palette:Select(palette.selected)
    palette:SetHeight(36 + math.max(n, (text ~= "" and n == 0) and 1 or 0) * RESULT_H + 28)
end

local function BuildPalette()
    palette = CreateFrame("Frame", ns.FRAME .. "GoTo", UIParent)
    palette:SetSize(520, 64)
    palette:SetFrameStrata("FULLSCREEN_DIALOG")
    palette:EnableMouse(true)
    Style.Surface(palette, "menu")
    palette:Hide()
    if UISpecialFrames then table.insert(UISpecialFrames, ns.FRAME .. "GoTo") end

    -- The dimmed window behind it; a click there closes Go to.
    local scrim = CreateFrame("Button", nil, UIParent)
    scrim:SetFrameStrata("FULLSCREEN")
    scrim.bg = Style.Texture(scrim, "BACKGROUND", COLORS.shade)
    scrim.bg:SetAllPoints()
    Style.Fill(scrim.bg, COLORS.edge, 0.45)
    scrim:SetScript("OnClick", function() Nav.CloseGoTo() end)
    scrim:Hide()
    palette.scrim = scrim
    palette:SetScript("OnHide", function(self) self.scrim:Hide() end)

    local glyph = Style.Glyph(palette, "search", 14, "t3")
    glyph:SetPoint("TOPLEFT", 12, -11)
    local box = CreateFrame("EditBox", nil, palette)
    box:SetHeight(24)
    box:SetPoint("TOPLEFT", 32, -6)
    box:SetPoint("TOPRIGHT", -12, -6)
    box:SetAutoFocus(false)
    box:SetFontObject(Style.Font("body"))
    box:SetScript("OnTextChanged", function(self) ShowResults(self:GetText() or "") end)
    box:SetScript("OnEscapePressed", function() Nav.CloseGoTo() end)
    box:SetScript("OnEnterPressed", function()
        Nav.Pick(palette.found and palette.selected and palette.found[palette.selected])
    end)
    box:SetScript("OnArrowPressed", function(_, key)
        local n = math.min(#(palette.found or {}), MAX_RESULTS)
        if n == 0 then return end
        local i = palette.selected or 0
        if key == "DOWN" then i = i % n + 1 elseif key == "UP" then i = (i - 2) % n + 1 end
        palette:Select(i)
    end)
    palette.box = box
    local rule = Style.HLine(palette, COLORS.line)
    rule:SetPoint("TOPLEFT", 1, -34)
    rule:SetPoint("TOPRIGHT", -1, -34)

    palette.results = {}
    for i = 1, MAX_RESULTS do
        local b = CreateFrame("Button", nil, palette)
        b:SetHeight(RESULT_H)
        b:SetPoint("TOPLEFT", 1, -36 - (i - 1) * RESULT_H)
        b:SetPoint("TOPRIGHT", -1, -36 - (i - 1) * RESULT_H)
        b.sel = Style.Texture(b, "BACKGROUND", COLORS.selected)
        b.sel:SetAllPoints()
        b.sel:Hide()
        local hl = Style.Texture(b, "HIGHLIGHT", COLORS.hover)
        hl:SetAllPoints()
        b.kind = Style.Text(b, "label")
        b.kind:SetPoint("LEFT", 12, 0)
        b.kind:SetWidth(64)
        b.label = Style.Text(b, "body")
        b.label:SetPoint("LEFT", 80, 0)
        b.path = Style.Text(b, "meta", "RIGHT")
        b.path:SetPoint("RIGHT", -12, 0)
        b.path:SetPoint("LEFT", b.label, "RIGHT", 12, 0)
        b:SetScript("OnClick", function(self) Nav.Pick(self.entry) end)
        b:SetScript("OnEnter", function(self) palette:Select(i) end)
        b:Hide()
        palette.results[i] = b
    end
    palette.empty = Style.Text(palette, "meta")
    palette.empty:SetPoint("TOPLEFT", 12, -40)
    palette.empty:SetText("Nothing here by that name.")
    palette.empty:Hide()
    palette.foot = Style.Text(palette, "meta")
    palette.foot:SetPoint("BOTTOMLEFT", 12, 8)
    palette.foot:SetPoint("BOTTOMRIGHT", -12, 8)
    palette.foot:SetText("Up / Down: move  ·  Enter: go there  ·  old names are found too  ·  a command is shown, never run")

    function palette:Select(i)
        self.selected = i
        for k, b in ipairs(self.results) do b.sel:SetShown(k == i) end
    end
end

-- Opens Go to over the open window (or the middle of the screen), with text.
function Nav.OpenGoTo(text)
    if not palette then BuildPalette() end
    local win = Nav.Current()
    palette:ClearAllPoints()
    if win then
        palette:SetPoint("TOP", win, "TOP", 0, -60)
        palette.scrim:ClearAllPoints()
        palette.scrim:SetAllPoints(win)
        palette.scrim:Show()
    else
        palette:SetPoint("TOP", UIParent, "TOP", 0, -160)
        palette.scrim:Hide()
    end
    palette:Show()
    if palette.Raise then palette:Raise() end
    palette.box:SetText(text or "")
    ShowResults(text or "")
    palette.box:SetFocus()
    return palette
end

function Nav.GoToShown() return palette ~= nil and palette:IsShown() end
function Nav.Palette() return palette end

-- /talod find <text>: one entry named exactly that goes there; anything else
-- opens Go to with the text. Returns the matches.
function Nav.GoTo(text)
    text = tostring(text or "")
    local found = Nav.Find(text)
    local whole = text:lower():gsub("^%s+", ""):gsub("%s+$", "")
    local exact = {}
    for _, e in ipairs(found) do
        if e.label:lower() == whole then exact[#exact + 1] = e end
    end
    if #exact == 1 then
        Nav.Pick(exact[1])
        return found, exact[1]
    end
    Nav.OpenGoTo(text)
    return found
end

---------------------------------------------------------------------------
-- Module
---------------------------------------------------------------------------
local function Slash(command)
    if command ~= "menu" then return false end
    Nav.ToggleMenu()
    return true
end

local sinceRefresh = 0

ns.RegisterModule("Navigation", {
    -- navLast: the page Nav.Go() reopens; navMovedSeen: the pages-moved notice was dismissed.
    defaults = { navMovedSeen = false, navLast = "" },
    init = function()
        -- A first install has nothing that moved.
        if not db().welcomeShown then db().navMovedSeen = true end
    end,
    refresh = function()
        Nav.RefreshHome()
        local f = Nav.Current()
        if f and f ~= home and f.navRail then RefreshRail(f.navRail) end
    end,
    -- Statuses move (enemies, replies): the open window's list and Home follow, every 3 s.
    tick = function()
        sinceRefresh = sinceRefresh + (ns.C and ns.C.TICK_INTERVAL or 0.2)
        if sinceRefresh < 3 then return end
        sinceRefresh = 0
        local f = Nav.Current()
        if not f then return end
        if f == home then Nav.RefreshHome() elseif f.navRail then RefreshRail(f.navRail) end
    end,
    events = { "PLAYER_REGEN_ENABLED" },
    onEvent = function(event)
        if event ~= "PLAYER_REGEN_ENABLED" then return end
        local waiting = pending
        pending = {}
        for key, on in pairs(waiting) do ApplyPiece(pieceByKey[key], on) end
        Nav.RefreshHome()
    end,
    slash = Slash,
})
