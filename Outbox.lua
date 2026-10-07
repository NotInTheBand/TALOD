-- TALOD - Outbox: every whisper, guild invite and party invite the addon
-- sends goes through here, so one pace and one throttle hold cover them all.
--
-- The game delivers about one whisper a second (measured: 344 openers sent
-- in 222 s were echoed back over the next 6 minutes) and drops lines past its
-- limit ("The number of messages that can be sent is limited, please wait to
-- send another message.", ERR_CHAT_THROTTLED), one message per dropped line.
-- A throttle line pauses every whisper for a hold (doubled when it throttles
-- again soon after), and the queue size it happened at becomes your own
-- limit (outboxBurst, kept across sessions), so the next run slows down
-- before the server does.
--
-- Nothing here sends on its own: each call is one message for one click or
-- one typed command of the caller (the addon never sends on its own). A whisper asked
-- with queue = true may wait for the pace and go out on a later tick, still
-- that one click's message, sent once. Guild and party invites never wait:
-- the game only accepts them during a key press or mouse click (from a tick
-- they are blocked, ADDON_ACTION_BLOCKED, with no Lua error to catch), so
-- they go in the caller's click or not at all. Addon messages
-- (GuildSync) have their own queue and their own server limit.
--
-- Raw send calls (SendChatMessage, GuildInvite, InviteUnit, ...) belong in
-- this file only; tests/run.py fails the build on one anywhere else.

local ADDON_NAME, ns = ...
local S = ns.Secret

local Outbox = {}
ns.Outbox = Outbox

local WHISPERS_PER_SECOND = 1
local MAX_QUEUE = 10           -- default limit of whispers still waiting to be delivered
local MIN_BURST = 2
local REPEAT_GUARD = 10        -- the same whisper / invite to the same player within this is not sent again (GetTime)
local THROTTLE_HOLD, THROTTLE_HOLD_MAX = 15, 120
local THROTTLE_MATCH = 5       -- a dropped line belongs to a whisper sent this recently (GetTime)
local MAX_SENT_LOG = 30

local queueFree = -math.huge   -- GetTime when the last whisper sent is delivered
local holdUntil, holdLen, throttleSource = -math.huge, 0, nil
local recent = {}              -- [kind .. "|" .. target .. "|" .. text] = GetTime() it went out
local sentLog = {}             -- newest last: { t, target, text, label, onLost, lost }
local holdHints = {}           -- functions called when a hold starts; may return a hint for the notice

local function db() return ns.DB() end

local function Fn(tbl, name, global)
    if type(tbl) == "table" and type(tbl[name]) == "function" then return tbl[name] end
    if global and type(_G[global]) == "function" then return _G[global] end
end

-- A double Enter or click while the client lags: the same thing to the same
-- player within REPEAT_GUARD is a repeat. Checked and recorded separately so
-- a send the game refused can be clicked again.
local function IsRepeat(key, now)
    for k, t in pairs(recent) do
        if now - t >= REPEAT_GUARD then recent[k] = nil end
    end
    return recent[key] ~= nil
end

---------------------------------------------------------------------------
-- Pace
---------------------------------------------------------------------------

-- Seconds until the whispers sent so far are delivered (an estimate).
function Outbox.Queue()
    return math.max(0, queueFree - GetTime())
end

-- Seconds left before whispers go out again (0 = not held).
function Outbox.Hold()
    return math.max(0, holdUntil - GetTime())
end

-- Your own whisper queue limit: learned from the last throttle, else MAX_QUEUE.
function Outbox.Burst()
    local n = tonumber(db().outboxBurst)
    return n and math.max(MIN_BURST, math.min(n, MAX_QUEUE)) or MAX_QUEUE
end

function Outbox.Learned() return db().outboxBurst ~= nil end
function Outbox.ResetBurst() db().outboxBurst = nil end

-- Would a whisper go out now? Returns true, or false and why ("held", "busy").
-- "busy" only matters to optional whispers (see Outbox.Whisper).
function Outbox.CanWhisper()
    if Outbox.Hold() > 0 then return false, "held" end
    if Outbox.Queue() >= Outbox.Burst() then return false, "busy" end
    return true
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

local pending = {}             -- queued whispers, oldest first: { text, target, key, opts }

local function Send(text, target, key, opts, send)
    local now = GetTime()
    if not pcall(send, text, "WHISPER", nil, target) then return false, "failed" end
    recent[key] = now
    queueFree = math.max(queueFree, now) + 1 / WHISPERS_PER_SECOND
    sentLog[#sentLog + 1] = { t = now, target = target, text = text, label = opts.label, onLost = opts.onLost }
    while #sentLog > MAX_SENT_LOG do table.remove(sentLog, 1) end
    if opts.onSent then pcall(opts.onSent, text) end
    return true
end

local function IsPending(key)
    for _, p in ipairs(pending) do
        if p.key == key then return true end
    end
    return false
end

-- One whisper. opts (all optional):
--   optional = true  refused with "busy" while the queue is at your limit;
--                    a whisper the player typed goes anyway.
--   queue = true     when the pace or a hold stops it now, it waits in the
--                    queue and goes out as soon as the pace allows (still the
--                    one whisper of the click that asked; never retried).
--   still()          for a queued whisper: checked just before it goes; false
--                    drops it (e.g. the recruit was forgotten).
--   onSent(text)     called when it actually goes out (now or from the queue).
--   onDropped(why)   a queued whisper did not go: "still" (still() said no) or
--                    "failed" (the game refused it).
--   label            name for the "dropped" notice (default: target).
--   onLost(entry)    the game's throttle dropped it (a guess: the newest one
--                    sent); return true when handled, else a notice is printed.
-- Returns true (and "queued" when it waits), or false and why: "held",
-- "busy", "repeat", "failed".
function Outbox.Whisper(text, target, opts)
    opts = opts or {}
    local send = Fn(C_ChatInfo, "SendChatMessage", "SendChatMessage")
    if not send or type(target) ~= "string" or type(text) ~= "string" or text == "" then return false, "failed" end
    local key = "w|" .. target:lower() .. "|" .. text
    if opts.queue then
        if IsPending(key) or IsRepeat(key, GetTime()) then return false, "repeat" end
        -- Behind the ones already waiting, so they go out in click order.
        if #pending > 0 or not Outbox.CanWhisper() then
            pending[#pending + 1] = { text = text, target = target, key = key, opts = opts }
            return true, "queued"
        end
    end
    if Outbox.Hold() > 0 then return false, "held" end
    if opts.optional and Outbox.Queue() >= Outbox.Burst() then return false, "busy" end
    if IsRepeat(key, GetTime()) then return false, "repeat" end
    return Send(text, target, key, opts, send)
end

-- Whispers waiting in the queue.
function Outbox.Pending() return #pending end

function Outbox.IsQueued(target, text)
    return type(target) == "string" and type(text) == "string" and IsPending("w|" .. target:lower() .. "|" .. text)
end

-- Texts of the whispers to this player still waiting in the queue, oldest first.
function Outbox.QueuedFor(target)
    local out = {}
    if type(target) ~= "string" then return out end
    local prefix = "w|" .. target:lower() .. "|"
    for _, p in ipairs(pending) do
        if p.key:sub(1, #prefix) == prefix then out[#out + 1] = p.text end
    end
    return out
end

-- Takes a queued whisper out (the player sends it by hand instead).
function Outbox.Unqueue(target, text)
    if type(target) ~= "string" or type(text) ~= "string" then return false end
    local key = "w|" .. target:lower() .. "|" .. text
    for i, p in ipairs(pending) do
        if p.key == key then
            table.remove(pending, i)
            return true
        end
    end
    return false
end

local function Drain()
    if #pending == 0 then return end
    local send = Fn(C_ChatInfo, "SendChatMessage", "SendChatMessage")
    if not send then return end
    while pending[1] and Outbox.CanWhisper() do
        local p = table.remove(pending, 1)
        local ok, still = true, true
        if p.opts.still then ok, still = pcall(p.opts.still) end
        if not (ok and still) then
            if p.opts.onDropped then pcall(p.opts.onDropped, "still") end
        elseif IsRepeat(p.key, GetTime()) then
            if p.opts.onSent then pcall(p.opts.onSent, p.text) end
        elseif not Send(p.text, p.target, p.key, p.opts, send) and p.opts.onDropped then
            pcall(p.opts.onDropped, "failed")
        end
    end
end

-- One guild invite, only from a click or a typed command (see the header).
-- Returns true, or false and why: "repeat", "failed".
-- [VERIFY] whether the server limits invites the way it limits whispers.
local function SendInvite(target)
    local fn = Fn(C_GuildInfo, "Invite", "GuildInvite")
    if not fn or type(target) ~= "string" then return false, "failed" end
    local now = GetTime()
    local key = "g|" .. target:lower()
    if IsRepeat(key, now) then return false, "repeat" end
    if not pcall(fn, target) then return false, "failed" end
    recent[key] = now
    return true
end
Outbox.GuildInvite = SendInvite

-- On the tick: queued whispers while the pace allows.
Outbox.Drain = Drain

-- One party invite. Returns true, or false and why: "repeat", "failed".
function Outbox.PartyInvite(target)
    local fn = Fn(C_PartyInfo, "InviteUnit", "InviteUnit")
    if not fn or type(target) ~= "string" then return false, "failed" end
    local now = GetTime()
    local key = "p|" .. target:lower()
    if IsRepeat(key, now) then return false, "repeat" end
    if not pcall(fn, target) then return false, "failed" end
    recent[key] = now
    return true
end

---------------------------------------------------------------------------
-- The game's throttle
---------------------------------------------------------------------------

local THROTTLE_PATTERN = "number of messages that can be sent is limited"

function Outbox.IsThrottleText(text)
    text = S.Value(text)
    if type(text) ~= "string" then return false end
    local g = S.Value(_G.ERR_CHAT_THROTTLED)
    if type(g) == "string" and g ~= "" and text == g then return true end
    return text:lower():find(THROTTLE_PATTERN, 1, true) ~= nil
end

-- fn(holdSeconds) runs when a new hold starts; a string it returns is added
-- to the notice (what the caller does meanwhile).
function Outbox.OnHold(fn)
    holdHints[#holdHints + 1] = fn
end

-- One dropped line: the newest whisper sent in the last THROTTLE_MATCH
-- seconds that is not yet counted as lost. The game does not name it.
local function MarkLost(now)
    for i = #sentLog, 1, -1 do
        local e = sentLog[i]
        if now - e.t > THROTTLE_MATCH then return nil end
        if not e.lost then
            e.lost = true
            return e
        end
    end
end

local function OnThrottle()
    local now = GetTime()
    -- The learned limit: a little under the queue the server refused.
    local burst = math.max(MIN_BURST, math.floor(Outbox.Queue()) - 1)
    if burst < Outbox.Burst() then db().outboxBurst = burst end
    queueFree = math.max(now, queueFree - 1 / WHISPERS_PER_SECOND)
    -- Several lines at once are one throttle; one after the hold began is a new one.
    local newHold = now >= holdUntil or now - (holdUntil - holdLen) > 1
    if newHold then
        holdLen = (now < holdUntil + 30 and holdLen > 0) and math.min(holdLen * 2, THROTTLE_HOLD_MAX) or THROTTLE_HOLD
        holdUntil = now + holdLen
    end
    local e = MarkLost(now)
    if e then
        local ok, handled = true, false
        if e.onLost then ok, handled = pcall(e.onLost, e) end
        if not (ok and handled) then
            ns.Print("the game dropped your whisper to " .. (e.label or e.target) .. ": \"" .. e.text .. "\"")
        end
    end
    if newHold then
        local hints = {}
        for _, fn in ipairs(holdHints) do
            local ok, hint = pcall(fn, holdLen)
            if ok and type(hint) == "string" and hint ~= "" then hints[#hints + 1] = hint end
        end
        ns.Print(string.format("the game is limiting your messages: whispers paused for %d s, then at most %d queued.%s",
            holdLen, Outbox.Burst(), #hints > 0 and (" " .. table.concat(hints, " ")) or ""))
    end
    ns.Refresh()
end

-- event: the first kind of event a throttle line came on is the one counted
-- (the same line can come as a UI message and a system message).
function Outbox.OnThrottleLine(event, text)
    if not Outbox.IsThrottleText(text) then return false end
    throttleSource = throttleSource or event
    if event == throttleSource then OnThrottle() end
    return true
end

local function OnEvent(event, ...)
    if event == "CHAT_MSG_SYSTEM" then
        Outbox.OnThrottleLine(event, (...))
    else
        -- (errorType, message); older clients send the message alone.
        local a, b = ...
        Outbox.OnThrottleLine(event, b ~= nil and b or a)
    end
end

local function Status()
    ns.Print(string.format("whispers: at most %d queued (%s)%s%s.", Outbox.Burst(),
        Outbox.Learned() and "learned from the game's limit; " .. ns.Cmd.Text("pace") .. " reset forgets it" or "default",
        Outbox.Hold() > 0 and string.format(", paused %d s more", math.ceil(Outbox.Hold())) or "",
        #pending > 0 and string.format(", %d waiting to go out", #pending) or ""))
end
Outbox.Status = Status

local function Slash(command, rest)
    if command ~= "pace" then return false end
    if (rest or ""):lower():match("^%s*reset") then Outbox.ResetBurst() end
    Status()
    return true
end

ns.RegisterModule("Outbox", {
    init = function()
        -- The limit used to be Guild's own.
        local d = db()
        if d.guildWhisperBurst ~= nil then
            d.outboxBurst = d.outboxBurst or d.guildWhisperBurst
            d.guildWhisperBurst = nil
        end
    end,
    tick = function() Outbox.Drain() end,
    events = { "CHAT_MSG_SYSTEM", "UI_ERROR_MESSAGE", "UI_INFO_MESSAGE" },
    onEvent = OnEvent,
    slash = Slash,
})
