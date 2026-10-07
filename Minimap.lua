-- TALOD - minimap button: the addon's icon on the minimap's edge.
-- Left-click the Main menu (every window from there), Shift the economy
-- window, Alt the market, Ctrl the Enemies nearby panel, right-click the
-- settings, Shift + right-click the guild; drag it along the edge.
--
-- No library: the classic look (tracking border, round background) built by
-- hand, round or square minimaps (GetMinimapShape). Minimap collectors such
-- as EllesmereUIMinimap take buttons into their own bar (by name, so the
-- frame is TALODMinimapButton); once reparented, its place is theirs.

local ADDON_NAME, ns = ...
local Style = ns.Style
local HEX = Style.HEX

local Mini = {}
ns.MinimapButton = Mini

local ICON = "Interface\\Icons\\Ability_DualWield"
local EDGE = 5             -- how far outside the minimap's edge the button's center sits

local button, shownState

local function db() return ns.DB() end

-- Ours to place only while it sits on the minimap itself.
local function OnMinimap() return button and Minimap and button:GetParent() == Minimap end

local function Place()
    if not OnMinimap() then return end
    local angle = math.rad(db().minimapAngle or 200)
    local x, y = math.cos(angle), math.sin(angle)
    local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
    if shape == "SQUARE" then
        -- From the circle out to the square's edge.
        local m = math.max(math.abs(x), math.abs(y))
        x, y = x / m, y / m
    end
    local rx = (Minimap:GetWidth() or 140) / 2 + EDGE
    local ry = (Minimap:GetHeight() or 140) / 2 + EDGE
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x * rx, y * ry)
end
Mini.Place = Place

local function DragUpdate()
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    if not (mx and cx) then return end
    db().minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx)) % 360
    Place()
end

local function OnClick(_, mouse)
    if mouse == "RightButton" and IsShiftKeyDown and IsShiftKeyDown() and ns.GuildUI then
        ns.GuildUI.Toggle()
    elseif mouse == "RightButton" then
        if ns.Options then ns.Options.Toggle() end
    elseif IsShiftKeyDown and IsShiftKeyDown() then
        if ns.EconomyUI then ns.EconomyUI.Toggle() else ns.Print("the economy window is not available.") end
    elseif IsAltKeyDown and IsAltKeyDown() then
        if ns.MarketUI then ns.MarketUI.Toggle() end
    elseif IsControlKeyDown and IsControlKeyDown() then
        db().panelShown = not db().panelShown
        ns.Print("Enemies nearby panel " .. (db().panelShown and "shown." or "hidden."))
        ns.Refresh()
    elseif ns.Nav then
        ns.Nav.ToggleMenu()
    else
        ns.GearUI.Toggle()
    end
end

local function Tooltip(self)
    local t = ns.Tooltip.Open(self, "ANCHOR_LEFT"):Title(ns.TITLE)
    t:Pair("Left-click", "main menu (every " .. ns.NAME .. " window)")
    if ns.EconomyUI then t:Pair("Shift + left-click", "economy") end
    if ns.MarketUI then t:Pair("Alt + left-click", "market (auction prices, selling, profit)") end
    t:Pair("Ctrl + left-click", "show / hide the Enemies nearby panel")
    t:Pair("Right-click", "settings")
    if ns.GuildUI then t:Pair("Shift + right-click", "guild (recruiting, roster, promotions)") end
    if OnMinimap() then t:Note("Drag: move it around the minimap.") end
    t:Show()
end

local function Build()
    if button or not Minimap then return end
    button = CreateFrame("Button", ns.FRAME .. "MinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetSize(20, 20)
    bg:SetPoint("TOPLEFT", 7, -5)
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ICON)
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 7, -6)
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    button.icon = icon
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")

    button:SetScript("OnClick", OnClick)
    button:SetScript("OnEnter", Tooltip)
    button:SetScript("OnLeave", function() ns.Tooltip.Hide() end)
    button:SetScript("OnDragStart", function(self)
        if not OnMinimap() then return end
        self:SetScript("OnUpdate", DragUpdate)
    end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    Place()
end

-- Shows or hides only when the setting changes: a minimap collector may
-- hide the button itself, and that is left alone.
local function Refresh()
    if not button then return end
    local want = db().minimapButton and true or false
    if want ~= shownState then
        shownState = want
        button:SetShown(want)
        if want then Place() end
    end
end
Mini.Refresh = Refresh

local function Slash(command)
    if command ~= "minimap" then return false end
    db().minimapButton = not db().minimapButton
    Refresh()
    ns.Print("minimap button " .. (db().minimapButton and "shown." or "hidden (" .. ns.Cmd.Text("minimap") .. " shows it again)."))
    if ns.Options then ns.Options.Refresh() end
    return true
end

function Mini.Button() return button end

ns.RegisterModule("MinimapButton", {
    defaults = { minimapButton = true, minimapAngle = 200 },
    init = function() Build() Refresh() end,
    refresh = Refresh,
    slash = Slash,
})
