-- TALOD - Enhance: what you can put on each piece of gear to make it
-- better (enchants, armor kits, shield spikes, counterweights, spurs,
-- scopes, and the temporary stones and oils), with what it takes: the
-- profession and skill, where the recipe is learned, the tool, every
-- reagent with how many you have, and how each reagent is made or found
-- (recursively, e.g. Iron Bar <- smelted at Mining 125 from Iron Ore).
--
-- The data is EnhanceData.lua, generated from Wowhead Classic by
-- tools/gen_enhancements.py (see docs/DATA.md). Your own
-- profession skills come from the Skills module.

local ADDON_NAME, ns = ...
local S = ns.Secret
local Style = ns.Style
local COLORS, HEX = Style.COLORS, Style.HEX
local Gear = ns.Gear

local Enhance = {}
ns.Enhance = Enhance

local DATA = ns.EnhanceData or { enhancements = {}, recipes = {}, items = {} }
local QUALITY_HEX = { [0] = "|cff9d9d9d", [1] = "|cffffffff", [2] = "|cff1eff00", [3] = "|cff0070dd", [4] = "|cffa335ee", [5] = "|cffff8000" }
local WEAPON_LOCS = { INVTYPE_WEAPON = true, INVTYPE_WEAPONMAINHAND = true, INVTYPE_WEAPONOFFHAND = true, INVTYPE_2HWEAPON = true }
-- Weapon subclasses (item class 2): bows, guns, crossbows take scopes;
-- sharpening stones are for blades, weightstones for blunt weapons.
local BOWGUN = { [2] = true, [3] = true, [18] = true }
local BLADED = { [0] = true, [1] = true, [6] = true, [7] = true, [8] = true, [15] = true }
local BLUNT = { [4] = true, [5] = true, [10] = true, [13] = true }

-- Slots that can take something, in paper-doll order.
local SLOT_ORDER = {}
do
    local has = {}
    for _, e in ipairs(DATA.enhancements) do
        for _, slot in ipairs(e.slots or {}) do has[slot] = true end
    end
    for _, s in ipairs(Gear.SLOTS) do
        if has[s[1]] then SLOT_ORDER[#SLOT_ORDER + 1] = s[1] end
    end
end
Enhance.SLOT_ORDER = SLOT_ORDER

---------------------------------------------------------------------------
-- Lookups
---------------------------------------------------------------------------
function Enhance.ItemName(id)
    local it = DATA.items[id]
    return it and it.name or ("item " .. tostring(id))
end

function Enhance.ItemText(id)
    local it = DATA.items[id]
    return (QUALITY_HEX[it and it.q or 1] or "|cffffffff") .. Enhance.ItemName(id) .. "|r"
end

function Enhance.ItemIcon(id)
    local fn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if type(fn) ~= "function" then return nil end
    local ok, _, _, _, _, icon = pcall(fn, id)
    return ok and S.Value(icon) or nil
end

-- How many you have (bags and bank).
function Enhance.Count(id)
    local fn = (C_Item and C_Item.GetItemCount) or GetItemCount
    if type(fn) ~= "function" then return 0 end
    local ok, n = pcall(fn, id, true)
    n = ok and S.Value(n) or 0
    return type(n) == "number" and n or 0
end

-- Your rank in a profession, or nil when you do not have it (or it is not read yet).
function Enhance.SkillRank(prof)
    local c = ns.Skills and ns.Skills.Char()
    local s = c and c.current and c.current[prof]
    return s and s.rank or nil
end

local function Money(copper)
    if not copper or copper <= 0 then return nil end
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if c > 0 and g == 0 then parts[#parts + 1] = c .. "c" end
    return table.concat(parts, " ")
end

-- "Enchanting 70" colored by whether you can: green you can, yellow you
-- have the profession but too low, grey you do not have it.
function Enhance.SkillText(recipe)
    if not recipe then return "" end
    local need = recipe.skill or 1
    local rank = Enhance.SkillRank(recipe.prof)
    local color = (rank and rank >= need) and HEX.good or (rank and HEX.gold) or HEX.muted
    return color .. recipe.prof .. " " .. need .. "|r" .. (rank and (HEX.muted .. " (you " .. rank .. ")|r") or "")
end

function Enhance.LearnText(recipe)
    if not recipe then return nil end
    local src = recipe.src and #recipe.src > 0 and table.concat(recipe.src, " / ") or "unknown source"
    local cost = Money(recipe.cost)
    return "learned from " .. src .. (cost and (" (" .. cost .. ")") or "")
end

-- One line: how to get an item ("Mining 125: 1 Iron Ore", "Disenchanting", "Vendor").
function Enhance.HowToGet(id)
    local it = DATA.items[id]
    if not it then return "drop or Auction House" end
    if it.made and it.made[1] then
        local r = DATA.recipes[it.made[1]]
        if r then
            local parts = {}
            for _, rg in ipairs(r.reagents or {}) do parts[#parts + 1] = rg[2] .. " " .. Enhance.ItemName(rg[1]) end
            return string.format("%s %d: %s", r.prof, r.skill or 1, table.concat(parts, ", "))
        end
    end
    return it.get or "drop or Auction House"
end

-- Tooltip lines for an item and everything it is made of.
function Enhance.TreeLines(id, count, depth, lines, seen)
    lines, seen, depth = lines or {}, seen or {}, depth or 0
    local pad = string.rep("    ", depth)
    local have = Enhance.Count(id)
    lines[#lines + 1] = pad .. (count and (count .. "x ") or "") .. Enhance.ItemText(id)
        .. HEX.muted .. "  (have " .. have .. ")|r"
    local it = DATA.items[id]
    local r = it and it.made and DATA.recipes[it.made[1]]
    if r and not seen[id] and depth < 4 then
        seen[id] = true
        lines[#lines + 1] = pad .. "    " .. Enhance.SkillText(r) .. HEX.muted .. "  ·  " .. (Enhance.LearnText(r) or "") .. "|r"
        for _, rg in ipairs(r.reagents or {}) do Enhance.TreeLines(rg[1], rg[2] * math.ceil((count or 1) / (r.makes or 1)), depth + 1, lines, seen) end
    else
        lines[#lines + 1] = pad .. "    " .. HEX.muted .. (it and it.get or "drop or Auction House") .. "|r"
    end
    return lines
end

---------------------------------------------------------------------------
-- What fits what
---------------------------------------------------------------------------
local function ItemClass(link)
    local fn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if type(link) ~= "string" or type(fn) ~= "function" then return nil end
    local ok, _, _, _, equipLoc, _, classID, subclassID = pcall(fn, link)
    if not ok then return nil end
    return S.Value(equipLoc), S.Value(classID), S.Value(subclassID)
end

-- "enchanted" when the item link carries a permanent enchant.
function Enhance.IsEnchanted(link)
    local enchant = type(link) == "string" and link:match("item:%d+:(%d*)")
    return enchant ~= nil and enchant ~= "" and enchant ~= "0"
end

-- Can this go on that item? Returns ok, reason (why not).
function Enhance.Fits(e, slot, link, playerLevel, itemLevel)
    if not link then return false, "nothing equipped" end
    local equipLoc, classID, subclass = ItemClass(link)
    local kind = e.kind
    if kind == "shield" and equipLoc ~= "INVTYPE_SHIELD" then return false, "needs a shield" end
    if kind == "twohand" and equipLoc ~= "INVTYPE_2HWEAPON" then return false, "needs a two-handed weapon" end
    if (kind == "weapon" or kind == "bladed" or kind == "blunt") and not WEAPON_LOCS[equipLoc or ""] then
        return false, "needs a melee weapon"
    end
    if kind == "bladed" and classID == 2 and subclass and not BLADED[subclass] then return false, "for bladed weapons" end
    if kind == "blunt" and classID == 2 and subclass and not BLUNT[subclass] then return false, "for blunt weapons" end
    if kind == "bowgun" and not (classID == 2 and BOWGUN[subclass or -1]) then return false, "needs a bow, gun or crossbow" end
    if e.level and playerLevel and playerLevel < e.level then return false, "requires level " .. e.level end
    if e.minItemLevel and itemLevel and itemLevel < e.minItemLevel then
        return false, "only on items level " .. e.minItemLevel .. "+"
    end
    return true
end

-- Options for a slot, best (highest skill) first.
function Enhance.ForSlot(slot)
    local out = {}
    for _, e in ipairs(DATA.enhancements) do
        for _, s in ipairs(e.slots or {}) do
            if s == slot then out[#out + 1] = e break end
        end
    end
    table.sort(out, function(a, b)
        local ra, rb = DATA.recipes[a.spell], DATA.recipes[b.spell]
        local sa, sb = ra and ra.skill or 0, rb and rb.skill or 0
        if sa ~= sb then return sa > sb end
        return a.name < b.name
    end)
    return out
end

---------------------------------------------------------------------------
-- Character window tab
---------------------------------------------------------------------------
local state = { slot = nil, fitsOnly = true, temporary = false }
Enhance.state = state

-- Professions that offer something, in a fixed order (others after them).
local PROF_ORDER = { "Enchanting", "Leatherworking", "Blacksmithing", "Engineering" }
do
    local seen = {}
    for _, p in ipairs(PROF_ORDER) do seen[p] = true end
    for _, e in ipairs(DATA.enhancements) do
        local r = DATA.recipes[e.spell]
        if r and not seen[r.prof] then seen[r.prof] = true PROF_ORDER[#PROF_ORDER + 1] = r.prof end
    end
end
Enhance.PROFESSIONS = PROF_ORDER
-- Short chip labels so all chips fit one row.
local SHORT = { Enchanting = "Enchanting", Leatherworking = "Leather", Blacksmithing = "Smithing", Engineering = "Engineer" }

local function ProfOf(e)
    local r = DATA.recipes[e.spell]
    return r and r.prof or "?"
end

-- Profession filter (saved): hidden professions, and "my professions only".
function Enhance.ProfShown(prof)
    local d = ns.DB()
    if d.enhanceHidden and d.enhanceHidden[prof] then return false end
    if d.enhanceMineOnly and not Enhance.SkillRank(prof) then return false end
    return true
end

-- Passes every filter for this slot's item?
local function Passes(e, slot, link, playerLevel, itemLevel)
    local fits, why = Enhance.Fits(e, slot, link, playerLevel, itemLevel)
    if not fits and state.fitsOnly then return false end
    if e.temporary and not state.temporary then return false end
    if not Enhance.ProfShown(ProfOf(e)) then return false end
    return true, fits, why
end

-- Click: show / hide one profession. Right-click: only this one (again: all).
function Enhance.ToggleProf(prof, solo)
    local d = ns.DB()
    d.enhanceHidden = d.enhanceHidden or {}
    if solo then
        local alreadySolo = true
        for _, p in ipairs(PROF_ORDER) do
            if (p == prof) == (d.enhanceHidden[p] == true) then alreadySolo = false end
        end
        for _, p in ipairs(PROF_ORDER) do d.enhanceHidden[p] = (not alreadySolo and p ~= prof) or nil end
    else
        d.enhanceHidden[prof] = not d.enhanceHidden[prof] or nil
    end
end

local function CurrentItems()
    local items = {}
    for _, s in ipairs(Gear.SLOTS) do
        local link = S.Call(GetInventoryItemLink, "player", s[1])
        items[s[1]] = type(link) == "string" and link or nil
    end
    return items
end

local function ItemLevelOf(link)
    if type(link) ~= "string" then return nil end
    local fn = (C_Item and C_Item.GetDetailedItemLevelInfo) or GetDetailedItemLevelInfo
    if type(fn) == "function" then
        local ok, ilvl = pcall(fn, link)
        if ok and type(ilvl) == "number" and ilvl > 0 then return ilvl end
    end
    local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if type(info) == "function" then
        local ok, _, _, _, ilvl = pcall(info, link)
        if ok and type(ilvl) == "number" and ilvl > 0 then return ilvl end
    end
    return nil
end

local function ShowSpellOrItem(owner, e)
    local t = ns.Tooltip.Open(owner)
    local ok = e.item and t:Item("item:" .. e.item)
    if not ok and not t:Spell(e.spell) then t:Title(e.name) end
    t:Blank()
    t:Line(e.effect or "")
    t:Show()
end

local function BuildView(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()

    v.left = Style.Card(v, "Your gear")
    v.left:SetPoint("TOPLEFT")
    v.left:SetPoint("BOTTOMLEFT")
    v.left:SetWidth(330)
    v.left.sub:SetText("Click a slot to see what you can put on it")
    v.slots = Style.List(v.left.content, { labelWidth = 62, colWidths = { 66 }, onClick = function(item)
        state.slot = item.slot
        ns.GearUI.Refresh()
    end })

    v.right = Style.Card(v, "")
    v.right:SetPoint("TOPLEFT", v.left, "TOPRIGHT", 10, 0)
    v.right:SetPoint("BOTTOMRIGHT")
    v.fits = Style.Button(v.right, "", 130, function() state.fitsOnly = not state.fitsOnly ns.GearUI.Refresh() end,
        "Show only what fits this item and your level, or everything for this slot.")
    v.fits:SetPoint("TOPRIGHT", -10, -10)
    v.temp = Style.Button(v.right, "", 130, function() state.temporary = not state.temporary ns.GearUI.Refresh() end,
        "Also show temporary weapon improvements (sharpening stones, weightstones, oils).")
    v.temp:SetPoint("RIGHT", v.fits, "LEFT", -6, 0)
    -- Profession chips above the options.
    v.chips = {}
    local chipRow = CreateFrame("Frame", nil, v.right.content)
    chipRow:SetPoint("TOPLEFT", 6, -4)
    chipRow:SetPoint("TOPRIGHT", -6, -4)
    chipRow:SetHeight(24)
    local x = 0
    for _, prof in ipairs(PROF_ORDER) do
        local chip = Style.Button(chipRow, SHORT[prof] or prof, 94, function(_, button)
            Enhance.ToggleProf(prof, button == "RightButton")
            ns.GearUI.Refresh()
        end, "Click: show or hide " .. prof .. ". Right-click: only " .. prof .. " (again: all).", { height = 22, title = prof })
        chip:SetPoint("TOPLEFT", x, 0)
        chip.prof = prof
        x = x + 98
        v.chips[#v.chips + 1] = chip
    end
    v.mine = Style.Button(chipRow, "Mine", 70, function()
        ns.DB().enhanceMineOnly = not ns.DB().enhanceMineOnly
        ns.GearUI.Refresh()
    end, "Only professions this character has (read from the Skills tab).", { height = 22, title = "My professions" })
    v.mine:SetPoint("TOPLEFT", x + 6, 0)
    local listHolder = CreateFrame("Frame", nil, v.right.content)
    listHolder:SetPoint("TOPLEFT", 0, -32)
    listHolder:SetPoint("BOTTOMRIGHT")
    v.options = Style.List(listHolder, { labelWidth = 70, colWidths = { 170 } })

    -- On: accent border and white text; off: dim.
    local function PaintChip(chip, on, label)
        chip.borderColor = on and COLORS.accent or nil
        local c = on and COLORS.accent or COLORS.border
        chip:SetBorderColor(c[1], c[2], c[3], 1)
        chip:SetLabel(label)
        chip.label:SetTextColor(on and 1 or 0.45, on and 1 or 0.45, on and 1 or 0.45)
    end

    function v:Footer()
        return "Green: you can make it. Yellow: your skill is too low. Hover anything for the full recipe tree. Data: Wowhead Classic, "
            .. tostring(DATA.generated or "?") .. "."
    end

    function v:Refresh()
        local items = CurrentItems()
        local playerLevel = S.Call(UnitLevel, "player")
        if not state.slot then
            for _, slot in ipairs(SLOT_ORDER) do
                if items[slot] then state.slot = slot break end
            end
            state.slot = state.slot or SLOT_ORDER[1]
        end

        local rows = {}
        for _, slot in ipairs(SLOT_ORDER) do
            local link = items[slot]
            local _, _, icon = Gear.ItemBasics(link)
            local count = 0
            local ilvl = ItemLevelOf(link)
            for _, e in ipairs(Enhance.ForSlot(slot)) do
                if not e.temporary and Enhance.Fits(e, slot, link, playerLevel, ilvl) and Enhance.ProfShown(ProfOf(e)) then
                    count = count + 1
                end
            end
            local enchanted = Enhance.IsEnchanted(link)
            rows[#rows + 1] = {
                slot = slot, label = Gear.SLOT_NAMES[slot], link = link, icon = link and (icon or 134400) or 136528, iconEmpty = not link,
                text = link or (HEX.dim .. "empty|r"),
                cols = { enchanted and (HEX.good .. "enchanted|r") or (count > 0 and (HEX.gold .. count .. " options|r") or (HEX.dim .. "-|r")) },
                accent = slot == state.slot and COLORS.accent or nil,
                tint = slot == state.slot and { COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.12 } or nil,
                tooltip = link and function(owner) ns.Tooltip.Item(owner, link) end or nil,
            }
        end
        self.slots:SetItems(rows)

        local slot, link = state.slot, items[state.slot]
        local itemLevel = ItemLevelOf(link)
        self.fits:SetLabel(state.fitsOnly and "Fits this item" or "Everything")
        self.temp:SetLabel(state.temporary and "With temporary" or "Permanent only")
        self.right.title:SetText((Gear.SLOT_NAMES[slot] or "?") .. "  " .. (link or (HEX.dim .. "nothing equipped|r")))
        self.right.sub:SetText((Enhance.IsEnchanted(link) and (HEX.good .. "Already enchanted|r: a new enchant replaces it.  ") or "")
            .. (itemLevel and ("Item level " .. itemLevel .. "  ·  ") or "") .. "best first")

        -- Chip counts: what this slot would show for each profession.
        local perProf = {}
        for _, e in ipairs(Enhance.ForSlot(slot)) do
            local fits = Enhance.Fits(e, slot, link, playerLevel, itemLevel)
            if (fits or not state.fitsOnly) and (state.temporary or not e.temporary) then
                perProf[ProfOf(e)] = (perProf[ProfOf(e)] or 0) + 1
            end
        end
        for _, chip in ipairs(self.chips) do
            local n = perProf[chip.prof] or 0
            PaintChip(chip, Enhance.ProfShown(chip.prof), (SHORT[chip.prof] or chip.prof) .. "  " .. (n > 0 and n or (HEX.dim .. "0|r")))
        end
        PaintChip(self.mine, ns.DB().enhanceMineOnly, "Mine")

        local out = {}
        local shown = 0
        for _, e in ipairs(Enhance.ForSlot(slot)) do
            local pass, fits, why = Passes(e, slot, link, playerLevel, itemLevel)
            if pass then
                shown = shown + 1
                local r = DATA.recipes[e.spell]
                out[#out + 1] = {
                    text = HEX.gold .. e.name .. "|r" .. (e.temporary and (HEX.muted .. "  temporary|r") or "")
                        .. (not fits and ("  " .. HEX.bad .. why .. "|r") or ""),
                    cols = { Enhance.SkillText(r) }, tint = { 1, 1, 1, 0.045 },
                    accent = fits and COLORS.accent or { 0.4, 0.4, 0.4 },
                    tooltip = function(owner) ShowSpellOrItem(owner, e) end,
                }
                out[#out + 1] = { label = "Effect", text = HEX.white .. (e.effect or "") .. "|r",
                    tooltip = function(owner) ns.Tooltip.Text(owner, { e.name, e.effect or "" }) end }
                if e.item then
                    local have = Enhance.Count(e.item)
                    local buy = ns.Prices and ns.Prices.Get(e.item)
                    out[#out + 1] = { label = "Use", text = Enhance.ItemText(e.item) .. (e.level and (HEX.muted .. "  requires level " .. e.level .. "|r") or "")
                        .. (buy and (HEX.muted .. "  ·  buy it: " .. ns.Professions.PriceText(e.item) .. "|r") or ""),
                        cols = { have > 0 and (HEX.good .. "you have " .. have .. "|r") or (HEX.muted .. "you have none|r") },
                        icon = Enhance.ItemIcon(e.item) or 134400,
                        tooltip = function(owner) ns.Tooltip.Item(owner, "item:" .. e.item) end }
                end
                out[#out + 1] = { label = e.item and "Made by" or "Who", text = Enhance.SkillText(r)
                    .. HEX.muted .. "  ·  " .. (Enhance.LearnText(r) or "") .. "|r" }
                for _, tid in ipairs(r and r.tools or {}) do
                    local have = Enhance.Count(tid)
                    out[#out + 1] = { label = "Tool", text = Enhance.ItemText(tid) .. HEX.muted .. "  ·  " .. Enhance.HowToGet(tid) .. "|r",
                        cols = { have > 0 and (HEX.good .. "have it|r") or (HEX.bad .. "missing|r") }, icon = Enhance.ItemIcon(tid) or 134400,
                        tooltip = function(owner) ns.Tooltip.Text(owner, Enhance.TreeLines(tid, 1)) end }
                end
                for _, rg in ipairs(r and r.reagents or {}) do
                    local id, need = rg[1], rg[2]
                    local have = Enhance.Count(id)
                    out[#out + 1] = {
                        label = "Reagent", icon = Enhance.ItemIcon(id) or 134400,
                        text = need .. "x " .. Enhance.ItemText(id) .. HEX.muted .. "  ·  " .. Enhance.HowToGet(id)
                            .. (ns.Professions and ("  ·  " .. ns.Professions.PriceText(id)) or "") .. "|r",
                        cols = { (have >= need and HEX.good or HEX.bad) .. "have " .. have .. " / " .. need .. "|r" },
                        tooltip = function(owner) ns.Tooltip.Text(owner, Enhance.TreeLines(id, need)) end,
                    }
                end
                -- What it costs: materials at your Auction House prices (vendor when cheaper).
                if ns.Professions and r and r.reagents and #r.reagents > 0 then
                    local cost, guessed = 0, false
                    for _, rg in ipairs(r.reagents) do
                        local unit, how = ns.Professions.ItemPrice(rg[1])
                        if how == "ah" or how == "unknown" then guessed = true end
                        cost = cost + unit * rg[2]
                    end
                    out[#out + 1] = { label = "Cost", text = HEX.gold .. ns.Professions.Money(cost) .. "|r" .. HEX.muted .. "  materials"
                        .. (guessed and "  (some not seen on the Auction House: estimated)" or "  (your Auction House prices)") .. "|r" }
                end
                out[#out + 1] = { text = "" }
            end
        end
        if shown == 0 then
            out[1] = { text = HEX.muted .. (link and "Nothing for these filters. Try \"Everything\" or turn a profession back on." or "Equip something in this slot first.") .. "|r" }
        end
        self.options:SetItems(out)
    end
    return v
end

ns.GearUI.AddView({ key = "enhance", label = "Enhance", build = BuildView })

-- Opens the tab on a slot (from the Gear tab).
function Enhance.ShowSlot(slot)
    state.slot = slot
    ns.GearUI.Show("enhance")
end

local function Slash(command)
    if command ~= "enhance" then return false end
    ns.GearUI.Toggle("enhance")
    return true
end

ns.RegisterModule("Enhance", {
    defaults = { enhanceHidden = {}, enhanceMineOnly = false },
    slash = Slash,
})
