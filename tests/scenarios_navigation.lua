-- Navigation (Navigation.lua): the page list on every main window, one main
-- window at a time (the next opens where the last stood), the Main menu.
local scenarios, T = ...
local check, boot, slash = T.check, T.boot, T.slash

local MAIN = { "TALODMainMenu", "TALODCharacterWindow", "TALODEconomyWindow", "TALODMarketWindow",
    "TALODAuctionDesk", "TALODFishingWindow", "TALODGuildWindow", "TALODOptionsWindow", "TALODCreditsWindow", "TALODChangelogWindow" }

local function openMain()
    local open = {}
    for _, name in ipairs(MAIN) do
        if _G[name] and _G[name]:IsShown() then open[#open + 1] = name end
    end
    return open
end

local function onlyOpen(name, label)
    local open = openMain()
    check(#open == 1 and open[1] == name, label .. ": open = " .. table.concat(open, ","))
end

scenarios.navigation = function()
    Minimap = CreateFrame("Frame", "Minimap", UIParent)
    Minimap._cx, Minimap._cy = 1000, 700
    local ns = boot(11509)
    local Nav = ns.Nav
    check(#openMain() == 0, "nothing open after login")

    -- The menu: a tile per page, the rail on its left.
    slash("menu")
    onlyOpen("TALODMainMenu", "/talod menu")
    local menu = TALODMainMenu
    for _, key in ipairs({ "character", "economy", "market", "desk", "fishing", "guild", "settings" }) do
        check(menu.tiles[key], "menu tile " .. key)
        check(menu.navRail.buttons[key], "rail entry " .. key)
    end
    check(menu.navRail.buttons.home.accent:IsShown(), "home marked in the rail")

    -- Every page from the menu replaces the window before it.
    menu.tiles.character:Fire("OnClick", "LeftButton")
    onlyOpen("TALODCharacterWindow", "menu tile opens the character window")
    local char = TALODCharacterWindow
    check(char.navRail.buttons.character.accent:IsShown() and not char.navRail.buttons.economy.accent:IsShown(),
        "character marked in its rail")
    char.navRail.buttons.economy:Fire("OnClick", "LeftButton")
    onlyOpen("TALODEconomyWindow", "rail opens economy")
    ns.MarketUI.Show()
    onlyOpen("TALODMarketWindow", "market by its own Show")
    ns.AuctionDeskUI.Show()
    onlyOpen("TALODAuctionDesk", "auction desk")
    slash("fish")
    onlyOpen("TALODFishingWindow", "/talod fish")
    ns.GuildUI.Show()
    onlyOpen("TALODGuildWindow", "guild")
    slash("")
    onlyOpen("TALODOptionsWindow", "/talod settings")
    TALODOptionsWindow.navRail.buttons.home:Fire("OnClick", "LeftButton")
    onlyOpen("TALODMainMenu", "rail back to the menu")

    -- The next window opens where the last one stood.
    menu._l, menu._t = 300, 800
    menu.tiles.market:Fire("OnClick", "LeftButton")
    local point, rel, relPoint, x, y = TALODMarketWindow:GetPoint(1)
    check(point == "TOPLEFT" and rel == UIParent and relPoint == "BOTTOMLEFT" and x == 300 and y == 800,
        "market took the menu's place: " .. tostring(point) .. " " .. tostring(x) .. "," .. tostring(y))

    -- A drag (window or rail) is remembered for the next window opened from nothing.
    TALODMarketWindow._l, TALODMarketWindow._t = 420, 700
    TALODMarketWindow.navRail:Fire("OnDragStop")
    check(TALODDB.navPos and TALODDB.navPos[1] == 420 and TALODDB.navPos[2] == 700, "rail drag saved")
    TALODMarketWindow:Hide()
    check(#openMain() == 0 and Nav.Current() == nil, "closed")
    ns.GearUI.Show()
    _, _, _, x, y = char:GetPoint(1)
    check(x == 420 and y == 700, "opened at the saved place")

    -- Side windows stay open next to a main window.
    slash("probe")
    check(TALODProbeWindow:IsShown(), "report open")
    ns.EconomyUI.Show()
    check(TALODProbeWindow:IsShown() and not char:IsShown(), "report stays, character closes")
    TALODProbeWindow:Hide()

    -- Quick control on the menu.
    Nav.ShowMenu()
    local shown = TALODDB.panelShown
    menu.panelButton:Fire("OnClick", "LeftButton")
    check(TALODDB.panelShown ~= shown and menu.panelButton.label:GetText():find("Enemies nearby"), "panel toggled from the menu")

    -- Minimap: left-click toggles the menu, from any window.
    ns.FishingUI.Show()
    TALODMinimapButton:Fire("OnClick", "LeftButton")
    onlyOpen("TALODMainMenu", "minimap opens the menu in place of fishing")
    TALODMinimapButton:Fire("OnClick", "LeftButton")
    check(#openMain() == 0, "minimap closes the menu")

    -- The addon compartment opens the menu too.
    TALOD_OnAddonCompartmentClick()
    onlyOpen("TALODMainMenu", "addon compartment")
    Nav.CloseAll()
    check(#openMain() == 0, "CloseAll")
    check(Nav.Open("nonsense") == false, "unknown page")
end

-- Credits page and the shared copy box (Utils.lua).
scenarios.credits = function()
    local ns = boot(11509)
    local Nav = ns.Nav
    Nav.ShowMenu()
    check(TALODMainMenu.tiles.credits and TALODMainMenu.navRail.buttons.credits, "credits tile and rail entry")
    TALODMainMenu.tiles.credits:Fire("OnClick", "LeftButton")
    check(ns.Credits.IsShown() and not TALODMainMenu:IsShown(), "credits replaces the menu")
    local f = TALODCreditsWindow

    f.copyInvite:Fire("OnClick", "LeftButton")
    check(MOCK.popup == "TALOD_COPY" and MOCK.popupText == "invite link"
        and MOCK.popupData == "https://discord.gg/2FYCFyRczN", "invite link in the copy box")
    f.copyAuthor:Fire("OnClick", "LeftButton")
    check(MOCK.popupData == "NotInTheBand", "author name in the copy box")
    f.copyDonate:Fire("OnClick", "LeftButton")
    check(MOCK.popupText == "name" and MOCK.popupData == "Send Coin", "donation character in the copy box")
    check(ns.Credits.DONATE.faction == "Alliance" and ns.Credits.DONATE.ruleset:find("PvP"), "Alliance, PvP realm")

    MOCK.popup, MOCK.popupData = nil, nil
    check(ns.Utils.Copy(nil, "name") == false and MOCK.popup == nil, "nothing to copy: no box")

    slash("credits")
    check(not ns.Credits.IsShown(), "/talod credits toggles closed")
    slash("credits")
    check(ns.Credits.IsShown(), "/talod credits opens")
end

-- One size for every main window: the corner grip resizes, the next page
-- opens at that size, a double-click puts the default back.
scenarios.nav_size = function()
    local ns = boot(11509)
    local Nav = ns.Nav
    local dw, dh = Nav.DEFAULT_SIZE[1], Nav.DEFAULT_SIZE[2]
    Nav.ShowMenu()
    local menu = TALODMainMenu
    check(menu:GetWidth() == dw and menu:GetHeight() == dh, "menu at the default size")
    ns.GearUI.Show()
    local char = TALODCharacterWindow
    check(char:GetWidth() == dw and char:GetHeight() == dh, "character window at the same size")
    local grip = char.sizeGrip
    check(grip, "size grip on the window")

    -- A drag: the top-left corner stays, the size follows the cursor.
    char._l, char._t = 300, 900
    MOCK.cursorX, MOCK.cursorY = 1240, 280
    grip:Fire("OnMouseDown", "LeftButton")
    local point, rel, relPoint, x, y = char:GetPoint(1)
    check(point == "TOPLEFT" and rel == UIParent and relPoint == "BOTTOMLEFT" and x == 300 and y == 900, "top-left pinned")
    MOCK.cursorX, MOCK.cursorY = 1400.4, 199.4
    grip:Fire("OnUpdate", 0.02)
    check(char:GetWidth() == dw + 160.4 and char:GetHeight() == dh + 80.6, "follows the cursor while dragging")
    MOCK.cursorX, MOCK.cursorY = 1240, 9999
    grip:Fire("OnUpdate", 0.02)
    check(char:GetWidth() == dw and char:GetHeight() == Nav.MIN_SIZE[2], "not below the minimum")
    MOCK.cursorX, MOCK.cursorY = 1400.4, 199.4
    grip:Fire("OnMouseUp", "LeftButton")
    check(grip:GetScript("OnUpdate") == nil, "stops following on release")
    check(TALODDB.navSize and TALODDB.navSize[1] == 1100 and TALODDB.navSize[2] == 701, "size saved: "
        .. tostring(TALODDB.navSize and TALODDB.navSize[1]) .. "x" .. tostring(TALODDB.navSize and TALODDB.navSize[2]))
    for _, show in ipairs({ ns.EconomyUI.Show, ns.FishingUI.Show, ns.GuildUI.Show, Nav.ShowMenu, ns.Credits.Show }) do
        show()
        local f = Nav.Current()
        check(f and f:GetWidth() == 1100 and f:GetHeight() == 701, "page opens at the shared size: " .. tostring(f and f:GetName()))
    end
    check(menu.tiles.character:GetWidth() == math.floor((1100 - 32 - 10) / 2), "menu tiles follow the width")
    ns.Options.Open()
    check(TALODOptionsWindow:GetWidth() == 1100, "settings at the shared size")

    -- Too small or too big a saved size is kept in bounds.
    TALODDB.navSize = { 100, 100 }
    local w, h = Nav.Size()
    check(w == Nav.MIN_SIZE[1] and h == Nav.MIN_SIZE[2], "minimum size")
    TALODDB.navSize = { 99999, 99999 }
    w, h = Nav.Size()
    check(w <= UIParent:GetWidth() and h <= UIParent:GetHeight(), "fits the screen")

    -- Double-click: default size, and the next page too.
    TALODDB.navSize = { 1100, 701 }
    ns.MarketUI.Show()
    local market = TALODMarketWindow
    market.sizeGrip:Fire("OnDoubleClick", "LeftButton")
    check(TALODDB.navSize == nil and market:GetWidth() == dw and market:GetHeight() == dh, "double-click resets")
    ns.AuditUI.Show()
    check(TALODAuditWindow:GetWidth() == dw, "next page at the default size")

    -- Closing mid-drag stops the sizing and keeps the size reached.
    local audit = TALODAuditWindow
    audit._l, audit._t = 300, 900
    MOCK.cursorX, MOCK.cursorY = 1240, 280
    audit.sizeGrip:Fire("OnMouseDown", "LeftButton")
    MOCK.cursorX = 1240 - (dw - 900)
    audit:Hide()
    check(TALODDB.navSize and TALODDB.navSize[1] == 900, "hidden mid-drag: size kept")
    check(not audit.sizeGrip.sizing, "sizing stopped")

    -- A settings reset puts the default size back.
    ns.Main.ResetSettings()
    check(TALODDB.navSize == nil, "reset clears the size")
end

-- Menu descriptions fit a tile at the smallest window; hovering a tile or a
-- rail entry shows the page's tabs.
scenarios.navigation_descriptions = function()
    local ns = boot(11509)
    local Nav = ns.Nav
    for _, page in ipairs(Nav.Pages()) do
        check(type(page.desc) == "string" and page.desc ~= "", page.key .. ": has a description")
        check(#page.desc <= 112, page.key .. ": description fits two lines (" .. #page.desc .. ")")
        for _, tab in ipairs(page.tabs or {}) do
            check(type(tab[1]) == "string" and type(tab[2]) == "string", page.key .. ": tab row")
        end
    end
    Nav.ShowMenu()
    local tile = TALODMainMenu.tiles.economy
    tile:Fire("OnEnter")
    check(GameTooltip:IsOwned(tile) and GameTooltip:IsShown(), "tile hover shows the page's tabs")
    tile:Fire("OnLeave")
    check(not GameTooltip:IsShown(), "tile leave hides it")
    local rail = TALODMainMenu.navRail.buttons.market
    rail:Fire("OnEnter")
    check(GameTooltip:IsOwned(rail), "rail hover shows the page tooltip")
end
