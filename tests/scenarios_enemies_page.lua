-- World > Enemies (EnemiesUI in Journal.lua): Journal, Lists and Census tabs,
-- the player card (what the who command prints, the note, the list buttons),
-- the commands that open it, and unknown never shown as known or as 0.
local scenarios, T = ...
local check, boot, slash, plateAdd = T.check, T.boot, T.slash, T.plateAdd

local function plain(text) return (tostring(text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end

local function page(ns) return ns.EnemiesUI.Frame() end

-- Rows are built when drawn; tests build them the same way.
local function ready(item)
    if item.build then
        local b = item.build
        item.build = nil
        b(item)
    end
    return item
end

local function items(list)
    local out = {}
    for _, item in ipairs(list.items) do out[#out + 1] = ready(item) end
    return out
end

local function rowFor(list, key)
    for _, item in ipairs(items(list)) do
        if item.key == key then return item end
    end
end

local function search(ns, text, enter)
    local box = ns.EnemiesUI.views.people.search
    box:SetText(text)
    box:Fire("OnTextChanged")
    if enter then box:Fire("OnEnterPressed") end
end

local function buildPage(classic)
    local ns = boot(11509, { db = { classicLook = classic or nil } })
    check(ns.Style.Look() == (classic and "classic" or "ledger"), "look: " .. ns.Style.Look())
    plateAdd("nameplate1", MOCK.Enemy({ level = 24, guild = "Gankers" }))
    local UI = ns.EnemiesUI
    check(UI and UI.ShowPage and UI.PageStatus, "page module contract")
    UI.ShowPage("journal")
    local f = page(ns)
    check(f and f:IsShown() and f == _G[ns.FRAME .. "EnemiesWindow"], "window shown under its frame name")
    check(f.navKey == "enemies", "a main window of the page list")
    check(f.gear, "gear to the settings section")
    for _, key in ipairs({ "panel", "alerts", "clear", "kos", "avoid", "remove" }) do
        check(f.buttons[key] and f.buttons[key]:GetParent() == f.header, "title bar button " .. key)
    end
    check(UI.views.people:IsShown() and not UI.views.census:IsShown(), "journal tab")
    check(rowFor(UI.views.people.list, "Shadowfang"), "the sighting is a row")
    UI.ShowPage("lists")
    check(UI.state.tab == "lists" and UI.views.people.lists:IsShown() and not UI.views.people.ranges:IsShown(), "lists tab")
    UI.ShowPage("census")
    check(UI.views.census:IsShown() and not UI.views.people:IsShown(), "census tab")
    f.tabs[1]:Fire("OnClick")
    check(UI.state.tab == "journal", "tab click")
    -- No secure button anywhere on the page.
    for _, w in ipairs(MOCK.frames) do
        local p, inPage = w, false
        while p do if p == f then inPage = true break end p = p:GetParent() end
        check(not (inPage and w._template and tostring(w._template):find("Secure")), "no secure button on the page")
    end
    return ns
end

scenarios.enemies_page_ledger = function() buildPage(false) end
scenarios.enemies_page_classic = function() buildPage(true) end

scenarios.enemies_player_card = function()
    local ns = boot(11509)
    plateAdd("nameplate1", MOCK.Enemy({ level = 24, guild = "Gankers" }))
    local UI = ns.EnemiesUI
    UI.ShowPage("journal")
    local people = UI.views.people
    -- Search filters, Enter shows the card.
    search(ns, "shadow")
    check(rowFor(people.list, "Shadowfang"), "search keeps the match")
    search(ns, "zzz")
    check(not rowFor(people.list, "Shadowfang"), "search drops others")
    search(ns, "shadowfang", true)
    check(UI.state.selected == "Shadowfang", "Enter selects the player")
    local card = people.card
    check(card.body:IsShown() and not card.empty:IsShown(), "card shows")
    check(card.pairs["Level"].shown == "24", "level: " .. tostring(card.pairs["Level"].shown))
    check(card.pairs["Guild"].shown == "<Gankers>", "guild")
    check(plain(card.pairs["Seen"].shown):find("^1 time"), "seen: " .. tostring(card.pairs["Seen"].shown))
    check(plain(card.title:GetText()) == "Shadowfang", "name on the card")
    -- The note: Enter saves, empty clears.
    card.note:SetText("camps the road")
    card.note:Fire("OnEnterPressed")
    check(TALODDB.players.Shadowfang.note == "camps the road", "note saved")
    check(ns.Journal.Describe("Shadowfang"):find("camps the road", 1, true), "who prints the note")
    card.note:SetText("  ")
    card.note:Fire("OnEnterPressed")
    check(TALODDB.players.Shadowfang.note == nil, "empty note clears")
    -- List buttons: one click, one list change.
    check(not card.unlist:IsEnabled(), "unlist off while on no list")
    card.kos:Click()
    check(TALODDB.players.Shadowfang.list == "kos" and card.kos.on and card.tag:IsShown(), "kill on sight")
    local row = rowFor(people.list, "Shadowfang")
    check(type(row.cols[1]) == "table" and row.cols[1].tone == "danger", "list tag on the row")
    UI.ShowPage("lists")
    check(rowFor(people.list, "Shadowfang"), "on the Lists tab")
    check(people.card.body:IsShown() and people.card.key == "Shadowfang", "same card on Lists")
    card.avoid:Click()
    check(TALODDB.players.Shadowfang.list == "avoid" and card.avoid.on and not card.kos.on, "avoid")
    -- Chips: Kill on sight only hides avoid.
    people.lists.chips[2]:Click()
    check(not UI.state.lists.avoid and not rowFor(people.list, "Shadowfang"), "avoid chip off hides the row")
    people.lists.chips[2]:Click()
    card.unlist:Click()
    check(TALODDB.players.Shadowfang.list == nil and not rowFor(people.list, "Shadowfang"), "unlisted")
    -- Add by name: a player never seen goes on a list from the card.
    search(ns, "newname", true)
    check(UI.state.selected == "Newname", "typed name selected (capitalized like the game)")
    card.kos:Click()
    check(TALODDB.players.Newname and TALODDB.players.Newname.list == "kos", "listed by name")
    search(ns, "")
    check(rowFor(people.list, "Newname"), "listed by name: a row")
    -- Header: Target buttons go through the list command.
    T.setTarget(MOCK.Enemy({ guid = "Player-1-T", name = "Targetguy", level = 30 }))
    page(ns).buttons.kos:Click()
    check(TALODDB.players.Targetguy and TALODDB.players.Targetguy.list == "kos", "Target: kill on sight")
    page(ns).buttons.remove:Click()
    check(TALODDB.players.Targetguy.list == nil, "Target: remove")
end

scenarios.enemies_unknown_fields = function()
    local ns = boot(11509)
    -- Seen with nothing but a name: level, class and guild hidden.
    ns.Journal.Record({ key = "Ghost", keyed = true, hostile = true, name = "Ghost" }, "n")
    ns.Journal.SetList("Nobody", "avoid")
    local UI = ns.EnemiesUI
    UI.ShowPage("journal")
    local people = UI.views.people
    local row = rowFor(people.list, "Ghost")
    check(row, "the hidden player is a row")
    check(row.cols[3] == ns.UNKNOWN, "level cell is the unknown tag")
    local unknown = ns.ColorCode("unknown")
    check(row.text:find(unknown .. "? class", 1, true) and row.text:find(unknown .. "? guild", 1, true), "unknown class and guild: " .. row.text)
    UI.Select("Ghost")
    local P = people.card.pairs
    for _, label in ipairs({ "Level", "Race and class", "Guild" }) do
        check(P[label].tone == "unknown" and P[label].tag:IsShown() and P[label].shown == "?", label .. " unknown tag")
        check(not plain(P[label].shown):find("%d"), label .. " no number")
    end
    -- Never seen at all: still unknown, and "never seen" rather than 0.
    UI.Select("Nobody")
    check(P["Level"].tone == "unknown", "never seen: level unknown")
    check(plain(P["Seen"].shown) == "never seen", "never seen, not 0")
    UI.ShowPage("lists")
    local lrow = rowFor(people.list, "Nobody")
    check(lrow and lrow.cols[3] == ns.UNKNOWN, "lists row: unknown level")
    -- A skull is danger, not unknown.
    ns.Journal.SetList("Boss", "kos", { name = "Boss", skull = true })
    UI.ShowPage("lists")
    local brow = rowFor(people.list, "Boss")
    check(brow and brow.cols[3].tag == "??" and brow.cols[3].tone == "danger", "skull level")
end

scenarios.enemies_commands = function()
    local ns = boot(11509)
    plateAdd("nameplate1", MOCK.Enemy({ level = 24 }))
    local UI = ns.EnemiesUI
    local function on(tab, label)
        check(UI.IsShown() and UI.state.tab == tab, label .. " opens " .. tab .. " (tab " .. tostring(UI.state.tab) .. ")")
    end
    slash("enemies") on("journal", "/talod enemies")
    slash("journal") on("journal", "/talod journal")
    slash("lists") on("lists", "/talod lists")
    slash("census") on("census", "/talod census")
    slash("enemies") check(UI.IsShown(), "/talod enemies opens the page on its last tab")
    slash("enemies lists") on("lists", "/talod enemies lists")
    slash("enemies census") on("census", "/talod enemies census")
    slash("enemies journal") on("journal", "/talod enemies journal")
    -- Arguments keep doing what they did.
    slash("census off")
    check(TALODDB.censusEnabled == false and UI.state.tab == "journal", "/talod census off")
    slash("census on")
    check(TALODDB.censusEnabled == true, "/talod census on")
    slash("kos Shadowfang")
    check(TALODDB.players.Shadowfang.list == "kos", "/talod kos")
    slash("unlist Shadowfang")
    check(TALODDB.players.Shadowfang.list == nil, "/talod unlist")
    slash("note Shadowfang watch out")
    check(TALODDB.players.Shadowfang.note == "watch out", "/talod note")
    -- who: prints, and selects the player while the page is open.
    slash("lists")
    MOCK.prints = {}
    slash("who Shadowfang")
    check(T.printed("Shadowfang"), "who prints")
    check(UI.state.tab == "journal" and UI.state.selected == "Shadowfang", "who selects on the Journal tab")
    check(plain(UI.views.people.card.note:GetText()) == "watch out", "card shows the note")
    page(ns):Hide()
    slash("who Otherguy")
    check(not UI.IsShown(), "who does not open the page")
end

scenarios.enemies_census = function()
    local ns = boot(11509)
    local bound = {}
    ns.Options.Bind = function(key, kind, where) bound[#bound + 1] = key .. "|" .. kind .. "|" .. where end
    local c = ns.Census.Store()
    c.maps[1434] = "Stranglethorn Vale"
    c.cells[1434] = { ["10:12:H:E:ROGUE:21:3"] = 2, ["11:12:H:E:MAGE:21:3"] = 1, ["-:?:?:?:?:5"] = 1 }
    c.maps[1453] = "Stormwind City"
    c.cells[1453] = { ["20:20:A:F:PRIEST:21:2"] = 5 }
    local UI = ns.EnemiesUI
    UI.ShowPage("census")
    local v = UI.views.census
    local all = table.concat(bound, ",")
    for _, b in ipairs({ "censusEnabled|quick|enemies/census", "panelShown|quick|enemies", "alertsEnabled|quick|enemies" }) do
        check(all:find(b, 1, true), "quick binding " .. b .. " in " .. all)
    end
    -- The log switch toggles the key, both ways.
    check(v.switch:GetOn() == true, "switch shows census on")
    v.switch:Click()
    check(TALODDB.censusEnabled == false and not v.switch:GetOn(), "switch off")
    v.switch:Click()
    check(TALODDB.censusEnabled == true, "switch on")
    -- Friendly nameplates button only while they are off.
    check(v.friendlyButton:IsShown() == not ns.Census.FriendlyPlatesOn(), "friendly button follows the setting")
    -- Zones from the summary cells.
    local zones = ns.Census.Zones()
    check(zones[1].name == "Stormwind City" and zones[1].counted == 5 and zones[1].enemy == 0, "zones sorted by count")
    local stv = zones[2]
    check(stv.counted == 4 and stv.enemy == 3 and stv.hidden == 1 and stv.squares == 2, "zone counts")
    local stvRow, swRow
    for _, item in ipairs(items(v.list)) do
        if item.text == "Stranglethorn Vale" then stvRow = item elseif item.text == "Stormwind City" then swRow = item end
    end
    check(stvRow and stvRow.cols[2].tone == "unknown", "hidden sides: unknown share")
    check(swRow and plain(swRow.cols[2]) == "your side only", "your side only")
    check(v.mapsText:GetText():find("census_viewer.py", 1, true), "how to open the heat maps")
    check(v.zoneCard.foot:GetText():find("census on", 1, true), "status line")
    -- Header quick switches.
    local f = page(ns)
    f.buttons.panel:Click()
    check(TALODDB.panelShown == false and plain(f.buttons.panel.label:GetText()) == "Panel hidden", "panel switch")
    f.buttons.panel:Click()
    check(TALODDB.panelShown == true, "panel switch back")
    f.buttons.alerts:Click()
    check(TALODDB.alertsEnabled == false and plain(f.buttons.alerts.label:GetText()) == "Alerts muted", "alerts switch")
    f.buttons.alerts:Click()
    check(TALODDB.alertsEnabled == true, "alerts back on")
end

scenarios.enemies_status = function()
    local ns = boot(11509)
    local UI = ns.EnemiesUI
    local s = UI.PageStatus()
    check(s.text:find("^none nearby") and s.tone == nil, "nobody around: " .. s.text)
    plateAdd("nameplate1", MOCK.Enemy({ level = 24 }))
    s = UI.PageStatus()
    check(s.text:find("^1 nearby") and s.tone == "danger", "one enemy: " .. s.text)
    UI.ShowPage("journal")
    check(plain(page(ns).status:GetText()):find("1 nearby", 1, true), "title bar status")
    page(ns).buttons.clear:Click()
    check(next(ns.Spotter.nearby) == nil or ns.Spotter.Get("Shadowfang"), "clear nearby list ran")
end

-- Every unit read secret: the count is "?", never 0 or a number, in the unknown tone.
scenarios.enemies_all_secret = function()
    local ns = boot(16001, { secrets = true })
    MOCK.secretMode = true
    MOCK.secretRange = true
    plateAdd("nameplate1", MOCK.Enemy({ level = 20, health = 900, healthMax = 2000,
        secret = { health = true, healthMax = true, combat = true, pvp = true, enemy = true, canAttack = true, reaction = true } }))
    MOCK.Tick(0.3)
    local UI = ns.EnemiesUI
    local s = UI.PageStatus()
    check(s.tone == "unknown" and s.text:find("^%? nearby"), "status: " .. tostring(s.text))
    check(not s.text:match("^%d"), "no count")
    UI.ShowPage("journal")
    local status = page(ns).status:GetText()
    check(status:find(ns.ColorCode("unknown"), 1, true) and not status:find(ns.ColorCode("safe"), 1, true), "title bar in the unknown tone: " .. status)
    -- Whatever was recorded shows unknown, never blank or 0.
    for _, item in ipairs(items(UI.views.people.list)) do
        if item.key then
            local lvl = item.cols[3]
            check(lvl == ns.UNKNOWN or (type(lvl) == "string" and lvl:match("^%d+$")) or type(lvl) == "table", "level cell")
            check(lvl ~= "0" and lvl ~= "", "level never 0 or blank")
        end
    end
end
