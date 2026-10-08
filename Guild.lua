-- TALOD - Guild: recruiting and guild management.
--
-- Recruiting: players of your faction near you (nameplates, target,
-- mouseover) and from /who searches who have no guild go on a list. One
-- click on a row sends your whisper and one guild invite to that one player
-- (like the crafting and fishing buttons): nothing is
-- queued, nothing is sent from a timer or an event, and /who runs one search
-- per click.
--
-- A unit's guild can read nil for a moment after it shows up (the data
-- arrives later), so "no guild" needs two nil reads CONFIRM_SECONDS apart; a
-- secret guild is unknown and never listed. A /who result is the server's
-- answer and counts at once.
--
-- Management: the roster is read on GUILD_ROSTER_UPDATE (requested only at
-- login, when the window opens and on its Refresh button). Joins, leaves and
-- rank changes come from the difference between reads: the system messages
-- that name who did it may be secret on Forever, so they only add "by".
-- A member missing from one read is not "left" until a later read at least
-- LEAVE_CONFIRM seconds after still misses them.
--
-- Data per guild: TALODDB.guild.guilds["Guild-Realm"] = { members, log,
-- recruits, rules, ranks, baseline, lastRead }. Messages are account-wide in
-- TALODDB.guildMessages (no default table: a deep default merge would put
-- back a message you deleted).

local ADDON_NAME, ns = ...
local S = ns.Secret

local Guild = {}
ns.Guild = Guild

local SCAN_INTERVAL = 1        -- seconds between plate scans for recruits
local CONFIRM_SECONDS = 3      -- two nil guild reads this far apart = no guild
local CANDIDATE_TTL = 1800     -- an unseen candidate leaves the list after this
local LIVE_SECONDS = 10        -- seen this recently = "here"
local ROSTER_READ_GAP = 2      -- read the roster at most this often (GetTime)
local LEAVE_CONFIRM = 60       -- missing from the roster this long (and a later read) = left
local HINT_SECONDS = 300       -- a system message names "by" for a change noticed this soon after
local INVITE_GUARD = 60        -- a second click on the same player within this sends nothing
local INVITE_DELAY = 10        -- delayed invite: seconds from the opener going out until the recruit is back to click
local ACK_WAIT = 60            -- no "You have invited X" this long after the invite = unconfirmed (= INVITE_GUARD: clickable again)
local QUICK_ANSWER = 120       -- in a guild / invited elsewhere / offline come right after the send
local DECLINE_ANSWER = 900     -- a decline comes when they click, or when the game's invite window times out
local UNMATCHED_SECONDS = 10   -- system lines this soon after a send are kept for /talod guild check
local MAX_UNMATCHED = 10
local ANSWERS = { declined = true, guilded = true, pending = true, notfound = true }  -- the game's answers to an invite
local WHO_WAIT = 15            -- /who results later than this are not ours
local MAX_LOG = 2000
local MAX_WHISPER = 255


Guild.DEFAULT_MESSAGES = {
    "Hi {name}! <{guild}> is recruiting: friendly people, help with quests and dungeons, all levels welcome. "
        .. "I just sent you an invite. Questions? Whisper me!",
    "Hey {name}, looking for a guild? <{guild}> would be glad to have you. Invite sent, accept if you like. No pressure!",
}

local candidates = {}          -- [full name] = { name, full, classFile, level, race, zone, src, first, last, nilSince, nilReads, confirmed }
local hints = {}               -- [full name] = { kind, by, rank, t } from system messages
local lastScan, lastRosterRead, rosterDirty = -math.huge, -math.huge, false
local whoPending, whoStatus = nil, nil
local lastSend = -math.huge    -- GetTime of the last opener or invite that went out
local unmatched = {}           -- system lines right after a send that matched nothing (session only)

local function db() return ns.DB() end

---------------------------------------------------------------------------
-- API lookups (C_GuildInfo on the newer engine, globals on Classic Era)
---------------------------------------------------------------------------
local function Fn(tbl, name, global)
    if type(tbl) == "table" and type(tbl[name]) == "function" then return tbl[name] end
    if global and type(_G[global]) == "function" then return _G[global] end
end

local function GI() return C_GuildInfo end

local PERMS = {
    invite = "CanGuildInvite", promote = "CanGuildPromote", demote = "CanGuildDemote", remove = "CanGuildRemove",
}

-- True only when the game says yes; unknown is no.
function Guild.Can(what)
    local name = PERMS[what]
    local fn = name and Fn(GI(), name, name)
    return fn ~= nil and S.Call(fn) == true
end

-- Guild master or officer by the game's own permissions: rank 0, the game's
-- officer flag (officer chat), or a right only officers usually get (officer
-- notes, promote, remove). Unknown is no. The officer ranks a guild master
-- picks for sharing (GuildSync) do not count here.
local OFFICER_RIGHTS = { "CanViewOfficerNote", "CanEditOfficerNote", "CanGuildPromote", "CanGuildRemove" }
function Guild.IsOfficer()
    if not (IsInGuild and S.Call(IsInGuild) == true) then return false end
    local _, _, rank = S.CallMulti(3, GetGuildInfo, "player")
    if rank == 0 then return true end
    local leader = Fn(nil, nil, "IsGuildLeader")
    if leader and S.Call(leader) == true then return true end
    local flag = Fn(GI(), "IsGuildOfficer")
    if flag and S.Call(flag) == true then return true end
    for _, name in ipairs(OFFICER_RIGHTS) do
        local fn = Fn(GI(), name, name)
        if fn and S.Call(fn) == true then return true end
    end
    return false
end

-- Names. Classic: "Name-Realm", the realm normalized (no spaces or hyphens).
-- WoW Forever: a first name and a surname ("Lyrah Shadeleaf"). The server
-- writes "Lyrah Shadeleaf-ClassicBetaPvP2" (roster, /who, system and addon
-- messages), but the unit functions hand the surname back where the realm
-- goes (UnitName gives "Lyrah", "Shadeleaf"), and whispers and invites only
-- find "Lyrah Shadeleaf", without the realm.
-- Every name is kept the server's way, so one player is one key.
local knownRealms = {}         -- realms seen in names the server wrote
local splitNames               -- true: this client hands surnames back as realms (Forever)
-- Forever's beta PvP realms are one realm group: names are one across it.
local REALM_GROUP = { ClassicBetaPvP = true, ClassicBetaPvP2 = true }

local function NormRealm(r) return (tostring(r):gsub("[%s%-]", "")) end

local function MyRealm()
    local r = (GetNormalizedRealmName and S.Call(GetNormalizedRealmName)) or (GetRealmName and S.Call(GetRealmName)) or ""
    return NormRealm(r)
end

local function IsRealm(r)
    if type(r) ~= "string" or r == "" then return false end
    if r == MyRealm() or knownRealms[r] then return true end
    return REALM_GROUP[MyRealm()] == true and REALM_GROUP[r] == true
end
Guild.IsRealm = IsRealm

-- Name and realm of "Name-Realm" (realm nil when there is none).
function Guild.Split(full)
    if type(full) ~= "string" then return nil end
    local name, realm = full:match("^(.+)%-([^%-%s]+)$")
    if name then return name, realm end
    return full, nil
end

-- A name the server wrote: remember its realm; a space marks Forever's names.
local function NoteServerName(full)
    local name, realm = Guild.Split(full)
    local spaced = type(name) == "string" and name:find(" ", 1, true) ~= nil
    if spaced then splitNames = true end
    -- On Forever "First-Surname" also reaches us: only "First Surname-Realm" names a realm.
    if realm and (spaced or not Guild.SplitNames()) then knownRealms[realm] = true end
end

-- True on a client whose unit functions split "First Surname" (Forever).
function Guild.SplitNames()
    if splitNames == nil then
        local name, second = S.CallMulti(2, UnitFullName or UnitName, "player")
        if type(name) == "string" and type(second) == "string" and second ~= "" and not IsRealm(NormRealm(second)) then
            splitNames = true
        end
    end
    return splitNames == true
end

-- "First-Surname[-Realm]" from the game's unit functions or chat, the
-- server's way ("First Surname[-Realm]"). Unchanged on Classic.
function Guild.Normal(name)
    if type(name) ~= "string" or name == "" or not Guild.SplitNames() then return name end
    local first, rest = name:match("^([^%-]+)%-(.+)$")
    if not first or first:find(" ", 1, true) then return name end
    local surname, realm = rest:match("^([^%-]+)%-(.+)$")
    if surname and IsRealm(realm) then return first .. " " .. surname .. "-" .. realm end
    if IsRealm(rest) then return name end
    return first .. " " .. rest
end

-- "Name-Realm" from a name and an optional realm (a typed name, a system
-- message, or UnitName's two values).
function Guild.FullName(name, realm)
    if type(name) ~= "string" or name == "" then return nil end
    if type(realm) == "string" and realm ~= "" then
        local r = NormRealm(realm)
        -- Forever: the second value is the surname.
        if Guild.SplitNames() and not IsRealm(r) then return name .. " " .. realm .. "-" .. MyRealm() end
        knownRealms[r] = true
        return name .. "-" .. r
    end
    name = Guild.Normal(name)
    local _, suffix = Guild.Split(name)
    if suffix and IsRealm(suffix) then return name end
    return name .. "-" .. MyRealm()
end
local FullName = Guild.FullName

-- A name the server wrote, with its realm when not yours (the roster, /who,
-- whisper and addon senders).
function Guild.FromFull(full)
    if type(full) ~= "string" or full == "" then return nil end
    NoteServerName(full)
    full = Guild.Normal(full)
    local _, realm = Guild.Split(full)
    if not realm or not IsRealm(realm) and not knownRealms[realm] then return full .. "-" .. MyRealm() end
    return full
end
local FromFull = Guild.FromFull

-- Your own name, the server's way ("Aalina Windsong-ClassicBetaPvP2").
function Guild.Me()
    return FullName(S.CallMulti(2, UnitFullName or UnitName, "player"))
end

-- The name without the realm ("Mira Stone").
function Guild.Short(full) return type(full) == "string" and Guild.Split(full) or "?" end

-- What to type after /w or /ginvite: the name alone on your own realm (and,
-- on Forever, your realm group: "First Surname-Realm" is not found there).
local function Target(full)
    local name, realm = Guild.Split(full)
    if realm == MyRealm() or (Guild.SplitNames() and IsRealm(realm)) then return name end
    return full
end
Guild.Target = Target

-- Your guild name, rank name and rank index (0 = guild master), or nil.
function Guild.Mine()
    if not (IsInGuild and S.Call(IsInGuild) == true) then return nil end
    local name, rankName, rankIndex = S.CallMulti(3, GetGuildInfo, "player")
    if type(name) ~= "string" or name == "" then return nil end
    return name, rankName, type(rankIndex) == "number" and rankIndex or nil
end

function Guild.Key()
    local name = Guild.Mine()
    return name and (name .. "-" .. MyRealm()) or nil
end

local settled = {}   -- [guild key] = true once this session's leftover "inviting" were cleared
-- Delayed invite: recruits whose opener is out, waiting for the click that
-- sends the invite. [full] = { at = GetTime() when it may go, shown }.
local waiting = {}

-- This guild's saved data (nil when you are not in a guild).
function Guild.Data()
    local key = Guild.Key()
    if not key then return nil end
    local root = db().guild
    if type(root) ~= "table" then root = {} db().guild = root end
    root.guilds = root.guilds or {}
    local g = root.guilds[key]
    if not g then
        g = { members = {}, log = {}, recruits = {}, rules = {}, ranks = {}, namesV = 2, chatV = 2 }
        root.guilds[key] = g
    end
    if g.namesV ~= 2 then Guild.MigrateNames(g) end
    if (g.chatV or 0) < 2 then Guild.BackfillOpeners(g) end
    if not settled[key] then
        settled[key] = true
        -- A delayed invite whose opener went out still waits for its click;
        -- an opener still queued when the game closed or reloaded never went
        -- (the Outbox queue lives in memory only).
        for full, r in pairs(g.recruits) do
            if r.status == "inviting" then
                if r.whisper and not r.unsent then waiting[full] = { at = 0, why = "reload", since = 0 } else r.status = "uninvited" end
            end
        end
        Guild.PackAll(g)
    end
    return g, key
end

---------------------------------------------------------------------------
-- Packed recruit records
---------------------------------------------------------------------------
-- A long recruiting run keeps every player ever invited (so they are not
-- offered again): thousands of records of about 17 fields each, the largest
-- part of the saved data. A settled record (no reply, nothing unread, not
-- touched for PACK_AFTER) keeps as real fields only what the lists, the
-- recruiter stats, re-invite days and the shared seal read (HOT); the rest
-- goes into one string `x` (Store.PackList). A metatable gives the packed
-- fields back on read, so every reader sees the same record. Writing a
-- packed field unpacks the record first (Thaw), so writes and deletions
-- always land. Unpacked again at the next login once it is settled again.
local PACK_AFTER = 3 * 86400
local HOT = { status = true, t = true, invited = true, by = true, level = true, classFile = true, replied = true, ignoring = true, x = true }
local COLD = { "name", "race", "zone", "src", "first", "invites", "seq", "ack", "guid", "saidNo", "noFrom",
    "whisper", "echo", "echoT", "unsent", "last", "chat" }
local COLD_AT = {}
for i, k in ipairs(COLD) do COLD_AT[k] = i end
local CHAT_AT, ECHO_AT = COLD_AT.chat, COLD_AT.echo
local LINE_KEY = { t = true, me = true, text = true, c = true }
local SAME = "W"        -- a text equal to the opener (no tag starts with W)

local St = ns.Store
-- Long walks pause here when they run as background work (Data.lua). Only
-- over arrays and tables the walk built itself: a pause inside pairs() over
-- saved data could meet a key added meanwhile.
local function Step(i) if i % 64 == 0 then ns.Data.Step() end end

local function PackChat(chat, whisper)
    if chat == nil then return "" end
    if type(chat) ~= "table" then return nil end
    local lines, keys = {}, 0
    for _ in pairs(chat) do keys = keys + 1 end
    for i, line in ipairs(chat) do
        if type(line) ~= "table" then return nil end
        for k in pairs(line) do if not LINE_KEY[k] then return nil end end
        local t, me, c = St.PackValue(line.t), St.PackValue(line.me), St.PackValue(line.c)
        local text = (whisper ~= nil and line.text == whisper) and SAME or St.PackValue(line.text)
        if not (t and me and c and text) then return nil end
        lines[i] = t .. ";" .. me .. ";" .. text .. ";" .. c
    end
    if #lines ~= keys then return nil end     -- holes or other keys: left as it is
    return "#" .. table.concat(lines, "~")
end

local function UnpackChat(s, whisper)
    if s == "" then return nil end
    local chat = {}
    if s == "#" then return chat end
    for _, raw in ipairs(St.SplitList(s:sub(2), "~")) do
        local f = St.SplitList(raw, ";")
        chat[#chat + 1] = { t = St.UnpackValue(f[1] or ""), me = St.UnpackValue(f[2] or ""),
            text = f[3] == SAME and whisper or St.UnpackValue(f[3] or ""), c = St.UnpackValue(f[4] or "") }
    end
    return chat
end

local function Decode(x)
    local f = St.SplitList(x, "|")
    local out = {}
    for i, k in ipairs(COLD) do
        if i ~= CHAT_AT and i ~= ECHO_AT then out[k] = St.UnpackValue(f[i] or "") end
    end
    out.echo = f[ECHO_AT] == SAME and out.whisper or St.UnpackValue(f[ECHO_AT] or "")
    out.chat = UnpackChat(f[CHAT_AT] or "", out.whisper)
    return out
end

-- Decoded records, dropped by the next garbage collection (a list walk that
-- reads several packed fields decodes each record once, nothing is kept).
local decoded = setmetatable({}, { __mode = "kv" })
local function Cold(r)
    local d = decoded[r]
    if not d then d = Decode(rawget(r, "x")) decoded[r] = d end
    return d
end

local function CopyChat(chat)
    if not chat then return nil end
    local out = {}
    for i, line in ipairs(chat) do out[i] = { t = line.t, me = line.me, text = line.text, c = line.c } end
    return out
end

-- One plain field of a packed record without decoding the rest: a list
-- reads one packed field (ack, last) of thousands of records.
local function ColdField(x, i)
    local pos = 1
    for _ = 2, i do
        local bar = x:find("|", pos, true)
        if not bar then return "" end
        pos = bar + 1
    end
    local stop = x:find("|", pos, true)
    return x:sub(pos, stop and stop - 1 or -1)
end

local Thaw
local PACKED = {
    __index = function(r, k)
        local i = COLD_AT[k]
        if not i then return nil end
        if i ~= CHAT_AT and i ~= ECHO_AT and not decoded[r] then return St.UnpackValue(ColdField(rawget(r, "x"), i)) end
        local v = Cold(r)[k]
        -- The caller may change the list it gets: never the shared copy.
        if k == "chat" then return CopyChat(v) end
        return v
    end,
    __newindex = function(r, k, v)
        if COLD_AT[k] then Thaw(r) end
        rawset(r, k, v)
    end,
}

-- Back to a plain record (before a change to a packed field).
function Thaw(r)
    if getmetatable(r) ~= PACKED then return r end
    local d = Decode(rawget(r, "x"))
    setmetatable(r, nil)
    decoded[r] = nil
    r.x = nil
    for _, k in ipairs(COLD) do r[k] = d[k] end
    return r
end
Guild.Thaw = Thaw

function Guild.IsPacked(r) return getmetatable(r) == PACKED end
function Guild.Attach(r) if rawget(r, "x") ~= nil then setmetatable(r, PACKED) end return r end

local function Settled(full, r, cutoff)
    if r.status == "inviting" or waiting[full] or r.unread then return false end
    if math.max(tonumber(r.t) or 0, tonumber(r.invited) or 0, tonumber(r.last) or 0) >= cutoff then return false end
    for _, line in ipairs(type(r.chat) == "table" and r.chat or {}) do
        if type(line) == "table" and not line.me then return false end
    end
    return true
end

-- The packed form of a plain record, as a new table: Lua 5.1 never shrinks
-- a table whose fields are set to nil, so packing in place would keep the
-- old size until the next login. nil when a field cannot be packed (the
-- record is left as it is). The caller puts the new table in its place.
local function Pack(r)
    for k in pairs(r) do
        if not HOT[k] and not COLD_AT[k] then return nil end
    end
    local values = {}
    for i, k in ipairs(COLD) do
        if i ~= CHAT_AT and i ~= ECHO_AT then
            values[i] = St.PackValue(r[k])
            if not values[i] then return nil end
        end
    end
    values[ECHO_AT] = (r.echo ~= nil and r.echo == r.whisper) and SAME or St.PackValue(r.echo)
    values[CHAT_AT] = PackChat(r.chat, r.whisper)
    if not values[ECHO_AT] or not values[CHAT_AT] then return nil end
    local out = {}
    for k in pairs(HOT) do out[k] = r[k] end
    out.x = table.concat(values, "|", 1, #COLD)
    return setmetatable(out, PACKED)
end
Guild.PackRecruit = Pack

-- Once per session per guild: records saved packed get their metatable,
-- settled plain ones are packed. Returns how many were packed now.
function Guild.PackAll(g, now)
    local cutoff = (now or time()) - PACK_AFTER
    local n = 0
    for full, r in pairs(g.recruits) do
        if type(r) == "table" and getmetatable(r) ~= PACKED then
            if rawget(r, "x") ~= nil then
                setmetatable(r, PACKED)
            elseif Settled(full, r, cutoff) then
                local packed = Pack(r)
                if packed then g.recruits[full], n = packed, n + 1 end
            end
        end
    end
    return n
end

local MyCharName = function() return Guild.Me() end

-- Cleanup rule: an opener nobody answered is most of a recruit record's size
-- (the text up to three times: whisper, echo, the chat line) and is not read
-- once the invite is settled. Who invited, when, the status and the reply
-- flag stay (Recruiters, re-invite days, what officers receive). Kept whole:
-- an invite still waiting for its click ("inviting"), an opener sent without
-- the invite ("uninvited": its whisper stops a second opener), anything
-- unread and any record with a line from the player (a conversation).
local KEEP_TEXT = { inviting = true, uninvited = true }

local function Answered(r)
    for _, line in ipairs(type(r.chat) == "table" and r.chat or {}) do
        if type(line) == "table" and not line.me then return true end
    end
    return false
end

-- keep (archive): key "Guild-Realm/Name-Realm", value the removed fields
-- packed (whisper; echo; unsent; chat; echoT).
function Guild.StripOldOpeners(cutoff, apply, keep)
    local root = db().guild
    local n = 0
    for gkey, g in pairs(type(root) == "table" and type(root.guilds) == "table" and root.guilds or {}) do
        for full, r in pairs(type(g.recruits) == "table" and g.recruits or {}) do
            -- Another guild's records were never opened this session: packed ones get their metatable here.
            if type(r) == "table" and rawget(r, "x") ~= nil and not Guild.IsPacked(r) then Guild.Attach(r) end
            if type(r) == "table" and not KEEP_TEXT[r.status] and not r.unread
                and math.max(tonumber(r.t) or 0, tonumber(r.invited) or 0) < cutoff
                and (r.chat or r.whisper or r.echo or r.unsent) and not Answered(r) then
                n = n + 1
                if apply then
                    local packed = Guild.IsPacked(r)
                    Guild.Thaw(r)
                    if keep then
                        keep(gkey .. "/" .. full, St.PackList({ r.whisper, r.echo, r.unsent, PackChat(r.chat, r.whisper),
                            r.echoT }, 5, ";"))
                    end
                    r.chat, r.whisper, r.echo, r.echoT, r.unsent = nil, nil, nil, nil, nil
                    -- Assigning an existing key during the walk is allowed.
                    if packed then g.recruits[full] = Guild.PackRecruit(r) or r end
                end
            end
        end
    end
    return n
end

ns.Cleanup.Add({ id = "guildEvents", label = "Guild event log", source = "guild",
    desc = "The game's guild log (invites, joins, leaves, removals) as merged over time. Recruiter stats and "
        .. "memberships then start at the cutoff.",
    days = 360, min = 60, max = 1080, step = 60, archive = true,
    run = function(cutoff, apply, keep) return Guild.DropOldEvents(cutoff, apply, keep) end })
ns.Cleanup.Add({ id = "recruitText", label = "Recruit messages", source = "guild",
    desc = "The opening whisper kept on each settled invite (declined, joined, not found...) when the player never "
        .. "answered. Who invited them, when and how it ended are kept.",
    days = 14, min = 7, max = 182, step = 7, archive = true,
    run = function(cutoff, apply, keep) return Guild.StripOldOpeners(cutoff, apply, keep) end })

-- Before names were read the server's way, a nameplate gave "Lyrah-Shadeleaf"
-- and /who "Lyrah Shadeleaf-ClassicBetaPvP2": one player, two records (and
-- two invites), and you were "Aalina-<realm>". Merged once, when this client
-- is known to split names.
-- Openers lost before they were kept at send time: put back from the
-- whisper text saved on the record, at the invite's time (chatV 1). The
-- game's echo of an opener that arrived more than a minute late (it sends
-- about one whisper a second, so a run of invites queues them for minutes)
-- was kept as a second line: dropped (chatV 2).
local ECHO_SECONDS = 900      -- the game's echo of the opening whisper, kept when sent

function Guild.BackfillOpeners(g)
    for _, r in pairs(g.recruits) do
        if r.whisper and r.chat then
            local first
            for i = 1, #r.chat do
                local line = r.chat[i]
                if line and line.me and line.text == r.whisper then
                    if not first then
                        first = line
                    elseif (line.t or 0) - (first.t or 0) <= ECHO_SECONDS then
                        r.chat[i] = false
                    end
                end
            end
            local kept = {}
            for _, line in ipairs(r.chat) do if line then kept[#kept + 1] = line end end
            r.chat = kept
        end
    end
    for _, r in pairs(g.recruits) do
        if r.whisper and r.invited then
            local has = false
            for _, line in ipairs(r.chat or {}) do if line.me and line.text == r.whisper then has = true break end end
            if not has then
                r.chat = r.chat or {}
                table.insert(r.chat, 1, { t = r.invited, me = true, text = r.whisper })
                table.sort(r.chat, function(x, y) return (x.t or 0) < (y.t or 0) end)
            end
        end
    end
    g.chatV = 2
end

local STATUS_RANK = { joined = 7, declined = 6, guilded = 5, pending = 4, notfound = 3, invited = 2, inviting = 2,
    uninvited = 1, skipped = 1 }
function Guild.MigrateNames(g)
    if not Guild.SplitNames() then return end
    local me = Guild.Me()
    local oldMe = me and ((Guild.Short(me):match("^(%S+)") or "") .. "-" .. MyRealm())
    local merged = {}
    for key, r in pairs(g.recruits) do
        local canon = FullName(key) or key
        if r.by == oldMe then r.by = me end
        r.name = Guild.Short(canon)
        local into = merged[canon]
        if not into then
            merged[canon] = r
        else
            local keep, other = into, r
            local rk, ok = STATUS_RANK[r.status] or 0, STATUS_RANK[into.status] or 0
            if rk > ok or (rk == ok and (r.t or 0) > (into.t or 0)) then keep, other = r, into end
            keep.invites = (keep.invites or 0) + (other.invites or 0)
            keep.first = math.min(keep.first or keep.t or 0, other.first or other.t or 0)
            keep.invited = math.max(keep.invited or 0, other.invited or 0)
            keep.replied = keep.replied or other.replied
            keep.unread = ((keep.unread or 0) + (other.unread or 0) > 0) and ((keep.unread or 0) + (other.unread or 0)) or nil
            ns.Data.Bump("guild.replies")
            for _, f in ipairs({ "classFile", "level", "race", "zone", "whisper", "src" }) do
                if keep[f] == nil then keep[f] = other[f] end
            end
            if other.chat then
                keep.chat = keep.chat or {}
                for _, line in ipairs(other.chat) do keep.chat[#keep.chat + 1] = line end
                table.sort(keep.chat, function(x, y) return (x.t or 0) < (y.t or 0) end)
            end
            merged[canon] = keep
        end
    end
    g.recruits = merged
    g.namesV = 2
end

---------------------------------------------------------------------------
-- Whisper messages
---------------------------------------------------------------------------
function Guild.Messages()
    local d = db()
    if type(d.guildMessages) ~= "table" then
        d.guildMessages = {}
        for i, m in ipairs(Guild.DEFAULT_MESSAGES) do d.guildMessages[i] = m end
    end
    return d.guildMessages
end

function Guild.MessageIndex()
    local list = Guild.Messages()
    local i = tonumber(db().guildMessageIndex) or 1
    if i > #list then i = #list end
    if i < 1 then i = 1 end
    return i, #list
end

function Guild.CurrentMessage()
    local list = Guild.Messages()
    return list[Guild.MessageIndex()]
end

-- {name} {first} {guild} {class} {level} {zone} {me}; unknown ones become
-- empty. {first} is the first word of a first + last name.
function Guild.FormatMessage(text, who)
    if type(text) ~= "string" then return "" end
    who = who or {}
    local values = {
        name = who.name or (who.full and Guild.Short(who.full)) or "",
        first = ((who.name or (who.full and Guild.Short(who.full)) or ""):match("^(%S+)")) or "",
        guild = Guild.Mine() or "",
        class = who.classFile and ns.ClassName(who.classFile) or "",
        level = who.level and tostring(who.level) or "",
        zone = who.zone or (GetZoneText and S.Call(GetZoneText)) or "",
        me = Guild.Short(Guild.Me() or "") or "",
    }
    local out = text:gsub("{(%a+)}", function(key)
        local v = values[key:lower()]
        if v == nil then return "{" .. key .. "}" end
        return v
    end)
    out = out:gsub("  +", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #out > MAX_WHISPER then out = out:sub(1, MAX_WHISPER) end
    return out
end

---------------------------------------------------------------------------
-- Recruits: candidates near you and from /who
---------------------------------------------------------------------------
local function Recruit(full, create, from)
    local g = Guild.Data()
    if not g then return nil end
    local r = g.recruits[full]
    if not r and create then
        r = {}
        g.recruits[full] = r
    end
    if r and from then
        r.name = from.name or r.name or Guild.Short(full)
        r.classFile = from.classFile or r.classFile
        r.level = from.level or r.level
        r.race = from.race or r.race
        r.zone = from.zone or r.zone
        r.src = from.src or r.src
    end
    return r
end
Guild.Recruit = Recruit

local function MemberOfMine(full)
    local g = Guild.Data()
    return g ~= nil and g.members[full] ~= nil
end

local function ReadUnit(unit, src, now)
    local f = ns.ReadPlayerFacts(unit)
    if not f or not f.name then return end
    local mine = S.Call(UnitFactionGroup, "player")
    local theirs = S.Call(UnitFactionGroup, unit)
    if type(mine) ~= "string" or mine == "" or theirs ~= mine then return end
    local full = FullName(f.name, f.realm)  -- Forever: f.realm is the surname
    local c = candidates[full]
    local guild, secret = S.Call(GetGuildInfo, unit)
    if secret then
        if c then c.nilSince, c.nilReads, c.confirmed = nil, 0, false end
        return
    end
    if type(guild) == "string" and guild ~= "" then
        candidates[full] = nil
        return
    end
    if not c then
        c = { full = full, first = now, nilReads = 0 }
        candidates[full] = c
    end
    c.name, c.classFile, c.level, c.race = f.name, f.classFile or c.classFile, f.level or c.level, f.race or c.race
    c.zone = (GetZoneText and S.Call(GetZoneText)) or c.zone
    c.src, c.last, c.unit = src, now, unit
    if not c.confirmed then
        if not c.nilSince then
            c.nilSince, c.nilReads = now, 1
        elseif now - c.nilSince >= CONFIRM_SECONDS then
            c.nilReads = c.nilReads + 1
            c.confirmed = c.nilReads >= 2
        end
    end
end

-- A pass over nameplates, target and mouseover. The tick reads at most
-- PASS_READS of them per tick: 40 plates read in one frame every second was
-- a hitch in cities (Census reads the same plates; both share the tick's reads).
local PASS_UNITS, PASS_SOURCES = {}, {}
for i = 1, 40 do PASS_UNITS[i], PASS_SOURCES[i] = "nameplate" .. i, "plate" end
PASS_UNITS[41], PASS_SOURCES[41] = "target", "target"
PASS_UNITS[42], PASS_SOURCES[42] = "mouseover", "mouseover"
local PASS_READS = 12
local passAt = #PASS_UNITS   -- the last unit read; the pass is done at #PASS_UNITS

-- Reads up to `budget` units that exist (all when nil); true when the pass is done.
local function StepPass(now, budget)
    local reads = 0
    while passAt < #PASS_UNITS and not (budget and reads >= budget) do
        passAt = passAt + 1
        local unit = PASS_UNITS[passAt]
        if S.Call(UnitExists, unit) then
            reads = reads + 1
            ReadUnit(unit, PASS_SOURCES[passAt], now)
        end
    end
    if passAt < #PASS_UNITS then return false end
    for full, c in pairs(candidates) do
        if now - c.last > CANDIDATE_TTL then candidates[full] = nil end
    end
    return true
end

-- One whole pass at once (tests, commands).
function Guild.Scan(now)
    if not db().guildRecruitScan or not Guild.Mine() then return end
    passAt = 0
    StepPass(now, nil)
end

-- Why a player is not offered again, or nil when they can be invited.
local BLOCKING = { inviting = true, invited = true, declined = true, guilded = true, pending = true, notfound = true }
-- g: the guild's data when the caller has it (Candidates: one read, not two per player).
function Guild.Blocked(full, g)
    g = g or Guild.Data()
    if not g then return nil end
    if g.members[full] then return "member" end
    local r = g.recruits[full]
    if not r then return nil end
    if r.status == "skipped" or r.status == "joined" then return r.status end
    if BLOCKING[r.status] and r.t and time() - r.t < (db().guildReinviteDays or 7) * 86400 then return r.status end
    return nil
end

-- All nine, whatever your faction: Forever has Alliance shamans and Horde
-- paladins, and a class without a filter chip could never be hidden.
local CLASSES = { "WARRIOR", "PALADIN", "SHAMAN", "HUNTER", "ROGUE", "PRIEST", "MAGE", "WARLOCK", "DRUID" }
function Guild.Classes()
    return CLASSES
end

-- A hidden class drops its players; a player whose class is unknown only
-- shows while no class is hidden.
function Guild.ClassOK(classFile)
    local hidden = db().guildRecruitHideClass or {}
    if classFile then return not hidden[classFile] end
    return next(hidden) == nil
end

-- Writing systems of player names. Connected realms from several regions
-- bring names in other alphabets; a guild that talks in one language can hide
-- them. Latin includes accented letters (é, ö, ß, ñ, ...). Names are UTF-8.
Guild.SCRIPTS = {
    { id = "latin", short = "Latin", label = "Latin (with accents like é, ö, ß, ñ)" },
    { id = "cyrillic", short = "Cyrillic", label = "Cyrillic (Russian, Ukrainian, ...)" },
    { id = "greek", short = "Greek", label = "Greek" },
    { id = "han", short = "Chinese", label = "Chinese characters (Hanzi / Kanji)" },
    { id = "kana", short = "Japanese", label = "Japanese kana" },
    { id = "hangul", short = "Korean", label = "Korean (Hangul)" },
    { id = "thai", short = "Thai", label = "Thai" },
    { id = "arabic", short = "Arabic", label = "Arabic" },
    { id = "hebrew", short = "Hebrew", label = "Hebrew" },
    { id = "other", short = "Other", label = "Other alphabets and symbols" },
}
-- { first, last code point, script }; anything not Latin and not listed is "other".
local SCRIPT_RANGES = {
    { 0x00C0, 0x02AF, "latin" }, { 0x1E00, 0x1EFF, "latin" }, { 0xFF21, 0xFF5A, "latin" },
    { 0x0370, 0x03FF, "greek" }, { 0x1F00, 0x1FFF, "greek" },
    { 0x0400, 0x052F, "cyrillic" }, { 0x1C80, 0x1C8F, "cyrillic" }, { 0x2DE0, 0x2DFF, "cyrillic" }, { 0xA640, 0xA69F, "cyrillic" },
    { 0x0590, 0x05FF, "hebrew" }, { 0xFB1D, 0xFB4F, "hebrew" },
    { 0x0600, 0x06FF, "arabic" }, { 0x0750, 0x077F, "arabic" }, { 0x08A0, 0x08FF, "arabic" },
    { 0xFB50, 0xFDFF, "arabic" }, { 0xFE70, 0xFEFF, "arabic" },
    { 0x0E00, 0x0E7F, "thai" },
    { 0x1100, 0x11FF, "hangul" }, { 0x3130, 0x318F, "hangul" }, { 0xA960, 0xA97F, "hangul" },
    { 0xAC00, 0xD7FF, "hangul" }, { 0xFFA0, 0xFFDC, "hangul" },
    { 0x3040, 0x30FF, "kana" }, { 0x31F0, 0x31FF, "kana" }, { 0xFF66, 0xFF9F, "kana" },
    { 0x3400, 0x4DBF, "han" }, { 0x4E00, 0x9FFF, "han" }, { 0xF900, 0xFAFF, "han" }, { 0x20000, 0x3FFFF, "han" },
}
local function ScriptOf(cp)
    for _, r in ipairs(SCRIPT_RANGES) do
        if cp >= r[1] and cp <= r[2] then return r[3] end
    end
    return "other"
end

local scriptCache = {}
-- The scripts of the letters in a name: a set { latin = true, cyrillic = true, ... }.
-- Spaces, hyphens and digits belong to none. Bytes that are not valid UTF-8 count as "other".
function Guild.NameScripts(name)
    if type(name) ~= "string" then return {} end
    local hit = scriptCache[name]
    if hit then return hit end
    local out, i, n = {}, 1, #name
    while i <= n do
        local b = name:byte(i)
        local cp, len
        if b < 0x80 then cp, len = b, 1
        elseif b >= 0xF0 and b < 0xF8 then cp, len = b - 0xF0, 4
        elseif b >= 0xE0 then cp, len = b - 0xE0, 3
        elseif b >= 0xC0 then cp, len = b - 0xC0, 2
        end
        if cp and i + len - 1 <= n then
            for k = i + 1, i + len - 1 do
                local c = name:byte(k)
                if c < 0x80 or c >= 0xC0 then cp = nil break end
                cp = cp * 64 + (c - 0x80)
            end
        else
            cp = nil
        end
        if not cp then
            out.other = true
            i = i + 1
        else
            if cp >= 0x80 then
                out[ScriptOf(cp)] = true
            elseif (cp >= 65 and cp <= 90) or (cp >= 97 and cp <= 122) then
                out.latin = true
            end
            i = i + len
        end
    end
    scriptCache[name] = out
    return out
end

-- True when the name (realm left out) uses a script hidden in the settings.
function Guild.ScriptHidden(full, hidden)
    hidden = hidden or db().guildRecruitHideScript
    if type(hidden) ~= "table" or next(hidden) == nil then return false end
    for s in pairs(Guild.NameScripts((Guild.Split(full)))) do
        if hidden[s] then return true end
    end
    return false
end

-- Candidates to show: players not messaged yet (here first, then most
-- recently seen), then delayed invites ready for their click (ready = true;
-- off the list from the first click until then), below the new names so a
-- returning row never moves under the cursor while you whisper the next ones.
-- Runs on every redraw (each recruit click): the guild data, level range and
-- class filter are read once, not per player (each read is several game calls).
function Guild.Candidates()
    local out = {}
    local now = GetTime()
    local g = Guild.Data()
    local lo, hi = Guild.LevelRange()
    local hidden = db().guildRecruitHideClass or {}
    local anyHidden = next(hidden) ~= nil
    local scripts = db().guildRecruitHideScript
    local byScript = 0
    for full, c in pairs(candidates) do
        local level, classFile = c.level, c.classFile
        if c.confirmed and (type(level) ~= "number" or (level >= lo and level <= hi))
            and (classFile and not hidden[classFile] or (not classFile and not anyHidden))
            and not Guild.Blocked(full, g) then
            if Guild.ScriptHidden(full, scripts) then
                byScript = byScript + 1
            else
                c.here = c.src ~= "who" and now - c.last <= LIVE_SECONDS
                out[#out + 1] = c
            end
        end
    end
    Guild.scriptHidden = byScript   -- shown on the Recruit tab's alphabet card
    if g then
        for full, w in pairs(waiting) do
            local r = g.recruits[full]
            if not r or r.status ~= "inviting" or g.members[full] then
                waiting[full] = nil
            elseif now >= w.at then
                local c = candidates[full]
                out[#out + 1] = { full = full, name = r.name or Guild.Short(full), classFile = r.classFile, level = r.level,
                    race = r.race, zone = r.zone, src = c and c.src or r.src or "?", last = c and c.last or now,
                    here = c ~= nil and c.src ~= "who" and now - c.last <= LIVE_SECONDS, ready = true,
                    why = w.why, since = w.since, at = w.at }
            end
        end
    end
    table.sort(out, function(a, b)
        if (a.ready == true) ~= (b.ready == true) then return b.ready == true end
        -- The invite queue: oldest first, the order the next invite takes.
        if a.ready and a.at ~= b.at then return a.at < b.at end
        if a.here ~= b.here then return a.here end
        if a.last ~= b.last then return a.last > b.last end
        return a.full < b.full
    end)
    return out
end

function Guild.Candidate(full) return candidates[full] end

-- After a guild action (invite, status, forget, /who): the cached lists are
-- rebuilt and only the guild windows redraw. ns.Refresh would redraw every
-- module and the settings page, a visible hitch on each recruit click.
function Guild.Changed()
    ns.Data.Bump("guild")
    local UI = ns.GuildUI
    if not UI then return end
    if UI.IsShown() then
        UI.Refresh()
    else
        UI.UpdateNotice()
        UI.RefreshMini()
    end
end

local AddLine   -- defined with the conversations below
-- Replies sent this session whose echo has not come yet: [full] = { { text,
-- t (GetTime), lost } }. Not saved: after a reload the echo would never match.
local outgoing = {}
local OUTGOING_WAIT = 60       -- a reply with no echo by then leaves the list (GetTime)
local LOST_SHOWN = 300         -- a dropped reply stays marked this long (GetTime)
---------------------------------------------------------------------------
-- Inviting (one click = one whisper + one invite to one player)
---------------------------------------------------------------------------
local Outbox = ns.Outbox
local queueNoticed = -math.huge  -- last "whispers held back" notice (GetTime)
local OpenerWanted, OpenerSent

-- An opener the game's throttle dropped (Outbox guesses which): the recruit
-- gets "no message" back, to send later with a click.
local function OpenerLost(full)
    return function(e)
        local r = Recruit(full)
        if r and r.whisper == e.text then
            Thaw(r)     -- its chat list is changed in place
            for i = #(r.chat or {}), 1, -1 do
                local line = r.chat[i]
                if line.me and line.text == e.text then table.remove(r.chat, i) break end
            end
            r.whisper, r.echo, r.echoT, r.unsent = nil, nil, nil, e.text
        end
        return true
    end
end

-- A queued opener still goes unless the recruit was forgotten or skipped,
-- sent it by hand meanwhile, or the invite did not land (declined, in a
-- guild, not found).
local OPENER_DROP = { declined = true, guilded = true, notfound = true, skipped = true }
OpenerWanted = function(full, text)
    local r = Recruit(full)
    return r ~= nil and r.unsent == text and not OPENER_DROP[r.status]
end

local inInvite = false   -- Guild.Invite redraws once itself

OpenerSent = function(full, text)
    local r = Recruit(full)
    if not r then return end
    r.whisper, r.unsent = text, nil
    -- Kept now, not from the game's echo (its name form may differ); the
    -- echo of this one line is skipped once when it comes.
    local now = time()
    AddLine(r, text, true, now)
    r.echo, r.echoT = text, now
    lastSend = GetTime()
    if not inInvite then Guild.Changed() end
end

-- The invite went out: the recruit counts as invited from now. The call
-- returning is not delivery: ack = false until the game says "You have
-- invited X" (Guild.InviteCheck).
local function InviteSent(full)
    local r = Recruit(full)
    if not r then return end
    local now = time()
    r.invited, r.t, r.status, r.ack = now, now, "invited", false
    r.invites = (r.invites or 0) + 1
    lastSend = GetTime()
    if not inInvite then Guild.Changed() end
end

local function InviteFailed(full)
    local r = Recruit(full)
    if r and r.status == "inviting" then r.status, r.t = "uninvited", time() end
    ns.Print("the game did not accept the invite for " .. Target(full) .. ".")
    if not inInvite then Guild.Changed() end
end

-- The invite queue: waiting[full] = { at, why, since } for every invite
-- still to send after its opener went out. Ready at `at` (oldest first);
-- `why` says how it got there, for the row's tooltip:
--   "delay"     delayed invite: INVITE_DELAY after the opener, to read it
--   "inclick"   the invite did not go in the click that sent the opener
--   "failed"    the game did not accept the invite call
--   "blocked"   the game blocked it (a Hands Free click it does not count)
--   "nowhisper" the opener could not go, so the invite need not wait for it
--   "reload"    left from before a reload (the invite never went)
-- The game takes a guild invite only inside a click or key press, so a
-- queued invite never goes on its own: each accepted input sends one.
local inviteWhy = {}   -- [full] = why, for an invite that waits for its queued opener (session only)

local function MarkReady(full, delay, why)
    local r = Recruit(full)
    if not r or r.status ~= "inviting" then return end
    waiting[full] = { at = GetTime() + (delay or 0), why = why or inviteWhy[full] or "delay", since = GetTime() }
    inviteWhy[full] = nil
end

-- The invite did not go in this click: it waits in the queue, ready once
-- the opener is out (at once when it already is or there is none).
local function InviteLater(full, why)
    local r = Recruit(full)
    if not r then return end
    r.status, r.t = "inviting", time()
    local w = waiting[full]
    if w then
        w.why, w.since = why, GetTime()
    elseif type(r.unsent) == "string" and Outbox.IsQueued(Target(full), r.unsent) then
        inviteWhy[full] = why
    else
        MarkReady(full, 0, why)
    end
end

-- Why this player's invite waits: why, seconds since, seconds until ready
-- (nil when no invite waits). "message" = its opener is still queued.
function Guild.InviteWhy(full)
    local w = waiting[full]
    if w then return w.why, GetTime() - (w.since or GetTime()), math.max(0, w.at - GetTime()) end
    if inviteWhy[full] then return "message", 0, nil end
end

-- The second click may send the invite.
function Guild.InviteReady(full)
    local r, w = Recruit(full), waiting[full]
    return r ~= nil and r.status == "inviting" and w ~= nil and GetTime() >= w.at
end

local function QueueOpener(full, target, text, delayed)
    return Outbox.Whisper(text, target, {
        queue = true, label = Guild.Short(full), onLost = OpenerLost(full),
        still = function() return OpenerWanted(full, text) end,
        -- The invite waits for this (delayed invite, or the same-click invite
        -- did not go); MarkReady does nothing once it went.
        onSent = function()
            OpenerSent(full, text)
            MarkReady(full, delayed and INVITE_DELAY or 0)
        end,
        -- The game refused the whisper: the invite need not wait for it.
        onDropped = function(why)
            if why == "failed" then MarkReady(full, 0, "nowhisper") end
        end,
    })
end

-- The opener is waiting in the Outbox queue (not "no message" yet).
function Guild.OpenerQueued(full)
    local r = Recruit(full)
    return r ~= nil and type(r.unsent) == "string" and Outbox.IsQueued(Target(full), r.unsent)
end

-- Delayed invite: seconds until this recruit can be invited (0 = now; nil
-- when no invite waits or its opener is still queued).
function Guild.InviteIn(full)
    local r, w = Recruit(full), waiting[full]
    if not r or r.status ~= "inviting" or not w then return nil end
    return math.max(0, w.at - GetTime())
end

-- Delayed invites ready for their click.
function Guild.InvitesReady()
    local n = 0
    for full in pairs(waiting) do
        if Guild.InviteReady(full) then n = n + 1 end
    end
    return n
end

-- Did the game confirm the last invite? "confirmed" (it said "You have
-- invited X"), "waiting" (sent less than ACK_WAIT ago), "unconfirmed" (no
-- such line: it may not have reached them), or nil (no invite out, an answer
-- came, sent before this check existed, or this client never shows the line).
function Guild.InviteCheck(r)
    if not r or r.status ~= "invited" or r.ack == nil then return nil end
    if r.ack then return "confirmed" end
    if not db().guildAckSeen then return nil end
    if time() - (r.invited or 0) < ACK_WAIT then return "waiting" end
    return "unconfirmed"
end

-- Your invites since `since` (time()), counted: sent, confirmed, waiting,
-- unconfirmed (names), answered (declined / in a guild / elsewhere / offline),
-- joined; plus what is still queued and the unmatched system lines.
function Guild.Check(since)
    since = since or (time() - 3600)
    local me = MyCharName()
    local out = { sent = 0, confirmed = 0, waiting = 0, unconfirmed = {}, answered = 0, joined = 0, open = 0,
        inviting = 0, ackSeen = db().guildAckSeen == true, unmatched = unmatched,
        queued = Outbox.Pending(), invitesReady = Guild.InvitesReady() }
    for _, x in ipairs(Guild.Recruits()) do
        local r = x.r
        if r.invited and r.invited >= since and (r.by == nil or r.by == me) then
            if r.status == "inviting" then
                out.inviting = out.inviting + 1
            elseif r.status ~= "uninvited" and r.status ~= "skipped" then
                out.sent = out.sent + 1
                local check = Guild.InviteCheck(r)
                if r.ack then out.confirmed = out.confirmed + 1 end
                if check == "waiting" then out.waiting = out.waiting + 1 end
                if check == "unconfirmed" then out.unconfirmed[#out.unconfirmed + 1] = x.full end
                if ANSWERS[r.status] then out.answered = out.answered + 1 end
                if r.status == "joined" then out.joined = out.joined + 1 end
                if r.status == "invited" then out.open = out.open + 1 end
            end
        end
    end
    return out
end

local function PrintCheck()
    local c = Guild.Check()
    ns.Print(string.format("invites in the last hour: %d sent, %d confirmed by the game, %d answered (declined / offline / in a guild), %d joined, %d still open.",
        c.sent, c.confirmed, c.answered, c.joined, c.open))
    if c.inviting > 0 or c.queued > 0 or c.invitesReady > 0 then
        ns.Print(string.format("on the way: %d messages waiting, %d invites ready for your click.", c.queued, c.invitesReady))
    end
    if not c.ackSeen then
        ns.Print("the game has not shown " .. ns.NAME .. " a \"You have invited ...\" line yet, so delivery cannot be checked on this client.")
    elseif #c.unconfirmed > 0 then
        local names = {}
        for i, full in ipairs(c.unconfirmed) do
            if i > 10 then names[#names + 1] = "+" .. (#c.unconfirmed - 10) .. " more" break end
            names[#names + 1] = Guild.Short(full)
        end
        ns.Print(string.format("%d invites the game never confirmed (may not have reached them; click their row in Invited to invite again): %s",
            #c.unconfirmed, table.concat(names, ", ")))
    elseif c.sent > 0 then
        ns.Print("every invite the game could confirm was confirmed.")
    end
    if #c.unmatched > 0 then
        ns.Print("game lines right after a send that " .. ns.NAME .. " did not recognize (please report them):")
        for _, e in ipairs(c.unmatched) do ns.Print("  " .. date("%H:%M:%S", e.t) .. "  " .. e.text) end
    end
end

-- The guild invite, in the caller's click (the game blocks it anywhere else).
-- later: when the game does not take it, it waits in the invite queue
-- instead of the player counting as not invited. Returns sent, why.
local function InviteNow(full, target, info, later)
    local invited, why = Outbox.GuildInvite(target)
    if not invited then
        -- A double click while the client lags: the first one went.
        if why == "repeat" then return false, why end
        if later then InviteLater(full, "failed") else InviteFailed(full) end
        return false, why
    end
    local r = Recruit(full, true, info)
    r.by = MyCharName()
    r.first = r.first or time()
    waiting[full] = nil
    inInvite = true
    InviteSent(full)
    inInvite = false
    Guild.Changed()
    return true
end

-- Called only from a click on a recruit row or a typed command, never from
-- a timer or an event. With delayed invite on (guildDelayedInvite): the
-- first click sends the opener (or queues it behind
-- the others when the game's pace is full) and takes the player off the
-- list; INVITE_DELAY after it went out they are back, marked, and the second
-- click sends the invite. Off: the opener and the invite in one click.
-- Without an opener the invite goes at once. Returns true when the invite
-- went out or the opener is on its way.
-- noWhisper: invite only (the Replies tab: you are already talking).
function Guild.Invite(full, info, noWhisper)
    if type(full) ~= "string" then return false end
    if not Guild.Mine() then
        ns.Print("you are not in a guild.")
        return false
    end
    if not Guild.Can("invite") then
        ns.Print("your guild rank cannot invite players.")
        return false
    end
    if MemberOfMine(full) then
        ns.Print(Guild.Short(full) .. " is already in your guild.")
        return false
    end
    info = info or candidates[full]
    local old = Recruit(full)
    local target = Target(full)
    -- The second click of a delayed invite: the invite alone, once its time came.
    if old and old.status == "inviting" then
        if not Guild.InviteReady(full) then return false end
        return InviteNow(full, target, info)
    end
    if old and old.invited and old.status ~= "uninvited" and time() - old.invited < INVITE_GUARD then return false end
    -- The invite that followed the opener did not go: invite only.
    if old and old.status == "uninvited" and old.whisper and not old.unsent then noWhisper = true end
    local wantWhisper = db().guildWhisper and not noWhisper
    local text = wantWhisper and Guild.FormatMessage(Guild.CurrentMessage(), info or old or { full = full }) or ""
    local now = time()
    if text == "" then
        local sent = InviteNow(full, target, info)
        if sent then
            local r = Recruit(full)
            r.whisper, r.unsent = nil, nil
        end
        return sent
    end
    local delayed = db().guildDelayedInvite ~= false
    local r = Recruit(full, true, info)
    -- "inviting": the opener is out or queued, the invite still to send.
    -- invited is set now so their reply is kept; it moves to the invite's time.
    r.invited, r.t, r.status = now, now, "inviting"
    r.whisper, r.unsent = nil, text
    r.by = MyCharName()
    r.first = r.first or now
    inInvite = true
    local ok, how = QueueOpener(full, target, text, delayed)
    inInvite = false
    if ok and how == "queued" and GetTime() - queueNoticed > 30 then
        queueNoticed = GetTime()
        ns.Print(string.format("your messages are queued (%d waiting, the game sends about one a second); ", Outbox.Pending())
            .. (delayed and string.format("each player is back on the list to invite %d s after their message.", INVITE_DELAY)
                or "the invites went already, the messages follow."))
    elseif not ok and how == "repeat" and not Outbox.IsQueued(target, text) then
        -- The same opener went out seconds ago.
        r.whisper, r.unsent = text, nil
    end
    if not delayed then
        -- Delayed invite off: the invite tries this same click. When the
        -- game does not take it, it waits in the queue and is ready once the
        -- opener is out; the next accepted click or key sends it.
        local sent, why = InviteNow(full, target, info, true)
        if not sent and why == "repeat" then
            -- The same invite went seconds ago (a double click): it counts.
            inInvite = true
            InviteSent(full)
            inInvite = false
            sent = true
        end
        if not sent and r.status == "inviting" and not waiting[full] and not inviteWhy[full] then InviteLater(full, "inclick") end
        Guild.Changed()
        return true
    end
    if not ok and not Outbox.IsQueued(target, text) then MarkReady(full, how == "repeat" and INVITE_DELAY or 0) end
    Guild.Changed()
    return true
end

-- Called only from a click on a "no message" / "message queued" row in the
-- Invited tab: the opener that was dropped or still waits, one whisper now.
-- Returns ok, why ("held", "repeat", "none").
function Guild.SendOpener(full)
    local r = Recruit(full)
    if not r or type(r.unsent) ~= "string" then return false, "none" end
    local text = r.unsent
    local target = Target(full)
    if Outbox.Hold() > 0 then return false, "held" end
    -- Still in the queue: this click sends it now instead.
    Outbox.Unqueue(target, text)
    local ok, why = Outbox.Whisper(text, target, { label = Guild.Short(full), onLost = OpenerLost(full) })
    if not ok then return false, why end
    local now = time()
    r.whisper, r.unsent = text, nil
    AddLine(r, text, true, now)
    r.echo, r.echoT = text, now
    -- Delayed invite: they are back to click INVITE_DELAY after this one.
    if r.status == "inviting" then MarkReady(full, INVITE_DELAY) end
    Guild.Changed()
    return true
end

-- While the game's throttle holds, invites still go; their openers wait.
Outbox.OnHold(function()
    queueNoticed = GetTime()
    if Guild.Mine() then
        return "Your messages wait and go after the pause" .. (db().guildDelayedInvite ~= false
            and string.format("; each player is back on the list to invite %d s after their message.", INVITE_DELAY)
            or "; the invites go with your clicks.")
    end
end)

-- Right-click on a candidate: never offer them again (until forgotten).
function Guild.Skip(full)
    local r = Recruit(full, true, candidates[full])
    if not r then return end
    r.status, r.t = "skipped", time()
    Guild.Changed()
end

-- The Replies tab's "Said no": they turned you down in a whisper. Never
-- offered again (like a skip): a delayed invite waiting for its click and a
-- queued opener are dropped. on = false takes it back to the status before
-- ("inviting" becomes "not invited": its wait is gone, a click invites).
function Guild.SaidNo(full, on)
    local r = Recruit(full)
    if not r then return false end
    if on == false then
        if not r.saidNo then return false end
        local before = r.noFrom
        r.status = (before == nil or before == "inviting") and "uninvited" or before
        r.t, r.saidNo, r.noFrom = time(), nil, nil
    elseif not r.saidNo then
        r.noFrom = r.status
        r.status, r.t, r.saidNo = "skipped", time(), time()
        waiting[full] = nil
    end
    Guild.Changed()
    return true
end

-- Drops a recruit record, so the player can show up as a candidate again.
function Guild.Forget(full)
    local g = Guild.Data()
    if g then g.recruits[full] = nil end
    ns.Data.Bump("guild.replies")
    Guild.Changed()
end

-- Every recruit record, newest first. A long recruiting run keeps thousands
-- (every player ever invited, so they are not offered again), and sorting
-- them all is one step the background work cannot pause in. Kept until the
-- guild data changes, then put in order starting from the last order: a
-- click moves one record, which is one pass instead of a full sort. The last
-- order is only a starting point; the result is always fully sorted.
-- Callers must not change it.
local RECRUITS_MAX_AGE = 10     -- seconds; writes that skip Guild.Changed show by then
local FULL_SORT_OVER = 8        -- records out of place before a plain sort is cheaper
local lastOrder = {}
local function NewerFirst(a, b) return (a.r.t or 0) > (b.r.t or 0) end

-- Newest first, ties in their earlier order. Sorted as fixed-width text so
-- the sort runs without a Lua call per comparison (thousands of records
-- after login were one long step).
local function SortNewest(out)
    local keys, byKey = {}, {}
    for i, x in ipairs(out) do
        Step(i)
        local k = string.format("%012.0f%07d", 1e11 - (tonumber(x.r.t) or 0), i)
        keys[i], byKey[k] = k, x
    end
    table.sort(keys)
    for i, k in ipairs(keys) do out[i] = byKey[k] end
end

local function BuildRecruits(g)
    local out, moved, total = {}, 0, 0
    for _ in pairs(g.recruits) do total = total + 1 end
    for i, x in ipairs(lastOrder) do
        Step(i)
        local r = g.recruits[x.full]
        if r then out[#out + 1] = r == x.r and x or { full = x.full, r = r } end
    end
    -- New records (names are unique keys: a count short of the total).
    if #out < total then
        local seen = {}
        for _, x in ipairs(out) do seen[x.full] = true end
        for full, r in pairs(g.recruits) do
            if not seen[full] then
                out[#out + 1] = { full = full, r = r }
                moved = moved + 1
            end
        end
    end
    for i = 2, #out do
        if NewerFirst(out[i], out[i - 1]) then moved = moved + 1 end
    end
    if moved > FULL_SORT_OVER then
        SortNewest(out)
    elseif moved > 0 then
        -- Insertion sort: linear on a list that is nearly in order.
        for i = 2, #out do
            local x = out[i]
            local j = i - 1
            while j >= 1 and NewerFirst(x, out[j]) do
                out[j + 1] = out[j]
                j = j - 1
            end
            out[j + 1] = x
        end
    end
    lastOrder = out
    return out
end

function Guild.Recruits()
    local g = Guild.Data()
    if not g then return {} end
    return ns.Data.Memo("guild:recruits", ns.Data.Key("guild") .. "|" .. tostring(g), function()
        return BuildRecruits(g)
    end, RECRUITS_MAX_AGE)
end

---------------------------------------------------------------------------
-- /who (one search per click)
---------------------------------------------------------------------------
local function WhoAPI()
    local F = C_FriendList
    if type(F) == "table" and type(F.SendWho) == "function" then return F.SendWho, F.GetNumWhoResults, F.GetWhoInfo end
    if type(SendWho) == "function" then return SendWho, GetNumWhoResults, GetWhoInfo end
end

-- The highest level a character can reach on this client, from the game
-- (the WoW Forever beta stops at 30, Classic Era at 60).
function Guild.MaxLevel()
    local fn = GetMaxPlayerLevel or GetMaxLevelForPlayerExpansion
    local n = type(fn) == "function" and S.Call(fn) or nil
    return (type(n) == "number" and n > 0) and n or 60
end

-- Your recruit level filter, capped at the game's top level.
function Guild.LevelRange()
    local cap = Guild.MaxLevel()
    local lo = math.max(1, math.min(db().guildRecruitMinLevel or 1, cap))
    local hi = math.max(lo, math.min(db().guildRecruitMaxLevel or cap, cap))
    return lo, hi, cap
end

-- /who answers stop at about 50 players. A click searches the whole level
-- range; only when that answer is full do the next clicks search smaller
-- ranges (a full small range is split again), then it goes back to the
-- whole range. whoPlan lives for the session.
local whoPlan
local WHO_FULL = 49
local WHO_COOLDOWN = 5       -- the game refuses a /who sooner than ~3 s after the last one; 2 s of margin
local lastWho = -math.huge

local function SplitRange(lo, hi)
    local span = hi - lo + 1
    if span < 2 then return {} end
    local parts = math.max(2, math.ceil(span / 10))
    local size = math.ceil(span / parts)
    local out = {}
    for from = lo, hi, size do out[#out + 1] = { from, math.min(hi, from + size - 1) } end
    return out
end

local function WhoZone()
    local zone = db().guildWhoZone and GetZoneText and S.Call(GetZoneText)
    return (type(zone) == "string" and zone ~= "") and zone or nil
end

-- Seconds until the next /who may go out (0: now).
function Guild.WhoWait()
    return math.max(0, WHO_COOLDOWN - (GetTime() - lastWho))
end

-- The next search: true, its /who text, levels from and to, zone, and
-- (step, steps) while a full answer is being split.
function Guild.NextWho()
    local lo, hi = Guild.LevelRange()
    local zone = WhoZone()
    local key = lo .. ":" .. hi .. ":" .. tostring(zone)
    local from, to, step, steps = lo, hi, nil, nil
    if whoPlan and whoPlan.key == key and whoPlan.list[whoPlan.i] then
        from, to = whoPlan.list[whoPlan.i][1], whoPlan.list[whoPlan.i][2]
        step, steps = whoPlan.i, #whoPlan.list
    end
    local text = from .. "-" .. to
    if zone then text = 'z-"' .. zone .. '" ' .. text end
    return true, text, from, to, zone, step, steps
end

-- Called only from a click or a typed command (the game also requires a
-- key press or click for /who).
function Guild.Who()
    local send = WhoAPI()
    if not send then
        ns.Print("/who is not available to addons on this client.")
        return false
    end
    if not Guild.Mine() then
        ns.Print("you are not in a guild.")
        return false
    end
    if Guild.WhoWait() > 0 then return false end
    local _, text, from, to, zone, step = Guild.NextWho()
    if not pcall(send, text) then
        ns.Print("the game did not accept the /who search.")
        return false
    end
    lastWho = GetTime()
    local lo, hi = Guild.LevelRange()
    whoPending = { t = GetTime(), text = text, from = from, to = to, split = step ~= nil,
        key = lo .. ":" .. hi .. ":" .. tostring(zone) }
    whoStatus = "searching " .. from .. "-" .. to .. (zone and (" in " .. zone) or "") .. "..."
    Guild.Changed()
    return true
end

-- One /who answer row: name, guild, level, race, classFile, zone (any may be nil).
local function WhoRow(info, i)
    local res = { pcall(info, i) }
    local t = res[1] and S.Value(res[2])
    if type(t) == "table" then
        return S.Value(t.fullName), S.Value(t.fullGuildName), S.Value(t.level), S.Value(t.raceStr), S.Value(t.filename), S.Value(t.area)
    elseif res[1] then
        -- Older global: name, guild, level, race, class, zone, classFile.
        return S.Value(res[2]), S.Value(res[3]), S.Value(res[4]), S.Value(res[5]), S.Value(res[8]), S.Value(res[7])
    end
end

-- New facts about a recruit (level, class, race, zone): true when one changed.
local function Freshen(r, f)
    local changed = false
    for _, k in ipairs({ "level", "classFile", "race", "zone" }) do
        local v = f[k]
        if v ~= nil and v ~= "" and (k ~= "level" or (type(v) == "number" and v > 0)) and r[k] ~= v then
            r[k], changed = v, true
        end
    end
    return changed
end

-- The answer to a conversation's look-up: only the one player asked for.
local function ReadLook(p)
    local _, count, info = WhoAPI()
    local n = count and S.Call(count) or 0
    local r = Recruit(p.full)
    for i = 1, n do
        local name, _, level, race, classFile, zone = WhoRow(info, i)
        if type(name) == "string" and r and (FromFull(name) == p.full or Guild.Short(FromFull(name)):lower() == Guild.Short(p.full):lower()) then
            if Freshen(r, { level = level, race = race, classFile = classFile, zone = zone }) then ns.Data.Bump("guild.replies") end
            break
        end
    end
    whoPending = nil
    Guild.Changed()
end

local function ReadWho()
    if not whoPending or GetTime() - whoPending.t > WHO_WAIT then return end
    if whoPending.look then return ReadLook(whoPending) end
    local _, count, info = WhoAPI()
    local n = count and S.Call(count) or 0
    local added, guilded = 0, 0
    local now = GetTime()
    for i = 1, n do
        local name, guild, level, race, classFile, zone = WhoRow(info, i)
        if type(name) == "string" and name ~= "" and type(guild) == "string" then
            local full = FromFull(name)
            if guild == "" then
                local cand = candidates[full] or { full = full, first = now, nilReads = 2 }
                candidates[full] = cand
                cand.name, cand.level, cand.race = Guild.Short(full), type(level) == "number" and level or cand.level, race or cand.race
                cand.classFile, cand.zone = classFile or cand.classFile, zone or cand.zone
                cand.last, cand.confirmed = now, true
                if cand.src ~= "plate" and cand.src ~= "target" and cand.src ~= "mouseover" then cand.src = "who" end
                added = added + 1
            else
                candidates[full] = nil
                guilded = guilded + 1
            end
        end
    end
    local p = whoPending
    local full = n >= WHO_FULL
    if not p.split then
        whoPlan = full and { key = p.key, list = SplitRange(p.from, p.to), i = 1 } or nil
        if whoPlan and #whoPlan.list == 0 then whoPlan = nil end
    elseif whoPlan and whoPlan.key == p.key then
        whoPlan.i = whoPlan.i + 1
        if full then
            -- Still full: its halves come next.
            for k, part in ipairs(SplitRange(p.from, p.to)) do table.insert(whoPlan.list, whoPlan.i + k - 1, part) end
        end
        if whoPlan.i > #whoPlan.list then whoPlan = nil end
    end
    local tail = ""
    if whoPlan then
        local nxt = whoPlan.list[whoPlan.i]
        tail = string.format(" - the list was full: the next clicks search smaller level ranges (next %d-%d, %d of %d)",
            nxt[1], nxt[2], whoPlan.i, #whoPlan.list)
    elseif p.split then
        tail = " - every level range searched"
    end
    whoStatus = string.format("%s: %d without a guild, %d in one%s", p.text, added, guilded, tail)
    whoPending = nil
    Guild.Changed()
end

function Guild.WhoStatus() return whoStatus end

---------------------------------------------------------------------------
-- System messages (only when readable: they add "by" and invite outcomes)
---------------------------------------------------------------------------
local function Pattern(fmt)
    if type(fmt) ~= "string" then return nil end
    local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    -- Lazy: names may have spaces ("Mira Stone has promoted Tom Reed to Veteran.").
    p = p:gsub("%%%%s", "(.-)")
    return "^" .. p .. "$"
end

-- Global name, English text when the global is missing, kind.
local SYSTEM = {
    { "ERR_GUILD_INVITE_S", "You have invited %s to join your guild.", "invite" },
    { "ERR_GUILD_DECLINE_S", "%s declines your guild invitation.", "declined" },
    { "ERR_GUILD_DECLINE_AUTO_S", nil, "declined" },
    { "ERR_ALREADY_IN_GUILD_S", "%s is already in a guild.", "guilded" },
    { "ERR_ALREADY_INVITED_TO_GUILD_S", "%s has already been invited to a guild.", "pending" },
    { "ERR_CHAT_PLAYER_NOT_FOUND_S", "No player named '%s' is currently playing.", "notfound" },
    -- The guild command's own "not found" (an invite to a name nobody online has).
    { "ERR_GUILD_PLAYER_NOT_FOUND_S", "\"%s\" not found.", "notfound" },
    -- A whisper to a player who has you on ignore (usually CHAT_MSG_IGNORED).
    { "ERR_IGNORING_YOU_S", "%s is ignoring you.", "ignoring" },
    { "CHAT_IGNORED", "%s is ignoring you.", "ignoring" },
    { "ERR_GUILD_JOIN_S", "%s has joined the guild.", "join" },
    { "ERR_GUILD_LEAVE_S", "%s has left the guild.", "leave" },
    { "ERR_GUILD_REMOVE_SS", "%s has been kicked out of the guild by %s.", "kick" },
    { "ERR_GUILD_PROMOTE_SSS", "%s has promoted %s to %s.", "promote" },
    { "ERR_GUILD_DEMOTE_SSS", "%s has demoted %s to %s.", "demote" },
}
local patterns
local function Patterns()
    if patterns then return patterns end
    patterns = {}
    for _, s in ipairs(SYSTEM) do
        local p = Pattern(_G[s[1]] or s[2])
        if p then patterns[#patterns + 1] = { p, s[3] } end
    end
    return patterns
end

-- kind, names... of a readable system line, or nil.
local function MatchSystem(text)
    text = S.Value(text)
    if type(text) ~= "string" then return nil end
    for _, p in ipairs(Patterns()) do
        local a, b, c = text:match(p[1])
        if a and a ~= "" then return p[2], a, b, c end
    end
end

-- A line that matched nothing right after an opener or invite went out:
-- kept so /talod guild check can show what this client actually says.
local function NoteUnmatched(text)
    if GetTime() - lastSend > UNMATCHED_SECONDS then return end
    local plain = S.Value(text)
    unmatched[#unmatched + 1] = { t = time(), text = type(plain) == "string" and plain or "(text hidden by the game)" }
    while #unmatched > MAX_UNMATCHED do table.remove(unmatched, 1) end
end

local function OnSystem(text)
    local kind, a, b, c = MatchSystem(text)
    if not kind then
        NoteUnmatched(text)
        return
    end
    if kind == "promote" or kind == "demote" then
        hints[FullName(b)] = { kind = kind, by = FullName(a), rank = c, t = time() }
    elseif kind == "kick" then
        hints[FullName(a)] = { kind = kind, by = FullName(b), t = time() }
    elseif kind == "join" or kind == "leave" then
        hints[FullName(a)] = { kind = kind, t = time() }
    end
    -- The roster read may have logged the change before this message came.
    local subject = (kind == "kick") and a or b
    local h = (kind == "promote" or kind == "demote" or kind == "kick") and hints[FullName(subject)]
    local g = h and Guild.Data()
    if g then
        for i = #g.log, math.max(1, #g.log - 20), -1 do
            local e = g.log[i]
            if e.n == FullName(subject) and not e.by and time() - e.t <= HINT_SECONDS
                and (e.k == kind or (kind == "kick" and e.k == "leave")) then
                e.by, e.k = h.by, kind
                break
            end
        end
    end
    -- The game may write the name in another form than the key (no realm, a
    -- realm of the group): the one invited player of that name, as the chat
    -- filter finds them (it hides these lines, so a miss here was invisible).
    local r = Recruit(FullName(a)) or (Guild.InvitedRecruit(a))
    if r then
        local now = time()
        local since = r.invited and now - r.invited
        -- "inviting" too: the opener's "No player named..." comes before the
        -- invite, which then does not go (Guild.Invite's still()).
        local open = since and (r.status == "invited" or r.status == "inviting")
        if kind == "ignoring" or kind == "notfound" then Guild.Undelivered(a, kind) end
        if kind == "join" then
            r.status, r.t = "joined", now
        elseif kind == "invite" then
            if r.status == "invited" and since < QUICK_ANSWER then
                r.ack = now
                db().guildAckSeen = true
            end
        elseif ANSWERS[kind] and open and since < (kind == "declined" and DECLINE_ANSWER or QUICK_ANSWER) then
            r.status, r.t = kind, now
        end
    end
    Guild.Changed()
end

---------------------------------------------------------------------------
-- Conversations with recruits (whispers to and from players you invited)
---------------------------------------------------------------------------
local MAX_CHAT = 60

-- The recruit record of a player you invited, from a chat name.
local function InvitedRecruit(name)
    name = S.Value(name)
    if type(name) ~= "string" or name == "" then return nil end
    local full = FromFull(name)
    local r = Recruit(full)
    if r and r.invited then return r, full end
    -- The chat name may come in another form than the one kept (realm left
    -- out or a different one): the one invited player of that name.
    local short = Guild.Short(full):lower()
    local g = Guild.Data()
    local found, foundFull
    for key, rec in pairs(g and g.recruits or {}) do
        if rec.invited and Guild.Short(key):lower() == short then
            if found then return nil end   -- two of that name: not guessed
            found, foundFull = rec, key
        end
    end
    return found, foundFull
end
Guild.InvitedRecruit = InvitedRecruit

local HIDDEN_TEXT = "(text hidden by the game, see the chat window)"

-- Adds a line to a recruit's conversation. Only the echo of the opening
-- whisper (kept when sent, its text) is skipped: the same short reply typed
-- twice is two lines. seq counts every line, so the window sees a new one
-- even when the list is full.
function AddLine(r, text, me, t)
    r.chat = r.chat or {}
    t = t or time()
    if me and r.echo then
        if t - (r.echoT or 0) > ECHO_SECONDS then
            r.echo, r.echoT = nil, nil
        elseif r.echo == text then
            return false
        end
    end
    r.chat[#r.chat + 1] = { t = t, me = me or nil, text = text, c = ns.Store.Me() }
    r.seq = (r.seq or 0) + 1
    ns.Data.Bump("guild.replies")
    return true
end

-- The chat line ID of each recruit's last whisper this session: the game's
-- report window needs one to point at the message. IDs start over after a
-- reload, so they are not saved. The GUID is saved (r.guid): without a line,
-- the report names the player.
local lastLine = {}

-- me: true for your whisper to them. A line the game hides (secret text)
-- is kept as a note, so a reply is never lost without a trace.
function Guild.AddChat(name, text, me, lineID, guid)
    local r, full = InvitedRecruit(name)
    if not r then return end
    if not me then
        lineID, guid = S.Value(lineID), S.Value(guid)
        if type(lineID) == "number" and lineID > 0 then lastLine[full] = lineID end
        if type(guid) == "string" and guid:match("^Player%-") then r.guid = guid end
    end
    text = S.Value(text)
    if type(text) ~= "string" then text = HIDDEN_TEXT end
    -- An opener counted as dropped by the throttle went out after all.
    if me and r.unsent and r.unsent == text then
        r.whisper, r.unsent = text, nil
    end
    -- The echo of a reply shown as "sending" (a hidden text is the oldest one's).
    local list = me and outgoing[full]
    if list then
        for i, e in ipairs(list) do
            if text == HIDDEN_TEXT or Guild.SameWhisper(e.text, text) then table.remove(list, i) break end
        end
        if #list == 0 then outgoing[full] = nil end
    end
    if not AddLine(r, text, me) then return end
    while #r.chat > MAX_CHAT do table.remove(r.chat, 1) end
    r.last = time()
    if me then
        -- Delivered: they no longer ignore you.
        r.ignoring = nil
    else
        r.replied = time()
        r.unread = (r.unread or 0) + 1
        r.ignoring = nil
    end
    ns.Data.Changed("guild")
    if ns.GuildUI and ns.GuildUI.OnChat then ns.GuildUI.OnChat(full, me) end
end

-- Recruits who wrote back, newest conversation first (your opening
-- whisper alone does not make a conversation). Kept until a conversation
-- changes ("guild.replies"), not rebuilt by every invite. Callers must not change it.
function Guild.Conversations()
    local g = Guild.Data()
    if not g then return {} end
    return ns.Data.Memo("guild:conversations", ns.Data.Key("guild.replies") .. "|" .. tostring(g), function()
        local out = {}
        for full, r in pairs(g.recruits) do
            local theirs = false
            -- A packed record never holds a reply (Settled): not decoded.
            if getmetatable(r) ~= PACKED then
                for _, line in ipairs(r.chat or {}) do if not line.me then theirs = true break end end
            end
            if theirs then out[#out + 1] = { full = full, r = r } end
        end
        table.sort(out, function(a, b) return (a.r.last or 0) > (b.r.last or 0) end)
        return out
    end, RECRUITS_MAX_AGE)
end

-- Where a conversation stands, for its tag and the Replies filters:
-- "blocked" (they have you on ignore; told above everything, even a
-- member), "joined", "declined" (said no, by the game's answer or as you
-- marked it), else "invited".
function Guild.ReplyGroup(r)
    if r.ignoring then return "blocked" end
    if r.status == "joined" then return "joined" end
    if r.status == "declined" or r.saidNo then return "declined" end
    return "invited"
end

-- The newest line of the conversation holding needle (plain lowercase),
-- or nil.
function Guild.ChatFind(r, needle)
    local chat = r.chat or {}
    for i = #chat, 1, -1 do
        local text = chat[i].text
        if type(text) == "string" and text:lower():find(needle, 1, true) then return chat[i] end
    end
end

-- Read on every redraw (the reply notice, the Replies tab label), and the
-- Recruit tab redraws every second: one walk over every recruit ever kept
-- when a conversation or an unread mark changes ("guild.replies", bumped
-- where chat lines and unread are written), not per redraw or per invite.
function Guild.Unread()
    local g = Guild.Data()
    if not g then return 0 end
    return ns.Data.Memo("guild:unread", ns.Data.Key("guild.replies") .. "|" .. tostring(g), function()
        local n = 0
        for _, r in pairs(g.recruits) do
            if (r.unread or 0) > 0 then
                for _, line in ipairs(r.chat or {}) do
                    if not line.me then n = n + r.unread break end
                end
            end
        end
        return n
    end, RECRUITS_MAX_AGE)
end

function Guild.MarkRead(full)
    local r = Recruit(full)
    if r and r.unread then
        r.unread = nil
        ns.Data.Bump("guild.replies")
        if ns.GuildUI and ns.GuildUI.UpdateNotice then ns.GuildUI.UpdateNotice() end
    end
end

function Guild.ClearChat(full)
    local r = Recruit(full)
    if r then r.chat, r.unread = nil, nil end
    ns.Data.Bump("guild.replies")
    Guild.Changed()
end

-- Is echo the game's echo of the whisper sent? The language filter hands
-- the echo back with words starred out ("shit" -> "@#$%"), so a run of
-- symbols in the echo stands for any letters of the same word.
function Guild.SameWhisper(sent, echo)
    if sent == echo then return true end
    if type(sent) ~= "string" or type(echo) ~= "string" then return false end
    local words = {}
    for w in sent:gmatch("%S+") do words[#words + 1] = w end
    local i = 0
    for w in echo:gmatch("%S+") do
        i = i + 1
        local s = words[i]
        if not s then return false end
        if s ~= w then
            -- Letters and digits need no escaping in a pattern.
            local p, symbols = w:gsub("%W+", ".-")
            if symbols == 0 or not s:match("^" .. p .. "$") then return false end
        end
    end
    return i == #words
end

-- The game answered a whisper to this player with "ignoring you" or "no
-- player named" (offline): replies still shown as sending were not
-- delivered. Ignoring is kept on the record until they whisper again.
local UNDELIVERED_MATCH = 10   -- an answer belongs to replies sent this recently (GetTime)
function Guild.Undelivered(name, why)
    local r, full = InvitedRecruit(name)
    if not r then return end
    if why == "ignoring" then r.ignoring = time() end
    local now = GetTime()
    for _, e in ipairs(outgoing[full] or {}) do
        if not e.lost and now - e.t <= UNDELIVERED_MATCH then e.lost, e.why, e.t = true, why, now end
    end
    ns.Data.Bump("guild.replies")
    Guild.Changed()
end

-- A reply typed in the Replies tab (Enter = one whisper). The game's echo
-- (CHAT_MSG_WHISPER_INFORM) puts it into the conversation. Returns false,
-- "repeat" for the same text sent to them a moment ago.
function Guild.Reply(full, text)
    if type(text) ~= "string" or text:match("^%s*$") then return false end
    text = text:sub(1, MAX_WHISPER)
    local entry
    local ok, why = Outbox.Whisper(text, Target(full), { label = Guild.Short(full),
        onLost = function()
            if entry then entry.lost, entry.t = true, GetTime() Guild.Changed() end
        end })
    if ok then
        -- An answer line that matches nothing ("... is ignoring you" in another
        -- wording) is kept for the guild check, as after an opener.
        lastSend = GetTime()
        -- Shown as "sending" until the echo: the game delivers about one
        -- whisper a second, so behind queued openers the echo can take a while.
        entry = { text = text, t = GetTime() }
        outgoing[full] = outgoing[full] or {}
        table.insert(outgoing[full], entry)
        Guild.Changed()
    end
    return ok, why
end

-- Your whispers to this player not in the conversation yet, oldest first:
-- { text, state = "queued" (waiting for the pace) | "sending" (sent, no echo
-- yet) | "lost" (the throttle dropped it) | "ignoring" (they ignore you) |
-- "notfound" (not online) }.
function Guild.Outgoing(full)
    local out = {}
    if type(full) ~= "string" then return out end
    for _, e in ipairs(outgoing[full] or {}) do
        out[#out + 1] = { text = e.text, state = e.lost and (e.why or "lost") or "sending" }
    end
    for _, text in ipairs(Outbox.QueuedFor(Target(full))) do
        out[#out + 1] = { text = text, state = "queued" }
    end
    return out
end

-- Called only from a click: one party invite to one player.
function Guild.PartyInvite(full)
    if type(full) ~= "string" then return false end
    return (Outbox.PartyInvite(Target(full)))
end

-- The unit token showing this player (target, mouseover, focus), or nil.
local function UnitOf(full)
    for _, unit in ipairs({ "target", "mouseover", "focus" }) do
        if S.Call(UnitIsPlayer, unit) then
            local name, realm = S.CallMulti(2, UnitName, unit)
            if type(name) == "string" and FullName(name, realm) == full then return unit end
        end
    end
end

-- Every unit that may show another player: a level read there is current.
local LOOK_UNITS = { "target", "mouseover", "focus" }
for i = 1, 4 do LOOK_UNITS[#LOOK_UNITS + 1] = "party" .. i end
for i = 1, 40 do LOOK_UNITS[#LOOK_UNITS + 1] = "raid" .. i end
for i = 1, 40 do LOOK_UNITS[#LOOK_UNITS + 1] = "nameplate" .. i end

-- Called only from a click (opening a conversation): brings a recruit's
-- level, class, race and zone up to date. From the roster when they are a
-- member, else from a unit showing them, else one /who for that one name
-- (only when the /who wait is over and no search is out). Returns where
-- from: "roster", "unit", "who", or nil.
function Guild.LookUp(full)
    local r = type(full) == "string" and Recruit(full)
    if not r then return nil end
    local g = Guild.Data()
    local m = g and g.members[full]
    if m then
        if Freshen(r, { level = m.level, classFile = m.classFile, zone = m.zone }) then
            ns.Data.Bump("guild.replies")
            Guild.Changed()
        end
        return "roster"
    end
    for _, unit in ipairs(LOOK_UNITS) do
        if S.Call(UnitExists, unit) and S.Call(UnitIsPlayer, unit) then
            local f = ns.ReadPlayerFacts(unit)
            if f and f.name and FullName(f.name, f.realm) == full then
                if Freshen(r, { level = f.level, classFile = f.classFile, race = f.race }) then
                    ns.Data.Bump("guild.replies")
                    Guild.Changed()
                end
                return "unit"
            end
        end
    end
    local send = WhoAPI()
    if not send or Guild.WhoWait() > 0 or (whoPending and GetTime() - whoPending.t <= WHO_WAIT) then return nil end
    if not pcall(send, 'n-"' .. Target(full) .. '"') then return nil end
    lastWho = GetTime()
    whoPending = { t = GetTime(), look = true, full = full }
    return "who"
end

-- How a Battle.net friend request can reach this player: the game only
-- offers it for guild members and for a unit you can see. Returns the
-- function and its argument, or nil and why not.
function Guild.BattleNetRoute(full)
    if type(BNFeaturesEnabledAndConnected) == "function" and not S.Call(BNFeaturesEnabledAndConnected) then
        return nil, "Battle.net is not connected."
    end
    if MemberOfMine(full) and type(BNCheckBattleTagInviteToGuildMember) == "function" then
        return BNCheckBattleTagInviteToGuildMember, Target(full)
    end
    local unit = UnitOf(full)
    if unit and type(BNCheckBattleTagInviteToUnit) == "function" then return BNCheckBattleTagInviteToUnit, unit end
    if type(BNCheckBattleTagInviteToGuildMember) ~= "function" and type(BNCheckBattleTagInviteToUnit) ~= "function" then
        return nil, "This client has no Battle.net friend request."
    end
    return nil, "The game sends a Battle.net request only to a guild member or a player you target."
end

-- Called only from a click: asks the game for its Battle.net friend request
-- window (you confirm it there).
function Guild.BattleNetInvite(full)
    local fn, arg = Guild.BattleNetRoute(full)
    if not fn then
        ns.Print(arg)
        return false
    end
    return (pcall(fn, arg))
end

local function HasReportWindow()
    return type(ReportFrame) == "table" and type(ReportFrame.InitiateReport) == "function"
        and type(ReportInfo) == "table" and type(ReportInfo.CreateReportInfoFromType) == "function"
        and type(PlayerLocation) == "table" and type(Enum) == "table" and type(Enum.ReportType) == "table"
end

-- What the game's report window can be opened on: "chat" and the line ID of
-- their last whisper this session (a report on that message, as from the
-- chat window's right-click), else "player" and their GUID. Being ignored
-- by them does not stop a report. Returns nil and why not.
function Guild.ReportRoute(full)
    if not HasReportWindow() then
        return nil, "This client has no report window: right-click their name in the chat window instead."
    end
    local line = full and lastLine[full]
    if line and type(PlayerLocation.CreateFromChatLineID) == "function" and Enum.ReportType.Chat then
        return "chat", line
    end
    local r = full and Recruit(full)
    if r and r.guid and type(PlayerLocation.CreateFromGUID) == "function" and Enum.ReportType.InWorld then
        return "player", r.guid
    end
    return nil, "Nothing to report from: the game gives a message to report only for whispers since your last login or reload."
end

-- Called only from a click: opens the game's report window for this player
-- (you pick the reason and send it there; the addon never sends a report).
function Guild.Report(full)
    local kind, arg = Guild.ReportRoute(full)
    if not kind then
        ns.Print(arg)
        return false
    end
    return (pcall(function()
        local info = ReportInfo:CreateReportInfoFromType(kind == "chat" and Enum.ReportType.Chat or Enum.ReportType.InWorld)
        local where = kind == "chat" and PlayerLocation:CreateFromChatLineID(arg) or PlayerLocation:CreateFromGUID(arg)
        ReportFrame:InitiateReport(info, Target(full), where)
    end))
end

-- True once you wrote to a recruit yourself (anything but the opening whisper).
local function Talking(r)
    for _, line in ipairs(r.chat or {}) do
        if line.me and line.text ~= r.whisper then return true end
    end
    return false
end

-- Chat filter: keeps the recruiting spam out of the chat window (it is in
-- the Replies tab): your opening whisper, and their answers until you write
-- back yourself. Once you do, the conversation shows in chat as usual.
-- A secret name or text is shown.
local function FilterWhisper(_, event, text, name)
    if not db().guildHideChat then return false end
    local r = InvitedRecruit(name)
    text = S.Value(text)
    if not r or type(text) ~= "string" then return false end
    if event == "CHAT_MSG_WHISPER_INFORM" then return text == r.whisper end
    return not Talking(r)
end

-- The game's lines about an invite you sent ("You have invited...",
-- "... declines", offline, already in a guild) for players you invited.
local RECRUIT_LINES = { invite = true, declined = true, guilded = true, pending = true, notfound = true }
local function FilterSystem(_, _, text)
    if not db().guildHideChat then return false end
    local kind, name = MatchSystem(text)
    return RECRUIT_LINES[kind] == true and InvitedRecruit(name) ~= nil
end
Guild.FilterWhisper, Guild.FilterSystem = FilterWhisper, FilterSystem

local function RegisterChatFilters()
    local add = (ChatFrameUtil and type(ChatFrameUtil.AddMessageEventFilter) == "function" and ChatFrameUtil.AddMessageEventFilter)
        or ChatFrame_AddMessageEventFilter
    if type(add) ~= "function" then return end
    pcall(add, "CHAT_MSG_WHISPER", FilterWhisper)
    pcall(add, "CHAT_MSG_WHISPER_INFORM", FilterWhisper)
    pcall(add, "CHAT_MSG_SYSTEM", FilterSystem)
end

---------------------------------------------------------------------------
-- Roster
---------------------------------------------------------------------------
-- Asks for the roster and the guild event log (login, window open, the
-- Refresh button; never on a timer).
function Guild.RequestRoster()
    if not Guild.Mine() then return end
    local fn = Fn(GI(), "GuildRoster", "GuildRoster")
    if fn then pcall(fn) end
    local log = Fn(GI(), "QueryGuildEventLog", "QueryGuildEventLog")
    if log then pcall(log) end
end

local function Hint(full, kinds)
    local h = hints[full]
    if h and kinds[h.kind] and time() - h.t <= HINT_SECONDS then return h end
end

local function Log(g, kind, full, from, to, by)
    g.log[#g.log + 1] = { t = time(), k = kind, n = full, from = from, to = to, by = by, c = ns.Store.Me() }
    local extra = #g.log - MAX_LOG
    if extra > 50 then
        for i = 1, MAX_LOG do g.log[i] = g.log[i + extra] end
        for i = #g.log, MAX_LOG + 1, -1 do g.log[i] = nil end
    end
end

-- Seconds since a member was last online from (years, months, days, hours).
local function OfflineSeconds(y, mo, d, h)
    if type(y) ~= "number" and type(mo) ~= "number" and type(d) ~= "number" and type(h) ~= "number" then return nil end
    return (((y or 0) * 365 + (mo or 0) * 30 + (d or 0)) * 24 + (h or 0)) * 3600
end

-- Reads the whole roster; returns false (nothing changed) when the read is
-- incomplete, so a half-loaded roster never logs members as gone. The second
-- return is whether anything the window shows changed (big guilds send
-- roster updates every few seconds; redrawing on each one lags).
function Guild.ReadRoster()
    local g = Guild.Data()
    if not g then return false end
    local total = S.Call(GetNumGuildMembers)
    if type(total) ~= "number" or total <= 0 then return false end
    local rows = {}
    for i = 1, total do
        local name, rankName, rankIndex, level, _, zone, note, _, online, _, classFile = S.CallMulti(11, GetGuildRosterInfo, i)
        if type(name) ~= "string" or name == "" or type(rankIndex) ~= "number" then return false end
        local offline
        if not online then offline = OfflineSeconds(S.CallMulti(4, GetGuildRosterLastOnline, i)) end
        rows[i] = { full = FromFull(name), rankName = rankName, rank = rankIndex, level = level, zone = zone,
            note = note, online = online and true or false, offline = offline, classFile = classFile }
    end

    local now = time()
    local numRanks = GuildControlGetNumRanks and S.Call(GuildControlGetNumRanks) or nil
    local ranksStable = g.numRanks == nil or numRanks == nil or numRanks == g.numRanks
    g.numRanks = numRanks or g.numRanks
    local first = g.baseline == nil
    local seen, changed = {}, first or #rows ~= (g.count or 0)
    for _, row in ipairs(rows) do
        local full = row.full
        seen[full] = true
        local m = g.members[full]
        if not m then
            m = { since = now, before = first or nil }
            g.members[full] = m
            changed = true
            if not first then
                Log(g, "join", full, nil, row.rankName)
                local r = Recruit(full)
                if r and r.status ~= "joined" then r.status, r.t = "joined", now end
            end
        else
            if m.missing then m.missing, changed = nil, true end
            local level = type(row.level) == "number" and row.level > 0 and row.level or m.level
            if m.rank ~= row.rank or m.level ~= level or m.zone ~= (row.zone or m.zone) or m.note ~= row.note
                or m.online ~= row.online or m.rankName ~= (row.rankName or m.rankName) then
                changed = true
            end
            if ranksStable and type(m.rank) == "number" and m.rank ~= row.rank then
                local kind = row.rank < m.rank and "promote" or "demote"
                local h = Hint(full, { promote = true, demote = true })
                Log(g, kind, full, m.rankName, row.rankName, h and h.by)
                m.rankSince = now
            end
        end
        m.rank, m.rankName, m.classFile = row.rank, row.rankName or m.rankName, row.classFile or m.classFile
        m.level = type(row.level) == "number" and row.level > 0 and row.level or m.level
        m.zone, m.note, m.online = row.zone or m.zone, row.note, row.online
        if row.online then
            m.lastOnline = now
        elseif row.offline then
            m.lastOnline = now - row.offline
        end
        if type(row.rankName) == "string" then g.ranks[row.rank] = row.rankName end
    end
    for full, m in pairs(g.members) do
        if not seen[full] then
            changed = true
            if not m.missing then
                m.missing = now
            elseif now - m.missing >= LEAVE_CONFIRM then
                local h = Hint(full, { kick = true, leave = true })
                Log(g, h and h.kind == "kick" and "kick" or "leave", full, m.rankName, nil, h and h.by)
                g.members[full] = nil
            end
        end
    end
    g.baseline = g.baseline or now
    g.lastRead, g.count = now, total
    return true, changed
end

-- Days since a member was online: 0 when online now, nil when unknown.
function Guild.DaysOffline(m)
    if m.online then return 0 end
    if not m.lastOnline then return nil end
    return math.max(0, (time() - m.lastOnline) / 86400)
end

-- Days a member has been in the guild, and whether that is a lower bound
-- (they were there before TALOD first read the roster).
function Guild.DaysIn(m)
    return math.max(0, (time() - (m.since or time())) / 86400), m.before == true
end

-- filter: "all", "online", "inactive".
function Guild.Roster(filter)
    local g = Guild.Data()
    local out = {}
    if not g then return out end
    local limit = db().guildInactiveDays or 30
    for full, m in pairs(g.members) do
        local days = Guild.DaysOffline(m)
        local keep = filter ~= "online" and filter ~= "inactive"
            or (filter == "online" and m.online)
            or (filter == "inactive" and days ~= nil and days >= limit)
        if keep then out[#out + 1] = { full = full, m = m, days = days } end
    end
    -- Rank, then name (a text key: one C sort for hundreds of members).
    return ns.Utils.SortBy(out, function(x) return string.format("%03d", x.m.rank or 99) .. x.full end)
end

function Guild.Log()
    local g = Guild.Data()
    return g and g.log or {}
end

function Guild.RankName(index)
    local g = Guild.Data()
    local name = g and g.ranks[index]
    if not name and GuildControlGetRankName then name = S.Call(GuildControlGetRankName, index + 1) end
    return type(name) == "string" and name or ("Rank " .. tostring(index))
end

function Guild.NumRanks()
    local g = Guild.Data()
    local n = GuildControlGetNumRanks and S.Call(GuildControlGetNumRanks)
    if type(n) == "number" and n > 0 then return n end
    local top = -1
    for i in pairs(g and g.ranks or {}) do if i > top then top = i end end
    return top + 1
end

---------------------------------------------------------------------------
-- Recruiters: who invited whom, who joined, who stayed
---------------------------------------------------------------------------
-- The game's guild event log ("X invited Y", "Y joined", "Y left", "X
-- removed Y") covers every member, addon or not, but only its last entries
-- and with times as "N days / hours ago". Each read is merged into
-- g.events, so the history grows past what the game keeps. Two entries are
-- the same when kind and names match and the times are within the log's
-- precision (2 h, or a day plus 10 % once it counts in days).
local QUICK_QUIT_DAYS = 7
Guild.QUICK_QUIT_DAYS = QUICK_QUIT_DAYS

local function Tolerance(age)
    if age < 86400 then return 2 * 3600 end
    return 86400 + age * 0.1
end

-- Each entry of g.events is one string, "t|k|a|b|rank" (Store.PackList):
-- a busy guild's log holds thousands, and a table per entry cost four
-- times the memory. Read through Guild.Event / Guild.Events (tables from
-- before guild v3 are read too).
function Guild.PackEvent(e)
    return St.PackList({ e.t, e.k, e.a, e.b, e.rank }, 5, "|")
end

local Unpack = St.UnpackValue

function Guild.Event(s)
    if type(s) ~= "string" then return s end
    -- One match for the five fields (a history is decoded whole for Recruiters).
    local t, k, a, b, rank = s:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
    if not t then
        local f = St.SplitList(s, "|")
        t, k, a, b, rank = f[1] or "", f[2] or "", f[3] or "", f[4] or "", f[5] or ""
    end
    return { t = Unpack(t), k = Unpack(k), a = Unpack(a), b = Unpack(b), rank = Unpack(rank) }
end

local function EventTime(s)
    if type(s) == "table" then return tonumber(s.t) or 0 end
    return tonumber(s:match("^n([^|]*)")) or 0
end
Guild.EventTime = EventTime

-- for i, e in Guild.Events(g): every entry decoded, oldest first.
function Guild.Events(g)
    local list, i = type(g) == "table" and g.events or {}, 0
    return function()
        i = i + 1
        local s = list[i]
        if s == nil then return nil end
        return i, Guild.Event(s)
    end
end

-- Cleanup rule: event log entries older than the cutoff. Recruiter stats
-- and memberships then start at the cutoff; eventsSince moves with it, so
-- officers' checks (GuildSync) never treat the dropped time as seen.
-- keep (archive): key the guild, value the event's packed string.
function Guild.DropOldEvents(cutoff, apply, keep)
    local root = db().guild
    local n = 0
    for gkey, g in pairs(type(root) == "table" and type(root.guilds) == "table" and root.guilds or {}) do
        local list = type(g.events) == "table" and g.events or {}
        local old = 0
        while list[old + 1] ~= nil and EventTime(list[old + 1]) < cutoff do old = old + 1 end
        n = n + old
        if apply and old > 0 then
            if keep then
                for i = 1, old do
                    local s = list[i]
                    keep(gkey, type(s) == "string" and s or Guild.PackEvent(s))
                end
            end
            local j = 0
            for i = old + 1, #list do j = j + 1 list[j] = list[i] end
            for i = #list, j + 1, -1 do list[i] = nil end
            g.eventsSince = math.max(tonumber(g.eventsSince) or 0, cutoff)
        end
    end
    return n
end

-- Store migration (guild v3): every guild's table entries packed.
function Guild.PackEvents(root)
    for _, g in pairs(type(root) == "table" and type(root.guilds) == "table" and root.guilds or {}) do
        for i, e in ipairs(type(g.events) == "table" and g.events or {}) do
            if type(e) == "table" then g.events[i] = Guild.PackEvent(e) or e end
        end
    end
end

function Guild.ReadEventLog()
    local g = Guild.Data()
    if not g then return false end
    local count = Fn(GI(), "GetNumGuildEvents", "GetNumGuildEvents")
    local info = Fn(GI(), "GetGuildEventInfo", "GetGuildEventInfo")
    local n = count and S.Call(count)
    if type(n) ~= "number" or not info then return false end
    g.events = g.events or {}
    local now, added = time(), 0
    -- The entries a new one is compared with (the last 400), decoded once and
    -- grouped by kind and names: the game answers every window open with its
    -- whole log, and a scan of all 400 per game entry cost ~30 ms a read.
    local recent = {}
    local function Same(k, a, b) return k .. "\1" .. a .. "\1" .. (b or "") end
    local function Remember(e)
        local key = Same(e.k, e.a or "", e.b)
        local list = recent[key]
        if not list then list = {} recent[key] = list end
        list[#list + 1] = e.t
    end
    for j = math.max(1, #g.events - 400), #g.events do
        local e = Guild.Event(g.events[j])
        if type(e) == "table" and type(e.k) == "string" and type(e.t) == "number" then Remember(e) end
    end
    local first = #g.events + 1
    for i = 1, n do
        local k, p1, p2, rank, y, mo, d, h = S.CallMulti(8, info, i)
        if type(k) == "string" and type(p1) == "string" and p1 ~= "" then
            local t = now - (OfflineSeconds(y, mo, d, h) or 0)
            local a, b = FullName(p1), (type(p2) == "string" and p2 ~= "") and FullName(p2) or nil
            local dup = false
            for _, t2 in ipairs(recent[Same(k, a, b)] or {}) do
                if math.abs(t2 - t) <= Tolerance(math.max(0, now - math.min(t2, t))) then dup = true break end
            end
            if not dup then
                local e = { t = t, k = k, a = a, b = b, rank = type(rank) == "string" and rank or nil }
                Remember(e)
                g.events[#g.events + 1] = Guild.PackEvent(e)
                added = added + 1
            end
        end
    end
    if added > 0 then
        -- Oldest first: each new entry moves back past the newer ones (a few
        -- steps; the list before them is already in order). Equal times keep
        -- their order.
        local list = g.events
        for i = first, #list do
            local s, t, j = list[i], EventTime(list[i]), i - 1
            while j >= 1 and EventTime(list[j]) > t do list[j + 1] = list[j] j = j - 1 end
            list[j + 1] = s
        end
    end
    g.eventsRead = now
    g.eventsSince = g.eventsSince or (g.events[1] and EventTime(g.events[1])) or now
    return true, added
end

-- Every membership: { who, inviter, joined, left, how ("quit"/"removed"), nth }.
-- A join counts for the latest invite of that player before it (from the
-- event log, or your own invite through TALOD); joins and leaves come
-- from the event log and from the roster log, merged when close together.
-- Memberships and Recruiters walk the whole history (thousands of entries in
-- a big guild) and several views ask for them in one redraw, so the result
-- is kept until the data it is built from changes (or a minute passes, for
-- the "days in the guild" of current members and edits this key misses).
local CACHE_SECONDS = 60

-- Several views ask in each redraw: the walk over every recruit (it catches
-- edits that skip Guild.Changed, which the minute's maxAge covers anyway)
-- runs at most every keyCache.seconds while the guild data version holds.
-- (One table: this file is near Lua 5.1's 200 locals.)
local keyCache = { seconds = 2 }

local function DataKey(g)
    local now, ver = GetTime(), ns.Data.Version("guild")
    if keyCache.g == g and keyCache.ver == ver and now - keyCache.at < keyCache.seconds then return keyCache.text end
    local n, sum = 0, 0
    for _, r in pairs(g.recruits) do
        n = n + 1
        if r.invited and r.by then sum = sum + r.invited end
    end
    local e, l = g.events or {}, g.log
    keyCache.g, keyCache.at, keyCache.ver = g, now, ver
    keyCache.text = table.concat({ tostring(g), #e, e[#e] and EventTime(e[#e]) or 0, #l, l[#l] and l[#l].t or 0,
        n, sum, g.lastRead or 0 }, ":")
    return keyCache.text
end

local function Cached(name, g, build)
    return ns.Data.Memo("guild:" .. name, ns.Data.Key("guild") .. "|" .. DataKey(g), function() return build(g) end, CACHE_SECONDS)
end

-- Callers read the result; it is shared until the data changes.
function Guild.Memberships()
    local g = Guild.Data()
    if not g then return {} end
    return Cached("memberships", g, Guild.BuildMemberships)
end

function Guild.BuildMemberships(g)
    local invites, joins, leaves = {}, {}, {}
    local now = time()
    local function Add(list, who, entry)
        list[who] = list[who] or {}
        for _, e in ipairs(list[who]) do
            if math.abs(e.t - entry.t) <= Tolerance(math.max(0, now - entry.t)) then
                e.by = e.by or entry.by
                return
            end
        end
        table.insert(list[who], entry)
    end
    for i, e in Guild.Events(g) do
        Step(i)
        if e.k == "invite" and e.b then Add(invites, e.b, { t = e.t, by = e.a })
        elseif e.k == "join" then Add(joins, e.a, { t = e.t })
        elseif e.k == "quit" then Add(leaves, e.a, { t = e.t, how = "quit" })
        elseif e.k == "remove" and e.b then Add(leaves, e.b, { t = e.t, how = "removed", by = e.a }) end
    end
    for i, e in ipairs(g.log) do
        Step(i)
        if e.k == "join" then Add(joins, e.n, { t = e.t })
        elseif e.k == "leave" then Add(leaves, e.n, { t = e.t, how = "quit" })
        elseif e.k == "kick" then Add(leaves, e.n, { t = e.t, how = "removed", by = e.by }) end
    end
    for full, rec in pairs(g.recruits) do
        if rec.invited and rec.by then Add(invites, full, { t = rec.invited, by = rec.by }) end
    end
    local out, n = {}, 0
    for who, list in pairs(joins) do
        n = n + 1
        Step(n)
        table.sort(list, function(x, y) return x.t < y.t end)
        for i, j in ipairs(list) do
            local inviter, best = nil, -math.huge
            for _, inv in ipairs(invites[who] or {}) do
                if inv.t <= j.t + 2 * 3600 and inv.t > best then inviter, best = inv.by, inv.t end
            end
            local nextJoin = list[i + 1] and list[i + 1].t or math.huge
            local left, how
            for _, l in ipairs(leaves[who] or {}) do
                if l.t >= j.t - 2 * 3600 and l.t < nextJoin and (not left or l.t < left) then left, how = l.t, l.how end
            end
            out[#out + 1] = { who = who, inviter = inviter, joined = j.t, left = left, how = how, nth = i }
        end
    end
    table.sort(out, function(x, y) return x.joined > y.joined end)
    return out
end

-- Per inviter: invitedCount (people), joined (people), here (still
-- members), left (memberships that ended), quick (ended within
-- QUICK_QUIT_DAYS), rejoins (people who joined more than once), days
-- (average days in the guild), list (their memberships).
function Guild.Recruiters()
    local g = Guild.Data()
    if not g then return {} end
    return Cached("recruiters", g, Guild.BuildRecruiters)
end

function Guild.BuildRecruiters(g)
    local stats = {}
    local function Stat(by)
        stats[by] = stats[by] or { by = by, invited = {}, joinedSet = {}, joined = 0, here = 0, left = 0, quick = 0,
            rejoins = 0, daysSum = 0, daysN = 0, list = {} }
        return stats[by]
    end
    -- Only invites count here: the others are not decoded at all.
    for i, s in ipairs(g.events or {}) do
        Step(i)
        if type(s) ~= "string" or s:find("|sinvite|", 1, true) then
            local e = Guild.Event(s)
            if e.k == "invite" and e.b then Stat(e.a).invited[e.b] = true end
        end
    end
    for full, rec in pairs(g.recruits) do
        if rec.invited and rec.by then Stat(rec.by).invited[full] = true end
    end
    local joinsOf = {}
    for i, m in ipairs(Guild.Memberships()) do
        Step(i)
        joinsOf[m.who] = (joinsOf[m.who] or 0) + 1
        if m.inviter then
            local st = Stat(m.inviter)
            st.list[#st.list + 1] = m
            if not st.joinedSet[m.who] then st.joinedSet[m.who] = true st.joined = st.joined + 1 end
            local member = g.members[m.who] ~= nil and not g.members[m.who].missing
            local stay = ((m.left or time()) - m.joined) / 86400
            if m.left then
                st.left = st.left + 1
                if stay < QUICK_QUIT_DAYS then st.quick = st.quick + 1 end
            elseif member then
                st.here = st.here + 1
            end
            st.daysSum, st.daysN = st.daysSum + math.max(0, stay), st.daysN + 1
        end
    end
    local out = {}
    for _, st in pairs(stats) do
        local n = 0
        for _ in pairs(st.invited) do n = n + 1 end
        st.invitedCount = n
        for who in pairs(st.joinedSet) do
            if (joinsOf[who] or 0) > 1 then st.rejoins = st.rejoins + 1 end
        end
        st.days = st.daysN > 0 and st.daysSum / st.daysN or nil
        out[#out + 1] = st
    end
    table.sort(out, function(a, b)
        if a.here ~= b.here then return a.here > b.here end
        if a.joined ~= b.joined then return a.joined > b.joined end
        return a.by < b.by
    end)
    return out
end

-- Who invited a member (their latest membership), and that membership.
function Guild.InvitedBy(full)
    for _, m in ipairs(Guild.Memberships()) do
        if m.who == full then return m.inviter, m end
    end
end

-- Members someone invited who are still in the guild.
function Guild.RecruitsKept(full)
    for _, st in ipairs(Guild.Recruiters()) do
        if st.by == full then return st.here end
    end
    return 0
end

---------------------------------------------------------------------------
-- Promotion rules: "promote from rank r+1 to rank r when ..."
---------------------------------------------------------------------------
Guild.RULE_DEFAULT = { on = false, level = 1, days = 14, active = 7, recruits = 0 }

function Guild.Rule(target)
    local g = Guild.Data()
    if not g then return nil end
    local r = g.rules[target]
    if not r then
        r = {}
        for k, v in pairs(Guild.RULE_DEFAULT) do r[k] = v end
        g.rules[target] = r
    end
    return r
end

-- The ranks you may promote into: below your own, above the lowest.
function Guild.PromotableRanks()
    local _, _, myRank = Guild.Mine()
    local out = {}
    if type(myRank) ~= "number" then return out end
    for target = myRank + 1, Guild.NumRanks() - 2 do out[#out + 1] = target end
    return out
end

-- Members each person invited who are still in the guild: { [full] = n }.
function Guild.KeptMap()
    local map = {}
    for _, st in ipairs(Guild.Recruiters()) do map[st.by] = st.here end
    return map
end

-- Why a member does not meet their next rank's rule, or nil when they do.
-- kept: Guild.KeptMap(), passed in when checking many members.
function Guild.RuleCheck(m, rule, full, kept)
    if not rule or not rule.on then return "rule off" end
    if type(m.level) ~= "number" or m.level < (rule.level or 1) then return "level" end
    local days, lowerBound = Guild.DaysIn(m)
    if days < (rule.days or 0) then return lowerBound and "days unknown" or "days" end
    local off = Guild.DaysOffline(m)
    if off == nil then return "last online unknown" end
    if off > (rule.active or 0) then return "inactive" end
    if (rule.recruits or 0) > 0 then
        local n = full and (kept and (kept[full] or 0) or Guild.RecruitsKept(full)) or 0
        if n < rule.recruits then return "recruits" end
    end
    return nil
end

function Guild.PromotionCandidates()
    local g = Guild.Data()
    local out = {}
    if not g then return out end
    local kept = Guild.KeptMap()
    for _, target in ipairs(Guild.PromotableRanks()) do
        local rule = g.rules[target]
        if rule and rule.on then
            for full, m in pairs(g.members) do
                if m.rank == target + 1 and not m.missing and Guild.RuleCheck(m, rule, full, kept) == nil then
                    out[#out + 1] = { full = full, m = m, target = target }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.target ~= b.target then return a.target < b.target end
        return a.full < b.full
    end)
    return out
end

---------------------------------------------------------------------------
-- Rank changes the game refuses. A refused call raises no Lua error: the
-- game fires ADDON_ACTION_FORBIDDEN (only its own UI may call it) or
-- ADDON_ACTION_BLOCKED (needs a click) inside the call, which then returns
-- as if it worked, and names the function "UNKNOWN()". So the call notes
-- which API it is making, and a forbidden one is remembered for this game
-- build: the menu greys those ranks out instead of failing silently.
---------------------------------------------------------------------------
local calling, refused

local function Build()
    local _, build = S.CallMulti(2, GetBuildInfo)
    return tostring(build or "?")
end

-- True when the game forbade this API ("promote", "demote", "setRank") to addons.
function Guild.Refused(api)
    local r = db().guildRefused
    return type(r) == "table" and r.build == Build() and r[api] == true
end

-- One call of a rank API. Returns ok, and the refusal event when the game refused it.
local function CallRankApi(api, fn, ...)
    calling, refused = api, nil
    local ok = pcall(fn, ...)
    calling = nil
    if refused then
        if refused == "ADDON_ACTION_FORBIDDEN" then
            local r = db().guildRefused
            if type(r) ~= "table" or r.build ~= Build() then r = { build = Build() } db().guildRefused = r end
            r[api] = true
        end
        return false, refused
    end
    return ok
end

local function RefusedText(full, refusal)
    if refusal == "ADDON_ACTION_FORBIDDEN" then
        return "the game keeps this rank change to its own guild window: change " .. Guild.Short(full)
            .. "'s rank there. " .. ns.NAME .. " greys it out from now on."
    end
    return "the game blocked the rank change of " .. Guild.Short(full) .. " (it takes it only from a click)."
end

-- Called only from a click: one member, up one rank.
function Guild.Promote(full)
    local g = Guild.Data()
    local m = g and g.members[full]
    if not m then return false end
    if not Guild.Can("promote") then
        ns.Print("your guild rank cannot promote members.")
        return false
    end
    local _, _, myRank = Guild.Mine()
    if type(myRank) ~= "number" or type(m.rank) ~= "number" or m.rank - 1 <= myRank then
        ns.Print(Guild.Short(full) .. " cannot be promoted above the rank below yours.")
        return false
    end
    local fn = Fn(GI(), "Promote", "GuildPromote")
    if Guild.Refused("promote") then
        ns.Print(RefusedText(full, "ADDON_ACTION_FORBIDDEN"))
        return false
    end
    local ok, refusal = false, nil
    if fn then ok, refusal = CallRankApi("promote", fn, Target(full)) end
    if not ok then
        ns.Print(refusal and RefusedText(full, refusal) or ("the game did not accept the promotion of " .. Guild.Short(full) .. "."))
        return false
    end
    -- The roster update that follows logs the change.
    Guild.RequestRoster()
    return true
end

---------------------------------------------------------------------------
-- Rank menu: any rank in one click (right-click a member in the Guild window)
---------------------------------------------------------------------------
-- The game's permission flags of a rank (0 = guild master), or nil when this
-- client does not tell (Classic Era has no C_GuildInfo.GuildControlGetRankFlags).
function Guild.RankFlags(rank)
    local fn = GI() and GI().GuildControlGetRankFlags
    if type(fn) ~= "function" or type(rank) ~= "number" then return nil end
    local ok, t = pcall(fn, rank + 1)
    t = ok and S.Value(t) or nil
    if type(t) ~= "table" then return nil end
    return t
end

-- The guild control flags worth a warning, by index (4, officer chat speak,
-- rides on 3). [VERIFY] the indices on Forever's 12.1 engine.
Guild.RANK_RIGHTS = {
    { 3, "officer chat" }, { 5, "promote" }, { 6, "demote" }, { 7, "invite" }, { 8, "remove members" },
    { 9, "set the message of the day" }, { 11, "read officer notes" }, { 12, "edit officer notes" },
    { 13, "edit guild info" },
}

-- Rights rank `to` has that rank `from` lacks (gained) and the other way
-- (lost), or nil when either rank's rights are unknown.
function Guild.RightsChange(from, to)
    local a, b = Guild.RankFlags(from), Guild.RankFlags(to)
    if not a or not b then return nil end
    local gained, lost = {}, {}
    for _, r in ipairs(Guild.RANK_RIGHTS) do
        local had, has = S.Value(a[r[1]]) == true, S.Value(b[r[1]]) == true
        if has and not had then gained[#gained + 1] = r[2] end
        if had and not has then lost[#lost + 1] = r[2] end
    end
    return gained, lost
end

-- Every rank in order for one member: { rank, name, current, ok, why,
-- gained, lost } (gained / lost nil: rights unknown).
function Guild.RankChoices(full)
    local g = Guild.Data()
    local m = g and g.members[full]
    local out = {}
    if not m or type(m.rank) ~= "number" then return out end
    local _, _, myRank = Guild.Mine()
    for rank = 0, Guild.NumRanks() - 1 do
        local c = { rank = rank, name = Guild.RankName(rank), current = rank == m.rank }
        if not c.current then
            if type(myRank) ~= "number" then c.why = "your rank is unknown"
            elseif m.missing then c.why = "missing from the last roster read"
            elseif m.rank <= myRank then c.why = "their rank is not below yours"
            elseif rank <= myRank then c.why = rank == 0 and "the guild master's rank" or "not below your rank"
            elseif rank < m.rank and not Guild.Can("promote") then c.why = "your rank cannot promote"
            elseif rank > m.rank and not Guild.Can("demote") then c.why = "your rank cannot demote"
            elseif math.abs(rank - m.rank) > 1 and not Fn(nil, nil, "SetGuildMemberRank") then
                c.why = "this client moves one rank per click"
            elseif Guild.Refused(math.abs(rank - m.rank) > 1 and "setRank" or (rank < m.rank and "promote" or "demote")) then
                c.why = "the game lets only its own guild window do this"
            else c.ok = true end
            c.gained, c.lost = Guild.RightsChange(m.rank, rank)
        end
        out[#out + 1] = c
    end
    return out
end

-- The roster index of a member right now (the game's list order changes).
local function RosterIndex(full)
    local total = S.Call(GetNumGuildMembers)
    if type(total) ~= "number" then return nil end
    for i = 1, total do
        local name = S.Call(GetGuildRosterInfo, i)
        if type(name) == "string" and FromFull(name) == full then return i end
    end
end

-- Called only from a click: one member to one rank, one game command. One
-- step is the game's own promote / demote; a jump is SetGuildMemberRank
-- (where that is missing, RankChoices offers only the ranks next to theirs).
function Guild.SetRank(full, target)
    local c
    for _, x in ipairs(Guild.RankChoices(full)) do
        if x.rank == target then c = x end
    end
    if not c or c.current then return false end
    if not c.ok then
        ns.Print(Guild.Short(full) .. " cannot be moved to " .. c.name .. ": " .. c.why .. ".")
        return false
    end
    local from = Guild.Data().members[full].rank
    local ok, refusal = false, nil
    if math.abs(target - from) == 1 then
        local up = target < from
        local fn = up and Fn(GI(), "Promote", "GuildPromote") or Fn(GI(), "Demote", "GuildDemote")
        if fn then ok, refusal = CallRankApi(up and "promote" or "demote", fn, Target(full)) end
    else
        local fn = Fn(nil, nil, "SetGuildMemberRank")
        local index = RosterIndex(full)
        -- The game counts ranks from 1 here (1 = guild master).
        if fn and index then ok, refusal = CallRankApi("setRank", fn, index, target + 1) end
    end
    if not ok then
        ns.Print(refusal and RefusedText(full, refusal) or ("the game did not accept moving " .. Guild.Short(full) .. " to " .. c.name .. "."))
        return false
    end
    Guild.RequestRoster()
    return true
end

---------------------------------------------------------------------------
-- Hands Free (guildHandsFree): a mouse click on the open world, one that hit
-- no window and no unit, is the click for the next recruit step. Still one
-- click = one action: the invite of a red row, else a /who once its wait is over,
-- else the whisper to the next player. Each needs your click (the game
-- blocks invites and /who anywhere else), so nothing goes while you do not click.
---------------------------------------------------------------------------
local HANDS_FREE_TRIES = 3     -- players tried per click when one is refused
local HANDS_FREE_GAP = 1       -- seconds between Hands Free steps (world clicks and move keys): presses sooner do nothing
local handsFreeLast            -- { what = "invite" | "whisper" | "who", full, t } (session only)
local presses = {}             -- the last presses while on: { t, button, over, result } (session only)
local MAX_PRESSES = 8
local BLOCK_LIMIT = 3          -- blocked this many times in a row: that action from that input is left alone
local stepping                 -- { source, blocked } while a step's game calls run
local blockStreak = {}         -- ["mouse:who"] = blocked steps in a row (session only)
local leftAlone = {}           -- ["key:invite"] = true: the game blocked it BLOCK_LIMIT times in a row (session only)
local yourClick = {}           -- [full] = source: the game blocked the invite from that input; it waits for another (session only)
local toldBlocked = {}         -- [source] = true: the first blocked invite was explained in chat (session only)
-- A /who the game drops raises no refusal at all: the call returns, no
-- answer ever comes, and the button's 5 s wait would hold your own clicks.
local WHO_ANSWER = 4           -- seconds for a hands-free /who's answer; none = it did not go
local WHO_MISSES = 2           -- unanswered in a row from one input: Hands Free leaves the /who to the button
local handsFreeWho             -- { t, source, pending } for the last hands-free /who (session only)
local whoMisses = {}           -- [source] = unanswered hands-free /who in a row

-- The frame under the cursor: true when it is the open world (nil or
-- WorldFrame), and the frame's name for the trace.
local function OverWorld()
    local focus
    if type(GetMouseFoci) == "function" then
        local ok, list = pcall(GetMouseFoci)
        focus = ok and type(list) == "table" and list[1] or nil
    elseif type(GetMouseFocus) == "function" then
        local ok, f = pcall(GetMouseFocus)
        focus = ok and f or nil
    end
    if focus == nil or focus == WorldFrame then return true, focus and "WorldFrame" or "nothing" end
    local ok, name = pcall(focus.GetName, focus)
    return false, (ok and type(name) == "string") and name or "an unnamed frame"
end

local function Trace(button, over, result)
    table.insert(presses, { t = GetTime(), button = button, over = over, result = result })
    if #presses > MAX_PRESSES then table.remove(presses, 1) end
end

function Guild.HandsFreePresses() return presses end

-- What each input is called in messages and tooltips.
local SOURCE_NAME = { mouse = "world clicks", key = "your move keys", bind = "the recruit key binding" }
local function SourceName(source) return SOURCE_NAME[source] or tostring(source) end
Guild.SourceName = SourceName

-- Why a step does nothing right now (nil: it may act). Hands Free's inputs
-- need its toggle; the key binding ("bind") is always on. The invite
-- permission is checked per step: /who needs none.
function Guild.StepBlocked(source)
    if source ~= "bind" and not db().guildHandsFree then return "off" end
    if not Guild.Mine() then return "not in a guild" end
    if (InCombatLockdown and InCombatLockdown()) or S.Call(UnitAffectingCombat, "player") == true then
        return "in combat"
    end
end
function Guild.HandsFreeBlocked() return Guild.StepBlocked("mouse") end

function Guild.HandsFreeLast() return handsFreeLast end

-- The invite queue, oldest ready first. skip: an input the game blocked the
-- invite from (that player waits for another input).
local function ReadyInvites(skip)
    local list = {}
    for full, w in pairs(waiting) do
        if Guild.InviteReady(full) and not (skip and yourClick[full] == skip) then list[#list + 1] = { full = full, at = w.at } end
    end
    table.sort(list, function(a, b)
        if a.at ~= b.at then return a.at < b.at end
        return a.full < b.full
    end)
    return list
end

-- The next ready invite in the queue, sent now. Called only inside a click
-- or key press (the Next invite button, the key binding, Hands Free).
-- Returns the player, or nil.
function Guild.InviteNext(source)
    local list = ReadyInvites(source)
    for i = 1, math.min(#list, HANDS_FREE_TRIES) do
        if Guild.Invite(list[i].full) then return list[i].full end
    end
end

-- The queue at a glance: ready (sendable now), soon (ready within the delay:
-- { full, in }), message (waiting for their opener to go out), blocked
-- (ready, but the game blocked them from a Hands Free input).
function Guild.InviteQueue()
    local q = { ready = 0, soon = {}, message = 0, blocked = 0 }
    local now = GetTime()
    for full, w in pairs(waiting) do
        local r = Recruit(full)
        if r and r.status == "inviting" then
            if now >= w.at then
                q.ready = q.ready + 1
                if yourClick[full] then q.blocked = q.blocked + 1 end
            else
                q.soon[#q.soon + 1] = { full = full, ["in"] = w.at - now }
            end
        end
    end
    for full in pairs(inviteWhy) do
        local r = Recruit(full)
        if r and r.status == "inviting" and not waiting[full] then q.message = q.message + 1 end
    end
    table.sort(q.soon, function(a, b) return a["in"] < b["in"] end)
    return q
end

local function Allowed(source, kind) return not leftAlone[source .. ":" .. kind] end

-- The step one hands-free click takes. Called only inside a click or key
-- press (source "mouse" or "key"). Returns what it did ("invite",
-- "whisper", "who") and the player, or nil and why not.
local function Step(source)
    local blocked = Guild.StepBlocked(source)
    if blocked then return nil, blocked end
    local now = GetTime()
    -- Hands Free's own inputs come fast (every click, every step you walk):
    -- one step a second at most, counted from the last step that did
    -- something. The recruit key is a deliberate press: no wait.
    if source ~= "bind" and handsFreeLast and now - handsFreeLast.t < HANDS_FREE_GAP then
        return nil, "too soon (Hands Free waits 1 s between steps)"
    end
    local canInvite = Guild.Can("invite")
    local cands = canInvite and Guild.Candidates() or {}
    local what, who
    -- The invite queue first: its oldest ready invite.
    if canInvite and Allowed(source, "invite") then
        who = Guild.InviteNext(source)
        if who then what = "invite" end
    end
    -- Then a /who as soon as the button's own wait is over.
    if not what and Guild.WhoWait() == 0 and Allowed(source, "who") then
        if Guild.Who() then what = "who" end
    end
    if not what and Allowed(source, "invite") then
        local tries = 0
        for _, c in ipairs(cands) do
            if not c.ready then
                tries = tries + 1
                if Guild.Invite(c.full) then
                    local r = Recruit(c.full)
                    what, who = (r and r.status == "inviting") and "whisper" or "invite", c.full
                    break
                end
                if tries >= HANDS_FREE_TRIES then break end
            end
        end
    end
    if what then
        handsFreeLast = { what = what, full = who, t = now }
        return what, who
    end
    local whoIn = math.ceil(Guild.WhoWait())
    if not canInvite then return nil, "your rank cannot invite (or the game has not said yet); next /who in " .. whoIn .. " s" end
    if #cands == 0 then return nil, "nobody on the list; next /who in " .. whoIn .. " s" end
    return nil, "nobody on the list could be messaged now"
end

-- The game blocked an invite: the call returned as if it went, so the
-- player does not count as invited: the invite goes back in the queue
-- (ready once their opener is out).
local function InviteBlocked(full)
    local r = Recruit(full)
    if not r or r.status ~= "invited" then return end
    r.invites = math.max(0, (r.invites or 1) - 1)
    r.ack = nil
    InviteLater(full, "blocked")
end

-- One step with the game's refusals watched: ADDON_ACTION_BLOCKED fires
-- inside the blocked call, so only a refusal during the step counts.
local function WatchedStep(source)
    stepping = { source = source }
    local ok, what, x = pcall(Step, source)
    local blockedBy = stepping.blocked
    stepping = nil
    if not ok then error(what, 0) end
    if not what then return nil, x end
    local kind = what == "who" and "who" or "invite"
    local key = source .. ":" .. kind
    if not blockedBy then
        blockStreak[key] = 0
        if what == "who" then handsFreeWho = { t = GetTime(), source = source, pending = whoPending } end
        return what, x
    end
    if what == "invite" then
        InviteBlocked(x)
        -- It never went: a click on their row may send it at once, and
        -- Hands Free does not try them again (it would be blocked again).
        Outbox.ForgetInvite(Target(x))
        yourClick[x] = source
        if not toldBlocked[source] then
            toldBlocked[source] = true
            ns.Print(string.format("the game blocked the guild invite to %s from %s. It waits in the invite queue: click their red row, "
                .. "the Next invite button or your recruit key binding to send it; Hands Free goes on with the others.",
                Guild.Short(x), SourceName(source)))
        end
    end
    blockStreak[key] = (blockStreak[key] or 0) + 1
    if blockStreak[key] >= BLOCK_LIMIT then
        leftAlone[key] = true
        ns.Print(string.format("the game blocked %s from %s %d times in a row; Hands Free leaves that to the %s until you reload.",
            kind == "who" and "the /who" or "the guild invite", SourceName(source), BLOCK_LIMIT,
            kind == "who" and "/who button" or "Next invite button, the red rows and the key binding"))
    end
    Guild.Changed()
    return nil, (what == "who" and "/who" or (what .. " " .. Guild.Short(x))) .. " blocked by the game (" .. tostring(blockedBy) .. ")"
end

function Guild.HandsFreeStep(source) return WatchedStep(source or "mouse") end

-- On the tick: did the last hands-free /who get its answer? None within
-- WHO_ANSWER = the game dropped it. The button's wait is given back at once
-- (your own /who click must never wait on a search that did not happen).
local function CheckHandsFreeWho(now)
    local w = handsFreeWho
    if not w then return end
    if whoPending ~= w.pending then
        -- Answered (ReadWho cleared it) or replaced by your own search.
        handsFreeWho = nil
        whoMisses[w.source] = 0
        return
    end
    if now - w.t < WHO_ANSWER then return end
    handsFreeWho = nil
    whoPending, lastWho = nil, -math.huge
    whoStatus = "the /who from Hands Free got no answer from the game; the /who button is free"
    whoMisses[w.source] = (whoMisses[w.source] or 0) + 1
    if whoMisses[w.source] >= WHO_MISSES and not leftAlone[w.source .. ":who"] then
        leftAlone[w.source .. ":who"] = true
        ns.Print(string.format("the game does not answer a /who sent from %s, so that input leaves the /who to the /who button until you reload.",
            SourceName(w.source)))
    end
    Guild.Changed()
end

-- The input the game blocked this player's invite from (nil: none).
function Guild.HandsFreeBlockedFor(full) return yourClick[full] end
-- Inputs that leave an action alone this session: { ["mouse:who"] = true }.
function Guild.LeftAlone() return leftAlone end

local function Result(what, x)
    return what and (what == "who" and "/who" or (what .. " " .. Guild.Short(x))) or x
end

-- The recruit key binding (Bindings.xml) and "/click" macros press this
-- button: a real key press each time, so it may invite and search. One step
-- per press (next queued invite, else /who, else the next whisper), Hands
-- Free on or off. A button, not a global function: frames are the addon's
-- only globals.
-- A block: its locals end with it (Lua 5.1 allows 200 in the file's chunk).
do
    local function Feedback(text)
        local f = UIErrorsFrame
        if f and f.AddMessage then pcall(f.AddMessage, f, ns.NAME .. ": " .. text, 1, 0.82, 0) end
    end

    function Guild.RecruitStep(source)
        source = source or "bind"
        local what, x = WatchedStep(source)
        Trace(source == "bind" and "binding" or source, source, Result(what, x))
        if not what then Guild.Changed() end
        Feedback(tostring(Result(what, x)))
        return what, x
    end

    local stepButton = CreateFrame("Button", ns.FRAME .. "RecruitStep", UIParent)
    stepButton:SetSize(1, 1)
    stepButton:SetAlpha(0)
    stepButton:EnableMouse(false)
    stepButton:SetScript("OnClick", function() Guild.RecruitStep("bind") end)
    _G["BINDING_HEADER_" .. ns.SLASH_KEY] = ns.NAME
    _G["BINDING_NAME_" .. ns.BINDING_STEP] = "Next recruit step (invite, /who or whisper)"
end

-- The key bound to the recruit step, or nil.
-- A block: its locals end with it (Lua 5.1 allows 200 in the file's chunk).
do
    -- Bound either in the game's Key Bindings (Bindings.xml) or from the
    -- addon's own "Set recruit key" (a click binding on the button).
    local CLICK_ACTION = "CLICK " .. ns.FRAME .. "RecruitStep:LeftButton"
    function Guild.StepKey()
        if type(GetBindingKey) ~= "function" then return nil end
        for _, action in ipairs({ CLICK_ACTION, ns.BINDING_STEP }) do
            local ok, key = pcall(GetBindingKey, action)
            key = ok and S.Value(key) or nil
            if type(key) == "string" then return key end
        end
    end

    -- Set recruit key: the next key or mouse button you press becomes the
    -- recruit step's key (a click binding on the step button, saved with your
    -- key bindings). Out of combat only (the game refuses binding changes in
    -- combat). Escape cancels; left and right click are left alone.
    local MODIFIER_KEYS = { LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true,
        LMETA = true, RMETA = true }
    local MOUSE_KEYS = { MiddleButton = "BUTTON3", Button4 = "BUTTON4", Button5 = "BUTTON5" }
    local catcher

    local function WithModifiers(key)
        local out = key
        if IsShiftKeyDown and IsShiftKeyDown() then out = "SHIFT-" .. out end
        if IsControlKeyDown and IsControlKeyDown() then out = "CTRL-" .. out end
        if IsAltKeyDown and IsAltKeyDown() then out = "ALT-" .. out end
        return out
    end

    local function StopCatching(text)
        if catcher then catcher:Hide() end
        if text then ns.Print(text) end
        Guild.Changed()
    end

    -- Binds key to the recruit step; returns true, or false and why.
    function Guild.SetStepKey(key)
        if (InCombatLockdown and InCombatLockdown()) then return false, "not in combat (the game refuses key binding changes then)" end
        if type(SetBindingClick) ~= "function" or type(key) ~= "string" or key == "" then return false, "this client does not let addons bind keys" end
        local old = type(GetBindingAction) == "function" and S.Value(select(2, pcall(GetBindingAction, key))) or nil
        -- Your old recruit keys go, so one key does the step.
        for _, action in ipairs({ CLICK_ACTION, ns.BINDING_STEP }) do
            local keys = type(GetBindingKey) == "function" and { pcall(GetBindingKey, action) } or {}
            for i = 2, #keys do
                local k = S.Value(keys[i])
                if type(k) == "string" and k ~= key and type(SetBinding) == "function" then pcall(SetBinding, k) end
            end
        end
        if not pcall(SetBindingClick, key, ns.FRAME .. "RecruitStep", "LeftButton") then return false, "the game did not take the binding" end
        if type(SaveBindings) == "function" and type(GetCurrentBindingSet) == "function" then
            pcall(SaveBindings, S.Value(select(2, pcall(GetCurrentBindingSet))) or 1)
        end
        return true, (type(old) == "string" and old ~= "" and old ~= CLICK_ACTION) and old or nil
    end

    function Guild.CatchStepKey()
        if (InCombatLockdown and InCombatLockdown()) then
            ns.Print("set the recruit key out of combat (the game refuses key binding changes in combat).")
            return
        end
        if not catcher then
            -- Full screen, on top: it takes the next key or mouse button only.
            catcher = CreateFrame("Button", nil, UIParent)
            catcher:SetAllPoints(UIParent)
            catcher:SetFrameStrata("FULLSCREEN_DIALOG")
            catcher:EnableMouse(true)
            catcher:EnableKeyboard(true)
            if catcher.SetPropagateKeyboardInput then pcall(catcher.SetPropagateKeyboardInput, catcher, false) end
            if catcher.RegisterForClicks then catcher:RegisterForClicks("AnyDown") end
            catcher.text = catcher:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
            catcher.text:SetPoint("CENTER")
            local function Take(key)
                local ok, why = Guild.SetStepKey(WithModifiers(key))
                if ok then
                    StopCatching("recruit key set: " .. WithModifiers(key) .. " (one press = the next invite, else /who, else a whisper)"
                        .. (why and (". It replaced: " .. why) or "") .. ".")
                else
                    StopCatching("the recruit key was not set: " .. tostring(why) .. ".")
                end
            end
            catcher:SetScript("OnKeyDown", function(_, key)
                if key == "ESCAPE" then StopCatching("recruit key unchanged.") return end
                if MODIFIER_KEYS[key] then return end
                Take(key)
            end)
            catcher:SetScript("OnMouseDown", function(_, button)
                if MOUSE_KEYS[button] then Take(MOUSE_KEYS[button]) end
            end)
            catcher:SetScript("OnMouseWheel", function(_, delta)
                Take(delta > 0 and "MOUSEWHEELUP" or "MOUSEWHEELDOWN")
            end)
            if catcher.EnableMouseWheel then catcher:EnableMouseWheel(true) end
        end
        catcher.text:SetText("Press the key or mouse button for the recruit step\n|cff999999(Escape: cancel. Left / right click are not taken.)|r")
        catcher:Show()
    end
end

-- A mouse button went down anywhere (GLOBAL_MOUSE_DOWN). A press on a
-- window, or on a unit (targeting, looting, talking), is used already.
local function OnMouseDown(button)
    if not db().guildHandsFree then return end
    if button ~= "LeftButton" and button ~= "RightButton" then return end
    local world, over = OverWorld()
    if not world then Trace(button, over, "on a window, left alone") return end
    if S.Call(UnitExists, "mouseover") == true then Trace(button, over, "on a unit, left alone") return end
    local what, x = WatchedStep("mouse")
    Trace(button, over, Result(what, x))
    -- An action redrew already; otherwise the Recruit tab's status shows why not.
    if not what then Guild.Changed() end
end

-- Keys (guildHandsFreeKeys): a press of a key bound to moving or jumping is
-- a click too. A hidden frame sees the key and hands it on to the game
-- (SetPropagateKeyboardInput), so you still move; it listens only once
-- handing on is confirmed, or it would eat every key. The game does not
-- repeat OnKeyDown while a key is held: one press = one step.
local MOVE_BINDINGS = { "MOVEFORWARD", "MOVEBACKWARD", "STRAFELEFT", "STRAFERIGHT", "TURNLEFT", "TURNRIGHT", "JUMP" }
local keyFrame
local moveKeys = {}   -- [key] = true, read again when bindings change

local function ReadMoveKeys()
    wipe(moveKeys)
    if type(GetBindingKey) ~= "function" then return end
    for _, action in ipairs(MOVE_BINDINGS) do
        local keys = { pcall(GetBindingKey, action) }
        for i = 2, #keys do
            local k = S.Value(keys[i])
            if type(k) == "string" then moveKeys[k] = true end
        end
    end
end

function Guild.HandsFreeKeys() return moveKeys end

local function OnKeyDown(_, key)
    if not db().guildHandsFree or db().guildHandsFreeKeys == false then return end
    if type(key) ~= "string" or not moveKeys[key] then return end
    local what, x = WatchedStep("key")
    Trace(key, "key", Result(what, x))
    if not what then Guild.Changed() end
end

-- Out of combat only (the game refuses SetPropagateKeyboardInput in combat).
local function SetUpKeys()
    if keyFrame or (InCombatLockdown and InCombatLockdown()) then return end
    local f = CreateFrame("Frame", nil, UIParent)
    if not (f.SetPropagateKeyboardInput and f.EnableKeyboard) then return end
    if not pcall(f.SetPropagateKeyboardInput, f, true) then return end
    if f.GetPropagateKeyboardInput and S.Call(f.GetPropagateKeyboardInput, f) ~= true then return end
    f:SetScript("OnKeyDown", OnKeyDown)
    if not pcall(f.EnableKeyboard, f, true) then return end
    keyFrame = f
    ReadMoveKeys()
end

-- /talod guild handsfree why: what the last clicks did, and why not.
local function PrintPresses()
    if not db().guildHandsFree then ns.Print("Hands Free is off.") end
    local why = db().guildHandsFree and Guild.HandsFreeBlocked()
    if why then ns.Print("Hands Free is paused: " .. why .. ".") end
    for key in pairs(leftAlone) do ns.Print("left alone after the game blocked it " .. BLOCK_LIMIT .. " times in a row: " .. key) end
    if #presses == 0 then
        ns.Print("Hands Free has seen no click or key this session: the game sent it no GLOBAL_MOUSE_DOWN"
            .. (keyFrame and "" or " (and the key listener is not set up)") .. ".")
        return
    end
    ns.Print("Hands Free, the last clicks:")
    local now = GetTime()
    for _, p in ipairs(presses) do
        local how = p.over == "key" and ("key " .. tostring(p.button))
            or p.over == "bind" and "recruit key binding"
            or (tostring(p.button) .. " over " .. p.over)
        ns.Print(string.format("  %d s ago, %s: %s", math.floor(now - p.t), how, tostring(p.result)))
    end
end

-- A refusal fired during a hands-free step: that step was blocked. Never
-- turns Hands Free off; WatchedStep counts it.
local function OnBlocked(addon, fn)
    if stepping and addon == ADDON_NAME then stepping.blocked = S.Value(fn) or "?" end
end

function Guild.SetHandsFree(on)
    db().guildHandsFree = on and true or false
    handsFreeLast = nil
    if on then
        ns.Print("Hands Free on: a click on the open world (not on a window or a player)"
            .. (db().guildHandsFreeKeys ~= false and " or a press of your move / jump keys" or "") .. " sends the next invite, "
            .. "whisper or /who. Off in combat. What it did with your clicks: " .. ns.Cmd.Text("guild", "handsfree why"))
    end
    Guild.Changed()
end

---------------------------------------------------------------------------
-- Module
---------------------------------------------------------------------------
local function Tick()
    local now = GetTime()
    CheckHandsFreeWho(now)
    local passDone = false
    if passAt >= #PASS_UNITS and now - lastScan >= SCAN_INTERVAL then
        lastScan = now
        if db().guildRecruitScan and Guild.Mine() then passAt = 0 else passDone = true end
    end
    if passAt < #PASS_UNITS then passDone = StepPass(now, PASS_READS) end
    if passDone then
        -- Only the Recruit tab shows what the scan finds (GuildUI watches
        -- "guild.scan" there only); redrawing a big roster every second lags.
        ns.Data.Changed("guild.scan")
        if ns.GuildUI and not (ns.GuildUI.IsShown() and ns.GuildUI.LiveView()) then ns.GuildUI.RefreshMini() end
    end
    -- A delayed invite came due: its player is back on the list.
    local due = false
    for _, w in pairs(waiting) do
        if not w.shown and now >= w.at then w.shown, due = true, true end
    end
    for full, list in pairs(outgoing) do
        for i = #list, 1, -1 do
            if now - list[i].t >= (list[i].lost and LOST_SHOWN or OUTGOING_WAIT) then table.remove(list, i) due = true end
        end
        if #list == 0 then outgoing[full] = nil end
    end
    if due then Guild.Changed() end
    if rosterDirty and now - lastRosterRead >= ROSTER_READ_GAP then
        rosterDirty = false
        lastRosterRead = now
        local ok, changed = Guild.ReadRoster()
        if ok and changed then ns.Data.Changed("guild") end
    end
end

local function OnEvent(event, ...)
    if event == "ADDON_ACTION_FORBIDDEN" or event == "ADDON_ACTION_BLOCKED" then
        -- Fired inside our own call (see CallRankApi); other refusals are not ours to read.
        if calling and S.Value((...)) == ADDON_NAME then refused = event end
        if event == "ADDON_ACTION_BLOCKED" then OnBlocked(S.Value((...)), (select(2, ...))) end
        return
    end
    if event == "GUILD_ROSTER_UPDATE" or event == "PLAYER_GUILD_UPDATE" then
        rosterDirty = true
    elseif event == "PLAYER_ENTERING_WORLD" then
        local isLogin, isReload = ...
        if isLogin or isReload then Guild.RequestRoster() end
        rosterDirty = true
    elseif event == "WHO_LIST_UPDATE" then
        ReadWho()
    elseif event == "CHAT_MSG_SYSTEM" then
        -- Throttle lines are the Outbox's.
        if not Outbox.IsThrottleText((...)) then OnSystem((...)) end
    elseif event == "CHAT_MSG_WHISPER" then
        local text, sender, _, _, _, _, _, _, _, _, lineID, guid = ...
        Guild.AddChat(sender, text, false, lineID, guid)
    elseif event == "CHAT_MSG_WHISPER_INFORM" then
        local text, target = ...
        Guild.AddChat(target, text, true)
    elseif event == "CHAT_MSG_IGNORED" then
        -- A whisper to a player who ignores you: no echo comes, only this (name second).
        Guild.Undelivered(select(2, ...), "ignoring")
    elseif event == "GLOBAL_MOUSE_DOWN" then
        OnMouseDown((...))
    elseif event == "UPDATE_BINDINGS" then
        ReadMoveKeys()
    elseif event == "PLAYER_REGEN_ENABLED" then
        SetUpKeys()   -- a reload in combat left it for now
    elseif event == "GUILD_EVENT_LOG_UPDATE" then
        local ok, added = Guild.ReadEventLog()
        if ok and added > 0 then ns.Data.Changed("guild") end
    end
end

local function Slash(command, rest)
    if command ~= "guild" then return false end
    local arg, more = (rest or ""):match("^(%S*)%s*(.-)$")
    arg = (arg or ""):lower()
    if arg == "who" then
        Guild.Who()
    elseif arg == "next" then
        Guild.RecruitStep("bind")
    elseif arg == "key" then
        Guild.CatchStepKey()
    elseif arg == "handsfree" and more:lower() == "why" then
        PrintPresses()
    elseif arg == "handsfree" then
        Guild.SetHandsFree(not db().guildHandsFree)
        if not db().guildHandsFree then ns.Print("Hands Free off.") end
    elseif arg == "mini" then
        db().guildMiniShown = not db().guildMiniShown
        ns.Refresh()
    elseif arg == "invite" then
        local name = more ~= "" and more or nil
        local info
        if not name then
            local f = ns.ReadPlayerFacts("target")
            if f and f.name then
                name = FullName(f.name, f.realm)
                info = { name = f.name, classFile = f.classFile, level = f.level, race = f.race, src = "target" }
            end
        end
        if not name then
            ns.Print("target a player or give a name: " .. ns.Cmd.Text("guild") .. " invite <name>")
        else
            Guild.Invite(FullName(name), info)
        end
    elseif arg == "pace" then
        if more:lower() == "reset" then Outbox.ResetBurst() end
        Outbox.Status()
    elseif arg == "check" then
        PrintCheck()
    elseif arg == "roster" then
        Guild.RequestRoster()
        if ns.GuildUI then ns.GuildUI.Show("roster") end
    elseif ns.GuildUI then
        local views = { recruit = "recruit", invited = "invited", replies = "replies", roster = "roster", activity = "activity", recruiters = "recruiters",
            promote = "promote", promotions = "promote", log = "log", members = "members", sharing = "sharing" }
        ns.GuildUI.Toggle(views[arg])
    end
    return true
end

ns.RegisterModule("Guild", {
    defaults = {
        guildRecruitScan = true,
        guildWhisper = true,
        guildDelayedInvite = true,
        guildHandsFree = false,
        guildHandsFreeKeys = true,
        guildWhoZone = true,
        guildRecruitMinLevel = 1,
        guildRecruitMaxLevel = 60,
        guildRecruitHideClass = {},
        guildRecruitHideScript = {},
        guildHideChat = true,
        guildMiniShown = false,
        guildReplyNotice = true,
        guildReinviteDays = 7,
        guildInactiveDays = 30,
        -- Rank APIs the game forbade to addons on this build: { build, promote, demote, setRank }.
        guildRefused = {},
        guild = {},
    },
    init = function()
        Guild.Messages()
        RegisterChatFilters()
        rosterDirty = true
        SetUpKeys()
    end,
    tick = Tick,
    events = { "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE", "PLAYER_ENTERING_WORLD", "WHO_LIST_UPDATE",
        "CHAT_MSG_SYSTEM", "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM", "CHAT_MSG_IGNORED", "GUILD_EVENT_LOG_UPDATE",
        "ADDON_ACTION_FORBIDDEN", "ADDON_ACTION_BLOCKED", "GLOBAL_MOUSE_DOWN",
        "UPDATE_BINDINGS", "PLAYER_REGEN_ENABLED" },
    onEvent = OnEvent,
    refresh = function() Guild.Changed() end,
    slash = Slash,
})
