-- TALOD - shared look: colors, surfaces, buttons, tabs, panels, lists
-- and windows, so the enemies panel, the character window and the HUD
-- pieces read as one addon. Plain textures only (no BackdropTemplate needed).
--
-- Two looks share every function: "ledger" (flat, square, the client's own
-- fonts, a glyph atlas) and "classic" (the look before it, kept as a setting).
-- A look is a table of values; Style.SetLook copies them into Style.COLORS,
-- Style.HEX and Style.M in place, so code that holds one of those tables sees
-- the new values. Frames already built keep the shapes they were built with.

local ADDON_NAME, ns = ...

local Style = {}
ns.Style = Style

local WHITE = "Interface\\Buttons\\WHITE8X8"
Style.WHITE = WHITE
Style.ROW = 20

---------------------------------------------------------------------------
-- Looks
---------------------------------------------------------------------------
local function H(hex, a)
    return { tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255, a or 1 }
end

-- Tokens: surfaces (window, rail, band, raise, well, hud, menu), lines (line,
-- lineStrong, edge), states (hover, selected), text tiers t1..t4, brand
-- (accent, brass), trade tones (good, bad, compare). Safety tones stay in
-- Core's ns.COLORS (colorblind aware). The keys after them are the names
-- older code uses, and the tints a few windows draw with.
local LEDGER = {
    window = H("0f1114", 0.96), rail = H("0a0b0d", 0.97), band = H("161a1f"), raise = H("15181c"),
    well = H("07080a"), hud = H("08090b", 0.84), menu = H("14171b"),
    line = { 1, 1, 1, 0.085 }, lineStrong = { 1, 1, 1, 0.17 }, edge = { 0, 0, 0, 1 },
    hover = { 1, 1, 1, 0.06 }, selected = { 1, 0.5, 0.25, 0.17 },
    t1 = H("f4f1ea"), t2 = H("cdd0d6"), t3 = H("9da2ac"), t4 = H("808692"),
    accent = H("ff8040"), accentHi = H("ffaa78"), onAccent = H("1b0e05"), brass = H("d4a638"),
    good = H("5fdc82"), bad = H("ff7070"), compare = H("5aa0ff"),
    -- Older names.
    titleBar = H("161a1f"), border = { 1, 1, 1, 0.17 }, card = H("15181c"), cardBorder = { 1, 1, 1, 0.085 },
    stripe = { 1, 1, 1, 0 }, button = H("1d2126"), bar = H("ff8040"), grid = { 1, 1, 1, 0.07 },
    text = H("f4f1ea"), muted = H("9da2ac"), brandBand = H("161a1f"), brandRule = H("d4a638", 0.45),
    -- Button states.
    buttonHover = H("272c33"), buttonDown = H("101215"), buttonOff = H("14161a"),
    -- Tints windows draw with.
    hoverRow = { 1, 1, 1, 0.06 }, hoverStrong = { 1, 1, 1, 0.1 }, tile = { 1, 1, 1, 0.035 }, navBg = { 1, 1, 1, 0.02 },
    cross = { 1, 1, 1, 0.25 }, focus = { 1, 1, 1, 1 }, track = { 1, 1, 1, 0.12 }, trackDim = { 1, 1, 1, 0.05 },
    shade = { 0, 0, 0, 0.7 }, clear = { 0, 0, 0, 0 }, iconFrame = { 0.3, 0.3, 0.3, 0.9 }, gridStrong = { 1, 1, 1, 0.2 },
    seriesGear = { 0.92, 0.41, 0.20 }, seriesTotal = H("5aa0ff"),
    hpBar = H("5fdc82"), auraBuff = { 0.35, 0.35, 0.35 }, auraDebuff = { 0.55, 0.05, 0.05 },
    -- Price graph: lowest = accent, usual = brass, your sales = compare, volume = white 13%.
    chartOver = H("ff7070"), chartUnder = H("ffd100"), chartBand = { 1, 0.5, 0.25, 0.22 }, chartUsual = H("d4a638", 0.7),
    chartListed = { 1, 1, 1, 0.13 }, chartSold = H("5aa0ff", 0.95),
}

-- The look before the ledger, value for value.
local CLASSIC = {
    window = { 0.055, 0.055, 0.06, 1 }, rail = { 0.055, 0.055, 0.06, 1 }, band = { 0.09, 0.09, 0.10, 1 },
    raise = { 1, 1, 1, 0.025 }, well = { 0.13, 0.13, 0.14, 1 }, hud = { 0.04, 0.04, 0.045, 0.82 },
    menu = { 0.055, 0.055, 0.06, 1 },
    line = { 1, 1, 1, 0.08 }, lineStrong = { 0.24, 0.24, 0.26, 1 }, edge = { 0.24, 0.24, 0.26, 1 },
    hover = { 1, 1, 1, 0.05 }, selected = { 1, 0.5, 0.25, 0.14 },
    t1 = { 1, 1, 1, 1 }, t2 = { 1, 1, 1, 1 }, t3 = { 0.62, 0.62, 0.62, 1 }, t4 = { 0.36, 0.36, 0.36, 1 },
    accent = { 1, 0.50, 0.25 }, accentHi = { 1, 0.67, 0.47 }, onAccent = { 0.1, 0.05, 0.02 }, brass = { 0.83, 0.65, 0.22 },
    good = { 0.25, 1, 0.25 }, bad = { 1, 0.31, 0.31 }, compare = { 0.35, 0.63, 1 },
    titleBar = { 0.09, 0.09, 0.10, 1 }, border = { 0.24, 0.24, 0.26, 1 }, card = { 1, 1, 1, 0.025 },
    cardBorder = { 1, 1, 1, 0.06 }, stripe = { 1, 1, 1, 0.03 }, button = { 0.13, 0.13, 0.14, 1 },
    bar = { 0.16, 0.47, 0.84 }, grid = { 1, 1, 1, 0.07 }, text = { 1, 1, 1 }, muted = { 0.62, 0.62, 0.62 },
    -- Brand header: lifts the shield's navy off the window; the rule is the art's gold.
    brandBand = { 0.12, 0.125, 0.145, 1 }, brandRule = { 0.83, 0.65, 0.22, 0.45 },
    buttonHover = { 0.13, 0.13, 0.14, 1 }, buttonDown = { 0.13, 0.13, 0.14, 1 }, buttonOff = { 0.13, 0.13, 0.14, 1 },
    hoverRow = { 1, 1, 1, 0.08 }, hoverStrong = { 1, 1, 1, 0.12 }, tile = { 1, 1, 1, 0.035 }, navBg = { 1, 1, 1, 0.02 },
    cross = { 1, 1, 1, 0.25 }, focus = { 1, 1, 1, 1 }, track = { 1, 1, 1, 0.12 }, trackDim = { 1, 1, 1, 0.05 },
    shade = { 0, 0, 0, 0.7 }, clear = { 0, 0, 0, 0 }, iconFrame = { 0.3, 0.3, 0.3, 0.9 }, gridStrong = { 1, 1, 1, 0.2 },
    seriesGear = { 0.92, 0.41, 0.20 }, seriesTotal = { 0.16, 0.47, 0.84 },
    hpBar = { 0.1, 0.8, 0.1 }, auraBuff = { 0.35, 0.35, 0.35 }, auraDebuff = { 0.55, 0.05, 0.05 },
    chartOver = { 1, 0.31, 0.31, 1 }, chartUnder = { 1, 0.82, 0, 1 }, chartBand = { 1, 0.5, 0.25, 0.22 },
    chartUsual = { 1, 1, 1, 0.18 }, chartListed = { 0.35, 0.55, 0.85, 0.6 }, chartSold = { 0.3, 0.85, 0.4, 0.95 },
}

local LEDGER_HEX = { accent = "|cffff8040", compare = "|cff5aa0ff", muted = "|cff9da2ac", dim = "|cff808692",
    gold = "|cffffd100", good = "|cff5fdc82", bad = "|cffff7070", source = "|cffc8b48c", white = "|cfff4f1ea",
    brass = "|cffd4a638", t1 = "|cfff4f1ea", t2 = "|cffcdd0d6", t3 = "|cff9da2ac", t4 = "|cff808692",
    chartOver = "|cffff7070", chartUnder = "|cffffd100", chartListed = "|cffc0c4cc", chartSold = "|cff5aa0ff" }
local CLASSIC_HEX = { accent = "|cffff8040", compare = "|cff5aa0ff", muted = "|cff8a8a8a", dim = "|cff5c5c5c",
    gold = "|cffffd100", good = "|cff40ff40", bad = "|cffff5050", source = "|cffc8b48c", white = "|cffffffff",
    brass = "|cffd4a638", t1 = "|cffffffff", t2 = "|cffffffff", t3 = "|cff8a8a8a", t4 = "|cff5c5c5c",
    chartOver = "|cffff5050", chartUnder = "|cffffd100", chartListed = "|cff5a8cd9", chartSold = "|cff4dd966" }

-- Measures that differ between the looks.
local LEDGER_M = { titleBar = 34, cardHeader = 26, tabWidth = nil, track = 6, thumbInset = 1, outerEdge = true,
    shadow = true, fonts = true, pixel = true, selectBar = true, stripes = false }
local CLASSIC_M = { titleBar = 38, cardHeader = 44, tabWidth = 96, track = 8, thumbInset = 2, outerEdge = false,
    shadow = false, fonts = false, pixel = false, selectBar = false, stripes = true }

Style.LOOKS = {
    ledger = { colors = LEDGER, hex = LEDGER_HEX, m = LEDGER_M },
    classic = { colors = CLASSIC, hex = CLASSIC_HEX, m = CLASSIC_M },
}

Style.COLORS, Style.HEX, Style.M = {}, {}, {}
local COLORS, HEX, M = Style.COLORS, Style.HEX, Style.M

-- Text roles. Ledger: the client's Friz Quadrata (titles) and its chat font
-- (Arial Narrow on Latin clients) read from the game's own font objects, so
-- every client language gets the fonts it ships. Classic: the old templates.
local ROLES = {
    title = { face = "title", size = 15, color = "t1" }, cardTitle = { face = "title", size = 13, color = "t1" },
    tab = { face = "body", size = 13, color = "t3" }, body = { face = "body", size = 12, color = "t2" },
    meta = { face = "body", size = 11, color = "t3" }, label = { face = "body", size = 10, color = "t4" },
    figure = { face = "body", size = 17, color = "t1" },
}
local CLASSIC_FONTS = { title = "GameFontNormalLarge", cardTitle = "GameFontNormal", tab = "GameFontNormal",
    body = "GameFontHighlightSmall", meta = "GameFontDisableSmall", label = "GameFontNormalSmall", figure = "GameFontNormalLarge" }
Style.FONTS = {}
local fontObjects

local function FontFile(names, fallback)
    for _, name in ipairs(names) do
        local o = _G[name]
        if o and o.GetFont then
            local ok, file = pcall(o.GetFont, o)
            if ok and type(file) == "string" and file ~= "" then return file end
        end
    end
    return fallback
end

-- Font objects, made once. nil when the client cannot make them (the
-- ledger then falls back to the classic templates).
local function MakeFonts()
    if fontObjects ~= nil then return fontObjects or nil end
    fontObjects = false
    if type(CreateFont) ~= "function" then return nil end
    local faces = {
        title = FontFile({ "GameFontNormal" }, "Fonts\\FRIZQT__.TTF"),
        body = FontFile({ "ChatFontNormal", "NumberFontNormal" }, STANDARD_TEXT_FONT or "Fonts\\ARIALN.TTF"),
    }
    local made = {}
    for role, r in pairs(ROLES) do
        local ok, font = pcall(CreateFont, ns.FRAME .. "Font_" .. role)
        if not ok or not font then return nil end
        made[role] = font
        font.face = faces[r.face]
    end
    fontObjects = made
    return made
end

-- Body text size (setting textSize: 11 / 12 / 13); meta follows it.
local function SizeOf(role)
    local body = Style.textSize or 12
    if role == "body" then return body end
    if role == "meta" then return body - 1 end
    return ROLES[role].size
end

local function ApplyFonts()
    local objects = M.fonts and MakeFonts()
    for role, r in pairs(ROLES) do
        local font = objects and objects[role]
        if font then
            pcall(font.SetFont, font, font.face, SizeOf(role), "")
            local c = COLORS[r.color]
            if font.SetTextColor then font:SetTextColor(c[1], c[2], c[3], 1) end
            if font.SetShadowColor then font:SetShadowColor(0, 0, 0, 0.85) end
            if font.SetShadowOffset then font:SetShadowOffset(1, -1) end
            Style.FONTS[role] = font
        else
            Style.FONTS[role] = CLASSIC_FONTS[role]
        end
    end
end

-- The font for a role or a template name: a font object or a template name
-- (both go to SetFontObject).
function Style.Font(roleOrTemplate)
    return Style.FONTS[roleOrTemplate] or roleOrTemplate
end

local function CopyInto(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            local t = dst[k]
            if type(t) ~= "table" then t = {} dst[k] = t end
            t[1], t[2], t[3], t[4] = v[1], v[2], v[3], v[4]
        else
            dst[k] = v
        end
    end
    for k in pairs(dst) do if src[k] == nil then dst[k] = nil end end
end

-- Colours that follow the colorblind setting (Core's palettes).
function Style.RefreshTones()
    HEX.unknown = ns.ColorCode and ns.ColorCode("unknown") or "|cffb9a0ff"
end

local lookName
function Style.SetLook(name)
    local look = Style.LOOKS[name] or Style.LOOKS.ledger
    lookName = Style.LOOKS[name] and name or "ledger"
    CopyInto(COLORS, look.colors)
    CopyInto(HEX, look.hex)
    CopyInto(M, look.m)
    Style.RefreshTones()
    ApplyFonts()
    return lookName
end

function Style.Look() return lookName end
function Style.IsLedger() return lookName == "ledger" end

-- The saved settings that shape the look: classicLook, textSize, compactRows.
-- Main runs it before any window is built; a change later reaches windows
-- built after it (the rest after a /reload).
function Style.ApplySettings()
    local d = ns.DB and ns.DB()
    local size = d and tonumber(d.textSize) or 12
    Style.textSize = (size == 11 or size == 13) and size or 12
    Style.ROW = (d and d.compactRows) and 18 or 20
    Style.SetLook(d and d.classicLook and "classic" or "ledger")
end

Style.SetLook("ledger")

---------------------------------------------------------------------------
-- Media: three texture files. A /reload does not make the game see files
-- added since it started, so they may be missing until a full restart:
-- every part that uses them has a plain fallback.
---------------------------------------------------------------------------
Style.MEDIA = {
    glyphs = ns.MEDIA .. "Glyphs.tga",
    hatch = ns.MEDIA .. "Hatch.tga",
    shadow = ns.MEDIA .. "Shadow.tga",
}
local mediaOK

-- True when the client loaded the texture files. Asked once; any doubt
-- counts as missing (a missing file draws as a green box).
function Style.HasMedia()
    if mediaOK ~= nil then return mediaOK end
    mediaOK = false
    local ok, result = pcall(function()
        local f = CreateFrame("Frame", nil, UIParent)
        f:Hide()
        local t = f:CreateTexture(nil, "BACKGROUND")
        for _, path in pairs(Style.MEDIA) do
            local set, loaded = pcall(t.SetTexture, t, path)
            if not set or loaded ~= true then return false end
        end
        return true
    end)
    mediaOK = ok and result == true
    return mediaOK
end

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

-- A line one screen pixel thick at any UI scale (ledger), else 1 unit.
local function Thin(t, horizontal)
    local P = M.pixel and PixelUtil
    if horizontal then
        if P and P.SetHeight and pcall(P.SetHeight, t, 1, 1) then return end
        t:SetHeight(1)
    else
        if P and P.SetWidth and pcall(P.SetWidth, t, 1, 1) then return end
        t:SetWidth(1)
    end
end
Style.Thin = Thin

-- 1 px border; frame:SetBorderColor(r, g, b, a) recolors it.
function Style.Border(f, c)
    local edges = {}
    for i, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local t = Texture(f, "BORDER", c)
        if side == "TOP" or side == "BOTTOM" then
            Thin(t, true)
            t:SetPoint(side .. "LEFT")
            t:SetPoint(side .. "RIGHT")
        else
            Thin(t, false)
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

-- A black line just outside the frame: frames over the world and over each
-- other stay apart on snow and at night.
local function OuterEdge(f)
    local e = {}
    -- { own point, frame point, x } twice, then horizontal or not.
    for i, def in ipairs({
        { "BOTTOMLEFT", "TOPLEFT", -1, "BOTTOMRIGHT", "TOPRIGHT", 1, true },
        { "TOPLEFT", "BOTTOMLEFT", -1, "TOPRIGHT", "BOTTOMRIGHT", 1, true },
        { "TOPRIGHT", "TOPLEFT", 0, "BOTTOMRIGHT", "BOTTOMLEFT", 0, false },
        { "TOPLEFT", "TOPRIGHT", 0, "BOTTOMLEFT", "BOTTOMRIGHT", 0, false } }) do
        local t = Texture(f, "BACKGROUND", COLORS.edge)
        t:SetDrawLayer("BACKGROUND", -8)
        t:SetPoint(def[1], f, def[2], def[3], 0)
        t:SetPoint(def[4], f, def[5], def[6], 0)
        Thin(t, def[7])
        e[i] = t
    end
    return e
end

-- A soft shadow under a window, nine pieces of Shadow.tga (corners keep
-- their size, edges stretch). Skipped without the file.
local SHADOW_PAD, SHADOW_CUT = 12, 0.25
local function Shadow(f)
    if not Style.HasMedia() then return nil end
    local parts = {}
    local cuts = { 0, SHADOW_CUT, 1 - SHADOW_CUT, 1 }
    local P = SHADOW_PAD
    for row = 1, 3 do
        for col = 1, 3 do
            local t = f:CreateTexture(nil, "BACKGROUND")
            t:SetDrawLayer("BACKGROUND", -8)
            t:SetTexture(Style.MEDIA.shadow)
            t:SetTexCoord(cuts[col], cuts[col + 1], cuts[row], cuts[row + 1])
            if col ~= 2 then t:SetWidth(2 * P) end
            if row ~= 2 then t:SetHeight(2 * P) end
            local h = col == 1 and "LEFT" or (col == 3 and "RIGHT" or nil)
            local v = row == 1 and "TOP" or (row == 3 and "BOTTOM" or nil)
            if h and v then
                t:SetPoint((v .. h), f, (v .. h), h == "LEFT" and -P or P, v == "TOP" and P or -P)
            elseif v then
                t:SetPoint(v .. "LEFT", f, v .. "LEFT", P, v == "TOP" and P or -P)
                t:SetPoint(v .. "RIGHT", f, v .. "RIGHT", -P, v == "TOP" and P or -P)
            elseif h then
                t:SetPoint("TOP" .. h, f, "TOP" .. h, h == "LEFT" and -P or P, -P)
                t:SetPoint("BOTTOM" .. h, f, "BOTTOM" .. h, h == "LEFT" and -P or P, P)
            else
                t:SetPoint("TOPLEFT", f, "TOPLEFT", P, -P)
                t:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -P, P)
            end
            parts[#parts + 1] = t
        end
    end
    return parts
end

-- Flat background + border on any frame. kind: "window" (default), "hud"
-- (more see-through, for things over the game world) or "menu" (tooltips,
-- menus, Go to). Ledger adds a black outer edge, and a shadow to windows.
function Style.Surface(f, kind)
    kind = kind or "window"
    if not M.outerEdge then
        f.surface = Texture(f, "BACKGROUND", kind == "hud" and COLORS.hud or COLORS.window)
        f.surface:SetAllPoints()
        Style.Border(f, COLORS.border)
        return f
    end
    f.surface = Texture(f, "BACKGROUND", COLORS[kind] or COLORS.window)
    f.surface:SetAllPoints()
    Style.Border(f, kind == "hud" and COLORS.line or COLORS.line)
    f.outerEdge = OuterEdge(f)
    if kind == "window" or kind == "menu" then f.shadow = Shadow(f) end
    return f
end

-- A font string. roleOrTemplate: a text role (title, cardTitle, tab, body,
-- meta, label, figure), a game font template, or a font object.
function Style.Text(parent, roleOrTemplate, justify)
    local font = type(roleOrTemplate) == "table" and roleOrTemplate or Style.FONTS[roleOrTemplate]
    local fs
    if font and type(font) ~= "string" then
        fs = parent:CreateFontString(nil, "ARTWORK")
        fs:SetFontObject(font)
    else
        fs = parent:CreateFontString(nil, "ARTWORK", font or roleOrTemplate or "GameFontHighlightSmall")
    end
    fs:SetJustifyH(justify or "LEFT")
    if fs.SetWordWrap then fs:SetWordWrap(false) end
    return fs
end
local Text = Style.Text

function Style.HLine(parent, c)
    local t = Texture(parent, "ARTWORK", c or COLORS.line)
    Thin(t, true)
    return t
end

---------------------------------------------------------------------------
-- Tones: a name → a colour. Safety tones (safe, threshold, danger, unknown)
-- come from Core and follow the colorblind setting; the rest are tokens.
---------------------------------------------------------------------------
local SAFETY = { safe = true, threshold = true, danger = true, unknown = true }
local CB_TRADE = { good = { 0.62, 0.85, 1 }, bad = { 1, 0.72, 0.44 } }
Style.SAFETY_TONES = SAFETY

function Style.ToneColor(tone)
    if type(tone) == "table" then return tone end
    if SAFETY[tone] then return ns.GetColor(tone) end
    if (tone == "good" or tone == "bad") and lookName == "ledger" and ns.DB and ns.DB() and ns.DB().colorblind then
        return CB_TRADE[tone]
    end
    if tone == "plain" or tone == nil then return COLORS.t2 end
    if tone == "muted" then return COLORS.t3 end
    if tone == "gold" then return { 1, 0.82, 0 } end
    return COLORS[tone] or COLORS.t2
end

function Style.ToneHex(tone)
    if SAFETY[tone] then return ns.ColorCode(tone) end
    local c = Style.ToneColor(tone)
    return ns.Hex(c)
end

---------------------------------------------------------------------------
-- Glyphs: white icons on one atlas (Glyphs.tga, 8 x 4 cells of 32), tinted.
-- Without the file: page icons fall back to the game's icons, controls and
-- shapes to a text symbol, or nothing where they only decorate.
---------------------------------------------------------------------------
Style.GLYPHS = { "home", "swords", "fish", "people", "armor", "anvil", "coins", "gavel",
    "horn", "banner", "scale", "gear", "info", "search", "lock", "unlock",
    "bell", "belloff", "close", "chevronright", "chevrondown", "send", "copy", "reset",
    "check", "circle", "triangle", "diamond" }
local GLYPH_CELL = {}
for i, name in ipairs(Style.GLYPHS) do GLYPH_CELL[name] = i - 1 end

local GLYPH_ICON = {
    home = "Interface\\Icons\\INV_Misc_Map_01", swords = "Interface\\Icons\\Ability_DualWield",
    fish = "Interface\\Icons\\Trade_Fishing", people = "Interface\\Icons\\Ability_Warrior_BattleShout",
    armor = "Interface\\Icons\\INV_Chest_Chain", anvil = "Interface\\Icons\\Trade_BlackSmithing",
    coins = "Interface\\Icons\\INV_Misc_Coin_01", gavel = "Interface\\Icons\\INV_Misc_Coin_02",
    horn = "Interface\\Icons\\INV_Misc_Horn_01", banner = "Interface\\Icons\\INV_Banner_02",
    scale = "Interface\\Icons\\INV_Misc_Spyglass_02", gear = "Interface\\Icons\\INV_Misc_Gear_01",
    info = "Interface\\Icons\\INV_Misc_Note_01",
}
local GLYPH_TEXT = {
    search = "?", lock = "L", unlock = "U", bell = "!", belloff = "-", close = "x", chevronright = ">",
    chevrondown = "v", send = ">", copy = "c", reset = "r", check = "+", circle = "o", triangle = "^", diamond = "<>",
}
Style.GLYPH_TEXT = GLYPH_TEXT

local function GlyphCoords(name)
    local i = GLYPH_CELL[name] or 0
    local col, row = i % 8, math.floor(i / 8)
    return col / 8, (col + 1) / 8, row / 4, (row + 1) / 4
end

-- A glyph region: g:SetGlyph(name), g:SetTone(tone). Returns a texture, or
-- a font string where the atlas is missing (same two methods).
function Style.Glyph(parent, name, size, tone, layer)
    size = size or 14
    local g
    if Style.HasMedia() then
        g = parent:CreateTexture(nil, layer or "ARTWORK")
        g:SetSize(size, size)
        function g:SetGlyph(n)
            self.glyph = n
            self:SetTexture(Style.MEDIA.glyphs)
            self:SetTexCoord(GlyphCoords(n))
        end
        function g:SetTone(t)
            self.tone = t
            local c = Style.ToneColor(t or "t2")
            self:SetVertexColor(c[1], c[2], c[3], c[4] or 1)
        end
    else
        local holder = parent:CreateTexture(nil, layer or "ARTWORK")
        holder:SetSize(size, size)
        g = holder
        g.fallbackText = Text(parent, "body", "CENTER")
        g.fallbackText:SetPoint("CENTER", holder, "CENTER")
        g.fallback = true
        local show, hide = holder.Show, holder.Hide
        function g:Show() show(self) self.fallbackText:Show() end
        function g:Hide() hide(self) self.fallbackText:Hide() end
        function g:SetShown(on) if on then self:Show() else self:Hide() end end
        function g:SetGlyph(n)
            self.glyph = n
            local icon = GLYPH_ICON[n]
            if icon then
                self:SetTexture(icon)
                self:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                self:SetAlpha(1)
                self.fallbackText:SetText("")
            else
                self:SetAlpha(0)
                self.fallbackText:SetText(GLYPH_TEXT[n] or "")
            end
        end
        function g:SetTone(t)
            self.tone = t
            local c = Style.ToneColor(t or "t2")
            self.fallbackText:SetTextColor(c[1], c[2], c[3], 1)
        end
    end
    g:SetGlyph(name)
    g:SetTone(tone)
    return g
end

-- The unknown fill: Hatch.tga tiled in the unknown tone, or without the
-- file a faint solid fill in that tone (the "?" beside it carries it).
function Style.Hatch(region, alpha)
    local c = ns.GetColor("unknown")
    if Style.HasMedia() then
        region:SetTexture(Style.MEDIA.hatch, "REPEAT", "REPEAT")
        if region.SetHorizTile then region:SetHorizTile(true) end
        if region.SetVertTile then region:SetVertTile(true) end
        region:SetVertexColor(c[1], c[2], c[3], alpha or 0.45)
        region.hatched = true
    else
        region:SetColorTexture(c[1], c[2], c[3], (alpha or 0.45) * 0.5)
        region.hatched = false
    end
    return region
end

---------------------------------------------------------------------------
-- Tag: a small label with a tone and a shape, so it reads without colour.
--   local tag = Style.Tag(parent); tag:Set(text, tone, shape)
-- tones: safe threshold danger unknown good bad compare accent plain;
-- shape: a glyph name, false for none, nil for the tone's own (safe =
-- circle, threshold = triangle, danger = diamond). Unknown is always the
-- hatch, a violet edge and "?".
---------------------------------------------------------------------------
local TONE_SHAPE = { safe = "circle", threshold = "triangle", danger = "diamond" }
local TAG_FILL = { safe = 0.16, threshold = 0.16, danger = 0.22, good = 0.15, bad = 0.15, compare = 0.17 }
local TAG_H = 15

function Style.Tag(parent)
    local tag = CreateFrame("Frame", nil, parent)
    tag:SetHeight(TAG_H)
    tag.bg = Texture(tag, "BACKGROUND")
    tag.bg:SetAllPoints()
    tag.text = Text(tag, "meta")
    tag.text:SetPoint("LEFT", 5, 0)
    function tag:Set(text, tone, shape)
        text = text ~= nil and tostring(text) or ""
        tone = tone or "plain"
        self.value, self.tone = text, tone
        local c = Style.ToneColor(tone)
        if shape == nil then shape = TONE_SHAPE[tone] end
        if tone == "unknown" then
            shape = false
            Style.Hatch(self.bg, 0.5)
            if not self.edges then self.edges = Style.Border(self, c) end
            for _, e in ipairs(self.edges) do e:Show() end
            self:SetBorderColor(c[1], c[2], c[3], 0.6)
            text = (text == "" or text == "?") and "?" or ("? " .. text)
        else
            if self.edges then for _, e in ipairs(self.edges) do e:Hide() end end
            if tone == "accent" then Fill(self.bg, COLORS.accent)
            elseif tone == "plain" then self.bg:SetColorTexture(1, 1, 1, 0.09)
            else self.bg:SetColorTexture(c[1], c[2], c[3], TAG_FILL[tone] or 0.16) end
        end
        local glyph = shape and Style.HasMedia() and shape
        if glyph then
            if not self.shape then self.shape = Style.Glyph(self, glyph, 7) self.shape:SetPoint("LEFT", 5, 0) end
            self.shape:SetGlyph(glyph)
            self.shape:SetTone(c)
            self.shape:Show()
        elseif self.shape then
            self.shape:Hide()
        end
        local tc = tone == "accent" and COLORS.onAccent or c
        self.text:SetTextColor(tc[1], tc[2], tc[3], 1)
        self.text:ClearAllPoints()
        self.text:SetPoint("LEFT", glyph and 16 or 5, 0)
        self.text:SetText(text)
        self.shown = text
        local w = (self.text:GetStringWidth() or 0) + 10 + (glyph and 11 or 0)
        self:SetWidth(math.max(TAG_H, math.floor(w + 0.5)))
        return self
    end
    function tag:GetText() return self.shown end
    return tag
end

-- A tag's colour code and text for inline strings ("?" in the unknown tone
-- and the like) where a frame does not fit.
function Style.TagText(text, tone)
    if tone == "unknown" then
        text = (text == nil or text == "" or text == "?") and "?" or ("? " .. tostring(text))
    end
    return Style.ToneHex(tone) .. tostring(text or "") .. "|r"
end

---------------------------------------------------------------------------
-- Controls
---------------------------------------------------------------------------
-- A method of the widget type itself (a button's own SetEnabled), past any
-- field of the same name on the frame.
local function Native(self, method)
    local mt = getmetatable(self)
    local idx = mt and mt.__index
    if type(idx) == "table" then return idx[method] end
    if type(idx) == "function" then return idx(self, method) end
    return nil
end

-- Flat button: dark fill, hairline border that lights up on hover. Text
-- buttons by default; opts.icon makes a square icon button.
--   opts.kind: "primary" (accent fill), "danger" (warning colours; the label
--   ends in "..." and the click asks first), "send" (sends something to the
--   game or another player: an arrow and an accent edge, always);
--   opts.small (18 high), opts.glyph (a glyph before the label), opts.height,
--   opts.title (tooltip title).
--   b:SetOn(bool) marks it on; b:SetEnabled(bool, why): off buttons do not
--   click, and the tooltip says why; b:SetKind(kind).
function Style.Button(parent, text, width, onClick, tooltip, opts)
    opts = opts or {}
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width, opts.height or (opts.small and 18) or 22)
    b.kind, b.enabled, b.on = opts.kind, true, false
    b.bg = Texture(b, "BACKGROUND", COLORS.button)
    b.bg:SetAllPoints()
    Style.Border(b, COLORS.border)
    if opts.icon then
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetPoint("TOPLEFT", 3, -3)
        b.icon:SetPoint("BOTTOMRIGHT", -3, 3)
        b.icon:SetTexture(opts.icon)
    end
    local ledger = lookName == "ledger"
    b.label = Text(b, ledger and Style.FONTS.body or "GameFontNormalSmall", "CENTER")
    if ledger and opts.small then b.label:SetFontObject(Style.FONTS.meta) end
    b.label:SetPoint("LEFT", 6, 0)
    b.label:SetPoint("RIGHT", -6, 0)
    b.label:SetText(text or "")
    local glyph = opts.glyph or (opts.kind == "send" and "send") or nil
    if glyph then
        b.glyph = Style.Glyph(b, glyph, opts.small and 10 or 12, "t2")
        b.glyph:SetPoint("LEFT", 6, 0)
        b.label:SetPoint("LEFT", (opts.small and 10 or 12) + 9, 0)
    end

    -- One paint for every state: kind, on, enabled, hover, pressed.
    function b:Paint()
        local fill, edge, tc, ea = COLORS.button, self.borderColor or COLORS.border, nil, nil
        if not self.enabled then
            fill, edge, tc = COLORS.buttonOff, COLORS.line, COLORS.t4
        elseif self.kind == "primary" then
            fill, edge, tc = self.hover and COLORS.accentHi or COLORS.accent, self.hover and COLORS.accentHi or COLORS.accent, COLORS.onAccent
        else
            if self.on then fill, edge = COLORS.selected, COLORS.accent end
            if self.kind == "send" then edge = COLORS.accent end
            if self.kind == "danger" then tc, edge, ea = COLORS.bad, COLORS.bad, 0.5 end
            if self.hover then
                if not self.on then fill = COLORS.buttonHover end
                edge, ea = COLORS.accent, 0.9
            end
            if self.down then fill = COLORS.buttonDown end
        end
        Fill(self.bg, fill)
        self:SetBorderColor(edge[1], edge[2], edge[3], ea or edge[4] or 1)
        if tc then self.label:SetTextColor(tc[1], tc[2], tc[3], 1)
        elseif lookName == "ledger" then self.label:SetTextColor(COLORS.t1[1], COLORS.t1[2], COLORS.t1[3], 1)
        elseif self.painted then self.label:SetTextColor(1, 0.82, 0, 1) end
        if self.glyph then
            self.glyph:SetTone(not self.enabled and "t4" or (self.kind == "primary" and COLORS.onAccent)
                or ((self.kind == "send" or self.on) and "accent") or "t2")
        end
        self.painted = true
    end

    function b:SetOn(on)
        self.on = on and true or false
        self.borderColor = self.on and COLORS.accent or nil
        self:Paint()
    end
    function b:SetKind(kind)
        if self.kind == kind then return end
        self.kind = kind
        if kind == "send" and not self.glyph then
            self.glyph = Style.Glyph(self, "send", 12, "accent")
            self.glyph:SetPoint("LEFT", 6, 0)
            self.label:SetPoint("LEFT", 21, 0)
        end
        if self.glyph and not opts.glyph then self.glyph:SetShown(kind == "send") end
        self:Paint()
    end
    local nativeEnabled = Native(b, "SetEnabled")
    function b:SetEnabled(on, why)
        self.enabled = on and true or false
        self.why = (not self.enabled) and why or nil
        if nativeEnabled then pcall(nativeEnabled, self, self.enabled) end
        self:Paint()
    end
    function b:IsEnabled() return self.enabled end

    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", onClick)
    b:SetScript("OnMouseDown", function(self)
        if not self.enabled or lookName ~= "ledger" then return end
        self.down = true
        self.label:SetPoint("LEFT", (self.glyph and 21 or 6), -1)
        self:Paint()
    end)
    b:SetScript("OnMouseUp", function(self)
        if not self.down then return end
        self.down = false
        self.label:SetPoint("LEFT", (self.glyph and 21 or 6), 0)
        self:Paint()
    end)
    b:SetScript("OnEnter", function(self)
        self.hover = true
        if lookName == "ledger" or self.kind or not self.enabled then self:Paint()
        else self:SetBorderColor(COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.9) end
        local tip = type(tooltip) == "function" and tooltip() or tooltip
        local why = not self.enabled and self.why
        if tip or why then
            local title = opts.title or ((self.label:GetText() or ""):gsub("%s*>$", ""))
            local lines = {}
            if type(tip) == "table" then
                -- Several lines: the title, then each line in turn.
                lines[1] = title ~= "" and title or nil
                for _, line in ipairs(tip) do lines[#lines + 1] = line end
            elseif tip then
                lines = { title ~= "" and title or tip, title ~= "" and tip or nil }
            else
                lines = { title ~= "" and title or nil }
            end
            if why then lines[#lines + 1] = HEX.bad .. "Not now: " .. why .. "|r" end
            ns.Tooltip.Text(self, lines)
        end
    end)
    b:SetScript("OnLeave", function(self)
        self.hover = false
        if self.down then
            self.down = false
            self.label:SetPoint("LEFT", (self.glyph and 21 or 6), 0)
        end
        if lookName == "ledger" or self.kind or not self.enabled then self:Paint()
        else
            local c = self.borderColor or COLORS.border
            self:SetBorderColor(c[1], c[2], c[3], c[4] or 1)
        end
        ns.Tooltip.Hide()
    end)
    b.SetLabel = function(self, t) self.label:SetText(t) end
    if lookName == "ledger" or opts.kind then b:Paint() end
    return b
end

-- An icon button: a glyph, no border, a hover fill (22, or 18 with small).
-- b:SetOn(bool) lights it in the accent; opts.offTone colours it when off
-- (the threshold tone for a mute).
function Style.IconButton(parent, glyph, onClick, tooltip, opts)
    opts = opts or {}
    local size = opts.small and 18 or 22
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size, size)
    b.hl = Texture(b, "HIGHLIGHT", COLORS.hover)
    b.hl:SetAllPoints()
    b.glyph = Style.Glyph(b, glyph, opts.small and 12 or 14, "t3")
    b.glyph:SetPoint("CENTER")
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", onClick)
    function b:SetOn(on, offTone)
        self.on = on
        self.glyph:SetTone(on and "accent" or (offTone or opts.offTone or "t3"))
    end
    function b:SetGlyph(name) self.glyph:SetGlyph(name) end
    b:SetScript("OnEnter", function(self)
        local tip = type(tooltip) == "function" and tooltip() or tooltip
        if type(tip) == "table" then ns.Tooltip.Text(self, tip) elseif tip then ns.Tooltip.Text(self, { tip }) end
    end)
    b:SetScript("OnLeave", function() ns.Tooltip.Hide() end)
    return b
end

-- Tab row: text with an accent underline on the selected tab.
-- defs = { { key, label } }; returns tabs with tabs:Select(key) and
-- tabs:SetTag(key, text, tone) (a tag after the label; nil text removes it).
-- Width: each tab as wide as its label (ledger) or 96 (classic) when width
-- is nil.
function Style.Tabs(parent, defs, onSelect, width)
    local tabs = {}
    local ledger = lookName == "ledger"
    local fixed = width or M.tabWidth
    for i, def in ipairs(defs) do
        local b = CreateFrame("Button", nil, parent)
        b:SetHeight(26)
        b.text = Text(b, ledger and "tab" or "GameFontNormal", "CENTER")
        b.text:SetText(def.label)
        b.line = Texture(b, "ARTWORK", COLORS.accent)
        b.line:SetHeight(2)
        b.line:SetPoint("BOTTOMLEFT", ledger and 6 or 8, 0)
        b.line:SetPoint("BOTTOMRIGHT", ledger and -6 or -8, 0)
        b.hl = Texture(b, "HIGHLIGHT", ledger and COLORS.hover or { 1, 1, 1, 0.05 })
        b.hl:SetAllPoints()
        b:SetScript("OnClick", function() onSelect(def.key) end)
        b.key = def.key
        tabs[i] = b
    end
    local function Width(b)
        if fixed then return fixed end
        local w = math.max(40, b.text:GetStringWidth() or 60) + 20
        if b.tag and b.tag:IsShown() then w = w + (b.tag:GetWidth() or 0) + 6 end
        return math.floor(w + 0.5)
    end
    function tabs:Layout()
        local x = 0
        for _, b in ipairs(self) do
            local w = Width(b)
            b:SetWidth(w)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", x, 0)
            b.text:ClearAllPoints()
            if b.tag and b.tag:IsShown() then
                b.text:SetPoint("LEFT", 10, 0)
                b.tag:ClearAllPoints()
                b.tag:SetPoint("LEFT", b.text, "RIGHT", 6, 0)
            else
                b.text:SetAllPoints()
            end
            x = x + w + (ledger and 2 or 4)
        end
        self.width = x
    end
    function tabs:Select(key)
        self.selected = key
        for _, b in ipairs(self) do
            local selected = b.key == key
            b.line:SetShown(selected)
            if ledger then
                local c = selected and COLORS.t1 or COLORS.t3
                b.text:SetTextColor(c[1], c[2], c[3])
            else
                b.text:SetTextColor(selected and 1 or 0.62, selected and 0.82 or 0.62, selected and 0.55 or 0.62)
            end
        end
    end
    function tabs:SetTag(key, text, tone)
        for _, b in ipairs(self) do
            if b.key == key then
                if text == nil or text == "" then
                    if b.tag then b.tag:Hide() end
                else
                    b.tag = b.tag or Style.Tag(b)
                    b.tag:Set(text, tone)
                    b.tag:Show()
                end
            end
        end
        self:Layout()
    end
    tabs:Layout()
    return tabs
end

-- A view switch: joined buttons (the right end of a tab bar), one selected.
-- defs = { { key, label } }; returns a frame with :Select(key).
function Style.Views(parent, defs, onSelect)
    local v = CreateFrame("Frame", nil, parent)
    v:SetHeight(20)
    Style.Border(v, COLORS.lineStrong)
    v.buttons = {}
    local x = 0
    for i, def in ipairs(defs) do
        local b = CreateFrame("Button", nil, v)
        b:SetHeight(20)
        b.bg = Texture(b, "BACKGROUND", COLORS.clear)
        b.bg:SetAllPoints()
        b.hl = Texture(b, "HIGHLIGHT", COLORS.hover)
        b.hl:SetAllPoints()
        b.text = Text(b, "body", "CENTER")
        b.text:SetAllPoints()
        b.text:SetText(def.label)
        local w = math.floor((b.text:GetStringWidth() or 40) + 16.5)
        b:SetWidth(w)
        b:SetPoint("TOPLEFT", x, 0)
        if i > 1 then
            local sep = Texture(v, "BORDER", COLORS.lineStrong)
            sep:SetPoint("TOPLEFT", x, 0)
            sep:SetPoint("BOTTOMLEFT", x, 0)
            Thin(sep, false)
        end
        x = x + w
        b.key = def.key
        b:SetScript("OnClick", function() v:Select(def.key) if onSelect then onSelect(def.key) end end)
        v.buttons[i] = b
    end
    v:SetWidth(math.max(1, x))
    function v:Select(key)
        self.selected = key
        for _, b in ipairs(self.buttons) do
            local on = b.key == key
            Fill(b.bg, on and COLORS.selected or COLORS.clear)
            local c = on and COLORS.t1 or COLORS.t3
            b.text:SetTextColor(c[1], c[2], c[3])
        end
    end
    return v
end

-- Filter chips: toggle buttons with a count. defs = { { key, label } };
-- onToggle(key, on). :Select(key) turns that one on and the rest off;
-- :SetOn(key, on) for one; :SetCount(key, n) (nil hides the count).
function Style.Chips(parent, defs, onToggle)
    local c = CreateFrame("Frame", nil, parent)
    c:SetHeight(20)
    c.chips = {}
    local function Paint(b)
        Fill(b.bg, b.on and COLORS.selected or COLORS.clear)
        local e = b.on and COLORS.accent or COLORS.lineStrong
        b:SetBorderColor(e[1], e[2], e[3], e[4] or 1)
        local t = b.on and COLORS.t1 or COLORS.t3
        b.text:SetTextColor(t[1], t[2], t[3])
    end
    for i, def in ipairs(defs) do
        local b = CreateFrame("Button", nil, c)
        b:SetHeight(20)
        b.bg = Texture(b, "BACKGROUND", COLORS.clear)
        b.bg:SetAllPoints()
        b.hl = Texture(b, "HIGHLIGHT", COLORS.hover)
        b.hl:SetAllPoints()
        Style.Border(b, COLORS.lineStrong)
        b.text = Text(b, "body")
        b.text:SetPoint("LEFT", 7, 0)
        b.text:SetText(def.label)
        b.count = Text(b, "meta")
        b.count:SetPoint("LEFT", b.text, "RIGHT", 5, 0)
        b.key, b.on = def.key, false
        b:SetScript("OnClick", function(self)
            self.on = not self.on
            Paint(self)
            if onToggle then onToggle(self.key, self.on) end
        end)
        c.chips[i] = b
        Paint(b)
    end
    function c:Layout()
        local x = 0
        for _, b in ipairs(self.chips) do
            local w = (b.text:GetStringWidth() or 40) + 14
            if (b.count:GetText() or "") ~= "" then w = w + (b.count:GetStringWidth() or 10) + 5 end
            w = math.floor(w + 0.5)
            b:SetWidth(w)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", x, 0)
            x = x + w + 4
        end
        self:SetWidth(math.max(1, x - 4))
    end
    function c:SetOn(key, on)
        for _, b in ipairs(self.chips) do if b.key == key then b.on = on and true or false Paint(b) end end
    end
    function c:Select(key)
        for _, b in ipairs(self.chips) do b.on = b.key == key Paint(b) end
    end
    function c:IsOn(key)
        for _, b in ipairs(self.chips) do if b.key == key then return b.on end end
        return false
    end
    function c:SetCount(key, n)
        for _, b in ipairs(self.chips) do if b.key == key then b.count:SetText(n ~= nil and tostring(n) or "") end end
        self:Layout()
    end
    c:Layout()
    return c
end

-- An on-screen switch (show / hide something on screen): 26 x 13, a knob
-- that moves. onToggle(on, sw) after a click; sw:SetOn(bool) sets it
-- without calling onToggle.
function Style.Switch(parent, onToggle, tooltip)
    local sw = CreateFrame("Button", nil, parent)
    sw:SetSize(26, 13)
    sw.bg = Texture(sw, "BACKGROUND", COLORS.well)
    sw.bg:SetAllPoints()
    Style.Border(sw, COLORS.lineStrong)
    sw.knob = Texture(sw, "ARTWORK", COLORS.t4)
    sw.knob:SetSize(9, 9)
    function sw:SetOn(on)
        self.on = on and true or false
        if self.on then
            Fill(self.bg, COLORS.accent, 0.3)
            self:SetBorderColor(COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 1)
            Fill(self.knob, COLORS.accent)
        else
            Fill(self.bg, COLORS.well)
            self:SetBorderColor(COLORS.lineStrong[1], COLORS.lineStrong[2], COLORS.lineStrong[3], COLORS.lineStrong[4])
            Fill(self.knob, COLORS.t4)
        end
        self.knob:ClearAllPoints()
        self.knob:SetPoint("LEFT", self.on and 15 or 2, 0)
    end
    function sw:GetOn() return self.on end
    sw:SetScript("OnClick", function(self)
        self:SetOn(not self.on)
        if onToggle then onToggle(self.on, self) end
    end)
    if tooltip then
        sw:SetScript("OnEnter", function(self)
            local tip = type(tooltip) == "function" and tooltip() or tooltip
            if tip then ns.Tooltip.Text(self, type(tip) == "table" and tip or { tip }) end
        end)
        sw:SetScript("OnLeave", function() ns.Tooltip.Hide() end)
    end
    sw:SetOn(false)
    return sw
end

-- A two-texture bar (share, progress). meter:SetValue(value, max, tone);
-- meter:SetUnknown() shows the unknown fill over the whole bar.
function Style.Meter(parent, height)
    local m = CreateFrame("Frame", nil, parent)
    m:SetHeight(height or 5)
    m.bg = Texture(m, "BACKGROUND", COLORS.well)
    m.bg:SetAllPoints()
    Style.Border(m, COLORS.line)
    m.fill = Texture(m, "ARTWORK", COLORS.accent)
    m.fill:SetPoint("TOPLEFT")
    m.fill:SetPoint("BOTTOMLEFT")
    m.fill:SetWidth(1)
    function m:SetValue(value, max, tone)
        self.unknown = false
        local frac = (type(value) == "number" and type(max) == "number" and max > 0) and math.max(0, math.min(1, value / max))
            or (type(value) == "number" and max == nil and math.max(0, math.min(1, value))) or 0
        self.frac = frac
        Fill(self.fill, Style.ToneColor(tone or "accent"))
        self.fill:ClearAllPoints()
        self.fill:SetPoint("TOPLEFT")
        self.fill:SetPoint("BOTTOMLEFT")
        self.fill:SetWidth(math.max(1, (self:GetWidth() or 0) * frac))
        self.fill:SetShown(frac > 0)
    end
    function m:SetUnknown()
        self.unknown, self.frac = true, nil
        Style.Hatch(self.fill, 0.6)
        self.fill:ClearAllPoints()
        self.fill:SetAllPoints()
        self.fill:Show()
    end
    m:SetScript("OnSizeChanged", function(self)
        if not self.unknown and self.frac then self.fill:SetWidth(math.max(1, (self:GetWidth() or 0) * self.frac)) end
    end)
    return m
end

-- A titled panel with a summary line. Returns the panel; its .content
-- frame holds whatever goes inside. Ledger: a 26 high header (title and sub
-- on one line); card:SetLink(label, onClick) adds a link at the header's
-- right, card:SetFoot(text) a footer line under the content.
function Style.Card(parent, title)
    local card = CreateFrame("Frame", nil, parent)
    local ledger = lookName == "ledger"
    local head = M.cardHeader
    local bg = Texture(card, "BACKGROUND", ledger and COLORS.raise or COLORS.card)
    bg:SetAllPoints()
    Style.Border(card, COLORS.cardBorder)
    card.title = Text(card, ledger and "cardTitle" or "GameFontNormal")
    card.sub = Text(card, ledger and "meta" or "GameFontDisableSmall")
    if ledger then
        card.title:SetPoint("LEFT", card, "TOPLEFT", 8, -head / 2)
        card.sub:SetPoint("LEFT", card.title, "RIGHT", 8, 0)
        card.sub:SetPoint("RIGHT", card, "TOPRIGHT", -8, -head / 2)
    else
        card.title:SetPoint("TOPLEFT", 10, -8)
        card.title:SetPoint("RIGHT", -10, 0)
        card.sub:SetPoint("TOPLEFT", card.title, "BOTTOMLEFT", 0, -3)
        card.sub:SetPoint("RIGHT", -10, 0)
    end
    card.title:SetText(title or "")
    local line = Style.HLine(card)
    line:SetPoint("TOPLEFT", 1, -head)
    line:SetPoint("TOPRIGHT", -1, -head)
    card.content = CreateFrame("Frame", nil, card)
    card.content:SetPoint("TOPLEFT", 4, -(head + 4))
    card.content:SetPoint("BOTTOMRIGHT", -4, 4)

    function card:SetLink(label, onClick)
        if not self.link then
            self.link = CreateFrame("Button", nil, self)
            self.link:SetHeight(18)
            self.link.text = Text(self.link, ledger and "body" or "GameFontNormalSmall", "RIGHT")
            self.link.text:SetAllPoints()
            self.link:SetPoint("RIGHT", self, "TOPRIGHT", -8, ledger and -head / 2 or -16)
            self.link:SetScript("OnEnter", function(b) b.text:SetTextColor(COLORS.t1[1], COLORS.t1[2], COLORS.t1[3]) end)
            self.link:SetScript("OnLeave", function(b) b.text:SetTextColor(COLORS.accentHi[1], COLORS.accentHi[2], COLORS.accentHi[3]) end)
        end
        self.link.text:SetText(label or "")
        self.link.text:SetTextColor(COLORS.accentHi[1], COLORS.accentHi[2], COLORS.accentHi[3])
        self.link:SetWidth(math.floor((self.link.text:GetStringWidth() or 60) + 4.5))
        self.link:SetScript("OnClick", onClick)
        self.link:SetShown(label ~= nil and label ~= "")
        if ledger then self.sub:SetPoint("RIGHT", self.link, "LEFT", -8, 0) end
    end

    function card:SetFoot(text)
        if not self.foot then
            self.foot = Text(self, "meta")
            self.foot:SetPoint("BOTTOMLEFT", 8, 5)
            self.foot:SetPoint("BOTTOMRIGHT", -8, 5)
        end
        self.foot:SetText(text or "")
        local on = text ~= nil and text ~= ""
        self.foot:SetShown(on)
        self.content:SetPoint("BOTTOMRIGHT", -4, on and 20 or 4)
    end
    return card
end

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

-- Brand art (an entry of ns.TEX with path / coords / aspect) at its own shape:
-- (height * aspect) x height with its texcoords. Style.BrandHeight resizes it
-- later (a window that shrinks); under 1 it hides.
function Style.BrandTexture(parent, tex, height, layer)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    t:SetTexture(tex.path)
    t:SetTexCoord(tex.coords[1], tex.coords[2], tex.coords[3], tex.coords[4])
    t.brand = tex
    Style.BrandHeight(t, height)
    return t
end

function Style.BrandHeight(t, height)
    if not height or height < 1 then t:Hide() return end
    t:SetSize(height * t.brand.aspect, height)
    t:Show()
end

-- The header of a home page: the crest on a band a shade lighter than the
-- window (its navy body is lost on the window's near-black), the name in the
-- art's gold and the tagline as text. The art's own lettering is too fine to
-- read at window sizes, so the words are font strings. Anchor it under the
-- title bar; header.sub takes a line of the page's own.
Style.BRAND_HEADER_HEIGHT = 80
function Style.BrandHeader(parent)
    local h = CreateFrame("Frame", nil, parent)
    h:SetHeight(Style.BRAND_HEADER_HEIGHT)
    h.bg = Texture(h, "BACKGROUND", COLORS.brandBand)
    h.bg:SetAllPoints()
    h.rule = Texture(h, "ARTWORK", COLORS.brandRule)
    h.rule:SetHeight(1)
    h.rule:SetPoint("BOTTOMLEFT")
    h.rule:SetPoint("BOTTOMRIGHT")
    h.crest = Style.BrandTexture(h, ns.TEX.crest, 72)
    h.crest:SetPoint("LEFT", 16, 0)
    h.name = Text(h, "GameFontNormalHuge")
    h.name:SetPoint("TOPLEFT", h.crest, "TOPRIGHT", 14, -8)
    h.name:SetText("|cff" .. ns.ART_COLOR .. ns.NAME .. "|r")
    h.tagline = Text(h, "GameFontHighlightSmall")
    h.tagline:SetPoint("TOPLEFT", h.name, "BOTTOMLEFT", 0, -3)
    h.tagline:SetText(HEX.muted .. ns.TAGLINE .. "|r")
    h.sub = Text(h, "GameFontHighlight")
    h.sub:SetPoint("BOTTOMLEFT", h.crest, "BOTTOMRIGHT", 14, 8)
    h.sub:SetPoint("RIGHT", -16, 0)
    return h
end

-- Opens Settings at a section (falls back to the whole settings window).
function Style.OpenSettings(section)
    local O = ns.Options
    if not O then return end
    if section and O.OpenSection then O.OpenSection(section)
    elseif O.Open then O.Open() end
end

-- The row of page buttons in a title bar: header:Add(button) places it
-- right to left, before the gear and close.
local function Header(f, right)
    local h = CreateFrame("Frame", nil, f)
    h:SetHeight(22)
    h:SetPoint("TOPRIGHT", right, -(M.titleBar - 22) / 2)
    h:SetWidth(1)
    h.items = {}
    function h:Add(b)
        b:SetParent(self)
        b:ClearAllPoints()
        local last = self.items[#self.items]
        if last then b:SetPoint("RIGHT", last, "LEFT", -4, 0) else b:SetPoint("RIGHT", self, "RIGHT", 0, 0) end
        self.items[#self.items + 1] = b
        local w = 0
        for _, it in ipairs(self.items) do w = w + (it:GetWidth() or 0) + 4 end
        self:SetWidth(math.max(1, w))
        return b
    end
    return h
end

-- A movable window with a title bar and a close button.
--   opts.nav: a main window; its size is the one all main windows share
--   (Navigation.lua), so width / height may be nil.
--   opts.settings: a Settings section key; a gear in the title bar opens it.
--   opts.section: the small brass word before the title (ledger).
--   opts.hidden: built ahead of time, hidden.
-- f:SetStatus(text) writes the status after the title; f.header:Add(button)
-- puts a page's button in the title bar.
function Style.Window(name, title, width, height, opts)
    opts = opts or {}
    if opts.nav and ns.Nav then width, height = ns.Nav.Size() end
    local ledger = lookName == "ledger"
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
    Style.Surface(f, "window")
    local barH = M.titleBar
    local bar = Texture(f, "BACKGROUND", ledger and COLORS.band or COLORS.titleBar)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:SetHeight(ledger and barH - 1 or 38)
    f.titleBar = bar
    local close = CreateFrame("Button", nil, f)
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -8, -7)
    if ledger then
        local rule = Style.HLine(f, COLORS.line)
        rule:SetPoint("TOPLEFT", 1, -barH)
        rule:SetPoint("TOPRIGHT", -1, -barH)
        f.section = Text(f, "label")
        f.section:SetPoint("LEFT", f, "TOPLEFT", 12, -barH / 2)
        f.section:SetText(string.upper(opts.section or ns.TITLE))
        f.section:SetTextColor(COLORS.brass[1], COLORS.brass[2], COLORS.brass[3])
        f.title = Text(f, "title")
        f.title:SetPoint("LEFT", f.section, "RIGHT", 8, 0)
        f.title:SetText(title or "")
        close:SetSize(22, 22)
        close:ClearAllPoints()
        close:SetPoint("RIGHT", f, "TOPRIGHT", -6, -barH / 2)
        close.hl = Texture(close, "HIGHLIGHT", COLORS.hover)
        close.hl:SetAllPoints()
        close.glyph = Style.Glyph(close, "close", 14, "t3")
        close.glyph:SetPoint("CENTER")
        if close.glyph.fallback then close.glyph.fallbackText:SetText("×") end
        close:SetScript("OnEnter", function(self) self.glyph:SetTone("t1") end)
        close:SetScript("OnLeave", function(self) self.glyph:SetTone("t3") end)
    else
        f.icon = f:CreateTexture(nil, "ARTWORK")
        f.icon:SetTexture(ns.TEX.icon64)
        f.icon:SetSize(18, 18)
        f.icon:SetPoint("TOPLEFT", 12, -11)
        f.title = Text(f, "GameFontNormalLarge")
        f.title:SetPoint("TOPLEFT", 36, -12)
        f.title:SetText(ns.TITLE .. "  " .. HEX.white .. (title or "") .. "|r")
        close.x = Text(close, "GameFontNormalLarge", "CENTER")
        close.x:SetPoint("CENTER", 0, 1)
        close.x:SetText(HEX.muted .. "×|r")
        close:SetScript("OnEnter", function(self) self.x:SetText(HEX.white .. "×|r") end)
        close:SetScript("OnLeave", function(self) self.x:SetText(HEX.muted .. "×|r") end)
    end
    close:SetScript("OnClick", function() f:Hide() end)
    f.close = close

    -- Status after the title, page buttons, the gear: made when first asked
    -- for, so a window that uses none of them draws as before.
    local right = -(8 + 24 + 4)
    if opts.settings then
        local gear = Style.IconButton(f, "gear", function() Style.OpenSettings(opts.settings) end,
            { "Settings", "Opens this page's settings." })
        gear:SetPoint("TOPRIGHT", right, -(barH - 22) / 2)
        f.gear = gear
        right = right - 22 - 4
    end
    f.header = Header(f, right)
    function f:SetStatus(text)
        if not self.status then
            self.status = Text(self, ledger and "body" or "GameFontHighlightSmall")
            self.status:SetPoint("LEFT", self.title, "RIGHT", 10, 0)
            self.status:SetPoint("RIGHT", self.header, "LEFT", -8, 0)
            if ledger then self.status:SetTextColor(COLORS.t3[1], COLORS.t3[2], COLORS.t3[3]) end
        end
        self.status:SetText(text or "")
    end

    if name and UISpecialFrames then table.insert(UISpecialFrames, name) end
    -- opts.hidden: built ahead of time (Data.Window prebuild). Hidden before
    -- the navigation sees it, or it would close the window that is open.
    if opts.hidden then f:Hide() end
    if opts.nav and ns.Nav then ns.Nav.Attach(f, opts.nav, title) end
    return f
end

---------------------------------------------------------------------------
-- Floating title bar: the one bar every floating piece (panel, fishing HUD,
-- mini recruit window, craft tracker, scan panel) wears.
--   Style.FloatBar(frame, { page, title, switch, lock, settings, hide, menu })
--   page: the page it belongs to (the left button opens it: Nav.Go / Open);
--   menu: fn() -> a Style.ContextMenu spec for a right-click on that button
--   (default: the page list when Navigation has one);
--   switch = { glyph, offGlyph, get = fn -> bool, set = fn(bool), tooltip, offTone }
--   (the piece's own switch, e.g. mute);
--   lock = { get = fn -> bool, set = fn(bool) }; settings = a Settings section;
--   hide = fn() (the hide button), hideTip = its tooltip lines;
--   tab: the tab the left button opens (default: the page's last one).
-- Returns the bar: bar:SetTitle(text), bar:SetCount(text), bar:Refresh().
---------------------------------------------------------------------------
Style.FLOAT_BAR = 20

local function PageMenu(current)
    local Nav = ns.Nav
    local items = {}
    for _, page in ipairs((Nav and Nav.PAGES) or {}) do
        if page.key and page.label and not (page.hidden and page.hidden()) then
            items[#items + 1] = { label = page.label, selected = page.key == current or nil, pick = function()
                if Nav.Go then Nav.Go(page.key) elseif Nav.Open then Nav.Open(page.key) end
            end }
        end
    end
    return { title = ns.TITLE, items = items }
end
Style.FloatPageMenu = PageMenu

function Style.FloatBar(frame, opts)
    opts = opts or {}
    local bar = CreateFrame("Frame", nil, frame)
    bar:SetHeight(Style.FLOAT_BAR)
    bar:SetPoint("TOPLEFT")
    bar:SetPoint("TOPRIGHT")
    bar.bg = Texture(bar, "BACKGROUND", COLORS.band, 0.92)
    bar.bg:SetAllPoints()
    Fill(bar.bg, COLORS.band, 0.92)
    local rule = Style.HLine(bar, COLORS.line)
    rule:SetPoint("BOTTOMLEFT")
    rule:SetPoint("BOTTOMRIGHT")

    local home = CreateFrame("Button", nil, bar)
    home:SetSize(18, 18)
    home:SetPoint("LEFT", 2, 0)
    home.icon = home:CreateTexture(nil, "ARTWORK")
    home.icon:SetTexture(ns.TEX.icon64)
    home.icon:SetSize(14, 14)
    home.icon:SetPoint("CENTER")
    home.hl = Texture(home, "HIGHLIGHT", COLORS.hover)
    home.hl:SetAllPoints()
    home:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    home:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            Style.ContextMenu(self, opts.menu and opts.menu() or PageMenu(opts.page))
            return
        end
        local Nav = ns.Nav
        if not Nav then return end
        if opts.page and Nav.Go then Nav.Go(opts.page, opts.tab)
        elseif opts.page and Nav.Open then Nav.Open(opts.page)
        elseif Nav.ShowMenu then Nav.ShowMenu() end
    end)
    home:SetScript("OnEnter", function(self)
        ns.Tooltip.Text(self, { ns.TITLE, "Click: open this page.", "Right-click: go to another page." })
    end)
    home:SetScript("OnLeave", function() ns.Tooltip.Hide() end)
    bar.home = home

    bar.title = Text(bar, "body")
    bar.title:SetPoint("LEFT", home, "RIGHT", 4, 0)
    bar.title:SetText(opts.title or "")
    bar.title:SetTextColor(COLORS.t1[1], COLORS.t1[2], COLORS.t1[3])

    -- Right to left: hide, gear, lock, the piece's switch.
    local x = -2
    local function Place(b)
        b:SetPoint("RIGHT", x, 0)
        x = x - 18 - 2
        return b
    end
    if opts.hide then
        bar.hide = Place(Style.IconButton(bar, "close", function() opts.hide() end,
            opts.hideTip or { "Hide", "Hides it. Home turns it back on." }, { small = true }))
    end
    if opts.settings then
        bar.gear = Place(Style.IconButton(bar, "gear", function() Style.OpenSettings(opts.settings) end,
            { "Settings", "Opens its settings." }, { small = true }))
    end
    if opts.lock then
        local L = opts.lock
        bar.lock = Place(Style.IconButton(bar, "unlock", function()
            L.set(not L.get())
            bar:Refresh()
        end, function() return { L.get() and "Locked" or "Unlocked", L.get() and "Shift + drag still moves it. Click: unlock."
            or "Drag to move. Click: lock in place." } end,
            { small = true }))
    end
    if opts.switch then
        local S = opts.switch
        bar.switch = Place(Style.IconButton(bar, S.glyph or "bell", function()
            S.set(not S.get())
            bar:Refresh()
        end, S.tooltip, { small = true }))
    end
    bar.count = Text(bar, "body", "RIGHT")
    bar.count:SetPoint("RIGHT", x - 2, 0)
    bar.count:SetTextColor(COLORS.t3[1], COLORS.t3[2], COLORS.t3[3])
    bar.title:SetPoint("RIGHT", bar.count, "LEFT", -4, 0)

    function bar:SetTitle(text) self.title:SetText(text or "") end
    function bar:SetCount(text) self.count:SetText(text or "") end
    function bar:Refresh()
        if self.lock then
            local locked = opts.lock.get() and true or false
            self.lock:SetGlyph(locked and "lock" or "unlock")
            self.lock:SetOn(false)
        end
        if self.switch then
            local S = opts.switch
            local on = S.get() and true or false
            self.switch:SetGlyph(on and (S.glyph or "bell") or (S.offGlyph or S.glyph or "belloff"))
            self.switch.glyph:SetTone(on and "t3" or (S.offTone or "threshold"))
        end
    end
    bar:Refresh()
    frame.floatBar = bar
    return bar
end

-- The Enemies panel's click-to-target overlays are secure buttons at the
-- panel's level + 10 in its strata (MEDIUM). A floating piece dragged over
-- the panel must take the click where they overlap (an invite, a /who, a
-- lure), so every floating piece starts at this level, before its children
-- are made (they are made above it). Out of combat only.
Style.FLOAT_LEVEL = 30
function Style.RaiseFloat(f)
    if not f or (InCombatLockdown and InCombatLockdown()) then return end
    if (f:GetFrameLevel() or 0) < Style.FLOAT_LEVEL then f:SetFrameLevel(Style.FLOAT_LEVEL) end
end

-- A floating piece's frame: the hud surface (black outer edge in the
-- ledger look), movable by a drag. opts.locked = fn -> true keeps it in
-- place unless Shift is held; opts.moved = fn(self) after a drag;
-- opts.strata; opts.escape = true closes it on Escape.
function Style.FloatFrame(name, width, height, opts)
    opts = opts or {}
    local f = CreateFrame("Frame", name, UIParent)
    f:SetSize(width, height)
    f:SetPoint("CENTER")
    f:SetFrameStrata(opts.strata or "MEDIUM")
    Style.RaiseFloat(f)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        if opts.locked and opts.locked() and not (IsShiftKeyDown and IsShiftKeyDown()) then return end
        self:StartMoving()
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if opts.moved then opts.moved(self) end
    end)
    Style.Surface(f, "hud")
    if opts.escape and name and UISpecialFrames then table.insert(UISpecialFrames, name) end
    return f
end

---------------------------------------------------------------------------
-- Notice: a small window that asks for the player's attention once (an
-- update, a warning), never chat. A colored edge says how serious it is;
-- the text wraps and the window grows to fit it.
--   local n = Style.Notice(name, title, { width, tone = "bad" | "gold" | "accent" | "good", icon })
--   n:Set({ headline, sub, pages = { { key, label, blocks } }, buttons = { { label, width, onClick, tooltip } } })
--     blocks: { heading, text, copy = { label, text, what } }; with two or
--     more pages a tab row picks the page (n:ShowPage(key)).
--   n:SetTone(tone). Buttons close nothing by themselves; call n:Hide().
--   opts.flat = true, opts.parent: drawn inside a page instead (no title bar,
--   shown as built; the page places it).
--   Tones: bad, gold, accent, good, and the safety tones (unknown included).
---------------------------------------------------------------------------
local function NoticeTone(tone)
    if tone == "gold" then return { 1, 0.82, 0 } end
    if tone == nil or tone == "accent" then return COLORS.accent end
    return Style.ToneColor(tone)
end
local NOTICE_PAD = 18

local function WrapText(parent, template)
    local fs = Text(parent, template)
    if fs.SetWordWrap then fs:SetWordWrap(true) end
    fs:SetJustifyV("TOP")
    return fs
end

function Style.Notice(name, title, opts)
    opts = opts or {}
    local width = opts.width or 480
    local flat = opts.flat
    local f
    if flat then
        f = CreateFrame("Frame", name, opts.parent or UIParent)
        f:SetSize(width, 60)
        local bg = Texture(f, "BACKGROUND", COLORS.raise)
        bg:SetAllPoints()
        Style.Border(f, COLORS.lineStrong)
    else
        f = Style.Window(name, title, width, 200, { hidden = true })
    end
    f.textWidth = width - 2 * NOTICE_PAD - (opts.icon and 42 or 0)
    -- Where the text starts under the title bar (10 in a page).
    local HEAD = flat and 10 or 54

    f.edge = Texture(f, "ARTWORK")
    f.edge:SetPoint("TOPLEFT", 1, flat and -1 or -(M.titleBar + 1))
    f.edge:SetPoint("BOTTOMLEFT", 1, 1)
    f.edge:SetWidth(3)

    local left = NOTICE_PAD + (opts.icon and 42 or 0)
    if opts.icon then
        f.icon = f:CreateTexture(nil, "ARTWORK")
        f.icon:SetSize(32, 32)
        f.icon:SetPoint("TOPLEFT", NOTICE_PAD, -HEAD)
        f.icon:SetTexture(opts.icon)
    end
    f.headline = WrapText(f, flat and "GameFontHighlight" or "GameFontHighlightLarge")
    f.headline:SetPoint("TOPLEFT", left, -HEAD)
    f.headline:SetWidth(f.textWidth)
    f.sub = WrapText(f, "GameFontHighlightSmall")
    f.sub:SetPoint("TOPLEFT", f.headline, "BOTTOMLEFT", 0, -6)
    f.sub:SetWidth(f.textWidth)
    f.sub:SetTextColor(COLORS.muted[1], COLORS.muted[2], COLORS.muted[3])

    f.body = CreateFrame("Frame", nil, f)
    f.blocks, f.buttons = {}, {}

    function f:SetTone(tone)
        local c = NoticeTone(tone)
        Fill(self.edge, c)
        self.headline:SetTextColor(c[1], c[2], c[3])
    end

    -- One heading + text (+ copy button) per block, reused between pages.
    local function Block(i)
        local b = f.blocks[i]
        if b then return b end
        b = CreateFrame("Frame", nil, f.body)
        b.heading = Text(b, "GameFontNormal")
        b.heading:SetPoint("TOPLEFT")
        b.text = WrapText(b, "GameFontHighlightSmall")
        b.text:SetWidth(width - 2 * NOTICE_PAD - 8)
        f.blocks[i] = b
        return b
    end

    local function Height(fs) return fs:IsShown() and (fs:GetText() or "") ~= "" and (fs:GetStringHeight() or 14) or 0 end

    -- Heights come from the wrapped text, so the window is as tall as what it says.
    function f:Layout()
        local top = HEAD + math.max(Height(self.headline) + (Height(self.sub) > 0 and Height(self.sub) + 6 or 0), self.icon and 32 or 0) + 14
        if self.tabs and self.tabs[1] and self.tabs[1]:IsShown() then
            self.tabHolder:SetPoint("TOPLEFT", NOTICE_PAD - 8, -top)
            top = top + 34
        end
        self.body:ClearAllPoints()
        self.body:SetPoint("TOPLEFT", NOTICE_PAD, -top)
        self.body:SetPoint("TOPRIGHT", -NOTICE_PAD, -top)
        local y = 0
        for _, b in ipairs(self.blocks) do
            if b:IsShown() then
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", self.body, "TOPLEFT", 0, -y)
                b:SetPoint("RIGHT", self.body, "RIGHT")
                local h = 0
                if (b.heading:GetText() or "") ~= "" then
                    h = 18
                    b.text:SetPoint("TOPLEFT", 8, -h)
                else
                    b.text:SetPoint("TOPLEFT", 0, 0)
                end
                h = h + Height(b.text)
                if b.copy and b.copy:IsShown() then
                    b.copy:ClearAllPoints()
                    b.copy:SetPoint("TOPLEFT", 8, -h - 6)
                    h = h + 30
                end
                b:SetHeight(h)
                y = y + h + 12
            end
        end
        self.body:SetHeight(math.max(1, y))
        self:SetHeight(top + y + (#self.buttons > 0 and (flat and 34 or 44) or (flat and 4 or 12)))
    end

    function f:ShowPage(key)
        local page
        for _, p in ipairs(self.pages or {}) do if p.key == key then page = p end end
        page = page or (self.pages or {})[1]
        if not page then return end
        self.page = page.key
        if self.tabs then self.tabs:Select(page.key) end
        for i, block in ipairs(page.blocks or {}) do
            local b = Block(i)
            b.heading:SetText(block.heading or "")
            b.text:SetText(block.text or "")
            if block.copy then
                local copy = block.copy
                b.copy = b.copy or Style.Button(b, "", 120, nil)
                b.copy:SetLabel(copy.label or "Copy")
                b.copy:SetWidth(copy.width or 120)
                b.copy:SetScript("OnClick", function() ns.Utils.Copy(copy.text, copy.what) end)
                b.copy:Show()
            elseif b.copy then
                b.copy:Hide()
            end
            b:Show()
        end
        for i = #(page.blocks or {}) + 1, #self.blocks do self.blocks[i]:Hide() end
        self:Layout()
    end

    function f:Set(spec)
        self:SetTone(spec.tone or opts.tone)
        self.headline:SetText(spec.headline or "")
        self.sub:SetText(spec.sub or "")
        self.pages = spec.pages or {}
        -- Tabs and buttons are kept and reused: a notice opened at every login must not grow frames.
        local tabKey = {}
        for i, p in ipairs(self.pages) do tabKey[i] = tostring(p.key) .. "=" .. tostring(p.label) end
        tabKey = #self.pages > 1 and table.concat(tabKey, "|") or nil
        if tabKey ~= self.tabKey then
            if self.tabs then for _, t in ipairs(self.tabs) do t:Hide() end end
            self.tabs, self.tabKey = nil, tabKey
            if tabKey then
                self.tabHolder = self.tabHolder or CreateFrame("Frame", nil, self)
                self.tabHolder:SetSize(width - 2 * NOTICE_PAD, 26)
                local defs = {}
                for i, p in ipairs(self.pages) do defs[i] = { key = p.key, label = p.label } end
                self.tabs = Style.Tabs(self.tabHolder, defs, function(key) self:ShowPage(key) end, opts.tabWidth or 150)
            end
        end
        if self.tabHolder then self.tabHolder:SetShown(self.tabs ~= nil) end
        self.buttonPool = self.buttonPool or {}
        for _, b in ipairs(self.buttonPool) do b:Hide() end
        self.buttons = {}
        local x = -NOTICE_PAD
        local defs = spec.buttons or {}
        for i = #defs, 1, -1 do
            local def = defs[i]
            local b = self.buttonPool[i]
            if not b then
                local made
                made = Style.Button(self, "", 140, nil, function() return made.tip end)
                b, self.buttonPool[i] = made, made
            end
            b:SetLabel(def.label or "")
            b:SetWidth(def.width or 140)
            b:SetScript("OnClick", def.onClick)
            b.tip = def.tooltip
            b:ClearAllPoints()
            b:SetPoint("BOTTOMRIGHT", x, flat and 8 or 12)
            b:Show()
            x = x - (def.width or 140) - 8
            self.buttons[i] = b
        end
        self:ShowPage(spec.page or self.page)
    end

    f:SetTone(opts.tone)
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
--   opts: labelWidth, colWidths, onClick(item, button, row), menu(item, row)
--   (a right-click menu, Style.ContextMenu; nil: onClick), fallbackRows,
--   (colWidths may hold more than three columns: cols[1] is the rightmost),
--   search = true (a search box; onSearch(text) after each change, for rows
--   the view adds only when searched), time = true (a time range), hint,
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
-- A cell may be ns.UNKNOWN (the game hides it) or { tag = text, tone = };
-- both read as their text.
local function CellText(v)
    if v == ns.UNKNOWN then return "?" end
    if type(v) == "table" and v.tag ~= nil then return tostring(v.tag) end
    return v
end
Style.CellText = CellText

local function Plain(s)
    s = CellText(s)
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
    if text == ns.UNKNOWN then return nil end
    if type(text) == "table" then
        if text.tone == "unknown" then return nil end
        if text.sort ~= nil then return text.sort end
    end
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
    local bg = Texture(box, "BACKGROUND", lookName == "ledger" and COLORS.well or COLORS.button)
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
    local ledger = lookName == "ledger"
    local BAR_WIDTH = M.track
    local FONT_ROW = ledger and Style.Font("body") or "GameFontHighlightSmall"
    local FONT_HEAD = ledger and Style.Font("body") or "GameFontNormalSmall"
    local list = CreateFrame("Frame", nil, parent)
    list:SetAllPoints()
    list.rows, list.items, list.all, list.offset = {}, {}, {}, 0
    list.labelWidth = opts.labelWidth or 0
    list.colWidths = opts.colWidths or {}
    local function NCols() return math.max(3, #list.colWidths) end
    list.search, list.range = "", "all"
    list.top = ((opts.search or opts.time) and TOOLBAR or 0) + (opts.columns and ROW or 0)
    list.sorts = {}
    -- Bumped when anything a row measured at layout is stale (the list was
    -- resized, new column titles, the scrollbar came or went): every row then
    -- sends its whole layout to the widgets once more.
    list.layoutVer = 0
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
        for c = 1, NCols() do
            local w = list.colWidths[c]
            if not w then break end
            local hi = rowRight - edge
            local lo = hi - w
            if x >= lo - 3 and x <= hi + 3 then return (r.item.cols[c] or "") ~= "" and c or nil end
            first = lo
            edge = edge + w + 6
        end
        if r.label and r.label:IsShown() then
            local l, rr = r.label:GetLeft(), r.label:GetRight()
            if l and rr and x >= l - 3 and x <= rr + 3 then return "label" end
        end
        if not first or x < first then return 0 end
        return nil
    end

    -- New titles for the fixed title row (a column that changes meaning).
    function list:SetColumns(columns)
        opts.columns = columns
        self.layoutVer = self.layoutVer + 1
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

    -- What a press acts on. A list redraws while the mouse is down (new
    -- players in view, a bag change, a deferred layout): the click must act
    -- on the item that was under the cursor when the press began, never on
    -- whatever the row shows at the release. opts.itemKey(item) names an
    -- item across redraws (rows are often rebuilt as new tables).
    local function ItemKey(item)
        if item == nil then return nil end
        if opts.itemKey then
            local k = opts.itemKey(item)
            if k ~= nil then return k end
        end
        return item.key or item.full or item.id or item
    end
    -- True when the press (if one was seen) began on this same item; else
    -- the click is dropped and the list redrawn. A click with no press seen
    -- (a key binding, /click) acts on the row as it is.
    local function SamePress(holder, item, extra)
        if not holder.pressed then return true end
        holder.pressed = nil
        local key, ex = holder.pressKey, holder.pressExtra
        holder.pressKey, holder.pressExtra = nil, nil
        if key == ItemKey(item) and ex == extra then return true end
        list:Draw()
        ns.Print("the list changed under the click: nothing done. Click again.")
        return false
    end
    list.ItemKey = ItemKey

    local function MakeRow(i)
        local r = CreateFrame("Button", nil, list)
        r:SetHeight(ROW)
        r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        -- Only what every row shows; the accent, icon, bar, label and columns
        -- are made when a row first needs them (see Layout): a list keeps
        -- about 30 rows, and most lists never show an icon or a bar.
        r.bg = Texture(r, "BACKGROUND")
        r.bg:SetAllPoints()
        r.text = Text(r, ledger and "body" or "GameFontHighlightSmall")
        r.cols = {}
        local hl = r:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        Fill(hl, COLORS.hover)
        r:SetScript("OnMouseDown", function(self)
            self.pressed, self.pressKey = true, ItemKey(self.item)
        end)
        r:SetScript("OnHide", function(self) self.pressed, self.pressKey = nil, nil end)
        r:SetScript("OnClick", function(self, button)
            local item = self.item
            if not SamePress(self, item) then return end
            if item and Titled(item) then
                local col = TitleAt(self)
                if col ~= nil then list:SortBy(SortId(item), col) end
            elseif item and not item.header then
                local menu = button == "RightButton" and opts.menu and opts.menu(item, self)
                if menu then Style.ContextMenu(self, menu)
                elseif opts.onClick then opts.onClick(item, button, self) end
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

    -- Row parts made on first use.
    local function Accent(r)
        if not r.accent then
            r.accent = Texture(r, "ARTWORK")
            r.accent:SetWidth(3)
            r.accent:SetPoint("TOPLEFT")
            r.accent:SetPoint("BOTTOMLEFT")
        end
        return r.accent
    end
    local function Icon(r)
        if not r.icon then
            r.iconBorder, r.icon = Style.IconFrame(r, ROW - 2)
            r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
        return r.icon
    end
    local function Bar(r)
        if not r.barBg then
            r.barBg = Texture(r, "ARTWORK", { 1, 1, 1, 0.08 })
            r.barBg:SetHeight(3)
            r.barFill = Texture(r, "OVERLAY", COLORS.bar)
            r.barFill:SetHeight(3)
        end
    end
    local function Hide(part) if part then part:Hide() end end

    -- Layout runs for every shown row on every redraw (about 30 rows, at least
    -- once a second while data changes) and each widget call crosses into the
    -- game's C side, so a part is touched only when what it shows differs from
    -- what this row last gave it. The "last" values live in r.st, thrown away
    -- whenever list.layoutVer moves (the list was resized, new column titles):
    -- the sizes a row measured then are stale.
    local function SetRGBA(st, key, tex, cr, cg, cb, ca)
        local l = st[key]
        if l and l[1] == cr and l[2] == cg and l[3] == cb and l[4] == ca then return end
        if not l then l = {} st[key] = l end
        l[1], l[2], l[3], l[4] = cr, cg, cb, ca
        tex:SetColorTexture(cr, cg, cb, ca)
    end
    local function SetTint(st, key, tex, c, a) SetRGBA(st, key, tex, c[1], c[2], c[3], a or c[4] or 1) end
    local function SetShownOnce(st, key, region, on)
        on = on and true or false
        if st[key] ~= on then st[key] = on region:SetShown(on) end
    end

    local function Layout(r, item, index)
        local st = r.st
        if not st or st.ver ~= list.layoutVer then
            st = { ver = list.layoutVer, cols = {} }
            r.st = st
        end
        local x = 6 + (item.indent or 0)
        local selected = not item.header and (item.selected or (opts.selected and opts.selected(item))) and true or false
        if item.tint then SetTint(st, "bg", r.bg, item.tint)
        elseif selected then SetTint(st, "bg", r.bg, COLORS.selected)
        elseif not item.header and index % 2 == 0 then SetTint(st, "bg", r.bg, COLORS.stripe)
        else SetRGBA(st, "bg", r.bg, 1, 1, 1, 0) end
        -- The selected row: a 2 unit accent bar on its left edge.
        if selected and M.selectBar and not r.selBar then
            r.selBar = Texture(r, "ARTWORK", COLORS.accent)
            r.selBar:SetWidth(2)
            r.selBar:SetPoint("TOPLEFT")
            r.selBar:SetPoint("BOTTOMLEFT")
        end
        if r.selBar then SetShownOnce(st, "selBar", r.selBar, selected) end
        if item.accent then
            SetShownOnce(st, "accent", Accent(r), true)
            SetTint(st, "accentColor", r.accent, item.accent)
        elseif r.accent then
            SetShownOnce(st, "accent", r.accent, false)
        end

        local titled = Titled(item)
        local useLabel = list.labelWidth > 0 and (not item.header or (titled and item.label ~= nil))
        if useLabel and not r.label then r.label = Text(r, ledger and "meta" or "GameFontDisableSmall", "RIGHT") end
        if r.label then SetShownOnce(st, "label", r.label, useLabel) end
        if useLabel then
            local label, width = r.label, list.labelWidth
            if st.labelX ~= x then
                st.labelX = x
                label:ClearAllPoints()
                label:SetPoint("LEFT", x, 0)
            end
            if st.labelWidth ~= width then st.labelWidth = width label:SetWidth(width) end
            local text = titled and TitleText(item, "label", item.label) or (item.label or "")
            if st.labelText ~= text then st.labelText = text label:SetText(text) end
            x = x + width + 8
        end
        local hasIcon = item.icon ~= nil
        if hasIcon then Icon(r) end
        if r.icon and st.icon ~= hasIcon then
            st.icon = hasIcon
            r.iconBorder:SetShown(hasIcon)
            r.icon:SetShown(hasIcon)
        end
        if hasIcon then
            if st.iconX ~= x then
                st.iconX = x
                r.iconBorder:ClearAllPoints()
                r.iconBorder:SetPoint("LEFT", x, 0)
            end
            if st.iconTexture ~= item.icon then st.iconTexture = item.icon r.icon:SetTexture(item.icon) end
            local empty = item.iconEmpty and true or false
            if st.iconEmpty ~= empty then
                if r.icon.SetDesaturated then r.icon:SetDesaturated(empty) end
                r.icon:SetAlpha(empty and 0.35 or 1)
            end
            if not st.iconBorderSet or st.iconLink ~= item.link or st.iconEmpty ~= empty then
                st.iconBorderSet, st.iconLink = true, item.link
                local qr, qg, qb = Style.QualityColor(item.link)
                r.iconBorder:SetColorTexture(qr, qg, qb, empty and 0.25 or 0.9)
            end
            st.iconEmpty = empty
            x = x + ROW + 4
        end

        local right = 6
        -- A send button on the row (opts.rowButton): selecting the row never sends.
        local spec = opts.rowButton and not item.header and opts.rowButton(item) or nil
        if spec and not r.rowButton then
            local rb
            rb = Style.Button(r, "", opts.rowButtonWidth or 80, nil, function() return rb.tip end, { small = true })
            rb:SetFrameLevel((r:GetFrameLevel() or 1) + 2)
            -- The item and the label (the action: "Craft 4", "Invite again")
            -- when the press began; checked again at the click.
            rb:HookScript("OnMouseDown", function(self)
                self.pressed, self.pressKey, self.pressExtra = true, ItemKey(r.item), self.specLabel
            end)
            rb:HookScript("OnHide", function(self) self.pressed, self.pressKey, self.pressExtra = nil, nil, nil end)
            r.rowButton = rb
        end
        if r.rowButton then
            local rb = r.rowButton
            SetShownOnce(st, "rowButton", rb, spec ~= nil)
            if spec then
                local w = spec.width or opts.rowButtonWidth or 80
                if st.rbRight ~= right or st.rbWidth ~= w then
                    st.rbRight, st.rbWidth = right, w
                    rb:SetWidth(w)
                    rb:ClearAllPoints()
                    rb:SetPoint("RIGHT", -right, 0)
                end
                rb:SetLabel(spec.label or "")
                rb.specLabel = spec.label
                rb:SetKind(spec.kind)
                rb:SetEnabled(spec.enabled ~= false, spec.why)
                rb.tip = spec.tooltip
                -- A right-click on the button is the row's right-click (skip,
                -- forget, a menu), never the button's send.
                rb:SetScript("OnClick", function(self, button)
                    if not SamePress(self, item, spec.label) then return end
                    if button == "RightButton" then
                        r.pressed, r.pressKey = nil, nil
                        local rowClick = r:GetScript("OnClick")
                        if rowClick then rowClick(r, "RightButton") end
                        return
                    end
                    if button ~= nil and button ~= "LeftButton" then return end
                    if spec.onClick then spec.onClick(item, rb) end
                end)
                right = right + w + 6
            end
        end
        for c = 1, NCols() do
            local w = list.colWidths[c]
            local value = item.cols and item.cols[c]
            local fs = r.cols[c]
            -- A tag cell ({ tag, tone } or ns.UNKNOWN): drawn as a tag, never as an empty string.
            local tagged = type(value) == "table"
            if w and value ~= nil and not tagged and not fs then fs = Text(r, ledger and "body" or "GameFontHighlightSmall", "RIGHT") r.cols[c] = fs end
            local cs = st.cols[c]
            if not cs then cs = {} st.cols[c] = cs end
            r.colTags = r.colTags or {}
            local tag = r.colTags[c]
            if w and tagged and not tag then tag = Style.Tag(r) r.colTags[c] = tag end
            if tag then SetShownOnce(cs, "tagShown", tag, w ~= nil and tagged) end
            if w and tagged then
                local tt, tone = "?", "unknown"
                if value ~= ns.UNKNOWN then tt, tone = value.tag, value.tone end
                local key = tostring(tt) .. "|" .. tostring(tone)
                if cs.tagKey ~= key then cs.tagKey = key tag:Set(tt, tone, value.shape) end
                if cs.tagRight ~= right then
                    cs.tagRight = right
                    tag:ClearAllPoints()
                    tag:SetPoint("RIGHT", -right, 0)
                end
            end
            local on = w ~= nil and value ~= nil and not tagged
            if fs then SetShownOnce(cs, "shown", fs, on) end
            if on then
                if cs.right ~= right then
                    cs.right = right
                    fs:ClearAllPoints()
                    fs:SetPoint("RIGHT", -right, 0)
                end
                -- A title may run a little past a narrow column (0 = its own width).
                local width = titled and 0 or w
                if cs.width ~= width then cs.width = width fs:SetWidth(width) end
                local text = (titled and value ~= "") and TitleText(item, c, value) or value
                if cs.text ~= text then cs.text = text fs:SetText(text) end
            end
            if w then right = right + w + 6 end
        end
        local textRight = item.cols and right or 6
        local textY = item.bar and 2 or 0
        if st.textX ~= x or st.textRight ~= textRight or st.textY ~= textY then
            st.textX, st.textRight, st.textY = x, textRight, textY
            r.text:ClearAllPoints()
            r.text:SetPoint("LEFT", x, textY)
            r.text:SetPoint("RIGHT", -textRight, textY)
        end
        local font = item.header and FONT_HEAD or FONT_ROW
        if st.font ~= font then st.font = font r.text:SetFontObject(font) end
        local text
        if titled then text = TitleText(item, 0, item.text or "")
        else text = item.header and (HEX.gold .. item.text .. "|r") or (item.text or "") end
        if st.text ~= text then st.text = text r.text:SetText(text) end

        local bar = item.bar
        if bar then Bar(r) end
        if r.barBg then
            SetShownOnce(st, "barBg", r.barBg, bar ~= nil)
            SetShownOnce(st, "barFill", r.barFill, bar ~= nil and (bar[1] or 0) > 0)
        end
        if bar then
            if st.barX ~= x or st.barRight ~= textRight then
                st.barX, st.barRight = x, textRight
                r.barBg:ClearAllPoints()
                r.barBg:SetPoint("BOTTOMLEFT", x, 2)
                r.barBg:SetPoint("BOTTOMRIGHT", -textRight, 2)
                r.barFill:ClearAllPoints()
                r.barFill:SetPoint("BOTTOMLEFT", x, 2)
            end
            -- Measured every time: the row's width moves with the window and the scrollbar.
            local width = math.max(1, (r:GetWidth() or 200) - x - textRight)
            local frac = (bar[2] and bar[2] > 0) and math.min(1, (bar[1] or 0) / bar[2]) or 0
            local fill = math.max(1, width * frac)
            if st.fillWidth ~= fill then st.fillWidth = fill r.barFill:SetWidth(fill) end
            SetTint(st, "barColor", r.barFill, bar.color or COLORS.bar)
        end
    end

    -- Scrollbar: a track (click: jump there) and a thumb (drag).
    local track = CreateFrame("Button", nil, list)
    track:SetWidth(BAR_WIDTH)
    track:SetPoint("TOPRIGHT", 0, -list.top)
    track:SetPoint("BOTTOMRIGHT")
    track.bg = Texture(track, "BACKGROUND", COLORS.trackDim)
    track.bg:SetPoint("TOPLEFT", M.thumbInset, -1)
    track.bg:SetPoint("BOTTOMRIGHT", -M.thumbInset, 1)
    local thumb = CreateFrame("Button", nil, track)
    thumb:SetWidth(BAR_WIDTH)
    thumb.tex = Texture(thumb, "ARTWORK", ledger and { COLORS.t4[1], COLORS.t4[2], COLORS.t4[3], 0.8 }
        or { COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.55 })
    thumb.tex:SetPoint("TOPLEFT", M.thumbInset, 0)
    thumb.tex:SetPoint("BOTTOMRIGHT", -M.thumbInset, 0)
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

    -- Redraws repeat with the same scroll position far more often than it
    -- moves: the track and thumb are only touched when their numbers changed.
    local barShown, barThumbH, barY
    local function PlaceBar(count)
        local total = #list.items
        local show = total > count and count > 0
        if barShown ~= show then barShown = show track:SetShown(show) end
        if not show then return false end
        local height = (list:GetHeight() or 0) - list.top
        local thumbH = math.max(16, height * count / total)
        local y = -(height - thumbH) * (list.offset / math.max(1, total - count))
        if barThumbH ~= thumbH then barThumbH = thumbH thumb:SetHeight(thumbH) end
        if barY ~= y then
            barY = y
            thumb:ClearAllPoints()
            thumb:SetPoint("TOPRIGHT", track, "TOPRIGHT", 0, y)
        end
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
        -- The rows' width changes with the scrollbar: bar widths are measured again.
        if self.barOn ~= bar then
            self.barOn = bar
            self.layoutVer = self.layoutVer + 1
        end
        local right = bar and -BAR_WIDTH - 2 or 0
        if opts.columns then
            if not self.head then
                self.headItem = { header = true, sticky = true, cols = {}, tint = { 1, 1, 1, 0.04 } }
                self.head = MakeRow(0)
                self.head.item = self.headItem
            end
            local h = self.headItem
            h.text, h.label = opts.columns.name or "", opts.columns.label
            for c = 1, NCols() do h.cols[c] = opts.columns[c] end
            local head = self.head
            local y = -(self.top - ROW)
            if head.anchorTop ~= self.top or head.anchorRight ~= right then
                head.anchorTop, head.anchorRight = self.top, right
                head:ClearAllPoints()
                head:SetPoint("TOPLEFT", 0, y)
                head:SetPoint("TOPRIGHT", right, y)
            end
            if not head.drawn then head.drawn = true head:Show() end
            Layout(head, self.headItem, 0)
        end
        for i, r in ipairs(self.rows) do
            local item = i <= count and self.items[i + self.offset] or nil
            r.item = item
            if item then
                -- A row keeps its slot (index i): re-anchored only when the top
                -- or the scrollbar's side moved.
                if r.anchorTop ~= self.top or r.anchorRight ~= right then
                    r.anchorTop, r.anchorRight = self.top, right
                    r:ClearAllPoints()
                    r:SetPoint("TOPLEFT", 0, -self.top - (i - 1) * ROW)
                    r:SetPoint("TOPRIGHT", right, -self.top - (i - 1) * ROW)
                end
                if not r.drawn then r.drawn = true r:Show() end
                Layout(r, Ready(item), i + self.offset)
            elseif r.drawn ~= false then
                r.drawn = false
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

    local countAll, countItems, countText
    local function UpdateCount(filtered)
        if not list.count then return end
        -- The same rows again (a redraw with nothing new): the same count.
        if list.all == countAll and list.items == countItems then list.count:SetText(countText) return end
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
        countAll, countItems = list.all, list.items
        countText = filtered and (HEX.muted .. shown .. " of " .. n .. " shown|r") or ""
        list.count:SetText(countText)
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

    -- The inputs of the last full pass (sort, filter, count). Handed the same
    -- table again with the same search, sort and a range that keeps everything
    -- (a range with a start moves with the clock), the result stands: only the
    -- rows are drawn again.
    local passItems, passSearch, passRange, passSortVer
    function list:SetItems(items)
        if items == self.all and items == passItems and passSearch == self.search and passRange == self.range
            and passSortVer == self.sortVer and not Style.RangeStart(self.range) then
            self.offset = math.min(self.offset, math.max(0, #self.items - (self.visible or 1)))
            self:Draw()
            return
        end
        self.all = items
        local filtered, active = Filter(Sorted(items))
        if active and #filtered == 0 then
            filtered = { { text = HEX.muted .. "Nothing matches the search / time range.|r" } }
        end
        self.items = filtered
        passItems, passSearch, passRange, passSortVer = items, self.search, self.range, self.sortVer
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
                if opts.onSearch then opts.onSearch(list.search) end
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
    list:SetScript("OnSizeChanged", function(self)
        self.layoutVer = self.layoutVer + 1
        self:Draw()
    end)
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
    Style.Surface(menu, "menu")
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
    arrow.hl = Texture(arrow, "HIGHLIGHT", COLORS.hoverRow)
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

---------------------------------------------------------------------------
-- Context menu: what a right-click opens, anywhere in the addon. A small
-- box just above the pointer (where a desktop menu opens). It goes away on
-- a pick, on Escape, when the row it came from hides or shows another item,
-- or once the mouse is well clear of both the box and that row.
--
--   Style.ContextMenu(owner, menu) -> the menu frame
--   menu = { title, sub (muted, after the title), items = {
--     { label, notes = { { text, tone }, ... } (after the label), tone,
--       selected (the current choice: accent bar), disabled, why (the
--       reason, shown when hovered), tooltip = lines, pick = fn },
--     { header = "Section" }, ... } }
--   Tones are the tooltip's names (Tooltip.lua TONES): muted, good, bad,
--   gold, accent, compare. Warnings are "bad", unknowns "gold".
--
-- A list opens one for its rows with opts.menu = fn(item, row) -> menu or
-- nil (Style.List); a right-click with no menu still goes to onClick.
---------------------------------------------------------------------------
local CTX_ROWS, CTX_WIDTH, CTX_TITLE = 14, 240, 20
-- How far (UI units) the mouse may stray from the box or the row.
Style.CONTEXT_MARGIN = 40
local ctx

local function ToneHex(tone)
    if tone == "white" or tone == "text" then return HEX.white end
    return tone and HEX[tone] or nil
end

local function Toned(text, tone)
    local hex = ToneHex(tone)
    return hex and (hex .. text .. "|r") or text
end

local function CloseContext()
    if ctx then ctx.owner, ctx.item = nil, nil ctx:Hide() end
end
Style.CloseContextMenu = CloseContext

-- The cursor within pad of a frame; true when the frame's place is unknown,
-- so a frame not laid out yet never closes the menu by itself.
local function Near(f, x, y, pad)
    local l, r, t, b = f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
    if not (l and r and t and b) then return true end
    local s = f:GetEffectiveScale() or 1
    x, y = x / s, y / s
    return x >= l - pad and x <= r + pad and y >= b - pad and y <= t + pad
end

local function BuildContext()
    ctx = CreateFrame("Frame", ns.FRAME .. "ContextMenu", UIParent)
    ctx:SetFrameStrata("FULLSCREEN_DIALOG")
    ctx:SetClampedToScreen(true)
    ctx:EnableMouse(true)
    Style.Surface(ctx, "menu")
    ctx.title = Text(ctx, "GameFontNormalSmall")
    ctx.title:SetPoint("TOPLEFT", 8, -5)
    ctx.title:SetPoint("TOPRIGHT", -8, -5)
    ctx.line = Style.HLine(ctx)
    ctx.line:SetPoint("TOPLEFT", 4, -CTX_TITLE + 2)
    ctx.line:SetPoint("TOPRIGHT", -4, -CTX_TITLE + 2)
    ctx.holder = CreateFrame("Frame", nil, ctx)
    ctx.holder:SetPoint("TOPLEFT", 3, -CTX_TITLE)
    ctx.holder:SetPoint("BOTTOMRIGHT", -3, 3)
    ctx.list = Style.List(ctx.holder, { fallbackRows = CTX_ROWS, onClick = function(item)
        if not item.pick then return end
        CloseContext()
        item.pick()
    end })
    ctx:SetScript("OnUpdate", function(self)
        local owner = self.owner
        if not owner or not owner:IsVisible() or owner.item ~= self.item then CloseContext() return end
        if type(GetCursorPosition) ~= "function" then return end
        local x, y = GetCursorPosition()
        if not (x and y) then return end
        local pad = Style.CONTEXT_MARGIN
        if not Near(self, x, y, pad) and not Near(owner, x, y, pad) then CloseContext() end
    end)
    ctx:Hide()
    if UISpecialFrames then table.insert(UISpecialFrames, ns.FRAME .. "ContextMenu") end
end

-- One menu entry → a list row.
local function MenuRow(it)
    if it.header then return { header = true, text = tostring(it.header) } end
    local tone = it.disabled and "dim" or (it.selected and "accent" or it.tone)
    local text = Toned(tostring(it.label or ""), tone)
    for _, n in ipairs(it.notes or {}) do
        if n[1] and n[1] ~= "" then text = text .. "  " .. Toned(n[1], it.disabled and n[2] ~= "bad" and n[2] ~= "gold" and "dim" or n[2]) end
    end
    local tip = it.tooltip
    if it.disabled and it.why then
        tip = {}
        for _, l in ipairs(it.tooltip or { tostring(it.label or "") }) do tip[#tip + 1] = l end
        tip[#tip + 1] = HEX.muted .. "Not possible: " .. it.why .. ".|r"
    end
    return { text = text, accent = it.selected and COLORS.accent or nil, pick = not it.disabled and it.pick or nil,
        tooltip = tip and function(o) ns.Tooltip.Text(o, tip) end }
end

function Style.ContextMenu(owner, menu)
    if not ctx then BuildContext() end
    menu = menu or {}
    local rows = {}
    for _, it in ipairs(menu.items or {}) do rows[#rows + 1] = MenuRow(it) end
    if #rows == 0 then rows[1] = { text = HEX.muted .. "Nothing to do here.|r" } end
    local shown = math.min(#rows, CTX_ROWS)
    ctx:SetSize(menu.width or CTX_WIDTH, CTX_TITLE + shown * Style.ROW + 6)
    ctx:ClearAllPoints()
    local x, y = 0, 0
    if type(GetCursorPosition) == "function" then x, y = GetCursorPosition() end
    local s = UIParent:GetEffectiveScale() or 1
    -- Just above the pointer, its left edge a little left of it.
    ctx:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", (x or 0) / s - 12, (y or 0) / s + 6)
    ctx.title:SetText(tostring(menu.title or "") .. (menu.sub and (HEX.muted .. "  " .. menu.sub .. "|r") or ""))
    ctx.owner, ctx.item = owner, owner.item
    ctx.list.visible = shown
    ctx.list.offset = 0
    ns.Tooltip.Hide()
    ctx:Show()
    ctx.list:SetItems(rows)
    return ctx
end
