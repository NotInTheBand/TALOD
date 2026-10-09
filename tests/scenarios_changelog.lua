-- Changelog page (Changelog.lua + generated ChangelogData.lua): one summary
-- per version, newest first, formatted, and as plain text to copy.
local scenarios, T = ...
local check, boot, slash = T.check, T.boot, T.slash

scenarios.changelog = function()
    local ns = boot(11509)
    local UI = ns.Changelog
    local list = ns.CHANGELOGS
    check(type(list) == "table" and #list > 1, "changelog data loaded")
    local function key(v)
        local a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)$")
        return tonumber(a) * 1e6 + tonumber(b) * 1e3 + tonumber(c)
    end
    for i = 2, #list do
        check(key(list[i - 1].v) > key(list[i].v), "newest first: " .. list[i - 1].v .. " before " .. list[i].v)
    end
    for _, e in ipairs(list) do
        check(type(e.text) == "string" and e.text ~= "", "text for " .. e.v)
    end

    -- From the Main menu.
    ns.Nav.ShowMenu()
    check(TALODMainMenu.tiles.changelog and TALODMainMenu.navRail.buttons.changelog, "changelog tile and rail entry")
    TALODMainMenu.tiles.changelog:Fire("OnClick", "LeftButton")
    check(UI.IsShown() and not TALODMainMenu:IsShown(), "changelog replaces the menu")
    local f = TALODChangelogWindow
    check(UI.Selected() == list[1], "newest selected")
    check(f.text.title:GetText() == "TALOD " .. list[1].v, "title names the version: " .. tostring(f.text.title:GetText()))
    local shown = f.body:GetText()
    check(not shown:find("{name}", 1, true) and not shown:find("{cmd}", 1, true), "placeholders filled")
    check(not shown:find("**", 1, true), "bold markers rendered")

    -- Rendering: headings, bullets, hard-wrapped lines joined, pipes escaped.
    local r = UI.Render("### Added\n\n- **Big** thing,\n  continued `{cmd} x`\n  - sub on|off\n\nA {name} line.")
    check(r:find("Added", 1, true) and r:find("\226\128\162 ", 1, true), "heading and bullet: " .. r)
    check(r:find("thing, continued", 1, true), "wrapped line joined")
    check(r:find("/talod x", 1, true) and r:find("A TALOD line.", 1, true), "name and prefix filled")
    check(r:find("on||off", 1, true), "pipe escaped")
    check(r:find("    \226\128\147 sub", 1, true), "sub bullet indented")

    -- Copy text: the summary as its file reads.
    f.copy:Fire("OnClick", "LeftButton")
    check(f.edit:IsShown() and not f.body:IsShown(), "copy view")
    local plain = f.edit:GetText()
    check(plain:find("^# TALOD " .. list[1].v:gsub("%.", "%%.")), "plain text starts with its heading")
    check(not plain:find("|c", 1, true), "plain text has no color codes")
    f.edit:Fire("OnTextChanged", true)
    check(f.edit:GetText() == plain, "copy box is read-only")
    f.copy:Fire("OnClick", "LeftButton")
    check(f.body:IsShown() and not f.edit:IsShown(), "back to formatted")

    -- A row click selects; /talod changelog <version> opens that one.
    local last = list[#list]
    UI.Select(#list)
    check(UI.Selected() == last, "select oldest")
    slash("changelog " .. list[2].v)
    check(UI.IsShown() and UI.Selected() == list[2], "/talod changelog <version>")
    MOCK.prints = {}
    slash("changelog 99.0.0")
    check(MOCK.prints[1] and MOCK.prints[1]:find("No notes for version 99.0.0", 1, true), "unknown version told")
    slash("news")
    check(not UI.IsShown(), "alias toggles closed")
end
