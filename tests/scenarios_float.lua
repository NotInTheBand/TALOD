-- The floating pieces (Enemies nearby panel, fishing HUD, mini recruit
-- window, craft tracker, Auction House scan panel): one floating title bar
-- (TALOD button, the piece's switch, lock, settings, hide) in both looks and
-- without the texture files; secure buttons untouched; showing or hiding a
-- piece with secure buttons waits for combat to end; unknown stays unknown;
-- center text and sound only for danger; chat links where the client has them.
local scenarios, T = ...
local check, plateAdd, printed = T.check, T.plateAdd, T.printed

local SWORD, SHIELD, POLE = 2000, 2001, 6256
local MEDIA = { "Glyphs.tga", "Hatch.tga", "Shadow.tga" }

local function plain(text) return (tostring(text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
local function near(a, b) return math.abs((a or -1) - (b or -2)) < 0.002 end
local function sameColor(a, b) return a and b and near(a[1], b[1]) and near(a[2], b[2]) and near(a[3], b[3]) end

local function equip(mh, oh)
    MOCK.equippedIDs[17] = oh
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 17, oh == nil)
    MOCK.equippedIDs[16] = mh
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 16, mh == nil)
    MOCK.Tick(1.2)
end

-- Pole in hand with a sword + shield remembered (so the swap buttons exist),
-- in a guild with the invite right.
local function setup(opts)
    opts = opts or {}
    if opts.missing then
        for _, f in ipairs(MEDIA) do
            MOCK.missingFiles["Interface\\AddOns\\" .. ADDON_NAME .. "\\media\\textures\\" .. f] = true
        end
    end
    MOCK.SetGuild()
    MOCK.items[SWORD] = { classID = 2, subclassID = 7, equipLoc = "INVTYPE_WEAPON" }
    MOCK.items[SHIELD] = { classID = 4, subclassID = 6, equipLoc = "INVTYPE_SHIELD" }
    local ns = T.fishingSetup(opts.iface or 11509, { db = { classicLook = opts.classic or nil }, secrets = opts.secrets })
    equip(SWORD, SHIELD)
    MOCK.equippedIDs[17] = nil
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 17, true)
    MOCK.Tick(0.3)
    equip(POLE, nil)
    MOCK.Tick(1.1)
    return ns
end

-- The three pieces that are not up at login: mini window, tracker, scan panel.
local function buildRest(ns)
    TALODDB.guildMiniShown = true
    ns.GuildUI.RefreshMini({})
    local _, recipe = next(ns.ProfessionData.recipes)
    ns.CraftTrackUI.Open(recipe)
    function CanSendAuctionQuery() return true, true end
    function QueryAuctionItems() end
    function GetNumAuctionItems() return 0, 0 end
    function GetAuctionItemInfo() return nil end
    MOCK.FireEvent("AUCTION_HOUSE_SHOW")
    MOCK.RunTimers()
    MOCK.Tick(1)
end

local function pieces()
    return { panel = TALODPanel, hud = TALODFishingHUD, mini = TALODGuildMini, tracker = TALODCraftTrack, scan = TALODAHPanel }
end

-- What the TALOD button of each piece opens.
local PAGE = { panel = { "enemies" }, hud = { "fishing" }, mini = { "recruit", "find" }, tracker = { "prof", "profit" },
    scan = { "ah" } }
local SECTION = { panel = "enemies", hud = "fishing", mini = "guild", tracker = "professions", scan = "ah" }

local function buildAndCheck(label, opts)
    local ns = setup(opts)
    local Style = ns.Style
    check(Style.Look() == (opts.classic and "classic" or "ledger"), label .. ": look")
    check(Style.HasMedia() == not opts.missing, label .. ": media probe")
    buildRest(ns)
    for key, f in pairs(pieces()) do
        check(f and f:IsShown(), label .. ": " .. key .. " shown")
        local bar = f and f.floatBar
        check(bar and bar:GetHeight() == Style.FLOAT_BAR, label .. ": " .. key .. " has the floating title bar")
        check(bar and bar.home and bar.gear and bar.hide, label .. ": " .. key .. " TALOD button, gear, hide")
        -- The hud surface with its black outer edge (ledger).
        check(f.surface and (opts.classic or f.outerEdge), label .. ": " .. key .. " hud surface")
    end
    local P, H = TALODPanel.floatBar, TALODFishingHUD.floatBar
    check(P.switch and P.lock and H.lock and not H.switch, label .. ": panel mute + lock, HUD lock")
    -- The chest and coin icons are gone (their pages are in the page menu).
    for _, child in ipairs(MOCK.frames) do
        if child._parent == TALODPanel and child._kind == "Button" and child.icon then
            local tex = tostring(child.icon:GetTexture() or "")
            check(not tex:find("Chest") and not tex:find("Coin"), label .. ": no chest or coin icon on the panel")
        end
    end
    -- The PvP flag: a tag (ledger) and its string.
    check(TALODFlag.text:GetText() ~= "" and (opts.classic or TALODFlag.tag), label .. ": flag tag and string")
    -- Without the files nothing draws them.
    if opts.missing then
        for _, w in ipairs(MOCK.frames) do
            local tex = w._texture
            if type(tex) == "string" and (tex:find("Glyphs.tga", 1, true) or tex:find("Hatch.tga", 1, true) or tex:find("Shadow.tga", 1, true)) then
                check(w._parent and not w._parent:IsShown(), label .. ": a missing file drawn: " .. tex)
            end
        end
    end
    MOCK.Tick(1)
    return ns
end

scenarios.float_pieces_ledger = function() buildAndCheck("ledger", {}) end
scenarios.float_pieces_classic = function() buildAndCheck("classic", { classic = true }) end
scenarios.float_pieces_media_missing = function() buildAndCheck("no media", { missing = true }) end
scenarios.float_pieces_media_missing_classic = function() buildAndCheck("classic, no media", { missing = true, classic = true }) end

-- The TALOD button opens this piece's page; right-click lists the pages;
-- the gear opens this piece's Settings section.
scenarios.float_talod_button = function()
    local ns = setup({})
    buildRest(ns)
    local Nav, Style = ns.Nav, ns.Style
    local went, menu, section
    local go = Nav.Go
    Nav.Go = function(page, tab, ...) went = { page, tab } return go(page, tab, ...) end
    local cm = Style.ContextMenu
    Style.ContextMenu = function(owner, spec) menu = spec return cm(owner, spec) end
    local os = Style.OpenSettings
    Style.OpenSettings = function(s) section = s end
    for key, f in pairs(pieces()) do
        went, menu, section = nil, nil, nil
        f.floatBar.home:Fire("OnClick", "LeftButton")
        check(went and went[1] == PAGE[key][1] and went[2] == PAGE[key][2],
            key .. ": opens " .. table.concat(PAGE[key], "/") .. ", got " .. tostring(went and went[1]) .. "/" .. tostring(went and went[2]))
        f.floatBar.home:Fire("OnClick", "RightButton")
        check(menu and menu.items and #menu.items >= 10, key .. ": page menu")
        local labels, selected = {}, nil
        for _, item in ipairs(menu and menu.items or {}) do
            labels[item.label] = item
            if item.selected then selected = item.label end
        end
        for _, page in ipairs(Nav.Pages()) do check(labels[page.label], key .. ": menu lists " .. page.label) end
        check(selected == Nav.Page(PAGE[key][1]).label, key .. ": its own page marked in the menu")
        went = nil
        labels["Gold"].pick()
        check(went and went[1] == "gold", key .. ": a pick opens that page")
        Style.CloseContextMenu()
        f.floatBar.gear:Fire("OnClick", "LeftButton")
        check(section == SECTION[key], key .. ": gear opens Settings at " .. SECTION[key] .. ", got " .. tostring(section))
    end
    Nav.Go, Style.ContextMenu, Style.OpenSettings = go, cm, os
end

-- The switch, lock and hide on each piece do what Home and Settings do, and
-- each quick switch is bound once, as declared.
scenarios.float_switches = function()
    local binds = {}
    local ns = setup({})
    local O = ns.Options
    buildRest(ns)
    for key, b in pairs(O.Bindings()) do
        for where, kind in pairs(b) do
            if where:find("^float/") then binds[key .. "|" .. kind .. "|" .. where] = true end
        end
    end
    for _, b in ipairs({ "alertsEnabled|quick|float/panel", "panelLocked|quick|float/panel", "panelShown|quick|float/panel",
        "fishHudLocked|quick|float/hud", "fishHud|quick|float/hud", "guildMiniShown|quick|float/mini" }) do
        check(binds[b], "bound: " .. b)
        binds[b] = nil
    end
    check(next(binds) == nil, "nothing else bound on a floating piece: " .. tostring(next(binds)))

    local P = TALODPanel.floatBar
    P.switch:Fire("OnClick", "LeftButton")
    check(TALODDB.alertsEnabled == false and P.switch.glyph.glyph == "belloff" and P.switch.glyph.tone == "threshold", "mute")
    P.switch:Fire("OnClick", "LeftButton")
    check(TALODDB.alertsEnabled == true and P.switch.glyph.glyph == "bell", "alerts back on")
    local locked = TALODDB.panelLocked
    P.lock:Fire("OnClick", "LeftButton")
    check(TALODDB.panelLocked == not locked and P.lock.glyph.glyph == (TALODDB.panelLocked and "lock" or "unlock"), "panel lock")
    P.lock:Fire("OnEnter")
    local H = TALODFishingHUD.floatBar
    local hudLocked = TALODDB.fishHudLocked and true or false
    H.lock:Fire("OnClick", "LeftButton")
    check((TALODDB.fishHudLocked and true or false) == not hudLocked, "HUD lock")

    -- Hide: out of combat at once; Home's switch shows them again.
    P.hide:Fire("OnClick", "LeftButton")
    check(TALODDB.panelShown == false and not TALODPanel:IsShown(), "panel hidden")
    check(ns.Nav.SetPiece("panel", true) == true and TALODDB.panelShown == true, "Home brings it back")
    MOCK.Tick(0.3)
    check(TALODPanel:IsShown(), "panel shown again")
    H.hide:Fire("OnClick", "LeftButton")
    MOCK.Tick(1.1)
    check(TALODDB.fishHud == false and not TALODFishingHUD:IsShown(), "HUD hidden")
    TALODGuildMini.floatBar.hide:Fire("OnClick", "LeftButton")
    check(TALODDB.guildMiniShown == false and not TALODGuildMini:IsShown(), "mini window hidden")
    TALODCraftTrack.floatBar.hide:Fire("OnClick", "LeftButton")
    check(not TALODCraftTrack:IsShown(), "tracker hidden")
    TALODAHPanel.floatBar.hide:Fire("OnClick", "LeftButton")
    check(not TALODAHPanel:IsShown() and TALODDB.ahHelper ~= false, "scan panel hidden for this visit only")
end

-- Secure buttons keep their names, parents, templates and anchors through
-- the bars being built and redrawn (look switch, lock, mute, refreshes).
local function secureSnapshot()
    local out = {}
    for _, w in ipairs(MOCK.frames) do
        local name = w._name
        -- Search next is named through _G (a macro clicks it by that name).
        if w == TALODAHNextButton then name = "TALODAHNextButton" end
        if w._template == "SecureActionButtonTemplate" or name == "TALODAHNextButton" or name == "TALODRecruitStep" then
            local pts = {}
            for i, p in ipairs(w._points) do
                local parts = {}
                for j = 1, 5 do parts[j] = tostring(p[j]) end
                pts[i] = table.concat(parts, ",")
            end
            out[#out + 1] = { w = w, name = name, parent = w._parent, template = w._template, points = table.concat(pts, ";"),
                all = w._allPoints }
        end
    end
    return out
end

scenarios.float_secure_untouched = function()
    local ns = setup({})
    buildRest(ns)
    -- An enemy in view: the panel's target overlay appears over row 1.
    plateAdd("nameplate1", MOCK.Enemy({ level = 30 }))
    MOCK.Tick(0.3)
    -- Record SetAllPoints on the secure buttons (the mock does not).
    for _, w in ipairs(MOCK.frames) do
        if w._template == "SecureActionButtonTemplate" then
            w.SetAllPoints = function(self, rel) self._allPoints = rel end
            w.row = nil
        end
    end
    MOCK.Tick(1.1)
    local names = {}
    for _, s in ipairs(secureSnapshot()) do if s.name then names[s.name] = s end end
    for _, n in ipairs({ "TALODFishingSwapButton", "TALODAHNextButton", "TALODRecruitStep" }) do
        check(names[n], n .. " exists under its name")
    end
    check(names.TALODFishingSwapButton.parent == UIParent and names.TALODFishingSwapButton.template == "SecureActionButtonTemplate",
        "swap button: parent and template")
    local next = TALODAHNextButton
    check(next._parent == TALODAHPanel and next._points[1][1] == "TOPLEFT" and next._points[1][2] == 14 and next._points[1][3] == -168,
        "Search next keeps its place on the scan panel: " .. tostring(next._points[1] and next._points[1][3]))
    local overlay
    for _, w in ipairs(MOCK.frames) do
        if w._template == "SecureActionButtonTemplate" and w._name == nil and w:GetAttribute("type") == "target" then overlay = w end
    end
    check(overlay and overlay._parent == UIParent and overlay._allPoints == TALODPanel.rows[1], "target overlay anchored to its row")
    for key, rowKey in pairs({ TALODFishingWeaponRowButton = "weapon", TALODFishingLureAgainButton = "lure" }) do
        local b = _G[key]
        if b and b:IsShown() then
            check(b._parent == UIParent and b._allPoints == ns.FishingUI.HUDRowByKey(rowKey), key .. " anchored to the HUD's " .. rowKey .. " row")
        end
    end

    local before = secureSnapshot()
    -- Redraw every bar: switch looks, flip lock and mute, refresh.
    ns.Style.SetLook("classic")
    ns.Refresh()
    ns.Style.SetLook("ledger")
    for _, f in pairs(pieces()) do f.floatBar:Refresh() end
    TALODPanel.floatBar.switch:Fire("OnClick", "LeftButton")
    TALODPanel.floatBar.switch:Fire("OnClick", "LeftButton")
    TALODPanel.floatBar.lock:Fire("OnClick", "LeftButton")
    TALODFishingHUD.floatBar.lock:Fire("OnClick", "LeftButton")
    ns.Refresh()
    MOCK.Tick(1.1)
    local after = secureSnapshot()
    check(#after == #before, "no secure button added or lost: " .. #before .. " -> " .. #after)
    for i, b in ipairs(before) do
        local a = after[i]
        check(a and a.w == b.w and a.name == b.name and a.parent == b.parent and a.template == b.template,
            "secure button " .. tostring(b.name) .. ": same frame, name, parent, template")
        check(a and a.points == b.points and a.all == b.all, "secure button " .. tostring(b.name) .. ": same anchor")
    end
end

-- Showing or hiding the panel or the HUD in combat waits for combat to end,
-- and says so; the other pieces (no secure buttons) do not wait.
scenarios.float_combat_waits = function()
    local ns = setup({})
    buildRest(ns)
    MOCK.prints = {}
    MOCK.lockdown = true
    MOCK.FireEvent("PLAYER_REGEN_DISABLED")
    TALODPanel.floatBar.hide:Fire("OnClick", "LeftButton")
    check(TALODDB.panelShown == true and ns.Nav.PiecePending("panel") == false, "panel: waits")
    check(printed("Enemies nearby panel: hides when combat ends"), "panel: says so")
    TALODFishingHUD.floatBar.hide:Fire("OnClick", "LeftButton")
    check(TALODDB.fishHud == true and ns.Nav.PiecePending("hud") == false, "HUD: waits")
    check(printed("Fishing HUD: hides when combat ends"), "HUD: says so")
    -- Home's switch in combat: showing waits too.
    check(ns.Nav.SetPiece("flag", false) == true, "the flag (no secure buttons) does not wait")
    MOCK.lockdown = false
    MOCK.FireEvent("PLAYER_REGEN_ENABLED")
    MOCK.Tick(1.1)
    check(TALODDB.panelShown == false and not TALODPanel:IsShown(), "panel hidden once combat ended")
    check(TALODDB.fishHud == false and not TALODFishingHUD:IsShown(), "HUD hidden once combat ended")
    MOCK.lockdown = true
    check(ns.Nav.SetPiece("panel", true) == "wait" and TALODDB.panelShown == false, "showing waits as well")
    MOCK.lockdown = false
    MOCK.FireEvent("PLAYER_REGEN_ENABLED")
    check(TALODDB.panelShown == true, "shown after combat")
end

-- Every unit read secret: the panel's rows, edge, health and count show the
-- unknown tone, never a safe tone or a number; the HUD band is violet, not red.
local function allSecret(missing)
    local ns = setup({ iface = 16001, secrets = true, missing = missing })
    MOCK.secretMode = true
    MOCK.secretRange = true
    local saved = UnitIsPVP
    UnitIsPVP = nil
    plateAdd("nameplate1", MOCK.Enemy({ level = 20, health = 900, healthMax = 2000,
        secret = { health = true, healthMax = true, combat = true, pvp = true, enemy = true, canAttack = true, reaction = true } }))
    MOCK.Tick(0.3) MOCK.Tick(1.1)
    local unknown, safe = ns.ColorCode("unknown"), ns.ColorCode("safe")
    local r = TALODPanel.rows[1]
    check(r and r:IsShown() and r.edgeTone == "unknown", "row edge: unknown")
    if missing then
        check(r.accent._colorTex and sameColor(r.accent._colorTex, ns.GetColor("unknown")) and not r.accent.hatched,
            "no hatch file: a solid unknown edge")
    else
        check(r.accent.hatched and sameColor(r.accent._vertex, ns.GetColor("unknown")), "dashed (hatched) unknown edge")
    end
    local det = r.detail
    check(det.hatch:IsShown() and det.hpText:GetText():find(unknown .. "? HP", 1, true), "health: hatch and ? HP")
    check(missing and not det.hatch.hatched or (not missing and det.hatch.hatched), "hatch file used only when present")
    local texts = { r.dist:GetText(), det.hpText:GetText(), det.tags:GetText(), r.info:GetText(), TALODPanel.count:GetText() }
    for _, text in ipairs(texts) do
        check(not tostring(text):find(safe, 1, true), "no safe tone: " .. tostring(text))
    end
    check(not plain(r.dist:GetText()):find("%d") and not plain(det.hpText:GetText()):find("%d"), "no number for range or health")
    local count = TALODPanel.count:GetText()
    check(count:find(unknown .. "1 ?", 1, true) and not plain(count):find("^0"), "count: 1 ?, never 0: " .. count)
    -- The flag: the unknown tag and "PvP: ?".
    check(TALODFlag.text:GetText():find(unknown .. "PvP: ?", 1, true), "flag string")
    if TALODFlag.tag then check(TALODFlag.tag:GetText() == "?" and TALODFlag.tag.tone == "unknown", "flag tag: ?") end
    -- The HUD: pole in hand, hostility hidden: the band is violet, never red.
    check(ns.FishingUI.PoleDanger() == "unknown" and TALODFishingHUD.bandTone == "unknown", "HUD band: unknown")
    check(TALODFishingHUD.bandTag.tone == "unknown", "HUD band tag: unknown")
    UnitIsPVP = saved
end

scenarios.float_all_secret = function() allSecret(false) end
scenarios.float_all_secret_media_missing = function() allSecret(true) end

-- The panel's rows: kill on sight = red edge; a row that left view fades and
-- says "out of view"; the HUD's red band with an enemy in view.
scenarios.float_rows_and_band = function()
    local ns = setup({})
    local e = MOCK.Enemy({ level = 30, name = "Grukk", guid = "Player-1-K" })
    plateAdd("nameplate1", e)
    MOCK.Tick(0.3)
    local key = ns.Spotter.Sorted()[1].key
    ns.Journal.SetList(key, "kos")
    MOCK.Tick(1.1)
    local r = TALODPanel.rows[1]
    check(r.edgeTone == "danger" and sameColor(r.accent._colorTex, ns.GetColor("danger")), "kill on sight: red edge")
    check(TALODFishingHUD.bandTone == "danger" and TALODFishingHUD.band:IsShown()
        and TALODFishingHUD.bandTag:GetText() == "Pole in hands", "HUD: red band, pole in hands")
    check(TALODPanel.count:GetText():find(ns.ColorCode("danger") .. "1", 1, true), "count in the danger tone")
    T.plateRemove("nameplate1")
    MOCK.Tick(1.1)
    r = TALODPanel.rows[1]
    if r and r:IsShown() and r.entry and not r.entry.unit then
        check(plain(r.dist:GetText()) == "out of view" and r:GetAlpha() == 0.55, "left view: faded, out of view")
    end
    check(TALODFishingHUD.bandTone == nil and not TALODFishingHUD.band:IsShown(), "no band without an enemy")
end

-- Center text: danger only, and a lower line never replaces a higher one.
scenarios.float_alert_loudness = function()
    local ns = setup({})
    local A = ns.Alerts
    check(A.Show("loud danger", ns.GetColor("danger"), true) == true, "danger shows")
    check(A.Show("plain", ns.GetColor("threshold"), false) == false and TALODAlertText.text:GetText() == "loud danger",
        "a lower line does not replace it")
    check(A.Show("plain danger", ns.GetColor("danger"), false) == false, "a plain danger line does not replace a loud one")
    MOCK.Tick(5)
    check(A.Show("plain danger", ns.GetColor("danger"), false) == true, "shows once the loud one is gone")
    check(A.Show("loud again", ns.GetColor("danger"), true) == true, "a higher one replaces it")
    -- A normal enemy alert is in the danger tone (ledger).
    TALODAlertText:Hide()
    A.Reset()
    plateAdd("nameplate1", MOCK.Enemy({ level = 1, name = "Lowbie", guid = "Player-1-L" }))
    if TALODAlertText:IsShown() then
        check(sameColor(TALODAlertText.text._color, ns.GetColor("danger")), "enemy line in the danger tone")
    end
end

-- Chat links: only where the client has addon links; a click opens the page.
scenarios.float_chat_links = function()
    LinkTypes = { addon = function() end }
    local refs = 0
    function SetItemRef() refs = refs + 1 end
    function IsModifiedClick() return false end
    local ns = T.boot(11509)
    local U = ns.Utils
    check(U.LinksSupported(), "links supported here")
    local link = U.PlaceLink("settings/data", "Settings › Data")
    check(link:find("|Haddon:" .. ns.NAME .. ":go:settings/data|h[Settings › Data]|h", 1, true), "link text: " .. link)
    local went
    local go = ns.Nav.Go
    ns.Nav.Go = function(page, tab, view) went = { page, tab, view } return go(page, tab, view) end
    SetItemRef("addon:" .. ns.NAME .. ":go:settings/data", "[Settings › Data]", "LeftButton")
    check(refs == 1 and went and went[1] == "settings" and went[2] == "data", "a click opens Settings › Data")
    went = nil
    SetItemRef("addon:Other:go:settings/data", "x", "LeftButton")
    check(went == nil, "another addon's link is left alone")
    function IsModifiedClick() return true end
    SetItemRef("addon:" .. ns.NAME .. ":go:prof/profit", "x", "LeftButton")
    check(went == nil, "a modified click is left to the game")
    function IsModifiedClick() return false end
    SetItemRef("addon:" .. ns.NAME .. ":go:members/roster#Activity", "x", "LeftButton")
    check(went and went[1] == "members" and went[2] == "roster" and went[3] == "Activity", "page, tab and view")
    -- A real line: the minimap button hidden names Home.
    MOCK.prints = {}
    T.slash("minimap")
    check(printed("|Haddon:" .. ns.NAME .. ":go:home|h"), "the minimap line links to Home")
    ns.Nav.Go = go
end

scenarios.float_chat_links_unsupported = function()
    LinkTypes = nil
    local ns = T.boot(11509)
    check(not ns.Utils.LinksSupported() and ns.Utils.PlaceLink("settings/data", "x") == "", "no link without addon links")
    MOCK.prints = {}
    T.slash("minimap")
    check(printed("minimap button hidden") and not printed("|H"), "the line stays as it was")
end
