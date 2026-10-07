-- TALOD - settings window.
--
-- Its own window in the shared Style (sections on the left, sub-tabs on
-- top, flat controls), so settings look like the rest of the addon. The
-- game's Options > AddOns list keeps a TALOD entry that opens it.
-- Pages are built the first time they are shown; every control writes
-- straight into TALODDB and applies live. No Blizzard templates are
-- needed, so it also works where they are missing.

local ADDON_NAME, ns = ...
local C = ns.C
local Style = ns.Style
local COLORS, HEX = Style.COLORS, Style.HEX

local Options = {}
ns.Options = Options

local panel, launcher, category
local controls = {}
local CONTENT_WIDTH = 640
local NAV_WIDTH = 156

local function Apply()
    if ns.Refresh then ns.Refresh() end
end

local function AddTooltip(frame, title, text)
    if not text then return end
    frame:HookScript("OnEnter", function(self)
        ns.Tooltip.Text(self, { title, text })
    end)
    frame:HookScript("OnLeave", ns.Tooltip.Hide)
end

---------------------------------------------------------------------------
-- Widgets
---------------------------------------------------------------------------
local function Header(parent, y, text, subtitle)
    y = y - 4
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fs:SetPoint("TOPLEFT", 16, y)
    fs:SetText(text)
    local line = Style.HLine(parent)
    line:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -5)
    line:SetPoint("RIGHT", parent, "LEFT", CONTENT_WIDTH - 16, 0)
    y = y - 26
    if subtitle then
        local sub = parent:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        sub:SetPoint("TOPLEFT", 18, y)
        sub:SetWidth(CONTENT_WIDTH - 40)
        sub:SetJustifyH("LEFT")
        sub:SetText(subtitle)
        y = y - math.max(14, sub:GetStringHeight() or 14) - 6
    end
    return y
end

local function Hover(frame, on)
    local c = on and COLORS.accent or COLORS.border
    if frame.SetBorderColor then frame:SetBorderColor(c[1], c[2], c[3], on and 0.9 or 1) end
end

-- Flat checkbox: a bordered box with an accent square when on; the label
-- is part of the click area.
-- tbl (optional): a subtable of TALODDB the key lives in, e.g. the
-- per-class alert switches.
local function Checkbox(parent, y, key, label, tooltip, x, tbl)
    local cb = CreateFrame("CheckButton", nil, parent)
    cb:SetSize(18, 18)
    cb:SetPoint("TOPLEFT", (x or 16) + 4, y - 3)
    local bg = Style.Texture(cb, "BACKGROUND", COLORS.button)
    bg:SetAllPoints()
    Style.Border(cb, COLORS.border)
    cb.mark = Style.Texture(cb, "ARTWORK", COLORS.accent)
    cb.mark:SetPoint("TOPLEFT", 4, -4)
    cb.mark:SetPoint("BOTTOMRIGHT", -4, 4)
    local fs = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("LEFT", cb, "RIGHT", 8, 0)
    fs:SetText(label)
    cb:SetHitRectInsets(0, -math.min(260, (fs:GetStringWidth() or 120) + 10), 0, 0)

    local function Store() return tbl and ns.DB()[tbl] or ns.DB() end
    cb:SetScript("OnClick", function(self)
        Store()[key] = self:GetChecked() and true or nil
        if not tbl then Store()[key] = self:GetChecked() and true or false end
        self.mark:SetShown(self:GetChecked() and true or false)
        Apply()
    end)
    cb:SetScript("OnEnter", function(self)
        Hover(self, true)
        if tooltip then ns.Tooltip.Text(self, { label, tooltip }) end
    end)
    cb:SetScript("OnLeave", function(self) Hover(self, false) ns.Tooltip.Hide() end)
    cb.Refresh = function(self)
        local on = Store()[key] and true or false
        self:SetChecked(on)
        self.mark:SetShown(on)
    end
    controls[#controls + 1] = cb
    return y - 28, cb
end

-- Flat slider: a thin track filled up to the value, a small accent thumb.
local function Slider(parent, y, key, label, minValue, maxValue, step, format, tooltip)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("TOPLEFT", 22, y - 2)
    fs:SetText(label)

    local s = CreateFrame("Slider", nil, parent)
    s:SetOrientation("HORIZONTAL")
    s:SetSize(240, 16)
    s:SetPoint("TOPLEFT", 270, y)
    s:SetHitRectInsets(0, 0, -6, -6)
    local track = Style.Texture(s, "BACKGROUND", { 1, 1, 1, 0.12 })
    track:SetHeight(4)
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")
    local fill = Style.Texture(s, "ARTWORK", COLORS.bar)
    fill:SetHeight(4)
    fill:SetPoint("LEFT")
    local thumb = s:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(Style.WHITE)
    thumb:SetSize(8, 16)
    Style.Fill(thumb, COLORS.accent)
    if not pcall(s.SetThumbTexture, s, thumb) then
        pcall(s.SetThumbTexture, s, "Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    end
    s:SetMinMaxValues(minValue, maxValue)
    s:SetValueStep(step)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    s:EnableMouseWheel(true)

    local valueText = s:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    valueText:SetPoint("LEFT", s, "RIGHT", 12, 0)

    local function Show(value)
        valueText:SetText(type(format) == "function" and format(value) or string.format(format or "%s", value))
        local frac = (maxValue > minValue) and (value - minValue) / (maxValue - minValue) or 0
        fill:SetWidth(math.max(1, frac * 240))
    end

    local refreshing = false
    s:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value / step + 0.5) * step
        Show(value)
        if refreshing then return end
        if ns.DB()[key] ~= value then
            ns.DB()[key] = value
            Apply()
        end
    end)
    s:SetScript("OnMouseWheel", function(self, delta)
        self:SetValue(math.max(minValue, math.min(maxValue, self:GetValue() + delta * step)))
    end)
    s:SetScript("OnEnter", function(self) if tooltip then ns.Tooltip.Text(self, { label, tooltip }) end end)
    s:SetScript("OnLeave", function() ns.Tooltip.Hide() end)
    s.Refresh = function(self)
        refreshing = true
        local value = ns.DB()[key] or minValue
        self:SetValue(value)
        Show(value)
        refreshing = false
    end
    controls[#controls + 1] = s
    return y - 32, s
end

local function Button(parent, y, text, width, onClick, tooltip, x)
    local b = Style.Button(parent, text, width or 160, onClick, tooltip)
    b:SetPoint("TOPLEFT", x or 22, y)
    return y - 28, b
end

-- A button that cycles through a fixed list of choices (UIDropDownMenu is
-- deprecated on the modern engine).
local function Cycle(parent, y, key, label, choices, tooltip)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("TOPLEFT", 22, y - 4)
    fs:SetText(label)

    local _, b = Button(parent, y, "", 200, nil, (tooltip and (tooltip .. "\n") or "") .. "Left-click: next. Right-click: previous. Arrow: pick from a list.", 270)
    local function List()
        if type(choices) == "function" then return choices() end
        return choices
    end
    local function Index()
        for i, choice in ipairs(List()) do
            if choice.value == ns.DB()[key] then return i end
        end
        return 1
    end
    local function SetLabel()
        b:SetLabel((List()[Index()] or { label = "?" }).label .. "  >")
    end
    b:SetScript("OnClick", function(_, mouseButton)
        local list = List()
        local i = Index() + (mouseButton == "RightButton" and -1 or 1)
        if i > #list then i = 1 elseif i < 1 then i = #list end
        ns.DB()[key] = list[i].value
        SetLabel()
        Apply()
    end)
    Style.AttachDropdown(b, function()
        local out, cur = {}, ns.DB()[key]
        for _, choice in ipairs(List()) do
            out[#out + 1] = { label = choice.label, selected = choice.value == cur, pick = function()
                ns.DB()[key] = choice.value
                SetLabel()
                Apply()
            end }
        end
        return out
    end)
    b.Refresh = SetLabel
    controls[#controls + 1] = b
    return y - 30, b
end

local function Paragraph(parent, y, text, template)
    local fs = parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlight")
    fs:SetPoint("TOPLEFT", 16, y)
    fs:SetWidth(CONTENT_WIDTH - 32)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    return y - (fs:GetStringHeight() or 14) - 12, fs
end

-- A text block whose content is recomputed on every refresh.
local function LiveText(parent, y, height, compute)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", 22, y)
    fs:SetWidth(CONTENT_WIDTH - 44)
    fs:SetJustifyH("LEFT")
    fs.Refresh = function(self) self:SetText(compute()) end
    controls[#controls + 1] = fs
    return y - height, fs
end

Options.Widgets = {
    Header = Header, Checkbox = Checkbox, Slider = Slider, Button = Button, Cycle = Cycle,
    Paragraph = Paragraph, LiveText = LiveText, AddTooltip = AddTooltip, CONTENT_WIDTH = CONTENT_WIDTH,
}
function Options.Widgets.Track(control) controls[#controls + 1] = control end
function Options.Apply() Apply() end

local function Signed(v) return (v > 0 and "+" or "") .. v end

---------------------------------------------------------------------------
-- Pages
---------------------------------------------------------------------------
local Pages = {}

function Pages.Panel(parent)
    local y = -12
    y = Paragraph(parent, y, "Enemy players near you, from their nameplates (up to ~41 yd), your target and your mouseover. "
        .. "Live enemies are sorted by threat (level, your lists, closeness); recently seen ones fade out below them. "
        .. "Distances are brackets from the game's range checks: |cffffffff8–10 yd|r. "
        .. ns.ColorCode("threshold") .. "? yd|r means the game gave no answer (usually in combat).")
    y = Header(parent, y, "General")
    y = Checkbox(parent, y, "enabled", "Enable " .. ns.NAME, "Turns the panel, alerts, badges and safety warnings on or off.")
    y = Checkbox(parent, y, "colorblind", "Colorblind-friendly colors", "Blue / orange / magenta instead of green / yellow / red.")
    y = Checkbox(parent, y, "minimapButton", "Minimap button", "Left-click: character window. Shift: economy. Ctrl: Enemies nearby "
        .. "panel. Right-click: these settings. Drag to move it. Also " .. ns.Cmd.Text("minimap") .. ".")
    y = y - 6
    y = Header(parent, y, "Enemies nearby panel")
    y = Checkbox(parent, y, "panelShown", "Show the panel")
    y = Checkbox(parent, y, "alertsEnabled", "Enemy alerts (center text, sound, chat)", "Notifications when an enemy appears. "
        .. "Off: the panel still lists every enemy, silently. Also the button in the panel's title bar, " .. ns.Cmd.Text("alerts") .. " on|off, "
        .. "and Alerts for the details.", 40)
    y = Checkbox(parent, y, "panelLocked", "Lock position", "Locked, Shift + drag still moves it.", 40)
    y = Checkbox(parent, y, "panelHideEmpty", "Hide while empty (when locked)", nil, 40)
    y = Checkbox(parent, y, "panelClickTarget", "Click a row to target", "Out of combat only: the game does not let addons change click targets in combat.", 40)
    y = Slider(parent, y, "panelScale", "Size", 0.6, 2.0, 0.1, "%.1fx")
    y = Slider(parent, y, "panelRows", "Rows", 3, 20, 1, "%d")
    y = Slider(parent, y, "panelFadeSeconds", "Keep listed after they leave view", 10, 300, 10, "%ds")
    y = y - 6
    y = Header(parent, y, "Enemy details", "A second line under each enemy in view: health in hit points, power, "
        .. "tags (" .. ns.ColorCode("danger") .. "@you|r targeting you, " .. ns.ColorCode("danger") .. "PvP|r flagged, "
        .. ns.ColorCode("threshold") .. "cast|r casting, cbt in combat) and their buffs and debuffs. Big cooldowns have a "
        .. ns.ColorCode("danger") .. "red|r border, crowd control a " .. ns.ColorCode("threshold") .. "yellow|r one. "
        .. "A " .. ns.ColorCode("threshold") .. "?|r means the game hides it. Hover a row for everything in words.")
    y = Checkbox(parent, y, "panelDetails", "Show health, tags, buffs and debuffs")
    y = Slider(parent, y, "panelMaxAuras", "Buff / debuff icons per enemy", 0, 10, 1, "%d")
    y = Button(parent, y, "Reset position", 140, function() ns.Panel.ResetPosition() end)
    return -y + 10
end

function Pages.Plates(parent)
    local y = -12
    y = Header(parent, y, "Nameplate badges", "A small label left of each enemy player's nameplate: level difference to you "
        .. "(" .. ns.ColorCode("danger") .. "??|r = 10+ above), and KoS / avoid when they are on a list.")
    y = Checkbox(parent, y, "badgesEnabled", "Show badges on enemy nameplates")
    y = y - 6
    y = Header(parent, y, "Target readout", "Above your enemy target's nameplate: distance bracket and the key spells "
        .. "of your class that reach right now (" .. ns.ColorCode("safe") .. "green|r). The panel footer lists all of them.")
    y = Checkbox(parent, y, "targetReadout", "Show the target readout")
    y = Checkbox(parent, y, "targetSpells", "Include your spell ranges", nil, 40)
    y = y - 6
    y = Header(parent, y, "Detection reach")
    y = Paragraph(parent, y, "Enemies are noticed when their nameplate appears. The game's maximum nameplate distance "
        .. "gives you the earliest warning.", "GameFontHighlightSmall")
    y = Button(parent, y, "Max nameplate distance", 200, function()
        if ns.Main and ns.Main.SetMaxNameplateDistance then ns.Main.SetMaxNameplateDistance() end
    end)
    y = LiveText(parent, y, 20, function()
        local d = ns.GetCVarNumber(C.NAMEPLATE_DISTANCE_CVAR)
        return "Current nameplate distance: " .. (d and (ns.FormatNumber(d) .. " yd") or "unknown")
    end)
    return -y + 10
end

function Pages.Triggers(parent)
    local y = -12
    y = Paragraph(parent, y, "An alert fires the first time an enemy player shows up, then not again for that player until "
        .. "the repeat time has passed. Players the game hides hostility for never alert; the panel shows them with "
        .. ns.ColorCode("threshold") .. "?|r.")
    y = Header(parent, y, "When to alert")
    y = Checkbox(parent, y, "alertsEnabled", "Enable alerts")
    y = Checkbox(parent, y, "alertOnNameplate", "When an enemy nameplate appears", nil, 40)
    y = Checkbox(parent, y, "alertOnTarget", "When you target an enemy", nil, 40)
    y = Checkbox(parent, y, "alertOnMouseover", "When you mouse over an enemy", nil, 40)
    y = Slider(parent, y, "alertMinLevelGap", "Only enemies from (levels vs you)", -60, 10, 1, function(v)
        return v <= -60 and "any level" or Signed(v)
    end, "Ignore enemies far below you. Skulls and your KoS list always alert.")
    y = Slider(parent, y, "alertRepeatSeconds", "Repeat for the same player after", 30, 900, 30, function(v)
        return v >= 60 and (math.floor(v / 60) .. " min" .. (v % 60 > 0 and (" " .. v % 60 .. "s") or "")) or (v .. "s")
    end)
    y = y - 6
    y = Header(parent, y, "Loud alerts", "Bigger text and the alert sound.")
    y = Checkbox(parent, y, "alertLoudKoS", "Players on your kill-on-sight list")
    y = Slider(parent, y, "alertLoudAbove", "Enemies this many levels above you", 1, 10, 1, function(v) return "+" .. v .. " and ??" end)
    y = Paragraph(parent, y, "Always loud for these classes:", "GameFontHighlightSmall")
    for i, classFile in ipairs(C.CLASSES) do
        local column = (i - 1) % 3
        local label = ns.Hex(ns.ClassColor(classFile)) .. ns.ClassName(classFile) .. "|r"
        Checkbox(parent, y, classFile, label, nil, 30 + column * 180, "alertLoudClasses")
        if column == 2 or i == #C.CLASSES then y = y - 28 end
    end
    return -y + 10
end

function Pages.Effects(parent)
    local y = -12
    y = Header(parent, y, "How to alert")
    y = Checkbox(parent, y, "alertCenterText", "Center-screen text")
    y = Checkbox(parent, y, "alertChat", "Chat line (with zone)")
    y = Checkbox(parent, y, "alertSound", "Sound for loud alerts")
    local soundChoices = {}
    for _, sound in ipairs(ns.ALERT_SOUNDS) do soundChoices[#soundChoices + 1] = { value = sound.key, label = sound.label } end
    y = Cycle(parent, y, "alertSoundChoice", "Sound", soundChoices)
    y = y - 6
    y = Button(parent, y, "Test alert", 160, function() ns.Alerts.Reset(); ns.Alerts.Test() end, "Shows a loud alert with the current settings.")
    return -y + 10
end

function Pages.Safety(parent)
    local y = -12
    y = Paragraph(parent, y, "For Hardcore characters, where one PvP flag can end a run. " .. ns.NAME .. " cannot stop an action; "
        .. "it warns when you target a player that acting on would flag you.")
    y = Header(parent, y, "PvP flag")
    y = Checkbox(parent, y, "flagIndicator", "Always show my PvP flag", "PvP off / PvP ON / PvP ON · off in 4:12. "
        .. ns.ColorCode("threshold") .. "?|r when the game hides it.")
    y = Checkbox(parent, y, "flagLocked", "Lock its position", "Locked, Shift + drag still moves it.", 40)
    y = Button(parent, y, "Reset position", 140, function() ns.Safety.ResetPosition() end)
    y = y - 6
    y = Header(parent, y, "Warnings")
    y = Checkbox(parent, y, "flagWarnTarget", "Warn when my target would flag me",
        "While you are unflagged: targeting an enemy player, their pet or an enemy-faction NPC such as a guard (attacking flags you), "
        .. "or a flagged friendly player (healing or buffing flags you).")
    y = Checkbox(parent, y, "zoneBanner", "Banner when entering contested or enemy territory",
        "With the number of enemies " .. ns.NAME .. " saw there in the last 24 hours.")
    return -y + 10
end

function Pages.Stealth(parent)
    local y = -12
    y = Paragraph(parent, y, "Rogues and druids leave no trace once stealthed: the game removes their nameplate. "
        .. "When an enemy rogue or druid's nameplate disappears close to you while they were alive, they most likely "
        .. "stealthed (Stealth, Prowl, Vanish). Logging out or a mount flying off look the same, so this is a heuristic and off by default.")
    y = Header(parent, y, "Vanished stealthers")
    y = Checkbox(parent, y, "vanishAlert", "Alert when a stealther vanishes nearby")
    y = Slider(parent, y, "vanishMaxRange", "Only when they were within", 10, 40, 5, "%d yd")
    return -y + 10
end

local function JournalOverview()
    local J = ns.Journal
    local rows, players, kos, avoid = J.Stats()
    local lines = { string.format("%d sightings of %d players.  Kill on sight: %d.  Avoid: %d.", rows, players, kos, avoid), "" }
    lines[#lines + 1] = "|cffffd100Most recent|r"
    local recent = J.Recent(12)
    if #recent == 0 then lines[#lines + 1] = "  nothing yet" end
    for _, row in ipairs(recent) do
        lines[#lines + 1] = string.format("  %s%s|r %s %s  —  %s, %s ago%s", ns.Hex(ns.ClassColor(row.class)), tostring(row.name),
            row.level == -1 and "??" or tostring(row.level or "?"), ns.ClassName(row.class),
            tostring(row.subzone or row.zone or "?"), ns.FormatAge(time() - (row.t2 or row.t)),
            row.outcome and ("  [" .. row.outcome .. "]") or "")
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "|cffffd100Where you meet enemies|r"
    local zones = J.ByZone()
    for i = 1, math.min(6, #zones) do
        lines[#lines + 1] = string.format("  %s: %d", zones[i].zone, zones[i].count)
    end
    return table.concat(lines, "\n")
end

local function ListText(list)
    local members = ns.Journal.ListMembers(list)
    if #members == 0 then return "  (empty)" end
    local out = {}
    for _, key in ipairs(members) do out[#out + 1] = "  " .. ns.Journal.Describe(key) end
    return table.concat(out, "\n")
end

function Pages.JournalOverview(parent)
    local y = -12
    y = LiveText(parent, y, 340, JournalOverview)
    return -y + 10
end

function Pages.Lists(parent)
    local y = -12
    y = Paragraph(parent, y, "Players on your kill-on-sight list always get the loud alert and a KoS badge; avoid shows a "
        .. "warning badge. Add your current target with the buttons, or anyone by name: "
        .. "|cffffffff" .. ns.Cmd.Text("kos") .. " Name|r, |cffffffff" .. ns.Cmd.Text("avoid") .. " Name|r, |cffffffff" .. ns.Cmd.Text("unlist") .. " Name|r, |cffffffff" .. ns.Cmd.Text("note") .. " Name text|r.",
        "GameFontHighlightSmall")
    local rowY = y
    Button(parent, rowY, "Target: kill on sight", 170, function() ns.Main.ListCommand("kos", "target") end)
    Button(parent, rowY, "Target: avoid", 130, function() ns.Main.ListCommand("avoid", "target") end, nil, 200)
    Button(parent, rowY, "Target: remove", 130, function() ns.Main.ListCommand("unlist", "target") end, nil, 338)
    y = y - 34
    y = Header(parent, y, "Kill on sight")
    y = LiveText(parent, y, 140, function() return ListText("kos") end)
    y = Header(parent, y, "Avoid")
    y = LiveText(parent, y, 140, function() return ListText("avoid") end)
    return -y + 10
end

function Pages.JournalManage(parent)
    local y = -12
    y = Header(parent, y, "Recording")
    y = Checkbox(parent, y, "journalEnabled", "Record enemy players I see",
        "Name, class, level, guild, zone and time. Repeat sightings of a player in the same zone are merged.")
    y = Slider(parent, y, "journalMax", "Keep at most", 500, 20000, 500, "%d sightings")
    y = y - 6
    y = Header(parent, y, "Delete", "Lists and notes are kept; a player with neither and no sightings left is forgotten.")
    local rowY = y
    Button(parent, rowY, "Older than 30 days", 160, function() StaticPopup_Show(ns.POPUP .. "DELETE", "older than 30 days", nil, 30) end)
    Button(parent, rowY, "Older than 7 days", 160, function() StaticPopup_Show(ns.POPUP .. "DELETE", "older than 7 days", nil, 7) end, nil, 190)
    Button(parent, rowY, "All sightings", 140, function() StaticPopup_Show(ns.POPUP .. "DELETE", "(all of them)", nil, false) end, nil, 358)
    y = y - 34
    return -y + 10
end

function Pages.Advanced(parent)
    local y = -12
    y = Header(parent, y, "Diagnostics")
    y = Paragraph(parent, y, "The probe reports what this client lets addons read about enemy players (names, levels, "
        .. "flags, distance, auras, casts, addon messages, battleground data), in or out of combat. Run it near an enemy "
        .. "player, once out of combat and once in combat, and keep the result for the developer.", "GameFontHighlightSmall")
    local rowY = y
    Button(parent, rowY, "Run API probe", 150, function() if ns.Probe then ns.Probe.Run() end end,
        "Target an enemy player first if you can.")
    Button(parent, rowY, "Show error log", 150, function() ns.ShowErrors() end,
        ns.NAME .. "'s own errors, in a window you can copy from.", 190)
    y = y - 34
    y = Header(parent, y, "Saved data")
    y = Paragraph(parent, y, "What " .. ns.NAME .. " keeps, for the whole account and for each character, whether what you "
        .. "share with officers is unchanged since your last logout (the tamper seal), and entries set aside because they could "
        .. "not be read.", "GameFontHighlightSmall")
    y = Button(parent, y, "Show saved data", 150, function()
        if ns.Probe and ns.Probe.ShowText then ns.Probe.ShowText(ns.Store.ReportText()) end
    end, "Entries per store, by character. " .. ns.Cmd.Text("data") .. " does the same.")
    y = Header(parent, y, "Reset")
    y = Button(parent, y, "Reset all settings", 160, function() StaticPopup_Show(ns.POPUP .. "RESET") end,
        "Settings and positions. Your journal, lists, census, gear ledger, skills, economy log, prices and fishing log are kept.")
    return -y + 10
end

StaticPopupDialogs[ns.POPUP .. "RESET"] = {
    text = "Reset all " .. ns.NAME .. " settings and positions? Your logged data (journal, lists, census, gear, skills, economy, prices, fishing) is kept.",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function() if ns.Main then ns.Main.ResetSettings() end end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs[ns.POPUP .. "DELETE"] = {
    text = "Delete " .. ns.NAME .. " sightings %s?",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function(self, days)
        local removed = ns.Journal.Delete(days or nil)
        ns.Print(removed .. " sightings deleted.")
        Apply()
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

---------------------------------------------------------------------------
-- Tabs
---------------------------------------------------------------------------
local LAYOUT = {
    { label = "General", pages = {
        { label = "Panel", build = Pages.Panel },
        { label = "Nameplates", build = Pages.Plates },
    } },
    { label = "Alerts", pages = {
        { label = "Triggers", build = Pages.Triggers },
        { label = "Effects", build = Pages.Effects },
    } },
    { label = "Safety", pages = {
        { label = "Safety", build = Pages.Safety },
    } },
    { label = "Stealth", pages = {
        { label = "Stealth", build = Pages.Stealth },
    } },
    { label = "Journal", pages = {
        { label = "Overview", build = Pages.JournalOverview },
        { label = "Lists", build = Pages.Lists },
        { label = "Manage data", build = Pages.JournalManage },
    } },
    { label = "Advanced", pages = {
        { label = "Advanced", build = Pages.Advanced },
    } },
}

-- Lets optional modules add a top-level tab (before `beforeLabel`, default
-- "Advanced"). Must be called at file load, before the panel is built.
function Options.AddTab(def, beforeLabel)
    for _, label in ipairs({ beforeLabel or "Advanced", "Advanced" }) do
        for i, existing in ipairs(LAYOUT) do
            if existing.label == label then
                table.insert(LAYOUT, i, def)
                return
            end
        end
    end
    LAYOUT[#LAYOUT + 1] = def
end

---------------------------------------------------------------------------
-- Window: sections on the left, sub-tabs on top, a scrolling page
---------------------------------------------------------------------------
-- A plain scroll frame with mouse-wheel scrolling and a thin position bar
-- (no template: same look everywhere).
local function MakeScroll(parent, build)
    local scroll = CreateFrame("ScrollFrame", nil, parent)
    scroll:SetPoint("TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", -10, 4)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(CONTENT_WIDTH, 100)
    scroll:SetScrollChild(child)
    local track = Style.Texture(parent, "ARTWORK", { 1, 1, 1, 0.05 })
    track:SetWidth(3)
    track:SetPoint("TOPRIGHT", -4, -6)
    track:SetPoint("BOTTOMRIGHT", -4, 6)
    local thumb = Style.Texture(parent, "OVERLAY", { COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.6 })
    thumb:SetWidth(3)
    local function UpdateBar()
        local view, total = scroll:GetHeight() or 0, child:GetHeight() or 0
        local shown = total > view + 1 and view > 0
        track:SetShown(shown)
        thumb:SetShown(shown)
        if not shown then return end
        local range = total - view
        local h = math.max(20, (view - 12) * view / total)
        local offset = (scroll:GetVerticalScroll() or 0) / range * (view - 12 - h)
        thumb:ClearAllPoints()
        thumb:SetHeight(h)
        thumb:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -6 - offset)
    end
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = math.max(0, (child:GetHeight() or 0) - (self:GetHeight() or 0))
        self:SetVerticalScroll(math.max(0, math.min(maxScroll, (self:GetVerticalScroll() or 0) - delta * 40)))
        UpdateBar()
    end)
    scroll:SetScript("OnShow", UpdateBar)
    scroll:SetScript("OnSizeChanged", UpdateBar)
    child:SetHeight(build(child))
    scroll.UpdateBar = UpdateBar
    scroll.parentFrame = parent
    return scroll
end

local tops = {}
local nav, subTabHolder, area
local selectedTop, selectedSub = 1, 1

local function PaintNav()
    for i, b in ipairs(nav) do
        local selected = i == selectedTop
        b.accent:SetShown(selected)
        if selected then
            b.bg:SetColorTexture(COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.14)
        else
            b.bg:SetColorTexture(0, 0, 0, 0)
        end
        b.text:SetTextColor(selected and 1 or 0.75, selected and 0.82 or 0.75, selected and 0.55 or 0.75)
    end
end

local function ShowPage(topIndex, subIndex)
    local top = tops[topIndex]
    local def = LAYOUT[topIndex].pages[subIndex]
    if not top.pages[subIndex] then
        local holder = CreateFrame("Frame", nil, area)
        holder:SetAllPoints()
        top.pages[subIndex] = holder
        holder.scroll = MakeScroll(holder, def.build)
    end
    for i, t in ipairs(tops) do
        for j, page in pairs(t.pages) do
            if i == topIndex and j == subIndex then page:Show() else page:Hide() end
        end
    end
end

function Options.SelectTab(topIndex, subIndex)
    topIndex = math.max(1, math.min(#LAYOUT, topIndex or selectedTop))
    local top = tops[topIndex]
    subIndex = subIndex or top.lastSub or 1
    subIndex = math.max(1, math.min(#LAYOUT[topIndex].pages, subIndex))
    selectedTop, selectedSub = topIndex, subIndex
    top.lastSub = subIndex
    PaintNav()

    for i, t in ipairs(tops) do
        local visible = i == topIndex and #LAYOUT[i].pages > 1
        t.tabs.holder:SetShown(visible)
        if visible then t.tabs:Select(subIndex) end
    end
    local hasSubs = #LAYOUT[topIndex].pages > 1
    area:ClearAllPoints()
    area:SetPoint("TOPLEFT", panel, "TOPLEFT", NAV_WIDTH + 22, hasSubs and -86 or -52)
    area:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -12, 12)
    panel.section:SetText(LAYOUT[topIndex].label)

    ShowPage(topIndex, subIndex)
    Options.Refresh()
end

local function BuildPanel()
    panel = Style.Window(ns.FRAME .. "OptionsWindow", "Settings", nil, nil, { nav = "settings" })
    panel:SetFrameStrata("DIALOG")
    panel:Hide()
    local version = Style.Text(panel, "GameFontDisableSmall", "RIGHT")
    version:SetPoint("TOPRIGHT", -40, -15)
    version:SetText("v" .. ns.VERSION .. "  ·  " .. ns.FLAVOR_NAME)

    -- Sections.
    local navBg = Style.Texture(panel, "BACKGROUND", { 1, 1, 1, 0.02 })
    navBg:SetPoint("TOPLEFT", 1, -39)
    navBg:SetPoint("BOTTOMLEFT", 1, 1)
    navBg:SetWidth(NAV_WIDTH + 10)
    local navLine = Style.Texture(panel, "ARTWORK", COLORS.line)
    navLine:SetWidth(1)
    navLine:SetPoint("TOPLEFT", NAV_WIDTH + 11, -39)
    navLine:SetPoint("BOTTOMLEFT", NAV_WIDTH + 11, 1)
    nav = {}
    for i, def in ipairs(LAYOUT) do
        local b = CreateFrame("Button", nil, panel)
        b:SetSize(NAV_WIDTH, 28)
        b:SetPoint("TOPLEFT", 6, -48 - (i - 1) * 30)
        b.bg = Style.Texture(b, "BACKGROUND")
        b.bg:SetAllPoints()
        b.accent = Style.Texture(b, "ARTWORK", COLORS.accent)
        b.accent:SetWidth(3)
        b.accent:SetPoint("TOPLEFT")
        b.accent:SetPoint("BOTTOMLEFT")
        b.text = Style.Text(b, "GameFontNormal")
        b.text:SetPoint("LEFT", 14, 0)
        b.text:SetPoint("RIGHT", -6, 0)
        b.text:SetText(def.label)
        local hl = Style.Texture(b, "HIGHLIGHT", { 1, 1, 1, 0.05 })
        hl:SetAllPoints()
        b:SetScript("OnClick", function() Options.SelectTab(i) end)
        nav[i] = b
    end

    -- Section title and its sub-tabs.
    panel.section = Style.Text(panel, "GameFontNormalLarge")
    panel.section:SetPoint("TOPLEFT", NAV_WIDTH + 24, -50)
    panel.section:Hide()   -- the selected section is marked in the list; kept for tests / future use

    area = CreateFrame("Frame", ns.FRAME .. "OptionsArea", panel)
    local areaBg = Style.Texture(area, "BACKGROUND", COLORS.card)
    areaBg:SetAllPoints()
    Style.Border(area, COLORS.cardBorder)

    for i, def in ipairs(LAYOUT) do
        local holder = CreateFrame("Frame", nil, panel)
        holder:SetPoint("TOPLEFT", NAV_WIDTH + 22, -48)
        holder:SetPoint("TOPRIGHT", -12, -48)
        holder:SetHeight(26)
        local defs = {}
        for j, page in ipairs(def.pages) do defs[j] = { key = j, label = page.label } end
        local tabs = Style.Tabs(holder, defs, function(j) Options.SelectTab(i, j) end, 120)
        tabs.holder = holder
        local line = Style.HLine(holder)
        line:SetPoint("BOTTOMLEFT", 0, -2)
        line:SetPoint("BOTTOMRIGHT", 0, -2)
        holder:Hide()
        tops[i] = { tabs = tabs, pages = {} }
    end
    Options.SelectTab(1, 1)
    panel:HookScript("OnShow", function()
        Options.Refresh()
        for _, t in ipairs(tops) do
            for _, page in pairs(t.pages) do if page.scroll and page:IsShown() then page.scroll.UpdateBar() end end
        end
    end)
end

-- The entry in the game's Options > AddOns list: it opens the window.
local function BuildLauncher()
    launcher = CreateFrame("Frame", ns.FRAME .. "OptionsPanel")
    launcher.name = ns.NAME
    launcher:Hide()
    local title = launcher:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(ns.TITLE)
    local text = launcher:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    text:SetWidth(520)
    text:SetJustifyH("LEFT")
    text:SetText(ns.NAME .. " has its own settings window. It opens by itself; you can also type " .. ns.Cmd.PREFIX .. ".")
    local open = Style.Button(launcher, "Open " .. ns.NAME .. " settings", 200, function() Options.Open() end)
    open:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -14)
    launcher:SetScript("OnShow", function() Options.Open() end)
    launcher.OnRefresh = function() end
    launcher.OnCommit = function() end
    launcher.OnDefault = function() end
    launcher.OnCancel = function() end
end

function Options.Refresh()
    -- Hidden: the page refreshes when it is shown (OnShow).
    if not panel or not panel:IsShown() then return end
    for _, control in ipairs(controls) do
        if control.Refresh then control:Refresh() end
    end
end

function Options.TabIndex(label)
    for i, def in ipairs(LAYOUT) do
        if def.label == label then return i end
    end
    return 1
end

function Options.OpenTab(topIndex, subIndex)
    Options.Open()
    Options.SelectTab(topIndex, subIndex)
end

function Options.Register()
    BuildPanel()
    BuildLauncher()
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local ok, cat = pcall(Settings.RegisterCanvasLayoutCategory, launcher, ns.NAME)
        if ok and cat then
            if pcall(Settings.RegisterAddOnCategory, cat) then category = cat end
        end
    end
    if not category and InterfaceOptions_AddCategory then
        pcall(InterfaceOptions_AddCategory, launcher)
    end
end

-- Plain frames: opens in combat too.
function Options.Open()
    if not panel then return end
    panel:Show()
    panel:Raise()
    Options.Refresh()
end

function Options.Toggle()
    if panel and panel:IsShown() then panel:Hide() else Options.Open() end
end

function Options.IsShown() return panel ~= nil and panel:IsShown() end
