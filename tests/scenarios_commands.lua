-- Commands.lua: the one list of slash commands. Words resolve to ids, aliases
-- work, /talod help is built from the list, every command reaches a handler.
local scenarios, T = ...
local check, boot, slash = T.check, T.boot, T.slash

local function printedPlain(text)
    for _, line in ipairs(MOCK.prints) do
        if line:find(text, 1, true) then return true end
    end
    return false
end

scenarios.commands_list = function()
    local ns = boot(11509)
    local Cmd = ns.Cmd
    local header = ns.NAME .. " v" .. ns.VERSION .. "|r"

    -- No word belongs to two commands; every word resolves to its own id.
    local seen = {}
    for _, c in ipairs(Cmd.LIST) do
        check(type(c.id) == "string" and #c.words > 0, "entry has an id and words")
        for _, w in ipairs(c.words) do
            check(not seen[w:lower()], "word '" .. w .. "' used twice")
            seen[w:lower()] = true
            check(Cmd.Resolve(w) == c.id and Cmd.Resolve(w:upper()) == c.id, "resolve " .. w)
        end
    end
    check(Cmd.Resolve("") == "settings", "the prefix alone opens settings")
    check(Cmd.Resolve("nonsense") == nil, "unknown word")
    check(Cmd.Text("guild", "invite <name>") == Cmd.PREFIX .. " guild invite <name>", "hint text")
    check(_G["SLASH_" .. ns.SLASH_KEY .. "1"] == Cmd.PREFIX, "prefix registered")

    -- /talod help prints every command from the list.
    MOCK.prints = {}
    slash("help")
    check(printedPlain(header), "help header")
    for _, c in ipairs(Cmd.LIST) do
        if c.id ~= "settings" then check(printedPlain(Cmd.Text(c.id)), "help lists " .. c.id) end
    end

    -- An unknown word prints help instead of failing.
    MOCK.prints = {}
    slash("nonsense")
    check(printedPlain(header), "unknown word prints help")

    -- Every command reaches a handler (none falls through to help).
    for _, c in ipairs(Cmd.LIST) do
        if c.id ~= "help" then
            MOCK.prints = {}
            slash(c.words[1])
            check(not printedPlain(header), c.id .. " is handled")
        end
    end
end

scenarios.commands_aliases = function()
    local ns = boot(11509)
    local economy = function() return _G[ns.FRAME .. "EconomyWindow"] end
    slash("gold")
    check(economy() and economy():IsShown(), "alias 'gold' opens the Economy window")
    slash("economy")
    check(not economy():IsShown(), "'economy' toggles it closed")
    MOCK.prints = {}
    slash("CREDITS")
    check(_G[ns.FRAME .. "CreditsWindow"] and _G[ns.FRAME .. "CreditsWindow"]:IsShown(), "words are case-insensitive")
end
