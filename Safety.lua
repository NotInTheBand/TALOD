-- TALOD - Safety (Hardcore): your PvP flag always visible, a warning when
-- your target is one that would flag you, and a banner when you enter
-- contested or hostile territory with the enemies seen there recently.
--
-- Addons cannot stop an action, only warn before it. The warnings fire when
-- you target the player, which is before any spell or attack can land.

local ADDON_NAME, ns = ...
local S = ns.Secret

local Safety = {}
ns.Safety = Safety

local indicator
local lastWarnAt = {}     -- [key] = GetTime()
local WARN_REPEAT = 60
local lastZone

local function db() return ns.DB() end

-- Returns flagged (true/false/nil when hidden) and the seconds until the flag
-- drops (nil when no timer runs).
function Safety.PlayerFlag()
    -- Hidden or missing is unknown, never "off".
    local flagged = UnitIsPVP and S.Call(UnitIsPVP, "player")
    if flagged == nil then return nil end
    local ffa = UnitIsPVPFreeForAll and S.Call(UnitIsPVPFreeForAll, "player") == true
    local remaining
    if flagged and IsPVPTimerRunning and S.Call(IsPVPTimerRunning) == true and GetPVPTimer then
        local ms = S.Call(GetPVPTimer)
        if ms and ms > 0 then remaining = ms / 1000 end
    end
    return flagged or ffa or false, remaining
end

---------------------------------------------------------------------------
-- Flag indicator
---------------------------------------------------------------------------
local function SavePosition(self)
    local point, _, relPoint, x, y = self:GetPoint(1)
    db().flagPoint = { point or "TOP", "UIParent", relPoint or "TOP", math.floor((x or 0) + 0.5), math.floor((y or 0) + 0.5) }
end

local function CreateIndicator()
    indicator = CreateFrame("Frame", ns.FRAME .. "Flag", UIParent)
    indicator:SetSize(150, 22)
    indicator:SetFrameStrata("MEDIUM")
    indicator:SetClampedToScreen(true)
    indicator:SetMovable(true)
    indicator:EnableMouse(true)
    indicator:RegisterForDrag("LeftButton")
    indicator:SetScript("OnDragStart", function(self)
        if db().flagLocked and not IsShiftKeyDown() then return end
        self:StartMoving()
    end)
    indicator:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self)
    end)
    ns.Style.Surface(indicator, "hud")
    indicator.text = indicator:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    indicator.text:SetPoint("CENTER")
    indicator:SetScript("OnEnter", function(self)
        ns.Tooltip.Open(self, "ANCHOR_BOTTOM")
            :Title("PvP flag")
            :Line("Flagged players can be attacked by the enemy faction. Helping a flagged player "
                .. "(heals, buffs) or attacking an enemy player flags you too.")
            :Note(db().flagLocked and "Shift + drag to move." or "Drag to move.")
            :Show()
    end)
    indicator:SetScript("OnLeave", function(self) ns.Tooltip.HideFor(self) end)
    Safety.RestorePosition()
end

function Safety.RestorePosition()
    if not indicator then return end
    local p = db().flagPoint or ns.defaults.flagPoint
    indicator:ClearAllPoints()
    indicator:SetPoint(p[1], UIParent, p[3], p[4], p[5])
end

function Safety.ResetPosition()
    db().flagPoint = { unpack(ns.defaults.flagPoint) }
    Safety.RestorePosition()
end

function Safety.UpdateIndicator()
    if not indicator then return end
    if not db().enabled or not db().flagIndicator then
        indicator:Hide()
        return
    end
    local flagged, remaining = Safety.PlayerFlag()
    if flagged == nil then
        indicator.text:SetText(ns.ColorCode("threshold") .. "PvP: ?|r")
    elseif flagged and remaining then
        indicator.text:SetText(ns.ColorCode("threshold") .. string.format("PvP ON · off in %d:%02d|r",
            math.floor(remaining / 60), math.floor(remaining % 60)))
    elseif flagged then
        indicator.text:SetText(ns.ColorCode("danger") .. "PvP ON|r")
    else
        indicator.text:SetText(ns.ColorCode("safe") .. "PvP off|r")
    end
    indicator:Show()
end

---------------------------------------------------------------------------
-- "This would flag you" warnings
---------------------------------------------------------------------------
-- Returns the warning text for the current target, or nil.
function Safety.TargetFlagRisk()
    local flagged = Safety.PlayerFlag()
    if flagged ~= false then return nil end   -- already flagged, or unknown (the indicator says "?")
    if S.Call(UnitIsUnit, "target", "player") then return nil end
    if not S.Call(UnitIsPlayer, "target") then
        -- Attacking an enemy player's pet or totem, or an NPC of the enemy
        -- faction (guards, flight masters, quest givers), flags you as well.
        if S.Call(UnitCanAttack, "player", "target") ~= true then return nil end
        local name = S.Call(UnitName, "target") or "this target"
        if S.Call(UnitPlayerControlled, "target") == true then
            return "Attacking " .. name .. " (a player's pet) will flag you for PvP", name
        end
        local mine, theirs = S.Call(UnitFactionGroup, "player"), S.Call(UnitFactionGroup, "target")
        if S.Call(UnitIsPVP, "target") == true and (theirs == "Alliance" or theirs == "Horde") and theirs ~= mine then
            return "Attacking " .. name .. " (" .. theirs .. ") will flag you for PvP", name
        end
        return nil
    end
    local name = S.Call(UnitName, "target") or "this player"
    local targetFlagged = UnitIsPVP and S.Call(UnitIsPVP, "target") == true
    local enemy = S.Call(UnitIsEnemy, "player", "target") == true
    local friend = S.Call(UnitIsFriend, "player", "target") == true
    if enemy and S.Call(UnitCanAttack, "player", "target") == true then
        return "Attacking " .. name .. " will flag you for PvP", name
    end
    if friend and targetFlagged then
        return "Helping " .. name .. " (heals, buffs) will flag you for PvP", name
    end
    return nil
end

local function CheckTarget()
    if not db().enabled or not db().flagWarnTarget then return end
    local text, name = Safety.TargetFlagRisk()
    if not text then return end
    local now = GetTime()
    if lastWarnAt[name] and now - lastWarnAt[name] < WARN_REPEAT then return end
    lastWarnAt[name] = now
    ns.Alerts.Show(text, ns.GetColor("threshold"), false)
    ns.Print(ns.ColorCode("threshold") .. text .. ".|r")
end

---------------------------------------------------------------------------
-- Danger-zone banner
---------------------------------------------------------------------------
local BANNER_TYPES = { contested = "Contested territory", hostile = "Enemy territory", combat = "Combat zone" }

function Safety.CheckZone(force)
    if not db().enabled or not db().zoneBanner then return end
    local zone = GetZoneText and S.Call(GetZoneText)
    if not zone or (zone == lastZone and not force) then return end
    lastZone = zone
    local pvpType = ns.ZonePvPInfo()
    local label = BANNER_TYPES[pvpType or ""]
    if not label then return end
    local text = label .. ": " .. zone
    if ns.Journal then
        local count, latest = ns.Journal.ZoneSummary(zone, 86400)
        if count > 0 then
            text = text .. string.format("  —  %d enem%s seen here in 24 h (latest %s, %s ago)", count,
                count == 1 and "y" or "ies", tostring(latest.name), ns.FormatAge(time() - (latest.t2 or latest.t)))
        end
    end
    ns.Alerts.Show(text, ns.GetColor(pvpType == "hostile" and "danger" or "threshold"), pvpType == "hostile")
    ns.Print(text)
end

ns.RegisterModule("Safety", {
    init = function()
        CreateIndicator()
        Safety.UpdateIndicator()
    end,
    tick = Safety.UpdateIndicator,
    refresh = function()
        Safety.RestorePosition()
        Safety.UpdateIndicator()
    end,
    events = { "PLAYER_TARGET_CHANGED", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD", "PLAYER_FLAGS_CHANGED",
        "UNIT_FACTION" },
    onEvent = function(event, unit)
        if event == "PLAYER_TARGET_CHANGED" then
            CheckTarget()
        elseif event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
            -- Zone text can lag the event by a moment.
            C_Timer.After(1, function() ns.SafeCall(Safety.CheckZone) end)
        else
            Safety.UpdateIndicator()
        end
    end,
})
