-- A /reload after the update: the three texture files it adds are missing
-- until the game restarts. Every page, tab and view, Home, every Settings
-- section and the floating pieces build; no glyph is left blank (a game icon
-- or a text symbol stands in) and nothing draws the missing files. The saved
-- data side of an update is tests/cross_version.py.
local scenarios, T = ...
local check, slash = T.check, T.slash

local MEDIA = { "Glyphs.tga", "Hatch.tga", "Shadow.tga" }

local function hideMedia()
    for _, f in ipairs(MEDIA) do
        MOCK.missingFiles["Interface\\AddOns\\" .. ADDON_NAME .. "\\media\\textures\\" .. f] = true
    end
end

local function isMedia(tex)
    if type(tex) ~= "string" then return false end
    for _, f in ipairs(MEDIA) do if tex:find(f, 1, true) then return true end end
    return false
end

-- Glyphs that fell back: each shows a game icon or a text symbol.
local function checkGlyphs(label)
    local n = 0
    for _, w in ipairs(MOCK.frames) do
        if w.fallback and w.fallbackText and w.glyph then
            n = n + 1
            local icon = w:GetTexture() and w:GetAlpha() > 0
            local text = (w.fallbackText:GetText() or "") ~= ""
            check(icon or text, label .. ": glyph " .. tostring(w.glyph) .. " left blank")
        end
        check(not isMedia(w._texture) or (w._parent and not w._parent:IsShown()),
            label .. ": a missing file drawn: " .. tostring(w._texture))
    end
    return n
end

local function everyPlace(ns, label)
    local Nav = ns.Nav
    check(Nav.Go("home"), label .. ": Home")
    for _, page in ipairs(Nav.PAGES) do
        check(Nav.Go(page.key), label .. ": page " .. page.key)
        for _, tab in ipairs(page.tabs) do
            check(Nav.Go(page.key, tab.key), label .. ": " .. page.key .. "/" .. tab.key)
            for _, v in ipairs(tab.views or {}) do
                check(Nav.Go(page.key, tab.key, v), label .. ": " .. page.key .. "/" .. tab.key .. "#" .. v)
            end
        end
        for _, v in ipairs(page.views or {}) do check(Nav.Go(page.key, nil, v), label .. ": " .. page.key .. "#" .. v) end
    end
    for _, s in ipairs(ns.Cmd.SECTIONS) do ns.Options.OpenSection(s.key) end
    Nav.OpenGoTo("fish")
    -- Floating pieces.
    TALODDB.guildMiniShown = true
    ns.GuildUI.RefreshMini({})
    check(TALODGuildMini and TALODGuildMini:IsShown(), label .. ": mini recruit window")
    local _, recipe = next(ns.ProfessionData.recipes)
    ns.CraftTrackUI.Open(recipe)
    check(TALODPanel and TALODFlag and TALODFishingHUD, label .. ": panel, flag, fishing HUD")
    MOCK.Tick(1)
end

local function noMedia(classic)
    hideMedia()
    local ns = T.fishingSetup(11509, { db = { classicLook = classic or nil } })
    check(not ns.Style.HasMedia(), "the probe sees the files missing")
    local label = classic and "classic, no media" or "ledger, no media"
    everyPlace(ns, label)
    local n = checkGlyphs(label)
    check(n > 20, label .. ": glyphs fell back (" .. n .. ")")
    -- The safety tags still read by their words and tone, without the shapes.
    for _, tone in ipairs({ "safe", "threshold", "danger" }) do
        local tag = ns.Style.Tag(UIParent):Set("Kill on sight", tone)
        check(tag:GetText() == "Kill on sight" and not (tag.shape and tag.shape:IsShown()), label .. ": " .. tone .. " tag")
    end
    -- Every glyph name has a stand-in.
    for _, name in ipairs(ns.Style.GLYPHS) do
        local g = ns.Style.Glyph(UIParent, name, 14)
        check(g.fallback and ((g:GetTexture() and g:GetAlpha() > 0) or g.fallbackText:GetText() ~= ""),
            label .. ": glyph " .. name .. " has no stand-in")
    end
end

scenarios.reload_media_missing_every_place = function() noMedia(false) end
scenarios.reload_media_missing_every_place_classic = function() noMedia(true) end
