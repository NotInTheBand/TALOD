-- Version check (Version.lua, Signature.lua, Style.Notice): signed release
-- notes over the hidden channel, forged notes refused, the update window once
-- a session; the pacing that keeps a 10,000-copy channel quiet.
local scenarios, T = ...
local check, slash = T.check, T.slash

local P = "TALODV"
local CH = "TALODVersion"

-- Test key and notes signed with it (tools/release_sign.py functions, a key made for the tests only).
local KEY = { bytes = 128, n = "ad605856675d50b2aa66d63a45d386b29b154b63e39c72457c11cc4c9dbe9bb439e137b09e275439c031f7b00d6d93694e5d479e59e59627873c37adc029f11e8391a28b69750e86776c215c140d89f0bf1f1e5113689bac839e4fb18af5d2ca3711b786de505f9b039d58a55a7ecf6b06b9b9e6cb3dac5db01cb35bdb8e9165", r2 = "152a1f993ee5d474c9b0489edbc9377a9cd564fea57a4f2fcddfe81eadbef69bc928eb7481ad0a1d36d5fa29efec9f0f7367382db6cf1ef07fca9ae3d8d31d9df74dbcb57c22b223d9bbe0e4c08ba5a8a78165df81b3b291448b54c4b6efd25520e564806be1b72333a7e107cb7f51c9e054d7ed30643086f26e980d41e09b5d", ninv = 5883795 }
local NOTES = {
    ["0.23.0"] = { v = "0.23.0", d = "2026-09-01", s = "N+55sstClgcDoaoFVJzvBFLBg9iQ9sPdo/q894mEaQNECiNKtm9GKUKZFtV5I0btk7H6c42qC/uecgTXmQK3m2tHSkDBRcINYlPwW8k6QxdQyQh2BexNTXQMsm3bHXUdRqGJwZMQf8n8cGl5aqVIKqgZoUgSY0wNpsBfgVVXR+w=" },
    ["0.24.0"] = { v = "0.24.0", d = "2026-10-09", s = "KelqaSGOXP8meTZFZqJdkZJipvyvsT1953oli10nDKwKgB38hSRZzNO8fD5ITMF92CXvthdNMTYYpHjOiHSg3anZtuE/oCafmCN4ojtrQOrwDcQzTqZSJuAUtoaCa5P2Z8ih/+q1Mdq+OefmLOKat1VyFd/3s+kKzYy1pir0I8s=" },
    ["0.25.0"] = { v = "0.25.0", d = "2026-10-20", s = "kB0ltvL82ic1n6MPz1/Wzenx03PEKSyIxI7CDUQFP7779yZPHx2UaXQfI2ZFrCk6elAcyVg7yNDjZmb+rO0Dx8MdN7Q+v8qzLj29z/CEgVVKQv6Kl2sN1AoMh5M/7ow9FhfIvBIDbvD9x+Nr6yUTxONSFrbVszd9mk1BlIrHsA0=" },
    ["0.26.0"] = { v = "0.26.0", d = "2026-11-01", s = "V5wbvUI005kou6XUIhNwumx7ZJ96oFJU/MNq46iWZOs5xe0prYltx4oeXUPl/HJOpgWafkpEQRDbTwJkB4LXO2lC3vfofRJM52dQU72zr+BcOaMYLr6zDIO4SGtLOKzSWWVUsrm3tk9lKNpPqUPiDzltj/oc/LXOvHIs3/1XSeQ=" },
}

-- Boots with the test key in place of Release.lua's, before the modules start.
local function boot(version, opts)
    opts = opts or {}
    MOCK.iface = 11509
    MOCK.metadata = { Version = version or "0.24.0" }
    if opts.db then TALODDB = opts.db end
    MOCK.units.player = { exists = true, guid = "Player-1-0001", name = "Tester", level = 20, faction = "Alliance" }
    local ns = MOCK.LoadAddon(ADDON_DIR, ADDON_FILES, ADDON_NAME)
    ns.RELEASE_KEY = KEY
    ns.RELEASE_NOTE = opts.note
    MOCK.FireEvent("ADDON_LOADED", ADDON_NAME)
    MOCK.Tick(0.3)
    MOCK.addonMessages = {}
    MOCK.FireEvent("PLAYER_ENTERING_WORLD")
    return ns
end

local function wait(seconds)
    for _ = 1, math.ceil(seconds / 0.5) do MOCK.Tick(0.5) end
end

local function sent(kind)
    local n = 0
    for _, m in ipairs(MOCK.addonMessages) do
        if m[1] == P and m[2]:find("^" .. kind .. "~") and m[3] == "CHANNEL" then n = n + 1 end
    end
    return n
end

local function lastSent(kind)
    for i = #MOCK.addonMessages, 1, -1 do
        local m = MOCK.addonMessages[i]
        if m[2]:find("^" .. kind .. "~") then return m[2] end
    end
end

local function msg(text, sender) MOCK.FireEvent("CHAT_MSG_ADDON", P, text, "CHANNEL", sender or "Other") end
local function noteMsg(n, sig) return "N~" .. n.v .. "~" .. n.d .. "~" .. (sig or n.s) end
local function shown() return TALODUpdateNotice ~= nil and TALODUpdateNotice:IsShown() end

scenarios.version_signature = function()
    local ns = boot()
    local Sig, V = ns.Signature, ns.Version
    local n = NOTES["0.25.0"]
    check(Sig.Verify("TALOD|0.25.0|2026-10-20", n.s, KEY), "a real note checks out")
    check(not Sig.Verify("TALOD|0.25.1|2026-10-20", n.s, KEY), "a changed version fails")
    check(not Sig.Verify("TALOD|0.25.0|2026-10-21", n.s, KEY), "a changed date fails")
    check(not Sig.Verify("TALOD|0.26.0|2026-11-01", n.s, KEY), "another note's signature fails")
    local flipped = (n.s:sub(1, 1) == "A" and "B" or "A") .. n.s:sub(2)
    check(not Sig.Verify("TALOD|0.25.0|2026-10-20", flipped, KEY), "a changed signature fails")
    check(not Sig.Verify("TALOD|0.25.0|2026-10-20", "junk", KEY) and not Sig.Verify("TALOD|0.25.0|2026-10-20", n.s, nil), "junk / no key")
    check(V.Compare("0.23.5", "0.24.0") == -1 and V.Compare("1.0.0", "0.99.9") == 1 and V.Parse("?") == nil, "versions")
    -- The wait is skewed late: most draws near the end, a few early.
    check(V.Wait(0) == 0 and math.abs(V.Wait(1) - 30) < 1e-6 and V.Wait(0.5) > 25, "late-skewed wait")
end

scenarios.version_channel = function()
    local ns = boot("0.24.0")
    local V = ns.Version

    -- Joins the hidden channel 20 s after login, then asks once.
    wait(10)
    check(MOCK.channels[CH] == nil, "not joined before 20 s")
    wait(12)
    check(MOCK.channels[CH] ~= nil, "joined")
    wait(4)
    check(sent("Q") == 1 and lastSent("Q") == "Q~0.24.0", "asked once with this version: " .. tostring(lastSent("Q")))

    -- Its lines never reach chat.
    check(MOCK.ChatHidden("CHAT_MSG_CHANNEL_NOTICE", "YOU_JOINED", "", "", "5. " .. CH, "", "", 0, 5, CH), "join notice hidden")
    check(MOCK.ChatHidden("CHAT_MSG_CHANNEL", "hi", "Troll", "", "5. " .. CH, "", "", 0, 5, CH), "chat in it hidden")
    check(not MOCK.ChatHidden("CHAT_MSG_CHANNEL", "hi", "Someone", "", "2. Trade", "", "", 0, 2, "Trade"), "Trade untouched")

    -- Forged notes: a fake version, a borrowed signature, junk. None counts.
    msg("N~9.9.9~2026-10-20~" .. NOTES["0.25.0"].s, "Troll")
    wait(3)
    msg(noteMsg(NOTES["0.25.0"], NOTES["0.26.0"].s), "Troll")
    wait(3)
    msg("N~0.30.0~2026-12-01~AAAA", "Troll")
    wait(3)
    check(V.Newer() == nil and not shown(), "forged notes ignored")
    check(V.stats.invalid == 3, "three failed checks: " .. V.stats.invalid)
    msg("N~9.9.9~2026-10-20~" .. NOTES["0.25.0"].s, "Troll")
    wait(3)
    check(V.stats.invalid == 3, "a known forgery is not checked twice")

    -- A real note: learned, saved, and the window opens (out of combat).
    MOCK.lockdown = true
    msg(noteMsg(NOTES["0.25.0"]), "Updater")
    wait(3)
    check(V.Newer() and V.Newer().v == "0.25.0", "real note learned")
    check(TALODDB.versionNews.v == "0.25.0" and TALODDB.versionNews.s == NOTES["0.25.0"].s, "saved with its signature")
    check(not shown(), "not in combat")
    MOCK.lockdown = false
    wait(1)
    check(shown() and TALODUpdateNotice.headline:GetText():find("0.25.0", 1, true), "window opens")
    TALODUpdateNotice:ShowPage("manual")
    check(TALODUpdateNotice.blocks[1].copy:IsShown(), "manual page with the copy link")
    TALODUpdateNotice:Hide()

    -- Once a session: a still newer note, or the same one again, does not reopen it.
    msg(noteMsg(NOTES["0.26.0"]), "Updater2")
    wait(3)
    msg(noteMsg(NOTES["0.26.0"]), "Updater3")
    wait(3)
    check(V.Newer().v == "0.26.0" and not shown(), "newer news learned, window not reopened")
end

-- Answers: one note covers every ask before it; a real note heard first keeps
-- this copy quiet; a fake one does not; once a minute on the channel, once
-- every 30 minutes from this copy.
scenarios.version_answers = function()
    local news = NOTES["0.25.0"]
    local ns = boot("0.25.0", { note = news })
    local V = ns.Version
    wait(26)
    MOCK.addonMessages = {}

    -- Two asks from copies behind: one answer, after the wait.
    msg("Q~0.24.0", "Behind1")
    wait(5)
    msg("Q~0.23.0", "Behind2")
    wait(35)
    check(sent("N") == 1 and lastSent("N") == noteMsg(news), "one answer for both asks: " .. sent("N"))

    -- Up-to-date asks get nothing.
    msg("Q~0.25.0", "Current")
    wait(40)
    check(sent("N") == 1, "no answer to a copy that knows as much")

    -- Within 30 minutes of its own answer this copy leaves asks to the others.
    msg("Q~0.24.0", "Behind3")
    wait(100)
    check(sent("N") == 1, "this copy answers at most every 30 minutes")
end

scenarios.version_answer_suppressed = function()
    local news = NOTES["0.25.0"]
    local ns = boot("0.25.0", { note = news })
    wait(26)
    MOCK.addonMessages = {}

    -- Another copy's real note after the ask: quiet.
    msg("Q~0.24.0", "Behind1")
    wait(0.5)
    msg(noteMsg(news), "FasterCopy")
    wait(40)
    check(sent("N") == 0, "another copy answered first: quiet")

    -- Within a minute of that note an ask waits for the channel gap, then gets one answer.
    msg("Q~0.24.0", "Behind2")
    wait(20)
    check(sent("N") == 0, "the channel heard the note less than a minute ago")
    wait(80)
    check(sent("N") == 1, "answered after the channel gap")
end

scenarios.version_fake_cannot_silence = function()
    local news = NOTES["0.25.0"]
    local ns = boot("0.25.0", { note = news })
    wait(26)
    MOCK.addonMessages = {}
    -- A troll repeats a fake note for the newest version to keep everyone quiet.
    msg("Q~0.24.0", "Behind1")
    for _ = 1, 8 do
        msg(noteMsg(news, NOTES["0.26.0"].s), "Troll")
        wait(5)
    end
    check(sent("N") == 1, "fakes do not silence the real answer: " .. sent("N"))
end

scenarios.version_hourly_ask = function()
    -- Asked ten minutes ago (any character of the account): no ask at this login.
    local ns = boot("0.24.0", { db = { versionAskedAt = MOCK.now - 600 } })
    wait(30)
    check(sent("Q") == 0, "asked recently: quiet login")
    -- An hour after the last ask, the session asks again, once.
    MOCK.now = MOCK.now + 3000
    wait(70)
    check(sent("Q") == 1, "asks again after an hour")
    wait(70)
    check(sent("Q") == 1, "once")
    check(TALODDB.versionAskedAt == MOCK.now, "remembered for the account")
end

scenarios.version_flood = function()
    local ns = boot("0.24.0")
    wait(26)
    -- 300 messages in one second: 10 handled, the rest dropped and counted.
    for i = 1, 300 do msg("Q~0.0." .. i, "Spammer" .. i) end
    check(ns.Version.stats.qIn == 10 and ns.Version.stats.dropped == 290,
        "flood capped: " .. ns.Version.stats.qIn .. " handled, " .. ns.Version.stats.dropped .. " dropped")
    wait(2)
    msg("Q~0.0.1", "Later")
    check(ns.Version.stats.qIn == 11, "next second handled again")
end

scenarios.version_channel_locked = function()
    -- Someone owns the channel and set a password: the copies move to the next name.
    MOCK.channelsLocked[CH] = true
    boot("0.24.0")
    wait(45)
    check(MOCK.channels[CH] == nil and MOCK.channels[CH .. "2"] ~= nil, "joined the second channel")
    check(sent("Q") == 1, "asked there")
    check(MOCK.ChatHidden("CHAT_MSG_CHANNEL", "hi", "Troll", "", "6. " .. CH .. "2", "", "", 0, 6, CH .. "2"), "second channel hidden too")
end

scenarios.version_every_load = function()
    -- Heard last session: opens at load, until the update.
    local news = NOTES["0.25.0"]
    local ns = boot("0.24.0", { db = { versionNews = { v = news.v, d = news.d, s = news.s, at = 1 } } })
    wait(1)
    check(shown(), "opens at load")
    check(ns.Version.Newer().v == "0.25.0", "still newer")
end

scenarios.version_saved_forgery = function()
    -- A hand-edited save file is checked like a message.
    local ns = boot("0.24.0", { db = { versionNews = { v = "0.99.0", d = "2026-10-20", s = NOTES["0.25.0"].s, at = 1 } } })
    wait(1)
    check(not shown() and ns.Version.Newer() == nil and TALODDB.versionNews.v == nil, "forged save dropped")
end

scenarios.version_updated = function()
    -- Updated to the released version: no window, nothing announced unprompted.
    local own = NOTES["0.25.0"]
    local old = NOTES["0.24.0"]
    boot("0.25.0", { note = own, db = { versionNews = { v = old.v, d = old.d, s = old.s, at = 1 } } })
    wait(60)
    check(not shown(), "up to date: no window")
    check(sent("N") == 0 and sent("Q") == 1, "only the ask")
    slash("version")
    check(shown() and TALODUpdateNotice.headline:GetText():find("You have", 1, true), "/talod version: up-to-date window")
    local tabs = TALODUpdateNotice.tabs
    for _ = 1, 5 do slash("version") end
    check(#TALODUpdateNotice.buttonPool == 1 and TALODUpdateNotice.tabs == tabs, "opening it again reuses its buttons and tabs")
    slash("version status")
end

scenarios.version_off_and_full = function()
    local ns = boot("0.24.0", { db = { versionCheck = false } })
    wait(30)
    check(MOCK.channels[CH] == nil and #MOCK.addonMessages == 0, "off: no channel, nothing sent")
    msg(noteMsg(NOTES["0.25.0"]), "Updater")
    wait(3)
    check(ns.Version.Newer() == nil, "off: nothing heard")
    -- On again with every slot taken: tries each name once, says why.
    MOCK.channelsFull = true
    TALODDB.versionCheck = true
    wait(60)
    check(ns.Version.stats.joinTries == 3 and ns.Version.stats.joinError, "three names tried, reason kept")
    check(table.concat(ns.Version.StatusLines(), "\n"):find("password, ban", 1, true), "status says why")
end
