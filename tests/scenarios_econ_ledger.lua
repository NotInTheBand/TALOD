-- Economy money accounting: auction letters close the listing they are
-- about, the Auctions tab's profit and lost deposits, sent mail to your own
-- character, refunds that are not income, "Today" on a clock-change day and
-- the session net without transfers.
local scenarios, T = ...
local check, boot, slash = T.check, T.boot, T.slash

local LINEN = 2589

-- Classic invoices carry the sale, buyout, deposit and the house's cut.
local function invoices()
    function GetInboxInvoiceInfo(i)
        local m = MOCK.inbox[i]
        if m and m.invoice then return m.invoice, m.item, m.player, m.bid, m.buyout, m.deposit, m.cut end
    end
end

local function start(money)
    MOCK.money = money or 100000
    local ns = boot(11509)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(2.2) MOCK.Tick(0.3)
    local function changed() MOCK.FireEvent("PLAYER_MONEY") MOCK.FireEvent("BAG_UPDATE_DELAYED") MOCK.Tick(0.5) end
    return ns, ns.Economy.Char(), changed
end

-- Posts one stack of linen from bag slot `slot` (classic PostAuction).
local function post(changed, slot, count, buyout, deposit)
    MOCK.sellItem = { "Linen Cloth", count }
    PostAuction(math.floor(buyout / 2), buyout, 3, count, 1)
    MOCK.bags[0][slot] = nil
    MOCK.money = MOCK.money - deposit
    changed()
end

local function linenBags(counts)
    for slot, n in pairs(counts) do
        MOCK.bags[0][slot] = MOCK.ItemLink(LINEN, "Linen Cloth")
        MOCK.bagCounts["0:" .. slot] = n
    end
end

-- Linen posted as 20 (deposit 60c), then 5 (15c), then 1 (3c). The 5-stack
-- sells: its letter must close the 5-stack (the bug: the oldest linen, the
-- 20-stack), the 1-stack is cancelled, the 20-stack expires with its 60c.
scenarios.econ_ledger_listing_match = function()
    invoices()
    linenBags({ [1] = 20, [2] = 5, [3] = 1 })
    local ns, c, changed = start()
    MOCK.FireEvent("AUCTION_HOUSE_SHOW")
    post(changed, 1, 20, 2000, 60)
    post(changed, 2, 5, 500, 15)
    post(changed, 3, 1, 100, 3)
    MOCK.FireEvent("AUCTION_HOUSE_CLOSED")
    MOCK.Tick(4)
    local big, small, one = c.auctions[1], c.auctions[2], c.auctions[3]
    check(big and big.count == 20 and big.deposit == 60 and small and small.count == 5 and small.deposit == 15
        and one and one.count == 1 and one.deposit == 3, "three listings kept")

    -- The 5-stack sold for 500c, cut 25c, deposit 15c back: 490c.
    MOCK.inbox[1] = { sender = "Auction House", subject = "Auction successful: Linen Cloth", money = 490, invoice = "seller",
        item = "Linen Cloth", player = "Bob", bid = 500, buyout = 500, deposit = 15, cut = 25 }
    MOCK.FireEvent("MAIL_SHOW")
    TakeInboxMoney(1)
    changed()
    check(small.status == "sold" and small.received == 490 and small.profit == 475,
        "the sold 5-stack is closed: " .. tostring(small.status) .. " " .. tostring(small.profit))
    check(big.status == "listed", "the 20-stack is still up: " .. tostring(big.status))

    -- The 1-stack cancelled (its stack comes back), then the 20-stack expires.
    MOCK.inbox[2] = { sender = "Auction House", subject = "Auction cancelled: Linen Cloth", items = { { LINEN, "Linen Cloth", 1 } } }
    TakeInboxItem(2)
    linenBags({ [3] = 1 })
    changed()
    check(one.status == "cancelled" and big.status == "listed", "the cancel letter closes the 1-stack: " .. tostring(one.status))
    MOCK.inbox[3] = { sender = "Auction House", subject = "Auction expired: Linen Cloth", items = { { LINEN, "Linen Cloth", 20 } } }
    TakeInboxItem(3)
    linenBags({ [1] = 20 })
    changed()
    check(big.status == "expired", "the 20-stack expires: " .. tostring(big.status))

    -- Account figures: the 15c deposit back is not income; spending is what was lost.
    local inc, exp = ns.Economy.Totals(c, nil)
    check(inc == 475 and exp == 63, "deposit back is not income: in " .. inc .. " out " .. exp)
    check(inc - exp == 490 - 78, "net unchanged")

    -- The Auctions tab: profit = 475 - 60 - 3 = 412, deposits lost 63, one cancelled.
    local t = ns.Economy.AuctionTotals(c.auctions)
    check(t.profit == 412 and t.lost == 63 and t.cancelled == 1 and t.expired == 1 and t.sold == 1, "auction totals: profit "
        .. t.profit .. " lost " .. t.lost)
    MOCK.FireEvent("MAIL_CLOSED")
    MOCK.Tick(4)
    -- The Auction House page's My auctions: every auction, every character.
    slash("ah mine")
    local sub = ns.MarketUI.views.mine.card.sub:GetText()
    local F = ns.Economy.FormatMoney
    check(sub:find("profit " .. F(412, true), 1, true) and sub:find("deposits lost " .. F(63), 1, true) and sub:find("1 cancelled", 1, true),
        "auctions summary: " .. sub)

    -- Nothing known but the name: the oldest listing, as before.
    c.auctions[#c.auctions + 1] = { id = 90, t = time() - 100, name = "Wool Cloth", count = 20, status = "listed" }
    c.auctions[#c.auctions + 1] = { id = 91, t = time() - 50, name = "Wool Cloth", count = 5, status = "listed" }
    local a = ns.Economy.SettleListing(c, "Wool Cloth", "expired")
    check(a and a.id == 90, "no hint: oldest listing")
end

-- A letter whose subject names the count ("Linen Cloth (5)") and no invoice
-- details (only type, item, buyer): the count still picks the listing.
scenarios.econ_ledger_subject_count = function()
    linenBags({ [1] = 20, [2] = 5 })
    local ns, c, changed = start()
    MOCK.FireEvent("AUCTION_HOUSE_SHOW")
    post(changed, 1, 20, 2000, 60)
    post(changed, 2, 5, 500, 15)
    MOCK.FireEvent("AUCTION_HOUSE_CLOSED")
    MOCK.Tick(4)
    MOCK.inbox[1] = { sender = "Auction House", subject = "Auction expired: Linen Cloth (5)" }
    MOCK.FireEvent("MAIL_SHOW")
    TakeInboxItem(1)
    linenBags({ [2] = 5 })
    changed()
    check(c.auctions[2].status == "expired" and c.auctions[1].status == "listed",
        "subject count picks the 5-stack: " .. tostring(c.auctions[1].status) .. " / " .. tostring(c.auctions[2].status))
end

-- A take that moved nothing waits in the queue; then gold is mailed to your
-- own character. The bug: the stale letter took the money ("mail from Buddy").
-- Now: 5000c transfer, 30c postage as mail, and the session net leaves the
-- transfer out.
scenarios.econ_ledger_sent_mail = function()
    function SetSendMailMoney() end
    function GetSendMailMoney() return 0 end
    local ns, c, changed = start()
    TALODDB.economy["Alt-Mockrealm"] = { log = {}, days = {} }
    MOCK.FireEvent("MAIL_SHOW")
    MOCK.inbox[1] = { sender = "Buddy", subject = "hi", money = 0 }
    TakeInboxMoney(1)
    changed()
    local n = #c.log
    SetSendMailMoney(5000)
    SendMail("Alt", "gold", "")
    MOCK.money = MOCK.money - 5030
    changed()
    local t1, t2 = c.log[n + 1], c.log[n + 2]
    check(t1 and t1.kind == "transfer" and t1.amount == -5000 and t1.detail == "to Alt: gold",
        "gold to your alt is a transfer: " .. tostring(t1 and t1.kind) .. " " .. tostring(t1 and t1.detail) .. " " .. tostring(t1 and t1.amount))
    check(t2 and t2.kind == "mail" and t2.amount == -30, "postage is a mail cost: " .. tostring(t2 and t2.amount))
    local _, exp = ns.Economy.ScopeTotals("all", nil)
    check(exp == 30, "the account spent only the postage: " .. exp)

    -- Money from your alt later: a transfer too, matched to its own letter.
    MOCK.inbox[2] = { sender = "Alt", subject = "back", money = 2000 }
    TakeInboxMoney(2)
    changed()
    check(c.log[#c.log].kind == "transfer" and c.log[#c.log].amount == 2000, "gold from your alt")
    local net, _, _, moved = ns.Economy.Session()
    check(net == -30 and moved == -3000, "session leaves transfers out: " .. tostring(net) .. " moved " .. tostring(moved))

    -- A money gain never goes to a letter that moved nothing or money the other way.
    MOCK.inbox[3] = { sender = "Buddy", subject = "zero", money = 0 }
    MOCK.inbox[4] = { sender = "Pal", subject = "tip", money = 300 }
    MOCK.mailLater = true
    TakeInboxMoney(3) TakeInboxMoney(4)
    MOCK.AnswerMail() MOCK.mailLater = nil
    changed()
    check(c.log[#c.log].detail == "from Pal: tip" and c.log[#c.log].amount == 300, "money goes to the letter with money: " .. tostring(c.log[#c.log].detail))
end

-- A bid of 700c, then the outbid letter returns it: no income, no spending.
scenarios.econ_ledger_refunds = function()
    local ns, c, changed = start()
    MOCK.FireEvent("AUCTION_HOUSE_SHOW")
    PlaceAuctionBid("list", 1, 700)
    MOCK.money = MOCK.money - 700
    changed()
    check(c.log[#c.log].kind == "auction" and c.log[#c.log].amount == -700, "bid recorded")
    MOCK.FireEvent("AUCTION_HOUSE_CLOSED")
    MOCK.Tick(4)
    MOCK.inbox[1] = { sender = "Auction House", subject = "Outbid on Linen Cloth", money = 700 }
    MOCK.FireEvent("MAIL_SHOW")
    TakeInboxMoney(1)
    changed()
    local e = c.log[#c.log]
    check(e.kind == "auction" and e.sub == "outbid" and e.refund == 700, "outbid letter is a refund")
    local inc, exp, by = ns.Economy.Totals(c, nil)
    check(inc == 0 and exp == 0 and (by.auction or 0) == 0, "bid and refund cancel out: in " .. inc .. " out " .. exp)
    local aInc, aExp = ns.Economy.ScopeTotals("all", nil)
    check(aInc == 0 and aExp == 0, "account totals too")
    local days = ns.Economy.ScopeDays("all")
    local d = days[date("%Y-%m-%d", time())]
    check(d and d.inc == 0 and d.exp == 0, "the day's in / out too")
    -- A refund with nothing spent in the range counts as income (net kept).
    local i2, e2 = ns.Economy.NetRefunds(0, 0, 500)
    check(i2 == 500 and e2 == 0, "refund over spending")
end

-- On a clock-change day the hours since midnight are not the clock's hour:
-- "Today" must start at the calendar's midnight (the bug: an hour early,
-- which pulled yesterday into today).
scenarios.econ_ledger_dst = function()
    local ns, c = start()
    local real = os.date
    local now = time()
    local d = real("*t", now)
    local midnight = os.time({ year = d.year, month = d.month, day = d.day, hour = 0, min = 0, sec = 0 })
    MOCK.now = midnight + 2 * 3600
    -- The clock jumped forward: at 02:00 since midnight it reads 03:00.
    date = function(fmt, t)
        local v = real(fmt, t)
        if fmt == "*t" and (t or MOCK.now) == MOCK.now then v.hour = v.hour + 1 end
        return v
    end
    local today, yesterday = real("%Y-%m-%d", MOCK.now), real("%Y-%m-%d", midnight - 3600)
    c.days[yesterday] = { inc = 1000, exp = 0, by = { vendor = 1000 }, money = 100000 }
    c.days[today] = { inc = 50, exp = 0, by = { vendor = 50 }, money = 100050 }
    ns.Economy.Changed()
    slash("economy")
    ns.EconomyUI.state.view = "overview"
    ns.EconomyUI.state.range = 1
    ns.EconomyUI.Refresh()
    local F = ns.Economy.FormatMoney
    local tiles = ns.EconomyUI.views.overview.tiles
    check(tiles[2].sub:GetText() == "in " .. F(50) .. "  out " .. F(0), "today is today only: " .. tiles[2].sub:GetText())
    check(tiles[3].sub:GetText() == "in " .. F(50) .. "  out " .. F(0), "range 'Today' too: " .. tiles[3].sub:GetText())
    check(ns.Economy.DayStart() == midnight and ns.Economy.DayStart(nil, 1) == os.time({ year = d.year, month = d.month,
        day = d.day - 1, hour = 0, min = 0, sec = 0 }), "day starts from the calendar")
    date = real
end
