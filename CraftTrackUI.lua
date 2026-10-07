-- TALOD - Craft tracker window: a floating window for one recipe (opened
-- from the Market's Crafting tab): what you need, the cheapest route (buy or
-- make each part), what is in your bags or mailbox, and a Craft next button
-- (one click = one game command, CraftTrack.CraftNext).

local ADDON_NAME, ns = ...
local Style = ns.Style
local COLORS, HEX = Style.COLORS, Style.HEX
local Track = ns.CraftTrack

local UI = {}
ns.CraftTrackUI = UI

local frame
local preview          -- { r, n }: a recipe shown but not tracked yet

local function db() return ns.DB() end
local function Money(c)
    if not c then return HEX.dim .. "?|r" end
    return ns.Professions.Money(c)
end
local function Name(id) return ns.Market.ItemText(id) end

local CANNOT_WHY = { skill = "skill too low", unlearned = "not learned" }

-- One node's status: what you hold, what is coming, what to buy or make.
local function Status(node)
    local parts = {}
    if node.have >= node.need then
        return HEX.good .. "in your bags|r"
    end
    if node.have > 0 then parts[#parts + 1] = HEX.white .. node.have .. " in bags|r" end
    if node.mailA > 0 then parts[#parts + 1] = HEX.gold .. node.mailA .. " in the mailbox (Auction House)|r" end
    if node.mailO > 0 then parts[#parts + 1] = HEX.gold .. node.mailO .. " in the mailbox|r" end
    if node.crafts then
        parts[#parts + 1] = HEX.accent .. "make " .. node.crafts .. "x|r"
    elseif node.buy then
        parts[#parts + 1] = HEX.bad .. "buy " .. node.buy .. "|r" .. HEX.muted
            .. (node.unit and ("  " .. Money(math.floor(node.unit + 0.5)) .. " each") or "  no price yet") .. "|r"
    end
    return table.concat(parts, HEX.muted .. "  ·  |r")
end

local function NodeRows(node, depth, out)
    local text = Name(node.id) .. "  " .. Status(node)
    if node.crafts and node.r then
        text = text .. HEX.muted .. "  (" .. node.r.name .. ", " .. node.r.prof .. ")|r"
    elseif node.cannot and not node.crafts and node.left > 0 then
        local r = node.cannot[1]
        local _, why = Track.CanCraft(r, ns.Gear.CharKey())
        text = text .. HEX.dim .. "  you can't make it: " .. r.prof .. " " .. r.skill .. (CANNOT_WHY[why] and (", " .. CANNOT_WHY[why]) or "") .. "|r"
    end
    out[#out + 1] = {
        label = node.need .. " x", text = text, icon = ns.Professions.ItemIcon(node.id), indent = depth * 14,
        cols = { node.buy and Money(node.cost and math.floor(node.cost + 0.5)) or (HEX.dim .. "-|r") },
        id = node.id,
        tooltip = function(o)
            local lines = { Name(node.id), string.format("Need %d: %d in bags, %d in the mailbox from the Auction House, %d in other letters.",
                node.need, node.have, node.mailA, node.mailO) }
            if node.crafts then
                lines[#lines + 1] = "Cheapest: make it (" .. Money(math.floor(node.unit + 0.5)) .. " each in materials)."
            elseif node.buy then
                lines[#lines + 1] = "Buy: " .. ns.Professions.PriceText(node.id) .. "."
            end
            lines[#lines + 1] = HEX.muted .. "Click: its prices.|r"
            ns.Tooltip.Text(o, lines)
        end,
    }
    for _, ch in ipairs(node.children or {}) do NodeRows(ch, depth + 1, out) end
end

local function Rows(plan)
    local out = {}
    out[#out + 1] = { header = true, text = "What you need" .. HEX.muted .. "  (cheapest route: buy, or make what you can)|r" }
    for _, ch in ipairs(plan.root.children) do NodeRows(ch, 0, out) end
    if #plan.root.children == 0 then out[#out + 1] = { text = HEX.muted .. "No materials.|r" } end

    out[#out + 1] = { header = true, text = "Crafts, in order" }
    if #plan.steps == 0 then
        out[#out + 1] = { text = HEX.good .. "All done.|r" }
    end
    for i, step in ipairs(plan.steps) do
        local missing = {}
        for _, ch in ipairs(step.children) do
            if ch.have < ch.need then missing[#missing + 1] = (ch.need - ch.have) .. " " .. Name(ch.id) end
        end
        out[#out + 1] = { label = i .. ".", text = Name(step.r.creates) .. " x" .. step.crafts .. HEX.muted .. "  " .. step.r.prof .. "|r"
                .. (step == plan.next and (HEX.good .. "  next|r") or ""),
            cols = { step.ready and (HEX.good .. "ready|r") or (HEX.muted .. "waiting|r") },
            tooltip = function(o)
                ns.Tooltip.Text(o, { step.r.name, step.ready and "Everything for it is in your bags."
                    or ("Still missing in your bags: " .. table.concat(missing, ", ") .. ".") })
            end }
    end
    return out
end

local function CurrentPlan()
    if preview then return Track.Plan(preview.r, preview.n) end
    return Track.Plan()
end

local function Build()
    frame = Style.Window(ns.FRAME .. "CraftTrack", "Craft", 520, 560)
    frame:Hide()
    frame:SetFrameStrata("HIGH")
    local pos = db().craftTrackPos
    if type(pos) == "table" and pos[1] and pos[2] then
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos[1], pos[2])
    end
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local left, top = self:GetLeft(), self:GetTop()
        if left and top then db().craftTrackPos = { math.floor(left + 0.5), math.floor(top + 0.5) } end
    end)

    frame.iconHolder, frame.icon = Style.IconFrame(frame, 32)
    frame.iconHolder:SetPoint("TOPLEFT", 14, -48)
    frame.name = Style.Text(frame, "GameFontNormalLarge")
    frame.name:SetPoint("TOPLEFT", frame.iconHolder, "TOPRIGHT", 8, -1)
    frame.name:SetPoint("RIGHT", -14, 0)
    frame.sub = Style.Text(frame, "GameFontDisableSmall")
    frame.sub:SetPoint("TOPLEFT", frame.name, "BOTTOMLEFT", 0, -3)
    frame.sub:SetPoint("RIGHT", -14, 0)

    -- How many crafts.
    frame.minus = Style.Button(frame, "-", 22, function(_, button)
        local plan = CurrentPlan()
        local n = plan and plan.count or 1
        UI.SetCount(n - (IsShiftKeyDown and IsShiftKeyDown() and 5 or 1))
    end, "One fewer (Shift: five).", { title = "Crafts" })
    frame.minus:SetPoint("TOPLEFT", 14, -90)
    frame.count = Style.Text(frame, "GameFontHighlight", "CENTER")
    frame.count:SetPoint("LEFT", frame.minus, "RIGHT", 4, 0)
    frame.count:SetWidth(90)
    frame.plus = Style.Button(frame, "+", 22, function()
        local plan = CurrentPlan()
        local n = plan and plan.count or 1
        UI.SetCount(n + (IsShiftKeyDown and IsShiftKeyDown() and 5 or 1))
    end, "One more (Shift: five).", { title = "Crafts" })
    frame.plus:SetPoint("LEFT", frame.count, "RIGHT", 4, 0)
    frame.track = Style.Button(frame, "", 120, function()
        if preview then
            Track.Start(preview.r, preview.n)
            preview = nil
        else
            Track.Stop()
            frame:Hide()
        end
        UI.Refresh()
    end, function()
        return preview and "Follow this craft: materials you buy on the Auction House or collect are counted as they come, "
            .. "and the AH helper searches what is still missing first." or "Stop following this craft."
    end, { title = "Tracking" })
    frame.track:SetPoint("TOPRIGHT", -14, -90)
    frame.summary = Style.Text(frame, "GameFontHighlightSmall")
    frame.summary:SetPoint("TOPLEFT", 14, -120)
    frame.summary:SetPoint("RIGHT", -14, 0)

    local holder = CreateFrame("Frame", nil, frame)
    holder:SetPoint("TOPLEFT", 10, -140)
    holder:SetPoint("BOTTOMRIGHT", -10, 48)
    frame.list = Style.List(holder, { labelWidth = 40, colWidths = { 64 }, onClick = function(item)
        if item.id and ns.Prices.Entry(item.id) and ns.MarketUI then
            ns.MarketUI.state.selected = item.id
            ns.MarketUI.Show("prices")
        end
    end })

    frame.craft = Style.Button(frame, "", 300, function()
        -- Crafting a previewed recipe starts tracking it (counts what follows).
        if preview then
            Track.Start(preview.r, preview.n)
            preview = nil
        end
        local _, msg = Track.CraftNext()
        ns.Print(msg)
        UI.Refresh()
    end, "One click starts one craft: the next step whose materials are in your bags, with its count (like the Create "
        .. "button). Open the profession's window first. The next click starts the next step.", { title = "Craft next", height = 26 })
    frame.craft:SetPoint("BOTTOMLEFT", 14, 14)
    frame.note = Style.Text(frame, "GameFontDisableSmall")
    frame.note:SetPoint("LEFT", frame.craft, "RIGHT", 10, 0)
    frame.note:SetPoint("RIGHT", -14, 0)
end

function UI.SetCount(n)
    n = math.max(1, math.min(999, math.floor(n)))
    if preview then preview.n = n else Track.SetCount(n) end
    UI.Refresh()
end

function UI.Refresh()
    if not frame or not frame:IsShown() then return end
    local plan = CurrentPlan()
    if not plan then frame:Hide() return end
    local r = plan.r
    frame.icon:SetTexture(ns.Professions.ItemIcon(r.creates))
    frame.name:SetText(Name(r.creates) .. ((r.makes or 1) ~= 1 and (" x" .. r.makes) or ""))
    frame.sub:SetText(r.name .. "  ·  " .. r.prof .. " " .. r.skill
        .. (plan.canCraft and (plan.why == "unread" and "  ·  open your " .. r.prof .. " window once to confirm you know it" or "")
            or (HEX.bad .. "  ·  you cannot make this yet (" .. (CANNOT_WHY[plan.why] or plan.why or "?") .. ")|r")))
    frame.count:SetText(plan.count .. (plan.count == 1 and " craft" or " crafts")
        .. (plan.done > 0 and (HEX.muted .. "  (" .. math.min(plan.done, plan.count) .. " done)|r") or ""))
    frame.track:SetLabel(preview and (HEX.good .. "Track it|r") or "Stop tracking")
    local parts = { "Still to buy: " .. HEX.white .. Money(math.floor(plan.buyCost + 0.5)) .. "|r"
        .. (plan.unpriced > 0 and (HEX.bad .. " + " .. plan.unpriced .. " without a price|r") or "") }
    if plan.value then
        parts[#parts + 1] = "sells for " .. Money(plan.value) .. " after the cut"
    end
    if plan.left <= 0 then parts = { HEX.good .. "Done: " .. plan.count .. " made.|r" } end
    frame.summary:SetText(table.concat(parts, HEX.muted .. "  ·  |r"))
    frame.list:SetItems(Rows(plan))
    local step = plan.next
    frame.craft:SetLabel(step and ("Craft next: " .. Name(step.r.creates) .. " x" .. step.crafts) or (HEX.muted .. "Craft next|r"))
    frame.note:SetText(preview and "Not tracked yet." or (step and "" or (plan.left > 0 and "Get the materials first." or "")))
end

-- Open the window on a recipe: the tracked one, or a preview of another.
function UI.Open(r)
    if not frame then Build() end
    local t = Track.Current()
    if r and not (t and ns.ProfessionData.recipes[t.id] == r) then
        preview = { r = r, n = 1 }
    elseif not r and not t then
        return false
    else
        preview = nil
    end
    frame:Show()
    UI.Refresh()
    return true
end

function UI.IsShown() return frame ~= nil and frame:IsShown() end
UI.frame = function() return frame end

ns.Data.Window(UI, { "crafttrack", "bags", "prices", "skills", "crafts" })
