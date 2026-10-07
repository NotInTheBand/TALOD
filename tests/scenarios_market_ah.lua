-- Market window: a click on an item while the Auction House is open searches
-- it in the AH window (one search per click); nothing when the AH is closed,
-- during a full scan or with the setting off; the search list is untouched.
local scenarios, T = ...
local check, boot = T.check, T.boot

local function setup(interface)
    function GetItemInfo(id)
        if id == 2589 then return "Linen Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132889, 13, 7, 5, 0 end
    end
    local ns = boot(interface)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    ns.Prices.Record(2589, 100, 20, time() - 7200, 2, "Linen Cloth")
    return ns
end

local function ClickPriceRow(ns)
    ns.MarketUI.Show("prices")
    local list = ns.MarketUI.views.prices.list
    for _, r in ipairs(list.rows) do
        if r.item and r.item.id == 2589 then r:Fire("OnClick", "LeftButton") return true end
    end
    return false
end

scenarios.market_click_ah_modern = function()
    local ns = setup(16001)
    local H = ns.AHHelper
    local ready, searched = true, {}
    C_AuctionHouse = {
        SendSearchQuery = function() end, MakeItemKey = function(id) return { itemID = id } end,
        IsThrottledMessageSystemReady = function() return ready end,
    }
    AuctionHouseFrameDisplayMode = { Buy = "buy", Sell = "sell" }
    AuctionHouseFrame = CreateFrame("Frame", "AuctionHouseFrame", UIParent)
    AuctionHouseFrame.SetDisplayMode = function(self, mode) self.mode = mode end
    AuctionHouseFrame.SearchBar = { SearchBox = CreateFrame("EditBox", nil, AuctionHouseFrame),
        StartSearch = function(self) searched[#searched + 1] = self.SearchBox:GetText() end }

    -- AH closed: the click only selects.
    AuctionHouseFrame:Hide()
    check(ClickPriceRow(ns), "row found")
    check(#searched == 0, "no search while the AH is closed")

    AuctionHouseFrame:Show()
    MOCK.FireEvent("AUCTION_HOUSE_SHOW")
    MOCK.RunTimers()
    local index = H.state.index
    AuctionHouseFrame.mode = "sell"
    check(ClickPriceRow(ns), "row found (open)")
    check(#searched == 1 and searched[1] == "Linen Cloth", "searched in the AH window: " .. tostring(searched[1]))
    check(AuctionHouseFrame.mode == "buy", "switched to the browse view")
    check(H.state.index == index and not H.state.waiting, "search list untouched")
    check(ClickPriceRow(ns) and #searched == 2, "one search per click")

    ready = false
    check(ClickPriceRow(ns) and #searched == 2, "busy: nothing sent")
    ready = true

    TALODDB.ahLookupClick = false
    check(ClickPriceRow(ns) and #searched == 2, "setting off: nothing sent")
    TALODDB.ahLookupClick = true

    MOCK.FireEvent("AUCTION_HOUSE_CLOSED")
    check(ClickPriceRow(ns) and #searched == 2, "closed again: nothing sent")
end

scenarios.market_click_ah_legacy = function()
    local ns = setup(11509)
    local browsed = {}
    AuctionFrame = CreateFrame("Frame", "AuctionFrame", UIParent)
    AuctionFrameTab1 = CreateFrame("Button", "AuctionFrameTab1", AuctionFrame)
    local tab
    function AuctionFrameTab_OnClick(t) tab = t end
    BrowseName = CreateFrame("EditBox", "BrowseName", AuctionFrame)
    function AuctionFrameBrowse_Search() browsed[#browsed + 1] = BrowseName:GetText() end
    function CanSendAuctionQuery() return true, true end
    MOCK.FireEvent("AUCTION_HOUSE_SHOW")
    MOCK.RunTimers()
    check(ClickPriceRow(ns), "row found")
    check(#browsed == 1 and browsed[1] == "Linen Cloth" and tab == AuctionFrameTab1, "Browse tab search: " .. tostring(browsed[1]))
    function CanSendAuctionQuery() return false, false end
    check(ClickPriceRow(ns) and #browsed == 1, "busy: nothing sent")
end
