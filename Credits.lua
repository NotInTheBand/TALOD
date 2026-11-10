-- TALOD - Credits: who made it, the Discord, how to send gold if you want
-- to, and the work it builds on; the About page shows it on its Credits tab.
-- Copy buttons go through ns.Utils.Copy (addons cannot write the clipboard).

local ADDON_NAME, ns = ...
local Style, Utils = ns.Style, ns.Utils
local HEX, COLORS = Style.HEX, Style.COLORS

local UI = {}
ns.Credits = UI

local AUTHOR = "NotInTheBand"
local DISCORD = "https://discord.gg/2FYCFyRczN"
-- Gold goes by in-game mail; mail does not cross factions, so only Alliance
-- characters on the same PvP realm can send it.
local DONATE = { name = "Send Coin", faction = "Alliance", ruleset = "PvP realm" }
UI.AUTHOR, UI.DISCORD, UI.DONATE = AUTHOR, DISCORD, DONATE

-- One reading column, centered: on a wide window the rows would otherwise
-- stretch and leave each copy button far from what it copies.
local MAX_WIDTH = 720
local GAP = 10

-- label | value ........ [button]
local function Row(parent, y, label, value, button)
    local l = Style.Text(parent, "GameFontNormalSmall")
    l:SetPoint("TOPLEFT", 8, y - 5)
    l:SetWidth(110)
    l:SetText(label)
    local v = Style.Text(parent, "GameFontHighlight")
    v:SetPoint("TOPLEFT", 122, y - 4)
    v:SetPoint("RIGHT", button, "LEFT", -8, 0)
    v:SetText(value)
    button:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -6, y)
    return l, v
end

local function Paragraph(parent, y, text)
    local fs = Style.Text(parent, "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", 8, y)
    fs:SetPoint("RIGHT", -8, 0)
    if fs.SetWordWrap then fs:SetWordWrap(true) end
    fs:SetText(text)
    return fs
end

-- offset: from the top of the first card (Layout places them under the header).
local function Card(v, title, sub, offset, height)
    local card = Style.Card(v, title)
    card:SetHeight(height)
    card.sub:SetText(sub)
    card.offset = offset
    v.cards[#v.cards + 1] = card
    return card
end

-- The header goes when the view is short, so the cards keep their room.
local function Layout(v)
    local width = v:GetWidth() or 900
    local column = math.min(width, MAX_WIDTH)
    local left = math.floor((width - column) / 2)
    local last = v.cards[#v.cards]
    local cardsHeight = last.offset + last:GetHeight()
    local cardsTop = Style.BRAND_HEADER_HEIGHT + 12
    local full = (v:GetHeight() or 500) >= cardsTop + cardsHeight
    v.header:SetShown(full)
    v.header:ClearAllPoints()
    v.header:SetPoint("TOPLEFT", left, 0)
    v.header:SetWidth(column)
    local top = full and -cardsTop or 0
    for _, card in ipairs(v.cards) do
        card:ClearAllPoints()
        card:SetPoint("TOPLEFT", left, top - card.offset)
        card:SetWidth(column)
    end
end
UI.Layout = Layout

-- The credits, built into a page (About > Credits): returns the view.
function UI.Build(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.cards = {}
    v.header = Style.BrandHeader(v)
    Style.Border(v.header, COLORS.cardBorder)
    v.header.sub:SetText("v" .. tostring(ns.VERSION or "?") .. "  ·  " .. tostring(ns.FLAVOR_NAME or ""))

    -- Made by
    local made = Card(v, "Made by " .. HEX.accent .. AUTHOR .. "|r", "Questions, bug reports and ideas are welcome on the Discord.", 0, 112)
    local c = made.content
    v.copyInvite = Utils.CopyButton(c, "Copy invite", 110, DISCORD, "invite link",
        "Shows the invite link ready to copy (Ctrl+C), to paste into your browser or Discord.")
    Row(c, -6, "Discord", HEX.white .. DISCORD .. "|r", v.copyInvite)
    v.copyAuthor = Utils.CopyButton(c, "Copy name", 110, AUTHOR, "name")
    Row(c, -34, "Discord name", HEX.white .. AUTHOR .. "|r", v.copyAuthor)

    -- Support
    local support = Card(v, "Support " .. ns.NAME, "Free, and it stays free. Gold is welcome, never expected.", 112 + GAP, 128)
    c = support.content
    Paragraph(c, -6, "If " .. ns.NAME .. " helped you, you can mail gold to " .. HEX.gold .. DONATE.name .. "|r. Mail does not cross "
        .. "factions: send it from an " .. DONATE.faction .. " character on the " .. DONATE.ruleset .. ". Thank you!")
    v.copyDonate = Utils.CopyButton(c, "Copy name", 110, DONATE.name, "name",
        "Shows the character name ready to copy (Ctrl+C), for the mailbox's To: line.")
    Row(c, -44, "Character", HEX.gold .. DONATE.name .. "|r  " .. HEX.muted .. DONATE.faction .. " · " .. DONATE.ruleset .. "|r",
        v.copyDonate)

    -- Where the game data comes from
    local built = Card(v, "Data sources", "Where the game data in " .. ns.NAME .. " comes from, with thanks.", 240 + 2 * GAP, 132)
    c = built.content
    local lines = {
        HEX.white .. "Wowhead Classic|r " .. HEX.muted .. "- enchants, recipes, profession leveling, fishing gear.|r",
        HEX.white .. "CMaNGOS classic-db|r " .. HEX.muted .. "- fishing zones and what is caught where.|r",
        HEX.white .. "wago.tools|r " .. HEX.muted .. "- the game's own tables: maps, statistics, sounds.|r",
        HEX.white .. "warcraft.wiki.gg|r " .. HEX.muted .. "- fish, seasons and events.|r",
    }
    for i, text in ipairs(lines) do Paragraph(c, -6 - (i - 1) * 20, text) end

    Layout(v)
    v:SetScript("OnSizeChanged", Layout)
    function v:Refresh() Layout(self) end
    function v:Footer() return "Copy buttons show the text ready to copy (Ctrl+C): the game cannot put text on the clipboard itself." end
    return v
end

-- The credits live on the About page (Credits tab); these keep the old calls.
local function About() return ns.AboutUI end

function UI.Show()
    if About() then About().ShowPage("credits") end
end

function UI.IsShown() return About() ~= nil and About().IsShown("credits") end

function UI.Toggle()
    if UI.IsShown() then About().Hide() else UI.Show() end
end

-- The view on the About page, once built.
function UI.View() return About() and About().views and About().views.credits or nil end

local function Slash(command)
    if command ~= "credits" then return false end
    UI.Toggle()
    return true
end

ns.RegisterModule("Credits", {
    slash = Slash,
})
