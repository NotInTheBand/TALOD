-- TALOD - Craft tracker: one recipe you want to make, its cheapest route
-- (buy each material, or make it when you can and that is cheaper), and your
-- progress as materials reach your bags or your mailbox.
--
-- Route: an item is bought at its best known price (Professions.ItemPrice:
-- vendor, your AH looks, else Wowhead's average) or made by a recipe this
-- character can make (the profession at its skill and, once the profession
-- window was read, the recipe known), whichever is cheaper per unit. What you
-- hold counts first (bags, then the mailbox), from the top of the tree down.
--
-- Purchases: a buyout on the Auction House (PlaceAuctionBid at the buyout,
-- C_AuctionHouse.ConfirmCommoditiesPurchase) is held until money leaves
-- (PLAYER_MONEY) or the game says "You won an auction" (CHAT_MSG_SYSTEM),
-- then counted as "in the mailbox (Auction House)" until the mailbox is read.
-- An open mailbox is read whole (MAIL_INBOX_UPDATE): its counts replace the
-- purchases made before it. The won message alone (C_AuctionHouse.PlaceBid,
-- whose item is not known at the bid) counts one; the next mailbox read gives
-- the true count. [VERIFY] the won message and the letter arriving at once.
--
-- Crafting: one click = one game command (Professions.Craft: the step's count,
-- like the Create button with a count). The addon never queues or chains the
-- steps: after one finishes, the next click starts the next.
--
-- Saved per character: TALODDB.craftTrack[char] = { id = recipe spell ID,
-- n = crafts wanted, t = started, done0 = crafts logged before, mail = {
-- [itemID] = { a = from the Auction House, o = other letters } }, mailT,
-- buys = { { id, n, t } } (confirmed, after mailT) }.

local ADDON_NAME, ns = ...
local S = ns.Secret

local Track = {}
ns.CraftTrack = Track

local MAX_DEPTH = 6
local CONFIRM_SECONDS = 15     -- a buyout counts once money leaves within this
local BUY_KEEP = 7 * 86400     -- purchases never seen in a mailbox read are dropped after this

local function db() return ns.DB() end
local function P() return ns.Professions end
local function DATA() return ns.ProfessionData or { recipes = {}, items = {} } end
local function Num(x) return type(x) == "number" and x == x and x or nil end

local function Store()
    if type(db().craftTrack) ~= "table" then db().craftTrack = {} end
    return db().craftTrack
end

function Track.Current(charKey)
    charKey = charKey or ns.Gear.CharKey()
    local t = charKey and Store()[charKey]
    if t and not DATA().recipes[t.id] then return nil end
    return t
end

local function Changed() ns.Data.Changed("crafttrack") end

---------------------------------------------------------------------------
-- What this character can make
---------------------------------------------------------------------------
-- ok, why: why = "skill" (rank too low or no profession), "unlearned" (the
-- profession window says not known), "unread" (skill allows it, window never
-- read: maybe not learned). The game's spell list wins over both: the saved
-- recipe list misses what was learned since the window was last read.
function Track.CanCraft(r, charKey)
    if charKey == ns.Gear.CharKey() and P().KnowsSpell(r) then return true end
    local c = charKey and db().skills and db().skills[charKey]
    local s = c and c.current and c.current[r.prof]
    if not s or (s.rank or 0) < (r.skill or 0) then return false, "skill" end
    local known = P().Known(charKey, r.prof)
    if known then
        if known[r.name] then return true end
        return false, "unlearned"
    end
    return true, "unread"
end

-- Cheapest way to get one unit: { unit, how = "buy" / "craft" / nil, r,
-- src, cannot = { recipes you cannot make } }. unit nil = no price at all.
local function Best(id, ctx, depth)
    local m = ctx.best[id]
    if m then return m end
    if m == false then return { cycle = true } end
    ctx.best[id] = false
    local unit, src = P().ItemPrice(id)
    if src == "unknown" then unit = nil end
    local best = { unit = unit, how = unit and "buy" or nil, src = src }
    if depth < MAX_DEPTH then
        for _, r in ipairs(ns.Market.MadeBy(id)) do
            if Track.CanCraft(r, ctx.char) then
                local cost, ok = 0, true
                for _, rg in ipairs(r.reagents or {}) do
                    local b = Best(rg[1], ctx, depth + 1)
                    if not b.unit then ok = false break end
                    cost = cost + rg[2] * b.unit
                end
                local each = ok and cost / math.max(r.makes or 1, 1) or nil
                if each and (not best.unit or each < best.unit) then
                    best = { unit = each, how = "craft", r = r, src = src, buyUnit = unit }
                end
            else
                best.cannot = best.cannot or {}
                best.cannot[#best.cannot + 1] = r
            end
        end
    end
    if best.how == "craft" and best.buyUnit == nil then best.buyUnit = unit end
    ctx.best[id] = best
    return best
end

-- One node: { id, need, have, mailA, mailO, left, how, unit, buy, cost,
-- r, crafts, children, cannot }.
local function Expand(id, need, ctx, depth)
    local node = { id = id, need = need }
    local have = math.min(ctx.bags[id] or 0, need)
    ctx.bags[id] = (ctx.bags[id] or 0) - have
    local rest = need - have
    local m = ctx.mail[id]
    local a = m and math.min(m.a, rest) or 0
    if m then m.a = m.a - a end
    rest = rest - a
    local o = m and math.min(m.o, rest) or 0
    if m then m.o = m.o - o end
    rest = rest - o
    node.have, node.mailA, node.mailO, node.left = have, a, o, rest
    local best = Best(id, ctx, depth)
    node.unit, node.how, node.cannot, node.src = best.unit, best.how, best.cannot, best.src
    if rest > 0 then
        if best.how == "craft" and depth < MAX_DEPTH then
            local r = best.r
            node.r, node.crafts, node.children = r, math.ceil(rest / math.max(r.makes or 1, 1)), {}
            for _, rg in ipairs(r.reagents or {}) do
                node.children[#node.children + 1] = Expand(rg[1], rg[2] * node.crafts, ctx, depth + 1)
            end
            ctx.steps[#ctx.steps + 1] = node
        else
            node.buy = rest
            node.cost = best.unit and best.unit * rest or nil
            ctx.shop[#ctx.shop + 1] = node
            if best.unit then ctx.buyCost = ctx.buyCost + node.cost else ctx.unpriced = ctx.unpriced + 1 end
        end
    end
    return node
end

-- Mailbox counts: the last read plus purchases confirmed since.
function Track.Mail(t)
    local out = {}
    for id, m in pairs(t and t.mail or {}) do out[id] = { a = m.a or 0, o = m.o or 0 } end
    for _, b in ipairs(t and t.buys or {}) do
        out[b.id] = out[b.id] or { a = 0, o = 0 }
        out[b.id].a = out[b.id].a + b.n
    end
    return out
end

-- Crafts of the recipe logged since tracking began.
function Track.Done(t, charKey)
    local n = 0
    for _, e in ipairs(P().Crafts(charKey)) do if e.id == t.id then n = n + (e.n or 0) end end
    return math.max(0, n - (t.done0 or 0))
end

-- The whole plan for the tracked recipe (or `r`, `count` to preview one).
-- { r, count, done, left, root, steps (crafts, deepest first), shop (to
-- buy), buyCost, unpriced, value, canCraft, why }.
function Track.Plan(r, count, charKey)
    charKey = charKey or ns.Gear.CharKey()
    local t = Track.Current(charKey)
    if not r then
        if not t then return nil end
        r, count = DATA().recipes[t.id], t.n
    end
    local tracked = t and DATA().recipes[t.id] == r
    local done = tracked and Track.Done(t, charKey) or 0
    local left = math.max(0, (count or 1) - done)
    local bags = {}
    for id, b in pairs(ns.Data.Bags()) do bags[id] = b.n end
    local ctx = { char = charKey, best = {}, bags = bags, mail = tracked and Track.Mail(t) or {}, steps = {}, shop = {},
        buyCost = 0, unpriced = 0 }
    local root = { id = r.creates, need = left * (r.makes or 1), r = r, crafts = left, children = {}, how = "craft", root = true,
        have = 0, mailA = 0, mailO = 0, left = left }
    for _, rg in ipairs(r.reagents or {}) do
        root.children[#root.children + 1] = Expand(rg[1], rg[2] * left, ctx, 1)
    end
    if left > 0 then ctx.steps[#ctx.steps + 1] = root end
    local ok, why = Track.CanCraft(r, charKey)
    local plan = { r = r, count = count or 1, done = done, left = left, root = root, steps = ctx.steps, shop = ctx.shop,
        buyCost = ctx.buyCost, unpriced = ctx.unpriced, canCraft = ok, why = why, tracked = tracked }
    local pr = ns.Market.CraftProfit(r)
    plan.value = pr.priced and pr.value * left or nil
    -- Each step ready when every material it needs is in your bags.
    for _, step in ipairs(plan.steps) do
        step.ready = true
        for _, ch in ipairs(step.children) do
            if ch.have < ch.need then step.ready = false end
        end
        if step.ready and not plan.next then plan.next = step end
    end
    return plan
end

---------------------------------------------------------------------------
-- Tracking
---------------------------------------------------------------------------
function Track.Start(r, count, charKey)
    charKey = charKey or ns.Gear.CharKey()
    if not (r and r.id and charKey) then return false end
    local done0 = 0
    for _, e in ipairs(P().Crafts(charKey)) do if e.id == r.id then done0 = done0 + (e.n or 0) end end
    local old = Store()[charKey]
    Store()[charKey] = { id = r.id, n = math.max(1, math.floor(count or 1)), t = time(), done0 = done0,
        mail = old and old.mail or {}, mailT = old and old.mailT or nil, buys = old and old.buys or {} }
    Changed()
    return true
end

function Track.SetCount(n, charKey)
    local t = Track.Current(charKey)
    if not t then return end
    t.n = math.max(1, math.min(999, math.floor(n)))
    Changed()
end

function Track.Stop(charKey)
    charKey = charKey or ns.Gear.CharKey()
    local t = charKey and Store()[charKey]
    if not t then return end
    -- The mailbox counts stay: they are still true for the next craft.
    Store()[charKey] = { mail = t.mail, mailT = t.mailT, buys = t.buys }
    Changed()
end

-- Items the tracked plan still has to buy: { { id, n } } (AH helper's list).
function Track.Missing(charKey)
    local plan = Track.Plan(nil, nil, charKey)
    local out = {}
    for _, node in ipairs(plan and plan.shop or {}) do
        if node.src ~= "vendor" then out[#out + 1] = { id = node.id, n = node.buy } end
    end
    return out
end

-- One click: the next step that has its materials, as one game command.
function Track.CraftNext(charKey)
    local plan = Track.Plan(nil, nil, charKey)
    if not plan then return false, "nothing tracked." end
    if plan.left <= 0 then return false, plan.r.name .. ": done." end
    local step = plan.next
    if not step then return false, "no step has all its materials in your bags yet." end
    -- No check of our own here: the saved recipe list and rank can be stale,
    -- and Professions.Craft asks the open profession window, which knows.
    return P().Craft(step.r, step.crafts)
end

---------------------------------------------------------------------------
-- Purchases and the mailbox
---------------------------------------------------------------------------
local tentative = {}       -- { { id, n, at (GetTime) } } buyouts not yet confirmed

local function Hold(id, n)
    id, n = Num(id), Num(n) or 1
    if not id then return end
    tentative[#tentative + 1] = { id = id, n = n, at = GetTime() }
end

local function Confirm(entry)
    local t = Store()
    local key = ns.Gear.CharKey()
    if not key then return end
    t[key] = t[key] or {}
    local c = t[key]
    c.buys = c.buys or {}
    c.buys[#c.buys + 1] = { id = entry.id, n = entry.n, t = time() }
    Changed()
end

local function Prune()
    local now = GetTime()
    for i = #tentative, 1, -1 do
        if now - tentative[i].at > CONFIRM_SECONDS then table.remove(tentative, i) end
    end
end

local function ItemIDFromLink(link)
    return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

local function HookBuys()
    if type(PlaceAuctionBid) == "function" then
        hooksecurefunc("PlaceAuctionBid", function(listType, index, bid)
            local _, _, count, _, _, _, _, _, _, buyout = S.CallMulti(10, GetAuctionItemInfo, listType, index)
            bid, buyout = Num(bid), Num(buyout)
            -- Only a buyout is yours at once; a bid can still be outbid.
            if not (bid and buyout and buyout > 0 and bid >= buyout) then return end
            local link = type(GetAuctionItemLink) == "function" and S.Call(GetAuctionItemLink, listType, index) or nil
            Hold(ItemIDFromLink(link), count)
        end)
    end
    local AH = C_AuctionHouse
    if type(AH) == "table" and type(AH.ConfirmCommoditiesPurchase) == "function" then
        hooksecurefunc(AH, "ConfirmCommoditiesPurchase", function(itemID, quantity) Hold(itemID, quantity) end)
    end
end

-- "You won an auction for %s" as a pattern.
local function WonPattern()
    local f = type(ERR_AUCTION_WON_S) == "string" and ERR_AUCTION_WON_S or "You won an auction for %s"
    local escaped = f:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    return "^" .. escaped:gsub("%%s", "(.+)") .. "$"
end

local function IdByName(name)
    for _, h in ipairs(tentative) do
        if ns.Market.ItemInfo(h.id) == name then return h.id, h end
    end
    local plan = Track.Plan()
    local found
    local function Walk(node)
        if found then return end
        if ns.Market.ItemInfo(node.id) == name then found = node.id return end
        for _, ch in ipairs(node.children or {}) do Walk(ch) end
    end
    if plan then Walk(plan.root) end
    return found
end

function Track.OnWon(msg)
    if type(msg) ~= "string" then return end
    local name = msg:match(WonPattern())
    if not name then return end
    local id, held = IdByName(name)
    if held then
        for i, h in ipairs(tentative) do if h == held then table.remove(tentative, i) break end end
        Confirm(held)
    elseif id then
        Confirm({ id = id, n = 1 })
    end
end

-- Money left: every buyout held in the last seconds went through.
function Track.OnMoney(before, after)
    Prune()
    if not (before and after and after < before) then return end
    for _, h in ipairs(tentative) do Confirm(h) end
    tentative = {}
end

-- The open mailbox, read whole: { [itemID] = { a, o } }.
function Track.ReadInbox()
    local n = Num(S.Call(GetInboxNumItems))
    if not n then return nil end
    local out = {}
    local max = Num(ATTACHMENTS_MAX_RECEIVE) or 16
    for i = 1, n do
        local _, kind, info = ns.Economy.DescribeMail(i)
        local fromAH = kind == "auction" and type(info) == "table" and info.status == "won"
        for j = 1, max do
            local name, itemID, _, count = S.CallMulti(4, GetInboxItem, i, j)
            if name or itemID then
                local id = Num(itemID)
                if not id and type(GetInboxItemLink) == "function" then id = ItemIDFromLink(S.Call(GetInboxItemLink, i, j)) end
                count = Num(count) or 1
                if id then
                    out[id] = out[id] or { a = 0, o = 0 }
                    if fromAH then out[id].a = out[id].a + count else out[id].o = out[id].o + count end
                end
            end
        end
    end
    return out
end

function Track.OnInbox()
    local key = ns.Gear.CharKey()
    local mail = Track.ReadInbox()
    if not key or not mail then return end
    local c = Store()[key] or {}
    Store()[key] = c
    c.mail, c.mailT, c.buys = mail, time(), {}
    Changed()
end

local lastMoney

ns.RegisterModule("CraftTrack", {
    defaults = { craftTrack = {} },
    init = function()
        HookBuys()
        lastMoney = Num(S.Call(GetMoney))
        -- Purchases never seen in a mailbox read go after a week.
        for _, c in pairs(Store()) do
            if type(c) == "table" and type(c.buys) == "table" then
                for i = #c.buys, 1, -1 do
                    if type(c.buys[i]) ~= "table" or time() - (c.buys[i].t or 0) > BUY_KEEP then table.remove(c.buys, i) end
                end
            end
        end
    end,
    -- MAIL_SHOW comes before the letters do: only MAIL_INBOX_UPDATE is read.
    events = { "PLAYER_MONEY", "CHAT_MSG_SYSTEM", "MAIL_INBOX_UPDATE" },
    onEvent = function(event, ...)
        if event == "PLAYER_MONEY" then
            local now = Num(S.Call(GetMoney))
            Track.OnMoney(lastMoney, now)
            lastMoney = now
        elseif event == "CHAT_MSG_SYSTEM" then
            Track.OnWon(S.Value((...)))
        elseif event == "MAIL_INBOX_UPDATE" then
            Track.OnInbox()
        end
    end,
})

Track.tentative = function() return tentative end
