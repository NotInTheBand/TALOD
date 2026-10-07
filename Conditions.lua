-- TALOD - Conditions: everything besides gear that moves your measured
-- stats, read for each gear snapshot so two snapshots can be compared
-- fairly: talents, passive spells, shapeshift form / stance, temporary
-- weapon enchants (poisons, stones, oils) and active buffs. Level is read
-- by Gear itself.
--
-- Talents are read from whichever API the client has: the classic talent
-- trees (Classic Era), or the modern trait system (C_ClassTalents /
-- C_Traits). On WoW Forever GetTalentInfo does not exist, so
-- the passive-spell fingerprint is the fallback: talents and
-- other account or character bonuses that change stats usually show up as
-- passive spells in the spellbook.
--
-- Talents and passives are read on the game's events and cached; the rest
-- is cheap and read every capture.

local ADDON_NAME, ns = ...
local S = ns.Secret

local Conditions = {}
ns.Conditions = Conditions

local talentCache, passiveCache
local buffScratch = {}

local function Num(v) return type(v) == "number" and v or nil end

-- Short, stable key for a list of strings.
local function Hash(text)
    local h = 5381
    for i = 1, #text do h = (h * 33 + text:byte(i)) % 2147483647 end
    return string.format("%08x", h)
end

function Conditions.SpellName(id)
    if type(id) ~= "number" then return nil end
    if C_Spell and C_Spell.GetSpellName then
        local name = S.Call(C_Spell.GetSpellName, id)
        if type(name) == "string" then return name end
    end
    if GetSpellInfo then
        local name = S.Call(GetSpellInfo, id)
        if type(name) == "string" then return name end
    end
    return nil
end

---------------------------------------------------------------------------
-- Talents
---------------------------------------------------------------------------
-- Classic trees. GetTalentTabInfo's returns moved between client
-- generations (name first, or an id first), so the tab name is the first
-- string and points are summed from the talents themselves.
local function ReadTalentTrees()
    if type(GetNumTalentTabs) ~= "function" or type(GetNumTalents) ~= "function" or type(GetTalentInfo) ~= "function" then
        return nil
    end
    local tabs, picks = {}, {}
    for tab = 1, Num(S.Call(GetNumTalentTabs)) or 0 do
        local tabName
        if type(GetTalentTabInfo) == "function" then
            local a, b = S.CallMulti(2, GetTalentTabInfo, tab)
            tabName = type(a) == "string" and a or (type(b) == "string" and b or nil)
        end
        local spent = 0
        for i = 1, Num(S.Call(GetNumTalents, tab)) or 0 do
            local name, _, _, _, rank = S.CallMulti(5, GetTalentInfo, tab, i)
            if type(rank) == "number" and rank > 0 then
                spent = spent + rank
                picks[type(name) == "string" and name or (tab .. "-" .. i)] = rank
            end
        end
        tabs[#tabs + 1] = { name = tabName or ("Tree " .. tab), spent = spent }
    end
    if #tabs == 0 then return nil end
    local parts = {}
    for _, t in ipairs(tabs) do parts[#parts + 1] = tostring(t.spent) end
    return { source = "trees", summary = table.concat(parts, "/"), tabs = tabs, picks = picks }
end

-- Modern trait system (Dragonflight-style talents on the 12.x engine).
local function ReadTraits()
    if not (C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_Traits and C_Traits.GetConfigInfo) then return nil end
    local configID = S.Call(C_ClassTalents.GetActiveConfigID)
    if type(configID) ~= "number" then return nil end
    local info = S.Value(S.Call(C_Traits.GetConfigInfo, configID))
    if type(info) ~= "table" or type(S.Value(info.treeIDs)) ~= "table" then return nil end
    local picks, spent = {}, 0
    for _, treeID in ipairs(info.treeIDs) do
        local nodes = S.Value(S.Call(C_Traits.GetTreeNodes, treeID))
        for _, nodeID in ipairs(type(nodes) == "table" and nodes or {}) do
            local node = S.Value(S.Call(C_Traits.GetNodeInfo, configID, nodeID))
            local rank = type(node) == "table" and Num(S.Value(node.activeRank)) or nil
            if rank and rank > 0 then
                spent = spent + rank
                local entryID = (type(node.activeEntry) == "table" and S.Value(node.activeEntry.entryID))
                    or (type(node.entryIDs) == "table" and node.entryIDs[1]) or nil
                local name
                local entry = entryID and S.Value(S.Call(C_Traits.GetEntryInfo, configID, entryID))
                local def = type(entry) == "table" and entry.definitionID and S.Value(S.Call(C_Traits.GetDefinitionInfo, entry.definitionID))
                if type(def) == "table" then name = Conditions.SpellName(S.Value(def.spellID)) end
                picks[name or ("node " .. nodeID)] = rank
            end
        end
    end
    return { source = "traits", summary = tostring(spent) .. " points", picks = picks }
end

function Conditions.ReadTalents()
    local t = ReadTalentTrees() or ReadTraits()
    if not t then return nil end
    local keys = {}
    for name, rank in pairs(t.picks) do keys[#keys + 1] = name .. "=" .. rank end
    table.sort(keys)
    t.sig = Hash(table.concat(keys, ";")) .. ":" .. t.summary
    return t
end

---------------------------------------------------------------------------
-- Passive spells (talent effects, racials, other bonuses)
---------------------------------------------------------------------------
local function IsPassive(spellID, index, bank)
    if C_Spell and C_Spell.IsSpellPassive then
        local v = S.Call(C_Spell.IsSpellPassive, spellID)
        if v ~= nil then return v == true end
    end
    if IsPassiveSpell then
        local v = index and S.Call(IsPassiveSpell, index, bank) or S.Call(IsPassiveSpell, spellID)
        return v == true or v == 1
    end
    return false
end

local function ReadPassivesModern()
    local book = C_SpellBook
    if not (book and book.GetNumSpellBookSkillLines and book.GetSpellBookSkillLineInfo and book.GetSpellBookItemInfo) then return nil end
    local bank = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0
    local ids = {}
    for line = 1, Num(S.Call(book.GetNumSpellBookSkillLines)) or 0 do
        local info = S.Value(S.Call(book.GetSpellBookSkillLineInfo, line))
        local offset, count = type(info) == "table" and Num(S.Value(info.itemIndexOffset)), type(info) == "table" and Num(S.Value(info.numSpellBookItems))
        for index = (offset or 0) + 1, (offset or 0) + (count or 0) do
            local item = S.Value(S.Call(book.GetSpellBookItemInfo, index, bank))
            local id = type(item) == "table" and Num(S.Value(item.spellID)) or nil
            local passive = type(item) == "table" and S.Value(item.isPassive)
            if id and (passive == true or (passive == nil and IsPassive(id))) then ids[#ids + 1] = id end
        end
    end
    return ids
end

local function ReadPassivesClassic()
    if type(GetNumSpellTabs) ~= "function" or type(GetSpellTabInfo) ~= "function" or type(GetSpellBookItemInfo) ~= "function" then return nil end
    local bank = BOOKTYPE_SPELL or "spell"
    local ids = {}
    for tab = 1, Num(S.Call(GetNumSpellTabs)) or 0 do
        local _, _, offset, count = S.CallMulti(4, GetSpellTabInfo, tab)
        for index = (Num(offset) or 0) + 1, (Num(offset) or 0) + (Num(count) or 0) do
            local _, id = S.CallMulti(2, GetSpellBookItemInfo, index, bank)
            if Num(id) and IsPassive(id, index, bank) then ids[#ids + 1] = id end
        end
    end
    return ids
end

function Conditions.ReadPassives()
    local ids = ReadPassivesModern() or ReadPassivesClassic()
    if not ids then return nil end
    table.sort(ids)
    local seen, unique = {}, {}
    for _, id in ipairs(ids) do
        if not seen[id] then seen[id] = true unique[#unique + 1] = id end
    end
    local parts = {}
    for i, id in ipairs(unique) do parts[i] = tostring(id) end
    return { ids = unique, sig = Hash(table.concat(parts, ",")) .. ":" .. #unique }
end

---------------------------------------------------------------------------
-- Cheap, read every capture
---------------------------------------------------------------------------
-- Shapeshift form or stance: its spell name, "none", or nil when unknown.
function Conditions.ReadForm()
    if type(GetShapeshiftForm) ~= "function" then return nil end
    local index = Num(S.Call(GetShapeshiftForm))
    if not index then return nil end
    if index == 0 then return "none" end
    if type(GetShapeshiftFormInfo) == "function" then
        -- Old clients: icon, name, active, castable; newer: icon, active, castable, spellID.
        local _, second, _, fourth = S.CallMulti(4, GetShapeshiftFormInfo, index)
        if type(second) == "string" then return second end
        local name = Conditions.SpellName(Num(fourth))
        if name then return name end
    end
    return "form " .. index
end

-- "mainhand enchant id / offhand enchant id", or nil without the API.
function Conditions.ReadWeaponEnchants()
    if type(GetWeaponEnchantInfo) ~= "function" then return nil end
    local hasMain, _, _, mainID, hasOff, _, _, offID = S.CallMulti(8, GetWeaponEnchantInfo)
    local main = hasMain and (Num(mainID) or "?") or "-"
    local off = hasOff and (Num(offID) or "?") or "-"
    if main == "-" and off == "-" then return "none" end
    return tostring(main) .. "/" .. tostring(off)
end

-- Sorted active buff spell IDs as a string ("" without buffs), and count.
function Conditions.ReadBuffs()
    local n = ns.ReadAuras("player", "HELPFUL", 40, buffScratch)
    local ids = {}
    for i = 1, n do ids[i] = tostring(buffScratch[i].spellId or buffScratch[i].name or "?") end
    table.sort(ids)
    return table.concat(ids, ","), n
end

---------------------------------------------------------------------------
-- Capture (cached parts refreshed on the game's events)
---------------------------------------------------------------------------
function Conditions.Invalidate(kind)
    if kind == nil or kind == "talents" then talentCache = nil end
    if kind == nil or kind == "passives" then passiveCache = nil end
end

-- { talents, passives, form, weapon, buffs, buffCount }; talents and
-- passives are the full read (Gear stores them once per distinct set).
function Conditions.Capture()
    if talentCache == nil then talentCache = Conditions.ReadTalents() or false end
    if passiveCache == nil then passiveCache = Conditions.ReadPassives() or false end
    local buffs, count = Conditions.ReadBuffs()
    return {
        talents = talentCache or nil, passives = passiveCache or nil,
        form = Conditions.ReadForm(), weapon = Conditions.ReadWeaponEnchants(), buffs = buffs, buffCount = count,
    }
end

Conditions.TALENT_EVENTS = { "CHARACTER_POINTS_CHANGED", "PLAYER_TALENT_UPDATE", "TRAIT_CONFIG_UPDATED",
    "ACTIVE_TALENT_GROUP_CHANGED", "SPELLS_CHANGED", "LEARNED_SPELL_IN_TAB" }

---------------------------------------------------------------------------
-- Differences, for warnings and the ledger
---------------------------------------------------------------------------
local function SetDiff(a, b)
    local added, removed = {}, {}
    for k, v in pairs(b or {}) do
        local old = (a or {})[k]
        if old == nil then added[#added + 1] = k .. (v ~= 1 and (" " .. v) or "")
        elseif old ~= v then added[#added + 1] = k .. " " .. old .. " -> " .. v end
    end
    for k in pairs(a or {}) do
        if (b or {})[k] == nil then removed[#removed + 1] = k end
    end
    table.sort(added)
    table.sort(removed)
    return added, removed
end

-- Talent picks gained / changed and lost from set a to set b.
function Conditions.TalentDiff(a, b)
    return SetDiff(a and a.picks, b and b.picks)
end

function Conditions.PassiveDiff(a, b)
    local function AsSet(p)
        local set = {}
        for _, id in ipairs(p and p.ids or {}) do set[Conditions.SpellName(id) or ("spell " .. id)] = 1 end
        return set
    end
    return SetDiff(AsSet(a), AsSet(b))
end

-- Lines saying how the conditions of snapshot a and b differ (empty when
-- they match). talentSet / passiveSet look stored sets up by key.
function Conditions.Describe(a, b, talentSet, passiveSet)
    local out = {}
    if a.level and b.level and a.level ~= b.level then
        out[#out + 1] = string.format("Level %d vs %d", a.level, b.level)
    end
    if a.talents and b.talents and a.talents ~= b.talents then
        local ta, tb = talentSet(a.talents), talentSet(b.talents)
        out[#out + 1] = string.format("Talents %s vs %s", ta and ta.summary or "?", tb and tb.summary or "?")
    end
    if a.passives and b.passives and a.passives ~= b.passives then
        local added, removed = Conditions.PassiveDiff(passiveSet(b.passives), passiveSet(a.passives))
        out[#out + 1] = string.format("Passive spells differ (%d only here, %d only there)", #added, #removed)
    end
    if (a.form or "none") ~= (b.form or "none") and a.form and b.form then
        out[#out + 1] = "Form: " .. a.form .. " vs " .. b.form
    end
    if (a.weapon or "none") ~= (b.weapon or "none") and a.weapon and b.weapon then
        out[#out + 1] = "Temporary weapon enchants differ"
    end
    if (a.buffList or "") ~= (b.buffList or "") then
        out[#out + 1] = string.format("Buffs differ (%d vs %d active)", a.buffs or 0, b.buffs or 0)
    end
    return out
end
