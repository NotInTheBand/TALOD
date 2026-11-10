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
    local mine = key == nil
    key = key or (ns.Gear and ns.Gear.CharKey())
    if not key then return nil end
    local c = db().economy[key]
    if not c then
        c = { log = {}, days = {} }
        db().economy[key] = c
    end
    -- Your name the server's way: on WoW Forever mail and trades name you
    -- "First Surname", which the key ("First-Realm") does not hold.
    if mine and ns.Guild and ns.Guild.Me then
        local full = ns.Guild.Me()
        if type(full) == "string" and c.full ~= full then c.full = full end
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

-- "Linen Cloth (5)" -> "Linen Cloth", 5: a stack's letter may name its count.
local function SplitCount(name)
    if type(name) ~= "string" then return nil, nil end
    local base, n = name:match("^(.-)%s*%((%d+)%)$")
    if base and base ~= "" then return base, tonumber(n) end
    return name, nil
end

-- Units returned by an expired / cancelled letter: every attachment summed. A
-- modern commodity listing can be larger than a stack, and comes back split
-- into stacks: the first one alone would close a smaller listing instead.
-- [VERIFY] how Forever returns a large expired commodity listing.
local function AttachedCount(index)
    local max = type(ATTACHMENTS_MAX_RECEIVE) == "number" and ATTACHMENTS_MAX_RECEIVE or 16
    local total, any = 0, false
    for j = 1, max do
        local count = Num(select(4, S.CallMulti(4, GetInboxItem, index, j)))
        if count then total, any = total + count, true end
    end
    return any and total or nil
end

function Economy.DescribeMail(index)
    local _, _, sender, subject, money, cod, daysLeft = S.CallMulti(7, GetInboxHeaderInfo, index)
    -- Classic invoices also carry the sale (bid), buyout, deposit and the house's cut, and on
    -- newer clients the count: they tell two listings of one item apart. [VERIFY] on Forever.
    local invoiceType, itemName, playerName, bid, buyout, deposit, cut, _, _, _, count = S.CallMulti(11, GetInboxInvoiceInfo, index)
    local arrived = (type(daysLeft) == "number" and daysLeft >= 0 and daysLeft <= MAIL_DAYS)
        and math.floor(time() - (MAIL_DAYS - daysLeft) * 86400) or nil
    -- The buyer's name can be empty (seen on Forever).
    if playerName == "" then playerName = nil end
    local named
    itemName, named = SplitCount(itemName)
    count = Num(count) or named
    if invoiceType == "seller" then
        return "Auction sold: " .. tostring(itemName or "?") .. (playerName and (" to " .. playerName) or ""), "auction",
            { status = "sold", item = itemName, arrived = arrived, count = count, bid = Num(bid), buyout = Num(buyout),
              deposit = Num(deposit), cut = Num(cut) }
    elseif invoiceType == "buyer" then
        return "Auction won: " .. tostring(itemName or "?") .. (playerName and (" from " .. playerName) or ""), "auction",
            { status = "won", item = itemName, count = count }
    elseif invoiceType == "seller_temp_invoice" then
        return "Auction sold (pending): " .. tostring(itemName or "?"), "auction", { status = "pending", item = itemName }
    end
    local subj = type(subject) == "string" and subject or ""
    for _, prefix in ipairs(Economy.AuctionSubjects()) do
        if subj:sub(1, #prefix) == prefix then
            local item = subj:sub(#prefix + 1):gsub("^[:%s]+", "")
            local lower = prefix:lower()
            local status = lower:find("expire") and "expired" or lower:find("cancel") and "cancelled" or lower:find("outbid") and "outbid" or nil
            local base, n = SplitCount(item)
            if status == "expired" or status == "cancelled" then n = AttachedCount(index) or n end
            return subj, "auction", { status = status, item = base ~= "" and base or nil, arrived = arrived, count = n }
        end
    end
    if type(sender) == "string" and Economy.IsOwn(sender) then
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

-- How well a letter's facts fit an open listing: count, deposit and buyout
-- each count when both sides know them; a count that differs weighs most
-- (still a candidate: a commodity can sell part of its stack). Our deposit is
-- the post's paid deposits spread over its listings, so it may be off by rounding.
local function Fit(a, hint)
    if not hint then return 0 end
    local score = 0
    if hint.count and a.count then
        score = score + (hint.count == a.count and 4 or -8)
    end
    if hint.deposit and a.deposit then
        if math.abs(hint.deposit - a.deposit) <= math.max(1, hint.deposit * 0.05) then score = score + 2 else score = score - 2 end
    end
    if hint.buyout and hint.buyout > 0 and a.buyout then
        if hint.buyout == a.buyout then score = score + 2 else score = score - 1 end
    end
    return score
end

-- Closes the open listing of this item that a letter is about: the one whose
-- count / deposit / buyout fit the letter best (hint, from the invoice, the
-- subject or the returned stack), oldest first among equals. Without any of
-- those it is the oldest listing of the item. arrived: when its letter came;
-- closedAt = when it really sold / ended (ended = when you took the letter).
local function SettleListing(c, itemName, status, received, arrived, hint)
    if not c.auctions or not itemName then return nil end
    -- When the letter says when it came: the auction ended before that (a sale
    -- an hour before its letter). A listing posted after that time cannot be
    -- the one (a sale before the post is the wrong listing, not a sell time
    -- of 0); one whose duration covers that time fits better. SOLD_MAIL_DELAY
    -- of slack: `arrived` comes from the letter's days left, not exact.
    local at = arrived and (arrived - (status == "sold" and SOLD_MAIL_DELAY or 0)) or nil
    local best, bestScore
    for _, a in ipairs(c.auctions) do
        if a.status == "listed" and ShortName(a.name) == itemName
            and not (at and a.t and a.t > at + SOLD_MAIL_DELAY) then
            local score = Fit(a, hint)
            local hours = at and a.t and type(a.duration) == "string" and tonumber(a.duration:match("^(%d+)"))
            if hours and at <= a.t + hours * 3600 + SOLD_MAIL_DELAY then score = score + 1 end
            if not bestScore or score > bestScore then best, bestScore = a, score end
        end
    end
    local a = best
    if not a then return nil end
    -- A commodity sold in parts: the letter is for some of the listing. That
    -- part becomes its own sold row with its share of the deposit; the rest
    -- stays listed for the next letter.
    if status == "sold" and hint and hint.count and a.count and hint.count < a.count then
        local k = hint.count
        local share = a.deposit and math.floor(a.deposit * k / a.count + 0.5) or nil
        c.nextAuction = (c.nextAuction or 0) + 1
        local part = {}
        for f, v in pairs(a) do part[f] = v end
        part.id, part.count, part.deposit = c.nextAuction, k, share
        -- Every row of the posting names it (id and posting time: ids are per
        -- character): the sell rate counts the posting once, not each part.
        a.of = a.of or ((a.id or 0) .. "@" .. (a.t or 0))
        part.of = a.of
        part.buyout = a.buyout and math.floor(a.buyout * k / a.count + 0.5) or nil
        a.count, a.deposit = a.count - k, a.deposit and (a.deposit - share) or nil
        a.buyout = a.buyout and (a.buyout - part.buyout) or nil
        for i, x in ipairs(c.auctions) do
            if x == a then table.insert(c.auctions, i + 1, part) break end
        end
        a = part
    end
    a.status, a.ended = status, time()
    Changed()
    if hint and hint.deposit and not a.deposit then a.deposit = hint.deposit end
    if arrived then
        a.closedAt = math.max(a.t or 0, arrived - (status == "sold" and SOLD_MAIL_DELAY or 0))
    end
    if received then
        a.received = received
        a.profit = received - (a.deposit or 0)
    end
    return a
end
Economy.SettleListing = SettleListing

-- A post's paid deposits over its listings in whole copper that add up to
-- what was paid: floor(paid / n) each and 1c more for the first paid % n
-- (100c over 3 is 34 + 33 + 33, not 33 x 3 = 99).
local function SpreadDeposit(post)
    local n = post.made and #post.made or 0
    if n == 0 or not post.paid then return end
    local base, extra = math.floor(post.paid / n), post.paid % n
    for i, a in ipairs(post.made) do a.deposit = base + (i <= extra and 1 or 0) end
end

-- Names of your characters, for transfers: "name-realm" (lower case, realm
-- without spaces or hyphens), from the character keys and, on WoW Forever,
-- the server's "First Surname-Realm" each character noted (economy[key].full).
-- A name alone is a different player on another realm.
local function NameKey(name, realm)
    return (tostring(name) .. "-" .. tostring(realm):gsub("[%s%-]", "")):lower()
end

function Economy.OwnNames()
    local names = {}
    for _, store in ipairs({ db().economy or {}, db().gear or {} }) do
        for key, c in pairs(store) do
            local name, realm = tostring(key):match("^([^-]+)%-(.+)$")
            if name then names[NameKey(name, realm)] = true end
            if type(c) == "table" and type(c.full) == "string" then
                local fn, fr = c.full:match("^(.+)%-([^%-]+)$")
                if fn then names[NameKey(fn, fr)] = true end
            end
        end
    end
    return names
end

-- Whether a mail sender / recipient or trade partner is one of your
-- characters. A name without a realm is on yours (mail and trade reach only it).
function Economy.IsOwn(name)
    if type(name) ~= "string" or name == "" then return false end
    local G = ns.Guild
    if G and G.Normal then name = G.Normal(name) or name end
    local n, realm = name:match("^(.+)%-([^%-]+)$")
    if not n then n, realm = name, S.Call(GetRealmName) end
    if type(realm) ~= "string" then return false end
    return Economy.OwnNames()[NameKey(n, realm)] == true
end

-- Letters taken from, oldest first, each waiting for its money / items. The
-- server answers each take later, so with Open All or quick clicks several
-- letters are taken before the first one's money arrives: one slot would
-- give that money the next letter's name and leave the last one unnamed.
local MAIL_WAIT = 60
local mailQueue = {}
local sendMoney                -- copper set on the letter being written (SetSendMailMoney)

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
    -- The gold put on a letter: the mail frame sets it just before sending.
    if type(SetSendMailMoney) == "function" then
        hooksecurefunc("SetSendMailMoney", function(copper) sendMoney = Num(copper) end)
    end
    if type(SendMail) == "function" then
        hooksecurefunc("SendMail", function(recipient, subject)
            if not db().economyEnabled then return end
            local own = Economy.IsOwn(recipient)
            detail.mail = "to " .. tostring(recipient or "?") .. ((type(subject) == "string" and subject ~= "") and (": " .. subject) or "")
            detail.mailAs, detail.mailInfo = own and "transfer" or nil, nil
            -- How much of the letter's cost is gold sent (the rest is postage). [VERIFY] whether
            -- GetSendMailMoney still holds it once SendMail returned.
            detail.mailMoney = sendMoney or Num(S.Call(GetSendMailMoney))
            sendMoney = nil
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
            local name, second = S.CallMulti(2, UnitName, "NPC")
            -- The partner's full name the server's way (on Forever the second value is the surname).
            local full = type(name) == "string" and ns.Guild and ns.Guild.FullName and ns.Guild.FullName(name, type(second) == "string" and second or nil) or nil
            trade = { partner = type(name) == "string" and name or "?", full = full, give = {}, get = {}, giveMoney = 0, getMoney = 0 }
        end
    else
        if not open[kind] then return end
        open[kind] = nil
        closed[kind] = GetTime()
        if kind == "mail" then sendMoney = nil end
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

-- refund: the part of a gain that is your own money coming back (an outbid
-- bid, a sold auction's deposit). It is kept apart (d.ref) and taken off the
-- spending when totals are read, so a bid and its return are neither income
-- nor spending; the day's net and by-kind figures are unchanged.
local function AddDay(c, t, amount, kind, money, refund)
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
        -- Nor for this session's net (always the current character's data).
        if session and amount ~= 0 then session.moved = (session.moved or 0) + amount end
    else
        refund = (amount > 0 and refund and refund > 0) and math.min(refund, amount) or 0
        if refund > 0 then d.ref = (d.ref or 0) + refund end
        if amount > 0 then d.inc = d.inc + amount - refund elseif amount < 0 then d.exp = d.exp - amount end
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
    -- Never across midnight: the entry's whole amount is shown on its day, as
    -- the day totals book each part on its own.
    if e.kind == "loot" and last and last.kind == "loot" and last.zone == e.zone and e.t - (last.t2 or last.t) <= LOOT_MERGE
        and Today(e.t) == Today(last.t) then
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
-- answers in one settle), else the oldest one with money the same way. A take
-- that moves no money (or money the other way) never explains a money change:
-- it would swallow gold you mailed out under another sender's name.
-- exact: only a letter with exactly this money (a sent letter is the other candidate).
-- ItemLetters(gained): the letters that move no money but whose items arrived
-- in this settle ({ link, n } gained), every one of them, taken off the queue:
-- with Open All several returned auctions (and a sale's money) land in one
-- settle, and each closes its own listing.
local function ItemLetters(gained)
    local now = GetTime()
    while mailQueue[1] and now - mailQueue[1].at > MAIL_WAIT do table.remove(mailQueue, 1) end
    local units = {}
    for _, it in ipairs(gained or {}) do
        local name = ShortName(it[1])
        units[name] = (units[name] or 0) + it[2]
    end
    local out, i = {}, 1
    while next(units) and mailQueue[i] do
        local m = mailQueue[i]
        local item = m.amount == 0 and m.info and m.info.item
        local need = item and (m.info.count or 1)
        if item and units[item] and units[item] >= need then
            units[item] = units[item] - need
            if units[item] <= 0 then units[item] = nil end
            out[#out + 1] = table.remove(mailQueue, i)
        else
            i = i + 1
        end
    end
    return out
end

local function TakeLetters(dMoney, exact)
    local now = GetTime()
    while mailQueue[1] and now - mailQueue[1].at > MAIL_WAIT do table.remove(mailQueue, 1) end
    if #mailQueue == 0 then return {} end
    if dMoney ~= 0 then
        local function Same(m) return m.amount ~= 0 and (m.amount > 0) == (dMoney > 0) end
        for i, m in ipairs(mailQueue) do
            if m.amount == dMoney then return { table.remove(mailQueue, i) } end
        end
        if exact then return {} end
        local sum, n = 0, 0
        for _, m in ipairs(mailQueue) do
            if Same(m) then
                sum, n = sum + m.amount, n + 1
                if sum == dMoney then break end
            end
        end
        if n > 1 and sum == dMoney then
            local out, i = {}, 1
            while #out < n do
                if Same(mailQueue[i]) then out[#out + 1] = table.remove(mailQueue, i) else i = i + 1 end
            end
            return out
        end
        for i, m in ipairs(mailQueue) do
            if Same(m) then return { table.remove(mailQueue, i) } end
        end
        return {}
    end
    -- Items only: the oldest take that moves no money, else the oldest one.
    for i, m in ipairs(mailQueue) do
        if m.amount == 0 then return { table.remove(mailQueue, i) } end
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
        local itemLetters = ItemLetters(e.gained)
        local letters
        if dMoney == 0 and #itemLetters > 0 then
            letters = {}
        elseif dMoney < 0 and detail.mail then
            -- Money going out right after SendMail is that letter's (postage, gold sent),
            -- unless a taken letter asks exactly this much (COD).
            letters = TakeLetters(dMoney, true)
        else
            letters = TakeLetters(dMoney)
        end
        if #letters == 0 and detail.mail and not (dMoney == 0 and #itemLetters > 0) then
            -- Sent mail (postage, COD sent): named by the SendMail hook. Gold sent to one of
            -- your characters is a transfer; the postage is still a mail cost.
            local sent = detail.mailMoney
            if detail.mailAs == "transfer" and sent and sent > 0 and dMoney < -sent then
                letters = { { text = detail.mail, as = "transfer", amount = -sent }, { text = detail.mail .. " (postage)" } }
            else
                letters = { { text = detail.mail, as = detail.mailAs } }
            end
        end
        detail.mail, detail.mailAs, detail.mailInfo, detail.mailMoney = nil, nil, nil, nil
        if #letters == 0 and (dMoney ~= 0 or #itemLetters == 0) then letters = { {} } end
        -- The letters that moved no money first: the money goes to the last one.
        for i = #itemLetters, 1, -1 do table.insert(letters, 1, itemLetters[i]) end
        local left = dMoney
        for i, m in ipairs(letters) do
            local le = i == 1 and e or { t = now, kind = "mail", zone = e.zone, level = e.level }
            le.amount = i == #letters and left or m.amount
            left = left - le.amount
            le.detail = m.text
            if m.as then le.kind = m.as end
            local info = m.info
            local refund
            if le.kind == "auction" and info then
                le.sub = info.status
                local a = (info.status == "sold" or info.status == "expired" or info.status == "cancelled")
                    and SettleListing(c, info.item, info.status, info.status == "sold" and le.amount > 0 and le.amount or nil, info.arrived, info)
                if a then le.listing = a.id end
                if le.amount > 0 then
                    -- A sale letter pays the deposit back with the sale; an outbid letter returns your bid.
                    if info.status == "sold" then refund = info.deposit or (a and a.deposit)
                    elseif info.status == "outbid" then refund = le.amount end
                end
            end
            if refund and refund > 0 then le.refund = math.min(refund, le.amount) end
            AddDay(c, now, le.amount, le.kind, money, le.refund)
            Record(c, le)
        end
        return
    elseif e.kind == "auction" then
        local nowT = GetTime()
        if pendingPost and pendingPost.done and nowT - pendingPost.at < 15 and dMoney < 0 and not e.lost
            and not (pendingBuy and nowT - pendingBuy.at < 15) then
            -- A deposit charged after the post's last listing was made: the server
            -- charges in batches that need not match the items, so the last one can
            -- come in the next settle. It is the same post's (no new listing).
            local post = pendingPost
            post.paid = (post.paid or 0) - dMoney
            SpreadDeposit(post)
            local listing = post.made[#post.made]
            e.sub, e.listing = "posted", listing and listing.id
            e.detail = "deposit for " .. tostring(listing and listing.name or post.name)
        elseif pendingPost and not pendingPost.done and nowT - pendingPost.at < 15 then
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
                -- Every listing is made; a deposit can still follow (above).
                post.stacks, post.at, post.done = 0, nowT, true
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
            SpreadDeposit(post)
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
            e.sub, e.detail, e.refund = "refund", "refund", dMoney
        end
    end
    if e.kind == "trade" and trade then
        e.detail = trade.partner
        e.gave, e.got = trade.give, trade.get
        e.gaveMoney, e.gotMoney = trade.giveMoney, trade.getMoney
    end
    -- After the partner is known: a trade with one of your own characters is a transfer.
    if e.kind == "trade" and e.detail and Economy.IsOwn((trade and trade.full) or tostring(e.detail)) then e.kind = "transfer" end
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
    AddDay(c, now, dMoney, e.kind, money, e.refund)
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
-- Gold moved to or from your own characters is left out (like the account
-- totals) and returned fourth.
function Economy.Session()
    local now = Money()
    if not session or not now then return nil end
    local moved = session.moved or 0
    local net = now - session.money - moved
    local hours = (GetTime() - session.at) / 3600
    return net, hours >= 5 / 60 and math.floor(net / hours + 0.5) or nil, hours, moved
end

-- Local midnight `back` days before the day of `t` (now by default). Built
-- from the calendar date, not by subtracting hours: on a clock-change day a
-- day is 23 or 25 hours long.
function Economy.DayStart(t, back)
    local d = date("*t", t or time())
    return time({ year = d.year, month = d.month, day = d.day - (back or 0), hour = 0, min = 0, sec = 0 })
end

-- A listing no letter closed whose time is up (its duration and the mail's
-- delay past its post): it cannot still be listed, and how it ended is
-- unknown. An unknown duration counts as the longest (48 h).
function Economy.ListingOver(a, now)
    if not a or a.status ~= "listed" or not a.t then return false end
    local hours = type(a.duration) == "string" and tonumber(a.duration:match("^(%d+)")) or 48
    return (now or time()) > a.t + hours * 3600 + SOLD_MAIL_DELAY
end

-- What a set of listings came to: counts by outcome, what sales paid,
-- deposits lost (unsold: expired or cancelled; a sold auction's deposit comes
-- back with the sale) and profit = sum over sold of (received - deposit)
-- minus the deposits lost. Listings still up are not counted in the money.
function Economy.AuctionTotals(auctions)
    local t = { listed = 0, sold = 0, expired = 0, cancelled = 0, income = 0, lost = 0, profit = 0, unknown = 0 }
    local now = time()
    for _, a in ipairs(auctions or {}) do
        if Economy.ListingOver(a, now) then t.unknown = t.unknown + 1
        elseif a.status == "listed" then t.listed = t.listed + 1
        elseif a.status == "sold" then
            t.sold = t.sold + 1
            -- What the sale kept after the cut: the letter also pays your own
            -- deposit back, which is not sale money. A sale whose payment is
            -- unknown is counted apart (unpriced), never as 0.
            if a.received then
                t.income = t.income + (a.received - (a.deposit or 0))
            else
                t.unpriced = (t.unpriced or 0) + 1
            end
            t.profit = t.profit + (a.received and (a.received - (a.deposit or 0)) or 0)
        elseif a.status == "expired" or a.status == "cancelled" then
            t[a.status] = t[a.status] + 1
            t.lost = t.lost + (a.deposit or 0)
            t.profit = t.profit - (a.deposit or 0)
        end
    end
    return t
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

-- Refunds (your own money back) come off the spending; more back than was
-- spent in the period (a bid placed before it) is income. Net is unchanged.
local function NetRefunds(inc, exp, ref)
    if not ref or ref <= 0 then return inc, exp end
    exp = exp - ref
    if exp < 0 then inc, exp = inc - exp, 0 end
    return inc, exp
end
Economy.NetRefunds = NetRefunds

-- Raw sums: income, expense, by kind, refunds.
local function RawTotals(c, since, withTransfers)
    local inc, exp, ref, by = 0, 0, 0, {}
    local from = since and Today(since) or nil
    for day, d in pairs(c and c.days or {}) do
        if not from or day >= from then
            inc, exp = inc + d.inc + (withTransfers and (d.tin or 0) or 0), exp + d.exp + (withTransfers and (d.tout or 0) or 0)
            ref = ref + (d.ref or 0)
            for k, v in pairs(d.by) do
                if withTransfers or k ~= "transfer" then by[k] = (by[k] or 0) + v end
            end
        end
    end
    return inc, exp, by, ref
end

-- Income, expense and by-kind net over days since `since` (time; nil = all)
-- for one character's data. withTransfers: count money moved between your
-- characters (a single character's view).
function Economy.Totals(c, since, withTransfers)
    local inc, exp, by, ref = RawTotals(c, since, withTransfers)
    inc, exp = NetRefunds(inc, exp, ref)
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
    local inc, exp, ref, by = 0, 0, 0, {}
    local single = key and key ~= "all"
    for _, c in pairs(Economy.Scope(key)) do
        local i, e, b, r = RawTotals(c, since, single)
        inc, exp, ref = inc + i, exp + e, ref + r
        for k, v in pairs(b) do by[k] = (by[k] or 0) + v end
    end
    inc, exp = NetRefunds(inc, exp, ref)
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
            local o = out[day] or { inc = 0, exp = 0, ref = 0, by = {} }
            out[day] = o
            o.inc = o.inc + d.inc + (single and (d.tin or 0) or 0)
            o.exp = o.exp + d.exp + (single and (d.tout or 0) or 0)
            o.ref = o.ref + (d.ref or 0)
            for kind, v in pairs(d.by) do
                if single or kind ~= "transfer" then o.by[kind] = (o.by[kind] or 0) + v end
            end
            if d.money then withMoney[#withMoney + 1] = day end
        end
        table.sort(withMoney)
        chars[#chars + 1] = { days = c.days, withMoney = withMoney, i = 0 }
    end
    local days = {}
    for day, o in pairs(out) do
        days[#days + 1] = day
        o.inc, o.exp = NetRefunds(o.inc, o.exp, o.ref)
    end
    table.sort(days)
    -- One pass over the days: each character's pointer moves to its last
    -- reading on or before the day.
    -- Before a character's first reading its gold is unknown, not 0: a sum
    -- over several characters is known only from the day each of them has one
    -- (an alt first logged in with 1000g is not a 1000g gain).
    local readers = 0
    for _, ch in ipairs(chars) do if #ch.withMoney > 0 then readers = readers + 1 end end
    for _, day in ipairs(days) do
        local total, have = 0, 0
        for _, ch in ipairs(chars) do
            local list = ch.withMoney
            while list[ch.i + 1] and list[ch.i + 1] <= day do ch.i = ch.i + 1 end
            local best = list[ch.i]
            if best then total, have = total + ch.days[best].money, have + 1 end
        end
        out[day].money = (have > 0 and have == readers) and total or nil
    end
    return out, days
end

---------------------------------------------------------------------------
-- Settings page, slash
---------------------------------------------------------------------------
local function StatusText()
    local c = Economy.Char()
    local inc, exp = Economy.Totals(c, nil)
    return string.format("This character: %d transactions; in %s, out %s.", c and #c.log or 0, FormatMoney(inc), FormatMoney(exp))
end

local function BuildSettings(parent, y)
    local W = ns.Options.Widgets
    y = W.Paragraph(parent, y, "Records every change of your gold with what you were doing: vendor sales and purchases, "
        .. "repairs, loot, quest rewards, trades (partner, items and gold both ways), mail, auction house, training and "
        .. "flights; auctions from posting to sold / expired. Money is shown for all your characters together. Also "
        .. ns.Cmd.Text("economy") .. ".", "GameFontHighlightSmall")
    y = W.Checkbox(parent, y, "economyEnabled", "Track my money and trades")
    return y
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

ns.Options.AddSection("gold", { status = StatusText, groups = { { label = "Recording", build = BuildSettings } } })

-- /talod gold (economy): the Gold page; /talod gold <tab> opens that tab
-- (auctions: the Auction House page's My auctions).
local function Slash(command, rest)
    if command ~= "economy" then return false end
    local tab = (rest or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if not ns.EconomyUI then return true end
    if tab == "" then ns.EconomyUI.Toggle() else ns.EconomyUI.ShowPage(tab) end
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
