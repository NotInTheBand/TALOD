-- TALOD - version check: is there a newer TALOD than the one loaded?
--
-- An addon cannot reach the internet, so copies tell each other. Every copy
-- joins one hidden custom channel (ns.VERSION_CHANNEL, removed from the chat
-- windows, its notices filtered) and talks there in addon messages only:
--
--   Q~<version>                 "the newest I know is <version>; anyone newer?"
--   N~<version>~<date>~<sig>    a signed release note: <version> is out
--
-- The note is signed with the author's private key when a release is
-- uploaded (tools/release_sign.py, by hand) and checked against the public
-- key every copy carries (Release.lua, Signature.lua). A forged or altered
-- note fails the check and is ignored, so nobody can fake an update notice.
-- Repeating a real note is harmless: it is true.
--
-- Built for a channel of 10,000+ copies, where every message reaches all:
--   * An account asks at most once an hour (versionAskedAt), at login when due.
--   * A note goes out only to answer an ask from a copy that knows less;
--     nothing is announced unprompted.
--   * One note answers every ask made before it: a copy that hears the newest
--     note after the latest ask it was going to answer stays quiet.
--   * The newest note goes out at most once a minute on the whole channel
--     (every copy counts from the last time it heard it), and from one copy at
--     most once every 30 minutes.
--   * Copies that could answer wait a random time skewed late within 30 s, so
--     in a crowd a few fire early and the rest hear them and stay quiet: a
--     handful of answers whether 10 or 10,000 copies could send one.
--   * Incoming messages cost one table write each; past 10 a second the rest
--     are counted and dropped; one signature check every 2 s at most.
--
-- The update window (Style.Notice) opens once a session at most, when a newer
-- version is known (at load or when heard), never in combat.
--
-- The first player in an empty custom channel owns it and could password or
-- ban it; when the channel cannot be joined, copies try the next name.

local ADDON_NAME, ns = ...
local S = ns.Secret
local Style = ns.Style
local Sig = ns.Signature

local Version = {}
ns.Version = Version

local PREFIX = ns.VERSION_PREFIX
local CHANNELS = { ns.VERSION_CHANNEL, ns.VERSION_CHANNEL .. "2", ns.VERSION_CHANNEL .. "3" }
local JOIN_DELAY = 20        -- s after login: the game's own channels join first and keep their numbers
local JOIN_WAIT = 10         -- s for the server to confirm a join
local ASK_DELAY = 3          -- s after joining
local ASK_GAP = 3600         -- an account asks at most this often
local CHANNEL_GAP = 60       -- the newest note at most once a minute on the whole channel
local SEND_GAP = 1800        -- and from one copy at most every 30 minutes
local WAIT_SPAN = 30         -- answers wait up to this long (s) ...
local WAIT_SKEW = 10         -- ... skewed late: few copies early, most at the end
local INBOX_MAX = 10         -- messages handled per second; the rest are dropped
local CHECK_GAP = 2          -- one signature check at most this often (a few ms each)
local MAX_FAILED = 30
local ICON = "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew"

local loginAt, joinedAt, joinUntil, nextJoin, channel
local channelIndex = 1
local asked = false
local answer                 -- { at, v, since }: a planned answer to asks up to `since`
local lastSent = -math.huge
local heardAt = {}           -- [version] = GetTime() the note was last heard on the channel
local inboxSecond, inboxCount = 0, 0
local lastCheck = -math.huge
local queued                 -- the newest unchecked note: { v, d, s, id }
local failed, failedN = {}, 0
local pendingShow, shownThisSession = false, false
local best                   -- the newest valid note known: { v, d, s }
local notice
local stats = { qIn = 0, qOut = 0, nIn = 0, nOut = 0, valid = 0, invalid = 0, dropped = 0, joinTries = 0,
    quietAnswers = 0 }
Version.stats = stats

local function db() return ns.DB() end
local function On() return db().versionCheck ~= false end

---------------------------------------------------------------------------
-- Versions and notes
---------------------------------------------------------------------------
-- "1.2.3" -> { 1, 2, 3 }; anything else (a dev copy's "?") -> nil.
function Version.Parse(v)
    if type(v) ~= "string" or #v > 20 then return nil end
    local a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    return { tonumber(a), tonumber(b), tonumber(c) }
end
local Parse = Version.Parse

-- -1 / 0 / 1; nil when either is not a version.
function Version.Compare(x, y)
    local a, b = Parse(x), Parse(y)
    if not a or not b then return nil end
    for i = 1, 3 do
        if a[i] ~= b[i] then return a[i] < b[i] and -1 or 1 end
    end
    return 0
end
local Compare = Version.Compare

function Version.Mine() return Parse(ns.VERSION) and ns.VERSION or nil end

local function Newer(x, y) return Compare(x, y) == 1 end
local function AtLeast(x, y) local c = Compare(x, y) return c == 1 or c == 0 end

-- True when the note is signed with the author's key.
function Version.Valid(note)
    if type(note) ~= "table" or not Parse(note.v) or type(note.d) ~= "string" or not note.d:match("^%d%d%d%d%-%d%d%-%d%d$") then
        return false
    end
    return Sig.Verify(ns.NAME .. "|" .. note.v .. "|" .. note.d, note.s, ns.RELEASE_KEY) == true
end

function Version.Best() return best end

-- The newest released version newer than this copy, as a note, or nil.
function Version.Newer()
    local mine = Version.Mine()
    if best and mine and Newer(best.v, mine) then return best end
end

local function Learn(note, saved)
    if best and not Newer(note.v, best.v) then return end
    best = { v = note.v, d = note.d, s = note.s }
    if not saved then db().versionNews = { v = note.v, d = note.d, s = note.s, at = time() } end
    if Version.Newer() and not shownThisSession then pendingShow = true end
    ns.Refresh()
end

---------------------------------------------------------------------------
-- The channel
---------------------------------------------------------------------------
local function ChannelId(name)
    name = name or channel
    if not (name and GetChannelName) then return nil end
    local id = S.Call(GetChannelName, name)
    return type(id) == "number" and id > 0 and id or nil
end

-- Its lines never reach a chat window: the join notice, players joining and
-- leaving, and anyone typing in it.
local function Ours(...)
    for i = 1, select("#", ...) do
        local v = S.Value((select(i, ...)))
        if type(v) == "string" then
            v = v:lower()
            for _, name in ipairs(CHANNELS) do
                if v:find(name:lower(), 1, true) then return true end
            end
        end
    end
    return false
end

local function Filter(_, _, _, _, _, channelName, _, _, _, _, baseName)
    if Ours(channelName, baseName) then return true end
    return false
end

local FILTERED = { "CHAT_MSG_CHANNEL", "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER", "CHAT_MSG_CHANNEL_JOIN",
    "CHAT_MSG_CHANNEL_LEAVE" }

local function HideFromChatWindows(name)
    local remove = ChatFrame_RemoveChannel
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local frame = _G["ChatFrame" .. i]
        if frame then
            if remove then
                pcall(remove, frame, name)
            elseif frame.RemoveChannel then
                pcall(frame.RemoveChannel, frame, name)
            end
        end
    end
end

-- The server confirms a join a moment later: Joined() polls for it. A
-- channel that will not take us (password, ban, no free slot) -> the next name.
local function Join(now)
    stats.joinTries = stats.joinTries + 1
    local name = CHANNELS[channelIndex]
    local join = JoinTemporaryChannel or JoinChannelByName
    if not join then
        stats.joinError, nextJoin = "the game has no channel join function", nil
        return
    end
    local ok, err = pcall(join, name)
    if ok then
        joinUntil = now + JOIN_WAIT
    else
        stats.joinError = tostring(err)
        nextJoin = now + JOIN_WAIT
    end
end

local function Joined(now)
    local name = CHANNELS[channelIndex]
    if ChannelId(name) then
        channel, joinedAt, joinUntil, nextJoin, stats.joinError = name, now, nil, nil, nil
        HideFromChatWindows(name)
    elseif now >= joinUntil then
        joinUntil = nil
        stats.joinError = "could not join " .. name .. " (password, ban, or all channel slots in use?)"
        channelIndex = channelIndex + 1
        nextJoin = CHANNELS[channelIndex] and now + 1 or nil
    end
end

local function Leave()
    if channel and ChannelId(channel) and LeaveChannelByName then pcall(LeaveChannelByName, channel) end
    channel, joinedAt, joinUntil, asked, answer = nil, nil, nil, false, nil
    channelIndex, stats.joinTries = 1, 0
    nextJoin = loginAt and GetTime() or nil
end

-- Older clients return true / false, newer ones a result code (0 = sent); kept for the status lines.
local function Send(msg)
    local api, id = C_ChatInfo, ChannelId()
    if not (id and api and api.SendAddonMessage) then return false end
    local ok, result = pcall(api.SendAddonMessage, PREFIX, msg, "CHANNEL", id)
    result = S.Value(result)
    stats.lastSend = ok and tostring(result) or ("error: " .. tostring(result))
    return ok and result ~= false and (result == nil or result == true or result == 0)
end

---------------------------------------------------------------------------
-- Messages in
---------------------------------------------------------------------------
-- Your own messages come back to you. On Forever the sender reads "First
-- Surname-Realm" while UnitName gives "First": the guild helpers know both.
local function FromMe(sender)
    local G = ns.Guild
    if G and G.FromFull and G.Me then
        local me = G.Me()
        if me and G.FromFull(sender) == me then return true end
    end
    local me = UnitName and S.Call(UnitName, "player")
    return type(me) == "string" and (sender == me or sender:match("^([^%-]+)") == me)
end

-- Late-skewed random wait in [0, WAIT_SPAN]: density grows as e^(skew t), so with
-- many copies racing, few draw an early time and the first one silences the rest.
function Version.Wait(u)
    u = u or math.random()
    local k = WAIT_SKEW
    return WAIT_SPAN / k * math.log(1 + u * (math.exp(k) - 1))
end

-- A real note for version v went over the channel at `at`: it answers every ask made before it.
function Version.Heard(v, at)
    heardAt[v] = math.max(heardAt[v] or -math.huge, at)
    if answer and AtLeast(v, answer.v) and at >= answer.since then
        answer = nil
        stats.quietAnswers = stats.quietAnswers + 1
    end
end

function Version.OnMessage(prefix, text, dist, sender)
    if S.Value(prefix) ~= PREFIX or not On() then return end
    local now = GetTime()
    local second = math.floor(now)
    if second ~= inboxSecond then inboxSecond, inboxCount = second, 0 end
    inboxCount = inboxCount + 1
    if inboxCount > INBOX_MAX then
        stats.dropped = stats.dropped + 1
        return
    end
    text, sender = S.Value(text), S.Value(sender)
    if type(text) ~= "string" or #text > 255 or type(sender) ~= "string" then return end
    if FromMe(sender) then return end

    local kind, rest = text:match("^([QN])~(.*)$")
    if kind == "Q" then
        stats.qIn = stats.qIn + 1
        -- They know less than this copy: one answer later covers them and every ask before it.
        if best and Parse(rest) and Newer(best.v, rest) then
            if answer then
                answer.since = now
            else
                answer = { at = now + Version.Wait(), v = best.v, since = now }
            end
        end
    elseif kind == "N" then
        stats.nIn = stats.nIn + 1
        local v, d, s = rest:match("^([%d%.]+)~([%d%-]+)~([%w%+/=]+)$")
        if not (v and Parse(v)) then return end
        -- Only a real note counts as heard (and silences answers): the exact note this copy
        -- already checked, or a newer one once its signature checks out. Otherwise a stream of
        -- fakes could keep every copy quiet and newcomers would never hear the real one.
        if best and v == best.v and d == best.d and s == best.s then
            Version.Heard(v, now)
            return
        end
        if best and not Newer(v, best.v) then return end
        local id = v .. "~" .. d .. "~" .. s
        if failed[id] then return end
        if not queued or Newer(v, queued.v) then queued = { v = v, d = d, s = s, id = id, at = now } end
    end
end

-- One check per CHECK_GAP: a flood of fake notes costs a few ms every 2 s at most.
local function CheckQueued(now)
    if not queued or now - lastCheck < CHECK_GAP then return end
    local note = queued
    queued, lastCheck = nil, now
    if best and not Newer(note.v, best.v) then return end
    if Version.Valid(note) then
        stats.valid = stats.valid + 1
        Learn(note)
        Version.Heard(note.v, note.at or now)
    else
        stats.invalid = stats.invalid + 1
        if failedN >= MAX_FAILED then failed, failedN = {}, 0 end
        failed[note.id], failedN = true, failedN + 1
    end
end

---------------------------------------------------------------------------
-- Messages out
---------------------------------------------------------------------------
local lastAskTry = -math.huge

local function Ask(now)
    asked = true
    if time() - (tonumber(db().versionAskedAt) or 0) < ASK_GAP then return end
    -- A send the game refused is tried again a minute later, not every tick.
    if now - lastAskTry < 60 then return end
    lastAskTry = now
    local mine = Version.Mine()
    local know = (best and mine and Newer(best.v, mine) and best.v) or mine or (best and best.v) or "0.0.0"
    if Send("Q~" .. know) then
        stats.qOut = stats.qOut + 1
        db().versionAskedAt = time()
    end
end

local function Answer(now)
    if not best then answer = nil return end
    -- The channel heard this note less than a minute ago, or this copy sent one lately: later.
    local due = math.max((heardAt[best.v] or -math.huge) + CHANNEL_GAP, lastSent + SEND_GAP)
    if now < due then
        if lastSent + SEND_GAP > now then
            answer = nil   -- this copy is done for half an hour; the others answer
            stats.quietAnswers = stats.quietAnswers + 1
        else
            answer.at = due + Version.Wait()
        end
        return
    end
    answer = nil
    if Send("N~" .. best.v .. "~" .. best.d .. "~" .. best.s) then
        stats.nOut = stats.nOut + 1
        lastSent = now
        Version.Heard(best.v, now)
    end
end

---------------------------------------------------------------------------
-- The notice
---------------------------------------------------------------------------
local function Steps(lines)
    local out = {}
    for i, line in ipairs(lines) do out[i] = i .. ".  " .. line end
    return table.concat(out, "\n")
end

local function Pages()
    local name, archive = ns.NAME, ns.ARCHIVE_ADDON
    local W = Style.HEX.white
    local curse = {
        { heading = "Update with the CurseForge app", text = Steps({
            "Quit the game: new addon files are read only when the game starts.",
            "Open the CurseForge app and pick World of Warcraft.",
            "Choose the game version you play " .. name .. " in. WoW Forever has no entry of its own: its uploads are listed as Classic Era.",
            "Under My Add-ons, find " .. name .. " and click " .. W .. "Update|r (or " .. W .. "Update All|r).",
            "Start the game. Your settings and logs are kept: they live in the WTF folder, not in the addon.",
        }) },
    }
    local manual = {
        { heading = "Download it", text = "Get the newest " .. name .. " zip from its download page (link below).",
            copy = { label = "Copy link", text = ns.PROJECT_URL, what = "download page" } },
        { heading = "Replace the old files", text = Steps({
            "Quit the game.",
            "Open your game folder, then the folder of the client you play (for example " .. W .. "_classic_era_|r), then "
                .. W .. "Interface\\AddOns|r.",
            "Delete the folders " .. W .. name .. "|r and " .. W .. archive .. "|r there. Your settings and logs stay: they live in the WTF folder.",
            "Copy both folders from the zip into " .. W .. "AddOns|r. Check that you get " .. W .. "AddOns\\" .. name .. "\\" .. name
                .. ".toc|r, not a folder inside a folder.",
            "Start the game. If the AddOns list says Out of date, tick Load out of date AddOns.",
        }) },
    }
    return {
        { key = "curse", label = "CurseForge app", blocks = curse },
        { key = "manual", label = "Without CurseForge", blocks = manual },
    }
end

local function Spec()
    local mine, news = Version.Mine() or tostring(ns.VERSION), Version.Newer()
    local close = { label = "Close", width = 100, onClick = function() notice:Hide() end }
    if news then
        return { tone = "gold", headline = ns.NAME .. " " .. news.v .. " is out (" .. news.d .. "). You have " .. mine .. ".",
            sub = "This window opens once each time the game loads, until you update. It takes a minute:",
            pages = Pages(), buttons = { { label = "Remind me next login", width = 170, onClick = function() notice:Hide() end,
                tooltip = "Closes it; it opens again the next time the game loads, until you update." } } }
    end
    local sub
    if not On() then
        sub = "The version check is off (settings: General). To update by hand:"
    elseif not ns.RELEASE_KEY then
        sub = "This copy cannot check versions (no release key). To update by hand:"
    else
        sub = "No newer version heard of yet: other " .. ns.NAME .. " players' copies tell yours when one is out. To update by hand:"
    end
    return { tone = "good", headline = "You have " .. ns.NAME .. " " .. mine .. ".", sub = sub, pages = Pages(), buttons = { close } }
end

function Version.Show()
    notice = notice or Style.Notice(ns.FRAME .. "UpdateNotice", "Update", { width = 500, tone = "gold", icon = ICON })
    notice:Set(Spec())
    notice:Show()
    return notice
end

-- For /talod version status and the probe: what the check sees, in words.
function Version.StatusLines()
    local function Y(b) return b and "yes" or "no" end
    local own = ns.RELEASE_NOTE
    local askedAt = tonumber(db().versionAskedAt) or 0
    return {
        "version check: " .. (On() and "on" or "off") .. ", this copy " .. tostring(ns.VERSION),
        "  release key: " .. Y(ns.RELEASE_KEY ~= nil) .. ", own note: " .. (own and (tostring(own.v) .. " " .. (Version.Valid(own) and "valid" or "INVALID")) or "none"),
        "  newest known: " .. (best and (best.v .. " (" .. best.d .. ")") or "none") .. ", newer than this copy: " .. Y(Version.Newer()),
        "  channel: " .. (channel and ChannelId() and (channel .. " joined as " .. ChannelId()) or ("not joined" .. (stats.joinError and (" - " .. stats.joinError) or ""))),
        "  last ask from this account: " .. (askedAt > 0 and (math.floor((time() - askedAt) / 60) .. " min ago") or "never"),
        string.format("  this session: asked %d, heard %d asks, sent %d notes, heard %d notes (%d valid, %d invalid), "
            .. "%d answers left to others, %d dropped (flood)", stats.qOut, stats.qIn, stats.nOut, stats.nIn, stats.valid,
            stats.invalid, stats.quietAnswers, stats.dropped),
        "  last send result: " .. tostring(stats.lastSend or "none"),
    }
end

local function InCombat()
    return (InCombatLockdown and InCombatLockdown()) or (UnitAffectingCombat and S.Call(UnitAffectingCombat, "player") == true)
end

---------------------------------------------------------------------------
-- Module
---------------------------------------------------------------------------
local function Tick()
    local now = GetTime()
    if pendingShow and On() and not InCombat() then
        pendingShow, shownThisSession = false, true
        if not (notice and notice:IsShown()) then Version.Show() end
    end
    if not On() then
        if channel or joinUntil then Leave() end
        return
    end
    if not loginAt then return end
    if not joinedAt then
        if joinUntil then
            Joined(now)
        elseif nextJoin and now >= nextJoin then
            Join(now)
        end
        if not joinedAt then return end
    end
    if not asked and now - joinedAt >= ASK_DELAY then Ask(now) end
    -- Hourly: a session longer than an hour asks again.
    if asked and time() - (tonumber(db().versionAskedAt) or 0) >= ASK_GAP then asked = false end
    if answer and now >= answer.at then Answer(now) end
    CheckQueued(now)
end

ns.RegisterModule("Version", {
    defaults = { versionCheck = true, versionNews = {}, versionAskedAt = 0 },
    init = function()
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX) end
        if ChatFrame_AddMessageEventFilter then
            for _, event in ipairs(FILTERED) do ChatFrame_AddMessageEventFilter(event, Filter) end
        end
        -- What this copy shipped with, then what it heard before (checked again: the save file is plain text).
        if Version.Valid(ns.RELEASE_NOTE) then Learn(ns.RELEASE_NOTE, true) end
        local news = db().versionNews
        -- Kept after updating too: still worth passing on to copies that are behind.
        if type(news) == "table" and news.v then
            if Version.Valid(news) then Learn(news, true) else db().versionNews = {} end
        end
    end,
    tick = Tick,
    events = { "PLAYER_ENTERING_WORLD", "CHAT_MSG_ADDON" },
    onEvent = function(event, ...)
        if event == "CHAT_MSG_ADDON" then
            Version.OnMessage(...)
        elseif event == "PLAYER_ENTERING_WORLD" then
            if not loginAt then
                loginAt = GetTime()
                nextJoin = loginAt + JOIN_DELAY
            end
        end
    end,
    slash = function(command, rest)
        if command ~= "version" then return false end
        if (rest or ""):lower() == "status" then
            if ns.Probe and ns.Probe.ShowText then ns.Probe.ShowText(table.concat(Version.StatusLines(), "\n")) end
        else
            Version.Show()
        end
        return true
    end,
})
