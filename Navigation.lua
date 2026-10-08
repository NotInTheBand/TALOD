-- TALOD - navigation between the addon's windows: a page list docked on
-- the left of every main window, one main window open at a time (the next
-- one opens where the last one stood), and the Main menu the minimap button
-- opens.
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

local Nav = {}
ns.Nav = Nav

local RAIL_WIDTH = 150
Nav.RAIL_WIDTH = RAIL_WIDTH
local ROW_HEIGHT, ROW_GAP = 28, 2
local RAIL_BG = { 0.035, 0.035, 0.04, 1 }

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

-- module: the ns field whose Show opens the page; a page whose module did not
-- load is left out of the rail and the menu.
-- desc: two lines at most on a menu tile at the smallest window size (~110
-- characters). tabs: { tab, what it shows } for the tooltip, in tab order.
local PAGES = {
    { key = "home", label = "Main menu", icon = "Interface\\Icons\\Ability_DualWield",
        desc = "Every page at a glance, and the Enemies nearby panel switch.",
        open = function() Nav.ShowMenu() end },
    { key = "character", label = "Character", module = "GearUI", icon = "Interface\\Icons\\INV_Chest_Chain",
        desc = "What you wore and what each change did to your stats, plus skills, professions and what to craft next.",
        tabs = {
            { "Gear", "your gear now beside an earlier set" },
            { "Ledger", "every change with its measured effect" },
            { "Progress", "your stats level by level" },
            { "Sources", "where each item came from" },
            { "Skills", "skill-ups, training and ranks" },
            { "Enhance", "enchants that fit each item, and their reagents" },
            { "Professions", "cheapest path to the next skill points" },
            { "Crafting", "everything you made, and when" },
        } },
    { key = "economy", label = "Economy", module = "EconomyUI", icon = "Interface\\Icons\\INV_Misc_Coin_01",
        desc = "Where your gold comes from and where it goes: vendors, repairs, loot, quests, mail, trades and auctions.",
        tabs = {
            { "Overview", "totals by source and by day" },
            { "Transactions", "every money change and the window it came from" },
            { "Auctions", "what you listed, what sold, what came back" },
            { "Trades", "trades with other players" },
        } },
    { key = "market", label = "Market", module = "MarketUI", icon = "Interface\\Icons\\INV_Misc_Coin_02",
        desc = "Auction prices you've seen and how they move: what to sell or vendor, which crafts pay, what's cheap now.",
        tabs = {
            { "Prices", "an item's price, supply and graph" },
            { "Sell", "your bags: Auction House or vendor" },
            { "Crafting", "material cost against selling price" },
            { "Deals", "listings under the usual price" },
            { "Bids", "bids under the buyout, time left" },
            { "Sell-through", "how fast items really sell" },
        } },
    { key = "desk", label = "Auction desk", module = "AuctionDeskUI", icon = "Interface\\Icons\\INV_Scroll_03",
        desc = "Your listings against the market: who undercut you, where the margins are, what buying out a price costs.",
        tabs = {
            { "Overview", "your listings, best resets, deals" },
            { "Listings", "each listing: lowest or undercut" },
            { "Deals", "cheap buys and the supply behind them" },
            { "Margins", "crafts and resale after the cut" },
            { "Control", "cost to own an item's supply and relist" },
        } },
    { key = "fishing", label = "Fishing", module = "FishingUI", icon = "Interface\\Icons\\Trade_Fishing",
        desc = "Every cast logged: the best spots for your skill, gold per hour, rare fish still to catch, and the HUD.",
        tabs = {
            { "Now", "this session and this spot" },
            { "Spots", "spots ranked by gold, catch rate or safety" },
            { "Map", "heat map of where you fished" },
            { "Log", "every cast and what it gave" },
            { "Sessions", "each trip: casts, value, attacks" },
            { "Goals", "rare and quest fish, timed catches" },
        } },
    { key = "guild", label = "Guild", module = "GuildUI", icon = "Interface\\Icons\\INV_Banner_02",
        desc = "Find unguilded players, invite them in one click, follow replies, and keep track of members and promotions.",
        tabs = {
            { "Recruit", "players without a guild you have seen" },
            { "Invited", "who joined, declined or didn't answer" },
            { "Replies", "whisper conversations with recruits" },
            { "Roster", "members, last online, inactivity" },
            { "Activity", "who talks and who is online (officers)" },
            { "Recruiters", "who brought whom, and who stayed" },
            { "Promotions", "members your rules say are due" },
            { "Log", "joins, leaves, kicks and rank changes" },
            { "Members", "what members chose to share" },
            { "Sharing", "what you share with officers" },
        } },
    { key = "audit", label = "Audit", module = "AuditUI", icon = "Interface\\Icons\\INV_Misc_Spyglass_02",
        desc = "Gold and activity from the game's statistics, for you and members who share: flags gold that looks bought.",
        tabs = {
            { "Members", "your roster and what is known of each" },
            { "Flags", "records worth a look" },
            { "Characters", "every record you hold" },
            { "Ledger", "income, spending and activity of one" },
            { "History", "every look, with the change since the last" },
        } },
    { key = "groups", label = "Groups", module = "GroupsUI", icon = "Interface\\Icons\\Ability_Warrior_BattleShout",
        desc = "Every party and raid you were in: who was there, where, for how long, deaths, the group's chat and loot.",
        tabs = {
            { "Now", "the group you are in, live" },
            { "Parties", "past parties" },
            { "Raids", "past raids" },
            { "Group", "one group in full" },
        } },
    { key = "settings", label = "Settings", module = "Options", icon = "Interface\\Icons\\INV_Misc_Gear_01",
        desc = "The Enemies nearby panel, nameplates, alerts, PvP safety, stealth, the enemy journal, and every page's options.",
        tabs = {
            { "General", "panel and nameplate badges" },
            { "Alerts", "when an enemy alert fires, and how" },
            { "Safety", "PvP flag, flagging warnings, contested zones" },
            { "Stealth", "alert when a stealther vanishes nearby" },
            { "Journal", "enemies seen, kill-on-sight and avoid lists" },
            { "Census", "the player census and heat maps" },
            { "Data", "cleanup, archive and memory" },
            { "Advanced", "probe, error log and saved data" },
            { "And more", "one tab per page: Character, Fishing, Guild..." },
        },
        open = function() ns.Options.Open() end },
    { key = "credits", label = "Credits", module = "Credits", icon = "Interface\\Icons\\INV_Misc_Note_01",
        desc = "Who made " .. ns.NAME .. ", the Discord for questions, bug reports and ideas, and how to send gold." },
}
Nav.PAGES = PAGES

local function Available(page) return page.module == nil or ns[page.module] ~= nil end

function Nav.Pages()
    local out = {}
    for _, page in ipairs(PAGES) do
        if Available(page) then out[#out + 1] = page end
    end
    return out
end

function Nav.Page(key)
    for _, page in ipairs(PAGES) do
        if page.key == key then return page end
    end
end

function Nav.Open(key)
    local page = Nav.Page(key)
    if not page or not Available(page) then return false end
    if page.open then page.open() else ns[page.module].Show() end
    return true
end

---------------------------------------------------------------------------
-- One main window at a time
---------------------------------------------------------------------------
local current
local windows = {}   -- [key] = frame

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
local function Activate(f)
    ApplySize(f)
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

function Nav.CloseAll()
    for _, f in pairs(windows) do
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
    if page.tabs then
        t:Blank()
        for _, tab in ipairs(page.tabs) do t:Pair(tab[1], tab[2], "muted") end
    end
    return t:Show()
end

local function RailButton(rail, page, index)
    local b = CreateFrame("Button", nil, rail)
    b:SetSize(RAIL_WIDTH - 12, ROW_HEIGHT)
    b:SetPoint("TOPLEFT", 6, -48 - (index - 1) * (ROW_HEIGHT + ROW_GAP))
    b.bg = Style.Texture(b, "BACKGROUND")
    b.bg:SetAllPoints()
    b.accent = Style.Texture(b, "ARTWORK", COLORS.accent)
    b.accent:SetWidth(3)
    b.accent:SetPoint("TOPLEFT")
    b.accent:SetPoint("BOTTOMLEFT")
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(18, 18)
    b.icon:SetPoint("LEFT", 10, 0)
    b.icon:SetTexture(page.icon)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.text = Style.Text(b, "GameFontNormal")
    b.text:SetPoint("LEFT", b.icon, "RIGHT", 8, 0)
    b.text:SetPoint("RIGHT", -4, 0)
    b.text:SetText(page.label)
    local hl = Style.Texture(b, "HIGHLIGHT", { 1, 1, 1, 0.05 })
    hl:SetAllPoints()
    b:SetScript("OnClick", function() Nav.Open(page.key) end)
    if page.desc then
        b:SetScript("OnEnter", function(self) Nav.PageTip(self, page, "ANCHOR_RIGHT") end)
        b:SetScript("OnLeave", function() ns.Tooltip.Hide() end)
    end
    b.key = page.key
    return b
end

local function MarkSelected(rail, key)
    for k, b in pairs(rail.buttons) do
        local on = k == key
        b.accent:SetShown(on)
        Style.Fill(b.bg, { 1, 1, 1 }, on and 0.06 or 0)
        b.text:SetTextColor(on and 1 or 0.78, on and 0.82 or 0.78, on and 0.55 or 0.78)
        b.icon:SetDesaturated(not on)
        b.icon:SetAlpha(on and 1 or 0.75)
    end
end

local function BuildRail(f, key)
    local rail = CreateFrame("Frame", nil, f)
    rail:SetWidth(RAIL_WIDTH)
    -- 1 px overlap: the rail's right edge and the window's left edge share a line.
    rail:SetPoint("TOPRIGHT", f, "TOPLEFT", 1, 0)
    rail:SetPoint("BOTTOMRIGHT", f, "BOTTOMLEFT", 1, 0)
    rail:EnableMouse(true)
    rail:RegisterForDrag("LeftButton")
    rail:SetScript("OnDragStart", function() f:StartMoving() end)
    rail:SetScript("OnDragStop", function() f:StopMovingOrSizing() SavePosition(f) end)
    rail.surface = Style.Texture(rail, "BACKGROUND", RAIL_BG)
    rail.surface:SetAllPoints()
    Style.Border(rail, COLORS.border)
    local bar = Style.Texture(rail, "BACKGROUND", COLORS.titleBar)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:SetHeight(38)
    rail.title = Style.Text(rail, "GameFontNormalLarge")
    rail.title:SetPoint("TOPLEFT", 14, -12)
    rail.title:SetText(ns.TITLE)
    rail.buttons = {}
    for i, page in ipairs(Nav.Pages()) do rail.buttons[page.key] = RailButton(rail, page, i) end
    rail.version = Style.Text(rail, "GameFontDisableSmall")
    rail.version:SetPoint("BOTTOMLEFT", 14, 10)
    rail.version:SetText("v" .. tostring(ns.VERSION or "?"))
    MarkSelected(rail, key)
    return rail
end

-- Style.Window calls this for a window made with { nav = key }.
function Nav.Attach(f, key, title)
    windows[key] = f
    f.navKey = key
    f.navRail = BuildRail(f, key)
    -- The brand moved to the rail's header; the window keeps only its name.
    if f.title then f.title:SetText(HEX.white .. (title or "") .. "|r") end
    -- Keep the rail on screen as well.
    if f.SetClampRectInsets then f:SetClampRectInsets(-(RAIL_WIDTH - 1), 0, 0, 0) end
    f:HookScript("OnShow", Activate)
    f:HookScript("OnHide", function(self) if current == self then current = nil end end)
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
    if f:IsShown() then Activate(f) end
end

---------------------------------------------------------------------------
-- Main menu
---------------------------------------------------------------------------
local PAD = 16
local TILE_HEIGHT, TILE_GAP = 62, 10
local menu

local function Tile(parent, page, width)
    local t = CreateFrame("Button", nil, parent)
    t:SetSize(width, TILE_HEIGHT)
    t.bg = Style.Texture(t, "BACKGROUND", COLORS.card)
    t.bg:SetAllPoints()
    Style.Border(t, COLORS.cardBorder)
    local holder, icon = Style.IconFrame(t, 38)
    holder:SetPoint("LEFT", 12, 0)
    icon:SetTexture(page.icon)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    t.icon = icon
    t.title = Style.Text(t, "GameFontNormal")
    t.title:SetPoint("TOPLEFT", 62, -12)
    t.title:SetPoint("RIGHT", -10, 0)
    t.title:SetText(page.label)
    t.desc = Style.Text(t, "GameFontDisableSmall")
    t.desc:SetPoint("TOPLEFT", t.title, "BOTTOMLEFT", 0, -4)
    t.desc:SetPoint("RIGHT", -10, 0)
    if t.desc.SetWordWrap then t.desc:SetWordWrap(true) end
    t.desc:SetText(page.desc or "")
    local hl = Style.Texture(t, "HIGHLIGHT", { 1, 1, 1, 0.04 })
    hl:SetAllPoints()
    t:SetScript("OnEnter", function(self)
        self:SetBorderColor(COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.9)
        if page.tabs then Nav.PageTip(self, page, "ANCHOR_RIGHT") end
    end)
    t:SetScript("OnLeave", function(self)
        local c = COLORS.cardBorder
        self:SetBorderColor(c[1], c[2], c[3], c[4])
        ns.Tooltip.HideFor(self)
    end)
    t:SetScript("OnClick", function() Nav.Open(page.key) end)
    t.key = page.key
    return t
end

local function PanelLabel()
    return "Enemies nearby panel: " .. (db().panelShown and (HEX.good .. "shown|r") or (HEX.muted .. "hidden|r"))
end

local function BuildMenu()
    menu = Style.Window(ns.FRAME .. "MainMenu", "Main menu", nil, nil, { nav = "home" })
    local sub = Style.Text(menu, "GameFontDisableSmall", "RIGHT")
    sub:SetPoint("TOPRIGHT", -40, -16)
    sub:SetText("v" .. tostring(ns.VERSION or "?") .. "  ·  " .. tostring(ns.FLAVOR_NAME or ""))

    local intro = Style.Text(menu, "GameFontHighlight")
    intro:SetPoint("TOPLEFT", PAD, -52)
    intro:SetText("Pick a page. The list on the left switches pages from any " .. ns.NAME .. " window.")

    menu.tiles, menu.order = {}, {}
    for _, page in ipairs(Nav.Pages()) do
        if page.key ~= "home" then
            local t = Tile(menu, page, 200)
            menu.tiles[page.key] = t
            menu.order[#menu.order + 1] = t
        end
    end
    -- Two columns across whatever width the window has.
    local function LayoutTiles()
        local tileWidth = math.floor(((menu:GetWidth() or 660) - 2 * PAD - TILE_GAP) / 2)
        for n, t in ipairs(menu.order) do
            local col, row = (n - 1) % 2, math.floor((n - 1) / 2)
            t:SetWidth(tileWidth)
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", PAD + col * (tileWidth + TILE_GAP), -76 - row * (TILE_HEIGHT + TILE_GAP))
        end
    end
    LayoutTiles()
    menu:HookScript("OnSizeChanged", LayoutTiles)

    -- Quick controls for the things that are not windows.
    local line = Style.HLine(menu)
    line:SetPoint("BOTTOMLEFT", PAD, 58)
    line:SetPoint("BOTTOMRIGHT", -PAD, 58)
    menu.panelButton = Style.Button(menu, "", 250, function()
        db().panelShown = not db().panelShown
        ns.Refresh()
        Nav.RefreshMenu()
    end, "Shows or hides the Enemies nearby list (Ctrl + click on the minimap button does the same).",
        { title = "Enemies nearby panel" })
    menu.panelButton:SetPoint("BOTTOMLEFT", PAD, 22)
    menu.hint = Style.Text(menu, "GameFontDisableSmall", "RIGHT")
    menu.hint:SetPoint("BOTTOMRIGHT", -PAD, 28)
    menu.hint:SetText(ns.Cmd.Text("menu") .. " opens this page  ·  " .. ns.Cmd.Text("help") .. " lists commands")
    menu:HookScript("OnShow", function() Nav.RefreshMenu() end)
end

function Nav.RefreshMenu()
    if not menu or not menu:IsShown() then return end
    menu.panelButton:SetLabel(PanelLabel())
end

function Nav.ShowMenu()
    if not menu then BuildMenu() end
    if not menu:IsShown() then menu:Show() end
    if menu.Raise then menu:Raise() end
    Nav.RefreshMenu()
end

-- The minimap button: closes the menu when it is open, else shows it in
-- place of whatever main window is open.
function Nav.ToggleMenu()
    if menu and menu:IsShown() then menu:Hide() else Nav.ShowMenu() end
end

function Nav.MenuShown() return menu ~= nil and menu:IsShown() end

local function Slash(command)
    if command ~= "menu" then return false end
    Nav.ToggleMenu()
    return true
end

ns.RegisterModule("Navigation", {
    refresh = function() Nav.RefreshMenu() end,
    slash = Slash,
})
