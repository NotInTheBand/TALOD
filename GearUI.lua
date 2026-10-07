-- TALOD - Character window (/talod char, /talod gear, /talod skills): gear
-- snapshots with a before/after comparison, the ledger of changes, stat
-- progress by level, where items came from, and views other modules add
-- (Skills). Built the first time it is opened, in the shared Style.

local ADDON_NAME, ns = ...
local Gear = ns.Gear

local UI = {}
ns.GearUI = UI

local PAD = 12
local Style = ns.Style
local COLORS, HEX = Style.COLORS, Style.HEX
local Text, Button, Card, List = Style.Text, Style.Button, Style.Card, Style.List
local ShowItemTooltip, ShowTextTooltip, Texture = ns.Tooltip.Item, ns.Tooltip.Text, Style.Texture

-- Character stats in groups. "dmg" is shown as one "min - max" row.
local STAT_GROUPS = {
    { "Attributes", { "str", "agi", "sta", "int", "spi" } },
    { "Health and defense", { "hp", "mana", "armor", "def", "dodge", "parry", "block" } },
    { "Melee", { "ap", "crit", "hit", "dmg", "speed", "dps" } },
    { "Ranged", { "rap", "rcrit" } },
    { "Spell", { "spell", "heal", "scrit", "shit", "regen" } },
    { "Resistances", { "resFire", "resNature", "resFrost", "resShadow", "resArcane" } },
}
local SLOT_TOKENS = { [1] = "HeadSlot", [2] = "NeckSlot", [3] = "ShoulderSlot", [15] = "BackSlot", [5] = "ChestSlot",
    [4] = "ShirtSlot", [19] = "TabardSlot", [9] = "WristSlot", [10] = "HandsSlot", [6] = "WaistSlot", [7] = "LegsSlot",
    [8] = "FeetSlot", [11] = "Finger0Slot", [12] = "Finger1Slot", [13] = "Trinket0Slot", [14] = "Trinket1Slot",
    [16] = "MainHandSlot", [17] = "SecondaryHandSlot", [18] = "RangedSlot" }

local frame
local views = {}
local state = { view = "snapshots", char = nil, a = nil, b = nil, stat = "sta" }

local function db() return ns.DB() end
local function CharData() return db().gear[state.char or ""] end
local function Date(t) return t and date("%b %d  %H:%M", t) or "?" end

local function ItemLevel(link)
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

local function EmptySlotIcon(slot)
    if type(GetInventorySlotInfo) ~= "function" or not SLOT_TOKENS[slot] then return 136528 end
    local ok, _, texture = pcall(GetInventorySlotInfo, SLOT_TOKENS[slot])
    return ok and texture or 136528
end

---------------------------------------------------------------------------
-- Snapshots view
---------------------------------------------------------------------------
local REASONS = { equip = "gear change", level = "level up", first = "first snapshot", manual = "manual", talents = "talents" }

local function SnapshotReason(s)
    local text = s.name and (HEX.gold .. s.name .. "|r") or (HEX.muted .. (REASONS[s.reason] or s.reason or "") .. "|r")
    if Gear.IsPartial(s) then text = text .. "  " .. HEX.bad .. "stats hidden|r" end
    return text
end

-- The first and last snapshots whose stats were readable (a snapshot taken
-- with hidden stats would show every stat as a change). Falls back to the
-- plain first / last when none is readable.
local function ReadableEnds(snaps)
    local first, last
    for i = 1, #snaps do if not Gear.IsPartial(snaps[i]) then first = snaps[i] break end end
    for i = #snaps, 1, -1 do if not Gear.IsPartial(snaps[i]) then last = snaps[i] break end end
    return first or snaps[1], last or snaps[#snaps]
end

local function StatRow(key, a, b)
    if key == "dmg" then
        local function Range(s) return (s and s.dmgMin) and string.format("%d - %d", s.dmgMin, s.dmgMax or s.dmgMin) or nil end
        local va, vb = Range(a), b and Range(b)
        if not va and not vb then return nil end
        return { label = "", text = "Damage", cols = { va or "-", b and (HEX.compare .. (vb or "-") .. "|r") or nil } }
    end
    local label, kind = Gear.StatInfo(key)
    local va, vb = a.stats[key], b and b.stats[key]
    if va == nil and vb == nil then return nil end
    local diff
    if b then
        -- Zeros are not stored, so a missing stat is 0 — unless that
        -- snapshot's stats were hidden: then it is unknown, never a change.
        if (va == nil and Gear.IsPartial(a)) or (vb == nil and Gear.IsPartial(b)) then
            diff = HEX.gold .. "?|r"
        else
            local d = (va or 0) - (vb or 0)
            diff = math.abs(d) >= 0.005 and ((d > 0 and HEX.good or HEX.bad) .. Gear.FormatStat(kind, d, true) .. "|r") or (HEX.dim .. "=|r")
        end
    end
    return { text = label, cols = { Gear.FormatStat(kind, va), b and (HEX.compare .. Gear.FormatStat(kind, vb) .. "|r") or nil, diff } }
end

-- Rows for what is behind the numbers: level, talents, passives, form,
-- weapon enchants, buffs. Differences with the compared snapshot show "!=".
local function ConditionRows(c, a, b)
    local rows = {}
    local function Row(label, va, vb, same, tooltip)
        local mark
        if b then mark = same and (HEX.dim .. "=|r") or (HEX.gold .. "differs|r") end
        rows[#rows + 1] = { text = label, cols = { va or "-", b and (HEX.compare .. (vb or "-") .. "|r") or nil, mark }, tooltip = tooltip }
    end
    local ta, tb = Gear.TalentSet(c, a.talents), b and Gear.TalentSet(c, b.talents)
    local pa, pb = Gear.PassiveSet(c, a.passives), b and Gear.PassiveSet(c, b.passives)
    Row("Level", a.level and tostring(a.level), b and b.level and tostring(b.level), not b or a.level == b.level)
    Row("Talents", ta and ta.summary or "?", tb and tb.summary or (b and "?"), not b or a.talents == b.talents, function(owner)
        local lines = { "Talents" .. (ta and ta.summary and ("  " .. ta.summary) or "") }
        if not ta then lines[#lines + 1] = "Not readable on this client (see the passive spells row)." end
        local names = {}
        for name, rank in pairs(ta and ta.picks or {}) do names[#names + 1] = name .. " " .. rank end
        table.sort(names)
        for _, n in ipairs(names) do lines[#lines + 1] = n end
        if b and tb and a.talents ~= b.talents then
            local gained, lost = ns.Conditions.TalentDiff(tb, ta)
            if #gained > 0 then lines[#lines + 1] = HEX.good .. "Only here: " .. table.concat(gained, ", ") .. "|r" end
            if #lost > 0 then lines[#lines + 1] = HEX.bad .. "Only in the compared one: " .. table.concat(lost, ", ") .. "|r" end
        end
        ShowTextTooltip(owner, lines)
    end)
    Row("Passive spells", pa and tostring(#pa.ids) or "?", pb and tostring(#pb.ids) or (b and "?"), not b or a.passives == b.passives, function(owner)
        local lines = { "Passive spells", "Talent effects, racials and other bonuses show up here." }
        if b and pb and a.passives ~= b.passives then
            local gained, lost = ns.Conditions.PassiveDiff(pb, pa)
            if #gained > 0 then lines[#lines + 1] = HEX.good .. "Only here: " .. table.concat(gained, ", ") .. "|r" end
            if #lost > 0 then lines[#lines + 1] = HEX.bad .. "Only in the compared one: " .. table.concat(lost, ", ") .. "|r" end
        else
            local names = {}
            for _, id in ipairs(pa and pa.ids or {}) do names[#names + 1] = ns.Conditions.SpellName(id) or ("spell " .. id) end
            table.sort(names)
            lines[#lines + 1] = table.concat(names, ", ")
        end
        ShowTextTooltip(owner, lines)
    end)
    Row("Form / stance", a.form, b and b.form, not b or (a.form or "none") == (b.form or "none"))
    Row("Weapon enchants", a.weapon, b and b.weapon, not b or (a.weapon or "none") == (b.weapon or "none"),
        function(owner) ShowTextTooltip(owner, { "Temporary weapon enchants", "Poisons, sharpening stones, oils (enchant IDs, main hand / off hand)." }) end)
    Row("Buffs", tostring(a.buffs or 0), b and tostring(b.buffs or 0), not b or (a.buffList or "") == (b.buffList or ""), function(owner)
        local names = {}
        for id in (a.buffList or ""):gmatch("[^,]+") do names[#names + 1] = ns.Conditions.SpellName(tonumber(id)) or id end
        ShowTextTooltip(owner, { "Buffs when this was taken", #names > 0 and table.concat(names, ", ") or "none" })
    end)
    return rows
end

local function BuildSnapshots(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()

    v.listCard = Card(v, "Snapshots")
    v.listCard:SetPoint("TOPLEFT")
    v.listCard:SetPoint("BOTTOMLEFT")
    v.listCard:SetWidth(230)
    v.snaps = List(v.listCard.content, { colWidths = { 44 }, search = true, time = true, onClick = function(item, button)
        if button == "RightButton" then
            state.b = (state.b == item.index) and nil or item.index
        else
            state.a, state.b = item.index, nil
        end
        UI.Refresh()
    end })

    v.itemsCard = Card(v, "Equipped")
    v.itemsCard:SetPoint("TOPLEFT", v.listCard, "TOPRIGHT", 10, 0)
    v.itemsCard:SetPoint("BOTTOMLEFT", v.listCard, "BOTTOMRIGHT", 10, 0)
    v.itemsCard:SetWidth(330)
    v.items = List(v.itemsCard.content, { labelWidth = 64, colWidths = { 34 }, onClick = function(item)
        if item.slot and ns.Enhance then ns.Enhance.ShowSlot(item.slot) end
    end })

    v.statsCard = Card(v, "Character stats")
    v.statsCard:SetPoint("TOPLEFT", v.itemsCard, "TOPRIGHT", 10, 0)
    v.statsCard:SetPoint("BOTTOMRIGHT")
    v.stats = List(v.statsCard.content, { colWidths = { 54, 54, 54 } })

    function v:Footer()
        return "Click a snapshot to show it. Right-click another to compare (default: the one before).", "Delete snapshot"
    end
    function v:FooterAction()
        local c = CharData()
        if c and state.a and c.snapshots[state.a] then
            Gear.DeleteSnapshot(state.char, state.a)
            state.a, state.b = nil, nil
            UI.Refresh()
        end
    end

    function v:Refresh()
        local c = CharData()
        local snaps = c and c.snapshots or {}
        if not state.a or not snaps[state.a] then state.a = #snaps > 0 and #snaps or nil end
        local bIndex = state.b or (state.a and state.a > 1 and state.a - 1) or nil
        if bIndex and not snaps[bIndex] then bIndex = nil end

        local list = {}
        for i = #snaps, 1, -1 do
            local s = snaps[i]
            local isA, isB = i == state.a, i == bIndex
            list[#list + 1] = {
                index = i, time = s.t, search = Date(s.t) .. " " .. SnapshotReason(s) .. " " .. (s.name or "") .. " " .. (s.zone or ""),
                text = Date(s.t) .. "  " .. SnapshotReason(s),
                cols = { HEX.gold .. "Lvl " .. tostring(s.level or "?") .. "|r" },
                accent = (isA and COLORS.accent) or (isB and COLORS.compare) or nil,
                tint = (isA and { COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.16 })
                    or (isB and { COLORS.compare[1], COLORS.compare[2], COLORS.compare[3], 0.14 }) or nil,
                tooltip = function(owner)
                    local lines = { "Level " .. tostring(s.level or "?") .. "  ·  " .. Date(s.t), (s.name and (s.name .. "  ·  ") or "") .. (REASONS[s.reason] or "") }
                    if s.zone then lines[#lines + 1] = s.zone end
                    if s.buffs then lines[#lines + 1] = HEX.gold .. s.buffs .. " buffs were active|r" end
                    ShowTextTooltip(owner, lines)
                end,
            }
        end
        if #list == 0 then list[1] = { text = HEX.muted .. "No snapshots yet.|r" } end
        self.snaps:SetItems(list)
        self.listCard.sub:SetText(#snaps .. " saved  ·  " .. HEX.accent .. "shown|r  " .. HEX.compare .. "compared|r")

        local a, b = state.a and snaps[state.a], bIndex and snaps[bIndex]
        local items, ilvlSum, ilvlCount, filled = {}, 0, 0, 0
        if a then
            for _, slot in ipairs(Gear.SLOTS) do
                local id, slotName = slot[1], slot[2]
                local link = a.items[id]
                local _, _, icon = Gear.ItemBasics(link)
                local ilvl = ItemLevel(link)
                if link then filled = filled + 1 end
                if ilvl and id ~= 4 and id ~= 19 then ilvlSum, ilvlCount = ilvlSum + ilvl, ilvlCount + 1 end
                local changed = b and b.items[id] ~= link
                items[#items + 1] = {
                    slot = id, label = slotName, link = link, icon = link and (icon or 134400) or EmptySlotIcon(id), iconEmpty = not link,
                    text = link or (HEX.dim .. "empty|r"),
                    cols = { ilvl and (HEX.muted .. ilvl .. "|r") or "" },
                    accent = changed and COLORS.compare or nil,
                    tooltip = function(owner)
                        local extra = changed and { { " " }, { "Compared snapshot: " .. (b.items[id] and Gear.ItemName(b.items[id]) or "empty"), "compare" } } or nil
                        if link then ShowItemTooltip(owner, link, extra)
                        elseif extra then ShowTextTooltip(owner, { slotName .. ": empty", extra[2][1] }) end
                    end,
                }
            end
            self.itemsCard.title:SetText("Equipped  " .. HEX.muted .. "level " .. tostring(a.level or "?") .. "|r")
            self.itemsCard.sub:SetText(string.format("%s  ·  %d of %d slots%s%s", Date(a.t), filled, #Gear.SLOTS,
                ilvlCount > 0 and string.format("  ·  avg item level %.1f", ilvlSum / ilvlCount) or "",
                b and ("  ·  " .. HEX.compare .. "changed vs compared|r") or ""))
        else
            self.itemsCard.title:SetText("Equipped")
            self.itemsCard.sub:SetText("")
        end
        self.items:SetItems(items)

        local stats = {}
        local differs = {}
        if a then
            differs = b and Gear.ConditionDiff(c, a, b) or {}
            stats[#stats + 1] = { header = true, text = "Conditions" .. (#differs > 0 and ("  |cffffd100(not the same)|r") or "") }
            for _, row in ipairs(ConditionRows(c, a, b)) do stats[#stats + 1] = row end
            for _, group in ipairs(STAT_GROUPS) do
                local rows = {}
                for _, key in ipairs(group[2]) do
                    local row = StatRow(key, a, b)
                    if row then rows[#rows + 1] = row end
                end
                if #rows > 0 then
                    stats[#stats + 1] = { header = true, text = group[1] }
                    for _, row in ipairs(rows) do stats[#stats + 1] = row end
                end
            end
        end
        self.stats:SetItems(stats)
        if #differs > 0 then
            self.statsCard.sub:SetText(HEX.gold .. "Different conditions: " .. table.concat(differs, ", ") .. "|r")
        else
            self.statsCard.sub:SetText(b and (HEX.accent .. "shown|r  ·  " .. HEX.compare .. "compared " .. Date(b.t) .. "|r  ·  difference")
                or (a and "Nothing to compare with yet." or ""))
        end
    end
    return v
end

---------------------------------------------------------------------------
-- Ledger view
---------------------------------------------------------------------------
-- One item swapped in a ledger entry (built when drawn).
local function LedgerChangeRow(ch)
    local _, _, icon = Gear.ItemBasics(ch.new or ch.old)
    local src = Gear.SourceText(ch.src)
    return {
        label = Gear.SLOT_NAMES[ch.slot] or tostring(ch.slot), link = ch.new, icon = icon or 134400, iconEmpty = ch.new == nil,
        text = (ch.new or (HEX.dim .. "removed|r")) .. (ch.old and ("  " .. HEX.muted .. "replaced|r " .. ch.old) or ""),
        tooltip = function(owner)
            if ch.new then ShowItemTooltip(owner, ch.new, src and { { "Got it: " .. src, "source" } } or nil)
            elseif ch.old then ShowItemTooltip(owner, ch.old) end
        end,
    }
end

-- The rows of one ledger entry: a dated header, then its details.
local function LedgerEntry(e, add, raw)
    local isLevel, isTalents = e.kind == "level", e.kind == "talents"
    local title = isLevel and ("Level " .. tostring(e.level))
        or (isTalents and (e.talentsAfter and "Talents changed" or "Passive spells changed")) or "Gear change"
    raw({
        header = true, time = e.t,
        text = title .. "|r   " .. HEX.muted .. Date(e.t)
            .. (e.zone and ("  ·  " .. e.zone) or "") .. (not isLevel and ("  ·  level " .. tostring(e.level or "?")) or "")
            .. (e.offline and "  ·  changed while " .. ns.NAME .. " was off" or "") .. "|r",
        accent = (isLevel and { 1, 0.82, 0 }) or (isTalents and COLORS.compare) or COLORS.accent,
        tint = { 1, 1, 1, 0.045 },
    })
    if isTalents then
        if e.talentsAfter then
            raw({ label = "Talents", text = (e.talentsBefore or "?") .. "  ->  " .. e.talentsAfter })
        end
        local function AddNames(label, names, color)
            if names and #names > 0 then
                raw({ label = label, text = color .. table.concat(names, ", ") .. "|r",
                    tooltip = function(owner) ShowTextTooltip(owner, { label, table.concat(names, "\n") }) end })
            end
        end
        AddNames("Gained", e.talentsGained, HEX.good)
        AddNames("Lost", e.talentsLost, HEX.bad)
        AddNames("New passive", e.passivesGained, HEX.good)
        AddNames("Lost passive", e.passivesLost, HEX.bad)
    end
    for _, ch in ipairs(e.changes or {}) do
        add(ch)
        -- The source line is known now (no item lookup): a plain row.
        local src = ch.src and Gear.SourceText(ch.src)
        if src then raw({ label = "", text = HEX.source .. "from " .. src .. "|r" }) end
    end
    raw({ label = "Measured", text = Gear.DeltaText(e.delta, 7)
            or (e.hidden and (HEX.bad .. "your stats were hidden (combat): fills in at the next readable moment|r") or (HEX.dim .. "no change|r")),
        tooltip = e.delta and function(owner)
            ShowTextTooltip(owner, { "Measured change", ((Gear.DeltaText(e.delta, nil) or ""):gsub("  ", "\n")) })
        end or nil })
    if e.itemDelta then raw({ label = "Tooltips", text = Gear.DeltaText(e.itemDelta, 7, true) }) end
    if e.repaired then
        raw({ label = "", text = HEX.muted .. "Measured after combat (the game hides your stats in combat).|r" })
    end
    local also = {}
    if e.buffsChanged then also[#also + 1] = "buffs" end
    if e.talentsChanged then also[#also + 1] = "talents" end
    if e.formChanged then also[#also + 1] = "form" end
    if e.weaponChanged then also[#also + 1] = "weapon enchants" end
    if e.levelChanged and not isLevel then also[#also + 1] = "level" end
    if #also > 0 then
        raw({ label = "", text = HEX.gold .. "Also changed: " .. table.concat(also, ", ")
            .. ". The measured numbers include that.|r" })
    end
end

local function BuildLedger(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Card(v, "Ledger")
    v.card:SetAllPoints()
    v.card.sub:SetText("Measured: your character sheet right before and after.  Tooltips: the items' own stats (buffs do not change these).")
    v.list = List(v.card.content, { labelWidth = 70, search = true, time = true, hint = "Search items, slots, sources..." })

    function v:Footer() return "Hover an item for its tooltip and where it came from; hover Measured for every stat." end

    function v:Refresh()
        -- Up to 1000 entries of several rows each: kept until the gear data
        -- changes; the item rows (item lookups) are formatted when drawn.
        local data = ns.Data.List(self.list, {
            name = "gear:ledger", sources = { "gear" }, key = state.char, row = LedgerChangeRow,
            empty = "No changes yet: equip something or level up.",
            build = function(add, raw)
                local c = CharData()
                local ledger = c and c.ledger or {}
                for i = #ledger, 1, -1 do LedgerEntry(ledger[i], add, raw) end
                return { count = #ledger }
            end,
        })
        self.card.title:SetText("Ledger  " .. HEX.muted .. data.count .. " entries|r")
    end
    return v
end

---------------------------------------------------------------------------
-- Progress view: pick a stat on the left, see it over every snapshot.
--   Line 1 (blue): the measured stat.  Line 2 (orange): the part from gear
--   (tooltip stats; primary stats and armor).  A marker under each point
--   says what happened there; hovering snaps a crosshair to the nearest
--   snapshot and tells what changed.
---------------------------------------------------------------------------
local SERIES = { total = { 0.16, 0.47, 0.84 }, gear = { 0.92, 0.41, 0.20 } }
-- Legend swatches: a colored bar drawn with a texture escape (no special glyphs).
local function Swatch(c)
    return string.format("|T%s:3:14:0:0:8:8:0:8:0:8:%d:%d:%d|t", Style.WHITE,
        math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end
local SWATCH = { total = Swatch(SERIES.total), gear = Swatch(SERIES.gear) }
local EVENT_GLYPH = { equip = "G", level = "L", talents = "T", manual = "M", first = "S" }
local EVENT_NAME = { equip = "gear change", level = "level up", talents = "talents", manual = "manual snapshot", first = "first snapshot" }

-- Rounded axis bounds and a step for 3-5 gridlines.
local function NiceRange(lo, hi)
    if hi - lo < 1e-6 then
        local pad = math.max(1, math.abs(hi) * 0.05)
        lo, hi = lo - pad, hi + pad
    end
    local span = hi - lo
    local raw = span / 4
    local mag = 10 ^ math.floor(math.log10 and math.log10(raw) or (math.log(raw) / math.log(10)))
    local step = mag
    for _, m in ipairs({ 1, 2, 2.5, 5, 10 }) do
        if raw <= m * mag then step = m * mag break end
    end
    return math.floor(lo / step) * step, math.ceil(hi / step) * step, step
end

-- The ledger entry recorded with a snapshot (same time), if any.
local function EntryFor(c, snap)
    for i = #(c.ledger or {}), 1, -1 do
        local e = c.ledger[i]
        if e.snapTime == snap.t then return e end
        if (e.snapTime or e.t or 0) < snap.t then break end
    end
    return nil
end

local function BuildProgress(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.mode = "change"          -- "change": every snapshot evenly spaced; "level": last snapshot per level
    v.page = "overview"        -- "overview": every stat as a tile; "detail": one stat's chart
    local gearCache = setmetatable({}, { __mode = "k" })
    v.detail = CreateFrame("Frame", nil, v)
    v.detail:SetAllPoints()

    -- Left: the stats.
    v.left = Card(v.detail, "Stats")
    v.left:SetPoint("TOPLEFT")
    v.left:SetPoint("BOTTOMLEFT")
    v.left:SetWidth(250)
    v.left.sub:SetText("Click one to chart it  ·  now  ·  since first")
    v.statList = List(v.left.content, { colWidths = { 54, 50 }, onClick = function(item)
        state.stat = item.key
        v.page = "detail"
        UI.Refresh()
    end })

    -- Right: the chart.
    v.card = Card(v.detail, "")
    v.card:SetPoint("TOPLEFT", v.left, "TOPRIGHT", 10, 0)
    v.card:SetPoint("BOTTOMRIGHT")
    v.card.title:SetFontObject("GameFontNormalLarge")

    local function ModeButton(label, mode)
        local b = Button(v.card, label, 96, function() v.mode = mode UI.Refresh() end,
            mode == "change" and "Every snapshot, evenly spaced: each change gets room." or "One point per level: your last snapshot at that level.")
        return b
    end
    v.byLevel = ModeButton("By level", "level")
    v.byLevel:SetPoint("TOPRIGHT", -10, -10)
    v.byChange = ModeButton("Each change", "change")
    v.byChange:SetPoint("RIGHT", v.byLevel, "LEFT", -4, 0)
    v.back = Button(v.card, "All stats", 90, function() v.page = "overview" UI.Refresh() end, "Back to every stat at a glance.")
    v.back:SetPoint("RIGHT", v.byChange, "LEFT", -12, 0)

    v.legend = Text(v.card, "GameFontHighlightSmall", "RIGHT")
    v.legend:SetPoint("TOPRIGHT", -12, -36)

    local plot = CreateFrame("Frame", nil, v.card.content)
    plot:SetPoint("TOPLEFT", 52, -18)
    plot:SetPoint("BOTTOMRIGHT", -20, 44)
    plot:EnableMouse(true)
    v.plot = plot
    v.grid, v.gridLabels, v.lines, v.points, v.marks, v.xLabels = {}, {}, {}, {}, {}, {}
    for i = 1, 6 do
        v.grid[i] = Style.HLine(plot, COLORS.grid)
        v.gridLabels[i] = Text(plot, "GameFontDisableSmall", "RIGHT")
        v.gridLabels[i]:SetWidth(46)
    end
    v.empty = Text(plot, "GameFontDisable", "CENTER")
    v.empty:SetPoint("CENTER")
    v.cross = Texture(plot, "OVERLAY", { 1, 1, 1, 0.25 })
    v.cross:SetWidth(1)
    v.cross:Hide()
    v.focus = Texture(plot, "OVERLAY", { 1, 1, 1, 1 })
    v.focus:SetSize(10, 10)
    v.focus:Hide()

    local function Line(i, color)
        local l = v.lines[i]
        if not l and plot.CreateLine then
            l = plot:CreateLine(nil, "ARTWORK")
            if l.SetThickness then l:SetThickness(2) end
            v.lines[i] = l
        end
        if l then l:SetColorTexture(color[1], color[2], color[3], 1) l:Show() end
        return l
    end
    local function Point(i, color, size)
        local p = v.points[i]
        if not p then
            p = Texture(plot, "OVERLAY")
            v.points[i] = p
        end
        p:SetSize(size, size)
        Style.Fill(p, color)
        p:Show()
        return p
    end
    local function Mark(i)
        local m = v.marks[i]
        if not m then
            m = Text(plot, "GameFontDisableSmall", "CENTER")
            m:SetWidth(16)
            v.marks[i] = m
        end
        m:Show()
        return m
    end
    local function XLabel(i)
        local l = v.xLabels[i]
        if not l then
            l = Text(plot, "GameFontDisableSmall", "CENTER")
            l:SetWidth(80)
            v.xLabels[i] = l
        end
        l:Show()
        return l
    end

    local function GearValue(snap, key)
        local itemKey = Gear.ITEM_STAT_FOR[key]
        if not itemKey then return nil end
        local cached = gearCache[snap]
        if cached == nil then
            local totals, complete = Gear.ItemTotals(snap.items)
            cached = complete and totals or false
            gearCache[snap] = cached
        end
        return cached and (cached[itemKey] or 0) or nil
    end

    -- The points to draw: { snap, x (0-1), value, gear }.
    local function Series(c, key)
        local snaps = {}
        if v.mode == "level" then
            local byLevel, levels = {}, {}
            for _, s in ipairs(c and c.snapshots or {}) do
                if s.level and s.stats[key] ~= nil then
                    if not byLevel[s.level] then levels[#levels + 1] = s.level end
                    byLevel[s.level] = s
                end
            end
            table.sort(levels)
            for _, lvl in ipairs(levels) do snaps[#snaps + 1] = byLevel[lvl] end
        else
            for _, s in ipairs(c and c.snapshots or {}) do
                if s.stats[key] ~= nil then snaps[#snaps + 1] = s end
            end
        end
        local out = {}
        for i, s in ipairs(snaps) do
            out[i] = { snap = s, x = #snaps > 1 and (i - 1) / (#snaps - 1) or 0.5, value = s.stats[key], gear = GearValue(s, key) }
        end
        return out
    end

    local function HideAll()
        for _, l in pairs(v.lines) do l:Hide() end
        for _, p in pairs(v.points) do p:Hide() end
        for _, m in pairs(v.marks) do m:Hide() end
        for _, l in pairs(v.xLabels) do l:Hide() end
        for i = 1, 6 do v.grid[i]:Hide() v.gridLabels[i]:Hide() end
        v.cross:Hide()
        v.focus:Hide()
    end

    ---------------------------------------------------------------------
    -- Overview: every stat as a tile (value, change, trend line)
    ---------------------------------------------------------------------
    local TILE_H, GAP = 78, 8
    v.overview = Card(v, "All stats")
    v.overview:SetAllPoints()
    local scroll = CreateFrame("ScrollFrame", nil, v.overview.content)
    scroll:SetPoint("TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", -6, 6)
    local grid = CreateFrame("Frame", nil, scroll)
    grid:SetSize(800, 100)
    scroll:SetScrollChild(grid)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local max = math.max(0, (grid:GetHeight() or 0) - (self:GetHeight() or 0))
        self:SetVerticalScroll(math.max(0, math.min(max, (self:GetVerticalScroll() or 0) - delta * 50)))
    end)
    scroll:SetScript("OnSizeChanged", function() if v:IsShown() and v.page == "overview" then v:Refresh() end end)
    v.tiles, v.groupLabels = {}, {}

    local function Tile(i)
        local t = v.tiles[i]
        if t then return t end
        t = CreateFrame("Button", nil, grid)
        t.bg = Texture(t, "BACKGROUND", { 1, 1, 1, 0.035 })
        t.bg:SetAllPoints()
        Style.Border(t, COLORS.cardBorder)
        t.label = Text(t, "GameFontDisableSmall")
        t.label:SetPoint("TOPLEFT", 10, -8)
        t.label:SetPoint("RIGHT", -10, 0)
        t.value = Text(t, "GameFontHighlightLarge")
        t.value:SetPoint("TOPLEFT", 10, -22)
        t.delta = Text(t, "GameFontHighlightSmall", "RIGHT")
        t.delta:SetPoint("TOPRIGHT", -10, -26)
        t.gear = Text(t, "GameFontDisableSmall", "RIGHT")
        t.gear:SetPoint("TOPRIGHT", -10, -8)
        t.spark = CreateFrame("Frame", nil, t)
        t.spark:SetPoint("BOTTOMLEFT", 10, 8)
        t.spark:SetPoint("BOTTOMRIGHT", -10, 8)
        t.spark:SetHeight(20)
        t.lines = {}
        t.dot = Texture(t.spark, "OVERLAY", SERIES.total)
        t.dot:SetSize(5, 5)
        t:SetScript("OnEnter", function(self)
            self:SetBorderColor(COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.9)
            if self.tip then ShowTextTooltip(self, self.tip) end
        end)
        t:SetScript("OnLeave", function(self)
            self:SetBorderColor(COLORS.cardBorder[1], COLORS.cardBorder[2], COLORS.cardBorder[3], COLORS.cardBorder[4])
            ns.Tooltip.Hide()
        end)
        t:SetScript("OnClick", function(self)
            state.stat = self.key
            v.page = "detail"
            UI.Refresh()
        end)
        v.tiles[i] = t
        return t
    end

    local function Spark(t, values)
        for _, l in ipairs(t.lines) do l:Hide() end
        t.dot:Hide()
        local n = #values
        if n == 0 then return end
        local W, H = (t:GetWidth() or 180) - 20, 20
        local lo, hi = math.huge, -math.huge
        for _, val in ipairs(values) do lo, hi = math.min(lo, val), math.max(hi, val) end
        local function Y(val) return hi - lo < 1e-6 and H / 2 or (val - lo) / (hi - lo) * (H - 2) + 1 end
        local function X(i) return n > 1 and (i - 1) / (n - 1) * W or W end
        if t.spark.CreateLine then
            for i = 2, n do
                local l = t.lines[i - 1]
                if not l then
                    l = t.spark:CreateLine(nil, "ARTWORK")
                    if l.SetThickness then l:SetThickness(1.5) end
                    t.lines[i - 1] = l
                end
                l:SetColorTexture(SERIES.total[1], SERIES.total[2], SERIES.total[3], 0.9)
                l:SetStartPoint("BOTTOMLEFT", t.spark, X(i - 1), Y(values[i - 1]))
                l:SetEndPoint("BOTTOMLEFT", t.spark, X(i), Y(values[i]))
                l:Show()
            end
        end
        t.dot:ClearAllPoints()
        t.dot:SetPoint("CENTER", t.spark, "BOTTOMLEFT", X(n), Y(values[n]))
        t.dot:Show()
    end

    function v:RefreshOverview()
        local c = CharData()
        local snaps = c and c.snapshots or {}
        local first, last = ReadableEnds(snaps)
        local W = math.max(400, (scroll:GetWidth() or 800))
        grid:SetWidth(W)
        local cols = W >= 760 and 4 or 3
        local tileW = (W - (cols - 1) * GAP) / cols
        local y, used, labels = 0, 0, 0
        for _, t in ipairs(self.tiles) do t:Hide() end
        for _, l in ipairs(self.groupLabels) do l:Hide() end
        if not last then
            self.overview.title:SetText("All stats")
            self.overview.sub:SetText("No snapshots yet.")
            return
        end
        for _, group in ipairs(STAT_GROUPS) do
            local keys = {}
            for _, k in ipairs(group[2]) do
                if k ~= "dmg" and last.stats[k] ~= nil then keys[#keys + 1] = k end
            end
            if #keys > 0 then
                labels = labels + 1
                local gl = self.groupLabels[labels]
                if not gl then gl = Text(grid, "GameFontNormal") self.groupLabels[labels] = gl end
                gl:ClearAllPoints()
                gl:SetPoint("TOPLEFT", 2, -y)
                gl:SetText(group[1])
                gl:Show()
                y = y + 22
                for n, k in ipairs(keys) do
                    used = used + 1
                    local t = Tile(used)
                    local col = (n - 1) % cols
                    if n > 1 and col == 0 then y = y + TILE_H + GAP end
                    t:ClearAllPoints()
                    t:SetSize(tileW, TILE_H)
                    t:SetPoint("TOPLEFT", col * (tileW + GAP), -y)
                    local label, kind = Gear.StatInfo(k)
                    local now, was = last.stats[k], first.stats[k] or 0
                    local d = now - was
                    t.key = k
                    t.label:SetText(label)
                    t.value:SetText(Gear.FormatStat(kind, now))
                    t.delta:SetText(math.abs(d) >= 0.005 and ((d > 0 and HEX.good or HEX.bad) .. Gear.FormatStat(kind, d, true) .. "|r") or (HEX.dim .. "no change|r"))
                    local gearNow = GearValue(last, k)
                    t.gear:SetText((gearNow and now ~= 0) and string.format("%d%% gear", math.floor(gearNow / now * 100 + 0.5)) or "")
                    local values = {}
                    local step = math.max(1, math.floor(#snaps / 40))
                    for i = 1, #snaps, step do
                        local val = snaps[i].stats[k]
                        if val ~= nil then values[#values + 1] = val end
                    end
                    if snaps[#snaps].stats[k] ~= nil and (#snaps - 1) % step ~= 0 then values[#values + 1] = snaps[#snaps].stats[k] end
                    t.tip = { label .. "  " .. Gear.FormatStat(kind, now),
                        string.format("%s since %s", Gear.FormatStat(kind, d, true), date("%b %d", first.t)),
                        gearNow and string.format("From gear %s  ·  from level and talents %s", Gear.FormatStat(kind, gearNow), Gear.FormatStat(kind, now - gearNow)) or nil,
                        "Click for the chart." }
                    t:Show()
                    Spark(t, values)
                end
                y = y + TILE_H + GAP + 6
            end
        end
        grid:SetHeight(math.max(1, y))
        self.overview.title:SetText("All stats  " .. HEX.muted .. "level " .. tostring(last.level or "?") .. "|r")
        self.overview.sub:SetText(string.format("%d snapshots since %s  ·  change since the first one  ·  click a stat for its chart",
            #snaps, date("%b %d", first.t)))
    end

    function v:Footer()
        if self.page == "overview" then
            return "Every stat at a glance: value now, change since your first snapshot, trend line. Click one for its chart."
        end
        return "Hover the chart for each snapshot and what changed there.  G gear  ·  L level  ·  T talents  ·  M manual"
    end

    function v:Refresh()
        self.overview:SetShown(self.page == "overview")
        self.detail:SetShown(self.page ~= "overview")
        if self.page == "overview" then
            self.points_ = nil
            self:RefreshOverview()
        else
            self:RefreshDetail()
        end
    end

    function v:RefreshDetail()
        local c = CharData()
        local key = state.stat
        local label, kind = Gear.StatInfo(key)

        -- Stat list: only stats this character has values for.
        local first, last
        if c then first, last = ReadableEnds(c.snapshots) end
        local rows = {}
        for _, group in ipairs(STAT_GROUPS) do
            local groupRows = {}
            for _, k in ipairs(group[2]) do
                if k ~= "dmg" and last and last.stats[k] ~= nil then
                    local l, kd = Gear.StatInfo(k)
                    local now, was = last.stats[k], first.stats[k] or 0
                    local d = now - was
                    local change = math.abs(d) >= 0.005 and ((d > 0 and HEX.good or HEX.bad) .. Gear.FormatStat(kd, d, true) .. "|r") or (HEX.dim .. "=|r")
                    groupRows[#groupRows + 1] = { key = k, text = (k == key and HEX.accent or "") .. l .. (k == key and "|r" or ""),
                        cols = { Gear.FormatStat(kd, now), change }, accent = k == key and COLORS.accent or nil,
                        tint = k == key and { COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.12 } or nil }
                end
            end
            if #groupRows > 0 then
                rows[#rows + 1] = { header = true, text = group[1] }
                for _, r in ipairs(groupRows) do rows[#rows + 1] = r end
            end
        end
        if #rows == 0 then rows[1] = { text = HEX.muted .. "No snapshots yet.|r" } end
        self.statList:SetItems(rows)

        for _, b in ipairs({ { self.byChange, "change" }, { self.byLevel, "level" } }) do
            local on = self.mode == b[2]
            b[1].borderColor = on and COLORS.accent or nil
            local col = on and COLORS.accent or COLORS.border
            b[1]:SetBorderColor(col[1], col[2], col[3], 1)
        end

        HideAll()
        local pts = Series(c, key)
        self.points_ = pts
        local hasGear = false
        for _, p in ipairs(pts) do if p.gear then hasGear = true end end

        -- Headline.
        if #pts == 0 then
            self.card.title:SetText(label)
            self.card.sub:SetText("")
            self.legend:SetText("")
            self.empty:SetText("No snapshots with " .. label:lower() .. " yet.")
            self.empty:Show()
            return
        end
        self.empty:Hide()
        local now, start = pts[#pts], pts[1]
        local d = now.value - start.value
        self.card.title:SetText(label .. "  " .. HEX.white .. Gear.FormatStat(kind, now.value) .. "|r")
        local parts = {}
        if #pts > 1 then
            parts[#parts + 1] = (math.abs(d) >= 0.005 and ((d > 0 and HEX.good or HEX.bad) .. Gear.FormatStat(kind, d, true) .. "|r") or "no change")
                .. " since " .. date("%b %d", start.snap.t) .. (start.snap.level and (" (level " .. start.snap.level .. ")") or "")
        else
            parts[#parts + 1] = "one snapshot so far"
        end
        if now.gear and now.value ~= 0 then
            parts[#parts + 1] = string.format("%s from gear (%d%%)", Gear.FormatStat(kind, now.gear), math.floor(now.gear / now.value * 100 + 0.5))
        end
        self.card.sub:SetText(table.concat(parts, "  ·  "))
        self.legend:SetText(SWATCH.total .. " " .. label .. (hasGear and ("     " .. SWATCH.gear .. " from gear") or ""))

        -- Scales.
        local lo, hi = math.huge, -math.huge
        for _, p in ipairs(pts) do
            lo, hi = math.min(lo, p.value, p.gear or p.value), math.max(hi, p.value, p.gear or p.value)
        end
        local yMin, yMax, step = NiceRange(lo, hi)
        local W, H = plot:GetWidth() or 500, plot:GetHeight() or 300
        if W < 10 or H < 10 then return end
        local function Y(val) return (val - yMin) / (yMax - yMin) * H end
        local function X(f) return 8 + f * (W - 16) end

        local i = 0
        for g = yMin, yMax + step * 0.01, step do
            i = i + 1
            if i > 6 then break end
            local y = Y(g)
            v.grid[i]:ClearAllPoints()
            v.grid[i]:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, y)
            v.grid[i]:SetPoint("BOTTOMRIGHT", plot, "BOTTOMRIGHT", 0, y)
            Style.Fill(v.grid[i], g == yMin and { 1, 1, 1, 0.2 } or COLORS.grid)
            v.grid[i]:Show()
            v.gridLabels[i]:ClearAllPoints()
            v.gridLabels[i]:SetPoint("RIGHT", plot, "BOTTOMLEFT", -6, y)
            v.gridLabels[i]:SetText(Gear.FormatStat(kind, g))
            v.gridLabels[i]:Show()
        end

        -- Lines, then points on top. Gear first so the measured line wins.
        local li, pi = 0, 0
        for _, series in ipairs({ "gear", "total" }) do
            local color = SERIES[series]
            local prev
            for _, p in ipairs(pts) do
                local val = series == "total" and p.value or p.gear
                if val then
                    local x, y = X(p.x), Y(val)
                    if prev then
                        li = li + 1
                        local l = Line(li, color)
                        if l then
                            l:SetStartPoint("BOTTOMLEFT", plot, prev[1], prev[2])
                            l:SetEndPoint("BOTTOMLEFT", plot, x, y)
                        end
                    end
                    if series == "total" or #pts <= 40 then
                        pi = pi + 1
                        local dot = Point(pi, color, series == "total" and 8 or 6)
                        dot:ClearAllPoints()
                        dot:SetPoint("CENTER", plot, "BOTTOMLEFT", x, y)
                        if series == "total" then p.dot = dot end
                    end
                    prev = { x, y }
                end
            end
        end

        -- What happened at each point, and a few x labels.
        for n, p in ipairs(pts) do
            if #pts <= 60 then
                local m = Mark(n)
                m:ClearAllPoints()
                m:SetPoint("TOP", plot, "BOTTOMLEFT", X(p.x), -4)
                local glyph = EVENT_GLYPH[p.snap.reason] or "·"
                m:SetText((p.snap.reason == "level" and HEX.gold or p.snap.reason == "talents" and HEX.compare or HEX.muted) .. glyph .. "|r")
            end
        end
        local labels = math.min(#pts, 5)
        for n = 1, labels do
            local idx = labels == 1 and 1 or math.floor((n - 1) * (#pts - 1) / (labels - 1) + 1.5)
            local p = pts[idx]
            local l = XLabel(n)
            l:ClearAllPoints()
            l:SetPoint("TOP", plot, "BOTTOMLEFT", X(p.x), -20)
            l:SetText(self.mode == "level" and ("level " .. tostring(p.snap.level)) or date("%b %d", p.snap.t))
        end
    end

    -- Crosshair: snaps to the nearest snapshot under the mouse.
    plot:SetScript("OnUpdate", function(self)
        local pts = v.points_
        if not pts or #pts == 0 or not (self.IsMouseOver and self:IsMouseOver()) then
            if v.hovering then v.hovering = nil v.cross:Hide() v.focus:Hide() ns.Tooltip.Hide() end
            return
        end
        local scale = self.GetEffectiveScale and self:GetEffectiveScale() or 1
        local cx = (GetCursorPosition()) / scale
        local left = self:GetLeft() or 0
        local W = self:GetWidth() or 1
        local best, bestD
        for n, p in ipairs(pts) do
            local d = math.abs(left + 8 + p.x * (W - 16) - cx)
            if not bestD or d < bestD then best, bestD = n, d end
        end
        if best == v.hovering then return end
        v.hovering = best
        local p = pts[best]
        local H = self:GetHeight() or 1
        local x = 8 + p.x * (W - 16)
        v.cross:ClearAllPoints()
        v.cross:SetPoint("TOP", self, "TOPLEFT", x, 0)
        v.cross:SetPoint("BOTTOM", self, "BOTTOMLEFT", x, 0)
        v.cross:Show()
        v.focus:ClearAllPoints()
        if p.dot then v.focus:SetPoint("CENTER", p.dot, "CENTER") v.focus:Show() end

        local c = CharData()
        local label, kind = Gear.StatInfo(state.stat)
        local s = p.snap
        local lines = { string.format("%s  %s", label, Gear.FormatStat(kind, p.value)),
            Date(s.t) .. "  ·  level " .. tostring(s.level or "?") .. (s.zone and ("  ·  " .. s.zone) or "") }
        if p.gear then lines[#lines + 1] = string.format("From gear %s  ·  from level and talents %s", Gear.FormatStat(kind, p.gear), Gear.FormatStat(kind, p.value - p.gear)) end
        if best > 1 then
            local d = p.value - pts[best - 1].value
            if math.abs(d) >= 0.005 then lines[#lines + 1] = "Since the point before: " .. (d > 0 and HEX.good or HEX.bad) .. Gear.FormatStat(kind, d, true) .. "|r" end
        end
        lines[#lines + 1] = " "
        lines[#lines + 1] = HEX.gold .. (s.name or EVENT_NAME[s.reason] or "snapshot") .. "|r"
        local e = c and EntryFor(c, s)
        if e then
            for _, ch in ipairs(e.changes or {}) do
                lines[#lines + 1] = (Gear.SLOT_NAMES[ch.slot] or "?") .. ": " .. (ch.new or "removed") .. (ch.old and ("  replaced " .. ch.old) or "")
            end
            if e.talentsAfter then lines[#lines + 1] = "Talents " .. (e.talentsBefore or "?") .. " -> " .. e.talentsAfter end
            if e.delta then lines[#lines + 1] = Gear.DeltaText(e.delta, 6) end
        end
        local talents = Gear.TalentSet(c, s.talents)
        if talents then lines[#lines + 1] = HEX.muted .. "Talents " .. talents.summary .. (s.form and s.form ~= "none" and ("  ·  " .. s.form) or "") .. "|r" end
        if s.buffs then lines[#lines + 1] = HEX.muted .. s.buffs .. " buffs active|r" end
        local t = ns.Tooltip.Open(self, "ANCHOR_NONE")
        if p.x > 0.6 then
            t:Place("RIGHT", self, "BOTTOMLEFT", x - 14, H / 2)
        else
            t:Place("LEFT", self, "BOTTOMLEFT", x + 14, H / 2)
        end
        for n, line in ipairs(lines) do
            if n == 1 then t:Title(line) else t:Line(line) end
        end
        t:Show()
    end)
    plot:SetScript("OnSizeChanged", function() if v:IsShown() and v.page ~= "overview" then v:Refresh() end end)
    return v
end

---------------------------------------------------------------------------
-- Sources view
---------------------------------------------------------------------------
local function SourceRow(a)
    local _, _, icon = Gear.ItemBasics(a.link)
    local src = Gear.SourceText(a)
    return { label = Date(a.t), link = a.link, icon = icon or 134400, text = a.link,
        cols = { HEX.source .. (src or "") .. "|r" },
        tooltip = function(owner) ShowItemTooltip(owner, a.link, src and { { "Got it: " .. src, "source" } } or nil) end }
end

local function BuildSources(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Card(v, "Sources")
    v.card:SetAllPoints()
    v.card.sub:SetText("New gear in your bags, with the window you had open when it arrived.")
    v.list = List(v.card.content, { labelWidth = 92, colWidths = { 330 }, search = true, time = true, hint = "Search items, sources..." })
    function v:Footer() return "Items you already had when the ledger started are not listed." end
    function v:Refresh()
        local data = ns.Data.List(self.list, {
            name = "gear:sources", sources = { "gear" }, key = state.char, row = SourceRow, empty = "Nothing yet.",
            build = function(add)
                local c = CharData()
                local acquired = c and c.acquired or {}
                for i = #acquired, 1, -1 do add(acquired[i], { time = acquired[i].t }) end
                return { count = #acquired }
            end,
        })
        self.card.title:SetText("Sources  " .. HEX.muted .. data.count .. " items|r")
    end
    return v
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local VIEWS = {
    { key = "snapshots", label = "Gear", build = BuildSnapshots },
    { key = "ledger", label = "Ledger", build = BuildLedger },
    { key = "progress", label = "Progress", build = BuildProgress },
    { key = "sources", label = "Sources", build = BuildSources },
}

-- Other modules add a tab here at load: { key, label, build(parent) -> view }.
-- A view has :Refresh() and :Footer() -> hint, actionLabel; :FooterAction().
function UI.AddView(def) VIEWS[#VIEWS + 1] = def end

local function Build()
    frame = Style.Window(ns.FRAME .. "CharacterWindow", "Character", nil, nil, { nav = "character" })

    frame.charButton = Button(frame, "", 220, function(_, button)
        local chars = Gear.Characters()
        if #chars == 0 then return end
        local i = 1
        for n, key in ipairs(chars) do if key == state.char then i = n end end
        i = i + (button == "RightButton" and -1 or 1)
        if i > #chars then i = 1 elseif i < 1 then i = #chars end
        state.char, state.a, state.b = chars[i], nil, nil
        UI.Refresh()
    end, "Your characters with saved data. Left-click: next. Right-click: previous.")
    frame.charButton:SetPoint("TOPRIGHT", -40, -8)
    Style.AttachDropdown(frame.charButton, function()
        local list = {}
        for _, key in ipairs(Gear.Characters()) do list[#list + 1] = { key = key, label = key } end
        return Style.ChoiceItems(list, state.char, function(key) state.char, state.a, state.b = key, nil, nil UI.Refresh() end)
    end)
    local snap = Button(frame, "Snapshot now", 110, function() StaticPopup_Show(ns.POPUP .. "GEAR_SNAPSHOT") end,
        "Saves what you wear now, with a name you choose (e.g. \"PvP set\").")
    snap:SetPoint("RIGHT", frame.charButton, "LEFT", -8, 0)

    local tabHolder = CreateFrame("Frame", nil, frame)
    tabHolder:SetPoint("TOPLEFT", PAD, -44)
    tabHolder:SetPoint("TOPRIGHT", -PAD, -44)
    tabHolder:SetHeight(26)
    frame.tabs = Style.Tabs(tabHolder, VIEWS, function(key) state.view = key UI.Refresh() end)
    local tabLine = Style.HLine(frame)
    tabLine:SetPoint("TOPLEFT", PAD, -70)
    tabLine:SetPoint("TOPRIGHT", -PAD, -70)

    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", PAD, -80)
    body:SetPoint("BOTTOMRIGHT", -PAD, 40)
    for _, def in ipairs(VIEWS) do views[def.key] = def.build(body) end

    frame.footer = Text(frame, "GameFontDisableSmall")
    frame.footer:SetPoint("BOTTOMLEFT", PAD + 2, 15)
    frame.footer:SetPoint("RIGHT", -170, 0)
    frame.action = Button(frame, "", 140, function()
        local view = views[state.view]
        if view.FooterAction then view:FooterAction() end
    end)
    frame.action:SetPoint("BOTTOMRIGHT", -PAD, 10)
    frame:HookScript("OnShow", function() UI.Refresh() end)
end

function UI.Refresh()
    if not frame or not frame:IsShown() then return end
    local chars = Gear.Characters()
    if not state.char or not (db().gear[state.char] or (db().skills and db().skills[state.char])) then
        state.char = Gear.CharKey() or chars[1]
    end
    frame.charButton:SetLabel((state.char or "no character") .. "  >")
    frame.tabs:Select(state.view)
    for key, view in pairs(views) do view:SetShown(key == state.view) end
    local view = views[state.view]
    view:Refresh()
    local hint, action = view:Footer()
    frame.footer:SetText(hint or "")
    frame.action:SetShown(action ~= nil)
    if action then frame.action:SetLabel(action) end
end

-- view: optional tab key to open on.
function UI.Show(view)
    if not frame then Build() end
    if view and views[view] then state.view = view end
    frame:Show()
    UI.Refresh()
end

function UI.Toggle(view)
    if frame and frame:IsShown() and (not view or view == state.view) then frame:Hide() else UI.Show(view) end
end

function UI.IsShown() return frame ~= nil and frame:IsShown() end
-- Every tab of the character window: gear, skills, crafts, and prices (the
-- planner and enhancements price materials).
ns.Data.Window(UI, { "gear", "skills", "crafts", "prices" })
UI.state = state
UI.views = views
UI.CharKey = function() return state.char end
UI.Date = Date
