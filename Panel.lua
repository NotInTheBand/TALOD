-- TALOD - the "Enemies nearby" panel: one row per enemy player, live ones
-- sorted by threat, then recently seen ones fading out. Hover for details,
-- click a live row to target it (out of combat).
--
-- Targeting is a protected action, so clicks go through secure action buttons
-- (type "target", unit = the enemy's nameplate token). Secure buttons cannot
-- be moved, shown or hidden in combat: they are detached and hidden when
-- combat starts and come back when it ends.

local ADDON_NAME, ns = ...
local S = ns.Secret

local Panel = {}
ns.Panel = Panel

local Style = ns.Style
local ROW_HEIGHT, DETAIL_HEIGHT, WIDTH, HEADER, FOOTER = 18, 15, 344, 30, 22
local INSET = 6                     -- content inset inside a row (after the accent bar)
local AURA_SIZE, AURA_X, AURA_FIT = 13, 186 + INSET, 10
local frame, rows, clicks = nil, {}, {}
local vitals, buffs, debuffs = {}, {}, {}          -- scratch, refilled per row
local tipVitals, tipBuffs, tipDebuffs = {}, {}, {} -- scratch for the tooltip
local combatLocked = false

local function db() return ns.DB() end

local CLASS_ICONS = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"
local FALLBACK_TCOORDS = {
    WARRIOR = {0, 0.25, 0, 0.25}, MAGE = {0.25, 0.49609375, 0, 0.25}, ROGUE = {0.49609375, 0.7421875, 0, 0.25},
    DRUID = {0.7421875, 0.98828125, 0, 0.25}, HUNTER = {0, 0.25, 0.25, 0.5}, SHAMAN = {0.25, 0.49609375, 0.25, 0.5},
    PRIEST = {0.49609375, 0.7421875, 0.25, 0.5}, WARLOCK = {0.7421875, 0.98828125, 0.25, 0.5},
    PALADIN = {0, 0.25, 0.5, 0.75},
}

local function SetClassIcon(tex, classFile)
    local coords = (CLASS_ICON_TCOORDS and classFile and CLASS_ICON_TCOORDS[classFile]) or FALLBACK_TCOORDS[classFile or ""]
    if coords then
        tex:SetTexture(CLASS_ICONS)
        tex:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    else
        tex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
end

---------------------------------------------------------------------------
-- Tooltip
---------------------------------------------------------------------------
local function AuraNames(list, n, hidden)
    local parts = {}
    for i = 1, n do
        local a = list[i]
        local s = a.name or "?"
        if a.count and a.count > 1 then s = s .. " x" .. a.count end
        if a.expires and a.duration and a.duration > 0 then
            local left = a.expires - GetTime()
            if left > 0 then s = s .. " (" .. ns.FormatAge(left) .. ")" end
        end
        if a.notable then s = ns.ColorCode(a.notable == "cc" and "threshold" or "danger") .. s .. "|r" end
        parts[#parts + 1] = s
    end
    if hidden > 0 then parts[#parts + 1] = ns.ColorCode("threshold") .. hidden .. " hidden by the game|r" end
    return #parts > 0 and table.concat(parts, ", ") or "none"
end

-- Live state in words. Hidden values read "?", never a reassuring default.
local function AddLiveLines(t, e)
    local v = ns.ReadVitals(e.unit, tipVitals)
    local hp = (v.hp and v.hpMax) and (v.hp .. " / " .. v.hpMax) or (e.dead and "dead") or "?"
    t:Pair("Health", hp)
    if v.power and v.powerMax then
        local label = v.powerToken and _G[v.powerToken]
        t:Pair(type(label) == "string" and label or "Power", v.power .. " / " .. v.powerMax, ns.PowerColor(v.powerToken))
    end
    if v.targetingYou == true then
        t:Pair("Targeting", "YOU", "danger")
    elseif v.targetingYou == nil then
        t:Pair("Targeting", "?", "threshold")
    else
        t:Pair("Targeting", v.targetName or "nobody")
    end
    if v.casting then t:Pair("Casting", v.casting, "threshold") end
    t:Pair("In combat", v.inCombat == nil and "?" or (v.inCombat and "yes" or "no"))
    local nb, hb = ns.ReadAuras(e.unit, "HELPFUL", 40, tipBuffs)
    local nd, hd = ns.ReadAuras(e.unit, "HARMFUL", 40, tipDebuffs)
    t:Line("Buffs: " .. AuraNames(tipBuffs, nb, hb), "good")
    t:Line("Debuffs: " .. AuraNames(tipDebuffs, nd, hd), "bad")
end

local function ShowTooltip(owner, e, clickable)
    if not e then return end
    local t = ns.Tooltip.Open(owner)
    local unitShown = e.unit and t:Unit(e.unit) or false
    if not unitShown then t:Title(ns.Alerts.Describe(e, true)) end
    t:Pair("Distance", e.unit and ns.FormatRange(e.lo, e.hi) or "not in view")
    if e.vanished then
        t:Line("Nameplate vanished close by: probably stealthed.", "danger")
    elseif not e.unit then
        t:Note("Last seen " .. ns.FormatAge(GetTime() - (e.lastSeen or 0)) .. " ago.")
    end
    if e.hostile == nil then t:Line("The game hides whether this player is hostile.", "threshold") end
    if e.flagged == true then
        t:Line("PvP flagged", "danger")
    elseif e.flagged == nil then
        t:Line("PvP: ?", "threshold")
    else
        t:Line("Not PvP flagged", "label")
    end
    if e.rankName then t:Pair("Honor rank", e.rankName .. " (" .. e.rankNumber .. ")") end
    if not unitShown and e.race then t:Pair("Race", e.race) end
    if e.unit then AddLiveLines(t, e) end
    if e.keyed and ns.Journal then t:Note(ns.Journal.Describe(e.key)) end
    if clickable then
        t:Hint("Click: target")
    elseif e.unit and db().panelClickTarget and combatLocked then
        t:Note("Targeting from the panel is paused in combat.")
    end
    t:Show()
end

local function HideTooltip(self)
    ns.Tooltip.HideFor(self)
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------
local function SmallFont(fs, size)
    local file, _, flags = fs:GetFont()
    if file then fs:SetFont(file, size, flags and flags ~= "" and flags or "OUTLINE") end
end

-- Second line of a live row: health bar (HP numbers, not percent) with a
-- thin power bar under it, state tags, then aura icons.
local function CreateDetail(r)
    local det = CreateFrame("Frame", nil, r)
    det:SetPoint("TOPLEFT", r, "TOPLEFT", 0, -ROW_HEIGHT)
    det:SetSize(WIDTH - 2, DETAIL_HEIGHT)
    det.bg = det:CreateTexture(nil, "BACKGROUND")
    det.bg:SetPoint("TOPLEFT", 18 + INSET, 0)
    det.bg:SetSize(92, 13)
    det.bg:SetColorTexture(0, 0, 0, 0.7)
    det.hp = CreateFrame("StatusBar", nil, det)
    det.hp:SetPoint("TOPLEFT", 19 + INSET, -1)
    det.hp:SetSize(90, 9)
    det.hp:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    det.power = CreateFrame("StatusBar", nil, det)
    det.power:SetPoint("TOPLEFT", 19 + INSET, -10)
    det.power:SetSize(90, 2)
    det.power:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    det.hpText = det.hp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    det.hpText:SetPoint("CENTER", 0, 0)
    SmallFont(det.hpText, 9)
    det.tags = det:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    det.tags:SetPoint("TOPLEFT", 114 + INSET, -1)
    det.tags:SetWidth(70)
    det.tags:SetJustifyH("LEFT")
    det.tags:SetWordWrap(false)
    SmallFont(det.tags, 9)
    det.auras = {}
    return det
end

local function AuraIcon(det, j)
    local a = det.auras[j]
    if a then return a end
    a = CreateFrame("Frame", nil, det)
    a:SetSize(AURA_SIZE, AURA_SIZE)
    a:SetPoint("TOPLEFT", AURA_X + (j - 1) * (AURA_SIZE + 1), 0)
    a.border = a:CreateTexture(nil, "BACKGROUND")
    a.border:SetAllPoints()
    a.icon = a:CreateTexture(nil, "ARTWORK")
    a.icon:SetPoint("TOPLEFT", 1, -1)
    a.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    a.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    a.count = a:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    a.count:SetPoint("BOTTOMRIGHT", 2, -1)
    SmallFont(a.count, 8)
    det.auras[j] = a
    return a
end

local function Row(i)
    local r = rows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, frame)
    r:SetSize(WIDTH - 2, ROW_HEIGHT)
    r:EnableMouse(true)
    r:SetScript("OnEnter", function(self) ShowTooltip(self, self.entry, false) end)
    r:SetScript("OnLeave", HideTooltip)
    r.bg = Style.Texture(r, "BACKGROUND")
    r.bg:SetAllPoints()
    r.accent = Style.Texture(r, "ARTWORK")
    r.accent:SetWidth(3)
    r.accent:SetPoint("TOPLEFT")
    r.accent:SetPoint("BOTTOMLEFT")
    r.iconFrame, r.icon = Style.IconFrame(r, 16)
    r.iconFrame:SetPoint("TOPLEFT", INSET - 1, -1)
    local function Text(width, justify, x)
        local fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", x + INSET, -2)
        fs:SetSize(width, 14)
        fs:SetJustifyH(justify)
        fs:SetWordWrap(false)
        return fs
    end
    r.name = Text(98, "LEFT", 18)
    r.level = Text(22, "CENTER", 118)
    r.info = Text(104, "LEFT", 142)
    r.dist = Text(56, "RIGHT", 246)
    r.age = Text(30, "RIGHT", 302)
    r.detail = CreateDetail(r)
    rows[i] = r
    return r
end

local function ClickButton(i)
    local b = clicks[i]
    if b then return b end
    b = CreateFrame("Button", nil, UIParent, "SecureActionButtonTemplate")
    b:RegisterForClicks("AnyUp", "AnyDown")
    b:SetAttribute("type", "target")
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.12)
    b:SetScript("OnEnter", function(self) ShowTooltip(self, self.entry, true) end)
    b:SetScript("OnLeave", HideTooltip)
    b:Hide()
    clicks[i] = b
    return b
end

local function PlaceClick(i, r, e)
    if combatLocked or InCombatLockdown() then return end
    local b = ClickButton(i)
    if not (e and e.unit and db().panelClickTarget) then
        if b:IsShown() then b:Hide() end
        return
    end
    if b.unit ~= e.unit then
        b:SetAttribute("unit", e.unit)
        b.unit = e.unit
    end
    b.entry = e
    b:SetFrameStrata(frame:GetFrameStrata())
    b:SetFrameLevel(frame:GetFrameLevel() + 10)
    b:ClearAllPoints()
    b:SetAllPoints(r)
    b:Show()
end

-- Readable numbers are written as "1234 / 2000". A secret value is handed to
-- the bar and text as is (12.x widgets may show what addons cannot read);
-- if the widget refuses it, the bar is grey and reads "? HP".
local function SetBar(bar, value, valueRaw, max, maxRaw)
    if value and max then
        bar:SetMinMaxValues(0, max)
        bar:SetValue(math.max(0, math.min(value, max)))
        return true
    end
    if (value or valueRaw) and (max or maxRaw) then
        if pcall(bar.SetMinMaxValues, bar, 0, max or maxRaw) and pcall(bar.SetValue, bar, value or valueRaw) then
            return true
        end
    end
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    return false
end

local function SetHealth(det, v, dead)
    if dead then
        SetBar(det.hp, 0, nil, 1, nil)
        det.hpText:SetText(ns.Hex(ns.COLORS.dim) .. "dead|r")
        return
    end
    local shown = SetBar(det.hp, v.hp, v.hpRaw, v.hpMax, v.hpMaxRaw)
    if shown and v.hp and v.hpMax then
        local frac = v.hp / v.hpMax
        det.hp:SetStatusBarColor(frac > 0.5 and (1 - frac) * 2 or 1, frac > 0.5 and 1 or frac * 2, 0)
        det.hpText:SetText(v.hp .. " / " .. v.hpMax)
    elseif shown and pcall(det.hpText.SetFormattedText, det.hpText, "%s / %s", v.hp or v.hpRaw, v.hpMax or v.hpMaxRaw) then
        det.hp:SetStatusBarColor(0.1, 0.8, 0.1)
    else
        if shown then SetBar(det.hp, nil, nil, nil, nil) end
        det.hp:SetStatusBarColor(0.35, 0.35, 0.35)
        det.hpText:SetText(ns.ColorCode("threshold") .. "? HP|r")
    end
end

local function SetPower(det, v)
    local shown = SetBar(det.power, v.power, v.powerRaw, v.powerMax, v.powerMaxRaw)
    local c = shown and ns.PowerColor(v.powerToken) or ns.COLORS.dim
    det.power:SetStatusBarColor(c[1], c[2], c[3])
    det.power:SetShown(shown)
end

-- Short tags, most urgent first; the tooltip spells them out. Unknown shows
-- with "?", never as absent.
local function Tags(e, v)
    local t = {}
    if v.targetingYou == true then t[#t + 1] = ns.ColorCode("danger") .. "@you|r"
    elseif v.targetingYou == nil then t[#t + 1] = ns.ColorCode("threshold") .. "@?|r" end
    if e.flagged == true then t[#t + 1] = ns.ColorCode("danger") .. "PvP|r"
    elseif e.flagged == nil then t[#t + 1] = ns.ColorCode("threshold") .. "PvP?|r" end
    if v.casting then t[#t + 1] = ns.ColorCode("threshold") .. "cast|r" end
    if v.inCombat == true then t[#t + 1] = "cbt"
    elseif v.inCombat == nil then t[#t + 1] = ns.ColorCode("threshold") .. "cbt?|r" end
    return table.concat(t, " ")
end

local BUFF_BORDER, DEBUFF_BORDER, HIDDEN_BORDER = {0.35, 0.35, 0.35}, {0.55, 0.05, 0.05}, {0.6, 0.6, 0.6}
local order, orderHarm = {}, {}

-- Important first: the enemy's big cooldowns, crowd control on them, other
-- debuffs, other buffs. One slot is kept for "?" when the game hid some.
local function FillAuras(det, unit, max)
    local nb, hb = ns.ReadAuras(unit, "HELPFUL", 40, buffs)
    local nd, hd = ns.ReadAuras(unit, "HARMFUL", 40, debuffs)
    local n = 0
    local function Add(list, count, harmful, notable)
        for i = 1, count do
            local a = list[i]
            if (a.notable ~= nil) == notable then
                n = n + 1
                order[n], orderHarm[n] = a, harmful
            end
        end
    end
    Add(buffs, nb, false, true)
    Add(debuffs, nd, true, true)
    Add(debuffs, nd, true, false)
    Add(buffs, nb, false, false)
    local hidden = hb + hd > 0
    local slots = math.min(max, AURA_FIT)
    local shown = math.max(0, math.min(n, hidden and slots - 1 or slots))
    for j = 1, shown do
        local a, icon = order[j], AuraIcon(det, j)
        if a.icon then
            icon.icon:SetTexture(a.icon)
        elseif not pcall(icon.icon.SetTexture, icon.icon, a.iconRaw) then
            icon.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        end
        local c = (a.notable == "buff" and ns.GetColor("danger")) or (a.notable == "cc" and ns.GetColor("threshold"))
            or (orderHarm[j] and DEBUFF_BORDER) or BUFF_BORDER
        icon.border:SetColorTexture(c[1], c[2], c[3], 1)
        icon.count:SetText(a.count and a.count > 1 and a.count or "")
        icon.spellId, icon.unknown = a.spellId, nil
        icon:Show()
    end
    if hidden and slots > 0 then
        shown = shown + 1
        local icon = AuraIcon(det, shown)
        icon.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        icon.border:SetColorTexture(HIDDEN_BORDER[1], HIDDEN_BORDER[2], HIDDEN_BORDER[3], 1)
        icon.count:SetText("")
        icon.spellId, icon.unknown = nil, true
        icon:Show()
    end
    for j = shown + 1, #det.auras do det.auras[j]:Hide() end
end

-- Returns true when the detail line is shown (live entry, setting on).
local function FillDetails(r, e)
    local det = r.detail
    if not (e.unit and db().panelDetails) then
        det:Hide()
        return false
    end
    local v = ns.ReadVitals(e.unit, vitals)
    SetHealth(det, v, e.dead)
    SetPower(det, v)
    det.tags:SetText(Tags(e, v))
    FillAuras(det, e.unit, db().panelMaxAuras or AURA_FIT)
    det:Show()
    return true
end

-- Left accent: what makes this row matter at a glance (your lists, a
-- vanished stealther, hidden hostility).
local function RowAccent(e, list)
    if e.vanished or list == "kos" then return ns.GetColor("danger") end
    if list == "avoid" or e.hostile == nil then return ns.GetColor("threshold") end
    return nil
end

-- Fills a row; returns its height.
local function FillRow(r, e, now, index)
    r.entry = e
    SetClassIcon(r.icon, e.classFile)
    local cc = ns.ClassColor(e.classFile)
    r.name:SetText(e.name or "Unknown")
    r.name:SetTextColor(cc[1], cc[2], cc[3])
    local lc = ns.LevelColor(e)
    r.level:SetText(ns.LevelText(e))
    r.level:SetTextColor(lc[1], lc[2], lc[3])
    local list = ns.ListOf(e.key)
    local info = e.guild and ("<" .. e.guild .. ">") or (e.className or ns.ClassName(e.classFile))
    if list == "kos" then info = ns.ColorCode("danger") .. "KoS|r " .. info
    elseif list == "avoid" then info = ns.ColorCode("threshold") .. "avoid|r " .. info end
    if e.hostile == nil then info = ns.ColorCode("threshold") .. "?|r " .. info end
    r.info:SetText(info)
    local accent = RowAccent(e, list)
    r.accent:SetShown(accent ~= nil)
    if accent then r.accent:SetColorTexture(accent[1], accent[2], accent[3], 1) end
    if index % 2 == 0 then Style.Fill(r.bg, Style.COLORS.stripe) else r.bg:SetColorTexture(0, 0, 0, 0) end
    if e.vanished then
        r.dist:SetText(ns.ColorCode("danger") .. "vanished|r")
    elseif e.dead then
        r.dist:SetText(ns.Hex(ns.COLORS.dim) .. "dead|r")
    elseif e.unit then
        r.dist:SetText(e.rangeOK and ns.FormatRange(e.lo, e.hi) or (ns.ColorCode("threshold") .. "? yd|r"))
    else
        r.dist:SetText(ns.Hex(ns.COLORS.dim) .. "gone|r")
    end
    r.age:SetText(e.unit and "now" or ns.FormatAge(now - (e.lastSeen or now)))
    r:SetAlpha(e.unit and 1 or 0.55)
    local height = FillDetails(r, e) and ROW_HEIGHT + DETAIL_HEIGHT or ROW_HEIGHT
    r:SetHeight(height)
    r:Show()
    return height
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------
local function SavePosition(self)
    local point, _, relPoint, x, y = self:GetPoint(1)
    db().panelPoint = { point or "CENTER", "UIParent", relPoint or "CENTER", math.floor((x or 0) + 0.5), math.floor((y or 0) + 0.5) }
end

function Panel.RestorePosition()
    if not frame then return end
    local p = db().panelPoint or ns.defaults.panelPoint
    frame:ClearAllPoints()
    frame:SetPoint(p[1], UIParent, p[3], p[4], p[5])
end

function Panel.ResetPosition()
    db().panelPoint = { unpack(ns.defaults.panelPoint) }
    Panel.RestorePosition()
end

-- A small square button in the title bar.
local function TitleButton(icon, tooltip, onClick)
    return Style.Button(frame, nil, 18, onClick, tooltip, { icon = icon, height = 18, title = "" })
end

local function Create()
    frame = CreateFrame("Frame", ns.FRAME .. "Panel", UIParent)
    frame.rows = rows
    frame:SetSize(WIDTH, HEADER + ROW_HEIGHT * 4 + FOOTER)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    Style.Surface(frame, "hud")
    local bar = Style.Texture(frame, "BACKGROUND", Style.COLORS.titleBar)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:SetHeight(HEADER - 6)
    -- Unlocked: drag anywhere. Locked: Shift + drag still moves it.
    frame:SetScript("OnDragStart", function(self)
        if db().panelLocked and not IsShiftKeyDown() then return end
        self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self)
    end)

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.title:SetPoint("TOPLEFT", 9, -7)
    frame.title:SetText("Enemies nearby")

    local settings = TitleButton("Interface\\Icons\\INV_Misc_Gear_01", ns.NAME .. " settings",
        function() if ns.Options then ns.Options.Open() end end)
    settings:SetPoint("TOPRIGHT", -4, -3)
    local char = TitleButton("Interface\\Icons\\INV_Chest_Chain_05", "Character: gear, ledger and skills",
        function() if ns.GearUI then ns.GearUI.Toggle() end end)
    char:SetPoint("RIGHT", settings, "LEFT", -3, 0)
    local econ = TitleButton("Interface\\Icons\\INV_Misc_Coin_01", "Economy: money, auctions and trades",
        function() if ns.EconomyUI then ns.EconomyUI.Toggle() end end)
    econ:SetPoint("RIGHT", char, "LEFT", -3, 0)
    local lock = TitleButton(nil, function()
        return db().panelLocked and "Locked (Shift + drag still moves it)" or "Unlocked: drag to move"
    end, function()
        db().panelLocked = not db().panelLocked
        ns.Refresh()
    end)
    lock.tex = lock:CreateTexture(nil, "ARTWORK")
    lock.tex:SetPoint("TOPLEFT", 1, -1)
    lock.tex:SetPoint("BOTTOMRIGHT", -1, 1)
    lock:SetPoint("RIGHT", econ, "LEFT", -3, 0)
    frame.lock = lock
    -- Alerts on / off: the same switch as Settings > Alerts and /talod alerts.
    -- The panel keeps listing enemies either way; only the notifications stop.
    local alerts = TitleButton("Interface\\Icons\\Ability_Warrior_BattleShout", function()
        return db().alertsEnabled and "Enemy alerts on: center text, sound and chat when an enemy appears. Click to mute."
            or "Enemy alerts muted: the panel still lists every enemy. Click to turn alerts back on."
    end, function(self)
        db().alertsEnabled = not db().alertsEnabled
        ns.Print("enemy alerts " .. (db().alertsEnabled and "on." or "muted (the panel still lists enemies)."))
        ns.Refresh()
        if self:GetScript("OnEnter") then self:GetScript("OnEnter")(self) end
    end)
    alerts.muted = alerts:CreateTexture(nil, "OVERLAY")
    alerts.muted:SetPoint("TOPLEFT", 2, -2)
    alerts.muted:SetPoint("BOTTOMRIGHT", -2, 2)
    alerts.muted:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    alerts:SetPoint("RIGHT", lock, "LEFT", -3, 0)
    frame.alerts = alerts

    frame.empty = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.empty:SetPoint("TOPLEFT", 10, -HEADER - 3)
    frame.empty:SetText("No enemy players seen.")

    frame.footerLine = Style.HLine(frame)
    frame.footerLine:SetPoint("BOTTOMLEFT", 1, FOOTER - 2)
    frame.footerLine:SetPoint("BOTTOMRIGHT", -1, FOOTER - 2)
    frame.footer = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.footer:SetPoint("BOTTOMLEFT", 9, 6)
    frame.footer:SetPoint("RIGHT", frame, "RIGHT", -9, 0)
    frame.footer:SetJustifyH("LEFT")
    frame.footer:SetWordWrap(false)

    Panel.RestorePosition()
    Panel.ApplyStyle()
end

function Panel.ApplyStyle()
    if not frame then return end
    frame:SetScale(db().panelScale or 1)
    local locked = db().panelLocked
    frame.lock.tex:SetTexture(locked and "Interface\\Buttons\\LockButton-Locked-Up" or "Interface\\Buttons\\LockButton-Unlocked-Up")
    local on = db().alertsEnabled and true or false
    frame.alerts.muted:SetShown(not on)
    if frame.alerts.icon.SetDesaturated then frame.alerts.icon:SetDesaturated(not on) end
    frame.alerts.icon:SetAlpha(on and 1 or 0.45)
    -- Unlocked shows in the accent color so a movable panel is obvious.
    local c = locked and Style.COLORS.border or Style.COLORS.accent
    frame:SetBorderColor(c[1], c[2], c[3], locked and 1 or 0.9)
end

function Panel.Update()
    if not frame then return end
    local d = db()
    if not d.enabled or not d.panelShown then
        frame:Hide()
        return
    end
    local now = GetTime()
    local list = ns.Spotter.Sorted()
    local maxRows = math.max(1, d.panelRows or 8)
    local live, total = ns.Spotter.Count()
    frame.title:SetText(string.format("Enemies nearby  %s%d|r%s", live > 0 and ns.ColorCode("danger") or "|cffffffff", live,
        total > live and string.format("  |cff999999(+%d recent)|r", total - live) or ""))

    local shown = math.min(#list, maxRows)
    local y = -HEADER
    for i = 1, shown do
        local r = Row(i)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, y)
        y = y - FillRow(r, list[i], now, i)
        PlaceClick(i, r, list[i])
    end
    if shown == 0 then y = -HEADER - ROW_HEIGHT end
    for i = shown + 1, #rows do
        rows[i]:Hide()
        rows[i].entry = nil
        PlaceClick(i, rows[i], nil)
    end
    frame.empty:SetShown(shown == 0)

    local targetText = ns.Plates and ns.Plates.TargetText(false)
    local footer = targetText and ("Target: " .. targetText) or nil
    frame.footer:SetText(footer or "")
    frame.footerLine:SetShown(footer ~= nil)
    frame:SetHeight(-y + (footer and FOOTER or 6) + 4)

    if shown == 0 and not footer and d.panelHideEmpty and d.panelLocked then
        frame:Hide()
    else
        frame:Show()
    end
end

-- Before combat lockdown: detach and hide every secure button so nothing
-- protected depends on the panel during combat.
local function EnterCombat()
    combatLocked = true
    for _, b in ipairs(clicks) do
        b:Hide()
        b:ClearAllPoints()
    end
end

ns.RegisterModule("Panel", {
    init = Create,
    tick = Panel.Update,
    refresh = function()
        Panel.ApplyStyle()
        Panel.Update()
    end,
    events = { "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" },
    onEvent = function(event)
        if event == "PLAYER_REGEN_DISABLED" then
            EnterCombat()
        else
            combatLocked = false
            Panel.Update()
        end
    end,
})
