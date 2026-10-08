-- Offline smoke scenarios. Each scenario runs in a fresh Lua state (see run.py),
-- with ADDON_DIR, ADDON_FILES and SCENARIO set by the runner.

local function check(cond, msg)
    if not cond then error("CHECK FAILED: " .. msg, 2) end
end

local function boot(iface, opts)
    opts = opts or {}
    MOCK.iface = iface
    if opts.secrets then MOCK.EnableSecrets() end
    if opts.db then TALODDB = opts.db end
    MOCK.units.player = { exists = true, guid = "Player-1-0001", name = "Tester", level = opts.playerLevel or 20,
        faction = "Alliance" }
    local ns = MOCK.LoadAddon(ADDON_DIR, ADDON_FILES, ADDON_NAME)
    MOCK.FireEvent("ADDON_LOADED", ADDON_NAME)
    MOCK.Tick(0.3)
    return ns
end

local function slash(cmd) SlashCmdList.TALOD(cmd) MOCK.RunTimers() end

local function printed(pattern)
    for _, line in ipairs(MOCK.prints) do
        if line:find(pattern) then return true end
    end
    return false
end

local function plateAdd(token, unit)
    MOCK.units[token] = unit
    MOCK.FireEvent("NAME_PLATE_UNIT_ADDED", token)
    MOCK.Tick(0.3)
end

local function plateRemove(token)
    MOCK.units[token] = nil
    MOCK.FireEvent("NAME_PLATE_UNIT_REMOVED", token)
    MOCK.Tick(0.3)
end

local function setTarget(unit)
    MOCK.units.target = unit
    MOCK.FireEvent("PLAYER_TARGET_CHANGED")
    MOCK.Tick(0.3)
end

local function alertText()
    return TALODAlertText and TALODAlertText:IsShown() and TALODAlertText.text:GetText() or nil
end

local function resetOutput()
    MOCK.prints, MOCK.sounds = {}, {}
    if TALODAlertText then TALODAlertText:Hide() end
end

local scenarios = {}

scenarios.era_boot = function()
    local ns = boot(11509)
    check(ns.FLAVOR == "era", "flavor era")
    check(type(TALODDB) == "table" and TALODDB.alertsEnabled == true, "defaults merged")
    check(#MOCK.settingsCategories == 1, "settings category registered")
    check(SLASH_TALOD1 == "/talod" and SLASH_TALOD2 == nil, "slash commands")
    -- /pvp is the game's flag toggle: TALOD must never claim it.
    for k, v in pairs(_G) do
        if type(k) == "string" and k:find("^SLASH_") then check(v ~= "/pvp", "never registers /pvp (" .. k .. ")") end
    end
    check(printed("Enemies nearby"), "welcome printed")
    check(printed("distance max"), "nameplate distance hint printed (cvar 20)")
    check(TALODPanel:IsShown(), "panel shown")
    check(TALODPanel.empty:IsShown(), "empty text shown")
    check(TALODFlag:IsShown() and TALODFlag.text:GetText():find("PvP off"), "flag indicator: off")
end

scenarios.spotted_alert_and_panel = function()
    local ns = boot(11509)
    resetOutput()
    plateAdd("nameplate1", MOCK.Enemy({ level = 24, distance = 22, guild = "Gankers" }))
    local e = ns.Spotter.Get("Shadowfang")
    check(e and e.unit == "nameplate1", "entry with plate token")
    check(e.lo == 20 and e.hi == 25, "bracket 20-25, got " .. tostring(e.lo) .. "-" .. tostring(e.hi))
    check(alertText() and alertText():find("Shadowfang"), "alert text: " .. tostring(alertText()))
    check(alertText():find("!! ENEMY"), "loud: 4 levels above (>= 3)")
    check(#MOCK.sounds == 1, "loud alert played a sound")
    check(printed("ENEMY.*Shadowfang.*<Gankers>"), "chat line with guild")
    check(TALODPanel.title:GetText():find("1"), "panel title count")
    check(not TALODPanel.empty:IsShown(), "empty text hidden")

    -- The same player again: no repeat alert within the repeat window.
    resetOutput()
    plateRemove("nameplate1")
    plateAdd("nameplate2", MOCK.Enemy({ level = 24, distance = 12 }))
    check(alertText() == nil and #MOCK.sounds == 0, "no repeat alert")
    check(ns.Spotter.Get("Shadowfang").unit == "nameplate2", "entry follows the new token")
    check(ns.Spotter.Get("Shadowfang").hi == 15, "new bracket")

    -- Out of view: listed as gone, then dropped after the fade time.
    plateRemove("nameplate2")
    local live, total = ns.Spotter.Count()
    check(live == 0 and total == 1, "remembered after plate removal")
    MOCK.Tick(61)
    MOCK.Tick(0.3)
    live, total = ns.Spotter.Count()
    check(total == 0, "dropped after fade")

    -- Sorting: a skull outranks a lower enemy; live before remembered.
    plateAdd("nameplate3", MOCK.Enemy({ guid = "Player-1-A", name = "Lowbie", class = "MAGE", level = 18, distance = 9 }))
    plateAdd("nameplate4", MOCK.Enemy({ guid = "Player-1-B", name = "Skully", class = "WARRIOR", level = -1, distance = 33 }))
    local list = ns.Spotter.Sorted()
    check(list[1].name == "Skully", "skull first, got " .. tostring(list[1].name))
    check(ns.LevelText(list[1]) == "??", "skull level text")
    check(ns.Plates.LevelGapText(list[2]) == "-2", "gap -2")
end

scenarios.alert_rules = function()
    local ns = boot(11509)
    resetOutput()
    TALODDB.alertMinLevelGap = -5
    plateAdd("nameplate1", MOCK.Enemy({ guid = "Player-1-L", name = "Lowbie", level = 10 }))
    check(alertText() == nil, "too low: no alert")
    check(ns.Spotter.Get("Lowbie"), "still listed")

    -- KoS overrides the level filter and is loud.
    plateRemove("nameplate1")
    MOCK.Tick(61)
    ns.Journal.SetList("Lowbie", "kos")
    plateAdd("nameplate1", MOCK.Enemy({ guid = "Player-1-L", name = "Lowbie", level = 10 }))
    check(alertText() and alertText():find("KoS"), "KoS alert: " .. tostring(alertText()))
    check(#MOCK.sounds == 1, "KoS is loud")

    -- A loud class.
    resetOutput()
    TALODDB.alertLoudClasses.MAGE = true
    plateAdd("nameplate2", MOCK.Enemy({ guid = "Player-1-M", name = "Frosty", class = "MAGE", level = 20 }))
    check(alertText() and alertText():find("!! ENEMY"), "loud class")

    -- An equal-level, not-chosen class: a normal alert, no sound.
    resetOutput()
    plateAdd("nameplate3", MOCK.Enemy({ guid = "Player-1-W", name = "Bonk", class = "WARRIOR", level = 20 }))
    check(alertText() and alertText():find("^Enemy:"), "normal alert: " .. tostring(alertText()))
    check(#MOCK.sounds == 0, "normal alert is silent")

    -- Friendly players are never listed; source switches are honored.
    resetOutput()
    plateAdd("nameplate4", MOCK.Friend())
    check(ns.Spotter.Get("Buddy") == nil, "friend not listed")
    TALODDB.alertOnMouseover = false
    MOCK.units.mouseover = MOCK.Enemy({ guid = "Player-1-H", name = "Hover", level = 20, plate = false })
    MOCK.FireEvent("UPDATE_MOUSEOVER_UNIT")
    MOCK.Tick(0.3)
    check(ns.Spotter.Get("Hover") and alertText() == nil, "mouseover listed, alert off by setting")

    -- Disabled: nothing at all.
    resetOutput()
    slash("alerts off")
    plateAdd("nameplate5", MOCK.Enemy({ guid = "Player-1-Q", name = "Quiet", level = 30 }))
    check(alertText() == nil and not printed("Quiet"), "alerts off")
end

scenarios.target_readout_and_flag_safety = function()
    local ns = boot(11509)
    MOCK.class = "WARRIOR"
    -- The warrior knows Charge (8-25) and Hamstring (melee).
    local known = { [100] = true, [1715] = true }
    IsPlayerSpell = function(id) return known[id] == true end
    local ranges = { [100] = { 8, 25, "Charge" }, [1715] = { 0, 5, "Hamstring" } }
    C_Spell = {
        GetSpellInfo = function(id)
            local r = ranges[id]
            if r then return { minRange = r[1], maxRange = r[2], name = r[3] } end
        end,
        IsSpellInRange = function(id, unit)
            local r, u = ranges[id], MOCK.units[unit]
            if not r or not u then return nil end
            return u.distance >= r[1] and u.distance <= r[2]
        end,
    }
    MOCK.FireEvent("SPELLS_CHANGED")
    resetOutput()

    plateAdd("nameplate1", MOCK.Enemy({ level = 20, distance = 14 }))
    setTarget(MOCK.Enemy({ level = 20, distance = 14 }))
    local text = ns.Plates.TargetText(false)
    check(text and text:find("10–15 yd") and text:find("Charge") and text:find("Hamstring"), "readout: " .. tostring(text))
    local compact = ns.Plates.TargetText(true)
    check(compact:find("Charge") and not compact:find("Hamstring"), "compact readout lists only spells in range: " .. compact)
    check(TALODTargetReadout and TALODTargetReadout:IsShown(), "readout above the target plate")
    check(TALODPanel.footer:GetText():find("Target:"), "panel footer")

    -- Unflagged, an attackable enemy target: attacking would flag you.
    check(printed("Attacking Shadowfang will flag you"), "attack-flag warning")
    -- A flagged friendly player: healing would flag you.
    resetOutput()
    setTarget(MOCK.Friend({ pvp = true }))
    check(printed("Helping Buddy"), "help-flag warning")
    check(ns.Plates.TargetText(false) == nil, "no readout for friends")
    -- An unflagged friend: nothing.
    resetOutput()
    setTarget(MOCK.Friend({ guid = "Player-1-F2", name = "Calm", pvp = false }))
    check(not printed("flag you"), "no warning for an unflagged friend")
    -- Already flagged: no warnings, indicator red, then the countdown.
    MOCK.playerPvP = true
    resetOutput()
    setTarget(MOCK.Friend({ guid = "Player-1-F3", name = "Other", pvp = true }))
    check(not printed("flag you"), "no warning when already flagged")
    check(TALODFlag.text:GetText():find("PvP ON"), "indicator on")
    MOCK.pvpTimer = 192000
    MOCK.Tick(0.3)
    check(TALODFlag.text:GetText():find("off in 3:12"), "countdown: " .. TALODFlag.text:GetText())

    -- Hidden flag: "?", never "off".
    MOCK.pvpTimer = nil
    local saved = UnitIsPVP
    UnitIsPVP = nil
    MOCK.Tick(0.3)
    check(TALODFlag.text:GetText():find("PvP: %?"), "unknown flag shows ?")
    UnitIsPVP = saved
end

scenarios.journal_and_lists = function()
    local ns = boot(11509)
    plateAdd("nameplate1", MOCK.Enemy({ level = 24, guild = "Gankers" }))
    check(#TALODDB.journal == 1, "one row")
    local row = TALODDB.journal[1]
    check(row.name == "Shadowfang" and row.class == "ROGUE" and row.level == 24 and row.zone == "Elwynn Forest"
        and row.guild == "Gankers" and row.source == "nameplate", "row fields")
    check(TALODDB.players.Shadowfang.seen == 1, "player record")

    -- Seen again soon in the same zone: merged into the same row.
    plateRemove("nameplate1")
    MOCK.Tick(61)
    MOCK.now = MOCK.now + 120
    plateAdd("nameplate1", MOCK.Enemy({ level = 25 }))
    check(#TALODDB.journal == 1 and TALODDB.journal[1].level == 25, "merged, level updated")
    -- Much later: a new row.
    plateRemove("nameplate1")
    MOCK.Tick(61)
    MOCK.now = MOCK.now + 3600
    plateAdd("nameplate1", MOCK.Enemy({ level = 25 }))
    check(#TALODDB.journal == 2, "new row after the merge window")

    -- Lists by target and by name.
    setTarget(MOCK.Enemy({ level = 25 }))
    slash("kos target")
    check(ns.ListOf("Shadowfang") == "kos", "kos by target")
    slash("avoid somebody")
    check(ns.ListOf("Somebody") == "avoid", "avoid by typed name (capitalized)")
    slash("note Somebody camps the flight master")
    check(TALODDB.players.Somebody.note == "camps the flight master", "note")
    slash("unlist Somebody")
    check(ns.ListOf("Somebody") == nil, "unlisted")
    slash("who Shadowfang")
    check(printed("Shadowfang: 25 Rogue <Gankers> %[KoS%]"), "who line")

    -- Outcomes: target dies -> "they died"; you die while targeting -> "you died".
    MOCK.units.target.dead = true
    MOCK.Tick(0.3)
    check(TALODDB.journal[2].outcome == "they died" and TALODDB.players.Shadowfang.kills == 1, "they died")
    setTarget(MOCK.Enemy({ guid = "Player-1-K", name = "Killer", level = 30 }))
    MOCK.FireEvent("PLAYER_DEAD")
    check(TALODDB.players.Killer.deaths == 1, "you died recorded")

    -- Zone banner on entering contested territory, with recent sightings.
    MOCK.prints = {}
    MOCK.zonePvP = "contested"
    MOCK.zone = "Elwynn Forest"
    ns.Safety.CheckZone(true)
    check(printed("Contested territory: Elwynn Forest.*2 enemies seen here"), "zone banner")

    -- Deleting keeps lists.
    local removed = ns.Journal.Delete()
    check(removed == 3 and #TALODDB.journal == 0, "deleted all rows, got " .. removed)
    check(ns.ListOf("Shadowfang") == "kos", "KoS kept")
    check(TALODDB.players.Killer == nil, "unlisted player forgotten")
end

scenarios.vanish_heuristic = function()
    local ns = boot(11509)
    TALODDB.vanishAlert = true
    plateAdd("nameplate1", MOCK.Enemy({ level = 20, distance = 12 }))
    resetOutput()
    plateRemove("nameplate1")
    check(alertText() and alertText():find("Stealther vanished"), "vanish alert: " .. tostring(alertText()))
    check(ns.Spotter.Get("Shadowfang").vanished, "entry marked vanished")

    -- Too far, a non-stealth class, or the setting off: nothing.
    resetOutput()
    plateAdd("nameplate2", MOCK.Enemy({ guid = "Player-1-D", name = "Moonpaw", class = "DRUID", level = 20, distance = 37 }))
    resetOutput()
    plateRemove("nameplate2")
    check(alertText() == nil, "druid at 35-40 yd: no vanish alert")
    plateAdd("nameplate3", MOCK.Enemy({ guid = "Player-1-W", name = "Bonk", class = "WARRIOR", level = 20, distance = 5 }))
    resetOutput()
    plateRemove("nameplate3")
    check(alertText() == nil, "warrior: no vanish alert")
    TALODDB.vanishAlert = false
    plateAdd("nameplate4", MOCK.Enemy({ guid = "Player-1-R", name = "Sneak", level = 20, distance = 8 }))
    resetOutput()
    plateRemove("nameplate4")
    check(alertText() == nil, "setting off")
end

scenarios.combat_lockdown = function()
    local ns = boot(11509)
    plateAdd("nameplate1", MOCK.Enemy({ level = 20 }))
    local secure = {}
    for _, f in ipairs(MOCK.frames) do
        if f._template == "SecureActionButtonTemplate" and f:IsShown() then secure[#secure + 1] = f end
    end
    check(#secure == 1 and secure[1]:GetAttribute("unit") == "nameplate1" and secure[1]:GetAttribute("type") == "target",
        "one click-to-target button for the live row")
    MOCK.FireEvent("PLAYER_REGEN_DISABLED")
    MOCK.lockdown = true
    check(not secure[1]:IsShown(), "hidden before lockdown")
    -- In combat, new enemies are listed but no secure button is touched.
    local count = #MOCK.frames
    plateAdd("nameplate2", MOCK.Enemy({ guid = "Player-1-X", name = "Second", level = 20 }))
    for i = count + 1, #MOCK.frames do
        check(MOCK.frames[i]._template ~= "SecureActionButtonTemplate", "no secure button created in combat")
    end
    check(not secure[1]:IsShown(), "still hidden in combat")
    MOCK.lockdown = false
    MOCK.FireEvent("PLAYER_REGEN_ENABLED")
    check(secure[1]:IsShown(), "back after combat")
end

scenarios.forever_secrets = function()
    local ns = boot(16001, { secrets = true })
    check(ns.IS_FOREVER, "forever")
    MOCK.secretMode = true
    resetOutput()
    -- Name, GUID and level hidden: listed by token, no journal row, "?" level.
    plateAdd("nameplate1", MOCK.Enemy({ secret = { name = true, guid = true, level = true } }))
    local e = ns.Spotter.Get("?nameplate1")
    check(e and not e.keyed, "unkeyed entry")
    check(ns.LevelText(e) == "?", "hidden level is ?")
    check(#TALODDB.journal == 0, "nothing journaled without a name")
    check(alertText() and alertText():find("Unknown"), "still alerts (hostility readable): " .. tostring(alertText()))

    -- Hostility hidden: listed as unknown, never alerts.
    resetOutput()
    plateAdd("nameplate2", MOCK.Enemy({ guid = "Player-1-S", name = "Hidden", secret = { enemy = true } }))
    local h = ns.Spotter.Get("Hidden")
    check(h and h.hostile == nil, "hostility unknown")
    check(alertText() == nil, "no alert for unknown hostility")

    -- Range hidden: "? yd", never a number.
    MOCK.secretRange = true
    MOCK.Tick(0.3)
    check(ns.Spotter.Get("Hidden").rangeOK == false, "range unknown")
    check(ns.FormatRange(nil, nil) == "? yd", "unknown range text")
    MOCK.secretRange = false
    MOCK.Tick(0.3)
end

-- Allies whose hostility is hidden are filtered by faction / group / friend,
-- unless they can be attacked (duel) or the zone is free-for-all.
scenarios.allies_filtered = function()
    local ns = boot(16001, { secrets = true })
    MOCK.secretMode = true
    resetOutput()
    plateAdd("nameplate1", MOCK.Friend({ name = "Ally", guid = "Player-1-A", enemy = true, secret = { enemy = true } }))
    check(ns.Spotter.Get("Ally") == nil, "same-faction ally with hidden hostility is not listed")
    plateAdd("nameplate2", MOCK.Friend({ name = "Mate", guid = "Player-1-M", faction = "Horde", friend = false,
        secret = { enemy = true, faction = true } }))
    check(ns.Spotter.Get("Mate") ~= nil, "faction unknown, not a friend: still listed as ?")
    MOCK.units.nameplate2.friend = true
    MOCK.Tick(0.3)
    check(ns.Spotter.Get("Mate") == nil, "dropped once UnitIsFriend says ally")
    plateAdd("nameplate3", MOCK.Enemy({ guid = "Player-1-S", name = "Hidden", secret = { enemy = true } }))
    check(ns.Spotter.Get("Hidden") and ns.Spotter.Get("Hidden").hostile == nil, "other faction with hidden hostility is listed")

    -- Same faction but readable as an enemy you can attack: a duel.
    plateAdd("nameplate4", MOCK.Friend({ name = "Dueler", guid = "Player-1-D", enemy = true, canAttack = true }))
    check(ns.Spotter.Get("Dueler") and ns.Spotter.Get("Dueler").hostile == true, "duel opponent listed")
    -- Same faction, "enemy" but readably not attackable: an ally.
    plateAdd("nameplate5", MOCK.Friend({ name = "Odd", guid = "Player-1-O", enemy = true, canAttack = false }))
    check(ns.Spotter.Get("Odd") == nil, "unattackable same-faction player is not listed")

    -- Free-for-all zone: your own faction can attack you.
    MOCK.zonePvPFFA = true
    plateAdd("nameplate6", MOCK.Friend({ name = "Arena", guid = "Player-1-F", secret = { enemy = true }, enemy = true }))
    check(ns.Spotter.Get("Arena") ~= nil, "same faction kept in a free-for-all zone")
    MOCK.zonePvPFFA = nil
    check(not ns.Spotter.Get("Ally") and not ns.Spotter.Get("Odd"), "no allies in the list")
end

-- Census: both factions logged at your position, throttled per player,
-- allies only counted in capitals, group members at their own position.
scenarios.census_logging = function()
    local ns = boot(11509)
    local c = TALODDB.census
    local function fields(line)
        local out = {}
        for v in (line .. ","):gmatch("([^,]*),") do out[#out + 1] = v end
        return out
    end
    MOCK.subzone = "Goldshire"
    plateAdd("nameplate1", MOCK.Enemy({ guild = "Reds" }))
    plateAdd("nameplate2", MOCK.Friend())
    MOCK.Tick(1.1) MOCK.now = MOCK.now + 1 MOCK.Tick(0.3)
    check(#c.points == 2, "enemy and ally logged: " .. #c.points)
    local e, a
    for _, line in ipairs(c.points) do
        local p = fields(line)
        if p[17] == "Shadowfang" then e = p elseif p[17] == "Buddy" then a = p end
    end
    check(e and a, "both keyed points")
    check(#e == 19 and e[19] == "#1" and e[2] == "1429" and e[3] == "420" and e[4] == "650", "map, your position, your character: " .. table.concat(e, ","))
    check(e[5] == "H" and e[6] == "E" and e[7] == "ROGUE" and e[8] == "24" and e[12] == "n" and e[18] == "Reds", "enemy facts")
    check(e[15] == "1" and e[16] == "1", "one enemy and one ally in view")
    check(a[5] == "A" and a[6] == "F", "ally facts")
    check(c.maps[1429] == "Elwynn Forest" and c.labels[1429].Goldshire, "map name and subzone label")
    check(next(c.cells[1429]) ~= nil, "summary cells")
    check(ns.Spotter.Get("Buddy") == nil, "ally still not in the enemy list")

    -- Throttle: enemy every 5 s, ally every 30 s.
    MOCK.now = MOCK.now + 6 MOCK.Tick(0.3)
    check(#c.points == 3, "enemy again after 5 s, ally not: " .. #c.points)

    -- Capital: the ally is counted but not tracked.
    MOCK.mapID = 1453
    MOCK.now = MOCK.now + 31 MOCK.Tick(0.3)
    check(#c.points == 4, "only the enemy gets a point in a capital: " .. #c.points)
    check(c.cells[1453] and next(c.cells[1453]), "capital ally counted")
    MOCK.mapID = 1429

    -- Group member at their own position.
    plateRemove("nameplate1") plateRemove("nameplate2")
    MOCK.units.party1 = MOCK.Friend({ name = "Mate", guid = "Player-1-P", mapX = 0.1, mapY = 0.2 })
    MOCK.now = MOCK.now + 31 MOCK.Tick(0.3)
    local g = fields(c.points[#c.points])
    check(g[17] == "Mate" and g[12] == "g" and g[3] == "100" and g[4] == "200", "group member position: " .. c.points[#c.points])
    MOCK.units.party1 = nil

    -- Off: nothing logged. Trim keeps the newest.
    TALODDB.censusEnabled = false
    plateAdd("nameplate1", MOCK.Enemy())
    local n = #c.points
    MOCK.now = MOCK.now + 60 MOCK.Tick(0.3)
    check(#c.points == n, "disabled logs nothing")
    TALODDB.censusEnabled = true
    TALODDB.censusMaxPoints = 2
    for i = 1, 20 do c.points[#c.points + 1] = "old" .. i end
    MOCK.now = MOCK.now + 60 MOCK.Tick(0.3)
    check(#c.points == 2 and c.points[2]:find("Shadowfang"), "trimmed to the newest")
    slash("census")
    check(printed("census on"), "status line")
    ns.Census.Delete("all")
    check(#TALODDB.census.points == 0 and next(TALODDB.census.cells) == nil, "deleted")
end

-- Gear ledger: first snapshot at login, a swap measured before/after with
-- the item-stat difference and the item's source, buff flag, level-up entry,
-- manual snapshot, and the window's views.
scenarios.gear_ledger = function()
    MOCK.items[1001] = { equipLoc = "INVTYPE_CHEST", stats = { ITEM_MOD_STAMINA_SHORT = 3, RESISTANCE0_NAME = 50 } }
    MOCK.items[1002] = { equipLoc = "INVTYPE_CHEST", stats = { ITEM_MOD_STAMINA_SHORT = 7, ITEM_MOD_STRENGTH_SHORT = 2, RESISTANCE0_NAME = 90 } }
    MOCK.items[1003] = { equipLoc = "INVTYPE_HEAD", stats = { ITEM_MOD_STAMINA_SHORT = 1 } }
    local old, new, helm = MOCK.ItemLink(1001, "Old Vest"), MOCK.ItemLink(1002, "New Breastplate"), MOCK.ItemLink(1003, "Cap")
    MOCK.equipped[5] = old
    MOCK.bags[0][1] = helm
    local ns = boot(11509)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    local c = ns.Gear.Char()
    check(c and #c.snapshots == 1 and c.snapshots[1].reason == "first", "first snapshot at login")
    check(c.snapshots[1].stats.sta == 23 + 3 and c.snapshots[1].stats.armor == 90, "measured stats: " .. tostring(c.snapshots[1].stats.sta))
    check(c.seen[helm] and #c.acquired == 0, "items you already had are the baseline")

    -- A quest reward arrives, then is equipped.
    MOCK.questTitle = "The Fargodeep Mine"
    MOCK.FireEvent("QUEST_COMPLETE")
    MOCK.bags[0][2] = new
    MOCK.FireEvent("BAG_UPDATE_DELAYED")
    MOCK.FireEvent("QUEST_FINISHED")
    check(#c.acquired == 1 and c.acquired[1].kind == "quest" and c.acquired[1].detail == "The Fargodeep Mine", "quest source")
    MOCK.equipped[5], MOCK.bags[0][2] = new, old
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 5, false)
    MOCK.Tick(1)
    check(#c.ledger == 0, "waits for the gear to settle")
    MOCK.Tick(1.2)
    local e = c.ledger[1]
    check(e and e.kind == "gear" and #e.changes == 1 and e.changes[1].slot == 5, "one change in the chest slot")
    check(e.changes[1].old == old and e.changes[1].new == new and e.changes[1].src.kind == "quest", "old, new and source")
    check(e.delta.sta == 4 and e.delta.str == 2 and e.delta.armor == 40, "measured delta")
    check(e.itemDelta.ITEM_MOD_STAMINA_SHORT == 4 and e.itemDelta.RESISTANCE0_NAME == 40, "tooltip delta")
    check(not e.buffsChanged and #c.snapshots == 2, "no buff flag; snapshot saved")

    -- A buff appears during a swap: flagged.
    MOCK.equipped[1] = helm
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 1, false)
    MOCK.units.player.buffs = { { spellId = 1243 } }
    MOCK.buffStamina = 3
    MOCK.Tick(2.2)
    check(c.ledger[2].buffsChanged and c.ledger[2].delta.sta == 4, "buff flagged (+1 helm, +3 buff)")

    -- Swapping back and forth inside the settle time is no change.
    MOCK.equipped[1] = nil
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 1, true)
    MOCK.equipped[1] = helm
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 1, false)
    MOCK.Tick(2.2)
    check(#c.ledger == 2, "no entry for a swap back")

    -- Level up: its own entry.
    MOCK.units.player.level = 21
    MOCK.FireEvent("PLAYER_LEVEL_UP", 21)
    MOCK.Tick(2.2)
    check(c.ledger[3].kind == "level" and c.ledger[3].level == 21, "level-up entry")

    -- Vendor purchase with the price.
    MOCK.items[1004] = { equipLoc = "INVTYPE_FEET", stats = {} }
    MOCK.FireEvent("MERCHANT_SHOW")
    MOCK.money = 10000 - 325
    MOCK.bags[0][3] = MOCK.ItemLink(1004, "Boots")
    MOCK.FireEvent("BAG_UPDATE_DELAYED")
    MOCK.FireEvent("MERCHANT_CLOSED")
    check(c.acquired[2].kind == "vendor" and c.acquired[2].cost == 325, "vendor price")

    slash("gear snap PvP set")
    check(c.snapshots[#c.snapshots].name == "PvP set" and c.snapshots[#c.snapshots].reason == "manual", "named snapshot")
    check(ns.Gear.DeltaText({ sta = 4, agi = -1 }):find("Stamina %+4"), "delta text")

    -- The window and its views build and refresh without errors.
    slash("gear")
    check(ns.GearUI.IsShown(), "window open")
    for _, view in ipairs({ "ledger", "progress", "sources", "snapshots" }) do
        ns.GearUI.state.view = view
        ns.GearUI.Refresh()
    end
    ns.GearUI.state.b = 1
    ns.GearUI.Refresh()
    slash("gear status")
    check(printed("snapshots"), "status")
    check(TALODDB.gear["Tester-Mockrealm"] == c, "per-character key")
end

-- Skills: baseline at login, skill-ups merged, training, collapsed
-- categories kept, the view and its settings page.
scenarios.skills_tracking = function()
    MOCK.skillLines = {
        { "Professions", true, true },
        { "Herbalism", false, nil, 40, 0, 0, 75 },
        { "Secondary Skills", true, true },
        { "Fishing", false, nil, 10, 0, 0, 75 },
        { "Weapon Skills", true, true },
        { "Swords", false, nil, 95, 0, 0, 100 },
        { "Languages", true, true },
        { "Common", false, nil, 300, 0, 0, 1 },
    }
    local ns = boot(11509)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    local c = ns.Skills.Char()
    check(c.current.Herbalism and c.current.Herbalism.rank == 40 and c.current.Herbalism.cat == "Professions", "baseline read")
    check(c.current.Common == nil, "rankless lines skipped")
    check(#c.log == 0, "no log entries for the baseline")

    MOCK.skillLines[4][4] = 11
    MOCK.FireEvent("SKILL_LINES_CHANGED")
    MOCK.Tick(0.6)
    MOCK.skillLines[4][4] = 13
    MOCK.FireEvent("SKILL_LINES_CHANGED")
    MOCK.Tick(0.6)
    check(#c.log == 1 and c.log[1].kind == "up" and c.log[1].from == 10 and c.log[1].to == 13, "skill-ups merged: " .. #c.log)

    MOCK.skillLines[2][7] = 150
    MOCK.FireEvent("SKILL_LINES_CHANGED")
    MOCK.Tick(0.6)
    check(c.log[2].kind == "trained" and c.log[2].to == 150, "training logged")

    -- A weapon skill max rising with your level is not "training".
    MOCK.skillLines[6][7] = 105
    MOCK.FireEvent("SKILL_LINES_CHANGED")
    MOCK.Tick(0.6)
    check(#c.log == 2, "weapon max change not logged as training")

    -- Collapsed category: its skills are kept, not dropped.
    MOCK.skillLines = { { "Professions", true, false }, { "Secondary Skills", true, true }, { "Fishing", false, nil, 13, 0, 0, 75 } }
    MOCK.FireEvent("SKILL_LINES_CHANGED")
    MOCK.Tick(0.6)
    check(c.current.Herbalism ~= nil and c.collapsed.Professions, "collapsed category kept")
    check(c.log[#c.log].kind == "dropped" and c.log[#c.log].name == "Swords", "skill gone from a visible category is dropped")
    check(ns.Skills.GainedSince(c, "Fishing", 0) == 3, "gained")

    slash("skills")
    check(ns.GearUI.IsShown() and ns.GearUI.state.view == "skills", "skills tab open")
    ns.GearUI.Refresh()
    slash("char")
    check(not ns.GearUI.IsShown(), "char toggles the window")
    slash("char")
    check(ns.GearUI.IsShown(), "char opens it again")
end

-- Conditions: talents (classic trees), passive spells, form and weapon
-- enchants are kept with snapshots; a talent change is its own ledger entry
-- with the stat difference; comparisons flag different conditions.
scenarios.gear_conditions = function()
    local talents = { { name = "Arms", list = { { "Deflection", 2, 5 }, { "Tactical Mastery", 0, 5 } } }, { name = "Fury", list = {} }, { name = "Protection", list = {} } }
    function GetNumTalentTabs() return #talents end
    function GetTalentTabInfo(tab) return talents[tab].name, 132355, 0 end
    function GetNumTalents(tab) return #talents[tab].list end
    function GetTalentInfo(tab, i) local t = talents[tab].list[i]; return t[1], 1, 1, i, t[2], t[3] end
    local book = { { 9116, true }, { 78, false } }
    local names = { [9116] = "Shield", [78] = "Heroic Strike", [12281] = "Sword Specialization", [2457] = "Battle Stance" }
    function GetNumSpellTabs() return 1 end
    function GetSpellTabInfo() return "General", 1, 0, #book end
    function GetSpellBookItemInfo(i) return "SPELL", book[i] and book[i][1] end
    function IsPassiveSpell(i) return book[i] and book[i][2] end
    function GetSpellInfo(id) return names[id] end
    local form = 0
    function GetShapeshiftForm() return form end
    function GetShapeshiftFormInfo(i) return 132349, "Battle Stance", true, true end
    function GetWeaponEnchantInfo() return false end

    MOCK.items[2001] = { equipLoc = "INVTYPE_HEAD", stats = { ITEM_MOD_STAMINA_SHORT = 2 } }
    local ns = boot(11509)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    local c = ns.Gear.Char()
    local first = c.snapshots[1]
    local set = ns.Gear.TalentSet(c, first.talents)
    check(set and set.summary == "2/0/0" and set.picks.Deflection == 2 and set.source == "trees", "talents in the snapshot")
    check(ns.Gear.PassiveSet(c, first.passives) and #ns.Gear.PassiveSet(c, first.passives).ids == 1, "passives in the snapshot")
    check(first.form == "none" and first.weapon == "none", "form and weapon enchants")

    -- A talent point that gives stamina: its own entry with the measured gain.
    talents[1].list[1][2] = 3
    MOCK.buffStamina = 2
    MOCK.FireEvent("CHARACTER_POINTS_CHANGED", -1)
    MOCK.Tick(2.2)
    local e = c.ledger[#c.ledger]
    check(e and e.kind == "talents" and e.talentsBefore == "2/0/0" and e.talentsAfter == "3/0/0", "talent entry")
    check(e.talentsGained[1] == "Deflection 2 -> 3" and e.delta.sta == 2, "what changed and what it did")
    check(c.snapshots[#c.snapshots].reason == "talents", "talent snapshot")

    -- A new passive spell (no talent change).
    book[3] = { 12281, true }
    MOCK.FireEvent("SPELLS_CHANGED")
    MOCK.Tick(2.2)
    e = c.ledger[#c.ledger]
    check(e.kind == "talents" and not e.talentsAfter and e.passivesGained[1] == "Sword Specialization", "passive entry")

    -- Unrelated SPELLS_CHANGED: no entry.
    local n = #c.ledger
    MOCK.FireEvent("SPELLS_CHANGED")
    MOCK.Tick(2.2)
    check(#c.ledger == n, "no entry without a change")

    -- Gear change in a different form: flagged; comparisons see it.
    form = 1
    MOCK.equipped[1] = MOCK.ItemLink(2001, "Helm")
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 1, false)
    MOCK.Tick(2.2)
    e = c.ledger[#c.ledger]
    check(e.kind == "gear" and e.formChanged, "form change flagged on the gear entry")
    local diff = ns.Gear.ConditionDiff(c, c.snapshots[#c.snapshots], c.snapshots[1])
    local text = table.concat(diff, " | ")
    check(text:find("Talents 3/0/0 vs 2/0/0") and text:find("Passive") and text:find("Form"), "condition diff: " .. text)

    slash("gear")
    ns.GearUI.state.a, ns.GearUI.state.b = #c.snapshots, 1
    ns.GearUI.Refresh()
    ns.GearUI.state.view = "ledger"
    ns.GearUI.Refresh()
    ns.GearUI.state.view = "progress"
    ns.GearUI.state.stat = "sta"
    ns.GearUI.Refresh()
    -- Hover: the crosshair snaps to a snapshot and the tooltip says what changed.
    local v = ns.GearUI.views.progress
    -- Overview first: a tile per stat with a value.
    local tiles = 0
    for _, t in ipairs(v.tiles) do if t:IsShown() then tiles = tiles + 1 end end
    check(v.page == "overview" and tiles >= 8, "overview tiles: " .. tiles)
    local sta
    for _, t in ipairs(v.tiles) do if t.key == "sta" then sta = t end end
    check(sta and sta.value:GetText() ~= "" and sta.delta:GetText():find("%+"), "stamina tile shows the gain: " .. tostring(sta and sta.value:GetText()) .. " " .. tostring(sta and sta.delta:GetText()))
    sta:Fire("OnClick")
    check(v.page == "detail" and v.detail:IsShown() and not v.overview:IsShown(), "a tile opens the chart")
    check(v.points_ and #v.points_ == #c.snapshots, "one point per snapshot: " .. tostring(v.points_ and #v.points_))
    v.plot._width, v.plot._height = 600, 300
    v.plot.IsMouseOver = function() return true end
    v.plot.GetLeft = function() return 0 end
    MOCK.cursorX = 600
    v.plot:Fire("OnUpdate")
    check(v.hovering == #v.points_ and GameTooltip:IsShown(), "hover picks the last snapshot")
    v.mode = "level"
    ns.GearUI.Refresh()
    check(#v.points_ == 1, "by level: one point per level")
end

-- Combat: Forever hides your stats. A level-up from a kill is measured
-- when combat ends; "before" is not overwritten with hidden stats; an old
-- snapshot saved with hidden stats is repaired.
scenarios.gear_combat = function()
    local ns = boot(16001, { secrets = true })
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    local c = ns.Gear.Char()
    check(#c.snapshots == 1 and ns.Gear.StatsReadable(c.snapshots[1].stats), "first snapshot readable")

    -- Level up in combat with stats hidden.
    MOCK.units.player.combat = true
    MOCK.statsHidden = true
    MOCK.units.player.level = 21
    MOCK.levelStamina = 5
    MOCK.FireEvent("PLAYER_LEVEL_UP", 21)
    -- A long fight (over the 2-minute fallback): still queued, not given up.
    for _ = 1, 30 do MOCK.Tick(5) end
    check(#c.snapshots == 1, "nothing measured in combat")
    MOCK.units.player.combat = false
    MOCK.statsHidden = false
    MOCK.Tick(0.3)
    local snap = c.snapshots[#c.snapshots]
    check(#c.snapshots == 2 and snap.reason == "level" and not ns.Gear.IsPartial(snap), "level snapshot after combat, complete")
    local e = c.ledger[#c.ledger]
    check(e.kind == "level" and e.delta and e.delta.sta == 5, "level-up gain measured: " .. tostring(e.delta and e.delta.sta))

    -- An old snapshot saved with hidden stats (older version) is repaired.
    local items = {}
    for k, v in pairs(snap.items) do items[k] = v end
    c.snapshots[#c.snapshots + 1] = { t = snap.t + 10, level = 21, items = items, stats = { hp = 100 }, reason = "level" }
    c.ledger[#c.ledger + 1] = { kind = "level", t = snap.t + 10, level = 21, delta = { hp = 25 }, snapTime = snap.t + 10 }
    MOCK.Tick(5.5)
    local fixed = c.snapshots[#c.snapshots]
    check(not ns.Gear.IsPartial(fixed) and fixed.repaired and fixed.stats.sta == snap.stats.sta, "partial snapshot repaired")
    check(c.ledger[#c.ledger].repaired and c.ledger[#c.ledger].delta == nil, "its entry recomputed (no change vs the one before)")
    slash("gear")
    ns.GearUI.state.view = "ledger"
    ns.GearUI.Refresh()
end

-- Enhance: options per slot from the generated data, what fits the item,
-- your skill and reagent counts, the recipe tree.
scenarios.enhance_view = function()
    MOCK.items[3001] = { equipLoc = "INVTYPE_WRIST", stats = {} }
    MOCK.items[3002] = { equipLoc = "INVTYPE_HOLDABLE", stats = {} }
    MOCK.equipped[9] = MOCK.ItemLink(3001, "Bracers")
    MOCK.equipped[17] = MOCK.ItemLink(3002, "Orb")
    MOCK.skillLines = { { "Professions", true, true }, { "Enchanting", false, nil, 80, 0, 0, 150 } }
    function GetItemCount(id) return id == 10940 and 3 or 0 end
    local ns = boot(11509)
    check(ns.EnhanceData and #ns.EnhanceData.enhancements > 100, "generated data loaded")
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)

    local bracer = ns.Enhance.ForSlot(9)
    local minor
    for _, e in ipairs(bracer) do if e.spell == 7418 then minor = e end end
    check(minor and minor.name == "Bracer - Minor Health", "bracer enchant listed")
    check(ns.Enhance.Fits(minor, 9, MOCK.equipped[9], 20, 20), "fits bracers")
    local spike
    for _, e in ipairs(ns.Enhance.ForSlot(17)) do if e.name == "Iron Shield Spike" then spike = e end end
    local ok, why = ns.Enhance.Fits(spike, 17, MOCK.equipped[17], 20, 20)
    check(spike and not ok and why == "needs a shield", "shield spike does not fit an off-hand orb")
    check(ns.Enhance.SkillText(ns.EnhanceData.recipes[7418]):find("you 80"), "your skill shown")
    check(ns.Enhance.HowToGet(3575):find("Mining"), "iron bar comes from mining: " .. ns.Enhance.HowToGet(3575))
    check(ns.Enhance.HowToGet(10940) == "Disenchanting", "dust from disenchanting")
    local tree = table.concat(ns.Enhance.TreeLines(6042, 1), " | ")
    check(tree:find("Iron Bar") and tree:find("Blacksmithing"), "recipe tree")
    check(ns.Enhance.IsEnchanted("|Hitem:123:41:::|h") and not ns.Enhance.IsEnchanted("|Hitem:123::::|h"), "enchant in the link")

    -- Profession filters.
    ns.Enhance.ToggleProf("Enchanting")
    check(not ns.Enhance.ProfShown("Enchanting") and ns.Enhance.ProfShown("Leatherworking"), "hide one profession")
    ns.Enhance.ToggleProf("Enchanting")
    ns.Enhance.ToggleProf("Leatherworking", true)
    check(ns.Enhance.ProfShown("Leatherworking") and not ns.Enhance.ProfShown("Enchanting") and not ns.Enhance.ProfShown("Blacksmithing"), "only one")
    ns.Enhance.ToggleProf("Leatherworking", true)
    check(ns.Enhance.ProfShown("Enchanting") and ns.Enhance.ProfShown("Blacksmithing"), "right-click again: all")
    TALODDB.enhanceMineOnly = true
    check(ns.Enhance.ProfShown("Enchanting") and not ns.Enhance.ProfShown("Engineering"), "my professions only (Enchanting 80)")
    TALODDB.enhanceMineOnly = false

    slash("enhance")
    check(ns.GearUI.IsShown() and ns.GearUI.state.view == "enhance", "enhance tab")
    local v = ns.GearUI.views.enhance
    check(#v.chips >= 4 and v.chips[1].label:GetText():find("Enchanting"), "profession chips")
    v.chips[1]:Fire("OnClick", "LeftButton")
    check(not ns.Enhance.ProfShown("Enchanting"), "chip click hides Enchanting")
    v.chips[1]:Fire("OnClick", "LeftButton")
    ns.Enhance.ShowSlot(17)
    ns.Enhance.state.fitsOnly = false
    ns.Enhance.state.temporary = true
    ns.GearUI.Refresh()
end

-- Professions: leveling plan from the generated data (chance rule,
-- training, make-first intermediates, bags counted, exclusions, known
-- recipes read from the profession window), the tab and /talod plan.
scenarios.profession_plan = function()
    MOCK.skillLines = { { "Professions", true, true }, { "Tailoring", false, nil, 1, 0, 0, 75 },
        { "Secondary Skills", true, true }, { "First Aid", false, nil, 1, 0, 0, 75 } }
    -- 20 Linen Cloth in the bags (one per slot in the mock), GetItemCount agrees.
    MOCK.bags[1] = {}
    for i = 1, 20 do MOCK.bags[i <= 16 and 0 or 1][i <= 16 and i or i - 16] = MOCK.ItemLink(2589, "Linen Cloth") end
    function GetItemCount(id) return id == 2589 and 20 or 0 end
    local ns = boot(11509)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    local P = ns.Professions
    local bandage = P.DATA.recipes[3275]
    check(bandage and bandage.name == "Linen Bandage" and bandage.prof == "First Aid", "generated data loaded")
    check(P.DATA.recipes[3276].src[1] == "trainer", "Heavy Linen Bandage is a trainer recipe")

    -- Vanilla skill-up chance: 1 up to yellow, falling to 0 at grey.
    local c = bandage.colors
    check(P.Chance(bandage, c[1]) == 1 and P.Chance(bandage, c[4]) == 0, "orange sure, grey never")
    check(math.abs(P.Chance(bandage, math.floor((c[2] + c[4]) / 2)) - (c[4] - math.floor((c[2] + c[4]) / 2)) / (c[4] - c[2])) < 1e-9, "linear chance")

    local plan = P.PlanFor(nil, "First Aid", 75)
    check(plan.from == 1 and plan.to == 75 and #plan.gaps == 0, "first aid 1-75 has no gap: " .. P.Summary(plan))
    check(plan.steps[1].kind == "craft" and plan.steps[1].recipe.id == 3275 and plan.steps[1].from == 1, "starts with Linen Bandage")
    check(plan.crafts >= 74, "at least one craft per point: " .. plan.crafts)
    local linen
    for _, e in ipairs(plan.shopping) do if e.id == 2589 then linen = e end end
    check(linen and linen.have == 20 and linen.buy == linen.need - 20, "bags counted")
    -- GetItemCount sees more than the bag scan (reagent bag, bank): it wins.
    -- Without it, the bag scan still counts.
    function GetItemCount(id) return id == 4289 and 26 or (id == 2589 and 20 or 0) end
    MOCK.Tick(1.5)
    check(P.Count(4289) == 26, "salt in the reagent bag counted")
    local saved = GetItemCount
    GetItemCount, C_Item.GetItemCount = nil, nil
    check(P.Count(2589) == 20, "no GetItemCount: bag scan")
    GetItemCount = saved
    function GetItemCount(id) return id == 2589 and 20 or 0 end
    check(plan.total > 0 and plan.materials == plan.total - plan.learn - plan.training, "cost adds up")

    -- Tailoring 1 -> 150: Journeyman at 75, bolts made first.
    local tp = P.PlanFor(nil, "Tailoring", 150)
    local train, bolts
    for _, step in ipairs(tp.steps) do
        if step.kind == "train" then train = train or step end
        for _, prep in ipairs(step.prep or {}) do if prep.item == 2996 then bolts = prep end end
    end
    check(train and train.at == 75 and train.rank.rank == "Journeyman" and train.rank.cost == 500, "train Journeyman at 75")
    check(bolts and bolts.recipe.prof == "Tailoring", "Bolt of Linen Cloth made first")
    check(tp.training == 500 and #tp.gaps == 0, "tailoring: " .. P.Summary(tp))
    -- Each step lists its materials as to-do lines: bags, made above, make (with its own materials), buy.
    local first = plan.steps[1]
    check(first.mats and first.mats[1].id == 2589 and first.mats[1].have == 20 and first.mats[1].buy == first.mats[1].n - 20,
        "step lines: 20 linen in bags, buy the rest")
    local made, makeLine
    for _, step in ipairs(tp.steps) do
        for _, line in ipairs(step.mats or {}) do
            if line.made and line.id == 2996 then made = made or line end
            if line.make and line.children and line.children[1] and line.children[1].id == 2589 then makeLine = line end
        end
    end
    check(made and made.id == 2996, "bolts made in an earlier step count as made above")
    check(makeLine and makeLine.recipe.creates == 2996, "make bolts, with the linen it needs")

    -- Right-click exclusion: the recipe is not used again.
    local first = tp.steps[1].recipe
    TALODDB.profPlanExcluded[first.id] = true
    local tp2 = P.PlanFor(nil, "Tailoring", 150)
    for _, step in ipairs(tp2.steps) do check(step.recipe ~= first, "excluded recipe not used") end
    TALODDB.profPlanExcluded = {}

    -- Trainer only: no dropped / vendor patterns unless known.
    TALODDB.profPlanPatterns = false
    for _, step in ipairs(P.PlanFor(nil, "Tailoring", 300).steps) do
        check(step.kind ~= "craft" or not step.pattern, "trainer only: " .. (step.recipe and step.recipe.name or ""))
    end
    TALODDB.profPlanPatterns = true

    -- Known recipes from the profession window (TradeSkill API).
    function GetTradeSkillLine() return "Tailoring", 1, 75 end
    function GetNumTradeSkills() return 2 end
    function GetTradeSkillInfo(i)
        if i == 1 then return "Cloth", "header" end
        return "Bolt of Linen Cloth", "optimal"
    end
    MOCK.FireEvent("TRADE_SKILL_SHOW")
    local known = P.Known(ns.Gear.CharKey(), "Tailoring")
    check(known and known["Bolt of Linen Cloth"] and not known["Cloth"], "known recipes read, headers skipped")

    -- Click a step: one DoTradeSkill with the count, capped by the materials.
    local crafted
    function DoTradeSkill(i, n) crafted = { i, n } end
    function GetTradeSkillInfo(i)
        if i == 1 then return "Cloth", "header" end
        return "Bolt of Linen Cloth", "optimal", 5
    end
    local boltRecipe
    for _, r in ipairs(P.Recipes("Tailoring")) do if r.name == "Bolt of Linen Cloth" then boltRecipe = r end end
    local ok, msg = P.Craft(boltRecipe, 30)
    check(ok and crafted and crafted[1] == 2 and crafted[2] == 5 and msg:find("materials for 5 of 30"), "craft capped: " .. tostring(msg))
    ok, msg = P.Craft(P.DATA.recipes[3275], 10)
    check(not ok and msg:find("open your First Aid window"), "other profession: " .. msg)
    function GetTradeSkillInfo(i)
        if i == 1 then return "Cloth", "header" end
        return "Bolt of Linen Cloth", "optimal", 0
    end
    ok, msg = P.Craft(boltRecipe, 30)
    check(not ok and msg:find("lack the materials"), "no materials: " .. msg)
    MOCK.units.player.combat = true
    check(not P.Craft(boltRecipe, 1), "not in combat")
    MOCK.units.player.combat = false

    -- Gathering profession and the target clamp.
    check(P.Plan("Herbalism", 1, 75).error, "herbalism is gathering")
    check(P.Plan("Mining", 1, 150).note, "mining: smelting plan with a gathering note")
    for _, step in ipairs(P.Plan("Alchemy", 1, 300, { patterns = true }).steps) do
        check(not (step.recipe and step.recipe.cooldown), "no cooldown recipe: " .. (step.recipe and step.recipe.name or ""))
    end
    for _, step in ipairs(P.Plan("Tailoring", 1, 300, { patterns = true }).steps) do
        check(not (step.recipe and step.recipe.name == "Mooncloth"), "no Mooncloth")
    end
    check(P.Plan("First Aid", 290, 400).to == 300, "target clamped to 300")

    -- Slash and the tab.
    slash("plan first aid 60")
    check(TALODDB.profPlanProf == "First Aid" and TALODDB.profPlanTargets["First Aid"] == 60, "slash sets profession and target")
    check(printed("First Aid 1 %-> 60"), "slash prints a summary")
    check(ns.GearUI.IsShown() and ns.GearUI.state.view == "professions", "professions tab")
    local v = ns.GearUI.views.professions
    check(v.plan and v.plan.prof == "First Aid" and v.target.label:GetText() == "to 60", "tab shows the plan")
    v.profButton:Fire("OnClick", "LeftButton")
    check(TALODDB.profPlanProf ~= "First Aid", "profession cycles")
    v.plus:Fire("OnClick", "LeftButton")
    v.patterns:Fire("OnClick", "LeftButton")
    check(TALODDB.profPlanPatterns == false, "patterns toggle")
    v.fromPlus:Fire("OnClick", "LeftButton")
    check(v.plan.from == 6 and v.plan.source == "set", "start + 5")
    v.from:Fire("OnClick", "LeftButton")
    check(v.plan.from == 1, "start back to your rank")
    v.steps:Fire("OnSizeChanged")
    slash("plan nonsense")
    check(printed("unknown profession"), "unknown profession")
end

-- Auction prices: logged from the legacy list and from C_AuctionHouse
-- (browse, commodity, item results), lowest per unit per look, history
-- kept; Auctionator as a fallback; the planner prefers them to Wowhead's
-- average (vendor prices still win).
scenarios.auction_prices = function()
    local ns = boot(11509)
    local Pr, P = ns.Prices, ns.Professions
    -- Legacy page: Light Hide 3 x 30c each and 1 x 35c, Light Leather 5 for 100c.
    local page = {
        { "Light Hide", 0, 3, 1, true, 10, "", 50, 1, 90, 0, false, nil, "Bob", nil, 0, 783 },
        { "Light Hide", 0, 1, 1, true, 10, "", 30, 1, 35, 0, false, nil, "Al", nil, 0, 783 },
        { "Light Leather", 0, 5, 1, true, 10, "", 50, 1, 100, 0, false, nil, "Cy", nil, 0, 2318 },
        { "Bid only", 0, 1, 1, true, 10, "", 50, 1, 0, 0, false, nil, "Di", nil, 0, 2589 },
    }
    function GetNumAuctionItems() return #page end
    function GetAuctionItemInfo(_, i) return unpack(page[i], 1, 17) end
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    local price, t, src = Pr.Get(783)
    check(price == 30 and src == "seen" and t, "lowest per unit: " .. tostring(price))
    check(Pr.Get(2318) == 20 and not Pr.Get(2589), "per unit; bid-only ignored")
    check(Pr.Entry(783).n == 4, "units listed")
    -- Next page of the same look, higher: the lowest stays.
    page = { { "Light Hide", 0, 1, 1, true, 10, "", 50, 1, 50, 0, false, nil, "Ed", nil, 0, 783 } }
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    check(Pr.Get(783) == 30, "same look keeps the lowest")
    -- A later look: the new price, the old one in the history.
    Pr.Record(783, 44, 2, time() + 3600)
    local e = Pr.Entry(783)
    check(e.p == 44 and e.h and ns.Prices.Looks(e)[1].p == 30, "new look replaces, history kept")

    -- Planner and texts.
    local unit, how = P.ItemPrice(783)
    check(unit == 44 and how == "seen", "planner uses the seen price")
    check(P.ItemPrice(4289) == 50, "vendor price still wins (Salt)")
    check(P.PriceText(783):find("AH 44c"), "price text: " .. P.PriceText(783))
    check(P.PriceText(2589):find("Wowhead average"), "not seen: Wowhead average")

    -- C_AuctionHouse: browse, commodity, item results.
    C_AuctionHouse = {
        GetBrowseResults = function() return { { itemKey = { itemID = 2589 }, minPrice = 12, totalQuantity = 200 } } end,
        GetNumCommoditySearchResults = function() return 2 end,
        GetCommoditySearchResultInfo = function(_, i) return ({ { unitPrice = 70, quantity = 5 }, { unitPrice = 60, quantity = 9 } })[i] end,
        GetNumItemSearchResults = function() return 1 end,
        GetItemSearchResultInfo = function() return { buyoutAmount = 500, quantity = 20 } end,
    }
    MOCK.FireEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    check(Pr.Get(2589) == 12, "browse")
    MOCK.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 2592)
    check(Pr.Get(2592) == 60 and Pr.Entry(2592).n == 14, "commodity lowest unit price")
    MOCK.FireEvent("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 4306 })
    check(Pr.Get(4306) == 25, "item results per unit")

    -- Auctionator: used when we have not seen it, or when it is newer.
    Auctionator = { API = { v1 = {
        GetAuctionPriceByItemID = function(_, id) return id == 4338 and 90 or (id == 783 and 41 or nil) end,
        GetAuctionAgeByItemID = function(_, id) return id == 783 and 0 or 2 end,
    } } }
    local ap, _, asrc = Pr.Get(4338)
    check(ap == 90 and asrc == "auctionator", "Auctionator fallback")
    check(Pr.Get(783) == 44, "own sighting newer than Auctionator's: ours")
    -- Auctionator keeps days only: "today" is some time today, never "1 min ago",
    -- and it does not beat your own look from earlier today.
    local _, at = Pr.Get(4338)
    check(Pr.Age(at, "auctionator") == "2 days ago", "Auctionator age by day: " .. Pr.Age(at, "auctionator"))
    TALODDB.prices[Pr.RealmKey()][783].t = time() - 1800
    local p783, t783, src783 = Pr.Get(783)
    check(p783 == 44 and src783 == "seen" and Pr.Age(t783) == "30 min ago", "your look from 30 min ago beats Auctionator's today: "
        .. tostring(src783) .. " " .. Pr.Age(t783))
    local own = TALODDB.prices[Pr.RealmKey()][783]
    TALODDB.prices[Pr.RealmKey()][783] = nil
    local _, tA, srcA = Pr.Get(783)
    check(srcA == "auctionator" and Pr.Age(tA, srcA) == "today" and Pr.Age(tA) ~= "1 min ago", "Auctionator today: " .. Pr.Age(tA, srcA))
    TALODDB.prices[Pr.RealmKey()][783] = own
    Auctionator = nil

    -- Off: nothing logged.
    TALODDB.auctionPrices = false
    MOCK.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 2996)
    check(not Pr.Get(2996), "logging off")
    TALODDB.auctionPrices = true

    slash("price light hide")
    check(printed("Light Hide: 44c each"), "slash lookup")
    check(ns.MarketUI.IsShown() and ns.MarketUI.state.search == "light hide", "market opened on the search")
end

-- Market: statistics of an item's looks (usual price, trend, supply),
-- deals, what to sell where, crafting profit, your own sales, the window.
scenarios.market = function()
    MOCK.skillLines = { { "Professions", true, true }, { "Tailoring", false, nil, 60, 0, 0, 75 } }
    -- Bags: 2 Linen Cloth, 1 soulbound ring.
    MOCK.bags[0][1] = MOCK.ItemLink(2589, "Linen Cloth")
    MOCK.bags[0][2] = MOCK.ItemLink(2589, "Linen Cloth")
    MOCK.bags[0][3] = MOCK.ItemLink(9001, "Bound Ring")
    function GetItemInfo(id)
        if id == 2589 then return "Linen Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132889, 13, 7, 5, 0 end
        if id == 9001 then return "Bound Ring", nil, 2, 20, 15, "Armor", "Misc", 1, "INVTYPE_FINGER", 133345, 250, 4, 0, 1 end
        if id == 2996 then return "Bolt of Linen Cloth", nil, 1, 5, 0, "Trade Goods", "Cloth", 20, "", 132890, 40, 7, 5, 0 end
    end
    local ns = boot(11509)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    local M, Pr = ns.Market, ns.Prices
    local now = time()
    -- Linen Cloth: usually ~100c with ~200 units; now 50c with 400 units.
    Pr.Record(2589, 100, 200, now - 3 * 86400, 10, "Linen Cloth")
    Pr.Record(2589, 110, 180, now - 2 * 86400, 9)
    Pr.Record(2589, 90, 220, now - 86400, 11)
    Pr.Record(2589, 50, 400, now, 20)
    local st = M.Stats(2589)
    check(st.looks == 4 and st.usual == 95 and st.low == 50 and st.high == 110 and st.a == 20 and st.over == 0, "stats")
    check(st.trend < -0.4 and st.supplyTrend > 0.5, "under usual, more supply: " .. st.trend .. " " .. tostring(st.supplyTrend))
    check(Pr.Entry(2589).name == "Linen Cloth" and Pr.Looks(Pr.Entry(2589))[1].a == 10, "name and auctions kept in history")

    local deals = M.Deals()
    -- Usual = the earlier looks (100, 110, 90): today's 50c does not pull it down.
    check(#deals == 1 and deals[1].id == 2589 and deals[1].usual == 100 and deals[1].gain == M.Net(100) - 50,
        "deal: " .. #deals .. " " .. tostring(deals[1] and deals[1].gain))

    -- Sell: linen on the AH (net 47c > vendor 13c), the bound ring to a vendor.
    local sell = M.SellList()
    local byId = {}
    for _, e in ipairs(sell) do byId[e.id] = e end
    check(byId[2589] and byId[2589].n == 2 and byId[2589].verdict == "ah" and byId[2589].net == 47, "linen: AH")
    check(byId[9001] and byId[9001].verdict == "vendor" and byId[9001].bound, "bound ring: vendor")

    -- Crafting: Bolt of Linen Cloth (2 linen at 50c) sells for 300c.
    Pr.Record(2996, 300, 50, now, 5, "Bolt of Linen Cloth")
    local list = M.CraftList(ns.Gear.CharKey(), "all")
    local bolt
    for _, pr in ipairs(list) do if pr.r.creates == 2996 then bolt = pr end end
    check(bolt and bolt.priced and bolt.cost == 100 and bolt.value == 285 and bolt.profit == 185, "bolt profit: "
        .. tostring(bolt and bolt.profit))
    check(list[1].priced, "priced recipes first")

    -- The planner with AH data: sell value, supply, resale lowers a recipe's cost.
    local P = ns.Professions
    local value, how = P.SellValue(2996)
    check(value == 285 and how == "ah", "sell value after the cut")
    check(P.SellValue(987654321) == 0, "no price, no value")
    local listed, auctions = P.Supply(2589)
    check(listed == 400 and auctions == 20, "supply at the last look")
    -- A recipe whose product sells for a fortune is chosen with resale on.
    local rich
    for _, r in ipairs(P.Recipes("Tailoring")) do
        if not rich and r.creates and r.skill <= 60 and P.Chance(r, 60) > 0 and not P.IsPattern(r) and r.creates ~= 2996 then rich = r end
    end
    Pr.Record(rich.creates, 1000000, 3, now, 1, rich.name)
    local function Uses(plan)
        for _, step in ipairs(plan.steps) do if step.recipe == rich then return true end end
        return false
    end
    TALODDB.profPlanResale = true
    local plan = P.PlanFor(nil, "Tailoring", 75)
    check(Uses(plan), "resale on: " .. rich.name .. " chosen")
    check(#plan.products > 0 and plan.resale > 0 and plan.net == plan.total - plan.resale, "products and net cost")
    TALODDB.profPlanResale = false
    check(P.PlanFor(nil, "Tailoring", 75).resale >= 0, "resale off still lists the products")
    TALODDB.profPlanResale = true
    slash("plan tailoring 75")
    local pv = ns.GearUI.views.professions
    check(pv.left.sub:GetText():find("sell the products"), "summary with resale: " .. pv.left.sub:GetText())
    pv.resale:Fire("OnClick", "LeftButton")
    check(TALODDB.profPlanResale == false, "resale toggle")

    -- Your sales, from Economy's auction log.
    TALODDB.economy = { ["Tester"] = { auctions = {
        { name = "|cffffffff|Hitem:2589::::::::|h[Linen Cloth]|h|r", count = 20, stacks = 1, status = "sold", received = 1900, t = now, ended = now },
        -- Two stacks posted at once: one listing per auction (Economy splits them).
        { name = "Linen Cloth", count = 20, status = "listed", t = now },
        { name = "Linen Cloth", count = 20, status = "listed", t = now },
    } } }
    local sales = M.MySales(2589)
    check(sales.sold == 1 and sales.units == 20 and sales.perUnit == 95 and sales.listed == 40, "my sales")

    -- What does not sell: the sell rate lowers the value everywhere (one rule).
    ns.Prices.Record(4306, 400, 30, now, 5, "Silk Cloth")
    local silk = "|cffffffff|Hitem:4306::::::::|h[Silk Cloth]|h|r"
    local full = M.SaleValue(4306)
    check(full == M.Net(400), "no history: AH after the cut, got " .. tostring(full))
    local list = TALODDB.economy.Tester.auctions
    list[#list + 1] = { name = silk, count = 20, status = "expired", deposit = 60, t = now, ended = now }
    list[#list + 1] = { name = silk, count = 20, status = "cancelled", deposit = 60, t = now, ended = now }
    list[#list + 1] = { name = silk, count = 20, status = "expired", deposit = 60, t = now, ended = now }
    list[#list + 1] = { name = silk, count = 20, status = "sold", received = 7600, t = now, ended = now }
    local ss = M.MySales(4306)
    check(ss.failed == 3 and ss.ended == 4 and ss.rate == 0.25 and ss.hard and ss.depositLost == 180, "sell rate: "
        .. tostring(ss.rate) .. " failed " .. ss.failed)
    local value, how, info = M.SaleValue(4306)
    -- 380c after the cut x 25% sold = 95c, under Silk Cloth's vendor price: the vendor wins.
    check(info.expected == math.floor(M.Net(400) * 0.25) and info.hard, "AH value x sell rate: " .. tostring(info.expected))
    check(info.vendor > info.expected and how == "vendor" and value == info.vendor, "hard to sell: vendor wins, got " .. tostring(how))
    check(P.SellValue(4306) == value, "planner uses the same rule")
    check(M.SellRateText(ss):find("sold 1 of 4"), "rate text")
    local through = M.SellThroughList()
    check(through[1].id == 4306 and through[1].sales.hard, "worst seller first")
    ns.MarketUI.Show("sellthrough")
    local stv = ns.MarketUI.views.sellthrough
    check(stv.list.items[1].header and stv.list.items[1].text:find("Hard to sell"), "sell-through tab groups")
    check(stv.card.sub:GetText():find("3 unsold"), "sell-through totals: " .. stv.card.sub:GetText())
    stv.list.items[2].tooltip(stv)
    -- An item that keeps failing falls to the vendor by itself.
    for _ = 1, 6 do list[#list + 1] = { name = silk, count = 20, status = "expired", t = now, ended = now } end
    MOCK.items[4306] = nil
    local _, how2, info2 = M.SaleValue(4306)
    check(info2.rate == 0.1, "rate after more failures: " .. tostring(info2.rate))

    -- Old results count less: failures 60 days ago, two recent sales.
    local wool = "|cffffffff|Hitem:2592::::::::|h[Wool Cloth]|h|r"
    for _ = 1, 4 do list[#list + 1] = { name = wool, count = 20, status = "expired", t = now - 60 * 86400, ended = now - 60 * 86400 } end
    list[#list + 1] = { name = wool, count = 20, status = "sold", received = 2000, t = now - 86400, ended = now - 86400 }
    list[#list + 1] = { name = wool, count = 20, status = "sold", received = 2000, t = now, ended = now }
    local ws = M.MySales(2592)
    check(ws.rawRate < 0.34 and ws.rate > 0.85 and not ws.hard and ws.recentSold == 2 and ws.recentEnded == 2,
        "recent sales outweigh old failures: raw " .. tostring(ws.rawRate) .. " weighted " .. tostring(ws.rate))
    -- Tooltip: likelihood to sell with how fresh the evidence is.
    local tip = {}
    local add = GameTooltip.AddDoubleLine
    GameTooltip.AddDoubleLine = function(_, l, r) tip[#tip + 1] = tostring(l) .. " | " .. tostring(r) end
    TALODDB.tooltipPrices = true
    ns.Tooltip.ItemLines(GameTooltip, 4306)
    local text = table.concat(tip, " || ")
    check(text:find("Sells | slow  10%%") and text:find("you sold 1 of 10") and text:find("last sold"),
        "tooltip sell chance: " .. text)
    tip = {}
    ns.Tooltip.ItemLines(GameTooltip, 2592)
    text = table.concat(tip, " || ")
    check(text:find("moves fast  90%%") and text:find("last 30 days: 2 of 2") and text:find("last sold today"), "tooltip recent: " .. text)
    GameTooltip.AddDoubleLine = add
    TALODMarketWindow:Hide()
    ns.MarketUI.state.view = "prices"

    -- The window.
    slash("price")
    check(ns.MarketUI.IsShown(), "market window")
    local ui = ns.MarketUI
    local v = ui.views.prices
    check(ui.state.selected, "an item selected")
    v.search:SetText("bolt")
    v.search:Fire("OnTextChanged")
    check(ui.state.search == "bolt" and ui.state.selected, "search")
    check(v.sort == nil, "no sort button: the column titles sort")
    for _, key in ipairs({ "sell", "crafting", "deals", "sellthrough" }) do
        ui.Show(key)
        check(ui.state.view == key, key .. " tab")
    end
    ui.views.crafting.mode:Fire("OnClick", "LeftButton")
    check(ui.state.craftMode == "known", "crafting mode")
    ui.Show("prices")
end

-- Auction House helper: the panel at the AH, the search list (one query
-- per click, result or "none listed"), the full scan on both engines (read
-- in chunks, other frames muted and restored, 15 min cooldown), AH prices
-- before vendor prices, tooltip lines.
scenarios.ah_helper = function()
    MOCK.skillLines = { { "Professions", true, true }, { "Tailoring", false, nil, 1, 0, 0, 75 } }
    MOCK.bags[0][1] = MOCK.ItemLink(2589, "Linen Cloth")
    local ns = boot(11509)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    local H, Pr = ns.AHHelper, ns.Prices
    -- Legacy auction house.
    local queries, page = {}, {}
    function CanSendAuctionQuery() return true, true end
    function QueryAuctionItems(...) queries[#queries + 1] = { ... } end
    function GetNumAuctionItems() return #page, #page end
    function GetAuctionItemInfo(_, i) return unpack(page[i], 1, 17) end
    function GetFramesRegisteredForEvent(event)
        local out = {}
        for frame, events in pairs(MOCK.events) do if events[event] then out[#out + 1] = frame end end
        return unpack(out)
    end
    local blizzard = CreateFrame("Frame", "AuctionFrame", UIParent)
    blizzard:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")

    MOCK.FireEvent("AUCTION_HOUSE_SHOW")
    MOCK.RunTimers()
    local panel = H.Panel()
    check(panel and panel:IsShown(), "panel at the auction house")
    check(TALODAHNextButton, "named for /click")
    check(#H.state.queue > 0, "search list built: " .. #H.state.queue)
    local first = H.state.queue[1]

    -- Click: one exact search; the result is logged and the list moves on.
    TALODAHNextButton:Fire("OnClick", "LeftButton")
    check(#queries == 1 and queries[1][1] == first.name and queries[1][8] == true and queries[1][7] == false, "exact search for " .. first.name)
    TALODAHNextButton:Fire("OnClick", "LeftButton")
    check(#queries == 1, "no second search while waiting")
    page = { { first.name, 0, 5, 1, true, 1, "", 10, 1, 150, 0, false, nil, "Al", nil, 0, first.id } }
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    MOCK.Tick(0.3)
    check(H.state.index == 2 and H.state.results[first.id].p == 30, "result logged, next item")
    -- Nothing listed: after the timeout the list moves on.
    if H.state.queue[2] then
        page = {}
        TALODAHNextButton:Fire("OnClick", "LeftButton")
        MOCK.Tick(6)
        MOCK.Tick(0.3)
        check(H.state.index == 3 and H.state.results[H.state.queue[2].id].none, "none listed")
    end
    H.Skip()

    -- Full scan (legacy): getAll, the Blizzard frame muted, then restored.
    page = {
        { "Salt", 0, 20, 1, true, 1, "", 10, 1, 400, 0, false, nil, "A", nil, 0, 4289 },
        { "Salt", 0, 10, 1, true, 1, "", 10, 1, 300, 0, false, nil, "B", nil, 0, 4289 },
        { "Light Hide", 0, 1, 1, true, 1, "", 10, 1, 0, 0, false, nil, "C", nil, 0, 783 },
    }
    local ok = H.FullScan()
    check(ok and queries[#queries][7] == true and not MOCK.events[blizzard]["AUCTION_ITEM_LIST_UPDATE"], "getAll sent, Blizzard muted")
    MOCK.FireEvent("AUCTION_ITEM_LIST_UPDATE")
    MOCK.RunTimers() MOCK.RunTimers()
    local salt = Pr.Entry(4289)
    check(salt and salt.p == 20 and salt.a == 2 and salt.n == 30, "full scan: lowest and whole supply")
    check(not Pr.Get(783), "bid-only: no price")
    check(MOCK.events[blizzard]["AUCTION_ITEM_LIST_UPDATE"] and not H.state.scan, "Blizzard restored")
    check(not H.FullScan(), "15 minute cooldown")

    -- Salt seen on the AH for 20c: cheaper than the vendor's 50c, so the planner uses it.
    local unit, how = ns.Professions.ItemPrice(4289)
    check(unit == 20 and how == "seen", "AH before vendor when cheaper")
    Pr.Record(4289, 80, 5, time() + 7200, 1)
    check(ns.Professions.ItemPrice(4289) == 50, "vendor when it is cheaper")

    -- Tooltip lines.
    local lines = {}
    local tip = { AddDoubleLine = function(_, l, r) lines[#lines + 1] = l .. " " .. r end, AddLine = function() end, Show = function() end }
    ns.Tooltip.ItemLines(tip, 4289)
    check(lines[1] and lines[1]:find("80c each"), "tooltip: " .. tostring(lines[1]))
    check(ns.Market.PostPrice(4289) == 79, "post 1c under")

    -- Newer engine: SendSearchQuery and ReplicateItems.
    local sent, replicated = nil, false
    C_AuctionHouse = {
        MakeItemKey = function(id) return { itemID = id } end,
        SendSearchQuery = function(key) sent = key end,
        ReplicateItems = function() replicated = true end,
        GetNumReplicateItems = function() return 2 end,
        GetReplicateItemInfo = function(i)
            local rows = { [0] = { "Wool Cloth", nil, 20, 1, true, 1, "", 1, 1, 600, 0, false, nil, "x", nil, 0, 2592 },
                [1] = { "Wool Cloth", nil, 10, 1, true, 1, "", 1, 1, 200, 0, false, nil, "y", nil, 0, 2592 } }
            return unpack(rows[i], 1, 17)
        end,
    }
    H.state.waiting = nil
    check(H.Search({ id = 2592, name = "Wool Cloth" }) and sent and sent.itemID == 2592, "SendSearchQuery by item key")
    H.state.waiting = nil
    TALODDB.ahFullScan = {}
    check(H.FullScan() and replicated, "ReplicateItems")
    MOCK.FireEvent("REPLICATE_ITEM_LIST_UPDATE")
    MOCK.RunTimers() MOCK.RunTimers()
    local wool = Pr.Entry(2592)
    check(wool and wool.p == 20 and wool.a == 2 and wool.n == 30, "replicate: from index 0, lowest and supply")
    C_AuctionHouse = nil

    MOCK.FireEvent("AUCTION_HOUSE_CLOSED")
    check(not panel:IsShown(), "closed with the auction house")
    slash("ah scan")
    check(panel:IsShown(), "/talod ah scan")
end

-- Minimap button: built on the minimap, placed on its edge, dragged along
-- it, clicks open the windows, the setting hides it; a collector's
-- reparenting is left alone.
scenarios.minimap_button = function()
    Minimap = CreateFrame("Frame", "Minimap", UIParent)
    Minimap:SetSize(140, 140)
    Minimap._cx, Minimap._cy = 1000, 700
    Minimap.GetEffectiveScale = function() return 1 end
    local ns = boot(11509)
    local b = TALODMinimapButton
    check(b and b:GetParent() == Minimap and b:IsShown(), "button on the minimap")
    local _, _, _, x, y = b:GetPoint(1)
    local r = math.sqrt(x * x + y * y)
    check(math.abs(r - 75) < 0.01, "on the edge: " .. r)

    -- Drag to the right of the minimap: angle 0.
    MOCK.cursorX, MOCK.cursorY = 1200, 700
    b:Fire("OnDragStart")
    b:Fire("OnUpdate", 0.1)
    b:Fire("OnDragStop")
    _, _, _, x, y = b:GetPoint(1)
    check(math.abs(TALODDB.minimapAngle) < 0.01 and math.abs(x - 75) < 0.01 and math.abs(y) < 0.01, "dragged to the right")
    -- Square minimap: the corner sits on the square's corner.
    GetMinimapShape = function() return "SQUARE" end
    TALODDB.minimapAngle = 45
    ns.MinimapButton.Place()
    _, _, _, x, y = b:GetPoint(1)
    check(math.abs(x - 75) < 0.01 and math.abs(y - 75) < 0.01, "square corner")
    GetMinimapShape = nil

    b:Fire("OnClick", "LeftButton")
    check(ns.Nav.MenuShown(), "left-click: main menu")
    b:Fire("OnClick", "LeftButton")
    check(not ns.Nav.MenuShown(), "left-click again closes it")
    b:Fire("OnClick", "RightButton")
    MOCK.ctrl = true
    function IsControlKeyDown() return MOCK.ctrl end
    local shown = TALODDB.panelShown
    b:Fire("OnClick", "LeftButton")
    check(TALODDB.panelShown ~= shown, "ctrl-click: panel toggled")
    MOCK.ctrl = false
    b:Fire("OnEnter")

    slash("minimap")
    check(not b:IsShown() and TALODDB.minimapButton == false, "/talod minimap hides it")
    slash("minimap")
    check(b:IsShown(), "and shows it again")

    -- Taken by a minimap collector: not moved back.
    local bar = CreateFrame("Frame", "SomeButtonBar", UIParent)
    b:SetParent(bar)
    b:ClearAllPoints()
    TALODDB.minimapAngle = 90
    ns.MinimapButton.Place()
    check(b:GetPoint(1) == "CENTER" and select(4, b:GetPoint(1)) == 0, "collector's place kept")
end

-- Crafting log: every successful recipe cast, merged per recipe, skill
-- points credited, other units and other spells ignored; the tab.
scenarios.crafting_log = function()
    MOCK.skillLines = { { "Professions", true, true }, { "Leatherworking", false, nil, 12, 0, 0, 75 } }
    local ns = boot(11509)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    local P = ns.Professions
    local function cast(id, unit) MOCK.FireEvent("UNIT_SPELLCAST_SUCCEEDED", unit or "player", "Cast-1", id) end
    local function skill(n) MOCK.skillLines[2][4] = n MOCK.FireEvent("SKILL_LINES_CHANGED") MOCK.Tick(0.6) end

    cast(2152) skill(13)      -- Light Armor Kit, +1
    cast(2152) skill(14)
    cast(2152)                -- no skill-up
    cast(2152, "party1")      -- not you
    cast(133)                 -- not a recipe (Fireball)
    local log = P.Crafts(ns.Gear.CharKey())
    check(#log == 1 and log[1].n == 3 and log[1].from == 12 and log[1].to == 14, "merged batch with skill: "
        .. #log .. " " .. tostring(log[1] and log[1].n))
    cast(2153) skill(15)      -- Handstitched Leather Pants: a new entry
    check(#log == 2 and log[2].id == 2153 and log[2].from == 14 and log[2].to == 15, "new recipe, new entry")
    check(P.ReagentCost(P.DATA.recipes[2152]) > 0, "materials priced")

    TALODDB.craftLogEnabled = false
    cast(2152)
    check(#log == 2, "log off")
    TALODDB.craftLogEnabled = true

    slash("crafts")
    check(ns.GearUI.IsShown() and ns.GearUI.state.view == "crafting", "crafting tab")
    local v = ns.GearUI.views.crafting
    check(v.left.sub:GetText():find("4 crafts") and v.left.sub:GetText():find("+3 skill"), "totals: " .. v.left.sub:GetText())
    v.range:Fire("OnClick", "LeftButton")
    v.range:Fire("OnClick", "LeftButton")
    check(v.range.label:GetText():find("Today"), "range cycles")
    cast(2152)
    check(log[#log].n == 1 and #log == 3, "new batch after another recipe")
end

-- Newer engine with C_SkillInfo: the full skill list as tables, with or
-- without header lines.
scenarios.skills_c_skillinfo = function()
    GetNumSkillLines, GetSkillLineInfo = nil, nil
    local lines = {
        { name = "Swords", rank = 112, maxRank = 125 },
        { name = "Defense", rank = 120, maxRank = 125, skillModifier = 4 },
        { name = "Tailoring", rank = 140, maxRank = 150 },
        { name = "First Aid", rank = 80, maxRank = 150 },
        { name = "Plate Mail", rank = 1, maxRank = 1 },
    }
    C_SkillInfo = { GetNumSkillLines = function() return #lines end, GetSkillLineInfo = function(i) return lines[i] end }
    local ns = boot(16001, { playerLevel = 25 })
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    local c = ns.Skills.Char()
    check(ns.Skills.Source() == "C_SkillInfo", "source: " .. ns.Skills.Source())
    check(c.current.Swords and c.current.Swords.cat == "Weapon Skills" and c.current.Swords.rank == 112, "weapon skill")
    check(c.current.Defense and c.current.Defense.mod == 4 and c.current.Defense.cat == "Weapon Skills", "defense")
    check(c.current.Tailoring.cat == "Professions" and c.current["First Aid"].cat == "Secondary Skills", "categories by name")
    check(not c.current["Plate Mail"], "proficiency without ranks skipped")
    lines[1].rank = 114
    MOCK.FireEvent("SKILL_LINES_CHANGED")
    MOCK.Tick(0.6)
    check(c.log[#c.log].kind == "up" and c.log[#c.log].name == "Swords" and c.log[#c.log].to == 114, "weapon skill-up logged")
    check(ns.Professions.PlanFor(nil, "Tailoring").from == 140, "planner uses the C_SkillInfo rank")

    -- With header lines: the header names the category; a collapsed one keeps its skills.
    lines = {
        { name = "Weapon Skills", isHeader = true, isExpanded = true },
        { name = "Swords", rank = 115, maxRank = 125 },
        { name = "Professions", isHeader = true, isExpanded = false },
    }
    MOCK.FireEvent("SKILL_LINES_CHANGED")
    MOCK.Tick(0.6)
    check(c.current.Swords.rank == 115 and c.current.Tailoring, "collapsed Professions kept")
    slash("skills")
    slash("probe")
end

-- Newer engine (Forever): no skill lines. Professions from GetProfessions,
-- a secondary skill it leaves out from the C_TradeSkillUI window, which
-- also gives the known recipes by spell ID; the planner uses them.
scenarios.skills_forever_professions = function()
    GetNumSkillLines, GetSkillLineInfo = nil, nil
    local profs = { [3] = { "Tailoring", 136249, 60, 75, 0, 0, 197, 0 }, [7] = { "Cooking", 133971, 12, 75, 0, 0, 185, 0 } }
    function GetProfessions() return 3, nil, nil, nil, 7 end
    function GetProfessionInfo(i) local p = profs[i]; if p then return unpack(p, 1, 8) end end
    -- Combat skills from the character stats: a sword in the main hand.
    local defense, sword = 95, 88
    function UnitDefense() return defense, 5 end
    function UnitAttackBothHands() return sword, 0, 0, 0 end
    function UnitRangedAttack() return 0, 0 end
    function GetInventoryItemID(_, slot) return slot == 16 and 5001 or nil end
    local instant = C_Item.GetItemInfoInstant
    C_Item.GetItemInfoInstant = function(id)
        if id == 5001 then return 5001, "Weapon", "One-Handed Swords", "INVTYPE_WEAPON", 135274, 2, 7 end
        return instant(id)
    end
    local ns = boot(16001)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    local c = ns.Skills.Char()
    check(ns.Skills.Available() and not ns.Skills.HasSkillLines(), "professions path")
    check(c.current.Tailoring and c.current.Tailoring.rank == 60 and c.current.Tailoring.cat == "Professions", "tailoring read")
    check(c.current.Cooking and c.current.Cooking.cat == "Secondary Skills", "cooking is secondary")
    check(c.current.Defense and c.current.Defense.rank == 95 and c.current.Defense.max == 100 and c.current.Defense.mod == 5
        and c.current.Defense.cat == "Weapon Skills", "defense from UnitDefense, max 5 per level")
    check(c.current.Swords and c.current.Swords.rank == 88, "main-hand weapon skill named from the item")
    -- Sword unequipped: Swords is kept (not dropped), Unarmed appears.
    GetInventoryItemID = function() return nil end
    MOCK.FireEvent("SKILL_LINES_CHANGED")
    MOCK.Tick(0.6)
    check(c.current.Swords and c.current.Unarmed, "weapon skill kept when not held")
    for _, e in ipairs(c.log) do check(e.kind ~= "dropped", "nothing dropped") end

    profs[3][3] = 63
    MOCK.FireEvent("SKILL_LINES_CHANGED")
    MOCK.Tick(0.6)
    check(c.log[#c.log].kind == "up" and c.log[#c.log].to == 63, "skill-up logged")

    -- First Aid only seen through its window.
    C_TradeSkillUI = {
        GetBaseProfessionInfo = function() return { professionName = "First Aid", skillLevel = 40, maxSkillLevel = 75 } end,
        GetAllRecipeIDs = function() return { 3275, 3276, 7928 } end,
        GetRecipeInfo = function(id) return { name = "x" .. id, learned = id ~= 7928 } end,
    }
    MOCK.FireEvent("TRADE_SKILL_LIST_UPDATE")
    MOCK.Tick(0.6)
    check(c.current["First Aid"] and c.current["First Aid"].rank == 40 and c.current["First Aid"].window, "first aid from the window")
    local known = ns.Professions.Known(ns.Gear.CharKey(), "First Aid")
    check(known and known["Linen Bandage"] and known["Heavy Linen Bandage"] and not known["Silk Bandage"], "known by spell id, learned only")
    -- Window closed (no info): First Aid is kept, not dropped.
    C_TradeSkillUI.GetBaseProfessionInfo = function() return nil end
    MOCK.FireEvent("SKILL_LINES_CHANGED")
    MOCK.Tick(0.6)
    check(c.current["First Aid"], "window skill kept")

    local plan = ns.Professions.PlanFor(nil, "First Aid", 75)
    check(plan.from == 40 and plan.steps[1].known, "plan starts at the window rank with a known recipe")
    -- Craft through C_TradeSkillUI when its window is on First Aid.
    local crafted
    C_TradeSkillUI.GetBaseProfessionInfo = function() return { professionName = "First Aid", skillLevel = 40, maxSkillLevel = 75 } end
    C_TradeSkillUI.GetRecipeInfo = function(id) return { name = "x", learned = true, numAvailable = 12 } end
    C_TradeSkillUI.CraftRecipe = function(id, n) crafted = { id, n } end
    local ok = ns.Professions.Craft(plan.steps[1].recipe, plan.steps[1].crafts)
    check(ok and crafted and crafted[1] == plan.steps[1].recipe.id and crafted[2] == math.min(12, plan.steps[1].crafts), "CraftRecipe")
    C_TradeSkillUI.GetBaseProfessionInfo = function() return nil end
    local tp = ns.Professions.PlanFor(nil, "Tailoring")
    check(tp.from == 63 and tp.source == "rank" and tp.to == 75, "tailoring plan starts at your rank 63, to the rank end")
    check(tp.steps[1].kind == "craft" and tp.steps[1].from == 63, "first step at your rank")
    -- Start set by hand (rank out of date) and back.
    local key = ns.Gear.CharKey()
    ns.Professions.SetStart(key, "Tailoring", 90)
    tp = ns.Professions.PlanFor(nil, "Tailoring")
    check(tp.from == 90 and tp.source == "set" and tp.to == 150, "hand start 90 (past your max 75: trained since)")
    for _, step in ipairs(tp.steps) do check(step.kind ~= "train" or step.at >= 150, "no Journeyman step from 90") end
    ns.Professions.SetStart(key, "Tailoring", 20)
    check(ns.Professions.PlanFor(nil, "Tailoring").from == 63, "hand start below your rank is ignored")
    ns.Professions.SetStart(key, "Tailoring", nil)
    slash("plan tailoring 70-140")
    tp = ns.Professions.PlanFor(nil, "Tailoring")
    check(tp.from == 70 and tp.to == 140, "slash from-to")
    ns.Professions.SetStart(key, "Tailoring", nil)
    slash("skills")
    slash("plan")
    check(ns.GearUI.state.view == "professions", "professions tab")
    slash("probe")
end

-- Economy: money and bag changes recorded with the open window: vendor
-- sale / purchase / repair, loot (merged), quest, trade with a partner.
scenarios.economy_tracking = function()
    MOCK.items[4001] = { equipLoc = "", stats = {} }
    MOCK.items[4002] = { equipLoc = "", stats = {} }
    local junk, potion = MOCK.ItemLink(4001, "Junk"), "|cff1eff00|Hitem:4002::::::::20:::::|h[Green Thing]|h|r"
    MOCK.bags[0][1] = junk
    MOCK.money = 10000
    local ns = boot(11509)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(2.2) MOCK.Tick(0.3)
    local c = ns.Economy.Char()
    local function changed() MOCK.FireEvent("PLAYER_MONEY") MOCK.FireEvent("BAG_UPDATE_DELAYED") MOCK.Tick(0.5) end

    -- Vendor: sell the junk (+25c), buy something (-100c, item in), repair (-500c, nothing moves).
    MOCK.units.npc = { exists = true, name = "Innkeeper Farley" }
    MOCK.FireEvent("MERCHANT_SHOW")
    MOCK.bags[0][1] = nil
    MOCK.money = MOCK.money + 25
    changed()
    local e = c.log[#c.log]
    check(e and e.kind == "vendor" and e.amount == 25 and e.lost and e.detail == "Innkeeper Farley", "vendor sale")
    MOCK.bags[0][2] = potion
    MOCK.money = MOCK.money - 100
    changed()
    check(c.log[#c.log].kind == "vendor" and c.log[#c.log].amount == -100 and c.log[#c.log].gained, "vendor purchase")
    MOCK.money = MOCK.money - 500
    changed()
    check(c.log[#c.log].kind == "repair" and c.log[#c.log].amount == -500, "repair")
    MOCK.FireEvent("MERCHANT_CLOSED")
    MOCK.Tick(4)

    -- Equipping (item-only, no window): not economy.
    local n = #c.log
    MOCK.bags[0][2] = nil
    changed()
    check(#c.log == n, "item-only change outside a window ignored")

    -- Loot twice in one zone: one entry.
    MOCK.FireEvent("LOOT_OPENED") MOCK.money = MOCK.money + 30 changed() MOCK.FireEvent("LOOT_CLOSED") MOCK.Tick(4)
    MOCK.FireEvent("LOOT_OPENED") MOCK.money = MOCK.money + 12 changed() MOCK.FireEvent("LOOT_CLOSED") MOCK.Tick(4)
    check(c.log[#c.log].kind == "loot" and c.log[#c.log].amount == 42 and c.log[#c.log].count == 2, "loot merged")

    -- Quest reward.
    MOCK.questTitle = "Lost Necklace"
    MOCK.FireEvent("QUEST_COMPLETE") MOCK.money = MOCK.money + 300 changed() MOCK.FireEvent("QUEST_FINISHED") MOCK.Tick(4)
    check(c.log[#c.log].kind == "quest" and c.log[#c.log].detail == "Lost Necklace", "quest reward")

    -- Trade: we give 1g, get an item.
    MOCK.units.NPC = { exists = true, name = "Buddy" }
    local tradeItems = { target = { MOCK.ItemLink(4001, "Junk") } }
    function GetTradePlayerItemLink() return nil end
    function GetTradeTargetItemLink(i) return tradeItems.target[i] end
    function GetTradeTargetItemInfo() return "Junk", 1, 1 end
    function GetTradePlayerItemInfo() return nil end
    function GetPlayerTradeMoney() return 10000 end
    function GetTargetTradeMoney() return 0 end
    MOCK.FireEvent("TRADE_SHOW")
    MOCK.FireEvent("TRADE_ACCEPT_UPDATE", 1, 1)
    MOCK.money = MOCK.money - 10000
    MOCK.bags[0][3] = MOCK.ItemLink(4001, "Junk")
    MOCK.FireEvent("TRADE_CLOSED")
    changed()
    e = c.log[#c.log]
    check(e.kind == "trade" and e.detail == "Buddy" and e.amount == -10000 and e.gaveMoney == 10000 and #e.got == 1, "trade recorded")

    -- Mail: an auction sale letter counts as auction income, named.
    MOCK.inbox[1] = { sender = "Stormwind Auction House", subject = "Auction successful: Copper Bar", money = 2000,
        invoice = "seller", item = "Copper Bar", player = "Bob" }
    MOCK.inbox[2] = { sender = "Buddy", subject = "for you", money = 50 }
    MOCK.FireEvent("MAIL_SHOW")
    TakeInboxMoney(1)
    changed()
    e = c.log[#c.log]
    check(e.kind == "auction" and e.amount == 2000 and e.detail == "Auction sold: Copper Bar to Bob", "auction sale from mail: " .. tostring(e.detail))
    TakeInboxMoney(2)
    changed()
    check(c.log[#c.log].kind == "mail" and c.log[#c.log].detail == "from Buddy: for you", "plain mail named")
    MOCK.FireEvent("MAIL_CLOSED")
    MOCK.Tick(4)

    -- Auction house: a buyout (money only).
    MOCK.FireEvent("AUCTION_HOUSE_SHOW")
    MOCK.money = MOCK.money - 700
    changed()
    check(c.log[#c.log].kind == "auction" and c.log[#c.log].detail == "bid or buyout", "auction buyout")
    MOCK.FireEvent("AUCTION_HOUSE_CLOSED")
    MOCK.Tick(4)

    local inc, exp, by = ns.Economy.Totals(c, nil)
    check(inc == 25 + 42 + 300 + 2000 + 50 and exp == 100 + 500 + 10000 + 700 and by.repair == -500 and by.auction == 1300, "totals")
    local sNet = ns.Economy.Session()
    check(sNet == inc - exp, "session net: " .. tostring(sNet))
    local total, chars = ns.Economy.AllCharacters()
    check(total == MOCK.money and #chars == 1, "all characters")
    check(#ns.Economy.GoldSeries(c, nil) >= 1, "gold series")
    check(ns.Economy.FormatMoney(12345):find("1g") and ns.Economy.FormatMoney(-5, true):find("^%-"), "money text")

    -- Mailbox, then straight to the auctioneer without a "mail closed" event:
    -- posting is an auction (the bug: it was recorded as mail), with details.
    MOCK.FireEvent("MAIL_SHOW")
    MOCK.FireEvent("AUCTION_HOUSE_SHOW")
    MOCK.bags[0][5] = MOCK.ItemLink(2840, "Copper Bar")
    changed()
    MOCK.sellItem = { "Copper Bar", 1 }
    PostAuction(150, 300, 3, 1, 1)
    MOCK.bags[0][5] = nil
    MOCK.money = MOCK.money - 58
    changed()
    e = c.log[#c.log]
    check(e.kind == "auction" and e.sub == "posted" and e.amount == -58, "posting recorded as auction: " .. tostring(e.kind) .. " " .. tostring(e.detail))
    check(e.detail:find("Listed") and e.detail:find("buyout") and e.detail:find("24 h") and e.detail:find("deposit"), "listing details: " .. e.detail)
    local listing = c.auctions[#c.auctions]
    check(listing.status == "listed" and listing.deposit == 58 and listing.buyout == 300 and listing.bid == 150, "listing kept")
    MOCK.FireEvent("AUCTION_HOUSE_CLOSED")
    MOCK.Tick(4)

    -- The sale letter closes the listing with the profit.
    MOCK.inbox[3] = { sender = "Auction House", subject = "Auction successful: Copper Bar", money = 285, invoice = "seller", item = "Copper Bar", player = "Bob" }
    MOCK.FireEvent("MAIL_SHOW")
    TakeInboxMoney(3)
    changed()
    check(listing.status == "sold" and listing.received == 285 and listing.profit == 285 - 58, "listing sold with profit")
    -- A letter from one of your own characters is a transfer, not income.
    TALODDB.economy["Alt-Mockrealm"] = { log = {}, days = {} }
    MOCK.inbox[4] = { sender = "Alt", subject = "gold", money = 5000 }
    TakeInboxMoney(4)
    changed()
    check(c.log[#c.log].kind == "transfer", "mail from your own character is a transfer")

    -- Open All / quick clicks: three letters taken before the first money
    -- comes. Each money change gets its own letter (the bug: the first got
    -- the next letter's name and the last one none).
    MOCK.inbox[5] = { sender = "Auction House", subject = "Auction successful: Wool Cloth", money = 1478, invoice = "seller", item = "Wool Cloth", player = "" }
    MOCK.inbox[6] = { sender = "Auction House", subject = "Auction successful: Linen Cloth", money = 1180, invoice = "seller", item = "Linen Cloth", player = "Bob" }
    MOCK.inbox[7] = { sender = "Buddy", subject = "loan", money = 77 }
    MOCK.mailLater = true
    local before = #c.log
    TakeInboxMoney(5) TakeInboxMoney(6) TakeInboxMoney(7)
    MOCK.mailAnswers = { MOCK.mailAnswers[1] }
    MOCK.AnswerMail() changed()
    MOCK.mailAnswers = { 1180, 77 }
    MOCK.AnswerMail() changed()
    MOCK.mailLater = nil
    local l1, l2, l3 = c.log[before + 1], c.log[before + 2], c.log[before + 3]
    check(#c.log == before + 3, "three letters, three entries: " .. (#c.log - before))
    check(l1 and l1.amount == 1478 and l1.kind == "auction" and l1.detail == "Auction sold: Wool Cloth", "first letter named: " .. tostring(l1 and l1.detail))
    check(l2 and l2.amount == 1180 and l2.detail == "Auction sold: Linen Cloth to Bob", "second letter named, split from one change: " .. tostring(l2 and l2.detail))
    check(l3 and l3.amount == 77 and l3.kind == "mail" and l3.detail == "from Buddy: loan", "third letter named: " .. tostring(l3 and l3.detail))
    MOCK.FireEvent("MAIL_CLOSED")
    MOCK.Tick(4)
    local allInc = ns.Economy.ScopeTotals("all", nil)
    local oneInc = ns.Economy.ScopeTotals(ns.Gear.CharKey(), nil)
    check(oneInc - allInc == 5000, "transfers count for the character, not the account")

    -- The economy window.
    slash("economy")
    check(ns.EconomyUI.IsShown() and not ns.GearUI.IsShown(), "economy has its own window")
    local views = ns.EconomyUI.views
    for _, view in ipairs({ "overview", "transactions", "auctions", "trades" }) do
        ns.EconomyUI.state.view = view
        for _, r in ipairs({ 1, 30, 0, 7 }) do ns.EconomyUI.state.range = r ns.EconomyUI.Refresh() end
    end
    ns.EconomyUI.state.scope = ns.Gear.CharKey()
    ns.EconomyUI.Refresh()
    ns.EconomyUI.state.scope = "all"
    ns.EconomyUI.state.view = "transactions"
    ns.EconomyUI.Refresh()
    local tv = views.transactions
    tv.chips[1]:Fire("OnClick", "RightButton")
    check(ns.EconomyUI.state.hidden.loot and not ns.EconomyUI.state.hidden.vendor, "right-click: only vendor")
    tv.chips[1]:Fire("OnClick", "RightButton")
    check(not ns.EconomyUI.state.hidden.loot, "right-click again: all")
    ns.EconomyUI.state.view = "overview"
    ns.EconomyUI.Refresh()
    local plot = views.overview.plot
    check(plot.series and #plot.series >= 1, "gold chart has points")
    plot._width, plot._height = 400, 300
    ns.EconomyUI.Refresh()
    plot.IsMouseOver = function() return true end
    plot.GetLeft = function() return 0 end
    MOCK.cursorX = 5
    plot:Fire("OnUpdate")
    check(plot.hovering == 1, "chart hover")
    check(views.overview.tiles[4].label:GetText() == "This session", "session tile")
    ns.EconomyUI.state.view = "auctions"
    ns.EconomyUI.Refresh()
    check(views.auctions.card.sub:GetText():find("1 sold"), "auction summary: " .. views.auctions.card.sub:GetText())
end

scenarios.slash_and_options = function()
    local ns = boot(11509)
    plateAdd("nameplate1", MOCK.Enemy({ level = 22 }))
    setTarget(MOCK.Enemy({ level = 22 }))
    for _, cmd in ipairs({ "help", "panel off", "panel on", "panel unlock", "panel lock", "panel reset", "alerts test",
        "alerts off", "alerts on", "badges off", "badges on", "flag off", "flag on", "flag reset", "kos target",
        "who target", "unlist target", "journal", "lists", "distance", "distance max", "probe", "errors", "errors clear",
        "clear", "nonsense" }) do
        slash(cmd)
        MOCK.Tick(0.3)
    end
    check(MOCK.cvars.nameplateMaxDistance == "41", "nameplate distance max")
    check(TALODProbeWindow and TALODProbeWindow:IsShown(), "probe window shown")
    check(type(TALODDB.lastProbe) == "table" and #TALODDB.lastProbe > 10, "probe saved")
    local probeText = table.concat(TALODDB.lastProbe, "\n")
    check(probeText:find("%[1%-2,4%]") and probeText:find("%[3%]") and probeText:find("%[5%]") and probeText:find("%[6%]"),
        "probe covers every Phase 0 item")
    check(probeText:find("target: name=Shadowfang"), "probe reads the target")

    slash("")
    check(ns.Options.IsShown(), "settings window opened")
    check(not SettingsPanel:IsShown(), "the game's panel is not needed")
    -- The entry in the game's Options > AddOns opens the window.
    TALODOptionsWindow:Hide()
    Settings.OpenToCategory(42)
    check(ns.Options.IsShown(), "the game's options entry opens the window")
    for top = 1, 10 do
        for sub = 1, 4 do ns.Options.SelectTab(top, sub) end
    end
    local clicked = 0
    for _, f in ipairs(MOCK.frames) do
        if f._kind == "CheckButton" and f._scripts.OnClick then
            f:SetChecked(not f:GetChecked()); f:Fire("OnClick")
            f:SetChecked(not f:GetChecked()); f:Fire("OnClick")
            clicked = clicked + 1
        elseif f._kind == "Slider" and f._scripts.OnValueChanged then
            f:SetValue(f:GetValue() + 1)
        elseif f._kind == "Button" and f._scripts.OnClick and f._template ~= "SecureActionButtonTemplate" then
            f:Fire("OnClick", "LeftButton")
        end
        MOCK.RunTimers()
        if MOCK.popup then MOCK.AcceptPopup() end
        MOCK.Tick(0.3)
    end
    check(clicked >= 25, "option checkboxes exercised: " .. clicked)
    check(TALODDB.alertLoudClasses ~= nil, "class table intact")

    -- Reset keeps the journal and lists.
    ns.Journal.SetList("Keeper", "kos")
    slash("reset")
    check(ns.ListOf("Keeper") == "kos", "lists kept across reset")
    check(TALODDB.panelRows == 8, "settings back to defaults")
end

scenarios.missing_templates = function()
    MOCK.missingTemplates = { UICheckButtonTemplate = true, UIPanelButtonTemplate = true,
        UIPanelScrollFrameTemplate = true, UIPanelCloseButton = true }
    local ns = boot(11509)
    slash("")
    for top = 1, 10 do
        for sub = 1, 4 do ns.Options.SelectTab(top, sub) end
    end
    slash("probe")
    check(TALODProbeWindow:IsShown(), "probe window without templates")
end

scenarios.savedvariables_upgrade = function()
    local ns = boot(11509, { db = {
        alertsEnabled = false,
        players = { Old = { list = "kos", name = "Old" } },
        errorLog = { { message = "old", version = "0.0.1" } },
    } })
    check(TALODDB.alertsEnabled == false, "user setting kept")
    check(TALODDB.panelShown == true, "new default merged")
    check(ns.ListOf("Old") == "kos", "list kept")
    check(#TALODDB.errorLog == 0, "errors from other versions dropped")
end

scenarios.panel_details = function()
    local ns = boot(11509)
    plateAdd("nameplate1", MOCK.Enemy({ level = 20, health = 1500, healthMax = 2000, power = 800, powerMax = 1000,
        targetsPlayer = true, combat = true, casting = "Frostbolt", rank = 8,
        buffs = { { spellId = 1243, name = "Power Word: Fortitude" }, { spellId = 642, name = "Divine Shield" } },
        debuffs = { { spellId = 118, name = "Polymorph" }, { spellId = 11, name = "Frostbite", count = 3 } } }))
    local r = TALODPanel.rows[1]
    local det = r.detail
    check(det:IsShown(), "detail line shown for a live enemy")
    check(r:GetHeight() == 33, "row is two lines, got " .. tostring(r:GetHeight()))
    check(det.hpText:GetText() == "1500 / 2000", "health in HP: " .. tostring(det.hpText:GetText()))
    check(det.hp:GetValue() == 1500, "health bar value")
    local tags = det.tags:GetText()
    check(tags:find("@you") and tags:find("PvP") and tags:find("cast") and tags:find("cbt"), "tags: " .. tags)
    -- Big cooldown first, then CC, then other debuffs, then other buffs.
    local ids = {}
    for j, icon in ipairs(det.auras) do if icon:IsShown() then ids[#ids + 1] = icon.spellId end end
    check(table.concat(ids, ",") == "642,118,11,1243", "aura order: " .. table.concat(ids, ","))
    check(det.auras[3].count:GetText() == 3, "stack count shown")
    check(ns.Spotter.Get("Shadowfang").rankName == "Rank 4", "honor rank read")
    r:Fire("OnEnter")
    r:Fire("OnLeave")

    -- Icon limit.
    TALODDB.panelMaxAuras = 2
    MOCK.Tick(0.3)
    local n = 0
    for _, icon in ipairs(det.auras) do if icon:IsShown() then n = n + 1 end end
    check(n == 2, "icon limit, got " .. n)

    -- Dead.
    MOCK.units.nameplate1.dead = true
    MOCK.Tick(0.3)
    check(det.hpText:GetText():find("dead"), "dead text")
    MOCK.units.nameplate1.dead = false

    -- Setting off: one line.
    TALODDB.panelDetails = false
    MOCK.Tick(0.3)
    check(not det:IsShown() and r:GetHeight() == 18, "details off")
    TALODDB.panelDetails = true

    -- Out of view: compact row, no stale health.
    plateRemove("nameplate1")
    check(not det:IsShown() and r:GetHeight() == 18, "gone row is one line")
end

scenarios.panel_details_secrets = function()
    local ns = boot(16001, { secrets = true })
    MOCK.secretMode = true
    plateAdd("nameplate1", MOCK.Enemy({ level = 20, health = 900, healthMax = 2000,
        secret = { health = true, healthMax = true, combat = true, pvp = true },
        buffs = { { spellId = 642, secret = true } }, debuffs = { { opaque = true } } }))
    local det = TALODPanel.rows[1].detail
    -- The mock's bar refuses secrets: the panel must say "?", never a number.
    check(det.hpText:GetText():find("? HP", 1, true), "hidden health: " .. tostring(det.hpText:GetText()))
    check(det.tags:GetText():find("PvP?", 1, true), "hidden flag tag: " .. det.tags:GetText())
    local shown, unknown = 0, false
    for _, icon in ipairs(det.auras) do
        if icon:IsShown() then
            shown = shown + 1
            if icon.unknown then unknown = true end
        end
    end
    check(shown == 2 and unknown, "secret-icon aura shown plus a ? for the hidden one")
    TALODPanel.rows[1]:Fire("OnEnter")
end

-- Fishing: casts and their results, spots and squares by skill band,
-- value per hour, catches per skill point, attacks (NPC, player, unknown,
-- self-started), deaths, enemies seen, lure / bag warnings, auto loot put
-- back, HUD, window, sessions, reset and delete.
local function fishingSetup(iface, opts)
    MOCK.skillLines = { { "Secondary Skills", true, true }, { "Fishing", false, nil, 100, 0, 0, 150 } }
    MOCK.items[6256] = { classID = 2, subclassID = 20, equipLoc = "INVTYPE_2HWEAPON" }   -- Fishing Pole
    MOCK.equippedIDs[16] = 6256
    MOCK.subzone = "Crystal Lake"
    MOCK.cvars.autoLootDefault = MOCK.cvars.autoLootDefault or "0"
    local ns = boot(iface, opts)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    return ns
end

local function castStart(id) MOCK.FireEvent("UNIT_SPELLCAST_CHANNEL_START", "player", "Cast-1", id or 7620) end
local function castStop(id) MOCK.FireEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", "Cast-1", id or 7620) end
local function catch(items, lootFirst)
    castStart() MOCK.Tick(8)
    items.fishing = true
    MOCK.loot = items
    if lootFirst then
        MOCK.FireEvent("LOOT_READY") MOCK.FireEvent("LOOT_OPENED") castStop()
    else
        castStop() MOCK.Tick(0.3) MOCK.FireEvent("LOOT_OPENED") MOCK.FireEvent("LOOT_READY")
    end
    MOCK.loot = nil
    MOCK.Tick(2)
end

scenarios.fishing = function()
    local ns = fishingSetup(11509)
    local F = ns.Fishing
    check(F.Skill() == 100, "skill read: " .. tostring(F.Skill()))
    check(F.PoleEquipped() == true, "pole equipped")
    MOCK.Tick(1.1)
    check(TALODFishingHUD and TALODFishingHUD:IsShown(), "HUD up as soon as a pole is equipped, before any cast")
    ns.Prices.Record(6291, 120, 40, time(), 3, "Raw Brilliant Smallfish")

    -- Catches, one with the loot before the channel ends; the second loot event is no phantom catch.
    catch({ { 6291, "Raw Brilliant Smallfish", 1 } })
    catch({ { 6291, "Raw Brilliant Smallfish", 2 } }, true)
    local s = F.Session()
    check(s and s.n == 2 and s.c == 2 and s.it[6291] == 3, "two catches, three fish: " .. tostring(s and s.n))
    -- Got away (the game says so) and no bite clicked (the channel ran out).
    castStart() MOCK.Tick(5) MOCK.FireEvent("UI_ERROR_MESSAGE", 0, "Your fish got away!") castStop() MOCK.Tick(2)
    castStart() MOCK.Tick(30) castStop() MOCK.Tick(2)
    check(s.a == 1 and s.t == 1 and s.n == 4, "got away + timed out: a=" .. s.a .. " t=" .. s.t)
    local f = F.Store()
    check(#f.casts == 4 and f.casts[1]:find(",c,100,0,0,20,6291:1,Crystal Lake,"), "cast log: " .. tostring(f.casts[1]))
    local spot = F.GetSpot(1429, "Crystal Lake")
    check(spot and spot.b[100] and spot.b[100].c == 2 and spot.b[100].n == 4, "spot band tally")
    check(f.cells[1429]["21:32"].n == 4, "heat map square")
    check(f.ranks[100] == 2, "catches per rank")
    check(f.maps[1429] == "Elwynn Forest", "map name")
    local r = F.Rates(spot.b[100])
    check(math.abs(r.catchPct - 2 / 3) < 0.01, "catch rate leaves out timeouts: " .. tostring(r.catchPct))
    check(r.gph == nil, "no per-hour figure under 5 min")
    local _, _, unseen = F.ItemValue(6291)
    check(unseen == false, "seen on the AH")
    local _, _, unseen2 = F.ItemValue(6303)
    check(unseen2 == true, "never seen on the AH: flagged")

    -- Fish for a while, skill rising one point every three catches.
    for i = 1, 30 do
        catch({ { 6291, "Raw Brilliant Smallfish", 1 } })
        if i % 3 == 0 then
            MOCK.skillLines[2][4] = MOCK.skillLines[2][4] + 1
            MOCK.FireEvent("SKILL_LINES_CHANGED") MOCK.Tick(0.6)
        end
    end
    local need, capped, per = F.NextPoint()
    check(per and math.abs(per - 3) < 0.01 and need == 3 and not capped, "next point estimate: " .. tostring(need) .. " " .. tostring(per))
    r = F.Rates((F.SpotTally(spot, F.Effective())))
    check(r.gph and r.gph > 0 and r.perHour > 0, "gold per hour once fished long enough")
    check(spot.b[100] and spot.b[100].n >= 4, "bands kept apart")
    local list = F.SpotList(F.Effective())
    check(#list == 1 and list[1].name == "Crystal Lake", "spot list")

    -- An NPC attacks during a cast: counted, the cast is "interrupted".
    resetOutput()
    plateAdd("nameplate5", MOCK.Hostile({ targetsPlayer = true }))
    castStart() MOCK.Tick(2)
    MOCK.FireEvent("PLAYER_REGEN_DISABLED")
    check(spot.x == 1 and f.threats[#f.threats].k == "N" and f.threats[#f.threats].who == "Kobold Vermin", "NPC attack")
    castStop() MOCK.Tick(2)
    check(f.casts[#f.casts]:find(",i,"), "interrupted cast")
    -- Combat you start yourself is no attack.
    local threats = #f.threats
    MOCK.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-2", 133)
    MOCK.FireEvent("PLAYER_REGEN_DISABLED")
    MOCK.Tick(3)
    check(#f.threats == threats, "self-started combat not counted")
    plateRemove("nameplate5")
    -- Nothing readable targets you: "?", never guessed.
    MOCK.Tick(4)
    MOCK.FireEvent("PLAYER_REGEN_DISABLED")
    check(#f.threats == threats, "unknown attacker: still looking")
    MOCK.Tick(1) MOCK.Tick(1.5)
    check(f.threats[#f.threats].k == "?" and spot.u == 1, "unknown attacker after the scan")

    -- An enemy player while fishing: counted, the alert sound, then the attack.
    resetOutput()
    catch({ { 6291, "Raw Brilliant Smallfish", 1 } })
    plateAdd("nameplate1", MOCK.Enemy({ level = 20, class = "WARRIOR", name = "Grunt", guid = "Player-1-G", targetsPlayer = true }))
    check(spot.e == 1 and f.threats[#f.threats].k == "E", "enemy seen while fishing")
    check(#MOCK.sounds == 1, "enemy sound while fishing: " .. #MOCK.sounds)
    MOCK.FireEvent("PLAYER_REGEN_DISABLED")
    check(spot.p == 1 and f.threats[#f.threats].who == "Grunt", "player attack")
    MOCK.FireEvent("PLAYER_DEAD")
    check(f.threats[#f.threats].died and spot.d == 1 and F.Session().d == 1, "death after the attack")
    local lines = F.DangerLines(spot)
    check(table.concat(lines, "\n"):find("NPC attacks: 1"), "danger lines: " .. table.concat(lines, " | "))
    plateRemove("nameplate1")

    -- Lure and bag warnings.
    resetOutput()
    MOCK.lureMs = 60000
    castStart() MOCK.Tick(1.1)
    check(F.Lure() == true, "lure on")
    MOCK.lureMs = nil
    MOCK.Tick(1.1)
    check(alertText() and alertText():find("lure ran out"), "lure alert: " .. tostring(alertText()))
    MOCK.freeSlots = 1
    MOCK.Tick(1.1)
    check(alertText() and alertText():find("1 bag slots left"), "bag alert: " .. tostring(alertText()))
    castStop() MOCK.Tick(2)

    -- HUD while fishing.
    check(TALODFishingHUD and TALODFishingHUD:IsShown(), "HUD shown")
    check(TALODFishingHUD.title:GetText():find("Fishing") and TALODFishingHUD.rows[1]:IsShown(), "HUD title and rows")
    -- It follows the pole: gone when you swap it out, back when you equip it.
    MOCK.equippedIDs[16] = nil
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 16)
    check(not TALODFishingHUD:IsShown(), "HUD hidden without a pole")
    MOCK.equippedIDs[16] = 6256
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 16)
    check(TALODFishingHUD:IsShown(), "HUD back with the pole")
    -- Snapping to the Enemies nearby panel.
    local hud, panel = TALODFishingHUD, TALODPanel
    panel:Show()
    panel._l, panel._r, panel._t, panel._b = 100, 444, 800, 700
    hud._l, hud._r, hud._t, hud._b = 110, 454, 690, 560          -- dropped 10 px under it
    hud:Fire("OnDragStart") hud:Fire("OnDragStop")
    local point, rel, relPoint = hud:GetPoint(1)
    check(TALODDB.fishHudDock == "bottom" and point == "TOPLEFT" and rel == panel and relPoint == "BOTTOMLEFT",
        "docked under the panel: " .. tostring(TALODDB.fishHudDock) .. " " .. tostring(point))
    hud._l, hud._r, hud._t, hud._b = 900, 1244, 400, 300           -- dragged far away
    hud._cx, hud._cy = 1072, 350
    UIParent._cx, UIParent._cy = 960, 540
    hud:Fire("OnDragStart") hud:Fire("OnDragStop")
    check(TALODDB.fishHudDock == nil and TALODDB.fishHudPos[1] == 112 and TALODDB.fishHudPos[2] == -190, "undocked, position kept")
    panel._l, panel._r, panel._t, panel._b = 1250, 1594, 420, 320  -- the panel dropped right of the HUD
    panel:Fire("OnDragStop")
    check(TALODDB.fishHudDock == "left", "panel dropped beside the HUD snaps too: " .. tostring(TALODDB.fishHudDock))
    TALODDB.fishHudLocked = true
    ns.Refresh()
    check(hud.lock.tex and true, "lock shown")
    TALODDB.fishHudLocked = false
    slash("fish hud reset")
    check(TALODDB.fishHudDock == nil and select(2, hud:GetPoint(1)) == UIParent, "reset undocks")

    -- Auto loot: on for fishing, your setting back after.
    slash("fish autoloot")
    check(TALODDB.fishAutoLoot == true, "auto loot while fishing on")
    castStart()
    check(MOCK.cvars.autoLootDefault == "1" and TALODDB.fishAutoLootRestore == "0", "auto loot turned on")
    castStop() MOCK.Tick(2)
    MOCK.Tick(50)
    check(MOCK.cvars.autoLootDefault == "1", "kept on while the pole is equipped")
    local function swapPole()
        MOCK.equippedIDs[16] = nil
        MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 16)
        local after = MOCK.cvars.autoLootDefault
        MOCK.equippedIDs[16] = 6256
        MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 16)
        return after
    end
    check(swapPole() == "0" and TALODDB.fishAutoLootRestore == nil, "put back the moment the pole comes off")
    -- Changed by you meanwhile: left alone. Already on: nothing to put back.
    castStart() MOCK.cvars.autoLootDefault = "0" castStop() MOCK.Tick(2)
    check(swapPole() == "0", "your own change kept")
    MOCK.cvars.autoLootDefault = "1"
    castStart() castStop() MOCK.Tick(2)
    check(swapPole() == "1" and TALODDB.fishAutoLootRestore == nil, "already on: untouched")
    MOCK.cvars.autoLootDefault = "0"

    -- Loud splash: sound effects up, music and ambience off while fishing; put back after,
    -- except what you changed yourself.
    MOCK.equippedIDs[16] = nil                -- end the splash of the earlier casts
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 16)
    MOCK.equippedIDs[16] = 6256
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 16)
    MOCK.cvars.Sound_SFXVolume, MOCK.cvars.Sound_MusicVolume, MOCK.cvars.Sound_AmbienceVolume = "0.4", "0.6", "0.5"
    MOCK.cvars.Sound_EnableAllSound, MOCK.cvars.Sound_EnableSFX, MOCK.cvars.Sound_EnableSoundWhenGameIsInBG = "1", "1", "0"
    castStart()
    check(MOCK.cvars.Sound_SFXVolume == "1" and MOCK.cvars.Sound_MusicVolume == "0" and MOCK.cvars.Sound_EnableSoundWhenGameIsInBG == "1",
        "splash: sound set for fishing")
    check(TALODDB.fishSoundRestore.Sound_EnableAllSound == nil, "unchanged settings not saved")
    MOCK.Tick(10)
    check(TALODFishingHUD.title:GetText():find("10s") and TALODFishingHUD.cast:IsShown(), "cast timer on the HUD: " .. TALODFishingHUD.title:GetText())
    MOCK.cvars.Sound_MusicVolume = "0.3"     -- you turn music back on yourself
    castStop() MOCK.Tick(2) MOCK.Tick(50)
    check(MOCK.cvars.Sound_SFXVolume == "1", "splash stays loud while the pole is equipped")
    -- Taking the pole off puts the sound back at once.
    MOCK.equippedIDs[16] = nil
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 16)
    check(MOCK.cvars.Sound_SFXVolume == "0.4" and MOCK.cvars.Sound_AmbienceVolume == "0.5" and MOCK.cvars.Sound_EnableSoundWhenGameIsInBG == "0",
        "splash: put back")
    check(MOCK.cvars.Sound_MusicVolume == "0.3" and TALODDB.fishSoundRestore == nil, "your own change kept")
    MOCK.equippedIDs[16] = 6256
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 16)
    -- A muted game stays muted.
    MOCK.cvars.Sound_EnableAllSound = "0"
    castStart()
    check(MOCK.cvars.Sound_EnableAllSound == "0" and MOCK.cvars.Sound_SFXVolume == "1", "master mute untouched")
    -- Logout puts everything back (the game saves its settings then), even with the log off.
    TALODDB.fishingEnabled = false
    MOCK.FireEvent("PLAYER_LOGOUT")
    check(MOCK.cvars.Sound_SFXVolume == "0.4" and MOCK.cvars.Sound_MusicVolume == "0.3" and TALODDB.fishSoundRestore == nil,
        "logout: sound back")
    TALODDB.fishingEnabled = true
    MOCK.cvars.Sound_EnableAllSound = "1"
    castStop() MOCK.Tick(2)
    -- A write the game refuses is tried again; one it cannot read is put back anyway.
    castStart()
    local set = C_CVar.SetCVar
    C_CVar.SetCVar = function() return false end
    MOCK.equippedIDs[16] = nil
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 16)
    check(MOCK.cvars.Sound_SFXVolume == "1" and TALODDB.fishSoundRestore.Sound_SFXVolume == 0.4, "refused: kept to retry")
    C_CVar.SetCVar = set
    local get = C_CVar.GetCVar
    C_CVar.GetCVar = function(name) if name == "Sound_MusicVolume" then return nil end return get(name) end
    MOCK.Tick(1.1)
    C_CVar.GetCVar = get
    check(MOCK.cvars.Sound_SFXVolume == "0.4" and MOCK.cvars.Sound_MusicVolume == "0.3" and TALODDB.fishSoundRestore == nil,
        "retried, unreadable one put back too")
    MOCK.equippedIDs[16] = 6256
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 16)
    castStop() MOCK.Tick(2)
    -- Auto loot comes back at logout too.
    TALODDB.fishAutoLoot = true
    MOCK.cvars.autoLootDefault = "0"
    castStart()
    check(MOCK.cvars.autoLootDefault == "1", "auto loot on for the logout test")
    MOCK.FireEvent("PLAYER_LOGOUT")
    check(MOCK.cvars.autoLootDefault == "0" and TALODDB.fishAutoLootRestore == nil, "logout: auto loot back")
    castStop() MOCK.Tick(2)

    slash("fish splash")
    check(TALODDB.fishLoudSplash == false, "splash off")
    castStart() check(MOCK.cvars.Sound_SFXVolume == "0.4", "off: nothing changed") castStop() MOCK.Tick(2)

    -- Window: every tab, the map's metrics and squares.
    slash("fish")
    check(TALODFishingWindow and TALODFishingWindow:IsShown(), "fishing window")
    local UI = ns.FishingUI
    for _, key in ipairs({ "now", "spots", "map", "log", "sessions" }) do
        UI.Show(key)
        check(UI.state.view == key, "tab " .. key)
    end
    local map = UI.views.map
    check(map.mapButton.label:GetText():find("Elwynn"), "map button: " .. tostring(map.mapButton.label:GetText()))
    local seen = {}
    for _ = 1, 8 do
        map.metricButton:Fire("OnClick", "LeftButton")
        seen[UI.state.metric] = true
        if map.cells[1] and map.cells[1]:IsShown() then map.cells[1]:Fire("OnEnter") end
    end
    check(seen["item:6291"] and seen.attacks, "metrics include the fish")
    -- The same choices as a dropdown: open, pick, closed; a click outside closes it too.
    UI.Show("map")
    map.metricButton.dropdown:Fire("OnClick", "LeftButton")
    local menu = TALODDropdownMenu
    check(menu and menu:IsShown(), "dropdown open")
    menu.list._height = 400
    menu.list:Draw()
    local picked
    for _, row in ipairs(menu.list.rows) do
        if row:IsShown() and row.item and row.item.text:find("Enemies seen") then row:Fire("OnClick", "LeftButton") picked = true break end
    end
    check(picked and UI.state.metric == "enemies" and not menu:IsShown(), "picked from the dropdown: " .. tostring(UI.state.metric))
    check(map.metricButton.label:GetText():find("Enemies seen"), "button label follows: " .. tostring(map.metricButton.label:GetText()) .. " view " .. tostring(UI.state.view))
    map.mapButton.dropdown:Fire("OnClick", "LeftButton")
    local marked = false
    for _, it in ipairs(menu.list.items) do if it.accent then marked = it.text:find("Elwynn") ~= nil end end
    check(menu:IsShown() and marked, "current map marked in the list")
    map.mapButton.dropdown:Fire("OnClick", "LeftButton")
    check(not menu:IsShown(), "arrow again closes it")
    map.mapButton:Fire("OnClick", "LeftButton")
    TALODFishingWindow.splash:Fire("OnClick", "LeftButton")
    check(TALODDB.fishLoudSplash == true, "window button turns the splash back on")
    TALODFishingWindow.autoLoot:Fire("OnClick", "LeftButton")
    check(TALODDB.fishAutoLoot == false, "window button turns auto loot off")
    UI.Show("now")
    check(UI.views.now.detail.items[2].text:find("%%"), "here: catch rate")

    resetOutput()
    slash("fish stats")
    check(printed("Here %(Crystal Lake"), "stats in chat")

    -- Reset keeps fishing data; the session ends when idle.
    slash("reset")
    check(TALODDB.fishing.spots[1429], "fishing kept across reset")
    MOCK.now = MOCK.now + 400
    MOCK.Tick(1.1)
    check(F.Session() == nil and #TALODDB.fishing.sessions == 1, "session closed after idle")
    UI.Show("sessions")
    for _, cmd in ipairs({ "fish hud", "fish hud", "fish hud reset", "fish spots", "fish map", "fish log", "fish end", "fish nonsense" }) do slash(cmd) end
    slash("fish clear")
    MOCK.AcceptPopup()
    check(next(TALODDB.fishing.spots) == nil and #TALODDB.fishing.casts == 0, "deleted")
    UI.Show("map")
    UI.Show("spots")
end

-- Forever: a hidden spell ID is ignored, a hidden IsFishingLoot falls back to
-- loot at the end of a fishing cast; map art tiles drawn when the game gives them.
scenarios.fishing_forever = function()
    local ns = fishingSetup(16001, { secrets = true })
    local F = ns.Fishing
    function IsFishingLoot() return MOCK.Secret(true) end
    C_Map.GetMapArtLayers = function() return { { layerWidth = 1002, layerHeight = 668, tileWidth = 256, tileHeight = 256 } } end
    C_Map.GetMapArtLayerTextures = function() local t = {} for i = 1, 12 do t[i] = 700000 + i end return t end
    castStart(MOCK.Secret(7620)) MOCK.Tick(5) castStop(MOCK.Secret(7620)) MOCK.Tick(2)
    check(F.Session() == nil, "hidden spell ID: not a cast")
    MOCK.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 7620)
    MOCK.Tick(6)
    MOCK.loot = { { 6291, "Raw Brilliant Smallfish", 1 } }
    castStop(MOCK.Secret(7620))
    MOCK.FireEvent("LOOT_OPENED")
    MOCK.loot = nil
    MOCK.Tick(2)
    local s = F.Session()
    check(s and s.c == 1, "catch from loot timing: " .. tostring(s and s.c))
    ns.FishingUI.Show("map")
    check(ns.FishingUI.views.map.tiles[12] and ns.FishingUI.views.map.tiles[12]:IsShown(), "map art tiles")
    slash("probe")
    check(table.concat(TALODDB.lastProbe, "\n"):find("fishing: "), "probe fishing line")
end

-- The game crashed while fishing: no logout, so the addon's note of what to
-- put back is gone, but the game kept the fishing sound and auto loot. At
-- login you are asked; your answer is applied; a clean logout learns your
-- settings. Logging in with the pole already equipped changes nothing until
-- you cast.
scenarios.fishing_crash_recovery = function()
    local usual = { Sound_EnableSFX = 1, Sound_SFXVolume = 0.4, Sound_MusicVolume = 0.6, Sound_AmbienceVolume = 0.5,
        Sound_EnableSoundWhenGameIsInBG = 0 }
    MOCK.cvars.Sound_EnableSFX, MOCK.cvars.Sound_SFXVolume, MOCK.cvars.Sound_MusicVolume = "1", "1", "0"
    MOCK.cvars.Sound_AmbienceVolume, MOCK.cvars.Sound_EnableSoundWhenGameIsInBG = "0", "1"
    MOCK.cvars.autoLootDefault = "1"   -- left on by the crash
    local ns = fishingSetup(11509, { db = { fishAutoLoot = true, fishLoudSplash = true, fishSoundLast = usual, fishAutoLootLast = 0 } })
    check(TALODFishingHUD and TALODFishingHUD:IsShown(), "logged in holding the pole: HUD up")
    MOCK.Tick(1.1)
    check(MOCK.popup == "TALOD_FISHING_LEFTOVER", "asked about the leftovers: " .. tostring(MOCK.popup))
    check(MOCK.popupText:find("sound") and MOCK.popupText:find("Auto Loot"), "both named: " .. tostring(MOCK.popupText))
    -- Casting while the question is open does not take the leftovers for your usual settings.
    castStart()
    check(TALODDB.fishSoundLast.Sound_SFXVolume == 0.4 and TALODDB.fishSoundRestore == nil, "usual kept while asking")
    castStop() MOCK.Tick(2)
    MOCK.AcceptPopup()
    check(MOCK.cvars.Sound_SFXVolume == "0.4" and MOCK.cvars.Sound_MusicVolume == "0.6" and MOCK.cvars.Sound_AmbienceVolume == "0.5"
        and MOCK.cvars.Sound_EnableSoundWhenGameIsInBG == "0" and MOCK.cvars.autoLootDefault == "0", "usual settings back")
    -- From now on the normal path: the next cast sets fishing values, unequip puts them back.
    castStart()
    check(MOCK.cvars.Sound_SFXVolume == "1" and MOCK.cvars.autoLootDefault == "1", "fishing settings at the next cast")
    castStop() MOCK.Tick(2)
    MOCK.equippedIDs[16] = nil
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 16)
    check(MOCK.cvars.Sound_SFXVolume == "0.4" and MOCK.cvars.autoLootDefault == "0", "back on unequip")
    -- You change your own settings; a clean logout learns them, so no false question next time.
    MOCK.cvars.Sound_MusicVolume, MOCK.cvars.autoLootDefault = "0.2", "1"
    MOCK.FireEvent("PLAYER_LOGOUT")
    check(TALODDB.fishSoundLast.Sound_MusicVolume == 0.2 and TALODDB.fishAutoLootLast == 1, "logout learns your settings")
    check(ns.Fishing.FindLeftovers() == nil, "nothing looks left over")
end

-- No crash record: nothing is asked, even when the values happen to match.
scenarios.fishing_no_false_alarm = function()
    MOCK.cvars.Sound_SFXVolume, MOCK.cvars.Sound_MusicVolume = "1", "0"
    local ns = fishingSetup(11509)
    MOCK.Tick(1.1)
    check(MOCK.popup == nil, "no question without a record")
    castStart() castStop() MOCK.Tick(2)
    check(MOCK.popup == nil, "still none after a cast")
end

-- Sound stuck in the splash values with no record (no question asked): the
-- check names it, "reset" falls back to the game's defaults, "default"
-- ignores your usual, the master switch is only reported.
scenarios.fishing_sound_restore = function()
    MOCK.cvars.Sound_EnableSFX, MOCK.cvars.Sound_SFXVolume, MOCK.cvars.Sound_MusicVolume = "1", "1", "0"
    MOCK.cvars.Sound_AmbienceVolume, MOCK.cvars.Sound_EnableSoundWhenGameIsInBG = "0", "1"
    MOCK.cvars.Sound_EnableAllSound = "0"
    local ns = fishingSetup(11509)
    MOCK.equippedIDs[16] = nil
    MOCK.FireEvent("PLAYER_EQUIPMENT_CHANGED", 16)
    MOCK.Tick(1.1)
    MOCK.prints = {}
    slash("fish sound")
    check(printed("Music volume: 0 %(fishing value%).*back to 0%.4 %(game default%)"), "music row")
    check(printed("Looks left over"), "verdict: left over")
    check(printed("Master sound is OFF"), "master reported")
    slash("fish sound reset")
    check(MOCK.cvars.Sound_MusicVolume == "0.4" and MOCK.cvars.Sound_AmbienceVolume == "0.6"
        and MOCK.cvars.Sound_EnableSoundWhenGameIsInBG == "0" and MOCK.cvars.Sound_SFXVolume == "1",
        "game defaults when no usual is known")
    check(MOCK.cvars.Sound_EnableAllSound == "0", "master switch untouched")
    check(TALODDB.fishSoundLast and TALODDB.fishSoundLast.Sound_MusicVolume == 0.4, "learned as usual")
    MOCK.prints = {}
    slash("fish sound")
    check(printed("Nothing looks stuck"), "clean after reset")

    -- Your usual wins over the default with "reset"; "default" ignores it.
    TALODDB.fishSoundLast = { Sound_MusicVolume = 0.2, Sound_SFXVolume = 0.5 }
    MOCK.cvars.Sound_MusicVolume, MOCK.cvars.Sound_SFXVolume = "0", "1"
    slash("fish sound reset")
    check(MOCK.cvars.Sound_MusicVolume == "0.2" and MOCK.cvars.Sound_SFXVolume == "0.5", "usual back")
    slash("fish sound default")
    check(MOCK.cvars.Sound_MusicVolume == "0.4" and MOCK.cvars.Sound_SFXVolume == "1", "game defaults")

    -- A pending restore is what "reset" puts back, and it is cleared.
    TALODDB.fishSoundRestore = { Sound_MusicVolume = 0.7 }
    MOCK.cvars.Sound_MusicVolume = "0"
    slash("fish sound reset")
    check(MOCK.cvars.Sound_MusicVolume == "0.7" and TALODDB.fishSoundRestore == nil, "pending value back, cleared")
end

-- Every list: a scrollbar when rows do not fit; search (colors ignored)
-- and time range where turned on; section headers only above matches;
-- dated headers filter with their detail rows; "N of M shown".
scenarios.list_filters = function()
    local ns = boot(11509)
    local Style = ns.Style
    local holder = CreateFrame("Frame", nil, UIParent)
    local list = Style.List(holder, { search = true, time = true, labelWidth = 60 })
    list._height = 28 + 10 * Style.ROW                -- toolbar + 10 rows
    local now = time()
    local items = { { header = true, text = "Fish" } }
    for i = 1, 30 do
        items[#items + 1] = { text = "|cff1eff00Raw Longjaw Mud Snapper|r", label = "row " .. i, time = now - i * 600 }
    end
    items[#items + 1] = { header = true, text = "Other" }
    items[#items + 1] = { text = "Oily Blackmouth", time = now - 3 * 86400 }
    list:SetItems(items)
    check(list.visible == 10 and list.track:IsShown(), "scrollbar when rows do not fit")
    -- Click on the track halfway down: jumps there.
    list.track._t, list.track._height = 500, 10 * Style.ROW
    MOCK.cursorX, MOCK.cursorY = 0, 500 - 5 * Style.ROW
    list.track:Fire("OnClick", "LeftButton")
    check(list.offset > 5 and list.offset < #list.items - 10, "track click scrolls: " .. list.offset)
    list:GetScript("OnMouseWheel")(list, 1)
    -- Search ignores colors and case.
    list.searchBox:SetText("MUD snapper")
    list.searchBox:Fire("OnTextChanged")
    check(#list.items == 31 and list.items[1].header and list.items[1].text == "Fish", "search keeps its section header")
    check(list.count:GetText():find("30 of 31"), "count: " .. tostring(list.count:GetText()))
    list.searchBox:SetText("blackmouth")
    list.searchBox:Fire("OnTextChanged")
    check(#list.items == 2 and list.items[1].text == "Other", "other section only")
    list.searchBox:SetText("nothing like this")
    list.searchBox:Fire("OnTextChanged")
    check(#list.items == 1 and list.items[1].text:find("Nothing matches"), "nothing matches")
    list.searchBox.clear:Fire("OnClick")
    list.searchBox:Fire("OnTextChanged")
    -- Time ranges: last hour = 6 rows (10, 20 ... 60 min ago) + the header; the dropdown too.
    list:SetRange("hour")
    check(#list.items == 7 and not list.track:IsShown(), "last hour: " .. #list.items)
    list.rangeButton:Fire("OnClick", "LeftButton")
    check(list.range == "today", "range cycles")
    list.rangeButton.dropdown:Fire("OnClick", "LeftButton")
    TALODDropdownMenu.list._height = 400
    TALODDropdownMenu.list:Draw()
    for _, row in ipairs(TALODDropdownMenu.list.rows) do
        if row:IsShown() and row.item and row.item.text:find("Last 7 days") then row:Fire("OnClick", "LeftButton") break end
    end
    check(list.range == "week" and #list.items == 33 and list.rangeButton.label:GetText():find("7 days"), "week via the dropdown")
    -- A dated header is one entry with its detail rows.
    local ledger = Style.List(holder, { search = true, time = true })
    ledger:SetItems({
        { header = true, time = now - 60, text = "Gear change" }, { label = "Head", text = "Crown of Testing" }, { label = "", text = "from Hogger" },
        { header = true, time = now - 10 * 86400, text = "Level 20" }, { label = "Measured", text = "+5 Stamina" },
    })
    ledger:SetRange("week")
    check(#ledger.items == 3 and ledger.items[3].text == "from Hogger", "old entry left out with its rows")
    ledger:SetRange("all")
    ledger.searchBox:SetText("hogger")
    ledger.searchBox:Fire("OnTextChanged")
    check(#ledger.items == 3 and ledger.items[2].text == "Crown of Testing", "a match shows the whole entry")
    check(ledger.count:GetText():find("1 of 2"), "entries counted: " .. tostring(ledger.count:GetText()))
    -- Plain lists: no toolbar, still a scrollbar.
    local plain = Style.List(holder, {})
    plain._height = 3 * Style.ROW
    plain:SetItems(items)
    check(plain.toolbar == nil and plain.track:IsShown() and plain.visible == 3, "plain list: scrollbar only")
end

-- Newer auction house (WoW Forever): "Search next" goes through the window's
-- own search bar (results shown there), else an item-key query; busy is
-- said; a full scan is read even when its event never comes, can be
-- cancelled, and a call the game blocks is reported instead of silence.
scenarios.ah_helper_modern = function()
    MOCK.bags[0][1] = MOCK.ItemLink(2589, "Linen Cloth")
    MOCK.bags[0][2] = MOCK.ItemLink(2592, "Wool Cloth")
    MOCK.bags[0][3] = MOCK.ItemLink(4306, "Silk Cloth")
    local ns = boot(16001)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(3.2) MOCK.Tick(0.3)
    local H, Pr = ns.AHHelper, ns.Prices
    local sent, replicate, ready, rows = {}, 0, true, {}
    C_AuctionHouse = {
        SendSearchQuery = function(key) sent[#sent + 1] = key end,
        MakeItemKey = function(id) return { itemID = id } end,
        IsThrottledMessageSystemReady = function() return ready end,
        ReplicateItems = function() replicate = replicate + 1 end,
        GetNumReplicateItems = function() return #rows end,
        GetReplicateItemInfo = function(i) local r = rows[i] return r[1], nil, r[2], nil, nil, nil, nil, nil, nil, r[3], nil, nil, nil, nil, nil, nil, r[4] end,
    }
    local searched = {}
    AuctionHouseFrame = CreateFrame("Frame", "AuctionHouseFrame", UIParent)
    AuctionHouseFrame.SearchBar = { SearchBox = CreateFrame("EditBox", nil, AuctionHouseFrame),
        StartSearch = function(self) searched[#searched + 1] = self.SearchBox:GetText() end }

    MOCK.FireEvent("AUCTION_HOUSE_SHOW")
    MOCK.RunTimers()
    check(H.Panel():IsShown() and #H.state.queue > 0, "panel and list")
    local first = H.state.queue[1]
    TALODAHNextButton:Fire("OnClick", "LeftButton")
    check(searched[1] == first.name and #sent == 0, "searched in the AH window's search bar: " .. tostring(searched[1]))
    check(H.state.message:find("shown in the Auction House window"), "message: " .. H.state.message)
    Pr.Record(first.id, 120, 20, time(), 2, first.name)
    MOCK.Tick(0.3)
    check(H.state.index == 2 and H.state.results[first.id].p == 120, "result picked up")
    -- Busy: said, nothing sent.
    ready = false
    TALODAHNextButton:Fire("OnClick", "LeftButton")
    check(H.state.message:find("busy") and #searched == 1, "busy: " .. H.state.message)
    ready = true
    -- Without the search bar: the item-key query.
    AuctionHouseFrame.SearchBar = nil
    H.BuildQueue()
    if H.state.queue[1] then
        TALODAHNextButton:Fire("OnClick", "LeftButton")
        check(#sent == 1 and sent[1].itemID == H.state.queue[1].id, "item-key search")
    end
    H.Skip()

    -- Full scan: no event comes, the data is found anyway.
    local panel = H.Panel()
    panel.scanButton:Fire("OnClick", "LeftButton")
    check(replicate == 1 and H.state.scan, "replicate sent")
    MOCK.Tick(1)
    check(panel.scanButton.label:GetText():find("Waiting for the server") and panel.scanButton.label:GetText():find("cancel"), "waiting shows seconds and cancel")
    rows = { { "Salt", 10, 300, 4289 }, { "Salt", 20, 400, 4289 } }
    MOCK.Tick(2.5)
    MOCK.RunTimers() MOCK.RunTimers()
    check(not H.state.scan and Pr.Entry(4289) and Pr.Entry(4289).p == 30, "scan read without its event")
    -- Proof it was real: counts from the answer, in the log, chat and the tooltip.
    local log = TALODDB.ahScanLog
    check(log and log[#log].ok and log[#log].rows == 2 and log[#log].items == 1 and log[#log].new == 1, "scan logged with counts")
    check(printed("Full scan done.*2 auctions, 1 items with a price: 1 new"), "chat: scan done")
    check(panel.scanStatus:GetText():find("Last: done"), "panel: last result")
    local tipLines = {}
    ns.Tooltip.ItemLines({ AddDoubleLine = function(_, l, r) tipLines[#tipLines + 1] = r end, AddLine = function() end, Show = function() end }, 4289)
    check(table.concat(tipLines, " | "):find("in the full scan"), "tooltip: from the full scan")

    -- Cancel a scan the server does not answer: the cooldown is cleared.
    TALODDB.ahFullScan = {}
    rows = {}
    panel.scanButton:Fire("OnClick", "LeftButton")
    check(H.state.scan, "second scan sent")
    panel.scanButton:Fire("OnClick", "LeftButton")
    check(not H.state.scan and H.state.message == "full scan cancelled." and H.NextFullScan() == 0, "cancelled: " .. tostring(H.state.message))
    check(log[#log].ok == false and log[#log].result == "cancelled" and printed("Full scan failed.*cancelled"), "cancel logged")
    -- No answer: logged after the timeout.
    panel.scanButton:Fire("OnClick", "LeftButton")
    MOCK.Tick(91) MOCK.Tick(0.3)
    check(not H.state.scan and log[#log].result:find("no answer"), "timeout logged: " .. tostring(log[#log].result))
    TALODDB.ahFullScan = {}
    -- The window closed before the answer.
    panel.scanButton:Fire("OnClick", "LeftButton")
    MOCK.FireEvent("AUCTION_HOUSE_CLOSED")
    check(log[#log].result:find("window closed"), "closed logged")
    MOCK.FireEvent("AUCTION_HOUSE_SHOW")
    MOCK.RunTimers()
    TALODDB.ahFullScan = {}

    -- The game blocks a call: said, not silent.
    panel.scanButton:Fire("OnClick", "LeftButton")
    MOCK.FireEvent("ADDON_ACTION_BLOCKED", ADDON_NAME, "C_AuctionHouse.ReplicateItems()")
    check(not H.state.scan and H.state.message:find("blocked C_AuctionHouse.ReplicateItems"), "blocked: " .. tostring(H.state.message))
    check(log[#log].result:find("the game blocked"), "blocked logged")
    MOCK.prints = {}
    slash("ah log")
    check(printed("full scans, newest first") and printed("Full scan done") and printed("blocked"), "/talod ah log")
    -- Reset keeps prices and the scan log.
    slash("reset")
    check(TALODDB.ahScanLog and #TALODDB.ahScanLog == #log and Pr.Entry(4289), "reset keeps prices and the scan log")
    MOCK.FireEvent("ADDON_ACTION_BLOCKED", "OtherAddon", "C_AuctionHouse.ReplicateItems()")
    MOCK.FireEvent("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
    slash("probe")
    check(table.concat(TALODDB.lastProbe, "\n"):find("auction house: C_AuctionHouse=yes"), "probe auction house line")
end

-- Attacking an enemy player's pet or an enemy-faction NPC flags you too;
-- an ordinary hostile mob does not.
scenarios.flag_safety_npcs = function()
    local ns = boot(11509)
    MOCK.playerPvP = false
    resetOutput()
    setTarget({ exists = true, isPlayer = false, name = "Wolf Pet", canAttack = true, enemy = true, playerControlled = true,
        pvp = true, faction = "Horde", distance = 10 })
    check(printed("Attacking Wolf Pet %(a player's pet%) will flag you"), "pet warning")
    resetOutput()
    setTarget({ exists = true, isPlayer = false, name = "Orgrimmar Grunt", canAttack = true, enemy = true, pvp = true,
        faction = "Horde", distance = 10 })
    check(printed("Attacking Orgrimmar Grunt %(Horde%) will flag you"), "faction NPC warning")
    resetOutput()
    setTarget({ exists = true, isPlayer = false, name = "Timber Wolf", canAttack = true, enemy = true, pvp = false, distance = 10 })
    check(not printed("flag you"), "no warning for an ordinary mob")
    -- Already flagged: nothing.
    MOCK.playerPvP = true
    resetOutput()
    setTarget({ exists = true, isPlayer = false, name = "Grunt Two", canAttack = true, enemy = true, pvp = true, faction = "Horde", distance = 10 })
    check(not printed("flag you"), "no warning when flagged")
end

-- Fixes from the review: a trade with your own alt is a transfer; several
-- stacks posted at once are one listing per auction; a reset keeps data;
-- typed names are capitalized like the game's.
scenarios.review_fixes = function()
    MOCK.money = 100000
    local ns = boot(11509)
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    MOCK.Tick(2.2) MOCK.Tick(0.3)
    local c = ns.Economy.Char()
    local function changed() MOCK.FireEvent("PLAYER_MONEY") MOCK.FireEvent("BAG_UPDATE_DELAYED") MOCK.Tick(0.5) end

    -- Trade with your own character: a transfer, not spending.
    TALODDB.economy["Alt-Mockrealm"] = { log = {}, days = {} }
    MOCK.units.NPC = { exists = true, name = "Alt" }
    function GetTradePlayerItemLink() return nil end
    function GetTradeTargetItemLink() return nil end
    function GetPlayerTradeMoney() return 5000 end
    function GetTargetTradeMoney() return 0 end
    MOCK.FireEvent("TRADE_SHOW")
    MOCK.FireEvent("TRADE_MONEY_CHANGED")
    MOCK.money = MOCK.money - 5000
    MOCK.FireEvent("TRADE_CLOSED")
    changed()
    local e = c.log[#c.log]
    check(e.kind == "transfer" and e.detail == "Alt" and e.amount == -5000, "trade with an alt is a transfer: " .. tostring(e.kind))
    local _, exp = ns.Economy.ScopeTotals("all", nil)
    check(exp == 0, "an alt trade is no spending for the account: " .. exp)
    MOCK.Tick(4)

    -- Three stacks of 20 posted at once; the server takes two, then one.
    MOCK.FireEvent("AUCTION_HOUSE_SHOW")
    for slot = 1, 3 do
        MOCK.bags[0][slot] = MOCK.ItemLink(2589, "Linen Cloth")
        MOCK.bagCounts["0:" .. slot] = 20
    end
    changed()
    MOCK.sellItem = { "Linen Cloth", 20 }
    PostAuction(100, 200, 3, 20, 3)
    MOCK.bags[0][1], MOCK.bags[0][2] = nil, nil
    MOCK.money = MOCK.money - 60
    changed()
    check(#c.auctions == 2 and c.auctions[1].count == 20 and c.auctions[1].deposit == 30 and c.auctions[2].deposit == 30,
        "two stacks: two listings of 20, 30c each: " .. #(c.auctions or {}))
    MOCK.bags[0][3] = nil
    MOCK.money = MOCK.money - 30
    changed()
    check(#c.auctions == 3 and c.auctions[3].deposit == 30 and c.auctions[3].status == "listed", "third stack later: its own listing")
    MOCK.FireEvent("AUCTION_HOUSE_CLOSED")
    MOCK.Tick(4)
    -- One sale letter closes one stack.
    MOCK.inbox[1] = { sender = "Auction House", subject = "Auction successful: Linen Cloth", money = 220, invoice = "seller", item = "Linen Cloth", player = "Bob" }
    MOCK.FireEvent("MAIL_SHOW")
    TakeInboxMoney(1)
    changed()
    local sales = ns.Market.MySales(2589)
    check(sales.sold == 1 and sales.units == 20 and sales.listed == 40 and sales.perUnit == 11, "one stack sold: "
        .. sales.sold .. " " .. sales.units .. " " .. sales.listed .. " " .. tostring(sales.perUnit))
    MOCK.FireEvent("MAIL_CLOSED")

    -- A reset keeps logged data (including stores without a default) and resets settings.
    TALODDB.alertsEnabled = false
    TALODDB.someFutureLog = { 1, 2, 3 }
    TALODDB.fishHudPos = { 10, 10 }
    slash("reset")
    check(TALODDB.alertsEnabled == true, "setting reset")
    check(TALODDB.someFutureLog and #TALODDB.someFutureLog == 3, "unknown data store kept")
    TALODDB.someFutureLog = nil
    check(TALODDB.economy["Alt-Mockrealm"] and #ns.Economy.Char().auctions == 3, "economy kept")
    check(TALODDB.fishHudPos == nil, "HUD position reset")

    -- Typed names: "SHADOWFANG" is the same player as "Shadowfang".
    slash("kos SHADOWFANG")
    check(ns.ListOf("Shadowfang") == "kos", "typed name normalized")
    slash("avoid bob-OtherRealm")
    check(ns.ListOf("Bob-OtherRealm") == "avoid", "realm kept as typed")
end

-- The panel's alerts button mutes enemy notifications; the panel keeps listing enemies.
scenarios.panel_mute_alerts = function()
    local ns = boot(11509)
    local button = TALODPanel.alerts
    check(button and not button.muted:IsShown(), "alerts button shows on")
    button:Fire("OnClick", "LeftButton")
    check(TALODDB.alertsEnabled == false and button.muted:IsShown(), "muted from the panel")
    check(printed("enemy alerts muted"), "said in chat")
    resetOutput()
    plateAdd("nameplate1", MOCK.Enemy({ level = 30 }))
    MOCK.Tick(0.3)
    check(alertText() == nil and not printed("ENEMY"), "no alert while muted")
    check(ns.Spotter.Count() == 1 and TALODPanel.rows[1]:IsShown(), "the panel still lists the enemy")
    -- The vanish alert is muted too.
    TALODDB.vanishAlert = true
    ns.Alerts.OnVanished({ name = "Shadowfang", classFile = "ROGUE", lo = 5, hi = 8 })
    check(alertText() == nil, "no vanish alert while muted")
    -- Back on: the same switch as the settings checkbox.
    button:Fire("OnClick", "LeftButton")
    check(TALODDB.alertsEnabled == true and not button.muted:IsShown(), "on again")
    ns.Alerts.Reset()
    plateRemove("nameplate1")
    plateAdd("nameplate2", MOCK.Enemy({ guid = "Player-1-B", name = "Other", level = 30 }))
    check(alertText() and alertText():find("Other"), "alerts again: " .. tostring(alertText()))
end

-- The generated databases: shapes the planner, Market and Enhance rely on.
scenarios.data_integrity = function()
    local ns = boot(11509)
    local bad = {}
    local function Bad(msg) if #bad < 10 then bad[#bad + 1] = msg end end
    for _, data in ipairs({ ns.ProfessionData, ns.EnhanceData }) do
        for sid, r in pairs(data.recipes) do
            if r.creates and not (type(r.makes) == "number" and r.makes >= 1) then Bad(sid .. " makes " .. tostring(r.makes)) end
            local c = r.colors
            if c and not (c[1] <= c[2] and c[2] <= c[3] and c[3] <= c[4]) then Bad(sid .. " colors") end
            if sid >= 40000 then Bad(sid .. " is not a vanilla spell ID") end
            for _, rg in ipairs(r.reagents or {}) do
                if not (type(rg[2]) == "number" and rg[2] > 0) then Bad(sid .. " reagent count") end
            end
        end
    end
    for name, ranks in pairs(ns.ProfessionData.ranks) do
        for i = 2, #ranks do
            if ranks[i].max <= ranks[i - 1].max then Bad(name .. " ranks out of order") end
        end
    end
    check(#bad == 0, "data problems: " .. table.concat(bad, "; "))
end

-- More scenarios live in tests/scenarios_<area>.lua (run.py finds them):
-- each file is a chunk called with (scenarios, T), T holding the helpers.
local T = { check = check, boot = boot, slash = slash, printed = printed, plateAdd = plateAdd,
    plateRemove = plateRemove, setTarget = setTarget, alertText = alertText, resetOutput = resetOutput,
    fishingSetup = fishingSetup, castStart = castStart, castStop = castStop, catch = catch }
for _, path in ipairs(EXTRA_SCENARIO_FILES or {}) do
    local chunk = assert(loadfile(path))
    chunk(scenarios, T)
end

local fn = scenarios[SCENARIO]
if not fn then error("unknown scenario " .. tostring(SCENARIO)) end
fn()
-- SafeCall keeps the addon running through its own errors; a scenario with
-- a caught error still fails.
local log = TALODDB and TALODDB.errorLog or {}
if #log > 0 then error("caught addon error: " .. tostring(log[1].stack)) end
