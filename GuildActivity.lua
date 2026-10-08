-- TALOD - Guild activity (officers and the guild master only).
--
-- Who talks in guild chat and who does not. Only lines seen while you are
-- online reach the addon, so "quiet" needs a second fact: the roster showed
-- them online on a day you were watching too. A member never seen online with
-- you is "not seen", never "quiet" (unknown is not shown as silent).
--
-- Recorded only while the game's permissions make you an officer or the guild
-- master (Guild.IsOfficer); nothing is sent anywhere.
--
-- More ways to measure activity come later as signals: a signal is one column
-- of the Activity tab (Activity.AddSignal). Guild chat is the first.
--
-- Data per guild (Guild.Data()): chat = { [full] = { n, first, last,
-- d = { [day] = lines }, on = { [day] = true }, c = { [character number] =
-- lines that character saw } } }, chatWatch = { since, d = { [day] = seconds
-- you were online (the account) }, c = { [character number] = { [day] =
-- seconds } } }, chatHidden = lines the game hid.
-- day = days since 1970 (UTC); kept KEEP_DAYS.

local ADDON_NAME, ns = ...
local S = ns.Secret
local Guild = ns.Guild

local Activity = {}
ns.GuildActivity = Activity

local KEEP_DAYS = 60
local OFFICER_CHECK = 10       -- seconds an officer check is reused (each is several game calls)
local ONLINE_STEP = 60         -- seconds between "who is online with you" passes
local WATCH_GAP = 300          -- a longer gap between ticks (loading, a freeze) is not counted as watched

Activity.WINDOWS = { 3, 7, 14, 30 }

local function db() return ns.DB() end

function Activity.Day(t) return math.floor((t or time()) / 86400) end

---------------------------------------------------------------------------
-- Officer check, cached
---------------------------------------------------------------------------
local officerAt, officer = -math.huge, false
local function IAmOfficer()
    local now = GetTime()
    if now - officerAt >= OFFICER_CHECK then
        officerAt, officer = now, Guild.Mine() ~= nil and Guild.IsOfficer()
    end
    return officer
end
Activity.IAmOfficer = IAmOfficer

-- Tests and rank changes: read the permissions again on the next call.
function Activity.Recheck() officerAt = -math.huge end

---------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------
local function Prune(days)
    local oldest = Activity.Day() - KEEP_DAYS
    for day in pairs(days) do
        if day < oldest then days[day] = nil end
    end
end

local function Store(g)
    g.chat = g.chat or {}
    g.chatWatch = g.chatWatch or { since = time(), d = {} }
    return g.chat, g.chatWatch
end

-- The member a chat name belongs to: the roster's key, else the one member
-- with that name (chat may leave the realm out or use another form).
function Activity.MemberKey(g, name)
    local full = Guild.FromFull(name)
    if not full or g.members[full] then return full end
    local short = Guild.Short(full):lower()
    local found
    for key in pairs(g.members) do
        if Guild.Short(key):lower() == short then
            if found then return full end   -- two of that name: not guessed
            found = key
        end
    end
    return found or full
end

local pruned = {}   -- [guild key] = true once old days were dropped this session

-- One guild chat line from `name` at time t. A hidden sender is counted
-- apart and given to nobody.
function Activity.NoteLine(name, t)
    if not IAmOfficer() then return false end
    local g, key = Guild.Data()
    if not g then return false end
    local chat = Store(g)
    name = S.Value(name)
    if type(name) ~= "string" or name == "" then
        g.chatHidden = (g.chatHidden or 0) + 1
        return false
    end
    t = t or time()
    local full = Activity.MemberKey(g, name)
    local rec = chat[full]
    if not rec then
        rec = { n = 0, first = t, d = {} }
        chat[full] = rec
    end
    local day = Activity.Day(t)
    rec.n, rec.last = rec.n + 1, t
    rec.d[day] = (rec.d[day] or 0) + 1
    local me = ns.Store.Me()
    if me then
        rec.c = rec.c or {}
        rec.c[me] = (rec.c[me] or 0) + 1
    end
    if not pruned[key] then
        pruned[key] = true
        for _, r in pairs(chat) do
            Prune(r.d)
            if r.on then Prune(r.on) end
        end
    end
    ns.Data.Changed("guild.chat")
    return true
end

-- Members the roster shows online today: seen on a day you were watching.
local function NoteOnline(g, day)
    local chat = Store(g)
    local me = Guild.Me()
    for full, m in pairs(g.members) do
        if m.online and not m.missing and full ~= me then
            local rec = chat[full]
            if not rec then
                rec = { n = 0, d = {} }
                chat[full] = rec
            end
            rec.on = rec.on or {}
            rec.on[day] = true
        end
    end
end

local lastTick, lastOnline = nil, -math.huge
local function Tick()
    local now = GetTime()
    local dt = lastTick and now - lastTick or 0
    lastTick = now
    if not IAmOfficer() then return end
    local g = Guild.Data()
    if not g then return end
    local _, watch = Store(g)
    local day = Activity.Day()
    local me = ns.Store.Me()
    local mine
    if me then
        watch.c = watch.c or {}
        watch.c[me] = watch.c[me] or {}
        mine = watch.c[me]
    end
    if dt > 0 and dt < WATCH_GAP then
        watch.d[day] = (watch.d[day] or 0) + dt
        if mine then mine[day] = (mine[day] or 0) + dt end
    end
    if now - lastOnline >= ONLINE_STEP then
        lastOnline = now
        Prune(watch.d)
        for _, days in pairs(watch.c or {}) do Prune(days) end
        NoteOnline(g, day)
    end
end

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------
-- The window in days that "active" looks back over (setting guildChatDays).
function Activity.Window()
    local n = tonumber(db().guildChatDays) or 7
    return math.max(1, math.min(KEEP_DAYS, n))
end

local function Sum(days, from)
    local n, count = 0, 0
    for day, v in pairs(days or {}) do
        if day >= from then
            n = n + (v == true and 1 or v)
            count = count + 1
        end
    end
    return n, count
end

-- Days within the window you were online (watching guild chat), and since when.
function Activity.Watched(window)
    local g = Guild.Data()
    local watch = g and g.chatWatch
    if not watch then return 0, nil end
    local from = Activity.Day() - (window or Activity.Window()) + 1
    local _, days = Sum(watch.d, from)
    return days, watch.since
end

-- One member's chat over the window: lines, days they spoke, days seen online
-- with you, last line (time()), and the status:
-- "active"  said something in the window;
-- "quiet"   seen online with you in the window, said nothing;
-- "unseen"  neither (not known to be quiet).
function Activity.Chat(full, window, g)
    g = g or Guild.Data()
    local rec = g and g.chat and g.chat[full]
    local from = Activity.Day() - (window or Activity.Window()) + 1
    local lines, spoke = Sum(rec and rec.d, from)
    local _, online = Sum(rec and rec.on, from)
    local status = lines > 0 and "active" or (online > 0 and "quiet") or "unseen"
    return { lines = lines, spoke = spoke, online = online, last = rec and rec.last, total = rec and rec.n or 0, status = status }
end

---------------------------------------------------------------------------
-- Signals: the Activity tab's columns
---------------------------------------------------------------------------
-- def = { key, label, width, read = function(full, m, g, window) -> sort value
-- (number, nil = unknown), cell text, tooltip line or nil }. Registered in order.
Activity.signals = {}

function Activity.AddSignal(def)
    for i, s in ipairs(Activity.signals) do
        if s.key == def.key then Activity.signals[i] = def return def end
    end
    Activity.signals[#Activity.signals + 1] = def
    return def
end

local HEX = ns.Style.HEX

Activity.AddSignal({ key = "chatLast", label = "Last said", width = 70,
    read = function(full, m, g, window)
        local c = Activity.Chat(full, window, g)
        if not c.last then return nil, HEX.muted .. "-|r", "Never seen in guild chat." end
        local age = time() - c.last
        return -age, (c.status == "active" and HEX.good or HEX.white) .. ns.FormatAge(age) .. " ago|r",
            "Last guild chat line: " .. date("%b %d %H:%M", c.last) .. "  (" .. c.total .. " lines kept)"
    end })

Activity.AddSignal({ key = "chatLines", label = "Lines", width = 64,
    read = function(full, m, g, window)
        local c = Activity.Chat(full, window, g)
        return c.lines, (c.lines > 0 and HEX.white or HEX.muted) .. c.lines .. " / " .. window .. " d|r",
            c.lines .. " lines on " .. c.spoke .. " of the last " .. window .. " days"
    end })

Activity.AddSignal({ key = "chatOnline", label = "Online with you", width = 76,
    read = function(full, m, g, window)
        local c = Activity.Chat(full, window, g)
        return c.online, HEX.muted .. c.online .. " d online|r",
            "Online while you were on " .. c.online .. " of the last " .. window .. " days"
    end })

---------------------------------------------------------------------------
-- Rows for the tab
---------------------------------------------------------------------------
-- filter: "all", "active", "quiet", "unseen". Each x = { full, m, chat, cells }
-- (cells[i] = { value, text, tip } per signal). Sorted: status, then name.
local ORDER = { quiet = 1, active = 2, unseen = 3 }
function Activity.Members(filter, window)
    local g = Guild.Data()
    local out, counts = {}, { all = 0, active = 0, quiet = 0, unseen = 0 }
    if not g then return out, counts end
    window = window or Activity.Window()
    for full, m in pairs(g.members) do
        if not m.missing then
            local c = Activity.Chat(full, window, g)
            counts.all = counts.all + 1
            counts[c.status] = counts[c.status] + 1
            if filter == nil or filter == "all" or filter == c.status then
                local cells = {}
                for i, sig in ipairs(Activity.signals) do
                    local ok, v, text, tip = pcall(sig.read, full, m, g, window)
                    cells[i] = ok and { value = v, text = text, tip = tip } or { text = HEX.muted .. "?|r" }
                end
                out[#out + 1] = { full = full, m = m, chat = c, cells = cells }
            end
        end
    end
    -- Status, rank, then name (a text key: one C sort for hundreds of members).
    ns.Utils.SortBy(out, function(x)
        return string.format("%03d%03d", ORDER[x.chat.status] or 99, x.m.rank or 99) .. x.full
    end)
    return out, counts
end

-- Forgets the chat counts of this guild (the tab's Clear button).
function Activity.Clear()
    local g = Guild.Data()
    if not g then return end
    g.chat, g.chatWatch, g.chatHidden = nil, nil, nil
    ns.Data.Changed("guild.chat")
end

---------------------------------------------------------------------------
-- Module
---------------------------------------------------------------------------
local function OnEvent(event, ...)
    if event == "CHAT_MSG_GUILD" then
        local _, sender = ...
        Activity.NoteLine(sender)
    elseif event == "PLAYER_GUILD_UPDATE" or event == "GUILD_RANKS_UPDATE" then
        Activity.Recheck()
    end
end

ns.RegisterModule("GuildActivity", {
    defaults = { guildChatDays = 7 },
    tick = Tick,
    events = { "CHAT_MSG_GUILD", "PLAYER_GUILD_UPDATE", "GUILD_RANKS_UPDATE" },
    onEvent = OnEvent,
})
