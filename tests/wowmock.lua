-- Minimal WoW API mock for offline smoke tests (Lua 5.1). Not loaded by the game.
-- It models only what TALOD touches , loosely: frames remember scripts,
-- points, shown state and text; units come from MOCK.units; item range checks
-- compare MOCK distances with the probe item ranges.

MOCK = {
    iface = 11509,
    time = 100,
    prints = {},
    sounds = {},
    events = {},       -- [frame] = { event = true }
    frames = {},
    units = {},
    secretMode = false, -- when true, values wrapped with MOCK.Secret() are secret
    combatLog = false,
}

---------------------------------------------------------------------------
-- Secrets
---------------------------------------------------------------------------
local secretMeta = {
    __index = function() error("attempt to index a secret value", 2) end,
    __concat = function() error("attempt to concatenate a secret value", 2) end,
    __lt = function() error("attempt to compare a secret value", 2) end,
    __le = function() error("attempt to compare a secret value", 2) end,
    __call = function() error("attempt to call a secret value", 2) end,
    __tostring = function() error("attempt to tostring a secret value", 2) end,
}
local secrets = setmetatable({}, { __mode = "k" })
function MOCK.Secret(v)
    local s = setmetatable({}, secretMeta)
    secrets[s] = v
    return s
end
local function isSecret(v) return type(v) == "table" and secrets[v] ~= nil end

function MOCK.EnableSecrets()
    issecretvalue = function(v) return isSecret(v) end
    canaccessvalue = function(v) return not isSecret(v) end
end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------
local Widget = {}
local widgetMeta = { __index = function(t, k)
    local m = Widget[k]
    if m then return m end
    -- Unknown methods (capitalized, like WoW's) are harmless no-ops returning nil.
    if type(k) == "string" and k:match("^%u") then return function() return nil end end
    return nil
end }

local function NewWidget(kind, name, parent)
    local w = setmetatable({ _kind = kind, _name = name, _parent = parent, _shown = true, _scripts = {}, _points = {},
        _text = "", _value = 0, _min = 0, _max = 1, _checked = false, _width = 100, _height = 20, _alpha = 1 }, widgetMeta)
    if name then _G[name] = w end
    MOCK.frames[#MOCK.frames + 1] = w
    return w
end
MOCK.NewWidget = NewWidget

function Widget:GetName() return self._name end
-- A button pressed by a key binding or /click: its OnClick runs (inside the press).
function Widget:Click(button) return self:Fire("OnClick", button or "LeftButton", false) end
function Widget:GetObjectType() return self._kind end
function Widget:SetScript(event, fn) self._scripts[event] = fn end
-- Keyboard: a frame with keys on gets every press (MOCK.KeyDown); without
-- propagation it would eat them (MOCK.keysEaten counts that).
function Widget:EnableKeyboard(on) self._keyboard = on and true or false; MOCK.keyFrames[self] = on or nil end
function Widget:SetPropagateKeyboardInput(on)
    if MOCK.lockdown then error("SetPropagateKeyboardInput: blocked in combat", 2) end
    self._propagate = on and true or false
end
function Widget:GetPropagateKeyboardInput() return self._propagate == true end
function Widget:GetScript(event) return self._scripts[event] end
function Widget:HookScript(event, fn)
    local old = self._scripts[event]
    self._scripts[event] = function(...) if old then old(...) end fn(...) end
end
function Widget:Fire(event, ...) local fn = self._scripts[event]; if fn then return fn(self, ...) end end
function Widget:Show()
    local was = self._shown; self._shown = true
    if not was then self:Fire("OnShow") end
end
function Widget:Hide()
    local was = self._shown; self._shown = false
    if was then self:Fire("OnHide") end
end
function Widget:SetShown(v) if v then self:Show() else self:Hide() end end
function Widget:IsShown() return self._shown end
function Widget:IsVisible() return self._shown end
function Widget:IsForbidden() return false end
function Widget:IsProtected() return false end
function Widget:SetPoint(...) self._points[#self._points + 1] = { ... } end
function Widget:ClearAllPoints() self._points = {} end
function Widget:GetPoint(i)
    local p = self._points[i or 1]
    if not p then return "CENTER", UIParent, "CENTER", 0, 0 end
    local rel = p[2]
    if type(rel) == "string" then rel = _G[rel] end
    return p[1], rel, p[3], p[4], p[5]
end
function Widget:SetParent(p) self._parent = p end
function Widget:GetParent() return self._parent end
-- Like the game: a frame whose size changes runs its OnSizeChanged.
local function Resized(self, w, h)
    local changed = self._width ~= w or self._height ~= h
    self._width, self._height = w, h
    if changed then self:Fire("OnSizeChanged", w, h) end
end
function Widget:SetSize(w, h) Resized(self, w, h) end
function Widget:SetWidth(w) Resized(self, w, self._height) end
function Widget:SetHeight(h) Resized(self, self._width, h) end
function Widget:GetWidth() return self._width end
function Widget:GetHeight() return self._height end
function Widget:SetAlpha(a) self._alpha = a end
function Widget:GetAlpha() return self._alpha end
function Widget:SetText(t) self._text = t end
function Widget:GetText() return self._text end
function Widget:SetFormattedText(fmt, ...) self._text = string.format(fmt, ...) end
function Widget:GetStringHeight() return 14 end
function Widget:GetStringWidth() return 100 end
function Widget:SetTextColor(r, g, b) self._color = { r, g, b } end
function Widget:GetFont() return "Fonts\\FRIZQT__.TTF", 14, "" end
function Widget:SetFont(file, size, flags) self._fontSize = size end
function Widget:CreateFontString(name) return NewWidget("FontString", name, self) end
function Widget:CreateTexture(name) return NewWidget("Texture", name, self) end
-- Textures keep what they were given (path, texcoords) so tests can read it back.
function Widget:SetTexture(path) self._texture = path end
function Widget:GetTexture() return self._texture end
function Widget:SetTexCoord(...) self._texCoord = { ... } end
function Widget:GetTexCoord()
    local c = self._texCoord or { 0, 1, 0, 1 }
    return c[1], c[2], c[3], c[4]
end
function Widget:CreateLine(name) return NewWidget("Line", name, self) end
-- Edges for snapping tests: set _l/_r/_t/_b on a frame.
function Widget:GetLeft() return self._l end
function Widget:GetRight() return self._r end
function Widget:GetTop() return self._t end
function Widget:GetBottom() return self._b end
function Widget:GetEffectiveScale() return 1 end
function Widget:GetCenter()
    -- WoW Forever: addons may not measure nameplates ("restricted regions").
    if MOCK.restrictPlates and self._isPlate then
        error("NamePlate:GetCenter(): Action[FrameMeasurement] failed because[Can't measure restricted regions]")
    end
    return self._cx, self._cy
end
function Widget:SetChecked(v) self._checked = v and true or false end
function Widget:GetChecked() return self._checked end
function Widget:SetMinMaxValues(a, b) self._min, self._max = a, b end
function Widget:GetMinMaxValues() return self._min, self._max end
function Widget:SetValue(v)
    v = math.max(self._min, math.min(self._max, v))
    self._value = v
    self:Fire("OnValueChanged", v, true)
end
function Widget:GetValue() return self._value end
function Widget:GetVerticalScroll() return 0 end
function Widget:GetFontString() return self._fs end
function Widget:SetScrollChild(c) self._child = c end
function Widget:RegisterEvent(event)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" and MOCK.iface >= 16000 and MOCK.iface < 20000 then
        error("Frame:RegisterEvent(): COMBAT_LOG_EVENT_UNFILTERED is restricted", 2)
    end
    MOCK.events[self] = MOCK.events[self] or {}
    MOCK.events[self][event] = true
end
-- Only for these units (the event's first argument), like the game.
function Widget:RegisterUnitEvent(event, ...)
    self:RegisterEvent(event)
    local units = {}
    for i = 1, select("#", ...) do units[select(i, ...)] = true end
    MOCK.events[self][event] = units
end
function Widget:UnregisterEvent(event)
    if MOCK.events[self] then MOCK.events[self][event] = nil end
end
function Widget:GetID() return self._id or 1 end
function Widget:SetAttribute(k, v) self._attr = self._attr or {}; self._attr[k] = v end
function Widget:GetAttribute(k) return self._attr and self._attr[k] end
function Widget:IsOwned(owner) return self._owner == owner end
function Widget:SetOwner(owner) self._owner = owner end
function Widget:GetFrameLevel() return self._level or 1 end
function Widget:SetFrameLevel(l) self._level = l end

function CreateFrame(kind, name, parent, template)
    if template and MOCK.missingTemplates and MOCK.missingTemplates[template] then
        error("Couldn't find inherited node: " .. template, 2)
    end
    local w = NewWidget(kind, name, parent)
    w._template = template
    if template == "UIPanelButtonTemplate" then w._fs = NewWidget("FontString", nil, w) end
    if template and template:find("CheckButton") then w.Text = NewWidget("FontString", nil, w) end
    return w
end

UIParent = NewWidget("Frame", "UIParent")
UIParent._width, UIParent._height = 1920, 1080
WorldFrame = NewWidget("Frame", "WorldFrame")
TargetFrame = NewWidget("Frame", "TargetFrame", UIParent)
GameTooltip = NewWidget("GameTooltip", "GameTooltip", UIParent)
SettingsPanel = NewWidget("Frame", "SettingsPanel", UIParent)
SettingsPanel._shown = false
for _, font in ipairs({ "GameFontNormal", "GameFontNormalLarge", "GameFontNormalHuge", "GameFontHighlight",
    "GameFontHighlightSmall", "GameFontDisable", "GameFontDisableSmall", "ChatFontNormal" }) do
    _G[font] = NewWidget("Font", font)
end

---------------------------------------------------------------------------
-- Globals
---------------------------------------------------------------------------
function GetBuildInfo() return "1.0.0", "99999", "Jan 1 2026", MOCK.iface end
function GetTime() return MOCK.time end
function CombatLogGetCurrentEventInfo() return unpack(MOCK.cleu or {}) end
MOCK.lockdown = false
function InCombatLockdown() return MOCK.lockdown end
function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    MOCK.prints[#MOCK.prints + 1] = table.concat(parts, " ")
end
function strsplit(sep, str)
    local out = {}
    for piece in (str .. sep):gmatch("(.-)" .. sep:gsub("%-", "%%-")) do out[#out + 1] = piece end
    return unpack(out)
end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
date = os.date
MOCK.now = os.time()
time = function(t) if t then return os.time(t) end return MOCK.now end
MOCK.class = "WARRIOR"
function UnitClass(unit) return MOCK.class, MOCK.class end
MOCK.stealthed = false
function IsStealthed() return MOCK.stealthed end
function IsMounted() return false end
MOCK.shift = false
function IsShiftKeyDown() return MOCK.shift end
MOCK.playerPos = nil   -- { x, y } world yards; nil = UnitPosition unavailable
function UnitPosition(unit)
    if unit ~= "player" or not MOCK.playerPos then return nil end
    return MOCK.playerPos.y, MOCK.playerPos.x, 0, 0
end
function GetUnitSpeed(unit) local u = MOCK.units[unit]; return u and u.speed or 0 end
-- Moves the player and updates distances: the target from MOCK.mobPos, and
-- any unit with its own .pos.
function MOCK.MovePlayer(x, y)
    MOCK.playerPos = { x = x, y = y }
    local t = MOCK.units.target
    if t and MOCK.mobPos then
        local dx, dy = x - MOCK.mobPos.x, y - MOCK.mobPos.y
        t.distance = math.sqrt(dx * dx + dy * dy)
    end
    for _, u in pairs(MOCK.units) do
        if u.pos then
            local dx, dy = x - u.pos.x, y - u.pos.y
            u.distance = math.sqrt(dx * dx + dy * dy)
        end
    end
end
MOCK.facing = 0
function GetPlayerFacing() return MOCK.facing end
MOCK.talents = nil  -- { { name=, rank= }, ... } in one tab
function GetNumTalentTabs() return MOCK.talents and 1 or 0 end
function GetNumTalents() return MOCK.talents and #MOCK.talents or 0 end
function GetTalentInfo(tab, i) local t = MOCK.talents[i]; return t.name, nil, 1, 1, t.rank, 3 end
function GetSpellInfo(id) if id == 13958 then return "Master of Deception" end end
SlashCmdList = {}
StaticPopupDialogs = {}
function StaticPopup_Show(which, text1, text2, data) MOCK.popup, MOCK.popupText, MOCK.popupData = which, text1, data end
function MOCK.AcceptPopup()
    local dialog = StaticPopupDialogs[MOCK.popup]
    -- No OnAccept (a Close-only box like the copy box): the button just closes it.
    if dialog.OnAccept then dialog.OnAccept(nil, MOCK.popupData) end
    MOCK.popup, MOCK.popupData = nil, nil
end
UISpecialFrames = {}
SOUNDKIT = { RAID_WARNING = 8959, ALARM_CLOCK_WARNING_3 = 12889, READY_CHECK = 8960 }
function PlaySound(kit) MOCK.sounds[#MOCK.sounds + 1] = kit end
YES, NO = "Yes", "No"
function GetZoneText() return "Elwynn Forest" end
function GetSubZoneText() return MOCK.subzone or "" end
function GetRealmName() return "Mockrealm" end

C_Timer = { After = function(_, fn) MOCK.timers = MOCK.timers or {}; MOCK.timers[#MOCK.timers + 1] = fn end }
function MOCK.RunTimers()
    local timers = MOCK.timers or {}
    MOCK.timers = {}
    for _, fn in ipairs(timers) do fn() end
end

MOCK.cvars = { nameplateMaxDistance = "20", cameraFov = "90" }
MOCK.zoom = 10
function GetCameraZoom() return MOCK.zoom end
MOCK.mouseDown = false
function IsMouseButtonDown() return MOCK.mouseDown end
MOCK.cursorX, MOCK.cursorY, MOCK.cursorDy = 0, 0, 0
function GetCursorPosition() return MOCK.cursorX, MOCK.cursorY end
function GetCursorDelta() local dy = MOCK.cursorDy; MOCK.cursorDy = 0; return 0, dy end
-- MOCK.focus: the frame under the cursor (nil = the open world).
function GetMouseFoci() return { MOCK.focus or WorldFrame } end
C_CVar = {
    GetCVar = function(name) return MOCK.cvars[name] end,
    SetCVar = function(name, value) MOCK.cvars[name] = value; return true end,
    GetCVarDefault = function(name) return MOCK.cvarDefaults[name] end,
}
MOCK.cvarDefaults = { Sound_EnableSFX = "1", Sound_SFXVolume = "1.0", Sound_MusicVolume = "0.4",
    Sound_AmbienceVolume = "0.6", Sound_EnableSoundWhenGameIsInBG = "0", Sound_EnableAllSound = "1" }
-- Map positions: the player's from MOCK.mapX/mapY on MOCK.mapID; a unit's from
-- its mapX/mapY fields (group members). nil x means "no position".
MOCK.mapID, MOCK.mapX, MOCK.mapY = 1429, 0.42, 0.65
MOCK.mapNames = { [1429] = "Elwynn Forest", [1453] = "Stormwind City" }
C_Map = {
    GetBestMapForUnit = function(unit)
        if unit == "player" then return MOCK.mapID end
        local u = MOCK.units[unit]
        return u and u.exists and (u.mapID or MOCK.mapID) or nil
    end,
    GetPlayerMapPosition = function(mapID, unit)
        local x, y
        if unit == "player" then x, y = MOCK.mapX, MOCK.mapY
        else local u = MOCK.units[unit]; if u then x, y = u.mapX, u.mapY end end
        if not x then return nil end
        return { GetXY = function() return x, y end }
    end,
    GetMapInfo = function(mapID) return { mapID = mapID, name = MOCK.mapNames[mapID] or ("Map " .. mapID) } end,
}
-- Gear: MOCK.items[id] = { equipLoc, stats = { ITEM_MOD_STAMINA_SHORT = 3, ... } },
-- MOCK.equipped[slot] = link, MOCK.bags[bag][slot] = link. Your stats are a
-- base plus what the equipped items give, plus MOCK.buffStamina.
MOCK.items, MOCK.equipped, MOCK.bags, MOCK.money = {}, {}, { [0] = {} }, 10000
MOCK.buffStamina = 0
function MOCK.ItemLink(id, name) return "|cff1eff00|Hitem:" .. id .. "::::::::20:::::|h[" .. name .. "]|h|r" end
function GetInventoryItemLink(unit, slot) if unit == "player" then return MOCK.equipped[slot] end end
local function gearSum(key)
    local total = 0
    for _, link in pairs(MOCK.equipped) do
        local it = MOCK.items[tonumber(link:match("item:(%d+)"))]
        total = total + (it and it.stats and it.stats[key] or 0)
    end
    return total
end
local STAT_KEYS = { "ITEM_MOD_STRENGTH_SHORT", "ITEM_MOD_AGILITY_SHORT", "ITEM_MOD_STAMINA_SHORT", "ITEM_MOD_INTELLECT_SHORT", "ITEM_MOD_SPIRIT_SHORT" }
-- MOCK.statsHidden: your stats are secret (WoW Forever in combat).
MOCK.levelStamina = 0
function UnitStat(unit, i)
    local base = 20 + i
    local v = base + gearSum(STAT_KEYS[i]) + (i == 3 and (MOCK.buffStamina + MOCK.levelStamina) or 0)
    if MOCK.statsHidden then return MOCK.Secret(base), MOCK.Secret(v), MOCK.Secret(0), MOCK.Secret(0) end
    return base, v, v - base, 0
end
function UnitArmor(unit)
    local v = 40 + gearSum("RESISTANCE0_NAME")
    if MOCK.statsHidden then return MOCK.Secret(40), MOCK.Secret(v), MOCK.Secret(v), 0, 0 end
    return 40, v, v, 0, 0
end
function UnitAttackPower() return 60, 0, 0 end
function GetCritChance() return 5.25 end
function GetMoney() return MOCK.money end
function GetTitleText() return MOCK.questTitle end
C_Container = {
    GetContainerNumSlots = function(bag) return MOCK.bags[bag] and 16 or 0 end,
    GetContainerItemLink = function(bag, slot) return MOCK.bags[bag] and MOCK.bags[bag][slot] end,
    -- Stack sizes: MOCK.bagCounts["bag:slot"], default 1.
    GetContainerItemInfo = function(bag, slot)
        if not (MOCK.bags[bag] and MOCK.bags[bag][slot]) then return nil end
        return { stackCount = MOCK.bagCounts[bag .. ":" .. slot] or 1 }
    end,
    -- A click on a bag item; MOCK.usedItems records (bag, slot).
    UseContainerItem = function(bag, slot) MOCK.usedItems[#MOCK.usedItems + 1] = { bag, slot } end,
}
MOCK.usedItems = {}
MOCK.bagCounts = {}

-- Skills tab lines: { name, isHeader, isExpanded, rank, temp, mod, max }.
MOCK.skillLines = {}
function GetNumSkillLines() return #MOCK.skillLines end
function GetSkillLineInfo(i) local l = MOCK.skillLines[i]; if l then return unpack(l, 1, 7) end end

-- hooksecurefunc(name, fn) / (table, name, fn): runs fn after the original.
function hooksecurefunc(a, b, c)
    local tbl, name, fn = _G, a, b
    if type(a) == "table" then tbl, name, fn = a, b, c end
    local orig = tbl[name]
    tbl[name] = function(...)
        local r = { orig(...) }
        fn(...)
        return unpack(r)
    end
end
-- Auction house (classic API): posting reads the item in the sell slot.
MOCK.sellItem = { "Copper Bar", 1 }
function GetAuctionSellItemInfo() return MOCK.sellItem[1], 133217, MOCK.sellItem[2], 1, true, 10, 10, MOCK.sellItem[2], MOCK.sellItem[2], 2840 end
function PostAuction() end
function PlaceAuctionBid() end
function GetAuctionItemInfo() return "Linen Cloth", 132889, 5, 1, true, 5, nil, 100, 10, 500 end
MOCK.inbox = {}
function GetInboxHeaderInfo(i) local m = MOCK.inbox[i]; if m then return nil, nil, m.sender, m.subject, m.money or 0, m.cod or 0, 30, 0 end end
function GetInboxInvoiceInfo(i) local m = MOCK.inbox[i]; if m and m.invoice then return m.invoice, m.item, m.player end end
-- The server answers a take later: the letter still shows its money when the
-- hooks run. MOCK.mailLater = true holds the money until MOCK.AnswerMail().
MOCK.mailAnswers = {}
function TakeInboxMoney(i)
    local m = MOCK.inbox[i]
    if not m then return end
    local money = m.money or 0
    if MOCK.mailLater then MOCK.mailAnswers[#MOCK.mailAnswers + 1] = money else MOCK.money = MOCK.money + money end
end
function MOCK.AnswerMail()
    for _, money in ipairs(MOCK.mailAnswers) do MOCK.money = MOCK.money + money end
    MOCK.mailAnswers = {}
end
function TakeInboxItem() end
-- Letters' items: MOCK.inbox[i].items = { { itemID, name, count } }.
function GetInboxNumItems() return #MOCK.inbox, #MOCK.inbox end
function GetInboxItem(i, j)
    local it = MOCK.inbox[i] and MOCK.inbox[i].items and MOCK.inbox[i].items[j]
    if it then return it[2], it[1], 134400, it[3] or 1, 1, true end
end
function GetInboxItemLink(i, j)
    local it = MOCK.inbox[i] and MOCK.inbox[i].items and MOCK.inbox[i].items[j]
    if it then return MOCK.ItemLink(it[1], it[2]) end
end
ATTACHMENTS_MAX_RECEIVE = 16
ERR_AUCTION_WON_S = "You won an auction for %s"
-- The auction row's link (classic list): MOCK.auctionLink.
MOCK.auctionLink = nil
function GetAuctionItemLink() return MOCK.auctionLink end
function AutoLootMailItem() end
function SendMail() end

C_EventUtils = { IsEventValid = function(event) return true end }

MOCK.settingsCategories = {}
Settings = {
    RegisterCanvasLayoutCategory = function(frame, name)
        local cat = { frame = frame, name = name, GetID = function() return 42 end }
        return cat
    end,
    RegisterAddOnCategory = function(cat) MOCK.settingsCategories[#MOCK.settingsCategories + 1] = cat end,
    OpenToCategory = function(id)
        SettingsPanel:Show()
        for _, cat in ipairs(MOCK.settingsCategories) do
            if cat:GetID() == id then cat.frame:SetParent(SettingsPanel); cat.frame:Show() end
        end
    end,
}

---------------------------------------------------------------------------
-- Items and range
---------------------------------------------------------------------------
local ITEM_RANGE = { [8149] = 5, [9606] = 10, [4559] = 15, [1191] = 20, [13289] = 25, [835] = 30, [18904] = 35, [4945] = 40 }
local function inRange(itemID, unit)
    local u = MOCK.units[unit]
    if not u or not u.exists or ITEM_RANGE[itemID] == nil then return nil end
    if MOCK.rangeRestricted then return nil end
    local result = u.distance <= ITEM_RANGE[itemID]
    if MOCK.secretRange then return MOCK.Secret(result) end
    return result
end
C_Item = {
    IsItemInRange = inRange,
    GetItemInfoInstant = function(id)
        if type(id) == "string" then
            local n = tonumber(id:match("item:(%d+)"))
            local it = n and MOCK.items[n]
            if not it then return nil end
            return n, "Armor", "Mail", it.equipLoc or "", 134000 + n, it.classID, it.subclassID
        end
        if ITEM_RANGE[id] then return id end
        local it = MOCK.items[id]
        if it then return id, "Armor", "Mail", it.equipLoc or "", 134000 + id, it.classID, it.subclassID end
    end,
    GetItemStats = function(link)
        local n = type(link) == "string" and tonumber(link:match("item:(%d+)"))
        local it = n and MOCK.items[n]
        if not it or it.uncached then return nil end
        local out = {}
        for k, v in pairs(it.stats or {}) do out[k] = v end
        return out
    end,
    GetItemNameByID = function(id) return "Item " .. id end,
    RequestLoadItemDataByID = function() end,
}
function CheckInteractDistance(unit, index)
    local u = MOCK.units[unit]
    if not u or not u.exists then return nil end
    if MOCK.rangeRestricted then return nil end
    local result = u.distance <= (index == 3 and 8 or 28)
    if MOCK.secretRange then return MOCK.Secret(result) end
    return result
end

---------------------------------------------------------------------------
-- Units
---------------------------------------------------------------------------
local function unitField(unit, field)
    local u = MOCK.units[unit]
    if not u then return nil end
    local v = u[field]
    if MOCK.secretMode and u.secret and u.secret[field] then return MOCK.Secret(v) end
    return v
end

function UnitExists(unit)
    local u = MOCK.units[unit]
    if u then return u.exists or false end
    -- "<unit>target": the mob's target, which the mock only knows as the player.
    if unit:sub(-6) == "target" and unit ~= "target" then
        local base = MOCK.units[unit:sub(1, -7)]
        return base ~= nil and base.targetsPlayer == true
    end
    return false
end
function UnitGUID(unit) return unitField(unit, "guid") end
function UnitName(unit) return unitField(unit, "name") end
function UnitLevel(unit) return unitField(unit, "level") end
function UnitClassification(unit) return unitField(unit, "classification") or "normal" end
function UnitCreatureType(unit) return unitField(unit, "creatureType") or "Humanoid" end
function UnitIsDeadOrGhost(unit) return unitField(unit, "dead") or false end
function UnitCanAttack(_, unit) return unitField(unit, "canAttack") end
function UnitReaction(unit) return unitField(unit, "reaction") end
function UnitIsEnemy(_, unit) return unitField(unit, "enemy") end
function UnitIsTrivial(unit) return unitField(unit, "trivial") or false end
function UnitAffectingCombat(unit) local u = MOCK.units[unit]; return u and u.combat or false end
function UnitIsUnit(a, b)
    local ua, ub = MOCK.units[a], MOCK.units[b]
    if a == b then return ua ~= nil and ua.exists end
    if b == "player" and ua and ua.isSelf then return true end
    if a:sub(-6) == "target" and a ~= "target" then
        local base = MOCK.units[a:sub(1, -7)]
        if base and base.targetsPlayer and b == "player" then return true end
        return false
    end
    return ua ~= nil and ub ~= nil and ua.exists and ub.exists and ua.guid == ub.guid
end
function UnitDetailedThreatSituation(_, unit)
    local u = MOCK.units[unit]
    if u and u.threat then return true, 3, 100, 100, 1000 end
    return nil
end

-- Auras: unit.buffs for "HELPFUL", unit.debuffs otherwise. { spellId, name,
-- icon, count, duration, expires, dispel, secret (fields secret), opaque
-- (the whole aura secret) }.
C_UnitAuras = {
    GetAuraDataByIndex = function(unit, index, filter)
        local u = MOCK.units[unit]
        local list = u and ((filter and filter:find("HELPFUL")) and u.buffs or u.debuffs)
        local aura = list and list[index]
        if not aura then return nil end
        if MOCK.secretMode and aura.opaque then return MOCK.Secret({}) end
        if MOCK.secretMode and aura.secret then
            return { spellId = MOCK.Secret(aura.spellId), name = MOCK.Secret("x"), icon = MOCK.Secret(aura.icon or 136000),
                applications = MOCK.Secret(0), duration = MOCK.Secret(0), expirationTime = MOCK.Secret(0) }
        end
        return { spellId = aura.spellId, name = aura.name or "Aura", icon = aura.icon or 136000,
            applications = aura.count or 0, duration = aura.duration or 0, expirationTime = aura.expires or 0,
            dispelName = aura.dispel }
    end,
}

MOCK.plates = {}
C_NamePlate = {
    GetNamePlateForUnit = function(unit)
        local u = MOCK.units[unit]
        if not u or not u.exists or not u.plate then return nil end
        MOCK.plates[unit] = MOCK.plates[unit] or NewWidget("Frame", nil, WorldFrame)
        MOCK.plates[unit]._isPlate = true
        MOCK.plates[unit].UnitFrame = rawget(MOCK.plates[unit], "UnitFrame") or NewWidget("Button", nil, MOCK.plates[unit])
        return MOCK.plates[unit]
    end,
}

---------------------------------------------------------------------------
-- Helpers for tests
---------------------------------------------------------------------------
-- Events, OnUpdate and timers run outside any key press or click: a
-- protected call made there is blocked (see Protected).
local function NoInput(fn, ...)
    local was = MOCK.hardware
    MOCK.hardware = false
    local ok, err = pcall(fn, ...)
    MOCK.hardware = was
    if not ok then error(err, 0) end
end

-- Key bindings: [action] = { keys }.
MOCK.keyFrames, MOCK.keysEaten = {}, 0
MOCK.bindings = { MOVEFORWARD = { "W", "UP" }, MOVEBACKWARD = { "S" }, STRAFELEFT = { "A" }, STRAFERIGHT = { "D" },
    JUMP = { "SPACE" } }
function GetBindingKey(action) return unpack(MOCK.bindings[action] or {}) end
function GetBindingAction(key)
    for action, keys in pairs(MOCK.bindings) do
        for _, k in ipairs(keys) do if k == key then return action end end
    end
    return ""
end
local function Unbind(key)
    for action, keys in pairs(MOCK.bindings) do
        for i = #keys, 1, -1 do if keys[i] == key then table.remove(keys, i) end end
    end
end
function SetBinding(key, action)
    if MOCK.lockdown then error("SetBinding: blocked in combat", 2) end
    Unbind(key)
    if action then MOCK.bindings[action] = MOCK.bindings[action] or {}; table.insert(MOCK.bindings[action], key) end
    return true
end
function SetBindingClick(key, button, mouse)
    return SetBinding(key, "CLICK " .. button .. ":" .. (mouse or "LeftButton"))
end
MOCK.savedBindings = 0
function SaveBindings() MOCK.savedBindings = MOCK.savedBindings + 1 end
function GetCurrentBindingSet() return 1 end
-- A key press: frames with keys on see it inside the press (protected calls
-- count as the press's).
function MOCK.KeyDown(key)
    local was = MOCK.hardware
    MOCK.hardware = true
    local ok, err = pcall(function()
        for frame in pairs(MOCK.keyFrames) do
            if frame:IsShown() ~= false then
                if not frame._propagate then MOCK.keysEaten = MOCK.keysEaten + 1 end
                frame:Fire("OnKeyDown", key)
            end
        end
    end)
    MOCK.hardware = was
    if not ok then error(err, 0) end
end

-- A mouse press: GLOBAL_MOUSE_DOWN arrives inside it, so protected calls made
-- from its handlers count as the click's (the game's behavior is [VERIFY]).
function MOCK.MouseDown(button)
    local was = MOCK.hardware
    MOCK.hardware = true
    local ok, err = pcall(function()
        for frame, events in pairs(MOCK.events) do
            if events.GLOBAL_MOUSE_DOWN then frame:Fire("OnEvent", "GLOBAL_MOUSE_DOWN", button or "LeftButton") end
        end
    end)
    MOCK.hardware = was
    if not ok then error(err, 0) end
end

function MOCK.FireEvent(event, ...)
    NoInput(function(...)
        for frame, events in pairs(MOCK.events) do
            local want = events[event]
            if want == true or (type(want) == "table" and want[(...)]) then frame:Fire("OnEvent", event, ...) end
        end
    end, ...)
end

function MOCK.Tick(seconds)
    MOCK.time = MOCK.time + (seconds or 0.2)
    NoInput(function()
        for _, frame in ipairs(MOCK.frames) do
            local fn = frame._scripts.OnUpdate
            if fn then fn(frame, seconds or 0.2) end
        end
        MOCK.RunTimers()
    end)
end

function MOCK.Hostile(fields)
    local u = { exists = true, guid = "Creature-0-4372-0-1-6-0000ABCDEF", name = "Kobold Vermin", level = 5,
        canAttack = true, reaction = 2, enemy = true, distance = 22, plate = true, classification = "normal" }
    for k, v in pairs(fields or {}) do u[k] = v end
    return u
end

function MOCK.LoadAddon(dir, files, addonName)
    local ns = {}
    for _, file in ipairs(files) do
        local chunk, err = loadfile(dir .. "/" .. file)
        if not chunk then error("load " .. file .. ": " .. tostring(err)) end
        chunk(addonName, ns)
    end
    MOCK.ns = ns
    return ns
end

---------------------------------------------------------------------------
-- TALOD additions: players, PvP flags, zones, groups, addon messages
---------------------------------------------------------------------------
-- Player units: MOCK.Enemy{...} / MOCK.Friend{...}. Fields: name, realm,
-- class, race, level, guild, pvp, friend, isPlayer, distance, plate.
function UnitIsPlayer(unit)
    if unit == "player" then return true end
    return unitField(unit, "isPlayer") or false
end
function UnitName(unit)
    local u = MOCK.units[unit]
    if not u then return nil end
    return unitField(unit, "name"), unitField(unit, "realm")
end
function UnitClass(unit)
    local u = MOCK.units[unit]
    if unit == "player" or not u or not u.class then return MOCK.class, MOCK.class end
    if MOCK.secretMode and u.secret and u.secret.class then return MOCK.Secret("x"), MOCK.Secret("x") end
    return u.class:sub(1, 1) .. u.class:sub(2):lower(), u.class
end
function UnitRace(unit)
    if unit == "player" then return "Human", "Human" end
    local race = unitField(unit, "race")
    return race, race
end
function GetGuildInfo(unit) return unitField(unit, "guild") end
MOCK.playerPvP = false
function UnitIsPVP(unit)
    if unit == "player" then return MOCK.playerPvP end
    return unitField(unit, "pvp") or false
end
function UnitIsPVPFreeForAll() return false end
function UnitIsFriend(_, unit) return unitField(unit, "friend") or false end
function UnitPlayerControlled(unit) return unitField(unit, "playerControlled") or false end
function UnitFactionGroup(unit) return unitField(unit, "faction") end
function UnitHealth(unit) local v = unitField(unit, "health"); if v == nil then return 100 end return v end
function UnitHealthMax(unit) local v = unitField(unit, "healthMax"); if v == nil then return 100 end return v end
function UnitPower(unit) return unitField(unit, "power") or 0 end
function UnitPowerMax(unit) return unitField(unit, "powerMax") or 0 end
function UnitPowerType(unit)
    local u = MOCK.units[unit]
    local t = u and u.powerType or 0
    return t, ({ [0] = "MANA", [1] = "RAGE", [3] = "ENERGY" })[t]
end
function UnitCastingInfo(unit) return unitField(unit, "casting") end
function UnitChannelInfo(unit) return nil end
function UnitPVPRank(unit) return unitField(unit, "rank") or 0 end
function GetPVPRankInfo(rank)
    if rank >= 5 then return "Rank " .. (rank - 4), rank - 4 end
    return nil, 0
end
MOCK.pvpTimer = nil   -- ms remaining, or nil
function IsPVPTimerRunning() return MOCK.pvpTimer ~= nil end
function GetPVPTimer() return MOCK.pvpTimer or 301000 end
MOCK.zone, MOCK.zonePvP = "Elwynn Forest", "friendly"
function GetZoneText() return MOCK.zone end
function GetZonePVPInfo() return MOCK.zonePvP, MOCK.zonePvPFFA or false, nil end
MOCK.inGroup, MOCK.inGuild = false, false
function IsInGroup() return MOCK.inGroup end
function IsInRaid() return MOCK.inRaid == true end
function IsInGuild() return MOCK.inGuild end
-- Custom channels: joined at once unless MOCK.channelsFull or MOCK.channelsLocked[name]
-- (a password or a ban); MOCK.channels[name] = id.
MOCK.channels, MOCK.channelsLocked = {}, {}
function JoinTemporaryChannel(name)
    if MOCK.channelsFull or MOCK.channelsLocked[name] then return end
    local n = 4
    for _ in pairs(MOCK.channels) do n = n + 1 end
    MOCK.channels[name] = MOCK.channels[name] or n + 1
end
function GetChannelName(name) local id = MOCK.channels[name]; if id then return id, name end; return 0, nil end
function LeaveChannelByName(name) MOCK.channels[name] = nil end
-- TOC fields a scenario sets (MOCK.metadata = { Version = "1.2.3" }); none by default.
function GetAddOnMetadata(_, field) return MOCK.metadata and MOCK.metadata[field] or nil end
function GetNumGroupMembers() return MOCK.groupSize or (MOCK.inGroup and 2 or 0) end
-- Group rosters: MOCK.SetGroup({ units }, raid) puts Friend units at party1.. (or raid1..,
-- the player last), MOCK.SetGroup(nil) leaves. Unit fields also read here: connected,
-- afk, leader, assist, role, subgroup, raidRank, zone, ml.
function MOCK.SetGroup(members, raid)
    for token in pairs(MOCK.units) do
        if token:find("^party%d") or token:find("^raid%d") then MOCK.units[token] = nil end
    end
    if not members then
        MOCK.inGroup, MOCK.inRaid, MOCK.groupSize = false, false, nil
        return
    end
    MOCK.inGroup, MOCK.inRaid, MOCK.groupSize = true, raid and true or false, #members + 1
    for i, u in ipairs(members) do MOCK.units[(raid and "raid" or "party") .. i] = u end
    if raid then MOCK.units["raid" .. (#members + 1)] = { exists = true, isPlayer = true, name = "Me", isSelf = true } end
end
function UnitIsConnected(unit) local u = MOCK.units[unit]; if not u then return false end; return u.connected ~= false end
function UnitIsAFK(unit) local u = MOCK.units[unit]; return u and u.afk or false end
function UnitIsGroupLeader(unit) if unit == "player" then return MOCK.leader or false end; local u = MOCK.units[unit]; return u and u.leader or false end
function UnitIsGroupAssistant(unit) local u = MOCK.units[unit]; return u and u.assist or false end
function UnitGroupRolesAssigned(unit) local u = MOCK.units[unit]; return u and u.role or "NONE" end
function GetRaidRosterInfo(i)
    local u = MOCK.units["raid" .. i]
    if not u then return nil end
    return u.name, u.raidRank or 0, u.subgroup or 1, u.level, nil, u.class, u.zone, u.connected ~= false, u.dead or false, u.raidRole, u.ml or false
end
function GetInstanceInfo() return MOCK.instance and MOCK.instance[1] or MOCK.zone, MOCK.instance and MOCK.instance[2] or "none" end
MOCK.addonMessages = {}
C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return true end,
    IsAddonMessagePrefixRegistered = function() return true end,
    SendAddonMessage = function(prefix, text, channel, target)
        MOCK.addonMessages[#MOCK.addonMessages + 1] = { prefix, text, channel, target }
        return true
    end,
}
-- Nameplates know their unit token (as the real ones do), and "target" /
-- "mouseover" resolve to the plate of the nameplate unit with the same GUID.
C_NamePlate.GetNamePlateForUnit = function(unit)
    local u = MOCK.units[unit]
    if not u or not u.exists then return nil end
    local token = unit
    if not unit:find("^nameplate") then
        token = nil
        for t, other in pairs(MOCK.units) do
            if t:find("^nameplate") and other.exists and other.guid == u.guid then token = t end
        end
        if not token then
            if not u.plate then return nil end
            token = unit
        end
    end
    if not MOCK.units[token].plate then return nil end
    MOCK.plates[token] = MOCK.plates[token] or NewWidget("Frame", nil, WorldFrame)
    local plate = MOCK.plates[token]
    plate._isPlate = true
    plate.namePlateUnitToken = token
    plate.UnitFrame = rawget(plate, "UnitFrame") or NewWidget("Button", nil, plate)
    return plate
end

function MOCK.Enemy(fields)
    local u = { exists = true, isPlayer = true, guid = "Player-4372-0ABCDEF0", name = "Shadowfang", class = "ROGUE",
        race = "Orc", level = 24, canAttack = true, enemy = true, pvp = true, distance = 22, plate = true, faction = "Horde" }
    for k, v in pairs(fields or {}) do u[k] = v end
    return u
end

function MOCK.Friend(fields)
    local u = { exists = true, isPlayer = true, guid = "Player-4372-0F00F00F", name = "Buddy", class = "PRIEST",
        race = "Human", level = 24, canAttack = false, enemy = false, friend = true, pvp = false, distance = 10,
        plate = true, faction = "Alliance" }
    for k, v in pairs(fields or {}) do u[k] = v end
    return u
end

---------------------------------------------------------------------------
-- Fishing: loot window, lure (temporary weapon enchant), equipped item IDs,
-- free bag slots.
---------------------------------------------------------------------------
-- MOCK.loot = { fishing = true, { id, name, count }, ... } while the window is open.
MOCK.loot = nil
function IsFishingLoot() return MOCK.loot ~= nil and MOCK.loot.fishing == true end
function GetNumLootItems() return MOCK.loot and #MOCK.loot or 0 end
function GetLootSlotLink(slot)
    local l = MOCK.loot and MOCK.loot[slot]
    return l and MOCK.ItemLink(l[1], l[2]) or nil
end
function GetLootSlotInfo(slot)
    local l = MOCK.loot and MOCK.loot[slot]
    if not l then return nil end
    return 133900 + l[1] % 100, l[2], l[3] or 1, nil, 1, false
end
MOCK.lureMs = nil     -- ms left on the main-hand temporary enchant, nil = none
MOCK.lureEnchant = 263
function GetWeaponEnchantInfo()
    if MOCK.lureMs then return true, MOCK.lureMs, 0, MOCK.lureEnchant, false, 0, 0, 0 end
    return false, 0, 0, 0, false, 0, 0, 0
end
MOCK.equippedIDs = {}
function GetInventoryItemID(unit, slot) if unit == "player" then return MOCK.equippedIDs[slot] end end
-- Cursor equips: PickupContainerItem puts a bag item on the cursor (refused
-- while MOCK.bagLocked["bag:slot"]), EquipCursorItem(slot) equips it.
MOCK.bagLocked, MOCK.cursor = {}, nil
C_Container.GetContainerItemInfo = function(bag, slot)
    if not (MOCK.bags[bag] and MOCK.bags[bag][slot]) then return nil end
    return { stackCount = MOCK.bagCounts[bag .. ":" .. slot] or 1, isLocked = MOCK.bagLocked[bag .. ":" .. slot] == true }
end
C_Container.PickupContainerItem = function(bag, slot)
    if MOCK.cursor or MOCK.bagLocked[bag .. ":" .. slot] then return end
    local link = MOCK.bags[bag] and MOCK.bags[bag][slot]
    if link then MOCK.cursor = { bag = bag, slot = slot, link = link } end
end
function CursorHasItem() return MOCK.cursor ~= nil end
function ClearCursor() MOCK.cursor = nil end
function EquipCursorItem(slot)
    local c = MOCK.cursor
    if not c then return end
    MOCK.cursor = nil
    MOCK.bags[c.bag][c.slot] = nil
    MOCK.equippedIDs[slot] = tonumber(c.link:match("item:(%d+)"))
    MOCK.equipCalls = (MOCK.equipCalls or 0) + 1
end
MOCK.freeSlots = 16
C_Container.GetContainerNumFreeSlots = function(bag) return bag == 0 and MOCK.freeSlots or 0, 0 end

---------------------------------------------------------------------------
-- Guild: your guild, the roster, permissions, invites, whispers, /who.
---------------------------------------------------------------------------
-- MOCK.guild = { name, rankName, rankIndex, ranks = { [0] = "Guild Master", ... },
--   can = { invite = true, promote = true }, roster = { { name, rank, level, classFile,
--   online, offline = { y, m, d, h }, zone, note }, ... } } or nil (no guild).
MOCK.guild = nil
MOCK.whispers, MOCK.guildInvites, MOCK.promoted, MOCK.whoQueries, MOCK.whoResults = {}, {}, {}, {}, {}
MOCK.demoted, MOCK.rankSets = {}, {}
MOCK.rosterRequests = 0
function IsInGuild() return MOCK.guild ~= nil or MOCK.inGuild end
local unitGuildInfo = GetGuildInfo
function GetGuildInfo(unit)
    if unit == "player" then
        local g = MOCK.guild
        if not g then return nil end
        return g.name, g.rankName, g.rankIndex
    end
    return unitGuildInfo(unit)
end
local function can(what) return MOCK.guild ~= nil and MOCK.guild.can ~= nil and MOCK.guild.can[what] == true end
function CanGuildInvite() return can("invite") end
function CanGuildPromote() return can("promote") end
function CanGuildDemote() return can("demote") end
function GetNumGuildMembers()
    local r = MOCK.guild and MOCK.guild.roster or {}
    local online = 0
    for _, m in ipairs(r) do if m.online then online = online + 1 end end
    return #r, online
end
function GetGuildRosterInfo(i)
    local m = MOCK.guild and MOCK.guild.roster[i]
    if not m then return nil end
    local rankName = MOCK.guild.ranks[m.rank]
    return m.name .. "-Mockrealm", rankName, m.rank, m.level, m.classFile, m.zone, m.note or "", "", m.online and 1 or nil, 0, m.classFile
end
function GetGuildRosterLastOnline(i)
    local m = MOCK.guild and MOCK.guild.roster[i]
    if not m or m.online or not m.offline then return nil end
    return unpack(m.offline)
end
function GuildControlGetNumRanks()
    local n = 0
    for _ in pairs(MOCK.guild and MOCK.guild.ranks or {}) do n = n + 1 end
    return n
end
function GuildControlGetRankName(i) return MOCK.guild and MOCK.guild.ranks[i - 1] end
-- Calls the game takes only during a key press or mouse click. A scenario's
-- own calls count as clicks (MOCK.hardware); events, OnUpdate and timers do
-- not. Outside one the game does nothing and fires ADDON_ACTION_BLOCKED (no
-- Lua error): kept in MOCK.blocked, and tests/run.py fails the scenario.
MOCK.hardware, MOCK.blocked = true, {}
-- Functions kept for the game's own UI: MOCK.forbidden[name] = true. A call
-- does nothing and fires ADDON_ACTION_FORBIDDEN inside the call ("UNKNOWN()",
-- as the game names it), with no Lua error.
MOCK.forbidden = {}
local function Protected(name, fn)
    return function(...)
        if MOCK.forbidden[name] then
            MOCK.FireEvent("ADDON_ACTION_FORBIDDEN", "TALOD", "UNKNOWN()")
            return
        end
        if not MOCK.hardware then
            MOCK.blocked[#MOCK.blocked + 1] = name
            return
        end
        return fn(...)
    end
end
C_GuildInfo = {
    GuildRoster = function() MOCK.rosterRequests = MOCK.rosterRequests + 1 end,
    Invite = Protected("C_GuildInfo.Invite", function(name) MOCK.guildInvites[#MOCK.guildInvites + 1] = name end),
}
GuildPromote = Protected("GuildPromote", function(name) MOCK.promoted[#MOCK.promoted + 1] = name end)
GuildDemote = Protected("GuildDemote", function(name) MOCK.demoted[#MOCK.demoted + 1] = name end)
-- The game's own rank pick: roster index, rank counted from 1 (1 = guild master).
SetGuildMemberRank = Protected("SetGuildMemberRank", function(index, rankOrder)
    MOCK.rankSets[#MOCK.rankSets + 1] = { index, rankOrder }
end)
-- Rank permission flags: MOCK.guild.flags = { [rank] = { [flag] = true } } (nil: the client does not tell).
C_GuildInfo.GuildControlGetRankFlags = function(rankOrder)
    local f = MOCK.guild and MOCK.guild.flags
    return f and f[rankOrder - 1] or nil
end
-- Party invites and Battle.net friend requests (the game's confirm window).
MOCK.partyInvites, MOCK.bnetRequests, MOCK.bnetConnected = {}, {}, true
C_PartyInfo = { InviteUnit = Protected("C_PartyInfo.InviteUnit", function(name) MOCK.partyInvites[#MOCK.partyInvites + 1] = name end) }
function BNFeaturesEnabledAndConnected() return MOCK.bnetConnected end
function BNCheckBattleTagInviteToGuildMember(name) MOCK.bnetRequests[#MOCK.bnetRequests + 1] = "member:" .. name end
function BNCheckBattleTagInviteToUnit(unit) MOCK.bnetRequests[#MOCK.bnetRequests + 1] = "unit:" .. unit end
-- The game's report window (you pick the reason and send it there).
MOCK.reports = {}
Enum = Enum or {}
Enum.ReportType = Enum.ReportType or { Chat = 0, InWorld = 1 }
ReportInfo = { CreateReportInfoFromType = function(_, kind) return { reportType = kind } end }
PlayerLocation = {
    CreateFromChatLineID = function(_, id) return { lineID = id } end,
    CreateFromGUID = function(_, guid) return { guid = guid } end,
}
ReportFrame = { InitiateReport = function(_, info, name, where)
    MOCK.reports[#MOCK.reports + 1] = { kind = info.reportType, name = name, lineID = where.lineID, guid = where.guid }
end }
function SendChatMessage(text, kind, lang, target)
    if kind == "WHISPER" then MOCK.whispers[#MOCK.whispers + 1] = { text = text, target = target } end
end
-- MOCK.whoResults = { { fullName, fullGuildName, level, filename, area, raceStr }, ... }
C_FriendList = {
    SendWho = function(text) MOCK.whoQueries[#MOCK.whoQueries + 1] = text end,
    GetNumWhoResults = function() return #MOCK.whoResults, #MOCK.whoResults end,
    GetWhoInfo = function(i) return MOCK.whoResults[i] end,
}
-- Sets up your guild with a roster and fires the roster update.
function MOCK.SetGuild(fields)
    MOCK.guild = { name = "Brave Souls", rankName = "Officer", rankIndex = 1,
        ranks = { [0] = "Guild Master", [1] = "Officer", [2] = "Veteran", [3] = "Member", [4] = "Initiate" },
        can = { invite = true, promote = true }, roster = {} }
    for k, v in pairs(fields or {}) do MOCK.guild[k] = v end
end

-- Guild event log: MOCK.guildEvents = { { type, player1, player2, rank, years, months, days, hours }, ... }
MOCK.guildEvents, MOCK.eventLogQueries = {}, 0
function QueryGuildEventLog() MOCK.eventLogQueries = MOCK.eventLogQueries + 1 end
function GetNumGuildEvents() return #MOCK.guildEvents end
function GetGuildEventInfo(i) local e = MOCK.guildEvents[i]; if e then return unpack(e, 1, 8) end end
-- Chat filters: MOCK.ChatHidden(event, text, name) is true when a filter hides the line.
MOCK.chatFilters = {}
function ChatFrame_AddMessageEventFilter(event, fn)
    MOCK.chatFilters[event] = MOCK.chatFilters[event] or {}
    table.insert(MOCK.chatFilters[event], fn)
end
function MOCK.ChatHidden(event, ...)
    for _, fn in ipairs(MOCK.chatFilters[event] or {}) do
        if fn(nil, event, ...) then return true end
    end
    return false
end
