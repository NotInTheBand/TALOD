-- Resetting settings always asks first: the typed word alone changes nothing,
-- the confirmation's Yes resets settings and window positions and keeps logs,
-- and nothing resets in combat.
local scenarios, T = ...
local check, boot, slash = T.check, T.boot, T.slash

scenarios.reset_asks_first = function()
    boot()
    local db = TALODDB
    for _, words in ipairs({ "reset", "settings reset" }) do
        db.panelScale = 1.7
        db.navPos = { 10, 20 }
        db.journal = db.journal or {}
        db.journal.kept = true
        MOCK.popup = nil
        slash(words)
        check(db.panelScale == 1.7, words .. ": the command alone changes nothing")
        check(db.navPos and db.navPos[1] == 10, words .. ": positions untouched before Yes")
        check(MOCK.popup == "TALOD_RESET", words .. ": the confirmation opened (" .. tostring(MOCK.popup) .. ")")
        MOCK.AcceptPopup()
        db = TALODDB
        check(db.panelScale ~= 1.7, words .. ": Yes resets settings")
        check(db.navPos == nil, words .. ": Yes resets window positions")
        check(db.journal and db.journal.kept, words .. ": logged data kept")
    end
end

scenarios.reset_never_in_combat = function()
    boot()
    TALODDB.panelScale = 1.7
    MOCK.lockdown = true
    MOCK.popup = nil
    slash("settings reset")
    check(MOCK.popup == nil, "no confirmation in combat")
    check(TALODDB.panelScale == 1.7, "nothing reset in combat")
    -- A confirmation left open from before the fight does nothing in combat.
    MOCK.lockdown = false
    slash("reset")
    MOCK.lockdown = true
    MOCK.AcceptPopup()
    check(TALODDB.panelScale == 1.7, "Yes pressed in combat resets nothing")
    MOCK.lockdown = false
end
