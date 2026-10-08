-- Style.ContextMenu and a list's opts.menu: the right-click menu every
-- window uses (spec, tones, headers, disabled reasons, closing).
local scenarios, T = ...
local check, boot = T.check, T.boot

local function rowWith(list, text)
    list._height = 400
    list:Draw()
    for _, r in ipairs(list.rows) do
        if r:IsShown() and r.item and r.item.text and r.item.text:find(text, 1, true) then return r end
    end
end

scenarios.context_menu = function()
    local ns = boot(11509)
    local Style = ns.Style
    local holder = CreateFrame("Frame", nil, UIParent)
    local picked, clicks = {}, {}
    local list = Style.List(holder, {
        onClick = function(item, button) clicks[#clicks + 1] = button .. ":" .. item.text end,
        menu = function(item)
            if item.text == "plain" then return nil end
            return { title = item.text, sub = "sub", items = {
                { header = "Section" },
                { label = "Go", notes = { { "now", "muted" }, { "! careful", "bad" } }, pick = function() picked[#picked + 1] = item.text end },
                { label = "Here", selected = true },
                { label = "Never", disabled = true, why = "not allowed", tooltip = { "Never" } },
            } }
        end,
    })
    list:SetItems({ { text = "alpha" }, { text = "plain" } })

    MOCK.cursorX, MOCK.cursorY = 300, 300
    local row = rowWith(list, "alpha")
    row:Fire("OnClick", "LeftButton")
    check(clicks[1] == "LeftButton:alpha" and not (TALODContextMenu and TALODContextMenu:IsShown()), "left-click: onClick, no menu")
    row:Fire("OnClick", "RightButton")
    local menu = TALODContextMenu
    check(menu and menu:IsShown() and #clicks == 1, "right-click: the menu, not onClick")
    check(menu.title:GetText():find("alpha") and menu.title:GetText():find("sub"), "title and sub")
    check(menu.list.items[1].header and menu.list.items[1].text == "Section", "a header row")
    local go = rowWith(menu.list, "Go")
    check(go.item.text:find(Style.HEX.bad .. "! careful", 1, true) and go.item.text:find(Style.HEX.muted .. "now", 1, true), "notes in their tones")
    check(rowWith(menu.list, "Here").item.accent ~= nil, "the current choice is marked")
    local never = rowWith(menu.list, "Never")
    check(never.item.pick == nil and never.item.text:find(Style.HEX.dim, 1, true), "disabled: dim, nothing to pick")
    never:Fire("OnClick", "LeftButton")
    check(menu:IsShown() and #picked == 0, "a click on a disabled entry does nothing and keeps the menu")
    local shownLines
    local text = ns.Tooltip.Text
    ns.Tooltip.Text = function(_, lines) shownLines = table.concat(lines, "\n") end
    never:Fire("OnEnter")
    ns.Tooltip.Text = text
    check(shownLines and shownLines:find("Never") and shownLines:find("Not possible: not allowed"), "the reason in its tooltip")
    go:Fire("OnClick", "LeftButton")
    check(#picked == 1 and picked[1] == "alpha" and not menu:IsShown(), "a pick runs once and closes")

    local plain = rowWith(list, "plain")
    plain:Fire("OnClick", "RightButton")
    check(clicks[2] == "RightButton:plain" and not menu:IsShown(), "no menu for the row: right-click goes to onClick")

    -- Closing: the row shows another item; the mouse wanders off.
    row:Fire("OnClick", "RightButton")
    check(menu:IsShown(), "open again")
    list:SetItems({ { text = "beta" }, { text = "plain" } })
    menu:Fire("OnUpdate", 0.1)
    check(not menu:IsShown(), "the row now shows another item: gone")
    row = rowWith(list, "beta")
    row:Fire("OnClick", "RightButton")
    row._l, row._r, row._b, row._t = 100, 500, 290, 310
    menu._l, menu._r, menu._b, menu._t = 288, 528, 306, 500
    MOCK.cursorX, MOCK.cursorY = 400, 450
    menu:Fire("OnUpdate", 0.1)
    check(menu:IsShown(), "over the menu: stays")
    MOCK.cursorX, MOCK.cursorY = 1200, 50
    menu:Fire("OnUpdate", 0.1)
    check(not menu:IsShown(), "well away: gone")

    -- Any frame can own one.
    local b = Style.Button(holder, "Options", 80, function() end)
    check(Style.ContextMenu(b, { title = "Options" }):IsShown(), "a menu on a button")
    check(rowWith(menu.list, "Nothing to do here") ~= nil, "empty: says so")
    Style.CloseContextMenu()
    check(not menu:IsShown(), "closed from code")
end
