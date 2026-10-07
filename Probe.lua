-- TALOD - /talod probe: Phase 0 of the plan. Reports what this client lets
-- the addon read about enemy players, so each 🟡 feature in docs/PLAN.md can
-- be built, cut or simplified on evidence. Output goes to a copyable window
-- and to TALODDB.lastProbe (saved on /reload or logout). Never touches a
-- secret beyond type checks.
--
-- Run it near an enemy player: once out of combat and once in combat.

local ADDON_NAME, ns = ...
local S = ns.Secret
local D = S.Describe

local Probe = {}
ns.Probe = Probe

local ADDON_PREFIX = ns.PROBE_PREFIX
local copyFrame

-- Passive counters, collected from load: do enemy cast events reach addons,
-- and do addon messages come back?
local counters = { castEvents = 0, castPlayer = 0, castReadableSpell = 0, castInCombat = 0, addonEcho = {} }

local function CreateCopyFrame()
    -- Same window as the rest of the addon; plain scroll (mouse wheel).
    local f = ns.Style.Window(ns.FRAME .. "ProbeWindow", "Report  |cff8a8a8aCtrl+A, Ctrl+C to copy|r", 720, 460)
    f:Hide()
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    local box = CreateFrame("Frame", nil, f)
    box:SetPoint("TOPLEFT", 12, -48)
    box:SetPoint("BOTTOMRIGHT", -12, 12)
    local boxBg = ns.Style.Texture(box, "BACKGROUND", ns.Style.COLORS.card)
    boxBg:SetAllPoints()
    ns.Style.Border(box, ns.Style.COLORS.cardBorder)

    local scroll, templated = ns.CreateFrameSafe("ScrollFrame", ns.FRAME .. "ProbeScroll", box, nil)
    scroll:SetPoint("TOPLEFT", 8, -8)
    scroll:SetPoint("BOTTOMRIGHT", -8, 8)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
    edit:SetWidth(660)
    edit:SetScript("OnEscapePressed", function() f:Hide() end)
    scroll:SetScrollChild(edit)
    if not templated then
        scroll:EnableMouseWheel(true)
        scroll:SetScript("OnMouseWheel", function(self, delta)
            local maxScroll = math.max(0, (edit:GetHeight() or 0) - (self:GetHeight() or 0))
            self:SetVerticalScroll(math.max(0, math.min(maxScroll, self:GetVerticalScroll() - delta * 40)))
        end)
    end
    f.edit = edit
    return f
end

function Probe.ShowText(text)
    copyFrame = copyFrame or CreateCopyFrame()
    copyFrame.edit:SetText(text)
    copyFrame:Show()
    copyFrame.edit:SetFocus()
    copyFrame.edit:HighlightText()
end

local function has(path)
    local t = _G
    for part in path:gmatch("[^%.]+") do
        if type(t) ~= "table" then return "no" end
        t = t[part]
    end
    return t ~= nil and "yes" or "no"
end

-- Describes every return value of a call: "a, b, c", "missing" or "error".
local function pack(...) return { n = select("#", ...), ... } end

local function call(fn, ...)
    if type(fn) ~= "function" then return "missing" end
    local results = pack(pcall(fn, ...))
    if not results[1] then return "error" end
    local n = math.max(1, results.n - 1)
    local out = {}
    for i = 1, math.min(n, 4) do out[i] = D(results[i + 1]) end
    return table.concat(out, ", ")
end

local function valid(event) return tostring(ns.IsEventValid(event)) end

local function UnitReport(out, unit)
    out("%s: name=%s class=%s race=%s level=%s guild=%s", unit, call(UnitName, unit), call(UnitClass, unit),
        call(UnitRace, unit), call(UnitLevel, unit), call(GetGuildInfo, unit))
    out("   player=%s enemy=%s canAttack=%s friend=%s faction=%s pvp=%s ffa=%s dead=%s guid=%s",
        call(UnitIsPlayer, unit), call(UnitIsEnemy, "player", unit), call(UnitCanAttack, "player", unit),
        call(UnitIsFriend, "player", unit), call(UnitFactionGroup, unit), call(UnitIsPVP, unit),
        call(UnitIsPVPFreeForAll, unit), call(UnitIsDeadOrGhost, unit), call(UnitGUID, unit))
    out("   health=%s / %s  power=%s  inCombat=%s  speed=%s", call(UnitHealth, unit), call(UnitHealthMax, unit),
        call(UnitPower, unit), call(UnitAffectingCombat, unit), call(GetUnitSpeed, unit))

    -- Item 2: range checks on an enemy player.
    local parts = {}
    for _, c in ipairs(ns.RANGE_CHECKERS) do
        local r = ns.RunChecker(c, unit)
        parts[#parts + 1] = ns.FormatNumber(c.range) .. (c.kind == "item" and "" or c.kind:sub(1, 1)) .. ":"
            .. (r == true and "IN" or r == false and "OUT" or "nil")
    end
    local lo, hi, ok = ns.ProbeUnitRange(unit)
    out("   range checks: %s", table.concat(parts, " "))
    out("   bracket: %s ok=%s", ns.FormatRange(lo, hi), tostring(ok))
    local spells = {}
    for _, spell in ipairs(ns.KeySpellRanges(unit)) do
        spells[#spells + 1] = spell.name .. ":" .. (spell.inRange == true and "IN" or spell.inRange == false and "OUT" or "nil")
    end
    out("   key spells: %s", #spells > 0 and table.concat(spells, "  ") or "none known")

    -- Item 4: enemy auras (stealth / trinket detection).
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
            local aok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, 1, filter)
            if not aok then
                out("   aura %s: error", filter)
            elseif type(aura) == "table" then
                out("   aura %s #1: spellId=%s name=%s duration=%s", filter, D(aura.spellId), D(aura.name), D(aura.duration))
            elseif S.IsSecret(aura) then
                out("   aura %s #1: SECRET", filter)
            else
                out("   aura %s #1: none", filter)
            end
        end
    else
        out("   auras: C_UnitAuras missing (UnitBuff=%s)", has("UnitBuff"))
    end
    out("   nameplate anchor=%s", ns.GetUnitPlateAnchor and (select(2, ns.GetUnitPlateAnchor(unit)) or "none") or "n/a")
end

-- Item 5: addon messages. Sends a probe to each group/guild channel you are
-- in; replies (your own echo) are counted by the CHAT_MSG_ADDON listener.
local function SendAddonProbes(out)
    local api = C_ChatInfo
    if not (api and api.SendAddonMessage) then
        out("addon messages: C_ChatInfo.SendAddonMessage missing (SendAddonMessage=%s)", has("SendAddonMessage"))
        return
    end
    out("addon messages: prefix registered=%s", call(api.IsAddonMessagePrefixRegistered, ADDON_PREFIX))
    local channels = {}
    if IsInRaid and S.Call(IsInRaid) then channels[#channels + 1] = "RAID"
    elseif IsInGroup and S.Call(IsInGroup) then channels[#channels + 1] = "PARTY" end
    if IsInGuild and S.Call(IsInGuild) then channels[#channels + 1] = "GUILD" end
    if #channels == 0 then
        out("   not in a group or guild: nothing sent (join one and probe again)")
    end
    for _, channel in ipairs(channels) do
        out("   send %s: %s  (echo counted so far: %d)", channel, call(api.SendAddonMessage, ADDON_PREFIX, "probe", channel),
            counters.addonEcho[channel] or 0)
    end
end

local function Collect(out)
    local version, build, _, iface = GetBuildInfo()
    out(ns.NAME .. " %s probe — %s", ns.VERSION, date("%Y-%m-%d %H:%M:%S"))
    out("client %s (%s) interface %s, flavor=%s, project=%s, inCombat=%s, lockdown=%s",
        tostring(version), tostring(build), tostring(iface), ns.FLAVOR, tostring(WOW_PROJECT_ID), tostring(ns.InCombat()),
        tostring(InCombatLockdown and InCombatLockdown()))
    out("issecretvalue=%s canaccessvalue=%s", type(issecretvalue), type(canaccessvalue))
    local zone = GetZoneText and S.Call(GetZoneText)
    out("zone=%s pvpInfo=%s  hardcore: C_GameRules.IsHardcoreActive=%s (%s)", tostring(zone), call(ns.ZonePvPInfo),
        has("C_GameRules.IsHardcoreActive"), C_GameRules and call(C_GameRules.IsHardcoreActive) or "n/a")
    if ns.Census then
        local mapID, x, y = ns.Census.MapPosition("player")
        out("census: my map=%s position=%s, %s  friendly nameplates=%s  party1 map=%s",
            tostring(mapID), x and string.format("%.3f", x) or "nil", y and string.format("%.3f", y) or "nil",
            tostring(ns.Census.FriendlyPlatesOn()), tostring((ns.Census.MapPosition("party1"))))
    end
    out("skills: GetNumSkillLines=%s (%s) GetSkillLineInfo(1)=%s  stats: UnitStat(1)=%s GetItemStats=%s",
        has("GetNumSkillLines"), call(GetNumSkillLines), call(GetSkillLineInfo, 1), call(UnitStat, "player", 1),
        has("GetItemStats") == "yes" and "yes" or has("C_Item.GetItemStats"))
    out("professions: GetProfessions=%s (%s) GetProfessionInfo(first)=%s  window: GetTradeSkillLine=%s GetCraftDisplaySkillLine=%s "
        .. "C_TradeSkillUI.GetBaseProfessionInfo=%s GetAllRecipeIDs=%s  read: %s",
        has("GetProfessions"), call(GetProfessions), call(GetProfessionInfo, (S.CallMulti(1, GetProfessions))),
        has("GetTradeSkillLine"), has("GetCraftDisplaySkillLine"), has("C_TradeSkillUI.GetBaseProfessionInfo"),
        has("C_TradeSkillUI.GetAllRecipeIDs"), ns.Skills and ns.Skills.Source() or "?")
    out("auction house: C_AuctionHouse=%s SendSearchQuery=%s ReplicateItems=%s GetNumReplicateItems=%s (%s) "
        .. "REPLICATE_ITEM_LIST_UPDATE=%s SearchBar=%s QueryAuctionItems=%s CanSendAuctionQuery=%s",
        has("C_AuctionHouse"), has("C_AuctionHouse.SendSearchQuery"), has("C_AuctionHouse.ReplicateItems"),
        has("C_AuctionHouse.GetNumReplicateItems"), call(C_AuctionHouse and C_AuctionHouse.GetNumReplicateItems),
        valid("REPLICATE_ITEM_LIST_UPDATE"), has("AuctionHouseFrame.SearchBar"), has("QueryAuctionItems"), call(CanSendAuctionQuery))
    if ns.Fishing then
        local F = ns.Fishing
        out("fishing: spell 7620=%s IsFishingLoot=%s GetLootSlotInfo=%s GetWeaponEnchantInfo=%s (%s) pole=%s lure=%s skill=%s "
            .. "freeSlots=%s autoLoot=%s mapArt=%s (%s)",
            call(GetSpellInfo, 7620), has("IsFishingLoot"), has("GetLootSlotInfo"), has("GetWeaponEnchantInfo"),
            call(GetWeaponEnchantInfo), tostring(F.PoleEquipped()), tostring(F.Lure()), tostring(F.Effective()),
            tostring(F.FreeSlots()), tostring(F.AutoLootOn()), has("C_Map.GetMapArtLayerTextures"),
            call(C_Map and C_Map.GetMapArtLayers, F.Place().mapID or 0))
    end
    out("skill list: C_SkillInfo.GetNumSkillLines=%s (%s) GetSkillLineInfo(1)=%s  UnitDefense=%s UnitAttackBothHands=%s",
        has("C_SkillInfo.GetNumSkillLines"), C_SkillInfo and call(C_SkillInfo.GetNumSkillLines) or "n/a",
        C_SkillInfo and call(C_SkillInfo.GetSkillLineInfo, 1) or "n/a", call(UnitDefense, "player"),
        call(UnitAttackBothHands, "player"))
    -- The C_SkillInfo table's field names, to check the ones Skills tries.
    local first = C_SkillInfo and S.Call(C_SkillInfo.GetSkillLineInfo, 1)
    if type(first) == "table" then
        local keys = {}
        for k, v in pairs(first) do keys[#keys + 1] = tostring(k) .. "=" .. S.Describe(v) end
        table.sort(keys)
        out("   C_SkillInfo line 1: %s", table.concat(keys, " "))
    end
    if ns.Conditions then
        local t, pv = ns.Conditions.ReadTalents(), ns.Conditions.ReadPassives()
        out("talents: GetNumTalentTabs=%s GetTalentInfo=%s C_ClassTalents=%s C_Traits=%s -> %s  passives: %s  form=%s weapon=%s",
            has("GetNumTalentTabs"), has("GetTalentInfo"), has("C_ClassTalents.GetActiveConfigID"), has("C_Traits.GetConfigInfo"),
            t and (t.source .. " " .. t.summary) or "none", pv and #pv.ids or "none", tostring(ns.Conditions.ReadForm()),
            tostring(ns.Conditions.ReadWeaponEnchants()))
        -- Anything the client calls "legacy" (e.g. legacy talents): names only, to find the right API.
        local legacy = {}
        for name, value in pairs(_G) do
            if type(name) == "string" and name:lower():find("legacy") and (type(value) == "function" or type(value) == "table") then
                legacy[#legacy + 1] = name .. (type(value) == "table" and "{}" or "()")
            end
        end
        table.sort(legacy)
        out("globals named *legacy*: %s", #legacy > 0 and table.concat(legacy, " ", 1, math.min(#legacy, 40)) or "none")
    end
    out("my flag: UnitIsPVP=%s IsPVPTimerRunning=%s GetPVPTimer=%s ffa=%s",
        call(UnitIsPVP, "player"), call(IsPVPTimerRunning), call(GetPVPTimer), call(UnitIsPVPFreeForAll, "player"))
    out("events: CLEU=%s NAME_PLATE_UNIT_ADDED=%s UPDATE_MOUSEOVER_UNIT=%s UNIT_HEALTH=%s PLAYER_DEAD=%s PLAYER_FLAGS_CHANGED=%s UNIT_FACTION=%s",
        valid("COMBAT_LOG_EVENT_UNFILTERED"), valid("NAME_PLATE_UNIT_ADDED"), valid("UPDATE_MOUSEOVER_UNIT"),
        valid("UNIT_HEALTH"), valid("PLAYER_DEAD"), valid("PLAYER_FLAGS_CHANGED"), valid("UNIT_FACTION"))
    out("cvar nameplateMaxDistance=%s  nameplateShowEnemies=%s",
        tostring(ns.GetCVarNumber(ns.C.NAMEPLATE_DISTANCE_CVAR)), tostring(ns.GetCVarNumber("nameplateShowEnemies")))

    -- Item 1 and 2: enemy player facts and range, target / mouseover / plates.
    out("")
    out("[1-2,4] enemy players — target, mouseover, then up to 3 player nameplates")
    for _, unit in ipairs({ "target", "mouseover" }) do
        if S.Call(UnitExists, unit) then UnitReport(out, unit) else out("%s: none", unit) end
    end
    local plates, players = 0, 0
    for i = 1, 40 do
        local token = "nameplate" .. i
        if S.Call(UnitExists, token) then
            plates = plates + 1
            if S.Call(UnitIsPlayer, token) then
                players = players + 1
                if players <= 3 then UnitReport(out, token) end
            end
        end
    end
    out("nameplates visible=%d (players %d)", plates, players)
    local live, total = ns.Spotter.Count()
    out("spotter: %d live, %d listed", live, total)

    -- Item 3: casts by nameplate units.
    out("")
    out("[3] UNIT_SPELLCAST_START valid=%s CHANNEL=%s  since load: events=%d from players=%d readable spellID=%d in combat=%d",
        valid("UNIT_SPELLCAST_START"), valid("UNIT_SPELLCAST_CHANNEL_START"), counters.castEvents, counters.castPlayer,
        counters.castReadableSpell, counters.castInCombat)

    -- Item 5.
    out("")
    out("[5] CHAT_MSG_ADDON valid=%s", valid("CHAT_MSG_ADDON"))
    SendAddonProbes(out)

    -- Item 6: battleground APIs.
    out("")
    out("[6] BG: C_UIWidgetManager=%s UPDATE_UI_WIDGET=%s RequestBattlefieldScoreData=%s GetNumBattlefieldScores=%s (%s) C_PvP.GetScoreInfo=%s",
        has("C_UIWidgetManager.GetAllWidgetsBySetID"), valid("UPDATE_UI_WIDGET"), has("RequestBattlefieldScoreData"),
        has("GetNumBattlefieldScores"), call(GetNumBattlefieldScores), has("C_PvP.GetScoreInfo"))
    out("   GetBattlefieldStatus(1)=%s  CHAT_MSG_BG_SYSTEM_ALLIANCE=%s  UPDATE_BATTLEFIELD_SCORE=%s",
        call(GetBattlefieldStatus, 1), valid("CHAT_MSG_BG_SYSTEM_ALLIANCE"), valid("UPDATE_BATTLEFIELD_SCORE"))
    out("")
    out("Tip: run once out of combat and once in combat, with an enemy player targeted. Addon-message echoes arrive a moment later: probe again to see them.")
end

function Probe.Run()
    local lines = {}
    local function out(fmt, ...)
        local ok, msg = pcall(string.format, fmt, ...)
        lines[#lines + 1] = ok and msg or tostring(fmt)
    end
    local ok, err = pcall(Collect, out)
    if not ok then out("probe error: %s", tostring(err)) end
    ns.DB().lastProbe = lines
    Probe.ShowText(table.concat(lines, "\n"))
    ns.Print("probe done. Also saved to SavedVariables (ns.DB().lastProbe) on /reload.")
end

ns.RegisterModule("Probe", {
    events = { "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_CHANNEL_START", "CHAT_MSG_ADDON" },
    init = function()
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            pcall(C_ChatInfo.RegisterAddonMessagePrefix, ADDON_PREFIX)
        end
    end,
    onEvent = function(event, arg1, arg2, arg3, arg4)
        if event == "CHAT_MSG_ADDON" then
            if S.Value(arg1) == ADDON_PREFIX and S.Value(arg2) == "probe" then
                local channel = S.Value(arg3) or "?"
                counters.addonEcho[channel] = (counters.addonEcho[channel] or 0) + 1
            end
            return
        end
        -- UNIT_SPELLCAST_*: unit, castGUID, spellID.
        local unit = S.Value(arg1)
        if type(unit) ~= "string" or not unit:find("^nameplate") then return end
        counters.castEvents = counters.castEvents + 1
        if S.Call(UnitIsPlayer, unit) then counters.castPlayer = counters.castPlayer + 1 end
        if S.Value(arg3) then counters.castReadableSpell = counters.castReadableSpell + 1 end
        if ns.InCombat() then counters.castInCombat = counters.castInCombat + 1 end
    end,
})
