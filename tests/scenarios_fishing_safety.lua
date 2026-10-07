-- Fishing safety (FishingSafety.lua): pole-in-hands warning, the weapon swap
-- button, enemy targeting you while fishing, nearest range on the HUD.
local scenarios, T = ...
local check, plateAdd, plateRemove, alertText, resetOutput = T.check, T.plateAdd, T.plateRemove, T.alertText, T.resetOutput

local SWORD, SHIELD, GREATSWORD, POLE = 2000, 2001, 2002, 6256

local function items()
    MOCK.items[SWORD] = { classID = 2, subclassID = 7, equipLoc = "INVTYPE_WEAPON" }
    MOCK.items[SHIELD] = { classID = 4, subclassID = 6, equipLoc = "INVTYPE_SHIELD" }
    MOCK.items[GREATSWORD] = { classID = 2, subclassID = 8, equipLoc = "INVTYPE_2HWEAPON" }
end

-- Puts items in your hands the way the game does: one slot after the other,
-- an event for each.
local function equip(mh, oh)
    MOCK.equippedIDs[17] = oh
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 17, oh == nil)
    MOCK.equippedIDs[16] = mh
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 16, mh == nil)
    MOCK.Tick(1.2)
end

-- Remembers sword + shield, then picks up the pole again.
local function setup(iface, opts)
    items()
    local ns = T.fishingSetup(iface, opts)
    equip(SWORD, SHIELD)
    -- Equipping the two-handed pole empties the off hand first: that moment
    -- must not overwrite the remembered shield.
    MOCK.equippedIDs[17] = nil
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 17, true)
    MOCK.Tick(0.3)
    equip(POLE, nil)
    MOCK.Tick(1.1)
    return ns
end

scenarios.fishing_safety_pole_warning = function()
    local ns = setup(16001, { secrets = true })
    MOCK.secretMode = true
    local FS = ns.FishingSafety
    check(ns.Fishing.PoleEquipped() == true, "pole equipped")
    resetOutput()

    -- Hidden hostility: counted on the HUD, never a pole warning.
    plateAdd("nameplate2", MOCK.Enemy({ guid = "Player-1-S", name = "Hidden", secret = { enemy = true } }))
    MOCK.Tick(0.3)
    check(ns.Spotter.Get("Hidden").hostile == nil, "hostility unknown")
    check(alertText() == nil, "no warning for hidden hostility: " .. tostring(alertText()))
    local text, warn = FS.NearestText()
    check(text:find("1 in view") and text:find("hostility %?") and not warn, "hidden counted, not enemy: " .. text)
    plateRemove("nameplate2")
    ns.Spotter.Clear()

    -- A real enemy: loud warning + sound.
    resetOutput()
    plateAdd("nameplate1", MOCK.Enemy({ name = "Grunt", guid = "Player-1-G", class = "WARRIOR", level = 20 }))
    check(alertText() and alertText():find("Fishing pole in your hands") and alertText():find("Grunt"),
        "pole warning: " .. tostring(alertText()))
    check(alertText():find("click Swap"), "swap hint when a weapon is remembered")
    check(#MOCK.sounds >= 1, "alert sound")
    MOCK.Tick(1.1)
    local hud = ns.FishingUI.HUDFrame()
    check(hud and hud:IsShown(), "HUD shown")
    local found
    for _, row in ipairs(hud.rows) do
        if row:IsShown() and (row.value:GetText() or ""):find("fishing pole in hands") then found = row end
    end
    check(found and found.accent:IsShown(), "HUD weapon row in warning")

    -- Rate limited: the same enemy does not warn again within the repeat time.
    resetOutput()
    MOCK.Tick(5) MOCK.Tick(5) MOCK.Tick(5)
    check(alertText() == nil and #MOCK.sounds == 0, "rate limited: " .. tostring(alertText()))
    -- Another enemy (the gap between two warnings has passed) warns at once...
    plateAdd("nameplate3", MOCK.Enemy({ name = "Stabby", guid = "Player-1-R", class = "ROGUE", level = 20 }))
    check(alertText() and alertText():find("Stabby"), "second enemy warns after the gap: " .. tostring(alertText()))
    resetOutput()
    -- ...and the first warns again once the repeat time has passed.
    local from = MOCK.time
    for _ = 1, 200 do
        MOCK.Tick(0.5)
        if alertText() then break end
    end
    check(MOCK.time - from >= 40, "not before the repeat time: " .. (MOCK.time - from))
    check(alertText() and alertText():find("Fishing pole"), "warns again after the repeat time: " .. tostring(alertText()))

    -- Muted alerts: no warning; weapon in hand: no warning.
    plateRemove("nameplate1") plateRemove("nameplate3")
    ns.Spotter.Clear()
    FS.Reset()
    resetOutput()
    TALODDB.alertsEnabled = false
    plateAdd("nameplate1", MOCK.Enemy({ name = "Grunt", guid = "Player-1-G", class = "WARRIOR", level = 20 }))
    check(alertText() == nil, "muted: " .. tostring(alertText()))
    TALODDB.alertsEnabled = true
    plateRemove("nameplate1")
    ns.Spotter.Clear()
    FS.Reset()
    equip(SWORD, SHIELD)
    resetOutput()
    plateAdd("nameplate1", MOCK.Enemy({ name = "Grunt2", guid = "Player-1-H", class = "WARRIOR", level = 20 }))
    check(not (alertText() or ""):find("Fishing pole"), "no pole warning with a sword: " .. tostring(alertText()))
end

scenarios.fishing_safety_swap_button = function()
    local ns = setup(11509)
    local FS = ns.FishingSafety
    local w = FS.Weapons()
    check(w and w.mh == SWORD and w.oh == SHIELD, "sword + shield remembered: " .. tostring(w and w.mh) .. " " .. tostring(w and w.oh))
    check(TALODDB.fishSwap["Tester-Mockrealm"], "saved per character")
    local b = TALODFishingSwapButton
    check(b and b:IsShown(), "swap button shown with the pole equipped")
    check(b._template == "SecureActionButtonTemplate" and b:GetAttribute("type") == "macro", "secure macro button")
    -- Names not cached: item strings.
    check(b:GetAttribute("macrotext") == "/equipslot 16 item:2000\n/equipslot 17 item:2001",
        "macrotext from IDs: " .. tostring(b:GetAttribute("macrotext")))
    -- Names arrive: the macro uses them.
    local names = { [SWORD] = "Shortsword", [SHIELD] = "Buckler", [GREATSWORD] = "Claymore" }
    function GetItemInfo(id) return names[id] end
    MOCK.Tick(0.3)
    check(b:GetAttribute("macrotext") == "/equipslot 16 Shortsword\n/equipslot 17 Buckler",
        "macrotext from names: " .. tostring(b:GetAttribute("macrotext")))
    check((b.label:GetText() or ""):find("Shortsword %+ Buckler"), "label: " .. tostring(b.label:GetText()))

    -- Never set up in combat: a new weapon remembered in combat leaves the
    -- attribute alone until combat ends.
    equip(GREATSWORD, nil)
    check(FS.Weapons().mh == GREATSWORD and FS.Weapons().oh == nil, "two-hander, no off hand")
    check(not b:IsShown(), "hidden once the pole is gone")
    MOCK.lockdown = true
    MOCK.FireEvent("PLAYER_REGEN_DISABLED")
    equip(POLE, nil)
    MOCK.Tick(0.3)
    check(not b:IsShown(), "not shown in combat")
    check(b:GetAttribute("macrotext") == "/equipslot 16 Shortsword\n/equipslot 17 Buckler", "attribute untouched in combat")
    MOCK.lockdown = false
    MOCK.FireEvent("PLAYER_REGEN_ENABLED")
    check(b:IsShown() and b:GetAttribute("macrotext") == "/equipslot 16 Claymore", "set after combat: " .. tostring(b:GetAttribute("macrotext")))

    -- Shown before combat: it stays through the fight, even after the pole is gone.
    MOCK.lockdown = true
    MOCK.FireEvent("PLAYER_REGEN_DISABLED")
    equip(GREATSWORD, nil)
    check(b:IsShown(), "stays usable in combat")
    MOCK.lockdown = false
    MOCK.FireEvent("PLAYER_REGEN_ENABLED")
    check(not b:IsShown(), "hidden after combat")

    -- A weapon no longer in the bags: no button.
    equip(POLE, nil)
    check(b:IsShown(), "back with the pole")
    function GetItemCount() return 0 end
    MOCK.Tick(0.3)
    check(not b:IsShown(), "weapon gone from the bags: no button")
    GetItemCount = nil

    -- Off in the settings.
    MOCK.Tick(0.3)
    check(b:IsShown(), "back")
    TALODDB.fishSwapButton = false
    MOCK.Tick(0.3)
    check(not b:IsShown(), "setting off")
    T.slash("fish safety")
    check(T.printed("swap button off"), "status line")
    T.slash("fish safety on")
    check(TALODDB.fishSwapButton == true, "safety on")
    b:Fire("OnEnter")
end

-- Two identical daggers: /equipslot cannot tell the copies apart, so the off
-- hand comes from the helper button, which takes the copy that is not locked.
scenarios.fishing_safety_dual_same = function()
    items()
    local DAGGER = 2003
    MOCK.items[DAGGER] = { classID = 2, subclassID = 15, equipLoc = "INVTYPE_WEAPON" }
    local ns = T.fishingSetup(11509)
    local FS = ns.FishingSafety
    equip(DAGGER, DAGGER)
    MOCK.equippedIDs[17] = nil
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 17, true)
    MOCK.Tick(0.3)
    equip(POLE, nil)
    MOCK.Tick(1.1)
    local w = FS.Weapons()
    check(w and w.mh == DAGGER and w.oh == DAGGER, "both daggers remembered")
    local b = TALODFishingSwapButton
    check(b and b:IsShown(), "swap button shown")
    check(b:GetAttribute("macrotext") == "/equipslot 16 item:2003\n/click TALODFishingOffHandButton",
        "off hand by the helper: " .. tostring(b:GetAttribute("macrotext")))
    check(TALODFishingOffHandButton and TALODFishingOffHandButton._template == nil, "helper is a plain button")
    -- The first line is moving copy A (locked); the helper equips copy B.
    MOCK.bags[0][1] = MOCK.ItemLink(DAGGER, "Tail Spike")
    MOCK.bags[0][2] = MOCK.ItemLink(DAGGER, "Tail Spike")
    MOCK.bagLocked["0:1"] = true
    TALODFishingOffHandButton:GetScript("OnClick")(TALODFishingOffHandButton)
    check(MOCK.equippedIDs[17] == DAGGER, "off hand equipped: " .. tostring(MOCK.equippedIDs[17]))
    check(MOCK.bags[0][1] ~= nil and MOCK.bags[0][2] == nil, "the unlocked copy was taken")
    check(not CursorHasItem(), "cursor empty")
    -- Already holding it: a second click does nothing.
    MOCK.bagLocked["0:1"] = nil
    TALODFishingOffHandButton:GetScript("OnClick")(TALODFishingOffHandButton)
    check(MOCK.bags[0][1] ~= nil and MOCK.equipCalls == 1, "no second equip")
end

scenarios.fishing_safety_targeting = function()
    local ns = setup(16001, { secrets = true })
    MOCK.secretMode = true
    TALODDB.fishPoleWarn = false
    T.catch({ { 6291, "Raw Brilliant Smallfish", 1 } })
    check(ns.Fishing.IsFishing(), "fishing")
    resetOutput()
    -- Not targeting you: nothing.
    plateAdd("nameplate1", MOCK.Enemy({ name = "Grunt", guid = "Player-1-G", class = "WARRIOR", level = 20 }))
    MOCK.Tick(0.3)
    check(not (alertText() or ""):find("targeting you"), "no target, no alert")
    -- Targets you: alert.
    MOCK.units.nameplate1.targetsPlayer = true
    MOCK.Tick(0.3)
    check(alertText() and alertText():find("Grunt is targeting you"), "targeting alert: " .. tostring(alertText()))
    check(#MOCK.sounds >= 1, "sound")
    -- Rate limited per player: drops and retargets within 30 s, no new alert.
    resetOutput()
    MOCK.units.nameplate1.targetsPlayer = false
    MOCK.Tick(0.3)
    MOCK.units.nameplate1.targetsPlayer = true
    MOCK.Tick(0.3)
    check(alertText() == nil, "rate limited: " .. tostring(alertText()))
    plateRemove("nameplate1")
    ns.Spotter.Clear()

    -- A hidden target (nil) never alerts.
    resetOutput()
    local realIsUnit = UnitIsUnit
    function UnitIsUnit(a, b)
        if a == "nameplate2target" then return MOCK.Secret(true) end
        return realIsUnit(a, b)
    end
    plateAdd("nameplate2", MOCK.Enemy({ name = "Sneaky", guid = "Player-1-N", class = "ROGUE", level = 20, targetsPlayer = true }))
    MOCK.Tick(0.3)
    check(ns.ReadVitals("nameplate2", {}).targetingYou == nil, "target hidden")
    check(not (alertText() or ""):find("targeting you"), "hidden target never alerts: " .. tostring(alertText()))
    UnitIsUnit = realIsUnit
    plateRemove("nameplate2")
    ns.Spotter.Clear()

    -- Hidden hostility targeting you: no alert.
    resetOutput()
    plateAdd("nameplate3", MOCK.Enemy({ name = "Hidden", guid = "Player-1-S", secret = { enemy = true }, targetsPlayer = true }))
    MOCK.Tick(0.3)
    check(not (alertText() or ""):find("targeting you"), "hidden hostility never alerts")
end

scenarios.fishing_safety_range = function()
    local ns = setup(16001, { secrets = true })
    local FS = ns.FishingSafety
    check(FS.NearestText():find("none in view"), "nobody")
    plateAdd("nameplate1", MOCK.Enemy({ name = "Grunt", guid = "Player-1-G", class = "WARRIOR", level = 20, distance = 22 }))
    MOCK.Tick(0.3)
    local text, warn = FS.NearestText()
    check(text:find("1 in view") and text:find("yd") and not text:find("%? yd") and warn, "known range: " .. text)
    -- Range hidden: "? yd", never a number.
    MOCK.secretRange = true
    MOCK.Tick(0.3)
    text = FS.NearestText()
    check(text:find("1 in view") and text:find("·  %? yd$"), "unknown range: " .. text)
    check(not text:find("%d+–%d+") and not text:find("< %d") and not text:find("> %d"), "no number for an unknown range: " .. text)
    -- One known, one unknown: the unknown one is still told.
    MOCK.secretRange = false
    MOCK.Tick(0.3)
    local realRange = ns.ProbeUnitRange
    ns.ProbeUnitRange = function(unit)
        if unit == "nameplate2" then return nil, nil, false end
        return realRange(unit)
    end
    plateAdd("nameplate2", MOCK.Enemy({ name = "Far", guid = "Player-1-F", class = "MAGE", level = 20, distance = 38 }))
    MOCK.Tick(0.3)
    text = FS.NearestText()
    check(text:find("2 in view") and text:find("1 at %? yd"), "mixed: " .. text)
    ns.ProbeUnitRange = realRange
    -- The HUD shows it.
    local hud = ns.FishingUI.HUDFrame()
    local found
    for _, row in ipairs(hud.rows) do
        if row:IsShown() and (row.label:GetText() or ""):find("Nearest") then found = row end
    end
    check(found and (found.value:GetText() or ""):find("in view"), "HUD nearest row")
    ns.FishingUI.Show("now")
end

-- The HUD's Weapon row is a click to swap back, enemy in view or not.
scenarios.fishing_safety_weapon_row = function()
    local ns = setup(11509)
    MOCK.Tick(0.6)
    local row = ns.FishingUI.HUDRowByKey("weapon")
    check(row, "Weapon row on the HUD")
    check(ns.FishingSafety.Nearby().enemies == 0, "no enemy in view")
    local b = TALODFishingWeaponRowButton
    check(b and b:IsShown() and b._template == "SecureActionButtonTemplate", "row button shown without an enemy")
    check(b:GetAttribute("type") == "macro" and b:GetAttribute("macrotext") == "/equipslot 16 item:2000\n/equipslot 17 item:2001",
        "same macro as the swap button: " .. tostring(b:GetAttribute("macrotext")))
    check(b:GetAttribute("macrotext") == TALODFishingSwapButton:GetAttribute("macrotext"), "matches the swap button")
    check(b.row == row, "lies over the Weapon row")
    check((row.value:GetText() or ""):find("click to equip"), "row says click: " .. tostring(row.value:GetText()))
    b:Fire("OnEnter")

    -- Combat: hidden at once, never set up until it ends.
    local setInCombat = 0
    local orig = b.SetAttribute
    b.SetAttribute = function(self, k, v)
        if MOCK.lockdown then setInCombat = setInCombat + 1 end
        return orig(self, k, v)
    end
    MOCK.FireEvent("PLAYER_REGEN_DISABLED")
    MOCK.lockdown = true
    check(not b:IsShown(), "hidden in combat")
    MOCK.Tick(0.6) MOCK.Tick(0.6)
    check(setInCombat == 0 and not b:IsShown(), "no setup in combat")
    MOCK.lockdown = false
    MOCK.FireEvent("PLAYER_REGEN_ENABLED")
    MOCK.Tick(0.6)
    check(b:IsShown() and b.row == ns.FishingUI.HUDRowByKey("weapon"), "back after combat")

    -- The apply-lure button under the HUD no longer covers the swap button.
    local swap = TALODFishingSwapButton
    local hud = ns.FishingUI.HUDFrame()
    hud.GetLeft = function() return 100 end
    hud.GetBottom = function() return 300 end
    MOCK.Tick(0.6)
    local hudBottom = 300
    check(swap.at and swap.at[2] == hudBottom, "swap button right under the HUD")
    MOCK.bags[0][1] = MOCK.ItemLink(6530, "Nightcrawlers")
    MOCK.bagCounts["0:1"] = 5
    ns.FishingGear.Invalidate()
    MOCK.Tick(1.1) MOCK.Tick(0.6)
    local lure = TALODFishingLureButton
    check(lure and lure:IsShown(), "apply-lure button shown")
    check(swap.at[2] == hudBottom - 2 - lure:GetHeight(), "swap button moved below the lure button: " .. tostring(swap.at[2]))

    -- Setting off; weapon gone from the bags; pole off.
    TALODDB.fishSwapRow = false
    MOCK.Tick(0.6)
    check(not b:IsShown() and b:GetAttribute("type") == nil, "setting off")
    TALODDB.fishSwapRow = true
    MOCK.Tick(0.6)
    check(b:IsShown(), "setting on")
    function GetItemCount() return 0 end
    MOCK.Tick(0.6)
    check(not b:IsShown(), "weapon not in the bags: no button")
    GetItemCount = nil
    MOCK.Tick(0.6)
    equip(SWORD, SHIELD)
    check(not b:IsShown(), "weapon in hand: no button")
end
