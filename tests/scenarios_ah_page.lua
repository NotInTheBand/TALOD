-- The Auction House page (MarketUI + AuctionDeskUI) and the Gold page
-- (EconomyUI): both looks, every tab and view through ShowPage, the merged
-- Deals list, My auctions across live listings and the posting log of every
-- character, By item, Prices with the control plan only for a full look, one
-- search / one full scan per click, the old commands and old Show calls, the
-- title bar (full scan, scan panel, scan log) and the page status lines.
local scenarios, T = ...
local check, boot, slash, printed = T.check, T.boot, T.slash, T.printed

local LINEN, WOOL, SALT, SILK = 2589, 2592, 4289, 4306

local function itemInfo()
    function GetItemInfo(id)
        if id == LINEN then return "Linen Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132889, 13, 7, 5, 0 end
        if id == WOOL then return "Wool Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132911, 33, 7, 5, 0 end
        if id == SALT then return "Salt", nil, 1, 5, 0, "Trade Goods", "Other", 20, "", 132891, 10, 7, 5, 0 end
        if id == SILK then return "Silk Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132905, 38, 7, 5, 0 end
    end
end

local function setup(opts)
    itemInfo()
    local ns = boot(11509, opts)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    return ns
end

local function plain(text) return (tostring(text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end

-- Linen: usual 100c, a deal at 10c with a ladder; salt with a ladder where
-- others undercut you; wool seen once (no ladder).
local function market(ns)
    local Pr = ns.Prices
    local now = time()
    Pr.Record(LINEN, 100, 30, now - 3 * 86400, 3, "Linen Cloth")
    Pr.Record(LINEN, 100, 30, now - 2 * 86400, 3)
    Pr.Record(LINEN, 100, 30, now - 86400, 3)
    Pr.Record(LINEN, 10, 30, now, 3)
    Pr.RecordLadder(LINEN, { { 10, 5, "Al" }, { 20, 10, "Bo" }, { 100, 20, "Al" } }, false, now)
    Pr.Record(SALT, 20, 10, now, 2, "Salt")
    Pr.RecordLadder(SALT, { { 15, 5, "Al" }, { 20, 5, "Tester", true } }, false, now)
    Pr.Record(WOOL, 50, 10, now, 2, "Wool Cloth")
    ns.Data.Changed("prices")
    ns.AuctionDesk.Invalidate()
end

-- This character's posting log, another character's, and the live list.
local function myAuctions(ns)
    local now = time()
    local me = ns.Gear.CharKey()
    local linen, salt, wool = MOCK.ItemLink(LINEN, "Linen Cloth"), MOCK.ItemLink(SALT, "Salt"), MOCK.ItemLink(WOOL, "Wool Cloth")
    local c = ns.Economy.Char()
    c.auctions = {
        { name = salt, count = 5, buyout = 100, deposit = 20, duration = "48 h", status = "listed", t = now - 600 },
        { name = linen, count = 20, buyout = 2000, deposit = 40, status = "sold", received = 1940, t = now - 86400, closedAt = now - 3600 },
        { name = linen, count = 20, buyout = 2000, deposit = 40, status = "expired", t = now - 3 * 86400, ended = now - 86400 },
        { name = wool, count = 10, buyout = 900, deposit = 30, status = "cancelled", t = now - 2 * 86400, ended = now - 2 * 86400 },
    }
    TALODDB.economy["Other-Realm"] = { log = {}, days = {}, auctions = {
        { name = wool, count = 10, buyout = 800, deposit = 30, duration = "24 h", status = "listed", t = now - 1200 },
        { name = linen, count = 20, buyout = 2200, deposit = 40, status = "sold", received = 2130, t = now - 5 * 86400, closedAt = now - 4 * 86400 },
    } }
    TALODDB.ahOwned = { [me] = { t = now, realm = ns.Prices.RealmKey(), list = { { id = SALT, count = 5, unit = 20 } } } }
    ns.Data.Changed("economy")
    ns.Data.Changed("prices")
    ns.Market.InvalidateSales()
    ns.AuctionDesk.Invalidate()
end

-- A legacy Auction House window: browse searches and getAll scans counted.
local function legacyAH(ns)
    local seen = { browse = {}, all = 0 }
    AuctionFrame = CreateFrame("Frame", "AuctionFrame", UIParent)
    AuctionFrameTab1 = CreateFrame("Button", "AuctionFrameTab1", AuctionFrame)
    function AuctionFrameTab_OnClick() end
    BrowseName = CreateFrame("EditBox", "BrowseName", AuctionFrame)
    function AuctionFrameBrowse_Search() seen.browse[#seen.browse + 1] = BrowseName:GetText() end
    function CanSendAuctionQuery() return true, true end
    function QueryAuctionItems(_, _, _, _, _, _, getAll) if getAll then seen.all = seen.all + 1 end end
    function GetNumAuctionItems() return 0, 0 end
    MOCK.FireEvent("AUCTION_HOUSE_SHOW")
    MOCK.RunTimers()
    return seen
end

local function rowFor(list, id)
    for _, r in ipairs(list.rows) do
        if r.item and r.item.id == id and r:IsShown() then return r end
    end
end

local function allTabs(ns, label)
    local M = ns.MarketUI
    local want = {
        { "today", nil, "today" }, { "buy", "Deals", "deals" }, { "buy", "Bids", "bids" }, { "sell", nil, "sell" },
        { "mine", "Auctions", "mine" }, { "mine", "By item", "sellthrough" }, { "prices", nil, "prices" },
        { "ah/buy", "bids", "bids" }, { "mine", "byitem", "sellthrough" },
    }
    for _, w in ipairs(want) do
        check(M.ShowPage(w[1], w[2]) and M.IsShown(), label .. ": opens " .. w[1])
        check(M.state.view == w[3], label .. ": " .. w[1] .. " / " .. tostring(w[2]) .. " -> " .. tostring(M.state.view))
        local f = M.Frame()
        check(f.tabs.selected == M.VIEW_TAB[w[3]], label .. ": tab marked " .. tostring(f.tabs.selected))
        local sw = f.switches[M.VIEW_TAB[w[3]]]
        if sw then check(sw:IsShown() and sw.selected == w[3], label .. ": view switch on " .. w[3]) end
        for tab, other in pairs(f.switches) do
            if tab ~= M.VIEW_TAB[w[3]] then check(not other:IsShown(), label .. ": other view switch hidden") end
        end
    end
    -- A tab remembers its last view.
    M.ShowPage("buy", "bids")
    M.ShowPage("sell")
    M.ShowPage("buy")
    check(M.state.view == "bids", label .. ": Buy reopens on Bids")
    -- Crafting is not on the page (Professions > Profit).
    check(M.views.crafting == nil and M.views.margins == nil, label .. ": no crafting or margins view")
    -- Gold: three tabs, the old Auctions tab opens My auctions.
    local G = ns.EconomyUI
    for _, tab in ipairs({ "overview", "transactions", "trades", "gold/trades" }) do
        check(G.ShowPage(tab) and G.IsShown(), label .. ": gold " .. tab)
        check(G.state.view == tab:gsub("^gold/", ""), label .. ": gold on " .. tab)
    end
    check(G.views.auctions == nil, label .. ": no Auctions tab on Gold")
    G.ShowPage("auctions")
    check(M.IsShown() and M.state.view == "mine", label .. ": gold auctions -> My auctions")
end

scenarios.ah_page_ledger = function()
    local ns = setup()
    check(ns.Style.Look() == "ledger", "ledger look")
    market(ns)
    myAuctions(ns)
    allTabs(ns, "ledger")
    local f = ns.MarketUI.Frame()
    check(f.fullScan.kind == "send" and f.fullScan.glyph, "Full scan carries the send mark")
    check(plain(f.status:GetText()):find("Auction house: ", 1, true), "realm in the title bar: " .. plain(f.status:GetText()))
    check(f.gear, "the page's settings gear")
end

scenarios.ah_page_classic = function()
    local ns = setup({ db = { classicLook = true } })
    check(ns.Style.Look() == "classic", "classic look")
    market(ns)
    myAuctions(ns)
    allTabs(ns, "classic")
end

-- Buy > Deals: the Market's columns and the desk's in one list.
scenarios.ah_page_deals = function()
    local ns = setup()
    market(ns)
    local M = ns.MarketUI
    M.ShowPage("buy", "deals")
    local v = M.views.deals
    local cols = {}
    for c = 1, 6 do cols[#cols + 1] = v.list.headItem.cols[c] end
    local titles = table.concat(cols, ",")
    for _, t in ipairs({ "Gain", "Cost", "Units", "Under", "Usual", "Each" }) do
        check(titles:find(t, 1, true), "deals column " .. t .. ": " .. titles)
    end
    local row
    for _, it in ipairs(v.list.all) do if it.id == LINEN then row = ns.Style.ReadyRow(it) end end
    check(row, "linen is a deal")
    -- Market: each 10c, usual 1s, under -90%. Desk: 15 units under the deal price (5 at 10c, 10 at 20c), 2s 50c.
    check(plain(row.cols[6]):find("10c") and plain(row.cols[5]):find("1s") and plain(row.cols[4]):find("%-90%%"),
        "market columns: " .. plain(row.cols[6]) .. " / " .. plain(row.cols[5]) .. " / " .. plain(row.cols[4]))
    check(row.cols[3] == "15" and plain(row.cols[2]):find("2s 50c") and plain(row.cols[1]):find("%+"),
        "desk columns: " .. tostring(row.cols[3]) .. " / " .. plain(row.cols[2]) .. " / " .. plain(row.cols[1]))
    check(#v.list.headItem.cols >= 6 and v.list.colWidths[6], "six columns drawn")
    local r = rowFor(v.list, LINEN)
    check(r and r.cols[6] and plain(r.cols[6]:GetText()):find("10c"), "the sixth column is on the row")
end

-- My auctions: live listings (this character, with standing) and every post
-- of every character, filtered by the status chips.
scenarios.ah_page_my_auctions = function()
    local ns = setup()
    market(ns)
    myAuctions(ns)
    local M = ns.MarketUI
    M.ShowPage("mine", "auctions", "all")
    local v = M.views.mine
    local function ids(status)
        v.chips:Select(status)
        M.state.mineFilter = status
        M.Refresh()
        local out = {}
        for _, it in ipairs(v.list.all) do
            if not it.header and it.id then out[#out + 1] = ns.Style.ReadyRow(it) end
        end
        return out
    end
    local all = ids("all")
    -- Live salt (the posting log's listed salt is the same auction, not twice), the
    -- other character's listed wool, two linen and one wool closed here, one linen sold there.
    check(#all == 6, "every auction once: " .. #all)
    local listed = ids("listed")
    check(#listed == 2, "listed: the live listing and the other character's: " .. #listed)
    local salt
    for _, r in ipairs(listed) do if r.id == SALT then salt = r end end
    check(salt and type(salt.cols[4]) == "table" and salt.cols[4].tone == "bad" and salt.cols[4].tag:find("undercut"),
        "standing in a trade tone: " .. tostring(salt and type(salt.cols[4]) == "table" and salt.cols[4].tone))
    check(plain(salt.cols[5]):find("15c"), "lowest now: " .. plain(salt.cols[5]))
    check(salt.cols[2] ~= ns.UNKNOWN, "posting time from the log")
    for _, r in ipairs(listed) do
        local tone = type(r.cols[4]) == "table" and r.cols[4].tone or (r.cols[4] == ns.UNKNOWN and "unknown")
        check(tone ~= "safe" and tone ~= "danger" and tone ~= "threshold", "never a safety tone: " .. tostring(tone))
    end
    local sold = ids("sold")
    check(#sold == 2, "sold on both characters: " .. #sold)
    for _, r in ipairs(sold) do check(r.cols[4].tag == "sold" and r.cols[4].tone == "good", "sold tag") end
    check(#ids("expired") == 1 and #ids("cancelled") == 1, "expired and cancelled")
    ids("all")
    check(v.chips:IsOn("all"), "chip on")
    local counts = {}
    for _, b in ipairs(v.chips.chips) do counts[b.key] = b.count:GetText() end
    check(counts.all == "6" and counts.listed == "2" and counts.sold == "2" and counts.expired == "1" and counts.cancelled == "1",
        "chip counts")
    local sub = plain(v.card.sub:GetText())
    check(sub:find("2 listed", 1, true) and sub:find("1 undercut", 1, true) and sub:find("2 sold", 1, true), "summary: " .. sub)
    -- The chips themselves filter.
    for _, b in ipairs(v.chips.chips) do
        if b.key == "sold" then b:Fire("OnClick", "LeftButton") end
    end
    check(M.state.mineFilter == "sold" and #v.list.all == 2, "a chip click filters: " .. #v.list.all)
    -- Old desk Listings: My auctions, listed only.
    ns.AuctionDeskUI.Show("listings")
    check(M.state.view == "mine" and M.state.mineFilter == "listed", "desk listings -> listed")
end

-- By item: the old Sell-through, same numbers.
scenarios.ah_page_by_item = function()
    local ns = setup()
    market(ns)
    myAuctions(ns)
    local M = ns.MarketUI
    M.Show("sellthrough")
    check(M.state.view == "sellthrough" and M.Frame().tabs.selected == "mine", "old Sell-through key -> My auctions > By item")
    local sold, failed = 0, 0
    for _, e in ipairs(ns.Market.SellThroughList()) do sold, failed = sold + e.sales.sold, failed + e.sales.failed end
    local sub = M.views.sellthrough.card.sub:GetText()
    check(sub:find(sold .. " sold", 1, true) and sub:find(failed .. " unsold", 1, true), "sell-through totals: " .. sub)
end

-- Prices: the control plan only for an item with a full look; the chips.
scenarios.ah_page_prices_control = function()
    local ns = setup()
    market(ns)
    local M = ns.MarketUI
    M.ShowPage("prices", nil, LINEN)
    local v = M.views.prices
    local function hasSection(name)
        for _, r in ipairs(v.detail.all) do if r.header and plain(r.text):find(name, 1, true) then return true end end
        return false
    end
    check(M.state.selected == LINEN and v.hasControl and hasSection("Own it all") and hasSection("Ladder"), "linen: the plan and ladder")
    M.ShowPage("prices", nil, WOOL)
    check(M.state.selected == WOOL and not v.hasControl and not hasSection("Own it all"), "wool (no full look): no plan")
    check(hasSection("Selling it"), "wool: its prices")
    -- With a full look: only items with a ladder, the desk's columns.
    for _, b in ipairs(v.chips.chips) do if b.key == "full" then b:Fire("OnClick", "LeftButton") end end
    check(M.state.priceFilter == "full", "full-look chip")
    local seen = {}
    for _, it in ipairs(v.list.all) do if it.id then seen[it.id] = true end end
    check(seen[LINEN] and seen[SALT] and not seen[WOOL], "only items with a ladder listed")
    check(M.state.selected ~= WOOL and v.hasControl, "the selection moved to one with a plan")
    check(v.list.headItem.text == "Item" and plain(v.list.headItem.cols[1]):find("Own it all"), "desk columns")
    for _, b in ipairs(v.chips.chips) do if b.key == "all" then b:Fire("OnClick", "LeftButton") end end
    check(M.state.priceFilter == "all" and plain(v.list.headItem.cols[3]):find("Price"), "back to every item")
    -- /talod ah <item>: the plan scrolled into view.
    slash("ah linen")
    check(M.state.view == "prices" and M.state.selected == LINEN and M.state.priceFilter == "full", "/talod ah linen")
    local first = v.detail.items[v.detail.offset + 1]
    check(first and first.control, "opened at its ladder section")
end

-- One click = one search (rows, the detail's button) and one full scan per
-- click with the server's limit; nothing from the page while the AH is closed.
scenarios.ah_page_one_click = function()
    local ns = setup()
    market(ns)
    myAuctions(ns)
    local M = ns.MarketUI
    M.ShowPage("prices", nil, LINEN)
    local v = M.views.prices
    check(not v.lookup:IsEnabled() and v.lookup.why == "open the Auction House first", "search button off while closed")
    v.lookup:Fire("OnClick", "LeftButton")
    local seen = legacyAH(ns)
    check(#seen.browse == 0, "nothing searched while closed")
    M.Refresh()
    check(v.lookup:IsEnabled() and v.lookup.kind == "send", "search button on (send)")
    v.lookup:Fire("OnClick", "LeftButton")
    check(#seen.browse == 1 and seen.browse[1] == "Linen Cloth", "one search from the button")
    -- The button searches even with row clicks set not to.
    TALODDB.ahLookupClick = false
    v.lookup:Fire("OnClick", "LeftButton")
    check(#seen.browse == 2, "the button is its own click")
    local r = rowFor(v.list, SALT)
    r:Fire("OnClick", "LeftButton")
    check(#seen.browse == 2, "row clicks follow the setting")
    TALODDB.ahLookupClick = true
    -- Each list: one click, one search.
    local n = #seen.browse
    for _, spec in ipairs({ { "prices", nil, SALT }, { "buy", "deals", LINEN }, { "mine", "auctions", SALT } }) do
        M.ShowPage(spec[1], spec[2], spec[1] == "mine" and "all" or nil)
        local list = M.views[M.state.view].list
        local row = rowFor(list, spec[3])
        check(row, "row drawn on " .. spec[1])
        row:Fire("OnClick", "LeftButton")
        n = n + 1
        check(#seen.browse == n, spec[1] .. ": one search per click (" .. #seen.browse .. ")")
    end
    -- Full scan: one click, one getAll; then the 15 minutes.
    local f = M.Frame()
    TALODDB.ahFullScan = {}
    M.Refresh()
    check(f.fullScan:IsEnabled() and plain(f.fullScan.label:GetText()) == "Full scan", "full scan ready")
    f.fullScan:Fire("OnClick", "LeftButton")
    check(seen.all == 1, "one full scan per click: " .. seen.all)
    ns.AHHelper.state.scan = nil   -- the answer was read
    M.Refresh()
    check(not f.fullScan:IsEnabled() and plain(f.fullScan.label:GetText()):find("Full scan in 1[45]:"), "the wait shows: "
        .. plain(f.fullScan.label:GetText()))
    f.fullScan:Fire("OnClick", "LeftButton")
    check(seen.all == 1, "no second scan within 15 minutes")
    -- Never from the page's own timer.
    MOCK.Tick(2)
    check(seen.all == 1 and #seen.browse == n, "nothing sent by a tick")
    MOCK.FireEvent("AUCTION_HOUSE_CLOSED")
    TALODDB.ahFullScan = {}
    M.Refresh()
    check(not f.fullScan:IsEnabled() and f.fullScan.why == "open the Auction House first", "closed: no full scan")
end

-- Old words and old Show calls land on the right tab.
scenarios.ah_page_commands = function()
    local ns = setup()
    market(ns)
    local M, G = ns.MarketUI, ns.EconomyUI
    slash("price")
    check(M.IsShown() and M.state.view == "prices", "/talod price -> Prices")
    slash("price")
    check(not M.IsShown(), "/talod price toggles")
    MOCK.prints = {}
    slash("price linen")
    check(M.IsShown() and M.state.view == "prices" and M.state.search == "linen" and M.state.selected == LINEN
        and printed("Linen Cloth"), "/talod price linen: printed and selected")
    slash("ah prices")
    check(M.state.view == "prices", "/talod ah prices")
    M.Frame():Hide()
    slash("ah")
    check(M.IsShown() and M.state.view == "prices", "/talod ah: where you left the page")
    slash("ah buy")
    check(M.state.view == "deals", "/talod ah buy")
    slash("ah mine")
    check(M.state.view == "mine", "/talod ah mine")
    slash("ah sell")
    check(M.state.view == "sell", "/talod ah sell")
    slash("ah today")
    check(M.state.view == "today", "/talod ah today")
    slash("desk")
    check(not M.IsShown(), "/talod desk toggles the same page")
    slash("ah scan")
    check(ns.AHHelper.Panel() and ns.AHHelper.Panel():IsShown(), "/talod ah scan: the scan panel")
    MOCK.prints = {}
    slash("ah log")
    check(printed("no full scans logged yet"), "/talod ah log prints as before")
    -- Old Show keys.
    for key, want in pairs({ prices = "prices", sell = "sell", deals = "deals", bids = "bids", sellthrough = "sellthrough" }) do
        M.Show(key)
        check(M.state.view == want, "MarketUI.Show(" .. key .. ")")
    end
    local go, went = ns.Nav.Go, nil
    ns.Nav.Go = function(page, tab) went = page .. "/" .. tostring(tab) return true end
    M.Show("crafting")
    check(went == "prof/profit", "crafting -> Professions > Profit")
    went = nil
    ns.AuctionDeskUI.Show("margins")
    check(went == "prof/profit", "desk margins -> Professions > Profit")
    ns.Nav.Go = go
    -- Gold.
    slash("economy")
    check(G.IsShown() and G.state.view == "overview", "/talod economy -> Gold")
    slash("gold trades")
    check(G.state.view == "trades", "/talod gold trades")
    slash("gold transactions")
    check(G.state.view == "transactions", "/talod gold transactions")
    slash("gold")
    check(not G.IsShown(), "/talod gold toggles")
end

-- Title bar: scan panel switch (a quick binding), scan log in the report
-- window; the page status lines.
scenarios.ah_page_title_and_status = function()
    itemInfo()
    local ns = boot(11509)
    local bound = {}
    ns.Options.Bind = function(key, kind, where) bound[#bound + 1] = key .. "|" .. kind .. "|" .. where end
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    market(ns)
    myAuctions(ns)
    local M = ns.MarketUI
    M.ShowPage("today")
    check(table.concat(bound, ","):find("ahHelper|quick|ah", 1, true), "scan panel switch bound as a quick switch: " .. table.concat(bound, ","))
    local f = M.Frame()
    TALODDB.ahHelper = true
    M.Refresh()
    check(f.scanPanel.on and plain(f.scanPanel.label:GetText()) == "Scan panel: shown", "shown")
    f.scanPanel:Fire("OnClick", "LeftButton")
    check(TALODDB.ahHelper == false and plain(f.scanPanel.label:GetText()) == "Scan panel: hidden", "hidden")
    f.scanPanel:Fire("OnClick", "LeftButton")
    check(TALODDB.ahHelper == true and ns.AHHelper.Panel():IsShown(), "shown again, panel open")
    TALODDB.ahScanLog = { { t = time() - 60, realm = ns.Prices.RealmKey(), ok = true, rows = 120, items = 40, new = 3, changed = 5 } }
    f.scanLog:Fire("OnClick", "LeftButton")
    check(TALODProbeWindow and TALODProbeWindow:IsShown(), "scan log in the report window")
    check(TALODProbeWindow and M.ScanLogLines()[2]:find("120 auctions", 1, true), "the log line: " .. tostring(M.ScanLogLines()[2]))
    -- Today: six cards, each with its link.
    local today = M.views.today
    check(#today.cards == 6, "six cards")
    for _, card in ipairs(today.cards) do check(card.link and card.link:IsShown(), "card link: " .. card.def.title) end
    today.cards.deals.link:Fire("OnClick", "LeftButton")
    check(M.state.view == "deals", "Deals card -> Buy")
    M.ShowPage("today")
    today.cards.listings.link:Fire("OnClick", "LeftButton")
    check(M.state.view == "mine" and M.state.mineFilter == "listed", "Your listings card -> My auctions, listed")
    -- Status lines: what Today computes.
    local st = M.PageStatus()
    check(st and st.text:find("1 listed", 1, true) and st.text:find("1 undercut", 1, true) and st.text:find("deals", 1, true)
        and st.tone == "bad", "Auction House status: " .. tostring(st and st.text))
    local gs = ns.EconomyUI.PageStatus()
    check(gs and gs.text:find("^Today"), "Gold status: " .. tostring(gs and gs.text))
end
