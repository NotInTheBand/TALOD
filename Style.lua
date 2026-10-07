-- TALOD - shared look: colors, surfaces, buttons, tabs, panels, lists
-- and windows, so the enemies panel, the character window and the HUD
-- pieces read as one addon. Plain textures only (no BackdropTemplate needed).

local ADDON_NAME, ns = ...

local Style = {}
ns.Style = Style

local WHITE = "Interface\\Buttons\\WHITE8X8"
Style.WHITE = WHITE
Style.ROW = 20

-- One accent (the addon's orange) for "this / selected", one blue for
-- "compared"; green and red only for gains and losses. Safety colors
-- (danger, threshold, safe) stay in Core's ns.COLORS (colorblind aware).
Style.COLORS = {
    window = { 0.055, 0.055, 0.06, 1 }, hud = { 0.04, 0.04, 0.045, 0.82 }, titleBar = { 0.09, 0.09, 0.10, 1 },
    border = { 0.24, 0.24, 0.26, 1 }, card = { 1, 1, 1, 0.025 }, cardBorder = { 1, 1, 1, 0.06 },
    stripe = { 1, 1, 1, 0.03 }, line = { 1, 1, 1, 0.08 }, button = { 0.13, 0.13, 0.14, 1 },
    accent = { 1, 0.50, 0.25 }, compare = { 0.35, 0.63, 1 }, bar = { 0.16, 0.47, 0.84 }, grid = { 1, 1, 1, 0.07 },
    text = { 1, 1, 1 }, muted = { 0.62, 0.62, 0.62 },
}
local COLORS = Style.COLORS
Style.HEX = { accent = "|cffff8040", compare = "|cff5aa0ff", muted = "|cff8a8a8a", dim = "|cff5c5c5c", gold = "|cffffd100",
    good = "|cff40ff40", bad = "|cffff5050", source = "|cffc8b48c", white = "|cffffffff" }
local HEX = Style.HEX

---------------------------------------------------------------------------
-- Primitives
---------------------------------------------------------------------------
function Style.Fill(region, c, a) region:SetColorTexture(c[1], c[2], c[3], a or c[4] or 1) end
local Fill = Style.Fill

function Style.Texture(parent, layer, c)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND")
    t:SetTexture(WHITE)
    if c then Fill(t, c) end
    return t
end
local Texture = Style.Texture

-- 1 px border; frame:SetBorderColor(r, g, b, a) recolors it.
function Style.Border(f, c)
    local edges = {}
    for i, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local t = Texture(f, "BORDER", c)
        if side == "TOP" or side == "BOTTOM" then
            t:SetHeight(1)
            t:SetPoint(side .. "LEFT")
            t:SetPoint(side .. "RIGHT")
        else
            t:SetWidth(1)
            t:SetPoint("TOP" .. side)
            t:SetPoint("BOTTOM" .. side)
        end
        edges[i] = t
    end
    f.SetBorderColor = function(_, r, g, b, a)
        for _, t in ipairs(edges) do t:SetColorTexture(r, g, b, a or 1) end
    end
    return edges
end

-- Flat background + border on any frame. kind: "window" (default) or "hud"
-- (more see-through, for things that sit over the game world).
function Style.Surface(f, kind)
    f.surface = Texture(f, "BACKGROUND", kind == "hud" and COLORS.hud or COLORS.window)
    f.surface:SetAllPoints()
    Style.Border(f, COLORS.border)
    return f
end

function Style.Text(parent, template, justify)
    local fs = parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlightSmall")
    fs:SetJustifyH(justify or "LEFT")
    if fs.SetWordWrap then fs:SetWordWrap(false) end
    return fs
end
local Text = Style.Text

function Style.HLine(parent, c)
    local t = Texture(parent, "ARTWORK", c or COLORS.line)
    t:SetHeight(1)
    return t
end

---------------------------------------------------------------------------
-- Controls
---------------------------------------------------------------------------
-- Flat button: dark fill, hairline border that lights up on hover. Text
-- buttons by default; opts.icon makes a square icon button.
function Style.Button(parent, text, width, onClick, tooltip, opts)
    opts = opts or {}
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width, opts.height or 22)
    b.bg = Texture(b, "BACKGROUND", COLORS.button)
    b.bg:SetAllPoints()
    Style.Border(b, COLORS.border)
    if opts.icon then
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetPoint("TOPLEFT", 3, -3)
        b.icon:SetPoint("BOTTOMRIGHT", -3, 3)
        b.icon:SetTexture(opts.icon)
    end
    b.label = Text(b, "GameFontNormalSmall", "CENTER")
    b.label:SetPoint("LEFT", 6, 0)
    b.label:SetPoint("RIGHT", -6, 0)
    b.label:SetText(text or "")
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function(self)
        self:SetBorderColor(COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.9)
        local tip = type(tooltip) == "function" and tooltip() or tooltip
        if tip then
            local title = opts.title or ((self.label:GetText() or ""):gsub("%s*>$", ""))
            ns.Tooltip.Text(self, { title ~= "" and title or tip, title ~= "" and tip or nil })
        end
    end)
    b:SetScript("OnLeave", function(self)
        local c = self.borderColor or COLORS.border
        self:SetBorderColor(c[1], c[2], c[3], c[4] or 1)
        ns.Tooltip.Hide()
    end)
    b.SetLabel = function(self, t) self.label:SetText(t) end
    return b
end

-- Tab row: text with an accent underline on the selected tab.
-- defs = { { key, label } }; returns tabs with tabs:Select(key).
function Style.Tabs(parent, defs, onSelect, width)
    local tabs = {}
    local x = 0
    for i, def in ipairs(defs) do
        local b = CreateFrame("Button", nil, parent)
        b:SetSize(width or 96, 26)
        b:SetPoint("TOPLEFT", x, 0)
        x = x + (width or 96) + 4
        b.text = Text(b, "GameFontNormal", "CENTER")
        b.text:SetAllPoints()
        b.text:SetText(def.label)
        b.line = Texture(b, "ARTWORK", COLORS.accent)
        b.line:SetHeight(2)
        b.line:SetPoint("BOTTOMLEFT", 8, 0)
        b.line:SetPoint("BOTTOMRIGHT", -8, 0)
        b.hl = Texture(b, "HIGHLIGHT", { 1, 1, 1, 0.05 })
        b.hl:SetAllPoints()
        b:SetScript("OnClick", function() onSelect(def.key) end)
        b.key = def.key
        tabs[i] = b
    end
    function tabs:Select(key)
        for _, b in ipairs(self) do
            local selected = b.key == key
            b.line:SetShown(selected)
            b.text:SetTextColor(selected and 1 or 0.62, selected and 0.82 or 0.62, selected and 0.55 or 0.62)
        end
    end
    return tabs
end

-- A titled panel with a summary line. Returns the panel; its .content
-- frame holds whatever goes inside.
function Style.Card(parent, title)
    local card = CreateFrame("Frame", nil, parent)
    local bg = Texture(card, "BACKGROUND", COLORS.card)
    bg:SetAllPoints()
    Style.Border(card, COLORS.cardBorder)
    card.title = Text(card, "GameFontNormal")
    card.title:SetPoint("TOPLEFT", 10, -8)
    card.title:SetPoint("RIGHT", -10, 0)
    card.title:SetText(title or "")
    card.sub = Text(card, "GameFontDisableSmall")
    card.sub:SetPoint("TOPLEFT", card.title, "BOTTOMLEFT", 0, -3)
    card.sub:SetPoint("RIGHT", -10, 0)
    local line = Style.HLine(card)
    line:SetPoint("TOPLEFT", 1, -44)
    line:SetPoint("TOPRIGHT", -1, -44)
    card.content = CreateFrame("Frame", nil, card)
    card.content:SetPoint("TOPLEFT", 4, -48)
    card.content:SetPoint("BOTTOMRIGHT", -4, 4)
    return card
end

-- A movable window with a title bar and a close button. opts.nav = page key
-- makes it a main window: the page list on its left, one open at a time
-- (Navigation.lua).
---------------------------------------------------------------------------
-- Size grip: three diagonal lines in the bottom-right corner. Drag to resize
-- (the frame's own layout follows, anchored to its edges); double-click puts
-- the default size back.
--   opts: min = { w, h }, onResized(w, h) after a drag, onReset() on a
--   double-click.
---------------------------------------------------------------------------
local GRIP = 14

function Style.SizeGrip(f, opts)
    opts = opts or {}
    local minW, minH = (opts.min or {})[1] or 200, (opts.min or {})[2] or 150
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(GRIP, GRIP)
    grip:SetPoint("BOTTOMRIGHT", -1, 1)
    grip:SetFrameLevel((f:GetFrameLevel() or 1) + 20)
    grip.lines = {}
    local function Paint(on)
        local c = on and COLORS.accent or COLORS.muted
        for _, l in ipairs(grip.lines) do
            if l.SetColorTexture then l:SetColorTexture(c[1], c[2], c[3], on and 1 or 0.7) end
        end
    end
    if grip.CreateLine then
        for i, k in ipairs({ 4, 8, 12 }) do
            local l = grip:CreateLine(nil, "OVERLAY")
            if l.SetThickness then l:SetThickness(1) end
            if l.SetStartPoint then
                l:SetStartPoint("BOTTOMRIGHT", grip, -k, 2)
                l:SetEndPoint("BOTTOMRIGHT", grip, -2, k)
            end
            grip.lines[i] = l
        end
    end
    Paint(false)
    grip:SetScript("OnEnter", function(self)
        Paint(true)
        ns.Tooltip.Text(self, { "Resize", "Drag to make the window bigger or smaller.", "Double-click: default size." })
    end)
    grip:SetScript("OnLeave", function(self)
        if not self.sizing then Paint(false) end
        ns.Tooltip.Hide()
    end)
    -- Sized by hand, not with StartSizing: the game's sizing grows a frame
    -- around its anchor (a window opened at CENTER grew on every side) and
    -- fights the rail's clamp insets. Here the top-left corner is pinned and
    -- the size is the size at the press plus how far the cursor moved.
    local function Cursor()
        local x, y = GetCursorPosition()
        local scale = f:GetEffectiveScale() or 1
        if not x or not y or scale <= 0 then return nil end
        return x / scale, y / scale
    end
    local function Follow(self)
        local x, y = Cursor()
        if not x then return end
        local maxW = (UIParent:GetRight() or UIParent:GetWidth() or 4096) - (self.left or 0)
        local maxH = (self.top or 4096) - (UIParent:GetBottom() or 0)
        local w = math.max(minW, math.min(maxW, self.w0 + x - self.x0))
        local h = math.max(minH, math.min(maxH, self.h0 + self.y0 - y))
        if math.abs(w - (f:GetWidth() or 0)) >= 0.5 or math.abs(h - (f:GetHeight() or 0)) >= 0.5 then f:SetSize(w, h) end
    end
    grip:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        local x, y = Cursor()
        local left, top = f:GetLeft(), f:GetTop()
        if not (x and left and top) then return end
        self.sizing = true
        self.x0, self.y0, self.w0, self.h0 = x, y, f:GetWidth(), f:GetHeight()
        self.left, self.top = left, top
        ns.Tooltip.Hide()
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        self:SetScript("OnUpdate", Follow)
    end)
    local function Stop(self)
        if not self.sizing then return end
        Follow(self)
        self.sizing = false
        self:SetScript("OnUpdate", nil)
        Paint(self:IsMouseOver())
        if opts.onResized then opts.onResized(f:GetWidth(), f:GetHeight()) end
    end
    grip:SetScript("OnMouseUp", Stop)
    -- Closed mid-drag (Escape): the game would keep sizing a hidden frame.
    f:HookScript("OnHide", function() Stop(grip) end)
    grip:SetScript("OnDoubleClick", function()
        if opts.onReset then opts.onReset() end
    end)
    f.sizeGrip = grip
    return grip
end

-- opts.nav: a main window; its size is the one all main windows share
-- (Navigation.lua), so width / height may be nil.
function Style.Window(name, title, width, height, opts)
    if opts and opts.nav and ns.Nav then width, height = ns.Nav.Size() end
    local f = CreateFrame("Frame", name, UIParent)
    f:SetSize(width, height)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    if f.SetToplevel then f:SetToplevel(true) end
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetClampedToScreen(true)
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    Style.Surface(f)
    local bar = Texture(f, "BACKGROUND", COLORS.titleBar)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:SetHeight(38)
    f.title = Text(f, "GameFontNormalLarge")
    f.title:SetPoint("TOPLEFT", 14, -12)
    f.title:SetText(ns.TITLE .. "  " .. HEX.white .. (title or "") .. "|r")
    local close = CreateFrame("Button", nil, f)
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -8, -7)
    close.x = Text(close, "GameFontNormalLarge", "CENTER")
    close.x:SetPoint("CENTER", 0, 1)
    close.x:SetText(HEX.muted .. "×|r")
    close:SetScript("OnEnter", function(self) self.x:SetText(HEX.white .. "×|r") end)
    close:SetScript("OnLeave", function(self) self.x:SetText(HEX.muted .. "×|r") end)
    close:SetScript("OnClick", function() f:Hide() end)
    f.close = close
    if name and UISpecialFrames then table.insert(UISpecialFrames, name) end
    -- opts.hidden: built ahead of time (Data.Window prebuild). Hidden before
    -- the navigation sees it, or it would close the window that is open.
    if opts and opts.hidden then f:Hide() end
    if opts and opts.nav and ns.Nav then ns.Nav.Attach(f, opts.nav, title) end
    return f
end

-- Small square badge with a 1 px colored frame around an icon texture.
function Style.IconFrame(parent, size)
    local holder = Texture(parent, "ARTWORK", { 0.3, 0.3, 0.3, 0.9 })
    holder:SetSize(size, size)
    local icon = parent:CreateTexture(nil, "OVERLAY")
    icon:SetPoint("TOPLEFT", holder, "TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -1, 1)
    return holder, icon
end

function Style.QualityColor(link)
    local hex = type(link) == "string" and link:match("|c(%x%x%x%x%x%x%x%x)")
    if not hex then return 0.4, 0.4, 0.4 end
    return tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255, tonumber(hex:sub(7, 8), 16) / 255
end

---------------------------------------------------------------------------
-- Scrolling list of pooled rows
--   item fields: text, header (gold section title), icon, iconEmpty, link
--   (quality border), label (left column), cols (right-aligned columns),
--   bar = { value, max } (thin progress bar under the text), accent (color
--   bar on the left), tint, indent, tooltip(owner); for the filters: time
--   (when it happened) and search (text to match, else text, label, cols).
--   opts: labelWidth, colWidths, onClick(item, button), fallbackRows,
--   search = true (a search box), time = true (a time range), hint,
--   columns = { name = "Item", label = "When", "Price", ... } (a fixed
--   title row; [c] titles cols[c]).
-- A scrollbar shows when the rows do not fit: drag the thumb or click the
-- track; the mouse wheel scrolls as before.
--
-- Column titles sit right above their column: opts.columns for the whole
-- list (name titles the text, label the label column), or a
-- section header row with cols = { titles } (its text titles the text
-- column; sortId keeps its sort while the text changes). Clicking a title
-- sorts the rows under it (each section on its own): once in its natural
-- direction (names A-Z, numbers high first), again reversed, a third time
-- back to the list's own order. A row sorts by sort = { [0] = text, label =,
-- [c] = col } when given, else by its shown text (money, numbers, percents
-- read as numbers). Unknown ("-", "?", empty) stays last either way. A row
-- without cols under a titled section belongs to the row above it.
---------------------------------------------------------------------------
local TOOLBAR = 28
local BAR_WIDTH = 8

Style.TIME_RANGES = {
    { key = "all", label = "All time" }, { key = "hour", label = "Last hour" }, { key = "today", label = "Today" },
    { key = "week", label = "Last 7 days" }, { key = "month", label = "Last 30 days" },
}

-- The oldest time a range keeps (nil: everything).
function Style.RangeStart(key)
    local now = time()
    if key == "hour" then return now - 3600 end
    if key == "today" then
        local d = date("*t", now)
        return time({ year = d.year, month = d.month, day = d.day, hour = 0 })
    end
    if key == "week" then return now - 7 * 86400 end
    if key == "month" then return now - 30 * 86400 end
    return nil
end

-- Text of a row without color codes, lowercased, for searching.
local function Plain(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):lower())
end

-- A row may carry build(item), which fills its label / text / cols / tooltip
-- the first time the row is drawn or searched: a list of thousands of rows
-- then formats only the ones on screen. Header and time must be set up front
-- (filtering reads them).
local function Ready(item)
    local build = item.build
    if build then
        item.build = nil
        build(item)
    end
    return item
end
Style.ReadyRow = Ready

local function SearchText(item)
    Ready(item)
    -- Kept on the row (searching re-reads every row per key press) while
    -- its text stays the same.
    local source = item.search or item.text
    if item.searchPlain and item.searchOf == source then return item.searchPlain end
    local plain
    if item.search then
        plain = Plain(item.search)
    else
        local parts = { Plain(item.text), Plain(item.label) }
        for _, c in ipairs(item.cols or {}) do parts[#parts + 1] = Plain(c) end
        plain = table.concat(parts, " ")
    end
    item.searchPlain, item.searchOf = plain, source
    return plain
end

-- What a cell sorts by: a number for money ("1g 2s 3c", "-17c"), counts
-- and percents ("+52%", "3/5" -> 3), else the lowercased text; nil for
-- unknown, so it can stay last.
local AGO = { s = 1, m = 60, min = 60, h = 3600, d = 86400, day = 86400, days = 86400 }
function Style.SortValue(text)
    if type(text) == "number" then return text end
    local p = Plain(text):gsub("^%s+", ""):gsub("%s+$", "")
    if p == "" or p == "-" or p:sub(1, 1) == "?" then return nil end
    -- "5 min ago", "3h ago", "2 days ago": newest counts highest, like a time.
    local n, unit = p:match("^(%d+)%s*(%a+) ago")
    if n and AGO[unit] then return -tonumber(n) * AGO[unit] end
    local body = p:gsub("^[>=<~]+", "")
    local lead = body:match("^[+%-]?([%d%.,]+[%d%.,%sgsc]*)")
    if lead then
        lead = lead:gsub(",", "")
        local g, s, c = lead:match("(%d+)g"), lead:match("(%d+)s"), lead:match("(%d+)c")
        local v
        if g or s or c then
            v = (tonumber(g) or 0) * 10000 + (tonumber(s) or 0) * 100 + (tonumber(c) or 0)
        else
            v = tonumber(lead:match("^[%d%.]+"))
        end
        if v then return body:sub(1, 1) == "-" and -v or v end
    end
    return p
end

-- A flat search box with a hint; onChange(text) on every key.
function Style.SearchBox(parent, onChange, hint)
    local box = CreateFrame("EditBox", nil, parent)
    box:SetHeight(22)
    box:SetAutoFocus(false)
    box:SetFontObject("GameFontHighlightSmall")
    box:SetTextInsets(8, 22, 0, 0)
    local bg = Texture(box, "BACKGROUND", COLORS.button)
    bg:SetAllPoints()
    Style.Border(box, COLORS.border)
    box.hint = Text(box, "GameFontDisableSmall")
    box.hint:SetPoint("LEFT", 8, 0)
    box.hint:SetText(hint or "Search...")
    box.clear = CreateFrame("Button", nil, box)
    box.clear:SetSize(18, 18)
    box.clear:SetPoint("RIGHT", -2, 0)
    box.clear.x = Text(box.clear, "GameFontNormalSmall", "CENTER")
    box.clear.x:SetPoint("CENTER")
    box.clear.x:SetText(HEX.muted .. "×|r")
    box.clear:SetScript("OnClick", function() box:SetText("") box:ClearFocus() end)
    box.clear:Hide()
    box:SetScript("OnTextChanged", function(self)
        local text = self:GetText() or ""
        self.hint:SetShown(text == "")
        self.clear:SetShown(text ~= "")
        onChange(text)
    end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    return box
end

function Style.List(parent, opts)
    opts = opts or {}
    local ROW = Style.ROW
    local list = CreateFrame("Frame", nil, parent)
    list:SetAllPoints()
    list.rows, list.items, list.all, list.offset = {}, {}, {}, 0
    list.labelWidth = opts.labelWidth or 0
    list.colWidths = opts.colWidths or {}
    list.search, list.range = "", "all"
    list.top = ((opts.search or opts.time) and TOOLBAR or 0) + (opts.columns and ROW or 0)
    list.sorts = {}
    local built = 0

    -- Sorting by a column title (see the header comment).
    local STICKY = "*"
    local function SortId(item) return item.sticky and STICKY or item.sortId or Plain(item.text) end
    local function Titled(item) return item.header and item.cols ~= nil end

    local function TitleText(item, col, title)
        local s = list.sorts[SortId(item)]
        if s and s.col == col then return HEX.gold .. title .. (s.flip and "  ^" or "  v") .. "|r" end
        return (col == 0 and HEX.gold or HEX.muted) .. title .. "|r"
    end

    -- Which title the cursor is over: a col, "label", 0 (the text) or nil.
    local function TitleAt(r)
        if type(GetCursorPosition) ~= "function" then return nil end
        local x = GetCursorPosition()
        if not x then return nil end
        x = x / (r:GetEffectiveScale() or 1)
        local rowRight = r:GetRight()
        if not rowRight then return nil end
        -- The same slots Layout uses: cols[1] rightmost, 6 px apart.
        local first, edge = nil, 6
        for c = 1, 3 do
            local w = list.colWidths[c]
            if not w then break end
            local hi = rowRight - edge
            local lo = hi - w
            if x >= lo - 3 and x <= hi + 3 then return (r.item.cols[c] or "") ~= "" and c or nil end
            first = lo
            edge = edge + w + 6
        end
        if r.label:IsShown() then
            local l, rr = r.label:GetLeft(), r.label:GetRight()
            if l and rr and x >= l - 3 and x <= rr + 3 then return "label" end
        end
        if not first or x < first then return 0 end
        return nil
    end

    -- New titles for the fixed title row (a column that changes meaning).
    function list:SetColumns(columns)
        opts.columns = columns
        self:Draw()
    end

    function list:SortBy(id, col)
        local s = self.sorts[id]
        if not s or s.col ~= col then self.sorts[id] = { col = col, flip = false }
        elseif not s.flip then s.flip = true
        else self.sorts[id] = nil end
        self.sortVer = self.sortVer + 1
        if id == STICKY then self.offset = 0 end
        self:SetItems(self.all)
    end

    local function MakeRow(i)
        local r = CreateFrame("Button", nil, list)
        r:SetHeight(ROW)
        r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        r.bg = Texture(r, "BACKGROUND")
        r.bg:SetAllPoints()
        r.accent = Texture(r, "ARTWORK")
        r.accent:SetWidth(3)
        r.accent:SetPoint("TOPLEFT")
        r.accent:SetPoint("BOTTOMLEFT")
        r.iconBorder, r.icon = Style.IconFrame(r, ROW - 2)
        r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        r.barBg = Texture(r, "ARTWORK", { 1, 1, 1, 0.08 })
        r.barBg:SetHeight(3)
        r.barFill = Texture(r, "OVERLAY", COLORS.bar)
        r.barFill:SetHeight(3)
        r.label = Text(r, "GameFontDisableSmall", "RIGHT")
        r.text = Text(r, "GameFontHighlightSmall")
        r.cols = {}
        for c = 1, 3 do r.cols[c] = Text(r, "GameFontHighlightSmall", "RIGHT") end
        local hl = r:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.05)
        r:SetScript("OnClick", function(self, button)
            local item = self.item
            if item and Titled(item) then
                local col = TitleAt(self)
                if col ~= nil then list:SortBy(SortId(item), col) end
            elseif opts.onClick and item and not item.header then
                opts.onClick(item, button)
            end
        end)
        r:SetScript("OnEnter", function(self)
            local item = self.item
            if not item then return end
            if item.tooltip then item.tooltip(self)
            elseif Titled(item) then
                ns.Tooltip.Text(self, { "Sort", "Click a column title to sort the rows under it. Again: the other way. A third time: the usual order." })
            end
        end)
        r:SetScript("OnLeave", function() ns.Tooltip.Hide() end)
        return r
    end

    local function Layout(r, item, index)
        local x = 6 + (item.indent or 0)
        r.bg:SetColorTexture(1, 1, 1, 0)
        if item.tint then Fill(r.bg, item.tint)
        elseif not item.header and index % 2 == 0 then Fill(r.bg, COLORS.stripe) end
        r.accent:SetShown(item.accent ~= nil)
        if item.accent then Fill(r.accent, item.accent) end

        local titled = Titled(item)
        local useLabel = list.labelWidth > 0 and (not item.header or (titled and item.label ~= nil))
        r.label:SetShown(useLabel)
        if useLabel then
            r.label:ClearAllPoints()
            r.label:SetPoint("LEFT", x, 0)
            r.label:SetWidth(list.labelWidth)
            r.label:SetText(titled and TitleText(item, "label", item.label) or (item.label or ""))
            x = x + list.labelWidth + 8
        end
        local hasIcon = item.icon ~= nil
        r.iconBorder:SetShown(hasIcon)
        r.icon:SetShown(hasIcon)
        if hasIcon then
            r.iconBorder:ClearAllPoints()
            r.iconBorder:SetPoint("LEFT", x, 0)
            r.icon:SetTexture(item.icon)
            if r.icon.SetDesaturated then r.icon:SetDesaturated(item.iconEmpty and true or false) end
            r.icon:SetAlpha(item.iconEmpty and 0.35 or 1)
            local qr, qg, qb = Style.QualityColor(item.link)
            r.iconBorder:SetColorTexture(qr, qg, qb, item.iconEmpty and 0.25 or 0.9)
            x = x + ROW + 4
        end

        local right = 6
        for c = 1, 3 do
            local fs, w = r.cols[c], list.colWidths[c]
            local value = item.cols and item.cols[c]
            fs:SetShown(w ~= nil and value ~= nil)
            if w and value then
                fs:ClearAllPoints()
                fs:SetPoint("RIGHT", -right, 0)
                -- A title may run a little past a narrow column (0 = its own width).
                fs:SetWidth(titled and 0 or w)
                fs:SetText((titled and value ~= "") and TitleText(item, c, value) or value)
            end
            if w then right = right + w + 6 end
        end
        local textRight = item.cols and right or 6
        r.text:ClearAllPoints()
        r.text:SetPoint("LEFT", x, item.bar and 2 or 0)
        r.text:SetPoint("RIGHT", -textRight, item.bar and 2 or 0)
        r.text:SetFontObject(item.header and "GameFontNormalSmall" or "GameFontHighlightSmall")
        if titled then r.text:SetText(TitleText(item, 0, item.text or ""))
        else r.text:SetText(item.header and (HEX.gold .. item.text .. "|r") or (item.text or "")) end

        local bar = item.bar
        r.barBg:SetShown(bar ~= nil)
        r.barFill:SetShown(bar ~= nil and (bar[1] or 0) > 0)
        if bar then
            r.barBg:ClearAllPoints()
            r.barBg:SetPoint("BOTTOMLEFT", x, 2)
            r.barBg:SetPoint("BOTTOMRIGHT", -textRight, 2)
            local width = math.max(1, (r:GetWidth() or 200) - x - textRight)
            local frac = (bar[2] and bar[2] > 0) and math.min(1, (bar[1] or 0) / bar[2]) or 0
            r.barFill:ClearAllPoints()
            r.barFill:SetPoint("BOTTOMLEFT", x, 2)
            r.barFill:SetWidth(math.max(1, width * frac))
            Fill(r.barFill, bar.color or COLORS.bar)
        end
    end

    -- Scrollbar: a track (click: jump there) and a thumb (drag).
    local track = CreateFrame("Button", nil, list)
    track:SetWidth(BAR_WIDTH)
    track:SetPoint("TOPRIGHT", 0, -list.top)
    track:SetPoint("BOTTOMRIGHT")
    track.bg = Texture(track, "BACKGROUND", { 1, 1, 1, 0.05 })
    track.bg:SetPoint("TOPLEFT", 2, -1)
    track.bg:SetPoint("BOTTOMRIGHT", -2, 1)
    local thumb = CreateFrame("Button", nil, track)
    thumb:SetWidth(BAR_WIDTH)
    thumb.tex = Texture(thumb, "ARTWORK", { COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.55 })
    thumb.tex:SetPoint("TOPLEFT", 2, 0)
    thumb.tex:SetPoint("BOTTOMRIGHT", -2, 0)
    list.track, list.thumb = track, thumb

    local function MaxOffset() return math.max(0, #list.items - (list.visible or 1)) end
    -- Offset for the cursor's height on the track.
    local function OffsetAtCursor(grab)
        local top, height = track:GetTop(), track:GetHeight()
        local _, cy = GetCursorPosition()
        local scale = track:GetEffectiveScale() or 1
        if not top or not height or height <= 0 or not cy then return nil end
        local thumbH = thumb:GetHeight() or 0
        local frac = (top - cy / scale - (grab or thumbH / 2)) / math.max(1, height - thumbH)
        return math.floor(math.max(0, math.min(1, frac)) * MaxOffset() + 0.5)
    end
    thumb:SetScript("OnMouseDown", function(self)
        local _, cy = GetCursorPosition()
        local scale = self:GetEffectiveScale() or 1
        local top = self:GetTop()
        self.grab = (top and cy) and (top - cy / scale) or nil
        self:SetScript("OnUpdate", function()
            local off = OffsetAtCursor(self.grab)
            if off and off ~= list.offset then list.offset = off list:Draw() end
        end)
    end)
    thumb:SetScript("OnMouseUp", function(self) self:SetScript("OnUpdate", nil) end)
    thumb:SetScript("OnHide", function(self) self:SetScript("OnUpdate", nil) end)
    track:SetScript("OnClick", function()
        local off = OffsetAtCursor()
        if off then list.offset = off list:Draw() end
    end)

    local function PlaceBar(count)
        local total = #list.items
        local show = total > count and count > 0
        track:SetShown(show)
        if not show then return false end
        local height = (list:GetHeight() or 0) - list.top
        local thumbH = math.max(16, height * count / total)
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPRIGHT", track, "TOPRIGHT", 0, -(height - thumbH) * (list.offset / math.max(1, total - count)))
        return true
    end

    -- The height is only known after the game lays the window out; until
    -- then draw generously (rows past the bottom are clipped by the parent)
    -- and redraw once the real size arrives.
    function list:Draw()
        local h = (self:GetHeight() or 0) - self.top
        if h < ROW and not self.retry and C_Timer and C_Timer.After then
            self.retry = true
            C_Timer.After(0, function() self.retry = nil if self:IsVisible() and (self:GetHeight() or 0) - self.top >= ROW then self:Draw() end end)
        end
        local count = h >= ROW and math.floor(h / ROW) or (opts.fallbackRows or 30)
        while built < count do built = built + 1; self.rows[built] = MakeRow(built) end
        self.visible = count
        self.offset = math.max(0, math.min(self.offset, #self.items - count))
        local bar = PlaceBar(count)
        if opts.columns then
            if not self.head then
                self.headItem = { header = true, sticky = true, cols = {}, tint = { 1, 1, 1, 0.04 } }
                self.head = MakeRow(0)
                self.head.item = self.headItem
            end
            local h = self.headItem
            h.text, h.label = opts.columns.name or "", opts.columns.label
            for c = 1, 3 do h.cols[c] = opts.columns[c] end
            local y = -(self.top - ROW)
            self.head:ClearAllPoints()
            self.head:SetPoint("TOPLEFT", 0, y)
            self.head:SetPoint("TOPRIGHT", bar and -BAR_WIDTH - 2 or 0, y)
            self.head:Show()
            Layout(self.head, self.headItem, 0)
        end
        for i, r in ipairs(self.rows) do
            local item = i <= count and self.items[i + self.offset] or nil
            r.item = item
            if item then
                r:ClearAllPoints()
                r:SetPoint("TOPLEFT", 0, -self.top - (i - 1) * ROW)
                r:SetPoint("TOPRIGHT", bar and -BAR_WIDTH - 2 or 0, -self.top - (i - 1) * ROW)
                r:Show()
                Layout(r, Ready(item), i + self.offset)
            else
                r:Hide()
            end
        end
    end

    -- Search and time range: a section header stays only above rows that
    -- match. A header with a time is one entry with its detail rows (a
    -- ledger change): its time decides, and a match anywhere in it shows all.
    local function Filter(items)
        local needle = list.search
        local since = Style.RangeStart(list.range)
        if needle == "" and not since then return items, false end
        local out, header = {}, nil
        local i = 1
        while i <= #items do
            local item = items[i]
            if item.header and item.time ~= nil then
                local j = i + 1
                while j <= #items and not items[j].header do j = j + 1 end
                local ok = not since or item.time >= since
                if ok and needle ~= "" then
                    ok = false
                    for k = i, j - 1 do if SearchText(items[k]):find(needle, 1, true) then ok = true break end end
                end
                if ok then for k = i, j - 1 do out[#out + 1] = items[k] end end
                header = nil
                i = j
            elseif item.header then
                header = item
                i = i + 1
            else
                i = i + 1
                local ok = true
                if since and item.time ~= nil then ok = item.time >= since
                elseif since and item.time == nil then ok = not item.timed end
                if ok and needle ~= "" then ok = SearchText(item):find(needle, 1, true) ~= nil end
                if ok then
                    if header then out[#out + 1] = header header = nil end
                    out[#out + 1] = item
                end
            end
        end
        return out, true
    end

    local function UpdateCount(filtered)
        if not list.count then return end
        -- Entries: dated headers when the list is grouped, else rows.
        local grouped = false
        for _, item in ipairs(list.all) do if item.header and item.time ~= nil then grouped = true break end end
        local function Units(items)
            local n = 0
            for _, item in ipairs(items) do
                if (grouped and item.header and item.time ~= nil) or (not grouped and not item.header) then n = n + 1 end
            end
            return n
        end
        local n, shown = Units(list.all), Units(list.items)
        list.count:SetText(filtered and (HEX.muted .. shown .. " of " .. n .. " shown|r") or "")
    end

    -- Column sorts, applied before the filters (headers stay in place).
    local function Key(item, col)
        if item.sort and item.sort[col] ~= nil then return item.sort[col] end
        if col == 0 then
            local t = Plain(item.text):gsub("^%s+", "")
            return t ~= "" and t or nil
        elseif col == "label" then
            if item.time then return item.time end
            return Style.SortValue(item.label)
        end
        return Style.SortValue(item.cols and item.cols[col])
    end

    -- Numbers high first and words A-Z (flip reverses both); numbers before
    -- words; unknown last; ties keep the list's own order.
    local function SortRun(run, s, out)
        local units = {}
        for _, item in ipairs(run) do
            Ready(item)
            local last = units[#units]
            if last and item.cols == nil and item.icon == nil and (item.label == nil or item.label == "") then
                last[#last + 1] = item
            else
                units[#units + 1] = { item, i = #units + 1, v = Key(item, s.col) }
            end
        end
        table.sort(units, function(a, b)
            local x, y = a.v, b.v
            if x == nil or y == nil then
                if (x == nil) ~= (y == nil) then return y == nil end
                return a.i < b.i
            end
            local tx, ty = type(x), type(y)
            if tx ~= ty then return tx == "number" end
            if x ~= y then
                if tx == "number" then return (x > y) ~= s.flip end
                return (x < y) ~= s.flip
            end
            return a.i < b.i
        end)
        for _, u in ipairs(units) do for _, item in ipairs(u) do out[#out + 1] = item end end
    end

    -- Kept while the same rows come back (Data.List hands the same table
    -- until its data changes) and no title was clicked.
    local sortedFrom, sortedVer, sortedOut
    list.sortVer = 0
    local function Sorted(items)
        if next(list.sorts) == nil then return items end
        if items == sortedFrom and sortedVer == list.sortVer then return sortedOut end
        local out, run = {}, {}
        local current = list.sorts[STICKY]
        local function Flush()
            if #run == 0 then return end
            if current then SortRun(run, current, out) else for _, item in ipairs(run) do out[#out + 1] = item end end
            run = {}
        end
        for _, item in ipairs(items) do
            if item.header then
                Flush()
                out[#out + 1] = item
                -- A dated header is one entry with its detail rows: never reordered inside.
                if item.time ~= nil then current = nil
                elseif item.cols then current = list.sorts[SortId(item)]
                else current = list.sorts[STICKY] end
            else
                run[#run + 1] = item
            end
        end
        Flush()
        sortedFrom, sortedVer, sortedOut = items, list.sortVer, out
        return out
    end

    function list:SetItems(items)
        self.all = items
        local filtered, active = Filter(Sorted(items))
        if active and #filtered == 0 then
            filtered = { { text = HEX.muted .. "Nothing matches the search / time range.|r" } }
        end
        self.items = filtered
        self.offset = math.min(self.offset, math.max(0, #self.items - (self.visible or 1)))
        UpdateCount(active)
        self:Draw()
    end

    if opts.search or opts.time then
        local bar = CreateFrame("Frame", nil, list)
        bar:SetPoint("TOPLEFT", 4, -3)
        bar:SetPoint("TOPRIGHT", -4, -3)
        bar:SetHeight(22)
        list.toolbar = bar
        local right = 0
        if opts.time then
            list.rangeButton = Style.Button(bar, "", 120, function(_, button)
                local i = 1
                for n, r in ipairs(Style.TIME_RANGES) do if r.key == list.range then i = n end end
                i = i + (button == "RightButton" and -1 or 1)
                if i > #Style.TIME_RANGES then i = 1 elseif i < 1 then i = #Style.TIME_RANGES end
                list:SetRange(Style.TIME_RANGES[i].key)
            end, "Left-click: next. Right-click: previous. Arrow: pick from a list.", { title = "Time range" })
            list.rangeButton:SetPoint("TOPRIGHT")
            Style.AttachDropdown(list.rangeButton, function()
                return Style.ChoiceItems(Style.TIME_RANGES, list.range, function(key) list:SetRange(key) end)
            end)
            right = 126
        end
        list.count = Text(bar, "GameFontDisableSmall", "RIGHT")
        list.count:SetPoint("RIGHT", -right - 4, 0)
        list.count:SetWidth(90)
        if opts.search then
            list.searchBox = Style.SearchBox(bar, function(text)
                list.search = Plain(text)
                list.offset = 0
                list:SetItems(list.all)
            end, opts.hint)
            list.searchBox:SetPoint("TOPLEFT")
            list.searchBox:SetPoint("TOPRIGHT", -right - 98, 0)
        end
    end

    function list:SetRange(key)
        self.range = key
        self.offset = 0
        if self.rangeButton then
            for _, r in ipairs(Style.TIME_RANGES) do if r.key == key then self.rangeButton:SetLabel(r.label .. "  >") end end
        end
        self:SetItems(self.all)
    end
    if list.rangeButton then list:SetRange("all") end

    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(self, delta)
        self.offset = math.max(0, math.min(MaxOffset(), self.offset - delta * 3))
        self:Draw()
    end)
    list:SetScript("OnSizeChanged", function(self) self:Draw() end)
    list:SetScript("OnShow", function(self) self:Draw() end)
    if list.SetClipsChildren then list:SetClipsChildren(true) end
    return list
end

---------------------------------------------------------------------------
-- Dropdown for a cycle button: a small arrow at the button's right edge
-- opens every choice in a list (the current one marked); the rest of the
-- button still cycles. One shared menu; it closes on a pick, a click
-- anywhere else, Escape, or when its button's window hides.
--   items() -> { { label, selected, pick = fn, tooltip } }
---------------------------------------------------------------------------
local MENU_ROWS = 16
local menu, catcher

local function CloseMenu()
    if menu then menu.owner = nil menu:Hide() end
    if catcher then catcher:Hide() end
end
Style.CloseDropdown = CloseMenu

local function BuildMenu()
    -- Clicks outside the menu close it (and are not passed on, as with the game's menus).
    catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("FULLSCREEN")
    catcher:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    catcher:SetScript("OnClick", CloseMenu)
    catcher:Hide()
    menu = CreateFrame("Frame", ns.FRAME .. "DropdownMenu", UIParent)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetClampedToScreen(true)
    menu:EnableMouse(true)
    Style.Surface(menu)
    menu.holder = CreateFrame("Frame", nil, menu)
    menu.holder:SetPoint("TOPLEFT", 3, -3)
    menu.holder:SetPoint("BOTTOMRIGHT", -3, 3)
    menu.list = Style.List(menu.holder, { fallbackRows = MENU_ROWS, onClick = function(item)
        CloseMenu()
        if item.pick then item.pick() end
    end })
    menu:SetScript("OnUpdate", function(self)
        if not self.owner or not self.owner:IsVisible() then CloseMenu() end
    end)
    menu:SetScript("OnHide", function() if catcher then catcher:Hide() end end)
    menu:Hide()
    if UISpecialFrames then table.insert(UISpecialFrames, ns.FRAME .. "DropdownMenu") end
end

function Style.OpenDropdown(owner, items)
    if not menu then BuildMenu() end
    if menu:IsShown() and menu.owner == owner then CloseMenu() return end
    local rows, selected = {}, 1
    for i, it in ipairs(items or {}) do
        rows[i] = { text = (it.selected and HEX.accent or "") .. tostring(it.label) .. (it.selected and "|r" or ""),
            accent = it.selected and COLORS.accent or nil, pick = it.pick, tooltip = it.tooltip and function(o) ns.Tooltip.Text(o, it.tooltip) end }
        if it.selected then selected = i end
    end
    if #rows == 0 then rows[1] = { text = HEX.muted .. "Nothing to choose.|r" } end
    local shown = math.min(#rows, MENU_ROWS)
    menu:SetSize(math.max(owner:GetWidth() or 160, 180), shown * Style.ROW + 6)
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -2)
    menu.owner = owner
    menu.list.visible = shown
    menu.list.offset = math.max(0, math.min(selected - math.floor(shown / 2), #rows - shown))
    catcher:Show()
    menu:Show()
    menu.list:SetItems(rows)
end

function Style.AttachDropdown(button, items)
    local arrow = CreateFrame("Button", nil, button)
    arrow:SetPoint("TOPRIGHT", -1, -1)
    arrow:SetPoint("BOTTOMRIGHT", -1, 1)
    arrow:SetWidth(18)
    arrow.sep = Texture(arrow, "ARTWORK", COLORS.border)
    arrow.sep:SetWidth(1)
    arrow.sep:SetPoint("TOPLEFT")
    arrow.sep:SetPoint("BOTTOMLEFT")
    arrow.hl = Texture(arrow, "HIGHLIGHT", { 1, 1, 1, 0.08 })
    arrow.hl:SetAllPoints()
    arrow.text = Text(arrow, "GameFontNormalSmall", "CENTER")
    arrow.text:SetPoint("CENTER", 1, 0)
    arrow.text:SetText("v")
    arrow:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    arrow:SetScript("OnClick", function() Style.OpenDropdown(button, items()) end)
    arrow:SetScript("OnEnter", function(self)
        button:SetBorderColor(COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.9)
        ns.Tooltip.Text(self, { "Choose from a list" })
    end)
    arrow:SetScript("OnLeave", function()
        local c = button.borderColor or COLORS.border
        button:SetBorderColor(c[1], c[2], c[3], c[4] or 1)
        ns.Tooltip.Hide()
    end)
    button.label:SetPoint("RIGHT", -22, 0)
    button.dropdown = arrow
    return arrow
end

-- Items from a list of { key, label } with the current key marked.
function Style.ChoiceItems(list, current, onPick, labelOf)
    local out = {}
    for _, c in ipairs(list) do
        out[#out + 1] = { label = labelOf and labelOf(c) or c.label, selected = c.key == current, pick = function() onPick(c.key, c) end }
    end
    return out
end
