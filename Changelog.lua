-- TALOD - the About page: What's new (what changed in each version, newest
-- first, from ChangelogData.lua, built from the per-version summaries by the
-- version tool), Commands (every command and the macro lines) and Credits
-- (Credits.lua). The notes are shown formatted; "Copy text" swaps them for
-- the plain summary in an edit box (Ctrl+A, Ctrl+C), since addons cannot
-- write the clipboard and the one-line copy popup would lose the line breaks.

local ADDON_NAME, ns = ...
local Style, Utils = ns.Style, ns.Utils
local HEX, COLORS = Style.HEX, Style.COLORS

local UI = {}
ns.Changelog = UI

local PAD, LIST_W = 12, 220
local selected = 1
local copying = false

local function Entries() return ns.CHANGELOGS or {} end
UI.Entries = Entries

-- The data spells the name and slash prefix as {name} / {cmd}.
local function Fill(text)
    text = text:gsub("{name}", function() return ns.NAME end)
    return (text:gsub("{cmd}", function() return ns.Cmd.PREFIX end))
end

-- The summary as its file reads: heading, "Changes since", body.
function UI.PlainText(entry)
    if not entry then return nil end
    local out = "# " .. ns.NAME .. " " .. entry.v .. (entry.d and (" \226\128\148 " .. entry.d) or "") .. "\n\n"
    if entry.from then out = out .. "Changes since " .. entry.from .. ".\n\n" end
    return out .. Fill(entry.text or "")
end

---------------------------------------------------------------------------
-- Markdown → game text. The files are hard-wrapped, so a line that is not a
-- heading, a bullet or blank continues the block above it.
---------------------------------------------------------------------------
local function Inline(s)
    s = s:gsub("|", "||")
    s = s:gsub("%*%*(.-)%*%*", HEX.white .. "%1|r")
    return (s:gsub("`(.-)`", HEX.gold .. "%1|r"))
end

function UI.Render(text)
    local blocks, last = {}, nil
    for line in (Fill(text or "") .. "\n"):gmatch("(.-)\r?\n") do
        local hashes, heading = line:match("^(#+)%s+(.*)$")
        local lead, bullet = line:match("^(%s*)[-*]%s+(.*)$")
        if line:match("^%s*$") then
            last = nil
        elseif hashes then
            blocks[#blocks + 1] = { kind = "head", text = heading }
            last = nil
        elseif bullet then
            last = { kind = "item", depth = math.floor(#lead / 2), text = bullet }
            blocks[#blocks + 1] = last
        elseif last then
            last.text = last.text .. " " .. line:match("^%s*(.-)%s*$")
        else
            last = { kind = "para", text = line:match("^%s*(.-)%s*$") }
            blocks[#blocks + 1] = last
        end
    end
    local out = {}
    for i, b in ipairs(blocks) do
        local prev = blocks[i - 1]
        if prev and (b.kind ~= "item" or prev.kind ~= "item") then out[#out + 1] = "" end
        if b.kind == "head" then
            out[#out + 1] = HEX.accent .. Inline(b.text) .. "|r"
        elseif b.kind == "item" then
            out[#out + 1] = string.rep("    ", b.depth) .. (b.depth == 0 and "\226\128\162 " or "\226\128\147 ") .. Inline(b.text)
        else
            out[#out + 1] = Inline(b.text)
        end
    end
    return table.concat(out, "\n")
end

---------------------------------------------------------------------------
-- The About page: What's new (the changelog), Commands, Credits.
---------------------------------------------------------------------------
local About = {}
ns.AboutUI = About

local frame
local views = {}
local state = { tab = "changelog" }

-- What's new ----------------------------------------------------------------
local function Draw()
    if not frame then return end
    local entries = Entries()
    if selected > #entries then selected = 1 end
    local items = {}
    for i, e in ipairs(entries) do
        local mine = e.v == ns.VERSION
        items[i] = { text = (i == selected and HEX.accent or HEX.white) .. e.v .. "|r"
            .. (mine and (HEX.muted .. "  yours|r") or ""),
            cols = { HEX.muted .. (e.d or "") .. "|r" }, index = i, selected = i == selected }
    end
    frame.list:SetItems(items)

    local entry = entries[selected]
    local card = frame.text
    if not entry then
        card.title:SetText("No changelog")
        card.sub:SetText("This copy has no version notes.")
        frame.body:SetText("")
        frame.copy:Hide()
        return
    end
    frame.copy:Show()
    card.title:SetText(ns.NAME .. " " .. entry.v)
    card.sub:SetText((entry.from and ("Changes since " .. entry.from) or "First version")
        .. (entry.d and ("  \194\183  " .. entry.d) or ""))
    frame.copy:SetLabel(copying and "Formatted" or "Copy text")

    local width = frame.scroll:GetWidth() or 0
    if width < 100 then width = 500 end
    frame.child:SetWidth(width)
    frame.body:SetWidth(width - 8)
    frame.edit:SetWidth(width - 8)
    if copying then
        frame.body:Hide()
        frame.edit:Show()
        frame.edit:SetText(UI.PlainText(entry))
        frame.edit:SetFocus()
        frame.edit:HighlightText()
        frame.child:SetHeight(math.max(40, (frame.edit:GetHeight() or 0) + 8))
    else
        frame.edit:Hide()
        frame.edit:ClearFocus()
        frame.body:Show()
        frame.body:SetText(UI.Render(entry.text))
        frame.child:SetHeight(math.max(40, (frame.body:GetStringHeight() or 0) + 12))
    end
    frame.scroll:SetVerticalScroll(0)
end

function UI.Select(index)
    selected = index
    copying = false
    Draw()
end

function UI.SetCopying(on)
    copying = on and true or false
    Draw()
end

function UI.Selected() return Entries()[selected] end

local function BuildChangelog(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    local versions = Style.Card(v, "Versions")
    versions:SetPoint("TOPLEFT")
    versions:SetPoint("BOTTOMLEFT")
    versions:SetWidth(LIST_W)
    versions.sub:SetText("Newest first.")
    frame.list = Style.List(versions.content, { colWidths = { 76 },
        columns = { name = "Version", "Date" },
        onClick = function(item) if item.index then UI.Select(item.index) end end })

    local card = Style.Card(v, "")
    card:SetPoint("TOPLEFT", versions, "TOPRIGHT", 10, 0)
    card:SetPoint("BOTTOMRIGHT")
    frame.text = card

    frame.copy = Style.Button(card, "Copy text", 96, function() UI.SetCopying(not copying) end,
        "Shows this version's notes as plain text, ready to copy (Ctrl+A, Ctrl+C) into a post or a message. "
        .. "Click again for the formatted view.", { small = true })
    frame.copy:SetPoint("TOPRIGHT", -6, -math.floor((Style.M.cardHeader - 18) / 2))
    if not Style.IsLedger() then card.title:SetPoint("RIGHT", frame.copy, "LEFT", -8, 0) end
    card.sub:SetPoint("RIGHT", frame.copy, "LEFT", -8, 0)

    local scroll = CreateFrame("ScrollFrame", nil, card.content)
    scroll:SetPoint("TOPLEFT", 8, -6)
    scroll:SetPoint("BOTTOMRIGHT", -8, 6)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(500, 100)
    scroll:SetScrollChild(child)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local max = math.max(0, (child:GetHeight() or 0) - (self:GetHeight() or 0))
        self:SetVerticalScroll(math.max(0, math.min(max, (self:GetVerticalScroll() or 0) - delta * 50)))
    end)
    scroll:SetScript("OnSizeChanged", function() if frame:IsShown() and state.tab == "changelog" then Draw() end end)
    frame.scroll, frame.child = scroll, child

    local body = Style.Text(child, "GameFontHighlight")
    body:SetPoint("TOPLEFT", 2, -2)
    if body.SetWordWrap then body:SetWordWrap(true) end
    body:SetJustifyV("TOP")
    local t2 = COLORS.t2
    body:SetTextColor(t2[1], t2[2], t2[3])
    if body.SetSpacing then body:SetSpacing(2) end
    frame.body = body

    local edit = CreateFrame("EditBox", nil, child)
    edit:SetPoint("TOPLEFT", 2, -2)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    -- Read-only: typing puts the summary back.
    edit:SetScript("OnTextChanged", function(self, user)
        local entry = UI.Selected()
        if user and entry then self:SetText(UI.PlainText(entry)) self:HighlightText() end
    end)
    edit:Hide()
    frame.edit = edit

    function v:Refresh() Draw() end
    function v:Footer() return "Each version's notes, newest first. Copy text gives the plain notes for a post or a message." end
    return v
end

-- Commands ------------------------------------------------------------------
-- The frames a macro or a key binding can click (secure buttons, set up out
-- of combat; one click = one action, as on screen).
local function MacroLines()
    return {
        { "/click " .. ns.FRAME .. "FishingSwapButton", "swap the fishing pole for your weapon" },
        { "/click " .. ns.FRAME .. "FishingLureButton", "put a lure on your fishing pole" },
        { "/click " .. ns.FRAME .. "AHNextButton", "the scan panel's next search at the Auction House" },
        { "/click " .. ns.FRAME .. "RecruitStep", "one recruit step (also the recruit key)" },
    }
end
About.MacroLines = MacroLines

local function CommandRow(r)
    local also = #r.aliases > 0 and (HEX.muted .. "  (also: " .. table.concat(r.aliases, ", ") .. ")|r") or ""
    return {
        text = HEX.white .. r.canonical .. "|r  " .. HEX.muted .. (r.help or "") .. "|r" .. also,
        search = r.canonical .. " " .. table.concat(r.aliases, " ") .. " " .. (r.help or "") .. " " .. ns.Cmd.PageLabel(r.page),
        copy = r.canonical, row = r,
        tooltip = function(owner)
            local lines = { r.canonical, r.help or "" }
            if #r.aliases > 0 then lines[#lines + 1] = HEX.muted .. "Also: " .. table.concat(r.aliases, ", ") .. "|r" end
            lines[#lines + 1] = HEX.muted .. "Copy: the command, ready to paste into a macro or chat.|r"
            ns.Tooltip.Text(owner, lines)
        end,
    }
end

-- Every command, grouped by page, then the macro lines.
function About.CommandRows()
    local rows, last = {}, nil
    for _, r in ipairs(ns.Cmd.List()) do
        if not r.macro then
            if r.page ~= last then
                last = r.page
                rows[#rows + 1] = { header = true, text = ns.Cmd.PageLabel(r.page) }
            end
            rows[#rows + 1] = CommandRow(r)
        end
    end
    rows[#rows + 1] = { header = true, text = "Macros and key bindings" }
    local seen = {}
    local function Macro(line, help, page)
        if seen[line] then return end
        seen[line] = true
        rows[#rows + 1] = {
            text = HEX.white .. line .. "|r  " .. HEX.muted .. help .. "|r",
            search = line .. " " .. help .. " macro " .. (page and ns.Cmd.PageLabel(page) or ""),
            copy = line, macro = true,
            tooltip = function(owner)
                ns.Tooltip.Text(owner, { line, help, HEX.muted .. "Put it in a macro, or bind the macro to a key. "
                    .. "Each press is one click: nothing repeats on its own.|r" })
            end,
        }
    end
    for _, r in ipairs(ns.Cmd.List()) do
        if r.macro then Macro(r.canonical, (r.help or ""):gsub("^%(macro / keybind%) ", ""), r.page) end
    end
    for _, m in ipairs(MacroLines()) do Macro(m[1], m[2]) end
    return rows
end

-- The Copy button on a row (every command and macro line has one).
function About.RowButton(item)
    if not item.copy then return nil end
    return { label = "Copy", width = 54, onClick = function() Utils.Copy(item.copy, item.macro and "macro" or "command") end,
        tooltip = "Shows it ready to copy (Ctrl+C)." }
end

local function BuildCommands(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Commands")
    v.card:SetAllPoints()
    v.card.sub:SetText("Every command by page, with its older words. Copy puts one in the copy box.")
    v.list = Style.List(v.card.content, { search = true, hint = "Search commands, words, pages...",
        rowButtonWidth = 54,
        rowButton = About.RowButton })
    local built
    function v:Refresh()
        if not built then
            built = About.CommandRows()
            self.list:SetItems(built)
        end
    end
    function v:Footer() return "Also in chat: " .. ns.Cmd.Text("help") .. " (every page) or " .. ns.Cmd.Text("help", "<page>") .. "." end
    return v
end

-- Window ----------------------------------------------------------------------
local TABS = {
    { key = "changelog", label = "What's new", build = BuildChangelog },
    { key = "commands", label = "Commands", build = BuildCommands },
    { key = "credits", label = "Credits", build = function(parent) return ns.Credits.Build(parent) end },
}

local function Build()
    frame = Style.Window(ns.FRAME .. "ChangelogWindow", "About", nil, nil, { nav = "about" })
    frame.check = Style.Button(frame, "Check for updates", 130, function()
        if ns.Version and ns.Version.Show then ns.Version.Show() end
    end, "Your version, whether a newer one is out, and how to update. Also " .. ns.Cmd.Text("version") .. ".", { small = true })
    frame.header:Add(frame.check)
    frame:SetStatus("")

    local top = Style.M.titleBar + 10
    local tabHolder = CreateFrame("Frame", nil, frame)
    tabHolder:SetPoint("TOPLEFT", PAD, -top)
    tabHolder:SetPoint("TOPRIGHT", -PAD, -top)
    tabHolder:SetHeight(26)
    frame.tabs = Style.Tabs(tabHolder, TABS, function(key) state.tab = key About.Refresh() end)
    local line = Style.HLine(frame)
    line:SetPoint("TOPLEFT", PAD, -(top + 26))
    line:SetPoint("TOPRIGHT", -PAD, -(top + 26))
    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", PAD, -(top + 36))
    body:SetPoint("BOTTOMRIGHT", -PAD, 34)
    for _, def in ipairs(TABS) do views[def.key] = def.build(body) end
    frame.footer = Style.Text(frame, "GameFontDisableSmall")
    frame.footer:SetPoint("BOTTOMLEFT", PAD + 2, 12)
    frame.footer:SetPoint("RIGHT", -PAD, 0)
    frame:HookScript("OnShow", function() About.Refresh() end)
end

function About.Refresh()
    if not frame or not frame:IsShown() then return end
    if not views[state.tab] then state.tab = "changelog" end
    local newer = ns.Version and ns.Version.Newer and ns.Version.Newer()
    frame:SetStatus("v" .. tostring(ns.VERSION or "?") .. "  ·  " .. tostring(ns.FLAVOR_NAME or "")
        .. (newer and (HEX.accent .. "  ·  " .. tostring(newer.v) .. " is out|r") or ""))
    frame.tabs:Select(state.tab)
    for key, v in pairs(views) do v:SetShown(key == state.tab) end
    local v = views[state.tab]
    v:Refresh()
    frame.footer:SetText(v:Footer() or "")
end

local TAB_OF = { changelog = "changelog", ["what's new"] = "changelog", news = "changelog", commands = "commands", help = "commands",
    credits = "credits" }

-- The page contract: tab changelog / commands / credits; arg on What's new:
-- a version ("0.30.1") to select.
function About.ShowPage(tab, view, arg)
    if not frame then Build() end
    tab = type(tab) == "string" and TAB_OF[tab:lower()] or nil
    if tab then state.tab = tab end
    if frame:IsShown() then About.Refresh() else frame:Show() end
    if frame.Raise then frame:Raise() end
    if state.tab == "changelog" and type(arg) == "string" then
        for i, e in ipairs(Entries()) do
            if e.v == arg then UI.Select(i) break end
        end
    end
    return true
end

-- Shown at all, or shown on that tab.
function About.IsShown(tab)
    if not (frame and frame:IsShown()) then return false end
    return tab == nil or state.tab == tab
end

function About.Hide() if frame then frame:Hide() end end

-- Home and the page list: a newer version heard of.
function About.PageStatus()
    local newer = ns.Version and ns.Version.Newer and ns.Version.Newer()
    if newer then return { text = tostring(newer.v) .. " is out", tone = "accent" } end
    return nil
end

function About.Frame() return frame end
About.views, About.state = views, state

-- The old Changelog calls: the page on its What's new tab.
function UI.Show() About.ShowPage("changelog") end

function UI.Toggle()
    if About.IsShown("changelog") then About.Hide() else UI.Show() end
end

function UI.IsShown() return About.IsShown("changelog") end

-- /talod changelog [version]
local function Slash(command, rest)
    if command ~= "changelog" then return false end
    local want = rest and rest:match("^%s*v?(%d+%.%d+%.%d+)")
    if want then
        for i, e in ipairs(Entries()) do
            if e.v == want then
                UI.Show()
                UI.Select(i)
                return true
            end
        end
        ns.Print("No notes for version " .. want .. ". " .. ns.Cmd.Text("changelog") .. " lists every version.")
        return true
    end
    UI.Toggle()
    return true
end

ns.RegisterModule("Changelog", {
    slash = Slash,
})
