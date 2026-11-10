-- The look (Style.lua): two looks (ledger, classic) build every window and
-- floating piece; the unknown tone; the parts every page uses; the texture
-- files missing after a /reload (the game sees new files only after a
-- restart): everything still builds and unknown still reads "?".
local scenarios, T = ...
local check, boot, slash = T.check, T.boot, T.slash

local MEDIA = { "Glyphs.tga", "Hatch.tga", "Shadow.tga" }

local function hideMedia()
    for _, f in ipairs(MEDIA) do
        MOCK.missingFiles["Interface\\AddOns\\" .. ADDON_NAME .. "\\media\\textures\\" .. f] = true
    end
end

local function near(a, b) return math.abs((a or -1) - (b or -2)) < 0.002 end
local function sameColor(a, b) return a and b and near(a[1], b[1]) and near(a[2], b[2]) and near(a[3], b[3]) end

-- Text without its colour codes.
local function plain(text) return (tostring(text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end

-- A floating piece and the parts any page may use, built in the current look.
local function buildParts(ns)
    local Style = ns.Style
    local host = CreateFrame("Frame", nil, UIParent)
    host:SetSize(400, 300)

    -- Button kinds and states.
    local send = Style.Button(host, "Whisper", 100, function() end, "Sends one whisper.", { kind = "send" })
    check(send.glyph and send.kind == "send", "send button has its mark")
    send:SetEnabled(false, "in combat")
    check(not send:IsEnabled() and send.why == "in combat", "disabled with a reason")
    send:Fire("OnEnter")
    send:Fire("OnLeave")
    send:SetEnabled(true)
    local primary = Style.Button(host, "Go", 60, nil, nil, { kind = "primary", small = true })
    primary:SetOn(true)
    primary:Fire("OnEnter") primary:Fire("OnMouseDown") primary:Fire("OnMouseUp") primary:Fire("OnLeave")
    Style.Button(host, "Delete...", 80, nil, nil, { kind = "danger", glyph = "reset" }):SetKind("send")
    Style.IconButton(host, "gear", function() end, { "Settings" }):SetOn(true)

    -- Tabs from their strings, with a tag; views; chips; switch; meter.
    local tabs = Style.Tabs(host, { { key = "a", label = "Find" }, { key = "b", label = "Invited" } }, function() end)
    tabs:Select("a")
    tabs:SetTag("b", "3", "accent")
    check(tabs[2].tag and tabs[2].tag:IsShown(), "tab tag")
    tabs:SetTag("b", nil)
    local views = Style.Views(host, { { key = "x", label = "Auctions" }, { key = "y", label = "By item" } }, function() end)
    views:Select("y")
    check(views.selected == "y", "view switch")
    local chips = Style.Chips(host, { { key = "all", label = "All" }, { key = "changed", label = "Changed" } }, function() end)
    chips:Select("all")
    chips:SetCount("changed", 4)
    check(chips:IsOn("all") and not chips:IsOn("changed"), "chips")
    local toggled
    local sw = Style.Switch(host, function(on) toggled = on end)
    sw:Fire("OnClick", "LeftButton")
    check(toggled == true and sw:GetOn(), "switch")
    local meter = Style.Meter(host)
    meter:SetValue(3, 4)
    meter:SetUnknown()

    -- Card header, link, foot.
    local card = Style.Card(host, "Today")
    card.sub:SetText("12 items")
    card:SetLink("Open page", function() end)
    card:SetFoot("Seen 5 min ago")

    -- Glyphs, hatch, tags in every tone.
    for _, name in ipairs(Style.GLYPHS) do Style.Glyph(host, name, 14, "t2") end
    Style.Hatch(host:CreateTexture())
    for _, tone in ipairs({ "safe", "threshold", "danger", "unknown", "good", "bad", "compare", "accent", "plain" }) do
        local tag = Style.Tag(host):Set("x", tone)
        check(tag:GetWidth() >= 15, "tag " .. tone .. " sized")
    end

    -- A list with unknown cells, tag cells, a row send button and a selection.
    local holder = CreateFrame("Frame", nil, host)
    holder:SetSize(300, 200)
    local sent = 0
    local list = Style.List(holder, { colWidths = { 50, 50 }, search = true,
        rowButton = function(item) return { label = "Invite", kind = "send", enabled = item.n ~= 2, why = "pace",
            onClick = function() sent = sent + 1 end } end,
        selected = function(item) return item.n == 1 end })
    list:SetItems({ { text = "One", n = 1, cols = { ns.UNKNOWN, { tag = "lowest", tone = "good" } } },
        { text = "Two", n = 2, cols = { "12", "3" } } })
    local r1 = list.rows[1]
    check(r1.colTags[1] and r1.colTags[1]:IsShown() and r1.colTags[1]:GetText() == "?", "unknown cell is a ? tag")
    check(not (r1.cols[1] and r1.cols[1]:IsShown()), "unknown cell is never an empty string")
    check(r1.rowButton and r1.rowButton:IsShown() and r1.rowButton.kind == "send", "row send button")
    r1:Fire("OnClick", "LeftButton")
    check(sent == 0, "selecting a row never sends")
    r1.rowButton:Fire("OnClick", "LeftButton")
    check(sent == 1, "the row's send button sends once")
    check(not list.rows[2].rowButton:IsEnabled(), "row button off with its reason")
    check(Style.SortValue(ns.UNKNOWN) == nil and Style.SortValue({ tag = "?", tone = "unknown" }) == nil, "unknown sorts last")

    -- Notices: a window and an in-page one.
    local n = Style.Notice(nil, "Update", { tone = "accent" })
    n:Set({ headline = "New version", sub = "x", pages = { { key = "a", label = "A", blocks = { { heading = "h", text = "t" } } } },
        buttons = { { label = "OK", onClick = function() end } } })
    local flat = Style.Notice(nil, nil, { flat = true, parent = host, width = 300 })
    flat:Set({ headline = "Pages moved", tone = "unknown", buttons = { { label = "Got it" } } })
    check(flat:GetParent() == host and flat:IsShown(), "flat notice inside its page")

    -- The floating title bar.
    local piece = CreateFrame("Frame", nil, UIParent)
    piece:SetSize(200, 120)
    local locked, muted = false, false
    local hidden = false
    local bar = Style.FloatBar(piece, { page = "enemies", title = "Enemies nearby",
        switch = { glyph = "bell", offGlyph = "belloff", get = function() return not muted end, set = function(on) muted = not on end },
        lock = { get = function() return locked end, set = function(v) locked = v end },
        settings = "enemies", hide = function() hidden = true end })
    check(piece.floatBar == bar and bar:GetHeight() == Style.FLOAT_BAR, "float bar on the piece")
    bar.lock:Fire("OnClick", "LeftButton")
    check(locked == true, "lock")
    bar.switch:Fire("OnClick", "LeftButton")
    check(muted == true, "own switch")
    bar.hide:Fire("OnClick", "LeftButton")
    check(hidden, "hide")
    bar.gear:Fire("OnClick", "LeftButton")
    bar.home:Fire("OnClick", "LeftButton")
    bar.home:Fire("OnClick", "RightButton")
    bar:SetCount("3")
    bar:SetTitle("Enemies")

    -- Menus.
    Style.ContextMenu(send, { title = "Menu", items = { { label = "One", pick = function() end }, { header = "More" },
        { label = "Two", disabled = true, why = "not now" } } })
    Style.CloseContextMenu()
    Style.OpenDropdown(send, { { label = "A", selected = true, pick = function() end } })
    Style.CloseDropdown()
end

-- Every main window and floating piece, built in the current look.
local function buildAll(ns, label)
    local Nav = ns.Nav
    for _, page in ipairs(Nav.Pages()) do
        check(Nav.Open(page.key), label .. ": page " .. page.key .. " opens")
    end
    ns.Options.Open()
    slash("probe")
    -- Floating pieces: panel and flag (built at login), fishing HUD (pole),
    -- mini recruit window, craft tracker, the scan panel at the AH.
    check(TALODPanel and TALODFlag, label .. ": panel and flag")
    check(TALODFishingHUD and TALODFishingHUD:IsShown(), label .. ": fishing HUD")
    TALODDB.guildMiniShown = true
    ns.GuildUI.RefreshMini({})
    check(TALODGuildMini and TALODGuildMini:IsShown(), label .. ": mini recruit window")
    local _, recipe = next(ns.ProfessionData.recipes)
    ns.CraftTrackUI.Open(recipe)
    check(ns.CraftTrackUI.IsShown(), label .. ": craft tracker")
    function CanSendAuctionQuery() return true, true end
    function QueryAuctionItems() end
    function GetNumAuctionItems() return 0, 0 end
    function GetAuctionItemInfo() return nil end
    MOCK.FireEvent("AUCTION_HOUSE_SHOW")
    MOCK.RunTimers()
    check(ns.AHHelper.Panel() and ns.AHHelper.Panel():IsShown(), label .. ": scan panel")
    buildParts(ns)
    MOCK.Tick(1)
end

local function setupLook(classic, missing)
    if missing then hideMedia() end
    local ns = T.fishingSetup(11509, { db = { classicLook = classic or nil } })
    check(ns.Style.Look() == (classic and "classic" or "ledger"), "look applied at load: " .. tostring(ns.Style.Look()))
    check(ns.Style.HasMedia() == not missing, "media probe")
    return ns
end

scenarios.look_windows_ledger = function()
    local ns = setupLook(false)
    local Style = ns.Style
    buildAll(ns, "ledger")
    -- Ledger shapes: title bar 34 with the section name, black outer edge and a shadow.
    local f = Style.Window(nil, "Test", 400, 300, { settings = "general" })
    check(f.titleBar:GetHeight() == 33 and f.section and f.outerEdge and f.shadow, "ledger window shape")
    check(f.gear and f.header and f.SetStatus, "gear, header slot, status")
    f:SetStatus("3 enemies")
    f.header:Add(Style.Button(f, "Scan", 60, nil, nil, { kind = "send" }))
    check(Style.COLORS.window[1] ~= 0.055 and Style.HEX.muted == "|cff9da2ac", "ledger tokens")
    check(type(Style.FONTS.body) == "table", "client fonts made")
    check(Style.ROW == 20, "row 20")
end

scenarios.look_windows_classic = function()
    local ns = setupLook(true)
    local Style = ns.Style
    buildAll(ns, "classic")
    -- The classic look is today's, value for value.
    local f = Style.Window(nil, "Test", 400, 300)
    check(f.icon and not f.section and not f.outerEdge and not f.gear, "classic window shape")
    check(f.titleBar:GetHeight() == 38, "classic title bar 38")
    local c = Style.COLORS
    check(c.window[1] == 0.055 and c.titleBar[1] == 0.09 and c.border[1] == 0.24 and c.card[4] == 0.025
        and c.stripe[4] == 0.03 and c.bar[3] == 0.84 and c.muted[1] == 0.62, "classic colours")
    check(Style.HEX.muted == "|cff8a8a8a" and Style.HEX.good == "|cff40ff40" and Style.HEX.white == "|cffffffff", "classic hex")
    check(Style.FONTS.body == "GameFontHighlightSmall", "classic fonts are the old templates")
    local card = Style.Card(UIParent, "x")
    check(card.content._points[1][3] == -48, "classic card header 44")
end

-- The texture files missing (a /reload after an update that added them):
-- every window builds, nothing draws the files, unknown still reads "?".
local function missingMedia(classic)
    local ns = setupLook(classic, true)
    local Style = ns.Style
    buildAll(ns, classic and "classic, no media" or "ledger, no media")
    for _, w in ipairs(MOCK.frames) do
        local tex = w._texture
        if type(tex) == "string" and (tex:find("Glyphs.tga", 1, true) or tex:find("Hatch.tga", 1, true) or tex:find("Shadow.tga", 1, true)) then
            -- Only the probe's own hidden texture may have tried them.
            check(w._parent and not w._parent:IsShown(), "a missing file drawn: " .. tex)
        end
    end
    local tag = Style.Tag(UIParent):Set("", "unknown")
    check(tag:GetText() == "?" and sameColor(tag.text._color, ns.GetColor("unknown")), "unknown tag reads ? in the unknown tone")
    check(not tag.bg.hatched and tag.bg._colorTex and sameColor(tag.bg._colorTex, ns.GetColor("unknown")), "solid unknown fill")
    local g = Style.Glyph(UIParent, "send", 12, "accent")
    check(g.fallback and g.fallbackText:GetText() == ">", "send arrow falls back to >")
    local icon = Style.Glyph(UIParent, "fish", 16)
    check(icon:GetTexture():find("Icons", 1, true), "page icon falls back to the game's icon")
    local f = Style.Window(nil, "Test", 300, 200)
    check(not f.shadow, "no shadow without the file")
end

scenarios.look_media_missing_ledger = function() missingMedia(false) end
scenarios.look_media_missing_classic = function() missingMedia(true) end

-- Switching looks in place: tables keep their identity, values change.
scenarios.look_switch = function()
    local ns = boot(11509)
    local Style = ns.Style
    local window, hex = Style.COLORS.window, Style.HEX
    Style.SetLook("classic")
    check(Style.COLORS.window == window and window[1] == 0.055 and Style.HEX == hex, "classic in place")
    Style.SetLook("ledger")
    check(Style.COLORS.window == window and near(window[1], 0x0f / 255), "ledger in place")
    TALODDB.classicLook, TALODDB.textSize, TALODDB.compactRows = true, 13, true
    Style.ApplySettings()
    check(Style.Look() == "classic" and Style.ROW == 18 and Style.textSize == 13, "settings applied")
    TALODDB.classicLook, TALODDB.textSize, TALODDB.compactRows = false, 11, false
    Style.ApplySettings()
    check(Style.Look() == "ledger" and Style.ROW == 20 and Style.FONTS.body._fontSize == 11, "text size")
    check(Style.SetLook("nonsense") == "ledger", "unknown look name falls back")
end

-- The unknown tone exists in both palettes and never equals a safe one.
scenarios.look_unknown_tone = function()
    local ns = boot(16001)
    for _, cb in ipairs({ false, true }) do
        TALODDB.colorblind = cb
        local u = ns.GetColor("unknown")
        check(u and u ~= ns.COLORS.neutral, "unknown colour (colorblind " .. tostring(cb) .. ")")
        for _, other in ipairs({ "safe", "threshold", "danger" }) do
            check(not sameColor(u, ns.GetColor(other)), "unknown differs from " .. other)
        end
        check(ns.ColorCode("unknown"):match("^|cff%x%x%x%x%x%x$"), "colour code")
        check(sameColor(ns.Style.ToneColor("unknown"), u), "Style tone follows Core")
    end
    TALODDB.colorblind = false
    check(ns.ColorCode("unknown") == "|cffb9a0ff", "violet")
    TALODDB.colorblind = true
    check(ns.ColorCode("unknown") == "|cffecebf5", "colorblind: white")
    TALODDB.colorblind = false
    check(ns.UnknownText("? yd") == "|cffb9a0ff? yd|r", "UnknownText")
    check(ns.Utils.SortBy({ { k = ns.UNKNOWN }, { k = "b" }, { k = "a" } }, function(x) return x.k end)[3].k == ns.UNKNOWN,
        "SortBy puts unknown last")
end

-- Every unit read secret: no panel row, flag or plate shows a safe tone or a
-- number for range, health or the flag.
scenarios.look_all_secret = function()
    local ns = boot(16001, { secrets = true })
    MOCK.secretMode = true
    MOCK.secretRange = true
    local saved = UnitIsPVP
    UnitIsPVP = nil
    T.plateAdd("nameplate1", MOCK.Enemy({ level = 20, health = 900, healthMax = 2000,
        secret = { health = true, healthMax = true, combat = true, pvp = true, enemy = true, canAttack = true, reaction = true },
        buffs = { { opaque = true } } }))
    MOCK.Tick(0.3)
    local unknown, safe, threshold = ns.ColorCode("unknown"), ns.ColorCode("safe"), ns.ColorCode("threshold")
    local r = TALODPanel.rows[1]
    check(r and r:IsShown(), "row shown")
    local dist = r.dist:GetText()
    check(dist:find(unknown .. "? yd", 1, true) and not plain(dist):find("%d"), "range: unknown tone, no number: " .. dist)
    local det = r.detail
    local hp = det.hpText:GetText()
    check(hp:find(unknown .. "? HP", 1, true) and not plain(hp):find("%d"), "health: unknown tone, no number: " .. hp)
    local tags = det.tags:GetText()
    check(tags:find(unknown .. "PvP?", 1, true), "hidden flag tag in the unknown tone: " .. tags)
    -- Every "?" tag is inside an unknown-toned run.
    local rest = tags:gsub(unknown:gsub("|", "%%|") .. "[^|]*|r", "")
    check(not rest:find("?", 1, true), "a ? tag outside the unknown tone: " .. tags)
    for _, fs in ipairs({ r.dist, det.hpText, det.tags, r.info }) do
        local text = fs:GetText() or ""
        check(not text:find(safe, 1, true), "no safe tone: " .. text)
        check(not text:find(threshold .. "?", 1, true) and not text:find(threshold .. "PvP?", 1, true)
            and not text:find(threshold .. "@?", 1, true), "no ? in the threshold tone: " .. text)
    end
    if r.accent:IsShown() then
        check(not sameColor(r.accent._colorTex, ns.GetColor("safe")), "row edge not safe")
    end
    -- The flag indicator: "PvP: ?" in the unknown tone, never "PvP off".
    MOCK.Tick(0.3)
    local flag = TALODFlag.text:GetText()
    check(flag:find(unknown .. "PvP: ?", 1, true) and not flag:find("off"), "flag: " .. flag)
    -- A list cell the game hides: the unknown tag.
    local tag = ns.Style.Tag(UIParent):Set("", "unknown")
    check(tag:GetText() == "?" and sameColor(tag.text._color, ns.GetColor("unknown")), "unknown tag")
    TALODPanel.rows[1]:Fire("OnEnter")
    -- Home: the enemy line says "?" and "PvP: ?", never a number or a safe
    -- tone; the page list's count tag is the unknown "?".
    ns.Nav.ShowHome()
    local line = TALODMainMenu.lineByKey.enemies.status:GetText()
    check(line:find(unknown .. "PvP: ?", 1, true) and not plain(line):find("%d"), "Home enemy line: " .. line)
    for key, l in pairs(TALODMainMenu.lineByKey) do
        check(not (l.status:GetText() or ""):find(safe, 1, true), "Home line " .. key .. " without a safe tone")
    end
    local count = TALODMainMenu.navRail.buttons.enemies.tag
    check(count:IsShown() and count:GetText() == "?" and count.tone == "unknown", "page list tag: unknown")
    UnitIsPVP = saved
end
