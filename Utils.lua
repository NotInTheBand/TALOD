-- TALOD - small helpers shared by every window.
--
-- Copy: addons cannot write the clipboard, so "copy" means the text in a box,
-- selected, for the player's own Ctrl+C. One popup serves every caller (guild
-- names, the Credits page's Discord invite and donation name).
--
-- Bags: every module that reads your bags goes through Utils.BagIDs /
-- EachBagSlot / ScanBags, so all of them see the same bags as the game and
-- as bag addons. On the newer engine (Forever) the reagent bag is bag 5
-- (Enum.BagIndex.ReagentBag); bag UIs such as EllesmereUIBags show it and
-- merge every stack of an item into one button with the total. On Classic
-- Era bag 5 is the first bank bag, so it counts only where the client names
-- a reagent bag. Counts are summed over every slot, so they match a merged
-- button; the slot list keeps where each stack really is (a merged button
-- hands only one of them to a mail or trade).

local ADDON_NAME, ns = ...
local Style = ns.Style
local S = ns.Secret

local Utils = {}
ns.Utils = Utils

StaticPopupDialogs[ns.POPUP .. "COPY"] = {
    text = "Ctrl+C copies the %s, Escape closes.",
    button1 = CLOSE or "Close",
    hasEditBox = true,
    editBoxWidth = 260,
    OnShow = function(self, data)
        local box = self.editBox or (self.GetEditBox and self:GetEditBox())
        if not box then return end
        box:SetText(data or "")
        box:SetFocus()
        box:HighlightText()
    end,
    EditBoxOnEnterPressed = function(self) self:GetParent():Hide() end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    EditBoxOnTextChanged = function(self, data)
        -- Typing over it puts the text back, so a stray key never copies the wrong text.
        if data and self:GetText() ~= data then self:SetText(data) self:HighlightText() end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

---------------------------------------------------------------------------
-- Sorting big lists
---------------------------------------------------------------------------
-- table.sort with a Lua comparator makes one Lua call per comparison:
-- thousands of items (every ladder, every recruit) are a long step that
-- background work cannot pause in. SortBy sorts by a text key in one C
-- call instead; equal keys keep their order.
local NUM_SPAN = 1e12           -- copper and times fit; beyond is clamped

-- Text whose byte order is the numeric order (desc: high first). Two
-- decimals; nil and NaN count as the lowest.
function Utils.NumKey(v, desc)
    v = tonumber(v)
    if not v or v ~= v then v = -NUM_SPAN end
    if v > NUM_SPAN then v = NUM_SPAN elseif v < -NUM_SPAN then v = -NUM_SPAN end
    if desc then v = -v end
    return string.format("%016.2f", v + NUM_SPAN)
end

function Utils.SortBy(list, keyOf)
    local keys, byKey = {}, {}
    for i, item in ipairs(list) do
        local k = keyOf(item) .. "\1" .. string.format("%07d", i)
        keys[i], byKey[k] = k, item
    end
    table.sort(keys)
    for i, k in ipairs(keys) do list[i] = byKey[k] end
    return list
end

-- what: the word in "Ctrl+C copies the <what>" ("name", "invite link", ...).
function Utils.Copy(text, what)
    if type(text) ~= "string" or text == "" then return false end
    if type(StaticPopup_Show) ~= "function" then
        ns.Print(text)
        return true
    end
    StaticPopup_Show(ns.POPUP .. "COPY", what or "text", nil, text)
    return true
end

-- A Style button that opens the copy box. getText: a string, or a function
-- returning one (nil: nothing to copy, the click does nothing).
function Utils.CopyButton(parent, label, width, getText, what, tooltip)
    return Style.Button(parent, label, width, function()
        local text = getText
        if type(getText) == "function" then text = getText() end
        Utils.Copy(text, what)
    end, tooltip or "Shows it ready to copy (Ctrl+C): the game cannot put text on the clipboard itself.")
end

---------------------------------------------------------------------------
-- Bags
---------------------------------------------------------------------------
local function Num(x) return type(x) == "number" and x == x and x or nil end

local function ContainerAPI()
    local C = C_Container
    return (C and C.GetContainerNumSlots) or GetContainerNumSlots, (C and C.GetContainerItemLink) or GetContainerItemLink
end

-- The reagent bag's ID on this client, or nil (Classic Era has none).
function Utils.ReagentBag()
    local idx = Enum and Enum.BagIndex
    return idx and Num(idx.ReagentBag) or nil
end

-- Bag IDs you carry: backpack and bags, plus the reagent bag unless
-- which == "general" (free space for loot, gear: the reagent bag holds
-- only reagents).
function Utils.BagIDs(which)
    local out = {}
    for bag = 0, Num(NUM_BAG_SLOTS) or 4 do out[#out + 1] = bag end
    local reagent = Utils.ReagentBag()
    if reagent and which ~= "general" then out[#out + 1] = reagent end
    return out
end

-- Units in one slot (1 when the game does not say).
function Utils.SlotCount(bag, slot)
    local info = C_Container and C_Container.GetContainerItemInfo
    if type(info) == "function" then
        local t = S.Value(S.Call(info, bag, slot))
        return type(t) == "table" and Num(S.Value(t.stackCount)) or 1
    end
    if type(GetContainerItemInfo) == "function" then
        return Num(select(2, S.CallMulti(2, GetContainerItemInfo, bag, slot))) or 1
    end
    return 1
end

-- fn(bag, slot, link) for every item you carry (which: see BagIDs).
function Utils.EachBagSlot(fn, which)
    local numSlots, itemLink = ContainerAPI()
    if type(numSlots) ~= "function" or type(itemLink) ~= "function" then return end
    for _, bag in ipairs(Utils.BagIDs(which)) do
        for slot = 1, Num(S.Call(numSlots, bag)) or 0 do
            local link = S.Call(itemLink, bag, slot)
            if type(link) == "string" then fn(bag, slot, link) end
        end
    end
end

-- { [itemID] = { n = total, link, slots = { { bag, slot, n } } } }: every
-- stack of an item summed, the way a merging bag UI shows it.
function Utils.ScanBags(which)
    local out = {}
    Utils.EachBagSlot(function(bag, slot, link)
        local id = tonumber(link:match("item:(%d+)"))
        if not id then return end
        local n = Utils.SlotCount(bag, slot)
        local e = out[id]
        if not e then
            e = { n = 0, link = link, slots = {} }
            out[id] = e
        end
        e.n = e.n + n
        e.slots[#e.slots + 1] = { bag = bag, slot = slot, n = n }
    end, which)
    return out
end

-- How many of an item you carry (bags and reagent bag). The game's own
-- count when it is higher than the scan (a bag the scan does not know).
function Utils.ItemCount(id)
    local bags = ns.Data and ns.Data.Bags() or Utils.ScanBags()
    local n = bags[id] and bags[id].n or 0
    local fn = (C_Item and C_Item.GetItemCount) or GetItemCount
    local game = type(fn) == "function" and Num(S.Call(fn, id)) or nil
    return math.max(n, game or 0)
end
