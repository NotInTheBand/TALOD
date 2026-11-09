-- Style.List redraws: a row sends a widget call only when the value it shows
-- changed, a row is anchored again only when its slot moved, and handing the
-- list the same table again redraws the rows without sorting / filtering
-- again. What the rows show must be exactly what a full redraw would show.
local scenarios, T = ...
local check, boot = T.check, T.boot

local function Texts(list)
    local out = {}
    for _, item in ipairs(list.items) do out[#out + 1] = item.text end
    return table.concat(out, ",")
end

local function Shown(list)
    local out = {}
    for _, r in ipairs(list.rows) do if r:IsShown() then out[#out + 1] = (r.text:GetText():gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end end
    return table.concat(out, ",")
end

local function RowOf(list, item)
    for _, r in ipairs(list.rows) do if r:IsShown() and r.item == item then return r end end
end

local function NewList(ns, opts, rows)
    local holder = CreateFrame("Frame", nil, UIParent)
    local list = ns.Style.List(holder, opts)
    list._height = (opts.search and 28 or 0) + (rows or 10) * ns.Style.ROW
    return list
end

-- Counts the calls a widget gets (an instance field shadows the mock's method).
local function Spy(widget, method)
    local n = { count = 0 }
    local real = widget[method]
    widget[method] = function(...) n.count = n.count + 1 return real(...) end
    return n
end

local function Numbered(n, prefix)
    local items = {}
    for i = 1, n do items[i] = { text = (prefix or "Row ") .. i } end
    return items
end

scenarios.list_draw_new_items = function()
    local ns = boot(16001)
    local list = NewList(ns, { colWidths = { 60, 40 }, labelWidth = 50 })
    local a = {
        { text = "Alpha", label = "L1", cols = { "1g", "2%" } },
        { text = "Bravo", label = "L2", cols = { "3g", "4%" }, accent = { 1, 0, 0, 1 }, bar = { 5, 10 } },
        { text = "Charlie", icon = "Interface\\Icons\\A", link = "|cffa335ee|Hitem:1|h[x]|h|r" },
    }
    list:SetItems(a)
    check(Shown(list) == "Alpha,Bravo,Charlie", "first draw: " .. Shown(list))
    local r1, r2, r3 = list.rows[1], list.rows[2], list.rows[3]
    check(r1.cols[1]:GetText() == "1g" and r1.label:GetText() == "L1", "columns and label drawn")
    check(r2.accent:IsShown() and r2.barBg:IsShown() and r2.barFill:IsShown(), "accent and bar drawn")
    check(r3.icon:GetTexture() == "Interface\\Icons\\A" and r3.icon:IsShown(), "icon drawn")

    -- New items in the same slots: everything shown follows them.
    local b = {
        { text = "Delta", label = "M1", cols = { "9g", "8%" } },
        { text = "Echo", cols = { "7g" } },                              -- no label, one column, no accent, no bar
        { text = "Foxtrot", icon = "Interface\\Icons\\B", iconEmpty = true },
    }
    list:SetItems(b)
    check(Shown(list) == "Delta,Echo,Foxtrot", "new texts: " .. Shown(list))
    check(r1.cols[1]:GetText() == "9g" and r1.cols[2]:GetText() == "8%" and r1.label:GetText() == "M1", "new columns and label")
    check(r2.cols[1]:GetText() == "7g" and not r2.cols[2]:IsShown(), "a missing column is hidden")
    check(not r2.accent:IsShown() and not r2.barBg:IsShown() and not r2.barFill:IsShown(), "accent and bar gone")
    check(r2.label:GetText() == "", "a row with no label shows an empty label")
    check(r3.icon:GetTexture() == "Interface\\Icons\\B" and r3.icon:GetAlpha() == 0.35, "new icon, emptied")
    check(r1.icon == nil, "no icon made for a row that never had one")

    -- The same table with an item changed in place: the next draw shows it.
    b[1].text = "Delta II"
    list:SetItems(b)
    check(r1.text:GetText() == "Delta II", "in-place change shows: " .. tostring(r1.text:GetText()))

    -- Fewer items hide the rows past them; more bring them back.
    list:SetItems(Numbered(2))
    check(Shown(list) == "Row 1,Row 2", "fewer rows: " .. Shown(list))
    list:SetItems(Numbered(4, "Back "))
    check(Shown(list) == "Back 1,Back 2,Back 3,Back 4", "more rows: " .. Shown(list))

    -- A header and a titled section keep their own font and gold text.
    list:SetItems({ { header = true, text = "Section" }, { text = "Under" } })
    check(list.rows[1].text:GetText():find("Section") and list.rows[1].text:GetText():find("|c"), "header text is gold")
    check(list.rows[2].text:GetText() == "Under", "row under a header is plain")
end

scenarios.list_draw_skips_unchanged = function()
    local ns = boot(16001)
    local list = NewList(ns, { colWidths = { 60, 40 }, labelWidth = 50 })
    local items = {
        { text = "Alpha", label = "L1", cols = { "1g", "2%" }, accent = { 1, 0, 0, 1 }, bar = { 5, 10 } },
        { text = "Bravo", label = "L2", cols = { "3g", "4%" }, icon = "Interface\\Icons\\A" },
    }
    list:SetItems(items)
    local spies = {}
    for _, r in ipairs({ list.rows[1], list.rows[2] }) do
        spies[#spies + 1] = Spy(r, "ClearAllPoints")
        spies[#spies + 1] = Spy(r, "SetPoint")
        spies[#spies + 1] = Spy(r, "Show")
        spies[#spies + 1] = Spy(r.text, "SetText")
        spies[#spies + 1] = Spy(r.text, "SetFontObject")
        spies[#spies + 1] = Spy(r.text, "ClearAllPoints")
        spies[#spies + 1] = Spy(r.bg, "SetColorTexture")
        spies[#spies + 1] = Spy(r.cols[1], "SetText")
        spies[#spies + 1] = Spy(r.cols[1], "SetWidth")
        spies[#spies + 1] = Spy(r.cols[1], "SetPoint")
        spies[#spies + 1] = Spy(r.label, "SetText")
        spies[#spies + 1] = Spy(r.label, "SetShown")
    end
    spies[#spies + 1] = Spy(list.rows[1].barFill, "SetWidth")
    spies[#spies + 1] = Spy(list.rows[1].accent, "SetColorTexture")
    spies[#spies + 1] = Spy(list.rows[2].icon, "SetTexture")
    spies[#spies + 1] = Spy(list.track, "SetShown")
    local function Total() local n = 0 for _, s in ipairs(spies) do n = n + s.count end return n end

    list:SetItems(items)
    list:Draw()
    check(Total() == 0, "the same table drawn again touches no widget: " .. Total())
    -- An equal table is a different table: the full pass runs, the widgets still stay untouched.
    list:SetItems({
        { text = "Alpha", label = "L1", cols = { "1g", "2%" }, accent = { 1, 0, 0, 1 }, bar = { 5, 10 } },
        { text = "Bravo", label = "L2", cols = { "3g", "4%" }, icon = "Interface\\Icons\\A" },
    })
    check(Total() == 0, "equal items in a new table touch no widget: " .. Total())
    -- One text changed: exactly that fontstring is written.
    items[1].cols[2] = "5%"
    items[1].text = "Alpha 2"
    list:SetItems(items)
    check(list.rows[1].text:GetText() == "Alpha 2" and list.rows[1].cols[2]:GetText() == "5%", "changed texts written")
    check(Total() == 1, "only the changed text is set (the other changed one is not spied): " .. Total())
end

scenarios.list_draw_sort_click = function()
    local ns = boot(16001)
    local list = NewList(ns, { colWidths = { 60, 60, 40 } }, 20)
    local head = { header = true, text = "Recipe", cols = { "Materials", "Profit", "Margin" } }
    local items = {
        head,
        { text = "Bravo", cols = { "10s", "+5s", "+50%" } },
        { text = "Alpha", cols = { "2s", "-3c", "-1%" } },
        { text = "Delta", cols = { "50c", "+1g 2s", "+204%" } },
    }
    local function Click(x)
        local row = RowOf(list, head)
        row._r = 400
        MOCK.cursorX, MOCK.cursorY = x, 0
        row:Fire("OnClick", "LeftButton")
    end
    list:SetItems(items)
    list:SetItems(items)   -- the same table once more before anything is clicked
    check(Texts(list) == "Recipe,Bravo,Alpha,Delta", "own order: " .. Texts(list))
    Click(300)
    check(Texts(list) == "Recipe,Delta,Bravo,Alpha", "profit, high first: " .. Texts(list))
    check(Shown(list) == "Recipe,Delta,Bravo,Alpha", "rows show the sort: " .. Shown(list))
    check(RowOf(list, head).cols[2]:GetText():find("v"), "the sorted title is marked")
    list:SetItems(items)   -- redraw with the same table: the sort stays
    check(Texts(list) == "Recipe,Delta,Bravo,Alpha", "sort kept on a same-table redraw: " .. Texts(list))
    Click(300)
    check(Texts(list) == "Recipe,Alpha,Bravo,Delta", "second click reverses: " .. Texts(list))
    check(Shown(list) == "Recipe,Alpha,Bravo,Delta", "rows show the reversal: " .. Shown(list))
    check(RowOf(list, head).cols[2]:GetText():find("%^"), "the reversed title is marked")
    Click(300)
    check(Texts(list) == "Recipe,Bravo,Alpha,Delta", "third click: own order again: " .. Texts(list))
    list:SortBy("recipe", 0)
    check(Texts(list) == "Recipe,Alpha,Bravo,Delta", "SortBy by name: " .. Texts(list))
end

scenarios.list_draw_columns_relayout = function()
    local ns = boot(16001)
    local list = NewList(ns, { colWidths = { 60, 40 }, labelWidth = 50 })
    local items = { { text = "Alpha", label = "L1", cols = { "1g", "2%" } } }
    list:SetItems(items)
    local row = list.rows[1]
    check(row.cols[1]._width == 60 and row.cols[1]._points[1][2] == -6, "first column slot")
    check(row.cols[2]._width == 40 and row.cols[2]._points[1][2] == -72, "second column slot")
    local text = row.text._points
    check(text[2][2] == -(6 + 60 + 6 + 40 + 6), "text stops before the columns")

    -- Wider columns (the table replaced, then changed in place): the next draw moves everything.
    list.colWidths = { 80, 40 }
    list:Draw()
    check(row.cols[1]._width == 80 and row.cols[2]._points[1][2] == -92, "replaced widths relaid out")
    check(row.text._points[2][2] == -(6 + 80 + 6 + 40 + 6), "text edge follows")
    list.colWidths[2] = 50
    list:SetItems(items)
    check(row.cols[2]._width == 50 and row.text._points[2][2] == -(6 + 80 + 6 + 50 + 6), "widths changed in place relaid out")
    -- A column dropped hides its text.
    list.colWidths = { 80 }
    list:Draw()
    check(not row.cols[2]:IsShown() and row.text._points[2][2] == -(6 + 80 + 6), "a dropped column is hidden")
    -- A wider label column moves the text's left edge.
    list.labelWidth = 70
    list:Draw()
    check(row.label._width == 70 and row.text._points[1][2] == 6 + 70 + 8, "label width relaid out")

    -- Fixed title row: SetColumns changes the titles and lays the row out again.
    local titled = NewList(ns, { colWidths = { 60, 40 }, columns = { name = "Item", "Price", "Left" } })
    titled:SetItems({ { text = "Alpha", cols = { "1g", "2" } } })
    local head = titled.head
    check(head.text:GetText():find("Item") and head.cols[1]:GetText():find("Price"), "titles drawn")
    local ver = titled.layoutVer
    titled:SetColumns({ name = "Thing", "Cost", "Stock" })
    check(titled.layoutVer > ver, "SetColumns bumps the layout version")
    check(head.text:GetText():find("Thing") and head.cols[1]:GetText():find("Cost") and head.cols[2]:GetText():find("Stock"),
        "new titles drawn")
    check(head.cols[1]._points[1][2] == -6, "title anchored")
end

scenarios.list_draw_size_change = function()
    local ns = boot(16001)
    local list = NewList(ns, {})
    local items = { { text = "Alpha", bar = { 5, 10 } }, { text = "Bravo", bar = { 10, 10, color = { 0, 1, 0, 1 } } } }
    list:SetItems(items)
    for _, r in ipairs(list.rows) do r._width = 300 end
    list:Draw()
    local fill = list.rows[1].barFill
    check(fill._width == (300 - 6 - 6) * 0.5, "bar width from the row width: " .. tostring(fill._width))
    check(list.rows[2].barFill._width == 288, "full bar")
    -- The window grows: its OnSizeChanged redraws and the bars follow.
    for _, r in ipairs(list.rows) do r._width = 500 end
    local ver = list.layoutVer
    list:SetWidth(777)
    check(list.layoutVer > ver, "a size change bumps the layout version")
    check(fill._width == (500 - 12) * 0.5, "bar follows the new width: " .. tostring(fill._width))
    -- Even a redraw with no size event measures the row again.
    for _, r in ipairs(list.rows) do r._width = 400 end
    list:Draw()
    check(fill._width == (400 - 12) * 0.5, "bar measured again on a plain redraw: " .. tostring(fill._width))
    -- Both bars keep their anchors after the size change.
    check(list.rows[1].barBg._points[2][2] == -6, "bar background anchored to the text edge")

    -- The scrollbar appearing narrows the rows: the rows are anchored beside it.
    local list2 = NewList(ns, {}, 3)
    list2:SetItems(Numbered(2))
    check(not list2.track:IsShown() and list2.rows[1]._points[2][2] == 0, "no scrollbar: rows reach the edge")
    list2:SetItems(Numbered(10))
    check(list2.track:IsShown() and list2.rows[1]._points[2][2] == -10, "scrollbar: rows stop before it")
    check(list2.rows[3]._points[1][3] == -2 * ns.Style.ROW, "row slot unchanged: " .. tostring(list2.rows[3]._points[1][3]))
    list2:SetItems(Numbered(2))
    check(not list2.track:IsShown() and list2.rows[1]._points[2][2] == 0, "scrollbar gone: rows reach the edge again")
end

scenarios.list_draw_same_table = function()
    local ns = boot(16001)
    local list = NewList(ns, {}, 10)
    local items = Numbered(100)
    list:SetItems(items)
    list.offset = 20
    list:Draw()
    check(list.rows[1].text:GetText() == "Row 21", "scrolled: " .. tostring(list.rows[1].text:GetText()))
    local thumbAt = list.thumb._points[#list.thumb._points][5]
    list:SetItems(items)
    check(list.offset == 20, "the same table keeps the scroll offset: " .. list.offset)
    check(list.rows[1].text:GetText() == "Row 21" and list.rows[10].text:GetText() == "Row 30", "same rows after the redraw")
    check(list.thumb._points[#list.thumb._points][5] == thumbAt, "thumb stays")
    -- Scrolling moves the rows without re-anchoring them.
    local anchors = Spy(list.rows[1], "ClearAllPoints")
    list:GetScript("OnMouseWheel")(list, -1)
    check(list.offset == 23 and list.rows[1].text:GetText() == "Row 24", "wheel scrolls: " .. list.offset)
    check(anchors.count == 0, "scrolling does not re-anchor the rows")
    check(list.thumb._points[#list.thumb._points][5] ~= thumbAt, "thumb moves with the offset")
    -- A shorter table clamps the offset as before.
    list:SetItems(Numbered(15))
    check(list.offset == 5, "offset clamped to the new length: " .. list.offset)
    list:SetItems(items)
    -- New items under the same offset.
    list.offset = 50
    list:SetItems(Numbered(100, "New "))
    check(list.offset == 50 and list.rows[1].text:GetText() == "New 51", "new table keeps the offset: " .. tostring(list.rows[1].text:GetText()))
end

scenarios.list_draw_search_after_same_table = function()
    local ns = boot(16001)
    local list = NewList(ns, { search = true, time = true }, 10)
    local items = {}
    for i = 1, 40 do items[i] = { text = (i % 2 == 0 and "Alpha " or "Bravo ") .. i, time = time() - i * 500 } end
    list:SetItems(items)
    list:SetItems(items)
    list:SetItems(items)
    check(#list.items == 40, "unfiltered: " .. #list.items)
    list.searchBox:SetText("alpha")
    list.searchBox:Fire("OnTextChanged")
    check(#list.items == 20 and list.items[1].text == "Alpha 2", "search filters after same-table redraws: " .. #list.items)
    check(list.count:GetText():find("20 of 40"), "count: " .. tostring(list.count:GetText()))
    list:SetItems(items)
    check(#list.items == 20 and Shown(list):find("^Alpha 2,Alpha 4"), "same table with a search: still filtered")
    -- A different search string changes the result.
    list.searchBox:SetText("bravo 3")
    list.searchBox:Fire("OnTextChanged")
    check(#list.items == 6 and list.items[1].text == "Bravo 3", "new search: " .. Texts(list))
    list.searchBox:SetText("")
    list.searchBox:Fire("OnTextChanged")
    check(#list.items == 40, "search cleared: " .. #list.items)
    -- A time range with a start moves with the clock: the same table is filtered again.
    list:SetRange("hour")
    check(#list.items == 7 and list.items[7].text:find("7$"), "last hour: " .. Texts(list))
    local aged = {}
    for i = 1, 5 do aged[i] = { text = "Age " .. i, time = time() - i * 600 + 5 } end
    list:SetItems(aged)
    check(#list.items == 5, "range: all inside")
    aged[1].time = time() - 7200   -- aged out of the hour while the table stayed the same
    list:SetItems(aged)
    check(#list.items == 4 and list.items[1].text == "Age 2", "a range with a start filters the same table again: " .. #list.items)
    list:SetRange("all")
    check(#list.items == 5, "range all again")
    -- Sorting by a title still goes through the full pass on the same table.
    local sorted = NewList(ns, { colWidths = { 60 } }, 10)
    local head = { header = true, text = "Name", cols = { "Qty" } }
    local rows = { head, { text = "A", cols = { "2" } }, { text = "B", cols = { "9" } }, { text = "C", cols = { "5" } } }
    sorted:SetItems(rows)
    sorted:SetItems(rows)
    sorted:SortBy("name", 1)
    check(Texts(sorted) == "Name,B,C,A", "SortBy re-sorts the same table: " .. Texts(sorted))
    sorted:SetItems(rows)
    check(Texts(sorted) == "Name,B,C,A", "and keeps it: " .. Texts(sorted))
end
