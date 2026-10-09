-- Brand art (Brand.lua ns.TEX, Style.BrandTexture): every path is a PNG that
-- exists in media/textures, crest and banner keep their shape, the windows
-- that show them, and the chat icon.
local scenarios, T = ...
local check, boot, slash = T.check, T.boot, T.slash

-- y offset of a frame's first point (the mock keeps SetPoint's arguments as given).
local function yOf(f)
    local p = f._points[1]
    return p and p[#p]
end

local function near(a, b) return math.abs((a or 0) - (b or 0)) < 0.01 end

local function onDisk(ns, path)
    local rel = path:sub(#ns.MEDIA + 1)
    local f = io.open(ADDON_DIR .. "/media/textures/" .. rel, "rb")
    if f then f:close() return true end
    return false
end

local function shaped(t, tex, label)
    check(t:GetTexture() == tex.path, label .. ": path " .. tostring(t:GetTexture()))
    local a, b, c, d = t:GetTexCoord()
    check(a == tex.coords[1] and b == tex.coords[2] and c == tex.coords[3] and d == tex.coords[4], label .. ": texcoords")
    check(near(t:GetWidth(), t:GetHeight() * tex.aspect), label .. ": width = height * aspect ("
        .. tostring(t:GetWidth()) .. " x " .. tostring(t:GetHeight()) .. ")")
end

scenarios.branding = function()
    Minimap = CreateFrame("Frame", "Minimap", UIParent)
    Minimap._cx, Minimap._cy = 1000, 700
    local ns = boot(11509)

    -- Paths: under the addon's media folder, ".png" kept, the file present.
    check(ns.MEDIA:find("media\\textures\\", 1, true), "MEDIA points at media\\textures")
    for key, tex in pairs(ns.TEX) do
        local path = type(tex) == "table" and tex.path or tex
        check(path:sub(1, #ns.MEDIA) == ns.MEDIA, key .. " under MEDIA")
        check(path:sub(-4) == ".png", key .. " keeps .png")
        check(onDisk(ns, path), key .. " exists: " .. path)
        if type(tex) == "table" then
            check(#tex.coords == 4 and tex.aspect > 0, key .. " has coords and aspect")
        end
    end

    -- Chat: the icon in front of the colored name.
    check(ns.CHAT_PREFIX == ns.ICON_TAG .. " " .. ns.TITLE, "chat prefix carries the icon")
    check(ns.ICON_TAG:find(ns.TEX.icon64, 1, true), "icon tag uses the 64 icon")

    -- Minimap button: the brand icon, full texcoords.
    local mini = TALODMinimapButton
    check(mini and mini.icon:GetTexture() == ns.TEX.icon64, "minimap icon")
    local a, b, c, d = mini.icon:GetTexCoord()
    check(a == 0 and b == 1 and c == 0 and d == 1, "minimap icon not cropped")

    -- Style.BrandTexture: crest / banner at their shape.
    local probe = CreateFrame("Frame", nil, UIParent)
    shaped(ns.Style.BrandTexture(probe, ns.TEX.banner, 56), ns.TEX.banner, "banner texture")
    shaped(ns.Style.BrandTexture(probe, ns.TEX.crest, 72), ns.TEX.crest, "crest texture")

    -- A header: icon, name, tagline as text, the page's own line.
    local function header(h, label)
        check(h and h:IsShown(), label .. ": header shown")
        shaped(h.crest, ns.TEX.crest, label .. ": header crest")
    check(h.crest:GetHeight() == 72, label .. ": crest 72 high")
        check(h.name:GetText():find(ns.NAME, 1, true) and h.name:GetText():find(ns.ART_COLOR, 1, true), label .. ": name in the art's gold")
        check(h.tagline:GetText():find(ns.TAGLINE, 1, true), label .. ": tagline")
    end

    -- Main menu: icon in the title bar, header, tiles under it.
    slash("menu")
    local menu = TALODMainMenu
    check(menu.icon:GetTexture() == ns.TEX.icon64 and menu.icon:GetWidth() == 18, "title bar icon")
    header(menu.header, "menu")
    check(menu.header.sub:GetText():find("Pick a page", 1, true), "menu intro in the header")
    local function lowestTile()
        local low = 0
        for _, t in ipairs(menu.order) do low = math.min(low, yOf(t) - t:GetHeight()) end
        return low
    end
    check(yOf(menu.order[1]) <= -(39 + ns.Style.BRAND_HEADER_HEIGHT), "tiles under the header")
    check(-lowestTile() <= menu:GetHeight() - 64, "tiles above the controls (default size): " .. lowestTile())
    -- A short window: the header gives way to the tiles.
    menu:SetHeight(ns.Nav.MIN_SIZE[2])
    check(not menu.header:IsShown(), "header hidden in a short window")
    menu:SetHeight(ns.Nav.DEFAULT_SIZE[2])
    check(menu.header:IsShown(), "header back at the default size")

    -- Credits: the same header above the cards.
    ns.Credits.Show()
    local credits = TALODCreditsWindow
    header(credits.header, "credits")
    local y = yOf(credits.cards[1])
    check(y == -(39 + 12 + ns.Style.BRAND_HEADER_HEIGHT + 12), "first card under the header: " .. tostring(y))
    -- One centered column, at most 720 wide, on a wide window.
    credits:SetWidth(1400)
    local card = credits.cards[1]
    local x = card._points[1][2]
    check(card:GetWidth() == 720 and x == (1400 - 720) / 2, "centered column: x " .. tostring(x) .. ", width " .. tostring(card:GetWidth()))
    check(credits.header:GetWidth() == 720, "header as wide as the column")
    credits:SetWidth(ns.Nav.DEFAULT_SIZE[1])
    credits:SetHeight(ns.Nav.MIN_SIZE[2])
    local last = credits.cards[#credits.cards]
    y = yOf(last)
    check(-(y - last:GetHeight()) <= credits:GetHeight() - 12, "cards fit the smallest window")

    -- The game's Options > AddOns entry: the crest beside the title.
    check(TALODOptionsPanel and TALODOptionsPanel.crest, "options launcher crest")
    shaped(TALODOptionsPanel.crest, ns.TEX.crest, "options crest")
end
