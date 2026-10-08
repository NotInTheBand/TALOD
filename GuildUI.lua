-- TALOD - Guild window (/talod guild), in the shared Style. Tabs: Recruit
-- (players without a guild + the whisper message), Invited (who you invited
-- and what came of it), Replies (whispers with players you invited),
-- Roster (members, last online, inactivity), Recruiters (who invited whom,
-- who joined, who stayed), Promotions (rules per rank and who meets them),
-- Log (joins, leaves, rank changes), Activity (officers and the guild master:
-- who talks in guild chat). A small notice shows when a recruit
-- whispers you and the Replies tab is not open.
-- Recruit, Invited and Promotions show only to ranks the game lets invite /
-- promote.

local ADDON_NAME, ns = ...
local Guild = ns.Guild
local Style = ns.Style
local COLORS, HEX = Style.COLORS, Style.HEX

local UI = {}
ns.GuildUI = UI

local PAD = 12
local state = { view = "recruit", roster = "all" }
UI.state = state
local frame
local views = {}

local function db() return ns.DB() end

local function Hex(c)
    return string.format("|cff%02x%02x%02x", math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end

local function NameText(full, classFile)
    return Hex(ns.ClassColor(classFile)) .. Guild.Short(full) .. "|r"
end

local function Paint(b, on)
    b.borderColor = on and COLORS.accent or nil
    local col = on and COLORS.accent or COLORS.border
    b:SetBorderColor(col[1], col[2], col[3], 1)
    b.label:SetTextColor(on and 1 or 0.45, on and 1 or 0.45, on and 1 or 0.45)
end

-- A card's list area with a centered note for when the list does not apply.
local function Note(parent)
    local fs = Style.Text(parent, "GameFontDisable", "CENTER")
    fs:SetPoint("TOPLEFT", 20, -60)
    fs:SetPoint("RIGHT", -20, 0)
    return fs
end

local STATUS = {
    invited = { "invited", HEX.compare }, inviting = { "inviting", HEX.muted }, uninvited = { "not invited", HEX.gold },
    joined = { "joined", HEX.good }, declined = { "declined", HEX.bad },
    guilded = { "in a guild", HEX.muted }, pending = { "invited elsewhere", HEX.muted },
    notfound = { "offline", HEX.muted }, skipped = { "never invite", HEX.dim },
}
UI.STATUS = STATUS

-- A recruit's status as shown: an invite the game never confirmed is not
-- shown as "invited" (it may not have reached them).
local function StatusOf(r)
    if Guild.InviteCheck(r) == "unconfirmed" then return { "unconfirmed", HEX.gold } end
    if r.saidNo and r.status == "skipped" then return { "said no", HEX.bad } end
    return STATUS[r.status] or { tostring(r.status or "?"), HEX.muted }
end
UI.StatusOf = StatusOf

-- The tooltip / status line about the game's confirmation of the invite.
local function CheckText(r)
    local check = Guild.InviteCheck(r)
    if check == "confirmed" then return HEX.good .. "The game confirmed the invite (" .. date("%H:%M", r.ack) .. ").|r" end
    if check == "waiting" then return HEX.muted .. "Waiting for the game to confirm the invite.|r" end
    if check == "unconfirmed" then
        return HEX.gold .. "The game never said \"You have invited\" them: the invite may not have reached them.|r"
    end
end

local function ShortDate(t) return t and date("%b %d", t) or "?" end

---------------------------------------------------------------------------
-- Recruit
---------------------------------------------------------------------------
-- The /who button: the next levels, or the seconds to wait after a search.
function UI.WhoLabel(short)
    local wait = Guild.WhoWait()
    if wait > 0 then return HEX.muted .. "wait " .. math.ceil(wait) .. " s|r" end
    local _, _, from, to, zone, step, steps = Guild.NextWho()
    if short then return "/who" end
    return "/who " .. from .. "-" .. to .. (zone and "  here" or "") .. (step and ("  (" .. step .. "/" .. steps .. ")") or "")
end

-- The bar behind a recruit's name: gray = not invited yet, red = delayed
-- invite ready (the click sends it).
local TINT_NEW = { 0.55, 0.55, 0.55, 0.14 }
local TINT_READY = { 0.85, 0.18, 0.18, 0.38 }
UI.TINT_NEW, UI.TINT_READY = TINT_NEW, TINT_READY

-- Why an invite waits in the queue (Guild.InviteWhy), in words for tooltips.
local WHY = {
    delay = "Delayed invite: your message went out, and the invite waits 10 s so they can read it first.",
    inclick = "The invite did not go in the click that sent your message, so it waits here until the message is out.",
    failed = "The game did not accept the invite when you clicked, so it waits here for your next click or key press.",
    blocked = "The game blocked this invite from %s: it takes an invite only from a real click or key press, and "
        .. "it did not count that one. It waits here for your click, the Next invite button or your key binding.",
    nowhisper = "Your message could not go out (the game refused it), so the invite does not wait for it.",
    reload = "Left from before your last reload: your message went out, the invite never did.",
    message = "Waits for your message to go out first (the game sends about one whisper a second).",
}
function UI.WhyText(why, full)
    local text = WHY[why] or "Waits for your click."
    if why == "blocked" then text = text:format(Guild.SourceName(Guild.HandsFreeBlockedFor(full) or "mouse")) end
    return text
end

-- Where the recruit key binding is: its key, or how to bind it.
function UI.StepKeyText()
    local key = Guild.StepKey()
    if key then
        return "Your recruit key (" .. HEX.white .. key .. "|r) does one step too: the next invite, else /who, else a whisper. "
            .. "Right-click Next invite to change it."
    end
    return "No recruit key yet: right-click Next invite (or " .. ns.Cmd.Text("guild", "key") .. ") and press a key or mouse "
        .. "button. One press = the next invite, else /who, else a whisper."
end

-- What a left-click on a recruit row does, for its tooltip.
local function ClickText(ready, full)
    if ready then return HEX.white .. "Left-click|r: send the guild invite now (your message went out)." end
    if not db().guildWhisper or not Guild.CurrentMessage() then return HEX.white .. "Left-click|r: send the guild invite." end
    if db().guildDelayedInvite ~= false then
        return HEX.white .. "Left-click|r: whisper your message. They come back here in red once they had time to read it: "
            .. "click again to invite."
    end
    return HEX.white .. "Left-click|r: whisper your message and send the guild invite."
end

-- Rows for the players without a guild (Recruit tab and the mini window).
-- compact: class and zone left out (the mini window is narrow). cands: the
-- list from Guild.Candidates when the redraw already has it.
function UI.CandidateRows(compact, cands)
    local rows, now = {}, GetTime()
    cands = cands or Guild.Candidates()
    local queued, place = 0, 0
    for _, cand in ipairs(cands) do if cand.ready then queued = queued + 1 end end
    for _, cand in ipairs(cands) do
        if cand.ready then
            place = place + 1
            cand.place, cand.queued = place, queued
        end
        local cc = cand
        local src = cand.src == "who" and "/who" or cand.src
        local seen = cand.here and (HEX.good .. "here|r") or (HEX.muted .. ns.FormatAge(now - cand.last) .. (compact and "" or " ago") .. "|r")
        if cand.ready then seen = HEX.white .. "invite|r" end
        rows[#rows + 1] = {
            full = cand.full,
            label = cand.level and tostring(cand.level) or "?",
            text = NameText(cand.full, cand.classFile) .. (compact and "" or (HEX.muted .. "  "
                .. (cand.classFile and ns.ClassName(cand.classFile) or "") .. (cand.zone and ("  ·  " .. cand.zone) or "") .. "|r")),
            cols = compact and { seen } or { seen, HEX.muted .. src .. "|r" },
            tint = cand.ready and TINT_READY or TINT_NEW,
            accent = cand.here and COLORS.accent or nil,
            search = Guild.Short(cand.full) .. " " .. (cand.classFile and ns.ClassName(cand.classFile) or "") .. " " .. (cand.zone or ""),
            tooltip = function(owner)
                local t = ns.Tooltip.Open(owner)
                t:Title(Guild.Short(cc.full) .. (cc.level and ("  level " .. cc.level) or ""))
                t:Line((cc.race and (cc.race .. " ") or "") .. (cc.classFile and ns.ClassName(cc.classFile) or ""), "muted")
                t:Pair("Seen", (cc.src == "who" and "/who" or tostring(cc.src)) .. (cc.zone and (", " .. cc.zone) or ""))
                if cc.ready then
                    local why, since = Guild.InviteWhy(cc.full)
                    t:Blank()
                    t:Pair("Invite queue", cc.place and (cc.place .. " of " .. cc.queued .. " ready") or "ready")
                    if since and since > 0 and why ~= "reload" then t:Pair("Waiting", ns.FormatAge(since)) end
                    t:Line(UI.WhyText(why or cc.why, cc.full), why == "blocked" and "bad" or nil)
                    t:Note("Invites go one per click or key press, oldest first: this row, the Next invite button or your key binding.")
                elseif db().guildHandsFree then
                    t:Note("Hands Free: your next world click or move key whispers the next player on this list.")
                end
                t:Blank()
                t:Line(ClickText(cc.ready, cc.full))
                t:Line(HEX.white .. "Right-click|r: never offer this player again.")
                t:Show()
            end,
        }
    end
    return rows
end

-- The Delayed invite toggle (Recruit tab and the mini window).
local function ToggleDelayed()
    db().guildDelayedInvite = db().guildDelayedInvite == false
    ns.Refresh()
end
local DELAYED_TIP = "On: the first click whispers your message and takes the player off the list; "
    .. "10 s after it went out they come back in red, and the second click sends the guild invite "
    .. "(the game takes an invite only from a click). Off: message and invite in one click."

-- The Hands Free toggle (Recruit tab and the mini window).
local function ToggleHandsFree()
    Guild.SetHandsFree(not db().guildHandsFree)
end
local function HandsFreeTip()
    local lines = {
        "On: a left- or right-click on the open world (not on a window, a player or an NPC)"
            .. (db().guildHandsFreeKeys ~= false and ", or a press of a key bound to moving or jumping (WASD, Space)," or "")
            .. " counts as a click here: the next queued invite, else a /who once the /who button's wait is over, "
            .. "else a whisper to the next player. One action per click, never on its own. Paused in combat.",
    }
    if db().guildHandsFree then
        local why = Guild.HandsFreeBlocked()
        lines[#lines + 1] = why and (HEX.gold .. "Paused now: " .. why .. ".|r") or (HEX.good .. "On.|r")
        local left = {}
        for key in pairs(Guild.LeftAlone()) do
            local source, kind = key:match("^(%w+):(%w+)$")
            left[#left + 1] = (kind == "who" and "/who" or "invites") .. " from " .. Guild.SourceName(source)
        end
        table.sort(left)
        if #left > 0 then
            lines[#lines + 1] = HEX.gold .. "The game does not take " .. table.concat(left, ", ")
                .. " on this client, so those wait for a real click (until you reload).|r"
        end
        local presses = Guild.HandsFreePresses()
        local last = presses[#presses]
        if last then lines[#lines + 1] = "Last: " .. tostring(last.result) .. ", " .. ns.FormatAge(GetTime() - last.t) .. " ago." end
    end
    lines[#lines + 1] = UI.StepKeyText()
    lines[#lines + 1] = HEX.muted .. "What each click did: " .. ns.Cmd.Text("guild", "handsfree why") .. "|r"
    return lines
end
local HANDS_FREE_TIP = HandsFreeTip

-- The Next invite button: sends the oldest ready invite in the queue.
-- Left-click: the next invite. Right-click: set the recruit key.
local function NextInvite(_, button)
    if button == "RightButton" then Guild.CatchStepKey() return end
    if not Guild.InviteNext() then UI.Refresh() end
end
local function NextLabel(short, n)
    if n == 0 then return short and "Next" or "Next invite" end
    return (short and "Next " or "Next invite ") .. "(" .. n .. ")"
end
local function NextTip()
    local q = Guild.InviteQueue()
    local lines = {}
    local list = Guild.Candidates()
    local first
    for _, c in ipairs(list) do
        if c.ready then first = c break end
    end
    if q.ready > 0 and first then
        lines[#lines + 1] = "Sends the oldest ready invite: " .. HEX.white .. Guild.Short(first.full) .. "|r."
    else
        lines[#lines + 1] = "No invite is ready right now."
    end
    lines[#lines + 1] = string.format("Ready: %d%s.", q.ready,
        q.blocked > 0 and string.format(" (%d blocked from Hands Free, waiting for a real click)", q.blocked) or "")
    for i, s in ipairs(q.soon) do
        if i > 3 then lines[#lines + 1] = string.format("  +%d more soon", #q.soon - 3) break end
        lines[#lines + 1] = string.format("  %s: ready in %d s (delayed invite)", Guild.Short(s.full), math.ceil(s["in"]))
    end
    if q.message > 0 then lines[#lines + 1] = string.format("Waiting for their message to go out first: %d.", q.message) end
    lines[#lines + 1] = HEX.muted .. "One invite per click, oldest first. The game takes a guild invite only from a click or "
        .. "key press, so queued invites never go on their own.|r"
    lines[#lines + 1] = UI.StepKeyText()
    return lines
end
UI.NextTip = NextTip

local function OnCandidateClick(item, button)
    if not item.full then return end
    -- Invite and Skip redraw the guild windows themselves when something changed.
    if button == "RightButton" then Guild.Skip(item.full) else Guild.Invite(item.full) end
end

local function BuildRecruit(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Players without a guild")
    v.card:SetPoint("TOPLEFT")
    v.card:SetPoint("BOTTOMLEFT")
    v.card:SetWidth(540)
    v.card.sub:SetText("Left-click: whisper (then click the red row: invite).  Right-click: never offer again.")
    v.miniToggle = Style.Button(v.card.content, "", 120, function()
        db().guildMiniShown = not db().guildMiniShown
        ns.Refresh()
    end, "A small window with this list that stays on your screen (drag it anywhere). Same clicks as here.",
        { title = "Mini recruit window", height = 20 })

    local bar = CreateFrame("Frame", nil, v.card.content)
    bar:SetPoint("TOPLEFT", 6, -4)
    bar:SetPoint("TOPRIGHT", -6, -4)
    bar:SetHeight(22)
    v.who = Style.Button(bar, "", 160, function() Guild.Who() end, function()
        return "Runs one /who for your whole level range and lists everyone it finds without a guild. When the "
            .. "answer is full (about 50 players), the next clicks search smaller level ranges to reach the rest. "
            .. "One search per click, at most one every 5 seconds."
    end, { title = "/who search" })
    v.who:SetPoint("TOPLEFT")
    v.delayed = Style.Button(bar, "", 110, ToggleDelayed, DELAYED_TIP, { title = "Delayed invite" })
    v.delayed:SetPoint("LEFT", v.who, "RIGHT", 6, 0)
    v.zone = Style.Button(bar, "", 110, function()
        db().guildWhoZone = not db().guildWhoZone
        UI.Refresh()
    end, "Search only the zone you are in, or every zone.", { title = "/who where" })
    v.handsFree = Style.Button(bar, "", 110, ToggleHandsFree, HANDS_FREE_TIP, { title = "Hands Free" })
    v.handsFree:SetPoint("LEFT", v.delayed, "RIGHT", 6, 0)
    v.zone:SetPoint("LEFT", v.handsFree, "RIGHT", 6, 0)
    v.plates = Style.Button(v.card.content, "Friendly nameplates", 130, function()
        if ns.Census then ns.Census.ShowFriendlyPlates() end
        UI.Refresh()
    end, "Players of your faction are only seen through friendly nameplates (often off in cities), your target and your mouseover.", { height = 20 })
    v.next = Style.Button(v.card.content, "", 110, NextInvite, NextTip, { title = "Next invite", height = 20 })
    -- A second row under the toggles: in the card's header they covered its subtitle.
    v.next:SetPoint("TOPLEFT", v.who, "BOTTOMLEFT", 0, -4)
    v.miniToggle:SetPoint("LEFT", v.next, "RIGHT", 6, 0)
    v.plates:SetPoint("LEFT", v.miniToggle, "RIGHT", 6, 0)
    v.status = Style.Text(v.card.content, "GameFontDisableSmall")
    v.status:SetPoint("TOPLEFT", 8, -56)
    v.status:SetPoint("RIGHT", -8, 0)

    -- Filters: level range (shared with /who and the settings page) and classes.
    local filters = CreateFrame("Frame", nil, v.card.content)
    filters:SetPoint("TOPLEFT", 6, -74)
    filters:SetPoint("TOPRIGHT", -6, -74)
    filters:SetHeight(20)
    local function LevelButton(key, other, isMin)
        return Style.Button(filters, "", 56, function(_, button)
            local d = db()
            local step = (IsShiftKeyDown and IsShiftKeyDown()) and 10 or 1
            local cap = Guild.MaxLevel()
            local n = math.min(d[key] or (isMin and 1 or cap), cap) + (button == "RightButton" and -step or step)
            n = math.max(1, math.min(cap, n))
            -- Keep min <= max by moving the other end along.
            if isMin and n > (d[other] or 60) then d[other] = n end
            if not isMin and n < (d[other] or 1) then d[other] = n end
            d[key] = n
            ns.Refresh()
        end, "Click: +1, right-click: -1, with Shift: 10. Also sets the /who level range.",
            { title = isMin and "Lowest level" or "Highest level", height = 20 })
    end
    v.minLevel = LevelButton("guildRecruitMinLevel", "guildRecruitMaxLevel", true)
    v.minLevel:SetPoint("TOPLEFT")
    v.maxLevel = LevelButton("guildRecruitMaxLevel", "guildRecruitMinLevel", false)
    v.maxLevel:SetPoint("LEFT", v.minLevel, "RIGHT", 4, 0)
    local SHORT = { WARRIOR = "War", PALADIN = "Pal", SHAMAN = "Sham", HUNTER = "Hunt", ROGUE = "Rog",
        PRIEST = "Pri", MAGE = "Mage", WARLOCK = "Lock", DRUID = "Dru" }
    v.classChips = {}
    local prev = v.maxLevel
    for _, classFile in ipairs(Guild.Classes()) do
        local chip = Style.Button(filters, SHORT[classFile], 40, function(_, button)
            local hidden = db().guildRecruitHideClass
            if button == "RightButton" then
                -- Only this class; again on the same class: all of them.
                local solo = true
                for _, other in ipairs(Guild.Classes()) do
                    if (other == classFile) == (hidden[other] == true) then solo = false end
                end
                for _, other in ipairs(Guild.Classes()) do hidden[other] = (not solo and other ~= classFile) or nil end
            else
                hidden[classFile] = not hidden[classFile] or nil
            end
            ns.Refresh()
        end, "Click: show or hide. Right-click: only this class (again: all).", { title = ns.ClassName(classFile), height = 20 })
        chip:SetPoint("LEFT", prev, "RIGHT", prev == v.maxLevel and 10 or 3, 0)
        chip.classFile = classFile
        prev = chip
        v.classChips[#v.classChips + 1] = chip
    end

    local holder = CreateFrame("Frame", nil, v.card.content)
    holder:SetPoint("TOPLEFT", 0, -98)
    holder:SetPoint("BOTTOMRIGHT")
    v.list = Style.List(holder, { labelWidth = 26, colWidths = { 70, 64 }, search = true, hint = "Search names, classes, zones...",
        onClick = OnCandidateClick })
    v.note = Note(v.card.content)

    -- Whisper message editor.
    v.msg = Style.Card(v, "Whisper message")
    v.msg:SetPoint("TOPLEFT", v.card, "TOPRIGHT", 10, 0)
    v.msg:SetPoint("RIGHT")
    local c = v.msg.content
    v.toggle = Style.Button(c, "", 130, function()
        db().guildWhisper = not db().guildWhisper
        UI.Refresh()
    end, "Send this whisper right before the guild invite, or invite without a whisper.", { title = "Whisper first" })
    v.toggle:SetPoint("TOPLEFT", 6, -4)

    local function Select(i)
        local list = Guild.Messages()
        if #list == 0 then i = 1 elseif i > #list then i = 1 elseif i < 1 then i = #list end
        db().guildMessageIndex = i
        v.filled = nil
        UI.Refresh()
    end
    v.prev = Style.Button(c, "<", 24, function() Select(Guild.MessageIndex() - 1) end, "Previous message.")
    v.prev:SetPoint("TOPLEFT", 6, -32)
    v.next = Style.Button(c, ">", 24, function() Select(Guild.MessageIndex() + 1) end, "Next message.")
    v.next:SetPoint("LEFT", v.prev, "RIGHT", 4, 0)
    v.which = Style.Text(c, "GameFontHighlightSmall")
    v.which:SetPoint("LEFT", v.next, "RIGHT", 8, 0)
    v.new = Style.Button(c, "New", 50, function()
        local list = Guild.Messages()
        list[#list + 1] = "Hi {name}! "
        Select(#list)
    end, "Add a message. The one shown is the one sent.")
    v.del = Style.Button(c, "Delete", 60, function()
        local list = Guild.Messages()
        if #list == 0 then return end
        table.remove(list, Guild.MessageIndex())
        Select(Guild.MessageIndex())
    end, "Delete the message shown.")
    v.del:SetPoint("TOPRIGHT", -6, -32)
    v.new:SetPoint("RIGHT", v.del, "LEFT", -4, 0)

    local area = CreateFrame("Frame", nil, c)
    area:SetPoint("TOPLEFT", 6, -62)
    area:SetPoint("RIGHT", -6, 0)
    area:SetHeight(96)
    local bg = Style.Texture(area, "BACKGROUND", COLORS.button)
    bg:SetAllPoints()
    Style.Border(area, COLORS.border)
    local box = CreateFrame("EditBox", nil, area)
    box:SetMultiLine(true)
    box:SetMaxLetters(255)
    box:SetAutoFocus(false)
    box:SetFontObject("GameFontHighlightSmall")
    box:SetPoint("TOPLEFT", 6, -6)
    box:SetPoint("BOTTOMRIGHT", -6, 6)
    box:SetWidth(300)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        local list = Guild.Messages()
        local i = Guild.MessageIndex()
        if #list == 0 then list[1] = "" i = 1 db().guildMessageIndex = 1 end
        list[i] = (self:GetText() or ""):gsub("[\r\n]+", " ")
        v:Preview()
    end)
    area:EnableMouse(true)
    area:SetScript("OnMouseDown", function() box:SetFocus() end)
    v.box = box
    v.count = Style.Text(c, "GameFontDisableSmall", "RIGHT")
    v.count:SetPoint("TOPRIGHT", area, "BOTTOMRIGHT", 0, -4)
    v.preview = Style.Text(c, "GameFontHighlightSmall")
    v.preview:SetPoint("TOPLEFT", area, "BOTTOMLEFT", 0, -22)
    v.preview:SetPoint("RIGHT", -6, 0)
    v.help = Style.Text(c, "GameFontDisableSmall")
    v.help:SetPoint("BOTTOMLEFT", 6, 8)
    v.help:SetPoint("RIGHT", -6, 0)
    v.help:SetText("Fills in: {name} {first} {guild} {class} {level} {zone} {me}. At most 255 letters. "
        .. "Mass whispers get reported as spam: invite people you actually met.")

    -- Name alphabets: hide players whose names use another writing system.
    v.abc = Style.Card(v, "Name alphabets")
    v.abc:SetPoint("BOTTOMLEFT", v.card, "BOTTOMRIGHT", 10, 0)
    v.abc:SetPoint("BOTTOMRIGHT")
    v.abc:SetHeight(128)
    v.msg:SetPoint("BOTTOM", v.abc, "TOP", 0, 10)
    v.scriptChips = {}
    local COLS, CHIP_W = 4, 66
    for i, s in ipairs(Guild.SCRIPTS) do
        local chip = Style.Button(v.abc.content, s.short, CHIP_W, function()
            local d = db()
            if type(d.guildRecruitHideScript) ~= "table" then d.guildRecruitHideScript = {} end
            d.guildRecruitHideScript[s.id] = not d.guildRecruitHideScript[s.id] or nil
            ns.Refresh()
        end, "Click: show or hide players whose names are written in it.", { title = s.label, height = 20 })
        chip:SetPoint("TOPLEFT", 6 + ((i - 1) % COLS) * (CHIP_W + 4), -4 - math.floor((i - 1) / COLS) * 24)
        chip.script = s.id
        v.scriptChips[#v.scriptChips + 1] = chip
    end

    function v:Preview()
        local text = Guild.CurrentMessage()
        self.count:SetText(HEX.muted .. #(text or "") .. " / 255|r")
        local sample = { name = "Thrall", classFile = "SHAMAN", level = 24 }
        local filled = Guild.FormatMessage(text, sample)
        self.preview:SetText(text and (HEX.muted .. "Preview:|r  " .. filled)
            or (HEX.muted .. "No message: invites go out without a whisper. Click New to write one.|r"))
    end

    function v:Footer()
        return "Players of your faction with no guild, from nameplates, target, mouseover and /who. "
            .. "Invited, declined or offline players come back after " .. (db().guildReinviteDays or 7) .. " days."
    end

    function v:Refresh()
        local guild = Guild.Mine()
        local canInvite = guild and Guild.Can("invite")
        self.who:SetLabel(UI.WhoLabel(false))
        self.zone:SetLabel(db().guildWhoZone and "This zone only" or "All zones")
        local delayed = db().guildDelayedInvite ~= false
        self.delayed:SetLabel(delayed and "Delayed: on" or "Delayed: off")
        Paint(self.delayed, delayed)
        local handsFree = db().guildHandsFree == true
        self.handsFree:SetLabel(handsFree and "Hands Free: on" or "Hands Free: off")
        local ready = Guild.InviteQueue().ready
        self.next:SetLabel(NextLabel(false, ready))
        Paint(self.next, ready > 0)
        self.next:SetShown(canInvite and true or false)
        Paint(self.handsFree, handsFree)
        self.card.sub:SetText(delayed and "Left-click: whisper, then the red row again: invite.  Right-click: never offer again."
            or "Left-click: whisper + guild invite.  Right-click: never offer again.")
        local platesOn = not ns.Census or ns.Census.FriendlyPlatesOn()
        self.plates:SetShown(not platesOn)
        local status = Guild.WhoStatus() or ""
        local hold = ns.Outbox.Hold()
        if hold > 0 and db().guildWhisper then
            status = HEX.gold .. "Messages paused " .. math.ceil(hold) .. " s (the game is limiting them): invites go without the whisper.|r  " .. status
        end
        if not platesOn then
            status = HEX.gold .. "Friendly nameplates are off: only your target and mouseover are seen.|r  " .. status
        end
        if handsFree then
            local why = Guild.HandsFreeBlocked()
            -- The last click: what it did, or why it did nothing.
            local presses = Guild.HandsFreePresses()
            local last = presses[#presses]
            local did = last and ("last click " .. tostring(last.result) .. ", " .. ns.FormatAge(GetTime() - last.t) .. " ago")
                or "waiting for a click on the world"
            status = (why and (HEX.gold .. "Hands Free paused: " .. why .. ".|r  ") or (HEX.good .. "Hands Free:|r " .. did .. ".  ")) .. status
        end
        self.status:SetText(status)

        local lo, hi, cap = Guild.LevelRange()
        self.minLevel:SetLabel("Lv " .. lo .. "+")
        self.maxLevel:SetLabel("to " .. hi)
        local hidden = db().guildRecruitHideClass
        for _, chip in ipairs(self.classChips) do
            local on = not hidden[chip.classFile]
            Paint(chip, on)
            if on then
                local c = ns.ClassColor(chip.classFile)
                chip.label:SetTextColor(c[1], c[2], c[3])
            end
        end

        local cands = canInvite and Guild.Candidates() or {}
        state.cands = cands   -- the mini window draws the same list in this redraw
        local rows = UI.CandidateRows(false, cands)
        self.miniToggle:SetLabel(db().guildMiniShown and "Mini window: on" or "Mini window: off")
        Paint(self.miniToggle, db().guildMiniShown)
        self.list:SetShown(canInvite and true or false)
        self.note:SetShown(not canInvite)
        if not guild then
            self.note:SetText("You are not in a guild.")
        elseif not canInvite then
            self.note:SetText("Your guild rank cannot invite players.\nAn officer can give your rank the Invite permission.")
        end
        local scripts = db().guildRecruitHideScript
        local anyScript = false
        for _, chip in ipairs(self.scriptChips) do
            local off = type(scripts) == "table" and scripts[chip.script] == true
            Paint(chip, not off)
            if off then anyScript = true end
        end
        local nHidden = Guild.scriptHidden or 0
        self.abc.sub:SetText(not anyScript and "Every alphabet shown."
            or nHidden > 0 and (HEX.gold .. nHidden .. (nHidden == 1 and " player" or " players") .. " hidden by alphabet.|r")
            or "Click an alphabet to hide or show it.")
        local filtered = next(hidden) ~= nil or lo > 1 or hi < cap or (type(scripts) == "table" and next(scripts) ~= nil)
        if canInvite and #rows == 0 then
            rows[1] = { text = HEX.muted .. (filtered and "Nobody matches the level / class / name alphabet filter."
                or ("No one without a guild in sight yet. Players of your faction show up from their "
                .. "nameplates, your target and mouseover; /who finds more.")) .. "|r" }
        end
        self.list:SetItems(rows)
        self.card.title:SetText("Players without a guild  " .. HEX.muted .. #cands .. "|r")

        self.toggle:SetLabel(db().guildWhisper and "Whisper first: on" or "Whisper first: off")
        Paint(self.toggle, db().guildWhisper)
        local i, n = Guild.MessageIndex()
        self.which:SetText(n > 0 and ("Message " .. i .. " of " .. n) or HEX.muted .. "No message|r")
        if self.filled ~= i .. "/" .. n then
            self.filled = i .. "/" .. n
            self.box:SetText(Guild.CurrentMessage() or "")
        end
        self:Preview()
    end
    return v
end

---------------------------------------------------------------------------
-- Invited
---------------------------------------------------------------------------
local function InvitedRow(x)
    local r, full = x.r, x.full
    local st = StatusOf(r)
    local unconfirmed = Guild.InviteCheck(r) == "unconfirmed"
    local waiting = r.status == "inviting" or r.status == "invited"
    local unsent = r.unsent and waiting
    local queued = r.unsent and Guild.OpenerQueued(full)
    local inviteIn = r.status == "inviting" and Guild.InviteIn(full)
    return {
        label = r.t and date("%b %d %H:%M", r.t) or "?",
        text = NameText(full, r.classFile) .. HEX.muted .. "  " .. (r.level and (r.level .. " ") or "")
            .. (r.classFile and ns.ClassName(r.classFile) or "") .. (r.zone and ("  ·  " .. r.zone) or "") .. "|r"
            .. (r.replied and (HEX.good .. "  replied|r") or "")
            .. (queued and (HEX.muted .. "  message queued|r") or unsent and (HEX.gold .. "  no message|r") or "")
            .. (inviteIn and (inviteIn > 0 and string.format("%s  invite in %d s|r", HEX.muted, math.ceil(inviteIn))
                or (HEX.bad .. "  click to invite|r")) or ""),
        cols = { st[2] .. st[1] .. "|r", HEX.muted .. (r.by and Guild.Short(r.by) or "") .. "|r" },
        tooltip = function(owner)
            local lines = { Guild.Short(full), "Status: " .. st[1] .. (r.t and ("  (" .. date("%b %d %H:%M", r.t) .. ")") or "") }
            if r.invites then lines[#lines + 1] = "Invited " .. r.invites .. "x" .. (r.by and (", last by " .. r.by) or "") end
            if r.whisper then lines[#lines + 1] = HEX.muted .. "Whisper: " .. r.whisper .. "|r" end
            if queued then
                lines[#lines + 1] = HEX.muted .. "Your message waits its turn (the game sends about one whisper a second).|r"
                if unsent then lines[#lines + 1] = HEX.white .. "Click|r: send it now (one whisper)" end
            elseif r.unsent then
                lines[#lines + 1] = HEX.gold .. "Your message did not reach them (the game was limiting messages).|r"
                if unsent then lines[#lines + 1] = HEX.white .. "Click|r: send it now (one whisper)" end
            end
            local check = CheckText(r)
            if check then lines[#lines + 1] = check end
            if unconfirmed then lines[#lines + 1] = HEX.white .. "Click|r: invite again (invite only, no whisper)" end
            if r.status == "inviting" then
                lines[#lines + 1] = inviteIn == 0 and (HEX.white .. "Click|r: send the guild invite")
                    or (HEX.muted .. "Delayed invite: click them 10 s after your message went out to send the guild invite.|r")
            elseif r.status == "uninvited" then
                lines[#lines + 1] = HEX.gold .. "The guild invite was not sent (the game refused it, or you reloaded first).|r"
                lines[#lines + 1] = HEX.white .. "Click|r: invite now" .. (r.unsent and " (with your message)" or "")
            end
            if r.replied then lines[#lines + 1] = "They whispered back " .. date("%b %d %H:%M", r.replied) end
            lines[#lines + 1] = HEX.white .. "Right-click|r: forget"
            ns.Tooltip.Text(owner, lines)
        end,
    }
end

-- The Invited tab's rows (every player ever invited: thousands), also built
-- after login by the window's warm-up. list nil: just the data.
local function InvitedList(list)
    return ns.Data.List(list, {
        -- maxAge: an invite turns "unconfirmed" by time alone.
        name = "guild:invited", sources = { "guild" }, maxAge = 15, row = InvitedRow, empty = "Nobody invited yet.",
        build = function(add)
            local counts = {}
            for _, x in ipairs(Guild.Recruits()) do
                local r = x.r
                local unconfirmed = Guild.InviteCheck(r) == "unconfirmed"
                local key = unconfirmed and "unconfirmed" or r.status or "?"
                counts[key] = (counts[key] or 0) + 1
                add(x, { full = x.full, time = r.t, unsent = r.unsent and (r.status == "invited" or r.status == "inviting"),
                    uninvited = r.status == "uninvited", unconfirmed = unconfirmed,
                    ready = r.status == "inviting" and Guild.InviteReady(x.full) })
            end
            return { counts = counts }
        end,
    })
end

local function BuildInvited(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Invited")
    v.card:SetAllPoints()
    v.card.sub:SetText("Everyone you invited or skipped. Click a \"no message\" row: send your message; a \"not invited\" or \"unconfirmed\" row: invite. Right-click: forget them.")
    v.list = Style.List(v.card.content, { labelWidth = 86, colWidths = { 110, 90 }, search = true, time = true,
        hint = "Search names, classes, status...",
        onClick = function(item, button)
            if not item.full then return end
            if button == "RightButton" then
                Guild.Forget(item.full)
            elseif item.ready then
                Guild.Invite(item.full)
            elseif item.unconfirmed then
                Guild.Invite(item.full, nil, true)
            elseif item.uninvited then
                Guild.Invite(item.full, nil, Guild.Recruit(item.full).unsent == nil)
            elseif item.unsent then
                local _, why = Guild.SendOpener(item.full)
                if why == "held" then
                    ns.Print(string.format("the game is still limiting your messages: try again in %d s.", math.ceil(ns.Outbox.Hold())))
                end
            end
        end })
    v.note = Note(v.card.content)

    function v:Footer()
        return "Joined: they showed up in the roster or the game said so. Declined / offline / in a guild: from the game's messages. "
            .. "Unconfirmed: the game never said \"You have invited\" them. " .. ns.Cmd.Text("guild") .. " check sums up the last hour."
    end

    function v:Refresh()
        local canInvite = Guild.Mine() and Guild.Can("invite")
        self.list:SetShown(canInvite and true or false)
        self.note:SetShown(not canInvite)
        self.note:SetText(Guild.Mine() and "Your guild rank cannot invite players." or "You are not in a guild.")
        if not canInvite then return end
        local data = InvitedList(self.list)
        local counts = data.counts
        self.card.title:SetText("Invited  " .. HEX.muted .. (counts.invited or 0) .. " waiting  ·  |r" .. HEX.good .. (counts.joined or 0)
            .. " joined|r" .. HEX.muted .. "  ·  " .. (counts.declined or 0) .. " declined|r"
            .. ((counts.unconfirmed or 0) > 0 and (HEX.gold .. "  ·  " .. counts.unconfirmed .. " unconfirmed|r") or ""))
    end
    return v
end

---------------------------------------------------------------------------
-- Rank menu: right-click a member (Roster, Activity, Recruiters, Members,
-- Promotions). Every rank in order; a pick is one game command for that one
-- member (Guild.SetRank). Rights the new rank adds are a red warning; rights
-- the game does not tell are a gold "?", never left out.
---------------------------------------------------------------------------
local function RankItems(full)
    local m = Guild.Data().members[full]
    local items = {}
    for _, c in ipairs(Guild.RankChoices(full)) do
        local up = c.rank < m.rank
        local it = { label = c.name, selected = c.current, disabled = not c.current and not c.ok, why = c.why, notes = {} }
        if c.current then
            it.notes[1] = { "now", "muted" }
            it.tooltip = { c.name, HEX.muted .. Guild.Short(full) .. "'s rank now.|r" }
        else
            it.tooltip = { (up and "Promote to " or "Demote to ") .. c.name }
            if c.ok then
                it.notes[1] = { up and "promote" or "demote", "muted" }
                it.tooltip[2] = HEX.white .. "Click|r: " .. (up and "promote " or "demote ") .. Guild.Short(full) .. " (one game command)."
                it.pick = function()
                    Guild.SetRank(full, c.rank)
                    UI.Refresh()
                end
            end
            if c.gained == nil then
                if up and c.ok then it.notes[#it.notes + 1] = { "rights ?", "gold" } end
                it.tooltip[#it.tooltip + 1] = HEX.gold .. "The game does not tell this rank's rights here: check them before promoting.|r"
            else
                if #c.gained > 0 then
                    it.notes[#it.notes + 1] = { "! gains " .. table.concat(c.gained, ", "), "bad" }
                    it.tooltip[#it.tooltip + 1] = HEX.bad .. "Gains: " .. table.concat(c.gained, ", ") .. "|r"
                end
                if #c.lost > 0 then it.tooltip[#it.tooltip + 1] = HEX.muted .. "Loses: " .. table.concat(c.lost, ", ") .. "|r" end
            end
        end
        items[#items + 1] = it
    end
    return items
end

-- The rank menu of one member (a Style.ContextMenu spec).
function UI.RankMenu(full)
    local g = Guild.Mine() and Guild.Data()
    local m = g and full and g.members[full]
    if not m then return { title = Guild.Short(full), items = { { label = "Not in the guild roster.", disabled = true } } } end
    return { title = Guild.Short(full), sub = m.rankName or "?", items = RankItems(full) }
end

-- opts.menu of every list of members.
local function MemberMenu(item) return item.full and UI.RankMenu(item.full) or nil end

local RANK_HINT = "Right-click a member: change their rank."

---------------------------------------------------------------------------
-- Roster
---------------------------------------------------------------------------
local function LastOnlineText(days)
    if days == nil then return HEX.muted .. "?|r" end
    if days == 0 then return HEX.good .. "online|r" end
    local limit = db().guildInactiveDays or 30
    local text = days < 1 and "today" or (math.floor(days) .. " d")
    return (days >= limit and HEX.bad or HEX.white) .. text .. "|r"
end
UI.LastOnlineText = LastOnlineText

local function SinceText(m)
    return (m.before and "before " or "") .. ShortDate(m.since)
end

local function RosterRow(x)
    local m = x.m
    return {
        full = x.full,
        label = m.rankName or "?",
        text = NameText(x.full, m.classFile) .. HEX.muted .. "  " .. (m.level or "?") .. "  "
            .. (m.zone or "") .. ((m.note and m.note ~= "") and ("  ·  " .. m.note) or "") .. "|r",
        cols = { LastOnlineText(x.days), HEX.muted .. SinceText(m) .. "|r" },
        tooltip = function(owner)
            local lines = { Guild.Short(x.full) .. "  " .. HEX.muted .. (m.rankName or "") .. "|r",
                "Level " .. tostring(m.level or "?") .. " " .. (m.classFile and ns.ClassName(m.classFile) or ""),
                "Last online: " .. (x.days == 0 and "now" or (x.days and (math.floor(x.days) .. " days ago") or "unknown")),
                "In the guild since: " .. SinceText(m) }
            if m.rankSince then lines[#lines + 1] = "Rank since: " .. ShortDate(m.rankSince) end
            local by = Guild.InvitedBy(x.full)
            if by then lines[#lines + 1] = "Invited by: " .. Guild.Short(by) end
            if m.note and m.note ~= "" then lines[#lines + 1] = "Note: " .. m.note end
            if m.missing then lines[#lines + 1] = HEX.gold .. "Missing from the last roster read.|r" end
            ns.Tooltip.Text(owner, lines)
        end,
    }
end

local function BuildRoster(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Roster")
    v.card:SetAllPoints()
    local bar = CreateFrame("Frame", nil, v.card.content)
    bar:SetPoint("TOPLEFT", 6, -4)
    bar:SetPoint("TOPRIGHT", -6, -4)
    bar:SetHeight(22)
    v.filters = {}
    local x = 0
    for _, f in ipairs({ { "all", "All" }, { "online", "Online" }, { "inactive", "Inactive" } }) do
        local b = Style.Button(bar, f[2], 84, function() state.roster = f[1] UI.Refresh() end, nil, { height = 20 })
        b:SetPoint("TOPLEFT", x, 0)
        b.key = f[1]
        x = x + 88
        v.filters[#v.filters + 1] = b
    end
    v.refresh = Style.Button(bar, "Refresh roster", 110, function() Guild.RequestRoster() end,
        "Asks the game for the roster again (it answers at most every few seconds).", { height = 20 })
    v.refresh:SetPoint("TOPRIGHT")
    local holder = CreateFrame("Frame", nil, v.card.content)
    holder:SetPoint("TOPLEFT", 0, -30)
    holder:SetPoint("BOTTOMRIGHT")
    v.list = Style.List(holder, { labelWidth = 90, colWidths = { 70, 96 }, search = true, hint = "Search names, ranks, zones, notes...",
        menu = MemberMenu })
    v.note = Note(v.card.content)

    function v:Footer()
        return "Last online is what the game reports (a month counts as 30 days). Inactive: offline "
            .. (db().guildInactiveDays or 30) .. " days or more. \"before\": in the guild before " .. ns.NAME .. " first read the roster. " .. RANK_HINT
    end

    function v:Refresh()
        for _, b in ipairs(self.filters) do Paint(b, b.key == state.roster) end
        local g = Guild.Mine() and Guild.Data()
        self.note:SetShown(not g)
        self.list:SetShown(g and true or false)
        if not g then self.note:SetText("You are not in a guild.") return end
        -- Kept until the roster changes (a minute at most: "last online" ages).
        local data = ns.Data.List(self.list, {
            name = "guild:roster", sources = { "guild" }, key = { state.roster, db().guildInactiveDays }, maxAge = 60, row = RosterRow,
            build = function(add)
                local all = Guild.Roster("all")
                local d = { all = #all, online = 0, inactive = 0 }
                local limit = db().guildInactiveDays or 30
                for _, x in ipairs(all) do
                    if x.m.online then d.online = d.online + 1 end
                    if x.days and x.days >= limit then d.inactive = d.inactive + 1 end
                end
                for _, x in ipairs(Guild.Roster(state.roster)) do add(x) end
                return d
            end,
        })
        if #data.rows == 0 then
            self.list:SetItems({ { text = HEX.muted .. (data.all == 0 and "The roster has not been read yet: click Refresh roster." or "Nobody here.") .. "|r" } })
        end
        local all, online, inactive = data.all, data.online, data.inactive
        self.card.title:SetText("Roster  " .. HEX.muted .. all .. " members  ·  " .. online .. " online  ·  |r"
            .. (inactive > 0 and HEX.bad or HEX.muted) .. inactive .. " inactive|r")
        self.card.sub:SetText(g.lastRead and ("Read " .. ns.FormatAge(time() - g.lastRead) .. " ago.") or "Not read yet.")
    end
    return v
end

---------------------------------------------------------------------------
-- Activity (officers and the guild master): who talks in guild chat. Each
-- column is a signal from GuildActivity.lua; more come later.
---------------------------------------------------------------------------
local ACTIVITY_STATUS = {
    active = { "active", HEX.good }, quiet = { "quiet", HEX.gold }, unseen = { "not seen", HEX.muted },
}
UI.ACTIVITY_STATUS = ACTIVITY_STATUS

local function ActivityRow(x)
    local m, st = x.m, ACTIVITY_STATUS[x.chat.status]
    local cols, values = {}, {}
    for i, cell in ipairs(x.cells) do cols[i], values[i] = cell.text or "", cell.value end
    return {
        full = x.full,
        label = m.rankName or "?",
        text = NameText(x.full, m.classFile) .. HEX.muted .. "  " .. (m.level or "?") .. "|r  " .. st[2] .. st[1] .. "|r",
        cols = cols, sort = values,
        search = Guild.Short(x.full) .. " " .. (m.rankName or "") .. " " .. st[1],
        tooltip = function(owner)
            local window = ns.GuildActivity.Window()
            local lines = { Guild.Short(x.full) .. "  " .. HEX.muted .. (m.rankName or "") .. "|r", st[2] .. st[1] .. "|r" .. HEX.muted
                .. (x.chat.status == "active" and ("  (said something in the last " .. window .. " days)")
                    or x.chat.status == "quiet" and ("  (online with you in the last " .. window .. " days, said nothing)")
                    or "  (not seen in guild chat or online while you were)") .. "|r" }
            for _, cell in ipairs(x.cells) do
                if cell.tip then lines[#lines + 1] = cell.tip end
            end
            lines[#lines + 1] = "Last online: " .. (m.online and "now" or (Guild.DaysOffline(m) and (math.floor(Guild.DaysOffline(m)) .. " days ago") or "unknown"))
            ns.Tooltip.Text(owner, lines)
        end,
    }
end

local function BuildActivity(parent)
    local Act = ns.GuildActivity
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Activity")
    v.card:SetAllPoints()
    local bar = CreateFrame("Frame", nil, v.card.content)
    bar:SetPoint("TOPLEFT", 6, -4)
    bar:SetPoint("TOPRIGHT", -6, -4)
    bar:SetHeight(22)
    v.filters = {}
    local x = 0
    for _, f in ipairs({ { "all", "All" }, { "active", "Active" }, { "quiet", "Quiet" }, { "unseen", "Not seen" } }) do
        local b = Style.Button(bar, f[2], 84, function() state.activity = f[1] UI.Refresh() end, nil, { height = 20 })
        b:SetPoint("TOPLEFT", x, 0)
        b.key = f[1]
        x = x + 88
        v.filters[#v.filters + 1] = b
    end
    v.window = Style.Button(bar, "", 110, function(_, button)
        local list, now = Act.WINDOWS, Act.Window()
        local i = 1
        for k, n in ipairs(list) do if n == now then i = k end end
        i = i + (button == "RightButton" and -1 or 1)
        if i > #list then i = 1 elseif i < 1 then i = #list end
        db().guildChatDays = list[i]
        UI.Refresh()
    end, "How far back \"active\" looks. Click: longer, right-click: shorter.", { title = "Window", height = 20 })
    v.window:SetPoint("TOPLEFT", x + 10, 0)
    v.clear = Style.Button(bar, "Clear", 64, function()
        if IsShiftKeyDown and IsShiftKeyDown() then Act.Clear() UI.Refresh() end
    end, "Shift-click: forget every count kept for this guild and start over.", { title = "Clear", height = 20 })
    v.clear:SetPoint("TOPRIGHT")
    v.refresh = Style.Button(bar, "Refresh roster", 110, function() Guild.RequestRoster() end,
        "Asks the game for the roster again: who is online with you comes from it.", { height = 20 })
    v.refresh:SetPoint("RIGHT", v.clear, "LEFT", -4, 0)
    local holder = CreateFrame("Frame", nil, v.card.content)
    holder:SetPoint("TOPLEFT", 0, -30)
    holder:SetPoint("BOTTOMRIGHT")
    local widths, columns = {}, { name = "Member", label = "Rank" }
    for i, sig in ipairs(Act.signals) do widths[i], columns[i] = sig.width or 70, sig.label end
    v.list = Style.List(holder, { labelWidth = 90, colWidths = widths, columns = columns, search = true,
        hint = "Search names, ranks, active / quiet...", menu = MemberMenu })
    v.note = Note(v.card.content)

    function v:Footer()
        return "Only guild chat seen while you are online counts. "
            .. "Quiet: online with you, said nothing. Not seen: neither, so unknown. " .. RANK_HINT
    end

    function v:Refresh()
        for _, b in ipairs(self.filters) do Paint(b, b.key == (state.activity or "all")) end
        local guild = Guild.Mine()
        local officer = guild and Act.IAmOfficer()
        for _, b in ipairs(self.filters) do b:SetShown(officer and true or false) end
        self.window:SetShown(officer and true or false)
        self.clear:SetShown(officer and true or false)
        self.refresh:SetShown(officer and true or false)
        self.list:SetShown(officer and true or false)
        self.note:SetShown(not officer)
        if not officer then
            self.note:SetText(guild and "Only the guild master and officers see guild activity." or "You are not in a guild.")
            self.card.title:SetText("Activity")
            self.card.sub:SetText("")
            return
        end
        local window = Act.Window()
        self.window:SetLabel("Last " .. window .. " days")
        local data = ns.Data.List(self.list, {
            -- maxAge: "last said" and the day window age with time alone.
            name = "guild:activity", sources = { "guild", "guild.chat" }, key = { state.activity or "all", window },
            maxAge = 60, row = ActivityRow,
            build = function(add)
                local list, counts = Act.Members(state.activity, window)
                for _, item in ipairs(list) do add(item) end
                return counts
            end,
        })
        if #data.rows == 0 then
            self.list:SetItems({ { text = HEX.muted .. (data.all == 0 and "The roster has not been read yet: click Refresh roster." or "Nobody here.") .. "|r" } })
        end
        self.card.title:SetText("Activity  " .. HEX.muted .. data.all .. " members  ·  |r" .. HEX.good .. data.active .. " active|r"
            .. HEX.muted .. "  ·  |r" .. (data.quiet > 0 and HEX.gold or HEX.muted) .. data.quiet .. " quiet|r"
            .. HEX.muted .. "  ·  " .. data.unseen .. " not seen|r")
        local watched, since = Act.Watched(window)
        local g = Guild.Data()
        self.card.sub:SetText("Guild chat: you were online on " .. watched .. " of the last " .. window .. " days"
            .. (since and (", counting since " .. ShortDate(since)) or ", counting from now")
            .. (((g and g.chatHidden) or 0) > 0 and (HEX.gold .. "  ·  " .. g.chatHidden .. " lines the game hid the sender of|r") or "") .. ".")
    end
    return v
end

---------------------------------------------------------------------------
-- Replies: whispers with players you invited
---------------------------------------------------------------------------
local function ChatLine(full, r, c)
    local who = c.me and (HEX.compare .. "You|r") or NameText(full, r.classFile)
    return HEX.muted .. date("%b %d %H:%M", c.t) .. "|r  " .. who .. ": " .. c.text
end
UI.ChatLine = ChatLine

-- The Replies filters and each conversation's tag (Guild.ReplyGroup).
local REPLY_GROUPS = {
    { key = "all", label = "All" },
    { key = "joined", label = "Joined", hex = HEX.good, tip = "They joined the guild." },
    { key = "declined", label = "Declined", hex = HEX.bad, tip = "They declined the invite, or you marked that they said no." },
    { key = "invited", label = "Invited", hex = HEX.compare, tip = "Invited, no answer yet (or offline, in a guild, invited elsewhere)." },
    { key = "blocked", label = "Blocked", hex = HEX.gold, tip = "They have you on ignore: your whispers do not reach them." },
}
local REPLY_GROUP = {}
for _, g in ipairs(REPLY_GROUPS) do REPLY_GROUP[g.key] = g end
UI.REPLY_GROUPS = REPLY_GROUPS

-- x.hit: the line a message search found (shown instead of the last one).
local function ConversationRow(x)
    local r = x.r
    local line = x.hit or r.chat[#r.chat]
    local preview = (line.me and "You: " or "") .. line.text
    if #preview > 30 then preview = preview:sub(1, 28) .. ".." end
    local g = REPLY_GROUP[x.group]
    return {
        text = NameText(x.full, r.classFile) .. (r.level and (HEX.muted .. " " .. r.level .. "|r") or "")
            .. HEX.muted .. "  " .. preview .. "|r",
        cols = { g and (g.hex .. g.label .. "|r") or "", (r.unread or 0) > 0 and (HEX.accent .. r.unread .. "|r") or "" },
        accent = x.full == state.chat and COLORS.accent or nil,
    }
end

local function BuildReplies(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.left = Style.Card(v, "Conversations")
    v.left:SetPoint("TOPLEFT")
    v.left:SetPoint("BOTTOMLEFT")
    v.left:SetWidth(300)
    v.left.sub:SetText("Players you invited who whispered with you.")
    local lc = v.left.content
    local bar = CreateFrame("Frame", nil, lc)
    bar:SetPoint("TOPLEFT", 4, -3)
    bar:SetPoint("TOPRIGHT", -4, -3)
    bar:SetHeight(20)
    v.groups = {}
    local x = 0
    for _, g in ipairs(REPLY_GROUPS) do
        local b = Style.Button(bar, g.label, g.key == "all" and 36 or 56, function()
            state.replyGroup = g.key
            UI.Refresh()
        end, g.tip, { height = 20 })
        b:SetPoint("TOPLEFT", x, 0)
        b.key = g.key
        x = x + (g.key == "all" and 38 or 58)
        v.groups[#v.groups + 1] = b
    end
    -- The second search: words said in the conversations (the list's own
    -- box searches names).
    v.words = Style.SearchBox(lc, function(text)
        state.replyWords = text:lower():gsub("^%s+", ""):gsub("%s+$", "")
        if v:IsShown() then v:Refresh() end
    end, "Search messages...")
    v.words:SetPoint("TOPLEFT", 4, -27)
    v.words:SetPoint("TOPRIGHT", -4, -27)
    local holder = CreateFrame("Frame", nil, lc)
    holder:SetPoint("TOPLEFT", 0, -50)
    holder:SetPoint("BOTTOMRIGHT")
    v.list = Style.List(holder, { colWidths = { 56, 22 }, search = true, hint = "Search names...",
        onClick = function(item)
            if item.full then
                state.chat = item.full
                -- A click: may run one /who for this one player (they may have levelled).
                Guild.LookUp(item.full)
                UI.Refresh()
            end
        end })

    v.right = Style.Card(v, "")
    v.right:SetPoint("TOPLEFT", v.left, "TOPRIGHT", 10, 0)
    v.right:SetPoint("BOTTOMRIGHT")
    local c = v.right.content
    v.invite = Style.Button(c, "Invite again", 100, function()
        if state.chat then Guild.Invite(state.chat, nil, true) UI.Refresh() end
    end, "Sends the guild invite only, no whisper: you are already talking.")
    v.invite:SetPoint("TOPRIGHT", -6, -4)
    v.clear = Style.Button(c, "Delete", 64, function()
        if state.chat then
            Guild.ClearChat(state.chat)
            state.chat = nil
            UI.Refresh()
        end
    end, "Delete this conversation (the player stays in Invited).")
    v.clear:SetPoint("RIGHT", v.invite, "LEFT", -4, 0)
    v.no = Style.Button(c, "Said no", 72, function()
        if state.chat then
            local r = Guild.Recruit(state.chat)
            Guild.SaidNo(state.chat, not (r and r.saidNo))
            UI.Refresh()
        end
    end, function()
        local r = state.chat and Guild.Recruit(state.chat)
        return r and r.saidNo and "Takes back \"said no\": they can be invited again."
            or "They said no: no invite goes to them (a delayed invite waiting for your click is dropped) and they are never offered again. The conversation stays."
    end)
    v.no:SetPoint("RIGHT", v.clear, "LEFT", -4, 0)
    v.status = Style.Text(c, "GameFontHighlightSmall")
    v.status:SetPoint("TOPLEFT", 8, -9)
    v.status:SetPoint("RIGHT", v.no, "LEFT", -8, 0)

    -- Second row: one click = one game action for this one player.
    -- The form you type after /w: "First Surname" on your realm.
    v.copy = ns.Utils.CopyButton(c, "Copy username", 104, function()
        return state.chat and Guild.Target(state.chat)
    end, "name", "Shows the name ready to copy (Ctrl+C): the game cannot put text on the clipboard itself.")
    v.copy:SetPoint("TOPRIGHT", v.invite, "BOTTOMRIGHT", 0, -4)
    v.bnet = Style.Button(c, "Add Battle.net", 104, function()
        if state.chat then Guild.BattleNetInvite(state.chat) end
    end, function()
        local fn, why = state.chat and Guild.BattleNetRoute(state.chat)
        return fn and "Opens the game's Battle.net friend request for this player; you confirm it there."
            or (why or "Pick a conversation.")
    end, { title = "Battle.net friend request" })
    v.bnet:SetPoint("RIGHT", v.copy, "LEFT", -4, 0)
    v.party = Style.Button(c, "Invite to party", 104, function()
        if state.chat and not Guild.PartyInvite(state.chat) then
            ns.Print("the game did not accept the party invite for " .. Guild.Short(state.chat) .. ".")
        end
    end, "Sends one party invite to this player.")
    v.party:SetPoint("RIGHT", v.bnet, "LEFT", -4, 0)
    v.report = Style.Button(c, "Report", 64, function()
        if state.chat then Guild.Report(state.chat) end
    end, function()
        local kind, why = Guild.ReportRoute(state.chat)
        return kind == "chat" and "Opens the game's report window on their last whisper; you pick the reason and send it there. Works even when they ignore you."
            or kind == "player" and "Opens the game's report window for this player (their whispers from before your last login or reload can no longer be pointed at); you pick the reason there."
            or (why or "Pick a conversation.")
    end, { title = "Report player" })
    v.report:SetPoint("RIGHT", v.party, "LEFT", -4, 0)

    local msgs = CreateFrame("ScrollingMessageFrame", nil, c)
    msgs:SetPoint("TOPLEFT", 8, -60)
    msgs:SetPoint("BOTTOMRIGHT", -8, 40)
    msgs:SetFontObject("GameFontHighlightSmall")
    msgs:SetJustifyH("LEFT")
    msgs:SetFading(false)
    msgs:SetMaxLines(200)
    msgs:EnableMouseWheel(true)
    msgs:SetScript("OnMouseWheel", function(self, delta)
        if delta > 0 then self:ScrollUp() else self:ScrollDown() end
    end)
    v.msgs = msgs

    local box = CreateFrame("EditBox", nil, c)
    box:SetHeight(24)
    box:SetPoint("BOTTOMLEFT", 6, 8)
    box:SetPoint("BOTTOMRIGHT", -6, 8)
    box:SetAutoFocus(false)
    box:SetMaxLetters(255)
    box:SetFontObject("GameFontHighlightSmall")
    box:SetTextInsets(8, 8, 0, 0)
    local bg = Style.Texture(box, "BACKGROUND", COLORS.button)
    bg:SetAllPoints()
    Style.Border(box, COLORS.border)
    box.hint = Style.Text(box, "GameFontDisableSmall")
    box.hint:SetPoint("LEFT", 8, 0)
    box.hint:SetText("Type a reply, Enter sends it")
    box:SetScript("OnTextChanged", function(self) self.hint:SetShown((self:GetText() or "") == "") end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self)
        if state.chat then
            local ok, why = Guild.Reply(state.chat, self:GetText() or "")
            if ok or why == "repeat" then self:SetText("") end
            if why == "repeat" then ns.Print("already sent to " .. Guild.Short(state.chat) .. " a moment ago; not sent twice.") end
            -- Held: the text stays in the box for Enter once the pause is over.
            if why == "held" then
                ns.Print(string.format("the game is limiting your messages: not sent, try again in %d s.", math.ceil(ns.Outbox.Hold())))
            end
        end
        self:ClearFocus()
    end)
    v.box = box

    function v:Footer()
        return db().guildHideChat and "Openers and answers you have not written back to stay out of the chat window; once you write back, the conversation shows in chat too."
            or "These whispers also show in the chat window."
    end

    function v:Refresh()
        local all = Guild.Mine() and Guild.Conversations() or {}
        local group, words = state.replyGroup or "all", state.replyWords or ""
        for _, b in ipairs(self.groups) do Paint(b, b.key == group) end
        -- Filtered and tagged; kept until a conversation or a filter changes.
        local convos = ns.Data.Memo("guild:replies:filtered", ns.Data.Key("guild.replies") .. "|" .. tostring(all) .. "|" .. group .. "|" .. words, function()
            local out = {}
            for _, x in ipairs(all) do
                local g = Guild.ReplyGroup(x.r)
                local hit = words ~= "" and Guild.ChatFind(x.r, words) or nil
                if (group == "all" or g == group) and (words == "" or hit) then
                    out[#out + 1] = { full = x.full, r = x.r, group = g, hit = hit }
                end
            end
            return out
        end, 10)
        local valid = false
        for _, x in ipairs(convos) do if x.full == state.chat then valid = true end end
        if not valid then
            state.chat = nil
            for _, x in ipairs(convos) do
                if (x.r.unread or 0) > 0 then state.chat = x.full break end
            end
            state.chat = state.chat or (convos[1] and convos[1].full)
        end
        -- Hundreds of conversations after a long recruiting run: formatted
        -- when drawn, kept until a conversation or the selection changes.
        ns.Data.List(self.list, {
            name = "guild:replies", sources = { "guild.replies" }, key = { tostring(convos), state.chat },
            row = ConversationRow, empty = #all > 0 and "No conversation matches." or "No replies yet.",
            build = function(add)
                for _, x in ipairs(convos) do add(x, { full = x.full, search = Guild.Short(x.full) }) end
            end,
        })
        self.left.title:SetText("Conversations  " .. HEX.muted .. (#convos == #all and #all or (#convos .. " of " .. #all)) .. "|r")

        local full = state.chat
        local r = full and Guild.Recruit(full)
        for _, b in ipairs({ self.invite, self.clear, self.party, self.bnet, self.copy, self.report, self.no }) do b:SetShown(r ~= nil) end
        if r then
            -- They said no: no "Invite again" (Undo first); a member cannot say no any more.
            self.invite:SetShown(not r.saidNo)
            self.no:SetShown(r.saidNo or r.status ~= "joined")
            self.no:SetLabel(r.saidNo and "Undo no" or "Said no")
            self.bnet:SetAlpha(Guild.BattleNetRoute(full) and 1 or 0.5)
            self.report:SetAlpha(Guild.ReportRoute(full) and 1 or 0.5)
        end
        self.box:SetShown(r ~= nil)
        if not r then
            self.right.title:SetText("")
            self.status:SetText(HEX.muted .. "When a player you invited whispers you, the conversation shows here.|r")
            self.msgs:Clear()
            self.shown = nil
            return
        end
        Guild.MarkRead(full)
        local st = StatusOf(r)
        self.right.title:SetText(NameText(full, r.classFile) .. HEX.muted .. "  " .. (r.level and (r.level .. " ") or "")
            .. (r.classFile and ns.ClassName(r.classFile) or "") .. "|r")
        local check = Guild.InviteCheck(r)
        self.status:SetText(st[2] .. st[1] .. "|r" .. HEX.muted .. (r.invited and ("  ·  invited " .. date("%b %d %H:%M", r.invited)) or "") .. "|r"
            .. (check == "confirmed" and (HEX.good .. "  ·  confirmed|r") or check == "waiting" and (HEX.muted .. "  ·  not confirmed yet|r") or "")
            .. (r.ignoring and (HEX.bad .. "  ·  has you on ignore since " .. date("%b %d %H:%M", r.ignoring) .. "|r") or ""))
        local out = Guild.Outgoing(full)
        local key = full .. "/" .. #r.chat .. "/" .. (r.seq or 0) .. "/" .. (r.chat[#r.chat].t or 0) .. "/" .. words
        for _, o in ipairs(out) do key = key .. "/" .. o.state .. o.text end
        if self.shown ~= key then
            self.shown = key
            self.msgs:Clear()
            for _, line in ipairs(r.chat) do
                -- Lines with the searched words are marked.
                local hit = words ~= "" and type(line.text) == "string" and line.text:lower():find(words, 1, true)
                self.msgs:AddMessage((hit and (HEX.gold .. "> |r") or "") .. ChatLine(full, r, line))
            end
            -- Not in the conversation until the game echoes it back.
            for _, o in ipairs(out) do
                local note = o.state == "queued" and (HEX.muted .. "  (waiting for the game's message pace)|r")
                    or o.state == "lost" and (HEX.bad .. "  (the game dropped it: not delivered)|r")
                    or o.state == "ignoring" and (HEX.bad .. "  (not delivered: they have you on ignore)|r")
                    or o.state == "notfound" and (HEX.bad .. "  (not delivered: they are offline)|r")
                    or (HEX.muted .. "  (sending...)|r")
                self.msgs:AddMessage(HEX.muted .. "            You: " .. o.text .. "|r" .. note)
            end
        end
    end
    return v
end

---------------------------------------------------------------------------
-- Recruiters: who invited whom, who joined, who stayed
---------------------------------------------------------------------------
local function StayText(m)
    local days = math.floor(((m.left or time()) - m.joined) / 86400)
    if m.left then
        return HEX.muted .. "joined " .. ShortDate(m.joined) .. ", " .. (m.how == "removed" and "removed " or "left ")
            .. ShortDate(m.left) .. "|r " .. (days < Guild.QUICK_QUIT_DAYS and HEX.bad or HEX.white) .. "(" .. days .. " d)|r"
    end
    return HEX.muted .. "joined " .. ShortDate(m.joined) .. ",|r " .. HEX.good .. "here (" .. days .. " d)|r"
end
UI.StayText = StayText

local function BuildRecruiters(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Recruiters")
    v.card:SetAllPoints()
    v.list = Style.List(v.card.content, { colWidths = { 70, 70, 80 }, search = true, hint = "Search names...",
        columns = { name = "Recruiter", "Still here", "Kept", "Average stay" }, menu = MemberMenu })
    v.note = Note(v.card.content)

    function v:Footer()
        return "Kept: of those who joined, still in the guild. Average stay: days in the guild. Red: left within "
            .. Guild.QUICK_QUIT_DAYS .. " days. Gold: joined more than once. " .. RANK_HINT
    end

    function v:Refresh()
        local g = Guild.Mine() and Guild.Data()
        self.note:SetShown(not g)
        self.list:SetShown(g and true or false)
        if not g then self.note:SetText("You are not in a guild.") return end
        local rows = {}
        local recruiters = Guild.Recruiters()
        for _, st in ipairs(recruiters) do
            local member = g.members[st.by]
            local kept = st.joined > 0 and math.floor(st.here / st.joined * 100 + 0.5) or nil
            rows[#rows + 1] = {
                full = st.by,
                text = NameText(st.by, member and member.classFile) .. HEX.muted .. "  invited " .. st.invitedCount
                    .. "  ·  joined " .. st.joined .. "  ·  left " .. st.left .. "|r"
                    .. (st.quick > 0 and (HEX.bad .. "  " .. st.quick .. " within " .. Guild.QUICK_QUIT_DAYS .. " d|r") or "")
                    .. (st.rejoins > 0 and (HEX.gold .. "  " .. st.rejoins .. " rejoined|r") or "")
                    .. (member and "" or (HEX.dim .. "  (not in the guild)|r")),
                cols = { HEX.good .. st.here .. " here|r", kept and ((kept >= 50 and HEX.white or HEX.bad) .. kept .. "% kept|r") or (HEX.muted .. "-|r"),
                    st.days and (HEX.muted .. string.format("%.0f d avg", st.days) .. "|r") or (HEX.muted .. "-|r") },
                search = Guild.Short(st.by),
                tooltip = function(owner)
                    local lines = { Guild.Short(st.by) .. HEX.muted .. "  invited " .. st.invitedCount .. ", joined " .. st.joined .. "|r" }
                    table.sort(st.list, function(a, b) return a.joined > b.joined end)
                    for i, m in ipairs(st.list) do
                        if i > 20 then lines[#lines + 1] = HEX.muted .. "+" .. (#st.list - 20) .. " more|r" break end
                        lines[#lines + 1] = Guild.Short(m.who) .. "  " .. StayText(m) .. (m.nth > 1 and (HEX.gold .. "  join #" .. m.nth .. "|r") or "")
                    end
                    if #st.list == 0 then lines[#lines + 1] = HEX.muted .. "Nobody they invited has joined (yet).|r" end
                    ns.Tooltip.Text(owner, lines)
                end,
            }
        end
        if #rows == 0 then
            rows[1] = { text = HEX.muted .. "No invites seen yet. Open the guild window after members invite people: "
                .. "the game's guild log is read each time.|r" }
        end
        self.list:SetItems(rows)
        self.card.title:SetText("Recruiters  " .. HEX.muted .. #recruiters .. "|r")
        self.card.sub:SetText("From the game's guild log (every member, addon or not) and your own invites"
            .. (g.eventsSince and (", since " .. ShortDate(g.eventsSince)) or "") .. ". Hover a name for their recruits.")
    end
    return v
end

---------------------------------------------------------------------------
-- Promotions
---------------------------------------------------------------------------
local RULE_FIELDS = {
    { key = "level", step = 5, min = 1, max = 60, text = function(n) return "Level " .. n .. "+" end,
        tip = "Lowest level. Click: +5, right-click: -5, with Shift: 1." },
    { key = "days", step = 7, min = 0, max = 365, text = function(n) return n .. "+ days in guild" end,
        tip = "Days since they joined (counted from " .. ns.NAME .. "'s first roster read for older members). Click: +7, right-click: -7, with Shift: 1." },
    { key = "active", step = 1, min = 0, max = 90, text = function(n) return "online in " .. n .. " d" end,
        tip = "Online within this many days. Click: +1, right-click: -1, with Shift: 7." },
    { key = "recruits", step = 1, min = 0, max = 50,
        text = function(n) return n == 0 and "recruits: any" or (n .. "+ recruits kept") end,
        tip = "Members they invited who are still in the guild (Recruiters tab). 0: not used. Click: +1, right-click: -1, with Shift: 5." },
}

local function Mark(ok) return ok and (HEX.good .. "yes|r") or (HEX.bad .. "not yet|r") end

-- For a member without the promote permission: the next rank under the
-- rules officers shared, condition by condition.
function UI.ProgressText()
    local Sync = ns.GuildSync
    if not Sync then return nil end
    local shared = Sync.GuildRules()
    if not shared then
        return "Your guild rank cannot promote members.\nNo promotion rules from your officers yet: they arrive when an officer with " .. ns.NAME .. " is online."
    end
    local target, rule, why = Sync.MyProgress()
    if not target then return nil end
    if target < 0 then return "You lead the guild." end
    local head = "Next rank: " .. HEX.white .. Guild.RankName(target) .. "|r" .. HEX.muted .. "  (rules from "
        .. Guild.Short(shared.by) .. ", " .. ShortDate(shared.t) .. ")|r"
    if not rule or not rule.on then return head .. "\nYour officers have no rule for this rank." end
    local g = Guild.Data()
    local me = Guild.Me()
    local m = g.members[me]
    local daysIn = Guild.DaysIn(m)
    local off = Guild.DaysOffline(m)
    local lines = { head,
        "Level " .. rule.level .. "+: " .. Mark(type(m.level) == "number" and m.level >= rule.level),
        rule.days .. "+ days in the guild: " .. Mark(daysIn >= rule.days),
        "Online in the last " .. rule.active .. " days: " .. Mark(off ~= nil and off <= rule.active) }
    if (rule.recruits or 0) > 0 then
        lines[#lines + 1] = rule.recruits .. "+ recruits still in the guild: " .. Mark(Guild.RecruitsKept(me) >= rule.recruits)
    end
    lines[#lines + 1] = why == nil and (HEX.good .. "You meet every rule: ask an officer.|r") or ""
    return table.concat(lines, "\n")
end

local function BuildPromotions(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.rules = Style.Card(v, "Rules")
    v.rules:SetPoint("TOPLEFT")
    v.rules:SetPoint("TOPRIGHT")
    v.rules:SetHeight(220)
    v.rules.sub:SetText("For each rank you can promote into: who from the rank below qualifies.")
    v.ruleRows = {}
    v.card = Style.Card(v, "Ready for promotion")
    v.card:SetPoint("TOPLEFT", v.rules, "BOTTOMLEFT", 0, -8)
    v.card:SetPoint("BOTTOMRIGHT")
    v.card.sub:SetText("Click: promote one rank. One click per member. Right-click: any rank.")
    v.list = Style.List(v.card.content, { labelWidth = 90, colWidths = { 80, 90 }, search = true,
        menu = MemberMenu,
        onClick = function(item)
            if item.full then Guild.Promote(item.full) UI.Refresh() end
        end })
    v.note = Note(v.card.content)
    v.rulesNote = Note(v.rules.content)
    v.rulesNote:SetPoint("TOPLEFT", 20, -20)

    local function RuleRow(i)
        local row = v.ruleRows[i]
        if row then return row end
        row = CreateFrame("Frame", nil, v.rules.content)
        row:SetHeight(24)
        row:SetPoint("TOPLEFT", 6, -4 - (i - 1) * 28)
        row:SetPoint("RIGHT", -6, 0)
        row.on = Style.Button(row, "", 50, function()
            local rule = Guild.Rule(row.target)
            rule.on = not rule.on
            if ns.GuildSync then ns.GuildSync.RulesChanged() end
            UI.Refresh()
        end, "Use this rule.", { title = "On / off", height = 22 })
        row.on:SetPoint("LEFT")
        row.label = Style.Text(row, "GameFontHighlightSmall")
        row.label:SetPoint("LEFT", row.on, "RIGHT", 10, 0)
        row.label:SetWidth(200)
        row.fields = {}
        local prev
        for f, def in ipairs(RULE_FIELDS) do
            local b = Style.Button(row, "", 120, function(_, button)
                local rule = Guild.Rule(row.target)
                local step = def.step
                if IsShiftKeyDown and IsShiftKeyDown() then step = (def.key == "active" and 7) or (def.key == "recruits" and 5) or 1 end
                local n = (rule[def.key] or def.min) + (button == "RightButton" and -step or step)
                rule[def.key] = math.max(def.min, math.min(def.max, n))
                if ns.GuildSync then ns.GuildSync.RulesChanged() end
                UI.Refresh()
            end, def.tip, { title = ({ level = "Level", days = "Days in guild", active = "Online", recruits = "Recruits kept" })[def.key], height = 22 })
            if prev then b:SetPoint("LEFT", prev, "RIGHT", 6, 0) else b:SetPoint("LEFT", row.label, "RIGHT", 10, 0) end
            b.def = def
            prev = b
            row.fields[f] = b
        end
        v.ruleRows[i] = row
        return row
    end

    function v:Footer()
        return "Only ranks below yours. Members whose join date or last online is unknown are not listed until it is known."
    end

    function v:Refresh()
        local g = Guild.Mine() and Guild.Data()
        local can = g and Guild.Can("promote")
        self.list:SetShown(can and true or false)
        self.note:SetShown(not can)
        self.rulesNote:SetShown(not can)
        self.note:SetText(g and (UI.ProgressText() or "Your guild rank cannot promote members.") or "You are not in a guild.")
        self.rulesNote:SetText("")
        local targets = can and Guild.PromotableRanks() or {}
        for i, row in ipairs(self.ruleRows) do row:SetShown(i <= #targets) end
        if can and #targets == 0 then
            self.rulesNote:SetShown(true)
            self.rulesNote:SetText("No rank below yours has a rank under it to promote from (or the roster is not read yet).")
        end
        for i, target in ipairs(targets) do
            local row = RuleRow(i)
            row:Show()
            row.target = target
            local rule = Guild.Rule(target)
            row.on:SetLabel(rule.on and "On" or "Off")
            Paint(row.on, rule.on)
            row.label:SetText(HEX.muted .. Guild.RankName(target + 1) .. " to |r" .. Guild.RankName(target))
            for _, b in ipairs(row.fields) do
                b:SetLabel(b.def.text(rule[b.def.key] or b.def.min))
                Paint(b, rule.on)
            end
        end
        if not can then return end
        local rows = {}
        local candidates = Guild.PromotionCandidates()
        for _, x in ipairs(candidates) do
            local m = x.m
            local daysIn, lower = Guild.DaysIn(m)
            rows[#rows + 1] = {
                full = x.full,
                label = Guild.RankName(x.target),
                text = NameText(x.full, m.classFile) .. HEX.muted .. "  " .. (m.level or "?") .. "  from " .. (m.rankName or "?") .. "|r",
                cols = { HEX.muted .. (lower and ">" or "") .. math.floor(daysIn) .. " d in|r", LastOnlineText(Guild.DaysOffline(m)) },
                tooltip = function(owner)
                    ns.Tooltip.Text(owner, { Guild.Short(x.full), "Promote from " .. (m.rankName or "?") .. " to " .. Guild.RankName(x.target),
                        HEX.white .. "Click|r: promote one rank (the game's own promote).",
                        HEX.white .. "Right-click|r: pick any rank." })
                end,
            }
        end
        if #rows == 0 then rows[1] = { text = HEX.muted .. "Nobody meets a rule that is on.|r" } end
        self.list:SetItems(rows)
        self.card.title:SetText("Ready for promotion  " .. HEX.muted .. #candidates .. "|r")
    end
    return v
end

---------------------------------------------------------------------------
-- Log
---------------------------------------------------------------------------
local KIND = {
    join = { "joined", HEX.good }, leave = { "left", HEX.bad }, kick = { "removed", HEX.bad },
    promote = { "promoted", HEX.compare }, demote = { "demoted", HEX.gold },
}

local function LogText(e)
    local who = Guild.Short(e.n)
    local by = e.by and (HEX.muted .. " by " .. Guild.Short(e.by) .. "|r") or ""
    if e.k == "join" then return who .. " joined" .. (e.to and (HEX.muted .. " as " .. e.to .. "|r") or "") end
    if e.k == "leave" then return who .. " left" .. (e.from and (HEX.muted .. " (" .. e.from .. ")|r") or "") end
    if e.k == "kick" then return who .. " was removed" .. by end
    if e.k == "promote" or e.k == "demote" then
        return who .. HEX.muted .. " from |r" .. tostring(e.from or "?") .. HEX.muted .. " to |r" .. tostring(e.to or "?") .. by
    end
    return who .. " " .. tostring(e.k)
end
UI.LogText = LogText

local function LogRow(e)
    local k = KIND[e.k] or { tostring(e.k), HEX.muted }
    return { label = date("%b %d %H:%M", e.t), text = LogText(e), cols = { k[2] .. k[1] .. "|r" } }
end

local function BuildLog(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Log")
    v.card:SetAllPoints()
    v.card.sub:SetText("Noticed between roster reads, so the time is when " .. ns.NAME .. " saw it.")
    v.list = Style.List(v.card.content, { labelWidth = 86, colWidths = { 80 }, search = true, time = true, hint = "Search names, ranks..." })
    v.note = Note(v.card.content)

    function v:Footer()
        return "\"by\" comes from the game's guild messages when they are readable. Changes while you were offline show at your next login."
    end

    function v:Refresh()
        local g = Guild.Mine() and Guild.Data()
        self.note:SetShown(not g)
        self.list:SetShown(g and true or false)
        if not g then self.note:SetText("You are not in a guild.") return end
        local data = ns.Data.List(self.list, {
            name = "guild:log", sources = { "guild" }, row = LogRow,
            empty = "Nothing yet. The first roster read is the starting point; changes after it show here.",
            build = function(add)
                local log = Guild.Log()
                for i = #log, 1, -1 do add(log[i], { time = log[i].t }) end
                return { count = #log }
            end,
        })
        self.card.title:SetText("Log  " .. HEX.muted .. data.count .. "|r")
    end
    return v
end

---------------------------------------------------------------------------
-- Members (officers): what members agreed to share
---------------------------------------------------------------------------
local function SkillsText(prof, max)
    if not prof or not prof.skills then return nil end
    local parts = {}
    for i, sk in ipairs(prof.skills) do
        if i > (max or 3) then break end
        parts[#parts + 1] = sk.name .. " " .. tostring(sk.rank or "?")
    end
    return #parts > 0 and table.concat(parts, ", ") or nil
end

local function RecruitingText(list)
    if not list then return nil end
    local joined = 0
    for _, x in ipairs(list) do if x.status == "joined" then joined = joined + 1 end end
    return #list .. " invited, " .. joined .. " joined"
end

local SEAL_TEXT = { ok = "unchanged since their last logout", edited = "their saved file was changed outside the game",
    new = "not sealed yet", unknown = "could not be checked" }

-- What the checks found in a member's shared data: nil when nothing.
local function TrustText(d, cats)
    local edited, bad = false, 0
    for _, key in ipairs(cats) do
        local seal = d.seal and d.seal[key]
        if seal and (seal.state == "edited" or seal.restarted) then edited = true end
        bad = bad + #(d.bad and d.bad[key] or {})
    end
    local parts = {}
    if edited then parts[#parts + 1] = HEX.bad .. "edited|r" end
    if bad > 0 then parts[#parts + 1] = HEX.bad .. bad .. " problem" .. (bad == 1 and "" or "s") .. "|r" end
    return #parts > 0 and table.concat(parts, "  ") or nil
end

local function BuildMembers(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "Shared by members")
    v.card:SetAllPoints()
    v.card.sub:SetText("What members agreed to share with officers. Ask: one request to everyone online with " .. ns.NAME .. ".")
    local bar = CreateFrame("Frame", nil, v.card.content)
    bar:SetPoint("TOPLEFT", 6, -4)
    bar:SetPoint("TOPRIGHT", -6, -4)
    bar:SetHeight(22)
    v.ask = Style.Button(bar, "Ask members", 120, function()
        if ns.GuildSync then ns.GuildSync.RequestMembers() end
        UI.Refresh()
    end, "Sends one request to the guild. Each member's addon answers with only what that member said Yes to.")
    v.ask:SetPoint("TOPLEFT")
    local holder = CreateFrame("Frame", nil, v.card.content)
    holder:SetPoint("TOPLEFT", 0, -30)
    holder:SetPoint("BOTTOMRIGHT")
    v.list = Style.List(holder, { colWidths = { 70, 120, 70 }, search = true, hint = "Search names, professions...",
        columns = { name = "Member", "Played (7 d)", "Recruiting (30 d)", "Answered" }, menu = MemberMenu })
    v.note = Note(v.card.content)

    function v:Footer()
        return "Played: hours in the last 7 days. Hover a member for everything. " .. RANK_HINT
    end

    function v:Refresh()
        local Sync = ns.GuildSync
        local officer = Guild.Mine() and Sync and Sync.IAmOfficer()
        self.list:SetShown(officer and true or false)
        self.ask:SetShown(officer and true or false)
        self.note:SetShown(not officer)
        self.note:SetText(Guild.Mine() and "Only officers see what members share." or "You are not in a guild.")
        if not officer then return end
        local rows = {}
        local g = Guild.Data()
        for _, x in ipairs(Sync.Members()) do
            local d = x.d
            local m = g.members[x.full]
            local cats = {}
            for key in pairs(d.cats or {}) do cats[#cats + 1] = key end
            table.sort(cats)
            local nothing = #cats == 0
            -- The roster's level is the server's; theirs only when the roster has none.
            local level = (m and m.level) or (d.prof and d.prof.level)
            local warn = TrustText(d, cats)
            rows[#rows + 1] = {
                full = x.full,
                text = NameText(x.full, m and m.classFile) .. HEX.muted .. "  " .. (level or "?")
                    .. (SkillsText(d.prof) and ("  ·  " .. SkillsText(d.prof)) or "")
                    .. (d.alts and #d.alts > 0 and ("  ·  " .. #d.alts .. " other characters") or "")
                    .. (nothing and "  ·  shares nothing" or "") .. "|r" .. (warn and ("  " .. warn) or ""),
                cols = { d.activity and d.activity.h7 and (string.format("%.1f h", d.activity.h7)) or (HEX.muted .. "-|r"),
                    RecruitingText(d.recruiting) or (HEX.muted .. "-|r"), HEX.muted .. ShortDate(d.t) .. "|r" },
                sort = { [3] = d.t },
                search = Guild.Short(x.full) .. " " .. (SkillsText(d.prof, 9) or ""),
                tooltip = function(owner)
                    local lines = { Guild.Short(x.full), "Shares: " .. (nothing and "nothing" or table.concat(cats, ", ")),
                        HEX.muted .. "Reported by their addon, not the server's figures.|r" }
                    for _, key in ipairs(cats) do
                        local seal = d.seal and d.seal[key]
                        if seal and seal.state ~= "ok" then
                            lines[#lines + 1] = (seal.state == "edited" and HEX.bad or HEX.gold) .. key .. ": " .. SEAL_TEXT[seal.state] .. "|r"
                        end
                        if seal and seal.restarted then lines[#lines + 1] = HEX.gold .. key .. ": their seal started over (its saved record was deleted)|r" end
                        for _, why in ipairs(d.bad and d.bad[key] or {}) do lines[#lines + 1] = HEX.bad .. key .. ": " .. why .. "|r" end
                    end
                    if d.prof then lines[#lines + 1] = "Level " .. tostring(d.prof.level or "?") .. ((SkillsText(d.prof, 9) and ("  ·  " .. SkillsText(d.prof, 9))) or "") end
                    if d.alts and #d.alts > 0 then
                        local names = {}
                        for _, a in ipairs(d.alts) do names[#names + 1] = Guild.Short(a) end
                        lines[#lines + 1] = "Other characters: " .. table.concat(names, ", ")
                    end
                    if d.activity then
                        lines[#lines + 1] = string.format("Played: %.1f h in 7 days, %.1f h in 30 days, on %d of 30 days",
                            d.activity.h7 or 0, d.activity.h30 or 0, d.activity.days or 0)
                    end
                    if d.recruiting then
                        lines[#lines + 1] = "Recruiting (30 days): " .. RecruitingText(d.recruiting)
                        for i, rec in ipairs(d.recruiting) do
                            if i > 12 then lines[#lines + 1] = HEX.muted .. "+" .. (#d.recruiting - 12) .. " more|r" break end
                            local st = STATUS[rec.status] or { tostring(rec.status), HEX.muted }
                            lines[#lines + 1] = HEX.muted .. "  " .. Guild.Short(rec.full) .. "  " .. ShortDate(rec.t) .. "|r  "
                                .. st[2] .. st[1] .. "|r" .. (rec.replied and (HEX.good .. "  replied|r") or "")
                                .. (rec.check == "seen" and (HEX.muted .. "  in the guild log|r") or rec.check == "missing" and (HEX.bad .. "  not in the guild log|r") or "")
                        end
                    end
                    ns.Tooltip.Text(owner, lines)
                end,
            }
        end
        if #rows == 0 then rows[1] = { text = HEX.muted .. "Nothing shared yet. Click Ask members while members with " .. ns.NAME .. " are online.|r" } end
        self.list:SetItems(rows)
        self.card.title:SetText("Shared by members  " .. HEX.muted .. #Sync.Members() .. "|r")
    end
    return v
end

---------------------------------------------------------------------------
-- Sharing: your Yes / No per category; officer ranks (guild master)
---------------------------------------------------------------------------
local function BuildSharing(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    v.card = Style.Card(v, "What you share with your officers")
    v.card:SetPoint("TOPLEFT")
    v.card:SetPoint("TOPRIGHT")
    v.card:SetHeight(58 + #(ns.GuildSync and ns.GuildSync.CATEGORIES or {}) * 46)
    v.card.sub:SetText("Nothing is sent until you say Yes. Saying No later tells the officers' addons to delete it.")
    v.rows = {}
    local Sync = ns.GuildSync
    for i, cat in ipairs(Sync and Sync.CATEGORIES or {}) do
        local row = CreateFrame("Frame", nil, v.card.content)
        row:SetHeight(44)
        row:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 46)
        row:SetPoint("RIGHT", -6, 0)
        row.yes = Style.Button(row, "Yes", 50, function() Sync.SetConsent(cat.key, true) UI.Refresh() end, nil, { height = 22 })
        row.yes:SetPoint("TOPLEFT")
        row.no = Style.Button(row, "No", 50, function() Sync.SetConsent(cat.key, false) UI.Refresh() end, nil, { height = 22 })
        row.no:SetPoint("LEFT", row.yes, "RIGHT", 4, 0)
        row.label = Style.Text(row, "GameFontNormal")
        row.label:SetPoint("TOPLEFT", 124, -3)
        row.label:SetPoint("RIGHT")
        row.label:SetText(cat.label)
        row.text = Style.Text(row, "GameFontHighlightSmall")
        row.text:SetPoint("TOPLEFT", row.label, "BOTTOMLEFT", 0, -3)
        row.text:SetPoint("RIGHT")
        row.key = cat.key
        row.desc = cat.text
        v.rows[i] = row
    end

    v.officers = Style.Card(v, "Officers")
    v.officers:SetPoint("TOPLEFT", v.card, "BOTTOMLEFT", 0, -8)
    v.officers:SetPoint("BOTTOMRIGHT")
    v.officerText = Style.Text(v.officers.content, "GameFontHighlightSmall")
    v.officerText:SetPoint("TOPLEFT", 8, -6)
    v.officerText:SetPoint("RIGHT", -8, 0)
    v.rankChips = {}
    v.auto = Style.Button(v.officers.content, "Use game permissions", 160, function()
        if Sync then Sync.SetOfficerRanks(nil) end
        UI.Refresh()
    end, "Officers are the ranks the game lets read officer chat, promote or remove members.", { height = 22 })
    v.auto:SetPoint("TOPLEFT", 8, -64)

    function v:Footer()
        return "Your answers are kept for this account. Officers only receive data from members whose own roster shows them at an officer rank."
    end

    function v:Refresh()
        local guild = Guild.Mine()
        for _, row in ipairs(self.rows) do
            local c = Sync.Consent(row.key)
            Paint(row.yes, c == true)
            Paint(row.no, c == false)
            row.text:SetText(row.desc .. (c == nil and (HEX.gold .. "  Not answered (nothing is sent).|r") or ""))
        end
        if not guild then
            self.officerText:SetText(HEX.muted .. "You are not in a guild.|r")
            self.auto:Hide()
            for _, chip in ipairs(self.rankChips) do chip:Hide() end
            return
        end
        local names = {}
        for rank = 0, math.max(0, Guild.NumRanks() - 1) do
            if Sync.RankIsOfficer(rank) then names[#names + 1] = Guild.RankName(rank) end
        end
        local source = Sync.OfficerSource()
        local g = Guild.Data()
        self.officerText:SetText("Officer ranks: " .. HEX.white .. table.concat(names, ", ") .. "|r" .. HEX.muted .. "  ("
            .. (source == "gm" and ("set by the guild master" .. (g.officerRanksT and (", " .. ShortDate(g.officerRanksT)) or ""))
                or (source == "permissions" and "from the game's rank permissions") or "the two highest ranks: the game's permissions could not be read")
            .. ")|r" .. (Sync.IAmGM() and ("\n" .. HEX.muted .. "You lead the guild: click ranks to choose the officer ranks yourself.|r") or ""))
        local gm = Sync.IAmGM()
        self.auto:SetShown(gm and source == "gm")
        local n = Guild.NumRanks()
        for rank = 1, math.max(0, n - 1) do
            local chip = self.rankChips[rank]
            if not chip then
                chip = Style.Button(self.officers.content, "", 104, function()
                    local set = {}
                    for r2 = 1, Guild.NumRanks() - 1 do if Sync.RankIsOfficer(r2) then set[r2] = true end end
                    set[rank] = not set[rank] or nil
                    Sync.SetOfficerRanks(set)
                    UI.Refresh()
                end, "Click: officer rank or not. Sent to every member with " .. ns.NAME .. ".", { height = 22 })
                chip:SetPoint("TOPLEFT", 8 + ((rank - 1) % 7) * 108, -36 - math.floor((rank - 1) / 7) * 26)
                self.rankChips[rank] = chip
            end
            chip:SetLabel(Guild.RankName(rank))
            Paint(chip, Sync.RankIsOfficer(rank))
            chip:SetShown(gm)
        end
        for rank = n, #self.rankChips do self.rankChips[rank]:Hide() end
        if gm then self.auto:SetPoint("TOPLEFT", 8, -36 - math.ceil((n - 1) / 7) * 26) end
    end
    return v
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local VIEWS = {
    { key = "recruit", label = "Recruit", build = BuildRecruit },
    { key = "invited", label = "Invited", build = BuildInvited },
    { key = "replies", label = "Replies", build = BuildReplies },
    { key = "roster", label = "Roster", build = BuildRoster },
    { key = "activity", label = "Activity", build = BuildActivity, officer = true },
    { key = "recruiters", label = "Recruiters", build = BuildRecruiters },
    { key = "promote", label = "Promotions", build = BuildPromotions },
    { key = "log", label = "Log", build = BuildLog },
    { key = "members", label = "Members", build = BuildMembers },
    { key = "sharing", label = "Sharing", build = BuildSharing },
}

local TAB_W = 84
local OFFICER_VIEW = {}
for _, def in ipairs(VIEWS) do OFFICER_VIEW[def.key] = def.officer end

-- Officer-only tabs are left out for everyone else; the rest close up.
local function LayoutTabs(officer)
    local x = 0
    for _, tab in ipairs(frame.tabs) do
        local shown = officer or not OFFICER_VIEW[tab.key]
        tab:SetShown(shown)
        if shown then
            tab:ClearAllPoints()
            tab:SetPoint("TOPLEFT", x, 0)
            x = x + TAB_W + 4
        end
    end
end

local function Build()
    frame = Style.Window(ns.FRAME .. "GuildWindow", "Guild", nil, nil, { nav = "guild", hidden = true })
    frame.who = Style.Text(frame, "GameFontHighlightSmall", "RIGHT")
    frame.who:SetPoint("TOPRIGHT", -40, -14)
    frame.who:SetWidth(460)

    local tabHolder = CreateFrame("Frame", nil, frame)
    tabHolder:SetPoint("TOPLEFT", PAD, -44)
    tabHolder:SetPoint("TOPRIGHT", -PAD, -44)
    tabHolder:SetHeight(26)
    frame.tabs = Style.Tabs(tabHolder, VIEWS, function(key) state.view = key UI.Refresh() end, TAB_W)
    local line = Style.HLine(frame)
    line:SetPoint("TOPLEFT", PAD, -70)
    line:SetPoint("TOPRIGHT", -PAD, -70)

    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", PAD, -80)
    body:SetPoint("BOTTOMRIGHT", -PAD, 34)
    for _, def in ipairs(VIEWS) do views[def.key] = def.build(body) end
    frame.footer = Style.Text(frame, "GameFontDisableSmall")
    frame.footer:SetPoint("BOTTOMLEFT", PAD + 2, 12)
    frame.footer:SetPoint("RIGHT", -PAD, 0)
    frame:HookScript("OnShow", function()
        Guild.RequestRoster()
        if ns.GuildSync then ns.GuildSync.OnWindowOpen() end
        UI.Refresh()
    end)
end

function UI.Refresh()
    if not frame or not frame:IsShown() then return end
    local guild, rankName = Guild.Mine()
    if guild then
        local can = {}
        if Guild.Can("invite") then can[#can + 1] = "invite" end
        if Guild.Can("promote") then can[#can + 1] = "promote" end
        frame.who:SetText(HEX.gold .. "<" .. guild .. ">|r  " .. tostring(rankName or "")
            .. HEX.muted .. (#can > 0 and ("  ·  can " .. table.concat(can, ", ")) or "") .. "|r")
    else
        frame.who:SetText(HEX.muted .. "not in a guild|r")
    end
    local officer = guild ~= nil and ns.GuildActivity ~= nil and ns.GuildActivity.IAmOfficer()
    LayoutTabs(officer)
    if OFFICER_VIEW[state.view] and not officer then state.view = "roster" end
    frame.tabs:Select(state.view)
    for key, v in pairs(views) do v:SetShown(key == state.view) end
    local v = views[state.view]
    state.cands = nil
    v:Refresh()
    frame.footer:SetText(v:Footer() or "")
    local unread = guild and Guild.Unread() or 0
    for _, tab in ipairs(frame.tabs) do
        if tab.key == "replies" then tab.text:SetText(unread > 0 and ("Replies " .. HEX.accent .. unread .. "|r") or "Replies") end
    end
    UI.UpdateNotice(unread)
    local cands = state.cands
    state.cands = nil
    UI.RefreshMini(cands)
end

---------------------------------------------------------------------------
-- Mini recruit window: the Recruit list in a small window that stays on
-- screen (off by default; Recruit tab button, settings, /talod guild mini)
---------------------------------------------------------------------------
local mini

local function PlaceMini()
    mini:ClearAllPoints()
    local p = db().guildMiniPos
    if type(p) == "table" and p[1] then
        mini:SetPoint(p[1], UIParent, p[2] or p[1], p[3] or 0, p[4] or 0)
    else
        mini:SetPoint("RIGHT", UIParent, "RIGHT", -260, 60)
    end
end

local function BuildMini()
    mini = CreateFrame("Frame", ns.FRAME .. "GuildMini", UIParent)
    mini:SetSize(340, 236)
    mini:SetFrameStrata("MEDIUM")
    mini:SetClampedToScreen(true)
    mini:SetMovable(true)
    mini:EnableMouse(true)
    mini:RegisterForDrag("LeftButton")
    mini:SetScript("OnDragStart", mini.StartMoving)
    mini:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, rel, x, y = self:GetPoint(1)
        db().guildMiniPos = { point, rel, x, y }
    end)
    Style.Surface(mini, "hud")
    mini.title = Style.Text(mini, "GameFontNormalSmall")
    mini.title:SetPoint("TOPLEFT", 8, -8)
    mini.title:SetPoint("RIGHT", -264, 0)
    mini.close = CreateFrame("Button", nil, mini)
    mini.close:SetSize(18, 18)
    mini.close:SetPoint("TOPRIGHT", -4, -4)
    mini.close.x = Style.Text(mini.close, "GameFontNormal", "CENTER")
    mini.close.x:SetPoint("CENTER", 0, 1)
    mini.close.x:SetText(HEX.muted .. "×|r")
    mini.close:SetScript("OnClick", function()
        db().guildMiniShown = false
        ns.Refresh()
    end)
    mini.close:SetScript("OnEnter", function(self)
        self.x:SetText(HEX.white .. "×|r")
        ns.Tooltip.Text(self, { "Hide", "Show it again from the guild window's Recruit tab." })
    end)
    mini.close:SetScript("OnLeave", function(self) self.x:SetText(HEX.muted .. "×|r") ns.Tooltip.Hide() end)
    mini.who = Style.Button(mini, "/who", 56, function() Guild.Who() end, function()
        local _, text = Guild.NextWho()
        return "One /who search: " .. text .. ". One per click, at most one every 5 seconds; "
            .. "a full answer is split into smaller level ranges on the next clicks."
    end, { title = "/who search", height = 18 })
    mini.who:SetPoint("RIGHT", mini.close, "LEFT", -4, 0)
    mini.delayed = Style.Button(mini, "", 56, ToggleDelayed, DELAYED_TIP, { title = "Delayed invite", height = 18 })
    mini.delayed:SetPoint("RIGHT", mini.who, "LEFT", -4, 0)
    mini.handsFree = Style.Button(mini, "", 56, ToggleHandsFree, HANDS_FREE_TIP, { title = "Hands Free", height = 18 })
    mini.handsFree:SetPoint("RIGHT", mini.delayed, "LEFT", -4, 0)
    mini.next = Style.Button(mini, "", 56, NextInvite, NextTip, { title = "Next invite", height = 18 })
    mini.next:SetPoint("RIGHT", mini.handsFree, "LEFT", -4, 0)
    mini.note = Style.Text(mini, "GameFontDisableSmall", "CENTER")
    mini.note:SetPoint("TOPLEFT", 10, -60)
    mini.note:SetPoint("RIGHT", -10, 0)
    local holder = CreateFrame("Frame", nil, mini)
    holder:SetPoint("TOPLEFT", 2, -26)
    holder:SetPoint("BOTTOMRIGHT", -2, 4)
    mini.list = Style.List(holder, { labelWidth = 20, colWidths = { 40 }, onClick = OnCandidateClick })
    PlaceMini()
    UI.mini = mini
end

-- cands: the Recruit tab's list from the same redraw (read once per click).
function UI.RefreshMini(cands)
    if not db().guildMiniShown then
        if mini then mini:Hide() end
        return
    end
    if not mini then BuildMini() end
    mini:Show()
    local guild = Guild.Mine()
    local canInvite = guild and Guild.Can("invite")
    local rows = canInvite and UI.CandidateRows(true, cands) or {}
    mini.title:SetText("Recruits  " .. HEX.muted .. #rows .. "|r")
    mini.who:SetLabel(UI.WhoLabel(true))
    mini.list:SetShown(canInvite and true or false)
    mini.who:SetShown(canInvite and true or false)
    local delayed = db().guildDelayedInvite ~= false
    mini.delayed:SetLabel(delayed and "Delay" or "No delay")
    Paint(mini.delayed, delayed)
    mini.delayed:SetShown(canInvite and true or false)
    local handsFree = db().guildHandsFree == true
    mini.handsFree:SetLabel(handsFree and "Free: on" or "Free: off")
    Paint(mini.handsFree, handsFree)
    mini.handsFree:SetShown(canInvite and true or false)
    local ready = Guild.InviteQueue().ready
    mini.next:SetLabel(NextLabel(true, ready))
    Paint(mini.next, ready > 0)
    mini.next:SetShown(canInvite and true or false)
    mini.note:SetShown(not canInvite)
    mini.note:SetText(guild and "Your guild rank cannot invite players." or "You are not in a guild.")
    if canInvite and #rows == 0 then rows[1] = { text = HEX.muted .. "Nobody without a guild in sight.|r" } end
    mini.list:SetItems(rows)
end

function UI.ResetMini()
    db().guildMiniPos = nil
    if mini then PlaceMini() end
end

---------------------------------------------------------------------------
-- Reply notice: a small movable button while recruits' whispers are unread
---------------------------------------------------------------------------
local notice

local function PlaceNotice()
    notice:ClearAllPoints()
    local p = db().guildNoticePos
    if type(p) == "table" and p[1] then
        notice:SetPoint(p[1], UIParent, p[2] or p[1], p[3] or 0, p[4] or 0)
    else
        notice:SetPoint("TOP", UIParent, "TOP", 0, -140)
    end
end

-- unread: the count when the caller just read it (UI.Refresh).
function UI.UpdateNotice(unread)
    local n = (db().guildReplyNotice and Guild.Mine()) and (unread or Guild.Unread()) or 0
    local reading = UI.IsShown() and state.view == "replies"
    if n == 0 or reading then
        if notice then notice:Hide() end
        return
    end
    if not notice then
        notice = Style.Button(UIParent, "", 200, function() UI.Show("replies") end,
            "Players you invited whispered you. Click to read and answer. Drag to move.", { title = "Recruit replies", height = 26 })
        notice:SetFrameStrata("HIGH")
        notice:SetMovable(true)
        notice:SetClampedToScreen(true)
        notice:RegisterForDrag("LeftButton")
        notice:SetScript("OnDragStart", notice.StartMoving)
        notice:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            local point, _, rel, x, y = self:GetPoint(1)
            db().guildNoticePos = { point, rel, x, y }
        end)
        PlaceNotice()
        UI.notice = notice
    end
    notice:SetLabel(HEX.accent .. n .. "|r " .. (n == 1 and "reply" or "replies") .. " from recruits")
    notice:Show()
end

function UI.ResetNotice()
    db().guildNoticePos = nil
    if notice then PlaceNotice() end
end

-- A whisper with a recruit came in or went out.
function UI.OnChat()
    if UI.IsShown() then UI.Refresh() else UI.UpdateNotice() end
end

function UI.Show(view)
    -- Built hidden (also ahead of time, after login): its OnShow asks for the roster.
    if not frame then Build() end
    if view and views[view] then state.view = view end
    if frame:IsShown() then UI.Refresh() else frame:Show() end
end

function UI.Toggle(view)
    if frame and frame:IsShown() and (not view or view == state.view) then frame:Hide() else UI.Show(view) end
end

function UI.IsShown() return frame ~= nil and frame:IsShown() end
-- The tab that shows live scan results (redrawn every scan).
function UI.LiveView() return state.view == "recruit" end
UI.views = views
-- Roster reads and the guild log redraw the window; the recruit scan only
-- while the Recruit tab is open.
-- Guild chat lines only while the Activity tab is open.
-- Frames and the long walks over the guild's history (recruits, who joined
-- through whom) are built after login, so the first open does not stall.
ns.Data.Window(UI, { "guild", "guild.scan", "guild.chat" }, { shows = function(src)
    if src == "guild.scan" then return UI.LiveView() end
    if src == "guild.chat" then return state.view == "activity" end
    return true
end,
    prebuild = function() if not frame then Build() end end,
    warmSources = { "guild" },
    warm = function()
        if not Guild.Mine() then return end
        Guild.Recruits()
        if Guild.Can("invite") then InvitedList(nil) end
        Guild.Conversations()
        Guild.Unread()
        Guild.Recruiters()
    end,
})

---------------------------------------------------------------------------
-- Settings tab
---------------------------------------------------------------------------
local function BuildPage(parent)
    local W = ns.Options.Widgets
    local y = -12
    y = W.Paragraph(parent, y, "Finds players of your faction without a guild (nameplates, target, mouseover and /who) "
        .. "and keeps your guild's roster, joins, leaves and rank changes. A click on a player sends your whisper, "
        .. "a second one the guild invite (or both in one click); nothing is ever sent on its own. Type |cffffffff" .. ns.Cmd.Text("guild") .. "|r for the window.", "GameFontHighlightSmall")
    local rowY = y
    W.Button(parent, rowY, "Open the guild window", 200, function() UI.Show() end)
    y = y - 34
    y = W.Header(parent, y, "Recruiting")
    y = W.Checkbox(parent, y, "guildRecruitScan", "Look for players without a guild near me",
        "Reads the guild of players of your faction from their nameplates, your target and your mouseover.")
    y = W.Checkbox(parent, y, "guildMiniShown", "Show the mini recruit window",
        "A small window with the players without a guild that stays on your screen. Off by default.")
    y = W.Checkbox(parent, y, "guildWhisper", "Whisper my message before the invite",
        "The message is edited in the guild window (Recruit tab).")
    y = W.Checkbox(parent, y, "guildDelayedInvite", "Delayed invite: click again to invite",
        "The first click whispers your message; 10 s after it went out the player is back on the list in red, and "
        .. "the second click sends the guild invite. Off: message and invite in one click.")
    y = W.Checkbox(parent, y, "guildHandsFree", "Hands Free: a click on the open world is my next recruit click",
        "A left- or right-click on the world (not on a window, a player or an NPC) invites the next red row, else "
        .. "runs a /who once the /who button's wait is over, else whispers the next player. One action per click; nothing goes "
        .. "while you do not click. Off in combat.")
    y = W.Checkbox(parent, y, "guildHandsFreeKeys", "Hands Free: my move and jump keys count too",
        "A press of a key bound to moving, turning, strafing or jumping (WASD, Space, or whatever you bound) is a "
        .. "Hands Free click as well. The key still moves you. One press = one action; holding a key is one press.")
    W.Button(parent, y, "Set recruit key", 200, function() Guild.CatchStepKey() end,
        "Press a key or mouse button after clicking: it becomes the recruit key. One press = the next queued invite, "
        .. "else a /who, else a whisper to the next player, Hands Free on or off. A key press is something the game always "
        .. "takes, so it can invite and search. Out of combat.")
    y = y - 34
    y = W.LiveText(parent, y, 18, function()
        local key = Guild.StepKey()
        return key and ("Recruit key: |cffffffff" .. key .. "|r") or "|cffffd100No recruit key yet.|r"
    end)
    y = W.Checkbox(parent, y, "guildWhoZone", "/who searches only my current zone")
    y = W.Checkbox(parent, y, "guildHideChat", "Keep recruiting chatter out of chat",
        "Your opening whispers, the game's \"You have invited\" / \"declines\" / offline lines, and recruits' answers until "
        .. "you write back show only in the guild window (Replies, Invited). Once you write back, that conversation shows "
        .. "in chat as usual. Other whispers are untouched.")
    y = W.Checkbox(parent, y, "guildReplyNotice", "Show a notice when a recruit whispers me",
        "A small button (drag it anywhere) with the number of unread replies; click it to open the Replies tab.")
    y = W.Slider(parent, y, "guildRecruitMinLevel", "Lowest level", 1, 60, 1, "%d")
    y = W.Slider(parent, y, "guildRecruitMaxLevel", "Highest level", 1, 60, 1, "%d")
    y = W.Slider(parent, y, "guildReinviteDays", "Offer again after", 1, 60, 1, "%d days",
        "Players who were invited, declined or were offline are listed again after this.")
    y = W.LiveText(parent, y, 18, function()
        local on = not ns.Census or ns.Census.FriendlyPlatesOn()
        return on and "Friendly nameplates are on." or "|cffffd100Friendly nameplates are off: only your target and mouseover are seen.|r"
    end)
    if ns.Census then
        W.Button(parent, y, "Turn on friendly nameplates", 200, function() ns.Census.ShowFriendlyPlates() ns.Refresh() end,
            "Sets the game's Friendly Player Nameplates option. Out of combat only.")
        y = y - 34
    end
    y = W.Header(parent, y, "Roster")
    y = W.Slider(parent, y, "guildInactiveDays", "Inactive after", 7, 180, 1, "%d days offline")
    return -y + 10
end

ns.Options.AddTab({ label = "Guild", pages = { { label = "Guild", build = BuildPage } } })
