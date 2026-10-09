-- TALOD - Changelog page: what changed in each version, newest first, from
-- ChangelogData.lua (built from the per-version summaries by the version
-- tool). The text is shown formatted; "Copy text" swaps it for the plain
-- summary in an edit box (Ctrl+A, Ctrl+C), since addons cannot write the
-- clipboard and the one-line copy popup would lose the line breaks.

local ADDON_NAME, ns = ...
local Style = ns.Style
local HEX, COLORS = Style.HEX, Style.COLORS

local UI = {}
ns.Changelog = UI

local PAD, LIST_W = 16, 220
local frame
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
-- Window
---------------------------------------------------------------------------
local function Draw()
    if not frame then return end
    local entries = Entries()
    if selected > #entries then selected = 1 end
    local items = {}
    for i, e in ipairs(entries) do
        local mine = e.v == ns.VERSION
        items[i] = { text = (i == selected and HEX.accent or HEX.white) .. e.v .. "|r"
            .. (mine and (HEX.muted .. "  yours|r") or ""),
            cols = { HEX.muted .. (e.d or "") .. "|r" }, accent = i == selected and COLORS.accent or nil, index = i }
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

local function Build()
    frame = Style.Window(ns.FRAME .. "ChangelogWindow", "Changelog", nil, nil, { nav = "changelog" })

    local versions = Style.Card(frame, "Versions")
    versions:SetPoint("TOPLEFT", PAD, -52)
    versions:SetPoint("BOTTOMLEFT", PAD, PAD)
    versions:SetWidth(LIST_W)
    versions.sub:SetText("Newest first. Click one to read it.")
    frame.list = Style.List(versions.content, { colWidths = { 76 },
        columns = { name = "Version", "Date" },
        onClick = function(item) if item.index then UI.Select(item.index) end end })

    local card = Style.Card(frame, "")
    card:SetPoint("TOPLEFT", versions, "TOPRIGHT", 10, 0)
    card:SetPoint("BOTTOMRIGHT", -PAD, PAD)
    frame.text = card

    frame.copy = Style.Button(card, "Copy text", 96, function() UI.SetCopying(not copying) end,
        "Shows this version's notes as plain text, ready to copy (Ctrl+A, Ctrl+C) into a post or a message. "
        .. "Click again for the formatted view.")
    frame.copy:SetPoint("TOPRIGHT", -8, -8)
    card.title:SetPoint("RIGHT", frame.copy, "LEFT", -8, 0)

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
    scroll:SetScript("OnSizeChanged", function() if frame:IsShown() then Draw() end end)
    frame.scroll, frame.child = scroll, child

    local body = Style.Text(child, "GameFontHighlight")
    body:SetPoint("TOPLEFT", 2, -2)
    if body.SetWordWrap then body:SetWordWrap(true) end
    body:SetJustifyV("TOP")
    body:SetTextColor(0.82, 0.82, 0.82)
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

    frame:HookScript("OnShow", Draw)
end

function UI.Show()
    if not frame then Build() end
    if frame:IsShown() then Draw() else frame:Show() end   -- OnShow draws
    if frame.Raise then frame:Raise() end
end

function UI.Toggle()
    if frame and frame:IsShown() then frame:Hide() else UI.Show() end
end

function UI.IsShown() return frame ~= nil and frame:IsShown() end

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
