-- Every slash command, in one place: the prefix players type, the words for
-- each command, and the help lines /talod help prints. Loads right after Brand.lua.
--
-- Grammar: /talod <page> [tab | verb] [arguments]. The first word names a page
-- (FIRST), the second one of its tabs or something it does (its subs). Every
-- older word keeps working: it resolves to the same id as before, with the same
-- arguments, so a module's slash handler never sees a difference.
--
-- Editing:
--   * PREFIX is what every hint shows ("/talod"); ALIASES also work. The game
--     allows at most a handful of slash words per addon; keep them short.
--   * words: what players typed before the page grammar (all still work). Two
--     commands must not share a word.
--   * path: the canonical words after the prefix ("enemies panel"); hints
--     (Cmd.Text) and help show it. Without one, the first word is canonical.
--   * id: the name the code knows the command by. Never shown; do not change it
--     (Main.lua and the modules' Slash functions compare against it).
--   * page: the page whose help lists it (PAGES).
--   * help: { args, what it does } lines for /talod help. A line may carry its
--     own path / page (guild invite is listed under Recruit) and old = the
--     arguments it was typed with after the old word, when they differ.
--   * aliasOf: the command whose help line already shows this one's canonical
--     form; this one's words are listed there as "also".
--   * open: a page word: { page, tab } opens through the page list when there is
--     one, else runs { id, rest } (the window that holds that content today).
--   * bare = true: the prefix alone runs this command.

local ADDON_NAME, ns = ...

local Cmd = {}
ns.Cmd = Cmd

Cmd.PREFIX = "/talod"
Cmd.ALIASES = {}

-- Pages in help order. section: the page's part of the Settings page.
Cmd.PAGES = {
    { key = "home", label = "Home", section = "general" },
    { key = "enemies", label = "Enemies", section = "enemies" },
    { key = "fishing", label = "Fishing", section = "fishing" },
    { key = "groups", label = "Groups", section = "groups" },
    { key = "gear", label = "Gear", section = "gear" },
    { key = "prof", label = "Professions", section = "professions" },
    { key = "gold", label = "Gold", section = "gold" },
    { key = "ah", label = "Auction House", section = "ah" },
    { key = "recruit", label = "Recruit", section = "guild" },
    { key = "members", label = "Members", section = "guild" },
    { key = "audit", label = "Audit", section = "audit" },
    { key = "settings", label = "Settings", section = "general" },
    { key = "data", label = "Data", section = "data" },
    { key = "debug", label = "Debug", section = "advanced" },
    { key = "about", label = "About" },
}

-- The Settings page's sections (what /talod settings <name> jumps to).
Cmd.SECTIONS = {
    { key = "general", label = "General" }, { key = "enemies", label = "Enemies" },
    { key = "alerts", label = "Alerts and safety" }, { key = "fishing", label = "Fishing" },
    { key = "groups", label = "Groups" }, { key = "gear", label = "Gear" },
    { key = "professions", label = "Professions" }, { key = "gold", label = "Gold" },
    { key = "ah", label = "Auction House" }, { key = "guild", label = "Guild" },
    { key = "audit", label = "Audit" }, { key = "data", label = "Data" },
    { key = "advanced", label = "Advanced" },
}

Cmd.LIST = {
    -- Home, help, Go to (Main.lua, Navigation.lua)
    { id = "root", page = "home", words = {}, path = "", bare = true,
        help = { { "", "open " .. ns.NAME .. " where you left it" } } },
    { id = "home", page = "home", words = { "home" }, open = { page = "home", id = "menu" },
        help = { { "", "Home: every page, what is on screen" } } },
    { id = "menu", page = "home", words = { "menu" }, path = "home", aliasOf = "home" },
    { id = "find", page = "home", words = { "find" }, help = { { "<text>", "Go to: pages, tabs, settings and commands matching the text" } } },
    { id = "help", page = "about", words = { "help" }, help = { { "[page]", "this list, or one page's commands" } } },

    -- Enemies (Main.lua, Journal.lua, Census.lua)
    { id = "enemies", page = "enemies", words = { "enemies" }, open = { page = "enemies", id = "journal" },
        help = { { "", "the journal of enemies you met" } } },
    { id = "journal", page = "enemies", words = { "journal" }, path = "enemies", aliasOf = "enemies" },
    { id = "lists", page = "enemies", words = { "lists" }, path = "enemies lists", help = { { "", "your kill-on-sight and avoid lists" } } },
    { id = "kos", page = "enemies", words = { "kos" }, long = "enemies kos", help = { { "<name|target>", "add a player to kill on sight" } } },
    { id = "avoid", page = "enemies", words = { "avoid" }, long = "enemies avoid", help = { { "<name|target>", "add a player to avoid" } } },
    { id = "unlist", page = "enemies", words = { "unlist" }, long = "enemies unlist", help = { { "<name>", "take a player off your lists" } } },
    { id = "note", page = "enemies", words = { "note" }, long = "enemies note", help = { { "<name> <text>", "note on a player (no text clears it)" } } },
    { id = "who", page = "enemies", words = { "who" }, long = "enemies who", help = { { "<name>", "what your journal knows about a player" } } },
    { id = "panel", page = "enemies", words = { "panel" }, path = "enemies panel", help = { { "on|off|lock|unlock|reset", "enemies-nearby panel" } } },
    { id = "clear", page = "enemies", words = { "clear" }, path = "enemies clear", help = { { "", "empty the nearby list" } } },
    { id = "alerts", page = "enemies", words = { "alerts", "alert" }, path = "enemies alerts", help = { { "on|off|test", "enemy spotted alerts" } } },
    { id = "badges", page = "enemies", words = { "badges" }, path = "enemies badges", help = { { "on|off", "nameplate badges" } } },
    { id = "flag", page = "enemies", words = { "flag" }, path = "enemies flag", help = { { "on|off|reset", "PvP flag indicator" } } },
    { id = "distance", page = "enemies", words = { "distance" }, path = "enemies distance",
        help = { { "[max]", "show or maximize nameplate distance (detection reach)" } } },
    { id = "census", page = "enemies", words = { "census" }, path = "enemies census", help = {
        { "[on|off]", "player census for heat maps (status without argument)" },
        { "allies on|off", "include your own faction" },
        { "friendly", "turn on friendly nameplates" },
        { "clear", "delete all census data" },
    } },

    -- Fishing (Fishing.lua and its helpers)
    { id = "fish", page = "fishing", words = { "fish", "fishing" }, help = {
        { "", "fishing window (spots, heat map, log, sessions)" },
        { "now|spots|map|log|sessions|goals", "open the fishing window on that tab" },
        { "stats", "this session and this spot in chat" },
        { "autoloot [on|off]", "auto loot on while fishing, your setting back after" },
        { "splash [on|off]", "loud splash: sound effects up, music off while fishing" },
        { "sound [reset|default]", "check the sound settings; put back your usual / the game's defaults" },
        { "hud | hud reset | end | on|off | clear", "HUD, end the session, logging, delete" },
        { "gear", "your fishing gear and lures in chat" },
        { "goals", "fishing goals: notable catches, Extravaganza clock" },
        { "zone", "the zone's fishing level against your skill" },
        { "safety [on|off]", "fishing safety: pole warning, targeting you, nearest range, swap button" },
    } },

    -- Groups.lua
    { id = "groups", page = "groups", words = { "groups", "party", "raid" }, help = {
        { "[now|history [parties|raids]]", "your parties and raids: who, where, how long, chat, loot", old = "[now|parties|raids]" } } },

    -- Character (Gear.lua, Enhance.lua, Skills.lua, Professions.lua)
    { id = "gear", page = "gear", words = { "gear" }, help = {
        { "", "the character window on the gear tab" },
        { "snap [name]", "take a named snapshot of what you wear" },
        { "status|on|off", "gear ledger status, or turn it on / off" },
    } },
    { id = "character", page = "gear", words = { "char", "character" }, help = { { "", "character window: gear, ledger, progress, sources, skills" } } },
    { id = "enhance", page = "gear", words = { "enhance", "enchants" }, path = "gear enhance", help = { { "", "what you can put on your gear and what it takes" } } },
    { id = "plan", page = "prof", words = { "plan", "professions", "prof" }, path = "prof", help = {
        { "[profession] [[from-]skill]", "profession leveling plan (e.g. tailoring 150, or 60-150)" } } },
    { id = "skills", page = "prof", words = { "skills" }, path = "prof skills", help = { { "", "the character window on the skills tab" } } },
    { id = "crafts", page = "prof", words = { "crafts", "crafting" }, path = "prof log", help = { { "", "your crafting log" } } },

    -- Money and the Auction House (Economy.lua, Prices.lua, AuctionDesk.lua, AHHelper.lua)
    { id = "economy", page = "gold", words = { "economy", "gold" }, path = "gold", help = { { "", "the gold window: money, auctions, trades (all characters)" } } },
    { id = "ah", page = "ah", words = { "ah", "desk" }, help = {
        { "[item]", "the Auction desk: your listings, deals, margins, buyout and control costs" },
        { "scan", "the scan panel (full scan, search list); opens by itself at the AH" },
        { "log", "every full scan: done (with counts) or why it failed" },
    } },
    { id = "price", page = "ah", words = { "price", "prices", "market" }, path = "ah prices", help = {
        { "[item]", "the Market window (prices you have seen, selling, crafting profit, deals)" } } },

    -- Guild (Guild.lua, Audit.lua)
    { id = "recruit", page = "recruit", words = { "recruit" }, open = { page = "recruit", id = "guild", rest = "recruit" },
        help = { { "", "the recruit list (players without a guild near you)" } } },
    { id = "members", page = "members", words = { "members" }, open = { page = "members", id = "guild", rest = "roster" },
        help = { { "", "the guild roster" } } },
    { id = "guild", page = "members", words = { "guild", "g" }, help = {
        { "[roster|activity|shared|promotions|log|sharing]", "guild window", old = "[roster|activity|members|promote|promotions|log|sharing]" },
        { "[find|invited|results]", "the recruit tabs", path = "recruit", page = "recruit", old = "[recruit|invited|replies|recruiters]" },
        { "mini", "show / hide the mini recruit window", path = "recruit", page = "recruit" },
        { "who", "one /who search for players without a guild (your level range)", path = "recruit", page = "recruit" },
        { "handsfree", "Hands Free on / off: a click on the open world is the next recruit click", path = "recruit", page = "recruit" },
        { "handsfree why", "what Hands Free did with your last clicks, and why not", path = "recruit", page = "recruit" },
        { "next", "one recruit step: the next queued invite, else /who, else the next whisper (for macros; on WoW Forever: the next whisper, else /who)", path = "recruit", page = "recruit" },
        { "key", "set the recruit key: press the key or mouse button for one recruit step", path = "recruit", page = "recruit" },
        { "invite [name]", "whisper + guild invite to one player (or your target); on WoW Forever the whisper only, you type /ginvite", path = "recruit", page = "recruit" },
        { "check", "opens a copyable report of your invites of the last hour: confirmed by the game, answered, unconfirmed", path = "recruit", page = "recruit" },
    } },
    { id = "audit", page = "audit", words = { "audit" }, help = {
        { "[me|target|guild|flagged|everyone|ledger|history|status]", "statistics ledger: members' gold and activity, flags",
            old = "[me|target|members|flags|characters|history|status]" } } },

    -- Settings, Data, Debug (Main.lua, Options.lua, Store.lua, Cleanup.lua, Outbox.lua, Version.lua)
    { id = "settings", page = "settings", words = { "settings", "config", "options" },
        help = { { "[section|words]", "open settings (a section name jumps there, other words search)", old = "" } } },
    { id = "pagesettings", page = "settings", words = {}, path = "<page> settings", help = { { "", "open Settings at that page's section", old = false } } },
    { id = "reset", page = "settings", words = { "reset" }, path = "settings reset", help = { { "", "reset settings and positions (all your logged data is kept)" } } },
    { id = "minimap", page = "settings", words = { "minimap" }, path = "settings minimap", help = { { "", "show / hide the minimap button" } } },
    { id = "data", page = "data", words = { "data" }, help = { { "[clear]", "saved data: stores by character, tamper seals, set-aside entries (clear deletes those)" } } },
    { id = "clean", page = "data", words = { "clean", "cleanup" }, path = "data clean", help = {
        { "", "what each cleanup rule would remove now" },
        { "now", "run the cleanup rules that are on" },
        { "auto on|off", "clean up once a day after login" } } },
    { id = "archive", page = "data", words = { "archive" }, path = "data archive", help = {
        { "", "archive addon: state and what waits for it" },
        { "load", "load the archive (stays in memory until /reload)" },
        { "move", "load it and move what the cleanup rules would remove" } } },
    { id = "memory", page = "data", words = { "memory" }, path = "data memory", help = { { "", "memory used by " .. ns.NAME .. ", your cap and the largest stores" } } },
    { id = "debug", page = "debug", words = { "debug" }, help = { { "", "these commands (and Settings > Advanced)" } } },
    { id = "probe", page = "debug", words = { "probe" }, path = "debug probe", help = { { "", "what this client lets addons read (target an enemy player)" } } },
    { id = "errors", page = "debug", words = { "errors", "error" }, path = "debug errors", help = { { "[clear]", "copyable list of " .. ns.NAME .. " errors (for bug reports)" } } },
    { id = "perf", page = "debug", words = { "perf" }, path = "debug perf", help = { { "[reset]", "copyable list of the slowest " .. ns.NAME .. " work this session (redraws, builds, events)" } } },
    { id = "pace", page = "debug", words = { "pace" }, path = "debug pace", help = { { "[reset]", "whisper limit learned from the game's throttle (reset forgets it)" } } },

    -- About (Changelog.lua, Credits.lua, Version.lua)
    { id = "about", page = "about", words = { "about" }, open = { page = "about", id = "changelog" }, help = {
        { "[version]", "what changed in each version (copyable notes)" } } },
    { id = "changelog", page = "about", words = { "changelog", "changes", "news" }, path = "about", aliasOf = "about" },
    { id = "credits", page = "about", words = { "credits", "discord", "donate" }, path = "about credits", help = { { "", "credits, the Discord invite, how to send gold" } } },
    { id = "version", page = "about", words = { "version", "update" }, path = "about version", help = {
        { "", "your version, whether a newer one is out, and how to update" },
        { "", "what the version check sees (channel, messages, notes)", path = "debug version", page = "debug", old = "status" } } },
}

-- Lines /talod help prints after the commands (things that are not /talod commands).
Cmd.EXTRA_HELP = {
    { "/click " .. ns.FRAME .. "FishingSwapButton", "(macro / keybind) swap the fishing pole for your weapon", page = "fishing" },
    { "/click " .. ns.FRAME .. "FishingLureButton", "(macro / keybind) put a lure on your fishing pole", page = "fishing" },
    { "/click " .. ns.FRAME .. "AHNextButton", "(macro / keybind) the scan panel's next search at the Auction House", page = "ah" },
}

-- The page words and what their second word means. A sub is an id (the
-- arguments after it are the command's), { id, rest } (rest is put in front of
-- the arguments: the module's own word for it), with tab = the page's tab to
-- open through the page list, or a function(more) -> id, rest. other(rest)
-- handles any other second word.
local function Tab(tab, id, rest) return { tab = tab, id = id, rest = rest } end

Cmd.FIRST = {
    home = { page = "home" },
    find = {},
    help = {},
    enemies = { page = "enemies", subs = {
        journal = Tab("journal", "journal"), lists = Tab("lists", "lists"), census = "census",
        kos = "kos", avoid = "avoid", unlist = "unlist", note = "note", who = "who",
        panel = "panel", clear = "clear", alerts = "alerts", alert = "alerts", badges = "badges", flag = "flag",
        distance = "distance" } },
    fish = { page = "fishing" },
    groups = { page = "groups", subs = {
        history = function(more)
            if more == "" then return "groups", "parties", { page = "groups", tab = "history" } end
            return "groups", more
        end } },
    gear = { page = "gear", subs = {
        enhance = Tab("enhance", "enhance"), gear = Tab("gear", "gear", "gear"),
        ledger = Tab("ledger", "gear", "ledger"), progress = Tab("progress", "gear", "progress") } },
    prof = { page = "prof", subs = {
        plan = Tab("plan", "plan"), skills = Tab("skills", "skills"), log = Tab("log", "crafts"),
        crafts = "crafts", profit = Tab("profit", "plan", "profit") } },
    gold = { page = "gold", subs = {
        overview = Tab("overview", "economy", "overview"), transactions = Tab("transactions", "economy", "transactions"),
        trades = Tab("trades", "economy", "trades") } },
    ah = { page = "ah", subs = {
        prices = Tab("prices", "price"), price = "price",
        today = Tab("today", "ah", "today"), buy = Tab("buy", "ah", "buy"), sell = Tab("sell", "ah", "sell"),
        mine = Tab("mine", "ah", "mine") } },
    recruit = { page = "recruit", subs = {
        find = Tab("find", "guild", "recruit"), invited = Tab("invited", "guild", "invited"),
        results = Tab("results", "guild", "recruiters"), replies = Tab("invited", "guild", "replies"),
        recruiters = Tab("results", "guild", "recruiters"),
        mini = { id = "guild", rest = "mini" }, who = { id = "guild", rest = "who" },
        handsfree = { id = "guild", rest = "handsfree" }, next = { id = "guild", rest = "next" },
        key = { id = "guild", rest = "key" }, invite = { id = "guild", rest = "invite" },
        check = { id = "guild", rest = "check" }, pace = { id = "guild", rest = "pace" } } },
    guild = { page = "members", subs = { shared = { id = "guild", rest = "members" } } },
    members = { page = "members", subs = {
        roster = Tab("roster", "guild", "roster"), promotions = Tab("promotions", "guild", "promotions"),
        log = Tab("log", "guild", "log"), sharing = Tab("sharing", "guild", "sharing"),
        activity = { id = "guild", rest = "activity" }, shared = { id = "guild", rest = "members" } } },
    audit = { page = "audit", subs = {
        flagged = { id = "audit", rest = "flags" }, guild = { id = "audit", rest = "members" },
        everyone = { id = "audit", rest = "characters" } } },
    settings = { page = "settings", subs = { reset = "reset", minimap = "minimap" } },
    data = { page = "data", subs = { clean = "clean", cleanup = "clean", archive = "archive", memory = "memory" } },
    debug = { page = "debug", subs = {
        probe = "probe", errors = "errors", error = "errors", perf = "perf", pace = "pace",
        version = { id = "version", rest = "status" } } },
    about = { page = "about",
        subs = { credits = Tab("credits", "credits"), version = "version", commands = Tab("commands", "help"),
            changelog = Tab("changelog", "changelog"), news = Tab("changelog", "changelog") },
        other = function(rest) return "changelog", rest end },
}

-- The documented first words and short forms, in help order.
Cmd.FIRST_WORDS = { "home", "find", "help", "enemies", "fish", "groups", "gear", "prof", "gold", "ah", "recruit", "guild",
    "audit", "settings", "data", "debug", "about" }
Cmd.SHORT_FORMS = { "kos", "avoid", "unlist", "note", "who" }

local byId, byWord, bareId = {}, {}, nil
for _, c in ipairs(Cmd.LIST) do
    byId[c.id] = c
    if c.bare then bareId = c.id end
    for _, w in ipairs(c.words) do byWord[w:lower()] = c.id end
end

local pageByKey = {}
for _, p in ipairs(Cmd.PAGES) do pageByKey[p.key] = p end

-- Every slash word the game should register (the prefix, then the aliases).
function Cmd.Slashes()
    local out = { Cmd.PREFIX }
    for _, a in ipairs(Cmd.ALIASES) do out[#out + 1] = a end
    return out
end

function Cmd.Get(id) return byId[id] end

-- The id for one word typed after the prefix, or nil ("" = the prefix alone).
function Cmd.Resolve(word)
    word = (word or ""):lower()
    if word == "" then return bareId end
    return byWord[word]
end

local function Join(a, b)
    if not a or a == "" then return b end
    if b == "" then return a end
    return a .. " " .. b
end

-- What the player typed after the prefix -> id, the arguments for it, and
-- { page, tab } when a page list should open it first (Main falls back to the
-- id when it cannot). Old words come back exactly as Resolve + the rest.
function Cmd.Parse(msg)
    local word, rest = (msg or ""):match("^(%S*)%s*(.-)$")
    word, rest = (word or ""):lower(), rest or ""
    local first = Cmd.FIRST[word]
    if first and rest ~= "" then
        local sub, more = rest:match("^(%S*)%s*(.-)$")
        local key = sub:lower()
        local page = first.page and pageByKey[first.page]
        if key == "settings" and more == "" and page and page.section and word ~= "settings" then
            return "pagesettings", page.section
        end
        local s = first.subs and first.subs[key]
        if type(s) == "function" then return s(more) end
        if type(s) == "string" then return s, more end
        if s then
            local nav = (s.tab and more == "") and { page = first.page, tab = s.tab } or nil
            return s.id, Join(s.rest, more), nav
        end
        if first.other then return first.other(rest) end
    end
    return Cmd.Resolve(word), rest
end

-- What to type, for hints: Cmd.Text("guild", "invite <name>") -> "/talod guild invite <name>".
function Cmd.Text(id, args)
    local c = byId[id]
    local path = c and (c.path or c.words[1]) or id
    local text = path ~= "" and (Cmd.PREFIX .. " " .. path) or Cmd.PREFIX
    if args and args ~= "" then text = text .. " " .. args end
    return text
end

-- A page key for what follows /talod help: a page key, its label, or a page word.
function Cmd.PageFor(text)
    text = (text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end
    if pageByKey[text] then return text end
    for _, p in ipairs(Cmd.PAGES) do
        if p.label:lower() == text then return p.key end
    end
    local first = Cmd.FIRST[text]
    if first and first.page then return first.page end
    local c = byId[byWord[text] or ""]
    return c and c.page or nil
end

function Cmd.PageLabel(key) return pageByKey[key] and pageByKey[key].label or key end

---------------------------------------------------------------------------
-- Rows: one per help line, for help, About > Commands and Go to.
-- { id, page, words, canonical, usage, help, aliases }
---------------------------------------------------------------------------
local rows

local function Typed(word, args)
    return Cmd.PREFIX .. " " .. word .. ((args and args ~= "") and (" " .. args) or "")
end

local function BuildRows()
    local out, folded = {}, {}
    for _, c in ipairs(Cmd.LIST) do
        if c.aliasOf then
            folded[c.aliasOf] = folded[c.aliasOf] or {}
            for _, w in ipairs(c.words) do table.insert(folded[c.aliasOf], w) end
        end
    end
    for _, c in ipairs(Cmd.LIST) do
        for i, h in ipairs(c.help or {}) do
            local args, path = h[1], h.path or c.path or c.words[1] or ""
            local usage = (path ~= "" and path or "") .. ((args ~= "") and ((path ~= "" and " " or "") .. args) or "")
            local canonical = usage ~= "" and (Cmd.PREFIX .. " " .. usage) or Cmd.PREFIX
            local aliases, seen = {}, { [canonical] = true }
            local function Add(text)
                if not seen[text] then seen[text] = true aliases[#aliases + 1] = text end
            end
            -- A synonym of the canonical word (fishing for fish) is listed on the first line only.
            local synonymsOnly = i > 1 and not c.path and not h.path and not h.old
            if h.old ~= false and not synonymsOnly then
                local oldArgs = h.old or args
                for _, w in ipairs(c.words) do
                    -- The canonical word itself is no old word, unless it took other arguments.
                    if w ~= path or (oldArgs ~= args and oldArgs ~= "") then Add(Typed(w, oldArgs)) end
                end
                if i == 1 then
                    for _, w in ipairs(folded[c.id] or {}) do Add(Typed(w, oldArgs)) end
                end
                if c.long then Add(Typed(c.long, args)) end
            end
            out[#out + 1] = { id = c.id, page = h.page or c.page, words = c.words, canonical = canonical, usage = usage,
                help = h[2], aliases = aliases }
        end
    end
    for _, h in ipairs(Cmd.EXTRA_HELP) do
        out[#out + 1] = { id = "macro", page = h.page, words = {}, canonical = h[1], usage = h[1], help = h[2], aliases = {}, macro = true }
    end
    -- Page order (stable within a page).
    local order = {}
    for i, p in ipairs(Cmd.PAGES) do order[p.key] = i end
    for i, r in ipairs(out) do r.n = i end
    table.sort(out, function(a, b)
        local pa, pb = order[a.page] or 99, order[b.page] or 99
        if pa ~= pb then return pa < pb end
        return a.n < b.n
    end)
    return out
end

function Cmd.List()
    rows = rows or BuildRows()
    return rows
end

function Cmd.ForPage(page)
    local out = {}
    for _, r in ipairs(Cmd.List()) do
        if r.page == page then out[#out + 1] = r end
    end
    return out
end

-- Rows whose command, old words or help text contain every word of text.
function Cmd.Find(text)
    local needles = {}
    for w in (text or ""):lower():gmatch("%S+") do needles[#needles + 1] = w end
    local out = {}
    if #needles == 0 then return out end
    for _, r in ipairs(Cmd.List()) do
        local hay = (r.canonical .. " " .. table.concat(r.aliases, " ") .. " " .. (r.help or "") .. " "
            .. Cmd.PageLabel(r.page)):lower()
        local all = true
        for _, n in ipairs(needles) do
            if not hay:find(n, 1, true) then all = false break end
        end
        if all then out[#out + 1] = r end
    end
    return out
end

local function HelpLine(usage, what)
    if not what then return "  " .. usage end
    return string.format("  %-26s - %s", usage, what)
end

-- One chat line per row: the canonical form, then the old words as "also".
function Cmd.RowLine(r)
    local what = r.help
    if #r.aliases > 0 then what = what .. "  (also: " .. table.concat(r.aliases, ", ") .. ")" end
    return HelpLine(r.canonical, what)
end

-- Every line, grouped by page under its name.
function Cmd.HelpLines(page)
    local lines, last = {}, nil
    for _, r in ipairs(page and Cmd.ForPage(page) or Cmd.List()) do
        if r.page ~= last then
            last = r.page
            lines[#lines + 1] = Cmd.PageLabel(r.page) .. ":"
        end
        lines[#lines + 1] = Cmd.RowLine(r)
    end
    return lines
end
