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
                if r.whisper and not r.unsent then waiting[full] = { at = 0 } else r.status = "uninvited" end
            end
        end
    end
    return g, key
end

local MyCharName = function() return Guild.Me() end

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

-- Classes of your faction (vanilla: paladins Alliance, shamans Horde); all
-- nine when the faction cannot be read.
local CLASSES = { "WARRIOR", "PALADIN", "SHAMAN", "HUNTER", "ROGUE", "PRIEST", "MAGE", "WARLOCK", "DRUID" }
function Guild.Classes()
    local faction = S.Call(UnitFactionGroup, "player")
    local out = {}
    for _, c in ipairs(CLASSES) do
        if not ((faction == "Alliance" and c == "SHAMAN") or (faction == "Horde" and c == "PALADIN")) then out[#out + 1] = c end
    end
    return out
end

-- A hidden class drops its players; a player whose class is unknown only
-- shows while no class is hidden.
function Guild.ClassOK(classFile)
    local hidden = db().guildRecruitHideClass or {}
    if classFile then return not hidden[classFile] end
    return next(hidden) == nil
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
    for full, c in pairs(candidates) do
        local level, classFile = c.level, c.classFile
        if c.confirmed and (type(level) ~= "number" or (level >= lo and level <= hi))
            and (classFile and not hidden[classFile] or (not classFile and not anyHidden))
            and not Guild.Blocked(full, g) then
            c.here = c.src ~= "who" and now - c.last <= LIVE_SECONDS
            out[#out + 1] = c
        end
    end
    if g then
        for full, w in pairs(waiting) do
            local r = g.recruits[full]
            if not r or r.status ~= "inviting" or g.members[full] then
                waiting[full] = nil
            elseif now >= w.at then
                local c = candidates[full]
                out[#out + 1] = { full = full, name = r.name or Guild.Short(full), classFile = r.classFile, level = r.level,
                    race = r.race, zone = r.zone, src = c and c.src or r.src or "?", last = c and c.last or now,
                    here = c ~= nil and c.src ~= "who" and now - c.last <= LIVE_SECONDS, ready = true }
            end
        end
    end
    table.sort(out, function(a, b)
        if (a.ready == true) ~= (b.ready == true) then return b.ready == true end
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

-- Delayed invite: the recruit is back on the list, to click for the invite,
-- delay seconds from now (INVITE_DELAY after the opener went out). The game
-- takes a guild invite only inside a click, so it never goes on its own.
local function MarkReady(full, delay)
    local r = Recruit(full)
    if not r or r.status ~= "inviting" then return end
    waiting[full] = { at = GetTime() + (delay or 0) }
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
        onSent = function()
            OpenerSent(full, text)
            if delayed then MarkReady(full, INVITE_DELAY) end
        end,
        -- The game refused the whisper: the invite may go at once.
        onDropped = function(why)
            if delayed and why == "failed" then MarkReady(full, 0) end
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
local function InviteNow(full, target, info)
    local invited, why = Outbox.GuildInvite(target)
    if not invited then
        -- A double click while the client lags: the first one went.
        if why ~= "repeat" then InviteFailed(full) end
        return false
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
    if not delayed then return InviteNow(full, target, info) end
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
    Guild.Changed()
end

function Guild.Recruits()
    local g = Guild.Data()
    local out = {}
    if not g then return out end
    for full, r in pairs(g.recruits) do out[#out + 1] = { full = full, r = r } end
    table.sort(out, function(a, b) return (a.r.t or 0) > (b.r.t or 0) end)
    return out
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

local function ReadWho()
    if not whoPending or GetTime() - whoPending.t > WHO_WAIT then return end
    local _, count, info = WhoAPI()
    local n = count and S.Call(count) or 0
    local added, guilded = 0, 0
    local now = GetTime()
    for i = 1, n do
        local res = { pcall(info, i) }
        local name, guild, level, race, classFile, zone
        local t = res[1] and S.Value(res[2])
        if type(t) == "table" then
            name, guild, level = S.Value(t.fullName), S.Value(t.fullGuildName), S.Value(t.level)
            race, classFile, zone = S.Value(t.raceStr), S.Value(t.filename), S.Value(t.area)
        elseif res[1] then
            -- Older global: name, guild, level, race, class, zone, classFile.
            name, guild, level, race = S.Value(res[2]), S.Value(res[3]), S.Value(res[4]), S.Value(res[5])
            zone, classFile = S.Value(res[7]), S.Value(res[8])
        end
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
            if e.text == text or text == HIDDEN_TEXT then table.remove(list, i) break end
        end
        if #list == 0 then outgoing[full] = nil end
    end
    if not AddLine(r, text, me) then return end
    while #r.chat > MAX_CHAT do table.remove(r.chat, 1) end
    r.last = time()
    if not me then
        r.replied = time()
        r.unread = (r.unread or 0) + 1
    end
    ns.Data.Changed("guild")
    if ns.GuildUI and ns.GuildUI.OnChat then ns.GuildUI.OnChat(full, me) end
end

-- Recruits who wrote back, newest conversation first (your opening
-- whisper alone does not make a conversation).
function Guild.Conversations()
    local out = {}
    for _, x in ipairs(Guild.Recruits()) do
        local theirs = false
        for _, line in ipairs(x.r.chat or {}) do if not line.me then theirs = true break end end
        if theirs then out[#out + 1] = x end
    end
    table.sort(out, function(a, b) return (a.r.last or 0) > (b.r.last or 0) end)
    return out
end

-- Read on every redraw: only the records with unread lines are looked at
-- (Conversations would list and sort every recruit ever kept).
function Guild.Unread()
    local g = Guild.Data()
    local n = 0
    for _, r in pairs(g and g.recruits or {}) do
        if (r.unread or 0) > 0 then
            for _, line in ipairs(r.chat or {}) do
                if not line.me then n = n + r.unread break end
            end
        end
    end
    return n
end

function Guild.MarkRead(full)
    local r = Recruit(full)
    if r and r.unread then
        r.unread = nil
        if ns.GuildUI and ns.GuildUI.UpdateNotice then ns.GuildUI.UpdateNotice() end
    end
end

function Guild.ClearChat(full)
    local r = Recruit(full)
    if r then r.chat, r.unread = nil, nil end
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
-- yet) | "lost" (the throttle dropped it) }.
function Guild.Outgoing(full)
    local out = {}
    if type(full) ~= "string" then return out end
    for _, e in ipairs(outgoing[full] or {}) do
        out[#out + 1] = { text = e.text, state = e.lost and "lost" or "sending" }
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
    table.sort(out, function(a, b)
        if (a.m.rank or 99) ~= (b.m.rank or 99) then return (a.m.rank or 99) < (b.m.rank or 99) end
        return a.full < b.full
    end)
    return out
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

local function SameEvent(e, k, a, b, t)
    return e.k == k and e.a == a and e.b == b and math.abs(e.t - t) <= Tolerance(math.max(0, time() - math.min(e.t, t)))
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
    for i = 1, n do
        local k, p1, p2, rank, y, mo, d, h = S.CallMulti(8, info, i)
        if type(k) == "string" and type(p1) == "string" and p1 ~= "" then
            local t = now - (OfflineSeconds(y, mo, d, h) or 0)
            local a, b = FullName(p1), (type(p2) == "string" and p2 ~= "") and FullName(p2) or nil
            local dup = false
            for j = #g.events, math.max(1, #g.events - 400), -1 do
                if SameEvent(g.events[j], k, a, b, t) then dup = true break end
            end
            if not dup then
                g.events[#g.events + 1] = { t = t, k = k, a = a, b = b, rank = type(rank) == "string" and rank or nil }
                added = added + 1
            end
        end
    end
    if added > 0 then table.sort(g.events, function(x, y2) return x.t < y2.t end) end
    g.eventsRead = now
    g.eventsSince = g.eventsSince or (g.events[1] and g.events[1].t) or now
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

local function DataKey(g)
    local n, sum = 0, 0
    for _, r in pairs(g.recruits) do
        n = n + 1
        if r.invited and r.by then sum = sum + r.invited end
    end
    local e, l = g.events or {}, g.log
    return table.concat({ tostring(g), #e, e[#e] and e[#e].t or 0, #l, l[#l] and l[#l].t or 0,
        n, sum, g.lastRead or 0 }, ":")
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
    local function Add(list, who, entry)
        list[who] = list[who] or {}
        for _, e in ipairs(list[who]) do
            if math.abs(e.t - entry.t) <= Tolerance(math.max(0, time() - entry.t)) then
                e.by = e.by or entry.by
                return
            end
        end
        table.insert(list[who], entry)
    end
    for _, e in ipairs(g.events or {}) do
        if e.k == "invite" and e.b then Add(invites, e.b, { t = e.t, by = e.a })
        elseif e.k == "join" then Add(joins, e.a, { t = e.t })
        elseif e.k == "quit" then Add(leaves, e.a, { t = e.t, how = "quit" })
        elseif e.k == "remove" and e.b then Add(leaves, e.b, { t = e.t, how = "removed", by = e.a }) end
    end
    for _, e in ipairs(g.log) do
        if e.k == "join" then Add(joins, e.n, { t = e.t })
        elseif e.k == "leave" then Add(leaves, e.n, { t = e.t, how = "quit" })
        elseif e.k == "kick" then Add(leaves, e.n, { t = e.t, how = "removed", by = e.by }) end
    end
    for full, rec in pairs(g.recruits) do
        if rec.invited and rec.by then Add(invites, full, { t = rec.invited, by = rec.by }) end
    end
    local out = {}
    for who, list in pairs(joins) do
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
    for _, e in ipairs(g.events or {}) do
        if e.k == "invite" and e.b then Stat(e.a).invited[e.b] = true end
    end
    for full, rec in pairs(g.recruits) do
        if rec.invited and rec.by then Stat(rec.by).invited[full] = true end
    end
    local joinsOf = {}
    for _, m in ipairs(Guild.Memberships()) do
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
    if not fn or not pcall(fn, Target(full)) then
        ns.Print("the game did not accept the promotion of " .. Guild.Short(full) .. ".")
        return false
    end
    -- The roster update that follows logs the change.
    Guild.RequestRoster()
    return true
end

---------------------------------------------------------------------------
-- Module
---------------------------------------------------------------------------
local function Tick()
    local now = GetTime()
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
        guildWhoZone = true,
        guildRecruitMinLevel = 1,
        guildRecruitMaxLevel = 60,
        guildRecruitHideClass = {},
        guildHideChat = true,
        guildMiniShown = false,
        guildReplyNotice = true,
        guildReinviteDays = 7,
        guildInactiveDays = 30,
        guild = {},
    },
    init = function()
        Guild.Messages()
        RegisterChatFilters()
        rosterDirty = true
    end,
    tick = Tick,
    events = { "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE", "PLAYER_ENTERING_WORLD", "WHO_LIST_UPDATE",
        "CHAT_MSG_SYSTEM", "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM", "GUILD_EVENT_LOG_UPDATE" },
    onEvent = OnEvent,
    refresh = function() Guild.Changed() end,
    slash = Slash,
})
