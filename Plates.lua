-- TALOD - nameplate badges on enemy players (level gap, KoS) and the
-- target readout above your enemy target's nameplate (distance bracket and
-- which of your key spells reach).
--
-- On WoW Forever addons may anchor frames to nameplates but may not measure
-- them or anchor lines to them, so everything here is a plain label anchored
-- to the plate; forbidden nameplates are never touched.

local ADDON_NAME, ns = ...
local S = ns.Secret

local Plates = {}
ns.Plates = Plates

local badges = {}      -- [token] = frame
local readout          -- target readout frame

local function IsForbidden(frame)
    return frame and frame.IsForbidden and frame:IsForbidden()
end

local function Usable(frame)
    if type(frame) ~= "table" or not frame.IsShown or IsForbidden(frame) then return false end
    local ok, shown = pcall(frame.IsShown, frame)
    return ok and shown == true
end

-- Nameplate addons replace the game's visible nameplate. Anchor to the
-- visible health bar when one is found (EllesmereUI, Plater, Blizzard), and
-- fall back to the base nameplate frame, which every addon leaves in place.
function ns.GetUnitPlateAnchor(unit)
    if not C_NamePlate or not C_NamePlate.GetNamePlateForUnit then return nil end
    local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
    if not ok or not plate or IsForbidden(plate) then return nil end

    local eui = _G.EllesmereNameplates_NS
    local euiPlate = eui and type(eui.plates) == "table" and eui.plates[unit]
    if euiPlate and Usable(euiPlate.health) then return euiPlate.health, "EllesmereUI" end

    local plater = rawget(plate, "unitFrame")
    if type(plater) == "table" and Usable(plater.healthBar) then return plater.healthBar, "Plater" end

    local blizzard = rawget(plate, "UnitFrame")
    if type(blizzard) == "table" then
        if Usable(blizzard.healthBar) and (blizzard.GetAlpha == nil or (blizzard:GetAlpha() or 1) > 0.05) then
            return blizzard.healthBar, "Blizzard"
        end
        if Usable(blizzard) and (blizzard.GetAlpha == nil or (blizzard:GetAlpha() or 1) > 0.05) then
            return blizzard, "Blizzard"
        end
    end
    return plate, "nameplate"
end

local function Label(name, template)
    local f = CreateFrame("Frame", name, UIParent)
    f:SetSize(60, 18)
    f:SetFrameStrata("TOOLTIP")
    f:EnableMouse(false)
    f.text = f:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
    f.text:SetPoint("CENTER")
    f.text:SetShadowOffset(1, -1)
    f:Hide()
    return f
end

-- Text is set only when it changes: every badge is refreshed 4 times a second.
local function SetLabel(frame, text)
    if frame.shownText == text then return end
    frame.shownText = text
    frame.text:SetText(text)
end

local function Anchor(frame, anchor, point, relPoint, x, y)
    if frame.anchor == anchor then return true end
    frame:ClearAllPoints()
    local ok = pcall(frame.SetPoint, frame, point, anchor, relPoint, x, y)
    frame.anchor = ok and anchor or nil
    return ok
end

-- "+3", "-2", "=", "??" relative to your level; "?" when hidden.
function Plates.LevelGapText(e)
    if e.skull then return "??" end
    local mine = S.Call(UnitLevel, "player")
    if not e.level or not mine then return "?" end
    local gap = e.level - mine
    if gap == 0 then return "=" end
    return (gap > 0 and "+" or "") .. gap
end

local function BadgeText(e)
    local gap = Plates.LevelGapText(e)
    local text = ns.Hex(ns.LevelColor(e)) .. gap .. "|r"
    local list = ns.ListOf(e.key)
    if list == "kos" then
        text = ns.ColorCode("danger") .. "KoS|r " .. text
    elseif list == "avoid" then
        text = ns.ColorCode("threshold") .. "avoid|r " .. text
    end
    if e.hostile == nil then text = ns.ColorCode("threshold") .. "?|r " .. text end
    return text
end

local used = {}
local function UpdateBadges()
    wipe(used)
    if ns.DB().enabled and ns.DB().badgesEnabled then
        for _, e in pairs(ns.Spotter.nearby) do
            local token = e.unit
            if token and not e.dead then
                local anchor = ns.GetUnitPlateAnchor(token)
                if anchor then
                    local badge = badges[token]
                    if not badge then
                        badge = Label(nil, "GameFontNormal")
                        badges[token] = badge
                    end
                    if Anchor(badge, anchor, "RIGHT", "LEFT", -4, 0) then
                        SetLabel(badge, BadgeText(e))
                        badge:Show()
                        used[token] = true
                    end
                end
            end
        end
    end
    for token, badge in pairs(badges) do
        if not used[token] then
            badge:Hide()
            badge.anchor = nil
        end
    end
end

---------------------------------------------------------------------------
-- Target readout
---------------------------------------------------------------------------
-- Distance bracket plus your key spells for the current enemy target.
-- compact: only the spells in range. Returns nil when the target is not an
-- enemy player.
function Plates.TargetText(compact)
    local f = ns.ReadPlayerUnit("target")
    if not f or f.dead then return nil end
    local e = f.key and ns.Spotter.Get(f.key)
    local lo, hi, ok
    if e and e.rangeOK ~= nil then
        lo, hi, ok = e.lo, e.hi, e.rangeOK
    else
        lo, hi, ok = ns.ProbeUnitRange("target")
    end
    local distance = ok and (ns.Hex(ns.COLORS.neutral) .. ns.FormatRange(lo, hi) .. "|r")
        or (ns.ColorCode("threshold") .. "? yd|r")
    if not ns.DB().targetSpells then return distance end
    local parts = {}
    for _, spell in ipairs(ns.KeySpellRanges("target")) do
        if spell.inRange == true then
            parts[#parts + 1] = ns.ColorCode("safe") .. spell.name .. "|r"
        elseif not compact then
            if spell.inRange == false then
                parts[#parts + 1] = ns.Hex(ns.COLORS.dim) .. spell.name .. "|r"
            else
                parts[#parts + 1] = ns.ColorCode("threshold") .. spell.name .. "?|r"
            end
        end
    end
    if #parts == 0 then return distance end
    return distance .. "  " .. table.concat(parts, " ")
end

local function UpdateReadout()
    if not ns.DB().enabled or not ns.DB().targetReadout then
        if readout then readout:Hide() end
        return
    end
    local anchor = ns.GetUnitPlateAnchor("target")
    local text = anchor and Plates.TargetText(true)
    if not text then
        if readout then readout:Hide(); readout.anchor = nil end
        return
    end
    readout = readout or Label(ns.FRAME .. "TargetReadout", "GameFontHighlight")
    if not Anchor(readout, anchor, "BOTTOM", "TOP", 0, 16) then
        readout:Hide()
        return
    end
    SetLabel(readout, text)
    readout:Show()
end

function Plates.Update()
    UpdateBadges()
    UpdateReadout()
end

function Plates.HideAll()
    for _, badge in pairs(badges) do badge:Hide(); badge.anchor = nil end
    if readout then readout:Hide(); readout.anchor = nil end
end

ns.RegisterModule("Plates", {
    tick = Plates.Update,
    refresh = function()
        Plates.HideAll()
        Plates.Update()
    end,
    events = { "NAME_PLATE_UNIT_REMOVED" },
    onEvent = function(event, token)
        local badge = token and badges[token]
        if badge then badge:Hide(); badge.anchor = nil end
        if readout and readout.anchor and not ns.GetUnitPlateAnchor("target") then readout:Hide(); readout.anchor = nil end
    end,
})
