-- TALOD - Auction House helper: a panel next to the Auction House
-- window that gathers prices for you, one click at a time.
--
--   1. Full scan: every auction in one go (legacy QueryAuctionItems getAll
--      on Classic Era, C_AuctionHouse.ReplicateItems on the newer engine).
--      The server allows one every 15 minutes.
--   2. Search list: the items you need prices for (your profession plan's
--      materials and products, your bags, your crafting products, old
--      prices). Each click searches the next one.
--
-- Every search is one click (the game wants a key or mouse press for each
-- query, and so does this addon: nothing searches by itself). Bind a key
-- with a macro: /click TALODAHNextButton, and press it to go through
-- the list. The results are logged by Prices.lua like any other look.

local ADDON_NAME, ns = ...
local S = ns.Secret
local Style = ns.Style
local COLORS, HEX = Style.COLORS, Style.HEX
local Prices = ns.Prices

local Helper = {}
ns.AHHelper = Helper

local FULL_SCAN_COOLDOWN = 15 * 60
local FRESH = 30 * 60           -- items seen this recently are not searched again
local RESULT_TIMEOUT = 5        -- seconds without a result = none listed
local SCAN_TIMEOUT = 90
local MAX_PER_SOURCE = 40

local SOURCES = {
    { key = "plan", label = "Plan", tip = "Your profession plan: materials, what you make on the way, the products." },
    { key = "bags", label = "Bags", tip = "What is in your bags (not soulbound): to know where to sell it." },
    { key = "crafting", label = "Crafting", tip = "Your known recipes' products and materials: crafting profit." },
    { key = "stale", label = "Old", tip = "Items whose last look is over a day old." },
}

local panel
local state = { queue = {}, index = 1, waiting = nil, results = {}, scan = nil, message = nil }

local function db() return ns.DB() end
local function Money(c) return ns.Professions.Money(c) end

local function Modern()
    return type(C_AuctionHouse) == "table" and type(C_AuctionHouse.SendSearchQuery) == "function"
end

---------------------------------------------------------------------------
-- The search list
---------------------------------------------------------------------------
local function Fresh(id)
    local e = Prices.Entry(id)
    return e and time() - e.t < FRESH
end

function Helper.BuildQueue()
    local list, seen = {}, {}
    local function Add(id, why)
        if type(id) ~= "number" or seen[id] or Fresh(id) then return end
        seen[id] = true
        list[#list + 1] = { id = id, name = ns.Market.ItemInfo(id), why = why }
    end
    -- What the tracked craft still has to buy comes first, fresh price or not.
    if ns.CraftTrack then
        for _, m in ipairs(ns.CraftTrack.Missing()) do
            if not seen[m.id] then
                seen[m.id] = true
                list[#list + 1] = { id = m.id, name = ns.Market.ItemInfo(m.id), why = "tracked craft: buy " .. m.n }
            end
        end
    end
    local src = db().ahSources
    local P = ns.Professions
    if src.plan and P then
        local prof = db().profPlanProf
        if not prof then
            local c = db().skills[ns.Gear.CharKey() or ""]
            for name in pairs(c and c.current or {}) do if P.DATA.ranks[name] then prof = name break end end
        end
        if prof then
            local plan = P.PlanFor(nil, prof)
            local n = 0
            for _, e in ipairs(plan.shopping or {}) do
                -- Vendor-sold materials only when another source wants them.
                if e.src ~= "vendor" and n < MAX_PER_SOURCE then Add(e.id, prof .. " material") n = n + 1 end
            end
            for _, step in ipairs(plan.steps or {}) do
                for _, p in ipairs(step.prep or {}) do Add(p.item, prof .. ": make or buy") end
            end
            for _, p in ipairs(plan.products or {}) do Add(p.id, prof .. " product") end
        end
    end
    if src.bags then
        local n = 0
        for _, e in ipairs(ns.Market.SellList()) do
            if not e.bound and n < MAX_PER_SOURCE then Add(e.id, "in your bags") n = n + 1 end
        end
    end
    if src.crafting then
        local n = 0
        for _, pr in ipairs(ns.Market.CraftList(ns.Gear.CharKey(), "known")) do
            if n >= MAX_PER_SOURCE then break end
            Add(pr.r.creates, "you can craft it")
            for _, rg in ipairs(pr.r.reagents or {}) do
                local _, how = P.ItemPrice(rg[1])
                if how ~= "vendor" then Add(rg[1], "crafting material") end
            end
            n = n + 1
        end
    end
    if src.stale then
        local old = {}
        for id, e in pairs(Prices.All()) do
            if time() - e.t > 86400 then old[#old + 1] = { id = id, t = e.t } end
        end
        table.sort(old, function(a, b) return a.t < b.t end)
        for i = 1, math.min(#old, MAX_PER_SOURCE) do Add(old[i].id, "last look " .. Prices.Age(old[i].t)) end
    end
    state.queue, state.index, state.waiting, state.results = list, 1, nil, {}
    return list
end

local function Current() return state.queue[state.index] end

-- One search for one item. Returns ok, message.
function Helper.Search(item)
    if not item then return false, "the list is done." end
    if Modern() then
        local AH = C_AuctionHouse
        if type(AH.IsThrottledMessageSystemReady) == "function" and S.Call(AH.IsThrottledMessageSystemReady) == false then
            return false, "the Auction House is busy: click again in a moment."
        end
        -- The window's own search bar: the results show in the Auction House
        -- window (and are logged from its browse results like any look).
        local bar = AuctionHouseFrame and AuctionHouseFrame.SearchBar
        if type(bar) == "table" and type(bar.SearchBox) == "table" and type(bar.StartSearch) == "function" then
            local ok = pcall(function()
                bar.SearchBox:SetText(item.name)
                bar:StartSearch()
            end)
            if ok then
                state.waiting = { id = item.id, at = time(), clock = GetTime() }
                return true, "searching " .. item.name .. " (shown in the Auction House window)..."
            end
        end
        if type(AH.MakeItemKey) ~= "function" then return false, "this client cannot search by item." end
        local ok, key = pcall(AH.MakeItemKey, item.id)
        if not ok or not key then return false, "no item key for " .. item.name .. "." end
        local order = (Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price) or 0
        if not pcall(AH.SendSearchQuery, key, { { sortOrder = order, reverseSort = false } }, false) then
            return false, "the Auction House did not take the search."
        end
    elseif type(QueryAuctionItems) == "function" then
        if type(CanSendAuctionQuery) == "function" and not CanSendAuctionQuery() then
            return false, "the Auction House is busy: click again in a moment."
        end
        -- Exact name: only this item, all its auctions on the first page.
        if not pcall(QueryAuctionItems, item.name, nil, nil, 0, nil, nil, false, true, nil) then
            return false, "the Auction House did not take the search."
        end
    else
        return false, "no Auction House search on this client."
    end
    state.waiting = { id = item.id, at = time(), clock = GetTime() }
    return true, "searching " .. item.name .. "..."
end

function Helper.IsOpen()
    local host = AuctionHouseFrame or AuctionFrame
    return state.open == true and host ~= nil and host.IsShown ~= nil and host:IsShown() == true
end

-- A click on an item elsewhere (the Market window) while the Auction House is
-- open: one search for it in the window's own browse view, so the auctions
-- show there. Leaves the search list alone; nothing while a full scan runs.
-- Returns ok, message.
function Helper.Lookup(id)
    if type(id) ~= "number" or not db().ahLookupClick or not Helper.IsOpen() then return false end
    if state.scan then return false, "a full scan is running." end
    local name = ns.Market.ItemInfo(id)
    if type(name) ~= "string" or name == "" then return false, "the item name is not loaded yet: click again." end
    if Modern() then
        local AH = C_AuctionHouse
        if type(AH.IsThrottledMessageSystemReady) == "function" and S.Call(AH.IsThrottledMessageSystemReady) == false then
            return false, "the Auction House is busy: click again in a moment."
        end
        local f, bar = AuctionHouseFrame, AuctionHouseFrame and AuctionHouseFrame.SearchBar
        if type(bar) ~= "table" or type(bar.SearchBox) ~= "table" or type(bar.StartSearch) ~= "function" then
            return false, "no search bar in the Auction House window."
        end
        local ok = pcall(function()
            -- The Sell / Auctions tabs hide the browse results.
            if type(f.SetDisplayMode) == "function" and AuctionHouseFrameDisplayMode and AuctionHouseFrameDisplayMode.Buy then
                f:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)
            end
            bar.SearchBox:SetText(name)
            bar:StartSearch()
        end)
        if not ok then return false, "the Auction House did not take the search." end
    else
        if type(CanSendAuctionQuery) == "function" and not CanSendAuctionQuery() then
            return false, "the Auction House is busy: click again in a moment."
        end
        -- The Browse tab's own search, so its list shows the result.
        local ok = pcall(function()
            if type(AuctionFrameTab_OnClick) == "function" and AuctionFrameTab1 then AuctionFrameTab_OnClick(AuctionFrameTab1) end
            BrowseName:SetText(name)
            AuctionFrameBrowse_Search()
        end)
        if not ok then
            if type(QueryAuctionItems) ~= "function" or not pcall(QueryAuctionItems, name, nil, nil, 0, nil, nil, false, true, nil) then
                return false, "the Auction House did not take the search."
            end
        end
    end
    return true, "searching " .. name .. " in the Auction House window..."
end

-- The click: search the current item (or, while one is pending, nothing).
function Helper.Next()
    if state.waiting then return false, "waiting for " .. (Current() and Current().name or "the result") .. "..." end
    if #state.queue == 0 or state.index > #state.queue then Helper.BuildQueue() end
    if #state.queue == 0 then return false, "nothing to search: everything was seen in the last 30 minutes." end
    local ok, msg = Helper.Search(Current())
    state.message = msg
    return ok, msg
end

function Helper.Skip()
    state.waiting = nil
    state.index = state.index + 1
end

-- Called on a timer: did the result arrive?
local function CheckResult()
    local w = state.waiting
    if not w then return end
    local e = Prices.Entry(w.id)
    local item = Current()
    if e and e.t >= w.at then
        state.results[w.id] = { p = e.p, n = e.n, a = e.a }
        state.message = string.format("%s: %s each  ·  %s auctions, %s units", item and item.name or "?", Money(e.p), tostring(e.a or "?"), tostring(e.n or "?"))
    elseif GetTime() - w.clock > RESULT_TIMEOUT then
        state.results[w.id] = { none = true }
        state.message = (item and item.name or "?") .. ": none listed (or no answer)."
    else
        return
    end
    state.waiting = nil
    state.index = state.index + 1
end
Helper.CheckResult = CheckResult

---------------------------------------------------------------------------
-- Full scan
---------------------------------------------------------------------------
local muted = {}

local function Mute()
    if type(GetFramesRegisteredForEvent) ~= "function" then return end
    for _, f in ipairs({ GetFramesRegisteredForEvent("AUCTION_ITEM_LIST_UPDATE") }) do
        if f ~= ns.eventFrame then
            f:UnregisterEvent("AUCTION_ITEM_LIST_UPDATE")
            muted[#muted + 1] = f
        end
    end
end

local function Unmute()
    for _, f in ipairs(muted) do pcall(f.RegisterEvent, f, "AUCTION_ITEM_LIST_UPDATE") end
    muted = {}
end

-- Every full scan's outcome, newest last: { t, realm, ok, result, rows,
-- items, new, changed, seconds }. Printed to chat as it happens.
local MAX_SCAN_LOG = 50

function Helper.LogScan(ok, result, extra)
    local log = db().ahScanLog
    if type(log) ~= "table" then log = {} db().ahScanLog = log end
    local e = { t = time(), c = ns.Store.Me(), realm = Prices.RealmKey(), ok = ok, result = result,
        seconds = state.scan and math.floor(GetTime() - state.scan.clock + 0.5) or nil }
    for k, v in pairs(extra or {}) do e[k] = v end
    log[#log + 1] = e
    while #log > MAX_SCAN_LOG do table.remove(log, 1) end
    ns.Print(Helper.ScanText(e))
    -- The panel shows the outcome at once (its own update only runs while a scan is pending).
    if C_Timer and C_Timer.After then C_Timer.After(0, function() Helper.Refresh() end) end
    return e
end

function Helper.ScanText(e)
    if e.ok then
        return string.format("%sFull scan done|r%s: %d auctions, %d items with a price: %d new, %d changed.", HEX.good,
            e.seconds and (" in " .. e.seconds .. " s") or "", e.rows or 0, e.items or 0, e.new or 0, e.changed or 0)
    end
    return HEX.bad .. "Full scan failed|r: " .. tostring(e.result) .. (e.seconds and (HEX.muted .. " (after " .. e.seconds .. " s)|r") or "")
end

function Helper.NextFullScan()
    local last = db().ahFullScan[Prices.RealmKey() or "?"]
    local wait = last and (last + FULL_SCAN_COOLDOWN - time()) or 0
    return math.max(0, wait), last
end

local function ScanDone(items, rows, stats)
    Unmute()
    Prices.fullScanPending = nil
    local e = Helper.LogScan(true, "done", { rows = rows, items = items, new = stats and stats.new or 0, changed = stats and stats.changed or 0 })
    state.scan = nil
    state.message = Helper.ScanText(e)
    Helper.Refresh()
    ns.Data.Notify("prices")
end

-- Stops a full scan the server has not answered (the next one may go at once:
-- an unanswered scan may not have counted).
function Helper.CancelScan(reason)
    if not state.scan or state.scan.reading then return false end
    Helper.LogScan(false, reason or "cancelled")
    Unmute()
    Prices.fullScanPending, state.scan = nil, nil
    db().ahFullScan[Prices.RealmKey() or "?"] = nil
    return true
end

function Helper.FullScan()
    if state.scan then
        if not state.scan.reading and Helper.CancelScan() then return false, "full scan cancelled." end
        return false, "a full scan is being read."
    end
    local wait = Helper.NextFullScan()
    if wait > 0 then return false, string.format("the next full scan is possible in %d:%02d.", math.floor(wait / 60), wait % 60) end
    if Modern() then
        if type(C_AuctionHouse.ReplicateItems) ~= "function" then return false, "this client has no full scan." end
        state.scan = { kind = "modern", clock = GetTime() }
        if not pcall(C_AuctionHouse.ReplicateItems) then
            Helper.LogScan(false, "refused by the Auction House")
            state.scan = nil
            return false, "the Auction House refused the full scan."
        end
    else
        if type(QueryAuctionItems) ~= "function" then return false, "no Auction House on this client." end
        if type(CanSendAuctionQuery) == "function" and not select(2, CanSendAuctionQuery()) then
            return false, "the server does not allow a full scan yet (one every 15 minutes)."
        end
        -- The Blizzard window would draw every row: it is muted until the read is done.
        if ITEM_QUALITY_COLORS and not ITEM_QUALITY_COLORS[-1] then ITEM_QUALITY_COLORS[-1] = { r = 0, g = 0, b = 0 } end
        Mute()
        Prices.fullScanPending = true
        state.scan = { kind = "legacy", clock = GetTime() }
        if not pcall(QueryAuctionItems, "", nil, nil, 0, nil, nil, true, false, nil) then
            Helper.LogScan(false, "refused by the Auction House")
            Unmute()
            Prices.fullScanPending, state.scan = nil, nil
            return false, "the Auction House refused the full scan."
        end
    end
    db().ahFullScan[Prices.RealmKey() or "?"] = time()
    state.message = "Full scan sent: the server answers in a few seconds to a minute."
    return true, state.message
end

-- The read itself broke (an error, or it stopped moving): the answer was
-- received, so the 15 minutes count; say so instead of hanging on "Reading".
local function ReadFailed(reason)
    if not state.scan then return end
    Helper.LogScan(false, reason)
    Unmute()
    Prices.fullScanPending, state.scan = nil, nil
    state.message = HEX.bad .. "Full scan failed|r: " .. reason
    Helper.Refresh()
end

local function OnScanData(kind)
    if not state.scan or state.scan.kind ~= kind or state.scan.reading then return end
    state.scan.reading = true
    -- Both lists give min bid (8), increment (9), current bid (11) and "you
    -- are the high bidder" (12): the bids under the buyouts (Prices.RecordBids).
    -- (next bid nil: no bid possible; the row still names the API, so a scan
    -- without a single bid clears the old ones.)
    local function Bid(v, band, api)
        return { Prices.LegacyNextBid(v[8], v[9], v[11]), band, v[12] == true or v[12] == 1, type(v[11]) == "number" and v[11] > 0, api }
    end
    if kind == "modern" then
        local AH = C_AuctionHouse
        -- [VERIFY] GetReplicateItemTimeLeft on Forever (Enum band 0-3); without it the time left is unknown.
        local left = type(AH.GetReplicateItemTimeLeft) == "function" and AH.GetReplicateItemTimeLeft or nil
        Prices.ReadBulk(function() return S.Call(AH.GetNumReplicateItems) end, function(i)
            local v = { S.CallMulti(17, AH.GetReplicateItemInfo, i) }
            local band = left and S.Call(left, i)
            return v[3], v[10], v[17], v[1], v[14], Bid(v, type(band) == "number" and band + 1 or nil, "modern")
        end, 0, ScanDone, ReadFailed)
    else
        Prices.fullScanPending = nil
        Prices.ReadBulk(function() return S.Call(GetNumAuctionItems, "list") end, function(i)
            local v = { S.CallMulti(17, GetAuctionItemInfo, "list", i) }
            local band = type(GetAuctionItemTimeLeft) == "function" and S.Call(GetAuctionItemTimeLeft, "list", i) or nil
            return v[3], v[10], v[17], v[1], v[14], Bid(v, band, "legacy")
        end, 1, ScanDone, ReadFailed)
    end
end

local READ_STALL = 30

-- Runs from the module tick, not the panel: the panel can be closed (Escape)
-- while the Auction House stays open, and the scan must still be read or end.
local function CheckScanTimeout()
    if state.scan and state.scan.reading then
        local idle = Prices.BulkIdle()
        if not idle then
            -- Read gone without its done/fail call.
            ReadFailed("the read stopped")
        elseif idle > READ_STALL then
            local done, total = Prices.BulkProgress()
            Prices.CancelBulk()
            ReadFailed(string.format("the read stopped at %d / %d", done or 0, total or 0))
        end
        return
    end
    -- The data may arrive without its event (or the event may not exist here): look for it.
    if state.scan and state.scan.kind == "modern" and GetTime() - state.scan.clock > 2
        and type(C_AuctionHouse) == "table" and type(C_AuctionHouse.GetNumReplicateItems) == "function" then
        local n = S.Call(C_AuctionHouse.GetNumReplicateItems)
        if type(n) == "number" and n > 0 then OnScanData("modern") return end
    end
    if state.scan and not state.scan.reading and GetTime() - state.scan.clock > SCAN_TIMEOUT then
        Helper.LogScan(false, "no answer from the server in " .. SCAN_TIMEOUT .. " s")
        Unmute()
        Prices.fullScanPending, state.scan = nil, nil
        state.message = "The full scan got no answer. Try again in 15 minutes."
    end
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------
local function Paint(b, on)
    b.borderColor = on and COLORS.accent or nil
    local c = on and COLORS.accent or COLORS.border
    b:SetBorderColor(c[1], c[2], c[3], 1)
    b.label:SetTextColor(on and 1 or 0.5, on and 1 or 0.5, on and 1 or 0.5)
end

local function Build()
    panel = Style.Window(ns.FRAME .. "AHPanel", "Auction House", 270, 372)
    panel:SetFrameStrata("HIGH")
    local y = -48
    local function Line(text, height)
        local fs = Style.Text(panel, "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", 14, y)
        fs:SetPoint("RIGHT", -14, 0)
        fs:SetText(text)
        y = y - (height or 16)
        return fs
    end
    Line(HEX.gold .. "1. Full scan|r  " .. HEX.muted .. "every price at once, every 15 min|r")
    panel.scanButton = Style.Button(panel, "Full scan", 242, function()
        local _, msg = Helper.FullScan()
        state.message = msg
        Helper.Refresh()
    end, "Asks the Auction House for every auction at once and logs the lowest price and the supply of each item. "
        .. "The server allows one every 15 minutes; it can take a minute.", { height = 26 })
    panel.scanButton:SetPoint("TOPLEFT", 14, y)
    y = y - 32
    panel.scanStatus = Line("", 18)
    local line = Style.HLine(panel)
    line:SetPoint("TOPLEFT", 14, y - 2)
    line:SetPoint("TOPRIGHT", -14, y - 2)
    y = y - 10
    Line(HEX.gold .. "2. Search list|r  " .. HEX.muted .. "one item per click|r")
    panel.sources = {}
    for i, def in ipairs(SOURCES) do
        local b = Style.Button(panel, def.label, 58, function()
            db().ahSources[def.key] = not db().ahSources[def.key]
            Helper.BuildQueue()
            Helper.Refresh()
        end, def.tip, { height = 20, title = def.label })
        b:SetPoint("TOPLEFT", 14 + (i - 1) * 61, y)
        b.key = def.key
        panel.sources[i] = b
    end
    y = y - 28
    -- The button to press (or /click from a macro).
    local next = Style.Button(panel, "", 242, function()
        local _, msg = Helper.Next()
        state.message = msg
        Helper.Refresh()
    end, "Searches the next item of the list on the Auction House. One click, one search. "
        .. "Macro for a key: /click " .. ns.FRAME .. "AHNextButton", { height = 40, title = "Search next" })
    -- Named so a macro can /click it.
    next:SetPoint("TOPLEFT", 14, y)
    _G[ns.FRAME .. "AHNextButton"] = next
    next.sub = Style.Text(next, "GameFontHighlightSmall", "CENTER")
    next.sub:SetPoint("BOTTOM", 0, 5)
    next.label:ClearAllPoints()
    next.label:SetPoint("TOP", 0, -6)
    panel.next = next
    y = y - 46
    panel.barBg = Style.Texture(panel, "ARTWORK", { 1, 1, 1, 0.08 })
    panel.barBg:SetPoint("TOPLEFT", 14, y)
    panel.barBg:SetSize(242, 4)
    panel.bar = Style.Texture(panel, "OVERLAY", COLORS.accent)
    panel.bar:SetPoint("TOPLEFT", 14, y)
    panel.bar:SetHeight(4)
    y = y - 10
    panel.result = Style.Text(panel, "GameFontHighlightSmall")
    panel.result:SetPoint("TOPLEFT", 14, y)
    panel.result:SetPoint("RIGHT", -14, 0)
    panel.result:SetHeight(30)
    panel.result:SetJustifyV("TOP")
    y = y - 34
    panel.skip = Style.Button(panel, "Skip", 118, function() Helper.Skip() Helper.Refresh() end, "Go to the next item without searching.")
    panel.skip:SetPoint("TOPLEFT", 14, y)
    panel.restart = Style.Button(panel, "New list", 118, function() Helper.BuildQueue() Helper.Refresh() end,
        "Builds the list again (items seen in the last 30 minutes are left out).")
    panel.restart:SetPoint("TOPLEFT", 138, y)
    y = y - 30
    panel.hint = Line(HEX.muted .. "Key for it: a macro with /click " .. ns.FRAME .. "AHNextButton|r", 14)
    panel.market = Style.Button(panel, "Open the Auction desk", 242, function() ns.AuctionDeskUI.Show() end,
        "Your listings, deals, margins and what it costs to buy out an item. Also " .. ns.Cmd.Text("ah") .. ".")
    panel.market:SetPoint("TOPLEFT", 14, y - 4)

    local elapsed = 0
    panel:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + (dt or 0)
        if elapsed < 0.2 then return end
        elapsed = 0
        local before = state.index
        CheckResult()
        if before ~= state.index or state.scan then Helper.Refresh() end
    end)
end

function Helper.Refresh()
    if not panel or not panel:IsShown() then return end
    for _, b in ipairs(panel.sources) do Paint(b, db().ahSources[b.key]) end
    -- Full scan.
    local wait = Helper.NextFullScan()
    if state.scan then
        local done, total = Prices.BulkProgress()
        panel.scanButton:SetLabel(done and string.format("Reading %d / %d...", done, total)
            or string.format("Waiting for the server... %ds  (click: cancel)", math.floor(GetTime() - state.scan.clock)))
    elseif wait > 0 then
        panel.scanButton:SetLabel(string.format("Full scan in %d:%02d", math.floor(wait / 60), wait % 60))
    else
        panel.scanButton:SetLabel("Full scan")
    end
    local _, last = Helper.NextFullScan()
    local log = db().ahScanLog
    local lastScan = type(log) == "table" and log[#log] or nil
    if lastScan then
        panel.scanStatus:SetText((lastScan.ok and HEX.good .. "Last: done|r" or (HEX.bad .. "Last: failed|r")) .. HEX.muted .. "  "
            .. Prices.Age(lastScan.t) .. (lastScan.ok and string.format("  ·  %d items, %d new, %d changed", lastScan.items or 0,
                lastScan.new or 0, lastScan.changed or 0) or ("  ·  " .. tostring(lastScan.result))) .. "|r")
        panel.scanStatus.tip = lastScan
    else
        -- Counting walks every price of the realm: only when it is shown
        -- (this redraw runs 5 times a second during a scan).
        panel.scanStatus:SetText(HEX.muted .. Prices.Count() .. " items logged" .. (last and ("  ·  last full scan " .. Prices.Age(last)) or "") .. "|r")
    end
    -- Search list.
    local total = #state.queue
    local item = Current()
    if total == 0 then
        panel.next:SetLabel("Search next")
        panel.next.sub:SetText(HEX.muted .. "click to build the list|r")
    elseif not item then
        panel.next:SetLabel(HEX.good .. "List done|r")
        panel.next.sub:SetText(HEX.muted .. total .. " items searched: click for a new list|r")
    else
        panel.next:SetLabel(string.format("Search next  %d / %d", state.index, total))
        panel.next.sub:SetText(ns.Market.ItemText(item.id) .. HEX.muted .. "  " .. item.why .. "|r")
    end
    panel.bar:SetWidth(math.max(1, 242 * (total > 0 and math.min(1, (state.index - 1) / total) or 0)))
    panel.result:SetText(state.message or (HEX.muted .. "Results show here. Prices go to the Market window and the planner.|r"))
end

local function Show()
    if not db().ahHelper then return end
    if not panel then Build() end
    panel:ClearAllPoints()
    local host = AuctionHouseFrame or AuctionFrame
    if host and host.IsShown and host:IsShown() then
        panel:SetPoint("TOPLEFT", host, "TOPRIGHT", 6, 0)
    else
        panel:SetPoint("RIGHT", UIParent, "RIGHT", -40, 0)
    end
    if #state.queue == 0 then Helper.BuildQueue() end
    panel:Show()
    Helper.Refresh()
end
Helper.Show = Show

local function OnEvent(event, ...)
    if event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        local addon, fn = ...
        if S.Value(addon) ~= ADDON_NAME then return end
        fn = tostring(S.Value(fn) or "?")
        if not (fn:find("AuctionHouse") or fn:find("Auction") or fn:find("SearchBar") or fn:find("Replicate")) then return end
        state.waiting = nil
        Helper.CancelScan("the game blocked " .. fn)
        state.message = HEX.bad .. "The game blocked " .. fn .. ".|r " .. HEX.muted .. "It only allows it from a click on the button "
            .. "(a macro with /click counts). " .. ns.Cmd.Text("errors") .. " has the details.|r"
        ns.Print("the Auction House blocked " .. fn .. " from " .. ns.NAME .. ".")
        Helper.Refresh()
        return
    end
    if event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
        if state.waiting then
            state.waiting = nil
            state.message = HEX.gold .. "The Auction House dropped the search (too many at once): click again.|r"
            Helper.Refresh()
        end
        return
    end
    if event == "AUCTION_HOUSE_SHOW" then
        state.open = true
        if C_Timer and C_Timer.After then C_Timer.After(0, Show) else Show() end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        if panel then panel:Hide() end
        state.open, state.waiting = nil, nil
        if state.scan and not state.scan.reading then
            Helper.LogScan(false, "the Auction House window closed before the answer")
            Unmute()
            Prices.fullScanPending, state.scan = nil, nil
        end
    elseif event == "AUCTION_ITEM_LIST_UPDATE" then
        OnScanData("legacy")
    elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
        OnScanData("modern")
    end
end

-- /talod ah scan (or helper) and /talod ah log; plain /talod ah is the Auction
-- desk (AuctionDesk.lua).
local function Slash(command, rest)
    if command ~= "ah" then return false end
    local sub = (rest or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if sub ~= "log" and sub ~= "scan" and sub ~= "helper" then return false end
    if sub == "log" then
        local log = db().ahScanLog
        if type(log) ~= "table" or #log == 0 then
            ns.Print("no full scans logged yet.")
        else
            ns.Print("full scans, newest first:")
            for i = #log, math.max(1, #log - 9), -1 do
                print("  " .. date("%b %d %H:%M", log[i].t) .. "  " .. (log[i].realm or "?") .. "  " .. Helper.ScanText(log[i]))
            end
        end
        return true
    end
    db().ahHelper = true
    Show()
    return true
end

function Helper.Panel() return panel end
Helper.state = state

ns.RegisterModule("AHHelper", {
    defaults = { ahHelper = true, ahLookupClick = true, ahSources = { plan = true, bags = true, crafting = false, stale = false }, ahFullScan = {} },
    events = { "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "AUCTION_ITEM_LIST_UPDATE", "REPLICATE_ITEM_LIST_UPDATE",
        "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN", "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" },
    onEvent = OnEvent,
    tick = CheckScanTimeout,
    slash = Slash,
})
