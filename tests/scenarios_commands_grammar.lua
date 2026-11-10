-- The command grammar (/talod <page> [tab | verb] [args]): every old word and
-- alias from the interface map still reaches the id and arguments it reached
-- before the grammar, every first word and short form resolves, help for one
-- page lists only that page, and the new canonical forms do what the old words do.
local scenarios, T = ...
local check, boot, slash = T.check, T.boot, T.slash

-- Word -> id as the one-word lookup resolved them before the page grammar.
local OLD = {
    ["settings"] = "settings", ["config"] = "settings", ["options"] = "settings", ["help"] = "help", ["menu"] = "menu",
    ["panel"] = "panel", ["alerts"] = "alerts", ["alert"] = "alerts", ["badges"] = "badges", ["flag"] = "flag",
    ["kos"] = "kos", ["avoid"] = "avoid", ["unlist"] = "unlist", ["note"] = "note", ["who"] = "who",
    ["journal"] = "journal", ["lists"] = "lists", ["distance"] = "distance", ["probe"] = "probe",
    ["errors"] = "errors", ["error"] = "errors", ["perf"] = "perf", ["clean"] = "clean", ["cleanup"] = "clean",
    ["archive"] = "archive", ["memory"] = "memory", ["data"] = "data", ["clear"] = "clear", ["reset"] = "reset",
    ["minimap"] = "minimap", ["version"] = "version", ["update"] = "version", ["pace"] = "pace",
    ["census"] = "census", ["char"] = "character", ["character"] = "character", ["gear"] = "gear",
    ["skills"] = "skills", ["enhance"] = "enhance", ["enchants"] = "enhance", ["plan"] = "plan",
    ["professions"] = "plan", ["prof"] = "plan", ["crafts"] = "crafts", ["crafting"] = "crafts",
    ["economy"] = "economy", ["gold"] = "economy", ["price"] = "price", ["prices"] = "price", ["market"] = "price",
    ["ah"] = "ah", ["desk"] = "ah", ["fish"] = "fish", ["fishing"] = "fish", ["guild"] = "guild", ["g"] = "guild",
    ["audit"] = "audit", ["groups"] = "groups", ["party"] = "groups", ["raid"] = "groups",
    ["changelog"] = "changelog", ["changes"] = "changelog", ["news"] = "changelog", ["credits"] = "credits",
    ["discord"] = "credits", ["donate"] = "credits",
}

local function loadMap()
    local dir = (EXTRA_SCENARIO_FILES[1] or ""):match("^(.*)/[^/]*$") or (ADDON_DIR .. "/tests")
    return assert(loadfile(dir .. "/ui_map.lua"))()
end

local SAMPLES = {
    ["<name|target>"] = "Somebody", ["<name>"] = "Somebody", ["<text>"] = "hi there", ["<x.y.z>"] = "0.30.0",
    ["<v>"] = "0.30.0", ["<item name>"] = "Linen Cloth", ["<item>"] = "Linen Cloth", ["<anything else>"] = "wobble",
}

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function words(s)
    local out = {}
    for w in s:gmatch("%S+") do out[#out + 1] = w end
    return out
end

-- "/talod alerts on|off" -> { "alerts on", "alerts off" } (what follows the prefix).
local function expand(text)
    text = trim(text:gsub("<[^>]*>", function(p) return SAMPLES[p] or "x" end))
    text = trim(text:gsub("%b[]", ""):gsub("%.%.%.", ""))
    if text:sub(1, 6) == "/click" then return {} end
    text = trim(text:gsub("^/talod", ""))
    local out = { "" }
    for _, tok in ipairs(words(text)) do
        local alts = {}
        if tok:find("|", 1, true) then
            for a in tok:gmatch("[^|]+") do alts[#alts + 1] = a end
        else
            alts[1] = tok
        end
        local nextOut = {}
        for _, base in ipairs(out) do
            for _, a in ipairs(alts) do nextOut[#nextOut + 1] = base == "" and a or (base .. " " .. a) end
        end
        out = nextOut
    end
    return out
end

local function replaceFirst(phrase, word)
    local _, rest = phrase:match("^(%S*)%s*(.-)$")
    return rest ~= "" and (word .. " " .. rest) or word
end

-- Every phrase an old word or alias of one map row stands for.
local function oldPhrases(row)
    local out = {}
    local main = row.old
    local parens = {}
    main = main:gsub("%b()", function(p) parens[#parens + 1] = p:sub(2, -2) return "" end)
    local bases = {}
    for alt in (main .. " | "):gmatch("(.-)%s+|%s+") do
        if trim(alt) ~= "" then
            for _, p in ipairs(expand(alt)) do bases[#bases + 1] = p out[#out + 1] = p end
        end
    end
    local function addAlias(a)
        a = trim(a)
        if a:sub(1, 6) == "/talod" then
            if a:find("%.%.%.") then
                local word = trim(a:gsub("^/talod", ""):gsub("%.%.%.", ""))
                for _, b in ipairs(bases) do out[#out + 1] = replaceFirst(b, word) end
            else
                for _, p in ipairs(expand(a)) do out[#out + 1] = p end
            end
        else
            local first = a:match("^(%S+)")
            if OLD[first] and a:find(" ") then
                for _, p in ipairs(expand(a)) do out[#out + 1] = p end
            elseif OLD[first] then
                for _, b in ipairs(bases) do out[#out + 1] = replaceFirst(b, a) end
            elseif not a:find(" ") then
                -- A sub-word alias (audit target -> refresh): the last word replaced.
                for _, b in ipairs(bases) do out[#out + 1] = (b:gsub("%S+$", a)) end
            end
        end
    end
    for _, p in ipairs(parens) do
        p = p:gsub("^aliases:%s*", ""):gsub("^alias:%s*", ""):gsub("^alias%s+", "")
        for piece in (p .. ","):gmatch("([^,;]+)[,;]") do addAlias(piece) end
    end
    for _, a in ipairs(row.aliases or {}) do addAlias(a) end
    return out
end

local function oldResult(phrase)
    local word, rest = phrase:match("^(%S*)%s*(.-)$")
    if word == "" then return "settings", "" end
    return OLD[word:lower()], rest
end

scenarios.commands_grammar_old_words = function()
    local ns = boot(11509)
    local Cmd = ns.Cmd
    local map = loadMap()
    local n = 0
    for _, row in ipairs(map.commands) do
        for _, phrase in ipairs(oldPhrases(row)) do
            local wantId, wantRest = oldResult(phrase)
            local id, rest, nav = Cmd.Parse(phrase)
            if phrase == "" then
                -- The one change: the prefix alone is the page list's entry point.
                check(id == "root" and rest == "", "bare prefix -> root")
            else
                check(wantId ~= nil, row.id .. ": '" .. phrase .. "' was an old word")
                check(id == wantId and rest == wantRest and nav == nil, row.id .. ": '" .. phrase .. "' -> " .. tostring(id)
                    .. " '" .. tostring(rest) .. "', was " .. tostring(wantId) .. " '" .. tostring(wantRest) .. "'")
                check(Cmd.Parse(phrase:upper()) == wantId, "case-insensitive: " .. phrase)
            end
            n = n + 1
        end
    end
    check(n > 150, "phrases checked: " .. n)
    -- Every old one-word lookup is unchanged.
    for word, id in pairs(OLD) do check(Cmd.Resolve(word) == id, "resolve " .. word) end
    -- The prefix alone opens the page list where you left it: Home the first time.
    slash("")
    check(TALODMainMenu and TALODMainMenu:IsShown(), "bare prefix opens Home")
    ns.Nav.Go("settings")
    TALODOptionsWindow:Hide()
    slash("")
    check(TALODOptionsWindow:IsShown(), "bare prefix reopens the last page")
end

scenarios.commands_grammar_first_words = function()
    local ns = boot(11509)
    local Cmd = ns.Cmd
    local map = loadMap()
    check(#Cmd.FIRST_WORDS == #map.first_words, "17 first words")
    for i, w in ipairs(map.first_words) do
        check(Cmd.FIRST_WORDS[i] == w, "first word " .. w)
        check(Cmd.FIRST[w], "grammar for " .. w)
        check(Cmd.Resolve(w) ~= nil and Cmd.Parse(w) ~= nil, "resolves " .. w)
    end
    for i, w in ipairs(map.short_forms) do
        check(Cmd.SHORT_FORMS[i] == w and Cmd.Resolve(w) == w, "short form " .. w)
        local id, rest = Cmd.Parse("enemies " .. w .. " Somebody here")
        check(id == w and rest == "Somebody here", "long form enemies " .. w)
    end
    -- Every canonical form of the map resolves to a command.
    for _, row in ipairs(map.commands) do
        for part in (row.canonical .. "  ·  "):gmatch("(.-)%s+·%s+") do
            for _, phrase in ipairs(expand(part)) do
                local id = Cmd.Parse(phrase)
                check(id ~= nil, row.id .. ": canonical '" .. phrase .. "' resolves")
            end
        end
    end
    -- Canonical forms land where the old words do.
    local same = {
        { "enemies panel lock", "panel", "lock" }, { "enemies alerts test", "alerts", "test" },
        { "enemies distance max", "distance", "max" }, { "enemies census allies on", "census", "allies on" },
        { "enemies lists", "lists", "" }, { "enemies clear", "clear", "" },
        { "debug errors clear", "errors", "clear" }, { "debug perf reset", "perf", "reset" },
        { "debug probe", "probe", "" }, { "debug version", "version", "status" }, { "debug pace reset", "pace", "reset" },
        { "data clean auto on", "clean", "auto on" }, { "data clean now", "clean", "now" },
        { "data archive load", "archive", "load" }, { "data memory", "memory", "" }, { "data clear", "data", "clear" },
        { "settings reset", "reset", "" }, { "settings minimap", "minimap", "" },
        { "about version", "version", "" }, { "about credits", "credits", "" }, { "about 0.30.0", "changelog", "0.30.0" },
        { "gear enhance", "enhance", "" }, { "gear snap Raid set", "gear", "snap Raid set" },
        { "prof skills", "skills", "" }, { "prof log", "crafts", "" }, { "prof tailoring 60-150", "plan", "tailoring 60-150" },
        { "ah prices", "price", "" }, { "ah price Linen Cloth", "price", "Linen Cloth" }, { "ah Linen Cloth", "ah", "Linen Cloth" },
        { "recruit who", "guild", "who" }, { "recruit invite Somebody", "guild", "invite Somebody" },
        { "recruit handsfree why", "guild", "handsfree why" }, { "recruit mini", "guild", "mini" },
        { "recruit invited", "guild", "invited" }, { "recruit results", "guild", "recruiters" },
        { "guild shared", "guild", "members" }, { "members promotions", "guild", "promotions" },
        { "audit flagged", "audit", "flags" }, { "audit guild", "audit", "members" }, { "audit everyone", "audit", "characters" },
        { "audit ledger", "audit", "ledger" },
        { "groups history parties", "groups", "parties" }, { "groups history raids", "groups", "raids" },
        { "groups history", "groups", "parties" },
        { "fish settings", "pagesettings", "fishing" }, { "recruit settings", "pagesettings", "guild" },
        { "debug settings", "pagesettings", "advanced" }, { "prof settings", "pagesettings", "professions" },
    }
    for _, s in ipairs(same) do
        local id, rest = Cmd.Parse(s[1])
        check(id == s[2] and rest == s[3], "'" .. s[1] .. "' -> " .. tostring(id) .. " '" .. tostring(rest) .. "'")
    end
    -- Hints show the canonical form, and it parses back to the same command.
    for _, c in ipairs(Cmd.LIST) do
        if #c.words > 0 and not c.aliasOf then
            local id = Cmd.Parse((Cmd.Text(c.id):gsub("^" .. Cmd.PREFIX .. "%s*", "")))
            check(id == c.id, "Cmd.Text(" .. c.id .. ") parses back: " .. tostring(id))
        end
    end
    check(Cmd.Text("panel", "lock") == Cmd.PREFIX .. " enemies panel lock", "canonical hint")
    check(Cmd.Text("guild", "invite <name>") == Cmd.PREFIX .. " guild invite <name>", "old hint kept")
    -- The data for About > Commands and Go to.
    local rows = Cmd.List()
    check(#rows > 60, "rows")
    for _, r in ipairs(rows) do
        check(r.id and r.page and r.canonical and r.help and r.aliases and r.words, "row fields " .. tostring(r.canonical))
    end
    local found = false
    for _, r in ipairs(Cmd.ForPage("enemies")) do
        check(r.page == "enemies", "ForPage only enemies")
        if r.canonical == Cmd.PREFIX .. " enemies panel on|off|lock|unlock|reset" then
            found = r.aliases[1] == Cmd.PREFIX .. " panel on|off|lock|unlock|reset"
        end
    end
    check(found, "panel row lists the old word as also")
end

local function linesAfter(n)
    local out = {}
    for i = n + 1, #MOCK.prints do out[#out + 1] = MOCK.prints[i] end
    return out
end

scenarios.commands_grammar_help = function()
    local ns = boot(11509)
    local Cmd = ns.Cmd
    -- help <page>: that page's lines, nothing else.
    for _, page in ipairs({ "enemies", "fish", "recruit", "debug", "about" }) do
        MOCK.prints = {}
        slash("help " .. page)
        local key = Cmd.PageFor(page)
        local allowed = {}
        for _, r in ipairs(Cmd.ForPage(key)) do allowed[Cmd.RowLine(r)] = true end
        local lines = linesAfter(1)
        check(#lines == #Cmd.ForPage(key) and #lines > 0, "help " .. page .. ": " .. #lines .. " lines")
        for _, line in ipairs(lines) do check(allowed[line], "help " .. page .. " printed only its own: " .. line) end
        for _, line in ipairs(MOCK.prints) do
            check(not line:find(ns.NAME .. " v" .. ns.VERSION, 1, true), "page help is not the full list")
        end
    end
    MOCK.prints = {}
    slash("help enemies")
    check(T.printed("/talod kos") and T.printed("also: /talod panel") and not T.printed("/talod fish"), "enemies help content")
    MOCK.prints = {}
    slash("help guild")
    check(T.printed("/talod guild %[roster") and not T.printed("/talod recruit who"), "guild = Members page help")
    -- Plain help: the whole list, grouped by page, canonical first.
    MOCK.prints = {}
    slash("help")
    check(T.printed(ns.NAME .. " v") and T.printed("^Enemies:") and T.printed("^Recruit:"), "full help grouped")
    check(T.printed("/talod debug errors %[clear%].*also: /talod errors %[clear%], /talod error %[clear%]"), "old words as also")
    -- Unknown page: the full list.
    MOCK.prints = {}
    slash("help nonsense")
    check(T.printed(ns.NAME .. " v"), "unknown page prints all")
    -- find: Go to with the matching commands (and pages, settings...).
    slash("find kill on sight")
    check(ns.Nav.GoToShown(), "find opens Go to")
    local kos, fish = false, false
    for _, e in ipairs(ns.Nav.Find("kill on sight")) do
        if e.kind == "Command" and e.label:find("/talod kos", 1, true) then kos = true end
        if e.kind == "Command" and e.label:find("/talod fish", 1, true) then fish = true end
    end
    check(kos and not fish, "find lists matches")
end

-- Canonical forms do what the old words do.
scenarios.commands_grammar_dispatch = function()
    local ns = boot(11509)
    local db = TALODDB

    slash("enemies panel lock")
    check(db.panelLocked == true, "enemies panel lock")
    slash("panel unlock")
    check(db.panelLocked == false, "panel unlock")
    slash("enemies panel off")
    check(db.panelShown == false, "enemies panel off")
    slash("enemies alerts off")
    check(db.alertsEnabled == false, "enemies alerts off")
    slash("alert on")
    check(db.alertsEnabled == true, "alert on")
    slash("enemies badges off")
    check(db.badgesEnabled == false, "badges off")

    db.errorLog = { { message = "x", version = ns.VERSION } }
    slash("debug errors clear")
    check(#db.errorLog == 0, "debug errors clear")

    slash("data clean auto on")
    check(db.cleanAuto == true, "data clean auto on")
    slash("cleanup auto off")
    check(db.cleanAuto == false, "cleanup auto off")

    local shown = db.minimapButton
    slash("settings minimap")
    check(db.minimapButton == not shown, "settings minimap toggles")
    slash("minimap")
    check(db.minimapButton == shown, "minimap toggles back")

    -- Recruiting: the same Guild call either way.
    local who = 0
    ns.Guild.Who = function() who = who + 1 end
    slash("recruit who")
    slash("guild who")
    slash("g who")
    check(who == 3, "recruit who = guild who")
    local mini = db.guildMiniShown
    slash("recruit mini")
    check(db.guildMiniShown == not mini, "recruit mini")

    -- Views: capture what the windows are asked to show.
    local asked = {}
    local function capture(tbl, name)
        tbl[name] = function(v) asked[#asked + 1] = tostring(v) end
    end
    local GS = ns.GroupsUI.state
    slash("groups history raids")
    check(GS.view == "history" and GS.chip == "raid", "groups history raids: " .. tostring(GS.view) .. "/" .. tostring(GS.chip))
    slash("groups parties")
    check(GS.view == "history" and GS.chip == "party", "groups parties: " .. tostring(GS.chip))
    slash("groups raids")
    check(GS.view == "history" and GS.chip == "raid", "groups raids: " .. tostring(GS.chip))
    slash("groups history")
    check(GS.view == "history", "groups history opens History")
    asked = {}
    capture(ns.AuditUI, "Show")
    capture(ns.AuditUI, "Toggle")
    slash("audit flagged")
    slash("audit flags")
    slash("audit everyone")
    slash("audit ledger")
    check(table.concat(asked, ",") == "flags,flags,characters,ledger", "audit words: " .. table.concat(asked, ","))
    -- Tabs open through the page list (Show), old words as before (Toggle).
    asked = {}
    capture(ns.GearUI, "Toggle")
    capture(ns.ProfessionsUI, "Toggle")
    capture(ns.GearUI, "Show")
    capture(ns.ProfessionsUI, "Show")
    capture(ns.GearUI, "ShowPage")
    capture(ns.ProfessionsUI, "ShowPage")
    slash("prof log")
    slash("crafts")
    slash("prof skills")
    slash("gear enhance")
    check(table.concat(asked, ",") == "log,log,skills,enhance", "character tabs: " .. table.concat(asked, ","))
    asked = {}
    capture(ns.MarketUI, "Toggle")
    capture(ns.MarketUI, "Show")
    capture(ns.MarketUI, "ShowPage")
    slash("ah prices")
    slash("market")
    check(#asked == 2 and asked[1] == "prices", "ah prices = market: " .. table.concat(asked, ","))

    -- Without a page list the Enemies words open the Enemies page itself.
    local tabs = {}
    capture(ns.EnemiesUI, "ShowPage")
    for _, word in ipairs({ "enemies", "journal", "enemies lists", "lists", "census", "enemies census" }) do
        asked = {}
        slash(word)
        tabs[#tabs + 1] = tostring(asked[1])
    end
    check(table.concat(tabs, ",") == "nil,journal,lists,lists,census,census", "enemies (last tab), journal...: " .. table.concat(tabs, ","))
    slash("home")
    check(TALODMainMenu and TALODMainMenu:IsShown(), "home opens the main menu")
    slash("menu")
    check(not TALODMainMenu:IsShown(), "menu toggles it closed")
    -- About opens on its last tab: What's new the first time.
    slash("about")
    check(TALODChangelogWindow and TALODChangelogWindow:IsShown(), "about opens the changelog")
    slash("about credits")
    check(ns.Credits.IsShown(), "about credits")
    slash("credits")
    check(not ns.Credits.IsShown(), "credits toggles closed")
    MOCK.prints = {}
    slash("about 9.9.9")
    check(T.printed("No notes for version 9.9.9"), "about <version>")

    capture(ns.GuildUI, "Toggle")
    capture(ns.GuildUI, "Show")
    asked = {}
    slash("recruit")
    slash("members")
    slash("recruit results")
    check(table.concat(asked, ",") == "recruit,roster,recruiters", "recruit / members fall back: " .. table.concat(asked, ","))

    -- Version status and whisper pace from their new homes.
    local texts = {}
    ns.Probe.ShowText = function(t) texts[#texts + 1] = t end
    slash("debug version")
    slash("version status")
    check(#texts == 2 and texts[1] == texts[2], "debug version = version status")
    MOCK.prints = {}
    slash("debug pace")
    check(T.printed("at most"), "debug pace")

    -- Settings: the whole window without sections, a section when there are.
    slash("settings alerts")
    check(TALODOptionsWindow:IsShown(), "settings <words> opens settings")
    local sections = {}
    ns.Options.OpenSection = function(key, search) sections[#sections + 1] = tostring(key) .. "|" .. tostring(search) end
    slash("enemies settings")
    slash("settings alerts and safety")
    slash("settings fish")
    slash("settings nameplate distance")
    slash("debug")
    check(table.concat(sections, ",") == "enemies|nil,alerts|nil,fishing|nil,nil|nameplate distance,advanced|nil",
        "sections: " .. table.concat(sections, ","))
end

-- With a page list: page words, tabs, Go to and the prefix alone go through it.
scenarios.commands_grammar_nav_hooks = function()
    local ns = boot(11509)
    local went, gotoText = {}, nil
    local answer = true
    ns.Nav.Go = function(page, tab) went[#went + 1] = tostring(page) .. "/" .. tostring(tab) return answer end
    ns.Nav.GoTo = function(text) gotoText = text end
    local tabs = 0
    ns.Options.OpenTab = function() tabs = tabs + 1 end
    slash("")
    slash("enemies")
    slash("recruit invited")
    slash("about")
    slash("home")
    slash("gold trades")
    slash("help")
    check(table.concat(went, ",") == "nil/nil,enemies/nil,recruit/invited,about/nil,home/nil,gold/trades,about/commands",
        "went: " .. table.concat(went, ","))
    check(tabs == 0 and not (TALODOptionsWindow and TALODOptionsWindow:IsShown()), "nothing else opened")
    slash("find linen")
    check(gotoText == "linen", "find = Go to")
    -- Old words keep their own route; the Enemies words open its tabs.
    went = {}
    slash("journal")
    slash("guild invited")
    check(table.concat(went, ",") == "enemies/journal" and tabs == 0, "old words: " .. table.concat(went, ","))
    -- A page list that cannot open it: the page itself.
    answer = false
    went = {}
    slash("enemies")
    check(#went == 2 and tabs == 0 and ns.EnemiesUI.IsShown(), "falls back when the page list cannot")
    slash("")
    check(TALODOptionsWindow and TALODOptionsWindow:IsShown(), "bare prefix falls back to settings")
end
