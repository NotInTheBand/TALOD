-- Full scan robustness: the scan is read and ends (done or failed, always
-- logged) even when the panel is closed, a chunk errors, or the read stalls.
local scenarios, T = ...
local check, boot, printed = T.check, T.boot, T.printed

local function modernAH(rows)
    C_AuctionHouse = {
        SendSearchQuery = function() end,
        MakeItemKey = function(id) return { itemID = id } end,
        ReplicateItems = function() end,
        GetNumReplicateItems = function() return #rows + (rows.extra or 0) end,
        GetReplicateItemInfo = function(i)
            local r = rows[i + 1]
            if not r then return nil end
            return r[1], nil, r[2], nil, nil, nil, nil, nil, nil, r[3], nil, nil, nil, nil, nil, nil, r[4]
        end,
    }
end

scenarios.ah_scan_robust = function()
    local ns = boot(16001)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    local H, Pr = ns.AHHelper, ns.Prices
    local rows = {}
    modernAH(rows)
    AuctionHouseFrame = CreateFrame("Frame", "AuctionHouseFrame", UIParent)
    MOCK.FireEvent("AUCTION_HOUSE_SHOW")
    MOCK.RunTimers()
    local panel = H.Panel()
    local log = function() return TALODDB.ahScanLog[#TALODDB.ahScanLog] end

    -- Panel closed (Escape) right after the click: the answer is still found and read.
    TALODDB.ahFullScan = {}
    panel.scanButton:Fire("OnClick", "LeftButton")
    check(H.state.scan, "scan sent")
    panel:Hide()
    rows[1] = { "Salt", 10, 300, 4289 }
    rows[2] = { "Salt", 20, 400, 4289 }
    for _ = 1, 15 do MOCK.Tick(0.3) end
    MOCK.RunTimers() MOCK.RunTimers()
    check(not H.state.scan and log() and log().ok and log().rows == 2, "read with the panel hidden: " .. tostring(log() and log().result))
    check(Pr.Entry(4289) and Pr.Entry(4289).p == 20 and Pr.Entry(4289).n == 30, "price recorded: " .. tostring(Pr.Entry(4289) and Pr.Entry(4289).p))

    -- A chunk errors: failed and logged, not stuck on "Reading".
    TALODDB.ahFullScan = {}
    panel:Show()
    for i = 3, 1200 do rows[i] = { "Salt", 1, 50, 4289 } end
    local ladder = Pr.RecordLadder
    Pr.RecordLadder = function() error("bad ladder") end
    panel.scanButton:Fire("OnClick", "LeftButton")
    for _ = 1, 15 do MOCK.Tick(0.3) end
    MOCK.RunTimers() MOCK.RunTimers() MOCK.RunTimers()
    Pr.RecordLadder = ladder
    check(not H.state.scan and log().ok == false and log().result:find("error while reading"), "chunk error: " .. tostring(log().result))
    check(not Pr.Bulk(), "bulk read cleared")
    check(printed("Full scan failed"), "failure said in chat")
    -- The answer came, so the cooldown stands.
    check(H.NextFullScan() > 0, "cooldown kept after a received answer")
    -- The error is kept for /talod errors (and cleared here: it was the test's own).
    local errs = TALODDB.errorLog or {}
    check(#errs == 1 and errs[1].message:find("bad ladder"), "error logged: " .. tostring(errs[1] and errs[1].message))
    TALODDB.errorLog = {}

    -- The read stops moving (a timer never comes back): failed after the stall time.
    TALODDB.ahFullScan = {}
    panel.scanButton:Fire("OnClick", "LeftButton")
    MOCK.Tick(2.5)
    check(H.state.scan and H.state.scan.reading, "reading")
    MOCK.timers = {}
    MOCK.Tick(31) MOCK.Tick(0.3)
    check(not H.state.scan and log().ok == false and log().result:find("read stopped at"), "stall: " .. tostring(log().result))
    check(not Pr.Bulk(), "stalled read cleared")
    C_AuctionHouse = nil
end

-- The Auction House closes (or the list changes) while a full scan is read:
-- failed and logged, the partial read never recorded as the whole AH.
scenarios.ah_scan_closed_midread = function()
    local ns = boot(16001)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    local H, Pr = ns.AHHelper, ns.Prices
    local rows = {}
    modernAH(rows)
    AuctionHouseFrame = CreateFrame("Frame", "AuctionHouseFrame", UIParent)
    MOCK.FireEvent("AUCTION_HOUSE_SHOW")
    MOCK.RunTimers()
    local panel = H.Panel()
    local log = function() return TALODDB.ahScanLog[#TALODDB.ahScanLog] end
    for i = 1, 1200 do rows[i] = { "Salt", 1, 50, i <= 600 and 4289 or 2589 } end

    TALODDB.ahFullScan = {}
    panel.scanButton:Fire("OnClick", "LeftButton")
    MOCK.Tick(2.5)
    check(H.state.scan and H.state.scan.reading and Pr.Bulk(), "reading")
    MOCK.FireEvent("AUCTION_HOUSE_CLOSED")
    MOCK.RunTimers() MOCK.RunTimers() MOCK.RunTimers()
    check(not H.state.scan and log().ok == false and log().result:find("closed during the read"), "closed: " .. tostring(log().result))
    check(not Pr.Bulk() and not Pr.Entry(2589), "nothing recorded from the rows never read")

    -- The list shrinks under the read (a new query): stopped, not counted as done.
    MOCK.FireEvent("AUCTION_HOUSE_SHOW")
    MOCK.RunTimers()
    TALODDB.ahFullScan = {}
    H.Panel().scanButton:Fire("OnClick", "LeftButton")
    MOCK.Tick(2.5)
    check(H.state.scan and H.state.scan.reading, "reading again")
    rows.extra = -700
    MOCK.RunTimers() MOCK.RunTimers() MOCK.RunTimers()
    check(not H.state.scan and log().ok == false and log().result:find("list changed"), "list changed: " .. tostring(log().result))
    check(not Pr.Entry(2589), "still nothing recorded for the unread item")
    C_AuctionHouse = nil
end
