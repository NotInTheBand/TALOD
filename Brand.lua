-- The addon's name, in one place. Loads first: every other file builds its
-- shown name, frame names, popup keys, slash commands, saved-data global and
-- addon-message prefix from these values.
--
-- Renaming the addon: change NAME below (slash commands are in Commands.lua), then the
-- few things Lua cannot reach:
--   * the addon folder and the .toc file name (the game loads by folder name),
--   * in the .toc: "## Title", "## SavedVariables" (= DB_NAME) and
--     "## AddonCompartmentFunc" (= NAME .. "_OnAddonCompartmentClick"),
--   * tools/build_release.py / .pkgmeta read the folder; the viewers read this file,
--   * Bindings.xml: the binding name (= BINDING_STEP), its header (= NAME:upper()) and
--     the frame it clicks (= FRAME .. "RecruitStep"),
--   * the archive addon (ARCHIVE_ADDON below): its folder in the repository, its .toc
--     file name, "## Dependencies" (= NAME), "## SavedVariables" (= ARCHIVE_DB), and
--     .pkgmeta's move-folders line.
--   * media/textures: every file name starts with NAME ("<NAME>-icon-64.png", ...), and the
--     .toc's "## IconTexture" names the 128 icon by folder and file.
-- The saved data does not follow a rename: the game names the SavedVariables
-- file after the folder and the global after DB_NAME.
-- Frame names change too, so players' "/click <old>AHNextButton" macros stop working,
-- and the addon-message prefix changes, so guild sharing with older versions stops.

local ADDON_NAME, ns = ...

-- Letters and digits only: it becomes part of global names and the message prefix.
ns.NAME = "TALOD"
ns.COLOR = "ff7f3f"

-- The brand art. The path keeps ".png": the game finds a PNG only by its full name.
-- Crest and banner art sit at the top-left of a power-of-two canvas: draw them at their
-- aspect (width = height * aspect) with their texcoords, or they stretch or show empty
-- padding (Style.BrandTexture does both).
ns.MEDIA = "Interface\\AddOns\\" .. ADDON_NAME .. "\\media\\textures\\"
ns.TEX = {
    icon64      = ns.MEDIA .. ns.NAME .. "-icon-64.png",
    icon128     = ns.MEDIA .. ns.NAME .. "-icon-128.png",
    icon256     = ns.MEDIA .. ns.NAME .. "-icon-256.png",
    crest       = { path = ns.MEDIA .. ns.NAME .. "-crest-512.png",        coords = { 0, 0.9004, 0, 1 }, aspect = 0.9004 },
    crestPhrase = { path = ns.MEDIA .. ns.NAME .. "-crest-phrase-512.png", coords = { 0, 0.8223, 0, 1 }, aspect = 0.8223 },
    banner      = { path = ns.MEDIA .. ns.NAME .. "-banner-1024.png",      coords = { 0, 1, 0, 0.6543 },      aspect = 3.0567 },
}
ns.ICON_TAG = "|T" .. ns.TEX.icon64 .. ":14:14|t"               -- inline icon for chat
ns.ART_COLOR = "d4a537"                                         -- the gold of the art (wordmark, rim)
ns.TAGLINE = "That's A Lot Of Data"                             -- what the name stands for

ns.TITLE = "|cff" .. ns.COLOR .. ns.NAME .. "|r"                -- colored, for chat and window titles
ns.FRAME = ns.NAME                                              -- prefix of every global frame name
ns.DB_NAME = ns.NAME .. "DB"                                    -- SavedVariables global (TOC must match)
ns.SLASH_KEY = ns.NAME:upper()                                  -- SlashCmdList key, SLASH_<KEY>n globals
ns.POPUP = ns.NAME:upper() .. "_"                               -- StaticPopupDialogs key prefix
ns.COMPARTMENT_FUNC = ns.NAME .. "_OnAddonCompartmentClick"     -- TOC AddonCompartmentFunc must match
ns.COMM_PREFIX = (ns.NAME .. "G"):sub(1, 16)                    -- guild sharing; the game allows 16 bytes
ns.VERSION_PREFIX = (ns.NAME .. "V"):sub(1, 16)                 -- version check (Version.lua)
ns.VERSION_CHANNEL = ns.NAME .. "Version"                       -- hidden custom channel the version check talks on
ns.PROJECT_URL = "https://www.curseforge.com/wow/addons/" .. ns.NAME:lower()   -- download page (must match the CurseForge project)
ns.PROBE_PREFIX = ns.NAME:sub(1, 16)                            -- /talod probe's registration test
ns.ARCHIVE_ADDON = ns.NAME .. "_Archive"                        -- load-on-demand archive addon (folder and TOC must match)
ns.ARCHIVE_DB = ns.NAME .. "ArchiveDB"                          -- its SavedVariables global (its TOC must match)
ns.BINDING_STEP = ns.NAME:upper() .. "_RECRUIT_STEP"            -- key binding name (Bindings.xml must match)

-- The saved data. Every module reads it through this, never by its global name.
function ns.DB() return _G[ns.DB_NAME] end
function ns.SetDB(t) _G[ns.DB_NAME] = t return t end
