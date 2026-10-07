-- Outbox (Outbox.lua): the one way whispers, guild invites and party
-- invites leave the addon; one pace and one throttle hold for all of them.
local scenarios, T = ...
local check, boot, slash, printed = T.check, T.boot, T.slash, T.printed

local THROTTLED = "The number of messages that can be sent is limited, please wait to send another message."

scenarios.outbox_pace_and_guards = function()
    -- The limit Guild used to keep moves over once.
    TALODDB = { guildWhisperBurst = 4 }
    MOCK.SetGuild()
    local ns = boot(11509)
    local O = ns.Outbox
    check(TALODDB.outboxBurst == 4 and TALODDB.guildWhisperBurst == nil, "old limit migrated")
    check(O.Burst() == 4, "migrated limit used: " .. O.Burst())

    -- Same whisper / invite to the same player twice in a moment: sent once.
    check(O.Whisper("hi", "Someone"), "whisper out")
    local ok, why = O.Whisper("hi", "someone")
    check(not ok and why == "repeat" and #MOCK.whispers == 1, "repeat whisper not sent")
    check(O.Whisper("hi again", "Someone") and #MOCK.whispers == 2, "other text goes")
    check(O.GuildInvite("Someone") and #MOCK.guildInvites == 1, "guild invite out")
    ok, why = O.GuildInvite("Someone")
    check(not ok and why == "repeat" and #MOCK.guildInvites == 1, "repeat invite not sent")
    check(O.PartyInvite("Someone") and #MOCK.partyInvites == 1, "party invite out")
    MOCK.Tick(11)
    check(O.GuildInvite("Someone") and #MOCK.guildInvites == 2, "invite again after the guard")

    -- Optional whispers stop at the queue limit; typed ones still go.
    for i = 1, 4 do O.Whisper("x" .. i, "Q" .. i, { optional = true }) end
    ok, why = O.Whisper("late", "Q9", { optional = true })
    check(not ok and why == "busy", "optional whisper refused past the limit: " .. tostring(why))
    check(O.Whisper("typed", "Q9"), "a typed whisper still goes")

    -- A throttle line holds every whisper, whoever sends it; the lost one
    -- with no owner of its own gets a notice.
    MOCK.FireEvent("UI_ERROR_MESSAGE", 0, THROTTLED)
    check(O.Hold() > 14, "held: " .. O.Hold())
    check(printed("dropped your whisper to Q9"), "lost whisper named")
    ok, why = O.Whisper("during", "Other")
    check(not ok and why == "held", "held for everyone")
    check(O.GuildInvite("Other"), "invites are not chat: still go")
    -- A throttle line in system chat is not also a guild system message.
    MOCK.FireEvent("CHAT_MSG_SYSTEM", THROTTLED)

    slash("pace")
    check(printed("at most"), "/talod pace prints the limit")
    slash("pace reset")
    check(TALODDB.outboxBurst == nil and O.Burst() == 10, "reset forgets the limit")
end
