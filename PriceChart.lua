-- TALOD - price graph: one item's history on the Auction House.
--   * the lowest price at each look (or each day, with the day's highest as
--     a band), and the usual price as a faint line; overpriced points
--     (Market.MarkOverpriced) in red, held at the top so the scale stays on
--     the prices that count;
--   * volume under it: units listed (bars), units gone since the look
--     before (sold, cancelled or expired: the AH does not say which; in the
--     hover readout) and the units you sold (green bars, Economy's log).
-- Used by the Market window (Prices detail), the Auction desk (Control) and
-- under item tooltips (at the Auction House, or everywhere by setting).

local ADDON_NAME, ns = ...
local Style = ns.Style
local COLORS, HEX = Style.COLORS, Style.HEX
local Market, Prices = ns.Market, ns.Prices

local Chart = {}
ns.PriceChart = Chart

local PRICE = COLORS.accent
local OVER = { 1, 0.31, 0.31, 1 }
local OVER_HEX = "|cffff5050"
local BAND = { 1, 0.5, 0.25, 0.22 }
local USUAL = { 1, 1, 1, 0.18 }
local LISTED = { 0.35, 0.55, 0.85, 0.6 }
local SOLD = { 0.3, 0.85, 0.4, 0.95 }
local LISTED_HEX, SOLD_HEX = "|cff5a8cd9", "|cff4dd966"
local PRICE_SHARE, VOLUME_SHARE = 0.64, 0.26   -- of the plot's height; the gap between is air

local function Money(c) return ns.Professions.Money(c) end

-- Days when the item was seen on 3 or more days, else every look.
function Chart.AutoMode(id)
    return #Prices.History(id, "days") >= 3 and "days" or "looks"
end

-- Points to draw, oldest first, each with gone (units fewer than the point
-- before), sold (your units sold: that day, or since the look before), over
-- (overpriced: left out of the usual price) and hiOver (the day's highest is).
-- Returns points, usual price (nil with one look), the overpriced line.
function Chart.Data(id, mode)
    local pts = Prices.History(id, mode)
    local sold = Market.SoldList(id)
    local byDay = {}
    for _, s in ipairs(sold) do
        local day = math.floor(s.t / 86400)
        byDay[day] = (byDay[day] or 0) + s.units
    end
    for i, pt in ipairs(pts) do
        local prev = pts[i - 1]
        if prev and (prev.n or 0) > (pt.n or 0) then pt.gone = prev.n - (pt.n or 0) end
        if mode == "days" then
            pt.sold = byDay[pt.day]
        else
            local from, n = prev and prev.t or -math.huge, 0
            for _, s in ipairs(sold) do if s.t > from and s.t <= pt.t then n = n + s.units end end
            pt.sold = n > 0 and n or nil
        end
    end
    local s = Market.Stats(id)
    local usual = (s and s.looks > 1) and s.usual or nil
    local cap = usual and s.looks >= Market.OUTLIER_LOOKS and usual * Market.OUTLIER_FACTOR or nil
    if mode ~= "days" then
        Market.MarkOverpriced(pts)
    elseif cap then
        for _, pt in ipairs(pts) do
            pt.over = pt.p > cap or nil
            pt.hiOver = pt.hi and pt.hi > cap or nil
        end
    end
    return pts, usual, cap
end

local function PointLines(pt, mode)
    local lines = { HEX.white .. date(mode == "days" and "%a %b %d" or "%b %d %H:%M", pt.t) .. "|r" }
    if mode == "days" and pt.hi and pt.hi > pt.p then
        lines[#lines + 1] = "Lowest " .. Money(pt.p) .. ", highest look " .. Money(pt.hi)
    else
        lines[#lines + 1] = "Lowest " .. Money(pt.p) .. " each"
    end
    if pt.over then
        lines[#lines + 1] = OVER_HEX .. "Overpriced (over " .. Market.OUTLIER_FACTOR .. "x usual): left out of the usual price|r"
    elseif pt.hiOver then
        lines[#lines + 1] = OVER_HEX .. "The day's highest look is overpriced: left out|r"
    end
    lines[#lines + 1] = LISTED_HEX .. "Listed: " .. (pt.n or 0) .. " units|r" .. (pt.a and (" in " .. pt.a .. " auctions") or "")
    if pt.gone then lines[#lines + 1] = HEX.muted .. pt.gone .. " fewer than the " .. (mode == "days" and "day" or "look") .. " before (sold, cancelled or expired)|r" end
    if pt.sold then lines[#lines + 1] = SOLD_HEX .. "You sold " .. pt.sold .. "|r" end
    return lines
end

-- A chart in `parent`. opts.compact: no buttons, no hover (the tooltip graph).
-- chart:SetItem(id), chart:Redraw(); chart.mode nil = automatic.
function Chart.New(parent, opts)
    opts = opts or {}
    local c = CreateFrame("Frame", nil, parent)
    c.compact = opts.compact
    c.legend = Style.Text(c, "GameFontDisableSmall")
    c.legend:SetPoint("TOPLEFT", 4, -2)
    c.legend:SetPoint("RIGHT", c.compact and -4 or -112, 0)
    if not c.compact then
        local function ModeButton(label, mode, tip)
            local b = Style.Button(c, label, 50, function() c.mode = mode c:Redraw() end, tip, { height = 18 })
            return b
        end
        c.days = ModeButton("Days", "days", "One point per day: its lowest price, the highest as a band, the most units listed.")
        c.days:SetPoint("TOPRIGHT", -2, 0)
        c.looks = ModeButton("Looks", "looks", "Every look you took (the last 30).")
        c.looks:SetPoint("RIGHT", c.days, "LEFT", -4, 0)
    end
    local plot = CreateFrame("Frame", nil, c)
    plot:SetPoint("TOPLEFT", c.compact and 40 or 50, c.compact and -16 or -24)
    plot:SetPoint("BOTTOMRIGHT", -6, c.compact and 12 or 14)
    c.plot = plot
    c.grid, c.gridLabels = {}, {}
    for i = 1, 3 do
        c.grid[i] = Style.HLine(plot, COLORS.grid)
        c.gridLabels[i] = Style.Text(plot, "GameFontDisableSmall", "RIGHT")
        c.gridLabels[i]:SetWidth(c.compact and 38 or 48)
    end
    c.xLeft = Style.Text(plot, "GameFontDisableSmall")
    c.xLeft:SetPoint("TOPLEFT", plot, "BOTTOMLEFT", 0, -1)
    c.xRight = Style.Text(plot, "GameFontDisableSmall", "RIGHT")
    c.xRight:SetPoint("TOPRIGHT", plot, "BOTTOMRIGHT", 0, -1)
    c.usual = Style.Texture(plot, "ARTWORK", USUAL)
    c.usual:SetHeight(1)
    c.empty = Style.Text(plot, "GameFontDisableSmall", "CENTER")
    c.empty:SetPoint("CENTER")
    c.cross = Style.Texture(plot, "OVERLAY", { 1, 1, 1, 0.25 })
    c.cross:SetWidth(1)
    c.cross:Hide()
    c.lines, c.dots, c.bands, c.bars, c.soldBars = {}, {}, {}, {}, {}

    local function Pool(list, i, make)
        local x = list[i]
        if not x then x = make() list[i] = x end
        x:Show()
        return x
    end
    local function HideAll()
        for _, list in ipairs({ c.lines, c.dots, c.bands, c.bars, c.soldBars }) do
            for _, x in pairs(list) do x:Hide() end
        end
        for i = 1, 3 do c.grid[i]:Hide() c.gridLabels[i]:Hide() end
        c.usual:Hide()
        c.cross:Hide()
        c.empty:SetText("")
        c.xLeft:SetText("")
        c.xRight:SetText("")
    end

    function c:SetItem(id)
        if id ~= self.id then self.mode = nil end
        self.id = id
        self:Redraw()
    end

    function c:Redraw()
        HideAll()
        self.pts = nil
        local id = self.id
        if not id then return end
        local mode = self.mode or Chart.AutoMode(id)
        self.shownMode = mode
        if self.days then
            self.days.borderColor = mode == "days" and COLORS.accent or nil
            self.looks.borderColor = mode == "looks" and COLORS.accent or nil
            for _, b in ipairs({ self.days, self.looks }) do
                local col = b.borderColor or COLORS.border
                b:SetBorderColor(col[1], col[2], col[3], 1)
            end
        end
        local pts, usual, cap = Chart.Data(id, mode)
        local anyOver = false
        for _, pt in ipairs(pts) do if pt.over or pt.hiOver then anyOver = true end end
        self.legend:SetText(HEX.accent .. "lowest price|r" .. HEX.muted .. (mode == "days" and " (band: highest)" or "") .. "  ·  |r"
            .. LISTED_HEX .. "units listed|r" .. HEX.muted .. "  ·  |r" .. SOLD_HEX .. "you sold|r"
            .. (anyOver and (HEX.muted .. "  ·  |r" .. OVER_HEX .. "overpriced|r") or ""))
        if #pts < 2 then
            self.empty:SetText(#pts == 1 and "One look so far: the graph starts with the second." or "Not seen on the Auction House yet.")
            return
        end
        local W, H = plot:GetWidth() or 0, plot:GetHeight() or 0
        if W < 20 then W = 240 end
        if H < 20 then H = 80 end
        local base, priceH, volH = H * (1 - PRICE_SHARE), H * PRICE_SHARE, H * VOLUME_SHARE
        local lo, hi, vmax = math.huge, -math.huge, 1
        -- The scale leaves the overpriced out: they are drawn at its top.
        for _, pt in ipairs(pts) do
            if not pt.over then
                lo, hi = math.min(lo, pt.p), math.max(hi, (not pt.hiOver and pt.hi) or pt.p)
            end
            vmax = math.max(vmax, pt.n or 0, pt.sold or 0)
        end
        if usual then lo, hi = math.min(lo, usual), math.max(hi, usual) end
        if lo == math.huge then lo, hi = 0, cap or 1 end
        if hi - lo < 1 then lo, hi = lo - 1, hi + 1 end
        local pad = (hi - lo) * 0.08
        lo, hi = math.max(0, lo - pad), hi + pad
        local function Y(p) return base + (math.min(p, hi) - lo) / (hi - lo) * priceH end
        local t0, t1 = pts[1].t, pts[#pts].t
        local function X(i)
            if mode == "days" and t1 > t0 then return 4 + (pts[i].t - t0) / (t1 - t0) * (W - 8) end
            return 4 + (i - 1) / (#pts - 1) * (W - 8)
        end
        local bw = math.max(2, math.min(12, (W - 8) / #pts * 0.55))

        for i = 1, 3 do
            local p = lo + (hi - lo) * (i - 1) / 2
            local y = Y(p)
            self.grid[i]:ClearAllPoints()
            self.grid[i]:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, y)
            self.grid[i]:SetPoint("BOTTOMRIGHT", plot, "BOTTOMRIGHT", 0, y)
            self.grid[i]:Show()
            self.gridLabels[i]:ClearAllPoints()
            self.gridLabels[i]:SetPoint("RIGHT", plot, "BOTTOMLEFT", -4, y)
            self.gridLabels[i]:SetText(Money(p))
            self.gridLabels[i]:Show()
        end
        if usual then
            self.usual:ClearAllPoints()
            self.usual:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, Y(usual))
            self.usual:SetPoint("BOTTOMRIGHT", plot, "BOTTOMRIGHT", 0, Y(usual))
            self.usual:Show()
        end
        local prevX, prevY
        for i, pt in ipairs(pts) do
            local x, y = X(i), Y(pt.p)
            pt.x = x
            -- Volume: units listed, your sales in front.
            if (pt.n or 0) > 0 then
                local b = Pool(self.bars, i, function() return Style.Texture(plot, "BACKGROUND", LISTED) end)
                b:ClearAllPoints()
                b:SetPoint("BOTTOM", plot, "BOTTOMLEFT", x, 0)
                b:SetSize(bw, math.max(1, pt.n / vmax * volH))
            end
            if pt.sold then
                local b = Pool(self.soldBars, i, function() return Style.Texture(plot, "BORDER", SOLD) end)
                b:ClearAllPoints()
                b:SetPoint("BOTTOM", plot, "BOTTOMLEFT", x, 0)
                b:SetSize(math.max(1, bw * 0.5), math.max(1, pt.sold / vmax * volH))
            end
            if pt.hi and pt.hi > pt.p then
                local b = Pool(self.bands, i, function() return Style.Texture(plot, "ARTWORK", BAND) end)
                b:ClearAllPoints()
                b:SetPoint("BOTTOM", plot, "BOTTOMLEFT", x, y)
                b:SetSize(math.max(2, bw * 0.6), math.max(1, Y(pt.hi) - y))
            end
            if prevX and plot.CreateLine then
                local l = Pool(self.lines, i, function()
                    local line = plot:CreateLine(nil, "OVERLAY")
                    if line.SetThickness then line:SetThickness(2) end
                    return line
                end)
                l:SetColorTexture(PRICE[1], PRICE[2], PRICE[3], 1)
                l:SetStartPoint("BOTTOMLEFT", plot, prevX, prevY)
                l:SetEndPoint("BOTTOMLEFT", plot, x, y)
            end
            local d = Pool(self.dots, i, function() return Style.Texture(plot, "OVERLAY", PRICE) end)
            local col = pt.over and OVER or PRICE
            d:SetColorTexture(col[1], col[2], col[3], col[4] or 1)
            d:ClearAllPoints()
            d:SetPoint("CENTER", plot, "BOTTOMLEFT", x, y)
            local size = (self.compact and 3 or 4) + (pt.over and 2 or 0)
            d:SetSize(size, size)
            prevX, prevY = x, y
        end
        local fmt = mode == "days" and "%b %d" or "%b %d %H:%M"
        self.xLeft:SetText(date(fmt, t0))
        self.xRight:SetText(date(fmt, t1))
        self.pts = pts
    end

    c:SetScript("OnSizeChanged", function(self) if self:IsShown() then self:Redraw() end end)

    if not c.compact then
        plot:EnableMouse(true)
        -- Hover: the nearest point's date, price and volume.
        plot:SetScript("OnUpdate", function(self)
            local pts = c.pts
            if not pts or not (self.IsMouseOver and self:IsMouseOver()) then
                if c.hovering then c.hovering = nil c.cross:Hide() ns.Tooltip.Hide() end
                return
            end
            local scale = self.GetEffectiveScale and self:GetEffectiveScale() or 1
            local cx = (GetCursorPosition()) / scale - (self:GetLeft() or 0)
            local best, bestD
            for n, pt in ipairs(pts) do
                local dist = math.abs((pt.x or 0) - cx)
                if not bestD or dist < bestD then best, bestD = n, dist end
            end
            if best == c.hovering then return end
            c.hovering = best
            local pt = pts[best]
            c.cross:ClearAllPoints()
            c.cross:SetPoint("TOP", self, "TOPLEFT", pt.x, 0)
            c.cross:SetPoint("BOTTOM", self, "BOTTOMLEFT", pt.x, 0)
            c.cross:Show()
            ns.Tooltip.Text(self, PointLines(pt, c.shownMode))
        end)
    end
    return c
end
Chart.PointLines = PointLines

---------------------------------------------------------------------------
-- Under item tooltips
---------------------------------------------------------------------------
local tipFrame

local function AtAuctionHouse()
    local host = AuctionHouseFrame or AuctionFrame
    return host and host.IsShown and host:IsShown() and true or false
end

local function HideTip() if tipFrame then tipFrame:Hide() end end

-- Shows the graph under `tooltip` for item `id` when the setting allows
-- and the item has two looks or more; hides it otherwise.
function Chart.UnderTooltip(tooltip, id)
    local db = ns.DB()
    local want = db and db.tooltipGraph and type(id) == "number" and (db.tooltipGraphAlways or AtAuctionHouse())
    if not want or #Prices.History(id, "looks") < 2 then HideTip() return false end
    if not tipFrame then
        tipFrame = CreateFrame("Frame", ns.FRAME .. "PriceGraphTip", UIParent)
        tipFrame:SetFrameStrata("TOOLTIP")
        Style.Surface(tipFrame, "hud")
        tipFrame.chart = Chart.New(tipFrame, { compact = true })
        tipFrame.chart:SetPoint("TOPLEFT", 4, -4)
        tipFrame.chart:SetPoint("BOTTOMRIGHT", -4, 4)
    end
    tipFrame:ClearAllPoints()
    tipFrame:SetPoint("TOPLEFT", tooltip, "BOTTOMLEFT", 0, -2)
    tipFrame:SetSize(math.max(tooltip:GetWidth() or 0, 250), 104)
    tipFrame:Show()
    tipFrame.chart:SetItem(id)
    return true
end

function Chart.TooltipFrame() return tipFrame end

-- Tooltip.lua shows it with GameTooltip's item tooltips and hides it with them.
ns.Tooltip.AddItemExtra("priceGraph", { show = Chart.UnderTooltip, hide = HideTip })
