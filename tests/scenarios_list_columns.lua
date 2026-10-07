-- Style.List column titles: a section header's titles (or a fixed title row)
-- sit above their columns, and a click on one sorts the rows under it: its
-- natural way, reversed, then the list's own order. Unknown stays last.
local scenarios, T = ...
local check, boot = T.check, T.boot

local function Texts(list)
    local out = {}
    for _, item in ipairs(list.items) do out[#out + 1] = item.text end
    return table.concat(out, ",")
end

-- Clicks the title at x on the drawn row showing `item` (the row's right edge at 400).
local function ClickAt(list, row, x)
    row._r = 400
    MOCK.cursorX, MOCK.cursorY = x, 0
    row:Fire("OnClick", "LeftButton")
end

local function RowOf(list, item)
    for _, r in ipairs(list.rows) do if r:IsShown() and r.item == item then return r end end
end

scenarios.list_sort_values = function()
    local ns = boot(16001)
    local V = ns.Style.SortValue
    check(V("|cff00ff0036s 53c|r") == 3653, "money: " .. tostring(V("36s 53c")))
    check(V("1,234g 5s") == 12340500, "gold with a thousands comma")
    check(V("|cffff0000-17c|r") == -17, "a loss is negative")
    check(V("+509%") == 509 and V("3 / 5") == 3 and V("45% sold  3/5") == 45, "percents and counts")
    check(V("12 sold") == 12, "a word starting with s is not silver")
    check(V("5 min ago") > V("3 h ago") and V("3h ago") > V("2 days ago"), "ages: newer is higher")
    check(V("-") == nil and V("?") == nil and V("") == nil and V(nil) == nil and V("? units") == nil, "unknown is nil")
    check(V("Undercut") == "undercut", "words: lowercased text")
end

scenarios.list_section_sort = function()
    local ns = boot(16001)
    local Style = ns.Style
    local holder = CreateFrame("Frame", nil, UIParent)
    local list = Style.List(holder, { colWidths = { 60, 60, 40 } })
    list._height = 20 * Style.ROW
    local head = { header = true, text = "Recipe", cols = { "Materials", "Profit", "Margin" } }
    local items = {
        head,
        { text = "Bravo", cols = { "10s", "+5s", "+50%" } },
        { text = "Alpha", cols = { "2s", "-3c", "-1%" } },
        { label = "", text = "make it: 1s" },                   -- belongs to Alpha
        { text = "Charlie", cols = { "1g", "|cff5c5c5c-|r", "-" } }, -- profit unknown
        { text = "Delta", cols = { "50c", "+1g 2s", "+204%" } },
        { header = true, text = "Other" },
        { text = "Zulu", cols = { "1c", "+9g", "" } },
        { text = "Yankee", cols = { "1c", "+1c", "" } },
    }
    list:SetItems(items)
    local row = RowOf(list, head)
    check(row and row.cols[2]:GetText():find("Profit") and row.text:GetText():find("Recipe"), "titles drawn over their columns")
    -- cols[1] is the rightmost slot: 334-394; cols[2]: 268-328.
    ClickAt(list, row, 300)
    check(Texts(list) == "Recipe,Delta,Bravo,Alpha,make it: 1s,Charlie,Other,Zulu,Yankee",
        "profit high first, its detail row follows, unknown last, other section untouched: " .. Texts(list))
    check(RowOf(list, head).cols[2]:GetText():find("v"), "the sorted title is marked")
    ClickAt(list, RowOf(list, head), 300)
    check(Texts(list) == "Recipe,Alpha,make it: 1s,Bravo,Delta,Charlie,Other,Zulu,Yankee", "reversed, unknown still last: " .. Texts(list))
    ClickAt(list, RowOf(list, head), 300)
    check(Texts(list) == "Recipe,Bravo,Alpha,make it: 1s,Charlie,Delta,Other,Zulu,Yankee", "third click: the list's own order")
    -- The name title: A-Z.
    ClickAt(list, RowOf(list, head), 40)
    check(Texts(list) == "Recipe,Alpha,make it: 1s,Bravo,Charlie,Delta,Other,Zulu,Yankee", "names A-Z: " .. Texts(list))
    -- The sort stays when the same section comes back with new rows (kept by its text).
    local again = { { header = true, text = "Recipe", cols = { "Materials", "Profit", "Margin" } },
        { text = "Echo", cols = { "1c", "", "" } }, { text = "Bravo", cols = { "1c", "", "" } } }
    list:SetItems(again)
    check(Texts(list) == "Recipe,Bravo,Echo", "sort kept across refreshes")
    -- A click between columns or on a blank title does nothing; rows still click through.
    local clicked
    local plain = Style.List(holder, { colWidths = { 60 }, onClick = function(item) clicked = item end })
    plain._height = 5 * Style.ROW
    local h = { header = true, text = "Item", cols = { "" } }
    local a = { text = "A", cols = { "1" } }
    plain:SetItems({ h, a })
    ClickAt(plain, RowOf(plain, h), 380)
    check(next(plain.sorts) == nil, "a blank title does not sort")
    RowOf(plain, a):Fire("OnClick", "LeftButton")
    check(clicked == a, "rows still click through")
end

scenarios.list_title_row = function()
    local ns = boot(16001)
    local Style = ns.Style
    local holder = CreateFrame("Frame", nil, UIParent)
    local list = Style.List(holder, { colWidths = { 60, 60 }, labelWidth = 80, search = true,
        columns = { name = "Member", label = "When", "Gold", "Seen" } })
    list._height = 28 + 11 * Style.ROW
    local now = time()
    local items = {
        { text = "Ann", label = "Oct 01", sort = { label = now - 300 }, cols = { "5g", "2 h ago" } },
        { text = "Bob", label = "Oct 03", sort = { label = now - 100 }, cols = { "1g", "5 min ago" } },
        { text = "Cy", label = "Sep 30", sort = { label = now - 900 }, cols = { "9g", "?" } },
    }
    list:SetItems(items)
    check(list.head and list.head:IsShown() and list.head.text:GetText():find("Member") and list.head.label:GetText():find("When")
        and list.head.cols[1]:GetText():find("Gold"), "fixed title row with every title")
    check(list.visible == 10, "the title row takes one row of room: " .. tostring(list.visible))
    ClickAt(list, list.head, 360)
    check(Texts(list) == "Cy,Ann,Bob", "gold high first: " .. Texts(list))
    ClickAt(list, list.head, 300)
    check(Texts(list) == "Bob,Ann,Cy", "newest seen first, unknown last: " .. Texts(list))
    list:SortBy("*", "label")
    check(Texts(list) == "Bob,Ann,Cy", "label sorts by its time")
    -- Search still filters the sorted rows.
    list.searchBox:SetText("ann")
    list.searchBox:Fire("OnTextChanged")
    check(Texts(list) == "Ann", "search over sorted rows")
    list:SetColumns({ name = "Member", label = "When", "Coins", "Seen" })
    check(list.head.cols[1]:GetText():find("Coins"), "titles can change")
end
