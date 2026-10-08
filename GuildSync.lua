-- TALOD - Guild sharing: members share what they agreed to with their
-- officers, and officers share the guild's promotion rules with members.
--
-- Consent: one Yes / No per category (Sync.CATEGORIES), nil (never
-- answered) is No. Nothing about a player leaves their client before their
-- Yes, and a No later tells the officers' addons to drop what they have.
--
-- What comes back is the member's addon's word, never a fact: values that
-- cannot be true are dropped and said so, values the server's own data
-- (roster, guild event log) contradicts are kept and marked (Sync.Check).
--
-- Officers: a rank counts as an officer rank when the guild master said so
-- (O1, accepted only from the member at rank 0 in your own roster), else
-- when the game's rank permissions allow officer chat, promoting or
-- removing members, else ranks 0 and 1. A sender's rank always comes from
-- your own roster read, never from the message: a forged message cannot
-- make anyone an officer.
--
-- Transport: addon messages with the prefix
-- below, one sent every SEND_GAP seconds from a queue; longer ones in
-- pieces "C<id>:<i>:<n>:<piece>". A member's data goes by WHISPER to the
-- officer who asked, never to the whole guild. Requests are one per click.
--
--   Q1                     officer -> GUILD: please send what you share
--   A0~cat,cat             member -> officer: the categories I share (empty: none)
--   A1~cat~payload         member -> officer: one category's data
--   A2~cat=state:since,... member -> officer: the tamper seal of each shared
--                          category (Store.lua: ok / edited / new / unknown, and
--                          when the seal chain began); sent after the A1s
--   O1~0,1                 guild master -> GUILD: officer ranks (empty: back to permissions)
--   Q0                     member -> GUILD: who are the officers? (the guild master answers)
--   R1~t:on:lvl:days:act:rec;...   officer -> GUILD: promotion rules
--   Q2                     member -> GUILD: the promotion rules, please

local ADDON_NAME, ns = ...
local S = ns.Secret
local Guild = ns.Guild

local Sync = {}
ns.GuildSync = Sync

local PREFIX = ns.COMM_PREFIX
local SEND_GAP = 1.2
local CHUNK = 220
local MAX_PIECES = 30
local PIECE_TTL = 60
local MAX_QUEUE = 80
local ANSWER_GAP = 60        -- answer one officer (or one Q0 / Q2) at most this often
local ASK_GAP = 60           -- an officer's request at most this often
local RECRUIT_DAYS = 30      -- recruiting shared: the last 30 days
local ACTIVITY_KEEP = 60     -- days of play time kept

Sync.PREFIX = PREFIX
Sync.CATEGORIES = {
    { key = "recruiting", label = "My recruiting",
        text = "Who you invited with " .. ns.NAME .. " in the last " .. RECRUIT_DAYS .. " days and what happened (joined, declined, replied)." },
    { key = "alts", label = "My other characters",
        text = "Your other characters in this guild that you have played with " .. ns.NAME .. " on this account." },
    { key = "prof", label = "Level and professions", text = "This character's level and profession skills." },
    { key = "activity", label = "Play time",
        text = "Hours played on this character in the last 7 and 30 days, counted by " .. ns.NAME .. " while you play." },
}
local CAT = {}
for _, c in ipairs(Sync.CATEGORIES) do CAT[c.key] = c end

-- Another module's category (at file load): { key, label, text, payload()
-- -> string, parse(payload) -> value, received(sender, value), dropped(sender) }.
-- It gets its own Yes / No line like the others: never a category without one.
function Sync.AddCategory(def)
    if type(def) ~= "table" or type(def.key) ~= "string" or CAT[def.key] or not def.label or not def.text then return false end
    Sync.CATEGORIES[#Sync.CATEGORIES + 1] = def
    CAT[def.key] = def
    return true
end

local queue, pieces, lastSend, msgId = {}, {}, -math.huge, 0
local lastAnswer = {}        -- [sender or "Q0"/"Q2"] = GetTime()
local lastAsk = -math.huge
local askedNotice = false
local activityAt = nil

local function db() return ns.DB() end

local function Me() return Guild.Me() end

-- Text that goes on the wire: no separators, no escape codes.
local function Clean(v) return (tostring(v or ""):gsub("[~;:,|\r\n]", "")) end
Sync.Clean = Clean

local function Split(s, sep)
    local out = {}
    if s == nil or s == "" then return out end
    for piece in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = piece end
    return out
end
Sync.Split = Split

---------------------------------------------------------------------------
-- Consent
---------------------------------------------------------------------------
function Sync.Consent(key)
    local c = db().guildShare
    return type(c) == "table" and c[key] or nil
end

function Sync.Unanswered()
    for _, c in ipairs(Sync.CATEGORIES) do
        if Sync.Consent(c.key) == nil then return true end
    end
    return false
end

function Sync.Shared()
    local out = {}
    for _, c in ipairs(Sync.CATEGORIES) do
        if Sync.Consent(c.key) == true then out[#out + 1] = c.key end
    end
    return out
end

local Send
-- A No (or Yes) goes out at once so officers' addons drop what they hold.
function Sync.SetConsent(key, value)
    if not CAT[key] then return end
    db().guildShare = type(db().guildShare) == "table" and db().guildShare or {}
    local old = db().guildShare[key]
    db().guildShare[key] = value
    if old == true and value ~= true and Guild.Mine() then
        Send("GUILD", "A0~" .. table.concat(Sync.Shared(), ","), "A0")
    end
    ns.Refresh()
end

---------------------------------------------------------------------------
-- Officers
---------------------------------------------------------------------------
local function RankFlags(rank) return Guild.RankFlags(rank) end

-- How officer ranks are decided now: "gm" (set by the guild master),
-- "permissions" or "default" (ranks 0 and 1).
function Sync.OfficerSource()
    local g = Guild.Data()
    if g and type(g.officerRanks) == "table" then return "gm" end
    if RankFlags(0) then return "permissions" end
    return "default"
end

function Sync.RankIsOfficer(rank)
    if type(rank) ~= "number" then return false end
    if rank == 0 then return true end
    local g = Guild.Data()
    if g and type(g.officerRanks) == "table" then return g.officerRanks[rank] == true end
    local f = RankFlags(rank)
    if f then
        -- 3 officer chat listen, 5 promote, 8 remove (the guild control flags).
        return S.Value(f[3]) == true or S.Value(f[5]) == true or S.Value(f[8]) == true
    end
    return rank <= 1
end

-- A player is an officer when your own roster puts them at an officer rank.
function Sync.IsOfficer(full)
    local g = Guild.Data()
    local m = g and g.members[full]
    return m ~= nil and not m.missing and Sync.RankIsOfficer(m.rank)
end

function Sync.IAmOfficer()
    local _, _, rank = Guild.Mine()
    return Sync.RankIsOfficer(rank)
end

function Sync.IAmGM()
    local _, _, rank = Guild.Mine()
    return rank == 0
end

-- Guild master only: which ranks count as officers (nil: the game's permissions).
function Sync.SetOfficerRanks(ranks)
    if not Sync.IAmGM() then return false end
    local g = Guild.Data()
    if ranks then
        g.officerRanks = {}
        for r in pairs(ranks) do if type(r) == "number" and r > 0 then g.officerRanks[r] = true end end
    else
        g.officerRanks = nil
    end
    g.officerRanksT = time()
    Sync.SendOfficerRanks()
    ns.Refresh()
    return true
end

function Sync.SendOfficerRanks()
    local g = Guild.Data()
    if not g or not Sync.IAmGM() then return end
    local list = {}
    for r in pairs(g.officerRanks or {}) do list[#list + 1] = r end
    table.sort(list)
    Send("GUILD", "O1~" .. (g.officerRanks and ("0," .. table.concat(list, ",")) or ""), "O1")
end

---------------------------------------------------------------------------
-- Transport
---------------------------------------------------------------------------
local function API()
    local C = C_ChatInfo
    if type(C) == "table" and type(C.SendAddonMessage) == "function" then return C end
end

function Send(dist, msg, key, target)
    if not API() or not Guild.Mine() then return false end
    local parts = { msg }
    if #msg > 250 then
        parts = {}
        msgId = (msgId + 1) % 1000
        local n = math.ceil(#msg / CHUNK)
        if n > MAX_PIECES then return false end
        for i = 1, n do parts[i] = "C" .. msgId .. ":" .. i .. ":" .. n .. ":" .. msg:sub((i - 1) * CHUNK + 1, i * CHUNK) end
        key = nil
    end
    for _, part in ipairs(parts) do
        local replaced = false
        if key then
            for _, item in ipairs(queue) do
                if item.key == key and item.target == target then item.msg, replaced = part, true end
            end
        end
        if not replaced then
            if #queue >= MAX_QUEUE then table.remove(queue, 1) end
            queue[#queue + 1] = { dist = dist, msg = part, key = key, target = target }
        end
    end
    return true
end
Sync.Send = function(dist, msg, key, target) return Send(dist, msg, key, target) end

local function Pump()
    local now = GetTime()
    if not queue[1] or now - lastSend < SEND_GAP then return end
    local item = table.remove(queue, 1)
    lastSend = now
    local C = API()
    if C and Guild.Mine() then pcall(C.SendAddonMessage, PREFIX, item.msg, item.dist, item.target) end
end
Sync.Pump = Pump
function Sync.QueueSize() return #queue end

---------------------------------------------------------------------------
-- What this player shares
---------------------------------------------------------------------------
local function CharKey() return Me() end

local function Payload(key)
    if key == "recruiting" then
        local out, since = {}, time() - RECRUIT_DAYS * 86400
        for _, x in ipairs(Guild.Recruits()) do
            local r = x.r
            if r.invited and r.invited >= since and #out < 100 then
                out[#out + 1] = Clean(x.full) .. ":" .. r.invited .. ":" .. Clean(r.status or "?") .. ":" .. (r.replied and "1" or "0")
            end
        end
        return table.concat(out, ";")
    elseif key == "alts" then
        local g = Guild.Data()
        local me, seen, out = Me(), {}, {}
        local names = type(db().guildMyNames) == "table" and db().guildMyNames or {}
        for _, store in ipairs({ db().skills, db().gear, db().economy, names }) do
            for charKey in pairs(type(store) == "table" and store or {}) do
                local full = names[charKey]
                if not full then
                    local name, realm = tostring(charKey):match("^([^%-]+)%-?(.*)$")
                    full = name and Guild.FullName(name, realm ~= "" and realm or nil)
                end
                if full and full ~= me and not seen[full] and g.members[full] then
                    seen[full] = true
                    out[#out + 1] = Clean(full)
                end
            end
        end
        table.sort(out)
        return table.concat(out, ";")
    elseif key == "prof" then
        local out = { tostring(S.Call(UnitLevel, "player") or "") }
        local c = ns.Skills and ns.Skills.Char and ns.Skills.Char()
        for name, s in pairs(c and c.current or {}) do
            if type(s) == "table" and (s.cat == "Professions" or s.cat == "Secondary Skills") and type(s.rank) == "number" then
                out[#out + 1] = Clean(name) .. ":" .. s.rank .. ":" .. tostring(s.max or "")
            end
        end
        table.sort(out, function(a, b) if a:find(":") and b:find(":") then return a < b end return not a:find(":") end)
        return table.concat(out, ";")
    elseif key == "activity" then
        local h7, h30, days = Sync.PlayTime()
        return string.format("%.1f:%.1f:%d", h7, h30, days)
    elseif CAT[key] and CAT[key].payload then
        return CAT[key].payload() or ""
    end
    return ""
end
Sync.Payload = Payload

-- Hours played on this character in the last 7 and 30 days, and days played of the 30.
function Sync.PlayTime()
    local a = db().guildActivity
    local mine = type(a) == "table" and a[CharKey() or ""] or {}
    local h7, h30, days = 0, 0, 0
    for i = 0, 29 do
        local s = mine[date("%Y-%m-%d", time() - i * 86400)] or 0
        h30 = h30 + s / 3600
        if i < 7 then h7 = h7 + s / 3600 end
        if s > 0 then days = days + 1 end
    end
    return h7, h30, days
end

local function TrackActivity()
    local now = GetTime()
    if not activityAt then
        activityAt = now
        -- This character's full name, for the alts of the others; play time
        -- counted under the short form before names were read in full moves over.
        local me, short = Me(), ns.Gear and ns.Gear.CharKey()
        if me and short then
            db().guildMyNames = type(db().guildMyNames) == "table" and db().guildMyNames or {}
            db().guildMyNames[short] = me
            local a = db().guildActivity
            local old = type(a) == "table" and Guild.Short(me):match("^(%S+)") .. "-" .. (Guild.Split(me) and select(2, Guild.Split(me)) or "")
            if old and old ~= me and a[old] and not a[me] then a[me], a[old] = a[old], nil end
        end
        return
    end
    local elapsed = now - activityAt
    if elapsed < 60 then return end
    activityAt = now
    local key = CharKey()
    if not key then return end
    local a = db().guildActivity
    if type(a) ~= "table" then a = {} db().guildActivity = a end
    a[key] = a[key] or {}
    local today = date("%Y-%m-%d")
    a[key][today] = (a[key][today] or 0) + math.min(elapsed, 300)
    local oldest = date("%Y-%m-%d", time() - ACTIVITY_KEEP * 86400)
    for day in pairs(a[key]) do if day < oldest then a[key][day] = nil end end
end

-- Nothing shared: no answer at all (not even "nothing"), so a player who
-- never said Yes does not show up as running the addon.
local function Answer(officer)
    local shared = Sync.Shared()
    if #shared == 0 then return end
    Send("WHISPER", "A0~" .. table.concat(shared, ","), "A0", officer)
    for _, key in ipairs(shared) do Send("WHISPER", "A1~" .. key .. "~" .. Payload(key), "A1" .. key, officer) end
    local seals = {}
    for _, key in ipairs(shared) do
        local state, since = ns.Store.SealState(key)
        if state then seals[#seals + 1] = key .. "=" .. state .. ":" .. string.format("%d", since or 0) end
    end
    if #seals > 0 then Send("WHISPER", "A2~" .. table.concat(seals, ","), "A2", officer) end
end

---------------------------------------------------------------------------
-- Officers: asking, and what came back
---------------------------------------------------------------------------
-- One request per click.
function Sync.RequestMembers()
    if not Sync.IAmOfficer() then
        ns.Print("only officers can ask members for their shared information.")
        return false
    end
    local wait = ASK_GAP - (GetTime() - lastAsk)
    if wait > 0 then
        ns.Print(string.format("asked a moment ago: answers are still coming (again in %d s).", math.ceil(wait)))
        return false
    end
    lastAsk = GetTime()
    return Send("GUILD", "Q1", "Q1")
end

local PARSE = {
    recruiting = function(p)
        local out = {}
        for _, item in ipairs(Split(p, ";")) do
            local f = Split(item, ":")
            if f[1] and f[1] ~= "" then
                out[#out + 1] = { full = f[1], t = tonumber(f[2]), status = f[3], replied = f[4] == "1" }
            end
        end
        return out
    end,
    alts = function(p)
        local out = {}
        for _, a in ipairs(Split(p, ";")) do if a ~= "" then out[#out + 1] = a end end
        return out
    end,
    prof = function(p)
        local f = Split(p, ";")
        local out = { level = tonumber(f[1]), skills = {} }
        for i = 2, #f do
            local s = Split(f[i], ":")
            if s[1] and s[1] ~= "" then out.skills[#out.skills + 1] = { name = s[1], rank = tonumber(s[2]), max = tonumber(s[3]) } end
        end
        return out
    end,
    activity = function(p)
        local f = Split(p, ":")
        return { h7 = tonumber(f[1]), h30 = tonumber(f[2]), days = tonumber(f[3]) }
    end,
}

---------------------------------------------------------------------------
-- What came back: checked, never trusted
---------------------------------------------------------------------------
local SKILL_CAP = 300
-- Profession ranks need a character level to train ([VERIFY] on Forever):
-- Journeyman 10, Expert 20, Artisan 35.
local RANK_LEVEL = { { 75, 10 }, { 150, 20 }, { 225, 35 } }
local RECRUIT_STATUS = { invited = true, inviting = true, uninvited = true, joined = true, declined = true, guilded = true,
    pending = true, notfound = true, skipped = true, ["?"] = true }
local SEAL_STATES = { ok = true, edited = true, new = true, unknown = true }
Sync.SKILL_CAP = SKILL_CAP

local function MaxLevel()
    local n = type(GetMaxPlayerLevel) == "function" and S.Call(GetMaxPlayerLevel) or nil
    return type(n) == "number" and n or 60
end

local function Whole(n, lo, hi) return type(n) == "number" and n == math.floor(n) and n >= lo and n <= hi end

-- Did the guild's own records (the game's event log, your roster log) see
-- this? true / false, or nil when they do not reach back that far.
local function GuildSaw(g, kind, who, by, t)
    if type(g.eventsSince) ~= "number" or not g.eventsRead or g.eventsSince > t - 3600 then return nil end
    local from = t - 2 * 86400
    for _, e in ns.Guild.Events(g) do
        if e.t >= from then
            if kind == "invite" and e.k == "invite" and e.b == who and e.a == by then return true end
            if kind == "join" and e.k == "join" and e.a == who then return true end
        end
    end
    if kind == "join" then
        for _, e in ipairs(g.log or {}) do
            if e.k == "join" and e.n == who and e.t >= from then return true end
        end
    end
    return false
end

-- A received category, checked: returns the value to keep (nil: nothing
-- usable) and the problems found ({ text, ... } or nil).
function Sync.Check(key, v, sender, g)
    local bad = {}
    local function Bad(text) bad[#bad + 1] = text end
    local m = g and g.members[sender]
    local now = time()
    if v == nil then return nil, nil end

    if key == "prof" then
        if v.level ~= nil and not Whole(v.level, 1, MaxLevel()) then
            Bad("level " .. tostring(v.level) .. " is not a level")
            v.level = nil
        end
        if v.level and m and type(m.level) == "number" and math.abs(v.level - m.level) > 1 then
            Bad("says level " .. v.level .. ", the guild roster says " .. m.level)
        end
        local level = (m and type(m.level) == "number" and m.level) or v.level
        local kept = {}
        for _, s in ipairs(v.skills or {}) do
            local why
            if not Whole(s.rank, 0, SKILL_CAP) then
                why = "rank " .. tostring(s.rank) .. " is not possible"
            elseif s.max ~= nil and (not Whole(s.max, 1, SKILL_CAP) or s.max < s.rank) then
                why = "rank " .. s.rank .. " of " .. tostring(s.max) .. " is not possible"
            elseif level then
                for _, r in ipairs(RANK_LEVEL) do
                    if s.rank > r[1] and level < r[2] then why = "rank " .. s.rank .. " needs level " .. r[2] .. " to train" break end
                end
            end
            if why then Bad(tostring(s.name) .. ": " .. why) else kept[#kept + 1] = s end
        end
        v.skills = kept

    elseif key == "activity" then
        local h7, h30, days = v.h7, v.h30, v.days
        local ok = type(h7) == "number" and type(h30) == "number" and Whole(days, 0, 30)
            and h7 >= 0 and h7 <= 7 * 24 and h30 >= 0 and h30 <= 30 * 24
            and h7 <= h30 + 0.1 and h30 <= days * 24 + 0.1 and (h7 == 0 or days >= 1)
        if not ok then
            Bad(string.format("impossible play time (%s h in 7 days, %s h in 30 days, %s days)", tostring(h7), tostring(h30), tostring(days)))
            v = nil
        end

    elseif key == "recruiting" then
        local kept, unconfirmed = {}, 0
        for _, r in ipairs(v) do
            if #kept >= 100 then Bad("more than 100 recruits") break end
            if type(r.t) ~= "number" or r.t > now + 300 or r.t < now - (RECRUIT_DAYS + 1) * 86400 then
                Bad(Guild.Short(r.full) .. ": invite time not possible")
            elseif not RECRUIT_STATUS[r.status] then
                Bad(Guild.Short(r.full) .. ": unknown status " .. tostring(r.status))
            else
                local invited = GuildSaw(g, "invite", r.full, sender, r.t)
                if r.status == "joined" then
                    local member = g.members[r.full]
                    local joined = GuildSaw(g, "join", r.full, nil, r.t)
                    if member and not member.missing then joined = true end
                    r.check = joined and "seen" or (joined == false and "missing") or nil
                elseif invited ~= nil then
                    r.check = invited and "seen" or "missing"
                end
                if r.check == "missing" then unconfirmed = unconfirmed + 1 end
                kept[#kept + 1] = r
            end
        end
        if unconfirmed > 0 then Bad(unconfirmed .. " recruit" .. (unconfirmed == 1 and "" or "s") .. " not in the guild's own log") end
        v = kept

    elseif key == "alts" then
        local kept = {}
        for _, full in ipairs(v) do
            if g.members[full] then kept[#kept + 1] = full else Bad(Guild.Short(full) .. " is not in this guild") end
        end
        v = kept
    end
    return v, #bad > 0 and bad or nil
end

-- Shared data of each member, newest first: { full, d = { t, cats, recruiting, alts, prof, activity } }.
function Sync.Members()
    local g = Guild.Data()
    local out = {}
    for full, d in pairs(g and g.shared or {}) do out[#out + 1] = { full = full, d = d } end
    table.sort(out, function(a, b) return (a.d.t or 0) > (b.d.t or 0) end)
    return out
end

---------------------------------------------------------------------------
-- Promotion rules from officers to members
---------------------------------------------------------------------------
function Sync.SendRules()
    local g = Guild.Data()
    if not g or not Sync.IAmOfficer() then return end
    local out = {}
    for target, r in pairs(g.rules) do
        if type(target) == "number" then
            out[#out + 1] = table.concat({ target, r.on and 1 or 0, r.level or 1, r.days or 0, r.active or 0, r.recruits or 0 }, ":")
        end
    end
    table.sort(out)
    Send("GUILD", "R1~" .. table.concat(out, ";"), "R1")
end

-- Rule buttons get clicked several times in a row: the rules go out once
-- the clicking stops (RULES_SETTLE seconds).
local RULES_SETTLE = 5
local rulesChangedAt
function Sync.RulesChanged() rulesChangedAt = GetTime() end

-- The rules members received: { by, t, rules = { [target] = rule } } or nil.
function Sync.GuildRules()
    local g = Guild.Data()
    return g and g.sharedRules or nil
end

-- Your own progress to the next rank under the rules officers shared:
-- target rank, rule, and the reason it is not met yet (nil = met).
function Sync.MyProgress()
    local g = Guild.Data()
    local shared = Sync.GuildRules()
    local me = Me()
    local m = g and g.members[me]
    if not (m and shared and type(m.rank) == "number") then return nil end
    local target = m.rank - 1
    local rule = shared.rules[target]
    if not rule then return target, nil, nil end
    return target, rule, Guild.RuleCheck(m, rule, me)
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------
local Handle

local function Assemble(sender, text)
    local id, i, n, piece = text:match("^C(%d+):(%d+):(%d+):(.*)$")
    i, n = tonumber(i), tonumber(n)
    if not (id and i and n) or n > MAX_PIECES or i < 1 or i > n then return end
    local key = sender .. "#" .. id
    local p = pieces[key]
    if not p or p.n ~= n then
        p = { n = n, got = 0, parts = {}, t = GetTime() }
        pieces[key] = p
    end
    if not p.parts[i] then p.parts[i], p.got = piece, p.got + 1 end
    if p.got == n then
        pieces[key] = nil
        Handle(sender, table.concat(p.parts))
    end
end

function Handle(sender, text)
    if text:match("^C%d+:") then
        Assemble(sender, text)
        return
    end
    local kind, rest = text:match("^(%u%d)~?(.*)$")
    if not kind then return end
    local g = Guild.Data()
    if not g then return end
    local now = GetTime()

    if kind == "Q1" then
        if not Sync.IsOfficer(sender) then return end
        if now - (lastAnswer[sender] or -math.huge) < ANSWER_GAP then return end
        lastAnswer[sender] = now
        if Sync.Unanswered() and not askedNotice then
            askedNotice = true
            ns.Print(Guild.Short(sender) .. " (officer) asked for your guild info. Nothing is shared until you choose: "
                .. "|cffffffff" .. ns.Cmd.Text("guild") .. " sharing|r.")
        end
        Answer(sender)

    elseif kind == "A0" or kind == "A1" or kind == "A2" then
        if not Sync.IAmOfficer() or not g.members[sender] then return end
        g.shared = g.shared or {}
        local d = g.shared[sender] or {}
        g.shared[sender] = d
        d.t = time()
        if kind == "A0" then
            local cats = {}
            for _, key in ipairs(Split(rest, ",")) do if CAT[key] then cats[key] = true end end
            d.cats = cats
            -- What they no longer share is dropped.
            for key, c in pairs(CAT) do
                if not cats[key] then
                    d[key] = nil
                    if d.bad then d.bad[key] = nil end
                    if d.seal then d.seal[key] = nil end
                    if c.dropped then c.dropped(sender) end
                end
            end
        elseif kind == "A2" then
            d.seal = d.seal or {}
            for _, item in ipairs(Split(rest, ",")) do
                local key, state, since = item:match("^(%a+)=(%a+):(%d+)$")
                since = tonumber(since)
                if key and CAT[key] and SEAL_STATES[state] then
                    local old = d.seal[key]
                    -- A seal that starts over (its saved record deleted) is worth knowing.
                    local restarted = (old and old.since and since and since > old.since) or (old and old.restarted) or nil
                    d.seal[key] = { state = state, since = since ~= 0 and since or nil, restarted = restarted or nil, t = time() }
                end
            end
        else
            local key, payload = rest:match("^(%a+)~(.*)$")
            local parse = key and (PARSE[key] or (CAT[key] and CAT[key].parse))
            if parse and (not d.cats or d.cats[key]) then
                d.bad = d.bad or {}
                d[key], d.bad[key] = Sync.Check(key, parse(payload), sender, g)
                if CAT[key].received then CAT[key].received(sender, d[key]) end
            end
        end
        ns.Refresh()

    elseif kind == "O1" then
        local m = g.members[sender]
        if not (m and m.rank == 0) then return end
        if rest == "" then
            g.officerRanks = nil
        else
            g.officerRanks = {}
            for _, r in ipairs(Split(rest, ",")) do
                local n = tonumber(r)
                if n and n > 0 then g.officerRanks[n] = true end
            end
        end
        g.officerRanksT = time()
        ns.Refresh()

    elseif kind == "Q0" then
        if Sync.IAmGM() and g.officerRanks and now - (lastAnswer.Q0 or -math.huge) >= ANSWER_GAP then
            lastAnswer.Q0 = now
            Sync.SendOfficerRanks()
        end

    elseif kind == "R1" then
        if not Sync.IsOfficer(sender) then return end
        local rules = {}
        for _, item in ipairs(Split(rest, ";")) do
            local f = Split(item, ":")
            local target = tonumber(f[1])
            if target then
                rules[target] = { on = f[2] == "1", level = tonumber(f[3]) or 1, days = tonumber(f[4]) or 0,
                    active = tonumber(f[5]) or 0, recruits = tonumber(f[6]) or 0 }
            end
        end
        g.sharedRules = { by = sender, t = time(), rules = rules }
        ns.Refresh()

    elseif kind == "Q2" then
        local any = false
        for _, r in pairs(g.rules) do if r.on then any = true end end
        if any and Sync.IAmOfficer() and now - (lastAnswer.Q2 or -math.huge) >= ANSWER_GAP then
            lastAnswer.Q2 = now
            Sync.SendRules()
        end
    end
end

local function OnAddonMessage(prefix, text, dist, sender)
    if prefix ~= PREFIX then return end
    text, sender = S.Value(text), S.Value(sender)
    if type(text) ~= "string" or type(sender) ~= "string" or #text > 255 then return end
    local full = Guild.FromFull(sender)
    if full == Me() then return end
    Handle(full, text)
end
Sync.OnAddonMessage = OnAddonMessage

-- Asks the guild master for the officer ranks and an officer for the
-- rules, once a session, when the guild window opens.
local askedSession = false
function Sync.OnWindowOpen()
    if askedSession or not Guild.Mine() then return end
    askedSession = true
    local g = Guild.Data()
    if not g.officerRanks then Send("GUILD", "Q0", "Q0") end
    if not Sync.IAmOfficer() then Send("GUILD", "Q2", "Q2") end
end

---------------------------------------------------------------------------
-- Module
---------------------------------------------------------------------------
ns.RegisterModule("GuildSync", {
    defaults = { guildShare = {} },
    init = function()
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX) end
    end,
    tick = function()
        TrackActivity()
        if rulesChangedAt and GetTime() - rulesChangedAt >= RULES_SETTLE then
            rulesChangedAt = nil
            Sync.SendRules()
        end
        Pump()
        local now = GetTime()
        for key, p in pairs(pieces) do if now - p.t > PIECE_TTL then pieces[key] = nil end end
    end,
    events = { "CHAT_MSG_ADDON" },
    onEvent = function(event, ...) if event == "CHAT_MSG_ADDON" then OnAddonMessage(...) end end,
})
