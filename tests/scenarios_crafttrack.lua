-- Craft tracker: the cheapest route (make what you can when cheaper, buy the
-- rest), Auction House buyouts counted as "in the mailbox" once money
-- leaves, the mailbox read replacing them, Craft next as one command for
-- the first ready step, and the window.
local scenarios, T = ...
local check, boot = T.check, T.boot

local function setup()
    MOCK.skillLines = { { "Professions", true, true }, { "Tailoring", false, nil, 60, 0, 0, 75 } }
    MOCK.bags[0][1] = MOCK.ItemLink(2589, "Linen Cloth")
    function GetItemInfo(id)
        if id == 2589 then return "Linen Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132889, 13, 7, 5, 0 end
        if id == 2996 then return "Bolt of Linen Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132890, 40, 7, 5, 0 end
        if id == 2320 then return "Coarse Thread", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132891, 2, 7, 5, 0 end
    end
    local ns = boot(11509)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    return ns
end

local function Find(node, id)
    if node.id == id and not node.root then return node end
    for _, ch in ipairs(node.children or {}) do
        local f = Find(ch, id)
        if f then return f end
    end
end

scenarios.crafttrack_route = function()
    local ns = setup()
    local Pr, Track = ns.Prices, ns.CraftTrack
    local now = time()
    Pr.Record(2589, 30, 200, now, 10, "Linen Cloth")
    Pr.Record(2996, 300, 20, now, 4, "Bolt of Linen Cloth")
    local vest = ns.ProfessionData.recipes[2385]       -- Brown Linen Vest: 1 bolt + 1 thread
    check(Track.Start(vest, 2), "tracking starts")
    local plan = Track.Plan()
    local bolt, linen, thread = Find(plan.root, 2996), Find(plan.root, 2589), Find(plan.root, 2320)
    check(bolt and bolt.crafts == 2 and bolt.r.id == 2963, "bolts made (60c) instead of bought (300c)")
    check(linen and linen.need == 4 and linen.have == 1 and linen.buy == 3, "linen: 1 in bags, buy 3")
    check(thread and thread.buy == 2 and thread.src == "vendor", "thread from a vendor")
    check(plan.buyCost == 3 * 30 + 2 * 10, "still to buy: " .. tostring(plan.buyCost))
    check(#plan.steps == 2 and plan.steps[1].r.id == 2963 and plan.steps[2].root, "bolts first, then the vest")
    check(plan.next == nil, "no step ready without the linen")

    -- Without Tailoring the bolts are bought, and the plan says why.
    MOCK.skillLines = { { "Professions", true, true } }
    local other = Track.Plan(vest, 2, "Nobody-Realm")
    local b2 = Find(other.root, 2996)
    check(b2 and b2.buy == 2 and b2.cannot and not other.canCraft and other.why == "skill", "no skill: buy the bolts")
    MOCK.skillLines = { { "Professions", true, true }, { "Tailoring", false, nil, 60, 0, 0, 75 } }

    -- A buyout of 5 linen: held until money leaves, then in the mailbox.
    MOCK.auctionLink = MOCK.ItemLink(2589, "Linen Cloth")
    PlaceAuctionBid("list", 1, 500)
    check(#Track.tentative() == 1, "buyout held")
    check(Find(Track.Plan().root, 2589).mailA == 0, "not counted before the money goes")
    MOCK.money = MOCK.money - 500
    MOCK.FireEvent("PLAYER_MONEY")
    linen = Find(Track.Plan().root, 2589)
    check(linen.mailA == 3 and linen.buy == nil and linen.left == 0, "3 of the 5 count, in the mailbox (AH)")
    -- A bid under the buyout is not yours yet.
    PlaceAuctionBid("list", 1, 100)
    check(#Track.tentative() == 0, "a bid is not held")
    -- "You won an auction" alone (modern bid): one, by name.
    Track.OnWon("You won an auction for Coarse Thread")
    check(Find(Track.Plan().root, 2320).mailA == 1, "won message counts one thread")

    -- The mailbox read replaces the purchases: 5 linen from the AH, 1 thread from a friend.
    MOCK.inbox[1] = { sender = "Auction House", subject = "Auction won: Linen Cloth", invoice = "buyer", item = "Linen Cloth",
        items = { { 2589, "Linen Cloth", 5 } } }
    MOCK.inbox[2] = { sender = "Buddy", subject = "thread", items = { { 2320, "Coarse Thread", 1 } } }
    MOCK.FireEvent("MAIL_INBOX_UPDATE")
    plan = Track.Plan()
    check(Find(plan.root, 2589).mailA == 3 and Find(plan.root, 2320).mailO == 1 and Find(plan.root, 2320).mailA == 0,
        "mailbox counts: AH linen, other thread")
    check(Track.Current().buys and #Track.Current().buys == 0, "purchases folded into the read")

    -- Taken: linen in the bags, the bolt step is ready.
    MOCK.inbox = {}
    for i = 2, 6 do MOCK.bags[0][i] = MOCK.ItemLink(2589, "Linen Cloth") end
    MOCK.FireEvent("MAIL_INBOX_UPDATE")
    MOCK.FireEvent("BAG_UPDATE_DELAYED")
    plan = Track.Plan()
    check(plan.next and plan.next.r.id == 2963 and plan.next.crafts == 2, "Craft next: 2 bolts")
    local ok, msg = Track.CraftNext()
    check(not ok and type(msg) == "string" and msg:find("Tailoring"), "one command, needs the window: " .. tostring(msg))

    -- The AH helper searches what the tracked craft still buys first.
    local missing = Track.Missing()
    check(#missing == 0, "thread is bought from a vendor: not searched on the AH")

    -- Crafts logged count as done.
    ns.DB().craftLogEnabled = true
    ns.Professions.RecordCraft(2385)
    plan = Track.Plan()
    check(plan.done == 1 and plan.left == 1, "one vest made: " .. tostring(plan.done))

    -- The window: preview another recipe, track it, stop.
    local UI = ns.CraftTrackUI
    check(UI.Open(ns.ProfessionData.recipes[2387]), "window opens on a preview")
    check(UI.IsShown(), "window shown")
    check(Track.Current().id == 2385, "a preview does not replace the tracked craft")
    UI.SetCount(3)
    UI.frame().track:Fire("OnClick", "LeftButton")
    check(Track.Current().id == 2387 and Track.Current().n == 3, "tracked from the window")
    UI.frame().plus:Fire("OnClick", "LeftButton")
    check(Track.Current().n == 4, "count up")
    UI.frame().craft:Fire("OnClick", "LeftButton")
    UI.frame().track:Fire("OnClick", "LeftButton")
    check(Track.Current() == nil and not UI.IsShown(), "stopped")

end

-- Crafting tab: one click selects a recipe, a double click opens the tracker.
scenarios.crafttrack_double_click = function()
    local ns = setup()
    ns.Prices.Record(2996, 300, 20, time(), 4, "Bolt of Linen Cloth")
    ns.MarketUI.Show("crafting")
    local list = ns.MarketUI.views.crafting.list
    local row
    for _, r in ipairs(list.rows or {}) do if r.item and r.item.pr then row = r break end end
    check(row, "a recipe row drawn")
    local UI = ns.CraftTrackUI
    row:Fire("OnClick", "LeftButton")
    check(not UI.IsShown(), "one click only selects")
    MOCK.time = MOCK.time + 1
    row:Fire("OnClick", "LeftButton")
    check(not UI.IsShown(), "two slow clicks only select")
    MOCK.time = MOCK.time + 0.2
    row:Fire("OnClick", "LeftButton")
    check(UI.IsShown(), "a double click opens the tracker")
end

-- Bags: the reagent bag (Forever, bag 5) counts like a bag addon shows it,
-- every stack summed; on Classic Era bag 5 is a bank bag and never counts.
scenarios.crafttrack_reagent_bag = function()
    local ns = setup()
    local U = ns.Utils
    MOCK.bags[5] = { MOCK.ItemLink(2589, "Linen Cloth"), MOCK.ItemLink(2589, "Linen Cloth") }
    MOCK.bagCounts["5:1"], MOCK.bagCounts["5:2"] = 20, 7
    check(U.ReagentBag() == nil and #U.BagIDs() == 5, "Classic Era: no reagent bag")
    check(U.ScanBags()[2589].n == 1, "bank bag 5 not counted")
    Enum.BagIndex = { ReagentBag = 5 }
    local scan = U.ScanBags()
    check(scan[2589].n == 28 and #scan[2589].slots == 3, "reagent bag summed: " .. scan[2589].n)
    check(#U.BagIDs("general") == 5, "general bags leave the reagent bag out")
    MOCK.FireEvent("BAG_UPDATE_DELAYED")
    check(U.ItemCount(2589) == 28, "item count")
    local vest = ns.ProfessionData.recipes[2385]
    ns.CraftTrack.Start(vest, 2)
    local plan = ns.CraftTrack.Plan()
    local linen
    local function Walk(n) if n.id == 2589 then linen = n end for _, c in ipairs(n.children or {}) do Walk(c) end end
    Walk(plan.root)
    check(linen and linen.have == 4 and linen.left == 0, "the tracker sees the reagent bag's linen")
    Enum.BagIndex = nil
    MOCK.bags[5] = nil
end

-- A recipe learned after the profession window was last read (a pattern
-- won on the AH) is not "not learned": the game's spell list and the
-- "You have learned" message both count, and Craft next asks the window.
scenarios.crafttrack_learned_since_read = function()
    local ns = setup()
    local Track, Prof = ns.CraftTrack, ns.Professions
    local me = ns.Gear.CharKey()
    local vest = ns.ProfessionData.recipes[2385]
    local c = ns.DB().skills[me]
    c.recipes = { Tailoring = { ["Bolt of Linen Cloth"] = true } }
    local ok, why = Track.CanCraft(vest, me)
    check(not ok and why == "unlearned", "stale list says not learned: " .. tostring(why))

    -- The game's spell list knows it.
    IsPlayerSpell = function(id) return id == 2385 end
    check(Track.CanCraft(vest, me), "known spell: can make")
    check(not select(1, Track.CanCraft(vest, "Other-Realm")), "another character's list is not the spell list")
    IsPlayerSpell = function() return MOCK.Secret(true) end
    check(not Track.CanCraft(vest, me), "a secret answer is unknown")
    IsPlayerSpell = nil

    -- The learn message adds it to the list.
    MOCK.FireEvent("CHAT_MSG_SYSTEM", "You have learned how to create a new item: Brown Linen Vest.")
    check(c.recipes.Tailoring["Brown Linen Vest"], "learn message recorded")
    check(Track.CanCraft(vest, me), "can make after the message")
    -- And the newer engine's event, by recipe ID.
    MOCK.FireEvent("NEW_RECIPE_LEARNED", 2387)
    check(c.recipes.Tailoring[ns.ProfessionData.recipes[2387].name], "NEW_RECIPE_LEARNED recorded")

    -- Craft next no longer refuses from a stale list: the window decides.
    c.recipes.Tailoring = { ["Bolt of Linen Cloth"] = true }
    for i = 1, 4 do MOCK.bags[0][i] = MOCK.ItemLink(2996, "Bolt of Linen Cloth") end
    for i = 5, 8 do MOCK.bags[0][i] = MOCK.ItemLink(2320, "Coarse Thread") end
    MOCK.FireEvent("BAG_UPDATE_DELAYED")
    Track.Start(vest, 1)
    local plan = Track.Plan()
    check(plan.next and plan.next.root, "the vest step is ready")
    local _, msg = Track.CraftNext()
    check(type(msg) == "string" and not msg:find("cannot make"), "no stale refusal: " .. tostring(msg))
end
