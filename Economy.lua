-- TALOD - Economy: where your money and goods come from and go.
--
-- Every change of your gold (and of your bags, where it matters) is
-- recorded with what you were doing, read from the window you had open:
-- vendor (sales, purchases; spending without an item change = repairs),
-- trade (partner, both sides' items and gold), mail, auction house,
-- trainer, flight master, quest reward (title), loot (money; uncommon and
-- better items; merged per zone while you keep looting). Chat messages are
-- not parsed: they may be secret on WoW Forever. Item-only changes outside
-- those windows (equipping, using a potion, the bank) are not economy.
--
-- Mail is read per letter: taking money or items from a letter (the
-- functions are hooked, never called) names it: "Auction sold: X to Y",
-- "Auction won", outbid / expired, or "from Sender: subject"; auction
-- letters count as auction income. Sent mail names the recipient. At the
-- auction house, posting (items leave, deposit paid) and bids / buyouts
-- (money only) are told apart.
--
-- Only one NPC window can be open at a time (mailbox, auctioneer, vendor,
-- trainer, flight master, bank): opening one ends the others, and the
-- newest open window wins. The engine's PLAYER_INTERACTION_MANAGER events
-- are used too, since the old "closed" events do not always arrive.
--
-- Auctions are followed from posting to the end: posting / bidding /
-- buying is read by hooking the game's functions (classic PostAuction /
-- StartAuction / PlaceAuctionBid and C_AuctionHouse.PostItem /
-- PostCommodity / PlaceBid / ConfirmCommoditiesPurchase), the listing is
-- kept with its deposit, and the auction letter later marks it sold (with
-- what you received and the profit), expired or cancelled.
--
-- Money is an account matter: data is kept per character
-- (TALODDB.economy["Name-Realm"] = { log, days, auctions }) and shown
-- for all characters together. Mail and trades between your own characters
-- are transfers: they are not income or spending for the account.

local ADDON_NAME, ns = ...
local S = ns.Secret
local Style = ns.Style
local COLORS, HEX = Style.COLORS, Style.HEX

local Economy = {}
ns.Economy = Economy

local SETTLE = 0.4             -- seconds after the last money / bag change before recording
local GRACE = 3                -- a change this soon after a window closed belongs to it
local LOOT_MERGE = 120         -- loot within this many seconds in one zone is one entry
local MAX_LOG = 5000
local MAX_DAYS = 400

-- Every write to the economy data says so (Data source "economy"): the
-- window's summaries and rows are kept until then.
local function Changed() ns.Data.Changed("economy") end
Economy.Changed = Changed

local KINDS = {
    { key = "vendor", label = "Vendor" }, { key = "repair", label = "Repairs" }, { key = "loot", label = "Loot" },
    { key = "quest", label = "Quests" }, { key = "trade", label = "Trades" }, { key = "mail", label = "Mail" },
    { key = "auction", label = "Auction" }, { key = "training", label = "Training" }, { key = "flight", label = "Flights" },
    { key = "transfer", label = "Transfers" }, { key = "other", label = "Other" },
}
Economy.KINDS = KINDS
local KIND_LABEL = {}
for _, k in ipairs(KINDS) do KIND_LABEL[k.key] = k.label end

-- Windows that tell what a money change was, highest priority first.
local WINDOWS = {
    TRADE_SHOW = { "trade", true }, TRADE_CLOSED = { "trade", false },
    MAIL_SHOW = { "mail", true }, MAIL_CLOSED = { "mail", false },
    AUCTION_HOUSE_SHOW = { "auction", true }, AUCTION_HOUSE_CLOSED = { "auction", false },
    MERCHANT_SHOW = { "vendor", true }, MERCHANT_CLOSED = { "vendor", false },
    TRAINER_SHOW = { "training", true }, TRAINER_CLOSED = { "training", false },
    TAXIMAP_OPENED = { "flight", true }, TAXIMAP_CLOSED = { "flight", false },
    QUEST_COMPLETE = { "quest", true }, QUEST_FINISHED = { "quest", false },
    LOOT_OPENED = { "loot", true }, LOOT_CLOSED = { "loot", false },
    BANKFRAME_OPENED = { "bank", true }, BANKFRAME_CLOSED = { "bank", false },
}
local PRIORITY = { "trade", "mail", "auction", "vendor", "training", "flight", "quest", "loot", "bank" }
-- NPC interactions: only one at a time.
local NPC_WINDOWS = { mail = true, auction = true, vendor = true, training = true, flight = true, bank = true }
-- PLAYER_INTERACTION_MANAGER_FRAME_SHOW / _HIDE types (Enum.PlayerInteractionType, numbers as fallback).
local INTERACTION_KINDS = {}
do
    local E = Enum and Enum.PlayerInteractionType or {}
    local function Map(name, number, kind) INTERACTION_KINDS[E[name] or number] = kind end
    Map("TradePartner", 1, "trade") Map("Merchant", 5, "vendor") Map("TaxiNode", 6, "flight") Map("Trainer", 7, "training")
    Map("Banker", 8, "bank") Map("MailInfo", 17, "mail") Map("Auctioneer", 21, "auction")
end

local open, closed, detail = {}, {}, {}   -- open[kind] = GetTime() it opened
local pendingPost, pendingBuy                -- auction actions waiting for their money change
local baseMoney, baseBags
local pendingAt, loginAt
local trade                    -- contents of the trade window, kept until it closes
local session                  -- { money, at = GetTime() } when this session's tracking started

local function db() return ns.DB() end
local function Num(v) return type(v) == "number" and v or nil end

function Economy.Char(key)
    key = key or (ns.Gear and ns.Gear.CharKey())
    if not key then return nil end
    local c = db().economy[key]
    if not c then
        c = { log = {}, days = {} }
        db().economy[key] = c
    end
    return c, key
end

---------------------------------------------------------------------------
-- Reading money and bags
---------------------------------------------------------------------------
local function Money() return Num(S.Call(GetMoney)) end

local function ItemID(link) return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil end

-- { [itemID] = { n = count, link = link, slots } } over your bags and the
-- reagent bag (Utils.ScanBags).
local function ScanBags() return ns.Utils.ScanBags() end
Economy.ScanBags = ScanBags

-- Items gained (n > 0) and lost (n < 0) between two scans.
local function BagDiff(a, b)
    local out = {}
    for id, e in pairs(b or {}) do
        local d = e.n - ((a or {})[id] and a[id].n or 0)
        if d ~= 0 then out[#out + 1] = { id = id, link = e.link, n = d } end
    end
    for id, e in pairs(a or {}) do
        if not (b or {})[id] then out[#out + 1] = { id = id, link = e.link, n = -e.n } end
    end
    table.sort(out, function(x, y) return x.n > y.n end)
    return out
end

-- Item quality from the link color (no item cache needed).
local QUALITY_BY_HEX = { ["9d9d9d"] = 0, ffffff = 1, ["1eff00"] = 2, ["0070dd"] = 3, a335ee = 4, ff8000 = 5 }
local function Quality(link)
    if type(link) ~= "string" then return 1 end
    -- Newer engine links carry the quality itself: |cnIQ2:...
    local iq = tonumber(link:match("|cnIQ(%d+):"))
    if iq then return iq end
    local hex = link:match("|cff(%x%x%x%x%x%x)")
    if hex and QUALITY_BY_HEX[hex:lower()] then return QUALITY_BY_HEX[hex:lower()] end
    local id = ItemID(link)
    local q = id and C_Item and C_Item.GetItemQualityByID and S.Call(C_Item.GetItemQualityByID, id)
    return type(q) == "number" and q or 1
end

local function SellPrice(link)
    local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if type(info) ~= "function" then return nil end
    local ok, a = pcall(function() return select(11, info(link)) end)
    return ok and Num(S.Value(a)) or nil
end

---------------------------------------------------------------------------
-- Context
---------------------------------------------------------------------------
local function Context()
    -- Trade first (it is with a player), then the newest open window.
    if open.trade then return "trade" end
    local best, bestT
    for kind, t in pairs(open) do
        if not bestT or t > bestT then best, bestT = kind, t end
    end
    if best then return best end
    local now, best, bestT = GetTime(), nil, nil
    for kind, t in pairs(closed) do
        if now - t <= GRACE and (not bestT or t > bestT) then best, bestT = kind, t end
    end
    return best
end

local function ReadTrade()
    local t = { give = {}, get = {} }
    for i = 1, 7 do
        local mine = S.Call(GetTradePlayerItemLink, i)
        if type(mine) == "string" then
            local n = Num(select(3, S.CallMulti(3, GetTradePlayerItemInfo, i))) or 1
            t.give[#t.give + 1] = { link = mine, n = n }
        end
        local theirs = S.Call(GetTradeTargetItemLink, i)
        if type(theirs) == "string" then
            local n = Num(select(3, S.CallMulti(3, GetTradeTargetItemInfo, i))) or 1
            t.get[#t.get + 1] = { link = theirs, n = n }
        end
    end
    t.giveMoney = Num(S.Call(GetPlayerTradeMoney)) or 0
    t.getMoney = Num(S.Call(GetTargetTradeMoney)) or 0
    return t
end

-- Auction letter subject prefixes: the client's own strings ("Outbid on %s"
-- -> "Outbid on "), so other languages work, plus the English ones.
local auctionSubjects
function Economy.AuctionSubjects()
    if auctionSubjects then return auctionSubjects end
    auctionSubjects = {}
    for _, name in ipairs({ "AUCTION_OUTBID_MAIL_SUBJECT", "AUCTION_EXPIRED_MAIL_SUBJECT", "AUCTION_REMOVED_MAIL_SUBJECT",
        "AUCTION_SOLD_MAIL_SUBJECT", "AUCTION_WON_MAIL_SUBJECT" }) do
        local text = _G[name]
        local prefix = type(text) == "string" and text:match("^(.-)%%") or nil
        if prefix and prefix ~= "" then auctionSubjects[#auctionSubjects + 1] = prefix end
    end
    for _, prefix in ipairs({ "Outbid", "Auction expired", "Auction cancelled", "Auction successful", "Auction won" }) do
        auctionSubjects[#auctionSubjects + 1] = prefix
    end
    return auctionSubjects
end

-- What a letter is: text, and "auction" when it is an auction house letter.
-- Auction letters keep 30 days: daysLeft tells when the letter came.
local MAIL_DAYS = 30
-- [VERIFY] The sale letter comes an hour after the sale (vanilla); an expired / cancelled letter at once.
local SOLD_MAIL_DELAY = 3600

function Economy.DescribeMail(index)
    local _, _, sender, subject, money, cod, daysLeft = S.CallMulti(7, GetInboxHeaderInfo, index)
    local invoiceType, itemName, playerName = S.CallMulti(3, GetInboxInvoiceInfo, index)
    local arrived = (type(daysLeft) == "number" and daysLeft >= 0 and daysLeft <= MAIL_DAYS)
        and math.floor(time() - (MAIL_DAYS - daysLeft) * 86400) or nil
    -- The buyer's name can be empty (seen on Forever).
    if playerName == "" then playerName = nil end
    if invoiceType == "seller" then
        return "Auction sold: " .. tostring(itemName or "?") .. (playerName and (" to " .. playerName) or ""), "auction",
            { status = "sold", item = itemName, arrived = arrived }
    elseif invoiceType == "buyer" then
        return "Auction won: " .. tostring(itemName or "?") .. (playerName and (" from " .. playerName) or ""), "auction",
            { status = "won", item = itemName }
    elseif invoiceType == "seller_temp_invoice" then
        return "Auction sold (pending): " .. tostring(itemName or "?"), "auction", { status = "pending", item = itemName }
    end
    local subj = type(subject) == "string" and subject or ""
    for _, prefix in ipairs(Economy.AuctionSubjects()) do
        if subj:sub(1, #prefix) == prefix then
            local item = subj:sub(#prefix + 1):gsub("^[:%s]+", "")
            local lower = prefix:lower()
            local status = lower:find("expire") and "expired" or lower:find("cancel") and "cancelled" or lower:find("outbid") and "outbid" or nil
            return subj, "auction", { status = status, item = item ~= "" and item or nil, arrived = arrived }
        end
    end
    if type(sender) == "string" and Economy.OwnNames()[sender] then
        return "from " .. sender .. (subj ~= "" and (": " .. subj) or ""), "transfer"
    end
    if type(cod) == "number" and cod > 0 then
        return "COD from " .. tostring(sender or "?") .. ": " .. subj, nil
    end
    return "from " .. tostring(sender or "?") .. (subj ~= "" and (": " .. subj) or ""), nil
end

---------------------------------------------------------------------------
-- Auctions: posting, bidding, buying
---------------------------------------------------------------------------
local function ItemLinkAt(location)
    if C_Item and C_Item.GetItemLink and location then
        local link = S.Call(C_Item.GetItemLink, location)
        if type(link) == "string" then return link end
    end
    return nil
end

-- Classic runTime 1 / 2 / 3; modern duration enum 0 / 1 / 2 (as on the client's posting frame).
local CLASSIC_DURATION = { [1] = "2 h", [2] = "8 h", [3] = "24 h" }
local MODERN_DURATION = { [0] = "12 h", [1] = "24 h", [2] = "48 h" }

local function HookAuctions()
    if type(hooksecurefunc) ~= "function" then return end
    local function Enabled() return db().economyEnabled end
    for _, name in ipairs({ "PostAuction", "StartAuction" }) do
        if type(_G[name]) == "function" then
            hooksecurefunc(name, function(minBid, buyout, runTime, stackSize, numStacks)
                if not Enabled() then return end
                local itemName, _, count = S.CallMulti(3, GetAuctionSellItemInfo)
                local stacks = Num(numStacks) or 1
                local stack = Num(stackSize) or Num(count) or 1
                pendingPost = { name = type(itemName) == "string" and itemName or "?", count = stack, stacks = stacks,
                    bid = Num(minBid), buyout = Num(buyout), duration = CLASSIC_DURATION[runTime] or tostring(runTime or "?"), at = GetTime() }
            end)
        end
    end
    if type(PlaceAuctionBid) == "function" then
        hooksecurefunc("PlaceAuctionBid", function(listType, index, bid)
            if not Enabled() then return end
            local name, _, count, _, _, _, _, _, _, buyout = S.CallMulti(10, GetAuctionItemInfo, listType, index)
            pendingBuy = { name = type(name) == "string" and name or "?", count = Num(count) or 1, amount = Num(bid),
                buyout = Num(buyout) and Num(bid) and bid >= buyout, at = GetTime() }
        end)
    end
    local AH = C_AuctionHouse
    if type(AH) == "table" then
        if type(AH.PostItem) == "function" then
            hooksecurefunc(AH, "PostItem", function(location, duration, quantity, bid, buyout)
                if not Enabled() then return end
                local link = ItemLinkAt(location)
                -- An item (not a commodity) posted with quantity N is N auctions of one, each at `buyout`
                -- with its own deposit (Forever 2026-10-07: 20 pants = 20 auctions at 69c deposit each).
                pendingPost = { name = link or "?", link = link, count = 1, stacks = Num(quantity) or 1, bid = Num(bid), buyout = Num(buyout),
                    duration = MODERN_DURATION[duration] or tostring(duration or "?"), at = GetTime() }
            end)
        end
        if type(AH.PostCommodity) == "function" then
            hooksecurefunc(AH, "PostCommodity", function(location, duration, quantity, unitPrice)
                if not Enabled() then return end
                local link = ItemLinkAt(location)
                local q = Num(quantity) or 1
                pendingPost = { name = link or "?", link = link, count = q, unit = Num(unitPrice),
                    buyout = Num(unitPrice) and unitPrice * q or nil, duration = MODERN_DURATION[duration] or tostring(duration or "?"), at = GetTime() }
            end)
        end
        if type(AH.PlaceBid) == "function" then
            hooksecurefunc(AH, "PlaceBid", function(auctionID, bidAmount)
                if not Enabled() then return end
                pendingBuy = { name = "auction " .. tostring(auctionID), amount = Num(bidAmount), at = GetTime() }
            end)
        end
        if type(AH.ConfirmCommoditiesPurchase) == "function" then
            hooksecurefunc(AH, "ConfirmCommoditiesPurchase", function(itemID, quantity)
                if not Enabled() then return end
                local name = (C_Item and C_Item.GetItemNameByID) and S.Call(C_Item.GetItemNameByID, itemID)
                pendingBuy = { name = type(name) == "string" and name or ("item " .. tostring(itemID)), count = Num(quantity) or 1,
                    buyout = true, at = GetTime() }
            end)
        end
    end
end

local function ShortName(link) return type(link) == "string" and (link:match("|h%[(.-)%]|h") or link) or "?" end
Economy.ShortName = ShortName

-- Marks the oldest open listing of this item as sold / expired / cancelled.
-- arrived: when its letter came; closedAt = when it really sold / ended
-- (ended = when you took the letter).
local function SettleListing(c, itemName, status, received, arrived)
    if not c.auctions or not itemName then return nil end
    for _, a in ipairs(c.auctions) do
        if a.status == "listed" and ShortName(a.name) == itemName then
            a.status, a.ended = status, time()
            Changed()
            if arrived then
                a.closedAt = math.max(a.t or 0, arrived - (status == "sold" and SOLD_MAIL_DELAY or 0))
            end
            if received then
                a.received = received
                a.profit = received - (a.deposit or 0)
            end
            return a
        end
    end
    return nil
end
Economy.SettleListing = SettleListing

-- Names of your characters (any realm), for transfers.
function Economy.OwnNames()
    local names = {}
    for _, store in ipairs({ db().economy or {}, db().gear or {} }) do
        for key in pairs(store) do
            local name = key:match("^([^-]+)")
            if name then names[name] = true end
        end
    end
    return names
end

-- Letters taken from, oldest first, each waiting for its money / items. The
-- server answers each take later, so with Open All or quick clicks several
-- letters are taken before the first one's money arrives: one slot would
-- give that money the next letter's name and leave the last one unnamed.
local MAIL_WAIT = 60
local mailQueue = {}

local function HookMail()
    HookAuctions()
    if type(hooksecurefunc) ~= "function" then return end
    -- withMoney / withItems: what this call takes from the letter.
    local function Taking(index, withMoney, withItems)
        if not db().economyEnabled or type(index) ~= "number" then return end
        local text, as, info = Economy.DescribeMail(index)
        local money, cod = select(5, S.CallMulti(6, GetInboxHeaderInfo, index))
        local amount = (withMoney and Num(money) or 0) - (withItems and Num(cod) or 0)
        local now = GetTime()
        while mailQueue[1] and now - mailQueue[1].at > MAIL_WAIT do table.remove(mailQueue, 1) end
        mailQueue[#mailQueue + 1] = { text = text, as = as, info = info, amount = amount, at = now }
    end
    if type(TakeInboxMoney) == "function" then hooksecurefunc("TakeInboxMoney", function(i) Taking(i, true, false) end) end
    if type(TakeInboxItem) == "function" then hooksecurefunc("TakeInboxItem", function(i) Taking(i, false, true) end) end
    if type(AutoLootMailItem) == "function" then hooksecurefunc("AutoLootMailItem", function(i) Taking(i, true, true) end) end
    if type(SendMail) == "function" then
        hooksecurefunc("SendMail", function(recipient, subject)
            if not db().economyEnabled then return end
            local own = type(recipient) == "string" and Economy.OwnNames()[(recipient:match("^([^-]+)"))]
            detail.mail = "to " .. tostring(recipient or "?") .. ((type(subject) == "string" and subject ~= "") and (": " .. subject) or "")
            detail.mailAs, detail.mailInfo = own and "transfer" or nil, nil
        end)
    end
end

local function SetWindow(kind, isOpen)
    if isOpen then
        if NPC_WINDOWS[kind] then
            for other in pairs(NPC_WINDOWS) do
                if other ~= kind and open[other] then open[other] = nil closed[other] = GetTime() - GRACE - 1 end
            end
        end
        if open[kind] then return end
        open[kind] = GetTime()
        if kind == "vendor" or kind == "training" or kind == "flight" then
            local name = S.Call(UnitName, "npc")
            detail[kind] = type(name) == "string" and name or nil
        elseif kind == "quest" then
            local title = S.Call(GetTitleText)
            detail.quest = type(title) == "string" and title ~= "" and title or nil
        elseif kind == "loot" then
            local name = S.Call(UnitName, "target")
            detail.loot = (S.Call(UnitIsDead, "target") and type(name) == "string") and name or nil
        elseif kind == "trade" then
            local name = S.Call(UnitName, "NPC")
            trade = { partner = type(name) == "string" and name or "?", give = {}, get = {}, giveMoney = 0, getMoney = 0 }
        end
    else
        if not open[kind] then return end
        open[kind] = nil
        closed[kind] = GetTime()
    end
end

local function OnWindow(event)
    local w = WINDOWS[event]
    SetWindow(w[1], w[2])
end
Economy.SetWindow = SetWindow

---------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------
local function Today(t) return date("%Y-%m-%d", t) end

local function AddDay(c, t, amount, kind, money)
    Changed()
    local key = Today(t)
    local d = c.days[key]
    if not d then
        d = { inc = 0, exp = 0, by = {} }
        c.days[key] = d
        -- Trim the oldest days.
        local keys = {}
        for k in pairs(c.days) do keys[#keys + 1] = k end
        if #keys > MAX_DAYS then
            table.sort(keys)
            for i = 1, #keys - MAX_DAYS do c.days[keys[i]] = nil end
        end
    end
    if kind == "transfer" then
        -- Between your own characters: not income or spending for the account.
        if amount > 0 then d.tin = (d.tin or 0) + amount elseif amount < 0 then d.tout = (d.tout or 0) - amount end
    else
        if amount > 0 then d.inc = d.inc + amount elseif amount < 0 then d.exp = d.exp - amount end
    end
    if amount ~= 0 then d.by[kind] = (d.by[kind] or 0) + amount end
    d.money = money
end

local function ItemsOf(diff, sign)
    local out = {}
    for _, it in ipairs(diff) do
        if (sign > 0 and it.n > 0) or (sign < 0 and it.n < 0) then out[#out + 1] = { it.link, math.abs(it.n) } end
    end
    return #out > 0 and out or nil
end

local function Record(c, e)
    -- Keep looting in one zone as one entry.
    local last = c.log[#c.log]
    if e.kind == "loot" and last and last.kind == "loot" and last.zone == e.zone and e.t - (last.t2 or last.t) <= LOOT_MERGE then
        last.amount, last.t2 = last.amount + e.amount, e.t
        last.count = (last.count or 1) + 1
        last.value = (last.value or 0) + (e.value or 0)
        for _, it in ipairs(e.gained or {}) do
            last.gained = last.gained or {}
            if #last.gained < 20 then last.gained[#last.gained + 1] = it end
        end
        if e.detail and last.detail ~= e.detail then last.detail = nil end
    else
        c.log[#c.log + 1] = e
        while #c.log > MAX_LOG do table.remove(c.log, 1) end
    end
    Changed()
end

-- The letters a money / item change came from, taken off the queue: the one
-- with exactly this money, else the oldest ones that add up to it (several
-- answers in one settle), else the oldest one.
local function TakeLetters(dMoney)
    local now = GetTime()
    while mailQueue[1] and now - mailQueue[1].at > MAIL_WAIT do table.remove(mailQueue, 1) end
    if #mailQueue == 0 then return {} end
    if dMoney ~= 0 then
        for i, m in ipairs(mailQueue) do
            if m.amount == dMoney then return { table.remove(mailQueue, i) } end
        end
        local sum, n = 0, 0
        for _, m in ipairs(mailQueue) do
            if m.amount ~= 0 then
                sum, n = sum + m.amount, n + 1
                if sum == dMoney then break end
            end
        end
        if n > 1 and sum == dMoney then
            local out, i = {}, 1
            while #out < n do
                if mailQueue[i].amount ~= 0 then out[#out + 1] = table.remove(mailQueue, i) else i = i + 1 end
            end
            return out
        end
    else
        -- Items only: the oldest take that moves no money.
        for i, m in ipairs(mailQueue) do
            if m.amount == 0 then return { table.remove(mailQueue, i) } end
        end
    end
    return { table.remove(mailQueue, 1) }
end

-- Compares money and bags with the last settled state and records the change.
function Economy.Settle()
    pendingAt = nil
    local c = Economy.Char()
    local money, bags = Money(), ScanBags()
    if not c or not money then return end
    if not baseMoney then baseMoney, baseBags = money, bags return end
    local dMoney = money - baseMoney
    local diff = BagDiff(baseBags, bags)
    baseMoney, baseBags = money, bags
    local kind = Context()
    if kind == "bank" then kind = nil end
    if dMoney == 0 and (#diff == 0 or not kind) then return end
    local now = time()
    local e = { t = now, kind = kind or "other", amount = dMoney, zone = S.Call(GetZoneText), level = Num(S.Call(UnitLevel, "player")),
        detail = kind and detail[kind] or nil, gained = ItemsOf(diff, 1), lost = ItemsOf(diff, -1) }
    if e.kind == "vendor" and dMoney < 0 and not e.gained and not e.lost then e.kind = "repair" end
    if e.kind == "mail" then
        local letters = TakeLetters(dMoney)
        if #letters == 0 and detail.mail then
            -- Sent mail (postage, COD sent): named by the SendMail hook.
            letters = { { text = detail.mail, as = detail.mailAs } }
        end
        detail.mail, detail.mailAs, detail.mailInfo = nil, nil, nil
        if #letters == 0 then letters = { {} } end
        local left = dMoney
        for i, m in ipairs(letters) do
            local le = i == 1 and e or { t = now, kind = "mail", zone = e.zone, level = e.level }
            le.amount = i == #letters and left or m.amount
            left = left - le.amount
            le.detail = m.text
            if m.as then le.kind = m.as end
            local info = m.info
            if le.kind == "auction" and info then
                le.sub = info.status
                local a = (info.status == "sold" or info.status == "expired" or info.status == "cancelled")
                    and SettleListing(c, info.item, info.status, info.status == "sold" and le.amount > 0 and le.amount or nil, info.arrived)
                if a then le.listing = a.id end
            end
            AddDay(c, now, le.amount, le.kind, money)
            Record(c, le)
        end
        return
    elseif e.kind == "auction" then
        local nowT = GetTime()
        if pendingPost and nowT - pendingPost.at < 15 then
            local post = pendingPost
            -- Several stacks (classic numStacks) are separate auctions with
            -- their own deposit and their own letter: one listing each. The
            -- server posts them one by one, so a settle may see only some.
            local left = post.stacks or 1
            local posted = 1
            if left > 1 then
                local units = 0
                for _, it in ipairs(e.lost or {}) do units = units + it[2] end
                posted = math.max(1, math.min(left, math.floor(units / math.max(1, post.count or 1) + 0.5)))
            end
            if left - posted > 0 then
                post.stacks, post.at = left - posted, nowT
            else
                pendingPost = nil
            end
            c.auctions = c.auctions or {}
            -- The server charges the deposits in batches that need not match
            -- the items leaving the bags (11 deposits with 12 items, one alone),
            -- so the whole post's paid deposits are spread over its listings.
            post.made = post.made or {}
            if dMoney < 0 then post.paid = (post.paid or 0) - dMoney end
            local listing
            for _ = 1, posted do
                c.nextAuction = (c.nextAuction or 0) + 1
                listing = { id = c.nextAuction, t = now, name = post.link or post.name, count = post.count,
                    bid = post.bid, buyout = post.buyout, duration = post.duration, status = "listed" }
                if not post.link and e.lost and e.lost[1] then listing.name = e.lost[1][1] end
                c.auctions[#c.auctions + 1] = listing
                post.made[#post.made + 1] = listing
            end
            local deposit = post.paid and math.floor(post.paid / #post.made + 0.5) or nil
            for _, a in ipairs(post.made) do a.deposit = deposit end
            while #c.auctions > 1000 do table.remove(c.auctions, 1) end
            e.sub, e.listing = "posted", listing.id
            e.detail = "Listed " .. tostring(listing.name) .. (listing.count and listing.count > 1 and (" x" .. listing.count) or "")
                .. (posted > 1 and (" (" .. posted .. " stacks)") or "")
                .. (listing.buyout and ("  ·  buyout " .. Economy.FormatMoney(listing.buyout)) or "")
                .. (listing.bid and ("  ·  bid " .. Economy.FormatMoney(listing.bid)) or "")
                .. "  ·  " .. tostring(listing.duration) .. (listing.deposit and ("  ·  deposit " .. Economy.FormatMoney(listing.deposit)) or "")
        elseif pendingBuy and nowT - pendingBuy.at < 15 then
            local buy = pendingBuy
            pendingBuy = nil
            e.sub = buy.buyout and "bought" or "bid"
            e.detail = (buy.buyout and "Bought " or "Bid on ") .. tostring(buy.name) .. (buy.count and buy.count > 1 and (" x" .. buy.count) or "")
        elseif dMoney < 0 and e.lost then
            e.sub, e.detail = "posted", "posted " .. (e.lost[1] and e.lost[1][1] or "?") .. " (deposit)"
        elseif dMoney < 0 then
            e.sub, e.detail = "bid", "bid or buyout"
        elseif dMoney > 0 then
            e.sub, e.detail = "refund", "refund"
        end
    end
    if e.kind == "trade" and trade then
        e.detail = trade.partner
        e.gave, e.got = trade.give, trade.get
        e.gaveMoney, e.gotMoney = trade.giveMoney, trade.getMoney
    end
    -- After the partner is known: a trade with one of your own characters is a transfer.
    if e.kind == "trade" and e.detail and Economy.OwnNames()[(tostring(e.detail):match("^([^-]+)"))] then e.kind = "transfer" end
    if e.kind == "loot" then
        -- Only money and uncommon or better items are economy.
        local keep = {}
        local value = 0
        for _, it in ipairs(e.gained or {}) do
            if Quality(it[1]) >= 2 then keep[#keep + 1] = it end
            value = value + (SellPrice(it[1]) or 0) * it[2]
        end
        e.gained = #keep > 0 and keep or nil
        e.value = value > 0 and value or nil
        e.lost = nil
        if dMoney == 0 and not e.gained then return end
    end
    if e.kind == "other" and dMoney == 0 then return end
    AddDay(c, now, dMoney, e.kind, money)
    Record(c, e)
end

local function OnEvent(event, ...)
    if not db().economyEnabled then return end
    if event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" or event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        local kind = INTERACTION_KINDS[...]
        if kind then
            local showing = event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW"
            SetWindow(kind, showing)
            if not showing and kind == "trade" then pendingAt = GetTime() end
        end
        return
    end
    if WINDOWS[event] then
        OnWindow(event)
        if event == "TRADE_CLOSED" then pendingAt = GetTime() end
    elseif event == "TRADE_ACCEPT_UPDATE" or event == "TRADE_PLAYER_ITEM_CHANGED" or event == "TRADE_TARGET_ITEM_CHANGED"
        or event == "TRADE_MONEY_CHANGED" then
        if trade then
            local t = ReadTrade()
            trade.give, trade.get, trade.giveMoney, trade.getMoney = t.give, t.get, t.giveMoney, t.getMoney
        end
    elseif event == "PLAYER_MONEY" or event == "BAG_UPDATE_DELAYED" then
        pendingAt = GetTime()
    elseif event == "PLAYER_ENTERING_WORLD" then
        loginAt = loginAt or GetTime()
    end
end

local function Tick()
    if not db().economyEnabled then return end
    local now = GetTime()
    if not baseMoney then
        if loginAt and now - loginAt >= 2 then
            baseMoney, baseBags = Money(), ScanBags()
            session = baseMoney and { money = baseMoney, at = GetTime() } or nil
            local c = Economy.Char()
            if c and baseMoney then AddDay(c, time(), 0, "other", baseMoney) end
        end
        return
    end
    if pendingAt and now - pendingAt >= SETTLE then Economy.Settle() end
    -- A trade's contents are needed until its money and items have settled.
    if trade and not open.trade and not pendingAt and closed.trade and now - closed.trade > GRACE then trade = nil end
end

---------------------------------------------------------------------------
-- Summaries
---------------------------------------------------------------------------
-- Net since tracking started this session, and per hour (nil under 5 min).
function Economy.Session()
    local now = Money()
    if not session or not now then return nil end
    local net = now - session.money
    local hours = (GetTime() - session.at) / 3600
    return net, hours >= 5 / 60 and math.floor(net / hours + 0.5) or nil, hours
end

-- Last known gold of every character with economy data, and the total.
function Economy.AllCharacters()
    local out, total = {}, 0
    local me = ns.Gear and ns.Gear.CharKey()
    for key, c in pairs(db().economy) do
        local money
        if key == me then money = Money() end
        if not money then
            local lastDay
            for day in pairs(c.days or {}) do if not lastDay or day > lastDay then lastDay = day end end
            money = lastDay and c.days[lastDay].money
        end
        if money then
            out[#out + 1] = { key, money }
            total = total + money
        end
    end
    table.sort(out, function(a, b) return a[2] > b[2] end)
    return total, out
end

-- Gold at the end of each day (oldest first) since `since`: { { day, money } }.
function Economy.GoldSeries(c, since)
    local out = {}
    local from = since and date("%Y-%m-%d", since) or nil
    for day, d in pairs(c and c.days or {}) do
        if d.money and (not from or day >= from) then out[#out + 1] = { day, d.money } end
    end
    table.sort(out, function(a, b) return a[1] < b[1] end)
    return out
end
function Economy.FormatMoney(copper, signed)
    if not copper then return "-" end
    local sign = copper < 0 and "-" or (signed and copper > 0 and "+" or "")
    copper = math.abs(copper)
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = "|cffffd100" .. g .. "g|r" end
    if s > 0 or g > 0 then parts[#parts + 1] = "|cffc7c7cf" .. s .. "s|r" end
    parts[#parts + 1] = "|cffeda55f" .. c .. "c|r"
    return sign .. table.concat(parts, " ")
end
local FormatMoney = Economy.FormatMoney

-- Income, expense and by-kind net over days since `since` (time; nil = all)
-- for one character's data. withTransfers: count money moved between your
-- characters (a single character's view).
function Economy.Totals(c, since, withTransfers)
    local inc, exp, by = 0, 0, {}
    local from = since and Today(since) or nil
    for day, d in pairs(c and c.days or {}) do
        if not from or day >= from then
            inc, exp = inc + d.inc + (withTransfers and (d.tin or 0) or 0), exp + d.exp + (withTransfers and (d.tout or 0) or 0)
            for k, v in pairs(d.by) do
                if withTransfers or k ~= "transfer" then by[k] = (by[k] or 0) + v end
            end
        end
    end
    return inc, exp, by
end

-- The characters a view covers: { [key] = data }, for "all" or one key.
function Economy.Scope(key)
    if key and key ~= "all" then
        local c = db().economy[key]
        return c and { [key] = c } or {}
    end
    return db().economy
end

-- A cheap look at the data (the "economy" source's signature): writes made
-- without Economy.Changed still show.
function Economy.Signature()
    local parts = {}
    for k, c in pairs(db().economy or {}) do
        local log = c.log or {}
        local last = log[#log]
        parts[#parts + 1] = k .. "/" .. #log .. "/" .. (last and (last.t2 or last.t) or 0) .. "/"
            .. (last and last.amount or 0) .. "/" .. (c.auctions and #c.auctions or 0)
    end
    return table.concat(parts, ":")
end

-- Totals over a scope; transfers count only when it is one character.
-- Memoized: callers must not change the returned `by`.
function Economy.ScopeTotals(key, since)
    local inc, exp, by = unpack(ns.Data.Memo("economy:totals:" .. tostring(key) .. ":" .. tostring(since),
        ns.Data.Key("economy"), function() return { Economy.BuildScopeTotals(key, since) } end))
    return inc, exp, by
end

function Economy.BuildScopeTotals(key, since)
    local inc, exp, by = 0, 0, {}
    local single = key and key ~= "all"
    for _, c in pairs(Economy.Scope(key)) do
        local i, e, b = Economy.Totals(c, since, single)
        inc, exp = inc + i, exp + e
        for k, v in pairs(b) do by[k] = (by[k] or 0) + v end
    end
    return inc, exp, by
end

-- Days over a scope: { [day] = { inc, exp, by, money } }, money summed over
-- characters (each character's last known gold up to that day). Memoized:
-- callers must not change the result.
function Economy.ScopeDays(key)
    local v = ns.Data.Memo("economy:days:" .. tostring(key), ns.Data.Key("economy"), function()
        local out, days = Economy.BuildScopeDays(key)
        return { out, days }
    end)
    return v[1], v[2]
end

function Economy.BuildScopeDays(key)
    local single = key and key ~= "all"
    local out, chars = {}, {}
    for _, c in pairs(Economy.Scope(key)) do
        -- This character's days with a gold reading, oldest first.
        local withMoney = {}
        for day, d in pairs(c.days or {}) do
            local o = out[day] or { inc = 0, exp = 0, by = {} }
            out[day] = o
            o.inc = o.inc + d.inc + (single and (d.tin or 0) or 0)
            o.exp = o.exp + d.exp + (single and (d.tout or 0) or 0)
            for kind, v in pairs(d.by) do
                if single or kind ~= "transfer" then o.by[kind] = (o.by[kind] or 0) + v end
            end
            if d.money then withMoney[#withMoney + 1] = day end
        end
        table.sort(withMoney)
        chars[#chars + 1] = { days = c.days, withMoney = withMoney, i = 0 }
    end
    local days = {}
    for day in pairs(out) do days[#days + 1] = day end
    table.sort(days)
    -- One pass over the days: each character's pointer moves to its last
    -- reading on or before the day.
    for _, day in ipairs(days) do
        local total, any = 0, false
        for _, ch in ipairs(chars) do
            local list = ch.withMoney
            while list[ch.i + 1] and list[ch.i + 1] <= day do ch.i = ch.i + 1 end
            local best = list[ch.i]
            if best then total, any = total + ch.days[best].money, true end
        end
        out[day].money = any and total or nil
    end
    return out, days
end

---------------------------------------------------------------------------
-- Settings page, slash
---------------------------------------------------------------------------
local function BuildPage(parent)
    local W = ns.Options.Widgets
    local y = -12
    y = W.Paragraph(parent, y, "Records every change of your gold with what you were doing: vendor sales and purchases, "
        .. "repairs, loot, quest rewards, trades (partner, items and gold both ways), mail, auction house, training and "
        .. "flights; auctions from posting to sold / expired. Money is shown for all your characters together.", "GameFontHighlightSmall")
    y = W.Button(parent, y, "Open the Economy window", 190, function() if ns.EconomyUI then ns.EconomyUI.Show() end end, "Also " .. ns.Cmd.Text("economy") .. ".")
    y = y - 4
    y = W.Header(parent, y, "Recording")
    y = W.Checkbox(parent, y, "economyEnabled", "Track my money and trades")
    y = W.LiveText(parent, y, 30, function()
        local c = Economy.Char()
        local inc, exp = Economy.Totals(c, nil)
        return string.format("This character: %d transactions; in %s, out %s.", c and #c.log or 0, FormatMoney(inc), FormatMoney(exp))
    end)
    y = W.Header(parent, y, "Delete")
    y = W.Button(parent, y, "Delete this character's economy log", 260, function()
        StaticPopup_Show(ns.POPUP .. "ECONOMY_DELETE", ns.Gear.CharKey() or "?", nil, ns.Gear.CharKey())
    end)
    return -y + 10
end

StaticPopupDialogs[ns.POPUP .. "ECONOMY_DELETE"] = {
    text = "Delete the " .. ns.NAME .. " economy log of %s?",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function(self, key)
        if key then db().economy[key] = nil Changed() end
        ns.Print("economy log deleted.")
        ns.Refresh()
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

if ns.CharacterTab then table.insert(ns.CharacterTab.pages, { label = "Economy", build = BuildPage }) end

local function Slash(command)
    if command ~= "economy" then return false end
    if ns.EconomyUI then ns.EconomyUI.Toggle() end
    return true
end

HookMail()

local events = { "PLAYER_MONEY", "BAG_UPDATE_DELAYED", "PLAYER_ENTERING_WORLD", "TRADE_ACCEPT_UPDATE",
    "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE",
    "TRADE_PLAYER_ITEM_CHANGED", "TRADE_TARGET_ITEM_CHANGED", "TRADE_MONEY_CHANGED" }
for event in pairs(WINDOWS) do events[#events + 1] = event end

ns.Data.Source("economy", { sig = Economy.Signature })

ns.RegisterModule("Economy", {
    defaults = { economyEnabled = true, economy = {} },
    events = events,
    onEvent = OnEvent,
    tick = Tick,
    slash = Slash,
})
