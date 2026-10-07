-- Every slash command, in one place: the prefix players type, the words for
-- each command, and the help lines /talod help prints. Loads right after Brand.lua.
--
-- Editing:
--   * PREFIX is what every hint shows ("/talod"); ALIASES also work. The game
--     allows at most a handful of slash words per addon; keep them short.
--   * words: what players type after the prefix. The first is the one shown in
--     help and in hints across the addon ("type /talod guild invite ..."); the
--     rest are aliases. Rename or add freely; two commands must not share a word.
--   * id: the name the code knows the command by. Never shown; do not change it
--     (Main.lua and the modules' Slash functions compare against it).
--   * help: { args, what it does } lines for /talod help. The words after the
--     command (sub-commands like "guild invite") are parsed by the module's own
--     Slash function; change them there and here together.
--   * bare = true: the prefix alone runs this command.

local ADDON_NAME, ns = ...

local Cmd = {}
ns.Cmd = Cmd

Cmd.PREFIX = "/talod"
Cmd.ALIASES = {}

Cmd.LIST = {
    -- Core (Main.lua)
    { id = "settings", words = { "settings", "config", "options" }, bare = true,
        help = { { "", "open settings" } } },
    { id = "help", words = { "help" }, help = { { "", "this list" } } },
    { id = "menu", words = { "menu" }, help = { { "", "main menu (every " .. ns.NAME .. " window)" } } },
    { id = "panel", words = { "panel" }, help = { { "on|off|lock|unlock|reset", "enemies-nearby panel" } } },
    { id = "alerts", words = { "alerts", "alert" }, help = { { "on|off|test", "enemy spotted alerts" } } },
    { id = "badges", words = { "badges" }, help = { { "on|off", "nameplate badges" } } },
    { id = "flag", words = { "flag" }, help = { { "on|off|reset", "PvP flag indicator" } } },
    { id = "kos", words = { "kos" }, help = { { "<name|target>", "add a player to kill on sight" } } },
    { id = "avoid", words = { "avoid" }, help = { { "<name|target>", "add a player to avoid" } } },
    { id = "unlist", words = { "unlist" }, help = { { "<name>", "take a player off your lists" } } },
    { id = "note", words = { "note" }, help = { { "<name> <text>", "note on a player (no text clears it)" } } },
    { id = "who", words = { "who" }, help = { { "<name>", "what your journal knows about a player" } } },
    { id = "journal", words = { "journal" }, help = { { "", "journal of enemies you met" } } },
    { id = "lists", words = { "lists" }, help = { { "", "your kill-on-sight and avoid lists" } } },
    { id = "distance", words = { "distance" }, help = { { "[max]", "show or maximize nameplate distance (detection reach)" } } },
    { id = "probe", words = { "probe" }, help = { { "", "what this client lets addons read (target an enemy player)" } } },
    { id = "errors", words = { "errors", "error" }, help = { { "[clear]", "copyable list of " .. ns.NAME .. " errors (for bug reports)" } } },
    { id = "data", words = { "data" }, help = { { "[clear]", "saved data: stores by character, tamper seals, set-aside entries (clear deletes those)" } } },
    { id = "clear", words = { "clear" }, help = { { "", "empty the nearby list" } } },
    { id = "reset", words = { "reset" }, help = { { "", "reset settings and positions (all your logged data is kept)" } } },
    { id = "minimap", words = { "minimap" }, help = { { "", "show / hide the minimap button" } } },
    { id = "pace", words = { "pace" }, help = { { "[reset]", "whisper limit learned from the game's throttle (reset forgets it)" } } },

    -- Census.lua
    { id = "census", words = { "census" }, help = {
        { "[on|off]", "player census for heat maps (status without argument)" },
        { "allies on|off", "include your own faction" },
        { "friendly", "turn on friendly nameplates" },
        { "clear", "delete all census data" },
    } },

    -- Character window (Gear.lua, Skills.lua, Enhance.lua, Professions.lua)
    { id = "character", words = { "char", "character" }, help = { { "", "character window: gear, ledger, progress, sources, skills" } } },
    { id = "gear", words = { "gear" }, help = {
        { "", "the character window on the gear tab" },
        { "snap [name]", "take a named snapshot of what you wear" },
        { "status|on|off", "gear ledger status, or turn it on / off" },
    } },
    { id = "skills", words = { "skills" }, help = { { "", "the character window on the skills tab" } } },
    { id = "enhance", words = { "enhance", "enchants" }, help = { { "", "what you can put on your gear and what it takes" } } },
    { id = "plan", words = { "plan", "professions", "prof" }, help = {
        { "[profession] [[from-]skill]", "profession leveling plan (e.g. tailoring 150, or 60-150)" } } },
    { id = "crafts", words = { "crafts", "crafting" }, help = { { "", "your crafting log" } } },

    -- Money and the Auction House (Economy.lua, Prices.lua, AuctionDesk.lua, AHHelper.lua)
    { id = "economy", words = { "economy", "gold" }, help = { { "", "the economy window: money, auctions, trades (all characters)" } } },
    { id = "price", words = { "price", "prices", "market" }, help = {
        { "[item]", "the Market window (prices you have seen, selling, crafting profit, deals)" } } },
    { id = "ah", words = { "ah", "desk" }, help = {
        { "[item]", "the Auction desk: your listings, deals, margins, buyout and control costs" },
        { "scan", "the scan panel (full scan, search list); opens by itself at the AH" },
        { "log", "every full scan: done (with counts) or why it failed" },
    } },

    -- Fishing (Fishing.lua and its helpers)
    { id = "fish", words = { "fish", "fishing" }, help = {
        { "", "fishing window (spots, heat map, log, sessions)" },
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

    -- Guild (Guild.lua, Audit.lua)
    { id = "guild", words = { "guild", "g" }, help = {
        { "[recruit|invited|replies|roster|activity|recruiters|promote|log|members|sharing]", "guild window" },
        { "mini", "show / hide the mini recruit window" },
        { "who", "one /who search for players without a guild (your level range)" },
        { "invite [name]", "whisper + guild invite to one player (or your target)" },
        { "pace [reset]", "whisper limit learned from the game's throttle (reset forgets it)" },
        { "check", "your invites of the last hour: confirmed by the game, answered, unconfirmed" },
    } },
    { id = "audit", words = { "audit" }, help = {
        { "[me|target|flags|members|status]", "statistics ledger: members' gold and activity, flags" } } },

    { id = "credits", words = { "credits", "discord", "donate" }, help = { { "", "credits, the Discord invite, how to send gold" } } },
}

-- Lines /talod help prints after the commands (things that are not /talod commands).
Cmd.EXTRA_HELP = {
    { "/click " .. ns.FRAME .. "FishingSwapButton", "(macro / keybind) swap the fishing pole for your weapon" },
}

local byId, byWord, bareId = {}, {}, nil
for _, c in ipairs(Cmd.LIST) do
    byId[c.id] = c
    if c.bare then bareId = c.id end
    for _, w in ipairs(c.words) do byWord[w:lower()] = c.id end
end

-- Every slash word the game should register (the prefix, then the aliases).
function Cmd.Slashes()
    local out = { Cmd.PREFIX }
    for _, a in ipairs(Cmd.ALIASES) do out[#out + 1] = a end
    return out
end

-- The id for what the player typed after the prefix, or nil.
function Cmd.Resolve(word)
    word = (word or ""):lower()
    if word == "" then return bareId end
    return byWord[word]
end

-- What to type, for hints: Cmd.Text("guild", "invite <name>") -> "/talod guild invite <name>".
function Cmd.Text(id, args)
    local c = byId[id]
    local text = Cmd.PREFIX .. " " .. (c and c.words[1] or id)
    if args and args ~= "" then text = text .. " " .. args end
    return text
end

local function HelpLine(usage, what)
    if not what then return "  " .. usage end
    return string.format("  %-26s - %s", usage, what)
end

function Cmd.HelpLines()
    local lines = {}
    for _, c in ipairs(Cmd.LIST) do
        for _, h in ipairs(c.help or {}) do
            local usage = (c.bare and h[1] == "") and Cmd.PREFIX or Cmd.Text(c.id, h[1])
            lines[#lines + 1] = HelpLine(usage, h[2])
        end
    end
    for _, h in ipairs(Cmd.EXTRA_HELP) do lines[#lines + 1] = HelpLine(h[1], h[2]) end
    return lines
end
