-- TALOD - Alerts: "enemy spotted" warnings (center text, sound, chat),
-- rate-limited per player. Loud alerts are for your kill-on-sight list, classes
-- you chose, skulls and enemies well above your level. Never alerts for a
-- player whose hostility the game hides: unknown is shown in the panel instead.

local ADDON_NAME, ns = ...
local S = ns.Secret

local Alerts = {}
ns.Alerts = Alerts

ns.ALERT_SOUNDS = {
    { key = "raidwarning", label = "Raid warning", kit = (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959 },
    { key = "pvpflag", label = "PvP warning", kit = (SOUNDKIT and SOUNDKIT.PVP_THROUGH_QUEUE) or 8458 },
    { key = "alarm", label = "Alarm clock", kit = (SOUNDKIT and SOUNDKIT.ALARM_CLOCK_WARNING_3) or 12889 },
    { key = "readycheck", label = "Ready check", kit = (SOUNDKIT and SOUNDKIT.READY_CHECK) or 8960 },
}

local lastAlertAt = {}   -- [key] = GetTime()
local alertFrame

local function ApplyFont(fontString, baseObject, scale)
    local file, size = nil, nil
    if baseObject and baseObject.GetFont then file, size = baseObject:GetFont() end
    if file and size then
        fontString:SetFont(file, math.floor(size * (scale or 1) + 0.5), "OUTLINE")
    elseif baseObject then
        fontString:SetFontObject(baseObject)
    end
end
ns.ApplyFont = ApplyFont

local function CreateAlertFrame()
    alertFrame = CreateFrame("Frame", ns.FRAME .. "AlertText", UIParent)
    alertFrame:SetSize(700, 40)
    alertFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 250)
    alertFrame:SetFrameStrata("HIGH")
    alertFrame:EnableMouse(false)
    alertFrame.text = alertFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    alertFrame.text:SetPoint("CENTER")
    alertFrame:Hide()
    alertFrame:SetScript("OnUpdate", function(self, elapsed)
        self.remaining = (self.remaining or 0) - elapsed
        if self.remaining <= 0 then
            self:Hide()
        elseif self.remaining < 0.6 then
            self:SetAlpha(self.remaining / 0.6)
        end
    end)
end

function Alerts.PlayChosenSound()
    for _, sound in ipairs(ns.ALERT_SOUNDS) do
        if sound.key == ns.DB().alertSoundChoice then
            ns.PlaySoundKit(sound.kit)
            return
        end
    end
end

-- Shows a center-screen line. color = {r,g,b}; loud = bigger and longer.
function Alerts.Show(text, color, loud)
    if not alertFrame then CreateAlertFrame() end
    ApplyFont(alertFrame.text, GameFontNormalLarge, loud and 1.6 or 1.25)
    alertFrame.text:SetText(text)
    color = color or ns.COLORS.neutral
    alertFrame.text:SetTextColor(color[1], color[2], color[3])
    alertFrame.remaining = loud and 4 or 2.5
    alertFrame:SetAlpha(1)
    alertFrame:Show()
end

-- "Shadowfang ?? Rogue <Guild> (KoS)"
function Alerts.Describe(e, withColor)
    local name = e.name or "Unknown"
    if withColor then name = ns.Hex(ns.ClassColor(e.classFile)) .. name .. "|r" end
    local parts = { name, ns.LevelText(e), e.className or ns.ClassName(e.classFile) }
    if e.guild then parts[#parts + 1] = "<" .. e.guild .. ">" end
    local list = ns.ListOf(e.key)
    if list == "kos" then parts[#parts + 1] = "(KoS)" elseif list == "avoid" then parts[#parts + 1] = "(avoid)" end
    return table.concat(parts, " ")
end

local SOURCE_KEYS = { nameplate = "alertOnNameplate", target = "alertOnTarget", mouseover = "alertOnMouseover" }

function Alerts.ShouldAlert(e, source)
    local db = ns.DB()
    if not db.enabled or not db.alertsEnabled then return false end
    if e.hostile ~= true or e.dead then return false end
    local sourceKey = SOURCE_KEYS[source]
    if sourceKey and not db[sourceKey] then return false end
    if ns.ListOf(e.key) ~= "kos" and not e.skull and e.level then
        local mine = S.Call(UnitLevel, "player")
        if mine and e.level - mine < (db.alertMinLevelGap or -60) then return false end
    end
    local now = GetTime()
    if e.keyed and lastAlertAt[e.key] and now - lastAlertAt[e.key] < (db.alertRepeatSeconds or 120) then return false end
    return true
end

function Alerts.Fire(e, source)
    local db = ns.DB()
    if e.keyed then lastAlertAt[e.key] = GetTime() end
    local loud = ns.IsLoud(e)
    local distance = (e.lo or e.hi) and ("  " .. ns.FormatRange(e.lo, e.hi)) or ""
    if db.alertCenterText then
        Alerts.Show((loud and "!! ENEMY: " or "Enemy: ") .. Alerts.Describe(e) .. distance,
            loud and ns.GetColor("danger") or ns.ClassColor(e.classFile), loud)
    end
    if db.alertSound and loud then Alerts.PlayChosenSound() end
    if db.alertChat then
        local zone = GetSubZoneText and S.Call(GetSubZoneText)
        if not zone or zone == "" then zone = GetZoneText and S.Call(GetZoneText) end
        ns.Print((loud and ns.ColorCode("danger") .. "ENEMY|r " or "enemy ") .. Alerts.Describe(e, true)
            .. distance .. (zone and (" — " .. zone) or ""))
    end
end

function Alerts.OnSpotted(e, source, isNew)
    if not isNew then return end
    if Alerts.ShouldAlert(e, source) then Alerts.Fire(e, source) end
end

function Alerts.OnVanished(e)
    -- Muting enemy alerts (panel button, settings) silences this one too.
    if not ns.DB().enabled or not ns.DB().alertsEnabled then return end
    Alerts.Show("Stealther vanished: " .. Alerts.Describe(e) .. "  (last " .. ns.FormatRange(e.lo, e.hi) .. ")",
        ns.GetColor("danger"), true)
    if ns.DB().alertSound then Alerts.PlayChosenSound() end
    if ns.DB().alertChat then
        ns.Print(ns.ColorCode("danger") .. "vanished|r " .. Alerts.Describe(e, true) .. " — probably stealthed nearby.")
    end
end

function Alerts.Test()
    Alerts.Fire({ key = "test", name = "Shadowfang", className = "Rogue", classFile = "ROGUE", skull = true,
        guild = "Test Guild", hostile = true, lo = 8, hi = 10 }, "test")
end

function Alerts.Reset() wipe(lastAlertAt) end

ns.RegisterModule("Alerts", {
    init = function()
        ns.Spotter.On("spotted", Alerts.OnSpotted)
        ns.Spotter.On("vanished", Alerts.OnVanished)
    end,
})
