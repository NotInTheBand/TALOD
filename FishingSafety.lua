-- TALOD - safety while fishing. A fishing pole in your hands is no weapon,
-- and the bobber keeps your eyes off the screen edges:
--   * an enemy player in view while the pole is equipped -> a loud warning
--     and a HUD row (hidden hostility is never "enemy": no warning for it);
--   * a one-click swap back to your weapons (a secure macro button under the
--     HUD and one over the HUD's Weapon row; one click is one equip, like the
--     panel's target buttons);
--   * an enemy player who targets you while you fish -> a warning, often the
--     only sign before a rogue opens or a hunter shoots;
--   * the nearest player's range bracket on the HUD (unknown is "? yd").

local ADDON_NAME, ns = ...
local S = ns.Secret
local Style = ns.Style
local HEX = Style.HEX
local Fishing = ns.Fishing

local Safety = {}
ns.FishingSafety = Safety

local MAIN, OFF = 16, 17
local SETTLE = 1            -- s after an equipment change before the hands are read
local IN_VIEW = 3           -- s a plate-less entry (your target) still counts as in view
local POLE_GAP = 8          -- s between two pole warnings, whoever they are about
local TARGET_REPEAT = 30    -- s before the same player targeting you alerts again
local MAX_READS = 10        -- units read for "targeting you" per tick

local poleWarnAt, lastPoleWarn = {}, -math.huge
local targetAt, targeting = {}, {}
local equipChangedAt
local requested = {}
local scratch = {}
local button

local function db() return ns.DB() end
local function Num(v) return type(v) == "number" and v or nil end

---------------------------------------------------------------------------
-- Your weapons
---------------------------------------------------------------------------
local function CharKey() return ns.Gear and ns.Gear.CharKey() or nil end

local function Store()
    if type(db().fishSwap) ~= "table" then db().fishSwap = {} end
    return db().fishSwap
end

-- true for a fishing pole, false for anything else, nil when the game does not say.
local function IsPole(id)
    local fn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if type(fn) ~= "function" then return nil end
    local _, _, _, _, _, classID, subclassID = S.CallMulti(7, fn, id)
    if type(classID) ~= "number" then return nil end
    return classID == 2 and subclassID == 20
end
Safety.IsPole = IsPole

-- The weapons remembered for this character: { mh = id, oh = id or nil }.
function Safety.Weapons()
    local key = CharKey()
    local w = key and Store()[key]
    if type(w) == "table" and Num(w.mh) then return w end
    return nil
end

-- Reads your hands and keeps them when they hold no fishing pole. Read a
-- moment after the change: equipping the pole (two-handed) empties the off
-- hand first, and that half-done state must not overwrite the off hand.
function Safety.Remember()
    local key = CharKey()
    if not key then return end
    local mh = Num(S.Call(GetInventoryItemID, "player", MAIN))
    -- Bare hands or an unknown item: keep what was remembered.
    if not mh or IsPole(mh) ~= false then return end
    local oh = Num(S.Call(GetInventoryItemID, "player", OFF))
    local w = Store()[key]
    if type(w) ~= "table" or w.mh ~= mh or w.oh ~= oh then
        Store()[key] = { mh = mh, oh = oh, t = time() }
    end
end

local function ItemName(id)
    local fn = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local name = type(fn) == "function" and S.CallMulti(1, fn, id) or nil
    if type(name) == "string" and name ~= "" then return name end
    -- Not cached yet: ask once; the macro switches to the name when it arrives.
    if not requested[id] and C_Item and C_Item.RequestLoadItemDataByID then
        requested[id] = true
        pcall(C_Item.RequestLoadItemDataByID, id)
    end
    return nil
end

local function ItemIcon(id)
    local fn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    local icon = type(fn) == "function" and select(5, S.CallMulti(5, fn, id)) or nil
    return icon or "Interface\\Icons\\INV_Sword_04"
end

-- How many you carry; nil when the game does not say.
local function Count(id)
    local fn = (C_Item and C_Item.GetItemCount) or GetItemCount
    if type(fn) ~= "function" then return nil end
    return Num(S.Call(fn, id))
end

-- The remembered weapons when they are still in your bags (a sold or banked
-- weapon makes no button).
function Safety.SwapWeapons()
    local w = Safety.Weapons()
    if not w or Count(w.mh) == 0 then return nil end
    return w
end

---------------------------------------------------------------------------
-- Second copy of the same weapon (two identical daggers). /equipslot turns
-- its argument into a link and equips "an item matching it", so its second
-- line takes the copy the first line is already moving and the off hand stays
-- empty. The macro clicks this plain button instead: it equips the copy in
-- your bags that is not locked (the moving one is) by its bag slot.
---------------------------------------------------------------------------
local OFFHAND_BUTTON = ns.FRAME .. "FishingOffHandButton"

local function BagSlotInfo(bag, slot)
    local api = C_Container or {}
    local link = S.Call(api.GetContainerItemLink or GetContainerItemLink, bag, slot)
    local id = type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
    if not id then return nil end
    local locked
    if type(api.GetContainerItemInfo) == "function" then
        local info = S.Call(api.GetContainerItemInfo, bag, slot)
        locked = type(info) == "table" and S.Value(info.isLocked) or nil
    elseif type(GetContainerItemInfo) == "function" then
        locked = select(3, S.CallMulti(3, GetContainerItemInfo, bag, slot))
    end
    return id, locked == true
end

function Safety.EquipSecondCopy()
    local w = Safety.Weapons()
    -- No combat check: weapons can be equipped in combat, and this runs only
    -- from the swap button's click.
    if not w or not Num(w.oh) then return false end
    if Num(S.Call(GetInventoryItemID, "player", OFF)) == w.oh then return false end
    if type(CursorHasItem) == "function" and S.Call(CursorHasItem) == true then return false end
    local api = C_Container or {}
    local numSlots = api.GetContainerNumSlots or GetContainerNumSlots
    local pickup = api.PickupContainerItem or PickupContainerItem
    if type(numSlots) ~= "function" or type(pickup) ~= "function" or type(EquipCursorItem) ~= "function" then return false end
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        for slot = 1, Num(S.Call(numSlots, bag)) or 0 do
            local id, locked = BagSlotInfo(bag, slot)
            if id == w.oh and not locked then
                pcall(pickup, bag, slot)
                pcall(EquipCursorItem, OFF)
                -- Never leave the dagger on the cursor if the game refused.
                if type(CursorHasItem) == "function" and S.Call(CursorHasItem) == true and ClearCursor then ClearCursor() end
                return true
            end
        end
    end
    return false
end

local offHandButton
local function OffHandButton()
    if offHandButton then return offHandButton end
    offHandButton = CreateFrame("Button", OFFHAND_BUTTON, UIParent)
    offHandButton:Hide()
    offHandButton:SetScript("OnClick", function() ns.SafeCall(Safety.EquipSecondCopy) end)
    return offHandButton
end

-- "/equipslot 16 <name>" per hand. /equipslot takes a name or an item string
-- ("item:1234"); the name is used once the item cache has it. The same item in
-- both hands: the off hand comes from the button above.
function Safety.MacroText(w)
    w = w or Safety.SwapWeapons()
    if not w then return nil end
    local function Ref(id) return ItemName(id) or ("item:" .. id) end
    local text = "/equipslot " .. MAIN .. " " .. Ref(w.mh)
    if Num(w.oh) and w.oh == w.mh then
        -- Two copies needed: the one for the main hand plus one more.
        local n = Count(w.oh)
        if n == nil or n >= 2 then
            OffHandButton()
            text = text .. "\n/click " .. OFFHAND_BUTTON
        end
    elseif Num(w.oh) and Count(w.oh) ~= 0 then
        text = text .. "\n/equipslot " .. OFF .. " " .. Ref(w.oh)
    end
    return text
end

local function WeaponText(w)
    if not w then return nil end
    local text = ItemName(w.mh) or ("item " .. w.mh)
    if Num(w.oh) then text = text .. " + " .. (ItemName(w.oh) or ("item " .. w.oh)) end
    return text
end

---------------------------------------------------------------------------
-- Players in view
---------------------------------------------------------------------------
local function InView(e, now)
    if e.dead then return false end
    return e.unit ~= nil or now - (e.lastSeen or 0) <= IN_VIEW
end

-- Players in view: enemies (hostile true), hidden hostility, and the nearest
-- known range bracket plus how many have no range.
function Safety.Nearby()
    local now = GetTime()
    local out = { enemies = 0, hidden = 0, unknownRange = 0, list = {} }
    for _, e in pairs(ns.Spotter.nearby) do
        if InView(e, now) then
            out.list[#out.list + 1] = e
            if e.hostile == true then out.enemies = out.enemies + 1 else out.hidden = out.hidden + 1 end
            -- A remembered entry's bracket is stale: only live plates count as a range.
            local lo, hi = e.unit and e.lo, e.unit and e.hi
            local d = hi or lo
            if not d then
                out.unknownRange = out.unknownRange + 1
            elseif not out.nearest or d < out.nearestD then
                out.nearest, out.nearestD, out.lo, out.hi = e, d, lo, hi
            end
        end
    end
    return out
end

-- "1 in view · 20–30 yd"; a player without a range adds "? yd", never a number.
function Safety.NearestText(n)
    n = n or Safety.Nearby()
    local total = n.enemies + n.hidden
    if total == 0 then return HEX.muted .. "none in view|r", false end
    local text = total .. " in view"
    if n.hidden > 0 then text = text .. HEX.muted .. " (" .. n.hidden .. " hostility ?)|r" end
    local range
    if n.nearest then
        range = ns.FormatRange(n.lo, n.hi)
        if n.unknownRange > 0 then range = range .. ", " .. n.unknownRange .. " at ? yd" end
    else
        range = "? yd"
    end
    return (n.enemies > 0 and HEX.bad or HEX.gold) .. text .. "|r  ·  " .. range, n.enemies > 0
end

---------------------------------------------------------------------------
-- Warnings
---------------------------------------------------------------------------
-- Enemy warnings follow the panel's mute (General > alerts), as every other
-- enemy alert does; the HUD rows show regardless.
local function AlertsOn() return db().enabled and db().alertsEnabled end

local function Distance(e)
    if not e.unit or not (e.lo or e.hi) then return "  ? yd" end
    return "  " .. ns.FormatRange(e.lo, e.hi)
end

-- The enemy alert (and the fishing enemy sound) already played the sound for
-- a player spotted this moment.
local function SoundAlreadyPlayed(e, now)
    if now - (e.firstSeen or -math.huge) > 1 then return false end
    local d = db()
    if d.alertSound and ns.IsLoud(e) then return true end
    return d.fishEnemySound and d.fishingEnabled and Fishing.IsFishing()
end

local function Sound(e, now)
    if db().alertSound and not SoundAlreadyPlayed(e, now) then ns.Alerts.PlayChosenSound() end
end

-- Pole in your hands and an enemy player in view.
function Safety.CheckPole(now)
    now = now or GetTime()
    if not db().fishPoleWarn or not AlertsOn() then return end
    if Fishing.PoleEquipped() ~= true then return end
    for _, e in pairs(ns.Spotter.nearby) do
        -- Hidden hostility is never "enemy" (it is counted on the HUD instead).
        if e.hostile == true and InView(e, now) and now - lastPoleWarn >= POLE_GAP
            and now - (poleWarnAt[e.key] or -math.huge) >= (db().fishPoleWarnRepeat or 60) then
            poleWarnAt[e.key], lastPoleWarn = now, now
            local swap = Safety.SwapWeapons() and "  (click Swap)" or ""
            ns.Alerts.Show("Fishing pole in your hands — swap!" .. swap .. "\nEnemy: " .. ns.Alerts.Describe(e) .. Distance(e),
                ns.GetColor("danger"), true)
            Sound(e, now)
            return
        end
    end
end

-- An enemy player who starts targeting you while you fish. A hidden target
-- (nil) never alerts.
function Safety.CheckTargeting(now)
    now = now or GetTime()
    local watching = db().fishTargetAlert and AlertsOn() and (Fishing.IsFishing() or Fishing.PoleEquipped() == true)
    if not watching then
        wipe(targeting)
        return
    end
    local reads = 0
    for key, e in pairs(ns.Spotter.nearby) do
        local t = nil
        if e.hostile == true and e.unit and not e.dead and reads < MAX_READS then
            reads = reads + 1
            t = ns.ReadVitals(e.unit, scratch).targetingYou
        end
        if t == true and not targeting[key] and now - (targetAt[key] or -math.huge) >= TARGET_REPEAT then
            targetAt[key] = now
            ns.Alerts.Show((e.name or "An enemy player") .. " is targeting you!" .. Distance(e)
                .. "\n" .. ns.Alerts.Describe(e), ns.GetColor("danger"), true)
            Sound(e, now)
            if db().alertChat then ns.Print(ns.ColorCode("danger") .. "targeting you|r " .. ns.Alerts.Describe(e, true) .. Distance(e)) end
        end
        targeting[key] = t == true or nil
    end
    for key in pairs(targeting) do
        if not ns.Spotter.nearby[key] then targeting[key] = nil end
    end
end

---------------------------------------------------------------------------
-- Swap button: SecureActionButtonTemplate, type "macro". Attributes, Show,
-- Hide and SetPoint are refused in combat, so it is set up only out of
-- combat; once shown it stays clickable through the fight (weapons can be
-- equipped in combat) and goes away after it when the pole is gone. It is
-- placed against UIParent, not anchored to the HUD: an anchor would make the
-- HUD protected too and block its moving and resizing in combat.
---------------------------------------------------------------------------
local function ButtonTooltip(self)
    local w = Safety.SwapWeapons()
    ns.Tooltip.Text(self, { "Swap to your weapon",
        w and ("Equips " .. WeaponText(w) .. ". One click, one equip; works in combat once shown.") or "No weapon remembered.",
        "Keybind: a macro with  /click " .. ns.FRAME .. "FishingSwapButton",
        HEX.muted .. "Remembered each time you hold a weapon (not a fishing pole).|r" })
end

local function Button()
    if button then return button end
    button = CreateFrame("Button", ns.FRAME .. "FishingSwapButton", UIParent, "SecureActionButtonTemplate")
    button:SetSize(170, 22)
    button:SetFrameStrata("MEDIUM")
    button:RegisterForClicks("AnyUp", "AnyDown")
    button:SetAttribute("type", "macro")
    local bg = Style.Texture(button, "BACKGROUND", Style.COLORS.button)
    bg:SetAllPoints()
    Style.Border(button, Style.COLORS.border)
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetSize(16, 16)
    button.icon:SetPoint("LEFT", 4, 0)
    button.label = Style.Text(button, "GameFontNormalSmall", "LEFT")
    button.label:SetPoint("LEFT", 24, 0)
    button.label:SetPoint("RIGHT", -6, 0)
    local hl = button:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.12)
    button:SetScript("OnEnter", ButtonTooltip)
    button:SetScript("OnLeave", function() ns.Tooltip.Hide() end)
    button:Hide()
    return button
end
Safety.Button = Button

local function Place(b)
    local hud = ns.FishingUI and ns.FishingUI.HUDFrame()
    local left, bottom = hud and hud:IsShown() and hud:GetLeft(), hud and hud:IsShown() and hud:GetBottom()
    if left and bottom then
        -- The apply-lure button sits right under the HUD too: go below it, or
        -- it covers this one.
        local lure = _G[ns.FRAME .. "FishingLureButton"]
        if lure and lure:IsShown() then bottom = bottom - 2 - (lure:GetHeight() or 20) end
        b:SetScale(hud:GetScale() or 1)
        if b.at and b.at[1] == left and b.at[2] == bottom then return end
        b.at = { left, bottom }
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, bottom - 2)
    elseif not b.at or b.at[1] ~= "free" then
        b.at = { "free" }
        b:ClearAllPoints()
        b:SetPoint("CENTER", UIParent, "CENTER", 0, -220)
    end
end

-- Out of combat only: macro text, place, show or hide.
function Safety.UpdateButton()
    if InCombatLockdown() then return end
    local w = db().enabled and db().fishSwapButton and Fishing.PoleEquipped() == true and Safety.SwapWeapons()
    if not w then
        if button and button:IsShown() then button:Hide() end
        return
    end
    local b = Button()
    local text = Safety.MacroText(w)
    if b:GetAttribute("macrotext") ~= text then b:SetAttribute("macrotext", text) end
    b.icon:SetTexture(ItemIcon(w.mh))
    b.label:SetText("Swap to " .. WeaponText(w))
    Place(b)
    if not b:IsShown() then b:Show() end
end

---------------------------------------------------------------------------
-- Weapon row: a secure macro button over the HUD's Weapon row, same macro as
-- the swap button (one click, one equip). It is anchored to the row, so it is
-- set up out of combat only and hidden when combat starts (the HUD stays
-- movable); the swap button under the HUD covers the fight.
---------------------------------------------------------------------------
local rowButton

local function RowTooltip(self)
    local w = Safety.SwapWeapons()
    if not w then return end
    ns.Tooltip.Text(self, { "Weapon",
        "A fishing pole is no weapon. Turns red when an enemy player is in view.",
        HEX.good .. "Click: equip " .. WeaponText(w) .. "|r (one click, one equip).",
        HEX.muted .. "Set up out of combat only; in combat use the swap button under the HUD.|r" })
end

local function CreateRowButton()
    if rowButton or InCombatLockdown() then return rowButton end
    local ok, b = pcall(CreateFrame, "Button", ns.FRAME .. "FishingWeaponRowButton", UIParent, "SecureActionButtonTemplate")
    if not ok or not b then return nil end
    b:RegisterForClicks("AnyUp", "AnyDown")
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    b:SetScript("OnEnter", RowTooltip)
    b:SetScript("OnLeave", function() ns.Tooltip.Hide() end)
    b:Hide()
    rowButton = b
    return b
end

local function ClearRowButton()
    if not rowButton then return end
    if rowButton.macro ~= nil then
        rowButton:SetAttribute("type", nil)
        rowButton:SetAttribute("macrotext", nil)
        rowButton.macro = nil
    end
    rowButton.row = nil
    if rowButton:IsShown() then rowButton:Hide() end
end

-- Runs after every HUD redraw (its rows can move) and on the tick.
function Safety.UpdateRowButton()
    if InCombatLockdown() then return end
    local UI = ns.FishingUI
    local row = UI and UI.HUDRowByKey and UI.HUDRowByKey("weapon")
    local w = row and db().enabled and db().fishSwapRow and Fishing.PoleEquipped() == true and Safety.SwapWeapons()
    local text = w and Safety.MacroText(w)
    if not text then return ClearRowButton() end
    local b = CreateRowButton()
    if not b then return end
    if b.macro ~= text then
        b:SetAttribute("type", "macro")
        b:SetAttribute("macrotext", text)
        b.macro = text
    end
    if b.row ~= row then
        local hud = UI.HUDFrame()
        b:SetScale(hud and hud:GetScale() or 1)
        b:SetFrameStrata(hud and hud:GetFrameStrata() or "MEDIUM")
        b:SetFrameLevel((row:GetFrameLevel() or 1) + 5)
        b:ClearAllPoints()
        b:SetAllPoints(row)
        b.row = row
    end
    if not b:IsShown() then b:Show() end
end

-- Anchored to the HUD: away before combat locks it in place.
local function HideRowButton()
    if not rowButton then return end
    rowButton:Hide()
    rowButton:ClearAllPoints()
    rowButton.row = nil
end

-- Colors are no protected change: the border turns red in combat too.
local function PaintButton(danger)
    if not button or not button.SetBorderColor then return end
    local c = danger and ns.GetColor("danger") or Style.COLORS.border
    button:SetBorderColor(c[1], c[2], c[3], 1)
end

---------------------------------------------------------------------------
-- HUD and Now rows
---------------------------------------------------------------------------
local function WeaponRow()
    if Fishing.PoleEquipped() ~= true then return nil end
    local n = Safety.Nearby()
    local w = Safety.SwapWeapons()
    local danger = n.enemies > 0
    local click = w and db().fishSwapRow and not InCombatLockdown()
    local value
    if danger then
        value = HEX.bad .. "fishing pole in hands — " .. (click and "click to swap" or "swap") .. "|r"
    elseif w then
        value = HEX.muted .. (click and "pole · click to equip: |r" or "fishing pole · swap: |r") .. WeaponText(w)
    else
        value = HEX.muted .. "fishing pole · no weapon remembered|r"
    end
    return { key = "weapon", label = "Weapon", value = value, warn = danger, icon = w and ItemIcon(w.mh) or "Interface\\Icons\\INV_Sword_04",
        tip = { "Weapon", "A fishing pole is no weapon. Turns red when an enemy player is in view.",
            w and ("Click this line, the swap button or a keybind (/click " .. ns.FRAME .. "FishingSwapButton): " .. WeaponText(w)) or "Hold your weapon once and it is remembered." } }
end

local function NearestRow()
    if not db().fishNearestRow then return nil end
    local text, warn = Safety.NearestText()
    return { key = "nearest", label = "Nearest", value = text, warn = warn, icon = "Interface\\Icons\\Ability_Hunter_SniperShot",
        tip = { "Nearest player", "Range bracket of the closest player in view (nameplates). A player whose range "
            .. "the game hides counts as ? yd, never as far away. Hidden hostility is counted, not called an enemy." } }
end

---------------------------------------------------------------------------
-- Tick, events
---------------------------------------------------------------------------
local function Tick()
    if not db().enabled then
        Safety.UpdateButton()
        Safety.UpdateRowButton()
        return
    end
    local now = GetTime()
    if equipChangedAt and now - equipChangedAt >= SETTLE then
        equipChangedAt = nil
        Safety.Remember()
    end
    Safety.CheckPole(now)
    Safety.CheckTargeting(now)
    Safety.UpdateButton()
    Safety.UpdateRowButton()
    PaintButton(Fishing.PoleEquipped() == true and Safety.Nearby().enemies > 0)
end

local function OnEvent(event, unit)
    if event == "PLAYER_EQUIPMENT_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
        equipChangedAt = GetTime()
    elseif event == "PLAYER_REGEN_DISABLED" then
        HideRowButton()
    elseif event == "PLAYER_REGEN_ENABLED" then
        Safety.UpdateButton()
        Safety.UpdateRowButton()
    end
end

---------------------------------------------------------------------------
-- Settings page, slash
---------------------------------------------------------------------------
local function StatusText()
    local w = Safety.Weapons()
    local here = Safety.SwapWeapons()
    return "Remembered weapon: " .. (w and (WeaponText(w) .. ((w and not here) and (HEX.gold .. "  (not in your bags)|r") or "")) or "none yet (hold your weapon once)")
end

local function BuildPage(parent)
    local W = ns.Options.Widgets
    local y = -12
    y = W.Paragraph(parent, y, "A fishing pole is no weapon and the bobber keeps your eyes busy. These warnings use "
        .. "what the game shows (nameplates, targets): turn on enemy nameplates (V). A player whose hostility is hidden "
        .. "is counted, never called an enemy; a hidden range is ? yd. Enemy warnings follow the alert mute in General.",
        "GameFontHighlightSmall")
    y = W.Header(parent, y, "Warnings")
    y = W.Checkbox(parent, y, "fishPoleWarn", "Warn me: fishing pole in my hands with an enemy in view",
        "A loud center-screen warning and your alert sound when an enemy player is in view while your fishing pole is equipped.")
    y = W.Slider(parent, y, "fishPoleWarnRepeat", "Same player again after", 15, 300, 15, "%d s")
    y = W.Checkbox(parent, y, "fishTargetAlert", "Warn me when an enemy player targets me while fishing",
        "Often the only sign before a rogue opens or a hunter shoots. Only when the game shows the target: a hidden one never alerts.")
    y = W.Header(parent, y, "HUD")
    y = W.Checkbox(parent, y, "fishNearestRow", "Show the nearest player's range on the HUD",
        "\"1 in view · 20–30 yd\". A player without a readable range counts as ? yd.")
    y = W.Checkbox(parent, y, "fishSwapButton", "Show a weapon swap button while the fishing pole is equipped",
        "One click equips the weapon (and off hand) you held last. Placed under the fishing HUD out of combat; it stays "
        .. "usable in combat once shown. Keybind: a macro with  /click " .. ns.FRAME .. "FishingSwapButton")
    y = W.Checkbox(parent, y, "fishSwapRow", "Click the HUD's Weapon line to equip my weapon",
        "One click equips the weapon (and off hand) you held last, same as the swap button. Set up out of combat only; "
        .. "in combat use the swap button under the HUD.")
    y = W.LiveText(parent, y, 30, StatusText)
    return -y + 10
end

local function Slash(arg)
    if arg == "safety" then
        local d = db()
        local function On(v) return v and "on" or "off" end
        ns.Print("fishing safety — pole warning " .. On(d.fishPoleWarn) .. ", targeting you " .. On(d.fishTargetAlert)
            .. ", nearest range " .. On(d.fishNearestRow) .. ", swap button " .. On(d.fishSwapButton) .. ".")
        ns.Print(StatusText())
        local macro = Safety.MacroText()
        if macro then ns.Print("swap macro: " .. macro:gsub("\n", " ; ")) end
        return true
    elseif arg == "safety on" or arg == "safety off" then
        local on = arg == "safety on"
        local d = db()
        d.fishPoleWarn, d.fishTargetAlert, d.fishNearestRow, d.fishSwapButton = on, on, on, on
        ns.Print("fishing safety " .. (on and "on." or "off."))
        return true
    end
    return false
end

Fishing.AddSlash(Slash, "safety [on|off]")
table.insert(Fishing.settingsTab.pages, { label = "Safety", build = BuildPage })
ns.FishingUI.AddHUDLine(WeaponRow)
ns.FishingUI.AddHUDLine(NearestRow)
ns.FishingUI.OnHUDUpdated(function() Safety.UpdateRowButton() end)
ns.FishingUI.AddNowRows(function(rows)
    local row = WeaponRow()
    if row then rows[#rows + 1] = { label = row.label, text = row.value } end
    local nr = NearestRow()
    if nr then rows[#rows + 1] = { label = nr.label, text = nr.value } end
end)

function Safety.Reset()
    wipe(poleWarnAt) wipe(targetAt) wipe(targeting)
    lastPoleWarn = -math.huge
end

ns.RegisterModule("FishingSafety", {
    defaults = {
        fishPoleWarn = true,
        fishPoleWarnRepeat = 60,
        fishTargetAlert = true,
        fishNearestRow = true,
        fishSwapButton = true,
        fishSwapRow = true,
        fishSwap = {},
    },
    events = { "PLAYER_EQUIPMENT_CHANGED", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" },
    init = function()
        Store()
        equipChangedAt = GetTime()
        -- Right after the enemy alert, so a pole warning is the line left on screen.
        ns.Spotter.On("spotted", function(e) if e.hostile == true then Safety.CheckPole() end end)
    end,
    onEvent = OnEvent,
    tick = Tick,
})
