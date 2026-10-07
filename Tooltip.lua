-- TALOD - every tooltip the addon writes goes through here, so they all
-- read the same: one set of line kinds (title, line, label → value, more,
-- note, hint) and one set of tones. Modules never call GameTooltip:AddLine /
-- AddDoubleLine / SetText / SetOwner themselves (tests/run.py checks it).
--
-- Three ways in:
--   Tip.Text(owner, { title, line, ... })      plain text tooltip
--   Tip.Item(owner, link, extra)               the game's item tooltip + lines
--   local t = Tip.Open(owner) ... t:Show()     anything else (builder below)
-- and, for the game's own item tooltips (bags, bank, chat links):
--   Tip.AddItemSection(key, order, fn(t, id))  lines under every item tooltip
--   Tip.AddItemExtra(key, { show, hide })      a frame shown with the tooltip

local ADDON_NAME, ns = ...

local Tip = {}
ns.Tooltip = Tip

---------------------------------------------------------------------------
-- Tones: what a color means, never a raw RGB in a module. Safety tones go
-- through ns.GetColor (colorblind aware), read at the time of the line.
---------------------------------------------------------------------------
local TONES = {
    title = { 1, 1, 1 }, text = { 1, 1, 1 }, value = { 1, 1, 1 },
    label = { 0.8, 0.8, 0.8 },
    muted = { 0.62, 0.62, 0.62 }, dim = { 0.45, 0.45, 0.45 },
    good = { 0.25, 1, 0.25 }, bad = { 1, 0.31, 0.31 }, gold = { 1, 0.82, 0 },
    hint = { 0.3, 1, 0.3 }, source = { 0.78, 0.71, 0.55 },
    accent = { 1, 0.50, 0.25 }, compare = { 0.35, 0.63, 1 },
}
local SAFETY = { safe = true, threshold = true, danger = true }
Tip.TONES = TONES

-- A tone name, an {r, g, b} list or an {r =, g =, b =} table → r, g, b.
local function RGB(tone, fallback)
    if type(tone) == "table" then
        if tone.r then return tone.r, tone.g, tone.b end
        return tone[1], tone[2], tone[3]
    end
    if SAFETY[tone] then
        local c = ns.GetColor(tone)
        return c[1], c[2], c[3]
    end
    local c = TONES[tone] or TONES[fallback] or TONES.text
    return c[1], c[2], c[3]
end
Tip.RGB = RGB

---------------------------------------------------------------------------
-- Builder: one per tooltip frame, reset by Open / On.
---------------------------------------------------------------------------
local Builder = {}
Builder.__index = Builder
local builders = setmetatable({}, { __mode = "k" })

local function Bind(tooltip, empty)
    local t = builders[tooltip]
    if not t then
        t = setmetatable({ tip = tooltip }, Builder)
        builders[tooltip] = t
    end
    t.n = empty and 0 or 1
    t.header = nil
    return t
end

-- A builder on GameTooltip, owned by `owner`, empty.
function Tip.Open(owner, anchor)
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    return Bind(GameTooltip, true)
end

-- A builder appending to a tooltip someone else filled (the game's item
-- tooltip). `header`: shown once, above the first line added.
function Tip.On(tooltip, header)
    local t = Bind(tooltip, false)
    t.header = header
    return t
end

function Builder:Header()
    if not self.header then return end
    local h = self.header
    self.header = nil
    self:Line(h, "accent", false)
end

-- First line of an empty tooltip is its title (the game's bigger font).
function Builder:Title(text, tone)
    if text == nil then return self end
    if self.n == 0 then
        local r, g, b = RGB(tone, "title")
        self.tip:SetText(text, r, g, b)
        self.n = 1
        return self
    end
    return self:Line(text, tone or "title", false)
end

-- A left-aligned line; wraps unless wrap == false.
function Builder:Line(text, tone, wrap)
    if text == nil then return self end
    if self.n == 0 then return self:Title(text, tone) end
    self:Header()
    local r, g, b = RGB(tone, "text")
    self.tip:AddLine(text, r, g, b, wrap ~= false)
    self.n = self.n + 1
    return self
end

-- label on the left, value on the right.
function Builder:Pair(label, value, tone, labelTone)
    if value == nil then return self end
    if self.n == 0 then self:Title(" ") end
    self:Header()
    local lr, lg, lb = RGB(labelTone, "label")
    local r, g, b = RGB(tone, "value")
    self.tip:AddDoubleLine(label or " ", tostring(value), lr, lg, lb, r, g, b)
    self.n = self.n + 1
    return self
end

-- A detail under the last Pair, on the right (muted by default).
function Builder:More(text, tone)
    if text == nil or text == "" then return self end
    return self:Pair(" ", text, tone or "muted")
end

function Builder:Note(text) return self:Line(text, "muted") end
function Builder:Hint(text) return self:Line(text, "hint") end
function Builder:Blank() return self:Line(" ", "text", false) end

-- Several lines at once: strings, or { text, tone } / { text, r, g, b }.
function Builder:Lines(list)
    for _, l in ipairs(list or {}) do
        if type(l) == "table" then
            if type(l[2]) == "number" then self:Line(l[1], { l[2], l[3] or 1, l[4] or 1 })
            else self:Line(l[1], l[2]) end
        else
            self:Line(l)
        end
    end
    return self
end

-- The game's own tooltip for an item link / a unit; true when it worked.
function Builder:Item(link)
    if type(link) ~= "string" then return false end
    local ok = pcall(self.tip.SetHyperlink, self.tip, link)
    if ok then self.n = math.max(self.n, 1) end
    return ok
end

function Builder:Spell(id)
    if type(id) ~= "number" or not self.tip.SetSpellByID then return false end
    local ok = pcall(self.tip.SetSpellByID, self.tip, id)
    if ok then self.n = math.max(self.n, 1) end
    return ok
end

function Builder:Unit(unit)
    if not unit then return false end
    local ok = pcall(self.tip.SetUnit, self.tip, unit)
    if ok then self.n = math.max(self.n, 1) end
    return ok
end

-- Where the tooltip sits, for owners that place it themselves (charts).
function Builder:Place(point, relative, relPoint, x, y)
    self.tip:ClearAllPoints()
    self.tip:SetPoint(point, relative, relPoint, x, y)
    return self
end

function Builder:Show() self.tip:Show() return self end

---------------------------------------------------------------------------
-- Shortcuts
---------------------------------------------------------------------------
-- lines[1] is the title, the rest wrap in white.
function Tip.Text(owner, lines, anchor)
    local t = Tip.Open(owner, anchor)
    for i, line in ipairs(lines or {}) do
        if i == 1 then t:Title(line) else t:Line(line) end
    end
    return t:Show()
end

-- The item's own tooltip, then `extra` lines ({ text, tone } or { text, r, g, b }).
function Tip.Item(owner, link, extra)
    if type(link) ~= "string" then return end
    local t = Tip.Open(owner)
    t:Item(link)
    t:Lines(extra)
    return t:Show()
end

function Tip.Hide() GameTooltip:Hide() end

-- Hides only when `owner` still has it (another frame may have taken it).
function Tip.HideFor(owner)
    if GameTooltip:IsOwned(owner) then GameTooltip:Hide() end
end

-- An OnLeave script that hides the tooltip.
function Tip.OnLeave() GameTooltip:Hide() end

---------------------------------------------------------------------------
-- The game's item tooltips: one hook, sections from the modules.
---------------------------------------------------------------------------
local sections, extras, extraList = {}, {}, {}

-- fn(t, id) adds lines with the builder; order sorts the sections.
function Tip.AddItemSection(key, order, fn)
    for i = #sections, 1, -1 do
        if sections[i].key == key then table.remove(sections, i) end
    end
    sections[#sections + 1] = { key = key, order = order or 50, fn = fn }
    table.sort(sections, function(a, b) return a.order < b.order end)
end

-- spec.show(tooltip, id) / spec.hide(): a frame that goes with GameTooltip
-- (the price graph). hide runs when the tooltip hides or is cleared.
function Tip.AddItemExtra(key, spec)
    if not extras[key] then extraList[#extraList + 1] = key end
    extras[key] = spec
end

local function HideExtras()
    for _, key in ipairs(extraList) do
        local h = extras[key].hide
        if h then ns.SafeCall(h) end
    end
end

local extraHooked
local function HookExtras(tooltip)
    if extraHooked or not tooltip.HookScript then return end
    extraHooked = true
    tooltip:HookScript("OnHide", HideExtras)
    pcall(tooltip.HookScript, tooltip, "OnTooltipCleared", HideExtras)
end

-- Every section's lines for item `id` on `tooltip`, under one header.
function Tip.ItemLines(tooltip, id)
    if tooltip == GameTooltip then
        HookExtras(tooltip)
        for _, key in ipairs(extraList) do
            local s = extras[key].show
            if s then ns.SafeCall(s, tooltip, id) end
        end
    end
    if type(id) ~= "number" then return end
    local t = Tip.On(tooltip, ns.TITLE)
    for _, s in ipairs(sections) do ns.SafeCall(s.fn, t, id) end
    if t.header == nil then tooltip:Show() end   -- resize when lines were added
end

local hooked = false
function Tip.HookItems()
    if hooked then return end
    hooked = true
    -- Newer engine: one hook for every item tooltip.
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
            local id = type(data) == "table" and ns.Secret.Value(data.id) or nil
            if tooltip == GameTooltip or tooltip == ItemRefTooltip then pcall(Tip.ItemLines, tooltip, id) end
        end)
        return
    end
    -- Classic Era: OnTooltipSetItem.
    for _, tip in ipairs({ GameTooltip, ItemRefTooltip }) do
        if tip and tip.HookScript then
            tip:HookScript("OnTooltipSetItem", function(self)
                local _, link = self:GetItem()
                local id = type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
                pcall(Tip.ItemLines, self, id)
            end)
        end
    end
end

ns.RegisterModule("Tooltip", {
    init = function() Tip.HookItems() end,
})
